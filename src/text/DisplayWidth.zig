const std = @import("std");
const Utf8 = @import("Utf8.zig");

const substitute = "?";

/// One decoded terminal glyph. `bytes` borrows `input` or points at static
/// storage. Callers may retain input-backed bytes only as long as they retain
/// the input. `consumed` is always in 1...4 and `width` is always 0, 1, or 2.
pub const Glyph = struct {
    bytes: []const u8,
    consumed: u3,
    width: u2,
    is_ascii_space: bool,
};

/// Allocation-free iteration over terminal glyphs.
pub const Iterator = struct {
    input: []const u8,
    offset: usize = 0,

    pub fn next(self: *Iterator) ?Glyph {
        const glyph = decode(self.input, self.offset) orelse return null;
        self.offset += glyph.consumed;
        return glyph;
    }
};

pub fn iterator(input: []const u8) Iterator {
    return .{ .input = input };
}

/// Decode the glyph at a byte offset. An offset at or beyond input.len returns
/// null. Malformed UTF-8 consumes one byte and produces a visible `?`, so no
/// malformed byte is hidden inside a larger replacement.
///
/// Tabs are C0 controls and therefore become `?`. A layout caller that wants
/// tabs must intercept `\t` and expand it from the current column; tab stops
/// cannot be computed by a provider-neutral scalar decoder.
pub fn next(input: []const u8, offset: usize) ?Glyph {
    return decode(input, offset);
}

/// Sum terminal cells, saturating at `maximum`. ANSI escapes are ordinary
/// control bytes here and are not parsed.
pub fn visibleWidth(input: []const u8, maximum: usize) usize {
    var glyphs = iterator(input);
    var width: usize = 0;
    while (glyphs.next()) |glyph| {
        if (glyph.width >= maximum -| width) return maximum;
        width += glyph.width;
    }
    return width;
}

const Interval = struct { first: u21, last: u21 };

// Adapted from the conventional wcwidth table used by EditLayout and hax.
// The sorted intervals cover common and supplementary combining marks without
// depending on a process locale.
const combining = [_]Interval{
    .{ .first = 0x0300, .last = 0x036f },   .{ .first = 0x0483, .last = 0x0489 },
    .{ .first = 0x0591, .last = 0x05bd },   .{ .first = 0x05bf, .last = 0x05bf },
    .{ .first = 0x05c1, .last = 0x05c2 },   .{ .first = 0x05c4, .last = 0x05c5 },
    .{ .first = 0x0610, .last = 0x061a },   .{ .first = 0x064b, .last = 0x065f },
    .{ .first = 0x0670, .last = 0x0670 },   .{ .first = 0x06d6, .last = 0x06ed },
    .{ .first = 0x0711, .last = 0x0711 },   .{ .first = 0x0730, .last = 0x074a },
    .{ .first = 0x07a6, .last = 0x07b0 },   .{ .first = 0x07eb, .last = 0x07f3 },
    .{ .first = 0x0816, .last = 0x082d },   .{ .first = 0x0859, .last = 0x085b },
    .{ .first = 0x08d3, .last = 0x0902 },   .{ .first = 0x093a, .last = 0x093c },
    .{ .first = 0x0941, .last = 0x0948 },   .{ .first = 0x094d, .last = 0x094d },
    .{ .first = 0x0951, .last = 0x0957 },   .{ .first = 0x0962, .last = 0x0963 },
    .{ .first = 0x0981, .last = 0x0981 },   .{ .first = 0x09bc, .last = 0x09bc },
    .{ .first = 0x09c1, .last = 0x09c4 },   .{ .first = 0x09cd, .last = 0x09cd },
    .{ .first = 0x0a01, .last = 0x0a02 },   .{ .first = 0x0a3c, .last = 0x0a3c },
    .{ .first = 0x0a41, .last = 0x0a51 },   .{ .first = 0x0a70, .last = 0x0a71 },
    .{ .first = 0x0abc, .last = 0x0abc },   .{ .first = 0x0ac1, .last = 0x0ac8 },
    .{ .first = 0x0acd, .last = 0x0acd },   .{ .first = 0x0b01, .last = 0x0b01 },
    .{ .first = 0x0b3c, .last = 0x0b3c },   .{ .first = 0x0b3f, .last = 0x0b3f },
    .{ .first = 0x0b41, .last = 0x0b4d },   .{ .first = 0x0c00, .last = 0x0c00 },
    .{ .first = 0x0c3e, .last = 0x0c40 },   .{ .first = 0x0c46, .last = 0x0c56 },
    .{ .first = 0x0d41, .last = 0x0d4d },   .{ .first = 0x0dca, .last = 0x0dca },
    .{ .first = 0x0dd2, .last = 0x0dd6 },   .{ .first = 0x0e31, .last = 0x0e31 },
    .{ .first = 0x0e34, .last = 0x0e3a },   .{ .first = 0x0e47, .last = 0x0e4e },
    .{ .first = 0x0eb1, .last = 0x0eb1 },   .{ .first = 0x0eb4, .last = 0x0ecd },
    .{ .first = 0x0f18, .last = 0x0f19 },   .{ .first = 0x0f35, .last = 0x0f39 },
    .{ .first = 0x0f71, .last = 0x0f84 },   .{ .first = 0x0f86, .last = 0x0f87 },
    .{ .first = 0x0f8d, .last = 0x0fbc },   .{ .first = 0x102d, .last = 0x1030 },
    .{ .first = 0x1032, .last = 0x1037 },   .{ .first = 0x1039, .last = 0x103a },
    .{ .first = 0x1058, .last = 0x1059 },   .{ .first = 0x135d, .last = 0x135f },
    .{ .first = 0x1712, .last = 0x1714 },   .{ .first = 0x1732, .last = 0x1734 },
    .{ .first = 0x1752, .last = 0x1753 },   .{ .first = 0x1772, .last = 0x1773 },
    .{ .first = 0x17b4, .last = 0x17d3 },   .{ .first = 0x180b, .last = 0x180d },
    .{ .first = 0x1885, .last = 0x1886 },   .{ .first = 0x18a9, .last = 0x18a9 },
    .{ .first = 0x1ab0, .last = 0x1aff },   .{ .first = 0x1dc0, .last = 0x1dff },
    .{ .first = 0x20d0, .last = 0x20ff },   .{ .first = 0x2cef, .last = 0x2cf1 },
    .{ .first = 0x2de0, .last = 0x2dff },   .{ .first = 0x302a, .last = 0x302f },
    .{ .first = 0x3099, .last = 0x309a },   .{ .first = 0xa66f, .last = 0xa672 },
    .{ .first = 0xa674, .last = 0xa67d },   .{ .first = 0xa69e, .last = 0xa69f },
    .{ .first = 0xa6f0, .last = 0xa6f1 },   .{ .first = 0xa802, .last = 0xa802 },
    .{ .first = 0xa806, .last = 0xa806 },   .{ .first = 0xa80b, .last = 0xa80b },
    .{ .first = 0xa825, .last = 0xa826 },   .{ .first = 0xa8c4, .last = 0xa8c5 },
    .{ .first = 0xa8e0, .last = 0xa8f1 },   .{ .first = 0xfe00, .last = 0xfe0f },
    .{ .first = 0xfe20, .last = 0xfe2f },   .{ .first = 0x101fd, .last = 0x101fd },
    .{ .first = 0x1d167, .last = 0x1d182 }, .{ .first = 0x1d185, .last = 0x1d18b },
    .{ .first = 0x1d1aa, .last = 0x1d1ad }, .{ .first = 0x1e000, .last = 0x1e02a },
    .{ .first = 0x1e8d0, .last = 0x1e8d6 }, .{ .first = 0x1e944, .last = 0x1e94a },
    .{ .first = 0xe0100, .last = 0xe01ef },
};

