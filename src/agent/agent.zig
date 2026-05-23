const std = @import("std");
const runtime_queue = @import("../runtime/queue.zig");
const cancel = @import("../runtime/cancel.zig");
const ai = @import("../ai/root.zig");
const config_mod = @import("config.zig");
const failure_mod = @import("failure.zig");
const message_mod = @import("message.zig");
const message_memory = @import("../ai/root.zig").message_memory;
const run_mod = @import("run.zig");
const run_terminal = @import("run_terminal.zig");
const tool_mod = @import("../ai/root.zig").tool;

pub const max_pending_follow_ups: usize = 8;
pub const max_listeners: usize = 16;
const MessageQueue = runtime_queue.BoundedQueue([]const message_mod.AgentMessage);

pub const QueueMode = enum {
    all,
    one_at_a_time,
};

pub const Agent = struct {
    allocator: std.mem.Allocator,
    model: message_mod.Model,
    backend: config_mod.RunBackend,
    system_prompt: []const u8 = "",
    reasoning: ?ai.protocol.ThinkingLevel = null,
    tools: []const tool_mod.AgentTool = &.{},
    sink: ?ai.protocol.AgentEventSink = null,
    messages: std.ArrayListUnmanaged(message_mod.AgentMessage) = .empty,
    steering_queue: MessageQueue,
    follow_up_queue: MessageQueue,
    steering_mode: QueueMode,
    follow_up_mode: QueueMode,
    abort_source: cancel.Source = .{},
    activity: Activity = .idle,
    is_streaming: bool = false,
    streaming_message: ?message_mod.AgentMessage = null,
    pending_tool_calls: usize = 0,
    error_message: ?[]const u8 = null,
    listeners: std.ArrayListUnmanaged(Listener) = .empty,
    next_listener_id: u64 = 1,

    pub const Activity = union(enum) {
        idle,
        running: Running,
        aborting,
        failed: failure_mod.Kind,
    };

    pub const Running = struct {
        queued_followups: usize = 0,
    };

    pub const State = struct {
        activity: Activity,
        messages: []const message_mod.AgentMessage,
        is_streaming: bool,
        streaming_message: ?message_mod.AgentMessage,
        pending_tool_calls: usize,
        error_message: ?[]const u8,
    };

    pub const Listener = struct {
        id: u64,
        sink: ai.protocol.AgentEventSink,
    };

    pub const Subscription = struct {
        id: u64,
    };

    pub const TerminalSink = struct {
        ctx: ?*anyopaque = null,
        emit_fn: *const fn (ctx: ?*anyopaque, terminal: *const run_terminal.OwnedRunTerminal) void,

        pub fn emit(self: TerminalSink, terminal: *const run_terminal.OwnedRunTerminal) void { // ziglint-ignore: Z012
            self.emit_fn(self.ctx, terminal);
        }
    };

    pub const Options = struct {
        model: message_mod.Model,
        backend: config_mod.RunBackend,
        system_prompt: []const u8 = "",
        reasoning: ?ai.protocol.ThinkingLevel = null,
        tools: []const tool_mod.AgentTool = &.{},
        initial_messages: []const message_mod.AgentMessage = &.{},
        sink: ?ai.protocol.AgentEventSink = null,
        follow_up_capacity: usize = max_pending_follow_ups,
        steering_mode: QueueMode = .one_at_a_time,
        follow_up_mode: QueueMode = .one_at_a_time,
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) !Agent {
        var steering_queue = try MessageQueue.init(allocator, options.follow_up_capacity);
        errdefer steering_queue.deinit();
        var follow_up_queue = try MessageQueue.init(allocator, options.follow_up_capacity);
        errdefer follow_up_queue.deinit();

        var self: Agent = .{
            .allocator = allocator,
            .model = options.model,
            .backend = options.backend,
            .system_prompt = options.system_prompt,
            .reasoning = options.reasoning,
            .tools = options.tools,
            .sink = options.sink,
            .messages = .empty,
            .steering_queue = steering_queue,
            .follow_up_queue = follow_up_queue,
            .steering_mode = options.steering_mode,
            .follow_up_mode = options.follow_up_mode,
        };
        errdefer self.deinit();
        try appendClonedMessages(allocator, &self.messages, options.initial_messages);
        return self;
    }

    pub fn deinit(self: *Agent) void {
        self.clearAllQueues();
        self.listeners.deinit(self.allocator);
        self.clearStreamingMessage();
        freeMessageList(self.allocator, &self.messages);
        self.steering_queue.deinit();
        self.follow_up_queue.deinit();
        self.* = undefined;
    }

    pub fn state(self: *const Agent) State {
        return .{
            .activity = self.activity,
            .messages = self.messages.items,
            .is_streaming = self.is_streaming,
            .streaming_message = self.streaming_message,
            .pending_tool_calls = self.pending_tool_calls,
            .error_message = self.error_message,
        };
    }

    pub fn subscribe(self: *Agent, sink: ai.protocol.AgentEventSink) !Subscription {
        if (self.listeners.items.len >= max_listeners) return error.ListenerCapacityExceeded;
        const id = self.next_listener_id;
        self.next_listener_id +%= 1;
        try self.listeners.append(self.allocator, .{ .id = id, .sink = sink });
        return .{ .id = id };
    }

    pub fn unsubscribe(self: *Agent, subscription: Subscription) void {
        for (self.listeners.items, 0..) |listener, index| {
            if (listener.id == subscription.id) {
                _ = self.listeners.orderedRemove(index);
                return;
            }
        }
    }

    pub fn prompt(self: *Agent, messages: []const message_mod.AgentMessage) !run_terminal.OwnedRunTerminal {
        if (self.activity == .running or self.activity == .aborting) return error.Busy;
        return self.runOne(messages);
    }

    pub fn continueRun(self: *Agent) !run_terminal.OwnedRunTerminal {
        if (self.activity == .running or self.activity == .aborting) return error.Busy;
        if (self.drain()) |terminal| return terminal;
        if (self.messages.items.len == 0) return error.InvalidState;
        if (self.messages.items[self.messages.items.len - 1] == .assistant) return error.InvalidState;
        return self.runOne(&.{});
    }

    pub fn steer(self: *Agent, messages: []const message_mod.AgentMessage) !void {
        const owned = try message_memory.cloneMessages(self.allocator, messages);
        self.steering_queue.push(owned) catch {
            freeMessages(self.allocator, owned);
            return error.SteeringQueueFull;
        };
    }

    pub fn followUp(self: *Agent, messages: []const message_mod.AgentMessage) !?run_terminal.OwnedRunTerminal {
        switch (self.activity) {
            .idle, .failed => return try self.prompt(messages),
            .running => {
                const owned = try message_memory.cloneMessages(self.allocator, messages);
                self.follow_up_queue.push(owned) catch {
                    freeMessages(self.allocator, owned);
                    return error.FollowUpQueueFull;
                };
                self.refreshRunningCounts();
                return null;
            },
            .aborting => return error.InvalidState,
        }
    }

    pub fn abort(self: *Agent) void {
        switch (self.activity) {
            .running => {
                self.abort_source.requestAbort();
                self.activity = .aborting;
            },
            else => {},
        }
    }

    pub fn fail(self: *Agent, kind: failure_mod.Kind) void {
        self.clearAllQueues();
        self.activity = .{ .failed = kind };
    }

    pub fn reset(self: *Agent) void {
        // Listeners are subscriptions owned by callers and intentionally survive reset.
        std.debug.assert(self.activity != .running);
        std.debug.assert(self.activity != .aborting);
        self.clearAllQueues();
        freeMessageList(self.allocator, &self.messages);
        self.activity = .idle;
        self.is_streaming = false;
        self.clearStreamingMessage();
        self.pending_tool_calls = 0;
        self.error_message = null;
        self.abort_source = .{};
    }

    fn emitToListeners(self: *Agent, value: ai.protocol.AgentEvent) void {
        for (self.listeners.items) |listener| listener.sink.emit(value);
        if (self.sink) |sink| sink.emit(value);
    }

    pub fn assertIdle(self: *const Agent) void {
        std.debug.assert(self.activity != .running);
        std.debug.assert(self.activity != .aborting);
    }

    pub fn waitForIdle(self: *const Agent) void {
        self.assertIdle();
    }

    fn clearStreamingMessage(self: *Agent) void {
        if (self.streaming_message) |msg| message_memory.freeMessage(self.allocator, msg);
        self.streaming_message = null;
    }

    pub fn drain(self: *Agent) ?run_terminal.OwnedRunTerminal {
        if (self.activity != .idle) return null;
        if (self.drainQueue(&self.steering_queue, self.steering_mode) catch |err| switch (err) {
            error.OutOfMemory => return run_terminal.OwnedRunTerminal.failed(
                self.allocator,
                &.{},
                .out_of_memory,
            ) catch @panic("OOM while recording steering terminal"),
        }) |messages| {
            defer freeMessages(self.allocator, messages);
            return self.runOne(messages) catch |err| switch (err) {
                error.OutOfMemory => run_terminal.OwnedRunTerminal.failed(
                    self.allocator,
                    &.{},
                    .out_of_memory,
                ) catch @panic("OOM while recording steering terminal"),
            };
        }
        if (self.drainQueue(&self.follow_up_queue, self.follow_up_mode) catch |err| switch (err) {
            error.OutOfMemory => return run_terminal.OwnedRunTerminal.failed(
                self.allocator,
                &.{},
                .out_of_memory,
            ) catch @panic("OOM while recording follow-up terminal"),
        }) |messages| {
            defer freeMessages(self.allocator, messages);
            return self.runOne(messages) catch |err| switch (err) {
                error.OutOfMemory => run_terminal.OwnedRunTerminal.failed(
                    self.allocator,
                    &.{},
                    .out_of_memory,
                ) catch @panic("OOM while recording follow-up terminal"),
            };
        }
        return null;
    }

    fn drainQueue(self: *Agent, queue: *MessageQueue, mode: QueueMode) error{OutOfMemory}!?[]const message_mod.AgentMessage { // ziglint-ignore: Z024
        return switch (mode) {
            .one_at_a_time => queue.pop(),
            .all => try self.drainAll(queue),
        };
    }

    fn drainAll(self: *Agent, queue: *MessageQueue) error{OutOfMemory}!?[]const message_mod.AgentMessage {
        const message_batch_count = queue.len;
        if (message_batch_count == 0) return null;
        var message_count: usize = 0;
        var batch_index: usize = 0;
        while (batch_index < message_batch_count) : (batch_index += 1) {
            const messages = queue.pop().?;
            message_count += messages.len;
            queue.push(messages) catch unreachable;
        }
        var out = try self.allocator.alloc(message_mod.AgentMessage, message_count);
        var out_index: usize = 0;
        errdefer {
            for (out[0..out_index]) |msg| message_memory.freeMessage(self.allocator, msg);
            self.allocator.free(out);
        }
        while (queue.pop()) |messages| {
            defer freeMessages(self.allocator, messages);
            for (messages) |msg| {
                out[out_index] = try message_memory.cloneMessage(self.allocator, msg);
                out_index += 1;
            }
        }
        return out;
    }

    fn drainQueueForRun(
        self: *Agent,
        allocator: std.mem.Allocator,
        queue: *MessageQueue,
        mode: QueueMode,
    ) error{OutOfMemory}![]const message_mod.AgentMessage {
        const messages = (try self.drainQueue(queue, mode)) orelse return allocator.alloc(message_mod.AgentMessage, 0);
        defer freeMessages(self.allocator, messages);
        return message_memory.cloneMessages(allocator, messages);
    }

    pub fn clearSteeringQueue(self: *Agent) void {
        while (self.steering_queue.pop()) |messages| freeMessages(self.allocator, messages);
    }

    pub fn clearFollowUpQueue(self: *Agent) void {
        while (self.follow_up_queue.pop()) |messages| freeMessages(self.allocator, messages);
    }

    pub fn clearAllQueues(self: *Agent) void {
        self.clearSteeringQueue();
        self.clearFollowUpQueue();
    }

    pub fn hasQueuedMessages(self: *const Agent) bool {
        return self.steering_queue.len > 0 or self.follow_up_queue.len > 0;
    }

    pub fn settle(self: *Agent, sink: TerminalSink) void {
        while (self.hasQueuedMessages()) {
            var terminal = self.drain() orelse {
                self.clearAllQueues();
                break;
            };
            defer terminal.deinit();
            sink.emit(&terminal);
        }
        std.debug.assert(!self.hasQueuedMessages());
    }

    fn runOne(self: *Agent, messages: []const message_mod.AgentMessage) !run_terminal.OwnedRunTerminal {
        self.activity = .{ .running = .{ .queued_followups = self.follow_up_queue.len } };
        errdefer self.activity = .{ .failed = .out_of_memory };
        const committed_start = self.messages.items.len;
        try appendClonedMessages(self.allocator, &self.messages, messages);
        errdefer truncateAndFreeMessages(self.allocator, &self.messages, committed_start);
        const token = self.abort_source.beginRun();
        var terminal = self.runPrompt(token);
        errdefer terminal.deinit();
        self.activity = switch (terminal.status) {
            .completed, .aborted => .idle,
            .failed => |failed| .{ .failed = failed.kind },
        };
        return terminal;
    }

    fn runPrompt(self: *Agent, token: cancel.Token) run_terminal.OwnedRunTerminal {
        var context = std.ArrayListUnmanaged(message_mod.AgentMessage).empty; // ziglint-ignore: Z011
        defer context.deinit(self.allocator);
        context.appendSlice(self.allocator, self.messages.items) catch return oomTerminal(
            self.allocator,
            error.OutOfMemory,
        );

        var capture: TerminalCapture = .{
            .allocator = self.allocator,
            .agent = self,
            .input_count = context.items.len,
            .sink = self.sink,
        };
        defer capture.deinit();

        var run_value = run_mod.Run.init(self.allocator, .{
            .system_prompt = self.system_prompt,
            .messages = context.items,
            .tools = self.tools,
        }, .{ .emit_fn = TerminalCapture.emit, .ctx = &capture }, token);
        defer run_value.deinit();

        var config = self.backend.runConfig(self.model, self.reasoning);
        config.steering_messages = .{ .ctx = self, .call_fn = steeringMessagesSource };
        config.follow_up_messages = .{ .ctx = self, .call_fn = followUpMessagesSource };
        run_value.runStream(config);
        return switch (run_value.state) {
            .completed => run_terminal.OwnedRunTerminal.completed(
                self.allocator,
                capture.outputMessages(self.messages.items),
            ) catch |err| oomTerminal(self.allocator, err),
            .aborted => run_terminal.OwnedRunTerminal.aborted(
                self.allocator,
                capture.outputMessages(self.messages.items),
            ) catch |err| oomTerminal(self.allocator, err),
            .failed => |failed| run_terminal.OwnedRunTerminal.failed(
                self.allocator,
                capture.outputMessages(self.messages.items),
                failure_mod.kind(failed),
            ) catch |err| oomTerminal(self.allocator, err),
            else => run_terminal.OwnedRunTerminal.failed(
                self.allocator,
                &.{},
                .internal,
            ) catch @panic("OOM while recording missing agent terminal"),
        };
    }

    fn refreshRunningCounts(self: *Agent) void {
        if (self.activity == .running) self.activity.running.queued_followups = self.follow_up_queue.len;
    }
};

