//! Raw-terminal renderer used when Markdown parsing is disabled.

const std = @import("std");
const agent = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const tool = @import("../tool/root.zig");
const MarkdownStreamRenderer = @import("MarkdownStreamRenderer.zig");
const Stream = @import("StreamRenderer.zig");
const Theme = @import("Theme.zig");
const ToolPresentation = @import("ToolPresentation.zig");

const PlainInteractiveRenderer = @This();

allocator: std.mem.Allocator,
writer: *std.Io.Writer,
theme: Theme,
width: usize,
width_source: ?MarkdownStreamRenderer.WidthSource = null,
stream: Stream.StreamRenderer,
tools: ToolPresentation,

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

pub fn setWidthSource(
    self: *PlainInteractiveRenderer,
    source: MarkdownStreamRenderer.WidthSource,
) void {
    self.width_source = source;
}

pub fn begin(self: *PlainInteractiveRenderer) !agent.Loop.Observer {
    self.width = self.resolveWidth();
    self.stream = .init(self.writer);
    self.tools.resetTurn(self.width);
    return agent.Loop.Observer.from(self);
}

pub fn close(self: *PlainInteractiveRenderer, terminal: Stream.Terminal) !void {
    self.stream.close(terminal);
    self.tools.close();
}

pub fn check(self: *const PlainInteractiveRenderer) !void {
    try self.stream.check();
    try self.tools.check();
}

pub fn wroteAssistantText(self: *const PlainInteractiveRenderer) bool {
    return self.stream.wroteAssistantText();
}

pub fn toolObserver(self: *PlainInteractiveRenderer) ?agent.Loop.ToolObserver {
    return agent.Loop.ToolObserver.from(self);
}

pub fn emit(self: *PlainInteractiveRenderer, event: ai.StreamEvent.StreamEvent) void {
    if (event == .text_delta) self.tools.closeCluster();
    self.stream.emit(event);
}

pub fn beginTool(
    self: *PlainInteractiveRenderer,
    observation: agent.Loop.ToolObservation,
) ?tool.Tool.DisplaySink {
    self.tools.setWidth(self.resolveWidth());
    if (self.stream.wroteAssistantText()) self.tools.requireSeparator();
    return self.tools.beginTool(observation);
}

pub fn endTool(
    self: *PlainInteractiveRenderer,
    observation: agent.Loop.ToolObservation,
    result: *const ai.Item.ToolResult,
) void {
    self.tools.endTool(observation, result);
}

fn resolveWidth(self: *const PlainInteractiveRenderer) usize {
    return if (self.width_source) |source| source.resolve() else self.width;
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
