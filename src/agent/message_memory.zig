const std = @import("std");
const ai = @import("../ai/root.zig");
const json_value = @import("../json/value.zig");
const message = @import("message.zig");

pub fn cloneMessage(allocator: std.mem.Allocator, value: message.AgentMessage) !message.AgentMessage {
    return switch (value) {
        .user => |user| .{ .user = try cloneUser(allocator, user) },
        .assistant => |assistant| .{ .assistant = try cloneAssistant(allocator, assistant) },
        .tool_result => |tool_result| .{ .tool_result = try cloneToolResult(allocator, tool_result) },
        .compaction_summary => |summary| .{ .compaction_summary = .{ .summary = try allocator.dupe(u8, summary.summary), .tokens_before = summary.tokens_before, .timestamp = summary.timestamp } },
        .branch_summary => |summary| .{ .branch_summary = .{ .summary = try allocator.dupe(u8, summary.summary), .from_id = try allocator.dupe(u8, summary.from_id), .timestamp = summary.timestamp } },
        .custom => |custom| .{ .custom = try cloneCustom(allocator, custom) },
    };
}

pub fn cloneMessages(allocator: std.mem.Allocator, messages: []const message.AgentMessage) ![]const message.AgentMessage {
    const out = try allocator.alloc(message.AgentMessage, messages.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |msg| freeMessage(allocator, msg);
        allocator.free(out);
    }
    for (messages, 0..) |msg, i| {
        out[i] = try cloneMessage(allocator, msg);
        initialized += 1;
    }
    return out;
}

pub fn cloneUser(allocator: std.mem.Allocator, value: ai.protocol.UserMessage) !ai.protocol.UserMessage {
    return .{ .content = try cloneUserContent(allocator, value.content), .timestamp = value.timestamp };
}

pub fn cloneAssistant(allocator: std.mem.Allocator, value: message.AssistantMessage) !message.AssistantMessage {
    const model = try allocator.dupe(u8, value.model);
    errdefer allocator.free(model);

    const response_id = if (value.response_id) |id| try allocator.dupe(u8, id) else null;
    errdefer if (response_id) |id| allocator.free(id);

    const error_message = if (value.error_message) |msg| try allocator.dupe(u8, msg) else null;
    errdefer if (error_message) |msg| allocator.free(msg);

    const content = try allocator.alloc(ai.protocol.AssistantMessage.AssistantContentBlock, value.content.len);
    var initialized: usize = 0;
    errdefer {
        for (content[0..initialized]) |block| freeAssistantBlock(allocator, block);
        allocator.free(content);
    }
    for (value.content, 0..) |block, i| {
        content[i] = try cloneAssistantBlock(allocator, block);
        initialized += 1;
    }
    return .{
        .content = content,
        .api = value.api,
        .provider = value.provider,
        .model = model,
        .response_id = response_id,
        .usage = value.usage,
        .stop_reason = value.stop_reason,
        .error_message = error_message,
        .failure = value.failure,
        .timestamp = value.timestamp,
    };
}

pub fn freeAssistant(allocator: std.mem.Allocator, value: message.AssistantMessage) void {
    for (value.content) |block| freeAssistantBlock(allocator, block);
    allocator.free(value.content);
    allocator.free(value.model);
    if (value.response_id) |id| allocator.free(id);
    if (value.error_message) |msg| allocator.free(msg);
}

pub fn freeMessage(allocator: std.mem.Allocator, value: message.AgentMessage) void {
    switch (value) {
        .assistant => |assistant| freeAssistant(allocator, assistant),
        .tool_result => |tool_result| freeToolResult(allocator, tool_result),
        .user => |user| freeUser(allocator, user),
        .compaction_summary => |summary| allocator.free(summary.summary),
        .branch_summary => |summary| {
            allocator.free(summary.summary);
            allocator.free(summary.from_id);
        },
        .custom => |custom| freeCustom(allocator, custom),
    }
}

pub fn freeUser(allocator: std.mem.Allocator, value: ai.protocol.UserMessage) void {
    freeUserContent(allocator, value.content);
}

pub fn freeToolResult(allocator: std.mem.Allocator, value: message.ToolResultMessage) void {
    for (value.content) |block| switch (block) {
        .text => |text| {
            allocator.free(text.text);
            if (text.text_signature) |sig| allocator.free(sig);
        },
        .image => |image| {
            allocator.free(image.data);
            allocator.free(image.mime_type);
        },
    };
    allocator.free(value.content);
    if (value.details) |details| {
        var d = details;
        d.deinit();
    }
    if (value.presentation) |presentation| {
        var p = presentation;
        p.deinit();
    }
    allocator.free(value.tool_call_id);
    allocator.free(value.tool_name);
}

