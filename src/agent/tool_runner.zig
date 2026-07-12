const std = @import("std");
const agent = @import("root.zig");
const ai = @import("../ai/root.zig");
const runtime = @import("../runtime/root.zig");

pub const Batch = struct {
    messages: []const ai.ToolResultMessage,
    terminate: bool,
};

pub const Runner = struct {
    allocator: std.mem.Allocator,
    // Owns the durable result-message contents returned in Batch. Scratch and
    // the message-list container use `allocator`; only the kept messages land
    // here, so the caller's arena can own them without a per-message free.
    result_allocator: std.mem.Allocator,
    io: std.Io,
    task_runtime: *runtime.Runtime,
    context: agent.AgentContext,
    assistant: ai.AssistantMessage,
    config: agent.AgentLoopConfig,
    token: runtime.CancelToken,
    emit: agent.EventSink,

    pub fn init(
        allocator: std.mem.Allocator,
        result_allocator: std.mem.Allocator,
        io: std.Io,
        task_runtime: *runtime.Runtime,
        context: agent.AgentContext,
        assistant: ai.AssistantMessage,
        config: agent.AgentLoopConfig,
        token: runtime.CancelToken,
        emit: agent.EventSink,
    ) Runner {
        return .{
            .allocator = allocator,
            .result_allocator = result_allocator,
            .io = io,
            .task_runtime = task_runtime,
            .context = context,
            .assistant = assistant,
            .config = config,
            .token = token,
            .emit = emit,
        };
    }

    pub fn run(self: Runner) !Batch {
        if (shouldExecuteToolsSequential(
            self.context.tools,
            self.assistant,
            self.config.tool_execution,
        )) {
            return executeToolCallsSequential(
                self.allocator,
                self.result_allocator,
                self.io,
                self.task_runtime,
                self.context,
                self.assistant,
                self.config,
                self.token,
                self.emit,
            );
        }
        return executeToolCallsParallel(
            self.allocator,
            self.result_allocator,
            self.io,
            self.context,
            self.assistant,
            self.config,
            self.token,
            self.task_runtime,
            self.emit,
        );
    }
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
    result_allocator: std.mem.Allocator,
    io: std.Io,
    task_runtime: *runtime.Runtime,
    context: agent.AgentContext,
    assistant: ai.AssistantMessage,
    config: agent.AgentLoopConfig,
    token: runtime.CancelToken,
    emit: agent.EventSink,
) !Batch {
    var messages = std.ArrayList(ai.ToolResultMessage).empty;
    errdefer deinitToolResultMessages(result_allocator, allocator, messages.items, &messages);
    var finalized_count: usize = 0;
    var terminate_count: usize = 0;
    var index: usize = 0;

    for (assistant.content) |content| {
        if (content != .tool_call) continue;
        if (token.isRequested()) break;
        const prepared = prepareToolCall(context, assistant, content.tool_call, config, token, index);
        index += 1;
        try emit.emit(.{ .tool_execution_start = .{
            .tool_call_id = prepared.toolCall().id,
            .tool_name = prepared.toolCall().name,
            .args = prepared.args(),
        } });

        var update_context: ToolUpdateContext = .{
            .emit = emit,
            .tool_call = prepared.toolCall(),
            .args = prepared.args(),
        };
        const executed = try executePreparedToolCall(allocator, io, task_runtime, prepared, token, .{
            .context = &update_context,
            .call_fn = emitToolUpdate,
        });
        var finalized = try finalizeExecutedToolCall(allocator, context, assistant, config, token, executed);
        finalized_count += 1;
        if (finalized.result.result.terminate) terminate_count += 1;

        emitToolExecutionEnd(emit, prepared.toolCall(), finalized) catch |err| {
            finalized.result.deinit();
            return err;
        };
        appendToolResultMessage(
            allocator,
            result_allocator,
            emit,
            prepared.toolCall(),
            finalized,
            &messages,
        ) catch |err| {
            finalized.result.deinit();
            return err;
        };
        finalized.result.deinit();
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
    blocked: FailedPreparedToolCall,

    fn index(self: PreparedToolCall) usize {
        return switch (self) {
            .executable => |item| item.index,
            .missing, .blocked => |item| item.index,
        };
    }

    fn toolCall(self: PreparedToolCall) ai.ToolCall {
        return switch (self) {
            .executable => |item| item.tool_call,
            .missing, .blocked => |item| item.tool_call,
        };
    }

    fn args(self: PreparedToolCall) std.json.Value {
        return switch (self) {
            .executable => |item| item.args,
            .missing => |item| item.tool_call.arguments,
            .blocked => |item| .{ .string = item.reason },
        };
    }
};

const ExecutedToolCall = struct {
    prepared: PreparedToolCall,
    result: agent.ToolExecutionResult,
    is_error: bool,
};

const FinalizedToolCall = struct {
    result: agent.ToolExecutionResult,
    is_error: bool,
};

const ToolWorkerEvent = union(enum) {
    update: ToolUpdate,
    complete: ExecutedToolCall,
    failed: ToolFailure,

    // The channel is buffered, so the worker resumes as soon as send returns
    // while the event may still sit in the buffer. Identity fields borrow
    // from the prepared array (alive for the whole batch); `partial_result`
    // is copied at send time because the tool may reuse its buffers the
    // moment the update callback returns. The receiver owns the copy.
    const ToolUpdate = struct {
        tool_call_id: []const u8,
        tool_name: []const u8,
        args: std.json.Value,
        partial_result: agent.AgentToolResult,
    };

    const ToolFailure = struct {
        prepared: PreparedToolCall,
        error_name: []const u8,
    };
};

const ToolWorkerChannel = std.Io.Queue(ToolWorkerEvent);
const tool_worker_event_capacity_count = agent.max_tool_calls_per_turn + agent.max_tool_updates_per_batch;

// Runtime task groups only report aggregate completion/failure. The agent loop
// needs a fixed, source-indexed result slot for each prepared tool call so
// finalization remains deterministic even when workers complete out of order.
const ToolWorkerGroup = struct {
    task_runtime: *runtime.Runtime,
    handles: [agent.max_tool_calls_per_turn]std.Io.Future(anyerror!void) = undefined,
    started: usize = 0,
    state: State = .idle,

    const State = enum {
        idle,
        active,
        drained,
    };

    fn init(task_runtime: *runtime.Runtime) ToolWorkerGroup {
        return .{ .task_runtime = task_runtime };
    }

    fn deinit(self: *ToolWorkerGroup) void {
        std.debug.assert(self.state != .active);
        self.* = undefined;
    }

    fn spawn(
        self: *ToolWorkerGroup,
        function: anytype,
        args: std.meta.ArgsTuple(@TypeOf(function)),
    ) anyerror!void {
        if (self.started == agent.max_tool_calls_per_turn) return error.TooManyTools;
        std.debug.assert(self.state == .idle or self.state == .active);
        self.handles[self.started] = try std.Io.concurrent(self.task_runtime.io(), function, args);
        self.started += 1;
        self.state = .active;
    }

    fn await(self: *ToolWorkerGroup) anyerror!void {
        std.debug.assert(self.state != .drained);
        var first_error: ?anyerror = null;
        for (self.handles[0..self.started]) |*handle| {
            handle.await(self.task_runtime.io()) catch |err| {
                if (first_error == null) first_error = err;
            };
        }
        self.state = .drained;
        if (first_error) |err| return err;
    }

    fn cancel(self: *ToolWorkerGroup) void {
        if (self.state != .active) return;
        for (self.handles[0..self.started]) |*handle| _ = handle.cancel(self.task_runtime.io()) catch {};
        self.state = .drained;
    }
};

const ParallelToolUpdateContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    channel: *ToolWorkerChannel,
    tool_call: ai.ToolCall,
    args: std.json.Value,
    update_count: *std.atomic.Value(usize),
};

