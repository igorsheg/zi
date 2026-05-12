const std = @import("std");
const limits = @import("limits.zig");

pub const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lauxlib.h");
    @cInclude("lualib.h");
});

const header_align: usize = @alignOf(usize) * 2;
const header_alignment: std.mem.Alignment = .fromByteUnits(header_align);

const BlockHeader = extern struct {
    size: usize,
    _pad: usize = 0,
};

const AllocatorUd = struct {
    allocator: std.mem.Allocator,
};

fn luaAlloc(
    ud: ?*anyopaque,
    ptr: ?*anyopaque,
    osize: usize,
    nsize: usize,
) callconv(.c) ?*anyopaque {
    const self: *AllocatorUd = @ptrCast(@alignCast(ud.?));
    const allocator = self.allocator;

    const old_total: usize = if (ptr != null) blk: {
        const user_ptr: [*]u8 = @ptrCast(ptr.?);
        const header_ptr: *BlockHeader = @ptrCast(@alignCast(user_ptr - @sizeOf(BlockHeader)));
        break :blk header_ptr.size;
    } else 0;
    _ = osize;

    if (nsize == 0) {
        if (ptr == null) return null;
        const user_ptr: [*]u8 = @ptrCast(ptr.?);
        const base = user_ptr - @sizeOf(BlockHeader);
        const total = @sizeOf(BlockHeader) + old_total;
        const slice = base[0..total];
        allocator.rawFree(slice, header_alignment, @returnAddress());
        return null;
    }

    const new_total = @sizeOf(BlockHeader) + nsize;
    const new_base = allocator.rawAlloc(new_total, header_alignment, @returnAddress()) orelse return null;
    const new_header: *BlockHeader = @ptrCast(@alignCast(new_base));
    new_header.* = .{ .size = nsize };
    const new_user = new_base + @sizeOf(BlockHeader);

    if (ptr) |old_user_raw| {
        const old_user: [*]u8 = @ptrCast(old_user_raw);
        const copy_len = @min(old_total, nsize);
        @memcpy(new_user[0..copy_len], old_user[0..copy_len]);
        const old_base = old_user - @sizeOf(BlockHeader);
        const old_total_with_header = @sizeOf(BlockHeader) + old_total;
        const old_slice = old_base[0..old_total_with_header];
        allocator.rawFree(old_slice, header_alignment, @returnAddress());
    }

    return @ptrCast(new_user);
}

pub const LuaError = error{
    OutOfMemory,
    LuaRuntime,
    LuaSyntax,
    LuaMemory,
    LuaError,
    InvalidCoroutineState,
};

