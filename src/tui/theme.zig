const std = @import("std");
const Color = @import("cell.zig").Color;

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
    pending_user_message_bg,
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

    /// Default dark theme — exact Kanso zen palette/mappings.
    pub const dark: Theme = buildZen();

    /// Default light theme — exact Kanso pearl palette/mappings.
    pub const light: Theme = buildPearl();
};

fn terminalBackgroundFromColorFgbg(colorfgbg: []const u8) Theme.Background {
    var parts = std.mem.splitScalar(u8, colorfgbg, ';');
    _ = parts.next();
    const bg_part = parts.next() orelse return .dark;
    const bg = std.fmt.parseInt(u8, bg_part, 10) catch return .dark;
    return if (bg < 8) .dark else .light;
}

fn setFg(theme: *Theme, color: FgColor, value: Color) void {
    theme.fg_colors[@intFromEnum(color)] = value;
}

fn setBg(theme: *Theme, color: BgColor, value: Color) void {
    theme.bg_colors[@intFromEnum(color)] = value;
}

fn buildZen() Theme {
    const ui_fg = Color.rgb(0xC5, 0xC9, 0xC7);
    const ui_fg_dim = Color.rgb(0x75, 0x79, 0x7F);
    const ui_nontext = Color.rgb(0x5C, 0x60, 0x66);
    const ui_comment = Color.rgb(0x75, 0x79, 0x7F);
    const ui_bg = Color.rgb(0x09, 0x0E, 0x13);
    const ui_bg_p1 = Color.rgb(0x1C, 0x1E, 0x25);
    const ui_bg_p2 = Color.rgb(0x22, 0x26, 0x2D);
    const ui_bg_sel = Color.rgb(0x39, 0x3B, 0x44);
    const ui_bg_search = Color.rgb(0x2D, 0x4F, 0x67);

    const syn_string = Color.rgb(0x8A, 0x9A, 0x7B);
    const syn_number = Color.rgb(0xA2, 0x92, 0xA3);
    const syn_identifier = Color.rgb(0x89, 0x92, 0xA7);
    const syn_parameter = Color.rgb(0x90, 0x93, 0x98);
    const syn_fun = Color.rgb(0x8B, 0xA4, 0xB0);
    const syn_keyword = Color.rgb(0x89, 0x92, 0xA7);
    const syn_type = Color.rgb(0x8E, 0xA4, 0xA2);
    const syn_operator = Color.rgb(0x90, 0x93, 0x98);
    const syn_punct = Color.rgb(0x90, 0x93, 0x98);
    const syn_special1 = Color.rgb(0xC4, 0xB2, 0x8A);

    const diag_error = Color.rgb(0xC3, 0x40, 0x43);
    const diag_ok = Color.rgb(0x98, 0xBB, 0x6C);
    const diag_warning = Color.rgb(0xDC, 0xA5, 0x61);
    const diag_info = Color.rgb(0x65, 0x85, 0x94);

    const vcs_added = Color.rgb(0x76, 0x94, 0x6A);
    const vcs_removed = Color.rgb(0xC3, 0x40, 0x43);

    const diff_add = Color.rgb(0x2B, 0x33, 0x28);
    const diff_delete = Color.rgb(0x43, 0x24, 0x2B);

    var theme: Theme = undefined;

    setFg(&theme, .accent, syn_fun);
    setFg(&theme, .border, ui_bg_p2);
    setFg(&theme, .border_accent, ui_bg_search);
    setFg(&theme, .border_muted, ui_nontext);
    setFg(&theme, .success, diag_ok);
    setFg(&theme, .@"error", diag_error);
    setFg(&theme, .warning, diag_warning);
    setFg(&theme, .muted, ui_fg_dim);
    setFg(&theme, .dim, ui_nontext);
    setFg(&theme, .text, ui_fg);
    setFg(&theme, .thinking_text, ui_comment);

    setFg(&theme, .user_message_text, ui_fg);
    setFg(&theme, .custom_message_text, ui_fg);
    setFg(&theme, .custom_message_label, syn_keyword);
    setFg(&theme, .tool_title, ui_fg);
    setFg(&theme, .tool_output, ui_fg_dim);

    setFg(&theme, .md_heading, syn_fun);
    setFg(&theme, .md_link, ui_fg);
    setFg(&theme, .md_link_url, syn_special1);
    setFg(&theme, .md_code, syn_string);
    setFg(&theme, .md_code_block, ui_fg);
    setFg(&theme, .md_code_block_border, ui_bg_p2);
    setFg(&theme, .md_quote, syn_parameter);
    setFg(&theme, .md_quote_border, ui_bg_p1);
    setFg(&theme, .md_hr, ui_nontext);
    setFg(&theme, .md_list_bullet, syn_special1);

    setFg(&theme, .tool_diff_added, vcs_added);
    setFg(&theme, .tool_diff_removed, vcs_removed);
    setFg(&theme, .tool_diff_context, ui_comment);

    setFg(&theme, .syntax_comment, ui_comment);
    setFg(&theme, .syntax_keyword, syn_keyword);
    setFg(&theme, .syntax_function, syn_fun);
    setFg(&theme, .syntax_variable, syn_identifier);
    setFg(&theme, .syntax_string, syn_string);
    setFg(&theme, .syntax_number, syn_number);
    setFg(&theme, .syntax_type, syn_type);
    setFg(&theme, .syntax_operator, syn_operator);
    setFg(&theme, .syntax_punctuation, syn_punct);

    setFg(&theme, .thinking_off, ui_nontext);
    setFg(&theme, .thinking_minimal, ui_comment);
    setFg(&theme, .thinking_low, diag_info);
    setFg(&theme, .thinking_medium, syn_fun);
    setFg(&theme, .thinking_high, syn_keyword);
    setFg(&theme, .thinking_xhigh, syn_number);

    setFg(&theme, .bash_mode, diag_warning);

    setBg(&theme, .selected_bg, ui_bg_sel);
    setBg(&theme, .user_message_bg, ui_bg_p1);
    setBg(&theme, .pending_user_message_bg, ui_bg);
    setBg(&theme, .custom_message_bg, ui_bg_p1);
    setBg(&theme, .tool_transcript_bg, ui_bg);
    setBg(&theme, .tool_pending_bg, ui_bg);
    setBg(&theme, .tool_success_bg, diff_add);
    setBg(&theme, .tool_error_bg, diff_delete);

    return theme;
}

