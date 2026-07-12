//! Bounded shimmer text effect for animated status copy.
//!
//! Shimmer is the only TUI path allowed to synthesize ad-hoc RGB colors: the
//! sweep needs a fine gradient. Normal UI colors must use semantic tokens from
//! screen.zig.
const std = @import("std");
const vaxis = @import("vaxis");
const screen = @import("screen.zig");

const phase_scale: u32 = 256;

pub const Config = struct {
    lead_pad_cols: u16 = 6,
    tail_pad_cols: u16 = 10,
    band_half_width: u16 = 3,
    base_style: screen.Style = screen.shimmer.base,
    peak_style: screen.Style = screen.shimmer.peak,
    floor: u8 = 0,
    ms_per_col: u64 = 32,
};

const Range = struct {
    start: usize,
    end: usize,
    style: screen.Style,
};

pub fn phaseForNs(now_ns: u64, config: Config, text: []const u8) u32 {
    const period_cols = screen.displayWidth(text) + config.lead_pad_cols + config.tail_pad_cols;
    if (period_cols == 0 or config.ms_per_col == 0) return 0;
    const elapsed_ms = now_ns / std.time.ns_per_ms;
    const period = @as(u128, period_cols) * phase_scale;
    return @intCast(((elapsed_ms * phase_scale) / config.ms_per_col) % period);
}

pub fn strengthForColumn(config: Config, phase: u32, visual_col: usize) u8 {
    const text_pos = @as(i64, @intCast(@as(usize, config.lead_pad_cols) + visual_col)) * phase_scale;
    const center: i64 = phase;
    const dist = @abs(text_pos - center);
    const radius = @as(i64, config.band_half_width) * phase_scale;
    if (radius <= 0) return if (dist == 0) 255 else 0;
    if (dist > radius) return 0;
    const numerator = (radius - @as(i64, @intCast(dist))) * 255;
    return @intCast(@min(@divTrunc(numerator, radius), 255));
}

pub fn styleForColumn(config: Config, phase: u32, visual_col: usize) screen.Style {
    const strength = flooredStrength(strengthForColumn(config, phase, visual_col), config.floor);
    var style = config.base_style;
    if (strength > 0) style.fg = lerpColor(config.base_style.fg, config.peak_style.fg, strength);
    if (strength >= 224) style = mergeStyle(style, config.peak_style);
    return style;
}

pub fn append(line: *screen.Line, text: []const u8, now_ns: u64, config: Config) error{LineFull}!void {
    if (text.len == 0) return;
    var ranges: [screen.span_capacity]Range = undefined;
    const range_count = buildRanges(&ranges, text, phaseForNs(now_ns, config, text), config) orelse {
        try line.append(.{ .text = text, .style = config.base_style });
        return;
    };
    if (range_count > screen.span_capacity - line.span_len) {
        try line.append(.{ .text = text, .style = config.base_style });
        return;
    }
    for (ranges[0..range_count]) |range| {
        if (range.start == range.end) continue;
        try line.append(.{ .text = text[range.start..range.end], .style = range.style });
    }
}

fn buildRanges(out: []Range, text: []const u8, phase: u32, config: Config) ?usize {
    var iter = vaxis.unicode.graphemeIterator(text);
    var count: usize = 0;
    var segment_start: usize = 0;
    var segment_end: usize = 0;
    var segment_style: ?screen.Style = null;
    var visual_col: usize = 0;

    while (iter.next()) |grapheme| {
        const bytes = grapheme.bytes(text);
        if (std.mem.eql(u8, bytes, "\n")) break;
        const style = styleForColumn(config, phase, visual_col);
        if (segment_style) |current| {
            if (!screen.Style.eql(current, style)) {
                if (count == out.len) return null;
                out[count] = .{ .start = segment_start, .end = grapheme.start, .style = current };
                count += 1;
                segment_start = grapheme.start;
            }
        } else {
            segment_start = grapheme.start;
        }
        segment_style = style;
        segment_end = grapheme.start + grapheme.len;
        visual_col += @intCast(vaxis.gwidth.gwidth(bytes, .unicode));
    }

    if (segment_style) |style| {
        if (count == out.len) return null;
        out[count] = .{ .start = segment_start, .end = segment_end, .style = style };
        count += 1;
    }
    return count;
}

