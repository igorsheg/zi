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

/// Background color names — matches pi-mono's ThemeBg type.
/// Used with Theme.bg() to look up background colors.
pub const BgColor = enum {
    selected_bg,
    user_message_bg,
    custom_message_bg,
    tool_pending_bg,
    tool_success_bg,
    tool_error_bg,
};

/// Semantic color theme matching pi-mono's Theme class.
///
/// pi-mono separates foreground colors (ThemeColor, 45 names) from background
/// colors (ThemeBg, 6 names). Colors are defined in JSON with variable
/// references; zi stores resolved Color values directly.
///
/// Default values come from pi-mono's dark.json with vars resolved to hex→RGB.
pub const Theme = struct {
    fg_colors: [fg_count]Color,
    bg_colors: [bg_count]Color,

    const fg_count = @typeInfo(FgColor).@"enum".fields.len;
    const bg_count = @typeInfo(BgColor).@"enum".fields.len;

    pub fn fg(self: *const Theme, color: FgColor) Color {
        return self.fg_colors[@intFromEnum(color)];
    }

    pub fn bg(self: *const Theme, color: BgColor) Color {
        return self.bg_colors[@intFromEnum(color)];
    }

    /// dark.json with all variable references resolved to RGB.
    pub const dark: Theme = blk: {
        // Vars from dark.json
        const cyan = Color.rgb(0x00, 0xd7, 0xff);
        const blue = Color.rgb(0x5f, 0x87, 0xff);
        const green = Color.rgb(0xb5, 0xbd, 0x68);
        const red = Color.rgb(0xcc, 0x66, 0x66);
        const yellow = Color.rgb(0xff, 0xff, 0x00);
        const gray = Color.rgb(0x80, 0x80, 0x80);
        const dim_gray = Color.rgb(0x66, 0x66, 0x66);
        const dark_gray = Color.rgb(0x50, 0x50, 0x50);
        const accent = Color.rgb(0x8a, 0xbe, 0xb7);

        var t: Theme = undefined;

        // Core UI
        t.fg_colors[@intFromEnum(FgColor.accent)] = accent;
        t.fg_colors[@intFromEnum(FgColor.border)] = blue;
        t.fg_colors[@intFromEnum(FgColor.border_accent)] = cyan;
        t.fg_colors[@intFromEnum(FgColor.border_muted)] = dark_gray;
        t.fg_colors[@intFromEnum(FgColor.success)] = green;
        t.fg_colors[@intFromEnum(FgColor.@"error")] = red;
        t.fg_colors[@intFromEnum(FgColor.warning)] = yellow;
        t.fg_colors[@intFromEnum(FgColor.muted)] = gray;
        t.fg_colors[@intFromEnum(FgColor.dim)] = dim_gray;
        t.fg_colors[@intFromEnum(FgColor.text)] = Color.default; // "" in dark.json
        t.fg_colors[@intFromEnum(FgColor.thinking_text)] = gray;

        // Content text
        t.fg_colors[@intFromEnum(FgColor.user_message_text)] = Color.default; // ""
        t.fg_colors[@intFromEnum(FgColor.custom_message_text)] = Color.default; // ""
        t.fg_colors[@intFromEnum(FgColor.custom_message_label)] = Color.rgb(0x95, 0x75, 0xcd);
        t.fg_colors[@intFromEnum(FgColor.tool_title)] = Color.default; // ""
        t.fg_colors[@intFromEnum(FgColor.tool_output)] = gray;

        // Markdown
        t.fg_colors[@intFromEnum(FgColor.md_heading)] = Color.rgb(0xf0, 0xc6, 0x74);
        t.fg_colors[@intFromEnum(FgColor.md_link)] = Color.rgb(0x81, 0xa2, 0xbe);
        t.fg_colors[@intFromEnum(FgColor.md_link_url)] = dim_gray;
        t.fg_colors[@intFromEnum(FgColor.md_code)] = accent;
        t.fg_colors[@intFromEnum(FgColor.md_code_block)] = green;
        t.fg_colors[@intFromEnum(FgColor.md_code_block_border)] = gray;
        t.fg_colors[@intFromEnum(FgColor.md_quote)] = gray;
        t.fg_colors[@intFromEnum(FgColor.md_quote_border)] = gray;
        t.fg_colors[@intFromEnum(FgColor.md_hr)] = gray;
        t.fg_colors[@intFromEnum(FgColor.md_list_bullet)] = accent;

        // Tool diffs
        t.fg_colors[@intFromEnum(FgColor.tool_diff_added)] = green;
        t.fg_colors[@intFromEnum(FgColor.tool_diff_removed)] = red;
        t.fg_colors[@intFromEnum(FgColor.tool_diff_context)] = gray;

        // Syntax highlighting
        t.fg_colors[@intFromEnum(FgColor.syntax_comment)] = Color.rgb(0x6A, 0x99, 0x55);
        t.fg_colors[@intFromEnum(FgColor.syntax_keyword)] = Color.rgb(0x56, 0x9C, 0xD6);
        t.fg_colors[@intFromEnum(FgColor.syntax_function)] = Color.rgb(0xDC, 0xDC, 0xAA);
        t.fg_colors[@intFromEnum(FgColor.syntax_variable)] = Color.rgb(0x9C, 0xDC, 0xFE);
        t.fg_colors[@intFromEnum(FgColor.syntax_string)] = Color.rgb(0xCE, 0x91, 0x78);
        t.fg_colors[@intFromEnum(FgColor.syntax_number)] = Color.rgb(0xB5, 0xCE, 0xA8);
        t.fg_colors[@intFromEnum(FgColor.syntax_type)] = Color.rgb(0x4E, 0xC9, 0xB0);
        t.fg_colors[@intFromEnum(FgColor.syntax_operator)] = Color.rgb(0xD4, 0xD4, 0xD4);
        t.fg_colors[@intFromEnum(FgColor.syntax_punctuation)] = Color.rgb(0xD4, 0xD4, 0xD4);

        // Thinking levels
        t.fg_colors[@intFromEnum(FgColor.thinking_off)] = dark_gray;
        t.fg_colors[@intFromEnum(FgColor.thinking_minimal)] = Color.rgb(0x6e, 0x6e, 0x6e);
        t.fg_colors[@intFromEnum(FgColor.thinking_low)] = Color.rgb(0x5f, 0x87, 0xaf);
        t.fg_colors[@intFromEnum(FgColor.thinking_medium)] = Color.rgb(0x81, 0xa2, 0xbe);
        t.fg_colors[@intFromEnum(FgColor.thinking_high)] = Color.rgb(0xb2, 0x94, 0xbb);
        t.fg_colors[@intFromEnum(FgColor.thinking_xhigh)] = Color.rgb(0xd1, 0x83, 0xe8);

        // Bash mode
        t.fg_colors[@intFromEnum(FgColor.bash_mode)] = green;

        // Backgrounds
        t.bg_colors[@intFromEnum(BgColor.selected_bg)] = Color.rgb(0x3a, 0x3a, 0x4a);
        t.bg_colors[@intFromEnum(BgColor.user_message_bg)] = Color.rgb(0x34, 0x35, 0x41);
        t.bg_colors[@intFromEnum(BgColor.custom_message_bg)] = Color.rgb(0x2d, 0x28, 0x38);
        t.bg_colors[@intFromEnum(BgColor.tool_pending_bg)] = Color.rgb(0x28, 0x28, 0x32);
        t.bg_colors[@intFromEnum(BgColor.tool_success_bg)] = Color.rgb(0x28, 0x32, 0x28);
        t.bg_colors[@intFromEnum(BgColor.tool_error_bg)] = Color.rgb(0x3c, 0x28, 0x28);

        break :blk t;
    };
};

// ── Tests ──────────────────────────────────────────────────────────

test "dark theme has correct accent color from dark.json" {
    const t = Theme.dark;
    // accent var = #8abeb7
    const accent = t.fg(.accent);
    try @import("std").testing.expectEqual(@as(u8, 0x8a), accent.r);
    try @import("std").testing.expectEqual(@as(u8, 0xbe), accent.g);
    try @import("std").testing.expectEqual(@as(u8, 0xb7), accent.b);
}

test "dark theme fg and bg lookups match dark.json" {
    const t = Theme.dark;
    // mdHeading = #f0c674
    const heading = t.fg(.md_heading);
    try @import("std").testing.expectEqual(@as(u8, 0xf0), heading.r);
    // userMessageBg = #343541
    const user_bg = t.bg(.user_message_bg);
    try @import("std").testing.expectEqual(@as(u8, 0x34), user_bg.r);
    try @import("std").testing.expectEqual(@as(u8, 0x35), user_bg.g);
    try @import("std").testing.expectEqual(@as(u8, 0x41), user_bg.b);
    // text = "" → Color.default
    try @import("std").testing.expect(t.fg(.text).is_default);
}
