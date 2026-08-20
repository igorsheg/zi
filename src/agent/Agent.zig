const std = @import("std");
const ai_failure = @import("../ai/failure.zig");
const ai_message = @import("../ai/message.zig");
const ai_model = @import("../ai/model.zig");
const ai_stream = @import("../ai/stream.zig");
const ai_usage = @import("../ai/usage.zig");
const commit_api = @import("Commit.zig");
const context_projection = @import("ContextProjection.zig");
const event_api = @import("Event.zig");
const History = @import("History.zig");
const tool_api = @import("Tool.zig");
const limit_api = @import("limits.zig");

const Agent = @This();

pub const State = union(enum) {
    ready,
    running: event_api.RunId,
    poisoned,
};

pub const StateTag = std.meta.Tag(State);

pub const RunControl = struct {
    cancellation: ?*const ai_model.CancellationToken = null,
    deadline: ?std.Io.Clock.Timestamp = null,
};

pub const Event = event_api.Event;
pub const EventSink = event_api.Sink;

pub const RunError = error{
    OutOfMemory,
    Cancelled,
    TimedOut,
    UnsupportedCapability,
    UnsupportedSetting,
    InvalidRequest,
    ConnectionFailed,
    RateLimited,
    ProviderRejectedRequest,
    ProviderUnavailable,
    InvalidProviderResponse,
    StreamInterrupted,
    EventConsumerStopped,
    HandoffRejected,
    MaxModelRequestsExceeded,
    MaxToolCallsExceeded,
    ToolResultTooLarge,
    ToolControlUnavailable,
    PersistenceFailed,
    CommitIndeterminate,
    SessionTooLarge,
    AlreadyRun,
    SessionUnavailable,
};

const TurnError = error{
    OutOfMemory,
    Cancelled,
    TimedOut,
    UnsupportedCapability,
    UnsupportedSetting,
    InvalidRequest,
    ConnectionFailed,
    RateLimited,
    ProviderRejectedRequest,
    ProviderUnavailable,
    InvalidProviderResponse,
    StreamInterrupted,
    EventConsumerStopped,
    HandoffRejected,
    MaxModelRequestsExceeded,
    MaxToolCallsExceeded,
    ToolResultTooLarge,
    ToolControlUnavailable,
    PersistenceFailed,
    CommitIndeterminate,
    SessionTooLarge,
};

allocator: std.mem.Allocator,
io: std.Io,
model: ai_model.Model,
/// Borrowed immutable policy; its storage must outlive the agent.
instructions: []const []const u8,
catalog: tool_api.Catalog,
history: History,
result_arena: std.heap.ArenaAllocator,
run_state: State = .ready,
limits: limit_api.RunLimits,
events: ?EventSink,
commits: ?commit_api.Sink = null,
model_request_count: usize = 0,
tool_call_count: usize = 0,
provider_failure: ?ai_failure.ProviderFailure = null,
context: context_projection.State = .{},
next_run_id: u64 = 0,

pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: ai_model.Model,
    instructions: []const []const u8,
    tools: []const tool_api.Tool,
    limits: limit_api.RunLimits,
    events: ?EventSink,
) tool_api.Error!Agent {
    var catalog = tool_api.Catalog.init(allocator);
    errdefer catalog.deinit();
    for (tools) |tool| try catalog.admit(tool);
    return .{
        .allocator = allocator,
        .io = io,
        .model = model,
        .instructions = instructions,
        .catalog = catalog,
        .history = History.init(allocator),
        .result_arena = std.heap.ArenaAllocator.init(allocator),
        .limits = limits,
        .events = events,
    };
}

pub fn deinit(self: *Agent) void {
    self.result_arena.deinit();
    self.history.deinit();
    self.catalog.deinit();
    self.* = undefined;
}

pub fn state(self: *const Agent) State {
    return self.run_state;
}

pub fn messages(self: *const Agent) []const ai_message.Message {
    return self.history.messages();
}

pub fn modelRequests(self: *const Agent) usize {
    return self.model_request_count;
}

pub fn toolCalls(self: *const Agent) usize {
    return self.tool_call_count;
}

/// Provider failure details remain valid until the next admitted run or deinit.
pub fn providerFailure(self: *const Agent) ?ai_failure.ProviderFailure {
    return self.provider_failure;
}

/// Construction-only binding for a consumer that outlives every run.
pub fn bindEvents(self: *Agent, sink: EventSink) error{EventsAlreadyBound}!void {
    std.debug.assert(self.run_state == .ready);
    if (self.events != null) return error.EventsAlreadyBound;
    self.events = sink;
}

/// Construction-only binding; committed sessions install it before the agent is published.
pub fn bindCommits(
    self: *Agent,
    initial_messages: []const ai_message.Message,
    sink: commit_api.Sink,
) error{ OutOfMemory, SessionTooLarge }!void {
    std.debug.assert(self.run_state == .ready);
    std.debug.assert(self.history.messages().len == 0);
    std.debug.assert(self.commits == null);
    for (initial_messages) |message| try self.history.append(message);
    self.commits = sink;
}

/// The returned final text remains valid until the next admitted run or deinit.
pub fn run(self: *Agent, input: []const u8) RunError![]const u8 {
    return self.runWithControl(input, .{});
}

pub fn runWithControl(self: *Agent, input: []const u8, control: RunControl) RunError![]const u8 {
    return self.runInternal(input, control);
}

fn runInternal(self: *Agent, input: []const u8, control: RunControl) RunError![]const u8 {
    switch (self.run_state) {
        .ready => {},
        .running => return error.AlreadyRun,
        .poisoned => return error.SessionUnavailable,
    }
    try self.preflight();

    self.next_run_id +%= 1;
    if (self.next_run_id == 0) self.next_run_id = 1;
    const run_id: event_api.RunId = @enumFromInt(self.next_run_id);
    self.run_state = .{ .running = run_id };
    self.result_arena.deinit();
    self.result_arena = std.heap.ArenaAllocator.init(self.allocator);
    self.model_request_count = 0;
    self.tool_call_count = 0;
    self.provider_failure = null;
    self.context.reset();
    defer self.history.truncate(self.context.abandoned(self.history.messages().len));
    const first_message = self.history.messages().len;

    self.emit(.{ .agent_start = .{ .run_id = run_id } }) catch |failure| {
        self.run_state = .ready;
        return failure;
    };

    self.commitMessage(.user, .{ .request = .{
        .parts = &.{.{ .user = .{ .text = input } }},
    } }) catch |failure| {
        return self.finishUnpublishedRun(run_id, first_message, failure);
    };

    const result = self.runTurns(run_id, control);
    const outcome: commit_api.RunOutcome = if (result) |_| .completed else |failure| runOutcome(failure);
    if (result) |_| {} else |failure| {
        if (failure == error.CommitIndeterminate) {
            self.run_state = .poisoned;
            discardEventResult(self.emitAgentEnd(run_id, outcome, first_message));
            return failure;
        }
    }
    const settlement = self.settleRun(outcome);
    if (settlement) |_| {} else |failure| {
        self.run_state = .poisoned;
        discardEventResult(self.emitAgentEnd(
            run_id,
            .{ .failed = .persistence_failed },
            first_message,
        ));
        return failure;
    }

    self.emitAgentEnd(run_id, outcome, first_message) catch |failure| {
        self.run_state = .ready;
        return failure;
    };
    self.run_state = .ready;
    return result;
}

fn finishUnpublishedRun(
    self: *Agent,
    run_id: event_api.RunId,
    first_message: usize,
    failure: TurnError,
) RunError {
    const outcome = runOutcome(failure);
    if (failure == error.CommitIndeterminate) self.run_state = .poisoned;
    self.emitAgentEnd(run_id, outcome, first_message) catch |event_failure| {
        if (self.run_state != .poisoned) self.run_state = .ready;
        return event_failure;
    };
    if (self.run_state != .poisoned) self.run_state = .ready;
    return failure;
}

fn discardEventResult(result: TurnError!void) void {
    if (result) |_| {} else |_| {}
}

fn emitAgentEnd(
    self: *Agent,
    run_id: event_api.RunId,
    outcome: commit_api.RunOutcome,
    first_message: usize,
) TurnError!void {
    try self.emit(.{ .agent_end = .{
        .run_id = run_id,
        .outcome = outcome,
        .messages = self.history.messages()[first_message..],
    } });
}

