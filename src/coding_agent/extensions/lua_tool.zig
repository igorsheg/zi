const std = @import("std");
const lua_runtime = @import("lua_runtime.zig");
const runner_mod = @import("runner.zig");
const tool_registry = @import("registries/tool_registry.zig");
const agent_protocol = @import("../../agent/types.zig");
const abort_signal_mod = @import("../../zio/root.zig");
const ai = @import("../../ai/root.zig");
const api_v3 = @import("api_v3.zig");
const spawn_api = @import("spawn_api.zig");
const context_mod = @import("context.zig");
const resource_types = @import("../resources/types.zig");
const extension_ui = @import("ui.zig");
const request_mod = @import("../request.zig");
const spawn_mod = @import("../../spawn/spawn.zig");
const spawn_types = @import("../../spawn/types.zig");
const extension_limits = @import("limits.zig");
const system_command = @import("system_command.zig");

const c = lua_runtime.c;
const log = std.log.scoped(.zi_lua_tool);

const AgentToolResult = agent_protocol.AgentToolResult;
const abort_hook_registry_key: u8 = 0;
const lua_abort_hook_instruction_count: c_int = 10_000;

fn installAbortHook(L: *c.lua_State, runner: *runner_mod.ExtensionRunner) void {
    c.lua_pushlightuserdata(L, @constCast(&abort_hook_registry_key));
    c.lua_pushlightuserdata(L, runner);
    c.lua_settable(L, c.LUA_REGISTRYINDEX);
    c.lua_sethook(L, abortHook, c.LUA_MASKCOUNT, lua_abort_hook_instruction_count);
}

fn clearAbortHook(L: *c.lua_State) void {
    c.lua_sethook(L, null, 0, 0);
    c.lua_pushlightuserdata(L, @constCast(&abort_hook_registry_key));
    c.lua_pushnil(L);
    c.lua_settable(L, c.LUA_REGISTRYINDEX);
}

fn abortHook(L: ?*c.lua_State, _: ?*c.lua_Debug) callconv(.c) void {
    const state = L orelse return;
    c.lua_pushlightuserdata(state, @constCast(&abort_hook_registry_key));
    _ = c.lua_gettable(state, c.LUA_REGISTRYINDEX);
    const raw = c.lua_touserdata(state, -1) orelse {
        c.lua_pop(state, 1);
        return;
    };
    const runner: *runner_mod.ExtensionRunner = @ptrCast(@alignCast(raw));
    c.lua_pop(state, 1);
    if (runner.current_tool_execution) |ctx| {
        if (ctx.signal.isAborted()) _ = c.luaL_error(state, "tool execution cancelled");
    }
}

const ToolResultLimits = struct {
    max_text_bytes: usize,
    max_blocks: usize,
    details: lua_runtime.JsonConvertLimits,
    presentation: lua_runtime.JsonConvertLimits,
};

const default_json_convert_limits = lua_runtime.default_json_convert_limits;
const presentation_json_convert_limits = lua_runtime.presentation_json_convert_limits;

const default_tool_result_limits = ToolResultLimits{
    .max_text_bytes = extension_limits.tool_result_text_bytes,
    .max_blocks = extension_limits.tool_result_blocks,
    .details = default_json_convert_limits,
    .presentation = presentation_json_convert_limits,
};

const partial_tool_result_limits = ToolResultLimits{
    .max_text_bytes = extension_limits.tool_result_text_bytes,
    .max_blocks = extension_limits.tool_result_blocks,
    .details = default_json_convert_limits,
    .presentation = presentation_json_convert_limits,
};

const tool_result_truncated_marker = "\n... [extension tool result truncated at 64KiB] ...";

pub const LuaToolCtx = struct {
    runner: *runner_mod.ExtensionRunner,
    lua_ref: c_int,
    provenance: ?resource_types.ExtensionProvenance,

    name: []const u8,
};

pub fn buildAgentTool(
    _: std.mem.Allocator,
    runner: *runner_mod.ExtensionRunner,
    ext_tool: tool_registry.ToolDefinition,
) !agent_protocol.AgentTool {
    const lua_ref = switch (ext_tool.impl) {
        .lua => |r| r,
        .builtin => return error.NotALuaTool,
    };
    const ctx = try runner.hookAllocator().create(LuaToolCtx);
    ctx.* = .{
        .runner = runner,
        .lua_ref = lua_ref,
        .provenance = ext_tool.source.provenance,
        .name = ext_tool.name,
    };

    return .{
        .name = ext_tool.name,
        .description = ext_tool.description,
        .label = ext_tool.label,
        .display_call = ext_tool.display_call,
        .parameters = ext_tool.parameters,
        .ctx = @ptrCast(ctx),
        .execute = &execute,
    };
}

fn execute(
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    tool_call_id: []const u8,
    args: std.json.Value,
    signal: abort_signal_mod.cancel.Token,
    on_update: ?agent_protocol.AgentToolUpdateCallback,
    update_ctx: ?*anyopaque,
) agent_protocol.AgentToolExecution {
    const tctx: *LuaToolCtx = @ptrCast(@alignCast(ctx.?));
    const state = tctx.runner.lua_state orelse {
        return .{ .ready = errorResult(allocator, "lua state not attached") };
    };

    tctx.runner.assertOnLuaThread();

    var co = lua_runtime.Coroutine.init(state) catch |err| {
        log.warn("lua tool coroutine allocation failed: {s}", .{@errorName(err)});
        return .{ .ready = errorResult(allocator, @errorName(err)) };
    };
    var co_owned = true;
    defer if (co_owned) co.deinit();

    tctx.runner.current_tool_execution = .{ .signal = signal, .on_update = on_update, .update_ctx = update_ctx };
    defer {
        tctx.runner.current_tool_execution = null;
    }

    prepareHandlerCoroutine(state, tctx.runner, &co, tctx.lua_ref, tctx.provenance, args) catch |err| {
        log.warn("lua tool execution failed: {s}", .{@errorName(err)});
        return .{ .ready = errorResult(allocator, @errorName(err)) };
    };

    if (tctx.provenance) |prov| tctx.runner.beginExecutionContext(tctx.runner.sourceForProvenance(prov));
    defer if (tctx.provenance != null) tctx.runner.endExecutionContext();

    var nargs: c_int = 2;
    while (true) {
        installAbortHook(co.L, tctx.runner);
        defer clearAbortHook(co.L);
        const r = co.resumeWith(nargs) catch |err| {
            log.warn("lua tool execution failed: {s}", .{@errorName(err)});
            return .{ .ready = errorResult(allocator, @errorName(err)) };
        };
        nargs = 0;

        switch (r.status) {
            .yielded => {
                if (tctx.runner.current_async_start) |start_value| {
                    if (r.nresults > 0) c.lua_pop(co.L, r.nresults);
                    var start = start_value;
                    tctx.runner.current_async_start = null;
                    errdefer start.deinit(tctx.runner.allocator);

                    const pending = allocator.create(PendingLuaToolExecution) catch {
                        start.deinit(tctx.runner.allocator);
                        return .{ .ready = errorResult(allocator, "failed to allocate lua tool continuation") };
                    };
                    pending.* = .{
                        .runner = tctx.runner,
                        .state = state,
                        .co = co,
                        .start = start,
                        .provenance = tctx.provenance,
                        .tool_name = tctx.name,
                        .tool_call_id = tool_call_id,
                        .generation = tctx.runner.generation,
                    };
                    co_owned = false;
                    return .{ .pending = .{
                        .ptr = @ptrCast(pending),
                        .wait = &PendingLuaToolExecution.wait,
                        .cancel = &PendingLuaToolExecution.cancel,
                        .deinit = &PendingLuaToolExecution.deinit,
                    } };
                }

                if (tctx.runner.current_spawn_request) |spawn_req_value| {
                    if (r.nresults > 0) c.lua_pop(co.L, r.nresults);
                    var spawn_req = spawn_req_value;
                    tctx.runner.current_spawn_request = null;
                    errdefer {
                        if (spawn_req.callbacks_ref != c.LUA_NOREF) c.luaL_unref(spawn_req.source_L, c.LUA_REGISTRYINDEX, spawn_req.callbacks_ref);
                        spawn_req.deinit(tctx.runner.allocator);
                    }
                    const pending = allocator.create(PendingLuaToolExecution) catch {
                        if (spawn_req.callbacks_ref != c.LUA_NOREF) c.luaL_unref(spawn_req.source_L, c.LUA_REGISTRYINDEX, spawn_req.callbacks_ref);
                        spawn_req.deinit(tctx.runner.allocator);
                        return .{ .ready = errorResult(allocator, "failed to allocate lua tool continuation") };
                    };
                    pending.* = .{
                        .runner = tctx.runner,
                        .state = state,
                        .co = co,
                        .spawn_request = spawn_req,
                        .provenance = tctx.provenance,
                        .tool_name = tctx.name,
                        .tool_call_id = tool_call_id,
                        .generation = tctx.runner.generation,
                    };
                    co_owned = false;
                    return .{ .pending = .{
                        .ptr = @ptrCast(pending),
                        .wait = &PendingLuaToolExecution.wait,
                        .cancel = &PendingLuaToolExecution.cancel,
                        .deinit = &PendingLuaToolExecution.deinit,
                    } };
                }

                serviceYieldedToolCoroutine(allocator, tctx.runner, state, &co, r.nresults) catch |err| {
                    log.warn("lua tool yielded operation failed: {s}", .{@errorName(err)});
                    return .{ .ready = errorResult(allocator, @errorName(err)) };
                };
                continue;
            },
            .ok, .finished => {
                const top = c.lua_gettop(co.L);
                defer if (r.nresults > 0) c.lua_settop(co.L, top - r.nresults);
                const result = if (r.nresults == 0)
                    emptyResult()
                else
                    parseReturn(allocator, co.L, top, default_tool_result_limits) catch |err| blk: {
                        log.warn("lua tool result parsing failed: {s}", .{@errorName(err)});
                        break :blk errorResult(allocator, @errorName(err));
                    };
                return .{ .ready = result };
            },
        }
    }
}

const PendingLuaToolExecution = struct {
    runner: *runner_mod.ExtensionRunner,
    state: *lua_runtime.LuaState,
    co: lua_runtime.Coroutine,
    start: ?runner_mod.AsyncStart = null,
    spawn_request: ?runner_mod.SpawnRequest = null,
    provenance: ?resource_types.ExtensionProvenance,
    tool_name: []const u8,
    tool_call_id: []const u8,
    generation: runner_mod.Generation,
    cancelled: bool = false,

    fn wait(ptr: *anyopaque, allocator: std.mem.Allocator, signal: abort_signal_mod.cancel.Token, on_update: ?agent_protocol.AgentToolUpdateCallback, update_ctx: ?*anyopaque) AgentToolResult {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.cancelled or isAbortedToolSignal(signal)) return errorResult(allocator, "tool execution cancelled");
        if (self.runner.generation != self.generation) return errorResult(allocator, "tool execution cancelled by extension reload");

        self.runner.assertOnLuaThread();
        self.runner.current_tool_execution = .{ .signal = signal, .on_update = on_update, .update_ctx = update_ctx };
        defer {
            self.runner.current_tool_execution = null;
        }

        if (self.provenance) |prov| self.runner.beginExecutionContext(self.runner.sourceForProvenance(prov));
        defer if (self.provenance != null) self.runner.endExecutionContext();

        while (true) {
            if (self.cancelled or isAbortedToolSignal(signal)) return errorResult(allocator, "tool execution cancelled");
            if (self.runner.generation != self.generation) return errorResult(allocator, "tool execution cancelled by extension reload");
            if (self.start) |start_value| {
                self.start = null;
                serviceYieldedAsyncToolCoroutine(self.runner, start_value) catch |err| {
                    log.warn("lua tool async operation failed: {s}", .{@errorName(err)});
                    return errorResult(allocator, @errorName(err));
                };
            }
            if (self.spawn_request) |spawn_req_value| {
                self.spawn_request = null;
                serviceYieldedSpawnToolCoroutine(allocator, self.runner, &self.co, spawn_req_value) catch |err| {
                    log.warn("lua tool spawn operation failed: {s}", .{@errorName(err)});
                    return errorResult(allocator, @errorName(err));
                };
            }

            installAbortHook(self.co.L, self.runner);
            defer clearAbortHook(self.co.L);
            const r = self.co.resumeWith(0) catch |err| {
                log.warn("lua tool continuation failed: {s}", .{@errorName(err)});
                return errorResult(allocator, @errorName(err));
            };
            switch (r.status) {
                .yielded => {
                    if (self.runner.current_async_start) |start_value| {
                        if (r.nresults > 0) c.lua_pop(self.co.L, r.nresults);
                        self.runner.current_async_start = null;
                        self.start = start_value;
                        continue;
                    }
                    if (self.runner.current_spawn_request) |spawn_req_value| {
                        if (r.nresults > 0) c.lua_pop(self.co.L, r.nresults);
                        self.runner.current_spawn_request = null;
                        self.spawn_request = spawn_req_value;
                        continue;
                    }
                    serviceYieldedToolCoroutine(allocator, self.runner, self.state, &self.co, r.nresults) catch |err| {
                        log.warn("lua tool yielded operation failed: {s}", .{@errorName(err)});
                        return errorResult(allocator, @errorName(err));
                    };
                    continue;
                },
                .ok, .finished => {
                    const top = c.lua_gettop(self.co.L);
                    defer if (r.nresults > 0) c.lua_settop(self.co.L, top - r.nresults);
                    _ = self.tool_call_id;
                    _ = self.tool_name;
                    if (r.nresults == 0) return emptyResult();
                    return parseReturn(allocator, self.co.L, top, default_tool_result_limits) catch |err| {
                        log.warn("lua tool result parsing failed: {s}", .{@errorName(err)});
                        return errorResult(allocator, @errorName(err));
                    };
                },
            }
        }
    }

    fn cancel(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.cancelled = true;
    }

    fn deinit(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.start) |*start| start.deinit(self.runner.allocator);
        if (self.spawn_request) |*req| {
            if (req.callbacks_ref != c.LUA_NOREF) c.luaL_unref(req.source_L, c.LUA_REGISTRYINDEX, req.callbacks_ref);
            req.deinit(self.runner.allocator);
        }
        self.co.deinit();
        allocator.destroy(self);
    }
};