fn freeMessages(allocator: std.mem.Allocator, messages: []const message_mod.AgentMessage) void {
    for (messages) |msg| message_memory.freeMessage(allocator, msg);
    allocator.free(messages);
}

fn steeringMessagesSource(ctx: ?*anyopaque, allocator: std.mem.Allocator) error{OutOfMemory}![]const message_mod.AgentMessage { // ziglint-ignore: Z024, Z023
    const self: *Agent = @ptrCast(@alignCast(ctx.?));
    return self.drainQueueForRun(allocator, &self.steering_queue, self.steering_mode);
}

fn followUpMessagesSource(ctx: ?*anyopaque, allocator: std.mem.Allocator) error{OutOfMemory}![]const message_mod.AgentMessage { // ziglint-ignore: Z024, Z023
    const self: *Agent = @ptrCast(@alignCast(ctx.?));
    return self.drainQueueForRun(allocator, &self.follow_up_queue, self.follow_up_mode);
}

fn appendClonedMessages(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(message_mod.AgentMessage),
    messages: []const message_mod.AgentMessage,
) !void {
    const start = list.items.len;
    errdefer truncateAndFreeMessages(allocator, list, start);
    try list.ensureUnusedCapacity(allocator, messages.len);
    for (messages) |msg| list.appendAssumeCapacity(try message_memory.cloneMessage(allocator, msg));
}

