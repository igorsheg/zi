//! Synchronous normal-buffer adapter from borrowed agent stream events to the
//! bounded Markdown parser. Observer callbacks cannot fail, so allocation and
//! writer failures become sticky and are returned by `check` after `close`.

const std = @import("std");
const ai = @import("../ai/root.zig");
const agent = @import("../agent/root.zig");
const tool = @import("../tool/root.zig");
const Markdown = @import("Markdown.zig");
const MarkdownOutput = @import("MarkdownOutput.zig");
const SafeText = @import("SafeText.zig");
const StreamRenderer = @import("StreamRenderer.zig");
const Theme = @import("Theme.zig");
const Spinner = @import("Spinner.zig").Spinner;
const ToolPresentation = @import("ToolPresentation.zig");

const MarkdownStreamRenderer = @This();

const safe_buffer_bytes: usize = 4096;

const ContentKind = enum {
    assistant,
    reasoning,
};

/// Allocation-free source for the current content width. The implementation is
/// borrowed for the renderer lifetime and may query terminal geometry.
pub const WidthSource = struct {
    context: *const anyopaque,
    resolve_fn: *const fn (*const anyopaque) usize,

    pub fn resolve(self: WidthSource) usize {
        return self.resolve_fn(self.context);
    }

    pub fn from(implementation: anytype) WidthSource {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("MarkdownStreamRenderer.WidthSource.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn resolve(context: *const anyopaque) usize {
                const self: *const Implementation = @ptrCast(@alignCast(context));
                return self.resolve();
            }
        };
        return .{ .context = implementation, .resolve_fn = Adapter.resolve };
    }
};

allocator: std.mem.Allocator,
writer: *std.Io.Writer,
theme: Theme,
tool_presentation: ToolPresentation,
wrap_width: usize,
width_source: ?WidthSource = null,
markdown: ?Markdown = null,
safe_text: SafeText.SafeText = .{},
safe_buffer: [safe_buffer_bytes]u8 = undefined,
safe_length: usize = 0,
write_error: ?std.Io.Writer.Error = null,
render_error: ?Markdown.Error = null,
show_reasoning: bool = false,
spinner: ?*Spinner = null,
terminal: bool = false,
stream_active: bool = false,
reasoning_active: bool = false,
reasoning_stream_wrote_text: bool = false,
reasoning_wrote_text: bool = false,
separator_after_reasoning: bool = false,
content_kind: ContentKind = .assistant,
stream_wrote_text: bool = false,
wrote_assistant_text: bool = false,
trailing_newlines: usize = 0,
answer_started: bool = false,

/// Initializes a reusable renderer without allocating. Call `deinit` after the
/// last turn so retained Markdown lookahead and wrap storage are released.
pub fn init(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    theme: Theme,
    wrap_width: usize,
) MarkdownStreamRenderer {
    return .{
        .allocator = allocator,
        .writer = writer,
        .theme = theme,
        .tool_presentation = .init(allocator, writer, theme, wrap_width),
        .wrap_width = wrap_width,
    };
}

pub fn deinit(self: *MarkdownStreamRenderer) void {
    self.tool_presentation.deinit();
    if (self.markdown) |*markdown| markdown.deinit();
    self.* = undefined;
}

pub fn setWidthSource(self: *MarkdownStreamRenderer, source: WidthSource) void {
    self.width_source = source;
}

pub fn setSpinner(self: *MarkdownStreamRenderer, spinner: ?*Spinner) void {
    self.spinner = spinner;
    self.tool_presentation.setSpinner(spinner);
}

pub fn setShowReasoning(self: *MarkdownStreamRenderer, visible: bool) void {
    self.show_reasoning = visible;
}

fn resolveWidth(self: *const MarkdownStreamRenderer) usize {
    return if (self.width_source) |source| source.resolve() else self.wrap_width;
}

