const std = @import("std");
const ai = @import("../ai/root.zig");
const partial_json = @import("../json/partial.zig");
const protocol = @import("types.zig");
const message_memory = @import("message_memory.zig");
const shared_committed_mod = @import("shared_committed.zig");
const json_value = @import("../json/value.zig");

pub const SharedCommitted = shared_committed_mod.SharedCommitted;

pub const ConversationView = struct {
    committed: *SharedCommitted,
    in_flight: ?InFlightTurn = null,

    pub fn deinit(self: *ConversationView, allocator: std.mem.Allocator) void {
        self.committed.release();
        if (self.in_flight) |*turn| turn.deinit(allocator);
        self.* = undefined;
    }
};

pub const ConversationSnapshotEnvelope = struct {
    session_generation: u64 = 0,
    conversation_version: u64 = 0,
    view: ConversationView,

    pub fn deinit(self: *ConversationSnapshotEnvelope, allocator: std.mem.Allocator) void {
        self.view.deinit(allocator);
        self.* = undefined;
    }
};

pub const FrontierLocator = struct {
    assistant_timestamp: i64,

    pub fn fromAssistant(assistant: protocol.AssistantMessage) FrontierLocator {
        return .{ .assistant_timestamp = assistant.timestamp };
    }

    pub fn eql(self: FrontierLocator, other: FrontierLocator) bool {
        return self.assistant_timestamp == other.assistant_timestamp;
    }
};

pub const InFlightTurn = struct {
    locator: FrontierLocator,
    assistant: ?protocol.AssistantMessage = null,
    tool_executions: []ToolExecution = &.{},

    pub fn deinit(self: *InFlightTurn, allocator: std.mem.Allocator) void {
        if (self.assistant) |*assistant| message_memory.freeAssistantMessage(allocator, assistant);
        for (self.tool_executions) |*tool| tool.deinit(allocator);
        allocator.free(self.tool_executions);
        self.* = undefined;
    }
};

pub const ApplyEventResult = struct {
    immediate_commit: ?protocol.AgentMessage = null,
    turn_commit: ?TurnCommit = null,
    did_mutate_conversation: bool = false,

    pub const TurnCommit = struct {
        assistant: protocol.AssistantMessage,
        tool_results: []const protocol.ToolResultMessage,
        error_message: ?[]const u8 = null,
    };
};

pub const ToolExecution = struct {
    tool_call_id: []u8,
    tool_name: []u8,
    args: json_value.OwnedValue,
    args_json_source: ?[]u8 = null,
    args_complete: bool = false,
    state: State = .discovered,

    pub const State = union(enum) {
        discovered,
        started,
        partial: ResultState,
        final: ResultState,
        result_message: protocol.ToolResultMessage,

        pub fn clone(self: State, allocator: std.mem.Allocator) !State {
            return switch (self) {
                .discovered => .discovered,
                .started => .started,
                .partial => |result| .{ .partial = try result.clone(allocator) },
                .final => |result| .{ .final = try result.clone(allocator) },
                .result_message => |result_message| .{ .result_message = try message_memory.cloneToolResultMessage(allocator, result_message) },
            };
        }

        pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .discovered, .started => {},
                .partial => |*result| result.deinit(allocator),
                .final => |*result| result.deinit(allocator),
                .result_message => |*result_message| message_memory.freeToolResultMessage(allocator, result_message),
            }
            self.* = undefined;
        }
    };

    pub const ResultState = struct {
        result: ?protocol.AgentToolResult,
        is_error: bool,

        pub fn clone(self: ResultState, allocator: std.mem.Allocator) !ResultState {
            return .{
                .result = if (self.result) |result| try result.clone(allocator) else null,
                .is_error = self.is_error,
            };
        }

        pub fn deinit(self: *ResultState, allocator: std.mem.Allocator) void {
            if (self.result) |result| result.free(allocator);
            self.* = undefined;
        }
    };

    pub fn clone(self: ToolExecution, allocator: std.mem.Allocator) !ToolExecution {
        const tool_call_id = try allocator.dupe(u8, self.tool_call_id);
        errdefer allocator.free(tool_call_id);
        const tool_name = try allocator.dupe(u8, self.tool_name);
        errdefer allocator.free(tool_name);
        var args = try json_value.OwnedValue.clone(allocator, self.args.borrowed());
        errdefer args.deinit();
        const args_json_source = if (self.args_json_source) |source|
            try allocator.dupe(u8, source)
        else
            null;
        errdefer if (args_json_source) |source| allocator.free(source);
        var state = try self.state.clone(allocator);
        errdefer state.deinit(allocator);

        return .{
            .tool_call_id = tool_call_id,
            .tool_name = tool_name,
            .args = args,
            .args_json_source = args_json_source,
            .args_complete = self.args_complete,
            .state = state,
        };
    }

    pub fn deinit(self: *ToolExecution, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_call_id);
        allocator.free(self.tool_name);
        var args = self.args;
        args.deinit();
        if (self.args_json_source) |source| allocator.free(source);
        self.state.deinit(allocator);
        self.* = undefined;
    }
};

