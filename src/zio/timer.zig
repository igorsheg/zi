const std = @import("std");
const deadline = @import("deadline.zig");

pub const Callback = struct {
    ptr: ?*anyopaque = null,
    call: *const fn (ptr: ?*anyopaque) void,
};

pub const Timer = struct {
    id: u64,
    deadline_ns: i128,
    callback: Callback,
    active: bool = true,
};

pub const Handle = struct { id: u64 };

pub const Queue = struct {
    allocator: std.mem.Allocator,
    timers: std.ArrayList(Timer) = .empty,
    next_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator) Queue {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Queue) void {
        self.timers.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clear(self: *Queue) void {
        self.timers.clearRetainingCapacity();
    }

    pub fn addAt(self: *Queue, deadline_ns: i128, callback: Callback) !Handle {
        const id = self.next_id;
        self.next_id +%= 1;
        if (self.next_id == 0) self.next_id = 1;
        try self.timers.append(self.allocator, .{ .id = id, .deadline_ns = deadline_ns, .callback = callback });
        return .{ .id = id };
    }

    pub fn addAfterMs(self: *Queue, io: std.Io, ms: u64, callback: Callback) !Handle {
        return self.addAt(deadline.Deadline.afterMs(io, ms).ns, callback);
    }

    pub fn cancel(self: *Queue, handle: Handle) void {
        for (self.timers.items) |*entry| {
            if (entry.id == handle.id) {
                entry.active = false;
                return;
            }
        }
    }

    pub fn nextDeadlineNs(self: *const Queue) ?i128 {
        var next: ?i128 = null;
        for (self.timers.items) |timer| {
            if (!timer.active) continue;
            next = if (next) |cur| @min(cur, timer.deadline_ns) else timer.deadline_ns;
        }
        return next;
    }

    pub fn timeoutMs(self: *const Queue, now_ns: i128, max_ms: i32) i32 {
        return deadline.timeoutUntil(self.nextDeadlineNs(), now_ns, max_ms);
    }

    pub fn fireExpired(self: *Queue, now_ns: i128) usize {
        var fired: usize = 0;
        var i: usize = 0;
        while (i < self.timers.items.len) {
            const timer = self.timers.items[i];
            if (!timer.active or timer.deadline_ns <= now_ns) {
                _ = self.timers.swapRemove(i);
                if (timer.active and timer.deadline_ns <= now_ns) {
                    fired += 1;
                    timer.callback.call(timer.callback.ptr);
                }
                continue;
            }
            i += 1;
        }
        return fired;
    }
};

test "timer queue fires expired timers once" {
    const Ctx = struct {
        count: usize = 0,
        fn onTimer(ptr: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            self.count += 1;
        }
    };
    var ctx = Ctx{};
    var q = Queue.init(std.testing.allocator);
    defer q.deinit();

    _ = try q.addAt(10, .{ .ptr = @ptrCast(&ctx), .call = Ctx.onTimer });
    try std.testing.expectEqual(@as(usize, 0), q.fireExpired(9));
    try std.testing.expectEqual(@as(usize, 1), q.fireExpired(10));
    try std.testing.expectEqual(@as(usize, 0), q.fireExpired(11));
    try std.testing.expectEqual(@as(usize, 1), ctx.count);
}

test "timer queue cancellation suppresses callback" {
    const Ctx = struct {
        called: bool = false,
        fn onTimer(ptr: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            self.called = true;
        }
    };
    var ctx = Ctx{};
    var q = Queue.init(std.testing.allocator);
    defer q.deinit();

    const handle = try q.addAt(10, .{ .ptr = @ptrCast(&ctx), .call = Ctx.onTimer });
    q.cancel(handle);
    try std.testing.expectEqual(@as(usize, 0), q.fireExpired(20));
    try std.testing.expect(!ctx.called);
}
