const std = @import("std");

pub const Intent = enum {
    automatic,
    approve,
    reject,
};

pub const Decision = enum {
    untrusted,
    trusted,
};

/// Explicit launch intent wins without mutating saved policy. Automatic
/// resolution uses the nearest saved decision and otherwise defaults closed.
pub fn resolve(intent: Intent, saved: ?Decision) Decision {
    return switch (intent) {
        .automatic => saved orelse .untrusted,
        .approve => .trusted,
        .reject => .untrusted,
    };
}

test "project trust defaults closed and honors saved and explicit intent" {
    try std.testing.expectEqual(Decision.untrusted, resolve(.automatic, null));
    try std.testing.expectEqual(Decision.trusted, resolve(.automatic, .trusted));
    try std.testing.expectEqual(Decision.untrusted, resolve(.automatic, .untrusted));
    try std.testing.expectEqual(Decision.trusted, resolve(.approve, .untrusted));
    try std.testing.expectEqual(Decision.untrusted, resolve(.reject, .trusted));
}
