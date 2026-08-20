const std = @import("std");

const InputDecoder = @This();

pub const Action = union(enum) {
    text_byte: u8,
    submit,
    follow_up,
    escape,
    interrupt,
    end_of_input,
    backspace,
    delete,
    tab,
    cursor_left,
    cursor_right,
    cursor_up,
    cursor_down,
    home,
    end,
    ignored,
};

const State = union(enum) {
    idle,
    escape: i64,
    csi: Sequence,
    ss3: i64,
};

const Sequence = struct {
    started_ms: i64,
    bytes: [16]u8 = undefined,
    len: u8 = 0,
};

state: State = .idle,

pub fn reset(self: *InputDecoder) void {
    self.* = .{};
}

pub fn hasPending(self: *const InputDecoder) bool {
    return self.state != .idle;
}

/// Consumes one terminal byte. A null result means the decoder needs more bytes
/// before it can distinguish Escape from a control sequence.
pub fn feed(self: *InputDecoder, byte: u8, now_ms: i64) ?Action {
    return switch (self.state) {
        .idle => self.feedIdle(byte, now_ms),
        .escape => |started_ms| self.feedEscape(byte, started_ms, now_ms),
        .csi => |*sequence| self.feedCsi(sequence, byte, now_ms),
        .ss3 => self.feedSs3(byte),
    };
}

/// Resolves a bare Escape after the caller's quiet-period deadline. Incomplete
/// control sequences are discarded rather than misreported as cancellation.
pub fn flush(self: *InputDecoder, now_ms: i64, timeout_ms: i64) ?Action {
    const started_ms = switch (self.state) {
        .idle => return null,
        .escape => |started| started,
        .csi => |sequence| sequence.started_ms,
        .ss3 => |started| started,
    };
    if (now_ms - started_ms < timeout_ms) return null;
    const action: Action = if (self.state == .escape) .escape else .ignored;
    self.state = .idle;
    return action;
}

fn feedIdle(self: *InputDecoder, byte: u8, now_ms: i64) ?Action {
    return switch (byte) {
        0x1b => pending: {
            self.state = .{ .escape = now_ms };
            break :pending null;
        },
        3 => .interrupt,
        4 => .end_of_input,
        8, 127 => .backspace,
        '\r', '\n' => .submit,
        '\t' => .tab,
        0...2, 5...7, 11, 12, 14...26, 28...31 => .ignored,
        else => .{ .text_byte = byte },
    };
}

fn feedEscape(self: *InputDecoder, byte: u8, started_ms: i64, now_ms: i64) ?Action {
    return switch (byte) {
        '[' => pending: {
            self.state = .{ .csi = .{ .started_ms = started_ms } };
            break :pending null;
        },
        'O' => pending: {
            self.state = .{ .ss3 = started_ms };
            break :pending null;
        },
        '\r', '\n' => resolved: {
            self.state = .idle;
            break :resolved .follow_up;
        },
        0x1b => pending: {
            self.state = .{ .escape = now_ms };
            break :pending null;
        },
        else => resolved: {
            self.state = .idle;
            break :resolved .ignored;
        },
    };
}

fn feedCsi(self: *InputDecoder, sequence: *Sequence, byte: u8, now_ms: i64) ?Action {
    sequence.started_ms = now_ms;
    if (sequence.len == sequence.bytes.len) {
        self.state = .idle;
        return .ignored;
    }
    sequence.bytes[sequence.len] = byte;
    sequence.len += 1;
    if (byte < 0x40 or byte > 0x7e) return null;

    const encoded = sequence.bytes[0..sequence.len];
    const action: Action = if (std.mem.eql(u8, encoded, "A"))
        .cursor_up
    else if (std.mem.eql(u8, encoded, "B"))
        .cursor_down
    else if (std.mem.eql(u8, encoded, "C"))
        .cursor_right
    else if (std.mem.eql(u8, encoded, "D"))
        .cursor_left
    else if (std.mem.eql(u8, encoded, "H") or
        std.mem.eql(u8, encoded, "1~") or
        std.mem.eql(u8, encoded, "7~"))
        .home
    else if (std.mem.eql(u8, encoded, "F") or
        std.mem.eql(u8, encoded, "4~") or
        std.mem.eql(u8, encoded, "8~"))
        .end
    else if (std.mem.eql(u8, encoded, "3~"))
        .delete
    else
        .ignored;
    self.state = .idle;
    return action;
}

fn feedSs3(self: *InputDecoder, byte: u8) Action {
    self.state = .idle;
    return switch (byte) {
        'A' => .cursor_up,
        'B' => .cursor_down,
        'C' => .cursor_right,
        'D' => .cursor_left,
        'H' => .home,
        'F' => .end,
        else => .ignored,
    };
}

test "decoder distinguishes submit follow-up and timed Escape" {
    var decoder: InputDecoder = .{};
    try std.testing.expect(decoder.feed('\r', 0).? == .submit);
    try std.testing.expect(decoder.feed(0x1b, 10) == null);
    try std.testing.expect(decoder.feed('\r', 11).? == .follow_up);
    try std.testing.expect(decoder.feed(0x1b, 20) == null);
    try std.testing.expect(decoder.flush(49, 30) == null);
    try std.testing.expect(decoder.flush(50, 30).? == .escape);
    try std.testing.expect(!decoder.hasPending());
}

test "decoder handles navigation and editing sequences" {
    const Case = struct {
        bytes: []const u8,
        expected: Action,
    };
    const cases = [_]Case{
        .{ .bytes = "\x1b[A", .expected = .cursor_up },
        .{ .bytes = "\x1b[B", .expected = .cursor_down },
        .{ .bytes = "\x1b[C", .expected = .cursor_right },
        .{ .bytes = "\x1b[D", .expected = .cursor_left },
        .{ .bytes = "\x1b[H", .expected = .home },
        .{ .bytes = "\x1b[4~", .expected = .end },
        .{ .bytes = "\x1b[3~", .expected = .delete },
        .{ .bytes = "\x1bOF", .expected = .end },
    };
    for (cases) |case| {
        var decoder: InputDecoder = .{};
        var result: ?Action = null;
        for (case.bytes) |byte| {
            if (decoder.feed(byte, 1)) |action| result = action;
        }
        try std.testing.expect(result != null);
        try std.testing.expectEqual(std.meta.activeTag(case.expected), std.meta.activeTag(result.?));
        try std.testing.expect(!decoder.hasPending());
    }
}

test "decoder preserves text bytes and control actions" {
    var decoder: InputDecoder = .{};
    try std.testing.expectEqual(@as(u8, 'x'), decoder.feed('x', 0).?.text_byte);
    try std.testing.expectEqual(@as(u8, 0xc3), decoder.feed(0xc3, 0).?.text_byte);
    try std.testing.expect(decoder.feed(127, 0).? == .backspace);
    try std.testing.expect(decoder.feed(3, 0).? == .interrupt);
    try std.testing.expect(decoder.feed(4, 0).? == .end_of_input);
}

test "decoder discards incomplete and bounded unknown sequences" {
    var decoder: InputDecoder = .{};
    _ = decoder.feed(0x1b, 0);
    _ = decoder.feed('[', 0);
    _ = decoder.feed('1', 0);
    try std.testing.expect(decoder.flush(30, 30).? == .ignored);

    _ = decoder.feed(0x1b, 40);
    _ = decoder.feed('[', 40);
    var action: ?Action = null;
    for (0..17) |_| {
        if (decoder.feed('1', 40)) |resolved| action = resolved;
    }
    try std.testing.expect(action.? == .ignored);
    try std.testing.expect(!decoder.hasPending());
}
