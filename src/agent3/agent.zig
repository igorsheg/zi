const std = @import("std");
const ai = @import("../ai/root.zig");
const abort_signal = @import("../abort_signal.zig");
const agent_loop = @import("agent_loop.zig");
const types = @import("types.zig");

const QueueMode = enum {
    all,
    one_at_a_time,
};

const Listener = struct {
    func: *const fn (event: types.AgentEvent, ctx: ?*anyopaque) void,
    ctx: ?*anyopaque,
};

pub const SubscriptionToken = struct {
    index: usize,
};

const PendingMessageQueue = struct {
    allocator: std.mem.Allocator,
    mode: QueueMode,
    messages: std.ArrayList(types.AgentMessage) = .empty,

    fn init(allocator: std.mem.Allocator, mode: QueueMode) PendingMessageQueue {
        return .{
            .allocator = allocator,
            .mode = mode,
            .messages = .empty,
        };
    }

    fn deinit(self: *PendingMessageQueue) void {
        for (self.messages.items) |*message| message.free(self.allocator);
        self.messages.deinit(self.allocator);
        self.* = undefined;
    }

    fn enqueue(self: *PendingMessageQueue, message: types.AgentMessage) !void {
        try self.messages.append(self.allocator, try message.clone(self.allocator));
    }

    fn hasItems(self: *const PendingMessageQueue) bool {
        return self.messages.items.len > 0;
    }

    fn clear(self: *PendingMessageQueue) void {
        for (self.messages.items) |*message| message.free(self.allocator);
        self.messages.clearRetainingCapacity();
    }

    fn drain(self: *PendingMessageQueue, allocator: std.mem.Allocator) []const types.AgentMessage {
        const take = switch (self.mode) {
            .all => self.messages.items.len,
            .one_at_a_time => @min(@as(usize, 1), self.messages.items.len),
        };
        if (take == 0) return &.{};

        const owned = allocator.alloc(types.AgentMessage, take) catch return &.{};
        var initialized: usize = 0;
        errdefer {
            for (owned[0..initialized]) |*message| message.free(allocator);
            allocator.free(owned);
        }

        for (self.messages.items[0..take], 0..) |message, i| {
            owned[i] = message.clone(allocator) catch break;
            initialized += 1;
        }

        var i: usize = 0;
        while (i < take) : (i += 1) {
            self.messages.items[i].free(self.allocator);
        }
        _ = self.messages.orderedRemoveRange(0, take);
        return owned[0..initialized];
    }
};

