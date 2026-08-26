const std = @import("std");
const PosixMode = @This();

pub const Mode = enum {
    prompt_edit,
    generation_interrupt,
};

/// Injectable termios operations. Callback arguments and results are borrowed.
pub const Ops = struct {
    context: ?*anyopaque,
    get_fn: *const fn (?*anyopaque, std.posix.fd_t) std.posix.TermiosGetError!std.posix.termios,
    set_fn: *const fn (
        ?*anyopaque,
        std.posix.fd_t,
        std.posix.TCSA,
        std.posix.termios,
    ) std.posix.TermiosSetError!void,

    pub fn posix() Ops {
        return .{
            .context = null,
            .get_fn = posixGet,
            .set_fn = posixSet,
        };
    }

    fn get(ops: Ops, fd: std.posix.fd_t) std.posix.TermiosGetError!std.posix.termios {
        return ops.get_fn(ops.context, fd);
    }

    fn set(
        ops: Ops,
        fd: std.posix.fd_t,
        action: std.posix.TCSA,
        attributes: std.posix.termios,
    ) std.posix.TermiosSetError!void {
        return ops.set_fn(ops.context, fd, action, attributes);
    }
};

fd: std.posix.fd_t,
ops: Ops,
original: ?std.posix.termios = null,
restore_action: std.posix.TCSA = .NOW,

/// Creates a mode owner for an explicit file. The file remains owned by the caller.
pub fn init(file: std.Io.File) PosixMode {
    return initFd(file.handle, Ops.posix());
}

/// Creates a mode owner with injected operations. The descriptor remains owned by the caller.
pub fn initFd(fd: std.posix.fd_t, ops: Ops) PosixMode {
    return .{
        .fd = fd,
        .ops = ops,
    };
}

/// Saves the exact current attributes and applies `mode`.
/// A second call while active is a no-op and does not replace the saved attributes.
pub fn apply(self: *PosixMode, mode: Mode) std.posix.TermiosSetError!void {
    if (self.original != null) return;

    const original = try self.ops.get(self.fd);
    const action: std.posix.TCSA = switch (mode) {
        .prompt_edit => .DRAIN,
        .generation_interrupt => .NOW,
    };
    const changed = transform(original, mode);
    try self.ops.set(self.fd, action, changed);

    self.original = original;
    self.restore_action = action;
}

/// Restores the exact saved attributes. A failed restore remains retryable.
/// Calling restore while inactive is a no-op.
pub fn restore(self: *PosixMode) std.posix.TermiosSetError!void {
    const original = self.original orelse return;
    try self.ops.set(self.fd, self.restore_action, original);
    self.original = null;
}

pub fn isActive(self: *const PosixMode) bool {
    return self.original != null;
}

/// Derives attributes without changing the input value.
pub fn transform(original: std.posix.termios, mode: Mode) std.posix.termios {
    var changed = original;
    switch (mode) {
        .prompt_edit => {
            changed.lflag.ECHO = false;
            changed.lflag.ICANON = false;
            changed.lflag.IEXTEN = false;
            changed.lflag.ISIG = false;

            changed.iflag.IXON = false;
            changed.iflag.ICRNL = false;
            changed.iflag.INPCK = false;
            changed.iflag.ISTRIP = false;
            changed.iflag.BRKINT = false;

            changed.oflag.OPOST = false;
            changed.cflag.CSIZE = .CS8;
            changed.cc[@intFromEnum(std.posix.V.MIN)] = 1;
            changed.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        },
        .generation_interrupt => {
            changed.lflag.ICANON = false;
            changed.lflag.ECHO = false;
            changed.cc[@intFromEnum(std.posix.V.MIN)] = 0;
            changed.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        },
    }
    return changed;
}

fn posixGet(
    _: ?*anyopaque,
    fd: std.posix.fd_t,
) std.posix.TermiosGetError!std.posix.termios {
    return std.posix.tcgetattr(fd);
}

fn posixSet(
    _: ?*anyopaque,
    fd: std.posix.fd_t,
    action: std.posix.TCSA,
    attributes: std.posix.termios,
) std.posix.TermiosSetError!void {
    return std.posix.tcsetattr(fd, action, attributes);
}

