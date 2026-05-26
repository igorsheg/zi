const std = @import("std");
const agent = @import("root.zig");
const ai = @import("../ai/root.zig");
const runtime = @import("../runtime/root.zig");

const Agent = @This();

pub const max_queued_messages = 128;
pub const max_listeners = 32;

allocator: std.mem.Allocator,
io: std.Io,
message_arena: std.heap.ArenaAllocator,
state: agent.AgentState,
messages: std.ArrayList(agent.AgentMessage) = .empty,
tools: std.ArrayList(agent.AgentTool) = .empty,
steering_queue: PendingMessageQueue = .{},
follow_up_queue: PendingMessageQueue = .{},
loop_config: agent.AgentLoopConfig,
listeners: std.ArrayList(?Listener) = .empty,
operations: runtime.OperationTable = .{},
cancel_source: runtime.CancelSource = .{},
active_run: ?runtime.OperationId = null,

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
    convert_to_llm: agent.ConvertToLlmHook = .{ .call_fn = defaultConvertToLlm },
    transform_context: ?agent.TransformContextHook = null,
    get_api_key: ?agent.GetApiKeyHook = null,
    before_tool_call: ?agent.BeforeToolCallHook = null,
    after_tool_call: ?agent.AfterToolCallHook = null,
};

pub const Error = error{
    AlreadyRunning,
    QueueFull,
    TooManyListeners,
    TooManyToolCalls,
    NoActiveRun,
    NoMessages,
    CannotContinueFromAssistant,
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
        .message_arena = std.heap.ArenaAllocator.init(allocator),
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
            .options = .{ .reasoning = agent.toAiThinkingLevel(options.thinking_level) },
            .stream = options.stream,
            .convert_to_llm = options.convert_to_llm,
            .transform_context = options.transform_context,
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
    self.message_arena.deinit();
    self.* = undefined;
}

pub fn setSystemPrompt(self: *Agent, system_prompt: []const u8) void {
    self.state.system_prompt = system_prompt;
}

pub fn setModel(self: *Agent, model: ai.Model) void {
    self.state.model = model;
    self.loop_config.model = model;
}

pub fn setThinkingLevel(self: *Agent, thinking_level: agent.ThinkingLevel) void {
    self.state.thinking_level = thinking_level;
    self.loop_config.options.reasoning = agent.toAiThinkingLevel(thinking_level);
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
        try self.messages.append(self.allocator, try cloneAgentMessage(arena, message));
    }
    self.state.messages = self.messages.items;
}

pub fn appendMessage(self: *Agent, message: agent.AgentMessage) !void {
    try self.messages.append(self.allocator, try cloneAgentMessage(self.message_arena.allocator(), message));
    self.state.messages = self.messages.items;
}

pub fn steer(self: *Agent, message: agent.AgentMessage) Error!void {
    const owned = cloneAgentMessage(self.message_arena.allocator(), message) catch return error.QueueFull;
    self.steering_queue.enqueue(self.allocator, owned) catch return error.QueueFull;
}

pub fn followUp(self: *Agent, message: agent.AgentMessage) Error!void {
    const owned = cloneAgentMessage(self.message_arena.allocator(), message) catch return error.QueueFull;
    self.follow_up_queue.enqueue(self.allocator, owned) catch return error.QueueFull;
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
    self.cancel_source.reset();
    self.active_run = null;
}

pub fn subscribe(self: *Agent, listener: Listener) Error!usize {
    for (self.listeners.items, 0..) |slot, index| {
        if (slot == null) {
            self.listeners.items[index] = listener;
            return index;
        }
    }
    if (self.listeners.items.len == max_listeners) return error.TooManyListeners;
    self.listeners.append(self.allocator, listener) catch return error.QueueFull;
    return self.listeners.items.len - 1;
}

pub fn unsubscribe(self: *Agent, handle: usize) void {
    if (handle >= self.listeners.items.len) return;
    self.listeners.items[handle] = null;
}

pub fn beginRun(self: *Agent) Error!runtime.CancelToken {
    if (self.active_run != null) return error.AlreadyRunning;
    self.cancel_source.reset();
    self.active_run = self.operations.reserve();
    self.state.status = .{ .running = .{} };
    return self.cancel_source.token();
}

