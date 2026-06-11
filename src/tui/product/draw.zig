const vaxis = @import("vaxis");

pub const Cursor = struct { x: u16, y: u16 };

pub const Context = struct {
    vx: *vaxis.Vaxis,
    width: u16,
    height: u16,
    cursor: ?Cursor = null,

    pub fn init(vx: *vaxis.Vaxis) Context {
        return .{ .vx = vx, .width = vx.screen.width, .height = vx.screen.height };
    }

    pub fn clear(self: *Context) void {
        self.vx.window().clear();
        self.clearCursor();
    }

    pub fn clearCursor(self: *Context) void {
        self.cursor = null;
        self.vx.window().hideCursor();
    }

    pub fn setCursor(self: *Context, cursor: Cursor) void {
        if (cursor.x >= self.width or cursor.y >= self.height) {
            self.clearCursor();
            return;
        }
        self.cursor = cursor;
        self.vx.window().showCursor(cursor.x, cursor.y);
    }

    pub fn writeText(self: *Context, x: u16, y: u16, bytes: []const u8, style: vaxis.Style) !void {
        if (x >= self.width or y >= self.height or bytes.len == 0) return;
        const segment = vaxis.Segment{ .text = bytes, .style = style };
        _ = self.vx.window().print(&.{segment}, .{ .col_offset = x, .row_offset = y, .wrap = .none });
    }

    pub fn printSegments(self: *Context, x: u16, y: u16, segments: []const vaxis.Segment) void {
        if (x >= self.width or y >= self.height or segments.len == 0) return;
        _ = self.vx.window().print(segments, .{ .col_offset = x, .row_offset = y, .wrap = .none });
    }

    pub fn fillRect(self: *Context, x: u16, y: u16, w: u16, h: u16, style: vaxis.Style) !void {
        if (x >= self.width or y >= self.height) return;
        const max_w = @min(w, self.width - x);
        const max_h = @min(h, self.height - y);
        var win = self.vx.window().child(.{ .x_off = @intCast(x), .y_off = @intCast(y), .width = max_w, .height = max_h });
        win.fill(.{ .style = style });
    }

    pub fn roundedBorder(self: *Context, x: u16, y: u16, w: u16, h: u16, style: vaxis.Style) void {
        if (x >= self.width or y >= self.height) return;
        const max_w = @min(w, self.width - x);
        const max_h = @min(h, self.height - y);
        _ = self.vx.window().child(.{
            .x_off = @intCast(x),
            .y_off = @intCast(y),
            .width = max_w,
            .height = max_h,
            .border = .{ .where = .all, .style = style, .glyphs = .single_rounded },
        });
    }
};
