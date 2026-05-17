const std = @import("std");
const completion = @import("completion.zig");
const queue = @import("queue.zig");
const wake = @import("wake.zig");

pub const TickMode = enum {
    no_wait,
    once,
};

pub const ManualBackend = struct {
    const TimerEntry = struct { op: *completion.TimerOp };
    const WakeEntry = struct { op: *completion.WakeOp };

    allocator: std.mem.Allocator,
    timers: std.ArrayList(TimerEntry) = .empty,
    wakes: std.ArrayList(WakeEntry) = .empty,
    now_ns: u64 = 0,
    stopped: bool = false,

    pub fn init(allocator: std.mem.Allocator) ManualBackend {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ManualBackend) void {
        self.timers.deinit(self.allocator);
        self.wakes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn setNow(self: *ManualBackend, now_ns: u64) void {
        std.debug.assert(now_ns >= self.now_ns);
        self.now_ns = now_ns;
    }

    pub fn submitTimer(self: *ManualBackend, op: *completion.TimerOp, deadline_ns: u64) !void {
        op.deadline_ns = deadline_ns;
        try self.timers.append(self.allocator, .{ .op = op });
    }

    pub fn submitWake(self: *ManualBackend, op: *completion.WakeOp) !void {
        try self.wakes.append(self.allocator, .{ .op = op });
    }

    pub fn cancel(self: *ManualBackend, op: *completion.Operation, out: *queue.BoundedQueue(completion.Completion)) !void {
        if (op.state != .submitted) return error.NotSubmitted;
        switch (op.kind) {
            .timer => {
                if (self.findTimerIndex(op)) |index| {
                    const timer_op = self.timers.items[index].op;
                    try out.push(.{ .timer = .{ .id = timer_op.id, .result = .cancelled } });
                    _ = self.timers.swapRemove(index);
                    op.markCompleting();
                    op.markCancelled();
                } else {
                    unreachable;
                }
            },
            .wake => {
                if (self.findWakeIndex(op)) |index| {
                    const wake_op = self.wakes.items[index].op;
                    try out.push(.{ .wake = .{ .id = wake_op.id, .result = .cancelled } });
                    _ = self.wakes.swapRemove(index);
                    op.markCompleting();
                    op.markCancelled();
                } else {
                    unreachable;
                }
            },
        }
    }

    pub fn tick(self: *ManualBackend, mode: TickMode, out: *queue.BoundedQueue(completion.Completion)) !void {
        if (self.stopped) return;
        try self.drainReady(out);
        if (mode == .once and out.isEmpty()) {
            if (self.nextDeadline()) |deadline| {
                if (deadline > self.now_ns) self.now_ns = deadline;
                try self.drainReady(out);
            }
        }
    }

    pub fn stop(self: *ManualBackend) void {
        self.stopped = true;
    }

    fn drainReady(self: *ManualBackend, out: *queue.BoundedQueue(completion.Completion)) !void {
        var i: usize = 0;
        while (i < self.timers.items.len) {
            const entry = self.timers.items[i];
            if (entry.op.deadline_ns <= self.now_ns) {
                try out.push(.{ .timer = .{ .id = entry.op.id, .result = .fired } });
                _ = self.timers.swapRemove(i);
                entry.op.op.markCompleting();
                entry.op.op.markCompleted();
            } else {
                i += 1;
            }
        }

        i = 0;
        while (i < self.wakes.items.len) {
            const entry = self.wakes.items[i];
            if (out.isFull()) return error.Full;
            const count = wake.takePending(entry.op);
            if (count > 0) {
                try out.push(.{ .wake = .{ .id = entry.op.id, .result = .{ .notified = count } } });
                _ = self.wakes.swapRemove(i);
                entry.op.op.markCompleting();
                entry.op.op.markCompleted();
            } else {
                i += 1;
            }
        }
    }

    fn nextDeadline(self: *const ManualBackend) ?u64 {
        var result: ?u64 = null;
        for (self.timers.items) |entry| {
            if (result == null or entry.op.deadline_ns < result.?) result = entry.op.deadline_ns;
        }
        return result;
    }

    fn findTimerIndex(self: *const ManualBackend, op: *completion.Operation) ?usize {
        for (self.timers.items, 0..) |entry, i| {
            if (&entry.op.op == op) {
                return i;
            }
        }
        return null;
    }

    fn findWakeIndex(self: *const ManualBackend, op: *completion.Operation) ?usize {
        for (self.wakes.items, 0..) |entry, i| {
            if (&entry.op.op == op) {
                return i;
            }
        }
        return null;
    }
};

pub fn assertBackendContract(comptime Backend: type) void {
    comptime {
        const required = .{
            "init",
            "deinit",
            "submitTimer",
            "submitWake",
            "cancel",
            "tick",
            "stop",
        };
        for (required) |decl| {
            if (!@hasDecl(Backend, decl)) {
                @compileError(@typeName(Backend) ++ " does not satisfy runtime backend contract: missing " ++ decl);
            }
        }
    }
}

comptime {
    assertBackendContract(ManualBackend);
}
