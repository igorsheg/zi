const std = @import("std");
const grapheme = @import("grapheme.zig");

/// A wrapped line represented as byte offsets into source text.
pub const Line = struct {
    start: usize,
    end: usize,

    pub fn text(self: Line, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }
};

/// Word-wrap plain UTF-8 text to fit within `max_width` terminal columns.
///
/// Splits on newlines first, then wraps each line at word boundaries.
/// Long words (wider than max_width) are broken character-by-character.
/// Leading whitespace is stripped from continuation lines.
/// Trailing whitespace is stripped from all lines.
///
/// Returns byte-offset pairs into `text`. Caller owns the returned slice.
pub fn wordWrap(text: []const u8, max_width: usize, allocator: std.mem.Allocator) ![]Line {
    if (max_width == 0) return try allocator.dupe(Line, &.{.{ .start = 0, .end = 0 }});

    var lines: std.ArrayListUnmanaged(Line) = .{};
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
        line_start = line_end + 1; // skip \n
        // trailing newline produces empty line
        if (line_start == text.len + 1) {
            // text ended with \n — we already processed the last content line
            break;
        }
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

    // fast path: line fits
    const line_width = grapheme.strWidth(line);
    if (line_width <= max_width) {
        const trimmed_end = base_offset + trimTrailingWhitespace(line);
        try lines.append(allocator, .{ .start = base_offset, .end = trimmed_end });
        return;
    }

    // tokenize and wrap
    var current_start: usize = 0;
    var current_width: usize = 0;
    var line_begin: usize = 0; // byte offset within `line` where current output line starts
    var is_continuation = false;

    while (current_start < line.len) {
        // skip leading whitespace on continuation lines
        if (is_continuation and isWhitespace(line[current_start])) {
            const ws_end = skipWhitespace(line, current_start);
            if (current_width == 0) {
                line_begin = ws_end;
            }
            current_start = ws_end;
            if (current_start >= line.len) break;
        }

        const token = nextToken(line, current_start);
        const token_width = grapheme.strWidth(token.text(line));

        // token wider than max_width — break character-by-character
        if (token_width > max_width and !isAllWhitespace(token.text(line))) {
            // flush current line if non-empty
            if (current_width > 0) {
                const end = trimTrailingWhitespace(line[line_begin..current_start]);
                try lines.append(allocator, .{
                    .start = base_offset + line_begin,
                    .end = base_offset + line_begin + end,
                });
            }
            try breakLongWord(line, token.start, token.end, base_offset, max_width, lines, allocator);
            current_start = token.end;
            // after breaking a long word, the last fragment is already emitted
            // start a fresh line
            line_begin = current_start;
            current_width = 0;
            is_continuation = true;
            continue;
        }

        // would this token overflow?
        if (current_width + token_width > max_width and current_width > 0) {
            // emit current line
            const end = trimTrailingWhitespace(line[line_begin..current_start]);
            try lines.append(allocator, .{
                .start = base_offset + line_begin,
                .end = base_offset + line_begin + end,
            });
            // start new line — skip leading whitespace
            is_continuation = true;
            if (isAllWhitespace(token.text(line))) {
                current_start = token.end;
                line_begin = current_start;
                current_width = 0;
            } else {
                line_begin = token.start;
                current_start = token.end;
                current_width = token_width;
            }
        } else {
            current_start = token.end;
            current_width += token_width;
        }
    }

    // flush remaining
    if (current_width > 0 or (is_continuation and line_begin < line.len)) {
        const remaining = line[line_begin..current_start];
        if (remaining.len > 0) {
            const end = trimTrailingWhitespace(remaining);
            if (end > 0) {
                try lines.append(allocator, .{
                    .start = base_offset + line_begin,
                    .end = base_offset + line_begin + end,
                });
            }
        }
    }
}

/// Break a word that's wider than max_width, character by character.
fn breakLongWord(
    line: []const u8,
    start: usize,
    end: usize,
    base_offset: usize,
    max_width: usize,
    lines: *std.ArrayListUnmanaged(Line),
    allocator: std.mem.Allocator,
) !void {
    var pos = start;
    var frag_start = start;
    var frag_width: usize = 0;

    while (pos < end) {
        const cp_len = std.unicode.utf8ByteSequenceLength(line[pos]) catch {
            pos += 1;
            continue;
        };
        if (pos + cp_len > end) break;
        const cp = std.unicode.utf8Decode(line[pos..][0..cp_len]) catch {
            pos += 1;
            continue;
        };
        const w: usize = @intCast(grapheme.charWidth(cp));

        if (frag_width + w > max_width and frag_width > 0) {
            try lines.append(allocator, .{
                .start = base_offset + frag_start,
                .end = base_offset + pos,
            });
            frag_start = pos;
            frag_width = 0;
        }

        frag_width += w;
        pos += cp_len;
    }

    if (frag_start < end) {
        try lines.append(allocator, .{
            .start = base_offset + frag_start,
            .end = base_offset + end,
        });
    }
}

const Token = struct {
    start: usize,
    end: usize,

    fn text(self: Token, line: []const u8) []const u8 {
        return line[self.start..self.end];
    }
};

/// Tokenize at whitespace boundaries. A token is either a run of whitespace
/// or a run of non-whitespace.
fn nextToken(line: []const u8, start: usize) Token {
    if (start >= line.len) return .{ .start = start, .end = start };
    const is_ws = isWhitespace(line[start]);
    var pos = start;
    while (pos < line.len) : (pos += 1) {
        if (isWhitespace(line[pos]) != is_ws) break;
    }
    return .{ .start = start, .end = pos };
}

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn isAllWhitespace(s: []const u8) bool {
    for (s) |c| {
        if (!isWhitespace(c)) return false;
    }
    return true;
}

fn skipWhitespace(line: []const u8, start: usize) usize {
    var pos = start;
    while (pos < line.len and isWhitespace(line[pos])) : (pos += 1) {}
    return pos;
}

/// Returns byte length after trimming trailing whitespace.
fn trimTrailingWhitespace(s: []const u8) usize {
    var end = s.len;
    while (end > 0 and isWhitespace(s[end - 1])) : (end -= 1) {}
    return end;
}

// --- tests ---

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

test "word wrap preserves short lines and splits at word boundaries" {
    // fits in width
    try expectWrapped("hello", 10, &.{"hello"});

    // basic word wrap
    try expectWrapped("hello world", 5, &.{ "hello", "world" });
    try expectWrapped("the quick brown fox", 10, &.{ "the quick", "brown fox" });

    // trailing whitespace trimmed
    try expectWrapped("hi   ", 10, &.{"hi"});
}

test "word wrap handles newlines, empty input, and long words" {
    // empty input
    try expectWrapped("", 10, &.{""});

    // explicit newlines
    try expectWrapped("a\nb", 10, &.{ "a", "b" });
    try expectWrapped("a\n\nb", 10, &.{ "a", "", "b" });

    // trailing newline produces empty final line (matches split("\n") semantics)
    try expectWrapped("a\n", 10, &.{ "a", "" });

    // long word broken character-by-character
    try expectWrapped("abcdefghij", 3, &.{ "abc", "def", "ghi", "j" });
}

test "word wrap handles wide characters and mixed content" {
    // CJK chars are 2 columns each — "一二三" = 6 cols, width=4 means 2 per line
    try expectWrapped("一二三", 4, &.{ "一二", "三" });

    // mixed ASCII and wide
    try expectWrapped("hi一二", 4, &.{ "hi一", "二" });
}
