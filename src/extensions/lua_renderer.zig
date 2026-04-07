//! Lua-driven tool renderers.
//!
//! Bridges `zi.register_tool({ render_result = fn(result, ctx) ... })`
//! to the TUI's cell-painting transcript. Runs on the thread that
//! drains the agent event queue (TUI thread in interactive mode,
//! synthetic in tests) — serialized against the agent thread's
//! `lua_tool.execute` via the runner's lua mutex.
//!
//! ## Flow
//!
//! ```text
//! agent: tool finishes
//!   │
//!   ▼
//! event queue drain on TUI thread
//!   │
//!   ▼
//! Transcript.toolSetFinalResult(id, result, is_error)
//!   │
//!   ├─► lua_renderer.dispatchRenderResult(runner, tool_name,
//!   │                                     args, result, width, expanded)
//!   │    ├─ acquires runner lua mutex
//!   │    ├─ spawns a fresh Coroutine on runner.lua_state
//!   │    ├─ pushes ref'd render_result fn + restricted ctx table
//!   │    ├─ resumeWith(2), parses the returned span tree
//!   │    ├─ deep-copies strings into an arena we own
//!   │    └─ returns owned *LuaRenderState (or null on any failure)
//!   │
//!   ▼
//! ToolExecution.lua_render_state = state
//!   │
//!   ▼
//! Next render frame: transcript paints spans from state.lines[expanded]
//! ```
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
//! Every `*LuaRenderState` is arena-allocated: one arena per
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
const theme_mod = @import("../tui/theme.zig");
const agent_protocol = @import("../agent/protocol.zig");

const c = lua_runtime.c;
const log = std.log.scoped(.zi_lua_renderer);

// ─────────────────────────────────────────────────────────────────
// Span data model
// ─────────────────────────────────────────────────────────────────

/// A single styled text run inside a line. Width-agnostic: the
/// painter handles truncation at paint time based on the active
/// region width.
///
/// `fg` and `bg` are theme role indices (resolved to concrete
/// colors by the painter using the active `Theme`). Storing role
/// names rather than RGB preserves theme swaps at paint time.
pub const Span = struct {
    text: []const u8,
    fg: ?theme_mod.FgColor = null,
    bg: ?theme_mod.BgColor = null,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
};

pub const Line = []const Span;

/// Arena-owned set of rendered lines. Two variants because the
/// agent tree view shows a different shape when collapsed vs
/// expanded (tool-call list length, summary presence). Both are
/// computed up front so the TUI can toggle without re-dispatching
/// through Lua.
pub const LuaRenderState = struct {
    arena: std.heap.ArenaAllocator,
    collapsed: []const Line,
    expanded: []const Line,

    pub fn deinit(self: *LuaRenderState, parent_allocator: std.mem.Allocator) void {
        self.arena.deinit();
        parent_allocator.destroy(self);
    }

    /// Type-erased deinit fn for `runner.PendingRender`. The runner
    /// stores `*anyopaque` to avoid a circular import; this is the
    /// adapter that bridges back to the typed pointer.
    pub fn deinitOpaque(state: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *LuaRenderState = @ptrCast(@alignCast(state));
        self.deinit(allocator);
    }
};

// ─────────────────────────────────────────────────────────────────
// Dispatch
// ─────────────────────────────────────────────────────────────────

pub const DispatchInput = struct {
    tool_name: []const u8,
    args: std.json.Value,
    result: std.json.Value,
    width: u32,
    is_error: bool,
};

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
) ?*LuaRenderState {
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
) ?*LuaRenderState {
    const tool = runner.tool_registry.get(input.tool_name) orelse return null;
    const ref = tool.render_result_ref orelse return null;
    const state_ptr = runner.lua_state orelse return null;
    const from_L = current_L orelse state_ptr.L;

    runner.assertOnLuaThread();

    const out_state = allocator.create(LuaRenderState) catch return null;
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

    // arg 1: result table — built by hand from AgentToolResult
    pushAgentToolResult(co.L, input.result);

    // arg 2: ctx
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

    // content array
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
            .image => {
                // skip images for now — renderers use details instead
            },
        }
    }
    c.lua_setfield(L, -2, "content");

    c.lua_pushboolean(L, if (r.is_error) 1 else 0);
    c.lua_setfield(L, -2, "is_error");

    lua_runtime.pushJsonValue(L, r.details) catch {
        c.lua_pushnil(L);
    };
    c.lua_setfield(L, -2, "details");
}

