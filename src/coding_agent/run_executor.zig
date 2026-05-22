const std = @import("std");
const agent_mod = @import("../agent/root.zig");
const cancel = @import("../runtime/cancel.zig");
const command_mod = @import("command.zig");
const event_mod = @import("event.zig");
const run_completion_mod = @import("run_completion.zig");
const state_mod = @import("state.zig");

// BorrowedRunSpec is synchronous executor ingress. An executor may inspect it during
// submission, but async/runtime-backed execution must clone the fields it needs
// into operation-owned memory before returning .submitted. AgentSession remains
// the owner of policy memory and active input messages. Hook contexts inside
// RunConfig are borrowed pointers; the executor must ensure they remain valid
// for the operation lifetime or clone them into operation-owned memory.
pub const BorrowedRunSpec = struct {
    input: agent_mod.AgentInput,
    config: agent_mod.config.RunConfig,
};

// Submission is a borrowed start-run event. It grants no pointer authority into
// AgentSession. Cancellation intent crosses the executor boundary separately as
// CancelRequest; cancellation completion still returns as RunCompletion.
pub const Submission = struct {
    run_command_id: command_mod.CommandId,
    spec: BorrowedRunSpec,
};

pub const CancelRequest = struct {
    run_command_id: command_mod.CommandId,
};

pub const SubmitResult = union(enum) {
    submitted,
    rejected: Rejection,
};

pub const Rejection = enum {
    busy,
    queue_full,
    shutting_down,
};

pub const Completion = run_completion_mod.RunCompletion;

// CompletionSink is a synchronous consumption boundary. RunCompletion contains
// arena-owned memory and must not be passed by value. The callee must consume the
// pointed-to completion before returning, either by applying/deiniting it or by
// moving its fields into another single-owner container.
pub const CompletionSink = struct {
    ctx: ?*anyopaque = null,
    complete_fn: *const fn (completion: *Completion, ctx: ?*anyopaque) void,

    pub fn complete(self: CompletionSink, completion: *Completion) void {
        self.complete_fn(completion, self.ctx);
    }
};

pub const EventSink = struct {
    ctx: ?*anyopaque = null,
    emit_fn: *const fn (event: event_mod.Event, ctx: ?*anyopaque) void,

    pub fn emit(self: EventSink, event: event_mod.Event) void {
        self.emit_fn(event, self.ctx);
    }
};

pub const Contract = struct {
    completion_delivery: CompletionDelivery,
    max_in_flight: usize,

    pub fn init(options: ContractOptions) Contract {
        if (options.max_in_flight == 0) @panic("run executor max_in_flight must be greater than zero");
        if (options.completion_delivery == .bounded_queue) {
            if (options.completion_delivery.bounded_queue == 0) @panic("run executor bounded completion queue capacity must be greater than zero");
        }
        return .{
            .completion_delivery = options.completion_delivery,
            .max_in_flight = options.max_in_flight,
        };
    }
};

pub const ContractOptions = struct {
    completion_delivery: CompletionDelivery,
    max_in_flight: usize = 1,
};

pub const CompletionDelivery = union(enum) {
    direct_owner_call,
    bounded_queue: usize,
};

pub const SynchronousExecutor = struct {
    // Runs the borrowed submission to terminal before returning. The cancel token
    // is a scoped borrow for this call only; this executor must not retain it.
    pub fn run(
        allocator: std.mem.Allocator,
        submission: Submission,
        token: cancel.Token,
        completion_sink: CompletionSink,
        event_sink: ?EventSink,
    ) void {
        var capture = RunCapture{ .allocator = allocator, .run_command_id = submission.run_command_id, .input_count = submission.spec.input.messages.len, .event_sink = event_sink };
        defer capture.deinit();

        var run_value = agent_mod.Run.init(allocator, submission.spec.input, .{ .emit_fn = RunCapture.emit, .ctx = &capture }, token);
        defer run_value.deinit();

        run_value.runStream(submission.spec.config);
        if (capture.takeTerminal()) |terminal| {
            var completion = Completion{ .command_id = submission.run_command_id, .terminal = terminal };
            completion_sink.complete(&completion);
        } else {
            const terminal = run_completion_mod.OwnedRunTerminal.failed(allocator, &.{}, .internal) catch @panic("OOM while recording missing run terminal");
            var completion = Completion{ .command_id = submission.run_command_id, .terminal = terminal };
            completion_sink.complete(&completion);
        }
    }
};

