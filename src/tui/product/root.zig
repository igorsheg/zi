pub const app = @import("App.zig");
pub const composer = @import("composer.zig");
pub const frame = @import("frame.zig");
pub const keys = @import("keys.zig");
pub const slots = @import("slots.zig");
pub const snapshot = @import("snapshot.zig");
pub const surface = @import("surface.zig");
pub const transcript = @import("transcript.zig");
pub const transcript_preview = @import("transcript_preview.zig");
pub const transcript_projection = @import("transcript_projection.zig");
pub const loop = @import("loop.zig");
pub const terminal_loop = @import("terminal_loop.zig");
pub const theme = @import("theme.zig");
pub const vscreen_harness = @import("vscreen_harness.zig");
const render_smoke = @import("render_smoke.zig");

pub const ProductApp = app.ProductApp;
pub const Command = app.Command;
pub const Effect = app.Effect;
pub const Frame = frame.Frame;
pub const ProductLoop = loop.ProductLoop;
pub const TerminalLoop = terminal_loop.TerminalLoop;
pub const Theme = theme.Theme;
pub const ThemeId = theme.ThemeId;
pub const SlotName = slots.SlotName;
pub const SlotContributionId = slots.ContributionId;
pub const SlotOwnerId = slots.OwnerId;
pub const ModalId = surface.ModalId;
pub const ConfirmResult = surface.ConfirmResult;
pub const VScreenHarness = vscreen_harness.VScreenHarness;

test {
    _ = app;
    _ = composer;
    _ = frame;
    _ = keys;
    _ = slots;
    _ = snapshot;
    _ = surface;
    _ = transcript;
    _ = transcript_preview;
    _ = transcript_projection;
    _ = loop;
    _ = terminal_loop;
    _ = theme;
    _ = vscreen_harness;
    _ = render_smoke;
}
