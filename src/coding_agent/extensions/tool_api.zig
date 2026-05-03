const std = @import("std");
const lua_runtime = @import("lua_runtime.zig");
const runner_mod = @import("runner.zig");
const tool_registry = @import("registries/tool_registry.zig");
const tool_def = @import("../tools/definition.zig");

const c = lua_runtime.c;
const log = std.log.scoped(.zi_api);

pub fn ziRegisterTool(L_opt: ?*c.lua_State) callconv(.c) c_int {
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
            error.InvalidRenderCall => "register_tool: 'render_call' must be a function",
            error.InvalidRenderResult => "register_tool: 'render_result' must be a function",
            error.InvalidExpandedChanged => "register_tool: 'on_expanded_changed' must be a function",
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
        if (built.render_call_ref) |r| c.luaL_unref(L, c.LUA_REGISTRYINDEX, r);
        if (built.render_result_ref) |r| c.luaL_unref(L, c.LUA_REGISTRYINDEX, r);
        if (built.on_expanded_changed_ref) |r| c.luaL_unref(L, c.LUA_REGISTRYINDEX, r);
        freeBuiltTool(runner.allocator, &built);
        c.lua_pushboolean(L, 0);
        return 1;
    }

    runner.notifyToolProjectionChanged();

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
    InvalidRenderCall,
    InvalidRenderResult,
    InvalidExpandedChanged,
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
    var parameters_budget = lua_runtime.JsonConvertBudget{ .limits = lua_runtime.default_json_convert_limits };
    const parameters = lua_runtime.luaValueToJsonLimited(L, -1, a, &parameters_budget) catch |err| switch (err) {
        error.LimitExceeded => return error.InvalidParameters,
        else => |e| return e,
    };
    errdefer lua_runtime.freeJsonValue(a, parameters);

    // Optional presentation-slot functions — validated type-only here.
    // We capture refs AFTER `execute` to keep ref-last discipline;
    // taking them before execute would leak on `MissingExecute`.
    var has_render_call = false;
    _ = c.lua_getfield(L, 1, "render_call");
    if (c.lua_type(L, -1) == c.LUA_TFUNCTION) {
        has_render_call = true;
    } else if (c.lua_type(L, -1) != c.LUA_TNIL) {
        c.lua_pop(L, 1);
        return error.InvalidRenderCall;
    }

    var has_render_result = false;
    _ = c.lua_getfield(L, 1, "render_result");
    if (c.lua_type(L, -1) == c.LUA_TFUNCTION) {
        has_render_result = true;
    } else if (c.lua_type(L, -1) != c.LUA_TNIL) {
        c.lua_pop(L, 2);
        return error.InvalidRenderResult;
    }
    var has_on_expanded_changed = false;
    _ = c.lua_getfield(L, 1, "on_expanded_changed");
    if (c.lua_type(L, -1) == c.LUA_TFUNCTION) {
        has_on_expanded_changed = true;
    } else if (c.lua_type(L, -1) != c.LUA_TNIL) {
        c.lua_pop(L, 3);
        return error.InvalidExpandedChanged;
    }
    // Leave on stack for now; we'll ref them after execute validates.

    // execute: required, must be a function. luaL_ref pops the
    // function from the stack and returns a registry slot. We do
    // this LAST so the errdefers above don't accidentally leak the
    // ref on a later failure.
    _ = c.lua_getfield(L, 1, "execute");
    if (c.lua_type(L, -1) == c.LUA_TNIL) {
        c.lua_pop(L, 4); // execute (nil) + on_expanded_changed + render_result + render_call
        return error.MissingExecute;
    }
    if (c.lua_type(L, -1) != c.LUA_TFUNCTION) {
        c.lua_pop(L, 4);
        return error.InvalidExecute;
    }
    const execute_ref = c.luaL_ref(L, c.LUA_REGISTRYINDEX);

    // Now ref optional callbacks (still on stack if present).
    const on_expanded_changed_ref: ?c_int = if (has_on_expanded_changed)
        c.luaL_ref(L, c.LUA_REGISTRYINDEX)
    else blk: {
        c.lua_pop(L, 1); // the nil value we left on stack
        break :blk null;
    };
    const render_result_ref: ?c_int = if (has_render_result)
        c.luaL_ref(L, c.LUA_REGISTRYINDEX)
    else blk: {
        c.lua_pop(L, 1); // the nil value we left on stack
        break :blk null;
    };
    const render_call_ref: ?c_int = if (has_render_call)
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
        .render_call_ref = render_call_ref,
        .render_result_ref = render_result_ref,
        .on_expanded_changed_ref = on_expanded_changed_ref,
        .owned = true,
    };
}

/// Free every owned field of a partially-built tool. Used by the
/// rejection path (`!accepted`) and by registry-insert OOM. Mirrors
/// `ToolRegistry.freeEntry` minus the registry-managed bookkeeping.
fn freeBuiltTool(allocator: std.mem.Allocator, tool: *tool_registry.ToolDefinition) void {
    tool_def.freeOwned(allocator, tool);
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

fn currentRegistrationSource(runner: *const runner_mod.ExtensionRunner) tool_registry.RegistrationSource {
    const source = runner.currentLoadSource() orelse return .{ .kind = "lua", .id = "lua" };
    return .{ .kind = source.kind, .id = source.path, .provenance = source.provenance };
}

fn luaError(L: *c.lua_State, msg: [:0]const u8) c_int {
    _ = c.lua_pushstring(L, msg.ptr);
    _ = c.lua_error(L);
    return 0;
}

fn runnerFromUpvalue(L: *c.lua_State) *runner_mod.ExtensionRunner {
    const raw = c.lua_touserdata(L, c.lua_upvalueindex(1)) orelse unreachable;
    return @ptrCast(@alignCast(raw));
}
