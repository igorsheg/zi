const std = @import("std");
const builtin = @import("builtin");
const process_common = @import("process_common.zig");
const process_env = @import("process_env.zig");
const logging = @import("../logging.zig");
const types = @import("process_reactor_types.zig");
const common = @import("process_reactor_common.zig");

const log = std.log.scoped(.zio_process_reactor);
const linux = std.os.linux;
const posix = std.posix;

const WatchKind = enum(u3) { requests, stdout, stderr, process, timeout, kill_grace, cancel };
const Stream = common.Stream;
const Watch = struct { kind: WatchKind, id: types.ProcessId };

pub const Reactor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    requests: types.RequestQueue,
    events: types.EventQueue,
    thread: ?std.Thread = null,
    processes: std.AutoHashMapUnmanaged(types.ProcessId, *Process) = .empty,
    shutting_down: bool = false,

    pub fn init(allocator: std.mem.Allocator) !Reactor {
        return initIo(allocator, std.Options.debug_io);
    }

    pub fn initIo(allocator: std.mem.Allocator, io: std.Io) !Reactor {
        comptime std.debug.assert(builtin.os.tag == .linux);
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
        const epfd = epollCreate() catch |err| {
            log.warn("epoll create failed: {}", .{err});
            self.events.close();
            return;
        };
        defer closeFd(epfd);
        registerFd(epfd, self.requests.wakeReadFd().?, encode(.requests, 0)) catch |err| {
            log.warn("request wake registration failed: {}", .{err});
            return;
        };

        while (!self.shutting_down or self.processes.count() > 0) {
            var events: [32]linux.epoll_event = undefined;
            const n = epollWait(epfd, &events) catch |err| {
                log.warn("epoll wait failed: {}", .{err});
                break;
            };
            for (events[0..n]) |ev| self.handleEpoll(epfd, ev) catch |err| log.warn("process reactor event failed: {}", .{err});
            self.applyControl(epfd) catch |err| log.warn("process reactor control failed: {}", .{err});
        }
        self.destroyProcesses();
    }

    fn handleEpoll(self: *Reactor, epfd: posix.fd_t, ev: linux.epoll_event) !void {
        const watch = decode(ev.data.u64);
        switch (watch.kind) {
            .requests => try self.drainRequests(epfd),
            .stdout => if (self.processes.get(watch.id)) |process| try self.drainProcess(epfd, process, .stdout),
            .stderr => if (self.processes.get(watch.id)) |process| try self.drainProcess(epfd, process, .stderr),
            .process => if (self.processes.get(watch.id)) |process| self.handleProcessExit(epfd, process),
            .timeout => if (self.processes.get(watch.id)) |process| {
                if (process.timeout_fd) |fd| drainTimerFd(fd);
                process.timed_out = true;
                process.stop_requested = true;
            },
            .kill_grace => if (self.processes.get(watch.id)) |process| {
                if (process.kill_grace_fd) |fd| drainTimerFd(fd);
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

    fn drainRequests(self: *Reactor, epfd: posix.fd_t) !void {
        self.requests.acknowledgeWake();
        var batch: [32]types.Request = undefined;
        while (true) {
            const count = self.requests.drainInto(&batch);
            if (count == 0) break;
            for (batch[0..count]) |*request| {
                defer request.deinit(self.allocator);
                switch (request.*) {
                    .spawn => |spawn_request| self.handleSpawn(epfd, spawn_request) catch |err| {
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

    fn handleSpawn(self: *Reactor, epfd: posix.fd_t, request: types.SpawnRequest) !void {
        if (self.processes.contains(request.id)) return error.DuplicateProcess;
        var process = Process.init(self.allocator, self.io, request) catch {
            _ = self.publish(.{ .spawn_failed = request.id });
            return;
        };
        errdefer process.forceReap(self.io);
        errdefer process.deinit(self.allocator, self.io);

        try registerFd(epfd, process.pidfd, encode(.process, process.id));
        if (process.stdout_file) |file| try registerFd(epfd, file.handle, encode(.stdout, process.id));
        if (process.stderr_file) |file| try registerFd(epfd, file.handle, encode(.stderr, process.id));
        if (process.cancel_fd) |fd| try registerFd(epfd, fd, encode(.cancel, process.id));
        if (process.timeout_fd) |fd| try registerFd(epfd, fd, encode(.timeout, process.id));

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

    fn applyControl(self: *Reactor, epfd: posix.fd_t) !void {
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
                if (process.kill_grace_fd == null) {
                    const fd = try timerFd(100);
                    process.kill_grace_fd = fd;
                    try registerFd(epfd, fd, encode(.kill_grace, process.id));
                }
            }
        }
        self.reapFinished();
    }

    fn handleProcessExit(self: *Reactor, epfd: posix.fd_t, process: *Process) void {
        if (!process.process_alive) return;
        unregisterFd(epfd, process.pidfd);
        process.term = process.child.wait(self.io) catch null;
        process.process_alive = false;
        process.closeStdin(self.io);
    }

    fn drainProcess(self: *Reactor, epfd: posix.fd_t, process: *Process, stream: Stream) !void {
        const file = switch (stream) {
            .stdout => process.stdout_file orelse return,
            .stderr => process.stderr_file orelse return,
        };
        var buf: [64 * 1024]u8 = undefined;
        const n = posix.read(file.handle, &buf) catch 0;
        if (n == 0) {
            unregisterFd(epfd, file.handle);
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
    pidfd: posix.fd_t,
    stdin_file: ?std.Io.File,
    stdout_file: ?std.Io.File,
    stderr_file: ?std.Io.File,
    timeout_fd: ?posix.fd_t,
    kill_grace_fd: ?posix.fd_t = null,
    cancel_fd: ?posix.fd_t,
    stdout_open: bool,
    stderr_open: bool,
    process_alive: bool = true,
    stop_requested: bool = false,
    stopping: bool = false,
    timed_out: bool = false,
    aborted: bool = false,
    term: ?std.process.Child.Term = null,

    fn init(allocator: std.mem.Allocator, io: std.Io, request: types.SpawnRequest) !Process {
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
        errdefer if (child.id) |pid| process_common.killChild(pid, owned.process_group, .KILL);
        errdefer _ = child.wait(io) catch null;

        const pidfd = try pidFdOpen(child.id.?);
        errdefer closeFd(pidfd);
        const timeout_fd = if (owned.timeout_ms) |ms| try timerFd(ms) else null;
        errdefer if (timeout_fd) |fd| closeFd(fd);
        const cancel_fd = try owned.signal.ensureWake();

        const stdin_file = child.stdin;
        const stdout_file = child.stdout;
        const stderr_file = child.stderr;
        child.stdin = null;
        child.stdout = null;
        child.stderr = null;
        return .{
            .id = owned.id,
            .request = owned,
            .child = child,
            .pid = child.id.?,
            .pidfd = pidfd,
            .stdin_file = stdin_file,
            .stdout_file = stdout_file,
            .stderr_file = stderr_file,
            .timeout_fd = timeout_fd,
            .cancel_fd = cancel_fd,
            .stdout_open = stdout_file != null,
            .stderr_open = stderr_file != null,
        };
    }

    fn deinit(self: *Process, allocator: std.mem.Allocator, io: std.Io) void {
        self.closeStdin(io);
        self.closeStdout(io);
        self.closeStderr(io);
        closeFd(self.pidfd);
        if (self.timeout_fd) |fd| closeFd(fd);
        if (self.kill_grace_fd) |fd| closeFd(fd);
        self.request.deinit(allocator);
        self.* = undefined;
    }

    fn forceReap(self: *Process, io: std.Io) void {
        if (!self.process_alive) return;
        process_common.killChild(self.pid, self.request.process_group, .KILL);
        _ = self.child.wait(io) catch null;
        self.process_alive = false;
    }

    fn closeStdin(self: *Process, io: std.Io) void {
        if (self.stdin_file) |file| file.close(io);
        self.stdin_file = null;
    }

    fn closeStdout(self: *Process, io: std.Io) void {
        if (self.stdout_file) |file| file.close(io);
        self.stdout_file = null;
        self.stdout_open = false;
    }

    fn closeStderr(self: *Process, io: std.Io) void {
        if (self.stderr_file) |file| file.close(io);
        self.stderr_file = null;
        self.stderr_open = false;
    }
};

fn encode(kind: WatchKind, id: types.ProcessId) u64 {
    return (@as(u64, @intCast(id)) << 3) | @intFromEnum(kind);
}

fn decode(value: u64) Watch {
    return .{ .kind = @enumFromInt(value & 0x7), .id = @intCast(value >> 3) };
}

fn epollCreate() !posix.fd_t {
    return @intCast(try syscallResult(linux.epoll_create1(linux.EPOLL.CLOEXEC)));
}

fn pidFdOpen(pid: std.process.Child.Id) !posix.fd_t {
    return @intCast(try syscallResult(linux.pidfd_open(@intCast(pid), 0)));
}

fn timerFd(ms: u64) !posix.fd_t {
    const fd: posix.fd_t = @intCast(try syscallResult(linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true, .NONBLOCK = true })));
    errdefer closeFd(fd);
    var spec = linux.itimerspec{
        .it_interval = .{ .sec = 0, .nsec = 0 },
        .it_value = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) },
    };
    if (ms == 0) spec.it_value.nsec = 1;
    _ = try syscallResult(linux.timerfd_settime(fd, .{}, &spec, null));
    return fd;
}

fn registerFd(epfd: posix.fd_t, fd: posix.fd_t, udata: u64) !void {
    var ev = linux.epoll_event{
        .events = linux.EPOLL.IN | linux.EPOLL.HUP | linux.EPOLL.ERR | linux.EPOLL.RDHUP,
        .data = .{ .u64 = udata },
    };
    _ = try syscallResult(linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, fd, &ev));
}

fn unregisterFd(epfd: posix.fd_t, fd: posix.fd_t) void {
    _ = linux.epoll_ctl(epfd, linux.EPOLL.CTL_DEL, fd, null);
}

fn epollWait(epfd: posix.fd_t, events: *[32]linux.epoll_event) !usize {
    while (true) {
        const rc = linux.epoll_wait(epfd, events, events.len, -1);
        switch (posix.errno(rc)) {
            .SUCCESS => return rc,
            .INTR => continue,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

fn drainTimerFd(fd: posix.fd_t) void {
    var value: u64 = 0;
    _ = posix.read(fd, std.mem.asBytes(&value)) catch {};
}

fn syscallResult(rc: usize) !usize {
    return switch (posix.errno(rc)) {
        .SUCCESS => rc,
        else => |err| posix.unexpectedErrno(err),
    };
}

fn closeFd(fd: posix.fd_t) void {
    _ = std.c.close(fd);
}
