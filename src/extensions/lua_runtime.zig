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
//! Coroutine c-call discipline (see docs/extensions.md §Lua Coroutine
//! C-Call Model): every tool execution and event handler runs in a
//! dedicated coroutine. The infrastructure below assumes the same and
//! never calls `lua_pcall` on a function that may yield. Yieldable host
//! functions MUST use `lua_yieldk` with a continuation, otherwise Lua
//! raises "attempt to yield across C-call boundary" at runtime.

const std = @import("std");

pub const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lauxlib.h");
    @cInclude("lualib.h");
});

// =============================================================================
// Allocator bridge
// =============================================================================

/// Header prepended to every block so we can recover the original size on
/// free / realloc. Lua's `lua_Alloc` contract gives us `osize` only when
/// `ptr != NULL`; we still need an aligned block, so we over-allocate by
/// `header_align` bytes and stash the size in the slot immediately before
/// the user pointer.
const header_align: usize = @alignOf(usize) * 2; // 16 on 64-bit, 8 on 32-bit
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

    // Recover the previous block (if any) so we can free or copy it.
    const old_total: usize = if (ptr != null) blk: {
        const user_ptr: [*]u8 = @ptrCast(ptr.?);
        const header_ptr: *BlockHeader = @ptrCast(@alignCast(user_ptr - @sizeOf(BlockHeader)));
        break :blk header_ptr.size;
        // NB: `osize` carries a type tag when ptr is NULL, so we ignore
        // it on the alloc path. When ptr != NULL the Lua manual says
        // osize equals the previously requested user size — we trust the
        // header instead, which avoids any drift.
    } else 0;
    _ = osize;

    // Free path.
    if (nsize == 0) {
        if (ptr == null) return null;
        const user_ptr: [*]u8 = @ptrCast(ptr.?);
        const base = user_ptr - @sizeOf(BlockHeader);
        const total = @sizeOf(BlockHeader) + old_total;
        const slice = base[0..total];
        allocator.rawFree(slice, header_alignment, @returnAddress());
        return null;
    }

    // Alloc / realloc path.
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

// =============================================================================
// LuaState
// =============================================================================

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

    /// Configure Lua's `package.path` so extensions can
    /// `require("lib/foo")` relative to their extension dir.
    ///
    /// Builds the canonical `<dir>/?.lua;<dir>/?/init.lua` pair for
    /// each search directory. Empty string entries are skipped.
    /// Silently tolerates allocation failure (package.path stays at
    /// the Lua default — extensions that use `require` will just
    /// fail to find modules, which is caught by the loader's
    /// per-extension error handling).
    ///
    /// Why not use the agent dir's `lib/` directly: matching
    /// pi-mono's convention, each extension is self-contained and
    /// its `lib/` is a subdirectory of the extension dir. A tool
    /// in `.zi/extensions/task.lua` can `require("lib/render")`
    /// and Lua resolves that to `.zi/extensions/lib/render.lua`.
    pub fn setPackagePath(self: *LuaState, dirs: []const []const u8) !void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        for (dirs) |d| {
            if (d.len == 0) continue;
            if (buf.items.len > 0) try buf.append(self.allocator, ';');
            try buf.writer(self.allocator).print("{s}/?.lua;{s}/?/init.lua", .{ d, d });
        }
        if (buf.items.len == 0) return;

        // package.path = <buf>
        _ = c.lua_getglobal(self.L, "package");
        defer c.lua_pop(self.L, 1);
        if (c.lua_type(self.L, -1) != c.LUA_TTABLE) return;
        _ = c.lua_pushlstring(self.L, buf.items.ptr, buf.items.len);
        c.lua_setfield(self.L, -2, "path");
    }
};

// =============================================================================
// Lua → zig value extraction
// =============================================================================

