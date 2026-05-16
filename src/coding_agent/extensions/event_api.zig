const std = @import("std");
const lua_runtime = @import("lua_runtime.zig");
const lua_helpers = @import("lua_helpers.zig");
const runner_mod = @import("runner.zig");
const api_export = @import("api_export.zig");
const event_registry = @import("registries/event_registry.zig");

const c = lua_runtime.c;
const Lua = lua_helpers.Lua;

pub const export_on = api_export.Export{
    .name = "event",
    .kind = .function,
    .install = installOnExport,
};

fn installOnExport(state: *lua_runtime.LuaState, runner: *runner_mod.ExtensionRunner) void {
    state.pushCClosureWithUserdata(ziOn, runner);
    c.lua_setfield(state.L, -2, export_on.name.ptr);
}

pub fn ziOn(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const lua = Lua.init(L);
    const runner = runnerFromUpvalue(L);

    if (lua.typeOf(1) != .string) {
        return luaError(L, "zi.define.event: expected event name as first argument");
    }
    var name_len: usize = 0;
    const name_ptr = c.lua_tolstring(L, 1, &name_len) orelse return luaError(L, "zi.define.event: invalid event name");
    const event_name = name_ptr[0..name_len];

    const kind = parseEventKind(event_name) orelse {
        _ = c.lua_pushfstring(L, "zi.define.event: unknown event '%s'", name_ptr);
        _ = c.lua_error(L);
        return 0;
    };

    if (lua.typeOf(2) != .function) {
        return luaError(L, "zi.define.event: expected handler function as second argument");
    }

    var handler_ref = lua_helpers.RegistryRef.takeValueAt(lua, 2) catch {
        return luaError(L, "zi.define.event: failed to capture handler reference");
    };
    errdefer handler_ref.release(lua);

    runner.event_registry.subscribe(kind, .{
        .lua_ref = handler_ref.value,
        .source_id = currentEventSourceId(runner),
        .provenance = currentEventProvenance(runner),
    }) catch {
        return luaError(L, "zi.define.event: subscribe failed");
    };
    handler_ref.value = c.LUA_NOREF;

    return 0;
}

pub fn parseEventKind(name: []const u8) ?event_registry.EventKind {
    const Pair = struct { name: []const u8, kind: event_registry.EventKind };
    const table = [_]Pair{
        .{ .name = "session_directory", .kind = .session_directory },
        .{ .name = "resources_discover", .kind = .resources_discover },
        .{ .name = "agent_start", .kind = .agent_start },
        .{ .name = "agent_end", .kind = .agent_end },
        .{ .name = "before_agent_start", .kind = .before_agent_start },
        .{ .name = "input", .kind = .input },
        .{ .name = "context", .kind = .context },
        .{ .name = "before_provider_request", .kind = .before_provider_request },
        .{ .name = "turn_start", .kind = .turn_start },
        .{ .name = "turn_end", .kind = .turn_end },
        .{ .name = "message_start", .kind = .message_start },
        .{ .name = "message_update", .kind = .message_update },
        .{ .name = "message_end", .kind = .message_end },
        .{ .name = "message", .kind = .message },
        .{ .name = "tool_execution_start", .kind = .tool_execution_start },
        .{ .name = "tool_execution_update", .kind = .tool_execution_update },
        .{ .name = "tool_execution_end", .kind = .tool_execution_end },
        .{ .name = "tool_call", .kind = .tool_call },
        .{ .name = "tool_result", .kind = .tool_result },
        .{ .name = "user_bash", .kind = .user_bash },
        .{ .name = "session_start", .kind = .session_start },
        .{ .name = "session_shutdown", .kind = .session_shutdown },
        .{ .name = "session_before_switch", .kind = .session_before_switch },
        .{ .name = "session_before_fork", .kind = .session_before_fork },
        .{ .name = "session_before_compact", .kind = .session_before_compact },
        .{ .name = "session_compact", .kind = .session_compact },
        .{ .name = "session_before_tree", .kind = .session_before_tree },
        .{ .name = "session_tree", .kind = .session_tree },
        .{ .name = "job_stdout", .kind = .job_stdout },
        .{ .name = "job_stderr", .kind = .job_stderr },
        .{ .name = "job_output_dropped", .kind = .job_output_dropped },
        .{ .name = "job_exit", .kind = .job_exit },
        .{ .name = "job_ready", .kind = .job_ready },
        .{ .name = "model_select", .kind = .model_select },
        .{ .name = "ui", .kind = .ui },
    };
    for (table) |p| {
        if (std.mem.eql(u8, p.name, name)) return p.kind;
    }
    return null;
}

fn currentEventProvenance(runner: *const runner_mod.ExtensionRunner) ?@import("../resources/types.zig").ExtensionProvenance {
    const source = runner.currentLoadSource() orelse return null;
    return source.provenance;
}

fn currentEventSourceId(runner: *const runner_mod.ExtensionRunner) []const u8 {
    const source = runner.currentLoadSource() orelse return "lua";
    return source.path;
}

fn luaError(L: *c.lua_State, msg: [:0]const u8) c_int {
    return lua_helpers.raiseError(Lua.init(L), msg);
}

fn runnerFromUpvalue(L: *c.lua_State) *runner_mod.ExtensionRunner {
    return lua_helpers.ptrFromUpvalue(runner_mod.ExtensionRunner, Lua.init(L), 1);
}
