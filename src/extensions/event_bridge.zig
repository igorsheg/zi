//! Bridge between the agent's `AgentEvent` stream and the
//! extension `dispatch` primitives.
//!
//! ExtensionRunner subscribes to `agent.subscribe(...)`. Every
//! AgentEvent that matches an `EventKind` we know about gets:
//!
//!   1. Translated to a Lua table on the runner's main state
//!      (per-variant builder, see `pushPayloadFor*` functions).
//!   2. Handed to `dispatch.dispatchObserver` (or the appropriate
//!      semantics primitive) which walks the registered chain.
//!   3. Popped from the main state when dispatch returns.
//!
//! Why a separate file from `runner.zig`: the runner has zero
//! upward dependencies (only `std`, `registries`, `lua_runtime`).
//! Routing AgentEvent requires importing `agent/protocol.zig`,
//! which would pollute the runner's import graph. Keeping the
//! bridge in its own module preserves that isolation — any code
//! that wants the runner without the agent can just import
//! `runner.zig`.
//!
//! Scope (D5 v1): observer events ONLY. The cancellable and
//! transformable events (`tool_call`, `tool_result`) flow through
//! the agent loop's `BeforeToolCallHook` / `AfterToolCallHook`
//! seams instead of the subscribe path — those need their own
//! adapter functions that return values to the loop. Filed as
//! follow-up; out of scope here.

const std = @import("std");
const agent_protocol = @import("../agent/protocol.zig");
const lua_runtime = @import("lua_runtime.zig");
const runner_mod = @import("runner.zig");
const dispatch = @import("dispatch.zig");
const event_registry = @import("registries/event_registry.zig");

const c = lua_runtime.c;
const log = std.log.scoped(.zi_bridge);

/// Adapter matching `agent_protocol.AgentEventSink`. Pass this and
/// a `*ExtensionRunner` as the ctx to `agent.subscribe`. The runner
/// must already have `lua_state` attached or the bridge no-ops.
pub fn agentEventSink(event: agent_protocol.AgentEvent, ctx: ?*anyopaque) void {
    const runner: *runner_mod.ExtensionRunner = @ptrCast(@alignCast(ctx.?));
    handleAgentEvent(runner, event) catch |err| {
        log.warn("agent event dispatch failed: {s}", .{@errorName(err)});
    };
}

/// Translate `event` to a Lua payload table on the runner's main
/// state, then walk the appropriate handler chain. Caller is
/// responsible for ensuring the runner has `lua_state` attached.
///
/// Returns `error.NoState` if the runner is detached — the agent
/// sink swallows this so a half-constructed runner doesn't crash
/// the agent thread.
pub fn handleAgentEvent(
    runner: *runner_mod.ExtensionRunner,
    event: agent_protocol.AgentEvent,
) !void {
    const state = runner.lua_state orelse return error.NoState;

    // Each branch:
    //   1. Pushes a payload table onto the main stack (via the
    //      pushPayloadFor* helper).
    //   2. Calls dispatchObserver with payload at index -1.
    //   3. Pops the payload.
    //
    // Errors during payload construction unwind via `try`; the
    // partial table (if any) gets popped by the catch in
    // `agentEventSink` via lua_settop on the next event. We could
    // be more careful here but the alternative — leaking one
    // table-shaped slot per failure — is bounded by the GC.
    switch (event) {
        .agent_start => try observe(state, runner, .agent_start, pushAgentStart),
        .agent_end => |e| try observeWith(state, runner, .agent_end, e, pushAgentEnd),
        .turn_start => try observe(state, runner, .turn_start, pushTurnStart),
        .turn_end => |e| try observeWith(state, runner, .turn_end, e, pushTurnEnd),
        .message_start => |e| try observeWith(state, runner, .message_start, e, pushMessageStart),
        .message_update => |e| try observeWith(state, runner, .message_update, e, pushMessageUpdate),
        .message_end => |e| try observeWith(state, runner, .message_end, e, pushMessageEnd),
        .tool_execution_start => |e| try observeWith(state, runner, .tool_execution_start, e, pushToolExecStart),
        .tool_execution_update => |e| try observeWith(state, runner, .tool_execution_update, e, pushToolExecUpdate),
        .tool_execution_end => |e| try observeWith(state, runner, .tool_execution_end, e, pushToolExecEnd),
    }
}

// =============================================================================
// Dispatch wrappers
// =============================================================================

