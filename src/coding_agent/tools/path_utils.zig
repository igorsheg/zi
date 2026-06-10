const std = @import("std");
const builtin = @import("builtin");
const agent = @import("../../agent/root.zig");
const ai = @import("../../ai/root.zig");

pub const max_path_bytes: usize = 16 * 1024;

pub const PathConfig = struct {
    cwd: []const u8,
    allow_paths_outside_cwd: bool = false,
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

fn resolvePath(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: PathConfig,
    path: []const u8,
    kind: PathKind,
) ![]const u8 {
    const normalized = try normalizeInputPath(allocator, path);
    defer allocator.free(normalized);

    const resolved = if (std.fs.path.isAbsolute(normalized))
        try std.fs.path.resolve(allocator, &.{normalized})
    else
        try std.fs.path.resolve(allocator, &.{ config.cwd, normalized });
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

/// Wrap owned text (ownership transfers) into a single-content tool result.
pub fn ownedTextResult(
    allocator: std.mem.Allocator,
    text: []const u8,
    details: ?std.json.Value,
) !agent.ToolExecutionResult {
    errdefer allocator.free(text);
    const content = try allocator.alloc(ai.ToolResultContent, 1);
    content[0] = .{ .text = .{ .text = text } };
    return .{ .allocator = allocator, .result = .{ .content = content, .details = details } };
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

pub fn ignoredSearchPath(path: []const u8) bool {
    var parts = std.mem.splitAny(u8, path, "/\\");
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".git") or std.mem.eql(u8, part, "node_modules")) return true;
    }
    return false;
}

pub fn parseOptionalLimit(params: std.json.Value, config_max: usize) !usize {
    if (params != .object) return error.InvalidToolArguments;
    const value = params.object.get("limit") orelse return config_max;
    if (value != .integer or value.integer < 1) return error.InvalidToolArguments;
    const requested = std.math.cast(usize, value.integer) orelse return config_max;
    return @min(requested, config_max);
}

test "path containment requires separator boundary" {
    try std.testing.expect(isPathInside("/repo", "/repo"));
    try std.testing.expect(isPathInside("/repo", "/repo/file"));
    try std.testing.expect(!isPathInside("/repo", "/repo2/file"));
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

test "search ignore policy skips common dependency metadata paths" {
    try std.testing.expect(ignoredSearchPath(".git/config"));
    try std.testing.expect(ignoredSearchPath("src/node_modules/pkg/index.js"));
    try std.testing.expect(!ignoredSearchPath("src/git/config"));
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
