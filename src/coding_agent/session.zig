const std = @import("std");
const runtime_queue = @import("../runtime/queue.zig");
const agent_mod = @import("../agent/root.zig");
const message_memory = @import("../agent/message_memory.zig");
const command_mod = @import("command.zig");
const event_mod = @import("event.zig");
const state_mod = @import("state.zig");
const extension_mod = @import("extension.zig");

const CommandQueue = runtime_queue.BoundedQueue(QueuedCommand);

pub const max_commands: usize = 64;

pub const AgentSession = struct {
    allocator: std.mem.Allocator,
    agent: agent_mod.Agent,
    commands: CommandQueue,
    state_value: state_mod.State = .{},
    next_command_id: u64 = 1,
    event_sink: ?event_mod.Sink = null,
    extension_host: extension_mod.Host = .disabled,

    pub const Options = struct {
        command_capacity: usize = max_commands,
        event_sink: ?event_mod.Sink = null,
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) !AgentSession {
        var commands = try CommandQueue.init(allocator, options.command_capacity);
        errdefer commands.deinit();

        var agent = agent_mod.Agent.init(allocator);
        errdefer agent.deinit();

        const self: AgentSession = .{
            .allocator = allocator,
            .agent = agent,
            .commands = commands,
            .event_sink = options.event_sink,
        };
        return self;
    }

    pub fn deinit(self: *AgentSession) void {
        while (self.commands.pop()) |queued| {
            var owned = queued;
            owned.deinit(self.allocator);
        }
        self.commands.deinit();
        self.agent.deinit();
        self.* = undefined;
    }

    pub fn submit(self: *AgentSession, command: command_mod.Command) error{OutOfMemory}!command_mod.SubmitResult {
        const rejected = self.rejectCommand(command);
        if (rejected) |reason| {
            self.emit(.{ .command = .{ .rejected = reason } });
            return .{ .rejected = reason };
        }

        const id: command_mod.CommandId = @enumFromInt(self.next_command_id);
        self.next_command_id +%= 1;
        const owned_command = try cloneCommand(self.allocator, command);
        errdefer freeCommand(self.allocator, owned_command);
        self.commands.push(.{ .id = id, .command = owned_command }) catch {
            self.emit(.{ .command = .{ .rejected = .queue_full } });
            return .{ .rejected = .queue_full };
        };
        self.emit(.{ .command = .{ .accepted = id } });
        return .{ .accepted = id };
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
            .submit_prompt, .continue_run => switch (self.state_value.activity) {
                .idle => null,
                else => .busy,
            },
            .abort_run => switch (self.state_value.activity) {
                .running => null,
                .idle, .aborting, .failed => .invalid_state,
            },
        };
    }

    fn applyCommand(self: *AgentSession, queued: QueuedCommand) void {
        switch (queued.command) {
            .submit_prompt => |prompt| {
                self.state_value.activity = .{ .running = .{ .command_id = queued.id } };
                _ = prompt;
            },
            .continue_run => {
                self.state_value.activity = .{ .running = .{ .command_id = queued.id } };
            },
            .abort_run => {
                self.agent.abort();
                self.state_value.activity = .{ .aborting = .{ .command_id = queued.id } };
            },
        }
    }

    pub fn applyAgentEvent(self: *AgentSession, value: agent_mod.AgentEvent) void {
        switch (value) {
            .lifecycle => |lifecycle| switch (lifecycle) {
                .run_finished => |terminal| switch (terminal) {
                    .completed => self.state_value.activity = .idle,
                    .aborted => self.state_value.activity = .idle,
                    .failed => |failed| self.state_value.activity = .{ .failed = .{ .reason = failureMessage(failed.reason) } },
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
        .abort_run => .abort_run,
        .continue_run => .continue_run,
    };
}

fn freeCommand(allocator: std.mem.Allocator, value: command_mod.Command) void {
    switch (value) {
        .submit_prompt => |prompt| freeMessages(allocator, prompt.messages),
        .abort_run, .continue_run => {},
    }
}

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
