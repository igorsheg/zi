const std = @import("std");
const ai_protocol = @import("ai/protocol.zig");
const protocol = @import("agent/protocol.zig");
const message_memory = @import("agent/message_memory.zig");
const json_util = @import("ai/json_util.zig");
const run_control = @import("runtime/run_control.zig");

pub const ItemId = enum(u64) { _ };
pub const SemanticVersion = u64;

pub const QueuedUserMessageKind = enum {
    steering,
    follow_up,
};

pub const ToolExecutionInput = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    args: std.json.Value = .null,
    args_complete: bool = false,
    execution_started: bool = false,
    result: ?protocol.AgentToolResult = null,
    is_error: bool = false,
    is_partial: bool = true,
};

/// Owned semantic snapshot of the transcript-visible conversation state.
///
/// Phase 1 of the projection refactor snapshots committed messages plus
/// queued user rows. Live active-assistant / tool-execution items land in
/// the cutover slices that remove delta-driven transcript mutation.
pub const ConversationSnapshot = struct {
    version: u64,
    items: []ConversationItem,

    pub fn clone(self: ConversationSnapshot, allocator: std.mem.Allocator) !ConversationSnapshot {
        const items = try allocator.alloc(ConversationItem, self.items.len);
        var initialized: usize = 0;
        errdefer {
            for (items[0..initialized]) |*item| item.deinit(allocator);
            allocator.free(items);
        }

        for (self.items, 0..) |item, i| {
            items[i] = try item.clone(allocator);
            initialized += 1;
        }

        return .{
            .version = self.version,
            .items = items,
        };
    }

    pub fn deinit(self: *ConversationSnapshot, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
        self.* = undefined;
    }
};

pub const ConversationItem = union(enum) {
    committed_message: CommittedMessageItem,
    active_assistant: ActiveAssistantItem,
    tool_execution: ToolExecutionItem,
    queued_user_message: QueuedUserMessageItem,

    pub fn clone(self: ConversationItem, allocator: std.mem.Allocator) !ConversationItem {
        return switch (self) {
            .committed_message => |item| .{ .committed_message = try item.clone(allocator) },
            .active_assistant => |item| .{ .active_assistant = try item.clone(allocator) },
            .tool_execution => |item| .{ .tool_execution = try item.clone(allocator) },
            .queued_user_message => |item| .{ .queued_user_message = try item.clone(allocator) },
        };
    }

    pub fn deinit(self: *ConversationItem, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .committed_message => |*item| item.deinit(allocator),
            .active_assistant => |*item| item.deinit(allocator),
            .tool_execution => |*item| item.deinit(allocator),
            .queued_user_message => |*item| item.deinit(allocator),
        }
    }

    pub fn itemId(self: ConversationItem) ItemId {
        return switch (self) {
            .committed_message => |item| item.item_id,
            .active_assistant => |item| item.item_id,
            .tool_execution => |item| item.item_id,
            .queued_user_message => |item| item.item_id,
        };
    }

    pub fn semanticVersion(self: ConversationItem) SemanticVersion {
        return switch (self) {
            .committed_message => |item| item.semantic_version,
            .active_assistant => |item| item.semantic_version,
            .tool_execution => |item| item.semantic_version,
            .queued_user_message => |item| item.semantic_version,
        };
    }
};

pub const CommittedMessageItem = struct {
    item_id: ItemId,
    semantic_version: SemanticVersion,
    message: protocol.AgentMessage,

    fn initClone(
        allocator: std.mem.Allocator,
        item_id: ItemId,
        semantic_version: SemanticVersion,
        message: protocol.AgentMessage,
    ) !CommittedMessageItem {
        return .{
            .item_id = item_id,
            .semantic_version = semantic_version,
            .message = try message_memory.cloneMessage(allocator, message),
        };
    }

    pub fn clone(self: CommittedMessageItem, allocator: std.mem.Allocator) !CommittedMessageItem {
        return initClone(allocator, self.item_id, self.semantic_version, self.message);
    }

    pub fn deinit(self: *CommittedMessageItem, allocator: std.mem.Allocator) void {
        message_memory.freeMessage(allocator, &self.message);
        self.* = undefined;
    }
};

