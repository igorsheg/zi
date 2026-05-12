const std = @import("std");
const lua_runtime = @import("lua_runtime.zig");
const runner_mod = @import("runner.zig");
const command_registry = @import("registries/command_registry.zig");
const tool_registry = @import("registries/tool_registry.zig");

const c = lua_runtime.c;

pub fn ziCommand(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const api_name = "zi.command";

    const L = L_opt.?;
    const runner = runnerFromUpvalue(L);

    if (c.lua_type(L, 1) != c.LUA_TTABLE) {
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

    c.lua_pushboolean(L, 1);
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

    var name: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    defer {
        if (name) |n| a.free(n);
        if (description) |d| a.free(d);
    }

    _ = c.lua_getfield(L, 1, "name");
    if (c.lua_type(L, -1) != c.LUA_TSTRING) {
        c.lua_pop(L, 1);
        return error.MissingName;
    }
    var name_len: usize = 0;
    const name_ptr = c.lua_tolstring(L, -1, &name_len).?;
    name = a.dupe(u8, name_ptr[0..name_len]) catch return error.OutOfMemory;
    c.lua_pop(L, 1);

    _ = c.lua_getfield(L, 1, "description");
    if (c.lua_type(L, -1) == c.LUA_TSTRING) {
        var desc_len: usize = 0;
        const desc_ptr = c.lua_tolstring(L, -1, &desc_len).?;
        description = a.dupe(u8, desc_ptr[0..desc_len]) catch {
            c.lua_pop(L, 1);
            return error.OutOfMemory;
        };
        c.lua_pop(L, 1);
    } else if (c.lua_type(L, -1) == c.LUA_TNIL) {
        c.lua_pop(L, 1);
        description = a.dupe(u8, "") catch return error.OutOfMemory;
    } else {
        c.lua_pop(L, 1);
        return error.InvalidDescription;
    }

    _ = c.lua_getfield(L, 1, "handler");
    if (c.lua_type(L, -1) == c.LUA_TNIL) {
        c.lua_pop(L, 1);
        return error.MissingHandler;
    }
    if (c.lua_type(L, -1) != c.LUA_TFUNCTION) {
        c.lua_pop(L, 1);
        return error.InvalidHandler;
    }
    const handler_ref = c.luaL_ref(L, c.LUA_REGISTRYINDEX);

    const owned_name = name.?;
    const result = command_registry.CommandDef{
        .name = owned_name,
        .visible_name = a.dupe(u8, owned_name) catch {
            c.luaL_unref(L, c.LUA_REGISTRYINDEX, handler_ref);
            return error.OutOfMemory;
        },
        .description = description.?,
        .lua_ref = handler_ref,
        .source = currentRegistrationSource(runner),
    };
    name = null;
    description = null;
    return result;
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

fn luaErrorFmt(L: *c.lua_State, comptime fmt: []const u8, args: anytype) c_int {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buf, fmt, args) catch "lua error";
    _ = c.lua_pushstring(L, msg.ptr);
    _ = c.lua_error(L);
    return 0;
}

fn luaApiError(L: *c.lua_State, api_name: []const u8, detail: []const u8) c_int {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buf, "{s}: {s}", .{ api_name, detail }) catch "lua error";
    _ = c.lua_pushstring(L, msg.ptr);
    _ = c.lua_error(L);
    return 0;
}

fn runnerFromUpvalue(L: *c.lua_State) *runner_mod.ExtensionRunner {
    const raw = c.lua_touserdata(L, c.lua_upvalueindex(1)) orelse unreachable;
    return @ptrCast(@alignCast(raw));
}
