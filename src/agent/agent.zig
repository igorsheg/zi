const abort_signal_mod = @import("../abort_signal.zig");
const std = @import("std");
const protocol = @import("protocol.zig");
const conversation_mod = @import("conversation.zig");
const message_memory = @import("message_memory.zig");
const loop_mod = @import("loop.zig");
const ai = @import("../ai/root.zig");
const json_util = @import("../ai/json_util.zig");
const run_control_mod = @import("../runtime/run_control.zig");
const testing = std.testing;

pub const QueueMode = run_control_mod.QueueMode;
pub const QueuedMessageText = run_control_mod.QueuedMessageText;
pub const QueuedMessageSnapshot = run_control_mod.QueuedMessageSnapshot;

/// FIFO queue for steering or follow-up messages.
/// Drain semantics depend on mode: `all` returns everything, `one_at_a_time` returns the first.
/// pi-mono source: packages/agent/src/agent.ts:112-143
pub const PendingMessageQueue = struct {
    messages: std.ArrayList(protocol.AgentMessage),
    mode: QueueMode,
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, mode: QueueMode) PendingMessageQueue {
        return .{
            .messages = .empty,
            .mode = mode,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PendingMessageQueue) void {
        self.clear();
        self.messages.deinit(self.allocator);
    }

    pub fn enqueue(self: *PendingMessageQueue, msg: protocol.AgentMessage) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const owned = dupeAgentMessage(self.allocator, msg);
        self.messages.append(self.allocator, owned) catch {
            var mutable = owned;
            freeAgentMessage(self.allocator, &mutable);
        };
    }

    pub fn hasItems(self: *PendingMessageQueue) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.messages.items.len > 0;
    }

    /// Drain messages into an arena-allocated slice.
    /// `all`: returns all items, clears internal list.
    /// `one_at_a_time`: returns first item only, removes it from the front.
    pub fn drain(self: *PendingMessageQueue, arena: std.mem.Allocator) []const protocol.AgentMessage {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.messages.items.len == 0) return &.{};

        if (self.mode == .all) {
            const result = arena.alloc(protocol.AgentMessage, self.messages.items.len) catch return &.{};
            for (self.messages.items, 0..) |msg, i| {
                result[i] = dupeAgentMessage(arena, msg);
            }
            for (self.messages.items) |*msg| freeAgentMessage(self.allocator, msg);
            self.messages.clearRetainingCapacity();
            return result;
        }

        const first = self.messages.items[0];
        const result = arena.alloc(protocol.AgentMessage, 1) catch return &.{};
        result[0] = dupeAgentMessage(arena, first);
        var removed = self.messages.orderedRemove(0);
        freeAgentMessage(self.allocator, &removed);
        return result;
    }

    pub fn clear(self: *PendingMessageQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.messages.items) |*msg| freeAgentMessage(self.allocator, msg);
        self.messages.clearRetainingCapacity();
    }

    pub fn snapshotTexts(self: *PendingMessageQueue, allocator: std.mem.Allocator) []QueuedMessageText {
        self.mutex.lock();
        defer self.mutex.unlock();

        var out: std.ArrayList(QueuedMessageText) = .empty;
        defer out.deinit(allocator);

        for (self.messages.items) |msg| {
            const text = extractQueuedMessageText(msg) orelse continue;
            const owned = allocator.dupe(u8, text) catch {
                for (out.items) |entry| allocator.free(entry.text);
                return &.{};
            };
            out.append(allocator, .{ .text = owned }) catch {
                allocator.free(owned);
                for (out.items) |entry| allocator.free(entry.text);
                return &.{};
            };
        }
        return out.toOwnedSlice(allocator) catch {
            for (out.items) |entry| allocator.free(entry.text);
            return &.{};
        };
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

const FrontierState = struct {
    allocator: std.mem.Allocator,
    assistant: ?protocol.AssistantMessage = null,
    live_tools: std.ArrayList(conversation_mod.LiveToolExecution) = .empty,

    fn init(allocator: std.mem.Allocator) FrontierState {
        return .{
            .allocator = allocator,
            .live_tools = .empty,
        };
    }

    fn deinit(self: *FrontierState) void {
        self.clear();
        self.live_tools.deinit(self.allocator);
    }

    fn clear(self: *FrontierState) void {
        if (self.assistant) |*assistant| conversation_mod.freeAssistantMessage(self.allocator, assistant);
        self.assistant = null;
        for (self.live_tools.items) |*tool| tool.deinit(self.allocator);
        self.live_tools.clearRetainingCapacity();
    }

    fn replaceAssistant(self: *FrontierState, assistant: protocol.AssistantMessage) void {
        if (self.assistant) |*old| conversation_mod.freeAssistantMessage(self.allocator, old);
        self.assistant = conversation_mod.cloneAssistantMessage(self.allocator, assistant) catch null;
    }

    fn findToolIndex(self: *const FrontierState, tool_call_id: []const u8) ?usize {
        for (self.live_tools.items, 0..) |tool, idx| {
            if (std.mem.eql(u8, tool.tool_call_id, tool_call_id)) return idx;
        }
        return null;
    }

    fn ensureTool(self: *FrontierState, tool_call_id: []const u8, tool_name: []const u8) ?*conversation_mod.LiveToolExecution {
        if (self.findToolIndex(tool_call_id)) |idx| return &self.live_tools.items[idx];

        const owned_id = self.allocator.dupe(u8, tool_call_id) catch return null;
        errdefer self.allocator.free(owned_id);
        const owned_name = self.allocator.dupe(u8, tool_name) catch return null;
        errdefer self.allocator.free(owned_name);

        self.live_tools.append(self.allocator, .{
            .tool_call_id = owned_id,
            .tool_name = owned_name,
            .args = .null,
        }) catch return null;

        return &self.live_tools.items[self.live_tools.items.len - 1];
    }

    fn syncToolCall(self: *FrontierState, tool_call: ai.protocol.ToolCall, args_complete: bool) void {
        const tool = self.ensureTool(tool_call.id, tool_call.name) orelse return;
        json_util.freeJsonValue(self.allocator, tool.args);
        tool.args = json_util.cloneJsonValue(self.allocator, tool_call.arguments) catch .null;
        tool.args_complete = tool.args_complete or args_complete;
    }

    fn markExecutionStarted(self: *FrontierState, tool_call_id: []const u8, tool_name: []const u8, args: std.json.Value) void {
        const tool = self.ensureTool(tool_call_id, tool_name) orelse return;
        json_util.freeJsonValue(self.allocator, tool.args);
        tool.args = json_util.cloneJsonValue(self.allocator, args) catch .null;
        tool.execution_started = true;
    }

    fn setPartialResult(self: *FrontierState, tool_call_id: []const u8, result: ?protocol.AgentToolResult, is_error: bool) void {
        const idx = self.findToolIndex(tool_call_id) orelse return;
        const tool = &self.live_tools.items[idx];
        if (tool.result) |old| old.free(self.allocator);
        tool.result = if (result) |owned| (owned.clone(self.allocator) catch null) else null;
        tool.is_partial = true;
        tool.is_error = if (result) |owned| owned.is_error else is_error;
    }

    fn setFinalResult(self: *FrontierState, tool_call_id: []const u8, result: ?protocol.AgentToolResult, is_error: bool) void {
        const idx = self.findToolIndex(tool_call_id) orelse return;
        const tool = &self.live_tools.items[idx];
        if (tool.result) |old| old.free(self.allocator);
        tool.result = if (result) |owned| (owned.clone(self.allocator) catch null) else null;
        tool.is_partial = false;
        tool.is_error = if (result) |owned| owned.is_error else is_error;
    }

    fn setResultMessage(self: *FrontierState, result_message: protocol.ToolResultMessage) void {
        const tool = self.ensureTool(result_message.tool_call_id, result_message.tool_name) orelse return;
        if (tool.result_message) |*old| conversation_mod.freeToolResultMessage(self.allocator, old);
        tool.result_message = conversation_mod.cloneToolResultMessage(self.allocator, result_message) catch null;
        tool.is_error = result_message.is_error;
    }

    fn freeze(self: *const FrontierState, allocator: std.mem.Allocator) !conversation_mod.ConversationFrontier {
        var assistant = if (self.assistant) |assistant|
            try conversation_mod.cloneAssistantMessage(allocator, assistant)
        else
            null;
        errdefer if (assistant) |*owned| conversation_mod.freeAssistantMessage(allocator, owned);

        const live_tools = try allocator.alloc(conversation_mod.LiveToolExecution, self.live_tools.items.len);
        var initialized: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < initialized) : (i += 1) {
                live_tools[i].deinit(allocator);
            }
            allocator.free(live_tools);
        }

        for (self.live_tools.items, 0..) |tool, i| {
            live_tools[i] = try tool.clone(allocator);
            initialized += 1;
        }

        return .{
            .assistant = assistant,
            .live_tools = live_tools,
        };
    }
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
    external_run_control: ?*run_control_mod.RunControl = null,

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
    get_api_key: ?protocol.GetApiKeyHook,

    is_running: std.atomic.Value(bool),
    abort_controller: abort_signal_mod.AbortController,

    /// Owned messages list — grows via processEvents on message_end.
    messages: std.ArrayList(protocol.AgentMessage),
    /// Pending tool call IDs tracked during execution.
    pending_tool_call_ids: std.ArrayList([]const u8),
    /// Agent-owned hot conversation frontier for the current turn.
    conversation_frontier: FrontierState,
    frontier_active: bool = false,
    frontier_committed_prefix_len: usize = 0,

    /// Arena for transcript/history that must survive across runs.
    /// Replaced wholesale on reset/load/compaction so history memory can be reclaimed.
    history_arena: std.heap.ArenaAllocator,
    /// Arena for run-lifetime scratch that survives across turns within a single run.
    /// Reset at run start/end. Per-turn scratch lives in loop-local arenas.
    runtime_arena: std.heap.ArenaAllocator,
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
        get_api_key: ?protocol.GetApiKeyHook = null,
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) Agent {
        const initial = options.initial_state orelse protocol.AgentState{};
        var history_arena = std.heap.ArenaAllocator.init(allocator);
        const runtime_arena = std.heap.ArenaAllocator.init(allocator);
        const aa = history_arena.allocator();
        var messages: std.ArrayList(protocol.AgentMessage) = .empty;
        for (initial.messages) |m| {
            messages.append(aa, dupeAgentMessage(aa, m)) catch {};
        }
        // Sync state.messages to the owned copy so they share one backing store.
        // Dupe error_message if seeded from initial state.
        var state = initial;
        state.messages = messages.items;
        if (initial.error_message) |em| {
            state.error_message = aa.dupe(u8, em) catch em;
        }
        const owned_session_id = if (options.session_id) |sid|
            allocator.dupe(u8, sid) catch null
        else
            null;
        return .{
            .state = state,
            .listeners = .empty,
            .steering_queue = PendingMessageQueue.init(allocator, options.steering_mode),
            .follow_up_queue = PendingMessageQueue.init(allocator, options.follow_up_mode),
            .external_run_control = null,
            .convert_to_llm = options.convert_to_llm orelse defaultConvertToLlmHook(),
            .transform_context = options.transform_context,
            .stream_fn = options.stream_fn orelse unreachable_stream_hook,
            .before_tool_call = options.before_tool_call,
            .after_tool_call = options.after_tool_call,
            .session_id = owned_session_id,
            .thinking_budgets = options.thinking_budgets,
            .transport = options.transport,
            .max_retry_delay_ms = options.max_retry_delay_ms,
            .tool_execution = options.tool_execution,
            .get_api_key = options.get_api_key,
            .is_running = std.atomic.Value(bool).init(false),
            .abort_controller = .{},
            .messages = messages,
            .pending_tool_call_ids = .empty,
            .conversation_frontier = FrontierState.init(allocator),
            .frontier_active = false,
            .frontier_committed_prefix_len = messages.items.len,
            .history_arena = history_arena,
            .runtime_arena = runtime_arena,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Agent) void {
        self.listeners.deinit(self.allocator);
        self.steering_queue.deinit();
        self.follow_up_queue.deinit();
        self.conversation_frontier.deinit();
        self.runtime_arena.deinit();
        self.history_arena.deinit();
        if (self.session_id) |sid| self.allocator.free(sid);
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

    /// Bind an explicit run-scoped control surface for steering/follow-up.
    /// Interactive mode uses a `msg_allocator`-backed `RunControl` so queued
    /// messages stay observable while a prompt is already in flight without
    /// turning the main owner inbox into a side-channel.
    pub fn bindRunControl(self: *Agent, run_control: *run_control_mod.RunControl) void {
        self.external_run_control = run_control;
    }

    pub fn unbindRunControl(self: *Agent, run_control: *run_control_mod.RunControl) void {
        if (self.external_run_control == run_control) {
            self.external_run_control = null;
        }
    }

    pub fn runControl(self: *Agent) ?*run_control_mod.RunControl {
        return self.external_run_control;
    }

    /// Queue a steering message to be injected after the current assistant turn finishes.
    pub fn steer(self: *Agent, message: protocol.AgentMessage) void {
        if (self.external_run_control) |run_control| {
            _ = run_control.enqueue(.steering, message);
            return;
        }
        self.steering_queue.enqueue(message);
    }

    /// Queue a follow-up message to run only after the agent would otherwise stop.
    pub fn followUp(self: *Agent, message: protocol.AgentMessage) void {
        if (self.external_run_control) |run_control| {
            _ = run_control.enqueue(.follow_up, message);
            return;
        }
        self.follow_up_queue.enqueue(message);
    }

    pub fn clearSteeringQueue(self: *Agent) void {
        if (self.external_run_control) |run_control| {
            run_control.clearSteering();
            return;
        }
        self.steering_queue.clear();
    }

    pub fn clearFollowUpQueue(self: *Agent) void {
        if (self.external_run_control) |run_control| {
            run_control.clearFollowUp();
            return;
        }
        self.follow_up_queue.clear();
    }

    pub fn clearAllQueues(self: *Agent) void {
        if (self.external_run_control) |run_control| {
            run_control.clearAll();
            return;
        }
        self.clearSteeringQueue();
        self.clearFollowUpQueue();
    }

    pub fn snapshotQueuedMessages(self: *Agent, allocator: std.mem.Allocator) QueuedMessageSnapshot {
        if (self.external_run_control) |run_control| {
            return run_control.snapshot(allocator);
        }
        return .{
            .steering = self.steering_queue.snapshotTexts(allocator),
            .follow_up = self.follow_up_queue.snapshotTexts(allocator),
        };
    }

    pub fn clearQueuedMessages(self: *Agent, allocator: std.mem.Allocator) QueuedMessageSnapshot {
        if (self.external_run_control) |run_control| {
            return run_control.clearAndSnapshot(allocator);
        }
        const snapshot = self.snapshotQueuedMessages(allocator);
        self.clearAllQueues();
        return snapshot;
    }

    fn hasSteeringMessages(self: *Agent) bool {
        if (self.external_run_control) |run_control| {
            return run_control.hasSteeringMessages();
        }
        return self.steering_queue.hasItems();
    }

    fn hasFollowUpMessages(self: *Agent) bool {
        if (self.external_run_control) |run_control| {
            return run_control.hasFollowUpMessages();
        }
        return self.follow_up_queue.hasItems();
    }

    fn drainSteeringForContinue(self: *Agent, allocator: std.mem.Allocator) []const protocol.AgentMessage {
        if (self.external_run_control) |run_control| {
            return run_control.drainSteering(allocator);
        }
        return self.steering_queue.drain(allocator);
    }

    fn drainFollowUpForContinue(self: *Agent, allocator: std.mem.Allocator) []const protocol.AgentMessage {
        if (self.external_run_control) |run_control| {
            return run_control.drainFollowUp(allocator);
        }
        return self.follow_up_queue.drain(allocator);
    }

    fn resetHistoryArena(self: *Agent) void {
        self.history_arena.deinit();
        self.history_arena = std.heap.ArenaAllocator.init(self.allocator);
        self.messages = .empty;
        self.state.messages = &.{};
        self.frontier_committed_prefix_len = 0;
    }

    fn clearConversationFrontier(self: *Agent) void {
        self.conversation_frontier.clear();
        self.frontier_active = false;
        self.frontier_committed_prefix_len = self.messages.items.len;
    }

    fn activateConversationFrontier(self: *Agent) void {
        if (self.frontier_active) return;
        self.frontier_active = true;
        self.frontier_committed_prefix_len = self.messages.items.len;
        self.conversation_frontier.clear();
    }

    fn resetRuntimeArena(self: *Agent) void {
        self.runtime_arena.deinit();
        self.runtime_arena = std.heap.ArenaAllocator.init(self.allocator);
        self.pending_tool_call_ids = .empty;
        self.state.pending_tool_calls = &.{};
        self.clearConversationFrontier();
    }

    pub fn hasQueuedMessages(self: *Agent) bool {
        if (self.external_run_control) |run_control| {
            return run_control.hasQueuedMessages();
        }
        return self.steering_queue.hasItems() or self.follow_up_queue.hasItems();
    }

    /// Cross-thread-safe cancellation entrypoint for the current run.
    ///
    /// This is intentionally separate from mailbox request handling:
    /// a running prompt may be blocked in provider I/O or tool
    /// execution, so interrupt delivery must remain observable without
    /// waiting for the next request-drain boundary.
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

    /// Clear transcript state, runtime state, and queued messages.
    /// pi-mono source: packages/agent/src/agent.ts:299-307
    pub fn reset(self: *Agent) void {
        self.resetHistoryArena();
        self.resetRuntimeArena();
        self.state.is_streaming = false;
        self.state.streaming_message = null;
        self.state.error_message = null;
        self.clearAllQueues();
    }

    pub fn setSessionId(self: *Agent, session_id: ?[]const u8) !void {
        const owned = if (session_id) |sid|
            try self.allocator.dupe(u8, sid)
        else
            null;
        if (self.session_id) |old| self.allocator.free(old);
        self.session_id = owned;
    }

    /// Replace all messages (e.g., after loading a resumed session).
    /// Accepts slices that may alias the agent's current arena-backed transcript.
    pub fn loadMessages(self: *Agent, new_messages: []const protocol.AgentMessage) void {
        var staging_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer staging_arena.deinit();
        const staging_alloc = staging_arena.allocator();

        var staged: std.ArrayList(protocol.AgentMessage) = .empty;
        for (new_messages) |m| {
            staged.append(staging_alloc, dupeAgentMessage(staging_alloc, m)) catch {};
        }

        self.resetHistoryArena();
        self.clearConversationFrontier();
        const aa = self.history_arena.allocator();
        for (staged.items) |m| {
            self.messages.append(aa, dupeAgentMessage(aa, m)) catch {};
        }
        self.state.messages = self.messages.items;
        self.frontier_committed_prefix_len = self.messages.items.len;
    }

    pub fn cloneConversationSnapshot(self: *const Agent, allocator: std.mem.Allocator) !conversation_mod.ConversationSnapshot {
        const committed_end = if (self.frontier_active)
            self.frontier_committed_prefix_len
        else
            self.messages.items.len;
        const committed = try message_memory.cloneMessages(allocator, self.messages.items[0..committed_end]);
        errdefer message_memory.freeMessages(allocator, committed);

        const frontier = try self.cloneConversationFrontier(allocator);

        return .{
            .committed = committed,
            .frontier = frontier,
        };
    }

    pub fn cloneConversationFrontier(self: *const Agent, allocator: std.mem.Allocator) !?conversation_mod.ConversationFrontier {
        if (!self.frontier_active) return null;
        return try self.conversation_frontier.freeze(allocator);
    }

    /// Start a new prompt. Blocks until loop completes.
    /// Returns error.AlreadyProcessing if a run is already active.
    /// pi-mono source: packages/agent/src/agent.ts:312-320
    pub fn prompt(self: *Agent, messages_in: []const protocol.AgentMessage) !void {
        if (self.is_running.load(.acquire)) return error.AlreadyProcessing;
        self.runWithLifecycle(messages_in, false, false);
    }

    /// Continue from the current transcript.
    /// If the last message is assistant, drains steering then follow-up queues first.
    /// pi-mono source: packages/agent/src/agent.ts:323-350
    pub fn @"continue"(self: *Agent) !void {
        if (self.is_running.load(.acquire)) return error.AlreadyProcessing;
        if (self.messages.items.len == 0) return error.NoMessages;

        const last = self.messages.items[self.messages.items.len - 1];
        if (last == .assistant) {
            if (self.hasSteeringMessages()) {
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const queued = self.drainSteeringForContinue(arena.allocator());
                if (queued.len > 0) {
                    self.runWithLifecycle(queued, false, true);
                    return;
                }
            }

            if (self.hasFollowUpMessages()) {
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const queued = self.drainFollowUpForContinue(arena.allocator());
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
        self.is_running.store(true, .release);
        self.state.is_streaming = true;
        self.state.streaming_message = null;
        self.state.error_message = null;
        const signal = self.abort_controller.beginRun();

        self.resetRuntimeArena();

        defer {
            self.is_running.store(false, .release);
            self.state.is_streaming = false;
            self.state.streaming_message = null;
            self.state.pending_tool_calls = &.{};
            self.pending_tool_call_ids = .empty;
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
            .reasoning = mapThinkingLevel(self.state.thinking_level),
            .get_api_key = self.get_api_key,
        };
    }

    /// Maps agent ThinkingLevel to ai ThinkingLevel.
    /// pi-mono: agent.ts:411 — reasoning: thinkingLevel === "off" ? undefined : thinkingLevel
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
        if (self.external_run_control) |run_control| {
            return run_control.drainSteering(allocator);
        }
        return self.steering_queue.drain(allocator);
    }

    fn drainFollowUpMessages(allocator: std.mem.Allocator, ctx: ?*anyopaque) []const protocol.AgentMessage {
        const self: *Agent = @ptrCast(@alignCast(ctx));
        if (self.external_run_control) |run_control| {
            return run_control.drainFollowUp(allocator);
        }
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
                switch (payload.message) {
                    .assistant => |assistant| {
                        self.activateConversationFrontier();
                        self.conversation_frontier.replaceAssistant(assistant);
                    },
                    else => {},
                }
            },
            .message_update => |payload| {
                self.state.streaming_message = payload.message;
                switch (payload.message) {
                    .assistant => |assistant| {
                        self.activateConversationFrontier();
                        self.conversation_frontier.replaceAssistant(assistant);
                        switch (payload.assistant_message_event) {
                            .toolcall_delta => |tc| {
                                if (tc.content_index < tc.partial.content.len and tc.partial.content[tc.content_index] == .tool_call) {
                                    self.conversation_frontier.syncToolCall(tc.partial.content[tc.content_index].tool_call, false);
                                }
                            },
                            .toolcall_end => |tc| self.conversation_frontier.syncToolCall(tc.tool_call, true),
                            else => {},
                        }
                    },
                    else => {},
                }
            },
            .message_end => |payload| {
                self.state.streaming_message = null;
                const owned = dupeAgentMessage(self.history_arena.allocator(), payload.message);
                self.messages.append(self.history_arena.allocator(), owned) catch {};
                self.state.messages = self.messages.items;

                switch (payload.message) {
                    .assistant => |assistant| {
                        self.activateConversationFrontier();
                        self.conversation_frontier.replaceAssistant(assistant);
                        if (assistant.stop_reason != .aborted and assistant.stop_reason != .@"error") {
                            for (assistant.content) |block| switch (block) {
                                .tool_call => |tool_call| self.conversation_frontier.syncToolCall(tool_call, true),
                                else => {},
                            };
                        }
                    },
                    .tool_result => |tool_result| {
                        if (self.frontier_active) {
                            self.conversation_frontier.setResultMessage(tool_result);
                        }
                    },
                    else => {},
                }
            },
            .tool_execution_start => |payload| {
                if (self.runtime_arena.allocator().dupe(u8, payload.tool_call_id)) |owned_id| {
                    self.pending_tool_call_ids.append(self.runtime_arena.allocator(), owned_id) catch {};
                    self.state.pending_tool_calls = self.pending_tool_call_ids.items;
                } else |_| {}
                if (self.frontier_active) {
                    self.conversation_frontier.markExecutionStarted(payload.tool_call_id, payload.tool_name, payload.args);
                }
            },
            .tool_execution_update => |payload| {
                if (self.frontier_active) {
                    self.conversation_frontier.setPartialResult(payload.tool_call_id, payload.partial_result, if (payload.partial_result) |result| result.is_error else false);
                }
            },
            .tool_execution_end => |payload| {
                for (self.pending_tool_call_ids.items, 0..) |id, i| {
                    if (std.mem.eql(u8, id, payload.tool_call_id)) {
                        _ = self.pending_tool_call_ids.orderedRemove(i);
                        break;
                    }
                }
                self.state.pending_tool_calls = self.pending_tool_call_ids.items;
                if (self.frontier_active) {
                    self.conversation_frontier.setFinalResult(payload.tool_call_id, payload.result, payload.is_error);
                }
            },
            .turn_end => |payload| {
                if (payload.message == .assistant) {
                    if (payload.message.assistant.error_message) |err_msg| {
                        self.state.error_message = self.history_arena.allocator().dupe(u8, err_msg) catch err_msg;
                    }
                    self.clearConversationFrontier();
                }
            },
            .agent_end => {
                self.state.streaming_message = null;
            },
            .agent_start, .turn_start => {},
        }

        for (self.listeners.items) |listener| {
            listener.func(event, listener.ctx);
        }
    }
};

