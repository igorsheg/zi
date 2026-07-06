const std = @import("std");

pub fn renderDelayNsWithFloor(floor_ns: u64, last_render_cost_ns: u64) u64 {
    return @max(floor_ns, last_render_cost_ns *| 3);
}

pub fn shouldRenderWithFloor(dirty: bool, now_ns: u64, last_flush_ns: u64, last_render_cost_ns: u64, floor_ns: u64) bool {
    if (!dirty) return false;
    return now_ns -| last_flush_ns >= renderDelayNsWithFloor(floor_ns, last_render_cost_ns);
}

pub fn nextRenderDueNsWithFloor(last_flush_ns: u64, last_render_cost_ns: u64, floor_ns: u64) u64 {
    return last_flush_ns +| renderDelayNsWithFloor(floor_ns, last_render_cost_ns);
}

test "render delay uses caller floor then 3x render cost" {
    const floor_ns: u64 = 16;
    try std.testing.expectEqual(@as(u64, floor_ns), renderDelayNsWithFloor(floor_ns, 1));
    try std.testing.expectEqual(@as(u64, 90), renderDelayNsWithFloor(floor_ns, 30));
}

test "dirty render waits until caller deadline" {
    const floor_ns: u64 = 16;
    try std.testing.expect(!shouldRenderWithFloor(false, 100, 0, 1, floor_ns));
    try std.testing.expect(!shouldRenderWithFloor(true, floor_ns - 1, 0, 1, floor_ns));
    try std.testing.expect(shouldRenderWithFloor(true, floor_ns, 0, 1, floor_ns));
    try std.testing.expectEqual(@as(u64, floor_ns + 10), nextRenderDueNsWithFloor(10, 1, floor_ns));
}
