const std = @import("std");
const agent = @import("root.zig");
const ai = @import("../ai/root.zig");
const runtime = @import("../runtime/root.zig");

pub const EventSink = struct {
    context: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, agent.AgentEvent) anyerror!void,

    pub fn emit(self: EventSink, event: agent.AgentEvent) anyerror!void {
        return self.call_fn(self.context, event);
    }
};

const AgentEventPipe = runtime.EventPipe(agent.AgentEvent, []const agent.AgentMessage);
pub const AgentEventStreamNextError = AgentEventPipe.NextError;
pub const AgentEventStreamEmitError = AgentEventPipe.EmitError;

pub const AgentEventStream = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    pipe: AgentEventPipe,
    future: ?std.Io.Future(anyerror!void) = null,
    terminal_messages: ?[]const agent.AgentMessage = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, buffer: []agent.AgentEvent) AgentEventStream {
        return .{ .allocator = allocator, .io = io, .pipe = AgentEventPipe.init(buffer) };
    }

    pub fn deinit(self: *AgentEventStream) void {
        std.debug.assert(self.future == null);
        if (self.terminal_messages) |messages| self.allocator.free(messages);
        self.* = undefined;
    }

    pub fn next(self: *AgentEventStream, io: std.Io) AgentEventStreamNextError!?agent.AgentEvent {
        return self.pipe.stream().next(io);
    }

    pub fn result(self: *AgentEventStream) ?[]const agent.AgentMessage {
        return self.pipe.stream().result();
    }

    pub fn awaitProducer(self: *AgentEventStream) anyerror!void {
        if (self.future) |*future| {
            defer self.future = null;
            try future.await(self.io);
        }
    }

    pub fn cancelProducer(self: *AgentEventStream) anyerror!void {
        if (self.future) |*future| {
            defer self.future = null;
            try future.cancel(self.io);
        }
    }
};

pub fn startPromptStream(
    stream: *AgentEventStream,
    allocator: std.mem.Allocator,
    io: std.Io,
    prompts: []const agent.AgentMessage,
    context: agent.AgentContext,
    config: agent.AgentLoopConfig,
    token: runtime.CancelToken,
    buffer: []agent.AgentEvent,
) void {
    stream.* = AgentEventStream.init(allocator, io, buffer);
    stream.future = io.async(runPromptStreamProducer, .{ allocator, io, prompts, context, config, token, stream });
}

pub fn startContinueStream(
    stream: *AgentEventStream,
    allocator: std.mem.Allocator,
    io: std.Io,
    context: agent.AgentContext,
    config: agent.AgentLoopConfig,
    token: runtime.CancelToken,
    buffer: []agent.AgentEvent,
) void {
    stream.* = AgentEventStream.init(allocator, io, buffer);
    stream.future = io.async(runContinueStreamProducer, .{ allocator, io, context, config, token, stream });
}

fn runPromptStreamProducer(
    allocator: std.mem.Allocator,
    io: std.Io,
    prompts: []const agent.AgentMessage,
    context: agent.AgentContext,
    config: agent.AgentLoopConfig,
    token: runtime.CancelToken,
    stream: *AgentEventStream,
) anyerror!void {
    try runPrompt(allocator, io, prompts, context, config, token, streamSink(stream));
}

fn runContinueStreamProducer(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: agent.AgentContext,
    config: agent.AgentLoopConfig,
    token: runtime.CancelToken,
    stream: *AgentEventStream,
) anyerror!void {
    try runContinue(allocator, io, context, config, token, streamSink(stream));
}

pub const Error = error{
    NoMessages,
    CannotContinueFromAssistant,
    TooManyTools,
    MissingAssistantResult,
};

fn streamSink(stream: *AgentEventStream) EventSink {
    return .{ .context = stream, .call_fn = streamSinkEmit };
}

fn streamSinkEmit(context: ?*anyopaque, event: agent.AgentEvent) anyerror!void {
    const stream: *AgentEventStream = @ptrCast(@alignCast(context.?));
    switch (event) {
        .agent_end => |end| {
            const messages = try stream.allocator.dupe(agent.AgentMessage, end.messages);
            stream.terminal_messages = messages;
            try stream.pipe.sink().end(stream.io, .{ .agent_end = .{ .messages = messages } }, messages);
        },
        else => try stream.pipe.sink().emit(stream.io, event),
    }
}

pub fn runPrompt(
    allocator: std.mem.Allocator,
    io: std.Io,
    prompts: []const agent.AgentMessage,
    context: agent.AgentContext,
    config: agent.AgentLoopConfig,
    token: runtime.CancelToken,
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

    try runLoop(allocator, io, &current, config, token, emit);
}

