const std = @import("std");

pub const OperationId = enum(u64) {
    _,

    pub fn first() OperationId {
        return @enumFromInt(1);
    }

    pub fn next(self: OperationId) OperationId {
        const value = @intFromEnum(self);
        std.debug.assert(value < std.math.maxInt(u64));
        return @enumFromInt(value + 1);
    }
};

pub const OperationState = union(enum) {
    queued,
    running,
    cancel_requested,
    completed,
    failed,
    canceled,
};

pub const OperationIds = struct {
    next_id: OperationId = OperationId.first(),

    pub fn reserve(self: *OperationIds) OperationId {
        const id = self.next_id;
        self.next_id = id.next();
        return id;
    }
};

test "operation ids reserve monotonic nonzero ids" {
    var ids: OperationIds = .{};

    const first = ids.reserve();
    const second = ids.reserve();

    try std.testing.expectEqual(@as(u64, 1), @intFromEnum(first));
    try std.testing.expectEqual(@as(u64, 2), @intFromEnum(second));
}

test "operation state encodes lifecycle without boolean modes" {
    const states = [_]OperationState{
        .queued,
        .running,
        .cancel_requested,
        .completed,
        .failed,
        .canceled,
    };

    try std.testing.expectEqual(@as(usize, 6), states.len);
}
