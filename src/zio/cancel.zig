const std = @import("std");

pub const Token = struct {
    controller: ?*Source,
    expected_generation: u64,

    pub const WaitPredicate = *const fn (ctx: ?*anyopaque) bool;
    pub const WaitResult = enum {
        aborted,
        predicate,
        timeout,
        none,
    };

    pub const none: Token = .{
        .controller = null,
        .expected_generation = 0,
    };

    // Token validity is the Source generation, not only the aborted flag.
    pub fn isAborted(self: Token) bool {
        const controller = self.controller orelse return false;
        return controller.generation.load(.acquire) != self.expected_generation or controller.aborted.load(.acquire);
    }

    pub fn isNone(self: Token) bool {
        return self.controller == null and self.expected_generation == 0;
    }

    pub fn runId(self: Token) u64 {
        return self.expected_generation;
    }

    pub fn waitUntil(
        self: Token,
        timeout_ns: ?u64,
        predicate: ?WaitPredicate,
        predicate_ctx: ?*anyopaque,
    ) WaitResult {
        return self.waitUntilIo(std.Options.debug_io, timeout_ns, predicate, predicate_ctx);
    }

    pub fn waitUntilIo(
        self: Token,
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

    pub fn notifyWaiters(self: Token) void {
        const controller = self.controller orelse return;
        controller.notifyWaiters();
    }
};

pub const Source = struct {
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    aborted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(1),

    // beginRun invalidates old tokens and wakes waiters before returning the new token.
    pub fn beginRun(self: *Source) Token {
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

    pub fn signal(self: *Source) Token {
        return .{
            .controller = self,
            .expected_generation = self.generation.load(.acquire),
        };
    }

    pub fn requestAbort(self: *Source) void {
        self.aborted.store(true, .release);
        self.notifyWaiters();
    }

    pub fn notifyWaiters(self: *Source) void {
        self.notifyWaitersIo(std.Options.debug_io);
    }

    pub fn notifyWaitersIo(self: *Source, io: std.Io) void {
        self.condition.broadcast(io);
    }

    pub fn isAborted(self: *const Source) bool {
        return self.aborted.load(.acquire);
    }

    pub fn currentRunId(self: *const Source) u64 {
        return self.generation.load(.acquire);
    }
};

test "Source invalidates stale signals when a new run begins" {
    var controller = Source{};

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

test "Token.waitUntil wakes for abort without polling" {
    var controller = Source{};
    const signal = controller.beginRun();

    const WaitCtx = struct {
        signal: Token,
        result: *Token.WaitResult,

        fn run(ctx: *@This()) void {
            ctx.result.* = ctx.signal.waitUntil(null, null, null);
        }
    };

    var result: Token.WaitResult = .none;
    var ctx: WaitCtx = .{ .signal = signal, .result = &result };
    const thread = try std.Thread.spawn(.{}, WaitCtx.run, .{&ctx});

    std.Options.debug_io.sleep(.fromNanoseconds(@intCast(10 * std.time.ns_per_ms)), .awake) catch {};
    controller.requestAbort();
    thread.join();
    try std.testing.expectEqual(.aborted, result);
}
