//! Product styling vocabulary. This file is also the vaxis *style* seam:
//! policy modules (render, markdown, status, shimmer, App) import `Style`
//! and `Color` from here instead of vaxis, so the real vendor surface stays
//! confined to Terminal.zig, render.zig, input.zig, and text.zig.
//!
//! Zi owns its product colors. Terminal capabilities decide only how the
//! chosen palette is encoded: truecolor RGB, fixed xterm-256 approximation, or
//! terminal default as a last-resort degradation.
const std = @import("std");
const vaxis = @import("vaxis");

pub const Style = vaxis.Style;
pub const Color = vaxis.Color;

pub const ThemeId = enum { kanso_zen };

pub const Rgb = [3]u8;

pub const ColorScheme = enum { dark, light };

pub const ColorLevel = enum { truecolor, ansi256, ansi16, unknown };

pub const TerminalInfo = struct {
    fg: ?Rgb = null,
    bg: ?Rgb = null,
    scheme: ?ColorScheme = null,
    color_level: ColorLevel = .unknown,
};

const Palette = struct {
    bg0: Rgb,
    bg1: Rgb,
    bg2: Rgb,
    bg3: Rgb,
    bg4: Rgb,
    fg: Rgb,
    fg_bright: Rgb,
    muted: Rgb,
    muted2: Rgb,
    red: Rgb,
    yellow: Rgb,
    green: Rgb,
    blue: Rgb,
    violet: Rgb,
    aqua: Rgb,
    orange: Rgb,
    diff_add_bg: Rgb,
    diff_del_bg: Rgb,
};

const kanso_zen: Palette = .{
    .bg0 = .{ 0x09, 0x0e, 0x13 },
    .bg1 = .{ 0x1c, 0x1e, 0x25 },
    .bg2 = .{ 0x22, 0x26, 0x2d },
    .bg3 = .{ 0x39, 0x3b, 0x44 },
    .bg4 = .{ 0x4b, 0x4e, 0x57 },
    .fg = .{ 0xc5, 0xc9, 0xc7 },
    .fg_bright = .{ 0xf2, 0xf1, 0xef },
    .muted = .{ 0x90, 0x93, 0x98 },
    .muted2 = .{ 0x5c, 0x60, 0x66 },
    .red = .{ 0xc3, 0x40, 0x43 },
    .yellow = .{ 0xdc, 0xa5, 0x61 },
    .green = .{ 0x98, 0xbb, 0x6c },
    .blue = .{ 0x7f, 0xb4, 0xca },
    .violet = .{ 0x89, 0x92, 0xa7 },
    .aqua = .{ 0x8e, 0xa4, 0xa2 },
    .orange = .{ 0xb6, 0x92, 0x7b },
    .diff_add_bg = .{ 0x2b, 0x33, 0x28 },
    .diff_del_bg = .{ 0x43, 0x24, 0x2b },
};

