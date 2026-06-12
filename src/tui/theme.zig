//! Product styling vocabulary. This file is also the vaxis *style* seam:
//! policy modules (render, markdown, status, shimmer, App) import `Style`
//! and `Color` from here instead of vaxis, so the real vendor surface stays
//! confined to Terminal.zig, render.zig, input.zig, and text.zig.
const vaxis = @import("vaxis");

pub const Style = vaxis.Style;
pub const Color = vaxis.Color;

pub const ThemeId = enum { codex };

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

    pub fn codex() Theme {
        const cyan: Color = .{ .index = 6 };
        const magenta: Color = .{ .index = 5 };
        const green: Color = .{ .index = 2 };
        const yellow: Color = .{ .index = 3 };
        const red: Color = .{ .index = 1 };
        const user_bg: Color = .{ .index = 236 };

        const accent: Style = .{ .fg = cyan, .bold = true };
        const muted: Style = .{ .dim = true };
        return .{
            .id = .codex,
            .shell_label = .{ .fg = magenta, .bold = true },
            .composer_chrome = muted,
            .composer_slot = accent,
            .composer_prompt = accent,
            .composer_text = .{},
            .transcript_text = .{},
            .transcript_user = .{ .bg = user_bg },
            .transcript_secondary = muted,
            .tool_chrome = muted,
            .tool_title = .{ .bold = true },
            .tool_output = muted,
            .diff_add = .{ .fg = green },
            .diff_del = .{ .fg = red },
            .status_accent = accent,
            .status_warning = .{ .fg = yellow, .bold = true },
            .status_error = .{ .fg = red, .bold = true },
        };
    }
};

pub fn resolve(id: ThemeId) Theme {
    return switch (id) {
        .codex => .codex(),
    };
}
