const std = @import("std");
const ai = @import("../../ai/root.zig");
const agent = @import("../../agent/root.zig");
const agent_session_mod = @import("../AgentSession.zig");
const AgentSession = agent_session_mod.AgentSession;
const Credentials = @import("../Credentials.zig");
const AuthOperation = Credentials.AuthOperation;
const CredentialStore = Credentials.Store;
const Runtime = @import("../Runtime.zig");
const ReopenInputs = Runtime.ReopenInputs;
const RuntimeServices = Runtime.Services;
const SessionFormat = @import("../SessionFormat.zig");
const SessionPolicy = @import("SessionPolicy.zig");
const SlashCommands = @import("SlashCommands.zig");
const session_event = agent_session_mod;
const SettingsStore = @import("../SettingsStore.zig");
const TurnWorker = @import("../TurnWorker.zig");
const ZiPaths = @import("../ZiPaths.zig");

const Session = @import("../Session.zig");
pub const SessionTranscript = Session.Transcript;
pub const Event = session_event.Event;
pub const Limits = SessionPolicy.Limits;
pub const default_limits: Limits = SessionPolicy.default_limits;

pub const SlashCommandSpec = SlashCommands.Spec;

pub fn slashCommandCompletionPrefix(input: []const u8, cursor: usize) ?[]const u8 {
    return SlashCommands.completionPrefix(input, cursor);
}

pub fn slashCommandCompletionCount(prefix: []const u8) usize {
    return SlashCommands.completionCount(prefix);
}

pub fn slashCommandCompletionAt(prefix: []const u8, index: usize) ?*const SlashCommandSpec {
    return SlashCommands.completionAt(prefix, index);
}

// Frontend contract -------------------------------------------------------

pub const ExitCause = enum {
    requested,
    input_closed,
};

/// Borrowed process and coding-agent values for one synchronous frontend run.
/// The launch owner keeps the host, transcript, prompts, files, and writer
/// alive until `runFn` returns.
pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    host: *InteractiveSessionHost,
    transcript: *const SessionTranscript,
    initial_prompts: []const []const u8,
    input: std.Io.File,
    output: std.Io.File,
    writer: *std.Io.Writer,
};

/// One concrete interactive client selected by the composition root.
pub const Frontend = struct {
    context: ?*anyopaque = null,
    runFn: *const fn (?*anyopaque, Context) anyerror!ExitCause,

    pub fn run(self: Frontend, run_context: Context) !ExitCause {
        return self.runFn(self.context, run_context);
    }
};

// Session host ------------------------------------------------------------

