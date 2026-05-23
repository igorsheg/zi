const std = @import("std");
const ai = @import("../ai/root.zig");
const json_value = @import("../json/value.zig");
const message = @import("message.zig");
const message_memory = @import("message_memory.zig");
const llm_messages = @import("llm_messages.zig");
const config = @import("config.zig");

pub const Backend = struct {
    prompt: []const u8,

    pub fn runBackend(self: *Backend, io: std.Io) config.RunBackend {
        return .{ .stream = .{ .call_fn = stream, .ctx = self }, .convert_messages = llm_messages.default_hook, .io = io }; // ziglint-ignore: Z024
    }

    fn stream(ctx: ?*anyopaque, allocator: std.mem.Allocator, model_value: message.Model, context: ai.protocol.Context, _: ai.protocol.SimpleStreamOptions, sink: ai.provider.StreamEventSink) error{OutOfMemory}!void { // ziglint-ignore: Z024, Z023
        const self: *@This() = @ptrCast(@alignCast(ctx.?)); // ziglint-ignore: Z020
        _ = model_value;
        if (lastToolResult(context)) |tool_result| {
            const text = if (tool_result.content.len > 0 and tool_result.content[0] == .text) tool_result.content[0].text.text else "tool completed"; // ziglint-ignore: Z024
            const assistant = try assistantText(allocator, text, .stop);
            defer message_memory.freeAssistant(allocator, assistant);
            sink.emit(.{ .done = .{ .reason = .stop, .message = assistant } });
            return;
        }
        if (std.mem.startsWith(u8, self.prompt, "bash:")) {
            const cmd = std.mem.trim(u8, self.prompt[5..], " \t");
            const assistant = try assistantToolCall(allocator, cmd);
            defer message_memory.freeAssistant(allocator, assistant);
            sink.emit(.{ .done = .{ .reason = .toolUse, .message = assistant } });
            return;
        }
        const assistant = try assistantText(allocator, "demo response", .stop);
        defer message_memory.freeAssistant(allocator, assistant);
        sink.emit(.{ .done = .{ .reason = .stop, .message = assistant } });
    }
};

pub fn model(id: []const u8) message.Model {
    return .{ .id = id, .name = id, .api = .openai_responses, .provider = .openai, .base_url = "", .reasoning = false, .input = &.{}, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 }, .context_window = 0, .max_tokens = 0 }; // ziglint-ignore: Z024
}

fn lastToolResult(context: ai.protocol.Context) ?ai.protocol.ToolResultMessage {
    if (context.messages.len == 0) return null;
    return switch (context.messages[context.messages.len - 1]) {
        .tool_result => |tool| tool,
        else => null,
    };
}

fn assistantText(allocator: std.mem.Allocator, text: []const u8, reason: ai.protocol.StopReason) !ai.protocol.AssistantMessage { // ziglint-ignore: Z024
    const blocks = try allocator.alloc(ai.protocol.AssistantMessage.AssistantContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try allocator.dupe(u8, text) } };
    return try baseAssistant(allocator, blocks, reason); // ziglint-ignore: Z017
}

fn assistantToolCall(allocator: std.mem.Allocator, cmd: []const u8) !ai.protocol.AssistantMessage {
    var args_obj: std.json.ObjectMap = .{};
    try args_obj.put(allocator, try allocator.dupe(u8, "cmd"), .{ .string = try allocator.dupe(u8, cmd) });
    const blocks = try allocator.alloc(ai.protocol.AssistantMessage.AssistantContentBlock, 1);
    blocks[0] = .{ .tool_call = .{ .id = try allocator.dupe(u8, "cli-bash-1"), .name = try allocator.dupe(u8, "bash"), .arguments = json_value.OwnedValue.adopt(allocator, .{ .object = args_obj }) } }; // ziglint-ignore: Z024
    return try baseAssistant(allocator, blocks, .toolUse); // ziglint-ignore: Z017
}

fn baseAssistant(allocator: std.mem.Allocator, blocks: []const ai.protocol.AssistantMessage.AssistantContentBlock, reason: ai.protocol.StopReason) !ai.protocol.AssistantMessage { // ziglint-ignore: Z024
    return .{ .content = blocks, .api = .openai_responses, .provider = .openai, .model = try allocator.dupe(u8, "demo"), .usage = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total_tokens = 0, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 } }, .stop_reason = reason, .timestamp = 0 }; // ziglint-ignore: Z024
}
