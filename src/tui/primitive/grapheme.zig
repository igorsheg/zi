const std = @import("std");
const vaxis = @import("vaxis");

pub fn previousStart(bytes: []const u8) usize {
    std.debug.assert(bytes.len > 0);

    var iter = vaxis.unicode.graphemeIterator(bytes);
    var start: usize = 0;
    var previous_start: usize = 0;
    var last_width: u16 = 1;
    while (iter.next()) |grapheme| {
        previous_start = start;
        start = grapheme.start;
        last_width = vaxis.gwidth.gwidth(grapheme.bytes(bytes), .unicode);
    }
    if (start > 0 and last_width == 0) return previous_start;
    return start;
}

pub fn nextEnd(bytes: []const u8, cursor_byte_index: usize) usize {
    std.debug.assert(cursor_byte_index < bytes.len);

    var iter = vaxis.unicode.graphemeIterator(bytes[cursor_byte_index..]);
    const first = iter.next() orelse return bytes.len;
    var end = cursor_byte_index + first.start + first.len;
    var last_width = vaxis.gwidth.gwidth(first.bytes(bytes[cursor_byte_index..]), .unicode);
    while (last_width == 0) {
        const next = iter.next() orelse return bytes.len;
        end = cursor_byte_index + next.start + next.len;
        last_width = vaxis.gwidth.gwidth(next.bytes(bytes[cursor_byte_index..]), .unicode);
    }
    return end;
}

test "previous start folds trailing zero-width grapheme into base" {
    try std.testing.expectEqual(@as(usize, 1), previousStart("ae\u{0301}"));
}

test "next end folds zero-width grapheme into base" {
    try std.testing.expectEqual(@as(usize, "e\u{0301}".len), nextEnd("e\u{0301}x", 0));
}