fn truncateAndFreeMessages(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(message_mod.AgentMessage),
    new_len: usize,
) void {
    std.debug.assert(new_len <= list.items.len);
    for (list.items[new_len..]) |msg| message_memory.freeMessage(allocator, msg);
    list.shrinkRetainingCapacity(new_len);
}

fn freeMessageList(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(message_mod.AgentMessage)) void {
    truncateAndFreeMessages(allocator, list, 0);
    list.deinit(allocator);
    list.* = .empty;
}

const TerminalCapture = struct {
    allocator: std.mem.Allocator,
    agent: *Agent,
    input_count: usize,
    sink: ?ai.protocol.AgentEventSink = null,
    terminal: ?run_terminal.OwnedRunTerminal = null,

    fn emit(value: ai.protocol.AgentEvent, ctx: ?*anyopaque) void {
        const self: *TerminalCapture = @ptrCast(@alignCast(ctx.?));
        self.apply(value) catch |err| {
            self.terminal = oomTerminal(self.allocator, err);
            return;
        };
        self.agent.emitToListeners(value);
    }

    fn apply(self: *TerminalCapture, value: ai.protocol.AgentEvent) error{OutOfMemory}!void {
        switch (value) {
            .message_start => |start| {
                self.agent.is_streaming = true;
                self.agent.clearStreamingMessage();
                self.agent.streaming_message = try message_memory.cloneMessage(self.allocator, start.message);
            },
            .message_end => |end| switch (end.message) {
                .assistant, .tool_result => {
                    self.agent.clearStreamingMessage();
                    try self.appendMessage(end.message);
                },
                else => {},
            },
            .message_update => |update| if (update.message) |msg| {
                self.agent.clearStreamingMessage();
                self.agent.streaming_message = try message_memory.cloneMessage(self.allocator, msg);
            },
            .agent_start => {
                self.agent.is_streaming = true;
                self.agent.error_message = null;
            },
            .agent_end => |terminal| {
                self.agent.is_streaming = false;
                self.agent.clearStreamingMessage();
                self.agent.pending_tool_calls = 0;
                self.agent.error_message = switch (terminal) {
                    .failed => |failed| failed.reason,
                    .completed, .aborted => null,
                };
            },
            .tool_execution_start => self.agent.pending_tool_calls += 1,
            .tool_execution_end => {
                if (self.agent.pending_tool_calls > 0) self.agent.pending_tool_calls -= 1;
            },
            .turn_start, .turn_end, .tool_execution_update => {},
        }
    }

    fn appendMessage(self: *TerminalCapture, msg: message_mod.AgentMessage) error{OutOfMemory}!void {
        try appendClonedMessages(self.allocator, &self.agent.messages, &.{msg});
    }

    fn outputMessages(
        self: *const TerminalCapture,
        messages: []const message_mod.AgentMessage,
    ) []const message_mod.AgentMessage {
        if (messages.len <= self.input_count) return &.{};
        return messages[self.input_count..];
    }

    fn deinit(self: *TerminalCapture) void {
        if (self.terminal) |*terminal| terminal.deinit();
        self.* = undefined;
    }
};

