const std = @import("std");
const agent = @import("../../agent/root.zig");
const session_event = @import("../AgentSessionEvent.zig");

const SessionPolicy = @This();

pub const Limits = struct {
    max_prompt_bytes: usize = 1024 * 1024,
    max_follow_ups: usize = 16,
    max_follow_up_bytes: usize = 4 * 1024 * 1024,
    max_restored_draft_bytes: usize = 5 * 1024 * 1024,
};

pub const default_limits: Limits = .{};

pub const InitError = error{
    OutOfMemory,
    InvalidLimits,
};

pub const Error = error{
    OutOfMemory,
    EmptyPrompt,
    PromptTooLarge,
    FollowUpQueueFull,
    FollowUpQueueTooLarge,
    RestoredDraftTooLarge,
    SessionUnavailable,
    InvalidLimits,
};

pub const Phase = union(enum) {
    idle,
    awaiting_start,
    cancel_pending,
    running: agent.event.RunId,
    cancelling: agent.event.RunId,
    dispatching_follow_up,
    poisoned,
};

pub const SubmissionRoute = enum {
    start,
    follow_up,
};

pub const PreparedSubmission = struct {
    allocator: std.mem.Allocator,
    text: []u8,
    route: SubmissionRoute,
    live: bool = true,

    pub fn deinit(self: *PreparedSubmission) void {
        if (self.live) self.allocator.free(self.text);
        self.* = undefined;
    }

    fn transfer(self: *PreparedSubmission) []u8 {
        std.debug.assert(self.live);
        self.live = false;
        return self.text;
    }
};

pub const OwnedDraft = struct {
    allocator: std.mem.Allocator,
    text: []u8,
    restored_count: usize,

    pub fn deinit(self: *OwnedDraft) void {
        self.allocator.free(self.text);
        self.* = undefined;
    }
};

pub const EscapeResult = struct {
    request_cancel: bool,
    restored: ?OwnedDraft,
};

pub const Admission = enum {
    admit,
    stale,
};

pub const Effect = union(enum) {
    none,
    request_cancel,
    submit_follow_up: []const u8,
    session_poisoned,
};

pub const EventResult = struct {
    admission: Admission,
    effect: Effect = .none,
};

allocator: std.mem.Allocator,
limits: Limits,
phase_value: Phase = .idle,
follow_ups: std.ArrayList([]u8) = .empty,
follow_up_bytes: usize = 0,
settled_run_id: ?agent.event.RunId = null,

pub fn init(
    allocator: std.mem.Allocator,
    limits: Limits,
) InitError!SessionPolicy {
    if (limits.max_prompt_bytes == 0 or
        limits.max_follow_ups == 0 or
        limits.max_follow_up_bytes == 0 or
        limits.max_restored_draft_bytes < limits.max_prompt_bytes)
    {
        return error.InvalidLimits;
    }
    var follow_ups: std.ArrayList([]u8) = .empty;
    errdefer follow_ups.deinit(allocator);
    try follow_ups.ensureTotalCapacity(allocator, limits.max_follow_ups);
    return .{
        .allocator = allocator,
        .limits = limits,
        .follow_ups = follow_ups,
    };
}

pub fn deinit(self: *SessionPolicy) void {
    self.clearFollowUps();
    self.follow_ups.deinit(self.allocator);
    self.* = undefined;
}

pub fn phase(self: *const SessionPolicy) Phase {
    return self.phase_value;
}

pub fn queuedFollowUps(self: *const SessionPolicy) []const []u8 {
    return self.follow_ups.items;
}

/// Copies and validates editor text without mutating policy. The caller clears
/// the editor only after `commitSubmission` succeeds. A start-route prompt must
/// first be accepted by `TurnWorker.submit`.
pub fn prepareSubmission(
    self: *const SessionPolicy,
    draft: []const u8,
) Error!PreparedSubmission {
    if (self.phase_value == .poisoned) return error.SessionUnavailable;
    const text = std.mem.trim(u8, draft, " \t\r\n");
    if (text.len == 0) return error.EmptyPrompt;
    if (text.len > self.limits.max_prompt_bytes) return error.PromptTooLarge;

    const route: SubmissionRoute = switch (self.phase_value) {
        .idle => .start,
        .awaiting_start, .cancel_pending, .running, .cancelling, .dispatching_follow_up => .follow_up,
        .poisoned => unreachable,
    };
    if (route == .follow_up) {
        if (self.follow_ups.items.len >= self.limits.max_follow_ups) {
            return error.FollowUpQueueFull;
        }
        if (text.len > self.limits.max_follow_up_bytes -| self.follow_up_bytes) {
            return error.FollowUpQueueTooLarge;
        }
    }
    return .{
        .allocator = self.allocator,
        .text = try self.allocator.dupe(u8, text),
        .route = route,
    };
}

