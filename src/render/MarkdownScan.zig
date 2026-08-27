const std = @import("std");

/// Classification of a physical Markdown line prefix.
pub const LineKind = enum {
    incomplete,
    text,
    blank,
    heading,
    fence,
    thematic,
    bullet,
    ordered,
    blockquote,
    pipe,
};

/// Allocation-free classification metadata for one physical line prefix.
pub const LineInfo = struct {
    kind: LineKind,
    indent_length: usize,
    marker_length: usize = 0,
    marker: u8 = 0,
    /// False when more bytes may refine the result. `kind` can still identify a definite block.
    classification_complete: bool = true,
    normalize_indent: bool = false,
};

fn lineInfo(kind: LineKind, indent_length: usize) LineInfo {
    return .{ .kind = kind, .indent_length = indent_length };
}

fn incompleteLine(indent_length: usize) LineInfo {
    return .{
        .kind = .incomplete,
        .indent_length = indent_length,
        .classification_complete = false,
    };
}

/// Classifies a borrowed physical line prefix without allocating.
///
/// Input follows the SafeText contract: CR bytes are removed upstream, matching
/// the reference implementation, which likewise classifies a bare '\r' as text.
/// When `final` is false, ambiguous prefixes remain incomplete. A result can
/// already have a definite block kind while `classification_complete` is false.
/// When `final` is true, EOF resolves ambiguous prefixes as literal text.
pub fn scan(line: []const u8, final: bool) LineInfo {
    var marker_offset: usize = 0;
    var has_tab = false;
    while (marker_offset < line.len and (line[marker_offset] == ' ' or line[marker_offset] == '\t')) {
        if (line[marker_offset] == '\t') has_tab = true;
        marker_offset += 1;
    }

    if (marker_offset >= line.len) {
        return if (final) lineInfo(.text, marker_offset) else incompleteLine(marker_offset);
    }

    if (line[marker_offset] == '\n') {
        var info = lineInfo(.blank, marker_offset);
        info.normalize_indent = true;
        return info;
    }

    const block_indent = !has_tab and marker_offset <= 3;
    const marker = line[marker_offset];

    if (block_indent and marker == '#') {
        var end = marker_offset;
        while (end < line.len and end - marker_offset < 6 and line[end] == '#') end += 1;
        if (end >= line.len) return if (final) lineInfo(.text, marker_offset) else incompleteLine(marker_offset);
        if (line[end] == ' ' or line[end] == '\n') {
            var info = lineInfo(.heading, marker_offset);
            info.marker = marker;
            info.marker_length = end - marker_offset;
            info.normalize_indent = true;
            return info;
        }
        return lineInfo(.text, marker_offset);
    }

    if (block_indent and marker == '`') {
        const available = line.len - marker_offset;
        if (available < 3) return if (final) lineInfo(.text, marker_offset) else incompleteLine(marker_offset);
        if (line[marker_offset + 1] == '`' and line[marker_offset + 2] == '`') {
            var end = marker_offset + 3;
            while (end < line.len and line[end] == '`') end += 1;
            var info = lineInfo(.fence, marker_offset);
            info.marker = marker;
            info.marker_length = end - marker_offset;
            info.normalize_indent = true;
            while (end < line.len and line[end] != '\n') end += 1;
            if (end >= line.len) {
                if (final) return lineInfo(.text, marker_offset);
                info.classification_complete = false;
            }
            return info;
        }
        return lineInfo(.text, marker_offset);
    }

    var bullet = false;
    if (!has_tab and (marker == '*' or marker == '-' or marker == '+')) {
        if (marker_offset + 1 >= line.len) {
            if (!final) return incompleteLine(marker_offset);
        } else if (line[marker_offset + 1] == ' ') {
            bullet = true;
        }
    }

    if (block_indent and (marker == '-' or marker == '*' or marker == '_' or marker == '=')) {
        var end = marker_offset;
        var count: usize = 0;
        while (end < line.len and (line[end] == marker or line[end] == ' ' or line[end] == '\t' or
            line[end] == '\r'))
        {
            if (line[end] == marker) count += 1;
            end += 1;
        }
        if (end >= line.len) {
            if (final and count >= 3) {
                var info = lineInfo(.thematic, marker_offset);
                info.marker = marker;
                info.marker_length = count;
                info.normalize_indent = true;
                return info;
            }
            if (!final and bullet) {
                var info = lineInfo(.bullet, marker_offset);
                info.marker = marker;
                info.marker_length = 1;
                info.classification_complete = false;
                return info;
            }
            return if (final) lineInfo(.text, marker_offset) else incompleteLine(marker_offset);
        }
        if (line[end] == '\n' and count >= 3) {
            var info = lineInfo(.thematic, marker_offset);
            info.marker = marker;
            info.marker_length = count;
            info.normalize_indent = true;
            return info;
        }
    }

    if (bullet) {
        var info = lineInfo(.bullet, marker_offset);
        info.marker = marker;
        info.marker_length = 1;
        return info;
    }

    if (!has_tab and marker >= '0' and marker <= '9') {
        var end = marker_offset;
        while (end < line.len and line[end] >= '0' and line[end] <= '9') end += 1;
        if (end >= line.len or end + 1 >= line.len) {
            return if (final) lineInfo(.text, marker_offset) else incompleteLine(marker_offset);
        }
        if ((line[end] == '.' or line[end] == ')') and line[end + 1] == ' ') {
            var info = lineInfo(.ordered, marker_offset);
            info.marker = line[end];
            info.marker_length = end - marker_offset + 1;
            return info;
        }
    }

    if (block_indent and marker == '>') {
        var info = lineInfo(.blockquote, marker_offset);
        info.marker = marker;
        info.marker_length = 1;
        info.normalize_indent = true;
        return info;
    }

    if (block_indent and marker == '|') {
        var info = lineInfo(.pipe, marker_offset);
        info.marker = marker;
        info.marker_length = 1;
        info.normalize_indent = true;
        return info;
    }

    return lineInfo(.text, marker_offset);
}