// -- Deep copy utility ------------------------------------------------------

/// Deep-copy an AgentMessage into the given allocator.
/// Copies all nested slices (text, content blocks, json values, string fields)
/// so the result is fully owned by the allocator and independent of the source.
///
/// Best-effort: if any individual allocation fails, that field falls back to
/// the borrowed original. This is acceptable because the allocator is typically
/// an arena — OOM means the arena is exhausted, and we're already degraded.
fn cloneJson(alloc: std.mem.Allocator, value: std.json.Value) std.json.Value {
    return json_util.cloneJsonValue(alloc, value) catch value;
}

fn cloneOptionalJson(alloc: std.mem.Allocator, value: ?std.json.Value) ?std.json.Value {
    const v = value orelse return null;
    return json_util.cloneJsonValue(alloc, v) catch v;
}

fn dupeAgentMessage(alloc: std.mem.Allocator, msg: protocol.AgentMessage) protocol.AgentMessage {
    return switch (msg) {
        .user => |u| .{ .user = dupeUserMessage(alloc, u) },
        .assistant => |a| .{ .assistant = dupeAssistantMessage(alloc, a) },
        .tool_result => |t| .{ .tool_result = dupeToolResultMessage(alloc, t) },
        .compaction_summary => |c| .{ .compaction_summary = .{
            .summary = alloc.dupe(u8, c.summary) catch c.summary,
            .tokens_before = c.tokens_before,
            .timestamp = c.timestamp,
        } },
        .branch_summary => |b| .{ .branch_summary = .{
            .summary = alloc.dupe(u8, b.summary) catch b.summary,
            .from_id = alloc.dupe(u8, b.from_id) catch b.from_id,
            .timestamp = b.timestamp,
        } },
        .custom => |c| .{ .custom = .{
            .custom_type = alloc.dupe(u8, c.custom_type) catch c.custom_type,
            .content = switch (c.content) {
                .text => |t| .{ .text = alloc.dupe(u8, t) catch t },
                .blocks => |b| .{ .blocks = dupeUserBlocks(alloc, b) },
            },
            .display = c.display,
            .details = cloneOptionalJson(alloc, c.details),
            .timestamp = c.timestamp,
        } },
    };
}