fn isAbortedToolSignal(signal: abort_signal_mod.cancel.Token) bool {
    return signal.isAborted();
}

fn awaitToolExecutionForCompat(execution: agent_protocol.AgentToolExecution, allocator: std.mem.Allocator, signal: abort_signal_mod.cancel.Token) AgentToolResult {
    return switch (execution) {
        .ready => |result| result,
        .pending => |pending| blk: {
            defer pending.free(allocator);
            break :blk pending.await(allocator, signal, null, null);
        },
    };
}

fn prepareHandlerCoroutine(
    state: *lua_runtime.LuaState,
    runner: *runner_mod.ExtensionRunner,
    co: *lua_runtime.Coroutine,
    handler_ref: c_int,
    provenance: ?resource_types.ExtensionProvenance,
    args: std.json.Value,
) !void {
    _ = c.lua_rawgeti(co.L, c.LUA_REGISTRYINDEX, handler_ref);
    if (c.lua_type(co.L, -1) != c.LUA_TFUNCTION) {
        c.lua_pop(co.L, 1);
        return error.HandlerNotAFunction;
    }

    try lua_runtime.pushJsonValue(co.L, args);

    try context_mod.pushExtensionContext(co.L, runner, provenance);
    c.lua_pushlightuserdata(co.L, runner);
    c.lua_pushcclosure(co.L, &luaToolUpdate, 1);
    c.lua_setfield(co.L, -2, "update");

    runner.setModuleContext(state, provenance);
}

fn serviceYieldedToolCoroutine(
    allocator: std.mem.Allocator,
    runner: *runner_mod.ExtensionRunner,
    state: *lua_runtime.LuaState,
    co: *lua_runtime.Coroutine,
    nresults: c_int,
) !void {
    _ = state;
    if (nresults > 0) c.lua_pop(co.L, nresults);

    if (runner.current_async_start) |start| {
        runner.current_async_start = null;
        try serviceYieldedAsyncToolCoroutine(runner, start);
        return;
    }

    const req = runner.current_spawn_request orelse return error.UnexpectedYield;
    runner.current_spawn_request = null;
    try serviceYieldedSpawnToolCoroutine(allocator, runner, co, req);
}

fn serviceYieldedSpawnToolCoroutine(
    allocator: std.mem.Allocator,
    runner: *runner_mod.ExtensionRunner,
    co: *lua_runtime.Coroutine,
    req_value: runner_mod.SpawnRequest,
) !void {
    var req = req_value;
    defer {
        if (req.callbacks_ref != c.LUA_NOREF) c.luaL_unref(req.source_L, c.LUA_REGISTRYINDEX, req.callbacks_ref);
        req.deinit(runner.allocator);
    }

    var trampoline_ctx = spawn_api.TrampolineCtx{
        .L = co.L,
        .callbacks_ref = req.callbacks_ref,
    };

    var fanout = SpawnEventFanout{
        .allocator = runner.allocator,
        .lua = if (req.callbacks_ref != c.LUA_NOREF) &trampoline_ctx else null,
    };

    const has_observer = fanout.lua != null;
    const cfg = spawn_types.SpawnConfig{
        .allocator = runner.allocator,
        .io = runner.io,
        .cwd = req.cwd,
        .task = req.task,
        .model = req.model,
        .tools = req.tools,
        .append_system_prompt = req.append_system_prompt,
        .signal = req.signal,
        .on_event = if (has_observer) &SpawnEventFanout.callback else null,
        .on_event_ctx = if (has_observer) @ptrCast(&fanout) else null,
        .on_wait = if (has_observer) &SpawnEventFanout.drainCallback else null,
        .on_wait_ctx = if (has_observer) @ptrCast(&fanout) else null,
    };

    var spawn_result = spawn_mod.ziSpawn(cfg);
    defer spawn_result.deinit(runner.allocator);
    defer fanout.deinit();

    try fanout.drain();

    runner.current_spawn_result = .{ .result = try spawnResultToToolResult(allocator, spawn_result) };
}

fn serviceYieldedAsyncToolCoroutine(
    runner: *runner_mod.ExtensionRunner,
    start_value: runner_mod.AsyncStart,
) !void {
    var start = start_value;
    defer start.deinit(runner.allocator);

    switch (start.request) {
        .system => |request| {
            var result: runner_mod.AsyncResult = .{ .system = try runToolSystemRequest(runner, request) };
            errdefer result.deinit(runner.allocator);
            try runner.completed_async.put(runner.allocator, start.id, result);
        },
        .ai_complete => |request| {
            var result: runner_mod.AsyncResult = .{ .ai_complete = try runToolAiCompleteRequest(runner, request) };
            errdefer result.deinit(runner.allocator);
            try runner.completed_async.put(runner.allocator, start.id, result);
        },
        .ai_session_prompt => |request| {
            var result: runner_mod.AsyncResult = .{ .ai_session_prompt = try runToolAiSessionPromptRequest(runner, request) };
            errdefer result.deinit(runner.allocator);
            try runner.completed_async.put(runner.allocator, start.id, result);
        },
        .@"test" => return error.UnsupportedToolAsyncOperation,
    }
}

fn runToolAiCompleteRequest(runner: *runner_mod.ExtensionRunner, request: runner_mod.AiCompleteRequest) !runner_mod.AiCompleteResult {
    return switch (runner.runtime) {
        .bound => |bound| blk: {
            const complete_fn = bound.ai_complete orelse return error.AiCompleteUnavailable;
            var sink_ctx = AiCompleteToolEventSink{ .runner = runner, .request = request };
            const sink: ?runner_mod.AiSessionEventSink = if (request.callbacks_ref != c.LUA_NOREF)
                .{ .ptr = @ptrCast(&sink_ctx), .emit = AiCompleteToolEventSink.emit }
            else
                null;
            break :blk try complete_fn(bound.session, runner.allocator, request, sink);
        },
        .stub => error.RuntimeNotBound,
    };
}

const AiCompleteToolEventSink = struct {
    runner: *runner_mod.ExtensionRunner,
    request: runner_mod.AiCompleteRequest,

    fn emit(ptr: *anyopaque, event: runner_mod.AiCompleteStreamEvent) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.runner.dispatchAiCompleteRequestEvent(self.request, event);
    }
};

fn runToolAiSessionPromptRequest(runner: *runner_mod.ExtensionRunner, request: runner_mod.AiSessionPromptRequest) !runner_mod.AiCompleteResult {
    return switch (runner.runtime) {
        .bound => |bound| blk: {
            const prompt_fn = bound.ai_session_prompt orelse return error.AiSessionPromptUnavailable;
            var sink_ctx = AiSessionPromptToolEventSink{ .runner = runner, .request = request, .session_id = request.session_id };
            const wants_events = request.callbacks_ref != c.LUA_NOREF or blk2: {
                const session = runner.getSideAiSession(request.session_id) orelse break :blk2 false;
                break :blk2 session.callbacks_ref != c.LUA_NOREF;
            };
            const sink: ?runner_mod.AiSessionEventSink = if (wants_events)
                .{ .ptr = @ptrCast(&sink_ctx), .emit = AiSessionPromptToolEventSink.emit }
            else
                null;
            break :blk try prompt_fn(bound.session, runner.allocator, request, sink);
        },
        .stub => error.RuntimeNotBound,
    };
}

const AiSessionPromptToolEventSink = struct {
    runner: *runner_mod.ExtensionRunner,
    request: runner_mod.AiSessionPromptRequest,
    session_id: u64,

    fn emit(ptr: *anyopaque, event: runner_mod.AiCompleteStreamEvent) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.runner.dispatchAiSessionPromptEvent(self.session_id, self.request, event);
    }
};

fn runToolSystemRequest(runner: *runner_mod.ExtensionRunner, request: runner_mod.SystemRequest) !runner_mod.SystemResult {
    var env: std.ArrayListUnmanaged(system_command.EnvPair) = .empty;
    defer env.deinit(runner.allocator);
    try env.ensureTotalCapacity(runner.allocator, request.env.len);
    for (request.env) |pair| env.appendAssumeCapacity(.{ .key = pair.key, .value = pair.value });

    return system_command.run(runner.allocator, runner.io, .{
        .argv = request.argv,
        .cwd = request.cwd,
        .stdin = request.stdin,
        .env = env.items,
        .clear_env = request.clear_env,
        .timeout_ms = request.timeout_ms,
        .max_stdout_bytes = request.max_stdout_bytes,
        .max_stderr_bytes = request.max_stderr_bytes,
        .text = request.text,
        .stdio = switch (request.stdio) {
            .capture => .capture,
            .terminal => .terminal,
        },
        .signal = request.signal,
    });
}

const SpawnEventFanout = struct {
    const PendingEvent = struct {
        kind: []const u8,
        event: std.json.Value,
    };

    allocator: std.mem.Allocator,
    lua: ?*spawn_api.TrampolineCtx = null,
    events: std.ArrayList(PendingEvent) = .empty,
    mutex: std.Io.Mutex = .init,

    fn callback(kind: []const u8, event: std.json.Value, ctx: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);

        const owned_kind = self.allocator.dupe(u8, kind) catch return;
        errdefer self.allocator.free(owned_kind);
        const owned_event = ai.json_util.cloneJsonValue(self.allocator, event) catch return;
        errdefer ai.json_util.freeJsonValue(self.allocator, owned_event);
        self.events.append(self.allocator, .{ .kind = owned_kind, .event = owned_event }) catch return;
    }

    fn drainCallback(ctx: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.drain() catch {};
    }

    fn drain(self: *SpawnEventFanout) !void {
        var drained: std.ArrayList(PendingEvent) = .empty;
        self.mutex.lockUncancelable(std.Options.debug_io);
        std.mem.swap(std.ArrayList(PendingEvent), &drained, &self.events);
        self.mutex.unlock(std.Options.debug_io);
        defer freeEvents(self.allocator, &drained);

        for (drained.items) |entry| {
            if (self.lua) |lua| spawn_api.eventTrampoline(entry.kind, entry.event, @ptrCast(lua));
        }
    }

    fn deinit(self: *SpawnEventFanout) void {
        freeEvents(self.allocator, &self.events);
    }

    fn freeEvents(allocator: std.mem.Allocator, events: *std.ArrayList(PendingEvent)) void {
        for (events.items) |entry| {
            allocator.free(entry.kind);
            ai.json_util.freeJsonValue(allocator, entry.event);
        }
        events.deinit(allocator);
    }
};

fn spawnResultToToolResult(allocator: std.mem.Allocator, spawn_result: spawn_types.SpawnResult) !AgentToolResult {
    const text = spawn_result.text() orelse "";
    var result = try textResult(allocator, text, spawn_result.exit_code != 0);

    var out: std.json.ObjectMap = .{};
    errdefer {
        const v: std.json.Value = .{ .object = out };
        lua_runtime.freeJsonValue(allocator, v);
    }

    try out.put(allocator, try allocator.dupe(u8, "cancelled"), .{ .bool = spawn_result.cancelled });
    if (spawn_result.model) |m| try out.put(allocator, try allocator.dupe(u8, "model"), .{ .string = try allocator.dupe(u8, m) });
    if (spawn_result.stop_reason) |sr| try out.put(allocator, try allocator.dupe(u8, "stop_reason"), .{ .string = try allocator.dupe(u8, sr) });
    if (spawn_result.error_message) |em| try out.put(allocator, try allocator.dupe(u8, "error_message"), .{ .string = try allocator.dupe(u8, em) });

    var usage: std.json.ObjectMap = .{};
    try usage.put(allocator, try allocator.dupe(u8, "input"), .{ .integer = @intCast(spawn_result.usage.input) });
    try usage.put(allocator, try allocator.dupe(u8, "output"), .{ .integer = @intCast(spawn_result.usage.output) });
    try usage.put(allocator, try allocator.dupe(u8, "cache_read"), .{ .integer = @intCast(spawn_result.usage.cache_read) });
    try usage.put(allocator, try allocator.dupe(u8, "cache_write"), .{ .integer = @intCast(spawn_result.usage.cache_write) });
    try usage.put(allocator, try allocator.dupe(u8, "total_tokens"), .{ .integer = @intCast(spawn_result.usage.context_tokens) });
    try usage.put(allocator, try allocator.dupe(u8, "cost"), .{ .float = spawn_result.usage.cost });
    try usage.put(allocator, try allocator.dupe(u8, "turns"), .{ .integer = @intCast(spawn_result.usage.turns) });
    try out.put(allocator, try allocator.dupe(u8, "usage"), .{ .object = usage });

    result.details = .{ .object = out };
    return result;
}

