const std = @import("std");
const ai = @import("../ai/root.zig");
const runtime_queue = @import("../runtime/queue.zig");
const cancel = @import("../runtime/cancel.zig");
const agent_mod = @import("../agent/root.zig");
const message_memory = @import("../agent/message_memory.zig");
const command_mod = @import("command.zig");
const event_mod = @import("event.zig");
const state_mod = @import("state.zig");
const extension_mod = @import("extension.zig");
const durable_mod = @import("durable.zig");
const session_event_mod = @import("../session/event.zig");

const CommandQueue = runtime_queue.BoundedQueue(QueuedCommand);
const FollowUpQueue = runtime_queue.BoundedQueue(QueuedFollowUp);

pub const max_commands: usize = 64;
pub const max_pending_follow_ups: usize = 8;

pub const AgentSession = struct {
    allocator: std.mem.Allocator,
    commands: CommandQueue,
    pending_follow_ups: FollowUpQueue,
    pending_abort: ?QueuedAbort = null,
    policy: SessionPolicy,
    state_value: state_mod.State = .{},
    active_run: ?ActiveRun = null,
    next_command_id: u64 = 1,
    event_sink: ?event_mod.Sink = null,
    durable_appender: durable_mod.Appender = .disabled,
    extension_host: extension_mod.Host = .disabled,
    execution: Execution = .external_terminal,

    pub const Options = struct {
        command_capacity: usize = max_commands,
        follow_up_capacity: usize = max_pending_follow_ups,
        event_sink: ?event_mod.Sink = null,
        durable_appender: durable_mod.Appender = .disabled,
        policy: SessionPolicyInit = .{},
        execution: Execution = .external_terminal,
    };

    pub const Execution = union(enum) {
        external_terminal,
        synchronous: ExecutionBackend,
    };

    pub const SessionPolicyInit = struct {
        system_prompt: []const u8 = "",
        model: ?agent_mod.message.Model = null,
        reasoning: ?ai.protocol.ThinkingLevel = null,
    };

    pub const SessionPolicy = struct {
        arena: std.heap.ArenaAllocator,
        system_prompt: []const u8,
        model: ?agent_mod.message.Model,
        reasoning: ?ai.protocol.ThinkingLevel,

        pub fn init(allocator: std.mem.Allocator, policy: SessionPolicyInit) !SessionPolicy {
            var self = SessionPolicy{
                .arena = std.heap.ArenaAllocator.init(allocator),
                .system_prompt = &.{},
                .model = null,
                .reasoning = policy.reasoning,
            };
            errdefer self.deinit();
            const a = self.arena.allocator();
            self.system_prompt = try a.dupe(u8, policy.system_prompt);
            self.model = if (policy.model) |model| try cloneModel(a, model) else null;
            return self;
        }

        pub fn deinit(self: *SessionPolicy) void {
            self.arena.deinit();
            self.* = undefined;
        }

        pub fn replaceModel(self: *SessionPolicy, allocator: std.mem.Allocator, model: agent_mod.message.Model) !void {
            const next = try SessionPolicy.init(allocator, .{
                .system_prompt = self.system_prompt,
                .model = model,
                .reasoning = self.reasoning,
            });
            self.deinit();
            self.* = next;
        }

        pub fn setReasoning(self: *SessionPolicy, reasoning: ?ai.protocol.ThinkingLevel) void {
            self.reasoning = reasoning;
        }
    };

    pub const ExecutionBackend = struct {
        stream: agent_mod.config.StreamHook,
        convert_messages: agent_mod.config.ConvertMessagesHook,
        io: std.Io = std.Options.debug_io,
        temperature: ?f64 = null,
        max_tokens: ?u64 = null,
        api_key: ?[]const u8 = null,
        cache_retention: ?ai.protocol.CacheRetention = null,
        session_id: ?[]const u8 = null,
        max_retry_delay_ms: ?u64 = null,
        thinking_budgets: ?ai.protocol.ThinkingBudgets = null,
        transport: ?ai.protocol.Transport = null,
    };

    const RunSpec = struct {
        input: agent_mod.AgentInput,
        config: agent_mod.config.RunConfig,
    };

    const RunRequest = struct {
        command_id: command_mod.CommandId,
        messages: []const agent_mod.AgentMessage,
    };

    const DurableAppend = union(enum) {
        appended,
        skipped,
        failed: SessionRunFailure,
    };

    const SessionRunFailure = enum {
        durable_append_rejected,
        durable_append_failed,
        unsupported_batch,
        missing_model,

        fn failureKind(_: SessionRunFailure) state_mod.FailureKind {
            return .internal;
        }

        fn runTerminal(self: SessionRunFailure) event_mod.RunTerminal {
            return .{ .failed = self.failureKind() };
        }
    };

    const ActiveRun = struct {
        command_id: command_mod.CommandId,
        cancel_source: cancel.Source = .{},
        execution: ActiveExecution,
        input_messages: []const agent_mod.AgentMessage,

        fn deinit(self: *ActiveRun, allocator: std.mem.Allocator) void {
            freeMessages(allocator, self.input_messages);
            self.* = undefined;
        }
    };

    const ActiveExecution = enum {
        external_terminal,
        synchronous,
    };

    const DrainDecision = enum {
        continue_draining,
        stop_draining,
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) !AgentSession {
        var commands = try CommandQueue.init(allocator, options.command_capacity);
        errdefer commands.deinit();

        var pending_follow_ups = try FollowUpQueue.init(allocator, options.follow_up_capacity);
        errdefer pending_follow_ups.deinit();

        var policy = try SessionPolicy.init(allocator, options.policy);
        errdefer policy.deinit();

        const self: AgentSession = .{
            .allocator = allocator,
            .commands = commands,
            .pending_follow_ups = pending_follow_ups,
            .policy = policy,
            .event_sink = options.event_sink,
            .durable_appender = options.durable_appender,
            .execution = options.execution,
        };
        return self;
    }

    pub fn deinit(self: *AgentSession) void {
        while (self.commands.pop()) |queued| {
            var owned = queued;
            owned.deinit(self.allocator);
        }
        self.clearActiveRun();
        self.clearPendingFollowUps();
        self.pending_abort = null;
        self.pending_follow_ups.deinit();
        self.commands.deinit();
        self.policy.deinit();
        self.clearActivity();
        self.* = undefined;
    }

    pub fn submit(self: *AgentSession, command: command_mod.Command) error{OutOfMemory}!command_mod.SubmitResult {
        switch (command) {
            .follow_up => |follow_up| return self.submitFollowUp(follow_up),
            .steer => |steer| return self.submitSteer(steer),
            .abort_run => return self.submitAbortRun(),
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
        if (self.drainAbortControl() == .stop_draining) return;
        while (self.commands.pop()) |queued| {
            var owned = queued;
            defer owned.deinit(self.allocator);
            switch (self.applyCommand(owned)) {
                .continue_draining => {},
                .stop_draining => return,
            }
            if (self.drainAbortControl() == .stop_draining) return;
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
            .set_model, .set_reasoning => switch (self.state_value.activity) {
                .idle, .failed => null,
                .running, .aborting => .busy,
            },
            .abort_run => switch (self.state_value.activity) {
                .running => if (self.pending_abort == null) null else .busy,
                .idle, .aborting, .failed => .invalid_state,
            },
            .follow_up, .steer => unreachable,
        };
    }

    fn applyCommand(self: *AgentSession, queued: QueuedCommand) DrainDecision {
        self.assertCanApplyQueuedCommand(queued.command);
        switch (queued.command) {
            .submit_prompt => |prompt| {
                self.startRun(.{ .command_id = queued.id, .messages = prompt.messages });
                return self.drainDecisionAfterTransition();
            },
            .follow_up => |follow_up| {
                self.startRun(.{ .command_id = queued.id, .messages = follow_up.messages });
                return self.drainDecisionAfterTransition();
            },
            .continue_run => {
                self.startRun(.{ .command_id = queued.id, .messages = &.{} });
                return self.drainDecisionAfterTransition();
            },
            .set_model => |set| {
                self.policy.replaceModel(self.allocator, set.model) catch {
                    self.setActivity(.{ .failed = .{ .kind = .out_of_memory } });
                };
                return .continue_draining;
            },
            .set_reasoning => |set| {
                self.policy.setReasoning(set.reasoning);
                return .continue_draining;
            },
            .steer => std.debug.panic("steer command must not enter command queue before agent control support", .{}),
            .abort_run => unreachable,
        }
    }

    pub fn completeRun(self: *AgentSession, completion: *RunCompletion) void {
        defer completion.deinit();
        self.assertActiveExecution(.external_terminal, "run completion without active run");
        self.applyRunCompletion(completion);
    }

    fn completeSynchronousRun(self: *AgentSession, completion: *RunCompletion) void {
        defer completion.deinit();
        self.assertActiveExecution(.synchronous, "synchronous run completion without active run");
        self.applyRunCompletion(completion);
    }

    fn applyRunCompletion(self: *AgentSession, completion: *const RunCompletion) void {
        const finished_command_id = self.activeCommandId();
        const result: event_mod.RunTerminal = switch (completion.terminal.status) {
            .completed => |messages| blk: {
                switch (self.appendTerminalMessages(messages)) {
                    .appended, .skipped => {},
                    .failed => |failure| break :blk failure.runTerminal(),
                }
                self.clearActiveRun();
                self.setActivity(.idle);
                break :blk .completed;
            },
            .aborted => {
                self.clearActiveRun();
                self.clearPendingFollowUps();
                self.setActivity(.idle);
                return self.emit(.{ .run = .{ .finished = .{ .command_id = finished_command_id, .terminal = .aborted } } });
            },
            .failed => |failed| {
                self.clearActiveRun();
                self.clearPendingFollowUps();
                self.setActivity(.{ .failed = .{ .kind = failed.kind } });
                return self.emit(.{ .run = .{ .finished = .{ .command_id = finished_command_id, .terminal = .{ .failed = failed.kind } } } });
            },
        };
        if (result == .failed) {
            self.clearActiveRun();
            self.clearPendingFollowUps();
            self.setActivity(.{ .failed = .{ .kind = result.failed } });
        }
        self.emit(.{ .run = .{ .finished = .{ .command_id = finished_command_id, .terminal = result } } });
        if (result == .completed) self.startNextFollowUpOrIdle();
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

    fn submitAbortRun(self: *AgentSession) command_mod.SubmitResult {
        const rejected = self.rejectCommand(.abort_run);
        if (rejected) |reason| {
            self.emit(.{ .command = .{ .rejected = reason } });
            return .{ .rejected = reason };
        }

        const id = self.nextCommandId();
        self.pending_abort = .{ .id = id };
        self.emit(.{ .command = .{ .accepted = id } });
        return .{ .accepted = id };
    }

    fn submitQueued(self: *AgentSession, command: command_mod.Command) error{OutOfMemory}!command_mod.SubmitResult {
        const id = self.nextCommandId();
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
        const id = self.nextCommandId();
        const owned_messages = try cloneMessages(self.allocator, follow_up.messages);
        self.pending_follow_ups.push(.{ .id = id, .messages = owned_messages }) catch {
            freeMessages(self.allocator, owned_messages);
            self.emit(.{ .command = .{ .rejected = .follow_up_queue_full } });
            return .{ .rejected = .follow_up_queue_full };
        };
        self.refreshActivityCounts();
        self.emit(.{ .command = .{ .accepted = id } });
        self.emit(.{ .run = .{ .follow_up_queued = .{
            .command_id = id,
            .run_command_id = self.activeCommandId(),
            .pending_follow_ups = self.pending_follow_ups.len,
        } } });
        return .{ .accepted = id };
    }

    fn startRun(self: *AgentSession, request: RunRequest) void {
        std.debug.assert(self.active_run == null);
        const id = request.command_id;
        const messages = request.messages;
        const owned_messages = cloneMessages(self.allocator, messages) catch {
            self.clearPendingFollowUps();
            self.setActivity(.{ .failed = .{ .kind = .out_of_memory } });
            return;
        };
        switch (self.appendRunInput(owned_messages)) {
            .appended, .skipped => {},
            .failed => |failure| {
                self.clearPendingFollowUps();
                self.setActivity(.{ .failed = .{ .kind = failure.failureKind() } });
                freeMessages(self.allocator, owned_messages);
                return;
            },
        }
        const active_execution: ActiveExecution = switch (self.execution) {
            .external_terminal => .external_terminal,
            .synchronous => .synchronous,
        };
        self.active_run = .{ .command_id = id, .execution = active_execution, .input_messages = owned_messages };
        self.setActivity(.{ .running = .{
            .command_id = id,
            .pending_follow_ups = self.pending_follow_ups.len,
            .pending_steering = 0,
        } });
        self.emit(.{ .run = .{ .started = id } });

        switch (self.execution) {
            .external_terminal => {},
            .synchronous => |template| self.runSynchronous(template),
        }
    }

    fn runSynchronous(self: *AgentSession, backend: ExecutionBackend) void {
        std.debug.assert(self.active_run != null);
        const messages = self.active_run.?.input_messages;
        const spec = self.buildRunSpec(backend, messages) orelse {
            const failure: SessionRunFailure = .missing_model;
            const command_id = self.activeCommandId();
            self.clearActiveRun();
            self.clearPendingFollowUps();
            self.setActivity(.{ .failed = .{ .kind = failure.failureKind() } });
            self.emit(.{ .run = .{ .finished = .{ .command_id = command_id, .terminal = failure.runTerminal() } } });
            return;
        };

        var capture = RunCapture{ .allocator = self.allocator, .input_count = messages.len };
        defer capture.deinit();

        const token = self.active_run.?.cancel_source.beginRun();
        var run = agent_mod.Run.init(self.allocator, spec.input, .{ .emit_fn = RunCapture.emit, .ctx = &capture }, token);
        defer run.deinit();

        run.runStream(spec.config);
        if (capture.takeTerminal()) |terminal| {
            var completion = RunCompletion{ .terminal = terminal };
            self.completeSynchronousRun(&completion);
        }
    }

    fn buildRunSpec(self: *const AgentSession, backend: ExecutionBackend, messages: []const agent_mod.AgentMessage) ?RunSpec {
        const model = self.policy.model orelse return null;
        return .{
            .input = .{
                .system_prompt = self.policy.system_prompt,
                .messages = messages,
                .tools = &.{},
            },
            .config = .{
                .model = model,
                .stream = backend.stream,
                .convert_messages = backend.convert_messages,
                .io = backend.io,
                .temperature = backend.temperature,
                .max_tokens = backend.max_tokens,
                .api_key = backend.api_key,
                .cache_retention = backend.cache_retention,
                .session_id = backend.session_id,
                .max_retry_delay_ms = backend.max_retry_delay_ms,
                .thinking_budgets = backend.thinking_budgets,
                .transport = backend.transport,
                .reasoning = self.policy.reasoning,
            },
        };
    }

    fn appendRunInput(self: *AgentSession, messages: []const agent_mod.AgentMessage) DurableAppend {
        if (self.durable_appender == .disabled) return .skipped;
        if (messages.len == 0) return .skipped;
        if (messages.len != 1) {
            self.emit(.{ .session = .{ .append_rejected = .unsupported_batch } });
            return .{ .failed = .unsupported_batch };
        }

        return self.appendDurableMessage(messages[0]);
    }

    fn appendTerminalMessages(self: *AgentSession, messages: []const agent_mod.AgentMessage) DurableAppend {
        if (self.durable_appender == .disabled) return .skipped;
        var appended_any = false;
        for (messages) |message| {
            switch (self.appendDurableMessage(message)) {
                .appended => appended_any = true,
                .skipped => {},
                .failed => |failure| return .{ .failed = failure },
            }
        }
        return if (appended_any) .appended else .skipped;
    }

    fn appendDurableMessage(self: *AgentSession, message: agent_mod.AgentMessage) DurableAppend {
        const result = self.durable_appender.append(.{ .message = .{ .message = message } });
        switch (result) {
            .appended => |id| {
                self.emit(.{ .session = .{ .appended = id } });
                return .appended;
            },
            .rejected => |reason| {
                self.emit(.{ .session = .{ .append_rejected = reason } });
                return .{ .failed = .durable_append_rejected };
            },
            .failed => |failure| {
                self.emit(.{ .session = .{ .append_failed = failure } });
                return .{ .failed = .durable_append_failed };
            },
        }
    }

    fn startNextFollowUpOrIdle(self: *AgentSession) void {
        if (self.pending_follow_ups.pop()) |queued| {
            var owned = queued;
            defer owned.deinit(self.allocator);
            self.startRun(.{ .command_id = owned.id, .messages = owned.messages });
            self.refreshActivityCounts();
            return;
        }
        self.setActivity(.idle);
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

    fn drainDecisionAfterTransition(self: *const AgentSession) DrainDecision {
        return switch (self.state_value.activity) {
            .running, .aborting => .stop_draining,
            .idle, .failed => .continue_draining,
        };
    }

    fn assertCanApplyQueuedCommand(self: *const AgentSession, command: OwnedCommand) void {
        switch (command) {
            .submit_prompt, .follow_up, .set_model, .set_reasoning => std.debug.assert(self.isIdleOrFailed()),
            .continue_run => std.debug.assert(self.state_value.activity == .idle),
            .abort_run, .steer => unreachable,
        }
    }

    fn isIdleOrFailed(self: *const AgentSession) bool {
        return switch (self.state_value.activity) {
            .idle, .failed => true,
            .running, .aborting => false,
        };
    }

    fn drainAbortControl(self: *AgentSession) DrainDecision {
        const pending = self.pending_abort orelse return .continue_draining;
        self.pending_abort = null;

        if (self.state_value.activity != .running) return .continue_draining;

        const run_command_id = self.activeCommandId();
        if (self.active_run) |*active| active.cancel_source.requestAbort();
        self.setActivity(.{ .aborting = .{ .command_id = run_command_id, .pending_follow_ups = self.pending_follow_ups.len } });
        self.emit(.{ .run = .{ .abort_requested = .{ .command_id = pending.id, .run_command_id = run_command_id } } });
        return .stop_draining;
    }

    fn nextCommandId(self: *AgentSession) command_mod.CommandId {
        std.debug.assert(self.next_command_id != 0);
        const id = self.next_command_id;
        self.next_command_id += 1;
        std.debug.assert(self.next_command_id != 0);
        return @enumFromInt(id);
    }

    fn setActivity(self: *AgentSession, next: state_mod.Activity) void {
        self.clearActivity();
        self.state_value.activity = next;
        self.assertRunInvariant();
    }

    fn clearActivity(self: *AgentSession) void {
        self.state_value.activity = .idle;
    }

    fn clearActiveRun(self: *AgentSession) void {
        if (self.active_run) |*active| active.deinit(self.allocator);
        self.active_run = null;
    }

    fn assertActiveExecution(self: *const AgentSession, expected: ActiveExecution, comptime message: []const u8) void {
        if (self.active_run) |active| {
            std.debug.assert(active.execution == expected);
        } else {
            std.debug.panic(message, .{});
        }
    }

    fn assertRunInvariant(self: *const AgentSession) void {
        switch (self.state_value.activity) {
            .running, .aborting => std.debug.assert(self.active_run != null),
            .idle, .failed => std.debug.assert(self.active_run == null),
        }
    }

    fn activeCommandId(self: *const AgentSession) command_mod.CommandId {
        return switch (self.state_value.activity) {
            .running => |running| running.command_id,
            .aborting => |aborting| aborting.command_id,
            .idle, .failed => @enumFromInt(0),
        };
    }
};

// Command is borrowed ingress. OwnedCommand is the queue-owned backlog copy.
// Active-run controls that target the current run must not be queued here.
const QueuedCommand = struct {
    id: command_mod.CommandId,
    command: OwnedCommand,

    fn deinit(self: *QueuedCommand, allocator: std.mem.Allocator) void {
        freeCommand(allocator, self.command);
        self.* = undefined;
    }
};

const QueuedAbort = struct {
    id: command_mod.CommandId,
};

const OwnedCommand = union(enum) {
    submit_prompt: command_mod.SubmitPrompt,
    follow_up: command_mod.FollowUp,
    steer: command_mod.Steer,
    abort_run,
    continue_run,
    set_model: command_mod.SetModel,
    set_reasoning: command_mod.SetReasoning,
};

pub const OwnedRunTerminal = struct {
    arena: std.heap.ArenaAllocator,
    status: Status,

    pub const Status = union(enum) {
        completed: []const agent_mod.AgentMessage,
        failed: Failed,
        aborted: []const agent_mod.AgentMessage,
    };

    pub const Failed = struct {
        messages: []const agent_mod.AgentMessage,
        kind: state_mod.FailureKind,
    };

    pub fn completed(allocator: std.mem.Allocator, messages: []const agent_mod.AgentMessage) !OwnedRunTerminal {
        var self = OwnedRunTerminal{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .status = .{ .completed = &.{} },
        };
        errdefer self.deinit();
        self.status = .{ .completed = try cloneMessages(self.arena.allocator(), messages) };
        return self;
    }

    pub fn failed(allocator: std.mem.Allocator, messages: []const agent_mod.AgentMessage, kind: state_mod.FailureKind) !OwnedRunTerminal {
        var self = OwnedRunTerminal{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .status = .{ .failed = .{ .messages = &.{}, .kind = kind } },
        };
        errdefer self.deinit();
        self.status = .{ .failed = .{ .messages = try cloneMessages(self.arena.allocator(), messages), .kind = kind } };
        return self;
    }

    pub fn aborted(allocator: std.mem.Allocator, messages: []const agent_mod.AgentMessage) !OwnedRunTerminal {
        var self = OwnedRunTerminal{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .status = .{ .aborted = &.{} },
        };
        errdefer self.deinit();
        self.status = .{ .aborted = try cloneMessages(self.arena.allocator(), messages) };
        return self;
    }

    pub fn deinit(self: *OwnedRunTerminal) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const RunCompletion = struct {
    terminal: OwnedRunTerminal,

    pub fn deinit(self: *RunCompletion) void {
        self.terminal.deinit();
        self.* = undefined;
    }
};

const RunCapture = struct {
    allocator: std.mem.Allocator,
    input_count: usize,
    terminal: ?OwnedRunTerminal = null,

    fn emit(value: agent_mod.AgentEvent, ctx: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        if (value != .lifecycle) return;
        const lifecycle = value.lifecycle;
        if (lifecycle != .run_finished) return;
        if (self.terminal != null) return;

        self.terminal = switch (lifecycle.run_finished) {
            .completed => |completed| OwnedRunTerminal.completed(self.allocator, self.outputMessages(completed.messages)) catch |err| oomTerminal(self.allocator, err),
            .failed => |failed| OwnedRunTerminal.failed(self.allocator, self.outputMessages(failed.messages), failureKind(failed.reason)) catch |err| oomTerminal(self.allocator, err),
            .aborted => |aborted| OwnedRunTerminal.aborted(self.allocator, self.outputMessages(aborted.messages)) catch |err| oomTerminal(self.allocator, err),
        };
    }

    fn outputMessages(self: *const RunCapture, messages: []const agent_mod.AgentMessage) []const agent_mod.AgentMessage {
        if (messages.len <= self.input_count) return &.{};
        return messages[self.input_count..];
    }

    fn takeTerminal(self: *RunCapture) ?OwnedRunTerminal {
        const terminal = self.terminal orelse return null;
        self.terminal = null;
        return terminal;
    }

    fn deinit(self: *RunCapture) void {
        if (self.terminal) |*terminal| terminal.deinit();
        self.* = undefined;
    }
};

fn oomTerminal(allocator: std.mem.Allocator, _: anyerror) OwnedRunTerminal {
    return OwnedRunTerminal.failed(allocator, &.{}, .out_of_memory) catch @panic("OOM while recording run terminal");
}

fn cloneModel(allocator: std.mem.Allocator, model: agent_mod.message.Model) !agent_mod.message.Model {
    const id = try allocator.dupe(u8, model.id);
    errdefer allocator.free(id);
    const name = try allocator.dupe(u8, model.name);
    errdefer allocator.free(name);
    const base_url = try allocator.dupe(u8, model.base_url);
    errdefer allocator.free(base_url);
    const input = try allocator.dupe(ai.protocol.Model.InputType, model.input);
    errdefer allocator.free(input);
    const headers = if (model.headers) |source| try cloneHeaders(allocator, source) else null;
    errdefer if (headers) |owned| freeHeaders(allocator, owned);

    return .{
        .id = id,
        .name = name,
        .api = model.api,
        .provider = model.provider,
        .base_url = base_url,
        .reasoning = model.reasoning,
        .input = input,
        .cost = model.cost,
        .context_window = model.context_window,
        .max_tokens = model.max_tokens,
        .headers = headers,
        .compat = model.compat,
    };
}

fn cloneHeaders(allocator: std.mem.Allocator, headers: []const ai.protocol.Header) ![]const ai.protocol.Header {
    const out = try allocator.alloc(ai.protocol.Header, headers.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |header| {
            allocator.free(header.key);
            allocator.free(header.value);
        }
        allocator.free(out);
    }
    for (headers, 0..) |header, i| {
        out[i] = .{
            .key = try allocator.dupe(u8, header.key),
            .value = try allocator.dupe(u8, header.value),
        };
        initialized += 1;
    }
    return out;
}

fn cloneCommand(allocator: std.mem.Allocator, value: command_mod.Command) !OwnedCommand {
    return switch (value) {
        .submit_prompt => |prompt| .{ .submit_prompt = .{ .messages = try cloneMessages(allocator, prompt.messages) } },
        .follow_up => |follow_up| .{ .follow_up = .{ .messages = try cloneMessages(allocator, follow_up.messages) } },
        .steer => |steer| .{ .steer = .{ .text = try allocator.dupe(u8, steer.text) } },
        .set_model => |set| .{ .set_model = .{ .model = try cloneModel(allocator, set.model) } },
        .set_reasoning => |set| .{ .set_reasoning = set },
        .abort_run => .abort_run,
        .continue_run => .continue_run,
    };
}

fn freeCommand(allocator: std.mem.Allocator, value: OwnedCommand) void {
    switch (value) {
        .submit_prompt => |prompt| freeMessages(allocator, prompt.messages),
        .follow_up => |follow_up| freeMessages(allocator, follow_up.messages),
        .steer => |steer| allocator.free(steer.text),
        .set_model => |set| freeModel(allocator, set.model),
        .set_reasoning => {},
        .abort_run, .continue_run => {},
    }
}

fn freeModel(allocator: std.mem.Allocator, model: agent_mod.message.Model) void {
    allocator.free(model.id);
    allocator.free(model.name);
    allocator.free(model.base_url);
    allocator.free(model.input);
    if (model.headers) |headers| {
        freeHeaders(allocator, headers);
    }
}

fn freeHeaders(allocator: std.mem.Allocator, headers: []const ai.protocol.Header) void {
    for (headers) |header| {
        allocator.free(header.key);
        allocator.free(header.value);
    }
    allocator.free(headers);
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

const observed_event_count = 16;
const ObservedEvent = enum {
    command_accepted,
    session_appended,
    append_rejected,
    append_failed,
    run_started,
    run_follow_up_queued,
    run_abort_requested,
    run_finished_completed,
    run_finished_failed,
    run_finished_aborted,
};

const EventCollector = struct {
    items: [observed_event_count]ObservedEvent = undefined,
    len: usize = 0,

    fn emit(value: event_mod.Event, ctx: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        std.debug.assert(self.len < observed_event_count);
        self.items[self.len] = switch (value) {
            .command => |command| switch (command) {
                .accepted => .command_accepted,
                .rejected => .append_rejected,
            },
            .session => |session| switch (session) {
                .appended => .session_appended,
                .append_rejected => .append_rejected,
                .append_failed => .append_failed,
            },
            .run => |run| switch (run) {
                .started => .run_started,
                .follow_up_queued => .run_follow_up_queued,
                .abort_requested => .run_abort_requested,
                .finished => |finished| switch (finished.terminal) {
                    .completed => .run_finished_completed,
                    .failed => .run_finished_failed,
                    .aborted => .run_finished_aborted,
                },
            },
        };
        self.len += 1;
    }
};

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

fn testModelWithId(id: []const u8) agent_mod.message.Model {
    var model = testModel();
    model.id = id;
    model.name = id;
    return model;
}

fn convertNoop(_: ?*anyopaque, _: std.mem.Allocator, _: []const agent_mod.AgentMessage) error{OutOfMemory}![]const @import("../ai/root.zig").protocol.Message {
    return &.{};
}

fn completeWithAssistant(_: ?*anyopaque, _: std.mem.Allocator, _: agent_mod.message.Model, _: @import("../ai/root.zig").protocol.Context, _: @import("../ai/root.zig").protocol.SimpleStreamOptions, sink: @import("../ai/root.zig").provider.StreamEventSink) error{OutOfMemory}!void {
    sink.emit(.{ .done = .{ .reason = .stop, .message = testAssistantMessage().assistant } });
}

const SpecCapture = struct {
    model_id: []const u8 = "",
    reasoning: ?ai.protocol.ThinkingLevel = null,

    fn stream(ctx: ?*anyopaque, _: std.mem.Allocator, model: agent_mod.message.Model, _: ai.protocol.Context, options: ai.protocol.SimpleStreamOptions, sink: ai.provider.StreamEventSink) error{OutOfMemory}!void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.model_id = model.id;
        self.reasoning = options.reasoning;
        sink.emit(.{ .done = .{ .reason = .stop, .message = testAssistantMessage().assistant } });
    }
};

fn testPolicy() AgentSession.SessionPolicyInit {
    return .{ .model = testModel() };
}

fn testExecutionBackend() AgentSession.ExecutionBackend {
    return .{
        .stream = .{ .call_fn = completeWithAssistant },
        .convert_messages = .{ .call_fn = convertNoop },
    };
}

fn captureExecutionBackend(capture: *SpecCapture) AgentSession.ExecutionBackend {
    return .{
        .stream = .{ .call_fn = SpecCapture.stream, .ctx = capture },
        .convert_messages = .{ .call_fn = convertNoop },
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

test "agent session snapshots policy and executes backend to terminal through owner drain" {
    var durable = durable_mod.ScriptedAppender{ .result = .{ .appended = [_]u8{'e'} ** session_event_mod.event_id_hex_len } };
    var events: EventCollector = .{};
    var session = try AgentSession.init(std.testing.allocator, .{
        .durable_appender = .{ .scripted = &durable },
        .event_sink = .{ .emit_fn = EventCollector.emit, .ctx = &events },
        .policy = testPolicy(),
        .execution = .{ .synchronous = testExecutionBackend() },
    });
    defer session.deinit();

    const messages = [_]agent_mod.AgentMessage{.{ .user = .{ .content = .{ .text = "hello" }, .timestamp = 1 } }};
    _ = try session.submit(.{ .submit_prompt = .{ .messages = &messages } });
    session.drainCommands();

    try std.testing.expect(session.state().activity == .idle);
    try std.testing.expectEqual(@as(usize, 2), durable.message_count);
    try std.testing.expectEqualSlices(ObservedEvent, &.{ .command_accepted, .session_appended, .run_started, .session_appended, .run_finished_completed }, events.items[0..events.len]);
}

test "synchronous execution requires selected model policy" {
    var events: EventCollector = .{};
    var session = try AgentSession.init(std.testing.allocator, .{
        .event_sink = .{ .emit_fn = EventCollector.emit, .ctx = &events },
        .execution = .{ .synchronous = testExecutionBackend() },
    });
    defer session.deinit();

    _ = try session.submit(.{ .submit_prompt = .{ .messages = &.{} } });
    session.drainCommands();

    try std.testing.expect(session.state().activity == .failed);
    try std.testing.expectEqualSlices(ObservedEvent, &.{ .command_accepted, .run_started, .run_finished_failed }, events.items[0..events.len]);
}

test "policy commands update owned run spec inputs while idle" {
    var capture = SpecCapture{};
    var session = try AgentSession.init(std.testing.allocator, .{
        .policy = testPolicy(),
        .execution = .{ .synchronous = captureExecutionBackend(&capture) },
    });
    defer session.deinit();

    _ = try session.submit(.{ .set_model = .{ .model = testModelWithId("next-model") } });
    _ = try session.submit(.{ .set_reasoning = .{ .reasoning = .high } });
    session.drainCommands();

    _ = try session.submit(.{ .submit_prompt = .{ .messages = &.{} } });
    session.drainCommands();

    try std.testing.expect(session.state().activity == .idle);
    try std.testing.expectEqualStrings("next-model", capture.model_id);
    try std.testing.expectEqual(ai.protocol.ThinkingLevel.high, capture.reasoning.?);
}

test "policy commands are rejected while running" {
    var session = try AgentSession.init(std.testing.allocator, .{
        .policy = testPolicy(),
        .execution = .external_terminal,
    });
    defer session.deinit();

    _ = try session.submit(.{ .submit_prompt = .{ .messages = &.{} } });
    session.drainCommands();

    try std.testing.expect(session.state().activity == .running);
    try std.testing.expectEqual(command_mod.Rejection.busy, (try session.submit(.{ .set_model = .{ .model = testModelWithId("rejected") } })).rejected);
    try std.testing.expectEqual(command_mod.Rejection.busy, (try session.submit(.{ .set_reasoning = .{ .reasoning = .low } })).rejected);
}

test "follow up while running emits queued fact with active run id" {
    const Collector = struct {
        command_id: command_mod.CommandId = @enumFromInt(0),
        run_command_id: command_mod.CommandId = @enumFromInt(0),
        pending_follow_ups: usize = 0,
        state_pending_follow_ups: usize = 0,
        session: *AgentSession,

        fn emit(value: event_mod.Event, ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (value != .run) return;
            if (value.run != .follow_up_queued) return;
            const queued = value.run.follow_up_queued;
            self.command_id = queued.command_id;
            self.run_command_id = queued.run_command_id;
            self.pending_follow_ups = queued.pending_follow_ups;
            self.state_pending_follow_ups = self.session.state().activity.running.pending_follow_ups;
        }
    };

    var session = try AgentSession.init(std.testing.allocator, .{ .execution = .external_terminal });
    defer session.deinit();
    var collector = Collector{ .session = &session };
    session.event_sink = .{ .emit_fn = Collector.emit, .ctx = &collector };

    const run_id = (try session.submit(.{ .submit_prompt = .{ .messages = &.{} } })).accepted;
    session.drainCommands();
    const follow_up_id = (try session.submit(.{ .follow_up = .{ .messages = &.{} } })).accepted;

    try std.testing.expectEqual(follow_up_id, collector.command_id);
    try std.testing.expectEqual(run_id, collector.run_command_id);
    try std.testing.expectEqual(@as(usize, 1), collector.pending_follow_ups);
    try std.testing.expectEqual(@as(usize, 1), collector.state_pending_follow_ups);
}

test "external terminal execution keeps active run until terminal" {
    var session = try AgentSession.init(std.testing.allocator, .{ .execution = .external_terminal });
    defer session.deinit();

    _ = try session.submit(.{ .submit_prompt = .{ .messages = &.{} } });
    session.drainCommands();

    try std.testing.expect(session.state().activity == .running);
}

test "external terminal drain stops after starting one queued run" {
    var events = EventCollector{};
    var session = try AgentSession.init(std.testing.allocator, .{
        .execution = .external_terminal,
        .event_sink = .{ .emit_fn = EventCollector.emit, .ctx = &events },
    });
    defer session.deinit();

    const first = (try session.submit(.{ .submit_prompt = .{ .messages = &.{} } })).accepted;
    const second = (try session.submit(.{ .follow_up = .{ .messages = &.{} } })).accepted;

    session.drainCommands();
    try std.testing.expect(session.state().activity == .running);
    try std.testing.expectEqual(first, session.state().activity.running.command_id);
    try std.testing.expectEqualSlices(ObservedEvent, &.{ .command_accepted, .command_accepted, .run_started }, events.items[0..events.len]);

    const terminal = try OwnedRunTerminal.completed(std.testing.allocator, &.{});
    var completion = RunCompletion{ .terminal = terminal };
    session.completeRun(&completion);
    try std.testing.expect(session.state().activity == .idle);

    session.drainCommands();
    try std.testing.expect(session.state().activity == .running);
    try std.testing.expectEqual(second, session.state().activity.running.command_id);
    try std.testing.expectEqualSlices(ObservedEvent, &.{ .command_accepted, .command_accepted, .run_started, .run_finished_completed, .run_started }, events.items[0..events.len]);
}

test "synchronous drain continues after completed queued run" {
    var events = EventCollector{};
    var session = try AgentSession.init(std.testing.allocator, .{
        .policy = testPolicy(),
        .execution = .{ .synchronous = testExecutionBackend() },
        .event_sink = .{ .emit_fn = EventCollector.emit, .ctx = &events },
    });
    defer session.deinit();

    _ = try session.submit(.{ .submit_prompt = .{ .messages = &.{} } });
    _ = try session.submit(.{ .follow_up = .{ .messages = &.{} } });
    session.drainCommands();

    try std.testing.expect(session.state().activity == .idle);
    try std.testing.expectEqualSlices(ObservedEvent, &.{ .command_accepted, .command_accepted, .run_started, .run_finished_completed, .run_started, .run_finished_completed }, events.items[0..events.len]);
}

test "abort in external terminal mode keeps original run command id" {
    const Collector = struct {
        finished_command_id: command_mod.CommandId = @enumFromInt(0),
        abort_command_id: command_mod.CommandId = @enumFromInt(0),
        abort_run_command_id: command_mod.CommandId = @enumFromInt(0),

        fn emit(value: event_mod.Event, ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (value != .run) return;
            switch (value.run) {
                .abort_requested => |abort| {
                    self.abort_command_id = abort.command_id;
                    self.abort_run_command_id = abort.run_command_id;
                },
                .finished => |finished| self.finished_command_id = finished.command_id,
                .follow_up_queued => {},
                .started => {},
            }
        }
    };

    var collector = Collector{};
    var session = try AgentSession.init(std.testing.allocator, .{
        .execution = .external_terminal,
        .event_sink = .{ .emit_fn = Collector.emit, .ctx = &collector },
    });
    defer session.deinit();

    const started = (try session.submit(.{ .submit_prompt = .{ .messages = &.{} } })).accepted;
    session.drainCommands();
    const abort_command_id = (try session.submit(.abort_run)).accepted;
    session.drainCommands();

    try std.testing.expect(session.state().activity == .aborting);
    try std.testing.expectEqual(started, session.state().activity.aborting.command_id);
    try std.testing.expectEqual(abort_command_id, collector.abort_command_id);
    try std.testing.expectEqual(started, collector.abort_run_command_id);

    const terminal = try OwnedRunTerminal.aborted(std.testing.allocator, &.{});
    var completion = RunCompletion{ .terminal = terminal };
    session.completeRun(&completion);

    try std.testing.expect(session.state().activity == .idle);
    try std.testing.expectEqual(started, collector.finished_command_id);
}

test "abort control drains before queued future runs" {
    const Collector = struct {
        abort_run_command_id: command_mod.CommandId = @enumFromInt(0),
        started_after_abort: bool = false,
        saw_abort: bool = false,

        fn emit(value: event_mod.Event, ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (value != .run) return;
            switch (value.run) {
                .abort_requested => |abort| {
                    self.saw_abort = true;
                    self.abort_run_command_id = abort.run_command_id;
                },
                .started => {
                    if (self.saw_abort) self.started_after_abort = true;
                },
                .follow_up_queued => {},
                .finished => {},
            }
        }
    };

    var collector = Collector{};
    var session = try AgentSession.init(std.testing.allocator, .{
        .execution = .external_terminal,
        .event_sink = .{ .emit_fn = Collector.emit, .ctx = &collector },
    });
    defer session.deinit();

    const first = (try session.submit(.{ .submit_prompt = .{ .messages = &.{} } })).accepted;
    const second = (try session.submit(.{ .submit_prompt = .{ .messages = &.{} } })).accepted;
    _ = second;

    session.drainCommands();
    try std.testing.expect(session.state().activity == .running);
    try std.testing.expectEqual(first, session.state().activity.running.command_id);

    _ = try session.submit(.abort_run);
    session.drainCommands();

    try std.testing.expect(session.state().activity == .aborting);
    try std.testing.expectEqual(first, session.state().activity.aborting.command_id);
    try std.testing.expectEqual(first, collector.abort_run_command_id);
    try std.testing.expect(!collector.started_after_abort);
}

test "run completion updates product activity before notifying" {
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

    const terminal = try OwnedRunTerminal.completed(std.testing.allocator, &.{});
    var completion = RunCompletion{ .terminal = terminal };
    session.completeRun(&completion);
    try std.testing.expect(collector.saw_idle);
}

test "prompt append happens before run start" {
    var durable = durable_mod.ScriptedAppender{ .result = .{ .appended = [_]u8{'a'} ** session_event_mod.event_id_hex_len } };
    var events: EventCollector = .{};
    var session = try AgentSession.init(std.testing.allocator, .{
        .durable_appender = .{ .scripted = &durable },
        .event_sink = .{ .emit_fn = EventCollector.emit, .ctx = &events },
    });
    defer session.deinit();

    const messages = [_]agent_mod.AgentMessage{.{ .user = .{ .content = .{ .text = "hello" }, .timestamp = 1 } }};
    _ = try session.submit(.{ .submit_prompt = .{ .messages = &messages } });
    session.drainCommands();

    try std.testing.expectEqual(@as(usize, 1), durable.message_count);
    try std.testing.expect(session.state().activity == .running);
    try std.testing.expectEqualSlices(ObservedEvent, &.{ .command_accepted, .session_appended, .run_started }, events.items[0..events.len]);
}

test "append rejection prevents run start" {
    var durable = durable_mod.ScriptedAppender{ .result = .{ .rejected = .invalid_state } };
    var events: EventCollector = .{};
    var session = try AgentSession.init(std.testing.allocator, .{
        .durable_appender = .{ .scripted = &durable },
        .event_sink = .{ .emit_fn = EventCollector.emit, .ctx = &events },
    });
    defer session.deinit();

    const messages = [_]agent_mod.AgentMessage{.{ .user = .{ .content = .{ .text = "hello" }, .timestamp = 1 } }};
    _ = try session.submit(.{ .submit_prompt = .{ .messages = &messages } });
    session.drainCommands();

    try std.testing.expectEqual(@as(usize, 1), durable.message_count);
    try std.testing.expect(session.state().activity == .failed);
    try std.testing.expectEqualSlices(ObservedEvent, &.{ .command_accepted, .append_rejected }, events.items[0..events.len]);
}

test "append failure prevents run start" {
    var durable = durable_mod.ScriptedAppender{ .result = .{ .failed = .io } };
    var events: EventCollector = .{};
    var session = try AgentSession.init(std.testing.allocator, .{
        .durable_appender = .{ .scripted = &durable },
        .event_sink = .{ .emit_fn = EventCollector.emit, .ctx = &events },
    });
    defer session.deinit();

    const messages = [_]agent_mod.AgentMessage{.{ .user = .{ .content = .{ .text = "hello" }, .timestamp = 1 } }};
    _ = try session.submit(.{ .submit_prompt = .{ .messages = &messages } });
    session.drainCommands();

    try std.testing.expectEqual(@as(usize, 1), durable.message_count);
    try std.testing.expect(session.state().activity == .failed);
    try std.testing.expectEqualSlices(ObservedEvent, &.{ .command_accepted, .append_failed }, events.items[0..events.len]);
}

test "multi message prompt is rejected before partial durable append" {
    var durable = durable_mod.ScriptedAppender{ .result = .{ .appended = [_]u8{'a'} ** session_event_mod.event_id_hex_len } };
    var events: EventCollector = .{};
    var session = try AgentSession.init(std.testing.allocator, .{
        .durable_appender = .{ .scripted = &durable },
        .event_sink = .{ .emit_fn = EventCollector.emit, .ctx = &events },
    });
    defer session.deinit();

    const messages = [_]agent_mod.AgentMessage{
        .{ .user = .{ .content = .{ .text = "one" }, .timestamp = 1 } },
        .{ .user = .{ .content = .{ .text = "two" }, .timestamp = 2 } },
    };
    _ = try session.submit(.{ .submit_prompt = .{ .messages = &messages } });
    session.drainCommands();

    try std.testing.expectEqual(@as(usize, 0), durable.message_count);
    try std.testing.expect(session.state().activity == .failed);
    try std.testing.expectEqualSlices(ObservedEvent, &.{ .command_accepted, .append_rejected }, events.items[0..events.len]);
}

test "completed terminal appends messages before run finished" {
    var durable = durable_mod.ScriptedAppender{ .result = .{ .appended = [_]u8{'b'} ** session_event_mod.event_id_hex_len } };
    var events: EventCollector = .{};
    var session = try AgentSession.init(std.testing.allocator, .{
        .durable_appender = .{ .scripted = &durable },
        .event_sink = .{ .emit_fn = EventCollector.emit, .ctx = &events },
    });
    defer session.deinit();

    _ = try session.submit(.{ .submit_prompt = .{ .messages = &.{} } });
    session.drainCommands();

    const messages = [_]agent_mod.AgentMessage{testAssistantMessage()};
    const terminal = try OwnedRunTerminal.completed(std.testing.allocator, &messages);
    var completion = RunCompletion{ .terminal = terminal };
    session.completeRun(&completion);

    try std.testing.expect(session.state().activity == .idle);
    try std.testing.expectEqual(@as(usize, 1), durable.message_count);
    try std.testing.expectEqualSlices(ObservedEvent, &.{ .command_accepted, .run_started, .session_appended, .run_finished_completed }, events.items[0..events.len]);
}

test "completed terminal starts queued follow up only after run finished" {
    var durable = durable_mod.ScriptedAppender{ .result = .{ .appended = [_]u8{'c'} ** session_event_mod.event_id_hex_len } };
    var events: EventCollector = .{};
    var session = try AgentSession.init(std.testing.allocator, .{
        .durable_appender = .{ .scripted = &durable },
        .event_sink = .{ .emit_fn = EventCollector.emit, .ctx = &events },
    });
    defer session.deinit();

    _ = try session.submit(.{ .submit_prompt = .{ .messages = &.{} } });
    session.drainCommands();
    _ = try session.submit(.{ .follow_up = .{ .messages = &.{} } });

    const messages = [_]agent_mod.AgentMessage{testAssistantMessage()};
    const terminal = try OwnedRunTerminal.completed(std.testing.allocator, &messages);
    var completion = RunCompletion{ .terminal = terminal };
    session.completeRun(&completion);

    try std.testing.expect(session.state().activity == .running);
    try std.testing.expectEqualSlices(ObservedEvent, &.{ .command_accepted, .run_started, .command_accepted, .run_follow_up_queued, .session_appended, .run_finished_completed, .run_started }, events.items[0..events.len]);
}

test "terminal append failure prevents queued follow up" {
    var durable = durable_mod.ScriptedAppender{ .result = .{ .failed = .io } };
    var events: EventCollector = .{};
    var session = try AgentSession.init(std.testing.allocator, .{
        .durable_appender = .{ .scripted = &durable },
        .event_sink = .{ .emit_fn = EventCollector.emit, .ctx = &events },
    });
    defer session.deinit();

    _ = try session.submit(.{ .submit_prompt = .{ .messages = &.{} } });
    session.drainCommands();
    _ = try session.submit(.{ .follow_up = .{ .messages = &.{} } });

    const messages = [_]agent_mod.AgentMessage{testAssistantMessage()};
    const terminal = try OwnedRunTerminal.completed(std.testing.allocator, &messages);
    var completion = RunCompletion{ .terminal = terminal };
    session.completeRun(&completion);

    try std.testing.expect(session.state().activity == .failed);
    try std.testing.expectEqualSlices(ObservedEvent, &.{ .command_accepted, .run_started, .command_accepted, .run_follow_up_queued, .append_failed, .run_finished_failed }, events.items[0..events.len]);
}

test "failed and aborted terminals do not append messages" {
    var durable = durable_mod.ScriptedAppender{ .result = .{ .appended = [_]u8{'d'} ** session_event_mod.event_id_hex_len } };
    var events: EventCollector = .{};
    var session = try AgentSession.init(std.testing.allocator, .{
        .durable_appender = .{ .scripted = &durable },
        .event_sink = .{ .emit_fn = EventCollector.emit, .ctx = &events },
    });
    defer session.deinit();

    _ = try session.submit(.{ .submit_prompt = .{ .messages = &.{} } });
    session.drainCommands();
    _ = try session.submit(.{ .follow_up = .{ .messages = &.{} } });

    const messages = [_]agent_mod.AgentMessage{testAssistantMessage()};
    const failed = try OwnedRunTerminal.failed(std.testing.allocator, &messages, .internal);
    var completion = RunCompletion{ .terminal = failed };
    session.completeRun(&completion);

    try std.testing.expectEqual(@as(usize, 0), durable.message_count);
    try std.testing.expect(session.state().activity == .failed);

    var session2 = try AgentSession.init(std.testing.allocator, .{ .durable_appender = .{ .scripted = &durable } });
    defer session2.deinit();
    _ = try session2.submit(.{ .submit_prompt = .{ .messages = &.{} } });
    session2.drainCommands();
    _ = try session2.submit(.{ .follow_up = .{ .messages = &.{} } });
    const aborted = try OwnedRunTerminal.aborted(std.testing.allocator, &messages);
    var aborted_completion = RunCompletion{ .terminal = aborted };
    session2.completeRun(&aborted_completion);
    try std.testing.expectEqual(@as(usize, 0), durable.message_count);
    try std.testing.expect(session2.state().activity == .idle);
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

    const terminal = try OwnedRunTerminal.completed(std.testing.allocator, &.{});
    var completion = RunCompletion{ .terminal = terminal };
    session.completeRun(&completion);
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

    const aborted = try OwnedRunTerminal.aborted(std.testing.allocator, &.{});
    var completion = RunCompletion{ .terminal = aborted };
    session.completeRun(&completion);
    try std.testing.expect(session.state().activity == .idle);

    _ = try session.submit(.{ .submit_prompt = .{ .messages = &.{} } });
    session.drainCommands();
    _ = try session.submit(.{ .follow_up = .{ .messages = &.{} } });
    const failed = try OwnedRunTerminal.failed(std.testing.allocator, &.{}, .internal);
    var failed_completion = RunCompletion{ .terminal = failed };
    session.completeRun(&failed_completion);
    try std.testing.expect(session.state().activity == .failed);
}
