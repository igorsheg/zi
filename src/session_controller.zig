const std = @import("std");
const coding_agent = @import("coding_agent.zig");
const agent_mod = @import("agent/root.zig");
const ai = @import("ai/root.zig");
const json_util = @import("ai/json_util.zig");
const resources = @import("resources/root.zig");
const classifier = @import("session_error_classifier.zig");

const AgentSession = coding_agent.AgentSession;

pub const Phase = enum {
    idle,
    running_prompt,
    running_continue,
    draining_requests,
    waiting_to_retry,
    compacting,
};

pub const RunOutcome = enum {
    success,
    assistant_error,
    aborted,
};

pub const RetryStart = struct {
    attempt: u32,
    max_attempts: u32,
    delay_ms: u64,
    error_message: []const u8,
};

pub const RetryEnd = struct {
    success: bool,
    attempt: u32,
    final_error: ?[]const u8 = null,
};

pub const CompactionReason = enum {
    overflow,
    threshold,
    manual,
};

pub const CompactionStart = struct {
    reason: CompactionReason,
};

pub const CompactionEnd = struct {
    reason: CompactionReason,
    success: bool,
    will_retry: bool,
    error_message: ?[]const u8 = null,
};

pub const SessionEvent = union(enum) {
    phase_changed: struct {
        from: Phase,
        to: Phase,
    },
    retry_start: RetryStart,
    retry_end: RetryEnd,
    compaction_start: CompactionStart,
    compaction_end: CompactionEnd,
};

pub const RetryPolicy = struct {
    enabled: bool = true,
    max_retries: u32 = 3,
    base_delay_ms: u64 = 2000,
    max_delay_ms: u64 = 30000,
};

pub const CompactionPolicy = struct {
    enabled: bool = true,
    reserve_tokens: u64 = 16384,
    keep_recent_tokens: u64 = 20000,
};

pub const CompactionResult = struct {
    summary: []const u8,
    first_kept_entry_id: []const u8,
    tokens_before: u64,
};

pub const CompactionExecutor = struct {
    func: *const fn (reason: CompactionReason, policy: CompactionPolicy, ctx: ?*anyopaque) anyerror!CompactionResult,
    ctx: ?*anyopaque = null,
};

