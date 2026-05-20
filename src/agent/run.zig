const std = @import("std");
const ai = @import("../ai/root.zig");
const cancel = @import("../runtime/cancel.zig");
const message = @import("message.zig");
const event = @import("event.zig");
const failure = @import("failure.zig");
const config_mod = @import("config.zig");
const stream_mod = @import("stream.zig");
const stream_op_mod = @import("stream_op.zig");
const tool_turn_mod = @import("tool_turn.zig");
const message_memory = @import("message_memory.zig");

pub const max_turns: usize = 32;

pub const Run = struct {
    allocator: std.mem.Allocator,
    input: message.AgentInput,
    sink: event.Sink,
    signal: cancel.Token,
    state: State = .init,
    messages: std.ArrayListUnmanaged(message.AgentMessage) = .empty,
    owned_messages_start: usize = 0,
    run_terminal_emitted: bool = false,
    turn_open: bool = false,

    pub const State = union(enum) {
        init,
        streaming,
        executing_tools,
        completed,
        failed: failure.Failure,
        aborted,
    };

    pub fn init(allocator: std.mem.Allocator, input: message.AgentInput, sink: event.Sink, signal: cancel.Token) Run {
        return .{ .allocator = allocator, .input = input, .sink = sink, .signal = signal };
    }

    pub fn deinit(self: *Run) void {
        for (self.messages.items[self.owned_messages_start..]) |msg| message_memory.freeMessage(self.allocator, msg);
        self.messages.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn start(self: *Run) !void {
        std.debug.assert(self.state == .init);
        try self.messages.appendSlice(self.allocator, self.input.messages);
        self.owned_messages_start = self.messages.items.len;
        self.sink.emit(.{ .lifecycle = .run_started });
    }

    pub fn runStream(self: *Run, config: config_mod.RunConfig) void {
        self.start() catch |err| {
            self.finishRunFailed(.{ .out_of_memory = @errorName(err) });
            return;
        };
        if (self.observeCancellation()) return;

        var turn_count: usize = 0;
        while (!self.isTerminal()) {
            if (turn_count >= max_turns) {
                self.finishRunFailed(.{ .tool_protocol_violation = "maximum agent turns exceeded" });
                return;
            }
            turn_count += 1;
            self.runOneTurn(config) catch |err| {
                self.finishRunFailed(.{ .internal = @errorName(err) });
                return;
            };
        }
    }

    fn runOneTurn(self: *Run, config: config_mod.RunConfig) !void {
        var turn_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer turn_arena.deinit();
        const turn_allocator = turn_arena.allocator();

        self.beginTurn();
        if (self.observeCancellation()) return;
        self.state = .streaming;

        const llm_messages = config.convert_messages.call(turn_allocator, self.messages.items) catch |err| {
            self.finishTurnFailed(.{ .out_of_memory = @errorName(err) });
            self.finishRunFailed(.{ .out_of_memory = @errorName(err) });
            return;
        };
        const protocol_tools = try protocolTools(turn_allocator, self.input.tools);
        const context = ai.protocol.Context{
            .system_prompt = self.input.system_prompt,
            .messages = llm_messages,
            .tools = protocol_tools,
        };

        var stream_op = stream_op_mod.StreamOp.init(self.allocator) catch |err| {
            self.finishTurnFailed(.{ .out_of_memory = @errorName(err) });
            self.finishRunFailed(.{ .out_of_memory = @errorName(err) });
            return;
        };
        defer stream_op.deinit();

        if (self.observeCancellation()) return;
        stream_op.start(config.stream, config.model, context, config.streamOptions());
        while (stream_op.next()) |completion| {
            if (self.observeCancellation()) return;
            try self.applyStreamCompletion(completion);
            if (!self.turn_open or self.isTerminal()) return;
        }

        if (!self.isTerminal()) {
            self.finishTurnFailed(.{ .stream_failed = "stream completed without terminal completion" });
            self.finishRunFailed(.{ .stream_failed = "stream completed without terminal completion" });
        }
    }

    fn applyStreamCompletion(self: *Run, completion: stream_mod.Completion) !void {
        switch (completion) {
            .started => self.sink.emit(.{ .message = .started }),
            .delta => |delta| self.sink.emit(.{ .message = .{ .delta = delta } }),
            .terminal => |terminal| switch (terminal) {
                .completed => |assistant| try self.finishAssistantTurn(assistant),
                .failed => |reason| {
                    self.finishTurnFailed(reason);
                    self.finishRunFailed(reason);
                },
                .aborted => self.finishRunAborted(),
            },
        }
    }

    fn finishAssistantTurn(self: *Run, assistant: message.AssistantMessage) !void {
        if (assistant.stop_reason != .toolUse) {
            try self.commitAssistantAndTools(assistant, &.{});
            self.finishRunCompleted();
            return;
        }

        self.state = .executing_tools;
        var tool_turn = tool_turn_mod.ToolTurn.init(self.allocator, self.input.tools, self.sink) catch |err| {
            self.finishTurnFailed(.{ .out_of_memory = @errorName(err) });
            self.finishRunFailed(.{ .out_of_memory = @errorName(err) });
            return;
        };
        defer tool_turn.deinit();
        try tool_turn.prepareFromAssistant(assistant);
        if (self.observeCancellation()) return;
        try tool_turn.executeReady(self.signal);
        if (self.observeCancellation()) return;
        try tool_turn.drainCompletions();
        if (tool_turn.toolResults().len == 0) {
            self.finishTurnFailed(.{ .tool_protocol_violation = "tool-use assistant produced no tool results" });
            self.finishRunFailed(.{ .tool_protocol_violation = "tool-use assistant produced no tool results" });
            return;
        }
        try self.commitAssistantAndTools(assistant, tool_turn.toolResults());
    }

    fn commitAssistantAndTools(self: *Run, assistant: message.AssistantMessage, tool_results: []const message.ToolResultMessage) !void {
        std.debug.assert(self.turn_open);
        const msg = message.AgentMessage{ .assistant = assistant };
        try self.messages.append(self.allocator, msg);
        for (tool_results) |tool_result| {
            try self.messages.append(self.allocator, try message_memory.cloneMessage(self.allocator, .{ .tool_result = tool_result }));
        }
        self.sink.emit(.{ .message = .{ .finished = assistant } });
        self.sink.emit(.{ .lifecycle = .{ .turn_finished = .{ .completed = .{ .message = msg, .tool_results = tool_results } } } });
        self.turn_open = false;
    }

    fn beginTurn(self: *Run) void {
        std.debug.assert(!self.turn_open);
        self.sink.emit(.{ .lifecycle = .turn_started });
        self.turn_open = true;
    }

    fn finishTurnFailed(self: *Run, reason: failure.Failure) void {
        if (!self.turn_open) return;
        self.sink.emit(.{ .lifecycle = .{ .turn_finished = .{ .failed = .{ .message = null, .tool_results = &.{}, .reason = reason } } } });
        self.turn_open = false;
    }

    fn finishTurnAborted(self: *Run) void {
        if (!self.turn_open) return;
        self.sink.emit(.{ .lifecycle = .{ .turn_finished = .{ .aborted = .{ .message = null, .tool_results = &.{} } } } });
        self.turn_open = false;
    }

    fn finishRunCompleted(self: *Run) void {
        if (self.run_terminal_emitted) return;
        self.sink.emit(.{ .lifecycle = .{ .run_finished = .{ .completed = .{ .messages = self.messages.items } } } });
        self.run_terminal_emitted = true;
        self.state = .completed;
    }

    fn finishRunFailed(self: *Run, reason: failure.Failure) void {
        if (self.run_terminal_emitted) return;
        self.sink.emit(.{ .lifecycle = .{ .run_finished = .{ .failed = .{ .messages = self.messages.items, .reason = reason } } } });
        self.run_terminal_emitted = true;
        self.state = .{ .failed = reason };
    }

    fn finishRunAborted(self: *Run) void {
        if (self.run_terminal_emitted) return;
        self.finishTurnAborted();
        self.sink.emit(.{ .lifecycle = .{ .run_finished = .{ .aborted = .{ .messages = self.messages.items } } } });
        self.run_terminal_emitted = true;
        self.state = .aborted;
    }

    fn isTerminal(self: *const Run) bool {
        return switch (self.state) {
            .completed, .failed, .aborted => true,
            else => false,
        };
    }

    fn observeCancellation(self: *Run) bool {
        if (!self.signal.isAborted()) return false;
        self.finishRunAborted();
        return true;
    }
};

fn protocolTools(allocator: std.mem.Allocator, tools: []const @import("tool.zig").AgentTool) !?[]const ai.protocol.Tool {
    if (tools.len == 0) return null;
    const out = try allocator.alloc(ai.protocol.Tool, tools.len);
    for (tools, 0..) |tool, i| {
        out[i] = .{ .name = tool.name, .description = tool.description, .parameters = tool.parameters };
    }
    return out;
}

fn testModel() message.Model {
    return .{
        .id = "test",
        .name = "test",
        .api = .openai_responses,
        .provider = .openai,
        .base_url = "",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 0,
        .max_tokens = 0,
    };
}

fn testAssistant() message.AssistantMessage {
    return .{
        .content = &.{},
        .api = .openai_responses,
        .provider = .openai,
        .model = "test",
        .usage = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total_tokens = 0, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 } },
        .stop_reason = .stop,
        .timestamp = 0,
    };
}