pub const InteractiveSessionHost = struct {
    const max_identifier_bytes = SlashCommands.max_identifier_bytes;

    pub const Options = struct {
        worker_limits: TurnWorker.Limits = .{},
        policy_limits: SessionPolicy.Limits = SessionPolicy.default_limits,
        auth_limits: AuthOperation.Limits = .{},
        auth_transport: ?ai.transport.Transport = null,
    };

    pub const SubmitError = error{
        OutOfMemory,
        EmptyPrompt,
        PromptTooLarge,
        FollowUpQueueFull,
        FollowUpQueueTooLarge,
        RestoredDraftTooLarge,
        SessionUnavailable,
        InvalidLimits,
        QueueFull,
        WorkerStopped,
        EmptyAnswer,
        AnswerTooLarge,
        NotAwaitingAnswer,
        Cancelled,
        InvalidPath,
        ThreadQuotaExceeded,
        SystemResources,
        LockedMemoryLimitExceeded,
        Unexpected,
        InvalidCommand,
        CommandBusy,
        AuthenticationBusy,
        ModelSelectionRequired,
        SessionTransitioning,
        IdentifierTooLong,
        UnsupportedThinkingLevel,
    };

    pub const SubmitDisposition = union(enum) {
        started,
        queued_follow_up,
        command,
        oauth_answer,
    };

    pub const Phase = union(enum) {
        model_less,
        authenticating,
        transitioning,
        unavailable,
        turn: SessionController.Phase,
    };

    /// Borrows model and cwd text from the host. Callers must not retain those
    /// slices across a mutating host call.
    pub const Snapshot = struct {
        phase: InteractiveSessionHost.Phase,
        queued_follow_ups: usize,
        mask_composer: bool,
        active_model: ?ai.ModelIdentity,
        thinking_level: ?ai.ThinkingLevel,
        cwd: []const u8,
    };

    pub const CancelResult = struct {
        restored: ?SessionController.OwnedDraft = null,
        wipe_draft: bool = false,

        pub fn deinit(self: *CancelResult) void {
            if (self.restored) |*draft| draft.deinit();
            self.* = undefined;
        }
    };

    pub const Fact = union(enum) {
        turn: SessionController.Fact,
        auth_started: struct {
            provider: []const u8,
            method: ai.oauth.LoginMethod,
        },
        auth_interaction: AuthOperation.Fact,
        auth_cancelled: struct { provider: []const u8 },
        login_succeeded: struct { provider: []const u8 },
        login_failed: struct {
            provider: []const u8,
            failure: AuthOperation.Failure,
        },
        model_changed: ai.ModelIdentity,
        thinking_level_changed: ai.ThinkingLevel,
        thinking_switch_failed: struct {
            requested: ai.ThinkingLevel,
            reason: []const u8,
        },
        thinking_switch_commit_indeterminate: ai.ThinkingLevel,
        model_less,
        model_switch_failed: struct {
            requested: ai.ModelIdentity,
            reason: []const u8,
        },
        model_switch_commit_indeterminate: ai.ModelIdentity,
        settings_failed: struct {
            selection: ai.ModelIdentity,
            reason: []const u8,
        },
        settings_commit_indeterminate: ai.ModelIdentity,
        session_unavailable: struct { reason: []const u8 },
    };

    pub const Sink = struct {
        context: *anyopaque,
        emit_fn: *const fn (*anyopaque, Fact) anyerror!void,

        // Nested host contract types remain public through InteractiveSessionHost.*.
        // ziglint-ignore: Z012
        pub fn emit(self: Sink, fact: Fact) !void {
            try self.emit_fn(self.context, fact);
        }
    };

    // SessionController stays file-private; its nested contract types surface through host facts.
    // ziglint-ignore: Z012
    pub const DrainResult = SessionController.DrainResult;

    const ModelLessBackend = struct {
        active_model: ?FixedModel,
    };

    const Runnable = struct {
        worker: *TurnWorker,
        controller: SessionController,
        active_model: FixedModel,
        thinking_level: ?ai.ThinkingLevel,
        thinking_levels: std.EnumSet(ai.ThinkingLevel),
    };

    const Backend = union(enum) {
        model_less: ModelLessBackend,
        runnable: Runnable,
        transitioning,
        unavailable,
    };

    const FixedText = struct {
        bytes: [max_identifier_bytes]u8 = undefined,
        len: u16,

        fn init(value: []const u8) error{IdentifierTooLong}!FixedText {
            if (value.len == 0 or value.len > max_identifier_bytes) return error.IdentifierTooLong;
            var result: FixedText = .{ .len = @intCast(value.len) };
            @memcpy(result.bytes[0..value.len], value);
            return result;
        }

        fn slice(self: *const FixedText) []const u8 {
            return self.bytes[0..self.len];
        }
    };

    const FixedModel = struct {
        provider: FixedText,
        model: FixedText,

        fn init(identity: ai.ModelIdentity) error{IdentifierTooLong}!FixedModel {
            return .{
                .provider = try FixedText.init(identity.provider),
                .model = try FixedText.init(identity.model),
            };
        }

        fn view(self: *const FixedModel) ai.ModelIdentity {
            return .{ .provider = self.provider.slice(), .model = self.model.slice() };
        }
    };

    const PendingFact = union(enum) {
        auth_started: struct {
            provider: FixedText,
            method: ai.oauth.LoginMethod,
        },
        auth_cancelled: FixedText,
        login_succeeded: FixedText,
        login_failed: struct {
            provider: FixedText,
            failure: AuthOperation.Failure,
        },
        model_changed: FixedModel,
        thinking_level_changed: ai.ThinkingLevel,
        thinking_switch_failed: struct {
            requested: ai.ThinkingLevel,
            reason: []const u8,
        },
        thinking_switch_commit_indeterminate: ai.ThinkingLevel,
        model_less,
        model_switch_failed: struct {
            requested: FixedModel,
            reason: []const u8,
        },
        model_switch_commit_indeterminate: FixedModel,
        settings_failed: struct {
            selection: FixedModel,
            reason: []const u8,
        },
        settings_commit_indeterminate: FixedModel,
        session_unavailable: struct { reason: []const u8 },

        fn view(self: *const PendingFact) Fact {
            return switch (self.*) {
                .auth_started => |*value| .{ .auth_started = .{
                    .provider = value.provider.slice(),
                    .method = value.method,
                } },
                .auth_cancelled => |*provider| .{ .auth_cancelled = .{
                    .provider = provider.slice(),
                } },
                .login_succeeded => |*provider| .{ .login_succeeded = .{
                    .provider = provider.slice(),
                } },
                .login_failed => |*value| .{ .login_failed = .{
                    .provider = value.provider.slice(),
                    .failure = value.failure,
                } },
                .model_changed => |*selection| .{ .model_changed = selection.view() },
                .thinking_level_changed => |level| .{ .thinking_level_changed = level },
                .thinking_switch_failed => |value| .{ .thinking_switch_failed = .{
                    .requested = value.requested,
                    .reason = value.reason,
                } },
                .thinking_switch_commit_indeterminate => |level| .{
                    .thinking_switch_commit_indeterminate = level,
                },
                .model_less => .model_less,
                .model_switch_failed => |*value| .{ .model_switch_failed = .{
                    .requested = value.requested.view(),
                    .reason = value.reason,
                } },
                .model_switch_commit_indeterminate => |*selection| .{
                    .model_switch_commit_indeterminate = selection.view(),
                },
                .settings_failed => |*value| .{ .settings_failed = .{
                    .selection = value.selection.view(),
                    .reason = value.reason,
                } },
                .settings_commit_indeterminate => |*selection| .{
                    .settings_commit_indeterminate = selection.view(),
                },
                .session_unavailable => |value| .{ .session_unavailable = .{ .reason = value.reason } },
            };
        }
    };

    const ParsedCommand = union(enum) {
        ordinary,
        login: SlashCommands.Login,
        model: ai.ModelIdentity,
        thinking: ai.ThinkingLevel,
    };

    allocator: std.mem.Allocator,
    io: std.Io,
    inputs: ReopenInputs,
    settings_paths: ZiPaths,
    journal_path: []u8,
    transcript_value: SessionTranscript,
    backend: Backend = .transitioning,
    auth: ?*AuthOperation = null,
    auth_batch: ?AuthOperation.Batch = null,
    auth_fact_cursor: usize = 0,
    pending: std.ArrayList(PendingFact) = .empty,
    options: Options,

    /// Takes ownership of `inputs` and `lifecycle` on every return path.
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        inputs: *ReopenInputs,
        lifecycle: *RuntimeServices.Interactive,
        options: Options,
    ) !*InteractiveSessionHost {
        var owned_inputs = inputs.*;
        inputs.* = undefined;
        var inputs_live = true;
        errdefer if (inputs_live) owned_inputs.deinit();
        var owned_lifecycle = lifecycle.*;
        lifecycle.* = undefined;
        var lifecycle_live = true;
        errdefer if (lifecycle_live) owned_lifecycle.deinit();

        const journal_path = try allocator.dupe(u8, owned_lifecycle.journalPath());
        errdefer allocator.free(journal_path);
        var settings_paths = try ZiPaths.init(
            allocator,
            owned_lifecycle.cwd(),
            owned_inputs.initial().home,
        );
        errdefer settings_paths.deinit();
        const self = try allocator.create(InteractiveSessionHost);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .inputs = owned_inputs,
            .settings_paths = settings_paths,
            .journal_path = journal_path,
            .transcript_value = owned_lifecycle.transcript_value,
            .options = options,
        };
        inputs_live = false;
        errdefer self.inputs.deinit();
        errdefer self.pending.deinit(allocator);
        errdefer self.transcript_value.deinit();
        lifecycle_live = false;
        try self.installLifecycle(owned_lifecycle.lifecycle);
        return self;
    }

    pub fn transcript(self: *const InteractiveSessionHost) *const SessionTranscript {
        return &self.transcript_value;
    }

    pub fn snapshot(self: *InteractiveSessionHost) Snapshot {
        const active_model = self.activeModel();
        const thinking_level = self.activeThinkingLevel();
        const cwd = self.settings_paths.cwd;
        if (self.auth) |operation| return .{
            .phase = .authenticating,
            .queued_follow_ups = self.queuedFollowUps(),
            .mask_composer = operation.isAwaitingAnswer(),
            .active_model = active_model,
            .thinking_level = thinking_level,
            .cwd = cwd,
        };
        return switch (self.backend) {
            .model_less => .{
                .phase = .model_less,
                .queued_follow_ups = 0,
                .mask_composer = false,
                .active_model = active_model,
                .thinking_level = thinking_level,
                .cwd = cwd,
            },
            .runnable => |*runnable| .{
                .phase = .{ .turn = runnable.controller.phase() },
                .queued_follow_ups = runnable.controller.queuedFollowUpCount(),
                .mask_composer = false,
                .active_model = active_model,
                .thinking_level = thinking_level,
                .cwd = cwd,
            },
            .transitioning => .{
                .phase = .transitioning,
                .queued_follow_ups = 0,
                .mask_composer = false,
                .active_model = active_model,
                .thinking_level = thinking_level,
                .cwd = cwd,
            },
            .unavailable => .{
                .phase = .unavailable,
                .queued_follow_ups = 0,
                .mask_composer = false,
                .active_model = active_model,
                .thinking_level = thinking_level,
                .cwd = cwd,
            },
        };
    }

    pub fn canExit(self: *InteractiveSessionHost) bool {
        if (self.auth != null) return false;
        return switch (self.backend) {
            .model_less, .unavailable => true,
            .transitioning => false,
            .runnable => |*runnable| runnable.controller.phase() == .idle and workerQuiescent(runnable.worker),
        };
    }

    pub fn hasPendingFacts(self: *InteractiveSessionHost) bool {
        if (self.pending.items.len != 0 or self.auth_batch != null) return true;
        if (self.auth) |operation| if (operation.hasPending()) return true;
        return switch (self.backend) {
            .runnable => |*runnable| runnable.controller.hasPendingFacts(),
            .model_less, .transitioning, .unavailable => false,
        };
    }

    /// Admits commands and turns transactionally. OAuth answers use a separate
    /// disposition so the client can wipe, rather than merely clear, its editor.
    pub fn submit(
        self: *InteractiveSessionHost,
        source: []const u8,
    ) SubmitError!InteractiveSessionHost.SubmitDisposition {
        const text = std.mem.trim(u8, source, " \t\r\n");
        if (text.len == 0) return error.EmptyPrompt;
        const parsed = try parseCommand(text);
        switch (parsed) {
            .login, .model, .thinking => if (self.hasUndrainedControlFacts()) return error.CommandBusy,
            .ordinary => {},
        }
        if (self.auth) |operation| {
            if (!operation.isAwaitingAnswer()) return error.AuthenticationBusy;
            try operation.answer(text);
            return .oauth_answer;
        }
        switch (self.backend) {
            .unavailable => return error.SessionUnavailable,
            .transitioning => return error.SessionTransitioning,
            .model_less, .runnable => {},
        }

        switch (parsed) {
            .ordinary => {},
            .login => |command| {
                if (!self.isQuiescent()) return error.CommandBusy;
                try self.pending.ensureUnusedCapacity(self.allocator, 1);
                const provider_copy = try FixedText.init(command.provider);
                const operation = if (self.options.auth_transport) |transport|
                    try AuthOperation.startWithTransport(self.allocator, self.io, .{
                        .startup_cwd = self.inputs.initial().startup_cwd,
                        .home = self.inputs.initial().home,
                        .provider_id = command.provider,
                        .method = command.method,
                        .now_ms = self.inputs.initial().sources.nowMsFn(
                            self.inputs.initial().sources.clock_context,
                        ),
                        .limits = self.options.auth_limits,
                    }, transport)
                else
                    try AuthOperation.start(self.allocator, self.io, .{
                        .startup_cwd = self.inputs.initial().startup_cwd,
                        .home = self.inputs.initial().home,
                        .provider_id = command.provider,
                        .method = command.method,
                        .now_ms = self.inputs.initial().sources.nowMsFn(
                            self.inputs.initial().sources.clock_context,
                        ),
                        .limits = self.options.auth_limits,
                    });
                self.auth = operation;
                self.appendPendingAssumeCapacity(.{ .auth_started = .{
                    .provider = provider_copy,
                    .method = operation.loginMethod(),
                } });
                return .command;
            },
            .model => |selection| {
                if (!self.isQuiescent()) return error.CommandBusy;
                try self.switchModel(selection);
                return .command;
            },
            .thinking => |requested| {
                if (!self.isQuiescent()) return error.CommandBusy;
                try self.switchThinkingLevel(requested);
                return .command;
            },
        }

        return switch (self.backend) {
            .runnable => |*runnable| switch (try runnable.controller.submit(text)) {
                .started => .started,
                .queued_follow_up => .queued_follow_up,
            },
            .model_less => error.ModelSelectionRequired,
            .transitioning => error.SessionTransitioning,
            .unavailable => error.SessionUnavailable,
        };
    }

    pub fn cancel(
        self: *InteractiveSessionHost,
        current_draft: []const u8,
    ) (SessionController.CancelError || error{OutOfMemory})!CancelResult {
        if (self.auth) |operation| {
            const wipe_draft = operation.isAwaitingAnswer();
            _ = operation.requestCancel();
            return .{ .wipe_draft = wipe_draft };
        }
        return switch (self.backend) {
            .runnable => |*runnable| .{ .restored = try runnable.controller.cancel(current_draft) },
            .model_less, .transitioning, .unavailable => .{},
        };
    }

    pub fn requestExit(self: *InteractiveSessionHost) void {
        if (self.auth) |operation| _ = operation.requestCancel();
        switch (self.backend) {
            .runnable => |*runnable| _ = runnable.worker.requestCancel(),
            .model_less, .transitioning, .unavailable => {},
        }
    }

    pub fn drain(
        self: *InteractiveSessionHost,
        current_draft: []const u8,
        sink: Sink,
    ) !DrainResult {
        var result: DrainResult = .{};
        errdefer result.deinit();

        try self.drainPending(sink);
        if (self.auth) |operation| {
            if (self.auth_batch == null and operation.hasPending()) {
                self.auth_batch = try operation.takeBatch();
                self.auth_fact_cursor = 0;
            }
            if (self.auth_batch) |*batch| {
                while (self.auth_fact_cursor < batch.len()) {
                    const fact_value = batch.fact(self.auth_fact_cursor);
                    try sink.emit(.{ .auth_interaction = fact_value });
                    self.auth_fact_cursor += 1;
                }
                if (batch.outcome) |outcome| {
                    try self.pending.ensureUnusedCapacity(self.allocator, 2);
                    self.settleAuthAssumeCapacity(outcome);
                    self.releaseAuthBatch();
                    operation.deinit();
                    self.auth = null;
                } else {
                    self.releaseAuthBatch();
                }
            }
        }
        try self.drainPending(sink);

        switch (self.backend) {
            .runnable => |*runnable| {
                if (runnable.controller.hasPendingFacts()) {
                    var turn_sink = sink;
                    var turn_result = try runnable.controller.drain(
                        current_draft,
                        .{ .context = &turn_sink, .emitFn = emitTurnFact },
                    );
                    defer turn_result.deinit();
                    if (turn_result.restored) |restored| {
                        result.restored = restored;
                        turn_result.restored = null;
                    }
                }
            },
            .model_less, .transitioning, .unavailable => {},
        }
        return result;
    }

    // Heap destruction follows explicit field invalidation.
    // ziglint-ignore: Z030
    pub fn deinit(self: *InteractiveSessionHost) void {
        if (self.auth) |operation| operation.deinit();
        if (self.auth_batch) |*batch| batch.deinit();
        self.deinitBackend();
        self.pending.deinit(self.allocator);
        self.transcript_value.deinit();
        self.allocator.free(self.journal_path);
        self.settings_paths.deinit();
        self.inputs.deinit();
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    fn settleAuthAssumeCapacity(
        self: *InteractiveSessionHost,
        outcome: AuthOperation.Outcome,
    ) void {
        const provider = FixedText.init(self.auth.?.provider()) catch unreachable;
        switch (outcome) {
            .cancelled => self.appendPendingAssumeCapacity(.{ .auth_cancelled = provider }),
            .failed => |failure| self.appendPendingAssumeCapacity(.{ .login_failed = .{
                .provider = provider,
                .failure = failure,
            } }),
            .succeeded => {
                self.appendPendingAssumeCapacity(.{ .login_succeeded = provider });
                self.closeForTransition();
                const lifecycle = RuntimeServices.reopenInteractive(
                    self.allocator,
                    self.io,
                    self.inputs.reopen(self.journal_path, .{}),
                ) catch |failure| {
                    self.backend = .unavailable;
                    self.appendPendingAssumeCapacity(.{
                        .session_unavailable = .{ .reason = @errorName(failure) },
                    });
                    return;
                };
                self.installLifecycle(lifecycle) catch |failure| {
                    self.backend = .unavailable;
                    self.appendPendingAssumeCapacity(.{
                        .session_unavailable = .{ .reason = @errorName(failure) },
                    });
                    return;
                };
                switch (self.backend) {
                    .runnable => |*runnable| self.appendPendingAssumeCapacity(.{
                        .model_changed = runnable.active_model,
                    }),
                    .model_less => self.appendPendingAssumeCapacity(.model_less),
                    .transitioning, .unavailable => unreachable,
                }
            },
        }
    }

    pub fn cycleThinkingLevel(self: *InteractiveSessionHost) SubmitError!void {
        if (self.hasUndrainedControlFacts() or !self.isQuiescent()) return error.CommandBusy;
        const runnable = switch (self.backend) {
            .runnable => |*value| value,
            .model_less => return error.ModelSelectionRequired,
            .transitioning => return error.SessionTransitioning,
            .unavailable => return error.SessionUnavailable,
        };
        const current = runnable.thinking_level orelse return error.InvalidCommand;
        return self.switchThinkingLevel(nextThinkingLevel(runnable.thinking_levels, current));
    }

    fn switchThinkingLevel(
        self: *InteractiveSessionHost,
        requested: ai.ThinkingLevel,
    ) SubmitError!void {
        const runnable = switch (self.backend) {
            .runnable => |*value| value,
            .model_less => return error.ModelSelectionRequired,
            .transitioning => return error.SessionTransitioning,
            .unavailable => return error.SessionUnavailable,
        };
        _ = runnable.thinking_level orelse return error.InvalidCommand;
        if (!runnable.thinking_levels.contains(requested)) return error.UnsupportedThinkingLevel;
        try self.pending.ensureUnusedCapacity(self.allocator, 2);
        self.closeForTransition();
        const lifecycle = RuntimeServices.reopenInteractive(
            self.allocator,
            self.io,
            self.inputs.reopen(self.journal_path, .{ .thinking_level = requested }),
        ) catch |failure| {
            self.recoverAfterThinkingFailure(requested, failure);
            return;
        };
        self.installLifecycle(lifecycle) catch |failure| {
            self.recoverAfterThinkingFailure(requested, failure);
            return;
        };
        self.appendPendingAssumeCapacity(.{
            .thinking_level_changed = self.activeThinkingLevel().?,
        });
    }

    fn nextThinkingLevel(
        levels: std.EnumSet(ai.ThinkingLevel),
        current: ai.ThinkingLevel,
    ) ai.ThinkingLevel {
        const values = std.enums.values(ai.ThinkingLevel);
        var offset: usize = 1;
        while (offset <= values.len) : (offset += 1) {
            const level = values[(@intFromEnum(current) + offset) % values.len];
            if (levels.contains(level)) return level;
        }
        return .off;
    }

    fn recoverAfterThinkingFailure(
        self: *InteractiveSessionHost,
        requested: ai.ThinkingLevel,
        failure: anyerror,
    ) void {
        const lifecycle = RuntimeServices.reopenInteractive(
            self.allocator,
            self.io,
            self.inputs.reopen(self.journal_path, .{}),
        ) catch |recovery_failure| {
            self.backend = .unavailable;
            self.appendThinkingFailure(requested, failure);
            self.appendPendingAssumeCapacity(.{
                .session_unavailable = .{ .reason = @errorName(recovery_failure) },
            });
            return;
        };
        self.installLifecycle(lifecycle) catch |recovery_failure| {
            self.backend = .unavailable;
            self.appendThinkingFailure(requested, failure);
            self.appendPendingAssumeCapacity(.{
                .session_unavailable = .{ .reason = @errorName(recovery_failure) },
            });
            return;
        };
        self.appendThinkingFailure(requested, failure);
    }

    fn appendThinkingFailure(
        self: *InteractiveSessionHost,
        requested: ai.ThinkingLevel,
        failure: anyerror,
    ) void {
        self.appendPendingAssumeCapacity(thinkingFailureFact(requested, failure));
    }

    fn thinkingFailureFact(requested: ai.ThinkingLevel, failure: anyerror) PendingFact {
        return if (failure == error.CommitIndeterminate)
            .{ .thinking_switch_commit_indeterminate = requested }
        else
            .{ .thinking_switch_failed = .{
                .requested = requested,
                .reason = @errorName(failure),
            } };
    }

    fn switchModel(self: *InteractiveSessionHost, requested: ai.ModelIdentity) !void {
        const requested_copy = try FixedModel.init(requested);
        try self.pending.ensureUnusedCapacity(self.allocator, 3);
        self.closeForTransition();
        const lifecycle = RuntimeServices.reopenInteractive(
            self.allocator,
            self.io,
            self.inputs.reopen(self.journal_path, .{
                .provider = requested.provider,
                .model = requested.model,
            }),
        ) catch |failure| {
            try self.recoverAfterSwitchFailure(requested_copy, failure);
            return;
        };
        self.installLifecycle(lifecycle) catch |failure| {
            try self.recoverAfterSwitchFailure(requested_copy, failure);
            return;
        };

        const canonical = self.activeModel() orelse unreachable;
        const canonical_copy = try FixedModel.init(canonical);
        self.appendPendingAssumeCapacity(.{ .model_changed = canonical_copy });
        SettingsStore.setGlobalDefaultModel(
            self.allocator,
            self.io,
            &self.settings_paths,
            canonical.provider,
            canonical.model,
        ) catch |failure| switch (failure) {
            error.CommitIndeterminate => self.appendPendingAssumeCapacity(.{
                .settings_commit_indeterminate = canonical_copy,
            }),
            else => self.appendPendingAssumeCapacity(.{ .settings_failed = .{
                .selection = canonical_copy,
                .reason = @errorName(failure),
            } }),
        };
    }

    fn recoverAfterSwitchFailure(
        self: *InteractiveSessionHost,
        requested: FixedModel,
        failure: anyerror,
    ) !void {
        const lifecycle = RuntimeServices.reopenInteractive(
            self.allocator,
            self.io,
            self.inputs.reopen(self.journal_path, .{}),
        ) catch |recovery_failure| {
            self.backend = .unavailable;
            self.appendSwitchFailure(requested, failure);
            self.appendPendingAssumeCapacity(.{
                .session_unavailable = .{ .reason = @errorName(recovery_failure) },
            });
            return;
        };
        self.installLifecycle(lifecycle) catch |recovery_failure| {
            self.backend = .unavailable;
            self.appendSwitchFailure(requested, failure);
            self.appendPendingAssumeCapacity(.{
                .session_unavailable = .{ .reason = @errorName(recovery_failure) },
            });
            return;
        };
        self.appendSwitchFailure(requested, failure);
        if (self.activeModel()) |model| {
            self.appendPendingAssumeCapacity(.{ .model_changed = try FixedModel.init(model) });
        } else {
            self.appendPendingAssumeCapacity(.model_less);
        }
    }

    fn appendSwitchFailure(self: *InteractiveSessionHost, requested: FixedModel, failure: anyerror) void {
        if (failure == error.CommitIndeterminate) {
            self.appendPendingAssumeCapacity(.{ .model_switch_commit_indeterminate = requested });
        } else {
            self.appendPendingAssumeCapacity(.{ .model_switch_failed = .{
                .requested = requested,
                .reason = @errorName(failure),
            } });
        }
    }

    fn installLifecycle(self: *InteractiveSessionHost, lifecycle: RuntimeServices.Lifecycle) !void {
        std.debug.assert(self.backend == .transitioning);
        const thinking_level = lifecycle.thinkingLevel();
        const thinking_levels = lifecycle.thinkingLevels();
        const active_model = if (lifecycle.activeModel()) |model|
            FixedModel.init(model) catch |failure| {
                lifecycle.deinit();
                return failure;
            }
        else
            null;
        switch (lifecycle) {
            .model_less => |runtime| {
                runtime.deinit();
                self.backend = .{ .model_less = .{
                    .active_model = active_model,
                } };
            },
            .runnable => |runtime| {
                const worker = TurnWorker.start(
                    self.allocator,
                    self.io,
                    TurnWorker.SessionOwner.from(runtime),
                    self.options.worker_limits,
                ) catch |failure| {
                    runtime.deinit();
                    return failure;
                };
                const controller = SessionController.init(
                    self.allocator,
                    worker,
                    self.options.policy_limits,
                ) catch |failure| {
                    worker.deinit();
                    return failure;
                };
                self.backend = .{ .runnable = .{
                    .worker = worker,
                    .controller = controller,
                    .active_model = active_model orelse unreachable,
                    .thinking_level = thinking_level,
                    .thinking_levels = thinking_levels,
                } };
            },
        }
    }

    fn activeThinkingLevel(self: *InteractiveSessionHost) ?ai.ThinkingLevel {
        return switch (self.backend) {
            .runnable => |*runnable| runnable.thinking_level,
            .model_less, .transitioning, .unavailable => null,
        };
    }

    fn activeModel(self: *InteractiveSessionHost) ?ai.ModelIdentity {
        return switch (self.backend) {
            .model_less => |*runtime| if (runtime.active_model) |*model| model.view() else null,
            .runnable => |*runnable| runnable.active_model.view(),
            .transitioning, .unavailable => null,
        };
    }

    fn closeForTransition(self: *InteractiveSessionHost) void {
        self.deinitBackend();
        self.backend = .transitioning;
    }

    fn deinitBackend(self: *InteractiveSessionHost) void {
        switch (self.backend) {
            .model_less => {},
            .runnable => |*runnable| {
                runnable.controller.deinit();
                runnable.worker.deinit();
            },
            .transitioning, .unavailable => {},
        }
    }

    fn isQuiescent(self: *InteractiveSessionHost) bool {
        return switch (self.backend) {
            .model_less => true,
            .runnable => |*runnable| runnable.controller.phase() == .idle and workerQuiescent(runnable.worker),
            .transitioning, .unavailable => false,
        };
    }

    fn queuedFollowUps(self: *InteractiveSessionHost) usize {
        return switch (self.backend) {
            .runnable => |*runnable| runnable.controller.queuedFollowUpCount(),
            .model_less, .transitioning, .unavailable => 0,
        };
    }

    fn workerQuiescent(worker: *TurnWorker) bool {
        const value = worker.snapshot();
        return !value.processing and value.queued_prompts == 0 and value.queued_events == 0 and
            value.queued_completions == 0;
    }

    fn hasUndrainedControlFacts(self: *InteractiveSessionHost) bool {
        if (self.pending.items.len != 0 or self.auth_batch != null) return true;
        if (self.auth) |operation| return operation.hasPending();
        return false;
    }

    fn drainPending(self: *InteractiveSessionHost, sink: Sink) !void {
        while (self.pending.items.len != 0) {
            try sink.emit(self.pending.items[0].view());
            _ = self.pending.orderedRemove(0);
        }
    }

    fn releaseAuthBatch(self: *InteractiveSessionHost) void {
        self.auth_batch.?.deinit();
        self.auth_batch = null;
        self.auth_fact_cursor = 0;
    }

    fn appendPendingAssumeCapacity(self: *InteractiveSessionHost, fact: PendingFact) void {
        self.pending.appendAssumeCapacity(fact);
    }

    fn parseCommand(text: []const u8) SlashCommands.ParseError!ParsedCommand {
        return switch (SlashCommands.parse(text)) {
            .ordinary => .ordinary,
            .command => |invocation| switch (invocation.spec.kind) {
                .login => .{ .login = try SlashCommands.Login.parse(invocation.arguments) },
                .model => .{ .model = (try SlashCommands.Model.parse(invocation.arguments)).selection },
                .thinking => .{ .thinking = (try SlashCommands.Thinking.parse(invocation.arguments)).level },
            },
        };
    }

    fn emitTurnFact(context: *anyopaque, fact: SessionController.Fact) !void {
        const sink: *Sink = @ptrCast(@alignCast(context));
        try sink.emit(.{ .turn = fact });
    }
};

