//! Product styling vocabulary. This file is also the vaxis *style* seam:
//! policy modules (render, markdown, status, shimmer, App) import `Style`
//! and `Color` from here instead of vaxis, so the real vendor surface stays
//! confined to Terminal.zig, render.zig, input.zig, and text.zig.
//!
//! Theme colors are chosen from the terminal's ANSI palette by default.  A
//! TerminalInfo capability lets the frontend supply the terminal's real
//! background and color level so the theme can adapt without probing inside
//! the TUI core.
const std = @import("std");
const ansi = @import("ansi.zig");
const vaxis = @import("vaxis");

pub const Style = vaxis.Style;
pub const Color = vaxis.Color;

pub const ThemeId = enum { codex };

pub const Rgb = [3]u8;

pub const ColorScheme = enum { dark, light };

pub const ColorLevel = enum { truecolor, ansi256, ansi16, unknown };

pub const TerminalInfo = struct {
    fg: ?Rgb = null,
    bg: ?Rgb = null,
    scheme: ?ColorScheme = null,
    color_level: ColorLevel = .unknown,
};

pub const Theme = struct {
    id: ThemeId,

    shell_label: Style,
    composer_chrome: Style,
    composer_slot: Style,
    composer_prompt: Style,
    composer_text: Style,
    transcript_text: Style,
    transcript_user: Style,
    transcript_secondary: Style,
    tool_chrome: Style,
    tool_title: Style,
    tool_output: Style,
    diff_add: Style,
    diff_del: Style,
    status_accent: Style,
    status_canceled: Style,
    status_warning: Style,
    status_error: Style,
    shimmer_base: Style,
    shimmer_peak: Style,
    picker_selected: Style,
    picker_unselected: Style,
    picker_detail: Style,
    picker_empty: Style,
    picker_filter: Style,

    pub fn codex(info: TerminalInfo) Theme {
        const scheme = resolveScheme(info);
        const accent = accentStyle(info, scheme);
        const muted: Style = .{ .dim = true };
        const user_bg = userMessageBg(info, scheme);

        return .{
            .id = .codex,
            .shell_label = .{ .fg = ansi.magenta, .bold = true },
            .composer_chrome = muted,
            .composer_slot = muted,
            .composer_prompt = accent,
            .composer_text = .{},
            .transcript_text = .{},
            .transcript_user = if (user_bg) |c| .{ .bg = c } else .{},
            .transcript_secondary = muted,
            .tool_chrome = muted,
            .tool_title = .{ .bold = true },
            .tool_output = muted,
            .diff_add = .{ .fg = ansi.green },
            .diff_del = .{ .fg = ansi.red },
            .status_accent = accent,
            .status_canceled = canceledStyle(info, scheme),
            .status_warning = .{ .fg = ansi.yellow, .bold = true },
            .status_error = .{ .fg = ansi.red, .bold = true },
            .shimmer_base = shimmerBaseStyle(info, scheme),
            .shimmer_peak = shimmerPeakStyle(info, scheme),
            .picker_selected = accent,
            .picker_unselected = .{},
            .picker_detail = muted,
            .picker_empty = muted,
            .picker_filter = .{},
        };
    }
};

pub fn resolve(id: ThemeId, info: TerminalInfo) Theme {
    return switch (id) {
        .codex => .codex(info),
    };
}

fn resolveScheme(info: TerminalInfo) ColorScheme {
    if (info.scheme) |scheme| return scheme;
    if (info.bg) |bg| return if (isLight(bg)) .light else .dark;
    return .dark;
}

fn accentStyle(info: TerminalInfo, scheme: ColorScheme) Style {
    const cyan: Color = switch (scheme) {
        .dark => ansi.cyan,
        .light => if (info.color_level == .ansi256 or info.color_level == .truecolor)
            bestColor(info, .{ 0, 95, 135 })
        else
            ansi.cyan,
    };
    return .{ .fg = cyan, .bold = true };
}

fn canceledStyle(info: TerminalInfo, scheme: ColorScheme) Style {
    return .{ .fg = switch (info.color_level) {
        .truecolor, .ansi256 => bestColor(info, switch (scheme) {
            .dark => .{ 180, 140, 255 },
            .light => .{ 95, 0, 135 },
        }),
        .ansi16, .unknown => ansi.magenta,
    }, .bold = true };
}

