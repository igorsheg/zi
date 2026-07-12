const std = @import("std");
const vaxis = @import("vaxis");
const markdown = @import("markdown.zig");
const screen = @import("screen.zig");

pub const Line = screen.Line;
pub const WrapState = struct {
    committed_bytes: usize = 0,
    committed_lines: usize = 0,
    md: markdown.MdState = .{},
};

pub fn wrapMarkdown(
    allocator: std.mem.Allocator,
    text: []const u8,
    width: u16,
    base: screen.Style,
    state: *WrapState,
) ![]Line {
    var out = std.ArrayList(Line).empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, estimatedLineCapacity(text, width));
    try appendMarkdown(allocator, &out, text, width, base, state);
    return out.toOwnedSlice(allocator);
}

pub fn appendMarkdown(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Line),
    text: []const u8,
    width: u16,
    base: screen.Style,
    state: *WrapState,
) !void {
    std.debug.assert(state.committed_bytes <= text.len);
    std.debug.assert(out.items.len == state.committed_lines);

    var start = state.committed_bytes;
    while (std.mem.indexOfScalarPos(u8, text, start, '\n')) |end| {
        try wrapPhysicalMarkdownLine(allocator, out, text[start..end], width, base, &state.md);
        start = end + 1;
        state.committed_bytes = start;
        state.committed_lines = out.items.len;
    }

    var tail_state = state.md;
    const tail = text[start..];
    if (tail.len == 0) {
        try out.append(allocator, .{});
        return;
    }
    if (hasMarkdownSyntax(tail)) {
        try wrapPhysicalMarkdownLine(allocator, out, tail, width, base, &tail_state);
        return;
    }

    var tail_start: usize = 0;
    while (tail_start < tail.len) {
        const slice = if (tail_state.fence != null)
            hardWrapSlice(tail, tail_start, width)
        else
            proseWrapSlice(tail, tail_start, width);
        var line: Line = .{};
        try markdown.renderLine(&tail_state, &line, tail[tail_start..slice.end], base);
        try out.append(allocator, line);
        tail_start = slice.next;
        if (tail_start < tail.len) {
            state.committed_bytes = start + tail_start;
            state.committed_lines = out.items.len;
        }
    }
}

pub fn wrapPlain(allocator: std.mem.Allocator, text: []const u8, width: u16, style: screen.Style) ![]Line {
    return wrapText(allocator, text, width, style, false);
}

pub fn wrapProse(allocator: std.mem.Allocator, text: []const u8, width: u16, style: screen.Style) ![]Line {
    return wrapText(allocator, text, width, style, true);
}

fn wrapText(
    allocator: std.mem.Allocator,
    text: []const u8,
    width: u16,
    style: screen.Style,
    prose: bool,
) ![]Line {
    var out = std.ArrayList(Line).empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, estimatedLineCapacity(text, width));
    var start: usize = 0;
    while (start <= text.len) {
        const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        if (prose) {
            try appendProseLine(allocator, &out, text[start..end], width, style);
        } else {
            try appendPlainLine(allocator, &out, text[start..end], width, style);
        }
        if (end == text.len) break;
        start = end + 1;
    }
    return out.toOwnedSlice(allocator);
}

fn wrapPhysicalMarkdownLine(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Line),
    text: []const u8,
    width: u16,
    base: screen.Style,
    state: *markdown.MdState,
) !void {
    if (text.len == 0) {
        try out.append(allocator, .{});
        return;
    }
    if (state.fence == null and !hasMarkdownSyntax(text)) return appendProseLine(allocator, out, text, width, base);
    var start: usize = 0;
    while (start < text.len) {
        const slice = if (state.fence != null)
            hardWrapSlice(text, start, width)
        else
            proseWrapSlice(text, start, width);
        var line: Line = .{};
        try markdown.renderLine(state, &line, text[start..slice.end], base);
        try out.append(allocator, line);
        start = slice.next;
    }
}