fn runTurns(self: *Agent, run_id: event_api.RunId, control: RunControl) TurnError![]const u8 {
    var definitions: std.ArrayList(ai_message.ToolDefinition) = .empty;
    defer definitions.deinit(self.allocator);
    for (self.catalog.tools.items) |tool| try definitions.append(self.allocator, tool.definition);

    const user_message_index = self.history.messages().len - 1;
    while (true) {
        if (self.model_request_count >= self.limits.max_model_requests) {
            return error.MaxModelRequestsExceeded;
        }
        self.model_request_count += 1;
        const turn_index: event_api.TurnIndex = @intCast(self.model_request_count);
        try self.emit(.{ .turn_start = .{ .run_id = run_id, .index = turn_index } });
        if (turn_index == 1) {
            const user = self.history.messages()[user_message_index];
            try self.emitMessageLifecycle(run_id, turn_index, user);
        }

        var accumulator = ai_stream.ResponseAccumulator.init(self.allocator, self.model.identity);
        defer accumulator.deinit();
        try self.emit(.{ .message_start = .{
            .run_id = run_id,
            .turn_index = turn_index,
            .message = .{ .response = accumulator.snapshot() },
        } });
        self.checkControl(control) catch |failure| {
            try self.emitDiscardedTurn(run_id, turn_index, accumulator.snapshot(), failure);
            return failure;
        };

        var response = self.invokeModel(
            run_id,
            turn_index,
            control,
            definitions.items,
            &accumulator,
        ) catch |failure| {
            try self.emitDiscardedTurn(run_id, turn_index, accumulator.snapshot(), failure);
            return failure;
        };
        defer response.deinit();
        if (!self.model.profile.supports(.streaming)) {
            accumulator.finish(response.value) catch |failure| {
                try self.emitDiscardedTurn(run_id, turn_index, accumulator.snapshot(), failure);
                return failure;
            };
        }
        const call_count = validateResponseFinish(response.value) catch |failure| {
            try self.emitDiscardedTurn(run_id, turn_index, accumulator.snapshot(), failure);
            return failure;
        };
        const response_index = self.history.messages().len;
        self.commitMessage(.response, .{ .response = response.value }) catch |failure| {
            try self.emitDiscardedTurn(run_id, turn_index, accumulator.snapshot(), failure);
            return failure;
        };
        const stored_response_message = self.history.messages()[self.history.messages().len - 1];
        const stored_response = stored_response_message.response;
        self.context.publishResponse(response_index, stored_response);
        const response_end: event_api.ResponseEnd = .{ .published = stored_response };
        try self.emit(.{ .message_end = .{
            .run_id = run_id,
            .turn_index = turn_index,
            .message = .{ .published = stored_response_message },
        } });

        var tool_results: std.ArrayList(ai_message.ToolResult) = .empty;
        defer tool_results.deinit(self.allocator);
        if (call_count > self.limits.max_tool_calls -| self.tool_call_count) {
            try self.emit(.{ .turn_end = .{
                .run_id = run_id,
                .index = turn_index,
                .response = response_end,
                .tool_results = tool_results.items,
            } });
            return error.MaxToolCallsExceeded;
        }

        for (stored_response.parts) |part| switch (part) {
            .tool_call => |call| {
                self.tool_call_count += 1;
                try self.emit(.{ .tool_execution_start = .{
                    .run_id = run_id,
                    .turn_index = turn_index,
                    .call_id = call.id,
                    .name = call.name,
                    .arguments_json = call.arguments_json,
                } });
                var result_arena = std.heap.ArenaAllocator.init(self.allocator);
                defer result_arena.deinit();
                const result = if (stored_response.finish.category == .length)
                    try self.failureResult(
                        result_arena.allocator(),
                        call,
                        "Tool call was not executed because the model response was truncated.",
                    )
                else
                    self.executeTool(result_arena.allocator(), call, control) catch |failure| {
                        try self.emit(.{ .tool_execution_end = .{
                            .run_id = run_id,
                            .turn_index = turn_index,
                            .call_id = call.id,
                            .name = call.name,
                            .result = .{ .discarded = runOutcome(failure) },
                        } });
                        try self.emit(.{ .turn_end = .{
                            .run_id = run_id,
                            .index = turn_index,
                            .response = response_end,
                            .tool_results = tool_results.items,
                        } });
                        return failure;
                    };
                const result_parts = [_]ai_message.RequestPart{.{ .tool_result = result }};
                self.commitMessage(.tool_result, .{ .request = .{ .parts = &result_parts } }) catch |failure| {
                    try self.emit(.{ .tool_execution_end = .{
                        .run_id = run_id,
                        .turn_index = turn_index,
                        .call_id = call.id,
                        .name = call.name,
                        .result = .{ .discarded = runOutcome(failure) },
                    } });
                    try self.emit(.{ .turn_end = .{
                        .run_id = run_id,
                        .index = turn_index,
                        .response = response_end,
                        .tool_results = tool_results.items,
                    } });
                    return failure;
                };
                const stored_result_message = self.history.messages()[self.history.messages().len - 1];
                const stored_result = stored_result_message.request;
                try tool_results.append(self.allocator, stored_result.parts[0].tool_result);
                try self.emit(.{ .tool_execution_end = .{
                    .run_id = run_id,
                    .turn_index = turn_index,
                    .call_id = call.id,
                    .name = call.name,
                    .result = .{ .published = stored_result.parts[0].tool_result },
                } });
                try self.emitMessageLifecycle(run_id, turn_index, stored_result_message);
            },
            else => {},
        };

        if (call_count > 0) self.context.completeToolExchange();
        try self.emit(.{ .turn_end = .{
            .run_id = run_id,
            .index = turn_index,
            .response = response_end,
            .tool_results = tool_results.items,
        } });
        if (call_count == 0) {
            return collectText(self.result_arena.allocator(), stored_response.parts);
        }
    }
}

fn emitDiscardedTurn(
    self: *Agent,
    run_id: event_api.RunId,
    turn_index: event_api.TurnIndex,
    response: ai_stream.ResponseSnapshot,
    failure: TurnError,
) TurnError!void {
    const discarded: event_api.DiscardedResponse = .{
        .response = response,
        .outcome = runOutcome(failure),
    };
    try self.emit(.{ .message_end = .{
        .run_id = run_id,
        .turn_index = turn_index,
        .message = .{ .discarded_response = discarded },
    } });
    try self.emit(.{ .turn_end = .{
        .run_id = run_id,
        .index = turn_index,
        .response = .{ .discarded = discarded },
        .tool_results = &.{},
    } });
}

fn emitMessageLifecycle(
    self: *Agent,
    run_id: event_api.RunId,
    turn_index: event_api.TurnIndex,
    message: ai_message.Message,
) TurnError!void {
    const snapshot: event_api.MessageSnapshot = switch (message) {
        .request => |request| .{ .request = request },
        .response => unreachable,
    };
    try self.emit(.{ .message_start = .{
        .run_id = run_id,
        .turn_index = turn_index,
        .message = snapshot,
    } });
    try self.emit(.{ .message_end = .{
        .run_id = run_id,
        .turn_index = turn_index,
        .message = .{ .published = message },
    } });
}

fn commitMessage(self: *Agent, kind: commit_api.MessageKind, value: ai_message.Message) TurnError!void {
    var prepared = try self.history.prepare(value);
    errdefer prepared.deinit();
    if (self.commits) |sink| try sink.commitMessage(kind, prepared.value);
    prepared.publish(&self.history);
}

fn settleRun(self: *Agent, outcome: commit_api.RunOutcome) commit_api.Error!void {
    if (self.commits) |sink| return sink.settleRun(outcome);
}

fn runOutcome(failure: TurnError) commit_api.RunOutcome {
    return switch (failure) {
        error.Cancelled => .cancelled,
        error.StreamInterrupted => .interrupted,
        error.OutOfMemory, error.SessionTooLarge => .{ .failed = .resource_exhausted },
        error.TimedOut => .{ .failed = .timed_out },
        error.UnsupportedCapability => .{ .failed = .unsupported_capability },
        error.UnsupportedSetting => .{ .failed = .unsupported_setting },
        error.InvalidRequest => .{ .failed = .invalid_request },
        error.ConnectionFailed => .{ .failed = .connection_failed },
        error.RateLimited => .{ .failed = .rate_limited },
        error.ProviderRejectedRequest => .{ .failed = .provider_rejected_request },
        error.ProviderUnavailable => .{ .failed = .provider_unavailable },
        error.InvalidProviderResponse => .{ .failed = .invalid_provider_response },
        error.EventConsumerStopped => .{ .failed = .event_consumer_stopped },
        error.HandoffRejected => .{ .failed = .handoff_rejected },
        error.MaxModelRequestsExceeded => .{ .failed = .max_model_requests_exceeded },
        error.MaxToolCallsExceeded => .{ .failed = .max_tool_calls_exceeded },
        error.ToolResultTooLarge => .{ .failed = .tool_result_too_large },
        error.ToolControlUnavailable => .{ .failed = .tool_control_unavailable },
        error.PersistenceFailed, error.CommitIndeterminate => .{ .failed = .persistence_failed },
    };
}

fn executeTool(
    self: *Agent,
    allocator: std.mem.Allocator,
    call: ai_message.ToolCall,
    control: RunControl,
) TurnError!ai_message.ToolResult {
    const resolved = self.catalog.lookup(call.name) orelse return self.failureResult(
        allocator,
        call,
        "Tool not found.",
    );
    tool_api.Tool.validateArguments(self.allocator, call.arguments_json) catch |failure| switch (failure) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return self.failureResult(allocator, call, "Tool arguments must be a JSON object."),
    };
    try self.checkControl(control);
    var call_arena = std.heap.ArenaAllocator.init(self.allocator);
    defer call_arena.deinit();
    const execution = try self.executeControlled(
        call_arena.allocator(),
        resolved,
        call.arguments_json,
        control,
    );
    return switch (execution) {
        .success => |output| success: {
            if (contentBytes(output.content) > self.limits.max_tool_result_bytes) {
                return error.ToolResultTooLarge;
            }
            break :success .{
                .call_id = try allocator.dupe(u8, call.id),
                .name = try allocator.dupe(u8, call.name),
                .content = try copyContent(allocator, output.content),
                .outcome = .success,
            };
        },
        .failure => |failure| self.failureResult(allocator, call, failure),
    };
}

