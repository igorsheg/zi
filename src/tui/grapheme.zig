const std = @import("std");

pub const WidthMethod = enum {
    /// Terminal wcwidth-compatible behavior. This is the conservative default
    /// for multiplexers and terminals that do not support explicit Unicode width.
    wcwidth,
    /// Unicode/emoji-biased behavior for modern terminals.
    unicode,
};

const Decoded = struct {
    cp: u21,
    len: usize,
};

pub const Cluster = struct {
    bytes: []const u8,
    width: u2,
    single_codepoint: ?u21,
};

/// Returns the display width (in terminal columns) of a Unicode codepoint.
/// 0 for combining marks, zero-width chars, controls.
/// 2 for CJK ideographs, fullwidth forms, wide emoji.
/// 1 for everything else.
pub fn charWidth(cp: u21, method: WidthMethod) u2 {
    if (cp >= 0x20 and cp <= 0x7E) return 1;

    if (cp <= 0x1F or cp == 0x7F) return 0;

    if (cp >= 0x0300 and cp <= 0x036F) return 0;
    if (cp >= 0x1AB0 and cp <= 0x1AFF) return 0;
    if (cp >= 0x1DC0 and cp <= 0x1DFF) return 0;
    if (cp >= 0x20D0 and cp <= 0x20FF) return 0;
    if (cp >= 0xFE20 and cp <= 0xFE2F) return 0;

    if (cp >= 0x0483 and cp <= 0x0489) return 0;

    if (cp >= 0x0591 and cp <= 0x05BD) return 0;
    if (cp == 0x05BF) return 0;
    if (cp >= 0x05C1 and cp <= 0x05C2) return 0;
    if (cp >= 0x05C4 and cp <= 0x05C5) return 0;
    if (cp == 0x05C7) return 0;

    if (cp >= 0x0610 and cp <= 0x061A) return 0;
    if (cp >= 0x064B and cp <= 0x065F) return 0;
    if (cp == 0x0670) return 0;
    if (cp >= 0x06D6 and cp <= 0x06ED) return 0;

    if (cp >= 0x200B and cp <= 0x200F) return 0;

    if (cp >= 0x2028 and cp <= 0x202E) return 0;

    if (cp >= 0x2060 and cp <= 0x2069) return 0;

    if (cp >= 0xFE00 and cp <= 0xFE0F) return 0;

    if (cp == 0xFEFF) return 0;

    if (cp >= 0xE0100 and cp <= 0xE01EF) return 0;

    if (cp >= 0x1100 and cp <= 0x115F) return 2;

    if (cp >= 0x2E80 and cp <= 0x303E) return 2;

    if (cp >= 0x3041 and cp <= 0x33BF) return 2;

    if (cp >= 0x3400 and cp <= 0x4DBF) return 2;

    if (cp >= 0x4E00 and cp <= 0xA4CF) return 2;

    if (cp >= 0xAC00 and cp <= 0xD7A3) return 2;

    if (cp >= 0xF900 and cp <= 0xFAFF) return 2;

    if (cp >= 0xFE30 and cp <= 0xFE6F) return 2;

    if (cp >= 0xFF01 and cp <= 0xFF60) return 2;

    if (cp >= 0xFFE0 and cp <= 0xFFE6) return 2;

    if (cp >= 0x1F1E6 and cp <= 0x1F1FF) return 2;

    if (cp >= 0x1F300 and cp <= 0x1F9FF) return 2;
    if (method == .unicode and isEmojiPresentationCodepoint(cp)) return 2;

    if (cp >= 0x20000 and cp <= 0x2FFFF) return 2;

    if (cp >= 0x30000 and cp <= 0x3FFFF) return 2;

    return 1;
}

pub fn prevGraphemeBoundary(text: []const u8, byte_offset: usize, method: WidthMethod) usize {
    const clamped = @min(byte_offset, text.len);
    if (clamped == 0 or text.len == 0) return 0;

    var start: usize = 0;
    while (start < text.len) {
        const end = nextGraphemeBoundaryFromBoundary(text, start, method);
        if (end >= clamped) return start;
        start = end;
    }
    return 0;
}

pub fn nextGraphemeBoundary(text: []const u8, byte_offset: usize, method: WidthMethod) usize {
    const clamped = @min(byte_offset, text.len);
    if (clamped >= text.len or text.len == 0) return text.len;

    var start: usize = 0;
    while (start < text.len) {
        const end = nextGraphemeBoundaryFromBoundary(text, start, method);
        if (clamped <= start or clamped < end) return end;
        start = end;
    }
    return text.len;
}

