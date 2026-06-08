const std = @import("std");
const infra = @import("../infra/root.zig");
const primitive = @import("../primitive/root.zig");
const shimmer = @import("shimmer.zig");
const slots = @import("slots.zig");
const theme_mod = @import("theme.zig");

const separator = " · ";
const status_shimmer_config: shimmer.Config = .{
    .lead_pad_cols = 6,
    .tail_pad_cols = 10,
    .band_half_width = 2,
    .base_style = .{ .dim = true },
    .edge_style = .{ .fg = .{ .rgb = .{ .r = 120, .g = 120, .b = 120 } } },
    .peak_style = .{ .fg = .{ .rgb = .{ .r = 255, .g = 255, .b = 255 } }, .bold = true },
};

pub fn visibleRows(has_status: bool, height: u16, composer_rows: usize) usize {
    if (!has_status) return 0;
    if (height == 0) return 0;
    if (@as(usize, height) <= composer_rows) return 0;
    return 1;
}

pub fn draw(
    renderer: *infra.Renderer,
    theme: theme_mod.Theme,
    y: u16,
    width: u16,
    views: []const slots.SlotView,
    tick: u64,
) !void {
    if (width == 0 or views.len == 0) return;
    try renderer.fillRect(0, y, width, 1, .{});
    var x: u16 = 0;
    var rendered_any = false;
    for (views) |view| {
        if (view.text.len == 0) continue;
        const remaining = if (x < width) width - x else 0;
        if (remaining == 0) return;
        const sep_width = if (rendered_any) primitive.text.displayWidth(separator) else 0;
        if (sep_width >= remaining) return;
        const text_width = primitive.text.displayWidth(view.text);
        if (text_width == 0) continue;
        const available = remaining - @as(u16, @intCast(sep_width));
        if (available == 0) return;
        var text = view.text;
        if (rendered_any or text_width > available) {
            var index: usize = 0;
            var fit_width: usize = 0;
            while (index < view.text.len) {
                const grapheme = primitive.text.nextGrapheme(view.text[index..]);
                if (grapheme.end == 0) break;
                if (fit_width + grapheme.width > available) break;
                fit_width += grapheme.width;
                index += grapheme.end;
            }
            text = view.text[0..index];
        }
        if (text.len == 0) continue;

        if (rendered_any) {
            try renderer.writeText(x, y, separator, theme.transcript_secondary);
            x = advance(x, sep_width);
        }
        x = switch (view.effect) {
            .none => blk: {
                try renderer.writeText(x, y, text, theme.transcript_secondary);
                break :blk advance(x, primitive.text.displayWidth(text));
            },
            .shimmer => try shimmer.writeSmooth(renderer, x, y, text, tick / 3, status_shimmer_config, 48),
        };
        rendered_any = true;
    }
}

fn advance(x: u16, width: usize) u16 {
    return @intCast(@min(@as(usize, std.math.maxInt(u16)), @as(usize, x) + width));
}

test "status area appears only when possible" {
    try std.testing.expectEqual(@as(usize, 0), visibleRows(false, 10, 3));
    try std.testing.expectEqual(@as(usize, 1), visibleRows(true, 10, 3));
    try std.testing.expectEqual(@as(usize, 0), visibleRows(true, 3, 3));
}

test "status area draws ordered contributions with separator" {
    var renderer = try infra.Renderer.init(std.testing.allocator, 20, 1, 20);
    defer renderer.deinit();
    const views = [_]slots.SlotView{
        .{ .priority = 2, .text = "one", .effect = .none },
        .{ .priority = 1, .text = "two", .effect = .none },
    };
    try draw(&renderer, theme_mod.Theme.codex(), 0, 20, &views, 0);
    try expectText(renderer.next, 0, 0, "one");
    try expectText(renderer.next, 6, 0, "two");
}

fn expectText(buffer: anytype, x: u16, y: u16, text: []const u8) !void {
    for (text, 0..) |byte, index| {
        const cell = try buffer.get(@intCast(@as(usize, x) + index), y);
        try std.testing.expectEqual(@as(?u21, byte), cell.renderScalar());
    }
}
