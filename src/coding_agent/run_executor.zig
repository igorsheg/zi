const std = @import("std");
const agent_mod = @import("../agent/root.zig");
const command_mod = @import("command.zig");
const run_completion_mod = @import("run_completion.zig");

// RunSpec is borrowed executor ingress. An executor may inspect it during
// submission, but async/runtime-backed execution must clone the fields it needs
// into operation-owned memory before returning .submitted. AgentSession remains
// the owner of policy memory and active input messages. Hook contexts inside
// RunConfig are borrowed pointers; the executor must ensure they remain valid
// for the operation lifetime or clone them into operation-owned memory.
pub const RunSpec = struct {
    input: agent_mod.AgentInput,
    config: agent_mod.config.RunConfig,
};

// Submission is a borrowed start-run event. It grants no pointer authority into
// AgentSession. Cancellation intent crosses the executor boundary separately as
// CancelRequest; cancellation completion still returns as RunCompletion.
pub const Submission = struct {
    run_command_id: command_mod.CommandId,
    spec: RunSpec,
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