fn dupeUserMessage(alloc: std.mem.Allocator, msg: ai.protocol.UserMessage) ai.protocol.UserMessage {
    return .{
        .content = switch (msg.content) {
            .text => |t| .{ .text = alloc.dupe(u8, t) catch t },
            .blocks => |blocks| .{ .blocks = dupeUserBlocks(alloc, blocks) },
        },
        .timestamp = msg.timestamp,
    };
}

fn dupeUserBlocks(alloc: std.mem.Allocator, blocks: []const ai.protocol.UserMessage.UserMessageContent.Block) []const ai.protocol.UserMessage.UserMessageContent.Block {
    const duped = alloc.alloc(ai.protocol.UserMessage.UserMessageContent.Block, blocks.len) catch return blocks;
    for (blocks, 0..) |block, i| {
        duped[i] = switch (block) {
            .text => |t| .{ .text = .{
                .text = alloc.dupe(u8, t.text) catch t.text,
                .text_signature = if (t.text_signature) |s| alloc.dupe(u8, s) catch s else null,
            } },
            .image => |img| .{ .image = .{
                .data = alloc.dupe(u8, img.data) catch img.data,
                .mime_type = alloc.dupe(u8, img.mime_type) catch img.mime_type,
            } },
        };
    }
    return duped;
}

