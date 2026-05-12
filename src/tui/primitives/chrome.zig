const std = @import("std");
const box_chrome = @import("../surfaces/box_chrome.zig");
const buffer_mod = @import("surface.zig");
const cell_mod = @import("../cell.zig");
const theme_mod = @import("../theme.zig");

const Buffer = buffer_mod.Buffer;
const Region = buffer_mod.Region;
const Color = cell_mod.Color;
const Cell = cell_mod.Cell;
const Attributes = cell_mod.Attributes;
const Theme = theme_mod.Theme;

pub const Tone = enum {
    neutral,
    muted,
    info,
    success,
    warning,
    danger,
    accent,
};

pub const BorderStyle = enum {
    rounded,
    square,
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
        while (col < region.width) : (col += 1) {
            region.set(col, 0, cell);
        }
    }
};

pub const Frame = struct {
    title: ?[]const u8 = null,
    trailing: ?[]const u8 = null,
    border: BorderStyle = .rounded,
    tone: Tone = .neutral,

    color: ?Color = null,

    pub const Layout = struct {
        body: Region,
    };

    pub fn render(self: Frame, region: Region, theme: *const Theme) ?Layout {
        if (region.width < 2 or region.height < 2) return null;
        const fg = self.color orelse toneFg(theme, self.tone);
        switch (self.border) {
            .rounded => {
                const style = box_chrome.Style{ .chrome = fg, .fg = fg, .dim = fg };
                const frame = box_chrome.closedFrame(region);
                _ = frame.drawTop(self.title, self.trailing, style);
                _ = frame.drawBottom(style);
                var row: u32 = 0;
                while (row < frame.inner.height) : (row += 1) {
                    _ = frame.drawBodyRow(row, style);
                }
                return .{ .body = frame.inner };
            },
            .square => {
                drawSquareFrame(region, self.title, self.trailing, fg);
                return .{ .body = region.sub(1, 1, region.width - 2, region.height - 2) };
            },
        }
    }
};

fn drawSquareFrame(region: Region, title: ?[]const u8, trailing: ?[]const u8, fg: Color) void {
    const attrs = Attributes.none;
    const bg = Color.default;
    region.set(0, 0, charCell('┌', fg, bg, attrs));
    region.set(region.width - 1, 0, charCell('┐', fg, bg, attrs));
    region.set(0, region.height - 1, charCell('└', fg, bg, attrs));
    region.set(region.width - 1, region.height - 1, charCell('┘', fg, bg, attrs));

    var x: u32 = 1;
    while (x + 1 < region.width) : (x += 1) {
        region.set(x, 0, charCell('─', fg, bg, attrs));
        region.set(x, region.height - 1, charCell('─', fg, bg, attrs));
    }

    var y: u32 = 1;
    while (y + 1 < region.height) : (y += 1) {
        region.set(0, y, charCell('│', fg, bg, attrs));
        region.set(region.width - 1, y, charCell('│', fg, bg, attrs));
    }

    var col: u32 = 2;
    if (title) |t| if (t.len > 0 and col < region.width - 1) {
        col += region.writeStr(col, 0, " ", Color.default, bg, attrs);
        col += region.writeStr(col, 0, t, fg, bg, attrs);
        _ = region.writeStr(col, 0, " ", Color.default, bg, attrs);
    };

    if (trailing) |s| if (s.len > 0 and region.width > 4) {
        const w = region.textWidth(s) + 2;
        if (w + 2 < region.width) {
            const start = region.width - 2 - w;
            _ = region.writeStr(start, 0, " ", Color.default, bg, attrs);
            _ = region.writeStr(start + 1, 0, s, fg, bg, attrs);
            _ = region.writeStr(start + 1 + region.textWidth(s), 0, " ", Color.default, bg, attrs);
        }
    };
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
