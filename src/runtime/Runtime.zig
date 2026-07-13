const std = @import("std");
const zio_backend = @import("zio_backend.zig");

pub const Cancelable = std.Io.Cancelable;
pub const Duration = std.Io.Duration;
pub const Options = struct {};

pub const Mutex = zio_backend.Mutex;

pub fn Task(comptime T: type) type {
    return struct {
        const Self = @This();
        const ZioTask = zio_backend.JoinHandle(T);

        handle: ZioTask,
        result: T = undefined,
        settled: bool = false,

        pub const Result = T;

        pub fn join(self: *Self) T {
            if (!self.settled) {
                self.result = self.handle.join();
                self.settled = true;
            }
            return self.result;
        }

        pub fn cancel(self: *Self) void {
            if (!self.settled) {
                self.handle.cancel();
                self.result = self.handle.result;
                self.settled = true;
            }
        }

        pub fn hasResult(self: *const Self) bool {
            if (self.settled) return true;
            return self.handle.hasResult();
        }

        pub fn getResult(self: *Self) T {
            if (!self.settled) {
                std.debug.assert(self.handle.hasResult());
                self.result = self.handle.join();
                self.settled = true;
            }
            return self.result;
        }
    };
}

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    inner: *zio_backend.Runtime,

    pub fn init(allocator: std.mem.Allocator, options: Options) !*Runtime {
        _ = options;
        const self = try allocator.create(Runtime);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .inner = try zio_backend.Runtime.init(allocator, .{}),
        };
        return self;
    }

    // ziglint-ignore: Z030 heap owner is poisoned before allocator.destroy(self).
    pub fn deinit(self: *Runtime) void {
        self.inner.deinit();
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn io(self: *Runtime) std.Io {
        return self.inner.io();
    }

    pub fn spawn(
        self: *Runtime,
        function: anytype,
        args: std.meta.ArgsTuple(@TypeOf(function)),
    ) !Task(@typeInfo(@TypeOf(function)).@"fn".return_type.?) {
        return .{ .handle = try self.inner.spawn(function, args) };
    }

    pub fn spawnBlocking(
        self: *Runtime,
        function: anytype,
        args: std.meta.ArgsTuple(@TypeOf(function)),
    ) !Task(@typeInfo(@TypeOf(function)).@"fn".return_type.?) {
        return .{ .handle = try self.inner.spawnBlocking(function, args) };
    }

    pub fn sleep(self: *Runtime, duration: Duration) Cancelable!void {
        try self.io().sleep(duration, .awake);
    }
};

pub fn sleep(io: std.Io, duration: Duration) Cancelable!void {
    return io.sleep(duration, .awake);
}

pub fn yield() Cancelable!void {
    return zio_backend.yield();
}

fn testTaskResult() usize {
    return 42;
}

test "getResult consumes a completed task handle" {
    var task_runtime = try Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var task = try task_runtime.spawn(testTaskResult, .{});
    while (!task.hasResult()) try yield();
    try std.testing.expectEqual(@as(usize, 42), task.getResult());
    try std.testing.expectEqual(@as(usize, 42), task.getResult());
}
