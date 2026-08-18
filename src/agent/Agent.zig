const std = @import("std");
const ai_message = @import("../ai/message.zig");
const ai_model = @import("../ai/model.zig");
const ai_stream = @import("../ai/stream.zig");
const ai_usage = @import("../ai/usage.zig");
const History = @import("History.zig");
const tool_api = @import("Tool.zig");
const limit_api = @import("limits.zig");

const Agent = @This();

pub const State = union(enum) {
    idle,
    requesting_model: struct { number: usize },
    executing_tools: struct { first: usize, count: usize },
    completed,
    failed,
    cancelled,
};

pub const StateTag = std.meta.Tag(State);

pub const ToolOutcome = enum { success, failure };

pub const RunControl = struct {
    cancellation: ?*const ai_model.CancellationToken = null,
    deadline: ?std.Io.Clock.Timestamp = null,
};

pub const Event = union(enum) {
    state_changed: struct { from: StateTag, to: StateTag },
    model_request_started: struct { number: usize },
    model_request_completed: struct { number: usize },
    tool_execution_started: struct { number: usize, call_id: []const u8, name: []const u8 },
    tool_execution_completed: struct {
        number: usize,
        call_id: []const u8,
        name: []const u8,
        outcome: ToolOutcome,
    },
};

pub const EventSink = struct {
    context: *anyopaque,
    emitFn: *const fn (context: *anyopaque, event: Event) void,

    pub fn emit(self: EventSink, event: Event) void {
        self.emitFn(self.context, event);
    }
};

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
    StreamConsumerStopped,
    HandoffRejected,
    MaxModelRequestsExceeded,
    MaxToolCallsExceeded,
    ToolResultTooLarge,
    ToolControlUnavailable,
    AlreadyRun,
};

allocator: std.mem.Allocator,
io: std.Io,
model: ai_model.Model,
/// Borrowed immutable policy; its storage must outlive the agent.
instructions: []const []const u8,
catalog: tool_api.Catalog,
history: History,
result_arena: std.heap.ArenaAllocator,
run_state: State = .idle,
limits: limit_api.RunLimits,
events: ?EventSink,
model_request_count: usize = 0,
tool_call_count: usize = 0,
run_admitted: bool = false,

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

pub const StreamEvent = struct {
    request_number: usize,
    event: ai_stream.StreamEvent,
};

/// Event payload slices are borrowed for the duration of emitFn.
pub const StreamSink = struct {
    context: *anyopaque,
    emitFn: *const fn (context: *anyopaque, event: StreamEvent) ai_stream.StreamSinkError!void,

    pub fn emit(self: StreamSink, event: StreamEvent) ai_stream.StreamSinkError!void {
        return self.emitFn(self.context, event);
    }
};

const Delivery = union(enum) {
    buffered,
    streaming: StreamSink,
};

/// The returned final text remains valid until the next admitted run or deinit.
pub fn run(self: *Agent, input: []const u8) RunError![]const u8 {
    return self.runWithControl(input, .{});
}

pub fn runWithControl(self: *Agent, input: []const u8, control: RunControl) RunError![]const u8 {
    return self.runInternal(input, control, .buffered);
}

/// The returned final text remains valid until the next admitted run or deinit.
pub fn runStream(self: *Agent, input: []const u8, sink: StreamSink) RunError![]const u8 {
    return self.runStreamWithControl(input, sink, .{});
}

pub fn runStreamWithControl(
    self: *Agent,
    input: []const u8,
    sink: StreamSink,
    control: RunControl,
) RunError![]const u8 {
    return self.runInternal(input, control, .{ .streaming = sink });
}