fn inIntervals(codepoint: u21, intervals: []const Interval) bool {
    for (intervals) |interval| {
        if (codepoint < interval.first) return false;
        if (codepoint <= interval.last) return true;
    }
    return false;
}

fn isWide(codepoint: u21) bool {
    return codepoint >= 0x1100 and (codepoint <= 0x115f or codepoint == 0x2329 or
        codepoint == 0x232a or
        (codepoint >= 0x2e80 and codepoint <= 0xa4cf and codepoint != 0x303f) or
        (codepoint >= 0xac00 and codepoint <= 0xd7a3) or
        (codepoint >= 0xf900 and codepoint <= 0xfaff) or
        (codepoint >= 0xfe10 and codepoint <= 0xfe19) or
        (codepoint >= 0xfe30 and codepoint <= 0xfe6f) or
        (codepoint >= 0xff00 and codepoint <= 0xff60) or
        (codepoint >= 0xffe0 and codepoint <= 0xffe6) or
        (codepoint >= 0x1f300 and codepoint <= 0x1faff) or
        (codepoint >= 0x20000 and codepoint <= 0x3fffd));
}

fn requiresSubstitution(codepoint: u21) bool {
    return codepoint < 0x20 or codepoint == 0x7f or
        Utf8.isTerminalUnsafeScalar(codepoint) or
        codepoint == 0x00ad or codepoint == 0x034f or
        codepoint == 0x115f or codepoint == 0x1160 or codepoint == 0x180e or
        (codepoint >= 0x206a and codepoint <= 0x206f) or
        codepoint == 0x3164 or codepoint == 0xffa0 or
        (codepoint >= 0xfff9 and codepoint <= 0xfffb) or
        (codepoint >= 0xe0000 and codepoint <= 0xe007f);
}

fn codepointWidth(codepoint: u21) ?u2 {
    if (requiresSubstitution(codepoint)) return null;
    if (inIntervals(codepoint, &combining)) return 0;
    return if (isWide(codepoint)) 2 else 1;
}