const FakeOps = struct {
    attributes: std.posix.termios,
    get_error: bool = false,
    set_failures: usize = 0,
    get_count: usize = 0,
    set_count: usize = 0,
    last_fd: ?std.posix.fd_t = null,
    last_action: ?std.posix.TCSA = null,
    last_set: ?std.posix.termios = null,

    fn ops(fake: *FakeOps) Ops {
        return .{
            .context = fake,
            .get_fn = get,
            .set_fn = set,
        };
    }

    fn get(context: ?*anyopaque, fd: std.posix.fd_t) std.posix.TermiosGetError!std.posix.termios {
        const fake: *FakeOps = @ptrCast(@alignCast(context.?));
        fake.get_count += 1;
        fake.last_fd = fd;
        if (fake.get_error) return error.NotATerminal;
        return fake.attributes;
    }

    fn set(
        context: ?*anyopaque,
        fd: std.posix.fd_t,
        action: std.posix.TCSA,
        attributes: std.posix.termios,
    ) std.posix.TermiosSetError!void {
        const fake: *FakeOps = @ptrCast(@alignCast(context.?));
        fake.set_count += 1;
        fake.last_fd = fd;
        fake.last_action = action;
        fake.last_set = attributes;
        if (fake.set_failures > 0) {
            fake.set_failures -= 1;
            return error.ProcessOrphaned;
        }
        fake.attributes = attributes;
    }
};

fn sampleTermios() std.posix.termios {
    var attributes: std.posix.termios = std.mem.zeroes(std.posix.termios);
    attributes.lflag.ECHO = true;
    attributes.lflag.ICANON = true;
    attributes.lflag.IEXTEN = true;
    attributes.lflag.ISIG = true;
    attributes.lflag.ECHOK = true;
    attributes.iflag.IXON = true;
    attributes.iflag.ICRNL = true;
    attributes.iflag.INPCK = true;
    attributes.iflag.ISTRIP = true;
    attributes.iflag.BRKINT = true;
    attributes.iflag.IGNCR = true;
    attributes.oflag.OPOST = true;
    attributes.oflag.ONLCR = true;
    attributes.cflag.CSIZE = .CS5;
    attributes.cc[@intFromEnum(std.posix.V.MIN)] = 7;
    attributes.cc[@intFromEnum(std.posix.V.TIME)] = 9;
    return attributes;
}

fn expectTermiosEqual(expected: std.posix.termios, actual: std.posix.termios) !void {
    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&expected),
        std.mem.asBytes(&actual),
    );
}

test "prompt edit transformation is raw and makes Ctrl-C a byte" {
    const original = sampleTermios();
    const changed = transform(original, .prompt_edit);

    try std.testing.expect(!changed.lflag.ECHO);
    try std.testing.expect(!changed.lflag.ICANON);
    try std.testing.expect(!changed.lflag.IEXTEN);
    try std.testing.expect(!changed.lflag.ISIG);
    try std.testing.expect(!changed.iflag.IXON);
    try std.testing.expect(!changed.iflag.ICRNL);
    try std.testing.expect(!changed.iflag.INPCK);
    try std.testing.expect(!changed.iflag.ISTRIP);
    try std.testing.expect(!changed.iflag.BRKINT);
    try std.testing.expect(!changed.oflag.OPOST);
    try std.testing.expectEqual(std.posix.CSIZE.CS8, changed.cflag.CSIZE);
    try std.testing.expectEqual(@as(u8, 1), changed.cc[@intFromEnum(std.posix.V.MIN)]);
    try std.testing.expectEqual(@as(u8, 0), changed.cc[@intFromEnum(std.posix.V.TIME)]);
    try std.testing.expect(changed.lflag.ECHOK);
    try std.testing.expect(changed.iflag.IGNCR);
    try std.testing.expect(changed.oflag.ONLCR);
}