fn dupeAssistantMessage(alloc: std.mem.Allocator, msg: ai.protocol.AssistantMessage) ai.protocol.AssistantMessage {
    const content = alloc.alloc(ai.protocol.AssistantMessage.AssistantContentBlock, msg.content.len) catch return msg;
    for (msg.content, 0..) |block, i| {
        content[i] = switch (block) {
            .text => |t| .{ .text = .{
                .text = alloc.dupe(u8, t.text) catch t.text,
                .text_signature = if (t.text_signature) |s| alloc.dupe(u8, s) catch s else null,
            } },
            .thinking => |t| .{ .thinking = .{
                .thinking = alloc.dupe(u8, t.thinking) catch t.thinking,
                .thinking_signature = if (t.thinking_signature) |s| alloc.dupe(u8, s) catch s else null,
                .redacted = t.redacted,
            } },
            .tool_call => |tc| .{ .tool_call = .{
                .id = alloc.dupe(u8, tc.id) catch tc.id,
                .name = alloc.dupe(u8, tc.name) catch tc.name,
                .arguments = cloneJson(alloc, tc.arguments),
                .thought_signature = if (tc.thought_signature) |s| alloc.dupe(u8, s) catch s else null,
            } },
        };
    }
    var result = msg;
    result.content = content;
    result.model = alloc.dupe(u8, msg.model) catch msg.model;
    if (msg.api == .custom) {
        result.api = .{ .custom = alloc.dupe(u8, msg.api.custom) catch msg.api.custom };
    }
    if (msg.provider == .custom) {
        result.provider = .{ .custom = alloc.dupe(u8, msg.provider.custom) catch msg.provider.custom };
    }
    if (msg.error_message) |em| {
        result.error_message = alloc.dupe(u8, em) catch em;
    }
    if (msg.response_id) |rid| {
        result.response_id = alloc.dupe(u8, rid) catch rid;
    }
    return result;
}

