const std = @import("std");

pub const Reason = enum {
    first_frame,
    transcript,
    footer,
    resize,
    notice,
};

pub const ReasonSet = std.EnumSet(Reason);

/// Owns one detached request snapshot until the frame either commits or the
/// attempt restores its reasons for a later commit. This keeps the transaction
/// shape of fx's `ui/render_request.zig` without importing its product states.
pub const Attempt = struct {
    state: *State,
    reasons: ReasonSet,
    active: bool = true,

    pub fn commit(self: *Attempt) void {
        std.debug.assert(self.active);
        self.state.finishAttempt();
        self.active = false;
    }

    pub fn deinit(self: *Attempt) void {
        if (self.active) {
            self.state.pending.setUnion(self.reasons);
            self.state.attempt_active = false;
        }
        self.* = undefined;
    }
};

pub const State = struct {
    pending: ReasonSet = .empty,
    attempt_active: bool = false,

    pub fn request(self: *State, reason: Reason) void {
        self.pending.insert(reason);
    }

    pub fn hasPending(self: State) bool {
        return self.pending.count() != 0;
    }

    pub fn beginAttempt(self: *State) error{AttemptInProgress}!?Attempt {
        if (self.attempt_active) return error.AttemptInProgress;
        if (!self.hasPending()) return null;
        const reasons = self.pending;
        self.pending = .empty;
        self.attempt_active = true;
        return .{ .state = self, .reasons = reasons };
    }

    fn finishAttempt(self: *State) void {
        std.debug.assert(self.attempt_active);
        self.attempt_active = false;
    }
};

test "uncommitted attempt restores its detached reasons" {
    var state: State = .{};
    state.request(.transcript);
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

test "requests made during an attempt survive its commit" {
    var state: State = .{};
    state.request(.footer);
    var attempt = (try state.beginAttempt()).?;
    defer attempt.deinit();
    state.request(.transcript);
    attempt.commit();
    try std.testing.expect(state.hasPending());
    const next = (try state.beginAttempt()).?;
    try std.testing.expect(next.reasons.contains(.transcript));
    var pending = next;
    pending.commit();
}
