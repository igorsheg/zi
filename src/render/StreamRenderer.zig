const std = @import("std");
const ai = @import("../ai/root.zig");
const agent = @import("../agent/root.zig");
const SafeText = @import("SafeText.zig");

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
    wrote_assistant_text: bool = false,
    trailing_newlines: usize = 0,
    safe_text: SafeText.SafeText = .{},

    pub fn init(writer: *std.Io.Writer) StreamRenderer {
        return .{ .writer = writer };
    }

    pub fn observer(self: *StreamRenderer) agent.Loop.Observer {
        return agent.Loop.Observer.from(self);
    }

    pub fn check(self: *const StreamRenderer) std.Io.Writer.Error!void {
        if (self.write_error) |err| return err;
    }

    /// Whether sanitized assistant text has been written during this run.
    pub fn wroteAssistantText(self: *const StreamRenderer) bool {
        return self.wrote_assistant_text;
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

    /// Abandons one retrying provider attempt and reports whether it wrote visible text.
    pub fn abandonAttempt(self: *StreamRenderer) bool {
        if (self.terminal) return false;
        const wrote_text = self.stream_wrote_text;
        self.closeStream();
        return wrote_text;
    }

    /// Ends the current provider item without closing the outer user turn.
    pub fn boundary(self: *StreamRenderer) void {
        if (self.terminal) return;
        self.closeStream();
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
        self.safe_text.finish(.{ .context = self, .emit_fn = safeOutput });
        if (self.stream_wrote_text and self.write_error == null) self.write("\n");
        self.trailing_newlines = 0;
        self.stream_wrote_text = false;
        self.flush();
    }

    fn feed(self: *StreamRenderer, bytes: []const u8) void {
        self.safe_text.feed(.{ .context = self, .emit_fn = safeOutput }, bytes);
    }

    fn safeOutput(context: *anyopaque, bytes: []const u8) void {
        const self: *StreamRenderer = @ptrCast(@alignCast(context));
        if (bytes.len == 1) {
            self.outputByte(bytes[0]);
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
            self.wrote_assistant_text = true;
        }
    }

    fn output(self: *StreamRenderer, bytes: []const u8) void {
        self.flushTrailingNewlines();
        self.write(bytes);
        if (bytes.len != 0) {
            self.stream_wrote_text = true;
            self.wrote_assistant_text = true;
        }
    }

    fn flushTrailingNewlines(self: *StreamRenderer) void {
        while (self.trailing_newlines != 0 and self.write_error == null) {
            self.write("\n");
            self.trailing_newlines -= 1;
        }
    }

    fn write(self: *StreamRenderer, bytes: []const u8) void {
        if (self.write_error != null) return;
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

test "assistant text query persists across provider requests" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var renderer: StreamRenderer = .init(&output.writer);

    try std.testing.expect(!renderer.wroteAssistantText());
    renderer.emit(.{ .text_delta = "first" });
    renderer.emit(.{ .done = .{} });
    try std.testing.expect(renderer.wroteAssistantText());

    renderer.emit(.{ .text_delta = "" });
    renderer.emit(.{ .done = .{} });
    try std.testing.expect(renderer.wroteAssistantText());
    renderer.close(.complete);
    try std.testing.expect(renderer.wroteAssistantText());
}

test "empty and control-only streams do not count as assistant text" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var renderer: StreamRenderer = .init(&output.writer);

    renderer.emit(.{ .text_delta = "" });
    renderer.emit(.{ .done = .{} });
    renderer.emit(.{ .text_delta = "\x1b[?1049h\x1b[?1049l" });
    renderer.emit(.{ .done = .{} });
    renderer.close(.complete);

    try std.testing.expect(!renderer.wroteAssistantText());
    try std.testing.expectEqualStrings("", output.written());
}

test "visible sanitizer substitutions count as assistant text" {
    var invalid_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer invalid_output.deinit();
    var invalid_renderer: StreamRenderer = .init(&invalid_output.writer);
    invalid_renderer.emit(.{ .text_delta = "\xff" });
    invalid_renderer.emit(.{ .done = .{} });
    try std.testing.expect(invalid_renderer.wroteAssistantText());

    var unsafe_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer unsafe_output.deinit();
    var unsafe_renderer: StreamRenderer = .init(&unsafe_output.writer);
    unsafe_renderer.emit(.{ .text_delta = "\xc2\x9b" });
    unsafe_renderer.emit(.{ .done = .{} });
    try std.testing.expect(unsafe_renderer.wroteAssistantText());
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

test "writer failures are sticky and reported by check" {
    var writer: std.Io.Writer = .failing;
    var renderer: StreamRenderer = .init(&writer);

    renderer.emit(.{ .text_delta = "visible" });
    renderer.emit(.{ .text_delta = "ignored" });
    renderer.emit(.{ .done = .{} });
    renderer.close(.failure);

    try std.testing.expectError(error.WriteFailed, renderer.check());
}