pub const SessionController = struct {
    allocator: std.mem.Allocator,
    session: *AgentSession,
    retry_policy: RetryPolicy,
    compaction_policy: CompactionPolicy,
    compaction_executor: ?CompactionExecutor = null,
    phase: Phase = .idle,
    listeners: std.ArrayList(Listener),
    retry_attempt: u32 = 0,
    overflow_recovery_attempted: bool = false,
    retry_abort_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    const Listener = struct {
        func: *const fn (event: SessionEvent, ctx: ?*anyopaque) void,
        ctx: ?*anyopaque,
    };

    pub const SubscriptionToken = struct {
        index: usize,
    };

    pub const Options = struct {
        retry_policy: RetryPolicy = .{},
        compaction_policy: CompactionPolicy = .{},
        compaction_executor: ?CompactionExecutor = null,
    };

    pub fn init(allocator: std.mem.Allocator, session: *AgentSession, options: Options) SessionController {
        return .{
            .allocator = allocator,
            .session = session,
            .retry_policy = options.retry_policy,
            .compaction_policy = options.compaction_policy,
            .compaction_executor = options.compaction_executor,
            .listeners = .empty,
        };
    }

    pub fn deinit(self: *SessionController) void {
        self.listeners.deinit(self.allocator);
    }

    pub fn subscribe(
        self: *SessionController,
        func: *const fn (event: SessionEvent, ctx: ?*anyopaque) void,
        ctx: ?*anyopaque,
    ) SubscriptionToken {
        const index = self.listeners.items.len;
        self.listeners.append(self.allocator, .{ .func = func, .ctx = ctx }) catch return .{ .index = std.math.maxInt(usize) };
        return .{ .index = index };
    }

    pub fn unsubscribe(self: *SessionController, token: SubscriptionToken) void {
        if (token.index < self.listeners.items.len) {
            _ = self.listeners.orderedRemove(token.index);
        }
    }

    pub fn runPrompt(self: *SessionController, prompt_text: []const u8) !RunOutcome {
        return self.runUserContent(.{ .text = prompt_text });
    }

    pub fn runUserContent(self: *SessionController, content: ai.protocol.UserMessage.UserMessageContent) !RunOutcome {
        return self.runWithRecovery(.running_prompt, content);
    }

    pub fn continueTurn(self: *SessionController) !RunOutcome {
        return self.runWithRecovery(.running_continue, null);
    }

    pub fn beginRequestDrain(self: *SessionController) void {
        self.setPhase(.draining_requests);
    }

    pub fn finishRequestDrain(self: *SessionController) void {
        self.setPhase(.idle);
    }

    pub fn notifyRetryStart(self: *SessionController, event: RetryStart) void {
        self.setPhase(.waiting_to_retry);
        self.emit(.{ .retry_start = event });
    }

    pub fn notifyRetryEnd(self: *SessionController, event: RetryEnd) void {
        self.emit(.{ .retry_end = event });
    }

    pub fn runCompaction(self: *SessionController, reason: CompactionReason, will_retry: bool) !CompactionResult {
        self.notifyCompactionStart(.{ .reason = reason });
        defer if (self.phase == .compacting) self.setPhase(.idle);

        if (!self.compaction_policy.enabled) {
            self.notifyCompactionEnd(.{
                .reason = reason,
                .success = false,
                .will_retry = false,
                .error_message = "CompactionDisabled",
            });
            return error.CompactionDisabled;
        }

        const executor = self.compaction_executor orelse {
            self.notifyCompactionEnd(.{
                .reason = reason,
                .success = false,
                .will_retry = false,
                .error_message = "CompactionUnavailable",
            });
            return error.CompactionUnavailable;
        };

        const result = executor.func(reason, self.compaction_policy, executor.ctx) catch |err| {
            self.notifyCompactionEnd(.{
                .reason = reason,
                .success = false,
                .will_retry = false,
                .error_message = @errorName(err),
            });
            return err;
        };

        self.notifyCompactionEnd(.{
            .reason = reason,
            .success = true,
            .will_retry = will_retry,
        });
        return result;
    }

    pub fn notifyCompactionStart(self: *SessionController, event: CompactionStart) void {
        self.setPhase(.compacting);
        self.emit(.{ .compaction_start = event });
    }

    pub fn notifyCompactionEnd(self: *SessionController, event: CompactionEnd) void {
        self.emit(.{ .compaction_end = event });
        if (self.phase == .compacting) self.setPhase(.idle);
    }

    fn emit(self: *SessionController, event: SessionEvent) void {
        for (self.listeners.items) |listener| {
            listener.func(event, listener.ctx);
        }
    }

    pub fn abortRetry(self: *SessionController) void {
        self.retry_abort_requested.store(true, .release);
        self.session.agent.wakeAbortWaiters();
    }

    pub fn isRetrying(self: *const SessionController) bool {
        return self.phase == .waiting_to_retry;
    }

    fn setPhase(self: *SessionController, next: Phase) void {
        const prev = self.phase;
        if (prev == next) return;
        self.phase = next;
        self.emit(.{ .phase_changed = .{ .from = prev, .to = next } });
    }

    fn resolveRunOutcome(self: *SessionController) RunOutcome {
        if (self.session.agent.isAbortRequested()) return .aborted;
        const assistant = self.latestAssistantMessage() orelse return .success;
        return switch (assistant.stop_reason) {
            .aborted => .aborted,
            .@"error" => .assistant_error,
            else => .success,
        };
    }

    fn runWithRecovery(
        self: *SessionController,
        initial_phase: Phase,
        prompt_content: ?ai.protocol.UserMessage.UserMessageContent,
    ) !RunOutcome {
        self.retry_attempt = 0;
        self.overflow_recovery_attempted = false;
        self.retry_abort_requested.store(false, .release);
        defer {
            self.retry_attempt = 0;
            self.overflow_recovery_attempted = false;
            self.retry_abort_requested.store(false, .release);
            self.setPhase(.idle);
        }

        var phase = initial_phase;
        while (true) {
            self.setPhase(phase);
            if (phase == .running_prompt) {
                try self.session.runUserContent(prompt_content.?);
            } else {
                try self.session.continueSession();
            }

            const outcome = self.resolveRunOutcome();
            if (outcome != .assistant_error) {
                self.overflow_recovery_attempted = false;
                if (self.retry_attempt > 0) {
                    self.notifyRetryEnd(.{
                        .success = true,
                        .attempt = self.retry_attempt,
                    });
                }
                return outcome;
            }

            const assistant = self.latestAssistantMessage() orelse return outcome;
            const classification = classifier.classifyAssistantMessage(
                &assistant,
                self.session.agent.state.model.context_window,
            );
            switch (classification.class) {
                .retryable_transient => {
                    if (!self.beginRetry(classification.error_message orelse assistant.error_message orelse "unknown error")) {
                        return outcome;
                    }

                    self.pruneTransientAssistantError();
                    if (self.waitForRetryDelay(self.computeRetryDelayMs())) {
                        self.notifyRetryEnd(.{
                            .success = false,
                            .attempt = self.retry_attempt,
                            .final_error = "Retry cancelled",
                        });
                        return .aborted;
                    }

                    phase = .running_continue;
                },
                .overflow => {
                    if (!self.isLatestAssistantFromCurrentModel(assistant)) return outcome;
                    if (self.overflow_recovery_attempted) {
                        self.notifyCompactionEnd(.{
                            .reason = .overflow,
                            .success = false,
                            .will_retry = false,
                            .error_message = "Context overflow recovery failed after one compact-and-retry attempt. Try reducing context or switching to a larger-context model.",
                        });
                        return outcome;
                    }

                    self.overflow_recovery_attempted = true;
                    self.pruneTransientAssistantError();
                    _ = self.runCompaction(.overflow, true) catch return outcome;
                    phase = .running_continue;
                },
                else => return outcome,
            }
        }
    }

    fn latestAssistantMessage(self: *SessionController) ?ai.protocol.AssistantMessage {
        const messages = self.session.agent.state.messages;
        if (messages.len == 0) return null;
        const last = messages[messages.len - 1];
        if (last != .assistant) return null;
        return last.assistant;
    }

    fn isLatestAssistantFromCurrentModel(self: *const SessionController, assistant: ai.protocol.AssistantMessage) bool {
        const model = self.session.agent.state.model;
        return std.mem.eql(u8, json_util.providerToString(assistant.provider), json_util.providerToString(model.provider)) and
            std.mem.eql(u8, assistant.model, model.id);
    }

    fn beginRetry(self: *SessionController, error_message: []const u8) bool {
        if (!self.retry_policy.enabled) return false;

        const next_attempt = self.retry_attempt + 1;
        if (next_attempt > self.retry_policy.max_retries) {
            self.notifyRetryEnd(.{
                .success = false,
                .attempt = self.retry_attempt,
                .final_error = error_message,
            });
            return false;
        }

        self.retry_attempt = next_attempt;
        self.notifyRetryStart(.{
            .attempt = self.retry_attempt,
            .max_attempts = self.retry_policy.max_retries,
            .delay_ms = self.computeRetryDelayMs(),
            .error_message = error_message,
        });
        return true;
    }

    fn computeRetryDelayMs(self: *const SessionController) u64 {
        var delay = self.retry_policy.base_delay_ms;
        var n: u32 = 1;
        while (n < self.retry_attempt) : (n += 1) {
            if (self.retry_policy.max_delay_ms > 0 and delay >= self.retry_policy.max_delay_ms / 2) {
                return self.retry_policy.max_delay_ms;
            }
            delay *= 2;
        }
        if (self.retry_policy.max_delay_ms > 0 and delay > self.retry_policy.max_delay_ms) {
            return self.retry_policy.max_delay_ms;
        }
        return delay;
    }

    fn waitForRetryDelay(self: *SessionController, delay_ms: u64) bool {
        return switch (self.session.agent.abortSignal().waitUntil(
            delay_ms * @as(u64, std.time.ns_per_ms),
            &retryAbortRequested,
            @ptrCast(self),
        )) {
            .aborted, .predicate => true,
            .timeout, .none => self.retry_abort_requested.load(.acquire) or self.session.agent.isAbortRequested(),
        };
    }

    fn retryAbortRequested(ctx: ?*anyopaque) bool {
        const self: *SessionController = @ptrCast(@alignCast(ctx.?));
        return self.retry_abort_requested.load(.acquire);
    }

    fn pruneTransientAssistantError(self: *SessionController) void {
        const messages = self.session.agent.state.messages;
        if (messages.len == 0) return;
        const last = messages[messages.len - 1];
        if (last != .assistant) return;
        if (last.assistant.stop_reason != .@"error") return;
        self.session.agent.loadMessages(messages[0 .. messages.len - 1]);
        self.session.agent.state.error_message = null;
    }
};

