//! Lua-driven tool renderers.
//!
//! Bridges the first vertical of zi's host-owned presentation contract:
//! `zi.tool({ render_call = ..., render_result = ... })` maps
//! to the tool `call` and `result` presentation slots and returns owned,
//! width-agnostic presentation documents.
//!
//! Since zi-wub.5/.6 the agent thread is the single owner of
//! `lua_state`, so any `render_result` dispatch must happen there.
//! This module builds a `RenderedToolResult` by running the hook against a
//! tool result and deep-copying the returned spans into arena-owned
//! Zig data. Callers decide whether to render immediately, cache, or
//! discard the result.
//!
//! ## Restricted render environment
//!
//! The Lua hook receives exactly two arguments:
//!
//!   1. `result` — the tool result table (`{ content, is_error,
//!      details }`), same shape the hook returned from `execute`.
//!   2. `ctx` — a small table with `{ width, expanded, is_error }`.
//!      Intentionally minimal. Render hooks are PURE FUNCTIONS —
//!      they MUST NOT call `zi.spawn` (blocking + abort-racing),
//!      `zi.on` (mutation during dispatch), or any other host
//!      function that mutates runner state. We enforce this at
//!      the policy level via documentation; a future hardening
//!      could sandbox by running the hook in a stripped
//!      environment.
//!
//! ## Ownership
//!
//! Every `*RenderedToolResult` is arena-allocated: one arena per
//! render state, freed wholesale on `deinit`. Strings parsed from
//! the Lua stack are duped into the arena before the coroutine
//! deinits. After `dispatchRenderResult` returns, the state holds
//! no references into Lua memory and can survive any subsequent
//! GC, reload, or runner teardown.
//!
//! ## Fallback
//!
//! Any failure (missing state, malformed return, Lua error, OOM)
//! produces `null`. The transcript falls back to the default
//! text-wrap formatter. Render hooks MUST fail open.

const std = @import("std");
const lua_runtime = @import("lua_runtime.zig");
const runner_mod = @import("runner.zig");
const tool_registry_mod = @import("registries/tool_registry.zig");
const theme_mod = @import("../../tui/theme.zig");
const theme_tokens = @import("../../themes/tokens.zig");
const rendered_tool_result_view = @import("../../tui/conversation/rendered_tool_result.zig");
const agent_protocol = @import("../../agent/types.zig");

pub const Span = rendered_tool_result_view.Span;
pub const Line = rendered_tool_result_view.Line;
pub const RenderedToolResult = rendered_tool_result_view.RenderedToolResult;

const c = lua_runtime.c;
const log = std.log.scoped(.zi_lua_renderer);

pub const DispatchCallInput = struct {
    tool_name: []const u8,
    args: std.json.Value,
    width: u32,
};

pub const DispatchInput = struct {
    tool_name: []const u8,
    args: std.json.Value,
    result: std.json.Value,
    width: u32,
    is_error: bool,
};

/// Run the render_call hook for `tool_name` if one exists, and return
/// an owned presentation document. Returns null on missing hook or any
/// failure so callers can fall back to builtin/default call rendering.
pub fn dispatchRenderCall(
    allocator: std.mem.Allocator,
    runner: *runner_mod.ExtensionRunner,
    input: DispatchCallInput,
) ?*RenderedToolResult {
    const tool = runner.tool_registry.get(input.tool_name) orelse return null;
    const ref = tool.render_call_ref orelse return null;
    const state_ptr = runner.lua_state orelse return null;

    runner.assertOnLuaThread();
    runner.setModuleContext(state_ptr, tool.source.provenance);

    const out_state = allocator.create(RenderedToolResult) catch return null;
    out_state.* = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .collapsed = &.{},
        .expanded = &.{},
    };

    out_state.collapsed = runOneCall(state_ptr, ref, input, false, out_state.arena.allocator()) catch |err| {
        log.warn("render_call (collapsed) failed for '{s}': {s}", .{ input.tool_name, @errorName(err) });
        out_state.deinit(allocator);
        return null;
    };
    out_state.expanded = runOneCall(state_ptr, ref, input, true, out_state.arena.allocator()) catch |err| {
        log.warn("render_call (expanded) failed for '{s}': {s}", .{ input.tool_name, @errorName(err) });
        out_state.deinit(allocator);
        return null;
    };

    return out_state;
}

