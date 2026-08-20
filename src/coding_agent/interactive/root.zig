const app = @import("App.zig");
const event_loop = @import("EventLoop.zig");
const normal_screen_renderer = @import("NormalScreenRenderer.zig");
const policy = @import("Policy.zig");
const decoder = @import("input/Decoder.zig");
const line_editor = @import("input/LineEditor.zig");
const terminal_session = @import("terminal/Session.zig");

test {
    _ = app;
    _ = event_loop;
    _ = normal_screen_renderer;
    _ = policy;
    _ = decoder;
    _ = line_editor;
    _ = terminal_session;
}