fn dupeToolResultMessage(alloc: std.mem.Allocator, msg: ai.protocol.ToolResultMessage) ai.protocol.ToolResultMessage {
    const content = alloc.alloc(ai.protocol.ToolResultMessage.ContentBlock, msg.content.len) catch return msg;
    for (msg.content, 0..) |block, i| {
        content[i] = switch (block) {
            .text => |t| .{ .text = .{
                .text = alloc.dupe(u8, t.text) catch t.text,
                .text_signature = if (t.text_signature) |s| alloc.dupe(u8, s) catch s else null,
            } },
            .image => |img| .{ .image = .{
                .data = alloc.dupe(u8, img.data) catch img.data,
                .mime_type = alloc.dupe(u8, img.mime_type) catch img.mime_type,
            } },
        };
    }
    var result = msg;
    result.content = content;
    result.tool_call_id = alloc.dupe(u8, msg.tool_call_id) catch msg.tool_call_id;
    result.tool_name = alloc.dupe(u8, msg.tool_name) catch msg.tool_name;
    result.details = cloneOptionalJson(alloc, msg.details);
    return result;
}

fn freeAgentMessage(alloc: std.mem.Allocator, msg: *protocol.AgentMessage) void {
    switch (msg.*) {
        .user => |*u| freeUserMessage(alloc, u),
        .assistant => |*a| freeAssistantMessage(alloc, a),
        .tool_result => |*t| freeToolResultMessage(alloc, t),
        .compaction_summary => |*c| alloc.free(c.summary),
        .branch_summary => |*b| {
            alloc.free(b.summary);
            alloc.free(b.from_id);
        },
        .custom => |*c| {
            alloc.free(c.custom_type);
            switch (c.content) {
                .text => |text| alloc.free(text),
                .blocks => |blocks| freeUserBlocks(alloc, blocks),
            }
            if (c.details) |*details| json_util.freeJsonValue(alloc, details.*);
        },
    }
    msg.* = undefined;
}

