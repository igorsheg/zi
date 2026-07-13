const std = @import("std");
const agent = @import("root.zig");
const ai = @import("../ai/root.zig");
const runtime = @import("../runtime/root.zig");

const Agent = @This();

pub const max_queued_messages = 128;
pub const max_listeners = 32;

allocator: std.mem.Allocator,
io: std.Io,
task_runtime: *runtime.Runtime,
/// Owns transcript-scale data: appended messages, prompt images, pending
/// tool-call ids. Reset by reset()/replaceMessages() — which is also the
/// compaction path, so memory returns when the transcript is rebuilt.
message_arena: std.heap.ArenaAllocator,
/// Owns only the latest streaming partial; reset on every update so memory
/// stays bounded by one partial regardless of stream length.
streaming_arena: std.heap.ArenaAllocator,
/// Owns one mirrored loop event at a time (emitFromLoop); reset per event.
event_scratch_arena: std.heap.ArenaAllocator,
state: agent.AgentState,
messages: std.ArrayList(agent.AgentMessage) = .empty,
tools: std.ArrayList(agent.AgentTool) = .empty,
steering_queue: PendingMessageQueue = .{},
follow_up_queue: PendingMessageQueue = .{},
loop_config: agent.AgentLoopConfig,
listeners: std.ArrayList(?Listener) = .empty,
operations: runtime.OperationIdAllocator = .{},
cancel_source: runtime.CancelSource,
active_run: ?runtime.OperationId = null,
active_run_message_start: usize = 0,

pub const QueueMode = enum {
    all,
    one_at_a_time,
};

pub const Options = struct {
    system_prompt: []const u8 = "",
    model: ai.Model = defaultModel(),
    thinking_level: agent.ThinkingLevel = .off,
    tools: []const agent.AgentTool = &.{},
    messages: []const agent.AgentMessage = &.{},
    steering_mode: QueueMode = .one_at_a_time,
    follow_up_mode: QueueMode = .one_at_a_time,
    stream: ai.StreamFunction = .{ .call_fn = defaultStream },
    stream_options: ai.StreamOptions = .{},
    convert_to_llm: agent.ConvertToLlmHook = .{ .call_fn = defaultConvertToLlm },
    get_api_key: ?agent.GetApiKeyHook = null,
    before_tool_call: ?agent.BeforeToolCallHook = null,
    after_tool_call: ?agent.AfterToolCallHook = null,
    task_runtime: *runtime.Runtime,
};

pub const Listener = struct {
    context: ?*anyopaque = null,
    call_fn: *const fn (std.Io, ?*anyopaque, agent.AgentEvent, runtime.CancelToken) anyerror!void,

    fn call(
        io: std.Io,
        self: Listener,
        event: agent.AgentEvent,
        token: runtime.CancelToken,
    ) anyerror!void {
        return self.call_fn(io, self.context, event, token);
    }
};

pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) !Agent {
    var self: Agent = .{
        .allocator = allocator,
        .io = io,
        .task_runtime = options.task_runtime,
        .cancel_source = try runtime.CancelSource.init(allocator, io),
        .message_arena = std.heap.ArenaAllocator.init(allocator),
        .streaming_arena = std.heap.ArenaAllocator.init(allocator),
        .event_scratch_arena = std.heap.ArenaAllocator.init(allocator),
        .state = .{
            .system_prompt = options.system_prompt,
            .model = options.model,
            .thinking_level = options.thinking_level,
            .tools = &.{},
            .messages = &.{},
        },
        .steering_queue = .{ .mode = options.steering_mode },
        .follow_up_queue = .{ .mode = options.follow_up_mode },
        .loop_config = .{
            .model = options.model,
            .options = .{
                .stream = options.stream_options,
                .reasoning = agent.toAiThinkingLevel(options.thinking_level),
            },
            .stream = options.stream,
            .convert_to_llm = options.convert_to_llm,
            .get_api_key = options.get_api_key,
            .before_tool_call = options.before_tool_call,
            .after_tool_call = options.after_tool_call,
        },
    };
    errdefer self.deinit();

    try self.setTools(options.tools);
    try self.replaceMessages(options.messages);
    return self;
}

pub fn initRuntime(process: runtime.Process, options: Options) !Agent {
    return init(process.gpa, process.io, options);
}

pub fn deinit(self: *Agent) void {
    std.debug.assert(self.active_run == null);
    self.messages.deinit(self.allocator);
    self.tools.deinit(self.allocator);
    self.steering_queue.deinit(self.allocator);
    self.follow_up_queue.deinit(self.allocator);
    self.listeners.deinit(self.allocator);
    self.cancel_source.deinit();
    self.message_arena.deinit();
    self.streaming_arena.deinit();
    self.event_scratch_arena.deinit();
    self.* = undefined;
}

pub fn setSystemPrompt(self: *Agent, system_prompt: []const u8) void {
    self.state.system_prompt = system_prompt;
}

pub fn setModel(self: *Agent, model: ai.Model) void {
    self.state.model = model;
    self.loop_config.model = model;
}

pub fn setStream(self: *Agent, stream: ai.StreamFunction) void {
    self.loop_config.stream = stream;
}

pub fn setThinkingLevel(self: *Agent, thinking_level: agent.ThinkingLevel) void {
    self.state.thinking_level = thinking_level;
    self.loop_config.options.reasoning = agent.toAiThinkingLevel(thinking_level);
}

pub fn streamOptions(self: *const Agent) ai.StreamOptions {
    return self.loop_config.options.stream;
}

pub fn setStreamOptions(self: *Agent, options: ai.StreamOptions) void {
    self.loop_config.options.stream = options;
}