/// Returns the total display width (in terminal columns) of a UTF-8 string.
pub fn strWidth(text: []const u8, method: WidthMethod) usize {
    var cols: usize = 0;
    var start: usize = 0;
    while (start < text.len) {
        const end = nextGraphemeBoundaryFromBoundary(text, start, method);
        cols += clusterWidth(text[start..end], method);
        start = end;
    }
    return cols;
}

/// Returns the longest prefix of `text` that fits within `max_cols` display columns.
/// Never splits a grapheme cluster.
pub fn sliceToWidth(text: []const u8, max_cols: usize, method: WidthMethod) []const u8 {
    var cols: usize = 0;
    var start: usize = 0;
    while (start < text.len) {
        const end = nextGraphemeBoundaryFromBoundary(text, start, method);
        const cluster_width = clusterWidth(text[start..end], method);
        if (cols + cluster_width > max_cols) break;
        cols += cluster_width;
        start = end;
    }
    return text[0..start];
}

pub fn nextGraphemeBoundaryFromBoundary(text: []const u8, start: usize, method: WidthMethod) usize {
    _ = method;
    if (start >= text.len) return text.len;

    const first = decodeAt(text, start);
    if (first.len == 0) return text.len;

    var prev = first;
    var prev_pos = start;
    var pos = start + first.len;
    var regional_indicator_count: u32 = if (isRegionalIndicator(first.cp)) 1 else 0;

    while (pos < text.len) {
        const current = decodeAt(text, pos);
        if (current.len == 0) break;
        if (isGraphemeBreak(text, start, prev_pos, prev.cp, pos, current.cp, regional_indicator_count)) {
            return pos;
        }

        if (isRegionalIndicator(prev.cp) and isRegionalIndicator(current.cp)) {
            regional_indicator_count += 1;
        } else {
            regional_indicator_count = if (isRegionalIndicator(current.cp)) 1 else 0;
        }

        prev_pos = pos;
        prev = current;
        pos += current.len;
    }

    return text.len;
}

pub fn clusterWidth(cluster: []const u8, method: WidthMethod) u2 {
    var raw_max: usize = 0;
    var visible_max: usize = 0;
    var pos: usize = 0;
    var has_zwj = false;
    var has_emoji_variation = false;
    var has_text_variation = false;
    var has_extended_pictographic = false;
    var regional_indicators: u32 = 0;

    while (pos < cluster.len) {
        const decoded = decodeAt(cluster, pos);
        if (decoded.len == 0) break;
        if (decoded.cp == 0x200D) has_zwj = true;
        if (decoded.cp == 0xFE0F) has_emoji_variation = true;
        if (decoded.cp == 0xFE0E) has_text_variation = true;
        if (isExtendedPictographic(decoded.cp)) has_extended_pictographic = true;
        if (isRegionalIndicator(decoded.cp)) regional_indicators += 1;

        const width: usize = @intCast(charWidth(decoded.cp, method));
        raw_max = @max(raw_max, width);
        if (!isExtend(decoded.cp) and decoded.cp != 0x200D and !isControl(decoded.cp)) {
            visible_max = @max(visible_max, width);
        }
        pos += decoded.len;
    }

    if (method == .unicode and !has_text_variation) {
        if (has_extended_pictographic and (has_emoji_variation or has_zwj)) return 2;
        if (regional_indicators >= 2) return 2;
    }

    return @intCast(@min(if (visible_max > 0) visible_max else raw_max, 2));
}

pub fn nextCluster(text: []const u8, start: usize, method: WidthMethod) ?Cluster {
    if (start >= text.len) return null;
    const end = nextGraphemeBoundaryFromBoundary(text, start, method);
    const bytes = text[start..end];
    const first = decodeAt(text, start);
    const single = if (first.len == bytes.len) first.cp else null;
    return .{
        .bytes = bytes,
        .width = clusterWidth(bytes, method),
        .single_codepoint = single,
    };
}

