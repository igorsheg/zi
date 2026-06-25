//! The session mailbox host: owns the current AgentSession slot, the bounded
//! command and event queues, the retained-event replay ledger, and the single
//! owner loop seam (`waitAndApplyWake` + `step`). Session replacement builds a
//! complete next slot before publishing it. Frontends talk to it only through
//! `submit`/`drainEvent`; no callback path mutates session state.

const std = @import("std");
const agent_mod = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const runtime = @import("../runtime/root.zig");
const AgentSession = @import("AgentSession.zig");
const client_protocol = @import("client_protocol.zig");
const file_completion = @import("file_completion.zig");
const paths_mod = @import("paths.zig");
const RuntimeServices = @import("runtime_services.zig").RuntimeServices;
const session_listing = @import("session_listing.zig");
const session_manager = @import("session_manager.zig");
const settings_mod = @import("settings.zig");
const slash_commands = @import("slash_commands.zig");

pub const WakeResult = enum { input, session, frame };

const session_command_message_bytes_max: usize = 160;
const session_public_events_per_turn_max: usize = 16;
const SessionStats = client_protocol.PromptCommandSessionStats;

fn ignoreBestEffortError(err: anyerror) void {
    std.debug.assert(@errorName(err).len > 0);
}

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

    const task_runtime = options.task_runtime orelse try runtime.Runtime.init(allocator, .{});
    errdefer if (options.task_runtime == null) task_runtime.deinit();

    const resolved_cwd = if (std.mem.eql(u8, options.cwd, "."))
        try options.dir.realPathFileAlloc(task_runtime.io(), options.cwd, allocator)
    else
        try allocator.dupe(u8, options.cwd);
    defer allocator.free(resolved_cwd);

    var services = try RuntimeServices.init(allocator, .{
        .cwd = resolved_cwd,
        .agent_dir = resolved_agent_dir,
        .dir = options.dir,
        .environ = options.environ,
        .task_runtime = task_runtime,
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
        .task_runtime = task_runtime,
        .task_runtime_owner = if (options.task_runtime == null) .owned else .borrowed,
        .host_config = .{
            .dir = options.dir,
            .environ = options.environ,
            .allow_paths_outside_cwd = options.allow_paths_outside_cwd,
            .public_event_capacity = options.public_event_capacity,
            .model = options.model,
            .thinking_level = options.thinking_level,
            .stream = options.stream,
        },
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
            var store = try session_manager.SessionStore.createDeferred(allocator, services.io, options.dir, .{
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
            session_options.store = .{ .restore = .{
                .allocator = allocator,
                .dir = options.dir,
                .file_name = file_name,
            } };
            var session = try AgentSession.init(allocator, services.io, session_options);
            errdefer shutdownAndDeinitSession(&session);
            restoreSessionPreferences(services, &session, .{
                .model_explicit = options.model != null,
                .thinking_explicit = options.thinking_level != null,
            });
            return session;
        },
    }
}

const RestorePreferenceOptions = struct {
    model_explicit: bool,
    thinking_explicit: bool,
};

fn restoreSessionPreferences(
    services: *RuntimeServices,
    session: *AgentSession,
    options: RestorePreferenceOptions,
) void {
    const preferences = session.manager.sessionPreferences();
    if (!options.model_explicit) {
        if (preferences.model) |saved| {
            if (ai.getModel(saved.provider, saved.model_id)) |model| {
                if (services.auth_manager.hasAuth(model.provider) and
                    services.provider_registry.get(model.api) != null)
                {
                    session.agent.setModel(model);
                    if (services.provider_registry.get(model.api)) |provider| {
                        session.agent.setStream(provider.stream_simple);
                    }
                }
            }
        }
    }
    if (!options.thinking_explicit) {
        if (preferences.thinking_level) |text| {
            if (parseThinkingLevel(text)) |level| session.agent.setThinkingLevel(level);
        }
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
                    if (services.auth_manager.hasAuth(model.provider) and
                        services.provider_registry.get(model.api) != null) break :model model;
                }
            }
        }
        for (ai.getProviders()) |provider| {
            for (ai.getModels(provider)) |model| {
                if (services.auth_manager.hasAuth(model.provider) and
                    services.provider_registry.get(model.api) != null) break :model model;
            }
        }
        break :model agent_mod.Agent.defaultModel();
    };

    const thinking_level = options.thinking_level orelse level: {
        if (project.default_thinking_level orelse global.default_thinking_level) |text| {
            if (parseThinkingLevel(text)) |parsed| break :level parsed;
        }
        break :level .off;
    };
    const hide_thinking = project.hide_thinking_block orelse global.hide_thinking_block orelse true;

    var compaction: session_manager.CompactionSettings = .{};
    var retry: AgentSession.RetrySettings = .{};
    for ([2]settings_mod.Settings{ global, project }) |scope| {
        if (scope.compaction) |value| {
            if (value.keep_recent_tokens) |tokens| compaction.keep_recent_tokens = tokens;
            if (value.reserve_tokens) |tokens| compaction.reserve_tokens = tokens;
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
        .hide_thinking = hide_thinking,
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

fn parseThinkingLevel(text: []const u8) ?agent_mod.ThinkingLevel {
    inline for (@typeInfo(agent_mod.ThinkingLevel).@"enum".fields) |field| {
        if (std.ascii.eqlIgnoreCase(text, field.name)) return @field(agent_mod.ThinkingLevel, field.name);
    }
    return null;
}

const TaskRuntimeOwner = enum { owned, borrowed };

const PendingFileCompletion = struct {
    request_id: ?client_protocol.RequestId,
    query: []u8,
};

pub const SessionRuntime = struct {
    allocator: std.mem.Allocator,
    services: RuntimeServices,
    session: AgentSession,
    task_runtime: *runtime.Runtime,
    task_runtime_owner: TaskRuntimeOwner,
    host_config: HostConfig,
    command_buffer: []client_protocol.CommandEnvelope,
    event_buffer: []client_protocol.EventEnvelope,
    commands: client_protocol.CommandQueue,
    events: client_protocol.EventQueue,
    retained_events: RetainedEventLedger,
    wake_event: runtime.ResetEvent = .init,
    active: ?ActiveOperation = null,
    completion_load: ?CompletionLoad = null,
    pending_file_completion: ?PendingFileCompletion = null,
    file_index: FileIndexState = .not_started,
    next_operation_id: client_protocol.OperationId = 1,
    next_event_seq: client_protocol.EventSeq = 1,
    pending_event: ?client_protocol.EventEnvelope = null,
    session_chrome_dirty: bool = false,

    const HostConfig = struct {
        dir: std.Io.Dir,
        environ: ?*const std.process.Environ.Map,
        allow_paths_outside_cwd: bool,
        public_event_capacity: usize,
        model: ?ai.Model,
        thinking_level: ?agent_mod.ThinkingLevel,
        stream: ?ai.StreamFunction,
    };

    /// All facts about the one in-flight prompt operation live together.
    /// The phase makes "a run, a summary run, and a retry timer at once"
    /// unrepresentable.
    const ActiveOperation = struct {
        phase: Phase,
        request_id: ?client_protocol.RequestId,
        operation_id: client_protocol.OperationId,
        prompt_text: []u8,
        prompt_images: []ai.ImageContent,
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

    const CompletionLoadKind = enum { resume_sessions, file_index_build, file_query };

    const CompletionLoad = struct {
        kind: CompletionLoadKind,
        request_id: ?client_protocol.RequestId,
        models: ?client_protocol.CompletionList = null,
        task: runtime.Task(anyerror!CompletionLoadResult),
        cwd: ?[]u8 = null,
        agent_dir: ?[]u8 = null,
        current_session_leaf: ?[]u8 = null,
        query: ?[]u8 = null,
    };

    const FileIndexState = union(enum) {
        not_started,
        building,
        ready: file_completion.Index,
        failed: BuildFailure,

        fn deinit(self: *FileIndexState) void {
            switch (self.*) {
                .ready => |*index| index.deinit(std.heap.page_allocator),
                .not_started, .building, .failed => {},
            }
            self.* = undefined;
        }
    };

    const BuildFailure = struct {
        query: [client_protocol.file_completion_query_bytes_max]u8 = undefined,
        query_len: u16 = 0,
        message: [64]u8 = undefined,
        message_len: u8 = 0,

        fn init(query: []const u8, message: []const u8) BuildFailure {
            var failure: BuildFailure = .{};
            failure.query_len = copyBytes(&failure.query, query);
            failure.message_len = @intCast(copyBytes(&failure.message, message));
            return failure;
        }

        fn querySlice(self: *const BuildFailure) []const u8 {
            return self.query[0..self.query_len];
        }
    };

    pub fn deinit(self: *SessionRuntime) void {
        self.cancelCompletionLoad();
        if (self.pending_file_completion) |pending| self.allocator.free(pending.query);
        self.file_index.deinit();
        if (self.active) |active| {
            self.destroyActivePhase(active);
            self.allocator.free(active.prompt_text);
            client_protocol.freeSubmitImages(self.allocator, active.prompt_images);
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
        switch (self.task_runtime_owner) {
            .owned => self.task_runtime.deinit(),
            .borrowed => {},
        }
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
        return self.pending_event != null or
            self.events.count() > 0 or
            self.session_chrome_dirty or
            self.commands.count() > 0 or
            (self.pending_file_completion != null and self.completion_load == null) or
            (self.completion_load != null and self.completion_load.?.task.hasResult());
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
                if (self.completion_load) |*load| {
                    switch (try runtime.select(.{
                        .input = &input,
                        .prompt = &progress,
                        .completion = &load.task,
                        .public_event = public_event_wake,
                        .command = command_wake,
                        .frame = &frame,
                    })) {
                        .input => |result| {
                            result catch return .session;
                            return .input;
                        },
                        .prompt => |result| {
                            self.applyActiveProgress(result) catch |err| self.failActiveOperation(err);
                            return .session;
                        },
                        .completion => |result| {
                            if (self.hasEventCapacity()) try self.applyCompletionLoadResult(result);
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
                }
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
                        self.applyActiveProgress(result) catch |err| self.failActiveOperation(err);
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
                if (self.completion_load) |*load| {
                    switch (try runtime.select(.{
                        .input = &input,
                        .retry = &retry,
                        .completion = &load.task,
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
                        .completion => |result| {
                            if (self.hasEventCapacity()) try self.applyCompletionLoadResult(result);
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
                }
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
        if (self.completion_load) |*load| {
            switch (try runtime.select(.{
                .input = &input,
                .completion = &load.task,
                .public_event = public_event_wake,
                .command = command_wake,
                .frame = &frame,
            })) {
                .input => |result| {
                    result catch return .session;
                    return .input;
                },
                .completion => |result| {
                    if (self.hasEventCapacity()) try self.applyCompletionLoadResult(result);
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
        }
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
        if (self.hasEventCapacity()) try self.finishReadyCompletionLoad();
        if (self.hasEventCapacity()) try self.startPendingFileCompletionLoad();
        while (self.hasEventCapacity()) {
            const envelope = self.commands.pop() orelse break;
            var command = envelope;
            defer command.deinit(self.allocator);
            try self.applyCommand(command);
            if (!self.flushPendingEvent()) return;
        }
        if (!self.hasEventCapacity()) return;
        self.startDueRetry();
        self.stepPromptProgressBounded(64) catch |err| self.failActiveOperation(err);
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
            .resubmit_prompt => self.session.startPromptRun(active.prompt_text, active.prompt_images),
            .continue_run => self.session.startContinueRun(),
        } catch |err| {
            self.failActiveOperation(err);
            return;
        };
        active.phase = .{ .running = run };
        self.drainSessionEvents(active.request_id) catch |err| ignoreBestEffortError(err);
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
                self.session.cancelPromptRun(run) catch |err| ignoreBestEffortError(err);
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
                // Slash commands are mailbox facts, not prompts: they reply
                // with a request-correlated prompt_command event and never
                // reach the model or the queues, active operation or not.
                if (try self.handleSlashCommand(envelope.id, prompt.text)) return;
                if (self.active != null and prompt.mode != .start) {
                    const delivery: AgentSession.QueuePromptKind = switch (prompt.mode) {
                        .auto, .steer => .steer,
                        .enqueue => .follow_up,
                        .start => unreachable,
                    };
                    self.session.queuePrompt(prompt.text, prompt.images, delivery) catch |err| {
                        try self.enqueueRejected(envelope.id, rejectionCode(err), @errorName(err));
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
                    try self.enqueueRejected(envelope.id, .exhausted, @errorName(err));
                    return;
                };
                const prompt_images = client_protocol.copySubmitImages(self.allocator, prompt.images) catch |err| {
                    self.allocator.free(prompt_text);
                    try self.enqueueRejected(envelope.id, .exhausted, @errorName(err));
                    return;
                };
                const overflow_count_before = self.session.contextOverflowCount();
                // Threshold compaction is the operation's opening phase when
                // due; its settle verdict starts the prompt run. A failure to
                // even start it degrades: the prompt runs uncompacted.
                const phase: ActiveOperation.Phase = blk: {
                    if (self.session.shouldRunThresholdCompaction()) {
                        if (self.session.startCompactionRun(.threshold, false, null) catch null) |compaction_run| {
                            break :blk .{ .compacting = compaction_run };
                        }
                    }
                    const run = self.session.startPromptRun(prompt.text, prompt.images) catch |err| {
                        self.allocator.free(prompt_text);
                        client_protocol.freeSubmitImages(self.allocator, prompt_images);
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
                    .prompt_images = prompt_images,
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
                client_protocol.freeSubmitImages(self.allocator, active.prompt_images);
                try self.drainSessionEvents(envelope.id);
                var failure = try self.canceledOperationFailure();
                errdefer failure.deinit(self.allocator);
                try self.enqueueEvent(.{
                    .request_id = envelope.id,
                    .operation_id = active.operation_id,
                    .event = .{ .operation_finished = .{ .reason = .canceled, .failure = failure } },
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
            .completion_snapshot => try self.startCompletionLoad(envelope.id),
            .file_completion => |request| try self.startFileCompletionLoad(envelope.id, request.query),
            .replay => |request| {
                var replay = try self.retained_events.buildReplay(self.allocator, request);
                replay.request_id = envelope.id;
                try self.enqueueEvent(replay);
            },
            .history_page => |request| {
                var page = self.session.clientHistoryPage(self.allocator, request.before_entry_id) catch |err| {
                    try self.enqueueRejected(envelope.id, rejectionCode(err), @errorName(err));
                    return;
                };
                errdefer page.deinit(self.allocator);
                try self.enqueueEvent(.{ .request_id = envelope.id, .event = .{ .history_page = page } });
            },
            .switch_session => |request| try self.switchSession(envelope.id, request.session_file_name),
            .shutdown => {
                // A pending retry or summary run never outlives shutdown:
                // settle it as canceled. (A running prompt is aborted by the
                // session's own shutdown path below.)
                if (self.active != null and self.active.?.phase != .running) {
                    const active = self.takeActive().?;
                    self.cancelAndDestroyActivePhase(active);
                    self.allocator.free(active.prompt_text);
                    client_protocol.freeSubmitImages(self.allocator, active.prompt_images);
                    try self.drainSessionEvents(active.request_id);
                    var failure = try self.canceledOperationFailure();
                    errdefer failure.deinit(self.allocator);
                    try self.enqueueEvent(.{
                        .request_id = active.request_id,
                        .operation_id = active.operation_id,
                        .event = .{ .operation_finished = .{ .reason = .canceled, .failure = failure } },
                    });
                }
                self.session.requestShutdown();
                try self.enqueueEvent(.{ .request_id = envelope.id, .event = .shutdown_started });
            },
        }
    }

    fn switchSession(
        self: *SessionRuntime,
        request_id: ?client_protocol.RequestId,
        session_selector: []const u8,
    ) !void {
        if (self.active != null) {
            try self.enqueueRejected(request_id, .busy, "cancel active operation before resume");
            return;
        }
        const session_file_name = session_listing.selectRuntimeSession(self.allocator, self.services.io, .{
            .cwd = self.services.cwd,
            .agent_dir_override = self.services.agent_dir,
            .dir = self.host_config.dir,
            .environ = self.host_config.environ,
            .selector = session_selector,
        }) catch |err| {
            try self.enqueueRejected(request_id, rejectionCode(err), @errorName(err));
            return;
        } orelse {
            try self.enqueueRejected(request_id, .invalid_command, "session not found");
            return;
        };
        defer self.allocator.free(session_file_name);

        const stamp = SessionStamp.now(self.services.io);
        try self.replaceSession(request_id, stamp, .{ .resume_existing = .{ .session_file_name = session_file_name } }, .resumed, session_file_name);
    }

    fn createNewSession(self: *SessionRuntime, request_id: ?client_protocol.RequestId) !void {
        if (self.active != null) {
            try self.enqueueRejected(request_id, .busy, "cancel active operation before new session");
            return;
        }
        const stamp = SessionStamp.now(self.services.io);
        var session_id_buffer: [48]u8 = undefined;
        const session_id = std.fmt.bufPrint(&session_id_buffer, "session-{d}", .{stamp.nanoseconds}) catch
            "session";
        try self.replaceSession(request_id, stamp, .{ .create = .{ .session_id = session_id, .timestamp = stamp.timestamp() } }, .created, null);
    }

    fn replaceSession(
        self: *SessionRuntime,
        request_id: ?client_protocol.RequestId,
        stamp: SessionStamp,
        open: Open,
        reason: client_protocol.SessionChanged.Reason,
        resume_file_name: ?[]const u8,
    ) !void {
        var next_services = try RuntimeServices.init(self.allocator, .{
            .cwd = self.services.cwd,
            .agent_dir = self.services.agent_dir,
            .dir = self.host_config.dir,
            .environ = self.host_config.environ,
            .task_runtime = self.task_runtime,
        });
        var next_services_owned = true;
        errdefer if (next_services_owned) next_services.deinit();

        var next_session = openSession(self.allocator, &next_services, .{
            .cwd = self.services.cwd,
            .agent_dir_override = self.services.agent_dir,
            .current_date = stamp.date(),
            .open = open,
            .model = self.host_config.model,
            .thinking_level = self.host_config.thinking_level,
            .stream = self.host_config.stream,
            .dir = self.host_config.dir,
            .environ = self.host_config.environ,
            .task_runtime = self.task_runtime,
            .allow_paths_outside_cwd = self.host_config.allow_paths_outside_cwd,
            .public_event_capacity = self.host_config.public_event_capacity,
        }) catch |err| {
            next_services.deinit();
            next_services_owned = false;
            if (resume_file_name) |file_name| {
                try self.enqueueResumeRejected(request_id, file_name, err);
            } else {
                try self.enqueueRejected(request_id, rejectionCode(err), @errorName(err));
            }
            return;
        };
        var next_session_owned = true;
        errdefer if (next_session_owned) shutdownAndDeinitSession(&next_session);

        self.cancelCompletionLoad();
        self.resetFileCompletionState();

        var old_session = self.session;
        var old_services = self.services;
        self.services = next_services;
        next_services_owned = false;
        self.session = next_session;
        next_session_owned = false;
        shutdownAndDeinitSession(&old_session);
        old_services.deinit();

        try self.enqueueEvent(.{ .request_id = request_id, .event = .{ .session_changed = .{ .reason = reason } } });
        try self.enqueueSessionChrome(request_id);
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
                defer client_protocol.freeSubmitImages(self.allocator, finished.prompt_images);
                const reason: client_protocol.OperationFinished.Reason = switch (verdict) {
                    .completed => .completed,
                    .failed => .failed,
                    .retry, .compact => unreachable,
                };
                var failure = if (reason == .failed)
                    try self.copyLatestOperationalFailure()
                else
                    null;
                errdefer if (failure) |*owned| owned.deinit(self.allocator);
                try self.drainSessionEvents(finished.request_id);
                try self.enqueueEvent(.{
                    .request_id = finished.request_id,
                    .operation_id = finished.operation_id,
                    .event = .{ .operation_finished = .{ .reason = reason, .failure = failure } },
                });
                if (self.session_chrome_dirty) try self.enqueueSessionChrome(finished.request_id);
            },
        }
    }

    fn copyLatestOperationalFailure(self: *SessionRuntime) !?client_protocol.OperationalFailure {
        const failure = self.session.latestOperationalFailure() orelse return null;
        return try client_protocol.OperationalFailure.init(self.allocator, failure);
    }

    fn canceledOperationFailure(self: *SessionRuntime) !client_protocol.OperationalFailure {
        const failure: ai.OperationalFailure = .{
            .category = .canceled,
            .message = "Request was aborted",
            .retryable = .no,
            .provider = self.session.agent.state.model.provider,
            .model = self.session.agent.state.model.id,
        };
        return client_protocol.OperationalFailure.init(self.allocator, failure);
    }

    /// Handle one slash command. Returns false when the text is not a
    /// command (no leading '/', or '/' without a name) so it flows on as a
    /// normal prompt. Replies are bounded; an over-long echo degrades to a
    /// generic message instead of failing.
    fn handleSlashCommand(
        self: *SessionRuntime,
        request_id: ?client_protocol.RequestId,
        text: []const u8,
    ) !bool {
        const invocation = slash_commands.parseInvocation(text) orelse return false;
        const spec = slash_commands.lookup(invocation.name) orelse {
            var reply_buffer: [256]u8 = undefined;
            const reply = std.fmt.bufPrint(&reply_buffer, "unknown command: /{s}", .{invocation.name}) catch
                "unknown command";
            try self.enqueuePromptCommand(request_id, invocation.name, .unknown, reply);
            return true;
        };

        var reply_buffer: [256]u8 = undefined;
        switch (spec.id) {
            .help => try self.enqueuePromptCommand(
                request_id,
                spec.name,
                .handled,
                slash_commands.formatAvailable(&reply_buffer),
            ),
            .session => try self.enqueueSessionPromptCommand(request_id, spec.name),
            .model => try self.handleModelSlashCommand(request_id, spec.name, invocation.args),
            .resume_session => try self.handleResumeSlashCommand(request_id, spec.name, invocation.args),
            .new_session => try self.handleNewSlashCommand(request_id),
            .compact => try self.handleCompactSlashCommand(request_id, spec.name, invocation.args),
            .settings => try self.handleSettingsSlashCommand(request_id, spec.name, invocation.args),
        }
        return true;
    }

    fn parseSlashCommand(text: []const u8) ?[]const u8 {
        return slash_commands.parseName(text);
    }

    fn formatSessionFallback(self: *const SessionRuntime, buffer: []u8, stats: SessionStats) []const u8 {
        return std.fmt.bufPrint(buffer, "session: {s}; messages: {d}; tokens: {d}", .{
            self.session.manager.header.id,
            stats.total_messages,
            stats.total_tokens,
        }) catch "session status unavailable";
    }

    fn collectSessionStats(manager: *const session_manager.SessionManager) SessionStats {
        var stats: SessionStats = .{};
        for (manager.entries.items) |entry| switch (entry) {
            .compaction, .model_change, .thinking_level_change => {},
            .message => |message_entry| {
                stats.total_messages += 1;
                switch (message_entry.message) {
                    .user => stats.user_messages += 1,
                    .assistant => |assistant| {
                        stats.assistant_messages += 1;
                        stats.input_tokens +|= assistant.usage.input;
                        stats.output_tokens +|= assistant.usage.output;
                        stats.cache_read_tokens +|= assistant.usage.cache_read;
                        stats.cache_write_tokens +|= assistant.usage.cache_write;
                        stats.total_tokens +|= assistant.usage.input +|
                            assistant.usage.output +|
                            assistant.usage.cache_read +|
                            assistant.usage.cache_write;
                        stats.cost += assistant.usage.cost.total;
                        for (assistant.content) |content| switch (content) {
                            .tool_call => stats.tool_calls += 1,
                            .text, .thinking => {},
                        };
                    },
                    .tool_result => stats.tool_results += 1,
                    .custom => {},
                }
            },
        };
        return stats;
    }

    fn handleResumeSlashCommand(
        self: *SessionRuntime,
        request_id: ?client_protocol.RequestId,
        command: []const u8,
        args: []const u8,
    ) !void {
        if (args.len == 0) {
            try self.enqueuePromptCommand(request_id, command, .handled, "usage: /resume <session-file>");
            return;
        }
        try self.switchSession(request_id, args);
    }

    fn handleNewSlashCommand(self: *SessionRuntime, request_id: ?client_protocol.RequestId) !void {
        try self.createNewSession(request_id);
    }

    fn handleSettingsSlashCommand(
        self: *SessionRuntime,
        request_id: ?client_protocol.RequestId,
        command: []const u8,
        args: []const u8,
    ) !void {
        if (args.len == 0) {
            try self.enqueuePromptCommand(request_id, command, .handled, "usage: /settings <thinking:level|thinking:hidden|thinking:shown>");
            return;
        }
        if (std.mem.startsWith(u8, args, "thinking:")) {
            const value = args["thinking:".len..];
            if (std.mem.eql(u8, value, "hidden")) {
                try self.setHideThinking(true);
                try self.enqueuePromptCommand(request_id, command, .handled, "thinking: hidden");
                try self.enqueueSessionChrome(request_id);
                return;
            }
            if (std.mem.eql(u8, value, "shown")) {
                try self.setHideThinking(false);
                try self.enqueuePromptCommand(request_id, command, .handled, "thinking: shown");
                try self.enqueueSessionChrome(request_id);
                return;
            }
            if (parseThinkingLevel(value)) |level| {
                try self.setSessionThinkingLevel(level);
                var reply_buffer: [64]u8 = undefined;
                const reply = std.fmt.bufPrint(&reply_buffer, "thinking effort: {s}", .{@tagName(level)}) catch
                    "thinking effort changed";
                try self.enqueuePromptCommand(request_id, command, .handled, reply);
                try self.enqueueSessionChrome(request_id);
                return;
            }
        }
        try self.enqueuePromptCommand(request_id, command, .failed, "unknown setting");
    }

    fn handleCompactSlashCommand(
        self: *SessionRuntime,
        request_id: ?client_protocol.RequestId,
        command: []const u8,
        args: []const u8,
    ) !void {
        if (self.active != null) {
            try self.enqueuePromptCommand(request_id, command, .failed, "cancel active operation before compaction");
            return;
        }
        const compaction_prompt = if (args.len == 0) null else args;
        const compaction_run = self.session.startCompactionRun(.manual, false, compaction_prompt) catch |err| {
            try self.enqueuePromptCommand(request_id, command, .failed, @errorName(err));
            return;
        } orelse {
            try self.enqueuePromptCommand(request_id, command, .failed, "nothing to compact");
            return;
        };
        errdefer self.session.destroyCompactionRun(compaction_run);
        const prompt_text = try self.allocator.dupe(u8, "");
        errdefer self.allocator.free(prompt_text);
        self.active = .{
            .phase = .{ .compacting = compaction_run },
            .request_id = request_id,
            .operation_id = self.nextOperationId(),
            .prompt_text = prompt_text,
            .prompt_images = &.{},
            .overflow_count_before = self.session.contextOverflowCount(),
        };
        try self.enqueueEvent(.{
            .request_id = request_id,
            .operation_id = self.active.?.operation_id,
            .event = .operation_started,
        });
        try self.drainSessionEvents(request_id);
    }

    fn handleModelSlashCommand(
        self: *SessionRuntime,
        request_id: ?client_protocol.RequestId,
        command: []const u8,
        args: []const u8,
    ) !void {
        if (args.len == 0) {
            try self.enqueuePromptCommand(request_id, command, .handled, "usage: /model <provider/model>");
            return;
        }
        if (self.active != null) {
            try self.enqueuePromptCommand(request_id, command, .failed, "cancel active operation before model change");
            return;
        }
        const model = self.resolveModelSelector(args) catch |err| {
            const message = switch (err) {
                error.AmbiguousModel => "ambiguous model; use provider/model",
                error.InvalidModelSelector => "invalid model selector; use provider/model",
                error.UnknownModel => "unknown model",
            };
            try self.enqueuePromptCommand(request_id, command, .failed, message);
            return;
        };
        if (!self.services.auth_manager.hasAuth(model.provider)) {
            var reply_buffer: [160]u8 = undefined;
            const reply = std.fmt.bufPrint(&reply_buffer, "missing auth for provider: {s}", .{model.provider}) catch
                "missing auth for provider";
            try self.enqueuePromptCommand(request_id, command, .failed, reply);
            return;
        }
        if (self.services.provider_registry.get(model.api) == null) {
            var reply_buffer: [160]u8 = undefined;
            const reply = std.fmt.bufPrint(
                &reply_buffer,
                "provider unavailable for model: {s}",
                .{model.provider},
            ) catch "provider unavailable for model";
            try self.enqueuePromptCommand(request_id, command, .failed, reply);
            return;
        }

        self.setSessionModel(model) catch |err| {
            try self.enqueuePromptCommand(request_id, command, .failed, @errorName(err));
            return;
        };
        var reply_buffer: [256]u8 = undefined;
        const reply = std.fmt.bufPrint(&reply_buffer, "model: {s}/{s}", .{ model.provider, model.id }) catch
            "model changed";
        try self.enqueuePromptCommand(request_id, command, .handled, reply);
        try self.enqueueSessionChrome(request_id);
    }

    const ModelResolveError = error{ UnknownModel, AmbiguousModel, InvalidModelSelector };

    fn resolveModelSelector(self: *const SessionRuntime, selector: []const u8) ModelResolveError!ai.Model {
        if (selector.len == 0) return error.InvalidModelSelector;
        if (std.mem.findScalar(u8, selector, '/')) |slash| {
            if (slash == 0 or slash + 1 >= selector.len) return error.InvalidModelSelector;
            const provider = selector[0..slash];
            const model_id = selector[slash + 1 ..];
            return ai.getModel(provider, model_id) orelse error.UnknownModel;
        }

        if (ai.getModel(self.session.agent.state.model.provider, selector)) |model| return model;
        var found: ?ai.Model = null;
        for (ai.getProviders()) |provider| {
            for (ai.getModels(provider)) |model| {
                if (!std.mem.eql(u8, model.id, selector)) continue;
                if (found != null) return error.AmbiguousModel;
                found = model;
            }
        }
        return found orelse error.UnknownModel;
    }

    fn setSessionThinkingLevel(self: *SessionRuntime, level: agent_mod.ThinkingLevel) !void {
        const entry = try self.session.manager.prepareThinkingLevelChangeEntry(
            @tagName(level),
            self.session.timestamp,
        );
        var entry_committed = false;
        errdefer if (!entry_committed) self.session.manager.deinitPreparedEntry(entry);
        if (self.session.store) |store| {
            try store.appendEntry(self.session.io, entry, self.session.manager.lastEntryId());
        }
        _ = self.session.manager.commitPreparedEntry(entry);
        entry_committed = true;
        try self.services.settings_manager.setDefaultThinkingLevel(self.services.io, self.host_config.dir, @tagName(level));
        self.session.agent.setThinkingLevel(level);
    }

    fn setHideThinking(self: *SessionRuntime, hidden: bool) !void {
        try self.services.settings_manager.setHideThinkingBlock(self.services.io, self.host_config.dir, hidden);
        self.session.hide_thinking = hidden;
    }

    fn setSessionModel(self: *SessionRuntime, model: ai.Model) !void {
        const entry = try self.session.manager.prepareModelChangeEntry(
            model.provider,
            model.id,
            self.session.timestamp,
        );
        var entry_committed = false;
        errdefer if (!entry_committed) self.session.manager.deinitPreparedEntry(entry);
        if (self.session.store) |store| {
            try store.appendEntry(self.session.io, entry, self.session.manager.lastEntryId());
        }
        _ = self.session.manager.commitPreparedEntry(entry);
        entry_committed = true;
        try self.services.settings_manager.setDefaultModel(self.services.io, self.host_config.dir, model.provider, model.id);
        self.session.agent.setModel(model);
        if (self.services.provider_registry.get(model.api)) |provider| {
            self.session.agent.setStream(provider.stream_simple);
        }
    }

    fn enqueueSessionPromptCommand(
        self: *SessionRuntime,
        request_id: ?client_protocol.RequestId,
        command: []const u8,
    ) !void {
        const stats = collectSessionStats(self.session.manager);
        var fallback_buffer: [session_command_message_bytes_max]u8 = undefined;
        var command_text = try client_protocol.EventText.init(self.allocator, command);
        errdefer command_text.deinit(self.allocator);
        var message_text = try client_protocol.EventText.init(
            self.allocator,
            self.formatSessionFallback(&fallback_buffer, stats),
        );
        errdefer message_text.deinit(self.allocator);
        var session_info = try client_protocol.PromptCommandSessionInfo.init(
            self.allocator,
            if (self.session.store) |store| store.file_name else null,
            self.session.manager.header.id,
            stats,
        );
        errdefer session_info.deinit(self.allocator);
        try self.enqueueEvent(.{ .request_id = request_id, .event = .{ .prompt_command = .{
            .command = command_text,
            .result = .handled,
            .message = message_text,
            .presentation = .transcript,
            .session_info = session_info,
        } } });
    }

    fn enqueuePromptCommand(
        self: *SessionRuntime,
        request_id: ?client_protocol.RequestId,
        command: []const u8,
        result: client_protocol.PromptCommand.Result,
        message: []const u8,
    ) !void {
        var command_text = try client_protocol.EventText.init(self.allocator, command);
        errdefer command_text.deinit(self.allocator);
        var message_text = try client_protocol.EventText.init(self.allocator, message);
        errdefer message_text.deinit(self.allocator);
        try self.enqueueEvent(.{ .request_id = request_id, .event = .{ .prompt_command = .{
            .command = command_text,
            .result = result,
            .message = message_text,
        } } });
    }

    fn finishOperationRejected(self: *SessionRuntime, err: anyerror) !void {
        const finished = self.takeActive().?;
        defer self.allocator.free(finished.prompt_text);
        defer client_protocol.freeSubmitImages(self.allocator, finished.prompt_images);
        try self.enqueueRejected(finished.request_id, rejectionCode(err), @errorName(err));
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
        client_protocol.freeSubmitImages(self.allocator, active.prompt_images);
        self.enqueueRejected(active.request_id, rejectionCode(err), @errorName(err)) catch |enqueue_err|
            ignoreBestEffortError(enqueue_err);
        self.enqueueEvent(.{
            .request_id = active.request_id,
            .operation_id = active.operation_id,
            .event = .{ .operation_finished = .{ .reason = .failed } },
        }) catch |enqueue_err| ignoreBestEffortError(enqueue_err);
    }

    fn buildClientSnapshot(self: *SessionRuntime) !client_protocol.Snapshot {
        return self.session.clientSnapshot(
            self.allocator,
            if (self.active) |active| active.request_id else null,
        );
    }

    fn startFileCompletionLoad(
        self: *SessionRuntime,
        request_id: ?client_protocol.RequestId,
        query: []const u8,
    ) !void {
        if (self.completion_load != null) {
            try self.setPendingFileCompletion(request_id, query);
            return;
        }

        switch (self.file_index) {
            .not_started => {
                try self.setPendingFileCompletion(request_id, query);
                try self.startFileIndexBuild(request_id, query);
            },
            .building => try self.setPendingFileCompletion(request_id, query),
            .ready => |*index| try self.startReadyFileQuery(request_id, query, index),
            .failed => |failure| {
                if (std.mem.eql(u8, failure.querySlice(), query)) {
                    try self.enqueueRejected(request_id, .exhausted, failure.message[0..failure.message_len]);
                    return;
                }
                self.file_index = .not_started;
                try self.setPendingFileCompletion(request_id, query);
                try self.startFileIndexBuild(request_id, query);
            },
        }
    }

    fn setPendingFileCompletion(
        self: *SessionRuntime,
        request_id: ?client_protocol.RequestId,
        query: []const u8,
    ) !void {
        const pending_query = try self.allocator.dupe(u8, query);
        if (self.pending_file_completion) |old| self.allocator.free(old.query);
        self.pending_file_completion = .{ .request_id = request_id, .query = pending_query };
    }

    fn startFileIndexBuild(
        self: *SessionRuntime,
        request_id: ?client_protocol.RequestId,
        query: []const u8,
    ) !void {
        std.debug.assert(self.completion_load == null);
        const cwd = try self.allocator.dupe(u8, self.services.cwd);
        errdefer self.allocator.free(cwd);
        const task = self.task_runtime.spawnBlocking(buildProjectFileIndexWorker, .{
            self.host_config.dir,
            cwd,
        }) catch |err| {
            self.file_index = .{ .failed = .init(query, @errorName(err)) };
            if (self.pending_file_completion) |pending| {
                try self.enqueueRejected(pending.request_id, rejectionCode(err), @errorName(err));
                self.allocator.free(pending.query);
                self.pending_file_completion = null;
            } else {
                try self.enqueueRejected(request_id, rejectionCode(err), @errorName(err));
            }
            self.allocator.free(cwd);
            return;
        };
        self.file_index = .building;
        self.completion_load = .{
            .kind = .file_index_build,
            .request_id = request_id,
            .task = task,
            .cwd = cwd,
        };
    }

    fn startReadyFileQuery(
        self: *SessionRuntime,
        request_id: ?client_protocol.RequestId,
        query: []const u8,
        index: *const file_completion.Index,
    ) !void {
        const owned_query = try self.allocator.dupe(u8, query);
        errdefer self.allocator.free(owned_query);
        const task = self.task_runtime.spawnBlocking(queryProjectFileCompletionWorker, .{
            index,
            owned_query,
        }) catch |err| {
            try self.enqueueRejected(request_id, rejectionCode(err), @errorName(err));
            self.allocator.free(owned_query);
            return;
        };
        self.completion_load = .{
            .kind = .file_query,
            .request_id = request_id,
            .task = task,
            .query = owned_query,
        };
    }

    fn startCompletionLoad(self: *SessionRuntime, request_id: ?client_protocol.RequestId) !void {
        if (self.completion_load != null) {
            try self.enqueueRejected(request_id, .busy, "completion snapshot already loading");
            return;
        }

        var models = self.buildModelCompletionList() catch |err| {
            try self.enqueueRejected(request_id, rejectionCode(err), @errorName(err));
            return;
        };
        errdefer models.deinit(self.allocator);

        const cwd = try self.allocator.dupe(u8, self.services.cwd);
        errdefer self.allocator.free(cwd);
        const agent_dir = try self.allocator.dupe(u8, self.services.agent_dir);
        errdefer self.allocator.free(agent_dir);
        var current_session_leaf = try self.dupeCurrentSessionLeaf();
        errdefer if (current_session_leaf) |leaf| self.allocator.free(leaf);

        const task = self.task_runtime.spawn(buildResumeCompletionListWorker, .{
            self.allocator,
            self.services.io,
            self.host_config.dir,
            self.host_config.environ,
            cwd,
            agent_dir,
            current_session_leaf,
        }) catch |err| {
            try self.enqueueRejected(request_id, rejectionCode(err), @errorName(err));
            if (current_session_leaf) |leaf| self.allocator.free(leaf);
            current_session_leaf = null;
            self.allocator.free(agent_dir);
            self.allocator.free(cwd);
            models.deinit(self.allocator);
            return;
        };

        self.completion_load = .{
            .kind = .resume_sessions,
            .request_id = request_id,
            .models = models,
            .task = task,
            .cwd = cwd,
            .agent_dir = agent_dir,
            .current_session_leaf = current_session_leaf,
        };
    }

    fn finishReadyCompletionLoad(self: *SessionRuntime) !void {
        const load = if (self.completion_load) |*completion| completion else return;
        if (!load.task.hasResult()) return;
        try self.applyCompletionLoadResult(load.task.join());
    }

    fn applyCompletionLoadResult(
        self: *SessionRuntime,
        result: anyerror!CompletionLoadResult,
    ) !void {
        try self.finishCompletionLoad(result);
    }

    fn finishCompletionLoad(self: *SessionRuntime, result: anyerror!CompletionLoadResult) !void {
        var load = self.completion_load orelse return;
        self.completion_load = null;
        defer if (load.cwd) |cwd| self.allocator.free(cwd);
        defer if (load.agent_dir) |agent_dir| self.allocator.free(agent_dir);
        defer if (load.current_session_leaf) |leaf| self.allocator.free(leaf);
        defer if (load.query) |query| self.allocator.free(query);

        const payload = result catch |err| {
            if (load.models) |*models| models.deinit(self.allocator);
            if (load.kind == .file_index_build) {
                if (self.pending_file_completion) |pending| {
                    self.file_index = .{ .failed = .init(pending.query, @errorName(err)) };
                    try self.enqueueRejected(pending.request_id, rejectionCode(err), @errorName(err));
                    self.allocator.free(pending.query);
                    self.pending_file_completion = null;
                } else {
                    self.file_index = .{ .failed = .init("", @errorName(err)) };
                    try self.enqueueRejected(load.request_id, rejectionCode(err), @errorName(err));
                }
            } else {
                try self.enqueueRejected(load.request_id, rejectionCode(err), @errorName(err));
            }
            return;
        };

        switch (payload) {
            .resume_sessions => |sessions| {
                var snapshot: client_protocol.CompletionSnapshot = .{
                    .models = load.models.?,
                    .resume_sessions = sessions,
                };
                var snapshot_owned = true;
                errdefer if (snapshot_owned) snapshot.deinit(self.allocator);
                try self.enqueueEvent(.{
                    .request_id = load.request_id,
                    .event = .{ .completion_snapshot = snapshot },
                });
                snapshot_owned = false;
            },
            .file_index_built => |index| {
                std.debug.assert(load.kind == .file_index_build);
                self.file_index = .{ .ready = index };
            },
            .file_completion => |raw| {
                defer raw.destroy(std.heap.page_allocator);
                var raw_sources: [file_completion.item_count_max]client_protocol.CompletionItem.Source = undefined;
                var event = try client_protocol.FileCompletionResult.init(
                    self.allocator,
                    raw.querySlice(),
                    raw.sources(&raw_sources),
                    raw.truncated,
                );
                var event_owned = true;
                errdefer if (event_owned) event.deinit(self.allocator);
                try self.enqueueEvent(.{
                    .request_id = load.request_id,
                    .event = .{ .file_completion = event },
                });
                event_owned = false;
            },
        }
    }

    fn startPendingFileCompletionLoad(self: *SessionRuntime) !void {
        if (self.completion_load != null) return;
        const pending = self.pending_file_completion orelse return;
        self.pending_file_completion = null;
        defer self.allocator.free(pending.query);
        try self.startFileCompletionLoad(pending.request_id, pending.query);
    }

    fn resetFileCompletionState(self: *SessionRuntime) void {
        if (self.pending_file_completion) |pending| self.allocator.free(pending.query);
        self.pending_file_completion = null;
        self.file_index.deinit();
        self.file_index = .not_started;
    }

    fn cancelCompletionLoad(self: *SessionRuntime) void {
        var load = self.completion_load orelse return;
        self.completion_load = null;
        load.task.cancel();
        const payload = load.task.join() catch null;
        if (payload) |value| {
            var owned = value;
            owned.deinit(self.allocator);
        }
        if (load.models) |*models| models.deinit(self.allocator);
        if (load.cwd) |cwd| self.allocator.free(cwd);
        if (load.agent_dir) |agent_dir| self.allocator.free(agent_dir);
        if (load.current_session_leaf) |leaf| self.allocator.free(leaf);
        if (load.query) |query| self.allocator.free(query);
    }

    const CompletionStatus = enum { ready, missing_auth, unavailable };

    fn buildModelCompletionList(self: *SessionRuntime) !client_protocol.CompletionList {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();
        var sources = std.ArrayList(client_protocol.CompletionItem.Source).empty;
        var truncated = false;

        outer: for (ai.getProviders()) |provider| {
            for (ai.getModels(provider)) |model| {
                if (sources.items.len == client_protocol.completion_item_count_max) {
                    truncated = true;
                    break :outer;
                }
                const id = try std.fmt.allocPrint(arena_allocator, "{s}/{s}", .{ model.provider, model.id });
                const status = self.modelCompletionStatus(model);
                const current = self.isCurrentModel(model);
                const detail = try modelCompletionDetail(arena_allocator, model, status, current);
                try sources.append(arena_allocator, .{ .id = id, .label = id, .detail = detail });
            }
        }

        return client_protocol.CompletionList.init(self.allocator, sources.items, truncated);
    }

    fn modelCompletionStatus(self: *const SessionRuntime, model: ai.Model) CompletionStatus {
        if (self.services.provider_registry.get(model.api) == null) return .unavailable;
        if (!self.services.auth_manager.hasAuth(model.provider)) return .missing_auth;
        return .ready;
    }

    fn isCurrentModel(self: *const SessionRuntime, model: ai.Model) bool {
        const current = self.session.agent.state.model;
        return std.mem.eql(u8, current.provider, model.provider) and std.mem.eql(u8, current.id, model.id);
    }

    fn completionStatusText(status: CompletionStatus) []const u8 {
        return switch (status) {
            .ready => "ready",
            .missing_auth => "missing auth",
            .unavailable => "unavailable",
        };
    }

    fn modelCompletionDetail(
        allocator: std.mem.Allocator,
        model: ai.Model,
        status: CompletionStatus,
        current: bool,
    ) ![]const u8 {
        var context_buffer: [24]u8 = undefined;
        var cost_buffer: [80]u8 = undefined;
        return std.fmt.allocPrint(allocator, "{s} - {s}{s}; ctx {s}; {s}", .{
            model.name,
            if (current) "current, " else "",
            completionStatusText(status),
            formatModelTokenCount(&context_buffer, model.context_window),
            formatModelCost(&cost_buffer, model.cost),
        });
    }

    fn formatModelTokenCount(buffer: []u8, tokens: u64) []const u8 {
        if (tokens >= 1_000_000 and tokens % 1_000_000 == 0) {
            return std.fmt.bufPrint(buffer, "{d}m", .{tokens / 1_000_000}) catch "?";
        }
        if (tokens >= 1_000 and tokens % 1_000 == 0) {
            return std.fmt.bufPrint(buffer, "{d}k", .{tokens / 1_000}) catch "?";
        }
        return std.fmt.bufPrint(buffer, "{d}", .{tokens}) catch "?";
    }

    fn formatModelCost(buffer: []u8, cost: ai.Model.Cost) []const u8 {
        return std.fmt.bufPrint(buffer, "${d:.2} in/${d:.2} out per 1M", .{
            cost.input,
            cost.output,
        }) catch "$? in/$? out per 1M";
    }

    fn enqueueSessionChrome(self: *SessionRuntime, request_id: ?client_protocol.RequestId) !void {
        if (!self.hasEventCapacity()) {
            self.session_chrome_dirty = true;
            return;
        }
        var chrome = try self.session.clientChromeSnapshot(self.allocator);
        errdefer chrome.deinit(self.allocator);
        try self.enqueueEvent(.{ .request_id = request_id, .event = .{ .session_chrome = chrome } });
        self.session_chrome_dirty = false;
    }

    fn drainSessionEvents(self: *SessionRuntime, request_id: ?client_protocol.RequestId) !void {
        try self.drainSessionEventsBounded(request_id, session_public_events_per_turn_max);
    }

    fn drainSessionEventsBounded(
        self: *SessionRuntime,
        request_id: ?client_protocol.RequestId,
        limit: usize,
    ) !void {
        var count: usize = 0;
        while (count < limit and self.hasEventCapacity()) : (count += 1) {
            const event = self.session.drainPublicEvent() orelse break;
            if (eventRefreshesSessionChrome(event)) self.session_chrome_dirty = true;
            try self.enqueueEvent(.{ .request_id = request_id, .event = event });
        }
        if (!self.session.publicEventsEmpty()) self.session.publicEventWake().set();
        if (self.session_chrome_dirty) try self.enqueueSessionChrome(request_id);
    }

    fn eventRefreshesSessionChrome(event: client_protocol.ClientEvent) bool {
        return switch (event) {
            .agent_event => |payload| payload.event == .message_end,
            .compaction_end => |payload| payload.result != null,
            else => false,
        };
    }

    fn rejectionCode(err: anyerror) client_protocol.Rejection.Code {
        return switch (err) {
            error.QueueFull => .queue_full,
            error.OutOfMemory => .exhausted,
            else => .invalid_command,
        };
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

    fn enqueueResumeRejected(
        self: *SessionRuntime,
        request_id: ?client_protocol.RequestId,
        session_file_name: []const u8,
        err: anyerror,
    ) !void {
        var buffer: [session_command_message_bytes_max]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "could not resume {s}: {s}", .{
            std.fs.path.basename(session_file_name),
            @errorName(err),
        }) catch "could not resume session";
        try self.enqueueRejected(request_id, rejectionCode(err), text);
    }

    fn dupeCurrentSessionLeaf(self: *SessionRuntime) !?[]u8 {
        const store = self.session.store orelse return null;
        const leaf = try self.allocator.dupe(u8, std.fs.path.basename(store.file_name));
        return leaf;
    }

    fn enqueueEvent(self: *SessionRuntime, envelope: client_protocol.EventEnvelope) std.mem.Allocator.Error!void {
        var sequenced = envelope;
        sequenced.seq = self.next_event_seq;
        self.next_event_seq += 1;
        try self.retained_events.append(sequenced);
        if (self.events.pushOrDrop(sequenced)) return;
        if (self.pending_event == null) {
            self.pending_event = sequenced;
            return;
        }
        var owned_envelope = sequenced;
        owned_envelope.deinit(self.allocator);
        return;
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

fn copyBytes(dest: []u8, source: []const u8) u16 {
    const keep = @min(dest.len, source.len);
    @memcpy(dest[0..keep], source[0..keep]);
    return @intCast(keep);
}

const CompletionLoadResult = union(enum) {
    resume_sessions: client_protocol.CompletionList,
    file_index_built: file_completion.Index,
    file_completion: *file_completion.Result,

    fn deinit(self: *CompletionLoadResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .resume_sessions => |*list| list.deinit(allocator),
            .file_index_built => |*index| index.deinit(std.heap.page_allocator),
            .file_completion => |result| result.destroy(std.heap.page_allocator),
        }
        self.* = undefined;
    }
};

fn buildResumeCompletionListWorker(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    environ: ?*const std.process.Environ.Map,
    cwd: []const u8,
    agent_dir: []const u8,
    current_session_leaf: ?[]const u8,
) anyerror!CompletionLoadResult {
    return .{ .resume_sessions = try buildResumeCompletionListFor(
        allocator,
        io,
        dir,
        environ,
        cwd,
        agent_dir,
        current_session_leaf,
    ) };
}

fn buildProjectFileIndexWorker(dir: std.Io.Dir, cwd: []const u8) anyerror!CompletionLoadResult {
    const project_fd = try std.posix.openat(dir.handle, cwd, .{
        .ACCMODE = .RDONLY,
        .DIRECTORY = true,
        .CLOEXEC = true,
    }, 0);
    defer _ = std.c.close(project_fd);
    const project_dir: std.Io.Dir = .{ .handle = project_fd };
    return .{ .file_index_built = try file_completion.Index.build(std.heap.page_allocator, project_dir) };
}

fn queryProjectFileCompletionWorker(
    index: *const file_completion.Index,
    query: []const u8,
) anyerror!CompletionLoadResult {
    return .{ .file_completion = try index.query(std.heap.page_allocator, query) };
}

fn buildResumeCompletionListFor(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    environ: ?*const std.process.Environ.Map,
    cwd: []const u8,
    agent_dir: []const u8,
    current_session_leaf: ?[]const u8,
) !client_protocol.CompletionList {
    var summaries = try session_listing.listRuntimeSessionSummaries(allocator, io, .{
        .cwd = cwd,
        .agent_dir_override = agent_dir,
        .dir = dir,
        .environ = environ,
        .max_sessions = client_protocol.completion_item_count_max,
    });
    defer summaries.deinit(allocator);

    var sources: [client_protocol.completion_item_count_max]client_protocol.CompletionItem.Source = undefined;
    var count: usize = 0;
    for (summaries.items) |summary| {
        if (current_session_leaf) |leaf| {
            if (std.mem.eql(u8, summary.file_name, leaf)) continue;
        }
        sources[count] = .{
            .id = summary.file_name,
            .label = summary.title,
            .detail = summary.detail,
            .meta = summary.meta,
            .aux = summary.aux,
        };
        count += 1;
    }
    return client_protocol.CompletionList.init(allocator, sources[0..count], summaries.truncated);
}

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

test "session runtime completion snapshot reports model status and resume sessions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var session_runtime = try initTestRuntime(&tmp, task_runtime);
    defer session_runtime.deinit();

    const current_model = ai.getModels(ai.getProviders()[0])[0];
    session_runtime.session.agent.setModel(current_model);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "agent/sessions/--repo--/2026-06-08T00:00:00Z_other.jsonl",
        .data = "{\"type\":\"session\",\"version\":3,\"id\":\"other\"," ++
            "\"timestamp\":\"2026-06-08T00:00:00Z\",\"cwd\":\"repo\"}\n",
    });

    try session_runtime.submit(.{ .id = 4, .command = .completion_snapshot });

    var event: client_protocol.EventEnvelope = event: {
        var iterations: usize = 0;
        while (iterations < 2000) : (iterations += 1) {
            try session_runtime.step();
            if (session_runtime.drainEvent()) |event| {
                if (event.event == .completion_snapshot) break :event event;
                var ignored = event;
                ignored.deinit(std.testing.allocator);
            }
            try runtime.sleep(.fromMilliseconds(1));
        }
        return error.TestUnexpectedResult;
    };
    defer event.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?client_protocol.RequestId, 4), event.request_id);
    try std.testing.expect(event.event == .completion_snapshot);
    const snapshot = event.event.completion_snapshot;
    try std.testing.expect(snapshot.models.items.len > 0);
    try std.testing.expectEqual(@as(usize, 1), snapshot.resume_sessions.items.len);
    try std.testing.expectEqualStrings(
        "2026-06-08T00:00:00Z_other.jsonl",
        snapshot.resume_sessions.items[0].id.text,
    );

    var found_missing_auth = false;
    for (snapshot.models.items) |item| {
        if (std.mem.indexOf(u8, item.detail.text, "missing auth") != null) found_missing_auth = true;
    }
    try std.testing.expect(found_missing_auth);
    var current_id_buffer: [client_protocol.completion_id_bytes_max]u8 = undefined;
    const current_id = std.fmt.bufPrint(&current_id_buffer, "{s}/{s}", .{
        current_model.provider,
        current_model.id,
    }) catch current_model.id;
    var found_current_model = false;
    for (snapshot.models.items) |item| {
        if (!std.mem.eql(u8, item.id.text, current_id)) continue;
        found_current_model = true;
        try std.testing.expect(std.mem.indexOf(u8, item.detail.text, "current") != null);
        try std.testing.expect(std.mem.indexOf(u8, item.detail.text, "ctx") != null);
        try std.testing.expect(std.mem.indexOf(u8, item.detail.text, "per 1M") != null);
    }
    try std.testing.expect(found_current_model);
}

fn waitForFileCompletionEvent(session_runtime: *SessionRuntime) !client_protocol.EventEnvelope {
    var iterations: usize = 0;
    while (iterations < 2000) : (iterations += 1) {
        try session_runtime.step();
        if (session_runtime.drainEvent()) |event| {
            if (event.event == .file_completion) return event;
            var ignored = event;
            ignored.deinit(std.testing.allocator);
        }
        try runtime.sleep(.fromMilliseconds(1));
    }
    return error.TestUnexpectedResult;
}

test "session runtime file completion lazily builds index coalesces and keeps ready index stable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var session_runtime = try initTestRuntime(&tmp, task_runtime);
    defer session_runtime.deinit();

    try tmp.dir.createDirPath(std.testing.io, "repo/src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/src/a.zig", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/src/b.zig", .data = "" });

    try session_runtime.submit(try client_protocol.CommandEnvelope.initFileCompletion(
        std.testing.allocator,
        1,
        "src/",
    ));
    try session_runtime.submit(try client_protocol.CommandEnvelope.initFileCompletion(
        std.testing.allocator,
        2,
        "src/a",
    ));

    var coalesced = try waitForFileCompletionEvent(&session_runtime);
    defer coalesced.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?client_protocol.RequestId, 2), coalesced.request_id);
    try std.testing.expectEqualStrings("src/a", coalesced.event.file_completion.query.text);
    try std.testing.expectEqual(@as(usize, 1), coalesced.event.file_completion.items.items.len);
    try std.testing.expectEqualStrings("src/a.zig", coalesced.event.file_completion.items.items[0].id.text);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/src/added.zig", .data = "" });
    try session_runtime.submit(try client_protocol.CommandEnvelope.initFileCompletion(
        std.testing.allocator,
        3,
        "added",
    ));

    var stale = try waitForFileCompletionEvent(&session_runtime);
    defer stale.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?client_protocol.RequestId, 3), stale.request_id);
    try std.testing.expectEqualStrings("added", stale.event.file_completion.query.text);
    try std.testing.expectEqual(@as(usize, 0), stale.event.file_completion.items.items.len);
}

test "model completion detail includes current marker context and costs" {
    const model: ai.Model = .{
        .id = "m",
        .name = "Model",
        .api = "api",
        .provider = "provider",
        .base_url = "",
        .reasoning = false,
        .input = &.{.text},
        .cost = .{ .input = 1.25, .output = 10, .cache_read = 0, .cache_write = 0 },
        .context_window = 128_000,
        .max_tokens = 4096,
    };
    const detail = try SessionRuntime.modelCompletionDetail(std.testing.allocator, model, .ready, true);
    defer std.testing.allocator.free(detail);
    try std.testing.expectEqualStrings(
        "Model - current, ready; ctx 128k; $1.25 in/$10.00 out per 1M",
        detail,
    );
}

test "session runtime refreshes context chrome after persisted messages" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var session_runtime = try initTestRuntime(&tmp, task_runtime);
    defer session_runtime.deinit();

    session_runtime.session.agent.setModel(.{
        .id = "model",
        .name = "Model",
        .api = "api",
        .provider = "provider",
        .base_url = "",
        .reasoning = false,
        .input = &.{.text},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 100,
        .max_tokens = 10,
    });

    _ = try session_runtime.session.agent.beginRun();
    try session_runtime.session.agent.emitEvent(.{ .message_end = .{ .message = .{ .user = .{
        .content = .{ .string = "hello world" },
        .timestamp = 0,
    } } } });
    session_runtime.session.agent.finishRun();
    try session_runtime.drainSessionEvents(7);

    var agent_event = session_runtime.drainEvent().?;
    defer agent_event.deinit(std.testing.allocator);
    try std.testing.expect(agent_event.event == .agent_event);
    var chrome_event = session_runtime.drainEvent().?;
    defer chrome_event.deinit(std.testing.allocator);
    try std.testing.expect(chrome_event.event == .session_chrome);
    try std.testing.expectEqual(@as(?client_protocol.RequestId, 7), chrome_event.request_id);
    try std.testing.expectEqual(@as(?u64, 3), chrome_event.event.session_chrome.context.tokens);
    try std.testing.expectEqual(@as(u64, 100), chrome_event.event.session_chrome.context.window);
    try std.testing.expectEqual(@as(?u32, 30), chrome_event.event.session_chrome.context.percent_tenths);
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

test "session runtime handles slash command without starting an operation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var session_runtime = try initTestRuntime(&tmp, task_runtime);
    defer session_runtime.deinit();

    var envelope = try client_protocol.CommandEnvelope.initSubmitPrompt(std.testing.allocator, 7, "/help", .auto);
    var envelope_owned = true;
    errdefer if (envelope_owned) envelope.deinit(std.testing.allocator);
    try session_runtime.submit(envelope);
    envelope_owned = false;
    try session_runtime.step();

    var event = session_runtime.drainEvent().?;
    defer event.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?client_protocol.RequestId, 7), event.request_id);
    try std.testing.expect(event.event == .prompt_command);
    try std.testing.expect(event.event.prompt_command.result == .handled);
    try std.testing.expectEqualStrings("help", event.event.prompt_command.command.text);
    try std.testing.expectEqualStrings(
        "available commands: /help, /session, /model, /resume, /new, /compact, /settings",
        event.event.prompt_command.message.text,
    );
    // No operation started, nothing queued, nothing persisted.
    try std.testing.expect(session_runtime.active == null);
    try std.testing.expect(session_runtime.drainEvent() == null);
    try std.testing.expectEqual(@as(usize, 0), session_runtime.session.manager.entries.items.len);
}

test "session runtime switches to a selected session through the mailbox" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var session_runtime = try initTestRuntime(&tmp, task_runtime);
    defer session_runtime.deinit();

    var store = try session_manager.SessionStore.create(std.testing.allocator, std.testing.io, tmp.dir, .{
        .sessions_dir = "agent/sessions/--repo--",
        .cwd = "repo",
        .session_id = "other",
        .timestamp = "2026-06-10T00:00:00Z",
    });
    defer store.deinit();

    var envelope = try client_protocol.CommandEnvelope.initSwitchSession(
        std.testing.allocator,
        9,
        "2026-06-10T00:00:00Z_other.jsonl",
    );
    var envelope_owned = true;
    errdefer if (envelope_owned) envelope.deinit(std.testing.allocator);
    try session_runtime.submit(envelope);
    envelope_owned = false;
    try session_runtime.step();

    var event = session_runtime.drainEvent().?;
    defer event.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?client_protocol.RequestId, 9), event.request_id);
    try std.testing.expect(event.event == .session_changed);
    try std.testing.expectEqual(client_protocol.SessionChanged.Reason.resumed, event.event.session_changed.reason);
    try std.testing.expectEqualStrings("other", session_runtime.session.manager.header.id);
    try std.testing.expect(session_runtime.active == null);
}