pub fn setTools(self: *Agent, tools: []const agent.AgentTool) !void {
    var next_tools = try std.ArrayList(agent.AgentTool).initCapacity(self.allocator, tools.len);
    errdefer next_tools.deinit(self.allocator);
    next_tools.appendSliceAssumeCapacity(tools);
    self.tools.deinit(self.allocator);
    self.tools = next_tools;
    self.state.tools = self.tools.items;
}

pub fn replaceMessages(self: *Agent, messages: []const agent.AgentMessage) !void {
    self.messages.clearRetainingCapacity();
    self.clearAllQueues();
    _ = self.message_arena.reset(.retain_capacity);
    const arena = self.message_arena.allocator();
    for (messages) |message| {
        try self.messages.append(self.allocator, try agent.copyAgentMessage(arena, message));
    }
    self.state.messages = self.messages.items;
}

pub fn appendMessage(self: *Agent, message: agent.AgentMessage) !void {
    try self.messages.append(self.allocator, try agent.copyAgentMessage(self.message_arena.allocator(), message));
    self.state.messages = self.messages.items;
}

pub fn steer(self: *Agent, message: agent.AgentMessage) error{ QueueFull, OutOfMemory }!void {
    const owned = try agent.copyAgentMessage(self.allocator, message);
    self.steering_queue.enqueue(self.allocator, owned) catch |err| {
        agent.deinitAgentMessage(self.allocator, owned);
        return err;
    };
}

pub fn followUp(self: *Agent, message: agent.AgentMessage) error{ QueueFull, OutOfMemory }!void {
    const owned = try agent.copyAgentMessage(self.allocator, message);
    self.follow_up_queue.enqueue(self.allocator, owned) catch |err| {
        agent.deinitAgentMessage(self.allocator, owned);
        return err;
    };
}

pub fn clearSteeringQueue(self: *Agent) void {
    self.steering_queue.clear(self.allocator);
}

pub fn clearFollowUpQueue(self: *Agent) void {
    self.follow_up_queue.clear(self.allocator);
}

pub fn clearAllQueues(self: *Agent) void {
    self.clearSteeringQueue();
    self.clearFollowUpQueue();
}

pub fn hasQueuedMessages(self: *Agent) bool {
    return self.steering_queue.hasItems() or self.follow_up_queue.hasItems();
}

pub fn abort(self: *Agent) void {
    if (self.active_run != null) self.cancel_source.request();
}

pub fn signal(self: *Agent) ?runtime.CancelToken {
    if (self.active_run == null) return null;
    return self.cancel_source.token();
}

pub fn reset(self: *Agent) void {
    self.messages.clearRetainingCapacity();
    self.clearAllQueues();
    _ = self.message_arena.reset(.retain_capacity);
    self.state.messages = self.messages.items;
    self.state.status = .idle;
    self.cancel_source.resetAfterDrain();
    self.active_run = null;
}

pub fn subscribe(self: *Agent, listener: Listener) error{ TooManyListeners, OutOfMemory }!usize {
    for (self.listeners.items, 0..) |slot, index| {
        if (slot == null) {
            self.listeners.items[index] = listener;
            return index;
        }
    }
    if (self.listeners.items.len == max_listeners) return error.TooManyListeners;
    try self.listeners.append(self.allocator, listener);
    return self.listeners.items.len - 1;
}

pub fn unsubscribe(self: *Agent, handle: usize) void {
    if (handle >= self.listeners.items.len) return;
    self.listeners.items[handle] = null;
}

pub fn beginRun(self: *Agent) error{AlreadyRunning}!runtime.CancelToken {
    if (self.active_run != null) return error.AlreadyRunning;
    self.cancel_source.resetAfterDrain();
    self.active_run = self.operations.reserve();
    self.active_run_message_start = self.state.messages.len;
    self.state.status = .{ .running = .{} };
    return self.cancel_source.token();
}

pub fn finishRun(self: *Agent) void {
    if (self.state.status != .failed) self.state.status = .idle;
    self.cancel_source.resetAfterDrain();
    self.active_run = null;
}

pub fn waitForIdle(self: *const Agent) bool {
    return self.active_run == null;
}

pub fn promptText(self: *Agent, text: []const u8, images: []const ai.ImageContent) !void {
    const message = try self.userMessageFromText(text, images);
    try self.promptMessages(&.{message});
}

pub fn promptMessage(self: *Agent, message: agent.AgentMessage) !void {
    try self.promptMessages(&.{message});
}

pub fn promptMessages(self: *Agent, messages: []const agent.AgentMessage) !void {
    try self.runPromptMessages(messages, false);
}

fn runPromptMessages(self: *Agent, messages: []const agent.AgentMessage, skip_initial_steering: bool) !void {
    const token = try self.beginRun();
    errdefer self.finishRun();
    var config = self.loopConfig();
    var steering_once: SkipInitialSteeringHook = .{ .agent = self, .skip = skip_initial_steering };
    if (skip_initial_steering) {
        config.get_steering_messages = .{ .context = &steering_once, .call_fn = skipInitialSteeringMessages };
    }

    agent.loop.runPrompt(
        self.allocator,
        self.io,
        messages,
        self.contextSnapshot(),
        config,
        token,
        self.task_runtime,
        .{ .context = self, .call_fn = emitFromLoop },
    ) catch |err| {
        try self.recordRunFailure(token, @errorName(err));
        self.finishRun();
        return err;
    };
    self.finishRun();
}

