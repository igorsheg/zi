const std = @import("std");
const ai_protocol = @import("ai/protocol.zig");
const protocol = @import("agent2/protocol.zig");
const agent_conversation = @import("agent2/conversation_state.zig");
const message_memory = @import("agent2/message_memory.zig");
const json_util = @import("ai/json_util.zig");
const run_control = @import("agent2/control.zig");

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
    args_json_source: ?[]const u8 = null,
    args_complete: bool = false,
    execution_started: bool = false,
    result: ?protocol.AgentToolResult = null,
    is_error: bool = false,
    is_partial: bool = true,
};

/// Owned semantic snapshot of the transcript-visible conversation state.
///
/// This is the authoritative TUI semantic contract for committed messages,
/// active assistant state, live tool execution rows, and queued user input.
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
    args_json_source: ?[]u8 = null,
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
        const args_json_source = if (input.args_json_source) |source|
            try allocator.dupe(u8, source)
        else
            null;
        errdefer if (args_json_source) |source| allocator.free(source);
        const result = if (input.result) |result| try result.clone(allocator) else null;
        errdefer if (result) |owned| owned.free(allocator);

        return .{
            .item_id = item_id,
            .semantic_version = semantic_version,
            .tool_call_id = tool_call_id,
            .tool_name = tool_name,
            .args = args,
            .args_json_source = args_json_source,
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
            .args_json_source = self.args_json_source,
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
        if (self.args_json_source) |source| allocator.free(source);
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

pub fn initCommittedMessageItem(
    allocator: std.mem.Allocator,
    index: usize,
    message: protocol.AgentMessage,
) !CommittedMessageItem {
    return CommittedMessageItem.initClone(
        allocator,
        committedMessageId(index, message),
        committedMessageSemanticVersion(message),
        message,
    );
}

pub fn initActiveAssistantItem(
    allocator: std.mem.Allocator,
    message: protocol.AssistantMessage,
) !ActiveAssistantItem {
    return ActiveAssistantItem.initClone(
        allocator,
        activeAssistantId(message),
        activeAssistantSemanticVersion(message),
        message,
    );
}

pub fn initToolExecutionItem(
    allocator: std.mem.Allocator,
    input: ToolExecutionInput,
) !ToolExecutionItem {
    return ToolExecutionItem.initClone(
        allocator,
        toolExecutionId(input.tool_call_id),
        toolExecutionSemanticVersion(input),
        input,
    );
}

pub fn initQueuedUserMessageItem(
    allocator: std.mem.Allocator,
    kind: QueuedUserMessageKind,
    ordinal: usize,
    text: []const u8,
) !QueuedUserMessageItem {
    return QueuedUserMessageItem.initClone(
        allocator,
        queuedUserMessageId(kind, ordinal),
        queuedUserMessageSemanticVersion(text),
        kind,
        text,
    );
}

pub fn refreshActiveAssistantItemIdentity(item: *ActiveAssistantItem) void {
    std.debug.assert(item.message == .assistant);
    item.item_id = activeAssistantId(item.message.assistant);
    item.semantic_version = activeAssistantSemanticVersion(item.message.assistant);
}

pub fn refreshToolExecutionItemIdentity(item: *ToolExecutionItem) void {
    item.item_id = toolExecutionId(item.tool_call_id);
    item.semantic_version = toolExecutionSemanticVersion(.{
        .tool_call_id = item.tool_call_id,
        .tool_name = item.tool_name,
        .args = item.args,
        .args_json_source = item.args_json_source,
        .args_complete = item.args_complete,
        .execution_started = item.execution_started,
        .result = item.result,
        .is_error = item.is_error,
        .is_partial = item.is_partial,
    });
}

pub fn refreshQueuedUserMessageItemIdentity(item: *QueuedUserMessageItem, ordinal: usize) void {
    item.item_id = queuedUserMessageId(item.kind, ordinal);
    item.semantic_version = queuedUserMessageSemanticVersion(item.text);
}

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

    try appendCommittedMessageItems(allocator, &items, inputs.messages);
    try appendActiveAssistantItem(allocator, &items, inputs.active_assistant);
    try appendToolExecutionItems(allocator, &items, inputs.tool_executions);
    try appendQueuedItems(allocator, &items, .steering, inputs.steering);
    try appendQueuedItems(allocator, &items, .follow_up, inputs.follow_up);

    return .{
        .version = inputs.version,
        .items = try items.toOwnedSlice(allocator),
    };
}

pub const BuildFromAgentConversationInputs = struct {
    version: u64,
    view: agent_conversation.ConversationView,
    steering: []const run_control.QueuedMessageText = &.{},
    follow_up: []const run_control.QueuedMessageText = &.{},
};