pub const Theme = struct {
    id: ThemeId,

    app_bg: Style,
    panel_bg: Style,
    selection_bg: Style,
    border: Style,
    border_active: Style,

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
    picker_row: Style,
    picker_filter: Style,
    picker_empty: Style,
    picker_item: Style,
    picker_detail: Style,
    picker_selected_row: Style,
    picker_selected_item: Style,
    picker_selected_detail: Style,

    pub fn kansoZen(info: TerminalInfo) Theme {
        const p = kanso_zen;
        const bg0 = bestColor(info, p.bg0);
        const bg1 = bestColor(info, p.bg1);
        const bg3 = bestColor(info, p.bg3);
        const fg_text = bestColor(info, p.fg);
        const fg_bright = bestColor(info, p.fg_bright);
        const muted = bestColor(info, p.muted);
        const muted2 = bestColor(info, p.muted2);
        const blue = bestColor(info, p.blue);
        const violet = bestColor(info, p.violet);
        const red = bestColor(info, p.red);
        const yellow = bestColor(info, p.yellow);
        const green = bestColor(info, p.green);
        const diff_add_bg = bestColor(info, p.diff_add_bg);
        const diff_del_bg = bestColor(info, p.diff_del_bg);

        return .{
            .id = .kanso_zen,
            .app_bg = .{ .fg = fg_text, .bg = bg0 },
            .panel_bg = .{ .fg = fg_text, .bg = bg1 },
            .selection_bg = .{ .fg = fg_bright, .bg = bg3 },
            .border = .{ .fg = muted2, .bg = bg0 },
            .border_active = .{ .fg = blue, .bg = bg0, .bold = true },
            .shell_label = .{ .fg = violet, .bg = bg0, .bold = true },
            .composer_chrome = .{ .fg = muted2, .bg = bg0 },
            .composer_slot = .{ .fg = muted, .bg = bg0 },
            .composer_prompt = .{ .fg = blue, .bg = bg0, .bold = true },
            .composer_text = .{ .fg = fg_text, .bg = bg0 },
            .transcript_text = .{ .fg = fg_text, .bg = bg0 },
            .transcript_user = .{ .fg = fg_bright, .bg = bg1 },
            .transcript_secondary = .{ .fg = muted, .bg = bg0 },
            .tool_chrome = .{ .fg = muted2, .bg = bg0 },
            .tool_title = .{ .fg = blue, .bg = bg0, .bold = true },
            .tool_output = .{ .fg = muted, .bg = bg0 },
            .diff_add = .{ .fg = green, .bg = diff_add_bg },
            .diff_del = .{ .fg = red, .bg = diff_del_bg },
            .status_accent = .{ .fg = blue, .bg = bg0, .bold = true },
            .status_canceled = .{ .fg = violet, .bg = bg0, .bold = true },
            .status_warning = .{ .fg = yellow, .bg = bg0, .bold = true },
            .status_error = .{ .fg = red, .bg = bg0, .bold = true },
            .shimmer_base = .{ .fg = muted2, .bg = bg0, .dim = true },
            .shimmer_peak = .{ .fg = fg_bright, .bg = bg0, .bold = true },
            .picker_row = .{ .fg = fg_text, .bg = bg0 },
            .picker_filter = .{ .fg = blue, .bg = bg0 },
            .picker_empty = .{ .fg = muted, .bg = bg0 },
            .picker_item = .{ .fg = fg_text, .bg = bg0 },
            .picker_detail = .{ .fg = muted, .bg = bg0 },
            .picker_selected_row = .{ .fg = fg_text, .bg = bg0 },
            .picker_selected_item = .{ .fg = blue, .bg = bg0, .bold = true },
            .picker_selected_detail = .{ .fg = blue, .bg = bg0, .bold = true },
        };
    }
};

pub fn resolve(id: ThemeId, info: TerminalInfo) Theme {
    return switch (id) {
        .kanso_zen => .kansoZen(info),
    };
}

/// Terminal-safe encoding for an opinionated RGB color. This chooses no color:
/// the theme already did that. It only adapts the representation to terminal
/// capability.
pub fn transparent() Style {
    return .{};
}

pub fn bestColor(info: TerminalInfo, target: Rgb) Color {
    return switch (info.color_level) {
        .truecolor => .{ .rgb = target },
        .ansi256 => .{ .index = nearestXtermFixedIndex(target) },
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

test "kanso zen uses truecolor rgb when available" {
    const theme = Theme.kansoZen(.{ .color_level = .truecolor });
    try std.testing.expect(theme.transcript_text.fg == .rgb);
    try std.testing.expectEqual(@as(Rgb, .{ 0xc5, 0xc9, 0xc7 }), theme.transcript_text.fg.rgb);
    try std.testing.expect(theme.app_bg.bg == .rgb);
    try std.testing.expectEqual(@as(Rgb, .{ 0x09, 0x0e, 0x13 }), theme.app_bg.bg.rgb);
}

test "kanso zen degrades to fixed xterm colors for ansi256" {
    const theme = Theme.kansoZen(.{ .color_level = .ansi256 });
    try std.testing.expect(theme.status_canceled.fg == .index);
    try std.testing.expect(theme.status_canceled.fg.index >= 16);
    try std.testing.expect(theme.app_bg.bg == .index);
    try std.testing.expect(theme.app_bg.bg.index >= 16);
}
