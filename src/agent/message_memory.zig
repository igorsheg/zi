const std = @import("std");
const ai = @import("../ai/root.zig");
const json_util = @import("../ai/json_util.zig");
const protocol = @import("types.zig");
const json_value = @import("../json/value.zig");

pub fn cloneMessages(allocator: std.mem.Allocator, messages: []const protocol.AgentMessage) ![]protocol.AgentMessage {
    const cloned = try allocator.alloc(protocol.AgentMessage, messages.len);
    var initialized: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < initialized) : (i += 1) {
            freeMessage(allocator, &cloned[i]);
        }
        allocator.free(cloned);
    }

    for (messages, 0..) |message, i| {
        cloned[i] = try cloneMessage(allocator, message);
        initialized += 1;
    }
    return cloned;
}

pub fn freeMessages(allocator: std.mem.Allocator, messages: []protocol.AgentMessage) void {
    for (messages) |*message| {
        freeMessage(allocator, message);
    }
    allocator.free(messages);
}

pub fn cloneMessage(allocator: std.mem.Allocator, message: protocol.AgentMessage) !protocol.AgentMessage {
    return switch (message) {
        .user => |user| .{ .user = try cloneUserMessage(allocator, user) },
        .assistant => |assistant| .{ .assistant = try cloneAssistantMessage(allocator, assistant) },
        .tool_result => |tool_result| .{ .tool_result = try cloneToolResultMessage(allocator, tool_result) },
        .compaction_summary => |summary| .{ .compaction_summary = try cloneCompactionSummaryMessage(allocator, summary) },
        .branch_summary => |summary| .{ .branch_summary = try cloneBranchSummaryMessage(allocator, summary) },
        .custom => |custom| .{ .custom = try cloneCustomMessage(allocator, custom) },
    };
}

pub fn cloneUserContent(
    allocator: std.mem.Allocator,
    content: ai.protocol.UserMessage.UserMessageContent,
) !ai.protocol.UserMessage.UserMessageContent {
    return switch (content) {
        .text => |text| .{ .text = try allocator.dupe(u8, text) },
        .blocks => |blocks| .{ .blocks = try cloneUserBlocks(allocator, blocks) },
    };
}

pub fn freeUserContent(
    allocator: std.mem.Allocator,
    content: *ai.protocol.UserMessage.UserMessageContent,
) void {
    switch (content.*) {
        .text => |text| allocator.free(text),
        .blocks => |blocks| {
            for (blocks) |block| freeUserBlock(allocator, block);
            allocator.free(blocks);
        },
    }
}

pub fn freeMessage(allocator: std.mem.Allocator, message: *protocol.AgentMessage) void {
    switch (message.*) {
        .user => |*user| freeUserMessage(allocator, user),
        .assistant => |*assistant| freeAssistantMessage(allocator, assistant),
        .tool_result => |*tool_result| freeToolResultMessage(allocator, tool_result),
        .compaction_summary => |*summary| allocator.free(summary.summary),
        .branch_summary => |*summary| {
            allocator.free(summary.summary);
            allocator.free(summary.from_id);
        },
        .custom => |*custom| freeCustomMessage(allocator, custom),
    }
}

fn cloneCompactionSummaryMessage(
    allocator: std.mem.Allocator,
    summary: protocol.AgentMessage.CompactionSummaryMessage,
) !protocol.AgentMessage.CompactionSummaryMessage {
    return .{
        .summary = try allocator.dupe(u8, summary.summary),
        .tokens_before = summary.tokens_before,
        .timestamp = summary.timestamp,
    };
}

fn cloneBranchSummaryMessage(
    allocator: std.mem.Allocator,
    summary: protocol.AgentMessage.BranchSummaryMessage,
) !protocol.AgentMessage.BranchSummaryMessage {
    const summary_text = try allocator.dupe(u8, summary.summary);
    errdefer allocator.free(summary_text);
    const from_id = try allocator.dupe(u8, summary.from_id);
    return .{
        .summary = summary_text,
        .from_id = from_id,
        .timestamp = summary.timestamp,
    };
}

