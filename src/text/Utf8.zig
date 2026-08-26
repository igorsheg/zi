const std = @import("std");

const replacement = "\xef\xbf\xbd";

pub const Error = error{
    OutOfMemory,
    ResultTooLarge,
};

/// Incrementally sanitizes borrowed chunks as RFC 3629 UTF-8.
///
/// `feed` and `finish` call `emit` synchronously. The callback must not retain
/// its borrowed payload. Each malformed input byte and each NUL emits one
/// U+FFFD. The sanitizer retains at most one incomplete UTF-8 sequence.
pub const Sanitizer = struct {
    bytes: [4]u8 = undefined,
    len: u3 = 0,
    want: u3 = 0,

    pub fn feed(
        self: *Sanitizer,
        comptime emit: anytype,
        context: anytype,
        input: []const u8,
    ) void {
        for (input) |byte| self.feedByte(emit, context, byte);
    }

    pub fn finish(
        self: *Sanitizer,
        comptime emit: anytype,
        context: anytype,
    ) void {
        if (self.len != 0) self.emitInvalid(emit, context);
    }

    fn feedByte(
        self: *Sanitizer,
        comptime emit: anytype,
        context: anytype,
        byte: u8,
    ) void {
        if (self.len == 0) {
            if (byte == 0) {
                emit(context, replacement);
            } else if (byte < 0x80) {
                emit(context, &.{byte});
            } else if (utf8SequenceLength(byte)) |want| {
                self.bytes[0] = byte;
                self.len = 1;
                self.want = @intCast(want);
            } else {
                emit(context, replacement);
            }
            return;
        }

        if (!isContinuation(byte)) {
            self.emitInvalid(emit, context);
            self.feedByte(emit, context, byte);
            return;
        }
        self.bytes[self.len] = byte;
        self.len += 1;
        if (self.len != self.want) return;

        const sequence = self.bytes[0..self.len];
        if (validSequence(sequence)) {
            emit(context, sequence);
            self.reset();
        } else {
            self.emitInvalid(emit, context);
        }
    }

    fn emitInvalid(
        self: *Sanitizer,
        comptime emit: anytype,
        context: anytype,
    ) void {
        for (0..self.len) |_| emit(context, replacement);
        self.reset();
    }

    fn reset(self: *Sanitizer) void {
        self.len = 0;
        self.want = 0;
    }
};

/// Returns whether a valid Unicode scalar can affect terminal display or
/// text direction without a visible glyph.
pub fn isTerminalUnsafeScalar(scalar: u21) bool {
    return (scalar >= 0x80 and scalar <= 0x9f) or
        scalar == 0x061c or
        (scalar >= 0x200b and scalar <= 0x200f) or
        scalar == 0x2028 or scalar == 0x2029 or
        (scalar >= 0x202a and scalar <= 0x202e) or
        (scalar >= 0x2060 and scalar <= 0x2069) or
        scalar == 0xfeff;
}

/// Returns an owned RFC 3629 UTF-8 copy. Each malformed input byte and each NUL
/// becomes one U+FFFD, matching hax's incremental sanitizer.
pub fn sanitize(
    allocator: std.mem.Allocator,
    input: []const u8,
    maximum_result_bytes: usize,
) Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var index: usize = 0;
    while (index < input.len) {
        const byte = input[index];
        if (byte == 0) {
            try appendBounded(allocator, &output, replacement, maximum_result_bytes);
            index += 1;
            continue;
        }
        if (byte < 0x80) {
            try appendBounded(allocator, &output, input[index .. index + 1], maximum_result_bytes);
            index += 1;
            continue;
        }

        const sequence_length = utf8SequenceLength(byte) orelse {
            try appendBounded(allocator, &output, replacement, maximum_result_bytes);
            index += 1;
            continue;
        };
        var available: usize = 1;
        while (available < sequence_length and index + available < input.len and
            isContinuation(input[index + available]))
        {
            available += 1;
        }
        if (available < sequence_length) {
            try appendReplacements(allocator, &output, available, maximum_result_bytes);
            index += available;
            continue;
        }
        const sequence = input[index .. index + sequence_length];
        if (!validSequence(sequence)) {
            try appendReplacements(allocator, &output, sequence_length, maximum_result_bytes);
        } else {
            try appendBounded(allocator, &output, sequence, maximum_result_bytes);
        }
        index += sequence_length;
    }
    return output.toOwnedSlice(allocator);
}

