//! The session mailbox host: owns one AgentSession, the bounded command and
//! event queues, the retained-event replay ledger, and the single owner loop
//! seam (`waitAndApplyWake` + `step`). Frontends talk to it only through
//! `submit`/`drainEvent`; no callback path mutates session state.

const std = @import("std");
const agent_mod = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const runtime = @import("../runtime/root.zig");
const AgentSession = @import("AgentSession.zig");
const client_protocol = @import("client_protocol.zig");
const paths_mod = @import("paths.zig");
const RuntimeServices = @import("runtime_services.zig").RuntimeServices;
const session_manager = @import("session_manager.zig");
const settings_mod = @import("settings.zig");

pub const WakeResult = enum { input, session, frame };

/// Wall-clock facts for opening one session: the prompt-visible date, the
/// ISO header/file timestamp, and a uniqueness source for session ids.
pub const SessionStamp = struct {
    text: [20]u8, // YYYY-MM-DDTHH:MM:SSZ
    nanoseconds: i96,

    pub fn now(io: std.Io) SessionStamp {
        const nanoseconds = std.Io.Timestamp.now(io, .real).nanoseconds;
        const seconds_total = @divFloor(nanoseconds, std.time.ns_per_s);
        const epoch_seconds: std.time.epoch.EpochSeconds = .{
            .secs = if (seconds_total > 0) @intCast(seconds_total) else 0,
        };
        const year_day = epoch_seconds.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_seconds = epoch_seconds.getDaySeconds();
        var self: SessionStamp = .{ .text = undefined, .nanoseconds = nanoseconds };
        _ = std.fmt.bufPrint(&self.text, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        }) catch unreachable;
        return self;
    }

    pub fn date(self: *const SessionStamp) []const u8 {
        return self.text[0..10];
    }

    pub fn timestamp(self: *const SessionStamp) []const u8 {
        return &self.text;
    }
};

pub const Open = union(enum) {
    create: struct {
        session_id: []const u8,
        timestamp: []const u8,
    },
    resume_existing: struct {
        session_file_name: []const u8,
    },
};

pub const Options = struct {
    cwd: []const u8 = ".",
    agent_dir_override: ?[]const u8 = null,
    current_date: []const u8,
    open: Open,
    model: ?ai.Model = null,
    thinking_level: ?agent_mod.ThinkingLevel = null,
    stream: ?ai.StreamFunction = null,
    dir: std.Io.Dir = .cwd(),
    environ: ?*const std.process.Environ.Map = null,
    task_runtime: ?*runtime.Runtime = null,
    allow_paths_outside_cwd: bool = true,
    public_event_capacity: usize = AgentSession.public_event_capacity_default,
    command_capacity: usize = client_protocol.command_queue_capacity_default,
    event_capacity: usize = client_protocol.event_queue_capacity_default,
    retained_event_capacity: usize = client_protocol.retained_event_count_default,
    retained_event_bytes: usize = client_protocol.retained_event_bytes_default,
};

pub fn openSessionRuntime(allocator: std.mem.Allocator, options: Options) !SessionRuntime {
    const resolved_agent_dir = if (options.agent_dir_override) |agent_dir_override|
        agent_dir_override
    else
        try paths_mod.resolveGlobalAgentDirFromEnv(allocator, options.environ);
    defer if (options.agent_dir_override == null) allocator.free(resolved_agent_dir);

    var services = try RuntimeServices.init(allocator, .{
        .cwd = options.cwd,
        .agent_dir = resolved_agent_dir,
        .dir = options.dir,
        .environ = options.environ,
        .task_runtime = options.task_runtime,
    });
    errdefer services.deinit();

    var session = try openSession(allocator, &services, options);
    errdefer shutdownAndDeinitSession(&session);

    if (options.command_capacity == 0) return error.CommandCapacityZero;
    if (options.event_capacity == 0) return error.EventCapacityZero;
    var retained_events = try RetainedEventLedger.init(
        allocator,
        options.retained_event_capacity,
        options.retained_event_bytes,
    );
    errdefer retained_events.deinit();
    const command_buffer = try allocator.alloc(client_protocol.CommandEnvelope, options.command_capacity);
    errdefer allocator.free(command_buffer);
    const event_buffer = try allocator.alloc(client_protocol.EventEnvelope, options.event_capacity);
    errdefer allocator.free(event_buffer);
    return .{
        .allocator = allocator,
        .services = services,
        .session = session,
        .command_buffer = command_buffer,
        .event_buffer = event_buffer,
        .commands = client_protocol.CommandQueue.init(command_buffer),
        .events = client_protocol.EventQueue.init(event_buffer),
        .retained_events = retained_events,
    };
}

fn openSession(allocator: std.mem.Allocator, services: *RuntimeServices, options: Options) !AgentSession {
    var session_options = resolveSessionOptions(services, options);

    const sessions_dir = try (paths_mod.PersistencePaths{
        .global_dir = services.agent_dir,
        .cwd = services.cwd,
    }).sessionsDirForCwd(allocator);
    defer allocator.free(sessions_dir);

    switch (options.open) {
        .create => |create| {
            var store = try session_manager.SessionStore.create(allocator, services.io, options.dir, .{
                .sessions_dir = sessions_dir,
                .cwd = services.cwd,
                .session_id = create.session_id,
                .timestamp = create.timestamp,
            });
            errdefer store.deinit();
            session_options.session_id = create.session_id;
            session_options.timestamp = create.timestamp;
            session_options.store = .{ .create = store };
            return AgentSession.init(allocator, services.io, session_options);
        },
        .resume_existing => |resume_open| {
            const leaf = resume_open.session_file_name;
            if (!paths_mod.isSessionFileLeafName(leaf)) return error.InvalidSessionFileName;
            const file_name = try std.fs.path.join(allocator, &.{ sessions_dir, leaf });
            errdefer allocator.free(file_name);
            session_options.store = .{ .restore = .{ .allocator = allocator, .dir = options.dir, .file_name = file_name } };
            return AgentSession.init(allocator, services.io, session_options);
        },
    }
}