fn shimmerBaseStyle(info: TerminalInfo, scheme: ColorScheme) Style {
    return .{ .fg = .{ .rgb = info.fg orelse switch (scheme) {
        .dark => .{ 128, 128, 128 },
        .light => .{ 96, 96, 96 },
    } }, .dim = true };
}

fn shimmerPeakStyle(_: TerminalInfo, scheme: ColorScheme) Style {
    return .{ .fg = .{ .rgb = switch (scheme) {
        .dark => .{ 255, 255, 255 },
        .light => .{ 0, 0, 0 },
    } }, .bold = true };
}

fn userMessageBg(info: TerminalInfo, scheme: ColorScheme) ?Color {
    return switch (info.color_level) {
        .truecolor, .ansi256 => if (info.bg) |bg| bestColor(info, blendUserMessageBg(bg, scheme)) else switch (scheme) {
            .dark => .{ .index = 236 },
            .light => .{ .index = 253 },
        },
        .ansi16, .unknown => null,
    };
}

/// Terminal-safe approximation for a target RGB color. This deliberately
/// returns fixed xterm-256 indexes instead of raw RGB: shimmer is the only TUI
/// path allowed to emit custom colors.
pub fn bestColor(info: TerminalInfo, target: Rgb) Color {
    return switch (info.color_level) {
        .truecolor, .ansi256 => .{ .index = nearestXtermFixedIndex(target) },
        .ansi16, .unknown => .default,
    };
}

fn nearestXtermFixedIndex(target: Rgb) u8 {
    var best_index: u8 = 16;
    var best_distance: u32 = std.math.maxInt(u32);
    var index: u16 = 16;
    while (index < 256) : (index += 1) {
        const candidate_index: u8 = @intCast(index);
        const distance = distanceSquared(target, xtermFixedRgb(candidate_index));
        if (distance < best_distance) {
            best_distance = distance;
            best_index = candidate_index;
        }
    }
    return best_index;
}

fn xtermFixedRgb(index: u8) Rgb {
    std.debug.assert(index >= 16);
    if (index < 232) {
        const offset = index - 16;
        return .{
            xtermCubeChannel(offset / 36),
            xtermCubeChannel((offset / 6) % 6),
            xtermCubeChannel(offset % 6),
        };
    }
    const level: u8 = 8 + 10 * (index - 232);
    return .{ level, level, level };
}

fn xtermCubeChannel(value: u8) u8 {
    return if (value == 0) 0 else 55 + 40 * value;
}

fn distanceSquared(a: Rgb, b: Rgb) u32 {
    return channelDistanceSquared(a[0], b[0]) +
        channelDistanceSquared(a[1], b[1]) +
        channelDistanceSquared(a[2], b[2]);
}

fn channelDistanceSquared(a: u8, b: u8) u32 {
    const delta = @as(i32, a) - @as(i32, b);
    return @intCast(delta * delta);
}

fn blendUserMessageBg(bg: Rgb, scheme: ColorScheme) Rgb {
    const top: Rgb = switch (scheme) {
        .dark => .{ 255, 255, 255 },
        .light => .{ 0, 0, 0 },
    };
    const alpha: f32 = switch (scheme) {
        .dark => 0.12,
        .light => 0.04,
    };
    return .{
        blendChannel(top[0], bg[0], alpha),
        blendChannel(top[1], bg[1], alpha),
        blendChannel(top[2], bg[2], alpha),
    };
}

fn blendChannel(top: u8, bottom: u8, alpha: f32) u8 {
    const t = @as(f32, top);
    const b = @as(f32, bottom);
    return @intFromFloat(std.math.clamp(t * alpha + b * (1.0 - alpha), 0.0, 255.0));
}

fn isLight(rgb: Rgb) bool {
    const r = @as(f32, rgb[0]);
    const g = @as(f32, rgb[1]);
    const b = @as(f32, rgb[2]);
    const y = 0.299 * r + 0.587 * g + 0.114 * b;
    return y > 128.0;
}

test "bestColor avoids terminal-remapped ANSI palette" {
    const color = bestColor(.{ .color_level = .ansi256 }, .{ 180, 140, 255 });
    try std.testing.expect(color == .index);
    try std.testing.expect(color.index >= 16);
}

test "canceled status uses fixed palette when available" {
    const theme = Theme.codex(.{ .color_level = .ansi256 });
    try std.testing.expect(theme.status_canceled.fg == .index);
    try std.testing.expect(theme.status_canceled.fg.index >= 16);
}
