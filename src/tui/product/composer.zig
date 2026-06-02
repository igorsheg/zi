const std = @import("std");
const text_primitive = @import("../primitive/text.zig");

pub const buffer_size_bytes_max: usize = 16 * 1024;
pub const submit_size_bytes_max: usize = buffer_size_bytes_max;

pub const ComposerBuffer = struct {
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    cursor_byte_index: usize = 0,

    pub fn deinit(self: *ComposerBuffer, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
        self.* = undefined;
    }

    pub fn clear(self: *ComposerBuffer) void {
        self.bytes.clearRetainingCapacity();
        self.cursor_byte_index = 0;
    }

    pub fn text(self: ComposerBuffer) []const u8 {
        return self.bytes.items;
    }

    pub fn insertUtf8(self: *ComposerBuffer, allocator: std.mem.Allocator, bytes: []const u8) !void {
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
        if (self.bytes.items.len + bytes.len > buffer_size_bytes_max) return error.ComposerTooLarge;
        try self.bytes.insertSlice(allocator, self.cursor_byte_index, bytes);
        self.cursor_byte_index += bytes.len;
    }

    pub fn backspace(self: *ComposerBuffer) void {
        if (self.cursor_byte_index == 0) return;
        const start = text_primitive.previousGraphemeStart(self.bytes.items, self.cursor_byte_index);
        self.bytes.replaceRangeAssumeCapacity(start, self.cursor_byte_index - start, "");
        self.cursor_byte_index = start;
    }

    pub fn moveLeft(self: *ComposerBuffer) void {
        if (self.cursor_byte_index == 0) return;
        self.cursor_byte_index = text_primitive.previousGraphemeStart(self.bytes.items, self.cursor_byte_index);
    }

    pub fn moveRight(self: *ComposerBuffer) void {
        if (self.cursor_byte_index >= self.bytes.items.len) return;
        self.cursor_byte_index = text_primitive.nextGraphemeEnd(self.bytes.items, self.cursor_byte_index);
    }

    pub fn takeSubmit(self: *ComposerBuffer, allocator: std.mem.Allocator) !?[]u8 {
        if (self.bytes.items.len == 0) return null;
        if (self.bytes.items.len > submit_size_bytes_max) return error.ComposerTooLarge;
        const owned = try allocator.dupe(u8, self.bytes.items);
        self.clear();
        return owned;
    }
};

test "composer inserts utf8 moves and backspaces by grapheme" {
    var composer: ComposerBuffer = .{};
    defer composer.deinit(std.testing.allocator);

    try composer.insertUtf8(std.testing.allocator, "ao\u{0300}👩🏽‍🚀b");
    composer.moveLeft();
    composer.backspace();
    try std.testing.expectEqualStrings("ao\u{0300}b", composer.text());
    composer.backspace();
    try std.testing.expectEqualStrings("ab", composer.text());

    const submitted = (try composer.takeSubmit(std.testing.allocator)).?;
    defer std.testing.allocator.free(submitted);
    try std.testing.expectEqualStrings("ab", submitted);
    try std.testing.expectEqualStrings("", composer.text());
}