fn decode(input: []const u8, offset: usize) ?Glyph {
    if (offset >= input.len) return null;

    const byte = input[offset];
    const sequence_len = std.unicode.utf8ByteSequenceLength(byte) catch
        return substitutedGlyph();
    if (sequence_len > input.len - offset) return substitutedGlyph();

    const bytes = input[offset..][0..sequence_len];
    if (!std.unicode.utf8ValidateSlice(bytes)) return substitutedGlyph();
    const codepoint: u21 = switch (sequence_len) {
        1 => byte,
        2 => std.unicode.utf8Decode2(bytes[0..2].*) catch return substitutedGlyph(),
        3 => std.unicode.utf8Decode3(bytes[0..3].*) catch return substitutedGlyph(),
        4 => std.unicode.utf8Decode4(bytes[0..4].*) catch return substitutedGlyph(),
        else => unreachable,
    };
    const width = codepointWidth(codepoint) orelse return .{
        .bytes = substitute,
        .consumed = @intCast(sequence_len),
        .width = 1,
        .is_ascii_space = false,
    };
    return .{
        .bytes = bytes,
        .consumed = @intCast(sequence_len),
        .width = width,
        .is_ascii_space = sequence_len == 1 and byte == ' ',
    };
}

fn substitutedGlyph() Glyph {
    return .{
        .bytes = substitute,
        .consumed = 1,
        .width = 1,
        .is_ascii_space = false,
    };
}

fn expectGlyph(
    expected_bytes: []const u8,
    expected_consumed: u3,
    expected_width: u2,
    expected_space: bool,
    actual: ?Glyph,
) !void {
    const glyph = actual orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings(expected_bytes, glyph.bytes);
    try std.testing.expectEqual(expected_consumed, glyph.consumed);
    try std.testing.expectEqual(expected_width, glyph.width);
    try std.testing.expectEqual(expected_space, glyph.is_ascii_space);
}

test "ASCII glyphs and offsets are bounded" {
    try expectGlyph(" ", 1, 1, true, next(" a", 0));
    try expectGlyph("a", 1, 1, false, next(" a", 1));
    try std.testing.expect(next("a", 1) == null);
    try std.testing.expect(next("a", std.math.maxInt(usize)) == null);
}

test "iterator borrows valid UTF-8 and advances by decoded bytes" {
    var glyphs = iterator("é界");
    try expectGlyph("é", 2, 1, false, glyphs.next());
    try std.testing.expectEqual(2, glyphs.offset);
    try expectGlyph("界", 3, 2, false, glyphs.next());
    try std.testing.expectEqual(5, glyphs.offset);
    try std.testing.expect(glyphs.next() == null);
}

test "malformed UTF-8 substitutes each byte deterministically" {
    var glyphs = iterator("\xed\xa0\x80\xf4\x90\x80\x80\xc2");
    var count: usize = 0;
    while (glyphs.next()) |glyph| {
        try std.testing.expectEqualStrings("?", glyph.bytes);
        try std.testing.expectEqual(1, glyph.consumed);
        try std.testing.expectEqual(1, glyph.width);
        count += 1;
    }
    try std.testing.expectEqual(8, count);
}

test "C0 C1 bidi and invisible format scalars substitute" {
    var glyphs = iterator("\x00\t\xc2\x85\xe2\x80\xae\xe2\x80\x8b\xef\xbb\xbf");
    const consumed = [_]u3{ 1, 1, 2, 3, 3, 3 };
    for (consumed) |expected| {
        try expectGlyph("?", expected, 1, false, glyphs.next());
    }
    try std.testing.expect(glyphs.next() == null);
}

test "combining marks occupy zero cells across Unicode planes" {
    try expectGlyph("\xcc\x81", 2, 0, false, next("\xcc\x81", 0));
    try expectGlyph("\xe2\x83\xa3", 3, 0, false, next("\xe2\x83\xa3", 0));
    try expectGlyph("\xf0\x9d\x85\xa7", 4, 0, false, next("\xf0\x9d\x85\xa7", 0));
    try expectGlyph("\xf3\xa0\x84\x80", 4, 0, false, next("\xf3\xa0\x84\x80", 0));
}

test "East Asian and emoji widths are two while ambiguous text is one" {
    try expectGlyph("界", 3, 2, false, next("界", 0));
    try expectGlyph("😀", 4, 2, false, next("😀", 0));
    try expectGlyph("𠀀", 4, 2, false, next("𠀀", 0));
    try expectGlyph("·", 2, 1, false, next("·", 0));
}

test "visible width saturates and does not parse ANSI" {
    try std.testing.expectEqual(4, visibleWidth("A界e\xcc\x81", 100));
    try std.testing.expectEqual(3, visibleWidth("界界界", 3));
    try std.testing.expectEqual(0, visibleWidth("anything", 0));
    try std.testing.expectEqual(5, visibleWidth("\x1b[31m", 100));
}
