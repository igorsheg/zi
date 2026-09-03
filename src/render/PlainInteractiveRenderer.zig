//! Raw-terminal renderer used when Markdown parsing is disabled.

const std = @import("std");
const agent = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const tool = @import("../tool/root.zig");
const MarkdownStreamRenderer = @import("MarkdownStreamRenderer.zig");
const SafeText = @import("SafeText.zig");
const Stream = @import("StreamRenderer.zig");
const Theme = @import("Theme.zig");
const Spinner = @import("Spinner.zig").Spinner;
const ToolPresentation = @import("ToolPresentation.zig");

const PlainInteractiveRenderer = @This();

allocator: std.mem.Allocator,
writer: *std.Io.Writer,
theme: Theme,
width: usize,
width_source: ?MarkdownStreamRenderer.WidthSource = null,
stream: Stream.StreamRenderer,
tools: ToolPresentation,
show_reasoning: bool = false,
spinner: ?*Spinner = null,
spinner_allocation_failed: bool = false,
turn_active: bool = false,
reasoning_active: bool = false,
reasoning_stream_wrote_text: bool = false,
reasoning_wrote_text: bool = false,
separator_after_reasoning: bool = false,
reasoning_text: SafeText.SafeText = .{},
write_error: ?std.Io.Writer.Error = null,

pub fn init(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    theme: Theme,
    width: usize,
) PlainInteractiveRenderer {
    return .{
        .allocator = allocator,
        .writer = writer,
        .theme = theme,
        .width = width,
        .stream = .init(writer),
        .tools = .init(allocator, writer, theme, width),
    };
}

pub fn deinit(self: *PlainInteractiveRenderer) void {
    self.tools.deinit();
    self.* = undefined;
}

/// Replaces value-only styling between provider turns.
pub fn setTheme(self: *PlainInteractiveRenderer, theme: Theme) void {
    std.debug.assert(!self.turn_active);
    self.theme = theme;
    self.tools.setTheme(theme);
}

pub fn setSpinner(self: *PlainInteractiveRenderer, spinner: ?*Spinner) void {
    self.spinner = spinner;
    self.tools.setSpinner(spinner);
}

pub fn setShowReasoning(self: *PlainInteractiveRenderer, visible: bool) void {
    self.show_reasoning = visible;
}

pub fn setWidthSource(
    self: *PlainInteractiveRenderer,
    source: MarkdownStreamRenderer.WidthSource,
) void {
    self.width_source = source;
}

pub fn begin(self: *PlainInteractiveRenderer) !agent.Loop.Observer {
    std.debug.assert(!self.turn_active);
    self.turn_active = true;
    errdefer self.turn_active = false;
    self.width = self.resolveWidth();
    self.stream = .init(self.writer);
    self.tools.resetTurn(self.width);
    self.reasoning_active = false;
    self.reasoning_stream_wrote_text = false;
    self.reasoning_wrote_text = false;
    self.separator_after_reasoning = false;
    self.reasoning_text = .{};
    self.write_error = null;
    self.spinner_allocation_failed = false;
    if (self.spinner) |spinner| {
        spinner.clearRetry();
        try spinner.setLabel("working", "working...");
        spinner.show();
    }
    return agent.Loop.Observer.from(self);
}

pub fn close(self: *PlainInteractiveRenderer, terminal: Stream.Terminal) !void {
    defer self.turn_active = false;
    self.closeReasoning();
    self.stream.close(terminal);
    self.tools.close();
    if (self.spinner) |spinner| spinner.hide();
}

pub fn check(self: *const PlainInteractiveRenderer) !void {
    try self.stream.check();
    try self.tools.check();
    if (self.write_error) |err| return err;
    if (self.spinner_allocation_failed) return error.OutOfMemory;
    if (self.spinner) |spinner| try spinner.check();
}

pub fn wroteAssistantText(self: *const PlainInteractiveRenderer) bool {
    return self.stream.wroteAssistantText() or self.reasoning_wrote_text;
}

