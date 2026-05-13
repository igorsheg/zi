const std = @import("std");
const buffer_mod = @import("surface.zig");
const cell_mod = @import("../cell.zig");
const theme_mod = @import("../theme.zig");

const Buffer = buffer_mod.Buffer;
const Region = buffer_mod.Region;
const Color = cell_mod.Color;
const Cell = cell_mod.Cell;
const Attributes = cell_mod.Attributes;
const Theme = theme_mod.Theme;

pub const Tone = enum { neutral, muted, info, success, warning, danger, accent };
pub const BorderStyle = enum { rounded, square };

pub const Style = struct {
    chrome: Color,
    fg: Color,
    dim: Color,
};

pub fn toneFg(theme: *const Theme, tone: Tone) Color {
    return switch (tone) {
        .neutral => theme.fg(.text),
        .muted => theme.fg(.muted),
        .info => theme.fg(.accent),
        .success => theme.fg(.success),
        .warning => theme.fg(.warning),
        .danger => theme.fg(.@"error"),
        .accent => theme.fg(.accent),
    };
}

pub const Separator = struct {
    color: ?Color = null,

    pub fn render(self: Separator, region: Region, theme: *const Theme) void {
        if (region.width == 0 or region.height == 0) return;
        const fg = self.color orelse theme.fg(.border_muted);
        const cell = charCell('─', fg, Color.default, Attributes.none);
        var col: u32 = 0;
        while (col < region.width) : (col += 1) region.set(col, 0, cell);
    }
};

pub const Frame = struct {
    title: ?[]const u8 = null,
    trailing: ?[]const u8 = null,
    border: BorderStyle = .rounded,
    tone: Tone = .neutral,
    color: ?Color = null,

    pub const Layout = struct { body: Region };

    pub fn render(self: Frame, region: Region, theme: *const Theme) ?Layout {
        if (region.width < 2 or region.height < 2) return null;
        const fg = self.color orelse toneFg(theme, self.tone);
        switch (self.border) {
            .rounded => drawFrame(region, self.title, self.trailing, fg, rounded_corners),
            .square => drawFrame(region, self.title, self.trailing, fg, square_corners),
        }
        return .{ .body = region.sub(1, 1, region.width - 2, region.height - 2) };
    }
};

pub fn closedInnerWidth(total_width: u32) u32 {
    return if (total_width > 2) total_width - 2 else 1;
}

pub const ClosedFrame = struct {
    outer: Region,
    body: Region,
    inner: Region,

    pub fn init(region: Region) ClosedFrame {
        const body = if (region.height > 2) region.sub(0, 1, region.width, region.height - 2) else region.sub(region.width, region.height, 0, 0);
        const inner = if (region.width > 2 and region.height > 2) region.sub(1, 1, closedInnerWidth(region.width), region.height - 2) else region.sub(region.width, region.height, 0, 0);
        return .{ .outer = region, .body = body, .inner = inner };
    }

    pub fn drawTop(self: ClosedFrame, left: ?[]const u8, right: ?[]const u8, style: Style) u32 {
        if (self.outer.height == 0) return 0;
        drawFrameTop(self.outer, 0, left, right, style.chrome, style.fg, style.dim, rounded_corners);
        return 1;
    }

    pub fn drawBottom(self: ClosedFrame, style: Style) u32 {
        if (self.outer.height == 0) return 0;
        drawFrameBottom(self.outer, self.outer.height - 1, style.chrome, rounded_corners);
        return 1;
    }

    pub fn drawBodyRow(self: ClosedFrame, body_row: u32, style: Style) u32 {
        if (self.outer.width == 0 or self.outer.height <= 2 or body_row >= self.body.height) return 0;
        const row = body_row + 1;
        _ = self.outer.writeStr(0, row, "│", style.chrome, Color.default, .{});
        if (self.outer.width > 1) _ = self.outer.writeStr(self.outer.width - 1, row, "│", style.chrome, Color.default, .{});
        return 1;
    }

    pub fn innerRow(self: ClosedFrame, body_row: u32) Region {
        if (body_row >= self.inner.height) return self.inner.sub(self.inner.width, self.inner.height, 0, 0);
        return self.inner.sub(0, body_row, self.inner.width, 1);
    }
};