const testing = std.testing;
const faux = ai.faux;

const SessionEventCollector = struct {
    phase_changes: std.ArrayListUnmanaged(struct { from: Phase, to: Phase }) = .empty,
    retry_starts: std.ArrayListUnmanaged(RetryStart) = .empty,
    retry_ends: std.ArrayListUnmanaged(RetryEnd) = .empty,
    compaction_starts: std.ArrayListUnmanaged(CompactionStart) = .empty,
    compaction_ends: std.ArrayListUnmanaged(CompactionEnd) = .empty,
    allocator: std.mem.Allocator,

    fn callback(event: SessionEvent, ctx: ?*anyopaque) void {
        const self: *SessionEventCollector = @ptrCast(@alignCast(ctx));
        switch (event) {
            .phase_changed => |pc| self.phase_changes.append(self.allocator, pc) catch {},
            .retry_start => |rs| self.retry_starts.append(self.allocator, rs) catch {},
            .retry_end => |re| self.retry_ends.append(self.allocator, re) catch {},
            .compaction_start => |cs| self.compaction_starts.append(self.allocator, cs) catch {},
            .compaction_end => |ce| self.compaction_ends.append(self.allocator, ce) catch {},
        }
    }

    fn deinit(self: *SessionEventCollector) void {
        self.phase_changes.deinit(self.allocator);
        self.retry_starts.deinit(self.allocator);
        self.retry_ends.deinit(self.allocator);
        self.compaction_starts.deinit(self.allocator);
        self.compaction_ends.deinit(self.allocator);
    }
};

