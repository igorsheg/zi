const std = @import("std");
const task_mod = @import("task.zig");
const process_engine = @import("process_engine.zig");
const logging = @import("../logging.zig");
const types = @import("process_reactor_types.zig");

const log = std.log.scoped(.zio_process_reactor);

pub const Reactor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    requests: types.RequestQueue,
    events: types.EventQueue,
    tasks: ?task_mod.Group = null,
    processes: std.AutoHashMapUnmanaged(types.ProcessId, *Process) = .empty,

    pub fn init(allocator: std.mem.Allocator) !Reactor {
        return initIo(allocator, std.Options.debug_io);
    }

    pub fn initIo(allocator: std.mem.Allocator, io: std.Io) !Reactor {
        return .{
            .allocator = allocator,
            .io = io,
            .requests = try types.RequestQueue.initIo(allocator, io),
            .events = try types.EventQueue.initIo(allocator, io),
        };
    }

    pub fn deinit(self: *Reactor) void {
        self.stop();
        self.destroyProcesses();
        self.processes.deinit(self.allocator);
        self.requests.deinit();
        self.events.deinit();
        self.* = undefined;
    }

    pub fn start(self: *Reactor) !void {
        if (self.tasks != null) return;
        var group = task_mod.Group.init(self.allocator);
        errdefer group.cancel();
        try group.spawnThread(run, .{self});
        self.tasks = group;
    }

    pub fn stop(self: *Reactor) void {
        self.requests.close();
        _ = self.requests.trySend(.shutdown);
        if (self.tasks) |*group| {
            group.join() catch |err| log.warn("process reactor join failed: {}", .{err});
            self.tasks = null;
        }
        self.events.close();
    }

    pub fn spawn(self: *Reactor, request: types.SpawnRequest) !void {
        var owned = try request.clone(self.allocator);
        errdefer owned.deinit(self.allocator);
        try self.submit(.{ .spawn = owned });
    }

    pub fn write(self: *Reactor, id: types.ProcessId, bytes: []const u8) !void {
        var owned = try (types.WriteRequest{ .id = id, .bytes = bytes }).clone(self.allocator);
        errdefer owned.deinit(self.allocator);
        try self.submit(.{ .write = owned });
    }

    pub fn closeStdin(self: *Reactor, id: types.ProcessId) !void {
        try self.submit(.{ .close_stdin = id });
    }

    pub fn kill(self: *Reactor, id: types.ProcessId) !void {
        try self.submit(.{ .stop = id });
    }

    pub fn drainEvents(self: *Reactor, out: []types.Event) usize {
        return self.events.drainInto(out);
    }

    pub fn waitEvents(self: *Reactor, timeout_ms: i32) !bool {
        return self.events.waitReadable(timeout_ms);
    }

    fn submit(self: *Reactor, request: types.Request) !void {
        var current = request;
        switch (self.requests.trySend(current)) {
            .ok => return,
            .dropped => return,
            .closed => |returned| {
                current = returned;
                current.deinit(self.allocator);
                return error.ReactorStopped;
            },
            .full => |returned| {
                current = returned;
                current.deinit(self.allocator);
                return error.ReactorQueueFull;
            },
            .oom => |returned| {
                current = returned;
                current.deinit(self.allocator);
                return error.OutOfMemory;
            },
        }
    }

    fn run(self: *Reactor) void {
        logging.setThreadLabel(.process_reactor);
        var batch: [32]types.Request = undefined;
        var shutting_down = false;
        while (!shutting_down or self.requests.pendingDepth() > 0) {
            const count = self.requests.drainInto(&batch);
            if (count == 0) {
                _ = self.requests.waitReadable(100) catch false;
                if (self.requests.isDrained()) break;
                continue;
            }
            for (batch[0..count]) |*request| {
                defer request.deinit(self.allocator);
                switch (request.*) {
                    .spawn => |spawn_request| self.handleSpawn(spawn_request) catch |err| log.warn("spawn request failed: {}", .{err}),
                    .write => |write_request| self.handleWrite(write_request),
                    .close_stdin => |id| self.handleCloseStdin(id),
                    .stop => |id| self.handleStop(id),
                    .shutdown => shutting_down = true,
                }
            }
        }
        self.destroyProcesses();
    }

    fn handleSpawn(self: *Reactor, request: types.SpawnRequest) !void {
        if (self.processes.contains(request.id)) return error.DuplicateProcess;
        const process = try self.allocator.create(Process);
        errdefer self.allocator.destroy(process);
        process.* = try Process.init(self.allocator, self.io, self, request);
        process.engine.sink.ptr = @ptrCast(process);
        errdefer process.deinit(self.allocator);
        try self.processes.put(self.allocator, request.id, process);
        errdefer _ = self.processes.remove(request.id);
        try process.engine.start();
    }

    fn handleWrite(self: *Reactor, request: types.WriteRequest) void {
        const process = self.processes.get(request.id) orelse return;
        process.engine.write(request.bytes) catch |err| log.warn("process write failed id={d}: {}", .{ request.id, err });
    }

    fn handleCloseStdin(self: *Reactor, id: types.ProcessId) void {
        const process = self.processes.get(id) orelse return;
        process.engine.closeStdin();
    }

    fn handleStop(self: *Reactor, id: types.ProcessId) void {
        const process = self.processes.get(id) orelse return;
        process.engine.stop();
    }

    fn publish(self: *Reactor, event: types.Event) bool {
        var current = event;
        return switch (self.events.trySend(current)) {
            .ok, .dropped => true,
            .closed, .full, .oom => |returned| {
                current = returned;
                current.deinit(self.allocator);
                return false;
            },
        };
    }

    fn destroyProcesses(self: *Reactor) void {
        var it = self.processes.iterator();
        while (it.next()) |entry| {
            const process = entry.value_ptr.*;
            process.engine.stop();
            process.engine.join();
            process.deinit(self.allocator);
            self.allocator.destroy(process);
        }
        self.processes.clearRetainingCapacity();
    }
};

