const abort_signal_mod = @import("../abort_signal.zig");
const std = @import("std");
const ai = @import("../ai/root.zig");
const protocol = @import("types.zig");
const control_mod = @import("control.zig");
const conversation_state = @import("conversation_state.zig");
const loop_mod = @import("loop.zig");
const message_memory = @import("message_memory.zig");
const testing = std.testing;

pub const QueueMode = control_mod.QueueMode;

const Listener = struct {
    func: *const fn (event: protocol.AgentEvent, ctx: ?*anyopaque) void,
    ctx: ?*anyopaque,
};

pub const SubscriptionToken = struct {
    index: usize,
};

pub const QueueMutationAction = enum {
    enqueued,
    drained,
    cleared,
};

pub const QueueObserver = struct {
    func: *const fn (action: QueueMutationAction, kind: control_mod.QueueKind, message: protocol.AgentMessage, ctx: ?*anyopaque) void,
    ctx: ?*anyopaque = null,
};

pub const Agent = struct {
    allocator: std.mem.Allocator,
    history_arena: std.heap.ArenaAllocator,
    runtime_arena: std.heap.ArenaAllocator,

    listeners: std.ArrayList(Listener),
    committed: std.ArrayList(protocol.AgentMessage),
    in_flight: conversation_state.InFlightState,

    run_control: control_mod.RunControl,
    queue_observer: ?QueueObserver = null,

    system_prompt: []const u8,
    model: protocol.Model,
    tools: []const protocol.AgentTool,
    thinking_level: protocol.ThinkingLevel,

    convert_to_llm: protocol.ConvertToLlmHook,
    transform_context: ?protocol.TransformContextHook,
    stream_fn: protocol.StreamHook,
    before_tool_call: ?protocol.BeforeToolCallHook,
    after_tool_call: ?protocol.AfterToolCallHook,
    get_api_key: ?protocol.GetApiKeyHook,

    session_id: ?[]const u8,
    thinking_budgets: ?ai.protocol.ThinkingBudgets,
    transport: ?ai.protocol.Transport,
    max_retry_delay_ms: ?u64,

    is_running: std.atomic.Value(bool),
    is_streaming: bool = false,
    error_message: ?[]const u8 = null,
    abort_controller: abort_signal_mod.AbortController,

    pub const Options = struct {
        system_prompt: []const u8 = "",
        model: protocol.Model,
        tools: []const protocol.AgentTool = &.{},
        messages: []const protocol.AgentMessage = &.{},
        thinking_level: protocol.ThinkingLevel = .off,
        convert_to_llm: ?protocol.ConvertToLlmHook = null,
        transform_context: ?protocol.TransformContextHook = null,
        stream_fn: ?protocol.StreamHook = null,
        before_tool_call: ?protocol.BeforeToolCallHook = null,
        after_tool_call: ?protocol.AfterToolCallHook = null,
        steering_mode: QueueMode = .one_at_a_time,
        follow_up_mode: QueueMode = .one_at_a_time,
        session_id: ?[]const u8 = null,
        thinking_budgets: ?ai.protocol.ThinkingBudgets = null,
        transport: ?ai.protocol.Transport = null,
        max_retry_delay_ms: ?u64 = null,
        get_api_key: ?protocol.GetApiKeyHook = null,
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) !Agent {
        var history_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer history_arena.deinit();
        var runtime_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer runtime_arena.deinit();

        const aa = history_arena.allocator();
        var committed: std.ArrayList(protocol.AgentMessage) = .empty;
        errdefer committed.deinit(aa);
        for (options.messages) |message| {
            try committed.append(aa, try message_memory.cloneMessage(aa, message));
        }

        const run_control = try control_mod.RunControl.init(allocator, .{
            .steering_mode = options.steering_mode,
            .follow_up_mode = options.follow_up_mode,
        });
        errdefer {
            var mutable = run_control;
            mutable.deinit();
        }

        const owned_session_id = if (options.session_id) |session_id|
            try allocator.dupe(u8, session_id)
        else
            null;
        errdefer if (owned_session_id) |session_id| allocator.free(session_id);

        return .{
            .allocator = allocator,
            .history_arena = history_arena,
            .runtime_arena = runtime_arena,
            .listeners = .empty,
            .committed = committed,
            .in_flight = conversation_state.InFlightState.init(allocator),
            .run_control = run_control,
            .system_prompt = options.system_prompt,
            .model = options.model,
            .tools = options.tools,
            .thinking_level = options.thinking_level,
            .convert_to_llm = options.convert_to_llm orelse defaultConvertToLlmHook(),
            .transform_context = options.transform_context,
            .stream_fn = options.stream_fn orelse unreachable_stream_hook,
            .before_tool_call = options.before_tool_call,
            .after_tool_call = options.after_tool_call,
            .get_api_key = options.get_api_key,
            .session_id = owned_session_id,
            .thinking_budgets = options.thinking_budgets,
            .transport = options.transport,
            .max_retry_delay_ms = options.max_retry_delay_ms,
            .is_running = std.atomic.Value(bool).init(false),
            .abort_controller = .{},
        };
    }

    pub fn deinit(self: *Agent) void {
        self.listeners.deinit(self.allocator);
        self.in_flight.deinit();
        self.run_control.deinit();
        self.runtime_arena.deinit();
        self.history_arena.deinit();
        if (self.session_id) |session_id| self.allocator.free(session_id);
        self.* = undefined;
    }

    pub fn subscribe(
        self: *Agent,
        func: *const fn (event: protocol.AgentEvent, ctx: ?*anyopaque) void,
        ctx: ?*anyopaque,
    ) SubscriptionToken {
        const index = self.listeners.items.len;
        self.listeners.append(self.allocator, .{ .func = func, .ctx = ctx }) catch return .{ .index = std.math.maxInt(usize) };
        return .{ .index = index };
    }

    pub fn unsubscribe(self: *Agent, token: SubscriptionToken) void {
        if (token.index < self.listeners.items.len) {
            _ = self.listeners.orderedRemove(token.index);
        }
    }

    pub fn setQueueObserver(self: *Agent, observer: ?QueueObserver) void {
        self.queue_observer = observer;
    }

    pub fn steer(self: *Agent, message: protocol.AgentMessage) control_mod.EnqueueResult {
        const result = self.run_control.enqueue(.steering, message);
        if (result == .ok) self.notifyQueueMutation(.enqueued, .steering, message);
        return result;
    }

    pub fn followUp(self: *Agent, message: protocol.AgentMessage) control_mod.EnqueueResult {
        const result = self.run_control.enqueue(.follow_up, message);
        if (result == .ok) self.notifyQueueMutation(.enqueued, .follow_up, message);
        return result;
    }

    pub fn hasQueuedMessages(self: *Agent) bool {
        return self.run_control.hasQueuedMessages();
    }

    pub fn clearSteeringQueue(self: *Agent) void {
        self.notifyPendingQueueCleared(.steering);
        self.run_control.clearSteering();
    }

    pub fn clearFollowUpQueue(self: *Agent) void {
        self.notifyPendingQueueCleared(.follow_up);
        self.run_control.clearFollowUp();
    }

    pub fn clearAllQueues(self: *Agent) void {
        self.clearSteeringQueue();
        self.clearFollowUpQueue();
    }

    pub fn abort(self: *Agent) void {
        if (self.is_running.load(.acquire)) {
            self.abort_controller.requestAbort();
        }
    }

    pub fn isAbortRequested(self: *const Agent) bool {
        return self.abort_controller.isAborted();
    }

    pub fn abortSignal(self: *Agent) abort_signal_mod.AbortSignal {
        return self.abort_controller.signal();
    }

    pub fn wakeAbortWaiters(self: *Agent) void {
        self.abort_controller.notifyWaiters();
    }

    pub fn systemPrompt(self: *const Agent) []const u8 {
        return self.system_prompt;
    }

    pub fn sessionId(self: *const Agent) ?[]const u8 {
        return self.session_id;
    }

    pub fn modelValue(self: *const Agent) protocol.Model {
        return self.model;
    }

    pub fn thinkingLevel(self: *const Agent) protocol.ThinkingLevel {
        return self.thinking_level;
    }

    pub fn isStreaming(self: *const Agent) bool {
        return self.is_streaming;
    }

    pub fn errorMessage(self: *const Agent) ?[]const u8 {
        return self.error_message;
    }

    pub fn messages(self: *const Agent) []const protocol.AgentMessage {
        return self.committed.items;
    }

    pub fn latestAssistant(self: *const Agent) ?protocol.AssistantMessage {
        var i = self.committed.items.len;
        while (i > 0) {
            i -= 1;
            switch (self.committed.items[i]) {
                .assistant => |assistant| return assistant,
                else => {},
            }
        }
        return null;
    }

    pub fn setModel(self: *Agent, model: protocol.Model) void {
        self.model = model;
    }

    pub fn setThinkingLevel(self: *Agent, thinking_level: protocol.ThinkingLevel) void {
        self.thinking_level = thinking_level;
    }

    pub fn clearError(self: *Agent) void {
        self.error_message = null;
    }

    pub fn setSessionId(self: *Agent, session_id: ?[]const u8) !void {
        const owned = if (session_id) |value| try self.allocator.dupe(u8, value) else null;
        if (self.session_id) |old| self.allocator.free(old);
        self.session_id = owned;
    }

    pub fn setMessages(self: *Agent, new_messages: []const protocol.AgentMessage) !void {
        var staging_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer staging_arena.deinit();
        const staging = staging_arena.allocator();

        var staged: std.ArrayList(protocol.AgentMessage) = .empty;
        defer staged.deinit(staging);
        for (new_messages) |message| {
            try staged.append(staging, try message_memory.cloneMessage(staging, message));
        }

        self.resetHistoryArena();
        self.clearInFlight();
        const aa = self.history_arena.allocator();
        for (staged.items) |message| {
            try self.committed.append(aa, try message_memory.cloneMessage(aa, message));
        }
    }

    pub fn truncateCommitted(self: *Agent, new_len: usize) void {
        std.debug.assert(new_len <= self.committed.items.len);
        self.committed.items.len = new_len;
    }

    pub fn reset(self: *Agent) void {
        self.resetHistoryArena();
        self.resetRuntimeArena();
        self.is_streaming = false;
        self.error_message = null;
        self.clearAllQueues();
    }

    pub fn cloneConversationView(self: *const Agent, allocator: std.mem.Allocator) !conversation_state.ConversationView {
        const committed = try message_memory.cloneMessages(allocator, self.committed.items);
        errdefer message_memory.freeMessages(allocator, committed);
        const in_flight = try self.in_flight.freeze(allocator);
        return .{
            .committed = committed,
            .in_flight = in_flight,
        };
    }

    pub fn prompt(self: *Agent, prompts: []const protocol.AgentMessage) !void {
        if (self.is_running.load(.acquire)) return error.AlreadyProcessing;
        self.runWithLifecycle(prompts, false, false);
    }

    pub fn continueTurn(self: *Agent) !void {
        if (self.is_running.load(.acquire)) return error.AlreadyProcessing;
        if (self.committed.items.len == 0) return error.NoMessages;

        const last = self.committed.items[self.committed.items.len - 1];
        if (last == .assistant) {
            if (self.run_control.hasSteeringMessages()) {
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const queued = self.drainQueuedMessages(.steering, arena.allocator());
                if (queued.len > 0) {
                    self.runWithLifecycle(queued, false, true);
                    return;
                }
            }

            if (self.run_control.hasFollowUpMessages()) {
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const queued = self.drainQueuedMessages(.follow_up, arena.allocator());
                if (queued.len > 0) {
                    self.runWithLifecycle(queued, false, false);
                    return;
                }
            }

            return error.CannotContinueFromAssistant;
        }

        self.runWithLifecycle(null, true, false);
    }

    fn resetHistoryArena(self: *Agent) void {
        self.history_arena.deinit();
        self.history_arena = std.heap.ArenaAllocator.init(self.allocator);
        self.committed = .empty;
    }

    fn clearInFlight(self: *Agent) void {
        self.in_flight.clear();
    }

    fn resetRuntimeArena(self: *Agent) void {
        self.runtime_arena.deinit();
        self.runtime_arena = std.heap.ArenaAllocator.init(self.allocator);
        self.clearInFlight();
    }

    fn appendCommittedMessage(self: *Agent, message: protocol.AgentMessage) void {
        const aa = self.history_arena.allocator();
        const owned = message_memory.cloneMessage(aa, message) catch return;
        self.committed.append(aa, owned) catch {
            var mutable = owned;
            message_memory.freeMessage(aa, &mutable);
        };
    }

    fn runWithLifecycle(self: *Agent, prompt_messages: ?[]const protocol.AgentMessage, is_continue: bool, skip_initial_steering_poll: bool) void {
        self.is_running.store(true, .release);
        self.is_streaming = true;
        self.error_message = null;
        const signal = self.abort_controller.beginRun();

        self.resetRuntimeArena();

        defer {
            self.is_running.store(false, .release);
            self.is_streaming = false;
            self.resetRuntimeArena();
        }

        const config = self.createLoopConfig(skip_initial_steering_poll);
        const context = self.createContextSnapshot();

        if (is_continue) {
            loop_mod.runAgentLoopContinue(
                self.runtime_arena.allocator(),
                self.allocator,
                context,
                config,
                processEventsSink,
                @ptrCast(self),
                signal,
            ) catch {};
        } else {
            loop_mod.runAgentLoop(
                self.runtime_arena.allocator(),
                self.allocator,
                prompt_messages.?,
                context,
                config,
                processEventsSink,
                @ptrCast(self),
                signal,
            );
        }
    }

    fn createContextSnapshot(self: *const Agent) protocol.AgentContext {
        return .{
            .system_prompt = self.system_prompt,
            .messages = self.committed.items,
            .tools = if (self.tools.len > 0) self.tools else null,
        };
    }

    fn createLoopConfig(self: *Agent, skip_initial_steering_poll: bool) protocol.AgentLoopConfig {
        return .{
            .model = self.model,
            .stream = self.stream_fn,
            .convert_to_llm = self.convert_to_llm,
            .transform_context = self.transform_context,
            .get_steering_messages = .{
                .func = drainSteeringMessages,
                .ctx = @ptrCast(self),
            },
            .get_follow_up_messages = .{
                .func = drainFollowUpMessages,
                .ctx = @ptrCast(self),
            },
            .skip_initial_steering_poll = skip_initial_steering_poll,
            .tool_execution = .sequential,
            .before_tool_call = self.before_tool_call,
            .after_tool_call = self.after_tool_call,
            .session_id = self.session_id,
            .max_retry_delay_ms = self.max_retry_delay_ms,
            .thinking_budgets = self.thinking_budgets,
            .transport = self.transport,
            .reasoning = mapThinkingLevel(self.thinking_level),
            .get_api_key = self.get_api_key,
        };
    }

    fn mapThinkingLevel(level: protocol.ThinkingLevel) ?ai.protocol.ThinkingLevel {
        return switch (level) {
            .off => null,
            .minimal => .minimal,
            .low => .low,
            .medium => .medium,
            .high => .high,
            .xhigh => .xhigh,
        };
    }

    fn drainSteeringMessages(allocator: std.mem.Allocator, ctx: ?*anyopaque) []const protocol.AgentMessage {
        const self: *Agent = @ptrCast(@alignCast(ctx));
        return self.drainQueuedMessages(.steering, allocator);
    }

    fn drainFollowUpMessages(allocator: std.mem.Allocator, ctx: ?*anyopaque) []const protocol.AgentMessage {
        const self: *Agent = @ptrCast(@alignCast(ctx));
        return self.drainQueuedMessages(.follow_up, allocator);
    }

    fn notifyPendingQueueCleared(self: *Agent, kind: control_mod.QueueKind) void {
        const observer = self.queue_observer orelse return;
        const Visitor = struct {
            fn visit(item: *const protocol.AgentMessage, raw_ctx: ?*anyopaque) !void {
                const ctx_ptr: *const struct {
                    agent: *Agent,
                    observer: QueueObserver,
                    kind: control_mod.QueueKind,
                } = @ptrCast(@alignCast(raw_ctx.?));
                ctx_ptr.observer.func(.cleared, ctx_ptr.kind, item.*, ctx_ptr.observer.ctx);
                _ = ctx_ptr.agent;
            }
        };
        const Ctx = struct {
            agent: *Agent,
            observer: QueueObserver,
            kind: control_mod.QueueKind,
        };
        var ctx = Ctx{ .agent = self, .observer = observer, .kind = kind };
        self.run_control.visitPending(kind, Visitor.visit, @ptrCast(&ctx)) catch {};
    }

    fn drainQueuedMessages(self: *Agent, kind: control_mod.QueueKind, allocator: std.mem.Allocator) []const protocol.AgentMessage {
        const drained = switch (kind) {
            .steering => self.run_control.drainSteering(allocator),
            .follow_up => self.run_control.drainFollowUp(allocator),
        };
        for (drained) |message| self.notifyQueueMutation(.drained, kind, message);
        return drained;
    }

    fn notifyQueueMutation(self: *Agent, action: QueueMutationAction, kind: control_mod.QueueKind, message: protocol.AgentMessage) void {
        const observer = self.queue_observer orelse return;
        observer.func(action, kind, message, observer.ctx);
    }

    fn processEventsSink(event: protocol.AgentEvent, ctx: ?*anyopaque) void {
        const self: *Agent = @ptrCast(@alignCast(ctx));
        self.processEvent(event);
    }

    fn processEvent(self: *Agent, event: protocol.AgentEvent) void {
        const effects = self.in_flight.applyEvent(event);
        self.applyConversationEffects(effects);

        for (self.listeners.items) |listener| {
            listener.func(event, listener.ctx);
        }
    }

    fn applyConversationEffects(self: *Agent, effects: conversation_state.ApplyEventResult) void {
        if (effects.immediate_commit) |message| {
            self.appendCommittedMessage(message);
        }
        if (effects.turn_commit) |turn| {
            self.appendCommittedMessage(.{ .assistant = turn.assistant });
            for (turn.tool_results) |tool_result| {
                self.appendCommittedMessage(.{ .tool_result = tool_result });
            }
            if (turn.error_message) |error_message| {
                self.error_message = self.history_arena.allocator().dupe(u8, error_message) catch error_message;
            }
        }
    }
};