fn executeToolCallsParallel(
    allocator: std.mem.Allocator,
    result_allocator: std.mem.Allocator,
    io: std.Io,
    context: agent.AgentContext,
    assistant: ai.AssistantMessage,
    config: agent.AgentLoopConfig,
    token: runtime.CancelToken,
    task_runtime: *runtime.Runtime,
    emit: agent.EventSink,
) !Batch {
    var prepared: [agent.max_tool_calls_per_turn]PreparedToolCall = undefined;
    const prepared_count = try prepareParallelToolCalls(context, assistant, config, token, emit, &prepared);
    if (prepared_count == 0) return .{ .messages = &.{}, .terminate = false };

    std.debug.assert(prepared_count <= agent.max_tool_calls_per_turn);
    var channel_buffer: [tool_worker_event_capacity_count]ToolWorkerEvent = undefined;
    var channel = ToolWorkerChannel.init(&channel_buffer);
    var update_count: std.atomic.Value(usize) = .init(0);
    var group = ToolWorkerGroup.init(task_runtime);
    defer group.deinit();
    errdefer cancelParallelToolWorkers(allocator, io, &group, &channel);

    for (prepared[0..prepared_count]) |item| {
        try group.spawn(
            executePreparedToolCallWorker,
            .{ allocator, io, task_runtime, item, token, &channel, &update_count },
        );
    }

    var executed: [agent.max_tool_calls_per_turn]ExecutedToolCall = undefined;
    var executed_owned: [agent.max_tool_calls_per_turn]bool = @splat(false);
    errdefer deinitOwnedExecutedToolCalls(&executed, &executed_owned);

    var completion_order: [agent.max_tool_calls_per_turn]usize = undefined;
    var completed_count: usize = 0;
    while (completed_count < prepared_count) {
        const event = try channel.getOne(io);
        switch (event) {
            .update => |update| {
                defer agent.deinitAgentToolResult(allocator, update.partial_result);
                try emit.emit(.{ .tool_execution_update = .{
                    .tool_call_id = update.tool_call_id,
                    .tool_name = update.tool_name,
                    .args = update.args,
                    .partial_result = update.partial_result,
                } });
            },
            .complete => |complete| {
                const source_index = complete.prepared.index();
                completion_order[completed_count] = source_index;
                executed[source_index] = complete;
                executed_owned[source_index] = true;
                completed_count += 1;
            },
            .failed => |failed| {
                const source_index = failed.prepared.index();
                completion_order[completed_count] = source_index;
                executed[source_index] = .{
                    .prepared = failed.prepared,
                    .result = try createErrorToolResultFmt(
                        allocator,
                        "tool worker failed: {s}",
                        .{failed.error_name},
                    ),
                    .is_error = true,
                };
                executed_owned[source_index] = true;
                completed_count += 1;
            },
        }
    }

    try group.await();

    var finalized: [agent.max_tool_calls_per_turn]FinalizedToolCall = undefined;
    var finalized_owned: [agent.max_tool_calls_per_turn]bool = @splat(false);
    errdefer deinitOwnedFinalizedToolCalls(&finalized, &finalized_owned);
    var terminate_count: usize = 0;

    // Pi exposes execution completion order, independent of assistant source order.
    for (completion_order[0..completed_count]) |source_index| {
        const item = executed[source_index];
        executed_owned[source_index] = false;
        finalized[source_index] = try finalizeExecutedToolCall(allocator, context, assistant, config, token, item);
        finalized_owned[source_index] = true;
        if (finalized[source_index].result.result.terminate) terminate_count += 1;
        try emitToolExecutionEnd(emit, item.prepared.toolCall(), finalized[source_index]);
    }

    var messages = std.ArrayList(ai.ToolResultMessage).empty;
    errdefer deinitToolResultMessages(result_allocator, allocator, messages.items, &messages);
    // Durable tool-result messages remain in assistant source order.
    for (executed[0..prepared_count], 0..) |item, source_index| {
        try appendToolResultMessage(
            allocator,
            result_allocator,
            emit,
            item.prepared.toolCall(),
            finalized[source_index],
            &messages,
        );
        finalized[source_index].result.deinit();
        finalized_owned[source_index] = false;
    }

    return .{
        .messages = try messages.toOwnedSlice(allocator),
        .terminate = prepared_count > 0 and terminate_count == prepared_count,
    };
}