fn isGraphemeBreak(
    text: []const u8,
    cluster_start: usize,
    prev_pos: usize,
    prev_cp: u21,
    _: usize,
    curr_cp: u21,
    regional_indicator_count: u32,
) bool {
    if (prev_cp == '\r' and curr_cp == '\n') return false;

    if (isControl(prev_cp) or isControl(curr_cp)) return true;

    if (isHangulL(prev_cp) and (isHangulL(curr_cp) or isHangulV(curr_cp) or isHangulLV(curr_cp) or isHangulLVT(curr_cp))) return false;
    if ((isHangulLV(prev_cp) or isHangulV(prev_cp)) and (isHangulV(curr_cp) or isHangulT(curr_cp))) return false;
    if ((isHangulLVT(prev_cp) or isHangulT(prev_cp)) and isHangulT(curr_cp)) return false;

    if (isPrepend(prev_cp)) return false;

    if (isExtend(curr_cp) or curr_cp == 0x200D or isSpacingMark(curr_cp)) return false;

    if (prev_cp == 0x200D and isExtendedPictographic(curr_cp) and hasExtendedPictographicBeforeZwj(text, cluster_start, prev_pos)) {
        return false;
    }

    if (isRegionalIndicator(prev_cp) and isRegionalIndicator(curr_cp) and (regional_indicator_count % 2 == 1)) {
        return false;
    }

    return true;
}

fn hasExtendedPictographicBeforeZwj(text: []const u8, cluster_start: usize, zwj_pos: usize) bool {
    var pos = cluster_start;
    var last_non_extend: ?u21 = null;
    while (pos < zwj_pos) {
        const decoded = decodeAt(text, pos);
        if (decoded.len == 0) break;
        if (!isExtend(decoded.cp)) {
            last_non_extend = decoded.cp;
        }
        pos += decoded.len;
    }
    return if (last_non_extend) |cp| isExtendedPictographic(cp) else false;
}

fn decodeAt(text: []const u8, start: usize) Decoded {
    if (start >= text.len) return .{ .cp = 0xFFFD, .len = 0 };
    const len = std.unicode.utf8ByteSequenceLength(text[start]) catch return .{ .cp = 0xFFFD, .len = 1 };
    if (start + len > text.len) return .{ .cp = 0xFFFD, .len = 1 };
    const cp = std.unicode.utf8Decode(text[start..][0..len]) catch return .{ .cp = 0xFFFD, .len = 1 };
    return .{ .cp = cp, .len = len };
}

fn isControl(cp: u21) bool {
    return cp == '\r' or cp == '\n' or (cp <= 0x1F) or (cp >= 0x7F and cp <= 0x9F);
}

fn isExtend(cp: u21) bool {
    if (cp >= 0x0300 and cp <= 0x036F) return true;
    if (cp >= 0x0483 and cp <= 0x0489) return true;
    if (cp >= 0x0591 and cp <= 0x05BD) return true;
    if (cp == 0x05BF) return true;
    if (cp >= 0x05C1 and cp <= 0x05C2) return true;
    if (cp >= 0x05C4 and cp <= 0x05C5) return true;
    if (cp == 0x05C7) return true;
    if (cp >= 0x0610 and cp <= 0x061A) return true;
    if (cp >= 0x064B and cp <= 0x065F) return true;
    if (cp == 0x0670) return true;
    if (cp >= 0x06D6 and cp <= 0x06ED) return true;
    if (cp >= 0x1AB0 and cp <= 0x1AFF) return true;
    if (cp >= 0x1DC0 and cp <= 0x1DFF) return true;
    if (cp >= 0x20D0 and cp <= 0x20FF) return true;
    if (cp >= 0xFE00 and cp <= 0xFE0F) return true;
    if (cp >= 0xFE20 and cp <= 0xFE2F) return true;
    if (cp >= 0xE0100 and cp <= 0xE01EF) return true;
    if (cp >= 0x1F3FB and cp <= 0x1F3FF) return true;
    return false;
}

