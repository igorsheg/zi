const std = @import("std");
const builtin = @import("builtin");
const process_common = @import("process_common.zig");
const process_env = @import("process_env.zig");
const types = @import("process_engine_types.zig");
const cancel_waiter = @import("cancel_waiter.zig");
const logging = @import("../logging.zig");

pub const EnvPair = types.EnvPair;
pub const StreamKind = types.StreamKind;
pub const Event = types.Event;
pub const EventSink = types.EventSink;
pub const StartRequest = types.StartRequest;

const Watch = enum(usize) { stdout = 1, stderr = 2, process = 3, timeout = 4, kill_grace = 5, wake = 6 };

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
    kq: ?std.posix.fd_t = null,
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
        const kq = self.kq;
        self.mutex.unlock(self.io);
        if (kq) |fd| triggerWake(fd);
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
        const kq = self.kq;
        self.mutex.unlock(self.io);
        if (kq) |fd| triggerWake(fd);
    }

    fn run(self: *Engine) void {
        comptime std.debug.assert(builtin.os.tag == .macos or builtin.os.tag == .ios or builtin.os.tag == .visionos);
        logging.setThreadLabel(.process_engine);

        var env_map_storage = process_env.buildMap(std.heap.page_allocator, self.request.env, self.request.clear_env) catch {
            _ = self.sink.submit(self.sink.ptr, .spawn_failed);
            self.markExited();
            return;
        };
        defer if (env_map_storage) |*env_map| env_map.deinit();

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
        const kq = std.c.kqueue();
        if (kq < 0) return error.KqueueFailed;
        self.mutex.lockUncancelable(self.io);
        self.kq = kq;
        self.mutex.unlock(self.io);
        self.cancel_waiter = try cancel_waiter.Waiter.start(self.io, self.request.signal, .{ .ptr = @ptrCast(self), .call = onCancel });
        defer {
            self.cancel_waiter.stop();

            self.mutex.lockUncancelable(self.io);
            self.kq = null;
            self.mutex.unlock(self.io);
            _ = std.c.close(kq);
        }

        const stdout_file = child.stdout;
        const stderr_file = child.stderr;
        child.stdout = null;
        child.stderr = null;
        defer if (stdout_file) |file| file.close(self.io);
        defer if (stderr_file) |file| file.close(self.io);

        const child_pid = child.id.?;
        try registerProcess(kq, child_pid);
        if (stdout_file) |file| try registerRead(kq, file.handle, .stdout);
        if (stderr_file) |file| try registerRead(kq, file.handle, .stderr);
        try registerUser(kq);
        if (self.request.timeout_ms) |ms| try registerTimer(kq, .timeout, ms);

        var stdout_open = stdout_file != null;
        var stderr_open = stderr_file != null;
        var process_alive = true;
        var term: ?std.process.Child.Term = null;
        var stopping = false;
        var kill_grace_armed = false;

        while (process_alive or stdout_open or stderr_open) {
            var events: [8]std.posix.Kevent = undefined;
            const n = try std.Io.Kqueue.kevent(kq, &.{}, &events, null);
            for (events[0..n]) |ev| {
                const which: Watch = @enumFromInt(ev.udata);
                switch (which) {
                    .wake => {},
                    .timeout => {
                        self.mutex.lockUncancelable(self.io);
                        self.timed_out = true;
                        self.stop_requested = true;
                        self.mutex.unlock(self.io);
                    },
                    .kill_grace => if (process_alive or stdout_open or stderr_open) {
                        process_common.killChild(child_pid, self.request.process_group, .KILL);
                    },
                    .stdout => if (stdout_file) |file| {
                        if (!self.drain(file, .stdout)) stdout_open = false;
                    },
                    .stderr => if (stderr_file) |file| {
                        if (!self.drain(file, .stderr)) stderr_open = false;
                    },
                    .process => if (process_alive) {
                        term = child.wait(self.io) catch null;
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
                if (!kill_grace_armed) {
                    try registerTimer(kq, .kill_grace, 100);
                    kill_grace_armed = true;
                }
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
        const kq = self.kq;
        self.mutex.unlock(self.io);
        if (kq) |fd| triggerWake(fd);
    }
};

fn registerProcess(kq: std.posix.fd_t, pid: std.process.Child.Id) !void {
    const changes = [1]std.posix.Kevent{.{
        .ident = @bitCast(@as(isize, @intCast(pid))),
        .filter = std.c.EVFILT.PROC,
        .flags = std.c.EV.ADD | std.c.EV.ENABLE | std.c.EV.ONESHOT,
        .fflags = std.c.NOTE.EXIT | std.c.NOTE.EXITSTATUS,
        .data = 0,
        .udata = @intFromEnum(Watch.process),
    }};
    _ = try std.Io.Kqueue.kevent(kq, &changes, &.{}, null);
}

fn registerRead(kq: std.posix.fd_t, fd: std.posix.fd_t, watch: Watch) !void {
    const changes = [1]std.posix.Kevent{.{
        .ident = @bitCast(@as(isize, fd)),
        .filter = std.c.EVFILT.READ,
        .flags = std.c.EV.ADD | std.c.EV.ENABLE,
        .fflags = 0,
        .data = 0,
        .udata = @intFromEnum(watch),
    }};
    _ = try std.Io.Kqueue.kevent(kq, &changes, &.{}, null);
}

fn registerTimer(kq: std.posix.fd_t, watch: Watch, ms: u64) !void {
    const changes = [1]std.posix.Kevent{.{
        .ident = @intFromEnum(watch),
        .filter = std.c.EVFILT.TIMER,
        .flags = std.c.EV.ADD | std.c.EV.ENABLE | std.c.EV.ONESHOT,
        .fflags = 0,
        .data = @intCast(ms),
        .udata = @intFromEnum(watch),
    }};
    _ = try std.Io.Kqueue.kevent(kq, &changes, &.{}, null);
}

fn registerUser(kq: std.posix.fd_t) !void {
    const changes = [1]std.posix.Kevent{.{
        .ident = @intFromEnum(Watch.wake),
        .filter = std.c.EVFILT.USER,
        .flags = std.c.EV.ADD | std.c.EV.ENABLE | std.c.EV.CLEAR,
        .fflags = std.c.NOTE.FFNOP,
        .data = 0,
        .udata = @intFromEnum(Watch.wake),
    }};
    _ = try std.Io.Kqueue.kevent(kq, &changes, &.{}, null);
}

fn triggerWake(kq: std.posix.fd_t) void {
    const changes = [1]std.posix.Kevent{.{
        .ident = @intFromEnum(Watch.wake),
        .filter = std.c.EVFILT.USER,
        .flags = 0,
        .fflags = std.c.NOTE.TRIGGER,
        .data = 0,
        .udata = @intFromEnum(Watch.wake),
    }};
    _ = std.Io.Kqueue.kevent(kq, &changes, &.{}, null) catch {};
}
