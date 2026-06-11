const std = @import("std");
const vaxis = @import("vaxis");
const wrap = @import("wrap.zig");
const shimmer = @import("shimmer.zig");
const slots = @import("slots.zig");
const theme_mod = @import("theme.zig");

const separator = " · ";
const segment_count_max = slots.status_area_slot_count_max * 2;
const status_shimmer_config: shimmer.Config = .{
    .lead_pad_cols = 6,
    .tail_pad_cols = 10,
    .band_half_width = 2,
    .base_style = .{ .dim = true },
    .edge_style = .{ .fg = .{ .rgb = .{ 120, 120, 120 } } },
    .peak_style = .{ .fg = .{ .rgb = .{ 255, 255, 255 } }, .bold = true },
};

pub fn visibleRows(has_status: bool, height: u16, composer_rows: usize) usize {
    if (!has_status) return 0;
    if (height == 0) return 0;
    if (@as(usize, height) <= composer_rows) return 0;
    return 1;
}

pub fn draw(
    renderer: anytype,
    theme: theme_mod.Theme,
    y: u16,
    width: u16,
    views: []const slots.SlotView,
    tick: u64,
) !void {
    if (width == 0 or views.len == 0) return;
    try renderer.fillRect(0, y, width, 1, .{});
    var x: u16 = 0;
    var segment_x: u16 = 0;
    var segments: [segment_count_max]vaxis.Segment = undefined;
    var segment_count: usize = 0;
    var rendered_any = false;
    for (views) |view| {
        if (view.text.len == 0) continue;
        const remaining = if (x < width) width - x else 0;
        if (remaining == 0) return;
        const sep_width = if (rendered_any) wrap.displayWidth(separator) else 0;
        if (sep_width >= remaining) return;
        const text_width = wrap.displayWidth(view.text);
        if (text_width == 0) continue;
        const available = remaining - @as(u16, @intCast(sep_width));
        if (available == 0) return;
        var text = view.text;
        if (rendered_any or text_width > available) {
            var index: usize = 0;
            var fit_width: usize = 0;
            while (index < view.text.len) {
                const grapheme = wrap.nextGrapheme(view.text[index..]);
                if (grapheme.end == 0) break;
                if (fit_width + grapheme.width > available) break;
                fit_width += grapheme.width;
                index += grapheme.end;
            }
            text = view.text[0..index];
        }
        if (text.len == 0) continue;

        if (rendered_any) {
            pushSegment(&segments, &segment_count, .{ .text = separator, .style = theme.transcript_secondary });
            x = advance(x, sep_width);
        }
        x = switch (view.effect) {
            .none => blk: {
                pushSegment(&segments, &segment_count, .{ .text = text, .style = theme.transcript_secondary });
                break :blk advance(x, wrap.displayWidth(text));
            },
            .shimmer => blk: {
                renderer.printSegments(segment_x, y, segments[0..segment_count]);
                segment_count = 0;
                const next_x = try shimmer.writeSmooth(renderer, x, y, text, tick / 3, status_shimmer_config, 48);
                segment_x = next_x;
                break :blk next_x;
            },
        };
        rendered_any = true;
    }
    renderer.printSegments(segment_x, y, segments[0..segment_count]);
}

fn pushSegment(segments: *[segment_count_max]vaxis.Segment, count: *usize, segment: vaxis.Segment) void {
    if (count.* == segments.len) return;
    segments[count.*] = segment;
    count.* += 1;
}

fn advance(x: u16, width: usize) u16 {
    return @intCast(@min(@as(usize, std.math.maxInt(u16)), @as(usize, x) + width));
}

fn expectText(buffer: anytype, x: u16, y: u16, text: []const u8) !void {
    for (text, 0..) |byte, index| {
        const cell = try buffer.get(@intCast(@as(usize, x) + index), y);
        try std.testing.expectEqual(@as(?u21, byte), cell.renderScalar());
    }
}