pub fn buildFromAgentConversationView(
    allocator: std.mem.Allocator,
    inputs: BuildFromAgentConversationInputs,
) !ConversationSnapshot {
    var items: std.ArrayList(ConversationItem) = .empty;
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit(allocator);
    }

    const live_item_count = if (inputs.view.in_flight) |turn|
        turn.tool_executions.len + (if (turn.assistant != null) @as(usize, 1) else 0)
    else
        0;

    try items.ensureTotalCapacity(
        allocator,
        inputs.view.committed.len +
            live_item_count +
            inputs.steering.len +
            inputs.follow_up.len,
    );

    try appendCommittedMessageItems(allocator, &items, inputs.view.committed);
    if (inputs.view.in_flight) |turn| {
        try appendActiveAssistantItem(allocator, &items, turn.assistant);
        try appendToolExecutionItemsFromAgentView(allocator, &items, turn.tool_executions);
    }
    try appendQueuedItems(allocator, &items, .steering, inputs.steering);
    try appendQueuedItems(allocator, &items, .follow_up, inputs.follow_up);

    return .{
        .version = inputs.version,
        .items = try items.toOwnedSlice(allocator),
    };
}

fn appendCommittedMessageItems(
    allocator: std.mem.Allocator,
    items: *std.ArrayList(ConversationItem),
    messages: []const protocol.AgentMessage,
) !void {
    for (messages, 0..) |message, idx| {
        try items.append(allocator, .{ .committed_message = try initCommittedMessageItem(allocator, idx, message) });
    }
}

fn appendActiveAssistantItem(
    allocator: std.mem.Allocator,
    items: *std.ArrayList(ConversationItem),
    assistant: ?protocol.AssistantMessage,
) !void {
    const active_assistant = assistant orelse return;
    try items.append(allocator, .{ .active_assistant = try initActiveAssistantItem(allocator, active_assistant) });
}

fn appendToolExecutionItems(
    allocator: std.mem.Allocator,
    items: *std.ArrayList(ConversationItem),
    tool_executions: []const ToolExecutionInput,
) !void {
    for (tool_executions) |tool_execution| {
        try items.append(allocator, .{ .tool_execution = try initToolExecutionItem(allocator, tool_execution) });
    }
}

fn appendToolExecutionItemsFromAgentView(
    allocator: std.mem.Allocator,
    items: *std.ArrayList(ConversationItem),
    live_tools: []const agent_conversation.ToolExecution,
) !void {
    for (live_tools) |tool| {
        const result = if (tool.result_message) |result_message|
            try toolResultMessageAsAgentToolResult(allocator, result_message)
        else if (tool.result) |partial_result|
            try partial_result.clone(allocator)
        else
            null;
        defer if (result) |owned| owned.free(allocator);

        try items.append(allocator, .{ .tool_execution = try initToolExecutionItem(allocator, .{
            .tool_call_id = tool.tool_call_id,
            .tool_name = tool.tool_name,
            .args = tool.args,
            .args_json_source = tool.args_json_source,
            .args_complete = tool.args_complete,
            .execution_started = tool.execution_started,
            .result = result,
            .is_error = if (tool.result_message) |result_message| result_message.is_error else tool.is_error,
            .is_partial = if (tool.result_message != null) false else tool.is_partial,
        }) });
    }
}

fn appendQueuedItems(
    allocator: std.mem.Allocator,
    items: *std.ArrayList(ConversationItem),
    kind: QueuedUserMessageKind,
    entries: []const run_control.QueuedMessageText,
) !void {
    for (entries, 0..) |entry, idx| {
        try items.append(allocator, .{ .queued_user_message = try initQueuedUserMessageItem(
            allocator,
            kind,
            idx,
            entry.text,
        ) });
    }
}

