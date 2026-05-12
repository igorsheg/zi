const std = @import("std");

pub const Group = struct {
    allocator: std.mem.Allocator,
    threads: std.ArrayList(std.Thread) = .empty,
    closed: bool = false,

    pub fn init(allocator: std.mem.Allocator) Group {
        return .{ .allocator = allocator };
    }

    // The group owns every spawned thread. No detach, no clever lifetime bargain,
    // no mystery meat running after shutdown. Join or cancel clears the room.
    pub fn spawnThread(self: *Group, function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) std.Io.ConcurrentError!void {
        std.debug.assert(!self.closed);
        self.threads.ensureUnusedCapacity(self.allocator, 1) catch return error.ConcurrencyUnavailable;
        const thread = std.Thread.spawn(.{}, function, args) catch return error.ConcurrencyUnavailable;
        self.threads.appendAssumeCapacity(thread);
    }

    pub fn join(self: *Group) std.Io.Cancelable!void {
        self.closed = true;
        self.joinThreads();
        self.threads.deinit(self.allocator);
        self.threads = .empty;
        return {};
    }

    pub fn cancel(self: *Group) void {
        self.closed = true;
        self.joinThreads();
        self.threads.deinit(self.allocator);
        self.threads = .empty;
    }

    fn joinThreads(self: *Group) void {
        for (self.threads.items) |thread| thread.join();
        self.threads.clearRetainingCapacity();
    }
};

test "Group concurrent work makes simultaneous progress" {
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
    var group = Group.init(std.testing.allocator);

    try group.spawnThread(Ctx.runA, .{&ctx});
    try group.spawnThread(Ctx.runB, .{&ctx});
    try group.join();

    try std.testing.expect(ctx.a_observed_b.load(.acquire));
    try std.testing.expect(ctx.b_observed_a.load(.acquire));
}
