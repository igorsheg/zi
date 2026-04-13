const std = @import("std");
const breaks_mod = @import("wrap/breaks.zig");

const Segment = breaks_mod.Segment;
const SegmentOptions = breaks_mod.SegmentOptions;

/// A wrapped display line represented as byte offsets into source text.
pub const Line = struct {
    start: usize,
    end: usize,

    pub fn text(self: Line, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }
};

const display_options = SegmentOptions{
    .trim_trailing_whitespace = true,
    .skip_leading_whitespace_on_continuation = true,
    .consume_overflow_whitespace = true,
};

/// Wrap plain UTF-8 text for display surfaces.
///
/// Policy:
/// - splits on explicit newlines first
/// - wraps at word boundaries when possible
/// - breaks long runs by grapheme width when needed
/// - strips leading whitespace on continuation lines
/// - trims trailing whitespace on all lines
///
/// Returns byte-offset pairs into `text`. Caller owns the returned slice.
pub fn wordWrap(text: []const u8, max_width: usize, allocator: std.mem.Allocator) ![]Line {
    if (max_width == 0) return try allocator.dupe(Line, &.{.{ .start = 0, .end = 0 }});

    var lines: std.ArrayListUnmanaged(Line) = .empty;
    errdefer lines.deinit(allocator);

    if (text.len == 0) {
        try lines.append(allocator, .{ .start = 0, .end = 0 });
        return try lines.toOwnedSlice(allocator);
    }

    var line_start: usize = 0;
    while (line_start <= text.len) {
        const newline_pos = std.mem.indexOfScalar(u8, text[line_start..], '\n');
        const line_end = if (newline_pos) |p| line_start + p else text.len;
        const input_line = text[line_start..line_end];

        try wrapSingleLine(input_line, line_start, max_width, &lines, allocator);

        if (newline_pos == null) break;
        line_start = line_end + 1;
        if (line_start == text.len + 1) break;
        if (line_start == text.len) {
            try lines.append(allocator, .{ .start = line_start, .end = line_start });
            break;
        }
    }

    if (lines.items.len == 0) {
        try lines.append(allocator, .{ .start = 0, .end = 0 });
    }

    return try lines.toOwnedSlice(allocator);
}

fn wrapSingleLine(
    line: []const u8,
    base_offset: usize,
    max_width: usize,
    lines: *std.ArrayListUnmanaged(Line),
    allocator: std.mem.Allocator,
) !void {
    if (line.len == 0) {
        try lines.append(allocator, .{ .start = base_offset, .end = base_offset });
        return;
    }

    var start: usize = 0;
    var continuation = false;
    while (true) {
        const segment = breaks_mod.nextSegment(line, start, max_width, continuation, display_options) orelse break;
        try appendLine(lines, base_offset, segment, allocator);
        if (segment.next_start >= line.len) break;
        start = segment.next_start;
        continuation = true;
    }

    if (lines.items.len == 0 or lines.items[lines.items.len - 1].start < base_offset) {
        try lines.append(allocator, .{ .start = base_offset, .end = base_offset });
    }
}

fn appendLine(lines: *std.ArrayListUnmanaged(Line), base_offset: usize, segment: Segment, allocator: std.mem.Allocator) !void {
    try lines.append(allocator, .{
        .start = base_offset + segment.start,
        .end = base_offset + segment.end,
    });
}

const testing = std.testing;

fn expectWrapped(text: []const u8, width: usize, expected: []const []const u8) !void {
    const lines = try wordWrap(text, width, testing.allocator);
    defer testing.allocator.free(lines);

    if (lines.len != expected.len) {
        std.debug.print("expected {} lines, got {}:\n", .{ expected.len, lines.len });
        for (lines, 0..) |l, i| {
            std.debug.print("  [{d}] \"{s}\"\n", .{ i, l.text(text) });
        }
        return error.TestUnexpectedResult;
    }

    for (expected, 0..) |exp, i| {
        const got = lines[i].text(text);
        if (!std.mem.eql(u8, got, exp)) {
            std.debug.print("line {d}: expected \"{s}\", got \"{s}\"\n", .{ i, exp, got });
            return error.TestUnexpectedResult;
        }
    }
}

test "display wrap preserves short lines and splits at word boundaries" {
    try expectWrapped("hello", 10, &.{"hello"});
    try expectWrapped("hello world", 5, &.{ "hello", "world" });
    try expectWrapped("the quick brown fox", 10, &.{ "the quick", "brown fox" });
    try expectWrapped("hi   ", 10, &.{"hi"});
}

test "display wrap handles newlines, empty input, and long words" {
    try expectWrapped("", 10, &.{""});
    try expectWrapped("a\nb", 10, &.{ "a", "b" });
    try expectWrapped("a\n\nb", 10, &.{ "a", "", "b" });
    try expectWrapped("a\n", 10, &.{ "a", "" });
    try expectWrapped("abcdefghij", 3, &.{ "abc", "def", "ghi", "j" });
}

test "display wrap handles wide characters and mixed content" {
    try expectWrapped("一二三", 4, &.{ "一二", "三" });
    try expectWrapped("hi一二", 4, &.{ "hi一", "二" });
}
