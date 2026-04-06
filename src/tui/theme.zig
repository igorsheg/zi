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

    /// zi default dark theme — kanso-muted inspired.
    ///
    /// key design choices vs pi-mono's dark.json:
    /// - toolSuccessBg is empty (no bg tint on completed tools)
    /// - softer warning yellow (#E6C384 vs #FFFF00)
    /// - tiered gray scale for dim/muted/output hierarchy
    /// - bashMode uses yellow (command stands out from output)
    /// - borders use dim gray (subtle) not blue (loud)
    pub const dark: Theme = blk: {
        // Tiered gray scale (kanso-muted: tier1=brightest, tier7=dimmest)
        const tier1 = Color.rgb(0xBE, 0xC2, 0xC0);
        const tier2 = Color.rgb(0xB2, 0xB6, 0xB4);
        const tier3 = Color.rgb(0xA5, 0xA9, 0xA7);
        const tier4 = Color.rgb(0x9B, 0x96, 0x90);
        const tier5 = Color.rgb(0x7F, 0x83, 0x81);
        const tier6 = Color.rgb(0x6A, 0x6E, 0x6C);
        const tier7 = Color.rgb(0x53, 0x57, 0x55);
        const scaffold = Color.rgb(0x62, 0x66, 0x64);

        // Semantic colors
        const teal = Color.rgb(0x7A, 0xA8, 0x9F);
        const blue = Color.rgb(0x7F, 0xB4, 0xCA);
        const green = Color.rgb(0x87, 0xA9, 0x87);
        const red = Color.rgb(0xE4, 0x68, 0x76);
        const yellow = Color.rgb(0xE6, 0xC3, 0x84);
        const purple = Color.rgb(0x93, 0x8A, 0xA9);

        // Background tones
        const panel_bg = Color.rgb(0x0D, 0x12, 0x18);
        const panel_bg_red = Color.rgb(0x1A, 0x0F, 0x12);
        const selection = Color.rgb(0x39, 0x3B, 0x44);

        var t: Theme = undefined;

        // Core UI
        t.fg_colors[@intFromEnum(FgColor.accent)] = teal;
        t.fg_colors[@intFromEnum(FgColor.border)] = tier6;
        t.fg_colors[@intFromEnum(FgColor.border_accent)] = blue;
        t.fg_colors[@intFromEnum(FgColor.border_muted)] = tier7;
        t.fg_colors[@intFromEnum(FgColor.success)] = green;
        t.fg_colors[@intFromEnum(FgColor.@"error")] = red;
        t.fg_colors[@intFromEnum(FgColor.warning)] = yellow;
        t.fg_colors[@intFromEnum(FgColor.muted)] = tier5;
        t.fg_colors[@intFromEnum(FgColor.dim)] = tier6;
        t.fg_colors[@intFromEnum(FgColor.text)] = Color.default;
        t.fg_colors[@intFromEnum(FgColor.thinking_text)] = tier5;

        // Content text
        t.fg_colors[@intFromEnum(FgColor.user_message_text)] = Color.default;
        t.fg_colors[@intFromEnum(FgColor.custom_message_text)] = Color.default;
        t.fg_colors[@intFromEnum(FgColor.custom_message_label)] = purple;
        t.fg_colors[@intFromEnum(FgColor.tool_title)] = Color.default;
        t.fg_colors[@intFromEnum(FgColor.tool_output)] = tier5;

        // Markdown
        t.fg_colors[@intFromEnum(FgColor.md_heading)] = yellow;
        t.fg_colors[@intFromEnum(FgColor.md_link)] = blue;
        t.fg_colors[@intFromEnum(FgColor.md_link_url)] = tier6;
        t.fg_colors[@intFromEnum(FgColor.md_code)] = teal;
        t.fg_colors[@intFromEnum(FgColor.md_code_block)] = tier3;
        t.fg_colors[@intFromEnum(FgColor.md_code_block_border)] = tier7;
        t.fg_colors[@intFromEnum(FgColor.md_quote)] = tier5;
        t.fg_colors[@intFromEnum(FgColor.md_quote_border)] = tier7;
        t.fg_colors[@intFromEnum(FgColor.md_hr)] = tier7;
        t.fg_colors[@intFromEnum(FgColor.md_list_bullet)] = teal;

        // Tool diffs
        t.fg_colors[@intFromEnum(FgColor.tool_diff_added)] = Color.rgb(0x98, 0xBB, 0x6C);
        t.fg_colors[@intFromEnum(FgColor.tool_diff_removed)] = red;
        t.fg_colors[@intFromEnum(FgColor.tool_diff_context)] = tier7;

        // Syntax highlighting (tiered grays — no rainbow, just hierarchy)
        t.fg_colors[@intFromEnum(FgColor.syntax_comment)] = tier7;
        t.fg_colors[@intFromEnum(FgColor.syntax_keyword)] = tier1;
        t.fg_colors[@intFromEnum(FgColor.syntax_function)] = tier2;
        t.fg_colors[@intFromEnum(FgColor.syntax_variable)] = tier3;
        t.fg_colors[@intFromEnum(FgColor.syntax_string)] = tier4;
        t.fg_colors[@intFromEnum(FgColor.syntax_number)] = tier4;
        t.fg_colors[@intFromEnum(FgColor.syntax_type)] = tier5;
        t.fg_colors[@intFromEnum(FgColor.syntax_operator)] = tier6;
        t.fg_colors[@intFromEnum(FgColor.syntax_punctuation)] = scaffold;

        // Thinking levels
        t.fg_colors[@intFromEnum(FgColor.thinking_off)] = tier7;
        t.fg_colors[@intFromEnum(FgColor.thinking_minimal)] = tier6;
        t.fg_colors[@intFromEnum(FgColor.thinking_low)] = tier5;
        t.fg_colors[@intFromEnum(FgColor.thinking_medium)] = teal;
        t.fg_colors[@intFromEnum(FgColor.thinking_high)] = purple;
        t.fg_colors[@intFromEnum(FgColor.thinking_xhigh)] = blue;

        // Bash mode
        t.fg_colors[@intFromEnum(FgColor.bash_mode)] = yellow;

        // Backgrounds
        t.bg_colors[@intFromEnum(BgColor.selected_bg)] = selection;
        t.bg_colors[@intFromEnum(BgColor.user_message_bg)] = panel_bg; // kanso-muted: #0D1218
        t.bg_colors[@intFromEnum(BgColor.custom_message_bg)] = Color.rgb(0x11, 0x18, 0x20);
        t.bg_colors[@intFromEnum(BgColor.tool_pending_bg)] = panel_bg;
        t.bg_colors[@intFromEnum(BgColor.tool_success_bg)] = Color.default; // no bg on success
        t.bg_colors[@intFromEnum(BgColor.tool_error_bg)] = panel_bg_red;

        break :blk t;
    };
};

// ── Tests ──────────────────────────────────────────────────────────

test "dark theme has correct accent color" {
    const t = Theme.dark;
    // accent = teal #7AA89F
    const accent = t.fg(.accent);
    try @import("std").testing.expectEqual(@as(u8, 0x7A), accent.r);
    try @import("std").testing.expectEqual(@as(u8, 0xA8), accent.g);
    try @import("std").testing.expectEqual(@as(u8, 0x9F), accent.b);
}

test "dark theme fg and bg lookups" {
    const t = Theme.dark;
    // mdHeading = yellow #E6C384
    const heading = t.fg(.md_heading);
    try @import("std").testing.expectEqual(@as(u8, 0xE6), heading.r);
    // userMessageBg = panelBg #0D1218 (kanso-muted)
    const user_bg = t.bg(.user_message_bg);
    try @import("std").testing.expectEqual(@as(u8, 0x0D), user_bg.r);
    // toolSuccessBg = default (no bg)
    try @import("std").testing.expect(t.bg(.tool_success_bg).is_default);
    // text = "" → Color.default
    try @import("std").testing.expect(t.fg(.text).is_default);
}