const CompactionSpy = struct {
    allocator: std.mem.Allocator,
    calls: std.ArrayListUnmanaged(CompactionReason) = .empty,

    fn execute(reason: CompactionReason, _: CompactionPolicy, ctx: ?*anyopaque) anyerror!CompactionResult {
        const self: *CompactionSpy = @ptrCast(@alignCast(ctx.?));
        try self.calls.append(self.allocator, reason);
        return .{
            .summary = "condensed history",
            .first_kept_entry_id = "keep-user",
            .tokens_before = 2048,
        };
    }

    fn deinit(self: *CompactionSpy) void {
        self.calls.deinit(self.allocator);
    }
};

fn fauxErrorAssistantMessage(
    allocator: std.mem.Allocator,
    error_message: []const u8,
) ai.protocol.AssistantMessage {
    var message = faux.fauxAssistantMessage(allocator, &.{}, .@"error");
    message.error_message = error_message;
    return message;
}

fn createTestAgentSession(
    allocator: std.mem.Allocator,
    registry: *ai.provider.Registry,
) AgentSession {
    const resource_loader = resources.ResourceLoader.init(allocator, .{ .cwd = "/tmp/zi-test" }) catch @panic("OOM");
    return AgentSession.init(allocator, .{
        .model = faux.fauxModel(),
        .api_key = "test-key",
        .cwd = "/tmp/zi-test",
        .resource_loader = resource_loader,
        .registry = registry,
        .tools = &.{},
        .no_session = true,
    });
}

