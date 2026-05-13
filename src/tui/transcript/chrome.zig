const std = @import("std");
const buffer_mod = @import("../primitives/surface.zig");
const cell_mod = @import("../cell.zig");
const layout = @import("layout.zig");
const Region = buffer_mod.Region;
const Color = cell_mod.Color;
const Attributes = cell_mod.Attributes;

pub const Style = struct {
    chrome: Color,
    fg: Color,
    dim: Color,
};

fn draw(fg_color: Color) layout.Style {
    return .{ .fg = fg_color, .bg = Color.default, .attrs = .{} };
}

pub fn topSegments(arena: std.mem.Allocator, header: ?[]const u8, style: Style) ![]const layout.Segment {
    var segs: std.ArrayListUnmanaged(layout.Segment) = .empty;
    var col: u32 = 0;
    try segs.append(arena, .{ .x = col, .text = "╭─", .style = draw(style.chrome) });
    col += 2;
    if (header) |h| {
        try segs.append(arena, .{ .x = col, .text = "[", .style = draw(style.chrome) });
        col += 1;
        try segs.append(arena, .{ .x = col, .text = h, .style = draw(style.fg) });
        col += @intCast(h.len);
        try segs.append(arena, .{ .x = col, .text = "]", .style = draw(style.chrome) });
    }
    return try segs.toOwnedSlice(arena);
}

pub fn contentSegments(arena: std.mem.Allocator, gutter: ?[]const u8, gutter_width: u32, text: []const u8, style: Style, highlight: bool) ![]const layout.Segment {
    var segs: std.ArrayListUnmanaged(layout.Segment) = .empty;
    const text_color = if (highlight) style.fg else style.dim;
    var col: u32 = 0;
    if (gutter_width > 0) {
        if (gutter) |g| {
            const g_len = @min(@as(u32, @intCast(g.len)), gutter_width);
            col += gutter_width - g_len;
            try segs.append(arena, .{ .x = col, .text = g, .style = draw(text_color) });
            col += g_len;
        } else col += gutter_width;
        try segs.append(arena, .{ .x = col, .text = " " });
        col += 1;
        try segs.append(arena, .{ .x = col, .text = "│", .style = draw(style.chrome) });
        col += 1;
        try segs.append(arena, .{ .x = col, .text = " " });
        col += 1;
    } else {
        try segs.append(arena, .{ .x = col, .text = "│", .style = draw(style.chrome) });
        col += 1;
        try segs.append(arena, .{ .x = col, .text = " " });
        col += 1;
    }
    try segs.append(arena, .{ .x = col, .text = text, .style = draw(text_color) });
    return try segs.toOwnedSlice(arena);
}

pub fn elisionSegments(arena: std.mem.Allocator, count: u32, gutter_width: u32, style: Style) ![]const layout.Segment {
    var segs: std.ArrayListUnmanaged(layout.Segment) = .empty;
    var col: u32 = 0;
    if (gutter_width > 0) {
        col += gutter_width;
        try segs.append(arena, .{ .x = col, .text = " " });
        col += 1;
        try segs.append(arena, .{ .x = col, .text = "·", .style = draw(style.chrome) });
        col += 1;
        try segs.append(arena, .{ .x = col, .text = " " });
        col += 1;
    } else {
        try segs.append(arena, .{ .x = col, .text = "·", .style = draw(style.chrome) });
        col += 1;
        try segs.append(arena, .{ .x = col, .text = " " });
        col += 1;
    }
    const hint = try std.fmt.allocPrint(arena, "··· {d} more lines", .{count});
    try segs.append(arena, .{ .x = col, .text = hint, .style = draw(style.dim) });
    return try segs.toOwnedSlice(arena);
}

pub fn bottomSegments(arena: std.mem.Allocator, style: Style) ![]const layout.Segment {
    return try arena.dupe(layout.Segment, &.{.{ .x = 0, .text = "╰────", .style = draw(style.chrome) }});
}

pub fn noticeSegments(arena: std.mem.Allocator, notice: []const u8, style: Style) ![]const layout.Segment {
    return try arena.dupe(layout.Segment, &.{
        .{ .x = 0, .text = "[", .style = draw(style.dim) },
        .{ .x = 1, .text = notice, .style = draw(style.dim) },
        .{ .x = 1 + @as(u32, @intCast(notice.len)), .text = "]", .style = draw(style.dim) },
    });
}

pub fn chromeWidth(gutter_width: u32) u32 {
    return if (gutter_width > 0) gutter_width + 3 else 2;
}

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

pub fn drawBottom(region: Region, row: u32, style: Style) u32 {
    if (row >= region.height) return 0;
    _ = region.writeStr(0, row, "╰────", style.chrome, Color.default, .{});
    return 1;
}

pub fn measureHeight(visible_lines: u32, gap_count: u32) u32 {
    return 1 + visible_lines + gap_count + 1;
}

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
            right_w = region.textWidth(r);
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
