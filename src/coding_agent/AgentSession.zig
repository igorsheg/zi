//! One session's policy spine: prompt resources, system prompt, builtin
//! tools, durable history, the long-lived agent, the bounded public event
//! queue, lifecycle, and the compaction/retry terminal policies.
//!
//! Compaction and retry are operation-backed: the session computes verdicts
//! and starts producer-backed runs; the owner loop does all waiting.

const std = @import("std");
const agent_mod = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const runtime = @import("../runtime/root.zig");
const bash_tool = @import("tools/bash.zig");
const event_drain_mod = @import("event_drain.zig");
const message_policy = @import("message_policy.zig");
const resources = @import("resources.zig");
const client_protocol = @import("client_protocol.zig");
const session_manager = @import("session_manager.zig");
const system_prompt = @import("system_prompt.zig");
const tool_registry = @import("tool_registry.zig");

const AgentSession = @This();

pub const public_event_capacity_default = 256;
const max_compaction_summary_prompt_bytes = session_manager.max_compaction_serialized_input_bytes + 16 * 1024;
const live_prompt_event_capacity_count = 64;

const summarization_system_prompt =
    \\You are a context summarization assistant. Your task is to read a conversation between a user and an AI coding assistant, then produce a structured summary following the exact format specified.
    \\
    \\Do NOT continue the conversation. Do NOT respond to any questions in the conversation. ONLY output the structured summary.
;

const summarization_prompt =
    \\The messages above are a conversation to summarize. Create a structured context checkpoint summary that another LLM will use to continue the work.
    \\
    \\Use this EXACT format:
    \\
    \\## Goal
    \\[What is the user trying to accomplish? Can be multiple items if the session covers different tasks.]
    \\
    \\## Constraints & Preferences
    \\- [Any constraints, preferences, or requirements mentioned by user]
    \\- [Or "(none)" if none were mentioned]
    \\
    \\## Progress
    \\### Done
    \\- [x] [Completed tasks/changes]
    \\
    \\### In Progress
    \\- [ ] [Current work]
    \\
    \\### Blocked
    \\- [Issues preventing progress, if any]
    \\
    \\## Key Decisions
    \\- **[Decision]**: [Brief rationale]
    \\
    \\## Next Steps
    \\1. [Ordered list of what should happen next]
    \\
    \\## Critical Context
    \\- [Any data, examples, or references needed to continue]
    \\- [Or "(none)" if not applicable]
    \\
    \\Keep each section concise. Preserve exact file paths, function names, and error messages.
;

const update_summarization_prompt =
    \\The messages above are NEW conversation messages to incorporate into the existing summary provided in <previous-summary> tags.
    \\
    \\Update the existing structured summary with new information. RULES:
    \\- PRESERVE all existing information from the previous summary
    \\- ADD new progress, decisions, and context from the new messages
    \\- UPDATE the Progress section: move items from "In Progress" to "Done" when completed
    \\- UPDATE "Next Steps" based on what was accomplished
    \\- PRESERVE exact file paths, function names, and error messages
    \\- If something is no longer relevant, you may remove it
    \\
    \\Use this EXACT format:
    \\
    \\## Goal
    \\[Preserve existing goals, add new ones if the task expanded]
    \\
    \\## Constraints & Preferences
    \\- [Preserve existing, add new ones discovered]
    \\
    \\## Progress
    \\### Done
    \\- [x] [Include previously done items AND newly completed items]
    \\
    \\### In Progress
    \\- [ ] [Current work - update based on progress]
    \\
    \\### Blocked
    \\- [Current blockers - remove if resolved]
    \\
    \\## Key Decisions
    \\- **[Decision]**: [Brief rationale] (preserve all previous, add new)
    \\
    \\## Next Steps
    \\1. [Update based on current state]
    \\
    \\## Critical Context
    \\- [Preserve important context, add new if needed]
    \\
    \\Keep each section concise. Preserve exact file paths, function names, and error messages.
;

const turn_prefix_summarization_prompt =
    \\This is the PREFIX of a turn that was too large to keep. The SUFFIX (recent work) is retained.
    \\
    \\Summarize the prefix to provide context for the retained suffix:
    \\
    \\## Original Request
    \\[What did the user ask for in this turn?]
    \\
    \\## Early Progress
    \\- [Key decisions and work done in the prefix]
    \\
    \\## Context for Suffix
    \\- [Information needed to understand the retained recent work]
    \\
    \\Be concise. Focus on what's needed to understand the kept suffix.
;

allocator: std.mem.Allocator,
io: std.Io,
task_runtime: *runtime.Runtime,
system_prompt_text: []const u8,
builtin_tools: *tool_registry.BuiltinTools,
manager: *session_manager.SessionManager,
store: ?*session_manager.SessionStore = null,
agent: *agent_mod.Agent,
event_drain: *event_drain_mod.EventDrain,
lifecycle: Lifecycle = .accepting,
compaction_settings: session_manager.CompactionSettings = .{},
retry_settings: RetrySettings = .{},
hide_thinking: bool = true,

pub const Options = struct {
    cwd: []const u8,
    agent_dir: []const u8,
    current_date: []const u8,
    session_id: []const u8,
    timestamp: []const u8,
    model: ai.Model = agent_mod.Agent.defaultModel(),
    thinking_level: agent_mod.ThinkingLevel = .off,
    compaction_settings: session_manager.CompactionSettings = .{},
    retry_settings: RetrySettings = .{},
    hide_thinking: bool = true,
    stream: ?ai.StreamFunction = null,
    get_api_key: ?agent_mod.GetApiKeyHook = null,
    dir: std.Io.Dir = .cwd(),
    environ: ?*const std.process.Environ.Map = null,
    allow_paths_outside_cwd: bool = true,
    public_event_capacity: usize = public_event_capacity_default,
    store: ?StoreOptions = null,
    task_runtime: *runtime.Runtime,
};

/// A store either persists a fresh session or restores an existing one;
/// the two cases cannot be combined, so they are one union field.
pub const StoreOptions = union(enum) {
    create: session_manager.SessionStore,
    restore: session_manager.SessionStore,
};

pub const QueuePromptKind = enum { steer, follow_up };

pub const RetrySettings = struct {
    enabled: bool = false,
    max_attempts: u8 = 3,
    base_delay_ms: u64 = 2_000,
};

/// Hard ceiling on one retry backoff wait, whatever the settings say.
pub const retry_delay_max_ms = 60_000;

/// What the owner should do after a prompt or compaction run settles.
/// `retry` means the owner waits `delay_ms`, then starts the retry run;
/// `compact` hands the owner a live summary run to drive. The session
/// never blocks here.
pub const SettleVerdict = union(enum) {
    completed,
    failed,
    retry: Retry,
    compact: *CompactionRun,

    pub const Retry = struct {
        kind: Kind,
        delay_ms: u64,

        pub const Kind = enum {
            /// Re-issue the original prompt (after overflow compaction).
            resubmit_prompt,
            /// Continue the run from the repaired transcript.
            continue_run,
        };
    };
};

pub const SettleContext = struct {
    overflow_count_before: usize,
    overflow_retry_used: bool,
};

/// One in-flight compaction summary generation: a bare one-shot agent-loop
/// run (no tools, no queue hooks, empty context) under its own cancel
/// source. The producer streams; the owner polls; settle applies the result.
pub const CompactionRun = struct {
    state: enum { producing, settled } = .producing,
    stream: agent_mod.loop.AgentEventStream = undefined,
    buffer: [live_prompt_event_capacity_count]agent_mod.loop.StreamEvent = undefined,
    prompts: [1]agent_mod.AgentMessage = undefined,
    cancel: runtime.CancelSource,
    reason: client_protocol.CompactionReason,
    will_retry: bool,
    input: session_manager.CompactionSummaryInput,
    summary_prompt: []const u8,
    outcome: Outcome = .pending,

    const Outcome = union(enum) {
        pending,
        summary: []const u8,
        failure: anyerror,
    };
};

pub const PromptRun = struct {
    state: State = .settled,
    stream: agent_mod.loop.AgentEventStream = undefined,
    buffer: [live_prompt_event_capacity_count]agent_mod.loop.StreamEvent = undefined,
    prompts: [1]agent_mod.AgentMessage = undefined,

    const State = union(enum) {
        running: runtime.CancelToken,
        cancel_requested: runtime.CancelToken,
        settled,
    };

    fn terminalToken(self: *const PromptRun) ?runtime.CancelToken {
        return switch (self.state) {
            .running, .cancel_requested => |token| token,
            .settled => null,
        };
    }

    fn isActive(self: *const PromptRun) bool {
        return self.terminalToken() != null;
    }

    fn markCancelRequested(self: *PromptRun) ?runtime.CancelToken {
        return switch (self.state) {
            .running => |token| {
                self.state = .{ .cancel_requested = token };
                return token;
            },
            .cancel_requested => |token| token,
            .settled => null,
        };
    }

    fn markSettled(self: *PromptRun) void {
        std.debug.assert(self.state != .settled);
        self.state = .settled;
    }
};

const Lifecycle = enum {
    accepting,
    cancel_requested,
    shutdown_requested,
    stopped,
};

pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) !AgentSession {
    const task_runtime = options.task_runtime;

    var prompt_resources = try resources.PromptResources.load(allocator, io, .{
        .dir = options.dir,
        .agent_dir = options.agent_dir,
        .cwd = options.cwd,
    });
    defer prompt_resources.deinit();

    const builtin_tools = try tool_registry.BuiltinTools.init(allocator, .{
        .cwd = options.cwd,
        .environ = options.environ,
        .allow_paths_outside_cwd = options.allow_paths_outside_cwd,
    });
    errdefer builtin_tools.deinit();

    const tools = try builtin_tools.registry();

    const system_prompt_text = try buildSystemPromptText(
        allocator,
        options.cwd,
        options.current_date,
        &prompt_resources,
        &tools,
    );
    errdefer allocator.free(system_prompt_text);

    const manager = try allocator.create(session_manager.SessionManager);
    errdefer allocator.destroy(manager);
    manager.* = if (options.store != null and options.store.? == .restore)
        try options.store.?.restore.load(io)
    else
        try session_manager.SessionManager.init(
            allocator,
            options.cwd,
            options.session_id,
            options.timestamp,
        );
    errdefer manager.deinit();

    const store = if (options.store) |store_options| blk: {
        const store_ptr = try allocator.create(session_manager.SessionStore);
        store_ptr.* = switch (store_options) {
            .create, .restore => |provided| provided,
        };
        break :blk store_ptr;
    } else null;
    errdefer if (store) |store_ptr| {
        store_ptr.deinit();
        allocator.destroy(store_ptr);
    };

    const context_messages = try manager.contextMessages(allocator);
    defer session_manager.SessionManager.deinitContextMessages(allocator, context_messages);

    var agent_options: agent_mod.Agent.Options = .{
        .system_prompt = system_prompt_text,
        .model = options.model,
        .thinking_level = options.thinking_level,
        .tools = tools.activeAgentTools(),
        .messages = context_messages,
        .task_runtime = task_runtime,
        .after_tool_call = .{ .call_fn = classifyToolResultAfterCall },
    };
    if (options.stream) |stream| agent_options.stream = stream;
    if (options.get_api_key) |get_api_key| agent_options.get_api_key = get_api_key;

    const core_agent = try allocator.create(agent_mod.Agent);
    errdefer allocator.destroy(core_agent);
    core_agent.* = try agent_mod.Agent.init(allocator, io, agent_options);
    errdefer core_agent.deinit();

    const event_drain = try allocator.create(event_drain_mod.EventDrain);
    errdefer allocator.destroy(event_drain);
    event_drain.* = try event_drain_mod.EventDrain.init(
        allocator,
        io,
        manager,
        store,
        options.public_event_capacity,
    );
    errdefer event_drain.deinit();

    _ = try core_agent.subscribe(.{ .context = event_drain, .call_fn = drainAgentEvent });

    return .{
        .allocator = allocator,
        .io = io,
        .task_runtime = task_runtime,
        .system_prompt_text = system_prompt_text,
        .builtin_tools = builtin_tools,
        .manager = manager,
        .store = store,
        .agent = core_agent,
        .event_drain = event_drain,
        .lifecycle = .accepting,
        .compaction_settings = options.compaction_settings,
        .retry_settings = options.retry_settings,
        .hide_thinking = options.hide_thinking,
    };
}

/// Asserts shutdownComplete(); call requestShutdown() and keep draining before deinit.
pub fn deinit(self: *AgentSession) void {
    self.reconcileLifecycle();
    std.debug.assert(self.shutdownComplete());
    self.agent.deinit();
    self.allocator.destroy(self.agent);
    self.event_drain.deinit();
    self.allocator.destroy(self.event_drain);
    if (self.store) |store| {
        store.deinit();
        self.allocator.destroy(store);
    }
    self.manager.deinit();
    self.allocator.destroy(self.manager);
    self.builtin_tools.deinit();
    self.allocator.free(self.system_prompt_text);
    self.* = undefined;
}

pub fn startPromptRun(
    self: *AgentSession,
    text: []const u8,
    images: []const ai.ImageContent,
) !*PromptRun {
    const run = try self.createPromptRun();
    errdefer if (run.isActive()) self.destroyPromptRun(run) else self.allocator.destroy(run);
    run.prompts[0] = try self.agent.userMessageFromText(text, images);
    const token = try self.beginPromptRun(run);
    agent_mod.loop.startPromptStream(
        &run.stream,
        self.allocator,
        self.task_runtime,
        &run.prompts,
        self.agentContext(),
        self.agent.loopConfig(),
        token,
        &run.buffer,
    );
    return run;
}

/// Begin a run that continues from the current transcript without a new
/// user message: the retry path after the failed assistant message has been
/// removed. Fails if the transcript still ends with an assistant message.
pub fn startContinueRun(self: *AgentSession) !*PromptRun {
    if (self.agent.state.messages.len == 0) return error.NoMessages;
    if (self.agent.state.messages[self.agent.state.messages.len - 1] == .assistant) {
        return error.CannotContinueFromAssistant;
    }
    const run = try self.createPromptRun();
    errdefer if (run.isActive()) self.destroyPromptRun(run) else self.allocator.destroy(run);
    const token = try self.beginPromptRun(run);
    agent_mod.loop.startContinueStream(
        &run.stream,
        self.allocator,
        self.task_runtime,
        self.agentContext(),
        self.agent.loopConfig(),
        token,
        &run.buffer,
    );
    return run;
}

/// Apply one stream progress result. Returns true while the run is live.
pub fn applyPromptRunProgress(
    self: *AgentSession,
    run: *PromptRun,
    progress: ?agent_mod.loop.StreamEvent,
) !bool {
    if (!run.isActive()) return false;
    var event = progress orelse {
        // Stream is done: settle the run as completed or failed.
        const token = run.terminalToken().?;
        run.stream.awaitProducer() catch |err| {
            try self.settlePromptRunFailure(run, token, @errorName(err));
            return false;
        };
        self.agent.finishRun();
        run.markSettled();
        return false;
    };
    defer event.deinit();
    try self.agent.emitEvent(event.event);
    return true;
}

pub fn cancelPromptRun(self: *AgentSession, run: *PromptRun) !void {
    const token = run.markCancelRequested() orelse return;
    self.agent.abort();
    run.stream.cancelProducer() catch |err| switch (err) {
        error.Canceled => {},
        else => {
            try self.settlePromptRunFailure(run, token, @errorName(err));
            return err;
        },
    };
    try self.settlePromptRunFailure(run, token, "aborted");
}

fn settlePromptRunFailure(
    self: *AgentSession,
    run: *PromptRun,
    token: runtime.CancelToken,
    message: []const u8,
) !void {
    std.debug.assert(run.isActive());
    try self.agent.failRun(token, message);
    self.agent.finishRun();
    run.markSettled();
}

pub fn destroyPromptRun(self: *AgentSession, run: *PromptRun) void {
    if (run.isActive()) {
        _ = run.markCancelRequested();
        run.stream.cancelProducer() catch |err| {
            const ignored_cleanup_error = @errorName(err);
            _ = ignored_cleanup_error;
        };
        self.agent.finishRun();
        run.markSettled();
    }
    run.stream.deinit();
    self.allocator.destroy(run);
}

pub fn requestShutdown(self: *AgentSession) void {
    self.reconcileLifecycle();
    switch (self.lifecycle) {
        .stopped, .shutdown_requested => return,
        .accepting, .cancel_requested => {},
    }
    if (self.agent.state.status == .settling) {
        self.lifecycle = .shutdown_requested;
        return;
    }
    if (self.agent.state.isStreaming()) {
        self.lifecycle = .shutdown_requested;
        self.agent.abort();
    } else {
        self.lifecycle = .stopped;
    }
}

pub fn shutdownComplete(self: *AgentSession) bool {
    self.reconcileLifecycle();
    return self.lifecycle == .stopped and
        self.agent.waitForIdle() and
        self.event_drain.publicEventsEmpty();
}

pub fn clientSnapshot(
    self: *const AgentSession,
    allocator: std.mem.Allocator,
    active_request_id: ?client_protocol.RequestId,
) !client_protocol.Snapshot {
    var queue = try self.event_drain.queueSnapshot(allocator);
    errdefer queue.deinit(allocator);
    var header = try client_protocol.SessionHeaderSnapshot.init(allocator, self.manager.header);
    errdefer header.deinit(allocator);
    var model = try client_protocol.ModelSnapshot.init(allocator, self.agent.state.model);
    errdefer model.deinit(allocator);
    var latest_failure = if (self.latestOperationalFailure()) |failure|
        try client_protocol.OperationalFailure.init(allocator, failure)
    else
        null;
    errdefer if (latest_failure) |*failure| failure.deinit(allocator);
    const history = try client_protocol.HistorySnapshot.fromSession(allocator, self.manager);
    return .{
        .header = header,
        .model = model,
        .thinking_level = self.agent.state.thinking_level,
        .hide_thinking = self.hide_thinking,
        .context = self.clientContextUsage(),
        .queue = queue,
        .active_request_id = active_request_id,
        .latest_failure = latest_failure,
        .history = history,
    };
}

pub fn clientChromeSnapshot(
    self: *const AgentSession,
    allocator: std.mem.Allocator,
) !client_protocol.SessionChromeSnapshot {
    return client_protocol.SessionChromeSnapshot.init(
        allocator,
        self.manager.header.cwd,
        self.agent.state.model,
        self.agent.state.thinking_level,
        self.hide_thinking,
        self.clientContextUsage(),
    );
}