pub fn runContinue(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: agent.AgentContext,
    config: agent.AgentLoopConfig,
    token: runtime.CancelToken,
    emit: EventSink,
) !void {
    if (context.messages.len == 0) return error.NoMessages;
    if (context.messages[context.messages.len - 1] == .assistant) return error.CannotContinueFromAssistant;

    var current = try Context.init(allocator, context);
    defer current.deinit();

    try emit.emit(.agent_start);
    try emit.emit(.turn_start);
    try runLoop(allocator, io, &current, config, token, emit);
}

fn runLoop(
    allocator: std.mem.Allocator,
    io: std.Io,
    current: *Context,
    config: agent.AgentLoopConfig,
    token: runtime.CancelToken,
    emit: EventSink,
) !void {
    var first_turn = true;
    var pending_messages = try drainMessages(allocator, config.get_steering_messages);
    defer allocator.free(pending_messages);

    while (true) {
        var has_more_tool_calls = true;
        while (has_more_tool_calls or pending_messages.len > 0) {
            if (token.isRequested()) {
                const aborted = terminalAssistantMessage(config.model, .aborted, "aborted");
                try emit.emit(.{ .message_start = .{ .message = .{ .assistant = aborted } } });
                try emit.emit(.{ .message_end = .{ .message = .{ .assistant = aborted } } });
                try current.messages.append(allocator, .{ .assistant = aborted });
                try emit.emit(.{ .turn_end = .{ .message = .{ .assistant = aborted }, .tool_results = &.{} } });
                try emit.emit(.{ .agent_end = .{ .messages = current.messages.items } });
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

            const assistant = try streamAssistantResponse(allocator, io, current, config, token, emit);
            try current.messages.append(allocator, .{ .assistant = assistant });

            if (assistant.stop_reason == .error_ or assistant.stop_reason == .aborted) {
                try emit.emit(.{ .turn_end = .{ .message = .{ .assistant = assistant }, .tool_results = &.{} } });
                try emit.emit(.{ .agent_end = .{ .messages = current.messages.items } });
                return;
            }

            const tool_results = if (shouldExecuteToolsSequential(current.tools, assistant, config.tool_execution))
                try executeToolCallsSequential(allocator, io, current, assistant, config, token, emit)
            else
                try executeToolCallsParallel(allocator, io, current, assistant, config, token, emit);
            defer allocator.free(tool_results.messages);
            for (tool_results.messages) |message| {
                try current.messages.append(allocator, .{ .tool_result = message });
            }

            try emit.emit(.{ .turn_end = .{
                .message = .{ .assistant = assistant },
                .tool_results = tool_results.messages,
            } });

            has_more_tool_calls = tool_results.messages.len > 0 and !tool_results.terminate;
            allocator.free(pending_messages);
            pending_messages = try drainMessages(allocator, config.get_steering_messages);
        }

        allocator.free(pending_messages);
        pending_messages = try drainMessages(allocator, config.get_follow_up_messages);
        if (pending_messages.len == 0) break;
    }

    try emit.emit(.{ .agent_end = .{ .messages = current.messages.items } });
}

fn drainMessages(
    allocator: std.mem.Allocator,
    hook: ?agent.GetMessagesHook,
) std.mem.Allocator.Error![]const agent.AgentMessage {
    if (hook) |get_messages| return agent.GetMessagesHook.call(allocator, get_messages);
    return allocator.alloc(agent.AgentMessage, 0);
}

fn emitPendingMessages(
    allocator: std.mem.Allocator,
    current: *Context,
    messages: []const agent.AgentMessage,
    emit: EventSink,
) !void {
    for (messages) |message| {
        try emit.emit(.{ .message_start = .{ .message = message } });
        try emit.emit(.{ .message_end = .{ .message = message } });
        try current.messages.append(allocator, message);
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
    const agent_messages = if (config.transform_context) |hook|
        try agent.TransformContextHook.call(allocator, hook, token, current.messages.items)
    else
        current.messages.items;

    const llm_messages = try agent.ConvertToLlmHook.call(allocator, config.convert_to_llm, agent_messages);
    defer allocator.free(llm_messages);
    var tools = std.ArrayList(ai.Tool).empty;
    defer tools.deinit(allocator);
    for (current.tools) |tool| try tools.append(allocator, tool.asTool());

    var stream_options = config.options.stream;
    if (config.get_api_key) |get_api_key| {
        if (try agent.GetApiKeyHook.call(allocator, get_api_key, config.model.provider)) |api_key| {
            stream_options.api_key = api_key;
        }
    }

    var event_buffer: [64]ai.AssistantMessageEvent = undefined;
    var stream = config.stream.call(.{
        .allocator = allocator,
        .io = io,
        .model = config.model,
        .context = .{
            .system_prompt = current.system_prompt,
            .messages = llm_messages,
            .tools = tools.items,
        },
        .options = stream_options,
        .cancel_token = token,
        .event_buffer = &event_buffer,
    });

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
                .message = .{ .assistant = assistantEventPartial(event) },
                .assistant_message_event = event,
            } }),
            .done => |done| {
                if (!added_partial) {
                    try emit.emit(.{ .message_start = .{ .message = .{ .assistant = done.message } } });
                }
                try emit.emit(.{ .message_end = .{ .message = .{ .assistant = done.message } } });
                return done.message;
            },
            .@"error" => |err| {
                if (!added_partial) {
                    try emit.emit(.{ .message_start = .{ .message = .{ .assistant = err.@"error" } } });
                }
                try emit.emit(.{ .message_end = .{ .message = .{ .assistant = err.@"error" } } });
                return err.@"error";
            },
        }
    }

    const result = stream.result() orelse return error.MissingAssistantResult;
    if (!added_partial) try emit.emit(.{ .message_start = .{ .message = .{ .assistant = result } } });
    try emit.emit(.{ .message_end = .{ .message = .{ .assistant = result } } });
    return result;
}