pub fn cloneToolResult(allocator: std.mem.Allocator, value: message.ToolResultMessage) !message.ToolResultMessage {
    const tool_call_id = try allocator.dupe(u8, value.tool_call_id);
    errdefer allocator.free(tool_call_id);

    const tool_name = try allocator.dupe(u8, value.tool_name);
    errdefer allocator.free(tool_name);

    const details = if (value.details) |d| try json_value.OwnedValue.clone(allocator, d.borrowed()) else null;
    errdefer if (details) |d| {
        var owned = d;
        owned.deinit();
    };

    const presentation = if (value.presentation) |p| try json_value.OwnedValue.clone(allocator, p.borrowed()) else null;
    errdefer if (presentation) |p| {
        var owned = p;
        owned.deinit();
    };

    const content = try allocator.alloc(ai.protocol.ToolResultMessage.ContentBlock, value.content.len);
    var initialized: usize = 0;
    errdefer {
        for (content[0..initialized]) |block| switch (block) {
            .text => |text| {
                allocator.free(text.text);
                if (text.text_signature) |sig| allocator.free(sig);
            },
            .image => |image| {
                allocator.free(image.data);
                allocator.free(image.mime_type);
            },
        };
        allocator.free(content);
    }
    for (value.content, 0..) |block, i| {
        content[i] = try cloneToolResultBlock(allocator, block);
        initialized += 1;
    }
    return .{
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .content = content,
        .details = details,
        .presentation = presentation,
        .is_error = value.is_error,
        .timestamp = value.timestamp,
    };
}

fn cloneAssistantBlock(allocator: std.mem.Allocator, block: ai.protocol.AssistantMessage.AssistantContentBlock) !ai.protocol.AssistantMessage.AssistantContentBlock {
    return switch (block) {
        .text => |text| blk: {
            const owned_text = try allocator.dupe(u8, text.text);
            errdefer allocator.free(owned_text);
            const sig = if (text.text_signature) |s| try allocator.dupe(u8, s) else null;
            break :blk .{ .text = .{ .text = owned_text, .text_signature = sig } };
        },
        .thinking => |thinking| blk: {
            const owned_thinking = try allocator.dupe(u8, thinking.thinking);
            errdefer allocator.free(owned_thinking);
            const sig = if (thinking.thinking_signature) |s| try allocator.dupe(u8, s) else null;
            break :blk .{ .thinking = .{ .thinking = owned_thinking, .thinking_signature = sig, .redacted = thinking.redacted } };
        },
        .tool_call => |call| blk: {
            const id = try allocator.dupe(u8, call.id);
            errdefer allocator.free(id);
            const name = try allocator.dupe(u8, call.name);
            errdefer allocator.free(name);
            const sig = if (call.thought_signature) |s| try allocator.dupe(u8, s) else null;
            errdefer if (sig) |owned| allocator.free(owned);
            const arguments = try json_value.OwnedValue.clone(allocator, call.arguments.borrowed());
            break :blk .{ .tool_call = .{ .id = id, .name = name, .thought_signature = sig, .arguments = arguments } };
        },
    };
}

fn cloneUserContent(allocator: std.mem.Allocator, content: ai.protocol.UserMessage.UserMessageContent) !ai.protocol.UserMessage.UserMessageContent {
    return switch (content) {
        .text => |text| .{ .text = try allocator.dupe(u8, text) },
        .blocks => |blocks| blk: {
            const out = try allocator.alloc(ai.protocol.UserMessage.UserMessageContent.Block, blocks.len);
            var initialized: usize = 0;
            errdefer {
                for (out[0..initialized]) |block| freeUserBlock(allocator, block);
                allocator.free(out);
            }
            for (blocks, 0..) |block, i| {
                out[i] = try cloneUserBlock(allocator, block);
                initialized += 1;
            }
            break :blk .{ .blocks = out };
        },
    };
}

fn freeUserContent(allocator: std.mem.Allocator, content: ai.protocol.UserMessage.UserMessageContent) void {
    switch (content) {
        .text => |text| allocator.free(text),
        .blocks => |blocks| {
            for (blocks) |block| freeUserBlock(allocator, block);
            allocator.free(blocks);
        },
    }
}