fn utf8SequenceLength(leader: u8) ?usize {
    if (leader >= 0xc2 and leader <= 0xdf) return 2;
    if (leader >= 0xe0 and leader <= 0xef) return 3;
    if (leader >= 0xf0 and leader <= 0xf4) return 4;
    return null;
}

fn isContinuation(byte: u8) bool {
    return byte & 0xc0 == 0x80;
}

fn validSequence(sequence: []const u8) bool {
    for (sequence[1..]) |byte| if (!isContinuation(byte)) return false;
    return switch (sequence.len) {
        2 => true,
        3 => !((sequence[0] == 0xe0 and sequence[1] < 0xa0) or
            (sequence[0] == 0xed and sequence[1] > 0x9f)),
        4 => !((sequence[0] == 0xf0 and sequence[1] < 0x90) or
            (sequence[0] == 0xf4 and sequence[1] > 0x8f)),
        else => false,
    };
}

fn appendReplacements(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    count: usize,
    maximum: usize,
) Error!void {
    if (count > (maximum -| output.items.len) / replacement.len) return error.ResultTooLarge;
    try output.ensureUnusedCapacity(allocator, count * replacement.len);
    for (0..count) |_| output.appendSliceAssumeCapacity(replacement);
}

fn appendBounded(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    bytes: []const u8,
    maximum: usize,
) Error!void {
    if (bytes.len > maximum -| output.items.len) return error.ResultTooLarge;
    try output.appendSlice(allocator, bytes);
}

test "sanitizer preserves valid UTF-8 and replaces malformed bytes individually" {
    const allocator = std.testing.allocator;
    const input = "ok \xc3\xa9 \xed\xa0\x80 \xf4\x90\x80\x80 tail\xc2";
    const expected = "ok \xc3\xa9 " ++ replacement ** 3 ++ " " ++ replacement ** 4 ++ " tail" ++ replacement;
    const output = try sanitize(allocator, input, 256);
    defer allocator.free(output);
    try std.testing.expectEqualStrings(expected, output);
}

test "sanitizer replaces NUL and reconsiders a non-continuation" {
    const allocator = std.testing.allocator;
    const input = [_]u8{ 'a', 0, 0xc3, 'A' };
    const output = try sanitize(allocator, &input, 32);
    defer allocator.free(output);
    try std.testing.expectEqualStrings("a" ++ replacement ++ replacement ++ "A", output);
}

test "sanitizer enforces final result bound" {
    try std.testing.expectError(
        error.ResultTooLarge,
        sanitize(std.testing.allocator, "\xff", 2),
    );
}

fn exerciseSanitizeAllocations(allocator: std.mem.Allocator) !void {
    const output = try sanitize(allocator, "valid \xff invalid", 128);
    allocator.free(output);
}

test "sanitizer frees partial output on every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseSanitizeAllocations,
        .{},
    );
}

const TestSink = struct {
    bytes: [64]u8 = undefined,
    len: usize = 0,

    fn emit(self: *TestSink, value: []const u8) void {
        @memcpy(self.bytes[self.len..][0..value.len], value);
        self.len += value.len;
    }
};

test "incremental sanitizer handles borrowed split chunks without allocation" {
    var sanitizer: Sanitizer = .{};
    var sink: TestSink = .{};
    var first = [_]u8{ 'a', 0xe2 };

    sanitizer.feed(TestSink.emit, &sink, &first);
    first = .{ 'x', 'x' };
    sanitizer.feed(TestSink.emit, &sink, "\x82\xac\x00\xed\xa0\x80\xc2");
    sanitizer.finish(TestSink.emit, &sink);

    try std.testing.expectEqualStrings(
        "a€" ++ replacement ++ replacement ** 3 ++ replacement,
        sink.bytes[0..sink.len],
    );
}
