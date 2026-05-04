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
//! Routing AgentEvent requires importing `agent2/protocol.zig`,
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
const agent_protocol = @import("../../agent/types.zig");
const ai_protocol = @import("../../ai/protocol.zig");
const abort_signal_mod = @import("../../zio/root.zig").abort;
const resource_types = @import("../resources/types.zig");
const lua_runtime = @import("lua_runtime.zig");
const runner_mod = @import("runner.zig");
const context_mod = @import("context.zig");
const dispatch = @import("dispatch.zig");
const event_registry = @import("registries/event_registry.zig");

const c = lua_runtime.c;
const log = std.log.scoped(.zi_bridge);

pub const InputMiddlewareResult = union(enum) {
    continue_,
    transform: []const u8,
    handled: ?[]const u8,
    blocked: ?[]const u8,
};

pub const BeforeAgentStartOptions = struct {
    cwd: []const u8,
    selected_tools: []const []const u8,
    skills: []const resource_types.Skill,
    append_system_prompt: []const []const u8,
};

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

    runner.assertOnLuaThread();

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

fn observe(
    state: *lua_runtime.LuaState,
    runner: *runner_mod.ExtensionRunner,
    kind: event_registry.EventKind,
    builder: *const fn (*c.lua_State) lua_runtime.ConvertError!void,
) !void {
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

pub fn dispatchSemanticMessage(
    runner: *runner_mod.ExtensionRunner,
    message: agent_protocol.AgentMessage,
    entry_id: []const u8,
) !void {
    const state = runner.lua_state orelse return error.NoState;
    runner.assertOnLuaThread();
    try dispatchSemanticMessageForState(state, runner, message, entry_id);
}

fn dispatchSemanticMessageForState(
    state: *lua_runtime.LuaState,
    runner: *runner_mod.ExtensionRunner,
    message: agent_protocol.AgentMessage,
    entry_id: []const u8,
) !void {
    if (runner.event_registry.handlers(.message).len == 0) return;
    switch (message) {
        .user => |user| {
            try pushSemanticMessagePayload(state.L, "user", entry_id, null);
            defer c.lua_pop(state.L, 1);
            const msg_idx = c.lua_absindex(state.L, -1);
            try pushUserTextField(state.L, msg_idx, user);
            try dispatch.dispatchObserver(state, runner, .message, -1);
        },
        .assistant => |assistant| {
            var text: std.ArrayList(u8) = .empty;
            defer text.deinit(state.allocator);
            for (assistant.content) |block| switch (block) {
                .text => |t| {
                    if (text.items.len > 0) try text.append(state.allocator, '\n');
                    try text.appendSlice(state.allocator, t.text);
                },
                .tool_call => |call| {
                    try pushSemanticMessagePayload(state.L, "tool_call", entry_id, null);
                    defer c.lua_pop(state.L, 1);
                    const msg_idx = semanticMessageTableIndex(state.L, -1);
                    _ = c.lua_pushlstring(state.L, call.id.ptr, call.id.len);
                    c.lua_setfield(state.L, msg_idx, "tool_call_id");
                    _ = c.lua_pushlstring(state.L, call.name.ptr, call.name.len);
                    c.lua_setfield(state.L, msg_idx, "tool_name");
                    try lua_runtime.pushJsonValue(state.L, call.arguments);
                    c.lua_setfield(state.L, msg_idx, "args");
                    c.lua_pop(state.L, 1);
                    try dispatch.dispatchObserver(state, runner, .message, -1);
                },
                .thinking => {},
            };
            if (text.items.len > 0) {
                try pushSemanticMessagePayload(state.L, "assistant", entry_id, text.items);
                defer c.lua_pop(state.L, 1);
                try dispatch.dispatchObserver(state, runner, .message, -1);
            }
        },
        .tool_result => |tr| {
            try pushSemanticMessagePayload(state.L, "tool_result", entry_id, null);
            defer c.lua_pop(state.L, 1);
            const msg_idx = semanticMessageTableIndex(state.L, -1);
            _ = c.lua_pushlstring(state.L, tr.tool_call_id.ptr, tr.tool_call_id.len);
            c.lua_setfield(state.L, msg_idx, "tool_call_id");
            _ = c.lua_pushlstring(state.L, tr.tool_name.ptr, tr.tool_name.len);
            c.lua_setfield(state.L, msg_idx, "tool_name");
            c.lua_pushboolean(state.L, if (tr.is_error) 1 else 0);
            c.lua_setfield(state.L, msg_idx, "is_error");
            try pushToolResultTextField(state, msg_idx, tr);
            if (tr.details) |details| {
                try lua_runtime.pushJsonValue(state.L, details);
                c.lua_setfield(state.L, msg_idx, "details");
            }
            c.lua_pop(state.L, 1);
            try dispatch.dispatchObserver(state, runner, .message, -1);
        },
        .compaction_summary, .branch_summary, .custom => {},
    }
}

fn pushSemanticMessagePayload(L: *c.lua_State, role: []const u8, entry_id: []const u8, text: ?[]const u8) !void {
    c.lua_createtable(L, 0, 2);
    _ = c.lua_pushlstring(L, "message".ptr, "message".len);
    c.lua_setfield(L, -2, "type");
    c.lua_createtable(L, 0, 7);
    _ = c.lua_pushlstring(L, role.ptr, role.len);
    c.lua_setfield(L, -2, "role");
    _ = c.lua_pushlstring(L, entry_id.ptr, entry_id.len);
    c.lua_setfield(L, -2, "entry_id");
    if (text) |value| {
        _ = c.lua_pushlstring(L, value.ptr, value.len);
        c.lua_setfield(L, -2, "text");
    }
    c.lua_setfield(L, -2, "message");
}

fn semanticMessageTableIndex(L: *c.lua_State, payload_idx: c_int) c_int {
    _ = c.lua_getfield(L, payload_idx, "message");
    return c.lua_absindex(L, -1);
}

fn pushUserTextField(L: *c.lua_State, payload_idx: c_int, user: ai_protocol.UserMessage) !void {
    const msg_idx = semanticMessageTableIndex(L, payload_idx);
    defer c.lua_pop(L, 1);
    switch (user.content) {
        .text => |text| {
            _ = c.lua_pushlstring(L, text.ptr, text.len);
            c.lua_setfield(L, msg_idx, "text");
        },
        .blocks => |blocks| {
            for (blocks) |block| switch (block) {
                .text => |text| {
                    _ = c.lua_pushlstring(L, text.text.ptr, text.text.len);
                    c.lua_setfield(L, msg_idx, "text");
                    return;
                },
                .image => {},
            };
        },
    }
}

fn pushToolResultTextField(state: *lua_runtime.LuaState, msg_idx: c_int, tr: ai_protocol.ToolResultMessage) !void {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(state.allocator);
    for (tr.content) |block| switch (block) {
        .text => |t| {
            if (text.items.len > 0) try text.append(state.allocator, '\n');
            try text.appendSlice(state.allocator, t.text);
        },
        .image => {},
    };
    if (text.items.len == 0) return;
    _ = c.lua_pushlstring(state.L, text.items.ptr, text.items.len);
    c.lua_setfield(state.L, msg_idx, "text");
}

pub const SessionLifecycleReason = enum { startup, new, @"resume", exit, fork };

pub const SessionLifecycleContext = struct {
    runner: *runner_mod.ExtensionRunner,
    workspace_id: []const u8,
    session_id: []const u8,
    session_file: ?[]const u8 = null,
};

pub const SessionLifecycleSnapshot = struct {
    generation: runner_mod.Generation,
    workspace_id: []const u8,
    session_id: []const u8,
    session_file: ?[]const u8 = null,
    loaded_extensions: []const resource_types.ExtensionProvenance,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *SessionLifecycleSnapshot) void {
        for (self.loaded_extensions) |prov| {
            self.allocator.free(prov.runtime_root_id);
            self.allocator.free(prov.extension_id);
            self.allocator.free(prov.state_owner_id);
        }
        self.allocator.free(self.loaded_extensions);
        self.allocator.free(self.workspace_id);
        self.allocator.free(self.session_id);
        if (self.session_file) |path| self.allocator.free(path);
    }

    pub fn findLoadedExtensionById(self: *const SessionLifecycleSnapshot, extension_id: []const u8) ?resource_types.ExtensionProvenance {
        for (self.loaded_extensions) |provenance| {
            if (std.mem.eql(u8, provenance.extension_id, extension_id)) return provenance;
        }
        return null;
    }
};

