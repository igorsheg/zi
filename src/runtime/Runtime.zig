const std = @import("std");
const zio = @import("zio");

pub const Cancelable = error{Canceled};

pub const Duration = struct {
    inner: zio.Duration,

    pub const zero: Duration = .{ .inner = zio.Duration.zero };
    pub const max: Duration = .{ .inner = zio.Duration.max };

    pub fn fromNanoseconds(ns: u64) Duration {
        return .{ .inner = zio.Duration.fromNanoseconds(ns) };
    }

    pub fn fromMicroseconds(us: u64) Duration {
        return .{ .inner = zio.Duration.fromMicroseconds(us) };
    }

    pub fn fromMilliseconds(ms: u64) Duration {
        return .{ .inner = zio.Duration.fromMilliseconds(ms) };
    }

    pub fn fromSeconds(s: u64) Duration {
        return .{ .inner = zio.Duration.fromSeconds(s) };
    }

    pub fn fromMinutes(m: u64) Duration {
        return .{ .inner = zio.Duration.fromMinutes(m) };
    }

    pub fn toNanoseconds(self: Duration) u128 {
        return self.inner.toNanoseconds();
    }

    pub fn format(self: Duration, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try self.inner.format(writer);
    }
};

pub const Timeout = struct {
    inner: zio.Timeout,

    pub const Result = void;
    pub const WaitContext = zio.Timeout.WaitContext;

    pub const none: Timeout = .{ .inner = .none };

    pub fn fromNanoseconds(ns: u64) Timeout {
        return .{ .inner = zio.Timeout.fromNanoseconds(ns) };
    }

    pub fn fromMicroseconds(us: u64) Timeout {
        return .{ .inner = zio.Timeout.fromMicroseconds(us) };
    }

    pub fn fromMilliseconds(ms: u64) Timeout {
        return .{ .inner = zio.Timeout.fromMilliseconds(ms) };
    }

    pub fn fromSeconds(s: u64) Timeout {
        return .{ .inner = zio.Timeout.fromSeconds(s) };
    }

    pub fn fromMinutes(m: u64) Timeout {
        return .{ .inner = zio.Timeout.fromMinutes(m) };
    }

    pub fn asyncWait(self: *const Timeout, waiter: *zio.Waiter, context: *WaitContext) bool {
        return self.inner.asyncWait(waiter, context);
    }

    pub fn asyncCancelWait(self: *const Timeout, waiter: *zio.Waiter, context: *WaitContext) bool {
        return self.inner.asyncCancelWait(waiter, context);
    }

    pub fn getResult(self: *const Timeout, context: *WaitContext) void {
        return self.inner.getResult(context);
    }
};

pub const ResetEvent = struct {
    inner: zio.ResetEvent = .init,

    pub const Result = void;
    pub const init: ResetEvent = .{};

    pub fn isSet(self: *const ResetEvent) bool {
        return self.inner.isSet();
    }

    pub fn set(self: *ResetEvent) void {
        self.inner.set();
    }

    pub fn reset(self: *ResetEvent) void {
        self.inner.reset();
    }

    pub fn wait(self: *ResetEvent) Cancelable!void {
        try self.inner.wait();
    }

    pub fn timedWait(self: *ResetEvent, timeout: Timeout) error{ Timeout, Canceled }!void {
        try self.inner.timedWait(timeout.inner);
    }

    pub fn asyncWait(self: *ResetEvent, waiter: *zio.Waiter) bool {
        return self.inner.asyncWait(waiter);
    }

    pub fn asyncCancelWait(self: *ResetEvent, waiter: *zio.Waiter) bool {
        return self.inner.asyncCancelWait(waiter);
    }

    pub fn getResult(self: *const ResetEvent) void {
        return self.inner.getResult();
    }
};

pub fn Channel(comptime Event: type) type {
    return struct {
        const Self = @This();
        const ZioChannel = zio.Channel(Event);

        inner: ZioChannel,

        pub const CloseMode = enum { graceful, immediate };

        pub fn init(buffer: []Event) Self {
            return .{ .inner = ZioChannel.init(buffer) };
        }

        pub fn receive(self: *Self) error{ ChannelClosed, Canceled }!Event {
            return self.inner.receive();
        }

        pub fn tryReceive(self: *Self) error{ ChannelEmpty, ChannelClosed }!Event {
            return self.inner.tryReceive();
        }

        pub fn send(self: *Self, event: Event) error{ ChannelClosed, Canceled }!void {
            try self.inner.send(event);
        }

        pub fn trySend(self: *Self, event: Event) error{ ChannelFull, ChannelClosed }!void {
            try self.inner.trySend(event);
        }

        pub fn close(self: *Self, mode: CloseMode) void {
            self.inner.close(switch (mode) {
                .graceful => .graceful,
                .immediate => .immediate,
            });
        }

        pub fn asyncReceive(self: *Self) @TypeOf(self.inner.asyncReceive()) {
            return self.inner.asyncReceive();
        }
    };
}

pub fn Task(comptime T: type) type {
    return struct {
        const Self = @This();
        const ZioTask = zio.JoinHandle(T);

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
                self.result = self.handle.getResult();
                self.settled = true;
            }
            return self.result;
        }

        pub fn asyncWait(self: *Self, waiter: *zio.Waiter) bool {
            if (self.settled) return false;
            return self.handle.asyncWait(waiter);
        }

        pub fn asyncCancelWait(self: *Self, waiter: *zio.Waiter) bool {
            if (self.settled) return true;
            return self.handle.asyncCancelWait(waiter);
        }
    };
}

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    inner: *zio.Runtime,

    pub fn init(allocator: std.mem.Allocator, options: zio.RuntimeOptions) !*Runtime {
        const self = try allocator.create(Runtime);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .inner = try zio.Runtime.init(allocator, options),
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

    pub fn backend(self: *Runtime) *zio.Runtime {
        return self.inner;
    }

    pub fn spawn(
        self: *Runtime,
        function: anytype,
        args: std.meta.ArgsTuple(@TypeOf(function)),
    ) !Task(@typeInfo(@TypeOf(function)).@"fn".return_type.?) {
        return .{ .handle = try self.inner.spawn(function, args) };
    }

    pub fn sleep(self: *Runtime, duration: Duration) Cancelable!void {
        _ = self;
        try zio.sleep(duration.inner);
    }
};

pub fn select(args: anytype) @TypeOf(zio.select(args)) {
    return zio.select(args);
}

pub fn sleep(duration: Duration) Cancelable!void {
    return zio.sleep(duration.inner);
}

pub fn yield() Cancelable!void {
    return zio.yield();
}
