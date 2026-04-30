const std = @import("std");
const posix = std.posix;
const fd = @import("fd.zig");

/// Nonblocking close-on-exec wake pipe.
///
/// This intentionally contains the small amount of platform fd plumbing needed
/// by runtime/mailbox. Higher layers should not call pipe/fcntl/close directly.
pub const Pipe = struct {
    read_fd: posix.fd_t,
    write_fd: posix.fd_t,

    pub fn init() !Pipe {
        const fds = try fd.pipe();
        errdefer fd.close(fds[0]);
        errdefer fd.close(fds[1]);

        try fd.setNonblocking(fds[0]);
        try fd.setNonblocking(fds[1]);
        try fd.setCloseOnExec(fds[0]);
        try fd.setCloseOnExec(fds[1]);

        return .{ .read_fd = fds[0], .write_fd = fds[1] };
    }

    pub fn deinit(self: *Pipe) void {
        fd.close(self.read_fd);
        fd.close(self.write_fd);
        self.* = undefined;
    }

    pub fn readFd(self: Pipe) posix.fd_t {
        return self.read_fd;
    }

    pub fn signal(self: Pipe, io: std.Io) bool {
        const byte = [1]u8{1};
        const file: std.Io.File = .{ .handle = self.write_fd, .flags = .{ .nonblocking = true } };
        var write_buf: [1]u8 = undefined;
        var writer = file.writer(io, &write_buf);
        writer.interface.writeAll(&byte) catch return false;
        writer.interface.flush() catch return false;
        return true;
    }

    pub fn drain(self: Pipe) void {
        var buf: [64]u8 = undefined;
        while (true) {
            const n = std.posix.read(self.read_fd, &buf) catch return;
            if (n < buf.len) return;
        }
    }
};
