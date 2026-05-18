const std = @import("std");
const runtime_queue = @import("../runtime/queue.zig");
const agent_mod = @import("../agent/root.zig");
const message_memory = @import("../agent/message_memory.zig");
const command_mod = @import("command.zig");
const event_mod = @import("event.zig");
const state_mod = @import("state.zig");
const extension_mod = @import("extension.zig");

const CommandQueue = runtime_queue.BoundedQueue(QueuedCommand);
const FollowUpQueue = runtime_queue.BoundedQueue(QueuedFollowUp);

pub const max_commands: usize = 64;
pub const max_pending_follow_ups: usize = 8;

pub const AgentSession = struct {
    allocator: std.mem.Allocator,
    agent: agent_mod.Agent,
    commands: CommandQueue,
    pending_follow_ups: FollowUpQueue,
    state_value: state_mod.State = .{},
    next_command_id: u64 = 1,
    event_sink: ?event_mod.Sink = null,
    extension_host: extension_mod.Host = .disabled,

    pub const Options = struct {
        command_capacity: usize = max_commands,
        follow_up_capacity: usize = max_pending_follow_ups,
        event_sink: ?event_mod.Sink = null,
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) !AgentSession {
        var commands = try CommandQueue.init(allocator, options.command_capacity);
        errdefer commands.deinit();

        var pending_follow_ups = try FollowUpQueue.init(allocator, options.follow_up_capacity);
        errdefer pending_follow_ups.deinit();

        var agent = agent_mod.Agent.init(allocator);
        errdefer agent.deinit();

        const self: AgentSession = .{
            .allocator = allocator,
            .agent = agent,
            .commands = commands,
            .pending_follow_ups = pending_follow_ups,
            .event_sink = options.event_sink,
        };
        return self;
    }

    pub fn deinit(self: *AgentSession) void {
        while (self.commands.pop()) |queued| {
            var owned = queued;
            owned.deinit(self.allocator);
        }
        self.clearPendingFollowUps();
        self.pending_follow_ups.deinit();
        self.commands.deinit();
        self.agent.deinit();
        self.* = undefined;
    }

    pub fn submit(self: *AgentSession, command: command_mod.Command) error{OutOfMemory}!command_mod.SubmitResult {
        switch (command) {
            .follow_up => |follow_up| return self.submitFollowUp(follow_up),
            .steer => |steer| return self.submitSteer(steer),
            else => {},
        }

        const rejected = self.rejectCommand(command);
        if (rejected) |reason| {
            self.emit(.{ .command = .{ .rejected = reason } });
            return .{ .rejected = reason };
        }

        return self.submitQueued(command);
    }

    pub fn drainCommands(self: *AgentSession) void {
        while (self.commands.pop()) |queued| {
            var owned = queued;
            defer owned.deinit(self.allocator);
            self.applyCommand(owned);
        }
    }

    pub fn state(self: *const AgentSession) state_mod.State {
        return self.state_value;
    }

    fn rejectCommand(self: *const AgentSession, command: command_mod.Command) ?command_mod.Rejection {
        return switch (command) {
            .submit_prompt => switch (self.state_value.activity) {
                .idle, .failed => null,
                else => .busy,
            },
            .continue_run => switch (self.state_value.activity) {
                .idle => null,
                else => .busy,
            },
            .abort_run => switch (self.state_value.activity) {
                .running => null,
                .idle, .aborting, .failed => .invalid_state,
            },
            .follow_up, .steer => unreachable,
        };
    }

    fn applyCommand(self: *AgentSession, queued: QueuedCommand) void {
        switch (queued.command) {
            .submit_prompt => |prompt| {
                self.startRun(queued.id, prompt.messages);
            },
            .follow_up => |follow_up| {
                self.startRun(queued.id, follow_up.messages);
            },
            .continue_run => {
                self.startRun(queued.id, &.{});
            },
            .steer => std.debug.panic("steer command must not enter command queue before agent control support", .{}),
            .abort_run => {
                self.agent.abort();
                self.state_value.activity = .{ .aborting = .{ .command_id = queued.id, .pending_follow_ups = self.pending_follow_ups.len } };
            },
        }
    }

    pub fn applyAgentEvent(self: *AgentSession, value: agent_mod.AgentEvent) void {
        switch (value) {
            .lifecycle => |lifecycle| switch (lifecycle) {
                .run_finished => |terminal| switch (terminal) {
                    .completed => self.startNextFollowUpOrIdle(),
                    .aborted => {
                        self.clearPendingFollowUps();
                        self.state_value.activity = .idle;
                    },
                    .failed => |failed| {
                        self.clearPendingFollowUps();
                        self.state_value.activity = .{ .failed = .{ .reason = failureMessage(failed.reason) } };
                    },
                },
                else => {},
            },
            else => {},
        }
        self.emit(.{ .run = .{ .agent = value } });
    }

    fn emit(self: *AgentSession, value: event_mod.Event) void {
        if (self.event_sink) |sink| sink.emit(value);
    }

    fn submitFollowUp(self: *AgentSession, follow_up: command_mod.FollowUp) error{OutOfMemory}!command_mod.SubmitResult {
        return switch (self.state_value.activity) {
            .idle, .failed => self.submitQueued(.{ .follow_up = follow_up }),
            .running => self.queuePendingFollowUp(follow_up),
            .aborting => |aborting| blk: {
                _ = aborting;
                self.emit(.{ .command = .{ .rejected = .invalid_state } });
                break :blk .{ .rejected = .invalid_state };
            },
        };
    }

    fn submitSteer(self: *AgentSession, steer: command_mod.Steer) command_mod.SubmitResult {
        return switch (self.state_value.activity) {
            .running => blk: {
                _ = steer;
                self.emit(.{ .command = .{ .rejected = .unsupported } });
                break :blk .{ .rejected = .unsupported };
            },
            .idle, .aborting, .failed => blk: {
                _ = steer;
                self.emit(.{ .command = .{ .rejected = .invalid_state } });
                break :blk .{ .rejected = .invalid_state };
            },
        };
    }

    fn submitQueued(self: *AgentSession, command: command_mod.Command) error{OutOfMemory}!command_mod.SubmitResult {
        const id: command_mod.CommandId = @enumFromInt(self.next_command_id);
        self.next_command_id +%= 1;
        const owned_command = try cloneCommand(self.allocator, command);
        self.commands.push(.{ .id = id, .command = owned_command }) catch {
            freeCommand(self.allocator, owned_command);
            self.emit(.{ .command = .{ .rejected = .queue_full } });
            return .{ .rejected = .queue_full };
        };
        self.emit(.{ .command = .{ .accepted = id } });
        return .{ .accepted = id };
    }

    fn queuePendingFollowUp(self: *AgentSession, follow_up: command_mod.FollowUp) error{OutOfMemory}!command_mod.SubmitResult {
        const id: command_mod.CommandId = @enumFromInt(self.next_command_id);
        self.next_command_id +%= 1;
        const owned_messages = try cloneMessages(self.allocator, follow_up.messages);
        self.pending_follow_ups.push(.{ .id = id, .messages = owned_messages }) catch {
            freeMessages(self.allocator, owned_messages);
            self.emit(.{ .command = .{ .rejected = .follow_up_queue_full } });
            return .{ .rejected = .follow_up_queue_full };
        };
        self.refreshActivityCounts();
        self.emit(.{ .command = .{ .accepted = id } });
        return .{ .accepted = id };
    }

    fn startRun(self: *AgentSession, id: command_mod.CommandId, messages: []const agent_mod.AgentMessage) void {
        // The current spine records the outer-loop transition only. Wiring to
        // agent.runStream must clone or consume these messages before this
        // function returns.
        _ = messages;
        self.state_value.activity = .{ .running = .{
            .command_id = id,
            .pending_follow_ups = self.pending_follow_ups.len,
            .pending_steering = 0,
        } };
    }

    fn startNextFollowUpOrIdle(self: *AgentSession) void {
        if (self.pending_follow_ups.pop()) |queued| {
            var owned = queued;
            defer owned.deinit(self.allocator);
            self.startRun(owned.id, owned.messages);
            self.refreshActivityCounts();
            return;
        }
        self.state_value.activity = .idle;
    }

    fn clearPendingFollowUps(self: *AgentSession) void {
        while (self.pending_follow_ups.pop()) |queued| {
            var owned = queued;
            owned.deinit(self.allocator);
        }
    }

    fn refreshActivityCounts(self: *AgentSession) void {
        switch (self.state_value.activity) {
            .running => |*running| running.pending_follow_ups = self.pending_follow_ups.len,
            .aborting => |*aborting| aborting.pending_follow_ups = self.pending_follow_ups.len,
            .idle, .failed => {},
        }
    }
};

