//! Agent-agnostic terminal UI product on vendored libvaxis. It never names
//! a session, provider, tool, or agent event; the concrete coding-agent
//! adapter lives in src/frontends/tui and talks to this package only
//! through App.Command / App.Effect.
pub const ansi = @import("ansi.zig");
pub const App = @import("App.zig");
pub const Composer = @import("Composer.zig");
pub const glyphs = @import("glyphs.zig");
pub const Greeter = @import("Greeter.zig");
pub const Picker = @import("Picker.zig");
pub const PromptHistory = @import("PromptHistory.zig");
pub const notify = @import("notify.zig");
pub const Terminal = @import("Terminal.zig");
pub const Transcript = @import("Transcript.zig");
pub const input = @import("input.zig");
pub const keybind = @import("keybind.zig");
pub const markdown = @import("markdown.zig");
pub const match = @import("match.zig");
pub const render = @import("render.zig");
pub const shimmer = @import("shimmer.zig");
pub const shuffle_text = @import("shuffle_text.zig");
pub const status = @import("status.zig");
pub const text = @import("text.zig");
pub const theme = @import("theme.zig");

pub const Command = App.Command;
pub const Effect = App.Effect;

test {
    _ = ansi;
    _ = App;
    _ = Composer;
    _ = glyphs;
    _ = Greeter;
    _ = Picker;
    _ = PromptHistory;
    _ = notify;
    _ = Terminal;
    _ = Transcript;
    _ = input;
    _ = keybind;
    _ = markdown;
    _ = match;
    _ = render;
    _ = shimmer;
    _ = shuffle_text;
    _ = status;
    _ = text;
    _ = theme;
}