pub fn cloneTextContent(allocator: std.mem.Allocator, text: ai.protocol.TextContent) !ai.protocol.TextContent {
    const text_copy = try allocator.dupe(u8, text.text);
    errdefer allocator.free(text_copy);
    const signature_copy = if (text.text_signature) |signature| try allocator.dupe(u8, signature) else null;
    return .{
        .text = text_copy,
        .text_signature = signature_copy,
    };
}

pub fn freeTextContent(allocator: std.mem.Allocator, text: ai.protocol.TextContent) void {
    allocator.free(text.text);
    if (text.text_signature) |signature| allocator.free(signature);
}

pub fn cloneThinkingContent(allocator: std.mem.Allocator, thinking: ai.protocol.ThinkingContent) !ai.protocol.ThinkingContent {
    const thinking_copy = try allocator.dupe(u8, thinking.thinking);
    errdefer allocator.free(thinking_copy);
    const signature_copy = if (thinking.thinking_signature) |signature| try allocator.dupe(u8, signature) else null;
    return .{
        .thinking = thinking_copy,
        .thinking_signature = signature_copy,
        .redacted = thinking.redacted,
    };
}

pub fn freeThinkingContent(allocator: std.mem.Allocator, thinking: ai.protocol.ThinkingContent) void {
    allocator.free(thinking.thinking);
    if (thinking.thinking_signature) |signature| allocator.free(signature);
}

pub fn cloneImageContent(allocator: std.mem.Allocator, image: ai.protocol.ImageContent) !ai.protocol.ImageContent {
    const data = try allocator.dupe(u8, image.data);
    errdefer allocator.free(data);
    const mime_type = try allocator.dupe(u8, image.mime_type);
    return .{
        .data = data,
        .mime_type = mime_type,
    };
}

pub fn freeImageContent(allocator: std.mem.Allocator, image: ai.protocol.ImageContent) void {
    allocator.free(image.data);
    allocator.free(image.mime_type);
}

pub fn cloneToolCall(allocator: std.mem.Allocator, tool_call: ai.protocol.ToolCall) !ai.protocol.ToolCall {
    const id = try allocator.dupe(u8, tool_call.id);
    errdefer allocator.free(id);
    const name = try allocator.dupe(u8, tool_call.name);
    errdefer allocator.free(name);
    const arguments = try json_value.cloneJsonValue(allocator, tool_call.arguments);
    errdefer json_value.freeJsonValue(allocator, arguments);
    const thought_signature = if (tool_call.thought_signature) |signature| try allocator.dupe(u8, signature) else null;
    return .{
        .id = id,
        .name = name,
        .arguments = arguments,
        .thought_signature = thought_signature,
    };
}

pub fn freeToolCall(allocator: std.mem.Allocator, tool_call: ai.protocol.ToolCall) void {
    allocator.free(tool_call.id);
    allocator.free(tool_call.name);
    json_value.freeJsonValue(allocator, tool_call.arguments);
    if (tool_call.thought_signature) |signature| allocator.free(signature);
}

fn cloneUserBlocks(
    allocator: std.mem.Allocator,
    blocks: []const ai.protocol.UserMessage.UserMessageContent.Block,
) ![]ai.protocol.UserMessage.UserMessageContent.Block {
    const cloned = try allocator.alloc(ai.protocol.UserMessage.UserMessageContent.Block, blocks.len);
    var initialized: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < initialized) : (i += 1) {
            freeUserBlock(allocator, cloned[i]);
        }
        allocator.free(cloned);
    }

    for (blocks, 0..) |block, i| {
        cloned[i] = switch (block) {
            .text => |text| .{ .text = try cloneTextContent(allocator, text) },
            .image => |image| .{ .image = try cloneImageContent(allocator, image) },
        };
        initialized += 1;
    }
    return cloned;
}

pub fn freeUserBlock(allocator: std.mem.Allocator, block: ai.protocol.UserMessage.UserMessageContent.Block) void {
    switch (block) {
        .text => |text| freeTextContent(allocator, text),
        .image => |image| freeImageContent(allocator, image),
    }
}

pub fn cloneUserMessage(allocator: std.mem.Allocator, message: ai.protocol.UserMessage) !ai.protocol.UserMessage {
    return .{
        .content = try cloneUserContent(allocator, message.content),
        .timestamp = message.timestamp,
    };
}

