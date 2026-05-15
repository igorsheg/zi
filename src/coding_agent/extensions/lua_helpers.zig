const std = @import("std");
const lua_runtime = @import("lua_runtime.zig");

pub const c = lua_runtime.c;

pub const LuaType = enum {
    none,
    nil,
    boolean,
    lightuserdata,
    number,
    string,
    table,
    function,
    userdata,
    thread,

    pub fn fromC(value: c_int) LuaType {
        return switch (value) {
            c.LUA_TNONE => .none,
            c.LUA_TNIL => .nil,
            c.LUA_TBOOLEAN => .boolean,
            c.LUA_TLIGHTUSERDATA => .lightuserdata,
            c.LUA_TNUMBER => .number,
            c.LUA_TSTRING => .string,
            c.LUA_TTABLE => .table,
            c.LUA_TFUNCTION => .function,
            c.LUA_TUSERDATA => .userdata,
            c.LUA_TTHREAD => .thread,
            else => .none,
        };
    }
};

pub const Lua = struct {
    L: *c.lua_State,

    pub fn init(L: *c.lua_State) Lua {
        return .{ .L = L };
    }

    pub fn top(self: Lua) c_int {
        return c.lua_gettop(self.L);
    }

    pub fn setTop(self: Lua, value: c_int) void {
        c.lua_settop(self.L, value);
    }

    pub fn pop(self: Lua, n: c_int) void {
        c.lua_pop(self.L, n);
    }

    pub fn absIndex(self: Lua, index: c_int) c_int {
        return c.lua_absindex(self.L, index);
    }

    pub fn typeOf(self: Lua, index: c_int) LuaType {
        return LuaType.fromC(c.lua_type(self.L, index));
    }

    pub fn pushNil(self: Lua) void {
        c.lua_pushnil(self.L);
    }

    pub fn pushBool(self: Lua, value: bool) void {
        c.lua_pushboolean(self.L, if (value) 1 else 0);
    }

    pub fn pushInt(self: Lua, value: anytype) void {
        c.lua_pushinteger(self.L, @intCast(value));
    }

    pub fn pushNumber(self: Lua, value: f64) void {
        c.lua_pushnumber(self.L, value);
    }

    pub fn pushString(self: Lua, value: []const u8) void {
        _ = c.lua_pushlstring(self.L, value.ptr, value.len);
    }

    pub fn pushStringZ(self: Lua, value: [:0]const u8) void {
        _ = c.lua_pushstring(self.L, value.ptr);
    }

    pub fn getField(self: Lua, index: c_int, key: [:0]const u8) LuaType {
        _ = c.lua_getfield(self.L, index, key.ptr);
        return self.typeOf(-1);
    }

    pub fn setField(self: Lua, index: c_int, key: [:0]const u8) void {
        c.lua_setfield(self.L, index, key.ptr);
    }

    pub fn rawGetIndex(self: Lua, index: c_int, array_index: c.lua_Integer) LuaType {
        _ = c.lua_rawgeti(self.L, index, array_index);
        return self.typeOf(-1);
    }

    pub fn rawSetIndex(self: Lua, index: c_int, array_index: c.lua_Integer) void {
        c.lua_rawseti(self.L, index, array_index);
    }

    pub fn pushValue(self: Lua, index: c_int) void {
        c.lua_pushvalue(self.L, index);
    }
};

pub const StackGuard = struct {
    lua: Lua,
    top_value: c_int,

    pub fn init(lua: Lua) StackGuard {
        return .{ .lua = lua, .top_value = lua.top() };
    }

    pub fn restore(self: StackGuard) void {
        self.lua.setTop(self.top_value);
    }

    pub fn assertUnchanged(self: StackGuard) void {
        std.debug.assert(self.lua.top() == self.top_value);
    }
};

pub const TableBuilder = struct {
    lua: Lua,
    index: c_int,

    pub fn create(lua: Lua, array_hint: c_int, record_hint: c_int) TableBuilder {
        c.lua_createtable(lua.L, array_hint, record_hint);
        return .{ .lua = lua, .index = lua.absIndex(-1) };
    }

    pub fn atTop(lua: Lua) TableBuilder {
        return .{ .lua = lua, .index = lua.absIndex(-1) };
    }

    pub fn string(self: TableBuilder, key: [:0]const u8, value: []const u8) void {
        self.lua.pushString(value);
        self.lua.setField(self.index, key);
    }

    pub fn stringZ(self: TableBuilder, key: [:0]const u8, value: [:0]const u8) void {
        self.lua.pushStringZ(value);
        self.lua.setField(self.index, key);
    }

    pub fn optionalString(self: TableBuilder, key: [:0]const u8, value: ?[]const u8) void {
        if (value) |s| self.lua.pushString(s) else self.lua.pushNil();
        self.lua.setField(self.index, key);
    }

    pub fn boolean(self: TableBuilder, key: [:0]const u8, value: bool) void {
        self.lua.pushBool(value);
        self.lua.setField(self.index, key);
    }

    pub fn int(self: TableBuilder, key: [:0]const u8, value: anytype) void {
        self.lua.pushInt(value);
        self.lua.setField(self.index, key);
    }

    pub fn number(self: TableBuilder, key: [:0]const u8, value: f64) void {
        self.lua.pushNumber(value);
        self.lua.setField(self.index, key);
    }

    pub fn nil(self: TableBuilder, key: [:0]const u8) void {
        self.lua.pushNil();
        self.lua.setField(self.index, key);
    }

    pub fn setFieldFromTop(self: TableBuilder, key: [:0]const u8) void {
        self.lua.setField(self.index, key);
    }

    pub fn rawSetArrayFromTop(self: TableBuilder, array_index: usize) void {
        self.lua.rawSetIndex(self.index, @intCast(array_index));
    }
};