pub const LifecyclePeer = union(enum) {
    live: SessionLifecycleContext,
    snapshot: *SessionLifecycleSnapshot,

    pub fn workspaceId(self: LifecyclePeer) []const u8 {
        return switch (self) {
            .live => |ctx| ctx.workspace_id,
            .snapshot => |snap| snap.workspace_id,
        };
    }

    pub fn sessionId(self: LifecyclePeer) []const u8 {
        return switch (self) {
            .live => |ctx| ctx.session_id,
            .snapshot => |snap| snap.session_id,
        };
    }

    pub fn sessionFile(self: LifecyclePeer) ?[]const u8 {
        return switch (self) {
            .live => |ctx| ctx.session_file,
            .snapshot => |snap| snap.session_file,
        };
    }

    pub fn generation(self: LifecyclePeer) runner_mod.Generation {
        return switch (self) {
            .live => |ctx| ctx.runner.generation,
            .snapshot => |snap| snap.generation,
        };
    }

    pub fn findLoadedExtensionById(self: LifecyclePeer, extension_id: []const u8) ?resource_types.ExtensionProvenance {
        return switch (self) {
            .live => |ctx| ctx.runner.findLoadedExtensionById(extension_id),
            .snapshot => |snap| snap.findLoadedExtensionById(extension_id),
        };
    }
};

pub fn snapshotLifecycleContext(ctx: SessionLifecycleContext, allocator: std.mem.Allocator) !SessionLifecycleSnapshot {
    const workspace_id = try allocator.dupe(u8, ctx.workspace_id);
    errdefer allocator.free(workspace_id);

    const session_id = try allocator.dupe(u8, ctx.session_id);
    errdefer allocator.free(session_id);

    const session_file = if (ctx.session_file) |path| try allocator.dupe(u8, path) else null;
    errdefer if (session_file) |path| allocator.free(path);

    const loaded_extensions = try allocator.alloc(resource_types.ExtensionProvenance, ctx.runner.loaded_extensions.items.len);
    errdefer allocator.free(loaded_extensions);

    var i: usize = 0;
    errdefer {
        for (loaded_extensions[0..i]) |prov| {
            allocator.free(prov.runtime_root_id);
            allocator.free(prov.extension_id);
            allocator.free(prov.state_owner_id);
        }
    }

    for (ctx.runner.loaded_extensions.items, 0..) |prov, idx| {
        loaded_extensions[idx] = .{
            .runtime_root_id = try allocator.dupe(u8, prov.runtime_root_id),
            .extension_id = try allocator.dupe(u8, prov.extension_id),
            .state_owner_id = try allocator.dupe(u8, prov.state_owner_id),
            .root_kind = prov.root_kind,
        };
        i += 1;
    }

    return .{
        .generation = ctx.runner.generation,
        .workspace_id = workspace_id,
        .session_id = session_id,
        .session_file = session_file,
        .loaded_extensions = loaded_extensions,
        .allocator = allocator,
    };
}

pub fn dispatchSessionStart(
    current: SessionLifecycleContext,
    previous: ?LifecyclePeer,
    reason: SessionLifecycleReason,
    fork_parent_entry_id: ?[]const u8,
) !void {
    try dispatchSessionLifecycle(.session_start, current, previous, reason, fork_parent_entry_id);
}

pub fn dispatchSessionShutdown(
    current: SessionLifecycleContext,
    next: ?SessionLifecycleContext,
    reason: SessionLifecycleReason,
    fork_parent_entry_id: ?[]const u8,
) !void {
    try dispatchSessionLifecycle(.session_shutdown, current, if (next) |n| .{ .live = n } else null, reason, fork_parent_entry_id);
}