// Turn controller (private) ----------------------------------------------

const SessionController = struct {
    pub const InitError = error{
        OutOfMemory,
        InvalidLimits,
    };
    pub const SubmitError = error{
        OutOfMemory,
        EmptyPrompt,
        PromptTooLarge,
        FollowUpQueueFull,
        FollowUpQueueTooLarge,
        RestoredDraftTooLarge,
        SessionUnavailable,
        InvalidLimits,
        QueueFull,
        WorkerStopped,
    };
    pub const CancelError = error{ OutOfMemory, RestoredDraftTooLarge };
    pub const Phase = SessionPolicy.Phase;
    pub const OwnedDraft = SessionPolicy.OwnedDraft;

    pub const SubmitDisposition = enum {
        started,
        queued_follow_up,
    };

    pub const CompletionFact = struct {
        value: TurnWorker.Completion,
        agent_end_observed: bool,
    };

    pub const Fault = union(enum) {
        follow_up_submission: TurnWorker.SubmitError,
        draft_restore: error{ OutOfMemory, RestoredDraftTooLarge },
    };

    /// Facts are borrowed for the duration of `emitFn`. Event payloads remain
    /// owned by the detached worker batch until `drain` returns.
    pub const Fact = union(enum) {
        event: session_event.Event,
        completion: CompletionFact,
        fault: Fault,
    };

    pub const Sink = struct {
        context: *anyopaque,
        emitFn: *const fn (*anyopaque, Fact) anyerror!void,

        // Nested controller contract types remain public through SessionController.*.
        // ziglint-ignore: Z012
        pub fn emit(self: Sink, fact: Fact) !void {
            try self.emitFn(self.context, fact);
        }
    };

    pub const DrainResult = struct {
        restored: ?OwnedDraft = null,

        pub fn deinit(self: *DrainResult) void {
            if (self.restored) |*draft| draft.deinit();
            self.* = undefined;
        }
    };

    const DeliverySource = union(enum) {
        event: usize,
        completion: struct {
            index: usize,
            agent_end_observed: bool,
        },
    };

    const DeliveryStage = union(enum) {
        primary: SessionPolicy.Effect,
        effect: SessionPolicy.Effect,
        fault: Fault,
    };

    const PreparedDelivery = struct {
        source: DeliverySource,
        stage: DeliveryStage,
    };

    allocator: std.mem.Allocator,
    worker: *TurnWorker,
    policy: SessionPolicy,
    in_flight: ?TurnWorker.Batch = null,
    event_cursor: usize = 0,
    completion_cursor: usize = 0,
    prepared: ?PreparedDelivery = null,
    pending_restored: ?OwnedDraft = null,

    fn init(
        allocator: std.mem.Allocator,
        worker: *TurnWorker,
        limits: SessionPolicy.Limits,
    ) InitError!SessionController {
        return .{
            .allocator = allocator,
            .worker = worker,
            .policy = try SessionPolicy.init(allocator, limits),
        };
    }

    pub fn deinit(self: *SessionController) void {
        if (self.pending_restored) |*restored| restored.deinit();
        if (self.in_flight) |*batch| batch.deinit(self.allocator);
        self.policy.deinit();
        self.* = undefined;
    }

    fn phase(self: *const SessionController) SessionController.Phase {
        return self.policy.phase();
    }

    fn queuedFollowUpCount(self: *const SessionController) usize {
        return self.policy.queuedFollowUps().len;
    }

    fn queuedFollowUp(self: *const SessionController, index: usize) ?[]const u8 {
        const queued = self.policy.queuedFollowUps();
        if (index >= queued.len) return null;
        return queued[index];
    }

    fn hasPendingFacts(self: *SessionController) bool {
        if (self.in_flight != null or self.prepared != null or self.pending_restored != null) return true;
        return workerHasPending(self.worker);
    }

    /// Admits a prompt transactionally. The caller may clear its editor only after
    /// this function succeeds.
    fn submit(
        self: *SessionController,
        prompt: []const u8,
    ) SubmitError!SessionController.SubmitDisposition {
        var prepared = try self.policy.prepareSubmission(prompt);
        var prepared_live = true;
        defer if (prepared_live) prepared.deinit();

        const disposition: SessionController.SubmitDisposition = switch (prepared.route) {
            .start => started: {
                try self.worker.submit(prepared.text);
                break :started .started;
            },
            .follow_up => .queued_follow_up,
        };
        self.policy.commitSubmission(&prepared);
        prepared_live = false;
        return disposition;
    }

    /// Restores queued follow-ups into the caller's draft and requests worker
    /// cancellation when an active run is known.
    fn cancel(
        self: *SessionController,
        current_draft: []const u8,
    ) CancelError!?OwnedDraft {
        const result = try self.policy.escape(current_draft);
        if (result.request_cancel) _ = self.worker.requestCancel();
        return result.restored;
    }

    /// Reduces detached worker output in contractual order. A policy transition is
    /// prepared once, then its borrowed fact remains retained until the sink accepts it.
    fn drain(
        self: *SessionController,
        current_draft: []const u8,
        sink: Sink,
    ) !DrainResult {
        while (true) {
            if (self.pending_restored) |restored| {
                self.pending_restored = null;
                return .{ .restored = restored };
            }
            if (self.prepared != null) {
                try self.deliverPrepared(current_draft, sink);
                continue;
            }
            if (self.in_flight == null) {
                if (!workerHasPending(self.worker)) return .{};
                self.in_flight = try self.worker.takeBatch();
                self.event_cursor = 0;
                self.completion_cursor = 0;
            }
            if (self.prepareNext()) continue;

            self.in_flight.?.deinit(self.allocator);
            self.in_flight = null;
        }
    }

    fn prepareNext(self: *SessionController) bool {
        const batch = &self.in_flight.?;
        while (self.event_cursor < batch.events.items.len) {
            const index = self.event_cursor;
            const reduced = self.policy.applyEvent(batch.events.items[index].value);
            if (reduced.admission == .stale) {
                self.event_cursor += 1;
                continue;
            }
            self.prepared = .{
                .source = .{ .event = index },
                .stage = .{ .primary = reduced.effect },
            };
            return true;
        }
        while (self.completion_cursor < batch.completions.items.len) {
            const index = self.completion_cursor;
            const completion = batch.completions.items[index];
            const reduced = self.policy.applyCompletion(completion.run_id, completion.availability);
            if (reduced.admission == .stale) {
                self.completion_cursor += 1;
                continue;
            }
            self.prepared = .{
                .source = .{ .completion = .{
                    .index = index,
                    .agent_end_observed = batchContainsAgentEnd(batch, completion.run_id),
                } },
                .stage = .{ .primary = reduced.effect },
            };
            return true;
        }
        return false;
    }

    fn deliverPrepared(
        self: *SessionController,
        current_draft: []const u8,
        sink: Sink,
    ) !void {
        while (true) switch (self.prepared.?.stage) {
            .primary => |effect| {
                try sink.emit(self.preparedFact());
                self.prepared.?.stage = .{ .effect = effect };
            },
            .effect => |effect| switch (effect) {
                .none => return self.finishPrepared(),
                .request_cancel => {
                    _ = self.worker.requestCancel();
                    return self.finishPrepared();
                },
                .submit_follow_up => |prompt| {
                    self.worker.submit(prompt) catch |failure| {
                        self.policy.rejectFollowUpSubmission();
                        self.prepared.?.stage = .{ .fault = .{
                            .follow_up_submission = failure,
                        } };
                        continue;
                    };
                    self.policy.confirmFollowUpSubmission();
                    return self.finishPrepared();
                },
                .session_poisoned => {
                    self.pending_restored = self.policy.restoreQueued(current_draft) catch |failure| {
                        self.prepared.?.stage = .{ .fault = .{ .draft_restore = failure } };
                        continue;
                    };
                    return self.finishPrepared();
                },
            },
            .fault => |fault| {
                try sink.emit(.{ .fault = fault });
                return self.finishPrepared();
            },
        };
    }

    fn preparedFact(self: *SessionController) Fact {
        const batch = &self.in_flight.?;
        return switch (self.prepared.?.source) {
            .event => |index| .{ .event = batch.events.items[index].value },
            .completion => |delivery| .{ .completion = .{
                .value = batch.completions.items[delivery.index],
                .agent_end_observed = delivery.agent_end_observed,
            } },
        };
    }

    fn finishPrepared(self: *SessionController) void {
        switch (self.prepared.?.source) {
            .event => self.event_cursor += 1,
            .completion => self.completion_cursor += 1,
        }
        self.prepared = null;
    }

    fn workerHasPending(worker: *TurnWorker) bool {
        const snapshot = worker.snapshot();
        return snapshot.queued_events != 0 or snapshot.queued_completions != 0;
    }

    fn batchContainsAgentEnd(
        batch: *const TurnWorker.Batch,
        run_id: agent.event.RunId,
    ) bool {
        for (batch.events.items) |owned| switch (owned.value) {
            .agent_end => |ended| if (ended.run_id == run_id) return true,
            else => {},
        };
        return false;
    }
};

