const std = @import("std");
const builtin = @import("builtin");
const process_common = @import("process_common.zig");
const types = @import("process_engine_types.zig");
const cancel_waiter = @import("cancel_waiter.zig");

const linux = std.os.linux;

pub const EnvPair = types.EnvPair;
pub const StreamKind = types.StreamKind;
pub const Event = types.Event;
pub const EventSink = types.EventSink;
pub const StartRequest = types.StartRequest;

const Watch = enum(u64) { stdout = 1, stderr = 2, process = 3, timeout = 4, kill_grace = 5, wake = 6 };

pub const Engine = struct {
    io: std.Io,
    request: StartRequest,
    sink: EventSink,
    thread: ?std.Thread = null,
    started: bool = false,
    mutex: std.Io.Mutex = .init,
    child_id: ?std.process.Child.Id = null,
    stdin_file: ?std.Io.File = null,
    ready: bool = false,
    exited: bool = false,
    close_stdin_requested: bool = false,
    stop_requested: bool = false,
    timed_out: bool = false,
    aborted: bool = false,
    wake_fd: ?std.posix.fd_t = null,
    cancel_waiter: cancel_waiter.Waiter = .{},

    pub const StopReason = enum { requested, timeout, abort };

    pub fn init(io: std.Io, request: StartRequest, sink: EventSink) Engine {
        return .{ .io = io, .request = request, .sink = sink };
    }

    pub fn start(self: *Engine) !void {
        if (self.started) return;
        std.debug.assert(!self.ready and !self.exited);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        self.started = true;
    }

    pub fn join(self: *Engine) void {
        if (!self.started) return;
        if (self.thread) |thread| thread.join();
        self.thread = null;
        self.started = false;
    }

    pub fn stop(self: *Engine) void {
        self.stopWithReason(.requested);
    }

    pub fn stopWithReason(self: *Engine, reason: StopReason) void {
        self.mutex.lockUncancelable(self.io);
        self.stop_requested = true;
        switch (reason) {
            .requested => {},
            .timeout => self.timed_out = true,
            .abort => self.aborted = true,
        }
        const wake_fd = self.wake_fd;
        self.mutex.unlock(self.io);
        if (wake_fd) |fd| triggerWake(fd);
    }

    pub fn didTimeout(self: *Engine) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.timed_out;
    }

    pub fn didAbort(self: *Engine) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.aborted;
    }

    pub fn childId(self: *Engine) ?std.process.Child.Id {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.child_id;
    }

    pub fn isExited(self: *Engine) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.exited;
    }

    pub fn waitReady(self: *Engine, timeout_ms: u64) bool {
        var waited: u64 = 0;
        while (waited <= timeout_ms) : (waited += 1) {
            self.mutex.lockUncancelable(self.io);
            const ready = self.ready;
            const exited = self.exited;
            self.mutex.unlock(self.io);
            if (ready) return true;
            if (exited) return false;
            self.io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
        return false;
    }

    pub fn write(self: *Engine, data: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        const file = self.stdin_file orelse {
            self.mutex.unlock(self.io);
            return error.ProcessNotReady;
        };
        self.mutex.unlock(self.io);
        try file.writeStreamingAll(self.io, data);
    }

    pub fn closeStdin(self: *Engine) void {
        self.mutex.lockUncancelable(self.io);
        self.close_stdin_requested = true;
        const wake_fd = self.wake_fd;
        self.mutex.unlock(self.io);
        if (wake_fd) |fd| triggerWake(fd);
    }

    fn run(self: *Engine) void {
        comptime std.debug.assert(builtin.os.tag == .linux);

        var env_map_storage: ?std.process.Environ.Map = null;
        defer if (env_map_storage) |*env_map| env_map.deinit();
        if (self.request.env.len > 0 or self.request.clear_env) {
            env_map_storage = std.process.Environ.Map.init(std.heap.page_allocator);
            for (self.request.env) |pair| {
                env_map_storage.?.put(pair.key, pair.value) catch {
                    _ = self.sink.submit(self.sink.ptr, .spawn_failed);
                    self.markExited();
                    return;
                };
            }
        }

        var child = std.process.spawn(self.io, .{
            .argv = self.request.argv,
            .cwd = if (self.request.cwd) |cwd| .{ .path = cwd } else .inherit,
            .environ_map = if (env_map_storage) |*env_map| env_map else null,
            .stdin = if (self.request.stdin) .pipe else .ignore,
            .stdout = if (self.request.stdout) .pipe else .ignore,
            .stderr = if (self.request.stderr) .pipe else .ignore,
            .pgid = if (self.request.process_group and process_common.supportsProcessGroups()) 0 else null,
        }) catch {
            _ = self.sink.submit(self.sink.ptr, .spawn_failed);
            self.markExited();
            return;
        };
        defer if (child.stdin) |stdin_file| stdin_file.close(self.io);

        self.mutex.lockUncancelable(self.io);
        self.child_id = child.id;
        self.stdin_file = child.stdin;
        self.ready = true;
        self.mutex.unlock(self.io);

        self.runLoop(&child) catch {
            if (child.id) |pid| process_common.killChild(pid, self.request.process_group, .KILL);
            _ = child.wait(self.io) catch null;
            _ = self.sink.submit(self.sink.ptr, .spawn_failed);
            self.markExited();
            return;
        };
    }

    fn runLoop(self: *Engine, child: *std.process.Child) !void {
        const epfd = try epollCreate();
        defer closeFd(epfd);

        const wake_fd = try eventFd();
        defer closeFd(wake_fd);

        const pidfd = try pidFdOpen(child.id.?);
        defer closeFd(pidfd);

        const timeout_fd = if (self.request.timeout_ms) |ms| try timerFd(ms) else null;
        defer if (timeout_fd) |fd| closeFd(fd);

        var kill_grace_fd: ?std.posix.fd_t = null;
        defer if (kill_grace_fd) |fd| closeFd(fd);

        self.mutex.lockUncancelable(self.io);
        self.wake_fd = wake_fd;
        self.mutex.unlock(self.io);
        self.cancel_waiter = try cancel_waiter.Waiter.start(self.io, self.request.signal, .{ .ptr = @ptrCast(self), .call = onCancel });
        defer {
            self.cancel_waiter.stop();

            self.mutex.lockUncancelable(self.io);
            self.wake_fd = null;
            self.mutex.unlock(self.io);
        }

        const stdout_file = child.stdout;
        const stderr_file = child.stderr;
        child.stdout = null;
        child.stderr = null;
        defer if (stdout_file) |file| file.close(self.io);
        defer if (stderr_file) |file| file.close(self.io);

        const child_pid = child.id.?;
        try registerFd(epfd, pidfd, .process);
        try registerFd(epfd, wake_fd, .wake);
        if (timeout_fd) |fd| try registerFd(epfd, fd, .timeout);
        if (stdout_file) |file| try registerFd(epfd, file.handle, .stdout);
        if (stderr_file) |file| try registerFd(epfd, file.handle, .stderr);

        var stdout_open = stdout_file != null;
        var stderr_open = stderr_file != null;
        var process_alive = true;
        var term: ?std.process.Child.Term = null;
        var stopping = false;

        while (process_alive or stdout_open or stderr_open) {
            var events: [8]linux.epoll_event = undefined;
            const n = try epollWait(epfd, &events);
            for (events[0..n]) |ev| {
                const which: Watch = @enumFromInt(ev.data.u64);
                switch (which) {
                    .wake => drainEventFd(wake_fd),
                    .timeout => {
                        if (timeout_fd) |fd| drainTimerFd(fd);
                        self.mutex.lockUncancelable(self.io);
                        self.timed_out = true;
                        self.stop_requested = true;
                        self.mutex.unlock(self.io);
                    },
                    .kill_grace => {
                        if (kill_grace_fd) |fd| drainTimerFd(fd);
                        if (process_alive or stdout_open or stderr_open) process_common.killChild(child_pid, self.request.process_group, .KILL);
                    },
                    .stdout => if (stdout_file) |file| {
                        if (!self.drain(file, .stdout)) {
                            unregisterFd(epfd, file.handle);
                            stdout_open = false;
                        }
                    },
                    .stderr => if (stderr_file) |file| {
                        if (!self.drain(file, .stderr)) {
                            unregisterFd(epfd, file.handle);
                            stderr_open = false;
                        }
                    },
                    .process => if (process_alive) {
                        term = child.wait(self.io) catch null;
                        unregisterFd(epfd, pidfd);
                        process_alive = false;
                        self.mutex.lockUncancelable(self.io);
                        self.stdin_file = null;
                        self.exited = true;
                        self.mutex.unlock(self.io);
                    },
                }
            }

            const control = self.controlSnapshot();
            if (control.close_stdin) self.closeChildStdin(child);
            if (control.should_stop and !stopping) {
                stopping = true;
                process_common.killChild(child_pid, self.request.process_group, .TERM);
                const fd = try timerFd(100);
                kill_grace_fd = fd;
                try registerFd(epfd, fd, .kill_grace);
            }
        }

        self.mutex.lockUncancelable(self.io);
        self.child_id = null;
        self.mutex.unlock(self.io);
        _ = self.sink.submit(self.sink.ptr, .{ .exit = term });
    }

    const Control = struct { close_stdin: bool, should_stop: bool };

    fn controlSnapshot(self: *Engine) Control {
        self.mutex.lockUncancelable(self.io);
        const close_stdin = self.close_stdin_requested;
        var should_stop = self.stop_requested;
        if (!should_stop and self.request.signal.isAborted()) {
            self.aborted = true;
            self.stop_requested = true;
            should_stop = true;
        }
        self.mutex.unlock(self.io);
        return .{ .close_stdin = close_stdin, .should_stop = should_stop };
    }

    fn closeChildStdin(self: *Engine, child: *std.process.Child) void {
        if (child.stdin) |stdin_file| {
            stdin_file.close(self.io);
            child.stdin = null;
            self.mutex.lockUncancelable(self.io);
            self.stdin_file = null;
            self.mutex.unlock(self.io);
        }
    }

    fn drain(self: *Engine, file: std.Io.File, kind: StreamKind) bool {
        var buf: [64 * 1024]u8 = undefined;
        const n = std.posix.read(file.handle, &buf) catch return false;
        if (n == 0) return false;
        _ = self.sink.submit(self.sink.ptr, switch (kind) {
            .stdout => .{ .stdout = buf[0..n] },
            .stderr => .{ .stderr = buf[0..n] },
        });
        return true;
    }

    fn markExited(self: *Engine) void {
        self.mutex.lockUncancelable(self.io);
        self.exited = true;
        self.mutex.unlock(self.io);
    }

    fn onCancel(ptr: *anyopaque) void {
        const self: *Engine = @ptrCast(@alignCast(ptr));
        self.mutex.lockUncancelable(self.io);
        self.aborted = true;
        self.stop_requested = true;
        const wake_fd = self.wake_fd;
        self.mutex.unlock(self.io);
        if (wake_fd) |fd| triggerWake(fd);
    }
};

