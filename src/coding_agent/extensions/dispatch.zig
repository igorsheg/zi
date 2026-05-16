const std = @import("std");
const lua_runtime = @import("lua_runtime.zig");
const runner_mod = @import("runner.zig");
const context_mod = @import("context.zig");
const agent_protocol = @import("../../agent/types.zig");
const session_core = @import("../../session/root.zig");
const resource_types = @import("../resources/types.zig");
const event_registry = @import("registries/event_registry.zig");
const ai = @import("../../ai/root.zig");

const c = lua_runtime.c;
const log = std.log.scoped(.zi_dispatch);

pub const DispatchError = error{
    UnexpectedYield,
    HandlerError,
    OutOfMemory,
    InvalidCoroutineState,
    LuaRuntime,
    LuaSyntax,
    LuaMemory,
    LuaError,
    UnsupportedLuaType,
    InvalidUtf8,
    LimitExceeded,
};

pub const CancelResult = struct {
    blocked: bool,
    reason: ?[]const u8 = null,

    pub fn deinit(self: *CancelResult, allocator: std.mem.Allocator) void {
        if (self.reason) |r| allocator.free(r);
        self.* = undefined;
    }
};

pub fn dispatchObserver(
    state: *lua_runtime.LuaState,
    runner: *runner_mod.ExtensionRunner,
    kind: event_registry.EventKind,
    payload_idx: c_int,
) DispatchError!void {
    const handlers = runner.event_registry.handlers(kind);
    for (handlers) |h| {
        runOneHandler(state, runner, h, payload_idx) catch |err| {
            log.warn("observer handler for {s} failed: {s}", .{ @tagName(kind), @errorName(err) });
            continue;
        };
    }
}

pub fn dispatchCancellable(
    state: *lua_runtime.LuaState,
    runner: *runner_mod.ExtensionRunner,
    kind: event_registry.EventKind,
    payload_idx: c_int,
    allocator: std.mem.Allocator,
) DispatchError!CancelResult {
    const handlers = runner.event_registry.handlers(kind);
    for (handlers) |h| {
        var co = try lua_runtime.Coroutine.init(state);
        defer co.deinit();

        try pushHandlerAndContext(state, runner, &co, h.lua_ref, h.provenance, payload_idx);

        const r = try co.resumeWith(2);
        switch (r.status) {
            .yielded => return error.UnexpectedYield,
            .ok, .finished => {},
        }

        if (r.nresults == 0) continue;

        const top = c.lua_gettop(co.L);
        defer c.lua_settop(co.L, top - r.nresults);

        const top_idx = top;
        if (c.lua_type(co.L, top_idx) == c.LUA_TNIL) continue;
        if (c.lua_type(co.L, top_idx) != c.LUA_TTABLE) continue;

        _ = c.lua_getfield(co.L, top_idx, "block");
        const blocked = c.lua_toboolean(co.L, -1) != 0;
        c.lua_pop(co.L, 1);

        if (!blocked) continue;

        var reason: ?[]const u8 = null;
        _ = c.lua_getfield(co.L, top_idx, "reason");
        if (c.lua_type(co.L, -1) == c.LUA_TSTRING) {
            var len: usize = 0;
            const ptr = c.lua_tolstring(co.L, -1, &len) orelse return error.InvalidUtf8;
            reason = try allocator.dupe(u8, ptr[0..len]);
        }
        c.lua_pop(co.L, 1);

        return .{ .blocked = true, .reason = reason };
    }
    return .{ .blocked = false };
}