fn runInternal(self: *Agent, input: []const u8, control: RunControl, delivery: Delivery) RunError![]const u8 {
    if (self.run_admitted) return error.AlreadyRun;
    if (self.run_state != .idle and self.run_state != .completed) return error.AlreadyRun;
    try self.preflight(delivery);

    self.run_admitted = true;
    defer self.run_admitted = false;
    self.result_arena.deinit();
    self.result_arena = std.heap.ArenaAllocator.init(self.allocator);
    self.model_request_count = 0;
    self.tool_call_count = 0;

    self.history.appendRequest(.{ .parts = &.{.{ .user = .{ .text = input } }} }) catch |failure| {
        self.fail(failure);
        return failure;
    };

    while (true) {
        self.checkControl(control) catch |failure| {
            self.fail(failure);
            return failure;
        };
        if (self.model_request_count >= self.limits.max_model_requests) {
            self.fail(error.MaxModelRequestsExceeded);
            return error.MaxModelRequestsExceeded;
        }
        self.model_request_count += 1;
        self.transition(.{ .requesting_model = .{ .number = self.model_request_count } });
        self.emit(.{ .model_request_started = .{ .number = self.model_request_count } });

        var definitions: std.ArrayList(ai_message.ToolDefinition) = .empty;
        defer definitions.deinit(self.allocator);
        for (self.catalog.tools.items) |tool| definitions.append(self.allocator, tool.definition) catch |failure| {
            self.fail(failure);
            return failure;
        };

        var response = self.invokeModel(control, delivery, definitions.items) catch |failure| {
            self.fail(failure);
            return failure;
        };
        const call_count = validateResponseFinish(response.value) catch |failure| {
            response.deinit();
            self.fail(failure);
            return failure;
        };
        self.history.appendResponse(response.value) catch |failure| {
            response.deinit();
            self.fail(failure);
            return failure;
        };
        response.deinit();
        self.emit(.{ .model_request_completed = .{ .number = self.model_request_count } });
        self.checkControl(control) catch |failure| {
            self.fail(failure);
            return failure;
        };

        const stored_response = self.history.messages()[self.history.messages().len - 1].response;
        if (call_count == 0) {
            const text = collectText(self.result_arena.allocator(), stored_response.parts) catch |failure| {
                self.fail(failure);
                return failure;
            };
            self.transition(.completed);
            return text;
        }
        if (call_count > self.limits.max_tool_calls -| self.tool_call_count) {
            self.fail(error.MaxToolCallsExceeded);
            return error.MaxToolCallsExceeded;
        }

        const first_call = self.tool_call_count + 1;
        self.transition(.{ .executing_tools = .{ .first = first_call, .count = call_count } });
        for (stored_response.parts) |part| switch (part) {
            .tool_call => |call| {
                self.tool_call_count += 1;
                const number = self.tool_call_count;
                self.emit(.{ .tool_execution_started = .{
                    .number = number,
                    .call_id = call.id,
                    .name = call.name,
                } });
                var result_arena = std.heap.ArenaAllocator.init(self.allocator);
                defer result_arena.deinit();
                const result_memory = result_arena.allocator();
                const result = if (stored_response.finish.category == .length)
                    self.failureResult(
                        result_memory,
                        call,
                        "Tool call was not executed because the model response was truncated.",
                    ) catch |failure| {
                        self.fail(failure);
                        return failure;
                    }
                else
                    self.executeTool(result_memory, call, control) catch |failure| {
                        self.fail(failure);
                        return failure;
                    };
                self.emit(.{ .tool_execution_completed = .{
                    .number = number,
                    .call_id = call.id,
                    .name = call.name,
                    .outcome = if (result.outcome == .success) .success else .failure,
                } });
                const result_parts = [_]ai_message.RequestPart{.{ .tool_result = result }};
                self.history.appendRequest(.{ .parts = &result_parts }) catch |failure| {
                    self.fail(failure);
                    return failure;
                };
                self.checkControl(control) catch |failure| {
                    self.fail(failure);
                    return failure;
                };
            },
            else => {},
        };
    }
}

