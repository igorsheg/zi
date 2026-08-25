const std = @import("std");
const ProcessAdapters = @import("ProcessAdapters.zig");

pub const max_depth: u8 = 3;
pub const Error = error{SubagentDepthLimit};
pub const diagnostic =
    "subagent depth limit (3) reached — run the task directly instead of spawning another zi";

/// Checks the exact environment snapshot supplied by process initialization.
/// It never reads ambient process state. Absent and empty values mean depth 0.
pub fn checkEnvironment(environment: *const ProcessAdapters.Environment) Error!u8 {
    return checkValue(environment.get("HAX_SUBAGENT_DEPTH"));
}

/// Returns an accepted parent depth. Malformed, negative, overflowing, and
/// capped values fail closed with the same error as depth 3.
pub fn checkValue(value: ?[]const u8) Error!u8 {
    const bytes = value orelse return 0;
    if (bytes.len == 0) return 0;

    var index: usize = 0;
    while (index < bytes.len and isAsciiWhitespace(bytes[index])) index += 1;
    var negative = false;
    if (index < bytes.len and (bytes[index] == '+' or bytes[index] == '-')) {
        negative = bytes[index] == '-';
        index += 1;
    }
    const digit_start = index;
    var magnitude: u64 = 0;
    while (index < bytes.len and bytes[index] >= '0' and bytes[index] <= '9') {
        magnitude = std.math.mul(u64, magnitude, 10) catch return error.SubagentDepthLimit;
        magnitude = std.math.add(u64, magnitude, bytes[index] - '0') catch
            return error.SubagentDepthLimit;
        index += 1;
    }
    if (index == digit_start or index != bytes.len) return error.SubagentDepthLimit;

    const maximum_magnitude: u64 = if (negative)
        @as(u64, std.math.maxInt(i32)) + 1
    else
        std.math.maxInt(i32);
    if (magnitude > maximum_magnitude) return error.SubagentDepthLimit;
    if (negative and magnitude != 0) return error.SubagentDepthLimit;
    if (magnitude >= max_depth) return error.SubagentDepthLimit;
    return @intCast(magnitude);
}

fn isAsciiWhitespace(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\n', '\r', 0x0b, 0x0c => true,
        else => false,
    };
}

test "subagent depth accepts the hax strtol integer domain below the cap" {
    try std.testing.expectEqual(@as(u8, 0), try checkValue(null));
    try std.testing.expectEqual(@as(u8, 0), try checkValue(""));
    try std.testing.expectEqual(@as(u8, 0), try checkValue("-0"));
    try std.testing.expectEqual(@as(u8, 1), try checkValue("+1"));
    try std.testing.expectEqual(@as(u8, 1), try checkValue(" \t\n\r\x0b\x0c1"));
    try std.testing.expectEqual(@as(u8, 2), try checkValue("0002"));
}

test "subagent depth fails closed for malformed negative capped and overflowing values" {
    const rejected = [_][]const u8{
        "-1",
        "+",
        "-",
        "  ",
        "1 ",
        "x",
        "3",
        "4",
        "2147483648",
        "-2147483649",
        "999999999999999999999999999999999999",
    };
    for (rejected) |value| {
        try std.testing.expectError(error.SubagentDepthLimit, checkValue(value));
    }
}