pub const ActiveAssistantItem = struct {
    item_id: ItemId,
    semantic_version: SemanticVersion,
    message: protocol.AgentMessage,

    fn initClone(
        allocator: std.mem.Allocator,
        item_id: ItemId,
        semantic_version: SemanticVersion,
        message: protocol.AssistantMessage,
    ) !ActiveAssistantItem {
        return .{
            .item_id = item_id,
            .semantic_version = semantic_version,
            .message = try message_memory.cloneMessage(allocator, .{ .assistant = message }),
        };
    }

    pub fn clone(self: ActiveAssistantItem, allocator: std.mem.Allocator) !ActiveAssistantItem {
        std.debug.assert(self.message == .assistant);
        return initClone(allocator, self.item_id, self.semantic_version, self.message.assistant);
    }

    pub fn deinit(self: *ActiveAssistantItem, allocator: std.mem.Allocator) void {
        message_memory.freeMessage(allocator, &self.message);
        self.* = undefined;
    }
};

pub const ToolExecutionItem = struct {
    item_id: ItemId,
    semantic_version: SemanticVersion,
    tool_call_id: []u8,
    tool_name: []u8,
    args: std.json.Value = .null,
    args_complete: bool = false,
    execution_started: bool = false,
    result: ?protocol.AgentToolResult = null,
    is_error: bool = false,
    is_partial: bool = true,

    fn initClone(
        allocator: std.mem.Allocator,
        item_id: ItemId,
        semantic_version: SemanticVersion,
        input: ToolExecutionInput,
    ) !ToolExecutionItem {
        const tool_call_id = try allocator.dupe(u8, input.tool_call_id);
        errdefer allocator.free(tool_call_id);
        const tool_name = try allocator.dupe(u8, input.tool_name);
        errdefer allocator.free(tool_name);
        const args = try json_util.cloneJsonValue(allocator, input.args);
        errdefer json_util.freeJsonValue(allocator, args);
        const result = if (input.result) |result| try result.clone(allocator) else null;
        errdefer if (result) |owned| owned.free(allocator);

        return .{
            .item_id = item_id,
            .semantic_version = semantic_version,
            .tool_call_id = tool_call_id,
            .tool_name = tool_name,
            .args = args,
            .args_complete = input.args_complete,
            .execution_started = input.execution_started,
            .result = result,
            .is_error = input.is_error,
            .is_partial = input.is_partial,
        };
    }

    pub fn clone(self: ToolExecutionItem, allocator: std.mem.Allocator) !ToolExecutionItem {
        return initClone(allocator, self.item_id, self.semantic_version, .{
            .tool_call_id = self.tool_call_id,
            .tool_name = self.tool_name,
            .args = self.args,
            .args_complete = self.args_complete,
            .execution_started = self.execution_started,
            .result = self.result,
            .is_error = self.is_error,
            .is_partial = self.is_partial,
        });
    }

    pub fn deinit(self: *ToolExecutionItem, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_call_id);
        allocator.free(self.tool_name);
        json_util.freeJsonValue(allocator, self.args);
        if (self.result) |result| result.free(allocator);
        self.* = undefined;
    }
};