pub const LuaState = struct {
    allocator: std.mem.Allocator,

    ud: *AllocatorUd,
    L: *c.lua_State,

    pub fn init(allocator: std.mem.Allocator) LuaError!LuaState {
        const ud = try allocator.create(AllocatorUd);
        errdefer allocator.destroy(ud);
        ud.* = .{ .allocator = allocator };

        const L = c.lua_newstate(luaAlloc, ud) orelse return error.OutOfMemory;
        c.luaL_openlibs(L);
        return .{ .allocator = allocator, .ud = ud, .L = L };
    }

    pub fn deinit(self: *LuaState) void {
        c.lua_close(self.L);
        self.allocator.destroy(self.ud);
        self.* = undefined;
    }

    pub fn doString(self: *LuaState, src: []const u8, chunk_name: [:0]const u8) LuaError!void {
        const load_rc = c.luaL_loadbufferx(self.L, src.ptr, src.len, chunk_name.ptr, null);
        if (load_rc != c.LUA_OK) return mapLoadError(self.L, load_rc);
        const call_rc = c.lua_pcallk(self.L, 0, c.LUA_MULTRET, 0, 0, null);
        if (call_rc != c.LUA_OK) return mapCallError(self.L, call_rc);
    }

    pub fn loadChunk(self: *LuaState, src: []const u8, chunk_name: [:0]const u8) LuaError!void {
        const rc = c.luaL_loadbufferx(self.L, src.ptr, src.len, chunk_name.ptr, null);
        if (rc != c.LUA_OK) return mapLoadError(self.L, rc);
    }

    pub fn pushCClosureWithUserdata(
        self: *LuaState,
        func: c.lua_CFunction,
        ud: *anyopaque,
    ) void {
        c.lua_pushlightuserdata(self.L, ud);
        c.lua_pushcclosure(self.L, func, 1);
    }

    pub fn setPackagePath(self: *LuaState, dirs: []const []const u8) !void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        for (dirs) |d| {
            if (d.len == 0) continue;
            if (buf.items.len > 0) try buf.append(self.allocator, ';');
            try buf.writer(self.allocator).print("{s}/?.lua;{s}/?/init.lua", .{ d, d });
        }
        if (buf.items.len == 0) return;

        _ = c.lua_getglobal(self.L, "package");
        defer c.lua_pop(self.L, 1);
        if (c.lua_type(self.L, -1) != c.LUA_TTABLE) return;
        _ = c.lua_pushlstring(self.L, buf.items.ptr, buf.items.len);
        c.lua_setfield(self.L, -2, "path");
    }

    pub fn setPackagePathRaw(self: *LuaState, path: []const u8) void {
        _ = c.lua_getglobal(self.L, "package");
        defer c.lua_pop(self.L, 1);
        if (c.lua_type(self.L, -1) != c.LUA_TTABLE) return;
        _ = c.lua_pushlstring(self.L, path.ptr, path.len);
        c.lua_setfield(self.L, -2, "path");
    }
};

pub const ConvertError = error{
    OutOfMemory,
    UnsupportedLuaType,
    InvalidUtf8,
};

pub const LimitedConvertError = ConvertError || error{LimitExceeded};

pub const JsonConvertLimits = struct {
    max_depth: usize,
    max_items: usize,
    max_string_bytes: usize,
    max_total_string_bytes: usize,
};

pub const JsonConvertBudget = struct {
    limits: JsonConvertLimits,
    depth: usize = 0,
    items: usize = 0,
    total_string_bytes: usize = 0,
};

pub const default_json_convert_limits = JsonConvertLimits{
    .max_depth = limits.details_depth,
    .max_items = limits.details_items,
    .max_string_bytes = limits.details_string_bytes,
    .max_total_string_bytes = limits.details_total_string_bytes,
};

pub const presentation_json_convert_limits = JsonConvertLimits{
    .max_depth = limits.presentation_depth,
    .max_items = limits.presentation_items,
    .max_string_bytes = limits.presentation_string_bytes,
    .max_total_string_bytes = limits.presentation_total_string_bytes,
};

pub const JsonLossyStats = struct {
    truncated_strings: usize = 0,
    omitted_items: usize = 0,
    depth_limited: usize = 0,
    unsupported_values: usize = 0,

    pub fn any(self: JsonLossyStats) bool {
        return self.truncated_strings != 0 or
            self.omitted_items != 0 or
            self.depth_limited != 0 or
            self.unsupported_values != 0;
    }
};

const presentation_truncated_marker = "... [truncated by zi presentation boundary] ...";
const presentation_omitted_marker = "... [items omitted by zi presentation boundary] ...";
const presentation_depth_marker = "... [depth limit reached by zi presentation boundary] ...";

