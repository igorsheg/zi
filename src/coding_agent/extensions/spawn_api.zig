const std = @import("std");
const lua_runtime = @import("lua_runtime.zig");
const lua_helpers = @import("lua_helpers.zig");
const runner_mod = @import("runner.zig");
const api_export = @import("api_export.zig");
const agent_protocol = @import("../../agent/types.zig");
const spawn_types = @import("../../spawn/types.zig");
const spawn_mod = @import("../../spawn/spawn.zig");
const ai = @import("../../ai/root.zig");
const limits = @import("limits.zig");

const c = lua_runtime.c;
const Lua = lua_helpers.Lua;
const TableBuilder = lua_helpers.TableBuilder;
const log = std.log.scoped(.zi_api);

const spawn_pending_events: usize = limits.spawn_pending_events;

pub const export_spawn = api_export.Export{
    .name = "spawn",
    .kind = .function,
    .install = installSpawnExport,
};

fn installSpawnExport(state: *lua_runtime.LuaState, runner: *runner_mod.ExtensionRunner) void {
    state.pushCClosureWithUserdata(ziSpawn, runner);
    c.lua_setfield(state.L, -2, export_spawn.name.ptr);
}

pub fn ziSpawn(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = runnerFromUpvalue(L);

    var err_buf: [256]u8 = undefined;
    const req = buildSpawnRequest(L, runner, &err_buf) catch {
        const msg = err_buf[0..std.mem.indexOfScalar(u8, &err_buf, 0).?];
        _ = c.lua_pushlstring(L, msg.ptr, msg.len);
        _ = c.lua_error(L);
        return 0;
    } orelse return 0;

    if (runner.current_tool_execution != null) {
        runner.current_spawn_request = req;
        return c.lua_yieldk(L, 0, 0, ziSpawnContinue);
    }

    var owned_req = req;
    defer {
        if (owned_req.callbacks_ref != c.LUA_NOREF) c.luaL_unref(owned_req.source_L, c.LUA_REGISTRYINDEX, owned_req.callbacks_ref);
        owned_req.deinit(runner.allocator);
    }

    var fanout = SpawnEventFanout{
        .allocator = runner.allocator,
        .lua = if (owned_req.callbacks_ref != c.LUA_NOREF) .{ .L = L, .callbacks_ref = owned_req.callbacks_ref } else null,
    };
    defer fanout.deinit();

    const has_observer = fanout.lua != null;
    const cfg = spawn_types.SpawnConfig{
        .allocator = runner.allocator,
        .io = runner.io,
        .cwd = owned_req.cwd,
        .task = owned_req.task,
        .model = owned_req.model,
        .tools = owned_req.tools,
        .append_system_prompt = owned_req.append_system_prompt,
        .signal = owned_req.signal,
        .on_event = if (has_observer) &SpawnEventFanout.callback else null,
        .on_event_ctx = if (has_observer) @ptrCast(&fanout) else null,
        .on_wait = if (has_observer) &SpawnEventFanout.drainCallback else null,
        .on_wait_ctx = if (has_observer) @ptrCast(&fanout) else null,
    };

    var result = spawn_mod.ziSpawn(cfg);
    defer result.deinit(runner.allocator);
    fanout.drain() catch {};
    pushSpawnResult(L, result);
    return 1;
}

fn ziSpawnContinue(L_opt: ?*c.lua_State, status: c_int, ctx: c.lua_KContext) callconv(.c) c_int {
    _ = status;
    _ = ctx;
    const L = L_opt.?;
    const runner = runnerFromUpvalue(L);
    const outcome = runner.current_spawn_result orelse return luaError(L, "ctx.agent.run: missing resume result");
    defer runner.current_spawn_result = null;

    pushToolResultAsSpawnResult(L, outcome.result);
    return 1;
}

pub fn ziSpawnContinueWrapper(L_opt: ?*c.lua_State) callconv(.c) c_int {
    return ziSpawnContinue(L_opt, c.LUA_YIELD, 0);
}

const ZiSpawnError = error{NeedLuaError};

