const std = @import("std");
const protocol = @import("protocol.zig");
const loop_mod = @import("loop.zig");
const ai = @import("../ai/root.zig");

/// Queue mode for pending message queues.
/// pi-mono source: packages/agent/src/agent.ts:55
pub const QueueMode = enum {
    all,
    one_at_a_time,
};

/// FIFO queue for steering or follow-up messages.
/// Drain semantics depend on mode: `all` returns everything, `one_at_a_time` returns the first.
/// pi-mono source: packages/agent/src/agent.ts:112-143
pub const PendingMessageQueue = struct {
    messages: std.ArrayList(protocol.AgentMessage),
    mode: QueueMode,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, mode: QueueMode) PendingMessageQueue {
        return .{
            .messages = .empty,
            .mode = mode,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PendingMessageQueue) void {
        self.messages.deinit(self.allocator);
    }

    pub fn enqueue(self: *PendingMessageQueue, msg: protocol.AgentMessage) void {
        self.messages.append(self.allocator, msg) catch return;
    }

    pub fn hasItems(self: *const PendingMessageQueue) bool {
        return self.messages.items.len > 0;
    }

    /// Drain messages into an arena-allocated slice.
    /// `all`: returns all items, clears internal list.
    /// `one_at_a_time`: returns first item only, removes it from the front.
    pub fn drain(self: *PendingMessageQueue, arena: std.mem.Allocator) []const protocol.AgentMessage {
        if (self.messages.items.len == 0) return &.{};

        if (self.mode == .all) {
            const result = arena.dupe(protocol.AgentMessage, self.messages.items) catch return &.{};
            self.messages.clearRetainingCapacity();
            return result;
        }

        // one_at_a_time: take first element
        const first = self.messages.items[0];
        const result = arena.alloc(protocol.AgentMessage, 1) catch return &.{};
        result[0] = first;
        _ = self.messages.orderedRemove(0);
        return result;
    }

    pub fn clear(self: *PendingMessageQueue) void {
        self.messages.clearRetainingCapacity();
    }
};

/// Listener entry — function pointer + opaque context.
const Listener = struct {
    func: *const fn (event: protocol.AgentEvent, ctx: ?*anyopaque) void,
    ctx: ?*anyopaque,
};

/// Opaque token returned by subscribe(), used to unsubscribe.
pub const SubscriptionToken = struct {
    index: usize,
};

