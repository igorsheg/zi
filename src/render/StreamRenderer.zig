const std = @import("std");
const ai = @import("../ai/root.zig");
const agent = @import("../agent/root.zig");
const text = @import("../text/root.zig");

pub const Terminal = enum {
    complete,
    failure,
    interrupted,
};

/// Synchronous normal-buffer renderer for `agent.Loop.Observer`.
///
/// Event payloads are borrowed. `emit` consumes them before it returns and
/// retains only parser state. Writer failures are recorded because Observer's
/// callback cannot return an error; call `check` after the loop.
pub const StreamRenderer = struct {
    writer: *std.Io.Writer,
    write_error: ?std.Io.Writer.Error = null,
    terminal: bool = false,
    stream_wrote_text: bool = false,
    trailing_newlines: usize = 0,
    control_state: ControlState = .text,
    utf8: text.Utf8Sanitizer = .{},

    pub fn init(writer: *std.Io.Writer) StreamRenderer {
        return .{ .writer = writer };
    }

    pub fn observer(self: *StreamRenderer) agent.Loop.Observer {
        return agent.Loop.Observer.from(self);
    }

    pub fn check(self: *const StreamRenderer) std.Io.Writer.Error!void {
        if (self.write_error) |err| return err;
    }

    pub fn emit(self: *StreamRenderer, event: ai.StreamEvent.StreamEvent) void {
        if (self.terminal or self.write_error != null) return;
        switch (event) {
            .text_delta => |bytes| {
                self.feed(bytes);
                self.flush();
            },
            // These are provider-request boundaries. One Loop run may cross
            // several of them while dispatching tools.
            .done, .failure => self.closeStream(),
            else => {},
        }
    }

    /// Close a stream which ended outside the event channel, including an
    /// interrupted `agent.Loop.run`. Repeated closes have no effect.
    pub fn close(self: *StreamRenderer, terminal: Terminal) void {
        _ = terminal;
        if (self.terminal) return;
        self.terminal = true;
        self.closeStream();
    }

    fn closeStream(self: *StreamRenderer) void {
        self.utf8.finish(sanitizedOutput, self);
        if (self.stream_wrote_text and self.write_error == null) self.write("\n");
        self.trailing_newlines = 0;
        self.stream_wrote_text = false;
        self.control_state = .text;
        self.flush();
    }

    fn feed(self: *StreamRenderer, bytes: []const u8) void {
        for (bytes) |byte| self.controlByte(byte);
    }

    fn controlByte(self: *StreamRenderer, byte: u8) void {
        var reprocess = true;
        while (reprocess) {
            reprocess = false;
            switch (self.control_state) {
                .text => {
                    if (byte == 0x1b) {
                        self.control_state = .escape;
                    } else if (byte == '\t' or byte == '\n' or byte >= 0x20 and byte != 0x7f) {
                        self.utf8.feed(sanitizedOutput, self, &.{byte});
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

    fn sanitizedOutput(self: *StreamRenderer, bytes: []const u8) void {
        if (bytes.len == 1) {
            self.outputByte(bytes[0]);
            return;
        }
        const scalar = decodeScalar(bytes);
        if (text.Utf8.isTerminalUnsafeScalar(scalar)) {
            var buffer: [12]u8 = undefined;
            const escaped = std.fmt.bufPrint(&buffer, "\\u{{{x}}}", .{scalar}) catch unreachable;
            self.output(escaped);
        } else {
            self.output(bytes);
        }
    }

    fn outputByte(self: *StreamRenderer, byte: u8) void {
        if (byte == '\n') {
            self.trailing_newlines +|= 1;
        } else {
            self.flushTrailingNewlines();
            self.write(&.{byte});
            self.stream_wrote_text = true;
        }
    }

    fn output(self: *StreamRenderer, bytes: []const u8) void {
        self.flushTrailingNewlines();
        self.write(bytes);
        if (bytes.len != 0) self.stream_wrote_text = true;
    }

    fn flushTrailingNewlines(self: *StreamRenderer) void {
        while (self.trailing_newlines != 0 and self.write_error == null) {
            self.write("\n");
            self.trailing_newlines -= 1;
        }
    }

    fn write(self: *StreamRenderer, bytes: []const u8) void {
        self.writer.writeAll(bytes) catch |err| {
            self.write_error = err;
        };
    }

    fn flush(self: *StreamRenderer) void {
        if (self.write_error != null) return;
        self.writer.flush() catch |err| {
            self.write_error = err;
        };
    }
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

test "observer renders text incrementally and normalizes terminal newline" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var renderer: StreamRenderer = .init(&output.writer);
    const observer = renderer.observer();

    observer.emit(.{ .text_delta = "hello" });
    try std.testing.expectEqualStrings("hello", output.written());
    observer.emit(.{ .text_delta = "\n\n" });
    observer.emit(.{ .done = .{} });
    try std.testing.expectEqualStrings("hello\n", output.written());
    renderer.close(.complete);
    try renderer.check();
    try std.testing.expectEqualStrings("hello\n", output.written());
}

test "renderer sanitizes malformed UTF-8 across borrowed delta boundaries" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var renderer: StreamRenderer = .init(&output.writer);
    const observer = renderer.observer();
    var first = [_]u8{ 'a', 0xe2 };

    observer.emit(.{ .text_delta = &first });
    first = .{ 'x', 'x' };
    observer.emit(.{ .text_delta = "\x82\xac\xff" });
    observer.emit(.{ .done = .{} });
    renderer.close(.complete);
    try std.testing.expectEqualStrings("a€\xef\xbf\xbd\n", output.written());
}

test "renderer strips alternate-screen and split terminal controls" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var renderer: StreamRenderer = .init(&output.writer);
    const observer = renderer.observer();

    observer.emit(.{ .text_delta = "safe\x1b[?104" });
    observer.emit(.{ .text_delta = "9hhidden\x1b[?1049l text\x00" });
    observer.emit(.{ .done = .{} });
    renderer.close(.complete);
    try std.testing.expectEqualStrings("safehidden text\n", output.written());
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\x1b") == null);
}

test "provider done events do not close a multi-request loop" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var renderer: StreamRenderer = .init(&output.writer);
    const observer = renderer.observer();

    observer.emit(.{ .text_delta = "before " });
    observer.emit(.{ .done = .{} });
    observer.emit(.{ .text_delta = "after" });
    observer.emit(.{ .done = .{} });
    try std.testing.expectEqualStrings("before \nafter\n", output.written());
    renderer.close(.complete);
    try std.testing.expectEqualStrings("before \nafter\n", output.written());
}

test "failure and interruption close partial text once" {
    var failed: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer failed.deinit();
    var failure_renderer: StreamRenderer = .init(&failed.writer);
    failure_renderer.emit(.{ .text_delta = "partial" });
    failure_renderer.emit(.{ .failure = .{ .message = "borrowed" } });
    failure_renderer.close(.failure);
    try std.testing.expectEqualStrings("partial\n", failed.written());

    var interrupted: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer interrupted.deinit();
    var interrupt_renderer: StreamRenderer = .init(&interrupted.writer);
    interrupt_renderer.emit(.{ .text_delta = "cut\n\n" });
    interrupt_renderer.close(.interrupted);
    try std.testing.expectEqualStrings("cut\n", interrupted.written());
}

test "renderer visibly escapes split C1 and bidi scalars" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var renderer: StreamRenderer = .init(&output.writer);

    renderer.emit(.{ .text_delta = "safe\xc2" });
    renderer.emit(.{ .text_delta = "\x9b \xe2\x80" });
    renderer.emit(.{ .text_delta = "\x8e text" });
    renderer.emit(.{ .done = .{} });

    try std.testing.expectEqualStrings("safe\\u{9b} \\u{200e} text\n", output.written());
}
