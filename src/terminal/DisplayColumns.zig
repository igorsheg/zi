const std = @import("std");

const minimum: usize = 20;
const maximum: usize = 4096;
const automatic_cap: usize = 100;
const automatic_tolerance: usize = 10;

pub const ParseError = error{InvalidValue};

/// Allocation-free display-width policy parsed from borrowed configuration.
pub const Policy = union(enum) {
    auto,
    terminal,
    fixed: usize,

    pub fn parse(configured: []const u8) ParseError!Policy {
        if (std.ascii.eqlIgnoreCase(configured, "auto")) return .auto;
        if (std.ascii.eqlIgnoreCase(configured, "terminal")) return .terminal;

        if (configured.len == 0) return error.InvalidValue;
        var columns: usize = 0;
        for (configured) |byte| {
            if (byte < '0' or byte > '9') return error.InvalidValue;
            const digit: usize = byte - '0';
            if (columns > (maximum - digit) / 10) return error.InvalidValue;
            columns = columns * 10 + digit;
        }
        if (columns < minimum) return error.InvalidValue;
        return .{ .fixed = columns };
    }

    /// Resolves a physical terminal width into the bounded content width.
    pub fn resolve(policy: Policy, physical_columns: usize) usize {
        return switch (policy) {
            .auto => if (physical_columns > automatic_cap + automatic_tolerance)
                automatic_cap
            else
                @max(physical_columns, minimum),
            .terminal => @min(@max(physical_columns, minimum), maximum),
            .fixed => |columns| columns,
        };
    }
};

fn expectResolved(policy: Policy, physical_columns: usize, expected: usize) !void {
    try std.testing.expectEqual(expected, policy.resolve(physical_columns));
}

test "auto floors narrow terminals and caps widths above its tolerance" {
    const policy = try Policy.parse("auto");
    const physical = [_]usize{ 0, 1, 19, 20, 100, 110, 111, 4096, maximum + 1 };
    const expected = [_]usize{ 20, 20, 20, 20, 100, 110, 100, 100, 100 };

    for (physical, expected) |columns, resolved| {
        try expectResolved(policy, columns, resolved);
    }
}

test "terminal follows the physical width within layout bounds" {
    const policy = try Policy.parse("terminal");
    const physical = [_]usize{ 0, 1, 19, 20, 100, 110, 111, 4096, maximum + 1 };
    const expected = [_]usize{ 20, 20, 20, 20, 100, 110, 111, 4096, 4096 };

    for (physical, expected) |columns, resolved| {
        try expectResolved(policy, columns, resolved);
    }
}

test "fixed policy is exact and independent of the physical width" {
    const policy = try Policy.parse("111");
    const physical = [_]usize{ 0, 1, 19, 20, 100, 110, 111, 4096, maximum + 1 };

    for (physical) |columns| {
        try expectResolved(policy, columns, 111);
    }
}

test "parse accepts named modes case-insensitively and bounded decimal widths" {
    try std.testing.expectEqual(Policy.auto, try Policy.parse("AUTO"));
    try std.testing.expectEqual(Policy.terminal, try Policy.parse("TeRmInAl"));
    const twenty: Policy = .{ .fixed = 20 };
    const hundred: Policy = .{ .fixed = 100 };
    const maximum_width: Policy = .{ .fixed = 4096 };
    try std.testing.expectEqual(twenty, try Policy.parse("20"));
    try std.testing.expectEqual(hundred, try Policy.parse("00100"));
    try std.testing.expectEqual(maximum_width, try Policy.parse("4096"));
}

test "parse rejects malformed, out-of-range, and overflowing values" {
    const invalid = [_][]const u8{
        "",
        "19",
        "4097",
        "184467440737095516160",
        "-20",
        "+20",
        "20 ",
        " 20",
        "20x",
        "wide",
    };

    for (invalid) |configured| {
        try std.testing.expectError(error.InvalidValue, Policy.parse(configured));
    }
}
