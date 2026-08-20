const std = @import("std");
const builtin = @import("builtin");

const TerminalSession = @This();

pub const restore_sequence = "\x1b]8;;\x1b\\\x1b[0m\x1b[?25h";

pub const Size = struct {
    rows: u16,
    columns: u16,
};

pub const PollResult = struct {
    readable: bool = false,
    hung_up: bool = false,
    has_error: bool = false,

    pub fn closed(self: PollResult) bool {
        return self.hung_up or self.has_error;
    }
};

pub const StartError = error{
    NotATerminal,
    UnableToReadTerminal,
    UnableToConfigureTerminal,
};

pub const SizeError = error{
    UnableToReadTerminalSize,
};

io: std.Io,
input: std.Io.File,
output: std.Io.File,
original: std.posix.termios,
active: bool = true,

/// Enters raw mode on the normal screen. No alternate screen, mouse tracking,
/// keyboard protocol, or frame-diff mode is enabled by this owner.
pub fn start(
    io: std.Io,
    input: std.Io.File,
    output: std.Io.File,
) StartError!TerminalSession {
    const input_is_tty = input.isTty(io) catch return error.NotATerminal;
    const output_is_tty = output.isTty(io) catch return error.NotATerminal;
    if (!input_is_tty or !output_is_tty) return error.NotATerminal;

    const original = std.posix.tcgetattr(input.handle) catch
        return error.UnableToReadTerminal;
    var raw = original;
    raw.iflag.BRKINT = false;
    raw.iflag.ICRNL = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.IXON = false;
    raw.iflag.IXOFF = false;
    raw.cflag.CSIZE = .CS8;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.IEXTEN = false;
    raw.lflag.ISIG = false;
    const vmin_index = vminIndex();
    const vtime_index = vtimeIndex();
    if (vmin_index < raw.cc.len and vtime_index < raw.cc.len) {
        raw.cc[vmin_index] = 1;
        raw.cc[vtime_index] = 0;
    }
    std.posix.tcsetattr(input.handle, .NOW, raw) catch
        return error.UnableToConfigureTerminal;
    return .{
        .io = io,
        .input = input,
        .output = output,
        .original = original,
    };
}

/// Restores terminal modes exactly once. Escape cleanup is best-effort because
/// cooked input restoration must still run when output has already closed.
// Idempotence is required by nested terminal cleanup paths.
// ziglint-ignore: Z030
pub fn deinit(self: *TerminalSession) void {
    if (!self.active) return;
    const termios_result = std.posix.tcsetattr(self.input.handle, .FLUSH, self.original);
    if (termios_result) |_| {} else |_| {}
    const output_result = self.output.writeStreamingAll(self.io, restore_sequence);
    if (output_result) |_| {} else |_| {}
    self.active = false;
}

pub fn read(self: TerminalSession, buffer: []u8) !usize {
    return std.posix.read(self.input.handle, buffer);
}

