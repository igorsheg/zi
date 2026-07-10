const std = @import("std");
const vaxis = @import("vaxis");

pub const row_capacity = 512;
pub const span_capacity = 16;

pub const Style = vaxis.Style;
pub const Color = vaxis.Color;

fn rgb(value: u24) Color {
    return Color.rgbFromUint(value);
}

pub const colors = struct {
    pub const bg = rgb(0x090E13);
    pub const fg = rgb(0xC5C9C7);
    pub const tier1 = rgb(0xBEC2C0);
    pub const tier2 = rgb(0xB2B6B4);
    pub const tier3 = rgb(0xA5A9A7);
    pub const tier4 = rgb(0x9B9690);
    pub const tier5 = rgb(0x7F8381);
    pub const tier6 = rgb(0x6A6E6C);
    pub const tier7 = rgb(0x535755);
    pub const scaffold = rgb(0x626664);
    pub const selection = rgb(0x393B44);
    pub const red = rgb(0xE46876);
    pub const green = rgb(0x87A987);
    pub const yellow = rgb(0xE6C384);
    pub const blue = rgb(0x7FB4CA);
    pub const purple = rgb(0x938AA9);
    pub const teal = rgb(0x7AA89F);
    pub const panel_bg = rgb(0x0D1218);
    pub const panel_bg_light = rgb(0x111820);
    pub const panel_bg_green = rgb(0x0F1A14);
    pub const panel_bg_red = rgb(0x1A0F12);
};

pub fn onSurface(style: Style, row_surface: Style) Style {
    var out = style;
    const resolved_surface = if (row_surface.bg == .default) surface.app else row_surface;
    if (out.bg == .default) out.bg = resolved_surface.bg;
    return out;
}

pub fn withBold(style: Style) Style {
    var out = style;
    out.bold = true;
    return out;
}

pub fn withItalic(style: Style) Style {
    var out = style;
    out.italic = true;
    return out;
}

pub const text = struct {
    pub const normal: Style = .{};
    pub const muted: Style = .{ .fg = colors.tier5 };
    pub const dim: Style = .{ .fg = colors.tier6 };
    pub const scaffold: Style = .{ .fg = colors.scaffold };
    pub const accent: Style = .{ .fg = colors.teal };
    pub const border: Style = .{ .fg = colors.tier6 };
    pub const border_accent: Style = .{ .fg = colors.blue };
    pub const border_muted: Style = .{ .fg = colors.tier7 };
    pub const success: Style = .{ .fg = colors.green };
    pub const error_: Style = .{ .fg = colors.red };
    pub const warning: Style = .{ .fg = colors.yellow };
    pub const thinking: Style = .{ .fg = colors.tier5 };
    pub const user_message: Style = .{};
    pub const custom_message: Style = .{};
    pub const custom_message_label: Style = .{ .fg = colors.purple };
    pub const tool_title: Style = .{};
    pub const tool_output: Style = .{ .fg = colors.tier5 };
    pub const bash_mode: Style = .{ .fg = colors.yellow };
};

pub const shimmer = struct {
    pub const base: Style = .{ .fg = colors.tier6 };
    pub const peak: Style = .{ .fg = colors.tier1, .bold = true };
};

pub const surface = struct {
    pub const transparent: Style = .{};
    pub const app: Style = .{ .bg = colors.bg };
    pub const composer: Style = .{ .bg = colors.bg };
    pub const selected: Style = .{ .bg = colors.selection };
    pub const user_message: Style = .{ .bg = colors.panel_bg };
    pub const custom_message: Style = .{ .bg = colors.panel_bg_light };
    pub const tool_pending: Style = .{ .bg = colors.panel_bg };
    pub const tool_success: Style = .{};
    pub const tool_error: Style = .{ .bg = colors.panel_bg_red };
};

pub const markdown_styles = struct {
    pub const heading: Style = .{ .fg = colors.yellow };
    pub const link: Style = .{ .fg = colors.blue, .ul_style = .single };
    pub const link_url: Style = .{ .fg = colors.tier6 };
    pub const code: Style = .{ .fg = colors.teal };
    pub const code_block: Style = .{ .fg = colors.tier3 };
    pub const code_block_border: Style = .{ .fg = colors.tier7 };
    pub const quote: Style = .{ .fg = colors.tier5, .italic = true };
    pub const quote_border: Style = .{ .fg = colors.tier7 };
    pub const hr: Style = .{ .fg = colors.tier7 };
    pub const list_bullet: Style = .{ .fg = colors.teal };
};

pub const diff = struct {
    pub const added: Style = .{ .fg = rgb(0x98BB6C) };
    pub const removed: Style = .{ .fg = colors.red };
    pub const context: Style = .{ .fg = colors.tier7 };
};