fn buildSpawnRequest(
    L: *c.lua_State,
    runner: *runner_mod.ExtensionRunner,
    err_buf: *[256]u8,
) ZiSpawnError!?runner_mod.SpawnRequest {
    if (c.lua_type(L, 1) != c.LUA_TTABLE) {
        return writeErr(err_buf, "ctx.agent.run: expected opts table as first argument");
    }

    var arena = std.heap.ArenaAllocator.init(runner.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const task = readSpawnString(L, 1, "task", aa) catch |err| switch (err) {
        error.Missing => return writeErr(err_buf, "ctx.agent.run: 'task' is required (string)"),
        error.WrongType => return writeErr(err_buf, "ctx.agent.run: 'task' must be a string"),
        error.OutOfMemory => return writeErr(err_buf, "ctx.agent.run: out of memory"),
    } orelse return writeErr(err_buf, "ctx.agent.run: 'task' is required (string)");

    const model = readOptionalSpawnString(L, 1, "model", aa) catch
        return writeErr(err_buf, "ctx.agent.run: 'model' must be a string");
    const tools = readOptionalSpawnString(L, 1, "tools", aa) catch
        return writeErr(err_buf, "ctx.agent.run: 'tools' must be a string");
    const system_append = readOptionalSpawnString(L, 1, "system_append", aa) catch
        return writeErr(err_buf, "ctx.agent.run: 'system_append' must be a string");
    const cwd_opt = readOptionalSpawnString(L, 1, "cwd", aa) catch
        return writeErr(err_buf, "ctx.agent.run: 'cwd' must be a string");

    _ = c.lua_getfield(L, 1, "on");
    const on_type = c.lua_type(L, -1);
    var callbacks_ref: c_int = c.LUA_NOREF;
    if (on_type == c.LUA_TNIL) {
        c.lua_pop(L, 1);
    } else if (on_type == c.LUA_TTABLE) {
        c.lua_pushnil(L);
        while (c.lua_next(L, -2) != 0) {
            if (c.lua_type(L, -2) != c.LUA_TSTRING) {
                c.lua_pop(L, 3);
                return writeErr(err_buf, "ctx.agent.run: 'on' keys must be event-name strings");
            }
            if (c.lua_type(L, -1) != c.LUA_TFUNCTION) {
                c.lua_pop(L, 3);
                return writeErr(err_buf, "ctx.agent.run: 'on' values must be functions");
            }
            c.lua_pop(L, 1);
        }
        callbacks_ref = c.luaL_ref(L, c.LUA_REGISTRYINDEX);
    } else {
        c.lua_pop(L, 1);
        return writeErr(err_buf, "ctx.agent.run: 'on' must be a table");
    }

    const exec = runner.requireToolExecution("ctx.agent.run");
    return .{
        .task = runner.allocator.dupe(u8, task) catch return writeErr(err_buf, "ctx.agent.run: out of memory"),
        .signal = exec.signal,
        .model = if (model) |v| runner.allocator.dupe(u8, v) catch return writeErr(err_buf, "ctx.agent.run: out of memory") else null,
        .tools = if (tools) |v| runner.allocator.dupe(u8, v) catch return writeErr(err_buf, "ctx.agent.run: out of memory") else null,
        .append_system_prompt = if (system_append) |v| runner.allocator.dupe(u8, v) catch return writeErr(err_buf, "ctx.agent.run: out of memory") else null,
        .cwd = runner.allocator.dupe(u8, cwd_opt orelse ".") catch return writeErr(err_buf, "ctx.agent.run: out of memory"),
        .callbacks_ref = callbacks_ref,
        .source_L = L,
        .continuation_ctx = 0,
    };
}

fn writeErr(err_buf: *[256]u8, msg: []const u8) ZiSpawnError {
    const n = @min(msg.len, err_buf.len - 1);
    @memcpy(err_buf[0..n], msg[0..n]);
    err_buf[n] = 0;
    return error.NeedLuaError;
}

const SpawnReadError = error{ Missing, WrongType, OutOfMemory };

fn readSpawnString(
    L: *c.lua_State,
    table_idx: c_int,
    field: [:0]const u8,
    allocator: std.mem.Allocator,
) SpawnReadError!?[]const u8 {
    _ = c.lua_getfield(L, table_idx, field.ptr);
    defer c.lua_pop(L, 1);
    return switch (c.lua_type(L, -1)) {
        c.LUA_TNIL => error.Missing,
        c.LUA_TSTRING => blk: {
            var len: usize = 0;
            const ptr = c.lua_tolstring(L, -1, &len) orelse return error.WrongType;
            break :blk allocator.dupe(u8, ptr[0..len]) catch error.OutOfMemory;
        },
        else => error.WrongType,
    };
}

fn readOptionalSpawnString(
    L: *c.lua_State,
    table_idx: c_int,
    field: [:0]const u8,
    allocator: std.mem.Allocator,
) error{ WrongType, OutOfMemory }!?[]const u8 {
    _ = c.lua_getfield(L, table_idx, field.ptr);
    defer c.lua_pop(L, 1);
    return switch (c.lua_type(L, -1)) {
        c.LUA_TNIL => null,
        c.LUA_TSTRING => blk: {
            var len: usize = 0;
            const ptr = c.lua_tolstring(L, -1, &len) orelse return error.WrongType;
            break :blk allocator.dupe(u8, ptr[0..len]) catch error.OutOfMemory;
        },
        else => error.WrongType,
    };
}

pub const TrampolineCtx = struct {
    L: *c.lua_State,
    callbacks_ref: c_int,
};

const SpawnEventFanout = struct {
    const PendingEvent = struct {
        kind: []const u8,
        event: std.json.Value,
    };

    allocator: std.mem.Allocator,
    lua: ?TrampolineCtx = null,
    events: std.ArrayList(PendingEvent) = .empty,
    dropped_count: usize = 0,
    mutex: std.Io.Mutex = .init,

    fn callback(kind: []const u8, event: std.json.Value, ctx: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);

        if (self.events.items.len >= spawn_pending_events) {
            self.dropped_count += 1;
            return;
        }

        const owned_kind = self.allocator.dupe(u8, kind) catch return;
        errdefer self.allocator.free(owned_kind);
        var budget = lua_runtime.JsonConvertBudget{ .limits = lua_runtime.default_json_convert_limits };
        const owned_event = cloneJsonValueLimited(self.allocator, event, &budget) catch {
            self.dropped_count += 1;
            return;
        };
        errdefer ai.json_util.freeJsonValue(self.allocator, owned_event);
        self.events.append(self.allocator, .{ .kind = owned_kind, .event = owned_event }) catch {
            self.dropped_count += 1;
            return;
        };
    }

    fn drainCallback(ctx: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.drain() catch {};
    }

    fn drain(self: *SpawnEventFanout) !void {
        var drained: std.ArrayList(PendingEvent) = .empty;
        var dropped: usize = 0;
        self.mutex.lockUncancelable(std.Options.debug_io);
        std.mem.swap(std.ArrayList(PendingEvent), &drained, &self.events);
        dropped = self.dropped_count;
        self.dropped_count = 0;
        self.mutex.unlock(std.Options.debug_io);
        defer freeEvents(self.allocator, &drained);

        for (drained.items) |entry| {
            if (self.lua) |*lua| eventTrampoline(entry.kind, entry.event, @ptrCast(lua));
        }
        if (dropped > 0) {
            const event = try droppedEvent(self.allocator, dropped);
            defer ai.json_util.freeJsonValue(self.allocator, event);
            if (self.lua) |*lua| eventTrampoline("events_dropped", event, @ptrCast(lua));
        }
    }

    fn deinit(self: *SpawnEventFanout) void {
        freeEvents(self.allocator, &self.events);
    }

    fn freeEvents(allocator: std.mem.Allocator, events: *std.ArrayList(PendingEvent)) void {
        for (events.items) |entry| {
            allocator.free(entry.kind);
            ai.json_util.freeJsonValue(allocator, entry.event);
        }
        events.deinit(allocator);
    }
};