/// Resolve session options: explicit option -> project settings -> global
/// settings -> default. Provider and model are scope-atomic: they resolve as
/// a pair from one settings scope and never mix across scopes.
fn resolveSessionOptions(services: *RuntimeServices, options: Options) AgentSession.Options {
    const snapshot = services.settings_manager.current();
    const project = fileSettings(snapshot.project);
    const global = fileSettings(snapshot.global);

    const model = options.model orelse model: {
        const pair = if (project.default_provider != null or project.default_model != null) project else global;
        if (pair.default_provider) |provider| {
            if (pair.default_model) |model_id| {
                if (ai.getModel(provider, model_id)) |model| {
                    if (services.auth_manager.hasAuth(model.provider)) break :model model;
                }
            }
        }
        for (ai.getProviders()) |provider| {
            for (ai.getModels(provider)) |model| {
                if (services.auth_manager.hasAuth(model.provider)) break :model model;
            }
        }
        break :model agent_mod.Agent.defaultModel();
    };

    const thinking_level = options.thinking_level orelse level: {
        if (project.default_thinking_level orelse global.default_thinking_level) |text| {
            inline for (@typeInfo(agent_mod.ThinkingLevel).@"enum".fields) |field| {
                if (std.ascii.eqlIgnoreCase(text, field.name)) {
                    break :level @field(agent_mod.ThinkingLevel, field.name);
                }
            }
        }
        break :level .off;
    };

    var compaction: session_manager.CompactionSettings = .{};
    var retry: AgentSession.RetrySettings = .{};
    for ([2]settings_mod.Settings{ global, project }) |scope| {
        if (scope.compaction) |value| {
            if (value.keep_recent_tokens) |tokens| compaction.keep_recent_tokens = tokens;
            if (value.enabled) |enabled| compaction.auto_enabled = enabled;
        }
        if (scope.retry) |value| {
            if (value.enabled) |enabled| retry.enabled = enabled;
            if (value.max_retries) |attempts| retry.max_attempts = std.math.lossyCast(u8, attempts);
            if (value.base_delay_ms) |delay| retry.base_delay_ms = delay;
        }
    }

    return .{
        .cwd = services.cwd,
        .agent_dir = services.agent_dir,
        .current_date = options.current_date,
        .session_id = "",
        .timestamp = "",
        .model = model,
        .thinking_level = thinking_level,
        .compaction_settings = compaction,
        .retry_settings = retry,
        .stream = options.stream orelse if (services.provider_registry.get(model.api)) |provider|
            provider.stream_simple
        else
            null,
        .get_api_key = services.auth_manager.hook(),
        .task_runtime = services.task_runtime,
        .dir = options.dir,
        .environ = services.environ,
        .allow_paths_outside_cwd = options.allow_paths_outside_cwd,
        .public_event_capacity = options.public_event_capacity,
    };
}

fn fileSettings(file: settings_mod.SettingsFile) settings_mod.Settings {
    return switch (file) {
        .missing => .{},
        .loaded => |settings| settings.value,
    };
}

