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

pub fn wrappedRowCount(bytes: []const u8, width_columns: u16) usize {
    if (bytes.len == 0) return 1;
    if (width_columns == 0) return 0;

    var count: usize = 1;
    var column: u16 = 0;
    var iter = vaxis.unicode.graphemeIterator(bytes);
    while (iter.next()) |grapheme| {
        if (bytes[grapheme.start] == '\n') {
            count += 1;
            column = 0;
            continue;
        }

        const grapheme_width = displayWidth(bytes[grapheme.start..][0..grapheme.len]);
        if (grapheme_width == 0) continue;
        if (column != 0 and column + grapheme_width > width_columns) {
            count += 1;
            column = 0;
        }
        column = @min(width_columns, column + grapheme_width);
    }
    return count;
}

test "text measures display width through libvaxis" {
    try std.testing.expectEqual(@as(u16, 4), displayWidth("a🙂b"));
}

test "text cursor movement uses grapheme boundaries" {
    try std.testing.expectEqual(@as(usize, 1), previousGraphemeStart("a🙂"));
    try std.testing.expectEqual(@as(usize, 4), nextGraphemeLen("🙂b"));
}

test "text counts wrapped rows without splitting graphemes" {
    try std.testing.expectEqual(@as(usize, 1), wrappedRowCount("", 4));
    try std.testing.expectEqual(@as(usize, 2), wrappedRowCount("abcd", 3));
    try std.testing.expectEqual(@as(usize, 2), wrappedRowCount("a🙂b", 3));
    try std.testing.expectEqual(@as(usize, 2), wrappedRowCount("a\nb", 80));
}