const ToolBatch = struct {
    messages: []const ai.ToolResultMessage,
    terminate: bool,
};

fn shouldExecuteToolsSequential(
    tools: []const agent.AgentTool,
    assistant: ai.AssistantMessage,
    mode: agent.ToolExecutionMode,
) bool {
    if (mode == .sequential) return true;
    for (assistant.content) |content| {
        const tool_call = switch (content) {
            .tool_call => |value| value,
            else => continue,
        };
        const tool = findTool(tools, tool_call.name) orelse continue;
        if (tool.execution_mode == .sequential) return true;
    }
    return false;
}

fn executeToolCallsSequential(
    allocator: std.mem.Allocator,
    io: std.Io,
    current: *Context,
    assistant: ai.AssistantMessage,
    config: agent.AgentLoopConfig,
    token: runtime.CancelToken,
    emit: EventSink,
) !ToolBatch {
    var messages = std.ArrayList(ai.ToolResultMessage).empty;
    errdefer messages.deinit(allocator);
    var finalized_count: usize = 0;
    var terminate_count: usize = 0;

    for (assistant.content) |content| {
        if (content != .tool_call) continue;
        if (token.isRequested()) break;
        const tool_call = content.tool_call;
        try emit.emit(.{ .tool_execution_start = .{
            .tool_call_id = tool_call.id,
            .tool_name = tool_call.name,
            .args = tool_call.arguments,
        } });

        const finalized = try executeOneToolCall(allocator, io, current, assistant, tool_call, config, token, emit);
        finalized_count += 1;
        if (finalized.result.terminate) terminate_count += 1;

        try emit.emit(.{ .tool_execution_end = .{
            .tool_call_id = tool_call.id,
            .tool_name = tool_call.name,
            .result = finalized.result,
            .is_error = finalized.is_error,
        } });

        const message = createToolResultMessage(tool_call, finalized.result, finalized.is_error);
        try emit.emit(.{ .message_start = .{ .message = .{ .tool_result = message } } });
        try emit.emit(.{ .message_end = .{ .message = .{ .tool_result = message } } });
        try messages.append(allocator, message);
    }

    return .{
        .messages = try messages.toOwnedSlice(allocator),
        .terminate = finalized_count > 0 and terminate_count == finalized_count,
    };
}

const ExecutablePreparedToolCall = struct {
    index: usize,
    tool: agent.AgentTool,
    tool_call: ai.ToolCall,
    args: std.json.Value,
};

const FailedPreparedToolCall = struct {
    index: usize,
    tool_call: ai.ToolCall,
    reason: []const u8,
};

const PreparedToolCall = union(enum) {
    executable: ExecutablePreparedToolCall,
    missing: FailedPreparedToolCall,
    prepare_error: FailedPreparedToolCall,
    blocked: FailedPreparedToolCall,

    fn index(self: PreparedToolCall) usize {
        return switch (self) {
            .executable => |item| item.index,
            .missing, .prepare_error, .blocked => |item| item.index,
        };
    }

    fn toolCall(self: PreparedToolCall) ai.ToolCall {
        return switch (self) {
            .executable => |item| item.tool_call,
            .missing, .prepare_error, .blocked => |item| item.tool_call,
        };
    }

    fn args(self: PreparedToolCall) std.json.Value {
        return switch (self) {
            .executable => |item| item.args,
            .missing => |item| item.tool_call.arguments,
            .prepare_error, .blocked => |item| .{ .string = item.reason },
        };
    }
};

const ExecutedToolCall = struct {
    prepared: PreparedToolCall,
    result: agent.AgentToolResult,
    is_error: bool,
};

const FinalizedToolCall = struct {
    result: agent.AgentToolResult,
    is_error: bool,
};