/// Input variant that takes an `AgentToolResult` directly instead
/// of a pre-built json.Value. Used by the transcript, which holds
/// `AgentToolResult` as owned zig state and doesn't want to build
/// an ephemeral json tree just to throw it away. Args are still
/// passed as json because that's what the agent layer gives us
/// (tool calls are decoded from JSON).
pub const DispatchInputFromResult = struct {
    tool_name: []const u8,
    args: std.json.Value,
    result: agent_protocol.AgentToolResult,
    width: u32,
    is_error: bool,
};

/// Variant of `dispatchRenderResult` that takes an `AgentToolResult`
/// and pushes the Lua table manually (content blocks + is_error +
/// details) without an intermediate json.Value allocation.
pub fn dispatchRenderResultFromResult(
    allocator: std.mem.Allocator,
    runner: *runner_mod.ExtensionRunner,
    input: DispatchInputFromResult,
) ?*RenderedToolResult {
    return dispatchRenderResultFromResultOn(allocator, runner, input, null);
}

/// Variant that lets the caller specify the *currently running*
/// `lua_State`. Required when this is invoked from a host C function
/// that's executing on a coroutine (e.g. `ctx.update` fired from
/// inside `zi.spawn`'s event trampoline) — Lua API calls must happen
/// on the current thread, not on the main state, or `lua_newthread`
/// corrupts the stack and the next `lua_resume` blows up inside
/// `luaH_getshortstr`. Pass `null` when you're already on main.
pub fn dispatchRenderResultFromResultOn(
    allocator: std.mem.Allocator,
    runner: *runner_mod.ExtensionRunner,
    input: DispatchInputFromResult,
    current_L: ?*c.lua_State,
) ?*RenderedToolResult {
    const tool = runner.tool_registry.get(input.tool_name) orelse return null;
    const ref = tool.render_result_ref orelse return null;
    const state_ptr = runner.lua_state orelse return null;
    const from_L = current_L orelse state_ptr.L;

    runner.assertOnLuaThread();

    runner.setModuleContext(state_ptr, tool.source.provenance);

    const out_state = allocator.create(RenderedToolResult) catch return null;
    out_state.* = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .collapsed = &.{},
        .expanded = &.{},
    };

    out_state.collapsed = runOneFromResult(state_ptr, from_L, ref, input, false, out_state.arena.allocator()) catch |err| {
        log.warn("render_result (collapsed) failed for '{s}': {s}", .{ input.tool_name, @errorName(err) });
        out_state.deinit(allocator);
        return null;
    };
    out_state.expanded = runOneFromResult(state_ptr, from_L, ref, input, true, out_state.arena.allocator()) catch |err| {
        log.warn("render_result (expanded) failed for '{s}': {s}", .{ input.tool_name, @errorName(err) });
        out_state.deinit(allocator);
        return null;
    };
    return out_state;
}

fn runOneFromResult(
    state: *lua_runtime.LuaState,
    from_L: *c.lua_State,
    ref: c_int,
    input: DispatchInputFromResult,
    expanded: bool,
    arena: std.mem.Allocator,
) RenderError![]const Line {
    var co = lua_runtime.Coroutine.initFrom(state, from_L) catch return error.CoroutineFailed;
    defer co.deinit();

    _ = c.lua_rawgeti(co.L, c.LUA_REGISTRYINDEX, ref);
    if (c.lua_type(co.L, -1) != c.LUA_TFUNCTION) {
        c.lua_pop(co.L, 1);
        return error.NotAFunction;
    }

    pushAgentToolResult(co.L, input.result);

    c.lua_createtable(co.L, 0, 4);
    c.lua_pushinteger(co.L, @intCast(input.width));
    c.lua_setfield(co.L, -2, "width");
    c.lua_pushboolean(co.L, if (expanded) 1 else 0);
    c.lua_setfield(co.L, -2, "expanded");
    c.lua_pushboolean(co.L, if (input.is_error) 1 else 0);
    c.lua_setfield(co.L, -2, "is_error");
    lua_runtime.pushJsonValue(co.L, input.args) catch {};
    c.lua_setfield(co.L, -2, "args");

    const r = co.resumeWith(2) catch return error.CoroutineFailed;
    switch (r.status) {
        .yielded => return error.CoroutineFailed,
        .ok, .finished => {},
    }
    if (r.nresults == 0) return &.{};

    const top = c.lua_gettop(co.L);
    defer c.lua_settop(co.L, top - r.nresults);
    return parseReturnValue(arena, co.L, top);
}

