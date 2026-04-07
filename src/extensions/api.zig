//! `zi.*` Lua API surface — host functions exposed to extensions.
//!
//! Each function in this file is a C function (`callconv(.c)`)
//! registered into the Lua state's globals as a field of a single
//! `zi` table. Extensions call them like ordinary Lua functions:
//!
//! ```lua
//! return function(zi)
//!   zi.register_tool({ name = "...", ... })
//! end
//! ```
//!
//! The `ExtensionRunner` pointer travels into each C function via a
//! light-userdata upvalue captured at install time
//! (`installZiTable`). C functions read it back through
//! `lua_upvalueindex(1)`. This sidesteps Lua globals entirely — two
//! `ExtensionRunner`s sharing one binary would still each have their
//! own `zi` table bound to their own runner.
//!
//! Ownership rules (docs/extensions.md §Ownership-and-Reload §Invariants):
//!
//!   1. Every string we read from Lua is duped via the runner's
//!      allocator BEFORE the Lua stack unwinds. Lua's GC must not
//!      see a slice that zig still holds.
//!
//!   2. Tool parameter schemas are deep-cloned through
//!      `lua_runtime.luaValueToJson` into runner-allocator memory.
//!      The original Lua table can be garbage-collected the moment
//!      this function returns.
//!
//!   3. The `execute` Lua function is captured via `luaL_ref` so the
//!      Lua GC can't reap the closure between registration and the
//!      first invocation. The ref is stored in `ExtensionTool.impl.lua`
//!      as a raw `c_int` and released when the runner closes its
//!      Lua state at deinit (closing the state collects every ref).
//!
//! Error model: failures inside a C function call `luaL_error`,
//! which longjmps back to the Lua caller. Lua-side this surfaces as
//! a normal `error()` and can be caught with `pcall`. We use it for
//! validation failures (missing required field, wrong type, etc.).
//! For "tool already registered" we DO NOT error — first-wins is a
//! silent drop with a diagnostic log entry, matching the spec.

const std = @import("std");
const lua_runtime = @import("lua_runtime.zig");
const runner_mod = @import("runner.zig");
const tool_registry = @import("registries/tool_registry.zig");
const event_registry = @import("registries/event_registry.zig");

const c = lua_runtime.c;
const log = std.log.scoped(.zi_api);

/// Install the `zi` table as a Lua global, populated with every host
/// C function. Each cfunction captures `runner` as its single
/// upvalue.
///
/// Idempotent within one Lua state — calling twice replaces the
/// global with a fresh table. Used by D3's runtime construction and
/// by tests that build a state inline.
pub fn installZiTable(state: *lua_runtime.LuaState, runner: *runner_mod.ExtensionRunner) void {
    const L = state.L;
    c.lua_createtable(L, 0, 8);

    // zi.register_tool
    state.pushCClosureWithUserdata(ziRegisterTool, runner);
    c.lua_setfield(L, -2, "register_tool");

    // zi.on
    state.pushCClosureWithUserdata(ziOn, runner);
    c.lua_setfield(L, -2, "on");

    // Install as a global named "zi".
    c.lua_setglobal(L, "zi");
}

// ─────────────────────────────────────────────────────────────────────────
// zi.register_tool
// ─────────────────────────────────────────────────────────────────────────

