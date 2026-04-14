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
//! Ownership rules (see `docs/extensions.md`):
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
//!      first invocation. The ref is stored in `ToolDefinition.impl.lua`
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
const tool_def = @import("../tools/definition.zig");
const agent_protocol = @import("../agent/protocol.zig");
const spawn_mod = @import("../spawn/spawn.zig");
const spawn_types = @import("../spawn/types.zig");

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

    // zi.spawn
    state.pushCClosureWithUserdata(ziSpawn, runner);
    c.lua_setfield(L, -2, "spawn");

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

    // Build the ToolDefinition incrementally so each errdefer in the
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
            error.InvalidRenderResult => "register_tool: 'render_result' must be a function",
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
        // Release the captured Lua function refs since we won't use them.
        if (built.impl == .lua) c.luaL_unref(L, c.LUA_REGISTRYINDEX, built.impl.lua);
        if (built.render_result_ref) |r| c.luaL_unref(L, c.LUA_REGISTRYINDEX, r);
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
    InvalidRenderResult,
    OutOfMemory,
    UnsupportedLuaType,
    InvalidUtf8,
};

/// Walk the Lua table at stack index 1 and produce a
/// `ToolDefinition` whose owned fields all live in the runner's
/// allocator. On any error every allocation made so far is freed.
///
/// Stack discipline: leaves the stack at the same height as on
/// entry. Each `lua_getfield` pushes one value; we pop it after
/// extraction. The `execute` function gets `luaL_ref`d, which pops
/// it from the stack and returns a registry slot.
fn buildExtensionTool(
    L: *c.lua_State,
    runner: *runner_mod.ExtensionRunner,
) BuildError!tool_registry.ToolDefinition {
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

    // Optional `render_result` function — validated type-only here.
    // We capture its ref AFTER `execute` to keep the ref-last
    // discipline; taking it before execute would leak on
    // `MissingExecute`.
    var has_render_result = false;
    _ = c.lua_getfield(L, 1, "render_result");
    if (c.lua_type(L, -1) == c.LUA_TFUNCTION) {
        has_render_result = true;
    } else if (c.lua_type(L, -1) != c.LUA_TNIL) {
        c.lua_pop(L, 1);
        return error.InvalidRenderResult;
    }
    // Leave on stack for now; we'll ref it after execute validates.

    // execute: required, must be a function. luaL_ref pops the
    // function from the stack and returns a registry slot. We do
    // this LAST so the errdefers above don't accidentally leak the
    // ref on a later failure.
    _ = c.lua_getfield(L, 1, "execute");
    if (c.lua_type(L, -1) == c.LUA_TNIL) {
        c.lua_pop(L, 2); // execute (nil) + render_result
        return error.MissingExecute;
    }
    if (c.lua_type(L, -1) != c.LUA_TFUNCTION) {
        c.lua_pop(L, 2);
        return error.InvalidExecute;
    }
    const execute_ref = c.luaL_ref(L, c.LUA_REGISTRYINDEX);

    // Now ref render_result (still at top of stack if present).
    const render_result_ref: ?c_int = if (has_render_result)
        c.luaL_ref(L, c.LUA_REGISTRYINDEX)
    else blk: {
        c.lua_pop(L, 1); // the nil value we left on stack
        break :blk null;
    };

    return .{
        .name = name,
        .label = label,
        .description = description,
        .parameters = parameters,
        .prompt_snippet = prompt_snippet,
        .prompt_guidelines = prompt_guidelines,
        .impl = .{ .lua = execute_ref },
        .source = currentRegistrationSource(runner),
        .render_result_ref = render_result_ref,
    };
}

