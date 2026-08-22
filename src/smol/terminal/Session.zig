const std = @import("std");
const builtin = @import("builtin");
const CursorProbe = @import("CursorProbe.zig");

const Session = @This();

pub const admission_sequence = "\x1b[?7l";
pub const restore_sequence = "\x1b[?2026l\x1b[?7h\x1b]8;;\x1b\\\x1b[0m\x1b[?25h";
const cursor_query_sequence = "\x1b[6n";
const cursor_query_timeout_ms: i32 = 100;
const max_probe_input_bytes = CursorProbe.max_deferred_bytes;

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
deferred_input: [CursorProbe.max_deferred_bytes]u8 = undefined,
deferred_start: u16 = 0,
deferred_len: u16 = 0,
active: bool = true,

/// Enters raw mode on the normal screen. No alternate screen, mouse tracking,
/// keyboard protocol, or frame-diff mode is enabled by this owner.
pub fn start(
    io: std.Io,
    input: std.Io.File,
    output: std.Io.File,
) StartError!Session {
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
    errdefer {
        std.posix.tcsetattr(input.handle, .NOW, original) catch {};
        output.writeStreamingAll(io, restore_sequence) catch {};
    }
    output.writeStreamingAll(io, admission_sequence) catch
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
pub fn deinit(self: *Session) void {
    if (!self.active) return;
    const termios_result = std.posix.tcsetattr(self.input.handle, .FLUSH, self.original);
    if (termios_result) |_| {} else |_| {}
    const output_result = self.output.writeStreamingAll(self.io, restore_sequence);
    if (output_result) |_| {} else |_| {}
    self.active = false;
}

pub fn read(self: *Session, buffer: []u8) !usize {
    if (buffer.len == 0) return 0;
    if (self.deferred_start < self.deferred_len) {
        const available = self.deferred_len - self.deferred_start;
        const count = @min(buffer.len, available);
        @memcpy(buffer[0..count], self.deferred_input[self.deferred_start..][0..count]);
        self.deferred_start += @intCast(count);
        if (self.deferred_start == self.deferred_len) {
            self.deferred_start = 0;
            self.deferred_len = 0;
        }
        return count;
    }
    return std.posix.read(self.input.handle, buffer);
}

pub fn pollInput(self: *Session, timeout_ms: i32) !PollResult {
    if (self.deferred_start < self.deferred_len) return .{ .readable = true };
    return self.pollFileInput(timeout_ms);
}

/// Admits a normal-buffer inline viewport and returns its one-based launch row.
/// Cursor probing never consumes user input. Failed and mid-line probes create
/// a fresh column-one line without clearing terminal content.
pub fn prepareInline(self: *Session, size: Size) !u16 {
    if (size.rows == 0 or size.columns == 0) return error.InvalidTerminalSize;

    const position = self.queryCursorPosition() catch return self.freshBottomLine(size.rows);
    if (position.row > size.rows or position.column > size.columns) {
        return self.freshBottomLine(size.rows);
    }
    if (position.column == 1) return position.row;

    try self.output.writeStreamingAll(self.io, "\r\n");
    return @min(position.row +| 1, size.rows);
}

fn freshBottomLine(self: *Session, bottom_row: u16) !u16 {
    var fallback: [32]u8 = undefined;
    const move = try std.fmt.bufPrint(&fallback, "\x1b[{d};1H", .{bottom_row});
    try self.output.writeStreamingAll(self.io, move);
    // LF at the bottom scrolls the existing shell row into history. CR makes
    // the newly exposed line safe even when output post-processing is disabled.
    try self.output.writeStreamingAll(self.io, "\r\n");
    return bottom_row;
}

fn queryCursorPosition(self: *Session) !CursorProbe.Position {
    if (self.deferred_input.len - self.deferred_len < max_probe_input_bytes) {
        return error.CursorPositionUnavailable;
    }
    try self.output.writeStreamingAll(self.io, cursor_query_sequence);

    var parser: CursorProbe.Parser = .{};
    defer {
        parser.finish() catch unreachable;
        self.appendDeferredInput(parser.deferredInput()) catch unreachable;
    }

    const started_ms = nowMs(self.io);
    const deadline_ms = std.math.add(i64, started_ms, cursor_query_timeout_ms) catch std.math.maxInt(i64);
    var observed: usize = 0;
    while (observed < max_probe_input_bytes) : (observed += 1) {
        const current_ms = nowMs(self.io);
        if (current_ms >= deadline_ms) break;
        const remaining_ms: i32 = @intCast(deadline_ms - current_ms);
        const poll = try self.pollFileInput(remaining_ms);
        if (poll.closed() or !poll.readable) break;

        var byte: [1]u8 = undefined;
        const count = try std.posix.read(self.input.handle, &byte);
        if (count == 0) break;
        try parser.feed(byte[0]);
        if (parser.position()) |position| return position;
    }
    return error.CursorPositionUnavailable;
}

fn appendDeferredInput(self: *Session, bytes: []const u8) error{DeferredInputFull}!void {
    if (bytes.len == 0) return;
    const pending = self.deferred_len - self.deferred_start;
    if (bytes.len > self.deferred_input.len - pending) return error.DeferredInputFull;
    if (self.deferred_start > 0 and pending > 0) {
        @memmove(
            self.deferred_input[0..pending],
            self.deferred_input[self.deferred_start..self.deferred_len],
        );
    }
    @memcpy(self.deferred_input[pending..][0..bytes.len], bytes);
    self.deferred_start = 0;
    self.deferred_len = @intCast(pending + bytes.len);
}

fn nowMs(io: std.Io) i64 {
    const value = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    return std.math.cast(i64, value) orelse std.math.maxInt(i64);
}

fn pollFileInput(self: Session, timeout_ms: i32) !PollResult {
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

pub fn querySize(self: Session) SizeError!Size {
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

fn readExact(file: std.Io.File, output: []u8) !void {
    var offset: usize = 0;
    while (offset < output.len) {
        const count = try file.readStreaming(std.testing.io, &.{output[offset..]});
        if (count == 0) return error.UnexpectedEndOfFile;
        offset += count;
    }
}

fn expectFileBytes(file: std.Io.File, expected: []const u8) !void {
    var actual: [64]u8 = undefined;
    try std.testing.expect(expected.len <= actual.len);
    try readExact(file, actual[0..expected.len]);
    try std.testing.expectEqualStrings(expected, actual[0..expected.len]);
}

fn replyToCursorProbe(file: std.Io.File, response: []const u8) !void {
    try expectFileBytes(file, cursor_query_sequence);
    try file.writeStreamingAll(std.testing.io, response);
}

test "terminal size rejects unknown geometry" {
    const size = try sizeFromValues(24, 80);
    try std.testing.expectEqual(@as(u16, 24), size.rows);
    try std.testing.expectEqual(@as(u16, 80), size.columns);
    try std.testing.expectError(error.UnableToReadTerminalSize, sizeFromValues(0, 80));
    try std.testing.expectError(error.UnableToReadTerminalSize, sizeFromValues(24, 0));
}

test "terminal session admits exact normal-buffer modes and restores exact cleanup" {
    if (!supports_test_pty) return error.SkipZigTest;
    const pty = try TestPty.open();
    defer pty.close();
    const original = try std.posix.tcgetattr(pty.slave.handle);

    var session = try Session.start(std.testing.io, pty.slave, pty.slave);
    try expectFileBytes(pty.master, admission_sequence);
    const raw = try std.posix.tcgetattr(pty.slave.handle);
    try std.testing.expect(!raw.lflag.ECHO);
    try std.testing.expect(!raw.lflag.ICANON);
    try std.testing.expect(!raw.lflag.ISIG);
    try std.testing.expect(raw.cflag.CSIZE == .CS8);
    var output: [restore_sequence.len]u8 = undefined;
    var output_future = std.testing.io.async(readExact, .{ pty.master, &output });
    session.deinit();
    try output_future.await(std.testing.io);

    const restored = try std.posix.tcgetattr(pty.slave.handle);
    try std.testing.expect(std.meta.eql(original, restored));
    try std.testing.expectEqualStrings(restore_sequence, &output);
    try std.testing.expect(std.mem.find(u8, admission_sequence, "?1049") == null);
    try std.testing.expect(std.mem.find(u8, admission_sequence, "?1000") == null);
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

    var session = try Session.start(std.testing.io, pty.slave, pty.slave);
    try expectFileBytes(pty.master, admission_sequence);
    const poll = try session.pollInput(100);
    try std.testing.expect(poll.readable);
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try session.read(&byte));
    try std.testing.expectEqual(@as(u8, 'x'), byte[0]);
    var output: [restore_sequence.len]u8 = undefined;
    var output_future = std.testing.io.async(readExact, .{ pty.master, &output });
    session.deinit();
    try output_future.await(std.testing.io);
}

test "prepare inline starts a fresh line when launched mid-line" {
    if (!supports_test_pty) return error.SkipZigTest;
    const pty = try TestPty.open();
    defer pty.close();

    var session = try Session.start(std.testing.io, pty.slave, pty.slave);
    try expectFileBytes(pty.master, admission_sequence);
    var reply = std.testing.io.async(replyToCursorProbe, .{ pty.master, "\x1b[4;7R" });
    try std.testing.expectEqual(
        @as(u16, 5),
        try session.prepareInline(.{ .rows = 24, .columns = 80 }),
    );
    try reply.await(std.testing.io);
    try expectFileBytes(pty.master, "\r\r\n");

    session.deinit();
    try expectFileBytes(pty.master, restore_sequence);
}

test "prepare inline fallback scrolls to a fresh bottom line without clearing" {
    if (!supports_test_pty) return error.SkipZigTest;
    const pty = try TestPty.open();
    defer pty.close();

    var session = try Session.start(std.testing.io, pty.slave, pty.slave);
    try expectFileBytes(pty.master, admission_sequence);
    var probe_read = std.testing.io.async(expectFileBytes, .{ pty.master, cursor_query_sequence });
    try std.testing.expectEqual(
        @as(u16, 24),
        try session.prepareInline(.{ .rows = 24, .columns = 80 }),
    );
    try probe_read.await(std.testing.io);
    try expectFileBytes(pty.master, "\x1b[24;1H\r\r\n");

    session.deinit();
    try expectFileBytes(pty.master, restore_sequence);
}

test "prepare inline fallback preserves input observed by the failed probe" {
    if (!supports_test_pty) return error.SkipZigTest;
    const pty = try TestPty.open();
    defer pty.close();

    var session = try Session.start(std.testing.io, pty.slave, pty.slave);
    try expectFileBytes(pty.master, admission_sequence);
    var reply = std.testing.io.async(replyToCursorProbe, .{ pty.master, "typed" });
    try std.testing.expectEqual(
        @as(u16, 24),
        try session.prepareInline(.{ .rows = 24, .columns = 80 }),
    );
    try reply.await(std.testing.io);
    try expectFileBytes(pty.master, "\x1b[24;1H\r\r\n");

    var input: [5]u8 = undefined;
    try std.testing.expectEqual(@as(usize, input.len), try session.read(&input));
    try std.testing.expectEqualStrings("typed", &input);

    session.deinit();
    try expectFileBytes(pty.master, restore_sequence);
}

test "cursor probe defers user input and reads it before file input" {
    if (!supports_test_pty) return error.SkipZigTest;
    const pty = try TestPty.open();
    defer pty.close();

    var session = try Session.start(std.testing.io, pty.slave, pty.slave);
    try expectFileBytes(pty.master, admission_sequence);
    var reply = std.testing.io.async(
        replyToCursorProbe,
        .{ pty.master, "ab\x1b[4;1Rcd" },
    );
    try std.testing.expectEqual(
        @as(u16, 4),
        try session.prepareInline(.{ .rows = 24, .columns = 80 }),
    );
    try reply.await(std.testing.io);

    try std.testing.expect((try session.pollInput(0)).readable);
    var input: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try session.read(&input));
    try std.testing.expectEqualStrings("ab", input[0..2]);
    try std.testing.expect((try session.pollInput(100)).readable);
    try std.testing.expectEqual(@as(usize, 2), try session.read(&input));
    try std.testing.expectEqualStrings("cd", input[0..2]);

    session.deinit();
    try expectFileBytes(pty.master, restore_sequence);
}