fn ziRegisterTool(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = runnerFromUpvalue(L);

    if (c.lua_type(L, 1) != c.LUA_TTABLE) {
        return luaError(L, "register_tool: expected a table argument");
    }

    // Build the ExtensionTool incrementally so each errdefer in the
    // builder reverses exactly the allocations made before the
    // failure point. On success, ownership transfers wholesale into
    // the registry.
    var built = buildExtensionTool(L, runner) catch |err| {
        return luaError(L, switch (err) {
            error.MissingName => "register_tool: missing required field 'name'",
            error.MissingDescription => "register_tool: missing required field 'description'",
            error.MissingParameters => "register_tool: missing required field 'parameters'",
            error.MissingExecute => "register_tool: missing required field 'execute'",
            error.InvalidExecute => "register_tool: 'execute' must be a function",
            error.InvalidName => "register_tool: 'name' must be a string",
            error.InvalidDescription => "register_tool: 'description' must be a string",
            error.InvalidLabel => "register_tool: 'label' must be a string",
            error.InvalidPromptSnippet => "register_tool: 'prompt_snippet' must be a string",
            error.InvalidPromptGuidelines => "register_tool: 'prompt_guidelines' must be an array of strings",
            error.InvalidParameters => "register_tool: 'parameters' must be a table",
            error.OutOfMemory => "register_tool: out of memory",
            error.UnsupportedLuaType => "register_tool: parameter schema contains an unsupported value",
            error.InvalidUtf8 => "register_tool: parameter schema contains invalid UTF-8",
        });
    };

    const accepted = runner.tool_registry.register(built) catch {
        // OOM during registry insert: free what we built and bail.
        freeBuiltTool(runner.allocator, &built);
        return luaError(L, "register_tool: registry insert failed");
    };

    if (!accepted) {
        // First-wins drop. Existing entry retains its source. We
        // free the duped strings and ref, log a diagnostic, and
        // return false to Lua so user code can branch on it.
        log.warn("tool '{s}' already registered (source: {s}); ignoring later registration from {s}", .{
            built.name,
            (runner.tool_registry.get(built.name) orelse unreachable).source.id,
            built.source.id,
        });
        // Release the captured Lua function ref since we won't use it.
        if (built.impl == .lua) c.luaL_unref(L, c.LUA_REGISTRYINDEX, built.impl.lua);
        freeBuiltTool(runner.allocator, &built);
        c.lua_pushboolean(L, 0);
        return 1;
    }

    c.lua_pushboolean(L, 1);
    return 1;
}

const BuildError = error{
    MissingName,
    MissingDescription,
    MissingParameters,
    MissingExecute,
    InvalidName,
    InvalidLabel,
    InvalidDescription,
    InvalidPromptSnippet,
    InvalidPromptGuidelines,
    InvalidParameters,
    InvalidExecute,
    OutOfMemory,
    UnsupportedLuaType,
    InvalidUtf8,
};

/// Walk the Lua table at stack index 1 and produce an
/// `ExtensionTool` whose owned fields all live in the runner's
/// allocator. On any error every allocation made so far is freed.
///
/// Stack discipline: leaves the stack at the same height as on
/// entry. Each `lua_getfield` pushes one value; we pop it after
/// extraction. The `execute` function gets `luaL_ref`d, which pops
/// it from the stack and returns a registry slot.
fn buildExtensionTool(
    L: *c.lua_State,
    runner: *runner_mod.ExtensionRunner,
) BuildError!tool_registry.ExtensionTool {
    const a = runner.allocator;

    const name = try requireString(L, 1, "name", a, error.MissingName, error.InvalidName);
    errdefer a.free(name);

    const description = try requireString(L, 1, "description", a, error.MissingDescription, error.InvalidDescription);
    errdefer a.free(description);

    // Optional label defaults to name (deep-cloned so the registry
    // never depends on the name slice's lifetime).
    const label = blk: {
        const opt = try optionalString(L, 1, "label", a, error.InvalidLabel);
        if (opt) |s| break :blk s;
        break :blk try a.dupe(u8, name);
    };
    errdefer a.free(label);

    const prompt_snippet = try optionalString(L, 1, "prompt_snippet", a, error.InvalidPromptSnippet);
    errdefer if (prompt_snippet) |s| a.free(s);

    const prompt_guidelines = try optionalStringArray(L, 1, "prompt_guidelines", a, error.InvalidPromptGuidelines);
    errdefer freeStringArray(a, prompt_guidelines);

    // parameters: required, must be a table, deep-cloned to JSON.
    _ = c.lua_getfield(L, 1, "parameters");
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) == c.LUA_TNIL) return error.MissingParameters;
    if (c.lua_type(L, -1) != c.LUA_TTABLE) return error.InvalidParameters;
    const parameters = try lua_runtime.luaValueToJson(L, -1, a);
    errdefer lua_runtime.freeJsonValue(a, parameters);

    // execute: required, must be a function. luaL_ref pops the
    // function from the stack and returns a registry slot. We do
    // this LAST so the errdefers above don't accidentally leak the
    // ref on a later failure.
    _ = c.lua_getfield(L, 1, "execute");
    if (c.lua_type(L, -1) == c.LUA_TNIL) {
        c.lua_pop(L, 1);
        return error.MissingExecute;
    }
    if (c.lua_type(L, -1) != c.LUA_TFUNCTION) {
        c.lua_pop(L, 1);
        return error.InvalidExecute;
    }
    const execute_ref = c.luaL_ref(L, c.LUA_REGISTRYINDEX);

    return .{
        .name = name,
        .label = label,
        .description = description,
        .parameters = parameters,
        .prompt_snippet = prompt_snippet,
        .prompt_guidelines = prompt_guidelines,
        .impl = .{ .lua = execute_ref },
        // For E1 every Lua-registered tool reports its source as
        // "lua". The loader will overwrite this with a meaningful
        // path identifier in C2-era plumbing.
        .source = .{ .kind = "lua", .id = "lua" },
    };
}