fn hasMarkdownSyntax(text: []const u8) bool {
    for (text) |byte| switch (byte) {
        '#', '`', '>', '-', '*', '_', '[', ']', '(', ')', '!' => return true,
        else => {},
    };
    return false;
}

fn estimatedLineCapacity(text: []const u8, width: u16) usize {
    if (text.len == 0) return 1;
    const effective_width: usize = @max(@as(usize, 1), width);
    return @max(@as(usize, 1), text.len / effective_width + 2);
}
pub fn appendPlainLine(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Line),
    text: []const u8,
    width: u16,
    style: screen.Style,
) !void {
    return appendTextLine(allocator, out, text, width, style, false);
}

pub fn appendProseLine(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Line),
    text: []const u8,
    width: u16,
    style: screen.Style,
) !void {
    return appendTextLine(allocator, out, text, width, style, true);
}

fn appendTextLine(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Line),
    text: []const u8,
    width: u16,
    style: screen.Style,
    prose: bool,
) !void {
    if (text.len == 0) {
        try out.append(allocator, .{});
        return;
    }
    var start: usize = 0;
    while (start < text.len) {
        const slice = if (prose)
            proseWrapSlice(text, start, width)
        else
            hardWrapSlice(text, start, width);
        var line: Line = .{};
        try line.append(.{ .text = text[start..slice.end], .style = style });
        try out.append(allocator, line);
        start = slice.next;
    }
}

const WrapSlice = struct {
    end: usize,
    next: usize,
};

fn hardWrapSlice(text: []const u8, start: usize, width: u16) WrapSlice {
    const end = sliceEndForWidth(text, start, width);
    return .{ .end = end, .next = end };
}

fn proseWrapSlice(text: []const u8, start: usize, width: u16) WrapSlice {
    const hard_end = sliceEndForWidth(text, start, width);
    if (hard_end == text.len) return .{ .end = hard_end, .next = hard_end };
    if (isWrapWhitespace(text[hard_end])) {
        var next = hard_end;
        while (next < text.len and isWrapWhitespace(text[next])) next += 1;
        return .{ .end = hard_end, .next = next };
    }

    var whitespace_break: ?usize = null;
    var punctuation_break: ?usize = null;
    for (text[start..hard_end], start..) |byte, index| {
        if (index > start and isWrapWhitespace(byte)) {
            whitespace_break = index;
        } else if (isWrapPunctuation(byte)) {
            punctuation_break = index + 1;
        }
    }

    const end = if (whitespace_break) |whitespace|
        if (punctuation_break) |punctuation| @max(whitespace, punctuation) else whitespace
    else
        punctuation_break orelse hard_end;
    var next = end;
    while (next < text.len and isWrapWhitespace(text[next])) next += 1;
    if (end == start) return .{ .end = hard_end, .next = hard_end };
    return .{ .end = end, .next = next };
}

fn isWrapWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

fn isWrapPunctuation(byte: u8) bool {
    return switch (byte) {
        '-', '/', '\\', '.', ',', ';', ':', '!', '?', ')', ']', '}' => true,
        else => false,
    };
}

pub fn sliceEndForWidth(text: []const u8, start: usize, width: u16) usize {
    if (start >= text.len) return text.len;
    if (width == 0) return nextUtf8ScalarEnd(text, start);
    if (asciiSliceEndForWidth(text, start, width)) |end| return end;
    var iter = vaxis.unicode.graphemeIterator(text[start..]);
    var used: u16 = 0;
    var last_break: usize = start;
    while (iter.next()) |grapheme| {
        const bytes = grapheme.bytes(text[start..]);
        const next = start + grapheme.start + grapheme.len;
        const w = vaxis.gwidth.gwidth(bytes, .unicode);
        if (used > 0 and used + w > width) break;
        used += w;
        last_break = next;
        if (used >= width) break;
    }
    if (last_break == start) return nextUtf8ScalarEnd(text, start);
    return last_break;
}

fn asciiSliceEndForWidth(text: []const u8, start: usize, width: u16) ?usize {
    var index = start;
    var used: u16 = 0;
    while (index < text.len and used < width) : (index += 1) {
        if (text[index] >= 0x80) return null;
        used += 1;
    }
    return index;
}

