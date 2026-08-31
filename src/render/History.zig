const std = @import("std");
const agent = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const terminal = @import("../terminal/root.zig");
const tool = @import("../tool/root.zig");
const Theme = @import("Theme.zig");

const interrupt_marker = "[interrupted]";

pub const maximum_heading_bytes: usize = 256;

pub const Inputs = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    writer: *std.Io.Writer,
    theme: Theme,
    columns: usize,
    show_reasoning: bool,
    items: []const ai.Item.Item,
    tools: []const tool.Tool.Tool,
    heading: []const u8,
};

/// Replays only the final visible user turn. `renderer` is one of the raw-TTY
/// stream renderers and remains owned by the caller.
pub fn replayBrief(renderer: anytype, inputs: Inputs) !void {
    if (inputs.heading.len > maximum_heading_bytes) return error.HeadingTooLong;
    var anchor: ?usize = null;
    var earlier_count: usize = 0;
    var index = inputs.items.len;
    while (index != 0) {
        index -= 1;
        if (!isAnchor(inputs.items[index])) continue;
        if (anchor == null) {
            anchor = index;
        } else {
            earlier_count += 1;
        }
    }

    try inputs.writer.writeAll("\n\x1b[2m── ");
    try inputs.writer.writeAll(inputs.heading);
    if (earlier_count != 0) {
        try inputs.writer.print(
            " · {d} earlier message{s}",
            .{ earlier_count, if (earlier_count == 1) "" else "s" },
        );
    }
    try inputs.writer.writeAll(" ──\x1b[0m\n\n");
    const start = anchor orelse {
        try inputs.writer.flush();
        return;
    };

    const dispatch = try tool.Dispatch.Dispatch.init(inputs.tools, .{});
    const observer = try renderer.begin();
    var closed = false;
    defer if (!closed) renderer.close(.failure) catch {};

    index = start;
    while (index < inputs.items.len) : (index += 1) {
        const item = &inputs.items[index];
        switch (item.*) {
            .user_message => |message| switch (message.origin) {
                .external => {
                    try terminal.RawLineInput.renderCommitted(
                        inputs.writer,
                        message.text,
                        inputs.theme.accent.open,
                        inputs.theme.accent.close,
                        inputs.columns,
                    );
                    try inputs.writer.writeByte('\n');
                },
                .compact_seed => try writeMarker(inputs.writer, "── conversation compacted ──"),
                .task_note => try writeMarker(inputs.writer, message.text),
                .continuation => {},
            },
            .assistant_message => |message| try renderAssistant(observer, inputs.writer, message),
            .reasoning => |reasoning| {
                if (inputs.show_reasoning) if (reasoning.text) |text| {
                    if (text.len != 0) observer.emit(.{ .reasoning_delta = text });
                };
                observer.emit(.{ .reasoning_item = .{ .opaque_json = "{}" } });
            },
            .tool_call => |*call| {
                const turn_end = findTurnEnd(inputs.items, index);
                const result = pairedResult(inputs.items, index, turn_end);
                var prepared = try dispatch.prepare(inputs.allocator, inputs.io, call);
                defer prepared.deinit(inputs.allocator);
                try renderTool(renderer, &prepared, result);
            },
            .tool_result, .turn_usage => {},
            .turn_boundary => observer.emit(.{ .reasoning_item = .{ .opaque_json = "{}" } }),
        }
    }

    try renderer.close(.complete);
    closed = true;
    try renderer.check();
    try inputs.writer.flush();
}

fn isAnchor(item: ai.Item.Item) bool {
    return switch (item) {
        .user_message => |message| message.origin == .external or message.origin == .compact_seed,
        else => false,
    };
}

fn findTurnEnd(items: []const ai.Item.Item, start: usize) usize {
    var end = start;
    while (end < items.len and items[end] != .turn_boundary) end += 1;
    return end;
}

fn pairedResult(items: []const ai.Item.Item, call_index: usize, turn_end: usize) ?*const ai.Item.ToolResult {
    const call = items[call_index].tool_call;
    for (items[call_index + 1 .. turn_end]) |*item| switch (item.*) {
        .tool_result => |*result| if (std.mem.eql(u8, result.call_id, call.id)) return result,
        else => {},
    };
    return null;
}

fn renderTool(renderer: anytype, prepared: *const tool.Dispatch.Prepared, result: ?*const ai.Item.ToolResult) !void {
    const action: agent.Loop.ToolAction = if (result) |value| switch (value.origin) {
        .skipped => .skip,
        .refused => .refuse,
        else => .run,
    } else .run;
    var display: tool.Tool.Display = if (prepared.tool) |selected| selected.display else .{};
    if (action == .run) {
        display.preview_mode = .collapsed;
        display.select_preview = null;
    }
    const observation: agent.Loop.ToolObservation = .{
        .call = prepared.original,
        .effective_arguments_json = prepared.effective_arguments_json,
        .display = display,
        .action = action,
    };
    _ = renderer.beginTool(observation);
    if (action != .run) {
        const paired = result orelse return;
        renderer.endTool(observation, paired);
    }
}

fn renderAssistant(
    observer: agent.Loop.Observer,
    writer: *std.Io.Writer,
    message: ai.Item.AssistantMessage,
) !void {
    if (message.text.len == 0) return;
    if (message.origin == .interrupted and std.mem.endsWith(u8, message.text, interrupt_marker)) {
        const marker_start = message.text.len - interrupt_marker.len;
        if (marker_start == 0 or message.text[marker_start - 1] == '\n') {
            if (marker_start > 1) observer.emit(.{ .text_delta = message.text[0 .. marker_start - 1] });
            observer.emit(.{ .reasoning_item = .{ .opaque_json = "{}" } });
            try writeMarker(writer, interrupt_marker);
            return;
        }
    }
    observer.emit(.{ .text_delta = message.text });
}

fn writeMarker(writer: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    try writer.writeAll("\n\x1b[2m");
    try writer.writeAll(bytes);
    try writer.writeAll("\x1b[0m\n");
    try writer.flush();
}

test "brief replay selects the final user turn and shows configured reasoning" {
    const Markdown = @import("MarkdownStreamRenderer.zig");
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const theme = try Theme.resolve(.{ .configured_theme = "ansi", .configured_tint = "teal" });
    var renderer = Markdown.init(std.testing.allocator, &output.writer, theme, 80);
    defer renderer.deinit();
    renderer.setShowReasoning(true);

    const items = [_]ai.Item.Item{
        .{ .user_message = .{ .text = @constCast("old") } },
        .{ .assistant_message = .{ .text = @constCast("old answer") } },
        .turn_boundary,
        .{ .user_message = .{ .text = @constCast("current") } },
        .{ .reasoning = .{ .text = @constCast("thought") } },
        .{ .assistant_message = .{ .text = @constCast("answer") } },
    };
    try replayBrief(&renderer, .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .writer = &output.writer,
        .theme = theme,
        .columns = 80,
        .show_reasoning = true,
        .items = &items,
        .tools = &.{},
        .heading = "resumed",
    });
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "1 earlier message") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "current") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "thought") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "answer") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "old answer") == null);
}
