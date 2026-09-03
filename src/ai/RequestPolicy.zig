const std = @import("std");

pub const Policy = struct {
    show_reasoning: bool = false,
    additional_retries: u16 = 4,
    retry_base_ms: u64 = 1_000,
    idle_timeout_ms: u64 = 10 * 60 * 1_000,
};

pub fn isValid(policy: Policy) bool {
    return policy.additional_retries <= 100 and policy.retry_base_ms != 0;
}

pub fn validate(policy: Policy) error{InvalidPolicy}!void {
    if (!isValid(policy)) return error.InvalidPolicy;
}

test "validation enforces request bounds" {
    const value: Policy = .{ .show_reasoning = true, .additional_retries = 7 };
    try std.testing.expect(isValid(value));
    try validate(value);
    try std.testing.expect(!isValid(.{ .retry_base_ms = 0 }));
    try std.testing.expectError(error.InvalidPolicy, validate(.{ .retry_base_ms = 0 }));
}