fn cancelParallelToolWorkers(
    allocator: std.mem.Allocator,
    io: std.Io,
    group: *ToolWorkerGroup,
    channel: *ToolWorkerChannel,
) void {
    group.cancel();
    channel.close(io);
    drainPendingToolWorkerEvents(allocator, io, channel);
}

fn drainPendingToolWorkerEvents(allocator: std.mem.Allocator, io: std.Io, channel: *ToolWorkerChannel) void {
    while (true) {
        var item: [1]ToolWorkerEvent = undefined;
        const count = channel.get(io, &item, 0) catch break;
        if (count == 0) break;
        deinitToolWorkerEvent(allocator, &item[0]);
    }
}

fn deinitToolWorkerEvent(allocator: std.mem.Allocator, event: *ToolWorkerEvent) void {
    switch (event.*) {
        .update => |update| agent.deinitAgentToolResult(allocator, update.partial_result),
        .failed => {},
        .complete => |*complete| complete.result.deinit(),
    }
}

fn deinitOwnedExecutedToolCalls(
    executed: *[agent.max_tool_calls_per_turn]ExecutedToolCall,
    owned: *[agent.max_tool_calls_per_turn]bool,
) void {
    for (owned, 0..) |is_owned, index| {
        if (is_owned) executed[index].result.deinit();
    }
}

