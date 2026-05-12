const std = @import("std");
const posix = std.posix;
const cancel = @import("../zio/cancel.zig");
const cancel_waiter = @import("../zio/cancel_waiter.zig");

fn requestShutdownFd(req: anytype) ?posix.fd_t {
    const conn = req.connection orelse return null;
    return conn.stream_reader.stream.socket.handle;
}

pub const ShutdownOnCancel = struct {
    state: ?*State = null,
    waiter: cancel_waiter.Waiter = .{},

    const State = struct {
        target: posix.fd_t,
    };

    pub fn start(io: std.Io, token: cancel.Token, req: anytype) !ShutdownOnCancel {
        return startFd(io, token, requestShutdownFd(req));
    }

    fn startFd(io: std.Io, token: cancel.Token, target: ?posix.fd_t) !ShutdownOnCancel {
        if (token.isNone() or target == null) return .{};
        const state = try std.heap.page_allocator.create(State);
        state.* = .{ .target = target.? };
        const waiter = cancel_waiter.Waiter.start(io, token, .{ .ptr = @ptrCast(state), .call = abort }) catch |err| {
            std.heap.page_allocator.destroy(state);
            return err;
        };
        return .{ .state = state, .waiter = waiter };
    }

    pub fn stop(self: *ShutdownOnCancel) void {
        self.waiter.stop();
        if (self.state) |state| std.heap.page_allocator.destroy(state);
        self.* = .{};
    }

    fn abort(ctx: *anyopaque) void {
        const state: *State = @ptrCast(@alignCast(ctx));
        const SHUT_RDWR = 2;
        _ = std.posix.system.shutdown(state.target, SHUT_RDWR);
    }
};

test "ShutdownOnCancel stop is safe after abort watcher exits" {
    var fds: [2]posix.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.Unexpected;
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var source = cancel.Source{};
    const token = source.beginRun();
    var guard = try ShutdownOnCancel.startFd(std.Options.debug_io, token, fds[0]);

    source.requestAbort();
    std.Options.debug_io.sleep(.fromMilliseconds(10), .awake) catch {};
    guard.stop();
}