pub const ConvertError = error{
    OutOfMemory,
    UnsupportedLuaType,
    InvalidUtf8,
};

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
    // Normalize negative indices once so recursive calls don't drift
    // when they push intermediate values onto the stack.
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
        // Functions, userdata, threads — none are JSON-representable.
        // Caller should special-case execute=function before reaching
        // here (it gets stored as a luaL_ref, not a value).
        else => error.UnsupportedLuaType,
    };
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

    var obj = std.json.ObjectMap.init(allocator);
    errdefer freeJsonValue(allocator, .{ .object = obj });

    // Iterate via lua_next: push nil, then each call replaces the key
    // with key+value. We pop the value after extracting, leaving the
    // key for the next iteration.
    c.lua_pushnil(L);
    while (c.lua_next(L, table_idx) != 0) {
        // Stack now: ... key value
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
        try obj.put(key_dup, value);

        c.lua_pop(L, 1); // pop value, keep key for next iteration
    }

    return .{ .object = obj };
}

fn isSequence(L: *c.lua_State, table_idx: c_int, expected_len: usize) bool {
    // A Lua "sequence" has exactly the integer keys 1..n with no
    // gaps. We confirm by counting how many integer keys in 1..n
    // exist. Cheaper than walking every key for the common case.
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
                // Lua arrays are 1-indexed.
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
                // Stack: ... table value key
                // We need: table key value, then settable
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
pub const freeJsonValue = @import("../json/value.zig").freeJsonValue;

// =============================================================================
// Coroutines
// =============================================================================

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

// =============================================================================
// Error helpers
// =============================================================================

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

// =============================================================================
// Tests
// =============================================================================

test "LuaState computes 42 = 40 + 2 in a coroutine" {
    var state = try LuaState.init(std.testing.allocator);
    defer state.deinit();

    // Define a global function `add` so the coroutine has something to call.
    try state.doString("function add(a, b) return a + b end", "test");

    var co = try Coroutine.init(&state);
    defer co.deinit();

    // Push the function and its two arguments onto the coroutine's stack,
    // not the parent's. Lua looks up `add` from the shared globals table.
    _ = c.lua_getglobal(co.L, "add");
    c.lua_pushinteger(co.L, 40);
    c.lua_pushinteger(co.L, 2);

    const r = try co.resumeWith(2);
    try std.testing.expectEqual(Coroutine.Status.finished, r.status);
    try std.testing.expectEqual(@as(c_int, 1), r.nresults);
    try std.testing.expectEqual(@as(c.lua_Integer, 42), c.lua_tointegerx(co.L, -1, null));
}

// --- yield-with-continuation smoke test ----------------------------------
//
// We register a tiny C host function `yield_one` that uses `lua_yieldk`
// with a continuation. The continuation reads the value zig pushes on
// resume and returns it as the function's result. This proves the
// `lua_yieldk` plumbing actually suspends across the C boundary and
// surfaces zig-supplied values back to Lua, which is the exact pattern
// real `zi.spawn` and `ctx.ui.*` host functions will use in Phase D.

fn yieldOneContinue(L: ?*c.lua_State, status: c_int, ctx: c.lua_KContext) callconv(.c) c_int {
    _ = status;
    _ = ctx;
    // Whatever zig passes to `lua_resume` is on top of L's stack now.
    // Return it as `yield_one`'s single result.
    _ = L;
    return 1;
}

fn yieldOne(L: ?*c.lua_State) callconv(.c) c_int {
    // Yield zero values; we expect to be resumed with exactly one.
    return c.lua_yieldk(L, 0, 0, yieldOneContinue);
}

test "Coroutine suspends via lua_yieldk and resumes with a value" {
    var state = try LuaState.init(std.testing.allocator);
    defer state.deinit();

    // Expose `yield_one` as a global so the coroutine body can call it.
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

    // Push the value the continuation will hand back to Lua, then resume.
    c.lua_pushinteger(co.L, 7);
    const second = try co.resumeWith(1);
    try std.testing.expectEqual(Coroutine.Status.finished, second.status);
    try std.testing.expectEqual(@as(c_int, 1), second.nresults);
    try std.testing.expectEqual(@as(c.lua_Integer, 70), c.lua_tointegerx(co.L, -1, null));
}
