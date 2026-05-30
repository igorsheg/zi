const action_mod = @import("primitive/action.zig");
const app_mod = @import("bridge/app.zig");
const buffer_mod = @import("primitive/buffer.zig");
const command_mod = @import("primitive/command.zig");
const composer_mod = @import("component/composer.zig");
const event_mod = @import("primitive/event.zig");
const shell_mod = @import("composition/shell.zig");
const slot_mod = @import("primitive/slot.zig");
const surface_mod = @import("primitive/surface.zig");
const terminal_mod = @import("substrate/terminal.zig");
const testing_mod = @import("substrate/testing.zig");
const transcript_mod = @import("primitive/transcript.zig");
const transcript_renderer_mod = @import("component/transcript_renderer.zig");
const view_mod = @import("primitive/view.zig");
const vscreen_mod = @import("substrate/vscreen.zig");

pub const bridge = struct {
    pub const app = app_mod;
};

pub const component = struct {
    pub const composer = composer_mod;
    pub const transcript_renderer = transcript_renderer_mod;
};

pub const composition = struct {
    pub const shell = shell_mod;
};

pub const primitive = struct {
    pub const action = action_mod;
    pub const buffer = buffer_mod;
    pub const command = command_mod;
    pub const event = event_mod;
    pub const slot = slot_mod;
    pub const surface = surface_mod;
    pub const transcript = transcript_mod;
    pub const view = view_mod;
};

pub const substrate = struct {
    pub const terminal = terminal_mod;
    pub const testing = testing_mod;
    pub const vscreen = vscreen_mod;
};

pub const action = primitive.action;
pub const app = bridge.app;
pub const buffer = primitive.buffer;
pub const command = primitive.command;
pub const composer = component.composer;
pub const event = primitive.event;
pub const shell = composition.shell;
pub const slot = primitive.slot;
pub const surface = primitive.surface;
pub const testing = substrate.testing;
pub const terminal = substrate.terminal;
pub const transcript = primitive.transcript;
pub const transcript_renderer = component.transcript_renderer;
pub const view = primitive.view;
pub const vscreen = substrate.vscreen;

test {
    _ = app;
    _ = action;
    _ = buffer;
    _ = command;
    _ = composer;
    _ = event;
    _ = shell;
    _ = slot;
    _ = surface;
    _ = testing;
    _ = terminal;
    _ = transcript;
    _ = transcript_renderer;
    _ = view;
    _ = vscreen;
}
