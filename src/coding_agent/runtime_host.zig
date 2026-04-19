const std = @import("std");
const agent_mod = @import("../agent3/root.zig");
const agent_impl = @import("../agent3/agent.zig");
const control_mod = @import("../agent3/control.zig");
const ai = @import("../ai/root.zig");
const json_util = @import("../ai/json_util.zig");
const AgentSession = @import("agent_session.zig").AgentSession;
const classifier = @import("session_error_classifier.zig");
const conversation_state = @import("../agent3/conversation_state.zig");

pub const QueueKind = control_mod.QueueKind;
pub const EnqueueResult = control_mod.EnqueueResult;
pub const QueuedMessageText = control_mod.QueuedMessageText;
pub const QueuedMessageSnapshot = control_mod.QueuedMessageSnapshot;

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

pub const CompactionEnd = struct {
    reason: CompactionReason,
    success: bool,
    will_retry: bool,
    error_message: ?[]const u8 = null,
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

pub const LifecycleHooks = struct {
    on_retry_start: ?*const fn (event: RetryStart, ctx: ?*anyopaque) void = null,
    on_retry_wait_finished: ?*const fn (ctx: ?*anyopaque) void = null,
    on_retry_end: ?*const fn (event: RetryEnd, ctx: ?*anyopaque) void = null,
    on_compaction_end: ?*const fn (event: CompactionEnd, ctx: ?*anyopaque) void = null,
    ctx: ?*anyopaque = null,
};

pub const Options = struct {
    retry_policy: RetryPolicy = .{},
    compaction_policy: CompactionPolicy = .{},
    compaction_executor: ?CompactionExecutor = null,
};

pub const ConversationStatePublisher = struct {
    func: *const fn (state: conversation_state.PublishedConversationState, ctx: ?*anyopaque) void,
    ctx: ?*anyopaque = null,

    pub fn publish(self: ConversationStatePublisher, state: conversation_state.PublishedConversationState) void {
        self.func(state, self.ctx);
    }
};

pub const RuntimeHost = struct {
    session: *AgentSession,
    allocator: std.mem.Allocator,
    retry_policy: RetryPolicy,
    compaction_policy: CompactionPolicy,
    compaction_executor: ?CompactionExecutor,
    lifecycle_hooks: LifecycleHooks = .{},
    retry_attempt: u32 = 0,
    overflow_recovery_attempted: bool = false,
    retry_abort_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    queue_mutex: std.Thread.Mutex = .{},
    steering_mirror: std.ArrayListUnmanaged(control_mod.QueuedMessageText) = .empty,
    follow_up_mirror: std.ArrayListUnmanaged(control_mod.QueuedMessageText) = .empty,

    const RunMode = enum {
        prompt,
        continue_turn,
    };

    pub fn init(session: *AgentSession, allocator: std.mem.Allocator, options: Options) !RuntimeHost {
        return .{
            .session = session,
            .allocator = allocator,
            .retry_policy = options.retry_policy,
            .compaction_policy = options.compaction_policy,
            .compaction_executor = options.compaction_executor,
        };
    }

    pub fn deinit(self: *RuntimeHost) void {
        self.detachQueueMirror();
        self.clearQueueMirror();
        self.steering_mirror.deinit(self.allocator);
        self.follow_up_mirror.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn setLifecycleHooks(self: *RuntimeHost, hooks: LifecycleHooks) void {
        self.lifecycle_hooks = hooks;
    }

    pub fn attachQueueMirror(self: *RuntimeHost) void {
        self.session.agent.setQueueObserver(.{
            .func = &queueMutationCallback,
            .ctx = @ptrCast(self),
        });
    }

    pub fn detachQueueMirror(self: *RuntimeHost) void {
        self.session.agent.setQueueObserver(null);
    }

    /// Agent-thread-only helper for the queued-input restore flow.
    /// Clones the runtime-owned queue mirror first, then clears the
    /// authoritative agent queues so the observer drains the mirror in
    /// the same order. Callers own the returned snapshot.
    pub fn restoreQueuedMessagesOnAgentThread(self: *RuntimeHost, allocator: std.mem.Allocator) !QueuedMessageSnapshot {
        var snapshot = try self.cloneQueueMirrorSnapshot(allocator);
        errdefer snapshot.deinit(allocator);
        self.session.agent.clearAllQueues();
        return snapshot;
    }

    pub fn abortRetry(self: *RuntimeHost) void {
        self.retry_abort_requested.store(true, .release);
        self.session.agent.wakeAbortWaiters();
    }

    pub fn runUserContent(self: *RuntimeHost, content: ai.protocol.UserMessage.UserMessageContent) !RunOutcome {
        return self.runWithRecovery(.prompt, content);
    }

    pub fn continueTurn(self: *RuntimeHost) !RunOutcome {
        return self.runWithRecovery(.continue_turn, null);
    }

    pub fn runCompaction(self: *RuntimeHost, reason: CompactionReason, will_retry: bool) !CompactionResult {
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

    pub fn publishConversationState(
        self: *RuntimeHost,
        publisher: ConversationStatePublisher,
    ) bool {
        var view = self.session.agent.cloneConversationView(self.allocator) catch return false;
        errdefer view.deinit(self.allocator);

        var queued = self.cloneQueueMirrorSnapshot(self.allocator) catch return false;
        errdefer queued.deinit(self.allocator);

        publisher.publish(.{
            .view = view,
            .queued = queued,
        });
        return true;
    }

    fn runWithRecovery(
        self: *RuntimeHost,
        initial_mode: RunMode,
        prompt_content: ?ai.protocol.UserMessage.UserMessageContent,
    ) !RunOutcome {
        self.retry_attempt = 0;
        self.overflow_recovery_attempted = false;
        self.retry_abort_requested.store(false, .release);
        defer {
            self.retry_attempt = 0;
            self.overflow_recovery_attempted = false;
            self.retry_abort_requested.store(false, .release);
        }

        var mode = initial_mode;
        while (true) {
            switch (mode) {
                .prompt => try self.session.runUserContent(prompt_content.?),
                .continue_turn => try self.session.continueSession(),
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
                self.session.agent.modelValue().context_window,
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

                    self.notifyRetryWaitFinished();
                    mode = .continue_turn;
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
                    mode = .continue_turn;
                },
                else => return outcome,
            }
        }
    }

    fn latestAssistantMessage(self: *RuntimeHost) ?ai.protocol.AssistantMessage {
        return self.session.agent.latestAssistant();
    }

    fn resolveRunOutcome(self: *RuntimeHost) RunOutcome {
        if (self.session.agent.isAbortRequested()) return .aborted;
        const assistant = self.latestAssistantMessage() orelse return .success;
        return switch (assistant.stop_reason) {
            .aborted => .aborted,
            .@"error" => .assistant_error,
            else => .success,
        };
    }

    fn isLatestAssistantFromCurrentModel(self: *const RuntimeHost, assistant: ai.protocol.AssistantMessage) bool {
        const model = self.session.agent.modelValue();
        return std.mem.eql(u8, json_util.providerToString(assistant.provider), json_util.providerToString(model.provider)) and
            std.mem.eql(u8, assistant.model, model.id);
    }

    fn beginRetry(self: *RuntimeHost, error_message: []const u8) bool {
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

    fn computeRetryDelayMs(self: *const RuntimeHost) u64 {
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

    fn waitForRetryDelay(self: *RuntimeHost, delay_ms: u64) bool {
        return switch (self.session.agent.abortSignal().waitUntil(
            delay_ms * @as(u64, std.time.ns_per_ms),
            &retryAbortRequested,
            @ptrCast(self),
        )) {
            .aborted, .predicate => true,
            .timeout, .none => self.retry_abort_requested.load(.acquire) or self.session.agent.isAbortRequested(),
        };
    }

    fn pruneTransientAssistantError(self: *RuntimeHost) void {
        const messages = self.session.agent.messages();
        if (messages.len == 0) return;
        const last = messages[messages.len - 1];
        if (last != .assistant) return;
        if (last.assistant.stop_reason != .@"error") return;
        self.session.agent.truncateCommitted(messages.len - 1);
        self.session.agent.clearError();
    }

    fn notifyRetryStart(self: *RuntimeHost, event: RetryStart) void {
        if (self.lifecycle_hooks.on_retry_start) |cb| cb(event, self.lifecycle_hooks.ctx);
    }

    fn notifyRetryWaitFinished(self: *RuntimeHost) void {
        if (self.lifecycle_hooks.on_retry_wait_finished) |cb| cb(self.lifecycle_hooks.ctx);
    }

    fn notifyRetryEnd(self: *RuntimeHost, event: RetryEnd) void {
        if (self.lifecycle_hooks.on_retry_end) |cb| cb(event, self.lifecycle_hooks.ctx);
    }

    fn notifyCompactionEnd(self: *RuntimeHost, event: CompactionEnd) void {
        if (self.lifecycle_hooks.on_compaction_end) |cb| cb(event, self.lifecycle_hooks.ctx);
    }

    fn cloneQueueMirrorSnapshot(self: *RuntimeHost, allocator: std.mem.Allocator) !QueuedMessageSnapshot {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();

        const steering = try cloneQueuedEntries(allocator, self.steering_mirror.items);
        errdefer {
            freeQueuedEntries(allocator, steering);
            allocator.free(steering);
        }
        const follow_up = try cloneQueuedEntries(allocator, self.follow_up_mirror.items);
        return .{
            .steering = steering,
            .follow_up = follow_up,
        };
    }

    fn clearQueueMirror(self: *RuntimeHost) void {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();

        freeQueuedEntries(self.allocator, self.steering_mirror.items);
        freeQueuedEntries(self.allocator, self.follow_up_mirror.items);
        self.steering_mirror.clearRetainingCapacity();
        self.follow_up_mirror.clearRetainingCapacity();
    }

    fn applyQueueMutation(self: *RuntimeHost, action: agent_impl.QueueMutationAction, kind: QueueKind, message: agent_mod.protocol.AgentMessage) void {
        const text = control_mod.extractQueuedMessageText(message) orelse return;

        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();

        const target = switch (kind) {
            .steering => &self.steering_mirror,
            .follow_up => &self.follow_up_mirror,
        };

        switch (action) {
            .enqueued => {
                const owned = self.allocator.dupe(u8, text) catch return;
                target.append(self.allocator, .{ .text = owned }) catch self.allocator.free(owned);
            },
            .drained, .cleared => {
                if (target.items.len == 0) return;
                const entry = target.orderedRemove(0);
                self.allocator.free(entry.text);
            },
        }
    }
};

fn retryAbortRequested(ctx: ?*anyopaque) bool {
    const self: *RuntimeHost = @ptrCast(@alignCast(ctx.?));
    return self.retry_abort_requested.load(.acquire);
}

fn queueMutationCallback(
    action: agent_impl.QueueMutationAction,
    kind: QueueKind,
    message: agent_mod.protocol.AgentMessage,
    ctx: ?*anyopaque,
) void {
    const self: *RuntimeHost = @ptrCast(@alignCast(ctx.?));
    self.applyQueueMutation(action, kind, message);
}

fn cloneQueuedEntries(
    allocator: std.mem.Allocator,
    entries: []const control_mod.QueuedMessageText,
) ![]control_mod.QueuedMessageText {
    var out: std.ArrayListUnmanaged(control_mod.QueuedMessageText) = .empty;
    errdefer {
        freeQueuedEntries(allocator, out.items);
        out.deinit(allocator);
    }

    for (entries) |entry| {
        const text = try allocator.dupe(u8, entry.text);
        errdefer allocator.free(text);
        try out.append(allocator, .{ .text = text });
    }
    return try out.toOwnedSlice(allocator);
}

fn freeQueuedEntries(allocator: std.mem.Allocator, entries: []control_mod.QueuedMessageText) void {
    for (entries) |entry| allocator.free(entry.text);
}

const testing = std.testing;
const faux = ai.faux;
const resources = @import("resources/root.zig");

const LifecycleCollector = struct {
    allocator: std.mem.Allocator,
    retry_starts: std.ArrayListUnmanaged(RetryStart) = .empty,
    retry_ends: std.ArrayListUnmanaged(RetryEnd) = .empty,
    compaction_ends: std.ArrayListUnmanaged(CompactionEnd) = .empty,
    retry_wait_finished_count: usize = 0,

    fn onRetryStart(event: RetryStart, ctx: ?*anyopaque) void {
        const self: *LifecycleCollector = @ptrCast(@alignCast(ctx.?));
        self.retry_starts.append(self.allocator, event) catch {};
    }

    fn onRetryWaitFinished(ctx: ?*anyopaque) void {
        const self: *LifecycleCollector = @ptrCast(@alignCast(ctx.?));
        self.retry_wait_finished_count += 1;
    }

    fn onRetryEnd(event: RetryEnd, ctx: ?*anyopaque) void {
        const self: *LifecycleCollector = @ptrCast(@alignCast(ctx.?));
        self.retry_ends.append(self.allocator, event) catch {};
    }

    fn onCompactionEnd(event: CompactionEnd, ctx: ?*anyopaque) void {
        const self: *LifecycleCollector = @ptrCast(@alignCast(ctx.?));
        self.compaction_ends.append(self.allocator, event) catch {};
    }

    fn deinit(self: *LifecycleCollector) void {
        self.retry_starts.deinit(self.allocator);
        self.retry_ends.deinit(self.allocator);
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

test "runtime host publishes committed and queued conversation state" {
    var session = AgentSession.init(testing.allocator, .{
        .model = faux.fauxModel(),
        .api_key = "test-key",
        .cwd = "/tmp/zi-test",
        .resource_loader = resources.ResourceLoader.init(testing.allocator, .{ .cwd = "/tmp/zi-test" }) catch @panic("OOM"),
        .tools = &.{},
        .no_session = true,
    });
    defer session.deinit();

    try session.agent.setMessages(&.{.{ .user = .{
        .content = .{ .text = "hello" },
        .timestamp = 1,
    } }});

    var published: ?conversation_state.PublishedConversationState = null;
    defer if (published) |*state| state.deinit(testing.allocator);

    const Capture = struct {
        fn publish(state: conversation_state.PublishedConversationState, ctx: ?*anyopaque) void {
            const out: *?conversation_state.PublishedConversationState = @ptrCast(@alignCast(ctx.?));
            out.* = state;
        }
    };

    var host = try RuntimeHost.init(&session, testing.allocator, .{});
    defer host.deinit();
    host.attachQueueMirror();
    defer host.detachQueueMirror();

    try testing.expectEqual(.ok, session.agent.followUp(.{ .user = .{
        .content = .{ .text = "queued" },
        .timestamp = 2,
    } }));

    try testing.expect(host.publishConversationState(.{
        .func = &Capture.publish,
        .ctx = @ptrCast(&published),
    }));
    try testing.expect(published != null);
    try testing.expectEqual(@as(usize, 1), published.?.view.committed.len);
    try testing.expectEqualStrings("hello", published.?.view.committed[0].user.content.text);
    try testing.expectEqual(@as(usize, 0), published.?.queued.steering.len);
    try testing.expectEqual(@as(usize, 1), published.?.queued.follow_up.len);
    try testing.expectEqualStrings("queued", published.?.queued.follow_up[0].text);
}

test "runtime host retries transient assistant failures and prunes the failed assistant turn before continue" {
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

    var collector = LifecycleCollector{ .allocator = allocator };
    defer collector.deinit();

    var host = try RuntimeHost.init(&session, allocator, .{
        .retry_policy = .{
            .enabled = true,
            .max_retries = 2,
            .base_delay_ms = 0,
            .max_delay_ms = 0,
        },
    });
    defer host.deinit();
    host.attachQueueMirror();
    defer host.detachQueueMirror();
    host.setLifecycleHooks(.{
        .on_retry_start = &LifecycleCollector.onRetryStart,
        .on_retry_wait_finished = &LifecycleCollector.onRetryWaitFinished,
        .on_retry_end = &LifecycleCollector.onRetryEnd,
        .ctx = @ptrCast(&collector),
    });

    const outcome = try host.runUserContent(.{ .text = "hi" });

    try testing.expectEqual(RunOutcome.success, outcome);
    try testing.expectEqual(@as(usize, 2), fp.call_count);
    try testing.expectEqual(@as(usize, 1), collector.retry_starts.items.len);
    try testing.expectEqual(@as(usize, 1), collector.retry_ends.items.len);
    try testing.expectEqual(@as(usize, 1), collector.retry_wait_finished_count);
    try testing.expectEqual(@as(u32, 1), collector.retry_starts.items[0].attempt);
    try testing.expectEqual(@as(u32, 1), collector.retry_ends.items[0].attempt);
    try testing.expect(collector.retry_ends.items[0].success);
    try testing.expectEqual(@as(usize, 2), session.agent.messages().len);
    try testing.expectEqualStrings("recovered", session.agent.messages()[1].assistant.content[0].text.text);
}

test "runtime host recovers overflow with one compaction pass before retrying continue" {
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

    var collector = LifecycleCollector{ .allocator = allocator };
    defer collector.deinit();

    var compaction_spy = CompactionSpy{ .allocator = allocator };
    defer compaction_spy.deinit();

    var host = try RuntimeHost.init(&session, allocator, .{
        .compaction_executor = .{
            .func = &CompactionSpy.execute,
            .ctx = @ptrCast(&compaction_spy),
        },
    });
    defer host.deinit();
    host.attachQueueMirror();
    defer host.detachQueueMirror();
    host.setLifecycleHooks(.{
        .on_retry_start = &LifecycleCollector.onRetryStart,
        .on_retry_end = &LifecycleCollector.onRetryEnd,
        .on_compaction_end = &LifecycleCollector.onCompactionEnd,
        .ctx = @ptrCast(&collector),
    });

    const outcome = try host.runUserContent(.{ .text = "hi" });

    try testing.expectEqual(RunOutcome.success, outcome);
    try testing.expectEqual(@as(usize, 2), fp.call_count);
    try testing.expectEqual(@as(usize, 1), compaction_spy.calls.items.len);
    try testing.expectEqual(CompactionReason.overflow, compaction_spy.calls.items[0]);
    try testing.expectEqual(@as(usize, 1), collector.compaction_ends.items.len);
    try testing.expect(collector.compaction_ends.items[0].success);
    try testing.expect(collector.compaction_ends.items[0].will_retry);
    try testing.expectEqual(@as(usize, 0), collector.retry_starts.items.len);
    try testing.expectEqual(@as(usize, 2), session.agent.messages().len);
    try testing.expectEqualStrings("after compaction", session.agent.messages()[1].assistant.content[0].text.text);
}
