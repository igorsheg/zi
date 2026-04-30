const std = @import("std");

/// Small zi wrapper around `std.Io.Group`.
///
/// Use this for structured fan-out where child tasks are owned by the lexical
/// scope. `defer cancel()` is the expected cleanup path until `wait()` succeeds.
///
/// This is deliberately tiny: std.Io owns scheduling/cancellation semantics;
/// zi owns naming, conventions, and candidate documentation.
pub const TaskGroup = struct {
    io: std.Io,
    group: std.Io.Group = .init,
    closed: bool = false,

    pub fn init(io: std.Io) TaskGroup {
        return .{ .io = io };
    }

    /// Spawn work that may run inline on backends without guaranteed
    /// concurrency. Use for logically async work where inline execution is OK.
    pub fn async(self: *TaskGroup, function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) void {
        std.debug.assert(!self.closed);
        self.group.async(self.io, function, args);
    }

    /// Spawn work that requires actual concurrency. If the backend cannot offer
    /// a unit of concurrency, the error is returned and no task is owned.
    pub fn concurrent(self: *TaskGroup, function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) std.Io.ConcurrentError!void {
        std.debug.assert(!self.closed);
        try self.group.concurrent(self.io, function, args);
    }

    /// Wait for all owned tasks. After this succeeds the group is considered
    /// closed by zi convention; create a fresh TaskGroup for more work.
    pub fn wait(self: *TaskGroup) std.Io.Cancelable!void {
        self.closed = true;
        try self.group.await(self.io);
    }

    /// Request cancellation of all owned tasks and wait until their resources are
    /// released. Idempotent.
    pub fn cancel(self: *TaskGroup) void {
        self.closed = true;
        self.group.cancel(self.io);
    }
};

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