pub fn finishRun(self: *Agent) void {
    if (self.state.status != .failed) self.state.status = .idle;
    self.cancel_source.reset();
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

fn promptMessagesSkipInitialSteering(self: *Agent, messages: []const agent.AgentMessage) !void {
    try self.runPromptMessages(messages, true);
}

fn runPromptMessages(self: *Agent, messages: []const agent.AgentMessage, skip_initial_steering: bool) !void {
    const token = try self.beginRun();
    errdefer self.finishRun();
    var config = self.loop_config;
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
            defer self.allocator.free(drained);
            try self.promptMessagesSkipInitialSteering(drained);
            return;
        }
        if (self.follow_up_queue.hasItems()) {
            const drained = try self.follow_up_queue.drain(self.allocator);
            defer self.allocator.free(drained);
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
        self.loop_config,
        token,
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
        },
        .tool_execution_start => |tool_event| try self.addPendingToolCall(tool_event.tool_call_id),
        .tool_execution_update => {},
        .tool_execution_end => |tool_event| self.removePendingToolCall(tool_event.tool_call_id),
        .turn_end => |turn_end| {
            if (turn_end.message == .assistant) {
                if (turn_end.message.assistant.error_message) |message| {
                    self.state.status = .{ .failed = message };
                }
            }
        },
        .agent_end => self.clearStreamingMessage(),
    }
}

fn recordRunFailure(self: *Agent, token: runtime.CancelToken, message: []const u8) !void {
    const stop_reason: ai.StopReason = if (token.isRequested()) .aborted else .error_;
    const assistant = terminalAssistantMessage(self.state.model, stop_reason, message);
    try self.appendMessage(.{ .assistant = assistant });
    self.state.status = .{ .failed = message };
    try self.emitEvent(.{ .agent_end = .{ .messages = &.{.{ .assistant = assistant }} } });
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
    try self.emitEvent(event);
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
    const owned = try cloneAgentMessage(self.message_arena.allocator(), message);
    switch (self.state.status) {
        .running => |*running| running.streaming_message = owned,
        .idle => self.state.status = .{ .running = .{ .streaming_message = owned } },
        .settling, .failed => std.debug.panic("invalid transition to running", .{}),
    }
}

fn clearStreamingMessage(self: *Agent) void {
    switch (self.state.status) {
        .running => |*running| running.streaming_message = null,
        else => {},
    }
}

fn addPendingToolCall(self: *Agent, id: []const u8) Error!void {
    switch (self.state.status) {
        .running => |*running| {
            const owned_id = self.message_arena.allocator().dupe(u8, id) catch return error.QueueFull;
            running.pending_tool_calls.append(owned_id) catch return error.TooManyToolCalls;
        },
        .idle => {
            const owned_id = self.message_arena.allocator().dupe(u8, id) catch return error.QueueFull;
            self.state.status = .{ .running = .{} };
            self.state.status.running.pending_tool_calls.append(owned_id) catch return error.TooManyToolCalls;
        },
        .settling, .failed => std.debug.panic("invalid transition to running", .{}),
    }
}

fn removePendingToolCall(self: *Agent, id: []const u8) void {
    switch (self.state.status) {
        .running => |*running| running.pending_tool_calls.remove(id),
        else => {},
    }
}