fn isSpacingMark(cp: u21) bool {
    return switch (cp) {
        0x0903,
        0x093B,
        0x093E...0x0940,
        0x0949...0x094C,
        0x094E...0x094F,
        0x0982...0x0983,
        0x09BE...0x09C0,
        0x09C7...0x09C8,
        0x09CB...0x09CC,
        0x0A3E...0x0A40,
        0x0A83,
        0x0ABE...0x0AC0,
        0x0AC9,
        0x0ACB...0x0ACC,
        0x0B02...0x0B03,
        0x0B3E,
        0x0B40,
        0x0B47...0x0B48,
        0x0B4B...0x0B4C,
        0x0BBE...0x0BBF,
        0x0BC1...0x0BC2,
        0x0BC6...0x0BC8,
        0x0BCA...0x0BCC,
        0x0C01...0x0C03,
        0x0C41...0x0C44,
        0x0C82...0x0C83,
        0x0CBE,
        0x0CC0...0x0CC4,
        0x0CC7...0x0CC8,
        0x0CCA...0x0CCB,
        0x0D02...0x0D03,
        0x0D3E...0x0D40,
        0x0D46...0x0D48,
        0x0D4A...0x0D4C,
        0x0D82...0x0D83,
        0x0DCF...0x0DD1,
        0x0DD8...0x0DDF,
        0x0DF2...0x0DF3,
        => true,
        else => false,
    };
}

fn isPrepend(cp: u21) bool {
    return switch (cp) {
        0x0600...0x0605,
        0x06DD,
        0x070F,
        0x0890...0x0891,
        0x08E2,
        0x0D4E,
        0x110BD,
        0x111C2...0x111C3,
        0x1193F,
        0x11941,
        0x11A3A,
        0x11A84...0x11A89,
        0x11D46,
        => true,
        else => false,
    };
}

fn isRegionalIndicator(cp: u21) bool {
    return cp >= 0x1F1E6 and cp <= 0x1F1FF;
}

fn isEmojiPresentationCodepoint(cp: u21) bool {
    return switch (cp) {
        0x231A...0x231B,
        0x23E9...0x23EC,
        0x23F0,
        0x23F3,
        0x25FD...0x25FE,
        0x2614...0x2615,
        0x2648...0x2653,
        0x267F,
        0x2693,
        0x26A1,
        0x26AA...0x26AB,
        0x26BD...0x26BE,
        0x26C4...0x26C5,
        0x26CE,
        0x26D4,
        0x26EA,
        0x26F2...0x26F3,
        0x26F5,
        0x26FA,
        0x26FD,
        0x2705,
        0x270A...0x270B,
        0x2728,
        0x274C,
        0x274E,
        0x2753...0x2755,
        0x2757,
        0x2795...0x2797,
        0x27B0,
        0x27BF,
        0x2B1B...0x2B1C,
        0x2B50,
        0x2B55,
        => true,
        else => false,
    };
}

fn isExtendedPictographic(cp: u21) bool {
    if (cp >= 0x1F000 and cp <= 0x1FAFF) return true;
    return switch (cp) {
        0x00A9,
        0x00AE,
        0x203C,
        0x2049,
        0x2122,
        0x2139,
        0x2328,
        0x23CF,
        0x24C2,
        0x3030,
        0x303D,
        0x3297,
        0x3299,
        => true,
        0x2194...0x2199,
        0x21A9...0x21AA,
        0x231A...0x231B,
        0x23E9...0x23FA,
        0x25AA...0x25AB,
        0x25B6,
        0x25C0,
        0x25FB...0x25FE,
        0x2600...0x27BF,
        0x2934...0x2935,
        0x2B05...0x2B55,
        => true,
        else => false,
    };
}

fn isHangulL(cp: u21) bool {
    return (cp >= 0x1100 and cp <= 0x115F) or (cp >= 0xA960 and cp <= 0xA97C);
}

fn isHangulV(cp: u21) bool {
    return (cp >= 0x1160 and cp <= 0x11A7) or (cp >= 0xD7B0 and cp <= 0xD7C6);
}

fn isHangulT(cp: u21) bool {
    return (cp >= 0x11A8 and cp <= 0x11FF) or (cp >= 0xD7CB and cp <= 0xD7FB);
}

fn isHangulLV(cp: u21) bool {
    if (cp < 0xAC00 or cp > 0xD7A3) return false;
    return ((cp - 0xAC00) % 28) == 0;
}

fn isHangulLVT(cp: u21) bool {
    if (cp < 0xAC00 or cp > 0xD7A3) return false;
    return ((cp - 0xAC00) % 28) != 0;
}

test "charWidth covers ASCII, wide, zero-width, and control ranges" {
    try std.testing.expectEqual(@as(u2, 1), charWidth('A', .wcwidth));
    try std.testing.expectEqual(@as(u2, 1), charWidth(' ', .wcwidth));
    try std.testing.expectEqual(@as(u2, 2), charWidth(0x4E00, .wcwidth));
    try std.testing.expectEqual(@as(u2, 2), charWidth(0x3042, .wcwidth));
    try std.testing.expectEqual(@as(u2, 0), charWidth(0x0300, .wcwidth));
    try std.testing.expectEqual(@as(u2, 0), charWidth(0x200B, .wcwidth));
    try std.testing.expectEqual(@as(u2, 0), charWidth(0x00, .wcwidth));
    try std.testing.expectEqual(@as(u2, 0), charWidth(0x1B, .wcwidth));
}