/// Commits a prepared submission. Calls are serialized by the terminal event
/// loop, so no event may be reduced between preparation and commit.
pub fn commitSubmission(
    self: *SessionPolicy,
    prepared: *PreparedSubmission,
) void {
    switch (prepared.route) {
        .start => {
            std.debug.assert(self.phase_value == .idle);
            self.allocator.free(prepared.transfer());
            self.phase_value = .awaiting_start;
        },
        .follow_up => {
            std.debug.assert(self.phase_value != .idle and self.phase_value != .poisoned);
            const text = prepared.transfer();
            self.follow_ups.appendAssumeCapacity(text);
            self.follow_up_bytes += text.len;
        },
    }
    prepared.* = undefined;
}

/// Applies one ordered worker event. Events from an inactive run are fenced as
/// stale and must not reach transcript or renderer reducers.
pub fn applyEvent(
    self: *SessionPolicy,
    event: session_event.Event,
) EventResult {
    if (event == .agent_start) return self.applyAgentStart(event.agent_start.run_id);

    const run_id = eventRunId(event);
    const active_id = self.activeRunId() orelse return .{ .admission = .stale };
    if (run_id != active_id) return .{ .admission = .stale };

    if (event == .agent_settled) {
        return self.settle(event.agent_settled.run_id, event.agent_settled.availability);
    }
    return .{ .admission = .admit };
}

/// Matches the worker completion after ordered events have been reduced. If
/// event delivery failed before `agent_settled`, the completion performs the
/// same deterministic settlement transition.
pub fn applyCompletion(
    self: *SessionPolicy,
    run_id: agent.event.RunId,
    availability: session_event.Availability,
) EventResult {
    if (self.settled_run_id) |settled| {
        if (settled != run_id) return .{ .admission = .stale };
        self.settled_run_id = null;
        return .{ .admission = .admit };
    }
    if (self.activeRunId()) |active| {
        if (active != run_id) return .{ .admission = .stale };
    } else switch (self.phase_value) {
        .awaiting_start, .cancel_pending => {},
        .idle, .dispatching_follow_up, .poisoned => return .{ .admission = .stale },
        .running, .cancelling => unreachable,
    }
    const result = self.settle(run_id, availability);
    self.settled_run_id = null;
    return result;
}

/// Confirms that the follow-up named by `submit_follow_up` was copied into the
/// worker queue. On rejection, call `rejectFollowUpSubmission` instead.
pub fn confirmFollowUpSubmission(self: *SessionPolicy) void {
    std.debug.assert(self.phase_value == .dispatching_follow_up);
    const submitted = self.follow_ups.orderedRemove(0);
    self.follow_up_bytes -= submitted.len;
    self.allocator.free(submitted);
    self.phase_value = .awaiting_start;
}

pub fn rejectFollowUpSubmission(self: *SessionPolicy) void {
    std.debug.assert(self.phase_value == .dispatching_follow_up);
}

pub fn pendingFollowUp(self: *const SessionPolicy) ?[]const u8 {
    if (self.phase_value != .dispatching_follow_up) return null;
    return self.follow_ups.items[0];
}

/// Restores queued follow-ups before the current editor text. Allocation
/// completes before the queue is cleared, so failure leaves every draft intact.
pub fn restoreQueued(
    self: *SessionPolicy,
    current_draft: []const u8,
) error{ OutOfMemory, RestoredDraftTooLarge }!?OwnedDraft {
    if (self.follow_ups.items.len == 0) return null;
    const include_current = std.mem.trim(u8, current_draft, " \t\r\n").len != 0;
    var total = self.follow_up_bytes;
    const separators = self.follow_ups.items.len - 1 + @intFromBool(include_current);
    const separator_bytes = std.math.mul(usize, separators, 2) catch
        return error.RestoredDraftTooLarge;
    total = std.math.add(usize, total, separator_bytes) catch
        return error.RestoredDraftTooLarge;
    if (include_current) {
        total = std.math.add(usize, total, current_draft.len) catch return error.RestoredDraftTooLarge;
    }
    if (total > self.limits.max_restored_draft_bytes) return error.RestoredDraftTooLarge;
    const combined = try self.allocator.alloc(u8, total);
    var offset: usize = 0;
    for (self.follow_ups.items, 0..) |follow_up, index| {
        if (index != 0) {
            @memcpy(combined[offset..][0..2], "\n\n");
            offset += 2;
        }
        @memcpy(combined[offset..][0..follow_up.len], follow_up);
        offset += follow_up.len;
    }
    if (include_current) {
        @memcpy(combined[offset..][0..2], "\n\n");
        offset += 2;
        @memcpy(combined[offset..][0..current_draft.len], current_draft);
        offset += current_draft.len;
    }
    std.debug.assert(offset == combined.len);

    const restored_count = self.follow_ups.items.len;
    self.clearFollowUps();
    return .{
        .allocator = self.allocator,
        .text = combined,
        .restored_count = restored_count,
    };
}