/// Run the render_result hook for `tool_name` if one exists, and
/// return an owned `*LuaRenderState` with both collapsed and
/// expanded variants. Returns null on any failure — caller falls
/// back to default rendering.
///
/// MUST be called from the agent thread (the lua-owning thread).
/// Use `runner.assertOnLuaThread()` to verify.
pub fn dispatchRenderResult(
    allocator: std.mem.Allocator,
    runner: *runner_mod.ExtensionRunner,
    input: DispatchInput,
) ?*LuaRenderState {
    const tool = runner.tool_registry.get(input.tool_name) orelse return null;
    const ref = tool.render_result_ref orelse return null;
    const state_ptr = runner.lua_state orelse return null;

    runner.assertOnLuaThread();

    // Arena owns every string we produce for the returned state.
    const out_state = allocator.create(LuaRenderState) catch return null;
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

fn runOne(
    state: *lua_runtime.LuaState,
    ref: c_int,
    input: DispatchInput,
    expanded: bool,
    arena: std.mem.Allocator,
) RenderError![]const Line {
    var co = lua_runtime.Coroutine.init(state) catch return error.CoroutineFailed;
    defer co.deinit();

    // Push the render_result function.
    _ = c.lua_rawgeti(co.L, c.LUA_REGISTRYINDEX, ref);
    if (c.lua_type(co.L, -1) != c.LUA_TFUNCTION) {
        c.lua_pop(co.L, 1);
        return error.NotAFunction;
    }

    // arg 1: result table ({ content, is_error, details }).
    lua_runtime.pushJsonValue(co.L, input.result) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.PushFailed,
    };

    // arg 2: ctx table { width, expanded, is_error, args }.
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

    // Parse return shape:
    //   - string → single-line single-span
    //   - table with .lines (array of line-arrays-of-spans)
    const top = c.lua_gettop(co.L);
    defer c.lua_settop(co.L, top - r.nresults);

    return parseReturnValue(arena, co.L, top);
}

fn parseReturnValue(arena: std.mem.Allocator, L: *c.lua_State, idx: c_int) RenderError![]const Line {
    const ty = c.lua_type(L, idx);
    if (ty == c.LUA_TSTRING) {
        // shortcut: single plain line
        const text = try dupeLuaString(arena, L, idx);
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
    // A line is either a table of spans OR a bare string (which we
    // coerce to a single default-styled span for ergonomics).
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

// ─────────────────────────────────────────────────────────────────
// Theme role mapping
// ─────────────────────────────────────────────────────────────────

fn parseFgColor(name: []const u8) ?theme_mod.FgColor {
    const T = theme_mod.FgColor;
    const map = .{
        .{ "accent", T.accent },
        .{ "border", T.border },
        .{ "border_accent", T.border_accent },
        .{ "border_muted", T.border_muted },
        .{ "success", T.success },
        .{ "error", T.@"error" },
        .{ "warning", T.warning },
        .{ "muted", T.muted },
        .{ "dim", T.dim },
        .{ "text", T.text },
        .{ "thinking_text", T.thinking_text },
        .{ "user_message_text", T.user_message_text },
        .{ "custom_message_text", T.custom_message_text },
        .{ "custom_message_label", T.custom_message_label },
        .{ "tool_title", T.tool_title },
        .{ "tool_output", T.tool_output },
        .{ "md_heading", T.md_heading },
        .{ "md_link", T.md_link },
        .{ "md_code", T.md_code },
    };
    inline for (map) |pair| {
        if (std.mem.eql(u8, name, pair[0])) return pair[1];
    }
    return null;
}

fn parseBgColor(name: []const u8) ?theme_mod.BgColor {
    const T = theme_mod.BgColor;
    if (std.mem.eql(u8, name, "selected_bg")) return T.selected_bg;
    if (std.mem.eql(u8, name, "tool_pending_bg")) return T.tool_pending_bg;
    if (std.mem.eql(u8, name, "tool_success_bg")) return T.tool_success_bg;
    if (std.mem.eql(u8, name, "tool_error_bg")) return T.tool_error_bg;
    return null;
}

// ─────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────

const testing = std.testing;
const api = @import("api.zig");

test "dispatchRenderResult with no hook returns null" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();
    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();
    runner.attachLuaState(&state);
    api.installZiTable(&state, &runner);

    try state.doString(
        \\zi.register_tool({
        \\  name = "plain",
        \\  description = "no renderer",
        \\  parameters = { type = "object" },
        \\  execute = function() end,
        \\})
    , "register");

    const out = dispatchRenderResult(testing.allocator, &runner, .{
        .tool_name = "plain",
        .args = .null,
        .result = .null,
        .width = 80,
        .is_error = false,
    });
    try testing.expect(out == null);
}

test "dispatchRenderResult parses string shortcut into one-line one-span" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();
    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();
    runner.attachLuaState(&state);
    api.installZiTable(&state, &runner);

    try state.doString(
        \\zi.register_tool({
        \\  name = "shortcut",
        \\  description = "short",
        \\  parameters = { type = "object" },
        \\  execute = function() end,
        \\  render_result = function(result, ctx)
        \\    return "hello world"
        \\  end,
        \\})
    , "register");

    const out = dispatchRenderResult(testing.allocator, &runner, .{
        .tool_name = "shortcut",
        .args = .null,
        .result = .null,
        .width = 80,
        .is_error = false,
    }) orelse return error.TestUnexpectedResult;
    defer out.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), out.collapsed.len);
    try testing.expectEqual(@as(usize, 1), out.collapsed[0].len);
    try testing.expectEqualStrings("hello world", out.collapsed[0][0].text);
}

