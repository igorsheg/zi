const std = @import("std");

/// Typed abort signal for cooperative cancellation.
/// Passed through agent loop → provider → tool execution.
/// All layers check isAborted() at cancellation points.
pub const AbortSignal = struct {
    flag: *const std.atomic.Value(bool),

    /// Sentinel for "no abort signal" — never triggers.
    pub const none: AbortSignal = .{ .flag = &never_aborted };

    pub fn isAborted(self: AbortSignal) bool {
        return self.flag.load(.acquire);
    }

    pub fn isNone(self: AbortSignal) bool {
        return self.flag == &never_aborted;
    }

    var never_aborted = std.atomic.Value(bool).init(false);
};
