const std = @import("std");

pub const CancelSource = struct {
    requested: std.atomic.Value(bool) = .init(false),

    pub fn token(self: *CancelSource) CancelToken {
        return .{ .requested = &self.requested };
    }

    pub fn request(self: *CancelSource) void {
        self.requested.store(true, .release);
    }

    pub fn reset(self: *CancelSource) void {
        self.requested.store(false, .release);
    }
};

pub const CancelToken = struct {
    requested: *const std.atomic.Value(bool),

    pub fn isRequested(self: CancelToken) bool {
        return self.requested.load(.acquire);
    }

    pub fn throwIfRequested(self: CancelToken) error{OperationCancelled}!void {
        if (self.isRequested()) return error.OperationCancelled;
    }
};

pub fn sleep(io: std.Io, duration: std.Io.Duration, token: ?CancelToken) error{ OperationCancelled, Canceled }!void {
    const chunk = std.Io.Duration.fromMilliseconds(10);
    var remaining_ns = duration.toNanoseconds();

    while (remaining_ns > 0) {
        if (token) |cancel_token| try cancel_token.throwIfRequested();

        const step_ns = @min(remaining_ns, chunk.toNanoseconds());
        io.sleep(.fromNanoseconds(step_ns), .awake) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
        };
        remaining_ns -= step_ns;
    }

    if (token) |cancel_token| try cancel_token.throwIfRequested();
}

test "cancel source owns mutation and token only observes" {
    var source: CancelSource = .{};
    const token = source.token();

    try std.testing.expect(!token.isRequested());
    source.request();
    try std.testing.expect(token.isRequested());
    source.reset();
    try std.testing.expect(!token.isRequested());
}

test "sleep returns immediately when token is already canceled" {
    var source: CancelSource = .{};
    source.request();

    try std.testing.expectError(
        error.OperationCancelled,
        sleep(std.Io.failing, .fromSeconds(60), source.token()),
    );
}

const SleepWorkerState = struct {
    source: CancelSource = .{},
    entered: std.atomic.Value(bool) = .init(false),
};

fn cancelableSleepWorker(io: std.Io, state: *SleepWorkerState) !void {
    state.entered.store(true, .release);
    try sleep(io, .fromSeconds(60), state.source.token());
}

test "sleep observes cancellation during retry delay" {
    var state: SleepWorkerState = .{};
    var future = std.testing.io.async(cancelableSleepWorker, .{ std.testing.io, &state });

    while (!state.entered.load(.acquire)) {
        std.testing.io.sleep(.fromMilliseconds(1), .awake) catch |err| switch (err) {
            error.Canceled => return err,
        };
    }
    state.source.request();

    try std.testing.expectError(error.OperationCancelled, future.await(std.testing.io));
}