/// Starts one user turn and returns its borrowed synchronous observer.
pub fn begin(self: *MarkdownStreamRenderer) !agent.Loop.Observer {
    self.safe_text = .{};
    self.safe_length = 0;
    self.write_error = null;
    self.render_error = null;
    self.terminal = false;
    self.stream_active = false;
    self.stream_wrote_text = false;
    self.reasoning_active = false;
    self.reasoning_stream_wrote_text = false;
    self.reasoning_wrote_text = false;
    self.separator_after_reasoning = false;
    self.content_kind = .assistant;
    self.wrote_assistant_text = false;
    self.trailing_newlines = 0;
    self.answer_started = false;
    self.wrap_width = self.resolveWidth();
    self.tool_presentation.resetTurn(self.wrap_width);
    if (self.spinner) |spinner| {
        spinner.clearRetry();
        try spinner.setLabel("working", "working...");
        spinner.show();
    }
    if (self.markdown) |*markdown| {
        markdown.reset(self.wrap_width);
    } else {
        self.markdown = Markdown.init(
            self.allocator,
            .{ .context = self, .emit_fn = markdownOutput },
            self.theme,
            self.wrap_width,
        );
    }
    return agent.Loop.Observer.from(self);
}

pub fn close(self: *MarkdownStreamRenderer, terminal: StreamRenderer.Terminal) !void {
    _ = terminal;
    if (self.terminal) return;
    self.terminal = true;
    self.closeReasoning();
    self.closeStream();
    self.tool_presentation.close();
    if (self.spinner) |spinner| spinner.hide();
}

pub fn check(self: *const MarkdownStreamRenderer) !void {
    if (self.render_error) |err| return err;
    if (self.write_error) |err| return err;
    try self.tool_presentation.check();
    if (self.spinner) |spinner| try spinner.check();
}

pub fn wroteAssistantText(self: *const MarkdownStreamRenderer) bool {
    return self.wrote_assistant_text or self.reasoning_wrote_text;
}

pub fn toolObserver(self: *MarkdownStreamRenderer) ?agent.Loop.ToolObserver {
    return agent.Loop.ToolObserver.from(self);
}

pub fn beginTool(
    self: *MarkdownStreamRenderer,
    observation: agent.Loop.ToolObservation,
) ?tool.Tool.DisplaySink {
    self.closeReasoning();
    self.tool_presentation.setWidth(self.resolveWidth());
    if (self.wrote_assistant_text or self.reasoning_wrote_text) {
        self.tool_presentation.requireSeparator();
    }
    self.separator_after_reasoning = false;
    return self.tool_presentation.beginTool(observation);
}

pub fn endTool(
    self: *MarkdownStreamRenderer,
    observation: agent.Loop.ToolObservation,
    result: *const ai.Item.ToolResult,
) void {
    self.tool_presentation.endTool(observation, result);
}

pub fn emit(self: *MarkdownStreamRenderer, event: ai.StreamEvent.StreamEvent) void {
    if (self.terminal or self.write_error != null or self.render_error != null) return;
    switch (event) {
        .retry => {},
        else => if (self.spinner) |spinner| spinner.clearRetry(),
    }
    switch (event) {
        .text_delta => |bytes| {
            self.closeReasoning();
            self.tool_presentation.closeCluster();
            self.feed(bytes);
        },
        .reasoning_delta => |maybe_bytes| {
            self.requestSpinnerLabel("thinking", "thinking...");
            if (self.show_reasoning) if (maybe_bytes) |bytes| {
                if (bytes.len != 0) self.feedReasoning(bytes);
            };
        },
        .tool_call_start => |start| {
            var label_buffer: [160]u8 = undefined;
            const label = std.fmt.bufPrint(&label_buffer, "[{s}] composing...", .{start.name}) catch "composing...";
            self.requestSpinnerLabel("compose", label);
            self.closeReasoning();
            self.closeStream();
        },
        .tool_call_end => {
            self.requestSpinnerLabel("working", "working...");
        },
        // Opaque reasoning ends any preceding visible item.
        .reasoning_item => {
            self.closeReasoning();
            self.closeStream();
        },
        // Each provider request is a complete Markdown stream. A retry
        // abandons the partial attempt: hax marks it so the replacement
        // stream does not read as a continuation of the truncated text.
        .retry => |retry| {
            if (self.spinner) |spinner| spinner.setRetry(
                retry.delay_ms,
                retry.attempt,
                retry.maximum_attempts,
            ) catch {
                if (self.render_error == null) self.render_error = error.OutOfMemory;
            };
            if (self.spinner) |spinner| spinner.show();
            const abandoned_text = self.stream_wrote_text or self.reasoning_stream_wrote_text;
            self.closeReasoning();
            self.closeStream();
            if (abandoned_text) {
                if (self.separator_after_reasoning) self.write("\n");
                self.separator_after_reasoning = false;
                self.write("\x1b[2m[unexpected end]\x1b[0m\n");
            }
        },
        .progress => |progress| {
            const uncached_total = progress.total_tokens -| progress.cached_tokens;
            if (uncached_total != 0) {
                const uncached_processed = progress.processed_tokens -| progress.cached_tokens;
                const percentage = @min(100, uncached_processed *| 100 / uncached_total);
                var label_buffer: [40]u8 = undefined;
                const label = std.fmt.bufPrint(&label_buffer, "processing... {d}%", .{percentage}) catch
                    "processing...";
                self.requestSpinnerLabel("processing", label);
            }
        },
        .done, .failure => {
            self.closeReasoning();
            self.closeStream();
            if (self.spinner) |spinner| spinner.hide();
        },
        else => {},
    }
}

