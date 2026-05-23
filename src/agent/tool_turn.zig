const std = @import("std");
const ai = @import("../ai/root.zig");
const message = @import("message.zig");
const tool = @import("../ai/root.zig").tool;
const event = @import("../ai/root.zig").protocol;
const failure = @import("failure.zig"); // ziglint-ignore: Z013
const tool_executor = @import("tool_executor.zig");
const message_memory = @import("../ai/root.zig").message_memory;
const json_value = @import("../json/value.zig");
const config_mod = @import("config.zig");

pub const ToolTurn = struct {
    allocator: std.mem.Allocator,
    tools: []const tool.AgentTool,
    sink: event.AgentEventSink,
    execution_mode: tool.ExecutionMode,
    before_tool_call: ?@import("config.zig").BeforeToolCallHook, // ziglint-ignore: Z028
    after_tool_call: ?@import("config.zig").AfterToolCallHook, // ziglint-ignore: Z028
    context_messages: []const message.AgentMessage,
    signal: @import("../runtime/cancel.zig").Token, // ziglint-ignore: Z028
    executor: tool_executor.Executor,
    next_op_id: tool.ToolOpId = 1,
    prepared: std.ArrayListUnmanaged(PreparedCall) = .empty,
    results: std.ArrayListUnmanaged(message.ToolResultMessage) = .empty,
    terminate_after_batch: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        tools: []const tool.AgentTool,
        sink: event.AgentEventSink,
        execution_mode: tool.ExecutionMode,
        before_tool_call: ?@import("config.zig").BeforeToolCallHook, // ziglint-ignore: Z028
        after_tool_call: ?@import("config.zig").AfterToolCallHook, // ziglint-ignore: Z028
        context_messages: []const message.AgentMessage,
        signal: @import("../runtime/cancel.zig").Token, // ziglint-ignore: Z028
    ) !ToolTurn {
        return .{
            .allocator = allocator,
            .tools = tools,
            .sink = sink,
            .execution_mode = execution_mode,
            .before_tool_call = before_tool_call,
            .after_tool_call = after_tool_call,
            .context_messages = context_messages,
            .signal = signal,
            .executor = try tool_executor.Executor.init(allocator),
        };
    }

    pub fn deinit(self: *ToolTurn) void {
        for (self.prepared.items) |prepared| prepared.deinit(self.allocator);
        for (self.results.items) |result| message_memory.freeToolResult(self.allocator, result);
        self.prepared.deinit(self.allocator);
        self.results.deinit(self.allocator);
        self.executor.deinit();
        self.* = undefined;
    }

    pub fn prepareFromAssistant(self: *ToolTurn, assistant: message.AssistantMessage) !void {
        for (assistant.content) |block| switch (block) {
            .tool_call => |call| {
                const matched = self.findTool(call.name) orelse {
                    try self.appendFailedResult(call.id, call.name, "tool not found");
                    continue;
                };
                if (self.before_tool_call) |before| {
                    if (!before.allow(.{
                        .assistant_message = assistant,
                        .tool_call = call,
                        .args = call.arguments.borrowed(),
                        .context_messages = self.context_messages,
                        .signal = self.signal,
                    })) {
                        try self.appendFailedResult(call.id, call.name, "tool blocked");
                        continue;
                    }
                }
                try self.prepared.append(self.allocator, .{
                    .op_id = self.nextId(),
                    .source_index = self.prepared.items.len,
                    .assistant = assistant,
                    .call = call,
                    .agent_tool = matched,
                    .state = .ready,
                });
            },
            else => {},
        };
    }

    pub fn executeReady(self: *ToolTurn, signal: @import("../runtime/cancel.zig").Token) !void { // ziglint-ignore: Z028
        for (self.prepared.items) |*prepared| {
            if (prepared.state != .ready) continue;
            try self.executor.reserveTerminal();
            prepared.state = .submitted;
            self.sink.emit(.{ .tool_execution_start = .{
                .op_id = prepared.op_id,
                .tool_call_id = prepared.call.id,
                .tool_name = prepared.call.name,
                .args = prepared.call.arguments.borrowed(),
            } });
            prepared.agent_tool.execute(self.allocator, .{
                .op_id = prepared.op_id,
                .source_index = prepared.source_index,
                .tool_call_id = prepared.call.id,
                .tool_name = prepared.call.name,
                .args = prepared.call.arguments.borrowed(),
                .signal = signal,
            }, self.executor.sink());
            if (self.mustExecuteSequential(prepared.agent_tool)) try self.drainCompletions();
        }
    }

    pub fn drainCompletions(self: *ToolTurn) !void {
        while (self.executor.next()) |completion| switch (completion) {
            .update => |update| self.sink.emit(.{ .tool_execution_update = .{
                .op_id = update.op_id,
                .tool_call_id = update.tool_call_id,
                .tool_name = update.tool_name,
                .args = .null,
                .partial_result = update.partial_result,
            } }),
            .terminal => |terminal_const| {
                var terminal = terminal_const;
                if (self.after_tool_call) |after| applyAfterHook(self, after, &terminal, preparedCallByOp(self.prepared.items, terminal.op_id) orelse return error.UnknownToolCompletion); // ziglint-ignore: Z024
                self.sink.emit(.{ .tool_execution_end = .{
                    .op_id = terminal.op_id,
                    .tool_call_id = terminal.tool_call_id,
                    .tool_name = terminal.tool_name,
                    .result = terminalResult(terminal.terminal),
                    .is_error = terminal.terminal != .completed,
                } });
                const prepared = self.findPrepared(terminal.op_id) orelse return error.UnknownToolCompletion;
                std.debug.assert(std.mem.eql(u8, prepared.call.name, terminal.tool_name));
                prepared.state = .{ .terminal = terminal };
            },
        };
        try self.finalizeInSourceOrder();
    }

    pub fn toolResults(self: *const ToolTurn) []const message.ToolResultMessage {
        return self.results.items;
    }

    pub fn shouldTerminate(self: *const ToolTurn) bool {
        return self.terminate_after_batch;
    }

    fn finalizeInSourceOrder(self: *ToolTurn) !void {
        var all_terminate = self.prepared.items.len > 0;
        var index: usize = 0;
        while (index < self.prepared.items.len) : (index += 1) {
            var prepared = &self.prepared.items[index];
            switch (prepared.state) {
                .terminal => |terminal| {
                    all_terminate = all_terminate and terminalResult(terminal.terminal).terminate;
                    try self.results.append(self.allocator, try terminalToMessage(self.allocator, terminal));
                    terminal.deinit(self.allocator);
                    prepared.state = .finalized;
                },
                .finalized => {},
                else => break,
            }
        }
        self.terminate_after_batch = all_terminate and self.results.items.len > 0;
    }

    fn terminalToMessage(allocator: std.mem.Allocator, terminal: tool.ToolTerminalCompletion) !message.ToolResultMessage { // ziglint-ignore: Z024
        const result = switch (terminal.terminal) {
            .completed => |result| result,
            .failed => |result| result,
            .aborted => |result| result,
        };
        const content = try allocator.alloc(ai.protocol.ToolResultMessage.ContentBlock, result.content.len);
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
        for (result.content, 0..) |block, i| {
            content[i] = switch (block) {
                .text => |text| .{ .text = .{ .text = try allocator.dupe(u8, text.text), .text_signature = if (text.text_signature) |sig| try allocator.dupe(u8, sig) else null } }, // ziglint-ignore: Z024
                .image => |image| .{ .image = .{ .data = try allocator.dupe(u8, image.data), .mime_type = try allocator.dupe(u8, image.mime_type) } }, // ziglint-ignore: Z024
            };
            initialized += 1;
        }
        return .{
            .tool_call_id = try allocator.dupe(u8, terminal.tool_call_id),
            .tool_name = try allocator.dupe(u8, terminal.tool_name),
            .content = content,
            .details = try jsonCloneOptional(allocator, result.details),
            .presentation = try jsonCloneOptional(allocator, result.presentation),
            .is_error = result.is_error,
            .timestamp = 0,
        };
    }

    fn appendFailedResult(self: *ToolTurn, tool_call_id: []const u8, tool_name: []const u8, text: []const u8) !void {
        const content = try self.allocator.alloc(ai.protocol.ToolResultMessage.ContentBlock, 1);
        content[0] = .{ .text = .{ .text = try self.allocator.dupe(u8, text) } };
        try self.results.append(self.allocator, .{
            .tool_call_id = try self.allocator.dupe(u8, tool_call_id),
            .tool_name = try self.allocator.dupe(u8, tool_name),
            .content = content,
            .is_error = true,
            .timestamp = 0,
        });
    }

    fn findTool(self: *ToolTurn, name: []const u8) ?tool.AgentTool {
        for (self.tools) |candidate| if (std.mem.eql(u8, candidate.name, name)) return candidate;
        return null;
    }

    fn mustExecuteSequential(self: *const ToolTurn, agent_tool: tool.AgentTool) bool {
        return (agent_tool.execution_mode orelse self.execution_mode) == .sequential;
    }

    fn findPrepared(self: *ToolTurn, op_id: tool.ToolOpId) ?*PreparedCall {
        for (self.prepared.items) |*prepared| if (prepared.op_id == op_id) return prepared;
        return null;
    }

    fn nextId(self: *ToolTurn) tool.ToolOpId {
        const id = self.next_op_id;
        self.next_op_id += 1;
        return id;
    }
};

