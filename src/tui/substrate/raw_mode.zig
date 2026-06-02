const std = @import("std");

pub const RawMode = struct {
    active: bool = false,

    pub fn enter() !RawMode { return .{ .active = true }; }
    pub fn restore(self: *RawMode) void { self.active = false; }
};

test "raw mode restore is idempotent" {
    var mode = try RawMode.enter();
    mode.restore();
    mode.restore();
    try std.testing.expect(!mode.active);
}
