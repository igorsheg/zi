const std = @import("std");
const ai = @import("../ai/root.zig");
const agent_mod = @import("../agent/root.zig");
const settings_resolve = @import("../settings/resolve.zig");
const command_mod = @import("command.zig");
const event_mod = @import("event.zig");
const extension_mod = @import("extension.zig");
const builtin_tools = @import("builtin_tools.zig");
const provider_backend = @import("provider_backend.zig");
const provider_runtime_mod = @import("provider_runtime.zig");
const durable_mod = @import("durable.zig");
const session_policy_mod = @import("session_policy.zig");
const durable_projection_mod = @import("session_durable_projection.zig");
const session_event_mod = @import("../session/event.zig");

pub const OwnedRunTerminal = agent_mod.run_terminal.OwnedRunTerminal;
const PolicyInit = session_policy_mod.Init;
const Policy = session_policy_mod.SessionPolicy;
const message_memory = agent_mod.message_memory;

pub const max_queued_followups: usize = 8;

pub const ToolsMode = enum { none, builtins };

pub const ManagedOptions = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    provider_runtime: ?*provider_runtime_mod.ProviderRuntime = null,
    model: ?[]const u8 = null,
    tools: ToolsMode = .builtins,
    event_sink: ?event_mod.Sink = null,
    demo_prompt: []const u8 = "",
};

pub const ManagedInitResult = union(enum) {
    ok: AgentSession,
    err: Diagnostic,
};

pub const Diagnostic = union(enum) {
    missing_model,
    unknown_model,
    invalid_settings_model: settings_resolve.Diagnostic,
    provider_unavailable,
    missing_api_key,
};