fn freeUserMessage(alloc: std.mem.Allocator, msg: *ai.protocol.UserMessage) void {
    switch (msg.content) {
        .text => |text| alloc.free(text),
        .blocks => |blocks| freeUserBlocks(alloc, blocks),
    }
}

fn freeUserBlocks(alloc: std.mem.Allocator, blocks: []const ai.protocol.UserMessage.UserMessageContent.Block) void {
    for (blocks) |block| {
        switch (block) {
            .text => |text| {
                alloc.free(text.text);
                if (text.text_signature) |sig| alloc.free(sig);
            },
            .image => |image| {
                alloc.free(image.data);
                alloc.free(image.mime_type);
            },
        }
    }
    alloc.free(blocks);
}

fn freeAssistantMessage(alloc: std.mem.Allocator, msg: *ai.protocol.AssistantMessage) void {
    for (msg.content) |block| {
        switch (block) {
            .text => |text| {
                alloc.free(text.text);
                if (text.text_signature) |sig| alloc.free(sig);
            },
            .thinking => |thinking| {
                alloc.free(thinking.thinking);
                if (thinking.thinking_signature) |sig| alloc.free(sig);
            },
            .tool_call => |tool_call| {
                alloc.free(tool_call.id);
                alloc.free(tool_call.name);
                json_util.freeJsonValue(alloc, tool_call.arguments);
                if (tool_call.thought_signature) |sig| alloc.free(sig);
            },
        }
    }
    alloc.free(msg.content);
    alloc.free(msg.model);
    if (msg.api == .custom) alloc.free(msg.api.custom);
    if (msg.provider == .custom) alloc.free(msg.provider.custom);
    if (msg.error_message) |text| alloc.free(text);
    if (msg.response_id) |id| alloc.free(id);
}