fn flooredStrength(raw_strength: u8, floor: u8) u8 {
    const raw: i32 = raw_strength;
    const floor_i: i32 = floor;
    if (raw <= floor_i) return 0;
    return @intCast(@divTrunc((raw - floor_i) * 255, 255 - floor_i));
}

pub fn lerpColor(from: screen.Color, to: screen.Color, t: u8) screen.Color {
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

fn lerpChannel(from: u8, to: u8, t: u8) u8 {
    const delta = @as(i32, to) - @as(i32, from);
    const value = @as(i32, from) + @divTrunc(delta * @as(i32, t), 255);
    return @intCast(@max(0, @min(value, 255)));
}

fn mergeStyle(base: screen.Style, overlay: screen.Style) screen.Style {
    return .{
        .fg = if (overlay.fg == .default) base.fg else overlay.fg,
        .bg = if (overlay.bg == .default) base.bg else overlay.bg,
        .ul = if (overlay.ul == .default) base.ul else overlay.ul,
        .ul_style = if (overlay.ul_style == .off) base.ul_style else overlay.ul_style,
        .bold = base.bold or overlay.bold,
        .dim = base.dim or overlay.dim,
        .italic = base.italic or overlay.italic,
        .blink = base.blink or overlay.blink,
        .reverse = base.reverse or overlay.reverse,
        .invisible = base.invisible or overlay.invisible,
        .strikethrough = base.strikethrough or overlay.strikethrough,
    };
}

test "phase advances with time and wraps at the period" {
    const config: Config = .{};
    const period: u64 = screen.displayWidth("abc") + config.lead_pad_cols + config.tail_pad_cols;
    try std.testing.expectEqual(@as(u32, 0), phaseForNs(0, config, "abc"));
    try std.testing.expectEqual(@as(u32, phase_scale / 2), phaseForNs((config.ms_per_col * std.time.ns_per_ms) / 2, config, "abc"));
    try std.testing.expectEqual(@as(u32, phase_scale), phaseForNs(config.ms_per_col * std.time.ns_per_ms, config, "abc"));
    try std.testing.expectEqual(@as(u32, 0), phaseForNs(period * config.ms_per_col * std.time.ns_per_ms, config, "abc"));
}

test "strength peaks at the band center and fades to zero" {
    const config: Config = .{ .band_half_width = 2 };
    const phase: u32 = @as(u32, config.lead_pad_cols) * phase_scale;
    try std.testing.expectEqual(@as(u8, 255), strengthForColumn(config, phase, 0));
    try std.testing.expect(strengthForColumn(config, phase, 1) < 255);
    try std.testing.expect(strengthForColumn(config, phase, 1) > 0);
    try std.testing.expectEqual(@as(u8, 0), strengthForColumn(config, phase, 5));
}

test "rgb styles interpolate for the shimmer exception" {
    const config: Config = .{
        .band_half_width = 2,
        .base_style = .{ .fg = .{ .rgb = .{ 0, 0, 0 } } },
        .peak_style = .{ .fg = .{ .rgb = .{ 255, 255, 255 } } },
    };
    const phase = @as(u32, config.lead_pad_cols) * phase_scale + phase_scale / 2;
    const style = styleForColumn(config, phase, 0);
    try std.testing.expect(style.fg == .rgb);
    try std.testing.expect(style.fg.rgb[0] > 0);
    try std.testing.expect(style.fg.rgb[0] < 255);
}

test "append degrades to one base span when span budget would overflow" {
    var line: screen.Line = .{};
    try append(&line, "this is a very long working status", 0, .{ .band_half_width = 80 });
    try std.testing.expectEqual(@as(usize, 1), line.spans().len);
    try std.testing.expect(screen.Style.eql(screen.shimmer.base, line.spans()[0].style));
}
