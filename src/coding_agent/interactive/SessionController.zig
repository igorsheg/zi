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

pub fn init(
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
    if (self.in_flight != null or self.prepared != null or self.pending_restored != null) return true;
    return workerHasPending(self.worker);
}

/// Admits a prompt transactionally. The caller may clear its editor only after
/// this function succeeds.
pub fn submit(
    self: *SessionController,
    prompt: []const u8,
) SubmitError!SubmitDisposition {
    var prepared = try self.policy.prepareSubmission(prompt);
    var prepared_live = true;
    defer if (prepared_live) prepared.deinit();

    const disposition: SubmitDisposition = switch (prepared.route) {
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
pub fn cancel(
    self: *SessionController,
    current_draft: []const u8,
) CancelError!?OwnedDraft {
    const result = try self.policy.escape(current_draft);
    if (result.request_cancel) _ = self.worker.requestCancel();
    return result.restored;
}

/// Reduces detached worker output in contractual order. A policy transition is
/// prepared once, then its borrowed fact remains retained until the sink accepts it.
pub fn drain(
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

const RetrySink = struct {
    sequence: usize = 0,
    start_attempts: usize = 0,
    end_attempts: usize = 0,
    completion_attempts: usize = 0,
    start_order: ?usize = null,
    end_order: ?usize = null,
    completion_order: ?usize = null,

    fn emit(context: *anyopaque, fact: Fact) !void {
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

    fn sink(self: *RetrySink) Sink {
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

    try std.testing.expectEqual(SubmitDisposition.started, try controller.submit("hello"));
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
