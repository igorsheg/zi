const std = @import("std");
const ai = @import("../../ai/root.zig");
const AuthOperation = @import("../AuthOperation.zig");
const CredentialStore = @import("../CredentialStore.zig");
const ReopenInputs = @import("../ReopenInputs.zig");
const RuntimeServices = @import("../RuntimeServices.zig");
const SessionController = @import("SessionController.zig").SessionController;
const SessionPolicy = @import("SessionPolicy.zig");
const SessionFormat = @import("../SessionFormat.zig");
const SessionTranscript = @import("../SessionTranscript.zig");
const SettingsStore = @import("../SettingsStore.zig");
const TurnWorker = @import("../TurnWorker.zig");
const ZiPaths = @import("../ZiPaths.zig");

const InteractiveSessionHost = @This();

const max_identifier_bytes = 512;
const max_pending_facts = 16;

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

pub const Snapshot = struct {
    phase: Phase,
    queued_follow_ups: usize,
    mask_composer: bool,
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

    pub fn emit(self: Sink, fact: Fact) !void {
        try self.emit_fn(self.context, fact);
    }
};

pub const DrainResult = struct {
    restored: ?SessionController.OwnedDraft = null,

    pub fn deinit(self: *DrainResult) void {
        if (self.restored) |*draft| draft.deinit();
        self.* = undefined;
    }
};

const ModelLessBackend = struct {
    runtime: *RuntimeServices.ModelLess,
    active_model: ?FixedModel,
};

const Runnable = struct {
    worker: *TurnWorker,
    controller: SessionController,
    active_model: FixedModel,
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
    model_changed: FixedModel,
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
            .model_changed => |*selection| .{ .model_changed = selection.view() },
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
    login: struct {
        provider: []const u8,
        method: ai.oauth.LoginMethod,
    },
    model: ai.ModelIdentity,
};

allocator: std.mem.Allocator,
io: std.Io,
inputs: ReopenInputs,
settings_paths: ZiPaths,
journal_path: []u8,
initial_transcript: *const SessionTranscript,
backend: Backend = .transitioning,
auth: ?*AuthOperation = null,
auth_started_pending: bool = false,
auth_outcome: ?AuthOperation.Outcome = null,
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
    const owned_lifecycle = lifecycle.*;
    lifecycle.* = undefined;
    var lifecycle_live = true;
    errdefer if (lifecycle_live) owned_lifecycle.deinit();

    const journal_path = try allocator.dupe(u8, owned_lifecycle.journalPath());
    errdefer allocator.free(journal_path);
    var settings_paths = try ZiPaths.init(
        allocator,
        owned_inputs.initial().startup_cwd,
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
        .initial_transcript = owned_lifecycle.transcript(),
        .options = options,
    };
    inputs_live = false;
    errdefer self.inputs.deinit();
    try self.pending.ensureTotalCapacity(allocator, max_pending_facts);
    errdefer self.pending.deinit(allocator);
    self.installLifecycle(owned_lifecycle) catch |failure| {
        lifecycle_live = false;
        return failure;
    };
    lifecycle_live = false;
    return self;
}

pub fn transcript(self: *const InteractiveSessionHost) *const SessionTranscript {
    return self.initial_transcript;
}

