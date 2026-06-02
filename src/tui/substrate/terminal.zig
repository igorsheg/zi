const std = @import("std");
const posix = std.posix;
const ansi = @import("ansi.zig");
const RawMode = @import("raw_mode.zig").RawMode;

pub const Size = struct {
    width: u16,
    height: u16,
};

pub const Terminal = struct {
    io: std.Io,
    input_fd: posix.fd_t,
    output_fd: posix.fd_t,
    raw: ?RawMode = null,
    alt_screen_active: bool = false,
    cursor_hidden: bool = false,

    pub fn init(io: std.Io) Terminal {
        return initWithFds(io, posix.STDIN_FILENO, posix.STDOUT_FILENO);
    }

    pub fn initWithFds(io: std.Io, input_fd: posix.fd_t, output_fd: posix.fd_t) Terminal {
        return .{ .io = io, .input_fd = input_fd, .output_fd = output_fd };
    }

    pub fn setup(self: *Terminal, writer: *std.Io.Writer) !void {
        var raw = try RawMode.enter(self.input_fd);
        writer.writeAll(ansi.enter_alt_screen) catch |err| {
            try raw.restore();
            return err;
        };
        self.alt_screen_active = true;

        writer.writeAll(ansi.hide_cursor) catch |err| {
            writeBestEffort(writer, ansi.leave_alt_screen);
            try raw.restore();
            self.alt_screen_active = false;
            return err;
        };
        self.cursor_hidden = true;

        writer.writeAll(ansi.clear) catch |err| {
            writeBestEffort(writer, ansi.reset ++ ansi.show_cursor ++ ansi.leave_alt_screen);
            try raw.restore();
            self.alt_screen_active = false;
            self.cursor_hidden = false;
            return err;
        };
        self.raw = raw;
    }

    pub fn shutdown(self: *Terminal, writer: *std.Io.Writer) !void {
        self.writeShutdownAnsi(writer) catch |write_err| {
            try self.restoreRawMode();
            return write_err;
        };
        try self.restoreRawMode();
    }

    pub fn size(self: Terminal) !Size {
        return querySize(self.output_fd);
    }

    fn writeShutdownAnsi(self: *Terminal, writer: *std.Io.Writer) !void {
        if (self.cursor_hidden) {
            try writer.writeAll(ansi.reset ++ ansi.show_cursor);
            self.cursor_hidden = false;
        } else {
            try writer.writeAll(ansi.reset);
        }

        if (self.alt_screen_active) {
            try writer.writeAll(ansi.leave_alt_screen);
            self.alt_screen_active = false;
        }
    }

    fn restoreRawMode(self: *Terminal) !void {
        if (self.raw) |*raw| try raw.restore();
        self.raw = null;
    }
};

fn writeBestEffort(writer: *std.Io.Writer, bytes: []const u8) void {
    writer.writeAll(bytes) catch |err| {
        _ = err;
    };
}

pub fn querySize(fd: posix.fd_t) !Size {
    var window_size: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const rc = std.c.ioctl(fd, posix.T.IOCGWINSZ, &window_size);
    if (rc == -1) return error.TerminalSizeUnavailable;
    if (window_size.col == 0) return error.TerminalSizeUnavailable;
    if (window_size.row == 0) return error.TerminalSizeUnavailable;
    return .{ .width = window_size.col, .height = window_size.row };
}

test "terminal init records explicit fds" {
    const terminal = Terminal.initWithFds(std.testing.io, 11, 12);
    try std.testing.expectEqual(@as(posix.fd_t, 11), terminal.input_fd);
    try std.testing.expectEqual(@as(posix.fd_t, 12), terminal.output_fd);
}

test "terminal shutdown is idempotent without setup" {
    var terminal = Terminal.initWithFds(std.testing.io, 11, 12);
    var output: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);

    try terminal.shutdown(&writer);
    try terminal.shutdown(&writer);

    try std.testing.expect(terminal.raw == null);
    try std.testing.expect(!terminal.alt_screen_active);
    try std.testing.expect(!terminal.cursor_hidden);
}