fn parseReturn(
    allocator: std.mem.Allocator,
    L: *c.lua_State,
    idx: c_int,
    limits: ToolResultLimits,
) !AgentToolResult {
    const ty = c.lua_type(L, idx);

    if (ty == c.LUA_TSTRING) {
        return try boundedTextResult(allocator, lstring(L, idx), false, limits);
    }

    if (ty == c.LUA_TTABLE) {
        _ = c.lua_getfield(L, idx, "is_error");
        const is_error = c.lua_toboolean(L, -1) != 0;
        c.lua_pop(L, 1);

        var details: std.json.Value = .null;
        _ = c.lua_getfield(L, idx, "details");
        if (c.lua_type(L, -1) != c.LUA_TNIL) {
            var budget = lua_runtime.JsonConvertBudget{ .limits = limits.details };
            details = lua_runtime.luaValueToJsonLimited(L, -1, allocator, &budget) catch .null;
        }
        c.lua_pop(L, 1);

        var presentation: std.json.Value = .null;
        _ = c.lua_getfield(L, idx, "presentation");
        if (c.lua_type(L, -1) != c.LUA_TNIL) {
            presentation = lua_runtime.luaValueToPresentationJson(L, -1, allocator, limits.presentation) catch .null;
        }
        c.lua_pop(L, 1);

        _ = c.lua_getfield(L, idx, "content");
        defer c.lua_pop(L, 1);

        const content_ty = c.lua_type(L, -1);

        if (content_ty == c.LUA_TSTRING) {
            var result = try boundedTextResult(allocator, lstring(L, -1), is_error, limits);
            result.details = details;
            result.presentation = presentation;
            return result;
        }

        if (content_ty == c.LUA_TTABLE) {
            const blocks = try parseContentBlocks(allocator, L, -1, limits);
            return .{ .content = blocks, .is_error = is_error, .details = details, .presentation = presentation };
        }

        return .{ .content = &.{}, .is_error = is_error, .details = details, .presentation = presentation };
    }

    return emptyResult();
}

fn parseContentBlocks(
    allocator: std.mem.Allocator,
    L: *c.lua_State,
    idx: c_int,
    limits: ToolResultLimits,
) ![]const AgentToolResult.ContentBlock {
    const len = c.lua_rawlen(L, idx);
    if (len == 0 or limits.max_blocks == 0 or limits.max_text_bytes == 0) return &.{};

    var blocks: std.ArrayListUnmanaged(AgentToolResult.ContentBlock) = .empty;
    errdefer blocks.deinit(allocator);

    var budget = TextBudget{ .remaining = limits.max_text_bytes };
    var i: c.lua_Integer = 1;
    while (i <= @as(c.lua_Integer, @intCast(len))) : (i += 1) {
        if (blocks.items.len >= limits.max_blocks or budget.remaining == 0) break;

        _ = c.lua_rawgeti(L, idx, i);
        defer c.lua_pop(L, 1);

        if (c.lua_type(L, -1) != c.LUA_TTABLE) continue;

        _ = c.lua_getfield(L, -1, "text");
        defer c.lua_pop(L, 1);
        if (c.lua_type(L, -1) != c.LUA_TSTRING) continue;

        const text = try dupeTextWithBudget(allocator, lstring(L, -1), &budget);
        try blocks.append(allocator, .{ .text = .{ .text = text } });
    }
    return blocks.items;
}

fn textResult(
    allocator: std.mem.Allocator,
    text: []const u8,
    is_error: bool,
) !AgentToolResult {
    return boundedTextResult(allocator, text, is_error, .{
        .max_text_bytes = text.len,
        .max_blocks = 1,
        .details = default_json_convert_limits,
        .presentation = presentation_json_convert_limits,
    });
}

fn boundedTextResult(
    allocator: std.mem.Allocator,
    text: []const u8,
    is_error: bool,
    limits: ToolResultLimits,
) !AgentToolResult {
    if (limits.max_blocks == 0 or limits.max_text_bytes == 0) {
        return .{ .content = &.{}, .is_error = is_error };
    }
    var budget = TextBudget{ .remaining = limits.max_text_bytes };
    const dup = try dupeTextWithBudget(allocator, text, &budget);
    errdefer allocator.free(dup);
    const blocks = try allocator.alloc(AgentToolResult.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = dup } };
    return .{ .content = blocks, .is_error = is_error };
}

const TextBudget = struct { remaining: usize };

fn dupeTextWithBudget(
    allocator: std.mem.Allocator,
    text: []const u8,
    budget: *TextBudget,
) ![]const u8 {
    if (text.len <= budget.remaining) {
        budget.remaining -= text.len;
        return try allocator.dupe(u8, text);
    }

    const marker_len = @min(tool_result_truncated_marker.len, budget.remaining);
    const prefix_len = budget.remaining - marker_len;
    const out = try allocator.alloc(u8, budget.remaining);
    @memcpy(out[0..prefix_len], text[0..prefix_len]);
    @memcpy(out[prefix_len..], tool_result_truncated_marker[0..marker_len]);
    budget.remaining = 0;
    return out;
}

fn emptyResult() AgentToolResult {
    return .{ .content = &.{}, .is_error = false };
}

fn errorResult(allocator: std.mem.Allocator, message: []const u8) AgentToolResult {
    return textResult(allocator, message, true) catch .{
        .content = &.{},
        .is_error = true,
    };
}

fn lstring(L: *c.lua_State, idx: c_int) []const u8 {
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, idx, &len) orelse return &.{};
    return ptr[0..len];
}

fn luaToolUpdate(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const ud = c.lua_touserdata(L, c.lua_upvalueindex(1));
    const runner: *runner_mod.ExtensionRunner = @ptrCast(@alignCast(ud.?));

    const exec = runner.current_tool_execution orelse return 0;
    const cb = exec.on_update orelse return 0;

    if (c.lua_type(L, 1) != c.LUA_TTABLE) return 0;

    var arena = std.heap.ArenaAllocator.init(runner.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const partial = parseReturn(aa, L, 1, partial_tool_result_limits) catch emptyResult();

    cb(partial, exec.update_ctx);

    return 0;
}

const testing = std.testing;

fn parseLuaGlobalResult(
    allocator: std.mem.Allocator,
    source: []const u8,
    chunk_name: [:0]const u8,
    limits: ToolResultLimits,
) !AgentToolResult {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();

    try state.doString(source, chunk_name);
    _ = c.lua_getglobal(state.L, "result");
    defer c.lua_pop(state.L, 1);

    return parseReturn(allocator, state.L, -1, limits);
}

fn parsedTextBytes(result: AgentToolResult) usize {
    var total: usize = 0;
    for (result.content) |block| total += block.text.text.len;
    return total;
}

test "parseReturn enforces raw string text budget" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const result = try parseLuaGlobalResult(
        arena.allocator(),
        "result = string.rep('a', 70000)",
        "huge_raw_result",
        default_tool_result_limits,
    );

    try testing.expectEqual(@as(usize, 1), result.content.len);
    try testing.expectEqual(default_tool_result_limits.max_text_bytes, result.content[0].text.text.len);
    try testing.expect(std.mem.endsWith(u8, result.content[0].text.text, tool_result_truncated_marker));
}

test "parseReturn enforces content block count limit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const result = try parseLuaGlobalResult(arena.allocator(),
        \\result = { content = {} }
        \\for i = 1, 40 do
        \\  result.content[i] = { type = 'text', text = 'b' }
        \\end
    , "many_blocks_result", default_tool_result_limits);

    try testing.expectEqual(default_tool_result_limits.max_blocks, result.content.len);
}

test "parseReturn preserves presentation shape while bounding oversized strings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const result = try parseLuaGlobalResult(arena.allocator(),
        \\result = {
        \\  content = { { type = 'text', text = 'ok' } },
        \\  presentation = {
        \\    kind = 'tree',
        \\    summary = string.rep('a', 200 * 1024),
        \\  },
        \\}
    , "huge_presentation_result", default_tool_result_limits);

    try testing.expect(result.presentation == .object);
    const obj = result.presentation.object;
    try testing.expectEqualStrings("tree", obj.get("kind").?.string);
    try testing.expect(obj.get("summary").?.string.len <= default_tool_result_limits.presentation.max_string_bytes);
    try testing.expectEqual(true, obj.get("__zi_truncated").?.bool);
}

test "parseReturn enforces cumulative text budget across blocks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const result = try parseLuaGlobalResult(arena.allocator(),
        \\result = { content = {} }
        \\for i = 1, 40 do
        \\  result.content[i] = { type = 'text', text = string.rep('b', 4096) }
        \\end
    , "huge_blocks_result", default_tool_result_limits);

    try testing.expectEqual(default_tool_result_limits.max_text_bytes, parsedTextBytes(result));
}

fn testGetModel(_: *anyopaque) agent_protocol.Model {
    return .{
        .id = "test-model",
        .name = "Test Model",
        .api = .{ .custom = "test-api" },
        .provider = .{ .custom = "test-provider" },
        .base_url = "",
        .reasoning = false,
        .input = &.{.text},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 1024,
        .max_tokens = 1024,
    };
}

fn testModelJson(allocator: std.mem.Allocator, model: agent_protocol.Model) !std.json.Value {
    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, try allocator.dupe(u8, "id"), .{ .string = try allocator.dupe(u8, model.id) });
    try obj.put(allocator, try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, model.name) });
    try obj.put(allocator, try allocator.dupe(u8, "provider"), .{ .string = try allocator.dupe(u8, ai.json_util.providerToString(model.provider)) });
    try obj.put(allocator, try allocator.dupe(u8, "api"), .{ .string = try allocator.dupe(u8, ai.provider.apiToString(model.api)) });
    try obj.put(allocator, try allocator.dupe(u8, "context_window"), .{ .integer = @intCast(model.context_window) });
    try obj.put(allocator, try allocator.dupe(u8, "max_tokens"), .{ .integer = @intCast(model.max_tokens) });
    try obj.put(allocator, try allocator.dupe(u8, "reasoning"), .{ .bool = model.reasoning });
    return .{ .object = obj };
}

fn testModelsGet(_: *anyopaque, allocator: std.mem.Allocator) ?std.json.Value {
    var arr = std.json.Array.init(allocator);
    arr.append(testModelJson(allocator, testGetModel(undefined)) catch return null) catch return null;
    return .{ .array = arr };
}

fn testModelsGetOne(_: *anyopaque, allocator: std.mem.Allocator, model_ref: []const u8) ?std.json.Value {
    if (!std.mem.eql(u8, model_ref, "test-model") and !std.mem.eql(u8, model_ref, "test-provider/test-model")) return null;
    return testModelJson(allocator, testGetModel(undefined)) catch null;
}

fn testIsIdle(_: *anyopaque) bool {
    return true;
}

fn testAbort(_: *anyopaque) void {}

fn testHasPendingMessages(_: *anyopaque) bool {
    return false;
}

fn testGetContextUsage(_: *anyopaque) ?@import("../../session/root.zig").context_usage.ContextUsage {
    return .{ .tokens = 321, .context_window = 1024, .percent = 31.34765625 };
}

fn testGetSystemPrompt(_: *anyopaque) []const u8 {
    return "system";
}

fn testGetBindingInfo(_: *anyopaque) runner_mod.ExtensionBindingInfo {
    return .{
        .workspace_id = "/workspace",
        .session_id = "session-123",
        .session_file = "/workspace/.zi/sessions/session-123.jsonl",
    };
}

fn testProvenance() resource_types.ExtensionProvenance {
    return .{
        .runtime_root_id = "root-123",
        .extension_id = "ext-123",
        .state_owner_id = "state-123",
        .root_kind = .runtime_root,
    };
}

fn testLoadSource() runner_mod.ExtensionLoadSource {
    return .{
        .kind = "project",
        .id = "ext-123",
        .path = "/workspace/extensions/ext.lua",
        .provenance = testProvenance(),
    };
}

test "lua tool ctx exposes binding from tool provenance" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 7);
    defer runner.deinit();
    runner.attachLuaState(&state);
    var provider_registry = ai.provider.Registry.init(testing.allocator);
    defer provider_registry.deinit();

    var dummy: u8 = 0;
    try runner.bindRuntime(.{
        .session = @ptrCast(&dummy),
        .ui = null,
        .command_actions = null,
        .get_model = &testGetModel,
        .models_get = &testModelsGet,
        .models_get_one = &testModelsGetOne,
        .is_idle = &testIsIdle,
        .abort = &testAbort,
        .has_pending_messages = &testHasPendingMessages,
        .shutdown = null,
        .context_usage = &testGetContextUsage,
        .system_prompt = &testGetSystemPrompt,
        .get_binding_info = &testGetBindingInfo,
    }, &provider_registry);
    api_v3.install(&state, &runner);

    runner.beginLoadContext(testLoadSource());
    defer runner.endLoadContext();

    try state.doString(
        \\zi.tool({
        \\  name = "binding",
        \\  description = "binding",
        \\  parameters = { type = "object", properties = {} },
        \\  execute = function(args, ctx)
        \\    assert(ctx.binding ~= nil)
        \\    assert(ctx.editor == nil)
        \\    assert(ctx["st" .. "ate"] == nil)
        \\    assert(ctx["get_" .. "context_usage"] == nil)
        \\    assert(ctx["get_" .. "system_prompt"] == nil)
        \\    assert(type(ctx.context_usage) == "function")
        \\    assert(type(ctx.system_prompt) == "function")
        \\    return {
        \\      details = {
        \\        runtime_root_id = ctx.binding.runtime_root_id,
        \\        state_owner_id = ctx.binding.state_owner_id,
        \\        generation_id = ctx.binding.generation_id,
        \\        namespace_id = ctx.binding.namespace_id,
        \\        workspace_id = ctx.binding.workspace_id,
        \\        session_id = ctx.binding.session_id,
        \\        session_file = ctx.binding.session_file,
        \\      },
        \\    }
        \\  end,
        \\})
    , "tool_binding");

    const ext_tool = runner.tool_registry.get("binding").?.*;
    const tool = try buildAgentTool(testing.allocator, &runner, ext_tool);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const result = awaitToolExecutionForCompat(tool.start(
        arena.allocator(),
        "id-binding",
        .{ .null = {} },
        abort_signal_mod.cancel.Token.none,
        null,
        null,
    ), arena.allocator(), abort_signal_mod.cancel.Token.none);

    try testing.expect(!result.is_error);
    try testing.expect(result.details == .object);
    try testing.expectEqualStrings("root-123", result.details.object.get("runtime_root_id").?.string);
    try testing.expectEqualStrings("state-123", result.details.object.get("state_owner_id").?.string);
    try testing.expectEqual(@as(i64, 7), result.details.object.get("generation_id").?.integer);
    try testing.expectEqualStrings("state-123::7", result.details.object.get("namespace_id").?.string);
    try testing.expectEqualStrings("/workspace", result.details.object.get("workspace_id").?.string);
    try testing.expectEqualStrings("session-123", result.details.object.get("session_id").?.string);
    try testing.expectEqualStrings("/workspace/.zi/sessions/session-123.jsonl", result.details.object.get("session_file").?.string);
}