fn requestSpinnerLabel(self: *MarkdownStreamRenderer, key: []const u8, label: []const u8) void {
    const spinner = self.spinner orelse return;
    spinner.requestLabel(key, label) catch {
        if (self.render_error == null) self.render_error = error.OutOfMemory;
    };
}

fn markdownOutput(
    context: *anyopaque,
    bytes: []const u8,
    kind: MarkdownOutput.Kind,
) MarkdownOutput.Error!void {
    const self: *MarkdownStreamRenderer = @ptrCast(@alignCast(context));
    switch (kind) {
        .content => self.outputContent(bytes),
        .raw => self.write(bytes),
    }
}

fn feedReasoning(self: *MarkdownStreamRenderer, bytes: []const u8) void {
    if (!self.reasoning_active) self.beginReasoning();
    if (!self.reasoning_active) return;
    self.safe_text.feed(.{ .context = self, .emit_fn = safeOutput }, bytes);
    self.flushSafeBuffer();
    self.flush();
}

fn beginReasoning(self: *MarkdownStreamRenderer) void {
    if (self.spinner) |spinner| spinner.hide();
    const follows_assistant = self.stream_active and self.stream_wrote_text;
    self.closeStream();
    self.tool_presentation.closeCluster();
    if (follows_assistant or self.separator_after_reasoning) self.write("\n");
    self.separator_after_reasoning = false;
    self.reasoning_active = true;
    self.reasoning_stream_wrote_text = false;
    self.content_kind = .reasoning;
    self.safe_text = .{};
    self.safe_length = 0;
    self.wrap_width = self.resolveWidth();
    self.markdown.?.reset(self.wrap_width);
    self.markdown.?.setStyled(false) catch |err| {
        self.render_error = err;
        self.reasoning_active = false;
        return;
    };
    self.write("\x1b[2m\x1b[3m");
}

fn closeReasoning(self: *MarkdownStreamRenderer) void {
    if (!self.reasoning_active) return;
    self.safe_text.finish(.{ .context = self, .emit_fn = safeOutput });
    self.flushSafeBuffer();
    if (self.render_error == null) self.markdown.?.finish() catch |err| {
        self.render_error = err;
    };
    self.write("\x1b[0m\n");
    self.reasoning_active = false;
    self.reasoning_stream_wrote_text = false;
    self.separator_after_reasoning = true;
    self.content_kind = .assistant;
    self.safe_length = 0;
    self.flush();
}