test "session runtime slash new starts a fresh session" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var session_runtime = try initTestRuntime(&tmp, task_runtime);
    defer session_runtime.deinit();

    var envelope = try client_protocol.CommandEnvelope.initSubmitPrompt(std.testing.allocator, 12, "/new", .auto);
    errdefer envelope.deinit(std.testing.allocator);
    try session_runtime.submit(envelope);
    try session_runtime.step();

    var event = session_runtime.drainEvent().?;
    defer event.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?client_protocol.RequestId, 12), event.request_id);
    try std.testing.expect(event.event == .session_changed);
    try std.testing.expectEqual(client_protocol.SessionChanged.Reason.created, event.event.session_changed.reason);
    try std.testing.expect(!std.mem.eql(u8, "session", session_runtime.session.manager.header.id));
    try std.testing.expect(std.mem.startsWith(u8, session_runtime.session.manager.header.id, "session-"));
    try std.testing.expectEqual(@as(usize, 0), session_runtime.session.manager.entries.items.len);
    try std.testing.expect(session_runtime.active == null);
}

test "session runtime keeps current session when resume file is invalid" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var session_runtime = try initTestRuntime(&tmp, task_runtime);
    defer session_runtime.deinit();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "agent/sessions/--repo--/2026-06-10T00:00:00Z_bad.jsonl",
        .data = "{\"type\":\"not-session\"}\n",
    });

    var envelope = try client_protocol.CommandEnvelope.initSwitchSession(
        std.testing.allocator,
        11,
        "2026-06-10T00:00:00Z_bad.jsonl",
    );
    var envelope_owned = true;
    errdefer if (envelope_owned) envelope.deinit(std.testing.allocator);
    try session_runtime.submit(envelope);
    envelope_owned = false;
    try session_runtime.step();

    var event = session_runtime.drainEvent().?;
    defer event.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?client_protocol.RequestId, 11), event.request_id);
    try std.testing.expect(event.event == .rejected);
    try std.testing.expectEqualStrings("session", session_runtime.session.manager.header.id);
    try std.testing.expect(std.mem.indexOf(
        u8,
        event.event.rejected.message.text,
        "could not resume 2026-06-10T00:00:00Z_bad.jsonl",
    ) != null);
}