/// Free every owned field of a partially-built tool. Used by the
/// rejection path (`!accepted`) and by registry-insert OOM. Mirrors
/// `ToolRegistry.freeEntry` minus the registry-managed bookkeeping.
fn freeBuiltTool(allocator: std.mem.Allocator, tool: *tool_registry.ToolDefinition) void {
    tool_def.freeOwned(allocator, tool);
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
        .source_id = currentEventSourceId(runner),
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
/// Event names are documented in `docs/extensions.md`.
/// We support the current implemented subset; new events get added here as
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
// zi.spawn
// ─────────────────────────────────────────────────────────────────────────
//
// `zi.spawn(opts)` runs a child `zi` process in `--mode json -p` and
// blocks until it exits. Per-event observer callbacks fire
// synchronously inside the parent's stdout read loop. The result is
// a Lua table; see `pushSpawnResult` for the shape.
//
// Why a host function instead of `io.popen` + parsing in Lua: io.popen
// merges stderr, has no clean abort path, and the JSONL framing is
// awkward to do correctly in Lua. The wrapper is also where we forward
// the parent agent's abort signal into the child.
//
// Lua opts shape:
//
//   {
//     task          = string,           -- required
//     model         = string|nil,
//     tools         = string|nil,       -- comma-separated, single arg
//     system_append = string|nil,
//     cwd           = string|nil,       -- defaults to "."
//     on            = table|nil,        -- { event_name = function(event) ... }
//   }
//
// Lifetime / safety notes:
//
//   1. All temp strings (task, model, tools, system_append, cwd) live
//      in a function-scoped arena that resets on return. NOT the
//      runner's hook arena (which never resets within a generation).
//
//   2. The `on` table is captured as a SINGLE Lua registry ref over
//      the whole table — not one ref per callback. This collapses
//      cleanup to one `luaL_unref` call site and means a partial
//      validation failure can't leak refs. Validation walks the
//      table BEFORE the ref is taken.
//
//   3. Abort: forwarded via `runner.current_signal`, set by
//      `lua_tool.execute` when this spawn happens inside a Lua tool
//      handler. If `current_signal` is null (e.g. spawn from an
//      event handler), the child runs uninterruptible. ziSpawn
//      runs a watchdog thread that shuts down the child's stdout
//      and SIGKILLs it within ~100ms of the signal firing, so even
//      a silent child responds promptly.
//
//   4. The trampoline pcalls observer callbacks on the same `lua_State`
//      the C function was invoked on (typically a coroutine `co.L`).
//      Observer callbacks MUST NOT yield: `lua_pcallk` does not
//      survive a yield across the C boundary. If a future variant
//      needs yieldable callbacks, it has to spawn a fresh Coroutine
//      and use `resumeWith`.

fn ziSpawn(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = runnerFromUpvalue(L);

    var err_buf: [256]u8 = undefined;
    const req = buildSpawnRequest(L, runner, &err_buf) catch {
        const msg = err_buf[0..std.mem.indexOfScalar(u8, &err_buf, 0).?];
        _ = c.lua_pushlstring(L, msg.ptr, msg.len);
        _ = c.lua_error(L);
        return 0;
    } orelse return 0;

    runner.current_spawn_request = req;
    return c.lua_yieldk(L, 0, req.continuation_ctx, ziSpawnContinue);
}

fn ziSpawnContinue(L_opt: ?*c.lua_State, status: c_int, ctx: c.lua_KContext) callconv(.c) c_int {
    _ = status;
    _ = ctx;
    const L = L_opt.?;
    const runner = runnerFromUpvalue(L);
    const outcome = runner.current_spawn_result orelse return luaError(L, "zi.spawn: missing resume result");
    defer runner.current_spawn_result = null;

    pushToolResultAsSpawnResult(L, outcome.result);
    return 1;
}

const ZiSpawnError = error{NeedLuaError};

fn buildSpawnRequest(
    L: *c.lua_State,
    runner: *runner_mod.ExtensionRunner,
    err_buf: *[256]u8,
) ZiSpawnError!?runner_mod.SpawnRequest {
    if (c.lua_type(L, 1) != c.LUA_TTABLE) {
        return writeErr(err_buf, "zi.spawn: expected opts table as first argument");
    }

    var arena = std.heap.ArenaAllocator.init(runner.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const task = readSpawnString(L, 1, "task", aa) catch |err| switch (err) {
        error.Missing => return writeErr(err_buf, "zi.spawn: 'task' is required (string)"),
        error.WrongType => return writeErr(err_buf, "zi.spawn: 'task' must be a string"),
        error.OutOfMemory => return writeErr(err_buf, "zi.spawn: out of memory"),
    } orelse return writeErr(err_buf, "zi.spawn: 'task' is required (string)");

    const model = readOptionalSpawnString(L, 1, "model", aa) catch
        return writeErr(err_buf, "zi.spawn: 'model' must be a string");
    const tools = readOptionalSpawnString(L, 1, "tools", aa) catch
        return writeErr(err_buf, "zi.spawn: 'tools' must be a string");
    const system_append = readOptionalSpawnString(L, 1, "system_append", aa) catch
        return writeErr(err_buf, "zi.spawn: 'system_append' must be a string");
    const cwd_opt = readOptionalSpawnString(L, 1, "cwd", aa) catch
        return writeErr(err_buf, "zi.spawn: 'cwd' must be a string");

    _ = c.lua_getfield(L, 1, "on");
    const on_type = c.lua_type(L, -1);
    var callbacks_ref: c_int = c.LUA_NOREF;
    if (on_type == c.LUA_TNIL) {
        c.lua_pop(L, 1);
    } else if (on_type == c.LUA_TTABLE) {
        c.lua_pushnil(L);
        while (c.lua_next(L, -2) != 0) {
            if (c.lua_type(L, -2) != c.LUA_TSTRING) {
                c.lua_pop(L, 3);
                return writeErr(err_buf, "zi.spawn: 'on' keys must be event-name strings");
            }
            if (c.lua_type(L, -1) != c.LUA_TFUNCTION) {
                c.lua_pop(L, 3);
                return writeErr(err_buf, "zi.spawn: 'on' values must be functions");
            }
            c.lua_pop(L, 1);
        }
        callbacks_ref = c.luaL_ref(L, c.LUA_REGISTRYINDEX);
    } else {
        c.lua_pop(L, 1);
        return writeErr(err_buf, "zi.spawn: 'on' must be a table");
    }

    return .{
        .task = runner.allocator.dupe(u8, task) catch return writeErr(err_buf, "zi.spawn: out of memory"),
        .model = if (model) |v| runner.allocator.dupe(u8, v) catch return writeErr(err_buf, "zi.spawn: out of memory") else null,
        .tools = if (tools) |v| runner.allocator.dupe(u8, v) catch return writeErr(err_buf, "zi.spawn: out of memory") else null,
        .append_system_prompt = if (system_append) |v| runner.allocator.dupe(u8, v) catch return writeErr(err_buf, "zi.spawn: out of memory") else null,
        .cwd = runner.allocator.dupe(u8, cwd_opt orelse ".") catch return writeErr(err_buf, "zi.spawn: out of memory"),
        .callbacks_ref = callbacks_ref,
        .source_L = L,
        .continuation_ctx = 0,
    };
}

// Event handlers and `on={...}` callbacks still run non-yieldably in this
// phase. They are invoked with `lua_pcallk` on the tool coroutine itself; a
// callback that tries to yield still trips Lua's cross-C-call boundary error.
fn writeErr(err_buf: *[256]u8, msg: []const u8) ZiSpawnError {
    const n = @min(msg.len, err_buf.len - 1);
    @memcpy(err_buf[0..n], msg[0..n]);
    err_buf[n] = 0;
    return error.NeedLuaError;
}

// -- spawn helpers --

const SpawnReadError = error{ Missing, WrongType, OutOfMemory };

fn readSpawnString(
    L: *c.lua_State,
    table_idx: c_int,
    field: [:0]const u8,
    allocator: std.mem.Allocator,
) SpawnReadError!?[]const u8 {
    _ = c.lua_getfield(L, table_idx, field.ptr);
    defer c.lua_pop(L, 1);
    return switch (c.lua_type(L, -1)) {
        c.LUA_TNIL => error.Missing,
        c.LUA_TSTRING => blk: {
            var len: usize = 0;
            const ptr = c.lua_tolstring(L, -1, &len) orelse return error.WrongType;
            break :blk allocator.dupe(u8, ptr[0..len]) catch error.OutOfMemory;
        },
        else => error.WrongType,
    };
}

fn readOptionalSpawnString(
    L: *c.lua_State,
    table_idx: c_int,
    field: [:0]const u8,
    allocator: std.mem.Allocator,
) error{ WrongType, OutOfMemory }!?[]const u8 {
    _ = c.lua_getfield(L, table_idx, field.ptr);
    defer c.lua_pop(L, 1);
    return switch (c.lua_type(L, -1)) {
        c.LUA_TNIL => null,
        c.LUA_TSTRING => blk: {
            var len: usize = 0;
            const ptr = c.lua_tolstring(L, -1, &len) orelse return error.WrongType;
            break :blk allocator.dupe(u8, ptr[0..len]) catch error.OutOfMemory;
        },
        else => error.WrongType,
    };
}

pub const TrampolineCtx = struct {
    L: *c.lua_State,
    callbacks_ref: c_int,
};

/// Called by `ziSpawn` for each parsed JSONL event. Looks up the
/// callback from the captured `on` table by event name and pcalls
/// it with the event payload as a single Lua-table arg.
///
/// Errors are logged and swallowed — observer callbacks must not
/// break the read loop. The synchronously-converted JSON value
/// becomes an independent Lua table via `pushJsonValue`, so the
/// caller's `parsed.deinit()` after this returns is safe.
pub fn eventTrampoline(
    kind: []const u8,
    event: std.json.Value,
    ctx: ?*anyopaque,
) void {
    const tctx: *TrampolineCtx = @ptrCast(@alignCast(ctx.?));
    const L = tctx.L;

    // Push the captured callbacks table.
    _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, tctx.callbacks_ref);
    if (c.lua_type(L, -1) != c.LUA_TTABLE) {
        c.lua_pop(L, 1);
        return;
    }

    // Look up t[kind] without requiring a null-terminated key.
    _ = c.lua_pushlstring(L, kind.ptr, kind.len);
    _ = c.lua_gettable(L, -2); // pops key, pushes value
    if (c.lua_type(L, -1) != c.LUA_TFUNCTION) {
        c.lua_pop(L, 2); // value, table
        return;
    }

    // Push the event payload as a Lua table.
    lua_runtime.pushJsonValue(L, event) catch {
        c.lua_pop(L, 2); // function, table
        return;
    };

    // pcall(1 arg, 0 results). Observer contract: must not yield.
    const rc = c.lua_pcallk(L, 1, 0, 0, 0, null);
    if (rc != c.LUA_OK) {
        if (c.lua_type(L, -1) == c.LUA_TSTRING) {
            var len: usize = 0;
            if (c.lua_tolstring(L, -1, &len)) |msg| {
                log.warn("zi.spawn 'on.{s}' handler error: {s}", .{ kind, msg[0..len] });
            }
        }
        c.lua_pop(L, 1); // error
    }
    c.lua_pop(L, 1); // callbacks table
}

pub fn pushToolResultAsSpawnResult(L: *c.lua_State, result: agent_protocol.AgentToolResult) void {
    c.lua_createtable(L, 0, 8);

    c.lua_pushinteger(L, if (result.is_error) 1 else 0);
    c.lua_setfield(L, -2, "exit_code");

    if (result.details == .object) {
        const obj = result.details.object;
        if (obj.get("stop_reason")) |v| if (v == .string) {
            _ = c.lua_pushlstring(L, v.string.ptr, v.string.len);
            c.lua_setfield(L, -2, "stop_reason");
        };
        if (obj.get("model")) |v| if (v == .string) {
            _ = c.lua_pushlstring(L, v.string.ptr, v.string.len);
            c.lua_setfield(L, -2, "model");
        };
        if (obj.get("usage")) |usage| {
            lua_runtime.pushJsonValue(L, usage) catch c.lua_createtable(L, 0, 0);
            c.lua_setfield(L, -2, "usage");
        } else {
            c.lua_createtable(L, 0, 0);
            c.lua_setfield(L, -2, "usage");
        }
    } else {
        c.lua_createtable(L, 0, 0);
        c.lua_setfield(L, -2, "usage");
    }

    var text: []const u8 = "";
    for (result.content) |block| {
        switch (block) {
            .text => |tb| {
                if (text.len == 0) text = tb.text;
            },
            else => {},
        }
    }
    _ = c.lua_pushlstring(L, text.ptr, text.len);
    c.lua_setfield(L, -2, "output");
    _ = c.lua_pushlstring(L, text.ptr, text.len);
    c.lua_setfield(L, -2, "final_text");
    _ = c.lua_pushlstring(L, "".ptr, 0);
    c.lua_setfield(L, -2, "stderr");
    c.lua_pushboolean(L, if (result.is_error) 1 else 0);
    c.lua_setfield(L, -2, "cancelled");
}

fn pushSpawnResult(L: *c.lua_State, result: spawn_types.SpawnResult) void {
    c.lua_createtable(L, 0, 8);

    c.lua_pushinteger(L, @intCast(result.exit_code));
    c.lua_setfield(L, -2, "exit_code");

    if (result.stop_reason) |sr| {
        _ = c.lua_pushlstring(L, sr.ptr, sr.len);
        c.lua_setfield(L, -2, "stop_reason");
    }
    if (result.error_message) |em| {
        _ = c.lua_pushlstring(L, em.ptr, em.len);
        c.lua_setfield(L, -2, "error_message");
    }
    if (result.model) |m| {
        _ = c.lua_pushlstring(L, m.ptr, m.len);
        c.lua_setfield(L, -2, "model");
    }

    _ = c.lua_pushlstring(L, result.output.items.ptr, result.output.items.len);
    c.lua_setfield(L, -2, "final_text");

    _ = c.lua_pushlstring(L, result.stderr_output.items.ptr, result.stderr_output.items.len);
    c.lua_setfield(L, -2, "stderr");

    // usage subtable
    c.lua_createtable(L, 0, 7);
    c.lua_pushinteger(L, @intCast(result.usage.input));
    c.lua_setfield(L, -2, "input");
    c.lua_pushinteger(L, @intCast(result.usage.output));
    c.lua_setfield(L, -2, "output");
    c.lua_pushinteger(L, @intCast(result.usage.cache_read));
    c.lua_setfield(L, -2, "cache_read");
    c.lua_pushinteger(L, @intCast(result.usage.cache_write));
    c.lua_setfield(L, -2, "cache_write");
    c.lua_pushinteger(L, @intCast(result.usage.context_tokens));
    c.lua_setfield(L, -2, "total_tokens");
    c.lua_pushnumber(L, result.usage.cost);
    c.lua_setfield(L, -2, "cost");
    c.lua_pushinteger(L, @intCast(result.usage.turns));
    c.lua_setfield(L, -2, "turns");
    c.lua_setfield(L, -2, "usage");
}

fn lstring(L: *c.lua_State, idx: c_int) []const u8 {
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, idx, &len) orelse return &.{};
    return ptr[0..len];
}