fn executeTool(
    self: *Agent,
    allocator: std.mem.Allocator,
    call: ai_message.ToolCall,
    control: RunControl,
) RunError!ai_message.ToolResult {
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
) RunError!tool_api.ToolExecution {
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
) RunError!ai_message.ToolResult {
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

fn transition(self: *Agent, next: State) void {
    const previous = std.meta.activeTag(self.run_state);
    self.run_state = next;
    self.emit(.{ .state_changed = .{ .from = previous, .to = std.meta.activeTag(next) } });
}

fn fail(self: *Agent, failure: anytype) void {
    if (failure == error.Cancelled) self.transition(.cancelled) else self.transition(.failed);
}

fn emit(self: *Agent, event: Event) void {
    if (self.events) |sink| sink.emit(event);
}

fn checkControl(self: *const Agent, control: RunControl) ai_model.ModelError!void {
    if (control.cancellation) |token| if (token.isCancelled()) return error.Cancelled;
    if (control.deadline) |deadline| {
        const now = std.Io.Clock.Timestamp.now(self.io, deadline.clock);
        if (now.durationTo(deadline).raw.nanoseconds <= 0) return error.TimedOut;
    }
}

fn preflight(self: *const Agent, delivery: Delivery) error{UnsupportedCapability}!void {
    if (self.catalog.tools.items.len > 0 and !self.model.profile.supports(.tools)) {
        return error.UnsupportedCapability;
    }
    if (delivery == .streaming and !self.model.profile.supports(.streaming)) {
        return error.UnsupportedCapability;
    }
}

fn invokeModel(
    self: *Agent,
    control: RunControl,
    delivery: Delivery,
    tools: []const ai_message.ToolDefinition,
) RunError!ai_model.OwnedResponse {
    const request: ai_model.ModelRequest = .{
        .messages = self.history.messages(),
        .instructions = self.instructions,
        .tools = tools,
        .deadline = control.deadline,
        .cancellation = control.cancellation,
    };
    return switch (delivery) {
        .buffered => self.model.complete(self.allocator, self.io, request),
        .streaming => |sink| stream: {
            var adapter = StreamSinkAdapter{
                .request_number = self.model_request_count,
                .sink = sink,
            };
            break :stream self.model.stream(self.allocator, self.io, request, .{
                .context = &adapter,
                .emitFn = StreamSinkAdapter.emit,
            });
        },
    };
}

const StreamSinkAdapter = struct {
    request_number: usize,
    sink: StreamSink,

    fn emit(context: *anyopaque, event: ai_stream.StreamEvent) ai_stream.StreamSinkError!void {
        const self: *StreamSinkAdapter = @ptrCast(@alignCast(context));
        return self.sink.emit(.{ .request_number = self.request_number, .event = event });
    }
};

fn validateResponseFinish(response: ai_message.ResponseMessage) RunError!usize {
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
    events: [16]Event = undefined,
    count: usize = 0,

    fn emit(context: *anyopaque, event: Event) void {
        const self: *EventRecorder = @ptrCast(@alignCast(context));
        self.events[self.count] = event;
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
    try std.testing.expect(agent.state() == .completed);
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
        .state_changed,
        .model_request_started,
        .model_request_completed,
        .state_changed,
        .tool_execution_started,
        .tool_execution_completed,
        .state_changed,
        .model_request_started,
        .model_request_completed,
        .state_changed,
    };
    try std.testing.expectEqual(expected.len, recorder.count);
    for (expected, recorder.events[0..recorder.count]) |tag, event| {
        try std.testing.expectEqual(tag, std.meta.activeTag(event));
    }
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
    try std.testing.expect(agent.state() == .failed);
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
    try std.testing.expect(agent.state() == .failed);
}

test "oversized tool result is not committed" {
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
    try std.testing.expectEqual(@as(usize, 2), agent.messages().len);
    try std.testing.expect(agent.state() == .failed);
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
    try std.testing.expect(agent.state() == .cancelled);
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
        try std.testing.expect(agent.state() == .failed);
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
    try std.testing.expect(agent.state() == .completed);
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
        try std.testing.expect(agent.state() == .completed);
        try std.testing.expectEqual(@as(usize, 1), agent.modelRequests());
        try std.testing.expectEqual(@as(usize, 0), agent.toolCalls());
        try std.testing.expectEqual(@as(usize, 2), agent.messages().len);
    }

    {
        const second_text = try agent.run("second question");
        try std.testing.expectEqualStrings("second answer", second_text);
        try std.testing.expect(agent.state() == .completed);
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
    try std.testing.expect(agent.state() == .completed);
    try std.testing.expectEqual(@as(usize, 4), agent.messages().len);
}

test "agent rejects runs after failure or cancellation without mutation" {
    {
        var cancelled_model: ai_testing.ScriptedModel = .{
            .identity = .{ .provider = "script", .model = "cancelled-turn" },
            .steps = &.{.{ .tool_call = .{ .id = "call", .name = "read", .arguments_json = "{}" } }},
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
        const message_count = agent.messages().len;
        const request_count = agent.modelRequests();
        const tool_count = agent.toolCalls();
        try std.testing.expectError(error.AlreadyRun, agent.run("again"));
        try std.testing.expectEqual(message_count, agent.messages().len);
        try std.testing.expectEqual(request_count, agent.modelRequests());
        try std.testing.expectEqual(tool_count, agent.toolCalls());
        try std.testing.expect(agent.state() == .cancelled);
    }

    {
        var failed_model: ai_testing.ScriptedModel = .{
            .identity = .{ .provider = "script", .model = "failed-turn" },
            .steps = &.{.{ .tool_call = .{ .id = "call", .name = "read", .arguments_json = "{}" } }},
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
        const message_count = agent.messages().len;
        try std.testing.expectError(error.AlreadyRun, agent.run("again"));
        try std.testing.expectEqual(message_count, agent.messages().len);
        try std.testing.expect(agent.state() == .failed);
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
        requesting_rejected: bool = false,
        completed_rejected: bool = false,

        fn emit(context: *anyopaque, event: Event) void {
            const self: *Self = @ptrCast(@alignCast(context));
            const change = switch (event) {
                .state_changed => |change| change,
                else => return,
            };
            if (change.to != .requesting_model and change.to != .completed) return;
            const attempt = self.agent.run("nested");
            const rejected = if (attempt) |_| false else |failure| failure == error.AlreadyRun;
            if (change.to == .requesting_model) self.requesting_rejected = rejected;
            if (change.to == .completed) self.completed_rejected = rejected;
        }
    };
    var recorder: ReentrantRecorder = .{ .agent = &agent };
    agent.events = .{ .context = &recorder, .emitFn = ReentrantRecorder.emit };

    const text = try agent.run("outer");
    try std.testing.expectEqualStrings("answer", text);
    try std.testing.expect(recorder.requesting_rejected);
    try std.testing.expect(recorder.completed_rejected);
    try std.testing.expect(agent.state() == .completed);
    try std.testing.expectEqual(@as(usize, 1), agent.modelRequests());
    try std.testing.expectEqual(@as(usize, 2), agent.messages().len);
}

const StreamCollector = struct {
    const Entry = struct {
        request_number: usize,
        tag: std.meta.Tag(ai_stream.StreamEvent),
    };

    entries: [32]Entry = undefined,
    count: usize = 0,
    completed_tool_call_valid: bool = false,

    fn emit(context: *anyopaque, event: StreamEvent) ai_stream.StreamSinkError!void {
        const self: *StreamCollector = @ptrCast(@alignCast(context));
        self.entries[self.count] = .{
            .request_number = event.request_number,
            .tag = std.meta.activeTag(event.event),
        };
        self.count += 1;
        if (event.event == .part_end and event.event.part_end.part == .tool_call) {
            self.completed_tool_call_valid = std.mem.eql(
                u8,
                event.event.part_end.part.tool_call.arguments_json,
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
        null,
    );
    defer agent.deinit();

    const text = try agent.runStream("read the file.", .{ .context = &collector, .emitFn = StreamCollector.emit });
    try std.testing.expectEqualStrings("streamed final", text);
    try std.testing.expect(agent.state() == .completed);
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
        try std.testing.expectEqual(@as(usize, 1), entry.request_number);
    }
    for (collector.entries[3..6]) |entry| {
        try std.testing.expectEqual(@as(usize, 2), entry.request_number);
    }
    try std.testing.expectEqual(.part_start, collector.entries[0].tag);
    try std.testing.expectEqual(.part_end, collector.entries[2].tag);
    try std.testing.expect(collector.completed_tool_call_valid);
    try std.testing.expectEqual(.part_start, collector.entries[3].tag);
}

const StreamFailSink = struct {
    failure: ai_stream.StreamSinkError,

    fn emit(context: *anyopaque, _: StreamEvent) ai_stream.StreamSinkError!void {
        const self: *StreamFailSink = @ptrCast(@alignCast(context));
        return self.failure;
    }
};

fn expectStreamFailureDoesNotCommit(
    failure: ai_stream.StreamSinkError,
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
    var sink_state: StreamFailSink = .{ .failure = failure };

    try std.testing.expectError(
        expected,
        agent.runStream("go", .{ .context = &sink_state, .emitFn = StreamFailSink.emit }),
    );
    try std.testing.expectEqual(expected_state_tag, std.meta.activeTag(agent.state()));
    try std.testing.expectEqual(@as(usize, 1), agent.messages().len);
    try std.testing.expectEqualStrings("go", agent.messages()[0].request.parts[0].user.text);
}

test "agent stream sink failures commit no partial response" {
    try expectStreamFailureDoesNotCommit(error.ConsumerStopped, error.StreamConsumerStopped, .failed);
    try expectStreamFailureDoesNotCommit(error.OutOfMemory, error.OutOfMemory, .failed);
    try expectStreamFailureDoesNotCommit(error.Cancelled, error.Cancelled, .cancelled);
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

    try std.testing.expectError(
        expected,
        agent.runStream("go", .{ .context = &collector, .emitFn = StreamCollector.emit }),
    );
    try std.testing.expect(collector.count > 0);
    try std.testing.expectEqual(expected_state_tag, std.meta.activeTag(agent.state()));
    try std.testing.expectEqual(@as(usize, 1), agent.messages().len);
    try std.testing.expectEqualStrings("go", agent.messages()[0].request.parts[0].user.text);
}

test "fatal streamed finishes commit no partial response" {
    try expectFatalFinishDoesNotCommit(.cancelled, error.Cancelled, .cancelled);
    try expectFatalFinishDoesNotCommit(.provider_error, error.InvalidProviderResponse, .failed);
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
    try std.testing.expect(agent.state() == .failed);
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
    try std.testing.expect(agent.state() == .failed);
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

test "completed tool results are canonical before the next tool starts" {
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
    try std.testing.expectEqual(@as(usize, 3), agent.messages().len);
    try std.testing.expectEqualStrings(
        "first complete",
        agent.messages()[2].request.parts[0].tool_result.content[0].text,
    );
    try std.testing.expectEqualStrings(
        "call-1",
        agent.messages()[2].request.parts[0].tool_result.call_id,
    );
    try std.testing.expect(agent.state() == .failed);
}

const CancelOnToolCompletion = struct {
    token: *ai_model.CancellationToken,

    fn emit(context: *anyopaque, event: Event) void {
        const self: *CancelOnToolCompletion = @ptrCast(@alignCast(context));
        if (event == .tool_execution_completed) self.token.cancel();
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
    try std.testing.expect(agent.state() == .cancelled);
}

test "agent preflights delivery capabilities before canonical input" {
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
    var collector: StreamCollector = .{};

    try std.testing.expectError(
        error.UnsupportedCapability,
        no_stream_agent.runStream("not submitted", .{
            .context = &collector,
            .emitFn = StreamCollector.emit,
        }),
    );
    try std.testing.expectEqual(@as(usize, 0), no_stream_model.calls);
    try std.testing.expectEqual(@as(usize, 0), no_stream_agent.messages().len);
    try std.testing.expect(no_stream_agent.state() == .idle);
    try std.testing.expectEqualStrings("never", try no_stream_agent.run("submitted"));
    try std.testing.expectEqual(@as(usize, 1), no_stream_model.calls);
    try std.testing.expectEqual(@as(usize, 2), no_stream_agent.messages().len);
    try std.testing.expect(no_stream_agent.state() == .completed);

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
    try std.testing.expect(no_tools_agent.state() == .idle);
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

    try std.testing.expectEqualStrings(
        "first answer",
        try agent.runStream("first stream", .{ .context = &first_collector, .emitFn = StreamCollector.emit }),
    );
    try std.testing.expectEqualStrings(
        "second answer",
        try agent.runStream("second stream", .{ .context = &second_collector, .emitFn = StreamCollector.emit }),
    );
    try std.testing.expect(agent.state() == .completed);
    try std.testing.expect(request_recorder.valid);
    try std.testing.expectEqual(@as(usize, 4), agent.messages().len);
    try std.testing.expectEqual(@as(usize, 1), second_collector.entries[0].request_number);
}