const ToolWorkerEvent = union(enum) {
    update: ToolUpdate,
    complete: ExecutedToolCall,

    const ToolUpdate = struct {
        tool_call_id: []const u8,
        tool_name: []const u8,
        args: std.json.Value,
        partial_result: agent.AgentToolResult,
    };
};

const ToolWorkerQueue = std.Io.Queue(ToolWorkerEvent);

const ParallelToolUpdateContext = struct {
    io: std.Io,
    queue: *ToolWorkerQueue,
    tool_call: ai.ToolCall,
    args: std.json.Value,
    update_count: *std.atomic.Value(usize),
};

fn executeToolCallsParallel(
    allocator: std.mem.Allocator,
    io: std.Io,
    current: *Context,
    assistant: ai.AssistantMessage,
    config: agent.AgentLoopConfig,
    token: runtime.CancelToken,
    emit: EventSink,
) !ToolBatch {
    var prepared: [agent.max_tool_calls_per_turn]PreparedToolCall = undefined;
    const prepared_count = try prepareParallelToolCalls(allocator, current, assistant, config, token, emit, &prepared);

    var queue_buffer: [agent.max_tool_calls_per_turn + agent.max_tool_updates_per_batch]ToolWorkerEvent = undefined;
    var queue = ToolWorkerQueue.init(&queue_buffer);
    var update_count: std.atomic.Value(usize) = .init(0);
    var futures: [agent.max_tool_calls_per_turn]std.Io.Future(anyerror!void) = undefined;

    for (prepared[0..prepared_count], 0..) |item, index| {
        futures[index] = io.async(
            executePreparedToolCallWorker,
            .{ allocator, io, item, token, &queue, &update_count },
        );
    }

    var executed: [agent.max_tool_calls_per_turn]ExecutedToolCall = undefined;
    var completed_count: usize = 0;
    while (completed_count < prepared_count) {
        const event = try queue.getOne(io);
        switch (event) {
            .update => |update| try emit.emit(.{ .tool_execution_update = .{
                .tool_call_id = update.tool_call_id,
                .tool_name = update.tool_name,
                .args = update.args,
                .partial_result = update.partial_result,
            } }),
            .complete => |complete| {
                executed[complete.prepared.index()] = complete;
                completed_count += 1;
            },
        }
    }

    for (futures[0..prepared_count]) |*future| try future.await(io);

    var messages = std.ArrayList(ai.ToolResultMessage).empty;
    errdefer messages.deinit(allocator);
    var terminate_count: usize = 0;

    for (executed[0..prepared_count]) |item| {
        const finalized = try finalizeExecutedToolCall(allocator, current, assistant, config, token, item);
        if (finalized.result.terminate) terminate_count += 1;
        try emitFinalizedToolCall(allocator, emit, item.prepared.toolCall(), finalized, &messages);
    }

    return .{
        .messages = try messages.toOwnedSlice(allocator),
        .terminate = prepared_count > 0 and terminate_count == prepared_count,
    };
}

fn prepareParallelToolCalls(
    allocator: std.mem.Allocator,
    current: *Context,
    assistant: ai.AssistantMessage,
    config: agent.AgentLoopConfig,
    token: runtime.CancelToken,
    emit: EventSink,
    out: *[agent.max_tool_calls_per_turn]PreparedToolCall,
) !usize {
    var prepared_count: usize = 0;
    for (assistant.content) |content| {
        const tool_call = switch (content) {
            .tool_call => |value| value,
            else => continue,
        };
        if (token.isRequested()) break;
        if (prepared_count == out.len) return error.TooManyTools;

        out[prepared_count] = prepareToolCall(allocator, current, assistant, tool_call, config, token, prepared_count);
        const item = out[prepared_count];
        const started_tool_call = item.toolCall();
        try emit.emit(.{ .tool_execution_start = .{
            .tool_call_id = started_tool_call.id,
            .tool_name = started_tool_call.name,
            .args = item.args(),
        } });
        prepared_count += 1;
    }
    return prepared_count;
}

fn executePreparedToolCallWorker(
    allocator: std.mem.Allocator,
    io: std.Io,
    prepared: PreparedToolCall,
    token: runtime.CancelToken,
    queue: *ToolWorkerQueue,
    update_count: *std.atomic.Value(usize),
) anyerror!void {
    const executed = try executePreparedToolCall(allocator, io, prepared, token, queue, update_count);
    try queue.putOne(io, .{ .complete = executed });
}