/// Free every owned field of a partially-built tool. Used by the
/// rejection path (`!accepted`) and by registry-insert OOM. Mirrors
/// `ToolRegistry.freeEntry` minus the registry-managed bookkeeping.
fn freeBuiltTool(allocator: std.mem.Allocator, tool: *tool_registry.ExtensionTool) void {
    allocator.free(tool.name);
    allocator.free(tool.label);
    allocator.free(tool.description);
    if (tool.prompt_snippet) |s| allocator.free(s);
    freeStringArray(allocator, tool.prompt_guidelines);
    lua_runtime.freeJsonValue(allocator, tool.parameters);
}

// ─────────────────────────────────────────────────────────────────────────
// zi.on
// ─────────────────────────────────────────────────────────────────────────

fn ziOn(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = runnerFromUpvalue(L);

    // arg 1: event name (string)
    if (c.lua_type(L, 1) != c.LUA_TSTRING) {
        return luaError(L, "zi.on: expected event name as first argument");
    }
    var name_len: usize = 0;
    const name_ptr = c.lua_tolstring(L, 1, &name_len) orelse return luaError(L, "zi.on: invalid event name");
    const event_name = name_ptr[0..name_len];

    const kind = parseEventKind(event_name) orelse {
        // Build the error message on the Lua stack so the runner's
        // allocator stays out of the error path. lua_pushfstring is
        // the canonical way and Lua-internal-allocator-friendly.
        _ = c.lua_pushfstring(L, "zi.on: unknown event '%s'", name_ptr);
        _ = c.lua_error(L);
        return 0;
    };

    // arg 2: handler (function)
    if (c.lua_type(L, 2) != c.LUA_TFUNCTION) {
        return luaError(L, "zi.on: expected handler function as second argument");
    }

    // Capture the handler via luaL_ref. We need it on top of the
    // stack first, so duplicate arg 2 with lua_pushvalue. luaL_ref
    // pops what's on top.
    c.lua_pushvalue(L, 2);
    const handler_ref = c.luaL_ref(L, c.LUA_REGISTRYINDEX);
    if (handler_ref == c.LUA_REFNIL or handler_ref == c.LUA_NOREF) {
        return luaError(L, "zi.on: failed to capture handler reference");
    }

    runner.event_registry.subscribe(kind, .{
        .lua_ref = handler_ref,
        // Same source-id placeholder as register_tool — the loader
        // will overwrite this with an extension path once factory
        // invocation lands. Borrowed string literal, no allocation.
        .source_id = "lua",
    }) catch {
        // OOM during subscribe: release the handler ref so the Lua
        // GC can reclaim it, then surface as a Lua error.
        c.luaL_unref(L, c.LUA_REGISTRYINDEX, handler_ref);
        return luaError(L, "zi.on: subscribe failed");
    };

    return 0;
}

