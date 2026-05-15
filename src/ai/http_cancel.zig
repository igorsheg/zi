const std = @import("std");
const posix = std.posix;
const cancel = @import("../zio/cancel.zig");

fn requestShutdownFd(req: anytype) ?posix.fd_t {
    const conn = req.connection orelse return null;
    return conn.stream_reader.stream.socket.handle;
}

pub const ShutdownOnCancel = struct {
    state: ?*State = null,
    token: cancel.Token = cancel.Token.none,

    const State = struct {
        node: cancel.Token.CallbackNode = undefined,
        target: posix.fd_t,
    };

    pub fn start(_: std.Io, token: cancel.Token, req: anytype) !ShutdownOnCancel {
        return startFd(token, requestShutdownFd(req));
    }

    fn startFd(token: cancel.Token, target: ?posix.fd_t) !ShutdownOnCancel {
        if (token.isNone() or target == null) return .{};
        const state = try std.heap.smp_allocator.create(State);
        state.* = .{ .target = target.? };
        token.registerCallback(&state.node, .{ .ptr = @ptrCast(state), .call = abort });
        return .{ .state = state, .token = token };
    }

    pub fn stop(self: *ShutdownOnCancel) void {
        if (self.state) |state| {
            self.token.unregisterCallback(&state.node);
            std.heap.smp_allocator.destroy(state);
        }
        self.* = .{};
    }

    fn abort(ctx: *anyopaque) void {
        const state: *State = @ptrCast(@alignCast(ctx));
        const SHUT_RDWR = 2;
        _ = std.posix.system.shutdown(state.target, SHUT_RDWR);
    }
};

test "ShutdownOnCancel abort callback shuts down fd" {
    var fds: [2]posix.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.Unexpected;
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var source = cancel.Source{};
    defer source.deinit();
    const token = source.beginRun();
    var guard = try ShutdownOnCancel.startFd(token, fds[0]);

    source.requestAbort();
    guard.stop();
}