/// Push `{ content = [...], is_error, details }` matching the shape
/// a Lua `execute` function returns. Image blocks are skipped —
/// renderers operating on binary content should look them up
/// through `details` instead.
fn pushAgentToolResult(L: *c.lua_State, r: agent_protocol.AgentToolResult) void {
    c.lua_createtable(L, 0, 3);

    c.lua_createtable(L, @intCast(r.content.len), 0);
    var i: c.lua_Integer = 1;
    for (r.content) |block| {
        switch (block) {
            .text => |t| {
                c.lua_createtable(L, 0, 2);
                _ = c.lua_pushlstring(L, "text".ptr, 4);
                c.lua_setfield(L, -2, "type");
                _ = c.lua_pushlstring(L, t.text.ptr, t.text.len);
                c.lua_setfield(L, -2, "text");
                c.lua_rawseti(L, -2, i);
                i += 1;
            },
            .image => {},
        }
    }
    c.lua_setfield(L, -2, "content");

    c.lua_pushboolean(L, if (r.is_error) 1 else 0);
    c.lua_setfield(L, -2, "is_error");

    lua_runtime.pushJsonValue(L, r.details) catch {
        c.lua_pushnil(L);
    };
    c.lua_setfield(L, -2, "details");

    lua_runtime.pushJsonValue(L, r.presentation) catch {
        c.lua_pushnil(L);
    };
    c.lua_setfield(L, -2, "presentation");
}

/// Run the render_result hook for `tool_name` if one exists, and
/// return an owned `*RenderedToolResult` with both collapsed and
/// expanded variants. Returns null on any failure — caller falls
/// back to default rendering.
///
/// MUST be called from the agent thread (the lua-owning thread).
/// Use `runner.assertOnLuaThread()` to verify.
pub fn dispatchRenderResult(
    allocator: std.mem.Allocator,
    runner: *runner_mod.ExtensionRunner,
    input: DispatchInput,
) ?*RenderedToolResult {
    const tool = runner.tool_registry.get(input.tool_name) orelse return null;
    const ref = tool.render_result_ref orelse return null;
    const state_ptr = runner.lua_state orelse return null;

    runner.assertOnLuaThread();

    runner.setModuleContext(state_ptr, tool.source.provenance);

    const out_state = allocator.create(RenderedToolResult) catch return null;
    out_state.* = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .collapsed = &.{},
        .expanded = &.{},
    };

    out_state.collapsed = runOne(state_ptr, ref, input, false, out_state.arena.allocator()) catch |err| {
        log.warn("render_result (collapsed) failed for '{s}': {s}", .{ input.tool_name, @errorName(err) });
        out_state.deinit(allocator);
        return null;
    };
    out_state.expanded = runOne(state_ptr, ref, input, true, out_state.arena.allocator()) catch |err| {
        log.warn("render_result (expanded) failed for '{s}': {s}", .{ input.tool_name, @errorName(err) });
        out_state.deinit(allocator);
        return null;
    };

    return out_state;
}

const RenderError = error{
    NotAFunction,
    CoroutineFailed,
    BadReturn,
    OutOfMemory,
    PushFailed,
};

fn runOneCall(
    state: *lua_runtime.LuaState,
    ref: c_int,
    input: DispatchCallInput,
    expanded: bool,
    arena: std.mem.Allocator,
) RenderError![]const Line {
    var co = lua_runtime.Coroutine.init(state) catch return error.CoroutineFailed;
    defer co.deinit();

    _ = c.lua_rawgeti(co.L, c.LUA_REGISTRYINDEX, ref);
    if (c.lua_type(co.L, -1) != c.LUA_TFUNCTION) {
        c.lua_pop(co.L, 1);
        return error.NotAFunction;
    }

    lua_runtime.pushJsonValue(co.L, input.args) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.PushFailed,
    };

    c.lua_createtable(co.L, 0, 2);
    c.lua_pushinteger(co.L, @intCast(input.width));
    c.lua_setfield(co.L, -2, "width");
    c.lua_pushboolean(co.L, if (expanded) 1 else 0);
    c.lua_setfield(co.L, -2, "expanded");

    const r = co.resumeWith(2) catch return error.CoroutineFailed;
    switch (r.status) {
        .yielded => return error.CoroutineFailed,
        .ok, .finished => {},
    }
    if (r.nresults == 0) return &.{};

    const top = c.lua_gettop(co.L);
    defer c.lua_settop(co.L, top - r.nresults);
    return parseReturnValue(arena, co.L, top);
}