const QueuedCommand = struct {
    id: command_mod.CommandId,
    command: command_mod.Command,

    fn deinit(self: *QueuedCommand, allocator: std.mem.Allocator) void {
        freeCommand(allocator, self.command);
        self.* = undefined;
    }
};

fn cloneCommand(allocator: std.mem.Allocator, value: command_mod.Command) !command_mod.Command {
    return switch (value) {
        .submit_prompt => |prompt| .{ .submit_prompt = .{ .messages = try cloneMessages(allocator, prompt.messages) } },
        .follow_up => |follow_up| .{ .follow_up = .{ .messages = try cloneMessages(allocator, follow_up.messages) } },
        .steer => |steer| .{ .steer = .{ .text = try allocator.dupe(u8, steer.text) } },
        .abort_run => .abort_run,
        .continue_run => .continue_run,
    };
}

fn freeCommand(allocator: std.mem.Allocator, value: command_mod.Command) void {
    switch (value) {
        .submit_prompt => |prompt| freeMessages(allocator, prompt.messages),
        .follow_up => |follow_up| freeMessages(allocator, follow_up.messages),
        .steer => |steer| allocator.free(steer.text),
        .abort_run, .continue_run => {},
    }
}

const QueuedFollowUp = struct {
    id: command_mod.CommandId,
    messages: []const agent_mod.AgentMessage,

    fn deinit(self: *QueuedFollowUp, allocator: std.mem.Allocator) void {
        freeMessages(allocator, self.messages);
        self.* = undefined;
    }
};

