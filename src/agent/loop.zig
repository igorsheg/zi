const std = @import("std");
const agent = @import("root.zig");
const ai = @import("../ai/root.zig");
const runtime = @import("../runtime/root.zig");
const tool_runner = @import("tool_runner.zig");

pub const EventSink = agent.EventSink;

/// One mirrored event plus the arena that owns every allocation inside it.
/// The consumer drops the arena in one call instead of a deep per-field free.
pub const StreamEvent = struct {
    arena: std.heap.ArenaAllocator,
    event: agent.AgentEvent,

    pub fn deinit(self: *StreamEvent) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const AgentEventPipe = runtime.EventPipe(StreamEvent, void);
pub const AgentEventStreamNextError = AgentEventPipe.NextError;
pub const AgentEventStreamEmitError = AgentEventPipe.EmitError;
pub const AgentEventStreamPoll = AgentEventPipe.Stream.Poll;

pub const AgentEventStream = struct {
    allocator: std.mem.Allocator,
    pipe: AgentEventPipe,
    producer: Producer = .settled,

    const Producer = union(enum) {
        running: runtime.Task(anyerror!void),
        spawn_failed: anyerror,
        settled,
    };

    pub fn init(allocator: std.mem.Allocator, buffer: []StreamEvent) AgentEventStream {
        return .{
            .allocator = allocator,
            .pipe = AgentEventPipe.init(buffer),
        };
    }

    pub fn deinit(self: *AgentEventStream) void {
        std.debug.assert(self.producer == .settled);
        self.discardPendingEvents();

        self.* = undefined;
    }

    pub fn next(self: *AgentEventStream) AgentEventStreamNextError!?StreamEvent {
        return self.pipe.stream().next();
    }

    pub fn poll(self: *AgentEventStream) AgentEventStreamPoll {
        return self.pipe.stream().poll();
    }

    pub fn asyncNext(self: *AgentEventStream) @TypeOf(self.pipe.stream().asyncNext()) {
        return self.pipe.stream().asyncNext();
    }

    pub fn awaitProducer(self: *AgentEventStream) anyerror!void {
        switch (self.producer) {
            .running => |*handle| {
                defer self.producer = .settled;
                try handle.join();
            },
            .spawn_failed => |err| {
                self.producer = .settled;
                return err;
            },
            .settled => {},
        }
    }

    pub fn cancelProducer(self: *AgentEventStream) anyerror!void {
        switch (self.producer) {
            .running => |*handle| {
                defer self.producer = .settled;
                handle.cancel();
                try handle.result;
            },
            .spawn_failed => |err| {
                self.producer = .settled;
                return err;
            },
            .settled => {},
        }
    }

    fn discardPendingEvents(self: *AgentEventStream) void {
        while (true) {
            switch (self.pipe.stream().poll()) {
                .event => |event| {
                    var owned = event;
                    owned.deinit();
                },
                .empty, .terminal => return,
            }
        }
    }
};

pub fn startPromptStream(
    stream: *AgentEventStream,
    allocator: std.mem.Allocator,
    task_runtime: *runtime.Runtime,
    prompts: []const agent.AgentMessage,
    context: agent.AgentContext,
    config: agent.AgentLoopConfig,
    token: runtime.CancelToken,
    buffer: []StreamEvent,
) void {
    const stream_io = task_runtime.io();
    stream.* = AgentEventStream.init(allocator, buffer);
    stream.producer = .{ .running = task_runtime.spawn(
        runPromptStreamProducer,
        .{ allocator, stream_io, prompts, context, config, token, task_runtime, stream },
    ) catch |err| {
        stream.pipe.sink().abort();
        stream.producer = .{ .spawn_failed = err };
        return;
    } };
}

fn runPromptStreamProducer(
    allocator: std.mem.Allocator,
    io: std.Io,
    prompts: []const agent.AgentMessage,
    context: agent.AgentContext,
    config: agent.AgentLoopConfig,
    token: runtime.CancelToken,
    task_runtime: *runtime.Runtime,
    stream: *AgentEventStream,
) anyerror!void {
    runPrompt(allocator, io, prompts, context, config, token, task_runtime, streamSink(stream)) catch |err| {
        stream.pipe.sink().abort();
        return err;
    };
}

/// Continuation sibling of startPromptStream: stream a run that resumes from
/// the existing context without appending a new user message. The last
/// context message must not be an assistant message.
pub fn startContinueStream(
    stream: *AgentEventStream,
    allocator: std.mem.Allocator,
    task_runtime: *runtime.Runtime,
    context: agent.AgentContext,
    config: agent.AgentLoopConfig,
    token: runtime.CancelToken,
    buffer: []StreamEvent,
) void {
    const stream_io = task_runtime.io();
    stream.* = AgentEventStream.init(allocator, buffer);
    stream.producer = .{ .running = task_runtime.spawn(
        runContinueStreamProducer,
        .{ allocator, stream_io, context, config, token, task_runtime, stream },
    ) catch |err| {
        stream.pipe.sink().abort();
        stream.producer = .{ .spawn_failed = err };
        return;
    } };
}

fn runContinueStreamProducer(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: agent.AgentContext,
    config: agent.AgentLoopConfig,
    token: runtime.CancelToken,
    task_runtime: *runtime.Runtime,
    stream: *AgentEventStream,
) anyerror!void {
    runContinue(allocator, io, context, config, token, task_runtime, streamSink(stream)) catch |err| {
        stream.pipe.sink().abort();
        return err;
    };
}

pub const Error = error{
    NoMessages,
    CannotContinueFromAssistant,
    TooManyTools,
    MissingAssistantResult,
};

fn copyStreamEvent(allocator: std.mem.Allocator, event: agent.AgentEvent) !agent.AgentEvent {
    return switch (event) {
        .tool_execution_start => |payload| blk: {
            const tool_call_id = try allocator.dupe(u8, payload.tool_call_id);
            errdefer allocator.free(tool_call_id);
            const tool_name = try allocator.dupe(u8, payload.tool_name);
            errdefer allocator.free(tool_name);
            const args = try runtime.cloneJsonValue(allocator, payload.args);
            errdefer runtime.freeJsonValue(allocator, args);
            break :blk .{ .tool_execution_start = .{
                .tool_call_id = tool_call_id,
                .tool_name = tool_name,
                .args = args,
            } };
        },
        .tool_execution_update => |payload| blk: {
            const tool_call_id = try allocator.dupe(u8, payload.tool_call_id);
            errdefer allocator.free(tool_call_id);
            const tool_name = try allocator.dupe(u8, payload.tool_name);
            errdefer allocator.free(tool_name);
            const args = try runtime.cloneJsonValue(allocator, payload.args);
            errdefer runtime.freeJsonValue(allocator, args);
            const partial_result = try agent.copyAgentToolResult(allocator, payload.partial_result);
            errdefer agent.deinitAgentToolResult(allocator, partial_result);
            break :blk .{ .tool_execution_update = .{
                .tool_call_id = tool_call_id,
                .tool_name = tool_name,
                .args = args,
                .partial_result = partial_result,
            } };
        },
        .tool_execution_end => |payload| blk: {
            const tool_call_id = try allocator.dupe(u8, payload.tool_call_id);
            errdefer allocator.free(tool_call_id);
            const tool_name = try allocator.dupe(u8, payload.tool_name);
            errdefer allocator.free(tool_name);
            const result = try agent.copyAgentToolResult(allocator, payload.result);
            errdefer agent.deinitAgentToolResult(allocator, result);
            break :blk .{ .tool_execution_end = .{
                .tool_call_id = tool_call_id,
                .tool_name = tool_name,
                .result = result,
                .is_error = payload.is_error,
            } };
        },
        .message_start => |payload| .{ .message_start = .{
            .message = try copyStreamMessage(allocator, payload.message),
        } },
        .message_update => |payload| blk: {
            const assistant_message_event = try copyCompactAssistantMessageEvent(
                allocator,
                payload.assistant_message_event,
            );
            break :blk .{ .message_update = .{
                .assistant_message_event = assistant_message_event,
            } };
        },
        .message_end => |payload| .{ .message_end = .{
            .message = try copyStreamMessage(allocator, payload.message),
        } },
        .turn_end => .turn_end,
        else => event,
    };
}

const stream_tool_argument_preview_bytes_max: usize = 8 * 1024;

fn copyCompactAssistantMessageEvent(
    allocator: std.mem.Allocator,
    source: ai.AssistantMessageEvent,
) !ai.AssistantMessageEvent {
    return switch (source) {
        .text_delta => |event| blk: {
            const delta = try allocator.dupe(u8, event.delta);
            errdefer allocator.free(delta);
            const partial = try copyDeltaPartial(allocator, event.partial, event.content_index, .text);
            errdefer ai.owned.deinitAssistantMessage(allocator, partial);
            break :blk .{ .text_delta = .{
                .content_index = event.content_index,
                .delta = delta,
                .partial = partial,
            } };
        },
        .thinking_delta => |event| blk: {
            const delta = try allocator.dupe(u8, event.delta);
            errdefer allocator.free(delta);
            const partial = try copyDeltaPartial(allocator, event.partial, event.content_index, .thinking);
            errdefer ai.owned.deinitAssistantMessage(allocator, partial);
            break :blk .{ .thinking_delta = .{
                .content_index = event.content_index,
                .delta = delta,
                .partial = partial,
            } };
        },
        .toolcall_start => |event| blk: {
            const partial = try copyDeltaPartial(allocator, event.partial, event.content_index, .tool_call);
            errdefer ai.owned.deinitAssistantMessage(allocator, partial);
            break :blk .{ .toolcall_start = .{
                .content_index = event.content_index,
                .partial = partial,
            } };
        },
        .toolcall_delta => |event| blk: {
            const delta = try allocator.dupe(u8, event.delta);
            errdefer allocator.free(delta);
            const partial = try copyDeltaPartial(allocator, event.partial, event.content_index, .tool_call);
            errdefer ai.owned.deinitAssistantMessage(allocator, partial);
            break :blk .{ .toolcall_delta = .{
                .content_index = event.content_index,
                .delta = delta,
                .partial = partial,
            } };
        },
        .toolcall_end => |event| blk: {
            const tool_call = try copyToolCallPreview(allocator, event.tool_call);
            errdefer ai.owned.deinitToolCall(allocator, tool_call);
            const partial = try copyDeltaPartial(allocator, event.partial, event.content_index, .tool_call);
            errdefer ai.owned.deinitAssistantMessage(allocator, partial);
            break :blk .{ .toolcall_end = .{
                .content_index = event.content_index,
                .tool_call = tool_call,
                .partial = partial,
            } };
        },
        else => ai.owned.copyAssistantMessageEvent(allocator, source),
    };
}

const DeltaPartialKind = enum { text, thinking, tool_call };

fn copyDeltaPartial(
    allocator: std.mem.Allocator,
    source: ai.AssistantMessage,
    content_index: usize,
    kind: DeltaPartialKind,
) !ai.AssistantMessage {
    // Text/thinking delta partials only ever carried empty placeholder blocks
    // (live text reaches clients through the event's `delta` field, not the
    // partial), so an empty content slice is information-equivalent and skips
    // the per-delta O(content_index) placeholder rebuild. Tool-call partials
    // still carry the argument preview below.
    if (kind == .text or kind == .thinking) {
        return copyAssistantMetadataWithContent(allocator, source, &.{});
    }
    // Only tool-call deltas reach here (text/thinking returned above). The
    // partial keeps a tool_call preview at the active index and empty
    // placeholders for the blocks before it.
    if (content_index >= source.content.len) return ai.owned.copyAssistantMessage(allocator, source);
    const content = try copyDeltaContent(
        allocator,
        source.content[content_index],
        content_index + 1,
        content_index,
    );
    errdefer ai.owned.deinitAssistantContentSlice(allocator, content);
    return copyAssistantMetadataWithContent(allocator, source, content);
}

fn copyDeltaContent(
    allocator: std.mem.Allocator,
    target: ai.AssistantContent,
    content_len: usize,
    target_index: usize,
) ![]const ai.AssistantContent {
    const content = try allocator.alloc(ai.AssistantContent, content_len);
    var initialized: usize = 0;
    errdefer {
        ai.owned.deinitAssistantContentItems(allocator, content[0..initialized]);
        allocator.free(content);
    }
    for (content, 0..) |*item, index| {
        item.* = if (index == target_index and target == .tool_call)
            .{ .tool_call = try copyToolCallPreview(allocator, target.tool_call) }
        else
            .{ .text = .{ .text = try allocator.dupe(u8, "") } };
        initialized += 1;
    }
    return content;
}

fn copyToolCallPreview(allocator: std.mem.Allocator, tool_call: ai.ToolCall) !ai.ToolCall {
    const id = try allocator.dupe(u8, tool_call.id);
    errdefer allocator.free(id);
    const name = try allocator.dupe(u8, tool_call.name);
    errdefer allocator.free(name);
    const arguments = try copyToolArgumentPreview(allocator, tool_call.arguments);
    errdefer runtime.freeJsonValue(allocator, arguments);
    return .{
        .id = id,
        .name = name,
        .arguments = arguments,
        .thought_signature = null,
    };
}

fn copyToolArgumentPreview(allocator: std.mem.Allocator, arguments: std.json.Value) !std.json.Value {
    if (arguments != .object) return .null;
    var object: std.json.ObjectMap = .empty;
    errdefer runtime.freeJsonValue(allocator, .{ .object = object });
    const string_keys = [_][]const u8{
        "command",
        "path",
        "file_path",
        "pattern",
        "name",
        "content",
        "glob",
    };
    for (string_keys) |key| {
        const value = arguments.object.get(key) orelse continue;
        if (value != .string) continue;
        const key_copy = try allocator.dupe(u8, key);
        errdefer allocator.free(key_copy);
        const bounded = agent.utf8Prefix(value.string, stream_tool_argument_preview_bytes_max);
        const value_copy = try allocator.dupe(u8, bounded);
        errdefer allocator.free(value_copy);
        try object.put(allocator, key_copy, .{ .string = value_copy });
    }
    const integer_keys = [_][]const u8{ "offset", "limit", "timeout" };
    for (integer_keys) |key| {
        const value = arguments.object.get(key) orelse continue;
        if (value != .integer) continue;
        const key_copy = try allocator.dupe(u8, key);
        errdefer allocator.free(key_copy);
        try object.put(allocator, key_copy, .{ .integer = value.integer });
    }
    return .{ .object = object };
}

fn copyAssistantMetadataWithContent(
    allocator: std.mem.Allocator,
    source: ai.AssistantMessage,
    content: []const ai.AssistantContent,
) !ai.AssistantMessage {
    const api = try allocator.dupe(u8, source.api);
    errdefer allocator.free(api);
    const provider = try allocator.dupe(u8, source.provider);
    errdefer allocator.free(provider);
    const model = try allocator.dupe(u8, source.model);
    errdefer allocator.free(model);
    const response_id = if (source.response_id) |value| try allocator.dupe(u8, value) else null;
    errdefer if (response_id) |value| allocator.free(value);
    const error_message = if (source.error_message) |value| try allocator.dupe(u8, value) else null;
    return .{
        .content = content,
        .api = api,
        .provider = provider,
        .model = model,
        .response_id = response_id,
        .usage = source.usage,
        .stop_reason = source.stop_reason,
        .error_message = error_message,
        .timestamp = source.timestamp,
    };
}

fn copyStreamMessage(allocator: std.mem.Allocator, message: agent.AgentMessage) !agent.AgentMessage {
    return switch (message) {
        .tool_result => |tool_result| .{ .tool_result = try tool_runner.createToolResultMessage(
            allocator,
            .{ .id = tool_result.tool_call_id, .name = tool_result.tool_name, .arguments = .null },
            .{ .content = tool_result.content, .details = tool_result.details },
            tool_result.is_error,
        ) },
        .assistant => |assistant| .{ .assistant = try ai.owned.copyAssistantMessage(allocator, assistant) },
        .user, .custom => try agent.copyAgentMessage(allocator, message),
    };
}

fn copyStreamToolResultMessages(
    allocator: std.mem.Allocator,
    source: []const ai.ToolResultMessage,
) ![]const ai.ToolResultMessage {
    const cloned = try allocator.alloc(ai.ToolResultMessage, source.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |message| agent.deinitToolResultMessage(allocator, message);
        allocator.free(cloned);
    }
    for (source, cloned) |message, *out| {
        out.* = try tool_runner.createToolResultMessage(
            allocator,
            .{ .id = message.tool_call_id, .name = message.tool_name, .arguments = .null },
            .{ .content = message.content, .details = message.details },
            message.is_error,
        );
        initialized += 1;
    }
    return cloned;
}

fn streamSink(stream: *AgentEventStream) EventSink {
    return .{ .context = stream, .call_fn = streamSinkEmit };
}

fn streamSinkEmit(context: ?*anyopaque, event: agent.AgentEvent) anyerror!void {
    const stream: *AgentEventStream = @ptrCast(@alignCast(context.?));
    switch (event) {
        .agent_end => try stream.pipe.sink().end(.{
            // agent_end carries no payload; an empty arena allocates nothing,
            // so dropping it on an end() error is harmless.
            .arena = std.heap.ArenaAllocator.init(stream.allocator),
            .event = .agent_end,
        }, {}),
        else => {
            // Each mirrored event owns its allocations in a private arena.
            // On a successful emit the ring slot takes the arena by value; on
            // failure we drop it here. (Safe: the copied event holds pointers
            // into heap pages, not into the moved arena struct.)
            var arena = std.heap.ArenaAllocator.init(stream.allocator);
            errdefer arena.deinit();
            const copied = try copyStreamEvent(arena.allocator(), event);
            try stream.pipe.sink().emit(.{ .arena = arena, .event = copied });
        },
    }
}

pub fn runPrompt(
    allocator: std.mem.Allocator,
    io: std.Io,
    prompts: []const agent.AgentMessage,
    context: agent.AgentContext,
    config: agent.AgentLoopConfig,
    token: runtime.CancelToken,
    task_runtime: *runtime.Runtime,
    emit: EventSink,
) !void {
    var current = try Context.init(allocator, context);
    defer current.deinit();

    try emit.emit(.agent_start);
    try emit.emit(.turn_start);
    for (prompts) |prompt| {
        try emit.emit(.{ .message_start = .{ .message = prompt } });
        try emit.emit(.{ .message_end = .{ .message = prompt } });
        try current.messages.append(allocator, prompt);
    }

    try runLoop(allocator, io, &current, config, token, task_runtime, emit);
}

pub fn runContinue(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: agent.AgentContext,
    config: agent.AgentLoopConfig,
    token: runtime.CancelToken,
    task_runtime: *runtime.Runtime,
    emit: EventSink,
) !void {
    if (context.messages.len == 0) return error.NoMessages;
    if (context.messages[context.messages.len - 1] == .assistant) return error.CannotContinueFromAssistant;

    var current = try Context.init(allocator, context);
    defer current.deinit();

    try emit.emit(.agent_start);
    try emit.emit(.turn_start);
    try runLoop(allocator, io, &current, config, token, task_runtime, emit);
}

fn runLoop(
    allocator: std.mem.Allocator,
    io: std.Io,
    current: *Context,
    config: agent.AgentLoopConfig,
    token: runtime.CancelToken,
    task_runtime: *runtime.Runtime,
    emit: EventSink,
) !void {
    var first_turn = true;
    var pending_messages = try drainMessages(allocator, config.get_steering_messages);
    // Contents are deinited by emitPendingMessages once consumed; this defer
    // covers early returns (cancellation) that leave a batch unconsumed.
    defer freePendingMessages(allocator, pending_messages);

    while (true) {
        var has_more_tool_calls = true;
        while (has_more_tool_calls or pending_messages.len > 0) {
            if (token.isRequested()) {
                const aborted = try ai.owned.copyAssistantMessage(
                    current.ownedAllocator(),
                    terminalAssistantMessage(config.model, .aborted, "aborted"),
                );
                try current.messages.append(allocator, .{ .assistant = aborted });
                try emit.emit(.{ .message_start = .{ .message = .{ .assistant = aborted } } });
                try emit.emit(.{ .message_end = .{ .message = .{ .assistant = aborted } } });
                try emit.emit(.turn_end);
                try emit.emit(.agent_end);
                return;
            }
            if (first_turn) {
                first_turn = false;
            } else {
                try emit.emit(.turn_start);
            }

            if (pending_messages.len > 0) {
                try emitPendingMessages(allocator, current, pending_messages, emit);
                allocator.free(pending_messages);
                pending_messages = &.{};
            }

            // streamAssistantResponse returns into current.owned_arena, so an
            // append failure leaves the message owned by the arena (no leak,
            // no per-field free) and Context.deinit drops it.
            const assistant = try streamAssistantResponse(
                allocator,
                io,
                current,
                config,
                token,
                emit,
            );
            try current.messages.append(allocator, .{ .assistant = assistant });

            if (assistant.stop_reason == .error_ or assistant.stop_reason == .aborted) {
                try emit.emit(.turn_end);
                try emit.emit(.agent_end);
                return;
            }

            const tool_results = try tool_runner.Runner.init(
                allocator,
                current.ownedAllocator(),
                io,
                task_runtime,
                .{
                    .system_prompt = current.system_prompt,
                    .messages = current.messages.items,
                    .tools = current.tools,
                },
                assistant,
                config,
                token,
                emit,
            ).run();
            // Message contents live in current.owned_arena; only the slice
            // container is scratch. An append failure leaves the remaining
            // messages owned by the arena, which Context.deinit drops.
            defer allocator.free(tool_results.messages);
            for (tool_results.messages) |message| {
                try current.messages.append(allocator, .{ .tool_result = message });
            }

            try emit.emit(.turn_end);

            has_more_tool_calls = tool_results.messages.len > 0 and !tool_results.terminate;
            allocator.free(pending_messages);
            pending_messages = try drainMessages(allocator, config.get_steering_messages);
        }

        allocator.free(pending_messages);
        pending_messages = try drainMessages(allocator, config.get_follow_up_messages);
        if (pending_messages.len == 0) break;
    }

    try emit.emit(.agent_end);
}

fn drainMessages(
    allocator: std.mem.Allocator,
    hook: ?agent.GetMessagesHook,
) std.mem.Allocator.Error![]const agent.AgentMessage {
    if (hook) |get_messages| return agent.GetMessagesHook.call(allocator, get_messages);
    return allocator.alloc(agent.AgentMessage, 0);
}

fn freePendingMessages(allocator: std.mem.Allocator, messages: []const agent.AgentMessage) void {
    for (messages) |message| agent.deinitAgentMessage(allocator, message);
    allocator.free(messages);
}

fn emitPendingMessages(
    allocator: std.mem.Allocator,
    current: *Context,
    messages: []const agent.AgentMessage,
    emit: EventSink,
) !void {
    // Re-home pending messages into the owned arena so Context owns every
    // in-loop message uniformly. The queue/hook contract hands us ownership
    // of every message's contents; the slice container itself is freed by
    // the caller.
    defer for (messages) |message| agent.deinitAgentMessage(allocator, message);
    for (messages) |message| {
        try emit.emit(.{ .message_start = .{ .message = message } });
        try emit.emit(.{ .message_end = .{ .message = message } });
        const owned = try agent.copyAgentMessage(current.ownedAllocator(), message);
        try current.messages.append(allocator, owned);
    }
}

fn streamAssistantResponse(
    allocator: std.mem.Allocator,
    io: std.Io,
    current: *Context,
    config: agent.AgentLoopConfig,
    token: runtime.CancelToken,
    emit: EventSink,
) !ai.AssistantMessage {
    var request_arena = std.heap.ArenaAllocator.init(allocator);
    defer request_arena.deinit();
    const request_allocator = request_arena.allocator();

    const llm_messages = try agent.ConvertToLlmHook.call(
        request_allocator,
        config.convert_to_llm,
        current.messages.items,
    );
    var tools = std.ArrayList(ai.Tool).empty;
    defer tools.deinit(allocator);
    for (current.tools) |tool| try tools.append(allocator, tool.asTool());

    var stream_options = config.options.stream;
    var owned_api_key: ?[]const u8 = null;
    defer if (owned_api_key) |api_key| allocator.free(api_key);
    if (config.get_api_key) |get_api_key| {
        if (try agent.GetApiKeyHook.call(allocator, get_api_key, config.model.provider)) |credential| {
            owned_api_key = credential.api_key;
            stream_options.api_key = credential.api_key;
            stream_options.auth_extra = credential.auth_extra;
        }
    }

    var response_arena = std.heap.ArenaAllocator.init(allocator);
    defer response_arena.deinit();

    var stream = config.stream.call(.{
        .allocator = response_arena.allocator(),
        .io = io,
        .model = config.model,
        .context = .{
            // An empty agent system prompt means none on the wire.
            .system_prompt = if (current.system_prompt.len == 0) null else current.system_prompt,
            .messages = llm_messages,
            .tools = tools.items,
        },
        .options = stream_options,
        .cancel_token = token,
    });
    defer stream.deinit();

    var added_partial = false;
    while (try stream.next(io)) |event| {
        switch (event) {
            .start => |start| {
                added_partial = true;
                try emit.emit(.{ .message_start = .{ .message = .{ .assistant = start.partial } } });
            },
            .text_start,
            .text_delta,
            .text_end,
            .thinking_start,
            .thinking_delta,
            .thinking_end,
            .toolcall_start,
            .toolcall_delta,
            .toolcall_end,
            => try emit.emit(.{ .message_update = .{
                .assistant_message_event = event,
            } }),
            .done => |done| {
                if (!added_partial) {
                    try emit.emit(.{ .message_start = .{ .message = .{ .assistant = done.message } } });
                }
                try emit.emit(.{ .message_end = .{ .message = .{ .assistant = done.message } } });
                return ai.owned.copyAssistantMessage(current.ownedAllocator(), done.message);
            },
            .@"error" => |err| {
                if (!added_partial) {
                    try emit.emit(.{ .message_start = .{ .message = .{ .assistant = err.@"error" } } });
                }
                try emit.emit(.{ .message_end = .{ .message = .{ .assistant = err.@"error" } } });
                return ai.owned.copyAssistantMessage(current.ownedAllocator(), err.@"error");
            },
        }
    }

    const result = stream.result() orelse return error.MissingAssistantResult;
    if (!added_partial) try emit.emit(.{ .message_start = .{ .message = .{ .assistant = result } } });
    try emit.emit(.{ .message_end = .{ .message = .{ .assistant = result } } });
    return ai.owned.copyAssistantMessage(current.ownedAllocator(), result);
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

const Context = struct {
    allocator: std.mem.Allocator,
    // Owns every message produced inside the loop (assistant + tool results).
    // Dropped as a unit in deinit, so no per-message free walk is needed and
    // clones into it need no errdefer unwinding.
    owned_arena: std.heap.ArenaAllocator,
    system_prompt: []const u8,
    messages: std.ArrayList(agent.AgentMessage),
    tools: []const agent.AgentTool,

    fn init(allocator: std.mem.Allocator, source: agent.AgentContext) !Context {
        var messages = std.ArrayList(agent.AgentMessage).empty;
        errdefer messages.deinit(allocator);
        try messages.appendSlice(allocator, source.messages);
        return .{
            .allocator = allocator,
            .owned_arena = std.heap.ArenaAllocator.init(allocator),
            .system_prompt = source.system_prompt,
            .messages = messages,
            .tools = source.tools,
        };
    }

    fn ownedAllocator(self: *Context) std.mem.Allocator {
        return self.owned_arena.allocator();
    }

    fn deinit(self: *Context) void {
        // All in-loop messages (assistant + tool results) live in owned_arena.
        self.owned_arena.deinit();
        self.messages.deinit(self.allocator);
        self.* = undefined;
    }
};

fn testConvertToLlm(
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

fn testSink(context: ?*anyopaque, event: agent.AgentEvent) anyerror!void {
    const events: *std.ArrayList(agent.AgentEvent) = @ptrCast(@alignCast(context.?));
    try events.append(std.testing.allocator, switch (event) {
        .message_start => |payload| .{ .message_start = .{ .message = try copyMessageForTest(payload.message) } },
        .message_update => event,
        .message_end => |payload| .{ .message_end = .{ .message = try copyMessageForTest(payload.message) } },
        .turn_end => .turn_end,
        .agent_end => .agent_end,
        else => event,
    });
}

fn failOnToolUpdateSink(context: ?*anyopaque, event: agent.AgentEvent) anyerror!void {
    if (event == .tool_execution_update) return error.TestSinkFailed;
    try testSink(context, event);
}

fn copyMessageForTest(message: agent.AgentMessage) !agent.AgentMessage {
    return switch (message) {
        .tool_result => |tool_result| .{
            .tool_result = try agent.copyToolResultMessage(std.testing.allocator, tool_result),
        },
        else => message,
    };
}

fn deinitTestEvents(events: []const agent.AgentEvent) void {
    for (events) |event| switch (event) {
        .message_start => |payload| deinitTestMessage(payload.message),
        .message_end => |payload| deinitTestMessage(payload.message),
        .turn_end => {},
        else => {},
    };
}

fn deinitTestMessage(message: agent.AgentMessage) void {
    if (message == .tool_result) agent.deinitToolResultMessage(std.testing.allocator, message.tool_result);
}

fn testStream(_: ?*anyopaque, request: ai.StreamRequest) ai.AssistantMessageEventStream {
    var stream = ai.AssistantMessageEventStream.initBuffered();
    const sink = stream.sink();
    sink.endDone(request.io, .stop, assistantMessage("ok")) catch std.debug.assert(false);
    return stream;
}

fn emptyStream(_: ?*anyopaque, _: ai.StreamRequest) ai.AssistantMessageEventStream {
    return ai.AssistantMessageEventStream.initBuffered();
}

const fast_delta_stream_count = 240;

fn fastDeltaBufferedStream(_: ?*anyopaque, request: ai.StreamRequest) ai.AssistantMessageEventStream {
    var stream = ai.AssistantMessageEventStream.initBuffered();
    const sink = stream.sink();
    sink.emit(request.io, .{ .start = .{ .partial = assistantMessage("partial") } }) catch std.debug.assert(false);
    var count: usize = 0;
    while (count < fast_delta_stream_count) : (count += 1) {
        sink.emit(request.io, .{ .text_delta = .{
            .content_index = 0,
            .delta = "x",
            .partial = assistantMessage("partial"),
        } }) catch std.debug.assert(false);
    }
    sink.endDone(request.io, .stop, assistantMessage("done")) catch std.debug.assert(false);
    return stream;
}

fn testToolStream(context: ?*anyopaque, request: ai.StreamRequest) ai.AssistantMessageEventStream {
    const calls: *usize = @ptrCast(@alignCast(context.?));
    var stream = ai.AssistantMessageEventStream.initBuffered();
    const sink = stream.sink();
    if (calls.* == 0) {
        sink.endDone(request.io, .tool_use, assistantToolCallMessage()) catch std.debug.assert(false);
    } else {
        sink.endDone(request.io, .stop, assistantMessage("done")) catch std.debug.assert(false);
    }
    calls.* += 1;
    return stream;
}

fn testTwoToolStream(context: ?*anyopaque, request: ai.StreamRequest) ai.AssistantMessageEventStream {
    const calls: *usize = @ptrCast(@alignCast(context.?));
    var stream = ai.AssistantMessageEventStream.initBuffered();
    const sink = stream.sink();
    if (calls.* == 0) {
        sink.endDone(request.io, .tool_use, assistantTwoToolCallMessage()) catch std.debug.assert(false);
    } else {
        sink.endDone(request.io, .stop, assistantMessage("done")) catch std.debug.assert(false);
    }
    calls.* += 1;
    return stream;
}

fn assistantMessage(_: []const u8) ai.AssistantMessage {
    return .{
        .content = &.{},
        .api = ai.KnownApi.openai_responses,
        .provider = ai.KnownProvider.openai,
        .model = "test-model",
        .usage = ai.protocol.emptyUsage(),
        .stop_reason = .stop,
        .timestamp = 0,
    };
}

fn assistantToolCallMessage() ai.AssistantMessage {
    return .{
        .content = &.{.{ .tool_call = .{
            .id = "tool-1",
            .name = "echo",
            .arguments = .{ .object = .empty },
        } }},
        .api = ai.KnownApi.openai_responses,
        .provider = ai.KnownProvider.openai,
        .model = "test-model",
        .usage = ai.protocol.emptyUsage(),
        .stop_reason = .tool_use,
        .timestamp = 0,
    };
}

fn assistantTwoToolCallMessage() ai.AssistantMessage {
    return .{
        .content = &.{
            .{ .tool_call = .{
                .id = "tool-1",
                .name = "echo",
                .arguments = .{ .object = .empty },
            } },
            .{ .tool_call = .{
                .id = "tool-2",
                .name = "echo",
                .arguments = .{ .object = .empty },
            } },
        },
        .api = ai.KnownApi.openai_responses,
        .provider = ai.KnownProvider.openai,
        .model = "test-model",
        .usage = ai.protocol.emptyUsage(),
        .stop_reason = .tool_use,
        .timestamp = 0,
    };
}

test "stream event copy bounds delta partial to changed content" {
    var args = std.json.ObjectMap.empty;
    defer args.deinit(std.testing.allocator);
    try args.put(std.testing.allocator, "command", .{ .string = "echo hi" });
    try args.put(std.testing.allocator, "content", .{
        .string = "large write content must not be copied on each delta" ** 512,
    });
    try args.put(std.testing.allocator, "offset", .{ .integer = 10 });
    try args.put(std.testing.allocator, "limit", .{ .integer = 20 });

    const content = [_]ai.AssistantContent{
        .{ .text = .{ .text = "large prior text that should not be copied into delta partial" } },
        .{ .tool_call = .{ .id = "call-1", .name = "bash", .arguments = .{ .object = args } } },
    };
    const partial: ai.AssistantMessage = .{
        .content = &content,
        .api = "api",
        .provider = "provider",
        .model = "model",
        .usage = ai.protocol.emptyUsage(),
        .stop_reason = .tool_use,
        .timestamp = 0,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const copied = try copyStreamEvent(arena.allocator(), .{ .message_update = .{
        .assistant_message_event = .{ .toolcall_delta = .{
            .content_index = 1,
            .delta = "{",
            .partial = partial,
        } },
    } });

    const update = copied.message_update;
    try std.testing.expect(update.assistant_message_event == .toolcall_delta);
    const copied_partial = update.assistant_message_event.toolcall_delta.partial;
    try std.testing.expectEqual(@as(usize, 2), copied_partial.content.len);
    try std.testing.expectEqualStrings("", copied_partial.content[0].text.text);
    try std.testing.expect(copied_partial.content[1] == .tool_call);
    try std.testing.expectEqualStrings("bash", copied_partial.content[1].tool_call.name);
    const preview = copied_partial.content[1].tool_call.arguments.object.get("content").?;
    try std.testing.expect(preview == .string);
    try std.testing.expectEqual(@as(usize, stream_tool_argument_preview_bytes_max), preview.string.len);
    try std.testing.expectEqual(
        @as(i64, 10),
        copied_partial.content[1].tool_call.arguments.object.get("offset").?.integer,
    );
    try std.testing.expectEqual(
        @as(i64, 20),
        copied_partial.content[1].tool_call.arguments.object.get("limit").?.integer,
    );
}

test "compact text delta partial with real content drops to empty content" {
    const content = [_]ai.AssistantContent{.{ .text = .{ .text = "hello world" } }};
    var partial = assistantMessage("x");
    partial.content = &content;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const copied = try copyCompactAssistantMessageEvent(arena.allocator(), .{ .text_delta = .{
        .content_index = 0,
        .delta = "h",
        .partial = partial,
    } });
    try std.testing.expectEqual(@as(usize, 0), copied.text_delta.partial.content.len);
}

fn userMessage(text: []const u8) agent.AgentMessage {
    return .{ .user = .{ .content = .{ .string = text }, .timestamp = 0 } };
}

fn echoTool(
    allocator: std.mem.Allocator,
    _: std.Io,
    _: *runtime.Runtime,
    context: ?*anyopaque,
    _: runtime.CancelToken,
    _: []const u8,
    _: std.json.Value,
    _: ?agent.AgentToolUpdateCallback,
) anyerror!agent.ToolExecutionResult {
    const calls: *usize = @ptrCast(@alignCast(context.?));
    calls.* += 1;
    return toolTextResult(allocator, "echoed");
}

fn updatingTool(
    allocator: std.mem.Allocator,
    _: std.Io,
    _: *runtime.Runtime,
    context: ?*anyopaque,
    _: runtime.CancelToken,
    _: []const u8,
    _: std.json.Value,
    on_update: ?agent.AgentToolUpdateCallback,
) anyerror!agent.ToolExecutionResult {
    const calls: *usize = @ptrCast(@alignCast(context.?));
    calls.* += 1;
    if (on_update) |callback| {
        try callback.call(.{ .content = &.{.{ .text = .{ .text = "partial" } }} });
    }
    return toolTextResult(allocator, "done");
}

fn overflowingUpdatesTool(
    allocator: std.mem.Allocator,
    _: std.Io,
    _: *runtime.Runtime,
    context: ?*anyopaque,
    _: runtime.CancelToken,
    _: []const u8,
    _: std.json.Value,
    on_update: ?agent.AgentToolUpdateCallback,
) anyerror!agent.ToolExecutionResult {
    const calls: *usize = @ptrCast(@alignCast(context.?));
    calls.* += 1;
    if (on_update) |callback| {
        for (0..agent.max_tool_updates_per_batch + 1) |_| {
            try callback.call(.{ .content = &.{.{ .text = .{ .text = "partial" } }} });
        }
    }
    return toolTextResult(allocator, "unreachable");
}

fn sleepingTool(
    _: std.mem.Allocator,
    _: std.Io,
    _: *runtime.Runtime,
    context: ?*anyopaque,
    _: runtime.CancelToken,
    _: []const u8,
    _: std.json.Value,
    _: ?agent.AgentToolUpdateCallback,
) anyerror!agent.ToolExecutionResult {
    const entered: *runtime.ResetEvent = @ptrCast(@alignCast(context.?));
    entered.set();
    try runtime.sleep(.fromSeconds(60));
    return error.TestUnexpectedResult;
}

fn toolTextResult(allocator: std.mem.Allocator, text: []const u8) !agent.ToolExecutionResult {
    const content = try allocator.alloc(ai.ToolResultContent, 1);
    content[0] = .{ .text = .{ .text = try allocator.dupe(u8, text) } };
    return .{ .allocator = allocator, .result = .{ .content = content } };
}

test "run prompt emits prompt assistant and agent end events" {
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var events = std.ArrayList(agent.AgentEvent).empty;
    defer events.deinit(std.testing.allocator);
    defer deinitTestEvents(events.items);
    var cancel = try runtime.CancelSource.init(std.testing.allocator);
    defer cancel.deinit();
    const prompt = userMessage("hello");

    try runPrompt(
        std.testing.allocator,
        std.testing.io,
        &.{prompt},
        .{ .system_prompt = "", .messages = &.{}, .tools = &.{} },
        .{
            .model = testModel(),
            .stream = .{ .call_fn = testStream },
            .convert_to_llm = .{ .call_fn = testConvertToLlm },
        },
        cancel.token(),
        task_runtime,
        .{ .context = &events, .call_fn = testSink },
    );

    try std.testing.expectEqual(agent.AgentEvent.agent_start, events.items[0]);
    try std.testing.expect(events.items[events.items.len - 1] == .agent_end);
}

test "prompt stream exposes events through event pipe" {
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var cancel = try runtime.CancelSource.init(std.testing.allocator);
    defer cancel.deinit();
    const prompt = userMessage("hello");
    var buffer: [8]StreamEvent = undefined;
    var stream: AgentEventStream = undefined;

    startPromptStream(
        &stream,
        std.testing.allocator,
        task_runtime,
        &.{prompt},
        .{ .system_prompt = "", .messages = &.{}, .tools = &.{} },
        .{
            .model = testModel(),
            .stream = .{ .call_fn = testStream },
            .convert_to_llm = .{ .call_fn = testConvertToLlm },
        },
        cancel.token(),
        &buffer,
    );
    defer stream.deinit();

    var start_event = (try stream.next()).?;
    defer start_event.deinit();
    try std.testing.expectEqual(agent.AgentEvent.agent_start, start_event.event);
    while (try stream.next()) |captured| {
        var event = captured;
        event.deinit();
    }
    try stream.awaitProducer();
}

test "prompt stream drains many fast deltas through bounded pipe" {
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var cancel = try runtime.CancelSource.init(std.testing.allocator);
    defer cancel.deinit();
    const prompt = userMessage("hello");
    var buffer: [8]StreamEvent = undefined;
    var stream: AgentEventStream = undefined;

    startPromptStream(
        &stream,
        std.testing.allocator,
        task_runtime,
        &.{prompt},
        .{ .system_prompt = "", .messages = &.{}, .tools = &.{} },
        .{
            .model = testModel(),
            .stream = .{ .call_fn = fastDeltaBufferedStream },
            .convert_to_llm = .{ .call_fn = testConvertToLlm },
        },
        cancel.token(),
        &buffer,
    );
    defer stream.deinit();

    var update_count: usize = 0;
    while (try stream.next()) |captured| {
        var event = captured;
        defer event.deinit();
        if (event.event == .message_update) update_count += 1;
    }
    try stream.awaitProducer();
    try std.testing.expectEqual(@as(usize, fast_delta_stream_count), update_count);
}

test "prompt stream closes event pipe when producer fails before terminal event" {
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var cancel = try runtime.CancelSource.init(std.testing.allocator);
    defer cancel.deinit();
    const prompt = userMessage("hello");
    var buffer: [8]StreamEvent = undefined;
    var stream: AgentEventStream = undefined;

    startPromptStream(
        &stream,
        std.testing.allocator,
        task_runtime,
        &.{prompt},
        .{ .system_prompt = "", .messages = &.{}, .tools = &.{} },
        .{
            .model = testModel(),
            .stream = .{ .call_fn = emptyStream },
            .convert_to_llm = .{ .call_fn = testConvertToLlm },
        },
        cancel.token(),
        &buffer,
    );
    defer stream.deinit();

    while (try stream.next()) |captured| {
        var event = captured;
        event.deinit();
    }
    try std.testing.expectError(error.MissingAssistantResult, stream.awaitProducer());
}

test "prompt stream cancellation drains producer blocked on bounded event pipe" {
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var cancel = try runtime.CancelSource.init(std.testing.allocator);
    defer cancel.deinit();
    const prompt = userMessage("hello");
    var buffer: [1]StreamEvent = undefined;
    var stream: AgentEventStream = undefined;

    startPromptStream(
        &stream,
        std.testing.allocator,
        task_runtime,
        &.{prompt},
        .{ .system_prompt = "", .messages = &.{}, .tools = &.{} },
        .{
            .model = testModel(),
            .stream = .{ .call_fn = testStream },
            .convert_to_llm = .{ .call_fn = testConvertToLlm },
        },
        cancel.token(),
        &buffer,
    );
    defer stream.deinit();

    var start_event = (try stream.next()).?;
    defer start_event.deinit();
    try std.testing.expectEqual(agent.AgentEvent.agent_start, start_event.event);
    try std.testing.expectError(error.Canceled, stream.cancelProducer());
}

test "prompt stream cancellation while tool is running drains as canceled" {
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var cancel = try runtime.CancelSource.init(std.testing.allocator);
    defer cancel.deinit();
    const prompt = userMessage("hello");
    var stream_calls: usize = 0;
    var entered: runtime.ResetEvent = .init;
    const tool: agent.AgentTool = .{
        .name = "echo",
        .description = "Echo",
        .parameters = .{ .object = .empty },
        .label = "Echo",
        .execute = .{ .context = &entered, .call_fn = sleepingTool },
    };
    var buffer: [16]StreamEvent = undefined;
    var stream: AgentEventStream = undefined;

    startPromptStream(
        &stream,
        std.testing.allocator,
        task_runtime,
        &.{prompt},
        .{ .system_prompt = "", .messages = &.{}, .tools = &.{tool} },
        .{
            .model = testModel(),
            .stream = .{ .context = &stream_calls, .call_fn = testToolStream },
            .convert_to_llm = .{ .call_fn = testConvertToLlm },
        },
        cancel.token(),
        &buffer,
    );
    defer stream.deinit();

    try entered.wait();

    try std.testing.expectError(error.Canceled, stream.cancelProducer());
}

test "run prompt executes tool result then continues assistant turn" {
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    const io = task_runtime.io();
    var events = std.ArrayList(agent.AgentEvent).empty;
    defer events.deinit(std.testing.allocator);
    defer deinitTestEvents(events.items);
    var cancel = try runtime.CancelSource.init(std.testing.allocator);
    defer cancel.deinit();
    var stream_calls: usize = 0;
    var tool_calls: usize = 0;
    const prompt = userMessage("hello");
    const tool: agent.AgentTool = .{
        .name = "echo",
        .description = "Echo",
        .parameters = .{ .object = .empty },
        .label = "Echo",
        .execute = .{ .context = &tool_calls, .call_fn = echoTool },
    };

    try runPrompt(
        std.testing.allocator,
        io,
        &.{prompt},
        .{ .system_prompt = "", .messages = &.{}, .tools = &.{tool} },
        .{
            .model = testModel(),
            .stream = .{ .context = &stream_calls, .call_fn = testToolStream },
            .convert_to_llm = .{ .call_fn = testConvertToLlm },
        },
        cancel.token(),
        task_runtime,
        .{ .context = &events, .call_fn = testSink },
    );

    try std.testing.expectEqual(@as(usize, 2), stream_calls);
    try std.testing.expectEqual(@as(usize, 1), tool_calls);
    try std.testing.expect(events.items[events.items.len - 1] == .agent_end);
}

test "parallel tool calls emit bounded live updates through owner" {
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    const io = task_runtime.io();
    var events = std.ArrayList(agent.AgentEvent).empty;
    defer events.deinit(std.testing.allocator);
    defer deinitTestEvents(events.items);
    var cancel = try runtime.CancelSource.init(std.testing.allocator);
    defer cancel.deinit();
    var stream_calls: usize = 0;
    var tool_calls: usize = 0;
    const prompt = userMessage("hello");
    const tool: agent.AgentTool = .{
        .name = "echo",
        .description = "Echo",
        .parameters = .{ .object = .empty },
        .label = "Echo",
        .execute = .{ .context = &tool_calls, .call_fn = updatingTool },
    };

    try runPrompt(
        std.testing.allocator,
        io,
        &.{prompt},
        .{ .system_prompt = "", .messages = &.{}, .tools = &.{tool} },
        .{
            .model = testModel(),
            .stream = .{ .context = &stream_calls, .call_fn = testToolStream },
            .convert_to_llm = .{ .call_fn = testConvertToLlm },
            .tool_execution = .parallel,
        },
        cancel.token(),
        task_runtime,
        .{ .context = &events, .call_fn = testSink },
    );

    var update_count: usize = 0;
    for (events.items) |event| {
        if (event == .tool_execution_update) update_count += 1;
    }

    try std.testing.expectEqual(@as(usize, 1), tool_calls);
    try std.testing.expectEqual(@as(usize, 1), update_count);
}

test "parallel tool calls cancel and drain workers when owner update drain fails" {
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    const io = task_runtime.io();
    var events = std.ArrayList(agent.AgentEvent).empty;
    defer events.deinit(std.testing.allocator);
    defer deinitTestEvents(events.items);
    var cancel = try runtime.CancelSource.init(std.testing.allocator);
    defer cancel.deinit();
    var stream_calls: usize = 0;
    var tool_calls: usize = 0;
    const prompt = userMessage("hello");
    const tool: agent.AgentTool = .{
        .name = "echo",
        .description = "Echo",
        .parameters = .{ .object = .empty },
        .label = "Echo",
        .execute = .{ .context = &tool_calls, .call_fn = updatingTool },
    };

    try std.testing.expectError(error.TestSinkFailed, runPrompt(
        std.testing.allocator,
        io,
        &.{prompt},
        .{ .system_prompt = "", .messages = &.{}, .tools = &.{tool} },
        .{
            .model = testModel(),
            .stream = .{ .context = &stream_calls, .call_fn = testToolStream },
            .convert_to_llm = .{ .call_fn = testConvertToLlm },
            .tool_execution = .parallel,
        },
        cancel.token(),
        task_runtime,
        .{ .context = &events, .call_fn = failOnToolUpdateSink },
    ));

    try std.testing.expectEqual(@as(usize, 1), tool_calls);
}

test "parallel tool calls bound live updates before completing worker result" {
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    const io = task_runtime.io();
    var events = std.ArrayList(agent.AgentEvent).empty;
    defer events.deinit(std.testing.allocator);
    defer deinitTestEvents(events.items);
    var cancel = try runtime.CancelSource.init(std.testing.allocator);
    defer cancel.deinit();
    var stream_calls: usize = 0;
    var tool_calls: usize = 0;
    const prompt = userMessage("hello");
    const tool: agent.AgentTool = .{
        .name = "echo",
        .description = "Echo",
        .parameters = .{ .object = .empty },
        .label = "Echo",
        .execute = .{ .context = &tool_calls, .call_fn = overflowingUpdatesTool },
    };

    try runPrompt(
        std.testing.allocator,
        io,
        &.{prompt},
        .{ .system_prompt = "", .messages = &.{}, .tools = &.{tool} },
        .{
            .model = testModel(),
            .stream = .{ .context = &stream_calls, .call_fn = testToolStream },
            .convert_to_llm = .{ .call_fn = testConvertToLlm },
            .tool_execution = .parallel,
        },
        cancel.token(),
        task_runtime,
        .{ .context = &events, .call_fn = testSink },
    );

    var update_count: usize = 0;
    var end_count: usize = 0;
    var saw_bound_error = false;
    for (events.items) |event| switch (event) {
        .tool_execution_update => update_count += 1,
        .tool_execution_end => |end| {
            end_count += 1;
            saw_bound_error = end.is_error;
        },
        else => {},
    };

    try std.testing.expectEqual(@as(usize, 1), tool_calls);
    try std.testing.expectEqual(@as(usize, agent.max_tool_updates_per_batch), update_count);
    try std.testing.expectEqual(@as(usize, 1), end_count);
    try std.testing.expect(saw_bound_error);
}

test "parallel tool calls finalize results in assistant source order" {
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    const io = task_runtime.io();
    var events = std.ArrayList(agent.AgentEvent).empty;
    defer events.deinit(std.testing.allocator);
    defer deinitTestEvents(events.items);
    var cancel = try runtime.CancelSource.init(std.testing.allocator);
    defer cancel.deinit();
    var stream_calls: usize = 0;
    var tool_calls: usize = 0;
    const prompt = userMessage("hello");
    const tool: agent.AgentTool = .{
        .name = "echo",
        .description = "Echo",
        .parameters = .{ .object = .empty },
        .label = "Echo",
        .execute = .{ .context = &tool_calls, .call_fn = echoTool },
    };

    try runPrompt(
        std.testing.allocator,
        io,
        &.{prompt},
        .{ .system_prompt = "", .messages = &.{}, .tools = &.{tool} },
        .{
            .model = testModel(),
            .stream = .{ .context = &stream_calls, .call_fn = testTwoToolStream },
            .convert_to_llm = .{ .call_fn = testConvertToLlm },
            .tool_execution = .parallel,
        },
        cancel.token(),
        task_runtime,
        .{ .context = &events, .call_fn = testSink },
    );

    var tool_result_count: usize = 0;
    for (events.items) |event| {
        if (event == .message_end and event.message_end.message == .tool_result) {
            const message = event.message_end.message.tool_result;
            if (tool_result_count == 0) try std.testing.expectEqualStrings("tool-1", message.tool_call_id);
            if (tool_result_count == 1) try std.testing.expectEqualStrings("tool-2", message.tool_call_id);
            tool_result_count += 1;
        }
    }

    try std.testing.expectEqual(@as(usize, 2), tool_calls);
    try std.testing.expectEqual(@as(usize, 2), tool_result_count);
}

test "run continue rejects assistant tail" {
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var events = std.ArrayList(agent.AgentEvent).empty;
    defer events.deinit(std.testing.allocator);
    defer deinitTestEvents(events.items);
    var cancel = try runtime.CancelSource.init(std.testing.allocator);
    defer cancel.deinit();
    const assistant: agent.AgentMessage = .{ .assistant = assistantMessage("done") };

    try std.testing.expectError(error.CannotContinueFromAssistant, runContinue(
        std.testing.allocator,
        std.Io.failing,
        .{ .system_prompt = "", .messages = &.{assistant}, .tools = &.{} },
        .{
            .model = testModel(),
            .stream = .{ .call_fn = testStream },
            .convert_to_llm = .{ .call_fn = testConvertToLlm },
        },
        cancel.token(),
        task_runtime,
        .{ .context = &events, .call_fn = testSink },
    ));
}

fn testModel() ai.Model {
    return .{
        .id = "test-model",
        .name = "Test Model",
        .api = ai.KnownApi.openai_responses,
        .provider = ai.KnownProvider.openai,
        .base_url = "https://example.test",
        .reasoning = false,
        .input = &.{.text},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 1,
        .max_tokens = 1,
    };
}

test "run prompt emits one tool result message_end per executed tool" {
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    const io = task_runtime.io();
    var events = std.ArrayList(agent.AgentEvent).empty;
    defer events.deinit(std.testing.allocator);
    defer deinitTestEvents(events.items);
    var cancel = try runtime.CancelSource.init(std.testing.allocator);
    defer cancel.deinit();

    var stream_calls: usize = 0;
    var tool_calls: usize = 0;
    const prompt = userMessage("hello");
    const tool: agent.AgentTool = .{
        .name = "echo",
        .description = "Echo",
        .parameters = .{ .object = .empty },
        .label = "Echo",
        .execute = .{ .context = &tool_calls, .call_fn = echoTool },
        .execution_mode = .sequential,
    };

    try runPrompt(
        std.testing.allocator,
        io,
        &.{prompt},
        .{ .system_prompt = "", .messages = &.{}, .tools = &.{tool} },
        .{
            .model = testModel(),
            .stream = .{ .context = &stream_calls, .call_fn = testToolStream },
            .convert_to_llm = .{ .call_fn = testConvertToLlm },
            .tool_execution = .sequential,
        },
        cancel.token(),
        task_runtime,
        .{ .context = &events, .call_fn = testSink },
    );

    var tool_start_count: usize = 0;
    var tool_end_count: usize = 0;
    var tool_result_start_count: usize = 0;
    var tool_result_end_count: usize = 0;
    for (events.items) |event| switch (event) {
        .tool_execution_start => tool_start_count += 1,
        .tool_execution_end => tool_end_count += 1,
        .message_start => |payload| {
            if (payload.message == .tool_result) tool_result_start_count += 1;
        },
        .message_end => |payload| {
            if (payload.message == .tool_result) tool_result_end_count += 1;
        },
        else => {},
    };

    try std.testing.expectEqual(@as(usize, 1), tool_calls);
    try std.testing.expectEqual(@as(usize, 1), tool_start_count);
    try std.testing.expectEqual(@as(usize, 1), tool_end_count);
    try std.testing.expectEqual(@as(usize, 0), tool_result_start_count);
    try std.testing.expectEqual(@as(usize, 1), tool_result_end_count);
}