fn runOne(
    state: *lua_runtime.LuaState,
    ref: c_int,
    input: DispatchInput,
    expanded: bool,
    arena: std.mem.Allocator,
) RenderError![]const Line {
    var co = lua_runtime.Coroutine.init(state) catch return error.CoroutineFailed;
    defer co.deinit();

    _ = c.lua_rawgeti(co.L, c.LUA_REGISTRYINDEX, ref);
    if (c.lua_type(co.L, -1) != c.LUA_TFUNCTION) {
        c.lua_pop(co.L, 1);
        return error.NotAFunction;
    }

    lua_runtime.pushJsonValue(co.L, input.result) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.PushFailed,
    };

    c.lua_createtable(co.L, 0, 4);
    c.lua_pushinteger(co.L, @intCast(input.width));
    c.lua_setfield(co.L, -2, "width");
    c.lua_pushboolean(co.L, if (expanded) 1 else 0);
    c.lua_setfield(co.L, -2, "expanded");
    c.lua_pushboolean(co.L, if (input.is_error) 1 else 0);
    c.lua_setfield(co.L, -2, "is_error");
    lua_runtime.pushJsonValue(co.L, input.args) catch {};
    c.lua_setfield(co.L, -2, "args");

    const r = co.resumeWith(2) catch return error.CoroutineFailed;
    switch (r.status) {
        .yielded => return error.CoroutineFailed,
        .ok, .finished => {},
    }
    if (r.nresults == 0) return &.{};

    const top = c.lua_gettop(co.L);
    defer c.lua_settop(co.L, top - r.nresults);

    return parseReturnValue(arena, co.L, top);
}

fn parseReturnValue(arena: std.mem.Allocator, L: *c.lua_State, idx: c_int) RenderError![]const Line {
    const ty = c.lua_type(L, idx);
    if (ty == c.LUA_TSTRING) {
        const text = try dupeLuaString(arena, L, idx);
        if (text.len == 0) return &.{};
        const spans = try arena.alloc(Span, 1);
        spans[0] = .{ .text = text };
        const lines = try arena.alloc(Line, 1);
        lines[0] = spans;
        return lines;
    }
    if (ty != c.LUA_TTABLE) return &.{};

    _ = c.lua_getfield(L, idx, "lines");
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TTABLE) return &.{};

    const n = c.lua_rawlen(L, -1);
    if (n == 0) return &.{};

    var lines: std.ArrayListUnmanaged(Line) = .empty;
    try lines.ensureTotalCapacity(arena, @intCast(n));

    var i: c.lua_Integer = 1;
    while (i <= @as(c.lua_Integer, @intCast(n))) : (i += 1) {
        _ = c.lua_rawgeti(L, -1, i);
        defer c.lua_pop(L, 1);

        const line = try parseLine(arena, L, -1);
        try lines.append(arena, line);
    }
    return lines.items;
}

fn parseLine(arena: std.mem.Allocator, L: *c.lua_State, idx: c_int) RenderError!Line {
    const ty = c.lua_type(L, idx);
    if (ty == c.LUA_TSTRING) {
        const text = try dupeLuaString(arena, L, idx);
        const spans = try arena.alloc(Span, 1);
        spans[0] = .{ .text = text };
        return spans;
    }
    if (ty != c.LUA_TTABLE) return &.{};

    const n = c.lua_rawlen(L, idx);
    if (n == 0) return &.{};

    var spans: std.ArrayListUnmanaged(Span) = .empty;
    try spans.ensureTotalCapacity(arena, @intCast(n));

    var i: c.lua_Integer = 1;
    while (i <= @as(c.lua_Integer, @intCast(n))) : (i += 1) {
        _ = c.lua_rawgeti(L, idx, i);
        defer c.lua_pop(L, 1);
        const span = parseSpan(arena, L, -1) catch continue;
        try spans.append(arena, span);
    }
    return spans.items;
}