fn ensureStream(self: *MarkdownStreamRenderer) void {
    if (self.stream_active) return;
    if (self.spinner) |spinner| spinner.hide();
    if (self.separator_after_reasoning) self.write("\n");
    self.separator_after_reasoning = false;
    self.stream_active = true;
    self.stream_wrote_text = false;
    self.trailing_newlines = 0;
    self.answer_started = false;
    self.safe_text = .{};
    self.safe_length = 0;
    self.wrap_width = self.resolveWidth();
    if (self.markdown) |*markdown| {
        markdown.reset(self.wrap_width);
        markdown.setStyled(true) catch |err| {
            self.render_error = err;
        };
    }
}

fn feed(self: *MarkdownStreamRenderer, original: []const u8) void {
    self.ensureStream();
    var bytes = original;
    if (!self.answer_started) {
        while (bytes.len != 0 and (bytes[0] == '\n' or bytes[0] == '\r')) bytes = bytes[1..];
        if (bytes.len == 0) return;
        self.answer_started = true;
    }
    self.safe_text.feed(.{ .context = self, .emit_fn = safeOutput }, bytes);
    self.flushSafeBuffer();
    self.flush();
}

/// Receives already-sanitized scalar chunks from SafeText. Coalescing here
/// prevents the Markdown parser from rebuilding lookahead once per ASCII byte.
fn safeOutput(context: *anyopaque, bytes: []const u8) void {
    const self: *MarkdownStreamRenderer = @ptrCast(@alignCast(context));
    if (self.render_error != null or bytes.len == 0) return;
    var remaining = bytes;
    while (remaining.len != 0) {
        if (self.safe_length == self.safe_buffer.len) self.flushSafeBuffer();
        if (self.render_error != null) return;
        const available = self.safe_buffer.len - self.safe_length;
        const amount = @min(available, remaining.len);
        @memcpy(self.safe_buffer[self.safe_length..][0..amount], remaining[0..amount]);
        self.safe_length += amount;
        remaining = remaining[amount..];
    }
}

fn flushSafeBuffer(self: *MarkdownStreamRenderer) void {
    if (self.safe_length == 0 or self.render_error != null) return;
    const bytes = self.safe_buffer[0..self.safe_length];
    self.safe_length = 0;
    self.markdown.?.feed(bytes) catch |err| {
        self.render_error = err;
    };
}

fn closeStream(self: *MarkdownStreamRenderer) void {
    if (!self.stream_active) return;
    self.safe_text.finish(.{ .context = self, .emit_fn = safeOutput });
    self.flushSafeBuffer();
    if (self.render_error == null) self.markdown.?.finish() catch |err| {
        self.render_error = err;
    };
    if (self.stream_wrote_text and self.write_error == null) self.write("\n");
    self.trailing_newlines = 0;
    self.stream_wrote_text = false;
    self.stream_active = false;
    self.answer_started = false;
    self.flush();
}

fn outputContent(self: *MarkdownStreamRenderer, bytes: []const u8) void {
    var start: usize = 0;
    for (bytes, 0..) |byte, index| {
        if (byte != '\n') continue;
        if (index > start) self.outputVisible(bytes[start..index]);
        self.trailing_newlines +|= 1;
        start = index + 1;
    }
    if (start < bytes.len) self.outputVisible(bytes[start..]);
}

fn outputVisible(self: *MarkdownStreamRenderer, bytes: []const u8) void {
    if (bytes.len == 0) return;
    self.flushTrailingNewlines();
    self.write(bytes);
    if (self.write_error == null) switch (self.content_kind) {
        .assistant => {
            self.stream_wrote_text = true;
            self.wrote_assistant_text = true;
        },
        .reasoning => {
            self.reasoning_stream_wrote_text = true;
            self.reasoning_wrote_text = true;
        },
    };
}

fn flushTrailingNewlines(self: *MarkdownStreamRenderer) void {
    while (self.trailing_newlines != 0 and self.write_error == null) {
        self.write("\n");
        self.trailing_newlines -= 1;
    }
}

fn write(self: *MarkdownStreamRenderer, bytes: []const u8) void {
    if (self.write_error != null or bytes.len == 0) return;
    self.writer.writeAll(bytes) catch |err| {
        self.write_error = err;
    };
}

fn flush(self: *MarkdownStreamRenderer) void {
    if (self.write_error != null) return;
    self.writer.flush() catch |err| {
        self.write_error = err;
    };
}

