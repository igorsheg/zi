const std = @import("std");
const lua_runtime = @import("lua_runtime.zig");
const lua_helpers = @import("lua_helpers.zig");

const c = lua_runtime.c;
const Lua = lua_helpers.Lua;
const RegistryRef = lua_helpers.RegistryRef;

pub const Error = error{
    MissingField,
    WrongType,
    UnknownField,
    UnsupportedLuaType,
    InvalidUtf8,
    LimitExceeded,
    InvalidRegistryRef,
    OutOfMemory,
};

pub const Table = struct {
    lua: Lua,
    allocator: std.mem.Allocator,
    index: c_int,

    pub fn init(lua: Lua, allocator: std.mem.Allocator, index: c_int) Table {
        return .{
            .lua = lua,
            .allocator = allocator,
            .index = lua.absIndex(index),
        };
    }

    pub fn rejectUnknownFields(self: Table, allowed: []const [:0]const u8) Error!void {
        c.lua_pushnil(self.lua.L);
        while (c.lua_next(self.lua.L, self.index) != 0) {
            if (self.lua.typeOf(-2) != .string) {
                self.lua.pop(2);
                return error.UnknownField;
            }
            var len: usize = 0;
            const ptr = c.lua_tolstring(self.lua.L, -2, &len) orelse {
                self.lua.pop(2);
                return error.UnknownField;
            };
            if (!fieldAllowed(ptr[0..len], allowed)) {
                self.lua.pop(2);
                return error.UnknownField;
            }
            self.lua.pop(1);
        }
    }

    pub fn requiredString(self: Table, key: [:0]const u8) Error![]u8 {
        _ = self.lua.getField(self.index, key);
        defer self.lua.pop(1);
        return switch (self.lua.typeOf(-1)) {
            .nil => error.MissingField,
            .string => try self.dupeStringAtTop(),
            else => error.WrongType,
        };
    }

    pub fn optionalString(self: Table, key: [:0]const u8) Error!?[]u8 {
        _ = self.lua.getField(self.index, key);
        defer self.lua.pop(1);
        return switch (self.lua.typeOf(-1)) {
            .nil => null,
            .string => try self.dupeStringAtTop(),
            else => error.WrongType,
        };
    }

    pub fn requiredFunctionRef(self: Table, key: [:0]const u8) Error!RegistryRef {
        _ = self.lua.getField(self.index, key);
        errdefer self.lua.pop(1);
        return switch (self.lua.typeOf(-1)) {
            .nil => error.MissingField,
            .function => RegistryRef.take(self.lua) catch error.InvalidRegistryRef,
            else => error.WrongType,
        };
    }

    pub fn requiredJsonTable(self: Table, key: [:0]const u8, limits: lua_runtime.JsonConvertLimits) Error!std.json.Value {
        _ = self.lua.getField(self.index, key);
        defer self.lua.pop(1);
        return switch (self.lua.typeOf(-1)) {
            .nil => error.MissingField,
            .table => blk: {
                var budget = lua_runtime.JsonConvertBudget{ .limits = limits };
                break :blk lua_runtime.luaValueToJsonLimited(self.lua.L, -1, self.allocator, &budget) catch |err| switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.UnsupportedLuaType => error.UnsupportedLuaType,
                    error.InvalidUtf8 => error.InvalidUtf8,
                    error.LimitExceeded => error.LimitExceeded,
                };
            },
            else => error.WrongType,
        };
    }

    pub fn optionalStringArray(self: Table, key: [:0]const u8) Error![]const []const u8 {
        _ = self.lua.getField(self.index, key);
        defer self.lua.pop(1);
        return switch (self.lua.typeOf(-1)) {
            .nil => &.{},
            .table => try self.stringArrayAtTop(),
            else => error.WrongType,
        };
    }

    fn stringArrayAtTop(self: Table) Error![]const []const u8 {
        const len = c.lua_rawlen(self.lua.L, -1);
        if (len == 0) return &.{};

        const items = try self.allocator.alloc([]const u8, len);
        var initialized: usize = 0;
        errdefer {
            for (items[0..initialized]) |item| self.allocator.free(item);
            self.allocator.free(items);
        }

        const table_idx = self.lua.absIndex(-1);
        var i: usize = 0;
        while (i < len) : (i += 1) {
            _ = c.lua_rawgeti(self.lua.L, table_idx, @intCast(i + 1));
            defer if (self.lua.top() >= table_idx + 1) self.lua.pop(1);
            if (self.lua.typeOf(-1) != .string) return error.WrongType;
            items[i] = try self.dupeStringAtTop();
            initialized += 1;
            self.lua.pop(1);
        }
        return items;
    }

    fn dupeStringAtTop(self: Table) Error![]u8 {
        var len: usize = 0;
        const ptr = c.lua_tolstring(self.lua.L, -1, &len) orelse return error.WrongType;
        return self.allocator.dupe(u8, ptr[0..len]) catch error.OutOfMemory;
    }
};

fn fieldAllowed(name: []const u8, allowed: []const [:0]const u8) bool {
    for (allowed) |field| {
        if (std.mem.eql(u8, name, field)) return true;
    }
    return false;
}
