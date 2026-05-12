const std = @import("std");
const lua_runtime = @import("lua_runtime.zig");
const runner_mod = @import("runner.zig");
const command_api = @import("command_api.zig");
const tool_api = @import("tool_api.zig");
const provider_api = @import("provider_api.zig");
const event_api = @import("event_api.zig");
const system_api = @import("system_api.zig");
const spawn_api = @import("spawn_api.zig");
const job_api = @import("job_api.zig");
const json_api = @import("json_api.zig");

const c = lua_runtime.c;

pub fn install(state: *lua_runtime.LuaState, runner: *runner_mod.ExtensionRunner) void {
    const L = state.L;
    c.lua_createtable(L, 0, 9);

    installRegistrationGroup(state, runner);
    installProcessGroup(state, runner);
    installDataGroup(state, runner);

    c.lua_setglobal(L, "zi");
}

fn installRegistrationGroup(state: *lua_runtime.LuaState, runner: *runner_mod.ExtensionRunner) void {
    const L = state.L;

    state.pushCClosureWithUserdata(command_api.ziCommand, runner);
    c.lua_setfield(L, -2, "command");

    state.pushCClosureWithUserdata(tool_api.ziTool, runner);
    c.lua_setfield(L, -2, "tool");

    state.pushCClosureWithUserdata(provider_api.ziProvider, runner);
    c.lua_setfield(L, -2, "provider");

    state.pushCClosureWithUserdata(provider_api.ziUnprovider, runner);
    c.lua_setfield(L, -2, "unprovider");

    state.pushCClosureWithUserdata(event_api.ziOn, runner);
    c.lua_setfield(L, -2, "on");
}

fn installProcessGroup(state: *lua_runtime.LuaState, runner: *runner_mod.ExtensionRunner) void {
    const L = state.L;

    state.pushCClosureWithUserdata(system_api.ziSystem, runner);
    c.lua_setfield(L, -2, "system");

    state.pushCClosureWithUserdata(spawn_api.ziSpawn, runner);
    c.lua_setfield(L, -2, "spawn");

    job_api.install(state, runner);
    c.lua_setfield(L, -2, "job");
}

fn installDataGroup(state: *lua_runtime.LuaState, runner: *runner_mod.ExtensionRunner) void {
    const L = state.L;

    json_api.install(state, runner);
    c.lua_setfield(L, -2, "json");
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
    try state.doString(
        \\local expected = {
        \\  command = true,
        \\  tool = true,
        \\  provider = true,
        \\  unprovider = true,
        \\  on = true,
        \\  system = true,
        \\  spawn = true,
        \\  job = true,
        \\  json = true,
        \\}
        \\for k, _ in pairs(zi) do
        \\  assert(expected[k], "unexpected zi global: " .. tostring(k))
        \\end
        \\for k, _ in pairs(expected) do
        \\  assert(zi[k] ~= nil, "missing zi global: " .. tostring(k))
        \\end
        \\assert(type(zi.command) == "function")
        \\assert(type(zi.tool) == "function")
        \\assert(type(zi.provider) == "function")
        \\assert(type(zi.unprovider) == "function")
        \\assert(type(zi.on) == "function")
        \\assert(type(zi.system) == "function")
        \\assert(type(zi.spawn) == "function")
        \\assert(type(zi.job) == "table")
        \\assert(type(zi.job.start) == "function")
        \\assert(type(zi.job.write) == "function")
        \\assert(type(zi.job.stop) == "function")
        \\assert(type(zi.json) == "table")
        \\assert(type(zi.json.encode) == "function")
        \\assert(type(zi.json.decode) == "function")
        \\local expected_json = { encode = true, decode = true }
        \\for k, _ in pairs(zi.json) do
        \\  assert(expected_json[k], "unexpected zi.json field: " .. tostring(k))
        \\end
        \\for k, _ in pairs(expected_json) do
        \\  assert(zi.json[k] ~= nil, "missing zi.json field: " .. tostring(k))
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