// ziglint-ignore: Z012
pub const HostFact = InteractiveSessionHost.Fact;
// ziglint-ignore: Z012
pub const TurnFact = SessionController.Fact;
pub const HostSink = InteractiveSessionHost.Sink;
pub const Phase = InteractiveSessionHost.Phase;
pub const SubmitDisposition = InteractiveSessionHost.SubmitDisposition;

// Tests ------------------------------------------------------------------

const HostTestSources = struct {
    next_id: u64 = 0,
    now_ms: u64 = 1_777_800_000_000,

    fn nextId(context: *anyopaque) [16]u8 {
        const self: *HostTestSources = @ptrCast(@alignCast(context));
        self.next_id += 1;
        var result: [16]u8 = [_]u8{0} ** 16;
        std.mem.writeInt(u64, result[8..16], self.next_id, .big);
        return result;
    }

    fn nowMs(context: *anyopaque) u64 {
        const self: *HostTestSources = @ptrCast(@alignCast(context));
        self.now_ms += 1;
        return self.now_ms;
    }

    fn view(self: *HostTestSources) SessionFormat.Sources {
        return .{
            .id_context = self,
            .nextIdFn = nextId,
            .clock_context = self,
            .nowMsFn = nowMs,
        };
    }
};

const RetryAuthRecorder = struct {
    host: *InteractiveSessionHost,
    answer: []const u8,
    auth_url_attempts: usize = 0,
    prompt_attempts: usize = 0,
    login_attempts: usize = 0,
    auth_url_order: ?usize = null,
    prompt_order: ?usize = null,
    login_order: ?usize = null,
    model_order: ?usize = null,
    sequence: usize = 0,

    fn emit(context: *anyopaque, fact: InteractiveSessionHost.Fact) !void {
        const self: *RetryAuthRecorder = @ptrCast(@alignCast(context));
        switch (fact) {
            .auth_started => {},
            .auth_interaction => |interaction| switch (interaction) {
                .auth_url => {
                    self.auth_url_attempts += 1;
                    if (self.auth_url_attempts == 1) return error.Injected;
                    self.auth_url_order = self.nextOrder();
                },
                .prompt => {
                    self.prompt_attempts += 1;
                    if (self.prompt_attempts == 1) return error.Injected;
                    self.prompt_order = self.nextOrder();
                    try std.testing.expect((try self.host.submit(self.answer)) == .oauth_answer);
                },
                .device_code => return error.UnexpectedDeviceCode,
            },
            .login_succeeded => {
                self.login_attempts += 1;
                try std.testing.expect(self.host.snapshot().phase == .turn);
                if (self.login_attempts == 1) return error.Injected;
                self.login_order = self.nextOrder();
            },
            .model_changed => self.model_order = self.nextOrder(),
            .turn,
            .thinking_level_changed,
            .thinking_switch_failed,
            .thinking_switch_commit_indeterminate,
            .auth_cancelled,
            .login_failed,
            .model_less,
            .model_switch_failed,
            .model_switch_commit_indeterminate,
            .settings_failed,
            .settings_commit_indeterminate,
            .session_unavailable,
            => return error.UnexpectedFact,
        }
    }

    fn nextOrder(self: *RetryAuthRecorder) usize {
        const result = self.sequence;
        self.sequence += 1;
        return result;
    }

    fn sink(self: *RetryAuthRecorder) InteractiveSessionHost.Sink {
        return .{ .context = self, .emit_fn = emit };
    }
};