pub const InFlightState = struct {
    allocator: std.mem.Allocator,
    locator: ?FrontierLocator = null,
    assistant: ?protocol.AssistantMessage = null,
    assistant_streaming: bool = false,
    tool_executions: std.ArrayList(ToolExecution) = .empty,

    pub fn init(allocator: std.mem.Allocator) InFlightState {
        return .{
            .allocator = allocator,
            .tool_executions = .empty,
        };
    }

    pub fn deinit(self: *InFlightState) void {
        self.clear();
        self.tool_executions.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn applyEvent(self: *InFlightState, event: protocol.AgentEvent) ApplyEventResult {
        switch (event) {
            .message_start => |payload| switch (payload.message) {
                .assistant => |assistant| {
                    self.replaceAssistant(assistant);
                    self.assistant_streaming = true;
                    return .{ .did_mutate_conversation = true };
                },
                else => return .{},
            },
            .message_update => |payload| switch (payload.message) {
                .assistant => |assistant| {
                    self.replaceAssistant(assistant);
                    self.assistant_streaming = true;
                    switch (payload.assistant_message_event) {
                        .toolcall_end => |tc| self.syncToolCall(tc.tool_call, true, null),
                        else => {},
                    }
                    return .{ .did_mutate_conversation = true };
                },
                else => return .{},
            },
            .message_delta => |payload| {
                switch (payload.assistant_message_event) {
                    .toolcall_end => |tc| self.syncToolCall(tc.tool_call, true, null),
                    else => {},
                }
                return .{ .did_mutate_conversation = true };
            },
            .message_end => |payload| switch (payload.message) {
                .assistant => |assistant| {
                    self.replaceAssistant(assistant);
                    self.assistant_streaming = false;
                    if (assistant.stop_reason != .aborted and assistant.stop_reason != .@"error") {
                        for (assistant.content) |block| switch (block) {
                            .tool_call => |tool_call| self.syncToolCall(tool_call, true, null),
                            else => {},
                        };
                    }
                    return .{ .did_mutate_conversation = true };
                },
                .tool_result => |tool_result| {
                    if (self.isActive()) {
                        self.setResultMessage(tool_result);
                        return .{ .did_mutate_conversation = true };
                    } else {
                        return .{ .immediate_commit = payload.message, .did_mutate_conversation = true };
                    }
                },
                else => return .{ .immediate_commit = payload.message, .did_mutate_conversation = true },
            },
            .tool_execution_start => |payload| {
                if (self.isActive()) {
                    self.markExecutionStarted(payload.tool_call_id, payload.tool_name, payload.args);
                    return .{ .did_mutate_conversation = true };
                }
                return .{};
            },
            .tool_execution_update => |payload| {
                if (self.isActive()) {
                    self.setPartialResult(
                        payload.tool_call_id,
                        payload.partial_result,
                        if (payload.partial_result) |result| result.is_error else false,
                    );
                    return .{ .did_mutate_conversation = true };
                }
                return .{};
            },
            .tool_execution_end => |payload| {
                if (self.isActive()) {
                    self.setFinalResult(payload.tool_call_id, payload.result, payload.is_error);
                    return .{ .did_mutate_conversation = true };
                }
                return .{};
            },
            .turn_end => |payload| switch (payload.message) {
                .assistant => |assistant| {
                    const result: ApplyEventResult = .{
                        .turn_commit = .{
                            .assistant = assistant,
                            .tool_results = payload.tool_results,
                            .error_message = assistant.error_message,
                        },
                        .did_mutate_conversation = true,
                    };
                    self.clear();
                    return result;
                },
                else => return .{},
            },
            .agent_start, .turn_start => {},
            .agent_end => self.assistant_streaming = false,
        }

        return .{};
    }

    pub fn clear(self: *InFlightState) void {
        if (self.assistant) |*assistant| message_memory.freeAssistantMessage(self.allocator, assistant);
        self.locator = null;
        self.assistant = null;
        self.assistant_streaming = false;
        for (self.tool_executions.items) |*tool| tool.deinit(self.allocator);
        self.tool_executions.clearRetainingCapacity();
    }

    pub fn isActive(self: *const InFlightState) bool {
        return self.assistant != null or self.tool_executions.items.len > 0;
    }

    pub fn replaceAssistant(self: *InFlightState, assistant: protocol.AssistantMessage) void {
        if (self.assistant) |*old| message_memory.freeAssistantMessage(self.allocator, old);
        if (self.locator == null) self.locator = FrontierLocator.fromAssistant(assistant);
        self.assistant = message_memory.cloneAssistantMessage(self.allocator, assistant) catch null;
    }

    pub fn syncToolCall(self: *InFlightState, tool_call: ai.protocol.ToolCall, args_complete: bool, delta: ?[]const u8) void {
        const tool = self.ensureTool(tool_call.id, tool_call.name) orelse return;
        tool.args.deinit();
        tool.args = json_value.OwnedValue.clone(self.allocator, tool_call.arguments.borrowed()) catch json_value.OwnedValue.nullValue();
        if (delta) |bytes| {
            const combined = if (tool.args_json_source) |source|
                appendBytesOwned(self.allocator, source, bytes) catch return
            else
                self.allocator.dupe(u8, bytes) catch return;
            if (tool.args_json_source) |source| self.allocator.free(source);
            tool.args_json_source = combined;
            if (bytes.len != 0 or combined.len != 0) {
                tool.args.deinit();
                tool.args = json_value.OwnedValue.adopt(self.allocator, partial_json.parseStreaming(self.allocator, combined) catch .null);
            }
        } else if (args_complete) {
            if (tool.args_json_source) |source| self.allocator.free(source);
            tool.args_json_source = null;
        }
        tool.args_complete = tool.args_complete or args_complete;
    }

    pub fn markExecutionStarted(self: *InFlightState, tool_call_id: []const u8, tool_name: []const u8, args: json_value.BorrowedValue) void {
        const tool = self.ensureTool(tool_call_id, tool_name) orelse return;
        tool.args.deinit();
        tool.args = json_value.OwnedValue.clone(self.allocator, args) catch json_value.OwnedValue.nullValue();
        if (tool.args_json_source) |source| self.allocator.free(source);
        tool.args_json_source = null;
        tool.state.deinit(self.allocator);
        tool.state = .started;
    }

    pub fn setPartialResult(self: *InFlightState, tool_call_id: []const u8, result: ?protocol.AgentToolResult, is_error: bool) void {
        const idx = self.findToolIndex(tool_call_id) orelse return;
        const tool = &self.tool_executions.items[idx];
        const owned_result = if (result) |owned| (owned.clone(self.allocator) catch null) else null;
        tool.state.deinit(self.allocator);
        tool.state = .{ .partial = .{
            .result = owned_result,
            .is_error = if (result) |owned| owned.is_error else is_error,
        } };
    }

    pub fn setFinalResult(self: *InFlightState, tool_call_id: []const u8, result: ?protocol.AgentToolResult, is_error: bool) void {
        const idx = self.findToolIndex(tool_call_id) orelse return;
        const tool = &self.tool_executions.items[idx];
        const owned_result = if (result) |owned| (owned.clone(self.allocator) catch null) else null;
        tool.state.deinit(self.allocator);
        tool.state = .{ .final = .{
            .result = owned_result,
            .is_error = if (result) |owned| owned.is_error else is_error,
        } };
    }

    pub fn setResultMessage(self: *InFlightState, result_message: protocol.ToolResultMessage) void {
        const tool = self.ensureTool(result_message.tool_call_id, result_message.tool_name) orelse return;
        const owned_result_message = message_memory.cloneToolResultMessage(self.allocator, result_message) catch return;
        tool.state.deinit(self.allocator);
        tool.state = .{ .result_message = owned_result_message };
    }

    pub fn freeze(self: *const InFlightState, allocator: std.mem.Allocator) !?InFlightTurn {
        if (!self.isActive()) return null;
        if (self.assistant_streaming) return null;
        if (self.assistant == null) return null;

        var assistant = if (self.assistant) |assistant|
            try message_memory.cloneAssistantMessage(allocator, assistant)
        else
            null;
        errdefer if (assistant) |*owned| message_memory.freeAssistantMessage(allocator, owned);

        const tool_executions = try allocator.alloc(ToolExecution, self.tool_executions.items.len);
        var initialized: usize = 0;
        errdefer {
            for (tool_executions[0..initialized]) |*tool| tool.deinit(allocator);
            allocator.free(tool_executions);
        }

        for (self.tool_executions.items, 0..) |tool, i| {
            tool_executions[i] = try tool.clone(allocator);
            initialized += 1;
        }

        return .{
            .locator = self.locator orelse FrontierLocator.fromAssistant(assistant.?),
            .assistant = assistant,
            .tool_executions = tool_executions,
        };
    }

    fn findToolIndex(self: *const InFlightState, tool_call_id: []const u8) ?usize {
        for (self.tool_executions.items, 0..) |tool, idx| {
            if (std.mem.eql(u8, tool.tool_call_id, tool_call_id)) return idx;
        }
        return null;
    }

    fn ensureTool(self: *InFlightState, tool_call_id: []const u8, tool_name: []const u8) ?*ToolExecution {
        if (self.findToolIndex(tool_call_id)) |idx| return &self.tool_executions.items[idx];

        const owned_id = self.allocator.dupe(u8, tool_call_id) catch return null;
        errdefer self.allocator.free(owned_id);
        const owned_name = self.allocator.dupe(u8, tool_name) catch return null;
        errdefer self.allocator.free(owned_name);

        self.tool_executions.append(self.allocator, .{
            .tool_call_id = owned_id,
            .tool_name = owned_name,
            .args = json_value.OwnedValue.nullValue(),
        }) catch return null;

        return &self.tool_executions.items[self.tool_executions.items.len - 1];
    }
};

fn appendBytesOwned(allocator: std.mem.Allocator, existing: []const u8, extra: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, existing.len + extra.len);
    @memcpy(out[0..existing.len], existing);
    @memcpy(out[existing.len..], extra);
    return out;
}

