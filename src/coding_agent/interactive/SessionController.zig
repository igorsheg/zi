const std = @import("std");
const ai = @import("../../ai/root.zig");
const agent = @import("../../agent/root.zig");
const AgentSession = @import("../AgentSession.zig");
const session_event = @import("../AgentSessionEvent.zig");
const SessionPolicy = @import("SessionPolicy.zig");
const TurnWorker = @import("../TurnWorker.zig");

pub const SessionController = @This();

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
    ModelSelectionRequired,
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

const Backend = union(enum) {
    model_less,
    runnable: *TurnWorker,
};

allocator: std.mem.Allocator,
backend: Backend,
policy: SessionPolicy,

pub fn init(
    allocator: std.mem.Allocator,
    worker: *TurnWorker,
    limits: SessionPolicy.Limits,
) InitError!SessionController {
    return .{
        .allocator = allocator,
        .backend = .{ .runnable = worker },
        .policy = try SessionPolicy.init(allocator, limits),
    };
}

pub fn initModelLess(
    allocator: std.mem.Allocator,
    limits: SessionPolicy.Limits,
) InitError!SessionController {
    return .{
        .allocator = allocator,
        .backend = .model_less,
        .policy = try SessionPolicy.init(allocator, limits),
    };
}

pub fn deinit(self: *SessionController) void {
    self.policy.deinit();
    self.* = undefined;
}

pub fn phase(self: *const SessionController) Phase {
    return self.policy.phase();
}

pub fn queuedFollowUpCount(self: *const SessionController) usize {
    return self.policy.queuedFollowUps().len;
}

pub fn queuedFollowUp(self: *const SessionController, index: usize) ?[]const u8 {
    const queued = self.policy.queuedFollowUps();
    if (index >= queued.len) return null;
    return queued[index];
}

pub fn hasPendingFacts(self: *SessionController) bool {
    const worker = switch (self.backend) {
        .model_less => return false,
        .runnable => |value| value,
    };
    const snapshot = worker.snapshot();
    return snapshot.queued_events != 0 or snapshot.queued_completions != 0;
}

/// Admits a prompt transactionally. The caller may clear its editor only after
/// this function succeeds.
pub fn submit(
    self: *SessionController,
    prompt: []const u8,
) SubmitError!SubmitDisposition {
    const worker = switch (self.backend) {
        .model_less => return error.ModelSelectionRequired,
        .runnable => |value| value,
    };
    var prepared = try self.policy.prepareSubmission(prompt);
    var prepared_live = true;
    defer if (prepared_live) prepared.deinit();

    const disposition: SubmitDisposition = switch (prepared.route) {
        .start => started: {
            try worker.submit(prepared.text);
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
pub fn cancel(
    self: *SessionController,
    current_draft: []const u8,
) CancelError!?OwnedDraft {
    const result = try self.policy.escape(current_draft);
    if (result.request_cancel) switch (self.backend) {
        .model_less => {},
        .runnable => |worker| _ = worker.requestCancel(),
    };
    return result.restored;
}

/// Reduces one detached worker batch in contractual order. The controller owns
/// interactive transitions and worker effects; the client only consumes facts.
pub fn drain(
    self: *SessionController,
    current_draft: []const u8,
    sink: Sink,
) !DrainResult {
    if (!self.hasPendingFacts()) return .{};

    const worker = switch (self.backend) {
        .model_less => return .{},
        .runnable => |value| value,
    };
    var batch = try worker.takeBatch();
    defer batch.deinit(self.allocator);
    var result: DrainResult = .{};
    errdefer result.deinit();

    for (batch.events.items) |owned| {
        const reduced = self.policy.applyEvent(owned.value);
        if (reduced.admission == .stale) continue;
        try sink.emit(.{ .event = owned.value });
        try self.applyEffect(reduced.effect, current_draft, sink, &result);
    }
    for (batch.completions.items) |completion| {
        const reduced = self.policy.applyCompletion(completion.run_id, completion.availability);
        if (reduced.admission == .stale) continue;
        try sink.emit(.{ .completion = .{
            .value = completion,
            .agent_end_observed = batchContainsAgentEnd(&batch, completion.run_id),
        } });
        try self.applyEffect(reduced.effect, current_draft, sink, &result);
    }
    return result;
}

fn applyEffect(
    self: *SessionController,
    effect: SessionPolicy.Effect,
    current_draft: []const u8,
    sink: Sink,
    result: *DrainResult,
) !void {
    switch (effect) {
        .none => {},
        .request_cancel => switch (self.backend) {
            .model_less => {},
            .runnable => |worker| _ = worker.requestCancel(),
        },
        .submit_follow_up => |prompt| {
            const worker = switch (self.backend) {
                .model_less => return,
                .runnable => |value| value,
            };
            worker.submit(prompt) catch |failure| {
                self.policy.rejectFollowUpSubmission();
                try sink.emit(.{ .fault = .{ .follow_up_submission = failure } });
                return;
            };
            self.policy.confirmFollowUpSubmission();
        },
        .session_poisoned => {
            std.debug.assert(result.restored == null);
            result.restored = self.policy.restoreQueued(current_draft) catch |failure| {
                try sink.emit(.{ .fault = .{ .draft_restore = failure } });
                return;
            };
        },
    }
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
        self.* = .{
            .allocator = allocator,
            .session_value = try AgentSession.init(allocator, std.testing.io, model, cwd, .{}),
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

    fn emit(context: *anyopaque, fact: Fact) !void {
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

    fn sink(self: *TestSink) Sink {
        return .{ .context = self, .emitFn = emit };
    }
};

test "model-less controller rejects prompts without changing draft policy" {
    var controller = try SessionController.initModelLess(
        std.testing.allocator,
        SessionPolicy.default_limits,
    );
    defer controller.deinit();

    try std.testing.expectError(error.ModelSelectionRequired, controller.submit("keep this draft"));
    try std.testing.expect(!controller.hasPendingFacts());
    try std.testing.expectEqual(SessionPolicy.Phase.idle, controller.phase());
}

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

    try std.testing.expectEqual(SubmitDisposition.started, try controller.submit("hello"));
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
