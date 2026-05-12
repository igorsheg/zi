const std = @import("std");
const cell_mod = @import("../cell.zig");
const display_wrap_mod = @import("../wrap/display.zig");
const breaks_mod = @import("../wrap/breaks.zig");
const grapheme = @import("../grapheme.zig");

const Color = cell_mod.Color;
const Attributes = cell_mod.Attributes;
pub const Line = display_wrap_mod.Line;

pub const WrapMode = enum { none, char, word };
pub const OverflowMode = enum { clip, ellipsis };
pub const TextAlign = enum { left, center, right };

pub const TextRun = struct {
    text: []const u8,
    fg: Color = Color.default,
    bg: Color = Color.default,
    attrs: Attributes = .{},
    link: ?[]const u8 = null,
};

pub const StyleSpan = struct {
    start: usize,
    end: usize,
    fg: Color,
    bg: Color,
    attrs: Attributes,
    link: ?[]const u8,
};

pub const TextBuffer = struct {
    text: std.ArrayListUnmanaged(u8) = .empty,
    styles: std.ArrayListUnmanaged(StyleSpan) = .empty,
    style_generation: u64 = 0,

    pub fn deinit(self: *TextBuffer, allocator: std.mem.Allocator) void {
        self.text.deinit(allocator);
        self.styles.deinit(allocator);
    }

    pub fn setPlain(self: *TextBuffer, allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
        self.text.clearRetainingCapacity();
        self.styles.clearRetainingCapacity();
        try self.text.appendSlice(allocator, text);
        self.style_generation +%= 1;
        return self.text.items;
    }

    pub fn setRuns(self: *TextBuffer, allocator: std.mem.Allocator, runs: []const TextRun) ![]const u8 {
        self.text.clearRetainingCapacity();
        self.styles.clearRetainingCapacity();
        for (runs) |run| {
            const start = self.text.items.len;
            try self.text.appendSlice(allocator, run.text);
            const end = self.text.items.len;
            if (start != end) {
                try self.styles.append(allocator, .{
                    .start = start,
                    .end = end,
                    .fg = run.fg,
                    .bg = run.bg,
                    .attrs = run.attrs,
                    .link = run.link,
                });
            }
        }
        self.style_generation +%= 1;
        return self.text.items;
    }

    pub fn styleAt(self: *const TextBuffer, byte_offset: usize, fallback: StyleSpan) StyleSpan {
        for (self.styles.items) |span| {
            if (byte_offset >= span.start and byte_offset < span.end) return span;
            if (byte_offset < span.start) break;
        }
        return fallback;
    }
};

pub const LayoutKey = struct {
    width: u32,
    content_ptr: ?[*]const u8,
    content_len: usize,
    content_hash: u64,
    style_generation: u64,
    width_method: grapheme.WidthMethod,
    wrap_mode: WrapMode,
    max_lines: ?u32,
};

pub const LayoutCache = struct {
    key: ?LayoutKey = null,
    lines: ?[]Line = null,

    pub fn matches(self: *const LayoutCache, key: LayoutKey) bool {
        const cached = self.key orelse return false;
        return cached.width == key.width and
            cached.content_ptr == key.content_ptr and
            cached.content_len == key.content_len and
            cached.content_hash == key.content_hash and
            cached.style_generation == key.style_generation and
            cached.width_method == key.width_method and
            cached.wrap_mode == key.wrap_mode and
            cached.max_lines == key.max_lines;
    }

    pub fn clear(self: *LayoutCache, allocator: std.mem.Allocator) void {
        if (self.lines) |lines| allocator.free(lines);
        self.lines = null;
        self.key = null;
    }
};

pub const LayoutInput = struct {
    text: []const u8,
    width: u32,
    wrap_mode: WrapMode,
    max_lines: ?u32 = null,
    width_method: grapheme.WidthMethod,
    style_generation: u64 = 0,
};

