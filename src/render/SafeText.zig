const std = @import("std");
const text = @import("../text/root.zig");

const EscapeClassifier = @import("../terminal/EscapeClassifier.zig");

/// Erased synchronous destination for safe text chunks.
///
/// Payloads are borrowed and are valid only for the duration of `emit`.
pub const Sink = struct {
    context: *anyopaque,
    emit_fn: *const fn (*anyopaque, []const u8) void,

    pub fn emit(self: Sink, bytes: []const u8) void {
        self.emit_fn(self.context, bytes);
    }

    pub fn from(implementation: anytype) Sink {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("SafeText.Sink.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn emit(context: *anyopaque, bytes: []const u8) void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                self.emit(bytes);
            }
        };
        return .{ .context = implementation, .emit_fn = Adapter.emit };
    }
};

/// Bounded, allocation-free decoder for untrusted streamed terminal text.
///
/// Input and emitted chunks are borrowed. `feed` consumes input synchronously,
/// and the sink must consume each output payload before returning.
pub const UnsafePolicy = enum {
    escape,
    substitute,
};

pub const SafeText = struct {
    unsafe_policy: UnsafePolicy = .escape,
    control_state: ControlState = .text,
    control_bytes: u8 = 0,
    utf8: text.Utf8Sanitizer = .{},

    pub fn feed(self: *SafeText, sink: Sink, bytes: []const u8) void {
        for (bytes) |byte| self.controlByte(sink, byte);
    }

    /// Emits any incomplete UTF-8 as replacements and discards an incomplete
    /// terminal control sequence. The decoder is ready for another stream.
    pub fn finish(self: *SafeText, sink: Sink) void {
        var output: SanitizedOutput = .{ .sink = sink, .unsafe_policy = self.unsafe_policy };
        self.utf8.finish(SanitizedOutput.emit, &output);
        self.control_state = .text;
        self.control_bytes = 0;
    }

    fn controlByte(self: *SafeText, sink: Sink, byte: u8) void {
        var reprocess = true;
        while (reprocess) {
            reprocess = false;
            if (self.control_state == .text) {
                self.control_bytes = 0;
            } else if (self.control_bytes >= EscapeClassifier.max_sequence_bytes) {
                // An unterminated sequence must not hide arbitrary future
                // text: the byte past the bound is reconsidered as plain text,
                // matching the terminal EscapeClassifier's discard policy.
                self.control_state = .text;
                self.control_bytes = 0;
            } else {
                self.control_bytes += 1;
            }
            switch (self.control_state) {
                .text => {
                    if (byte == 0x1b) {
                        self.control_state = .escape;
                    } else if (byte == '\t' or byte == '\n' or byte >= 0x20 and byte != 0x7f) {
                        var output: SanitizedOutput = .{ .sink = sink, .unsafe_policy = self.unsafe_policy };
                        self.utf8.feed(SanitizedOutput.emit, &output, &.{byte});
                    }
                },
                .escape => {
                    if (byte == '[') self.control_state = .csi else if (byte == ']') {
                        self.control_state = .osc;
                    } else if (byte == 'P' or byte == '^' or byte == '_') {
                        self.control_state = .control_string;
                    } else if (byte >= 0x20 and byte <= 0x2f) {
                        self.control_state = .escape_intermediate;
                    } else if (byte >= 0x30 and byte <= 0x7e) {
                        self.control_state = .text;
                    } else {
                        self.control_state = .text;
                        reprocess = true;
                    }
                },
                .csi => {
                    if (cancelsControl(byte)) {
                        self.control_state = .text;
                        reprocess = true;
                    } else if (byte >= 0x40 and byte <= 0x7e) self.control_state = .text;
                },
                .osc => {
                    if (cancelsControl(byte)) {
                        self.control_state = .text;
                        reprocess = true;
                    } else if (byte == 0x07) {
                        self.control_state = .text;
                    } else if (byte == 0x1b) self.control_state = .osc_escape;
                },
                .osc_escape => {
                    if (byte == '\\') {
                        self.control_state = .text;
                    } else {
                        if (cancelsControl(byte)) self.control_state = .text else self.control_state = .osc;
                        reprocess = true;
                    }
                },
                .control_string => {
                    if (cancelsControl(byte)) {
                        self.control_state = .text;
                        reprocess = true;
                    } else if (byte == 0x1b) self.control_state = .control_string_escape;
                },
                .control_string_escape => {
                    if (byte == '\\') {
                        self.control_state = .text;
                    } else {
                        if (cancelsControl(byte)) self.control_state = .text else self.control_state = .control_string;
                        reprocess = true;
                    }
                },
                .escape_intermediate => {
                    if (cancelsControl(byte)) {
                        self.control_state = .text;
                        reprocess = true;
                    } else if (byte >= 0x30 and byte <= 0x7e) self.control_state = .text;
                },
            }
        }
    }

    const SanitizedOutput = struct {
        sink: Sink,
        unsafe_policy: UnsafePolicy,

        fn emit(output: *SanitizedOutput, bytes: []const u8) void {
            if (bytes.len == 1) {
                output.sink.emit(bytes);
                return;
            }
            const scalar = decodeScalar(bytes);
            if (text.Utf8.isTerminalUnsafeScalar(scalar)) {
                switch (output.unsafe_policy) {
                    .escape => {
                        var buffer: [12]u8 = undefined;
                        const escaped = std.fmt.bufPrint(&buffer, "\\u{{{x}}}", .{scalar}) catch unreachable;
                        output.sink.emit(escaped);
                    },
                    .substitute => output.sink.emit("?"),
                }
            } else {
                output.sink.emit(bytes);
            }
        }
    };
};

