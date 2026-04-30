const std = @import("std");

/// Read-only cooperative cancellation token for one in-flight run.
/// Passed through agent loop → provider → tool execution.
/// All layers check `isAborted()` at cancellation points.
///
/// The signal is generation-scoped: when the owner starts a new run,
/// stale signals from the previous run become aborted automatically.
pub const AbortSignal = struct {
    controller: ?*AbortController,
    expected_generation: u64,

    pub const WaitPredicate = *const fn (ctx: ?*anyopaque) bool;
    pub const WaitResult = enum {
        aborted,
        predicate,
        timeout,
        none,
    };

    /// Sentinel for "no abort signal" — never triggers.
    pub const none: AbortSignal = .{
        .controller = null,
        .expected_generation = 0,
    };

    pub fn isAborted(self: AbortSignal) bool {
        const controller = self.controller orelse return false;
        return controller.generation.load(.acquire) != self.expected_generation or controller.aborted.load(.acquire);
    }

    pub fn isNone(self: AbortSignal) bool {
        return self.controller == null and self.expected_generation == 0;
    }

    pub fn runId(self: AbortSignal) u64 {
        return self.expected_generation;
    }

    /// Block until this run aborts, a caller-supplied predicate becomes
    /// true, or the timeout expires.
    ///
    /// This is zi's wake-driven replacement for helper threads that used
    /// to poll `isAborted()` with `sleep(100ms)`.
    pub fn waitUntil(
        self: AbortSignal,
        timeout_ns: ?u64,
        predicate: ?WaitPredicate,
        predicate_ctx: ?*anyopaque,
    ) WaitResult {
        return self.waitUntilIo(std.Options.debug_io, timeout_ns, predicate, predicate_ctx);
    }

    /// Same as `waitUntil`, but participates in the caller-provided `std.Io`
    /// backend for clocks, sleep, mutex, and condition waits.
    pub fn waitUntilIo(
        self: AbortSignal,
        io: std.Io,
        timeout_ns: ?u64,
        predicate: ?WaitPredicate,
        predicate_ctx: ?*anyopaque,
    ) WaitResult {
        const controller = self.controller orelse {
            if (predicate) |pred| {
                if (pred(predicate_ctx)) return .predicate;
            }
            return if (timeout_ns == null) .none else .timeout;
        };

        const deadline_ns: ?i128 = if (timeout_ns) |timeout|
            @as(i128, @intCast(std.Io.Timestamp.now(io, .awake).toNanoseconds())) + @as(i128, @intCast(timeout))
        else
            null;

        controller.mutex.lockUncancelable(io);
        defer controller.mutex.unlock(io);

        while (true) {
            if (self.isAborted()) return .aborted;
            if (predicate) |pred| {
                if (pred(predicate_ctx)) return .predicate;
            }

            if (deadline_ns) |deadline| {
                const now = @as(i128, @intCast(std.Io.Timestamp.now(io, .awake).toNanoseconds()));
                if (now >= deadline) return .timeout;
                const remaining = @as(i96, @intCast(deadline - now));
                controller.mutex.unlock(io);
                io.sleep(.fromNanoseconds(remaining), .awake) catch {};
                controller.mutex.lockUncancelable(io);
            } else {
                controller.condition.waitUncancelable(io, &controller.mutex);
            }
        }
    }

    /// Wake threads blocked in `waitUntil` so they can re-check their
    /// predicates. Used by helper shutdown paths in addition to abort.
    pub fn notifyWaiters(self: AbortSignal) void {
        const controller = self.controller orelse return;
        controller.notifyWaiters();
    }
};

/// Run-scoped abort controller.
///
/// One owner mutates it (`beginRun`, `requestAbort`); readers receive
/// `AbortSignal` snapshots that stay valid for the lifetime of the run.
pub const AbortController = struct {
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    aborted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(1),

    pub fn beginRun(self: *AbortController) AbortSignal {
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);

        self.aborted.store(true, .release);
        const next_generation = self.generation.load(.acquire) + 1;
        self.generation.store(next_generation, .release);
        self.condition.broadcast(std.Options.debug_io);
        self.aborted.store(false, .release);

        return .{
            .controller = self,
            .expected_generation = next_generation,
        };
    }

    pub fn signal(self: *AbortController) AbortSignal {
        return .{
            .controller = self,
            .expected_generation = self.generation.load(.acquire),
        };
    }

    pub fn requestAbort(self: *AbortController) void {
        self.aborted.store(true, .release);
        self.notifyWaiters();
    }

    pub fn notifyWaiters(self: *AbortController) void {
        self.notifyWaitersIo(std.Options.debug_io);
    }

    pub fn notifyWaitersIo(self: *AbortController, io: std.Io) void {
        self.condition.broadcast(io);
    }

    pub fn isAborted(self: *const AbortController) bool {
        return self.aborted.load(.acquire);
    }

    pub fn currentRunId(self: *const AbortController) u64 {
        return self.generation.load(.acquire);
    }
};

test "AbortController invalidates stale signals when a new run begins" {
    var controller = AbortController{};

    const first = controller.beginRun();
    try std.testing.expect(!first.isAborted());
    try std.testing.expect(first.runId() != 0);

    controller.requestAbort();
    try std.testing.expect(first.isAborted());

    const second = controller.beginRun();
    try std.testing.expect(!second.isAborted());
    try std.testing.expect(second.runId() != first.runId());
    try std.testing.expect(first.isAborted());
}

test "AbortSignal.waitUntil wakes for abort without polling" {
    var controller = AbortController{};
    const signal = controller.beginRun();

    const WaitCtx = struct {
        signal: AbortSignal,
        result: *AbortSignal.WaitResult,

        fn run(ctx: *@This()) void {
            ctx.result.* = ctx.signal.waitUntil(null, null, null);
        }
    };

    var result: AbortSignal.WaitResult = .none;
    var ctx: WaitCtx = .{ .signal = signal, .result = &result };
    const thread = try std.Thread.spawn(.{}, WaitCtx.run, .{&ctx});

    std.Options.debug_io.sleep(.fromNanoseconds(@intCast(10 * std.time.ns_per_ms)), .awake) catch {};
    controller.requestAbort();
    thread.join();
    try std.testing.expectEqual(.aborted, result);
}

test "AbortSignal.none never aborts" {
    try std.testing.expect(AbortSignal.none.isNone());
    try std.testing.expect(!AbortSignal.none.isAborted());
}
