const coding_agent = @import("../coding_agent/root.zig");
const App = @import("App.zig");
const event_loop = @import("event_loop.zig");
const render_invalidation = @import("render_invalidation.zig");
const screen = @import("Screen.zig");
const safe_text = @import("SafeText.zig");
const user_message_card = @import("assistant/user_message_card.zig");
const footer_presentation = @import("footer/presentation.zig");
const footer_surface = @import("footer/surface_frame.zig");
const tool_presentation = @import("tools/tool_presentation.zig");
const transcript = @import("transcript/root.zig");
const render = @import("render_engine/root.zig");
const markdown = @import("markdown/root.zig");
const decoder = @import("input/Decoder.zig");
const line_editor = @import("input/LineEditor.zig");
const slash_menu = @import("input/SlashMenu.zig");
const cursor_position_parser = @import("terminal/cursor_position_parser.zig");
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
    _ = render_invalidation;
    _ = screen;
    _ = safe_text;
    _ = user_message_card;
    _ = footer_presentation;
    _ = footer_surface;
    _ = tool_presentation;
    _ = transcript;
    _ = render;
    _ = markdown;
    _ = decoder;
    _ = line_editor;
    _ = slash_menu;
    _ = cursor_position_parser;
    _ = terminal_session;
}