/// Map a Lua-side event name (the same string the spec uses in
/// `zi.on("name", ...)` examples) to an `EventKind` enum value.
/// Returns null on unknown names — the caller raises a Lua error
/// with the offending string in the message.
///
/// Spec source: docs/extensions.md §Event Hooks lines 137-170.
/// We support the v1-checked subset; v2 events get added here as
/// their dispatch points come online (D4 grows the table when it
/// hooks new event sources).
fn parseEventKind(name: []const u8) ?event_registry.EventKind {
    const Pair = struct { name: []const u8, kind: event_registry.EventKind };
    const table = [_]Pair{
        // lifecycle
        .{ .name = "agent_start", .kind = .agent_start },
        .{ .name = "agent_end", .kind = .agent_end },
        .{ .name = "turn_start", .kind = .turn_start },
        .{ .name = "turn_end", .kind = .turn_end },
        .{ .name = "message_start", .kind = .message_start },
        .{ .name = "message_update", .kind = .message_update },
        .{ .name = "message_end", .kind = .message_end },
        // tool
        .{ .name = "tool_execution_start", .kind = .tool_execution_start },
        .{ .name = "tool_execution_update", .kind = .tool_execution_update },
        .{ .name = "tool_execution_end", .kind = .tool_execution_end },
        .{ .name = "tool_call", .kind = .tool_call },
        .{ .name = "tool_result", .kind = .tool_result },
        // session
        .{ .name = "session_start", .kind = .session_start },
        .{ .name = "session_shutdown", .kind = .session_shutdown },
        // meta
        .{ .name = "model_select", .kind = .model_select },
    };
    for (table) |p| {
        if (std.mem.eql(u8, p.name, name)) return p.kind;
    }
    return null;
}

// ─────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────

fn runnerFromUpvalue(L: *c.lua_State) *runner_mod.ExtensionRunner {
    const ud = c.lua_touserdata(L, c.lua_upvalueindex(1));
    return @ptrCast(@alignCast(ud.?));
}

/// Push an error message onto the Lua stack and longjmp out of the
/// C function. Returns `c_int` so callers can `return luaError(...)`.
/// `lua_error` does not return — the cast is to satisfy the type
/// checker for the unreachable code path.
fn luaError(L: *c.lua_State, msg: [:0]const u8) c_int {
    _ = c.lua_pushstring(L, msg.ptr);
    _ = c.lua_error(L);
    return 0;
}

/// Read a required string field. Pushes/pops one stack slot.
fn requireString(
    L: *c.lua_State,
    table_idx: c_int,
    field: [:0]const u8,
    allocator: std.mem.Allocator,
    missing_err: BuildError,
    invalid_err: BuildError,
) BuildError![]const u8 {
    _ = c.lua_getfield(L, table_idx, field.ptr);
    defer c.lua_pop(L, 1);

    switch (c.lua_type(L, -1)) {
        c.LUA_TNIL => return missing_err,
        c.LUA_TSTRING => {
            var len: usize = 0;
            const ptr = c.lua_tolstring(L, -1, &len) orelse return error.InvalidUtf8;
            return allocator.dupe(u8, ptr[0..len]) catch return error.OutOfMemory;
        },
        else => return invalid_err,
    }
}

/// Read an optional string field. Returns null if absent (nil), or
/// the duped slice. Errors only on type mismatch.
fn optionalString(
    L: *c.lua_State,
    table_idx: c_int,
    field: [:0]const u8,
    allocator: std.mem.Allocator,
    invalid_err: BuildError,
) BuildError!?[]const u8 {
    _ = c.lua_getfield(L, table_idx, field.ptr);
    defer c.lua_pop(L, 1);

    switch (c.lua_type(L, -1)) {
        c.LUA_TNIL => return null,
        c.LUA_TSTRING => {
            var len: usize = 0;
            const ptr = c.lua_tolstring(L, -1, &len) orelse return error.InvalidUtf8;
            return allocator.dupe(u8, ptr[0..len]) catch return error.OutOfMemory;
        },
        else => return invalid_err,
    }
}

