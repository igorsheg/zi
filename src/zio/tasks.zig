const std = @import("std");

/// zi's owned concurrent work set.
///
/// Contract:
/// - `async` is logical fan-out and may run inline on the active `std.Io` backend.
/// - `concurrent` requires simultaneous progress. It first asks `std.Io.Group` and
///   falls back to an owned OS thread when the backend cannot provide concurrency.
/// - `wait` joins all owned work and closes the set.
/// - `cancel` cancels `std.Io` work and joins fallback threads. Fallback threads are
///   not preempted; callers must pass cooperative cancellation/resource guards when
///   the work can block indefinitely.
///
/// This is the only place new zio code should encode the std.Io-vs-thread backend
/// decision for scoped fan-out.
pub const TaskGroup = struct {
    io: std.Io,
    group: std.Io.Group = .init,
    threads: std.ArrayList(std.Thread) = .empty,
    closed: bool = false,

    pub fn init(io: std.Io) TaskGroup {
        return .{ .io = io };
    }

    pub fn async(self: *TaskGroup, function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) void {
        std.debug.assert(!self.closed);
        self.group.async(self.io, function, args);
    }

    pub fn concurrent(self: *TaskGroup, function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) std.Io.ConcurrentError!void {
        std.debug.assert(!self.closed);
        self.group.concurrent(self.io, function, args) catch |err| switch (err) {
            error.ConcurrencyUnavailable => {
                const thread = std.Thread.spawn(.{}, function, args) catch return error.ConcurrencyUnavailable;
                self.threads.append(std.heap.page_allocator, thread) catch {
                    thread.join();
                    return error.ConcurrencyUnavailable;
                };
            },
        };
    }

    pub fn wait(self: *TaskGroup) std.Io.Cancelable!void {
        self.closed = true;
        var io_result: std.Io.Cancelable!void = {};
        self.group.await(self.io) catch |err| {
            io_result = err;
        };
        self.joinThreads();
        self.threads.deinit(std.heap.page_allocator);
        self.threads = .empty;
        return io_result;
    }

    pub fn cancel(self: *TaskGroup) void {
        self.closed = true;
        self.group.cancel(self.io);
        self.joinThreads();
        self.threads.deinit(std.heap.page_allocator);
        self.threads = .empty;
    }

    fn joinThreads(self: *TaskGroup) void {
        for (self.threads.items) |thread| thread.join();
        self.threads.clearRetainingCapacity();
    }
};

test "TaskGroup concurrent work makes simultaneous progress" {
    const Ctx = struct {
        a_started: std.atomic.Value(bool) = .init(false),
        b_started: std.atomic.Value(bool) = .init(false),
        a_observed_b: std.atomic.Value(bool) = .init(false),
        b_observed_a: std.atomic.Value(bool) = .init(false),

        fn runA(ctx: *@This()) void {
            ctx.a_started.store(true, .release);
            var spins: usize = 0;
            while (!ctx.b_started.load(.acquire) and spins < 10_000) : (spins += 1) {
                std.Options.debug_io.sleep(.fromNanoseconds(std.time.ns_per_ms), .awake) catch {};
            }
            ctx.a_observed_b.store(ctx.b_started.load(.acquire), .release);
        }

        fn runB(ctx: *@This()) void {
            ctx.b_started.store(true, .release);
            var spins: usize = 0;
            while (!ctx.a_started.load(.acquire) and spins < 10_000) : (spins += 1) {
                std.Options.debug_io.sleep(.fromNanoseconds(std.time.ns_per_ms), .awake) catch {};
            }
            ctx.b_observed_a.store(ctx.a_started.load(.acquire), .release);
        }
    };

    var ctx = Ctx{};
    var group = TaskGroup.init(std.Options.debug_io);
    defer group.cancel();

    try group.concurrent(Ctx.runA, .{&ctx});
    try group.concurrent(Ctx.runB, .{&ctx});
    try group.wait();

    try std.testing.expect(ctx.a_observed_b.load(.acquire));
    try std.testing.expect(ctx.b_observed_a.load(.acquire));
}

test "TaskGroup owns async fan-out until wait" {
    const Ctx = struct {
        value: *std.atomic.Value(u32),
        fn add(ctx: *@This(), amount: u32) void {
            _ = ctx.value.fetchAdd(amount, .acq_rel);
        }
    };

    var value = std.atomic.Value(u32).init(0);
    var ctx: Ctx = .{ .value = &value };
    var group = TaskGroup.init(std.Options.debug_io);
    defer group.cancel();

    group.async(Ctx.add, .{ &ctx, 2 });
    group.async(Ctx.add, .{ &ctx, 3 });
    try group.wait();

    try std.testing.expectEqual(@as(u32, 5), value.load(.acquire));
}
