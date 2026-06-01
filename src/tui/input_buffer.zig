const std = @import("std");

const text = @import("text.zig");

pub const InputBuffer = struct {
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    cursor_byte_index: usize = 0,

    pub const bytes_max = 16 * 1024;

    pub fn deinit(self: *InputBuffer, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
        self.* = undefined;
    }

    pub fn insert(self: *InputBuffer, allocator: std.mem.Allocator, bytes: []const u8) !void {
        try validateInsert(bytes);
        std.debug.assert(self.cursor_byte_index <= self.bytes.items.len);
        const byte_count_after_insert = std.math.add(usize, self.bytes.items.len, bytes.len) catch
            return error.InputBufferFull;
        if (byte_count_after_insert > bytes_max) return error.InputBufferFull;
        try self.bytes.insertSlice(allocator, self.cursor_byte_index, bytes);
        self.cursor_byte_index += bytes.len;
    }

    pub fn backspace(self: *InputBuffer) void {
        if (self.cursor_byte_index == 0) return;
        const start = text.previousGraphemeStart(self.bytes.items[0..self.cursor_byte_index]);
        self.bytes.replaceRangeAssumeCapacity(start, self.cursor_byte_index - start, &.{});
        self.cursor_byte_index = start;
    }

    pub fn moveLeft(self: *InputBuffer) void {
        if (self.cursor_byte_index == 0) return;
        self.cursor_byte_index = text.previousGraphemeStart(self.bytes.items[0..self.cursor_byte_index]);
    }

    pub fn moveRight(self: *InputBuffer) void {
        if (self.cursor_byte_index >= self.bytes.items.len) return;
        const next_len = text.nextGraphemeLen(self.bytes.items[self.cursor_byte_index..]);
        std.debug.assert(next_len <= self.bytes.items.len - self.cursor_byte_index);
        self.cursor_byte_index += next_len;
    }

    pub fn clearRetainingCapacity(self: *InputBuffer) void {
        self.bytes.clearRetainingCapacity();
        self.cursor_byte_index = 0;
    }

    pub fn cursorColumn(self: InputBuffer, width: u16) u16 {
        return text.cursorColumn(self.bytes.items, self.cursor_byte_index, width);
    }

    fn validateInsert(bytes: []const u8) !void {
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
        if (std.mem.indexOfScalar(u8, bytes, '\n') != null) return error.NewlineUnsupported;
    }
};

test "input buffer edits bounded utf8 bytes" {
    var buffer: InputBuffer = .{};
    defer buffer.deinit(std.testing.allocator);

    try buffer.insert(std.testing.allocator, "a🙂b");
    buffer.moveLeft();
    buffer.backspace();

    try std.testing.expectEqualStrings("ab", buffer.bytes.items);
    try std.testing.expectEqual(@as(usize, 1), buffer.cursor_byte_index);
}

test "input buffer rejects newline before mutation" {
    var buffer: InputBuffer = .{};
    defer buffer.deinit(std.testing.allocator);

    try buffer.insert(std.testing.allocator, "abc");
    try std.testing.expectError(error.NewlineUnsupported, buffer.insert(std.testing.allocator, "\n"));
    try std.testing.expectEqualStrings("abc", buffer.bytes.items);
}