pub fn continueRun(self: *Agent) !void {
    if (self.active_run != null) return error.AlreadyRunning;
    const last = if (self.messages.items.len == 0)
        return error.NoMessages
    else
        self.messages.items[self.messages.items.len - 1];

    if (last == .assistant) {
        if (self.steering_queue.hasItems()) {
            const drained = try self.steering_queue.drain(self.allocator);
            defer self.deinitDrainedMessages(drained);
            try self.runPromptMessages(drained, true);
            return;
        }
        if (self.follow_up_queue.hasItems()) {
            const drained = try self.follow_up_queue.drain(self.allocator);
            defer self.deinitDrainedMessages(drained);
            try self.promptMessages(drained);
            return;
        }
        return error.CannotContinueFromAssistant;
    }

    const token = try self.beginRun();
    errdefer self.finishRun();
    agent.loop.runContinue(
        self.allocator,
        self.io,
        self.contextSnapshot(),
        self.loopConfig(),
        token,
        self.task_runtime,
        .{ .context = self, .call_fn = emitFromLoop },
    ) catch |err| {
        try self.recordRunFailure(token, @errorName(err));
        self.finishRun();
        return err;
    };
    self.finishRun();
}

pub fn emitEvent(self: *Agent, event: agent.AgentEvent) !void {
    const token = self.signal() orelse return error.NoActiveRun;
    for (self.listeners.items) |maybe_listener| {
        const listener = maybe_listener orelse continue;
        try Listener.call(self.io, listener, event, token);
    }
    try self.applyEvent(event);
    if (event == .agent_end and self.state.status != .failed) {
        self.state.status = .{ .settling = .{ .messages = self.state.messages } };
    }
}

pub fn applyEvent(self: *Agent, event: agent.AgentEvent) !void {
    switch (event) {
        .agent_start, .turn_start => {},
        .message_start => |message_event| try self.setStreamingMessage(message_event.message),
        .message_update => |message_update| try self.setStreamingMessage(message_update.message),
        .message_end => |message_event| {
            self.clearStreamingMessage();
            try self.appendMessage(message_event.message);
            if (message_event.message == .assistant and message_event.message.assistant.stop_reason == .error_) {
                if (message_event.message.assistant.error_message) |message| self.state.status = .{ .failed = message };
            }
        },
        .tool_execution_start => |tool_event| try self.addPendingToolCall(tool_event.tool_call_id),
        .tool_execution_update => {},
        .tool_execution_end => |tool_event| switch (self.state.status) {
            .running => |*running| running.pending_tool_calls.remove(tool_event.tool_call_id),
            else => {},
        },
        .turn_end => {},
        .agent_end => self.clearStreamingMessage(),
    }
}

pub fn failRun(self: *Agent, token: runtime.CancelToken, message: []const u8) !void {
    try self.recordRunFailure(token, message);
}

fn recordRunFailure(self: *Agent, token: runtime.CancelToken, message: []const u8) !void {
    const stop_reason: ai.StopReason = if (token.isRequested()) .aborted else .error_;
    const assistant = terminalAssistantMessage(self.state.model, stop_reason, message);
    const terminal_message: agent.AgentMessage = .{ .assistant = assistant };
    try self.emitEvent(.{ .message_start = .{ .message = terminal_message } });
    try self.emitEvent(.{ .message_end = .{ .message = terminal_message } });
    const stored = self.state.messages[self.state.messages.len - 1];
    try self.emitEvent(.{ .turn_end = .{ .message = stored, .tool_results = &.{} } });
    try self.emitEvent(.{ .agent_end = .{ .messages = self.state.messages[self.active_run_message_start..] } });
}

fn terminalAssistantMessage(model: ai.Model, reason: ai.StopReason, error_message: ?[]const u8) ai.AssistantMessage {
    return .{
        .content = &.{},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = ai.protocol.emptyUsage(),
        .stop_reason = reason,
        .error_message = error_message,
        .timestamp = 0,
    };
}

/// The run config with the steering and follow-up queues bound to this
/// agent. `loop_config` itself never holds the binding: Agent.init returns
/// by value, so a self pointer captured there would dangle. Anyone starting
/// a loop run for this agent (its own prompt methods, the coding-agent
/// session) must take the config from here.
pub fn loopConfig(self: *Agent) agent.AgentLoopConfig {
    var config = self.loop_config;
    config.get_steering_messages = .{ .context = self, .call_fn = drainSteeringMessages };
    config.get_follow_up_messages = .{ .context = self, .call_fn = drainFollowUpMessages };
    return config;
}

fn deinitDrainedMessages(self: *Agent, drained: []const agent.AgentMessage) void {
    for (drained) |message| agent.deinitAgentMessage(self.allocator, message);
    self.allocator.free(drained);
}

fn drainSteeringMessages(
    allocator: std.mem.Allocator,
    context: ?*anyopaque,
) std.mem.Allocator.Error![]const agent.AgentMessage {
    const self: *Agent = @ptrCast(@alignCast(context.?));
    return self.steering_queue.drain(allocator);
}

fn drainFollowUpMessages(
    allocator: std.mem.Allocator,
    context: ?*anyopaque,
) std.mem.Allocator.Error![]const agent.AgentMessage {
    const self: *Agent = @ptrCast(@alignCast(context.?));
    return self.follow_up_queue.drain(allocator);
}

const SkipInitialSteeringHook = struct {
    agent: *Agent,
    skip: bool,
};

fn skipInitialSteeringMessages(
    allocator: std.mem.Allocator,
    context: ?*anyopaque,
) std.mem.Allocator.Error![]const agent.AgentMessage {
    const hook: *SkipInitialSteeringHook = @ptrCast(@alignCast(context.?));
    if (hook.skip) {
        hook.skip = false;
        return allocator.alloc(agent.AgentMessage, 0);
    }
    return hook.agent.steering_queue.drain(allocator);
}