fn prepareToolCall(
    allocator: std.mem.Allocator,
    current: *Context,
    assistant: ai.AssistantMessage,
    tool_call: ai.ToolCall,
    config: agent.AgentLoopConfig,
    token: runtime.CancelToken,
    index: usize,
) PreparedToolCall {
    const tool = findTool(current.tools, tool_call.name) orelse return .{ .missing = .{
        .index = index,
        .tool_call = tool_call,
        .reason = tool_call.name,
    } };

    const args = if (tool.prepare_arguments) |prepare|
        agent.PrepareArgumentsHook.call(allocator, prepare, tool_call.arguments) catch |err| return .{
            .prepare_error = .{
                .index = index,
                .tool_call = tool_call,
                .reason = @errorName(err),
            },
        }
    else
        tool_call.arguments;

    // TODO: Validate args against tool.parameters before tool execution.
    if (config.before_tool_call) |before| {
        const before_result = before.call(token, .{
            .assistant_message = assistant,
            .tool_call = tool_call,
            .args = args,
            .agent = .{
                .system_prompt = current.system_prompt,
                .messages = current.messages.items,
                .tools = current.tools,
            },
        });
        if (before_result == .block) return .{ .blocked = .{
            .index = index,
            .tool_call = tool_call,
            .reason = before_result.block,
        } };
    }

    return .{ .executable = .{ .index = index, .tool = tool, .tool_call = tool_call, .args = args } };
}

fn executePreparedToolCall(
    allocator: std.mem.Allocator,
    io: std.Io,
    prepared: PreparedToolCall,
    token: runtime.CancelToken,
    queue: *ToolWorkerQueue,
    update_count: *std.atomic.Value(usize),
) anyerror!ExecutedToolCall {
    switch (prepared) {
        .missing => |item| return .{
            .prepared = prepared,
            .result = try createErrorToolResultFmt(allocator, "Tool {s} not found", .{item.reason}),
            .is_error = true,
        },
        .prepare_error => |item| return .{
            .prepared = prepared,
            .result = try createErrorToolResultFmt(allocator, "prepare arguments failed: {s}", .{item.reason}),
            .is_error = true,
        },
        .blocked => |item| return .{
            .prepared = prepared,
            .result = try createErrorToolResult(allocator, item.reason),
            .is_error = true,
        },
        .executable => |item| {
            var update_context: ParallelToolUpdateContext = .{
                .io = io,
                .queue = queue,
                .tool_call = item.tool_call,
                .args = item.args,
                .update_count = update_count,
            };
            const update_callback: agent.AgentToolUpdateCallback = .{
                .context = &update_context,
                .call_fn = enqueueToolUpdate,
            };
            const result = agent.ExecuteToolHook.call(
                allocator,
                io,
                item.tool.execute,
                token,
                item.tool_call.id,
                item.args,
                update_callback,
            ) catch |err| return .{
                .prepared = prepared,
                .result = try createErrorToolResultFmt(allocator, "tool execution failed: {s}", .{@errorName(err)}),
                .is_error = true,
            };
            return .{ .prepared = prepared, .result = result, .is_error = false };
        },
    }
}

fn finalizeExecutedToolCall(
    allocator: std.mem.Allocator,
    current: *Context,
    assistant: ai.AssistantMessage,
    config: agent.AgentLoopConfig,
    token: runtime.CancelToken,
    executed: ExecutedToolCall,
) !FinalizedToolCall {
    var result = executed.result;
    var is_error = executed.is_error;
    if (executed.prepared == .executable) {
        if (config.after_tool_call) |after| {
            const prepared = executed.prepared.executable;
            const override = after.call(token, .{
                .assistant_message = assistant,
                .tool_call = prepared.tool_call,
                .args = prepared.args,
                .result = result,
                .is_error = is_error,
                .agent = .{
                    .system_prompt = current.system_prompt,
                    .messages = current.messages.items,
                    .tools = current.tools,
                },
            }) catch |err| return .{
                .result = try createErrorToolResultFmt(allocator, "after tool call failed: {s}", .{@errorName(err)}),
                .is_error = true,
            };
            if (override) |value| {
                if (value.content) |content| result.content = content;
                if (value.details) |details| result.details = details;
                if (value.terminate) |terminate| result.terminate = terminate;
                if (value.is_error) |override_is_error| is_error = override_is_error;
            }
        }
    }
    return .{ .result = result, .is_error = is_error };
}

fn emitFinalizedToolCall(
    allocator: std.mem.Allocator,
    emit: EventSink,
    tool_call: ai.ToolCall,
    finalized: FinalizedToolCall,
    messages: *std.ArrayList(ai.ToolResultMessage),
) !void {
    try emit.emit(.{ .tool_execution_end = .{
        .tool_call_id = tool_call.id,
        .tool_name = tool_call.name,
        .result = finalized.result,
        .is_error = finalized.is_error,
    } });

    const message = createToolResultMessage(tool_call, finalized.result, finalized.is_error);
    try emit.emit(.{ .message_start = .{ .message = .{ .tool_result = message } } });
    try emit.emit(.{ .message_end = .{ .message = .{ .tool_result = message } } });
    try messages.append(allocator, message);
}