fn clientContextUsage(self: *const AgentSession) client_protocol.ContextUsageSnapshot {
    const window = self.agent.state.model.context_window;
    if (window == 0) return .{};

    const entries = self.manager.entries.items;
    const latest_compaction_index = latestCompactionIndex(entries);
    const search_start = if (latest_compaction_index) |index| index + 1 else 0;
    if (latest_compaction_index != null and !hasKnownAssistantUsage(entries[search_start..])) {
        return .{ .window = window };
    }

    var usage_index: ?usize = null;
    var usage_tokens: u64 = 0;
    var index = entries.len;
    while (index > search_start) {
        index -= 1;
        const tokens = assistantContextTokens(entries[index]) orelse continue;
        usage_index = index;
        usage_tokens = tokens;
        break;
    }

    var tokens: u64 = usage_tokens;
    const estimate_start = if (usage_index) |resolved| resolved + 1 else search_start;
    for (entries[estimate_start..]) |entry| tokens +|= session_manager.SessionManager.estimateEntryTokens(entry);
    const percent_tenths = if (window == 0) null else percent: {
        const scaled = (@as(u128, tokens) * 1000) / window;
        break :percent @as(u32, @intCast(@min(scaled, std.math.maxInt(u32))));
    };
    return .{ .tokens = tokens, .window = window, .percent_tenths = percent_tenths };
}

fn latestCompactionIndex(entries: []const session_manager.SessionEntry) ?usize {
    var index = entries.len;
    while (index > 0) {
        index -= 1;
        if (entries[index] == .compaction) return index;
    }
    return null;
}

fn hasKnownAssistantUsage(entries: []const session_manager.SessionEntry) bool {
    for (entries) |entry| {
        const tokens = assistantContextTokens(entry) orelse continue;
        if (tokens > 0) return true;
    }
    return false;
}

fn assistantContextTokens(entry: session_manager.SessionEntry) ?u64 {
    if (entry != .message or entry.message.message != .assistant) return null;
    const assistant = entry.message.message.assistant;
    if (assistant.stop_reason == .aborted or assistant.stop_reason == .error_) return null;
    if (assistant.usage.total_tokens != 0) return assistant.usage.total_tokens;
    return assistant.usage.input +|
        assistant.usage.output +|
        assistant.usage.cache_read +|
        assistant.usage.cache_write;
}

pub fn clientHistoryPage(
    self: *const AgentSession,
    allocator: std.mem.Allocator,
    before_entry_id: []const u8,
) !client_protocol.HistoryPage {
    return client_protocol.HistoryPage.beforeEntry(allocator, self.manager, before_entry_id);
}

pub fn clearQueue(self: *AgentSession) void {
    self.agent.clearAllQueues();
    self.event_drain.clearQueueMirror();
}

pub fn drainPublicEvent(self: *AgentSession) ?client_protocol.ClientEvent {
    return self.event_drain.drainPublicEvent();
}

pub fn publicEventWake(self: *AgentSession) *runtime.WakeEvent {
    return self.event_drain.publicEventWake();
}

pub fn publicEventsEmpty(self: *const AgentSession) bool {
    return self.event_drain.publicEventsEmpty();
}

pub fn queuePrompt(
    self: *AgentSession,
    text: []const u8,
    images: []const ai.ImageContent,
    kind: QueuePromptKind,
) !void {
    if (!self.agent.state.isStreaming()) return error.SessionNotRunning;
    switch (kind) {
        .steer => if (!self.agent.steering_queue.hasCapacity()) return error.QueueFull,
        .follow_up => if (!self.agent.follow_up_queue.hasCapacity()) return error.QueueFull,
    }
    switch (kind) {
        .steer => try self.event_drain.appendSteering(text),
        .follow_up => try self.event_drain.appendFollowUp(text),
    }
    var mirror_committed = false;
    errdefer if (!mirror_committed) self.event_drain.removeQueuedText(text);

    const message = try self.agent.userMessageFromText(text, images);
    switch (kind) {
        .steer => try self.agent.steer(message),
        .follow_up => try self.agent.followUp(message),
    }
    mirror_committed = true;
    self.event_drain.emitQueueUpdate();
}

/// Terminal session policy after a prompt run settles. Decides between
/// completion, failure, overflow-compaction + prompt resubmission, and
/// provider-error retry with exponential backoff. Emits the retry protocol
/// events and repairs the runtime transcript; the owner does the waiting.
pub fn settlePromptRun(self: *AgentSession, context: SettleContext) !SettleVerdict {
    // Context overflow: start one summary run per operation; the owner
    // drives it as the compacting phase and resubmits on success.
    if (!context.overflow_retry_used and
        self.event_drain.context_overflow_count > context.overflow_count_before)
    {
        if (try self.startCompactionRun(.overflow, true, null)) |compaction_run| {
            return .{ .compact = compaction_run };
        }
    }

    const error_text = self.latestAssistantError() orelse return .completed;

    // Transient provider error: repair the runtime transcript (durable
    // history keeps the failure) and ask the owner to retry after backoff.
    const last = self.agent.state.messages[self.agent.state.messages.len - 1];
    if (self.retry_settings.enabled and
        message_policy.isRetryableAssistant(last.assistant) and
        self.event_drain.retry_attempt < self.retry_settings.max_attempts)
    {
        const attempt = self.event_drain.beginRetryAttempt();
        const delay_ms = retryBackoffMs(self.retry_settings, attempt);
        var error_message = try client_protocol.EventText.init(self.allocator, error_text);
        errdefer error_message.deinit(self.allocator);
        var failure = if (last.assistant.operational_failure) |value|
            try client_protocol.OperationalFailure.init(self.allocator, value)
        else
            null;
        errdefer if (failure) |*value| value.deinit(self.allocator);
        self.event_drain.enqueuePublicEvent(.{ .auto_retry_start = .{
            .attempt = attempt,
            .max_attempts = self.retry_settings.max_attempts,
            .delay_ms = delay_ms,
            .error_message = error_message,
            .failure = failure,
        } });
        try self.removeLastAssistantRuntimeMessage();
        return .{ .retry = .{ .kind = .continue_run, .delay_ms = delay_ms } };
    }

    self.event_drain.failRetry(error_text, last.assistant.operational_failure);
    return .failed;
}

/// Settle an in-flight retry that will not run (cancel or shutdown).
pub fn cancelRetryWait(self: *AgentSession) void {
    self.event_drain.failRetry("Retry cancelled", .{
        .category = .canceled,
        .message = "Retry cancelled",
        .retryable = .no,
        .provider = self.agent.state.model.provider,
        .model = self.agent.state.model.id,
    });
}

fn retryBackoffMs(settings: RetrySettings, attempt: u8) u64 {
    std.debug.assert(attempt >= 1);
    const shift: u6 = @intCast(@min(attempt - 1, 16));
    return @min(settings.base_delay_ms *| (@as(u64, 1) << shift), retry_delay_max_ms);
}

pub fn contextOverflowCount(self: *const AgentSession) usize {
    return self.event_drain.context_overflow_count;
}

fn createPromptRun(self: *AgentSession) !*PromptRun {
    try self.ensureCanStartRun();
    const run = try self.allocator.create(PromptRun);
    run.* = .{};
    return run;
}

fn beginPromptRun(self: *AgentSession, run: *PromptRun) !runtime.CancelToken {
    const token = try self.agent.beginRun();
    std.debug.assert(run.state == .settled);
    run.state = .{ .running = token };
    return token;
}

fn agentContext(self: *AgentSession) agent_mod.AgentContext {
    return .{
        .system_prompt = self.agent.state.system_prompt,
        .messages = self.agent.state.messages,
        .tools = self.agent.state.tools,
    };
}

fn ensureCanStartRun(self: *AgentSession) !void {
    self.reconcileLifecycle();
    switch (self.lifecycle) {
        .accepting => {},
        .cancel_requested => return error.SessionCancelling,
        .shutdown_requested, .stopped => return error.SessionShuttingDown,
    }
    if (self.agent.state.isStreaming()) return error.SessionBusy;
}

/// Idle transitions are observed lazily: a wake never carries data, so
/// every lifecycle read goes through this reconciliation first.
fn reconcileLifecycle(self: *AgentSession) void {
    if (!self.agent.waitForIdle()) return;
    switch (self.lifecycle) {
        .cancel_requested => self.lifecycle = .accepting,
        .shutdown_requested => self.lifecycle = .stopped,
        .accepting, .stopped => {},
    }
}

fn buildSystemPromptText(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    current_date: []const u8,
    prompt_resources: *const resources.PromptResources,
    tools: *const tool_registry.ToolRegistry,
) ![]const u8 {
    var snippets: [tool_registry.default_active_tool_names.len + 57]system_prompt.ToolSnippet = undefined;
    var snippet_count: usize = 0;
    for (tools.activeToolNames(), tools.activePromptSnippets()) |name, maybe_snippet| {
        const snippet = maybe_snippet orelse continue;
        snippets[snippet_count] = .{ .name = name, .snippet = snippet };
        snippet_count += 1;
    }

    return system_prompt.build(allocator, .{
        .cwd = cwd,
        .current_date = current_date,
        .selected_tools = tools.activeToolNames(),
        .tool_snippets = snippets[0..snippet_count],
        .context_files = prompt_resources.context_files.files,
        .skills = prompt_resources.skills.skills,
        .custom_prompt = if (prompt_resources.system_prompt.file) |file| file.content else null,
        .append_system_prompt = if (prompt_resources.append_system_prompt.file) |file| file.content else null,
    });
}

