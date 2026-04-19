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
    _ = @import("coding_agent/auth/root.zig");
    _ = @import("coding_agent/settings/root.zig");
    _ = @import("coding_agent/cli/root.zig");
    _ = @import("coding_agent/cli/help.zig");
    _ = @import("coding_agent/cli/initial_message.zig");
    _ = @import("coding_agent/cli/run_interactive.zig");
    _ = @import("agent2/root.zig");
    _ = @import("agent3/root.zig");
    _ = @import("coding_agent/session/root.zig");
    _ = @import("coding_agent/root.zig");
    _ = @import("coding_agent/system_prompt.zig");
    _ = @import("coding_agent/resources/root.zig");
    _ = @import("search/root.zig");
    _ = @import("coding_agent/skills/root.zig");
    _ = @import("coding_agent/tools/bash.zig");
    _ = @import("coding_agent/tools/read.zig");
    _ = @import("tui/root.zig");
    _ = @import("themes/root.zig");
    _ = @import("tui/editor/root.zig");
    _ = @import("coding_agent/slash_commands.zig");
    _ = @import("spawn/root.zig");
    _ = @import("coding_agent/extensions/lua_runtime.zig");
    _ = @import("coding_agent/extensions/registries/root.zig");
    _ = @import("coding_agent/extensions/runner.zig");
    _ = @import("coding_agent/extensions/api.zig");
    _ = @import("coding_agent/extensions/dispatch.zig");
    _ = @import("coding_agent/extensions/event_bridge.zig");
    _ = @import("coding_agent/extensions/loader.zig");
    _ = @import("coding_agent/extensions/lua_tool.zig");
    _ = @import("coding_agent/extensions/lua_renderer.zig");
}