fn executeOneToolCall(
    allocator: std.mem.Allocator,
    io: std.Io,
    current: *Context,
    assistant: ai.AssistantMessage,
    tool_call: ai.ToolCall,
    config: agent.AgentLoopConfig,
    token: runtime.CancelToken,
    emit: EventSink,
) !FinalizedToolCall {
    const tool = findTool(current.tools, tool_call.name) orelse return .{
        .result = try createErrorToolResultFmt(allocator, "Tool {s} not found", .{tool_call.name}),
        .is_error = true,
    };

    const args = if (tool.prepare_arguments) |prepare|
        agent.PrepareArgumentsHook.call(allocator, prepare, tool_call.arguments) catch |err| return .{
            .result = try createErrorToolResultFmt(allocator, "prepare arguments failed: {s}", .{@errorName(err)}),
            .is_error = true,
        }
    else
        tool_call.arguments;

    if (config.before_tool_call) |before| {
        const before_result = before.call(token, .{
            .assistant_message = assistant,
            .tool_call = tool_call,
            .args = args,
            .agent = .{
                .system_prompt = current.system_prompt,
                .messages = current.messages.items,
                .tools = current.tools,
            },
        });
        switch (before_result) {
            .allow => {},
            .block => |reason| return .{
                .result = try createErrorToolResult(allocator, reason),
                .is_error = true,
            },
        }
    }

    var update_context: ToolUpdateContext = .{
        .emit = emit,
        .tool_call = tool_call,
        .args = args,
    };
    const update_callback: agent.AgentToolUpdateCallback = .{
        .context = &update_context,
        .call_fn = emitToolUpdate,
    };
    var result = agent.ExecuteToolHook.call(
        allocator,
        io,
        tool.execute,
        token,
        tool_call.id,
        args,
        update_callback,
    ) catch |err| return .{
        .result = try createErrorToolResultFmt(allocator, "tool execution failed: {s}", .{@errorName(err)}),
        .is_error = true,
    };
    var is_error = false;

    if (config.after_tool_call) |after| {
        const override = after.call(token, .{
            .assistant_message = assistant,
            .tool_call = tool_call,
            .args = args,
            .result = result,
            .is_error = is_error,
            .agent = .{
                .system_prompt = current.system_prompt,
                .messages = current.messages.items,
                .tools = current.tools,
            },
        }) catch |err| return .{
            .result = try createErrorToolResultFmt(allocator, "after tool call failed: {s}", .{@errorName(err)}),
            .is_error = true,
        };
        if (override) |value| {
            if (value.content) |content| result.content = content;
            if (value.details) |details| result.details = details;
            if (value.terminate) |terminate| result.terminate = terminate;
            if (value.is_error) |override_is_error| is_error = override_is_error;
        }
    }

    return .{ .result = result, .is_error = is_error };
}

const ToolUpdateContext = struct {
    emit: EventSink,
    tool_call: ai.ToolCall,
    args: std.json.Value,
};

fn enqueueToolUpdate(context: ?*anyopaque, partial_result: agent.AgentToolResult) anyerror!void {
    const update: *ParallelToolUpdateContext = @ptrCast(@alignCast(context.?));
    const previous_count = update.update_count.fetchAdd(1, .monotonic);
    if (previous_count >= agent.max_tool_updates_per_batch) return error.TooManyTools;
    try update.queue.putOne(update.io, .{ .update = .{
        .tool_call_id = update.tool_call.id,
        .tool_name = update.tool_call.name,
        .args = update.args,
        .partial_result = partial_result,
    } });
}

fn emitToolUpdate(context: ?*anyopaque, partial_result: agent.AgentToolResult) anyerror!void {
    const update: *ToolUpdateContext = @ptrCast(@alignCast(context.?));
    try update.emit.emit(.{ .tool_execution_update = .{
        .tool_call_id = update.tool_call.id,
        .tool_name = update.tool_call.name,
        .args = update.args,
        .partial_result = partial_result,
    } });
}

fn findTool(tools: []const agent.AgentTool, name: []const u8) ?agent.AgentTool {
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return tool;
    }
    return null;
}

fn createToolResultMessage(
    tool_call: ai.ToolCall,
    result: agent.AgentToolResult,
    is_error: bool,
) ai.ToolResultMessage {
    return .{
        .tool_call_id = tool_call.id,
        .tool_name = tool_call.name,
        .content = result.content,
        .details = result.details,
        .is_error = is_error,
        .timestamp = 0,
    };
}

fn createErrorToolResult(allocator: std.mem.Allocator, message: []const u8) !agent.AgentToolResult {
    const content = try allocator.alloc(ai.ToolResultContent, 1);
    content[0] = .{ .text = .{ .text = try allocator.dupe(u8, message) } };
    return .{ .content = content, .details = .{ .object = .empty } };
}