/// Read an optional array of strings. Empty/absent → empty slice
/// (caller doesn't need to special-case null). Type mismatch on
/// the table or any element → invalid_err.
fn optionalStringArray(
    L: *c.lua_State,
    table_idx: c_int,
    field: [:0]const u8,
    allocator: std.mem.Allocator,
    invalid_err: BuildError,
) BuildError![]const []const u8 {
    _ = c.lua_getfield(L, table_idx, field.ptr);
    defer c.lua_pop(L, 1);

    switch (c.lua_type(L, -1)) {
        c.LUA_TNIL => return &.{},
        c.LUA_TTABLE => {},
        else => return invalid_err,
    }

    const len = c.lua_rawlen(L, -1);
    if (len == 0) return &.{};

    const arr = allocator.alloc([]const u8, len) catch return error.OutOfMemory;
    var built: usize = 0;
    errdefer {
        for (arr[0..built]) |s| allocator.free(s);
        allocator.free(arr);
    }

    var i: c.lua_Integer = 1;
    while (@as(usize, @intCast(i)) <= len) : (i += 1) {
        _ = c.lua_rawgeti(L, -1, i);
        defer c.lua_pop(L, 1);
        if (c.lua_type(L, -1) != c.LUA_TSTRING) return invalid_err;

        var s_len: usize = 0;
        const ptr = c.lua_tolstring(L, -1, &s_len) orelse return error.InvalidUtf8;
        arr[built] = allocator.dupe(u8, ptr[0..s_len]) catch return error.OutOfMemory;
        built += 1;
    }

    return arr;
}

fn freeStringArray(allocator: std.mem.Allocator, arr: []const []const u8) void {
    for (arr) |s| allocator.free(s);
    if (arr.len > 0) allocator.free(arr);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "zi.register_tool registers a Lua-defined tool end-to-end" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();

    installZiTable(&state, &runner);

    // Run an extension that registers a single tool. Note we call
    // the factory inline rather than going through a `return
    // function(zi) ... end` wrapper — that wrapper is the loader's
    // job (C2/C3 era), not E1's.
    try state.doString(
        \\zi.register_tool({
        \\  name = "finder",
        \\  label = "Finder",
        \\  description = "search the codebase",
        \\  prompt_snippet = "use finder for multi-step search",
        \\  prompt_guidelines = { "prefer over chained grep", "parallelize independent queries" },
        \\  parameters = {
        \\    type = "object",
        \\    properties = {
        \\      query = { type = "string", description = "the search query" },
        \\    },
        \\    required = { "query" },
        \\  },
        \\  execute = function(params, ctx) return { content = {} } end,
        \\})
    , "test_register");

    try testing.expectEqual(@as(usize, 1), runner.tool_registry.count());

    const tool = runner.tool_registry.get("finder").?;
    try testing.expectEqualStrings("finder", tool.name);
    try testing.expectEqualStrings("Finder", tool.label);
    try testing.expectEqualStrings("search the codebase", tool.description);
    try testing.expectEqualStrings("use finder for multi-step search", tool.prompt_snippet.?);
    try testing.expectEqual(@as(usize, 2), tool.prompt_guidelines.len);
    try testing.expectEqualStrings("prefer over chained grep", tool.prompt_guidelines[0]);

    // The schema must be deep-copied: even after we explicitly
    // garbage-collect Lua, the registry's std.json.Value is intact.
    _ = c.lua_gc(state.L, c.LUA_GCCOLLECT, @as(c_int, 0));

    try testing.expect(tool.parameters == .object);
    const props = tool.parameters.object.get("properties").?.object;
    const query_schema = props.get("query").?.object;
    try testing.expectEqualStrings("string", query_schema.get("type").?.string);
    try testing.expectEqualStrings("the search query", query_schema.get("description").?.string);

    // The required array round-tripped as a JSON array of strings.
    const required = tool.parameters.object.get("required").?.array;
    try testing.expectEqual(@as(usize, 1), required.items.len);
    try testing.expectEqualStrings("query", required.items[0].string);

    try testing.expect(tool.impl == .lua);
    try testing.expect(tool.impl.lua != c.LUA_REFNIL);
}

