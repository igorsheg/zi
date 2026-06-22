//! Shimmer math for animated status text: a brightness band sweeps across
//! the text. Pure functions of (config, time, column); render.zig owns the
//! actual terminal writes.
const std = @import("std");
const text_mod = @import("text.zig");
const theme = @import("theme.zig");

const phase_scale: u32 = 256;

pub const Config = struct {
    lead_pad_cols: u16 = 6,
    tail_pad_cols: u16 = 10,
    band_half_width: u16 = 3,
    base_style: theme.Style,
    peak_style: theme.Style,
    /// Strengths at or below the floor render as base; above it the band
    /// fades in. Keeps the sweep from tinting the whole line.
    floor: u8 = 0,
    /// Milliseconds per column of band travel. Phase is fixed-point, so a
    /// 16ms frame still changes intensity even before the band reaches the
    /// next whole cell.
    ms_per_col: u64 = 32,
};

pub fn phaseForMs(now_ms: i64, config: Config, text: []const u8) u32 {
    const period_cols = text_mod.displayWidth(text) + config.lead_pad_cols + config.tail_pad_cols;
    if (period_cols == 0 or config.ms_per_col == 0) return 0;
    const elapsed: u64 = @intCast(@max(0, now_ms));
    const period = @as(u64, @intCast(period_cols)) * phase_scale;
    return @intCast(((elapsed * phase_scale) / config.ms_per_col) % period);
}

pub fn strengthForColumn(config: Config, phase: u32, visual_col: usize) u8 {
    const text_pos = (@as(i64, @intCast(@as(usize, config.lead_pad_cols) + visual_col)) * phase_scale);
    const center: i64 = phase;
    const dist = @abs(text_pos - center);
    const radius = @as(i64, config.band_half_width) * phase_scale;
    if (radius <= 0) return if (dist == 0) 255 else 0;
    if (dist > radius) return 0;
    const numerator = (radius - @as(i64, @intCast(dist))) * 255;
    return @intCast(@min(@divTrunc(numerator, radius), 255));
}

/// Style for one column at the given band phase: base color lerped toward
/// the peak, with the peak style's attributes merged in near the center.
pub fn styleForColumn(config: Config, phase: u32, visual_col: usize) theme.Style {
    const strength = flooredStrength(strengthForColumn(config, phase, visual_col), config.floor);
    var style = config.base_style;
    if (strength > 0) style.fg = lerpColor(config.base_style.fg, config.peak_style.fg, strength);
    if (strength >= 224) style = mergeStyle(style, config.peak_style);
    return style;
}

fn flooredStrength(raw_strength: u8, floor: u8) u8 {
    const raw: i32 = raw_strength;
    const floor_i: i32 = floor;
    if (raw <= floor_i) return 0;
    return @intCast(@divTrunc((raw - floor_i) * 255, 255 - floor_i));
}

pub fn lerpColor(from: theme.Color, to: theme.Color, t: u8) theme.Color {
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

fn mergeStyle(base: theme.Style, overlay: theme.Style) theme.Style {
    return .{
        .fg = if (overlay.fg == .default) base.fg else overlay.fg,
        .bg = if (overlay.bg == .default) base.bg else overlay.bg,
        .bold = base.bold or overlay.bold,
        .dim = base.dim or overlay.dim,
        .ul = if (overlay.ul == .default) base.ul else overlay.ul,
        .ul_style = if (overlay.ul_style == .off) base.ul_style else overlay.ul_style,
    };
}

test "phase advances with time and wraps at the period" {
    const config: Config = .{ .base_style = .{}, .peak_style = .{ .bold = true } };
    const period: u64 = text_mod.displayWidth("abc") + config.lead_pad_cols + config.tail_pad_cols;
    const p0 = phaseForMs(0, config, "abc");
    const half = phaseForMs(@intCast(config.ms_per_col / 2), config, "abc");
    const p1 = phaseForMs(@intCast(config.ms_per_col), config, "abc");
    try std.testing.expectEqual(@as(u32, 0), p0);
    try std.testing.expectEqual(@as(u32, phase_scale / 2), half);
    try std.testing.expectEqual(@as(u32, phase_scale), p1);
    const wrapped = phaseForMs(@intCast(period * config.ms_per_col), config, "abc");
    try std.testing.expectEqual(@as(u32, 0), wrapped);
}

test "strength peaks at the band center and fades to zero" {
    const config: Config = .{ .band_half_width = 2, .base_style = .{}, .peak_style = .{} };
    const phase: u32 = @as(u32, config.lead_pad_cols) * phase_scale; // center over column 0
    try std.testing.expectEqual(@as(u8, 255), strengthForColumn(config, phase, 0));
    try std.testing.expect(strengthForColumn(config, phase, 1) < 255);
    try std.testing.expect(strengthForColumn(config, phase, 1) > 0);
    try std.testing.expectEqual(@as(u8, 0), strengthForColumn(config, phase, 5));
}

test "sub-column phase changes strength before the band reaches the next cell" {
    const config: Config = .{ .band_half_width = 2, .base_style = .{}, .peak_style = .{} };
    const whole: u32 = @as(u32, config.lead_pad_cols) * phase_scale;
    const half = whole + phase_scale / 2;
    try std.testing.expect(strengthForColumn(config, half, 0) < strengthForColumn(config, whole, 0));
    try std.testing.expect(strengthForColumn(config, half, 1) > strengthForColumn(config, whole, 1));
}

test "rgb styles interpolate instead of jumping to peak" {
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