fn loadTodoFixture(state: *lua_runtime.LuaState, runner: *runner_mod.ExtensionRunner) !void {
    runner.beginLoadContext(testLoadSource());
    defer runner.endLoadContext();

    try state.doString(
        \\local todos = {}
        \\local next_id = 1
        \\
        \\local function clone_todos()
        \\  local out = {}
        \\  for i, todo in ipairs(todos) do
        \\    out[i] = { id = todo.id, text = todo.text, done = todo.done }
        \\  end
        \\  return out
        \\end
        \\
        \\local function list_text()
        \\  if #todos == 0 then return "No todos" end
        \\  local lines = {}
        \\  for i, todo in ipairs(todos) do
        \\    lines[i] = string.format("[%s] #%d: %s", todo.done and "x" or " ", todo.id, todo.text)
        \\  end
        \\  return table.concat(lines, "\n")
        \\end
        \\
        \\local function details(action, err)
        \\  return { action = action, todos = clone_todos(), nextId = next_id, error = err }
        \\end
        \\
        \\local function find_todo(id)
        \\  for _, todo in ipairs(todos) do
        \\    if todo.id == id then return todo end
        \\  end
        \\  return nil
        \\end
        \\
        \\zi.tool({
        \\  name = "todo",
        \\  label = "Todo",
        \\  description = "Manage a todo list",
        \\  parameters = {
        \\    type = "object",
        \\    properties = {
        \\      action = { type = "string", enum = { "list", "add", "toggle", "clear" } },
        \\      text = { type = "string" },
        \\      id = { type = "number" },
        \\    },
        \\    required = { "action" },
        \\  },
        \\  execute = function(params, ctx)
        \\    local action = params.action
        \\    if action == "list" then
        \\      return { content = { { type = "text", text = list_text() } }, details = details("list") }
        \\    end
        \\    if action == "add" then
        \\      local todo = { id = next_id, text = params.text, done = false }
        \\      next_id = next_id + 1
        \\      todos[#todos + 1] = todo
        \\      return { content = { { type = "text", text = string.format("Added todo #%d: %s", todo.id, todo.text) } }, details = details("add") }
        \\    end
        \\    if action == "toggle" then
        \\      local todo = find_todo(params.id)
        \\      todo.done = not todo.done
        \\      return { content = { { type = "text", text = string.format("Todo #%d %s", todo.id, todo.done and "completed" or "uncompleted") } }, details = details("toggle") }
        \\    end
        \\    return { content = { { type = "text", text = "Unknown action" } }, is_error = true, details = details("list", "unknown action") }
        \\  end,
        \\})
        \\
        \\zi.command({
        \\  name = "todos",
        \\  description = "Show todos",
        \\  handler = function(_, ctx)
        \\    ctx.ui.render({ id = "todos" })
        \\  end,
        \\})
    , "todo-fixture");
    try testing.expect(runner.tool_registry.get("todo") != null);
    try testing.expect(runner.command_registry.getByVisibleName("todos") != null);
}

fn todoArgs(allocator: std.mem.Allocator, action: []const u8, text: ?[]const u8, id: ?i64) !std.json.Value {
    var obj: std.json.ObjectMap = .{};
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "action", .{ .string = action });
    if (text) |value| try obj.put(allocator, "text", .{ .string = value });
    if (id) |value| try obj.put(allocator, "id", .{ .integer = value });
    return .{ .object = obj };
}

const TestLabelEntry = struct {
    target_entry_id: []const u8,
    label: ?[]const u8,
};

