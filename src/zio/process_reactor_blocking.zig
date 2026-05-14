const std = @import("std");
const builtin = @import("builtin");
const process_common = @import("process_common.zig");
const process_env = @import("process_env.zig");
const task_mod = @import("task.zig");
const logging = @import("../logging.zig");
const types = @import("process_reactor_types.zig");
const common = @import("process_reactor_common.zig");

const log = std.log.scoped(.zio_process_reactor);
const Stream = common.Stream;

pub const Reactor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    requests: types.RequestQueue,
    events: types.EventQueue,
    tasks: ?task_mod.Group = null,
    processes: std.AutoHashMapUnmanaged(types.ProcessId, *Process) = .empty,
    shutting_down: bool = false,

    pub fn init(allocator: std.mem.Allocator) !Reactor {
        return initIo(allocator, std.Options.debug_io);
    }

    pub fn initIo(allocator: std.mem.Allocator, io: std.Io) !Reactor {
        comptime std.debug.assert(builtin.os.tag != .macos and builtin.os.tag != .ios and builtin.os.tag != .visionos and builtin.os.tag != .linux);
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
            group.join() catch |err| log.warn("blocking process reactor join failed: {}", .{err});
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
            .ok, .dropped => return,
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
        while (!self.shutting_down or self.processes.count() > 0) {
            const count = self.requests.drainInto(&batch);
            if (count == 0) {
                _ = self.requests.waitReadable(100) catch false;
                self.reapFinished();
                if (self.requests.isDrained()) self.shutting_down = true;
                continue;
            }
            for (batch[0..count]) |*request| {
                defer request.deinit(self.allocator);
                switch (request.*) {
                    .spawn => |spawn_request| self.handleSpawn(spawn_request) catch |err| {
                        log.warn("spawn request failed id={d}: {}", .{ spawn_request.id, err });
                        _ = self.publish(.{ .spawn_failed = spawn_request.id });
                    },
                    .write => |write_request| self.handleWrite(write_request),
                    .close_stdin => |id| self.handleCloseStdin(id),
                    .stop => |id| self.handleStop(id),
                    .shutdown => self.shutting_down = true,
                }
            }
            self.applyControl();
            self.reapFinished();
        }
        self.destroyProcesses();
    }

    fn handleSpawn(self: *Reactor, request: types.SpawnRequest) !void {
        if (self.processes.contains(request.id)) return error.DuplicateProcess;
        const process = try self.allocator.create(Process);
        errdefer self.allocator.destroy(process);
        process.* = Process.init(self.allocator, self.io, self, request) catch {
            _ = self.publish(.{ .spawn_failed = request.id });
            return;
        };
        errdefer process.deinit(self.allocator, self.io);
        try self.processes.put(self.allocator, process.id, process);
        errdefer _ = self.processes.remove(process.id);
        try process.startReaders();
        _ = self.publish(.{ .ready = process.id });
    }

    fn handleWrite(self: *Reactor, request: types.WriteRequest) void {
        const process = self.processes.get(request.id) orelse return;
        const file = process.stdin_file orelse return;
        file.writeStreamingAll(self.io, request.bytes) catch |err| log.warn("process write failed id={d}: {}", .{ request.id, err });
    }

    fn handleCloseStdin(self: *Reactor, id: types.ProcessId) void {
        const process = self.processes.get(id) orelse return;
        process.closeStdin(self.io);
    }

    fn handleStop(self: *Reactor, id: types.ProcessId) void {
        const process = self.processes.get(id) orelse return;
        process.stop_requested.store(true, .release);
    }

    fn applyControl(self: *Reactor) void {
        var it = self.processes.iterator();
        while (it.next()) |entry| {
            const process = entry.value_ptr.*;
            if (!process.stop_requested.load(.acquire) and process.request.signal.isAborted()) {
                process.aborted.store(true, .release);
                process.stop_requested.store(true, .release);
            }
            if (process.stop_requested.load(.acquire) and !process.stopping.swap(true, .acq_rel)) {
                process_common.killChild(process.pid, process.request.process_group, .TERM);
            }
        }
    }

    fn reapFinished(self: *Reactor) void {
        var finished: [32]types.ProcessId = undefined;
        while (true) {
            var count: usize = 0;
            var it = self.processes.iterator();
            while (it.next()) |entry| {
                const process = entry.value_ptr.*;
                if (process.done.load(.acquire)) {
                    finished[count] = entry.key_ptr.*;
                    count += 1;
                    if (count == finished.len) break;
                }
            }
            if (count == 0) return;
            for (finished[0..count]) |id| {
                if (self.processes.fetchRemove(id)) |entry| {
                    const process = entry.value;
                    _ = self.publish(.{ .exit = .{
                        .id = process.id,
                        .term = process.term,
                        .timed_out = process.timed_out.load(.acquire),
                        .aborted = process.aborted.load(.acquire),
                    } });
                    process.deinit(self.allocator, self.io);
                    self.allocator.destroy(process);
                }
            }
        }
    }

    fn publish(self: *Reactor, event: types.Event) bool {
        return common.publishEvent(self.allocator, &self.events, event);
    }

    fn destroyProcesses(self: *Reactor) void {
        var it = self.processes.iterator();
        while (it.next()) |entry| {
            const process = entry.value_ptr.*;
            process.forceReap(self.io);
            process.deinit(self.allocator, self.io);
            self.allocator.destroy(process);
        }
        self.processes.clearRetainingCapacity();
    }
};