/// Escape restores follow-ups transactionally and requests cancellation only
/// when a run id is already known. An awaiting run is cancelled on agent_start.
pub fn escape(
    self: *SessionPolicy,
    current_draft: []const u8,
) error{ OutOfMemory, RestoredDraftTooLarge }!EscapeResult {
    const restored = try self.restoreQueued(current_draft);
    const request_cancel = switch (self.phase_value) {
        .running => |run_id| cancel: {
            self.phase_value = .{ .cancelling = run_id };
            break :cancel true;
        },
        .cancelling => true,
        .awaiting_start => pending: {
            self.phase_value = .cancel_pending;
            break :pending false;
        },
        .cancel_pending => false,
        .dispatching_follow_up => dispatching: {
            self.phase_value = .idle;
            break :dispatching false;
        },
        .idle, .poisoned => false,
    };
    return .{ .request_cancel = request_cancel, .restored = restored };
}

fn settle(
    self: *SessionPolicy,
    run_id: agent.event.RunId,
    availability: session_event.Availability,
) EventResult {
    self.settled_run_id = run_id;
    return switch (availability) {
        .poisoned => poisoned: {
            self.phase_value = .poisoned;
            break :poisoned .{ .admission = .admit, .effect = .session_poisoned };
        },
        .ready => ready: {
            if (self.follow_ups.items.len == 0) {
                self.phase_value = .idle;
                break :ready .{ .admission = .admit };
            }
            self.phase_value = .dispatching_follow_up;
            break :ready .{
                .admission = .admit,
                .effect = .{ .submit_follow_up = self.follow_ups.items[0] },
            };
        },
    };
}

fn applyAgentStart(self: *SessionPolicy, run_id: agent.event.RunId) EventResult {
    return switch (self.phase_value) {
        .awaiting_start => started: {
            self.settled_run_id = null;
            self.phase_value = .{ .running = run_id };
            break :started .{ .admission = .admit };
        },
        .cancel_pending => cancelling: {
            self.settled_run_id = null;
            self.phase_value = .{ .cancelling = run_id };
            break :cancelling .{ .admission = .admit, .effect = .request_cancel };
        },
        .running => |active| .{ .admission = if (active == run_id) .admit else .stale },
        .cancelling => |active| .{ .admission = if (active == run_id) .admit else .stale },
        .idle, .dispatching_follow_up, .poisoned => .{ .admission = .stale },
    };
}

fn activeRunId(self: *const SessionPolicy) ?agent.event.RunId {
    return switch (self.phase_value) {
        .running => |run_id| run_id,
        .cancelling => |run_id| run_id,
        .idle, .awaiting_start, .cancel_pending, .dispatching_follow_up, .poisoned => null,
    };
}

fn clearFollowUps(self: *SessionPolicy) void {
    for (self.follow_ups.items) |follow_up| self.allocator.free(follow_up);
    self.follow_ups.clearRetainingCapacity();
    self.follow_up_bytes = 0;
}

fn eventRunId(event: session_event.Event) agent.event.RunId {
    return switch (event) {
        .agent_start => |value| value.run_id,
        .agent_end => |value| value.run_id,
        .turn_start => |value| value.run_id,
        .turn_end => |value| value.run_id,
        .message_start => |value| value.run_id,
        .message_update => |value| value.run_id,
        .message_end => |value| value.run_id,
        .tool_execution_start => |value| value.run_id,
        .tool_execution_end => |value| value.run_id,
        .agent_settled => |value| value.run_id,
    };
}

fn testRunId(value: u64) agent.event.RunId {
    return @enumFromInt(value);
}

fn startRun(policy: *SessionPolicy, prompt: []const u8, id: u64) !void {
    var prepared = try policy.prepareSubmission(prompt);
    policy.commitSubmission(&prepared);
    const result = policy.applyEvent(.{ .agent_start = .{ .run_id = testRunId(id) } });
    try std.testing.expectEqual(Admission.admit, result.admission);
}