const TestStateStore = struct {
    allocator: std.mem.Allocator,
    editor_actions: std.ArrayListUnmanaged(extension_ui.EditorAction) = .empty,
    render_specs: std.ArrayListUnmanaged(extension_ui.RenderSpec) = .empty,
    session_name: ?[]const u8 = null,
    note_kind: ?[]const u8 = null,
    note_title: ?[]const u8 = null,
    note_body: ?[]const u8 = null,
    note_source_entry_id: ?[]const u8 = null,
    artifact_owner_id: ?[]const u8 = null,
    artifact_kind: ?[]const u8 = null,
    artifact_key: ?[]const u8 = null,
    artifact_title: ?[]const u8 = null,
    artifact_data: ?std.json.Value = null,
    label_target_entry_id: ?[]const u8 = null,
    label_value: ?[]const u8 = null,
    label_history: std.ArrayListUnmanaged(TestLabelEntry) = .empty,
    cancel_count: usize = 0,
    revoke_count: usize = 0,
    render_count: usize = 0,
    frame_count: usize = 0,

    fn deinit(self: *TestStateStore) void {
        self.clearEditorActions();
        self.clearRenderSpecs();
        if (self.session_name) |name| self.allocator.free(name);
        self.session_name = null;
        if (self.note_kind) |value| self.allocator.free(value);
        if (self.note_title) |value| self.allocator.free(value);
        if (self.note_body) |value| self.allocator.free(value);
        if (self.note_source_entry_id) |value| self.allocator.free(value);
        if (self.artifact_owner_id) |value| self.allocator.free(value);
        if (self.artifact_kind) |value| self.allocator.free(value);
        if (self.artifact_key) |value| self.allocator.free(value);
        if (self.artifact_title) |value| self.allocator.free(value);
        if (self.artifact_data) |value| ai.json_util.freeJsonValue(self.allocator, value);
        if (self.label_target_entry_id) |value| self.allocator.free(value);
        if (self.label_value) |value| self.allocator.free(value);
        for (self.label_history.items) |label_item| {
            self.allocator.free(label_item.target_entry_id);
            if (label_item.label) |value| self.allocator.free(value);
        }
        self.label_history.deinit(self.allocator);
        self.note_kind = null;
        self.note_title = null;
        self.note_body = null;
        self.note_source_entry_id = null;
        self.artifact_owner_id = null;
        self.artifact_kind = null;
        self.artifact_key = null;
        self.artifact_title = null;
        self.artifact_data = null;
        self.label_target_entry_id = null;
        self.label_value = null;
    }

    fn sessionInfo(session: *anyopaque, allocator: std.mem.Allocator) ?std.json.Value {
        var obj: std.json.ObjectMap = .{};
        obj.put(allocator, allocator.dupe(u8, "id") catch return null, .{ .string = allocator.dupe(u8, "session-test") catch return null }) catch return null;
        obj.put(allocator, allocator.dupe(u8, "cwd") catch return null, .{ .string = allocator.dupe(u8, "/tmp/project") catch return null }) catch return null;
        obj.put(allocator, allocator.dupe(u8, "file") catch return null, .null) catch return null;
        const self: *TestStateStore = @ptrCast(@alignCast(session));
        obj.put(allocator, allocator.dupe(u8, "name") catch return null, if (self.session_name) |name| .{ .string = allocator.dupe(u8, name) catch return null } else .null) catch return null;
        return .{ .object = obj };
    }

    fn sessionName(session: *anyopaque, allocator: std.mem.Allocator) ?[]const u8 {
        const self: *TestStateStore = @ptrCast(@alignCast(session));
        return if (self.session_name) |name| allocator.dupe(u8, name) catch null else null;
    }

    fn setSessionName(session: *anyopaque, name: ?[]const u8) !void {
        const self: *TestStateStore = @ptrCast(@alignCast(session));
        if (self.session_name) |old| self.allocator.free(old);
        self.session_name = if (name) |value| try self.allocator.dupe(u8, value) else null;
    }

    fn sessionToolResults(session: *anyopaque, allocator: std.mem.Allocator, tool_name: []const u8) ?std.json.Value {
        _ = session;
        var arr = std.json.Array.init(allocator);
        if (std.mem.eql(u8, tool_name, "todo")) {
            var details: std.json.ObjectMap = .{};
            details.put(allocator, allocator.dupe(u8, "nextId") catch return null, .{ .integer = 2 }) catch return null;
            var obj: std.json.ObjectMap = .{};
            obj.put(allocator, allocator.dupe(u8, "entry_id") catch return null, .{ .string = allocator.dupe(u8, "entry-1") catch return null }) catch return null;
            obj.put(allocator, allocator.dupe(u8, "tool_call_id") catch return null, .{ .string = allocator.dupe(u8, "call-1") catch return null }) catch return null;
            obj.put(allocator, allocator.dupe(u8, "tool_name") catch return null, .{ .string = allocator.dupe(u8, "todo") catch return null }) catch return null;
            obj.put(allocator, allocator.dupe(u8, "details") catch return null, .{ .object = details }) catch return null;
            obj.put(allocator, allocator.dupe(u8, "is_error") catch return null, .{ .bool = false }) catch return null;
            arr.append(.{ .object = obj }) catch return null;
        }
        return .{ .array = arr };
    }

    fn appendNote(session: *anyopaque, kind: []const u8, title: ?[]const u8, body: []const u8, source_entry_id: ?[]const u8) !void {
        const self: *TestStateStore = @ptrCast(@alignCast(session));
        if (self.note_kind) |value| self.allocator.free(value);
        if (self.note_title) |value| self.allocator.free(value);
        if (self.note_body) |value| self.allocator.free(value);
        if (self.note_source_entry_id) |value| self.allocator.free(value);
        self.note_kind = try self.allocator.dupe(u8, kind);
        self.note_title = if (title) |value| try self.allocator.dupe(u8, value) else null;
        self.note_body = try self.allocator.dupe(u8, body);
        self.note_source_entry_id = if (source_entry_id) |value| try self.allocator.dupe(u8, value) else null;
    }

    fn notes(session: *anyopaque, allocator: std.mem.Allocator, kind: ?[]const u8, source_entry_id: ?[]const u8, limit: usize) ?std.json.Value {
        const self: *TestStateStore = @ptrCast(@alignCast(session));
        _ = limit;
        var arr = std.json.Array.init(allocator);
        const note_kind = self.note_kind orelse return .{ .array = arr };
        if (kind) |wanted| if (!std.mem.eql(u8, wanted, note_kind)) return .{ .array = arr };
        if (source_entry_id) |wanted| {
            const source = self.note_source_entry_id orelse return .{ .array = arr };
            if (!std.mem.eql(u8, wanted, source)) return .{ .array = arr };
        }
        var obj: std.json.ObjectMap = .{};
        obj.put(allocator, allocator.dupe(u8, "kind") catch return null, .{ .string = allocator.dupe(u8, note_kind) catch return null }) catch return null;
        if (self.note_title) |title| obj.put(allocator, allocator.dupe(u8, "title") catch return null, .{ .string = allocator.dupe(u8, title) catch return null }) catch return null;
        if (self.note_source_entry_id) |source| obj.put(allocator, allocator.dupe(u8, "source_entry_id") catch return null, .{ .string = allocator.dupe(u8, source) catch return null }) catch return null;
        obj.put(allocator, allocator.dupe(u8, "body") catch return null, .{ .string = allocator.dupe(u8, self.note_body orelse "") catch return null }) catch return null;
        arr.append(.{ .object = obj }) catch return null;
        return .{ .array = arr };
    }

    fn appendArtifact(session: *anyopaque, owner_id: []const u8, kind: []const u8, key: ?[]const u8, title: ?[]const u8, data: std.json.Value) !void {
        const self: *TestStateStore = @ptrCast(@alignCast(session));
        if (self.artifact_owner_id) |value| self.allocator.free(value);
        if (self.artifact_kind) |value| self.allocator.free(value);
        if (self.artifact_key) |value| self.allocator.free(value);
        if (self.artifact_title) |value| self.allocator.free(value);
        if (self.artifact_data) |value| ai.json_util.freeJsonValue(self.allocator, value);
        self.artifact_owner_id = try self.allocator.dupe(u8, owner_id);
        self.artifact_kind = try self.allocator.dupe(u8, kind);
        self.artifact_key = if (key) |value| try self.allocator.dupe(u8, value) else null;
        self.artifact_title = if (title) |value| try self.allocator.dupe(u8, value) else null;
        self.artifact_data = try ai.json_util.cloneJsonValue(self.allocator, data);
    }

    fn artifacts(session: *anyopaque, allocator: std.mem.Allocator, owner_id: []const u8, kind: ?[]const u8, key: ?[]const u8, limit: usize) ?std.json.Value {
        const self: *TestStateStore = @ptrCast(@alignCast(session));
        _ = limit;
        var arr = std.json.Array.init(allocator);
        const artifact_owner = self.artifact_owner_id orelse return .{ .array = arr };
        if (!std.mem.eql(u8, owner_id, artifact_owner)) return .{ .array = arr };
        const artifact_kind = self.artifact_kind orelse return .{ .array = arr };
        if (kind) |wanted| if (!std.mem.eql(u8, wanted, artifact_kind)) return .{ .array = arr };
        if (key) |wanted| {
            const artifact_key = self.artifact_key orelse return .{ .array = arr };
            if (!std.mem.eql(u8, wanted, artifact_key)) return .{ .array = arr };
        }
        var obj: std.json.ObjectMap = .{};
        obj.put(allocator, allocator.dupe(u8, "entry_id") catch return null, .{ .string = allocator.dupe(u8, "artifact-1") catch return null }) catch return null;
        obj.put(allocator, allocator.dupe(u8, "owner_id") catch return null, .{ .string = allocator.dupe(u8, artifact_owner) catch return null }) catch return null;
        obj.put(allocator, allocator.dupe(u8, "kind") catch return null, .{ .string = allocator.dupe(u8, artifact_kind) catch return null }) catch return null;
        if (self.artifact_key) |value| obj.put(allocator, allocator.dupe(u8, "key") catch return null, .{ .string = allocator.dupe(u8, value) catch return null }) catch return null;
        if (self.artifact_title) |value| obj.put(allocator, allocator.dupe(u8, "title") catch return null, .{ .string = allocator.dupe(u8, value) catch return null }) catch return null;
        obj.put(allocator, allocator.dupe(u8, "data") catch return null, if (self.artifact_data) |value| ai.json_util.cloneJsonValue(allocator, value) catch return null else .null) catch return null;
        arr.append(.{ .object = obj }) catch return null;
        return .{ .array = arr };
    }

    fn setLabel(session: *anyopaque, target_entry_id: []const u8, label: ?[]const u8) !void {
        const self: *TestStateStore = @ptrCast(@alignCast(session));
        if (self.label_target_entry_id) |value| self.allocator.free(value);
        if (self.label_value) |value| self.allocator.free(value);
        self.label_target_entry_id = try self.allocator.dupe(u8, target_entry_id);
        self.label_value = if (label) |value| try self.allocator.dupe(u8, value) else null;
        try self.label_history.append(self.allocator, .{
            .target_entry_id = try self.allocator.dupe(u8, target_entry_id),
            .label = if (label) |value| try self.allocator.dupe(u8, value) else null,
        });
    }

    fn entry(session: *anyopaque, allocator: std.mem.Allocator, entry_id: []const u8) ?std.json.Value {
        const self: *TestStateStore = @ptrCast(@alignCast(session));
        if (std.mem.eql(u8, entry_id, "message-1")) {
            var obj: std.json.ObjectMap = .{};
            obj.put(allocator, allocator.dupe(u8, "entry_id") catch return null, .{ .string = allocator.dupe(u8, "message-1") catch return null }) catch return null;
            obj.put(allocator, allocator.dupe(u8, "type") catch return null, .{ .string = allocator.dupe(u8, "message") catch return null }) catch return null;
            obj.put(allocator, allocator.dupe(u8, "role") catch return null, .{ .string = allocator.dupe(u8, "user") catch return null }) catch return null;
            obj.put(allocator, allocator.dupe(u8, "text") catch return null, .{ .string = allocator.dupe(u8, "hello") catch return null }) catch return null;
            return .{ .object = obj };
        }
        if (std.mem.eql(u8, entry_id, "note-1")) {
            const note_kind = self.note_kind orelse return null;
            var obj: std.json.ObjectMap = .{};
            obj.put(allocator, allocator.dupe(u8, "entry_id") catch return null, .{ .string = allocator.dupe(u8, "note-1") catch return null }) catch return null;
            obj.put(allocator, allocator.dupe(u8, "type") catch return null, .{ .string = allocator.dupe(u8, "extension_note") catch return null }) catch return null;
            obj.put(allocator, allocator.dupe(u8, "kind") catch return null, .{ .string = allocator.dupe(u8, note_kind) catch return null }) catch return null;
            obj.put(allocator, allocator.dupe(u8, "body") catch return null, .{ .string = allocator.dupe(u8, self.note_body orelse "") catch return null }) catch return null;
            if (self.note_source_entry_id) |source| obj.put(allocator, allocator.dupe(u8, "source_entry_id") catch return null, .{ .string = allocator.dupe(u8, source) catch return null }) catch return null;
            return .{ .object = obj };
        }
        if (std.mem.eql(u8, entry_id, "label-1")) {
            const target = self.label_target_entry_id orelse return null;
            var obj: std.json.ObjectMap = .{};
            obj.put(allocator, allocator.dupe(u8, "entry_id") catch return null, .{ .string = allocator.dupe(u8, "label-1") catch return null }) catch return null;
            obj.put(allocator, allocator.dupe(u8, "type") catch return null, .{ .string = allocator.dupe(u8, "label") catch return null }) catch return null;
            obj.put(allocator, allocator.dupe(u8, "target_entry_id") catch return null, .{ .string = allocator.dupe(u8, target) catch return null }) catch return null;
            obj.put(allocator, allocator.dupe(u8, "label") catch return null, if (self.label_value) |value| .{ .string = allocator.dupe(u8, value) catch return null } else .null) catch return null;
            return .{ .object = obj };
        }
        return null;
    }

    fn latestLabel(self: *TestStateStore, target_entry_id: []const u8) ?[]const u8 {
        var i = self.label_history.items.len;
        while (i > 0) {
            i -= 1;
            const label_item = self.label_history.items[i];
            if (std.mem.eql(u8, label_item.target_entry_id, target_entry_id)) return label_item.label;
        }
        return null;
    }

    fn appendLabeledTestEntry(allocator: std.mem.Allocator, arr: *std.json.Array, self: *TestStateStore, target_entry_id: []const u8, wanted_label: []const u8, text: []const u8) !void {
        const current = self.latestLabel(target_entry_id) orelse return;
        if (!std.mem.eql(u8, current, wanted_label)) return;
        var obj: std.json.ObjectMap = .{};
        try obj.put(allocator, try allocator.dupe(u8, "entry_id"), .{ .string = try allocator.dupe(u8, target_entry_id) });
        try obj.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "message") });
        try obj.put(allocator, try allocator.dupe(u8, "role"), .{ .string = try allocator.dupe(u8, "user") });
        try obj.put(allocator, try allocator.dupe(u8, "text"), .{ .string = try allocator.dupe(u8, text) });
        try arr.append(.{ .object = obj });
    }

    fn entries(session: *anyopaque, allocator: std.mem.Allocator, label: ?[]const u8, limit: usize) ?std.json.Value {
        const self: *TestStateStore = @ptrCast(@alignCast(session));
        _ = limit;
        var arr = std.json.Array.init(allocator);
        const wanted = label orelse return .{ .array = arr };
        appendLabeledTestEntry(allocator, &arr, self, "entry-a", wanted, "first decision") catch return null;
        appendLabeledTestEntry(allocator, &arr, self, "entry-b", wanted, "kept decision") catch return null;
        appendLabeledTestEntry(allocator, &arr, self, "entry-2", wanted, "important entry") catch return null;
        return .{ .array = arr };
    }

    fn labels(session: *anyopaque, allocator: std.mem.Allocator, target_entry_id: ?[]const u8, limit: usize) ?std.json.Value {
        const self: *TestStateStore = @ptrCast(@alignCast(session));
        _ = limit;
        var arr = std.json.Array.init(allocator);
        const target = self.label_target_entry_id orelse return .{ .array = arr };
        if (target_entry_id) |wanted| if (!std.mem.eql(u8, wanted, target)) return .{ .array = arr };
        var obj: std.json.ObjectMap = .{};
        obj.put(allocator, allocator.dupe(u8, "entry_id") catch return null, .{ .string = allocator.dupe(u8, "label-1") catch return null }) catch return null;
        obj.put(allocator, allocator.dupe(u8, "target_entry_id") catch return null, .{ .string = allocator.dupe(u8, target) catch return null }) catch return null;
        obj.put(allocator, allocator.dupe(u8, "label") catch return null, if (self.label_value) |value| .{ .string = allocator.dupe(u8, value) catch return null } else .null) catch return null;
        arr.append(.{ .object = obj }) catch return null;
        return .{ .array = arr };
    }

    fn sessionMessages(session: *anyopaque, allocator: std.mem.Allocator, limit: usize, include_tools: bool) ?std.json.Value {
        _ = session;
        _ = include_tools;
        var arr = std.json.Array.init(allocator);
        if (limit != 1) {
            var first: std.json.ObjectMap = .{};
            first.put(allocator, allocator.dupe(u8, "entry_id") catch return null, .{ .string = allocator.dupe(u8, "entry-1") catch return null }) catch return null;
            first.put(allocator, allocator.dupe(u8, "role") catch return null, .{ .string = allocator.dupe(u8, "user") catch return null }) catch return null;
            first.put(allocator, allocator.dupe(u8, "text") catch return null, .{ .string = allocator.dupe(u8, "hello") catch return null }) catch return null;
            arr.append(.{ .object = first }) catch return null;
        }
        var second: std.json.ObjectMap = .{};
        second.put(allocator, allocator.dupe(u8, "entry_id") catch return null, .{ .string = allocator.dupe(u8, "entry-2") catch return null }) catch return null;
        second.put(allocator, allocator.dupe(u8, "role") catch return null, .{ .string = allocator.dupe(u8, "assistant") catch return null }) catch return null;
        second.put(allocator, allocator.dupe(u8, "text") catch return null, .{ .string = allocator.dupe(u8, "hi") catch return null }) catch return null;
        arr.append(.{ .object = second }) catch return null;
        return .{ .array = arr };
    }

    fn sessionContext(session: *anyopaque, allocator: std.mem.Allocator, max_messages: usize, include_tools: bool) ?std.json.Value {
        _ = session;
        var obj: std.json.ObjectMap = .{};
        obj.put(allocator, allocator.dupe(u8, "system_prompt") catch return null, .{ .string = allocator.dupe(u8, "test system") catch return null }) catch return null;
        var messages = std.json.Array.init(allocator);
        if (max_messages != 1) {
            var user_obj: std.json.ObjectMap = .{};
            user_obj.put(allocator, allocator.dupe(u8, "role") catch return null, .{ .string = allocator.dupe(u8, "user") catch return null }) catch return null;
            user_obj.put(allocator, allocator.dupe(u8, "content") catch return null, .{ .string = allocator.dupe(u8, "hello") catch return null }) catch return null;
            messages.append(.{ .object = user_obj }) catch return null;
        }
        var assistant_obj: std.json.ObjectMap = .{};
        assistant_obj.put(allocator, allocator.dupe(u8, "role") catch return null, .{ .string = allocator.dupe(u8, "assistant") catch return null }) catch return null;
        var content = std.json.Array.init(allocator);
        var text_obj: std.json.ObjectMap = .{};
        text_obj.put(allocator, allocator.dupe(u8, "type") catch return null, .{ .string = allocator.dupe(u8, "text") catch return null }) catch return null;
        text_obj.put(allocator, allocator.dupe(u8, "text") catch return null, .{ .string = allocator.dupe(u8, "hi") catch return null }) catch return null;
        content.append(.{ .object = text_obj }) catch return null;
        if (include_tools) {
            var call_obj: std.json.ObjectMap = .{};
            call_obj.put(allocator, allocator.dupe(u8, "type") catch return null, .{ .string = allocator.dupe(u8, "tool_call") catch return null }) catch return null;
            call_obj.put(allocator, allocator.dupe(u8, "name") catch return null, .{ .string = allocator.dupe(u8, "todo") catch return null }) catch return null;
            content.append(.{ .object = call_obj }) catch return null;
        }
        assistant_obj.put(allocator, allocator.dupe(u8, "content") catch return null, .{ .array = content }) catch return null;
        messages.append(.{ .object = assistant_obj }) catch return null;
        obj.put(allocator, allocator.dupe(u8, "messages") catch return null, .{ .array = messages }) catch return null;
        if (include_tools) {
            var tools = std.json.Array.init(allocator);
            var tool: std.json.ObjectMap = .{};
            tool.put(allocator, allocator.dupe(u8, "name") catch return null, .{ .string = allocator.dupe(u8, "todo") catch return null }) catch return null;
            tools.append(.{ .object = tool }) catch return null;
            obj.put(allocator, allocator.dupe(u8, "tools") catch return null, .{ .array = tools }) catch return null;
        }
        return .{ .object = obj };
    }

    fn publishRender(session: *anyopaque, spec: extension_ui.RenderSpec) !void {
        const self: *TestStateStore = @ptrCast(@alignCast(session));
        var cloned = try extension_ui.RenderSpec.clone(self.allocator, spec);
        errdefer cloned.deinit(self.allocator);
        try self.render_specs.append(self.allocator, cloned);
        self.render_count += 1;
    }

    fn publishFrame(session: *anyopaque, spec: extension_ui.FrameSpec) !void {
        const self: *TestStateStore = @ptrCast(@alignCast(session));
        _ = spec;
        self.frame_count += 1;
    }

    fn publishEditorAction(session: *anyopaque, action: extension_ui.EditorAction) !void {
        const self: *TestStateStore = @ptrCast(@alignCast(session));
        var cloned = try extension_ui.EditorAction.clone(self.allocator, action);
        errdefer cloned.deinit(self.allocator);
        try self.editor_actions.append(self.allocator, cloned);
    }

    fn clearEditorActionsCallback(session: *anyopaque) void {
        const self: *TestStateStore = @ptrCast(@alignCast(session));
        self.clearEditorActions();
    }

    fn clearEditorActions(self: *TestStateStore) void {
        for (self.editor_actions.items) |*action| action.deinit(self.allocator);
        self.editor_actions.deinit(self.allocator);
        self.editor_actions = .empty;
    }

    fn clearRenderSpecs(self: *TestStateStore) void {
        for (self.render_specs.items) |*spec| spec.deinit(self.allocator);
        self.render_specs.deinit(self.allocator);
        self.render_specs = .empty;
    }
};