pub fn makeKey(input: LayoutInput) LayoutKey {
    return .{
        .width = input.width,
        .content_ptr = if (input.text.len == 0) null else input.text.ptr,
        .content_len = input.text.len,
        .content_hash = std.hash.Wyhash.hash(0, input.text),
        .style_generation = input.style_generation,
        .width_method = input.width_method,
        .wrap_mode = input.wrap_mode,
        .max_lines = input.max_lines,
    };
}

pub fn getCached(cache: *LayoutCache, allocator: std.mem.Allocator, input: LayoutInput) !*const LayoutCache {
    const layout_key = makeKey(input);
    if (cache.matches(layout_key)) return cache;

    cache.clear(allocator);
    const lines = try wrapLines(input.text, input.width, input.wrap_mode, allocator, input.width_method);
    cache.* = .{ .key = layout_key, .lines = lines };
    return cache;
}

pub fn measureLineCount(lines: []const Line, padding_y: u32, max_lines: ?u32) u32 {
    const line_count: u32 = @intCast(lines.len);
    var total = line_count + padding_y * 2;
    if (max_lines) |m| total = @min(total, m);
    return total;
}

pub fn wrapLines(text: []const u8, max_width: u32, mode: WrapMode, allocator: std.mem.Allocator, width_method: grapheme.WidthMethod) ![]Line {
    return switch (mode) {
        .word => display_wrap_mod.wordWrap(text, max_width, allocator, width_method),
        .none => wrapLogicalLines(text, allocator, null, width_method),
        .char => wrapCharLines(text, max_width, allocator, width_method),
    };
}

fn wrapLogicalLines(text: []const u8, allocator: std.mem.Allocator, max_width: ?u32, width_method: grapheme.WidthMethod) ![]Line {
    if (max_width != null and max_width.? == 0) return try allocator.dupe(Line, &.{.{ .start = 0, .end = 0 }});

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
        if (max_width) |width| {
            try appendCharWrappedLine(&lines, allocator, text, line_start, line_end, width, width_method);
        } else {
            try lines.append(allocator, .{ .start = line_start, .end = line_end });
        }

        if (newline_pos == null) break;
        line_start = line_end + 1;
        if (line_start == text.len) {
            try lines.append(allocator, .{ .start = line_start, .end = line_start });
            break;
        }
    }

    return try lines.toOwnedSlice(allocator);
}

fn wrapCharLines(text: []const u8, max_width: u32, allocator: std.mem.Allocator, width_method: grapheme.WidthMethod) ![]Line {
    return wrapLogicalLinesWithBreaks(text, allocator, max_width, width_method);
}

fn wrapLogicalLinesWithBreaks(text: []const u8, allocator: std.mem.Allocator, max_width: u32, width_method: grapheme.WidthMethod) ![]Line {
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
        try appendCharWrappedLine(&lines, allocator, text, line_start, line_end, max_width, width_method);

        if (newline_pos == null) break;
        line_start = line_end + 1;
        if (line_start == text.len) {
            try lines.append(allocator, .{ .start = line_start, .end = line_start });
            break;
        }
    }

    return try lines.toOwnedSlice(allocator);
}

fn appendCharWrappedLine(lines: *std.ArrayListUnmanaged(Line), allocator: std.mem.Allocator, text: []const u8, line_start: usize, line_end: usize, max_width: u32, width_method: grapheme.WidthMethod) !void {
    if (line_start == line_end) {
        try lines.append(allocator, .{ .start = line_start, .end = line_start });
        return;
    }

    var start = line_start;
    while (start < line_end) {
        const segment = breaks_mod.nextSegment(text[line_start..line_end], start - line_start, max_width, start != line_start, .{}, width_method) orelse {
            try lines.append(allocator, .{ .start = start, .end = line_end });
            break;
        };
        const end = line_start + segment.end;
        try lines.append(allocator, .{ .start = line_start + segment.start, .end = @min(end, line_end) });
        start = line_start + segment.next_start;
        if (start <= line_start + segment.start) break;
    }
}

