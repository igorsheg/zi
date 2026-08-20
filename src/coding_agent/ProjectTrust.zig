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

/// Zi currently exposes only non-interactive launches. Until a durable trust
/// store is admitted, automatic resolution must not trust project prompt files.
pub fn resolve(intent: Intent) Decision {
    return switch (intent) {
        .automatic, .reject => .untrusted,
        .approve => .trusted,
    };
}

test "project trust defaults closed and honors explicit launch intent" {
    try std.testing.expectEqual(Decision.untrusted, resolve(.automatic));
    try std.testing.expectEqual(Decision.trusted, resolve(.approve));
    try std.testing.expectEqual(Decision.untrusted, resolve(.reject));
}
