const std = @import("std");
const lua_runtime = @import("lua_runtime.zig");
const lua_helpers = @import("lua_helpers.zig");
const runner_mod = @import("runner.zig");
const api_export = @import("api_export.zig");
const command_registry = @import("registries/command_registry.zig");
const tool_registry = @import("registries/tool_registry.zig");

const c = lua_runtime.c;
const Lua = lua_helpers.Lua;
const FieldReader = lua_helpers.FieldReader;

pub const export_command = api_export.Export{
    .name = "command",
    .kind = .function,
    .install = installCommandExport,
};

fn installCommandExport(state: *lua_runtime.LuaState, runner: *runner_mod.ExtensionRunner) void {
    state.pushCClosureWithUserdata(ziCommand, runner);
    c.lua_setfield(state.L, -2, export_command.name.ptr);
}

pub fn ziCommand(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const api_name = "zi.command";

    const L = L_opt.?;
    const runner = runnerFromUpvalue(L);

    const lua = Lua.init(L);
    if (lua.typeOf(1) != .table) {
        return luaErrorFmt(L, "{s}: expected spec table", .{api_name});
    }

    const cmd = buildCommandDef(L, runner) catch |err| {
        return luaApiError(L, api_name, switch (err) {
            error.MissingName => "missing required field 'name' (string)",
            error.InvalidDescription => "field 'description' must be a string",
            error.MissingHandler => "missing required field 'handler' (function)",
            error.InvalidHandler => "field 'handler' must be a function",
            error.OutOfMemory => "out of memory",
        });
    };

    return registerCommandDef(L, runner, cmd, api_name);
}

fn registerCommandDef(L: *c.lua_State, runner: *runner_mod.ExtensionRunner, cmd_in: command_registry.CommandDef, api_name: [:0]const u8) c_int {
    const cmd = cmd_in;
    runner.command_registry.register(cmd) catch {
        c.luaL_unref(L, c.LUA_REGISTRYINDEX, cmd.lua_ref);
        runner.allocator.free(cmd.name);
        runner.allocator.free(cmd.visible_name);
        runner.allocator.free(cmd.description);
        return luaErrorFmt(L, "{s}: registry insert failed", .{api_name});
    };

    Lua.init(L).pushBool(true);
    return 1;
}

const RegisterCommandError = error{
    OutOfMemory,
    MissingName,
    InvalidDescription,
    MissingHandler,
    InvalidHandler,
};

fn buildCommandDef(
    L: *c.lua_State,
    runner: *runner_mod.ExtensionRunner,
) RegisterCommandError!command_registry.CommandDef {
    const a = runner.allocator;
    const fields = FieldReader.init(Lua.init(L), 1);

    var name: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    var handler_ref = lua_helpers.RegistryRef{};
    defer {
        if (name) |n| a.free(n);
        if (description) |d| a.free(d);
        handler_ref.release(Lua.init(L));
    }

    name = fields.requiredString(a, "name") catch return error.MissingName;
    description = fields.stringOrDefault(a, "description", "") catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidDescription,
    };
    handler_ref = fields.functionRef("handler") catch |err| return switch (err) {
        error.MissingField => error.MissingHandler,
        error.InvalidRegistryRef => error.OutOfMemory,
        else => error.InvalidHandler,
    };

    const owned_name = name.?;
    const result = command_registry.CommandDef{
        .name = owned_name,
        .visible_name = a.dupe(u8, owned_name) catch {
            return error.OutOfMemory;
        },
        .description = description.?,
        .lua_ref = handler_ref.value,
        .source = currentRegistrationSource(runner),
    };
    name = null;
    description = null;
    handler_ref.value = c.LUA_NOREF;
    return result;
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
