//! Bounded markdown presentation for transcript text. This is not a full
//! CommonMark AST: it recognizes the blocks agents emit most often and parses
//! inline emphasis without allocating.
const std = @import("std");
const glyphs = @import("glyphs.zig");
const theme_mod = @import("theme.zig");

pub const State = struct {
    fence: Fence = .none,

    pub const Fence = enum { none, backtick, tilde };
};

pub const LineKind = enum { plain, heading, quote, list, code, horizontal_rule };

pub const Projection = struct {
    kind: LineKind,
    prefix: []const u8 = "",
    continuation_prefix: []const u8 = "",
    text: []const u8,
    /// Whether wrapped continuation rows repeat `prefix` (quotes/code do;
    /// list items use `continuation_prefix` instead).
    repeat_prefix: bool = false,
    parse_inline: bool = true,
    prefix_style: theme_mod.Style,
    text_style: theme_mod.Style,
    row_style: theme_mod.Style,
};

pub const InlineSpan = struct {
    text: []const u8,
    style: theme_mod.Style,
    raw_start: usize,
    raw_end: usize,
};

const spaces = "                                                                ";

pub fn classifyLine(state: *State, line: []const u8, theme: *const theme_mod.Theme) Projection {
    if (state.fence != .none) {
        if (fenceMarker(line)) |marker| {
            if (marker == state.fence) state.* = .{};
        }
        return codeProjection(line, theme);
    }

    if (fenceMarker(line)) |marker| {
        state.fence = marker;
        return codeProjection(line, theme);
    }

    const trimmed = trimLeft(line);
    if (horizontalRule(trimmed)) {
        return .{
            .kind = .horizontal_rule,
            .text = glyphs.horizontal_rule,
            .parse_inline = false,
            .prefix_style = theme.transcript_secondary,
            .text_style = theme.transcript_secondary,
            .row_style = theme.transcript_secondary,
        };
    }
    if (heading(trimmed)) |head| {
        const style = headingStyle(theme, head.level);
        return .{
            .kind = .heading,
            .text = if (head.level >= 3) trimmed else head.content,
            .prefix_style = style,
            .text_style = style,
            .row_style = theme.transcript_text,
        };
    }
    if (quote(trimmed)) |content| {
        var quote_style = theme.transcript_text;
        quote_style.italic = true;
        return .{
            .kind = .quote,
            .prefix = glyphs.quote_prefix,
            .text = content,
            .repeat_prefix = true,
            .prefix_style = theme.transcript_secondary,
            .text_style = quote_style,
            .row_style = theme.transcript_text,
        };
    }
    if (list(line)) |parts| {
        return .{
            .kind = .list,
            .prefix = parts.prefix,
            .continuation_prefix = parts.continuation_prefix,
            .text = parts.text,
            .repeat_prefix = false,
            .prefix_style = theme.status_accent,
            .text_style = theme.transcript_text,
            .row_style = theme.transcript_text,
        };
    }
    return .{
        .kind = .plain,
        .text = line,
        .prefix_style = theme.transcript_text,
        .text_style = theme.transcript_text,
        .row_style = theme.transcript_text,
    };
}

pub fn nextInlineSpan(
    line: []const u8,
    index: *usize,
    base_style: theme_mod.Style,
    theme: *const theme_mod.Theme,
) ?InlineSpan {
    if (index.* >= line.len) return null;
    const start = index.*;

    if (line[start] == '`') {
        if (findInlineCode(line, start)) |span| {
            index.* = span.after;
            return .{
                .text = line[span.start..span.end],
                .style = theme.tool_output,
                .raw_start = start,
                .raw_end = span.after,
            };
        }
    }

    if (startsWithAt(line, start, "**") or startsWithAt(line, start, "__")) {
        if (findDelimited(line, start, 2)) |span| {
            index.* = span.after;
            var style = base_style;
            style.bold = true;
            return .{ .text = line[span.start..span.end], .style = style, .raw_start = start, .raw_end = span.after };
        }
    }

    if (startsWithAt(line, start, "~~")) {
        if (findStrikethrough(line, start)) |span| {
            index.* = span.after;
            var style = base_style;
            style.strikethrough = true;
            return .{ .text = line[span.start..span.end], .style = style, .raw_start = start, .raw_end = span.after };
        }
    }

    if ((line[start] == '*' or line[start] == '_') and
        !(start + 1 < line.len and line[start + 1] == line[start]))
    {
        if (findDelimited(line, start, 1)) |span| {
            index.* = span.after;
            var style = base_style;
            style.italic = true;
            return .{ .text = line[span.start..span.end], .style = style, .raw_start = start, .raw_end = span.after };
        }
    }

    if (line[start] == '[') {
        if (findLink(line, start)) |link_span| {
            index.* = link_span.after;
            var style = theme.status_accent;
            style.ul_style = .single;
            return .{
                .text = line[link_span.start..link_span.end],
                .style = style,
                .raw_start = start,
                .raw_end = link_span.after,
            };
        }
    }

    var end = start + 1;
    while (end < line.len and !isInlineSpecial(line[end])) : (end += 1) {}
    index.* = end;
    return .{ .text = line[start..end], .style = base_style, .raw_start = start, .raw_end = end };
}