test "submission remains transactional until committed" {
    var policy = try SessionPolicy.init(std.testing.allocator, .{});
    defer policy.deinit();
    var draft = [_]u8{ ' ', 'h', 'e', 'l', 'l', 'o', ' ' };

    var rolled_back = try policy.prepareSubmission(&draft);
    try std.testing.expectEqual(SubmissionRoute.start, rolled_back.route);
    @memset(&draft, 'x');
    try std.testing.expectEqualStrings("hello", rolled_back.text);
    rolled_back.deinit();
    try std.testing.expect(policy.phase() == .idle);

    var accepted = try policy.prepareSubmission("hello");
    policy.commitSubmission(&accepted);
    try std.testing.expect(policy.phase() == .awaiting_start);
}

test "follow-ups dispatch sequentially after matching settlements" {
    var policy = try SessionPolicy.init(std.testing.allocator, .{});
    defer policy.deinit();
    try startRun(&policy, "initial", 1);

    var first = try policy.prepareSubmission("first follow-up");
    policy.commitSubmission(&first);
    var second = try policy.prepareSubmission("second follow-up");
    policy.commitSubmission(&second);
    try std.testing.expectEqual(@as(usize, 2), policy.queuedFollowUps().len);

    const stale = policy.applyEvent(.{ .agent_settled = .{
        .run_id = testRunId(99),
        .availability = .ready,
    } });
    try std.testing.expectEqual(Admission.stale, stale.admission);
    try std.testing.expect(policy.phase() == .running);

    const first_dispatch = policy.applyEvent(.{ .agent_settled = .{
        .run_id = testRunId(1),
        .availability = .ready,
    } });
    try std.testing.expect(first_dispatch.effect == .submit_follow_up);
    try std.testing.expectEqualStrings("first follow-up", first_dispatch.effect.submit_follow_up);
    try std.testing.expectEqual(
        Admission.stale,
        policy.applyCompletion(testRunId(99), .ready).admission,
    );
    try std.testing.expectEqual(
        Admission.admit,
        policy.applyCompletion(testRunId(1), .ready).admission,
    );
    policy.rejectFollowUpSubmission();
    try std.testing.expectEqualStrings("first follow-up", policy.pendingFollowUp().?);
    policy.confirmFollowUpSubmission();
    try std.testing.expect(policy.phase() == .awaiting_start);

    const second_start = policy.applyEvent(.{ .agent_start = .{ .run_id = testRunId(2) } });
    try std.testing.expectEqual(Admission.admit, second_start.admission);
    const second_dispatch = policy.applyEvent(.{ .agent_settled = .{
        .run_id = testRunId(2),
        .availability = .ready,
    } });
    try std.testing.expectEqualStrings("second follow-up", second_dispatch.effect.submit_follow_up);
    policy.confirmFollowUpSubmission();
    _ = policy.applyEvent(.{ .agent_start = .{ .run_id = testRunId(3) } });
    _ = policy.applyEvent(.{ .agent_settled = .{
        .run_id = testRunId(3),
        .availability = .ready,
    } });
    try std.testing.expect(policy.phase() == .idle);
    try std.testing.expectEqual(@as(usize, 0), policy.queuedFollowUps().len);
}

test "completion settles a run when settled event delivery failed" {
    var policy = try SessionPolicy.init(std.testing.allocator, .{});
    defer policy.deinit();
    try startRun(&policy, "initial", 12);

    const stale = policy.applyCompletion(testRunId(11), .ready);
    try std.testing.expectEqual(Admission.stale, stale.admission);
    try std.testing.expect(policy.phase() == .running);
    const fallback = policy.applyCompletion(testRunId(12), .ready);
    try std.testing.expectEqual(Admission.admit, fallback.admission);
    try std.testing.expect(policy.phase() == .idle);

    var awaiting = try policy.prepareSubmission("next");
    policy.commitSubmission(&awaiting);
    const missing_start = policy.applyCompletion(testRunId(13), .ready);
    try std.testing.expectEqual(Admission.admit, missing_start.admission);
    try std.testing.expect(policy.phase() == .idle);
}

test "escape restores queued drafts before requesting cancellation" {
    var policy = try SessionPolicy.init(std.testing.allocator, .{});
    defer policy.deinit();
    try startRun(&policy, "initial", 7);
    var first = try policy.prepareSubmission("one");
    policy.commitSubmission(&first);
    var second = try policy.prepareSubmission("two");
    policy.commitSubmission(&second);

    var escaped = try policy.escape("current");
    defer if (escaped.restored) |*restored| restored.deinit();
    try std.testing.expect(escaped.request_cancel);
    try std.testing.expect(policy.phase() == .cancelling);
    try std.testing.expectEqual(@as(usize, 0), policy.queuedFollowUps().len);
    try std.testing.expectEqual(@as(usize, 2), escaped.restored.?.restored_count);
    try std.testing.expectEqualStrings("one\n\ntwo\n\ncurrent", escaped.restored.?.text);
}