const PreparedCall = struct {
    op_id: tool.ToolOpId,
    source_index: usize,
    // Borrowed from the assistant message owned by the current Run turn arena.
    // ToolTurn never outlives Run.runOneTurn; only terminal results are owned here.
    assistant: message.AssistantMessage,
    call: message.ToolCall,
    agent_tool: tool.AgentTool,
    state: State,

    const State = union(enum) {
        ready,
        submitted,
        terminal: tool.ToolTerminalCompletion,
        finalized,
    };

    fn deinit(self: PreparedCall, allocator: std.mem.Allocator) void {
        switch (self.state) {
            .terminal => |terminal| terminal.deinit(allocator),
            else => {},
        }
    }
};

fn jsonCloneOrNull(allocator: std.mem.Allocator, value: json_value.OwnedValue) !?json_value.OwnedValue {
    if (value.borrowed() == .null) return null;
    return try json_value.OwnedValue.clone(allocator, value.borrowed()); // ziglint-ignore: Z017
}

fn jsonCloneOptional(allocator: std.mem.Allocator, value: ?json_value.OwnedValue) !?json_value.OwnedValue {
    const owned = value orelse return null;
    return jsonCloneOrNull(allocator, owned);
}

fn terminalResult(terminal: tool.ToolTerminal) tool.AgentToolResult {
    return switch (terminal) {
        .completed => |result| result,
        .failed => |result| result,
        .aborted => |result| result,
    };
}