pub fn toolObserver(self: *PlainInteractiveRenderer) ?agent.Loop.ToolObserver {
    return agent.Loop.ToolObserver.from(self);
}

pub fn emit(self: *PlainInteractiveRenderer, event: ai.StreamEvent.StreamEvent) void {
    switch (event) {
        .retry => {},
        else => if (self.spinner) |spinner| spinner.finishRetry() catch {
            self.spinner_allocation_failed = true;
        },
    }
    switch (event) {
        .reasoning_delta => |maybe_bytes| {
            self.requestSpinnerLabel("thinking", "thinking...");
            if (self.show_reasoning) if (maybe_bytes) |bytes| {
                if (bytes.len != 0) self.feedReasoning(bytes);
            };
        },
        .text_delta => {
            if (self.spinner) |spinner| spinner.hide();
            self.closeReasoning();
            self.consumeReasoningSeparator();
            self.tools.closeCluster();
            self.stream.emit(event);
        },
        .retry => |retry| {
            if (self.spinner) |spinner| spinner.setRetry(
                retry.delay_ms,
                retry.attempt,
                retry.maximum_attempts,
            ) catch {
                self.spinner_allocation_failed = true;
            };
            if (self.spinner) |spinner| spinner.show();
            const abandoned_text = self.stream.abandonAttempt();
            const abandoned_reasoning = self.reasoning_stream_wrote_text;
            self.closeReasoning();
            if (abandoned_text or abandoned_reasoning) {
                self.consumeReasoningSeparator();
                self.write("\x1b[2m[unexpected end]\x1b[0m\n");
            }
            self.stream.emit(event);
        },
        .tool_call_start => |start| {
            var label_buffer: [160]u8 = undefined;
            const label = std.fmt.bufPrint(&label_buffer, "[{s}] composing...", .{start.name}) catch "composing...";
            self.requestSpinnerLabel("compose", label);
            self.closeReasoning();
            self.stream.emit(event);
        },
        .tool_call_end => {
            self.requestSpinnerLabel("working", "working...");
            self.stream.emit(event);
        },
        .reasoning_item => {
            self.closeReasoning();
            self.stream.emit(event);
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
            self.stream.emit(event);
            if (self.spinner) |spinner| spinner.hide();
        },
        else => self.stream.emit(event),
    }
}

pub fn beginTool(
    self: *PlainInteractiveRenderer,
    observation: agent.Loop.ToolObservation,
) ?tool.Tool.DisplaySink {
    self.closeReasoning();
    self.tools.setWidth(self.resolveWidth());
    if (self.stream.wroteAssistantText() or self.reasoning_wrote_text) {
        self.tools.requireSeparator();
    }
    self.separator_after_reasoning = false;
    return self.tools.beginTool(observation);
}

pub fn endTool(
    self: *PlainInteractiveRenderer,
    observation: agent.Loop.ToolObservation,
    result: *const ai.Item.ToolResult,
) void {
    self.tools.endTool(observation, result);
}

fn requestSpinnerLabel(self: *PlainInteractiveRenderer, key: []const u8, label: []const u8) void {
    const spinner = self.spinner orelse return;
    spinner.requestLabel(key, label) catch {
        self.spinner_allocation_failed = true;
    };
}

fn feedReasoning(self: *PlainInteractiveRenderer, bytes: []const u8) void {
    if (!self.reasoning_active) {
        if (self.spinner) |spinner| spinner.hide();
        const follows_assistant = self.stream.wroteAssistantText();
        self.stream.boundary();
        self.tools.closeCluster();
        if (follows_assistant and !self.separator_after_reasoning) self.write("\n");
        self.consumeReasoningSeparator();
        self.reasoning_active = true;
        self.reasoning_stream_wrote_text = false;
        self.reasoning_text = .{};
        self.write("\x1b[2m\x1b[3m");
    }
    self.reasoning_text.feed(.{ .context = self, .emit_fn = reasoningOutput }, bytes);
    self.flush();
}