test "oversized restoration preserves queue and cancellation state" {
    var policy = try SessionPolicy.init(std.testing.allocator, .{
        .max_prompt_bytes = 4,
        .max_follow_ups = 2,
        .max_follow_up_bytes = 4,
        .max_restored_draft_bytes = 5,
    });
    defer policy.deinit();
    try startRun(&policy, "run", 9);
    var follow_up = try policy.prepareSubmission("four");
    policy.commitSubmission(&follow_up);

    try std.testing.expectError(error.RestoredDraftTooLarge, policy.escape("xx"));
    try std.testing.expect(policy.phase() == .running);
    try std.testing.expectEqual(@as(usize, 1), policy.queuedFollowUps().len);
    try std.testing.expectEqualStrings("four", policy.queuedFollowUps()[0]);
}

test "escape before agent start defers cancellation to the admitted run" {
    var policy = try SessionPolicy.init(std.testing.allocator, .{});
    defer policy.deinit();
    var prepared = try policy.prepareSubmission("initial");
    policy.commitSubmission(&prepared);

    const escaped = try policy.escape("");
    try std.testing.expect(!escaped.request_cancel);
    try std.testing.expect(policy.phase() == .cancel_pending);
    const started = policy.applyEvent(.{ .agent_start = .{ .run_id = testRunId(8) } });
    try std.testing.expect(started.effect == .request_cancel);
    try std.testing.expect(policy.phase() == .cancelling);
}

test "poisoned settlement fences future submission" {
    var policy = try SessionPolicy.init(std.testing.allocator, .{});
    defer policy.deinit();
    try startRun(&policy, "initial", 4);
    var follow_up = try policy.prepareSubmission("preserve me");
    policy.commitSubmission(&follow_up);
    const result = policy.applyEvent(.{ .agent_settled = .{
        .run_id = testRunId(4),
        .availability = .poisoned,
    } });
    try std.testing.expect(result.effect == .session_poisoned);
    try std.testing.expect(policy.phase() == .poisoned);
    try std.testing.expectError(error.SessionUnavailable, policy.prepareSubmission("again"));
    var restored = (try policy.restoreQueued("")).?;
    defer restored.deinit();
    try std.testing.expectEqualStrings("preserve me", restored.text);
}

test "follow-up bounds leave existing queue unchanged" {
    var policy = try SessionPolicy.init(std.testing.allocator, .{
        .max_prompt_bytes = 8,
        .max_follow_ups = 1,
        .max_follow_up_bytes = 3,
    });
    defer policy.deinit();
    try startRun(&policy, "start", 1);
    var accepted = try policy.prepareSubmission("one");
    policy.commitSubmission(&accepted);

    try std.testing.expectError(error.FollowUpQueueFull, policy.prepareSubmission("two"));
    try std.testing.expectError(error.PromptTooLarge, policy.prepareSubmission("123456789"));
    try std.testing.expectEqual(@as(usize, 1), policy.queuedFollowUps().len);
    try std.testing.expectEqualStrings("one", policy.queuedFollowUps()[0]);

    var byte_policy = try SessionPolicy.init(std.testing.allocator, .{
        .max_prompt_bytes = 8,
        .max_follow_ups = 2,
        .max_follow_up_bytes = 3,
    });
    defer byte_policy.deinit();
    try startRun(&byte_policy, "start", 1);
    var fills_bytes = try byte_policy.prepareSubmission("one");
    byte_policy.commitSubmission(&fills_bytes);
    try std.testing.expectError(
        error.FollowUpQueueTooLarge,
        byte_policy.prepareSubmission("x"),
    );
}

fn exerciseAllocations(allocator: std.mem.Allocator) !void {
    var policy = try SessionPolicy.init(allocator, .{});
    defer policy.deinit();
    var start = try policy.prepareSubmission("start");
    policy.commitSubmission(&start);
    _ = policy.applyEvent(.{ .agent_start = .{ .run_id = testRunId(1) } });
    var follow_up = try policy.prepareSubmission("follow-up");
    policy.commitSubmission(&follow_up);
    var restored = (try policy.restoreQueued("current")).?;
    restored.deinit();
}

test "policy settles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocations,
        .{},
    );
}
