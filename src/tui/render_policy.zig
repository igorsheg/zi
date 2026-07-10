const std = @import("std");

pub fn shouldRenderWithFloor(dirty: bool, now_ns: u64, last_frame_start_ns: u64, floor_ns: u64) bool {
    if (!dirty) return false;
    return now_ns -| last_frame_start_ns >= floor_ns;
}

pub fn nextRenderDueNsWithFloor(last_frame_start_ns: u64, floor_ns: u64) u64 {
    return last_frame_start_ns +| floor_ns;
}

test "dirty render waits for a fixed frame deadline" {
    const floor_ns: u64 = 16;
    try std.testing.expect(!shouldRenderWithFloor(false, 100, 0, floor_ns));
    try std.testing.expect(!shouldRenderWithFloor(true, floor_ns - 1, 0, floor_ns));
    try std.testing.expect(shouldRenderWithFloor(true, floor_ns, 0, floor_ns));
    try std.testing.expectEqual(@as(u64, floor_ns + 10), nextRenderDueNsWithFloor(10, floor_ns));
}