fn droppedEvent(allocator: std.mem.Allocator, count: usize) !std.json.Value {
    var obj: std.json.ObjectMap = .{};
    errdefer ai.json_util.freeJsonValue(allocator, .{ .object = obj });
    try obj.put(allocator, try allocator.dupe(u8, "kind"), .{ .string = try allocator.dupe(u8, "events_dropped") });
    try obj.put(allocator, try allocator.dupe(u8, "count"), .{ .integer = @intCast(count) });
    return .{ .object = obj };
}

fn cloneJsonValueLimited(allocator: std.mem.Allocator, value: std.json.Value, budget: *lua_runtime.JsonConvertBudget) !std.json.Value {
    return switch (value) {
        .null => .null,
        .bool => |b| .{ .bool = b },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .number_string => |s| blk: {
            try chargeString(s.len, budget);
            break :blk .{ .number_string = try allocator.dupe(u8, s) };
        },
        .string => |s| blk: {
            try chargeString(s.len, budget);
            break :blk .{ .string = try allocator.dupe(u8, s) };
        },
        .array => |arr| blk: {
            if (budget.depth >= budget.limits.max_depth) return error.LimitExceeded;
            if (arr.items.len > budget.limits.max_items or budget.items > budget.limits.max_items - arr.items.len) return error.LimitExceeded;
            budget.depth += 1;
            defer budget.depth -= 1;
            budget.items += arr.items.len;

            var out = std.json.Array.init(allocator);
            errdefer ai.json_util.freeJsonValue(allocator, .{ .array = out });
            try out.ensureTotalCapacity(arr.items.len);
            for (arr.items) |item| {
                const cloned = try cloneJsonValueLimited(allocator, item, budget);
                out.append(cloned) catch |err| {
                    ai.json_util.freeJsonValue(allocator, cloned);
                    return err;
                };
            }
            break :blk .{ .array = out };
        },
        .object => |obj| blk: {
            if (budget.depth >= budget.limits.max_depth) return error.LimitExceeded;
            if (obj.count() > budget.limits.max_items or budget.items > budget.limits.max_items - obj.count()) return error.LimitExceeded;
            budget.depth += 1;
            defer budget.depth -= 1;
            budget.items += obj.count();

            var out: std.json.ObjectMap = .{};
            errdefer ai.json_util.freeJsonValue(allocator, .{ .object = out });
            var it = obj.iterator();
            while (it.next()) |kv| {
                const key = try allocator.dupe(u8, kv.key_ptr.*);
                const cloned = cloneJsonValueLimited(allocator, kv.value_ptr.*, budget) catch |err| {
                    allocator.free(key);
                    return err;
                };
                out.put(allocator, key, cloned) catch |err| {
                    allocator.free(key);
                    ai.json_util.freeJsonValue(allocator, cloned);
                    return err;
                };
            }
            break :blk .{ .object = out };
        },
    };
}

