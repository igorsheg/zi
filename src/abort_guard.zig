const builtin = @import("builtin");
const std = @import("std");
const AbortSignal = @import("abort_signal.zig").AbortSignal;

/// Cooperative abort guard — spawns a watchdog thread that polls an
/// AbortSignal every 100ms and executes cleanup actions on abort.
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

    pub const Actions = struct {
        shutdown_fd: ?std.posix.fd_t = null,
        kill_pid: ?std.process.Child.Id = null,
        interrupt_process_group: ?std.process.Child.Id = null,
    };

    /// Spawn the watchdog. No-ops (no thread) when the signal is inert
    /// or all actions are null.
    pub fn start(signal: AbortSignal, actions: Actions) AbortGuard {
        if (signal.isNone() or
            (actions.shutdown_fd == null and actions.kill_pid == null and actions.interrupt_process_group == null))
        {
            return .{ .shared_done = &noop_done, .thread = null, .allocator = std.heap.page_allocator };
        }
        const done = std.heap.page_allocator.create(std.atomic.Value(bool)) catch {
            return .{ .shared_done = &noop_done, .thread = null, .allocator = std.heap.page_allocator };
        };
        done.* = std.atomic.Value(bool).init(false);
        const ctx = WatchdogCtx{
            .signal = signal,
            .done = done,
            .shutdown_fd = actions.shutdown_fd,
            .kill_pid = actions.kill_pid,
            .interrupt_process_group = actions.interrupt_process_group,
        };
        const thread = std.Thread.spawn(.{}, watchdog, .{ctx}) catch null;
        return .{ .shared_done = done, .thread = thread, .allocator = std.heap.page_allocator };
    }

    /// Signal the watchdog to exit and join it. Must be called before
    /// closing/deiniting the guarded resource (socket, child process).
    pub fn stop(self: *AbortGuard) void {
        self.shared_done.store(true, .release);
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
    };

    fn watchdog(ctx: WatchdogCtx) void {
        while (true) {
            if (ctx.done.load(.acquire)) return;
            if (ctx.signal.isAborted()) break;
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
        if (ctx.done.load(.acquire)) return;

        if (ctx.shutdown_fd) |fd| {
            const SHUT_RDWR = 2;
            _ = std.posix.system.shutdown(fd, SHUT_RDWR);
        }
        if (ctx.interrupt_process_group) |pgid| {
            interruptProcessGroup(pgid);
        }
        if (ctx.kill_pid) |pid| {
            std.posix.kill(pid, std.posix.SIG.KILL) catch {};
        }
    }

    fn interruptProcessGroup(pgid: std.process.Child.Id) void {
        if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {
            std.posix.kill(pgid, std.posix.SIG.KILL) catch {};
            return;
        }
        signalProcessGroup(pgid, std.posix.SIG.INT);
        std.Thread.sleep(150 * std.time.ns_per_ms);
        signalProcessGroup(pgid, std.posix.SIG.KILL);
    }

    fn signalProcessGroup(pgid: std.process.Child.Id, sig: u8) void {
        if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {
            std.posix.kill(pgid, sig) catch {};
            return;
        }
        const group_pid: std.posix.pid_t = -@as(std.posix.pid_t, @intCast(pgid));
        std.posix.kill(group_pid, sig) catch {};
    }
};
