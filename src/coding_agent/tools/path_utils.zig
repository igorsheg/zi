const std = @import("std");
const builtin = @import("builtin");
const agent = @import("../../agent/root.zig");
const ai = @import("../../ai/root.zig");

pub const max_path_bytes: usize = 16 * 1024;

pub const PathConfig = struct {
    cwd: []const u8,
    allow_paths_outside_cwd: bool = false,
    home_dir: ?[]const u8 = null,
};

pub fn resolveExistingPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: PathConfig,
    path: []const u8,
) ![]const u8 {
    return resolvePath(allocator, io, config, path, .existing);
}

pub fn resolveCreatablePath(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: PathConfig,
    path: []const u8,
) ![]const u8 {
    return resolvePath(allocator, io, config, path, .creatable);
}

const PathKind = enum { existing, creatable };

fn pathExists(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bool {
    const real_path = std.Io.Dir.realPathFileAlloc(.cwd(), io, path, allocator) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    allocator.free(real_path);
    return true;
}

fn resolveExistingVariant(
    allocator: std.mem.Allocator,
    io: std.Io,
    owned_path: []u8,
) ![]u8 {
    if (try pathExists(allocator, io, owned_path)) return owned_path;
    if (try macOsScreenshotPathVariant(allocator, owned_path)) |variant| {
        errdefer allocator.free(variant);
        if (try pathExists(allocator, io, variant)) {
            allocator.free(owned_path);
            return variant;
        }
        allocator.free(variant);
    }
    if (try nfdLatin1PathVariant(allocator, owned_path)) |variant| {
        errdefer allocator.free(variant);
        if (try pathExists(allocator, io, variant)) {
            allocator.free(owned_path);
            return variant;
        }
        if (try curlyQuotePathVariant(allocator, variant)) |combined| {
            errdefer allocator.free(combined);
            if (try pathExists(allocator, io, combined)) {
                allocator.free(owned_path);
                allocator.free(variant);
                return combined;
            }
            allocator.free(combined);
        }
        allocator.free(variant);
    }
    if (try curlyQuotePathVariant(allocator, owned_path)) |variant| {
        errdefer allocator.free(variant);
        if (try pathExists(allocator, io, variant)) {
            allocator.free(owned_path);
            return variant;
        }
        allocator.free(variant);
    }
    return owned_path;
}

fn resolvePath(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: PathConfig,
    path: []const u8,
    kind: PathKind,
) ![]const u8 {
    const normalized = try normalizeInputPath(allocator, path);
    defer allocator.free(normalized);
    const expanded_home = try expandHomePath(allocator, normalized, config.home_dir);
    defer if (expanded_home) |expanded| allocator.free(expanded);
    const input_path = expanded_home orelse normalized;

    var resolved = if (std.fs.path.isAbsolute(input_path))
        try std.fs.path.resolve(allocator, &.{input_path})
    else
        try std.fs.path.resolve(allocator, &.{ config.cwd, input_path });
    if (kind == .existing) {
        resolved = resolveExistingVariant(allocator, io, resolved) catch |err| {
            allocator.free(resolved);
            return err;
        };
    }
    errdefer allocator.free(resolved);

    if (!config.allow_paths_outside_cwd) {
        const canonical_cwd = try std.Io.Dir.realPathFileAlloc(.cwd(), io, config.cwd, allocator);
        defer allocator.free(canonical_cwd);
        const canonical_path = switch (kind) {
            .existing => try std.Io.Dir.realPathFileAlloc(.cwd(), io, resolved, allocator),
            .creatable => try canonicalExistingParent(allocator, io, resolved),
        };
        defer allocator.free(canonical_path);
        if (!isPathInside(canonical_cwd, canonical_path)) return error.PathOutsideCwd;
    }
    return resolved;
}

fn expandHomePath(allocator: std.mem.Allocator, path: []const u8, home_dir_raw: ?[]const u8) !?[]u8 {
    if (path.len == 0 or path[0] != '~') return null;
    if (path.len > 1 and !std.fs.path.isSep(path[1])) return null;
    const home_dir = trimTrailingPathSeparators(home_dir_raw orelse return null);
    if (home_dir.len == 0) return null;
    const suffix = if (path.len == 1) "" else path[1..];
    const expanded = try std.fmt.allocPrint(allocator, "{s}{s}", .{ home_dir, suffix });
    errdefer allocator.free(expanded);
    if (expanded.len == 0 or expanded.len > max_path_bytes) return error.InvalidToolArguments;
    return expanded;
}

fn trimTrailingPathSeparators(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and std.fs.path.isSep(path[end - 1])) : (end -= 1) {}
    return path[0..end];
}

