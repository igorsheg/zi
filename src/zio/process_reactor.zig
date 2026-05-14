const std = @import("std");
const queue_mod = @import("queue.zig");
const task_mod = @import("task.zig");
const process_engine = @import("process_engine.zig");
const logging = @import("../logging.zig");

const log = std.log.scoped(.zio_process_reactor);

pub const ProcessId = u64;

pub const EnvPair = process_engine.EnvPair;

pub const SpawnRequest = struct {
    id: ProcessId,
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    env: []const EnvPair = &.{},
    clear_env: bool = false,
    process_group: bool = true,
    stdin: bool = true,
    stdout: bool = true,
    stderr: bool = true,
    timeout_ms: ?u64 = null,
    signal: @import("cancel.zig").Token = .none,

    pub fn clone(self: SpawnRequest, allocator: std.mem.Allocator) !SpawnRequest {
        const argv = try allocator.alloc([]const u8, self.argv.len);
        errdefer allocator.free(argv);
        var argv_built: usize = 0;
        errdefer for (argv[0..argv_built]) |arg| allocator.free(arg);
        for (self.argv, 0..) |arg, i| {
            argv[i] = try allocator.dupe(u8, arg);
            argv_built += 1;
        }

        const env = try allocator.alloc(EnvPair, self.env.len);
        errdefer allocator.free(env);
        var env_built: usize = 0;
        errdefer for (env[0..env_built]) |pair| {
            allocator.free(pair.key);
            allocator.free(pair.value);
        };
        for (self.env, 0..) |pair, i| {
            env[i] = .{
                .key = try allocator.dupe(u8, pair.key),
                .value = try allocator.dupe(u8, pair.value),
            };
            env_built += 1;
        }

        return .{
            .id = self.id,
            .argv = argv,
            .cwd = if (self.cwd) |cwd| try allocator.dupe(u8, cwd) else null,
            .env = env,
            .clear_env = self.clear_env,
            .process_group = self.process_group,
            .stdin = self.stdin,
            .stdout = self.stdout,
            .stderr = self.stderr,
            .timeout_ms = self.timeout_ms,
            .signal = self.signal,
        };
    }

    pub fn deinit(self: *SpawnRequest, allocator: std.mem.Allocator) void {
        for (self.argv) |arg| allocator.free(arg);
        allocator.free(self.argv);
        if (self.cwd) |cwd| allocator.free(cwd);
        for (self.env) |pair| {
            allocator.free(pair.key);
            allocator.free(pair.value);
        }
        allocator.free(self.env);
        self.* = undefined;
    }
};

pub const WriteRequest = struct {
    id: ProcessId,
    bytes: []const u8,

    pub fn clone(self: WriteRequest, allocator: std.mem.Allocator) !WriteRequest {
        return .{ .id = self.id, .bytes = try allocator.dupe(u8, self.bytes) };
    }

    pub fn deinit(self: *WriteRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const Request = union(enum) {
    spawn: SpawnRequest,
    write: WriteRequest,
    close_stdin: ProcessId,
    stop: ProcessId,
    shutdown,

    pub fn deinit(self: *Request, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .spawn => |*request| request.deinit(allocator),
            .write => |*request| request.deinit(allocator),
            .close_stdin, .stop, .shutdown => {},
        }
        self.* = undefined;
    }
};

pub const Event = union(enum) {
    ready: ProcessId,
    stdout: Output,
    stderr: Output,
    exit: Exit,
    spawn_failed: ProcessId,

    pub const Output = struct { id: ProcessId, bytes: []const u8 };
    pub const Exit = struct {
        id: ProcessId,
        term: ?std.process.Child.Term,
        timed_out: bool = false,
        aborted: bool = false,
    };

    pub fn deinit(self: *Event, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .stdout => |out| allocator.free(out.bytes),
            .stderr => |out| allocator.free(out.bytes),
            .ready, .exit, .spawn_failed => {},
        }
        self.* = undefined;
    }
};

fn cleanupRequest(item: *anyopaque, allocator: std.mem.Allocator) void {
    const request: *Request = @ptrCast(@alignCast(item));
    request.deinit(allocator);
}

fn cleanupEvent(item: *anyopaque, allocator: std.mem.Allocator) void {
    const event: *Event = @ptrCast(@alignCast(item));
    event.deinit(allocator);
}

const RequestQueue = queue_mod.Queue(Request, .{
    .cleanup = .{ .custom = cleanupRequest },
    .policy = .{ .bounded = .{ .capacity = 256, .on_full = .reject } },
    .wakeup = .pipe,
});

const EventQueue = queue_mod.Queue(Event, .{
    .cleanup = .{ .custom = cleanupEvent },
    .policy = .{ .bounded = .{ .capacity = 1024, .on_full = .reject } },
    .wakeup = .pipe,
});