pub const QueuedUserMessageItem = struct {
    item_id: ItemId,
    semantic_version: SemanticVersion,
    kind: QueuedUserMessageKind,
    text: []u8,

    fn initClone(
        allocator: std.mem.Allocator,
        item_id: ItemId,
        semantic_version: SemanticVersion,
        kind: QueuedUserMessageKind,
        text: []const u8,
    ) !QueuedUserMessageItem {
        return .{
            .item_id = item_id,
            .semantic_version = semantic_version,
            .kind = kind,
            .text = try allocator.dupe(u8, text),
        };
    }

    pub fn clone(self: QueuedUserMessageItem, allocator: std.mem.Allocator) !QueuedUserMessageItem {
        return initClone(allocator, self.item_id, self.semantic_version, self.kind, self.text);
    }

    pub fn deinit(self: *QueuedUserMessageItem, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

pub const BuildInputs = struct {
    version: u64,
    messages: []const protocol.AgentMessage,
    active_assistant: ?protocol.AssistantMessage = null,
    tool_executions: []const ToolExecutionInput = &.{},
    steering: []const run_control.QueuedMessageText = &.{},
    follow_up: []const run_control.QueuedMessageText = &.{},
};

pub fn build(allocator: std.mem.Allocator, inputs: BuildInputs) !ConversationSnapshot {
    var items: std.ArrayList(ConversationItem) = .empty;
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit(allocator);
    }

    try items.ensureTotalCapacity(
        allocator,
        inputs.messages.len +
            inputs.tool_executions.len +
            inputs.steering.len +
            inputs.follow_up.len +
            (if (inputs.active_assistant != null) @as(usize, 1) else 0),
    );

    for (inputs.messages, 0..) |message, idx| {
        try items.append(allocator, .{ .committed_message = try CommittedMessageItem.initClone(
            allocator,
            committedMessageId(idx, message),
            committedMessageSemanticVersion(message),
            message,
        ) });
    }

    if (inputs.active_assistant) |assistant| {
        try items.append(allocator, .{ .active_assistant = try ActiveAssistantItem.initClone(
            allocator,
            activeAssistantId(assistant),
            activeAssistantSemanticVersion(assistant),
            assistant,
        ) });
    }

    try appendToolExecutionItems(allocator, &items, inputs.tool_executions);
    try appendQueuedItems(allocator, &items, .steering, inputs.steering);
    try appendQueuedItems(allocator, &items, .follow_up, inputs.follow_up);

    return .{
        .version = inputs.version,
        .items = try items.toOwnedSlice(allocator),
    };
}

fn appendToolExecutionItems(
    allocator: std.mem.Allocator,
    items: *std.ArrayList(ConversationItem),
    tool_executions: []const ToolExecutionInput,
) !void {
    for (tool_executions) |tool_execution| {
        try items.append(allocator, .{ .tool_execution = try ToolExecutionItem.initClone(
            allocator,
            toolExecutionId(tool_execution.tool_call_id),
            toolExecutionSemanticVersion(tool_execution),
            tool_execution,
        ) });
    }
}

fn appendQueuedItems(
    allocator: std.mem.Allocator,
    items: *std.ArrayList(ConversationItem),
    kind: QueuedUserMessageKind,
    entries: []const run_control.QueuedMessageText,
) !void {
    for (entries, 0..) |entry, idx| {
        try items.append(allocator, .{ .queued_user_message = try QueuedUserMessageItem.initClone(
            allocator,
            queuedUserMessageId(kind, idx),
            queuedUserMessageSemanticVersion(entry.text),
            kind,
            entry.text,
        ) });
    }
}

fn committedMessageSemanticVersion(message: protocol.AgentMessage) SemanticVersion {
    var hasher = std.hash.Wyhash.init(0x434f_4d4d_56455231);
    hasher.update("committed_message_semantic");
    hashAgentMessage(&hasher, message);
    return hasher.final();
}

fn activeAssistantId(message: protocol.AssistantMessage) ItemId {
    var hasher = std.hash.Wyhash.init(0x41435449_56454944);
    hasher.update("active_assistant");
    std.hash.autoHash(&hasher, message.timestamp);
    return @enumFromInt(hasher.final());
}

fn activeAssistantSemanticVersion(message: protocol.AssistantMessage) SemanticVersion {
    var hasher = std.hash.Wyhash.init(0x41435449_56455652);
    hasher.update("active_assistant_semantic");
    hashAssistantMessage(&hasher, message);
    return hasher.final();
}

fn committedMessageId(index: usize, message: protocol.AgentMessage) ItemId {
    var hasher = std.hash.Wyhash.init(0x434f_4e56_534e_4150);
    hasher.update("committed_message");
    std.hash.autoHash(&hasher, index);
    std.hash.autoHash(&hasher, messageTagCode(message));
    std.hash.autoHash(&hasher, messageTimestamp(message));
    return @enumFromInt(hasher.final());
}

fn queuedUserMessageId(kind: QueuedUserMessageKind, ordinal: usize) ItemId {
    var hasher = std.hash.Wyhash.init(0x5155_4555_4549_4401);
    hasher.update("queued_user_message");
    std.hash.autoHash(&hasher, @intFromEnum(kind));
    std.hash.autoHash(&hasher, ordinal);
    return @enumFromInt(hasher.final());
}

fn queuedUserMessageSemanticVersion(text: []const u8) SemanticVersion {
    var hasher = std.hash.Wyhash.init(0x5155_4555_4556_4552);
    hasher.update(text);
    return hasher.final();
}

fn toolExecutionId(tool_call_id: []const u8) ItemId {
    var hasher = std.hash.Wyhash.init(0x544f4f4c_45584944);
    hasher.update("tool_execution");
    hasher.update(tool_call_id);
    return @enumFromInt(hasher.final());
}

fn toolExecutionSemanticVersion(input: ToolExecutionInput) SemanticVersion {
    var hasher = std.hash.Wyhash.init(0x544f4f4c_45585652);
    hasher.update("tool_execution_semantic");
    hasher.update(input.tool_call_id);
    hasher.update(input.tool_name);
    hashJsonValue(&hasher, input.args);
    std.hash.autoHash(&hasher, input.args_complete);
    std.hash.autoHash(&hasher, input.execution_started);
    std.hash.autoHash(&hasher, input.is_error);
    std.hash.autoHash(&hasher, input.is_partial);
    if (input.result) |result| {
        std.hash.autoHash(&hasher, true);
        hashAgentToolResult(&hasher, result);
    } else {
        std.hash.autoHash(&hasher, false);
    }
    return hasher.final();
}

fn messageTagCode(message: protocol.AgentMessage) u8 {
    return switch (message) {
        .user => 1,
        .assistant => 2,
        .tool_result => 3,
        .compaction_summary => 4,
        .branch_summary => 5,
        .custom => 6,
    };
}

fn messageTimestamp(message: protocol.AgentMessage) i64 {
    return switch (message) {
        .user => |user| user.timestamp,
        .assistant => |assistant| assistant.timestamp,
        .tool_result => |tool_result| tool_result.timestamp,
        .compaction_summary => |summary| summary.timestamp,
        .branch_summary => |summary| summary.timestamp,
        .custom => |custom| custom.timestamp,
    };
}

fn hashAgentMessage(hasher: *std.hash.Wyhash, message: protocol.AgentMessage) void {
    std.hash.autoHash(hasher, messageTagCode(message));
    std.hash.autoHash(hasher, messageTimestamp(message));
    switch (message) {
        .user => |user| hashUserContent(hasher, user.content),
        .assistant => |assistant| hashAssistantMessage(hasher, assistant),
        .tool_result => |tool_result| {
            hasher.update(tool_result.tool_call_id);
            hasher.update(tool_result.tool_name);
            std.hash.autoHash(hasher, tool_result.is_error);
            for (tool_result.content) |block| hashToolResultContentBlock(hasher, block);
            if (tool_result.details) |details| hashJsonValue(hasher, details) else hashJsonValue(hasher, .null);
        },
        .compaction_summary => |summary| {
            hasher.update(summary.summary);
            std.hash.autoHash(hasher, summary.tokens_before);
        },
        .branch_summary => |summary| {
            hasher.update(summary.summary);
            hasher.update(summary.from_id);
        },
        .custom => |custom| {
            hasher.update(custom.custom_type);
            std.hash.autoHash(hasher, custom.display);
            hashCustomContent(hasher, custom.content);
            if (custom.details) |details| hashJsonValue(hasher, details) else hashJsonValue(hasher, .null);
        },
    }
}

fn hashAssistantMessage(hasher: *std.hash.Wyhash, assistant: protocol.AssistantMessage) void {
    std.hash.autoHash(hasher, @intFromEnum(assistant.api));
    std.hash.autoHash(hasher, @intFromEnum(assistant.provider));
    hasher.update(assistant.model);
    std.hash.autoHash(hasher, assistant.timestamp);
    std.hash.autoHash(hasher, @intFromEnum(assistant.stop_reason));
    if (assistant.error_message) |msg| {
        std.hash.autoHash(hasher, true);
        hasher.update(msg);
    } else {
        std.hash.autoHash(hasher, false);
    }
    for (assistant.content) |block| switch (block) {
        .text => |text| hasher.update(text.text),
        .thinking => |thinking| {
            hasher.update(thinking.thinking);
            if (thinking.thinking_signature) |sig| {
                std.hash.autoHash(hasher, true);
                hasher.update(sig);
            } else {
                std.hash.autoHash(hasher, false);
            }
            std.hash.autoHash(hasher, thinking.redacted != null);
            if (thinking.redacted) |redacted| std.hash.autoHash(hasher, redacted);
        },
        .tool_call => |tool_call| {
            hasher.update(tool_call.id);
            hasher.update(tool_call.name);
            hashJsonValue(hasher, tool_call.arguments);
        },
    };
}

fn hashUserContent(hasher: *std.hash.Wyhash, content: ai_protocol.UserMessage.UserMessageContent) void {
    switch (content) {
        .text => |text| hasher.update(text),
        .blocks => |blocks| for (blocks) |block| switch (block) {
            .text => |text| hasher.update(text.text),
            .image => |image| {
                hasher.update(image.mime_type);
                hasher.update(image.data);
            },
        },
    }
}

fn hashCustomContent(hasher: *std.hash.Wyhash, content: protocol.AgentMessage.CustomContent) void {
    switch (content) {
        .text => |text| hasher.update(text),
        .blocks => |blocks| for (blocks) |block| switch (block) {
            .text => |text| hasher.update(text.text),
            .image => |image| {
                hasher.update(image.mime_type);
                hasher.update(image.data);
            },
        },
    }
}

fn hashAgentToolResult(hasher: *std.hash.Wyhash, result: protocol.AgentToolResult) void {
    std.hash.autoHash(hasher, result.is_error);
    for (result.content) |block| hashAgentToolResultContentBlock(hasher, block);
    hashJsonValue(hasher, result.details);
}

fn hashAgentToolResultContentBlock(hasher: *std.hash.Wyhash, block: protocol.AgentToolResult.ContentBlock) void {
    switch (block) {
        .text => |text| {
            hasher.update(text.text);
            if (text.text_signature) |sig| {
                std.hash.autoHash(hasher, true);
                hasher.update(sig);
            } else {
                std.hash.autoHash(hasher, false);
            }
        },
        .image => |image| {
            hasher.update(image.mime_type);
            hasher.update(image.data);
        },
    }
}

fn hashToolResultContentBlock(hasher: *std.hash.Wyhash, block: protocol.ToolResultMessage.ContentBlock) void {
    switch (block) {
        .text => |text| {
            hasher.update(text.text);
            if (text.text_signature) |sig| {
                std.hash.autoHash(hasher, true);
                hasher.update(sig);
            } else {
                std.hash.autoHash(hasher, false);
            }
        },
        .image => |image| {
            hasher.update(image.mime_type);
            hasher.update(image.data);
        },
    }
}

fn hashJsonValue(hasher: *std.hash.Wyhash, value: std.json.Value) void {
    switch (value) {
        .null => std.hash.autoHash(hasher, @as(u8, 0)),
        .bool => |bool_value| {
            std.hash.autoHash(hasher, @as(u8, 1));
            std.hash.autoHash(hasher, bool_value);
        },
        .integer => |integer| {
            std.hash.autoHash(hasher, @as(u8, 2));
            std.hash.autoHash(hasher, integer);
        },
        .float => |float_value| {
            std.hash.autoHash(hasher, @as(u8, 3));
            hasher.update(std.mem.asBytes(&float_value));
        },
        .number_string => |number_string| {
            std.hash.autoHash(hasher, @as(u8, 4));
            hasher.update(number_string);
        },
        .string => |string| {
            std.hash.autoHash(hasher, @as(u8, 5));
            hasher.update(string);
        },
        .array => |array| {
            std.hash.autoHash(hasher, @as(u8, 6));
            for (array.items) |entry| hashJsonValue(hasher, entry);
        },
        .object => |object| {
            std.hash.autoHash(hasher, @as(u8, 7));
            var it = object.iterator();
            while (it.next()) |entry| {
                hasher.update(entry.key_ptr.*);
                hashJsonValue(hasher, entry.value_ptr.*);
            }
        },
    }
}

const testing = std.testing;

fn makeUserMessage(text: []const u8, timestamp: i64) protocol.AgentMessage {
    return .{ .user = .{
        .content = .{ .text = text },
        .timestamp = timestamp,
    } };
}

fn makeCompactionSummary(summary: []const u8, timestamp: i64) protocol.AgentMessage {
    return .{ .compaction_summary = .{
        .summary = summary,
        .tokens_before = 123,
        .timestamp = timestamp,
    } };
}

fn makeAssistantMessage(
    content: []const protocol.AssistantMessage.AssistantContentBlock,
    stop_reason: protocol.StopReason,
    timestamp: i64,
) protocol.AssistantMessage {
    return .{
        .content = content,
        .api = .anthropic_messages,
        .provider = .anthropic,
        .model = "claude-test",
        .usage = .{
            .input = 1,
            .output = 1,
            .cache_read = 0,
            .cache_write = 0,
            .total_tokens = 2,
            .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 },
        },
        .stop_reason = stop_reason,
        .timestamp = timestamp,
    };
}

