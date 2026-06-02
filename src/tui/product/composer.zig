const std = @import("std");

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
        const start = previousScalarStart(self.bytes.items, self.cursor_byte_index);
        self.bytes.replaceRangeAssumeCapacity(start, self.cursor_byte_index - start, "");
        self.cursor_byte_index = start;
    }

    pub fn moveLeft(self: *ComposerBuffer) void {
        if (self.cursor_byte_index == 0) return;
        self.cursor_byte_index = previousScalarStart(self.bytes.items, self.cursor_byte_index);
    }

    pub fn moveRight(self: *ComposerBuffer) void {
        if (self.cursor_byte_index >= self.bytes.items.len) return;
        self.cursor_byte_index = nextScalarEnd(self.bytes.items, self.cursor_byte_index);
    }

    pub fn takeSubmit(self: *ComposerBuffer, allocator: std.mem.Allocator) !?[]u8 {
        if (self.bytes.items.len == 0) return null;
        if (self.bytes.items.len > submit_size_bytes_max) return error.ComposerTooLarge;
        const owned = try allocator.dupe(u8, self.bytes.items);
        self.clear();
        return owned;
    }
};

fn previousScalarStart(bytes: []const u8, cursor: usize) usize {
    std.debug.assert(cursor <= bytes.len);
    var index = cursor - 1;
    while (index > 0 and (bytes[index] & 0xc0) == 0x80) : (index -= 1) {}
    return index;
}

fn nextScalarEnd(bytes: []const u8, cursor: usize) usize {
    std.debug.assert(cursor < bytes.len);
    const first = bytes[cursor];
    const len: usize = if (first < 0x80)
        1
    else if ((first & 0xe0) == 0xc0)
        2
    else if ((first & 0xf0) == 0xe0)
        3
    else if ((first & 0xf8) == 0xf0)
        4
    else
        1;
    return @min(cursor + len, bytes.len);
}

test "composer inserts utf8 moves and backspaces by scalar" {
    var composer: ComposerBuffer = .{};
    defer composer.deinit(std.testing.allocator);

    try composer.insertUtf8(std.testing.allocator, "a中b");
    composer.moveLeft();
    composer.backspace();
    try std.testing.expectEqualStrings("ab", composer.text());

    const submitted = (try composer.takeSubmit(std.testing.allocator)).?;
    defer std.testing.allocator.free(submitted);
    try std.testing.expectEqualStrings("ab", submitted);
    try std.testing.expectEqualStrings("", composer.text());
}
