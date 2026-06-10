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
    io: std.Io,
    task_runtime: *runtime.Runtime,
    context: agent.AgentContext,
    assistant: ai.AssistantMessage,
    config: agent.AgentLoopConfig,
    token: runtime.CancelToken,
    emit: agent.EventSink,

    pub fn init(
        allocator: std.mem.Allocator,
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
    io: std.Io,
    task_runtime: *runtime.Runtime,
    context: agent.AgentContext,
    assistant: ai.AssistantMessage,
    config: agent.AgentLoopConfig,
    token: runtime.CancelToken,
    emit: agent.EventSink,
) !Batch {
    var messages = std.ArrayList(ai.ToolResultMessage).empty;
    errdefer deinitToolResultMessages(allocator, messages.items, &messages);
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

        var finalized = try executeOneToolCall(
            allocator,
            io,
            task_runtime,
            context,
            assistant,
            tool_call,
            config,
            token,
            emit,
        );
        finalized_count += 1;
        if (finalized.result.result.terminate) terminate_count += 1;

        emitFinalizedToolCall(allocator, emit, tool_call, finalized, &messages) catch |err| {
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

const ToolWorkerChannel = runtime.Channel(ToolWorkerEvent);
const tool_worker_event_capacity_count = agent.max_tool_calls_per_turn + agent.max_tool_updates_per_batch;

// Runtime task groups only report aggregate completion/failure. The agent loop
// needs a fixed, source-indexed result slot for each prepared tool call so
// finalization remains deterministic even when workers complete out of order.
const ToolWorkerGroup = struct {
    task_runtime: *runtime.Runtime,
    handles: [agent.max_tool_calls_per_turn]runtime.Task(anyerror!void) = undefined,
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
        self.handles[self.started] = try self.task_runtime.spawn(function, args);
        self.started += 1;
        self.state = .active;
    }

    fn await(self: *ToolWorkerGroup) anyerror!void {
        std.debug.assert(self.state != .drained);
        var first_error: ?anyerror = null;
        for (self.handles[0..self.started]) |*handle| {
            handle.join() catch |err| {
                if (first_error == null) first_error = err;
            };
        }
        self.state = .drained;
        if (first_error) |err| return err;
    }

    fn cancel(self: *ToolWorkerGroup) void {
        if (self.state != .active) return;
        for (self.handles[0..self.started]) |*handle| handle.cancel();
        self.state = .drained;
    }
};

const ParallelToolUpdateContext = struct {
    channel: *ToolWorkerChannel,
    tool_call: ai.ToolCall,
    args: std.json.Value,
    update_count: *std.atomic.Value(usize),
};

fn executeToolCallsParallel(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: agent.AgentContext,
    assistant: ai.AssistantMessage,
    config: agent.AgentLoopConfig,
    token: runtime.CancelToken,
    task_runtime: *runtime.Runtime,
    emit: agent.EventSink,
) !Batch {
    var prepared: [agent.max_tool_calls_per_turn]PreparedToolCall = undefined;
    const prepared_count = try prepareParallelToolCalls(allocator, context, assistant, config, token, emit, &prepared);
    if (prepared_count == 0) return .{ .messages = &.{}, .terminate = false };

    std.debug.assert(prepared_count <= agent.max_tool_calls_per_turn);
    var channel_buffer: [tool_worker_event_capacity_count]ToolWorkerEvent = undefined;
    var channel = ToolWorkerChannel.init(&channel_buffer);
    var update_count: std.atomic.Value(usize) = .init(0);
    var group = ToolWorkerGroup.init(task_runtime);
    defer group.deinit();
    errdefer cancelParallelToolWorkers(&group, &channel);

    for (prepared[0..prepared_count]) |item| {
        try group.spawn(
            executePreparedToolCallWorker,
            .{ allocator, io, task_runtime, item, token, &channel, &update_count },
        );
    }

    var executed: [agent.max_tool_calls_per_turn]ExecutedToolCall = undefined;
    var executed_owned: [agent.max_tool_calls_per_turn]bool = @splat(false);
    errdefer deinitOwnedExecutedToolCalls(&executed, &executed_owned);

    var completed_count: usize = 0;
    while (completed_count < prepared_count) {
        const event = try channel.receive();
        switch (event) {
            .update => |update| try emit.emit(.{ .tool_execution_update = .{
                .tool_call_id = update.tool_call_id,
                .tool_name = update.tool_name,
                .args = update.args,
                .partial_result = update.partial_result,
            } }),
            .complete => |complete| {
                executed[complete.prepared.index()] = complete;
                executed_owned[complete.prepared.index()] = true;
                completed_count += 1;
            },
            .failed => |failed| {
                executed[failed.prepared.index()] = .{
                    .prepared = failed.prepared,
                    .result = try createErrorToolResultFmt(
                        allocator,
                        "tool worker failed: {s}",
                        .{failed.error_name},
                    ),
                    .is_error = true,
                };
                executed_owned[failed.prepared.index()] = true;
                completed_count += 1;
            },
        }
    }

    try group.await();

    var messages = std.ArrayList(ai.ToolResultMessage).empty;
    errdefer deinitToolResultMessages(allocator, messages.items, &messages);
    var terminate_count: usize = 0;

    for (executed[0..prepared_count]) |item| {
        executed_owned[item.prepared.index()] = false;
        var finalized = try finalizeExecutedToolCall(allocator, context, assistant, config, token, item);
        if (finalized.result.result.terminate) terminate_count += 1;
        emitFinalizedToolCall(allocator, emit, item.prepared.toolCall(), finalized, &messages) catch |err| {
            finalized.result.deinit();
            return err;
        };
        finalized.result.deinit();
    }

    return .{
        .messages = try messages.toOwnedSlice(allocator),
        .terminate = prepared_count > 0 and terminate_count == prepared_count,
    };
}

fn cancelParallelToolWorkers(
    group: *ToolWorkerGroup,
    channel: *ToolWorkerChannel,
) void {
    group.cancel();
    channel.close(.graceful);
    drainPendingToolWorkerEvents(channel);
}

fn drainPendingToolWorkerEvents(channel: *ToolWorkerChannel) void {
    while (true) {
        var event = channel.tryReceive() catch break;
        deinitToolWorkerEvent(&event);
    }
}

fn deinitToolWorkerEvent(event: *ToolWorkerEvent) void {
    switch (event.*) {
        .update, .failed => {},
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

fn prepareParallelToolCalls(
    allocator: std.mem.Allocator,
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

        out[prepared_count] = prepareToolCall(allocator, context, assistant, tool_call, config, token, prepared_count);
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
    var executed = executePreparedToolCall(
        allocator,
        io,
        task_runtime,
        prepared,
        token,
        channel,
        update_count,
    ) catch |err| {
        channel.send(.{ .failed = .{ .prepared = prepared, .error_name = @errorName(err) } }) catch |channel_err| {
            if (channel_err == error.Canceled) return error.Canceled;
            return;
        };
        return;
    };
    channel.send(.{ .complete = executed }) catch |channel_err| {
        executed.result.deinit();
        if (channel_err == error.Canceled) return error.Canceled;
    };
}

fn prepareToolCall(
    allocator: std.mem.Allocator,
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

    // Debt owner: agent. Reason: JSON-schema validation needs one shared
    // validator for sequential and parallel tool paths. Scope: before-tool
    // policy may block or rewrite arguments, but schema validation is not yet
    // executable here. Remove when `agent.AgentTool.parameters` has an
    // executable validator. Current behavior is covered by prepare/block tests
    // on sequential and parallel tool paths.
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
    channel: *ToolWorkerChannel,
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
                .channel = channel,
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
                task_runtime,
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

fn emitFinalizedToolCall(
    allocator: std.mem.Allocator,
    emit: agent.EventSink,
    tool_call: ai.ToolCall,
    finalized: FinalizedToolCall,
    messages: *std.ArrayList(ai.ToolResultMessage),
) !void {
    try emit.emit(.{ .tool_execution_end = .{
        .tool_call_id = tool_call.id,
        .tool_name = tool_call.name,
        .result = finalized.result.view(),
        .is_error = finalized.is_error,
    } });

    const message = try createToolResultMessage(allocator, tool_call, finalized.result.view(), finalized.is_error);
    errdefer agent.deinitToolResultMessage(allocator, message);
    try emit.emit(.{ .message_end = .{ .message = .{ .tool_result = message } } });
    try messages.append(allocator, message);
}

fn executeOneToolCall(
    allocator: std.mem.Allocator,
    io: std.Io,
    task_runtime: *runtime.Runtime,
    context: agent.AgentContext,
    assistant: ai.AssistantMessage,
    tool_call: ai.ToolCall,
    config: agent.AgentLoopConfig,
    token: runtime.CancelToken,
    emit: agent.EventSink,
) !FinalizedToolCall {
    const tool = findTool(context.tools, tool_call.name) orelse return .{
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
                .system_prompt = context.system_prompt,
                .messages = context.messages,
                .tools = context.tools,
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
        task_runtime,
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
            .result = result.view(),
            .is_error = is_error,
            .agent = .{
                .system_prompt = context.system_prompt,
                .messages = context.messages,
                .tools = context.tools,
            },
        }) catch |err| {
            result.deinit();
            return .{
                .result = try createErrorToolResultFmt(allocator, "after tool call failed: {s}", .{@errorName(err)}),
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

    return .{ .result = result, .is_error = is_error };
}

const ToolUpdateContext = struct {
    emit: agent.EventSink,
    tool_call: ai.ToolCall,
    args: std.json.Value,
};

fn enqueueToolUpdate(context: ?*anyopaque, partial_result: agent.AgentToolResult) anyerror!void {
    const update: *ParallelToolUpdateContext = @ptrCast(@alignCast(context.?));
    const previous_count = update.update_count.fetchAdd(1, .monotonic);
    if (previous_count >= agent.max_tool_updates_per_batch) return error.TooManyTools;
    try update.channel.send(.{ .update = .{
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
    allocator: std.mem.Allocator,
    messages: []const ai.ToolResultMessage,
    list: *std.ArrayList(ai.ToolResultMessage),
) void {
    for (messages) |message| agent.deinitToolResultMessage(allocator, message);
    list.deinit(allocator);
}
