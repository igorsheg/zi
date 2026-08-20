const std = @import("std");
const ai = @import("../../ai/root.zig");
const session_event = @import("../AgentSessionEvent.zig");
const SessionTranscript = @import("../SessionTranscript.zig");
const LineEditor = @import("input/LineEditor.zig");

const NormalScreenRenderer = @This();

writer: *std.Io.Writer,
prompt_visible: bool = false,
assistant_line_open: bool = false,
thinking_line_open: bool = false,

pub fn init(writer: *std.Io.Writer) NormalScreenRenderer {
    return .{ .writer = writer };
}

pub fn renderWelcome(self: *NormalScreenRenderer) !void {
    try self.writer.writeAll("Zi interactive. Enter submits, Alt+Enter queues, Escape cancels, Ctrl-D exits.\n");
}

pub fn renderTranscript(
    self: *NormalScreenRenderer,
    transcript: *const SessionTranscript,
) !void {
    try self.erasePrompt();
    for (transcript.items) |item| switch (item.content) {
        .model_change => |identity| try self.renderModel(identity),
        .user => |user| try self.renderUser(user.parts),
        .assistant => |response| try self.renderResponse(response),
        .tool_results => |results| for (results.results) |result| try self.renderToolResult(result),
        .failure => |failure| try self.writer.print(
            "[turn failed: {s}]\n",
            .{@tagName(failure.category)},
        ),
        .cancelled => try self.writer.writeAll("[turn cancelled]\n"),
        .interrupted => try self.writer.writeAll("[turn interrupted]\n"),
    };
}

pub fn renderEvent(
    self: *NormalScreenRenderer,
    event: session_event.Event,
) !void {
    try self.erasePrompt();
    switch (event) {
        .agent_start, .turn_start, .turn_end => {},
        .message_start => |started| switch (started.message) {
            .request => |request| for (request.parts) |part| switch (part) {
                .user => |user| try self.renderUser(&.{user}),
                .tool_result, .retry_prompt => {},
            },
            .response => {},
        },
        .message_update => |update| switch (update.update) {
            .part_start => |start| switch (start.part) {
                .thinking => try self.beginThinking(),
                .text, .tool_call => {},
            },
            .part_delta => |delta| switch (delta.delta) {
                .text => |text| {
                    try self.beginAssistant();
                    try writeSafeText(self.writer, text, true);
                },
                .thinking => |thinking| {
                    try self.beginThinking();
                    try writeSafeText(self.writer, thinking, true);
                },
                .tool_call => {},
            },
            .part_end, .usage => {},
        },
        .message_end => |ended| switch (ended.message) {
            .published => |message| switch (message) {
                .request => {},
                .response => try self.finishAssistant(),
            },
            .discarded_response => |discarded| {
                try self.finishAssistant();
                try self.writer.print("[response discarded: {s}]\n", .{@tagName(discarded.outcome)});
            },
        },
        .tool_execution_start => |started| {
            try self.finishAssistant();
            try self.writer.writeAll("[tool ");
            try writeSafeText(self.writer, started.name, false);
            try self.writer.writeAll("] ");
            try writeSafeText(self.writer, started.arguments_json, false);
            try self.writer.writeByte('\n');
        },
        .tool_execution_end => |ended| switch (ended.result) {
            .published => |result| try self.renderToolResult(result),
            .discarded => |outcome| try self.writer.print(
                "[tool result discarded: {s}]\n",
                .{@tagName(outcome)},
            ),
        },
        .agent_end => |ended| switch (ended.outcome) {
            .completed => {},
            .cancelled => try self.writer.writeAll("[turn cancelled]\n"),
            .interrupted => try self.writer.writeAll("[turn interrupted]\n"),
            .failed => |failure| try self.writer.print("[turn failed: {s}]\n", .{@tagName(failure)}),
        },
        .agent_settled => |settled| if (settled.availability == .poisoned) {
            try self.writer.writeAll("[session unavailable, reopen the durable session]\n");
        },
    }
}

pub fn renderNotice(self: *NormalScreenRenderer, label: []const u8) !void {
    try self.erasePrompt();
    try self.finishAssistant();
    try self.writer.writeByte('[');
    try writeSafeText(self.writer, label, false);
    try self.writer.writeAll("]\n");
}

pub fn renderCompletionFailure(self: *NormalScreenRenderer, failure: anyerror) !void {
    try self.renderNotice(@errorName(failure));
}

pub fn redrawPrompt(self: *NormalScreenRenderer, editor: *const LineEditor) !void {
    try self.finishAssistant();
    try self.writer.writeAll("\r\x1b[2K> ");
    try writeSafeText(self.writer, editor.text(), false);
    const suffix = editor.suffixScalarCount();
    if (suffix > 0) try self.writer.print("\x1b[{d}D", .{suffix});
    self.prompt_visible = true;
    try self.writer.flush();
}

pub fn finish(self: *NormalScreenRenderer) !void {
    try self.erasePrompt();
    try self.finishAssistant();
    try self.writer.writeByte('\n');
    try self.writer.flush();
}

fn erasePrompt(self: *NormalScreenRenderer) !void {
    if (!self.prompt_visible) return;
    try self.writer.writeAll("\r\x1b[2K");
    self.prompt_visible = false;
}

fn beginAssistant(self: *NormalScreenRenderer) !void {
    if (self.thinking_line_open) {
        try self.writer.writeByte('\n');
        self.thinking_line_open = false;
    }
    self.assistant_line_open = true;
}