const ControlState = enum {
    text,
    escape,
    csi,
    osc,
    osc_escape,
    control_string,
    control_string_escape,
    escape_intermediate,
};

fn cancelsControl(byte: u8) bool {
    return byte == '\n' or byte == 0x18 or byte == 0x1a;
}

fn decodeScalar(bytes: []const u8) u21 {
    return switch (bytes.len) {
        2 => std.unicode.utf8Decode2(bytes[0..2].*) catch unreachable,
        3 => std.unicode.utf8Decode3(bytes[0..3].*) catch unreachable,
        4 => std.unicode.utf8Decode4(bytes[0..4].*) catch unreachable,
        else => unreachable,
    };
}

const TestSink = struct {
    bytes: [512]u8 = undefined,
    len: usize = 0,

    fn emit(self: *TestSink, bytes: []const u8) void {
        @memcpy(self.bytes[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    fn written(self: *const TestSink) []const u8 {
        return self.bytes[0..self.len];
    }
};

fn decodeWithPartitions(input: []const u8, split_mask: usize, sink: *TestSink) void {
    var decoder: SafeText = .{};
    const output: Sink = .from(sink);
    var start: usize = 0;
    for (0..input.len - 1) |boundary| {
        if (split_mask & (@as(usize, 1) << @intCast(boundary)) != 0) {
            decoder.feed(output, input[start .. boundary + 1]);
            start = boundary + 1;
        }
    }
    decoder.feed(output, input[start..]);
    decoder.finish(output);
}

test "all split partitions produce identical safe text" {
    const input = "A\xe2\x82\xac\x1b[31mB\xc2\x9b\xff\x00";
    const expected = "A€B\\u{9b}\xef\xbf\xbd";
    const partition_count = @as(usize, 1) << @intCast(input.len - 1);
    for (0..partition_count) |split_mask| {
        var sink: TestSink = .{};
        decodeWithPartitions(input, split_mask, &sink);
        try std.testing.expectEqualStrings(expected, sink.written());
    }
}

test "control strings cancel on CAN SUB and newline across every split" {
    const input = "a\x1b]osc\x18b\x1bPdata\x1ac\x1b[31\nd";
    var whole: TestSink = .{};
    decodeWithPartitions(input, 0, &whole);
    for (0..input.len - 1) |boundary| {
        var split: TestSink = .{};
        decodeWithPartitions(input, @as(usize, 1) << @intCast(boundary), &split);
        try std.testing.expectEqualStrings(whole.written(), split.written());
    }
    try std.testing.expectEqualStrings("abc\nd", whole.written());
}

test "finish resolves pending UTF-8 and discards pending control" {
    var sink: TestSink = .{};
    var decoder: SafeText = .{};
    const output: Sink = .from(&sink);
    decoder.feed(output, "x\xe2");
    decoder.finish(output);
    decoder.feed(output, "y\x1b]unfinished");
    decoder.finish(output);
    decoder.feed(output, "z");
    decoder.finish(output);
    try std.testing.expectEqualStrings("x\xef\xbf\xbdyz", sink.written());
}

test "unsafe scalar policy can substitute for compact previews" {
    var sink: TestSink = .{};
    var decoder: SafeText = .{ .unsafe_policy = .substitute };
    const output: Sink = .from(&sink);
    decoder.feed(output, "a\xe2\x80\xaeb");
    decoder.finish(output);
    try std.testing.expectEqualStrings("a?b", sink.written());
}

test "unterminated control sequences stop suppressing after the shared bound" {
    for ([_]u8{ '[', ']', 'P' }) |opener| {
        var sink: TestSink = .{};
        var decoder: SafeText = .{};
        const output: Sink = .from(&sink);
        decoder.feed(output, "a\x1b");
        decoder.feed(output, &.{opener});
        // The introducer plus these bytes are discarded; the next byte is
        // reconsidered from the text state (EscapeClassifier semantics).
        for (0..EscapeClassifier.max_sequence_bytes - 1) |_| decoder.feed(output, "0");
        // The byte past the bound and everything after it is plain text again.
        decoder.feed(output, "still here");
        decoder.finish(output);
        try std.testing.expectEqualStrings("astill here", sink.written());
    }
}

test "bounded overflow handles an escape byte as a new candidate" {
    var sink: TestSink = .{};
    var decoder: SafeText = .{};
    const output: Sink = .from(&sink);
    decoder.feed(output, "\x1b[");
    for (0..EscapeClassifier.max_sequence_bytes - 1) |_| decoder.feed(output, "1");
    // This Esc is past the bound: it starts a fresh, well-formed sequence.
    decoder.feed(output, "\x1b[31mred");
    decoder.finish(output);
    try std.testing.expectEqualStrings("red", sink.written());
}
