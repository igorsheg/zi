const std = @import("std");

pub const OperationId = enum(u64) {
    _,

    pub fn first() OperationId {
        return @enumFromInt(1);
    }

    pub fn next(self: OperationId) OperationId {
        return @enumFromInt(@intFromEnum(self) + 1);
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

pub const OperationTable = struct {
    next_id: OperationId = OperationId.first(),

    pub fn reserve(self: *OperationTable) OperationId {
        const id = self.next_id;
        self.next_id = id.next();
        return id;
    }
};

test "operation table reserves monotonic nonzero ids" {
    var table: OperationTable = .{};

    const first = table.reserve();
    const second = table.reserve();

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