const DeviceRetryRecorder = struct {
    host: *InteractiveSessionHost,
    device_attempts: usize = 0,
    saw_cancelled: bool = false,

    fn emit(context: *anyopaque, fact: InteractiveSessionHost.Fact) !void {
        const self: *DeviceRetryRecorder = @ptrCast(@alignCast(context));
        switch (fact) {
            .auth_started => {},
            .auth_interaction => |interaction| switch (interaction) {
                .device_code => {
                    self.device_attempts += 1;
                    if (self.device_attempts == 1) return error.Injected;
                    self.host.requestExit();
                },
                .auth_url, .prompt => return error.UnexpectedInteraction,
            },
            .auth_cancelled => self.saw_cancelled = true,
            .turn,
            .login_succeeded,
            .login_failed,
            .model_changed,
            .thinking_level_changed,
            .thinking_switch_failed,
            .thinking_switch_commit_indeterminate,
            .model_less,
            .model_switch_failed,
            .model_switch_commit_indeterminate,
            .settings_failed,
            .settings_commit_indeterminate,
            .session_unavailable,
            => return error.UnexpectedFact,
        }
    }

    fn sink(self: *DeviceRetryRecorder) InteractiveSessionHost.Sink {
        return .{ .context = self, .emit_fn = emit };
    }
};

