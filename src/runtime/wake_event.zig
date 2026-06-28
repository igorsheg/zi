const std = @import("std");

pub const WakeEvent = struct {
    event: std.Io.Event = .unset,

    pub const init: WakeEvent = .{};

    pub fn isSet(self: *const WakeEvent) bool {
        return self.event.isSet();
    }

    pub fn set(self: *WakeEvent, io: std.Io) void {
        self.event.set(io);
    }

    pub fn reset(self: *WakeEvent) void {
        self.event.reset();
    }

    pub fn wait(self: *WakeEvent, io: std.Io) std.Io.Cancelable!void {
        try self.event.wait(io);
    }

    pub fn waitTimeout(self: *WakeEvent, io: std.Io, timeout: std.Io.Timeout) error{ Timeout, Canceled }!void {
        try self.event.waitTimeout(io, timeout);
    }
};

test "wake event set reset and immediate wait" {
    var wake: WakeEvent = .init;
    const io = std.testing.io;

    try std.testing.expect(!wake.isSet());
    wake.set(io);
    try std.testing.expect(wake.isSet());
    try wake.wait(io);
    wake.reset();
    try std.testing.expect(!wake.isSet());
}

test "wake event reports timeout while unset" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var wake: WakeEvent = .init;
    try std.testing.expectError(error.Timeout, wake.waitTimeout(io, .{ .duration = .{
        .raw = .fromMilliseconds(1),
        .clock = .awake,
    } }));
}

test "wake event set before wait is observed" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var wake: WakeEvent = .init;
    wake.set(io);
    try wake.waitTimeout(io, .{ .duration = .{
        .raw = .fromMilliseconds(1),
        .clock = .awake,
    } });
    try std.testing.expect(wake.isSet());
}

test "wake event set from raw thread wakes std io waiter" {
    const Producer = struct {
        io: std.Io,
        wake: *WakeEvent,
        ready: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            while (!self.ready.load(.acquire)) std.Thread.yield() catch {};
            self.wake.set(self.io);
        }
    };

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var wake: WakeEvent = .init;
    var producer: Producer = .{ .io = io, .wake = &wake };
    const thread = try std.Thread.spawn(.{}, Producer.run, .{&producer});
    defer thread.join();

    producer.ready.store(true, .release);
    try wake.waitTimeout(io, .{ .duration = .{
        .raw = .fromMilliseconds(1000),
        .clock = .awake,
    } });
    try std.testing.expect(wake.isSet());
}