pub const Agent = struct {
    allocator: std.mem.Allocator,
    listeners: std.ArrayList(Listener) = .empty,
    messages_list: std.ArrayList(types.AgentMessage) = .empty,
    pending_tool_calls: std.ArrayList([]const u8) = .empty,
    steering_queue: PendingMessageQueue,
    follow_up_queue: PendingMessageQueue,

    system_prompt: []const u8,
    model: types.Model,
    tools: []const types.AgentTool,
    thinking_level: types.ThinkingLevel,

    convert_to_llm: types.ConvertToLlmHook,
    transform_context: ?types.TransformContextHook,
    stream_fn: types.StreamFn,
    before_tool_call: ?types.BeforeToolCallHook,
    after_tool_call: ?types.AfterToolCallHook,
    get_api_key: ?types.GetApiKeyHook,

    session_id: ?[]const u8 = null,
    thinking_budgets: ?ai.protocol.ThinkingBudgets = null,
    transport: ?ai.protocol.Transport = null,
    max_retry_delay_ms: ?u64 = null,
    tool_execution: types.ToolExecutionMode = .parallel,

    is_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    is_streaming: bool = false,
    streaming_message: ?types.AgentMessage = null,
    error_message: ?[]const u8 = null,
    abort_controller: abort_signal.AbortController = .{},

    pub const Options = struct {
        system_prompt: []const u8 = "",
        model: types.Model,
        tools: []const types.AgentTool = &.{},
        messages: []const types.AgentMessage = &.{},
        thinking_level: types.ThinkingLevel = .off,
        convert_to_llm: ?types.ConvertToLlmHook = null,
        transform_context: ?types.TransformContextHook = null,
        stream_fn: types.StreamFn,
        before_tool_call: ?types.BeforeToolCallHook = null,
        after_tool_call: ?types.AfterToolCallHook = null,
        steering_mode: QueueMode = .one_at_a_time,
        follow_up_mode: QueueMode = .one_at_a_time,
        session_id: ?[]const u8 = null,
        thinking_budgets: ?ai.protocol.ThinkingBudgets = null,
        transport: ?ai.protocol.Transport = null,
        max_retry_delay_ms: ?u64 = null,
        get_api_key: ?types.GetApiKeyHook = null,
        tool_execution: types.ToolExecutionMode = .parallel,
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) !Agent {
        var messages_list: std.ArrayList(types.AgentMessage) = .empty;
        errdefer {
            for (messages_list.items) |*message| message.free(allocator);
            messages_list.deinit(allocator);
        }
        for (options.messages) |message| {
            try messages_list.append(allocator, try message.clone(allocator));
        }

        const system_prompt = try allocator.dupe(u8, options.system_prompt);
        errdefer allocator.free(system_prompt);

        const session_id = if (options.session_id) |session_id| try allocator.dupe(u8, session_id) else null;
        errdefer if (session_id) |owned| allocator.free(owned);

        return .{
            .allocator = allocator,
            .messages_list = messages_list,
            .pending_tool_calls = .empty,
            .steering_queue = PendingMessageQueue.init(allocator, options.steering_mode),
            .follow_up_queue = PendingMessageQueue.init(allocator, options.follow_up_mode),
            .system_prompt = system_prompt,
            .model = options.model,
            .tools = options.tools,
            .thinking_level = options.thinking_level,
            .convert_to_llm = options.convert_to_llm orelse defaultConvertToLlmHook(),
            .transform_context = options.transform_context,
            .stream_fn = options.stream_fn,
            .before_tool_call = options.before_tool_call,
            .after_tool_call = options.after_tool_call,
            .get_api_key = options.get_api_key,
            .session_id = session_id,
            .thinking_budgets = options.thinking_budgets,
            .transport = options.transport,
            .max_retry_delay_ms = options.max_retry_delay_ms,
            .tool_execution = options.tool_execution,
        };
    }

    pub fn deinit(self: *Agent) void {
        self.listeners.deinit(self.allocator);
        for (self.messages_list.items) |*message| message.free(self.allocator);
        self.messages_list.deinit(self.allocator);
        for (self.pending_tool_calls.items) |tool_call_id| self.allocator.free(tool_call_id);
        self.pending_tool_calls.deinit(self.allocator);
        self.steering_queue.deinit();
        self.follow_up_queue.deinit();
        if (self.streaming_message) |*message| message.free(self.allocator);
        if (self.error_message) |message| self.allocator.free(message);
        self.allocator.free(self.system_prompt);
        if (self.session_id) |session_id| self.allocator.free(session_id);
        self.* = undefined;
    }

    pub fn subscribe(self: *Agent, func: *const fn (event: types.AgentEvent, ctx: ?*anyopaque) void, ctx: ?*anyopaque) SubscriptionToken {
        const index = self.listeners.items.len;
        self.listeners.append(self.allocator, .{ .func = func, .ctx = ctx }) catch return .{ .index = std.math.maxInt(usize) };
        return .{ .index = index };
    }

    pub fn unsubscribe(self: *Agent, token: SubscriptionToken) void {
        if (token.index < self.listeners.items.len) _ = self.listeners.orderedRemove(token.index);
    }

    pub fn steer(self: *Agent, message: types.AgentMessage) !void {
        try self.steering_queue.enqueue(message);
    }

    pub fn followUp(self: *Agent, message: types.AgentMessage) !void {
        try self.follow_up_queue.enqueue(message);
    }

    pub fn clearSteeringQueue(self: *Agent) void {
        self.steering_queue.clear();
    }

    pub fn clearFollowUpQueue(self: *Agent) void {
        self.follow_up_queue.clear();
    }

    pub fn clearAllQueues(self: *Agent) void {
        self.clearSteeringQueue();
        self.clearFollowUpQueue();
    }

    pub fn hasQueuedMessages(self: *const Agent) bool {
        return self.steering_queue.hasItems() or self.follow_up_queue.hasItems();
    }

    pub fn abort(self: *Agent) void {
        if (self.is_running.load(.acquire)) self.abort_controller.requestAbort();
    }

    pub fn isAbortRequested(self: *const Agent) bool {
        return self.abort_controller.isAborted();
    }

    pub fn wakeAbortWaiters(self: *Agent) void {
        self.abort_controller.notifyWaiters();
    }

    pub fn prompt(self: *Agent, prompts: []const types.AgentMessage) !void {
        if (self.is_running.load(.acquire)) return error.AlreadyProcessing;
        self.runPrompt(prompts, false);
    }

    pub fn continueTurn(self: *Agent) !void {
        if (self.is_running.load(.acquire)) return error.AlreadyProcessing;
        if (self.messages_list.items.len == 0) return error.NoMessages;

        const last = self.messages_list.items[self.messages_list.items.len - 1];
        if (last == .assistant) {
            const queued_steering = self.steering_queue.drain(self.allocator);
            if (queued_steering.len > 0) {
                defer types.freeMessages(self.allocator, @constCast(queued_steering));
                self.runPrompt(queued_steering, false);
                return;
            }

            const queued_follow_up = self.follow_up_queue.drain(self.allocator);
            if (queued_follow_up.len > 0) {
                defer types.freeMessages(self.allocator, @constCast(queued_follow_up));
                self.runPrompt(queued_follow_up, false);
                return;
            }

            return error.CannotContinueFromAssistant;
        }

        self.runPrompt(null, true);
    }

    pub fn reset(self: *Agent) void {
        for (self.messages_list.items) |*message| message.free(self.allocator);
        self.messages_list.clearRetainingCapacity();
        self.clearStreamingMessage();
        self.clearPendingToolCalls();
        self.clearError();
        self.clearAllQueues();
        self.is_streaming = false;
    }

    pub fn setModel(self: *Agent, model: types.Model) void {
        self.model = model;
    }

    pub fn setThinkingLevel(self: *Agent, thinking_level: types.ThinkingLevel) void {
        self.thinking_level = thinking_level;
    }

    pub fn setTools(self: *Agent, tools: []const types.AgentTool) void {
        self.tools = tools;
    }

    pub fn setMessages(self: *Agent, new_messages: []const types.AgentMessage) !void {
        var replacement: std.ArrayList(types.AgentMessage) = .empty;
        defer if (replacement.items.len > 0) {
            for (replacement.items) |*message| message.free(self.allocator);
            replacement.deinit(self.allocator);
        };

        for (new_messages) |message| {
            try replacement.append(self.allocator, try message.clone(self.allocator));
        }

        for (self.messages_list.items) |*message| message.free(self.allocator);
        self.messages_list.deinit(self.allocator);
        self.messages_list = replacement;
        replacement = .empty;
    }

    pub fn setSessionId(self: *Agent, session_id: ?[]const u8) !void {
        const owned = if (session_id) |value| try self.allocator.dupe(u8, value) else null;
        if (self.session_id) |current| self.allocator.free(current);
        self.session_id = owned;
    }

    pub fn messages(self: *const Agent) []const types.AgentMessage {
        return self.messages_list.items;
    }

    pub fn latestAssistant(self: *const Agent) ?ai.protocol.AssistantMessage {
        var i = self.messages_list.items.len;
        while (i > 0) {
            i -= 1;
            if (self.messages_list.items[i] == .assistant) return self.messages_list.items[i].assistant;
        }
        return null;
    }

    pub fn modelValue(self: *const Agent) types.Model {
        return self.model;
    }

    pub fn thinkingLevel(self: *const Agent) types.ThinkingLevel {
        return self.thinking_level;
    }

    pub fn isStreaming(self: *const Agent) bool {
        return self.is_streaming;
    }

    pub fn errorMessage(self: *const Agent) ?[]const u8 {
        return self.error_message;
    }

    fn runPrompt(self: *Agent, prompts: ?[]const types.AgentMessage, is_continue: bool) void {
        self.is_running.store(true, .release);
        self.is_streaming = true;
        self.clearStreamingMessage();
        self.clearError();
        const signal = self.abort_controller.beginRun();

        var run_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer run_arena.deinit();
        defer {
            self.is_streaming = false;
            self.clearStreamingMessage();
            self.clearPendingToolCalls();
            self.is_running.store(false, .release);
        }

        const context = self.createContextSnapshot();
        const config = self.createLoopConfig();

        if (is_continue) {
            agent_loop.runAgentLoopContinue(
                run_arena.allocator(),
                self.allocator,
                context,
                config,
                processEventSink,
                @ptrCast(self),
                signal,
            ) catch |err| switch (err) {
                error.EmptyContext, error.AssistantTail => {},
            };
        } else {
            agent_loop.runAgentLoop(
                run_arena.allocator(),
                self.allocator,
                prompts.?,
                context,
                config,
                processEventSink,
                @ptrCast(self),
                signal,
            );
        }
    }

    fn createContextSnapshot(self: *const Agent) types.AgentContext {
        return .{
            .system_prompt = self.system_prompt,
            .messages = self.messages_list.items,
            .tools = if (self.tools.len > 0) self.tools else null,
        };
    }

    fn createLoopConfig(self: *Agent) types.AgentLoopConfig {
        var stream_options: ai.protocol.SimpleStreamOptions = .{};
        stream_options.base.session_id = self.session_id;
        stream_options.base.max_retry_delay_ms = self.max_retry_delay_ms;
        stream_options.base.transport = self.transport;
        stream_options.reasoning = self.thinking_level.toAi();
        stream_options.thinking_budgets = self.thinking_budgets;

        return .{
            .model = self.model,
            .stream_fn = self.stream_fn,
            .convert_to_llm = self.convert_to_llm,
            .stream_options = stream_options,
            .transform_context = self.transform_context,
            .get_api_key = self.get_api_key,
            .get_steering_messages = .{ .func = drainSteeringMessages, .ctx = @ptrCast(self) },
            .get_follow_up_messages = .{ .func = drainFollowUpMessages, .ctx = @ptrCast(self) },
            .tool_execution = self.tool_execution,
            .before_tool_call = self.before_tool_call,
            .after_tool_call = self.after_tool_call,
        };
    }

    fn drainSteeringMessages(allocator: std.mem.Allocator, raw_ctx: ?*anyopaque) []const types.AgentMessage {
        const self: *Agent = @ptrCast(@alignCast(raw_ctx));
        return self.steering_queue.drain(allocator);
    }

    fn drainFollowUpMessages(allocator: std.mem.Allocator, raw_ctx: ?*anyopaque) []const types.AgentMessage {
        const self: *Agent = @ptrCast(@alignCast(raw_ctx));
        return self.follow_up_queue.drain(allocator);
    }

    fn processEventSink(event: types.AgentEvent, raw_ctx: ?*anyopaque) void {
        const self: *Agent = @ptrCast(@alignCast(raw_ctx));
        self.processEvent(event);
    }

    fn processEvent(self: *Agent, event: types.AgentEvent) void {
        switch (event) {
            .message_start => |payload| {
                self.setStreamingMessage(payload.message);
            },
            .message_update => |payload| {
                self.setStreamingMessage(payload.message);
            },
            .message_end => |payload| {
                self.clearStreamingMessage();
                self.appendCommittedMessage(payload.message);
            },
            .tool_execution_start => |payload| {
                const owned = self.allocator.dupe(u8, payload.tool_call_id) catch return;
                self.pending_tool_calls.append(self.allocator, owned) catch {
                    self.allocator.free(owned);
                };
            },
            .tool_execution_end => |payload| {
                self.removePendingToolCall(payload.tool_call_id);
            },
            .turn_end => |payload| switch (payload.message) {
                .assistant => |assistant| {
                    if (assistant.error_message) |error_message| {
                        self.clearError();
                        self.error_message = self.allocator.dupe(u8, error_message) catch error_message;
                    }
                },
                else => {},
            },
            .agent_end => {
                self.clearStreamingMessage();
            },
            .agent_start, .turn_start => {},
        }

        for (self.listeners.items) |listener| {
            listener.func(event, listener.ctx);
        }
    }

    fn appendCommittedMessage(self: *Agent, message: types.AgentMessage) void {
        const owned = message.clone(self.allocator) catch return;
        self.messages_list.append(self.allocator, owned) catch {
            var mutable = owned;
            mutable.free(self.allocator);
        };
    }

    fn setStreamingMessage(self: *Agent, message: types.AgentMessage) void {
        self.clearStreamingMessage();
        self.streaming_message = message.clone(self.allocator) catch null;
    }

    fn clearStreamingMessage(self: *Agent) void {
        if (self.streaming_message) |*message| message.free(self.allocator);
        self.streaming_message = null;
    }

    fn clearPendingToolCalls(self: *Agent) void {
        for (self.pending_tool_calls.items) |tool_call_id| self.allocator.free(tool_call_id);
        self.pending_tool_calls.clearRetainingCapacity();
    }

    fn removePendingToolCall(self: *Agent, tool_call_id: []const u8) void {
        for (self.pending_tool_calls.items, 0..) |current, i| {
            if (std.mem.eql(u8, current, tool_call_id)) {
                self.allocator.free(current);
                _ = self.pending_tool_calls.orderedRemove(i);
                return;
            }
        }
    }

    fn clearError(self: *Agent) void {
        if (self.error_message) |message| self.allocator.free(message);
        self.error_message = null;
    }
};

