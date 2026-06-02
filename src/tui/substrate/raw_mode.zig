const std = @import("std");
const posix = std.posix;

pub const RawMode = struct {
    fd: posix.fd_t,
    original: posix.termios,
    active: bool,

    pub fn enter(fd: posix.fd_t) !RawMode {
        const original = try posix.tcgetattr(fd);
        var raw = original;
        applyRawTermios(&raw);
        try posix.tcsetattr(fd, .FLUSH, raw);
        return .{ .fd = fd, .original = original, .active = true };
    }

    pub fn restore(self: *RawMode) !void {
        if (!self.active) return;
        try posix.tcsetattr(self.fd, .FLUSH, self.original);
        self.active = false;
    }
};

fn applyRawTermios(term: *posix.termios) void {
    if (@hasField(@TypeOf(term.iflag), "BRKINT")) term.iflag.BRKINT = false;
    if (@hasField(@TypeOf(term.iflag), "ICRNL")) term.iflag.ICRNL = false;
    if (@hasField(@TypeOf(term.iflag), "INPCK")) term.iflag.INPCK = false;
    if (@hasField(@TypeOf(term.iflag), "ISTRIP")) term.iflag.ISTRIP = false;
    if (@hasField(@TypeOf(term.iflag), "IXON")) term.iflag.IXON = false;

    if (@hasField(@TypeOf(term.oflag), "OPOST")) term.oflag.OPOST = false;

    if (@hasField(@TypeOf(term.cflag), "CSIZE")) term.cflag.CSIZE = .CS8;

    if (@hasField(@TypeOf(term.lflag), "ECHO")) term.lflag.ECHO = false;
    if (@hasField(@TypeOf(term.lflag), "ICANON")) term.lflag.ICANON = false;
    if (@hasField(@TypeOf(term.lflag), "IEXTEN")) term.lflag.IEXTEN = false;
    if (@hasField(@TypeOf(term.lflag), "ISIG")) term.lflag.ISIG = false;

    term.cc[@intFromEnum(posix.V.MIN)] = 0;
    term.cc[@intFromEnum(posix.V.TIME)] = 1;
}

test "raw termios disables canonical input and echo" {
    var term: posix.termios = std.mem.zeroes(posix.termios);
    applyRawTermios(&term);

    if (@hasField(@TypeOf(term.lflag), "ECHO")) try std.testing.expect(!term.lflag.ECHO);
    if (@hasField(@TypeOf(term.lflag), "ICANON")) try std.testing.expect(!term.lflag.ICANON);
    try std.testing.expectEqual(@as(posix.cc_t, 0), term.cc[@intFromEnum(posix.V.MIN)]);
    try std.testing.expectEqual(@as(posix.cc_t, 1), term.cc[@intFromEnum(posix.V.TIME)]);
}