test "grapheme boundaries keep combining marks and emoji sequences atomic" {
    try std.testing.expectEqual(@as(usize, "e\u{0301}".len), nextGraphemeBoundary("e\u{0301}", 0, .wcwidth));
    try std.testing.expectEqual(@as(usize, "👋🏿".len), nextGraphemeBoundary("👋🏿", 0, .wcwidth));
    try std.testing.expectEqual(@as(usize, "👩‍🚀".len), nextGraphemeBoundary("👩‍🚀", 0, .wcwidth));
    try std.testing.expectEqual(@as(usize, "🇨🇦".len), nextGraphemeBoundary("🇨🇦", 0, .wcwidth));

    try std.testing.expectEqual(@as(usize, 0), prevGraphemeBoundary("e\u{0301}", "e\u{0301}".len, .wcwidth));
    try std.testing.expectEqual(@as(usize, 0), prevGraphemeBoundary("👋🏿", "👋🏿".len, .wcwidth));
    try std.testing.expectEqual(@as(usize, 0), prevGraphemeBoundary("👩‍🚀", "👩‍🚀".len, .wcwidth));
    try std.testing.expectEqual(@as(usize, 0), prevGraphemeBoundary("🇨🇦", "🇨🇦".len, .wcwidth));
}

test "strWidth sums grapheme cluster widths" {
    try std.testing.expectEqual(@as(usize, 5), strWidth("hello", .wcwidth));
    try std.testing.expectEqual(@as(usize, 0), strWidth("", .wcwidth));
    try std.testing.expectEqual(@as(usize, 4), strWidth("一二", .wcwidth));
    try std.testing.expectEqual(@as(usize, 1), strWidth("e\u{0301}", .wcwidth));
    try std.testing.expectEqual(@as(usize, 2), strWidth("👋🏿", .wcwidth));
    try std.testing.expectEqual(@as(usize, 2), strWidth("👩‍🚀", .wcwidth));
    try std.testing.expectEqual(@as(usize, 2), strWidth("🇨🇦", .wcwidth));
}

test "WidthMethod distinguishes emoji presentation clusters" {
    try std.testing.expectEqual(@as(usize, 1), strWidth("♥", .wcwidth));
    try std.testing.expectEqual(@as(usize, 1), strWidth("♥", .unicode));
    try std.testing.expectEqual(@as(usize, 1), strWidth("♥️", .wcwidth));
    try std.testing.expectEqual(@as(usize, 2), strWidth("♥️", .unicode));
    try std.testing.expectEqual(@as(usize, 1), strWidth("♥︎", .unicode));
    try std.testing.expectEqual(@as(usize, 2), strWidth("☕", .unicode));
}

test "unicode width treats emoji clusters as width two" {
    try std.testing.expectEqual(@as(usize, 2), strWidth("👩‍🚀", .unicode));
    try std.testing.expectEqual(@as(usize, 2), strWidth("🇨🇦", .unicode));
    try std.testing.expectEqual(@as(usize, 2), strWidth("👋🏿", .unicode));
}

test "sliceToWidth respects emoji presentation width" {
    try std.testing.expectEqualStrings("♥️", sliceToWidth("♥️x", 2, .unicode));
    try std.testing.expectEqualStrings("", sliceToWidth("♥️x", 1, .unicode));
    try std.testing.expectEqualStrings("♥️x", sliceToWidth("♥️x", 3, .unicode));
}

test "sliceToWidth truncates at grapheme boundary" {
    try std.testing.expectEqualStrings("hel", sliceToWidth("hello", 3, .wcwidth));
    const result = sliceToWidth("一二三", 3, .wcwidth);
    try std.testing.expectEqual(@as(usize, 2), strWidth(result, .wcwidth));
    try std.testing.expectEqualStrings("👩‍🚀", sliceToWidth("👩‍🚀x", 2, .wcwidth));
    try std.testing.expectEqualStrings("", sliceToWidth("👩‍🚀x", 1, .wcwidth));
}