fn contextSnapshot(self: *const Agent) agent.AgentContext {
    return .{
        .system_prompt = self.state.system_prompt,
        .messages = self.state.messages,
        .tools = self.state.tools,
    };
}

fn emitFromLoop(context: ?*anyopaque, event: agent.AgentEvent) anyerror!void {
    const self: *Agent = @ptrCast(@alignCast(context.?));
    // The copy lives only for this call: listeners and applyEvent must not
    // retain it (applyEvent re-copies what it keeps into the durable or
    // streaming arena). Resetting here drops the previous event's copy.
    _ = self.event_scratch_arena.reset(.retain_capacity);
    try self.emitEvent(try agent.loop.copyStreamEvent(self.event_scratch_arena.allocator(), event));
}

pub fn userMessageFromText(self: *Agent, text: []const u8, images: []const ai.ImageContent) !agent.AgentMessage {
    if (images.len == 0) {
        return .{ .user = .{
            .content = .{ .string = try self.message_arena.allocator().dupe(u8, text) },
            .timestamp = 0,
        } };
    }

    const content = try self.message_arena.allocator().alloc(ai.UserContent, images.len + 1);
    content[0] = .{ .text = .{ .text = try self.message_arena.allocator().dupe(u8, text) } };
    for (images, 0..) |image, index| {
        content[index + 1] = .{ .image = .{
            .data = try self.message_arena.allocator().dupe(u8, image.data),
            .mime_type = try self.message_arena.allocator().dupe(u8, image.mime_type),
        } };
    }
    return .{ .user = .{ .content = .{ .blocks = content }, .timestamp = 0 } };
}

fn setStreamingMessage(self: *Agent, message: agent.AgentMessage) !void {
    // Only the latest partial is retained; the arena reset drops the
    // previous one so a long stream holds at most one partial's memory.
    _ = self.streaming_arena.reset(.retain_capacity);
    const owned = try agent.copyAgentMessage(self.streaming_arena.allocator(), message);
    switch (self.state.status) {
        .running => |*running| running.streaming_message = owned,
        .idle => self.state.status = .{ .running = .{ .streaming_message = owned } },
        .settling, .failed => std.debug.assert(false),
    }
}

fn clearStreamingMessage(self: *Agent) void {
    switch (self.state.status) {
        .running => |*running| running.streaming_message = null,
        else => {},
    }
}

fn addPendingToolCall(self: *Agent, id: []const u8) error{ TooManyToolCalls, OutOfMemory }!void {
    switch (self.state.status) {
        .running => |*running| {
            const owned_id = try self.message_arena.allocator().dupe(u8, id);
            running.pending_tool_calls.append(owned_id) catch return error.TooManyToolCalls;
        },
        .idle => {
            const owned_id = try self.message_arena.allocator().dupe(u8, id);
            self.state.status = .{ .running = .{} };
            self.state.status.running.pending_tool_calls.append(owned_id) catch return error.TooManyToolCalls;
        },
        .settling, .failed => std.debug.assert(false),
    }
}

