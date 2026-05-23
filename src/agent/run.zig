const std = @import("std");
const ai = @import("../ai/root.zig");
const cancel = @import("../runtime/cancel.zig");
const message = @import("message.zig");
const event = @import("../ai/root.zig").protocol;
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
    sink: event.AgentEventSink,
    signal: cancel.Token,
    state: State = .init,
    messages: std.ArrayListUnmanaged(message.AgentMessage) = .empty,
    owned_messages_start: usize = 0,
    run_terminal_emitted: bool = false,
    turn_open: bool = false,
    active_model: ?message.Model = null,

    pub const State = union(enum) {
        init,
        streaming,
        executing_tools,
        completed,
        failed: failure.Failure,
        aborted,
    };

    pub fn init(allocator: std.mem.Allocator, input: message.AgentInput, sink: event.AgentEventSink, signal: cancel.Token) Run { // ziglint-ignore: Z024
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
        self.sink.emit(.agent_start);
    }

    pub fn runStream(self: *Run, config: config_mod.RunConfig) void {
        self.active_model = config.model;
        self.start() catch |err| {
            self.finishRunFailed(.{ .out_of_memory = @errorName(err) });
            return;
        };
        if (self.observeCancellation()) return;

        var turn_count: usize = 0;
        while (!self.isTerminal()) {
            if (turn_count >= max_turns) {
                self.finishTurnFailed(.{ .tool_protocol_violation = "maximum agent turns exceeded" });
                self.finishRunFailed(.{ .tool_protocol_violation = "maximum agent turns exceeded" });
                return;
            }
            turn_count += 1;
            self.runOneTurn(config) catch |err| {
                self.finishTurnFailed(.{ .internal = @errorName(err) });
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

        const agent_messages = if (config.transform_context) |transform|
            transform.call(turn_allocator, self.messages.items) catch |err| {
                self.finishTurnFailed(.{ .out_of_memory = @errorName(err) });
                self.finishRunFailed(.{ .out_of_memory = @errorName(err) });
                return;
            }
        else
            self.messages.items;

        const llm_messages = config.convert_messages.call(turn_allocator, agent_messages) catch |err| {
            self.finishTurnFailed(.{ .out_of_memory = @errorName(err) });
            self.finishRunFailed(.{ .out_of_memory = @errorName(err) });
            return;
        };
        const protocol_tools = try protocolTools(turn_allocator, self.input.tools);
        const context = ai.protocol.Context{ // ziglint-ignore: Z004
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
            try self.applyStreamCompletion(completion, config);
            if (!self.turn_open or self.isTerminal()) return;
        }

        if (!self.isTerminal()) {
            self.finishTurnFailed(.{ .stream_failed = "stream completed without terminal completion" });
            self.finishRunFailed(.{ .stream_failed = "stream completed without terminal completion" });
        }
    }

    fn applyStreamCompletion(self: *Run, completion: stream_mod.Completion, config: config_mod.RunConfig) !void {
        switch (completion) {
            .started => {},
            .delta => |delta| {
                defer message_memory.freeAssistantEvent(self.allocator, delta);
                self.sink.emit(.{ .message_update = .{ .assistant_message_event = delta } });
            },
            .terminal => |terminal| switch (terminal) {
                .completed => |assistant| try self.finishAssistantTurn(assistant, config),
                .failed => |reason| {
                    self.finishTurnFailed(reason);
                    self.finishRunFailed(reason);
                },
                .aborted => self.finishRunAborted(),
            },
        }
    }

    fn finishAssistantTurn(self: *Run, assistant: message.AssistantMessage, config: config_mod.RunConfig) !void {
        if (assistant.stop_reason != .toolUse) {
            try self.commitAssistantAndTools(assistant, &.{});
            if (try self.pollMessageSource(config.follow_up_messages)) return;
            self.finishRunCompleted();
            return;
        }

        self.state = .executing_tools;
        var tool_turn = tool_turn_mod.ToolTurn.init(
            self.allocator,
            self.input.tools,
            self.sink,
            config.tool_execution,
            config.before_tool_call,
            config.after_tool_call,
            self.messages.items,
            self.signal,
        ) catch |err| {
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
        if (tool_turn.shouldTerminate()) {
            self.finishRunCompleted();
            return;
        }
        _ = try self.pollMessageSource(config.steering_messages);
    }

    fn pollMessageSource(self: *Run, source: ?config_mod.MessageSourceHook) !bool {
        const hook = source orelse return false;
        const messages = try hook.call(self.allocator);
        defer freeOwnedMessages(self.allocator, messages);
        if (messages.len == 0) return false;
        for (messages) |msg| {
            try self.messages.append(self.allocator, try message_memory.cloneMessage(self.allocator, msg));
            self.sink.emit(.{ .message_start = .{ .message = msg } });
            self.sink.emit(.{ .message_end = .{ .message = msg } });
        }
        return true;
    }

    fn commitAssistantAndTools(self: *Run, assistant: message.AssistantMessage, tool_results: []const message.ToolResultMessage) !void { // ziglint-ignore: Z024
        std.debug.assert(self.turn_open);
        const msg = message.AgentMessage{ .assistant = assistant }; // ziglint-ignore: Z004
        try self.messages.append(self.allocator, msg);
        for (tool_results) |tool_result| {
            try self.messages.append(self.allocator, try message_memory.cloneMessage(self.allocator, .{ .tool_result = tool_result })); // ziglint-ignore: Z024
        }
        self.sink.emit(.{ .message_end = .{ .message = msg } });
        self.sink.emit(.{ .turn_end = .{ .completed = .{ .message = msg, .tool_results = tool_results } } });
        self.turn_open = false;
    }

    fn beginTurn(self: *Run) void {
        std.debug.assert(!self.turn_open);
        self.sink.emit(.turn_start);
        self.turn_open = true;
    }

    fn finishTurnFailed(self: *Run, reason: failure.Failure) void {
        if (!self.turn_open) return;
        self.sink.emit(.{ .turn_end = .{ .failed = .{ .reason = failureMessage(reason) } } });
        self.turn_open = false;
    }

    fn finishTurnAborted(self: *Run) void {
        if (!self.turn_open) return;
        self.sink.emit(.{ .turn_end = .{ .aborted = .{} } });
        self.turn_open = false;
    }

    fn finishRunCompleted(self: *Run) void {
        if (self.run_terminal_emitted) return;
        self.sink.emit(.{ .agent_end = .{ .completed = .{ .messages = self.messages.items } } });
        self.run_terminal_emitted = true;
        self.state = .completed;
    }

    fn finishRunFailed(self: *Run, reason: failure.Failure) void {
        if (self.run_terminal_emitted) return;
        self.appendFailureAssistant(.@"error", failureMessage(reason)) catch |err| {
            std.log.scoped(.agent).err("failed to append failure assistant: {s}", .{@errorName(err)});
        };
        self.sink.emit(.{ .agent_end = .{ .failed = .{ .messages = self.messages.items, .reason = failureMessage(reason) } } }); // ziglint-ignore: Z024
        self.run_terminal_emitted = true;
        self.state = .{ .failed = reason };
    }

    fn finishRunAborted(self: *Run) void {
        if (self.run_terminal_emitted) return;
        self.finishTurnAborted();
        self.appendFailureAssistant(.aborted, "aborted") catch |err| {
            std.log.scoped(.agent).err("failed to append aborted assistant: {s}", .{@errorName(err)});
        };
        self.sink.emit(.{ .agent_end = .{ .aborted = .{ .messages = self.messages.items } } });
        self.run_terminal_emitted = true;
        self.state = .aborted;
    }

    fn appendFailureAssistant(self: *Run, stop_reason: ai.protocol.StopReason, error_message: []const u8) !void {
        const model = self.active_model orelse return;
        const assistant: message.AssistantMessage = .{
            .content = &.{},
            .api = model.api,
            .provider = model.provider,
            .model = model.id,
            .usage = emptyUsage(),
            .stop_reason = stop_reason,
            .error_message = error_message,
            .timestamp = 0,
        };
        const msg: message.AgentMessage = .{ .assistant = assistant };
        try self.messages.append(self.allocator, try message_memory.cloneMessage(self.allocator, msg));
        self.sink.emit(.{ .message_end = .{ .message = msg } });
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

fn protocolTools(allocator: std.mem.Allocator, tools: []const @import("tool.zig").AgentTool) !?[]const ai.protocol.Tool { // ziglint-ignore: Z024, Z028
    if (tools.len == 0) return null;
    const out = try allocator.alloc(ai.protocol.Tool, tools.len);
    for (tools, 0..) |tool, i| {
        out[i] = .{ .name = tool.name, .description = tool.description, .parameters = tool.parameters };
    }
    return out;
}

fn freeOwnedMessages(allocator: std.mem.Allocator, messages: []const message.AgentMessage) void {
    for (messages) |msg| message_memory.freeMessage(allocator, msg);
    allocator.free(messages);
}

fn failureMessage(reason: failure.Failure) []const u8 {
    return switch (reason) {
        .out_of_memory => |message_text| message_text,
        .invalid_context => |message_text| message_text,
        .stream_failed => |message_text| message_text,
        .tool_failed => |message_text| message_text,
        .tool_protocol_violation => |message_text| message_text,
        .internal => |message_text| message_text,
    };
}

fn emptyUsage() ai.protocol.Usage {
    return .{
        .input = 0,
        .output = 0,
        .cache_read = 0,
        .cache_write = 0,
        .total_tokens = 0,
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 },
    };
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
        .usage = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total_tokens = 0, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 } }, // ziglint-ignore: Z024
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
        .usage = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total_tokens = 0, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 } }, // ziglint-ignore: Z024
        .stop_reason = .toolUse,
        .timestamp = 0,
    };
}

