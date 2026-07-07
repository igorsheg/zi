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
    var md_state: markdown.MdState = .{};
    var start: usize = 0;
    while (start <= text.len) {
        const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        try wrapPhysicalMarkdownLine(allocator, &out, text[start..end], width, base, &md_state);
        if (end == text.len) break;
        start = end + 1;
    }
    state.committed_bytes = text.len;
    state.committed_lines = out.items.len;
    state.md = md_state;
    return out.toOwnedSlice(allocator);
}

pub fn wrapPlain(allocator: std.mem.Allocator, text: []const u8, width: u16, style: screen.Style) ![]Line {
    var out = std.ArrayList(Line).empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, estimatedLineCapacity(text, width));
    var start: usize = 0;
    while (start <= text.len) {
        const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        try appendPlainLine(allocator, &out, text[start..end], width, style);
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
    if (!hasMarkdownSyntax(text)) return appendPlainLine(allocator, out, text, width, base);
    var start: usize = 0;
    while (start < text.len) {
        const end = sliceEndForWidth(text, start, width);
        var line: Line = .{};
        try markdown.renderLine(state, &line, text[start..end], base);
        try out.append(allocator, line);
        start = end;
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
    if (text.len == 0) {
        try out.append(allocator, .{});
        return;
    }
    var start: usize = 0;
    while (start < text.len) {
        const end = sliceEndForWidth(text, start, width);
        var line: Line = .{};
        try line.append(.{ .text = text[start..end], .style = style });
        try out.append(allocator, line);
        start = end;
    }
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
    const lines = try wrapPlain(std.testing.allocator, "abcd", 2, screen.styles.normal);
    defer std.testing.allocator.free(lines);
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    var buffer: [8]u8 = undefined;
    try std.testing.expectEqualStrings("ab", lines[0].copyText(&buffer));
    try std.testing.expectEqualStrings("cd", lines[1].copyText(&buffer));
}

test "markdown wrap applies block style" {
    var state: WrapState = .{};
    const lines = try wrapMarkdown(std.testing.allocator, "# title", 80, screen.styles.normal, &state);
    defer std.testing.allocator.free(lines);
    try std.testing.expect(lines[0].spans()[0].style.bold);
    try std.testing.expectEqual(@as(usize, "# title".len), state.committed_bytes);
}

test {
    std.testing.refAllDecls(@This());
}