pub fn luaValueToJson(
    L: *c.lua_State,
    index: c_int,
    allocator: std.mem.Allocator,
) ConvertError!std.json.Value {
    const abs_idx: c_int = if (index < 0) c.lua_gettop(L) + index + 1 else index;

    return switch (c.lua_type(L, abs_idx)) {
        c.LUA_TNIL, c.LUA_TNONE => .null,
        c.LUA_TBOOLEAN => .{ .bool = c.lua_toboolean(L, abs_idx) != 0 },
        c.LUA_TNUMBER => blk: {
            if (c.lua_isinteger(L, abs_idx) != 0) {
                break :blk .{ .integer = c.lua_tointegerx(L, abs_idx, null) };
            }
            break :blk .{ .float = c.lua_tonumberx(L, abs_idx, null) };
        },
        c.LUA_TSTRING => blk: {
            var len: usize = 0;
            const ptr = c.lua_tolstring(L, abs_idx, &len) orelse return error.InvalidUtf8;
            const dup = try allocator.dupe(u8, ptr[0..len]);
            break :blk .{ .string = dup };
        },
        c.LUA_TTABLE => luaTableToJson(L, abs_idx, allocator),
        else => error.UnsupportedLuaType,
    };
}

pub fn luaValueToJsonLimited(
    L: *c.lua_State,
    index: c_int,
    allocator: std.mem.Allocator,
    budget: *JsonConvertBudget,
) LimitedConvertError!std.json.Value {
    const abs_idx: c_int = if (index < 0) c.lua_gettop(L) + index + 1 else index;

    return switch (c.lua_type(L, abs_idx)) {
        c.LUA_TNIL, c.LUA_TNONE => .null,
        c.LUA_TBOOLEAN => .{ .bool = c.lua_toboolean(L, abs_idx) != 0 },
        c.LUA_TNUMBER => blk: {
            if (c.lua_isinteger(L, abs_idx) != 0) {
                break :blk .{ .integer = c.lua_tointegerx(L, abs_idx, null) };
            }
            break :blk .{ .float = c.lua_tonumberx(L, abs_idx, null) };
        },
        c.LUA_TSTRING => blk: {
            var len: usize = 0;
            const ptr = c.lua_tolstring(L, abs_idx, &len) orelse return error.InvalidUtf8;
            if (len > budget.limits.max_string_bytes) return error.LimitExceeded;
            if (len > budget.limits.max_total_string_bytes or budget.total_string_bytes > budget.limits.max_total_string_bytes - len) return error.LimitExceeded;
            budget.total_string_bytes += len;
            const dup = try allocator.dupe(u8, ptr[0..len]);
            break :blk .{ .string = dup };
        },
        c.LUA_TTABLE => luaTableToJsonLimited(L, abs_idx, allocator, budget),
        else => error.UnsupportedLuaType,
    };
}