const ControlledOutcome = union(enum) {
    tool: tool_api.ToolFatalError!tool_api.ToolExecution,
    deadline: std.Io.Cancelable!void,
    cancelled: std.Io.Cancelable!void,
};

fn executeControlled(
    self: *Agent,
    allocator: std.mem.Allocator,
    tool: tool_api.Tool,
    arguments_json: []const u8,
    control: RunControl,
) TurnError!tool_api.ToolExecution {
    const run_context: tool_api.Tool.RunContext = .{
        .cancellation = control.cancellation,
        .deadline = control.deadline,
    };
    if (control.cancellation == null and control.deadline == null) {
        return tool.execute(allocator, self.io, run_context, arguments_json);
    }

    var buffer: [3]ControlledOutcome = undefined;
    var select: std.Io.Select(ControlledOutcome) = .init(self.io, &buffer);
    defer select.cancelDiscard();
    select.concurrent(.tool, invokeTool, .{
        allocator,
        self.io,
        tool,
        run_context,
        arguments_json,
    }) catch return error.ToolControlUnavailable;
    if (control.deadline) |deadline| {
        select.concurrent(.deadline, waitForDeadline, .{ self.io, deadline }) catch
            return error.ToolControlUnavailable;
    }
    if (control.cancellation) |token| {
        select.concurrent(.cancelled, waitForCancellation, .{ self.io, token }) catch
            return error.ToolControlUnavailable;
    }

    const outcome = select.await() catch return error.Cancelled;
    return switch (outcome) {
        .tool => |result| result,
        .deadline => |result| {
            result catch return error.Cancelled;
            return error.TimedOut;
        },
        .cancelled => |result| {
            result catch return error.Cancelled;
            return error.Cancelled;
        },
    };
}

fn invokeTool(
    allocator: std.mem.Allocator,
    io: std.Io,
    tool: tool_api.Tool,
    run_context: tool_api.Tool.RunContext,
    arguments_json: []const u8,
) tool_api.ToolFatalError!tool_api.ToolExecution {
    return tool.execute(allocator, io, run_context, arguments_json);
}

fn waitForDeadline(io: std.Io, deadline: std.Io.Clock.Timestamp) std.Io.Cancelable!void {
    return deadline.wait(io);
}

fn waitForCancellation(io: std.Io, token: *const ai_model.CancellationToken) std.Io.Cancelable!void {
    const delay: std.Io.Timeout = .{ .duration = .{
        .raw = .fromMilliseconds(5),
        .clock = .awake,
    } };
    while (!token.isCancelled()) try delay.sleep(io);
}

fn failureResult(
    self: *Agent,
    allocator: std.mem.Allocator,
    call: ai_message.ToolCall,
    failure: []const u8,
) error{ OutOfMemory, ToolResultTooLarge }!ai_message.ToolResult {
    if (failure.len > self.limits.max_tool_result_bytes) return error.ToolResultTooLarge;
    const content = try allocator.alloc(ai_message.Content, 1);
    content[0] = .{ .text = try allocator.dupe(u8, failure) };
    return .{
        .call_id = try allocator.dupe(u8, call.id),
        .name = try allocator.dupe(u8, call.name),
        .content = content,
        .outcome = .failure,
    };
}

fn emit(self: *Agent, event: Event) TurnError!void {
    const sink = self.events orelse return;
    sink.emit(event) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        error.Cancelled => error.Cancelled,
        error.ConsumerStopped => error.EventConsumerStopped,
    };
}

fn checkControl(self: *const Agent, control: RunControl) error{ Cancelled, TimedOut }!void {
    if (control.cancellation) |token| if (token.isCancelled()) return error.Cancelled;
    if (control.deadline) |deadline| {
        const now = std.Io.Clock.Timestamp.now(self.io, deadline.clock);
        if (now.durationTo(deadline).raw.nanoseconds <= 0) return error.TimedOut;
    }
}

fn preflight(self: *const Agent) error{UnsupportedCapability}!void {
    if (self.catalog.tools.items.len > 0 and !self.model.profile.supports(.tools)) {
        return error.UnsupportedCapability;
    }
}

fn invokeModel(
    self: *Agent,
    run_id: event_api.RunId,
    turn_index: event_api.TurnIndex,
    control: RunControl,
    tools: []const ai_message.ToolDefinition,
    accumulator: *ai_stream.ResponseAccumulator,
) TurnError!ai_model.OwnedResponse {
    const request: ai_model.ModelRequest = .{
        .messages = self.history.messages(),
        .instructions = self.instructions,
        .tools = tools,
        .failure_sink = .{ .context = self, .observeFn = observeProviderFailure },
        .deadline = control.deadline,
        .cancellation = control.cancellation,
    };
    if (!self.model.profile.supports(.streaming)) {
        return self.model.complete(self.allocator, self.io, request) catch |failure|
            return mapModelError(failure);
    }

    var adapter: StreamEventAdapter = .{
        .agent = self,
        .run_id = run_id,
        .turn_index = turn_index,
        .accumulator = accumulator,
    };
    return self.model.stream(self.allocator, self.io, request, .{
        .context = &adapter,
        .emitFn = StreamEventAdapter.emit,
    }) catch |failure| {
        if (adapter.failure) |event_failure| return event_failure;
        return mapModelError(failure);
    };
}

fn mapModelError(failure: ai_model.ModelError) TurnError {
    return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        error.Cancelled => error.Cancelled,
        error.TimedOut => error.TimedOut,
        error.UnsupportedCapability => error.UnsupportedCapability,
        error.UnsupportedSetting => error.UnsupportedSetting,
        error.InvalidRequest => error.InvalidRequest,
        error.ConnectionFailed => error.ConnectionFailed,
        error.RateLimited => error.RateLimited,
        error.ProviderRejectedRequest => error.ProviderRejectedRequest,
        error.ProviderUnavailable => error.ProviderUnavailable,
        error.InvalidProviderResponse => error.InvalidProviderResponse,
        error.StreamInterrupted => error.StreamInterrupted,
        error.StreamConsumerStopped => error.EventConsumerStopped,
        error.HandoffRejected => error.HandoffRejected,
    };
}

fn observeProviderFailure(context: *anyopaque, provider_failure: ai_failure.ProviderFailure) void {
    const self: *Agent = @ptrCast(@alignCast(context));
    if (provider_failure.provider.len == 0 or
        provider_failure.provider.len > ai_failure.ProviderFailure.max_provider_bytes or
        provider_failure.message.len == 0 or
        provider_failure.message.len > ai_failure.ProviderFailure.max_message_bytes or
        !safeDiagnosticText(provider_failure.message)) return;

    const allocator = self.result_arena.allocator();
    const provider = allocator.dupe(u8, provider_failure.provider) catch return;
    const message = allocator.dupe(u8, provider_failure.message) catch return;
    self.provider_failure = .{
        .provider = provider,
        .status = provider_failure.status,
        .code = copyOptionalDiagnostic(
            allocator,
            provider_failure.code,
            ai_failure.ProviderFailure.max_code_bytes,
        ),
        .message = message,
        .request_id = copyOptionalDiagnostic(
            allocator,
            provider_failure.request_id,
            ai_failure.ProviderFailure.max_request_id_bytes,
        ),
        .retry_after_ms = provider_failure.retry_after_ms,
        .sensitive_data_redacted = provider_failure.sensitive_data_redacted,
    };
}

fn copyOptionalDiagnostic(
    allocator: std.mem.Allocator,
    value: ?[]const u8,
    max_bytes: usize,
) ?[]const u8 {
    const text = value orelse return null;
    if (text.len == 0 or text.len > max_bytes or !safeDiagnosticText(text)) return null;
    return allocator.dupe(u8, text) catch null;
}