// ─────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────

fn runnerFromUpvalue(L: *c.lua_State) *runner_mod.ExtensionRunner {
    const ud = c.lua_touserdata(L, c.lua_upvalueindex(1));
    return @ptrCast(@alignCast(ud.?));
}

fn currentRegistrationSource(runner: *const runner_mod.ExtensionRunner) tool_registry.RegistrationSource {
    const source = runner.currentLoadSource() orelse return .{ .kind = "lua", .id = "lua" };
    return .{ .kind = source.kind, .id = source.path };
}

fn currentEventSourceId(runner: *const runner_mod.ExtensionRunner) []const u8 {
    const source = runner.currentLoadSource() orelse return "lua";
    return source.path;
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

test "zi.spawn validates required 'task' field" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();

    installZiTable(&state, &runner);

    try state.doString(
        \\local ok, err = pcall(function() zi.spawn({}) end)
        \\assert(not ok)
        \\assert(string.find(err, "task") ~= nil, "expected task error, got: " .. tostring(err))
    , "spawn_missing_task");
}

test "zi.spawn rejects non-function values in 'on' table" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();

    installZiTable(&state, &runner);

    try state.doString(
        \\local ok, err = pcall(function()
        \\  zi.spawn({ task = "x", on = { message_end = "not a fn" } })
        \\end)
        \\assert(not ok)
        \\assert(string.find(err, "function") ~= nil, "got: " .. tostring(err))
    , "spawn_bad_on");
}

