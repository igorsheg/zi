const std = @import("std");
const lua_runtime = @import("lua_runtime.zig");
const lua_helpers = @import("lua_helpers.zig");
const runner_mod = @import("runner.zig");
const api_export = @import("api_export.zig");
const command_api = @import("command_api.zig");
const tool_api = @import("tool_api.zig");
const provider_api = @import("provider_api.zig");
const event_api = @import("event_api.zig");
const json_api = @import("json_api.zig");
const keybinding_api = @import("keybinding_api.zig");
const builtin_lua = @import("builtin_lua.zig");

const c = lua_runtime.c;

pub const Export = api_export.Export;
pub const ExportKind = api_export.Kind;

pub const exports = [_]Export{
    json_api.export_json,
};

pub fn install(state: *lua_runtime.LuaState, runner: *runner_mod.ExtensionRunner) void {
    builtin_lua.install(state) catch {};
    const L = state.L;
    c.lua_createtable(L, 0, exports.len + 4);

    for (exports) |exp| {
        if (std.mem.eql(u8, exp.name, "command") or std.mem.eql(u8, exp.name, "tool")) continue;
        const before = c.lua_gettop(L);
        exp.install(state, runner);
        std.debug.assert(c.lua_gettop(L) == before);
    }

    c.lua_createtable(L, 0, 5);
    var before = c.lua_gettop(L);
    command_api.export_command.install(state, runner);
    std.debug.assert(c.lua_gettop(L) == before);
    before = c.lua_gettop(L);
    tool_api.export_tool.install(state, runner);
    std.debug.assert(c.lua_gettop(L) == before);
    before = c.lua_gettop(L);
    event_api.export_on.install(state, runner);
    std.debug.assert(c.lua_gettop(L) == before);
    before = c.lua_gettop(L);
    provider_api.export_provider.install(state, runner);
    std.debug.assert(c.lua_gettop(L) == before);
    state.pushCClosureWithUserdata(keybinding_api.ziRegisterKeybinding, runner);
    c.lua_setfield(L, -2, "keybinding");
    state.pushCClosureWithUserdata(ziDefineAction, runner);
    c.lua_setfield(L, -2, "action");
    c.lua_setfield(L, -2, "define");

    installVersion(L);
    c.lua_setfield(L, -2, "version");
    installExtension(L);
    c.lua_setfield(L, -2, "extension");
    installSchema(L);
    c.lua_setfield(L, -2, "schema");
    installDoc(L);
    c.lua_setfield(L, -2, "doc");

    c.lua_setglobal(L, "zi");
}

fn installVersion(L: *c.lua_State) void {
    c.lua_createtable(L, 0, 2);
    c.lua_pushinteger(L, 4);
    c.lua_setfield(L, -2, "api");
    _ = c.lua_pushlstring(L, "zi", 2);
    c.lua_setfield(L, -2, "host");
}

fn installExtension(L: *c.lua_State) void {
    c.lua_createtable(L, 0, 4);
    _ = c.lua_pushlstring(L, "", 0);
    c.lua_setfield(L, -2, "id");
    _ = c.lua_pushlstring(L, "", 0);
    c.lua_setfield(L, -2, "name");
    _ = c.lua_pushlstring(L, "", 0);
    c.lua_setfield(L, -2, "root");
    c.lua_pushcfunction(L, ziExtensionRequire);
    c.lua_setfield(L, -2, "require");
}

fn installSchema(L: *c.lua_State) void {
    c.lua_createtable(L, 0, 7);
    inline for (.{ "object", "string", "number", "integer", "boolean", "array", "enum" }) |name| {
        c.lua_pushcfunction(L, ziSchemaConstructor);
        c.lua_setfield(L, -2, name);
    }
}

fn installDoc(L: *c.lua_State) void {
    _ = c.lua_getglobal(L, "require");
    _ = c.lua_pushliteral(L, "zi.doc");
    if (c.lua_pcallk(L, 1, 1, 0, 0, null) != c.LUA_OK) {
        c.lua_pop(L, 1);
        c.lua_createtable(L, 0, 0);
    }
}