fn safeDiagnosticText(value: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

const StreamEventAdapter = struct {
    agent: *Agent,
    run_id: event_api.RunId,
    turn_index: event_api.TurnIndex,
    accumulator: *ai_stream.ResponseAccumulator,
    failure: ?TurnError = null,

    fn emit(context: *anyopaque, event: ai_stream.StreamEvent) ai_stream.StreamSinkError!void {
        const self: *StreamEventAdapter = @ptrCast(@alignCast(context));
        const snapshot = self.accumulator.apply(event) catch |failure| {
            self.failure = switch (failure) {
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidStream => error.InvalidProviderResponse,
            };
            return switch (failure) {
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidStream => error.ConsumerStopped,
            };
        };
        self.agent.emit(.{ .message_update = .{
            .run_id = self.run_id,
            .turn_index = self.turn_index,
            .message = snapshot,
            .update = event,
        } }) catch |failure| {
            self.failure = failure;
            return switch (failure) {
                error.OutOfMemory => error.OutOfMemory,
                error.Cancelled => error.Cancelled,
                else => error.ConsumerStopped,
            };
        };
    }
};

fn validateResponseFinish(response: ai_message.ResponseMessage) error{ Cancelled, InvalidProviderResponse }!usize {
    const call_count = countToolCalls(response.parts);
    switch (response.finish.category) {
        .cancelled => return error.Cancelled,
        .provider_error => return error.InvalidProviderResponse,
        .tool_calls => if (call_count == 0) return error.InvalidProviderResponse,
        .stop, .content_filter, .unknown => if (call_count > 0) return error.InvalidProviderResponse,
        .length => {},
    }
    try validateToolCallIdentities(response.parts);
    return call_count;
}

fn validateToolCallIdentities(parts: []const ai_message.ResponsePart) error{InvalidProviderResponse}!void {
    for (parts, 0..) |part, index| switch (part) {
        .tool_call => |call| {
            if (call.id.len == 0 or call.name.len == 0) return error.InvalidProviderResponse;
            for (parts[0..index]) |earlier| switch (earlier) {
                .tool_call => |other| if (std.mem.eql(u8, call.id, other.id)) {
                    return error.InvalidProviderResponse;
                },
                else => {},
            };
        },
        else => {},
    };
}

fn countToolCalls(parts: []const ai_message.ResponsePart) usize {
    var count: usize = 0;
    for (parts) |part| switch (part) {
        .tool_call => count += 1,
        else => {},
    };
    return count;
}

fn collectText(allocator: std.mem.Allocator, parts: []const ai_message.ResponsePart) error{OutOfMemory}![]const u8 {
    var size: usize = 0;
    for (parts) |part| switch (part) {
        .text => |text| size = std.math.add(usize, size, text.text.len) catch return error.OutOfMemory,
        else => {},
    };
    const result = try allocator.alloc(u8, size);
    var offset: usize = 0;
    for (parts) |part| switch (part) {
        .text => |text| {
            @memcpy(result[offset..][0..text.text.len], text.text);
            offset += text.text.len;
        },
        else => {},
    };
    return result;
}

fn contentBytes(content: []const ai_message.Content) usize {
    var size: usize = 0;
    for (content) |item| switch (item) {
        .text => |text| size +|= text.len,
        .image => |image| {
            size +|= image.media_type.len;
            size +|= switch (image.source) {
                .bytes => |bytes| bytes.len,
                .url => |url| url.len,
            };
        },
    };
    return size;
}

fn copyContent(allocator: std.mem.Allocator, source: []const ai_message.Content) ![]const ai_message.Content {
    const content = try allocator.alloc(ai_message.Content, source.len);
    for (source, content) |item, *copy| copy.* = switch (item) {
        .text => |text| .{ .text = try allocator.dupe(u8, text) },
        .image => |image| .{ .image = .{
            .media_type = try allocator.dupe(u8, image.media_type),
            .source = switch (image.source) {
                .bytes => |bytes| .{ .bytes = try allocator.dupe(u8, bytes) },
                .url => |url| .{ .url = try allocator.dupe(u8, url) },
            },
        } },
    };
    return content;
}

const ai_testing = @import("../ai/testing.zig");
const agent_testing = @import("testing.zig");

const EventRecorder = struct {
    tags: [32]std.meta.Tag(Event) = undefined,
    count: usize = 0,

    fn emit(context: *anyopaque, event: Event) event_api.SinkError!void {
        const self: *EventRecorder = @ptrCast(@alignCast(context));
        self.tags[self.count] = std.meta.activeTag(event);
        self.count += 1;
    }
};

const SecondRequestRecorder = struct {
    valid: bool = false,

    fn observe(context: *anyopaque, index: usize, request: ai_model.ModelRequest) void {
        const self: *SecondRequestRecorder = @ptrCast(@alignCast(context));
        if (index != 1 or request.messages.len != 3) return;
        const result = request.messages[2].request.parts[0].tool_result;
        self.valid = result.outcome == .success and
            std.mem.eql(u8, result.call_id, "call-1") and
            std.mem.eql(u8, result.name, "read") and
            std.mem.eql(u8, result.content[0].text, "file contents");
    }
};

test "agent retains only bounded safe provider failure details" {
    var scripted_model: ai_testing.ScriptedModel = .{
        .identity = .{ .provider = "script", .model = "agent" },
        .steps = &.{.{ .text = "unused" }},
    };
    var agent = try Agent.init(
        std.testing.allocator,
        std.testing.io,
        scripted_model.asModel(),
        &.{},
        &.{},
        .{},
        null,
    );
    defer agent.deinit();

    var oversized_message = [_]u8{'x'} ** (ai_failure.ProviderFailure.max_message_bytes + 1);
    observeProviderFailure(&agent, .{
        .provider = "provider",
        .status = 400,
        .message = &oversized_message,
    });
    try std.testing.expect(agent.providerFailure() == null);

    var provider = [_]u8{ 'p', 'r', 'o', 'v', 'i', 'd', 'e', 'r' };
    var message = [_]u8{ 's', 'a', 'f', 'e' };
    var oversized_code = [_]u8{'x'} ** (ai_failure.ProviderFailure.max_code_bytes + 1);
    observeProviderFailure(&agent, .{
        .provider = &provider,
        .status = 429,
        .code = &oversized_code,
        .message = &message,
        .request_id = "unsafe\nrequest",
    });
    @memset(&provider, 'x');
    @memset(&message, 'x');

    const retained = agent.providerFailure().?;
    try std.testing.expectEqualStrings("provider", retained.provider);
    try std.testing.expectEqualStrings("safe", retained.message);
    try std.testing.expect(retained.code == null);
    try std.testing.expect(retained.request_id == null);
}

test "agent executes a tool and returns final text with owned canonical history" {
    var request_recorder: SecondRequestRecorder = .{};
    var scripted_model: ai_testing.ScriptedModel = .{
        .identity = .{ .provider = "script", .model = "agent" },
        .steps = &.{
            .{ .tool_call = .{ .id = "call-1", .name = "read", .arguments_json = "{\"path\":\"file\"}" } },
            .{ .text = "done" },
        },
        .request_observer = .{ .context = &request_recorder, .observeFn = SecondRequestRecorder.observe },
    };
    var scripted_tool: agent_testing.ScriptedTool = .{ .result = "file contents" };
    const definition: ai_message.ToolDefinition = .{
        .name = "read",
        .description = "Read a file",
        .parameters_json_schema = "{\"type\":\"object\"}",
    };
    const tool = tool_api.Tool.from(&scripted_tool, definition);
    var recorder: EventRecorder = .{};
    var cancellation: ai_model.CancellationToken = .{};
    var agent = try Agent.init(
        std.testing.allocator,
        std.testing.io,
        scripted_model.asModel(),
        &.{},
        &.{tool},
        .{},
        .{ .context = &recorder, .emitFn = EventRecorder.emit },
    );
    defer agent.deinit();

    const text = try agent.runWithControl("read the file.", .{ .cancellation = &cancellation });
    try std.testing.expectEqualStrings("done", text);
    try std.testing.expect(agent.state() == .ready);
    try std.testing.expectEqual(@as(usize, 2), agent.modelRequests());
    try std.testing.expectEqual(@as(usize, 1), agent.toolCalls());
    try std.testing.expectEqual(@as(usize, 1), scripted_tool.calls);
    try std.testing.expect(request_recorder.valid);
    try std.testing.expectEqual(@as(usize, 4), agent.messages().len);
    try std.testing.expectEqualStrings("read the file.", agent.messages()[0].request.parts[0].user.text);
    try std.testing.expectEqualStrings("read", agent.messages()[1].response.parts[0].tool_call.name);
    try std.testing.expectEqualStrings(
        "file contents",
        agent.messages()[2].request.parts[0].tool_result.content[0].text,
    );
    try std.testing.expectEqualStrings("done", agent.messages()[3].response.parts[0].text.text);
    const expected = [_]std.meta.Tag(Event){
        .agent_start,
        .turn_start,
        .message_start,
        .message_end,
        .message_start,
        .message_update,
        .message_update,
        .message_update,
        .message_end,
        .tool_execution_start,
        .tool_execution_end,
        .message_start,
        .message_end,
        .turn_end,
        .turn_start,
        .message_start,
        .message_update,
        .message_update,
        .message_update,
        .message_end,
        .turn_end,
        .agent_end,
    };
    try std.testing.expectEqualSlices(std.meta.Tag(Event), &expected, recorder.tags[0..recorder.count]);
}

test "pre-cancelled runs close their message and turn lifecycle" {
    var scripted_model: ai_testing.ScriptedModel = .{
        .identity = .{ .provider = "script", .model = "pre-cancelled" },
        .steps = &.{.{ .text = "never" }},
    };
    var recorder: EventRecorder = .{};
    var agent = try Agent.init(
        std.testing.allocator,
        std.testing.io,
        scripted_model.asModel(),
        &.{},
        &.{},
        .{},
        .{ .context = &recorder, .emitFn = EventRecorder.emit },
    );
    defer agent.deinit();
    var cancellation: ai_model.CancellationToken = .{};
    cancellation.cancel();

    try std.testing.expectError(
        error.Cancelled,
        agent.runWithControl("stop", .{ .cancellation = &cancellation }),
    );
    const expected = [_]std.meta.Tag(Event){
        .agent_start,
        .turn_start,
        .message_start,
        .message_end,
        .message_start,
        .message_end,
        .turn_end,
        .agent_end,
    };
    try std.testing.expectEqualSlices(std.meta.Tag(Event), &expected, recorder.tags[0..recorder.count]);
    try std.testing.expectEqual(@as(usize, 0), scripted_model.calls);
    try std.testing.expect(agent.state() == .ready);
}

test "agent enforces model request and tool call limits before excess work" {
    var scripted_model: ai_testing.ScriptedModel = .{
        .identity = .{ .provider = "script", .model = "limits" },
        .steps = &.{.{ .tool_call = .{ .id = "call", .name = "read", .arguments_json = "{}" } }},
    };
    var scripted_tool: agent_testing.ScriptedTool = .{ .result = "ok" };
    const tool = tool_api.Tool.from(&scripted_tool, .{
        .name = "read",
        .description = "",
        .parameters_json_schema = "{}",
    });
    var agent = try Agent.init(
        std.testing.allocator,
        std.testing.io,
        scripted_model.asModel(),
        &.{},
        &.{tool},
        .{ .max_tool_calls = 0 },
        null,
    );
    defer agent.deinit();
    try std.testing.expectError(error.MaxToolCallsExceeded, agent.run("go"));
    try std.testing.expect(agent.state() == .ready);
    try std.testing.expectEqual(@as(usize, 0), scripted_tool.calls);
}

test "recoverable tool failure is returned to the model" {
    var scripted_model: ai_testing.ScriptedModel = .{
        .identity = .{ .provider = "script", .model = "recover" },
        .steps = &.{
            .{ .tool_call = .{ .id = "call", .name = "read", .arguments_json = "{}" } },
            .{ .text = "recovered" },
        },
    };
    var scripted_tool: agent_testing.ScriptedTool = .{ .result = "cannot read", .recoverable_failure = true };
    const tool = tool_api.Tool.from(&scripted_tool, .{
        .name = "read",
        .description = "",
        .parameters_json_schema = "{}",
    });
    var agent = try Agent.init(
        std.testing.allocator,
        std.testing.io,
        scripted_model.asModel(),
        &.{},
        &.{tool},
        .{},
        null,
    );
    defer agent.deinit();
    try std.testing.expectEqualStrings("recovered", try agent.run("go"));
    const result = agent.messages()[2].request.parts[0].tool_result;
    try std.testing.expect(result.outcome == .failure);
    try std.testing.expectEqualStrings("cannot read", result.content[0].text);
}

test "length-truncated tool calls are returned as failures without execution" {
    var scripted_model: ai_testing.ScriptedModel = .{
        .identity = .{ .provider = "script", .model = "truncated" },
        .steps = &.{
            .{ .tool_call = .{
                .id = "call",
                .name = "read",
                .arguments_json = "{\"path\":\"partial\"}",
                .finish = .length,
            } },
            .{ .text = "reissued" },
        },
    };
    var scripted_tool: agent_testing.ScriptedTool = .{ .result = "must not execute" };
    const tool = scripted_tool.asTool(.{
        .name = "read",
        .description = "",
        .parameters_json_schema = "{}",
    });
    var agent = try Agent.init(
        std.testing.allocator,
        std.testing.io,
        scripted_model.asModel(),
        &.{},
        &.{tool},
        .{},
        null,
    );
    defer agent.deinit();
    try std.testing.expectEqualStrings("reissued", try agent.run("go"));
    try std.testing.expectEqual(@as(usize, 0), scripted_tool.calls);
    try std.testing.expect(agent.messages()[2].request.parts[0].tool_result.outcome == .failure);
}

test "model request limit stops before another model operation" {
    var scripted_model: ai_testing.ScriptedModel = .{
        .identity = .{ .provider = "script", .model = "model-limit" },
        .steps = &.{
            .{ .tool_call = .{ .id = "call", .name = "read", .arguments_json = "{}" } },
            .{ .text = "never" },
        },
    };
    var scripted_tool: agent_testing.ScriptedTool = .{ .result = "ok" };
    const tool = tool_api.Tool.from(&scripted_tool, .{
        .name = "read",
        .description = "",
        .parameters_json_schema = "{}",
    });
    var agent = try Agent.init(
        std.testing.allocator,
        std.testing.io,
        scripted_model.asModel(),
        &.{},
        &.{tool},
        .{ .max_model_requests = 1 },
        null,
    );
    defer agent.deinit();
    try std.testing.expectError(error.MaxModelRequestsExceeded, agent.run("go"));
    try std.testing.expectEqual(@as(usize, 1), scripted_model.calls);
    try std.testing.expectEqual(@as(usize, 3), agent.messages().len);
    try std.testing.expect(agent.state() == .ready);
}

test "oversized tool result removes its incomplete exchange from provider context" {
    var scripted_model: ai_testing.ScriptedModel = .{
        .identity = .{ .provider = "script", .model = "result-limit" },
        .steps = &.{.{ .tool_call = .{ .id = "call", .name = "read", .arguments_json = "{}" } }},
    };
    var scripted_tool: agent_testing.ScriptedTool = .{ .result = "large" };
    const tool = tool_api.Tool.from(&scripted_tool, .{
        .name = "read",
        .description = "",
        .parameters_json_schema = "{}",
    });
    var agent = try Agent.init(
        std.testing.allocator,
        std.testing.io,
        scripted_model.asModel(),
        &.{},
        &.{tool},
        .{ .max_tool_result_bytes = 4 },
        null,
    );
    defer agent.deinit();
    try std.testing.expectError(error.ToolResultTooLarge, agent.run("go"));
    try std.testing.expectEqual(@as(usize, 1), agent.messages().len);
    try std.testing.expect(agent.state() == .ready);
}

test "fatal tool cancellation is terminal cancellation" {
    var scripted_model: ai_testing.ScriptedModel = .{
        .identity = .{ .provider = "script", .model = "cancel" },
        .steps = &.{.{ .tool_call = .{ .id = "call", .name = "read", .arguments_json = "{}" } }},
    };
    var scripted_tool: agent_testing.ScriptedTool = .{ .result = "", .fatal = error.Cancelled };
    const tool = tool_api.Tool.from(&scripted_tool, .{
        .name = "read",
        .description = "",
        .parameters_json_schema = "{}",
    });
    var agent = try Agent.init(
        std.testing.allocator,
        std.testing.io,
        scripted_model.asModel(),
        &.{},
        &.{tool},
        .{},
        null,
    );
    defer agent.deinit();
    try std.testing.expectError(error.Cancelled, agent.run("go"));
    try std.testing.expect(agent.state() == .ready);
}

test "fatal tool timeout and allocation failure are terminal failures" {
    for ([_]tool_api.ToolFatalError{ error.TimedOut, error.OutOfMemory }) |fatal| {
        var scripted_model: ai_testing.ScriptedModel = .{
            .identity = .{ .provider = "script", .model = "fatal" },
            .steps = &.{.{ .tool_call = .{ .id = "call", .name = "read", .arguments_json = "{}" } }},
        };
        var scripted_tool: agent_testing.ScriptedTool = .{ .result = "", .fatal = fatal };
        const tool = tool_api.Tool.from(&scripted_tool, .{
            .name = "read",
            .description = "",
            .parameters_json_schema = "{}",
        });
        var agent = try Agent.init(
            std.testing.allocator,
            std.testing.io,
            scripted_model.asModel(),
            &.{},
            &.{tool},
            .{},
            null,
        );
        defer agent.deinit();
        try std.testing.expectError(fatal, agent.run("go"));
        try std.testing.expect(agent.state() == .ready);
    }
}

const MultiTurnRecorder = struct {
    first_valid: bool = false,
    second_valid: bool = false,

    fn observe(context: *anyopaque, index: usize, request: ai_model.ModelRequest) void {
        const self: *MultiTurnRecorder = @ptrCast(@alignCast(context));
        switch (index) {
            1 => self.first_valid = request.messages.len == 3 and
                std.mem.eql(u8, request.messages[0].request.parts[0].user.text, "first question") and
                std.mem.eql(u8, request.messages[1].response.parts[0].text.text, "first answer") and
                std.mem.eql(u8, request.messages[2].request.parts[0].user.text, "second question"),
            2 => self.second_valid = request.messages.len == 5 and
                std.mem.eql(u8, request.messages[3].response.parts[0].tool_call.name, "read") and
                request.messages[4].request.parts[0].tool_result.outcome == .success and
                std.mem.eql(u8, request.messages[4].request.parts[0].tool_result.content[0].text, "contents"),
            else => {},
        }
    }
};

test "agent completes one turn with owned canonical messages" {
    var scripted_model: ai_testing.ScriptedModel = .{
        .identity = .{ .provider = "script", .model = "one-turn" },
        .steps = &.{.{ .text = "answer one" }},
    };
    var agent = try Agent.init(
        std.testing.allocator,
        std.testing.io,
        scripted_model.asModel(),
        &.{},
        &.{},
        .{},
        null,
    );
    defer agent.deinit();

    const text = try agent.run("question one");
    try std.testing.expectEqualStrings("answer one", text);
    try std.testing.expect(agent.state() == .ready);
    try std.testing.expectEqual(@as(usize, 1), agent.modelRequests());
    try std.testing.expectEqual(@as(usize, 0), agent.toolCalls());
    try std.testing.expectEqual(@as(usize, 2), agent.messages().len);
    try std.testing.expectEqualStrings("question one", agent.messages()[0].request.parts[0].user.text);
    try std.testing.expectEqualStrings("answer one", agent.messages()[1].response.parts[0].text.text);
}

test "agent reuses completed turns and resets run limits" {
    var request_recorder: MultiTurnRecorder = .{};
    var scripted_model: ai_testing.ScriptedModel = .{
        .identity = .{ .provider = "script", .model = "multi-turn" },
        .steps = &.{
            .{ .text = "first answer" },
            .{ .tool_call = .{ .id = "call-1", .name = "read", .arguments_json = "{\"path\":\"a\"}" } },
            .{ .text = "second answer" },
        },
        .request_observer = .{ .context = &request_recorder, .observeFn = MultiTurnRecorder.observe },
    };
    var scripted_tool: agent_testing.ScriptedTool = .{ .result = "contents" };
    const tool = scripted_tool.asTool(.{
        .name = "read",
        .description = "",
        .parameters_json_schema = "{}",
    });
    var agent = try Agent.init(
        std.testing.allocator,
        std.testing.io,
        scripted_model.asModel(),
        &.{},
        &.{tool},
        .{ .max_model_requests = 2 },
        null,
    );
    defer agent.deinit();

    {
        const first_text = try agent.run("first question");
        try std.testing.expectEqualStrings("first answer", first_text);
        try std.testing.expect(agent.state() == .ready);
        try std.testing.expectEqual(@as(usize, 1), agent.modelRequests());
        try std.testing.expectEqual(@as(usize, 0), agent.toolCalls());
        try std.testing.expectEqual(@as(usize, 2), agent.messages().len);
    }

    {
        const second_text = try agent.run("second question");
        try std.testing.expectEqualStrings("second answer", second_text);
        try std.testing.expect(agent.state() == .ready);
        try std.testing.expectEqual(@as(usize, 2), agent.modelRequests());
        try std.testing.expectEqual(@as(usize, 1), agent.toolCalls());
        try std.testing.expectEqual(@as(usize, 1), scripted_tool.calls);
        try std.testing.expect(request_recorder.first_valid);
        try std.testing.expect(request_recorder.second_valid);
        try std.testing.expectEqual(@as(usize, 6), agent.messages().len);
        try std.testing.expectEqualStrings("first question", agent.messages()[0].request.parts[0].user.text);
        try std.testing.expectEqualStrings("first answer", agent.messages()[1].response.parts[0].text.text);
        try std.testing.expectEqualStrings("second question", agent.messages()[2].request.parts[0].user.text);
        try std.testing.expectEqualStrings("read", agent.messages()[3].response.parts[0].tool_call.name);
        try std.testing.expectEqualStrings(
            "contents",
            agent.messages()[4].request.parts[0].tool_result.content[0].text,
        );
        try std.testing.expectEqualStrings("second answer", agent.messages()[5].response.parts[0].text.text);
    }
}

test "completed turns accept fresh run cancellation control" {
    var scripted_model: ai_testing.ScriptedModel = .{
        .identity = .{ .provider = "script", .model = "fresh-control" },
        .steps = &.{ .{ .text = "first" }, .{ .text = "second" } },
    };
    var agent = try Agent.init(
        std.testing.allocator,
        std.testing.io,
        scripted_model.asModel(),
        &.{},
        &.{},
        .{},
        null,
    );
    defer agent.deinit();

    var first_control: ai_model.CancellationToken = .{};
    var second_control: ai_model.CancellationToken = .{};
    try std.testing.expectEqualStrings(
        "first",
        try agent.runWithControl("one", .{ .cancellation = &first_control }),
    );
    first_control.cancel();
    try std.testing.expectEqualStrings(
        "second",
        try agent.runWithControl("two", .{ .cancellation = &second_control }),
    );
    try std.testing.expect(agent.state() == .ready);
    try std.testing.expectEqual(@as(usize, 4), agent.messages().len);
}

test "agent accepts a fresh run after settled cancellation and failure" {
    {
        var cancelled_model: ai_testing.ScriptedModel = .{
            .identity = .{ .provider = "script", .model = "cancelled-run" },
            .steps = &.{
                .{ .tool_call = .{ .id = "call", .name = "read", .arguments_json = "{}" } },
                .{ .text = "recovered after cancellation" },
            },
        };
        var fatal_tool: agent_testing.ScriptedTool = .{ .result = "", .fatal = error.Cancelled };
        var agent = try Agent.init(
            std.testing.allocator,
            std.testing.io,
            cancelled_model.asModel(),
            &.{},
            &.{fatal_tool.asTool(.{ .name = "read", .description = "", .parameters_json_schema = "{}" })},
            .{},
            null,
        );
        defer agent.deinit();
        try std.testing.expectError(error.Cancelled, agent.run("stop me"));
        try std.testing.expect(agent.state() == .ready);
        try std.testing.expectEqualStrings("recovered after cancellation", try agent.run("again"));
        try std.testing.expect(agent.state() == .ready);
        try std.testing.expectEqual(@as(usize, 3), agent.messages().len);
        try std.testing.expectEqualStrings("stop me", agent.messages()[0].request.parts[0].user.text);
        try std.testing.expectEqualStrings("again", agent.messages()[1].request.parts[0].user.text);
    }

    {
        var failed_model: ai_testing.ScriptedModel = .{
            .identity = .{ .provider = "script", .model = "failed-run" },
            .steps = &.{
                .{ .tool_call = .{ .id = "call", .name = "read", .arguments_json = "{}" } },
                .{ .text = "recovered after failure" },
            },
        };
        var quiet_tool: agent_testing.ScriptedTool = .{ .result = "x" };
        var agent = try Agent.init(
            std.testing.allocator,
            std.testing.io,
            failed_model.asModel(),
            &.{},
            &.{quiet_tool.asTool(.{ .name = "read", .description = "", .parameters_json_schema = "{}" })},
            .{ .max_tool_calls = 0 },
            null,
        );
        defer agent.deinit();
        try std.testing.expectError(error.MaxToolCallsExceeded, agent.run("limit me"));
        try std.testing.expect(agent.state() == .ready);
        try std.testing.expectEqualStrings("recovered after failure", try agent.run("again"));
        try std.testing.expect(agent.state() == .ready);
        try std.testing.expectEqual(@as(usize, 3), agent.messages().len);
        try std.testing.expectEqualStrings("limit me", agent.messages()[0].request.parts[0].user.text);
        try std.testing.expectEqualStrings("again", agent.messages()[1].request.parts[0].user.text);
    }
}

test "agent rejects reentrant runs until terminal events settle" {
    var scripted_model: ai_testing.ScriptedModel = .{
        .identity = .{ .provider = "script", .model = "reenter" },
        .steps = &.{.{ .text = "answer" }},
    };
    var agent = try Agent.init(
        std.testing.allocator,
        std.testing.io,
        scripted_model.asModel(),
        &.{},
        &.{},
        .{},
        null,
    );
    defer agent.deinit();

    const ReentrantRecorder = struct {
        const Self = @This();
        agent: *Agent,
        turn_start_rejected: bool = false,
        agent_end_rejected: bool = false,

        fn emit(context: *anyopaque, event: Event) event_api.SinkError!void {
            const self: *Self = @ptrCast(@alignCast(context));
            if (event != .turn_start and event != .agent_end) return;
            const attempt = self.agent.run("nested");
            const rejected = if (attempt) |_| false else |failure| failure == error.AlreadyRun;
            if (event == .turn_start) self.turn_start_rejected = rejected;
            if (event == .agent_end) self.agent_end_rejected = rejected;
        }
    };
    var recorder: ReentrantRecorder = .{ .agent = &agent };
    agent.events = .{ .context = &recorder, .emitFn = ReentrantRecorder.emit };

    const text = try agent.run("outer");
    try std.testing.expectEqualStrings("answer", text);
    try std.testing.expect(recorder.turn_start_rejected);
    try std.testing.expect(recorder.agent_end_rejected);
    try std.testing.expect(agent.state() == .ready);
    try std.testing.expectEqual(@as(usize, 1), agent.modelRequests());
    try std.testing.expectEqual(@as(usize, 2), agent.messages().len);
}

const StreamCollector = struct {
    const Entry = struct {
        turn_index: event_api.TurnIndex,
        tag: std.meta.Tag(ai_stream.StreamEvent),
    };

    entries: [32]Entry = undefined,
    count: usize = 0,
    completed_tool_call_valid: bool = false,

    fn emit(context: *anyopaque, value: Event) event_api.SinkError!void {
        const self: *StreamCollector = @ptrCast(@alignCast(context));
        const update = switch (value) {
            .message_update => |event| event,
            else => return,
        };
        self.entries[self.count] = .{
            .turn_index = update.turn_index,
            .tag = std.meta.activeTag(update.update),
        };
        self.count += 1;
        if (update.update == .part_end and update.update.part_end.part == .tool_call) {
            self.completed_tool_call_valid = std.mem.eql(
                u8,
                update.update.part_end.part.tool_call.arguments_json,
                "{\"path\":\"file\"}",
            );
        }
    }
};

test "agent streams a tool loop with owned canonical history" {
    var scripted_model: ai_testing.ScriptedModel = .{
        .identity = .{ .provider = "script", .model = "stream-loop" },
        .steps = &.{
            .{ .tool_call = .{ .id = "call-1", .name = "read", .arguments_json = "{\"path\":\"file\"}" } },
            .{ .text = "streamed final" },
        },
    };
    var scripted_tool: agent_testing.ScriptedTool = .{ .result = "streamed contents" };
    const tool = scripted_tool.asTool(.{
        .name = "read",
        .description = "",
        .parameters_json_schema = "{}",
    });
    var collector: StreamCollector = .{};
    var agent = try Agent.init(
        std.testing.allocator,
        std.testing.io,
        scripted_model.asModel(),
        &.{},
        &.{tool},
        .{},
        .{ .context = &collector, .emitFn = StreamCollector.emit },
    );
    defer agent.deinit();

    const text = try agent.run("read the file.");
    try std.testing.expectEqualStrings("streamed final", text);
    try std.testing.expect(agent.state() == .ready);
    try std.testing.expectEqual(@as(usize, 2), agent.modelRequests());
    try std.testing.expectEqual(@as(usize, 1), agent.toolCalls());
    try std.testing.expectEqual(@as(usize, 1), scripted_tool.calls);
    try std.testing.expectEqual(@as(usize, 4), agent.messages().len);
    try std.testing.expectEqualStrings("read the file.", agent.messages()[0].request.parts[0].user.text);
    try std.testing.expectEqualStrings("read", agent.messages()[1].response.parts[0].tool_call.name);
    try std.testing.expectEqualStrings(
        "streamed contents",
        agent.messages()[2].request.parts[0].tool_result.content[0].text,
    );
    try std.testing.expectEqualStrings("streamed final", agent.messages()[3].response.parts[0].text.text);

    try std.testing.expectEqual(@as(usize, 6), collector.count);
    for (collector.entries[0..3]) |entry| {
        try std.testing.expectEqual(@as(event_api.TurnIndex, 1), entry.turn_index);
    }
    for (collector.entries[3..6]) |entry| {
        try std.testing.expectEqual(@as(event_api.TurnIndex, 2), entry.turn_index);
    }
    try std.testing.expectEqual(.part_start, collector.entries[0].tag);
    try std.testing.expectEqual(.part_end, collector.entries[2].tag);
    try std.testing.expect(collector.completed_tool_call_valid);
    try std.testing.expectEqual(.part_start, collector.entries[3].tag);
}

const EventFailSink = struct {
    failure: event_api.SinkError,

    fn emit(context: *anyopaque, event: Event) event_api.SinkError!void {
        const self: *EventFailSink = @ptrCast(@alignCast(context));
        if (event == .message_update) return self.failure;
    }
};

fn expectEventFailureDoesNotCommit(
    failure: event_api.SinkError,
    expected: RunError,
    expected_state_tag: StateTag,
) !void {
    var scripted_model: ai_testing.ScriptedModel = .{
        .identity = .{ .provider = "script", .model = "stream-fail" },
        .steps = &.{.{ .text = "partial" }},
    };
    var agent = try Agent.init(
        std.testing.allocator,
        std.testing.io,
        scripted_model.asModel(),
        &.{},
        &.{},
        .{},
        null,
    );
    defer agent.deinit();
    var sink_state: EventFailSink = .{ .failure = failure };
    agent.events = .{ .context = &sink_state, .emitFn = EventFailSink.emit };

    try std.testing.expectError(expected, agent.run("go"));
    try std.testing.expectEqual(expected_state_tag, std.meta.activeTag(agent.state()));
    try std.testing.expectEqual(@as(usize, 1), agent.messages().len);
    try std.testing.expectEqualStrings("go", agent.messages()[0].request.parts[0].user.text);
}

test "agent event sink failures commit no partial response" {
    try expectEventFailureDoesNotCommit(error.ConsumerStopped, error.EventConsumerStopped, .ready);
    try expectEventFailureDoesNotCommit(error.OutOfMemory, error.OutOfMemory, .ready);
    try expectEventFailureDoesNotCommit(error.Cancelled, error.Cancelled, .ready);
}

fn expectFatalFinishDoesNotCommit(
    finish: ai_usage.FinishCategory,
    expected: RunError,
    expected_state_tag: StateTag,
) !void {
    var scripted_model: ai_testing.ScriptedModel = .{
        .identity = .{ .provider = "script", .model = "fatal-finish" },
        .steps = &.{.{ .tool_call = .{
            .id = "partial-call",
            .name = "read",
            .arguments_json = "{}",
            .finish = finish,
        } }},
    };
    var agent = try Agent.init(
        std.testing.allocator,
        std.testing.io,
        scripted_model.asModel(),
        &.{},
        &.{},
        .{},
        null,
    );
    defer agent.deinit();
    var collector: StreamCollector = .{};
    agent.events = .{ .context = &collector, .emitFn = StreamCollector.emit };

    try std.testing.expectError(expected, agent.run("go"));
    try std.testing.expect(collector.count > 0);
    try std.testing.expectEqual(expected_state_tag, std.meta.activeTag(agent.state()));
    try std.testing.expectEqual(@as(usize, 1), agent.messages().len);
    try std.testing.expectEqualStrings("go", agent.messages()[0].request.parts[0].user.text);
}

test "indeterminate message publication poisons the live agent" {
    const Commits = struct {
        const Self = @This();

        messages: usize = 0,
        settlements: usize = 0,

        fn message(
            context: *anyopaque,
            _: commit_api.MessageKind,
            _: ai_message.Message,
        ) commit_api.Error!void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.messages += 1;
            if (self.messages == 2) return error.CommitIndeterminate;
        }

        fn settle(
            context: *anyopaque,
            _: commit_api.RunOutcome,
        ) commit_api.Error!void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.settlements += 1;
        }
    };

    var scripted_model: ai_testing.ScriptedModel = .{
        .identity = .{ .provider = "script", .model = "indeterminate" },
        .steps = &.{.{ .text = "uncertain" }},
    };
    var commits: Commits = .{};
    var agent = try Agent.init(
        std.testing.allocator,
        std.testing.io,
        scripted_model.asModel(),
        &.{},
        &.{},
        .{},
        null,
    );
    defer agent.deinit();
    try agent.bindCommits(&.{}, .{
        .context = &commits,
        .messageFn = Commits.message,
        .settleFn = Commits.settle,
    });

    try std.testing.expectError(error.CommitIndeterminate, agent.run("question"));
    try std.testing.expect(agent.state() == .poisoned);
    try std.testing.expectEqual(@as(usize, 0), commits.settlements);
    try std.testing.expectError(error.SessionUnavailable, agent.run("again"));
}