fn expectLine(input: []const u8, final: bool, expected: LineInfo) !void {
    try std.testing.expectEqual(expected, scan(input, final));
}

test "blank and text lines" {
    try expectLine("", false, .{ .kind = .incomplete, .indent_length = 0, .classification_complete = false });
    try expectLine("   ", false, .{ .kind = .incomplete, .indent_length = 3, .classification_complete = false });
    try expectLine(" \t\n", false, .{ .kind = .blank, .indent_length = 2, .normalize_indent = true });
    try expectLine("plain", false, .{ .kind = .text, .indent_length = 0 });
    try expectLine("    # heading\n", false, .{ .kind = .text, .indent_length = 4 });
}

test "heading and fence lines" {
    try expectLine("#", false, .{ .kind = .incomplete, .indent_length = 0, .classification_complete = false });
    try expectLine("  ## heading\n", false, .{
        .kind = .heading,
        .indent_length = 2,
        .marker_length = 2,
        .marker = '#',
        .normalize_indent = true,
    });
    try expectLine("######\n", false, .{
        .kind = .heading,
        .indent_length = 0,
        .marker_length = 6,
        .marker = '#',
        .normalize_indent = true,
    });
    try expectLine("#######\n", false, .{ .kind = .text, .indent_length = 0 });
    try expectLine("##not\n", false, .{ .kind = .text, .indent_length = 0 });
    try expectLine("``", false, .{ .kind = .incomplete, .indent_length = 0, .classification_complete = false });
    try expectLine("```", false, .{
        .kind = .fence,
        .indent_length = 0,
        .marker_length = 3,
        .marker = '`',
        .classification_complete = false,
        .normalize_indent = true,
    });
    try expectLine(" ```c\n", false, .{
        .kind = .fence,
        .indent_length = 1,
        .marker_length = 3,
        .marker = '`',
        .normalize_indent = true,
    });
}

test "thematic and list lines" {
    try expectLine("* ", false, .{
        .kind = .bullet,
        .indent_length = 0,
        .marker_length = 1,
        .marker = '*',
        .classification_complete = false,
    });
    try expectLine("* item", false, .{ .kind = .bullet, .indent_length = 0, .marker_length = 1, .marker = '*' });
    try expectLine("+ ", false, .{ .kind = .bullet, .indent_length = 0, .marker_length = 1, .marker = '+' });
    try expectLine("  * * *\n", false, .{
        .kind = .thematic,
        .indent_length = 2,
        .marker_length = 3,
        .marker = '*',
        .normalize_indent = true,
    });
    try expectLine("---\n", false, .{
        .kind = .thematic,
        .indent_length = 0,
        .marker_length = 3,
        .marker = '-',
        .normalize_indent = true,
    });
    try expectLine("---", false, .{ .kind = .incomplete, .indent_length = 0, .classification_complete = false });
    try expectLine("---x\n", false, .{ .kind = .text, .indent_length = 0 });
    try expectLine("    * item", false, .{ .kind = .bullet, .indent_length = 4, .marker_length = 1, .marker = '*' });
    try expectLine("\t* item", false, .{ .kind = .text, .indent_length = 1 });
}