test "SessionController reports phase transitions for prompt runs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fp = faux.FauxProvider.init(allocator);
    const content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("hello")};
    fp.setResponses(&.{faux.fauxAssistantMessage(allocator, &content, .stop)});

    var registry = ai.provider.Registry.init(allocator);
    try registry.register("faux", fp.provider(), null);

    var session = createTestAgentSession(allocator, &registry);
    defer session.deinit();

    var controller = SessionController.init(allocator, &session, .{});
    defer controller.deinit();

    var collector = SessionEventCollector{ .allocator = allocator };
    defer collector.deinit();
    _ = controller.subscribe(&SessionEventCollector.callback, @ptrCast(&collector));

    const outcome = try controller.runPrompt("hi");

    try testing.expectEqual(RunOutcome.success, outcome);
    try testing.expectEqual(Phase.idle, controller.phase);
    try testing.expectEqual(@as(usize, 2), session.agent.state.messages.len);
    try testing.expectEqual(@as(usize, 2), collector.phase_changes.items.len);
    try testing.expectEqual(Phase.idle, collector.phase_changes.items[0].from);
    try testing.expectEqual(Phase.running_prompt, collector.phase_changes.items[0].to);
    try testing.expectEqual(Phase.running_prompt, collector.phase_changes.items[1].from);
    try testing.expectEqual(Phase.idle, collector.phase_changes.items[1].to);
}

test "SessionController reports assistant error outcome without changing raw session history" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fp = faux.FauxProvider.init(allocator);
    const err_msg = faux.fauxAssistantMessage(allocator, &.{}, .@"error");
    fp.setResponses(&.{err_msg});

    var registry = ai.provider.Registry.init(allocator);
    try registry.register("faux", fp.provider(), null);

    var session = createTestAgentSession(allocator, &registry);
    defer session.deinit();

    var controller = SessionController.init(allocator, &session, .{});
    defer controller.deinit();

    const outcome = try controller.runPrompt("hi");

    try testing.expectEqual(RunOutcome.assistant_error, outcome);
    try testing.expectEqual(Phase.idle, controller.phase);
    try testing.expectEqual(@as(usize, 2), session.agent.state.messages.len);
    try testing.expectEqual(agent_mod.protocol.StopReason.@"error", session.agent.state.messages[1].assistant.stop_reason);
}

test "SessionController retries transient assistant failures and prunes the failed assistant turn before continue" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fp = faux.FauxProvider.init(allocator);
    const transient_err = fauxErrorAssistantMessage(allocator, "provider returned error: 503 service unavailable");
    const success_content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("recovered")};
    const success_msg = faux.fauxAssistantMessage(allocator, &success_content, .stop);
    fp.setResponses(&.{ transient_err, success_msg });

    var registry = ai.provider.Registry.init(allocator);
    try registry.register("faux", fp.provider(), null);

    var session = createTestAgentSession(allocator, &registry);
    defer session.deinit();

    var controller = SessionController.init(allocator, &session, .{
        .retry_policy = .{
            .enabled = true,
            .max_retries = 2,
            .base_delay_ms = 0,
            .max_delay_ms = 0,
        },
    });
    defer controller.deinit();

    var collector = SessionEventCollector{ .allocator = allocator };
    defer collector.deinit();
    _ = controller.subscribe(&SessionEventCollector.callback, @ptrCast(&collector));

    const outcome = try controller.runPrompt("hi");

    try testing.expectEqual(RunOutcome.success, outcome);
    try testing.expectEqual(@as(usize, 2), fp.call_count);
    try testing.expectEqual(@as(usize, 1), collector.retry_starts.items.len);
    try testing.expectEqual(@as(usize, 1), collector.retry_ends.items.len);
    try testing.expectEqual(@as(u32, 1), collector.retry_starts.items[0].attempt);
    try testing.expectEqual(@as(u32, 1), collector.retry_ends.items[0].attempt);
    try testing.expect(collector.retry_ends.items[0].success);
    try testing.expectEqual(@as(usize, 2), session.agent.state.messages.len);
    try testing.expectEqualStrings("recovered", session.agent.state.messages[1].assistant.content[0].text.text);
    try testing.expectEqual(@as(usize, 4), collector.phase_changes.items.len);
    try testing.expectEqual(Phase.idle, collector.phase_changes.items[0].from);
    try testing.expectEqual(Phase.running_prompt, collector.phase_changes.items[0].to);
    try testing.expectEqual(Phase.running_prompt, collector.phase_changes.items[1].from);
    try testing.expectEqual(Phase.waiting_to_retry, collector.phase_changes.items[1].to);
    try testing.expectEqual(Phase.waiting_to_retry, collector.phase_changes.items[2].from);
    try testing.expectEqual(Phase.running_continue, collector.phase_changes.items[2].to);
    try testing.expectEqual(Phase.running_continue, collector.phase_changes.items[3].from);
    try testing.expectEqual(Phase.idle, collector.phase_changes.items[3].to);
}