fn ziExtensionRequire(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    if (c.lua_type(L, 1) != c.LUA_TSTRING) return c.luaL_error(L, "zi.extension.require: expected module path");
    _ = c.lua_getglobal(L, "require");
    c.lua_pushvalue(L, 1);
    if (c.lua_pcallk(L, 1, 1, 0, 0, null) != c.LUA_OK) return c.lua_error(L);
    return 1;
}

fn ziSchemaConstructor(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    c.lua_createtable(L, 0, 8);
    if (c.lua_type(L, 1) == c.LUA_TTABLE) {
        c.lua_pushnil(L);
        while (c.lua_next(L, 1) != 0) {
            c.lua_pushvalue(L, -2);
            c.lua_insert(L, -2);
            c.lua_settable(L, -4);
        }
    }
    return 1;
}

fn ziDefineAction(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    if (c.lua_type(L, 1) != c.LUA_TSTRING) return c.luaL_error(L, "zi.define.action: expected action name");
    if (c.lua_type(L, 2) != c.LUA_TFUNCTION) return c.luaL_error(L, "zi.define.action: expected handler function");
    const runner = lua_helpers.ptrFromUpvalue(runner_mod.ExtensionRunner, lua_helpers.Lua.init(L), 1);
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, 1, &len) orelse return c.luaL_error(L, "zi.define.action: invalid action name");
    const lua = lua_helpers.Lua.init(L);
    var handler_ref = lua_helpers.RegistryRef.takeValueAt(lua, 2) catch return c.luaL_error(L, "zi.define.action: failed to capture handler");
    errdefer handler_ref.release(lua);
    const source = runner.currentLoadSource();
    runner.action_registry.put(ptr[0..len], .{
        .lua_ref = handler_ref.value,
        .source_id = if (source) |s| s.path else "lua",
        .provenance = if (source) |s| s.provenance else null,
    }) catch return c.luaL_error(L, "zi.define.action: register failed");
    handler_ref.value = c.LUA_NOREF;
    return 0;
}

const testing = std.testing;

test "api v4 command registration reports v4 name" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();

    install(&state, &runner);

    try state.doString(
        \\local cases = {
        \\  { function() zi.define.command(nil) end, "zi.define.command:" },
        \\  { function() zi.define.tool(nil) end, "zi.define.tool:" },
        \\}
        \\for _, case in ipairs(cases) do
        \\  local ok, err = pcall(case[1])
        \\  assert(not ok, "expected API call to fail")
        \\  assert(string.find(tostring(err), case[2], 1, true), tostring(err))
        \\end
    , "api_v4_registration_errors");
}

test "api v4 command installs under define" {
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
        if (std.mem.eql(u8, exp.name, "command") or std.mem.eql(u8, exp.name, "tool")) continue;
        _ = c.lua_getfield(L, -1, exp.name.ptr);
        defer c.lua_pop(L, 1);
        try testing.expectEqual(expectedLuaType(exp.kind), c.lua_type(L, -1));
    }

    try expectNoExtraZiGlobals(L, -1);

    try state.doString(
        \\assert(type(zi.json.encode) == "function")
        \\assert(type(zi.json.decode) == "function")
        \\assert(type(zi.define.command) == "function")
        \\assert(type(zi.define.tool) == "function")
        \\assert(type(zi.define.provider) == "function")
        \\assert(type(zi.define.event) == "function")
        \\assert(type(zi.define.keybinding) == "function")
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
        \\  "system", "spawn", "job", "command", "tool", "provider", "on",
        \\}
        \\for _, name in ipairs(legacy) do
        \\  assert(zi[name] == nil, "legacy API exposed: " .. name)
        \\end
    , "api_v4_perimeter");
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
    if (std.mem.eql(u8, name, "define") or std.mem.eql(u8, name, "version") or std.mem.eql(u8, name, "extension") or std.mem.eql(u8, name, "schema") or std.mem.eql(u8, name, "doc")) return true;
    for (exports) |exp| {
        if (std.mem.eql(u8, exp.name, name)) return true;
    }
    return false;
}

test "api v4 json group reports v4 diagnostic names" {
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
    , "api_v4_json_errors");
}
