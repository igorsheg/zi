const std = @import("std");
const zio = @import("zio");
const ev = zio.ev;
const Waiter = zio.Waiter;

pub const ReadableFdError = ev.PipePoll.Error;

pub const ReadableFd = struct {
    fd: std.posix.fd_t,

    pub fn initBorrowed(fd: std.posix.fd_t) ReadableFd {
        return .{ .fd = fd };
    }

    pub fn asyncReadable(self: ReadableFd) ReadableWait {
        return .{ .fd = self.fd };
    }
};

pub const ReadableWait = struct {
    fd: std.posix.fd_t,

    pub const Result = ReadableFdError!void;

    pub const WaitContext = struct {
        poll: ev.PipePoll = ev.PipePoll.init(0, .read),
        waiter: ?*Waiter = null,
    };

    pub fn asyncWait(self: *const ReadableWait, waiter: *Waiter, ctx: *WaitContext) bool {
        ctx.poll = ev.PipePoll.init(self.fd, .read);
        ctx.waiter = waiter;
        ctx.poll.c.userdata = ctx;
        ctx.poll.c.callback = callback;
        zio.getCurrentExecutor().loop.add(&ctx.poll.c);
        return true;
    }

    pub fn asyncCancelWait(self: *const ReadableWait, waiter: *Waiter, ctx: *WaitContext) bool {
        _ = self;
        _ = waiter;
        const loop = ctx.poll.c.loop orelse return true;
        loop.cancel(&ctx.poll.c);
        return false;
    }

    pub fn getResult(self: *const ReadableWait, ctx: *WaitContext) Result {
        _ = self;
        return ctx.poll.getResult();
    }

    fn callback(_: *ev.Loop, completion: *ev.Completion) void {
        const ctx: *WaitContext = @ptrCast(@alignCast(completion.userdata.?));
        if (ctx.waiter) |waiter| waiter.signal();
    }
};

test "readable fd loses to timeout when pipe has no data" {
    var rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const pair = try zio.createPipe();
    defer pair.close();

    const readable = ReadableFd.initBorrowed(pair.read.fd);
    var wait = readable.asyncReadable();
    var timeout = zio.Timeout.fromMilliseconds(1);

    const result = try zio.select(.{ .input = &wait, .timeout = &timeout });
    try std.testing.expect(result == .timeout);
}

test "readable fd wins after pipe write" {
    var rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const pair = try zio.createPipe();
    defer pair.close();

    _ = try pair.write.write("x", zio.Timeout.fromMilliseconds(100));

    const readable = ReadableFd.initBorrowed(pair.read.fd);
    var wait = readable.asyncReadable();
    var timeout = zio.Timeout.fromMilliseconds(100);

    const result = try zio.select(.{ .input = &wait, .timeout = &timeout });
    try std.testing.expect(result == .input);
    try result.input;
}