pub fn snapshot(self: *InteractiveSessionHost) Snapshot {
    if (self.auth) |operation| return .{
        .phase = .authenticating,
        .queued_follow_ups = self.queuedFollowUps(),
        .mask_composer = operation.isAwaitingAnswer(),
    };
    return switch (self.backend) {
        .model_less => .{ .phase = .model_less, .queued_follow_ups = 0, .mask_composer = false },
        .runnable => |*runnable| .{
            .phase = .{ .turn = runnable.controller.phase() },
            .queued_follow_ups = runnable.controller.queuedFollowUpCount(),
            .mask_composer = false,
        },
        .transitioning => .{ .phase = .transitioning, .queued_follow_ups = 0, .mask_composer = false },
        .unavailable => .{ .phase = .unavailable, .queued_follow_ups = 0, .mask_composer = false },
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
    if (self.auth_started_pending or self.auth_outcome != null or self.pending.items.len != 0) return true;
    if (self.auth) |operation| if (operation.hasPending()) return true;
    return switch (self.backend) {
        .runnable => |*runnable| runnable.controller.hasPendingFacts(),
        .model_less, .transitioning, .unavailable => false,
    };
}

/// Admits commands and turns transactionally. OAuth answers use a separate
/// disposition so the client can wipe, rather than merely clear, its editor.
pub fn submit(self: *InteractiveSessionHost, source: []const u8) SubmitError!SubmitDisposition {
    const text = std.mem.trim(u8, source, " \t\r\n");
    if (text.len == 0) return error.EmptyPrompt;
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

    switch (try parseCommand(text)) {
        .ordinary => {},
        .login => |command| {
            if (!self.isQuiescent()) return error.CommandBusy;
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
            self.auth_started_pending = true;
            return .command;
        },
        .model => |selection| {
            if (!self.isQuiescent()) return error.CommandBusy;
            try self.switchModel(selection);
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

    if (self.auth_started_pending) {
        const operation = self.auth.?;
        try sink.emit(.{ .auth_started = .{
            .provider = operation.provider(),
            .method = operation.loginMethod(),
        } });
        self.auth_started_pending = false;
    }

    if (self.auth) |operation| {
        if (operation.hasPending()) {
            var batch = try operation.takeBatch();
            defer batch.deinit();
            if (batch.outcome) |outcome| self.auth_outcome = outcome;
            for (0..batch.len()) |index| {
                const fact_value = batch.fact(index);
                try sink.emit(switch (fact_value) {
                    .auth_url, .device_code, .prompt => .{ .auth_interaction = fact_value },
                });
            }
        }
        if (self.auth_outcome) |outcome| {
            try self.settleAuth(outcome, sink);
            self.auth_outcome = null;
        }
    }

    while (self.pending.items.len != 0) {
        const fact_value = self.pending.orderedRemove(0);
        try sink.emit(fact_value.view());
    }

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
    self.deinitBackend();
    self.pending.deinit(self.allocator);
    self.allocator.free(self.journal_path);
    self.settings_paths.deinit();
    self.inputs.deinit();
    const allocator = self.allocator;
    self.* = undefined;
    allocator.destroy(self);
}

fn settleAuth(self: *InteractiveSessionHost, outcome: AuthOperation.Outcome, sink: Sink) !void {
    const operation = self.auth.?;
    const provider = operation.provider();
    switch (outcome) {
        .cancelled => try sink.emit(.{ .auth_cancelled = .{ .provider = provider } }),
        .failed => |failure| try sink.emit(.{ .login_failed = .{
            .provider = provider,
            .failure = failure,
        } }),
        .succeeded => {
            try sink.emit(.{ .login_succeeded = .{ .provider = provider } });
            self.closeForTransition();
            const lifecycle = RuntimeServices.createInteractive(
                self.allocator,
                self.io,
                self.inputs.reopen(self.journal_path, .{}),
            ) catch |failure| {
                self.backend = .unavailable;
                try sink.emit(.{ .session_unavailable = .{ .reason = @errorName(failure) } });
                operation.deinit();
                self.auth = null;
                return;
            };
            self.installLifecycle(lifecycle) catch |failure| {
                self.backend = .unavailable;
                try sink.emit(.{ .session_unavailable = .{ .reason = @errorName(failure) } });
                operation.deinit();
                self.auth = null;
                return;
            };
            switch (self.backend) {
                .runnable => |*runnable| try sink.emit(.{
                    .model_changed = runnable.active_model.view(),
                }),
                .model_less => try sink.emit(.model_less),
                .transitioning, .unavailable => unreachable,
            }
        },
    }
    operation.deinit();
    self.auth = null;
}

fn switchModel(self: *InteractiveSessionHost, requested: ai.ModelIdentity) !void {
    const requested_copy = try FixedModel.init(requested);
    self.closeForTransition();
    const lifecycle = RuntimeServices.createInteractive(
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
    self.appendPending(.{ .model_changed = canonical_copy });
    SettingsStore.setGlobalDefaultModel(
        self.allocator,
        self.io,
        &self.settings_paths,
        canonical.provider,
        canonical.model,
    ) catch |failure| switch (failure) {
        error.CommitIndeterminate => self.appendPending(.{
            .settings_commit_indeterminate = canonical_copy,
        }),
        else => self.appendPending(.{ .settings_failed = .{
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
    const lifecycle = RuntimeServices.createInteractive(
        self.allocator,
        self.io,
        self.inputs.reopen(self.journal_path, .{}),
    ) catch |recovery_failure| {
        self.backend = .unavailable;
        self.appendSwitchFailure(requested, failure);
        self.appendPending(.{ .session_unavailable = .{ .reason = @errorName(recovery_failure) } });
        return;
    };
    self.installLifecycle(lifecycle) catch |recovery_failure| {
        self.backend = .unavailable;
        self.appendSwitchFailure(requested, failure);
        self.appendPending(.{ .session_unavailable = .{ .reason = @errorName(recovery_failure) } });
        return;
    };
    self.appendSwitchFailure(requested, failure);
    if (self.activeModel()) |model| {
        self.appendPending(.{ .model_changed = try FixedModel.init(model) });
    } else {
        self.appendPending(.model_less);
    }
}

fn appendSwitchFailure(self: *InteractiveSessionHost, requested: FixedModel, failure: anyerror) void {
    if (failure == error.CommitIndeterminate) {
        self.appendPending(.{ .model_switch_commit_indeterminate = requested });
    } else {
        self.appendPending(.{ .model_switch_failed = .{
            .requested = requested,
            .reason = @errorName(failure),
        } });
    }
}

fn installLifecycle(self: *InteractiveSessionHost, lifecycle: RuntimeServices.Interactive) !void {
    std.debug.assert(self.backend == .transitioning);
    const active_model = if (lifecycle.activeModel()) |model|
        FixedModel.init(model) catch |failure| {
            lifecycle.deinit();
            return failure;
        }
    else
        null;
    switch (lifecycle) {
        .model_less => |runtime| self.backend = .{ .model_less = .{
            .runtime = runtime,
            .active_model = active_model,
        } },
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
            } };
        },
    }
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
        .model_less => |runtime| runtime.runtime.deinit(),
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

fn appendPending(self: *InteractiveSessionHost, fact: PendingFact) void {
    std.debug.assert(self.pending.items.len < max_pending_facts);
    self.pending.appendAssumeCapacity(fact);
}

fn parseCommand(text: []const u8) error{ InvalidCommand, IdentifierTooLong }!ParsedCommand {
    var words = std.mem.tokenizeAny(u8, text, " \t\r\n");
    const command = words.next() orelse return .ordinary;
    if (std.mem.eql(u8, command, "/login")) {
        const provider = words.next() orelse return error.InvalidCommand;
        _ = try FixedText.init(provider);
        const option = words.next();
        if (words.next() != null) return error.InvalidCommand;
        const method: ai.oauth.LoginMethod = if (option) |value| method: {
            if (!std.mem.eql(u8, value, "--device")) return error.InvalidCommand;
            break :method .device_code;
        } else .browser;
        return .{ .login = .{ .provider = provider, .method = method } };
    }
    if (std.mem.eql(u8, command, "/model")) {
        const target = words.next() orelse return error.InvalidCommand;
        if (words.next() != null) return error.InvalidCommand;
        const slash = std.mem.findScalar(u8, target, '/') orelse return error.InvalidCommand;
        if (slash == 0 or slash + 1 == target.len) return error.InvalidCommand;
        const selection: ai.ModelIdentity = .{
            .provider = target[0..slash],
            .model = target[slash + 1 ..],
        };
        _ = try FixedModel.init(selection);
        return .{ .model = selection };
    }
    return .ordinary;
}

fn emitTurnFact(context: *anyopaque, fact: SessionController.Fact) !void {
    const sink: *Sink = @ptrCast(@alignCast(context));
    try sink.emit(.{ .turn = fact });
}

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

const HostTestRecorder = struct {
    host: ?*InteractiveSessionHost = null,
    answer: ?[]const u8 = null,
    answered: bool = false,
    saw_login_success: bool = false,
    saw_model_change: bool = false,
    saw_model_less: bool = false,
    saw_switch_failure: bool = false,
    saw_auth_cancelled: bool = false,

    fn emit(context: *anyopaque, fact: Fact) !void {
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
            .session_unavailable => {},
        }
    }

    fn expectSafe(self: *const HostTestRecorder, value: []const u8) !void {
        if (self.answer) |answer| try std.testing.expect(std.mem.find(u8, value, answer) == null);
    }

    fn sink(self: *HostTestRecorder) Sink {
        return .{ .context = self, .emit_fn = emit };
    }
};

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
    options: Options,
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
    const journal_path = try std.testing.allocator.dupe(u8, host.journal_path);
    defer std.testing.allocator.free(journal_path);

    try std.testing.expect((try host.submit("/model openai-codex/gpt-5.6-luna")) == .command);
    var recorder: HostTestRecorder = .{};
    var update = try host.drain("", recorder.sink());
    update.deinit();
    try std.testing.expect(recorder.saw_model_change);
    try std.testing.expectEqualStrings(journal_path, host.journal_path);

    const journal = try std.Io.Dir.readFileAlloc(
        .cwd(),
        std.testing.io,
        journal_path,
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(journal);
    try std.testing.expect(std.mem.count(u8, journal, "model_change") == 2);
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
        error.AuthenticationBusy,
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

test "interactive command parser admits exact login and model commands" {
    try std.testing.expect((try parseCommand("/login openai-codex")) == .login);
    try std.testing.expectEqual(
        ai.oauth.LoginMethod.device_code,
        (try parseCommand("/login openai-codex --device")).login.method,
    );
    const selection = (try parseCommand("/model openai/gpt-5.6-sol")).model;
    try std.testing.expectEqualStrings("openai", selection.provider);
    try std.testing.expectEqualStrings("gpt-5.6-sol", selection.model);
    try std.testing.expect((try parseCommand("/unknown value")) == .ordinary);
    try std.testing.expectError(error.InvalidCommand, parseCommand("/model missing-slash"));
    try std.testing.expectError(error.InvalidCommand, parseCommand("/login provider --bad"));
}