/// Queue of messages waiting to enter a run. Enqueue happens on the owner
/// task while the loop producer task drains between turns, so every access
/// holds the mutex. Message contents are owned by the queue's allocator
/// (not an arena): drain transfers that ownership to the caller, who must
/// deinit each message and free the slice.
pub const PendingMessageQueue = struct {
    mode: QueueMode = .one_at_a_time,
    mutex: runtime.Mutex = .init,
    messages: std.ArrayList(agent.AgentMessage) = .empty,

    pub fn deinit(self: *PendingMessageQueue, allocator: std.mem.Allocator) void {
        for (self.messages.items) |message| agent.deinitAgentMessage(allocator, message);
        self.messages.deinit(allocator);
        self.* = undefined;
    }

    /// Takes ownership of `message` (contents allocated from `allocator`)
    /// on success; the caller keeps ownership on failure.
    pub fn enqueue(
        self: *PendingMessageQueue,
        allocator: std.mem.Allocator,
        message: agent.AgentMessage,
    ) error{ QueueFull, OutOfMemory }!void {
        self.mutex.lockUncancelable();
        defer self.mutex.unlock();
        if (self.messages.items.len == max_queued_messages) return error.QueueFull;
        try self.messages.append(allocator, message);
    }

    pub fn hasItems(self: *PendingMessageQueue) bool {
        self.mutex.lockUncancelable();
        defer self.mutex.unlock();
        return self.messages.items.len > 0;
    }

    pub fn count(self: *PendingMessageQueue) usize {
        self.mutex.lockUncancelable();
        defer self.mutex.unlock();
        return self.messages.items.len;
    }

    pub fn hasCapacity(self: *PendingMessageQueue) bool {
        self.mutex.lockUncancelable();
        defer self.mutex.unlock();
        return self.messages.items.len < max_queued_messages;
    }

    pub fn clear(self: *PendingMessageQueue, allocator: std.mem.Allocator) void {
        self.mutex.lockUncancelable();
        defer self.mutex.unlock();
        for (self.messages.items) |message| agent.deinitAgentMessage(allocator, message);
        self.messages.clearRetainingCapacity();
    }

    /// The caller owns the returned messages and the slice.
    pub fn drain(
        self: *PendingMessageQueue,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error![]const agent.AgentMessage {
        self.mutex.lockUncancelable();
        defer self.mutex.unlock();
        if (self.messages.items.len == 0) return &.{};

        const drain_count: usize = switch (self.mode) {
            .all => self.messages.items.len,
            .one_at_a_time => 1,
        };
        const drained = try allocator.dupe(agent.AgentMessage, self.messages.items[0..drain_count]);
        const remaining = self.messages.items.len - drain_count;
        @memmove(self.messages.items[0..remaining], self.messages.items[drain_count..]);
        self.messages.shrinkRetainingCapacity(self.messages.items.len - drain_count);
        return drained;
    }
};

const llm_tool_result_text_bytes_max: usize = 8 * 1024;
const llm_tool_result_truncated_note = "\n[tool result truncated for model context]\n";

fn defaultConvertToLlm(
    allocator: std.mem.Allocator,
    _: ?*anyopaque,
    messages: []const agent.AgentMessage,
) std.mem.Allocator.Error![]const ai.Message {
    var out = std.ArrayList(ai.Message).empty;
    for (messages) |message| {
        switch (message) {
            .user => |user| try out.append(allocator, .{ .user = user }),
            .assistant => |assistant| try out.append(allocator, .{ .assistant = assistant }),
            .tool_result => |tool_result| try out.append(allocator, .{
                .tool_result = try compactToolResultForLlm(allocator, tool_result),
            }),
            .custom => {},
        }
    }
    return out.toOwnedSlice(allocator);
}

fn compactToolResultForLlm(
    allocator: std.mem.Allocator,
    source: ai.ToolResultMessage,
) std.mem.Allocator.Error!ai.ToolResultMessage {
    const tool_call_id = try allocator.dupe(u8, source.tool_call_id);
    errdefer allocator.free(tool_call_id);
    const tool_name = try allocator.dupe(u8, source.tool_name);
    errdefer allocator.free(tool_name);
    const content = try allocator.alloc(ai.ToolResultContent, source.content.len);
    errdefer allocator.free(content);
    var initialized: usize = 0;
    errdefer for (content[0..initialized]) |item| agent.deinitToolResultContent(allocator, item);
    for (source.content, content) |item, *out| {
        out.* = switch (item) {
            .text => |text| .{ .text = .{ .text = try compactToolResultTextForLlm(allocator, text.text) } },
            .image => .{ .text = .{ .text = try allocator.dupe(u8, "[tool image omitted from model context]") } },
        };
        initialized += 1;
    }
    return .{
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .content = content,
        .details = null,
        .is_error = source.is_error,
        .timestamp = source.timestamp,
    };
}

fn compactToolResultTextForLlm(allocator: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]const u8 {
    if (text.len <= llm_tool_result_text_bytes_max) return allocator.dupe(u8, text);
    const content_budget = llm_tool_result_text_bytes_max - llm_tool_result_truncated_note.len;
    const head_budget = content_budget / 2;
    const tail_budget = content_budget - head_budget;
    const head = agent.utf8Prefix(text, head_budget);
    const tail = utf8Suffix(text, tail_budget);
    const out = try allocator.alloc(u8, head.len + llm_tool_result_truncated_note.len + tail.len);
    @memcpy(out[0..head.len], head);
    @memcpy(out[head.len..][0..llm_tool_result_truncated_note.len], llm_tool_result_truncated_note);
    @memcpy(out[head.len + llm_tool_result_truncated_note.len ..], tail);
    return out;
}

fn utf8Suffix(text: []const u8, max_bytes: usize) []const u8 {
    if (text.len <= max_bytes) return text;
    var start = text.len - max_bytes;
    while (start < text.len and !std.unicode.utf8ValidateSlice(text[start..])) start += 1;
    return text[start..];
}

test "default llm conversion bounds tool result text" {
    const large = "x" ** (llm_tool_result_text_bytes_max + 100);
    const content = [_]ai.ToolResultContent{.{ .text = .{ .text = large } }};
    const source = [_]agent.AgentMessage{.{ .tool_result = .{
        .tool_call_id = "call-1",
        .tool_name = "custom",
        .content = &content,
        .is_error = false,
        .timestamp = 0,
    } }};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const converted = try defaultConvertToLlm(arena.allocator(), null, &source);

    try std.testing.expectEqual(@as(usize, 1), converted.len);
    try std.testing.expect(converted[0] == .tool_result);
    const text = converted[0].tool_result.content[0].text.text;
    try std.testing.expect(text.len <= llm_tool_result_text_bytes_max);
    try std.testing.expect(std.mem.indexOf(u8, text, llm_tool_result_truncated_note) != null);
    try std.testing.expect(converted[0].tool_result.details == null);
}

test "default llm conversion preserves tail hints in large tool result text" {
    var source_text_writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer source_text_writer.deinit();
    try source_text_writer.writer.splatByteAll('x', llm_tool_result_text_bytes_max + 100);
    try source_text_writer.writer.writeAll("\nFull output: /tmp/zi-bash-test.log");
    const content = [_]ai.ToolResultContent{.{ .text = .{ .text = source_text_writer.written() } }};
    const source = [_]agent.AgentMessage{.{ .tool_result = .{
        .tool_call_id = "call-1",
        .tool_name = "bash",
        .content = &content,
        .is_error = false,
        .timestamp = 0,
    } }};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const converted = try defaultConvertToLlm(arena.allocator(), null, &source);

    const text = converted[0].tool_result.content[0].text.text;
    try std.testing.expect(text.len <= llm_tool_result_text_bytes_max);
    try std.testing.expect(std.mem.indexOf(u8, text, llm_tool_result_truncated_note) != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "Full output: /tmp/zi-bash-test.log"));
}

fn defaultStream(_: ?*anyopaque, request: ai.StreamRequest) ai.AssistantMessageEventStream {
    var stream = ai.AssistantMessageEventStream.initBuffered();
    const sink = stream.sink();
    sink.endDone(request.io, .stop, .{
        .content = &.{},
        .api = request.model.api,
        .provider = request.model.provider,
        .model = request.model.id,
        .usage = ai.protocol.emptyUsage(),
        .stop_reason = .stop,
        .timestamp = 0,
    }) catch std.debug.assert(false);
    return stream;
}