fn freeToolResultMessage(alloc: std.mem.Allocator, msg: *ai.protocol.ToolResultMessage) void {
    for (msg.content) |block| {
        switch (block) {
            .text => |text| {
                alloc.free(text.text);
                if (text.text_signature) |sig| alloc.free(sig);
            },
            .image => |image| {
                alloc.free(image.data);
                alloc.free(image.mime_type);
            },
        }
    }
    alloc.free(msg.content);
    alloc.free(msg.tool_call_id);
    alloc.free(msg.tool_name);
    if (msg.details) |*details| json_util.freeJsonValue(alloc, details.*);
}

fn extractQueuedMessageText(msg: protocol.AgentMessage) ?[]const u8 {
    return switch (msg) {
        .user => |user| switch (user.content) {
            .text => |text| text,
            .blocks => |blocks| blk: {
                var first: ?[]const u8 = null;
                var total_len: usize = 0;
                var text_count: usize = 0;
                for (blocks) |block| {
                    switch (block) {
                        .text => |text_block| {
                            if (first == null) first = text_block.text;
                            total_len += text_block.text.len;
                            text_count += 1;
                        },
                        .image => {},
                    }
                }
                if (text_count == 0) break :blk null;
                if (text_count == 1 and first != null and total_len == first.?.len) break :blk first.?;
                break :blk null;
            },
        },
        else => null,
    };
}

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

