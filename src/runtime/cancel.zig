const std = @import("std");
const async_runtime = @import("Runtime.zig");
const Runtime = async_runtime.Runtime;

pub const CancelSource = struct {
    const WakeStorage = struct {
        event: async_runtime.ResetEvent = .init,
    };

    requested: std.atomic.Value(bool) = .init(false),
    generation: std.atomic.Value(u64) = .init(0),
    allocator: std.mem.Allocator,
    wake_storage: *WakeStorage,

    pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!CancelSource {
        const wake_storage = try allocator.create(WakeStorage);
        wake_storage.* = .{};
        return .{
            .allocator = allocator,
            .wake_storage = wake_storage,
        };
    }

    pub fn deinit(self: *CancelSource) void {
        self.allocator.destroy(self.wake_storage);
        self.* = undefined;
    }

    pub fn token(self: *CancelSource) CancelToken {
        return .{
            .requested = &self.requested,
            .generation = &self.generation,
            .generation_value = self.generation.load(.acquire),
            .wake_event = &self.wake_storage.event,
        };
    }

    pub fn request(self: *CancelSource) void {
        if (self.requested.swap(true, .acq_rel)) return;
        self.wake_storage.event.set();
    }

    pub fn resetAfterDrain(self: *CancelSource) void {
        self.requested.store(false, .release);
        const generation = self.generation.load(.acquire);
        std.debug.assert(generation < std.math.maxInt(u64));
        self.generation.store(generation + 1, .release);
        self.wake_storage.event.reset();
    }
};

pub const CancelToken = struct {
    requested: *const std.atomic.Value(bool),
    generation: *const std.atomic.Value(u64),
    generation_value: u64,
    wake_event: *async_runtime.ResetEvent,

    pub fn isRequested(self: CancelToken) bool {
        if (self.generation.load(.acquire) != self.generation_value) return true;
        return self.requested.load(.acquire);
    }

    pub fn throwIfRequested(self: CancelToken) error{OperationCancelled}!void {
        if (self.isRequested()) return error.OperationCancelled;
    }

    pub fn wait(self: CancelToken) error{ OperationCancelled, Canceled }!void {
        if (self.isRequested()) return error.OperationCancelled;
        self.wake_event.wait() catch |err| switch (err) {
            error.Canceled => return error.Canceled,
        };
        return error.OperationCancelled;
    }
};

pub fn sleepUntilCancel(
    io: std.Io,
    duration: std.Io.Duration,
    token: ?CancelToken,
) error{ OperationCancelled, Canceled }!void {
    if (token == null) {
        try io.sleep(duration, .awake);
        return;
    }
    const cancel_token = token.?;
    try cancel_token.throwIfRequested();
    cancel_token.wake_event.timedWait(toTimeout(duration)) catch |err| switch (err) {
        error.Timeout => {
            try cancel_token.throwIfRequested();
            return;
        },
        error.Canceled => return error.Canceled,
    };
    return error.OperationCancelled;
}

fn toTimeout(duration: std.Io.Duration) async_runtime.Timeout {
    const nanoseconds = duration.toNanoseconds();
    std.debug.assert(nanoseconds >= 0);
    return .fromNanoseconds(std.math.cast(u64, nanoseconds) orelse std.math.maxInt(u64));
}

fn waitForCancelWake(token: CancelToken) error{ OperationCancelled, Canceled }!void {
    return token.wait();
}

test "cancel source owns mutation and token only observes" {
    var source = try CancelSource.init(std.testing.allocator);
    defer source.deinit();
    const token = source.token();

    try std.testing.expect(!token.isRequested());
    source.request();
    try std.testing.expect(token.isRequested());
    source.resetAfterDrain();
    try std.testing.expect(token.isRequested());
    try std.testing.expect(!source.token().isRequested());
}

test "cancel token wait wakes without sleep polling" {
    var task_runtime = try Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var source = try CancelSource.init(std.testing.allocator);
    defer source.deinit();
    const token = source.token();
    var future = try task_runtime.spawn(waitForCancelWake, .{token});
    defer future.cancel();

    source.request();

    try std.testing.expectError(error.OperationCancelled, future.join());
}

test "cancel request wakes all current waiters" {
    var task_runtime = try Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var source = try CancelSource.init(std.testing.allocator);
    defer source.deinit();
    const token = source.token();
    var first = try task_runtime.spawn(waitForCancelWake, .{token});
    defer first.cancel();
    var second = try task_runtime.spawn(waitForCancelWake, .{token});
    defer second.cancel();

    source.request();

    try std.testing.expectError(error.OperationCancelled, first.join());
    try std.testing.expectError(error.OperationCancelled, second.join());
}

test "cancel source reopens wake channel after owner drain" {
    var task_runtime = try Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var source = try CancelSource.init(std.testing.allocator);
    defer source.deinit();
    const first = source.token();
    source.request();
    source.resetAfterDrain();

    const second = source.token();
    try std.testing.expect(first.isRequested());
    try std.testing.expect(!second.isRequested());

    var future = try task_runtime.spawn(waitForCancelWake, .{second});
    defer future.cancel();
    source.request();
    try std.testing.expectError(error.OperationCancelled, future.join());
}

test "cancel source can move after init without invalidating token wake storage" {
    var task_runtime = try Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    const source = try CancelSource.init(std.testing.allocator);
    var moved = source;
    defer moved.deinit();
    const token = moved.token();
    var future = try task_runtime.spawn(waitForCancelWake, .{token});
    defer future.cancel();

    moved.request();

    try std.testing.expectError(error.OperationCancelled, future.join());
}

test "sleep returns immediately when token is already canceled" {
    var task_runtime = try Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var source = try CancelSource.init(std.testing.allocator);
    defer source.deinit();
    source.request();

    try std.testing.expectError(
        error.OperationCancelled,
        sleepUntilCancel(task_runtime.io(), .fromSeconds(60), source.token()),
    );
}

const SleepWorkerState = struct {
    io: std.Io,
    source: *CancelSource,
    entered: async_runtime.ResetEvent = .init,
};

fn cancelableSleepWorker(state: *SleepWorkerState) !void {
    state.entered.set();
    try sleepUntilCancel(state.io, .fromSeconds(60), state.source.token());
}

test "sleep observes cancellation during retry delay" {
    var task_runtime = try Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var source = try CancelSource.init(std.testing.allocator);
    defer source.deinit();
    var state: SleepWorkerState = .{ .io = task_runtime.io(), .source = &source };
    var future = try task_runtime.spawn(cancelableSleepWorker, .{&state});
    defer future.cancel();

    try state.entered.wait();
    state.source.request();

    try std.testing.expectError(error.OperationCancelled, future.join());
}
