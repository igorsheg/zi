const std = @import("std");
const OutputCap = @import("OutputCap.zig");

pub const Policy = struct {
    output_bytes: usize = OutputCap.default_output_bytes,
    bash_timeout_ms: u64 = 120 * 1_000,
    bash_maximum_timeout_ms: u64 = 30 * 60 * 1_000,
    bash_termination_grace_ms: u64 = 2 * 1_000,
    bash_background_yield_ms: u64 = 5 * 1_000,
    task_wait_timeout_ms: u64 = 10 * 60 * 1_000,
    task_maximum_running: usize = 32,
};

pub fn isValid(policy: Policy) bool {
    return policy.output_bytes != 0 and policy.output_bytes <= OutputCap.maximum_capture_bytes and
        policy.bash_timeout_ms <= std.math.maxInt(i64) and
        policy.bash_maximum_timeout_ms <= std.math.maxInt(i64) and
        policy.bash_termination_grace_ms <= 300_000 and
        policy.bash_background_yield_ms <= std.math.maxInt(i64) and
        policy.task_maximum_running != 0 and policy.task_maximum_running <= 64;
}

pub fn bashResultBytes(policy: Policy) usize {
    std.debug.assert(isValid(policy));
    return policy.output_bytes * 3 + 64 * 1024;
}

pub fn validate(policy: Policy) error{InvalidPolicy}!void {
    if (!isValid(policy)) return error.InvalidPolicy;
}

test "validation enforces complete tool policy bounds" {
    const value: Policy = .{ .task_maximum_running = 8 };
    try std.testing.expect(isValid(value));
    try validate(value);
    try std.testing.expect(!isValid(.{ .output_bytes = 0 }));
    try std.testing.expectError(error.InvalidPolicy, validate(.{ .output_bytes = 0 }));
}
