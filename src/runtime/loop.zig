const std = @import("std");
const backend_mod = @import("backend.zig");
const completion_mod = @import("completion.zig");
const queue_mod = @import("queue.zig");

pub const Completion = completion_mod.Completion;
pub const TimerOp = completion_mod.TimerOp;
pub const WakeOp = completion_mod.WakeOp;
pub const Operation = completion_mod.Operation;
pub const TickMode = backend_mod.TickMode;

pub const Options = struct {
    completion_capacity: usize = 256,
};

pub const CompletionSink = struct {
    ptr: *anyopaque,
    submitFn: *const fn (*anyopaque, Completion) anyerror!void,

    pub fn submit(self: CompletionSink, completion: Completion) !void {
        try self.submitFn(self.ptr, completion);
    }
};

pub const Loop = struct {
    allocator: std.mem.Allocator,
    backend: backend_mod.ManualBackend,
    completions: queue_mod.BoundedQueue(Completion),
    owner_thread_id: std.Thread.Id,
    next_operation_id: u64 = 1,
    in_tick: bool = false,
    stopped: bool = false,

    pub fn init(allocator: std.mem.Allocator, options: Options) !Loop {
        return .{
            .allocator = allocator,
            .backend = .init(allocator),
            .completions = try .init(allocator, options.completion_capacity),
            .owner_thread_id = std.Thread.getCurrentId(),
        };
    }

    pub fn deinit(self: *Loop) void {
        self.assertOwnerThread();
        std.debug.assert(!self.in_tick);
        self.backend.deinit();
        self.completions.deinit();
        self.* = undefined;
    }

    pub fn submitTimer(self: *Loop, op: *TimerOp, deadline_ns: u64) !void {
        self.assertOwnerThread();
        try self.backend.submitTimer(op, deadline_ns);
        op.op.markSubmitted(self.nextId());
    }

    pub fn submitWake(self: *Loop, op: *WakeOp) !void {
        self.assertOwnerThread();
        try self.backend.submitWake(op);
        op.op.markSubmitted(self.nextId());
    }

    pub fn cancel(self: *Loop, op: *Operation) !void {
        self.assertOwnerThread();
        try self.backend.cancel(op, &self.completions);
    }

    pub fn tick(self: *Loop, mode: TickMode) !void {
        self.assertOwnerThread();
        std.debug.assert(!self.in_tick);
        if (self.stopped) return;
        self.in_tick = true;
        defer self.in_tick = false;
        try self.backend.tick(mode, &self.completions);
    }

    pub fn drain(self: *Loop, sink: CompletionSink) !usize {
        self.assertOwnerThread();
        var n: usize = 0;
        while (self.completions.peek()) |completion| {
            try sink.submit(completion);
            self.completions.discardFront();
            n += 1;
        }
        return n;
    }

    pub fn stop(self: *Loop) void {
        self.assertOwnerThread();
        self.stopped = true;
        self.backend.stop();
    }

    pub fn setNowForTesting(self: *Loop, now_ns: u64) void {
        self.assertOwnerThread();
        self.backend.setNow(now_ns);
    }

    fn assertOwnerThread(self: *const Loop) void {
        std.debug.assert(std.Thread.getCurrentId() == self.owner_thread_id);
    }

    fn nextId(self: *Loop) u64 {
        const id = self.next_operation_id;
        self.next_operation_id += 1;
        return id;
    }
};

test "loop fires timer through bounded completion drain" {
    const Collector = struct {
        items: std.ArrayList(Completion) = .empty,

        fn submit(ptr: *anyopaque, c: Completion) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            try self.items.append(std.testing.allocator, c);
        }
    };

    var loop = try Loop.init(std.testing.allocator, .{ .completion_capacity = 4 });
    defer loop.deinit();

    var timer: TimerOp = .{ .id = 11, .deadline_ns = 0 };
    try loop.submitTimer(&timer, 10);
    loop.setNowForTesting(9);
    try loop.tick(.no_wait);

    var collector: Collector = .{};
    defer collector.items.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), try loop.drain(.{ .ptr = &collector, .submitFn = Collector.submit }));

    loop.setNowForTesting(10);
    try loop.tick(.no_wait);
    try std.testing.expectEqual(@as(usize, 1), try loop.drain(.{ .ptr = &collector, .submitFn = Collector.submit }));
    try std.testing.expectEqual(@as(completion_mod.TimerId, 11), collector.items.items[0].timer.id);
}

