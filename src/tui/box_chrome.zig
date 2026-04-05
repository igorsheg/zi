const std = @import("std");
const buffer_mod = @import("buffer.zig");
const cell_mod = @import("cell.zig");
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

// --- tests ---

const testing = std.testing;
const Buffer = buffer_mod.Buffer;

const test_style = Style{
    .chrome = Color.default,
    .fg = Color.default,
    .dim = Color.default,
};

test "drawTop renders header" {
    var buf = try Buffer.init(testing.allocator, 30, 1);
    defer buf.deinit();
    const rows = drawTop(buf.region(), 0, "file.zig", test_style);
    try testing.expectEqual(@as(u32, 1), rows);
    try testing.expectEqual(@as(u21, '╭'), buf.get(0, 0).grapheme.codepoint);
}

test "drawTop without header" {
    var buf = try Buffer.init(testing.allocator, 30, 1);
    defer buf.deinit();
    _ = drawTop(buf.region(), 0, null, test_style);
    try testing.expectEqual(@as(u21, '╭'), buf.get(0, 0).grapheme.codepoint);
}

test "drawContentLine with gutter" {
    var buf = try Buffer.init(testing.allocator, 30, 1);
    defer buf.deinit();
    _ = drawContentLine(buf.region(), 0, "42", 3, "hello", test_style, true);
    try testing.expectEqual(@as(u21, '4'), buf.get(1, 0).grapheme.codepoint);
    try testing.expectEqual(@as(u21, '2'), buf.get(2, 0).grapheme.codepoint);
    try testing.expectEqual(@as(u21, '│'), buf.get(4, 0).grapheme.codepoint);
    try testing.expectEqual(@as(u21, 'h'), buf.get(6, 0).grapheme.codepoint);
}

test "drawContentLine without gutter" {
    var buf = try Buffer.init(testing.allocator, 30, 1);
    defer buf.deinit();
    _ = drawContentLine(buf.region(), 0, null, 0, "hello", test_style, true);
    try testing.expectEqual(@as(u21, '│'), buf.get(0, 0).grapheme.codepoint);
    try testing.expectEqual(@as(u21, 'h'), buf.get(2, 0).grapheme.codepoint);
}

test "drawBottom renders footer" {
    var buf = try Buffer.init(testing.allocator, 30, 1);
    defer buf.deinit();
    _ = drawBottom(buf.region(), 0, test_style);
    try testing.expectEqual(@as(u21, '╰'), buf.get(0, 0).grapheme.codepoint);
}

test "drawElision shows count" {
    var buf = try Buffer.init(testing.allocator, 40, 1);
    defer buf.deinit();
    _ = drawElision(buf.region(), 0, 95, 0, test_style);
    try testing.expectEqual(@as(u21, '·'), buf.get(0, 0).grapheme.codepoint);
}

test "chromeWidth" {
    try testing.expectEqual(@as(u32, 2), chromeWidth(0));
    try testing.expectEqual(@as(u32, 6), chromeWidth(3));
    try testing.expectEqual(@as(u32, 7), chromeWidth(4));
}

test "measureHeight" {
    try testing.expectEqual(@as(u32, 12), measureHeight(10, 0));
    try testing.expectEqual(@as(u32, 8), measureHeight(5, 1));
}