const RunCapture = struct {
    allocator: std.mem.Allocator,
    run_command_id: command_mod.CommandId,
    input_count: usize,
    event_sink: ?EventSink = null,
    terminal: ?run_completion_mod.OwnedRunTerminal = null,

    fn emit(value: agent_mod.AgentEvent, ctx: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        if (self.event_sink) |sink| sink.emit(.{ .agent = value });
        switch (value) {
            .lifecycle => |lifecycle| self.captureLifecycle(lifecycle),
            .tool => {},
            .message => {},
        }
    }

    fn captureLifecycle(self: *RunCapture, lifecycle: agent_mod.event.Lifecycle) void {
        if (lifecycle != .run_finished) return;
        if (self.terminal != null) return;

        self.terminal = switch (lifecycle.run_finished) {
            .completed => |completed| run_completion_mod.OwnedRunTerminal.completed(self.allocator, self.outputMessages(completed.messages)) catch |err| oomTerminal(self.allocator, err),
            .failed => |failed| run_completion_mod.OwnedRunTerminal.failed(self.allocator, self.outputMessages(failed.messages), failureKind(failed.reason)) catch |err| oomTerminal(self.allocator, err),
            .aborted => |aborted| run_completion_mod.OwnedRunTerminal.aborted(self.allocator, self.outputMessages(aborted.messages)) catch |err| oomTerminal(self.allocator, err),
        };
    }

    fn outputMessages(self: *const RunCapture, messages: []const agent_mod.AgentMessage) []const agent_mod.AgentMessage {
        if (messages.len <= self.input_count) return &.{};
        return messages[self.input_count..];
    }

    fn takeTerminal(self: *RunCapture) ?run_completion_mod.OwnedRunTerminal {
        const terminal = self.terminal orelse return null;
        self.terminal = null;
        return terminal;
    }

    fn deinit(self: *RunCapture) void {
        if (self.terminal) |*terminal| terminal.deinit();
        self.* = undefined;
    }
};

fn oomTerminal(allocator: std.mem.Allocator, _: anyerror) run_completion_mod.OwnedRunTerminal {
    return run_completion_mod.OwnedRunTerminal.failed(allocator, &.{}, .out_of_memory) catch @panic("OOM while recording run terminal");
}

fn failureKind(value: agent_mod.failure.Failure) state_mod.FailureKind {
    return switch (value) {
        .out_of_memory => .out_of_memory,
        .invalid_context => .invalid_context,
        .stream_failed => .stream_failed,
        .tool_failed => .tool_failed,
        .tool_protocol_violation => .tool_protocol_violation,
        .internal => .internal,
    };
}

test "run executor submission carries run identity and borrowed spec" {
    const submission = Submission{
        .run_command_id = @enumFromInt(7),
        .spec = .{
            .input = .{ .system_prompt = "", .messages = &.{}, .tools = &.{} },
            .config = .{
                .model = .{
                    .id = "test",
                    .name = "test",
                    .api = .openai_responses,
                    .provider = .openai,
                    .base_url = "",
                    .reasoning = false,
                    .input = &.{},
                    .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
                    .context_window = 0,
                    .max_tokens = 0,
                },
                .stream = undefined,
                .convert_messages = undefined,
                .io = std.testing.io,
            },
        },
    };

    try std.testing.expectEqual(@as(command_mod.CommandId, @enumFromInt(7)), submission.run_command_id);
    try std.testing.expectEqualStrings("", submission.spec.input.system_prompt);
}

test "run executor cancellation intent is separate from submission" {
    const request = CancelRequest{ .run_command_id = @enumFromInt(7) };

    try std.testing.expectEqual(@as(command_mod.CommandId, @enumFromInt(7)), request.run_command_id);
}

test "completion sink consumes owned completion by pointer" {
    const Capture = struct {
        command_id: ?command_mod.CommandId = null,
        terminal: ?run_completion_mod.OwnedRunTerminal = null,

        fn complete(completion: *Completion, ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.command_id = completion.command_id;
            self.terminal = completion.terminal;
            completion.* = undefined;
        }

        fn deinit(self: *@This()) void {
            if (self.terminal) |*terminal| terminal.deinit();
            self.* = undefined;
        }
    };

    var capture = Capture{};
    defer capture.deinit();
    const sink = CompletionSink{ .complete_fn = Capture.complete, .ctx = &capture };
    var completion = Completion{
        .command_id = @enumFromInt(9),
        .terminal = try run_completion_mod.OwnedRunTerminal.completed(std.testing.allocator, &.{}),
    };

    sink.complete(&completion);

    try std.testing.expectEqual(@as(command_mod.CommandId, @enumFromInt(9)), capture.command_id.?);
    try std.testing.expect(capture.terminal.?.status == .completed);
}

test "run executor contract names bounded delivery and in flight capacity" {
    const contract = Contract.init(.{ .completion_delivery = .{ .bounded_queue = 4 }, .max_in_flight = 1 });

    try std.testing.expectEqual(@as(usize, 1), contract.max_in_flight);
    try std.testing.expectEqual(@as(usize, 4), contract.completion_delivery.bounded_queue);
}