fn createErrorToolResultFmt(
    allocator: std.mem.Allocator,
    comptime fmt: []const u8,
    args: anytype,
) !agent.AgentToolResult {
    const message = try std.fmt.allocPrint(allocator, fmt, args);
    return createErrorToolResult(allocator, message);
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

fn assistantEventPartial(event: ai.AssistantMessageEvent) ai.AssistantMessage {
    return switch (event) {
        .start => |payload| payload.partial,
        .text_start => |payload| payload.partial,
        .text_delta => |payload| payload.partial,
        .text_end => |payload| payload.partial,
        .thinking_start => |payload| payload.partial,
        .thinking_delta => |payload| payload.partial,
        .thinking_end => |payload| payload.partial,
        .toolcall_start => |payload| payload.partial,
        .toolcall_delta => |payload| payload.partial,
        .toolcall_end => |payload| payload.partial,
        .done => |payload| payload.message,
        .@"error" => |payload| payload.@"error",
    };
}

const Context = struct {
    allocator: std.mem.Allocator,
    system_prompt: []const u8,
    messages: std.ArrayList(agent.AgentMessage),
    tools: []const agent.AgentTool,

    fn init(allocator: std.mem.Allocator, source: agent.AgentContext) !Context {
        var messages = std.ArrayList(agent.AgentMessage).empty;
        errdefer messages.deinit(allocator);
        try messages.appendSlice(allocator, source.messages);
        return .{
            .allocator = allocator,
            .system_prompt = source.system_prompt,
            .messages = messages,
            .tools = source.tools,
        };
    }

    fn deinit(self: *Context) void {
        self.messages.deinit(self.allocator);
        self.* = undefined;
    }
};

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

fn testSink(context: ?*anyopaque, event: agent.AgentEvent) anyerror!void {
    const events: *std.ArrayList(agent.AgentEvent) = @ptrCast(@alignCast(context.?));
    try events.append(std.testing.allocator, event);
}

fn testStream(_: ?*anyopaque, request: ai.StreamRequest) ai.AssistantMessageEventStream {
    var stream = ai.AssistantMessageEventStream.init(request.event_buffer);
    const sink = stream.sink();
    sink.endDone(request.io, .stop, assistantMessage("ok")) catch unreachable;
    return stream;
}

fn testToolStream(context: ?*anyopaque, request: ai.StreamRequest) ai.AssistantMessageEventStream {
    const calls: *usize = @ptrCast(@alignCast(context.?));
    var stream = ai.AssistantMessageEventStream.init(request.event_buffer);
    const sink = stream.sink();
    if (calls.* == 0) {
        sink.endDone(request.io, .tool_use, assistantToolCallMessage()) catch unreachable;
    } else {
        sink.endDone(request.io, .stop, assistantMessage("done")) catch unreachable;
    }
    calls.* += 1;
    return stream;
}

fn testTwoToolStream(context: ?*anyopaque, request: ai.StreamRequest) ai.AssistantMessageEventStream {
    const calls: *usize = @ptrCast(@alignCast(context.?));
    var stream = ai.AssistantMessageEventStream.init(request.event_buffer);
    const sink = stream.sink();
    if (calls.* == 0) {
        sink.endDone(request.io, .tool_use, assistantTwoToolCallMessage()) catch unreachable;
    } else {
        sink.endDone(request.io, .stop, assistantMessage("done")) catch unreachable;
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

fn userMessage(text: []const u8) agent.AgentMessage {
    return .{ .user = .{ .content = .{ .string = text }, .timestamp = 0 } };
}

fn echoTool(
    _: std.mem.Allocator,
    _: std.Io,
    context: ?*anyopaque,
    _: runtime.CancelToken,
    _: []const u8,
    _: std.json.Value,
    _: ?agent.AgentToolUpdateCallback,
) anyerror!agent.AgentToolResult {
    const calls: *usize = @ptrCast(@alignCast(context.?));
    calls.* += 1;
    return .{ .content = &.{.{ .text = .{ .text = "echoed" } }} };
}

fn updatingTool(
    _: std.mem.Allocator,
    _: std.Io,
    context: ?*anyopaque,
    _: runtime.CancelToken,
    _: []const u8,
    _: std.json.Value,
    on_update: ?agent.AgentToolUpdateCallback,
) anyerror!agent.AgentToolResult {
    const calls: *usize = @ptrCast(@alignCast(context.?));
    calls.* += 1;
    if (on_update) |callback| {
        try callback.call(.{ .content = &.{.{ .text = .{ .text = "partial" } }} });
    }
    return .{ .content = &.{.{ .text = .{ .text = "done" } }} };
}

test "run prompt emits prompt assistant and agent end events" {
    var events = std.ArrayList(agent.AgentEvent).empty;
    defer events.deinit(std.testing.allocator);
    var cancel: runtime.CancelSource = .{};
    const prompt = userMessage("hello");

    try runPrompt(
        std.testing.allocator,
        std.Io.failing,
        &.{prompt},
        .{ .system_prompt = "", .messages = &.{}, .tools = &.{} },
        .{
            .model = testModel(),
            .stream = .{ .call_fn = testStream },
            .convert_to_llm = .{ .call_fn = defaultConvertToLlm },
        },
        cancel.token(),
        .{ .context = &events, .call_fn = testSink },
    );

    try std.testing.expectEqual(agent.AgentEvent.agent_start, events.items[0]);
    try std.testing.expect(events.items[events.items.len - 1] == .agent_end);
}

test "prompt stream exposes events and terminal messages through event pipe" {
    var cancel: runtime.CancelSource = .{};
    const prompt = userMessage("hello");
    var buffer: [8]agent.AgentEvent = undefined;
    var stream: AgentEventStream = undefined;

    startPromptStream(
        &stream,
        std.testing.allocator,
        std.Io.failing,
        &.{prompt},
        .{ .system_prompt = "", .messages = &.{}, .tools = &.{} },
        .{
            .model = testModel(),
            .stream = .{ .call_fn = testStream },
            .convert_to_llm = .{ .call_fn = defaultConvertToLlm },
        },
        cancel.token(),
        &buffer,
    );
    defer stream.deinit();

    try std.testing.expectEqual(agent.AgentEvent.agent_start, (try stream.next(std.Io.failing)).?);
    while (try stream.next(std.Io.failing)) |_| {}
    try stream.awaitProducer();
    try std.testing.expectEqual(@as(usize, 2), stream.result().?.len);
}

test "run prompt executes tool result then continues assistant turn" {
    var events = std.ArrayList(agent.AgentEvent).empty;
    defer events.deinit(std.testing.allocator);
    var cancel: runtime.CancelSource = .{};
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
        std.Io.failing,
        &.{prompt},
        .{ .system_prompt = "", .messages = &.{}, .tools = &.{tool} },
        .{
            .model = testModel(),
            .stream = .{ .context = &stream_calls, .call_fn = testToolStream },
            .convert_to_llm = .{ .call_fn = defaultConvertToLlm },
        },
        cancel.token(),
        .{ .context = &events, .call_fn = testSink },
    );

    try std.testing.expectEqual(@as(usize, 2), stream_calls);
    try std.testing.expectEqual(@as(usize, 1), tool_calls);
    try std.testing.expect(events.items[events.items.len - 1] == .agent_end);
}

test "parallel tool calls emit bounded live updates through owner" {
    var events = std.ArrayList(agent.AgentEvent).empty;
    defer events.deinit(std.testing.allocator);
    var cancel: runtime.CancelSource = .{};
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
        std.Io.failing,
        &.{prompt},
        .{ .system_prompt = "", .messages = &.{}, .tools = &.{tool} },
        .{
            .model = testModel(),
            .stream = .{ .context = &stream_calls, .call_fn = testToolStream },
            .convert_to_llm = .{ .call_fn = defaultConvertToLlm },
            .tool_execution = .parallel,
        },
        cancel.token(),
        .{ .context = &events, .call_fn = testSink },
    );

    var update_count: usize = 0;
    for (events.items) |event| {
        if (event == .tool_execution_update) update_count += 1;
    }

    try std.testing.expectEqual(@as(usize, 1), tool_calls);
    try std.testing.expectEqual(@as(usize, 1), update_count);
}

test "parallel tool calls finalize results in assistant source order" {
    var events = std.ArrayList(agent.AgentEvent).empty;
    defer events.deinit(std.testing.allocator);
    var cancel: runtime.CancelSource = .{};
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
        std.Io.failing,
        &.{prompt},
        .{ .system_prompt = "", .messages = &.{}, .tools = &.{tool} },
        .{
            .model = testModel(),
            .stream = .{ .context = &stream_calls, .call_fn = testTwoToolStream },
            .convert_to_llm = .{ .call_fn = defaultConvertToLlm },
            .tool_execution = .parallel,
        },
        cancel.token(),
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
    var events = std.ArrayList(agent.AgentEvent).empty;
    defer events.deinit(std.testing.allocator);
    var cancel: runtime.CancelSource = .{};
    const assistant: agent.AgentMessage = .{ .assistant = assistantMessage("done") };

    try std.testing.expectError(error.CannotContinueFromAssistant, runContinue(
        std.testing.allocator,
        std.Io.failing,
        .{ .system_prompt = "", .messages = &.{assistant}, .tools = &.{} },
        .{
            .model = testModel(),
            .stream = .{ .call_fn = testStream },
            .convert_to_llm = .{ .call_fn = defaultConvertToLlm },
        },
        cancel.token(),
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
