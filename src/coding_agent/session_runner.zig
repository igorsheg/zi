const std = @import("std");
const agent_session_mod = @import("agent_session.zig");
const AgentSession = agent_session_mod.AgentSession;
const ai = @import("../ai/root.zig");
const json_util = @import("../ai/json_util.zig");
const session_event_mod = @import("session_event.zig");
const classifier = @import("session_error_classifier.zig");

pub const RunOutcome = enum {
    success,
    assistant_error,
    aborted,
};

pub const RetryStart = session_event_mod.RetryStart;
pub const RetryEnd = session_event_mod.RetryEnd;
pub const CompactionReason = session_event_mod.CompactionReason;
pub const CompactionEnd = session_event_mod.CompactionEnd;
pub const SessionEvent = session_event_mod.SessionEvent;

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
    func: *const fn (session: *AgentSession, reason: CompactionReason, policy: CompactionPolicy, ctx: ?*anyopaque) anyerror!CompactionResult,
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

pub const EventEmitter = struct {
    func: *const fn (event: SessionEvent, ctx: ?*anyopaque) void,
    ctx: ?*anyopaque = null,

    pub fn emit(self: EventEmitter, event: SessionEvent) void {
        self.func(event, self.ctx);
    }
};

/// Owns retry, overflow, and compaction recovery around a replaceable
/// AgentSession. Callers pass the current session for each run so the
/// runner never retains a stale runtime pointer across replacement.
pub const SessionRunner = struct {
    retry_policy: RetryPolicy,
    compaction_policy: CompactionPolicy,
    compaction_executor: ?CompactionExecutor,
    lifecycle_hooks: LifecycleHooks = .{},
    retry_attempt: u32 = 0,
    overflow_recovery_attempted: bool = false,
    retry_abort_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    const RunMode = enum {
        prompt,
        continue_turn,
    };

    pub fn init(options: Options) SessionRunner {
        return .{
            .retry_policy = options.retry_policy,
            .compaction_policy = options.compaction_policy,
            .compaction_executor = options.compaction_executor,
        };
    }

    pub fn setLifecycleHooks(self: *SessionRunner, hooks: LifecycleHooks) void {
        self.lifecycle_hooks = hooks;
    }

    pub fn setCompactionExecutor(self: *SessionRunner, executor: ?CompactionExecutor) void {
        self.compaction_executor = executor;
    }

    pub fn abortRetry(self: *SessionRunner, session: *AgentSession) void {
        self.retry_abort_requested.store(true, .release);
        session.agent.wakeAbortWaiters();
    }

    pub fn runUserContent(
        self: *SessionRunner,
        session: *AgentSession,
        emitter: EventEmitter,
        content: ai.protocol.UserMessage.UserMessageContent,
    ) !RunOutcome {
        return self.runWithRecovery(session, emitter, .prompt, content);
    }

    pub fn continueTurn(
        self: *SessionRunner,
        session: *AgentSession,
        emitter: EventEmitter,
    ) !RunOutcome {
        return self.runWithRecovery(session, emitter, .continue_turn, null);
    }

    pub fn runCompaction(
        self: *SessionRunner,
        session: *AgentSession,
        emitter: EventEmitter,
        reason: CompactionReason,
        will_retry: bool,
    ) !CompactionResult {
        if (!self.compaction_policy.enabled) {
            self.notifyCompactionEnd(emitter, .{
                .reason = reason,
                .success = false,
                .will_retry = false,
                .error_message = "CompactionDisabled",
            });
            return error.CompactionDisabled;
        }

        const executor = self.compaction_executor orelse {
            self.notifyCompactionEnd(emitter, .{
                .reason = reason,
                .success = false,
                .will_retry = false,
                .error_message = "CompactionUnavailable",
            });
            return error.CompactionUnavailable;
        };

        const result = executor.func(session, reason, self.compaction_policy, executor.ctx) catch |err| {
            self.notifyCompactionEnd(emitter, .{
                .reason = reason,
                .success = false,
                .will_retry = false,
                .error_message = @errorName(err),
            });
            return err;
        };

        self.notifyCompactionEnd(emitter, .{
            .reason = reason,
            .success = true,
            .will_retry = will_retry,
        });
        return result;
    }

    fn runWithRecovery(
        self: *SessionRunner,
        session: *AgentSession,
        emitter: EventEmitter,
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
                .prompt => try session.runUserContent(prompt_content.?),
                .continue_turn => try session.continueSession(),
            }

            const outcome = resolveRunOutcome(session);
            if (outcome != .assistant_error) {
                self.overflow_recovery_attempted = false;
                if (self.retry_attempt > 0) {
                    self.notifyRetryEnd(emitter, .{
                        .success = true,
                        .attempt = self.retry_attempt,
                    });
                }
                return outcome;
            }

            const assistant = latestAssistantMessage(session) orelse return outcome;
            const classification = classifier.classifyAssistantMessage(
                &assistant,
                session.agent.modelValue().context_window,
            );
            switch (classification.class) {
                .retryable_transient => {
                    if (!self.beginRetry(emitter, classification.error_message orelse assistant.error_message orelse "unknown error")) {
                        return outcome;
                    }

                    pruneTransientAssistantError(session);
                    if (self.waitForRetryDelay(session, self.computeRetryDelayMs())) {
                        self.notifyRetryEnd(emitter, .{
                            .success = false,
                            .attempt = self.retry_attempt,
                            .final_error = "Retry cancelled",
                        });
                        return .aborted;
                    }

                    self.notifyRetryWaitFinished(emitter);
                    mode = .continue_turn;
                },
                .overflow => {
                    if (!isLatestAssistantFromCurrentModel(session, assistant)) return outcome;
                    if (self.overflow_recovery_attempted) {
                        self.notifyCompactionEnd(emitter, .{
                            .reason = .overflow,
                            .success = false,
                            .will_retry = false,
                            .error_message = "Context overflow recovery failed after one compact-and-retry attempt. Try reducing context or switching to a larger-context model.",
                        });
                        return outcome;
                    }

                    self.overflow_recovery_attempted = true;
                    pruneTransientAssistantError(session);
                    _ = self.runCompaction(session, emitter, .overflow, true) catch return outcome;
                    mode = .continue_turn;
                },
                else => return outcome,
            }
        }
    }

    fn latestAssistantMessage(session: *AgentSession) ?ai.protocol.AssistantMessage {
        return session.agent.latestAssistant();
    }

    fn resolveRunOutcome(session: *AgentSession) RunOutcome {
        if (session.agent.isAbortRequested()) return .aborted;
        const assistant = latestAssistantMessage(session) orelse return .success;
        return switch (assistant.stop_reason) {
            .aborted => .aborted,
            .@"error" => .assistant_error,
            else => .success,
        };
    }

    fn isLatestAssistantFromCurrentModel(session: *const AgentSession, assistant: ai.protocol.AssistantMessage) bool {
        const model = session.agent.modelValue();
        return std.mem.eql(u8, json_util.providerToString(assistant.provider), json_util.providerToString(model.provider)) and
            std.mem.eql(u8, assistant.model, model.id);
    }

    fn beginRetry(self: *SessionRunner, emitter: EventEmitter, error_message: []const u8) bool {
        if (!self.retry_policy.enabled) return false;

        const next_attempt = self.retry_attempt + 1;
        if (next_attempt > self.retry_policy.max_retries) {
            self.notifyRetryEnd(emitter, .{
                .success = false,
                .attempt = self.retry_attempt,
                .final_error = error_message,
            });
            return false;
        }

        self.retry_attempt = next_attempt;
        self.notifyRetryStart(emitter, .{
            .attempt = self.retry_attempt,
            .max_attempts = self.retry_policy.max_retries,
            .delay_ms = self.computeRetryDelayMs(),
            .error_message = error_message,
        });
        return true;
    }

    fn computeRetryDelayMs(self: *const SessionRunner) u64 {
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

    fn waitForRetryDelay(self: *SessionRunner, session: *AgentSession, delay_ms: u64) bool {
        return switch (session.agent.abortSignal().waitUntil(
            delay_ms * @as(u64, std.time.ns_per_ms),
            &retryAbortRequested,
            @ptrCast(self),
        )) {
            .aborted, .predicate => true,
            .timeout, .none => self.retry_abort_requested.load(.acquire) or session.agent.isAbortRequested(),
        };
    }

    fn pruneTransientAssistantError(session: *AgentSession) void {
        const messages = session.agent.messages();
        if (messages.len == 0) return;
        const last = messages[messages.len - 1];
        if (last != .assistant) return;
        if (last.assistant.stop_reason != .@"error") return;
        // Only clear the error flag if we actually removed the message
        // — otherwise the error-bearing message stays committed while
        // the flag says "no error," which is a control-flow lie.
        session.agent.truncateCommitted(messages.len - 1) catch return;
        session.agent.clearError();
    }

    fn notifyRetryStart(self: *SessionRunner, emitter: EventEmitter, event: RetryStart) void {
        emitter.emit(.{ .auto_retry_start = event });
        if (self.lifecycle_hooks.on_retry_start) |cb| cb(event, self.lifecycle_hooks.ctx);
    }

    fn notifyRetryWaitFinished(self: *SessionRunner, emitter: EventEmitter) void {
        emitter.emit(.{ .auto_retry_wait_finished = {} });
        if (self.lifecycle_hooks.on_retry_wait_finished) |cb| cb(self.lifecycle_hooks.ctx);
    }

    fn notifyRetryEnd(self: *SessionRunner, emitter: EventEmitter, event: RetryEnd) void {
        emitter.emit(.{ .auto_retry_end = event });
        if (self.lifecycle_hooks.on_retry_end) |cb| cb(event, self.lifecycle_hooks.ctx);
    }

    fn notifyCompactionEnd(self: *SessionRunner, emitter: EventEmitter, event: CompactionEnd) void {
        emitter.emit(.{ .compaction_end = event });
        if (self.lifecycle_hooks.on_compaction_end) |cb| cb(event, self.lifecycle_hooks.ctx);
    }
};

fn retryAbortRequested(ctx: ?*anyopaque) bool {
    const self: *SessionRunner = @ptrCast(@alignCast(ctx.?));
    return self.retry_abort_requested.load(.acquire);
}