pub const Reactor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    requests: RequestQueue,
    events: EventQueue,
    tasks: ?task_mod.Group = null,
    processes: std.AutoHashMapUnmanaged(ProcessId, *Process) = .empty,

    pub fn init(allocator: std.mem.Allocator) !Reactor {
        return initIo(allocator, std.Options.debug_io);
    }

    pub fn initIo(allocator: std.mem.Allocator, io: std.Io) !Reactor {
        return .{
            .allocator = allocator,
            .io = io,
            .requests = try RequestQueue.initIo(allocator, io),
            .events = try EventQueue.initIo(allocator, io),
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

    pub fn spawn(self: *Reactor, request: SpawnRequest) !void {
        var owned = try request.clone(self.allocator);
        errdefer owned.deinit(self.allocator);
        try self.submit(.{ .spawn = owned });
    }

    pub fn write(self: *Reactor, id: ProcessId, bytes: []const u8) !void {
        var owned = try (WriteRequest{ .id = id, .bytes = bytes }).clone(self.allocator);
        errdefer owned.deinit(self.allocator);
        try self.submit(.{ .write = owned });
    }

    pub fn closeStdin(self: *Reactor, id: ProcessId) !void {
        try self.submit(.{ .close_stdin = id });
    }

    pub fn kill(self: *Reactor, id: ProcessId) !void {
        try self.submit(.{ .stop = id });
    }

    pub fn drainEvents(self: *Reactor, out: []Event) usize {
        return self.events.drainInto(out);
    }

    pub fn waitEvents(self: *Reactor, timeout_ms: i32) !bool {
        return self.events.waitReadable(timeout_ms);
    }

    fn submit(self: *Reactor, request: Request) !void {
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
        var batch: [32]Request = undefined;
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

    fn handleSpawn(self: *Reactor, request: SpawnRequest) !void {
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

    fn handleWrite(self: *Reactor, request: WriteRequest) void {
        const process = self.processes.get(request.id) orelse return;
        process.engine.write(request.bytes) catch |err| log.warn("process write failed id={d}: {}", .{ request.id, err });
    }

    fn handleCloseStdin(self: *Reactor, id: ProcessId) void {
        const process = self.processes.get(id) orelse return;
        process.engine.closeStdin();
    }

    fn handleStop(self: *Reactor, id: ProcessId) void {
        const process = self.processes.get(id) orelse return;
        process.engine.stop();
    }

    fn publish(self: *Reactor, event: Event) bool {
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
    id: ProcessId,
    reactor: *Reactor,
    request: SpawnRequest,
    engine: process_engine.Engine,

    fn init(allocator: std.mem.Allocator, io: std.Io, reactor: *Reactor, request: SpawnRequest) !Process {
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
        const owned: Event = switch (event) {
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

test "process reactor request and event payloads own memory" {
    const allocator = std.testing.allocator;
    var spawn_request = try (SpawnRequest{ .id = 1, .argv = &.{ "echo", "ok" }, .cwd = "/tmp", .env = &.{.{ .key = "A", .value = "B" }} }).clone(allocator);
    defer spawn_request.deinit(allocator);
    var write_request = try (WriteRequest{ .id = 1, .bytes = "hello" }).clone(allocator);
    defer write_request.deinit(allocator);
    var event = Event{ .stdout = .{ .id = 1, .bytes = try allocator.dupe(u8, "bytes") } };
    defer event.deinit(allocator);

    try std.testing.expectEqualStrings("echo", spawn_request.argv[0]);
    try std.testing.expectEqualStrings("/tmp", spawn_request.cwd.?);
    try std.testing.expectEqualStrings("B", spawn_request.env[0].value);
    try std.testing.expectEqualStrings("hello", write_request.bytes);
    try std.testing.expectEqualStrings("bytes", event.stdout.bytes);
}

test "process reactor emits ready stdout and exit events" {
    if (@import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) return error.SkipZigTest;

    var reactor = try Reactor.init(std.testing.allocator);
    defer reactor.deinit();
    try reactor.start();
    try reactor.spawn(.{ .id = 7, .argv = &.{ "/bin/sh", "-c", "printf reactor" } });

    var saw_ready = false;
    var saw_stdout = false;
    var saw_exit = false;
    var attempts: usize = 0;
    while (attempts < 200 and !(saw_ready and saw_stdout and saw_exit)) : (attempts += 1) {
        var batch: [8]Event = undefined;
        const count = reactor.drainEvents(&batch);
        if (count == 0) {
            _ = try reactor.waitEvents(100);
            continue;
        }
        for (batch[0..count]) |*event| {
            defer event.deinit(std.testing.allocator);
            switch (event.*) {
                .ready => |id| saw_ready = saw_ready or id == 7,
                .stdout => |out| saw_stdout = saw_stdout or (out.id == 7 and std.mem.eql(u8, out.bytes, "reactor")),
                .exit => |exit| saw_exit = saw_exit or (exit.id == 7 and exit.term != null),
                .stderr, .spawn_failed => {},
            }
        }
    }

    try std.testing.expect(saw_ready);
    try std.testing.expect(saw_stdout);
    try std.testing.expect(saw_exit);
}