fn luaTableToJsonLimited(
    L: *c.lua_State,
    table_idx: c_int,
    allocator: std.mem.Allocator,
    budget: *JsonConvertBudget,
) LimitedConvertError!std.json.Value {
    if (budget.depth >= budget.limits.max_depth) return error.LimitExceeded;
    budget.depth += 1;
    defer budget.depth -= 1;

    const seq_len = c.lua_rawlen(L, table_idx);
    if (seq_len > 0 and isSequence(L, table_idx, seq_len)) {
        if (seq_len > budget.limits.max_items or budget.items > budget.limits.max_items - seq_len) return error.LimitExceeded;
        budget.items += seq_len;

        var arr = std.json.Array.init(allocator);
        errdefer freeJsonValue(allocator, .{ .array = arr });
        try arr.ensureTotalCapacity(seq_len);

        var i: c.lua_Integer = 1;
        while (@as(usize, @intCast(i)) <= seq_len) : (i += 1) {
            _ = c.lua_rawgeti(L, table_idx, i);
            const elem = luaValueToJsonLimited(L, -1, allocator, budget) catch |err| {
                c.lua_pop(L, 1);
                return err;
            };
            c.lua_pop(L, 1);
            try arr.append(elem);
        }
        return .{ .array = arr };
    }

    var obj: std.json.ObjectMap = .{};
    errdefer freeJsonValue(allocator, .{ .object = obj });

    c.lua_pushnil(L);
    while (c.lua_next(L, table_idx) != 0) {
        if (budget.items >= budget.limits.max_items) {
            c.lua_pop(L, 2);
            return error.LimitExceeded;
        }
        budget.items += 1;

        var key_buf: [64]u8 = undefined;
        const key_str: []const u8 = switch (c.lua_type(L, -2)) {
            c.LUA_TSTRING => blk: {
                var len: usize = 0;
                const ptr = c.lua_tolstring(L, -2, &len) orelse {
                    c.lua_pop(L, 2);
                    return error.InvalidUtf8;
                };
                break :blk ptr[0..len];
            },
            c.LUA_TNUMBER => blk: {
                if (c.lua_isinteger(L, -2) != 0) {
                    const n = c.lua_tointegerx(L, -2, null);
                    break :blk std.fmt.bufPrint(&key_buf, "{d}", .{n}) catch {
                        c.lua_pop(L, 2);
                        return error.OutOfMemory;
                    };
                }
                const f = c.lua_tonumberx(L, -2, null);
                break :blk std.fmt.bufPrint(&key_buf, "{d}", .{f}) catch {
                    c.lua_pop(L, 2);
                    return error.OutOfMemory;
                };
            },
            else => {
                c.lua_pop(L, 2);
                return error.UnsupportedLuaType;
            },
        };

        const key_dup = allocator.dupe(u8, key_str) catch |err| {
            c.lua_pop(L, 2);
            return err;
        };

        const value = luaValueToJsonLimited(L, -1, allocator, budget) catch |err| {
            allocator.free(key_dup);
            c.lua_pop(L, 2);
            return err;
        };
        obj.put(allocator, key_dup, value) catch |err| {
            allocator.free(key_dup);
            freeJsonValue(allocator, value);
            c.lua_pop(L, 2);
            return err;
        };
        c.lua_pop(L, 1);
    }

    return .{ .object = obj };
}

pub fn luaValueToPresentationJson(
    L: *c.lua_State,
    index: c_int,
    allocator: std.mem.Allocator,
    limits_: JsonConvertLimits,
) ConvertError!std.json.Value {
    var budget = JsonConvertBudget{ .limits = limits_ };
    var stats = JsonLossyStats{};
    var value = try luaValueToPresentationJsonInner(L, index, allocator, &budget, &stats);
    errdefer freeJsonValue(allocator, value);
    if (stats.any()) try annotatePresentationRoot(allocator, &value, stats);
    return value;
}

fn luaValueToPresentationJsonInner(
    L: *c.lua_State,
    index: c_int,
    allocator: std.mem.Allocator,
    budget: *JsonConvertBudget,
    stats: *JsonLossyStats,
) ConvertError!std.json.Value {
    const abs_idx: c_int = if (index < 0) c.lua_gettop(L) + index + 1 else index;
    return switch (c.lua_type(L, abs_idx)) {
        c.LUA_TNIL, c.LUA_TNONE => .null,
        c.LUA_TBOOLEAN => .{ .bool = c.lua_toboolean(L, abs_idx) != 0 },
        c.LUA_TNUMBER => blk: {
            if (c.lua_isinteger(L, abs_idx) != 0) break :blk .{ .integer = c.lua_tointegerx(L, abs_idx, null) };
            break :blk .{ .float = c.lua_tonumberx(L, abs_idx, null) };
        },
        c.LUA_TSTRING => luaStringToPresentationJson(L, abs_idx, allocator, budget, stats),
        c.LUA_TTABLE => luaTableToPresentationJson(L, abs_idx, allocator, budget, stats),
        else => blk: {
            stats.unsupported_values += 1;
            break :blk .null;
        },
    };
}