fn beginThinking(self: *NormalScreenRenderer) !void {
    if (self.thinking_line_open) return;
    if (self.assistant_line_open) {
        try self.writer.writeByte('\n');
        self.assistant_line_open = false;
    }
    try self.writer.writeAll("[thinking] ");
    self.thinking_line_open = true;
}

fn finishAssistant(self: *NormalScreenRenderer) !void {
    if (!self.assistant_line_open and !self.thinking_line_open) return;
    try self.writer.writeByte('\n');
    self.assistant_line_open = false;
    self.thinking_line_open = false;
}

fn renderModel(self: *NormalScreenRenderer, identity: ai.message.ModelIdentity) !void {
    try self.writer.writeAll("[model ");
    try writeSafeText(self.writer, identity.provider, false);
    try self.writer.writeByte('/');
    try writeSafeText(self.writer, identity.model, false);
    try self.writer.writeAll("]\n");
}

fn renderUser(self: *NormalScreenRenderer, parts: []const ai.message.UserContent) !void {
    try self.finishAssistant();
    try self.writer.writeAll("> ");
    for (parts, 0..) |part, index| {
        if (index != 0) try self.writer.writeByte(' ');
        switch (part) {
            .text => |text| try writeSafeText(self.writer, text, true),
            .image => |image| {
                try self.writer.writeAll("[image ");
                try writeSafeText(self.writer, image.media_type, false);
                try self.writer.writeByte(']');
            },
        }
    }
    try self.writer.writeByte('\n');
}

fn renderResponse(self: *NormalScreenRenderer, response: ai.message.ResponseMessage) !void {
    try self.finishAssistant();
    for (response.parts) |part| switch (part) {
        .text => |text| {
            try writeSafeText(self.writer, text.text, true);
            try self.writer.writeByte('\n');
        },
        .thinking => |thinking| {
            try self.writer.writeAll("[thinking] ");
            try writeSafeText(self.writer, thinking.text, true);
            try self.writer.writeByte('\n');
        },
        .tool_call => |call| {
            try self.writer.writeAll("[tool call ");
            try writeSafeText(self.writer, call.name, false);
            try self.writer.writeAll("] ");
            try writeSafeText(self.writer, call.arguments_json, false);
            try self.writer.writeByte('\n');
        },
    };
}

fn renderToolResult(self: *NormalScreenRenderer, result: ai.message.ToolResult) !void {
    try self.finishAssistant();
    try self.writer.writeAll("[tool result ");
    try writeSafeText(self.writer, result.name, false);
    try self.writer.print(" {s}]\n", .{@tagName(result.outcome)});
    for (result.content) |content| switch (content) {
        .text => |text| {
            try writeSafeText(self.writer, text, true);
            if (!std.mem.endsWith(u8, text, "\n")) try self.writer.writeByte('\n');
        },
        .image => |image| {
            try self.writer.writeAll("[image ");
            try writeSafeText(self.writer, image.media_type, false);
            try self.writer.writeAll("]\n");
        },
    };
}

fn writeSafeText(writer: *std.Io.Writer, text: []const u8, allow_newlines: bool) !void {
    if (!std.unicode.utf8ValidateSlice(text)) {
        for (text) |byte| {
            if (byte >= 0x20 and byte < 0x7f) {
                try writer.writeByte(byte);
            } else if (allow_newlines and byte == '\n') {
                try writer.writeByte('\n');
            } else if (byte == '\t') {
                try writer.writeByte('\t');
            } else {
                try writer.writeAll("�");
            }
        }
        return;
    }

    var iterator = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (iterator.peek(1).len != 0) {
        const start = iterator.i;
        const scalar = iterator.nextCodepoint().?;
        const codepoint = text[start..iterator.i];
        if (allow_newlines and scalar == '\n') {
            try writer.writeByte('\n');
        } else if (scalar == '\t') {
            try writer.writeByte('\t');
        } else if (scalar < 0x20 or (scalar >= 0x7f and scalar <= 0x9f)) {
            try writer.writeAll("�");
        } else {
            try writer.writeAll(codepoint);
        }
    }
}

test "renderer streams normalized text and redraws the prompt" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var renderer = NormalScreenRenderer.init(&output.writer);
    var editor = LineEditor.init(std.testing.allocator, 32);
    defer editor.deinit();
    try editor.replace("next");

    try renderer.renderEvent(.{ .message_start = .{
        .run_id = @enumFromInt(1),
        .turn_index = 1,
        .message = .{ .request = .{ .parts = &.{.{ .user = .{ .text = "hello" } }} } },
    } });
    try renderer.renderEvent(.{ .message_update = .{
        .run_id = @enumFromInt(1),
        .turn_index = 1,
        .message = .{
            .parts = &.{.{ .text = "answer" }},
            .identity = .{ .provider = "script", .model = "render" },
        },
        .update = .{ .part_delta = .{ .index = 0, .delta = .{ .text = "answer" } } },
    } });
    try renderer.renderEvent(.{ .message_end = .{
        .run_id = @enumFromInt(1),
        .turn_index = 1,
        .message = .{ .published = .{ .response = .{
            .parts = &.{.{ .text = .{ .text = "answer" } }},
            .identity = .{ .provider = "script", .model = "render" },
        } } },
    } });
    try renderer.redrawPrompt(&editor);

    try std.testing.expectEqualStrings("> hello\nanswer\n\r\x1b[2K> next", output.written());
}

test "renderer prevents provider terminal escape injection" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeSafeText(&output.writer, "safe\x1b[2J\rtext\u{009b}tail", true);
    try std.testing.expectEqualStrings("safe�[2J�text�tail", output.written());
    try std.testing.expect(std.mem.find(u8, output.written(), "\x1b") == null);
}