pub const PendingMessageQueue = struct {
    mode: QueueMode = .one_at_a_time,
    messages: std.ArrayList(agent.AgentMessage) = .empty,

    pub fn deinit(self: *PendingMessageQueue, allocator: std.mem.Allocator) void {
        self.messages.deinit(allocator);
        self.* = undefined;
    }

    pub fn enqueue(
        self: *PendingMessageQueue,
        allocator: std.mem.Allocator,
        message: agent.AgentMessage,
    ) error{ QueueFull, OutOfMemory }!void {
        if (self.messages.items.len == max_queued_messages) return error.QueueFull;
        try self.messages.append(allocator, message);
    }

    pub fn hasItems(self: *const PendingMessageQueue) bool {
        return self.messages.items.len > 0;
    }

    pub fn count(self: *const PendingMessageQueue) usize {
        return self.messages.items.len;
    }

    pub fn hasCapacity(self: *const PendingMessageQueue) bool {
        return self.messages.items.len < max_queued_messages;
    }

    pub fn clear(self: *PendingMessageQueue) void {
        self.messages.clearRetainingCapacity();
    }

    pub fn drain(
        self: *PendingMessageQueue,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error![]const agent.AgentMessage {
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

fn cloneAgentMessage(allocator: std.mem.Allocator, source: agent.AgentMessage) !agent.AgentMessage {
    return switch (source) {
        .user => |message| .{ .user = .{
            .content = switch (message.content) {
                .string => |text| .{ .string = try allocator.dupe(u8, text) },
                .blocks => |blocks| .{ .blocks = try cloneUserContentSlice(allocator, blocks) },
            },
            .timestamp = message.timestamp,
        } },
        .assistant => |message| .{ .assistant = .{
            .content = try cloneAssistantContentSlice(allocator, message.content),
            .api = try allocator.dupe(u8, message.api),
            .provider = try allocator.dupe(u8, message.provider),
            .model = try allocator.dupe(u8, message.model),
            .response_id = try cloneOptionalString(allocator, message.response_id),
            .usage = message.usage,
            .stop_reason = message.stop_reason,
            .error_message = try cloneOptionalString(allocator, message.error_message),
            .timestamp = message.timestamp,
        } },
        .tool_result => |message| .{ .tool_result = .{
            .tool_call_id = try allocator.dupe(u8, message.tool_call_id),
            .tool_name = try allocator.dupe(u8, message.tool_name),
            .content = try cloneToolResultContentSlice(allocator, message.content),
            .details = if (message.details) |details| try cloneJsonValue(allocator, details) else null,
            .is_error = message.is_error,
            .timestamp = message.timestamp,
        } },
        .custom => |message| .{ .custom = .{
            .kind = try allocator.dupe(u8, message.kind),
            .payload = try cloneJsonValue(allocator, message.payload),
            .timestamp = message.timestamp,
        } },
    };
}

fn cloneUserContentSlice(allocator: std.mem.Allocator, source: []const ai.UserContent) ![]const ai.UserContent {
    const cloned = try allocator.alloc(ai.UserContent, source.len);
    for (source, cloned) |content, *out| {
        out.* = switch (content) {
            .text => |text| .{ .text = .{
                .text = try allocator.dupe(u8, text.text),
                .text_signature = try cloneOptionalString(allocator, text.text_signature),
            } },
            .image => |image| .{ .image = .{
                .data = try allocator.dupe(u8, image.data),
                .mime_type = try allocator.dupe(u8, image.mime_type),
            } },
        };
    }
    return cloned;
}

fn cloneAssistantContentSlice(
    allocator: std.mem.Allocator,
    source: []const ai.AssistantContent,
) ![]const ai.AssistantContent {
    const cloned = try allocator.alloc(ai.AssistantContent, source.len);
    for (source, cloned) |content, *out| {
        out.* = switch (content) {
            .text => |text| .{ .text = .{
                .text = try allocator.dupe(u8, text.text),
                .text_signature = try cloneOptionalString(allocator, text.text_signature),
            } },
            .thinking => |thinking| .{ .thinking = .{
                .thinking = try allocator.dupe(u8, thinking.thinking),
                .thinking_signature = try cloneOptionalString(allocator, thinking.thinking_signature),
                .redacted = thinking.redacted,
            } },
            .tool_call => |tool_call| .{ .tool_call = .{
                .id = try allocator.dupe(u8, tool_call.id),
                .name = try allocator.dupe(u8, tool_call.name),
                .arguments = try cloneJsonValue(allocator, tool_call.arguments),
                .thought_signature = try cloneOptionalString(allocator, tool_call.thought_signature),
            } },
        };
    }
    return cloned;
}

fn cloneToolResultContentSlice(
    allocator: std.mem.Allocator,
    source: []const ai.ToolResultContent,
) ![]const ai.ToolResultContent {
    const cloned = try allocator.alloc(ai.ToolResultContent, source.len);
    for (source, cloned) |content, *out| {
        out.* = switch (content) {
            .text => |text| .{ .text = .{
                .text = try allocator.dupe(u8, text.text),
                .text_signature = try cloneOptionalString(allocator, text.text_signature),
            } },
            .image => |image| .{ .image = .{
                .data = try allocator.dupe(u8, image.data),
                .mime_type = try allocator.dupe(u8, image.mime_type),
            } },
        };
    }
    return cloned;
}

fn cloneOptionalString(allocator: std.mem.Allocator, source: ?[]const u8) !?[]const u8 {
    return if (source) |value| try allocator.dupe(u8, value) else null;
}

fn cloneJsonValue(allocator: std.mem.Allocator, source: std.json.Value) !std.json.Value {
    return switch (source) {
        .null => .null,
        .bool => |value| .{ .bool = value },
        .integer => |value| .{ .integer = value },
        .float => |value| .{ .float = value },
        .number_string => |value| .{ .number_string = try allocator.dupe(u8, value) },
        .string => |value| .{ .string = try allocator.dupe(u8, value) },
        .array => |array| blk: {
            var cloned: std.json.Array = .init(allocator);
            for (array.items) |item| try cloned.append(try cloneJsonValue(allocator, item));
            break :blk .{ .array = cloned };
        },
        .object => |object| blk: {
            var cloned: std.json.ObjectMap = .empty;
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                try cloned.put(allocator, key, try cloneJsonValue(allocator, entry.value_ptr.*));
            }
            break :blk .{ .object = cloned };
        },
    };
}

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
            .tool_result => |tool_result| try out.append(allocator, .{ .tool_result = tool_result }),
            .custom => {},
        }
    }
    return out.toOwnedSlice(allocator);
}

