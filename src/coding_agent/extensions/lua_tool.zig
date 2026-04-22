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
const context_mod = @import("context.zig");
const resource_types = @import("../resources/types.zig");
const spawn_mod = @import("../../spawn/spawn.zig");
const spawn_types = @import("../../spawn/types.zig");

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
    allocator: std.mem.Allocator,
    runner: *runner_mod.ExtensionRunner,
    ext_tool: tool_registry.ToolDefinition,
) !agent_protocol.AgentTool {
    const lua_ref = switch (ext_tool.impl) {
        .lua => |r| r,
        .builtin => return error.NotALuaTool,
    };
    const ctx = try allocator.create(LuaToolCtx);
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
    // always tests or mistakes; we don't want to surface a tool
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
/// tools (Task, Oracle, anything that wraps `zi.spawn`) to surface
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
    defer testing.allocator.destroy(@as(*LuaToolCtx, @ptrCast(@alignCast(tool.ctx.?))));

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
    try testing.expectEqualStrings("state-123::7::/workspace", result.details.object.get("namespace_id").?.string);
    try testing.expectEqualStrings("/workspace", result.details.object.get("workspace_id").?.string);
    try testing.expectEqualStrings("session-123", result.details.object.get("session_id").?.string);
    try testing.expectEqualStrings("/workspace/.zi/sessions/session-123.jsonl", result.details.object.get("session_file").?.string);
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
    defer testing.allocator.destroy(@as(*LuaToolCtx, @ptrCast(@alignCast(tool.ctx.?))));

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

test "lua tool returning content array with is_error=true surfaces both" {
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
    defer testing.allocator.destroy(@as(*LuaToolCtx, @ptrCast(@alignCast(tool.ctx.?))));

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
    defer testing.allocator.destroy(@as(*LuaToolCtx, @ptrCast(@alignCast(tool.ctx.?))));

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