pub const ViewportSlice = struct { start: usize, end: usize };

pub fn viewportForLine(text: []const u8, line: Line, content_width: u32, scroll_x: u32, width_method: grapheme.WidthMethod) ViewportSlice {
    if (line.start >= line.end) return .{ .start = line.start, .end = line.end };
    const start = byteOffsetForDisplayOffset(text, line.start, line.end, scroll_x, width_method);
    const rel = grapheme.sliceToWidth(text[start..line.end], content_width, width_method);
    return .{ .start = start, .end = start + rel.len };
}

pub fn byteOffsetForDisplayOffset(text: []const u8, start: usize, end: usize, offset: u32, width_method: grapheme.WidthMethod) usize {
    if (offset == 0) return start;
    var byte = start;
    var col: u32 = 0;
    while (byte < end) {
        const next = grapheme.nextGraphemeBoundaryFromBoundary(text[start..end], byte - start, width_method) + start;
        if (next <= byte) break;
        const w: u32 = @intCast(grapheme.strWidth(text[byte..next], width_method));
        if (col + w > offset) return byte;
        col += w;
        byte = next;
    }
    return end;
}

pub fn alignmentOffset(alignment: TextAlign, content_width: u32, line_width: u32) u32 {
    if (line_width >= content_width) return 0;
    const extra = content_width - line_width;
    return switch (alignment) {
        .left => 0,
        .center => extra / 2,
        .right => extra,
    };
}

const testing = std.testing;

fn expectWrapped(text: []const u8, width: u32, mode: WrapMode, expected: []const []const u8) !void {
    const lines = try wrapLines(text, width, mode, testing.allocator, .wcwidth);
    defer testing.allocator.free(lines);
    try testing.expectEqual(expected.len, lines.len);
    for (expected, 0..) |exp, i| try testing.expectEqualStrings(exp, lines[i].text(text));
}

test "text layout wrap modes use wrap primitives" {
    try expectWrapped("hello world", 5, .word, &.{ "hello", "world" });
    try expectWrapped("abcdef", 3, .char, &.{ "abc", "def" });
    try expectWrapped("abc\ndef", 3, .none, &.{ "abc", "def" });
}

test "text layout viewport and alignment helpers" {
    const text = "abcdef";
    const line = Line{ .start = 0, .end = text.len };
    const viewport = viewportForLine(text, line, 3, 2, .wcwidth);
    try testing.expectEqualStrings("cde", text[viewport.start..viewport.end]);
    try testing.expectEqual(@as(u32, 2), alignmentOffset(.center, 6, 2));
    try testing.expectEqual(@as(u32, 4), alignmentOffset(.right, 6, 2));
}

test "text buffer maps styled runs" {
    var buffer: TextBuffer = .{};
    defer buffer.deinit(testing.allocator);
    const red = Color.rgb(255, 0, 0);
    const runs = [_]TextRun{.{ .text = "hi", .fg = red }};
    const owned = try buffer.setRuns(testing.allocator, &runs);
    try testing.expectEqualStrings("hi", owned);
    const fallback = StyleSpan{ .start = 0, .end = 0, .fg = Color.default, .bg = Color.default, .attrs = .{}, .link = null };
    try testing.expect(buffer.styleAt(0, fallback).fg.eql(red));
}

test "text layout cache detects content mutation" {
    var cache: LayoutCache = .{};
    defer cache.clear(testing.allocator);
    var bytes = [_]u8{ 'a', 'b' };
    const first = try getCached(&cache, testing.allocator, .{ .text = bytes[0..], .width = 10, .wrap_mode = .none, .width_method = .wcwidth });
    try testing.expectEqual(@as(usize, 1), first.lines.?.len);
    bytes[1] = '\n';
    const second = try getCached(&cache, testing.allocator, .{ .text = bytes[0..], .width = 10, .wrap_mode = .none, .width_method = .wcwidth });
    try testing.expectEqual(@as(usize, 2), second.lines.?.len);
}