/// Stateful wrapper around the low-level agent loop.
///
/// Owns the current transcript, emits lifecycle events, executes tools,
/// and exposes queueing APIs for steering and follow-up messages.
///
/// pi-mono source: packages/agent/src/agent.ts:157-539
pub const Agent = struct {
    state: protocol.AgentState,
    listeners: std.ArrayList(Listener),
    steering_queue: PendingMessageQueue,
    follow_up_queue: PendingMessageQueue,

    convert_to_llm: protocol.ConvertToLlmHook,
    transform_context: ?protocol.TransformContextHook,
    stream_fn: protocol.StreamHook,
    before_tool_call: ?protocol.BeforeToolCallHook,
    after_tool_call: ?protocol.AfterToolCallHook,

    session_id: ?[]const u8,
    thinking_budgets: ?ai.protocol.ThinkingBudgets,
    transport: ?ai.protocol.Transport,
    max_retry_delay_ms: ?u64,
    tool_execution: protocol.ToolExecutionMode,

    is_running: bool,
    abort_requested: bool,

    /// Owned messages list — grows via processEvents on message_end.
    messages: std.ArrayList(protocol.AgentMessage),
    /// Pending tool call IDs tracked during execution.
    pending_tool_call_ids: std.ArrayList([]const u8),

    /// Arena for all message content that outlives the loop.
    /// Freed on reset() and deinit(). The loop allocates into this arena
    /// so message content (text, content blocks) survives after the loop returns.
    message_arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,

    pub const Options = struct {
        initial_state: ?protocol.AgentState = null,
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
        tool_execution: protocol.ToolExecutionMode = .parallel,
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) Agent {
        const initial = options.initial_state orelse protocol.AgentState{};
        var message_arena = std.heap.ArenaAllocator.init(allocator);
        var messages: std.ArrayList(protocol.AgentMessage) = .empty;
        for (initial.messages) |m| {
            messages.append(message_arena.allocator(), m) catch {};
        }
        return .{
            .state = initial,
            .listeners = .empty,
            .steering_queue = PendingMessageQueue.init(allocator, options.steering_mode),
            .follow_up_queue = PendingMessageQueue.init(allocator, options.follow_up_mode),
            .convert_to_llm = options.convert_to_llm orelse defaultConvertToLlmHook(),
            .transform_context = options.transform_context,
            .stream_fn = options.stream_fn orelse unreachable_stream_hook,
            .before_tool_call = options.before_tool_call,
            .after_tool_call = options.after_tool_call,
            .session_id = options.session_id,
            .thinking_budgets = options.thinking_budgets,
            .transport = options.transport,
            .max_retry_delay_ms = options.max_retry_delay_ms,
            .tool_execution = options.tool_execution,
            .is_running = false,
            .abort_requested = false,
            .messages = messages,
            .pending_tool_call_ids = .empty,
            .message_arena = message_arena,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Agent) void {
        self.listeners.deinit(self.allocator);
        self.steering_queue.deinit();
        self.follow_up_queue.deinit();
        // messages and pending_tool_call_ids are in message_arena — freed by arena deinit
        self.message_arena.deinit();
    }

    /// Subscribe to agent lifecycle events. Returns a token for unsubscribing.
    /// Listeners are called synchronously in subscription order after state reduction.
    pub fn subscribe(
        self: *Agent,
        func: *const fn (event: protocol.AgentEvent, ctx: ?*anyopaque) void,
        ctx: ?*anyopaque,
    ) SubscriptionToken {
        const index = self.listeners.items.len;
        self.listeners.append(self.allocator, .{ .func = func, .ctx = ctx }) catch return .{ .index = std.math.maxInt(usize) };
        return .{ .index = index };
    }

    /// Remove a previously registered listener by token.
    pub fn unsubscribe(self: *Agent, token: SubscriptionToken) void {
        if (token.index < self.listeners.items.len) {
            _ = self.listeners.orderedRemove(token.index);
        }
    }

    /// Queue a steering message to be injected after the current assistant turn finishes.
    pub fn steer(self: *Agent, message: protocol.AgentMessage) void {
        self.steering_queue.enqueue(message);
    }

    /// Queue a follow-up message to run only after the agent would otherwise stop.
    pub fn followUp(self: *Agent, message: protocol.AgentMessage) void {
        self.follow_up_queue.enqueue(message);
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

    /// Set the abort flag. The loop checks this between turns.
    pub fn abort(self: *Agent) void {
        if (self.is_running) {
            self.abort_requested = true;
        }
    }

    /// Clear transcript state, runtime state, and queued messages.
    /// pi-mono source: packages/agent/src/agent.ts:299-307
    pub fn reset(self: *Agent) void {
        // Reset arena — frees all message content in O(1)
        _ = self.message_arena.reset(.retain_capacity);
        self.messages = .empty;
        self.state.messages = &.{};
        self.state.is_streaming = false;
        self.state.streaming_message = null;
        self.state.pending_tool_calls = &.{};
        self.state.error_message = null;
        self.pending_tool_call_ids = .empty;
        self.clearAllQueues();
    }

    /// Start a new prompt. Blocks until loop completes.
    /// Returns error.AlreadyProcessing if a run is already active.
    /// pi-mono source: packages/agent/src/agent.ts:312-320
    pub fn prompt(self: *Agent, messages_in: []const protocol.AgentMessage) !void {
        if (self.is_running) return error.AlreadyProcessing;
        self.runWithLifecycle(messages_in, false, false);
    }

    /// Continue from the current transcript.
    /// If the last message is assistant, drains steering then follow-up queues first.
    /// pi-mono source: packages/agent/src/agent.ts:323-350
    pub fn @"continue"(self: *Agent) !void {
        if (self.is_running) return error.AlreadyProcessing;
        if (self.messages.items.len == 0) return error.NoMessages;

        const last = self.messages.items[self.messages.items.len - 1];
        if (last == .assistant) {
            if (self.steering_queue.hasItems()) {
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const queued = self.steering_queue.drain(arena.allocator());
                if (queued.len > 0) {
                    self.runWithLifecycle(queued, false, true);
                    return;
                }
            }

            if (self.follow_up_queue.hasItems()) {
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const queued = self.follow_up_queue.drain(arena.allocator());
                if (queued.len > 0) {
                    self.runWithLifecycle(queued, false, false);
                    return;
                }
            }

            return error.CannotContinueFromAssistant;
        }

        self.runWithLifecycle(null, true, false);
    }

    /// Run the loop with proper lifecycle management.
    /// pi-mono source: packages/agent/src/agent.ts:434-457
    fn runWithLifecycle(self: *Agent, prompt_messages: ?[]const protocol.AgentMessage, is_continue: bool, skip_initial_steering_poll: bool) void {
        self.is_running = true;
        self.state.is_streaming = true;
        self.state.streaming_message = null;
        self.state.error_message = null;
        self.abort_requested = false;

        defer {
            self.is_running = false;
            self.state.is_streaming = false;
            self.state.streaming_message = null;
            self.pending_tool_call_ids.clearRetainingCapacity();
            self.state.pending_tool_calls = &.{};
        }

        const config = self.createLoopConfig(skip_initial_steering_poll);
        const context = self.createContextSnapshot();

        if (is_continue) {
            loop_mod.runAgentLoopContinue(
                self.message_arena.allocator(),
                context,
                config,
                processEventsSink,
                @ptrCast(self),
                @ptrCast(&self.abort_requested),
            ) catch {};
        } else {
            loop_mod.runAgentLoop(
                self.message_arena.allocator(),
                prompt_messages.?,
                context,
                config,
                processEventsSink,
                @ptrCast(self),
                @ptrCast(&self.abort_requested),
            );
        }
    }

    /// Snapshot the current context for the loop.
    fn createContextSnapshot(self: *const Agent) protocol.AgentContext {
        return .{
            .system_prompt = self.state.system_prompt,
            .messages = self.messages.items,
            .tools = if (self.state.tools.len > 0) self.state.tools else null,
        };
    }

    /// Build the loop config from current agent state and hooks.
    /// pi-mono source: packages/agent/src/agent.ts:407-432
    fn createLoopConfig(self: *Agent, skip_initial_steering_poll: bool) protocol.AgentLoopConfig {
        return .{
            .model = self.state.model,
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
            .tool_execution = self.tool_execution,
            .before_tool_call = self.before_tool_call,
            .after_tool_call = self.after_tool_call,
            .session_id = self.session_id,
            .max_retry_delay_ms = self.max_retry_delay_ms,
            .thinking_budgets = self.thinking_budgets,
            .transport = self.transport,
        };
    }

    fn drainSteeringMessages(allocator: std.mem.Allocator, ctx: ?*anyopaque) []const protocol.AgentMessage {
        const self: *Agent = @ptrCast(@alignCast(ctx));
        return self.steering_queue.drain(allocator);
    }

    fn drainFollowUpMessages(allocator: std.mem.Allocator, ctx: ?*anyopaque) []const protocol.AgentMessage {
        const self: *Agent = @ptrCast(@alignCast(ctx));
        return self.follow_up_queue.drain(allocator);
    }

    /// Event sink callback — reduces state then notifies listeners.
    /// pi-mono source: packages/agent/src/agent.ts:491-538
    fn processEventsSink(event: protocol.AgentEvent, ctx: ?*anyopaque) void {
        const self: *Agent = @ptrCast(@alignCast(ctx));
        self.processEvent(event);
    }

    fn processEvent(self: *Agent, event: protocol.AgentEvent) void {
        switch (event) {
            .message_start => |payload| {
                self.state.streaming_message = payload.message;
            },
            .message_update => |payload| {
                self.state.streaming_message = payload.message;
            },
            .message_end => |payload| {
                self.state.streaming_message = null;
                self.messages.append(self.message_arena.allocator(), payload.message) catch {};
                self.state.messages = self.messages.items;
            },
            .tool_execution_start => |payload| {
                self.pending_tool_call_ids.append(self.message_arena.allocator(), payload.tool_call_id) catch {};
                self.state.pending_tool_calls = self.pending_tool_call_ids.items;
            },
            .tool_execution_end => |payload| {
                for (self.pending_tool_call_ids.items, 0..) |id, i| {
                    if (std.mem.eql(u8, id, payload.tool_call_id)) {
                        _ = self.pending_tool_call_ids.orderedRemove(i);
                        break;
                    }
                }
                self.state.pending_tool_calls = self.pending_tool_call_ids.items;
            },
            .turn_end => |payload| {
                if (payload.message == .assistant) {
                    if (payload.message.assistant.error_message) |err_msg| {
                        self.state.error_message = err_msg;
                    }
                }
            },
            .agent_end => {
                self.state.streaming_message = null;
            },
            .agent_start, .turn_start, .tool_execution_update => {},
        }

        for (self.listeners.items) |listener| {
            listener.func(event, listener.ctx);
        }
    }
};

// -- Default hooks ----------------------------------------------------------

/// Default convertToLlm: pass through user/assistant/tool_result messages.
/// pi-mono source: packages/agent/src/agent.ts:27-31
pub fn defaultConvertToLlm(allocator: std.mem.Allocator, messages: []const protocol.AgentMessage, _: ?*anyopaque) []const ai.protocol.Message {
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

/// Sentinel stream hook — panics if called without being replaced.
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