const Process = struct {
    id: types.ProcessId,
    reactor: *Reactor,
    request: types.SpawnRequest,
    engine: process_engine.Engine,

    fn init(allocator: std.mem.Allocator, io: std.Io, reactor: *Reactor, request: types.SpawnRequest) !Process {
        const owned = try request.clone(allocator);
        errdefer owned.deinit(allocator);
        return .{
            .id = request.id,
            .reactor = reactor,
            .request = owned,
            .engine = process_engine.Engine.init(io, .{
                .argv = owned.argv,
                .cwd = owned.cwd,
                .env = owned.env,
                .clear_env = owned.clear_env,
                .process_group = owned.process_group,
                .stdin = owned.stdin,
                .stdout = owned.stdout,
                .stderr = owned.stderr,
                .timeout_ms = owned.timeout_ms,
                .signal = owned.signal,
            }, .{ .ptr = undefined, .submit = Process.submitEvent }),
        };
    }

    fn deinit(self: *Process, allocator: std.mem.Allocator) void {
        self.request.deinit(allocator);
        self.* = undefined;
    }

    fn submitEvent(ptr: *anyopaque, event: process_engine.Event) bool {
        const self: *Process = @ptrCast(@alignCast(ptr));
        const reactor = self.reactor;
        const owned: types.Event = switch (event) {
            .ready => .{ .ready = self.id },
            .stdout => |bytes| .{ .stdout = .{ .id = self.id, .bytes = reactor.allocator.dupe(u8, bytes) catch return false } },
            .stderr => |bytes| .{ .stderr = .{ .id = self.id, .bytes = reactor.allocator.dupe(u8, bytes) catch return false } },
            .exit => |term| .{ .exit = .{
                .id = self.id,
                .term = term,
                .timed_out = self.engine.didTimeout(),
                .aborted = self.engine.didAbort(),
            } },
            .spawn_failed => .{ .spawn_failed = self.id },
        };
        return reactor.publish(owned);
    }
};