test "SessionController recovers overflow with one compaction pass before retrying continue" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fp = faux.FauxProvider.init(allocator);
    const overflow_err = fauxErrorAssistantMessage(allocator, "prompt is too long for requested model");
    const success_content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("after compaction")};
    const success_msg = faux.fauxAssistantMessage(allocator, &success_content, .stop);
    fp.setResponses(&.{ overflow_err, success_msg });

    var registry = ai.provider.Registry.init(allocator);
    try registry.register("faux", fp.provider(), null);

    var session = createTestAgentSession(allocator, &registry);
    defer session.deinit();

    var compaction_spy = CompactionSpy{ .allocator = allocator };
    defer compaction_spy.deinit();

    var controller = SessionController.init(allocator, &session, .{
        .compaction_executor = .{
            .func = &CompactionSpy.execute,
            .ctx = @ptrCast(&compaction_spy),
        },
    });
    defer controller.deinit();

    var collector = SessionEventCollector{ .allocator = allocator };
    defer collector.deinit();
    _ = controller.subscribe(&SessionEventCollector.callback, @ptrCast(&collector));

    const outcome = try controller.runPrompt("hi");

    try testing.expectEqual(RunOutcome.success, outcome);
    try testing.expectEqual(@as(usize, 2), fp.call_count);
    try testing.expectEqual(@as(usize, 1), compaction_spy.calls.items.len);
    try testing.expectEqual(CompactionReason.overflow, compaction_spy.calls.items[0]);
    try testing.expectEqual(@as(usize, 1), collector.compaction_starts.items.len);
    try testing.expectEqual(@as(usize, 1), collector.compaction_ends.items.len);
    try testing.expect(collector.compaction_ends.items[0].success);
    try testing.expect(collector.compaction_ends.items[0].will_retry);
    try testing.expectEqual(@as(usize, 0), collector.retry_starts.items.len);
    try testing.expectEqual(@as(usize, 2), session.agent.state.messages.len);
    try testing.expectEqualStrings("after compaction", session.agent.state.messages[1].assistant.content[0].text.text);
    try testing.expectEqual(@as(usize, 5), collector.phase_changes.items.len);
    try testing.expectEqual(Phase.idle, collector.phase_changes.items[0].from);
    try testing.expectEqual(Phase.running_prompt, collector.phase_changes.items[0].to);
    try testing.expectEqual(Phase.running_prompt, collector.phase_changes.items[1].from);
    try testing.expectEqual(Phase.compacting, collector.phase_changes.items[1].to);
    try testing.expectEqual(Phase.compacting, collector.phase_changes.items[2].from);
    try testing.expectEqual(Phase.idle, collector.phase_changes.items[2].to);
    try testing.expectEqual(Phase.idle, collector.phase_changes.items[3].from);
    try testing.expectEqual(Phase.running_continue, collector.phase_changes.items[3].to);
    try testing.expectEqual(Phase.running_continue, collector.phase_changes.items[4].from);
    try testing.expectEqual(Phase.idle, collector.phase_changes.items[4].to);
}