pub fn defaultConvertToLlm(
    allocator: std.mem.Allocator,
    messages: []const protocol.AgentMessage,
    _: ?*anyopaque,
) []const ai.protocol.Message {
    var result: std.ArrayList(ai.protocol.Message) = .empty;
    for (messages) |msg| {
        switch (msg) {
            .user => |u| result.append(allocator, .{ .user = u }) catch continue,
            .assistant => |a| result.append(allocator, .{ .assistant = a }) catch continue,
            .tool_result => |t| result.append(allocator, .{ .tool_result = t }) catch continue,
            .compaction_summary, .branch_summary, .custom => {},
        }
    }
    return result.items;
}

pub fn defaultConvertToLlmHook() protocol.ConvertToLlmHook {
    return .{ .func = &defaultConvertToLlm, .ctx = null };
}

const unreachable_stream_hook: protocol.StreamHook = .{
    .func = &unreachableStreamFn,
    .ctx = null,
};

fn unreachableStreamFn(
    _: ?*anyopaque,
    _: std.mem.Allocator,
    _: protocol.Model,
    _: ai.protocol.Context,
    _: ai.protocol.SimpleStreamOptions,
    _: ai.provider.EventCallback,
    _: ?*anyopaque,
) void {
    @panic("Agent: no stream function configured");
}

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
        .timestamp = 2,
    };
}

