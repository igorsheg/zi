//! Lua 5.4 runtime wrapper — owned by ExtensionRunner.
//!
//! This module is the SOLE bridge between zig and `lua_State *`. Higher
//! layers (loader, registries, hook dispatch) must go through `LuaState`
//! and never touch the C API directly. Doing so keeps lifetime, error
//! normalization, and the coroutine c-call discipline in one place.
//!
//! Scope (Phase B2):
//!   - allocate / close `lua_State` with a zig-backed allocator
//!   - open the standard libraries
//!   - create coroutines (`lua_newthread`) and pin them via the registry
//!   - resume / yield plumbing using `lua_resume` + `lua_yieldk`
//!   - error normalization helpers
//!
//! Out of scope here (Phase D and beyond):
//!   - the `zi.*` host API table
//!   - tool / event / command registries
//!   - the actual yieldable host functions (`zi.spawn`, `ctx.ui.*`)
//!
//! Coroutine c-call discipline (see `docs/extensions.md`): every tool
//! execution and event handler runs in a
//! dedicated coroutine. The infrastructure below assumes the same and
//! never calls `lua_pcall` on a function that may yield. Yieldable host
//! functions MUST use `lua_yieldk` with a continuation, otherwise Lua
//! raises "attempt to yield across C-call boundary" at runtime.

const std = @import("std");
const limits = @import("limits.zig");

pub const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lauxlib.h");
    @cInclude("lualib.h");
});

/// Header prepended to every block so we can recover the original size on
/// free / realloc. Lua's `lua_Alloc` contract gives us `osize` only when
/// `ptr != NULL`; we still need an aligned block, so we over-allocate by
/// `header_align` bytes and stash the size in the slot immediately before
/// the user pointer.
const header_align: usize = @alignOf(usize) * 2;
const header_alignment: std.mem.Alignment = .fromByteUnits(header_align);

const BlockHeader = extern struct {
    size: usize,
    _pad: usize = 0, // keep payload aligned to header_align
};

/// Userdata passed to `lua_newstate`. We need a stable pointer to the
/// allocator across the Lua state's lifetime; `LuaState` stores it inline
/// and hands its address to `lua_newstate`.
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
        // `osize` carries a type tag when ptr is NULL, so we ignore
        // it on the alloc path. When ptr != NULL the Lua manual says
        // osize equals the previously requested user size — we trust the
        // header instead, which avoids any drift.
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