pub const SessionRuntime = struct {
    allocator: std.mem.Allocator,
    services: RuntimeServices,
    session: AgentSession,
    command_buffer: []client_protocol.CommandEnvelope,
    event_buffer: []client_protocol.EventEnvelope,
    commands: client_protocol.CommandQueue,
    events: client_protocol.EventQueue,
    retained_events: RetainedEventLedger,
    wake_event: runtime.ResetEvent = .init,
    active: ?ActiveOperation = null,
    next_operation_id: client_protocol.OperationId = 1,
    next_event_seq: client_protocol.EventSeq = 1,
    pending_event: ?client_protocol.EventEnvelope = null,

    /// All facts about the one in-flight prompt operation live together.
    /// The phase makes "a run, a summary run, and a retry timer at once"
    /// unrepresentable.
    const ActiveOperation = struct {
        phase: Phase,
        request_id: ?client_protocol.RequestId,
        operation_id: client_protocol.OperationId,
        prompt_text: []u8,
        overflow_count_before: usize,
        overflow_retry_used: bool = false,

        const Phase = union(enum) {
            running: *AgentSession.PromptRun,
            compacting: *AgentSession.CompactionRun,
            retry_wait: RetryWait,
        };

        const RetryWait = struct {
            kind: AgentSession.SettleVerdict.Retry.Kind,
            resume_at_ns: i96,
        };
    };

    pub fn deinit(self: *SessionRuntime) void {
        if (self.active) |active| {
            self.destroyActivePhase(active);
            self.allocator.free(active.prompt_text);
            self.active = null;
        }
        while (self.commands.pop()) |envelope| {
            var owned_envelope = envelope;
            owned_envelope.deinit(self.allocator);
        }
        if (self.pending_event) |*event| event.deinit(self.allocator);
        self.pending_event = null;
        while (self.events.pop()) |envelope| {
            var owned_envelope = envelope;
            owned_envelope.deinit(self.allocator);
        }
        self.retained_events.deinit();
        shutdownAndDeinitSession(&self.session);
        self.services.deinit();
        self.allocator.free(self.event_buffer);
        self.allocator.free(self.command_buffer);
        self.* = undefined;
    }

    pub fn submit(self: *SessionRuntime, envelope: client_protocol.CommandEnvelope) !void {
        try self.commands.push(envelope);
        self.wake_event.set();
    }

    pub fn drainEvent(self: *SessionRuntime) ?client_protocol.EventEnvelope {
        return self.events.pop();
    }

    pub fn hasImmediateWork(self: *const SessionRuntime) bool {
        return self.pending_event != null or self.events.count() > 0 or self.commands.count() > 0;
    }

    pub fn rejectClientCommand(
        self: *SessionRuntime,
        request_id: ?client_protocol.RequestId,
        code: client_protocol.Rejection.Code,
        message: []const u8,
    ) !void {
        try self.enqueueRejected(request_id, code, message);
    }

    pub fn waitAndApplyWake(
        self: *SessionRuntime,
        input_fd: std.posix.fd_t,
        frame_ms: u64,
    ) !WakeResult {
        const readable = runtime.ReadableFd.initBorrowed(input_fd);
        var input = readable.asyncReadable();
        var frame = runtime.Timeout.fromMilliseconds(frame_ms);
        const public_event_wake = self.session.publicEventWake();
        const command_wake = &self.wake_event;
        if (self.active) |*active| switch (active.phase) {
            .running, .compacting => {
                var progress = switch (active.phase) {
                    .running => |run| run.stream.asyncNext(),
                    .compacting => |run| run.stream.asyncNext(),
                    .retry_wait => unreachable,
                };
                switch (try runtime.select(.{
                    .input = &input,
                    .prompt = &progress,
                    .public_event = public_event_wake,
                    .command = command_wake,
                    .frame = &frame,
                })) {
                    .input => |result| {
                        result catch return .session;
                        return .input;
                    },
                    .prompt => |result| {
                        self.applyActiveProgress(result) catch |err| switch (err) {
                            error.EventQueueFull => {},
                            else => self.failActiveOperation(err),
                        };
                        return .session;
                    },
                    .public_event => {
                        public_event_wake.reset();
                        self.drainSessionEvents(null) catch return .session;
                        return .session;
                    },
                    .command => {
                        self.wake_event.reset();
                        return .session;
                    },
                    .frame => return .frame,
                }
            },
            .retry_wait => |wait| {
                const remaining_ns = wait.resume_at_ns - self.nowNanoseconds();
                if (remaining_ns <= 0) {
                    self.startDueRetry();
                    return .session;
                }
                var retry = runtime.Timeout.fromNanoseconds(@intCast(remaining_ns));
                switch (try runtime.select(.{
                    .input = &input,
                    .retry = &retry,
                    .public_event = public_event_wake,
                    .command = command_wake,
                    .frame = &frame,
                })) {
                    .input => |result| {
                        result catch return .session;
                        return .input;
                    },
                    .retry => {
                        self.startDueRetry();
                        return .session;
                    },
                    .public_event => {
                        public_event_wake.reset();
                        self.drainSessionEvents(null) catch return .session;
                        return .session;
                    },
                    .command => {
                        self.wake_event.reset();
                        return .session;
                    },
                    .frame => return .frame,
                }
            },
        };
        switch (try runtime.select(.{
            .input = &input,
            .public_event = public_event_wake,
            .command = command_wake,
            .frame = &frame,
        })) {
            .input => |result| {
                result catch return .session;
                return .input;
            },
            .public_event => {
                public_event_wake.reset();
                self.drainSessionEvents(null) catch return .session;
                return .session;
            },
            .command => {
                self.wake_event.reset();
                return .session;
            },
            .frame => return .frame,
        }
    }

    pub fn step(self: *SessionRuntime) !void {
        if (!self.flushPendingEvent()) return;
        while (self.hasEventCapacity()) {
            const envelope = self.commands.pop() orelse break;
            var command = envelope;
            defer command.deinit(self.allocator);
            self.applyCommand(command) catch |err| switch (err) {
                error.EventQueueFull => return,
                else => return err,
            };
            if (!self.flushPendingEvent()) return;
        }
        if (!self.hasEventCapacity()) return;
        self.startDueRetry();
        self.stepPromptProgressBounded(64) catch |err| switch (err) {
            error.EventQueueFull => return,
            else => self.failActiveOperation(err),
        };
        self.startDueRetry();
        if (!self.flushPendingEvent()) return;
        self.drainSessionEvents(null) catch return;
    }

    fn stepPromptProgressBounded(self: *SessionRuntime, limit: usize) !void {
        var count: usize = 0;
        while (count < limit) : (count += 1) {
            const active = if (self.active) |*operation| operation else return;
            var progress = switch (active.phase) {
                .running => |run| run.stream.asyncNext(),
                .compacting => |run| run.stream.asyncNext(),
                .retry_wait => return,
            };
            var ready = runtime.Timeout.fromMilliseconds(0);
            switch (try runtime.select(.{ .prompt = &progress, .ready = &ready })) {
                .prompt => |result| try self.applyActiveProgress(result),
                .ready => return,
            }
        }
    }

    /// Begin the armed retry run once its backoff deadline has passed.
    /// Wakeups coalesce, so this inspects state instead of trusting them.
    fn startDueRetry(self: *SessionRuntime) void {
        const active = if (self.active) |*operation| operation else return;
        const wait = switch (active.phase) {
            .retry_wait => |wait| wait,
            .running, .compacting => return,
        };
        if (self.nowNanoseconds() < wait.resume_at_ns) return;
        const run = switch (wait.kind) {
            .resubmit_prompt => self.session.startPromptRun(active.prompt_text, &.{}),
            .continue_run => self.session.startContinueRun(),
        } catch |err| {
            self.failActiveOperation(err);
            return;
        };
        active.phase = .{ .running = run };
        self.drainSessionEvents(active.request_id) catch {};
    }

    fn nowNanoseconds(self: *const SessionRuntime) i96 {
        return std.Io.Clock.awake.now(self.services.io).nanoseconds;
    }

    fn takeActive(self: *SessionRuntime) ?ActiveOperation {
        const active = self.active orelse return null;
        self.active = null;
        return active;
    }

    fn destroyActivePhase(self: *SessionRuntime, active: ActiveOperation) void {
        switch (active.phase) {
            .running => |run| self.session.destroyPromptRun(run),
            .compacting => |run| self.session.destroyCompactionRun(run),
            .retry_wait => {},
        }
    }

    fn cancelAndDestroyActivePhase(self: *SessionRuntime, active: ActiveOperation) void {
        switch (active.phase) {
            .running => |run| {
                self.session.cancelPromptRun(run) catch {};
                self.session.destroyPromptRun(run);
            },
            .compacting => |run| {
                self.session.cancelCompactionRun(run);
                self.session.destroyCompactionRun(run);
            },
            .retry_wait => self.session.cancelRetryWait(),
        }
    }

    fn applyCommand(self: *SessionRuntime, envelope: client_protocol.CommandEnvelope) !void {
        switch (envelope.command) {
            .submit => |prompt| {
                if (self.active != null and prompt.mode != .start) {
                    const delivery: AgentSession.QueuePromptKind = switch (prompt.mode) {
                        .auto, .steer => .steer,
                        .enqueue => .follow_up,
                        .start => unreachable,
                    };
                    self.session.queuePrompt(prompt.text, &.{}, delivery) catch |err| {
                        try self.enqueueRejected(envelope.id, .invalid_command, @errorName(err));
                        return;
                    };
                    try self.drainSessionEvents(envelope.id);
                    return;
                }
                if (self.active != null) {
                    try self.enqueueRejected(envelope.id, .busy, "operation already active");
                    return;
                }
                const prompt_text = self.allocator.dupe(u8, prompt.text) catch |err| {
                    try self.enqueueRejected(envelope.id, .invalid_command, @errorName(err));
                    return;
                };
                const overflow_count_before = self.session.contextOverflowCount();
                // Threshold compaction is the operation's opening phase when
                // due; its settle verdict starts the prompt run. A failure to
                // even start it degrades: the prompt runs uncompacted.
                const phase: ActiveOperation.Phase = blk: {
                    if (self.session.startCompactionRun(.threshold, false) catch null) |compaction_run| {
                        break :blk .{ .compacting = compaction_run };
                    }
                    const run = self.session.startPromptRun(prompt.text, &.{}) catch |err| {
                        self.allocator.free(prompt_text);
                        try self.enqueueRejected(envelope.id, .invalid_command, @errorName(err));
                        return;
                    };
                    break :blk .{ .running = run };
                };
                self.active = .{
                    .phase = phase,
                    .request_id = envelope.id,
                    .operation_id = self.nextOperationId(),
                    .prompt_text = prompt_text,
                    .overflow_count_before = overflow_count_before,
                };
                try self.enqueueEvent(.{
                    .request_id = envelope.id,
                    .operation_id = self.active.?.operation_id,
                    .event = .operation_started,
                });
                try self.drainSessionEvents(envelope.id);
            },
            .cancel => |cancel| {
                const matches = if (self.active) |active| switch (cancel.target) {
                    .active => true,
                    .request_id => |id| active.request_id == id,
                    .operation_id => |id| active.operation_id == id,
                } else false;
                if (!matches) {
                    try self.enqueueRejected(envelope.id, .invalid_command, "cancel target not active");
                    return;
                }
                const active = self.takeActive().?;
                self.cancelAndDestroyActivePhase(active);
                self.allocator.free(active.prompt_text);
                try self.drainSessionEvents(envelope.id);
                try self.enqueueEvent(.{
                    .request_id = envelope.id,
                    .operation_id = active.operation_id,
                    .event = .{ .operation_finished = .{ .reason = .canceled } },
                });
            },
            .queue => |queue_command| switch (queue_command) {
                .clear => {
                    // The reply is the state fact itself: a request-correlated
                    // queue_changed (emitted unconditionally by the drain).
                    self.session.clearQueue();
                    try self.drainSessionEvents(envelope.id);
                },
            },
            .snapshot => {
                const snapshot = try self.buildClientSnapshot();
                try self.enqueueEvent(.{ .request_id = envelope.id, .event = .{ .snapshot = snapshot } });
            },
            .replay => |request| {
                var replay = try self.retained_events.buildReplay(self.allocator, request);
                replay.request_id = envelope.id;
                try self.enqueueEvent(replay);
            },
            .shutdown => {
                // A pending retry or summary run never outlives shutdown:
                // settle it as canceled. (A running prompt is aborted by the
                // session's own shutdown path below.)
                if (self.active != null and self.active.?.phase != .running) {
                    const active = self.takeActive().?;
                    self.cancelAndDestroyActivePhase(active);
                    self.allocator.free(active.prompt_text);
                    try self.drainSessionEvents(active.request_id);
                    try self.enqueueEvent(.{
                        .request_id = active.request_id,
                        .operation_id = active.operation_id,
                        .event = .{ .operation_finished = .{ .reason = .canceled } },
                    });
                }
                self.session.requestShutdown();
                try self.enqueueEvent(.{ .request_id = envelope.id, .event = .shutdown_started });
            },
        }
    }

    fn applyActiveProgress(self: *SessionRuntime, result: anytype) !void {
        const active = if (self.active) |*operation| operation else return;
        switch (active.phase) {
            .running => |run| {
                const more = try self.session.applyPromptRunProgress(run, result);
                try self.drainSessionEvents(active.request_id);
                if (more) return;
                // The run settled. Destroy it, then act on the session's
                // verdict. State transitions happen before any fallible emit
                // so a full event queue can never leave the phase pointing
                // at a destroyed run.
                self.session.destroyPromptRun(run);
                const verdict = self.session.settlePromptRun(.{
                    .overflow_count_before = active.overflow_count_before,
                    .overflow_retry_used = active.overflow_retry_used,
                }) catch |err| return self.finishOperationRejected(err);
                try self.applyVerdict(active, verdict);
            },
            .compacting => |run| {
                const more = try self.session.applyCompactionRunProgress(run, result);
                try self.drainSessionEvents(active.request_id);
                if (more) return;
                const verdict = self.session.settleCompactionRun(run) catch |err| {
                    self.session.destroyCompactionRun(run);
                    return self.finishOperationRejected(err);
                };
                self.session.destroyCompactionRun(run);
                try self.applyVerdict(active, verdict);
            },
            .retry_wait => return,
        }
    }

    /// Act on a settle verdict. Every arm reassigns the phase or takes the
    /// operation before its first fallible call.
    fn applyVerdict(
        self: *SessionRuntime,
        active: *ActiveOperation,
        verdict: AgentSession.SettleVerdict,
    ) !void {
        switch (verdict) {
            .compact => |compaction_run| {
                active.overflow_retry_used = true;
                active.phase = .{ .compacting = compaction_run };
                try self.drainSessionEvents(active.request_id);
            },
            .retry => |retry| {
                active.phase = .{ .retry_wait = .{
                    .kind = retry.kind,
                    .resume_at_ns = self.nowNanoseconds() +
                        @as(i96, @intCast(retry.delay_ms)) * std.time.ns_per_ms,
                } };
                try self.drainSessionEvents(active.request_id);
            },
            .completed, .failed => {
                const finished = self.takeActive().?;
                defer self.allocator.free(finished.prompt_text);
                const reason: client_protocol.OperationFinished.Reason = switch (verdict) {
                    .completed => .completed,
                    .failed => .failed,
                    .retry, .compact => unreachable,
                };
                try self.drainSessionEvents(finished.request_id);
                try self.enqueueEvent(.{
                    .request_id = finished.request_id,
                    .operation_id = finished.operation_id,
                    .event = .{ .operation_finished = .{ .reason = reason } },
                });
            },
        }
    }

    fn finishOperationRejected(self: *SessionRuntime, err: anyerror) !void {
        const finished = self.takeActive().?;
        defer self.allocator.free(finished.prompt_text);
        try self.enqueueRejected(finished.request_id, .invalid_command, @errorName(err));
        try self.enqueueEvent(.{
            .request_id = finished.request_id,
            .operation_id = finished.operation_id,
            .event = .{ .operation_finished = .{ .reason = .failed } },
        });
    }

    /// Contain an operational failure (persistence, stream apply) to the
    /// active operation: the operation fails loudly, the owner loop lives.
    fn failActiveOperation(self: *SessionRuntime, err: anyerror) void {
        const active = self.takeActive() orelse return;
        self.cancelAndDestroyActivePhase(active);
        self.allocator.free(active.prompt_text);
        self.enqueueRejected(active.request_id, .invalid_command, @errorName(err)) catch {};
        self.enqueueEvent(.{
            .request_id = active.request_id,
            .operation_id = active.operation_id,
            .event = .{ .operation_finished = .{ .reason = .failed } },
        }) catch {};
    }

    fn buildClientSnapshot(self: *SessionRuntime) !client_protocol.Snapshot {
        return self.session.clientSnapshot(
            self.allocator,
            if (self.active) |active| active.request_id else null,
        );
    }

    fn drainSessionEvents(self: *SessionRuntime, request_id: ?client_protocol.RequestId) !void {
        while (self.hasEventCapacity()) {
            const event = self.session.drainPublicEvent() orelse return;
            try self.enqueueEvent(.{ .request_id = request_id, .event = event });
        }
    }

    fn enqueueRejected(
        self: *SessionRuntime,
        request_id: ?client_protocol.RequestId,
        code: client_protocol.Rejection.Code,
        message: []const u8,
    ) !void {
        const owned_message = try client_protocol.EventText.init(self.allocator, message);
        try self.enqueueEvent(.{
            .request_id = request_id,
            .event = .{ .rejected = .{ .code = code, .message = owned_message } },
        });
    }

    fn enqueueEvent(self: *SessionRuntime, envelope: client_protocol.EventEnvelope) !void {
        var sequenced = envelope;
        sequenced.seq = self.next_event_seq;
        self.next_event_seq += 1;
        try self.retained_events.append(sequenced);
        if (self.events.pushOrDrop(sequenced)) return;
        if (self.pending_event == null) {
            self.pending_event = sequenced;
        } else {
            var owned_envelope = sequenced;
            owned_envelope.deinit(self.allocator);
        }
        return error.EventQueueFull;
    }

    fn nextOperationId(self: *SessionRuntime) client_protocol.OperationId {
        const id = self.next_operation_id;
        std.debug.assert(id != 0);
        self.next_operation_id += 1;
        return id;
    }

    fn hasEventCapacity(self: *const SessionRuntime) bool {
        return self.pending_event == null and self.events.count() < self.events.capacity();
    }

    fn flushPendingEvent(self: *SessionRuntime) bool {
        const event = self.pending_event orelse return true;
        if (self.events.pushOrDrop(event)) {
            self.pending_event = null;
            return true;
        }
        return false;
    }
};

