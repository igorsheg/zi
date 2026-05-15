const std = @import("std");
const lua_runtime = @import("lua_runtime.zig");
const lua_helpers = @import("lua_helpers.zig");
const runner_mod = @import("runner.zig");
const tool_registry = @import("registries/tool_registry.zig");
const tool_def = @import("../tools/definition.zig");

const c = lua_runtime.c;
const Lua = lua_helpers.Lua;
const log = std.log.scoped(.zi_api);

pub fn ziTool(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const api_name = "zi.tool";

    const L = L_opt.?;
    const lua = Lua.init(L);
    const runner = runnerFromUpvalue(L);

    if (lua.typeOf(1) != .table) {
        return luaErrorFmt(L, "{s}: expected spec table", .{api_name});
    }

    var built = buildExtensionTool(L, runner) catch |err| {
        return luaApiError(L, api_name, switch (err) {
            error.MissingName => "missing required field 'name'",
            error.MissingDescription => "missing required field 'description'",
            error.MissingParameters => "missing required field 'parameters'",
            error.MissingExecute => "missing required field 'execute'",
            error.InvalidExecute => "field 'execute' must be a function",
            error.InvalidName => "field 'name' must be a string",
            error.InvalidDescription => "field 'description' must be a string",
            error.InvalidLabel => "field 'label' must be a string",
            error.InvalidDisplay => "field 'display.call' must be a string",
            error.InvalidPromptSnippet => "field 'prompt_snippet' must be a string",
            error.InvalidPromptGuidelines => "field 'prompt_guidelines' must be an array of strings",
            error.InvalidParameters => "field 'parameters' must be a table",
            error.OutOfMemory => "out of memory",
            error.UnsupportedLuaType => "parameter schema contains an unsupported value",
            error.InvalidUtf8 => "parameter schema contains invalid UTF-8",
        });
    };

    const accepted = runner.tool_registry.register(built) catch {
        freeBuiltTool(runner.allocator, &built);
        return luaErrorFmt(L, "{s}: registry insert failed", .{api_name});
    };

    if (!accepted) {
        log.warn("tool '{s}' already registered (source: {s}); ignoring later registration from {s}", .{
            built.name,
            (runner.tool_registry.get(built.name) orelse unreachable).source.id,
            built.source.id,
        });
        if (built.impl == .lua) c.luaL_unref(L, c.LUA_REGISTRYINDEX, built.impl.lua);
        freeBuiltTool(runner.allocator, &built);
        lua.pushBool(false);
        return 1;
    }

    runner.notifyToolProjectionChanged();

    lua.pushBool(true);
    return 1;
}

const BuildError = error{
    MissingName,
    MissingDescription,
    MissingParameters,
    MissingExecute,
    InvalidName,
    InvalidLabel,
    InvalidDisplay,
    InvalidDescription,
    InvalidPromptSnippet,
    InvalidPromptGuidelines,
    InvalidParameters,
    InvalidExecute,
    OutOfMemory,
    UnsupportedLuaType,
    InvalidUtf8,
};

fn buildExtensionTool(
    L: *c.lua_State,
    runner: *runner_mod.ExtensionRunner,
) BuildError!tool_registry.ToolDefinition {
    const a = runner.allocator;

    const name = try requireString(L, 1, "name", a, error.MissingName, error.InvalidName);
    errdefer a.free(name);

    const description = try requireString(L, 1, "description", a, error.MissingDescription, error.InvalidDescription);
    errdefer a.free(description);

    const label = blk: {
        const opt = try optionalString(L, 1, "label", a, error.InvalidLabel);
        if (opt) |s| break :blk s;
        break :blk try a.dupe(u8, name);
    };
    errdefer a.free(label);

    const display_call = try optionalDisplayCall(L, 1, a, error.InvalidDisplay);
    errdefer if (display_call) |field| a.free(field);

    const prompt_snippet = try optionalString(L, 1, "prompt_snippet", a, error.InvalidPromptSnippet);
    errdefer if (prompt_snippet) |s| a.free(s);

    const prompt_guidelines = try optionalStringArray(L, 1, "prompt_guidelines", a, error.InvalidPromptGuidelines);
    errdefer freeStringArray(a, prompt_guidelines);

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
        .display_call = display_call,
        .parameters = parameters,
        .prompt_snippet = prompt_snippet,
        .prompt_guidelines = prompt_guidelines,
        .impl = .{ .lua = execute_ref },
        .source = currentRegistrationSource(runner),
        .owned = true,
    };
}

fn optionalDisplayCall(
    L: *c.lua_State,
    table_idx: c_int,
    allocator: std.mem.Allocator,
    invalid_err: BuildError,
) BuildError!?[]const u8 {
    _ = c.lua_getfield(L, table_idx, "display");
    defer c.lua_pop(L, 1);
    const display_type = c.lua_type(L, -1);
    if (display_type == c.LUA_TNIL) return null;
    if (display_type != c.LUA_TTABLE) return invalid_err;
    _ = c.lua_getfield(L, -1, "call");
    defer c.lua_pop(L, 1);
    const call_type = c.lua_type(L, -1);
    if (call_type == c.LUA_TNIL) return null;
    if (call_type != c.LUA_TSTRING) return invalid_err;
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, -1, &len) orelse return invalid_err;
    const slice = ptr[0..len];
    if (!std.unicode.utf8ValidateSlice(slice)) return error.InvalidUtf8;
    return try allocator.dupe(u8, slice);
}

fn freeBuiltTool(allocator: std.mem.Allocator, tool: *tool_registry.ToolDefinition) void {
    tool_def.freeOwned(allocator, tool);
}

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
    return lua_helpers.raiseError(Lua.init(L), msg);
}

fn luaErrorFmt(L: *c.lua_State, comptime fmt: []const u8, args: anytype) c_int {
    return lua_helpers.raiseErrorFmt(Lua.init(L), fmt, args);
}

fn luaApiError(L: *c.lua_State, api_name: []const u8, detail: []const u8) c_int {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buf, "{s}: {s}", .{ api_name, detail }) catch "lua error";
    return lua_helpers.raiseError(Lua.init(L), msg);
}

fn runnerFromUpvalue(L: *c.lua_State) *runner_mod.ExtensionRunner {
    return lua_helpers.ptrFromUpvalue(runner_mod.ExtensionRunner, Lua.init(L), 1);
}