/// Dispatch `model_select` to the extension observer chain.
/// Called from the successful model-change path in `AgentSession.trySetModel`.
/// No-op if the runner has no lua_state or no handlers are registered.
/// Observer failures are logged and swallowed per pi-mono doctrine.
pub fn dispatchModelSelect(
    runner: *runner_mod.ExtensionRunner,
    model: agent_protocol.Model,
    previous_model: ?agent_protocol.Model,
    source: []const u8,
) void {
    const state = runner.lua_state orelse return;
    runner.assertOnLuaThread();

    const handlers = runner.event_registry.handlers(.model_select);
    if (handlers.len == 0) return;

    pushModelSelectPayload(state.L, model, previous_model, source) catch |err| {
        log.warn("model_select payload build failed: {s}", .{@errorName(err)});
        return;
    };
    defer c.lua_pop(state.L, 1);

    dispatch.dispatchObserver(state, runner, .model_select, -1) catch |err| {
        log.warn("model_select dispatch failed: {s}", .{@errorName(err)});
    };
}

fn pushModelSelectPayload(
    L: *c.lua_State,
    model: agent_protocol.Model,
    previous_model: ?agent_protocol.Model,
    source: []const u8,
) !void {
    c.lua_createtable(L, 0, 4);
    _ = c.lua_pushlstring(L, "model_select".ptr, "model_select".len);
    c.lua_setfield(L, -2, "type");

    context_mod.pushModel(L, model);
    c.lua_setfield(L, -2, "model");

    if (previous_model) |pm| {
        context_mod.pushModel(L, pm);
    } else {
        c.lua_pushnil(L);
    }
    c.lua_setfield(L, -2, "previous_model");

    _ = c.lua_pushlstring(L, source.ptr, source.len);
    c.lua_setfield(L, -2, "source");
}

pub fn dispatchBeforeAgentStart(
    runner: *runner_mod.ExtensionRunner,
    system_prompt: []const u8,
    options: BeforeAgentStartOptions,
    allocator: std.mem.Allocator,
) ![]const u8 {
    const state = runner.lua_state orelse return error.NoState;
    runner.assertOnLuaThread();

    const handlers = runner.event_registry.handlers(.before_agent_start);
    if (handlers.len == 0) return try allocator.dupe(u8, system_prompt);

    try pushBeforeAgentStartPayload(state.L, system_prompt, options);
    defer c.lua_pop(state.L, 1);

    for (handlers) |h| {
        var co = try lua_runtime.Coroutine.init(state);
        defer co.deinit();

        try dispatch.pushHandlerAndContextForBridge(state, runner, &co, h.lua_ref, h.provenance, -1);
        const r = try co.resumeWith(2);
        switch (r.status) {
            .yielded => return error.UnexpectedYield,
            .ok, .finished => {},
        }
        if (r.nresults > 0) {
            const top = c.lua_gettop(co.L);
            defer c.lua_settop(co.L, top - r.nresults);
            const top_idx = top;
            if (c.lua_type(co.L, top_idx) == c.LUA_TTABLE) {
                if (try readOptionalStringFieldOwned(co.L, top_idx, "system_prompt", allocator)) |prompt| {
                    defer allocator.free(prompt);
                    setPayloadSystemPrompt(state.L, -1, prompt);
                }
            }
        }

        if (try readPayloadSystemPrompt(state.L, -1, allocator)) |prompt| {
            defer allocator.free(prompt);
            setPayloadSystemPrompt(state.L, -1, prompt);
        }
    }

    return try readPayloadSystemPrompt(state.L, -1, allocator) orelse try allocator.dupe(u8, system_prompt);
}

pub fn dispatchInput(
    runner: *runner_mod.ExtensionRunner,
    text: []const u8,
    queued_kind: ?[]const u8,
    allocator: std.mem.Allocator,
) !InputMiddlewareResult {
    const state = runner.lua_state orelse return error.NoState;
    runner.assertOnLuaThread();

    const handlers = runner.event_registry.handlers(.input);
    if (handlers.len == 0) return .continue_;

    try pushInputPayload(state.L, text, queued_kind);
    defer c.lua_pop(state.L, 1);

    for (handlers) |h| {
        var co = try lua_runtime.Coroutine.init(state);
        defer co.deinit();

        try dispatch.pushHandlerAndContextForBridge(state, runner, &co, h.lua_ref, h.provenance, -1);
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

        if (try readBlockResult(co.L, top_idx, allocator)) |result| return result;
        if (try readInputActionResult(co.L, top_idx, allocator)) |result| return result;
    }

    _ = c.lua_getfield(state.L, -1, "text");
    defer c.lua_pop(state.L, 1);
    if (c.lua_type(state.L, -1) == c.LUA_TSTRING) {
        var len: usize = 0;
        const ptr = c.lua_tolstring(state.L, -1, &len) orelse return .continue_;
        const mutated = ptr[0..len];
        if (!std.mem.eql(u8, mutated, text)) return .{ .transform = try allocator.dupe(u8, mutated) };
    }

    return .continue_;
}

pub fn dispatchSessionBeforeSwitch(
    current: SessionLifecycleContext,
    next: ?SessionLifecycleContext,
    reason: SessionLifecycleReason,
    allocator: std.mem.Allocator,
) !dispatch.CancelResult {
    const state = current.runner.lua_state orelse return error.NoState;
    current.runner.assertOnLuaThread();

    const handlers = current.runner.event_registry.handlers(.session_before_switch);
    if (handlers.len == 0) return .{ .blocked = false };

    try pushSessionBeforeSwitchPayload(state.L, reason, current, next);
    defer c.lua_pop(state.L, 1);

    return dispatch.dispatchCancellable(state, current.runner, .session_before_switch, -1, allocator);
}

pub fn dispatchSessionBeforeFork(
    current: SessionLifecycleContext,
    entry_id: []const u8,
    allocator: std.mem.Allocator,
) !dispatch.CancelResult {
    const state = current.runner.lua_state orelse return error.NoState;
    current.runner.assertOnLuaThread();

    const handlers = current.runner.event_registry.handlers(.session_before_fork);
    if (handlers.len == 0) return .{ .blocked = false };

    try pushSessionBeforeForkPayload(state.L, current, entry_id);
    defer c.lua_pop(state.L, 1);

    return dispatch.dispatchCancellable(state, current.runner, .session_before_fork, -1, allocator);
}

