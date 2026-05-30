pub const action = @import("action.zig");
pub const app = @import("app.zig");
pub const buffer = @import("buffer.zig");
pub const command = @import("command.zig");
pub const composer = @import("composer.zig");
pub const event = @import("event.zig");
pub const slot = @import("slot.zig");
pub const surface = @import("surface.zig");
pub const testing = @import("testing.zig");
pub const terminal = @import("terminal.zig");
pub const transcript = @import("transcript.zig");
pub const view = @import("view.zig");

test {
    _ = app;
    _ = action;
    _ = buffer;
    _ = command;
    _ = composer;
    _ = event;
    _ = slot;
    _ = surface;
    _ = testing;
    _ = terminal;
    _ = transcript;
    _ = view;
}