test "zi.spawn end-to-end: dispatches per-event callbacks via argv_override" {
    // The Lua surface doesn't expose argv_override (test-only zig
    // field). To exercise the trampoline + result table without a
    // real model, we register a CFunction that runs ziSpawn directly
    // with a canned `sh -c` script. The Lua side observes the result
    // table and counts callbacks via a closure-captured upvalue.
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();

    installZiTable(&state, &runner);

    // Helper: run ziSpawn directly so we can pass argv_override.
    // We can't go through zi.spawn (no Lua override) but we CAN
    // verify the trampoline by reusing it. Build cfg in zig and
    // call ziSpawn, then poke the result back into Lua manually.
    // For an end-to-end Lua test we instead push a custom global
    // that wraps spawn_mod.ziSpawn with the override baked in.

    const Helper = struct {
        fn run(L_opt: ?*c.lua_State) callconv(.c) c_int {
            const L = L_opt.?;
            // Pull the message_end callback from the first arg (a function).
            if (c.lua_type(L, 1) != c.LUA_TFUNCTION) return luaError(L, "expected fn");

            // Capture as ref so the trampoline can find it via a one-key table.
            // Build the same shape as ziSpawn would: a callbacks table.
            c.lua_createtable(L, 0, 1);
            c.lua_pushvalue(L, 1);
            c.lua_setfield(L, -2, "message_end");
            const cb_ref = c.luaL_ref(L, c.LUA_REGISTRYINDEX);

            const script =
                \\printf '%s\n' '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"helo"}]}}'
                \\printf '%s\n' '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"helo"}]}}'
            ;
            const override = [_][]const u8{ "sh", "-c", script };

            var ctx_struct = TrampolineCtx{ .L = L, .callbacks_ref = cb_ref };
            const cfg = spawn_types.SpawnConfig{
                .allocator = std.testing.allocator,
                .cwd = ".",
                .task = "unused",
                .argv_override = &override,
                .on_event = &eventTrampoline,
                .on_event_ctx = @ptrCast(&ctx_struct),
            };

            var result = spawn_mod.ziSpawn(cfg);
            defer result.deinit(std.testing.allocator);
            c.luaL_unref(L, c.LUA_REGISTRYINDEX, cb_ref);

            pushSpawnResult(L, result);
            return 1;
        }
    };

    c.lua_pushcfunction(state.L, &Helper.run);
    c.lua_setglobal(state.L, "_test_spawn");

    try state.doString(
        \\local count = 0
        \\local saw_text = nil
        \\local r = _test_spawn(function(event)
        \\  count = count + 1
        \\  if event.message and event.message.content then
        \\    saw_text = event.message.content[1].text
        \\  end
        \\end)
        \\assert(count == 2, "expected 2 callbacks, got " .. tostring(count))
        \\assert(saw_text == "helo", "expected helo, got " .. tostring(saw_text))
        \\assert(r.exit_code == 0)
        \\assert(r.final_text == "helo")
        \\assert(type(r.usage) == "table")
        \\assert(r.usage.turns == 2)
    , "spawn_e2e");
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

test "zi.spawn yields from tool coroutine and resumes with spawn-shaped result" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();
    installZiTable(&state, &runner);
    runner.attachLuaState(&state);

    var co = try lua_runtime.Coroutine.init(&state);
    defer co.deinit();

    try state.doString(
        \\function run_spawn()
        \\  return zi.spawn({ task = "demo", cwd = "." })
        \\end
    , "spawn_yield_test");

    _ = c.lua_getglobal(co.L, "run_spawn");
    const first = try co.resumeWith(0);
    try testing.expectEqual(lua_runtime.Coroutine.Status.yielded, first.status);
    try testing.expect(runner.current_spawn_request != null);

    const blocks = try testing.allocator.alloc(agent_protocol.AgentToolResult.ContentBlock, 1);
    const text = try testing.allocator.dupe(u8, "child output");
    blocks[0] = .{ .text = .{ .text = text } };
    var usage = std.json.ObjectMap.init(testing.allocator);
    try usage.put(try testing.allocator.dupe(u8, "input"), .{ .integer = 1 });
    var details = std.json.ObjectMap.init(testing.allocator);
    try details.put(try testing.allocator.dupe(u8, "usage"), .{ .object = usage });
    runner.current_spawn_result = .{ .result = .{ .content = blocks, .is_error = false, .details = .{ .object = details } } };
    defer {
        const res = runner.current_spawn_result.?.result;
        for (res.content) |b| switch (b) {
            .text => |tb| testing.allocator.free(tb.text),
            else => {},
        };
        testing.allocator.free(res.content);
        lua_runtime.freeJsonValue(testing.allocator, res.details);
    }

    c.lua_pushlightuserdata(co.L, &runner);
    c.lua_pushcclosure(co.L, ziSpawnContinue, 1);
    const second = try co.resumeWith(0);
    try testing.expectEqual(lua_runtime.Coroutine.Status.finished, second.status);
    _ = c.lua_getfield(co.L, -1, "output");
    try testing.expectEqualStrings("child output", lstring(co.L, -1));
    c.lua_pop(co.L, 1);
}
