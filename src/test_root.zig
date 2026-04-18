const std = @import("std");
const logging = @import("logging.zig");

pub const std_options: std.Options = .{
    .logFn = logging.logFn,
};

test {
    logging.setThreadLabel(.@"test");
    _ = @import("abort_signal.zig");
    _ = @import("conversation_snapshot.zig");
    _ = @import("storage.zig");
    _ = @import("debug/tracked_allocator.zig");
    _ = @import("logging.zig");
    _ = @import("ai/root.zig");
    _ = @import("json/root.zig");
    _ = @import("auth/root.zig");
    _ = @import("settings/root.zig");
    _ = @import("cli/root.zig");
    _ = @import("cli/help.zig");
    _ = @import("cli/initial_message.zig");
    _ = @import("cli/run_interactive.zig");
    _ = @import("agent2/root.zig");
    _ = @import("agent3/root.zig");
    _ = @import("session/root.zig");
    _ = @import("coding_agent.zig");
    _ = @import("system_prompt.zig");
    _ = @import("resources/root.zig");
    _ = @import("search/root.zig");
    _ = @import("skills/root.zig");
    _ = @import("tools/bash.zig");
    _ = @import("tools/read.zig");
    _ = @import("tui/root.zig");
    _ = @import("themes/root.zig");
    _ = @import("tui/editor/root.zig");
    _ = @import("slash_commands.zig");
    _ = @import("spawn/root.zig");
    _ = @import("extensions/lua_runtime.zig");
    _ = @import("extensions/registries/root.zig");
    _ = @import("extensions/runner.zig");
    _ = @import("extensions/api.zig");
    _ = @import("extensions/dispatch.zig");
    _ = @import("extensions/event_bridge.zig");
    _ = @import("extensions/loader.zig");
    _ = @import("extensions/lua_tool.zig");
    _ = @import("extensions/lua_renderer.zig");
}