pub fn defaultModel() ai.Model {
    return .{
        .id = "unknown",
        .name = "unknown",
        .api = "unknown",
        .provider = "unknown",
        .base_url = "",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 0,
        .max_tokens = 0,
    };
}

fn userMessage(text: []const u8) agent.AgentMessage {
    return .{ .user = .{ .content = .{ .string = text }, .timestamp = 0 } };
}

fn assistantMessage(text: []const u8) agent.AgentMessage {
    return .{ .assistant = .{
        .content = &.{.{ .text = .{ .text = text } }},
        .api = ai.KnownApi.openai_responses,
        .provider = ai.KnownProvider.openai,
        .model = "test-model",
        .usage = ai.protocol.emptyUsage(),
        .stop_reason = .stop,
        .timestamp = 0,
    } };
}

const ListenerProbe = struct {
    calls: usize = 0,
    saw_cancel_requested: bool = false,
};

const TestAgent = struct {
    task_runtime: *runtime.Runtime,
    agent: Agent,

    fn init(options: anytype) !TestAgent {
        const task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
        errdefer task_runtime.deinit();
        var resolved_options: Options = .{ .task_runtime = task_runtime };
        inline for (@typeInfo(@TypeOf(options)).@"struct".fields) |field| {
            @field(resolved_options, field.name) = @field(options, field.name);
        }
        return .{
            .task_runtime = task_runtime,
            .agent = try Agent.init(std.testing.allocator, task_runtime.io(), resolved_options),
        };
    }

    fn deinit(self: *TestAgent) void {
        self.agent.deinit();
        self.task_runtime.deinit();
        self.* = undefined;
    }
};

fn countListener(_: std.Io, context: ?*anyopaque, _: agent.AgentEvent, token: runtime.CancelToken) anyerror!void {
    const probe: *ListenerProbe = @ptrCast(@alignCast(context.?));
    probe.calls += 1;
    probe.saw_cancel_requested = token.isRequested();
}

test "agent creates default state" {
    var fixture = try TestAgent.init(.{});
    defer fixture.deinit();
    const self = &fixture.agent;

    try std.testing.expectEqualStrings("", self.state.system_prompt);
    try std.testing.expectEqual(agent.ThinkingLevel.off, self.state.thinking_level);
    try std.testing.expectEqual(@as(usize, 0), self.state.tools.len);
    try std.testing.expectEqual(@as(usize, 0), self.state.messages.len);
    try std.testing.expect(!self.state.isStreaming());
    try std.testing.expect(self.state.streamingMessage() == null);
    try std.testing.expectEqual(@as(usize, 0), self.state.pendingToolCalls().len);
    try std.testing.expect(self.state.errorMessage() == null);
}

test "agent owns copied initial message strings" {
    var text = [_]u8{ 'h', 'e', 'l', 'l', 'o' };
    const message = userMessage(&text);
    var messages = [_]agent.AgentMessage{message};
    var fixture = try TestAgent.init(.{ .messages = &messages });
    defer fixture.deinit();
    const self = &fixture.agent;

    messages[0] = userMessage("changed");
    text[0] = 'j';

    try std.testing.expectEqual(@as(usize, 1), self.state.messages.len);
    try std.testing.expectEqualStrings("hello", self.state.messages[0].user.content.string);
}

test "state mutators do not use event path" {
    var fixture = try TestAgent.init(.{});
    defer fixture.deinit();
    const self = &fixture.agent;

    self.setSystemPrompt("custom");
    self.setThinkingLevel(.high);

    try std.testing.expectEqualStrings("custom", self.state.system_prompt);
    try std.testing.expectEqual(agent.ThinkingLevel.high, self.state.thinking_level);
}

test "steering and follow-up queues do not mutate transcript" {
    var fixture = try TestAgent.init(.{});
    defer fixture.deinit();
    const self = &fixture.agent;

    try self.steer(userMessage("steer"));
    try self.followUp(userMessage("follow"));

    try std.testing.expect(self.hasQueuedMessages());
    try std.testing.expectEqual(@as(usize, 0), self.state.messages.len);
}

test "pending message queue drains one at a time by default" {
    var queue: PendingMessageQueue = .{};
    defer queue.deinit(std.testing.allocator);

    try queue.enqueue(std.testing.allocator, try agent.copyAgentMessage(std.testing.allocator, userMessage("one")));
    try queue.enqueue(std.testing.allocator, try agent.copyAgentMessage(std.testing.allocator, userMessage("two")));

    const drained = try queue.drain(std.testing.allocator);
    defer {
        for (drained) |message| agent.deinitAgentMessage(std.testing.allocator, message);
        std.testing.allocator.free(drained);
    }

    try std.testing.expectEqual(@as(usize, 1), drained.len);
    try std.testing.expectEqualStrings("one", drained[0].user.content.string);
    try std.testing.expect(queue.hasItems());
}

test "pending message queue has explicit maximum" {
    var queue: PendingMessageQueue = .{};
    defer queue.deinit(std.testing.allocator);

    for (0..max_queued_messages) |_| {
        try queue.enqueue(
            std.testing.allocator,
            try agent.copyAgentMessage(std.testing.allocator, userMessage("message")),
        );
    }

    const overflow = try agent.copyAgentMessage(std.testing.allocator, userMessage("overflow"));
    defer agent.deinitAgentMessage(std.testing.allocator, overflow);
    try std.testing.expectError(error.QueueFull, queue.enqueue(std.testing.allocator, overflow));
}

