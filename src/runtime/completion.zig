const std = @import("std");

pub const OperationId = u64;
pub const TimerId = u64;
pub const WakeId = u64;

pub const OperationKind = enum {
    timer,
    wake,
};

pub const OperationState = enum {
    idle,
    submitted,
    completing,
    completed,
    cancelled,
};

pub const TimerResult = union(enum) {
    fired: void,
    cancelled: void,
};

pub const WakeResult = union(enum) {
    notified: u32,
    cancelled: void,
};

pub const Completion = union(enum) {
    timer: struct {
        id: TimerId,
        result: TimerResult,
    },
    wake: struct {
        id: WakeId,
        result: WakeResult,
    },
};

pub const CallerOwnedOperation = struct {
    id: OperationId = 0,
    kind: OperationKind,
    state: OperationState = .idle,

    pub fn assertReusable(self: *const Operation) void {
        std.debug.assert(self.state == .idle or self.state == .completed or self.state == .cancelled);
    }

    pub fn markSubmitted(self: *Operation, id: OperationId) void {
        self.assertReusable();
        self.id = id;
        self.state = .submitted;
    }

    pub fn markCompleting(self: *Operation) void {
        std.debug.assert(self.state == .submitted);
        self.state = .completing;
    }

    pub fn markCompleted(self: *Operation) void {
        std.debug.assert(self.state == .completing);
        self.state = .completed;
    }

    pub fn markCancelled(self: *Operation) void {
        std.debug.assert(self.state == .submitted or self.state == .completing);
        self.state = .cancelled;
    }
};

pub const TimerOp = struct {
    op: CallerOwnedOperation = .{ .kind = .timer },
    id: TimerId,
    deadline_ns: u64,
};

pub const CoalescingWakeOp = struct {
    op: CallerOwnedOperation = .{ .kind = .wake },
    id: WakeId,
    pending_notify_count: std.atomic.Value(u32) = .init(0),
};

pub const Operation = CallerOwnedOperation;
pub const WakeOp = CoalescingWakeOp;
