const coding_agent = @import("../coding_agent/root.zig");
const App = @import("App.zig");
const event_loop = @import("EventLoop.zig");
const render_request = @import("RenderRequest.zig");
const screen = @import("Screen.zig");
const safe_text = @import("SafeText.zig");
const transcript = @import("transcript/root.zig");
const render = @import("render/root.zig");
const markdown = @import("markdown/root.zig");
const decoder = @import("input/Decoder.zig");
const line_editor = @import("input/LineEditor.zig");
const cursor_probe = @import("terminal/CursorProbe.zig");
const terminal_session = @import("terminal/Session.zig");

pub const frontend: coding_agent.interactive.Frontend = .{
    .runFn = run,
};

fn run(
    _: ?*anyopaque,
    context: coding_agent.interactive.Context,
) !coding_agent.interactive.ExitCause {
    var app = try App.init(
        context.allocator,
        context.io,
        context.host,
        context.writer,
        .{},
    );
    defer app.deinit();
    const cause = try app.run(
        context.input,
        context.output,
        context.transcript,
        .{ .initial_prompts = context.initial_prompts },
    );
    return switch (cause) {
        .requested => .requested,
        .input_closed => .input_closed,
    };
}

test {
    _ = App;
    _ = event_loop;
    _ = render_request;
    _ = screen;
    _ = safe_text;
    _ = transcript;
    _ = render;
    _ = markdown;
    _ = decoder;
    _ = line_editor;
    _ = cursor_probe;
    _ = terminal_session;
}