test "loop wake completion coalesces notifications" {
    const Collector = struct {
        count: u32 = 0,
        fn submit(ptr: *anyopaque, c: Completion) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.count = c.wake.result.notified;
        }
    };

    var loop = try Loop.init(std.testing.allocator, .{ .completion_capacity = 4 });
    defer loop.deinit();

    var w: WakeOp = .{ .id = 3 };
    try loop.submitWake(&w);
    @import("wake.zig").notify(&w);
    @import("wake.zig").notify(&w);
    try loop.tick(.no_wait);

    var collector: Collector = .{};
    _ = try loop.drain(.{ .ptr = &collector, .submitFn = Collector.submit });
    try std.testing.expectEqual(@as(u32, 2), collector.count);
}

test "loop cancel produces cancellation completion" {
    const Collector = struct {
        cancelled: bool = false,
        fn submit(ptr: *anyopaque, c: Completion) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.cancelled = c.timer.result == .cancelled;
        }
    };

    var loop = try Loop.init(std.testing.allocator, .{ .completion_capacity = 4 });
    defer loop.deinit();

    var timer: TimerOp = .{ .id = 9, .deadline_ns = 0 };
    try loop.submitTimer(&timer, 100);
    try loop.cancel(&timer.op);

    var collector: Collector = .{};
    _ = try loop.drain(.{ .ptr = &collector, .submitFn = Collector.submit });
    try std.testing.expect(collector.cancelled);
}

test "drain preserves completion when sink fails" {
    const FailingSink = struct {
        fn submit(_: *anyopaque, _: Completion) !void {
            return error.SinkFailed;
        }
    };
    const CountingSink = struct {
        count: usize = 0,
        fn submit(ptr: *anyopaque, _: Completion) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.count += 1;
        }
    };

    var loop = try Loop.init(std.testing.allocator, .{ .completion_capacity = 4 });
    defer loop.deinit();

    var timer: TimerOp = .{ .id = 12, .deadline_ns = 0 };
    try loop.submitTimer(&timer, 1);
    loop.setNowForTesting(1);
    try loop.tick(.no_wait);

    try std.testing.expectError(error.SinkFailed, loop.drain(.{ .ptr = undefined, .submitFn = FailingSink.submit }));

    var counting: CountingSink = .{};
    try std.testing.expectEqual(@as(usize, 1), try loop.drain(.{ .ptr = &counting, .submitFn = CountingSink.submit }));
    try std.testing.expectEqual(@as(usize, 1), counting.count);
}

test "full completion queue does not complete undelivered timer" {
    const Sink = struct {
        count: usize = 0,
        fn submit(ptr: *anyopaque, _: Completion) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.count += 1;
        }
    };

    var loop = try Loop.init(std.testing.allocator, .{ .completion_capacity = 1 });
    defer loop.deinit();

    var first: TimerOp = .{ .id = 1, .deadline_ns = 0 };
    var second: TimerOp = .{ .id = 2, .deadline_ns = 0 };
    try loop.submitTimer(&first, 1);
    try loop.submitTimer(&second, 1);
    loop.setNowForTesting(1);

    try std.testing.expectError(error.Full, loop.tick(.no_wait));
    try std.testing.expect(first.op.state == .completed or second.op.state == .completed);
    try std.testing.expect(first.op.state == .submitted or second.op.state == .submitted);

    var sink: Sink = .{};
    try std.testing.expectEqual(@as(usize, 1), try loop.drain(.{ .ptr = &sink, .submitFn = Sink.submit }));

    try loop.tick(.no_wait);
    try std.testing.expectEqual(@as(usize, 1), try loop.drain(.{ .ptr = &sink, .submitFn = Sink.submit }));
    try std.testing.expectEqual(@as(usize, 2), sink.count);
}