test "session runtime keeps owned task runtime across session switch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    var session_runtime = try openSessionRuntime(std.testing.allocator, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .current_date = "2026-06-09",
        .open = .{ .create = .{ .session_id = "session", .timestamp = "2026-06-09T00:00:00Z" } },
        .dir = tmp.dir,
    });
    defer session_runtime.deinit();
    const host_runtime = session_runtime.task_runtime;
    try std.testing.expectEqual(TaskRuntimeOwner.owned, session_runtime.task_runtime_owner);
    try std.testing.expect(session_runtime.services.task_runtime == host_runtime);

    var store = try session_manager.SessionStore.create(std.testing.allocator, std.testing.io, tmp.dir, .{
        .sessions_dir = "agent/sessions/--repo--",
        .cwd = "repo",
        .session_id = "other",
        .timestamp = "2026-06-10T00:00:00Z",
    });
    defer store.deinit();

    var envelope = try client_protocol.CommandEnvelope.initSwitchSession(
        std.testing.allocator,
        10,
        "2026-06-10T00:00:00Z_other.jsonl",
    );
    var envelope_owned = true;
    errdefer if (envelope_owned) envelope.deinit(std.testing.allocator);
    try session_runtime.submit(envelope);
    envelope_owned = false;
    try session_runtime.step();

    var event = session_runtime.drainEvent().?;
    defer event.deinit(std.testing.allocator);
    try std.testing.expect(event.event == .session_changed);
    try std.testing.expectEqual(client_protocol.SessionChanged.Reason.resumed, event.event.session_changed.reason);
    try std.testing.expect(session_runtime.task_runtime == host_runtime);
    try std.testing.expect(session_runtime.services.task_runtime == host_runtime);
}