const HostTestRecorder = struct {
    host: ?*InteractiveSessionHost = null,
    answer: ?[]const u8 = null,
    answered: bool = false,
    saw_login_success: bool = false,
    saw_model_change: bool = false,
    saw_model_less: bool = false,
    saw_switch_failure: bool = false,
    saw_auth_cancelled: bool = false,
    saw_unavailable: bool = false,

    fn emit(context: *anyopaque, fact: InteractiveSessionHost.Fact) !void {
        const self: *HostTestRecorder = @ptrCast(@alignCast(context));
        switch (fact) {
            .turn => {},
            .auth_started => |value| try self.expectSafe(value.provider),
            .auth_interaction => |interaction| switch (interaction) {
                .auth_url => |value| {
                    try self.expectSafe(value.url);
                    try self.expectSafe(value.instructions);
                },
                .device_code => |value| {
                    try self.expectSafe(value.user_code);
                    try self.expectSafe(value.verification_uri);
                },
                .prompt => |value| {
                    try self.expectSafe(value.message);
                    if (value.placeholder) |placeholder| try self.expectSafe(placeholder);
                    if (self.answer) |answer| if (!self.answered) {
                        try std.testing.expect(self.host.?.snapshot().mask_composer);
                        try std.testing.expect((try self.host.?.submit(answer)) == .oauth_answer);
                        self.answered = true;
                    };
                },
            },
            .auth_cancelled => |value| {
                try self.expectSafe(value.provider);
                self.saw_auth_cancelled = true;
            },
            .login_succeeded => |value| {
                try self.expectSafe(value.provider);
                self.saw_login_success = true;
            },
            .login_failed => |value| try self.expectSafe(value.provider),
            .model_changed => |value| {
                try self.expectSafe(value.provider);
                try self.expectSafe(value.model);
                self.saw_model_change = true;
            },
            .thinking_level_changed => {},
            .thinking_switch_failed, .thinking_switch_commit_indeterminate => {
                self.saw_switch_failure = true;
            },
            .model_less => self.saw_model_less = true,
            .model_switch_failed => |value| {
                try self.expectSafe(value.requested.provider);
                try self.expectSafe(value.requested.model);
                self.saw_switch_failure = true;
            },
            .model_switch_commit_indeterminate => |value| {
                try self.expectSafe(value.provider);
                try self.expectSafe(value.model);
                self.saw_switch_failure = true;
            },
            .settings_failed => |value| {
                try self.expectSafe(value.selection.provider);
                try self.expectSafe(value.selection.model);
            },
            .settings_commit_indeterminate => |value| {
                try self.expectSafe(value.provider);
                try self.expectSafe(value.model);
            },
            .session_unavailable => self.saw_unavailable = true,
        }
    }

    fn expectSafe(self: *const HostTestRecorder, value: []const u8) !void {
        if (self.answer) |answer| try std.testing.expect(std.mem.find(u8, value, answer) == null);
    }

    fn sink(self: *HostTestRecorder) InteractiveSessionHost.Sink {
        return .{ .context = self, .emit_fn = emit };
    }
};

test "thinking switch failures retain deterministic and indeterminate types" {
    const deterministic = InteractiveSessionHost.thinkingFailureFact(.high, error.PersistenceFailed);
    try std.testing.expect(deterministic == .thinking_switch_failed);
    try std.testing.expectEqualStrings("PersistenceFailed", deterministic.thinking_switch_failed.reason);
    const indeterminate = InteractiveSessionHost.thinkingFailureFact(.low, error.CommitIndeterminate);
    try std.testing.expect(indeterminate == .thinking_switch_commit_indeterminate);
}

fn hostTestRoot(temporary: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
    const length = try temporary.dir.realPath(std.testing.io, buffer);
    return buffer[0..length];
}

fn hostTestAccessToken(allocator: std.mem.Allocator) ![]u8 {
    const payload = "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"account\"}}";
    const encoded = try allocator.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(payload.len));
    defer allocator.free(encoded);
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, payload);
    return std.fmt.allocPrint(allocator, "header.{s}.signature", .{encoded});
}

fn createHostForTest(
    root: []const u8,
    sources: SessionFormat.Sources,
    requested: ?ai.ModelIdentity,
    options: InteractiveSessionHost.Options,
) !*InteractiveSessionHost {
    var inputs = try ReopenInputs.init(std.testing.allocator, .{
        .startup_cwd = root,
        .home = root,
        .session = .new,
        .sources = sources,
        .requested_provider = if (requested) |value| value.provider else null,
        .requested_model = if (requested) |value| value.model else null,
    });
    var lifecycle = try RuntimeServices.createInteractive(
        std.testing.allocator,
        std.testing.io,
        inputs.initial(),
    );
    return InteractiveSessionHost.init(
        std.testing.allocator,
        std.testing.io,
        &inputs,
        &lifecycle,
        options,
    );
}

test "interactive host snapshot uses the resumed session cwd" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(std.testing.io, "launch", .default_dir);
    try temporary.dir.createDir(std.testing.io, "stored", .default_dir);
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try hostTestRoot(&temporary, &root_buffer);
    const launch_cwd = try std.fs.path.resolve(std.testing.allocator, &.{ root, "launch" });
    defer std.testing.allocator.free(launch_cwd);
    const stored_cwd = try std.fs.path.resolve(std.testing.allocator, &.{ root, "stored" });
    defer std.testing.allocator.free(stored_cwd);
    var sources: HostTestSources = .{};

    const created = try createHostForTest(stored_cwd, sources.view(), null, .{});
    const journal_path = try std.testing.allocator.dupe(u8, created.journal_path);
    created.deinit();
    defer std.testing.allocator.free(journal_path);

    var inputs = try ReopenInputs.init(std.testing.allocator, .{
        .startup_cwd = launch_cwd,
        .home = root,
        .session = .{ .open = journal_path },
        .sources = sources.view(),
    });
    var lifecycle = try RuntimeServices.createInteractive(
        std.testing.allocator,
        std.testing.io,
        inputs.initial(),
    );
    const resumed = try InteractiveSessionHost.init(
        std.testing.allocator,
        std.testing.io,
        &inputs,
        &lifecycle,
        .{},
    );
    defer resumed.deinit();
    try std.testing.expectEqualStrings(stored_cwd, resumed.snapshot().cwd);
}

test "model switch reopens the exact journal and persists the canonical default" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try hostTestRoot(&temporary, &root_buffer);
    var paths = try ZiPaths.init(std.testing.allocator, root, root);
    defer paths.deinit();
    try CredentialStore.put(std.testing.allocator, std.testing.io, &paths, .{
        .provider_id = "openai-codex",
        .credential = .{ .oauth = .{
            .access = "fresh-access",
            .refresh = "fresh-refresh",
            .expires_at_ms = std.math.maxInt(u64),
            .account_id = "account",
        } },
    });
    var sources: HostTestSources = .{};
    const host = try createHostForTest(root, sources.view(), .{
        .provider = "openai-codex",
        .model = "gpt-5.6-terra",
    }, .{});
    defer host.deinit();
    const initial_snapshot = host.snapshot();
    try std.testing.expectEqualStrings(root, initial_snapshot.cwd);
    try std.testing.expectEqualStrings("openai-codex", initial_snapshot.active_model.?.provider);
    try std.testing.expectEqualStrings("gpt-5.6-terra", initial_snapshot.active_model.?.model);
    const journal_path = try std.testing.allocator.dupe(u8, host.journal_path);
    defer std.testing.allocator.free(journal_path);

    try std.testing.expect((try host.submit("/model openai-codex/gpt-5.6-luna")) == .command);
    var recorder: HostTestRecorder = .{};
    var update = try host.drain("", recorder.sink());
    update.deinit();
    try std.testing.expect(recorder.saw_model_change);
    try std.testing.expectEqualStrings(journal_path, host.journal_path);
    const switched_snapshot = host.snapshot();
    try std.testing.expectEqualStrings("openai-codex", switched_snapshot.active_model.?.provider);
    try std.testing.expectEqualStrings("gpt-5.6-luna", switched_snapshot.active_model.?.model);
    try std.testing.expectEqual(ai.ThinkingLevel.medium, switched_snapshot.thinking_level.?);

    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".zi/agent/settings.json",
        .data = "{\"defaultThinkingLevel\":\"low\"}",
    });
    try std.testing.expect((try host.submit("/model openai-codex/gpt-5.6-luna")) == .command);
    var stable_update = try host.drain("", recorder.sink());
    stable_update.deinit();
    try std.testing.expectEqual(ai.ThinkingLevel.medium, host.snapshot().thinking_level.?);

    try std.testing.expectError(error.UnsupportedThinkingLevel, host.submit("/thinking max"));
    try std.testing.expectEqual(ai.ThinkingLevel.medium, host.snapshot().thinking_level.?);

    try std.testing.expect((try host.submit("/thinking high")) == .command);
    var thinking_update = try host.drain("", recorder.sink());
    thinking_update.deinit();
    try std.testing.expectEqual(ai.ThinkingLevel.high, host.snapshot().thinking_level.?);

    const journal = try std.Io.Dir.readFileAlloc(
        .cwd(),
        std.testing.io,
        journal_path,
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(journal);
    try std.testing.expect(std.mem.count(u8, journal, "model_change") == 2);
    try std.testing.expect(std.mem.count(u8, journal, "thinking_level_change") == 3);
    try std.testing.expect(std.mem.find(u8, journal, "gpt-5.6-terra") != null);
    try std.testing.expect(std.mem.find(u8, journal, "gpt-5.6-luna") != null);

    const settings_path = try std.fs.path.resolve(
        std.testing.allocator,
        &.{ root, ".zi/agent/settings.json" },
    );
    defer std.testing.allocator.free(settings_path);
    const settings = try std.Io.Dir.readFileAlloc(
        .cwd(),
        std.testing.io,
        settings_path,
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(settings);
    try std.testing.expect(std.mem.find(u8, settings, "gpt-5.6-luna") != null);

    const last_path_byte = &host.journal_path[host.journal_path.len - 1];
    last_path_byte.* = if (last_path_byte.* == 'x') 'y' else 'x';
    try std.testing.expect((try host.submit("/thinking low")) == .command);
    var failed_update = try host.drain("", recorder.sink());
    failed_update.deinit();
    try std.testing.expect(recorder.saw_switch_failure);
    try std.testing.expect(recorder.saw_unavailable);
    try std.testing.expect(host.snapshot().phase == .unavailable);
}

test "host transcript remains valid after replacing its initial backend" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try hostTestRoot(&temporary, &root_buffer);
    var paths = try ZiPaths.init(std.testing.allocator, root, root);
    defer paths.deinit();
    try CredentialStore.put(std.testing.allocator, std.testing.io, &paths, .{
        .provider_id = "openai-codex",
        .credential = .{ .oauth = .{
            .access = "fresh-access",
            .refresh = "fresh-refresh",
            .expires_at_ms = std.math.maxInt(u64),
            .account_id = "account",
        } },
    });
    var sources: HostTestSources = .{};
    const initial = try createHostForTest(root, sources.view(), .{
        .provider = "openai-codex",
        .model = "gpt-5.6-terra",
    }, .{});
    const journal_path = try std.testing.allocator.dupe(u8, initial.journal_path);
    defer std.testing.allocator.free(journal_path);
    initial.deinit();

    var inputs = try ReopenInputs.init(std.testing.allocator, .{
        .startup_cwd = root,
        .home = root,
        .session = .{ .open = journal_path },
        .sources = sources.view(),
    });
    var lifecycle = try RuntimeServices.createInteractive(
        std.testing.allocator,
        std.testing.io,
        inputs.initial(),
    );
    const transcript_items = lifecycle.transcript().items.ptr;
    const host = try InteractiveSessionHost.init(
        std.testing.allocator,
        std.testing.io,
        &inputs,
        &lifecycle,
        .{},
    );
    defer host.deinit();
    const transcript_view = host.transcript();
    try std.testing.expect(transcript_view.items.len != 0);
    try std.testing.expect(transcript_view.items.ptr == transcript_items);
    try std.testing.expectEqualStrings(
        "gpt-5.6-terra",
        transcript_view.items[0].content.model_change.model,
    );

    try std.testing.expect((try host.submit("/model openai-codex/gpt-5.6-luna")) == .command);
    var recorder: HostTestRecorder = .{};
    var update = try host.drain("", recorder.sink());
    update.deinit();
    try std.testing.expect(host.transcript() == transcript_view);
    try std.testing.expectEqualStrings(
        "gpt-5.6-terra",
        transcript_view.items[0].content.model_change.model,
    );
}

