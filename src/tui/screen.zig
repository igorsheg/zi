const std = @import("std");
const vaxis = @import("vaxis");

pub const row_capacity = 512;
pub const span_capacity = 16;

pub const Style = vaxis.Style;

pub const styles = struct {
    const bg0 = vaxis.Color{ .rgb = .{ 0x09, 0x0e, 0x13 } };
    const bg1 = vaxis.Color{ .rgb = .{ 0x1c, 0x1e, 0x25 } };
    const bg3 = vaxis.Color{ .rgb = .{ 0x39, 0x3b, 0x44 } };
    const fg_text = vaxis.Color{ .rgb = .{ 0xc5, 0xc9, 0xc7 } };
    const fg_bright = vaxis.Color{ .rgb = .{ 0xf2, 0xf1, 0xef } };
    const muted_fg = vaxis.Color{ .rgb = .{ 0x90, 0x93, 0x98 } };
    const muted2_fg = vaxis.Color{ .rgb = .{ 0x5c, 0x60, 0x66 } };
    const blue_fg = vaxis.Color{ .rgb = .{ 0x7f, 0xb4, 0xca } };
    const red = vaxis.Color{ .rgb = .{ 0xc3, 0x40, 0x43 } };
    const yellow = vaxis.Color{ .rgb = .{ 0xdc, 0xa5, 0x61 } };
    const green = vaxis.Color{ .rgb = .{ 0x98, 0xbb, 0x6c } };
    const diff_add_bg = vaxis.Color{ .rgb = .{ 0x2b, 0x33, 0x28 } };
    const diff_del_bg = vaxis.Color{ .rgb = .{ 0x43, 0x24, 0x2b } };

    pub const normal: Style = .{ .fg = fg_text };
    pub const muted: Style = .{ .fg = muted_fg, .dim = true };
    pub const accent: Style = .{ .bold = true, .fg = blue_fg };
    pub const ok: Style = .{ .fg = green };
    pub const warn: Style = .{ .fg = yellow };
    pub const error_: Style = .{ .fg = red };
    pub const panel: Style = .{ .fg = fg_bright, .bg = bg1 };
    pub const composer_chrome: Style = .{ .fg = muted2_fg, .bg = bg0 };
    pub const composer_slot: Style = .{ .fg = muted_fg, .bg = bg0 };
    pub const composer_text: Style = .{ .fg = fg_text, .bg = bg0 };
    pub const composer_prompt: Style = .{ .bold = true, .fg = blue_fg, .bg = bg0 };
    pub const picker_row: Style = .{ .fg = fg_text, .bg = bg0 };
    pub const picker_selected_row: Style = .{ .fg = fg_bright, .bg = bg3 };
    pub const picker_detail: Style = .{ .fg = muted_fg, .bg = bg0, .dim = true };
    pub const diff_add: Style = .{ .fg = green, .bg = diff_add_bg };
    pub const diff_del: Style = .{ .fg = red, .bg = diff_del_bg };
};

pub const Span = struct {
    text: []const u8,
    style: Style = styles.normal,
};

pub const Line = struct {
    spans_buffer: [span_capacity]Span = undefined,
    span_len: usize = 0,
    row_style: Style = styles.normal,

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

    pub fn appendText(self: *LineBuilder, text: []const u8, style: Style) error{LineFull}!usize {
        if (text.len == 0) return 0;
        try self.line.append(.{ .text = text, .style = style });
        const width = displayWidth(text);
        self.col += width;
        return width;
    }

    pub fn appendClipped(self: *LineBuilder, text: []const u8, max_cols: usize, style: Style) error{LineFull}!usize {
        return self.appendText(sliceForColumns(text, max_cols), style);
    }

    pub fn appendFill(self: *LineBuilder, repeated_text: []const u8, cols: usize, style: Style) error{LineFull}!usize {
        return self.appendClipped(repeated_text, cols, style);
    }

    pub fn finish(self: *const LineBuilder) Line {
        return self.line;
    }
};

pub const Screen = struct {
    pub fn paint(_: *Screen, vx: *vaxis.Vaxis, tty_writer: *std.Io.Writer, frame: Frame) !void {
        const win = vx.window();
        win.clear();
        for (frame.rows(), 0..) |line, row| {
            if (!Style.eql(line.row_style, styles.normal)) {
                var fill_col: u16 = 0;
                while (fill_col < vx.screen.width) : (fill_col += 1) {
                    win.writeCell(fill_col, @intCast(row), .{ .style = line.row_style });
                }
            }
            var col: u16 = 0;
            for (line.spans()) |span| {
                const result = win.printSegment(.{
                    .text = span.text,
                    .style = span.style,
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
        try vx.render(tty_writer);
    }
};

pub fn singleSpanLine(text: []const u8, style: Style) Line {
    var line: Line = .{};
    line.append(.{ .text = text, .style = style }) catch unreachable;
    return line;
}

pub fn displayWidth(text: []const u8) usize {
    if (asciiDisplayWidth(text)) |width| return width;
    var iter = vaxis.unicode.graphemeIterator(text);
    var width: usize = 0;
    while (iter.next()) |grapheme| {
        const bytes = grapheme.bytes(text);
        if (std.mem.eql(u8, bytes, "\n")) break;
        width += @intCast(vaxis.gwidth.gwidth(bytes, .unicode));
    }
    return width;
}

pub fn sliceForColumns(text: []const u8, max_cols: usize) []const u8 {
    return text[0..sliceEndForColumns(text, max_cols)];
}

pub fn sliceEndForColumns(text: []const u8, max_cols: usize) usize {
    if (text.len == 0 or max_cols == 0) return 0;
    if (asciiSliceEndForColumns(text, max_cols)) |end| return end;
    var iter = vaxis.unicode.graphemeIterator(text);
    var used: usize = 0;
    var last: usize = 0;
    while (iter.next()) |grapheme| {
        const bytes = grapheme.bytes(text);
        if (std.mem.eql(u8, bytes, "\n")) break;
        const width: usize = @intCast(vaxis.gwidth.gwidth(bytes, .unicode));
        if (width != 0 and used + width > max_cols) break;
        used += width;
        last = grapheme.start + grapheme.len;
    }
    return last;
}

fn asciiDisplayWidth(text: []const u8) ?usize {
    var width: usize = 0;
    for (text) |byte| {
        if (byte == '\n') break;
        if (byte < 0x20 or byte >= 0x80) return null;
        width += 1;
    }
    return width;
}

fn asciiSliceEndForColumns(text: []const u8, max_cols: usize) ?usize {
    var index: usize = 0;
    var used: usize = 0;
    while (index < text.len and used < max_cols) : (index += 1) {
        const byte = text[index];
        if (byte < 0x20 or byte >= 0x80) return null;
        used += 1;
    }
    return index;
}

test "frame stores fixed rows and spans" {
    var frame: Frame = .{};
    try frame.appendLine(singleSpanLine("hello", styles.accent));

    var line: Line = .{};
    try line.append(.{ .text = "a" });
    try line.append(.{ .text = "b", .style = styles.muted });
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

test "line builder tracks display columns" {
    var builder = LineBuilder.init(styles.normal);
    _ = try builder.appendText("a", styles.normal);
    _ = try builder.appendClipped("🙂b", 2, styles.accent);
    _ = try builder.appendText("c", styles.normal);
    const line = builder.finish();

    try std.testing.expectEqual(@as(usize, 4), line.cellWidth());
    try std.testing.expectEqual(@as(usize, 4), builder.col);
}
