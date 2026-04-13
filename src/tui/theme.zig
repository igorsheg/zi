const std = @import("std");
const Color = @import("cell.zig").Color;
const builtins = @import("theme_builtin_data.zig");

pub const builtin_dark_json = @embedFile("themes/dark.json");
pub const builtin_light_json = @embedFile("themes/light.json");

/// Foreground color names — matches pi-mono's ThemeColor type.
/// Used with Theme.fg() to look up foreground colors.
pub const FgColor = enum {
    // Core UI (11)
    accent,
    border,
    border_accent,
    border_muted,
    success,
    @"error",
    warning,
    muted,
    dim,
    text,
    thinking_text,
    // Content text (5)
    user_message_text,
    custom_message_text,
    custom_message_label,
    tool_title,
    tool_output,
    // Markdown (10)
    md_heading,
    md_link,
    md_link_url,
    md_code,
    md_code_block,
    md_code_block_border,
    md_quote,
    md_quote_border,
    md_hr,
    md_list_bullet,
    // Tool diffs (3)
    tool_diff_added,
    tool_diff_removed,
    tool_diff_context,
    // Syntax highlighting (9)
    syntax_comment,
    syntax_keyword,
    syntax_function,
    syntax_variable,
    syntax_string,
    syntax_number,
    syntax_type,
    syntax_operator,
    syntax_punctuation,
    // Thinking levels (6)
    thinking_off,
    thinking_minimal,
    thinking_low,
    thinking_medium,
    thinking_high,
    thinking_xhigh,
    // Bash mode (1)
    bash_mode,
};

/// Background color names — mostly matches pi-mono's ThemeBg type, plus
/// zi-specific surfaces that still need to participate in theme lookup.
/// Used with Theme.bg() to look up background colors.
pub const BgColor = enum {
    selected_bg,
    user_message_bg,
    custom_message_bg,
    tool_transcript_bg,
    tool_pending_bg,
    tool_success_bg,
    tool_error_bg,
};

/// Semantic color theme matching pi-mono's Theme class.
pub const Theme = struct {
    fg_colors: [fg_count]Color,
    bg_colors: [bg_count]Color,

    pub const Background = enum {
        dark,
        light,
    };

    const fg_count = @typeInfo(FgColor).@"enum".fields.len;
    const bg_count = @typeInfo(BgColor).@"enum".fields.len;

    pub fn fg(self: *const Theme, color: FgColor) Color {
        return self.fg_colors[@intFromEnum(color)];
    }

    pub fn bg(self: *const Theme, color: BgColor) Color {
        return self.bg_colors[@intFromEnum(color)];
    }

    pub fn detectTerminalBackground() Background {
        return terminalBackgroundFromColorFgbg(std.posix.getenv("COLORFGBG") orelse "");
    }

    pub fn defaultForTerminal() *const Theme {
        return switch (detectTerminalBackground()) {
            .dark => &dark,
            .light => &light,
        };
    }

    /// Default dark theme — extracted to src/tui/themes/dark.json and embedded.
    pub const dark: Theme = .{
        .fg_colors = builtins.dark_fg,
        .bg_colors = builtins.dark_bg,
    };

    /// Default light theme — extracted to src/tui/themes/light.json and embedded.
    pub const light: Theme = .{
        .fg_colors = builtins.light_fg,
        .bg_colors = builtins.light_bg,
    };
};

fn terminalBackgroundFromColorFgbg(colorfgbg: []const u8) Theme.Background {
    var parts = std.mem.splitScalar(u8, colorfgbg, ';');
    _ = parts.next();
    const bg_part = parts.next() orelse return .dark;
    const bg = std.fmt.parseInt(u8, bg_part, 10) catch return .dark;
    return if (bg < 8) .dark else .light;
}

fn expectColorEq(expected: Color, actual: Color) !void {
    try std.testing.expectEqual(expected.is_default, actual.is_default);
    if (!expected.is_default) {
        try std.testing.expectEqual(expected.r, actual.r);
        try std.testing.expectEqual(expected.g, actual.g);
        try std.testing.expectEqual(expected.b, actual.b);
    }
}

// ── Tests ──────────────────────────────────────────────────────────

test "dark theme matches kanso zen defaults" {
    const theme = Theme.dark;
    try expectColorEq(Color.rgb(0x8B, 0xA4, 0xB0), theme.fg(.accent));
    try expectColorEq(Color.rgb(0xC5, 0xC9, 0xC7), theme.fg(.text));
    try expectColorEq(Color.rgb(0x09, 0x0E, 0x13), theme.bg(.tool_pending_bg));
    try expectColorEq(Color.rgb(0x39, 0x3B, 0x44), theme.bg(.selected_bg));
}

test "light theme matches kanso pearl defaults" {
    const theme = Theme.light;
    try expectColorEq(Color.rgb(0x4D, 0x69, 0x9B), theme.fg(.accent));
    try expectColorEq(Color.rgb(0x22, 0x26, 0x2D), theme.fg(.text));
    try expectColorEq(Color.rgb(0xF2, 0xF1, 0xEF), theme.bg(.tool_pending_bg));
    try expectColorEq(Color.rgb(0xDD, 0xDD, 0xDB), theme.bg(.selected_bg));
}

test "terminal background detection mirrors pi-mono COLORFGBG heuristic" {
    try std.testing.expectEqual(Theme.Background.dark, terminalBackgroundFromColorFgbg("15;0"));
    try std.testing.expectEqual(Theme.Background.light, terminalBackgroundFromColorFgbg("0;15"));
    try std.testing.expectEqual(Theme.Background.dark, terminalBackgroundFromColorFgbg("broken"));
    try std.testing.expectEqual(Theme.Background.dark, terminalBackgroundFromColorFgbg(""));
}