fn deinitOwnedFinalizedToolCalls(
    finalized: *[agent.max_tool_calls_per_turn]FinalizedToolCall,
    owned: *[agent.max_tool_calls_per_turn]bool,
) void {
    for (owned, 0..) |is_owned, index| {
        if (is_owned) finalized[index].result.deinit();
    }
}

fn prepareParallelToolCalls(
    context: agent.AgentContext,
    assistant: ai.AssistantMessage,
    config: agent.AgentLoopConfig,
    token: runtime.CancelToken,
    emit: agent.EventSink,
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

        out[prepared_count] = prepareToolCall(context, assistant, tool_call, config, token, prepared_count);
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
    task_runtime: *runtime.Runtime,
    prepared: PreparedToolCall,
    token: runtime.CancelToken,
    channel: *ToolWorkerChannel,
    update_count: *std.atomic.Value(usize),
) anyerror!void {
    var update_context: ParallelToolUpdateContext = .{
        .allocator = allocator,
        .io = io,
        .channel = channel,
        .tool_call = prepared.toolCall(),
        .args = prepared.args(),
        .update_count = update_count,
    };
    var executed = executePreparedToolCall(
        allocator,
        io,
        task_runtime,
        prepared,
        token,
        .{ .context = &update_context, .call_fn = enqueueToolUpdate },
    ) catch |err| {
        channel.putOne(io, .{ .failed = .{ .prepared = prepared, .error_name = @errorName(err) } }) catch |channel_err| {
            if (channel_err == error.Canceled) return error.Canceled;
            return;
        };
        return;
    };
    channel.putOne(io, .{ .complete = executed }) catch |channel_err| {
        executed.result.deinit();
        if (channel_err == error.Canceled) return error.Canceled;
    };
}