test "session runtime session command reports session facts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var session_runtime = try initTestRuntime(&tmp, task_runtime);
    defer session_runtime.deinit();

    var envelope = try client_protocol.CommandEnvelope.initSubmitPrompt(std.testing.allocator, 8, "/session", .auto);
    errdefer envelope.deinit(std.testing.allocator);
    try session_runtime.submit(envelope);
    try session_runtime.step();

    var event = session_runtime.drainEvent().?;
    defer event.deinit(std.testing.allocator);
    try std.testing.expect(event.event == .prompt_command);
    try std.testing.expect(event.event.prompt_command.result == .handled);
    try std.testing.expectEqual(
        client_protocol.PromptCommand.Presentation.transcript,
        event.event.prompt_command.presentation,
    );
    const info = event.event.prompt_command.session_info.?;
    try std.testing.expect(info.file != null);
    try std.testing.expect(std.mem.indexOf(u8, info.file.?.text, "agent/sessions/--repo--/") != null);
    try std.testing.expectEqualStrings("session", info.id.text);
    try std.testing.expectEqual(@as(usize, 0), info.total_messages);
    try std.testing.expectEqual(@as(u64, 0), info.total_tokens);
    try std.testing.expect(std.mem.indexOf(u8, event.event.prompt_command.message.text, "session: session") != null);
}