fn luaStringToPresentationJson(
    L: *c.lua_State,
    abs_idx: c_int,
    allocator: std.mem.Allocator,
    budget: *JsonConvertBudget,
    stats: *JsonLossyStats,
) ConvertError!std.json.Value {
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, abs_idx, &len) orelse return error.InvalidUtf8;
    const src = ptr[0..len];
    if (budget.total_string_bytes >= budget.limits.max_total_string_bytes) {
        stats.truncated_strings += 1;
        return .{ .string = try allocator.dupe(u8, presentation_truncated_marker) };
    }
    const allowed = @min(budget.limits.max_string_bytes, budget.limits.max_total_string_bytes - budget.total_string_bytes);
    if (src.len <= allowed) {
        budget.total_string_bytes += src.len;
        return .{ .string = try allocator.dupe(u8, src) };
    }
    stats.truncated_strings += 1;
    const marker_len = @min(presentation_truncated_marker.len, allowed);
    const prefix_len = allowed - marker_len;
    const out = try allocator.alloc(u8, allowed);
    @memcpy(out[0..prefix_len], src[0..prefix_len]);
    @memcpy(out[prefix_len..], presentation_truncated_marker[0..marker_len]);
    budget.total_string_bytes += out.len;
    return .{ .string = out };
}

fn luaTableToPresentationJson(
    L: *c.lua_State,
    table_idx: c_int,
    allocator: std.mem.Allocator,
    budget: *JsonConvertBudget,
    stats: *JsonLossyStats,
) ConvertError!std.json.Value {
    if (budget.depth >= budget.limits.max_depth) {
        stats.depth_limited += 1;
        return .{ .string = try allocator.dupe(u8, presentation_depth_marker) };
    }
    budget.depth += 1;
    defer budget.depth -= 1;

    const seq_len = c.lua_rawlen(L, table_idx);
    if (seq_len > 0 and isSequence(L, table_idx, seq_len)) {
        var arr = std.json.Array.init(allocator);
        errdefer freeJsonValue(allocator, .{ .array = arr });
        var i: c.lua_Integer = 1;
        while (@as(usize, @intCast(i)) <= seq_len) : (i += 1) {
            if (budget.items >= budget.limits.max_items) {
                stats.omitted_items += seq_len - @as(usize, @intCast(i)) + 1;
                try arr.append(.{ .string = try allocator.dupe(u8, presentation_omitted_marker) });
                break;
            }
            budget.items += 1;
            _ = c.lua_rawgeti(L, table_idx, i);
            const elem = luaValueToPresentationJsonInner(L, -1, allocator, budget, stats) catch |err| {
                c.lua_pop(L, 1);
                return err;
            };
            c.lua_pop(L, 1);
            try arr.append(elem);
        }
        return .{ .array = arr };
    }

    var obj: std.json.ObjectMap = .{};
    errdefer freeJsonValue(allocator, .{ .object = obj });
    c.lua_pushnil(L);
    while (c.lua_next(L, table_idx) != 0) {
        if (budget.items >= budget.limits.max_items) {
            stats.omitted_items += 1;
            c.lua_pop(L, 1);
            continue;
        }
        budget.items += 1;

        var key_buf: [64]u8 = undefined;
        const key_str: []const u8 = switch (c.lua_type(L, -2)) {
            c.LUA_TSTRING => blk: {
                var len: usize = 0;
                const ptr = c.lua_tolstring(L, -2, &len) orelse {
                    c.lua_pop(L, 2);
                    return error.InvalidUtf8;
                };
                break :blk ptr[0..len];
            },
            c.LUA_TNUMBER => blk: {
                if (c.lua_isinteger(L, -2) != 0) break :blk std.fmt.bufPrint(&key_buf, "{d}", .{c.lua_tointegerx(L, -2, null)}) catch {
                    c.lua_pop(L, 2);
                    return error.OutOfMemory;
                };
                break :blk std.fmt.bufPrint(&key_buf, "{d}", .{c.lua_tonumberx(L, -2, null)}) catch {
                    c.lua_pop(L, 2);
                    return error.OutOfMemory;
                };
            },
            else => {
                stats.unsupported_values += 1;
                c.lua_pop(L, 1);
                continue;
            },
        };
        const key_dup = try allocator.dupe(u8, key_str);
        const value = luaValueToPresentationJsonInner(L, -1, allocator, budget, stats) catch |err| {
            allocator.free(key_dup);
            c.lua_pop(L, 2);
            return err;
        };
        obj.put(allocator, key_dup, value) catch |err| {
            allocator.free(key_dup);
            freeJsonValue(allocator, value);
            c.lua_pop(L, 2);
            return err;
        };
        c.lua_pop(L, 1);
    }
    return .{ .object = obj };
}