pub fn dispatchTransformable(
    state: *lua_runtime.LuaState,
    runner: *runner_mod.ExtensionRunner,
    kind: event_registry.EventKind,
    payload_idx: c_int,
    allocator: std.mem.Allocator,
) DispatchError!std.json.Value {
    const handlers = runner.event_registry.handlers(kind);

    const abs_payload: c_int = if (payload_idx < 0)
        c.lua_gettop(state.L) + payload_idx + 1
    else
        payload_idx;

    for (handlers) |h| {
        var co = try lua_runtime.Coroutine.init(state);
        defer co.deinit();

        try pushHandlerAndContext(state, runner, &co, h.lua_ref, h.provenance, abs_payload);

        const r = try co.resumeWith(2);
        switch (r.status) {
            .yielded => return error.UnexpectedYield,
            .ok, .finished => {},
        }

        if (r.nresults == 0) continue;

        const top_idx = c.lua_gettop(co.L);
        if (c.lua_type(co.L, top_idx) == c.LUA_TNIL) {
            c.lua_settop(co.L, top_idx - r.nresults);
            continue;
        }

        if (r.nresults > 1) c.lua_pop(co.L, r.nresults - 1);
        c.lua_xmove(co.L, state.L, 1);
        c.lua_replace(state.L, abs_payload);
    }

    var budget = lua_runtime.JsonConvertBudget{ .limits = lua_runtime.default_json_convert_limits };
    return lua_runtime.luaValueToJsonLimited(state.L, abs_payload, allocator, &budget);
}

pub fn dispatchObserverHandler(
    state: *lua_runtime.LuaState,
    runner: *runner_mod.ExtensionRunner,
    h: event_registry.EventHandler,
    payload_idx: c_int,
) DispatchError!void {
    return runOneHandler(state, runner, h, payload_idx);
}

pub fn pushHandlerAndContextForBridge(
    state: *lua_runtime.LuaState,
    runner: *runner_mod.ExtensionRunner,
    co: *lua_runtime.Coroutine,
    handler_ref: c_int,
    provenance: ?resource_types.ExtensionProvenance,
    payload_idx: c_int,
) DispatchError!void {
    return pushHandlerAndContext(state, runner, co, handler_ref, provenance, payload_idx);
}

fn pushHandlerAndContext(
    state: *lua_runtime.LuaState,
    runner: *runner_mod.ExtensionRunner,
    co: *lua_runtime.Coroutine,
    handler_ref: c_int,
    provenance: ?resource_types.ExtensionProvenance,
    payload_idx: c_int,
) DispatchError!void {
    _ = c.lua_rawgeti(co.L, c.LUA_REGISTRYINDEX, handler_ref);
    if (c.lua_type(co.L, -1) != c.LUA_TFUNCTION) {
        c.lua_pop(co.L, 1);
        return error.HandlerError;
    }

    try context_mod.pushExtensionContext(co.L, runner, provenance);

    c.lua_pushvalue(state.L, payload_idx);
    c.lua_xmove(state.L, co.L, 1);

    runner.setModuleContext(state, provenance);
}

fn runOneHandler(
    state: *lua_runtime.LuaState,
    runner: *runner_mod.ExtensionRunner,
    h: event_registry.EventHandler,
    payload_idx: c_int,
) DispatchError!void {
    var co = try lua_runtime.Coroutine.init(state);
    var co_owned = true;
    defer if (co_owned) co.deinit();

    try pushHandlerAndContext(state, runner, &co, h.lua_ref, h.provenance, payload_idx);
    if (h.provenance) |provenance| {
        runner.beginExecutionContext(runner.sourceForProvenance(provenance));
        defer runner.endExecutionContext();
    }

    const r = try co.resumeWith(2);
    switch (r.status) {
        .yielded => {
            const start = runner.suspendYieldedCoroutine(&co, h.provenance) catch return error.UnexpectedYield;
            co_owned = false;
            runner.submitAsyncStart(start) catch return error.UnexpectedYield;
            return;
        },
        .ok, .finished => {},
    }
    if (r.nresults > 0) c.lua_pop(co.L, r.nresults);
}

const testing = std.testing;
const api_v4 = @import("api_v4.zig");

