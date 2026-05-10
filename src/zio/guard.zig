const builtin = @import("builtin");
const std = @import("std");

const abort_signal_mod = @import("abort_signal.zig");
pub const AbortSignal = abort_signal_mod.AbortSignal;
pub const AbortController = abort_signal_mod.AbortController;

/// Resource interruption guard namespace.
///
/// This is the end-state home for watchdog-shaped code: wait for abort,
/// timeout, or owner-done, then interrupt the blocking resource and join before
/// that resource is destroyed.
pub const AbortGuard = struct {
    state: *State,
    thread: ?std.Thread,
    signal: AbortSignal,
    io: std.Io,

    pub const Actions = struct {
        shutdown_fd: ?std.posix.fd_t = null,
        kill_pid: ?std.process.Child.Id = null,
        interrupt_process_group: ?std.process.Child.Id = null,
    };

    pub fn httpRequestShutdownFd(req: anytype) ?std.posix.fd_t {
        const conn = req.connection orelse return null;
        return conn.stream_reader.stream.socket.handle;
    }

    pub fn start(io: std.Io, signal: AbortSignal, actions: AbortGuard.Actions) AbortGuard {
        if (signal.isNone() or
            (actions.shutdown_fd == null and actions.kill_pid == null and actions.interrupt_process_group == null))
        {
            return .{ .state = &noop_state, .thread = null, .signal = AbortSignal.none, .io = io };
        }
        const state = std.heap.page_allocator.create(State) catch return .{ .state = &noop_state, .thread = null, .signal = AbortSignal.none, .io = io };
        state.* = .{};
        const ctx = WatchdogCtx{
            .signal = signal,
            .state = state,
            .shutdown_fd = actions.shutdown_fd,
            .kill_pid = actions.kill_pid,
            .interrupt_process_group = actions.interrupt_process_group,
            .io = io,
        };
        const thread = std.Thread.spawn(.{}, watchdog, .{ctx}) catch null;
        if (thread == null) {
            std.heap.page_allocator.destroy(state);
            return .{ .state = &noop_state, .thread = null, .signal = AbortSignal.none, .io = io };
        }
        return .{ .state = state, .thread = thread, .signal = signal, .io = io };
    }

    pub fn stop(self: *AbortGuard) void {
        self.state.done.store(true, .release);
        self.signal.notifyWaiters();
        if (self.thread) |thread| thread.join();
        if (self.state != &noop_state) std.heap.page_allocator.destroy(self.state);
        self.state = &noop_state;
        self.thread = null;
        self.signal = AbortSignal.none;
    }

    const State = struct {
        done: std.atomic.Value(bool) = .init(false),
    };

    var noop_state = State{ .done = .init(true) };

    const WatchdogCtx = struct {
        signal: AbortSignal,
        state: *State,
        shutdown_fd: ?std.posix.fd_t,
        kill_pid: ?std.process.Child.Id,
        interrupt_process_group: ?std.process.Child.Id,
        io: std.Io,
    };

    fn watchdog(ctx: WatchdogCtx) void {
        switch (ctx.signal.waitUntilIo(ctx.io, null, donePredicate, @ptrCast(ctx.state))) {
            .aborted => {},
            .predicate, .timeout, .none => return,
        }

        if (ctx.state.done.load(.acquire)) return;

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
        const state: *State = @ptrCast(@alignCast(ctx.?));
        return state.done.load(.acquire);
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
};

pub const abort = AbortGuard;
pub const Actions = AbortGuard.Actions;

pub const AbortCallback = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (ctx: ?*anyopaque) void,
};

pub fn startAbort(io: std.Io, signal: AbortSignal, actions: Actions) AbortGuard {
    return AbortGuard.start(io, signal, actions);
}

pub const AbortCallbackGuard = struct {
    state: *State,
    thread: ?std.Thread,
    signal: AbortSignal,
    io: std.Io,

    const State = struct {
        done: std.atomic.Value(bool) = .init(false),
        callback: AbortCallback,
    };

    var noop_state = State{ .done = .init(true), .callback = .{ .call = noopCallback } };

    pub fn start(io: std.Io, signal: AbortSignal, callback: AbortCallback) AbortCallbackGuard {
        if (signal.isNone()) return .{ .state = &noop_state, .thread = null, .signal = AbortSignal.none, .io = io };
        const state = std.heap.page_allocator.create(State) catch return .{ .state = &noop_state, .thread = null, .signal = AbortSignal.none, .io = io };
        state.* = .{ .callback = callback };
        const thread = std.Thread.spawn(.{}, abortCallbackWatchdog, .{ io, signal, state }) catch null;
        if (thread == null) {
            std.heap.page_allocator.destroy(state);
            return .{ .state = &noop_state, .thread = null, .signal = AbortSignal.none, .io = io };
        }
        return .{ .state = state, .thread = thread, .signal = signal, .io = io };
    }

    pub fn stop(self: *AbortCallbackGuard) void {
        self.state.done.store(true, .release);
        self.signal.notifyWaiters();
        if (self.thread) |thread| thread.join();
        if (self.state != &noop_state) std.heap.page_allocator.destroy(self.state);
        self.state = &noop_state;
        self.thread = null;
        self.signal = AbortSignal.none;
    }

    fn abortCallbackWatchdog(io: std.Io, signal: AbortSignal, state: *State) void {
        switch (signal.waitUntilIo(io, null, donePredicate, @ptrCast(state))) {
            .aborted => {},
            .predicate, .timeout, .none => return,
        }
        if (!state.done.load(.acquire)) state.callback.call(state.callback.ctx);
    }

    fn donePredicate(ctx: ?*anyopaque) bool {
        const state: *State = @ptrCast(@alignCast(ctx.?));
        return state.done.load(.acquire);
    }

    fn noopCallback(_: ?*anyopaque) void {}
};