fn annotatePresentationRoot(allocator: std.mem.Allocator, value: *std.json.Value, stats: JsonLossyStats) !void {
    if (value.* != .object) return;
    var obj = &value.object;
    if (!obj.contains("__zi_truncated")) {
        try obj.put(allocator, try allocator.dupe(u8, "__zi_truncated"), .{ .bool = true });
    }
    if (stats.omitted_items > 0 and !obj.contains("__zi_omitted")) {
        try obj.put(allocator, try allocator.dupe(u8, "__zi_omitted"), .{ .integer = @intCast(stats.omitted_items) });
    }
}

fn luaTableToJson(
    L: *c.lua_State,
    table_idx: c_int,
    allocator: std.mem.Allocator,
) ConvertError!std.json.Value {
    const seq_len = c.lua_rawlen(L, table_idx);
    if (seq_len > 0 and isSequence(L, table_idx, seq_len)) {
        var arr = std.json.Array.init(allocator);
        errdefer freeJsonValue(allocator, .{ .array = arr });
        try arr.ensureTotalCapacity(seq_len);

        var i: c.lua_Integer = 1;
        while (@as(usize, @intCast(i)) <= seq_len) : (i += 1) {
            _ = c.lua_rawgeti(L, table_idx, i);
            const elem = try luaValueToJson(L, -1, allocator);
            c.lua_pop(L, 1);
            try arr.append(elem);
        }
        return .{ .array = arr };
    }

    var obj: std.json.ObjectMap = .{};
    errdefer freeJsonValue(allocator, .{ .object = obj });

    c.lua_pushnil(L);
    while (c.lua_next(L, table_idx) != 0) {
        var key_buf: [64]u8 = undefined;
        const key_str: []const u8 = switch (c.lua_type(L, -2)) {
            c.LUA_TSTRING => blk: {
                var len: usize = 0;
                const ptr = c.lua_tolstring(L, -2, &len) orelse return error.InvalidUtf8;
                break :blk ptr[0..len];
            },
            c.LUA_TNUMBER => blk: {
                if (c.lua_isinteger(L, -2) != 0) {
                    const n = c.lua_tointegerx(L, -2, null);
                    break :blk std.fmt.bufPrint(&key_buf, "{d}", .{n}) catch return error.OutOfMemory;
                }
                const f = c.lua_tonumberx(L, -2, null);
                break :blk std.fmt.bufPrint(&key_buf, "{d}", .{f}) catch return error.OutOfMemory;
            },
            else => return error.UnsupportedLuaType,
        };

        const key_dup = try allocator.dupe(u8, key_str);
        errdefer allocator.free(key_dup);

        const value = try luaValueToJson(L, -1, allocator);
        try obj.put(allocator, key_dup, value);

        c.lua_pop(L, 1);
    }

    return .{ .object = obj };
}

fn isSequence(L: *c.lua_State, table_idx: c_int, expected_len: usize) bool {
    var i: c.lua_Integer = 1;
    while (@as(usize, @intCast(i)) <= expected_len) : (i += 1) {
        const t = c.lua_rawgeti(L, table_idx, i);
        c.lua_pop(L, 1);
        if (t == c.LUA_TNIL) return false;
    }
    return true;
}