fn nextUtf8ScalarEnd(text: []const u8, start: usize) usize {
    const len = std.unicode.utf8ByteSequenceLength(text[start]) catch 1;
    return @min(text.len, start + len);
}

test "plain wrap respects grapheme width" {
    const lines = try wrapPlain(std.testing.allocator, "abcd", 2, screen.text.normal);
    defer std.testing.allocator.free(lines);
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    var buffer: [8]u8 = undefined;
    try std.testing.expectEqualStrings("ab", lines[0].copyText(&buffer));
    try std.testing.expectEqualStrings("cd", lines[1].copyText(&buffer));
}

test "prose wrap prefers words and skips wrap-only whitespace" {
    const lines = try wrapProse(std.testing.allocator, "alpha beta gamma", 10, screen.text.normal);
    defer std.testing.allocator.free(lines);
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("alpha beta", lines[0].copyText(&buffer));
    try std.testing.expectEqualStrings("gamma", lines[1].copyText(&buffer));
}

test "prose wrap falls back for long unicode tokens" {
    const lines = try wrapProse(std.testing.allocator, "界界界界", 4, screen.text.normal);
    defer std.testing.allocator.free(lines);
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("界界", lines[0].copyText(&buffer));
    try std.testing.expectEqualStrings("界界", lines[1].copyText(&buffer));
}

test "markdown wrap applies block style" {
    var state: WrapState = .{};
    const lines = try wrapMarkdown(std.testing.allocator, "# title", 80, screen.text.normal, &state);
    defer std.testing.allocator.free(lines);
    try std.testing.expect(lines[0].spans()[0].style.bold);
    try std.testing.expectEqual(@as(usize, 0), state.committed_bytes);
}

test "markdown wrapping preserves fenced code style on plain body lines" {
    var state: WrapState = .{};
    const lines = try wrapMarkdown(
        std.testing.allocator,
        "```zig\nconst value = 1;\n```",
        80,
        screen.text.normal,
        &state,
    );
    defer std.testing.allocator.free(lines);
    try std.testing.expect(std.meta.eql(lines[1].spans()[0].style.fg, screen.markdown_styles.code_block.fg));
}

test "markdown prose wraps by words while fenced code hard wraps" {
    var prose_state: WrapState = .{};
    const prose = try wrapMarkdown(std.testing.allocator, "alpha beta gamma", 10, screen.text.normal, &prose_state);
    defer std.testing.allocator.free(prose);
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("alpha beta", prose[0].copyText(&buffer));
    try std.testing.expectEqualStrings("gamma", prose[1].copyText(&buffer));

    var fence_state: WrapState = .{};
    const fenced = try wrapMarkdown(std.testing.allocator, "```\nalpha beta\n```", 6, screen.text.normal, &fence_state);
    defer std.testing.allocator.free(fenced);
    try std.testing.expectEqualStrings("alpha ", fenced[1].copyText(&buffer));
    try std.testing.expectEqualStrings("beta", fenced[2].copyText(&buffer));
}

test "incremental markdown keeps committed physical lines and plain wraps" {
    var lines = std.ArrayList(Line).empty;
    defer lines.deinit(std.testing.allocator);
    var state: WrapState = .{};

    try appendMarkdown(std.testing.allocator, &lines, "one\nabcdefghij", 4, screen.text.normal, &state);
    try std.testing.expectEqual(@as(usize, "one\nabcdefgh".len), state.committed_bytes);
    try std.testing.expectEqual(@as(usize, 3), state.committed_lines);
    lines.items.len = state.committed_lines;

    try appendMarkdown(std.testing.allocator, &lines, "one\nabcdefghijkl", 4, screen.text.normal, &state);
    var buffer: [8]u8 = undefined;
    try std.testing.expectEqualStrings("ijkl", lines.items[3].copyText(&buffer));
}

test {
    std.testing.refAllDecls(@This());
}
