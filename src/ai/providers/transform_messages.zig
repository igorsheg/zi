const std = @import("std");
const protocol = @import("../protocol.zig");
const runtime = @import("../../runtime/root.zig");

const non_vision_user_image_placeholder = "(image omitted: model does not support images)";
const non_vision_tool_image_placeholder = "(tool image omitted: model does not support images)";
const synthetic_tool_result_text = "No result provided";

pub const NormalizeToolCallId = struct {
    context: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, []const u8, protocol.Model, protocol.AssistantMessage) anyerror![]const u8,

    fn call(
        self: NormalizeToolCallId,
        id: []const u8,
        model: protocol.Model,
        source: protocol.AssistantMessage,
    ) ![]const u8 {
        return self.call_fn(self.context, id, model, source);
    }
};

pub const TransformedMessages = struct {
    arena: std.heap.ArenaAllocator,
    messages: []const protocol.Message,

    pub fn deinit(self: *TransformedMessages) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn transformMessages(
    backing_allocator: std.mem.Allocator,
    messages: []const protocol.Message,
    model: protocol.Model,
    normalize_tool_call_id: ?NormalizeToolCallId,
) !TransformedMessages {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    var result: std.ArrayList(protocol.Message) = .empty;
    var tool_call_id_map = std.StringHashMap([]const u8).init(allocator);
    var pending_tool_calls: std.ArrayList(protocol.ToolCall) = .empty;
    var existing_tool_result_ids = std.StringHashMap(void).init(allocator);

    for (messages) |message| {
        const transformed = try transformMessage(
            allocator,
            message,
            model,
            normalize_tool_call_id,
            &tool_call_id_map,
        );

        switch (transformed) {
            .assistant => |assistant| {
                try insertSyntheticToolResults(allocator, &result, pending_tool_calls.items, &existing_tool_result_ids);
                pending_tool_calls.clearRetainingCapacity();
                existing_tool_result_ids.clearRetainingCapacity();

                if (assistant.stop_reason == .error_ or assistant.stop_reason == .aborted) continue;
                for (assistant.content) |block| {
                    if (block == .tool_call) try pending_tool_calls.append(allocator, block.tool_call);
                }
                try result.append(allocator, transformed);
            },
            .tool_result => |tool_result| {
                try existing_tool_result_ids.put(tool_result.tool_call_id, {});
                try result.append(allocator, transformed);
            },
            .user => {
                try insertSyntheticToolResults(allocator, &result, pending_tool_calls.items, &existing_tool_result_ids);
                pending_tool_calls.clearRetainingCapacity();
                existing_tool_result_ids.clearRetainingCapacity();
                try result.append(allocator, transformed);
            },
        }
    }

    try insertSyntheticToolResults(allocator, &result, pending_tool_calls.items, &existing_tool_result_ids);

    return .{ .arena = arena, .messages = try result.toOwnedSlice(allocator) };
}

fn transformMessage(
    allocator: std.mem.Allocator,
    message: protocol.Message,
    model: protocol.Model,
    normalize_tool_call_id: ?NormalizeToolCallId,
    tool_call_id_map: *std.StringHashMap([]const u8),
) !protocol.Message {
    return switch (message) {
        .user => |user| .{ .user = try transformUserMessageForModel(allocator, user, model) },
        .tool_result => |tool_result| .{ .tool_result = try transformToolResultMessageForModel(
            allocator,
            tool_result,
            model,
            tool_call_id_map.get(tool_result.tool_call_id),
        ) },
        .assistant => |assistant| .{ .assistant = try transformAssistantMessageForModel(
            allocator,
            assistant,
            model,
            normalize_tool_call_id,
            tool_call_id_map,
        ) },
    };
}

fn transformUserMessageForModel(
    allocator: std.mem.Allocator,
    source: protocol.UserMessage,
    model: protocol.Model,
) !protocol.UserMessage {
    return .{
        .content = switch (source.content) {
            .string => |text| .{ .string = try allocator.dupe(u8, text) },
            .blocks => |blocks| .{ .blocks = try transformUserContentSlice(allocator, blocks, supportsImages(model)) },
        },
        .timestamp = source.timestamp,
    };
}

fn transformToolResultMessageForModel(
    allocator: std.mem.Allocator,
    source: protocol.ToolResultMessage,
    model: protocol.Model,
    normalized_tool_call_id: ?[]const u8,
) !protocol.ToolResultMessage {
    return .{
        .tool_call_id = try allocator.dupe(u8, normalized_tool_call_id orelse source.tool_call_id),
        .tool_name = try allocator.dupe(u8, source.tool_name),
        .content = try transformToolResultContentSlice(allocator, source.content, supportsImages(model)),
        .details = if (source.details) |details| try runtime.cloneJsonValue(allocator, details) else null,
        .is_error = source.is_error,
        .timestamp = source.timestamp,
    };
}

fn transformAssistantMessageForModel(
    allocator: std.mem.Allocator,
    source: protocol.AssistantMessage,
    model: protocol.Model,
    normalize_tool_call_id: ?NormalizeToolCallId,
    tool_call_id_map: *std.StringHashMap([]const u8),
) !protocol.AssistantMessage {
    const same_model = std.mem.eql(u8, source.provider, model.provider) and
        std.mem.eql(u8, source.api, model.api) and
        std.mem.eql(u8, source.model, model.id);
    var content: std.ArrayList(protocol.AssistantContent) = .empty;

    for (source.content) |block| {
        switch (block) {
            .thinking => |thinking| {
                if (thinking.redacted and !same_model) continue;
                if (same_model and thinking.thinking_signature != null) {
                    try content.append(allocator, .{ .thinking = try copyThinkingContent(allocator, thinking) });
                } else if (std.mem.trim(u8, thinking.thinking, " \t\r\n").len == 0) {
                    continue;
                } else if (same_model) {
                    try content.append(allocator, .{ .thinking = try copyThinkingContent(allocator, thinking) });
                } else {
                    try content.append(allocator, .{ .text = .{ .text = try allocator.dupe(u8, thinking.thinking) } });
                }
            },
            .text => |text| try content.append(allocator, .{ .text = .{
                .text = try allocator.dupe(u8, text.text),
                .text_signature = if (same_model) try copyOptionalString(allocator, text.text_signature) else null,
            } }),
            .tool_call => |tool_call| {
                var transformed_tool_call = try copyToolCall(allocator, tool_call);
                if (!same_model) transformed_tool_call.thought_signature = null;
                if (!same_model) if (normalize_tool_call_id) |normalizer| {
                    const normalized = try normalizer.call(tool_call.id, model, source);
                    if (!std.mem.eql(u8, normalized, tool_call.id)) {
                        const owned_normalized = try allocator.dupe(u8, normalized);
                        try tool_call_id_map.put(transformed_tool_call.id, owned_normalized);
                        transformed_tool_call.id = owned_normalized;
                    }
                };
                try content.append(allocator, .{ .tool_call = transformed_tool_call });
            },
        }
    }

    return .{
        .content = try content.toOwnedSlice(allocator),
        .api = try allocator.dupe(u8, source.api),
        .provider = try allocator.dupe(u8, source.provider),
        .model = try allocator.dupe(u8, source.model),
        .response_id = try copyOptionalString(allocator, source.response_id),
        .usage = source.usage,
        .stop_reason = source.stop_reason,
        .error_message = try copyOptionalString(allocator, source.error_message),
        .timestamp = source.timestamp,
    };
}

fn insertSyntheticToolResults(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(protocol.Message),
    pending_tool_calls: []const protocol.ToolCall,
    existing_tool_result_ids: *const std.StringHashMap(void),
) !void {
    for (pending_tool_calls) |tool_call| {
        if (existing_tool_result_ids.contains(tool_call.id)) continue;
        const content = try allocator.alloc(protocol.ToolResultContent, 1);
        content[0] = .{ .text = .{ .text = synthetic_tool_result_text } };
        try result.append(allocator, .{ .tool_result = .{
            .tool_call_id = try allocator.dupe(u8, tool_call.id),
            .tool_name = try allocator.dupe(u8, tool_call.name),
            .content = content,
            .is_error = true,
            .timestamp = 0,
        } });
    }
}

fn transformUserContentSlice(
    allocator: std.mem.Allocator,
    source: []const protocol.UserContent,
    keep_images: bool,
) ![]const protocol.UserContent {
    var result: std.ArrayList(protocol.UserContent) = .empty;
    var previous_was_placeholder = false;
    for (source) |block| switch (block) {
        .image => |image| {
            if (keep_images) {
                try result.append(allocator, .{ .image = try copyImageContent(allocator, image) });
                previous_was_placeholder = false;
            } else if (!previous_was_placeholder) {
                try result.append(allocator, .{ .text = .{ .text = non_vision_user_image_placeholder } });
                previous_was_placeholder = true;
            }
        },
        .text => |text| {
            try result.append(allocator, .{ .text = .{
                .text = try allocator.dupe(u8, text.text),
                .text_signature = try copyOptionalString(allocator, text.text_signature),
            } });
            previous_was_placeholder = std.mem.eql(u8, text.text, non_vision_user_image_placeholder);
        },
    };
    return result.toOwnedSlice(allocator);
}

fn transformToolResultContentSlice(
    allocator: std.mem.Allocator,
    source: []const protocol.ToolResultContent,
    keep_images: bool,
) ![]const protocol.ToolResultContent {
    var result: std.ArrayList(protocol.ToolResultContent) = .empty;
    var previous_was_placeholder = false;
    for (source) |block| switch (block) {
        .image => |image| {
            if (keep_images) {
                try result.append(allocator, .{ .image = try copyImageContent(allocator, image) });
                previous_was_placeholder = false;
            } else if (!previous_was_placeholder) {
                try result.append(allocator, .{ .text = .{ .text = non_vision_tool_image_placeholder } });
                previous_was_placeholder = true;
            }
        },
        .text => |text| {
            try result.append(allocator, .{ .text = .{
                .text = try allocator.dupe(u8, text.text),
                .text_signature = try copyOptionalString(allocator, text.text_signature),
            } });
            previous_was_placeholder = std.mem.eql(u8, text.text, non_vision_tool_image_placeholder);
        },
    };
    return result.toOwnedSlice(allocator);
}

fn supportsImages(model: protocol.Model) bool {
    for (model.input) |input| if (input == .image) return true;
    return false;
}

fn copyThinkingContent(allocator: std.mem.Allocator, source: protocol.ThinkingContent) !protocol.ThinkingContent {
    return .{
        .thinking = try allocator.dupe(u8, source.thinking),
        .thinking_signature = try copyOptionalString(allocator, source.thinking_signature),
        .redacted = source.redacted,
    };
}

fn copyImageContent(allocator: std.mem.Allocator, source: protocol.ImageContent) !protocol.ImageContent {
    return .{
        .data = try allocator.dupe(u8, source.data),
        .mime_type = try allocator.dupe(u8, source.mime_type),
    };
}

fn copyToolCall(allocator: std.mem.Allocator, source: protocol.ToolCall) !protocol.ToolCall {
    return .{
        .id = try allocator.dupe(u8, source.id),
        .name = try allocator.dupe(u8, source.name),
        .arguments = try runtime.cloneJsonValue(allocator, source.arguments),
        .thought_signature = try copyOptionalString(allocator, source.thought_signature),
    };
}

fn copyOptionalString(allocator: std.mem.Allocator, source: ?[]const u8) !?[]const u8 {
    return if (source) |value| try allocator.dupe(u8, value) else null;
}

test "non vision model replaces adjacent user images with one placeholder" {
    const source = [_]protocol.Message{.{ .user = .{
        .content = .{ .blocks = &.{
            .{ .image = .{ .data = "a", .mime_type = "image/png" } },
            .{ .image = .{ .data = "b", .mime_type = "image/png" } },
            .{ .text = .{ .text = "after" } },
        } },
        .timestamp = 1,
    } }};

    var transformed = try transformMessages(std.testing.allocator, &source, testModel(&.{.text}), null);
    defer transformed.deinit();

    const blocks = transformed.messages[0].user.content.blocks;
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqualStrings(non_vision_user_image_placeholder, blocks[0].text.text);
    try std.testing.expectEqualStrings("after", blocks[1].text.text);
}

test "cross model thinking becomes text and redacted thinking is dropped" {
    const source = [_]protocol.Message{.{ .assistant = assistantMessage(&.{
        .{ .thinking = .{ .thinking = "visible", .thinking_signature = "sig" } },
        .{ .thinking = .{ .thinking = "secret", .redacted = true } },
    }, .stop) }};

    var transformed = try transformMessages(std.testing.allocator, &source, testModel(&.{.text}), null);
    defer transformed.deinit();

    const content = transformed.messages[0].assistant.content;
    try std.testing.expectEqual(@as(usize, 1), content.len);
    try std.testing.expectEqualStrings("visible", content[0].text.text);
}

test "orphaned tool calls receive synthetic tool results before user message" {
    const source = [_]protocol.Message{
        .{ .assistant = assistantMessage(&.{.{ .tool_call = .{
            .id = "call-1",
            .name = "echo",
            .arguments = .null,
        } }}, .tool_use) },
        .{ .user = .{ .content = .{ .string = "next" }, .timestamp = 2 } },
    };

    var transformed = try transformMessages(std.testing.allocator, &source, testModel(&.{.text}), null);
    defer transformed.deinit();

    try std.testing.expectEqual(@as(usize, 3), transformed.messages.len);
    try std.testing.expect(transformed.messages[1] == .tool_result);
    try std.testing.expectEqualStrings("call-1", transformed.messages[1].tool_result.tool_call_id);
    try std.testing.expect(transformed.messages[1].tool_result.is_error);
}

test "tool call id normalization updates later tool result" {
    const source = [_]protocol.Message{
        .{ .assistant = assistantMessage(&.{.{ .tool_call = .{
            .id = "very-long",
            .name = "echo",
            .arguments = .null,
        } }}, .tool_use) },
        .{ .tool_result = .{
            .tool_call_id = "very-long",
            .tool_name = "echo",
            .content = &.{.{ .text = .{ .text = "ok" } }},
            .is_error = false,
            .timestamp = 3,
        } },
    };
    const normalizer: NormalizeToolCallId = .{ .call_fn = normalizeForTest };

    var transformed = try transformMessages(std.testing.allocator, &source, testModel(&.{.text}), normalizer);
    defer transformed.deinit();

    try std.testing.expectEqualStrings("short", transformed.messages[0].assistant.content[0].tool_call.id);
    try std.testing.expectEqualStrings("short", transformed.messages[1].tool_result.tool_call_id);
}

fn normalizeForTest(_: ?*anyopaque, _: []const u8, _: protocol.Model, _: protocol.AssistantMessage) ![]const u8 {
    return "short";
}

fn assistantMessage(
    content: []const protocol.AssistantContent,
    stop_reason: protocol.StopReason,
) protocol.AssistantMessage {
    return .{
        .content = content,
        .api = protocol.KnownApi.openai_responses,
        .provider = protocol.KnownProvider.openai,
        .model = "source-model",
        .usage = protocol.emptyUsage(),
        .stop_reason = stop_reason,
        .timestamp = 0,
    };
}

fn testModel(input: []const protocol.Model.Input) protocol.Model {
    return .{
        .id = "target-model",
        .name = "Target Model",
        .api = protocol.KnownApi.openai_responses,
        .provider = protocol.KnownProvider.openai,
        .base_url = "https://example.test",
        .reasoning = false,
        .input = input,
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 1,
        .max_tokens = 1,
    };
}
