const std = @import("std");
const lua_runtime = @import("lua_runtime.zig");
const lua_helpers = @import("lua_helpers.zig");
const runner_mod = @import("runner.zig");
const api_export = @import("api_export.zig");

const c = lua_runtime.c;
const Lua = lua_helpers.Lua;

pub const export_json = api_export.Export{
    .name = "json",
    .kind = .table,
    .install = installJsonExport,
};

const json_api_limits = lua_runtime.JsonConvertLimits{
    .max_depth = 64,
    .max_items = 16 * 1024,
    .max_string_bytes = 8 * 1024 * 1024,
    .max_total_string_bytes = 16 * 1024 * 1024,
};

fn installJsonExport(state: *lua_runtime.LuaState, runner: *runner_mod.ExtensionRunner) void {
    pushJsonTable(state, runner);
    c.lua_setfield(state.L, -2, export_json.name.ptr);
}

fn pushJsonTable(state: *lua_runtime.LuaState, runner: *runner_mod.ExtensionRunner) void {
    const L = state.L;
    c.lua_createtable(L, 0, 2);

    state.pushCClosureWithUserdata(ziJsonEncode, runner);
    c.lua_setfield(L, -2, "encode");

    state.pushCClosureWithUserdata(ziJsonDecode, runner);
    c.lua_setfield(L, -2, "decode");
}

fn ziJsonEncode(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = runnerFromUpvalue(L);

    var budget = lua_runtime.JsonConvertBudget{ .limits = json_api_limits };
    const value = lua_runtime.luaValueToJsonLimited(L, 1, runner.allocator, &budget) catch |err| {
        return luaErrorFmt(L, "zi.json.encode: unsupported value: {s}", .{@errorName(err)});
    };
    defer lua_runtime.freeJsonValue(runner.allocator, value);

    var out: std.Io.Writer.Allocating = .init(runner.allocator);
    defer out.deinit();
    std.json.Stringify.value(value, .{}, &out.writer) catch |err| {
        out.deinit();
        lua_runtime.freeJsonValue(runner.allocator, value);
        return luaErrorFmt(L, "zi.json.encode: stringify failed: {s}", .{@errorName(err)});
    };

    const written = out.written();
    Lua.init(L).pushString(written);
    return 1;
}

fn ziJsonDecode(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = runnerFromUpvalue(L);

    if (Lua.init(L).typeOf(1) != .string) {
        return luaError(L, "zi.json.decode: expected string");
    }
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, 1, &len) orelse return luaError(L, "zi.json.decode: expected string");
    const src = ptr[0..len];
    if (src.len > json_api_limits.max_total_string_bytes) {
        return luaError(L, "zi.json.decode: input too large");
    }

    const parsed = std.json.parseFromSlice(std.json.Value, runner.allocator, src, .{ .allocate = .alloc_always }) catch |err| {
        return luaErrorFmt(L, "zi.json.decode: parse failed: {s}", .{@errorName(err)});
    };
    defer parsed.deinit();

    lua_runtime.pushJsonValue(L, parsed.value) catch |err| {
        parsed.deinit();
        return luaErrorFmt(L, "zi.json.decode: conversion failed: {s}", .{@errorName(err)});
    };
    return 1;
}

fn runnerFromUpvalue(L: *c.lua_State) *runner_mod.ExtensionRunner {
    return lua_helpers.ptrFromUpvalue(runner_mod.ExtensionRunner, Lua.init(L), 1);
}

fn luaError(L: *c.lua_State, msg: [:0]const u8) c_int {
    return lua_helpers.raiseError(Lua.init(L), msg);
}

fn luaErrorFmt(L: *c.lua_State, comptime fmt: []const u8, args: anytype) c_int {
    return lua_helpers.raiseErrorFmt(Lua.init(L), fmt, args);
}

const testing = std.testing;

test "zi.json encode and decode round trip Lua values" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();
    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 1);
    defer runner.deinit();
    pushJsonTable(&state, &runner);
    c.lua_setglobal(state.L, "zi_json");

    try state.doString(
        "local encoded = zi_json.encode({ status = 'submitted', values = { 1, true, 'x' } })\n" ++
            "local decoded = zi_json.decode(encoded)\n" ++
            "assert(decoded.status == 'submitted')\n" ++
            "assert(decoded.values[1] == 1)\n" ++
            "assert(decoded.values[2] == true)\n" ++
            "assert(decoded.values[3] == 'x')\n",
        "json_roundtrip",
    );
}

test "zi.json decode maps null fields to nil" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();
    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 1);
    defer runner.deinit();
    pushJsonTable(&state, &runner);
    c.lua_setglobal(state.L, "zi_json");

    try state.doString(
        "local decoded = zi_json.decode('{\"present\":1,\"missing\":null}')\n" ++
            "assert(decoded.present == 1)\n" ++
            "assert(decoded.missing == nil)\n",
        "json_null",
    );
}

test "zi.json encode rejects unsupported Lua values" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();
    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 1);
    defer runner.deinit();
    pushJsonTable(&state, &runner);
    c.lua_setglobal(state.L, "zi_json");

    try state.doString(
        "local ok = pcall(function() zi_json.encode({ callback = function() end }) end)\n" ++
            "assert(ok == false)\n",
        "json_unsupported",
    );
}
