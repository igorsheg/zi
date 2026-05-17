const std = @import("std");
const cancel = @import("cancel.zig");

const poll_interval_ns = 10 * std.time.ns_per_ms;

pub fn requestStream(req: anytype) ?std.Io.net.Stream {
    const conn = req.connection orelse return null;
    return conn.stream_reader.stream;
}

pub const ShutdownOnCancel = union(enum) {
    inactive,
    active: Active,

    const Active = struct {
        allocator: std.mem.Allocator,
        state: *State,
        thread: std.Thread,
    };

    const State = struct {
        io: std.Io,
        stream: std.Io.net.Stream,
        token: cancel.Token,
        stop: std.atomic.Value(bool) = .init(false),
    };

    pub fn start(
        allocator: std.mem.Allocator,
        io: std.Io,
        token: cancel.Token,
        stream: ?std.Io.net.Stream,
    ) !ShutdownOnCancel {
        if (token.isNone()) return .inactive;
        const request_stream = stream orelse return .inactive;
        if (token.isAborted()) {
            interruptRequest(io, request_stream);
            return .inactive;
        }

        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        state.* = .{ .io = io, .stream = request_stream, .token = token };

        const thread = try std.Thread.spawn(.{}, watch, .{state});
        return .{ .active = .{ .allocator = allocator, .state = state, .thread = thread } };
    }

    pub fn stop(self: *ShutdownOnCancel) void {
        switch (self.*) {
            .inactive => {},
            .active => |active| {
                active.state.stop.store(true, .release);
                active.thread.join();
                active.allocator.destroy(active.state);
                self.* = .inactive;
            },
        }
    }

    fn watch(state: *State) void {
        while (!state.stop.load(.acquire)) {
            if (state.token.isAborted()) {
                interruptRequest(state.io, state.stream);
                return;
            }
            std.Thread.sleep(poll_interval_ns);
        }
    }

    fn interruptRequest(io: std.Io, stream: std.Io.net.Stream) void {
        stream.shutdown(io, .both) catch {};
    }
};