/// Owned wrapper around `lua_State *`. Created with a zig allocator so the
/// runner controls all Lua memory and can audit it via the same gpa as the
/// rest of the agent.
///
/// One `LuaState` per `ExtensionRunner` generation. Closing the state
/// releases EVERYTHING: registries, refs, compiled chunks, coroutines.
/// The runner is responsible for ordering `deinit` so any zig-side state
/// that points into Lua memory is dropped first.
pub const LuaState = struct {
    allocator: std.mem.Allocator,
    /// Heap-allocated so its address survives `LuaState` moves. The Lua
    /// state stores this pointer as the alloc userdata for its entire
    /// lifetime; if it dangled we'd corrupt every allocation.
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

    /// Compile + execute a chunk in the main thread. Use only for top-
    /// level extension loading or simple, non-yielding tests. Anything
    /// that may yield (`zi.spawn`, ui calls) MUST go through a coroutine.
    pub fn doString(self: *LuaState, src: []const u8, chunk_name: [:0]const u8) LuaError!void {
        const load_rc = c.luaL_loadbufferx(self.L, src.ptr, src.len, chunk_name.ptr, null);
        if (load_rc != c.LUA_OK) return mapLoadError(self.L, load_rc);
        const call_rc = c.lua_pcallk(self.L, 0, c.LUA_MULTRET, 0, 0, null);
        if (call_rc != c.LUA_OK) return mapCallError(self.L, call_rc);
    }

    /// Compile a chunk and leave the resulting function on the top of
    /// the stack. The caller decides what to do with it (call now,
    /// store via `luaL_ref`, etc.). Used by the extension loader to
    /// capture factories without invoking them, so the loader can
    /// hand a fresh `zi` table to each one.
    pub fn loadChunk(self: *LuaState, src: []const u8, chunk_name: [:0]const u8) LuaError!void {
        const rc = c.luaL_loadbufferx(self.L, src.ptr, src.len, chunk_name.ptr, null);
        if (rc != c.LUA_OK) return mapLoadError(self.L, rc);
    }

    /// Push a C function as a closure with one upvalue (a light
    /// userdata pointer). The C function reads the pointer back via
    /// `lua_upvalueindex(1)`. This is the canonical way to give a
    /// stateless C function access to per-state context (in our case
    /// the `ExtensionRunner` it should mutate).
    ///
    /// The closure is left on top of the stack — caller stores it
    /// wherever they want (global, table field, etc.).
    pub fn pushCClosureWithUserdata(
        self: *LuaState,
        func: c.lua_CFunction,
        ud: *anyopaque,
    ) void {
        c.lua_pushlightuserdata(self.L, ud);
        c.lua_pushcclosure(self.L, func, 1);
    }

    /// Configure Lua's `package.path` from explicit module roots.
    ///
    /// Builds the canonical `<dir>/?.lua;<dir>/?/init.lua` pair for
    /// each search directory. Empty string entries are skipped.
    /// Silently tolerates allocation failure (package.path stays at
    /// the Lua default — extensions that use `require` will just
    /// fail to find modules, which is caught by the loader's
    /// per-extension error handling).
    ///
    /// The extension system follows a Neovim-style runtime layout:
    /// bundled extensions put private modules under
    /// `extensions/<id>/lua/`, and runtime roots can expose shared
    /// modules under `<root>/lua/`. A bundled extension can require
    /// `my_ext.render` from `extensions/my-ext/lua/my_ext/render.lua`.
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

    /// Set `package.path` to an already-built string. Used by
    /// `ExtensionRunner.setModuleContext` when it has composed the
    /// full private + shared + default path externally.
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

/// Read a Lua-stack value at the given (absolute or negative) index
/// and produce an owned `std.json.Value`. Recursively walks tables.
///
/// Ownership: every string and every nested map/array is allocated
/// from `allocator`. The returned value is COMPLETELY independent of
/// the Lua state — the caller can collect it after the Lua stack
/// unwinds, GCs, or the whole `lua_close` happens. This is the spec's
/// §Ownership-and-Reload invariant: "Zig never stores pointers into
/// Lua-managed memory."
///
/// Table ↔ JSON shape rule: a Lua table whose keys are exactly
/// `1..#t` (a "sequence" in Lua parlance) becomes a JSON array.
/// Anything else becomes an object with stringified keys. The
/// detection uses `lua_rawlen` for the length and a single pass over
/// the keys via `lua_next`. Mixed-shape tables (sparse arrays, or
/// arrays with extra string keys) collapse to objects — JSON has no
/// mixed shape, and this matches how pi-mono's TypeBox-driven
/// schemas serialize today.
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
        c.lua_pop(L, 1); // pop value, keep key for lua_next
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
        // Stringify the key without coercing it on the actual stack
        // (lua_tostring on a non-string key would mutate it and break
        // lua_next's invariant). Use a sidecar push.
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

        c.lua_pop(L, 1); // pop value, keep key for next iteration
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

/// Push a `std.json.Value` onto the Lua stack as the equivalent
/// Lua type. The inverse of `luaValueToJson` — used by the event
/// bridge to convert agent-side payloads (which carry
/// `std.json.Value` for tool args, message content, etc.) into Lua
/// tables that handlers can read.
///
/// Ownership: the pushed Lua values are independent copies. Strings
/// are duplicated by Lua's own allocator (`lua_pushlstring` copies);
/// nested tables are constructed inline. Caller may free the source
/// `std.json.Value` immediately after the call returns.
///
/// On allocator failure (Lua's internal allocator is wired to the
/// runner's gpa via `LuaState.init`), this returns
/// `error.OutOfMemory` and the partial state is left on the stack
/// for the caller to clean up via `lua_settop`.
pub fn pushJsonValue(L: *c.lua_State, value: std.json.Value) ConvertError!void {
    switch (value) {
        .null => c.lua_pushnil(L),
        .bool => |b| c.lua_pushboolean(L, if (b) 1 else 0),
        .integer => |i| c.lua_pushinteger(L, i),
        .float => |f| c.lua_pushnumber(L, f),
        .number_string => |s| {
            // JSON's "number_string" only appears for numbers that
            // overflow i64. Pass them through as Lua strings; the
            // handler can re-parse if it cares.
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
                // lua_setfield needs a null-terminated key. Object
                // keys come from `luaValueToJson`'s allocator (or
                // a JSON parse) and aren't guaranteed sentinel-
                // terminated, so we use lua_pushlstring + lua_settable.
                _ = c.lua_pushlstring(L, kv.key_ptr.*.ptr, kv.key_ptr.*.len);
                c.lua_insert(L, -2);
                c.lua_settable(L, -3);
            }
        },
    }
}