fn makeToolResultMessage() protocol.ToolResultMessage {
    return .{
        .tool_call_id = "tool-1",
        .tool_name = "read",
        .content = &.{.{ .text = .{ .text = "done" } }},
        .is_error = false,
        .timestamp = 3,
    };
}

test "conversation view keeps current turn separate until turn_end" {
    var agent = try Agent.init(testing.allocator, .{
        .model = .{
            .id = "unknown",
            .name = "unknown",
            .api = .{ .custom = "unknown" },
            .provider = .{ .custom = "unknown" },
            .base_url = "",
            .reasoning = false,
            .input = &.{},
            .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
            .context_window = 0,
            .max_tokens = 0,
        },
    });
    defer agent.deinit();

    agent.processEvent(.{ .message_end = .{ .message = .{ .user = .{
        .content = .{ .text = "prompt" },
        .timestamp = 1,
    } } } });

    const assistant = makeAssistantMessage();
    const tool_result = makeToolResultMessage();
    agent.processEvent(.{ .message_start = .{ .message = .{ .assistant = assistant } } });
    agent.processEvent(.{ .message_end = .{ .message = .{ .assistant = assistant } } });
    agent.processEvent(.{ .tool_execution_start = .{
        .tool_call_id = "tool-1",
        .tool_name = "read",
        .args = .null,
    } });
    agent.processEvent(.{ .tool_execution_end = .{
        .tool_call_id = "tool-1",
        .tool_name = "read",
        .result = .{ .content = &.{.{ .text = .{ .text = "done" } }}, .is_error = false },
        .is_error = false,
    } });
    agent.processEvent(.{ .message_end = .{ .message = .{ .tool_result = tool_result } } });

    var view = try agent.cloneConversationView(testing.allocator);
    defer view.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), view.committed.len);
    try testing.expect(view.in_flight != null);
    try testing.expect(view.in_flight.?.assistant != null);
    try testing.expectEqual(@as(usize, 1), view.in_flight.?.tool_executions.len);
    try testing.expectEqualStrings("tool-1", view.in_flight.?.tool_executions[0].tool_call_id);
    try testing.expect(view.in_flight.?.tool_executions[0].result_message != null);

    agent.processEvent(.{ .turn_end = .{
        .message = .{ .assistant = assistant },
        .tool_results = &.{tool_result},
    } });

    var committed = try agent.cloneConversationView(testing.allocator);
    defer committed.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), committed.committed.len);
    try testing.expect(committed.in_flight == null);
}

test "truncateCommitted drops tail without rebuilding history" {
    const initial_messages = [_]protocol.AgentMessage{
        .{ .user = .{ .content = .{ .text = "hello" }, .timestamp = 1 } },
        .{ .assistant = .{
            .content = &.{},
            .api = .openai_responses,
            .provider = .openai,
            .model = "gpt-test",
            .usage = .{
                .input = 0,
                .output = 0,
                .cache_read = 0,
                .cache_write = 0,
                .total_tokens = 0,
                .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 },
            },
            .stop_reason = .@"error",
            .error_message = "retry me",
            .timestamp = 2,
        } },
    };

    var agent = try Agent.init(testing.allocator, .{
        .model = .{
            .id = "unknown",
            .name = "unknown",
            .api = .{ .custom = "unknown" },
            .provider = .{ .custom = "unknown" },
            .base_url = "",
            .reasoning = false,
            .input = &.{},
            .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
            .context_window = 0,
            .max_tokens = 0,
        },
        .messages = &initial_messages,
    });
    defer agent.deinit();

    agent.truncateCommitted(1);

    try testing.expectEqual(@as(usize, 1), agent.messages().len);
    try testing.expect(agent.messages()[0] == .user);
}