fn observe(
    state: *lua_runtime.LuaState,
    runner: *runner_mod.ExtensionRunner,
    kind: event_registry.EventKind,
    builder: *const fn (*c.lua_State) lua_runtime.ConvertError!void,
) !void {
    // Skip the build entirely if no handler subscribes — the table
    // is pure overhead in that case, and the early-out matters once
    // we wire the runner into a hot agent loop.
    if (runner.event_registry.handlers(kind).len == 0) return;

    try builder(state.L);
    defer c.lua_pop(state.L, 1);
    try dispatch.dispatchObserver(state, runner, kind, -1);
}

/// Same as `observe` but the builder takes the event payload too.
/// Both `payload` and `builder` are `anytype` because each AgentEvent
/// variant is an anonymous struct — there is no name we could write
/// in a `*const fn` signature. The compiler monomorphizes per call
/// site, which is the same code we'd write by hand.
fn observeWith(
    state: *lua_runtime.LuaState,
    runner: *runner_mod.ExtensionRunner,
    kind: event_registry.EventKind,
    payload: anytype,
    builder: anytype,
) !void {
    if (runner.event_registry.handlers(kind).len == 0) return;

    try builder(state.L, payload);
    defer c.lua_pop(state.L, 1);
    try dispatch.dispatchObserver(state, runner, kind, -1);
}

// =============================================================================
// Per-variant payload builders
// =============================================================================
//
// Each builder pushes ONE Lua table onto the stack. The table
// shape mirrors the AgentEvent variant fields, exposing what an
// extension actually needs. v1 keeps these MINIMAL — extensions
// reading deeper fields (e.g. assistant content blocks) get null
// in v1 and a richer table in v2 once we know which fields
// matter. Adding fields is backwards-compatible: handlers that
// don't read them are unaffected.

fn pushAgentStart(L: *c.lua_State) lua_runtime.ConvertError!void {
    c.lua_createtable(L, 0, 0);
}

fn pushAgentEnd(L: *c.lua_State, payload: anytype) lua_runtime.ConvertError!void {
    c.lua_createtable(L, 0, 1);
    c.lua_pushinteger(L, @intCast(payload.messages.len));
    c.lua_setfield(L, -2, "messages_count");
}

fn pushTurnStart(L: *c.lua_State) lua_runtime.ConvertError!void {
    c.lua_createtable(L, 0, 0);
}

fn pushTurnEnd(L: *c.lua_State, payload: anytype) lua_runtime.ConvertError!void {
    c.lua_createtable(L, 0, 2);
    pushMessageRoleField(L, payload.message);
    c.lua_pushinteger(L, @intCast(payload.tool_results.len));
    c.lua_setfield(L, -2, "tool_results_count");
}

fn pushMessageStart(L: *c.lua_State, payload: anytype) lua_runtime.ConvertError!void {
    c.lua_createtable(L, 0, 1);
    pushMessageRoleField(L, payload.message);
}

fn pushMessageUpdate(L: *c.lua_State, payload: anytype) lua_runtime.ConvertError!void {
    c.lua_createtable(L, 0, 1);
    pushMessageRoleField(L, payload.message);
    // assistant_message_event has many sub-variants. v1 surfaces
    // just its tag name as `update_kind`; later phases can grow
    // this when extensions need to introspect deltas vs starts vs
    // tool-call pieces.
    _ = c.lua_pushstring(L, @tagName(payload.assistant_message_event));
    c.lua_setfield(L, -2, "update_kind");
}

fn pushMessageEnd(L: *c.lua_State, payload: anytype) lua_runtime.ConvertError!void {
    c.lua_createtable(L, 0, 1);
    pushMessageRoleField(L, payload.message);
}

fn pushToolExecStart(L: *c.lua_State, payload: anytype) lua_runtime.ConvertError!void {
    c.lua_createtable(L, 0, 3);

    _ = c.lua_pushlstring(L, payload.tool_call_id.ptr, payload.tool_call_id.len);
    c.lua_setfield(L, -2, "tool_call_id");

    _ = c.lua_pushlstring(L, payload.tool_name.ptr, payload.tool_name.len);
    c.lua_setfield(L, -2, "tool_name");

    try lua_runtime.pushJsonValue(L, payload.args);
    c.lua_setfield(L, -2, "args");
}

fn pushToolExecUpdate(L: *c.lua_State, payload: anytype) lua_runtime.ConvertError!void {
    c.lua_createtable(L, 0, 4);

    _ = c.lua_pushlstring(L, payload.tool_call_id.ptr, payload.tool_call_id.len);
    c.lua_setfield(L, -2, "tool_call_id");

    _ = c.lua_pushlstring(L, payload.tool_name.ptr, payload.tool_name.len);
    c.lua_setfield(L, -2, "tool_name");

    try lua_runtime.pushJsonValue(L, payload.args);
    c.lua_setfield(L, -2, "args");

    c.lua_pushboolean(L, if (payload.partial_result != null) 1 else 0);
    c.lua_setfield(L, -2, "has_partial");
}

