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
    status_warning: Style,
    status_error: Style,
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
            .status_warning = .{ .fg = ansi.yellow, .bold = true },
            .status_error = .{ .fg = ansi.red, .bold = true },
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
        .light => if (info.color_level == .truecolor)
            .{ .rgb = .{ 0, 95, 135 } }
        else
            ansi.cyan,
    };
    return .{ .fg = cyan, .bold = true };
}

fn userMessageBg(info: TerminalInfo, scheme: ColorScheme) ?Color {
    return switch (info.color_level) {
        .truecolor => if (info.bg) |bg| .{ .rgb = blendUserMessageBg(bg, scheme) } else null,
        .ansi256 => switch (scheme) {
            .dark => .{ .index = 236 },
            .light => .{ .index = 253 },
        },
        .ansi16, .unknown => null,
    };
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