pub fn normalizeInputPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len == 0 or path.len > max_path_bytes) return error.InvalidToolArguments;
    const stripped = if (path[0] == '@') path[1..] else path;
    if (stripped.len == 0) return error.InvalidToolArguments;

    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    var index: usize = 0;
    while (index < stripped.len) {
        if (unicodeSpaceLen(stripped[index..])) |len| {
            try out.writer.writeByte(' ');
            index += len;
        } else {
            try out.writer.writeByte(stripped[index]);
            index += 1;
        }
    }
    const normalized = try out.toOwnedSlice();
    if (normalized.len == 0 or normalized.len > max_path_bytes) {
        allocator.free(normalized);
        return error.InvalidToolArguments;
    }
    return normalized;
}

fn macOsScreenshotPathVariant(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    var changed = false;
    var index: usize = 0;
    while (index < path.len) {
        if (index + 4 <= path.len and
            path[index] == ' ' and
            path[index + 3] == '.' and
            (std.ascii.eqlIgnoreCase(path[index + 1 .. index + 3], "AM") or
                std.ascii.eqlIgnoreCase(path[index + 1 .. index + 3], "PM")))
        {
            try out.writer.writeAll("\xe2\x80\xaf");
            try out.writer.writeAll(path[index + 1 .. index + 4]);
            index += 4;
            changed = true;
        } else {
            try out.writer.writeByte(path[index]);
            index += 1;
        }
    }
    if (!changed) {
        out.deinit();
        return null;
    }
    const variant = try out.toOwnedSlice();
    return variant;
}

const NfdMapping = struct {
    composed: []const u8,
    decomposed: []const u8,
};