fn dispatchSessionLifecycle(
    kind: event_registry.EventKind,
    current: SessionLifecycleContext,
    related: ?LifecyclePeer,
    reason: SessionLifecycleReason,
    fork_parent_entry_id: ?[]const u8,
) !void {
    const state = current.runner.lua_state orelse return error.NoState;
    current.runner.assertOnLuaThread();

    const handlers = current.runner.event_registry.handlers(kind);
    if (handlers.len == 0) return;

    for (handlers) |handler| {
        try pushSessionLifecyclePayload(state.L, kind, reason, handler.provenance, current, related, fork_parent_entry_id);
        dispatch.dispatchObserverHandler(state, current.runner, handler, -1) catch |err| {
            c.lua_pop(state.L, 1);
            log.warn("observer handler for {s} failed: {s}", .{ @tagName(kind), @errorName(err) });
            continue;
        };
        c.lua_pop(state.L, 1);
    }
}

fn pushSessionLifecyclePayload(
    L: *c.lua_State,
    kind: event_registry.EventKind,
    reason: SessionLifecycleReason,
    provenance: ?resource_types.ExtensionProvenance,
    current: SessionLifecycleContext,
    related: ?LifecyclePeer,
    fork_parent_entry_id: ?[]const u8,
) !void {
    c.lua_createtable(L, 0, if (fork_parent_entry_id != null and reason == .fork) 5 else 4);

    const event_type = switch (kind) {
        .session_start => "session_start",
        .session_shutdown => "session_shutdown",
        else => unreachable,
    };
    _ = c.lua_pushlstring(L, event_type.ptr, event_type.len);
    c.lua_setfield(L, -2, "type");

    const reason_str = sessionLifecycleReasonString(reason);
    _ = c.lua_pushlstring(L, reason_str.ptr, reason_str.len);
    c.lua_setfield(L, -2, "reason");

    if (provenance) |prov| {
        context_mod.pushBinding(L, prov, current.runner.generation, current.workspace_id, current.session_id, current.session_file);
    } else {
        c.lua_pushnil(L);
    }
    c.lua_setfield(L, -2, "binding");

    if (provenance) |prov| {
        if (related) |peer| {
            if (peer.findLoadedExtensionById(prov.extension_id)) |peer_provenance| {
                context_mod.pushBinding(L, peer_provenance, peer.generation(), peer.workspaceId(), peer.sessionId(), peer.sessionFile());
                c.lua_setfield(L, -2, switch (kind) {
                    .session_start => "previous",
                    .session_shutdown => "next",
                    else => unreachable,
                });
            }
        }
    }

    if (fork_parent_entry_id) |id| {
        if (reason == .fork) {
            _ = c.lua_pushlstring(L, id.ptr, id.len);
            c.lua_setfield(L, -2, "fork_parent_entry_id");
        }
    }
}

fn pushSessionBeforeSwitchPayload(
    L: *c.lua_State,
    reason: SessionLifecycleReason,
    current: SessionLifecycleContext,
    next: ?SessionLifecycleContext,
) !void {
    c.lua_createtable(L, 0, 3);

    _ = c.lua_pushlstring(L, "session_before_switch".ptr, "session_before_switch".len);
    c.lua_setfield(L, -2, "type");

    const reason_str = sessionLifecycleReasonString(reason);
    _ = c.lua_pushlstring(L, reason_str.ptr, reason_str.len);
    c.lua_setfield(L, -2, "reason");

    if (current.session_file) |path| {
        _ = c.lua_pushlstring(L, path.ptr, path.len);
        c.lua_setfield(L, -2, "current_session_file");
    }

    if (next) |peer| {
        if (peer.session_file) |path| {
            _ = c.lua_pushlstring(L, path.ptr, path.len);
            c.lua_setfield(L, -2, "target_session_file");
        }
    }
}

fn pushSessionBeforeForkPayload(
    L: *c.lua_State,
    current: SessionLifecycleContext,
    entry_id: []const u8,
) !void {
    c.lua_createtable(L, 0, 3);

    _ = c.lua_pushlstring(L, "session_before_fork".ptr, "session_before_fork".len);
    c.lua_setfield(L, -2, "type");

    _ = c.lua_pushlstring(L, "fork".ptr, "fork".len);
    c.lua_setfield(L, -2, "reason");

    _ = c.lua_pushlstring(L, entry_id.ptr, entry_id.len);
    c.lua_setfield(L, -2, "entry_id");

    if (current.session_file) |path| {
        _ = c.lua_pushlstring(L, path.ptr, path.len);
        c.lua_setfield(L, -2, "current_session_file");
    }
}

fn sessionLifecycleReasonString(reason: SessionLifecycleReason) []const u8 {
    return switch (reason) {
        .startup => "startup",
        .new => "new",
        .@"resume" => "resume",
        .exit => "exit",
        .fork => "fork",
    };
}

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

// These two adapters plug into the agent's `BeforeToolCallHook` and
// `AfterToolCallHook` slots. Unlike the observer path, they have a
// return value that the agent loop consumes — block decisions, arg
// replacements, content rewrites — so the dispatch primitive used
// MUST match the event's semantics() (cancellable for tool_call,
// transformable for tool_result).
//
// Ownership: any memory the loop must hold past the hook return
// (replacement args, replacement content, block reasons) is allocated
// from the runner's hook arena. That arena lives for the runner's
// generation; v1 leaks within a session and resets at session end.
// See `extensions/runner.zig` § hook_arena field doc.
//
// `signal` is currently unused — the cancellable chain doesn't poll
// it because Lua handlers run synchronously to completion. If a
// future host function yields (zi.spawn, ctx.ui.prompt), the
// dispatcher will need to thread abort checks into its resume loop.