fn freeQueuedInputs(allocator: std.mem.Allocator, entries: []run_control.QueuedMessageText) void {
    for (entries) |entry| allocator.free(entry.text);
}

test "build clones committed messages and queued rows into owned snapshot" {
    const messages = [_]protocol.AgentMessage{
        makeUserMessage("hello", 1),
        makeCompactionSummary("summary", 2),
    };

    var steering = [_]run_control.QueuedMessageText{
        .{ .text = try testing.allocator.dupe(u8, "steer") },
    };

    var follow_up = [_]run_control.QueuedMessageText{
        .{ .text = try testing.allocator.dupe(u8, "follow") },
    };

    var snapshot = try build(testing.allocator, .{
        .version = 7,
        .messages = &messages,
        .steering = &steering,
        .follow_up = &follow_up,
    });
    defer snapshot.deinit(testing.allocator);

    freeQueuedInputs(testing.allocator, &steering);
    freeQueuedInputs(testing.allocator, &follow_up);

    try testing.expectEqual(@as(u64, 7), snapshot.version);
    try testing.expectEqual(@as(usize, 4), snapshot.items.len);
    try testing.expect(snapshot.items[0] == .committed_message);
    try testing.expect(snapshot.items[1] == .committed_message);
    try testing.expect(snapshot.items[2] == .queued_user_message);
    try testing.expect(snapshot.items[3] == .queued_user_message);
    try testing.expectEqualStrings("hello", snapshot.items[0].committed_message.message.user.content.text);
    try testing.expectEqualStrings("summary", snapshot.items[1].committed_message.message.compaction_summary.summary);
    try testing.expectEqual(QueuedUserMessageKind.steering, snapshot.items[2].queued_user_message.kind);
    try testing.expectEqualStrings("steer", snapshot.items[2].queued_user_message.text);
    try testing.expectEqual(QueuedUserMessageKind.follow_up, snapshot.items[3].queued_user_message.kind);
    try testing.expectEqualStrings("follow", snapshot.items[3].queued_user_message.text);
}