test "fatal streamed finishes commit no partial response" {
    try expectFatalFinishDoesNotCommit(.cancelled, error.Cancelled, .ready);
    try expectFatalFinishDoesNotCommit(.provider_error, error.InvalidProviderResponse, .ready);
}

fn expectNonToolFinishRejectsToolCalls(finish: ai_usage.FinishCategory) !void {
    var scripted_model: ai_testing.ScriptedModel = .{
        .identity = .{ .provider = "script", .model = "invalid-tool-finish" },
        .steps = &.{.{ .tool_call = .{
            .id = "call-1",
            .name = "read",
            .arguments_json = "{}",
            .finish = finish,
        } }},
    };
    var scripted_tool: agent_testing.ScriptedTool = .{ .result = "must not run" };
    const tool = scripted_tool.asTool(.{
        .name = "read",
        .description = "",
        .parameters_json_schema = "{}",
    });
    var agent = try Agent.init(
        std.testing.allocator,
        std.testing.io,
        scripted_model.asModel(),
        &.{},
        &.{tool},
        .{},
        null,
    );
    defer agent.deinit();

    try std.testing.expectError(error.InvalidProviderResponse, agent.run("go"));
    try std.testing.expectEqual(@as(usize, 0), scripted_tool.calls);
    try std.testing.expectEqual(@as(usize, 0), agent.toolCalls());
    try std.testing.expectEqual(@as(usize, 1), agent.messages().len);
    try std.testing.expect(agent.state() == .ready);
}