fn testAssistantMessage() protocol.AssistantMessage {
    return .{
        .content = &.{},
        .api = .openai_responses,
        .provider = .openai,
        .model = "test-model",
        .usage = .{
            .input = 0,
            .output = 0,
            .cache_read = 0,
            .cache_write = 0,
            .total_tokens = 0,
            .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 },
        },
        .stop_reason = .toolUse,
        .timestamp = 1,
    };
}

fn testToolResultMessage() protocol.ToolResultMessage {
    return .{
        .tool_call_id = "tool-1",
        .tool_name = "read",
        .content = &.{.{ .text = .{ .text = "done" } }},
        .is_error = false,
        .timestamp = 2,
    };
}

test "in-flight tool execution state follows event lifecycle" {
    const testing = std.testing;
    var state = InFlightState.init(testing.allocator);
    defer state.deinit();

    _ = state.applyEvent(.{ .message_start = .{ .message = .{ .assistant = testAssistantMessage() } } });
    _ = state.applyEvent(.{ .message_delta = .{ .assistant_message_event = .{ .toolcall_end = .{ .content_index = 0, .tool_call = .{
        .id = "tool-1",
        .name = "read",
        .arguments = json_value.OwnedValue.nullValue(),
        .thought_signature = null,
    } } } } });

    try testing.expectEqual(@as(usize, 1), state.tool_executions.items.len);
    try testing.expect(state.tool_executions.items[0].state == .discovered);

    _ = state.applyEvent(.{ .tool_execution_start = .{
        .tool_call_id = "tool-1",
        .tool_name = "read",
        .args = .null,
    } });
    try testing.expect(state.tool_executions.items[0].state == .started);

    _ = state.applyEvent(.{ .tool_execution_update = .{
        .tool_call_id = "tool-1",
        .tool_name = "read",
        .args = .null,
        .partial_result = .{ .content = &.{.{ .text = .{ .text = "partial" } }}, .is_error = false },
    } });
    switch (state.tool_executions.items[0].state) {
        .partial => |partial| {
            try testing.expect(partial.result != null);
            try testing.expect(!partial.is_error);
        },
        else => return error.ExpectedPartialState,
    }

    _ = state.applyEvent(.{ .tool_execution_end = .{
        .tool_call_id = "tool-1",
        .tool_name = "read",
        .result = .{ .content = &.{.{ .text = .{ .text = "done" } }}, .is_error = false },
        .is_error = false,
    } });
    switch (state.tool_executions.items[0].state) {
        .final => |final| {
            try testing.expect(final.result != null);
            try testing.expect(!final.is_error);
        },
        else => return error.ExpectedFinalState,
    }

    _ = state.applyEvent(.{ .message_end = .{ .message = .{ .tool_result = testToolResultMessage() } } });
    switch (state.tool_executions.items[0].state) {
        .result_message => |result_message| {
            try testing.expectEqualStrings("tool-1", result_message.tool_call_id);
            try testing.expectEqualStrings("read", result_message.tool_name);
        },
        else => return error.ExpectedResultMessageState,
    }
}

test "in-flight tool execution clone owns union state payloads" {
    const testing = std.testing;
    var state = InFlightState.init(testing.allocator);
    defer state.deinit();

    _ = state.applyEvent(.{ .message_start = .{ .message = .{ .assistant = testAssistantMessage() } } });
    _ = state.applyEvent(.{ .tool_execution_start = .{
        .tool_call_id = "tool-1",
        .tool_name = "read",
        .args = .null,
    } });
    _ = state.applyEvent(.{ .tool_execution_update = .{
        .tool_call_id = "tool-1",
        .tool_name = "read",
        .args = .null,
        .partial_result = .{ .content = &.{.{ .text = .{ .text = "partial" } }}, .is_error = false },
    } });

    const cloned = try state.tool_executions.items[0].clone(testing.allocator);
    defer {
        var mutable = cloned;
        mutable.deinit(testing.allocator);
    }

    switch (cloned.state) {
        .partial => |partial| {
            const result = partial.result orelse return error.ExpectedClonedResult;
            try testing.expectEqualStrings("partial", result.content[0].text.text);
            try testing.expect(result.content[0].text.text.ptr != state.tool_executions.items[0].state.partial.result.?.content[0].text.text.ptr);
        },
        else => return error.ExpectedPartialState,
    }
}