/// Adapter matching `agent_protocol.BeforeToolCallHook.func`. Routes
/// the agent's `tool_call` event through the cancellable dispatch
/// chain. The runner pointer comes in as `hook_ctx`.
///
/// Behavior:
///   - No `.tool_call` handlers registered → returns null (the loop
///     uses prepared args unchanged, no allocation occurs).
///   - Any handler returns `{ block = true, reason = ... }` →
///     returns BeforeToolCallResult with block=true and the reason.
///   - Otherwise → reads back `payload.args` (which handlers may
///     have mutated in place via shared-table semantics) and
///     returns it as the replacement args. Always cloning is
///     simpler than detecting mutation; the cost is one
///     deep-clone per tool call when extensions are loaded.
pub fn beforeToolCall(
    ctx_arg: agent_protocol.BeforeToolCallContext,
    signal: abort_signal_mod.AbortSignal,
    hook_ctx: ?*anyopaque,
) ?agent_protocol.BeforeToolCallResult {
    _ = signal;
    const runner: *runner_mod.ExtensionRunner = @ptrCast(@alignCast(hook_ctx.?));
    return beforeToolCallImpl(runner, ctx_arg) catch |err| {
        log.warn("beforeToolCall dispatch failed: {s}", .{@errorName(err)});
        return null;
    };
}

fn beforeToolCallImpl(
    runner: *runner_mod.ExtensionRunner,
    ctx_arg: agent_protocol.BeforeToolCallContext,
) !?agent_protocol.BeforeToolCallResult {
    const state = runner.lua_state orelse return null;
    if (runner.event_registry.handlers(.tool_call).len == 0) return null;

    runner.assertOnLuaThread();

    try pushToolCallPayload(state.L, ctx_arg.tool_call, ctx_arg.args);
    defer c.lua_pop(state.L, 1);

    const hook_alloc = runner.hookAllocator();
    const cancel = try dispatch.dispatchCancellable(state, runner, .tool_call, -1, hook_alloc);

    if (cancel.blocked) {
        // Reason already lives in hook_arena (dispatchCancellable
        // allocated it via hook_alloc). Don't deinit — we hand the
        // pointer to the loop and the arena owns its lifetime.
        return .{ .block = true, .reason = cancel.reason, .args = null };
    }

    // Read the (possibly mutated) `args` field back from the payload
    // table at the top of the main stack. luaValueToJsonLimited allocates
    // into hook_alloc so the value lives until the runner is destroyed.
    _ = c.lua_getfield(state.L, -1, "args");
    defer c.lua_pop(state.L, 1);
    var budget = lua_runtime.JsonConvertBudget{ .limits = lua_runtime.default_json_convert_limits };
    const new_args = lua_runtime.luaValueToJsonLimited(state.L, -1, hook_alloc, &budget) catch |err| {
        log.warn("beforeToolCall: failed to read mutated args: {s}", .{@errorName(err)});
        return null;
    };
    return .{ .block = false, .reason = null, .args = new_args };
}

/// Adapter matching `agent_protocol.AfterToolCallHook.func`. Routes
/// the agent's `tool_result` event through the transformable
/// dispatch chain. Returns AfterToolCallResult with the (possibly
/// rewritten) content and is_error flag.
///
/// Behavior:
///   - No `.tool_result` handlers → returns null (loop keeps
///     original content + is_error).
///   - Otherwise → builds a payload table with the result fields,
///     runs the chain, parses content + is_error from the final
///     JSON, returns them. Content blocks are restricted to text
///     in v1 — image rewrites would need their own builder/parser
///     and are out of scope.
pub fn afterToolCall(
    ctx_arg: agent_protocol.AfterToolCallContext,
    signal: abort_signal_mod.AbortSignal,
    hook_ctx: ?*anyopaque,
) ?agent_protocol.AfterToolCallResult {
    _ = signal;
    const runner: *runner_mod.ExtensionRunner = @ptrCast(@alignCast(hook_ctx.?));
    return afterToolCallImpl(runner, ctx_arg) catch |err| {
        log.warn("afterToolCall dispatch failed: {s}", .{@errorName(err)});
        return null;
    };
}

fn afterToolCallImpl(
    runner: *runner_mod.ExtensionRunner,
    ctx_arg: agent_protocol.AfterToolCallContext,
) !?agent_protocol.AfterToolCallResult {
    const state = runner.lua_state orelse return null;
    if (runner.event_registry.handlers(.tool_result).len == 0) return null;

    runner.assertOnLuaThread();

    try pushToolResultPayload(state.L, ctx_arg.tool_call, ctx_arg.result);
    defer c.lua_pop(state.L, 1);

    const hook_alloc = runner.hookAllocator();
    const final = try dispatch.dispatchTransformable(state, runner, .tool_result, -1, hook_alloc);

    if (final != .object) return null;
    const obj = final.object;

    var result: agent_protocol.AfterToolCallResult = .{};

    if (obj.get("is_error")) |v| switch (v) {
        .bool => |b| result.is_error = b,
        else => {},
    };

    if (obj.get("content")) |v| {
        if (parseContentArray(hook_alloc, v)) |blocks| {
            result.content = blocks;
        } else |err| {
            log.warn("afterToolCall: invalid content array: {s}", .{@errorName(err)});
        }
    }

    return result;
}

fn readBlockResult(L: *c.lua_State, idx: c_int, allocator: std.mem.Allocator) !?InputMiddlewareResult {
    _ = c.lua_getfield(L, idx, "block");
    const blocked = c.lua_toboolean(L, -1) != 0;
    c.lua_pop(L, 1);
    if (!blocked) return null;
    return .{ .blocked = try readOptionalStringFieldOwned(L, idx, "reason", allocator) };
}

fn readInputActionResult(L: *c.lua_State, idx: c_int, allocator: std.mem.Allocator) !?InputMiddlewareResult {
    _ = c.lua_getfield(L, idx, "action");
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TSTRING) return null;
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, -1, &len) orelse return null;
    const action = ptr[0..len];
    if (std.mem.eql(u8, action, "continue")) return .continue_;
    if (std.mem.eql(u8, action, "handled")) return .{ .handled = try readOptionalStringFieldOwned(L, idx, "reason", allocator) };
    if (std.mem.eql(u8, action, "transform")) {
        const text = try readOptionalStringFieldOwned(L, idx, "text", allocator) orelse return .continue_;
        return .{ .transform = text };
    }
    return null;
}

