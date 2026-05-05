const std = @import("std");
const lua_runtime = @import("lua_runtime.zig");
const runner_mod = @import("runner.zig");
const keybinding_registry = @import("registries/keybinding_registry.zig");
const tool_registry = @import("registries/tool_registry.zig");
const keys_mod = @import("../../tui/terminal/keys.zig");

const c = lua_runtime.c;

/// Lua `zi.register_keybinding(def)`: accepts `key` and/or dense-array `keys`.
pub fn ziRegisterKeybinding(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = runnerFromUpvalue(L);

    if (c.lua_type(L, 1) != c.LUA_TTABLE) {
        return luaError(L, "register_keybinding: expected a table argument");
    }

    const def = buildKeybindingDef(L, runner) catch |err| {
        return luaError(L, switch (err) {
            error.MissingId => "register_keybinding: missing required field \"id\" (string)",
            error.InvalidDescription => "register_keybinding: \"description\" must be a string",
            error.MissingKey => "register_keybinding: missing required field \"key\" or \"keys\"",
            error.InvalidKey => "register_keybinding: key specs must be strings like \"ctrl+f\"",
            error.MissingHandler => "register_keybinding: missing required field \"handler\" (function)",
            error.InvalidHandler => "register_keybinding: \"handler\" must be a function",
            error.OutOfMemory => "register_keybinding: out of memory",
        });
    };

    runner.keybinding_registry.register(def) catch {
        var failed = def;
        c.luaL_unref(L, c.LUA_REGISTRYINDEX, failed.lua_ref);
        failed.deinit(runner.allocator);
        return luaError(L, "register_keybinding: registry insert failed");
    };

    c.lua_pushboolean(L, 1);
    return 1;
}

const RegisterKeybindingError = error{
    OutOfMemory,
    MissingId,
    InvalidDescription,
    MissingKey,
    InvalidKey,
    MissingHandler,
    InvalidHandler,
};

fn buildKeybindingDef(L: *c.lua_State, runner: *runner_mod.ExtensionRunner) RegisterKeybindingError!keybinding_registry.KeybindingDef {
    const a = runner.allocator;
    var id: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    var parsed_keys: std.ArrayListUnmanaged(keys_mod.Key) = .empty;
    var displays: std.ArrayListUnmanaged([]const u8) = .empty;
    var handler_ref: ?c_int = null;
    errdefer {
        if (id) |v| a.free(v);
        if (description) |v| a.free(v);
        parsed_keys.deinit(a);
        for (displays.items) |v| a.free(v);
        displays.deinit(a);
        if (handler_ref) |r| c.luaL_unref(L, c.LUA_REGISTRYINDEX, r);
    }

    _ = c.lua_getfield(L, 1, "id");
    if (c.lua_type(L, -1) != c.LUA_TSTRING) {
        c.lua_pop(L, 1);
        return error.MissingId;
    }
    id = try dupLuaString(a, L, -1);
    c.lua_pop(L, 1);

    _ = c.lua_getfield(L, 1, "description");
    if (c.lua_type(L, -1) == c.LUA_TSTRING) {
        description = try dupLuaString(a, L, -1);
        c.lua_pop(L, 1);
    } else if (c.lua_type(L, -1) == c.LUA_TNIL) {
        c.lua_pop(L, 1);
        description = a.dupe(u8, "") catch return error.OutOfMemory;
    } else {
        c.lua_pop(L, 1);
        return error.InvalidDescription;
    }

    _ = c.lua_getfield(L, 1, "key");
    if (c.lua_type(L, -1) == c.LUA_TSTRING) {
        try appendKeySpec(a, L, -1, &parsed_keys, &displays);
        c.lua_pop(L, 1);
    } else {
        c.lua_pop(L, 1);
    }

    _ = c.lua_getfield(L, 1, "keys");
    if (c.lua_type(L, -1) == c.LUA_TTABLE) {
        const len = c.lua_rawlen(L, -1);
        var i: usize = 1;
        while (i <= len) : (i += 1) {
            _ = c.lua_rawgeti(L, -1, @intCast(i));
            if (c.lua_type(L, -1) != c.LUA_TSTRING) {
                c.lua_pop(L, 2);
                return error.InvalidKey;
            }
            try appendKeySpec(a, L, -1, &parsed_keys, &displays);
            c.lua_pop(L, 1);
        }
        c.lua_pop(L, 1);
    } else if (c.lua_type(L, -1) == c.LUA_TNIL) {
        c.lua_pop(L, 1);
    } else {
        c.lua_pop(L, 1);
        return error.InvalidKey;
    }
    if (parsed_keys.items.len == 0) return error.MissingKey;

    _ = c.lua_getfield(L, 1, "handler");
    if (c.lua_type(L, -1) == c.LUA_TNIL) {
        c.lua_pop(L, 1);
        return error.MissingHandler;
    }
    if (c.lua_type(L, -1) != c.LUA_TFUNCTION) {
        c.lua_pop(L, 1);
        return error.InvalidHandler;
    }
    handler_ref = c.luaL_ref(L, c.LUA_REGISTRYINDEX);

    const keys = parsed_keys.toOwnedSlice(a) catch return error.OutOfMemory;
    const display_slice = displays.toOwnedSlice(a) catch {
        a.free(keys);
        return error.OutOfMemory;
    };
    const result: keybinding_registry.KeybindingDef = .{
        .id = id.?,
        .description = description.?,
        .keys = keys,
        .displays = display_slice,
        .lua_ref = handler_ref.?,
        .source = currentRegistrationSource(runner),
    };
    id = null;
    description = null;
    handler_ref = null;
    return result;
}

fn appendKeySpec(a: std.mem.Allocator, L: *c.lua_State, index: c_int, parsed_keys: *std.ArrayListUnmanaged(keys_mod.Key), displays: *std.ArrayListUnmanaged([]const u8)) RegisterKeybindingError!void {
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, index, &len).?;
    const text = ptr[0..len];
    const key = keys_mod.parseKeySpec(text) catch return error.InvalidKey;
    const display = a.dupe(u8, text) catch return error.OutOfMemory;
    errdefer a.free(display);
    try parsed_keys.append(a, key);
    try displays.append(a, display);
}

fn dupLuaString(a: std.mem.Allocator, L: *c.lua_State, index: c_int) RegisterKeybindingError![]const u8 {
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, index, &len).?;
    return a.dupe(u8, ptr[0..len]) catch error.OutOfMemory;
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
