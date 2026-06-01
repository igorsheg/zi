const std = @import("std");
const vaxis = @import("vaxis");

pub fn displayWidth(text: []const u8) u16 {
    return vaxis.gwidth.gwidth(text, .unicode);
}

pub fn cursorColumn(text: []const u8, cursor_byte_index: usize, width: u16) u16 {
    std.debug.assert(cursor_byte_index <= text.len);
    if (width == 0) return 0;
    const col = displayWidth(text[0..cursor_byte_index]);
    return @intCast(@min(col, width - 1));
}

pub fn previousGraphemeStart(text: []const u8) usize {
    var iter = vaxis.unicode.graphemeIterator(text);
    var previous: usize = 0;
    while (iter.next()) |grapheme| previous = grapheme.start;
    return previous;
}

pub fn nextGraphemeLen(text: []const u8) usize {
    var iter = vaxis.unicode.graphemeIterator(text);
    const grapheme = iter.next() orelse return 0;
    return grapheme.len;
}

test "text measures display width through libvaxis" {
    try std.testing.expectEqual(@as(u16, 4), displayWidth("a🙂b"));
}

test "text cursor movement uses grapheme boundaries" {
    try std.testing.expectEqual(@as(usize, 1), previousGraphemeStart("a🙂"));
    try std.testing.expectEqual(@as(usize, 4), nextGraphemeLen("🙂b"));
}