fn testToolUseAssistant() message.AssistantMessage {
    return .{
        .content = &test_tool_content,
        .api = .openai_responses,
        .provider = .openai,
        .model = "test",
        .usage = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total_tokens = 0, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 } },
        .stop_reason = .toolUse,
        .timestamp = 0,
    };
}

const test_tool_content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{.{ .tool_call = test_tool_call }};
const test_tool_call = message.ToolCall{ .id = "tool-1", .name = "read", .arguments = @import("../json/value.zig").OwnedValue.nullValue() };

fn convertNoop(_: ?*anyopaque, _: std.mem.Allocator, _: []const message.AgentMessage) error{OutOfMemory}![]const ai.protocol.Message {
    return &.{};
}

const Collector = struct {
    run_terminals: usize = 0,
    turn_terminals: usize = 0,
    message_deltas: usize = 0,
    completed: bool = false,
    failed: bool = false,
    aborted: bool = false,

    fn emit(value: event.AgentEvent, ctx: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        switch (value) {
            .message => |msg| switch (msg) {
                .delta => self.message_deltas += 1,
                else => {},
            },
            .lifecycle => |lifecycle| switch (lifecycle) {
                .turn_finished => self.turn_terminals += 1,
                .run_finished => |terminal| {
                    self.run_terminals += 1;
                    switch (terminal) {
                        .completed => self.completed = true,
                        .failed => self.failed = true,
                        .aborted => self.aborted = true,
                    }
                },
                else => {},
            },
            else => {},
        }
    }
};

