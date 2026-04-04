const Color = @import("cell.zig").Color;

pub const Theme = struct {
    // UI chrome
    accent: Color,
    border: Color,
    dim: Color,

    // Status
    success: Color,
    error_fg: Color,
    warning: Color,
    info: Color,

    // Messages
    user_message_fg: Color,
    user_message_bg: Color,

    // Markdown
    md_heading: Color,
    md_code_inline_fg: Color,
    md_code_inline_bg: Color,
    md_code_block: Color,
    md_code_border: Color,
    md_list_bullet: Color,
    md_quote_border: Color,
    md_quote_text: Color,
    md_hr: Color,

    // Editor
    editor_prompt: Color,
    editor_border: Color,
    editor_text: Color,

    // Tool display
    tool_pending_bg: Color,
    tool_error_bg: Color,
    tool_name: Color,

    // Thinking
    thinking_fg: Color,
    thinking_border: Color,

    pub const default_dark: Theme = .{
        .accent = Color.rgb(100, 200, 255),
        .border = Color.rgb(60, 60, 70),
        .dim = Color.rgb(100, 100, 100),

        .success = Color.rgb(100, 200, 100),
        .error_fg = Color.rgb(255, 80, 80),
        .warning = Color.rgb(255, 200, 80),
        .info = Color.rgb(100, 200, 255),

        .user_message_fg = Color.rgb(220, 220, 230),
        .user_message_bg = Color.rgb(35, 38, 48),

        .md_heading = Color.rgb(255, 255, 255),
        .md_code_inline_fg = Color.rgb(200, 175, 235),
        .md_code_inline_bg = Color.rgb(45, 40, 60),
        .md_code_block = Color.rgb(190, 190, 190),
        .md_code_border = Color.rgb(100, 100, 100),
        .md_list_bullet = Color.rgb(100, 200, 255),
        .md_quote_border = Color.rgb(100, 100, 100),
        .md_quote_text = Color.rgb(170, 170, 170),
        .md_hr = Color.rgb(80, 80, 80),

        .editor_prompt = Color.rgb(100, 100, 100),
        .editor_border = Color.rgb(60, 60, 70),
        .editor_text = Color.default,

        .tool_pending_bg = Color.rgb(40, 40, 50),
        .tool_error_bg = Color.rgb(60, 40, 40),
        .tool_name = Color.rgb(100, 200, 255),

        .thinking_fg = Color.rgb(170, 170, 170),
        .thinking_border = Color.rgb(80, 80, 90),
    };
};

test "default_dark theme has non-default accent color" {
    const t = Theme.default_dark;
    try @import("std").testing.expect(!t.accent.is_default);
}
