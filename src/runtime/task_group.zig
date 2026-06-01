const std = @import("std");

/// Bounded structured concurrent task owner over `std.Io.Group`.
///
/// A successful `spawn` creates a drain obligation. Owners must call `await` or
/// `cancel` before `deinit`; this keeps task lifetime visible at the owner site
/// instead of relying on ambient future discipline.
pub const TaskGroup = struct {
    io: std.Io,
    group: std.Io.Group = .init,
    capacity: usize,
    started: usize = 0,
    closed: bool = false,
    drained: bool = true,

    pub const SpawnError = error{Full} || std.Io.ConcurrentError;

    pub fn init(io: std.Io, capacity: usize) TaskGroup {
        std.debug.assert(capacity > 0);
        return .{ .io = io, .capacity = capacity };
    }

    pub fn deinit(self: *TaskGroup) void {
        if (self.started > 0 and !self.drained) @panic("runtime.TaskGroup deinit before await or cancel");
        self.* = undefined;
    }

    pub fn spawn(
        self: *TaskGroup,
        function: anytype,
        args: std.meta.ArgsTuple(@TypeOf(function)),
    ) SpawnError!void {
        std.debug.assert(!self.closed);
        if (self.started == self.capacity) return error.Full;
        try self.group.concurrent(self.io, function, args);
        self.started += 1;
        self.drained = false;
    }

    pub fn await(self: *TaskGroup) std.Io.Cancelable!void {
        std.debug.assert(!self.closed);
        try self.group.await(self.io);
        self.closed = true;
        self.drained = true;
    }

    pub fn cancel(self: *TaskGroup) void {
        if (self.closed) return;
        self.group.cancel(self.io);
        self.closed = true;
        self.drained = true;
    }
};

fn waitForCancel(io: std.Io) std.Io.Cancelable!void {
    while (true) try io.sleep(.fromMilliseconds(1), .awake);
}

fn finishNow(_: std.Io) std.Io.Cancelable!void {}

test "task group requires bounded capacity" {
    var group = TaskGroup.init(std.testing.io, 1);
    defer group.deinit();

    try group.spawn(waitForCancel, .{std.testing.io});
    try std.testing.expectError(error.Full, group.spawn(waitForCancel, .{std.testing.io}));
    group.cancel();
}

test "task group await satisfies drain obligation" {
    var group = TaskGroup.init(std.testing.io, 1);
    defer group.deinit();

    try group.spawn(finishNow, .{std.testing.io});
    try group.await();
}