/// Free a `std.json.Value` previously produced by `luaValueToJson`.
/// Re-exported from `src/json/value.zig` — the extensions package
/// can safely depend on the generic json module (no upward deps).
/// Consumers historically imported this from `lua_runtime`; the
/// re-export preserves their call sites.
pub const freeJsonValue = @import("../../json/value.zig").freeJsonValue;

/// A Lua thread (coroutine) pinned via the registry so the GC can't reap
/// it while zig still needs to resume it. Tied to a parent `LuaState`;
/// the parent owns the underlying memory and the registry slot.
pub const Coroutine = struct {
    parent: *LuaState,
    /// Registry reference (`LUA_REGISTRYINDEX` slot) keeping the thread
    /// rooted. Released by `deinit` via `luaL_unref`.
    ref: c_int,
    /// The coroutine's `lua_State *`. Borrowed from `parent`; do not
    /// `lua_close` it directly.
    L: *c.lua_State,

    /// Create a fresh coroutine with no body on its stack. Caller is
    /// expected to push a function (and any initial args) before the
    /// first `resume`.
    pub fn init(parent: *LuaState) LuaError!Coroutine {
        return initFrom(parent, parent.L);
    }

    /// Like `init`, but allocates the new thread off `from_L` instead
    /// of `parent.L`. Use this when you're called from inside a host
    /// C function that's running on a coroutine — Lua API calls must
    /// happen on the *currently executing* thread, not on the main
    /// state, otherwise `lua_newthread` pushes onto a non-current
    /// stack and the next `lua_resume` corrupts state.
    ///
    /// `parent` is still kept around so `deinit` has a known-alive
    /// state to call `luaL_unref` on (the registry is global to the
    /// shared global_State, so any thread works).
    pub fn initFrom(parent: *LuaState, from_L: *c.lua_State) LuaError!Coroutine {
        const L = c.lua_newthread(from_L) orelse return error.OutOfMemory;
        // The new thread sits on top of `from_L`'s stack. Pop it into
        // the registry so it stays alive across `resume` calls.
        const ref = c.luaL_ref(from_L, c.LUA_REGISTRYINDEX);
        if (ref == c.LUA_REFNIL or ref == c.LUA_NOREF) return error.InvalidCoroutineState;
        return .{ .parent = parent, .ref = ref, .L = L };
    }

    pub fn deinit(self: *Coroutine) void {
        c.luaL_unref(self.parent.L, c.LUA_REGISTRYINDEX, self.ref);
        self.* = undefined;
    }

    pub const Status = enum { ok, yielded, finished };

    /// Resume the coroutine with `nargs` already pushed onto its stack.
    /// On `yielded`, the values yielded by Lua remain on the coroutine
    /// stack and `nresults` reports how many. On `ok`/`finished`, the
    /// final return values are on the stack.
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

/// Pop and discard the error message Lua leaves on the stack after a
/// failed `lua_pcallk` / `lua_resume`. Higher layers will eventually
/// capture this string into a structured tool result; for now we just
/// keep the stack clean so subsequent operations behave.
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