fn chargeString(len: usize, budget: *lua_runtime.JsonConvertBudget) !void {
    if (len > budget.limits.max_string_bytes) return error.LimitExceeded;
    if (len > budget.limits.max_total_string_bytes or budget.total_string_bytes > budget.limits.max_total_string_bytes - len) return error.LimitExceeded;
    budget.total_string_bytes += len;
}

pub fn eventTrampoline(
    kind: []const u8,
    event: std.json.Value,
    ctx: ?*anyopaque,
) void {
    const tctx: *TrampolineCtx = @ptrCast(@alignCast(ctx.?));
    const L = tctx.L;

    _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, tctx.callbacks_ref);
    if (c.lua_type(L, -1) != c.LUA_TTABLE) {
        c.lua_pop(L, 1);
        return;
    }

    _ = c.lua_pushlstring(L, kind.ptr, kind.len);
    _ = c.lua_gettable(L, -2);
    if (c.lua_type(L, -1) != c.LUA_TFUNCTION) {
        c.lua_pop(L, 2);
        return;
    }

    lua_runtime.pushJsonValue(L, event) catch {
        c.lua_pop(L, 2);
        return;
    };

    const rc = c.lua_pcallk(L, 1, 0, 0, 0, null);
    if (rc != c.LUA_OK) {
        if (c.lua_type(L, -1) == c.LUA_TSTRING) {
            var len: usize = 0;
            if (c.lua_tolstring(L, -1, &len)) |msg| {
                log.warn("ctx.agent.run 'on.{s}' handler error: {s}", .{ kind, msg[0..len] });
            }
        }
        c.lua_pop(L, 1);
    }
    c.lua_pop(L, 1);
}

