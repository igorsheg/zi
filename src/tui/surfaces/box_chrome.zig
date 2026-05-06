const std = @import("std");
const buffer_mod = @import("../primitives/surface.zig");
const cell_mod = @import("../cell.zig");
const Region = buffer_mod.Region;
const Color = cell_mod.Color;
const Attributes = cell_mod.Attributes;

pub const Style = struct {
    chrome: Color,
    fg: Color,
    dim: Color,
};

/// Compute total columns used by chrome (gutter + separator).
/// With gutter:    "  42 │ " = gutter_width + 3 (space + │ + space)
/// Without gutter: "│ "     = 2
pub fn chromeWidth(gutter_width: u32) u32 {
    return if (gutter_width > 0) gutter_width + 3 else 2;
}

/// Draw ╭─[header] or ╭─ at row. Returns 1 (rows consumed).
pub fn drawTop(region: Region, row: u32, header: ?[]const u8, style: Style) u32 {
    if (row >= region.height) return 0;
    var col: u32 = 0;
    col += region.writeStr(col, row, "╭─", style.chrome, Color.default, .{});
    if (header) |h| {
        col += region.writeStr(col, row, "[", style.chrome, Color.default, .{});
        col += region.writeStr(col, row, h, style.fg, Color.default, .{});
        col += region.writeStr(col, row, "]", style.chrome, Color.default, .{});
    }
    return 1;
}

/// Draw a content line with optional right-aligned gutter.
/// Layout: "{gutter} │ {text}" or "│ {text}"
/// highlight=true: gutter+text at style.fg; false: everything at style.dim
pub fn drawContentLine(region: Region, row: u32, gutter: ?[]const u8, gutter_width: u32, text: []const u8, style: Style, highlight: bool) u32 {
    if (row >= region.height) return 0;
    const text_color = if (highlight) style.fg else style.dim;
    var col: u32 = 0;

    if (gutter_width > 0) {
        if (gutter) |g| {
            const g_len = @min(@as(u32, @intCast(g.len)), gutter_width);
            const pad = gutter_width - g_len;
            col += pad;
            col += region.writeStr(col, row, g, if (highlight) style.fg else style.dim, Color.default, .{});
        } else {
            col += gutter_width;
        }
        col += region.writeStr(col, row, " ", Color.default, Color.default, .{});
        col += region.writeStr(col, row, "│", style.chrome, Color.default, .{});
        col += region.writeStr(col, row, " ", Color.default, Color.default, .{});
    } else {
        col += region.writeStr(col, row, "│", style.chrome, Color.default, .{});
        col += region.writeStr(col, row, " ", Color.default, Color.default, .{});
    }

    _ = region.writeStr(col, row, text, text_color, Color.default, .{});
    return 1;
}

/// Draw elision marker: "    · ··· N more lines"
/// Positioned to align with content (respects gutter_width).
pub fn drawElision(region: Region, row: u32, count: u32, gutter_width: u32, style: Style) u32 {
    if (row >= region.height) return 0;
    var col: u32 = 0;

    if (gutter_width > 0) {
        col += gutter_width;
        col += region.writeStr(col, row, " ", Color.default, Color.default, .{});
        col += region.writeStr(col, row, "·", style.chrome, Color.default, .{});
        col += region.writeStr(col, row, " ", Color.default, Color.default, .{});
    } else {
        col += region.writeStr(col, row, "·", style.chrome, Color.default, .{});
        col += region.writeStr(col, row, " ", Color.default, Color.default, .{});
    }

    var buf_arr: [64]u8 = undefined;
    const hint = std.fmt.bufPrint(&buf_arr, "··· {d} more lines", .{count}) catch "···";
    _ = region.writeStr(col, row, hint, style.dim, Color.default, .{});
    return 1;
}

/// Draw ╰──── at row. Returns 1.
pub fn drawBottom(region: Region, row: u32, style: Style) u32 {
    if (row >= region.height) return 0;
    _ = region.writeStr(0, row, "╰────", style.chrome, Color.default, .{});
    return 1;
}

/// Measure total height for box-chrome rendered content.
/// top(1) + visible_lines + elision_markers + bottom(1)
pub fn measureHeight(visible_lines: u32, gap_count: u32) u32 {
    return 1 + visible_lines + gap_count + 1;
}

const grapheme_mod = @import("../grapheme.zig");

