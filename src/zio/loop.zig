const std = @import("std");
const posix = std.posix;
const deadline = @import("deadline.zig");
const timer = @import("timer.zig");

pub const Interest = packed struct {
    read: bool = false,
};

pub const Ready = packed struct {
    read: bool = false,
    hangup: bool = false,
    err: bool = false,
};

pub const Callback = struct {
    ptr: ?*anyopaque = null,
    call: *const fn (ptr: ?*anyopaque, ready: Ready) void,
};

pub const Source = struct {
    fd: posix.fd_t,
    interest: Interest,
    callback: Callback,
};

pub const Loop = struct {
    allocator: std.mem.Allocator,
    sources: std.ArrayList(Source) = .empty,
    timers: timer.Queue,

    pub fn init(allocator: std.mem.Allocator) Loop {
        return .{ .allocator = allocator, .timers = timer.Queue.init(allocator) };
    }

    pub fn deinit(self: *Loop) void {
        self.timers.deinit();
        self.sources.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn register(self: *Loop, source: Source) !usize {
        try self.sources.append(self.allocator, source);
        return self.sources.items.len - 1;
    }

    pub fn unregister(self: *Loop, handle: usize) void {
        if (handle >= self.sources.items.len) return;
        _ = self.sources.swapRemove(handle);
    }

    pub fn clear(self: *Loop) void {
        self.sources.clearRetainingCapacity();
        self.timers.clear();
    }

    pub fn addTimerAt(self: *Loop, deadline_ns: i128, callback: timer.Callback) !timer.Handle {
        return self.timers.addAt(deadline_ns, callback);
    }

    pub fn addTimerAfterMs(self: *Loop, io: std.Io, ms: u64, callback: timer.Callback) !timer.Handle {
        return self.timers.addAfterMs(io, ms, callback);
    }

    pub fn cancelTimer(self: *Loop, handle: timer.Handle) void {
        self.timers.cancel(handle);
    }

    pub fn runOnce(self: *Loop, io: std.Io, timeout_ms: i32) !usize {
        const now_ns = deadline.nowNs(io);
        const poll_timeout_ms = self.timers.timeoutMs(now_ns, timeout_ms);
        var dispatched = try runSources(self.allocator, self.sources.items, poll_timeout_ms);
        dispatched += self.timers.fireExpired(deadline.nowNs(io));
        return dispatched;
    }
};

pub fn runSources(allocator: std.mem.Allocator, sources: []const Source, timeout_ms: i32) !usize {
    if (sources.len == 0) {
        if (timeout_ms > 0) std.Options.debug_io.sleep(.fromMilliseconds(@intCast(timeout_ms)), .awake) catch {};
        return 0;
    }

    var pfds = try allocator.alloc(posix.pollfd, sources.len);
    defer allocator.free(pfds);

    for (sources, 0..) |source, i| {
        pfds[i] = .{
            .fd = source.fd,
            .events = eventsFromInterest(source.interest),
            .revents = 0,
        };
    }

    const ready_count = try posix.poll(pfds, timeout_ms);
    if (ready_count <= 0) return 0;

    var dispatched: usize = 0;
    for (pfds, 0..) |pfd, i| {
        if (pfd.revents == 0) continue;
        dispatched += 1;
        sources[i].callback.call(sources[i].callback.ptr, readyFromRevents(pfd.revents));
    }
    return dispatched;
}

fn eventsFromInterest(interest: Interest) i16 {
    var events: i16 = 0;
    if (interest.read) events |= posix.POLL.IN;
    return events;
}

fn readyFromRevents(revents: i16) Ready {
    return .{
        .read = revents & posix.POLL.IN != 0,
        .hangup = revents & posix.POLL.HUP != 0,
        .err = revents & posix.POLL.ERR != 0,
    };
}

test "Loop dispatches readable fd callbacks" {
    const wake = @import("wake.zig");
    var pipe = try wake.Pipe.init();
    defer pipe.deinit();

    const Ctx = struct {
        called: bool = false,
        fn onReady(ptr: ?*anyopaque, ready: Ready) void {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            self.called = ready.read;
        }
    };

    var ctx = Ctx{};
    var loop = Loop.init(std.testing.allocator);
    defer loop.deinit();
    _ = try loop.register(.{
        .fd = pipe.readFd(),
        .interest = .{ .read = true },
        .callback = .{ .ptr = @ptrCast(&ctx), .call = Ctx.onReady },
    });

    try std.testing.expect(pipe.signal(std.Options.debug_io));
    try std.testing.expectEqual(@as(usize, 1), try loop.runOnce(std.Options.debug_io, 0));
    try std.testing.expect(ctx.called);
}

test "Loop dispatches timer callbacks" {
    const Ctx = struct {
        called: bool = false,
        fn onTimer(ptr: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            self.called = true;
        }
    };

    var ctx = Ctx{};
    var loop = Loop.init(std.testing.allocator);
    defer loop.deinit();

    _ = try loop.addTimerAt(deadline.nowNs(std.Options.debug_io), .{ .ptr = @ptrCast(&ctx), .call = Ctx.onTimer });
    try std.testing.expectEqual(@as(usize, 1), try loop.runOnce(std.Options.debug_io, 50));
    try std.testing.expect(ctx.called);
}
