const std = @import("std");
const posix = std.posix;
const terminal_mod = @import("terminal.zig");

extern "c" fn openpty(
    amaster: *c_int,
    aslave: *c_int,
    name: ?[*]u8,
    termp: ?*posix.termios,
    winp: ?*posix.winsize,
) c_int;

pub const read_size_bytes_max: usize = 64 * 1024;
pub const write_buffer_size_bytes: usize = 4096;

pub const TerminalHarness = struct {
    io: std.Io,
    master_fd: posix.fd_t,
    slave_fd: posix.fd_t,

    pub fn init(io: std.Io) !TerminalHarness {
        var master: c_int = -1;
        var slave: c_int = -1;
        if (openpty(&master, &slave, null, null, null) == -1) return error.OpenPtyFailed;
        return .{ .io = io, .master_fd = master, .slave_fd = slave };
    }

    pub fn deinit(self: *TerminalHarness) void {
        fileFromFd(self.master_fd).close(self.io);
        fileFromFd(self.slave_fd).close(self.io);
        self.* = undefined;
    }

    pub fn terminal(self: TerminalHarness) terminal_mod.Terminal {
        return terminal_mod.Terminal.initWithFds(self.io, self.slave_fd, self.slave_fd);
    }

    pub fn slaveWriter(self: TerminalHarness, buffer: []u8) std.Io.File.Writer {
        return .initStreaming(fileFromFd(self.slave_fd), self.io, buffer);
    }

    pub fn writeInput(self: TerminalHarness, bytes: []const u8) !void {
        try fileFromFd(self.master_fd).writeStreamingAll(self.io, bytes);
    }

    pub fn readOutput(self: TerminalHarness, buffer: []u8) ![]const u8 {
        var fds = [_]posix.pollfd{.{ .fd = self.master_fd, .events = posix.POLL.IN, .revents = 0 }};
        const ready = try posix.poll(&fds, 100);
        if (ready == 0 or (fds[0].revents & posix.POLL.IN) == 0) return error.NoOutput;
        const count = try posix.read(self.master_fd, buffer);
        return buffer[0..count];
    }
};

fn fileFromFd(fd: posix.fd_t) std.Io.File {
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

test "terminal harness captures setup and shutdown bytes" {
    var harness = try TerminalHarness.init(std.testing.io);
    defer harness.deinit();
    var terminal = harness.terminal();
    var write_buffer: [write_buffer_size_bytes]u8 = undefined;
    var writer = harness.slaveWriter(&write_buffer);

    try terminal.setup(&writer.interface);
    try writer.interface.flush();

    var read_buffer: [read_size_bytes_max]u8 = undefined;
    const setup_bytes = try harness.readOutput(&read_buffer);
    try std.testing.expect(std.mem.indexOf(u8, setup_bytes, "\x1b[?1049h") != null);
    try std.testing.expect(std.mem.indexOf(u8, setup_bytes, "\x1b[?25l") != null);

    try terminal.shutdown(&writer.interface);
    try writer.interface.flush();
    const shutdown_bytes = try harness.readOutput(&read_buffer);
    try std.testing.expect(std.mem.indexOf(u8, shutdown_bytes, "\x1b[?25h") != null);
    try std.testing.expect(std.mem.indexOf(u8, shutdown_bytes, "\x1b[?1049l") != null);
}
