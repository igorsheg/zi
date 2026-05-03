const std = @import("std");
const lua_runtime = @import("lua_runtime.zig");
const runner_mod = @import("runner.zig");

const c = lua_runtime.c;

pub fn install(state: *lua_runtime.LuaState, runner: *runner_mod.ExtensionRunner) void {
    const L = state.L;
    c.lua_createtable(L, 0, 3);
    state.pushCClosureWithUserdata(ziJobStart, runner);
    c.lua_setfield(L, -2, "start");
    state.pushCClosureWithUserdata(ziJobWrite, runner);
    c.lua_setfield(L, -2, "write");
    state.pushCClosureWithUserdata(ziJobStop, runner);
    c.lua_setfield(L, -2, "stop");
}

pub fn ziJobStart(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = runnerFromUpvalue(L);
    var request = parseStartRequest(runner.allocator, L) catch |err| {
        return luaErrorFmt(L, "zi.job.start: invalid request: {s}", .{@errorName(err)});
    };
    const id = runner.reserveJobId();
    const dispatcher = runner.async_dispatcher orelse {
        request.deinit(runner.allocator);
        return luaError(L, "zi.job.start: unavailable outside interactive execution");
    };
    const start = dispatcher.job_start orelse {
        request.deinit(runner.allocator);
        return luaError(L, "zi.job.start: job dispatcher unavailable");
    };
    start(dispatcher.ptr, runner, id, request) catch |err| {
        return luaErrorFmt(L, "zi.job.start: {s}", .{@errorName(err)});
    };
    c.lua_createtable(L, 0, 1);
    c.lua_pushinteger(L, @intCast(id));
    c.lua_setfield(L, -2, "id");
    return 1;
}

pub fn ziJobWrite(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = runnerFromUpvalue(L);
    const id = readId(L, 1) orelse return luaError(L, "zi.job.write: expected id");
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, 2, &len) orelse return luaError(L, "zi.job.write: expected data string");
    const dispatcher = runner.async_dispatcher orelse return luaError(L, "zi.job.write: dispatcher unavailable");
    const write = dispatcher.job_write orelse return luaError(L, "zi.job.write: unsupported");
    write(dispatcher.ptr, runner, id, ptr[0..len]) catch |err| return luaErrorFmt(L, "zi.job.write: {s}", .{@errorName(err)});
    return 0;
}

pub fn ziJobStop(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = runnerFromUpvalue(L);
    const id = readId(L, 1) orelse return luaError(L, "zi.job.stop: expected id");
    const dispatcher = runner.async_dispatcher orelse return luaError(L, "zi.job.stop: dispatcher unavailable");
    const stop = dispatcher.job_stop orelse return luaError(L, "zi.job.stop: unsupported");
    stop(dispatcher.ptr, runner, id) catch |err| return luaErrorFmt(L, "zi.job.stop: {s}", .{@errorName(err)});
    return 0;
}

fn parseStartRequest(allocator: std.mem.Allocator, L: *c.lua_State) !runner_mod.JobStartRequest {
    if (c.lua_type(L, 1) != c.LUA_TTABLE) return error.InvalidOptions;
    _ = c.lua_getfield(L, 1, "argv");
    defer c.lua_pop(L, 1);
    const argv_idx = c.lua_absindex(L, -1);
    if (c.lua_type(L, argv_idx) != c.LUA_TTABLE) return error.InvalidArgv;
    const argv_len = c.lua_rawlen(L, argv_idx);
    if (argv_len == 0) return error.InvalidArgv;
    const argv = try allocator.alloc([]const u8, argv_len);
    var built: usize = 0;
    var argv_transferred = false;
    errdefer if (!argv_transferred) {
        for (argv[0..built]) |arg| allocator.free(arg);
        allocator.free(argv);
    };
    var i: c.lua_Integer = 1;
    while (@as(usize, @intCast(i)) <= argv_len) : (i += 1) {
        _ = c.lua_rawgeti(L, argv_idx, i);
        defer c.lua_pop(L, 1);
        if (c.lua_type(L, -1) != c.LUA_TSTRING) return error.InvalidArgv;
        var len: usize = 0;
        const ptr = c.lua_tolstring(L, -1, &len) orelse return error.InvalidArgv;
        argv[built] = try allocator.dupe(u8, ptr[0..len]);
        built += 1;
    }
    var request = runner_mod.JobStartRequest{ .argv = argv };
    argv_transferred = true;
    errdefer request.deinit(allocator);
    _ = c.lua_getfield(L, 1, "cwd");
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) == c.LUA_TSTRING) {
        var len: usize = 0;
        const ptr = c.lua_tolstring(L, -1, &len) orelse return error.InvalidOptions;
        request.cwd = try allocator.dupe(u8, ptr[0..len]);
    }
    _ = c.lua_getfield(L, 1, "stdout");
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) == c.LUA_TTABLE) {
        const stdout_idx = c.lua_absindex(L, -1);
        const mode = try readStringField(allocator, L, stdout_idx, "mode", "events");
        defer allocator.free(mode);
        if (std.mem.eql(u8, mode, "surface_frame")) {
            const runner = runnerFromUpvalue(L);
            const source = runner.currentLoadSource();
            const surface_id = try readStringField(allocator, L, stdout_idx, "surface", "surface");
            errdefer allocator.free(surface_id);
            const state_owner_id = try allocator.dupe(u8, if (source) |src| src.provenance.state_owner_id else "job");
            errdefer allocator.free(state_owner_id);
            request.stdout = .{ .surface_frame = .{
                .surface_id = surface_id,
                .state_owner_id = state_owner_id,
                .generation = runner.generation,
                .max_frame_bytes = @intCast(readIntegerField(L, stdout_idx, "max_frame_bytes", 16 * 1024 * 1024)),
            } };
        }
    }
    return request;
}

fn readStringField(allocator: std.mem.Allocator, L: *c.lua_State, idx: c_int, field: [:0]const u8, default: []const u8) ![]u8 {
    _ = c.lua_getfield(L, idx, field.ptr);
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TSTRING) return allocator.dupe(u8, default);
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, -1, &len) orelse return error.InvalidOptions;
    return allocator.dupe(u8, ptr[0..len]);
}

fn readIntegerField(L: *c.lua_State, idx: c_int, field: [:0]const u8, default: c.lua_Integer) c.lua_Integer {
    _ = c.lua_getfield(L, idx, field.ptr);
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TNUMBER) return default;
    return c.lua_tointegerx(L, -1, null);
}

fn readId(L: *c.lua_State, idx: c_int) ?u64 {
    if (c.lua_type(L, idx) == c.LUA_TTABLE) {
        _ = c.lua_getfield(L, idx, "id");
        defer c.lua_pop(L, 1);
        if (c.lua_type(L, -1) != c.LUA_TNUMBER) return null;
        return @intCast(c.lua_tointegerx(L, -1, null));
    }
    if (c.lua_type(L, idx) != c.LUA_TNUMBER) return null;
    return @intCast(c.lua_tointegerx(L, idx, null));
}

fn runnerFromUpvalue(L: *c.lua_State) *runner_mod.ExtensionRunner {
    const raw = c.lua_touserdata(L, c.lua_upvalueindex(1)) orelse unreachable;
    return @ptrCast(@alignCast(raw));
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