test "ordered, blockquote, and leading pipe lines" {
    try expectLine("  12) item", false, .{ .kind = .ordered, .indent_length = 2, .marker_length = 3, .marker = ')' });
    try expectLine("    1. item", false, .{ .kind = .ordered, .indent_length = 4, .marker_length = 2, .marker = '.' });
    try expectLine("1", false, .{ .kind = .incomplete, .indent_length = 0, .classification_complete = false });
    try expectLine("1x", false, .{ .kind = .incomplete, .indent_length = 0, .classification_complete = false });
    try expectLine("1xy", false, .{ .kind = .text, .indent_length = 0 });
    try expectLine("  > quote", false, .{
        .kind = .blockquote,
        .indent_length = 2,
        .marker_length = 1,
        .marker = '>',
        .normalize_indent = true,
    });
    try expectLine("   | A |", false, .{
        .kind = .pipe,
        .indent_length = 3,
        .marker_length = 1,
        .marker = '|',
        .normalize_indent = true,
    });
    try expectLine("    > quote", false, .{ .kind = .text, .indent_length = 4 });
}

test "EOF resolves ambiguous prefixes" {
    try expectLine("", true, .{ .kind = .text, .indent_length = 0 });
    try expectLine("  ", true, .{ .kind = .text, .indent_length = 2 });
    try expectLine("#", true, .{ .kind = .text, .indent_length = 0 });
    try expectLine("```", true, .{ .kind = .text, .indent_length = 0 });
    try expectLine("---", true, .{
        .kind = .thematic,
        .indent_length = 0,
        .marker_length = 3,
        .marker = '-',
        .normalize_indent = true,
    });
    try expectLine("===", true, .{
        .kind = .thematic,
        .indent_length = 0,
        .marker_length = 3,
        .marker = '=',
        .normalize_indent = true,
    });
    try expectLine("* ", true, .{ .kind = .text, .indent_length = 0 });
    try expectLine("+ ", true, .{ .kind = .bullet, .indent_length = 0, .marker_length = 1, .marker = '+' });
    try expectLine("1. ", true, .{ .kind = .ordered, .indent_length = 0, .marker_length = 2, .marker = '.' });
    try expectLine("1.", true, .{ .kind = .text, .indent_length = 0 });
}

fn expectPrefixKinds(input: []const u8, expected: []const LineKind) !void {
    try std.testing.expectEqual(input.len + 1, expected.len);
    for (expected, 0..) |kind, cut| {
        try std.testing.expectEqual(kind, scan(input[0..cut], false).kind);
    }
}

test "every prefix cut preserves definite block classifications" {
    try expectPrefixKinds("  ## heading\n", &.{
        .incomplete, .incomplete, .incomplete, .incomplete, .incomplete,
        .heading,    .heading,    .heading,    .heading,    .heading,
        .heading,    .heading,    .heading,    .heading,
    });
    try expectPrefixKinds(" ```c\n", &.{
        .incomplete, .incomplete, .incomplete, .incomplete, .fence, .fence, .fence,
    });
    try expectPrefixKinds("  * * *\n", &.{
        .incomplete, .incomplete, .incomplete, .incomplete, .bullet, .bullet,
        .bullet,     .bullet,     .thematic,
    });
    try expectPrefixKinds("  12) item", &.{
        .incomplete, .incomplete, .incomplete, .incomplete, .incomplete, .incomplete,
        .ordered,    .ordered,    .ordered,    .ordered,    .ordered,
    });
    try expectPrefixKinds("   | A |", &.{
        .incomplete, .incomplete, .incomplete, .incomplete, .pipe, .pipe, .pipe,
        .pipe,       .pipe,
    });
}