fn shutdownAndDeinitSession(session: *AgentSession) void {
    session.requestShutdown();
    while (session.drainPublicEvent()) |event| {
        var owned_event = event;
        owned_event.deinit(session.allocator);
    }
    session.deinit();
}

/// Bounded ring of recently emitted event envelopes, retained as encoded
/// JSON for replay. Encoding reuses one scratch buffer sized to the byte
/// budget; an envelope that cannot fit evicts the whole ledger through its
/// sequence number so the gap stays observable.
const RetainedEventLedger = struct {
    allocator: std.mem.Allocator,
    entries: []Entry,
    scratch: []u8,
    start: usize = 0,
    count: usize = 0,
    total_bytes: usize = 0,
    evicted_through_seq: client_protocol.EventSeq = 0,

    const Entry = struct {
        seq: client_protocol.EventSeq,
        json: []u8,
    };

    fn init(allocator: std.mem.Allocator, capacity: usize, max_bytes: usize) !RetainedEventLedger {
        if (capacity == 0) return error.RetainedEventCapacityZero;
        if (max_bytes == 0) return error.RetainedEventBytesZero;
        const entries = try allocator.alloc(Entry, capacity);
        errdefer allocator.free(entries);
        return .{
            .allocator = allocator,
            .entries = entries,
            .scratch = try allocator.alloc(u8, max_bytes),
        };
    }

    fn deinit(self: *RetainedEventLedger) void {
        while (self.count > 0) self.evictOldest();
        self.allocator.free(self.scratch);
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    fn append(self: *RetainedEventLedger, envelope: client_protocol.EventEnvelope) !void {
        if (envelope.event == .replay or envelope.event == .replay_gap) return;
        var writer = std.Io.Writer.fixed(self.scratch);
        std.json.Stringify.value(envelope, .{}, &writer) catch |err| switch (err) {
            error.WriteFailed => {
                while (self.count > 0) self.evictOldest();
                self.evicted_through_seq = envelope.seq;
                return;
            },
        };
        const json = try self.allocator.dupe(u8, self.scratch[0..writer.end]);
        errdefer self.allocator.free(json);
        while (self.count == self.entries.len or self.total_bytes + json.len > self.scratch.len) self.evictOldest();
        const index = (self.start + self.count) % self.entries.len;
        self.entries[index] = .{ .seq = envelope.seq, .json = json };
        self.count += 1;
        self.total_bytes += json.len;
    }

    fn buildReplay(
        self: *const RetainedEventLedger,
        allocator: std.mem.Allocator,
        request: client_protocol.ReplayRequest,
    ) !client_protocol.EventEnvelope {
        const first = self.firstRetainedSeq();
        const last = self.lastRetainedSeq();
        if (request.after < self.evicted_through_seq) {
            return .{ .event = .{ .replay_gap = .{
                .requested_after = request.after,
                .first_retained_seq = first,
                .last_retained_seq = last,
            } } };
        }
        var scratch = try allocator.alloc(
            client_protocol.RetainedEvent.Source,
            client_protocol.replay_event_count_max,
        );
        defer allocator.free(scratch);
        var out_count: usize = 0;
        var index: usize = 0;
        while (index < self.count and out_count < scratch.len) : (index += 1) {
            const entry = self.entryAt(index);
            if (entry.seq <= request.after) continue;
            scratch[out_count] = .{ .seq = entry.seq, .json = entry.json };
            out_count += 1;
        }
        return .{ .event = .{ .replay = try client_protocol.ReplayBatch.init(
            allocator,
            request.after,
            first,
            last,
            scratch[0..out_count],
        ) } };
    }

    fn firstRetainedSeq(self: *const RetainedEventLedger) client_protocol.EventSeq {
        if (self.count == 0) return self.evicted_through_seq + 1;
        return self.entries[self.start].seq;
    }

    fn lastRetainedSeq(self: *const RetainedEventLedger) client_protocol.EventSeq {
        if (self.count == 0) return self.evicted_through_seq;
        return self.entryAt(self.count - 1).seq;
    }

    fn entryAt(self: *const RetainedEventLedger, offset: usize) Entry {
        std.debug.assert(offset < self.count);
        return self.entries[(self.start + offset) % self.entries.len];
    }

    fn evictOldest(self: *RetainedEventLedger) void {
        std.debug.assert(self.count > 0);
        const entry = self.entries[self.start];
        self.evicted_through_seq = entry.seq;
        self.total_bytes -= entry.json.len;
        self.allocator.free(entry.json);
        self.start = (self.start + 1) % self.entries.len;
        self.count -= 1;
        if (self.count == 0) self.start = 0;
    }
};

// -- tests --------------------------------------------------------------

fn initTestRuntime(tmp: *std.testing.TmpDir, task_runtime: *runtime.Runtime) !SessionRuntime {
    return initTestRuntimeWithCaps(tmp, task_runtime, 4, 64);
}

fn initTestRuntimeWithCaps(
    tmp: *std.testing.TmpDir,
    task_runtime: *runtime.Runtime,
    command_capacity: usize,
    event_capacity: usize,
) !SessionRuntime {
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    return openSessionRuntime(std.testing.allocator, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .current_date = "2026-06-09",
        .open = .{ .create = .{ .session_id = "session", .timestamp = "2026-06-09T00:00:00Z" } },
        .dir = tmp.dir,
        .task_runtime = task_runtime,
        .command_capacity = command_capacity,
        .event_capacity = event_capacity,
    });
}

