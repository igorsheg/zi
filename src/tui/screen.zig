const std = @import("std");
const vaxis = @import("vaxis");

pub const row_capacity = 512;
pub const span_capacity = 8;

pub const Style = vaxis.Style;

pub const styles = struct {
    pub const normal: Style = .{};
    pub const muted: Style = .{ .dim = true };
    pub const accent: Style = .{ .bold = true };
    pub const error_: Style = .{ .fg = .{ .index = 1 } };
};

pub const Span = struct {
    text: []const u8,
    style: Style = styles.normal,
};

pub const Line = struct {
    spans_buffer: [span_capacity]Span = undefined,
    span_len: usize = 0,

    pub fn spans(self: *const Line) []const Span {
        return self.spans_buffer[0..self.span_len];
    }

    pub fn append(self: *Line, span: Span) error{LineFull}!void {
        if (self.span_len == span_capacity) return error.LineFull; // bounded policy: reject.
        self.spans_buffer[self.span_len] = span;
        self.span_len += 1;
    }

    pub fn textBytes(self: *const Line) usize {
        var total: usize = 0;
        for (self.spans()) |span| total += span.text.len;
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

pub const Screen = struct {
    pub fn paint(_: *Screen, vx: *vaxis.Vaxis, tty_writer: *std.Io.Writer, frame: Frame) !void {
        const win = vx.window();
        win.clear();
        for (frame.rows(), 0..) |line, row| {
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