fn readOptionalStringFieldOwned(L: *c.lua_State, idx: c_int, field: [:0]const u8, allocator: std.mem.Allocator) !?[]const u8 {
    _ = c.lua_getfield(L, idx, field.ptr);
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TSTRING) return null;
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, -1, &len) orelse return null;
    return try allocator.dupe(u8, ptr[0..len]);
}

fn readPayloadSystemPrompt(L: *c.lua_State, idx: c_int, allocator: std.mem.Allocator) !?[]const u8 {
    return readOptionalStringFieldOwned(L, idx, "system_prompt", allocator);
}

fn setPayloadSystemPrompt(L: *c.lua_State, idx: c_int, prompt: []const u8) void {
    const abs_idx = c.lua_absindex(L, idx);
    _ = c.lua_pushlstring(L, prompt.ptr, prompt.len);
    c.lua_setfield(L, abs_idx, "system_prompt");
}

fn pushBeforeAgentStartPayload(L: *c.lua_State, system_prompt: []const u8, options: BeforeAgentStartOptions) !void {
    c.lua_createtable(L, 0, 3);
    _ = c.lua_pushlstring(L, "before_agent_start".ptr, "before_agent_start".len);
    c.lua_setfield(L, -2, "type");
    _ = c.lua_pushlstring(L, system_prompt.ptr, system_prompt.len);
    c.lua_setfield(L, -2, "system_prompt");
    try pushSystemPromptOptions(L, options);
    c.lua_setfield(L, -2, "system_prompt_options");
}

fn pushSystemPromptOptions(L: *c.lua_State, options: BeforeAgentStartOptions) !void {
    c.lua_createtable(L, 0, 4);
    _ = c.lua_pushlstring(L, options.cwd.ptr, options.cwd.len);
    c.lua_setfield(L, -2, "cwd");

    c.lua_createtable(L, @intCast(options.selected_tools.len), 0);
    for (options.selected_tools, 0..) |name, i| {
        _ = c.lua_pushlstring(L, name.ptr, name.len);
        c.lua_rawseti(L, -2, @intCast(i + 1));
    }
    c.lua_setfield(L, -2, "selected_tools");

    c.lua_createtable(L, @intCast(options.skills.len), 0);
    for (options.skills, 0..) |skill, i| {
        c.lua_createtable(L, 0, 3);
        _ = c.lua_pushlstring(L, skill.name.ptr, skill.name.len);
        c.lua_setfield(L, -2, "name");
        _ = c.lua_pushlstring(L, skill.description.ptr, skill.description.len);
        c.lua_setfield(L, -2, "description");
        _ = c.lua_pushlstring(L, skill.file_path.ptr, skill.file_path.len);
        c.lua_setfield(L, -2, "file_path");
        c.lua_rawseti(L, -2, @intCast(i + 1));
    }
    c.lua_setfield(L, -2, "skills");

    c.lua_createtable(L, @intCast(options.append_system_prompt.len), 0);
    for (options.append_system_prompt, 0..) |append, i| {
        _ = c.lua_pushlstring(L, append.ptr, append.len);
        c.lua_rawseti(L, -2, @intCast(i + 1));
    }
    c.lua_setfield(L, -2, "append_system_prompt");
}

fn pushInputPayload(L: *c.lua_State, text: []const u8, queued_kind: ?[]const u8) !void {
    c.lua_createtable(L, 0, 5);
    _ = c.lua_pushlstring(L, "input".ptr, "input".len);
    c.lua_setfield(L, -2, "type");
    _ = c.lua_pushlstring(L, text.ptr, text.len);
    c.lua_setfield(L, -2, "text");
    _ = c.lua_pushlstring(L, "user".ptr, "user".len);
    c.lua_setfield(L, -2, "source");
    c.lua_pushboolean(L, if (queued_kind != null) 1 else 0);
    c.lua_setfield(L, -2, "queued");
    if (queued_kind) |kind| {
        _ = c.lua_pushlstring(L, kind.ptr, kind.len);
    } else {
        c.lua_pushnil(L);
    }
    c.lua_setfield(L, -2, "queue_kind");
}

/// Push `{ tool_call = {id, name}, tool_name, args }` onto the stack.
fn pushToolCallPayload(
    L: *c.lua_State,
    tool_call: ai_protocol.ToolCall,
    args: std.json.Value,
) lua_runtime.ConvertError!void {
    c.lua_createtable(L, 0, 3);

    c.lua_createtable(L, 0, 2);
    _ = c.lua_pushlstring(L, tool_call.id.ptr, tool_call.id.len);
    c.lua_setfield(L, -2, "id");
    _ = c.lua_pushlstring(L, tool_call.name.ptr, tool_call.name.len);
    c.lua_setfield(L, -2, "name");
    c.lua_setfield(L, -2, "tool_call");

    _ = c.lua_pushlstring(L, tool_call.name.ptr, tool_call.name.len);
    c.lua_setfield(L, -2, "tool_name");

    try lua_runtime.pushJsonValue(L, args);
    c.lua_setfield(L, -2, "args");
}

