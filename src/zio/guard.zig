const builtin = @import("builtin");
const std = @import("std");

const abort_signal_mod = @import("abort_signal.zig");
pub const AbortSignal = abort_signal_mod.AbortSignal;
pub const AbortController = abort_signal_mod.AbortController;

pub const AbortCallback = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (ctx: ?*anyopaque) void,
};

/// One watchdog primitive for interrupting blocking resources.
///
/// The guard waits for abort, timeout, or owner-done. On abort/timeout it runs
/// the configured mechanical interruption actions, then joins in `stop()` before
/// the protected resource is destroyed.
pub const InterruptGuard = struct {
    state: *State,
    thread: ?std.Thread,
    signal: AbortSignal,
    io: std.Io,

    pub const Actions = struct {
        shutdown_fd: ?std.posix.fd_t = null,
        kill_pid: ?std.process.Child.Id = null,
        kill_process_group: ?std.process.Child.Id = null,
        interrupt_process_group: ?std.process.Child.Id = null,
        callback: ?AbortCallback = null,
    };

    pub const Options = struct {
        signal: AbortSignal = AbortSignal.none,
        timeout_ms: ?u64 = null,
        actions: Actions = .{},
    };

    const State = struct {
        done: std.atomic.Value(bool) = .init(false),
        done_event: std.Io.Event = .unset,
        did_timeout: std.atomic.Value(bool) = .init(false),
    };

    var noop_state = State{ .done = .init(true), .done_event = .is_set };

    pub fn httpRequestShutdownFd(req: anytype) ?std.posix.fd_t {
        const conn = req.connection orelse return null;
        return conn.stream_reader.stream.socket.handle;
    }

    pub fn start(io: std.Io, options: Options) !InterruptGuard {
        if (options.signal.isNone() and options.timeout_ms == null and isNoopActions(options.actions)) {
            return noop(io);
        }
        if (options.signal.isNone() and options.timeout_ms == null) return noop(io);

        const state = try std.heap.page_allocator.create(State);
        state.* = .{};
        const ctx = WatchdogCtx{
            .signal = options.signal,
            .state = state,
            .timeout_ms = options.timeout_ms,
            .actions = options.actions,
            .io = io,
        };
        const thread = std.Thread.spawn(.{}, watchdog, .{ctx}) catch |err| {
            std.heap.page_allocator.destroy(state);
            return err;
        };
        return .{ .state = state, .thread = thread, .signal = options.signal, .io = io };
    }

    pub fn markDone(self: *InterruptGuard) void {
        self.state.done.store(true, .release);
        self.state.done_event.set(self.io);
        self.signal.notifyWaiters();
    }

    pub fn stop(self: *InterruptGuard) void {
        self.markDone();
        if (self.thread) |thread| thread.join();
        if (self.state != &noop_state) std.heap.page_allocator.destroy(self.state);
        self.state = &noop_state;
        self.thread = null;
        self.signal = AbortSignal.none;
    }

    pub fn didTimeout(self: *const InterruptGuard) bool {
        return self.state.did_timeout.load(.acquire);
    }

    fn noop(io: std.Io) InterruptGuard {
        return .{ .state = &noop_state, .thread = null, .signal = AbortSignal.none, .io = io };
    }

    fn isNoopActions(actions: Actions) bool {
        return actions.shutdown_fd == null and actions.kill_pid == null and actions.kill_process_group == null and actions.interrupt_process_group == null and actions.callback == null;
    }

    const WatchdogCtx = struct {
        signal: AbortSignal,
        state: *State,
        timeout_ms: ?u64,
        actions: Actions,
        io: std.Io,
    };

    const Trigger = enum { aborted, timeout };

    fn watchdog(ctx: WatchdogCtx) void {
        const trigger = waitForTrigger(ctx) orelse return;
        if (ctx.state.done.load(.acquire)) return;
        if (trigger == .timeout) ctx.state.did_timeout.store(true, .release);
        runActions(ctx.io, ctx.actions);
    }

    fn waitForTrigger(ctx: WatchdogCtx) ?Trigger {
        if (ctx.signal.isNone()) {
            const ms = ctx.timeout_ms orelse return null;
            ctx.state.done_event.waitTimeout(ctx.io, .{ .duration = .{ .raw = .fromMilliseconds(@intCast(ms)), .clock = .boot } }) catch |err| switch (err) {
                error.Timeout => return .timeout,
                error.Canceled => return null,
            };
            return null;
        }

        const timeout_ns = if (ctx.timeout_ms) |ms| ms * std.time.ns_per_ms else null;
        return switch (ctx.signal.waitUntilIo(ctx.io, timeout_ns, donePredicate, @ptrCast(ctx.state))) {
            .aborted => .aborted,
            .timeout => .timeout,
            .predicate, .none => null,
        };
    }

    fn donePredicate(ctx: ?*anyopaque) bool {
        const state: *State = @ptrCast(@alignCast(ctx.?));
        return state.done.load(.acquire);
    }

    fn runActions(io: std.Io, actions: Actions) void {
        if (actions.shutdown_fd) |fd| {
            const SHUT_RDWR = 2;
            _ = std.posix.system.shutdown(fd, SHUT_RDWR);
        }
        if (actions.interrupt_process_group) |pgid| interruptProcessGroup(io, pgid);
        if (actions.kill_process_group) |pgid| signalProcessGroup(pgid, std.posix.SIG.KILL);
        if (actions.kill_pid) |pid| std.posix.kill(pid, std.posix.SIG.KILL) catch {};
        if (actions.callback) |callback| callback.call(callback.ctx);
    }
};

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

test "InterruptGuard invokes callback on abort and joins on stop" {
    const Ctx = struct {
        called: std.atomic.Value(u32) = .init(0),

        fn callback(raw: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            _ = self.called.fetchAdd(1, .acq_rel);
        }
    };

    var controller = AbortController{};
    const signal = controller.beginRun();
    var ctx = Ctx{};
    var guard = try InterruptGuard.start(std.Options.debug_io, .{ .signal = signal, .actions = .{ .callback = .{ .ctx = @ptrCast(&ctx), .call = Ctx.callback } } });
    defer guard.stop();

    controller.requestAbort();
    var spins: usize = 0;
    while (ctx.called.load(.acquire) == 0 and spins < 1000) : (spins += 1) {
        std.Options.debug_io.sleep(.fromNanoseconds(std.time.ns_per_ms), .awake) catch {};
    }
    guard.stop();

    try std.testing.expectEqual(@as(u32, 1), ctx.called.load(.acquire));
}

test "InterruptGuard stop suppresses later abort callback" {
    const Ctx = struct {
        called: std.atomic.Value(u32) = .init(0),

        fn callback(raw: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            _ = self.called.fetchAdd(1, .acq_rel);
        }
    };

    var controller = AbortController{};
    const signal = controller.beginRun();
    var ctx = Ctx{};
    var guard = try InterruptGuard.start(std.Options.debug_io, .{ .signal = signal, .actions = .{ .callback = .{ .ctx = @ptrCast(&ctx), .call = Ctx.callback } } });
    guard.stop();

    controller.requestAbort();
    std.Options.debug_io.sleep(.fromNanoseconds(10 * std.time.ns_per_ms), .awake) catch {};

    try std.testing.expectEqual(@as(u32, 0), ctx.called.load(.acquire));
}