pub const AgentSession = struct {
    allocator: std.mem.Allocator,
    policy: Policy,
    owner_call_active: bool = false,
    next_command_id: u64 = 1,
    // Event sinks run synchronously inside the current owner call. They may
    // observe AgentSession state, but public owner entry points assert against
    // reentrant mutation. Replace this with an explicit bounded event queue
    // when a caller needs post-transition delivery/backpressure semantics.
    event_sink: ?event_mod.Sink = null,
    durable_appender: durable_mod.Appender = .disabled,
    extension_host: extension_mod.Host = .disabled,
    agent: agent_mod.Agent,
    builtins: ?builtin_tools.Builtins = null,
    provider: ?*ai.provider.Provider = null,
    demo_backend: ?*agent_mod.demo_backend.Backend = null,

    pub const Options = struct {
        follow_up_capacity: usize = max_queued_followups,
        event_sink: ?event_mod.Sink = null,
        durable_appender: durable_mod.Appender = .disabled,
        extension_host: extension_mod.Host = .disabled,
        policy: PolicyInit = .{},
        backend: agent_mod.config.RunBackend,
    };

    pub const ExecutionBackend = agent_mod.config.RunBackend;

    const SessionRunFailure = enum {
        missing_model,

        fn failureKind(self: SessionRunFailure) agent_mod.failure.Kind {
            return switch (self) {
                .missing_model => .invalid_context,
            };
        }
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) !AgentSession {
        var policy = try Policy.init(allocator, options.policy);
        errdefer policy.deinit();

        var extension_host = options.extension_host;
        errdefer extension_host.deinit();

        var agent = try agent_mod.Agent.init(allocator, .{
            .model = policy.model orelse return error.InvalidModel,
            .backend = options.backend,
            .system_prompt = policy.system_prompt,
            .reasoning = policy.reasoning,
            .tools = extension_host.tools(),
            .sink = null,
        });
        errdefer agent.deinit();

        const self: AgentSession = .{
            .allocator = allocator,
            .policy = policy,
            .event_sink = options.event_sink,
            .durable_appender = options.durable_appender,
            .extension_host = extension_host,
            .agent = agent,
        };
        return self;
    }

    pub fn initManaged(options: ManagedOptions) (error{OutOfMemory} || extension_mod.InitError)!ManagedInitResult {
        const allocator = options.allocator;
        var self = AgentSession{
            .allocator = allocator,
            .policy = undefined,
            .agent = undefined,
        };

        self.policy = try Policy.init(allocator, .{});
        errdefer self.policy.deinit();
        self.event_sink = options.event_sink;

        self.extension_host = switch (options.tools) {
            .none => extension_mod.Host.disabled,
            .builtins => blk: {
                self.builtins = try builtin_tools.Builtins.init(allocator, .{ .bash = .{ .io = options.io } });
                errdefer if (self.builtins) |*builtins_value| builtins_value.deinit();
                break :blk try self.builtins.?.host(allocator);
            },
        };
        errdefer self.extension_host.deinit();

        const resolved = switch (try self.resolveManagedExecution(options)) {
            .ok => |ok| ok,
            .err => |diag| return .{ .err = diag },
        };
        self.policy.model = resolved.model;
        self.agent = try agent_mod.Agent.init(allocator, .{
            .model = resolved.model,
            .backend = resolved.backend,
            .system_prompt = self.policy.system_prompt,
            .reasoning = self.policy.reasoning,
            .tools = self.extension_host.tools(),
            .sink = .{ .emit_fn = emitAgentEventFromAgent, .ctx = &self },
        });
        errdefer self.agent.deinit();
        return .{ .ok = self };
    }

    // deinit is destructive cleanup. It does not emit terminal events or
    // perform graceful cancellation. Runtime-backed execution must be shut down
    // before deinit so no completion can arrive after this object is destroyed.
    pub fn deinit(self: *AgentSession) void {
        self.agent.deinit();
        self.extension_host.deinit();
        if (self.provider) |provider| self.allocator.destroy(provider);
        if (self.demo_backend) |demo_backend| self.allocator.destroy(demo_backend);
        if (self.builtins) |*builtins_value| builtins_value.deinit();
        self.policy.deinit();
        self.* = undefined;
    }

    const ResolvedExecution = struct {
        model: agent_mod.message.Model,
        backend: agent_mod.config.RunBackend,
    };

    const ResolveExecutionResult = union(enum) {
        ok: ResolvedExecution,
        err: Diagnostic,
    };

    fn resolveManagedExecution(self: *AgentSession, options: ManagedOptions) error{OutOfMemory}!ResolveExecutionResult {
        const requested = options.model orelse {
            self.demo_backend = try self.allocator.create(agent_mod.demo_backend.Backend);
            self.demo_backend.?.* = .{ .prompt = options.demo_prompt };
            return .{ .ok = .{
                .model = agent_mod.demo_backend.model("demo"),
                .backend = self.demo_backend.?.runBackend(options.io),
            } };
        };

        const runtime = options.provider_runtime orelse return .{ .err = .missing_model };
        const model = switch (runtime.resolveModel(requested)) {
            .ok => |model| model,
            .unknown_model => return .{ .err = .unknown_model },
            .invalid_settings_model => |diag| return .{ .err = .{ .invalid_settings_model = diag } },
        };
        const resolved_provider = runtime.resolveProvider(model) catch |err| switch (err) {
            error.ProviderUnavailable => return .{ .err = .provider_unavailable },
            error.MissingApiKey => return .{ .err = .missing_api_key },
        };
        self.provider = try self.allocator.create(ai.provider.Provider);
        self.provider.?.* = resolved_provider.provider;
        return .{ .ok = .{ .model = model, .backend = provider_backend.synchronous(self.provider.?, .{
            .io = options.io,
            .api_key = resolved_provider.api_key,
            .transport = resolved_provider.transport,
        }) } };
    }

    pub fn submit(self: *AgentSession, command: command_mod.Command) error{OutOfMemory}!command_mod.SubmitResult {
        self.enterOwnerCall();
        defer self.leaveOwnerCall();

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

        return self.acceptAndApply(command);
    }

    pub fn state(self: *const AgentSession) agent_mod.Agent.State {
        return self.agent.state();
    }

    fn rejectCommand(self: *const AgentSession, command: command_mod.Command) ?command_mod.Rejection {
        return switch (command) {
            .submit_prompt => switch (self.state().activity) {
                .idle, .failed => null,
                else => .busy,
            },
            .continue_run => switch (self.state().activity) {
                .idle => null,
                else => .busy,
            },
            .set_model, .set_reasoning => switch (self.state().activity) {
                .idle, .failed => null,
                .running, .aborting => .busy,
            },
            .abort_run => switch (self.state().activity) {
                .running => null,
                .idle, .aborting, .failed => .invalid_state,
            },
            .follow_up, .steer => unreachable,
        };
    }

    fn applyCommand(self: *AgentSession, command: command_mod.Command) void {
        self.assertCanApplyCommand(command);
        switch (command) {
            .submit_prompt => |prompt| self.runPromptCommand(prompt.messages),
            .follow_up => |follow_up| self.runFollowUpCommand(follow_up.messages),
            .continue_run => self.runContinueCommand(),
            .set_model => |set| {
                self.policy.replaceModel(self.allocator, set.model) catch {
                    self.setAgentFailure(.out_of_memory);
                };
            },
            .set_reasoning => |set| {
                self.policy.setReasoning(set.reasoning);
            },
            .steer => std.debug.panic("steer command must not enter command queue before agent control support", .{}),
            .abort_run => unreachable,
        }
    }

    fn emit(self: *AgentSession, value: event_mod.Event) void {
        if (self.event_sink) |sink| sink.emit(value);
    }

    fn submitFollowUp(self: *AgentSession, follow_up: command_mod.FollowUp) error{OutOfMemory}!command_mod.SubmitResult {
        return switch (self.state().activity) {
            .idle, .failed => self.acceptAndApply(.{ .follow_up = follow_up }),
            .running => self.acceptRunningFollowUp(follow_up),
            .aborting => |aborting| blk: {
                _ = aborting;
                self.emit(.{ .command = .{ .rejected = .invalid_state } });
                break :blk .{ .rejected = .invalid_state };
            },
        };
    }

    fn submitSteer(self: *AgentSession, steer: command_mod.Steer) command_mod.SubmitResult {
        return switch (self.state().activity) {
            .running => blk: {
                const id = self.nextCommandId();
                self.agent.steer(steer.messages) catch {
                    self.emit(.{ .command = .{ .rejected = .queue_full } });
                    break :blk .{ .rejected = .queue_full };
                };
                self.emit(.{ .command = .{ .accepted = id } });
                break :blk .{ .accepted = id };
            },
            .idle, .aborting, .failed => blk: {
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
        self.agent.abort();
        self.emit(.{ .command = .{ .accepted = id } });
        self.emit(.{ .control = .{ .abort_requested = .{ .command_id = id } } });
        return .{ .accepted = id };
    }

    fn acceptAndApply(self: *AgentSession, command: command_mod.Command) error{OutOfMemory}!command_mod.SubmitResult {
        const id = self.nextCommandId();
        self.emit(.{ .command = .{ .accepted = id } });
        self.applyCommand(command);
        return .{ .accepted = id };
    }

    fn acceptRunningFollowUp(self: *AgentSession, follow_up: command_mod.FollowUp) error{OutOfMemory}!command_mod.SubmitResult {
        const id = self.nextCommandId();
        _ = self.agent.followUp(follow_up.messages) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.FollowUpQueueFull => {
                self.emit(.{ .command = .{ .rejected = .follow_up_queue_full } });
                return .{ .rejected = .follow_up_queue_full };
            },
            else => {
                self.emit(.{ .command = .{ .rejected = .invalid_state } });
                return .{ .rejected = .invalid_state };
            },
        };
        self.emit(.{ .command = .{ .accepted = id } });
        self.emit(.{ .control = .{ .follow_up_queued = .{
            .command_id = id,
            .queued_followups = self.agent.state().activity.running.queued_followups,
        } } });
        return .{ .accepted = id };
    }

    fn runPromptCommand(self: *AgentSession, messages: []const agent_mod.AgentMessage) void {
        if (self.appendCommandInput(messages)) |kind| {
            self.setAgentFailure(kind);
            return;
        }
        if (!self.syncAgentConfigBeforeRun()) return;
        var terminal = self.agent.prompt(messages) catch |err| return self.setAgentError(err);
        defer terminal.deinit();
        self.persistObservedTerminal(&terminal);
        self.settleAgent();
    }

    fn runFollowUpCommand(self: *AgentSession, messages: []const agent_mod.AgentMessage) void {
        if (self.appendCommandInput(messages)) |kind| {
            self.setAgentFailure(kind);
            return;
        }
        if (!self.syncAgentConfigBeforeRun()) return;
        const maybe_terminal = self.agent.followUp(messages) catch |err| return self.setAgentError(err);
        if (maybe_terminal) |terminal_value| {
            var terminal = terminal_value;
            defer terminal.deinit();
            self.persistObservedTerminal(&terminal);
        }
        self.settleAgent();
    }

    fn runContinueCommand(self: *AgentSession) void {
        if (!self.syncAgentConfigBeforeRun()) return;
        var terminal = self.agent.continueRun() catch |err| return self.setAgentError(err);
        defer terminal.deinit();
        self.persistObservedTerminal(&terminal);
        self.settleAgent();
    }

    fn appendCommandInput(self: *AgentSession, messages: []const agent_mod.AgentMessage) ?agent_mod.failure.Kind {
        const owned_messages = message_memory.cloneMessages(self.allocator, messages) catch {
            return .out_of_memory;
        };
        switch (self.appendRunInput(owned_messages)) {
            .appended, .skipped => freeMessages(self.allocator, owned_messages),
            .failed => |failure| {
                freeMessages(self.allocator, owned_messages);
                return durableFailureKind(failure);
            },
        }
        return null;
    }

    fn syncAgentConfigBeforeRun(self: *AgentSession) bool {
        const model = self.policy.model orelse {
            const failure: SessionRunFailure = .missing_model;
            self.setAgentFailure(failure.failureKind());
            return false;
        };
        self.agent.model = model;
        self.agent.system_prompt = self.policy.system_prompt;
        self.agent.reasoning = self.policy.reasoning;
        self.agent.tools = self.extension_host.tools();
        self.agent.sink = .{ .emit_fn = emitAgentEventFromAgent, .ctx = self };
        return true;
    }

    fn persistObservedTerminal(self: *AgentSession, terminal: *const OwnedRunTerminal) void {
        switch (terminal.status) {
            .completed => |messages| switch (self.appendTerminalMessages(messages)) {
                .appended, .skipped => {},
                .failed => |failure| self.setAgentFailure(durableFailureKind(failure)),
            },
            .aborted => {},
            .failed => |failed| self.setAgentFailure(failed.kind),
        }
    }

    fn settleAgent(self: *AgentSession) void {
        self.agent.settle(.{ .emit_fn = applySettledTerminal, .ctx = self });
    }

    fn applySettledTerminal(ctx: ?*anyopaque, terminal: *const OwnedRunTerminal) void {
        const self: *AgentSession = @ptrCast(@alignCast(ctx.?));
        self.persistObservedTerminal(terminal);
    }

    fn setAgentError(self: *AgentSession, err: anyerror) void {
        self.setAgentFailure(switch (err) {
            error.OutOfMemory => .out_of_memory,
            else => .internal,
        });
    }

    fn emitAgentEventFromAgent(event: agent_mod.AgentEvent, ctx: ?*anyopaque) void {
        const self: *AgentSession = @ptrCast(@alignCast(ctx.?));
        self.emit(.{ .agent = event });
    }

    fn appendRunInput(self: *AgentSession, messages: []const agent_mod.AgentMessage) durable_projection_mod.Append {
        return self.durableProjection().appendRunInput(messages);
    }

    fn appendTerminalMessages(self: *AgentSession, messages: []const agent_mod.AgentMessage) durable_projection_mod.Append {
        return self.durableProjection().appendCompletedTerminal(messages);
    }

    fn durableProjection(self: *AgentSession) durable_projection_mod.Projection {
        return .{ .appender = &self.durable_appender, .event_sink = self.event_sink };
    }

    fn freeMessages(allocator: std.mem.Allocator, messages: []const agent_mod.AgentMessage) void {
        for (messages) |msg| message_memory.freeMessage(allocator, msg);
        allocator.free(messages);
    }

    fn assertCanApplyCommand(self: *const AgentSession, command: command_mod.Command) void {
        switch (command) {
            .submit_prompt, .follow_up, .set_model, .set_reasoning => {
                if (!self.isIdleOrFailed()) @panic("command requires idle or failed session");
            },
            .continue_run => {
                if (self.state().activity != .idle) @panic("continue_run requires idle session");
            },
            .abort_run, .steer => unreachable,
        }
    }

    fn isIdleOrFailed(self: *const AgentSession) bool {
        return switch (self.state().activity) {
            .idle, .failed => true,
            .running, .aborting => false,
        };
    }

    fn nextCommandId(self: *AgentSession) command_mod.CommandId {
        std.debug.assert(self.next_command_id != 0);
        const id = self.next_command_id;
        self.next_command_id += 1;
        std.debug.assert(self.next_command_id != 0);
        return @enumFromInt(id);
    }

    fn setAgentFailure(self: *AgentSession, kind: agent_mod.failure.Kind) void {
        self.agent.fail(kind);
    }

    fn enterOwnerCall(self: *AgentSession) void {
        if (self.owner_call_active) @panic("reentrant AgentSession owner call");
        self.owner_call_active = true;
    }

    fn leaveOwnerCall(self: *AgentSession) void {
        if (!self.owner_call_active) @panic("AgentSession owner call underflow");
        self.owner_call_active = false;
    }
};

fn durableFailureKind(failure: durable_projection_mod.Failure) agent_mod.failure.Kind {
    return switch (failure) {
        .unsupported_batch => .invalid_context,
        .durable_append_rejected, .durable_append_failed => .internal,
    };
}

const observed_event_count = 19;
const ObservedEvent = enum {
    command_accepted,
    command_rejected,
    session_appended,
    append_rejected,
    append_failed,
    run_started,
    control_follow_up_queued,
    control_abort_requested,
    run_tool_started,
    run_tool_updated,
    run_tool_finished,
    run_finished_completed,
    run_finished_failed,
    run_finished_aborted,
};

const EventCollector = struct {
    items: [observed_event_count]ObservedEvent = undefined,
    len: usize = 0,

    fn emit(value: event_mod.Event, ctx: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        if (value == .agent and (value.agent == .message_start or value.agent == .message_update or value.agent == .message_end)) return;
        if (value == .agent and value.agent != .agent_start and value.agent != .agent_end and value.agent != .tool_execution_start and value.agent != .tool_execution_update and value.agent != .tool_execution_end) return;
        std.debug.assert(self.len < observed_event_count);
        self.items[self.len] = switch (value) {
            .agent => |agent_event| switch (agent_event) {
                .agent_start => .run_started,
                .agent_end => .run_finished_completed,
                .tool_execution_start => .run_tool_started,
                .tool_execution_update => .run_tool_updated,
                .tool_execution_end => .run_tool_finished,
                else => unreachable,
            },
            .command => |command| switch (command) {
                .accepted => .command_accepted,
                .rejected => .command_rejected,
            },
            .session => |session| switch (session) {
                .appended => .session_appended,
                .append_rejected => .append_rejected,
                .append_failed => .append_failed,
            },
            .control => |control| switch (control) {
                .follow_up_queued => .control_follow_up_queued,
                .abort_requested => .control_abort_requested,
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

fn testToolUseAssistantMessage() agent_mod.AgentMessage {
    const json_value = @import("../json/value.zig");
    const content = struct {
        const blocks = [_]ai.protocol.AssistantMessage.AssistantContentBlock{.{ .tool_call = .{ .id = "tool-1", .name = "read", .arguments = json_value.OwnedValue.nullValue() } }};
    }.blocks;
    return .{ .assistant = .{
        .content = &content,
        .api = .openai_responses,
        .provider = .openai,
        .model = "test",
        .usage = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total_tokens = 0, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 } },
        .stop_reason = .toolUse,
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

fn testPolicy() PolicyInit {
    return .{ .model = testModel() };
}

fn testExecutionBackend() AgentSession.ExecutionBackend {
    return .{
        .stream = .{ .call_fn = completeWithAssistant },
        .convert_messages = .{ .call_fn = convertNoop },
        .io = std.testing.io,
    };
}

fn captureExecutionBackend(capture: *SpecCapture) AgentSession.ExecutionBackend {
    return .{
        .stream = .{ .call_fn = SpecCapture.stream, .ctx = capture },
        .convert_messages = .{ .call_fn = convertNoop },
        .io = std.testing.io,
    };
}

test "agent session accepts prompt through owner drain" {
    var session = try AgentSession.init(std.testing.allocator, .{ .policy = testPolicy(), .backend = testExecutionBackend() });
    defer session.deinit();

    const result = try session.submit(.{ .submit_prompt = .{ .messages = &.{} } });
    try std.testing.expect(result == .accepted);
    try std.testing.expect(session.state().activity == .idle);
}

test "agent session snapshots policy and executes backend to terminal through owner drain" {
    var durable = durable_mod.ScriptedAppender{ .result = .{ .appended = [_]u8{'e'} ** session_event_mod.event_id_hex_len } };
    var events: EventCollector = .{};
    var session = try AgentSession.init(std.testing.allocator, .{
        .durable_appender = .{ .scripted = &durable },
        .event_sink = .{ .emit_fn = EventCollector.emit, .ctx = &events },
        .policy = testPolicy(),
        .backend = testExecutionBackend(),
    });
    defer session.deinit();

    const messages = [_]agent_mod.AgentMessage{.{ .user = .{ .content = .{ .text = "hello" }, .timestamp = 1 } }};
    _ = try session.submit(.{ .submit_prompt = .{ .messages = &messages } });

    try std.testing.expect(session.state().activity == .idle);
    try std.testing.expectEqual(@as(usize, 2), durable.message_count);
    try std.testing.expectEqualSlices(ObservedEvent, &.{ .command_accepted, .session_appended, .run_started, .run_finished_completed, .session_appended }, events.items[0..events.len]);
}

test "policy commands update owned run spec inputs while idle" {
    var capture = SpecCapture{};
    var session = try AgentSession.init(std.testing.allocator, .{
        .policy = testPolicy(),
        .backend = captureExecutionBackend(&capture),
    });
    defer session.deinit();

    _ = try session.submit(.{ .set_model = .{ .model = testModelWithId("next-model") } });
    _ = try session.submit(.{ .set_reasoning = .{ .reasoning = .high } });

    _ = try session.submit(.{ .submit_prompt = .{ .messages = &.{} } });

    try std.testing.expect(session.state().activity == .idle);
    try std.testing.expectEqualStrings("next-model", capture.model_id);
    try std.testing.expectEqual(ai.protocol.ThinkingLevel.high, capture.reasoning.?);
}

test "extension host tools are exposed through run spec" {
    const Capture = struct {
        tool_count: usize = 0,
        tool_name: []const u8 = "",

        fn stream(ctx: ?*anyopaque, _: std.mem.Allocator, _: agent_mod.message.Model, context: ai.protocol.Context, _: ai.protocol.SimpleStreamOptions, sink: ai.provider.StreamEventSink) error{OutOfMemory}!void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.tool_count = if (context.tools) |tools| tools.len else 0;
            if (context.tools) |tools| {
                if (tools.len > 0) self.tool_name = tools[0].name;
            }
            sink.emit(.{ .done = .{ .reason = .stop, .message = testAssistantMessage().assistant } });
        }
    };
    const Tool = struct {
        fn execute(_: ?*anyopaque, _: std.mem.Allocator, _: agent_mod.tool.ToolInvocation, _: agent_mod.tool.ToolCompletionSink) void {}
    };

    var capture = Capture{};
    const source_tools = [_]agent_mod.AgentTool{.{ .name = "read", .description = "read files", .parameters = .null, .execute_fn = Tool.execute }};
    var session = try AgentSession.init(std.testing.allocator, .{
        .policy = testPolicy(),
        .extension_host = try extension_mod.Host.initTools(std.testing.allocator, &source_tools),
        .backend = .{ .stream = .{ .call_fn = Capture.stream, .ctx = &capture }, .convert_messages = .{ .call_fn = convertNoop }, .io = std.testing.io },
    });
    defer session.deinit();

    _ = try session.submit(.{ .submit_prompt = .{ .messages = &.{} } });

    try std.testing.expectEqual(@as(usize, 1), capture.tool_count);
    try std.testing.expectEqualStrings("read", capture.tool_name);
}

test "synchronous tool execution emits coding agent tool events" {
    const Capture = struct {
        calls: usize = 0,

        fn stream(ctx: ?*anyopaque, _: std.mem.Allocator, _: agent_mod.message.Model, _: ai.protocol.Context, _: ai.protocol.SimpleStreamOptions, sink: ai.provider.StreamEventSink) error{OutOfMemory}!void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            if (self.calls == 1) {
                sink.emit(.{ .done = .{ .reason = .toolUse, .message = testToolUseAssistantMessage().assistant } });
            } else {
                sink.emit(.{ .done = .{ .reason = .stop, .message = testAssistantMessage().assistant } });
            }
        }
    };
    const Tool = struct {
        fn execute(_: ?*anyopaque, _: std.mem.Allocator, invocation: agent_mod.tool.ToolInvocation, sink: agent_mod.tool.ToolCompletionSink) void {
            var update = agent_mod.tool.ToolCompletion{ .update = .{
                .op_id = invocation.op_id,
                .source_index = invocation.source_index,
                .tool_call_id = invocation.tool_call_id,
                .tool_name = invocation.tool_name,
                .partial_result = .{ .content = &.{}, .is_error = false },
            } };
            sink.emit(&update);
            var completion = agent_mod.tool.ToolCompletion{ .terminal = .{
                .op_id = invocation.op_id,
                .source_index = invocation.source_index,
                .tool_call_id = invocation.tool_call_id,
                .tool_name = invocation.tool_name,
                .terminal = .{ .completed = .{ .content = &.{}, .is_error = false } },
            } };
            sink.emit(&completion);
        }
    };

    var capture = Capture{};
    var events = EventCollector{};
    const source_tools = [_]agent_mod.AgentTool{.{ .name = "read", .description = "read files", .parameters = .null, .execute_fn = Tool.execute }};
    var session = try AgentSession.init(std.testing.allocator, .{
        .policy = testPolicy(),
        .event_sink = .{ .emit_fn = EventCollector.emit, .ctx = &events },
        .extension_host = try extension_mod.Host.initTools(std.testing.allocator, &source_tools),
        .backend = .{ .stream = .{ .call_fn = Capture.stream, .ctx = &capture }, .convert_messages = .{ .call_fn = convertNoop }, .io = std.testing.io },
    });
    defer session.deinit();

    _ = try session.submit(.{ .submit_prompt = .{ .messages = &.{} } });

    try std.testing.expectEqualSlices(ObservedEvent, &.{ .command_accepted, .run_started, .run_tool_started, .run_tool_updated, .run_tool_finished, .run_finished_completed }, events.items[0..events.len]);
}

test "tool update projection emits summary without payload ownership" {
    const Collector = struct {
        saw_update: bool = false,
        matched_ids: bool = false,
        content_blocks: usize = 0,
        is_error: bool = false,
        has_details: bool = true,
        has_presentation: bool = true,
        expected_run_id: command_mod.CommandId,

        fn emit(value: event_mod.Event, ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (value != .agent or value.agent != .tool_execution_update) return;
            const updated = value.agent.tool_execution_update;
            self.saw_update = true;
            _ = self.expected_run_id;
            self.matched_ids = updated.op_id == 1 and
                std.mem.eql(u8, updated.tool_call_id, "tool-1") and
                std.mem.eql(u8, updated.tool_name, "read");
            self.content_blocks = updated.partial_result.content.len;
            self.is_error = updated.partial_result.is_error;
            self.has_details = updated.partial_result.details != null;
            self.has_presentation = updated.partial_result.presentation != null;
        }
    };
    const Capture = struct {
        calls: usize = 0,

        fn stream(ctx: ?*anyopaque, _: std.mem.Allocator, _: agent_mod.message.Model, _: ai.protocol.Context, _: ai.protocol.SimpleStreamOptions, sink: ai.provider.StreamEventSink) error{OutOfMemory}!void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            if (self.calls == 1) {
                sink.emit(.{ .done = .{ .reason = .toolUse, .message = testToolUseAssistantMessage().assistant } });
            } else {
                sink.emit(.{ .done = .{ .reason = .stop, .message = testAssistantMessage().assistant } });
            }
        }
    };
    const Tool = struct {
        fn execute(_: ?*anyopaque, _: std.mem.Allocator, invocation: agent_mod.tool.ToolInvocation, sink: agent_mod.tool.ToolCompletionSink) void {
            const content = [_]agent_mod.tool.AgentToolResult.ContentBlock{.{ .text = .{ .text = "partial" } }};
            var update = agent_mod.tool.ToolCompletion{ .update = .{
                .op_id = invocation.op_id,
                .source_index = invocation.source_index,
                .tool_call_id = invocation.tool_call_id,
                .tool_name = invocation.tool_name,
                .partial_result = .{ .content = &content, .details = null, .presentation = null, .is_error = true },
            } };
            sink.emit(&update);
            var completion = agent_mod.tool.ToolCompletion{ .terminal = .{
                .op_id = invocation.op_id,
                .source_index = invocation.source_index,
                .tool_call_id = invocation.tool_call_id,
                .tool_name = invocation.tool_name,
                .terminal = .{ .completed = .{ .content = &.{}, .is_error = false } },
            } };
            sink.emit(&completion);
        }
    };

    var capture = Capture{};
    const source_tools = [_]agent_mod.AgentTool{.{ .name = "read", .description = "read files", .parameters = .null, .execute_fn = Tool.execute }};
    const run_id: command_mod.CommandId = @enumFromInt(1);
    var collector = Collector{ .expected_run_id = run_id };
    var session = try AgentSession.init(std.testing.allocator, .{
        .policy = testPolicy(),
        .event_sink = .{ .emit_fn = Collector.emit, .ctx = &collector },
        .extension_host = try extension_mod.Host.initTools(std.testing.allocator, &source_tools),
        .backend = .{ .stream = .{ .call_fn = Capture.stream, .ctx = &capture }, .convert_messages = .{ .call_fn = convertNoop }, .io = std.testing.io },
    });
    defer session.deinit();

    try std.testing.expectEqual(run_id, (try session.submit(.{ .submit_prompt = .{ .messages = &.{} } })).accepted);

    try std.testing.expect(collector.saw_update);
    try std.testing.expect(collector.matched_ids);
    try std.testing.expectEqual(@as(usize, 1), collector.content_blocks);
    try std.testing.expect(collector.is_error);
    try std.testing.expect(!collector.has_details);
    try std.testing.expect(!collector.has_presentation);
}

test "synchronous drain continues after completed queued run" {
    var events = EventCollector{};
    var session = try AgentSession.init(std.testing.allocator, .{
        .policy = testPolicy(),
        .backend = testExecutionBackend(),
        .event_sink = .{ .emit_fn = EventCollector.emit, .ctx = &events },
    });
    defer session.deinit();

    _ = try session.submit(.{ .submit_prompt = .{ .messages = &.{} } });
    _ = try session.submit(.{ .follow_up = .{ .messages = &.{} } });

    try std.testing.expect(session.state().activity == .idle);
    try std.testing.expectEqualSlices(ObservedEvent, &.{ .command_accepted, .run_started, .run_finished_completed, .command_accepted, .run_started, .run_finished_completed }, events.items[0..events.len]);
}

test "append rejection prevents run start" {
    var durable = durable_mod.ScriptedAppender{ .result = .{ .rejected = .invalid_state } };
    var events: EventCollector = .{};
    var session = try AgentSession.init(std.testing.allocator, .{
        .durable_appender = .{ .scripted = &durable },
        .event_sink = .{ .emit_fn = EventCollector.emit, .ctx = &events },
        .policy = testPolicy(),
        .backend = testExecutionBackend(),
    });
    defer session.deinit();

    const messages = [_]agent_mod.AgentMessage{.{ .user = .{ .content = .{ .text = "hello" }, .timestamp = 1 } }};
    _ = try session.submit(.{ .submit_prompt = .{ .messages = &messages } });

    try std.testing.expectEqual(@as(usize, 1), durable.message_count);
    try std.testing.expect(session.state().activity == .failed);
    try std.testing.expectEqual(agent_mod.failure.Kind.internal, session.state().activity.failed);
    try std.testing.expectEqualSlices(ObservedEvent, &.{ .command_accepted, .append_rejected }, events.items[0..events.len]);
}

test "append failure prevents run start" {
    var durable = durable_mod.ScriptedAppender{ .result = .{ .failed = .io } };
    var events: EventCollector = .{};
    var session = try AgentSession.init(std.testing.allocator, .{
        .durable_appender = .{ .scripted = &durable },
        .event_sink = .{ .emit_fn = EventCollector.emit, .ctx = &events },
        .policy = testPolicy(),
        .backend = testExecutionBackend(),
    });
    defer session.deinit();

    const messages = [_]agent_mod.AgentMessage{.{ .user = .{ .content = .{ .text = "hello" }, .timestamp = 1 } }};
    _ = try session.submit(.{ .submit_prompt = .{ .messages = &messages } });

    try std.testing.expectEqual(@as(usize, 1), durable.message_count);
    try std.testing.expect(session.state().activity == .failed);
    try std.testing.expectEqual(agent_mod.failure.Kind.internal, session.state().activity.failed);
    try std.testing.expectEqualSlices(ObservedEvent, &.{ .command_accepted, .append_failed }, events.items[0..events.len]);
}

test "multi message prompt is rejected before partial durable append" {
    var durable = durable_mod.ScriptedAppender{ .result = .{ .appended = [_]u8{'a'} ** session_event_mod.event_id_hex_len } };
    var events: EventCollector = .{};
    var session = try AgentSession.init(std.testing.allocator, .{
        .durable_appender = .{ .scripted = &durable },
        .event_sink = .{ .emit_fn = EventCollector.emit, .ctx = &events },
        .policy = testPolicy(),
        .backend = testExecutionBackend(),
    });
    defer session.deinit();

    const messages = [_]agent_mod.AgentMessage{
        .{ .user = .{ .content = .{ .text = "one" }, .timestamp = 1 } },
        .{ .user = .{ .content = .{ .text = "two" }, .timestamp = 2 } },
    };
    _ = try session.submit(.{ .submit_prompt = .{ .messages = &messages } });

    try std.testing.expectEqual(@as(usize, 0), durable.message_count);
    try std.testing.expect(session.state().activity == .failed);
    try std.testing.expectEqual(agent_mod.failure.Kind.invalid_context, session.state().activity.failed);
    try std.testing.expectEqualSlices(ObservedEvent, &.{ .command_accepted, .append_rejected }, events.items[0..events.len]);
}