fn codeProjection(line: []const u8, theme: *const theme_mod.Theme) Projection {
    return .{
        .kind = .code,
        .prefix = "  ",
        .text = line,
        .repeat_prefix = true,
        .parse_inline = false,
        .prefix_style = theme.transcript_secondary,
        .text_style = theme.tool_output,
        .row_style = theme.transcript_text,
    };
}

fn headingStyle(theme: *const theme_mod.Theme, level: u8) theme_mod.Style {
    var style = theme.status_accent;
    style.bold = true;
    if (level == 1) style.ul_style = .single;
    return style;
}

fn fenceMarker(line: []const u8) ?State.Fence {
    const trimmed = trimLeft(line);
    if (std.mem.startsWith(u8, trimmed, "```")) return .backtick;
    if (std.mem.startsWith(u8, trimmed, "~~~")) return .tilde;
    return null;
}

const Heading = struct {
    level: u8,
    content: []const u8,
};

fn heading(line: []const u8) ?Heading {
    var level: usize = 0;
    while (level < line.len and level < 6 and line[level] == '#') : (level += 1) {}
    if (level == 0) return null;
    if (level >= line.len or line[level] != ' ') return null;
    return .{ .level = @intCast(level), .content = trimLeft(line[level + 1 ..]) };
}

fn quote(line: []const u8) ?[]const u8 {
    if (line.len == 0 or line[0] != '>') return null;
    var content = line[1..];
    if (content.len > 0 and content[0] == ' ') content = content[1..];
    return content;
}

const ListParts = struct {
    prefix: []const u8,
    continuation_prefix: []const u8,
    text: []const u8,
};

fn list(line: []const u8) ?ListParts {
    const start = leadingIndentEnd(line);
    if (start >= line.len) return null;
    if (line.len >= start + 2 and isUnorderedMarker(line[start]) and line[start + 1] == ' ') {
        var text_start = start + 2;
        if (taskMarker(line[text_start..])) text_start += 4;
        return listParts(line, text_start);
    }

    var index = start;
    while (index < line.len and index - start < 9 and std.ascii.isDigit(line[index])) : (index += 1) {}
    if (index == start or index + 1 >= line.len) return null;
    if ((line[index] != '.' and line[index] != ')') or line[index + 1] != ' ') return null;
    return listParts(line, index + 2);
}

fn listParts(line: []const u8, text_start: usize) ListParts {
    const prefix = line[0..text_start];
    return .{
        .prefix = prefix,
        .continuation_prefix = spaces[0..@min(prefixColumns(prefix), spaces.len)],
        .text = line[text_start..],
    };
}

fn taskMarker(line: []const u8) bool {
    return line.len >= 4 and line[0] == '[' and line[2] == ']' and line[3] == ' ' and
        (line[1] == ' ' or line[1] == 'x' or line[1] == 'X');
}

fn isUnorderedMarker(byte: u8) bool {
    return byte == '-' or byte == '*' or byte == '+';
}

fn horizontalRule(line: []const u8) bool {
    if (line.len < 3) return false;
    const marker = line[0];
    if (marker != '-' and marker != '*' and marker != '_') return false;
    var count: usize = 0;
    for (line) |byte| {
        if (byte == marker) {
            count += 1;
        } else if (byte != ' ' and byte != '\t') return false;
    }
    return count >= 3;
}

fn leadingIndentEnd(bytes: []const u8) usize {
    var index: usize = 0;
    while (index < bytes.len and (bytes[index] == ' ' or bytes[index] == '\t')) : (index += 1) {}
    return index;
}

fn prefixColumns(bytes: []const u8) usize {
    var cols: usize = 0;
    for (bytes) |byte| cols += if (byte == '\t') 4 else 1;
    return cols;
}

fn trimLeft(bytes: []const u8) []const u8 {
    return bytes[leadingIndentEnd(bytes)..];
}

const Span = struct {
    start: usize,
    end: usize,
    after: usize,
};

fn findInlineCode(line: []const u8, pos: usize) ?Span {
    const start = pos + 1;
    if (start >= line.len) return null;
    var end = start;
    while (end < line.len) : (end += 1) {
        if (line[end] == '`') {
            if (end == start) return null;
            return .{ .start = start, .end = end, .after = end + 1 };
        }
    }
    return null;
}

fn findDelimited(line: []const u8, pos: usize, delimiter_len: usize) ?Span {
    if (pos + delimiter_len >= line.len) return null;
    const delimiter = line[pos];
    var offset: usize = 0;
    while (offset < delimiter_len) : (offset += 1) {
        if (line[pos + offset] != delimiter) return null;
    }

    const start = pos + delimiter_len;
    if (start >= line.len or isBoundarySpace(line[start])) return null;

    var end = start;
    while (end + delimiter_len <= line.len) : (end += 1) {
        var matches = true;
        offset = 0;
        while (offset < delimiter_len) : (offset += 1) {
            if (line[end + offset] != delimiter) {
                matches = false;
                break;
            }
        }
        if (!matches) continue;
        if (end == start or isBoundarySpace(line[end - 1])) continue;
        return .{ .start = start, .end = end, .after = end + delimiter_len };
    }
    return null;
}