test "session runtime model command selects an authenticated model" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("OPENAI_API_KEY", "test-key");
    var session_runtime = try openSessionRuntime(std.testing.allocator, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .current_date = "2026-06-09",
        .open = .{ .create = .{ .session_id = "session", .timestamp = "2026-06-09T00:00:00Z" } },
        .dir = tmp.dir,
        .environ = &environ,
        .task_runtime = task_runtime,
    });
    defer session_runtime.deinit();

    var envelope = try client_protocol.CommandEnvelope.initSubmitPrompt(
        std.testing.allocator,
        10,
        "/model openai/gpt-5.1",
        .auto,
    );
    errdefer envelope.deinit(std.testing.allocator);
    try session_runtime.submit(envelope);
    try session_runtime.step();

    var event = session_runtime.drainEvent().?;
    defer event.deinit(std.testing.allocator);
    try std.testing.expect(event.event == .prompt_command);
    try std.testing.expect(event.event.prompt_command.result == .handled);
    try std.testing.expectEqualStrings("model", event.event.prompt_command.command.text);
    try std.testing.expectEqualStrings("openai", session_runtime.session.agent.state.model.provider);
    try std.testing.expectEqualStrings("gpt-5.1", session_runtime.session.agent.state.model.id);
    try std.testing.expect(session_runtime.session.manager.entries.items[0] == .model_change);
    try std.testing.expectEqualStrings(
        "openai",
        session_runtime.session.manager.entries.items[0].model_change.provider,
    );
    try std.testing.expectEqualStrings(
        "gpt-5.1",
        session_runtime.session.manager.entries.items[0].model_change.model_id,
    );
    var loaded = try session_runtime.session.store.?.load(std.testing.io);
    defer loaded.deinit();
    try std.testing.expect(loaded.entries.items[0] == .model_change);
    try std.testing.expectEqualStrings("gpt-5.1", loaded.sessionPreferences().model.?.model_id);
    try std.testing.expect(session_runtime.active == null);
}

