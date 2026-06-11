const std = @import("std");
const vaxis = @import("vaxis");

pub const ThemeId = enum { codex };

pub const CodexPalette = struct {
    cyan: vaxis.Color = .{ .index = 6 },
    magenta: vaxis.Color = .{ .index = 5 },
    green: vaxis.Color = .{ .index = 2 },
    yellow: vaxis.Color = .{ .index = 3 },
    red: vaxis.Color = .{ .index = 1 },
    user_bg: vaxis.Color = .{ .index = 236 },
};

pub const Theme = struct {
    id: ThemeId,
    accent: vaxis.Style,
    muted: vaxis.Style,
    success: vaxis.Style,
    warning: vaxis.Style,
    failure: vaxis.Style,

    shell_label: vaxis.Style,
    composer_chrome: vaxis.Style,
    composer_slot: vaxis.Style,
    composer_prompt: vaxis.Style,
    composer_text: vaxis.Style,
    transcript_text: vaxis.Style,
    transcript_user: vaxis.Style,
    transcript_secondary: vaxis.Style,
    tool_chrome: vaxis.Style,
    tool_title: vaxis.Style,
    tool_output: vaxis.Style,
    status_accent: vaxis.Style,
    status_success: vaxis.Style,
    status_warning: vaxis.Style,
    status_error: vaxis.Style,

    pub fn codex() Theme {
        const p: CodexPalette = .{};
        const accent: vaxis.Style = .{ .fg = p.cyan, .bold = true };
        const muted: vaxis.Style = .{ .dim = true };
        const success: vaxis.Style = .{ .fg = p.green, .bold = true };
        const warning: vaxis.Style = .{ .fg = p.yellow, .bold = true };
        const err: vaxis.Style = .{ .fg = p.red, .bold = true };
        return .{
            .id = .codex,
            .accent = accent,
            .muted = muted,
            .success = success,
            .warning = warning,
            .failure = err,
            .shell_label = .{ .fg = p.magenta, .bold = true },
            .composer_chrome = muted,
            .composer_slot = accent,
            .composer_prompt = accent,
            .composer_text = .{},
            .transcript_text = .{},
            .transcript_user = .{ .bg = p.user_bg },
            .transcript_secondary = muted,
            .tool_chrome = muted,
            .tool_title = .{ .bold = true },
            .tool_output = muted,
            .status_accent = accent,
            .status_success = success,
            .status_warning = warning,
            .status_error = err,
        };
    }
};

pub fn resolve(id: ThemeId) Theme {
    return switch (id) {
        .codex => .codex(),
    };
}