/// Start one settings-gated compaction summary run. Returns null (quietly)
/// when compaction is disabled or there is nothing to compact. Emits
/// compaction_start and spawns the summary producer; the caller owns the
/// run and must drive it to settle, then destroy it.
pub fn shouldRunThresholdCompaction(self: *const AgentSession) bool {
    const settings = self.compaction_settings;
    if (!settings.auto_enabled) return false;
    const window = self.agent.state.model.context_window;
    if (window == 0) return false;
    const usage = self.clientContextUsage();
    const tokens = usage.tokens orelse return false;
    if (settings.reserve_tokens >= window) return true;
    return tokens > window - settings.reserve_tokens;
}

pub fn startCompactionRun(
    self: *AgentSession,
    reason: client_protocol.CompactionReason,
    will_retry: bool,
    custom_instructions: ?[]const u8,
) !?*CompactionRun {
    if (reason != .manual and !self.compaction_settings.auto_enabled) return null;
    var input = self.manager.buildCompactionSummaryInput(
        self.allocator,
        self.compaction_settings,
    ) catch |err| switch (err) {
        error.NothingToCompact, error.AlreadyCompacted => return null,
        else => return err,
    };
    errdefer input.deinit();

    const serialized_input = try input.serialize(self.allocator);
    defer self.allocator.free(serialized_input);
    const turn_prefix_input = if (input.is_split_turn)
        try input.serializeTurnPrefix(self.allocator)
    else
        null;
    defer if (turn_prefix_input) |text| self.allocator.free(text);
    const summary_prompt = try self.buildCompactionSummaryPrompt(
        serialized_input,
        turn_prefix_input,
        input.previous_summary != null,
        custom_instructions,
    );
    errdefer self.allocator.free(summary_prompt);

    const run = try self.allocator.create(CompactionRun);
    errdefer self.allocator.destroy(run);
    run.* = .{
        .cancel = try runtime.CancelSource.init(self.allocator, self.io),
        .reason = reason,
        .will_retry = will_retry,
        .input = input,
        .summary_prompt = summary_prompt,
    };
    run.prompts[0] = .{ .user = .{
        .content = .{ .string = run.summary_prompt },
        .timestamp = 0,
    } };

    // The summary call is a bare one-shot loop run: empty context, no tools,
    // no queue or tool hooks. The loop owns provider auth and streaming.
    var config = self.agent.loopConfig();
    config.options.stream.max_tokens = compactionSummaryMaxTokens(self.agent.state.model, self.compaction_settings.reserve_tokens);
    config.get_steering_messages = null;
    config.get_follow_up_messages = null;
    config.before_tool_call = null;
    config.after_tool_call = null;

    self.event_drain.enqueuePublicEvent(.{ .compaction_start = .{ .reason = reason } });
    agent_mod.loop.startPromptStream(
        &run.stream,
        self.allocator,
        self.task_runtime,
        &run.prompts,
        .{ .system_prompt = summarization_system_prompt, .messages = &.{}, .tools = &.{} },
        config,
        run.cancel.token(),
        &run.buffer,
    );
    return run;
}

fn buildCompactionSummaryPrompt(
    self: *AgentSession,
    serialized_input: []const u8,
    turn_prefix_input: ?[]const u8,
    has_previous_summary: bool,
    custom_instructions: ?[]const u8,
) ![]const u8 {
    var writer: std.Io.Writer.Allocating = .init(self.allocator);
    errdefer writer.deinit();
    try appendCompactionPromptBounded(&writer, serialized_input);
    try appendCompactionPromptBounded(&writer, "\n\n");
    try appendCompactionPromptBounded(&writer, if (has_previous_summary) update_summarization_prompt else summarization_prompt);
    if (custom_instructions) |instructions| {
        try appendCompactionPromptBounded(&writer, "\n\nAdditional focus: ");
        try appendCompactionPromptBounded(&writer, instructions);
    }
    if (turn_prefix_input) |prefix_input| {
        try appendCompactionPromptBounded(&writer, "\n\n---\n\n");
        try appendCompactionPromptBounded(&writer, prefix_input);
        try appendCompactionPromptBounded(&writer, "\n\n");
        try appendCompactionPromptBounded(&writer, turn_prefix_summarization_prompt);
        try appendCompactionPromptBounded(
            &writer,
            "\n\nAppend the result after the main summary under this heading exactly:\n\n" ++
                "---\n\n**Turn Context (split turn):**\n\n",
        );
    }
    return writer.toOwnedSlice();
}

fn appendCompactionPromptBounded(writer: *std.Io.Writer.Allocating, text: []const u8) !void {
    if (text.len > max_compaction_summary_prompt_bytes or
        writer.written().len > max_compaction_summary_prompt_bytes - text.len)
    {
        return error.CompactionSummaryPromptTooLarge;
    }
    try writer.writer.writeAll(text);
}

fn compactionSummaryMaxTokens(model: ai.Model, reserve_tokens: u64) ?u32 {
    const reserve_output = (reserve_tokens * 8) / 10;
    const model_limit = if (model.max_tokens > 0) model.max_tokens else std.math.maxInt(u32);
    const raw = @min(reserve_output, model_limit, std.math.maxInt(u32));
    if (raw == 0) return 1;
    return @intCast(raw);
}

fn compactionSummaryWithFileOperations(
    self: *AgentSession,
    summary: []const u8,
    input: session_manager.CompactionSummaryInput,
) ![]const u8 {
    var read_files = std.ArrayList([]const u8).empty;
    defer read_files.deinit(self.allocator);
    var modified_files = std.ArrayList([]const u8).empty;
    defer modified_files.deinit(self.allocator);

    try collectCompactionFileOperations(self.allocator, input.messages, &read_files, &modified_files);
    try collectCompactionFileOperations(self.allocator, input.turn_prefix_messages, &read_files, &modified_files);
    removeModifiedFilesFromReadFiles(&read_files, modified_files.items);
    sortStringSlices(read_files.items);
    sortStringSlices(modified_files.items);

    if (read_files.items.len == 0 and modified_files.items.len == 0) return self.allocator.dupe(u8, summary);

    var writer: std.Io.Writer.Allocating = .init(self.allocator);
    errdefer writer.deinit();
    try appendCompactionSummaryBounded(&writer, summary);
    if (read_files.items.len > 0) {
        try appendCompactionSummaryBounded(&writer, "\n\n<read-files>\n");
        for (read_files.items) |path| {
            try appendCompactionSummaryBounded(&writer, path);
            try appendCompactionSummaryBounded(&writer, "\n");
        }
        try appendCompactionSummaryBounded(&writer, "</read-files>");
    }
    if (modified_files.items.len > 0) {
        try appendCompactionSummaryBounded(&writer, "\n\n<modified-files>\n");
        for (modified_files.items) |path| {
            try appendCompactionSummaryBounded(&writer, path);
            try appendCompactionSummaryBounded(&writer, "\n");
        }
        try appendCompactionSummaryBounded(&writer, "</modified-files>");
    }
    return writer.toOwnedSlice();
}

fn collectCompactionFileOperations(
    allocator: std.mem.Allocator,
    messages: []const agent_mod.AgentMessage,
    read_files: *std.ArrayList([]const u8),
    modified_files: *std.ArrayList([]const u8),
) !void {
    for (messages) |message| {
        if (message != .assistant) continue;
        for (message.assistant.content) |content| {
            if (content != .tool_call) continue;
            const path = toolCallPath(content.tool_call) orelse continue;
            if (std.mem.eql(u8, content.tool_call.name, "read")) {
                try appendUniqueString(allocator, read_files, path);
            } else if (std.mem.eql(u8, content.tool_call.name, "write") or
                std.mem.eql(u8, content.tool_call.name, "edit"))
            {
                try appendUniqueString(allocator, modified_files, path);
            }
        }
    }
}

fn toolCallPath(tool_call: ai.ToolCall) ?[]const u8 {
    if (tool_call.arguments != .object) return null;
    const value = tool_call.arguments.object.get("path") orelse return null;
    return if (value == .string) value.string else null;
}

fn appendUniqueString(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), value: []const u8) !void {
    for (list.items) |item| if (std.mem.eql(u8, item, value)) return;
    try list.append(allocator, value);
}

fn removeModifiedFilesFromReadFiles(read_files: *std.ArrayList([]const u8), modified_files: []const []const u8) void {
    var index: usize = 0;
    while (index < read_files.items.len) {
        for (modified_files) |modified| {
            if (std.mem.eql(u8, read_files.items[index], modified)) {
                _ = read_files.swapRemove(index);
                break;
            }
        } else {
            index += 1;
        }
    }
}

fn sortStringSlices(items: [][]const u8) void {
    std.mem.sort([]const u8, items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);
}

fn appendCompactionSummaryBounded(writer: *std.Io.Writer.Allocating, text: []const u8) !void {
    if (text.len > session_manager.max_compaction_summary_bytes or
        writer.written().len > session_manager.max_compaction_summary_bytes - text.len)
    {
        return error.CompactionSummaryTooLarge;
    }
    try writer.writer.writeAll(text);
}

/// Apply one summary-stream progress result. Returns true while the run is
/// live. The summary (or its failure) is captured on the run for settle.
pub fn applyCompactionRunProgress(
    self: *AgentSession,
    run: *CompactionRun,
    progress: ?agent_mod.loop.StreamEvent,
) !bool {
    if (run.state == .settled) return false;
    var event = progress orelse {
        run.stream.awaitProducer() catch |err| {
            if (run.outcome == .summary) self.allocator.free(run.outcome.summary);
            run.outcome = .{ .failure = err };
        };
        run.state = .settled;
        return false;
    };
    defer event.deinit();
    switch (event.event) {
        .message_end => |payload| switch (payload.message) {
            .assistant => |assistant| {
                const summary = extractCompactionSummary(self.allocator, assistant) catch |err| {
                    run.outcome = .{ .failure = err };
                    return true;
                };
                if (run.outcome == .summary) self.allocator.free(run.outcome.summary);
                run.outcome = .{ .summary = summary };
            },
            else => {},
        },
        else => {},
    }
    return true;
}

