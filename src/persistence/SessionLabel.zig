const std = @import("std");
const text = @import("../text/root.zig");

pub const maximum_scan_bytes: usize = 64 * 1024;
pub const default_prompt_cells: usize = 512;
pub const maximum_zero_width_per_base: usize = 8;

pub const Error = error{ OutOfMemory, InvalidPath, IoFailure, NotRegular };

pub const Label = struct {
    prompt: ?[]u8 = null,
    provider: ?[]u8 = null,
    model: ?[]u8 = null,
    effort: ?[]u8 = null,
    preset: ?[]u8 = null,
    git_branch: ?[]u8 = null,
    git_subject: ?[]u8 = null,

    pub fn deinit(self: *Label, allocator: std.mem.Allocator) void {
        freeOptional(allocator, self.prompt);
        freeOptional(allocator, self.provider);
        freeOptional(allocator, self.model);
        freeOptional(allocator, self.effort);
        freeOptional(allocator, self.preset);
        freeOptional(allocator, self.git_branch);
        freeOptional(allocator, self.git_subject);
        self.* = undefined;
    }
};

pub fn read(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    maximum_prompt_cells: usize,
) Error!Label {
    if (!safeAbsolutePath(path)) return error.InvalidPath;
    const named_stat = std.Io.Dir.statFile(.cwd(), io, path, .{ .follow_symlinks = false }) catch
        return error.IoFailure;
    if (named_stat.kind != .file or named_stat.nlink == 0) return error.NotRegular;
    const file = std.Io.Dir.openFile(.cwd(), io, path, .{
        .mode = .read_only,
        .follow_symlinks = false,
    }) catch return error.IoFailure;
    defer file.close(io);
    const retained_size: usize = @intCast(@min(named_stat.size, maximum_scan_bytes));
    const data = allocator.alloc(u8, retained_size) catch return error.OutOfMemory;
    defer allocator.free(data);
    if (retained_size != 0) {
        const bytes_read = file.readPositionalAll(io, data, 0) catch return error.IoFailure;
        if (bytes_read != retained_size) return error.IoFailure;
    }
    return parse(allocator, data, maximum_prompt_cells);
}

pub fn parse(
    allocator: std.mem.Allocator,
    data: []const u8,
    maximum_prompt_cells: usize,
) error{OutOfMemory}!Label {
    var label: Label = .{};
    errdefer label.deinit(allocator);
    var saw_compaction_seed = false;
    var lines = std.mem.splitScalar(u8, data[0..@min(data.len, maximum_scan_bytes)], '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{
            .duplicate_field_behavior = .use_last,
        }) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            continue;
        };
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const object = parsed.value.object;
        const record_type = optionalString(object, "type");
        if (record_type) |kind| if (std.mem.eql(u8, kind, "session") or
            std.mem.eql(u8, kind, "selection"))
        {
            try replaceOptional(allocator, &label.provider, optionalString(object, "provider"));
            const model = optionalString(object, "model_label") orelse optionalString(object, "model");
            try replaceOptional(allocator, &label.model, model);
            try replaceOptional(allocator, &label.effort, optionalString(object, "effort"));
            try replaceOptional(allocator, &label.preset, optionalString(object, "preset"));
            if (std.mem.eql(u8, kind, "session")) {
                try replaceOptional(allocator, &label.git_branch, optionalString(object, "git_branch"));
                try replaceOptional(allocator, &label.git_subject, optionalString(object, "git_subject"));
            }
            continue;
        };
        const item_kind = optionalString(object, "kind") orelse continue;
        if (!std.mem.eql(u8, item_kind, "user")) continue;
        if (optionalString(object, "origin")) |origin| {
            if (std.mem.eql(u8, origin, "compact_seed")) {
                saw_compaction_seed = true;
                continue;
            }
            if (std.mem.eql(u8, origin, "continuation") or
                std.mem.eql(u8, origin, "task_note")) continue;
        }
        if (optionalString(object, "text")) |prompt| {
            const flattened = try flatten(allocator, prompt);
            defer allocator.free(flattened);
            label.prompt = try truncate(allocator, flattened, maximum_prompt_cells);
        }
        break;
    }
    if (label.prompt == null and saw_compaction_seed) {
        label.prompt = allocator.dupe(u8, "(compacted)") catch return error.OutOfMemory;
    }
    return label;
}

