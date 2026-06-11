const std = @import("std");
const vaxis = @import("vaxis");
const wrap = @import("wrap.zig");

pub const Config = struct {
    lead_pad_cols: u16 = 6,
    tail_pad_cols: u16 = 10,
    band_half_width: u16 = 2,
    base_style: vaxis.Style,
    edge_style: vaxis.Style,
    peak_style: vaxis.Style,
};

pub const Bucket = enum { base, edge, peak };
const segment_count_max: usize = 256;

pub fn phaseForTick(tick: u64, config: Config, text: []const u8) u32 {
    const period = shimmerPeriod(config, text);
    if (period == 0) return 0;
    return @intCast(tick % period);
}

fn shimmerPeriod(config: Config, text: []const u8) u64 {
    return wrap.displayWidth(text) + config.lead_pad_cols + config.tail_pad_cols;
}

pub fn bucketForColumn(config: Config, phase: u32, visual_col: usize) Bucket {
    const text_pos: i64 = @intCast(@as(usize, config.lead_pad_cols) + visual_col);
    const center: i64 = phase;
    const dist = if (text_pos >= center) text_pos - center else center - text_pos;
    const half_width: i64 = config.band_half_width;
    if (dist == 0) return .peak;
    if (half_width == 0 or dist > half_width) return .base;
    if (dist * 2 <= half_width) return .peak;
    return .edge;
}

pub fn strengthForColumn(config: Config, phase: u32, visual_col: usize) u8 {
    const text_pos: i64 = @intCast(@as(usize, config.lead_pad_cols) + visual_col);
    const center: i64 = phase;
    const dist = if (text_pos >= center) text_pos - center else center - text_pos;
    const radius: i64 = config.band_half_width;
    if (radius <= 0) return if (dist == 0) 255 else 0;
    if (dist > radius) return 0;

    const numerator = (radius - dist + 1) * 255;
    const denominator = radius + 1;
    return @intCast(@min(@divTrunc(numerator, denominator), 255));
}

pub fn floorStrength(raw_strength: u8, floor: u8) u8 {
    const raw: i32 = raw_strength;
    const floor_i: i32 = floor;
    if (raw <= floor_i) return 0;
    const numer = (raw - floor_i) * 255;
    const denom = 255 - floor_i;
    return @intCast(@divTrunc(numer, denom));
}

pub fn lerpColor(from: vaxis.Color, to: vaxis.Color, t: u8) vaxis.Color {
    return switch (from) {
        .default => if (t == 0) from else to,
        .rgb => |from_rgb| switch (to) {
            .default => if (t == 255) to else from,
            .rgb => |to_rgb| .{ .rgb = .{
                lerpChannel(from_rgb[0], to_rgb[0], t),
                lerpChannel(from_rgb[1], to_rgb[1], t),
                lerpChannel(from_rgb[2], to_rgb[2], t),
            } },
            .index => if (t < 128) from else to,
        },
        .index => switch (to) {
            .default => if (t == 255) to else from,
            .rgb, .index => if (t < 128) from else to,
        },
    };
}

pub fn write(
    renderer: anytype,
    x: u16,
    y: u16,
    text: []const u8,
    tick: u64,
    config: Config,
) !u16 {
    const phase = phaseForTick(tick, config, text);
    var cursor_x = x;
    var visual_col: usize = 0;
    var run_start: usize = 0;
    var run_x = x;
    var run_bucket: ?Bucket = null;
    var index: usize = 0;
    while (index < text.len and cursor_x < renderer.width) {
        const char_start = index;
        const grapheme = wrap.nextGrapheme(text[index..]);
        if (grapheme.end == 0) break;
        const bucket = bucketForColumn(config, phase, visual_col);
        if (run_bucket == null) {
            run_bucket = bucket;
            run_start = char_start;
            run_x = cursor_x;
        } else if (run_bucket.? != bucket) {
            try renderer.writeText(run_x, y, text[run_start..char_start], styleForBucket(config, run_bucket.?));
            run_bucket = bucket;
            run_start = char_start;
            run_x = cursor_x;
        }
        cursor_x = advance(cursor_x, grapheme.width);
        visual_col += grapheme.width;
        index += grapheme.end;
    }
    if (run_bucket) |bucket| try renderer.writeText(run_x, y, text[run_start..index], styleForBucket(config, bucket));
    return cursor_x;
}

pub fn writeSmooth(
    renderer: anytype,
    x: u16,
    y: u16,
    text: []const u8,
    tick: u64,
    config: Config,
    floor: u8,
) !u16 {
    const phase = phaseForTick(tick, config, text);
    var cursor_x = x;
    var visual_col: usize = 0;
    var index: usize = 0;
    var segments: [segment_count_max]vaxis.Segment = undefined;
    var segment_count: usize = 0;
    var segment_x = x;

    while (index < text.len and cursor_x < renderer.width) {
        const grapheme = wrap.nextGrapheme(text[index..]);
        if (grapheme.end == 0) break;
        const slice = text[index .. index + grapheme.end];
        const strength = floorStrength(strengthForColumn(config, phase, visual_col), floor);
        var style = config.base_style;
        if (strength > 0) style.fg = lerpColor(config.base_style.fg, config.peak_style.fg, strength);
        if (strength >= 224) style = mergeStyle(style, config.peak_style);

        if (segment_count == segments.len) {
            renderer.printSegments(segment_x, y, segments[0..segment_count]);
            segment_x = cursor_x;
            segment_count = 0;
        }
        segments[segment_count] = .{ .text = slice, .style = style };
        segment_count += 1;

        cursor_x = advance(cursor_x, grapheme.width);
        visual_col += grapheme.width;
        index += grapheme.end;
    }
    renderer.printSegments(segment_x, y, segments[0..segment_count]);
    return cursor_x;
}

fn styleForBucket(config: Config, bucket: Bucket) vaxis.Style {
    return switch (bucket) {
        .base => config.base_style,
        .edge => config.edge_style,
        .peak => config.peak_style,
    };
}

fn lerpChannel(from: u8, to: u8, t: u8) u8 {
    const from_i: i32 = from;
    const to_i: i32 = to;
    const delta = to_i - from_i;
    const value = from_i + @divTrunc(delta * @as(i32, t), 255);
    return @intCast(@max(0, @min(value, 255)));
}

fn mergeStyle(base: vaxis.Style, overlay: vaxis.Style) vaxis.Style {
    return .{
        .fg = if (overlay.fg == .default) base.fg else overlay.fg,
        .bg = if (overlay.bg == .default) base.bg else overlay.bg,
        .bold = base.bold or overlay.bold,
        .dim = base.dim or overlay.dim,
        .ul = if (overlay.ul == .default) base.ul else overlay.ul,
        .ul_style = if (overlay.ul_style == .off) base.ul_style else overlay.ul_style,
    };
}

fn advance(x: u16, width: usize) u16 {
    return @intCast(@min(@as(usize, std.math.maxInt(u16)), @as(usize, x) + width));
}