/// Push `{ tool_call = {id, name}, tool_name, content = [...], is_error }`.
fn pushToolResultPayload(
    L: *c.lua_State,
    tool_call: ai_protocol.ToolCall,
    result: agent_protocol.AgentToolResult,
) lua_runtime.ConvertError!void {
    c.lua_createtable(L, 0, 4);

    c.lua_createtable(L, 0, 2);
    _ = c.lua_pushlstring(L, tool_call.id.ptr, tool_call.id.len);
    c.lua_setfield(L, -2, "id");
    _ = c.lua_pushlstring(L, tool_call.name.ptr, tool_call.name.len);
    c.lua_setfield(L, -2, "name");
    c.lua_setfield(L, -2, "tool_call");

    _ = c.lua_pushlstring(L, tool_call.name.ptr, tool_call.name.len);
    c.lua_setfield(L, -2, "tool_name");

    c.lua_createtable(L, @intCast(result.content.len), 0);
    for (result.content, 0..) |block, i| {
        switch (block) {
            .text => |t| {
                c.lua_createtable(L, 0, 2);
                _ = c.lua_pushstring(L, "text");
                c.lua_setfield(L, -2, "type");
                _ = c.lua_pushlstring(L, t.text.ptr, t.text.len);
                c.lua_setfield(L, -2, "text");
            },
            .image => |img| {
                c.lua_createtable(L, 0, 3);
                _ = c.lua_pushstring(L, "image");
                c.lua_setfield(L, -2, "type");
                _ = c.lua_pushlstring(L, img.mime_type.ptr, img.mime_type.len);
                c.lua_setfield(L, -2, "mime_type");
                _ = c.lua_pushlstring(L, img.data.ptr, img.data.len);
                c.lua_setfield(L, -2, "data");
            },
        }
        c.lua_rawseti(L, -2, @intCast(i + 1));
    }
    c.lua_setfield(L, -2, "content");

    c.lua_pushboolean(L, if (result.is_error) 1 else 0);
    c.lua_setfield(L, -2, "is_error");
}

/// Parse a JSON array of `{type, text}` (text only in v1) into
/// owned ContentBlocks. Strings are duped from the supplied
/// allocator (the hook arena in the live path).
fn parseContentArray(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !?[]const agent_protocol.AgentToolResult.ContentBlock {
    if (value != .array) return null;
    const items = value.array.items;

    const out = try allocator.alloc(agent_protocol.AgentToolResult.ContentBlock, items.len);
    var n: usize = 0;
    for (items) |item| {
        if (item != .object) continue;
        const obj = item.object;
        const ty = obj.get("type") orelse continue;
        if (ty != .string) continue;
        if (std.mem.eql(u8, ty.string, "text")) {
            const txt = obj.get("text") orelse continue;
            if (txt != .string) continue;
            out[n] = .{ .text = .{ .text = try allocator.dupe(u8, txt.string) } };
            n += 1;
        }
    }
    return out[0..n];
}

const testing = std.testing;
const api = @import("api.zig");

test "semantic message event exposes assistant text and tool calls" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();
    runner.attachLuaState(&state);
    api.installZiTable(&state, &runner);

    try state.doString(
        \\_semantic = {}
        \\zi.on("message", function(event, ctx)
        \\  table.insert(_semantic, event.message.entry_id .. ":" .. event.message.role .. ":" .. (event.message.text or event.message.tool_name or ""))
        \\end)
    , "subscribe_semantic_message");

    var args: std.json.ObjectMap = .{};
    defer args.deinit(testing.allocator);
    const content = [_]ai_protocol.AssistantMessage.AssistantContentBlock{
        .{ .text = .{ .text = "hello" } },
        .{ .tool_call = .{ .id = "call-1", .name = "todo", .arguments = .{ .object = args } } },
    };
    const fake_assistant = agent_protocol.AgentMessage{ .assistant = .{
        .content = &content,
        .api = .{ .anthropic_messages = {} },
        .provider = .{ .anthropic = {} },
        .model = "test",
        .usage = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total_tokens = 0, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 } },
        .stop_reason = .stop,
        .timestamp = 0,
    } };

    try dispatchSemanticMessage(&runner, fake_assistant, "entry-1");

    try state.doString(
        \\assert(#_semantic == 2, "expected 2 semantic messages, got " .. #_semantic)
        \\assert(_semantic[1] == "entry-1:tool_call:todo", _semantic[1])
        \\assert(_semantic[2] == "entry-1:assistant:hello", _semantic[2])
    , "verify_semantic_message");
}

test "before_agent_start transforms system prompt and exposes options" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();
    runner.attachLuaState(&state);
    api.installZiTable(&state, &runner);

    try state.doString(
        \\zi.on("before_agent_start", function(event, ctx)
        \\  local opts = event.system_prompt_options
        \\  event.system_prompt = event.system_prompt .. " " .. opts.selected_tools[1] .. " " .. opts.skills[1].name
        \\end)
        \\zi.on("before_agent_start", function(event, ctx)
        \\  return { system_prompt = event.system_prompt .. " marker" }
        \\end)
    , "subscribe_before_agent_start");

    const tool_names = [_][]const u8{"bash"};
    const skill_list = [_]resource_types.Skill{.{ .name = "zig", .description = "zig skill", .file_path = "zig.md", .base_dir = ".", .source_info = .{ .path = "zig.md", .source = "test" } }};
    const result = try dispatchBeforeAgentStart(&runner, "base", .{ .cwd = ".", .selected_tools = &tool_names, .skills = &skill_list, .append_system_prompt = &.{} }, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("base bash zig marker", result);
}

test "input middleware transforms text before agent submission" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();
    runner.attachLuaState(&state);
    api.installZiTable(&state, &runner);

    try state.doString(
        \\zi.on("input", function(event, ctx)
        \\  if string.sub(event.text, 1, 7) == "?quick " then
        \\    return { action = "transform", text = "Brief: " .. string.sub(event.text, 8) }
        \\  end
        \\end)
    , "subscribe_input_transform");

    const result = try dispatchInput(&runner, "?quick hello", null, testing.allocator);
    switch (result) {
        .transform => |text| {
            defer testing.allocator.free(text);
            try testing.expectEqualStrings("Brief: hello", text);
        },
        else => return error.ExpectedTransform,
    }
}

test "input middleware handled action stops agent submission" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();
    runner.attachLuaState(&state);
    api.installZiTable(&state, &runner);

    try state.doString(
        \\zi.on("input", function(event, ctx)
        \\  if event.text == "ping" then return { action = "handled" } end
        \\end)
    , "subscribe_input_handled");

    const result = try dispatchInput(&runner, "ping", null, testing.allocator);
    try testing.expect(result == .handled);
}

