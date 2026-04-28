//! Adapter that wraps a registered Lua tool as an `AgentTool`.
//!
//! When the agent dispatches a tool by name, this executor:
//!   1. Spawns a fresh coroutine on the runner's Lua state.
//!   2. Resolves the handler ref from the registry.
//!   3. Pushes the tool args as a Lua table (via `pushJsonValue`).
//!   4. Resumes the coroutine; parses the return into an
//!      `AgentToolResult`.
//!
//! Accepted return shapes from the Lua handler:
//!   - `string`                          → single text block, success
//!   - `{ content = "string", is_error? = bool }`
//!   - `{ content = { {type="text", text="..."} ... }, is_error? = bool }`
//!   - `nil` or anything else            → empty success
//!
//! Ownership: the agent loop's `aa` arena is what we get as
//! `allocator` here. Every owned slice in the returned result is
//! duped from THAT allocator, so the loop can use the result for
//! the rest of the iteration without us caring about lifetimes.
//! The handler ref + runner pointer come from a per-tool
//! `LuaToolCtx` allocated from the runner's allocator at build
//! time — those live for the runner generation.

const std = @import("std");
const lua_runtime = @import("lua_runtime.zig");
const runner_mod = @import("runner.zig");
const tool_registry = @import("registries/tool_registry.zig");
const agent_protocol = @import("../../agent3/types.zig");
const abort_signal_mod = @import("../../abort_signal.zig");
const ai = @import("../../ai/root.zig");
const api = @import("api.zig");
const lua_renderer = @import("lua_renderer.zig");
const context_mod = @import("context.zig");
const resource_types = @import("../resources/types.zig");
const extension_ui = @import("ui.zig");
const request_mod = @import("../request.zig");
const spawn_mod = @import("../../spawn/spawn.zig");
const spawn_types = @import("../../spawn/types.zig");
const builtins_mod = @import("../tools/builtins.zig");
const tool_def = @import("../tools/definition.zig");
const tool_display = @import("../../tui/tool_display.zig");
const builtin_renderers = @import("../../tui/renderers/builtins.zig");

const c = lua_runtime.c;
const log = std.log.scoped(.zi_lua_tool);

const AgentToolResult = agent_protocol.AgentToolResult;

/// Per-tool execution context. The `AgentTool.ctx` slot is one
/// pointer; we use it to find the runner (for the lua_state),
/// the handler ref, and the tool name (for routing render-hook
/// dispatch back through `runner.tool_registry`).
pub const LuaToolCtx = struct {
    runner: *runner_mod.ExtensionRunner,
    lua_ref: c_int,
    provenance: ?resource_types.ExtensionProvenance,
    /// Borrowed from `ToolDefinition.name` in the runner's tool
    /// registry. Lifetime matches the runner generation.
    name: []const u8,
};

/// Build an `AgentTool` from a registered ToolDefinition.
///
/// Borrows: `name`, `description`, `label`, `parameters` come from
/// the registry entry, which the runner already owns. The returned
/// AgentTool is only valid for the runner's generation.
///
/// Allocates: one `LuaToolCtx` from `allocator`. Caller does not
/// need to free it explicitly — the runner generation owns it.
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
        .parameters = ext_tool.parameters,
        .ctx = @ptrCast(ctx),
        .execute = &execute,
    };
}

// =============================================================================
// AgentTool.execute adapter
// =============================================================================

fn execute(
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    tool_call_id: []const u8,
    args: std.json.Value,
    signal: abort_signal_mod.AbortSignal,
    on_update: ?agent_protocol.AgentToolUpdateCallback,
    update_ctx: ?*anyopaque,
) AgentToolResult {
    const tctx: *LuaToolCtx = @ptrCast(@alignCast(ctx.?));
    const state = tctx.runner.lua_state orelse {
        return errorResult(allocator, "lua state not attached");
    };

    // Single-thread contract: only the agent thread should ever
    // call into Lua. Panics if violated. See `runner.zig`
    // `lua_owner_thread` doc for the rationale.
    tctx.runner.assertOnLuaThread();

    // Stash per-call state so host functions invoked from inside
    // the Lua handler can forward abort and partial updates for the
    // right tool. Cleared on return.
    tctx.runner.current_signal = signal;
    tctx.runner.current_update_callback = on_update;
    tctx.runner.current_update_ctx = update_ctx;
    defer {
        tctx.runner.current_signal = null;
        tctx.runner.current_update_callback = null;
        tctx.runner.current_update_ctx = null;
    }

    const result = runHandler(allocator, state, tctx.runner, tctx.lua_ref, tctx.provenance, args) catch |err| {
        log.warn("lua tool execution failed: {s}", .{@errorName(err)});
        return errorResult(allocator, @errorName(err));
    };

    _ = tool_call_id;
    _ = tctx.name;
    return result;
}

fn runHandler(
    allocator: std.mem.Allocator,
    state: *lua_runtime.LuaState,
    runner: *runner_mod.ExtensionRunner,
    handler_ref: c_int,
    provenance: ?resource_types.ExtensionProvenance,
    args: std.json.Value,
) !AgentToolResult {
    var co = try lua_runtime.Coroutine.init(state);
    defer co.deinit();

    // Push the handler.
    _ = c.lua_rawgeti(co.L, c.LUA_REGISTRYINDEX, handler_ref);
    if (c.lua_type(co.L, -1) != c.LUA_TFUNCTION) {
        c.lua_pop(co.L, 1);
        return error.HandlerNotAFunction;
    }

    // arg 1: tool args
    try lua_runtime.pushJsonValue(co.L, args);

    // arg 2: ctx table.
    // Base fields come from the bound extension runtime; tool
    // execution adds the `update(partial)` helper on top.
    try context_mod.pushExtensionContext(co.L, runner, provenance);
    c.lua_pushlightuserdata(co.L, runner);
    c.lua_pushcclosure(co.L, &luaToolUpdate, 1);
    c.lua_setfield(co.L, -2, "update");

    // Inherit the current tool's module context for nested host
    // callbacks (e.g. `zi.spawn` on_event trampolines).
    runner.setModuleContext(state, provenance);
    if (provenance) |prov| {
        runner.beginExecutionContext(runner.sourceForProvenance(prov));
        defer runner.endExecutionContext();
    }

    while (true) {
        const r = try co.resumeWith(2);
        switch (r.status) {
            .yielded => {
                try serviceYieldedToolCoroutine(allocator, runner, state, &co, r.nresults);
                continue;
            },
            .ok, .finished => {
                if (r.nresults == 0) return emptyResult();

                const top = c.lua_gettop(co.L);
                defer c.lua_settop(co.L, top - r.nresults);
                return parseReturn(allocator, co.L, top);
            },
        }
    }
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

    var req = runner.current_spawn_request orelse return error.UnexpectedYield;
    defer {
        if (req.callbacks_ref != c.LUA_NOREF) c.luaL_unref(req.source_L, c.LUA_REGISTRYINDEX, req.callbacks_ref);
        req.deinit(runner.allocator);
        runner.current_spawn_request = null;
    }

    var trampoline_ctx = api.TrampolineCtx{
        .L = co.L,
        .callbacks_ref = req.callbacks_ref,
    };

    const cfg = spawn_types.SpawnConfig{
        .allocator = runner.allocator,
        .cwd = req.cwd,
        .task = req.task,
        .model = req.model,
        .tools = req.tools,
        .append_system_prompt = req.append_system_prompt,
        .signal = runner.current_signal,
        .on_event = if (req.callbacks_ref != c.LUA_NOREF) &api.eventTrampoline else null,
        .on_event_ctx = if (req.callbacks_ref != c.LUA_NOREF) @ptrCast(&trampoline_ctx) else null,
    };

    var spawn_result = spawn_mod.ziSpawn(cfg);
    defer spawn_result.deinit(runner.allocator);

    runner.current_spawn_result = .{ .result = try spawnResultToToolResult(allocator, spawn_result) };
}

