const std = @import("std");
const posix = std.posix;
const cancel = @import("../zio/cancel.zig");

pub fn requestShutdownFd(req: anytype) ?posix.fd_t {
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
        return .{ .state = state, .thread = thread };
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
