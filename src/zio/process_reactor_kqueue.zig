const std = @import("std");
const builtin = @import("builtin");
const process_common = @import("process_common.zig");
const logging = @import("../logging.zig");
const types = @import("process_reactor_types.zig");
const common = @import("process_reactor_common.zig");

const log = std.log.scoped(.zio_process_reactor);
const posix = std.posix;

const WatchKind = enum(u3) { requests, stdout, stderr, process, timeout, kill_grace, cancel };
const Stream = common.Stream;

pub const Reactor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    requests: types.RequestQueue,
    events: types.EventQueue,
    thread: ?std.Thread = null,
    kq: ?posix.fd_t = null,
    processes: std.AutoHashMapUnmanaged(types.ProcessId, *Process) = .empty,
    shutting_down: bool = false,

    pub fn init(allocator: std.mem.Allocator) !Reactor {
        return initIo(allocator, std.Options.debug_io);
    }

    pub fn initIo(allocator: std.mem.Allocator, io: std.Io) !Reactor {
        comptime std.debug.assert(builtin.os.tag == .macos or builtin.os.tag == .ios or builtin.os.tag == .visionos);
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
        if (self.thread != null) return;
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn stop(self: *Reactor) void {
        self.requests.close();
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
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
        const kq = std.c.kqueue();
        if (kq < 0) {
            log.warn("kqueue create failed", .{});
            self.events.close();
            return;
        }
        self.kq = kq;
        defer {
            self.kq = null;
            _ = std.c.close(kq);
        }

        registerRead(kq, self.requests.wakeReadFd().?, encode(.requests, 0)) catch |err| {
            log.warn("request wake registration failed: {}", .{err});
            return;
        };

        while (!self.shutting_down or self.processes.count() > 0) {
            var events: [32]posix.Kevent = undefined;
            const n = std.Io.Kqueue.kevent(kq, &.{}, &events, null) catch |err| {
                log.warn("kqueue wait failed: {}", .{err});
                break;
            };
            for (events[0..n]) |ev| self.handleKevent(kq, ev) catch |err| log.warn("process reactor event failed: {}", .{err});
            self.applyControl(kq) catch |err| log.warn("process reactor control failed: {}", .{err});
        }
        self.destroyProcesses();
    }

    fn handleKevent(self: *Reactor, kq: posix.fd_t, ev: posix.Kevent) !void {
        const watch = decode(ev.udata);
        switch (watch.kind) {
            .requests => try self.drainRequests(kq),
            .stdout => if (self.processes.get(watch.id)) |process| try self.drainProcess(process, .stdout),
            .stderr => if (self.processes.get(watch.id)) |process| try self.drainProcess(process, .stderr),
            .process => if (self.processes.get(watch.id)) |process| self.handleProcessExit(process),
            .timeout => if (self.processes.get(watch.id)) |process| {
                process.timed_out = true;
                process.stop_requested = true;
            },
            .kill_grace => if (self.processes.get(watch.id)) |process| {
                if (process.process_alive or process.stdout_open or process.stderr_open) process_common.killChild(process.pid, process.request.process_group, .KILL);
            },
            .cancel => if (self.processes.get(watch.id)) |process| {
                process.request.signal.acknowledgeWake();
                if (process.request.signal.isAborted()) {
                    process.aborted = true;
                    process.stop_requested = true;
                }
            },
        }
    }

    fn drainRequests(self: *Reactor, kq: posix.fd_t) !void {
        self.requests.acknowledgeWake();
        var batch: [32]types.Request = undefined;
        while (true) {
            const count = self.requests.drainInto(&batch);
            if (count == 0) break;
            for (batch[0..count]) |*request| {
                defer request.deinit(self.allocator);
                switch (request.*) {
                    .spawn => |spawn_request| self.handleSpawn(kq, spawn_request) catch |err| {
                        log.warn("spawn request failed id={d}: {}", .{ spawn_request.id, err });
                        _ = self.publish(.{ .spawn_failed = spawn_request.id });
                    },
                    .write => |write_request| self.handleWrite(write_request),
                    .close_stdin => |id| self.handleCloseStdin(id),
                    .stop => |id| self.handleStop(id),
                    .shutdown => self.shutting_down = true,
                }
            }
        }
        const request_stats = self.requests.stats();
        if (request_stats.state != .active and request_stats.pending_depth == 0) self.shutting_down = true;
    }

    fn handleSpawn(self: *Reactor, kq: posix.fd_t, request: types.SpawnRequest) !void {
        if (self.processes.contains(request.id)) return error.DuplicateProcess;
        var process = Process.init(self.allocator, self.io, request) catch {
            _ = self.publish(.{ .spawn_failed = request.id });
            return;
        };
        errdefer process.forceReap(self.io);
        errdefer process.deinit(self.allocator, self.io);

        try registerProcess(kq, process.pid, encode(.process, process.id));
        if (process.stdout_file) |file| try registerRead(kq, file.handle, encode(.stdout, process.id));
        if (process.stderr_file) |file| try registerRead(kq, file.handle, encode(.stderr, process.id));
        if (try process.request.signal.ensureWake()) |fd| try registerRead(kq, fd, encode(.cancel, process.id));
        if (process.request.timeout_ms) |ms| try registerTimer(kq, process.id, .timeout, ms);

        const slot = try self.allocator.create(Process);
        slot.* = process;
        errdefer self.allocator.destroy(slot);
        try self.processes.put(self.allocator, process.id, slot);
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
        process.stop_requested = true;
    }

    fn applyControl(self: *Reactor, kq: posix.fd_t) !void {
        var it = self.processes.iterator();
        while (it.next()) |entry| {
            const process = entry.value_ptr.*;
            if (!process.stop_requested and process.request.signal.isAborted()) {
                process.aborted = true;
                process.stop_requested = true;
            }
            if (process.stop_requested and !process.stopping) {
                process.stopping = true;
                process_common.killChild(process.pid, process.request.process_group, .TERM);
                if (!process.kill_grace_armed) {
                    try registerTimer(kq, process.id, .kill_grace, 100);
                    process.kill_grace_armed = true;
                }
            }
        }
        self.reapFinished();
    }

    fn handleProcessExit(self: *Reactor, process: *Process) void {
        if (!process.process_alive) return;
        process.term = process.child.wait(self.io) catch null;
        process.process_alive = false;
        process.closeStdin(self.io);
    }

    fn drainProcess(self: *Reactor, process: *Process, stream: Stream) !void {
        const file = switch (stream) {
            .stdout => process.stdout_file orelse return,
            .stderr => process.stderr_file orelse return,
        };
        var buf: [64 * 1024]u8 = undefined;
        const n = posix.read(file.handle, &buf) catch 0;
        if (n == 0) {
            switch (stream) {
                .stdout => process.closeStdout(self.io),
                .stderr => process.closeStderr(self.io),
            }
            return;
        }
        _ = try common.publishOutput(self.allocator, &self.events, process.id, stream, buf[0..n]);
    }

    fn reapFinished(self: *Reactor) void {
        var finished: [32]types.ProcessId = undefined;
        while (true) {
            var count: usize = 0;
            var it = self.processes.iterator();
            while (it.next()) |entry| {
                const process = entry.value_ptr.*;
                if (!process.process_alive and !process.stdout_open and !process.stderr_open) {
                    finished[count] = entry.key_ptr.*;
                    count += 1;
                    if (count == finished.len) break;
                }
            }
            if (count == 0) return;
            for (finished[0..count]) |id| {
                if (self.processes.fetchRemove(id)) |entry| {
                    const process = entry.value;
                    _ = self.publish(.{ .exit = .{ .id = process.id, .term = process.term, .timed_out = process.timed_out, .aborted = process.aborted } });
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
            if (process.process_alive) process_common.killChild(process.pid, process.request.process_group, .KILL);
            process.deinit(self.allocator, self.io);
            self.allocator.destroy(process);
        }
        self.processes.clearRetainingCapacity();
    }
};

const Process = struct {
    id: types.ProcessId,
    request: types.SpawnRequest,
    child: std.process.Child,
    pid: std.process.Child.Id,
    stdin_file: ?std.Io.File,
    stdout_file: ?std.Io.File,
    stderr_file: ?std.Io.File,
    stdout_open: bool,
    stderr_open: bool,
    process_alive: bool = true,
    stop_requested: bool = false,
    stopping: bool = false,
    kill_grace_armed: bool = false,
    timed_out: bool = false,
    aborted: bool = false,
    term: ?std.process.Child.Term = null,

    fn init(allocator: std.mem.Allocator, io: std.Io, request: types.SpawnRequest) !Process {
        const spawned = try common.SpawnedChild.init(allocator, io, request);
        return .{
            .id = spawned.request.id,
            .request = spawned.request,
            .child = spawned.child,
            .pid = spawned.pid,
            .stdin_file = spawned.stdin_file,
            .stdout_file = spawned.stdout_file,
            .stderr_file = spawned.stderr_file,
            .stdout_open = spawned.stdout_file != null,
            .stderr_open = spawned.stderr_file != null,
        };
    }

    fn deinit(self: *Process, allocator: std.mem.Allocator, io: std.Io) void {
        self.closeStdin(io);
        self.closeStdout(io);
        self.closeStderr(io);
        self.request.deinit(allocator);
        self.* = undefined;
    }

    fn forceReap(self: *Process, io: std.Io) void {
        if (!self.process_alive) return;
        common.forceReap(io, &self.child, self.pid, self.request.process_group, &self.process_alive);
    }

    fn closeStdin(self: *Process, io: std.Io) void {
        common.closeFile(io, &self.stdin_file);
    }

    fn closeStdout(self: *Process, io: std.Io) void {
        // Closing the fd removes its EVFILT_READ watch from this kqueue on Darwin.
        common.closeFile(io, &self.stdout_file);
        self.stdout_open = false;
    }

    fn closeStderr(self: *Process, io: std.Io) void {
        // Closing the fd removes its EVFILT_READ watch from this kqueue on Darwin.
        common.closeFile(io, &self.stderr_file);
        self.stderr_open = false;
    }
};

const Watch = struct { kind: WatchKind, id: types.ProcessId };

fn encode(kind: WatchKind, id: types.ProcessId) usize {
    return (@as(usize, @intCast(id)) << 3) | @intFromEnum(kind);
}

fn decode(value: usize) Watch {
    return .{ .kind = @enumFromInt(value & 0x7), .id = @intCast(value >> 3) };
}

fn registerProcess(kq: posix.fd_t, pid: std.process.Child.Id, udata: usize) !void {
    const changes = [1]posix.Kevent{.{
        .ident = @bitCast(@as(isize, @intCast(pid))),
        .filter = std.c.EVFILT.PROC,
        .flags = std.c.EV.ADD | std.c.EV.ENABLE | std.c.EV.ONESHOT,
        .fflags = std.c.NOTE.EXIT | std.c.NOTE.EXITSTATUS,
        .data = 0,
        .udata = udata,
    }};
    _ = try std.Io.Kqueue.kevent(kq, &changes, &.{}, null);
}

fn registerRead(kq: posix.fd_t, fd: posix.fd_t, udata: usize) !void {
    const changes = [1]posix.Kevent{.{
        .ident = @bitCast(@as(isize, fd)),
        .filter = std.c.EVFILT.READ,
        .flags = std.c.EV.ADD | std.c.EV.ENABLE,
        .fflags = 0,
        .data = 0,
        .udata = udata,
    }};
    _ = try std.Io.Kqueue.kevent(kq, &changes, &.{}, null);
}

fn registerTimer(kq: posix.fd_t, id: types.ProcessId, kind: WatchKind, ms: u64) !void {
    const changes = [1]posix.Kevent{.{
        .ident = encode(kind, id),
        .filter = std.c.EVFILT.TIMER,
        .flags = std.c.EV.ADD | std.c.EV.ENABLE | std.c.EV.ONESHOT,
        .fflags = 0,
        .data = @intCast(ms),
        .udata = encode(kind, id),
    }};
    _ = try std.Io.Kqueue.kevent(kq, &changes, &.{}, null);
}