test "undrained control facts reject more than sixteen commands without growing pending state" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try hostTestRoot(&temporary, &root_buffer);
    var sources: HostTestSources = .{};
    const host = try createHostForTest(root, sources.view(), null, .{});
    defer host.deinit();

    try std.testing.expect((try host.submit("/model missing-provider/missing-model")) == .command);
    const pending_count = host.pending.items.len;
    try std.testing.expect(pending_count != 0);
    for (0..32) |index| {
        const command = if (index % 2 == 0)
            "/model missing-provider/another-model"
        else
            "/login missing-provider";
        try std.testing.expectError(error.CommandBusy, host.submit(command));
        try std.testing.expectEqual(pending_count, host.pending.items.len);
    }

    var recorder: HostTestRecorder = .{};
    var update = try host.drain("", recorder.sink());
    update.deinit();
    const snapshot = host.snapshot();
    try std.testing.expect(snapshot.phase == .model_less);
    try std.testing.expect(snapshot.active_model == null);
    try std.testing.expectEqualStrings(root, snapshot.cwd);
}

test "failed model switch recovers model-less state from the same journal" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try hostTestRoot(&temporary, &root_buffer);
    var sources: HostTestSources = .{};
    const host = try createHostForTest(root, sources.view(), null, .{});
    defer host.deinit();
    const journal_path = try std.testing.allocator.dupe(u8, host.journal_path);
    defer std.testing.allocator.free(journal_path);

    try std.testing.expect((try host.submit("/model missing-provider/missing-model")) == .command);
    var recorder: HostTestRecorder = .{};
    var update = try host.drain("", recorder.sink());
    update.deinit();
    try std.testing.expect(recorder.saw_switch_failure);
    try std.testing.expect(recorder.saw_model_less);
    try std.testing.expect(host.snapshot().phase == .model_less);
    try std.testing.expectEqualStrings(journal_path, host.journal_path);
    try std.testing.expectError(error.ModelSelectionRequired, host.submit("/unknown stays a prompt"));
}

test "auth delivery and settlement retry without repeating lifecycle mutation" {
    const answer = "retry-answer-secret";
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try hostTestRoot(&temporary, &root_buffer);
    const access = try hostTestAccessToken(std.testing.allocator);
    defer std.testing.allocator.free(access);
    const body = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"access_token\":\"{s}\",\"refresh_token\":\"refresh\",\"expires_in\":3600}}",
        .{access},
    );
    defer std.testing.allocator.free(body);
    const exchanges = [_]ai.transport_testing.Exchange{.{ .response = .{ .status = 200, .body = body } }};
    var fake = ai.transport_testing.FakeTransport.init(&exchanges);
    var sources: HostTestSources = .{};
    const host = try createHostForTest(root, sources.view(), null, .{
        .auth_transport = fake.transport(),
    });
    defer host.deinit();
    try std.testing.expect((try host.submit("/login openai-codex")) == .command);

    var recorder: RetryAuthRecorder = .{ .host = host, .answer = answer };
    var checked_single_transition = false;
    for (0..5_000) |_| {
        if (host.hasPendingFacts()) {
            var update = host.drain("", recorder.sink()) catch |failure| {
                try std.testing.expectEqual(error.Injected, failure);
                if (recorder.login_attempts == 1 and !checked_single_transition) {
                    const journal = try std.Io.Dir.readFileAlloc(
                        .cwd(),
                        std.testing.io,
                        host.journal_path,
                        std.testing.allocator,
                        .unlimited,
                    );
                    defer std.testing.allocator.free(journal);
                    try std.testing.expectEqual(
                        @as(usize, 1),
                        std.mem.count(u8, journal, "model_change"),
                    );
                    checked_single_transition = true;
                }
                try std.testing.io.sleep(.fromMilliseconds(1), .awake);
                continue;
            };
            update.deinit();
        }
        if (recorder.model_order != null) break;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }

    try std.testing.expect(checked_single_transition);
    try std.testing.expectEqual(@as(usize, 2), recorder.auth_url_attempts);
    try std.testing.expectEqual(@as(usize, 2), recorder.prompt_attempts);
    try std.testing.expectEqual(@as(usize, 2), recorder.login_attempts);
    try std.testing.expect(recorder.auth_url_order.? < recorder.prompt_order.?);
    try std.testing.expect(recorder.prompt_order.? < recorder.login_order.?);
    try std.testing.expect(recorder.login_order.? < recorder.model_order.?);
    try std.testing.expect(host.snapshot().phase == .turn);

    const journal = try std.Io.Dir.readFileAlloc(
        .cwd(),
        std.testing.io,
        host.journal_path,
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(journal);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, journal, "model_change"));
}