const test_tool_content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{.{ .tool_call = test_tool_call }};
const test_tool_call = message.ToolCall{ .id = "tool-1", .name = "read", .arguments = @import("../json/value.zig").OwnedValue.nullValue() }; // ziglint-ignore: Z024, Z004, Z028

fn convertNoop(_: ?*anyopaque, _: std.mem.Allocator, _: []const message.AgentMessage) error{OutOfMemory}![]const ai.protocol.Message { // ziglint-ignore: Z024, Z023
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
        const self: *@This() = @ptrCast(@alignCast(ctx.?)); // ziglint-ignore: Z020
        switch (value) {
            .message_update => self.message_deltas += 1,
            .turn_end => self.turn_terminals += 1,
            .agent_end => {
                self.run_terminals += 1;
                self.completed = true;
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
        fn call(_: ?*anyopaque, _: std.mem.Allocator, _: message.Model, _: ai.protocol.Context, _: ai.protocol.SimpleStreamOptions, sink: ai.provider.StreamEventSink) error{OutOfMemory}!void { // ziglint-ignore: Z024, Z023
            sink.emit(.{ .done = .{ .reason = .stop, .message = testAssistant() } });
        }
    };

    var collector = Collector{}; // ziglint-ignore: Z004
    var run = Run.init(std.testing.allocator, .{ .system_prompt = "", .messages = &.{} }, .{ .emit_fn = Collector.emit, .ctx = &collector }, .none); // ziglint-ignore: Z024
    defer run.deinit();
    run.runStream(configWithStream(Hook.call));

    try std.testing.expectEqual(@as(usize, 1), collector.run_terminals);
    try std.testing.expectEqual(@as(usize, 1), collector.turn_terminals);
    try std.testing.expect(collector.completed);
    try std.testing.expect(run.state == .completed);
}

test "run forwards stream deltas before terminal" {
    const Hook = struct {
        fn call(_: ?*anyopaque, _: std.mem.Allocator, _: message.Model, _: ai.protocol.Context, _: ai.protocol.SimpleStreamOptions, sink: ai.provider.StreamEventSink) error{OutOfMemory}!void { // ziglint-ignore: Z024, Z023
            sink.emit(.start);
            sink.emit(.{ .text_delta = .{ .content_index = 0, .delta = "hi" } });
            sink.emit(.{ .done = .{ .reason = .stop, .message = testAssistant() } });
        }
    };

    var collector = Collector{}; // ziglint-ignore: Z004
    var run = Run.init(std.testing.allocator, .{ .system_prompt = "", .messages = &.{} }, .{ .emit_fn = Collector.emit, .ctx = &collector }, .none); // ziglint-ignore: Z024
    defer run.deinit();
    run.runStream(configWithStream(Hook.call));

    try std.testing.expect(collector.message_deltas >= 1);
    try std.testing.expectEqual(@as(usize, 1), collector.run_terminals);
}

test "run emits failed terminal when stream has no terminal" {
    const Hook = struct {
        fn call(_: ?*anyopaque, _: std.mem.Allocator, _: message.Model, _: ai.protocol.Context, _: ai.protocol.SimpleStreamOptions, _: ai.provider.StreamEventSink) error{OutOfMemory}!void {} // ziglint-ignore: Z024, Z023
    };

    var collector = Collector{}; // ziglint-ignore: Z004
    var run = Run.init(std.testing.allocator, .{ .system_prompt = "", .messages = &.{} }, .{ .emit_fn = Collector.emit, .ctx = &collector }, .none); // ziglint-ignore: Z024
    defer run.deinit();
    run.runStream(configWithStream(Hook.call));

    try std.testing.expectEqual(@as(usize, 1), collector.run_terminals);
    try std.testing.expect(run.state == .failed);
}

test "run observes cancellation before stream start" {
    const Hook = struct {
        fn call(_: ?*anyopaque, _: std.mem.Allocator, _: message.Model, _: ai.protocol.Context, _: ai.protocol.SimpleStreamOptions, _: ai.provider.StreamEventSink) error{OutOfMemory}!void { // ziglint-ignore: Z024, Z023
            return error.OutOfMemory;
        }
    };

    var source = cancel.Source{}; // ziglint-ignore: Z004
    const signal = source.beginRun();
    source.requestAbort();

    var collector = Collector{}; // ziglint-ignore: Z004
    var run = Run.init(std.testing.allocator, .{ .system_prompt = "", .messages = &.{} }, .{ .emit_fn = Collector.emit, .ctx = &collector }, signal); // ziglint-ignore: Z024
    defer run.deinit();
    run.runStream(configWithStream(Hook.call));

    try std.testing.expectEqual(@as(usize, 1), collector.run_terminals);
    try std.testing.expect(run.state == .aborted);
}

fn completeRead(_: ?*anyopaque, _: std.mem.Allocator, invocation: @import("tool.zig").ToolInvocation, sink: @import("tool.zig").ToolCompletionSink) void { // ziglint-ignore: Z024, Z023, Z028
    var completion = @import("tool.zig").ToolCompletion{ .terminal = .{ // ziglint-ignore: Z004, Z028
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
        fn call(ctx: ?*anyopaque, _: std.mem.Allocator, _: message.Model, _: ai.protocol.Context, _: ai.protocol.SimpleStreamOptions, sink: ai.provider.StreamEventSink) error{OutOfMemory}!void { // ziglint-ignore: Z024, Z023
            const self: *@This() = @ptrCast(@alignCast(ctx.?)); // ziglint-ignore: Z020
            self.calls += 1;
            if (self.calls == 1) {
                sink.emit(.{ .done = .{ .reason = .toolUse, .message = testToolUseAssistant() } });
            } else {
                sink.emit(.{ .done = .{ .reason = .stop, .message = testAssistant() } });
            }
        }
    };

    var hook = Hook{}; // ziglint-ignore: Z004
    var collector = Collector{}; // ziglint-ignore: Z004
    const tools = [_]@import("tool.zig").AgentTool{.{ .name = "read", .description = "", .parameters = .null, .execute_fn = completeRead }}; // ziglint-ignore: Z024, Z028
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