fn testTheme() !Theme {
    return Theme.resolve(.{ .configured_theme = "ansi", .configured_tint = "teal" });
}

test "renderer sanitizes and styles split Markdown while dropping initial line endings" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var renderer = MarkdownStreamRenderer.init(std.testing.allocator, &output.writer, try testTheme(), 0);
    defer renderer.deinit();
    const observer = try renderer.begin();

    observer.emit(.{ .text_delta = "\n\r## He" });
    observer.emit(.{ .text_delta = "ad\n\n**bo" });
    observer.emit(.{ .text_delta = "ld**\x1b[31m" });
    observer.emit(.{ .done = .{} });
    try renderer.close(.complete);
    try renderer.check();

    // Raw SGR bypasses deferred newline bookkeeping, as hax's disp_write_ansi
    // does, so the next span's opener precedes the pending blank line on wire.
    try std.testing.expectEqualStrings(
        "\x1b[1mHead\x1b[22m\x1b[1m\n\nbold\x1b[22m\n",
        output.written(),
    );
    try std.testing.expect(renderer.wroteAssistantText());
}

test "provider boundaries reset Markdown state without closing the user turn" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var renderer = MarkdownStreamRenderer.init(std.testing.allocator, &output.writer, try testTheme(), 0);
    defer renderer.deinit();
    const observer = try renderer.begin();

    observer.emit(.{ .text_delta = "**one" });
    observer.emit(.{ .tool_call_start = .{ .id = "call", .name = "read" } });
    observer.emit(.{ .done = .{} });
    observer.emit(.{ .text_delta = "two**" });
    observer.emit(.{ .done = .{} });
    try renderer.close(.complete);
    try renderer.check();

    try std.testing.expectEqualStrings("\x1b[1mone\x1b[22m\ntwo**\n", output.written());
}

test "reasoning is hidden by default and visible mode resets before assistant text" {
    var hidden_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer hidden_output.deinit();
    var hidden = MarkdownStreamRenderer.init(
        std.testing.allocator,
        &hidden_output.writer,
        try testTheme(),
        80,
    );
    defer hidden.deinit();
    const hidden_observer = try hidden.begin();
    hidden_observer.emit(.{ .reasoning_delta = "private" });
    hidden_observer.emit(.{ .text_delta = "answer" });
    hidden_observer.emit(.{ .done = .{} });
    try hidden.close(.complete);
    try hidden.check();
    try std.testing.expectEqualStrings("answer\n", hidden_output.written());

    var visible_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer visible_output.deinit();
    var visible = MarkdownStreamRenderer.init(
        std.testing.allocator,
        &visible_output.writer,
        try testTheme(),
        80,
    );
    defer visible.deinit();
    visible.setShowReasoning(true);
    const visible_observer = try visible.begin();
    visible_observer.emit(.{ .reasoning_delta = "**think**" });
    visible_observer.emit(.{ .reasoning_item = .{ .opaque_json = "{}" } });
    visible_observer.emit(.{ .text_delta = "answer" });
    visible_observer.emit(.{ .reasoning_delta = "after" });
    visible_observer.emit(.{ .done = .{} });
    try visible.close(.complete);
    try visible.check();
    try std.testing.expectEqualStrings(
        "\x1b[2m\x1b[3mthink\x1b[0m\n\nanswer\n\n\x1b[2m\x1b[3mafter\x1b[0m\n",
        visible_output.written(),
    );
    try std.testing.expect(visible.wroteAssistantText());
}

test "visible reasoning sanitizes split input and closes at tool boundaries" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var renderer = MarkdownStreamRenderer.init(std.testing.allocator, &output.writer, try testTheme(), 80);
    defer renderer.deinit();
    renderer.setShowReasoning(true);
    const observer = try renderer.begin();
    observer.emit(.{ .reasoning_delta = "safe\xe2" });
    observer.emit(.{ .reasoning_delta = "\x82\xac\xff\x1b[31m" });
    observer.emit(.{ .tool_call_start = .{ .id = "id", .name = "read" } });
    observer.emit(.{ .done = .{} });
    try renderer.close(.complete);
    try renderer.check();
    try std.testing.expectEqualStrings(
        "\x1b[2m\x1b[3msafe€\xef\xbf\xbd\x1b[0m\n",
        output.written(),
    );
}