test "dispatchRenderResult parses structured spans with theme roles" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();
    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();
    runner.attachLuaState(&state);
    api.installZiTable(&state, &runner);

    try state.doString(
        \\zi.register_tool({
        \\  name = "rich",
        \\  description = "rich",
        \\  parameters = { type = "object" },
        \\  execute = function() end,
        \\  render_result = function(result, ctx)
        \\    return {
        \\      lines = {
        \\        {
        \\          { text = "Task", fg = "accent", bold = true },
        \\          { text = " done", fg = "dim" },
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

    try testing.expectEqual(@as(usize, 2), out.collapsed.len);
    try testing.expectEqual(@as(usize, 2), out.collapsed[0].len);
    try testing.expectEqualStrings("Task", out.collapsed[0][0].text);
    try testing.expectEqual(theme_mod.FgColor.accent, out.collapsed[0][0].fg.?);
    try testing.expect(out.collapsed[0][0].bold);
    try testing.expectEqualStrings(" done", out.collapsed[0][1].text);
    try testing.expectEqual(theme_mod.FgColor.dim, out.collapsed[0][1].fg.?);
    try testing.expectEqualStrings("simple string line", out.collapsed[1][0].text);
}

test "dispatchRenderResult passes ctx.expanded differently to collapsed and expanded runs" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();
    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();
    runner.attachLuaState(&state);
    api.installZiTable(&state, &runner);

    try state.doString(
        \\zi.register_tool({
        \\  name = "variant",
        \\  description = "variant",
        \\  parameters = { type = "object" },
        \\  execute = function() end,
        \\  render_result = function(result, ctx)
        \\    return ctx.expanded and "expanded form" or "collapsed form"
        \\  end,
        \\})
    , "register");

    const out = dispatchRenderResult(testing.allocator, &runner, .{
        .tool_name = "variant",
        .args = .null,
        .result = .null,
        .width = 80,
        .is_error = false,
    }) orelse return error.TestUnexpectedResult;
    defer out.deinit(testing.allocator);

    try testing.expectEqualStrings("collapsed form", out.collapsed[0][0].text);
    try testing.expectEqualStrings("expanded form", out.expanded[0][0].text);
}

test "dispatchRenderResult on lua error returns null" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();
    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();
    runner.attachLuaState(&state);
    api.installZiTable(&state, &runner);

    try state.doString(
        \\zi.register_tool({
        \\  name = "boom",
        \\  description = "boom",
        \\  parameters = { type = "object" },
        \\  execute = function() end,
        \\  render_result = function() error("nope") end,
        \\})
    , "register");

    const out = dispatchRenderResult(testing.allocator, &runner, .{
        .tool_name = "boom",
        .args = .null,
        .result = .null,
        .width = 80,
        .is_error = false,
    });
    try testing.expect(out == null);
}