pub fn defaultConvertToLlm(
    allocator: std.mem.Allocator,
    messages: []const types.AgentMessage,
    _: ?*anyopaque,
) []const ai.protocol.Message {
    var result: std.ArrayList(ai.protocol.Message) = .empty;
    for (messages) |message| {
        switch (message) {
            .user => |user| result.append(allocator, .{ .user = user }) catch {},
            .assistant => |assistant| result.append(allocator, .{ .assistant = assistant }) catch {},
            .tool_result => |tool_result| result.append(allocator, .{ .tool_result = tool_result }) catch {},
            .custom => {},
        }
    }
    return result.items;
}

pub fn defaultConvertToLlmHook() types.ConvertToLlmHook {
    return .{ .func = defaultConvertToLlm };
}

test "defaultConvertToLlm drops custom messages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var payload_map = std.json.ObjectMap.init(allocator);
    try payload_map.put("value", .{ .integer = 1 });

    const messages = [_]types.AgentMessage{
        .{ .user = .{ .content = .{ .text = "hello" }, .timestamp = 1 } },
        .{ .custom = .{ .role = "note", .payload = .{ .object = payload_map }, .timestamp = 2 } },
    };

    const result = defaultConvertToLlm(allocator, &messages, null);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expect(result[0] == .user);
}
