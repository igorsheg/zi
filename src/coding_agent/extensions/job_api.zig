const std = @import("std");
const lua_runtime = @import("lua_runtime.zig");
const runner_mod = @import("runner.zig");
const extension_ui = @import("ui.zig");
const limits = @import("limits.zig");
const zio = @import("../../zio/root.zig");

const c = lua_runtime.c;

pub fn install(state: *lua_runtime.LuaState, runner: *runner_mod.ExtensionRunner) void {
    const L = state.L;
    c.lua_createtable(L, 0, 4);
    state.pushCClosureWithUserdata(ziJobStart, runner);
    c.lua_setfield(L, -2, "start");
    state.pushCClosureWithUserdata(ziJobWrite, runner);
    c.lua_setfield(L, -2, "write");
    state.pushCClosureWithUserdata(ziJobStop, runner);
    c.lua_setfield(L, -2, "stop");
    state.pushCClosureWithUserdata(ziJobNext, runner);
    c.lua_setfield(L, -2, "next");
}

pub fn ziJobStart(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = runnerFromUpvalue(L);
    var request = parseStartRequest(runner.allocator, L) catch |err| {
        return luaErrorFmt(L, "zi.job.start: invalid request: {s}", .{@errorName(err)});
    };
    const id = runner.reserveJobId();
    if (runner.async_dispatcher) |dispatcher| {
        const start = dispatcher.job_start orelse {
            request.deinit(runner.allocator);
            return luaError(L, "zi.job.start: job dispatcher unavailable");
        };
        start(dispatcher.ptr, runner, id, request) catch |err| {
            return luaErrorFmt(L, "zi.job.start: {s}", .{@errorName(err)});
        };
    } else {
        defer request.deinit(runner.allocator);
        switch (request.stdout) {
            .events, .json_lines => {},
            .ui_frame => return luaError(L, "zi.job.start: ui_frame stdout requires interactive execution"),
        }
        const signal: zio.cancel.Token = if (runner.current_tool_execution) |exec| exec.signal else zio.cancel.Token.none;
        var job = runner_mod.ToolJob.start(runner.allocator, runner.io, id, request, signal) catch |err| {
            return luaErrorFmt(L, "zi.job.start: {s}", .{@errorName(err)});
        };
        errdefer job.deinit(runner.allocator);
        runner.tool_jobs.put(runner.allocator, id, job) catch |err| {
            return luaErrorFmt(L, "zi.job.start: {s}", .{@errorName(err)});
        };
    }
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
    if (runner.tool_jobs.getPtr(id)) |job| {
        job.write(ptr[0..len]) catch |err| return luaErrorFmt(L, "zi.job.write: {s}", .{@errorName(err)});
    } else {
        const dispatcher = runner.async_dispatcher orelse return luaError(L, "zi.job.write: unknown job");
        const write = dispatcher.job_write orelse return luaError(L, "zi.job.write: unsupported");
        write(dispatcher.ptr, runner, id, ptr[0..len]) catch |err| return luaErrorFmt(L, "zi.job.write: {s}", .{@errorName(err)});
    }
    return 0;
}

pub fn ziJobStop(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = runnerFromUpvalue(L);
    const id = readId(L, 1) orelse return luaError(L, "zi.job.stop: expected id");
    if (runner.tool_jobs.fetchRemove(id)) |kv| {
        var job = kv.value;
        job.stop() catch {};
        job.deinit(runner.allocator);
    } else {
        const dispatcher = runner.async_dispatcher orelse return luaError(L, "zi.job.stop: unknown job");
        const stop = dispatcher.job_stop orelse return luaError(L, "zi.job.stop: unsupported");
        stop(dispatcher.ptr, runner, id) catch |err| return luaErrorFmt(L, "zi.job.stop: {s}", .{@errorName(err)});
    }
    return 0;
}