const Process = struct {
    id: types.ProcessId,
    reactor: *Reactor,
    request: types.SpawnRequest,
    child: std.process.Child,
    pid: std.process.Child.Id,
    stdin_file: ?std.Io.File,
    stdout_file: ?std.Io.File,
    stderr_file: ?std.Io.File,
    tasks: task_mod.Group,
    term: ?std.process.Child.Term = null,
    stdout_open: std.atomic.Value(bool) = .init(false),
    stderr_open: std.atomic.Value(bool) = .init(false),
    child_exited: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    stop_requested: std.atomic.Value(bool) = .init(false),
    stopping: std.atomic.Value(bool) = .init(false),
    timed_out: std.atomic.Value(bool) = .init(false),
    aborted: std.atomic.Value(bool) = .init(false),

    fn init(allocator: std.mem.Allocator, io: std.Io, reactor: *Reactor, request: types.SpawnRequest) !Process {
        var owned = try request.clone(allocator);
        errdefer owned.deinit(allocator);
        var env_map_storage = process_env.buildMap(std.heap.page_allocator, owned.env, owned.clear_env) catch return error.EnvironmentBuildFailed;
        defer if (env_map_storage) |*env_map| env_map.deinit();
        var child = try std.process.spawn(io, .{
            .argv = owned.argv,
            .cwd = if (owned.cwd) |cwd| .{ .path = cwd } else .inherit,
            .environ_map = if (env_map_storage) |*env_map| env_map else null,
            .stdin = if (owned.stdin) .pipe else .ignore,
            .stdout = if (owned.stdout) .pipe else .ignore,
            .stderr = if (owned.stderr) .pipe else .ignore,
            .pgid = if (owned.process_group and process_common.supportsProcessGroups()) 0 else null,
        });
        const stdin_file = child.stdin;
        const stdout_file = child.stdout;
        const stderr_file = child.stderr;
        child.stdin = null;
        child.stdout = null;
        child.stderr = null;
        return .{
            .id = owned.id,
            .reactor = reactor,
            .request = owned,
            .child = child,
            .pid = child.id.?,
            .stdin_file = stdin_file,
            .stdout_file = stdout_file,
            .stderr_file = stderr_file,
            .tasks = task_mod.Group.init(allocator),
            .stdout_open = .init(stdout_file != null),
            .stderr_open = .init(stderr_file != null),
        };
    }

    fn startReaders(self: *Process) !void {
        try self.tasks.spawnThread(waitChild, .{self});
        if (self.stdout_file) |file| try self.tasks.spawnThread(readPipe, .{ self, file, Stream.stdout });
        if (self.stderr_file) |file| try self.tasks.spawnThread(readPipe, .{ self, file, Stream.stderr });
        if (self.request.timeout_ms != null or !self.request.signal.isNone()) try self.tasks.spawnThread(watchControl, .{self});
    }

    fn deinit(self: *Process, allocator: std.mem.Allocator, io: std.Io) void {
        self.tasks.join() catch {};
        self.closeStdin(io);
        if (self.stdout_file) |file| file.close(io);
        if (self.stderr_file) |file| file.close(io);
        self.request.deinit(allocator);
        self.* = undefined;
    }

    fn closeStdin(self: *Process, io: std.Io) void {
        if (self.stdin_file) |file| file.close(io);
        self.stdin_file = null;
    }

    fn forceReap(self: *Process, io: std.Io) void {
        if (self.child_exited.load(.acquire)) return;
        process_common.killChild(self.pid, self.request.process_group, .KILL);
        _ = self.child.wait(io) catch null;
        self.child_exited.store(true, .release);
        self.done.store(true, .release);
    }

    fn markDoneIfComplete(self: *Process) void {
        if (self.child_exited.load(.acquire) and !self.stdout_open.load(.acquire) and !self.stderr_open.load(.acquire)) self.done.store(true, .release);
    }

    fn waitChild(self: *Process) void {
        self.term = self.child.wait(self.reactor.io) catch null;
        self.child_exited.store(true, .release);
        self.closeStdin(self.reactor.io);
        self.markDoneIfComplete();
    }

    fn readPipe(self: *Process, file: std.Io.File, stream: Stream) void {
        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            const n = std.posix.read(file.handle, &buf) catch break;
            if (n == 0) break;
            _ = common.publishOutput(self.reactor.allocator, &self.reactor.events, self.id, stream, buf[0..n]) catch break;
        }
        switch (stream) {
            .stdout => self.stdout_open.store(false, .release),
            .stderr => self.stderr_open.store(false, .release),
        }
        self.markDoneIfComplete();
    }

    fn watchControl(self: *Process) void {
        const start = std.Io.Timestamp.now(self.reactor.io, .awake).toMilliseconds();
        while (!self.child_exited.load(.acquire)) {
            if (self.request.signal.isAborted()) {
                self.aborted.store(true, .release);
                self.stop_requested.store(true, .release);
            }
            if (self.request.timeout_ms) |ms| {
                const now = std.Io.Timestamp.now(self.reactor.io, .awake).toMilliseconds();
                if (now - start >= ms) {
                    self.timed_out.store(true, .release);
                    self.stop_requested.store(true, .release);
                }
            }
            if (self.stop_requested.load(.acquire) and !self.stopping.swap(true, .acq_rel)) {
                process_common.killChild(self.pid, self.request.process_group, .TERM);
            }
            self.reactor.io.sleep(.fromMilliseconds(10), .awake) catch {};
        }
    }
};