fn cloneUserBlock(allocator: std.mem.Allocator, block: ai.protocol.UserMessage.UserMessageContent.Block) !ai.protocol.UserMessage.UserMessageContent.Block {
    return switch (block) {
        .text => |text| blk: {
            const owned_text = try allocator.dupe(u8, text.text);
            errdefer allocator.free(owned_text);
            const sig = if (text.text_signature) |s| try allocator.dupe(u8, s) else null;
            break :blk .{ .text = .{ .text = owned_text, .text_signature = sig } };
        },
        .image => |image| blk: {
            const data = try allocator.dupe(u8, image.data);
            errdefer allocator.free(data);
            const mime_type = try allocator.dupe(u8, image.mime_type);
            break :blk .{ .image = .{ .data = data, .mime_type = mime_type } };
        },
    };
}

fn cloneToolResultBlock(allocator: std.mem.Allocator, block: ai.protocol.ToolResultMessage.ContentBlock) !ai.protocol.ToolResultMessage.ContentBlock {
    return switch (block) {
        .text => |text| blk: {
            const owned_text = try allocator.dupe(u8, text.text);
            errdefer allocator.free(owned_text);
            const sig = if (text.text_signature) |s| try allocator.dupe(u8, s) else null;
            break :blk .{ .text = .{ .text = owned_text, .text_signature = sig } };
        },
        .image => |image| blk: {
            const data = try allocator.dupe(u8, image.data);
            errdefer allocator.free(data);
            const mime_type = try allocator.dupe(u8, image.mime_type);
            break :blk .{ .image = .{ .data = data, .mime_type = mime_type } };
        },
    };
}

fn freeUserBlock(allocator: std.mem.Allocator, block: ai.protocol.UserMessage.UserMessageContent.Block) void {
    switch (block) {
        .text => |text| {
            allocator.free(text.text);
            if (text.text_signature) |sig| allocator.free(sig);
        },
        .image => |image| {
            allocator.free(image.data);
            allocator.free(image.mime_type);
        },
    }
}

fn cloneCustom(allocator: std.mem.Allocator, value: message.AgentMessage.Custom) !message.AgentMessage.Custom {
    const custom_type = try allocator.dupe(u8, value.custom_type);
    errdefer allocator.free(custom_type);

    const content: message.AgentMessage.CustomContent = switch (value.content) {
            .text => |text| .{ .text = try allocator.dupe(u8, text) },
            .blocks => |blocks| blk: {
                const out = try allocator.alloc(ai.protocol.UserMessage.UserMessageContent.Block, blocks.len);
                var initialized: usize = 0;
                errdefer {
                    for (out[0..initialized]) |block| freeUserBlock(allocator, block);
                    allocator.free(out);
                }
                for (blocks, 0..) |block, i| {
                    out[i] = try cloneUserBlock(allocator, block);
                    initialized += 1;
                }
                break :blk .{ .blocks = out };
            },
    };
    errdefer switch (content) {
        .text => |text| allocator.free(text),
        .blocks => |blocks| {
            for (blocks) |block| freeUserBlock(allocator, block);
            allocator.free(blocks);
        },
    };

    const details = if (value.details) |d| try json_value.OwnedValue.clone(allocator, d.borrowed()) else null;
    errdefer if (details) |d| {
        var owned = d;
        owned.deinit();
    };

    return .{
        .custom_type = custom_type,
        .content = content,
        .display = value.display,
        .details = details,
        .timestamp = value.timestamp,
    };
}

fn freeCustom(allocator: std.mem.Allocator, value: message.AgentMessage.Custom) void {
    allocator.free(value.custom_type);
    switch (value.content) {
        .text => |text| allocator.free(text),
        .blocks => |blocks| {
            for (blocks) |block| freeUserBlock(allocator, block);
            allocator.free(blocks);
        },
    }
    if (value.details) |details| {
        var d = details;
        d.deinit();
    }
}

fn freeAssistantBlock(allocator: std.mem.Allocator, block: ai.protocol.AssistantMessage.AssistantContentBlock) void {
    switch (block) {
        .text => |text| {
            allocator.free(text.text);
            if (text.text_signature) |sig| allocator.free(sig);
        },
        .thinking => |thinking| {
            allocator.free(thinking.thinking);
            if (thinking.thinking_signature) |sig| allocator.free(sig);
        },
        .tool_call => |call| {
            allocator.free(call.id);
            allocator.free(call.name);
            if (call.thought_signature) |sig| allocator.free(sig);
            var args = call.arguments;
            args.deinit();
        },
    }
}
