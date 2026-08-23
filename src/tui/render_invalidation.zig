const std = @import("std");

/// Owns one detached dirty snapshot until a frame either commits or restores
/// the invalidation for a later attempt.
pub const Attempt = struct {
    state: *State,
    active: bool = true,

    pub fn commit(self: *Attempt) void {
        std.debug.assert(self.active);
        self.state.finishAttempt();
        self.active = false;
    }

    pub fn deinit(self: *Attempt) void {
        if (self.active) {
            self.state.pending = true;
            self.state.attempt_active = false;
        }
        self.* = undefined;
    }
};

/// Coalesces any number of frame invalidations while preserving requests made
/// during an in-flight publication attempt.
pub const State = struct {
    pending: bool = false,
    attempt_active: bool = false,

    pub fn invalidate(self: *State) void {
        self.pending = true;
    }

    pub fn hasPending(self: State) bool {
        return self.pending;
    }

    pub fn beginAttempt(self: *State) error{AttemptInProgress}!?Attempt {
        if (self.attempt_active) return error.AttemptInProgress;
        if (!self.pending) return null;
        self.pending = false;
        self.attempt_active = true;
        return .{ .state = self };
    }

    fn finishAttempt(self: *State) void {
        std.debug.assert(self.attempt_active);
        self.attempt_active = false;
    }
};

test "uncommitted attempt restores invalidation" {
    var state: State = .{};
    state.invalidate();
    {
        var attempt = (try state.beginAttempt()).?;
        defer attempt.deinit();
        try std.testing.expect(!state.hasPending());
    }
    try std.testing.expect(state.hasPending());
    var retry = (try state.beginAttempt()).?;
    retry.commit();
    retry.deinit();
    try std.testing.expect(!state.hasPending());
}

test "invalidation during an attempt survives commit" {
    var state: State = .{};
    state.invalidate();
    var attempt = (try state.beginAttempt()).?;
    defer attempt.deinit();
    state.invalidate();
    attempt.commit();
    try std.testing.expect(state.hasPending());
    var pending = (try state.beginAttempt()).?;
    pending.commit();
}