fn bindRuntimeFields(store: *TestStateStore) runner_mod.ExtensionRuntime.Bound {
    return .{
        .session = @ptrCast(store),
        .ui = null,
        .command_actions = null,
        .get_model = &testGetModel,
        .models_get = &testModelsGet,
        .models_get_one = &testModelsGetOne,
        .is_idle = &testIsIdle,
        .abort = &testAbort,
        .has_pending_messages = &testHasPendingMessages,
        .shutdown = null,
        .context_usage = &testGetContextUsage,
        .system_prompt = &testGetSystemPrompt,
        .get_binding_info = &testGetBindingInfo,
        .session_info_get = &TestStateStore.sessionInfo,
        .session_name_get = &TestStateStore.sessionName,
        .session_name_set = &TestStateStore.setSessionName,
        .session_tool_results_get = &TestStateStore.sessionToolResults,
        .session_messages_get = &TestStateStore.sessionMessages,
        .session_context_get = &TestStateStore.sessionContext,
        .session_note_append = &TestStateStore.appendNote,
        .session_notes_get = &TestStateStore.notes,
        .session_artifact_append = &TestStateStore.appendArtifact,
        .session_artifacts_get = &TestStateStore.artifacts,
        .session_label_set = &TestStateStore.setLabel,
        .session_labels_get = &TestStateStore.labels,
        .session_entry_get = &TestStateStore.entry,
        .session_entries_get = &TestStateStore.entries,
        .publish_render = &TestStateStore.publishRender,
        .publish_frame = &TestStateStore.publishFrame,
        .publish_editor_action = &TestStateStore.publishEditorAction,
        .clear_editor_actions = &TestStateStore.clearEditorActionsCallback,
    };
}

fn bindTestRuntime(runner: *runner_mod.ExtensionRunner, store: *TestStateStore, provider_registry: *ai.provider.Registry) !void {
    try runner.bindRuntime(bindRuntimeFields(store), provider_registry);
}

fn bindResolvingRuntime(runner: *runner_mod.ExtensionRunner, store: *TestStateStore, provider_registry: *ai.provider.Registry) !void {
    var bound = bindRuntimeFields(store);
    bound.resolve_prompt = &TestStateStore.resolvePrompt;
    try runner.bindRuntime(bound, provider_registry);
}

test "extension command context exposes read-only session ui_publication" {
    var store = TestStateStore{ .allocator = testing.allocator };
    defer store.deinit();

    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();
    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 20);
    defer runner.deinit();
    runner.attachLuaState(&state);
    runner.bindLuaOwnerThread(std.Thread.getCurrentId());
    var provider_registry = ai.provider.Registry.init(testing.allocator);
    defer provider_registry.deinit();
    try bindTestRuntime(&runner, &store, &provider_registry);
    api_v3.install(&state, &runner);

    runner.beginLoadContext(testLoadSource());
    defer runner.endLoadContext();
    try state.doString(
        \\zi.command({
        \\  name = "session-ui_publication",
        \\  description = "session-ui_publication",
        \\  handler = function(_, ctx)
        \\    local info = ctx.session.info()
        \\    assert(info.id == "session-test")
        \\    assert(info.cwd == "/tmp/project")
        \\    assert(ctx.session.name() == nil)
        \\    assert(ctx.session.rename("demo") == true)
        \\    assert(ctx.session.name() == "demo")
        \\    assert(ctx.session.info().name == "demo")
        \\    assert(ctx.session.rename("") == true)
        \\    assert(ctx.session.name() == nil)
        \\    local results = ctx.session.tool_results("todo")
        \\    assert(#results == 1)
        \\    assert(results[1].tool_name == "todo")
        \\    assert(results[1].details.nextId == 2)
        \\    local messages = ctx.session.messages({ limit = 1 })
        \\    assert(#messages == 1)
        \\    assert(messages[1].role == "assistant")
        \\    assert(messages[1].text == "hi")
        \\    assert(ctx.session.append_note({ kind = "manual", title = "Note", body = "remember", source_entry_id = "entry-2" }) == true)
        \\    local notes = ctx.session.notes({ kind = "manual", source_entry_id = "entry-2" })
        \\    assert(#notes == 1)
        \\    assert(notes[1].title == "Note")
        \\    assert(notes[1].body == "remember")
        \\    assert(notes[1].source_entry_id == "entry-2")
        \\    assert(#ctx.session.notes({ source_entry_id = "missing" }) == 0)
        \\    assert(ctx.session.append_artifact({ kind = "todo_state", key = "main", title = "Todo state", data = { next_id = 3, items = { "a", "b" } } }) == true)
        \\    local artifacts = ctx.session.artifacts({ kind = "todo_state", key = "main" })
        \\    assert(#artifacts == 1)
        \\    assert(artifacts[1].entry_id == "artifact-1")
        \\    assert(artifacts[1].owner_id == "state-123")
        \\    assert(artifacts[1].kind == "todo_state")
        \\    assert(artifacts[1].key == "main")
        \\    assert(artifacts[1].title == "Todo state")
        \\    assert(artifacts[1].data.next_id == 3)
        \\    assert(artifacts[1].data.items[2] == "b")
        \\    assert(#ctx.session.artifacts({ key = "missing" }) == 0)
        \\    assert(ctx.session.label("entry-2", "important") == true)
        \\    local labels = ctx.session.labels({ target_entry_id = "entry-2" })
        \\    assert(#labels == 1)
        \\    assert(labels[1].entry_id == "label-1")
        \\    assert(labels[1].target_entry_id == "entry-2")
        \\    assert(labels[1].label == "important")
        \\    assert(#ctx.session.labels({ target_entry_id = "missing" }) == 0)
        \\    local message_entry = ctx.session.entry("message-1")
        \\    assert(message_entry.type == "message")
        \\    assert(message_entry.role == "user")
        \\    assert(message_entry.text == "hello")
        \\    local note_entry = ctx.session.entry("note-1")
        \\    assert(note_entry.type == "extension_note")
        \\    assert(note_entry.kind == "manual")
        \\    assert(note_entry.source_entry_id == "entry-2")
        \\    local label_entry = ctx.session.entry("label-1")
        \\    assert(label_entry.type == "label")
        \\    assert(label_entry.target_entry_id == "entry-2")
        \\    assert(label_entry.label == "important")
        \\    assert(ctx.session.entry("missing") == nil)
        \\    assert(ctx.session.label("entry-a", "decision") == true)
        \\    assert(ctx.session.label("entry-b", "decision") == true)
        \\    assert(ctx.session.label("entry-a", "") == true)
        \\    local decision_entries = ctx.session.entries({ label = "decision" })
        \\    assert(#decision_entries == 1)
        \\    assert(decision_entries[1].entry_id == "entry-b")
        \\    assert(decision_entries[1].text == "kept decision")
        \\    assert(#ctx.session.entries({ label = "missing" }) == 0)
        \\    assert(ctx.session.label("entry-2", "") == true)
        \\    labels = ctx.session.labels({ target_entry_id = "entry-2" })
        \\    assert(#labels == 1)
        \\    assert(labels[1].label == nil)
        \\  end,
        \\})
    , "register_session_ui_publication_command");

    try runner.dispatchCommand("session-ui_publication", "");
}

test "extension command context exposes model catalog and lookup" {
    var store = TestStateStore{ .allocator = testing.allocator };
    defer store.deinit();

    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();
    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 21);
    defer runner.deinit();
    runner.attachLuaState(&state);
    runner.bindLuaOwnerThread(std.Thread.getCurrentId());
    var provider_registry = ai.provider.Registry.init(testing.allocator);
    defer provider_registry.deinit();
    try bindTestRuntime(&runner, &store, &provider_registry);
    api_v3.install(&state, &runner);

    runner.beginLoadContext(testLoadSource());
    defer runner.endLoadContext();
    try state.doString(
        \\zi.command({
        \\  name = "model-ui_publication",
        \\  description = "model-ui_publication",
        \\  handler = function(_, ctx)
        \\    assert(ctx.model == nil)
        \\    assert(ctx.models.current().id == "test-model")
        \\    assert(ctx.models.current().max_tokens == 1024)
        \\    local models = ctx.models.list()
        \\    assert(#models == 1)
        \\    assert(models[1].provider == "test-provider")
        \\    assert(ctx.models.get("test-model").id == "test-model")
        \\    assert(ctx.models.get("test-provider/test-model").api == "test-api")
        \\    assert(ctx.models.get("missing") == nil)
        \\  end,
        \\})
    , "register_model_ui_publication_command");

    try runner.dispatchCommand("model-ui_publication", "");
}

test "extension command context publishes host-owned editor buffer actions" {
    var store = TestStateStore{ .allocator = testing.allocator };
    defer store.deinit();

    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();
    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 15);
    defer runner.deinit();
    runner.attachLuaState(&state);
    runner.bindLuaOwnerThread(std.Thread.getCurrentId());
    var provider_registry = ai.provider.Registry.init(testing.allocator);
    defer provider_registry.deinit();
    try bindTestRuntime(&runner, &store, &provider_registry);
    api_v3.install(&state, &runner);

    runner.beginLoadContext(testLoadSource());
    defer runner.endLoadContext();
    try state.doString(
        \\zi.command({
        \\  name = "editor-actions",
        \\  description = "editor-actions",
        \\  handler = function(_, ctx)
        \\    assert(ctx["st" .. "ate"] == nil)
        \\    assert(ctx["get_" .. "context_usage"] == nil)
        \\    assert(ctx["get_" .. "system_prompt"] == nil)
        \\    assert(type(ctx.context_usage) == "function")
        \\    assert(type(ctx.system_prompt) == "function")
        \\    assert(ctx.ui["set_" .. "editor_text"] == nil)
        \\    assert(ctx.ui["paste_" .. "to_editor"] == nil)
        \\    assert(ctx.ui["clear_" .. "editor_text"] == nil)
        \\    assert(ctx.ui["get_" .. "editor_text"] == nil)
        \\    assert(ctx.editor ~= nil)
        \\    local seen = {}
        \\    for k, v in pairs(ctx.editor) do
        \\      assert(type(v) == "function")
        \\      seen[k] = true
        \\    end
        \\    assert(seen.set_text and seen.insert_text and seen.clear)
        \\    assert(not seen.get_text)
        \\    local count = 0
        \\    for _ in pairs(seen) do count = count + 1 end
        \\    assert(count == 3)
        \\    ctx.editor.set_text("hello")
        \\    ctx.editor.insert_text(" world")
        \\    ctx.editor.clear()
        \\  end,
        \\})
    , "register_editor_action_command");

    try runner.dispatchCommand("editor-actions", "");

    try testing.expectEqual(@as(usize, 3), store.editor_actions.items.len);
    try testing.expectEqual(extension_ui.EditorActionKind.set_text, store.editor_actions.items[0].kind);
    try testing.expectEqualStrings("hello", store.editor_actions.items[0].text.?);
    try testing.expectEqual(extension_ui.EditorActionKind.paste_text, store.editor_actions.items[1].kind);
    try testing.expectEqualStrings(" world", store.editor_actions.items[1].text.?);
    try testing.expectEqual(extension_ui.EditorActionKind.clear_text, store.editor_actions.items[2].kind);

    runner.unbindRuntime();
    try testing.expectEqual(@as(usize, 0), store.editor_actions.items.len);
}

test "ctx.ui v3 exposes render frame and notifications" {
    var store = TestStateStore{ .allocator = testing.allocator };
    defer store.deinit();

    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();
    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 14);
    defer runner.deinit();
    runner.attachLuaState(&state);
    runner.bindLuaOwnerThread(std.Thread.getCurrentId());
    var provider_registry = ai.provider.Registry.init(testing.allocator);
    defer provider_registry.deinit();
    try bindTestRuntime(&runner, &store, &provider_registry);
    api_v3.install(&state, &runner);

    runner.beginLoadContext(testLoadSource());
    defer runner.endLoadContext();
    try state.doString(
        \\zi.command({
        \\  name = "ui-v3-perimeter",
        \\  description = "ui-v3-perimeter",
        \\  handler = function(_, ctx)
        \\    assert(ctx.has_ui == true)
        \\    assert(ctx.ui ~= nil)
        \\    local seen = {}
        \\    local count = 0
        \\    for k, v in pairs(ctx.ui) do
        \\      seen[k] = true
        \\      count = count + 1
        \\      assert(type(v) == "function")
        \\    end
        \\    assert(count == 5)
        \\    assert(seen.render and seen.frame and seen.notify and seen.notify_clear and seen.progress)
        \\    ctx.ui.render({ id = "demo" })
        \\    ctx.ui.frame({ id = "demo" })
        \\    ctx.ui.notify("demo", { id = "notify" })
        \\    ctx.ui.render("not-a-table")
        \\    ctx.ui.frame(nil)
        \\  end,
        \\})
    , "register_ui_v3_perimeter_command");

    try runner.dispatchCommand("ui-v3-perimeter", "");
    try testing.expectEqual(@as(usize, 2), store.render_count);
    try testing.expectEqual(@as(usize, 1), store.frame_count);
}

test "extension command resumes after zi.system result" {
    var store = TestStateStore{ .allocator = testing.allocator };
    defer store.deinit();

    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();
    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 29);
    defer runner.deinit();
    runner.attachLuaState(&state);
    runner.bindLuaOwnerThread(std.Thread.getCurrentId());
    var provider_registry = ai.provider.Registry.init(testing.allocator);
    defer provider_registry.deinit();
    try bindTestRuntime(&runner, &store, &provider_registry);

    const Capture = struct {
        argv0: ?[]u8 = null,
        cwd: ?[]u8 = null,
        stdin: ?[]u8 = null,
        env_value: ?[]u8 = null,
        timeout_ms: ?u64 = null,
        stdio: runner_mod.SystemStdio = .capture,

        fn submit(ptr: *anyopaque, _: *runner_mod.ExtensionRunner, start: runner_mod.AsyncStart) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            var owned = start;
            defer owned.deinit(testing.allocator);
            switch (owned.request) {
                .system => |request| {
                    self.argv0 = try testing.allocator.dupe(u8, request.argv[0]);
                    if (request.cwd) |cwd| self.cwd = try testing.allocator.dupe(u8, cwd);
                    if (request.stdin) |stdin| self.stdin = try testing.allocator.dupe(u8, stdin);
                    for (request.env) |pair| if (std.mem.eql(u8, pair.key, "FOO")) {
                        self.env_value = try testing.allocator.dupe(u8, pair.value);
                    };
                    self.timeout_ms = request.timeout_ms;
                    self.stdio = request.stdio;
                },
                else => {},
            }
        }
    };
    var capture = Capture{};
    defer {
        if (capture.argv0) |value| testing.allocator.free(value);
        if (capture.cwd) |value| testing.allocator.free(value);
        if (capture.stdin) |value| testing.allocator.free(value);
        if (capture.env_value) |value| testing.allocator.free(value);
    }
    runner.async_dispatcher = .{ .ptr = @ptrCast(&capture), .submit = &Capture.submit };
    api_v3.install(&state, &runner);

    runner.beginLoadContext(testLoadSource());
    defer runner.endLoadContext();
    try state.doString(
        \\zi.command({
        \\  name = "system-test",
        \\  description = "system-test",
        \\  handler = function(_, ctx)
        \\    local result = zi.system({ "/bin/sh", "-c", "cat" }, { cwd = ctx.cwd, stdin = "hello", env = { FOO = "bar" }, timeout_ms = 1234, stdio = "capture" })
        \\    _system_result = result.status .. ":" .. result.code .. ":" .. result.stdout .. ":" .. result.stderr
        \\  end,
        \\})
    , "register_system_test_command");

    try runner.dispatchCommand("system-test", "");
    try testing.expectEqual(@as(usize, 1), runner.pending_async.count());
    const pending = runner.pending_async.get(1) orelse return error.MissingAsyncRequest;
    try testing.expectEqual(runner_mod.AsyncKind.system, pending.kind);
    try testing.expectEqualStrings("/bin/sh", capture.argv0 orelse return error.MissingArgv);
    try testing.expectEqualStrings(".", capture.cwd orelse return error.MissingCwd);
    try testing.expectEqualStrings("hello", capture.stdin orelse return error.MissingStdin);
    try testing.expectEqualStrings("bar", capture.env_value orelse return error.MissingEnv);
    try testing.expectEqual(@as(?u64, 1234), capture.timeout_ms);
    try testing.expectEqual(runner_mod.SystemStdio.capture, capture.stdio);
    try runner.resumeAsync(1, .{ .system = .{ .completed = .{
        .code = 7,
        .stdout = try testing.allocator.dupe(u8, "out"),
        .stderr = try testing.allocator.dupe(u8, "err"),
    } } });
    try testing.expectEqual(@as(usize, 0), runner.pending_async.count());

    _ = c.lua_getglobal(state.L, "_system_result");
    defer c.lua_pop(state.L, 1);
    var len: usize = 0;
    const ptr = c.lua_tolstring(state.L, -1, &len) orelse return error.MissingSystemResult;
    try testing.expectEqualStrings("completed:7:out:err", ptr[0..len]);
}

test "extension job API starts writes and stops through dispatcher" {
    var store = TestStateStore{ .allocator = testing.allocator };
    defer store.deinit();

    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();
    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 41);
    defer runner.deinit();
    runner.attachLuaState(&state);
    runner.bindLuaOwnerThread(std.Thread.getCurrentId());
    var provider_registry = ai.provider.Registry.init(testing.allocator);
    defer provider_registry.deinit();
    try bindTestRuntime(&runner, &store, &provider_registry);

    const Capture = struct {
        started_id: ?u64 = null,
        argv0: ?[]u8 = null,
        cwd: ?[]u8 = null,
        wrote_id: ?u64 = null,
        wrote_data: ?[]u8 = null,
        stopped_id: ?u64 = null,
        stdout_surface: ?[]u8 = null,

        fn submit(_: *anyopaque, _: *runner_mod.ExtensionRunner, async_start: runner_mod.AsyncStart) !void {
            var owned = async_start;
            defer owned.deinit(testing.allocator);
        }
        fn start(ptr: *anyopaque, _: *runner_mod.ExtensionRunner, id: u64, request: runner_mod.JobStartRequest) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            var owned = request;
            defer owned.deinit(testing.allocator);
            self.started_id = id;
            self.argv0 = try testing.allocator.dupe(u8, request.argv[0]);
            if (request.cwd) |cwd| self.cwd = try testing.allocator.dupe(u8, cwd);
            switch (request.stdout) {
                .events => {},
                .ui_frame => |frame| self.stdout_surface = try testing.allocator.dupe(u8, frame.node),
                .json_lines => {},
            }
        }
        fn write(ptr: *anyopaque, _: *runner_mod.ExtensionRunner, id: u64, data: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.wrote_id = id;
            self.wrote_data = try testing.allocator.dupe(u8, data);
        }
        fn stop(ptr: *anyopaque, _: *runner_mod.ExtensionRunner, id: u64) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.stopped_id = id;
        }
    };
    var capture = Capture{};
    defer {
        if (capture.argv0) |value| testing.allocator.free(value);
        if (capture.cwd) |value| testing.allocator.free(value);
        if (capture.wrote_data) |value| testing.allocator.free(value);
        if (capture.stdout_surface) |value| testing.allocator.free(value);
    }
    runner.async_dispatcher = .{
        .ptr = @ptrCast(&capture),
        .submit = &Capture.submit,
        .job_start = &Capture.start,
        .job_write = &Capture.write,
        .job_stop = &Capture.stop,
    };
    api_v3.install(&state, &runner);

    runner.beginLoadContext(testLoadSource());
    try state.doString(
        \\zi.command({
        \\  name = "job-api",
        \\  handler = function(_, ctx)
        \\    local job = zi.job.start({ argv = { "/bin/cat" }, cwd = ctx.cwd, stdout = { mode = "ui_frame", view = "doom-workbench", node = "doom-demo", protocol = "zi-rgba-frame-v1" } })
        \\    zi.job.write(job, "KEY left\n")
        \\    zi.job.stop(job.id)
        \\  end,
        \\})
    , "register_job_api_command");
    runner.endLoadContext();

    try runner.dispatchCommand("job-api", "");
    try testing.expectEqual(@as(?u64, 1), capture.started_id);
    try testing.expectEqualStrings("/bin/cat", capture.argv0 orelse return error.MissingJobArgv);
    try testing.expectEqualStrings(".", capture.cwd orelse return error.MissingJobCwd);
    try testing.expectEqualStrings("doom-demo", capture.stdout_surface orelse return error.MissingJobStdoutSurface);
    try testing.expectEqual(@as(?u64, 1), capture.wrote_id);
    try testing.expectEqualStrings("KEY left\n", capture.wrote_data orelse return error.MissingJobWrite);
    try testing.expectEqual(@as(?u64, 1), capture.stopped_id);
}

test "extension job events dispatch to lua observers" {
    var store = TestStateStore{ .allocator = testing.allocator };
    defer store.deinit();

    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();
    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 42);
    defer runner.deinit();
    runner.attachLuaState(&state);
    runner.bindLuaOwnerThread(std.Thread.getCurrentId());
    var provider_registry = ai.provider.Registry.init(testing.allocator);
    defer provider_registry.deinit();
    try bindTestRuntime(&runner, &store, &provider_registry);
    api_v3.install(&state, &runner);

    runner.beginLoadContext(testLoadSource());
    defer runner.endLoadContext();
    try state.doString(
        \\job_seen = ""
        \\zi.on("job_stdout", function(event) job_seen = job_seen .. event.id .. ":" .. event.data end)
        \\zi.on("job_exit", function(event) job_seen = job_seen .. ":exit=" .. event.code end)
    , "register_job_event_handlers");

    try runner.dispatchJobEvent(.{ .id = 7, .kind = .stdout, .data = "hello" });
    try runner.dispatchJobEvent(.{ .id = 7, .kind = .exit, .code = 0 });

    _ = c.lua_getglobal(state.L, "job_seen");
    defer c.lua_pop(state.L, 1);
    var len: usize = 0;
    const ptr = c.lua_tolstring(state.L, -1, &len) orelse return error.MissingJobSeen;
    try testing.expectEqualStrings("7:hello:exit=0", ptr[0..len]);
}

test "extension job next drains tool scoped process events without interactive dispatcher" {
    var store = TestStateStore{ .allocator = testing.allocator };
    defer store.deinit();

    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();
    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 43);
    defer runner.deinit();
    runner.attachLuaState(&state);
    runner.bindLuaOwnerThread(std.Thread.getCurrentId());
    var provider_registry = ai.provider.Registry.init(testing.allocator);
    defer provider_registry.deinit();
    try bindTestRuntime(&runner, &store, &provider_registry);
    api_v3.install(&state, &runner);

    runner.beginLoadContext(testLoadSource());
    try state.doString(
        \\job_out = ""
        \\zi.command({
        \\  name = "job-next",
        \\  handler = function(_, ctx)
        \\    local job = zi.job.start({ argv = { "/bin/sh", "-c", "printf out; printf err >&2" }, cwd = ctx.cwd })
        \\    while true do
        \\      local ev = zi.job.next(job, { timeout_ms = 100 })
        \\      if ev then
        \\        job_out = job_out .. ev.type .. ":" .. tostring(ev.data or ev.code or "") .. "|"
        \\        if ev.type == "exit" then break end
        \\      end
        \\    end
        \\  end,
        \\})
    , "register_job_next_command");
    runner.endLoadContext();

    try runner.dispatchCommand("job-next", "");

    _ = c.lua_getglobal(state.L, "job_out");
    defer c.lua_pop(state.L, 1);
    var len: usize = 0;
    const ptr = c.lua_tolstring(state.L, -1, &len) orelse return error.MissingJobOut;
    const out = ptr[0..len];
    try testing.expect(std.mem.indexOf(u8, out, "stdout:out|") != null);
    try testing.expect(std.mem.indexOf(u8, out, "stderr:err|") != null);
    try testing.expect(std.mem.indexOf(u8, out, "exit:0|") != null);
}

test "extension ui events dispatch to lua observers" {
    var store = TestStateStore{ .allocator = testing.allocator };
    defer store.deinit();

    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();
    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 42);
    defer runner.deinit();
    runner.attachLuaState(&state);
    runner.bindLuaOwnerThread(std.Thread.getCurrentId());
    var provider_registry = ai.provider.Registry.init(testing.allocator);
    defer provider_registry.deinit();
    try bindTestRuntime(&runner, &store, &provider_registry);
    api_v3.install(&state, &runner);

    runner.beginLoadContext(testLoadSource());
    defer runner.endLoadContext();
    try state.doString(
        \\ui_seen = ""
        \\zi.on("ui", function(event) ui_seen = event.type .. ":" .. event.view .. ":" .. event.key .. ":" .. event.action .. ":" .. tostring(event.ctrl) end)
    , "register_ui_event_handler");

    try runner.dispatchUiEvent(.{ .state_owner_id = "owner", .generation = 7, .view = "demo", .type = .key, .action = "close", .key = "escape", .ctrl = true });

    _ = c.lua_getglobal(state.L, "ui_seen");
    defer c.lua_pop(state.L, 1);
    var len: usize = 0;
    const ptr = c.lua_tolstring(state.L, -1, &len) orelse return error.MissingUiSeen;
    try testing.expectEqualStrings("key:demo:escape:close:true", ptr[0..len]);
}