fn epollCreate() !std.posix.fd_t {
    const rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
    return @intCast(try syscallResult(rc));
}

fn pidFdOpen(pid: std.process.Child.Id) !std.posix.fd_t {
    const rc = linux.pidfd_open(@intCast(pid), 0);
    return @intCast(try syscallResult(rc));
}

fn eventFd() !std.posix.fd_t {
    const rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    return @intCast(try syscallResult(rc));
}

fn timerFd(ms: u64) !std.posix.fd_t {
    const fd: std.posix.fd_t = @intCast(try syscallResult(linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true, .NONBLOCK = true })));
    errdefer closeFd(fd);
    var spec = linux.itimerspec{
        .it_interval = .{ .sec = 0, .nsec = 0 },
        .it_value = .{
            .sec = @intCast(ms / 1000),
            .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
        },
    };
    if (ms == 0) spec.it_value.nsec = 1;
    _ = try syscallResult(linux.timerfd_settime(fd, .{}, &spec, null));
    return fd;
}

fn registerFd(epfd: std.posix.fd_t, fd: std.posix.fd_t, watch: Watch) !void {
    var ev = linux.epoll_event{
        .events = linux.EPOLL.IN | linux.EPOLL.HUP | linux.EPOLL.ERR,
        .data = .{ .u64 = @intFromEnum(watch) },
    };
    _ = try syscallResult(linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, fd, &ev));
}