fn prepareToolCall(
    context: agent.AgentContext,
    assistant: ai.AssistantMessage,
    tool_call: ai.ToolCall,
    config: agent.AgentLoopConfig,
    token: runtime.CancelToken,
    index: usize,
) PreparedToolCall {
    const tool = findTool(context.tools, tool_call.name) orelse return .{ .missing = .{
        .index = index,
        .tool_call = tool_call,
        .reason = tool_call.name,
    } };

    const args = tool_call.arguments;

    // Debt owner: agent. Reason: JSON-schema validation of `args` against
    // `agent.AgentTool.parameters` is not yet executable here; the before-tool
    // policy may only block. Remove when an executable validator exists.
    if (config.before_tool_call) |before| {
        const before_result = before.call(token, .{
            .assistant_message = assistant,
            .tool_call = tool_call,
            .args = args,
            .agent = .{
                .system_prompt = context.system_prompt,
                .messages = context.messages,
                .tools = context.tools,
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
    task_runtime: *runtime.Runtime,
    prepared: PreparedToolCall,
    token: runtime.CancelToken,
    on_update: agent.AgentToolUpdateCallback,
) anyerror!ExecutedToolCall {
    switch (prepared) {
        .missing => |item| return .{
            .prepared = prepared,
            .result = try createErrorToolResultFmt(allocator, "Tool {s} not found", .{item.reason}),
            .is_error = true,
        },
        .blocked => |item| return .{
            .prepared = prepared,
            .result = try createErrorToolResult(allocator, item.reason),
            .is_error = true,
        },
        .executable => |item| {
            const result = agent.ExecuteToolHook.call(
                allocator,
                io,
                task_runtime,
                item.tool.execute,
                token,
                item.tool_call.id,
                item.args,
                on_update,
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
    context: agent.AgentContext,
    assistant: ai.AssistantMessage,
    config: agent.AgentLoopConfig,
    token: runtime.CancelToken,
    executed: ExecutedToolCall,
) !FinalizedToolCall {
    var result = executed.result;
    var result_owned = true;
    errdefer if (result_owned) result.deinit();
    var is_error = executed.is_error;
    if (executed.prepared == .executable) {
        if (config.after_tool_call) |after| {
            const prepared = executed.prepared.executable;
            const override = after.call(token, .{
                .assistant_message = assistant,
                .tool_call = prepared.tool_call,
                .args = prepared.args,
                .result = result.view(),
                .is_error = is_error,
                .agent = .{
                    .system_prompt = context.system_prompt,
                    .messages = context.messages,
                    .tools = context.tools,
                },
            }) catch |err| {
                result.deinit();
                result_owned = false;
                return .{
                    .result = try createErrorToolResultFmt(
                        allocator,
                        "after tool call failed: {s}",
                        .{@errorName(err)},
                    ),
                    .is_error = true,
                };
            };
            if (override) |value| {
                if (value.content) |content| try replaceToolResultContent(&result, content);
                if (value.details) |details| try replaceToolResultDetails(&result, details);
                if (value.terminate) |terminate| result.result.terminate = terminate;
                if (value.is_error) |override_is_error| is_error = override_is_error;
            }
        }
    }
    result_owned = false;
    return .{ .result = result, .is_error = is_error };
}

fn emitToolExecutionEnd(
    emit: agent.EventSink,
    tool_call: ai.ToolCall,
    finalized: FinalizedToolCall,
) !void {
    try emit.emit(.{ .tool_execution_end = .{
        .tool_call_id = tool_call.id,
        .tool_name = tool_call.name,
        .result = finalized.result.view(),
        .is_error = finalized.is_error,
    } });
}

fn appendToolResultMessage(
    allocator: std.mem.Allocator,
    result_allocator: std.mem.Allocator,
    emit: agent.EventSink,
    tool_call: ai.ToolCall,
    finalized: FinalizedToolCall,
    messages: *std.ArrayList(ai.ToolResultMessage),
) !void {
    // Durable message content lives in result_allocator; the list container
    // and the append below use the scratch allocator.
    const message = try createToolResultMessage(
        result_allocator,
        tool_call,
        finalized.result.view(),
        finalized.is_error,
    );
    errdefer agent.deinitToolResultMessage(result_allocator, message);
    try emit.emit(.{ .message_start = .{ .message = .{ .tool_result = message } } });
    try emit.emit(.{ .message_end = .{ .message = .{ .tool_result = message } } });
    try messages.append(allocator, message);
}

const ToolUpdateContext = struct {
    emit: agent.EventSink,
    tool_call: ai.ToolCall,
    args: std.json.Value,
};

fn enqueueToolUpdate(context: ?*anyopaque, partial_result: agent.AgentToolResult) anyerror!void {
    const update: *ParallelToolUpdateContext = @ptrCast(@alignCast(context.?));
    const previous_count = update.update_count.fetchAdd(1, .monotonic);
    if (previous_count >= agent.max_tool_updates_per_batch) return error.TooManyToolUpdates;
    const owned_partial = try agent.copyAgentToolResult(update.allocator, partial_result);
    errdefer agent.deinitAgentToolResult(update.allocator, owned_partial);
    try update.channel.putOne(update.io, .{ .update = .{
        .tool_call_id = update.tool_call.id,
        .tool_name = update.tool_call.name,
        .args = update.args,
        .partial_result = owned_partial,
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

fn replaceToolResultContent(result: *agent.ToolExecutionResult, content: []const ai.ToolResultContent) !void {
    const previous = result.result.content;
    result.result.content = try agent.copyToolResultContentSlice(result.allocator, content);
    for (previous) |item| agent.deinitToolResultContent(result.allocator, item);
    result.allocator.free(previous);
}

fn replaceToolResultDetails(result: *agent.ToolExecutionResult, details: std.json.Value) !void {
    const cloned = try runtime.cloneJsonValue(result.allocator, details);
    const previous = result.result.details;
    result.result.details = cloned;
    if (previous) |value| runtime.freeJsonValue(result.allocator, value);
}

pub fn createToolResultMessage(
    allocator: std.mem.Allocator,
    tool_call: ai.ToolCall,
    result: agent.AgentToolResult,
    is_error: bool,
) !ai.ToolResultMessage {
    const tool_call_id = try allocator.dupe(u8, tool_call.id);
    errdefer allocator.free(tool_call_id);
    const tool_name = try allocator.dupe(u8, tool_call.name);
    errdefer allocator.free(tool_name);
    const content = try agent.copyToolResultContentSlice(allocator, result.content);
    errdefer agent.deinitToolResultContentSlice(allocator, content);
    const details = if (result.details) |value| try runtime.cloneJsonValue(allocator, value) else null;
    errdefer if (details) |value| runtime.freeJsonValue(allocator, value);
    return .{
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .content = content,
        .details = details,
        .is_error = is_error,
        .timestamp = 0,
    };
}

fn createErrorToolResult(allocator: std.mem.Allocator, message: []const u8) !agent.ToolExecutionResult {
    const content = try allocator.alloc(ai.ToolResultContent, 1);
    errdefer allocator.free(content);
    content[0] = .{ .text = .{ .text = try allocator.dupe(u8, message) } };
    return .{ .allocator = allocator, .result = .{ .content = content, .details = .{ .object = .empty } } };
}

fn createErrorToolResultFmt(
    allocator: std.mem.Allocator,
    comptime fmt: []const u8,
    args: anytype,
) !agent.ToolExecutionResult {
    const message = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(message);
    return createErrorToolResult(allocator, message);
}

fn deinitToolResultMessages(
    result_allocator: std.mem.Allocator,
    list_allocator: std.mem.Allocator,
    messages: []const ai.ToolResultMessage,
    list: *std.ArrayList(ai.ToolResultMessage),
) void {
    for (messages) |message| agent.deinitToolResultMessage(result_allocator, message);
    list.deinit(list_allocator);
}