test "session runtime switch restores persisted session model" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("OPENAI_API_KEY", "test-key");

    var session_runtime = try openSessionRuntime(std.testing.allocator, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .current_date = "2026-06-09",
        .open = .{ .create = .{ .session_id = "session", .timestamp = "2026-06-09T00:00:00Z" } },
        .dir = tmp.dir,
        .environ = &environ,
        .task_runtime = task_runtime,
    });
    defer session_runtime.deinit();

    var store = try session_manager.SessionStore.create(std.testing.allocator, std.testing.io, tmp.dir, .{
        .sessions_dir = "agent/sessions/--repo--",
        .cwd = "repo",
        .session_id = "other",
        .timestamp = "2026-06-10T00:00:00Z",
    });
    defer store.deinit();
    var manager = try session_manager.SessionManager.init(
        std.testing.allocator,
        "repo",
        "other",
        "2026-06-10T00:00:00Z",
    );
    defer manager.deinit();
    const model_entry = try manager.prepareModelChangeEntry("openai", "gpt-5.1", "t1");
    var model_entry_committed = false;
    errdefer if (!model_entry_committed) manager.deinitPreparedEntry(model_entry);
    try store.appendEntry(std.testing.io, model_entry, null);
    const model_entry_id = manager.commitPreparedEntry(model_entry);
    model_entry_committed = true;
    const thinking_entry = try manager.prepareThinkingLevelChangeEntry("high", "t2");
    var thinking_entry_committed = false;
    errdefer if (!thinking_entry_committed) manager.deinitPreparedEntry(thinking_entry);
    try store.appendEntry(std.testing.io, thinking_entry, model_entry_id);
    _ = manager.commitPreparedEntry(thinking_entry);
    thinking_entry_committed = true;

    var envelope = try client_protocol.CommandEnvelope.initSwitchSession(
        std.testing.allocator,
        12,
        "2026-06-10T00:00:00Z_other.jsonl",
    );
    var envelope_owned = true;
    errdefer if (envelope_owned) envelope.deinit(std.testing.allocator);
    try session_runtime.submit(envelope);
    envelope_owned = false;
    try session_runtime.step();

    var event = session_runtime.drainEvent().?;
    defer event.deinit(std.testing.allocator);
    try std.testing.expect(event.event == .session_changed);
    try std.testing.expectEqual(client_protocol.SessionChanged.Reason.resumed, event.event.session_changed.reason);
    try std.testing.expectEqualStrings("openai", session_runtime.session.agent.state.model.provider);
    try std.testing.expectEqualStrings("gpt-5.1", session_runtime.session.agent.state.model.id);
    try std.testing.expectEqual(agent_mod.ThinkingLevel.high, session_runtime.session.agent.state.thinking_level);
}

test "session runtime model command rejects missing auth" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var session_runtime = try initTestRuntime(&tmp, task_runtime);
    defer session_runtime.deinit();

    var envelope = try client_protocol.CommandEnvelope.initSubmitPrompt(
        std.testing.allocator,
        11,
        "/model openai/gpt-5.1",
        .auto,
    );
    errdefer envelope.deinit(std.testing.allocator);
    try session_runtime.submit(envelope);
    try session_runtime.step();

    var event = session_runtime.drainEvent().?;
    defer event.deinit(std.testing.allocator);
    try std.testing.expect(event.event == .prompt_command);
    try std.testing.expect(event.event.prompt_command.result == .failed);
    try std.testing.expect(std.mem.indexOf(u8, event.event.prompt_command.message.text, "missing auth") != null);
    try std.testing.expect(session_runtime.active == null);
}