pub fn pushJsonValue(L: *c.lua_State, value: std.json.Value) ConvertError!void {
    switch (value) {
        .null => c.lua_pushnil(L),
        .bool => |b| c.lua_pushboolean(L, if (b) 1 else 0),
        .integer => |i| c.lua_pushinteger(L, i),
        .float => |f| c.lua_pushnumber(L, f),
        .number_string => |s| {
            _ = c.lua_pushlstring(L, s.ptr, s.len);
        },
        .string => |s| {
            _ = c.lua_pushlstring(L, s.ptr, s.len);
        },
        .array => |arr| {
            c.lua_createtable(L, @intCast(arr.items.len), 0);
            for (arr.items, 0..) |item, i| {
                try pushJsonValue(L, item);
                c.lua_rawseti(L, -2, @intCast(i + 1));
            }
        },
        .object => |obj| {
            c.lua_createtable(L, 0, @intCast(obj.count()));
            var it = obj.iterator();
            while (it.next()) |kv| {
                try pushJsonValue(L, kv.value_ptr.*);
                _ = c.lua_pushlstring(L, kv.key_ptr.*.ptr, kv.key_ptr.*.len);
                c.lua_insert(L, -2);
                c.lua_settable(L, -3);
            }
        },
    }
}

pub const freeJsonValue = @import("../../json/value.zig").freeJsonValue;

pub const Coroutine = struct {
    parent: *LuaState,

    ref: c_int,

    L: *c.lua_State,

    pub fn init(parent: *LuaState) LuaError!Coroutine {
        return initFrom(parent, parent.L);
    }

    pub fn initFrom(parent: *LuaState, from_L: *c.lua_State) LuaError!Coroutine {
        const L = c.lua_newthread(from_L) orelse return error.OutOfMemory;
        const ref = c.luaL_ref(from_L, c.LUA_REGISTRYINDEX);
        if (ref == c.LUA_REFNIL or ref == c.LUA_NOREF) return error.InvalidCoroutineState;
        return .{ .parent = parent, .ref = ref, .L = L };
    }

    pub fn deinit(self: *Coroutine) void {
        c.luaL_unref(self.parent.L, c.LUA_REGISTRYINDEX, self.ref);
        self.* = undefined;
    }

    pub const Status = enum { ok, yielded, finished };

    pub fn resumeWith(self: *Coroutine, nargs: c_int) LuaError!struct {
        status: Status,
        nresults: c_int,
    } {
        var nresults: c_int = 0;
        const rc = c.lua_resume(self.L, null, nargs, &nresults);
        return switch (rc) {
            c.LUA_OK => .{ .status = .finished, .nresults = nresults },
            c.LUA_YIELD => .{ .status = .yielded, .nresults = nresults },
            c.LUA_ERRRUN => mapError(self.L, error.LuaRuntime),
            c.LUA_ERRMEM => error.LuaMemory,
            c.LUA_ERRERR => error.LuaError,
            else => error.LuaError,
        };
    }
};

pub fn mapLoadError(L: *c.lua_State, rc: c_int) LuaError {
    consumeErrorMessage(L);
    return switch (rc) {
        c.LUA_ERRSYNTAX => error.LuaSyntax,
        c.LUA_ERRMEM => error.LuaMemory,
        else => error.LuaError,
    };
}

pub fn mapCallError(L: *c.lua_State, rc: c_int) LuaError {
    consumeErrorMessage(L);
    return switch (rc) {
        c.LUA_ERRRUN => error.LuaRuntime,
        c.LUA_ERRMEM => error.LuaMemory,
        c.LUA_ERRERR => error.LuaError,
        else => error.LuaError,
    };
}

fn mapError(L: *c.lua_State, err: LuaError) LuaError {
    consumeErrorMessage(L);
    return err;
}

fn consumeErrorMessage(L: *c.lua_State) void {
    if (c.lua_gettop(L) > 0) c.lua_pop(L, 1);
}

