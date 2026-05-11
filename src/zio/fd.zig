const std = @import("std");
const posix = std.posix;
const cancel = @import("cancel.zig");

pub fn pipe() ![2]posix.fd_t {
    var fds: [2]posix.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.Unexpected;
    return fds;
}

pub fn close(fd: posix.fd_t) void {
    _ = std.c.close(fd);
}

pub fn setNonblocking(fd: posix.fd_t) !void {
    const flags = std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0));
    if (flags < 0) return error.Unexpected;
    var new_flags: std.c.O = @bitCast(@as(c_uint, @intCast(flags)));
    new_flags.NONBLOCK = true;
    if (std.c.fcntl(fd, std.c.F.SETFL, @as(c_uint, @bitCast(new_flags))) < 0) return error.Unexpected;
}

pub fn setCloseOnExec(fd: posix.fd_t) !void {
    if (std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC)) < 0) return error.Unexpected;
}

pub fn httpRequestShutdownFd(req: anytype) ?posix.fd_t {
    const conn = req.connection orelse return null;
    return conn.stream_reader.stream.socket.handle;
}

pub const ShutdownOnCancel = struct {
    state: ?*State = null,
    thread: ?std.Thread = null,

    const State = struct {
        done: std.atomic.Value(bool) = .init(false),
        token: cancel.Token,
        target: posix.fd_t,
    };

    pub fn start(io: std.Io, token: cancel.Token, target: ?posix.fd_t) !ShutdownOnCancel {
        if (token.isNone() or target == null) return .{};
        const state = try std.heap.page_allocator.create(State);
        state.* = .{ .token = token, .target = target.? };
        const thread = std.Thread.spawn(.{}, watch, .{ io, state }) catch |err| {
            std.heap.page_allocator.destroy(state);
            return err;
        };
        return .{
            .state = state,
            .thread = thread,
        };
    }

    pub fn stop(self: *ShutdownOnCancel) void {
        if (self.state) |state| state.done.store(true, .release);
        if (self.thread) |thread| thread.detach();
        self.* = .{};
    }

    fn watch(io: std.Io, state: *State) void {
        defer std.heap.page_allocator.destroy(state);
        while (!state.done.load(.acquire)) {
            if (state.token.isAborted()) {
                const SHUT_RDWR = 2;
                _ = std.posix.system.shutdown(state.target, SHUT_RDWR);
                return;
            }
            io.sleep(.fromMilliseconds(10), .awake) catch {};
        }
    }
};
