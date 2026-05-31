const std = @import("std");

pub const Policy = struct {
    interval_ns: i128 = std.time.ns_per_s / 30,
    terminal_events_per_tick_max: usize = 64,
    host_events_per_tick_max: usize = 128,

    pub fn validate(self: Policy) void {
        std.debug.assert(self.interval_ns > 0);
        std.debug.assert(self.terminal_events_per_tick_max > 0);
        std.debug.assert(self.host_events_per_tick_max > 0);
    }
};

pub const Gate = struct {
    policy: Policy = .{},
    last_render_ns: i128 = 0,

    pub fn init(policy: Policy) Gate {
        policy.validate();
        return .{ .policy = policy };
    }

    pub fn shouldRender(self: Gate, now_ns: i128) bool {
        return elapsed(now_ns, self.last_render_ns, self.policy.interval_ns);
    }

    pub fn recordRender(self: *Gate, now_ns: i128) void {
        self.last_render_ns = now_ns;
    }
};

pub fn elapsed(now_ns: i128, last_render_ns: i128, interval_ns: i128) bool {
    std.debug.assert(interval_ns > 0);
    return now_ns - last_render_ns >= interval_ns;
}

test "frame gate renders dirty state only after interval" {
    var gate = Gate.init(.{ .interval_ns = 33 });

    try std.testing.expect(!gate.shouldRender(32));
    try std.testing.expect(gate.shouldRender(33));

    gate.recordRender(33);
    try std.testing.expect(!gate.shouldRender(65));
    try std.testing.expect(gate.shouldRender(66));
}

test "frame policy exposes nonzero bounded drains" {
    const policy: Policy = .{
        .terminal_events_per_tick_max = 8,
        .host_events_per_tick_max = 16,
    };
    policy.validate();

    try std.testing.expectEqual(@as(usize, 8), policy.terminal_events_per_tick_max);
    try std.testing.expectEqual(@as(usize, 16), policy.host_events_per_tick_max);
}
