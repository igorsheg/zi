const std = @import("std");
const zio_backend = @import("zio_backend.zig");

pub const PollReadableFdError = std.posix.PollError;

pub fn pollReadableFd(fd: std.posix.fd_t) PollReadableFdError!bool {
    return pollReadableFdTimeout(fd, 0);
}

pub fn pollReadableFdTimeout(fd: std.posix.fd_t, timeout_ms: u64) PollReadableFdError!bool {
    var fds = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const timeout: i32 = @intCast(@min(timeout_ms, @as(u64, @intCast(std.math.maxInt(i32)))));
    return try std.posix.poll(&fds, timeout) > 0 and (fds[0].revents & std.posix.POLL.IN) != 0;
}

test "poll readable fd reports false when pipe has no data" {
    var rt = try zio_backend.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const pair = try zio_backend.createPipe();
    defer pair.close();

    try std.testing.expect(!try pollReadableFd(pair.read.fd));
}

test "poll readable fd reports true after pipe write" {
    var rt = try zio_backend.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const pair = try zio_backend.createPipe();
    defer pair.close();

    _ = try pair.write.write("x", zio_backend.Timeout.fromMilliseconds(100));

    try std.testing.expect(try pollReadableFd(pair.read.fd));
}