pub const RegistryRef = struct {
    value: c_int = c.LUA_NOREF,

    pub fn take(lua: Lua) !RegistryRef {
        const value = c.luaL_ref(lua.L, c.LUA_REGISTRYINDEX);
        if (value == c.LUA_REFNIL or value == c.LUA_NOREF) return error.InvalidRegistryRef;
        return .{ .value = value };
    }

    pub fn push(self: RegistryRef, lua: Lua) !void {
        if (!self.isValid()) return error.InvalidRegistryRef;
        _ = c.lua_rawgeti(lua.L, c.LUA_REGISTRYINDEX, self.value);
    }

    pub fn release(self: *RegistryRef, lua: Lua) void {
        if (self.isValid()) {
            c.luaL_unref(lua.L, c.LUA_REGISTRYINDEX, self.value);
            self.value = c.LUA_NOREF;
        }
    }

    pub fn isValid(self: RegistryRef) bool {
        return self.value != c.LUA_NOREF and self.value != c.LUA_REFNIL;
    }

    pub fn takeValueAt(lua: Lua, index: c_int) !RegistryRef {
        lua.pushValue(index);
        return take(lua);
    }
};

pub const FieldReader = struct {
    lua: Lua,
    table_index: c_int,

    pub fn init(lua: Lua, table_index: c_int) FieldReader {
        return .{ .lua = lua, .table_index = lua.absIndex(table_index) };
    }

    pub fn has(self: FieldReader, key: [:0]const u8) bool {
        _ = self.lua.getField(self.table_index, key);
        defer self.lua.pop(1);
        return self.lua.typeOf(-1) != .nil;
    }

    pub fn requiredString(self: FieldReader, allocator: std.mem.Allocator, key: [:0]const u8) ![]u8 {
        _ = self.lua.getField(self.table_index, key);
        defer self.lua.pop(1);
        if (self.lua.typeOf(-1) != .string) return error.WrongType;
        return try self.dupeStringAtTop(allocator);
    }

    pub fn optionalString(self: FieldReader, allocator: std.mem.Allocator, key: [:0]const u8) !?[]u8 {
        _ = self.lua.getField(self.table_index, key);
        defer self.lua.pop(1);
        return switch (self.lua.typeOf(-1)) {
            .nil => null,
            .string => try self.dupeStringAtTop(allocator),
            else => error.WrongType,
        };
    }

    pub fn stringOrDefault(self: FieldReader, allocator: std.mem.Allocator, key: [:0]const u8, default: []const u8) ![]u8 {
        return (try self.optionalString(allocator, key)) orelse try allocator.dupe(u8, default);
    }

    pub fn functionRef(self: FieldReader, key: [:0]const u8) !RegistryRef {
        _ = self.lua.getField(self.table_index, key);
        errdefer self.lua.pop(1);
        return switch (self.lua.typeOf(-1)) {
            .nil => error.MissingField,
            .function => try RegistryRef.take(self.lua),
            else => error.WrongType,
        };
    }

    fn dupeStringAtTop(self: FieldReader, allocator: std.mem.Allocator) ![]u8 {
        var len: usize = 0;
        const ptr = c.lua_tolstring(self.lua.L, -1, &len) orelse return error.WrongType;
        return try allocator.dupe(u8, ptr[0..len]);
    }
};

pub fn ptrFromUpvalue(comptime T: type, lua: Lua, upvalue_index: c_int) *T {
    const raw = c.lua_touserdata(lua.L, c.lua_upvalueindex(upvalue_index)) orelse unreachable;
    return @ptrCast(@alignCast(raw));
}

pub fn raiseError(lua: Lua, msg: [:0]const u8) c_int {
    lua.pushStringZ(msg);
    _ = c.lua_error(lua.L);
    return 0;
}

pub fn raiseErrorFmt(lua: Lua, comptime fmt: []const u8, args: anytype) c_int {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buf, fmt, args) catch "lua error";
    lua.pushStringZ(msg);
    _ = c.lua_error(lua.L);
    return 0;
}