fn defaultStream(_: ?*anyopaque, request: ai.StreamRequest) ai.AssistantMessageEventStream {
    var stream = ai.AssistantMessageEventStream.init(request.event_buffer);
    const sink = stream.sink();
    sink.endDone(request.io, .stop, .{
        .content = &.{},
        .api = request.model.api,
        .provider = request.model.provider,
        .model = request.model.id,
        .usage = ai.protocol.emptyUsage(),
        .stop_reason = .stop,
        .timestamp = 0,
    }) catch unreachable;
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

fn countListener(_: std.Io, context: ?*anyopaque, _: agent.AgentEvent, token: runtime.CancelToken) anyerror!void {
    const probe: *ListenerProbe = @ptrCast(@alignCast(context.?));
    probe.calls += 1;
    probe.saw_cancel_requested = token.isRequested();
}

test "agent creates default state" {
    var self = try Agent.init(std.testing.allocator, std.Io.failing, .{});
    defer self.deinit();

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
    var self = try Agent.init(std.testing.allocator, std.Io.failing, .{ .messages = &messages });
    defer self.deinit();

    messages[0] = userMessage("changed");
    text[0] = 'j';

    try std.testing.expectEqual(@as(usize, 1), self.state.messages.len);
    try std.testing.expectEqualStrings("hello", self.state.messages[0].user.content.string);
}

test "state mutators do not use event path" {
    var self = try Agent.init(std.testing.allocator, std.Io.failing, .{});
    defer self.deinit();

    self.setSystemPrompt("custom");
    self.setThinkingLevel(.high);

    try std.testing.expectEqualStrings("custom", self.state.system_prompt);
    try std.testing.expectEqual(agent.ThinkingLevel.high, self.state.thinking_level);
}

test "steering and follow-up queues do not mutate transcript" {
    var self = try Agent.init(std.testing.allocator, std.Io.failing, .{});
    defer self.deinit();

    try self.steer(userMessage("steer"));
    try self.followUp(userMessage("follow"));

    try std.testing.expect(self.hasQueuedMessages());
    try std.testing.expectEqual(@as(usize, 0), self.state.messages.len);
}

test "pending message queue drains one at a time by default" {
    var queue: PendingMessageQueue = .{};
    defer queue.deinit(std.testing.allocator);

    try queue.enqueue(std.testing.allocator, userMessage("one"));
    try queue.enqueue(std.testing.allocator, userMessage("two"));

    const drained = try queue.drain(std.testing.allocator);
    defer std.testing.allocator.free(drained);

    try std.testing.expectEqual(@as(usize, 1), drained.len);
    try std.testing.expectEqualStrings("one", drained[0].user.content.string);
    try std.testing.expect(queue.hasItems());
}

test "pending message queue has explicit maximum" {
    var queue: PendingMessageQueue = .{};
    defer queue.deinit(std.testing.allocator);

    for (0..max_queued_messages) |_| {
        try queue.enqueue(std.testing.allocator, userMessage("message"));
    }

    try std.testing.expectError(error.QueueFull, queue.enqueue(std.testing.allocator, userMessage("overflow")));
}

test "abort without active run is a no-op" {
    var self = try Agent.init(std.testing.allocator, std.Io.failing, .{});
    defer self.deinit();

    self.abort();

    try std.testing.expect(self.signal() == null);
}

test "reset clears transcript runtime state and queues" {
    var self = try Agent.init(std.testing.allocator, std.Io.failing, .{});
    defer self.deinit();

    try self.appendMessage(userMessage("hello"));
    try self.steer(userMessage("steer"));
    self.state.status = .{ .failed = "boom" };

    self.reset();

    try std.testing.expectEqual(@as(usize, 0), self.state.messages.len);
    try std.testing.expect(!self.hasQueuedMessages());
    try std.testing.expect(self.state.errorMessage() == null);
}

test "begin run rejects concurrent run and exposes cancel token" {
    var self = try Agent.init(std.testing.allocator, std.Io.failing, .{});
    defer self.deinit();

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
    var self = try Agent.init(std.testing.allocator, std.Io.failing, .{});
    defer self.deinit();
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

test "agent end enters settling until finish run" {
    var self = try Agent.init(std.testing.allocator, std.Io.failing, .{});
    defer self.deinit();
    _ = try self.beginRun();

    try self.emitEvent(.{ .agent_end = .{ .messages = &.{} } });

    try std.testing.expect(self.state.isStreaming());
    try std.testing.expect(!self.waitForIdle());
    self.finishRun();
    try std.testing.expect(!self.state.isStreaming());
}

test "tool execution events track pending tool calls" {
    var self = try Agent.init(std.testing.allocator, std.Io.failing, .{});
    defer self.deinit();
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

test "turn end records assistant error message" {
    var self = try Agent.init(std.testing.allocator, std.Io.failing, .{});
    defer self.deinit();
    _ = try self.beginRun();
    defer self.finishRun();
    var message = assistantMessage("");
    message.assistant.error_message = "failed";
    message.assistant.stop_reason = .error_;

    try self.emitEvent(.{ .turn_end = .{ .message = message, .tool_results = &.{} } });

    try std.testing.expectEqualStrings("failed", self.state.errorMessage().?);
}

test "prompt text emits lifecycle and appends user message" {
    var self = try Agent.init(std.testing.allocator, std.Io.failing, .{});
    defer self.deinit();
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
    var self = try Agent.init(std.testing.allocator, std.Io.failing, .{});
    defer self.deinit();
    _ = try self.beginRun();
    defer self.finishRun();

    try std.testing.expectError(error.AlreadyRunning, self.promptText("blocked", &.{}));
}

test "continue rejects empty transcript" {
    var self = try Agent.init(std.testing.allocator, std.Io.failing, .{});
    defer self.deinit();

    try std.testing.expectError(error.NoMessages, self.continueRun());
}

test "continue from assistant drains one steering batch" {
    var self = try Agent.init(std.testing.allocator, std.Io.failing, .{});
    defer self.deinit();
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
    var self = try Agent.init(std.testing.allocator, std.Io.failing, .{});
    defer self.deinit();
    try self.appendMessage(assistantMessage("done"));
    try self.followUp(userMessage("next"));

    try self.continueRun();

    try std.testing.expectEqual(@as(usize, 3), self.state.messages.len);
    try std.testing.expectEqualStrings("next", self.state.messages[1].user.content.string);
    try std.testing.expect(self.state.messages[2] == .assistant);
}