test "session runtime model command does not mutate while active" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("OPENAI_API_KEY", "test-key");
    var session_runtime = try openSessionRuntime(std.testing.allocator, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .current_date = "2026-06-09",
        .open = .{ .create = .{ .session_id = "session", .timestamp = "2026-06-09T00:00:00Z" } },
        .dir = tmp.dir,
        .environ = &environ,
        .task_runtime = task_runtime,
    });
    defer session_runtime.deinit();
    const old_model = session_runtime.session.agent.state.model;
    session_runtime.active = .{
        .phase = .{ .retry_wait = .{ .kind = .resubmit_prompt, .resume_at_ns = std.math.maxInt(i96) } },
        .request_id = 1,
        .operation_id = 1,
        .prompt_text = try session_runtime.allocator.dupe(u8, "original"),
        .prompt_images = &.{},
        .overflow_count_before = 0,
    };

    var envelope = try client_protocol.CommandEnvelope.initSubmitPrompt(
        std.testing.allocator,
        12,
        "/model openai/gpt-5.1",
        .auto,
    );
    errdefer envelope.deinit(std.testing.allocator);
    try session_runtime.submit(envelope);
    try session_runtime.step();

    var event = session_runtime.drainEvent().?;
    defer event.deinit(std.testing.allocator);
    try std.testing.expect(event.event == .prompt_command);
    try std.testing.expect(event.event.prompt_command.result == .failed);
    try std.testing.expect(std.mem.indexOf(u8, event.event.prompt_command.message.text, "active operation") != null);
    try std.testing.expectEqualStrings(old_model.provider, session_runtime.session.agent.state.model.provider);
    try std.testing.expectEqualStrings(old_model.id, session_runtime.session.agent.state.model.id);
    try std.testing.expectEqual(@as(usize, 0), session_runtime.session.manager.entries.items.len);
    try std.testing.expect(session_runtime.active != null);
    try std.testing.expect(session_runtime.drainEvent() == null);
}

test "session runtime replies unknown for unrecognized slash command" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var session_runtime = try initTestRuntime(&tmp, task_runtime);
    defer session_runtime.deinit();

    var envelope = try client_protocol.CommandEnvelope.initSubmitPrompt(
        std.testing.allocator,
        9,
        "/mystery now",
        .auto,
    );
    errdefer envelope.deinit(std.testing.allocator);
    try session_runtime.submit(envelope);
    try session_runtime.step();

    var event = session_runtime.drainEvent().?;
    defer event.deinit(std.testing.allocator);
    try std.testing.expect(event.event == .prompt_command);
    try std.testing.expect(event.event.prompt_command.result == .unknown);
    try std.testing.expectEqualStrings("mystery", event.event.prompt_command.command.text);
    try std.testing.expectEqualStrings("unknown command: /mystery", event.event.prompt_command.message.text);
    try std.testing.expect(session_runtime.active == null);
}

test "session runtime slash command never queues while an operation is active" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var session_runtime = try initTestRuntime(&tmp, task_runtime);
    defer session_runtime.deinit();

    // Simulate an in-flight operation with a parked retry phase; a slash
    // command must reply as a fact, not steer or enqueue.
    session_runtime.active = .{
        .phase = .{ .retry_wait = .{ .kind = .resubmit_prompt, .resume_at_ns = std.math.maxInt(i96) } },
        .request_id = 1,
        .operation_id = 1,
        .prompt_text = try std.testing.allocator.dupe(u8, "original"),
        .prompt_images = &.{},
        .overflow_count_before = 0,
    };

    var envelope = try client_protocol.CommandEnvelope.initSubmitPrompt(std.testing.allocator, 2, "/help", .auto);
    errdefer envelope.deinit(std.testing.allocator);
    try session_runtime.submit(envelope);
    try session_runtime.step();

    var event = session_runtime.drainEvent().?;
    defer event.deinit(std.testing.allocator);
    try std.testing.expect(event.event == .prompt_command);
    try std.testing.expectEqual(@as(usize, 0), session_runtime.session.agent.steering_queue.count());
    try std.testing.expectEqual(@as(usize, 0), session_runtime.session.agent.follow_up_queue.count());
}

test "slash command requires a name; bare or spaced slash is a prompt" {
    try std.testing.expectEqual(@as(?[]const u8, null), SessionRuntime.parseSlashCommand("/"));
    try std.testing.expectEqual(@as(?[]const u8, null), SessionRuntime.parseSlashCommand("/ help"));
    try std.testing.expectEqual(@as(?[]const u8, null), SessionRuntime.parseSlashCommand("help"));
    try std.testing.expectEqualStrings("help", SessionRuntime.parseSlashCommand("/help extra").?);
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
    try std.testing.expectEqual(agent_mod.ThinkingLevel.off, event.event.snapshot.thinking_level);
    try std.testing.expectEqual(@as(u64, 0), event.event.snapshot.context.window);
    try std.testing.expectEqual(@as(?u64, null), event.event.snapshot.context.tokens);
    try std.testing.expectEqual(
        @as(?client_protocol.RequestId, null),
        event.event.snapshot.active_request_id,
    );
    try std.testing.expectEqual(@as(usize, 0), event.event.snapshot.history.items.len);
}

test "session runtime history page command emits entries before cursor" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var session_runtime = try initTestRuntime(&tmp, task_runtime);
    defer session_runtime.deinit();

    const first = try session_runtime.session.manager.prepareMessageEntry(.{
        .user = .{ .content = .{ .string = "one" }, .timestamp = 0 },
    }, "t1");
    _ = session_runtime.session.manager.commitPreparedEntry(first);
    const second = try session_runtime.session.manager.prepareMessageEntry(.{
        .user = .{ .content = .{ .string = "two" }, .timestamp = 0 },
    }, "t2");
    const before = session_runtime.session.manager.commitPreparedEntry(second);

    var request = try client_protocol.CommandEnvelope.initHistoryPage(std.testing.allocator, 10, before);
    var request_owned = true;
    defer if (request_owned) request.deinit(std.testing.allocator);
    try session_runtime.submit(request);
    request_owned = false;
    try session_runtime.step();

    var event = session_runtime.drainEvent().?;
    defer event.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?client_protocol.RequestId, 10), event.request_id);
    try std.testing.expect(event.event == .history_page);
    try std.testing.expectEqual(@as(usize, 1), event.event.history_page.items.len);
    try std.testing.expectEqualStrings("one", event.event.history_page.items[0].text.text);
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
    var non_compaction_call_count: usize = 0;
    var fail_calls: usize = 1;
    var error_text: []const u8 = "rate limit exceeded";
    var success_usage_total_tokens: u64 = 0;
    var last_prompt_buffer: [4096]u8 = undefined;
    var last_prompt: []const u8 = "";

    fn reset(fails: usize) void {
        call_count = 0;
        non_compaction_call_count = 0;
        fail_calls = fails;
        error_text = "rate limit exceeded";
        success_usage_total_tokens = 0;
        last_prompt = "";
    }

    fn stream(_: ?*anyopaque, request: ai.StreamRequest) ai.AssistantMessageEventStream {
        call_count += 1;
        var is_compaction_request = false;
        for (request.context.messages) |message| {
            if (message != .user) continue;
            const text = switch (message.user.content) {
                .string => |value| value,
                .blocks => "",
            };
            if (text.len == 0) continue;
            const copied_len = @min(text.len, last_prompt_buffer.len);
            @memcpy(last_prompt_buffer[0..copied_len], text[0..copied_len]);
            last_prompt = last_prompt_buffer[0..copied_len];
            if (std.mem.indexOf(u8, text, "conversation history to compact") != null) {
                is_compaction_request = true;
            }
        }
        if (!is_compaction_request) non_compaction_call_count += 1;
        var assistant_stream = ai.AssistantMessageEventStream.initBuffered();
        const sink = assistant_stream.sink();
        if (!is_compaction_request and non_compaction_call_count <= fail_calls) {
            var message = ai.protocol.emptyAssistantMessageFromRequest(request, .error_, error_text);
            message.operational_failure = .{
                .category = if (std.ascii.indexOfIgnoreCase(error_text, "context") != null)
                    .context_overflow
                else if (std.ascii.indexOfIgnoreCase(error_text, "rate") != null)
                    .rate_limited
                else
                    .unknown,
                .message = error_text,
                .detail = error_text,
                .retryable = .yes,
                .provider = request.model.provider,
                .model = request.model.id,
            };
            sink.endError(
                request.io,
                .error_,
                message,
            ) catch std.debug.assert(false);
        } else {
            var usage = ai.protocol.emptyUsage();
            usage.total_tokens = success_usage_total_tokens;
            sink.endDone(request.io, .stop, .{
                .content = &.{.{ .text = .{ .text = "recovered" } }},
                .api = request.model.api,
                .provider = request.model.provider,
                .model = request.model.id,
                .usage = usage,
                .stop_reason = .stop,
                .timestamp = 0,
            }) catch std.debug.assert(false);
        }
        return assistant_stream;
    }
};

test "session runtime streams multi-block deltas through the live owner loop" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/.zi");

    var provider = try ai.FauxProvider.init(std.testing.allocator, .{});
    defer provider.deinit();
    const reply_content = [_]ai.AssistantContent{
        .{ .thinking = .{ .thinking = "let me think about this" } },
        .{ .text = .{ .text = "here is the answer" } },
    };
    const replies = [_]ai.AssistantMessage{
        ai.faux.assistantMessage(&reply_content, .{ .stop_reason = .stop }),
    };
    try provider.setResponses(&replies);

    var session_runtime = try openSessionRuntime(std.testing.allocator, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .current_date = "2026-06-09",
        .open = .{ .create = .{ .session_id = "session", .timestamp = "2026-06-09T00:00:00Z" } },
        .dir = tmp.dir,
        .task_runtime = task_runtime,
        .model = provider.getModel(),
        .stream = provider.apiProvider().stream,
    });
    defer session_runtime.deinit();

    var prompt = try client_protocol.CommandEnvelope.initSubmitPrompt(std.testing.allocator, 1, "hello", .auto);
    var prompt_owned = true;
    defer if (prompt_owned) prompt.deinit(std.testing.allocator);
    try session_runtime.submit(prompt);
    prompt_owned = false;

    const outcome = try driveUntilOperationFinished(&session_runtime);
    try std.testing.expectEqual(client_protocol.OperationFinished.Reason.completed, outcome.reason);
    try std.testing.expect(session_runtime.active == null);
}

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
    compaction_start_count: usize = 0,
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
                .compaction_start => {
                    outcome.saw_compaction_start = true;
                    outcome.compaction_start_count += 1;
                },
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

test "session runtime does not threshold compact below reserve" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    FlakyStream.reset(0);
    FlakyStream.success_usage_total_tokens = 100;
    var session_runtime = try initRetryTestRuntime(
        &tmp,
        task_runtime,
        "{\"compaction\":{\"enabled\":true,\"keepRecentTokens\":1,\"reserveTokens\":1000}}",
    );
    defer session_runtime.deinit();

    var first_prompt = try client_protocol.CommandEnvelope.initSubmitPrompt(std.testing.allocator, 1, "hello", .auto);
    var first_owned = true;
    defer if (first_owned) first_prompt.deinit(std.testing.allocator);
    try session_runtime.submit(first_prompt);
    first_owned = false;
    const first = try driveUntilOperationFinished(&session_runtime);
    try std.testing.expectEqual(client_protocol.OperationFinished.Reason.completed, first.reason);
    try std.testing.expect(!first.saw_compaction_start);

    var second_prompt = try client_protocol.CommandEnvelope.initSubmitPrompt(std.testing.allocator, 2, "again", .auto);
    var second_owned = true;
    defer if (second_owned) second_prompt.deinit(std.testing.allocator);
    try session_runtime.submit(second_prompt);
    second_owned = false;
    const second = try driveUntilOperationFinished(&session_runtime);
    try std.testing.expectEqual(client_protocol.OperationFinished.Reason.completed, second.reason);
    try std.testing.expect(!second.saw_compaction_start);
    try std.testing.expectEqual(@as(usize, 2), FlakyStream.call_count);
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
        "{\"compaction\":{\"enabled\":true,\"keepRecentTokens\":1,\"reserveTokens\":1000000}}",
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