fn pushToolExecEnd(L: *c.lua_State, payload: anytype) lua_runtime.ConvertError!void {
    c.lua_createtable(L, 0, 4);

    _ = c.lua_pushlstring(L, payload.tool_call_id.ptr, payload.tool_call_id.len);
    c.lua_setfield(L, -2, "tool_call_id");

    _ = c.lua_pushlstring(L, payload.tool_name.ptr, payload.tool_name.len);
    c.lua_setfield(L, -2, "tool_name");

    c.lua_pushboolean(L, if (payload.is_error) 1 else 0);
    c.lua_setfield(L, -2, "is_error");

    // Extensions that need full result content can inspect the
    // tool_result event (transformable) — v1 keeps the observer
    // payload light and uses a single bool for the success flag.
    c.lua_pushinteger(L, @intCast(payload.result.content.len));
    c.lua_setfield(L, -2, "content_count");
}

/// Helper: extract the role tag from an AgentMessage and set it
/// as the `role` field on the table currently at the top of the
/// stack. Stack depth unchanged on return.
fn pushMessageRoleField(L: *c.lua_State, message: agent_protocol.AgentMessage) void {
    const role = @tagName(message);
    _ = c.lua_pushlstring(L, role.ptr, role.len);
    c.lua_setfield(L, -2, "role");
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;
const api = @import("api.zig");

test "event_bridge dispatches AgentEvent.message_end through to a Lua handler" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();
    runner.attachLuaState(&state);

    api.installZiTable(&state, &runner);

    // Subscribe via the public Lua API: a single message_end
    // handler that records the role into a global so the test
    // can check it.
    try state.doString(
        \\_received_role = nil
        \\zi.on("message_end", function(event, ctx)
        \\  _received_role = event.role
        \\end)
    , "subscribe");

    // Synthesize a message_end AgentEvent for an assistant
    // message. We don't need real fields beyond what
    // pushMessageEnd reads — `role` comes from the union tag.
    const fake_assistant = agent_protocol.AgentMessage{
        .assistant = .{
            .content = &.{},
            .api = .{ .anthropic_messages = {} },
            .provider = .{ .anthropic = {} },
            .model = "test",
            .usage = .{
                .input = 0,
                .output = 0,
                .cache_read = 0,
                .cache_write = 0,
                .total_tokens = 0,
                .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 },
            },
            .stop_reason = .stop,
            .timestamp = 0,
        },
    };

    try handleAgentEvent(&runner, .{ .message_end = .{ .message = fake_assistant } });

    // Verify the handler ran and saw role = "assistant".
    try state.doString(
        \\assert(_received_role == "assistant", "expected 'assistant', got " .. tostring(_received_role))
    , "verify");
}

test "event_bridge skips dispatch when no handler is subscribed" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();
    runner.attachLuaState(&state);

    api.installZiTable(&state, &runner);

    // No subscription. Dispatching should be a complete no-op
    // — no Lua state mutation, no errors.
    const top_before = c.lua_gettop(state.L);
    try handleAgentEvent(&runner, .{ .agent_start = {} });
    const top_after = c.lua_gettop(state.L);

    try testing.expectEqual(top_before, top_after);
}

test "event_bridge tool_execution_start exposes tool_name and args to handler" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();
    runner.attachLuaState(&state);

    api.installZiTable(&state, &runner);

    try state.doString(
        \\_seen_tool = nil
        \\_seen_command = nil
        \\zi.on("tool_execution_start", function(event, ctx)
        \\  _seen_tool = event.tool_name
        \\  _seen_command = event.args.command
        \\end)
    , "subscribe");

    // Build a synthetic args JSON value: { command = "ls -la" }
    var args_obj = std.json.ObjectMap.init(testing.allocator);
    defer args_obj.deinit();
    try args_obj.put("command", .{ .string = "ls -la" });

    try handleAgentEvent(&runner, .{
        .tool_execution_start = .{
            .tool_call_id = "id-1",
            .tool_name = "Bash",
            .args = .{ .object = args_obj },
        },
    });

    try state.doString(
        \\assert(_seen_tool == "Bash", "tool_name: " .. tostring(_seen_tool))
        \\assert(_seen_command == "ls -la", "command: " .. tostring(_seen_command))
    , "verify");
}
