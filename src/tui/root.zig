//! Agent-agnostic terminal UI product on vendored libvaxis. It never names
//! a session, provider, tool, or agent event; the concrete coding-agent
//! adapter lives in src/frontends/tui and talks to this package only
//! through App.Command / App.Effect.
pub const App = @import("App.zig");
pub const Composer = @import("Composer.zig");
pub const Picker = @import("Picker.zig");
pub const PromptHistory = @import("PromptHistory.zig");
pub const Terminal = @import("Terminal.zig");
pub const Transcript = @import("Transcript.zig");
pub const input = @import("input.zig");
pub const markdown = @import("markdown.zig");
pub const match = @import("match.zig");
pub const render = @import("render.zig");
pub const shimmer = @import("shimmer.zig");
pub const status = @import("status.zig");
pub const text = @import("text.zig");
pub const theme = @import("theme.zig");

pub const Command = App.Command;
pub const Effect = App.Effect;

test {
    _ = App;
    _ = Composer;
    _ = Picker;
    _ = PromptHistory;
    _ = Terminal;
    _ = Transcript;
    _ = input;
    _ = markdown;
    _ = match;
    _ = render;
    _ = shimmer;
    _ = status;
    _ = text;
    _ = theme;
}