const latin1_nfd_mappings = [_]NfdMapping{
    .{ .composed = "À", .decomposed = "A\u{300}" },
    .{ .composed = "Á", .decomposed = "A\u{301}" },
    .{ .composed = "Â", .decomposed = "A\u{302}" },
    .{ .composed = "Ã", .decomposed = "A\u{303}" },
    .{ .composed = "Ä", .decomposed = "A\u{308}" },
    .{ .composed = "Å", .decomposed = "A\u{30a}" },
    .{ .composed = "Ç", .decomposed = "C\u{327}" },
    .{ .composed = "È", .decomposed = "E\u{300}" },
    .{ .composed = "É", .decomposed = "E\u{301}" },
    .{ .composed = "Ê", .decomposed = "E\u{302}" },
    .{ .composed = "Ë", .decomposed = "E\u{308}" },
    .{ .composed = "Ì", .decomposed = "I\u{300}" },
    .{ .composed = "Í", .decomposed = "I\u{301}" },
    .{ .composed = "Î", .decomposed = "I\u{302}" },
    .{ .composed = "Ï", .decomposed = "I\u{308}" },
    .{ .composed = "Ñ", .decomposed = "N\u{303}" },
    .{ .composed = "Ò", .decomposed = "O\u{300}" },
    .{ .composed = "Ó", .decomposed = "O\u{301}" },
    .{ .composed = "Ô", .decomposed = "O\u{302}" },
    .{ .composed = "Õ", .decomposed = "O\u{303}" },
    .{ .composed = "Ö", .decomposed = "O\u{308}" },
    .{ .composed = "Ù", .decomposed = "U\u{300}" },
    .{ .composed = "Ú", .decomposed = "U\u{301}" },
    .{ .composed = "Û", .decomposed = "U\u{302}" },
    .{ .composed = "Ü", .decomposed = "U\u{308}" },
    .{ .composed = "Ý", .decomposed = "Y\u{301}" },
    .{ .composed = "à", .decomposed = "a\u{300}" },
    .{ .composed = "á", .decomposed = "a\u{301}" },
    .{ .composed = "â", .decomposed = "a\u{302}" },
    .{ .composed = "ã", .decomposed = "a\u{303}" },
    .{ .composed = "ä", .decomposed = "a\u{308}" },
    .{ .composed = "å", .decomposed = "a\u{30a}" },
    .{ .composed = "ç", .decomposed = "c\u{327}" },
    .{ .composed = "è", .decomposed = "e\u{300}" },
    .{ .composed = "é", .decomposed = "e\u{301}" },
    .{ .composed = "ê", .decomposed = "e\u{302}" },
    .{ .composed = "ë", .decomposed = "e\u{308}" },
    .{ .composed = "ì", .decomposed = "i\u{300}" },
    .{ .composed = "í", .decomposed = "i\u{301}" },
    .{ .composed = "î", .decomposed = "i\u{302}" },
    .{ .composed = "ï", .decomposed = "i\u{308}" },
    .{ .composed = "ñ", .decomposed = "n\u{303}" },
    .{ .composed = "ò", .decomposed = "o\u{300}" },
    .{ .composed = "ó", .decomposed = "o\u{301}" },
    .{ .composed = "ô", .decomposed = "o\u{302}" },
    .{ .composed = "õ", .decomposed = "o\u{303}" },
    .{ .composed = "ö", .decomposed = "o\u{308}" },
    .{ .composed = "ù", .decomposed = "u\u{300}" },
    .{ .composed = "ú", .decomposed = "u\u{301}" },
    .{ .composed = "û", .decomposed = "u\u{302}" },
    .{ .composed = "ü", .decomposed = "u\u{308}" },
    .{ .composed = "ý", .decomposed = "y\u{301}" },
    .{ .composed = "ÿ", .decomposed = "y\u{308}" },
};

fn nfdLatin1PathVariant(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    var changed = false;
    var index: usize = 0;
    while (index < path.len) {
        for (latin1_nfd_mappings) |mapping| {
            if (std.mem.startsWith(u8, path[index..], mapping.composed)) {
                try out.writer.writeAll(mapping.decomposed);
                index += mapping.composed.len;
                changed = true;
                break;
            }
        } else {
            try out.writer.writeByte(path[index]);
            index += 1;
        }
    }
    if (!changed) {
        out.deinit();
        return null;
    }
    const variant = try out.toOwnedSlice();
    return variant;
}

fn curlyQuotePathVariant(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    var changed = false;
    for (path) |byte| {
        if (byte == '\'') {
            try out.writer.writeAll("\xe2\x80\x99");
            changed = true;
        } else {
            try out.writer.writeByte(byte);
        }
    }
    if (!changed) {
        out.deinit();
        return null;
    }
    const variant = try out.toOwnedSlice();
    return variant;
}

fn unicodeSpaceLen(bytes: []const u8) ?usize {
    const spaces = [_][]const u8{
        "\xc2\xa0", // no-break space
        "\xe1\x9a\x80", // ogham space mark
        "\xe2\x80\x80", // en quad
        "\xe2\x80\x81", // em quad
        "\xe2\x80\x82", // en space
        "\xe2\x80\x83", // em space
        "\xe2\x80\x84", // three-per-em space
        "\xe2\x80\x85", // four-per-em space
        "\xe2\x80\x86", // six-per-em space
        "\xe2\x80\x87", // figure space
        "\xe2\x80\x88", // punctuation space
        "\xe2\x80\x89", // thin space
        "\xe2\x80\x8a", // hair space
        "\xe2\x80\xaf", // narrow no-break space
        "\xe2\x81\x9f", // medium mathematical space
        "\xe3\x80\x80", // ideographic space
    };
    for (spaces) |space| {
        if (std.mem.startsWith(u8, bytes, space)) return space.len;
    }
    return null;
}