fn configWithStream(comptime stream_fn: anytype) config_mod.RunConfig {
    return .{
        .model = testModel(),
        .stream = .{ .call_fn = stream_fn },
        .convert_messages = .{ .call_fn = convertNoop },
        .io = std.testing.io,
    };
}

test "run drains stream completion and emits completed terminal" {
    const Hook = struct {
        fn call(_: ?*anyopaque, _: std.mem.Allocator, _: message.Model, _: ai.protocol.Context, _: ai.protocol.SimpleStreamOptions, sink: ai.provider.StreamEventSink) error{OutOfMemory}!void {
            sink.emit(.{ .done = .{ .reason = .stop, .message = testAssistant() } });
        }
    };

    var collector = Collector{};
    var run = Run.init(std.testing.allocator, .{ .system_prompt = "", .messages = &.{} }, .{ .emit_fn = Collector.emit, .ctx = &collector }, .none);
    defer run.deinit();
    run.runStream(configWithStream(Hook.call));

    try std.testing.expectEqual(@as(usize, 1), collector.run_terminals);
    try std.testing.expectEqual(@as(usize, 1), collector.turn_terminals);
    try std.testing.expect(collector.completed);
    try std.testing.expect(run.state == .completed);
}

test "run forwards stream deltas before terminal" {
    const Hook = struct {
        fn call(_: ?*anyopaque, _: std.mem.Allocator, _: message.Model, _: ai.protocol.Context, _: ai.protocol.SimpleStreamOptions, sink: ai.provider.StreamEventSink) error{OutOfMemory}!void {
            sink.emit(.start);
            sink.emit(.{ .text_delta = .{ .content_index = 0, .delta = "hi" } });
            sink.emit(.{ .done = .{ .reason = .stop, .message = testAssistant() } });
        }
    };

    var collector = Collector{};
    var run = Run.init(std.testing.allocator, .{ .system_prompt = "", .messages = &.{} }, .{ .emit_fn = Collector.emit, .ctx = &collector }, .none);
    defer run.deinit();
    run.runStream(configWithStream(Hook.call));

    try std.testing.expect(collector.message_deltas >= 1);
    try std.testing.expectEqual(@as(usize, 1), collector.run_terminals);
}