fn findStrikethrough(line: []const u8, pos: usize) ?Span {
    const start = pos + 2;
    if (start >= line.len or isBoundarySpace(line[start]) or line[start] == '~') return null;
    var end = start;
    while (end + 2 <= line.len) : (end += 1) {
        if (line[end] != '~' or line[end + 1] != '~') continue;
        if (end == start or isBoundarySpace(line[end - 1]) or line[end - 1] == '~') continue;
        return .{ .start = start, .end = end, .after = end + 2 };
    }
    return null;
}

const LinkSpan = struct {
    start: usize,
    end: usize,
    after: usize,
};

fn findLink(line: []const u8, pos: usize) ?LinkSpan {
    var close_label = pos + 1;
    while (close_label < line.len and line[close_label] != ']') : (close_label += 1) {}
    if (close_label == pos + 1 or close_label + 2 >= line.len) return null;
    if (line[close_label + 1] != '(') return null;
    var close_url = close_label + 2;
    while (close_url < line.len and line[close_url] != ')') : (close_url += 1) {}
    if (close_url >= line.len) return null;
    return .{ .start = pos + 1, .end = close_label, .after = close_url + 1 };
}

fn startsWithAt(line: []const u8, pos: usize, needle: []const u8) bool {
    return pos + needle.len <= line.len and std.mem.eql(u8, line[pos .. pos + needle.len], needle);
}

fn isInlineSpecial(byte: u8) bool {
    return byte == '`' or byte == '*' or byte == '_' or byte == '[' or byte == '~';
}

fn isBoundarySpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

test "classifyLine tracks fences and recognizes structures" {
    const theme = theme_mod.Theme.codex(.{});
    var state: State = .{};

    try std.testing.expectEqual(LineKind.heading, classifyLine(&state, "# Title", &theme).kind);
    try std.testing.expectEqual(LineKind.quote, classifyLine(&state, "> quoted", &theme).kind);
    try std.testing.expectEqual(LineKind.list, classifyLine(&state, "12. item", &theme).kind);
    try std.testing.expectEqual(LineKind.horizontal_rule, classifyLine(&state, "---", &theme).kind);

    try std.testing.expectEqual(LineKind.code, classifyLine(&state, "```zig", &theme).kind);
    // Inside a fence everything is code, including would-be headings.
    try std.testing.expectEqual(LineKind.code, classifyLine(&state, "# not a heading", &theme).kind);
    try std.testing.expectEqual(LineKind.code, classifyLine(&state, "```", &theme).kind);
    try std.testing.expectEqual(LineKind.plain, classifyLine(&state, "after", &theme).kind);
}

test "list markers keep source marker and indent continuations" {
    const theme = theme_mod.Theme.codex(.{});
    var state: State = .{};

    try std.testing.expectEqual(LineKind.plain, classifyLine(&state, "-no space", &theme).kind);
    const ordered = classifyLine(&state, "  3) third", &theme);
    try std.testing.expectEqualStrings("  3) ", ordered.prefix);
    try std.testing.expectEqualStrings("     ", ordered.continuation_prefix);
    try std.testing.expectEqualStrings("third", ordered.text);

    const task = classifyLine(&state, "- [x] done", &theme);
    try std.testing.expectEqualStrings("- [x] ", task.prefix);
    try std.testing.expectEqualStrings("done", task.text);
}

test "inline parser recognizes common pi markdown spans" {
    const theme = theme_mod.Theme.codex(.{});
    const base = theme.transcript_text;
    const line = "a `code` **bold** *em* ~~gone~~ [link](https://e.test)";
    var index: usize = 0;

    const plain = nextInlineSpan(line, &index, base, &theme).?;
    try std.testing.expectEqualStrings("a ", plain.text);

    const code = nextInlineSpan(line, &index, base, &theme).?;
    try std.testing.expectEqualStrings("code", code.text);
    try std.testing.expect(theme_mod.Style.eql(theme.tool_output, code.style));

    _ = nextInlineSpan(line, &index, base, &theme).?;
    const bold = nextInlineSpan(line, &index, base, &theme).?;
    try std.testing.expectEqualStrings("bold", bold.text);
    try std.testing.expect(bold.style.bold);

    _ = nextInlineSpan(line, &index, base, &theme).?;
    const italic = nextInlineSpan(line, &index, base, &theme).?;
    try std.testing.expectEqualStrings("em", italic.text);
    try std.testing.expect(italic.style.italic);

    _ = nextInlineSpan(line, &index, base, &theme).?;
    const strike = nextInlineSpan(line, &index, base, &theme).?;
    try std.testing.expectEqualStrings("gone", strike.text);
    try std.testing.expect(strike.style.strikethrough);

    _ = nextInlineSpan(line, &index, base, &theme).?;
    const link_span = nextInlineSpan(line, &index, base, &theme).?;
    try std.testing.expectEqualStrings("link", link_span.text);
    try std.testing.expectEqual(theme_mod.Style.Underline.single, link_span.style.ul_style);
}