pub fn flatten(allocator: std.mem.Allocator, input: []const u8) error{OutOfMemory}![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    output.ensureTotalCapacity(allocator, input.len) catch return error.OutOfMemory;
    var previous_was_space = true;
    var zero_width_run: usize = 0;
    var offset: usize = 0;
    while (offset < input.len) {
        const byte = input[offset];
        if (byte < 0x80) {
            const is_space = byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or
                byte < 0x20 or byte == 0x7f;
            if (is_space) {
                if (!previous_was_space) {
                    output.appendAssumeCapacity(' ');
                    previous_was_space = true;
                }
            } else {
                output.appendAssumeCapacity(byte);
                previous_was_space = false;
            }
            zero_width_run = 0;
            offset += 1;
            continue;
        }
        const glyph = text.DisplayWidth.next(input, offset).?;
        if (glyph.width == 0) {
            if (zero_width_run < maximum_zero_width_per_base) {
                output.appendSliceAssumeCapacity(glyph.bytes);
                zero_width_run += 1;
            }
        } else {
            output.appendSliceAssumeCapacity(glyph.bytes);
            zero_width_run = 0;
            previous_was_space = false;
        }
        offset += glyph.consumed;
    }
    if (output.items.len != 0 and output.items[output.items.len - 1] == ' ') _ = output.pop();
    return output.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

pub fn truncate(
    allocator: std.mem.Allocator,
    input: []const u8,
    maximum_cells: usize,
) error{OutOfMemory}![]u8 {
    if (text.DisplayWidth.visibleWidth(input, maximum_cells +| 1) <= maximum_cells) {
        return allocator.dupe(u8, input) catch error.OutOfMemory;
    }
    const suffix = if (maximum_cells < 4) "" else "...";
    const content_cells = maximum_cells -| suffix.len;
    var glyphs = text.DisplayWidth.iterator(input);
    var end: usize = 0;
    var cells: usize = 0;
    while (glyphs.next()) |glyph| {
        if (glyph.width > content_cells -| cells) break;
        end = glyphs.offset;
        cells += glyph.width;
    }
    const output = allocator.alloc(u8, end + suffix.len) catch return error.OutOfMemory;
    @memcpy(output[0..end], input[0..end]);
    @memcpy(output[end..], suffix);
    return output;
}

fn replaceOptional(
    allocator: std.mem.Allocator,
    destination: *?[]u8,
    value: ?[]const u8,
) error{OutOfMemory}!void {
    const replacement = if (value) |bytes|
        allocator.dupe(u8, bytes) catch return error.OutOfMemory
    else
        null;
    freeOptional(allocator, destination.*);
    destination.* = replacement;
}

fn optionalString(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

fn freeOptional(allocator: std.mem.Allocator, value: ?[]u8) void {
    if (value) |bytes| allocator.free(bytes);
}

fn safeAbsolutePath(path: []const u8) bool {
    if (path.len == 0 or path[0] != '/' or std.mem.findScalar(u8, path, 0) != null or
        !std.unicode.utf8ValidateSlice(path)) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..")) return false;
    return true;
}

test "label uses opening selection and first typed prompt" {
    const fixture =
        "{\"type\":\"session\",\"provider\":\"p\",\"model\":\"wire\"," ++
        "\"model_label\":\"Shown\",\"effort\":\"high\",\"preset\":\"work\"," ++
        "\"git_branch\":\"main\",\"git_subject\":\"subject\"}\n" ++
        "{\"kind\":\"user\",\"text\":\"  hello\\n  world  \"}\n" ++
        "{\"type\":\"selection\",\"provider\":\"later\",\"model\":\"new\"}\n";
    var label = try parse(std.testing.allocator, fixture, default_prompt_cells);
    defer label.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("hello world", label.prompt.?);
    try std.testing.expectEqualStrings("p", label.provider.?);
    try std.testing.expectEqualStrings("Shown", label.model.?);
    try std.testing.expectEqualStrings("high", label.effort.?);
    try std.testing.expectEqualStrings("work", label.preset.?);
    try std.testing.expectEqualStrings("main", label.git_branch.?);
    try std.testing.expectEqualStrings("subject", label.git_subject.?);
}

test "unknown user origins remain typed prompts" {
    var label = try parse(
        std.testing.allocator,
        "{\"kind\":\"user\",\"text\":\"kept\",\"origin\":\"future\"}\n",
        default_prompt_cells,
    );
    defer label.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("kept", label.prompt.?);
}

test "synthetic users are skipped and compaction is the fallback" {
    const compacted =
        "{\"kind\":\"user\",\"text\":\"summary\",\"origin\":\"compact_seed\"}\n" ++
        "{\"kind\":\"user\",\"text\":\"continue\",\"origin\":\"continuation\"}\n";
    var label = try parse(std.testing.allocator, compacted, default_prompt_cells);
    defer label.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("(compacted)", label.prompt.?);
}

test "flatten sanitizes and bounds invisible runs" {
    const combining = "a" ++ "\xcc\x81" ** 12 ++ " b";
    const flattened = try flatten(std.testing.allocator, " \t one\n\r two \x1b " ++ combining);
    defer std.testing.allocator.free(flattened);
    try std.testing.expect(std.mem.startsWith(u8, flattened, "one two a"));
    try std.testing.expectEqual(@as(usize, 8), std.mem.count(u8, flattened, "\xcc\x81"));
    try std.testing.expect(std.mem.endsWith(u8, flattened, " b"));
}

test "prompt truncation uses three ASCII dots" {
    const result = try truncate(std.testing.allocator, "abcdefghij", 7);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("abcd...", result);
    const narrow = try truncate(std.testing.allocator, "abc", 2);
    defer std.testing.allocator.free(narrow);
    try std.testing.expectEqualStrings("ab", narrow);
}

test "reader is prefix bounded and rejects final symlinks" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const path = try std.fmt.allocPrint(allocator, "{s}/session.jsonl", .{root});
    defer allocator.free(path);
    var file = try tmp.dir.createFile(io, "session.jsonl", .{});
    try file.writeStreamingAll(io, "{\"kind\":\"user\",\"text\":\"kept\"}\n");
    file.close(io);
    var label = try read(allocator, io, path, default_prompt_cells);
    defer label.deinit(allocator);
    try std.testing.expectEqualStrings("kept", label.prompt.?);
    try tmp.dir.symLink(io, "session.jsonl", "link.jsonl", .{});
    const link = try std.fmt.allocPrint(allocator, "{s}/link.jsonl", .{root});
    defer allocator.free(link);
    try std.testing.expectError(error.NotRegular, read(allocator, io, link, default_prompt_cells));
}
