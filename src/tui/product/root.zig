pub const app = @import("App.zig");
pub const composer = @import("composer.zig");
pub const frame = @import("frame.zig");
const render_smoke = @import("render_smoke.zig");

pub const ProductApp = app.ProductApp;
pub const Command = app.Command;
pub const Effect = app.Effect;
pub const Frame = frame.Frame;

test {
    _ = app;
    _ = composer;
    _ = frame;
    _ = render_smoke;
}