test "session stamp formats prompt date and iso timestamp" {
    const stamp = SessionStamp.now(std.testing.io);
    try std.testing.expectEqual(@as(usize, 10), stamp.date().len);
    try std.testing.expectEqual(@as(usize, 20), stamp.timestamp().len);
    try std.testing.expect(stamp.timestamp()[4] == '-' and stamp.timestamp()[10] == 'T');
    try std.testing.expect(stamp.timestamp()[19] == 'Z');
}

test "session runtime owns services session and bounded mailboxes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var session_runtime = try initTestRuntimeWithCaps(&tmp, task_runtime, 2, 2);
    defer session_runtime.deinit();

    try std.testing.expectEqual(@as(usize, 2), session_runtime.commands.capacity());
    try std.testing.expectEqual(@as(usize, 2), session_runtime.events.capacity());
    try std.testing.expectEqualStrings("session", session_runtime.session.manager.header.id);
}

test "session runtime acknowledges queue clear with a correlated queue fact" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var session_runtime = try initTestRuntime(&tmp, task_runtime);
    defer session_runtime.deinit();

    try session_runtime.submit(.{ .id = 1, .command = .{ .queue = .clear } });
    try session_runtime.step();
    var event = session_runtime.drainEvent().?;
    defer event.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?client_protocol.RequestId, 1), event.request_id);
    try std.testing.expect(event.event == .queue_changed);
    try std.testing.expectEqual(@as(usize, 0), event.event.queue_changed.steering_count);
}

