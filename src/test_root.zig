const std = @import("std");
const logging = @import("logging.zig");

pub var std_options_debug_threaded_io_storage: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
pub const std_options_debug_threaded_io: *std.Io.Threaded = &std_options_debug_threaded_io_storage;

test {
    std.testing.log_level = .err;

    std.Io.Threaded.global_single_threaded.allocator = std.heap.smp_allocator;
    logging.setThreadLabel(.@"test");
    _ = @import("zio/root.zig");
    _ = @import("storage.zig");
    _ = @import("logging.zig");
    _ = @import("ai/root.zig");
    _ = @import("json/root.zig");
    _ = @import("coding_agent/auth/root.zig");
    _ = @import("coding_agent/settings/root.zig");
    _ = @import("coding_agent/cli/root.zig");
    _ = @import("coding_agent/cli/help.zig");
    _ = @import("coding_agent/cli/initial_message.zig");
    _ = @import("coding_agent/cli/run_interactive.zig");
    _ = @import("agent/root.zig");
    _ = @import("coding_agent/session/root.zig");
    _ = @import("coding_agent/root.zig");
    _ = @import("coding_agent/system_prompt.zig");
    _ = @import("coding_agent/resources/root.zig");
    _ = @import("search/root.zig");
    _ = @import("coding_agent/skills/root.zig");
    _ = @import("coding_agent/tools/bash.zig");
    _ = @import("coding_agent/tools/read.zig");
    _ = @import("tui/root.zig");
    _ = @import("tui/interactive/job_manager.zig");
    _ = @import("themes/root.zig");
    _ = @import("tui/editor/root.zig");
    _ = @import("coding_agent/slash_commands.zig");
    _ = @import("spawn/root.zig");
    _ = @import("coding_agent/extensions/system_command.zig");
    _ = @import("coding_agent/extensions/lua_runtime.zig");
    _ = @import("coding_agent/extensions/registries/root.zig");
    _ = @import("coding_agent/extensions/runner.zig");
    _ = @import("coding_agent/extensions/api.zig");
    _ = @import("coding_agent/extensions/dispatch.zig");
    _ = @import("coding_agent/extensions/event_bridge.zig");
    _ = @import("coding_agent/extensions/system_worker.zig");
    _ = @import("coding_agent/extensions/loader.zig");
    _ = @import("coding_agent/extensions/lua_tool.zig");
    _ = @import("coding_agent/extensions/lua_renderer.zig");
}
