const std = @import("std");
const uucode = @import("uucode");

pub const replacement: u21 = 0xfffd;
pub const grapheme_bytes_max: usize = 32;

pub const DecodedScalar = struct {
    scalar: u21,
    len: usize,
};

pub const Grapheme = struct {
    start: usize,
    end: usize,
    width: u2,
};

pub fn nextScalar(bytes: []const u8) DecodedScalar {
    if (bytes.len == 0) return .{ .scalar = replacement, .len = 0 };
    const first = bytes[0];
    if (first < 0x80) {
        return .{ .scalar = if (first < 0x20 or first == 0x7f) replacement else first, .len = 1 };
    }
    const len = utf8SequenceLen(first);
    if (len > bytes.len) return .{ .scalar = replacement, .len = 1 };
    const slice = bytes[0..len];
    if (!std.unicode.utf8ValidateSlice(slice)) return .{ .scalar = replacement, .len = 1 };
    return .{ .scalar = std.unicode.utf8Decode(slice) catch replacement, .len = len };
}

pub fn nextGrapheme(bytes: []const u8) Grapheme {
    if (bytes.len == 0) return .{ .start = 0, .end = 0, .width = 0 };
    if (!std.unicode.utf8ValidateSlice(bytes)) return .{ .start = 0, .end = 1, .width = 1 };

    var iterator = uucode.grapheme.utf8Iterator(bytes);
    const grapheme = iterator.nextGrapheme() orelse return .{ .start = 0, .end = 0, .width = 0 };
    const width = uucode.grapheme.wcwidth(uucode.grapheme.utf8Iterator(bytes[grapheme.start..grapheme.end]));
    return .{ .start = grapheme.start, .end = grapheme.end, .width = clampWidth(width) };
}

pub fn previousGraphemeStart(bytes: []const u8, cursor: usize) usize {
    std.debug.assert(cursor <= bytes.len);
    if (cursor == 0) return 0;
    if (!std.unicode.utf8ValidateSlice(bytes[0..cursor])) return previousScalarStart(bytes, cursor);

    var iterator = uucode.grapheme.utf8Iterator(bytes[0..cursor]);
    var previous: usize = 0;
    while (iterator.nextGrapheme()) |grapheme| {
        if (grapheme.end >= cursor) return grapheme.start;
        previous = grapheme.start;
    }
    return previous;
}

pub fn nextGraphemeEnd(bytes: []const u8, cursor: usize) usize {
    std.debug.assert(cursor <= bytes.len);
    if (cursor >= bytes.len) return bytes.len;
    if (!std.unicode.utf8ValidateSlice(bytes[cursor..])) return nextScalarEnd(bytes, cursor);

    const grapheme = nextGrapheme(bytes[cursor..]);
    if (grapheme.end == 0) return bytes.len;
    return @min(cursor + grapheme.end, bytes.len);
}

pub fn displayWidth(bytes: []const u8) usize {
    if (!std.unicode.utf8ValidateSlice(bytes)) return bytes.len;
    return uucode.grapheme.utf8Wcwidth(bytes);
}

pub fn scalarWidth(scalar: u21) u2 {
    if (scalar == 0 or scalar < 0x20 or scalar == 0x7f) return 1;
    return clampWidth(uucode.get(.wcwidth_standalone, scalar));
}

fn previousScalarStart(bytes: []const u8, cursor: usize) usize {
    var index = cursor - 1;
    while (index > 0 and (bytes[index] & 0xc0) == 0x80) : (index -= 1) {}
    return index;
}

fn nextScalarEnd(bytes: []const u8, cursor: usize) usize {
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

fn clampWidth(width: usize) u2 {
    if (width == 0) return 0;
    if (width > 2) return 2;
    return @intCast(width);
}

fn utf8SequenceLen(first: u8) usize {
    if ((first & 0xe0) == 0xc0) return 2;
    if ((first & 0xf0) == 0xe0) return 3;
    if ((first & 0xf8) == 0xf0) return 4;
    return 1;
}

test "text uses uucode grapheme width" {
    try std.testing.expectEqual(@as(u21, 'a'), nextScalar("a").scalar);
    try std.testing.expectEqual(@as(u2, 2), scalarWidth(nextScalar("中").scalar));
    try std.testing.expectEqual(@as(usize, 1), displayWidth("o\u{0300}"));
    try std.testing.expectEqual(@as(usize, 2), displayWidth("👩🏽‍🚀"));
    try std.testing.expectEqual(replacement, nextScalar("\xff").scalar);
}

test "grapheme cursor movement preserves clusters" {
    const value = "ao\u{0300}👩🏽‍🚀b";
    var cursor = value.len;
    cursor = previousGraphemeStart(value, cursor);
    try std.testing.expectEqualStrings("b", value[cursor..]);
    cursor = previousGraphemeStart(value, cursor);
    try std.testing.expectEqualStrings("👩🏽‍🚀", value[cursor .. value.len - 1]);
    try std.testing.expectEqual(value.len - 1, nextGraphemeEnd(value, cursor));
}
