const std = @import("std");
const ai = @import("../ai/root.zig");
const json_util = @import("../ai/json_util.zig");
const protocol = @import("protocol.zig");
const message_memory = @import("message_memory.zig");

pub const ConversationSnapshot = struct {
    committed: []protocol.AgentMessage,
    frontier: ?ConversationFrontier = null,

    pub fn clone(self: ConversationSnapshot, allocator: std.mem.Allocator) !ConversationSnapshot {
        const committed = try message_memory.cloneMessages(allocator, self.committed);
        errdefer message_memory.freeMessages(allocator, committed);
        const frontier = if (self.frontier) |frontier|
            try frontier.clone(allocator)
        else
            null;
        return .{
            .committed = committed,
            .frontier = frontier,
        };
    }

    pub fn deinit(self: *ConversationSnapshot, allocator: std.mem.Allocator) void {
        message_memory.freeMessages(allocator, self.committed);
        if (self.frontier) |*frontier| frontier.deinit(allocator);
        self.* = undefined;
    }
};

pub const ConversationFrontier = struct {
    assistant: ?protocol.AssistantMessage = null,
    live_tools: []LiveToolExecution = &.{},

    pub fn clone(self: ConversationFrontier, allocator: std.mem.Allocator) !ConversationFrontier {
        const assistant = if (self.assistant) |assistant|
            try cloneAssistantMessage(allocator, assistant)
        else
            null;
        errdefer if (assistant) |*owned| freeAssistantMessage(allocator, owned);

        const live_tools = try allocator.alloc(LiveToolExecution, self.live_tools.len);
        var initialized: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < initialized) : (i += 1) {
                live_tools[i].deinit(allocator);
            }
            allocator.free(live_tools);
        }

        for (self.live_tools, 0..) |tool, i| {
            live_tools[i] = try tool.clone(allocator);
            initialized += 1;
        }

        return .{
            .assistant = assistant,
            .live_tools = live_tools,
        };
    }

    pub fn deinit(self: *ConversationFrontier, allocator: std.mem.Allocator) void {
        if (self.assistant) |*assistant| freeAssistantMessage(allocator, assistant);
        for (self.live_tools) |*tool| tool.deinit(allocator);
        allocator.free(self.live_tools);
        self.* = undefined;
    }
};

pub const LiveToolExecution = struct {
    tool_call_id: []u8,
    tool_name: []u8,
    args: std.json.Value,
    args_json_source: ?[]u8 = null,
    args_complete: bool = false,
    execution_started: bool = false,
    result: ?protocol.AgentToolResult = null,
    result_message: ?protocol.ToolResultMessage = null,
    is_partial: bool = false,
    is_error: bool = false,

    pub fn clone(self: LiveToolExecution, allocator: std.mem.Allocator) !LiveToolExecution {
        const tool_call_id = try allocator.dupe(u8, self.tool_call_id);
        errdefer allocator.free(tool_call_id);
        const tool_name = try allocator.dupe(u8, self.tool_name);
        errdefer allocator.free(tool_name);
        const args = try json_util.cloneJsonValue(allocator, self.args);
        errdefer json_util.freeJsonValue(allocator, args);
        const args_json_source = if (self.args_json_source) |source|
            try allocator.dupe(u8, source)
        else
            null;
        errdefer if (args_json_source) |source| allocator.free(source);
        const result = if (self.result) |result|
            try result.clone(allocator)
        else
            null;
        errdefer if (result) |owned| owned.free(allocator);
        const result_message = if (self.result_message) |result_message|
            try cloneToolResultMessage(allocator, result_message)
        else
            null;
        errdefer if (result_message) |*owned| freeToolResultMessage(allocator, owned);

        return .{
            .tool_call_id = tool_call_id,
            .tool_name = tool_name,
            .args = args,
            .args_json_source = args_json_source,
            .args_complete = self.args_complete,
            .execution_started = self.execution_started,
            .result = result,
            .result_message = result_message,
            .is_partial = self.is_partial,
            .is_error = self.is_error,
        };
    }

    pub fn deinit(self: *LiveToolExecution, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_call_id);
        allocator.free(self.tool_name);
        json_util.freeJsonValue(allocator, self.args);
        if (self.args_json_source) |source| allocator.free(source);
        if (self.result) |result| result.free(allocator);
        if (self.result_message) |*result_message| freeToolResultMessage(allocator, result_message);
        self.* = undefined;
    }
};

pub const AssistantAppendTarget = struct {
    content_index: usize,
    kind: enum {
        text,
        thinking,
    },
};

pub const FrontierAppendTarget = union(enum) {
    assistant_content: AssistantAppendTarget,
    tool_call_arguments: struct {
        tool_call_id: []u8,
    },
    tool_result_content: struct {
        tool_call_id: []u8,
        content_index: usize,
    },

    pub fn clone(self: FrontierAppendTarget, allocator: std.mem.Allocator) !FrontierAppendTarget {
        return switch (self) {
            .assistant_content => |target| .{ .assistant_content = target },
            .tool_call_arguments => |target| .{ .tool_call_arguments = .{
                .tool_call_id = try allocator.dupe(u8, target.tool_call_id),
            } },
            .tool_result_content => |target| .{ .tool_result_content = .{
                .tool_call_id = try allocator.dupe(u8, target.tool_call_id),
                .content_index = target.content_index,
            } },
        };
    }

    pub fn deinit(self: *FrontierAppendTarget, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .assistant_content => {},
            .tool_call_arguments => |target| allocator.free(target.tool_call_id),
            .tool_result_content => |target| allocator.free(target.tool_call_id),
        }
        self.* = undefined;
    }
};