/// Terminal compaction policy. On success: persist the compaction entry,
/// replace the runtime context, emit compaction_end, and (overflow) arm the
/// resubmit retry. On failure: an overflow compaction fails the operation
/// (the context still does not fit); a threshold compaction degrades and
/// the prompt proceeds.
pub fn settleCompactionRun(self: *AgentSession, run: *CompactionRun) !SettleVerdict {
    std.debug.assert(run.state == .settled);
    const summary = switch (run.outcome) {
        .summary => |summary| summary,
        .pending, .failure => {
            const err = switch (run.outcome) {
                .failure => |failure| failure,
                else => error.MissingCompactionSummary,
            };
            const error_message = try client_protocol.EventText.init(self.allocator, @errorName(err));
            self.event_drain.enqueuePublicEvent(.{ .compaction_end = .{
                .reason = run.reason,
                .aborted = err == error.OperationCancelled,
                .will_retry = false,
                .error_message = error_message,
            } });
            if (run.will_retry) {
                self.event_drain.failRetry(@errorName(err), null);
                return .failed;
            }
            if (run.reason == .manual) return .failed;
            return .{ .retry = .{ .kind = .resubmit_prompt, .delay_ms = 0 } };
        },
    };

    const durable_summary = try self.compactionSummaryWithFileOperations(summary, run.input);
    defer self.allocator.free(durable_summary);

    // Persist the compaction entry durably before committing it in memory.
    const timestamp = session_manager.timestampNow(self.io);
    const entry = try self.manager.prepareCompactionEntry(
        durable_summary,
        run.input.first_kept_entry_id,
        run.input.tokens_before,
        &timestamp,
    );
    var entry_committed = false;
    errdefer if (!entry_committed) self.manager.deinitPreparedEntry(entry);
    if (self.store) |store| {
        try store.appendEntry(self.io, entry, self.manager.lastEntryId());
    }
    var result = try client_protocol.CompactionResult.init(self.allocator, entry.compaction);
    errdefer result.deinit(self.allocator);
    _ = self.manager.commitPreparedEntry(entry);
    entry_committed = true;

    const messages = try self.manager.contextMessages(self.allocator);
    defer session_manager.SessionManager.deinitContextMessages(self.allocator, messages);
    try self.agent.replaceMessages(messages);

    self.event_drain.enqueuePublicEvent(.{ .compaction_end = .{
        .reason = run.reason,
        .result = result,
        .aborted = false,
        .will_retry = run.will_retry,
    } });

    if (run.will_retry) {
        const attempt = self.event_drain.beginRetryAttempt();
        const error_message = try client_protocol.EventText.init(self.allocator, "context overflow");
        self.event_drain.enqueuePublicEvent(.{ .auto_retry_start = .{
            .attempt = attempt,
            .max_attempts = attempt,
            .delay_ms = 0,
            .error_message = error_message,
        } });
        return .{ .retry = .{ .kind = .resubmit_prompt, .delay_ms = 0 } };
    }
    if (run.reason == .manual) return .completed;
    return .{ .retry = .{ .kind = .resubmit_prompt, .delay_ms = 0 } };
}

/// Cancel an in-flight compaction: request, join the producer, emit the
/// aborted compaction_end. The caller still destroys the run.
pub fn cancelCompactionRun(self: *AgentSession, run: *CompactionRun) void {
    run.cancel.request();
    run.stream.cancelProducer() catch |err| {
        const ignored_cancel_error = @errorName(err);
        _ = ignored_cancel_error;
    };
    run.state = .settled;
    const error_message = client_protocol.EventText.init(self.allocator, "OperationCancelled") catch null;
    self.event_drain.enqueuePublicEvent(.{ .compaction_end = .{
        .reason = run.reason,
        .aborted = true,
        .will_retry = false,
        .error_message = error_message,
    } });
}

pub fn destroyCompactionRun(self: *AgentSession, run: *CompactionRun) void {
    run.cancel.request();
    run.stream.cancelProducer() catch |err| {
        const ignored_cleanup_error = @errorName(err);
        _ = ignored_cleanup_error;
    };
    run.stream.deinit();
    run.cancel.deinit();
    if (run.outcome == .summary) self.allocator.free(run.outcome.summary);
    self.allocator.free(run.summary_prompt);
    run.input.deinit();
    self.allocator.destroy(run);
}

fn extractCompactionSummary(
    allocator: std.mem.Allocator,
    message: ai.AssistantMessage,
) ![]const u8 {
    if (message.stop_reason == .aborted) return error.OperationCancelled;
    if (message.stop_reason == .error_) return error.CompactionSummaryGenerationFailed;

    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    for (message.content) |content| switch (content) {
        .text => |text| {
            if (text.text.len > session_manager.max_compaction_summary_bytes or
                writer.written().len > session_manager.max_compaction_summary_bytes - text.text.len)
            {
                return error.CompactionSummaryTooLarge;
            }
            try writer.writer.writeAll(text.text);
        },
        else => {},
    };
    if (writer.written().len == 0) return error.MissingCompactionSummary;
    return writer.toOwnedSlice();
}

pub fn latestOperationalFailure(self: *const AgentSession) ?ai.OperationalFailure {
    if (self.agent.state.messages.len == 0) return null;
    const last = self.agent.state.messages[self.agent.state.messages.len - 1];
    if (last != .assistant) return null;
    if (last.assistant.stop_reason != .error_ and last.assistant.stop_reason != .aborted) return null;
    return last.assistant.operational_failure;
}

fn latestAssistantError(self: *const AgentSession) ?[]const u8 {
    if (self.agent.state.messages.len == 0) return null;
    const last = self.agent.state.messages[self.agent.state.messages.len - 1];
    if (last != .assistant) return null;
    if (last.assistant.stop_reason != .error_) return null;
    return last.assistant.error_message orelse "assistant error";
}

fn removeLastAssistantRuntimeMessage(self: *AgentSession) !void {
    if (self.agent.state.messages.len == 0) return error.NoMessages;
    const retained_len = self.agent.state.messages.len - 1;
    const retained = try agent_mod.copyAgentMessages(self.allocator, self.agent.state.messages[0..retained_len]);
    defer {
        for (retained) |message| agent_mod.deinitAgentMessage(self.allocator, message);
        self.allocator.free(retained);
    }
    try self.agent.replaceMessages(retained);
}

fn classifyToolResultAfterCall(
    _: ?*anyopaque,
    _: runtime.CancelToken,
    context: agent_mod.AfterToolCallContext,
) anyerror!?agent_mod.AfterToolCallResult {
    if (std.mem.eql(u8, context.tool_call.name, "bash")) {
        return .{ .is_error = bash_tool.classifyResult(context.result.details, context.is_error) };
    }
    if (toolResultRequestsError(context.result.details)) return .{ .is_error = true };
    return null;
}

fn toolResultRequestsError(details: ?std.json.Value) bool {
    const value = details orelse return false;
    if (value != .object) return false;
    const is_error = value.object.get("isError") orelse return false;
    return is_error == .bool and is_error.bool;
}

fn drainAgentEvent(
    _: std.Io,
    context: ?*anyopaque,
    event: agent_mod.AgentEvent,
    _: runtime.CancelToken,
) anyerror!void {
    const drain: *event_drain_mod.EventDrain = @ptrCast(@alignCast(context.?));
    try drain.handle(event);
}

test "tool result details can request error classification" {
    var object: std.json.ObjectMap = .empty;
    defer object.deinit(std.testing.allocator);
    try object.put(std.testing.allocator, "isError", .{ .bool = true });
    try std.testing.expect(toolResultRequestsError(.{ .object = object }));
    try std.testing.expect(!toolResultRequestsError(null));
}

test "compaction summary appends file operation tags" {
    var read_args: std.json.ObjectMap = .empty;
    defer read_args.deinit(std.testing.allocator);
    try read_args.put(std.testing.allocator, "path", .{ .string = "README.md" });
    var edit_args: std.json.ObjectMap = .empty;
    defer edit_args.deinit(std.testing.allocator);
    try edit_args.put(std.testing.allocator, "path", .{ .string = "src/main.zig" });
    const blocks = [_]ai.AssistantContent{
        .{ .tool_call = .{ .id = "read-1", .name = "read", .arguments = .{ .object = read_args } } },
        .{ .tool_call = .{ .id = "edit-1", .name = "edit", .arguments = .{ .object = edit_args } } },
    };
    const messages = [_]agent_mod.AgentMessage{.{ .assistant = .{
        .content = &blocks,
        .api = ai.KnownApi.openai_responses,
        .provider = "openai",
        .model = "gpt",
        .usage = ai.protocol.emptyUsage(),
        .stop_reason = .tool_use,
        .timestamp = 0,
    } }};
    const input: session_manager.CompactionSummaryInput = .{
        .allocator = std.testing.allocator,
        .messages = &messages,
        .first_kept_entry_id = "00000002",
        .tokens_before = 1,
    };
    var session: AgentSession = undefined;
    session.allocator = std.testing.allocator;
    const summary = try session.compactionSummaryWithFileOperations("summary", input);
    defer std.testing.allocator.free(summary);
    try std.testing.expect(std.mem.indexOf(u8, summary, "<read-files>\nREADME.md\n</read-files>") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "<modified-files>\nsrc/main.zig\n</modified-files>") != null);
}