pub fn pushToolResultAsSpawnResult(L: *c.lua_State, result: agent_protocol.AgentToolResult) void {
    const table = TableBuilder.create(Lua.init(L), 0, 11);

    table.int("exit_code", @as(i32, if (result.is_error) 1 else 0));

    if (result.details == .object) {
        const obj = result.details.object;
        if (obj.get("stop_reason")) |v| if (v == .string) {
            table.string("stop_reason", v.string);
        };
        if (obj.get("model")) |v| if (v == .string) {
            table.string("model", v.string);
        };
        if (obj.get("cancelled")) |v| if (v == .bool) {
            table.boolean("cancelled", v.bool);
        };
        if (obj.get("usage")) |usage| {
            lua_runtime.pushJsonValue(L, usage) catch c.lua_createtable(L, 0, 0);
            table.setFieldFromTop("usage");
        } else {
            c.lua_createtable(L, 0, 0);
            table.setFieldFromTop("usage");
        }
    } else {
        c.lua_createtable(L, 0, 0);
        table.setFieldFromTop("usage");
    }

    table.boolean("is_error", result.is_error);

    c.lua_createtable(L, @intCast(result.content.len), 0);
    const content_table = TableBuilder.atTop(Lua.init(L));
    var content_i: c.lua_Integer = 1;
    var text: []const u8 = "";
    for (result.content) |block| {
        switch (block) {
            .text => |tb| {
                if (text.len == 0) text = tb.text;
                const block_table = TableBuilder.create(Lua.init(L), 0, 2);
                block_table.stringZ("type", "text");
                block_table.string("text", tb.text);
                content_table.rawSetArrayFromTop(@intCast(content_i));
                content_i += 1;
            },
            else => {},
        }
    }
    table.setFieldFromTop("content");

    if (result.details != .null) {
        lua_runtime.pushJsonValue(L, result.details) catch c.lua_pushnil(L);
        table.setFieldFromTop("details");
    }
    if (result.presentation != .null) {
        lua_runtime.pushJsonValue(L, result.presentation) catch c.lua_pushnil(L);
        table.setFieldFromTop("presentation");
    }

    table.string("output", text);
    table.string("final_text", text);
    table.stringZ("stderr", "");
    if (result.details != .object or result.details.object.get("cancelled") == null) {
        table.boolean("cancelled", false);
    }
}

pub fn pushSpawnResult(L: *c.lua_State, result: spawn_types.SpawnResult) void {
    const table = TableBuilder.create(Lua.init(L), 0, 11);

    table.int("exit_code", result.exit_code);

    if (result.stop_reason) |sr| {
        table.string("stop_reason", sr);
    }
    if (result.error_message) |em| {
        table.string("error_message", em);
    }
    if (result.model) |m| {
        table.string("model", m);
    }

    table.string("final_text", result.output.items);

    table.string("stderr", result.stderr_output.items);

    table.boolean("cancelled", result.cancelled);

    const usage = TableBuilder.create(Lua.init(L), 0, 7);
    usage.int("input", result.usage.input);
    usage.int("output", result.usage.output);
    usage.int("cache_read", result.usage.cache_read);
    usage.int("cache_write", result.usage.cache_write);
    usage.int("total_tokens", result.usage.context_tokens);
    usage.number("cost", result.usage.cost);
    usage.int("turns", result.usage.turns);
    table.setFieldFromTop("usage");
}

test "spawn event fanout bounds pending events and tracks drops" {
    var fanout = SpawnEventFanout{ .allocator = std.testing.allocator };
    defer fanout.deinit();

    const event = std.json.Value{ .string = "ok" };
    var i: usize = 0;
    while (i < spawn_pending_events + 5) : (i += 1) {
        SpawnEventFanout.callback("message", event, @ptrCast(&fanout));
    }

    try std.testing.expectEqual(spawn_pending_events, fanout.events.items.len);
    try std.testing.expectEqual(@as(usize, 5), fanout.dropped_count);
}

fn runnerFromUpvalue(L: *c.lua_State) *runner_mod.ExtensionRunner {
    return lua_helpers.ptrFromUpvalue(runner_mod.ExtensionRunner, Lua.init(L), 1);
}

fn luaError(L: *c.lua_State, msg: [:0]const u8) c_int {
    return lua_helpers.raiseError(Lua.init(L), msg);
}