test "run emits failed terminal when stream has no terminal" {
    const Hook = struct {
        fn call(_: ?*anyopaque, _: std.mem.Allocator, _: message.Model, _: ai.protocol.Context, _: ai.protocol.SimpleStreamOptions, _: ai.provider.StreamEventSink) error{OutOfMemory}!void {}
    };

    var collector = Collector{};
    var run = Run.init(std.testing.allocator, .{ .system_prompt = "", .messages = &.{} }, .{ .emit_fn = Collector.emit, .ctx = &collector }, .none);
    defer run.deinit();
    run.runStream(configWithStream(Hook.call));

    try std.testing.expectEqual(@as(usize, 1), collector.run_terminals);
    try std.testing.expect(collector.failed);
}

test "run observes cancellation before stream start" {
    const Hook = struct {
        fn call(_: ?*anyopaque, _: std.mem.Allocator, _: message.Model, _: ai.protocol.Context, _: ai.protocol.SimpleStreamOptions, _: ai.provider.StreamEventSink) error{OutOfMemory}!void {
            return error.OutOfMemory;
        }
    };

    var source = cancel.Source{};
    const signal = source.beginRun();
    source.requestAbort();

    var collector = Collector{};
    var run = Run.init(std.testing.allocator, .{ .system_prompt = "", .messages = &.{} }, .{ .emit_fn = Collector.emit, .ctx = &collector }, signal);
    defer run.deinit();
    run.runStream(configWithStream(Hook.call));

    try std.testing.expectEqual(@as(usize, 1), collector.run_terminals);
    try std.testing.expect(collector.aborted);
    try std.testing.expect(run.state == .aborted);
}

fn completeRead(_: ?*anyopaque, _: std.mem.Allocator, invocation: @import("tool.zig").ToolInvocation, sink: @import("tool.zig").ToolCompletionSink) void {
    var completion = @import("tool.zig").ToolCompletion{ .terminal = .{
        .op_id = invocation.op_id,
        .source_index = invocation.source_index,
        .tool_call_id = invocation.tool_call_id,
        .tool_name = invocation.tool_name,
        .terminal = .{ .completed = .{ .content = &.{}, .is_error = false } },
    } };
    sink.emit(&completion);
}

test "run executes tool turn then continues to final assistant" {
    const Hook = struct {
        calls: usize = 0,
        fn call(ctx: ?*anyopaque, _: std.mem.Allocator, _: message.Model, _: ai.protocol.Context, _: ai.protocol.SimpleStreamOptions, sink: ai.provider.StreamEventSink) error{OutOfMemory}!void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            if (self.calls == 1) {
                sink.emit(.{ .done = .{ .reason = .toolUse, .message = testToolUseAssistant() } });
            } else {
                sink.emit(.{ .done = .{ .reason = .stop, .message = testAssistant() } });
            }
        }
    };

    var hook = Hook{};
    var collector = Collector{};
    const tools = [_]@import("tool.zig").AgentTool{.{ .name = "read", .description = "", .parameters = .null, .execute_fn = completeRead }};
    var run = Run.init(std.testing.allocator, .{
        .system_prompt = "",
        .messages = &.{},
        .tools = &tools,
    }, .{ .emit_fn = Collector.emit, .ctx = &collector }, .none);
    defer run.deinit();
    var cfg = configWithStream(Hook.call);
    cfg.stream.ctx = &hook;
    run.runStream(cfg);

    try std.testing.expectEqual(@as(usize, 1), collector.run_terminals);
    try std.testing.expectEqual(@as(usize, 2), collector.turn_terminals);
    try std.testing.expect(collector.completed);
    try std.testing.expectEqual(@as(usize, 3), run.messages.items.len);
    try std.testing.expect(run.messages.items[0] == .assistant);
    try std.testing.expect(run.messages.items[1] == .tool_result);
    try std.testing.expect(run.messages.items[2] == .assistant);
}
