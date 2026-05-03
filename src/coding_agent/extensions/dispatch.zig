//! Event dispatch — walks the chains in `event_registry` and runs
//! Lua handlers under the observer / mutable / transformable semantics
//! described in `docs/extensions.md`.
//!
//! Three primitives, each generic over the event payload:
//!
//!   - `dispatchObserver(...)`     — fire-and-forget, return values
//!     ignored. Used for lifecycle events (`agent_start`,
//!     `message_end`, `tool_execution_*`, etc.).
//!
//!   - `dispatchCancellable(...) → CancelResult`
//!     — chain runs in registration order; the first handler that
//!     returns `{ block = true, reason = ... }` short-circuits and
//!     the dispatcher returns the block result. Mutations to the
//!     payload table by earlier handlers are visible to later ones
//!     (the table is shared across the chain — Lua semantics).
//!     Used for `tool_call`, `session_before_*`.
//!
//!   - `dispatchTransformable(...) → ?std.json.Value`
//!     — each handler's return value replaces the payload for the
//!     next handler. The final value is returned to zig as an owned
//!     `std.json.Value`. Returning `nil` from a handler keeps the
//!     prior value. Used for `tool_result`, `context`, `input`,
//!     `before_provider_request`.
//!
//! Coroutine model: every handler runs in a fresh coroutine
//! (`Coroutine.init`), even when it can't yield. This is the spec's
//! §Lua Coroutine C-Call Model invariant — once host functions like
//! `zi.spawn` and `ctx.ui.prompt` exist (E5+), they must yield, and
//! `lua_resume` is the only way to call something that might. Using
//! coroutines uniformly avoids a future migration where we'd have
//! to rewrite the dispatcher.
//!
//! For D4 v1 a `LUA_YIELD` return surfaces as `error.UnexpectedYield`
//! — no host function yields yet, so any yield is a bug. When E5
//! introduces `zi.spawn`, this site grows the resume loop.
//!
//! Payload contract: the caller pushes the event payload onto the
//! main Lua state's stack BEFORE invoking a dispatch primitive. The
//! dispatcher copies it onto each handler's coroutine via
//! `lua_xmove`, so the original stays put across the chain. The
//! caller is responsible for popping it after dispatch returns.
//!
//! Why xmove from main → coroutine instead of building per-call:
//! the agent integration (D5) will translate `AgentEvent` to a Lua
//! table once per event, not once per handler. xmove lets us reuse
//! that work across an arbitrary chain length.

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
};

/// Result of a cancellable dispatch. `blocked` is true when any
/// handler returned `{ block = true }`. `reason` is the optional
/// string from that same return table (owned by the supplied
/// allocator); null when the handler omitted it.
pub const CancelResult = struct {
    blocked: bool,
    reason: ?[]const u8 = null,

    pub fn deinit(self: *CancelResult, allocator: std.mem.Allocator) void {
        if (self.reason) |r| allocator.free(r);
        self.* = undefined;
    }
};

// =============================================================================
// Observer
// =============================================================================

/// Walk the chain for `kind`, calling each handler with the payload
/// at `payload_idx` on the main state. Return values are discarded.
/// On a Lua-side error, logs and continues — observer handlers must
/// not be able to break the chain via a thrown error (matches
/// pi-mono's "broken extension is logged per-handler" doctrine).
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
            // Observer chain continues even on individual failure.
            continue;
        };
    }
}

// =============================================================================
// Cancellable
// =============================================================================

/// Walk the chain for `kind` until a handler returns
/// `{ block = true, reason? = string }`. Returns `{ blocked = true,
/// reason }` at the first such handler; otherwise `{ blocked = false }`
/// after the chain completes.
///
/// Lua-side errors during a cancellable chain are NOT silently
/// swallowed — they surface as `error.HandlerError`. Cancellable
/// chains gate real behavior (tool execution); a broken handler
/// failing open could let unsafe operations through.
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

        if (r.nresults == 0) continue; // nil-equivalent → no opinion

        // Inspect the top return value. We expect either nil or a
        // table with `block` field.
        const top = c.lua_gettop(co.L);
        defer c.lua_settop(co.L, top - r.nresults); // pop results

        const top_idx = top; // last result is at top
        if (c.lua_type(co.L, top_idx) == c.LUA_TNIL) continue;
        if (c.lua_type(co.L, top_idx) != c.LUA_TTABLE) continue;

        _ = c.lua_getfield(co.L, top_idx, "block");
        const blocked = c.lua_toboolean(co.L, -1) != 0;
        c.lua_pop(co.L, 1);

        if (!blocked) continue;

        // Pull the reason if present.
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

