const std = @import("std");
const race = @import("race.zig");

pub const CancelSource = struct {
    const WakeQueue = std.Io.Queue(u8);
    const WakeStorage = struct {
        buffer: [1]u8 = undefined,
        queue: WakeQueue,

        fn initInPlace(self: *WakeStorage) void {
            self.queue = WakeQueue.init(&self.buffer);
        }
    };

    requested: std.atomic.Value(bool) = .init(false),
    generation: std.atomic.Value(u64) = .init(0),
    allocator: std.mem.Allocator,
    wake_storage: *WakeStorage,

    pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!CancelSource {
        const wake_storage = try allocator.create(WakeStorage);
        wake_storage.initInPlace();
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
            .wake_queue = &self.wake_storage.queue,
        };
    }

    pub fn requestWithWake(self: *CancelSource, io: std.Io) void {
        if (self.requested.swap(true, .acq_rel)) return;
        self.wake_storage.queue.close(io);
    }

    pub fn resetAfterDrain(self: *CancelSource) void {
        self.requested.store(false, .release);
        const generation = self.generation.load(.acquire);
        std.debug.assert(generation < std.math.maxInt(u64));
        self.generation.store(generation + 1, .release);
        self.wake_storage.initInPlace();
    }
};

pub const CancelToken = struct {
    requested: *const std.atomic.Value(bool),
    generation: *const std.atomic.Value(u64),
    generation_value: u64,
    wake_queue: *CancelSource.WakeQueue,

    pub fn isRequested(self: CancelToken) bool {
        if (self.generation.load(.acquire) != self.generation_value) return true;
        return self.requested.load(.acquire);
    }

    pub fn throwIfRequested(self: CancelToken) error{OperationCancelled}!void {
        if (self.isRequested()) return error.OperationCancelled;
    }

    pub fn wait(self: CancelToken, io: std.Io) error{ OperationCancelled, Canceled }!void {
        if (self.isRequested()) return error.OperationCancelled;
        _ = self.wake_queue.getOne(io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.Closed => return error.OperationCancelled,
        };
        return error.OperationCancelled;
    }
};

const SleepCancelCompletion = union(enum) {
    sleep: error{Canceled}!void,
    cancel: error{ OperationCancelled, Canceled }!void,
};

pub fn sleepUntilCancel(
    io: std.Io,
    duration: std.Io.Duration,
    token: ?CancelToken,
) (std.Io.ConcurrentError || error{ OperationCancelled, Canceled })!void {
    if (token == null) {
        io.sleep(duration, .awake) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
        };
        return;
    }
    try token.?.throwIfRequested();

    var completion_buffer: [2]SleepCancelCompletion = undefined;
    var sleep_race = race.Race(SleepCancelCompletion).init(io, &completion_buffer);
    defer sleep_race.deinit();

    sleep_race.concurrent(.sleep, sleepTask, .{ io, duration }) catch |err| switch (err) {
        error.Full => unreachable,
        error.ConcurrencyUnavailable => return error.ConcurrencyUnavailable,
    };
    errdefer sleep_race.cancelAndDrain({}, drainSleepCancelCompletion);
    sleep_race.concurrent(.cancel, waitForCancelWake, .{ io, token.? }) catch |err| switch (err) {
        error.Full => unreachable,
        error.ConcurrencyUnavailable => return error.ConcurrencyUnavailable,
    };

    const completion = sleep_race.await() catch |err| {
        sleep_race.cancelAndDrain({}, drainSleepCancelCompletion);
        return err;
    };
    sleep_race.cancelAndDrain({}, drainSleepCancelCompletion);
    switch (completion) {
        .sleep => |result| try result,
        .cancel => |result| try result,
    }
}

fn sleepTask(io: std.Io, duration: std.Io.Duration) error{Canceled}!void {
    return io.sleep(duration, .awake);
}

fn drainSleepCancelCompletion(_: void, _: SleepCancelCompletion) void {
}

pub fn waitForCancelWake(io: std.Io, token: CancelToken) error{ OperationCancelled, Canceled }!void {
    return token.wait(io);
}

test "cancel source owns mutation and token only observes" {
    var source = try CancelSource.init(std.testing.allocator);
    defer source.deinit();
    const token = source.token();

    try std.testing.expect(!token.isRequested());
    source.requestWithWake(std.testing.io);
    try std.testing.expect(token.isRequested());
    source.resetAfterDrain();
    try std.testing.expect(token.isRequested());
    try std.testing.expect(!source.token().isRequested());
}

test "cancel token wait wakes without sleep polling" {
    var source = try CancelSource.init(std.testing.allocator);
    defer source.deinit();
    const token = source.token();
    var future = std.testing.io.async(waitForCancelWake, .{ std.testing.io, token });

    source.requestWithWake(std.testing.io);

    try std.testing.expectError(error.OperationCancelled, future.await(std.testing.io));
}

test "cancel request wakes all current waiters" {
    var source = try CancelSource.init(std.testing.allocator);
    defer source.deinit();
    const token = source.token();
    var first = std.testing.io.async(waitForCancelWake, .{ std.testing.io, token });
    var second = std.testing.io.async(waitForCancelWake, .{ std.testing.io, token });

    source.requestWithWake(std.testing.io);

    try std.testing.expectError(error.OperationCancelled, first.await(std.testing.io));
    try std.testing.expectError(error.OperationCancelled, second.await(std.testing.io));
}

test "cancel source reopens wake channel after owner drain" {
    var source = try CancelSource.init(std.testing.allocator);
    defer source.deinit();
    const first = source.token();
    source.requestWithWake(std.testing.io);
    source.resetAfterDrain();

    const second = source.token();
    try std.testing.expect(first.isRequested());
    try std.testing.expect(!second.isRequested());

    var future = std.testing.io.async(waitForCancelWake, .{ std.testing.io, second });
    source.requestWithWake(std.testing.io);
    try std.testing.expectError(error.OperationCancelled, future.await(std.testing.io));
}

test "cancel source can move after init without invalidating token wake storage" {
    const source = try CancelSource.init(std.testing.allocator);
    var moved = source;
    defer moved.deinit();
    const token = moved.token();
    var future = std.testing.io.async(waitForCancelWake, .{ std.testing.io, token });

    moved.requestWithWake(std.testing.io);

    try std.testing.expectError(error.OperationCancelled, future.await(std.testing.io));
}

test "sleep returns immediately when token is already canceled" {
    var source = try CancelSource.init(std.testing.allocator);
    defer source.deinit();
    source.requestWithWake(std.testing.io);

    try std.testing.expectError(
        error.OperationCancelled,
        sleepUntilCancel(std.Io.failing, .fromSeconds(60), source.token()),
    );
}

const SleepWorkerState = struct {
    source: *CancelSource,
    entered: std.atomic.Value(bool) = .init(false),
};

fn cancelableSleepWorker(io: std.Io, state: *SleepWorkerState) !void {
    state.entered.store(true, .release);
    try sleepUntilCancel(io, .fromSeconds(60), state.source.token());
}

test "sleep observes cancellation during retry delay" {
    var source = try CancelSource.init(std.testing.allocator);
    defer source.deinit();
    var state: SleepWorkerState = .{ .source = &source };
    var future = std.testing.io.async(cancelableSleepWorker, .{ std.testing.io, &state });

    while (!state.entered.load(.acquire)) {
        std.testing.io.sleep(.fromMilliseconds(1), .awake) catch |err| switch (err) {
            error.Canceled => return err,
        };
    }
    state.source.requestWithWake(std.testing.io);

    try std.testing.expectError(error.OperationCancelled, future.await(std.testing.io));
}