pub fn pollInput(self: TerminalSession, timeout_ms: i32) !PollResult {
    var descriptors = [_]std.posix.pollfd{.{
        .fd = self.input.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    _ = try std.posix.poll(&descriptors, timeout_ms);
    const events = descriptors[0].revents;
    return .{
        .readable = (events & std.posix.POLL.IN) != 0,
        .hung_up = (events & std.posix.POLL.HUP) != 0,
        .has_error = (events & std.posix.POLL.ERR) != 0,
    };
}

pub fn querySize(self: TerminalSession) SizeError!Size {
    var value: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const request: c_int = @intCast(std.c.T.IOCGWINSZ);
    const result = std.c.ioctl(self.output.handle, request, &value);
    if (result == -1) return error.UnableToReadTerminalSize;
    return sizeFromValues(value.row, value.col);
}

fn sizeFromValues(rows: u16, columns: u16) SizeError!Size {
    if (rows == 0 or columns == 0) return error.UnableToReadTerminalSize;
    return .{ .rows = rows, .columns = columns };
}

fn vminIndex() usize {
    return switch (builtin.os.tag) {
        .linux => 6,
        .macos, .ios, .tvos, .watchos, .visionos => 16,
        .freebsd, .netbsd, .dragonfly, .openbsd => 16,
        else => 16,
    };
}

fn vtimeIndex() usize {
    return switch (builtin.os.tag) {
        .linux => 5,
        .macos, .ios, .tvos, .watchos, .visionos => 17,
        .freebsd, .netbsd, .dragonfly, .openbsd => 17,
        else => 17,
    };
}

const supports_test_pty = switch (builtin.os.tag) {
    .linux, .macos, .freebsd, .netbsd, .openbsd => true,
    else => false,
};

extern "c" fn posix_openpt(flags: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]u8;

const TestPty = struct {
    master: std.Io.File,
    slave: std.Io.File,

    fn open() !TestPty {
        const flags: std.posix.O = .{
            .ACCMODE = .RDWR,
            .NOCTTY = true,
            .CLOEXEC = true,
        };
        const master_handle = posix_openpt(@bitCast(flags));
        if (master_handle < 0) return error.PtyUnavailable;
        errdefer (std.Io.File{ .handle = master_handle, .flags = .{ .nonblocking = false } }).close(std.testing.io);
        if (grantpt(master_handle) != 0 or unlockpt(master_handle) != 0) {
            return error.PtyUnavailable;
        }
        const slave_name = ptsname(master_handle) orelse return error.PtyUnavailable;
        const slave_handle = try std.posix.openatZ(std.posix.AT.FDCWD, slave_name, flags, 0);
        return .{
            .master = .{ .handle = master_handle, .flags = .{ .nonblocking = false } },
            .slave = .{ .handle = slave_handle, .flags = .{ .nonblocking = false } },
        };
    }

    fn close(self: TestPty) void {
        self.master.close(std.testing.io);
        self.slave.close(std.testing.io);
    }
};

fn readRestoreSequence(file: std.Io.File, output: []u8) !void {
    var offset: usize = 0;
    while (offset < output.len) {
        const count = try file.readStreaming(std.testing.io, &.{output[offset..]});
        if (count == 0) return error.UnexpectedEndOfFile;
        offset += count;
    }
}

test "terminal size rejects unknown geometry" {
    const size = try sizeFromValues(24, 80);
    try std.testing.expectEqual(@as(u16, 24), size.rows);
    try std.testing.expectEqual(@as(u16, 80), size.columns);
    try std.testing.expectError(error.UnableToReadTerminalSize, sizeFromValues(0, 80));
    try std.testing.expectError(error.UnableToReadTerminalSize, sizeFromValues(24, 0));
}

test "terminal session enters raw mode and restores termios and cursor state" {
    if (!supports_test_pty) return error.SkipZigTest;
    const pty = try TestPty.open();
    defer pty.close();
    const original = try std.posix.tcgetattr(pty.slave.handle);

    var session = try TerminalSession.start(std.testing.io, pty.slave, pty.slave);
    const raw = try std.posix.tcgetattr(pty.slave.handle);
    try std.testing.expect(!raw.lflag.ECHO);
    try std.testing.expect(!raw.lflag.ICANON);
    try std.testing.expect(!raw.lflag.ISIG);
    try std.testing.expect(raw.cflag.CSIZE == .CS8);
    var output: [restore_sequence.len]u8 = undefined;
    var output_future = std.testing.io.async(readRestoreSequence, .{ pty.master, &output });
    session.deinit();
    try output_future.await(std.testing.io);

    const restored = try std.posix.tcgetattr(pty.slave.handle);
    try std.testing.expect(std.meta.eql(original, restored));
    try std.testing.expectEqualStrings(restore_sequence, &output);
}

test "terminal session preserves input queued before raw-mode admission" {
    if (!supports_test_pty) return error.SkipZigTest;
    const pty = try TestPty.open();
    defer pty.close();
    var original = try std.posix.tcgetattr(pty.slave.handle);
    original.lflag.ECHO = false;
    original.lflag.ICANON = false;
    original.lflag.ISIG = false;
    original.cc[vminIndex()] = 1;
    original.cc[vtimeIndex()] = 0;
    try std.posix.tcsetattr(pty.slave.handle, .NOW, original);
    try pty.master.writeStreamingAll(std.testing.io, "x");

    var session = try TerminalSession.start(std.testing.io, pty.slave, pty.slave);
    const poll = try session.pollInput(100);
    try std.testing.expect(poll.readable);
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try session.read(&byte));
    try std.testing.expectEqual(@as(u8, 'x'), byte[0]);
    var output: [restore_sequence.len]u8 = undefined;
    var output_future = std.testing.io.async(readRestoreSequence, .{ pty.master, &output });
    session.deinit();
    try output_future.await(std.testing.io);
}