fn preparedCallByOp(prepared: []PreparedCall, op_id: tool.ToolOpId) ?PreparedCall {
    for (prepared) |call| if (call.op_id == op_id) return call;
    return null;
}

fn applyAfterHook(self: *ToolTurn, hook: @import("config.zig").AfterToolCallHook, terminal: *tool.ToolTerminalCompletion, prepared: PreparedCall) void { // ziglint-ignore: Z024, Z028
    switch (terminal.terminal) {
        .completed => |*result| hook.apply(.{
            .assistant_message = prepared.assistant,
            .tool_call = prepared.call,
            .args = prepared.call.arguments.borrowed(),
            .result = result,
            .is_error = false,
            .context_messages = self.context_messages,
            .signal = self.signal,
        }),
        .failed => |*result| hook.apply(.{
            .assistant_message = prepared.assistant,
            .tool_call = prepared.call,
            .args = prepared.call.arguments.borrowed(),
            .result = result,
            .is_error = true,
            .context_messages = self.context_messages,
            .signal = self.signal,
        }),
        .aborted => |*result| hook.apply(.{
            .assistant_message = prepared.assistant,
            .tool_call = prepared.call,
            .args = prepared.call.arguments.borrowed(),
            .result = result,
            .is_error = true,
            .context_messages = self.context_messages,
            .signal = self.signal,
        }),
    }
}

