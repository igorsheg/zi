//! Small TUI glyph arsenal. Centralizing visible symbols keeps the product
//! consistent and makes future tweaks one-line changes.

/// Selected picker/list row marker.
pub const picker_selected = "› ";

/// Unselected picker/list row marker (two spaces, same width as selected).
pub const picker_unselected = "  ";

/// Separator between status-line contributions.
pub const status_separator = " · ";

/// Left border of a tool body panel.
pub const tool_body_prefix = "│ ";

/// Top decorative rail of a tool body panel.
pub const tool_top_line = "╭───";

/// Bottom decorative rail of a tool body panel.
pub const tool_bottom_line = "╰───";

/// Left border of a markdown quote block.
pub const quote_prefix = "│ ";

/// Horizontal rule rendered for markdown `---` / `***` / `___`.
pub const horizontal_rule = "────────────────" ++
    "────────────────" ++
    "────────────────" ++
    "────────────────";
