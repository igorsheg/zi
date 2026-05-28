pub const ai = @import("ai/root.zig");
pub const agent = @import("agent/root.zig");
pub const coding_agent = @import("coding_agent/root.zig");
pub const zistd = @import("zistd/root.zig");

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

const std = @import("std");

test "add returns the sum" {
    try std.testing.expectEqual(@as(i32, 10), add(3, 7));
}

test {
    _ = ai;
    _ = agent;
    _ = coding_agent;
    _ = zistd;
}