fn oomTerminal(allocator: std.mem.Allocator, _: anyerror) run_terminal.OwnedRunTerminal {
    return run_terminal.OwnedRunTerminal.failed(
        allocator,
        &.{},
        .out_of_memory,
    ) catch @panic("OOM while recording agent terminal");
}

fn failureErrorMessage(reason: failure_mod.Failure) ?[]const u8 {
    return switch (reason) {
        .out_of_memory => |message| message,
        .invalid_context => |message| message,
        .stream_failed => |message| message,
        .tool_failed => |message| message,
        .tool_protocol_violation => |message| message,
        .internal => |message| message,
    };
}

fn testModel() message_mod.Model {
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

fn testAssistant() message_mod.AssistantMessage {
    return .{
        .content = &.{},
        .api = .openai_responses,
        .provider = .openai,
        .model = "test",
        .usage = .{
            .input = 0,
            .output = 0,
            .cache_read = 0,
            .cache_write = 0,
            .total_tokens = 0,
            .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 },
        },
        .stop_reason = .stop,
        .timestamp = 0,
    };
}

fn convertNoop(
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator, // ziglint-ignore: Z023
    messages: []const message_mod.AgentMessage,
) error{OutOfMemory}![]const ai.protocol.Message {
    const self: *ContextCapture = @ptrCast(@alignCast(ctx.?));
    _ = allocator;
    self.pushContextLength(messages.len);
    return &.{};
}

