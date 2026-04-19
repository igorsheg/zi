const lua_runtime = @import("lua_runtime.zig");
const runner_mod = @import("runner.zig");
const json_util = @import("../../ai/json_util.zig");
const agent_protocol = @import("../../agent3/types.zig");
const session_mod = @import("../session/root.zig");

const c = lua_runtime.c;

/// Push the shared extension context table used by tool execution and
/// event handlers. Tool-specific callers can add extra fields (e.g.
/// `update`) after this returns.
pub fn pushExtensionContext(L: *c.lua_State, runner: *runner_mod.ExtensionRunner) !void {
    c.lua_createtable(L, 0, 10);

    _ = c.lua_pushlstring(L, runner.cwd.ptr, runner.cwd.len);
    c.lua_setfield(L, -2, "cwd");

    const has_ui = switch (runner.runtime) {
        .bound => |bound| bound.ui != null,
        .stub => false,
    };
    c.lua_pushboolean(L, if (has_ui) 1 else 0);
    c.lua_setfield(L, -2, "has_ui");

    c.lua_pushnil(L);
    c.lua_setfield(L, -2, "ui");

    c.lua_pushnil(L);
    c.lua_setfield(L, -2, "signal");

    switch (runner.runtime) {
        .bound => |bound| {
            pushModel(L, bound.get_model(bound.session));
            c.lua_setfield(L, -2, "model");

            pushMethod(L, runner, &ctxIsIdle);
            c.lua_setfield(L, -2, "is_idle");

            pushMethod(L, runner, &ctxAbort);
            c.lua_setfield(L, -2, "abort");

            pushMethod(L, runner, &ctxHasPendingMessages);
            c.lua_setfield(L, -2, "has_pending_messages");

            if (bound.shutdown != null) {
                pushMethod(L, runner, &ctxShutdown);
            } else {
                c.lua_pushnil(L);
            }
            c.lua_setfield(L, -2, "shutdown");

            pushMethod(L, runner, &ctxGetContextUsage);
            c.lua_setfield(L, -2, "get_context_usage");

            pushMethod(L, runner, &ctxGetSystemPrompt);
            c.lua_setfield(L, -2, "get_system_prompt");
        },
        .stub => {
            c.lua_pushnil(L);
            c.lua_setfield(L, -2, "model");
            c.lua_pushnil(L);
            c.lua_setfield(L, -2, "is_idle");
            c.lua_pushnil(L);
            c.lua_setfield(L, -2, "abort");
            c.lua_pushnil(L);
            c.lua_setfield(L, -2, "has_pending_messages");
            c.lua_pushnil(L);
            c.lua_setfield(L, -2, "shutdown");
            c.lua_pushnil(L);
            c.lua_setfield(L, -2, "get_context_usage");
            c.lua_pushnil(L);
            c.lua_setfield(L, -2, "get_system_prompt");
        },
    }
}

fn pushMethod(L: *c.lua_State, runner: *runner_mod.ExtensionRunner, func: *const fn (?*c.lua_State) callconv(.c) c_int) void {
    c.lua_pushlightuserdata(L, runner);
    c.lua_pushcclosure(L, func, 1);
}

fn pushModel(L: *c.lua_State, model: agent_protocol.Model) void {
    c.lua_createtable(L, 0, 6);
    _ = c.lua_pushlstring(L, model.id.ptr, model.id.len);
    c.lua_setfield(L, -2, "id");
    _ = c.lua_pushlstring(L, model.name.ptr, model.name.len);
    c.lua_setfield(L, -2, "name");
    const provider = json_util.providerToString(model.provider);
    _ = c.lua_pushlstring(L, provider.ptr, provider.len);
    c.lua_setfield(L, -2, "provider");
    c.lua_pushinteger(L, @intCast(model.context_window));
    c.lua_setfield(L, -2, "context_window");
    c.lua_pushboolean(L, if (model.reasoning) 1 else 0);
    c.lua_setfield(L, -2, "reasoning");
}

fn pushContextUsage(L: *c.lua_State, usage: session_mod.context_usage.ContextUsage) void {
    c.lua_createtable(L, 0, 3);
    if (usage.tokens) |tokens| {
        c.lua_pushinteger(L, @intCast(tokens));
    } else {
        c.lua_pushnil(L);
    }
    c.lua_setfield(L, -2, "tokens");
    c.lua_pushinteger(L, @intCast(usage.context_window));
    c.lua_setfield(L, -2, "context_window");
    if (usage.percent) |percent| {
        c.lua_pushnumber(L, percent);
    } else {
        c.lua_pushnil(L);
    }
    c.lua_setfield(L, -2, "percent");
}

fn runnerFromUpvalue(L: *c.lua_State) *runner_mod.ExtensionRunner {
    const ud = c.lua_touserdata(L, c.lua_upvalueindex(1));
    return @ptrCast(@alignCast(ud.?));
}

fn ctxIsIdle(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = runnerFromUpvalue(L);
    switch (runner.runtime) {
        .bound => |bound| c.lua_pushboolean(L, if (bound.is_idle(bound.session)) 1 else 0),
        .stub => c.lua_pushboolean(L, 1),
    }
    return 1;
}

fn ctxAbort(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = runnerFromUpvalue(L);
    switch (runner.runtime) {
        .bound => |bound| bound.abort(bound.session),
        .stub => {},
    }
    return 0;
}

fn ctxHasPendingMessages(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = runnerFromUpvalue(L);
    switch (runner.runtime) {
        .bound => |bound| c.lua_pushboolean(L, if (bound.has_pending_messages(bound.session)) 1 else 0),
        .stub => c.lua_pushboolean(L, 0),
    }
    return 1;
}

fn ctxShutdown(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = runnerFromUpvalue(L);
    switch (runner.runtime) {
        .bound => |bound| if (bound.shutdown) |func| func(bound.session),
        .stub => {},
    }
    return 0;
}

fn ctxGetContextUsage(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = runnerFromUpvalue(L);
    switch (runner.runtime) {
        .bound => |bound| {
            if (bound.get_context_usage(bound.session)) |usage| {
                pushContextUsage(L, usage);
            } else {
                c.lua_pushnil(L);
            }
        },
        .stub => c.lua_pushnil(L),
    }
    return 1;
}

fn ctxGetSystemPrompt(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = runnerFromUpvalue(L);
    switch (runner.runtime) {
        .bound => |bound| {
            const prompt = bound.get_system_prompt(bound.session);
            _ = c.lua_pushlstring(L, prompt.ptr, prompt.len);
        },
        .stub => _ = c.lua_pushlstring(L, "".ptr, 0),
    }
    return 1;
}
