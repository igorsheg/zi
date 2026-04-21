const abort_signal_mod = @import("../abort_signal.zig");
const std = @import("std");
const ai = @import("../ai/root.zig");
const protocol = @import("types.zig");
const control_mod = @import("control.zig");
const conversation_state = @import("conversation_state.zig");
const loop_mod = @import("loop.zig");
const message_memory = @import("message_memory.zig");
const profile = @import("../debug/profile.zig");
const shared_committed_mod = @import("shared_committed.zig");
const SharedCommitted = shared_committed_mod.SharedCommitted;
const testing = std.testing;

pub const QueueMode = control_mod.QueueMode;

const Listener = struct {
    id: u64,
    func: *const fn (event: protocol.AgentEvent, ctx: ?*anyopaque) void,
    ctx: ?*anyopaque,
};

pub const SubscriptionToken = struct {
    id: u64,
};

pub const Agent = struct {
    allocator: std.mem.Allocator,
    history_arena: std.heap.ArenaAllocator,
    runtime_arena: std.heap.ArenaAllocator,

    listeners: std.ArrayList(Listener),
    next_listener_id: u64,
    /// P3: authoritative committed history. Refcounted shared handle;
    /// each publish retains this rather than deep-copying. Replaced
    /// atomically on append/truncate/reset/setMessages (release old,
    /// install new). Segments keep older snapshots alive for outstanding
    /// published views.
    shared_committed: *SharedCommitted,
    in_flight: conversation_state.InFlightState,

    run_control: control_mod.RunControl,

    system_prompt: []const u8,
    model: protocol.Model,
    tools: []const protocol.AgentTool,
    thinking_level: protocol.ThinkingLevel,

    convert_to_llm: protocol.ConvertToLlmHook,
    transform_context: ?protocol.TransformContextHook,
    stream_fn: protocol.StreamHook,
    before_tool_call: ?protocol.BeforeToolCallHook,
    after_tool_call: ?protocol.AfterToolCallHook,
    on_payload: ?protocol.OnPayloadHook,
    get_api_key: ?protocol.GetApiKeyHook,

    session_id: ?[]const u8,
    thinking_budgets: ?ai.protocol.ThinkingBudgets,
    transport: ?ai.protocol.Transport,
    max_retry_delay_ms: ?u64,
    tool_execution: protocol.ToolExecutionMode,
    default_stream_bundle: ?*ai.provider_defaults.Bundle,
    default_stream_closure: ?*DefaultStreamClosure,
    state_pending_tool_calls: std.ArrayList([]const u8),

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
        on_payload: ?protocol.OnPayloadHook = null,
        steering_mode: QueueMode = .one_at_a_time,
        follow_up_mode: QueueMode = .one_at_a_time,
        session_id: ?[]const u8 = null,
        thinking_budgets: ?ai.protocol.ThinkingBudgets = null,
        transport: ?ai.protocol.Transport = null,
        max_retry_delay_ms: ?u64 = null,
        tool_execution: protocol.ToolExecutionMode = .parallel,
        get_api_key: ?protocol.GetApiKeyHook = null,
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) !Agent {
        var history_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer history_arena.deinit();
        var runtime_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer runtime_arena.deinit();

        const initial_shared = try SharedCommitted.fromMessages(allocator, options.messages);
        errdefer initial_shared.release();

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

        var default_stream_bundle: ?*ai.provider_defaults.Bundle = null;
        errdefer if (default_stream_bundle) |bundle| bundle.deinit();
        var default_stream_closure: ?*DefaultStreamClosure = null;
        errdefer if (default_stream_closure) |closure| allocator.destroy(closure);

        const stream_fn = if (options.stream_fn) |stream_fn|
            stream_fn
        else blk: {
            const bundle = try ai.provider_defaults.Bundle.init(allocator);
            default_stream_bundle = bundle;

            const closure = try allocator.create(DefaultStreamClosure);
            closure.* = .{ .registry = bundle.registry };
            default_stream_closure = closure;

            break :blk protocol.StreamHook{
                .func = &DefaultStreamClosure.streamFn,
                .ctx = @ptrCast(closure),
            };
        };

        return .{
            .allocator = allocator,
            .history_arena = history_arena,
            .runtime_arena = runtime_arena,
            .listeners = .empty,
            .next_listener_id = 1,
            .shared_committed = initial_shared,
            .in_flight = conversation_state.InFlightState.init(allocator),
            .run_control = run_control,
            .system_prompt = options.system_prompt,
            .model = options.model,
            .tools = options.tools,
            .thinking_level = options.thinking_level,
            .convert_to_llm = options.convert_to_llm orelse defaultConvertToLlmHook(),
            .transform_context = options.transform_context,
            .stream_fn = stream_fn,
            .before_tool_call = options.before_tool_call,
            .after_tool_call = options.after_tool_call,
            .on_payload = options.on_payload,
            .get_api_key = options.get_api_key,
            .session_id = owned_session_id,
            .thinking_budgets = options.thinking_budgets,
            .transport = options.transport,
            .max_retry_delay_ms = options.max_retry_delay_ms,
            .tool_execution = options.tool_execution,
            .default_stream_bundle = default_stream_bundle,
            .default_stream_closure = default_stream_closure,
            .state_pending_tool_calls = .empty,
            .is_running = std.atomic.Value(bool).init(false),
            .abort_controller = .{},
        };
    }

    pub fn deinit(self: *Agent) void {
        self.listeners.deinit(self.allocator);
        self.state_pending_tool_calls.deinit(self.allocator);
        self.in_flight.deinit();
        self.run_control.deinit();
        self.shared_committed.release();
        self.runtime_arena.deinit();
        self.history_arena.deinit();
        if (self.session_id) |session_id| self.allocator.free(session_id);
        if (self.default_stream_closure) |closure| self.allocator.destroy(closure);
        if (self.default_stream_bundle) |bundle| bundle.deinit();
        self.* = undefined;
    }

    pub fn subscribe(
        self: *Agent,
        func: *const fn (event: protocol.AgentEvent, ctx: ?*anyopaque) void,
        ctx: ?*anyopaque,
    ) SubscriptionToken {
        const id = self.next_listener_id;
        self.next_listener_id +%= 1;
        self.listeners.append(self.allocator, .{ .id = id, .func = func, .ctx = ctx }) catch return .{ .id = 0 };
        return .{ .id = id };
    }

    pub fn unsubscribe(self: *Agent, token: SubscriptionToken) void {
        if (token.id == 0) return;
        for (self.listeners.items, 0..) |listener, index| {
            if (listener.id == token.id) {
                _ = self.listeners.orderedRemove(index);
                return;
            }
        }
    }

    pub fn steer(self: *Agent, message: protocol.AgentMessage) control_mod.EnqueueResult {
        return self.run_control.enqueue(.steering, message);
    }

    pub fn followUp(self: *Agent, message: protocol.AgentMessage) control_mod.EnqueueResult {
        return self.run_control.enqueue(.follow_up, message);
    }

    pub fn hasQueuedMessages(self: *Agent) bool {
        return self.run_control.hasQueuedMessages();
    }

    pub fn clearSteeringQueue(self: *Agent) void {
        self.run_control.clearSteering();
    }

    pub fn clearFollowUpQueue(self: *Agent) void {
        self.run_control.clearFollowUp();
    }

    pub fn clearAllQueues(self: *Agent) void {
        self.clearSteeringQueue();
        self.clearFollowUpQueue();
    }

    pub fn snapshotQueuedMessages(self: *Agent, allocator: std.mem.Allocator) control_mod.QueuedMessageSnapshot {
        return self.run_control.snapshot(allocator);
    }

    pub fn takeQueuedMessagesAndClear(self: *Agent, allocator: std.mem.Allocator) control_mod.QueuedMessageSnapshot {
        return self.run_control.clearAndSnapshot(allocator);
    }

    pub fn currentQueuedVersion(self: *const Agent) u64 {
        return self.run_control.currentVersion();
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
        return self.shared_committed.flat;
    }

    pub fn latestAssistant(self: *const Agent) ?protocol.AssistantMessage {
        const flat = self.shared_committed.flat;
        var i = flat.len;
        while (i > 0) {
            i -= 1;
            switch (flat[i]) {
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

    pub fn state(self: *Agent) protocol.AgentState {
        return .{
            .system_prompt = self.system_prompt,
            .model = self.model,
            .thinking_level = self.thinking_level,
            .tools = self.tools,
            .messages = self.shared_committed.flat,
            .is_streaming = self.is_streaming,
            .streaming_message = if (self.in_flight.assistant_streaming and self.in_flight.assistant != null)
                .{ .assistant = self.in_flight.assistant.? }
            else
                null,
            .pending_tool_calls = self.rebuildPendingToolCalls(),
            .error_message = self.error_message,
        };
    }

    pub fn setSessionId(self: *Agent, session_id: ?[]const u8) !void {
        const owned = if (session_id) |value| try self.allocator.dupe(u8, value) else null;
        if (self.session_id) |old| self.allocator.free(old);
        self.session_id = owned;
    }

    pub fn setMessages(self: *Agent, new_messages: []const protocol.AgentMessage) !void {
        // Build the new shared prefix BEFORE touching existing state, so
        // any allocation failure leaves the agent untouched.
        const new_shared = try SharedCommitted.fromMessages(self.allocator, new_messages);
        errdefer new_shared.release();

        const old_shared = self.shared_committed;
        self.shared_committed = new_shared;
        old_shared.release();

        self.resetHistoryArena();
        self.clearInFlight();
    }

    pub fn truncateCommitted(self: *Agent, new_len: usize) !void {
        const current = self.shared_committed;
        std.debug.assert(new_len <= current.flat.len);
        if (new_len == current.flat.len) return;

        // Cold path: rebuild a fresh shared prefix from the first
        // new_len messages. Old shared stays alive in any outstanding
        // published views until they drain. Propagates OOM so callers
        // can avoid acting on a half-applied truncate.
        const new_shared = try SharedCommitted.fromMessages(self.allocator, current.flat[0..new_len]);
        self.shared_committed = new_shared;
        current.release();
    }

    pub fn reset(self: *Agent) !void {
        // Allocate the new empty prefix first so that a failure here
        // leaves the agent untouched. Propagates OOM — callers must
        // avoid mutating adjacent state (e.g. session store swap)
        // before this succeeds.
        const empty_shared = try SharedCommitted.empty(self.allocator);
        const old = self.shared_committed;
        self.shared_committed = empty_shared;
        old.release();

        self.resetHistoryArena();
        self.resetRuntimeArena();
        self.is_streaming = false;
        self.error_message = null;
        self.clearAllQueues();
    }

    pub fn retainCommitted(self: *const Agent) *SharedCommitted {
        const mutable: *SharedCommitted = @constCast(self.shared_committed);
        return mutable.retain();
    }

    pub fn cloneConversationView(self: *const Agent, allocator: std.mem.Allocator) !conversation_state.ConversationView {
        var clone_timer = profile.ScopedTimer.begin(.clone_conversation_view);
        defer clone_timer.end();

        const in_flight = try self.in_flight.freeze(allocator);
        errdefer if (in_flight) |*frozen| {
            var mut = frozen.*;
            mut.deinit(allocator);
        };

        return .{
            .committed = self.retainCommitted(),
            .in_flight = in_flight,
        };
    }

    pub fn cloneInFlightTurn(self: *const Agent, allocator: std.mem.Allocator) !?conversation_state.InFlightTurn {
        return self.in_flight.freeze(allocator);
    }

    pub fn currentFrontierLocator(self: *const Agent) ?conversation_state.FrontierLocator {
        return self.in_flight.currentLocator();
    }

    pub fn prompt(self: *Agent, prompts: []const protocol.AgentMessage) !void {
        if (self.is_running.load(.acquire)) return error.AlreadyProcessing;
        self.runWithLifecycle(prompts, false, false);
    }

    pub fn continueTurn(self: *Agent) !void {
        if (self.is_running.load(.acquire)) return error.AlreadyProcessing;
        const flat = self.shared_committed.flat;
        if (flat.len == 0) return error.NoMessages;

        const last = flat[flat.len - 1];
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

    fn rebuildPendingToolCalls(self: *Agent) []const []const u8 {
        self.state_pending_tool_calls.clearRetainingCapacity();
        for (self.in_flight.tool_executions.items) |*tool| {
            if (!tool.execution_started) continue;
            if (tool.result != null and !tool.is_partial) continue;
            self.state_pending_tool_calls.append(self.allocator, tool.tool_call_id) catch break;
        }
        return self.state_pending_tool_calls.items;
    }

    fn resetHistoryArena(self: *Agent) void {
        // Resets the scratch arena used for fields that still live in it
        // (currently just `self.error_message`). Committed history is
        // owned by `self.shared_committed` and must be replaced
        // separately — see setMessages / truncateCommitted / reset.
        self.history_arena.deinit();
        self.history_arena = std.heap.ArenaAllocator.init(self.allocator);
        self.error_message = null;
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
        // P3 hot path: build a new SharedCommitted that appends a fresh
        // segment holding the deep-copied message. The old handle is
        // released — its segments stay alive via the new handle, plus
        // any outstanding published views.
        const new_shared = SharedCommitted.appendMessage(
            self.allocator,
            self.shared_committed,
            message,
        ) catch return;
        const old = self.shared_committed;
        self.shared_committed = new_shared;
        old.release();
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
            .messages = self.shared_committed.flat,
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
            .tool_execution = self.tool_execution,
            .before_tool_call = self.before_tool_call,
            .after_tool_call = self.after_tool_call,
            .on_payload = self.on_payload,
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

    fn drainQueuedMessages(self: *Agent, kind: control_mod.QueueKind, allocator: std.mem.Allocator) []const protocol.AgentMessage {
        return switch (kind) {
            .steering => self.run_control.drainSteering(allocator),
            .follow_up => self.run_control.drainFollowUp(allocator),
        };
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

const DefaultStreamClosure = struct {
    registry: *ai.provider.Registry,

    fn streamFn(
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        model: protocol.Model,
        context: ai.protocol.Context,
        options: ai.protocol.SimpleStreamOptions,
        callback: ai.provider.EventCallback,
        callback_ctx: ?*anyopaque,
    ) void {
        const self: *const DefaultStreamClosure = @ptrCast(@alignCast(ctx.?));
        const api_str = ai.provider.apiToString(model.api);
        const prov = self.registry.get(api_str) orelse {
            emitMissingProviderError(allocator, model, api_str, callback, callback_ctx);
            return;
        };
        prov.streamSimple(allocator, model, context, options, callback, callback_ctx);
    }
};

fn emitMissingProviderError(
    allocator: std.mem.Allocator,
    model: protocol.Model,
    api_str: []const u8,
    callback: ai.provider.EventCallback,
    callback_ctx: ?*anyopaque,
) void {
    const err_message = std.fmt.allocPrint(allocator, "No provider registered for API {s}", .{api_str}) catch "No provider registered for requested API";
    callback(.{ .@"error" = .{
        .reason = .@"error",
        .@"error" = .{
            .content = &.{},
            .api = model.api,
            .provider = model.provider,
            .model = model.id,
            .usage = .{
                .input = 0,
                .output = 0,
                .cache_read = 0,
                .cache_write = 0,
                .total_tokens = 0,
                .cost = .{
                    .input = 0,
                    .output = 0,
                    .cache_read = 0,
                    .cache_write = 0,
                    .total = 0,
                },
            },
            .stop_reason = .@"error",
            .error_message = err_message,
            .timestamp = std.time.milliTimestamp(),
        },
    } }, callback_ctx);
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

    try testing.expectEqual(@as(usize, 1), view.committed.flat.len);
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

    try testing.expectEqual(@as(usize, 3), committed.committed.flat.len);
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

    try agent.truncateCommitted(1);

    try testing.expectEqual(@as(usize, 1), agent.messages().len);
    try testing.expect(agent.messages()[0] == .user);
}

test "unsubscribe tokens stay valid after earlier listeners are removed" {
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

    const Counter = struct {
        fn onEvent(_: protocol.AgentEvent, raw_ctx: ?*anyopaque) void {
            const count: *u32 = @ptrCast(@alignCast(raw_ctx.?));
            count.* += 1;
        }
    };

    var first_count: u32 = 0;
    var second_count: u32 = 0;
    const first = agent.subscribe(Counter.onEvent, @ptrCast(&first_count));
    const second = agent.subscribe(Counter.onEvent, @ptrCast(&second_count));

    agent.unsubscribe(first);
    agent.processEvent(.agent_start);
    try testing.expectEqual(@as(u32, 0), first_count);
    try testing.expectEqual(@as(u32, 1), second_count);

    agent.unsubscribe(second);
    agent.processEvent(.agent_start);
    try testing.expectEqual(@as(u32, 0), first_count);
    try testing.expectEqual(@as(u32, 1), second_count);
}

test "state exposes streaming assistant only during assistant streaming" {
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

    const assistant = makeAssistantMessage();
    agent.processEvent(.{ .message_start = .{ .message = .{ .assistant = assistant } } });
    var state = agent.state();
    try testing.expect(state.streaming_message != null);
    try testing.expect(state.streaming_message.? == .assistant);

    agent.processEvent(.{ .message_update = .{
        .message = .{ .assistant = assistant },
        .assistant_message_event = .{ .text_start = .{
            .content_index = 0,
            .partial = assistant,
        } },
    } });
    state = agent.state();
    try testing.expect(state.streaming_message != null);
    try testing.expect(state.streaming_message.? == .assistant);

    agent.processEvent(.{ .message_end = .{ .message = .{ .assistant = assistant } } });
    state = agent.state();
    try testing.expect(state.streaming_message == null);
}

test "state pending tool calls follow pi-mono execution lifecycle" {
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

    const assistant = makeAssistantMessage();
    agent.processEvent(.{ .message_start = .{ .message = .{ .assistant = assistant } } });
    agent.processEvent(.{ .tool_execution_start = .{
        .tool_call_id = "tool-1",
        .tool_name = "read",
        .args = .null,
    } });

    var state = agent.state();
    try testing.expectEqual(@as(usize, 1), state.pending_tool_calls.len);
    try testing.expectEqualStrings("tool-1", state.pending_tool_calls[0]);

    agent.processEvent(.{ .tool_execution_update = .{
        .tool_call_id = "tool-1",
        .tool_name = "read",
        .args = .null,
        .partial_result = .{ .content = &.{}, .is_error = false },
    } });
    state = agent.state();
    try testing.expectEqual(@as(usize, 1), state.pending_tool_calls.len);
    try testing.expectEqualStrings("tool-1", state.pending_tool_calls[0]);

    agent.processEvent(.{ .tool_execution_end = .{
        .tool_call_id = "tool-1",
        .tool_name = "read",
        .result = .{ .content = &.{}, .is_error = false },
        .is_error = false,
    } });
    state = agent.state();
    try testing.expectEqual(@as(usize, 0), state.pending_tool_calls.len);
}

test "default stream fallback emits assistant error lifecycle without panic" {
    var agent = try Agent.init(testing.allocator, .{
        .model = .{
            .id = "missing-model",
            .name = "missing-model",
            .api = .{ .custom = "missing-api" },
            .provider = .{ .custom = "missing-provider" },
            .base_url = "",
            .reasoning = false,
            .input = &.{},
            .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
            .context_window = 0,
            .max_tokens = 0,
        },
    });
    defer agent.deinit();

    const Collector = struct {
        saw_assistant_start: bool = false,
        saw_assistant_end: bool = false,
        saw_agent_end: bool = false,

        fn onEvent(event: protocol.AgentEvent, raw_ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx.?));
            switch (event) {
                .message_start => |payload| {
                    if (payload.message == .assistant) self.saw_assistant_start = true;
                },
                .message_end => |payload| {
                    if (payload.message == .assistant) self.saw_assistant_end = true;
                },
                .agent_end => self.saw_agent_end = true,
                else => {},
            }
        }
    };

    var collector = Collector{};
    _ = agent.subscribe(Collector.onEvent, @ptrCast(&collector));

    const prompt = [_]protocol.AgentMessage{
        .{ .user = .{ .content = .{ .text = "hello" }, .timestamp = 1 } },
    };
    try agent.prompt(&prompt);

    const state = agent.state();
    try testing.expect(collector.saw_assistant_start);
    try testing.expect(collector.saw_assistant_end);
    try testing.expect(collector.saw_agent_end);
    try testing.expectEqual(@as(usize, 2), state.messages.len);
    try testing.expect(state.messages[1] == .assistant);
    try testing.expectEqual(ai.protocol.StopReason.@"error", state.messages[1].assistant.stop_reason);
    try testing.expect(state.error_message != null);
}
