const std = @import("std");
const lua_runtime = @import("lua_runtime.zig");
const lua_helpers = @import("lua_helpers.zig");
const runner_mod = @import("runner.zig");

const c = lua_runtime.c;
const Lua = lua_helpers.Lua;
const TableBuilder = lua_helpers.TableBuilder;

pub fn ziSystem(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = runnerFromUpvalue(L);
    var request = parseSystemRequest(runner.allocator, L) catch |err| {
        return luaErrorFmt(L, "zi.system: invalid request: {s}", .{@errorName(err)});
    };
    request.signal = runner.requireToolExecution("zi.system").signal;
    const id = runner.beginSystemAsync(request);
    return c.lua_yieldk(L, 0, @intCast(id), ziSystemContinue);
}

fn ziSystemContinue(L_opt: ?*c.lua_State, status: c_int, ctx: c.lua_KContext) callconv(.c) c_int {
    _ = status;
    const L = L_opt.?;
    const runner = runnerFromUpvalue(L);
    const id: runner_mod.AsyncOpId = @intCast(ctx);
    var result = runner.takeCompletedAsync(id) orelse {
        pushSystemError(L, "missing async result");
        return 1;
    };
    defer result.deinit(runner.allocator);
    switch (result) {
        .system => |value| pushSystemResult(L, value),
        else => pushSystemError(L, "unexpected async result"),
    }
    return 1;
}

const SystemParseError = error{ InvalidArgv, InvalidOptions, OutOfMemory };

fn parseSystemRequest(allocator: std.mem.Allocator, L: *c.lua_State) SystemParseError!runner_mod.SystemRequest {
    if (c.lua_type(L, 1) != c.LUA_TTABLE) return error.InvalidArgv;
    const argv_len = c.lua_rawlen(L, 1);
    if (argv_len == 0) return error.InvalidArgv;
    const argv = allocator.alloc([]const u8, argv_len) catch return error.OutOfMemory;
    var argv_built: usize = 0;
    errdefer {
        for (argv[0..argv_built]) |arg| allocator.free(arg);
        allocator.free(argv);
    }
    var i: c.lua_Integer = 1;
    while (@as(usize, @intCast(i)) <= argv_len) : (i += 1) {
        _ = c.lua_rawgeti(L, 1, i);
        defer c.lua_pop(L, 1);
        if (c.lua_type(L, -1) != c.LUA_TSTRING) return error.InvalidArgv;
        var len: usize = 0;
        const ptr = c.lua_tolstring(L, -1, &len) orelse return error.InvalidArgv;
        argv[argv_built] = allocator.dupe(u8, ptr[0..len]) catch return error.OutOfMemory;
        argv_built += 1;
    }

    var request = runner_mod.SystemRequest{ .argv = argv };
    errdefer request.deinit(allocator);

    if (c.lua_type(L, 2) == c.LUA_TNONE or c.lua_type(L, 2) == c.LUA_TNIL) return request;
    if (c.lua_type(L, 2) != c.LUA_TTABLE) return error.InvalidOptions;
    const opts_idx = c.lua_absindex(L, 2);

    request.cwd = try optionalSystemStringField(allocator, L, opts_idx, "cwd");
    request.stdin = try optionalSystemStringField(allocator, L, opts_idx, "stdin");
    request.timeout_ms = optionalSystemU64Field(L, opts_idx, "timeout_ms") catch return error.InvalidOptions;
    request.max_stdout_bytes = optionalSystemUsizeField(L, opts_idx, "max_stdout_bytes", 1024 * 1024) catch return error.InvalidOptions;
    request.max_stderr_bytes = optionalSystemUsizeField(L, opts_idx, "max_stderr_bytes", 1024 * 1024) catch return error.InvalidOptions;
    request.clear_env = optionalSystemBoolField(L, opts_idx, "clear_env", false) catch return error.InvalidOptions;
    request.text = optionalSystemBoolField(L, opts_idx, "text", true) catch return error.InvalidOptions;
    request.stdio = optionalSystemStdioField(L, opts_idx, "stdio") catch return error.InvalidOptions;
    if (request.stdio == .terminal) {
        if (request.stdin != null) return error.InvalidOptions;
        if (request.timeout_ms != null) return error.InvalidOptions;
        if (hasField(L, opts_idx, "max_stdout_bytes") or hasField(L, opts_idx, "max_stderr_bytes")) return error.InvalidOptions;
    }
    request.env = try optionalSystemEnv(allocator, L, opts_idx);
    return request;
}

fn hasField(L: *c.lua_State, table_idx: c_int, field: [:0]const u8) bool {
    _ = c.lua_getfield(L, table_idx, field.ptr);
    defer c.lua_pop(L, 1);
    return c.lua_type(L, -1) != c.LUA_TNIL;
}

fn optionalSystemStringField(allocator: std.mem.Allocator, L: *c.lua_State, table_idx: c_int, field: [:0]const u8) SystemParseError!?[]const u8 {
    _ = c.lua_getfield(L, table_idx, field.ptr);
    defer c.lua_pop(L, 1);
    switch (c.lua_type(L, -1)) {
        c.LUA_TNIL => return null,
        c.LUA_TSTRING => {
            var len: usize = 0;
            const ptr = c.lua_tolstring(L, -1, &len) orelse return error.InvalidOptions;
            return allocator.dupe(u8, ptr[0..len]) catch error.OutOfMemory;
        },
        else => return error.InvalidOptions,
    }
}

