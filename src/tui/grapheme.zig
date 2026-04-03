const std = @import("std");

/// Returns the display width (in terminal columns) of a Unicode codepoint.
/// 0 for combining marks, zero-width chars, controls.
/// 2 for CJK ideographs, fullwidth forms, wide emoji.
/// 1 for everything else.
pub fn charWidth(cp: u21) u2 {
    // fast path: printable ASCII
    if (cp >= 0x20 and cp <= 0x7E) return 1;

    // --- width 0 ---

    // C0 controls + DEL
    if (cp <= 0x1F or cp == 0x7F) return 0;

    // combining diacriticals
    if (cp >= 0x0300 and cp <= 0x036F) return 0;

    // cyrillic combining
    if (cp >= 0x0483 and cp <= 0x0489) return 0;

    // hebrew combining
    if (cp >= 0x0591 and cp <= 0x05BD) return 0;
    if (cp == 0x05BF) return 0;
    if (cp >= 0x05C1 and cp <= 0x05C2) return 0;
    if (cp >= 0x05C4 and cp <= 0x05C5) return 0;
    if (cp == 0x05C7) return 0;

    // arabic combining
    if (cp >= 0x0610 and cp <= 0x061A) return 0;
    if (cp >= 0x064B and cp <= 0x065F) return 0;
    if (cp == 0x0670) return 0;

    // zero-width space, joiners, directional marks
    if (cp >= 0x200B and cp <= 0x200F) return 0;

    // line/paragraph separators, directional formatting
    if (cp >= 0x2028 and cp <= 0x202E) return 0;

    // word joiner, invisible chars
    if (cp >= 0x2060 and cp <= 0x2069) return 0;

    // variation selectors
    if (cp >= 0xFE00 and cp <= 0xFE0F) return 0;

    // BOM / ZWNBSP
    if (cp == 0xFEFF) return 0;

    // variation selectors supplement
    if (cp >= 0xE0100 and cp <= 0xE01EF) return 0;

    // --- width 2 ---

    // hangul jamo
    if (cp >= 0x1100 and cp <= 0x115F) return 2;

    // CJK radicals, kangxi, CJK symbols
    if (cp >= 0x2E80 and cp <= 0x303E) return 2;

    // hiragana, katakana, bopomofo, etc.
    if (cp >= 0x3041 and cp <= 0x33BF) return 2;

    // CJK unified extension A
    if (cp >= 0x3400 and cp <= 0x4DBF) return 2;

    // CJK unified ideographs, Yi
    if (cp >= 0x4E00 and cp <= 0xA4CF) return 2;

    // hangul syllables
    if (cp >= 0xAC00 and cp <= 0xD7A3) return 2;

    // CJK compatibility ideographs
    if (cp >= 0xF900 and cp <= 0xFAFF) return 2;

    // CJK compatibility forms
    if (cp >= 0xFE30 and cp <= 0xFE6F) return 2;

    // fullwidth forms
    if (cp >= 0xFF01 and cp <= 0xFF60) return 2;

    // fullwidth signs
    if (cp >= 0xFFE0 and cp <= 0xFFE6) return 2;

    // miscellaneous symbols / emoji
    if (cp >= 0x1F300 and cp <= 0x1F9FF) return 2;

    // CJK extension B+
    if (cp >= 0x20000 and cp <= 0x2FFFF) return 2;

    // CJK extension G+
    if (cp >= 0x30000 and cp <= 0x3FFFF) return 2;

    return 1;
}

/// Returns the total display width (in terminal columns) of a UTF-8 string.
pub fn strWidth(text: []const u8) usize {
    var cols: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            i += 1;
            cols += 1;
            continue;
        };
        if (i + len > text.len) break;
        const cp = std.unicode.utf8Decode(text[i..][0..len]) catch {
            i += 1;
            cols += 1;
            continue;
        };
        cols += @as(usize, charWidth(cp));
        i += len;
    }
    return cols;
}

/// Returns the longest prefix of `text` that fits within `max_cols` display columns.
/// Never splits a multi-byte codepoint.
pub fn sliceToWidth(text: []const u8, max_cols: usize) []const u8 {
    var cols: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            if (cols + 1 > max_cols) break;
            cols += 1;
            i += 1;
            continue;
        };
        if (i + len > text.len) break;
        const cp = std.unicode.utf8Decode(text[i..][0..len]) catch {
            if (cols + 1 > max_cols) break;
            cols += 1;
            i += 1;
            continue;
        };
        const w: usize = @as(usize, charWidth(cp));
        if (cols + w > max_cols) break;
        cols += w;
        i += len;
    }
    return text[0..i];
}

// --- tests ---

test "ASCII characters are width 1" {
    try std.testing.expectEqual(@as(u2, 1), charWidth('A'));
    try std.testing.expectEqual(@as(u2, 1), charWidth(' '));
    try std.testing.expectEqual(@as(u2, 1), charWidth('~'));
}

test "CJK characters are width 2" {
    try std.testing.expectEqual(@as(u2, 2), charWidth(0x4E00));
    try std.testing.expectEqual(@as(u2, 2), charWidth(0x3042));
    try std.testing.expectEqual(@as(u2, 2), charWidth(0xAC00));
}

test "combining marks are width 0" {
    try std.testing.expectEqual(@as(u2, 0), charWidth(0x0300));
    try std.testing.expectEqual(@as(u2, 0), charWidth(0x200B));
    try std.testing.expectEqual(@as(u2, 0), charWidth(0xFE0F));
}

test "control characters are width 0" {
    try std.testing.expectEqual(@as(u2, 0), charWidth(0x00));
    try std.testing.expectEqual(@as(u2, 0), charWidth(0x1B));
    try std.testing.expectEqual(@as(u2, 0), charWidth(0x7F));
}

test "strWidth counts display columns" {
    try std.testing.expectEqual(@as(usize, 5), strWidth("hello"));
    try std.testing.expectEqual(@as(usize, 0), strWidth(""));
}

test "strWidth with wide chars" {
    try std.testing.expectEqual(@as(usize, 4), strWidth("一二"));
}

test "sliceToWidth truncates correctly" {
    const result = sliceToWidth("hello", 3);
    try std.testing.expectEqualStrings("hel", result);
}

test "sliceToWidth respects wide char boundaries" {
    const result = sliceToWidth("一二三", 3);
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqual(@as(usize, 2), strWidth(result));
}