fn cloneMessages(allocator: std.mem.Allocator, messages: []const agent_mod.AgentMessage) ![]const agent_mod.AgentMessage {
    const out = try allocator.alloc(agent_mod.AgentMessage, messages.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |msg| message_memory.freeMessage(allocator, msg);
        allocator.free(out);
    }
    for (messages, 0..) |msg, i| {
        out[i] = try message_memory.cloneMessage(allocator, msg);
        initialized += 1;
    }
    return out;
}

fn freeMessages(allocator: std.mem.Allocator, messages: []const agent_mod.AgentMessage) void {
    for (messages) |msg| message_memory.freeMessage(allocator, msg);
    allocator.free(messages);
}

fn failureMessage(value: agent_mod.failure.Failure) []const u8 {
    return switch (value) {
        inline else => |message| message,
    };
}

test "agent session command queue is bounded" {
    var session = try AgentSession.init(std.testing.allocator, .{ .command_capacity = 1 });
    defer session.deinit();

    try std.testing.expect((try session.submit(.{ .submit_prompt = .{ .messages = &.{} } })) == .accepted);
    try std.testing.expectEqual(command_mod.Rejection.queue_full, (try session.submit(.{ .submit_prompt = .{ .messages = &.{} } })).rejected);
}

test "agent session accepts prompt through owner drain" {
    var session = try AgentSession.init(std.testing.allocator, .{});
    defer session.deinit();

    const result = try session.submit(.{ .submit_prompt = .{ .messages = &.{} } });
    try std.testing.expect(result == .accepted);
    try std.testing.expect(session.state().activity == .idle);

    session.drainCommands();
    try std.testing.expect(session.state().activity == .running);
}

