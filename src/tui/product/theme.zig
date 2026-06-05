const std = @import("std");
const primitive = @import("../primitive/root.zig");

pub const ThemeId = enum { codex };

pub const CodexPalette = struct {
    cyan: primitive.Color = .{ .indexed = 6 },
    magenta: primitive.Color = .{ .indexed = 5 },
    green: primitive.Color = .{ .indexed = 2 },
    yellow: primitive.Color = .{ .indexed = 3 },
    red: primitive.Color = .{ .indexed = 1 },
    user_bg: primitive.Color = .{ .indexed = 236 },
};

pub const Theme = struct {
    id: ThemeId,
    accent: primitive.Style,
    muted: primitive.Style,
    success: primitive.Style,
    warning: primitive.Style,
    failure: primitive.Style,

    shell_label: primitive.Style,
    composer_prompt: primitive.Style,
    composer_text: primitive.Style,
    transcript_text: primitive.Style,
    transcript_user: primitive.Style,
    transcript_secondary: primitive.Style,
    tool_chrome: primitive.Style,
    status_accent: primitive.Style,
    status_success: primitive.Style,
    status_warning: primitive.Style,
    status_error: primitive.Style,

    pub fn codex() Theme {
        const p: CodexPalette = .{};
        const accent: primitive.Style = .{ .fg = p.cyan, .bold = true };
        const muted: primitive.Style = .{ .dim = true };
        const success: primitive.Style = .{ .fg = p.green, .bold = true };
        const warning: primitive.Style = .{ .fg = p.yellow, .bold = true };
        const err: primitive.Style = .{ .fg = p.red, .bold = true };
        return .{
            .id = .codex,
            .accent = accent,
            .muted = muted,
            .success = success,
            .warning = warning,
            .failure = err,
            .shell_label = .{ .fg = p.magenta, .bold = true },
            .composer_prompt = accent,
            .composer_text = .{},
            .transcript_text = .{},
            .transcript_user = .{ .bg = p.user_bg },
            .transcript_secondary = muted,
            .tool_chrome = muted,
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

test "codex theme maps palette to semantic styles" {
    const theme = Theme.codex();
    try std.testing.expectEqual(ThemeId.codex, theme.id);
    try std.testing.expect(theme.accent.eql(.{ .fg = .{ .indexed = 6 }, .bold = true }));
    try std.testing.expect(theme.muted.eql(.{ .dim = true }));
    try std.testing.expect(theme.shell_label.eql(.{ .fg = .{ .indexed = 5 }, .bold = true }));
    try std.testing.expect(theme.composer_prompt.eql(theme.accent));
    try std.testing.expect(theme.transcript_user.eql(.{ .bg = .{ .indexed = 236 } }));
    try std.testing.expect(theme.transcript_secondary.eql(theme.muted));
    try std.testing.expect(theme.status_success.eql(.{ .fg = .{ .indexed = 2 }, .bold = true }));
    try std.testing.expect(theme.status_warning.eql(.{ .fg = .{ .indexed = 3 }, .bold = true }));
    try std.testing.expect(theme.status_error.eql(.{ .fg = .{ .indexed = 1 }, .bold = true }));
}