fn unregisterFd(epfd: std.posix.fd_t, fd: std.posix.fd_t) void {
    _ = linux.epoll_ctl(epfd, linux.EPOLL.CTL_DEL, fd, null);
}

fn epollWait(epfd: std.posix.fd_t, events: *[8]linux.epoll_event) !usize {
    while (true) {
        const rc = linux.epoll_wait(epfd, events, events.len, -1);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return rc,
            .INTR => continue,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

fn drainTimerFd(fd: std.posix.fd_t) void {
    var value: u64 = 0;
    _ = std.posix.read(fd, std.mem.asBytes(&value)) catch {};
}

fn drainEventFd(fd: std.posix.fd_t) void {
    var value: u64 = 0;
    _ = std.posix.read(fd, std.mem.asBytes(&value)) catch {};
}

fn triggerWake(fd: std.posix.fd_t) void {
    var value: u64 = 1;
    const bytes = std.mem.asBytes(&value);
    _ = linux.write(fd, bytes.ptr, bytes.len);
}

fn syscallResult(rc: usize) !usize {
    return switch (std.posix.errno(rc)) {
        .SUCCESS => rc,
        else => |err| std.posix.unexpectedErrno(err),
    };
}

fn closeFd(fd: std.posix.fd_t) void {
    _ = std.c.close(fd);
}