test "only tool-call finishes authorize local tool execution" {
    try expectNonToolFinishRejectsToolCalls(.stop);
    try expectNonToolFinishRejectsToolCalls(.content_filter);
    try expectNonToolFinishRejectsToolCalls(.unknown);

    var scripted_model: ai_testing.ScriptedModel = .{
        .identity = .{ .provider = "script", .model = "missing-tool-call" },
        .steps = &.{.{ .text_finish = .{ .text = "inconsistent", .finish = .tool_calls } }},
    };
    var agent = try Agent.init(
        std.testing.allocator,
        std.testing.io,
        scripted_model.asModel(),
        &.{},
        &.{},
        .{},
        null,
    );
    defer agent.deinit();

    try std.testing.expectError(error.InvalidProviderResponse, agent.run("go"));
    try std.testing.expectEqual(@as(usize, 1), agent.messages().len);
    try std.testing.expect(agent.state() == .ready);
}

fn expectInvalidToolIdentities(calls: []const ai_testing.ScriptedStep.ToolCall) !void {
    var scripted_model: ai_testing.ScriptedModel = .{
        .identity = .{ .provider = "script", .model = "invalid-tool-identities" },
        .steps = &.{.{ .tool_calls = .{ .calls = calls } }},
    };
    var scripted_tool: agent_testing.ScriptedTool = .{ .result = "must not run" };
    const tool = scripted_tool.asTool(.{
        .name = "read",
        .description = "",
        .parameters_json_schema = "{}",
    });
    var agent = try Agent.init(
        std.testing.allocator,
        std.testing.io,
        scripted_model.asModel(),
        &.{},
        &.{tool},
        .{},
        null,
    );
    defer agent.deinit();

    try std.testing.expectError(error.InvalidProviderResponse, agent.run("go"));
    try std.testing.expectEqual(@as(usize, 0), scripted_tool.calls);
    try std.testing.expectEqual(@as(usize, 0), agent.toolCalls());
    try std.testing.expectEqual(@as(usize, 1), agent.messages().len);
}