test "build keeps stable ids for repeated inputs and bumps queued semantic version on text change" {
    const messages = [_]protocol.AgentMessage{makeUserMessage("hello", 1)};

    var steering_a = [_]run_control.QueuedMessageText{
        .{ .text = try testing.allocator.dupe(u8, "draft") },
    };
    defer freeQueuedInputs(testing.allocator, &steering_a);
    var snapshot_a = try build(testing.allocator, .{
        .version = 1,
        .messages = &messages,
        .steering = &steering_a,
    });
    defer snapshot_a.deinit(testing.allocator);

    var steering_b = [_]run_control.QueuedMessageText{
        .{ .text = try testing.allocator.dupe(u8, "draft") },
    };
    defer freeQueuedInputs(testing.allocator, &steering_b);
    var snapshot_b = try build(testing.allocator, .{
        .version = 2,
        .messages = &messages,
        .steering = &steering_b,
    });
    defer snapshot_b.deinit(testing.allocator);

    try testing.expectEqual(@intFromEnum(snapshot_a.items[0].itemId()), @intFromEnum(snapshot_b.items[0].itemId()));
    try testing.expectEqual(snapshot_a.items[0].semanticVersion(), snapshot_b.items[0].semanticVersion());
    try testing.expectEqual(@intFromEnum(snapshot_a.items[1].itemId()), @intFromEnum(snapshot_b.items[1].itemId()));
    try testing.expectEqual(snapshot_a.items[1].semanticVersion(), snapshot_b.items[1].semanticVersion());

    var steering_c = [_]run_control.QueuedMessageText{
        .{ .text = try testing.allocator.dupe(u8, "revised") },
    };
    defer freeQueuedInputs(testing.allocator, &steering_c);
    var snapshot_c = try build(testing.allocator, .{
        .version = 3,
        .messages = &messages,
        .steering = &steering_c,
    });
    defer snapshot_c.deinit(testing.allocator);

    try testing.expectEqual(@intFromEnum(snapshot_a.items[1].itemId()), @intFromEnum(snapshot_c.items[1].itemId()));
    try testing.expect(snapshot_a.items[1].semanticVersion() != snapshot_c.items[1].semanticVersion());
}