const ContextCapture = struct {
    context_lengths: [4]usize = undefined,
    context_length_count: usize = 0,

    fn pushContextLength(self: *ContextCapture, value: usize) void {
        std.debug.assert(self.context_length_count < self.context_lengths.len);
        self.context_lengths[self.context_length_count] = value;
        self.context_length_count += 1;
    }

    fn stream(
        _: ?*anyopaque,
        _: std.mem.Allocator, // ziglint-ignore: Z023
        _: message_mod.Model,
        _: ai.protocol.Context,
        _: ai.protocol.SimpleStreamOptions,
        sink: ai.provider.StreamEventSink,
    ) error{OutOfMemory}!void {
        sink.emit(.{ .done = .{ .reason = .stop, .message = testAssistant() } });
    }
};

fn testBackend(capture: *ContextCapture) config_mod.RunBackend {
    return .{
        .stream = .{ .ctx = capture, .call_fn = ContextCapture.stream },
        .convert_messages = .{ .ctx = capture, .call_fn = convertNoop },
        .io = std.testing.io,
    };
}

test "agent owns transcript and runs prompts with current context" {
    var capture: ContextCapture = .{};
    var agent = try Agent.init(std.testing.allocator, .{ .model = testModel(), .backend = testBackend(&capture) });
    defer agent.deinit();

    const prompt_message: message_mod.AgentMessage = .{ .user = .{
        .content = .{ .text = "hello" },
        .timestamp = 0,
    } };
    var terminal = try agent.prompt(&.{prompt_message});
    defer terminal.deinit();

    try std.testing.expectEqual(@as(usize, 1), capture.context_lengths[0]);
    try std.testing.expectEqual(@as(usize, 2), agent.state().messages.len);
    try std.testing.expect(agent.state().messages[0] == .user);
    try std.testing.expect(agent.state().messages[1] == .assistant);
}

test "agent continue uses owned transcript as low-level loop context" {
    var capture: ContextCapture = .{};
    const prompt_message: message_mod.AgentMessage = .{ .user = .{
        .content = .{ .text = "hello" },
        .timestamp = 0,
    } };
    var agent = try Agent.init(std.testing.allocator, .{
        .model = testModel(),
        .backend = testBackend(&capture),
        .initial_messages = &.{prompt_message},
    });
    defer agent.deinit();

    var terminal = try agent.continueRun();
    defer terminal.deinit();

    try std.testing.expectEqual(@as(usize, 1), capture.context_lengths[0]);
    try std.testing.expectEqual(@as(usize, 2), agent.state().messages.len);
}
