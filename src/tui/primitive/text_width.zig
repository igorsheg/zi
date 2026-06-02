const std = @import("std");
const uucode = @import("uucode");

pub const replacement: u21 = 0xfffd;

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

pub fn utf8Width(bytes: []const u8) usize {
    if (!std.unicode.utf8ValidateSlice(bytes)) return bytes.len;
    return uucode.grapheme.utf8Wcwidth(bytes);
}

pub fn scalarWidth(scalar: u21) u2 {
    if (scalar == 0 or scalar < 0x20 or scalar == 0x7f) return 1;
    return clampWidth(uucode.get(.wcwidth_standalone, scalar));
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

test "text width uses uucode grapheme width" {
    try std.testing.expectEqual(@as(u21, 'a'), nextScalar("a").scalar);
    try std.testing.expectEqual(@as(u2, 2), scalarWidth(nextScalar("中").scalar));
    try std.testing.expectEqual(@as(usize, 1), utf8Width("o\u{0300}"));
    try std.testing.expectEqual(@as(usize, 2), utf8Width("👩🏽‍🚀"));
    try std.testing.expectEqual(replacement, nextScalar("\xff").scalar);
}

test "next grapheme returns byte range and terminal width" {
    const text = "o\u{0300}中";
    const first = nextGrapheme(text);
    try std.testing.expectEqual(@as(usize, 0), first.start);
    try std.testing.expectEqual(@as(usize, 3), first.end);
    try std.testing.expectEqual(@as(u2, 1), first.width);

    const second = nextGrapheme(text[first.end..]);
    try std.testing.expectEqual(@as(u2, 2), second.width);
}