pub const syntax = struct {
    pub const comment: Style = .{ .fg = colors.tier7 };
    pub const keyword: Style = .{ .fg = colors.tier1 };
    pub const function: Style = .{ .fg = colors.tier2 };
    pub const variable: Style = .{ .fg = colors.tier3 };
    pub const string: Style = .{ .fg = colors.tier4 };
    pub const number: Style = .{ .fg = colors.tier4 };
    pub const type_name: Style = .{ .fg = colors.tier5 };
    pub const operator: Style = .{ .fg = colors.tier6 };
    pub const punctuation: Style = .{ .fg = colors.scaffold };
};

pub const Span = struct {
    text: []const u8,
    style: Style = text.normal,
};

pub const Line = struct {
    spans_buffer: [span_capacity]Span = undefined,
    span_len: usize = 0,
    row_style: Style = surface.transparent,

    pub fn spans(self: *const Line) []const Span {
        return self.spans_buffer[0..self.span_len];
    }

    pub fn append(self: *Line, span: Span) error{LineFull}!void {
        if (self.span_len == span_capacity) return error.LineFull; // bounded policy: reject.
        self.spans_buffer[self.span_len] = span;
        self.span_len += 1;
    }

    pub fn prepend(self: *Line, span: Span) error{LineFull}!void {
        if (self.span_len == span_capacity) return error.LineFull; // bounded policy: reject.
        var index = self.span_len;
        while (index > 0) : (index -= 1) self.spans_buffer[index] = self.spans_buffer[index - 1];
        self.spans_buffer[0] = span;
        self.span_len += 1;
    }

    pub fn textBytes(self: *const Line) usize {
        var total: usize = 0;
        for (self.spans()) |span| total += span.text.len;
        return total;
    }

    pub fn cellWidth(self: *const Line) usize {
        var total: usize = 0;
        for (self.spans()) |span| total += displayWidth(span.text);
        return total;
    }

    pub fn copyText(self: *const Line, out: []u8) []const u8 {
        var offset: usize = 0;
        for (self.spans()) |span| {
            if (offset == out.len) break;
            const count = @min(span.text.len, out.len - offset);
            @memcpy(out[offset..][0..count], span.text[0..count]);
            offset += count;
        }
        return out[0..offset];
    }
};

pub const Cursor = struct { col: u16, row: u16 };

pub const Frame = struct {
    rows_buffer: [row_capacity]Line = undefined,
    row_len: usize = 0,
    cursor: ?Cursor = null,

    pub fn rows(self: *const Frame) []const Line {
        return self.rows_buffer[0..self.row_len];
    }

    pub fn appendLine(self: *Frame, line: Line) error{FrameFull}!void {
        if (self.row_len == row_capacity) return error.FrameFull; // bounded policy: reject.
        self.rows_buffer[self.row_len] = line;
        self.row_len += 1;
    }
};

pub const LineBuilder = struct {
    line: Line,
    col: usize = 0,

    pub fn init(row_style: Style) LineBuilder {
        return .{ .line = .{ .row_style = row_style } };
    }

    pub fn appendText(self: *LineBuilder, bytes: []const u8, style: Style) error{LineFull}!usize {
        if (bytes.len == 0) return 0;
        try self.line.append(.{ .text = bytes, .style = style });
        const width = displayWidth(bytes);
        self.col += width;
        return width;
    }

    pub fn appendClipped(self: *LineBuilder, bytes: []const u8, max_cols: usize, style: Style) error{LineFull}!usize {
        return self.appendText(sliceForColumns(bytes, max_cols), style);
    }

    pub fn appendFill(self: *LineBuilder, repeated_text: []const u8, cols: usize, style: Style) error{LineFull}!usize {
        return self.appendClipped(repeated_text, cols, style);
    }

    pub fn finish(self: *const LineBuilder) Line {
        return self.line;
    }
};

pub const Screen = struct {
    pub fn paint(_: *Screen, vx: *vaxis.Vaxis, frame: Frame) void {
        const win = vx.window();
        win.clear();
        for (frame.rows(), 0..) |line, row| {
            if (!Style.eql(line.row_style, surface.transparent)) {
                var fill_col: u16 = 0;
                while (fill_col < vx.screen.width) : (fill_col += 1) {
                    win.writeCell(fill_col, @intCast(row), .{ .style = line.row_style });
                }
            }
            var col: u16 = 0;
            for (line.spans()) |span| {
                const result = win.printSegment(.{
                    .text = span.text,
                    .style = onSurface(span.style, line.row_style),
                }, .{
                    .row_offset = @intCast(row),
                    .col_offset = col,
                    .wrap = .none,
                });
                col = result.col;
            }
        }
        if (frame.cursor) |cursor| {
            win.showCursor(cursor.col, cursor.row);
        } else {
            win.hideCursor();
        }
    }
};

pub fn singleSpanLine(bytes: []const u8, style: Style) Line {
    var line: Line = .{};
    line.append(.{ .text = bytes, .style = style }) catch unreachable;
    return line;
}