test "abort without active run is a no-op" {
    var fixture = try TestAgent.init(.{});
    defer fixture.deinit();
    const self = &fixture.agent;

    self.abort();

    try std.testing.expect(self.signal() == null);
}

test "reset clears transcript runtime state and queues" {
    var fixture = try TestAgent.init(.{});
    defer fixture.deinit();
    const self = &fixture.agent;

    try self.appendMessage(userMessage("hello"));
    try self.steer(userMessage("steer"));
    self.state.status = .{ .failed = "boom" };

    self.reset();

    try std.testing.expectEqual(@as(usize, 0), self.state.messages.len);
    try std.testing.expect(!self.hasQueuedMessages());
    try std.testing.expect(self.state.errorMessage() == null);
}

test "begin run rejects concurrent run and exposes cancel token" {
    var fixture = try TestAgent.init(.{});
    defer fixture.deinit();
    const self = &fixture.agent;

    const token = try self.beginRun();
    try std.testing.expect(self.state.isStreaming());
    try std.testing.expect(!token.isRequested());
    try std.testing.expectError(error.AlreadyRunning, self.beginRun());

    self.abort();
    try std.testing.expect(token.isRequested());
    self.finishRun();
    try std.testing.expect(self.waitForIdle());
}

test "emit event reduces state before notifying listeners" {
    var fixture = try TestAgent.init(.{});
    defer fixture.deinit();
    const self = &fixture.agent;
    var probe: ListenerProbe = .{};
    _ = try self.subscribe(.{ .context = &probe, .call_fn = countListener });
    _ = try self.beginRun();
    defer self.finishRun();

    const message = userMessage("hello");
    try self.emitEvent(.{ .message_start = .{ .message = message } });
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expect(self.state.streamingMessage() != null);

    try self.emitEvent(.{ .message_end = .{ .message = message } });
    try std.testing.expectEqual(@as(usize, 2), probe.calls);
    try std.testing.expectEqual(@as(usize, 1), self.state.messages.len);
    try std.testing.expect(self.state.streamingMessage() == null);
}

test "fail run emits terminal assistant error before agent end" {
    var fixture = try TestAgent.init(.{});
    defer fixture.deinit();
    const self = &fixture.agent;
    var probe: ListenerProbe = .{};
    _ = try self.subscribe(.{ .context = &probe, .call_fn = countListener });

    const token = try self.beginRun();
    try self.failRun(token, "OutOfMemory");
    self.finishRun();

    try std.testing.expectEqual(@as(usize, 4), probe.calls);
    try std.testing.expectEqual(@as(usize, 1), self.state.messages.len);
    try std.testing.expectEqualStrings("OutOfMemory", self.state.messages[0].assistant.error_message.?);
    try std.testing.expectEqualStrings("OutOfMemory", self.state.errorMessage().?);
}

test "agent end enters settling until finish run" {
    var fixture = try TestAgent.init(.{});
    defer fixture.deinit();
    const self = &fixture.agent;
    _ = try self.beginRun();

    try self.emitEvent(.{ .agent_end = .{ .messages = &.{} } });

    try std.testing.expect(self.state.isStreaming());
    try std.testing.expect(!self.waitForIdle());
    self.finishRun();
    try std.testing.expect(!self.state.isStreaming());
}

test "tool execution events track pending tool calls" {
    var fixture = try TestAgent.init(.{});
    defer fixture.deinit();
    const self = &fixture.agent;
    _ = try self.beginRun();
    defer self.finishRun();

    try self.emitEvent(.{ .tool_execution_start = .{
        .tool_call_id = "tool-1",
        .tool_name = "echo",
        .args = .{ .object = .{} },
    } });
    try std.testing.expectEqual(@as(usize, 1), self.state.pendingToolCalls().len);

    try self.emitEvent(.{ .tool_execution_end = .{
        .tool_call_id = "tool-1",
        .tool_name = "echo",
        .result = .{ .content = &.{} },
        .is_error = false,
    } });
    try std.testing.expectEqual(@as(usize, 0), self.state.pendingToolCalls().len);
}

test "message end records assistant error message" {
    var fixture = try TestAgent.init(.{});
    defer fixture.deinit();
    const self = &fixture.agent;
    _ = try self.beginRun();
    defer self.finishRun();
    var message = assistantMessage("");
    message.assistant.error_message = "failed";
    message.assistant.stop_reason = .error_;

    try self.emitEvent(.{ .message_end = .{ .message = message } });

    try std.testing.expectEqualStrings("failed", self.state.errorMessage().?);
}

test "prompt text emits lifecycle and appends user message" {
    var fixture = try TestAgent.init(.{});
    defer fixture.deinit();
    const self = &fixture.agent;
    var probe: ListenerProbe = .{};
    _ = try self.subscribe(.{ .context = &probe, .call_fn = countListener });

    try self.promptText("hello", &.{});

    try std.testing.expect(self.waitForIdle());
    try std.testing.expectEqual(@as(usize, 2), self.state.messages.len);
    try std.testing.expectEqualStrings("hello", self.state.messages[0].user.content.string);
    try std.testing.expect(self.state.messages[1] == .assistant);
    try std.testing.expectEqual(@as(usize, 8), probe.calls);
}

test "prompt rejects while active run exists" {
    var fixture = try TestAgent.init(.{});
    defer fixture.deinit();
    const self = &fixture.agent;
    _ = try self.beginRun();
    defer self.finishRun();

    try std.testing.expectError(error.AlreadyRunning, self.promptText("blocked", &.{}));
}