test "tool execution requires non-empty unique call identities" {
    const duplicate = [_]ai_testing.ScriptedStep.ToolCall{
        .{ .id = "same", .name = "read", .arguments_json = "{}" },
        .{ .id = "same", .name = "read", .arguments_json = "{}" },
    };
    const empty_id = [_]ai_testing.ScriptedStep.ToolCall{
        .{ .id = "", .name = "read", .arguments_json = "{}" },
    };
    const empty_name = [_]ai_testing.ScriptedStep.ToolCall{
        .{ .id = "call", .name = "", .arguments_json = "{}" },
    };
    try expectInvalidToolIdentities(&duplicate);
    try expectInvalidToolIdentities(&empty_id);
    try expectInvalidToolIdentities(&empty_name);
}

test "failed tool batches are removed from provider context" {
    const calls = [_]ai_testing.ScriptedStep.ToolCall{
        .{ .id = "call-1", .name = "first", .arguments_json = "{}" },
        .{ .id = "call-2", .name = "second", .arguments_json = "{}" },
    };
    var scripted_model: ai_testing.ScriptedModel = .{
        .identity = .{ .provider = "script", .model = "partial-tool-batch" },
        .steps = &.{.{ .tool_calls = .{ .calls = &calls } }},
    };
    var first_tool: agent_testing.ScriptedTool = .{ .result = "first complete" };
    var second_tool: agent_testing.ScriptedTool = .{ .result = "", .fatal = error.TimedOut };
    const tools = [_]tool_api.Tool{
        first_tool.asTool(.{ .name = "first", .description = "", .parameters_json_schema = "{}" }),
        second_tool.asTool(.{ .name = "second", .description = "", .parameters_json_schema = "{}" }),
    };
    var agent = try Agent.init(
        std.testing.allocator,
        std.testing.io,
        scripted_model.asModel(),
        &.{},
        &tools,
        .{},
        null,
    );
    defer agent.deinit();

    try std.testing.expectError(error.TimedOut, agent.run("go"));
    try std.testing.expectEqual(@as(usize, 1), first_tool.calls);
    try std.testing.expectEqual(@as(usize, 1), second_tool.calls);
    try std.testing.expectEqual(@as(usize, 2), agent.toolCalls());
    try std.testing.expectEqual(@as(usize, 1), agent.messages().len);
    try std.testing.expectEqualStrings("go", agent.messages()[0].request.parts[0].user.text);
    try std.testing.expect(agent.state() == .ready);
}