fn buildPearl() Theme {
    const ui_fg = Color.rgb(0x22, 0x26, 0x2D);
    const ui_fg_dim = Color.rgb(0x54, 0x54, 0x64);
    const ui_nontext = Color.rgb(0xA0, 0x9C, 0xAC);
    const ui_comment = Color.rgb(0x6D, 0x6D, 0x69);
    const ui_bg = Color.rgb(0xF2, 0xF1, 0xEF);
    const ui_bg_p1 = Color.rgb(0xE2, 0xE1, 0xDF);
    const ui_bg_p2 = Color.rgb(0xDD, 0xDD, 0xDB);
    const ui_bg_search = Color.rgb(0xB5, 0xCB, 0xD2);

    const syn_string = Color.rgb(0x6F, 0x89, 0x4E);
    const syn_number = Color.rgb(0xB3, 0x5B, 0x79);
    const syn_identifier = Color.rgb(0x62, 0x4C, 0x83);
    const syn_parameter = Color.rgb(0x5D, 0x57, 0xA3);
    const syn_fun = Color.rgb(0x4D, 0x69, 0x9B);
    const syn_keyword = Color.rgb(0x62, 0x4C, 0x83);
    const syn_type = Color.rgb(0x59, 0x7B, 0x75);
    const syn_operator = Color.rgb(0x6D, 0x6D, 0x69);
    const syn_punct = Color.rgb(0x6D, 0x6D, 0x69);
    const syn_special1 = Color.rgb(0x83, 0x6F, 0x4A);

    const diag_error = Color.rgb(0xE8, 0x24, 0x24);
    const diag_ok = Color.rgb(0x6F, 0x89, 0x4E);
    const diag_warning = Color.rgb(0xE9, 0x8A, 0x00);
    const diag_info = Color.rgb(0x5A, 0x77, 0x85);

    const vcs_added = Color.rgb(0x6E, 0x91, 0x5F);
    const vcs_removed = Color.rgb(0xD7, 0x47, 0x4B);

    const diff_add = Color.rgb(0xB7, 0xD0, 0xAE);
    const diff_delete = Color.rgb(0xD9, 0xA5, 0x94);

    var theme: Theme = undefined;

    setFg(&theme, .accent, syn_fun);
    setFg(&theme, .border, ui_bg_p2);
    setFg(&theme, .border_accent, ui_bg_search);
    setFg(&theme, .border_muted, ui_bg_p1);
    setFg(&theme, .success, diag_ok);
    setFg(&theme, .@"error", diag_error);
    setFg(&theme, .warning, diag_warning);
    setFg(&theme, .muted, ui_fg_dim);
    setFg(&theme, .dim, ui_nontext);
    setFg(&theme, .text, ui_fg);
    setFg(&theme, .thinking_text, ui_comment);

    setFg(&theme, .user_message_text, ui_fg);
    setFg(&theme, .custom_message_text, ui_fg);
    setFg(&theme, .custom_message_label, syn_keyword);
    setFg(&theme, .tool_title, ui_fg);
    setFg(&theme, .tool_output, ui_fg_dim);

    setFg(&theme, .md_heading, syn_fun);
    setFg(&theme, .md_link, ui_fg);
    setFg(&theme, .md_link_url, syn_special1);
    setFg(&theme, .md_code, syn_string);
    setFg(&theme, .md_code_block, ui_fg);
    setFg(&theme, .md_code_block_border, ui_bg_p2);
    setFg(&theme, .md_quote, syn_parameter);
    setFg(&theme, .md_quote_border, ui_bg_p1);
    setFg(&theme, .md_hr, ui_nontext);
    setFg(&theme, .md_list_bullet, syn_special1);

    setFg(&theme, .tool_diff_added, vcs_added);
    setFg(&theme, .tool_diff_removed, vcs_removed);
    setFg(&theme, .tool_diff_context, ui_comment);

    setFg(&theme, .syntax_comment, ui_comment);
    setFg(&theme, .syntax_keyword, syn_keyword);
    setFg(&theme, .syntax_function, syn_fun);
    setFg(&theme, .syntax_variable, syn_identifier);
    setFg(&theme, .syntax_string, syn_string);
    setFg(&theme, .syntax_number, syn_number);
    setFg(&theme, .syntax_type, syn_type);
    setFg(&theme, .syntax_operator, syn_operator);
    setFg(&theme, .syntax_punctuation, syn_punct);

    setFg(&theme, .thinking_off, ui_nontext);
    setFg(&theme, .thinking_minimal, ui_comment);
    setFg(&theme, .thinking_low, diag_info);
    setFg(&theme, .thinking_medium, syn_fun);
    setFg(&theme, .thinking_high, syn_keyword);
    setFg(&theme, .thinking_xhigh, syn_number);

    setFg(&theme, .bash_mode, diag_warning);

    setBg(&theme, .selected_bg, ui_bg_p2);
    setBg(&theme, .user_message_bg, ui_bg_p1);
    setBg(&theme, .pending_user_message_bg, Color.rgb(0xD0, 0xCE, 0xCC));
    setBg(&theme, .custom_message_bg, ui_bg_p1);
    setBg(&theme, .tool_transcript_bg, ui_bg);
    setBg(&theme, .tool_pending_bg, ui_bg);
    setBg(&theme, .tool_success_bg, diff_add);
    setBg(&theme, .tool_error_bg, diff_delete);

    return theme;
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
    try expectColorEq(Color.rgb(0x09, 0x0E, 0x13), theme.bg(.pending_user_message_bg));
}

test "light theme matches kanso pearl defaults" {
    const theme = Theme.light;
    try expectColorEq(Color.rgb(0x4D, 0x69, 0x9B), theme.fg(.accent));
    try expectColorEq(Color.rgb(0x22, 0x26, 0x2D), theme.fg(.text));
    try expectColorEq(Color.rgb(0xF2, 0xF1, 0xEF), theme.bg(.tool_pending_bg));
    try expectColorEq(Color.rgb(0xDD, 0xDD, 0xDB), theme.bg(.selected_bg));
    try expectColorEq(Color.rgb(0xD0, 0xCE, 0xCC), theme.bg(.pending_user_message_bg));
}

test "terminal background detection mirrors pi-mono COLORFGBG heuristic" {
    try std.testing.expectEqual(Theme.Background.dark, terminalBackgroundFromColorFgbg("15;0"));
    try std.testing.expectEqual(Theme.Background.light, terminalBackgroundFromColorFgbg("0;15"));
    try std.testing.expectEqual(Theme.Background.dark, terminalBackgroundFromColorFgbg("broken"));
    try std.testing.expectEqual(Theme.Background.dark, terminalBackgroundFromColorFgbg(""));
}