// -- tests --------------------------------------------------------------

const TestSessionOptions = struct {
    public_event_capacity: usize = public_event_capacity_default,
    compaction_settings: session_manager.CompactionSettings = .{},
    retry_settings: RetrySettings = .{},
    model: ?ai.Model = null,
    stream: ?ai.StreamFunction = null,
    store: ?StoreOptions = null,
};

fn initTestSession(task_runtime: *runtime.Runtime, dir: std.Io.Dir, overrides: TestSessionOptions) !AgentSession {
    try dir.createDirPath(std.testing.io, "agent");
    try dir.createDirPath(std.testing.io, "repo");
    var options: Options = .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .dir = dir,
        .task_runtime = task_runtime,
        .public_event_capacity = overrides.public_event_capacity,
        .compaction_settings = overrides.compaction_settings,
        .retry_settings = overrides.retry_settings,
        .stream = overrides.stream,
        .store = overrides.store,
    };
    if (overrides.model) |model| options.model = model;
    return AgentSession.init(std.testing.allocator, std.testing.io, options);
}

fn shutdownAndDeinit(session: *AgentSession) void {
    if (!session.agent.waitForIdle()) session.agent.finishRun();
    session.requestShutdown();
    drainAllPublicEvents(session);
    session.deinit();
}

fn drainAllPublicEvents(session: *AgentSession) void {
    while (session.drainPublicEvent()) |event| {
        var owned_event = event;
        owned_event.deinit(std.testing.allocator);
    }
}

fn emitUserMessageEnd(session: *AgentSession, text: []const u8) !void {
    try session.agent.emitEvent(.{ .message_end = .{ .message = .{ .user = .{
        .content = .{ .string = text },
        .timestamp = 0,
    } } } });
}

fn emitAssistantError(session: *AgentSession, error_message: []const u8) !void {
    try session.agent.emitEvent(.{ .message_end = .{ .message = .{ .assistant = .{
        .content = &.{},
        .api = ai.KnownApi.openai_responses,
        .provider = ai.KnownProvider.openai,
        .model = "gpt",
        .usage = ai.protocol.emptyUsage(),
        .stop_reason = .error_,
        .error_message = error_message,
        .operational_failure = .{
            .category = if (std.ascii.indexOfIgnoreCase(error_message, "context") != null)
                .context_overflow
            else if (std.ascii.indexOfIgnoreCase(error_message, "rate") != null)
                .rate_limited
            else
                .unknown,
            .message = error_message,
            .detail = error_message,
            .retryable = if (std.ascii.indexOfIgnoreCase(error_message, "rate") != null) .yes else .unknown,
            .provider = ai.KnownProvider.openai,
            .model = "gpt",
        },
        .timestamp = 0,
    } } } });
}

fn emitAssistantText(session: *AgentSession, text: []const u8) !void {
    const content = [_]ai.AssistantContent{.{ .text = .{ .text = text } }};
    try session.agent.emitEvent(.{ .message_end = .{ .message = .{ .assistant = .{
        .content = &content,
        .api = ai.KnownApi.openai_responses,
        .provider = ai.KnownProvider.openai,
        .model = "gpt",
        .usage = ai.protocol.emptyUsage(),
        .stop_reason = .stop,
        .timestamp = 0,
    } } } });
}

test "settle verdict arms backoff retry and repairs the runtime transcript" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var session = try initTestSession(task_runtime, tmp.dir, .{
        .retry_settings = .{ .enabled = true, .max_attempts = 3, .base_delay_ms = 100 },
    });
    defer shutdownAndDeinit(&session);

    _ = try session.agent.beginRun();
    try emitUserMessageEnd(&session, "hello");
    try emitAssistantError(&session, "rate limit exceeded");
    session.agent.finishRun();
    drainAllPublicEvents(&session);

    const verdict = try session.settlePromptRun(.{ .overflow_count_before = 0, .overflow_retry_used = false });
    const expected: SettleVerdict = .{ .retry = .{ .kind = .continue_run, .delay_ms = 100 } };
    try std.testing.expectEqual(expected, verdict);
    // The failed assistant message is gone from the runtime context; the
    // durable history still has it.
    try std.testing.expectEqual(@as(usize, 1), session.agent.state.messages.len);
    try std.testing.expect(session.agent.state.messages[0] == .user);
    try std.testing.expectEqual(@as(usize, 2), session.manager.entries.items.len);
    try std.testing.expectEqual(@as(u8, 1), session.event_drain.retry_attempt);

    var start_event = session.drainPublicEvent().?;
    defer start_event.deinit(std.testing.allocator);
    try std.testing.expect(start_event == .auto_retry_start);
    try std.testing.expectEqual(@as(usize, 1), start_event.auto_retry_start.attempt);
    try std.testing.expectEqual(@as(usize, 3), start_event.auto_retry_start.max_attempts);
    try std.testing.expectEqual(@as(u64, 100), start_event.auto_retry_start.delay_ms);
    try std.testing.expectEqualStrings("rate limit exceeded", start_event.auto_retry_start.error_message.text);
    try std.testing.expectEqual(client_protocol.OperationalFailure.Category.rate_limited, start_event.auto_retry_start.failure.?.category);

    // Second failure backs off exponentially.
    _ = try session.agent.beginRun();
    try emitAssistantError(&session, "rate limit exceeded");
    session.agent.finishRun();
    drainAllPublicEvents(&session);
    const second = try session.settlePromptRun(.{ .overflow_count_before = 0, .overflow_retry_used = false });
    try std.testing.expectEqual(@as(u64, 200), second.retry.delay_ms);
}

test "settle verdict fails after exhausted attempts with terminal retry end" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var session = try initTestSession(task_runtime, tmp.dir, .{
        .retry_settings = .{ .enabled = true, .max_attempts = 2 },
    });
    defer shutdownAndDeinit(&session);

    session.event_drain.retry_attempt = 2;
    _ = try session.agent.beginRun();
    try emitAssistantError(&session, "rate limit exceeded");
    session.agent.finishRun();
    drainAllPublicEvents(&session);

    const verdict = try session.settlePromptRun(.{ .overflow_count_before = 0, .overflow_retry_used = false });
    try std.testing.expect(verdict == .failed);
    try std.testing.expectEqual(@as(u8, 0), session.event_drain.retry_attempt);

    var end_event = session.drainPublicEvent().?;
    defer end_event.deinit(std.testing.allocator);
    try std.testing.expect(end_event == .auto_retry_end);
    try std.testing.expect(!end_event.auto_retry_end.success);
    try std.testing.expectEqual(@as(usize, 2), end_event.auto_retry_end.attempt);
    try std.testing.expectEqualStrings("rate limit exceeded", end_event.auto_retry_end.final_error.?.text);
    try std.testing.expectEqual(client_protocol.OperationalFailure.Category.rate_limited, end_event.auto_retry_end.failure.?.category);
}

test "retry failure still emits end event when final error allocation fails" {
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var session = try AgentSession.init(failing.allocator(), std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .dir = tmp.dir,
        .task_runtime = task_runtime,
    });
    defer {
        failing.fail_index = std.math.maxInt(usize);
        if (!session.agent.waitForIdle()) session.agent.finishRun();
        session.requestShutdown();
        drainAllPublicEvents(&session);
        session.deinit();
    }

    session.event_drain.retry_attempt = 1;
    failing.fail_index = failing.alloc_index;
    session.event_drain.failRetry("rate limit exceeded", null);
    failing.fail_index = std.math.maxInt(usize);

    var end_event = session.drainPublicEvent().?;
    defer end_event.deinit(failing.allocator());
    try std.testing.expect(end_event == .auto_retry_end);
    try std.testing.expect(!end_event.auto_retry_end.success);
    try std.testing.expectEqual(@as(usize, 1), end_event.auto_retry_end.attempt);
    try std.testing.expect(end_event.auto_retry_end.final_error == null);
}

test "settle verdict ignores non retryable errors and clean runs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var session = try initTestSession(task_runtime, tmp.dir, .{
        .retry_settings = .{ .enabled = true },
    });
    defer shutdownAndDeinit(&session);

    _ = try session.agent.beginRun();
    try emitUserMessageEnd(&session, "hello");
    session.agent.finishRun();
    drainAllPublicEvents(&session);
    try std.testing.expect(try session.settlePromptRun(.{
        .overflow_count_before = 0,
        .overflow_retry_used = false,
    }) == .completed);

    _ = try session.agent.beginRun();
    try emitAssistantError(&session, "invalid api key");
    session.agent.finishRun();
    drainAllPublicEvents(&session);
    try std.testing.expect(try session.settlePromptRun(.{
        .overflow_count_before = 0,
        .overflow_retry_used = false,
    }) == .failed);
    try std.testing.expectEqual(@as(u8, 0), session.event_drain.retry_attempt);
}

test "drain settles in-flight retry on successful assistant message" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var session = try initTestSession(task_runtime, tmp.dir, .{});
    defer shutdownAndDeinit(&session);

    session.event_drain.retry_attempt = 2;
    _ = try session.agent.beginRun();
    try emitAssistantText(&session, "recovered");
    session.agent.finishRun();

    try std.testing.expectEqual(@as(u8, 0), session.event_drain.retry_attempt);
    var message_event = session.drainPublicEvent().?;
    message_event.deinit(std.testing.allocator);
    var commit_event = session.drainPublicEvent().?;
    commit_event.deinit(std.testing.allocator);
    var end_event = session.drainPublicEvent().?;
    defer end_event.deinit(std.testing.allocator);
    try std.testing.expect(end_event == .auto_retry_end);
    try std.testing.expect(end_event.auto_retry_end.success);
    try std.testing.expectEqual(@as(usize, 2), end_event.auto_retry_end.attempt);
}

