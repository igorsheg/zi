const action_mod = @import("primitive/action.zig");
const app_mod = @import("bridge/app.zig");
const buffer_mod = @import("primitive/buffer.zig");
const command_mod = @import("primitive/command.zig");
const composer_mod = @import("product/composer.zig");
const event_mod = @import("primitive/event.zig");
const focus_mod = @import("primitive/focus.zig");
const frame_mod = @import("primitive/frame.zig");
const input_router_mod = @import("primitive/input_router.zig");
const shell_mod = @import("composition/shell.zig");
const slot_mod = @import("primitive/slot.zig");
const surface_mod = @import("primitive/surface.zig");
const terminal_mod = @import("substrate/terminal.zig");
const testing_mod = @import("substrate/testing.zig");
const transcript_mod = @import("primitive/transcript.zig");
const transcript_renderer_mod = @import("product/transcript_renderer.zig");
const view_mod = @import("primitive/view.zig");
const vscreen_mod = @import("substrate/vscreen.zig");

pub const app = app_mod;
pub const frame = frame_mod;
pub const input_router = input_router_mod;
pub const terminal = terminal_mod;

test {
    _ = app;
    _ = action_mod;
    _ = buffer_mod;
    _ = command_mod;
    _ = composer_mod;
    _ = event_mod;
    _ = focus_mod;
    _ = frame;
    _ = input_router;
    _ = shell_mod;
    _ = slot_mod;
    _ = surface_mod;
    _ = testing_mod;
    _ = terminal;
    _ = transcript_mod;
    _ = transcript_renderer_mod;
    _ = view_mod;
    _ = vscreen_mod;
}