test "session runtime manual compact slash command starts compaction operation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    FlakyStream.reset(0);
    FlakyStream.success_usage_total_tokens = 100;
    var session_runtime = try initRetryTestRuntime(
        &tmp,
        task_runtime,
        "{\"compaction\":{\"enabled\":false,\"keepRecentTokens\":1}}",
    );
    defer session_runtime.deinit();

    var prompt = try client_protocol.CommandEnvelope.initSubmitPrompt(std.testing.allocator, 1, "hello", .auto);
    var prompt_owned = true;
    defer if (prompt_owned) prompt.deinit(std.testing.allocator);
    try session_runtime.submit(prompt);
    prompt_owned = false;
    _ = try driveUntilOperationFinished(&session_runtime);

    var compact = try client_protocol.CommandEnvelope.initSubmitPrompt(
        std.testing.allocator,
        2,
        "/compact focus on files",
        .auto,
    );
    var compact_owned = true;
    defer if (compact_owned) compact.deinit(std.testing.allocator);
    try session_runtime.submit(compact);
    compact_owned = false;
    const compact_outcome = try driveUntilOperationFinished(&session_runtime);

    try std.testing.expectEqual(client_protocol.OperationFinished.Reason.completed, compact_outcome.reason);
    try std.testing.expect(compact_outcome.saw_compaction_start);
    try std.testing.expect(compact_outcome.saw_compaction_end_result);
    try std.testing.expectEqual(@as(usize, 2), FlakyStream.call_count);
    try std.testing.expect(std.mem.indexOf(u8, FlakyStream.last_prompt, "Additional focus: focus on files") != null);
    try std.testing.expect(session_runtime.session.manager.entries.items[2] == .compaction);
}

test "session runtime manual compact reports nothing to compact" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    FlakyStream.reset(0);
    var session_runtime = try initRetryTestRuntime(
        &tmp,
        task_runtime,
        "{\"compaction\":{\"enabled\":false}}",
    );
    defer session_runtime.deinit();

    var compact = try client_protocol.CommandEnvelope.initSubmitPrompt(std.testing.allocator, 1, "/compact", .auto);
    var compact_owned = true;
    defer if (compact_owned) compact.deinit(std.testing.allocator);
    try session_runtime.submit(compact);
    compact_owned = false;
    try session_runtime.step();

    var event = session_runtime.drainEvent().?;
    defer event.deinit(std.testing.allocator);
    try std.testing.expect(event.event == .prompt_command);
    try std.testing.expect(event.event.prompt_command.result == .failed);
    try std.testing.expectEqualStrings("compact", event.event.prompt_command.command.text);
    try std.testing.expectEqualStrings("nothing to compact", event.event.prompt_command.message.text);
    try std.testing.expect(session_runtime.active == null);
}

test "session runtime manual compact rejects while active" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    FlakyStream.reset(0);
    var session_runtime = try initRetryTestRuntime(
        &tmp,
        task_runtime,
        "{\"compaction\":{\"enabled\":false}}",
    );
    defer session_runtime.deinit();

    var prompt = try client_protocol.CommandEnvelope.initSubmitPrompt(std.testing.allocator, 1, "hello", .auto);
    var prompt_owned = true;
    defer if (prompt_owned) prompt.deinit(std.testing.allocator);
    try session_runtime.submit(prompt);
    prompt_owned = false;
    try session_runtime.step();
    try std.testing.expect(session_runtime.active != null);
    while (session_runtime.drainEvent()) |event| {
        var owned = event;
        owned.deinit(std.testing.allocator);
    }

    var compact = try client_protocol.CommandEnvelope.initSubmitPrompt(std.testing.allocator, 2, "/compact", .auto);
    var compact_owned = true;
    defer if (compact_owned) compact.deinit(std.testing.allocator);
    try session_runtime.submit(compact);
    compact_owned = false;
    try session_runtime.step();

    var event = session_runtime.drainEvent().?;
    defer event.deinit(std.testing.allocator);
    try std.testing.expect(event.event == .prompt_command);
    try std.testing.expect(event.event.prompt_command.result == .failed);
    try std.testing.expectEqualStrings(
        "cancel active operation before compaction",
        event.event.prompt_command.message.text,
    );
}

test "session runtime does not retrigger threshold from kept pre-compaction usage" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    FlakyStream.reset(0);
    FlakyStream.success_usage_total_tokens = 127500;
    var session_runtime = try initRetryTestRuntime(
        &tmp,
        task_runtime,
        "{\"compaction\":{\"enabled\":true,\"keepRecentTokens\":1000,\"reserveTokens\":1000}}",
    );
    defer session_runtime.deinit();

    var first_prompt = try client_protocol.CommandEnvelope.initSubmitPrompt(std.testing.allocator, 1, "hello", .auto);
    var first_owned = true;
    defer if (first_owned) first_prompt.deinit(std.testing.allocator);
    try session_runtime.submit(first_prompt);
    first_owned = false;
    _ = try driveUntilOperationFinished(&session_runtime);

    try std.testing.expect(session_runtime.session.shouldRunThresholdCompaction());
    const first_kept_entry_id = session_runtime.session.manager.entries.items[0].id();
    const compaction = try session_runtime.session.manager.prepareCompactionEntry(
        "summary",
        first_kept_entry_id,
        127500,
        "2026-06-09T00:00:00Z",
    );
    _ = session_runtime.session.manager.commitPreparedEntry(compaction);
    try std.testing.expect(!session_runtime.session.shouldRunThresholdCompaction());

    FlakyStream.success_usage_total_tokens = 0;
    var third_prompt = try client_protocol.CommandEnvelope.initSubmitPrompt(
        std.testing.allocator,
        3,
        "after compact",
        .auto,
    );
    var third_owned = true;
    defer if (third_owned) third_prompt.deinit(std.testing.allocator);
    try session_runtime.submit(third_prompt);
    third_owned = false;
    const third = try driveUntilOperationFinished(&session_runtime);
    try std.testing.expect(!third.saw_compaction_start);
    try std.testing.expectEqual(@as(usize, 2), FlakyStream.call_count);
}

test "session runtime overflow compaction retries once" {
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

    var seed = try client_protocol.CommandEnvelope.initSubmitPrompt(std.testing.allocator, 1, "seed", .auto);
    var seed_owned = true;
    defer if (seed_owned) seed.deinit(std.testing.allocator);
    try session_runtime.submit(seed);
    seed_owned = false;
    _ = try driveUntilOperationFinished(&session_runtime);

    FlakyStream.reset(2);
    FlakyStream.error_text = "maximum context length exceeded";
    var prompt = try client_protocol.CommandEnvelope.initSubmitPrompt(std.testing.allocator, 2, "hello", .auto);
    var prompt_owned = true;
    defer if (prompt_owned) prompt.deinit(std.testing.allocator);
    try session_runtime.submit(prompt);
    prompt_owned = false;
    const outcome = try driveUntilOperationFinished(&session_runtime);

    try std.testing.expectEqual(client_protocol.OperationFinished.Reason.failed, outcome.reason);
    try std.testing.expectEqual(@as(usize, 1), outcome.compaction_start_count);
    try std.testing.expectEqual(@as(usize, 3), FlakyStream.call_count);
    try std.testing.expect(session_runtime.active == null);
}

test "pending event owns failed operation failure when event queue is full" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/.zi");
    FlakyStream.reset(1);
    var session_runtime = try openSessionRuntime(std.testing.allocator, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .current_date = "2026-06-09",
        .open = .{ .create = .{ .session_id = "session", .timestamp = "2026-06-09T00:00:00Z" } },
        .dir = tmp.dir,
        .task_runtime = task_runtime,
        .model = testModel(),
        .stream = .{ .call_fn = FlakyStream.stream },
        .event_capacity = 1,
    });
    defer session_runtime.deinit();

    try session_runtime.enqueueEvent(.{ .event = .operation_started });
    var failure = try client_protocol.OperationalFailure.init(std.testing.allocator, .{
        .category = .rate_limited,
        .message = "rate limit exceeded",
        .retryable = .yes,
        .provider = "openai",
        .model = "gpt",
    });
    var failure_needs_deinit = true;
    errdefer if (failure_needs_deinit) failure.deinit(std.testing.allocator);
    try session_runtime.enqueueEvent(.{ .event = .{ .operation_finished = .{
        .reason = .failed,
        .failure = failure,
    } } });
    failure_needs_deinit = false;
    try std.testing.expect(session_runtime.pending_event != null);

    var dropped_failure = try client_protocol.OperationalFailure.init(std.testing.allocator, .{
        .category = .provider_unavailable,
        .message = "provider unavailable",
        .retryable = .yes,
        .provider = "openai",
        .model = "gpt",
    });
    var dropped_failure_needs_deinit = true;
    errdefer if (dropped_failure_needs_deinit) dropped_failure.deinit(std.testing.allocator);
    try session_runtime.enqueueEvent(.{ .event = .{ .operation_finished = .{
        .reason = .failed,
        .failure = dropped_failure,
    } } });
    dropped_failure_needs_deinit = false;

    if (session_runtime.drainEvent()) |event| {
        var owned = event;
        defer owned.deinit(std.testing.allocator);
        try std.testing.expect(owned.event == .operation_started);
    } else return error.MissingOperationStarted;
    try std.testing.expect(session_runtime.flushPendingEvent());

    var saw_failure = false;
    while (session_runtime.drainEvent()) |event| {
        var owned = event;
        defer owned.deinit(std.testing.allocator);
        if (owned.event == .operation_finished) {
            try std.testing.expectEqual(client_protocol.OperationFinished.Reason.failed, owned.event.operation_finished.reason);
            try std.testing.expectEqual(client_protocol.OperationalFailure.Category.rate_limited, owned.event.operation_finished.failure.?.category);
            saw_failure = true;
        }
    }
    try std.testing.expect(saw_failure);
}

test "session runtime snapshot preserves latest terminal failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    FlakyStream.reset(1);
    var session_runtime = try initRetryTestRuntime(
        &tmp,
        task_runtime,
        "{\"retry\":{\"enabled\":false}}",
    );
    defer session_runtime.deinit();

    var prompt = try client_protocol.CommandEnvelope.initSubmitPrompt(std.testing.allocator, 1, "hello", .auto);
    var prompt_owned = true;
    defer if (prompt_owned) prompt.deinit(std.testing.allocator);
    try session_runtime.submit(prompt);
    prompt_owned = false;
    const outcome = try driveUntilOperationFinished(&session_runtime);
    try std.testing.expectEqual(client_protocol.OperationFinished.Reason.failed, outcome.reason);

    try session_runtime.submit(.{ .id = 2, .command = .{ .replay = .{ .after = 0 } } });
    try session_runtime.step();
    var saw_replay_failure = false;
    while (session_runtime.drainEvent()) |event| {
        var owned = event;
        defer owned.deinit(std.testing.allocator);
        if (owned.event != .replay) continue;
        for (owned.event.replay.events) |retained| {
            if (std.mem.indexOf(u8, retained.json.text, "\"operation_finished\"") == null) continue;
            if (std.mem.indexOf(u8, retained.json.text, "\"failure\"") == null) continue;
            if (std.mem.indexOf(u8, retained.json.text, "\"rateLimited\"") == null) continue;
            saw_replay_failure = true;
        }
    }
    try std.testing.expect(saw_replay_failure);

    try session_runtime.submit(.{ .id = 3, .command = .snapshot });
    try session_runtime.step();
    var saw_snapshot_failure = false;
    while (session_runtime.drainEvent()) |event| {
        var owned = event;
        defer owned.deinit(std.testing.allocator);
        if (owned.event != .snapshot) continue;
        const failure = owned.event.snapshot.latest_failure orelse continue;
        try std.testing.expectEqual(client_protocol.OperationalFailure.Category.rate_limited, failure.category);
        try std.testing.expectEqualStrings("rate limit exceeded", failure.message.text);
        saw_snapshot_failure = true;
    }
    try std.testing.expect(saw_snapshot_failure);
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
                if (payload.reason == .canceled) {
                    found_canceled = true;
                    try std.testing.expectEqual(client_protocol.OperationalFailure.Category.canceled, payload.failure.?.category);
                }
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
