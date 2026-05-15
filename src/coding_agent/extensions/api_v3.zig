const std = @import("std");
const lua_runtime = @import("lua_runtime.zig");
const runner_mod = @import("runner.zig");
const api_export = @import("api_export.zig");
const command_api = @import("command_api.zig");
const tool_api = @import("tool_api.zig");
const provider_api = @import("provider_api.zig");
const event_api = @import("event_api.zig");
const system_api = @import("system_api.zig");
const spawn_api = @import("spawn_api.zig");
const job_api = @import("job_api.zig");
const json_api = @import("json_api.zig");

const c = lua_runtime.c;

pub const Export = api_export.Export;
pub const ExportKind = api_export.Kind;

pub const exports = [_]Export{
    command_api.export_command,
    tool_api.export_tool,
    provider_api.export_provider,
    provider_api.export_unprovider,
    event_api.export_on,
    system_api.export_system,
    spawn_api.export_spawn,
    job_api.export_job,
    json_api.export_json,
};

pub fn install(state: *lua_runtime.LuaState, runner: *runner_mod.ExtensionRunner) void {
    const L = state.L;
    c.lua_createtable(L, 0, exports.len);

    for (exports) |exp| {
        const before = c.lua_gettop(L);
        exp.install(state, runner);
        std.debug.assert(c.lua_gettop(L) == before);
    }

    c.lua_setglobal(L, "zi");
}

const testing = std.testing;

test "api v3 registration group reports v3 names" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();

    install(&state, &runner);

    try state.doString(
        \\local cases = {
        \\  { function() zi.command(nil) end, "zi.command:" },
        \\  { function() zi.tool(nil) end, "zi.tool:" },
        \\  { function() zi.provider(nil, {}) end, "zi.provider:" },
        \\  { function() zi.unprovider(nil) end, "zi.unprovider:" },
        \\  { function() zi.on(nil, function() end) end, "zi.on:" },
        \\}
        \\for _, case in ipairs(cases) do
        \\  local ok, err = pcall(case[1])
        \\  assert(not ok, "expected API call to fail")
        \\  assert(string.find(tostring(err), case[2], 1, true), tostring(err))
        \\end
    , "api_v3_registration_errors");
}

test "api v3 installs exactly the public zi global groups" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();

    install(&state, &runner);

    const L = state.L;
    _ = c.lua_getglobal(L, "zi");
    defer c.lua_pop(L, 1);
    try testing.expectEqual(c.LUA_TTABLE, c.lua_type(L, -1));

    for (exports) |exp| {
        _ = c.lua_getfield(L, -1, exp.name.ptr);
        defer c.lua_pop(L, 1);
        try testing.expectEqual(expectedLuaType(exp.kind), c.lua_type(L, -1));
    }

    try expectNoExtraZiGlobals(L, -1);

    try state.doString(
        \\assert(type(zi.job.start) == "function")
        \\assert(type(zi.job.write) == "function")
        \\assert(type(zi.job.stop) == "function")
        \\assert(type(zi.job.next) == "function")
        \\assert(type(zi.json.encode) == "function")
        \\assert(type(zi.json.decode) == "function")
        \\local expected_json = { encode = true, decode = true }
        \\for k, _ in pairs(zi.json) do
        \\  assert(expected_json[k], "unexpected zi.json field: " .. tostring(k))
        \\end
        \\local legacy = {
        \\  "register_" .. "tool",
        \\  "register_" .. "command",
        \\  "register_" .. "keybinding",
        \\  "register_" .. "provider",
        \\  "unregister_" .. "provider",
        \\  "__register_" .. "builtin_tools",
        \\}
        \\for _, name in ipairs(legacy) do
        \\  assert(zi[name] == nil, "legacy API exposed: " .. name)
        \\end
    , "api_v3_perimeter");
}

fn expectedLuaType(kind: ExportKind) c_int {
    return switch (kind) {
        .function => c.LUA_TFUNCTION,
        .table => c.LUA_TTABLE,
    };
}

fn expectNoExtraZiGlobals(L: *c.lua_State, table_idx: c_int) !void {
    const abs_idx = c.lua_absindex(L, table_idx);
    c.lua_pushnil(L);
    while (c.lua_next(L, abs_idx) != 0) {
        defer c.lua_pop(L, 1);
        try testing.expectEqual(c.LUA_TSTRING, c.lua_type(L, -2));
        var len: usize = 0;
        const ptr = c.lua_tolstring(L, -2, &len) orelse return error.InvalidZiGlobalName;
        try testing.expect(exportNameInManifest(ptr[0..len]));
    }
}

fn exportNameInManifest(name: []const u8) bool {
    for (exports) |exp| {
        if (std.mem.eql(u8, exp.name, name)) return true;
    }
    return false;
}

test "api v3 json group reports v3 diagnostic names" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();

    install(&state, &runner);

    try state.doString(
        \\local cases = {
        \\  { function() zi.json.encode(function() end) end, "zi.json.encode:" },
        \\  { function() zi.json.decode({}) end, "zi.json.decode:" },
        \\}
        \\for _, case in ipairs(cases) do
        \\  local ok, err = pcall(case[1])
        \\  assert(not ok, "expected API call to fail")
        \\  assert(string.find(tostring(err), case[2], 1, true), tostring(err))
        \\end
    , "api_v3_json_errors");
}
