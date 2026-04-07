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
const agent_protocol = @import("../agent/protocol.zig");
const abort_signal_mod = @import("../abort_signal.zig");

const c = lua_runtime.c;
const log = std.log.scoped(.zi_lua_tool);

const AgentToolResult = agent_protocol.AgentToolResult;

/// Per-tool execution context. The `AgentTool.ctx` slot is one
/// pointer; we use it to find both the runner (for the lua_state)
/// and the handler ref (the registry entry's `lua_ref`).
pub const LuaToolCtx = struct {
    runner: *runner_mod.ExtensionRunner,
    lua_ref: c_int,
};

/// Build an `AgentTool` from a registered ExtensionTool.
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
    ext_tool: tool_registry.ExtensionTool,
) !agent_protocol.AgentTool {
    const lua_ref = switch (ext_tool.impl) {
        .lua => |r| r,
        .builtin => return error.NotALuaTool,
    };
    const ctx = try allocator.create(LuaToolCtx);
    ctx.* = .{ .runner = runner, .lua_ref = lua_ref };

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
    _ = tool_call_id;
    _ = signal;
    _ = on_update;
    _ = update_ctx;

    const tctx: *LuaToolCtx = @ptrCast(@alignCast(ctx.?));
    const state = tctx.runner.lua_state orelse {
        return errorResult(allocator, "lua state not attached");
    };

    return runHandler(allocator, state, tctx.lua_ref, args) catch |err| {
        log.warn("lua tool execution failed: {s}", .{@errorName(err)});
        return errorResult(allocator, @errorName(err));
    };
}

fn runHandler(
    allocator: std.mem.Allocator,
    state: *lua_runtime.LuaState,
    handler_ref: c_int,
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

    // Push args as the single argument.
    try lua_runtime.pushJsonValue(co.L, args);

    const r = try co.resumeWith(1);
    switch (r.status) {
        .yielded => return error.UnexpectedYield,
        .ok, .finished => {},
    }

    if (r.nresults == 0) return emptyResult();

    const top = c.lua_gettop(co.L);
    defer c.lua_settop(co.L, top - r.nresults);

    return parseReturn(allocator, co.L, top);
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

        // Inspect the content field.
        _ = c.lua_getfield(L, idx, "content");
        defer c.lua_pop(L, 1);

        const content_ty = c.lua_type(L, -1);

        if (content_ty == c.LUA_TSTRING) {
            return try textResult(allocator, lstring(L, -1), is_error);
        }

        if (content_ty == c.LUA_TTABLE) {
            const blocks = try parseContentBlocks(allocator, L, -1);
            return .{ .content = blocks, .is_error = is_error };
        }

        // Table with no content field → empty result with the
        // is_error flag honored.
        return .{ .content = &.{}, .is_error = is_error };
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
// Tests
// =============================================================================

const testing = std.testing;
const api = @import("api.zig");

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