test "luaValueToJsonLimited enforces depth item and string budgets" {
    var state = try LuaState.init(std.testing.allocator);
    defer state.deinit();

    try state.doString(
        \\deep = { a = { b = { c = 1 } } }
        \\wide = { 1, 2, 3 }
        \\huge = string.rep('x', 9)
    , "limited_json_values");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    _ = c.lua_getglobal(state.L, "deep");
    var depth_budget = JsonConvertBudget{ .limits = .{
        .max_depth = 2,
        .max_items = 10,
        .max_string_bytes = 16,
        .max_total_string_bytes = 64,
    } };
    try std.testing.expectError(error.LimitExceeded, luaValueToJsonLimited(state.L, -1, arena.allocator(), &depth_budget));
    c.lua_pop(state.L, 1);

    _ = c.lua_getglobal(state.L, "wide");
    var item_budget = JsonConvertBudget{ .limits = .{
        .max_depth = 8,
        .max_items = 2,
        .max_string_bytes = 16,
        .max_total_string_bytes = 64,
    } };
    try std.testing.expectError(error.LimitExceeded, luaValueToJsonLimited(state.L, -1, arena.allocator(), &item_budget));
    c.lua_pop(state.L, 1);

    _ = c.lua_getglobal(state.L, "huge");
    var string_budget = JsonConvertBudget{ .limits = .{
        .max_depth = 8,
        .max_items = 10,
        .max_string_bytes = 8,
        .max_total_string_bytes = 64,
    } };
    try std.testing.expectError(error.LimitExceeded, luaValueToJsonLimited(state.L, -1, arena.allocator(), &string_budget));
    c.lua_pop(state.L, 1);
}

test "LuaState computes 42 = 40 + 2 in a coroutine" {
    var state = try LuaState.init(std.testing.allocator);
    defer state.deinit();

    try state.doString("function add(a, b) return a + b end", "test");

    var co = try Coroutine.init(&state);
    defer co.deinit();

    _ = c.lua_getglobal(co.L, "add");
    c.lua_pushinteger(co.L, 40);
    c.lua_pushinteger(co.L, 2);

    const r = try co.resumeWith(2);
    try std.testing.expectEqual(Coroutine.Status.finished, r.status);
    try std.testing.expectEqual(@as(c_int, 1), r.nresults);
    try std.testing.expectEqual(@as(c.lua_Integer, 42), c.lua_tointegerx(co.L, -1, null));
}

fn yieldOneContinue(L: ?*c.lua_State, status: c_int, ctx: c.lua_KContext) callconv(.c) c_int {
    _ = status;
    _ = ctx;
    _ = L;
    return 1;
}

fn yieldOne(L: ?*c.lua_State) callconv(.c) c_int {
    return c.lua_yieldk(L, 0, 0, yieldOneContinue);
}

test "Coroutine suspends via lua_yieldk and resumes with a value" {
    var state = try LuaState.init(std.testing.allocator);
    defer state.deinit();

    c.lua_pushcfunction(state.L, yieldOne);
    c.lua_setglobal(state.L, "yield_one");

    try state.doString(
        \\function run()
        \\  local v = yield_one()
        \\  return v * 10
        \\end
    , "test");

    var co = try Coroutine.init(&state);
    defer co.deinit();

    _ = c.lua_getglobal(co.L, "run");
    const first = try co.resumeWith(0);
    try std.testing.expectEqual(Coroutine.Status.yielded, first.status);

    c.lua_pushinteger(co.L, 7);
    const second = try co.resumeWith(1);
    try std.testing.expectEqual(Coroutine.Status.finished, second.status);
    try std.testing.expectEqual(@as(c_int, 1), second.nresults);
    try std.testing.expectEqual(@as(c.lua_Integer, 70), c.lua_tointegerx(co.L, -1, null));
}
