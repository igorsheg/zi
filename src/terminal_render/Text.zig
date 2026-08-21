const std = @import("std");
const uucode = @import("uucode");

/// OpenTUI's native utf8 implementation established the terminal-specific
/// grapheme and width rules used here. Zi keeps a smaller iterator shaped for
/// bounded frame construction and invalid input. See THIRD_PARTY_NOTICES.md.
pub const default_tab_width: u8 = 4;
pub const max_grapheme_bytes: usize = 128;

pub const Kind = enum {
    text,
    tab,
    line_break,
    replacement,
};

pub const Grapheme = struct {
    start_byte: usize,
    source_len: usize,
    bytes: []const u8,
    width: u8,
    kind: Kind,

    pub fn endByte(self: Grapheme) usize {
        return self.start_byte + self.source_len;
    }
};

pub const Iterator = struct {
    text: []const u8,
    index: usize = 0,

    pub fn init(text: []const u8) Iterator {
        return .{ .text = text };
    }

    pub fn next(self: *Iterator) ?Grapheme {
        if (self.index >= self.text.len) return null;
        const start = self.index;
        const first = decode(self.text, start);
        if (!first.valid) {
            self.index += first.byte_len;
            return replacement(start, first.byte_len);
        }
        if (first.codepoint == '\r') {
            var source_len = first.byte_len;
            if (start + source_len < self.text.len and self.text[start + source_len] == '\n') {
                source_len += 1;
            }
            self.index += source_len;
            return .{
                .start_byte = start,
                .source_len = source_len,
                .bytes = self.text[start..][0..source_len],
                .width = 0,
                .kind = .line_break,
            };
        }
        if (first.codepoint == '\n') {
            self.index += first.byte_len;
            return .{
                .start_byte = start,
                .source_len = first.byte_len,
                .bytes = self.text[start..][0..first.byte_len],
                .width = 0,
                .kind = .line_break,
            };
        }
        if (first.codepoint == '\t') {
            self.index += first.byte_len;
            return .{
                .start_byte = start,
                .source_len = first.byte_len,
                .bytes = self.text[start..][0..first.byte_len],
                .width = default_tab_width,
                .kind = .tab,
            };
        }
        if (isUnsafeControl(first.codepoint)) {
            self.index += first.byte_len;
            return replacement(start, first.byte_len);
        }

        var width_state = WidthState.init(first.codepoint);
        var break_state: uucode.grapheme.BreakState = .default;
        var previous = first.codepoint;
        var end = start + first.byte_len;
        while (end < self.text.len) {
            const current = decode(self.text, end);
            if (!current.valid or isSpecial(current.codepoint)) break;
            if (uucode.grapheme.isBreak(previous, current.codepoint, &break_state)) break;
            width_state.add(current.codepoint);
            previous = current.codepoint;
            end += current.byte_len;
        }
        self.index = end;
        if (end - start > max_grapheme_bytes) return replacement(start, end - start);
        return .{
            .start_byte = start,
            .source_len = end - start,
            .bytes = self.text[start..end],
            .width = width_state.width,
            .kind = .text,
        };
    }
};

pub fn displayWidth(text: []const u8) usize {
    var width: usize = 0;
    var iterator = Iterator.init(text);
    while (iterator.next()) |grapheme| {
        if (grapheme.kind == .line_break) break;
        width +|= grapheme.width;
    }
    return width;
}

pub fn previousBoundary(text: []const u8, byte_offset: usize) usize {
    const bounded = @min(byte_offset, text.len);
    if (bounded == 0) return 0;
    var iterator = Iterator.init(text);
    var previous: usize = 0;
    while (iterator.next()) |grapheme| {
        if (grapheme.endByte() >= bounded) return grapheme.start_byte;
        previous = grapheme.start_byte;
    }
    return previous;
}

