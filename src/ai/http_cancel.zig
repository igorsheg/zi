const std = @import("std");
const posix = std.posix;
const protocol = @import("protocol.zig");

fn requestShutdownFd(req: anytype) ?posix.fd_t {
    const conn = req.connection orelse return null;
    return conn.stream_reader.stream.socket.handle;
}

pub const ShutdownOnCancel = struct {
    pub fn start(_: std.Io, token: protocol.CancelToken, req: anytype) !ShutdownOnCancel {
        _ = token;
        _ = requestShutdownFd(req);
        return .{};
    }

    pub fn stop(self: *ShutdownOnCancel) void {
        self.* = .{};
    }
};