fn setupCounterChain(state: *lua_runtime.LuaState, runner: *runner_mod.ExtensionRunner, kind_name: [:0]const u8) !void {
    api_v4.install(state, runner);
    try state.doString(
        \\_test_counters = {}
    , "init_counters");
    _ = kind_name;
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

fn testIsIdle(_: *anyopaque) bool {
    return true;
}

fn testAbort(_: *anyopaque) void {}

fn testHasPendingMessages(_: *anyopaque) bool {
    return false;
}

fn testGetContextUsage(_: *anyopaque) ?session_core.context_usage.ContextUsage {
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

fn bindTestRuntime(runner: *runner_mod.ExtensionRunner, provider_registry: *ai.provider.Registry, session: *u8) !void {
    try runner.bindRuntime(.{
        .session = @ptrCast(session),
        .ui = null,
        .command_actions = null,
        .get_model = &testGetModel,
        .is_idle = &testIsIdle,
        .abort = &testAbort,
        .has_pending_messages = &testHasPendingMessages,
        .shutdown = null,
        .context_usage = &testGetContextUsage,
        .system_prompt = &testGetSystemPrompt,
        .get_binding_info = &testGetBindingInfo,
    }, provider_registry);
}

test "dispatchObserver runs handlers in order and continues after errors" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();
    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();
    var provider_registry = ai.provider.Registry.init(testing.allocator);
    defer provider_registry.deinit();

    var dummy: u8 = 0;
    try bindTestRuntime(&runner, &provider_registry, &dummy);

    try setupCounterChain(&state, &runner, "message_end");

    try state.doString(
        \\zi.define.event("message_end", function(ctx, event) table.insert(_test_counters, "a:" .. event.name) end)
        \\zi.define.event("message_end", function(ctx, event) error("boom") end)
        \\zi.define.event("message_end", function(ctx, event) table.insert(_test_counters, "c:" .. event.name) end)
    , "subscribe");

    c.lua_createtable(state.L, 0, 1);
    _ = c.lua_pushstring(state.L, "ping");
    c.lua_setfield(state.L, -2, "name");

    try dispatchObserver(&state, &runner, .message_end, -1);

    c.lua_pop(state.L, 1);

    try state.doString(
        \\assert(#_test_counters == 2, "expected 2 entries, got " .. #_test_counters)
        \\assert(_test_counters[1] == "a:ping", _test_counters[1])
        \\assert(_test_counters[2] == "c:ping", _test_counters[2])
    , "verify");
}

test "dispatch paths expose binding from handler provenance" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();
    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 7);
    defer runner.deinit();
    var provider_registry = ai.provider.Registry.init(testing.allocator);
    defer provider_registry.deinit();

    var dummy: u8 = 0;
    try bindTestRuntime(&runner, &provider_registry, &dummy);

    api_v4.install(&state, &runner);
    runner.beginLoadContext(testLoadSource());
    defer runner.endLoadContext();

    try state.doString(
        \\zi.define.event("message_end", function(ctx, event)
        \\  assert(ctx.env ~= nil)
        \\  assert(ctx.env.state_owner_id == "state-123")
        \\  assert(tonumber(ctx.env.generation_id) == 7)
        \\  assert(ctx.env.namespace_id == "state-123::7")
        \\  assert(ctx.env.workspace_id == "/workspace")
        \\  assert(ctx.env.session_id == "session-123")
        \\  assert(ctx.env.session_file == "/workspace/.zi/sessions/session-123.jsonl")
        \\end)
        \\zi.define.event("tool_call", function(ctx, event)
        \\  assert(ctx.env ~= nil)
        \\  assert(ctx.env.namespace_id == "state-123::7")
        \\  return { block = true, reason = ctx.env.session_id }
        \\end)
        \\zi.define.event("tool_result", function(ctx, event)
        \\  assert(ctx.env ~= nil)
        \\  return { namespace_id = ctx.env.namespace_id, session_file = ctx.env.session_file }
        \\end)
    , "binding_dispatch");

    c.lua_createtable(state.L, 0, 0);
    try dispatchObserver(&state, &runner, .message_end, -1);
    c.lua_pop(state.L, 1);

    c.lua_createtable(state.L, 0, 0);
    var cancel = try dispatchCancellable(&state, &runner, .tool_call, -1, testing.allocator);
    defer cancel.deinit(testing.allocator);
    c.lua_pop(state.L, 1);
    try testing.expect(cancel.blocked);
    try testing.expectEqualStrings("session-123", cancel.reason.?);

    c.lua_createtable(state.L, 0, 0);
    var transformed = try dispatchTransformable(&state, &runner, .tool_result, -1, testing.allocator);
    defer lua_runtime.freeJsonValue(testing.allocator, transformed);
    c.lua_pop(state.L, 1);

    try testing.expect(transformed == .object);
    try testing.expectEqualStrings("state-123::7", transformed.object.get("namespace_id").?.string);
    try testing.expectEqualStrings("/workspace/.zi/sessions/session-123.jsonl", transformed.object.get("session_file").?.string);
}