pub fn nextBoundary(text: []const u8, byte_offset: usize) usize {
    const bounded = @min(byte_offset, text.len);
    if (bounded == text.len) return text.len;
    var iterator = Iterator.init(text);
    while (iterator.next()) |grapheme| {
        if (grapheme.endByte() > bounded) return grapheme.endByte();
    }
    return text.len;
}

const replacement_bytes = "�";

fn replacement(start: usize, source_len: usize) Grapheme {
    return .{
        .start_byte = start,
        .source_len = source_len,
        .bytes = replacement_bytes,
        .width = 1,
        .kind = .replacement,
    };
}

const Decoded = struct {
    codepoint: u21,
    byte_len: usize,
    valid: bool,
};

fn decode(bytes: []const u8, index: usize) Decoded {
    const sequence_len = std.unicode.utf8ByteSequenceLength(bytes[index]) catch {
        return .{ .codepoint = 0xfffd, .byte_len = 1, .valid = false };
    };
    if (sequence_len > bytes.len - index) {
        return .{ .codepoint = 0xfffd, .byte_len = 1, .valid = false };
    }
    const slice = bytes[index..][0..sequence_len];
    const codepoint = switch (sequence_len) {
        1 => slice[0],
        2 => std.unicode.utf8Decode2(slice[0..2].*) catch
            return .{ .codepoint = 0xfffd, .byte_len = 1, .valid = false },
        3 => std.unicode.utf8Decode3(slice[0..3].*) catch
            return .{ .codepoint = 0xfffd, .byte_len = 1, .valid = false },
        4 => std.unicode.utf8Decode4(slice[0..4].*) catch
            return .{ .codepoint = 0xfffd, .byte_len = 1, .valid = false },
        else => unreachable,
    };
    return .{ .codepoint = codepoint, .byte_len = sequence_len, .valid = true };
}

fn isSpecial(codepoint: u21) bool {
    return codepoint == '\n' or codepoint == '\r' or codepoint == '\t' or
        isUnsafeControl(codepoint);
}

fn isUnsafeControl(codepoint: u21) bool {
    return codepoint < 0x20 or (codepoint >= 0x7f and codepoint <= 0x9f);
}

fn codepointWidth(codepoint: u21) u8 {
    if (codepoint == 0) return 0;
    const category = uucode.get(.general_category, codepoint);
    switch (category) {
        .mark_nonspacing, .mark_spacing_combining, .mark_enclosing => return 0,
        else => {},
    }
    if (codepoint == 0x200b or codepoint == 0x200c or codepoint == 0x200d or
        codepoint == 0x2060 or codepoint == 0x034f or codepoint == 0xfeff or
        (codepoint >= 0x180b and codepoint <= 0x180d) or
        (codepoint >= 0xfe00 and codepoint <= 0xfe0f) or
        (codepoint >= 0xe0100 and codepoint <= 0xe01ef))
    {
        return 0;
    }
    const east_asian_width = uucode.get(.east_asian_width, codepoint);
    if (east_asian_width == .fullwidth or east_asian_width == .wide) return 2;
    if (uucode.get(.is_emoji_presentation, codepoint)) return 2;
    return 1;
}

const WidthState = struct {
    width: u8,
    has_width: bool,
    regional_indicator: bool,
    has_virama: bool = false,

    fn init(first: u21) WidthState {
        const width = codepointWidth(first);
        return .{
            .width = width,
            .has_width = width != 0,
            .regional_indicator = isRegionalIndicator(first),
        };
    }

    fn add(self: *WidthState, codepoint: u21) void {
        if (codepoint == 0xfe0f) {
            if (self.has_width and self.width == 1) self.width = 2;
            return;
        }
        const category = uucode.get(.general_category, codepoint);
        if (category == .mark_nonspacing) {
            self.has_virama = true;
            return;
        }
        const width = codepointWidth(codepoint);
        if (self.regional_indicator and isRegionalIndicator(codepoint)) {
            self.width = 2;
            self.has_width = true;
            return;
        }
        if (!self.has_width and width != 0) {
            self.width = width;
            self.has_width = true;
            return;
        }
        const devanagari_base = (codepoint >= 0x0915 and codepoint <= 0x0939) or
            (codepoint >= 0x0958 and codepoint <= 0x095f);
        if (self.has_virama and devanagari_base and codepoint != 0x0930 and width != 0) {
            self.width +|= width;
        }
        self.has_virama = false;
    }
};

