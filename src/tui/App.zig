const std = @import("std");

const agent = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const session_events = @import("../coding_agent/session_events.zig");
const composer_mod = @import("composer.zig");
const transcript_mod = @import("transcript.zig");

pub const App = @This();

allocator: std.mem.Allocator,
width: u16,
height: u16,
composer: composer_mod.Composer = .{},
transcript: transcript_mod.Transcript = .{},
transcript_view: transcript_mod.TranscriptView = .{},
status: Status = .idle,
dirty: bool = true,

pub const Status = enum {
    idle,
    running,
    cancel_requested,
    failed,
};

pub const Command = union(enum) {
    insert_text: []const u8,
    backspace,
    move_left,
    move_right,
    clear_composer,
    submit_composer,
    cancel_or_quit,
    scroll_up,
    scroll_down,
};

pub const Effect = union(enum) {
    none,
    quit,
    cancel,
    submit_prompt: []u8,

    pub fn deinit(self: Effect, allocator: std.mem.Allocator) void {
        switch (self) {
            .submit_prompt => |prompt| allocator.free(prompt),
            .none, .quit, .cancel => {},
        }
    }
};

pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) App {
    return .{
        .allocator = allocator,
        .width = width,
        .height = height,
    };
}

pub fn deinit(self: *App) void {
    self.composer.deinit(self.allocator);
    self.transcript.deinit(self.allocator);
    self.* = undefined;
}

pub fn apply(self: *App, command: Command) !Effect {
    switch (command) {
        .insert_text => |text| try self.composer.insert(self.allocator, text),
        .backspace => self.composer.backspace(),
        .move_left => self.composer.moveLeft(),
        .move_right => self.composer.moveRight(),
        .clear_composer => self.composer.clear(),
        .submit_composer => {
            const prompt = try self.composer.submit(self.allocator) orelse return .none;
            self.dirty = true;
            return .{ .submit_prompt = prompt };
        },
        .cancel_or_quit => return if (self.status == .running) .cancel else .quit,
        .scroll_up => self.transcript_view.scrollUp(&self.transcript, self.transcriptTextWidth()),
        .scroll_down => self.transcript_view.scrollDown(),
    }
    self.dirty = true;
    return .none;
}

pub fn resize(self: *App, width: u16, height: u16) void {
    self.width = @max(width, 1);
    self.height = @max(height, 1);
    self.dirty = true;
}

pub fn setStatus(self: *App, status: Status) void {
    if (self.status == status) return;
    self.status = status;
    self.dirty = true;
}

pub fn appendSystem(self: *App, text: []const u8) !void {
    _ = try self.transcript.append(self.allocator, .system, text);
    self.dirty = true;
}

pub fn applyAgentSessionEvent(self: *App, event: session_events.AgentSessionEvent) !void {
    switch (event) {
        .agent_event => |agent_event| try self.applyAgentEvent(agent_event),
        .prompt_command => |payload| try self.appendSystem(payload.message.text),
        else => {},
    }
}

pub fn applyAgentEvent(self: *App, event: agent.AgentEvent) !void {
    switch (event) {
        .message_end => |payload| try self.appendMessage(payload.message),
        .message_update => |payload| try self.appendAssistantEvent(payload.assistant_message_event),
        .tool_execution_start => |payload| {
            _ = try self.transcript.append(self.allocator, .tool, payload.tool_name);
            self.dirty = true;
        },
        else => {},
    }
}

pub fn isDirty(self: App) bool {
    return self.dirty;
}

pub fn syncViews(self: *App) void {
    self.transcript_view.sync(&self.transcript);
}

pub fn transcriptTextWidth(self: App) u16 {
    return self.width -| 2;
}

pub fn markClean(self: *App) void {
    self.dirty = false;
}

fn appendMessage(self: *App, message: agent.AgentMessage) !void {
    switch (message) {
        .user => |user| switch (user.content) {
            .string => |text| _ = try self.transcript.append(self.allocator, .user, text),
            .blocks => {},
        },
        .assistant => |assistant| try self.appendAssistantMessageEnd(assistant),
        .tool_result => |tool_result| try self.appendToolResult(tool_result),
        .custom => {},
    }
    self.dirty = true;
}

fn appendAssistantEvent(self: *App, event: ai.AssistantMessageEvent) !void {
    switch (event) {
        .text_delta => |payload| try self.transcript.appendAssistantDelta(self.allocator, payload.delta),
        .text_end => {},
        else => {},
    }
    self.dirty = true;
}

fn appendAssistantMessageEnd(self: *App, assistant: ai.AssistantMessage) !void {
    if (assistant.error_message) |message| try self.transcript.finishAssistant(self.allocator, message);
    for (assistant.content) |content| {
        if (content == .text) try self.transcript.finishAssistant(self.allocator, content.text.text);
    }
    self.transcript.endAssistant();
}

fn appendToolResult(self: *App, message: ai.ToolResultMessage) !void {
    if (!message.is_error) return;
    for (message.content) |content| switch (content) {
        .text => |text| {
            _ = try self.transcript.append(self.allocator, .tool, text.text);
            return;
        },
        .image => {},
    };
}

test "submit returns owned prompt and clears composer" {
    var app = App.init(std.testing.allocator, 80, 24);
    defer app.deinit();

    _ = try app.apply(.{ .insert_text = "hello" });
    const effect = try app.apply(.submit_composer);
    defer effect.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("hello", effect.submit_prompt);
    try std.testing.expectEqual(@as(usize, 0), app.composer.bytes.items.len);
}

test "prompt command event appends system transcript item" {
    var app = App.init(std.testing.allocator, 80, 24);
    defer app.deinit();

    var event: session_events.AgentSessionEvent = .{ .prompt_command = .{
        .command = try session_events.EventText.init(std.testing.allocator, "missing"),
        .result = .unknown,
        .message = try session_events.EventText.init(std.testing.allocator, "unknown command: /missing"),
    } };
    defer event.deinit();

    try app.applyAgentSessionEvent(event);

    try std.testing.expectEqual(@as(usize, 1), app.transcript.count);
    try std.testing.expectEqual(transcript_mod.Transcript.Kind.system, app.transcript.items[0].kind);
    try std.testing.expectEqualStrings("unknown command: /missing", app.transcript.items[0].text);
}