test "beforeToolCall blocks tool execution when handler returns block=true" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();
    runner.attachLuaState(&state);
    api.installZiTable(&state, &runner);

    try state.doString(
        \\zi.on("tool_call", function(event, ctx)
        \\  if event.tool_name == "Bash" and event.args.command == "rm -rf /" then
        \\    return { block = true, reason = "nope" }
        \\  end
        \\end)
    , "subscribe");

    var args_obj: std.json.ObjectMap = .{};
    defer args_obj.deinit(testing.allocator);
    try args_obj.put(testing.allocator, "command", .{ .string = "rm -rf /" });

    const tc = ai_protocol.ToolCall{
        .id = "id-1",
        .name = "Bash",
        .arguments = .{ .object = args_obj },
    };
    const ctx = agent_protocol.BeforeToolCallContext{
        .assistant_message = undefined,
        .tool_call = tc,
        .args = .{ .object = args_obj },
        .context = .{ .system_prompt = "", .messages = &.{} },
    };

    const result = beforeToolCall(ctx, abort_signal_mod.AbortSignal.none, @ptrCast(&runner));
    try testing.expect(result != null);
    try testing.expect(result.?.block);
    try testing.expectEqualStrings("nope", result.?.reason.?);
}

test "beforeToolCall returns mutated args when handler rewrites them" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();
    runner.attachLuaState(&state);
    api.installZiTable(&state, &runner);

    try state.doString(
        \\zi.on("tool_call", function(event, ctx)
        \\  event.args.command = "echo safe"
        \\end)
    , "subscribe");

    var args_obj: std.json.ObjectMap = .{};
    defer args_obj.deinit(testing.allocator);
    try args_obj.put(testing.allocator, "command", .{ .string = "rm -rf /" });

    const tc = ai_protocol.ToolCall{
        .id = "id-2",
        .name = "Bash",
        .arguments = .{ .object = args_obj },
    };
    const ctx = agent_protocol.BeforeToolCallContext{
        .assistant_message = undefined,
        .tool_call = tc,
        .args = .{ .object = args_obj },
        .context = .{ .system_prompt = "", .messages = &.{} },
    };

    const result = beforeToolCall(ctx, abort_signal_mod.AbortSignal.none, @ptrCast(&runner));
    try testing.expect(result != null);
    try testing.expect(!result.?.block);

    const new_args = result.?.args.?;
    try testing.expect(new_args == .object);
    const cmd = new_args.object.get("command").?;
    try testing.expectEqualStrings("echo safe", cmd.string);
}

test "afterToolCall transforms result content via transformable chain" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();
    runner.attachLuaState(&state);
    api.installZiTable(&state, &runner);

    try state.doString(
        \\zi.on("tool_result", function(event, ctx)
        \\  return {
        \\    tool_call = event.tool_call,
        \\    tool_name = event.tool_name,
        \\    content = { { type = "text", text = "REDACTED" } },
        \\    is_error = event.is_error,
        \\  }
        \\end)
    , "subscribe");

    const blocks = [_]agent_protocol.AgentToolResult.ContentBlock{
        .{ .text = .{ .text = "secret token: abc123" } },
    };
    const tool_result = agent_protocol.AgentToolResult{
        .content = &blocks,
        .is_error = false,
    };

    const tc = ai_protocol.ToolCall{
        .id = "id-3",
        .name = "Bash",
        .arguments = .{ .null = {} },
    };
    const ctx = agent_protocol.AfterToolCallContext{
        .assistant_message = undefined,
        .tool_call = tc,
        .args = .{ .null = {} },
        .result = tool_result,
        .is_error = false,
        .context = .{ .system_prompt = "", .messages = &.{} },
    };

    const result = afterToolCall(ctx, abort_signal_mod.AbortSignal.none, @ptrCast(&runner));
    try testing.expect(result != null);
    try testing.expect(result.?.content != null);

    const new_content = result.?.content.?;
    try testing.expectEqual(@as(usize, 1), new_content.len);
    try testing.expectEqualStrings("REDACTED", new_content[0].text.text);
}

test "lifecycle observer delivers null-provenance handler with nil binding" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();
    runner.attachLuaState(&state);

    try state.doString(
        \\_received_binding = "UNSET"
        \\function handler(event, ctx)
        \\  if event.binding == nil then
        \\    _received_binding = "NIL"
        \\  else
        \\    _received_binding = "SET"
        \\  end
        \\end
    , "setup");

    _ = c.lua_getglobal(state.L, "handler");
    const ref = c.luaL_ref(state.L, c.LUA_REGISTRYINDEX);

    try runner.event_registry.subscribe(.session_start, .{
        .lua_ref = ref,
        .source_id = "null-test",
        .provenance = null,
    });

    try dispatchSessionStart(.{
        .runner = &runner,
        .workspace_id = "ws",
        .session_id = "sess",
    }, null, .startup, null);

    try state.doString(
        \\assert(_received_binding == "NIL", "expected binding nil, got " .. tostring(_received_binding))
    , "verify");
}

test "dispatchModelSelect exposes model, previous_model, and source" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();
    runner.attachLuaState(&state);

    api.installZiTable(&state, &runner);

    try state.doString(
        \\_seen_model = nil
        \\_seen_prev = nil
        \\_seen_source = nil
        \\zi.on("model_select", function(event, ctx)
        \\  _seen_model = event.model.id
        \\  _seen_prev = event.previous_model and event.previous_model.id or nil
        \\  _seen_source = event.source
        \\end)
    , "subscribe");

    const prev_model = agent_protocol.Model{
        .id = "prev-model",
        .name = "Previous",
        .api = .{ .openai_completions = {} },
        .provider = .{ .openai = {} },
        .base_url = "",
        .reasoning = false,
        .input = &.{.text},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 1000,
        .max_tokens = 100,
    };

    const next_model = agent_protocol.Model{
        .id = "next-model",
        .name = "Next",
        .api = .{ .anthropic_messages = {} },
        .provider = .{ .anthropic = {} },
        .base_url = "",
        .reasoning = true,
        .input = &.{ .text, .image },
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 2000,
        .max_tokens = 200,
    };

    dispatchModelSelect(&runner, next_model, prev_model, "set");

    try state.doString(
        \\assert(_seen_model == "next-model", "model: " .. tostring(_seen_model))
        \\assert(_seen_prev == "prev-model", "previous: " .. tostring(_seen_prev))
        \\assert(_seen_source == "set", "source: " .. tostring(_seen_source))
    , "verify");
}