test "extension command resumes after ai completion result" {
    var store = TestStateStore{ .allocator = testing.allocator };
    defer store.deinit();

    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();
    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 20);
    defer runner.deinit();
    runner.attachLuaState(&state);
    runner.bindLuaOwnerThread(std.Thread.getCurrentId());
    var provider_registry = ai.provider.Registry.init(testing.allocator);
    defer provider_registry.deinit();
    try bindTestRuntime(&runner, &store, &provider_registry);
    const Capture = struct {
        model: ?[]u8 = null,
        reasoning: ?agent_protocol.ThinkingLevel = null,

        fn submit(ptr: *anyopaque, _: *runner_mod.ExtensionRunner, start: runner_mod.AsyncStart) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            var owned = start;
            defer owned.deinit(testing.allocator);
            switch (owned.request) {
                .ai_complete => |request| {
                    if (request.model) |model| self.model = try testing.allocator.dupe(u8, model);
                    self.reasoning = request.reasoning;
                },
                else => {},
            }
        }
    };
    var capture = Capture{};
    defer if (capture.model) |model| testing.allocator.free(model);
    runner.async_dispatcher = .{ .ptr = @ptrCast(&capture), .submit = &Capture.submit };
    api_v3.install(&state, &runner);

    runner.beginLoadContext(testLoadSource());
    defer runner.endLoadContext();
    try state.doString(
        \\zi.command({
        \\  name = "ai-complete-test",
        \\  description = "ai-complete-test",
        \\  handler = function(_, ctx)
        \\    local result = ctx.ai.complete({ model = ctx.models.current(), reasoning = "low", prompt = "hello", system_prompt = "system", max_tokens = 12 })
        \\    _ai_complete_result = result.status .. ":" .. result.text
        \\  end,
        \\})
    , "register_ai_complete_test_command");

    try runner.dispatchCommand("ai-complete-test", "");
    try testing.expectEqual(@as(usize, 1), runner.pending_async.count());
    const pending = runner.pending_async.get(1) orelse return error.MissingAsyncRequest;
    try testing.expectEqual(runner_mod.AsyncKind.ai_complete, pending.kind);
    try testing.expectEqualStrings("test-provider/test-model", capture.model orelse return error.MissingModelOverride);
    try testing.expectEqual(agent_protocol.ThinkingLevel.low, capture.reasoning orelse return error.MissingReasoningOverride);
    try runner.resumeAsync(1, .{ .ai_complete = try runner_mod.AiCompleteResult.completedText(testing.allocator, "world") });
    try testing.expectEqual(@as(usize, 0), runner.pending_async.count());

    _ = c.lua_getglobal(state.L, "_ai_complete_result");
    defer c.lua_pop(state.L, 1);
    var len: usize = 0;
    const ptr = c.lua_tolstring(state.L, -1, &len) orelse return error.MissingAsyncResult;
    try testing.expectEqualStrings("completed:world", ptr[0..len]);
}

