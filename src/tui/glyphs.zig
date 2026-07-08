//! Small TUI glyph vocabulary. Visual policy imports these symbols instead of
//! scattering Unicode constants through layout and chrome code.

pub const picker_selected = "› ";
pub const picker_unselected = "  ";
pub const tool_body_prefix = "│ ";
pub const tool_top_line = "╭───";
pub const tool_bottom_line = "╰───";

pub const composer_top_left = "╭";
pub const composer_top_right = "╮";
pub const composer_bottom_left = "╰";
pub const composer_bottom_right = "╯";
pub const composer_horizontal = "─";
pub const composer_vertical = "│";