fn canonicalExistingParent(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![:0]u8 {
    var candidate = path;
    while (true) {
        return std.Io.Dir.realPathFileAlloc(.cwd(), io, candidate, allocator) catch |err| switch (err) {
            error.FileNotFound => {
                candidate = std.fs.path.dirname(candidate) orelse return err;
                continue;
            },
            else => return err,
        };
    }
}

pub fn isPathInside(raw_cwd: []const u8, path: []const u8) bool {
    var cwd = raw_cwd;
    while (cwd.len > 1 and std.fs.path.isSep(cwd[cwd.len - 1])) cwd = cwd[0 .. cwd.len - 1];
    if (!std.mem.startsWith(u8, path, cwd)) return false;
    if (cwd.len == 1 and std.fs.path.isSep(cwd[0])) return true;
    if (path.len == cwd.len) return true;
    return std.fs.path.isSep(path[cwd.len]);
}

const utf8_replacement = "\u{fffd}";

/// Wrap owned text (ownership transfers) into a single-content tool result.
/// Tool result text is model/runtime data, so invalid process/file bytes are
/// replaced before they can enter the transcript or public protocol.
pub fn ownedTextResult(
    allocator: std.mem.Allocator,
    text: []const u8,
    details: ?std.json.Value,
) !agent.ToolExecutionResult {
    var owned_text: []const u8 = text;
    errdefer allocator.free(owned_text);
    owned_text = try sanitizeOwnedUtf8(allocator, owned_text);
    const content = try allocator.alloc(ai.ToolResultContent, 1);
    content[0] = .{ .text = .{ .text = owned_text } };
    return .{ .allocator = allocator, .result = .{ .content = content, .details = details } };
}

pub fn dupSanitizedUtf8(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    return sanitizeOwnedUtf8(allocator, try allocator.dupe(u8, text));
}

fn sanitizeOwnedUtf8(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(text)) return text;

    var sanitized: std.ArrayList(u8) = .empty;
    errdefer sanitized.deinit(allocator);
    var index: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        if (byte < 0x80) {
            try sanitized.append(allocator, byte);
            index += 1;
            continue;
        }
        const sequence_len = std.unicode.utf8ByteSequenceLength(byte) catch {
            try sanitized.appendSlice(allocator, utf8_replacement);
            index += 1;
            continue;
        };
        if (index + sequence_len > text.len or
            !std.unicode.utf8ValidateSlice(text[index .. index + sequence_len]))
        {
            try sanitized.appendSlice(allocator, utf8_replacement);
            index += 1;
            continue;
        }
        try sanitized.appendSlice(allocator, text[index .. index + sequence_len]);
        index += sequence_len;
    }

    const owned = try sanitized.toOwnedSlice(allocator);
    allocator.free(text);
    return owned;
}

pub fn textResult(
    allocator: std.mem.Allocator,
    text: []const u8,
    details: ?std.json.Value,
) !agent.ToolExecutionResult {
    return ownedTextResult(allocator, try allocator.dupe(u8, text), details);
}

/// Build an owned `std.json.Value` object from an anonymous struct literal.
/// Field types: bool, integers, string slices/literals (duped), an already
/// owned `std.json.Value` (adopted), and optionals of those (null omitted).
pub fn jsonDetails(allocator: std.mem.Allocator, fields: anytype) error{OutOfMemory}!std.json.Value {
    var object: std.json.ObjectMap = .empty;
    errdefer object.deinit(allocator);
    inline for (@typeInfo(@TypeOf(fields)).@"struct".fields) |field| {
        try putJsonValue(allocator, &object, field.name, @field(fields, field.name));
    }
    return .{ .object = object };
}

fn putJsonValue(
    allocator: std.mem.Allocator,
    object: *std.json.ObjectMap,
    key: []const u8,
    value: anytype,
) error{OutOfMemory}!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .optional => if (value) |resolved| try putJsonValue(allocator, object, key, resolved),
        .bool => try putJsonField(allocator, object, key, .{ .bool = value }),
        .int, .comptime_int => try putJsonField(allocator, object, key, .{ .integer = @intCast(value) }),
        else => if (T == std.json.Value)
            try putJsonField(allocator, object, key, value)
        else
            try putJsonStringField(allocator, object, key, value),
    }
}