fn spawnResultToToolResult(allocator: std.mem.Allocator, spawn_result: spawn_types.SpawnResult) !AgentToolResult {
    const text = spawn_result.text() orelse "";
    var result = try textResult(allocator, text, spawn_result.exit_code != 0);

    var out = std.json.ObjectMap.init(allocator);
    errdefer {
        const v: std.json.Value = .{ .object = out };
        lua_runtime.freeJsonValue(allocator, v);
    }

    try out.put(try allocator.dupe(u8, "cancelled"), .{ .bool = spawn_result.cancelled });
    if (spawn_result.model) |m| try out.put(try allocator.dupe(u8, "model"), .{ .string = try allocator.dupe(u8, m) });
    if (spawn_result.stop_reason) |sr| try out.put(try allocator.dupe(u8, "stop_reason"), .{ .string = try allocator.dupe(u8, sr) });
    if (spawn_result.error_message) |em| try out.put(try allocator.dupe(u8, "error_message"), .{ .string = try allocator.dupe(u8, em) });

    var usage = std.json.ObjectMap.init(allocator);
    try usage.put(try allocator.dupe(u8, "input"), .{ .integer = @intCast(spawn_result.usage.input) });
    try usage.put(try allocator.dupe(u8, "output"), .{ .integer = @intCast(spawn_result.usage.output) });
    try usage.put(try allocator.dupe(u8, "cache_read"), .{ .integer = @intCast(spawn_result.usage.cache_read) });
    try usage.put(try allocator.dupe(u8, "cache_write"), .{ .integer = @intCast(spawn_result.usage.cache_write) });
    try usage.put(try allocator.dupe(u8, "total_tokens"), .{ .integer = @intCast(spawn_result.usage.context_tokens) });
    try usage.put(try allocator.dupe(u8, "cost"), .{ .float = spawn_result.usage.cost });
    try usage.put(try allocator.dupe(u8, "turns"), .{ .integer = @intCast(spawn_result.usage.turns) });
    try out.put(try allocator.dupe(u8, "usage"), .{ .object = usage });

    result.details = .{ .object = out };
    return result;
}

// =============================================================================
// Return value parsing
// =============================================================================

fn parseReturn(
    allocator: std.mem.Allocator,
    L: *c.lua_State,
    idx: c_int,
) !AgentToolResult {
    const ty = c.lua_type(L, idx);

    if (ty == c.LUA_TSTRING) {
        return try textResult(allocator, lstring(L, idx), false);
    }

    if (ty == c.LUA_TTABLE) {
        // Read is_error first so the early-out paths still set it.
        _ = c.lua_getfield(L, idx, "is_error");
        const is_error = c.lua_toboolean(L, -1) != 0;
        c.lua_pop(L, 1);

        // Read `details` (optional, deep-cloned via
        // luaValueToJson). Tools like Task put their tree state
        // here so render hooks can draw a rich display. Without
        // this extraction the final render would see empty
        // details and collapse to just the header row.
        var details: std.json.Value = .null;
        _ = c.lua_getfield(L, idx, "details");
        if (c.lua_type(L, -1) != c.LUA_TNIL) {
            details = lua_runtime.luaValueToJson(L, -1, allocator) catch .null;
        }
        c.lua_pop(L, 1);

        // Inspect the content field.
        _ = c.lua_getfield(L, idx, "content");
        defer c.lua_pop(L, 1);

        const content_ty = c.lua_type(L, -1);

        if (content_ty == c.LUA_TSTRING) {
            var result = try textResult(allocator, lstring(L, -1), is_error);
            result.details = details;
            return result;
        }

        if (content_ty == c.LUA_TTABLE) {
            const blocks = try parseContentBlocks(allocator, L, -1);
            return .{ .content = blocks, .is_error = is_error, .details = details };
        }

        // Table with no content field → empty result with the
        // is_error flag and details honored.
        return .{ .content = &.{}, .is_error = is_error, .details = details };
    }

    // Anything else (number, bool, nil): treat as empty success.
    // Lua tools that return non-string non-table values are almost
    // always tests or mistakes; we don't want to ui_publication a tool
    // error for them.
    return emptyResult();
}

fn parseContentBlocks(
    allocator: std.mem.Allocator,
    L: *c.lua_State,
    idx: c_int,
) ![]const AgentToolResult.ContentBlock {
    const len = c.lua_rawlen(L, idx);
    if (len == 0) return &.{};

    var blocks: std.ArrayListUnmanaged(AgentToolResult.ContentBlock) = .empty;
    errdefer blocks.deinit(allocator);

    var i: c.lua_Integer = 1;
    while (i <= @as(c.lua_Integer, @intCast(len))) : (i += 1) {
        _ = c.lua_rawgeti(L, idx, i);
        defer c.lua_pop(L, 1);

        if (c.lua_type(L, -1) != c.LUA_TTABLE) continue;

        _ = c.lua_getfield(L, -1, "text");
        defer c.lua_pop(L, 1);
        if (c.lua_type(L, -1) != c.LUA_TSTRING) continue;

        const text = try allocator.dupe(u8, lstring(L, -1));
        try blocks.append(allocator, .{ .text = .{ .text = text } });
    }
    return blocks.items;
}

// =============================================================================
// Result helpers
// =============================================================================

fn textResult(
    allocator: std.mem.Allocator,
    text: []const u8,
    is_error: bool,
) !AgentToolResult {
    const dup = try allocator.dupe(u8, text);
    const blocks = try allocator.alloc(AgentToolResult.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = dup } };
    return .{ .content = blocks, .is_error = is_error };
}

fn emptyResult() AgentToolResult {
    return .{ .content = &.{}, .is_error = false };
}

/// Best-effort error result. Allocation failures fall back to an
/// empty error so the agent loop never sees an exception from a
/// tool that simply failed inside Lua.
fn errorResult(allocator: std.mem.Allocator, message: []const u8) AgentToolResult {
    return textResult(allocator, message, true) catch .{
        .content = &.{},
        .is_error = true,
    };
}

/// Read a Lua string at `idx` as a zig slice. The slice points
/// into Lua-managed memory and is only valid until the value is
/// popped — callers MUST dupe immediately if they need to hold it.
fn lstring(L: *c.lua_State, idx: c_int) []const u8 {
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, idx, &len) orelse return &.{};
    return ptr[0..len];
}

// =============================================================================
// ctx.update host function
// =============================================================================

