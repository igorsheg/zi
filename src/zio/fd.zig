const std = @import("std");
const posix = std.posix;

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
