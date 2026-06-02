const std = @import("std");
const posix = std.posix;
const ansi = @import("ansi.zig");
const RawMode = @import("raw_mode.zig").RawMode;
const builtin = @import("builtin");

pub const Size = struct { width: u16, height: u16 };
pub const TerminalOptions = struct {
    alt_screen: bool = true,
    bracketed_paste: bool = true,
    focus_events: bool = true,
    mouse: bool = false,
    synchronized_output: bool = false,
};
pub const TerminalCapabilities = struct {
    tty_size_available: bool = true,
    bracketed_paste: bool = true,
    focus_events: bool = true,
    mouse: bool = false,
    synchronized_output: bool = false,
};

pub const Terminal = struct {
    io: std.Io,
    input_fd: posix.fd_t,
    output_fd: posix.fd_t,
    options: TerminalOptions = .{},
    capabilities: TerminalCapabilities = .{},
    raw: ?RawMode = null,
    alt_screen_active: bool = false,
    cursor_hidden: bool = false,
    bracketed_paste_active: bool = false,
    focus_active: bool = false,
    mouse_active: bool = false,
    synchronized_update_active: bool = false,

    pub fn init(io: std.Io) Terminal {
        return initWithFds(io, posix.STDIN_FILENO, posix.STDOUT_FILENO);
    }
    pub fn initWithFds(io: std.Io, input_fd: posix.fd_t, output_fd: posix.fd_t) Terminal {
        return .{ .io = io, .input_fd = input_fd, .output_fd = output_fd };
    }

    pub fn setup(self: *Terminal, writer: *std.Io.Writer) !void {
        var raw = try RawMode.enter(self.input_fd);
        errdefer self.cleanupSetupFailure(writer, &raw);
        if (self.options.alt_screen) {
            try writer.writeAll(ansi.enter_alt_screen);
            self.alt_screen_active = true;
        }
        if (self.options.bracketed_paste and self.capabilities.bracketed_paste) {
            try writer.writeAll(ansi.enable_bracketed_paste);
            self.bracketed_paste_active = true;
        }
        if (self.options.focus_events and self.capabilities.focus_events) {
            try writer.writeAll(ansi.enable_focus);
            self.focus_active = true;
        }
        if (self.options.synchronized_output and self.capabilities.synchronized_output) {
            try writer.writeAll(ansi.begin_synchronized_update);
            self.synchronized_update_active = true;
        }
        try writer.writeAll(ansi.hide_cursor ++ ansi.clear);
        self.cursor_hidden = true;
        self.raw = raw;
    }

    pub fn shutdown(self: *Terminal, writer: *std.Io.Writer) !void {
        const ansi_err = self.writeShutdownAnsi(writer);
        const raw_err = self.restoreRawMode();
        if (ansi_err) |_| {} else |e| {
            raw_err catch |raw_restore_error| restoreErrorBestEffort(raw_restore_error);
            return e;
        }
        try raw_err;
    }
    pub fn size(self: Terminal) !Size {
        return querySize(self.output_fd);
    }

    fn writeShutdownAnsi(self: *Terminal, writer: *std.Io.Writer) !void {
        if (self.synchronized_update_active) {
            try writer.writeAll(ansi.end_synchronized_update);
            self.synchronized_update_active = false;
        }
        try writer.writeAll(ansi.reset);
        if (self.cursor_hidden) {
            try writer.writeAll(ansi.show_cursor);
            self.cursor_hidden = false;
        }
        if (self.mouse_active) {
            try writer.writeAll(ansi.disable_mouse);
            self.mouse_active = false;
        }
        if (self.focus_active) {
            try writer.writeAll(ansi.disable_focus);
            self.focus_active = false;
        }
        if (self.bracketed_paste_active) {
            try writer.writeAll(ansi.disable_bracketed_paste);
            self.bracketed_paste_active = false;
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
    fn cleanupSetupFailure(self: *Terminal, writer: *std.Io.Writer, raw: *RawMode) void {
        self.writeShutdownAnsi(writer) catch |ansi_error| restoreErrorBestEffort(ansi_error);
        raw.restore() catch |raw_restore_error| restoreErrorBestEffort(raw_restore_error);
    }
};

fn restoreErrorBestEffort(raw_restore_error: anyerror) void {
    switch (raw_restore_error) {
        else => {},
    }
}

pub fn querySize(fd: posix.fd_t) !Size {
    if (comptime !isPosix()) return error.UnsupportedPlatform;
    var window_size: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const rc = std.c.ioctl(fd, posix.T.IOCGWINSZ, &window_size);
    if (rc == -1 or window_size.col == 0 or window_size.row == 0) return error.TerminalSizeUnavailable;
    return .{ .width = window_size.col, .height = window_size.row };
}
fn isPosix() bool {
    return switch (builtin.os.tag) {
        .linux, .macos, .freebsd, .openbsd, .netbsd, .dragonfly => true,
        else => false,
    };
}

test "terminal init records explicit fds and shutdown idempotent" {
    const terminal = Terminal.initWithFds(std.testing.io, 11, 12);
    try std.testing.expectEqual(@as(posix.fd_t, 11), terminal.input_fd);
    var t = terminal;
    var output: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try t.shutdown(&writer);
    try t.shutdown(&writer);
    try std.testing.expect(t.raw == null);
}

test "terminal shutdown writes enabled teardown in order" {
    var t = Terminal.initWithFds(std.testing.io, 0, 1);
    t.alt_screen_active = true;
    t.cursor_hidden = true;
    t.bracketed_paste_active = true;
    t.focus_active = true;
    var output: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try t.shutdown(&writer);
    try std.testing.expectEqualStrings(
        ansi.reset ++ ansi.show_cursor ++ ansi.disable_focus ++
            ansi.disable_bracketed_paste ++ ansi.leave_alt_screen,
        writer.buffered(),
    );
}