fn parseSpan(arena: std.mem.Allocator, L: *c.lua_State, idx: c_int) RenderError!Span {
    const ty = c.lua_type(L, idx);
    if (ty == c.LUA_TSTRING) {
        const text = try dupeLuaString(arena, L, idx);
        return .{ .text = text };
    }
    if (ty != c.LUA_TTABLE) return error.BadReturn;

    var span: Span = .{ .text = "" };

    _ = c.lua_getfield(L, idx, "text");
    if (c.lua_type(L, -1) == c.LUA_TSTRING) {
        span.text = try dupeLuaString(arena, L, -1);
    }
    c.lua_pop(L, 1);

    _ = c.lua_getfield(L, idx, "fg");
    if (c.lua_type(L, -1) == c.LUA_TSTRING) {
        var len: usize = 0;
        if (c.lua_tolstring(L, -1, &len)) |p| {
            span.fg = parseFgColor(p[0..len]);
        }
    }
    c.lua_pop(L, 1);

    _ = c.lua_getfield(L, idx, "bg");
    if (c.lua_type(L, -1) == c.LUA_TSTRING) {
        var len: usize = 0;
        if (c.lua_tolstring(L, -1, &len)) |p| {
            span.bg = parseBgColor(p[0..len]);
        }
    }
    c.lua_pop(L, 1);

    span.bold = readBoolField(L, idx, "bold");
    span.dim = readBoolField(L, idx, "dim");
    span.italic = readBoolField(L, idx, "italic");
    span.underline = readBoolField(L, idx, "underline");

    return span;
}

fn readBoolField(L: *c.lua_State, idx: c_int, field: [:0]const u8) bool {
    _ = c.lua_getfield(L, idx, field.ptr);
    defer c.lua_pop(L, 1);
    return c.lua_toboolean(L, -1) != 0;
}

fn dupeLuaString(arena: std.mem.Allocator, L: *c.lua_State, idx: c_int) RenderError![]const u8 {
    var len: usize = 0;
    const p = c.lua_tolstring(L, idx, &len) orelse return error.BadReturn;
    return arena.dupe(u8, p[0..len]) catch error.OutOfMemory;
}

fn parseFgColor(name: []const u8) ?theme_mod.FgColor {
    return theme_tokens.parseFgWireName(name);
}

fn parseBgColor(name: []const u8) ?theme_mod.BgColor {
    return theme_tokens.parseBgWireName(name);
}

const testing = std.testing;
const api_v3 = @import("api_v3.zig");

test "dispatchRenderCall parses args into an owned call presentation document" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();
    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();
    runner.attachLuaState(&state);
    api_v3.install(&state, &runner);

    try state.doString(
        \\zi.tool({
        \\  name = "callable",
        \\  description = "callable",
        \\  parameters = { type = "object" },
        \\  execute = function() end,
        \\  render_call = function(args, ctx)
        \\    return {
        \\      lines = { { { text = "call ", fg = "muted" }, { text = args.path, fg = "accent", bold = ctx.width == 80 } } }
        \\    }
        \\  end,
        \\})
    , "register");

    var args_obj: std.json.ObjectMap = .{};
    defer args_obj.deinit(testing.allocator);
    try args_obj.put(testing.allocator, "path", .{ .string = "src/main.zig" });

    const out = dispatchRenderCall(testing.allocator, &runner, .{
        .tool_name = "callable",
        .args = .{ .object = args_obj },
        .width = 80,
    }) orelse return error.TestUnexpectedResult;
    defer out.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), out.collapsed.len);
    try testing.expectEqualStrings("call ", out.collapsed[0][0].text);
    try testing.expectEqual(theme_mod.FgColor.muted, out.collapsed[0][0].fg.?);
    try testing.expectEqualStrings("src/main.zig", out.collapsed[0][1].text);
    try testing.expectEqual(theme_mod.FgColor.accent, out.collapsed[0][1].fg.?);
    try testing.expect(out.collapsed[0][1].bold);
}

