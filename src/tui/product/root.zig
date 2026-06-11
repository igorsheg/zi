pub const app = @import("App.zig");
pub const chrome = @import("chrome.zig");
pub const composer = @import("composer.zig");
pub const frame = @import("frame.zig");
pub const input = @import("input.zig");
pub const keys = @import("keys.zig");
pub const markdown_projection = @import("markdown_projection.zig");
pub const slots = @import("slots.zig");
pub const shimmer = @import("shimmer.zig");
pub const snapshot = @import("snapshot.zig");
pub const status_area = @import("status_area.zig");
pub const surface = @import("surface.zig");
pub const transcript = @import("transcript.zig");
pub const transcript_preview = @import("transcript_preview.zig");
pub const transcript_projection = @import("transcript_projection.zig");
pub const vaxis_terminal_loop = @import("vaxis_terminal_loop.zig");
pub const theme = @import("theme.zig");
pub const wrap = @import("wrap.zig");
const vaxis_smoke_test = @import("vaxis_smoke_test.zig");

pub const ProductApp = app.ProductApp;
pub const Command = app.Command;
pub const Effect = app.Effect;
pub const Frame = frame.Frame;
pub const TerminalLoop = vaxis_terminal_loop.TerminalLoop;
pub const Theme = theme.Theme;
pub const ThemeId = theme.ThemeId;
pub const SlotName = slots.SlotName;
pub const SlotContributionId = slots.ContributionId;
pub const ModalId = surface.ModalId;
pub const ConfirmResult = surface.ConfirmResult;

test {
    _ = vaxis_smoke_test;
}
