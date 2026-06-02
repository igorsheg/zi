const std = @import("std");

pub const line_count_max: usize = 200;
pub const total_size_bytes_max: usize = 64 * 1024;
pub const append_size_bytes_max: usize = 8 * 1024;

pub const TranscriptRole = enum { user, assistant, system };

pub const TranscriptAppendMode = enum { new_line, extend_previous_same_role };

pub const TranscriptAppend = struct {
    role: TranscriptRole,
    text: []const u8,
    mode: TranscriptAppendMode = .new_line,
};

pub const TranscriptLine = struct {
    role: TranscriptRole,
    text: []u8,
};

pub const TranscriptBuffer = struct {
    lines: std.ArrayListUnmanaged(TranscriptLine) = .empty,
    total_size_bytes: usize = 0,

    pub fn deinit(self: *TranscriptBuffer, allocator: std.mem.Allocator) void {
        for (self.lines.items) |line| allocator.free(line.text);
        self.lines.deinit(allocator);
        self.* = undefined;
    }

    pub fn append(self: *TranscriptBuffer, allocator: std.mem.Allocator, item: TranscriptAppend) !void {
        if (item.text.len > append_size_bytes_max) return error.TranscriptAppendTooLarge;
        if (!std.unicode.utf8ValidateSlice(item.text)) return error.InvalidUtf8;

        if (item.mode == .extend_previous_same_role and self.lines.items.len > 0) {
            const last = &self.lines.items[self.lines.items.len - 1];
            if (last.role == item.role) {
                last.text = try allocator.realloc(last.text, last.text.len + item.text.len);
                @memcpy(last.text[last.text.len - item.text.len ..], item.text);
                self.total_size_bytes += item.text.len;
                self.evictUntilBounded(allocator);
                return;
            }
        }

        const copy = try allocator.dupe(u8, item.text);
        errdefer allocator.free(copy);
        try self.lines.append(allocator, .{ .role = item.role, .text = copy });
        self.total_size_bytes += copy.len;
        self.evictUntilBounded(allocator);
    }

    pub fn latest(self: TranscriptBuffer, count: usize) []const TranscriptLine {
        if (count >= self.lines.items.len) return self.lines.items;
        return self.lines.items[self.lines.items.len - count ..];
    }

    fn evictUntilBounded(self: *TranscriptBuffer, allocator: std.mem.Allocator) void {
        while (self.lines.items.len > line_count_max or self.total_size_bytes > total_size_bytes_max) {
            const line = self.lines.orderedRemove(0);
            self.total_size_bytes -= line.text.len;
            allocator.free(line.text);
        }
    }
};

test "transcript owns copied text and accepts empty append" {
    var buffer: TranscriptBuffer = .{};
    defer buffer.deinit(std.testing.allocator);

    var source = [_]u8{ 'h', 'i' };
    try buffer.append(std.testing.allocator, .{ .role = .user, .text = &source });
    source[0] = 'b';
    try buffer.append(std.testing.allocator, .{ .role = .system, .text = "" });

    try std.testing.expectEqual(@as(usize, 2), buffer.lines.items.len);
    try std.testing.expectEqualStrings("hi", buffer.lines.items[0].text);
    try std.testing.expectEqualStrings("", buffer.lines.items[1].text);
}

test "transcript can extend previous line with same role" {
    var buffer: TranscriptBuffer = .{};
    defer buffer.deinit(std.testing.allocator);

    try buffer.append(std.testing.allocator, .{ .role = .assistant, .text = "hel" });
    try buffer.append(std.testing.allocator, .{ .role = .assistant, .text = "lo", .mode = .extend_previous_same_role });
    try buffer.append(std.testing.allocator, .{ .role = .user, .text = "stop", .mode = .extend_previous_same_role });

    try std.testing.expectEqual(@as(usize, 2), buffer.lines.items.len);
    try std.testing.expectEqualStrings("hello", buffer.lines.items[0].text);
    try std.testing.expectEqualStrings("stop", buffer.lines.items[1].text);
}

test "transcript rejects invalid utf8 and oversized single append before allocation" {
    var buffer: TranscriptBuffer = .{};
    defer buffer.deinit(std.testing.allocator);

    try std.testing.expectError(error.InvalidUtf8, buffer.append(std.testing.allocator, .{
        .role = .assistant,
        .text = "\xff",
    }));

    const too_large = try std.testing.allocator.alloc(u8, append_size_bytes_max + 1);
    defer std.testing.allocator.free(too_large);
    @memset(too_large, 'a');
    try std.testing.expectError(error.TranscriptAppendTooLarge, buffer.append(std.testing.allocator, .{
        .role = .assistant,
        .text = too_large,
    }));
    try std.testing.expectEqual(@as(usize, 0), buffer.lines.items.len);
}

test "transcript accepts exact append limit" {
    var buffer: TranscriptBuffer = .{};
    defer buffer.deinit(std.testing.allocator);

    const exact = try std.testing.allocator.alloc(u8, append_size_bytes_max);
    defer std.testing.allocator.free(exact);
    @memset(exact, 'a');
    try buffer.append(std.testing.allocator, .{ .role = .assistant, .text = exact });
    try std.testing.expectEqual(@as(usize, append_size_bytes_max), buffer.total_size_bytes);
}

test "transcript evicts oldest by line count and total bytes" {
    var buffer: TranscriptBuffer = .{};
    defer buffer.deinit(std.testing.allocator);

    for (0..line_count_max + 1) |index| {
        const text = if (index == 0) "old" else "new";
        try buffer.append(std.testing.allocator, .{ .role = .system, .text = text });
    }
    try std.testing.expectEqual(@as(usize, line_count_max), buffer.lines.items.len);
    try std.testing.expectEqualStrings("new", buffer.lines.items[0].text);

    const chunk = try std.testing.allocator.alloc(u8, append_size_bytes_max);
    defer std.testing.allocator.free(chunk);
    @memset(chunk, 'b');
    for (0..9) |_| try buffer.append(std.testing.allocator, .{ .role = .assistant, .text = chunk });
    try std.testing.expect(buffer.total_size_bytes <= total_size_bytes_max);
    try std.testing.expect(buffer.lines.items.len <= line_count_max);
}
