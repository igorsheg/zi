const std = @import("std");
const ai = @import("../ai/root.zig");
const message = @import("message.zig");
const tool = @import("tool.zig");
const event = @import("event.zig");
const failure = @import("failure.zig");
const tool_executor = @import("tool_executor.zig");
const message_memory = @import("message_memory.zig");
const json_value = @import("../json/value.zig");

pub const ToolTurn = struct {
    allocator: std.mem.Allocator,
    tools: []const tool.AgentTool,
    sink: event.Sink,
    executor: tool_executor.Executor,
    next_op_id: tool.ToolOpId = 1,
    prepared: std.ArrayListUnmanaged(PreparedCall) = .empty,
    results: std.ArrayListUnmanaged(message.ToolResultMessage) = .empty,

    pub fn init(allocator: std.mem.Allocator, tools: []const tool.AgentTool, sink: event.Sink) !ToolTurn {
        return .{ .allocator = allocator, .tools = tools, .sink = sink, .executor = try tool_executor.Executor.init(allocator) };
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
                try self.prepared.append(self.allocator, .{
                    .op_id = self.nextId(),
                    .source_index = self.prepared.items.len,
                    .call = call,
                    .agent_tool = matched,
                    .state = .ready,
                });
            },
            else => {},
        };
    }

    pub fn executeReady(self: *ToolTurn, signal: @import("../runtime/cancel.zig").Token) !void {
        for (self.prepared.items) |*prepared| {
            if (prepared.state != .ready) continue;
            try self.executor.reserveTerminal();
            prepared.state = .submitted;
            self.sink.emit(.{ .tool = .{ .started = .{ .op_id = prepared.op_id, .tool_call_id = prepared.call.id, .tool_name = prepared.call.name } } });
            prepared.agent_tool.execute(self.allocator, .{
                .op_id = prepared.op_id,
                .source_index = prepared.source_index,
                .tool_call_id = prepared.call.id,
                .tool_name = prepared.call.name,
                .args = prepared.call.arguments.borrowed(),
                .signal = signal,
            }, self.executor.sink());
        }
    }

    pub fn drainCompletions(self: *ToolTurn) !void {
        while (self.executor.next()) |completion| switch (completion) {
            .update => |update| self.sink.emit(.{ .tool = .{ .update = update } }),
            .terminal => |terminal| {
                self.sink.emit(.{ .tool = .{ .finished = terminal } });
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

    fn finalizeInSourceOrder(self: *ToolTurn) !void {
        var index: usize = 0;
        while (index < self.prepared.items.len) : (index += 1) {
            var prepared = &self.prepared.items[index];
            switch (prepared.state) {
                .terminal => |terminal| {
                    try self.results.append(self.allocator, try terminalToMessage(self.allocator, terminal));
                    terminal.deinit(self.allocator);
                    prepared.state = .finalized;
                },
                .finalized => {},
                else => break,
            }
        }
    }

    fn terminalToMessage(allocator: std.mem.Allocator, terminal: tool.ToolTerminalCompletion) !message.ToolResultMessage {
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
                .text => |text| .{ .text = .{ .text = try allocator.dupe(u8, text.text), .text_signature = if (text.text_signature) |sig| try allocator.dupe(u8, sig) else null } },
                .image => |image| .{ .image = .{ .data = try allocator.dupe(u8, image.data), .mime_type = try allocator.dupe(u8, image.mime_type) } },
            };
            initialized += 1;
        }
        return .{
            .tool_call_id = try allocator.dupe(u8, terminal.tool_call_id),
            .tool_name = try allocator.dupe(u8, terminal.tool_name),
            .content = content,
            .details = try jsonCloneOrNull(allocator, result.details),
            .presentation = try jsonCloneOrNull(allocator, result.presentation),
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
    return try json_value.OwnedValue.clone(allocator, value.borrowed());
}

fn noopEvent(_: event.AgentEvent, _: ?*anyopaque) void {}

fn completeTool(_: ?*anyopaque, _: std.mem.Allocator, invocation: tool.ToolInvocation, sink: tool.ToolCompletionSink) void {
    sink.emit(.{ .terminal = .{
        .op_id = invocation.op_id,
        .source_index = invocation.source_index,
        .tool_call_id = invocation.tool_call_id,
        .tool_name = invocation.tool_name,
        .terminal = .{ .completed = .{ .content = &.{}, .is_error = false } },
    } });
}

test "tool turn executes and finalizes tool result" {
    var turn = try ToolTurn.init(std.testing.allocator, &.{.{ .name = "read", .description = "", .parameters = .null, .execute_fn = completeTool }}, .{ .emit_fn = noopEvent });
    defer turn.deinit();
    try turn.prepareFromAssistant(.{
        .content = &.{.{ .tool_call = .{ .id = "tool-1", .name = "read", .arguments = json_value.OwnedValue.nullValue() } }},
        .api = .openai_responses,
        .provider = .openai,
        .model = "test",
        .usage = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total_tokens = 0, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 } },
        .stop_reason = .toolUse,
        .timestamp = 0,
    });
    try turn.executeReady(.none);
    try turn.drainCompletions();
    try std.testing.expectEqual(@as(usize, 1), turn.toolResults().len);
    try std.testing.expectEqualStrings("tool-1", turn.toolResults()[0].tool_call_id);
}