test "continue rejects empty transcript" {
    var fixture = try TestAgent.init(.{});
    defer fixture.deinit();
    const self = &fixture.agent;

    try std.testing.expectError(error.NoMessages, self.continueRun());
}

test "queued steering message is drained into a live run" {
    var fixture = try TestAgent.init(.{});
    defer fixture.deinit();
    const self = &fixture.agent;

    // Queued before the run starts: the loop's initial steering drain must
    // pick it up mid-run, without waiting for the run to settle.
    try self.steer(userMessage("mid-run steer"));
    try self.promptText("hello", &.{});

    try std.testing.expect(!self.hasQueuedMessages());
    try std.testing.expectEqual(@as(usize, 3), self.state.messages.len);
    try std.testing.expectEqualStrings("hello", self.state.messages[0].user.content.string);
    try std.testing.expectEqualStrings("mid-run steer", self.state.messages[1].user.content.string);
    try std.testing.expect(self.state.messages[2] == .assistant);
}

test "continue from assistant drains one steering batch" {
    var fixture = try TestAgent.init(.{});
    defer fixture.deinit();
    const self = &fixture.agent;
    try self.appendMessage(assistantMessage("done"));
    try self.steer(userMessage("one"));
    try self.steer(userMessage("two"));

    try self.continueRun();

    try std.testing.expectEqual(@as(usize, 5), self.state.messages.len);
    try std.testing.expectEqualStrings("one", self.state.messages[1].user.content.string);
    try std.testing.expect(self.state.messages[2] == .assistant);
    try std.testing.expectEqualStrings("two", self.state.messages[3].user.content.string);
    try std.testing.expect(self.state.messages[4] == .assistant);
}

test "continue from assistant drains follow up when steering empty" {
    var fixture = try TestAgent.init(.{});
    defer fixture.deinit();
    const self = &fixture.agent;
    try self.appendMessage(assistantMessage("done"));
    try self.followUp(userMessage("next"));

    try self.continueRun();

    try std.testing.expectEqual(@as(usize, 3), self.state.messages.len);
    try std.testing.expectEqualStrings("next", self.state.messages[1].user.content.string);
    try std.testing.expect(self.state.messages[2] == .assistant);
}

const large_tool_output_text = "x" ** (llm_tool_result_text_bytes_max + 4096);

const LargeToolOutputProbe = struct {
    calls: usize = 0,
    saw_bounded_tool_result: bool = false,
    saw_raw_large_tool_result: bool = false,
};

fn compactedToolResultProbeStream(context: ?*anyopaque, request: ai.StreamRequest) ai.AssistantMessageEventStream {
    const probe: *LargeToolOutputProbe = @ptrCast(@alignCast(context.?));
    const call_index = probe.calls;
    probe.calls += 1;

    var stream = ai.AssistantMessageEventStream.initBuffered();
    const sink = stream.sink();
    if (call_index == 0) {
        sink.endDone(request.io, .tool_use, largeToolCallAssistantMessage(request.model)) catch std.debug.assert(false);
        return stream;
    }

    for (request.context.messages) |message| {
        if (message != .tool_result) continue;
        const text = message.tool_result.content[0].text.text;
        if (text.len > llm_tool_result_text_bytes_max) probe.saw_raw_large_tool_result = true;
        if (text.len <= llm_tool_result_text_bytes_max and
            std.mem.indexOf(u8, text, llm_tool_result_truncated_note) != null)
        {
            probe.saw_bounded_tool_result = true;
        }
    }

    sink.endDone(request.io, .stop, emptyAssistantResponse(request.model)) catch std.debug.assert(false);
    return stream;
}

fn largeToolCallAssistantMessage(model: ai.Model) ai.AssistantMessage {
    return .{
        .content = &.{.{ .tool_call = .{
            .id = "large-1",
            .name = "large_output",
            .arguments = .{ .object = .empty },
        } }},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = ai.protocol.emptyUsage(),
        .stop_reason = .tool_use,
        .timestamp = 0,
    };
}

fn emptyAssistantResponse(model: ai.Model) ai.AssistantMessage {
    return .{
        .content = &.{},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = ai.protocol.emptyUsage(),
        .stop_reason = .stop,
        .timestamp = 0,
    };
}

fn largeOutputTool(
    allocator: std.mem.Allocator,
    _: std.Io,
    _: *runtime.Runtime,
    _: ?*anyopaque,
    _: runtime.CancelToken,
    _: []const u8,
    _: std.json.Value,
    _: ?agent.AgentToolUpdateCallback,
) anyerror!agent.ToolExecutionResult {
    const content = try allocator.alloc(ai.ToolResultContent, 1);
    errdefer allocator.free(content);
    content[0] = .{ .text = .{ .text = try allocator.dupe(u8, large_tool_output_text) } };
    return .{ .allocator = allocator, .result = .{ .content = content } };
}

test "agent compacts large tool results before next model request" {
    var probe: LargeToolOutputProbe = .{};
    const tool: agent.AgentTool = .{
        .name = "large_output",
        .description = "Emit large output",
        .parameters = .{ .object = .empty },
        .label = "Large output",
        .execute = .{ .call_fn = largeOutputTool },
        .execution_mode = .sequential,
    };
    var fixture = try TestAgent.init(.{
        .tools = &.{tool},
        .stream = ai.StreamFunction{ .context = &probe, .call_fn = compactedToolResultProbeStream },
    });
    defer fixture.deinit();

    try fixture.agent.promptText("hello", &.{});

    try std.testing.expectEqual(@as(usize, 2), probe.calls);
    try std.testing.expect(probe.saw_bounded_tool_result);
    try std.testing.expect(!probe.saw_raw_large_tool_result);
}