test "extension command resumes after yieldable host result" {
    var store = TestStateStore{ .allocator = testing.allocator };
    defer store.deinit();

    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();
    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 20);
    defer runner.deinit();
    runner.enable_test_async = true;
    runner.attachLuaState(&state);
    runner.bindLuaOwnerThread(std.Thread.getCurrentId());
    var provider_registry = ai.provider.Registry.init(testing.allocator);
    defer provider_registry.deinit();
    try bindTestRuntime(&runner, &store, &provider_registry);
    api_v3.install(&state, &runner);

    runner.beginLoadContext(testLoadSource());
    defer runner.endLoadContext();
    try state.doString(
        \\zi.command({
        \\  name = "async-test",
        \\  description = "async-test",
        \\  handler = function(_, ctx)
        \\    local first = ctx.__test_async()
        \\    local second = ctx.__test_async()
        \\    _async_result = first .. ":" .. second
        \\  end,
        \\})
    , "register_async_test_command");

    try runner.dispatchCommand("async-test", "");
    try testing.expectEqual(@as(usize, 1), runner.pending_async.count());
    try runner.completeTestAsync(1, "one");
    try testing.expectEqual(@as(usize, 1), runner.pending_async.count());
    try runner.completeTestAsync(2, "two");
    try testing.expectEqual(@as(usize, 0), runner.pending_async.count());

    _ = c.lua_getglobal(state.L, "_async_result");
    defer c.lua_pop(state.L, 1);
    var len: usize = 0;
    const ptr = c.lua_tolstring(state.L, -1, &len) orelse return error.MissingAsyncResult;
    try testing.expectEqualStrings("one:two", ptr[0..len]);
}

test "extension command rejects arbitrary coroutine yield" {
    var store = TestStateStore{ .allocator = testing.allocator };
    defer store.deinit();

    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();
    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 20);
    defer runner.deinit();
    runner.attachLuaState(&state);
    runner.bindLuaOwnerThread(std.Thread.getCurrentId());
    var provider_registry = ai.provider.Registry.init(testing.allocator);
    defer provider_registry.deinit();
    try bindTestRuntime(&runner, &store, &provider_registry);
    api_v3.install(&state, &runner);

    runner.beginLoadContext(testLoadSource());
    defer runner.endLoadContext();
    try state.doString(
        \\zi.command({
        \\  name = "bad-yield",
        \\  description = "bad-yield",
        \\  handler = function() coroutine.yield() end,
        \\})
    , "register_bad_yield_command");

    try testing.expectError(error.UnexpectedYield, runner.dispatchCommand("bad-yield", ""));
}

test "ctx.ui.notify publishes notification render" {
    var store = TestStateStore{ .allocator = testing.allocator };
    defer store.deinit();

    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();
    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 1);
    defer runner.deinit();
    runner.attachLuaState(&state);
    runner.bindLuaOwnerThread(std.Thread.getCurrentId());
    var provider_registry = ai.provider.Registry.init(testing.allocator);
    defer provider_registry.deinit();
    try bindTestRuntime(&runner, &store, &provider_registry);
    api_v3.install(&state, &runner);

    runner.beginLoadContext(testLoadSource());
    defer runner.endLoadContext();
    try state.doString(
        \\zi.command({
        \\  name = "ui-notify",
        \\  description = "ui-notify",
        \\  handler = function(_, ctx)
        \\    ctx.ui.notify("Ready for input", { id = "agent-ready", group = "agent", level = "success", annote = "until input" })
        \\  end,
        \\})
    , "ui_notify");

    try runner.dispatchCommand("ui-notify", "");
    try testing.expectEqual(@as(usize, 1), store.render_specs.items.len);
    try testing.expectEqual(extension_ui.UiSlot.notification, store.render_specs.items[0].slot);
    try testing.expectEqualStrings("agent-ready", store.render_specs.items[0].id);
    try testing.expect(store.render_specs.items[0].notification != null);
    try testing.expectEqualStrings("Ready for input", store.render_specs.items[0].notification.?.message);
    try testing.expectEqual(@as(?u32, 5000), store.render_specs.items[0].notification.?.ttlMs());
}

test "todo command can call ctx.ui.render perimeter" {
    var store = TestStateStore{ .allocator = testing.allocator };
    defer store.deinit();

    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();
    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 12);
    defer runner.deinit();
    runner.attachLuaState(&state);
    runner.bindLuaOwnerThread(std.Thread.getCurrentId());
    var provider_registry = ai.provider.Registry.init(testing.allocator);
    defer provider_registry.deinit();
    try bindTestRuntime(&runner, &store, &provider_registry);
    api_v3.install(&state, &runner);
    try loadTodoFixture(&state, &runner);

    const ext_tool = runner.tool_registry.get("todo").?.*;
    const tool = try buildAgentTool(testing.allocator, &runner, ext_tool);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const add_args = try todoArgs(arena.allocator(), "add", "ship perimeter", null);
    const add_result = awaitToolExecutionForCompat(tool.start(arena.allocator(), "todo-1", add_args, abort_signal_mod.cancel.Token.none, null, null), arena.allocator(), abort_signal_mod.cancel.Token.none);
    try testing.expect(!add_result.is_error);

    try runner.dispatchCommand("todos", "");
    try testing.expectEqual(@as(usize, 1), store.render_count);
}

test "todo fixture keeps ephemeral Lua locals within one extension generation" {
    var store = TestStateStore{ .allocator = testing.allocator };
    defer store.deinit();

    {
        var state = try lua_runtime.LuaState.init(testing.allocator);
        defer state.deinit();
        var runner = runner_mod.ExtensionRunner.init(testing.allocator, 1);
        defer runner.deinit();
        runner.attachLuaState(&state);
        runner.bindLuaOwnerThread(std.Thread.getCurrentId());
        var provider_registry = ai.provider.Registry.init(testing.allocator);
        defer provider_registry.deinit();
        try bindTestRuntime(&runner, &store, &provider_registry);
        api_v3.install(&state, &runner);
        try loadTodoFixture(&state, &runner);

        const ext_tool = runner.tool_registry.get("todo").?.*;
        const tool = try buildAgentTool(testing.allocator, &runner, ext_tool);
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const add_args = try todoArgs(arena.allocator(), "add", "persist me", null);
        const add_result = awaitToolExecutionForCompat(tool.start(arena.allocator(), "todo-1", add_args, abort_signal_mod.cancel.Token.none, null, null), arena.allocator(), abort_signal_mod.cancel.Token.none);
        try testing.expect(!add_result.is_error);
    }

    {
        var state = try lua_runtime.LuaState.init(testing.allocator);
        defer state.deinit();
        var runner = runner_mod.ExtensionRunner.init(testing.allocator, 2);
        defer runner.deinit();
        runner.attachLuaState(&state);
        runner.bindLuaOwnerThread(std.Thread.getCurrentId());
        var provider_registry = ai.provider.Registry.init(testing.allocator);
        defer provider_registry.deinit();
        try bindTestRuntime(&runner, &store, &provider_registry);
        api_v3.install(&state, &runner);
        try loadTodoFixture(&state, &runner);

        const ext_tool = runner.tool_registry.get("todo").?.*;
        const tool = try buildAgentTool(testing.allocator, &runner, ext_tool);
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const list_args = try todoArgs(arena.allocator(), "list", null, null);
        const list_result = awaitToolExecutionForCompat(tool.start(arena.allocator(), "todo-2", list_args, abort_signal_mod.cancel.Token.none, null, null), arena.allocator(), abort_signal_mod.cancel.Token.none);
        try testing.expect(!list_result.is_error);
        try testing.expectEqualStrings("No todos", list_result.content[0].text.text);
    }
}

test "lua tool execution maps Lua return shapes and runtime errors to AgentToolResult" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();
    runner.attachLuaState(&state);
    api_v3.install(&state, &runner);

    try state.doString(
        \\zi.tool({
        \\  name = "echo",
        \\  description = "echo",
        \\  parameters = { type = "object", properties = {} },
        \\  execute = function(args) return "hello " .. (args.who or "world") end,
        \\})
        \\zi.tool({
        \\  name = "system_echo",
        \\  description = "system echo",
        \\  parameters = { type = "object", properties = {} },
        \\  execute = function(args)
        \\    local a = zi.system({ "/bin/sh", "-c", "printf tool" })
        \\    local b = zi.system({ "/bin/sh", "-c", "printf -- -system" })
        \\    return a.stdout .. b.stdout
        \\  end,
        \\})
        \\zi.tool({
        \\  name = "fail",
        \\  description = "always fails",
        \\  parameters = { type = "object", properties = {} },
        \\  execute = function(args) return { content = { { type = "text", text = "boom" } }, is_error = true } end,
        \\})
        \\zi.tool({
        \\  name = "explode",
        \\  description = "raises",
        \\  parameters = { type = "object", properties = {} },
        \\  execute = function(args) error("kaboom") end,
        \\})
    , "register_result_shape_tools");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var args_obj: std.json.ObjectMap = .{};
    defer args_obj.deinit(testing.allocator);
    try args_obj.put(testing.allocator, "who", .{ .string = "zi" });

    const echo_tool = try buildAgentTool(testing.allocator, &runner, runner.tool_registry.get("echo").?.*);
    const echo_execution = echo_tool.start(arena.allocator(), "id-ready", .{ .object = args_obj }, abort_signal_mod.cancel.Token.none, null, null);
    switch (echo_execution) {
        .ready => |echo_ready| {
            try testing.expect(!echo_ready.is_error);
            try testing.expectEqualStrings("hello zi", echo_ready.content[0].text.text);
        },
        .pending => return error.ExpectedReadyLuaToolExecution,
    }
    const echo = awaitToolExecutionForCompat(echo_tool.start(arena.allocator(), "id-1", .{ .object = args_obj }, abort_signal_mod.cancel.Token.none, null, null), arena.allocator(), abort_signal_mod.cancel.Token.none);
    try testing.expect(!echo.is_error);
    try testing.expectEqualStrings("hello zi", echo.content[0].text.text);

    const system_tool = try buildAgentTool(testing.allocator, &runner, runner.tool_registry.get("system_echo").?.*);
    const system_execution = system_tool.start(arena.allocator(), "id-system-pending", .{ .null = {} }, abort_signal_mod.cancel.Token.none, null, null);
    const system_ready = switch (system_execution) {
        .ready => return error.ExpectedPendingLuaToolExecution,
        .pending => |pending| blk: {
            defer pending.free(arena.allocator());
            break :blk pending.await(arena.allocator(), abort_signal_mod.cancel.Token.none, null, null);
        },
    };
    try testing.expect(!system_ready.is_error);
    try testing.expectEqualStrings("tool-system", system_ready.content[0].text.text);
    const system_echo = awaitToolExecutionForCompat(system_tool.start(arena.allocator(), "id-system", .{ .null = {} }, abort_signal_mod.cancel.Token.none, null, null), arena.allocator(), abort_signal_mod.cancel.Token.none);
    try testing.expect(!system_echo.is_error);
    try testing.expectEqualStrings("tool-system", system_echo.content[0].text.text);

    const fail_tool = try buildAgentTool(testing.allocator, &runner, runner.tool_registry.get("fail").?.*);
    const fail = awaitToolExecutionForCompat(fail_tool.start(arena.allocator(), "id-2", .{ .null = {} }, abort_signal_mod.cancel.Token.none, null, null), arena.allocator(), abort_signal_mod.cancel.Token.none);
    try testing.expect(fail.is_error);
    try testing.expectEqualStrings("boom", fail.content[0].text.text);

    const explode_tool = try buildAgentTool(testing.allocator, &runner, runner.tool_registry.get("explode").?.*);
    const explode = awaitToolExecutionForCompat(explode_tool.start(arena.allocator(), "id-3", .{ .null = {} }, abort_signal_mod.cancel.Token.none, null, null), arena.allocator(), abort_signal_mod.cancel.Token.none);
    try testing.expect(explode.is_error);
    try testing.expect(explode.content.len >= 1);
}

test "lua tool cpu loop aborts through debug hook" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();
    runner.attachLuaState(&state);
    api_v3.install(&state, &runner);

    try state.doString(
        \\zi.tool({
        \\  name = "spin",
        \\  description = "spin",
        \\  parameters = { type = "object", properties = {} },
        \\  execute = function(args) while true do end end,
        \\})
    , "register_spin_tool");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var args_obj: std.json.ObjectMap = .{};
    defer args_obj.deinit(testing.allocator);
    const spin_tool = try buildAgentTool(testing.allocator, &runner, runner.tool_registry.get("spin").?.*);

    var controller = abort_signal_mod.cancel.Source{};
    const signal = controller.beginRun();
    const Aborter = struct {
        fn run(ctrl: *abort_signal_mod.cancel.Source) void {
            std.Options.debug_io.sleep(.fromMilliseconds(50), .awake) catch {};
            ctrl.requestAbort();
        }
    };
    const thread = try std.Thread.spawn(.{}, Aborter.run, .{&controller});
    defer thread.join();
    const start = std.Io.Clock.awake.now(std.Options.debug_io).toMilliseconds();
    const result = awaitToolExecutionForCompat(spin_tool.start(arena.allocator(), "id-spin", .{ .object = args_obj }, signal, null, null), arena.allocator(), signal);
    const elapsed = std.Io.Clock.awake.now(std.Options.debug_io).toMilliseconds() - start;
    try testing.expect(result.is_error);
    try testing.expect(elapsed < 1000);
}
