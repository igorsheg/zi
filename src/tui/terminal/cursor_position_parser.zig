const std = @import("std");

/// Maximum user input retained while one cursor-position report is sought.
pub const max_deferred_bytes: usize = 256;
const max_candidate_bytes: usize = 14;

pub const Position = struct {
    row: u16,
    column: u16,
};

const Candidate = union(enum) {
    prefix,
    complete: Position,
    invalid,
};

/// Incrementally removes the first CSI row;column R report from a byte stream.
/// Every other byte remains available in its original order through
/// `deferredInput`. The parser owns fixed storage and performs no I/O.
pub const Parser = struct {
    candidate: [max_candidate_bytes]u8 = undefined,
    candidate_len: u8 = 0,
    deferred: [max_deferred_bytes]u8 = undefined,
    deferred_len: u16 = 0,
    found: ?Position = null,

    pub fn feed(self: *Parser, byte: u8) error{DeferredInputFull}!void {
        if (self.found != null) return self.appendDeferred(&.{byte});

        self.candidate[self.candidate_len] = byte;
        self.candidate_len += 1;
        switch (classify(self.candidate[0..self.candidate_len])) {
            .prefix => {},
            .complete => |value| {
                self.found = value;
                self.candidate_len = 0;
            },
            .invalid => try self.rejectCandidate(),
        }
    }

    /// Preserves an incomplete report candidate when probing stops.
    pub fn finish(self: *Parser) error{DeferredInputFull}!void {
        try self.appendDeferred(self.candidate[0..self.candidate_len]);
        self.candidate_len = 0;
    }

    pub fn position(self: *const Parser) ?Position {
        return self.found;
    }

    pub fn deferredInput(self: *const Parser) []const u8 {
        return self.deferred[0..self.deferred_len];
    }

    fn rejectCandidate(self: *Parser) error{DeferredInputFull}!void {
        const bytes = self.candidate[0..self.candidate_len];
        const retain_escape = bytes[bytes.len - 1] == 0x1b;
        const forward_len = bytes.len - @intFromBool(retain_escape);
        try self.appendDeferred(bytes[0..forward_len]);
        if (retain_escape) self.candidate[0] = 0x1b;
        self.candidate_len = @intFromBool(retain_escape);
    }

    fn appendDeferred(self: *Parser, bytes: []const u8) error{DeferredInputFull}!void {
        const start: usize = self.deferred_len;
        if (bytes.len > self.deferred.len - start) return error.DeferredInputFull;
        @memcpy(self.deferred[start..][0..bytes.len], bytes);
        self.deferred_len += @intCast(bytes.len);
    }
};

fn classify(bytes: []const u8) Candidate {
    if (bytes.len == 0) return .prefix;
    if (bytes[0] != 0x1b) return .invalid;
    if (bytes.len == 1) return .prefix;
    if (bytes[1] != '[') return .invalid;

    var index: usize = 2;
    const row_start = index;
    while (index < bytes.len and std.ascii.isDigit(bytes[index])) : (index += 1) {}
    const row_len = index - row_start;
    if (row_len > 5) return .invalid;
    if (index == bytes.len) return .prefix;
    if (row_len == 0 or bytes[index] != ';') return .invalid;

    index += 1;
    const column_start = index;
    while (index < bytes.len and std.ascii.isDigit(bytes[index])) : (index += 1) {}
    const column_len = index - column_start;
    if (column_len > 5) return .invalid;
    if (index == bytes.len) return .prefix;
    if (column_len == 0 or bytes[index] != 'R' or index + 1 != bytes.len) return .invalid;

    const row = std.fmt.parseUnsigned(u16, bytes[row_start .. row_start + row_len], 10) catch
        return .invalid;
    const column = std.fmt.parseUnsigned(
        u16,
        bytes[column_start .. column_start + column_len],
        10,
    ) catch return .invalid;
    if (row == 0 or column == 0) return .invalid;
    return .{ .complete = .{ .row = row, .column = column } };
}

fn feedAll(parser: *Parser, bytes: []const u8) !void {
    for (bytes) |byte| try parser.feed(byte);
}

test "cursor probe finds an interleaved report without reordering input" {
    var parser: Parser = .{};
    try feedAll(&parser, "a\x1b[1;xbc\x1b[42;7Rtail");
    try parser.finish();

    const expected: Position = .{ .row = 42, .column = 7 };
    try std.testing.expectEqual(expected, parser.position().?);
    try std.testing.expectEqualStrings("a\x1b[1;xbctail", parser.deferredInput());
}

test "cursor probe preserves overlapping escapes and split reports" {
    var parser: Parser = .{};
    try feedAll(&parser, "before\x1b");
    try feedAll(&parser, "\x1b[9;");
    try feedAll(&parser, "3Rafter");
    try parser.finish();

    const expected: Position = .{ .row = 9, .column = 3 };
    try std.testing.expectEqual(expected, parser.position().?);
    try std.testing.expectEqualStrings("before\x1bafter", parser.deferredInput());
}

test "cursor probe preserves incomplete and invalid reports" {
    var parser: Parser = .{};
    try feedAll(&parser, "x\x1b[0;2Ry\x1b[12");
    try parser.finish();

    try std.testing.expect(parser.position() == null);
    try std.testing.expectEqualStrings("x\x1b[0;2Ry\x1b[12", parser.deferredInput());
}