test "build includes active assistant and live tool execution items" {
    const assistant_content = [_]protocol.AssistantMessage.AssistantContentBlock{
        .{ .text = .{ .text = "working" } },
        .{ .tool_call = .{ .id = "tool-1", .name = "bash", .arguments = .null } },
    };
    const assistant = makeAssistantMessage(&assistant_content, .toolUse, 3);

    const tool_blocks = [_]protocol.AgentToolResult.ContentBlock{
        .{ .text = .{ .text = "partial" } },
    };
    const tool_result = protocol.AgentToolResult{
        .content = &tool_blocks,
        .is_error = false,
    };

    var snapshot = try build(testing.allocator, .{
        .version = 4,
        .messages = &.{makeUserMessage("hello", 1)},
        .active_assistant = assistant,
        .tool_executions = &.{.{
            .tool_call_id = "tool-1",
            .tool_name = "bash",
            .args = .null,
            .args_complete = true,
            .execution_started = true,
            .result = tool_result,
            .is_error = false,
            .is_partial = true,
        }},
    });
    defer snapshot.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), snapshot.items.len);
    try testing.expect(snapshot.items[1] == .active_assistant);
    try testing.expect(snapshot.items[2] == .tool_execution);
    try testing.expectEqualStrings("working", snapshot.items[1].active_assistant.message.assistant.content[0].text.text);
    try testing.expectEqualStrings("tool-1", snapshot.items[2].tool_execution.tool_call_id);
    try testing.expect(snapshot.items[2].tool_execution.result != null);
    try testing.expectEqualStrings("partial", snapshot.items[2].tool_execution.result.?.content[0].text.text);
}

test "conversation snapshot clone deep copies items" {
    const messages = [_]protocol.AgentMessage{makeUserMessage("hello", 1)};
    var steering = [_]run_control.QueuedMessageText{
        .{ .text = try testing.allocator.dupe(u8, "draft") },
    };
    defer freeQueuedInputs(testing.allocator, &steering);

    var original = try build(testing.allocator, .{
        .version = 9,
        .messages = &messages,
        .steering = &steering,
    });

    var cloned = try original.clone(testing.allocator);
    defer cloned.deinit(testing.allocator);

    original.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, 9), cloned.version);
    try testing.expectEqual(@as(usize, 2), cloned.items.len);
    try testing.expectEqualStrings("hello", cloned.items[0].committed_message.message.user.content.text);
    try testing.expectEqualStrings("draft", cloned.items[1].queued_user_message.text);
}