fn testAssistantMessage() agent_mod.AgentMessage {
    return .{ .assistant = .{
        .content = &.{},
        .api = .openai_responses,
        .provider = .openai,
        .model = "test",
        .usage = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total_tokens = 0, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 } },
        .stop_reason = .stop,
        .timestamp = 1,
    } };
}

fn testModel() agent_mod.message.Model {
    return .{
        .id = "test",
        .name = "test",
        .api = .openai_responses,
        .provider = .openai,
        .base_url = "",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 0,
        .max_tokens = 0,
    };
}

fn convertNoop(_: ?*anyopaque, _: std.mem.Allocator, _: []const agent_mod.AgentMessage) error{OutOfMemory}![]const @import("../ai/root.zig").protocol.Message {
    return &.{};
}

fn completeWithAssistant(_: ?*anyopaque, _: std.mem.Allocator, _: agent_mod.message.Model, _: @import("../ai/root.zig").protocol.Context, _: @import("../ai/root.zig").protocol.SimpleStreamOptions, sink: @import("../ai/root.zig").provider.StreamEventSink) error{OutOfMemory}!void {
    sink.emit(.{ .done = .{ .reason = .stop, .message = testAssistantMessage().assistant } });
}

fn failWithAssistant(_: ?*anyopaque, _: std.mem.Allocator, _: agent_mod.message.Model, _: @import("../ai/root.zig").protocol.Context, _: @import("../ai/root.zig").protocol.SimpleStreamOptions, sink: @import("../ai/root.zig").provider.StreamEventSink) error{OutOfMemory}!void {
    sink.emit(.{ .@"error" = .{ .reason = .@"error", .@"error" = testAssistantMessage().assistant } });
}

fn abortWithAssistant(_: ?*anyopaque, _: std.mem.Allocator, _: agent_mod.message.Model, _: @import("../ai/root.zig").protocol.Context, _: @import("../ai/root.zig").protocol.SimpleStreamOptions, sink: @import("../ai/root.zig").provider.StreamEventSink) error{OutOfMemory}!void {
    sink.emit(.{ .@"error" = .{ .reason = .aborted, .@"error" = testAssistantMessage().assistant } });
}

const CompletionCapture = struct {
    command_id: ?command_mod.CommandId = null,
    terminal: ?run_completion_mod.OwnedRunTerminal = null,

    fn complete(completion: *Completion, ctx: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.command_id = completion.command_id;
        self.terminal = completion.terminal;
        completion.* = undefined;
    }

    fn deinit(self: *@This()) void {
        if (self.terminal) |*terminal| terminal.deinit();
        self.* = undefined;
    }
};

fn testSubmission(run_command_id: command_mod.CommandId, stream: agent_mod.config.StreamHook) Submission {
    return .{
        .run_command_id = run_command_id,
        .spec = .{
            .input = .{ .system_prompt = "", .messages = &.{}, .tools = &.{} },
            .config = .{
                .model = testModel(),
                .stream = stream,
                .convert_messages = .{ .call_fn = convertNoop },
                .io = std.testing.io,
            },
        },
    };
}

test "synchronous executor publishes one completed run completion" {
    var capture = CompletionCapture{};
    defer capture.deinit();
    const submission = testSubmission(@enumFromInt(11), .{ .call_fn = completeWithAssistant });

    SynchronousExecutor.run(std.testing.allocator, submission, .none, .{ .complete_fn = CompletionCapture.complete, .ctx = &capture }, null);

    try std.testing.expectEqual(@as(command_mod.CommandId, @enumFromInt(11)), capture.command_id.?);
    try std.testing.expect(capture.terminal.?.status == .completed);
}

test "synchronous executor publishes failed run completion" {
    var capture = CompletionCapture{};
    defer capture.deinit();

    SynchronousExecutor.run(std.testing.allocator, testSubmission(@enumFromInt(12), .{ .call_fn = failWithAssistant }), .none, .{ .complete_fn = CompletionCapture.complete, .ctx = &capture }, null);

    try std.testing.expectEqual(@as(command_mod.CommandId, @enumFromInt(12)), capture.command_id.?);
    try std.testing.expect(capture.terminal.?.status == .failed);
    try std.testing.expectEqual(state_mod.FailureKind.stream_failed, capture.terminal.?.status.failed.kind);
}

test "synchronous executor publishes aborted run completion" {
    var capture = CompletionCapture{};
    defer capture.deinit();
    var source = cancel.Source{};
    const token = source.beginRun();
    source.requestAbort();

    SynchronousExecutor.run(std.testing.allocator, testSubmission(@enumFromInt(13), .{ .call_fn = completeWithAssistant }), token, .{ .complete_fn = CompletionCapture.complete, .ctx = &capture }, null);

    try std.testing.expectEqual(@as(command_mod.CommandId, @enumFromInt(13)), capture.command_id.?);
    try std.testing.expect(capture.terminal.?.status == .aborted);
}