// =============================================================================
// Transformable
// =============================================================================

/// Walk the chain for `kind`, feeding each handler's non-nil return
/// value as the payload for the next handler. Returns the final
/// payload as an owned `std.json.Value` allocated from `allocator`.
///
/// If no handler is registered, returns the original payload (deep-
/// cloned to the requested allocator). If every handler returns nil,
/// likewise — the dispatch is the no-op identity.
///
/// Implementation note: between handlers we keep the "current
/// payload" on the MAIN Lua stack at `payload_idx`. Each handler
/// gets a copy via xmove; if it returns a non-nil value, we
/// xmove that back to the main stack and `lua_replace` over the
/// old payload. This keeps the working set small and reuses Lua's
/// own GC for intermediate tables.
pub fn dispatchTransformable(
    state: *lua_runtime.LuaState,
    runner: *runner_mod.ExtensionRunner,
    kind: event_registry.EventKind,
    payload_idx: c_int,
    allocator: std.mem.Allocator,
) DispatchError!std.json.Value {
    const handlers = runner.event_registry.handlers(kind);

    // Normalize payload_idx so subsequent operations don't drift if
    // we push intermediate values onto the main stack.
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

        // If the handler returned nil, leave the payload as-is.
        const top_idx = c.lua_gettop(co.L);
        if (c.lua_type(co.L, top_idx) == c.LUA_TNIL) {
            c.lua_settop(co.L, top_idx - r.nresults);
            continue;
        }

        // Move the new payload from the coroutine back to the main
        // state and replace the slot at `abs_payload`. lua_xmove
        // moves the top value (we discard any extra returns first).
        if (r.nresults > 1) c.lua_pop(co.L, r.nresults - 1);
        c.lua_xmove(co.L, state.L, 1);
        c.lua_replace(state.L, abs_payload);
    }

    return lua_runtime.luaValueToJson(state.L, abs_payload, allocator);
}

// =============================================================================
// Internals
// =============================================================================

pub fn dispatchObserverHandler(
    state: *lua_runtime.LuaState,
    runner: *runner_mod.ExtensionRunner,
    h: event_registry.EventHandler,
    payload_idx: c_int,
) DispatchError!void {
    return runOneHandler(state, runner, h, payload_idx);
}

/// Push the handler (resolved from the registry ref) onto the
/// coroutine's stack, then xmove a copy of the main state's payload
/// onto it. Stack on entry: main has payload at payload_idx.
/// Stack on success: coroutine has [handler, payload], main is
/// unchanged (xmove was preceded by lua_pushvalue).
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
    // Resolve the handler. lua_rawgeti against LUA_REGISTRYINDEX
    // works on any state of the same instance — main or coroutine —
    // so we push directly onto the coroutine's stack.
    _ = c.lua_rawgeti(co.L, c.LUA_REGISTRYINDEX, handler_ref);
    if (c.lua_type(co.L, -1) != c.LUA_TFUNCTION) {
        c.lua_pop(co.L, 1);
        return error.HandlerError;
    }

    // Duplicate the payload on the main stack, then xmove the dup.
    c.lua_pushvalue(state.L, payload_idx);
    c.lua_xmove(state.L, co.L, 1);

    // Second arg: shared extension context.
    try context_mod.pushExtensionContext(co.L, runner, provenance);

    // Ensure the handler sees the same private-root package.path
    // that the extension had during load.
    runner.setModuleContext(state, provenance);
}

