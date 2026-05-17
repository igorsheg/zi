const completion = @import("completion.zig");

pub const TimerId = completion.TimerId;

pub const TimerOp = completion.TimerOp;

pub fn init(id: TimerId) TimerOp {
    return .{ .id = id, .deadline_ns = 0 };
}