test "agent session initializes policy spine with definition-first builtin tools" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "agent/AGENTS.md", .data = "global" });
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();

    var session = try initTestSession(task_runtime, tmp.dir, .{});
    defer shutdownAndDeinit(&session);

    try std.testing.expectEqual(tool_registry.default_active_tool_names.len, session.agent.state.tools.len);
    try std.testing.expectEqualStrings("read", session.agent.state.tools[0].name);
    try std.testing.expectEqualStrings("bash", session.agent.state.tools[1].name);
    try std.testing.expectEqual(agent_mod.ToolExecutionMode.sequential, session.agent.state.tools[1].execution_mode.?);
    try std.testing.expect(std.mem.indexOf(u8, session.system_prompt_text, "global") != null);
}

test "live prompt run uses explicit bounded event buffer" {
    try std.testing.expectEqual(@as(usize, 64), live_prompt_event_capacity_count);
    try std.testing.expectEqual(
        live_prompt_event_capacity_count,
        @typeInfo(@FieldType(PromptRun, "buffer")).array.len,
    );
}

test "queue prompt rolls back mirror when agent queue allocation fails" {
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var session = try AgentSession.init(failing.allocator(), std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .dir = tmp.dir,
        .task_runtime = task_runtime,
    });
    defer {
        failing.fail_index = std.math.maxInt(usize);
        if (!session.agent.waitForIdle()) session.agent.finishRun();
        session.requestShutdown();
        while (session.drainPublicEvent()) |event| {
            var owned_event = event;
            owned_event.deinit(failing.allocator());
        }
        session.deinit();
    }

    _ = try session.agent.beginRun();
    failing.fail_index = failing.alloc_index + 2;

    try std.testing.expectError(error.OutOfMemory, session.queuePrompt("hello", &.{}, .steer));
    const changed = session.event_drain.queue_mirror.changed();
    try std.testing.expectEqual(@as(usize, 0), changed.steering_count);
    try std.testing.expect(!session.agent.steering_queue.hasItems());
}

test "agent session public event enqueue sets coalesced wake" {
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var session = try initTestSession(task_runtime, tmp.dir, .{});
    defer shutdownAndDeinit(&session);

    try std.testing.expect(!session.publicEventWake().isSet());

    session.event_drain.enqueuePublicEvent(.{ .queue_changed = .{
        .steering_count = 0,
        .follow_up_count = 0,
        .revision = 1,
    } });

    try std.testing.expect(session.publicEventWake().isSet());
    session.publicEventWake().reset();
    try std.testing.expect(!session.publicEventWake().isSet());

    var event = session.drainPublicEvent().?;
    defer event.deinit(std.testing.allocator);
    try std.testing.expect(event == .queue_changed);
    try std.testing.expectEqual(@as(u64, 1), event.queue_changed.revision);
}

test "agent session persists message_end and exposes caller-drained events" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var session = try initTestSession(task_runtime, tmp.dir, .{});
    defer shutdownAndDeinit(&session);

    _ = try session.agent.beginRun();
    try emitUserMessageEnd(&session, "hello");
    session.agent.finishRun();

    try std.testing.expectEqual(@as(usize, 1), session.manager.entries.items.len);
    try std.testing.expectEqual(@as(usize, 2), session.event_drain.publicEventCount());
    var event = session.drainPublicEvent().?;
    defer event.deinit(std.testing.allocator);
    try std.testing.expect(event == .agent_event);
    try std.testing.expect(event.agent_event.event == .message_end);
    var commit = session.drainPublicEvent().?;
    defer commit.deinit(std.testing.allocator);
    try std.testing.expect(commit == .message_committed);
    try std.testing.expectEqualStrings(session.manager.entries.items[0].id(), commit.message_committed.entry_id.text);
    try std.testing.expect(session.drainPublicEvent() == null);
}

test "agent session shutdown complete requires stopped idle and drained events" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var session = try initTestSession(task_runtime, tmp.dir, .{});
    defer shutdownAndDeinit(&session);

    try std.testing.expect(!session.shutdownComplete());
    session.requestShutdown();
    try std.testing.expect(session.shutdownComplete());
}

test "agent session public event queue overflow is explicit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var session = try initTestSession(task_runtime, tmp.dir, .{ .public_event_capacity = 1 });
    defer shutdownAndDeinit(&session);

    _ = try session.agent.beginRun();
    defer session.agent.finishRun();
    try emitUserMessageEnd(&session, "overflow");
    try emitUserMessageEnd(&session, "overflow");

    try std.testing.expectEqual(@as(usize, 1), session.event_drain.publicEventCount());
    try std.testing.expectEqual(@as(usize, 3), session.event_drain.droppedPublicEventCount());

    var first = session.drainPublicEvent().?;
    first.deinit(std.testing.allocator);
    var overflow_event = session.drainPublicEvent().?;
    defer overflow_event.deinit(std.testing.allocator);
    try std.testing.expect(overflow_event == .event_overflow);
    try std.testing.expectEqual(@as(usize, 3), overflow_event.event_overflow.dropped_count);
}

fn initCompactionTestSession(
    task_runtime: *runtime.Runtime,
    dir: std.Io.Dir,
    provider: *ai.FauxProvider,
    store: ?StoreOptions,
) !AgentSession {
    return initTestSession(task_runtime, dir, .{
        .model = provider.getModel(),
        .stream = provider.apiProvider().stream,
        .compaction_settings = .{ .keep_recent_tokens = 2, .auto_enabled = true },
        .store = store,
    });
}

/// Poll a compaction run to settle the way the owner loop does: bounded,
/// non-blocking, yielding to the producer between polls.
fn driveCompactionRun(session: *AgentSession, run: *AgentSession.CompactionRun) !void {
    var iterations: usize = 0;
    while (iterations < 10_000) : (iterations += 1) {
        switch (run.stream.poll()) {
            .event => |event| {
                if (!try session.applyCompactionRunProgress(run, event)) return;
            },
            .terminal => {
                if (!try session.applyCompactionRunProgress(run, null)) return;
            },
            .empty => try runtime.yield(),
        }
    }
    return error.CompactionRunDidNotSettle;
}

fn appendTestMessage(session: *AgentSession, message: agent_mod.AgentMessage, timestamp: []const u8) ![]const u8 {
    const entry = try session.manager.prepareMessageEntry(message, timestamp);
    errdefer session.manager.deinitPreparedEntry(entry);
    return session.manager.commitPreparedEntry(entry);
}

fn appendTwoCompactableMessages(session: *AgentSession) !void {
    _ = try appendTestMessage(session, .{ .user = .{
        .content = .{ .string = "aaaaaaaa" },
        .timestamp = 0,
    } }, "t1");
    _ = try appendTestMessage(session, .{ .user = .{
        .content = .{ .string = "bbbbbbbb" },
        .timestamp = 0,
    } }, "t2");
}

test "agent session auto compaction summarizes persists and replaces context" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var provider = try ai.FauxProvider.init(std.testing.allocator, .{});
    defer provider.deinit();
    const summary_content = [_]ai.AssistantContent{ai.faux.text("generated summary")};
    const summaries = [_]ai.AssistantMessage{
        ai.faux.assistantMessage(&summary_content, .{ .stop_reason = .stop }),
    };
    try provider.setResponses(&summaries);
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();

    const store = try session_manager.SessionStore.create(std.testing.allocator, std.testing.io, tmp.dir, .{
        .cwd = "repo",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
    });
    var session = try initCompactionTestSession(task_runtime, tmp.dir, &provider, .{ .create = store });
    defer shutdownAndDeinit(&session);

    _ = try session.agent.beginRun();
    try emitUserMessageEnd(&session, "aaaaaaaa");
    try emitUserMessageEnd(&session, "bbbbbbbb");
    session.agent.finishRun();
    drainAllPublicEvents(&session);
    const kept = session.manager.entries.items[1].id();

    const run = (try session.startCompactionRun(.threshold, false, null)).?;
    try driveCompactionRun(&session, run);
    const verdict = try session.settleCompactionRun(run);
    session.destroyCompactionRun(run);
    const expected: SettleVerdict = .{ .retry = .{ .kind = .resubmit_prompt, .delay_ms = 0 } };
    try std.testing.expectEqual(expected, verdict);

    try std.testing.expectEqual(@as(usize, 1), provider.call_count);
    try std.testing.expectEqualStrings("generated summary", session.manager.entries.items[2].compaction.summary);
    try std.testing.expectEqualStrings(kept, session.manager.entries.items[2].compaction.first_kept_entry_id);
    try std.testing.expect(std.mem.indexOf(
        u8,
        session.agent.state.messages[0].user.content.string,
        "generated summary",
    ) != null);

    var start_event = session.drainPublicEvent().?;
    defer start_event.deinit(std.testing.allocator);
    try std.testing.expect(start_event == .compaction_start);
    var end_event = session.drainPublicEvent().?;
    defer end_event.deinit(std.testing.allocator);
    try std.testing.expect(end_event == .compaction_end);
    try std.testing.expectEqualStrings("generated summary", end_event.compaction_end.result.?.summary.text);

    // Durable truth round-trips.
    var loaded = try session.store.?.load(std.testing.io);
    defer loaded.deinit();
    try std.testing.expect(loaded.entries.items[2] == .compaction);
    try std.testing.expectEqualStrings("generated summary", loaded.entries.items[2].compaction.summary);
}