fn noopEvent(_: event.AgentEvent, _: ?*anyopaque) void {}

fn completeTool(_: ?*anyopaque, _: std.mem.Allocator, invocation: tool.ToolInvocation, sink: tool.ToolCompletionSink) void { // ziglint-ignore: Z024, Z023
    var completion = tool.ToolCompletion{ .terminal = .{ // ziglint-ignore: Z004
        .op_id = invocation.op_id,
        .source_index = invocation.source_index,
        .tool_call_id = invocation.tool_call_id,
        .tool_name = invocation.tool_name,
        .terminal = .{ .completed = .{ .content = &.{}, .is_error = false } },
    } };
    sink.emit(&completion);
}

fn testToolUseAssistant() message.AssistantMessage {
    return .{
        .content = &.{.{ .tool_call = .{ .id = "tool-1", .name = "read", .arguments = json_value.OwnedValue.nullValue() } }}, // ziglint-ignore: Z024
        .api = .openai_responses,
        .provider = .openai,
        .model = "test",
        .usage = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total_tokens = 0, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 } }, // ziglint-ignore: Z024
        .stop_reason = .toolUse,
        .timestamp = 0,
    };
}

test "tool turn executes and finalizes tool result" {
    var turn = try ToolTurn.init(
        std.testing.allocator,
        &.{.{ .name = "read", .description = "", .parameters = .null, .execute_fn = completeTool }},
        .{ .emit_fn = noopEvent },
        .parallel,
        null,
        null,
        &.{},
        .none,
    );
    defer turn.deinit();
    try turn.prepareFromAssistant(.{
        .content = &.{.{ .tool_call = .{ .id = "tool-1", .name = "read", .arguments = json_value.OwnedValue.nullValue() } }}, // ziglint-ignore: Z024
        .api = .openai_responses,
        .provider = .openai,
        .model = "test",
        .usage = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total_tokens = 0, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 } }, // ziglint-ignore: Z024
        .stop_reason = .toolUse,
        .timestamp = 0,
    });
    try turn.executeReady(.none);
    try turn.drainCompletions();
    try std.testing.expectEqual(@as(usize, 1), turn.toolResults().len);
    try std.testing.expectEqualStrings("tool-1", turn.toolResults()[0].tool_call_id);
}

test "tool turn before hook blocks execution with context" {
    const Hook = struct {
        fn before(ctx: ?*anyopaque, context: config_mod.BeforeToolCallContext) bool {
            const saw: *bool = @ptrCast(@alignCast(ctx.?));
            saw.* = std.mem.eql(u8, context.tool_call.name, "read") and context.context_messages.len == 0;
            return false;
        }
    };
    var saw_context = false;
    var turn = try ToolTurn.init(
        std.testing.allocator,
        &.{.{ .name = "read", .description = "", .parameters = .null, .execute_fn = completeTool }},
        .{ .emit_fn = noopEvent },
        .parallel,
        .{ .ctx = &saw_context, .call_fn = Hook.before },
        null,
        &.{},
        .none,
    );
    defer turn.deinit();
    try turn.prepareFromAssistant(testToolUseAssistant());
    try std.testing.expect(saw_context);
    try std.testing.expectEqual(@as(usize, 1), turn.toolResults().len);
    try std.testing.expect(turn.toolResults()[0].is_error);
}

test "tool turn after hook can override result and terminate batch" {
    const Hook = struct {
        fn after(_: ?*anyopaque, context: config_mod.AfterToolCallContext) void {
            context.result.is_error = true;
            context.result.terminate = true;
        }
    };
    var turn = try ToolTurn.init(
        std.testing.allocator,
        &.{.{ .name = "read", .description = "", .parameters = .null, .execute_fn = completeTool }},
        .{ .emit_fn = noopEvent },
        .parallel,
        null,
        .{ .call_fn = Hook.after },
        &.{},
        .none,
    );
    defer turn.deinit();
    try turn.prepareFromAssistant(testToolUseAssistant());
    try turn.executeReady(.none);
    try turn.drainCompletions();
    try std.testing.expect(turn.shouldTerminate());
    try std.testing.expect(turn.toolResults()[0].is_error);
}