const CancelOnToolCompletion = struct {
    token: *ai_model.CancellationToken,

    fn emit(context: *anyopaque, event: Event) event_api.SinkError!void {
        const self: *CancelOnToolCompletion = @ptrCast(@alignCast(context));
        if (event == .tool_execution_end) self.token.cancel();
    }
};

test "late cancellation preserves a completed tool result" {
    var scripted_model: ai_testing.ScriptedModel = .{
        .identity = .{ .provider = "script", .model = "late-cancellation" },
        .steps = &.{.{ .tool_call = .{ .id = "call-1", .name = "read", .arguments_json = "{}" } }},
    };
    var scripted_tool: agent_testing.ScriptedTool = .{ .result = "completed" };
    const tool = scripted_tool.asTool(.{
        .name = "read",
        .description = "",
        .parameters_json_schema = "{}",
    });
    var token: ai_model.CancellationToken = .{};
    var events: CancelOnToolCompletion = .{ .token = &token };
    var agent = try Agent.init(
        std.testing.allocator,
        std.testing.io,
        scripted_model.asModel(),
        &.{},
        &.{tool},
        .{},
        .{ .context = &events, .emitFn = CancelOnToolCompletion.emit },
    );
    defer agent.deinit();

    try std.testing.expectError(error.Cancelled, agent.runWithControl("go", .{ .cancellation = &token }));
    try std.testing.expectEqual(@as(usize, 1), scripted_tool.calls);
    try std.testing.expectEqual(@as(usize, 3), agent.messages().len);
    try std.testing.expectEqualStrings(
        "completed",
        agent.messages()[2].request.parts[0].tool_result.content[0].text,
    );
    try std.testing.expect(agent.state() == .ready);
}

test "agent falls back to buffered models and preflights tool capabilities" {
    var no_stream_model: ai_testing.ScriptedModel = .{
        .identity = .{ .provider = "script", .model = "buffered-only" },
        .steps = &.{.{ .text = "never" }},
    };
    var no_stream_agent = try Agent.init(
        std.testing.allocator,
        std.testing.io,
        ai_model.Model.from(&no_stream_model, no_stream_model.identity, .{}),
        &.{},
        &.{},
        .{},
        null,
    );
    defer no_stream_agent.deinit();

    try std.testing.expectEqualStrings("never", try no_stream_agent.run("submitted"));
    try std.testing.expectEqual(@as(usize, 1), no_stream_model.calls);
    try std.testing.expectEqual(@as(usize, 2), no_stream_agent.messages().len);
    try std.testing.expect(no_stream_agent.state() == .ready);

    var no_tools_model: ai_testing.ScriptedModel = .{
        .identity = .{ .provider = "script", .model = "without-tools" },
        .steps = &.{.{ .text = "never" }},
    };
    var scripted_tool: agent_testing.ScriptedTool = .{ .result = "never" };
    const tool = scripted_tool.asTool(.{
        .name = "read",
        .description = "",
        .parameters_json_schema = "{}",
    });
    var no_tools_agent = try Agent.init(
        std.testing.allocator,
        std.testing.io,
        ai_model.Model.from(&no_tools_model, no_tools_model.identity, .{}),
        &.{},
        &.{tool},
        .{},
        null,
    );
    defer no_tools_agent.deinit();

    try std.testing.expectError(error.UnsupportedCapability, no_tools_agent.run("not submitted"));
    try std.testing.expectEqual(@as(usize, 0), no_tools_model.calls);
    try std.testing.expectEqual(@as(usize, 0), no_tools_agent.messages().len);
    try std.testing.expect(no_tools_agent.state() == .ready);
}

const StreamedRunRecorder = struct {
    valid: bool = false,

    fn observe(context: *anyopaque, index: usize, request: ai_model.ModelRequest) void {
        const self: *StreamedRunRecorder = @ptrCast(@alignCast(context));
        if (index != 1) return;
        self.valid = request.messages.len == 3 and
            std.mem.eql(u8, request.messages[0].request.parts[0].user.text, "first stream") and
            std.mem.eql(u8, request.messages[1].response.parts[0].text.text, "first answer") and
            std.mem.eql(u8, request.messages[2].request.parts[0].user.text, "second stream");
    }
};

test "streamed completed turns preserve history across fresh runs" {
    var request_recorder: StreamedRunRecorder = .{};
    var scripted_model: ai_testing.ScriptedModel = .{
        .identity = .{ .provider = "script", .model = "stream-reuse" },
        .steps = &.{ .{ .text = "first answer" }, .{ .text = "second answer" } },
        .request_observer = .{ .context = &request_recorder, .observeFn = StreamedRunRecorder.observe },
    };
    var agent = try Agent.init(
        std.testing.allocator,
        std.testing.io,
        scripted_model.asModel(),
        &.{},
        &.{},
        .{},
        null,
    );
    defer agent.deinit();
    var first_collector: StreamCollector = .{};
    var second_collector: StreamCollector = .{};

    agent.events = .{ .context = &first_collector, .emitFn = StreamCollector.emit };
    try std.testing.expectEqualStrings("first answer", try agent.run("first stream"));
    agent.events = .{ .context = &second_collector, .emitFn = StreamCollector.emit };
    try std.testing.expectEqualStrings("second answer", try agent.run("second stream"));
    try std.testing.expect(agent.state() == .ready);
    try std.testing.expect(request_recorder.valid);
    try std.testing.expectEqual(@as(usize, 4), agent.messages().len);
    try std.testing.expectEqual(@as(event_api.TurnIndex, 1), second_collector.entries[0].turn_index);
}