pub fn ziJobNext(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = runnerFromUpvalue(L);
    const id = readId(L, 1) orelse return luaError(L, "zi.job.next: expected id");
    const wait_ms = readNextWaitMs(L, 2) catch return luaError(L, "zi.job.next: invalid options");
    const job = runner.tool_jobs.getPtr(id) orelse return luaError(L, "zi.job.next: unknown job");
    var event = job.next(runner.allocator, wait_ms) catch |err| return luaErrorFmt(L, "zi.job.next: {s}", .{@errorName(err)});
    if (event) |*ev| {
        defer ev.deinit(runner.allocator);
        pushJobEvent(L, ev.*);
        if (ev.kind == .exit) {
            if (runner.tool_jobs.fetchRemove(id)) |kv| {
                var owned = kv.value;
                owned.deinit(runner.allocator);
            }
        }
    } else {
        c.lua_pushnil(L);
    }
    return 1;
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
        if (std.mem.eql(u8, mode, "ui_frame")) {
            const protocol = try readStringField(allocator, L, stdout_idx, "protocol", "zi-rgba-frame-v1");
            defer allocator.free(protocol);
            const format: extension_ui.FrameFormat = if (std.mem.eql(u8, protocol, "zi-rgba-frame-v1"))
                .rgba8888
            else if (std.mem.eql(u8, protocol, "zi-halfblock-rgb-v1"))
                .halfblock_rgb
            else
                return error.InvalidOptions;
            const runner = runnerFromUpvalue(L);
            const source = runner.currentLoadSource();
            const view = try readStringField(allocator, L, stdout_idx, "view", "default");
            errdefer allocator.free(view);
            const node = try readStringField(allocator, L, stdout_idx, "node", "surface");
            errdefer allocator.free(node);
            const default_state_owner_id = if (source) |src| src.provenance.state_owner_id else "job";
            const state_owner_id = try readStringField(allocator, L, stdout_idx, "state_owner_id", default_state_owner_id);
            errdefer allocator.free(state_owner_id);
            request.stdout = .{ .ui_frame = .{
                .view = view,
                .node = node,
                .state_owner_id = state_owner_id,
                .generation = runner.generation,
                .format = format,
                .max_frame_bytes = @min(@as(usize, @intCast(readIntegerField(L, stdout_idx, "max_frame_bytes", limits.frame_bytes))), limits.frame_bytes),
            } };
        } else if (std.mem.eql(u8, mode, "json_lines")) {
            const raw_max_line_bytes = readIntegerField(L, stdout_idx, "max_line_bytes", 1024 * 1024);
            if (raw_max_line_bytes <= 0) return error.InvalidOptions;
            request.stdout = .{ .json_lines = .{
                .max_line_bytes = @min(@as(usize, @intCast(raw_max_line_bytes)), 16 * 1024 * 1024),
            } };
        } else if (!std.mem.eql(u8, mode, "events")) {
            return error.InvalidOptions;
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

fn readNextWaitMs(L: *c.lua_State, idx: c_int) !u64 {
    if (c.lua_type(L, idx) == c.LUA_TNONE or c.lua_type(L, idx) == c.LUA_TNIL) return 0;
    if (c.lua_type(L, idx) != c.LUA_TTABLE) return error.InvalidOptions;
    _ = c.lua_getfield(L, idx, "timeout_ms");
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) == c.LUA_TNIL) return 0;
    if (c.lua_type(L, -1) != c.LUA_TNUMBER) return error.InvalidOptions;
    const value = c.lua_tointegerx(L, -1, null);
    if (value < 0) return error.InvalidOptions;
    return @intCast(value);
}

fn pushJobEvent(L: *c.lua_State, event: extension_ui.JobEvent) void {
    c.lua_createtable(L, 0, 7);
    c.lua_pushinteger(L, @intCast(event.id));
    c.lua_setfield(L, -2, "id");
    pushLiteralField(L, "type", switch (event.kind) {
        .ready => "ready",
        .stdout => "stdout",
        .stderr => "stderr",
        .output_dropped => "output_dropped",
        .exit => "exit",
        .json => "json",
    });
    pushLiteralField(L, "kind", switch (event.kind) {
        .ready => "ready",
        .stdout => "stdout",
        .stderr => "stderr",
        .output_dropped => "output_dropped",
        .exit => "exit",
        .json => "json",
    });
    if (event.data) |data| {
        _ = c.lua_pushlstring(L, data.ptr, data.len);
    } else c.lua_pushnil(L);
    c.lua_setfield(L, -2, "data");
    if (event.code) |code| c.lua_pushinteger(L, @intCast(code)) else c.lua_pushnil(L);
    c.lua_setfield(L, -2, "code");
    c.lua_pushboolean(L, if (event.is_error) 1 else 0);
    c.lua_setfield(L, -2, "is_error");
    if (event.error_message) |msg| {
        _ = c.lua_pushlstring(L, msg.ptr, msg.len);
    } else c.lua_pushnil(L);
    c.lua_setfield(L, -2, "error_message");
}

fn pushLiteralField(L: *c.lua_State, field: [:0]const u8, value: [:0]const u8) void {
    _ = c.lua_pushstring(L, value.ptr);
    c.lua_setfield(L, -2, field.ptr);
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