fn toolResultMessageAsAgentToolResult(
    allocator: std.mem.Allocator,
    tool_result: protocol.ToolResultMessage,
) !protocol.AgentToolResult {
    const blocks = try allocator.alloc(protocol.AgentToolResult.ContentBlock, tool_result.content.len);
    var initialized: usize = 0;
    errdefer {
        for (blocks[0..initialized]) |block| switch (block) {
            .text => |text| {
                allocator.free(text.text);
                if (text.text_signature) |signature| allocator.free(signature);
            },
            .image => |image| {
                allocator.free(image.data);
                allocator.free(image.mime_type);
            },
        };
        allocator.free(blocks);
    }

    for (tool_result.content, 0..) |block, i| {
        blocks[i] = switch (block) {
            .text => |text| .{ .text = .{
                .text = try allocator.dupe(u8, text.text),
                .text_signature = if (text.text_signature) |signature| try allocator.dupe(u8, signature) else null,
            } },
            .image => |image| .{ .image = .{
                .data = try allocator.dupe(u8, image.data),
                .mime_type = try allocator.dupe(u8, image.mime_type),
            } },
        };
        initialized += 1;
    }

    return .{
        .content = blocks,
        .details = if (tool_result.details) |details| try json_util.cloneJsonValue(allocator, details) else .null,
        .is_error = tool_result.is_error,
    };
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
    if (input.args_json_source) |source| {
        std.hash.autoHash(&hasher, true);
        hasher.update(source);
    } else {
        std.hash.autoHash(&hasher, false);
    }
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
            .args_json_source = "{\"cmd\":\"he",
            .args_complete = false,
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
    try testing.expect(snapshot.items[2].tool_execution.args_json_source != null);
    try testing.expectEqualStrings("{\"cmd\":\"he", snapshot.items[2].tool_execution.args_json_source.?);
    try testing.expect(snapshot.items[2].tool_execution.result != null);
    try testing.expectEqualStrings("partial", snapshot.items[2].tool_execution.result.?.content[0].text.text);
}

test "buildFromAgentConversationView preserves in-flight rows and queued inputs" {
    const assistant_content = [_]protocol.AssistantMessage.AssistantContentBlock{
        .{ .text = .{ .text = "working" } },
        .{ .tool_call = .{ .id = "tool-1", .name = "bash", .arguments = .null } },
    };
    const tool_result_content = [_]protocol.ToolResultMessage.ContentBlock{
        .{ .text = .{ .text = "done" } },
    };
    var steering = [_]run_control.QueuedMessageText{
        .{ .text = try testing.allocator.dupe(u8, "steer") },
    };
    defer freeQueuedInputs(testing.allocator, &steering);
    var follow_up = [_]run_control.QueuedMessageText{
        .{ .text = try testing.allocator.dupe(u8, "follow") },
    };
    defer freeQueuedInputs(testing.allocator, &follow_up);

    const live_tools = try testing.allocator.dupe(agent_conversation.ToolExecution, &.{.{
        .tool_call_id = try testing.allocator.dupe(u8, "tool-1"),
        .tool_name = try testing.allocator.dupe(u8, "bash"),
        .args = .null,
        .args_json_source = try testing.allocator.dupe(u8, "{\"cmd\":\"echo hi"),
        .args_complete = false,
        .execution_started = true,
        .result_message = .{
            .tool_call_id = "tool-1",
            .tool_name = "bash",
            .content = &tool_result_content,
            .is_error = false,
            .timestamp = 3,
        },
    }});
    defer {
        for (live_tools) |tool| {
            testing.allocator.free(tool.tool_call_id);
            testing.allocator.free(tool.tool_name);
            if (tool.args_json_source) |source| testing.allocator.free(source);
        }
        testing.allocator.free(live_tools);
    }

    var committed = [_]protocol.AgentMessage{makeUserMessage("hello", 1)};

    var snapshot = try buildFromAgentConversationView(testing.allocator, .{
        .version = 11,
        .view = .{
            .committed = &committed,
            .in_flight = .{
                .assistant = makeAssistantMessage(&assistant_content, .toolUse, 2),
                .tool_executions = live_tools,
            },
        },
        .steering = &steering,
        .follow_up = &follow_up,
    });
    defer snapshot.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 5), snapshot.items.len);
    try testing.expect(snapshot.items[0] == .committed_message);
    try testing.expect(snapshot.items[1] == .active_assistant);
    try testing.expect(snapshot.items[2] == .tool_execution);
    try testing.expect(snapshot.items[3] == .queued_user_message);
    try testing.expect(snapshot.items[4] == .queued_user_message);
    try testing.expectEqualStrings("working", snapshot.items[1].active_assistant.message.assistant.content[0].text.text);
    try testing.expectEqualStrings("tool-1", snapshot.items[2].tool_execution.tool_call_id);
    try testing.expect(snapshot.items[2].tool_execution.result != null);
    try testing.expectEqualStrings("done", snapshot.items[2].tool_execution.result.?.content[0].text.text);
    try testing.expect(snapshot.items[2].tool_execution.args_json_source != null);
    try testing.expectEqualStrings("{\"cmd\":\"echo hi", snapshot.items[2].tool_execution.args_json_source.?);
    try testing.expectEqualStrings("steer", snapshot.items[3].queued_user_message.text);
    try testing.expectEqualStrings("follow", snapshot.items[4].queued_user_message.text);
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