test "device auth fact retries before cancellation settles" {
    const BlockingDeviceTransport = struct {
        const Self = @This();

        calls: usize = 0,

        pub fn exchange(
            self: *Self,
            allocator: std.mem.Allocator,
            io: std.Io,
            request: ai.transport.Request,
            _: ai.transport.Delivery,
        ) ai.transport.Error!ai.transport.Response {
            self.calls += 1;
            if (self.calls == 1) return .{
                .status = 200,
                .body = try allocator.dupe(
                    u8,
                    "{\"device_auth_id\":\"device\",\"user_code\":\"CODE\",\"interval\":5}",
                ),
            };
            while (request.cancellation) |cancellation| {
                if (cancellation.isCancelled()) return error.Cancelled;
                io.sleep(.fromMilliseconds(1), .awake) catch return error.Cancelled;
            } else return error.InvalidRequest;
        }
    };

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try hostTestRoot(&temporary, &root_buffer);
    var transport: BlockingDeviceTransport = .{};
    var sources: HostTestSources = .{};
    const host = try createHostForTest(root, sources.view(), null, .{
        .auth_transport = ai.transport.Transport.from(&transport),
    });
    defer host.deinit();
    try std.testing.expect((try host.submit("/login openai-codex --device")) == .command);

    var recorder: DeviceRetryRecorder = .{ .host = host };
    for (0..5_000) |_| {
        if (host.hasPendingFacts()) {
            var update = host.drain("", recorder.sink()) catch |failure| {
                try std.testing.expectEqual(error.Injected, failure);
                continue;
            };
            update.deinit();
        }
        if (recorder.saw_cancelled) break;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqual(@as(usize, 2), recorder.device_attempts);
    try std.testing.expect(recorder.saw_cancelled);
    try std.testing.expect(host.snapshot().phase == .model_less);
}

test "background login activates the original journal without exposing the answer" {
    const answer = "oauth-answer-secret";
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try hostTestRoot(&temporary, &root_buffer);
    const access = try hostTestAccessToken(std.testing.allocator);
    defer std.testing.allocator.free(access);
    const body = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"access_token\":\"{s}\",\"refresh_token\":\"refresh\",\"expires_in\":3600}}",
        .{access},
    );
    defer std.testing.allocator.free(body);
    const exchanges = [_]ai.transport_testing.Exchange{.{ .response = .{ .status = 200, .body = body } }};
    var fake = ai.transport_testing.FakeTransport.init(&exchanges);
    var sources: HostTestSources = .{};
    const host = try createHostForTest(root, sources.view(), null, .{
        .auth_transport = fake.transport(),
    });
    defer host.deinit();
    const journal_path = try std.testing.allocator.dupe(u8, host.journal_path);
    defer std.testing.allocator.free(journal_path);
    try std.testing.expect((try host.submit("/login openai-codex")) == .command);
    try std.testing.expectError(
        error.CommandBusy,
        host.submit("/model openai-codex/gpt-5.6-terra"),
    );

    var recorder: HostTestRecorder = .{ .host = host, .answer = answer };
    for (0..5_000) |_| {
        if (host.hasPendingFacts()) {
            var update = try host.drain("", recorder.sink());
            update.deinit();
        }
        if (recorder.saw_login_success and recorder.saw_model_change) break;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(recorder.answered);
    try std.testing.expect(recorder.saw_login_success);
    try std.testing.expect(recorder.saw_model_change);
    try std.testing.expect(host.snapshot().phase == .turn);
    try std.testing.expectEqualStrings(journal_path, host.journal_path);

    const journal = try std.Io.Dir.readFileAlloc(
        .cwd(),
        std.testing.io,
        journal_path,
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(journal);
    try std.testing.expect(std.mem.find(u8, journal, answer) == null);
    const auth_path = try std.fs.path.resolve(
        std.testing.allocator,
        &.{ root, ".zi/agent/auth.json" },
    );
    defer std.testing.allocator.free(auth_path);
    const auth_source = try std.Io.Dir.readFileAlloc(
        .cwd(),
        std.testing.io,
        auth_path,
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(auth_source);
    try std.testing.expect(std.mem.find(u8, auth_source, answer) == null);
}

test "interactive host decodes matched login and model commands" {
    try std.testing.expect((try InteractiveSessionHost.parseCommand("/login openai-codex")) == .login);
    try std.testing.expectEqual(
        ai.oauth.LoginMethod.device_code,
        (try InteractiveSessionHost.parseCommand("/login openai-codex --device")).login.method,
    );
    const selection = (try InteractiveSessionHost.parseCommand("/model openai/gpt-5.6-sol")).model;
    try std.testing.expectEqualStrings("openai", selection.provider);
    try std.testing.expectEqualStrings("gpt-5.6-sol", selection.model);
    try std.testing.expect((try InteractiveSessionHost.parseCommand("/unknown value")) == .ordinary);
    try std.testing.expectError(error.InvalidCommand, InteractiveSessionHost.parseCommand("/model missing-slash"));
    try std.testing.expectError(error.InvalidCommand, InteractiveSessionHost.parseCommand("/login provider --bad"));
}

const TestSessionOwner = struct {
    allocator: std.mem.Allocator,
    session_value: AgentSession,

    fn create(
        allocator: std.mem.Allocator,
        model: ai.model.Model,
        cwd: std.Io.Dir,
    ) !*TestSessionOwner {
        const self = try allocator.create(TestSessionOwner);
        errdefer allocator.destroy(self);
        // The session takes ownership of its own dedicated handle so the
        // caller's TmpDir handle is not closed twice.
        const session_cwd = try cwd.openDir(std.testing.io, ".", .{});
        self.* = .{
            .allocator = allocator,
            .session_value = try AgentSession.init(allocator, std.testing.io, model, session_cwd, .{}),
        };
        return self;
    }

    pub fn session(self: *TestSessionOwner) *AgentSession {
        return &self.session_value;
    }

    // Heap destruction follows explicit field invalidation.
    // ziglint-ignore: Z030
    pub fn deinit(self: *TestSessionOwner) void {
        const allocator = self.allocator;
        self.session_value.deinit();
        self.* = undefined;
        allocator.destroy(self);
    }
};

const TestSink = struct {
    event_count: usize = 0,
    completion_count: usize = 0,
    saw_agent_end: bool = false,

    fn emit(context: *anyopaque, fact: SessionController.Fact) !void {
        const self: *TestSink = @ptrCast(@alignCast(context));
        switch (fact) {
            .event => |event| {
                self.event_count += 1;
                if (event == .agent_end) self.saw_agent_end = true;
            },
            .completion => |completion| {
                self.completion_count += 1;
                try std.testing.expect(completion.agent_end_observed);
            },
            .fault => return error.UnexpectedFault,
        }
    }

    fn sink(self: *TestSink) SessionController.Sink {
        return .{ .context = self, .emitFn = emit };
    }
};

const RetrySink = struct {
    sequence: usize = 0,
    start_attempts: usize = 0,
    end_attempts: usize = 0,
    completion_attempts: usize = 0,
    start_order: ?usize = null,
    end_order: ?usize = null,
    completion_order: ?usize = null,

    fn emit(context: *anyopaque, fact: SessionController.Fact) !void {
        const self: *RetrySink = @ptrCast(@alignCast(context));
        switch (fact) {
            .event => |event| switch (event) {
                .agent_start => {
                    self.start_attempts += 1;
                    if (self.start_attempts == 1) return error.Injected;
                    self.start_order = self.nextOrder();
                },
                .agent_end => {
                    self.end_attempts += 1;
                    if (self.end_attempts == 1) return error.Injected;
                    self.end_order = self.nextOrder();
                },
                else => {},
            },
            .completion => {
                self.completion_attempts += 1;
                if (self.completion_attempts == 1) return error.Injected;
                self.completion_order = self.nextOrder();
            },
            .fault => return error.UnexpectedFault,
        }
    }

    fn nextOrder(self: *RetrySink) usize {
        const result = self.sequence;
        self.sequence += 1;
        return result;
    }

    fn sink(self: *RetrySink) SessionController.Sink {
        return .{ .context = self, .emitFn = emit };
    }
};

test "session controller drives a worker without frontend state" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var scripted: ai.testing.ScriptedModel = .{
        .identity = .{ .provider = "script", .model = "controller" },
        .steps = &.{.{ .text = "answer" }},
    };
    const owner = try TestSessionOwner.create(
        std.testing.allocator,
        scripted.asModel(),
        temporary.dir,
    );
    var worker = try TurnWorker.start(
        std.testing.allocator,
        std.testing.io,
        TurnWorker.SessionOwner.from(owner),
        .{},
    );
    defer worker.deinit();
    var controller = try SessionController.init(
        std.testing.allocator,
        worker,
        SessionPolicy.default_limits,
    );
    defer controller.deinit();

    try std.testing.expectEqual(SessionController.SubmitDisposition.started, try controller.submit("hello"));
    var sink: TestSink = .{};
    var settled = false;
    for (0..10_000) |_| {
        var update = try controller.drain("", sink.sink());
        update.deinit();
        const snapshot = worker.snapshot();
        if (!snapshot.processing and
            snapshot.queued_prompts == 0 and
            snapshot.queued_events == 0 and
            snapshot.queued_completions == 0 and
            controller.phase() == .idle)
        {
            settled = true;
            break;
        }
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    try std.testing.expect(settled);
    try std.testing.expect(sink.saw_agent_end);
    try std.testing.expectEqual(@as(usize, 1), sink.completion_count);
}

test "session controller retries prepared turn facts without repeating policy transitions" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var scripted: ai.testing.ScriptedModel = .{
        .identity = .{ .provider = "script", .model = "controller-retry" },
        .steps = &.{.{ .text = "answer" }},
    };
    const owner = try TestSessionOwner.create(
        std.testing.allocator,
        scripted.asModel(),
        temporary.dir,
    );
    var worker = try TurnWorker.start(
        std.testing.allocator,
        std.testing.io,
        TurnWorker.SessionOwner.from(owner),
        .{},
    );
    defer worker.deinit();
    var controller = try SessionController.init(
        std.testing.allocator,
        worker,
        SessionPolicy.default_limits,
    );
    defer controller.deinit();

    try std.testing.expectEqual(SessionController.SubmitDisposition.started, try controller.submit("hello"));
    var sink: RetrySink = .{};
    var saw_completion_failure_at_idle = false;
    var settled = false;
    for (0..10_000) |_| {
        var update = controller.drain("", sink.sink()) catch |failure| {
            try std.testing.expectEqual(error.Injected, failure);
            if (sink.completion_attempts == 1) {
                try std.testing.expect(controller.phase() == .idle);
                saw_completion_failure_at_idle = true;
            }
            std.Thread.yield() catch std.atomic.spinLoopHint();
            continue;
        };
        update.deinit();
        const snapshot = worker.snapshot();
        if (!snapshot.processing and
            snapshot.queued_prompts == 0 and
            !controller.hasPendingFacts() and
            controller.phase() == .idle)
        {
            settled = true;
            break;
        }
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }

    try std.testing.expect(settled);
    try std.testing.expect(saw_completion_failure_at_idle);
    try std.testing.expectEqual(@as(usize, 2), sink.start_attempts);
    try std.testing.expectEqual(@as(usize, 2), sink.end_attempts);
    try std.testing.expectEqual(@as(usize, 2), sink.completion_attempts);
    try std.testing.expect(sink.start_order.? < sink.end_order.?);
    try std.testing.expect(sink.end_order.? < sink.completion_order.?);
    try std.testing.expect(controller.phase() == .idle);
}

test {
    _ = SessionPolicy;
}