test "generation interrupt transformation preserves ISIG and unrelated flags" {
    const original = sampleTermios();
    const changed = transform(original, .generation_interrupt);

    try std.testing.expect(!changed.lflag.ECHO);
    try std.testing.expect(!changed.lflag.ICANON);
    try std.testing.expect(changed.lflag.ISIG);
    try std.testing.expect(changed.lflag.IEXTEN);
    try std.testing.expectEqual(@as(u8, 0), changed.cc[@intFromEnum(std.posix.V.MIN)]);
    try std.testing.expectEqual(@as(u8, 0), changed.cc[@intFromEnum(std.posix.V.TIME)]);

    var expected = original;
    expected.lflag.ECHO = false;
    expected.lflag.ICANON = false;
    expected.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    expected.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    try expectTermiosEqual(expected, changed);
}

test "apply saves exact original and restore is idempotent" {
    const original = sampleTermios();
    var fake: FakeOps = .{ .attributes = original };
    var state = initFd(42, fake.ops());

    try state.apply(.prompt_edit);
    try std.testing.expect(state.isActive());
    try std.testing.expectEqual(@as(usize, 1), fake.get_count);
    try std.testing.expectEqual(@as(usize, 1), fake.set_count);
    try std.testing.expectEqual(@as(std.posix.fd_t, 42), fake.last_fd.?);
    try std.testing.expectEqual(std.posix.TCSA.DRAIN, fake.last_action.?);
    try expectTermiosEqual(transform(original, .prompt_edit), fake.attributes);

    try state.apply(.generation_interrupt);
    try std.testing.expectEqual(@as(usize, 1), fake.get_count);
    try std.testing.expectEqual(@as(usize, 1), fake.set_count);

    try state.restore();
    try std.testing.expect(!state.isActive());
    try std.testing.expectEqual(@as(usize, 2), fake.set_count);
    try std.testing.expectEqual(std.posix.TCSA.DRAIN, fake.last_action.?);
    try expectTermiosEqual(original, fake.attributes);

    try state.restore();
    try std.testing.expectEqual(@as(usize, 2), fake.set_count);
}

test "generation mode applies and restores immediately" {
    const original = sampleTermios();
    var fake: FakeOps = .{ .attributes = original };
    var state = initFd(8, fake.ops());

    try state.apply(.generation_interrupt);
    try std.testing.expectEqual(std.posix.TCSA.NOW, fake.last_action.?);
    try expectTermiosEqual(transform(original, .generation_interrupt), fake.attributes);
    try state.restore();
    try std.testing.expectEqual(std.posix.TCSA.NOW, fake.last_action.?);
    try expectTermiosEqual(original, fake.attributes);
}

test "get failure leaves state inactive and does not set" {
    var fake: FakeOps = .{
        .attributes = sampleTermios(),
        .get_error = true,
    };
    var state = initFd(3, fake.ops());

    try std.testing.expectError(error.NotATerminal, state.apply(.prompt_edit));
    try std.testing.expect(!state.isActive());
    try std.testing.expectEqual(@as(usize, 1), fake.get_count);
    try std.testing.expectEqual(@as(usize, 0), fake.set_count);
    try state.restore();
    try std.testing.expectEqual(@as(usize, 0), fake.set_count);
}

test "apply failure rolls ownership state back" {
    const original = sampleTermios();
    var fake: FakeOps = .{
        .attributes = original,
        .set_failures = 1,
    };
    var state = initFd(4, fake.ops());

    try std.testing.expectError(error.ProcessOrphaned, state.apply(.prompt_edit));
    try std.testing.expect(!state.isActive());
    try expectTermiosEqual(original, fake.attributes);

    try state.apply(.prompt_edit);
    try std.testing.expect(state.isActive());
    try std.testing.expectEqual(@as(usize, 2), fake.get_count);
    try std.testing.expectEqual(@as(usize, 2), fake.set_count);
}

test "restore failure retains exact original for retry" {
    const original = sampleTermios();
    var fake: FakeOps = .{ .attributes = original };
    var state = initFd(5, fake.ops());
    try state.apply(.generation_interrupt);

    fake.set_failures = 1;
    try std.testing.expectError(error.ProcessOrphaned, state.restore());
    try std.testing.expect(state.isActive());
    try expectTermiosEqual(transform(original, .generation_interrupt), fake.attributes);

    try state.restore();
    try std.testing.expect(!state.isActive());
    try expectTermiosEqual(original, fake.attributes);
}
