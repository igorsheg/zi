const std = @import("std");
const protocol = @import("protocol.zig");
const runtime_http_cancel = @import("../runtime/http_cancel.zig");

pub const requestStream = runtime_http_cancel.requestStream;

pub const ShutdownOnCancel = struct {
    inner: runtime_http_cancel.ShutdownOnCancel = .inactive,

    pub fn start(io: std.Io, token: protocol.CancelToken, req: anytype) !ShutdownOnCancel {
        return .{ .inner = try runtime_http_cancel.ShutdownOnCancel.start(
            std.heap.smp_allocator,
            io,
            token,
            runtime_http_cancel.requestStream(req),
        ) };
    }

    pub fn stop(self: *ShutdownOnCancel) void {
        self.inner.stop();
        self.* = .{};
    }
};