pub fn putJsonField(
    allocator: std.mem.Allocator,
    object: *std.json.ObjectMap,
    key: []const u8,
    value: std.json.Value,
) !void {
    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);
    try object.put(allocator, owned_key, value);
}

pub fn putJsonStringField(
    allocator: std.mem.Allocator,
    object: *std.json.ObjectMap,
    key: []const u8,
    value: []const u8,
) !void {
    const owned_value = try allocator.dupe(u8, value);
    errdefer allocator.free(owned_value);
    try putJsonField(allocator, object, key, .{ .string = owned_value });
}

test "owned text result sanitizes invalid utf8" {
    const text = try std.testing.allocator.dupe(u8, "ok\xffgo");
    var result = try ownedTextResult(std.testing.allocator, text, null);
    defer result.deinit();

    try std.testing.expect(std.unicode.utf8ValidateSlice(result.result.content[0].text.text));
    try std.testing.expectEqualStrings("ok�go", result.result.content[0].text.text);
}

test "json details builds typed object and omits null optionals" {
    const nested = try jsonDetails(std.testing.allocator, .{ .truncated = true });
    const details = try jsonDetails(std.testing.allocator, .{
        .count = @as(usize, 3),
        .kind = "bytes",
        .skipped = @as(?usize, null),
        .present = @as(?usize, 7),
        .truncation = nested,
    });
    var owned: agent.ToolExecutionResult = try textResult(std.testing.allocator, "x", details);
    defer owned.deinit();

    const object = owned.result.details.?.object;
    try std.testing.expectEqual(@as(i64, 3), object.get("count").?.integer);
    try std.testing.expectEqualStrings("bytes", object.get("kind").?.string);
    try std.testing.expect(object.get("skipped") == null);
    try std.testing.expectEqual(@as(i64, 7), object.get("present").?.integer);
    try std.testing.expect(object.get("truncation").?.object.get("truncated").?.bool);
}

test "existing path resolution tries common macOS filename variants" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "repo");
    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try tmp.dir.realPathFile(std.testing.io, "repo", &cwd_buffer);
    const cwd = cwd_buffer[0..cwd_len];

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/shot\xe2\x80\xafAM.png", .data = "x" });
    const screenshot = try resolveExistingPath(std.testing.allocator, std.testing.io, .{
        .cwd = cwd,
    }, "shot AM.png");
    defer std.testing.allocator.free(screenshot);
    try std.testing.expect(std.mem.endsWith(u8, screenshot, "shot\xe2\x80\xafAM.png"));

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/it\xe2\x80\x99s.txt", .data = "x" });
    const curly = try resolveExistingPath(std.testing.allocator, std.testing.io, .{
        .cwd = cwd,
    }, "it's.txt");
    defer std.testing.allocator.free(curly);
    try std.testing.expect(std.mem.endsWith(u8, curly, "it\xe2\x80\x99s.txt"));

    const nfd = (try nfdLatin1PathVariant(std.testing.allocator, "Café.txt")).?;
    defer std.testing.allocator.free(nfd);
    try std.testing.expectEqualStrings("Cafe\u{301}.txt", nfd);
    try std.testing.expect((try nfdLatin1PathVariant(std.testing.allocator, "Cafe.txt")) == null);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/Cafe\u{301}.txt", .data = "x" });
    const decomposed = try resolveExistingPath(std.testing.allocator, std.testing.io, .{
        .cwd = cwd,
    }, "Café.txt");
    defer std.testing.allocator.free(decomposed);
    try std.testing.expect(std.mem.endsWith(u8, decomposed, "Café.txt") or
        std.mem.endsWith(u8, decomposed, "Cafe\u{301}.txt"));

    const nfd_curly = (try curlyQuotePathVariant(std.testing.allocator, "Cafe\u{301}'s.txt")).?;
    defer std.testing.allocator.free(nfd_curly);
    try std.testing.expectEqualStrings("Cafe\u{301}\xe2\x80\x99s.txt", nfd_curly);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/Cafe\u{301}\xe2\x80\x99s.txt", .data = "x" });
    const combined = try resolveExistingPath(std.testing.allocator, std.testing.io, .{
        .cwd = cwd,
    }, "Café's.txt");
    defer std.testing.allocator.free(combined);
    try std.testing.expect(std.mem.endsWith(u8, combined, "Café's.txt") or
        std.mem.endsWith(u8, combined, "Cafe\u{301}\xe2\x80\x99s.txt"));
}