test "session runtime replays retained event envelopes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var session_runtime = try initTestRuntime(&tmp, task_runtime);
    defer session_runtime.deinit();

    try session_runtime.submit(.{ .id = 1, .command = .{ .queue = .clear } });
    try session_runtime.step();
    var original = session_runtime.drainEvent().?;
    const original_seq = original.seq;
    original.deinit(std.testing.allocator);

    try session_runtime.submit(.{ .id = 2, .command = .{ .replay = .{ .after = 0 } } });
    try session_runtime.step();
    var replay = session_runtime.drainEvent().?;
    defer replay.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?client_protocol.RequestId, 2), replay.request_id);
    try std.testing.expect(replay.event == .replay);
    try std.testing.expectEqual(@as(usize, 1), replay.event.replay.events.len);
    try std.testing.expectEqual(original_seq, replay.event.replay.events[0].seq);
    try std.testing.expect(
        std.mem.indexOf(u8, replay.event.replay.events[0].json.text, "\"queue_changed\"") != null,
    );
}

test "session runtime reports replay gap after retained ledger eviction" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    var session_runtime = try openSessionRuntime(std.testing.allocator, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .current_date = "2026-06-09",
        .open = .{ .create = .{ .session_id = "session", .timestamp = "2026-06-09T00:00:00Z" } },
        .dir = tmp.dir,
        .task_runtime = task_runtime,
        .retained_event_capacity = 1,
    });
    defer session_runtime.deinit();

    try session_runtime.submit(.{ .id = 1, .command = .{ .queue = .clear } });
    try session_runtime.step();
    var first = session_runtime.drainEvent().?;
    first.deinit(std.testing.allocator);
    try session_runtime.submit(.{ .id = 2, .command = .{ .queue = .clear } });
    try session_runtime.step();
    var second = session_runtime.drainEvent().?;
    second.deinit(std.testing.allocator);

    try session_runtime.submit(.{ .id = 3, .command = .{ .replay = .{ .after = 0 } } });
    try session_runtime.step();
    var gap = session_runtime.drainEvent().?;
    defer gap.deinit(std.testing.allocator);
    try std.testing.expect(gap.event == .replay_gap);
    try std.testing.expectEqual(@as(client_protocol.EventSeq, 0), gap.event.replay_gap.requested_after);
}

test "session runtime request snapshot emits owned bounded snapshot event" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var session_runtime = try initTestRuntime(&tmp, task_runtime);
    defer session_runtime.deinit();

    try session_runtime.submit(.{ .id = 9, .command = .snapshot });
    try session_runtime.step();

    var event = session_runtime.drainEvent().?;
    defer event.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?client_protocol.RequestId, 9), event.request_id);
    try std.testing.expect(event.event == .snapshot);
    try std.testing.expectEqualStrings("session", event.event.snapshot.header.id.text);
    try std.testing.expectEqual(
        @as(?client_protocol.RequestId, null),
        event.event.snapshot.active_request_id,
    );
    try std.testing.expectEqual(@as(usize, 0), event.event.snapshot.history.items.len);
}

test "session runtime does not consume commands while event queue is full" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var session_runtime = try initTestRuntimeWithCaps(&tmp, task_runtime, 4, 1);
    defer session_runtime.deinit();

    try session_runtime.submit(.{ .id = 1, .command = .{ .queue = .clear } });
    try session_runtime.step();
    try session_runtime.submit(.{ .id = 2, .command = .snapshot });
    try session_runtime.step();

    var first = session_runtime.drainEvent().?;
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?client_protocol.RequestId, 1), first.request_id);
    try std.testing.expect(first.event == .queue_changed);

    try session_runtime.step();
    var second = session_runtime.drainEvent().?;
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?client_protocol.RequestId, 2), second.request_id);
    try std.testing.expect(second.event == .snapshot);
}

test "session runtime shutdown remains observable under event pressure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var session_runtime = try initTestRuntimeWithCaps(&tmp, task_runtime, 4, 1);
    defer session_runtime.deinit();

    try session_runtime.submit(.{ .id = 1, .command = .{ .queue = .clear } });
    try session_runtime.step();
    try session_runtime.submit(.{ .id = 2, .command = .shutdown });
    try session_runtime.step();

    var first = session_runtime.drainEvent().?;
    defer first.deinit(std.testing.allocator);
    try std.testing.expect(first.event == .queue_changed);

    try session_runtime.step();
    var second = session_runtime.drainEvent().?;
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?client_protocol.RequestId, 2), second.request_id);
    try std.testing.expect(second.event == .shutdown_started);
}

test "session runtime command queue full rejects submit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var session_runtime = try initTestRuntimeWithCaps(&tmp, task_runtime, 1, 4);
    defer session_runtime.deinit();

    try session_runtime.submit(.{ .id = 1, .command = .{ .queue = .clear } });
    try std.testing.expectError(error.Full, session_runtime.submit(.{ .id = 2, .command = .{ .queue = .clear } }));
}

