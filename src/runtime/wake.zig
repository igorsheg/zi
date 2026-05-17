const std = @import("std");
const completion = @import("completion.zig");

pub const WakeId = completion.WakeId;
pub const WakeOp = completion.WakeOp;

pub fn init(id: WakeId) WakeOp {
    return .{ .id = id };
}

pub fn notify(op: *WakeOp) void {
    _ = op.pending_notify_count.fetchAdd(1, .release);
}

pub fn takePending(op: *WakeOp) u32 {
    return op.pending_notify_count.swap(0, .acquire);
}

test "wake notifications coalesce" {
    var w = init(7);
    notify(&w);
    notify(&w);
    try std.testing.expectEqual(@as(u32, 2), takePending(&w));
    try std.testing.expectEqual(@as(u32, 0), takePending(&w));
}