test "path containment requires separator boundary" {
    try std.testing.expect(isPathInside("/repo", "/repo"));
    try std.testing.expect(isPathInside("/repo", "/repo/file"));
    try std.testing.expect(!isPathInside("/repo", "/repo2/file"));
}

test "home expansion is explicit and bounded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/project");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "home/project/file.txt", .data = "x" });
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPathFile(std.testing.io, ".", &root_buffer);
    const root = root_buffer[0..root_len];
    var repo_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const repo_len = try tmp.dir.realPathFile(std.testing.io, "repo", &repo_buffer);
    const repo = repo_buffer[0..repo_len];

    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = try std.fmt.bufPrint(&home_buffer, "{s}/home/", .{root});
    const resolved = try resolveExistingPath(std.testing.allocator, std.testing.io, .{
        .cwd = repo,
        .allow_paths_outside_cwd = true,
        .home_dir = home,
    }, "~/project/file.txt");
    defer std.testing.allocator.free(resolved);
    try std.testing.expect(std.mem.endsWith(u8, resolved, "home/project/file.txt"));

    const literal = try normalizeInputPath(std.testing.allocator, "~other/file.txt");
    defer std.testing.allocator.free(literal);
    try std.testing.expectEqualStrings("~other/file.txt", literal);
}

test "path normalization strips one at sign and maps unicode spaces" {
    const normalized = try normalizeInputPath(std.testing.allocator, "@@dir\xc2\xa0name/\xe2\x80\x89file");
    defer std.testing.allocator.free(normalized);
    try std.testing.expectEqualStrings("@dir name/ file", normalized);
    try std.testing.expectError(error.InvalidToolArguments, normalizeInputPath(std.testing.allocator, ""));
    try std.testing.expectError(error.InvalidToolArguments, normalizeInputPath(std.testing.allocator, "@"));

    const oversized = try std.testing.allocator.alloc(u8, max_path_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');
    try std.testing.expectError(error.InvalidToolArguments, normalizeInputPath(std.testing.allocator, oversized));
}

test "path containment rejects symlink escapes" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");
    try tmp.dir.createDirPath(std.testing.io, "other");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "other/file.txt", .data = "outside" });
    try tmp.dir.symLink(std.testing.io, "../other", "repo/link", .{});

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try tmp.dir.realPathFile(std.testing.io, "repo", &cwd_buffer);
    const cwd = cwd_buffer[0..cwd_len];

    try std.testing.expectError(error.PathOutsideCwd, resolveExistingPath(
        std.testing.allocator,
        std.testing.io,
        .{ .cwd = cwd },
        "link/file.txt",
    ));
    try std.testing.expectError(error.PathOutsideCwd, resolveCreatablePath(
        std.testing.allocator,
        std.testing.io,
        .{ .cwd = cwd },
        "link/new.txt",
    ));
}

test "creatable path containment uses nearest existing parent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo/dir");
    try tmp.dir.createDirPath(std.testing.io, "other");

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try tmp.dir.realPathFile(std.testing.io, "repo", &cwd_buffer);
    const cwd = cwd_buffer[0..cwd_len];

    const resolved = try resolveCreatablePath(
        std.testing.allocator,
        std.testing.io,
        .{ .cwd = cwd },
        "dir/new/file.txt",
    );
    defer std.testing.allocator.free(resolved);
    try std.testing.expect(std.mem.endsWith(u8, resolved, "dir/new/file.txt"));

    try std.testing.expectError(error.PathOutsideCwd, resolveCreatablePath(
        std.testing.allocator,
        std.testing.io,
        .{ .cwd = cwd },
        "../other/new.txt",
    ));
}
