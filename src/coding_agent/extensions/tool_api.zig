const std = @import("std");
const lua_runtime = @import("lua_runtime.zig");
const lua_helpers = @import("lua_helpers.zig");
const runner_mod = @import("runner.zig");
const api_export = @import("api_export.zig");
const lua_schema = @import("lua_schema.zig");
const tool_registry = @import("registries/tool_registry.zig");
const tool_def = @import("../tools/definition.zig");

const c = lua_runtime.c;
const Lua = lua_helpers.Lua;
const log = std.log.scoped(.zi_api);

pub const export_tool = api_export.Export{
    .name = "tool",
    .kind = .function,
    .install = installToolExport,
};

fn installToolExport(state: *lua_runtime.LuaState, runner: *runner_mod.ExtensionRunner) void {
    state.pushCClosureWithUserdata(ziTool, runner);
    c.lua_setfield(state.L, -2, export_tool.name.ptr);
}

pub fn ziTool(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const api_name = "zi.define.tool";

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
            error.MissingParameters => "missing required field 'input'",
            error.MissingExecute => "missing required field 'run'",
            error.InvalidExecute => "field 'run' must be a function",
            error.InvalidName => "field 'name' must be a string",
            error.InvalidDescription => "field 'description' must be a string",
            error.InvalidLabel => "field 'label' must be a string",
            error.InvalidDisplay => "field 'display.call' must be a string",
            error.InvalidPromptSnippet => "field 'prompt_snippet' must be a string",
            error.InvalidPromptGuidelines => "field 'prompt_guidelines' must be an array of strings",
            error.InvalidParameters => "field 'parameters' must be a table",
            error.UnknownField => "spec contains an unknown field",
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
    UnknownField,
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
    const spec = lua_schema.Table.init(Lua.init(L), a, 1);

    spec.rejectUnknownFields(&.{
        "name",
        "label",
        "description",
        "display",
        "input",
        "run",
        "prompt",
    }) catch |err| return mapSchemaError(err, error.UnknownField, error.UnknownField);

    const name = spec.requiredString("name") catch |err| return mapSchemaError(err, error.MissingName, error.InvalidName);
    errdefer a.free(name);

    const description = spec.requiredString("description") catch |err| return mapSchemaError(err, error.MissingDescription, error.InvalidDescription);
    errdefer a.free(description);

    const label = blk: {
        const opt = spec.optionalString("label") catch |err| return mapSchemaError(err, error.InvalidLabel, error.InvalidLabel);
        if (opt) |s| break :blk s;
        break :blk a.dupe(u8, name) catch return error.OutOfMemory;
    };
    errdefer a.free(label);

    const display_call = try optionalDisplayCall(L, 1, a, error.InvalidDisplay);
    errdefer if (display_call) |field| a.free(field);

    const prompt_snippet = try optionalPromptSnippet(L, 1, a, error.InvalidPromptSnippet);
    errdefer if (prompt_snippet) |s| a.free(s);

    const prompt_guidelines = try optionalPromptGuidelines(L, 1, a, error.InvalidPromptGuidelines);
    errdefer freeStringArray(a, prompt_guidelines);

    const parameters = spec.requiredJsonTable("input", lua_runtime.default_json_convert_limits) catch |err| switch (err) {
        error.MissingField => return error.MissingParameters,
        error.WrongType, error.LimitExceeded => return error.InvalidParameters,
        error.UnsupportedLuaType => return error.UnsupportedLuaType,
        error.InvalidUtf8 => return error.InvalidUtf8,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidParameters,
    };
    errdefer lua_runtime.freeJsonValue(a, parameters);

    var execute_ref = spec.requiredFunctionRef("run") catch |err| switch (err) {
        error.MissingField => return error.MissingExecute,
        error.WrongType => return error.InvalidExecute,
        error.InvalidRegistryRef, error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidExecute,
    };
    errdefer execute_ref.release(Lua.init(L));

    const result = tool_registry.ToolDefinition{
        .name = name,
        .label = label,
        .description = description,
        .display_call = display_call,
        .parameters = parameters,
        .prompt_snippet = prompt_snippet,
        .prompt_guidelines = prompt_guidelines,
        .impl = .{ .lua = execute_ref.value },
        .source = currentRegistrationSource(runner),
        .owned = true,
    };
    execute_ref.value = c.LUA_NOREF;
    return result;
}

fn mapSchemaError(err: lua_schema.Error, missing_err: BuildError, invalid_err: BuildError) BuildError {
    return switch (err) {
        error.MissingField => missing_err,
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidUtf8 => error.InvalidUtf8,
        error.UnsupportedLuaType => error.UnsupportedLuaType,
        else => invalid_err,
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

fn optionalPromptSnippet(
    L: *c.lua_State,
    table_idx: c_int,
    allocator: std.mem.Allocator,
    invalid_err: BuildError,
) BuildError!?[]const u8 {
    _ = c.lua_getfield(L, table_idx, "prompt");
    defer c.lua_pop(L, 1);
    const prompt_type = c.lua_type(L, -1);
    if (prompt_type == c.LUA_TNIL) return null;
    if (prompt_type != c.LUA_TTABLE) return invalid_err;

    _ = c.lua_getfield(L, -1, "snippet");
    defer c.lua_pop(L, 1);
    const snippet_type = c.lua_type(L, -1);
    if (snippet_type == c.LUA_TNIL) return null;
    if (snippet_type != c.LUA_TSTRING) return invalid_err;
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, -1, &len) orelse return invalid_err;
    const slice = ptr[0..len];
    if (!std.unicode.utf8ValidateSlice(slice)) return error.InvalidUtf8;
    return try allocator.dupe(u8, slice);
}

fn optionalPromptGuidelines(
    L: *c.lua_State,
    table_idx: c_int,
    allocator: std.mem.Allocator,
    invalid_err: BuildError,
) BuildError![]const []const u8 {
    _ = c.lua_getfield(L, table_idx, "prompt");
    defer c.lua_pop(L, 1);
    const prompt_type = c.lua_type(L, -1);
    if (prompt_type == c.LUA_TNIL) return &.{};
    if (prompt_type != c.LUA_TTABLE) return invalid_err;

    _ = c.lua_getfield(L, -1, "guidelines");
    defer c.lua_pop(L, 1);
    const guidelines_type = c.lua_type(L, -1);
    if (guidelines_type == c.LUA_TNIL) return &.{};
    if (guidelines_type != c.LUA_TTABLE) return invalid_err;

    const len = c.lua_rawlen(L, -1);
    if (len == 0) return &.{};
    const out = try allocator.alloc([]const u8, len);
    errdefer allocator.free(out);
    var written: usize = 0;
    errdefer {
        for (out[0..written]) |s| allocator.free(s);
    }
    var i: usize = 0;
    while (i < len) : (i += 1) {
        _ = c.lua_rawgeti(L, -1, @intCast(i + 1));
        defer c.lua_pop(L, 1);
        if (c.lua_type(L, -1) != c.LUA_TSTRING) return invalid_err;
        var item_len: usize = 0;
        const ptr = c.lua_tolstring(L, -1, &item_len) orelse return invalid_err;
        const slice = ptr[0..item_len];
        if (!std.unicode.utf8ValidateSlice(slice)) return error.InvalidUtf8;
        out[written] = try allocator.dupe(u8, slice);
        written += 1;
    }
    return out;
}

fn freeBuiltTool(allocator: std.mem.Allocator, tool: *tool_registry.ToolDefinition) void {
    tool_def.freeOwned(allocator, tool);
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