test "session runtime cancels targeted active operation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var session_runtime = try initTestRuntime(&tmp, task_runtime);
    defer session_runtime.deinit();

    var prompt = try client_protocol.CommandEnvelope.initSubmitPrompt(std.testing.allocator, 1, "first", .auto);
    var prompt_owned = true;
    defer if (prompt_owned) prompt.deinit(std.testing.allocator);
    try session_runtime.submit(prompt);
    prompt_owned = false;
    try session_runtime.step();

    const operation_id = session_runtime.active.?.operation_id;
    try session_runtime.submit(.{
        .id = 2,
        .command = .{ .cancel = .{ .target = .{ .operation_id = operation_id } } },
    });
    try session_runtime.step();

    var found_canceled = false;
    while (session_runtime.drainEvent()) |event| {
        var owned = event;
        defer owned.deinit(std.testing.allocator);
        if (owned.event == .operation_finished and
            owned.event.operation_finished.reason == .canceled and
            owned.operation_id == operation_id)
        {
            found_canceled = true;
        }
    }
    try std.testing.expect(found_canceled);
}

test "session runtime queues prompt while active" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var session_runtime = try initTestRuntime(&tmp, task_runtime);
    defer session_runtime.deinit();

    var first = try client_protocol.CommandEnvelope.initSubmitPrompt(std.testing.allocator, 1, "first", .auto);
    var first_owned = true;
    defer if (first_owned) first.deinit(std.testing.allocator);
    try session_runtime.submit(first);
    first_owned = false;
    try session_runtime.step();
    try std.testing.expect(session_runtime.active != null);

    var second = try client_protocol.CommandEnvelope.initSubmitPrompt(std.testing.allocator, 2, "second", .auto);
    var second_owned = true;
    defer if (second_owned) second.deinit(std.testing.allocator);
    try session_runtime.submit(second);
    second_owned = false;
    try session_runtime.step();

    var found_queue = false;
    while (session_runtime.drainEvent()) |event| {
        var owned = event;
        defer owned.deinit(std.testing.allocator);
        if (owned.event == .queue_changed and owned.event.queue_changed.steering_count == 1) found_queue = true;
    }
    try std.testing.expect(found_queue);
}

fn testModel() ai.Model {
    return .{
        .id = "test-model",
        .name = "test model",
        .api = ai.KnownApi.openai_responses,
        .provider = ai.KnownProvider.openai,
        .base_url = "",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128000,
        .max_tokens = 4096,
    };
}

/// Stream that fails with a transient error for the first `fail_calls`
/// requests, then succeeds. Call count is container-level test state.
const FlakyStream = struct {
    var call_count: usize = 0;
    var fail_calls: usize = 1;

    fn reset(fails: usize) void {
        call_count = 0;
        fail_calls = fails;
    }

    fn stream(_: ?*anyopaque, request: ai.StreamRequest) ai.AssistantMessageEventStream {
        call_count += 1;
        var assistant_stream = ai.AssistantMessageEventStream.initBuffered();
        const sink = assistant_stream.sink();
        if (call_count <= fail_calls) {
            sink.endError(
                request.io,
                .error_,
                ai.protocol.emptyAssistantMessageFromRequest(request, .error_, "rate limit exceeded"),
            ) catch std.debug.assert(false);
        } else {
            sink.endDone(request.io, .stop, .{
                .content = &.{.{ .text = .{ .text = "recovered" } }},
                .api = request.model.api,
                .provider = request.model.provider,
                .model = request.model.id,
                .usage = ai.protocol.emptyUsage(),
                .stop_reason = .stop,
                .timestamp = 0,
            }) catch std.debug.assert(false);
        }
        return assistant_stream;
    }
};

fn initRetryTestRuntime(
    tmp: *std.testing.TmpDir,
    task_runtime: *runtime.Runtime,
    retry_settings_json: []const u8,
) !SessionRuntime {
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/.zi");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/.zi/settings.json", .data = retry_settings_json });
    return openSessionRuntime(std.testing.allocator, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .current_date = "2026-06-09",
        .open = .{ .create = .{ .session_id = "session", .timestamp = "2026-06-09T00:00:00Z" } },
        .dir = tmp.dir,
        .task_runtime = task_runtime,
        .model = testModel(),
        .stream = .{ .call_fn = FlakyStream.stream },
    });
}

test "session runtime retries transient failure through the live owner loop" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    FlakyStream.reset(1);
    var session_runtime = try initRetryTestRuntime(
        &tmp,
        task_runtime,
        "{\"retry\":{\"enabled\":true,\"maxRetries\":2,\"baseDelayMs\":0}}",
    );
    defer session_runtime.deinit();

    var prompt = try client_protocol.CommandEnvelope.initSubmitPrompt(std.testing.allocator, 1, "hello", .auto);
    var prompt_owned = true;
    defer if (prompt_owned) prompt.deinit(std.testing.allocator);
    try session_runtime.submit(prompt);
    prompt_owned = false;

    var found_retry_start = false;
    var found_retry_success = false;
    var finished_reason: ?client_protocol.OperationFinished.Reason = null;
    var iterations: usize = 0;
    while (finished_reason == null and iterations < 2000) : (iterations += 1) {
        try session_runtime.step();
        while (session_runtime.drainEvent()) |event| {
            var owned = event;
            defer owned.deinit(std.testing.allocator);
            switch (owned.event) {
                .auto_retry_start => found_retry_start = true,
                .auto_retry_end => |payload| {
                    if (payload.success) found_retry_success = true;
                },
                .operation_finished => |payload| finished_reason = payload.reason,
                else => {},
            }
        }
        try runtime.sleep(.fromMilliseconds(1));
    }

    try std.testing.expectEqual(client_protocol.OperationFinished.Reason.completed, finished_reason.?);
    try std.testing.expect(found_retry_start);
    try std.testing.expect(found_retry_success);
    try std.testing.expectEqual(@as(usize, 2), FlakyStream.call_count);
    try std.testing.expect(session_runtime.active == null);
}

const DriveOutcome = struct {
    reason: client_protocol.OperationFinished.Reason,
    saw_compaction_start: bool = false,
    saw_compaction_end_result: bool = false,
};

fn driveUntilOperationFinished(session_runtime: *SessionRuntime) !DriveOutcome {
    var outcome: DriveOutcome = .{ .reason = .failed };
    var iterations: usize = 0;
    while (iterations < 2000) : (iterations += 1) {
        try session_runtime.step();
        while (session_runtime.drainEvent()) |event| {
            var owned = event;
            defer owned.deinit(std.testing.allocator);
            switch (owned.event) {
                .compaction_start => outcome.saw_compaction_start = true,
                .compaction_end => |payload| {
                    if (payload.result != null) outcome.saw_compaction_end_result = true;
                },
                .operation_finished => |payload| {
                    outcome.reason = payload.reason;
                    return outcome;
                },
                else => {},
            }
        }
        try runtime.sleep(.fromMilliseconds(1));
    }
    return error.OperationDidNotFinish;
}