pub fn freeUserMessage(allocator: std.mem.Allocator, message: *ai.protocol.UserMessage) void {
    freeUserContent(allocator, &message.content);
}

fn cloneFailure(allocator: std.mem.Allocator, failure: ai.protocol.NormalizedFailure) !ai.protocol.NormalizedFailure {
    const provider_code = if (failure.provider_code) |code| try allocator.dupe(u8, code) else null;
    errdefer if (provider_code) |code| allocator.free(code);
    const provider_type = if (failure.provider_type) |value| try allocator.dupe(u8, value) else null;
    return .{
        .kind = failure.kind,
        .http_status = failure.http_status,
        .provider_code = provider_code,
        .provider_type = provider_type,
        .retry_after_ms = failure.retry_after_ms,
    };
}

fn freeFailure(allocator: std.mem.Allocator, failure: ai.protocol.NormalizedFailure) void {
    if (failure.provider_code) |code| allocator.free(code);
    if (failure.provider_type) |provider_type| allocator.free(provider_type);
}

fn cloneApi(allocator: std.mem.Allocator, api: ai.protocol.Api) !ai.protocol.Api {
    return switch (api) {
        .custom => |value| .{ .custom = try allocator.dupe(u8, value) },
        else => api,
    };
}

fn freeApi(allocator: std.mem.Allocator, api: *ai.protocol.Api) void {
    switch (api.*) {
        .custom => |value| allocator.free(value),
        else => {},
    }
}

fn cloneProvider(allocator: std.mem.Allocator, provider: ai.protocol.Provider) !ai.protocol.Provider {
    return switch (provider) {
        .custom => |value| .{ .custom = try allocator.dupe(u8, value) },
        else => provider,
    };
}

fn freeProvider(allocator: std.mem.Allocator, provider: *ai.protocol.Provider) void {
    switch (provider.*) {
        .custom => |value| allocator.free(value),
        else => {},
    }
}

pub fn cloneAssistantMessage(allocator: std.mem.Allocator, message: ai.protocol.AssistantMessage) !ai.protocol.AssistantMessage {
    const content = try allocator.alloc(ai.protocol.AssistantMessage.AssistantContentBlock, message.content.len);
    var initialized: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < initialized) : (i += 1) {
            freeAssistantContentBlock(allocator, content[i]);
        }
        allocator.free(content);
    }

    for (message.content, 0..) |block, i| {
        content[i] = switch (block) {
            .text => |text| .{ .text = try cloneTextContent(allocator, text) },
            .thinking => |thinking| .{ .thinking = try cloneThinkingContent(allocator, thinking) },
            .tool_call => |tool_call| .{ .tool_call = try cloneToolCall(allocator, tool_call) },
        };
        initialized += 1;
    }

    var api = try cloneApi(allocator, message.api);
    errdefer freeApi(allocator, &api);
    var provider = try cloneProvider(allocator, message.provider);
    errdefer freeProvider(allocator, &provider);
    const model = try allocator.dupe(u8, message.model);
    errdefer allocator.free(model);
    const response_id = if (message.response_id) |response_id| try allocator.dupe(u8, response_id) else null;
    errdefer if (response_id) |value| allocator.free(value);
    const error_message = if (message.error_message) |error_message| try allocator.dupe(u8, error_message) else null;
    errdefer if (error_message) |value| allocator.free(value);
    const failure = if (message.failure) |value| try cloneFailure(allocator, value) else null;
    errdefer if (failure) |value| freeFailure(allocator, value);

    return .{
        .content = content,
        .api = api,
        .provider = provider,
        .model = model,
        .response_id = response_id,
        .usage = message.usage,
        .stop_reason = message.stop_reason,
        .error_message = error_message,
        .failure = failure,
        .timestamp = message.timestamp,
    };
}

pub fn freeAssistantContentBlock(allocator: std.mem.Allocator, block: ai.protocol.AssistantMessage.AssistantContentBlock) void {
    switch (block) {
        .text => |text| freeTextContent(allocator, text),
        .thinking => |thinking| freeThinkingContent(allocator, thinking),
        .tool_call => |tool_call| freeToolCall(allocator, tool_call),
    }
}