pub fn closedFrame(region: Region) ClosedFrame {
    return ClosedFrame.init(region);
}

const Corners = struct { tl: u21, tr: u21, bl: u21, br: u21 };
const rounded_corners = Corners{ .tl = '╭', .tr = '╮', .bl = '╰', .br = '╯' };
const square_corners = Corners{ .tl = '┌', .tr = '┐', .bl = '└', .br = '┘' };

fn drawFrame(region: Region, title: ?[]const u8, trailing: ?[]const u8, fg: Color, corners: Corners) void {
    drawFrameTop(region, 0, title, trailing, fg, fg, fg, corners);
    drawFrameBottom(region, region.height - 1, fg, corners);
    var y: u32 = 1;
    while (y + 1 < region.height) : (y += 1) {
        region.set(0, y, charCell('│', fg, Color.default, Attributes.none));
        region.set(region.width - 1, y, charCell('│', fg, Color.default, Attributes.none));
    }
}

fn drawFrameTop(region: Region, row: u32, title: ?[]const u8, trailing: ?[]const u8, chrome: Color, fg: Color, dim: Color, corners: Corners) void {
    const attrs = Attributes.none;
    const bg = Color.default;
    region.set(0, row, charCell(corners.tl, chrome, bg, attrs));
    var x: u32 = 1;
    while (x + 1 < region.width) : (x += 1) region.set(x, row, charCell('─', chrome, bg, attrs));
    region.set(region.width - 1, row, charCell(corners.tr, chrome, bg, attrs));

    var col: u32 = 2;
    if (title) |t| if (t.len > 0 and col < region.width - 1) {
        col += region.writeStr(col, row, " ", Color.default, bg, attrs);
        col += region.writeStr(col, row, t, fg, bg, attrs);
        _ = region.writeStr(col, row, " ", Color.default, bg, attrs);
    };

    if (trailing) |s| if (s.len > 0 and region.width > 4) {
        const w = region.textWidth(s) + 2;
        if (w + 2 < region.width) {
            const start = region.width - 2 - w;
            _ = region.writeStr(start, row, " ", Color.default, bg, attrs);
            _ = region.writeStr(start + 1, row, s, dim, bg, attrs);
            _ = region.writeStr(start + 1 + region.textWidth(s), row, " ", Color.default, bg, attrs);
        }
    };
}

fn drawFrameBottom(region: Region, row: u32, fg: Color, corners: Corners) void {
    const attrs = Attributes.none;
    const bg = Color.default;
    region.set(0, row, charCell(corners.bl, fg, bg, attrs));
    var x: u32 = 1;
    while (x + 1 < region.width) : (x += 1) region.set(x, row, charCell('─', fg, bg, attrs));
    region.set(region.width - 1, row, charCell(corners.br, fg, bg, attrs));
}

fn charCell(cp: u21, fg: Color, bg: Color, attrs: Attributes) Cell {
    return .{ .grapheme = .{ .codepoint = cp }, .fg = fg, .bg = bg, .attrs = attrs };
}

test "Separator renders muted horizontal rule" {
    var buf = try Buffer.init(std.testing.allocator, 4, 2, .wcwidth);
    defer buf.deinit();

    const theme = @import("../../themes/builtin.zig").dark();
    (Separator{}).render(buf.region().sub(0, 1, 4, 1), theme);

    const expected = theme.fg(.border_muted);
    var col: u32 = 0;
    while (col < 4) : (col += 1) {
        const cell = buf.get(col, 1);
        try std.testing.expect(cell.grapheme.eql(.{ .codepoint = '─' }));
        try std.testing.expect(cell.fg.eql(expected));
    }
}
