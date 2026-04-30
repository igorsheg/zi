const builtin = @import("builtin");
const std = @import("std");
const AbortSignal = @import("abort_signal.zig").AbortSignal;

/// Cooperative abort guard — blocks on an AbortSignal and executes
/// cleanup actions when abort is requested.
///
/// Covers two abort actions (independently optional):
///   - shutdown_fd: calls shutdown(SHUT_RDWR) to unblock blocking reads
///     on a socket. Used by HTTP providers during streaming.
///   - kill_pid: sends SIGKILL to one child pid.
///   - interrupt_process_group: sends SIGINT, waits a short grace
///     period, then SIGKILLs the entire child process group. Used by
///     bash/spawn so Ctrl+C semantics reach grandchildren too.
///
/// Usage:
///   var guard = AbortGuard.start(signal, .{ .shutdown_fd = fd });
///   defer guard.stop();
///   // ... blocking I/O ...
pub const AbortGuard = struct {
    /// Heap-allocated so the pointer survives return-by-value from start().
    /// The watchdog thread holds a pointer to this; if it lived inline in
    /// the struct, returning from start() would copy the struct and leave
    /// the watchdog with a dangling pointer to the old stack frame.
    shared_done: *std.atomic.Value(bool),
    thread: ?std.Thread,
    allocator: std.mem.Allocator,
    signal: AbortSignal,
    io: std.Io,

    pub const Actions = struct {
        shutdown_fd: ?std.posix.fd_t = null,
        kill_pid: ?std.process.Child.Id = null,
        interrupt_process_group: ?std.process.Child.Id = null,
    };

    /// Return the underlying TCP socket fd for Zig 0.16 std.http requests.
    ///
    /// std.http no longer exposes the old `stream_reader.getStream()` path,
    /// but the request still owns a `Connection` while the body is being sent
    /// and read. AbortGuard only uses this fd for `shutdown(SHUT_RDWR)` from a
    /// watchdog thread to unblock an in-flight network read/write; ownership
    /// remains with the http request/connection.
    pub fn httpRequestShutdownFd(req: anytype) ?std.posix.fd_t {
        const conn = req.connection orelse return null;
        return conn.stream_reader.stream.socket.handle;
    }

    /// Spawn the watchdog. No-ops (no thread) when the signal is inert
    /// or all actions are null.
    pub fn start(signal: AbortSignal, actions: Actions) AbortGuard {
        return startWithIo(std.Options.debug_io, signal, actions);
    }

    pub fn startWithIo(io: std.Io, signal: AbortSignal, actions: Actions) AbortGuard {
        if (signal.isNone() or
            (actions.shutdown_fd == null and actions.kill_pid == null and actions.interrupt_process_group == null))
        {
            return .{
                .shared_done = &noop_done,
                .thread = null,
                .allocator = std.heap.page_allocator,
                .signal = AbortSignal.none,
                .io = io,
            };
        }
        const done = std.heap.page_allocator.create(std.atomic.Value(bool)) catch {
            return .{
                .shared_done = &noop_done,
                .thread = null,
                .allocator = std.heap.page_allocator,
                .signal = AbortSignal.none,
                .io = io,
            };
        };
        done.* = std.atomic.Value(bool).init(false);
        const ctx = WatchdogCtx{
            .signal = signal,
            .done = done,
            .shutdown_fd = actions.shutdown_fd,
            .kill_pid = actions.kill_pid,
            .interrupt_process_group = actions.interrupt_process_group,
            .io = io,
        };
        const thread = std.Thread.spawn(.{}, watchdog, .{ctx}) catch null;
        return .{
            .shared_done = done,
            .thread = thread,
            .allocator = std.heap.page_allocator,
            .signal = signal,
            .io = io,
        };
    }

    /// Signal the watchdog to exit and join it. Must be called before
    /// closing/deiniting the guarded resource (socket, child process).
    pub fn stop(self: *AbortGuard) void {
        self.shared_done.store(true, .release);
        self.signal.notifyWaiters();
        if (self.thread) |t| t.join();
        self.thread = null;
        if (self.shared_done != &noop_done) {
            self.allocator.destroy(self.shared_done);
        }
    }

    var noop_done = std.atomic.Value(bool).init(true);

    const WatchdogCtx = struct {
        signal: AbortSignal,
        done: *std.atomic.Value(bool),
        shutdown_fd: ?std.posix.fd_t,
        kill_pid: ?std.process.Child.Id,
        interrupt_process_group: ?std.process.Child.Id,
        io: std.Io,
    };

    fn watchdog(ctx: WatchdogCtx) void {
        switch (ctx.signal.waitUntil(null, &donePredicate, @ptrCast(ctx.done))) {
            .aborted => {},
            .predicate, .timeout, .none => return,
        }

        if (ctx.done.load(.acquire)) return;

        if (ctx.shutdown_fd) |fd| {
            const SHUT_RDWR = 2;
            _ = std.posix.system.shutdown(fd, SHUT_RDWR);
        }
        if (ctx.interrupt_process_group) |pgid| {
            interruptProcessGroup(ctx.io, pgid);
        }
        if (ctx.kill_pid) |pid| {
            std.posix.kill(pid, std.posix.SIG.KILL) catch {};
        }
    }

    fn donePredicate(ctx: ?*anyopaque) bool {
        const done: *std.atomic.Value(bool) = @ptrCast(@alignCast(ctx.?));
        return done.load(.acquire);
    }

    fn interruptProcessGroup(io: std.Io, pgid: std.process.Child.Id) void {
        if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {
            std.posix.kill(pgid, std.posix.SIG.KILL) catch {};
            return;
        }
        signalProcessGroup(pgid, std.posix.SIG.INT);
        io.sleep(.fromNanoseconds(150 * std.time.ns_per_ms), .awake) catch {};
        signalProcessGroup(pgid, std.posix.SIG.KILL);
    }

    fn signalProcessGroup(pgid: std.process.Child.Id, sig: std.posix.SIG) void {
        if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {
            std.posix.kill(pgid, sig) catch {};
            return;
        }
        const group_pid: std.posix.pid_t = -@as(std.posix.pid_t, @intCast(pgid));
        std.posix.kill(group_pid, sig) catch {};
    }
};