fn closeReasoning(self: *PlainInteractiveRenderer) void {
    if (!self.reasoning_active) return;
    self.reasoning_text.finish(.{ .context = self, .emit_fn = reasoningOutput });
    self.write("\x1b[0m\n");
    self.reasoning_active = false;
    self.reasoning_stream_wrote_text = false;
    self.separator_after_reasoning = true;
    self.flush();
}

fn consumeReasoningSeparator(self: *PlainInteractiveRenderer) void {
    if (!self.separator_after_reasoning) return;
    self.write("\n");
    self.separator_after_reasoning = false;
}

fn reasoningOutput(context: *anyopaque, bytes: []const u8) void {
    const self: *PlainInteractiveRenderer = @ptrCast(@alignCast(context));
    self.write(bytes);
    if (bytes.len != 0 and self.write_error == null) {
        self.reasoning_stream_wrote_text = true;
        self.reasoning_wrote_text = true;
    }
}

fn write(self: *PlainInteractiveRenderer, bytes: []const u8) void {
    if (self.write_error != null or bytes.len == 0) return;
    self.writer.writeAll(bytes) catch |err| {
        self.write_error = err;
    };
}

fn flush(self: *PlainInteractiveRenderer) void {
    if (self.write_error != null) return;
    self.writer.flush() catch |err| {
        self.write_error = err;
    };
}

fn resolveWidth(self: *const PlainInteractiveRenderer) usize {
    return if (self.width_source) |source| source.resolve() else self.width;
}

test "plain interactive reasoning is optional sanitized and style bounded" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const theme = try Theme.resolve(.{ .configured_theme = "ansi", .configured_tint = "teal" });
    var renderer = init(std.testing.allocator, &output.writer, theme, 80);
    defer renderer.deinit();
    renderer.setShowReasoning(true);
    const observer = try renderer.begin();
    observer.emit(.{ .reasoning_delta = "safe\xe2" });
    observer.emit(.{ .reasoning_delta = "\x82\xac\xff" });
    observer.emit(.{ .text_delta = "answer" });
    observer.emit(.{ .done = .{} });
    try renderer.close(.complete);
    try renderer.check();
    try std.testing.expectEqualStrings(
        "\x1b[2m\x1b[3msafe€\xef\xbf\xbd\x1b[0m\n\nanswer\n",
        output.written(),
    );
    try std.testing.expect(renderer.wroteAssistantText());
}

test "plain retry marks and separates abandoned assistant text" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const theme = try Theme.resolve(.{ .configured_theme = "ansi", .configured_tint = "teal" });
    var renderer = init(std.testing.allocator, &output.writer, theme, 80);
    defer renderer.deinit();
    const observer = try renderer.begin();
    observer.emit(.{ .text_delta = "partial" });
    observer.emit(.{ .retry = .{ .attempt = 1, .maximum_attempts = 3, .delay_ms = 1000 } });
    observer.emit(.{ .text_delta = "replacement" });
    observer.emit(.{ .done = .{} });
    try renderer.close(.complete);
    try renderer.check();
    try std.testing.expectEqualStrings(
        "partial\n\x1b[2m[unexpected end]\x1b[0m\nreplacement\n",
        output.written(),
    );
}

test "plain interactive renderer exposes tool presentation without Markdown" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const theme = try Theme.resolve(.{ .configured_theme = "ansi", .configured_tint = "teal" });
    var renderer = init(std.testing.allocator, &output.writer, theme, 80);
    defer renderer.deinit();
    const observer = try renderer.begin();
    observer.emit(.{ .text_delta = "answer" });
    observer.emit(.{ .done = .{} });
    try renderer.close(.complete);
    try renderer.check();
    try std.testing.expectEqualStrings("answer\n", output.written());
    try std.testing.expect(renderer.toolObserver() != null);
}