/// One-shot handler runner used by dispatchObserver. Same shape as
/// the cancellable/transformable inner loop but discards results.
fn runOneHandler(
    state: *lua_runtime.LuaState,
    runner: *runner_mod.ExtensionRunner,
    h: event_registry.EventHandler,
    payload_idx: c_int,
) DispatchError!void {
    var co = try lua_runtime.Coroutine.init(state);
    defer co.deinit();

    try pushHandlerAndContext(state, runner, &co, h.lua_ref, h.provenance, payload_idx);
    if (h.provenance) |provenance| {
        runner.beginExecutionContext(runner.sourceForProvenance(provenance));
        defer runner.endExecutionContext();
    }

    const r = try co.resumeWith(2);
    switch (r.status) {
        .yielded => return error.UnexpectedYield,
        .ok, .finished => {},
    }
    if (r.nresults > 0) c.lua_pop(co.L, r.nresults);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;
const api = @import("api.zig");

/// Helper: register `n` handlers for `kind` via the public Lua API,
/// each one mutating a global counter table so the tests can verify
/// the chain ran in order.
fn setupCounterChain(state: *lua_runtime.LuaState, runner: *runner_mod.ExtensionRunner, kind_name: [:0]const u8) !void {
    api.installZiTable(state, runner);
    // Initialize a global counter table.
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
        .get_context_usage = &testGetContextUsage,
        .get_system_prompt = &testGetSystemPrompt,
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
        \\zi.on("message_end", function(event, ctx) table.insert(_test_counters, "a:" .. event.name) end)
        \\zi.on("message_end", function(event, ctx) error("boom") end)
        \\zi.on("message_end", function(event, ctx) table.insert(_test_counters, "c:" .. event.name) end)
    , "subscribe");

    // Build a payload table on the main stack: { name = "ping" }
    c.lua_createtable(state.L, 0, 1);
    _ = c.lua_pushstring(state.L, "ping");
    c.lua_setfield(state.L, -2, "name");

    try dispatchObserver(&state, &runner, .message_end, -1);

    c.lua_pop(state.L, 1); // pop the payload

    // Verify the counters in order.
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

    api.installZiTable(&state, &runner);
    runner.beginLoadContext(testLoadSource());
    defer runner.endLoadContext();

    try state.doString(
        \\zi.on("message_end", function(event, ctx)
        \\  assert(ctx.binding ~= nil)
        \\  assert(ctx.binding.runtime_root_id == "root-123")
        \\  assert(ctx.binding.state_owner_id == "state-123")
        \\  assert(ctx.binding.generation_id == 7)
        \\  assert(ctx.binding.namespace_id == "state-123::7")
        \\  assert(ctx.binding.workspace_id == "/workspace")
        \\  assert(ctx.binding.session_id == "session-123")
        \\  assert(ctx.binding.session_file == "/workspace/.zi/sessions/session-123.jsonl")
        \\end)
        \\zi.on("tool_call", function(event, ctx)
        \\  assert(ctx.binding ~= nil)
        \\  assert(ctx.binding.namespace_id == "state-123::7")
        \\  return { block = true, reason = ctx.binding.session_id }
        \\end)
        \\zi.on("tool_result", function(event, ctx)
        \\  assert(ctx.binding ~= nil)
        \\  return { namespace_id = ctx.binding.namespace_id, session_file = ctx.binding.session_file }
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
        \\zi.on("tool_call", function(event, ctx)
        \\  table.insert(_test_counters, "first")
        \\  -- no return → fall through
        \\end)
        \\zi.on("tool_call", function(event, ctx)
        \\  table.insert(_test_counters, "second")
        \\  return { block = true, reason = "danger" }
        \\end)
        \\zi.on("tool_call", function(event, ctx)
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

    api.installZiTable(&state, &runner);

    try state.doString(
        \\zi.on("tool_call", function(event, ctx) end)
        \\zi.on("tool_call", function(event, ctx) return nil end)
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

    api.installZiTable(&state, &runner);

    // Pipeline: each handler increments a counter field on the
    // payload. The third handler returns nil (no change). Final
    // value should have counter == 2.
    try state.doString(
        \\zi.on("tool_result", function(event, ctx)
        \\  return { counter = (event.counter or 0) + 1, label = event.label }
        \\end)
        \\zi.on("tool_result", function(event, ctx)
        \\  return { counter = event.counter + 1, label = event.label .. "!" }
        \\end)
        \\zi.on("tool_result", function(event, ctx)
        \\  -- no return → identity
        \\end)
    , "subscribe");

    // Initial payload: { counter = 0, label = "hi" }
    c.lua_createtable(state.L, 0, 2);
    c.lua_pushinteger(state.L, 0);
    c.lua_setfield(state.L, -2, "counter");
    _ = c.lua_pushstring(state.L, "hi");
    c.lua_setfield(state.L, -2, "label");

    var result = try dispatchTransformable(&state, &runner, .tool_result, -1, testing.allocator);
    defer lua_runtime.freeJsonValue(testing.allocator, result);

    c.lua_pop(state.L, 1); // pop the (now-replaced) payload slot

    try testing.expect(result == .object);
    const counter = result.object.get("counter").?;
    try testing.expectEqual(@as(i64, 2), counter.integer);
    const label = result.object.get("label").?;
    try testing.expectEqualStrings("hi!", label.string);
}