/// `ctx.update(partial)` — Lua-callable that forwards a partial
/// tool result back through the agent loop. Used by long-running
/// tools (Task, Oracle, anything that wraps `zi.spawn`) to ui_publication
/// progressive state to the TUI without waiting for `execute` to
/// return.
///
/// Lua signature: `ctx.update({ content?, is_error?, details? })`
///
///   - `content`  optional content blocks (defaults to `{}`)
///   - `is_error` optional bool flag
///   - `details`  optional table; deep-cloned via luaValueToJson
///
/// Lifetime: every owned slice for the partial result is allocated
/// from a stack-scoped arena that lives only for the duration of
/// this call. The downstream `tool_execution_update` event handler
/// (`interactive.zig` event-queue translator) deep-copies what it
/// needs into its own allocator before this returns, so the arena
/// is safe to drop.
fn luaToolUpdate(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const ud = c.lua_touserdata(L, c.lua_upvalueindex(1));
    const runner: *runner_mod.ExtensionRunner = @ptrCast(@alignCast(ud.?));

    const cb = runner.current_update_callback orelse return 0;

    if (c.lua_type(L, 1) != c.LUA_TTABLE) return 0;

    var arena = std.heap.ArenaAllocator.init(runner.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // -- is_error --
    var is_error = false;
    _ = c.lua_getfield(L, 1, "is_error");
    if (c.lua_type(L, -1) == c.LUA_TBOOLEAN) is_error = c.lua_toboolean(L, -1) != 0;
    c.lua_pop(L, 1);

    // -- content (optional, may be table or absent) --
    var content_blocks: []const AgentToolResult.ContentBlock = &.{};
    _ = c.lua_getfield(L, 1, "content");
    if (c.lua_type(L, -1) == c.LUA_TTABLE) {
        content_blocks = parseContentBlocks(aa, L, -1) catch &.{};
    }
    c.lua_pop(L, 1);

    // -- details (optional json value, deep-cloned via luaValueToJson) --
    var details: std.json.Value = .null;
    _ = c.lua_getfield(L, 1, "details");
    if (c.lua_type(L, -1) != c.LUA_TNIL) {
        details = lua_runtime.luaValueToJson(L, -1, aa) catch .null;
    }
    c.lua_pop(L, 1);

    const partial = AgentToolResult{
        .content = content_blocks,
        .details = details,
        .is_error = is_error,
    };

    // Fire the callback. The downstream consumer clones what it
    // needs synchronously, so when this returns the arena can
    // safely free everything.
    cb(partial, runner.current_update_ctx);

    return 0;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

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
    var obj = std.json.ObjectMap.init(allocator);
    try obj.put(try allocator.dupe(u8, "id"), .{ .string = try allocator.dupe(u8, model.id) });
    try obj.put(try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, model.name) });
    try obj.put(try allocator.dupe(u8, "provider"), .{ .string = try allocator.dupe(u8, ai.json_util.providerToString(model.provider)) });
    try obj.put(try allocator.dupe(u8, "api"), .{ .string = try allocator.dupe(u8, ai.provider.apiToString(model.api)) });
    try obj.put(try allocator.dupe(u8, "context_window"), .{ .integer = @intCast(model.context_window) });
    try obj.put(try allocator.dupe(u8, "max_tokens"), .{ .integer = @intCast(model.max_tokens) });
    try obj.put(try allocator.dupe(u8, "reasoning"), .{ .bool = model.reasoning });
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
        .get_context_usage = &testGetContextUsage,
        .get_system_prompt = &testGetSystemPrompt,
        .get_binding_info = &testGetBindingInfo,
    }, &provider_registry);
    api.installZiTable(&state, &runner);

    runner.beginLoadContext(testLoadSource());
    defer runner.endLoadContext();

    try state.doString(
        \\zi.register_tool({
        \\  name = "binding",
        \\  description = "binding",
        \\  parameters = { type = "object", properties = {} },
        \\  execute = function(args, ctx)
        \\    assert(ctx.binding ~= nil)
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
    , "register_binding_tool");

    const ext_tool = runner.tool_registry.get("binding").?.*;
    const tool = try buildAgentTool(testing.allocator, &runner, ext_tool);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const result = tool.execute(
        tool.ctx,
        arena.allocator(),
        "id-binding",
        .{ .null = {} },
        abort_signal_mod.AbortSignal.none,
        null,
        null,
    );

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
        \\local function hydrate(ctx)
        \\  if not ctx or not ctx.state then return end
        \\  local saved = ctx.state.get("todos")
        \\  if type(saved) == "table" then
        \\    todos = saved.todos or {}
        \\    next_id = saved.nextId or 1
        \\  end
        \\end
        \\
        \\local function persist(ctx)
        \\  if ctx and ctx.state then
        \\    ctx.state.set("todos", { todos = clone_todos(), nextId = next_id })
        \\  end
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
        \\zi.register_tool({
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
        \\    hydrate(ctx)
        \\    local action = params.action
        \\    if action == "list" then
        \\      return { content = { { type = "text", text = list_text() } }, details = details("list") }
        \\    end
        \\    if action == "add" then
        \\      local todo = { id = next_id, text = params.text, done = false }
        \\      next_id = next_id + 1
        \\      todos[#todos + 1] = todo
        \\      persist(ctx)
        \\      return { content = { { type = "text", text = string.format("Added todo #%d: %s", todo.id, todo.text) } }, details = details("add") }
        \\    end
        \\    if action == "toggle" then
        \\      local todo = find_todo(params.id)
        \\      todo.done = not todo.done
        \\      persist(ctx)
        \\      return { content = { { type = "text", text = string.format("Todo #%d %s", todo.id, todo.done and "completed" or "uncompleted") } }, details = details("toggle") }
        \\    end
        \\    return { content = { { type = "text", text = "Unknown action" } }, is_error = true, details = details("list", "unknown action") }
        \\  end,
        \\  render_result = function(result, ctx)
        \\    local d = result.details
        \\    if d.action == "list" then
        \\      if #d.todos == 0 then return { lines = { { { text = "No todos", fg = "muted", dim = true } } } } end
        \\      local lines = { { { text = tostring(#d.todos) .. " todo(s):", fg = "muted" } } }
        \\      local limit = ctx.expanded and #d.todos or math.min(#d.todos, 5)
        \\      for i = 1, limit do
        \\        local todo = d.todos[i]
        \\        lines[#lines + 1] = {
        \\          { text = todo.done and "✓ " or "○ ", fg = todo.done and "success" or "muted" },
        \\          { text = "#" .. tostring(todo.id) .. " ", fg = "accent" },
        \\          { text = todo.text, fg = todo.done and "muted" or "text", dim = todo.done },
        \\        }
        \\      end
        \\      return { lines = lines }
        \\    end
        \\    local text = result.content and result.content[1] and result.content[1].text or ""
        \\    return { lines = { { { text = "✓ ", fg = "success" }, { text = text, fg = "muted" } } } }
        \\  end,
        \\})
        \\
        \\zi.on("session_start", function(_, ctx) hydrate(ctx) end)
        \\zi.on("session_tree", function(_, ctx) hydrate(ctx) end)
        \\
        \\zi.register_command({
        \\  name = "todos",
        \\  description = "Show todos",
        \\  handler = function(_, ctx)
        \\    hydrate(ctx)
        \\    ctx.ui.report({ id = "todos", title = "Todos", body = list_text(), transient = true })
        \\  end,
        \\})
    , "todo-fixture");
    try testing.expect(runner.tool_registry.get("todo") != null);
    try testing.expect(runner.command_registry.getByVisibleName("todos") != null);
}

fn loadToolOverrideFixture(state: *lua_runtime.LuaState, runner: *runner_mod.ExtensionRunner) !void {
    runner.beginLoadContext(testLoadSource());
    defer runner.endLoadContext();

    try state.doString(
        \\zi.register_tool({
        \\  name = "read",
        \\  label = "read (audited)",
        \\  description = "override read",
        \\  parameters = {
        \\    type = "object",
        \\    properties = { path = { type = "string" } },
        \\    required = { "path" },
        \\  },
        \\  execute = function(params)
        \\    if params.path == ".env" then
        \\      return {
        \\        content = { { type = "text", text = "Access denied: .env" } },
        \\        is_error = true,
        \\        details = { blocked = true },
        \\      }
        \\    end
        \\    return { content = { { type = "text", text = "ok" } }, details = { blocked = false } }
        \\  end,
        \\})
    , "tool-override-fixture");
    try testing.expect(runner.tool_registry.get("read") != null);
}

fn todoArgs(allocator: std.mem.Allocator, action: []const u8, text: ?[]const u8, id: ?i64) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    errdefer obj.deinit();
    try obj.put("action", .{ .string = action });
    if (text) |value| try obj.put("text", .{ .string = value });
    if (id) |value| try obj.put("id", .{ .integer = value });
    return .{ .object = obj };
}

test "tool override example keeps extension read while preserving builtin renderer fallback" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();
    runner.attachLuaState(&state);
    runner.bindLuaOwnerThread(std.Thread.getCurrentId());
    api.installZiTable(&state, &runner);

    try loadToolOverrideFixture(&state, &runner);

    const override = runner.tool_registry.get("read") orelse return error.MissingOverride;
    try testing.expectEqualStrings("project", override.source.kind);
    try testing.expect(override.impl == .lua);
    try testing.expect(override.render_result_ref == null);

    var builtins = try builtins_mod.build(testing.allocator, ".", .{});
    defer builtins.deinit();
    var read_builtin: ?tool_def.ToolDefinition = null;
    for (builtins.definitions) |definition| {
        if (std.mem.eql(u8, definition.name, "read")) {
            read_builtin = try tool_def.cloneOwned(testing.allocator, definition);
            break;
        }
    }
    var cloned_builtin = read_builtin orelse return error.MissingReadBuiltin;
    defer tool_def.freeOwned(testing.allocator, &cloned_builtin);
    try testing.expect(!(try runner.tool_registry.register(cloned_builtin)));

    const static_entries: []const tool_display.Registration = &.{
        .{ .tool_name = "read", .renderer = builtin_renderers.read_renderer },
    };
    const resolver = tool_display.ToolRendererResolver.fromStatic(&static_entries);
    const renderer = resolver.resolve("read");
    try testing.expect(renderer.render_call != null);
    try testing.expect(renderer.render_result_slice != null);

    const ext_tool = override.*;
    const agent_tool = try buildAgentTool(testing.allocator, &runner, ext_tool);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args_obj = std.json.ObjectMap.init(allocator);
    try args_obj.put("path", .{ .string = ".env" });
    const result = agent_tool.execute(agent_tool.ctx, allocator, "read-1", .{ .object = args_obj }, abort_signal_mod.AbortSignal.none, null, null);
    try testing.expect(result.is_error);
    try testing.expectEqualStrings("Access denied: .env", result.content[0].text.text);
    try testing.expect(result.details.object.get("blocked").?.bool);
}

test "todo fixture registers a tool, command, details, and renderer" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();
    runner.attachLuaState(&state);
    runner.bindLuaOwnerThread(std.Thread.getCurrentId());
    api.installZiTable(&state, &runner);

    try loadTodoFixture(&state, &runner);

    const ext_tool = runner.tool_registry.get("todo").?.*;
    const tool = try buildAgentTool(testing.allocator, &runner, ext_tool);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const add_args = try todoArgs(allocator, "add", "write parity ledger", null);
    const add_result = tool.execute(tool.ctx, allocator, "todo-1", add_args, abort_signal_mod.AbortSignal.none, null, null);
    try testing.expect(!add_result.is_error);
    try testing.expectEqualStrings("Added todo #1: write parity ledger", add_result.content[0].text.text);
    try testing.expect(add_result.details == .object);
    const add_details = add_result.details.object;
    try testing.expectEqualStrings("add", add_details.get("action").?.string);
    try testing.expectEqual(@as(i64, 2), add_details.get("nextId").?.integer);
    const add_todos = add_details.get("todos").?.array.items;
    try testing.expectEqual(@as(usize, 1), add_todos.len);
    try testing.expectEqual(@as(i64, 1), add_todos[0].object.get("id").?.integer);
    try testing.expectEqualStrings("write parity ledger", add_todos[0].object.get("text").?.string);

    const toggle_args = try todoArgs(allocator, "toggle", null, 1);
    const toggle_result = tool.execute(tool.ctx, allocator, "todo-2", toggle_args, abort_signal_mod.AbortSignal.none, null, null);
    try testing.expect(!toggle_result.is_error);
    const toggle_todos = toggle_result.details.object.get("todos").?.array.items;
    try testing.expect(toggle_todos[0].object.get("done").?.bool);

    const list_args = try todoArgs(allocator, "list", null, null);
    const list_result = tool.execute(tool.ctx, allocator, "todo-3", list_args, abort_signal_mod.AbortSignal.none, null, null);
    try testing.expect(!list_result.is_error);
    try testing.expectEqualStrings("[x] #1: write parity ledger", list_result.content[0].text.text);

    const rendered = lua_renderer.dispatchRenderResultFromResult(testing.allocator, &runner, .{
        .tool_name = "todo",
        .args = list_args,
        .result = list_result,
        .width = 80,
        .is_error = false,
    }) orelse return error.MissingTodoRenderer;
    defer rendered.deinit(testing.allocator);

    try testing.expect(rendered.collapsed.len >= 2);
    try testing.expectEqualStrings("1 todo(s):", rendered.collapsed[0][0].text);
    try testing.expectEqualStrings("✓ ", rendered.collapsed[1][0].text);
    try testing.expectEqualStrings("#1 ", rendered.collapsed[1][1].text);
    try testing.expectEqualStrings("write parity ledger", rendered.collapsed[1][2].text);
}

const TestLabelEntry = struct {
    target_entry_id: []const u8,
    label: ?[]const u8,
};

const TestStateStore = struct {
    allocator: std.mem.Allocator,
    value: ?std.json.Value = null,
    report: ?extension_ui.Report = null,
    prompts: std.ArrayListUnmanaged(extension_ui.PromptRequest) = .empty,
    ui_publications: std.ArrayListUnmanaged(extension_ui.UiPublication) = .empty,
    editor_actions: std.ArrayListUnmanaged(extension_ui.EditorAction) = .empty,
    session_name: ?[]const u8 = null,
    note_kind: ?[]const u8 = null,
    note_title: ?[]const u8 = null,
    note_body: ?[]const u8 = null,
    note_source_entry_id: ?[]const u8 = null,
    label_target_entry_id: ?[]const u8 = null,
    label_value: ?[]const u8 = null,
    label_history: std.ArrayListUnmanaged(TestLabelEntry) = .empty,
    cancel_count: usize = 0,
    revoke_count: usize = 0,

    fn deinit(self: *TestStateStore) void {
        if (self.value) |value| ai.json_util.freeJsonValue(self.allocator, value);
        self.value = null;
        if (self.report) |*report| report.deinit(self.allocator);
        self.report = null;
        self.clearPrompts();
        self.clearUiPublications();
        self.clearEditorActions();
        if (self.session_name) |name| self.allocator.free(name);
        self.session_name = null;
        if (self.note_kind) |value| self.allocator.free(value);
        if (self.note_title) |value| self.allocator.free(value);
        if (self.note_body) |value| self.allocator.free(value);
        if (self.note_source_entry_id) |value| self.allocator.free(value);
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
        self.label_target_entry_id = null;
        self.label_value = null;
    }

    fn get(session: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: []const u8) ?std.json.Value {
        const self: *TestStateStore = @ptrCast(@alignCast(session));
        const value = self.value orelse return null;
        return ai.json_util.cloneJsonValue(allocator, value) catch null;
    }

    fn set(session: *anyopaque, _: []const u8, _: []const u8, value: std.json.Value) !void {
        const self: *TestStateStore = @ptrCast(@alignCast(session));
        if (self.value) |old| ai.json_util.freeJsonValue(self.allocator, old);
        self.value = try ai.json_util.cloneJsonValue(self.allocator, value);
    }

    fn delete(session: *anyopaque, _: []const u8, _: []const u8) !void {
        const self: *TestStateStore = @ptrCast(@alignCast(session));
        if (self.value) |old| ai.json_util.freeJsonValue(self.allocator, old);
        self.value = null;
    }

    fn sessionInfo(session: *anyopaque, allocator: std.mem.Allocator) ?std.json.Value {
        var obj = std.json.ObjectMap.init(allocator);
        obj.put(allocator.dupe(u8, "id") catch return null, .{ .string = allocator.dupe(u8, "session-test") catch return null }) catch return null;
        obj.put(allocator.dupe(u8, "cwd") catch return null, .{ .string = allocator.dupe(u8, "/tmp/project") catch return null }) catch return null;
        obj.put(allocator.dupe(u8, "file") catch return null, .null) catch return null;
        const self: *TestStateStore = @ptrCast(@alignCast(session));
        obj.put(allocator.dupe(u8, "name") catch return null, if (self.session_name) |name| .{ .string = allocator.dupe(u8, name) catch return null } else .null) catch return null;
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
            var details = std.json.ObjectMap.init(allocator);
            details.put(allocator.dupe(u8, "nextId") catch return null, .{ .integer = 2 }) catch return null;
            var obj = std.json.ObjectMap.init(allocator);
            obj.put(allocator.dupe(u8, "entry_id") catch return null, .{ .string = allocator.dupe(u8, "entry-1") catch return null }) catch return null;
            obj.put(allocator.dupe(u8, "tool_call_id") catch return null, .{ .string = allocator.dupe(u8, "call-1") catch return null }) catch return null;
            obj.put(allocator.dupe(u8, "tool_name") catch return null, .{ .string = allocator.dupe(u8, "todo") catch return null }) catch return null;
            obj.put(allocator.dupe(u8, "details") catch return null, .{ .object = details }) catch return null;
            obj.put(allocator.dupe(u8, "is_error") catch return null, .{ .bool = false }) catch return null;
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
        var obj = std.json.ObjectMap.init(allocator);
        obj.put(allocator.dupe(u8, "kind") catch return null, .{ .string = allocator.dupe(u8, note_kind) catch return null }) catch return null;
        if (self.note_title) |title| obj.put(allocator.dupe(u8, "title") catch return null, .{ .string = allocator.dupe(u8, title) catch return null }) catch return null;
        if (self.note_source_entry_id) |source| obj.put(allocator.dupe(u8, "source_entry_id") catch return null, .{ .string = allocator.dupe(u8, source) catch return null }) catch return null;
        obj.put(allocator.dupe(u8, "body") catch return null, .{ .string = allocator.dupe(u8, self.note_body orelse "") catch return null }) catch return null;
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
            var obj = std.json.ObjectMap.init(allocator);
            obj.put(allocator.dupe(u8, "entry_id") catch return null, .{ .string = allocator.dupe(u8, "message-1") catch return null }) catch return null;
            obj.put(allocator.dupe(u8, "type") catch return null, .{ .string = allocator.dupe(u8, "message") catch return null }) catch return null;
            obj.put(allocator.dupe(u8, "role") catch return null, .{ .string = allocator.dupe(u8, "user") catch return null }) catch return null;
            obj.put(allocator.dupe(u8, "text") catch return null, .{ .string = allocator.dupe(u8, "hello") catch return null }) catch return null;
            return .{ .object = obj };
        }
        if (std.mem.eql(u8, entry_id, "note-1")) {
            const note_kind = self.note_kind orelse return null;
            var obj = std.json.ObjectMap.init(allocator);
            obj.put(allocator.dupe(u8, "entry_id") catch return null, .{ .string = allocator.dupe(u8, "note-1") catch return null }) catch return null;
            obj.put(allocator.dupe(u8, "type") catch return null, .{ .string = allocator.dupe(u8, "extension_note") catch return null }) catch return null;
            obj.put(allocator.dupe(u8, "kind") catch return null, .{ .string = allocator.dupe(u8, note_kind) catch return null }) catch return null;
            obj.put(allocator.dupe(u8, "body") catch return null, .{ .string = allocator.dupe(u8, self.note_body orelse "") catch return null }) catch return null;
            if (self.note_source_entry_id) |source| obj.put(allocator.dupe(u8, "source_entry_id") catch return null, .{ .string = allocator.dupe(u8, source) catch return null }) catch return null;
            return .{ .object = obj };
        }
        if (std.mem.eql(u8, entry_id, "label-1")) {
            const target = self.label_target_entry_id orelse return null;
            var obj = std.json.ObjectMap.init(allocator);
            obj.put(allocator.dupe(u8, "entry_id") catch return null, .{ .string = allocator.dupe(u8, "label-1") catch return null }) catch return null;
            obj.put(allocator.dupe(u8, "type") catch return null, .{ .string = allocator.dupe(u8, "label") catch return null }) catch return null;
            obj.put(allocator.dupe(u8, "target_entry_id") catch return null, .{ .string = allocator.dupe(u8, target) catch return null }) catch return null;
            obj.put(allocator.dupe(u8, "label") catch return null, if (self.label_value) |value| .{ .string = allocator.dupe(u8, value) catch return null } else .null) catch return null;
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
        var obj = std.json.ObjectMap.init(allocator);
        try obj.put(try allocator.dupe(u8, "entry_id"), .{ .string = try allocator.dupe(u8, target_entry_id) });
        try obj.put(try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "message") });
        try obj.put(try allocator.dupe(u8, "role"), .{ .string = try allocator.dupe(u8, "user") });
        try obj.put(try allocator.dupe(u8, "text"), .{ .string = try allocator.dupe(u8, text) });
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
        var obj = std.json.ObjectMap.init(allocator);
        obj.put(allocator.dupe(u8, "entry_id") catch return null, .{ .string = allocator.dupe(u8, "label-1") catch return null }) catch return null;
        obj.put(allocator.dupe(u8, "target_entry_id") catch return null, .{ .string = allocator.dupe(u8, target) catch return null }) catch return null;
        obj.put(allocator.dupe(u8, "label") catch return null, if (self.label_value) |value| .{ .string = allocator.dupe(u8, value) catch return null } else .null) catch return null;
        arr.append(.{ .object = obj }) catch return null;
        return .{ .array = arr };
    }

    fn sessionMessages(session: *anyopaque, allocator: std.mem.Allocator, limit: usize, include_tools: bool) ?std.json.Value {
        _ = session;
        _ = include_tools;
        var arr = std.json.Array.init(allocator);
        if (limit != 1) {
            var first = std.json.ObjectMap.init(allocator);
            first.put(allocator.dupe(u8, "entry_id") catch return null, .{ .string = allocator.dupe(u8, "entry-1") catch return null }) catch return null;
            first.put(allocator.dupe(u8, "role") catch return null, .{ .string = allocator.dupe(u8, "user") catch return null }) catch return null;
            first.put(allocator.dupe(u8, "text") catch return null, .{ .string = allocator.dupe(u8, "hello") catch return null }) catch return null;
            arr.append(.{ .object = first }) catch return null;
        }
        var second = std.json.ObjectMap.init(allocator);
        second.put(allocator.dupe(u8, "entry_id") catch return null, .{ .string = allocator.dupe(u8, "entry-2") catch return null }) catch return null;
        second.put(allocator.dupe(u8, "role") catch return null, .{ .string = allocator.dupe(u8, "assistant") catch return null }) catch return null;
        second.put(allocator.dupe(u8, "text") catch return null, .{ .string = allocator.dupe(u8, "hi") catch return null }) catch return null;
        arr.append(.{ .object = second }) catch return null;
        return .{ .array = arr };
    }

    fn publishReport(session: *anyopaque, report: extension_ui.Report) !void {
        const self: *TestStateStore = @ptrCast(@alignCast(session));
        if (self.report) |*old| old.deinit(self.allocator);
        self.report = try extension_ui.Report.clone(self.allocator, report);
    }

    fn publishPrompt(session: *anyopaque, prompt: extension_ui.PromptRequest) !void {
        const self: *TestStateStore = @ptrCast(@alignCast(session));
        var cloned = try extension_ui.PromptRequest.clone(self.allocator, prompt);
        errdefer cloned.deinit(self.allocator);
        try self.prompts.append(self.allocator, cloned);
    }

    fn cancelPrompts(session: *anyopaque) void {
        const self: *TestStateStore = @ptrCast(@alignCast(session));
        self.cancel_count += 1;
        self.clearPrompts();
    }

    fn clearPrompts(self: *TestStateStore) void {
        for (self.prompts.items) |*prompt| prompt.deinit(self.allocator);
        self.prompts.deinit(self.allocator);
        self.prompts = .empty;
    }

    fn publishUi(session: *anyopaque, update: extension_ui.UiPublication) !void {
        const self: *TestStateStore = @ptrCast(@alignCast(session));
        var cloned = try extension_ui.UiPublication.clone(self.allocator, update);
        errdefer cloned.deinit(self.allocator);
        try self.ui_publications.append(self.allocator, cloned);
    }

    fn revokeUi(session: *anyopaque) void {
        const self: *TestStateStore = @ptrCast(@alignCast(session));
        self.revoke_count += 1;
        self.clearUiPublications();
    }

    fn clearUiPublications(self: *TestStateStore) void {
        for (self.ui_publications.items) |*update| update.deinit(self.allocator);
        self.ui_publications.deinit(self.allocator);
        self.ui_publications = .empty;
    }

    fn publishEditorAction(session: *anyopaque, action: extension_ui.EditorAction) !void {
        const self: *TestStateStore = @ptrCast(@alignCast(session));
        var cloned = try extension_ui.EditorAction.clone(self.allocator, action);
        errdefer cloned.deinit(self.allocator);
        try self.editor_actions.append(self.allocator, cloned);
    }

    fn resolvePrompt(session: *anyopaque, prompt: extension_ui.PromptRequest, response: *request_mod.ExtensionPromptResponse) void {
        const self: *TestStateStore = @ptrCast(@alignCast(session));
        if (prompt.timeout_ms == 1) return response.finish(.timeout);
        switch (prompt.kind) {
            .confirm => response.finish(.{ .confirm = true }),
            .select => {
                const selected = if (prompt.options.len > 0) prompt.options[0] else null;
                const selected_id = if (selected) |option| option.id else "";
                const text = self.allocator.dupe(u8, selected_id) catch return response.finish(.{ .value = null });
                const label = if (selected) |option| self.allocator.dupe(u8, option.label) catch null else null;
                const description = if (selected) |option| if (option.description) |value| self.allocator.dupe(u8, value) catch null else null else null;
                const search = if (selected) |option| if (option.search) |value| self.allocator.dupe(u8, value) catch null else null else null;
                const preview = if (selected) |option| if (option.preview) |value| self.allocator.dupe(u8, value) catch null else null else null;
                response.finish(.{ .value = .{
                    .text = text,
                    .allocator = self.allocator,
                    .label = label,
                    .description = description,
                    .search = search,
                    .preview = preview,
                } });
            },
            .input => {
                const text = self.allocator.dupe(u8, "typed") catch return response.finish(.{ .value = null });
                response.finish(.{ .value = .{ .text = text, .allocator = self.allocator } });
            },
            .editor => {
                const text = self.allocator.dupe(u8, "edited") catch return response.finish(.{ .value = null });
                response.finish(.{ .value = .{ .text = text, .allocator = self.allocator } });
            },
        }
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
        .get_context_usage = &testGetContextUsage,
        .get_system_prompt = &testGetSystemPrompt,
        .get_binding_info = &testGetBindingInfo,
        .session_state_get = &TestStateStore.get,
        .session_state_set = &TestStateStore.set,
        .session_state_delete = &TestStateStore.delete,
        .session_info_get = &TestStateStore.sessionInfo,
        .session_name_get = &TestStateStore.sessionName,
        .session_name_set = &TestStateStore.setSessionName,
        .session_tool_results_get = &TestStateStore.sessionToolResults,
        .session_messages_get = &TestStateStore.sessionMessages,
        .session_note_append = &TestStateStore.appendNote,
        .session_notes_get = &TestStateStore.notes,
        .session_label_set = &TestStateStore.setLabel,
        .session_labels_get = &TestStateStore.labels,
        .session_entry_get = &TestStateStore.entry,
        .session_entries_get = &TestStateStore.entries,
        .publish_report = &TestStateStore.publishReport,
        .publish_prompt = &TestStateStore.publishPrompt,
        .cancel_prompts = &TestStateStore.cancelPrompts,
        .publish_ui = &TestStateStore.publishUi,
        .revoke_ui = &TestStateStore.revokeUi,
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
    api.installZiTable(&state, &runner);

    runner.beginLoadContext(testLoadSource());
    defer runner.endLoadContext();
    try state.doString(
        \\zi.register_command({
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
    api.installZiTable(&state, &runner);

    runner.beginLoadContext(testLoadSource());
    defer runner.endLoadContext();
    try state.doString(
        \\zi.register_command({
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
    api.installZiTable(&state, &runner);

    runner.beginLoadContext(testLoadSource());
    defer runner.endLoadContext();
    try state.doString(
        \\zi.register_command({
        \\  name = "editor-actions",
        \\  description = "editor-actions",
        \\  handler = function(_, ctx)
        \\    ctx.ui.set_editor_text("hello")
        \\    ctx.ui.paste_to_editor(" world")
        \\    ctx.ui.clear_editor_text()
        \\    assert(ctx.ui.get_editor_text() == nil)
        \\  end,
        \\})
    , "register_editor_action_command");

    try runner.dispatchCommand("editor-actions", "");

    try testing.expectEqual(@as(usize, 4), store.editor_actions.items.len);
    try testing.expectEqual(extension_ui.EditorActionKind.set_text, store.editor_actions.items[0].kind);
    try testing.expectEqualStrings("hello", store.editor_actions.items[0].text.?);
    try testing.expectEqual(extension_ui.EditorActionKind.paste_text, store.editor_actions.items[1].kind);
    try testing.expectEqualStrings(" world", store.editor_actions.items[1].text.?);
    try testing.expectEqual(extension_ui.EditorActionKind.clear_text, store.editor_actions.items[2].kind);
    try testing.expectEqual(extension_ui.EditorActionKind.get_text, store.editor_actions.items[3].kind);

    runner.unbindRuntime();
    try testing.expectEqual(@as(usize, 0), store.editor_actions.items.len);
}

test "extension command context publishes semantic ui message status and progress" {
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
    api.installZiTable(&state, &runner);

    runner.beginLoadContext(testLoadSource());
    defer runner.endLoadContext();
    try state.doString(
        \\zi.register_command({
        \\  name = "ui_publications",
        \\  description = "ui_publications",
        \\  handler = function(_, ctx)
        \\    ctx.ui.message("Ready for input", { id = "readiness", kind = "warning", lifetime = "until_input" })
        \\    ctx.ui.status({ id = "demo", text = "ready" })
        \\    ctx.ui.progress({ id = "index", title = "Indexing", current = 2, total = 4, detail = "src" })
        \\  end,
        \\})
    , "register_ui_publication_command");

    try runner.dispatchCommand("ui_publications", "");

    try testing.expectEqual(@as(usize, 3), store.ui_publications.items.len);
    try testing.expectEqual(extension_ui.UiPublicationKind.message, store.ui_publications.items[0].kind);
    try testing.expectEqualStrings("readiness", store.ui_publications.items[0].id);
    try testing.expectEqualStrings("Ready for input", store.ui_publications.items[0].text.?);
    try testing.expectEqualStrings("warning", store.ui_publications.items[0].classification.?);
    try testing.expectEqual(extension_ui.UiPublicationKind.status, store.ui_publications.items[1].kind);
    try testing.expectEqualStrings("demo", store.ui_publications.items[1].id);
    try testing.expectEqualStrings("ready", store.ui_publications.items[1].text.?);
    try testing.expectEqual(extension_ui.UiPublicationKind.progress, store.ui_publications.items[2].kind);
    try testing.expectEqualStrings("index", store.ui_publications.items[2].id);
    try testing.expect(store.ui_publications.items[2].text == null);
    try testing.expectEqual(extension_ui.ProgressStatus.running, store.ui_publications.items[2].progress_status.?);
    try testing.expectEqualStrings("Indexing", store.ui_publications.items[2].title.?);
    try testing.expectEqual(@as(i64, 2), store.ui_publications.items[2].current.?);
    try testing.expectEqual(@as(i64, 4), store.ui_publications.items[2].total.?);
    try testing.expectEqualStrings("src", store.ui_publications.items[2].detail.?);

    runner.unbindRuntime();
    try testing.expectEqual(@as(usize, 1), store.revoke_count);
    try testing.expectEqual(@as(usize, 0), store.ui_publications.items.len);
}

test "extension command prompts can resolve through host response" {
    var store = TestStateStore{ .allocator = testing.allocator };
    defer store.deinit();

    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();
    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 16);
    defer runner.deinit();
    runner.attachLuaState(&state);
    runner.bindLuaOwnerThread(std.Thread.getCurrentId());
    var provider_registry = ai.provider.Registry.init(testing.allocator);
    defer provider_registry.deinit();
    try bindResolvingRuntime(&runner, &store, &provider_registry);
    api.installZiTable(&state, &runner);

    runner.beginLoadContext(testLoadSource());
    defer runner.endLoadContext();
    try state.doString(
        \\zi.register_command({
        \\  name = "resolved-prompts",
        \\  description = "resolved-prompts",
        \\  handler = function(_, ctx)
        \\    local confirmed = ctx.ui.prompt({ kind = "confirm", title = "Confirm", message = "Continue?" })
        \\    assert(confirmed.status == "submitted" and confirmed.value == true)
        \\    local picked = ctx.ui.pick({ title = "Pick", options = { "A", "B" } })
        \\    assert(picked.status == "submitted" and picked.value == "A")
        \\    local input = ctx.ui.prompt({ kind = "input", title = "Input", placeholder = "placeholder" })
        \\    assert(input.status == "submitted" and input.value == "typed")
        \\    local edited = ctx.ui.prompt({ kind = "editor", title = "Editor", prefill = "prefill" })
        \\    assert(edited.status == "submitted" and edited.value == "edited")
        \\    local selected = ctx.ui.prompt({
        \\      kind = "select",
        \\      title = "Pick object",
        \\      placeholder = "language> ",
        \\      empty_text = "No languages",
        \\      options = {
        \\        {
        \\          label = "Lua",
        \\          value = "lua",
        \\          description = "extension language",
        \\          search = "lua extension scripting",
        \\          preview = "Lua\nSmall embeddable language.",
        \\        },
        \\        { label = "Zig", value = "zig" },
        \\      },
        \\    })
        \\    assert(selected.status == "submitted")
        \\    assert(selected.value == "lua")
        \\    assert(selected.item.value == "lua")
        \\    assert(selected.item.label == "Lua")
        \\    assert(selected.item.description == "extension language")
        \\    assert(selected.item.search == "lua extension scripting")
        \\    assert(selected.item.preview == "Lua\nSmall embeddable language.")
        \\    local typed = ctx.ui.prompt({ kind = "input", title = "Name", placeholder = "my-app", default = "zi" })
        \\    assert(typed.status == "submitted")
        \\    assert(typed.value == "typed")
        \\    local timed_out = ctx.ui.prompt({ kind = "confirm", title = "Timed", timeout_ms = 1 })
        \\    assert(timed_out.status == "timeout")
        \\  end,
        \\})
    , "register_resolved_prompt_command");

    try runner.dispatchCommand("resolved-prompts", "");
}

test "lua question tool publishes host-owned select prompt request" {
    var store = TestStateStore{ .allocator = testing.allocator };
    defer store.deinit();

    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();
    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 17);
    defer runner.deinit();
    runner.attachLuaState(&state);
    runner.bindLuaOwnerThread(std.Thread.getCurrentId());
    var provider_registry = ai.provider.Registry.init(testing.allocator);
    defer provider_registry.deinit();
    try bindTestRuntime(&runner, &store, &provider_registry);
    api.installZiTable(&state, &runner);

    runner.beginLoadContext(testLoadSource());
    defer runner.endLoadContext();
    try state.doString(
        \\zi.register_tool({
        \\  name = "question_test",
        \\  description = "question_test",
        \\  parameters = { type = "object", properties = {} },
        \\  execute = function(args, ctx)
        \\    local picked = ctx.ui.pick({ title = args.question, options = args.options })
        \\    local answer = picked.status == "submitted" and picked.value or nil
        \\    return {
        \\      content = { { type = "text", text = answer or "cancelled" } },
        \\      details = { answer = answer },
        \\    }
        \\  end,
        \\})
    , "register_question_test_tool");

    const ext_tool = runner.tool_registry.get("question_test").?.*;
    const tool = try buildAgentTool(testing.allocator, &runner, ext_tool);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const args = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(),
        \\{"question":"Pick one","options":["Alpha","Beta"]}
    , .{});

    const result = tool.execute(
        tool.ctx,
        arena.allocator(),
        "id-question",
        args,
        abort_signal_mod.AbortSignal.none,
        null,
        null,
    );

    try testing.expect(!result.is_error);
    try testing.expectEqual(@as(usize, 1), store.prompts.items.len);
    try testing.expectEqual(extension_ui.PromptKind.select, store.prompts.items[0].kind);
    try testing.expectEqualStrings("Pick one", store.prompts.items[0].title);
    try testing.expectEqualStrings("Alpha", store.prompts.items[0].options[0].id);
    try testing.expectEqualStrings("Beta", store.prompts.items[0].options[1].label);
}

test "extension command context publishes host-owned prompt requests with default outcomes" {
    var store = TestStateStore{ .allocator = testing.allocator };
    defer store.deinit();

    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();
    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 13);
    defer runner.deinit();
    runner.attachLuaState(&state);
    runner.bindLuaOwnerThread(std.Thread.getCurrentId());
    var provider_registry = ai.provider.Registry.init(testing.allocator);
    defer provider_registry.deinit();
    try bindTestRuntime(&runner, &store, &provider_registry);
    api.installZiTable(&state, &runner);

    runner.beginLoadContext(testLoadSource());
    defer runner.endLoadContext();
    try state.doString(
        \\zi.register_command({
        \\  name = "prompts",
        \\  description = "prompts",
        \\  handler = function(_, ctx)
        \\    local confirmed = ctx.ui.prompt({ kind = "confirm", title = "Confirm", message = "Continue?" })
        \\    assert(confirmed.status == "submitted" and confirmed.value == false)
        \\    local picked = ctx.ui.pick({ title = "Pick", options = { "A", "B" } })
        \\    assert(picked.status == "cancelled")
        \\    local input = ctx.ui.prompt({ kind = "input", title = "Input", placeholder = "placeholder" })
        \\    assert(input.status == "cancelled")
        \\    local edited = ctx.ui.prompt({ kind = "editor", title = "Editor", prefill = "prefill" })
        \\    assert(edited.status == "cancelled")
        \\    local cancelled = ctx.ui.prompt({ kind = "select", title = "Pick object", options = { { label = "Lua", value = "lua" } }, timeout_ms = 5000 })
        \\    assert(cancelled.status == "cancelled")
        \\  end,
        \\})
    , "register_prompt_command");

    try runner.dispatchCommand("prompts", "");

    try testing.expectEqual(@as(usize, 5), store.prompts.items.len);
    try testing.expectEqual(extension_ui.PromptKind.confirm, store.prompts.items[0].kind);
    try testing.expectEqualStrings("Confirm", store.prompts.items[0].title);
    try testing.expectEqualStrings("Continue?", store.prompts.items[0].message.?);
    try testing.expectEqual(extension_ui.PromptKind.select, store.prompts.items[1].kind);
    try testing.expectEqualStrings("A", store.prompts.items[1].options[0].id);
    try testing.expectEqualStrings("B", store.prompts.items[1].options[1].label);
    try testing.expectEqual(extension_ui.PromptKind.input, store.prompts.items[2].kind);
    try testing.expectEqualStrings("placeholder", store.prompts.items[2].placeholder.?);
    try testing.expectEqual(extension_ui.PromptKind.editor, store.prompts.items[3].kind);
    try testing.expectEqualStrings("prefill", store.prompts.items[3].prefill.?);
    try testing.expectEqual(extension_ui.PromptKind.select, store.prompts.items[4].kind);
    try testing.expectEqualStrings("lua", store.prompts.items[4].options[0].id);
    try testing.expectEqualStrings("Lua", store.prompts.items[4].options[0].label);
    try testing.expectEqual(@as(?u64, 5000), store.prompts.items[4].timeout_ms);

    runner.unbindRuntime();
    try testing.expectEqual(@as(usize, 1), store.cancel_count);
    try testing.expectEqual(@as(usize, 0), store.prompts.items.len);
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
    api.installZiTable(&state, &runner);

    runner.beginLoadContext(testLoadSource());
    defer runner.endLoadContext();
    try state.doString(
        \\zi.register_command({
        \\  name = "system-test",
        \\  description = "system-test",
        \\  handler = function(_, ctx)
        \\    local result = zi.system({ "/bin/sh", "-c", "cat" }, { cwd = ctx.cwd, stdin = "hello", env = { FOO = "bar" }, timeout_ms = 1234 })
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
    api.installZiTable(&state, &runner);

    runner.beginLoadContext(testLoadSource());
    defer runner.endLoadContext();
    try state.doString(
        \\zi.register_command({
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
    try runner.resumeAsync(1, .{ .ai_complete = .{ .completed = .{ .text = try testing.allocator.dupe(u8, "world") } } });
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
    api.installZiTable(&state, &runner);

    runner.beginLoadContext(testLoadSource());
    defer runner.endLoadContext();
    try state.doString(
        \\zi.register_command({
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
    api.installZiTable(&state, &runner);

    runner.beginLoadContext(testLoadSource());
    defer runner.endLoadContext();
    try state.doString(
        \\zi.register_command({
        \\  name = "bad-yield",
        \\  description = "bad-yield",
        \\  handler = function() coroutine.yield() end,
        \\})
    , "register_bad_yield_command");

    try testing.expectError(error.UnexpectedYield, runner.dispatchCommand("bad-yield", ""));
}

test "extension command context publishes a host-owned report" {
    var store = TestStateStore{ .allocator = testing.allocator };
    defer store.deinit();

    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();
    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 11);
    defer runner.deinit();
    runner.attachLuaState(&state);
    runner.bindLuaOwnerThread(std.Thread.getCurrentId());
    var provider_registry = ai.provider.Registry.init(testing.allocator);
    defer provider_registry.deinit();
    try bindTestRuntime(&runner, &store, &provider_registry);
    api.installZiTable(&state, &runner);

    runner.beginLoadContext(testLoadSource());
    defer runner.endLoadContext();
    try state.doString(
        \\zi.register_command({
        \\  name = "report",
        \\  description = "report",
        \\  handler = function(_, ctx)
        \\    assert(ctx.has_ui == true)
        \\    ctx.ui.report({
        \\      id = "demo",
        \\      title = "Demo",
        \\      body = "✓ published",
        \\      transient = true,
        \\    })
        \\  end,
        \\})
    , "register_report_command");

    try runner.dispatchCommand("report", "");

    const report = store.report orelse return error.MissingReport;
    try testing.expectEqualStrings("state-123", report.state_owner_id);
    try testing.expectEqual(@as(u64, 11), report.generation);
    try testing.expectEqualStrings("demo", report.id);
    try testing.expectEqualStrings("Demo", report.title);
    try testing.expect(report.transient);
    try testing.expectEqual(@as(usize, 1), report.lines.len);
    try testing.expectEqual(@as(usize, 1), report.lines[0].len);
    try testing.expectEqualStrings("✓ published", report.lines[0][0].text);
}

test "extension report body is split into visible lines" {
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
    api.installZiTable(&state, &runner);

    runner.beginLoadContext(testLoadSource());
    defer runner.endLoadContext();
    try state.doString(
        \\zi.register_command({
        \\  name = "report-body",
        \\  description = "report-body",
        \\  handler = function(_, ctx)
        \\    ctx.ui.report({ title = "Body", body = "one\ntwo\n" })
        \\  end,
        \\})
    , "register_report_body_command");

    try runner.dispatchCommand("report-body", "");

    const report = store.report orelse return error.MissingReport;
    try testing.expectEqualStrings("Body", report.title);
    try testing.expectEqual(@as(usize, 2), report.lines.len);
    try testing.expectEqualStrings("one", report.lines[0][0].text);
    try testing.expectEqualStrings("two", report.lines[1][0].text);
}

test "todo command publishes hydrated todos as a host-owned report" {
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
    api.installZiTable(&state, &runner);
    try loadTodoFixture(&state, &runner);

    const ext_tool = runner.tool_registry.get("todo").?.*;
    const tool = try buildAgentTool(testing.allocator, &runner, ext_tool);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const add_args = try todoArgs(arena.allocator(), "add", "ship report", null);
    const add_result = tool.execute(tool.ctx, arena.allocator(), "todo-1", add_args, abort_signal_mod.AbortSignal.none, null, null);
    try testing.expect(!add_result.is_error);

    try runner.dispatchCommand("todos", "");

    const report = store.report orelse return error.MissingReport;
    try testing.expectEqualStrings("todos", report.id);
    try testing.expectEqualStrings("Todos", report.title);
    try testing.expect(report.transient);
    try testing.expectEqual(@as(usize, 1), report.lines.len);
    try testing.expectEqual(@as(usize, 1), report.lines[0].len);
    try testing.expectEqualStrings("[ ] #1: ship report", report.lines[0][0].text);
}

test "todo fixture rehydrates from session state across extension generations" {
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
        api.installZiTable(&state, &runner);
        try loadTodoFixture(&state, &runner);

        const ext_tool = runner.tool_registry.get("todo").?.*;
        const tool = try buildAgentTool(testing.allocator, &runner, ext_tool);
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const add_args = try todoArgs(arena.allocator(), "add", "persist me", null);
        const add_result = tool.execute(tool.ctx, arena.allocator(), "todo-1", add_args, abort_signal_mod.AbortSignal.none, null, null);
        try testing.expect(!add_result.is_error);
    }

    try testing.expect(store.value != null);

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
        api.installZiTable(&state, &runner);
        try loadTodoFixture(&state, &runner);

        const ext_tool = runner.tool_registry.get("todo").?.*;
        const tool = try buildAgentTool(testing.allocator, &runner, ext_tool);
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const list_args = try todoArgs(arena.allocator(), "list", null, null);
        const list_result = tool.execute(tool.ctx, arena.allocator(), "todo-2", list_args, abort_signal_mod.AbortSignal.none, null, null);
        try testing.expect(!list_result.is_error);
        try testing.expectEqualStrings("[ ] #1: persist me", list_result.content[0].text.text);
    }
}

test "lua tool returning a string produces a single text content block" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();
    runner.attachLuaState(&state);
    api.installZiTable(&state, &runner);

    try state.doString(
        \\zi.register_tool({
        \\  name = "echo",
        \\  description = "echo",
        \\  parameters = { type = "object", properties = {} },
        \\  execute = function(args) return "hello " .. (args.who or "world") end,
        \\})
    , "register");

    const ext_tool = runner.tool_registry.get("echo").?.*;
    const tool = try buildAgentTool(testing.allocator, &runner, ext_tool);

    var args_obj = std.json.ObjectMap.init(testing.allocator);
    defer args_obj.deinit();
    try args_obj.put("who", .{ .string = "zi" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const result = tool.execute(
        tool.ctx,
        arena.allocator(),
        "id-1",
        .{ .object = args_obj },
        abort_signal_mod.AbortSignal.none,
        null,
        null,
    );

    try testing.expect(!result.is_error);
    try testing.expectEqual(@as(usize, 1), result.content.len);
    try testing.expectEqualStrings("hello zi", result.content[0].text.text);
}

test "lua tool returning content array with is_error=true ui_publications both" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();
    runner.attachLuaState(&state);
    api.installZiTable(&state, &runner);

    try state.doString(
        \\zi.register_tool({
        \\  name = "fail",
        \\  description = "always fails",
        \\  parameters = { type = "object", properties = {} },
        \\  execute = function(args)
        \\    return {
        \\      content = { { type = "text", text = "boom" } },
        \\      is_error = true,
        \\    }
        \\  end,
        \\})
    , "register");

    const ext_tool = runner.tool_registry.get("fail").?.*;
    const tool = try buildAgentTool(testing.allocator, &runner, ext_tool);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const result = tool.execute(
        tool.ctx,
        arena.allocator(),
        "id-2",
        .{ .null = {} },
        abort_signal_mod.AbortSignal.none,
        null,
        null,
    );

    try testing.expect(result.is_error);
    try testing.expectEqual(@as(usize, 1), result.content.len);
    try testing.expectEqualStrings("boom", result.content[0].text.text);
}

test "lua tool with a runtime error returns is_error with the error message" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();
    runner.attachLuaState(&state);
    api.installZiTable(&state, &runner);

    try state.doString(
        \\zi.register_tool({
        \\  name = "explode",
        \\  description = "raises",
        \\  parameters = { type = "object", properties = {} },
        \\  execute = function(args) error("kaboom") end,
        \\})
    , "register");

    const ext_tool = runner.tool_registry.get("explode").?.*;
    const tool = try buildAgentTool(testing.allocator, &runner, ext_tool);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const result = tool.execute(
        tool.ctx,
        arena.allocator(),
        "id-3",
        .{ .null = {} },
        abort_signal_mod.AbortSignal.none,
        null,
        null,
    );

    try testing.expect(result.is_error);
    try testing.expect(result.content.len >= 1);
}
