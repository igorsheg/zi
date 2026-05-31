const std = @import("std");
const vaxis = @import("vaxis");

pub const Composer = struct {
    bytes: std.ArrayList(u8) = .empty,
    cursor: usize = 0,

    pub const bytes_max = 16 * 1024;

    pub fn deinit(self: *Composer, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
        self.* = undefined;
    }

    pub fn insert(self: *Composer, allocator: std.mem.Allocator, text: []const u8) !void {
        try validateInsert(text);
        if (self.bytes.items.len + text.len > bytes_max) return error.ComposerFull;
        try self.bytes.insertSlice(allocator, self.cursor, text);
        self.cursor += text.len;
    }

    pub fn backspace(self: *Composer) void {
        if (self.cursor == 0) return;
        const start = previousGraphemeStart(self.bytes.items[0..self.cursor]);
        self.bytes.replaceRangeAssumeCapacity(start, self.cursor - start, "");
        self.cursor = start;
    }

    pub fn moveLeft(self: *Composer) void {
        if (self.cursor == 0) return;
        self.cursor = previousGraphemeStart(self.bytes.items[0..self.cursor]);
    }

    pub fn moveRight(self: *Composer) void {
        if (self.cursor >= self.bytes.items.len) return;
        self.cursor += nextGraphemeLen(self.bytes.items[self.cursor..]);
    }

    pub fn clear(self: *Composer) void {
        self.bytes.clearRetainingCapacity();
        self.cursor = 0;
    }

    pub fn submit(self: *Composer, allocator: std.mem.Allocator) !?[]u8 {
        if (std.mem.trim(u8, self.bytes.items, " \t").len == 0) return null;
        const prompt = try allocator.dupe(u8, self.bytes.items);
        self.clear();
        return prompt;
    }

    pub fn cursorCol(self: Composer, width: u16) u16 {
        if (width == 0) return 0;
        const col = vaxis.gwidth.gwidth(self.bytes.items[0..self.cursor], .unicode);
        return @intCast(@min(col, width - 1));
    }

    fn validateInsert(text: []const u8) !void {
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        if (std.mem.indexOfScalar(u8, text, '\n') != null) return error.NewlineUnsupported;
        if (std.mem.indexOfScalar(u8, text, '\r') != null) return error.NewlineUnsupported;
    }

    fn previousGraphemeStart(text: []const u8) usize {
        var iter = vaxis.unicode.graphemeIterator(text);
        var previous: usize = 0;
        while (iter.next()) |grapheme| previous = grapheme.start;
        return previous;
    }

    fn nextGraphemeLen(text: []const u8) usize {
        var iter = vaxis.unicode.graphemeIterator(text);
        const grapheme = iter.next() orelse return 0;
        return grapheme.len;
    }
};

test "composer rejects newline before mutation" {
    var composer: Composer = .{};
    defer composer.deinit(std.testing.allocator);

    try composer.insert(std.testing.allocator, "abc");
    try std.testing.expectError(error.NewlineUnsupported, composer.insert(std.testing.allocator, "\n"));
    try std.testing.expectEqualStrings("abc", composer.bytes.items);
}