pub fn displayWidth(bytes: []const u8) usize {
    if (asciiDisplayWidth(bytes)) |width| return width;
    var iter = vaxis.unicode.graphemeIterator(bytes);
    var width: usize = 0;
    while (iter.next()) |grapheme| {
        const grapheme_bytes = grapheme.bytes(bytes);
        if (std.mem.eql(u8, grapheme_bytes, "\n")) break;
        width += @intCast(vaxis.gwidth.gwidth(grapheme_bytes, .unicode));
    }
    return width;
}

pub fn sliceForColumns(bytes: []const u8, max_cols: usize) []const u8 {
    return bytes[0..sliceEndForColumns(bytes, max_cols)];
}

pub fn sliceEndForColumns(bytes: []const u8, max_cols: usize) usize {
    if (bytes.len == 0 or max_cols == 0) return 0;
    if (asciiSliceEndForColumns(bytes, max_cols)) |end| return end;
    var iter = vaxis.unicode.graphemeIterator(bytes);
    var used: usize = 0;
    var last: usize = 0;
    while (iter.next()) |grapheme| {
        const grapheme_bytes = grapheme.bytes(bytes);
        if (std.mem.eql(u8, grapheme_bytes, "\n")) break;
        const width: usize = @intCast(vaxis.gwidth.gwidth(grapheme_bytes, .unicode));
        if (width != 0 and used + width > max_cols) break;
        used += width;
        last = grapheme.start + grapheme.len;
    }
    return last;
}

pub fn firstGraphemeEnd(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    if (bytes[0] < 0x80) return 1;
    var iter = vaxis.unicode.graphemeIterator(bytes);
    const grapheme = iter.next() orelse return 1;
    return grapheme.start + grapheme.len;
}

fn asciiDisplayWidth(bytes: []const u8) ?usize {
    var width: usize = 0;
    for (bytes) |byte| {
        if (byte == '\n') break;
        if (byte < 0x20 or byte >= 0x80) return null;
        width += 1;
    }
    return width;
}

fn asciiSliceEndForColumns(bytes: []const u8, max_cols: usize) ?usize {
    var index: usize = 0;
    var used: usize = 0;
    while (index < bytes.len and used < max_cols) : (index += 1) {
        const byte = bytes[index];
        if (byte < 0x20 or byte >= 0x80) return null;
        used += 1;
    }
    return index;
}

test "frame stores fixed rows and spans" {
    var frame: Frame = .{};
    try frame.appendLine(singleSpanLine("hello", text.accent));

    var line: Line = .{};
    try line.append(.{ .text = "a" });
    try line.append(.{ .text = "b", .style = text.muted });
    try frame.appendLine(line);

    try std.testing.expectEqual(@as(usize, 2), frame.rows().len);
    var buffer: [8]u8 = undefined;
    try std.testing.expectEqualStrings("ab", frame.rows()[1].copyText(&buffer));
}

test "frame and line reject overflow" {
    var line: Line = .{};
    for (0..span_capacity) |_| try line.append(.{ .text = "x" });
    try std.testing.expectError(error.LineFull, line.append(.{ .text = "x" }));

    var frame: Frame = .{};
    for (0..row_capacity) |_| try frame.appendLine(.{});
    try std.testing.expectError(error.FrameFull, frame.appendLine(.{}));
}

test "line can prepend padding span" {
    var line: Line = .{};
    try line.append(.{ .text = "body" });
    try line.prepend(.{ .text = " " });

    var buffer: [8]u8 = undefined;
    try std.testing.expectEqualStrings(" body", line.copyText(&buffer));
}

test "screen measures and clips by display columns" {
    try std.testing.expectEqual(@as(usize, 9), displayWidth("ctx ↑0 ↓0"));
    try std.testing.expectEqualStrings("ctx ↑0", sliceForColumns("ctx ↑0 ↓0", 6));
    try std.testing.expectEqualStrings("", sliceForColumns("🙂", 1));
}

test "transparent span inherits row or app surface" {
    const selected = onSurface(text.normal, surface.selected);
    try std.testing.expect(std.meta.eql(selected.bg, surface.selected.bg));

    const app = onSurface(text.normal, surface.transparent);
    try std.testing.expect(std.meta.eql(app.bg, surface.app.bg));

    var explicit = text.normal;
    explicit.bg = colors.panel_bg_red;
    const preserved = onSurface(explicit, surface.selected);
    try std.testing.expect(std.meta.eql(preserved.bg, explicit.bg));
}

test "line builder tracks display columns" {
    var builder = LineBuilder.init(surface.transparent);
    _ = try builder.appendText("a", text.normal);
    _ = try builder.appendClipped("🙂b", 2, text.accent);
    _ = try builder.appendText("c", text.normal);
    const line = builder.finish();

    try std.testing.expectEqual(@as(usize, 4), line.cellWidth());
    try std.testing.expectEqual(@as(usize, 4), builder.col);
}