test "dispatchCancellable stops at first block=true" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();
    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();

    try setupCounterChain(&state, &runner, "tool_call");

    try state.doString(
        \\zi.define.event("tool_call", function(ctx, event)
        \\  table.insert(_test_counters, "first")
        \\  -- no return → fall through
        \\end)
        \\zi.define.event("tool_call", function(ctx, event)
        \\  table.insert(_test_counters, "second")
        \\  return { block = true, reason = "danger" }
        \\end)
        \\zi.define.event("tool_call", function(ctx, event)
        \\  table.insert(_test_counters, "third (should NOT run)")
        \\end)
    , "subscribe");

    c.lua_createtable(state.L, 0, 1);
    _ = c.lua_pushstring(state.L, "bash");
    c.lua_setfield(state.L, -2, "tool_name");

    var result = try dispatchCancellable(&state, &runner, .tool_call, -1, testing.allocator);
    defer result.deinit(testing.allocator);

    c.lua_pop(state.L, 1);

    try testing.expect(result.blocked);
    try testing.expectEqualStrings("danger", result.reason.?);

    try state.doString(
        \\assert(#_test_counters == 2, "expected 2 entries, got " .. #_test_counters)
        \\assert(_test_counters[1] == "first")
        \\assert(_test_counters[2] == "second")
    , "verify");
}

test "dispatchCancellable returns blocked=false when chain falls through" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();
    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();

    api_v4.install(&state, &runner);

    try state.doString(
        \\zi.define.event("tool_call", function(ctx, event) end)
        \\zi.define.event("tool_call", function(ctx, event) return nil end)
    , "subscribe");

    c.lua_createtable(state.L, 0, 0);
    var result = try dispatchCancellable(&state, &runner, .tool_call, -1, testing.allocator);
    defer result.deinit(testing.allocator);
    c.lua_pop(state.L, 1);

    try testing.expect(!result.blocked);
    try testing.expect(result.reason == null);
}

test "dispatchTransformable feeds each handler's return into the next" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();
    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();

    api_v4.install(&state, &runner);

    try state.doString(
        \\zi.define.event("tool_result", function(ctx, event)
        \\  return { counter = (event.counter or 0) + 1, label = event.label }
        \\end)
        \\zi.define.event("tool_result", function(ctx, event)
        \\  return { counter = event.counter + 1, label = event.label .. "!" }
        \\end)
        \\zi.define.event("tool_result", function(ctx, event)
        \\  -- no return → identity
        \\end)
    , "subscribe");

    c.lua_createtable(state.L, 0, 2);
    c.lua_pushinteger(state.L, 0);
    c.lua_setfield(state.L, -2, "counter");
    _ = c.lua_pushstring(state.L, "hi");
    c.lua_setfield(state.L, -2, "label");

    var result = try dispatchTransformable(&state, &runner, .tool_result, -1, testing.allocator);
    defer lua_runtime.freeJsonValue(testing.allocator, result);

    c.lua_pop(state.L, 1);

    try testing.expect(result == .object);
    const counter = result.object.get("counter").?;
    try testing.expectEqual(@as(i64, 2), counter.integer);
    const label = result.object.get("label").?;
    try testing.expectEqualStrings("hi!", label.string);
}
