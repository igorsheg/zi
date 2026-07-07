const std = @import("std");
const agent = @import("../agent/root.zig");
const partial_json = @import("../ai/utils/partial_json.zig");
const runtime = @import("../runtime/root.zig");
const screen = @import("screen.zig");

pub const args_preview_bytes_max: usize = 2 * 1024;
pub const tool_body_bytes_max: usize = 64 * 1024;
pub const tail_line_count: usize = 5;
pub const tail_line_bytes_max: usize = 200;

pub const Status = enum { pending, running, done, failed, aborted };

pub fn statusStyle(status: Status) screen.Style {
    return switch (status) {
        .pending => screen.styles.muted,
        .running => screen.styles.accent,
        .done => screen.styles.ok,
        .failed, .aborted => screen.styles.error_,
    };
}

pub fn statusText(status: Status) []const u8 {
    return switch (status) {
        .pending => "pending",
        .running => "running",
        .done => "done",
        .failed => "error",
        .aborted => "aborted",
    };
}

pub fn titleFor(allocator: std.mem.Allocator, name: []const u8, args_json_prefix: []const u8) ![]const u8 {
    if (std.mem.eql(u8, name, "bash")) {
        if (try stringFromPartialJson(allocator, args_json_prefix, &.{"command"})) |command| {
            defer allocator.free(command);
            return titleWithValue(allocator, "$", firstLine(command), 60);
        }
    } else if (isPathTool(name)) {
        if (try stringFromPartialJson(allocator, args_json_prefix, &.{ "path", "file_path" })) |path| {
            defer allocator.free(path);
            return titleWithValue(allocator, name, path, 80);
        }
    }
    return allocator.dupe(u8, name);
}

pub fn titleForValue(allocator: std.mem.Allocator, name: []const u8, value: std.json.Value) ![]const u8 {
    if (std.mem.eql(u8, name, "bash")) {
        if (stringFromValue(value, &.{"command"})) |command| return titleWithValue(allocator, "$", firstLine(command), 60);
    } else if (isPathTool(name)) {
        if (stringFromValue(value, &.{ "path", "file_path" })) |path| return titleWithValue(allocator, name, path, 80);
    }
    return allocator.dupe(u8, name);
}

fn isPathTool(name: []const u8) bool {
    return std.mem.eql(u8, name, "read") or std.mem.eql(u8, name, "write") or std.mem.eql(u8, name, "edit");
}

fn titleWithValue(allocator: std.mem.Allocator, prefix: []const u8, value: []const u8, max_value_bytes: usize) ![]const u8 {
    const bounded = agent.utf8Prefix(value, max_value_bytes);
    return std.fmt.allocPrint(allocator, "{s} {s}", .{ prefix, bounded });
}

fn firstLine(value: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, value, "\r\n") orelse value.len;
    return value[0..end];
}

fn stringFromPartialJson(allocator: std.mem.Allocator, input: []const u8, keys: []const []const u8) !?[]const u8 {
    if (input.len == 0) return null;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = partial_json.parse(arena.allocator(), input) catch return null;
    const value = parsed.value orelse return null;
    const found = stringFromValue(value, keys) orelse return null;
    return @as(?[]const u8, try allocator.dupe(u8, found));
}

fn stringFromValue(value: std.json.Value, keys: []const []const u8) ?[]const u8 {
    if (value != .object) return null;
    for (keys) |key| {
        const field = value.object.get(key) orelse continue;
        if (field == .string) return field.string;
    }
    return null;
}

pub const TailBuffer = struct {
    lines: [tail_line_count][tail_line_bytes_max]u8 = undefined,
    lens: [tail_line_count]usize = @splat(0),
    count: usize = 0,

    pub fn update(self: *TailBuffer, text: []const u8) void {
        for (text) |byte| switch (byte) {
            '\r', '\n' => self.newLine(),
            '\t' => {
                self.pushByte(' ');
                self.pushByte(' ');
            },
            else => self.pushByte(byte),
        };
    }

    pub fn line(self: *const TailBuffer, index: usize) []const u8 {
        std.debug.assert(index < self.count);
        return self.lines[index][0..self.lens[index]];
    }

    pub fn isEmpty(self: *const TailBuffer) bool {
        return self.count == 0 or (self.count == 1 and self.lens[0] == 0);
    }

    fn ensureLine(self: *TailBuffer) void {
        if (self.count == 0) {
            self.count = 1;
            self.lens[0] = 0;
        }
    }

    fn pushByte(self: *TailBuffer, byte: u8) void {
        self.ensureLine();
        const index = self.count - 1;
        if (self.lens[index] == tail_line_bytes_max) {
            std.mem.copyForwards(u8, self.lines[index][0 .. tail_line_bytes_max - 1], self.lines[index][1..tail_line_bytes_max]);
            self.lens[index] -= 1;
        }
        self.lines[index][self.lens[index]] = byte;
        self.lens[index] += 1;
    }

    fn newLine(self: *TailBuffer) void {
        self.ensureLine();
        if (self.count < tail_line_count) {
            self.lens[self.count] = 0;
            self.count += 1;
            return;
        }
        for (1..tail_line_count) |index| {
            @memcpy(&self.lines[index - 1], &self.lines[index]);
            self.lens[index - 1] = self.lens[index];
        }
        self.lens[tail_line_count - 1] = 0;
    }
};

pub fn appendTextContent(writer: *std.Io.Writer.Allocating, content: []const @import("../ai/root.zig").ToolResultContent, max_bytes: usize, truncated: *bool) !void {
    for (content) |item| switch (item) {
        .text => |text| try appendBounded(writer, text.text, max_bytes, truncated),
        .image => {},
    };
}

pub fn appendBounded(writer: *std.Io.Writer.Allocating, text: []const u8, max_bytes: usize, truncated: *bool) !void {
    if (writer.written().len >= max_bytes) {
        truncated.* = true;
        return;
    }
    const remaining = max_bytes - writer.written().len;
    if (text.len <= remaining) {
        try writer.writer.writeAll(text);
        return;
    }
    try writer.writer.writeAll(agent.utf8Prefix(text, remaining));
    truncated.* = true;
}

test "tool titles use tolerant partial json" {
    const title = try titleFor(std.testing.allocator, "bash", "{\"command\":\"zig build\nnext");
    defer std.testing.allocator.free(title);
    try std.testing.expectEqualStrings("$ zig build", title);

    const path_title = try titleFor(std.testing.allocator, "read", "{\"path\":\"src/main.zig\"}");
    defer std.testing.allocator.free(path_title);
    try std.testing.expectEqualStrings("read src/main.zig", path_title);
}

test "tail buffer keeps the last five normalized lines" {
    var tail: TailBuffer = .{};
    tail.update("zero\none\ntwo\rthree\tfour\nfive\nsix");

    try std.testing.expectEqual(@as(usize, 5), tail.count);
    try std.testing.expectEqualStrings("one", tail.line(0));
    try std.testing.expectEqualStrings("two", tail.line(1));
    try std.testing.expectEqualStrings("six", tail.line(4));
}

test "bounded append reports truncation" {
    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();
    var truncated = false;
    try appendBounded(&writer, "abcdef", 4, &truncated);
    try std.testing.expectEqualStrings("abcd", writer.written());
    try std.testing.expect(truncated);
}

test {
    std.testing.refAllDecls(@This());
}
