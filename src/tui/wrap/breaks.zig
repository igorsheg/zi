const std = @import("std");
const grapheme = @import("../grapheme.zig");

pub const SegmentOptions = struct {
    trim_trailing_whitespace: bool = false,
    skip_leading_whitespace_on_continuation: bool = false,
    consume_overflow_whitespace: bool = false,
};

pub const Segment = struct {
    start: usize,
    end: usize,
    next_start: usize,
    width_cols: u32,

    pub fn text(self: Segment, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }
};

pub fn nextSegment(
    line: []const u8,
    start: usize,
    max_width: usize,
    is_continuation: bool,
    options: SegmentOptions,
    width_method: grapheme.WidthMethod,
) ?Segment {
    if (start >= line.len) return null;
    if (max_width == 0) {
        return .{ .start = start, .end = start, .next_start = start, .width_cols = 0 };
    }

    var line_begin = start;
    if (is_continuation and options.skip_leading_whitespace_on_continuation) {
        line_begin = skipWhitespace(line, line_begin);
        if (line_begin >= line.len) return null;
    }

    var current_start = line_begin;
    var current_width: usize = 0;

    while (current_start < line.len) {
        const token = nextToken(line, current_start);
        const token_width = token.width(line, width_method);
        const token_is_whitespace = isWhitespace(line[token.start]);

        if (token_width > max_width) {
            if (current_width > 0) {
                const end = applyTrim(line, line_begin, current_start, options);
                return .{
                    .start = line_begin,
                    .end = end,
                    .next_start = current_start,
                    .width_cols = @intCast(current_width),
                };
            }

            const piece_end = breakPiece(line, token.start, token.end, max_width, width_method);
            const end = applyTrim(line, line_begin, piece_end, options);
            return .{
                .start = line_begin,
                .end = end,
                .next_start = piece_end,
                .width_cols = @intCast(grapheme.strWidth(line[line_begin..end], width_method)),
            };
        }

        if (current_width + token_width > max_width and current_width > 0) {
            if (token_is_whitespace) {
                const raw_end = if (options.consume_overflow_whitespace) token.start else token.end;
                const next_start = token.end;
                const end = applyTrim(line, line_begin, raw_end, options);
                return .{
                    .start = line_begin,
                    .end = end,
                    .next_start = next_start,
                    .width_cols = @intCast(current_width),
                };
            }

            const end = applyTrim(line, line_begin, current_start, options);
            return .{
                .start = line_begin,
                .end = end,
                .next_start = current_start,
                .width_cols = @intCast(current_width),
            };
        }

        current_start = token.end;
        current_width += token_width;
    }

    const end = applyTrim(line, line_begin, current_start, options);
    return .{
        .start = line_begin,
        .end = end,
        .next_start = current_start,
        .width_cols = @intCast(current_width),
    };
}

pub const Token = struct {
    start: usize,
    end: usize,
    ascii_printable: bool,

    pub fn text(self: Token, line: []const u8) []const u8 {
        return line[self.start..self.end];
    }

    pub fn width(self: Token, line: []const u8, width_method: grapheme.WidthMethod) usize {
        if (self.ascii_printable) return self.end - self.start;
        return grapheme.strWidth(self.text(line), width_method);
    }
};

pub fn nextToken(line: []const u8, start: usize) Token {
    if (start >= line.len) return .{ .start = start, .end = start, .ascii_printable = true };
    const is_ws = isWhitespace(line[start]);
    var pos = start;
    var ascii_printable = true;
    while (pos < line.len) : (pos += 1) {
        const c = line[pos];
        if (isWhitespace(c) != is_ws) break;
        if (c < 0x20 or c > 0x7E) ascii_printable = false;
    }
    return .{ .start = start, .end = pos, .ascii_printable = ascii_printable };
}

pub fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t';
}

pub fn skipWhitespace(line: []const u8, start: usize) usize {
    var pos = start;
    while (pos < line.len and isWhitespace(line[pos])) : (pos += 1) {}
    return pos;
}

pub fn trimTrailingWhitespace(s: []const u8) usize {
    var end = s.len;
    while (end > 0 and isWhitespace(s[end - 1])) : (end -= 1) {}
    return end;
}

fn applyTrim(line: []const u8, start: usize, raw_end: usize, options: SegmentOptions) usize {
    if (!options.trim_trailing_whitespace) return raw_end;
    return start + trimTrailingWhitespace(line[start..raw_end]);
}

fn breakPiece(line: []const u8, start: usize, end: usize, max_width: usize, width_method: grapheme.WidthMethod) usize {
    var pos = start;
    var width: usize = 0;

    while (pos < end) {
        const next = @min(grapheme.nextGraphemeBoundary(line[0..end], pos, width_method), end);
        const cluster_width = grapheme.strWidth(line[pos..next], width_method);
        if (width + cluster_width > max_width and width > 0) break;
        width += cluster_width;
        pos = next;
    }

    return if (pos > start) pos else @min(start + 1, end);
}

const testing = std.testing;

test "nextSegment display policy consumes overflow whitespace" {
    const seg1 = nextSegment("hello world", 0, 5, false, .{
        .trim_trailing_whitespace = true,
        .skip_leading_whitespace_on_continuation = true,
        .consume_overflow_whitespace = true,
    }, .wcwidth).?;
    try testing.expectEqualStrings("hello", seg1.text("hello world"));
    try testing.expectEqual(@as(usize, 6), seg1.next_start);

    const seg2 = nextSegment("hello world", seg1.next_start, 5, true, .{
        .trim_trailing_whitespace = true,
        .skip_leading_whitespace_on_continuation = true,
        .consume_overflow_whitespace = true,
    }, .wcwidth).?;
    try testing.expectEqualStrings("world", seg2.text("hello world"));
}

test "nextSegment preserve policy keeps separator bytes on previous line" {
    const seg1 = nextSegment("hello world", 0, 5, false, .{}, .wcwidth).?;
    try testing.expectEqualStrings("hello ", seg1.text("hello world"));
    try testing.expectEqual(@as(usize, 6), seg1.next_start);

    const seg2 = nextSegment("hello world", seg1.next_start, 5, true, .{}, .wcwidth).?;
    try testing.expectEqualStrings("world", seg2.text("hello world"));
}

test "token width fast path matches grapheme width for printable ascii" {
    const text = "plain ascii token";
    const token = nextToken(text, 0);
    try testing.expect(token.ascii_printable);
    try testing.expectEqual(grapheme.strWidth(token.text(text), .wcwidth), token.width(text, .wcwidth));
}