test "agent session auto compaction failure does not mutate history" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var provider = try ai.FauxProvider.init(std.testing.allocator, .{});
    defer provider.deinit();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();

    var session = try initCompactionTestSession(task_runtime, tmp.dir, &provider, null);
    defer shutdownAndDeinit(&session);

    try appendTwoCompactableMessages(&session);

    const run = (try session.startCompactionRun(.threshold, false, null)).?;
    try driveCompactionRun(&session, run);
    const verdict = try session.settleCompactionRun(run);
    session.destroyCompactionRun(run);
    // A failed threshold compaction degrades: the prompt still proceeds.
    const expected: SettleVerdict = .{ .retry = .{ .kind = .resubmit_prompt, .delay_ms = 0 } };
    try std.testing.expectEqual(expected, verdict);
    try std.testing.expectEqual(@as(usize, 2), session.manager.entries.items.len);
    try std.testing.expectEqual(@as(usize, 0), session.agent.state.messages.len);

    var start_event = session.drainPublicEvent().?;
    defer start_event.deinit(std.testing.allocator);
    try std.testing.expect(start_event == .compaction_start);
    var end_event = session.drainPublicEvent().?;
    defer end_event.deinit(std.testing.allocator);
    try std.testing.expect(end_event == .compaction_end);
    try std.testing.expect(end_event.compaction_end.result == null);
    try std.testing.expectEqualStrings(
        "CompactionSummaryGenerationFailed",
        end_event.compaction_end.error_message.?.text,
    );
}

test "agent session auto compaction oversized summary does not mutate history" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var provider = try ai.FauxProvider.init(std.testing.allocator, .{
        .min_token_size = session_manager.max_compaction_summary_bytes + 1,
        .max_token_size = session_manager.max_compaction_summary_bytes + 1,
    });
    defer provider.deinit();
    const oversized_summary = try std.testing.allocator.alloc(u8, session_manager.max_compaction_summary_bytes + 1);
    defer std.testing.allocator.free(oversized_summary);
    @memset(oversized_summary, 's');
    const summary_content = [_]ai.AssistantContent{.{ .text = .{ .text = oversized_summary } }};
    const summaries = [_]ai.AssistantMessage{
        ai.faux.assistantMessage(&summary_content, .{ .stop_reason = .stop }),
    };
    try provider.setResponses(&summaries);
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();

    var session = try initCompactionTestSession(task_runtime, tmp.dir, &provider, null);
    defer shutdownAndDeinit(&session);

    try appendTwoCompactableMessages(&session);

    const run = (try session.startCompactionRun(.threshold, false, null)).?;
    try driveCompactionRun(&session, run);
    try std.testing.expect(run.outcome == .failure);
    try std.testing.expectEqual(error.CompactionSummaryTooLarge, run.outcome.failure);
    const verdict = try session.settleCompactionRun(run);
    session.destroyCompactionRun(run);
    try std.testing.expect(verdict == .retry);
    try std.testing.expectEqual(@as(usize, 2), session.manager.entries.items.len);
    drainAllPublicEvents(&session);
}

test "overflow settle starts compaction and arms the resubmit retry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var provider = try ai.FauxProvider.init(std.testing.allocator, .{});
    defer provider.deinit();
    const summary_content = [_]ai.AssistantContent{ai.faux.text("overflow summary")};
    const summaries = [_]ai.AssistantMessage{
        ai.faux.assistantMessage(&summary_content, .{ .stop_reason = .stop }),
    };
    try provider.setResponses(&summaries);
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();

    var session = try initCompactionTestSession(task_runtime, tmp.dir, &provider, null);
    defer shutdownAndDeinit(&session);

    _ = try session.agent.beginRun();
    try emitUserMessageEnd(&session, "aaaaaaaa");
    try emitUserMessageEnd(&session, "bbbbbbbb");
    try emitAssistantError(&session, "maximum context length exceeded");
    session.agent.finishRun();
    drainAllPublicEvents(&session);
    try std.testing.expectEqual(@as(usize, 1), session.contextOverflowCount());

    const verdict = try session.settlePromptRun(.{ .overflow_count_before = 0, .overflow_retry_used = false });
    try std.testing.expect(verdict == .compact);
    var start_event = session.drainPublicEvent().?;
    defer start_event.deinit(std.testing.allocator);
    try std.testing.expect(start_event == .compaction_start);
    try std.testing.expect(start_event.compaction_start.reason == .overflow);

    const run = verdict.compact;
    try driveCompactionRun(&session, run);
    const resubmit = try session.settleCompactionRun(run);
    session.destroyCompactionRun(run);
    const expected: SettleVerdict = .{ .retry = .{ .kind = .resubmit_prompt, .delay_ms = 0 } };
    try std.testing.expectEqual(expected, resubmit);
    try std.testing.expect(session.manager.entries.items[3] == .compaction);

    var end_event = session.drainPublicEvent().?;
    defer end_event.deinit(std.testing.allocator);
    try std.testing.expect(end_event == .compaction_end);
    try std.testing.expect(end_event.compaction_end.will_retry);
    var retry_event = session.drainPublicEvent().?;
    defer retry_event.deinit(std.testing.allocator);
    try std.testing.expect(retry_event == .auto_retry_start);
    try std.testing.expectEqual(@as(usize, 1), retry_event.auto_retry_start.attempt);
    try std.testing.expectEqual(@as(u64, 0), retry_event.auto_retry_start.delay_ms);
    try std.testing.expectEqual(@as(u8, 1), session.event_drain.retry_attempt);

    // The overflow budget is one compaction per operation.
    const second = try session.settlePromptRun(.{ .overflow_count_before = 0, .overflow_retry_used = true });
    try std.testing.expect(second == .failed);
    drainAllPublicEvents(&session);
}

test "start compaction run returns null when disabled or nothing to compact" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();

    var disabled_session = try initTestSession(task_runtime, tmp.dir, .{});
    defer shutdownAndDeinit(&disabled_session);
    try std.testing.expectEqual(
        @as(?*AgentSession.CompactionRun, null),
        try disabled_session.startCompactionRun(.threshold, false, null),
    );

    var provider = try ai.FauxProvider.init(std.testing.allocator, .{});
    defer provider.deinit();
    var empty_session = try initCompactionTestSession(task_runtime, tmp.dir, &provider, null);
    defer shutdownAndDeinit(&empty_session);
    try std.testing.expectEqual(
        @as(?*AgentSession.CompactionRun, null),
        try empty_session.startCompactionRun(.threshold, false, null),
    );
}

test "cancel compaction run emits the aborted compaction end" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var provider = try ai.FauxProvider.init(std.testing.allocator, .{});
    defer provider.deinit();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();

    var session = try initCompactionTestSession(task_runtime, tmp.dir, &provider, null);
    defer shutdownAndDeinit(&session);
    try appendTwoCompactableMessages(&session);

    const run = (try session.startCompactionRun(.threshold, false, null)).?;
    session.cancelCompactionRun(run);
    session.destroyCompactionRun(run);
    try std.testing.expectEqual(@as(usize, 2), session.manager.entries.items.len);

    var start_event = session.drainPublicEvent().?;
    defer start_event.deinit(std.testing.allocator);
    try std.testing.expect(start_event == .compaction_start);
    var end_event = session.drainPublicEvent().?;
    defer end_event.deinit(std.testing.allocator);
    try std.testing.expect(end_event == .compaction_end);
    try std.testing.expect(end_event.compaction_end.aborted);
    try std.testing.expect(!end_event.compaction_end.will_retry);
}

test "agent session terminal policy classifies context overflow after persistence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var session = try initTestSession(task_runtime, tmp.dir, .{});
    defer shutdownAndDeinit(&session);

    _ = try session.agent.beginRun();
    try emitAssistantError(&session, "maximum context length exceeded");
    try emitAssistantError(&session, "rate limit exceeded");
    session.agent.finishRun();

    try std.testing.expectEqual(@as(usize, 2), session.manager.entries.items.len);
    try std.testing.expectEqual(@as(usize, 1), session.contextOverflowCount());
    drainAllPublicEvents(&session);
}

test "agent session terminal policy runs when persistence fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var store: session_manager.SessionStore = .{
        .allocator = std.testing.allocator,
        .dir = tmp.dir,
        .file_name = try std.testing.allocator.dupe(u8, "missing/session.jsonl"),
    };
    var store_needs_deinit = true;
    errdefer if (store_needs_deinit) store.deinit();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();

    var session = try initTestSession(task_runtime, tmp.dir, .{ .store = .{ .create = store } });
    store_needs_deinit = false;
    defer shutdownAndDeinit(&session);

    _ = try session.agent.beginRun();
    try std.testing.expectError(
        error.FileNotFound,
        session.agent.emitEvent(.{ .message_end = .{ .message = .{ .assistant = .{
            .content = &.{},
            .api = ai.KnownApi.openai_responses,
            .provider = ai.KnownProvider.openai,
            .model = "gpt",
            .usage = ai.protocol.emptyUsage(),
            .stop_reason = .error_,
            .error_message = "maximum context length exceeded",
            .timestamp = 0,
        } } } }),
    );
    session.agent.finishRun();

    try std.testing.expectEqual(@as(usize, 0), session.manager.entries.items.len);
    try std.testing.expectEqual(@as(usize, 1), session.contextOverflowCount());
    drainAllPublicEvents(&session);
}