test "empty and stripped-control streams do not count as assistant text" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var renderer = MarkdownStreamRenderer.init(std.testing.allocator, &output.writer, try testTheme(), 80);
    defer renderer.deinit();
    const observer = try renderer.begin();

    observer.emit(.{ .text_delta = "\n\r\x1b[?1049h\x1b[?1049l" });
    observer.emit(.{ .done = .{} });
    try renderer.close(.complete);
    try renderer.check();

    try std.testing.expectEqualStrings("", output.written());
    try std.testing.expect(!renderer.wroteAssistantText());
}

test "writer and parser errors are retained for synchronous check" {
    var failed_writer: std.Io.Writer = .failing;
    var writer_renderer = MarkdownStreamRenderer.init(
        std.testing.allocator,
        &failed_writer,
        try testTheme(),
        0,
    );
    defer writer_renderer.deinit();
    const writer_observer = try writer_renderer.begin();
    writer_observer.emit(.{ .text_delta = "visible" });
    try writer_renderer.close(.failure);
    try std.testing.expectError(error.WriteFailed, writer_renderer.check());

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var parser_renderer = MarkdownStreamRenderer.init(
        failing.allocator(),
        &output.writer,
        try testTheme(),
        0,
    );
    defer parser_renderer.deinit();
    const parser_observer = try parser_renderer.begin();
    parser_observer.emit(.{ .text_delta = "text" });
    try parser_renderer.close(.failure);
    try std.testing.expectError(error.OutOfMemory, parser_renderer.check());
}

test "width source is resolved for each provider stream" {
    const DynamicWidth = struct {
        const Self = @This();

        width: usize,

        pub fn resolve(self: *const Self) usize {
            return self.width;
        }
    };

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var dynamic: DynamicWidth = .{ .width = 10 };
    var renderer = MarkdownStreamRenderer.init(std.testing.allocator, &output.writer, try testTheme(), 0);
    defer renderer.deinit();
    renderer.setWidthSource(.from(&dynamic));
    const observer = try renderer.begin();

    observer.emit(.{ .text_delta = "abc def ghi" });
    observer.emit(.{ .done = .{} });
    dynamic.width = 80;
    observer.emit(.{ .text_delta = "abc def ghi" });
    observer.emit(.{ .done = .{} });
    try renderer.close(.complete);
    try renderer.check();

    try std.testing.expectEqualStrings(
        "abc def gh\x1b[3D\x1b[K\nghi\nabc def ghi\n",
        output.written(),
    );
}

test "retry after partial output emits the unexpected-end marker" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var renderer = MarkdownStreamRenderer.init(std.testing.allocator, &output.writer, try testTheme(), 80);
    defer renderer.deinit();
    const observer = try renderer.begin();

    observer.emit(.{ .text_delta = "partial answer" });
    observer.emit(.{ .retry = .{ .attempt = 2, .maximum_attempts = 3, .delay_ms = 0 } });
    observer.emit(.{ .text_delta = "full answer" });
    observer.emit(.{ .done = .{} });
    try renderer.close(.complete);
    try renderer.check();

    try std.testing.expectEqualStrings(
        "partial answer\n\x1b[2m[unexpected end]\x1b[0m\nfull answer\n",
        output.written(),
    );
}

test "retry without rendered output stays silent" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var renderer = MarkdownStreamRenderer.init(std.testing.allocator, &output.writer, try testTheme(), 80);
    defer renderer.deinit();
    const observer = try renderer.begin();

    observer.emit(.{ .retry = .{ .attempt = 2, .maximum_attempts = 3, .delay_ms = 0 } });
    observer.emit(.{ .text_delta = "answer" });
    observer.emit(.{ .done = .{} });
    try renderer.close(.complete);
    try renderer.check();

    try std.testing.expectEqualStrings("answer\n", output.written());
}