pub const ConversationPatch = union(enum) {
    replace_all: ConversationSnapshot,
    append_committed: protocol.AgentMessage,
    replace_frontier: ?ConversationFrontier,
    append_frontier_content: struct {
        target: FrontierAppendTarget,
        bytes: []u8,
    },
    commit_frontier: void,

    pub fn clone(self: ConversationPatch, allocator: std.mem.Allocator) !ConversationPatch {
        return switch (self) {
            .replace_all => |snapshot| .{ .replace_all = try snapshot.clone(allocator) },
            .append_committed => |message| .{ .append_committed = try message_memory.cloneMessage(allocator, message) },
            .replace_frontier => |frontier| .{ .replace_frontier = if (frontier) |value| try value.clone(allocator) else null },
            .append_frontier_content => |append| .{ .append_frontier_content = .{
                .target = try append.target.clone(allocator),
                .bytes = try allocator.dupe(u8, append.bytes),
            } },
            .commit_frontier => .commit_frontier,
        };
    }

    pub fn deinit(self: *ConversationPatch, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .replace_all => |*snapshot| snapshot.deinit(allocator),
            .append_committed => |*message| message_memory.freeMessage(allocator, message),
            .replace_frontier => |*frontier| {
                if (frontier.*) |*owned| owned.deinit(allocator);
            },
            .append_frontier_content => |*append| {
                append.target.deinit(allocator);
                allocator.free(append.bytes);
            },
            .commit_frontier => {},
        }
        self.* = undefined;
    }
};

pub fn cloneAssistantMessage(allocator: std.mem.Allocator, assistant: protocol.AssistantMessage) !protocol.AssistantMessage {
    const wrapped = try message_memory.cloneMessage(allocator, .{ .assistant = assistant });
    return wrapped.assistant;
}

pub fn freeAssistantMessage(allocator: std.mem.Allocator, assistant: *protocol.AssistantMessage) void {
    var wrapped = protocol.AgentMessage{ .assistant = assistant.* };
    message_memory.freeMessage(allocator, &wrapped);
    assistant.* = undefined;
}

pub fn cloneToolResultMessage(allocator: std.mem.Allocator, result_message: protocol.ToolResultMessage) !protocol.ToolResultMessage {
    const wrapped = try message_memory.cloneMessage(allocator, .{ .tool_result = result_message });
    return wrapped.tool_result;
}

pub fn freeToolResultMessage(allocator: std.mem.Allocator, result_message: *protocol.ToolResultMessage) void {
    var wrapped = protocol.AgentMessage{ .tool_result = result_message.* };
    message_memory.freeMessage(allocator, &wrapped);
    result_message.* = undefined;
}

const testing = std.testing;

fn makeAssistantMessage() protocol.AssistantMessage {
    return .{
        .content = &.{
            .{ .text = .{ .text = "hello" } },
            .{ .tool_call = .{
                .id = "tool-1",
                .name = "read",
                .arguments = .null,
            } },
        },
        .api = .openai_responses,
        .provider = .openai,
        .model = "gpt-test",
        .usage = .{
            .input = 1,
            .output = 2,
            .cache_read = 0,
            .cache_write = 0,
            .total_tokens = 3,
            .cost = .{
                .input = 0,
                .output = 0,
                .cache_read = 0,
                .cache_write = 0,
                .total = 0,
            },
        },
        .stop_reason = .toolUse,
        .timestamp = 1,
    };
}

fn makeToolResultMessage() protocol.ToolResultMessage {
    return .{
        .tool_call_id = "tool-1",
        .tool_name = "read",
        .content = &.{.{ .text = .{ .text = "done" } }},
        .is_error = false,
        .timestamp = 2,
    };
}

test "ConversationPatch clone owns nested snapshot payloads" {
    const snapshot = ConversationSnapshot{
        .committed = &.{.{ .user = .{
            .content = .{ .text = "prompt" },
            .timestamp = 1,
        } }},
        .frontier = .{
            .assistant = makeAssistantMessage(),
            .live_tools = &.{.{
                .tool_call_id = @constCast("tool-1"),
                .tool_name = @constCast("read"),
                .args = .null,
                .args_complete = true,
                .execution_started = true,
                .result_message = makeToolResultMessage(),
            }},
        },
    };

    var patch = try (ConversationPatch{ .replace_all = snapshot }).clone(testing.allocator);
    defer patch.deinit(testing.allocator);

    switch (patch) {
        .replace_all => |owned| {
            try testing.expectEqual(@as(usize, 1), owned.committed.len);
            try testing.expectEqualStrings("prompt", owned.committed[0].user.content.text);
            try testing.expect(owned.frontier != null);
            try testing.expectEqual(@as(usize, 1), owned.frontier.?.live_tools.len);
            try testing.expectEqualStrings("tool-1", owned.frontier.?.live_tools[0].tool_call_id);
            try testing.expectEqualStrings("done", owned.frontier.?.live_tools[0].result_message.?.content[0].text.text);
        },
        else => return error.TestUnexpectedResult,
    }
}