fn isRegionalIndicator(codepoint: u21) bool {
    return codepoint >= 0x1f1e6 and codepoint <= 0x1f1ff;
}

test "iterator keeps extended grapheme clusters intact" {
    const family = "👨‍👩‍👧‍👦";
    var iterator = Iterator.init(family ++ "!");
    const cluster = iterator.next().?;
    try std.testing.expectEqualStrings(family, cluster.bytes);
    try std.testing.expectEqual(@as(u8, 2), cluster.width);
    try std.testing.expectEqual(@as(usize, family.len), cluster.source_len);
    try std.testing.expectEqualStrings("!", iterator.next().?.bytes);
}

test "iterator applies terminal width to flags combining marks and variation selectors" {
    var flag = Iterator.init("🇺🇦");
    try std.testing.expectEqual(@as(u8, 2), flag.next().?.width);
    var combining = Iterator.init("e\u{301}");
    const combined = combining.next().?;
    try std.testing.expectEqual(@as(u8, 1), combined.width);
    try std.testing.expectEqualStrings("e\u{301}", combined.bytes);
    var emoji = Iterator.init("♥️");
    try std.testing.expectEqual(@as(u8, 2), emoji.next().?.width);
}

test "iterator preserves layout controls before sanitizing unsafe controls" {
    var iterator = Iterator.init("a\t\r\nb\nc");
    try std.testing.expectEqual(Kind.text, iterator.next().?.kind);
    const tab = iterator.next().?;
    try std.testing.expectEqual(Kind.tab, tab.kind);
    try std.testing.expectEqual(@as(u8, default_tab_width), tab.width);
    const crlf = iterator.next().?;
    try std.testing.expectEqual(Kind.line_break, crlf.kind);
    try std.testing.expectEqual(@as(usize, 2), crlf.source_len);
    try std.testing.expectEqual(Kind.text, iterator.next().?.kind);
    try std.testing.expectEqual(Kind.line_break, iterator.next().?.kind);
}

test "iterator sanitizes controls invalid UTF-8 and oversized clusters" {
    var unsafe = Iterator.init("a\x1bb\xff");
    try std.testing.expectEqualStrings("a", unsafe.next().?.bytes);
    try std.testing.expectEqual(Kind.replacement, unsafe.next().?.kind);
    try std.testing.expectEqualStrings("b", unsafe.next().?.bytes);
    try std.testing.expectEqual(Kind.replacement, unsafe.next().?.kind);

    var bytes: [max_grapheme_bytes + 2]u8 = undefined;
    bytes[0] = 'e';
    var index: usize = 1;
    while (index < bytes.len - 1) : (index += 2) {
        bytes[index] = 0xcc;
        bytes[index + 1] = 0x81;
    }
    var oversized = Iterator.init(&bytes);
    const replacement_cluster = oversized.next().?;
    try std.testing.expectEqual(Kind.replacement, replacement_cluster.kind);
    try std.testing.expectEqualStrings(replacement_bytes, replacement_cluster.bytes);
}

test "grapheme boundaries drive editor motion" {
    const text = "a👨‍👩‍👧‍👦e\u{301}z";
    const family_start = 1;
    const family_end = family_start + "👨‍👩‍👧‍👦".len;
    const combined_end = family_end + "e\u{301}".len;
    try std.testing.expectEqual(family_start, nextBoundary(text, 0));
    try std.testing.expectEqual(family_end, nextBoundary(text, family_start));
    try std.testing.expectEqual(family_start, previousBoundary(text, family_end));
    try std.testing.expectEqual(family_end, previousBoundary(text, combined_end));
}