test "agent terminal event updates product activity before notifying" {
    const Collector = struct {
        session: *AgentSession,
        saw_idle: bool = false,

        fn emit(value: event_mod.Event, ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (value == .run) self.saw_idle = self.session.state().activity == .idle;
        }
    };

    var session = try AgentSession.init(std.testing.allocator, .{});
    defer session.deinit();
    var collector = Collector{ .session = &session };
    session.event_sink = .{ .emit_fn = Collector.emit, .ctx = &collector };

    _ = try session.submit(.{ .submit_prompt = .{ .messages = &.{} } });
    session.drainCommands();
    try std.testing.expect(session.state().activity == .running);

    session.applyAgentEvent(.{ .lifecycle = .{ .run_finished = .{ .completed = .{ .messages = &.{} } } } });
    try std.testing.expect(collector.saw_idle);
}

test "agent session rejects steering until inner loop supports it" {
    var session = try AgentSession.init(std.testing.allocator, .{});
    defer session.deinit();

    try std.testing.expectEqual(command_mod.Rejection.invalid_state, (try session.submit(.{ .steer = .{ .text = "slow down" } })).rejected);

    _ = try session.submit(.{ .submit_prompt = .{ .messages = &.{} } });
    session.drainCommands();

    try std.testing.expectEqual(command_mod.Rejection.unsupported, (try session.submit(.{ .steer = .{ .text = "slow down" } })).rejected);
}

test "follow up starts from idle through owner drain" {
    var session = try AgentSession.init(std.testing.allocator, .{});
    defer session.deinit();

    const result = try session.submit(.{ .follow_up = .{ .messages = &.{} } });
    try std.testing.expect(result == .accepted);
    try std.testing.expect(session.state().activity == .idle);

    session.drainCommands();
    try std.testing.expect(session.state().activity == .running);
}

test "follow up queues while running and starts after completed terminal" {
    var session = try AgentSession.init(std.testing.allocator, .{});
    defer session.deinit();

    _ = try session.submit(.{ .submit_prompt = .{ .messages = &.{} } });
    session.drainCommands();
    _ = try session.submit(.{ .follow_up = .{ .messages = &.{} } });

    try std.testing.expectEqual(@as(usize, 1), session.state().activity.running.pending_follow_ups);

    session.applyAgentEvent(.{ .lifecycle = .{ .run_finished = .{ .completed = .{ .messages = &.{} } } } });
    try std.testing.expect(session.state().activity == .running);
    try std.testing.expectEqual(@as(usize, 0), session.state().activity.running.pending_follow_ups);
}

test "follow up queue is bounded" {
    var session = try AgentSession.init(std.testing.allocator, .{ .follow_up_capacity = 1 });
    defer session.deinit();

    _ = try session.submit(.{ .submit_prompt = .{ .messages = &.{} } });
    session.drainCommands();

    try std.testing.expect((try session.submit(.{ .follow_up = .{ .messages = &.{} } })) == .accepted);
    try std.testing.expectEqual(command_mod.Rejection.follow_up_queue_full, (try session.submit(.{ .follow_up = .{ .messages = &.{} } })).rejected);
}

test "aborted and failed terminals clear queued follow ups" {
    var session = try AgentSession.init(std.testing.allocator, .{});
    defer session.deinit();

    _ = try session.submit(.{ .submit_prompt = .{ .messages = &.{} } });
    session.drainCommands();
    _ = try session.submit(.{ .follow_up = .{ .messages = &.{} } });
    try std.testing.expectEqual(@as(usize, 1), session.state().activity.running.pending_follow_ups);

    session.applyAgentEvent(.{ .lifecycle = .{ .run_finished = .{ .aborted = .{ .messages = &.{} } } } });
    try std.testing.expect(session.state().activity == .idle);

    _ = try session.submit(.{ .submit_prompt = .{ .messages = &.{} } });
    session.drainCommands();
    _ = try session.submit(.{ .follow_up = .{ .messages = &.{} } });
    session.applyAgentEvent(.{ .lifecycle = .{ .run_finished = .{ .failed = .{ .messages = &.{}, .reason = .{ .internal = "boom" } } } } });
    try std.testing.expect(session.state().activity == .failed);
}