test "dispatchRenderResult renders collapsed and expanded result presentations" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();
    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();
    runner.attachLuaState(&state);
    api_v3.install(&state, &runner);

    try state.doString(
        \\zi.tool({
        \\  name = "rich",
        \\  description = "rich",
        \\  parameters = { type = "object" },
        \\  execute = function() end,
        \\  render_result = function(result, ctx)
        \\    if not ctx.expanded then return "" end
        \\    return {
        \\      lines = {
        \\        {
        \\          { text = "Task", fg = "accent", bold = true },
        \\          { text = ctx.is_error and " failed" or " done", fg = "dim" },
        \\        },
        \\        "simple string line",
        \\      },
        \\    }
        \\  end,
        \\})
    , "register");

    const out = dispatchRenderResult(testing.allocator, &runner, .{
        .tool_name = "rich",
        .args = .null,
        .result = .null,
        .width = 80,
        .is_error = false,
    }) orelse return error.TestUnexpectedResult;
    defer out.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), out.collapsed.len);
    try testing.expectEqual(@as(usize, 2), out.expanded.len);
    try testing.expectEqual(@as(usize, 2), out.expanded[0].len);
    try testing.expectEqualStrings("Task", out.expanded[0][0].text);
    try testing.expectEqual(theme_mod.FgColor.accent, out.expanded[0][0].fg.?);
    try testing.expect(out.expanded[0][0].bold);
    try testing.expectEqualStrings(" done", out.expanded[0][1].text);
    try testing.expectEqual(theme_mod.FgColor.dim, out.expanded[0][1].fg.?);
    try testing.expectEqualStrings("simple string line", out.expanded[1][0].text);
}

test "dispatchRenderResultFromResult owns rendered output after host result changes" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();
    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();
    runner.attachLuaState(&state);
    api_v3.install(&state, &runner);

    try state.doString(
        \\zi.tool({
        \\  name = "owned",
        \\  description = "owned",
        \\  parameters = { type = "object" },
        \\  execute = function() end,
        \\  render_result = function(result, ctx)
        \\    return result.content[1].text
        \\  end,
        \\})
    , "register");

    const text_buf = try testing.allocator.dupe(u8, "owned by host");
    defer testing.allocator.free(text_buf);
    var blocks = [_]agent_protocol.AgentToolResult.ContentBlock{
        .{ .text = .{ .text = text_buf } },
    };

    const out = dispatchRenderResultFromResult(testing.allocator, &runner, .{
        .tool_name = "owned",
        .args = .null,
        .result = .{ .content = &blocks },
        .width = 80,
        .is_error = false,
    }) orelse return error.TestUnexpectedResult;
    defer out.deinit(testing.allocator);

    @memset(text_buf, 'x');
    try testing.expectEqualStrings("owned by host", out.collapsed[0][0].text);
    try testing.expectEqualStrings("owned by host", out.expanded[0][0].text);
}

test "renderer dispatch fails open for missing hooks and lua errors" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();
    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();
    runner.attachLuaState(&state);
    api_v3.install(&state, &runner);

    try state.doString(
        \\zi.tool({
        \\  name = "plain",
        \\  description = "no renderer",
        \\  parameters = { type = "object" },
        \\  execute = function() end,
        \\})
        \\zi.tool({
        \\  name = "bad_call",
        \\  description = "bad call",
        \\  parameters = { type = "object" },
        \\  execute = function() end,
        \\  render_call = function() error("nope") end,
        \\})
        \\zi.tool({
        \\  name = "bad_result",
        \\  description = "bad result",
        \\  parameters = { type = "object" },
        \\  execute = function() end,
        \\  render_result = function() error("nope") end,
        \\})
    , "register");

    try testing.expect(dispatchRenderResult(testing.allocator, &runner, .{
        .tool_name = "plain",
        .args = .null,
        .result = .null,
        .width = 80,
        .is_error = false,
    }) == null);

    try testing.expect(dispatchRenderCall(testing.allocator, &runner, .{
        .tool_name = "bad_call",
        .args = .null,
        .width = 80,
    }) == null);

    try testing.expect(dispatchRenderResult(testing.allocator, &runner, .{
        .tool_name = "bad_result",
        .args = .null,
        .result = .null,
        .width = 80,
        .is_error = false,
    }) == null);
}