pub fn freeAssistantMessage(allocator: std.mem.Allocator, message: *ai.protocol.AssistantMessage) void {
    for (message.content) |block| freeAssistantContentBlock(allocator, block);
    allocator.free(message.content);
    freeApi(allocator, &message.api);
    freeProvider(allocator, &message.provider);
    allocator.free(message.model);
    if (message.response_id) |response_id| allocator.free(response_id);
    if (message.error_message) |error_message| allocator.free(error_message);
    if (message.failure) |failure| freeFailure(allocator, failure);
}

pub fn cloneToolResultMessage(allocator: std.mem.Allocator, message: ai.protocol.ToolResultMessage) !ai.protocol.ToolResultMessage {
    const content = try allocator.alloc(ai.protocol.ToolResultMessage.ContentBlock, message.content.len);
    var initialized: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < initialized) : (i += 1) {
            freeToolResultContentBlock(allocator, content[i]);
        }
        allocator.free(content);
    }

    for (message.content, 0..) |block, i| {
        content[i] = switch (block) {
            .text => |text| .{ .text = try cloneTextContent(allocator, text) },
            .image => |image| .{ .image = try cloneImageContent(allocator, image) },
        };
        initialized += 1;
    }

    const tool_call_id = try allocator.dupe(u8, message.tool_call_id);
    errdefer allocator.free(tool_call_id);
    const tool_name = try allocator.dupe(u8, message.tool_name);
    errdefer allocator.free(tool_name);
    const details = if (message.details) |details| try json_value.cloneJsonValue(allocator, details) else null;
    errdefer if (details) |value| json_value.freeJsonValue(allocator, value);
    const presentation = if (message.presentation) |presentation| try json_value.cloneJsonValue(allocator, presentation) else null;
    errdefer if (presentation) |value| json_value.freeJsonValue(allocator, value);

    return .{
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .content = content,
        .details = details,
        .presentation = presentation,
        .is_error = message.is_error,
        .timestamp = message.timestamp,
    };
}

pub fn freeToolResultContentBlock(allocator: std.mem.Allocator, block: ai.protocol.ToolResultMessage.ContentBlock) void {
    switch (block) {
        .text => |text| freeTextContent(allocator, text),
        .image => |image| freeImageContent(allocator, image),
    }
}

pub fn freeToolResultMessage(allocator: std.mem.Allocator, message: *ai.protocol.ToolResultMessage) void {
    allocator.free(message.tool_call_id);
    allocator.free(message.tool_name);
    for (message.content) |block| freeToolResultContentBlock(allocator, block);
    allocator.free(message.content);
    if (message.details) |details| json_value.freeJsonValue(allocator, details);
    if (message.presentation) |presentation| json_value.freeJsonValue(allocator, presentation);
}

fn cloneCustomMessage(allocator: std.mem.Allocator, message: protocol.AgentMessage.CustomMessage) !protocol.AgentMessage.CustomMessage {
    const custom_type = try allocator.dupe(u8, message.custom_type);
    errdefer allocator.free(custom_type);
    const content: protocol.AgentMessage.CustomContent = switch (message.content) {
        .text => |text| .{ .text = try allocator.dupe(u8, text) },
        .blocks => |blocks| .{ .blocks = try cloneUserBlocks(allocator, blocks) },
    };
    errdefer switch (content) {
        .text => |text| allocator.free(text),
        .blocks => |blocks| {
            for (blocks) |block| freeUserBlock(allocator, block);
            allocator.free(blocks);
        },
    };
    const details = if (message.details) |details| try json_value.cloneJsonValue(allocator, details) else null;
    return .{
        .custom_type = custom_type,
        .content = content,
        .display = message.display,
        .details = details,
        .timestamp = message.timestamp,
    };
}

pub fn freeCustomContent(allocator: std.mem.Allocator, content: protocol.AgentMessage.CustomContent) void {
    switch (content) {
        .text => |text| allocator.free(text),
        .blocks => |blocks| {
            for (blocks) |block| freeUserBlock(allocator, block);
            allocator.free(blocks);
        },
    }
}

fn freeCustomMessage(allocator: std.mem.Allocator, message: *protocol.AgentMessage.CustomMessage) void {
    allocator.free(message.custom_type);
    freeCustomContent(allocator, message.content);
    if (message.details) |details| json_value.freeJsonValue(allocator, details);
}
