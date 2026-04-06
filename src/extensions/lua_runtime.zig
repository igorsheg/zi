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
};

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
        const L = c.lua_newthread(parent.L) orelse return error.OutOfMemory;
        // The new thread sits on top of the parent stack. Pop it into
        // the registry so it stays alive across `resume` calls.
        const ref = c.luaL_ref(parent.L, c.LUA_REGISTRYINDEX);
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

fn mapLoadError(L: *c.lua_State, rc: c_int) LuaError {
    consumeErrorMessage(L);
    return switch (rc) {
        c.LUA_ERRSYNTAX => error.LuaSyntax,
        c.LUA_ERRMEM => error.LuaMemory,
        else => error.LuaError,
    };
}

fn mapCallError(L: *c.lua_State, rc: c_int) LuaError {
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