test "zi.register_tool first-registered-wins drops later duplicates" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();

    installZiTable(&state, &runner);

    try state.doString(
        \\local first = zi.register_tool({
        \\  name = "task",
        \\  description = "first registration",
        \\  parameters = { type = "object" },
        \\  execute = function() end,
        \\})
        \\local second = zi.register_tool({
        \\  name = "task",
        \\  description = "second registration (should be dropped)",
        \\  parameters = { type = "object" },
        \\  execute = function() end,
        \\})
        \\assert(first == true, "first registration should succeed")
        \\assert(second == false, "second registration should be dropped")
    , "test_first_wins");

    try testing.expectEqual(@as(usize, 1), runner.tool_registry.count());
    try testing.expectEqualStrings(
        "first registration",
        runner.tool_registry.get("task").?.description,
    );
}

test "zi.on subscribes a Lua handler to the right event chain" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();

    installZiTable(&state, &runner);

    try state.doString(
        \\zi.on("message_end", function(event, ctx) end)
        \\zi.on("tool_call", function(event, ctx) end)
        \\zi.on("tool_call", function(event, ctx) end)
    , "test_subscribe");

    // message_end has 1 handler, tool_call has 2, total 3.
    try testing.expectEqual(@as(usize, 3), runner.event_registry.count());

    const tc = runner.event_registry.handlers(.tool_call);
    try testing.expectEqual(@as(usize, 2), tc.len);
    try testing.expect(tc[0].lua_ref != tc[1].lua_ref);

    const me = runner.event_registry.handlers(.message_end);
    try testing.expectEqual(@as(usize, 1), me.len);
    try testing.expect(me[0].lua_ref != c.LUA_REFNIL);
}

test "zi.on rejects unknown event names with a Lua-catchable error" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();

    installZiTable(&state, &runner);

    try state.doString(
        \\local ok, err = pcall(function()
        \\  zi.on("not_a_real_event", function() end)
        \\end)
        \\assert(not ok, "expected error")
        \\assert(string.find(err, "not_a_real_event") ~= nil,
        \\  "error should mention the bad name, got: " .. tostring(err))
    , "test_unknown_event");

    try testing.expectEqual(@as(usize, 0), runner.event_registry.count());
}

test "zi.on rejects non-function handler" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();

    installZiTable(&state, &runner);

    try state.doString(
        \\local ok, err = pcall(function()
        \\  zi.on("message_end", "not a function")
        \\end)
        \\assert(not ok)
        \\assert(string.find(err, "function") ~= nil)
    , "test_bad_handler");

    try testing.expectEqual(@as(usize, 0), runner.event_registry.count());
}

test "zi.register_tool surfaces validation errors as Lua errors" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();

    installZiTable(&state, &runner);

    // Missing 'execute' field — should raise a Lua error which we
    // catch via pcall and confirm the message contains "execute".
    try state.doString(
        \\local ok, err = pcall(function()
        \\  zi.register_tool({
        \\    name = "broken",
        \\    description = "no execute",
        \\    parameters = { type = "object" },
        \\  })
        \\end)
        \\assert(not ok, "expected error")
        \\assert(string.find(err, "execute") ~= nil, "error should mention 'execute', got: " .. tostring(err))
    , "test_missing_execute");

    try testing.expectEqual(@as(usize, 0), runner.tool_registry.count());
}
