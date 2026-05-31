const std = @import("std");

const agent = @import("../../agent/root.zig");
const ai = @import("../../ai/root.zig");
const AgentSession = @import("../../coding_agent/AgentSession.zig");

const app_mod = @import("app.zig");

pub fn applyAgentSessionEvent(
    allocator: std.mem.Allocator,
    app: *app_mod.App,
    event: AgentSession.AgentSessionEvent,
) !void {
    switch (event) {
        .agent_event => |agent_event| try applyAgentEvent(allocator, app, agent_event),
        else => {},
    }
}

fn applyAgentEvent(allocator: std.mem.Allocator, app: *app_mod.App, event: agent.AgentEvent) !void {
    switch (event) {
        .message_end => |payload| try appendMessage(allocator, app, payload.message),
        .message_update => |payload| try appendAssistantEvent(app, payload.assistant_message_event),
        .tool_execution_start => |payload| {
            try app.dispatch(.{ .append_transcript_text = .{
                .kind = .tool_call,
                .durability = .ephemeral,
                .text = payload.tool_name,
            } });
        },
        else => {},
    }
}

fn appendMessage(allocator: std.mem.Allocator, app: *app_mod.App, message: agent.AgentMessage) !void {
    switch (message) {
        .user => |user| switch (user.content) {
            .string => |text| {
                try app.dispatch(.{ .append_transcript_text = .{
                    .kind = .user_message,
                    .durability = .persistent,
                    .text = text,
                } });
            },
            .blocks => {},
        },
        .assistant => |assistant| try appendAssistantMessageEnd(app, assistant),
        .tool_result => |tool_result| try appendToolResultMessage(allocator, app, tool_result),
        else => {},
    }
}

fn appendToolResultMessage(
    allocator: std.mem.Allocator,
    app: *app_mod.App,
    message: ai.ToolResultMessage,
) !void {
    if (!message.is_error) return;
    const text = firstToolResultText(message.content) orelse return;
    const rendered = try std.fmt.allocPrint(
        allocator,
        "{s} error: {s}",
        .{ message.tool_name, text },
    );
    defer allocator.free(rendered);

    try app.dispatch(.{ .append_transcript_text = .{
        .kind = .tool_call,
        .durability = .ephemeral,
        .text = rendered,
    } });
}

fn appendAssistantEvent(app: *app_mod.App, event: ai.AssistantMessageEvent) !void {
    switch (event) {
        .text_delta => |payload| try app.dispatch(.{ .assistant_delta = payload.delta }),
        .text_end => {
            // Keep the active item until message_end. Some providers emit only
            // final text at message_end, and streamed providers may need a
            // final suffix reconciliation.
        },
        else => {},
    }
}

fn appendAssistantMessageEnd(app: *app_mod.App, assistant: ai.AssistantMessage) !void {
    if (assistant.error_message) |message| {
        try app.dispatch(.{ .assistant_final_text = message });
    }
    for (assistant.content) |content| {
        if (content != .text) continue;
        try app.dispatch(.{ .assistant_final_text = content.text.text });
    }
    try app.dispatch(.assistant_end);
}

fn firstToolResultText(content: []const ai.ToolResultContent) ?[]const u8 {
    for (content) |item| switch (item) {
        .text => |text| return text.text,
        .image => {},
    };
    return null;
}