pub const TimeoutGuard = struct {
    io: std.Io,
    state: *TimeoutState,
    thread: ?std.Thread,

    const TimeoutState = struct {
        done: std.Io.Event = .unset,
        did_timeout: std.atomic.Value(bool) = .init(false),
    };

    pub fn start(io: std.Io, timeout_ms: ?u64, child_id: std.process.Child.Id, process_group: bool) TimeoutGuard {
        const ms = timeout_ms orelse return .{ .io = io, .state = &noop_state, .thread = null };
        const state = std.heap.page_allocator.create(TimeoutState) catch return .{ .io = io, .state = &noop_state, .thread = null };
        state.* = .{};
        const thread = std.Thread.spawn(.{}, watchdog, .{ io, ms, child_id, process_group, state }) catch null;
        if (thread == null) {
            std.heap.page_allocator.destroy(state);
            return .{ .io = io, .state = &noop_state, .thread = null };
        }
        return .{ .io = io, .state = state, .thread = thread };
    }

    pub fn markExited(self: *TimeoutGuard) void {
        self.state.done.set(self.io);
    }

    pub fn stop(self: *TimeoutGuard) void {
        self.state.done.set(self.io);
        if (self.thread) |thread| thread.join();
        if (self.state != &noop_state) std.heap.page_allocator.destroy(self.state);
        self.state = &noop_state;
        self.thread = null;
    }

    pub fn didTimeout(self: *const TimeoutGuard) bool {
        return self.state.did_timeout.load(.acquire);
    }

    fn watchdog(io: std.Io, timeout_ms: u64, child_id: std.process.Child.Id, process_group: bool, state: *TimeoutState) void {
        state.done.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(@intCast(timeout_ms)), .clock = .boot } }) catch |err| switch (err) {
            error.Timeout => {
                state.did_timeout.store(true, .release);
                if (process_group) killProcessGroup(child_id, std.posix.SIG.KILL) else std.posix.kill(child_id, std.posix.SIG.KILL) catch {};
            },
            error.Canceled => {},
        };
    }

    var noop_state: TimeoutState = .{ .done = .is_set };
};

fn signalProcessGroup(pgid: std.process.Child.Id, sig: std.posix.SIG) void {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        std.posix.kill(pgid, sig) catch {};
        return;
    }
    const group_pid: std.posix.pid_t = -@as(std.posix.pid_t, @intCast(pgid));
    std.posix.kill(group_pid, sig) catch {};
}

fn killProcessGroup(pgid: std.process.Child.Id, sig: std.posix.SIG) void {
    signalProcessGroup(pgid, sig);
}

test "AbortCallbackGuard invokes callback on abort and joins on stop" {
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
    var guard = AbortCallbackGuard.start(std.Options.debug_io, signal, .{ .ctx = @ptrCast(&ctx), .call = Ctx.callback });
    defer guard.stop();

    controller.requestAbort();
    var spins: usize = 0;
    while (ctx.called.load(.acquire) == 0 and spins < 1000) : (spins += 1) {
        std.Options.debug_io.sleep(.fromNanoseconds(std.time.ns_per_ms), .awake) catch {};
    }
    guard.stop();

    try std.testing.expectEqual(@as(u32, 1), ctx.called.load(.acquire));
}

test "AbortCallbackGuard stop suppresses later abort callback" {
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
    var guard = AbortCallbackGuard.start(std.Options.debug_io, signal, .{ .ctx = @ptrCast(&ctx), .call = Ctx.callback });
    guard.stop();

    controller.requestAbort();
    std.Options.debug_io.sleep(.fromNanoseconds(10 * std.time.ns_per_ms), .awake) catch {};

    try std.testing.expectEqual(@as(u32, 0), ctx.called.load(.acquire));
}