/// Draw closed top border: ╭─ {left} ──── {right} ─╮
/// Labels are optional. Fill with ─ between them.
fn drawClosedTopBorder(region: Region, row: u32, left: ?[]const u8, right: ?[]const u8, style: Style) u32 {
    if (row >= region.height or region.width < 4) return 0;
    const w = region.width;
    var col: u32 = 0;

    col += region.writeStr(col, row, "╭─", style.chrome, Color.default, .{});

    var left_w: u32 = 0;
    if (left) |l| {
        if (l.len > 0) {
            col += region.writeStr(col, row, " ", Color.default, Color.default, .{});
            const wrote = region.writeStr(col, row, l, style.fg, Color.default, .{});
            col += wrote;
            left_w = wrote + 1;
            col += region.writeStr(col, row, " ", Color.default, Color.default, .{});
            left_w += 1;
        }
    }

    var right_w: u32 = 0;
    if (right) |r| {
        if (r.len > 0) {
            right_w = @intCast(grapheme_mod.strWidth(r));
            right_w += 2;
        }
    }

    const used = 2 + left_w + right_w + 2;
    if (w > used) {
        const fill = w - used;
        var i: u32 = 0;
        while (i < fill) : (i += 1) {
            col += region.writeStr(col, row, "─", style.chrome, Color.default, .{});
        }
    }

    if (right) |r| {
        if (r.len > 0) {
            col += region.writeStr(col, row, " ", Color.default, Color.default, .{});
            col += region.writeStr(col, row, r, style.dim, Color.default, .{});
            col += region.writeStr(col, row, " ", Color.default, Color.default, .{});
        }
    }

    col += region.writeStr(col, row, "─╮", style.chrome, Color.default, .{});
    return 1;
}

/// Draw closed bottom border: ╰─────╯
fn drawClosedBottomBorder(region: Region, row: u32, style: Style) u32 {
    if (row >= region.height or region.width < 4) return 0;
    const w = region.width;
    var col: u32 = 0;

    col += region.writeStr(col, row, "╰", style.chrome, Color.default, .{});

    const fill = if (w > 2) w - 2 else 0;
    var i: u32 = 0;
    while (i < fill) : (i += 1) {
        col += region.writeStr(col, row, "─", style.chrome, Color.default, .{});
    }

    _ = region.writeStr(col, row, "╯", style.chrome, Color.default, .{});
    return 1;
}

/// Returns the width strictly inside a closed frame, excluding both borders.
pub fn closedInnerWidth(total_width: u32) u32 {
    return if (total_width > 2) total_width - 2 else 1;
}

pub const ClosedFrame = struct {
    outer: Region,
    body: Region,
    inner: Region,

    pub fn init(region: Region) ClosedFrame {
        const body = if (region.height > 2)
            region.sub(0, 1, region.width, region.height - 2)
        else
            region.sub(region.width, region.height, 0, 0);

        const inner = if (region.width > 2 and region.height > 2)
            region.sub(1, 1, closedInnerWidth(region.width), region.height - 2)
        else
            region.sub(region.width, region.height, 0, 0);

        return .{
            .outer = region,
            .body = body,
            .inner = inner,
        };
    }

    pub fn drawTop(self: ClosedFrame, left: ?[]const u8, right: ?[]const u8, style: Style) u32 {
        return drawClosedTopBorder(self.outer, 0, left, right, style);
    }

    pub fn drawBottom(self: ClosedFrame, style: Style) u32 {
        if (self.outer.height == 0) return 0;
        return drawClosedBottomBorder(self.outer, self.outer.height - 1, style);
    }

    /// Draw both side borders for a closed content row: │ ... │
    /// `body_row` is indexed within the box body, so 0 is the first row
    /// beneath the top border.
    pub fn drawBodyRow(self: ClosedFrame, body_row: u32, style: Style) u32 {
        if (self.outer.width == 0 or self.outer.height <= 2) return 0;
        if (body_row >= self.body.height) return 0;

        const row = body_row + 1;
        _ = self.outer.writeStr(0, row, "│", style.chrome, Color.default, .{});
        if (self.outer.width > 1) {
            _ = self.outer.writeStr(self.outer.width - 1, row, "│", style.chrome, Color.default, .{});
        }
        return 1;
    }

    pub fn innerRow(self: ClosedFrame, body_row: u32) Region {
        if (body_row >= self.inner.height) {
            return self.inner.sub(self.inner.width, self.inner.height, 0, 0);
        }
        return self.inner.sub(0, body_row, self.inner.width, 1);
    }
};

pub fn closedFrame(region: Region) ClosedFrame {
    return ClosedFrame.init(region);
}