fn testAssistantWithToolCall() protocol.AssistantMessage {
    return .{
        .content = &.{
            .{ .text = .{ .text = "working" } },
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

fn testToolResultMessage() protocol.ToolResultMessage {
    return .{
        .tool_call_id = "tool-1",
        .tool_name = "read",
        .content = &.{.{ .text = .{ .text = "done" } }},
        .is_error = false,
        .timestamp = 3,
    };
}

test "tool_execution_start copies ids into runtime scratch" {
    var agent = Agent.init(testing.allocator, .{});
    defer agent.deinit();

    var tool_call_id_buf = [_]u8{ 'a', 'b', 'c' };
    agent.processEvent(.{ .tool_execution_start = .{
        .tool_call_id = tool_call_id_buf[0..],
        .tool_name = "read",
        .args = .{ .object = std.json.ObjectMap.init(testing.allocator) },
    } });

    tool_call_id_buf[0] = 'z';

    try testing.expectEqual(@as(usize, 1), agent.state.pending_tool_calls.len);
    try testing.expectEqualStrings("abc", agent.state.pending_tool_calls[0]);

    agent.processEvent(.{ .tool_execution_end = .{
        .tool_call_id = "abc",
        .tool_name = "read",
        .result = .{ .content = &.{}, .is_error = false },
        .is_error = false,
    } });

    try testing.expectEqual(@as(usize, 0), agent.state.pending_tool_calls.len);
}

test "conversation snapshot keeps current turn in frontier until turn_end" {
    var agent = Agent.init(testing.allocator, .{});
    defer agent.deinit();

    agent.processEvent(.{ .message_end = .{ .message = .{ .user = .{
        .content = .{ .text = "prompt" },
        .timestamp = 1,
    } } } });

    const assistant = testAssistantWithToolCall();
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
    agent.processEvent(.{ .message_end = .{ .message = .{ .tool_result = testToolResultMessage() } } });

    var snapshot = try agent.cloneConversationSnapshot(testing.allocator);
    defer snapshot.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), snapshot.committed.len);
    try testing.expect(snapshot.frontier != null);
    try testing.expect(snapshot.frontier.?.assistant != null);
    try testing.expectEqual(@as(usize, 1), snapshot.frontier.?.live_tools.len);
    try testing.expectEqualStrings("tool-1", snapshot.frontier.?.live_tools[0].tool_call_id);
    try testing.expect(snapshot.frontier.?.live_tools[0].result_message != null);
    try testing.expectEqualStrings("done", snapshot.frontier.?.live_tools[0].result_message.?.content[0].text.text);

    agent.processEvent(.{ .turn_end = .{
        .message = .{ .assistant = assistant },
        .tool_results = &.{testToolResultMessage()},
    } });

    var committed_snapshot = try agent.cloneConversationSnapshot(testing.allocator);
    defer committed_snapshot.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), committed_snapshot.committed.len);
    try testing.expect(committed_snapshot.frontier == null);
}

test "loadMessages accepts state-backed subslices" {
    const initial_messages = [_]protocol.AgentMessage{
        .{ .user = .{
            .content = .{ .text = "hello" },
            .timestamp = 1,
        } },
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
                .cost = .{
                    .input = 0,
                    .output = 0,
                    .cache_read = 0,
                    .cache_write = 0,
                    .total = 0,
                },
            },
            .stop_reason = .@"error",
            .error_message = "retry me",
            .timestamp = 2,
        } },
    };

    var agent = Agent.init(testing.allocator, .{
        .initial_state = .{
            .messages = &initial_messages,
        },
    });
    defer agent.deinit();

    const kept = agent.state.messages[0 .. agent.state.messages.len - 1];
    agent.loadMessages(kept);

    try testing.expectEqual(@as(usize, 1), agent.state.messages.len);
    try testing.expect(agent.state.messages[0] == .user);
    try testing.expectEqualStrings("hello", agent.state.messages[0].user.content.text);
}