test "session runtime runs threshold compaction as the operation's opening phase" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    FlakyStream.reset(0);
    var session_runtime = try initRetryTestRuntime(
        &tmp,
        task_runtime,
        "{\"compaction\":{\"enabled\":true,\"keepRecentTokens\":1}}",
    );
    defer session_runtime.deinit();

    // First operation seeds history; nothing to compact yet.
    var first_prompt = try client_protocol.CommandEnvelope.initSubmitPrompt(std.testing.allocator, 1, "hello", .auto);
    var first_owned = true;
    defer if (first_owned) first_prompt.deinit(std.testing.allocator);
    try session_runtime.submit(first_prompt);
    first_owned = false;
    const first = try driveUntilOperationFinished(&session_runtime);
    try std.testing.expectEqual(client_protocol.OperationFinished.Reason.completed, first.reason);
    try std.testing.expect(!first.saw_compaction_start);

    // Second operation opens with the summary run, then runs the prompt.
    var second_prompt = try client_protocol.CommandEnvelope.initSubmitPrompt(std.testing.allocator, 2, "again", .auto);
    var second_owned = true;
    defer if (second_owned) second_prompt.deinit(std.testing.allocator);
    try session_runtime.submit(second_prompt);
    second_owned = false;
    const second = try driveUntilOperationFinished(&session_runtime);
    try std.testing.expectEqual(client_protocol.OperationFinished.Reason.completed, second.reason);
    try std.testing.expect(second.saw_compaction_start);
    try std.testing.expect(second.saw_compaction_end_result);

    // One summary call between the two prompt calls; history holds the
    // compaction entry before the second turn.
    try std.testing.expectEqual(@as(usize, 3), FlakyStream.call_count);
    try std.testing.expect(session_runtime.session.manager.entries.items[2] == .compaction);
    try std.testing.expect(session_runtime.active == null);
}

test "session runtime cancel during retry backoff settles operation as canceled" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    FlakyStream.reset(1);
    var session_runtime = try initRetryTestRuntime(
        &tmp,
        task_runtime,
        "{\"retry\":{\"enabled\":true,\"maxRetries\":2,\"baseDelayMs\":60000}}",
    );
    defer session_runtime.deinit();

    var prompt = try client_protocol.CommandEnvelope.initSubmitPrompt(std.testing.allocator, 1, "hello", .auto);
    var prompt_owned = true;
    defer if (prompt_owned) prompt.deinit(std.testing.allocator);
    try session_runtime.submit(prompt);
    prompt_owned = false;

    // Drive until the failed run settles into the backoff wait. The loop
    // stays responsive the whole time: step() returns instead of sleeping.
    var iterations: usize = 0;
    while (iterations < 2000) : (iterations += 1) {
        try session_runtime.step();
        if (session_runtime.active) |active| {
            if (active.phase == .retry_wait) break;
        }
        try runtime.sleep(.fromMilliseconds(1));
    }
    try std.testing.expect(session_runtime.active.?.phase == .retry_wait);

    try session_runtime.submit(.{ .id = 2, .command = .{ .cancel = .{ .target = .active } } });
    try session_runtime.step();

    var found_retry_cancelled = false;
    var found_canceled = false;
    while (session_runtime.drainEvent()) |event| {
        var owned = event;
        defer owned.deinit(std.testing.allocator);
        switch (owned.event) {
            .auto_retry_end => |payload| {
                if (!payload.success) {
                    found_retry_cancelled = true;
                    try std.testing.expectEqualStrings("Retry cancelled", payload.final_error.?.text);
                }
            },
            .operation_finished => |payload| {
                if (payload.reason == .canceled) found_canceled = true;
            },
            else => {},
        }
    }
    try std.testing.expect(found_retry_cancelled);
    try std.testing.expect(found_canceled);
    try std.testing.expect(session_runtime.active == null);
    try std.testing.expectEqual(@as(usize, 1), FlakyStream.call_count);
}

test "retained ledger terminal agent events do not carry message payloads" {
    var ledger = try RetainedEventLedger.init(std.testing.allocator, 4, 256);
    defer ledger.deinit();

    var agent_end = try client_protocol.OwnedAgentEvent.init(std.testing.allocator, .agent_end);
    defer agent_end.deinit(std.testing.allocator);
    try ledger.append(.{ .seq = 1, .event = .{ .agent_event = agent_end } });

    var turn_end = try client_protocol.OwnedAgentEvent.init(std.testing.allocator, .turn_end);
    defer turn_end.deinit(std.testing.allocator);
    try ledger.append(.{ .seq = 2, .event = .{ .agent_event = turn_end } });

    try std.testing.expectEqual(@as(usize, 2), ledger.count);
    for (0..ledger.count) |index| {
        const entry = ledger.entryAt(index);
        try std.testing.expect(entry.json.len < 128);
        try std.testing.expect(std.mem.indexOf(u8, entry.json, "\"message\"") == null);
    }
}

test "retained ledger oversized encode evicts through seq and accepts later events" {
    var ledger = try RetainedEventLedger.init(std.testing.allocator, 2, 128);
    defer ledger.deinit();

    try ledger.append(.{
        .seq = 1,
        .event = .{ .operation_finished = .{ .reason = .completed } },
    });

    var message = try client_protocol.EventText.init(std.testing.allocator, "x" ** 512);
    defer message.deinit(std.testing.allocator);
    try ledger.append(.{
        .seq = 2,
        .event = .{ .rejected = .{ .code = .invalid_command, .message = message } },
    });

    try std.testing.expectEqual(@as(usize, 0), ledger.count);
    try std.testing.expectEqual(@as(client_protocol.EventSeq, 2), ledger.evicted_through_seq);
    try std.testing.expectEqual(@as(usize, 0), ledger.total_bytes);

    try ledger.append(.{
        .seq = 3,
        .event = .{ .operation_finished = .{ .reason = .completed } },
    });

    var gap = try ledger.buildReplay(std.testing.allocator, .{ .after = 1 });
    defer gap.deinit(std.testing.allocator);
    try std.testing.expect(gap.event == .replay_gap);

    var replay = try ledger.buildReplay(std.testing.allocator, .{ .after = 2 });
    defer replay.deinit(std.testing.allocator);
    try std.testing.expect(replay.event == .replay);
    try std.testing.expectEqual(@as(usize, 1), replay.event.replay.events.len);
    try std.testing.expectEqual(@as(client_protocol.EventSeq, 3), replay.event.replay.events[0].seq);
}