fn optionalSystemU64Field(L: *c.lua_State, table_idx: c_int, field: [:0]const u8) !?u64 {
    _ = c.lua_getfield(L, table_idx, field.ptr);
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) == c.LUA_TNIL) return null;
    if (c.lua_type(L, -1) != c.LUA_TNUMBER) return error.InvalidOptions;
    const raw = c.lua_tointegerx(L, -1, null);
    if (raw <= 0) return error.InvalidOptions;
    return @intCast(raw);
}

fn optionalSystemUsizeField(L: *c.lua_State, table_idx: c_int, field: [:0]const u8, default_value: usize) !usize {
    _ = c.lua_getfield(L, table_idx, field.ptr);
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) == c.LUA_TNIL) return default_value;
    if (c.lua_type(L, -1) != c.LUA_TNUMBER) return error.InvalidOptions;
    const raw = c.lua_tointegerx(L, -1, null);
    if (raw <= 0) return error.InvalidOptions;
    const capped = @min(@as(usize, @intCast(raw)), 16 * 1024 * 1024);
    return capped;
}

fn optionalSystemBoolField(L: *c.lua_State, table_idx: c_int, field: [:0]const u8, default_value: bool) !bool {
    _ = c.lua_getfield(L, table_idx, field.ptr);
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) == c.LUA_TNIL) return default_value;
    if (c.lua_type(L, -1) != c.LUA_TBOOLEAN) return error.InvalidOptions;
    return c.lua_toboolean(L, -1) != 0;
}

fn optionalSystemStdioField(L: *c.lua_State, table_idx: c_int, field: [:0]const u8) !runner_mod.SystemStdio {
    _ = c.lua_getfield(L, table_idx, field.ptr);
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) == c.LUA_TNIL) return .capture;
    if (c.lua_type(L, -1) != c.LUA_TSTRING) return error.InvalidOptions;
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, -1, &len) orelse return error.InvalidOptions;
    const value = ptr[0..len];
    if (std.mem.eql(u8, value, "capture")) return .capture;
    if (std.mem.eql(u8, value, "terminal")) return .terminal;
    return error.InvalidOptions;
}

fn optionalSystemEnv(allocator: std.mem.Allocator, L: *c.lua_State, table_idx: c_int) SystemParseError![]runner_mod.SystemEnvPair {
    _ = c.lua_getfield(L, table_idx, "env");
    defer c.lua_pop(L, 1);
    switch (c.lua_type(L, -1)) {
        c.LUA_TNIL => return &.{},
        c.LUA_TTABLE => {},
        else => return error.InvalidOptions,
    }
    const env_idx = c.lua_absindex(L, -1);
    var pairs: std.ArrayListUnmanaged(runner_mod.SystemEnvPair) = .empty;
    errdefer {
        for (pairs.items) |pair| pair.deinit(allocator);
        pairs.deinit(allocator);
    }
    c.lua_pushnil(L);
    while (c.lua_next(L, env_idx) != 0) {
        defer c.lua_pop(L, 1);
        if (c.lua_type(L, -2) != c.LUA_TSTRING or c.lua_type(L, -1) != c.LUA_TSTRING) return error.InvalidOptions;
        var key_len: usize = 0;
        const key_ptr = c.lua_tolstring(L, -2, &key_len) orelse return error.InvalidOptions;
        var value_len: usize = 0;
        const value_ptr = c.lua_tolstring(L, -1, &value_len) orelse return error.InvalidOptions;
        pairs.append(allocator, .{
            .key = allocator.dupe(u8, key_ptr[0..key_len]) catch return error.OutOfMemory,
            .value = allocator.dupe(u8, value_ptr[0..value_len]) catch return error.OutOfMemory,
        }) catch return error.OutOfMemory;
    }
    return pairs.toOwnedSlice(allocator) catch error.OutOfMemory;
}

fn pushSystemResult(L: *c.lua_State, result: runner_mod.SystemResult) void {
    switch (result) {
        .completed => |completed| {
            const table = TableBuilder.create(Lua.init(L), 0, 5);
            table.stringZ("status", "completed");
            if (completed.code) |code| c.lua_pushinteger(L, @intCast(code)) else c.lua_pushnil(L);
            table.setFieldFromTop("code");
            if (completed.signal) |signal| c.lua_pushinteger(L, @intCast(signal)) else c.lua_pushnil(L);
            table.setFieldFromTop("signal");
            table.string("stdout", completed.stdout);
            table.string("stderr", completed.stderr);
        },
        .timeout => |timeout| {
            const table = TableBuilder.create(Lua.init(L), 0, 4);
            table.stringZ("status", "timeout");
            table.string("error", timeout.message);
            table.string("stdout", timeout.stdout);
            table.string("stderr", timeout.stderr);
        },
        .err => |err| {
            const table = TableBuilder.create(Lua.init(L), 0, 4);
            table.stringZ("status", "error");
            table.string("error", err.message);
            table.string("stdout", err.stdout);
            table.string("stderr", err.stderr);
        },
    }
}

fn pushSystemError(L: *c.lua_State, message: []const u8) void {
    const table = TableBuilder.create(Lua.init(L), 0, 4);
    table.stringZ("status", "error");
    table.string("error", message);
    table.stringZ("stdout", "");
    table.stringZ("stderr", "");
}

fn runnerFromUpvalue(L: *c.lua_State) *runner_mod.ExtensionRunner {
    return lua_helpers.ptrFromUpvalue(runner_mod.ExtensionRunner, Lua.init(L), 1);
}

fn luaErrorFmt(L: *c.lua_State, comptime fmt: []const u8, args: anytype) c_int {
    return lua_helpers.raiseErrorFmt(Lua.init(L), fmt, args);
}
