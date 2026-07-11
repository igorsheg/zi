//! One session's policy spine: prompt resources, system prompt, builtin
//! tools, durable history, the long-lived agent, lifecycle, and the
//! compaction/retry terminal policies.
//!
//! Compaction and retry are operation-backed: the session computes verdicts
//! and starts producer-backed runs; the owner loop does all waiting.

const std = @import("std");
const agent_mod = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const runtime = @import("../runtime/root.zig");
const bash_tool = @import("tools/bash.zig");
const failure_display = @import("failure_display.zig");
const message_policy = @import("message_policy.zig");
const resources = @import("resources.zig");
const session_manager = @import("session_manager.zig");
const system_prompt = @import("system_prompt.zig");
const tool_registry = @import("tool_registry.zig");

const AgentSession = @This();

pub const CompactionReason = enum { manual, threshold, overflow };
pub const ContextUsage = struct { tokens: ?u64 = null, window: u64 = 0, percent_tenths: ?u32 = null };

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
events: *SessionEvents,
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
    store: ?StoreOptions = null,
    cancel_token: ?runtime.CancelToken = null,
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
    state: enum { producing, cancel_requested, settled } = .producing,
    stream: agent_mod.loop.AgentEventStream = undefined,
    buffer: [live_prompt_event_capacity_count]agent_mod.loop.StreamEvent = undefined,
    prompts: [1]agent_mod.AgentMessage = undefined,
    cancel: runtime.CancelSource,
    reason: CompactionReason,
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

    fn requestCancel(self: *PromptRun) bool {
        return switch (self.state) {
            .running => |token| blk: {
                self.state = .{ .cancel_requested = token };
                break :blk true;
            },
            .cancel_requested, .settled => false,
        };
    }

    fn cancellationOutstanding(self: *const PromptRun) bool {
        return self.state == .cancel_requested;
    }

    fn markSettled(self: *PromptRun) void {
        std.debug.assert(self.state != .settled);
        self.state = .settled;
    }
};

pub const RunHandle = struct {
    kind: Kind,
    run: Run,
    settled: bool = false,

    pub const Kind = enum { prompt, compaction };
    pub const PollResult = enum { live, empty, settled };
    pub const CancelRequestResult = enum { requested, already_requested, settled };

    const Run = union(enum) {
        prompt: *PromptRun,
        compaction: *CompactionRun,
    };

    pub fn prompt(run: *PromptRun) RunHandle {
        return .{ .kind = .prompt, .run = .{ .prompt = run } };
    }

    pub fn compaction(run: *CompactionRun) RunHandle {
        return .{ .kind = .compaction, .run = .{ .compaction = run } };
    }

    pub fn setWake(self: *RunHandle, io: std.Io, wake: *runtime.WakeEvent) void {
        switch (self.run) {
            .prompt => |run| run.stream.setWake(io, wake),
            .compaction => |run| run.stream.setWake(io, wake),
        }
    }

    pub fn poll(self: *RunHandle, session: *AgentSession) !PollResult {
        if (self.settled) return .settled;
        return switch (self.run) {
            .prompt => |run| if (!run.isActive()) .settled else switch (run.stream.poll()) {
                .event => |event| if (try session.applyPromptRunProgress(run, event)) .live else .settled,
                .terminal => if (try session.applyPromptRunProgress(run, null)) .live else .settled,
                .empty => .empty,
            },
            .compaction => |run| if (run.state == .settled) .settled else switch (run.stream.poll()) {
                .event => |event| if (try session.applyCompactionRunProgress(run, event)) .live else .settled,
                .terminal => if (try session.applyCompactionRunProgress(run, null)) .live else .settled,
                .empty => .empty,
            },
        };
    }

    pub fn settle(self: *RunHandle, session: *AgentSession, context: SettleContext) !SettleVerdict {
        std.debug.assert(!self.settled);
        self.settled = true;
        return switch (self.run) {
            .prompt => session.settlePromptRun(context),
            .compaction => |run| session.settleCompactionRun(run),
        };
    }

    pub fn cancelRequest(self: *RunHandle, session: *AgentSession) CancelRequestResult {
        return switch (self.run) {
            .prompt => |run| session.cancelPromptRun(run),
            .compaction => |run| session.cancelCompactionRun(run),
        };
    }

    pub fn cancellationOutstanding(self: *const RunHandle) bool {
        if (self.settled) return false;
        return switch (self.run) {
            .prompt => |run| run.cancellationOutstanding(),
            .compaction => |run| run.state == .cancel_requested,
        };
    }

    pub fn deinitAfterSettled(self: *RunHandle, session: *AgentSession) void {
        switch (self.run) {
            .prompt => |run| session.destroyPromptRun(run),
            .compaction => |run| session.destroyCompactionRun(run),
        }
        self.* = undefined;
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
    if (options.cancel_token) |token| try token.throwIfRequested();

    var prompt_resources = try resources.PromptResources.load(allocator, io, .{
        .dir = options.dir,
        .agent_dir = options.agent_dir,
        .cwd = options.cwd,
    });
    defer prompt_resources.deinit();

    if (options.cancel_token) |token| try token.throwIfRequested();
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

    if (options.cancel_token) |token| try token.throwIfRequested();
    const manager = try allocator.create(session_manager.SessionManager);
    errdefer allocator.destroy(manager);
    manager.* = if (options.store != null and options.store.? == .restore)
        try options.store.?.restore.loadCancelable(io, options.cancel_token)
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

    const events = try allocator.create(SessionEvents);
    errdefer allocator.destroy(events);
    events.* = SessionEvents.init(allocator, io, manager, store);
    errdefer events.deinit();

    _ = try core_agent.subscribe(.{ .context = events, .call_fn = drainAgentEvent });

    return .{
        .allocator = allocator,
        .io = io,
        .task_runtime = task_runtime,
        .system_prompt_text = system_prompt_text,
        .builtin_tools = builtin_tools,
        .manager = manager,
        .store = store,
        .agent = core_agent,
        .events = events,
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
    self.events.deinit();
    self.allocator.destroy(self.events);
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

pub fn startPromptHandle(
    self: *AgentSession,
    text: []const u8,
    images: []const ai.ImageContent,
) !RunHandle {
    return RunHandle.prompt(try self.startPromptRun(text, images));
}

pub fn startContinueHandle(self: *AgentSession) !RunHandle {
    return RunHandle.prompt(try self.startContinueRun());
}

pub fn startCompactionHandle(
    self: *AgentSession,
    reason: CompactionReason,
    will_retry: bool,
    custom_instructions: ?[]const u8,
) !?RunHandle {
    const run = try self.startCompactionRun(reason, will_retry, custom_instructions) orelse return null;
    return RunHandle.compaction(run);
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
        if (run.cancellationOutstanding()) {
            _ = run.stream.awaitProducer() catch {};
            try self.settlePromptRunFailure(run, token, "aborted");
            return false;
        }
        run.stream.awaitProducer() catch |err| {
            try self.settlePromptRunFailure(run, token, @errorName(err));
            return false;
        };
        self.agent.finishRun();
        run.markSettled();
        return false;
    };
    defer event.deinit();
    if (run.cancellationOutstanding()) return true;
    try self.agent.emitEvent(event.event);
    return true;
}

pub fn cancelPromptRun(self: *AgentSession, run: *PromptRun) RunHandle.CancelRequestResult {
    if (run.cancellationOutstanding()) return .already_requested;
    const token = run.terminalToken() orelse return .settled;
    if (!run.requestCancel()) return .settled;
    self.agent.abort();
    run.stream.cancelProducer() catch |err| switch (err) {
        error.Canceled => {},
        else => {
            self.settlePromptRunFailure(run, token, @errorName(err)) catch {};
            return .requested;
        },
    };
    self.settlePromptRunFailure(run, token, "aborted") catch {};
    return .requested;
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
        _ = run.requestCancel();
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
        self.agent.waitForIdle();
}

pub fn contextUsage(self: *const AgentSession) ContextUsage {
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

pub fn clearQueue(self: *AgentSession) void {
    self.agent.clearAllQueues();
    self.events.clearQueueEchoes();
}

pub fn setModel(self: *AgentSession, model: ai.Model, stream: ?ai.StreamFunction) !void {
    const timestamp = session_manager.timestampNow(self.io);
    const entry = try self.manager.prepareModelChangeEntry(model.provider, model.id, &timestamp);
    var committed = false;
    errdefer if (!committed) self.manager.deinitPreparedEntry(entry);
    if (self.store) |store| try store.appendEntry(self.io, entry, self.manager.lastEntryId());
    _ = self.manager.commitPreparedEntry(entry);
    committed = true;
    self.agent.setModel(model);
    if (stream) |stream_fn| self.agent.setStream(stream_fn);
}

pub fn setThinkingLevel(self: *AgentSession, level: agent_mod.ThinkingLevel) !void {
    const timestamp = session_manager.timestampNow(self.io);
    const entry = try self.manager.prepareThinkingLevelChangeEntry(@tagName(level), &timestamp);
    var committed = false;
    errdefer if (!committed) self.manager.deinitPreparedEntry(entry);
    if (self.store) |store| try store.appendEntry(self.io, entry, self.manager.lastEntryId());
    _ = self.manager.commitPreparedEntry(entry);
    committed = true;
    self.agent.setThinkingLevel(level);
}

/// Hide-thinking is a settings fact, not a session jsonl fact; the caller
/// persists it through the settings owner before this mutation.
pub fn setHideThinking(self: *AgentSession, hidden: bool) !void {
    self.hide_thinking = hidden;
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
        .steer => try self.events.appendSteering(text),
        .follow_up => try self.events.appendFollowUp(text),
    }
    var mirror_committed = false;
    errdefer if (!mirror_committed) self.events.removeQueuedText(text);

    const message = try self.agent.userMessageFromText(text, images);
    switch (kind) {
        .steer => try self.agent.steer(message),
        .follow_up => try self.agent.followUp(message),
    }
    mirror_committed = true;
}

/// Terminal session policy after a prompt run settles. Decides between
/// completion, failure, overflow-compaction + prompt resubmission, and
/// provider-error retry with exponential backoff. Emits the retry protocol
/// events and repairs the runtime transcript; the owner does the waiting.
pub fn settlePromptRun(self: *AgentSession, context: SettleContext) !SettleVerdict {
    // Context overflow: start one summary run per operation; the owner
    // drives it as the compacting phase and resubmits on success.
    if (!context.overflow_retry_used and
        self.events.context_overflow_count > context.overflow_count_before)
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
        self.events.retry_attempt < self.retry_settings.max_attempts)
    {
        const attempt = self.events.beginRetryAttempt();
        const delay_ms = retryBackoffMs(self.retry_settings, attempt);
        try self.removeLastAssistantRuntimeMessage();
        return .{ .retry = .{ .kind = .continue_run, .delay_ms = delay_ms } };
    }

    self.events.failRetry(error_text, last.assistant.operational_failure);
    return .failed;
}

/// Settle an in-flight retry that will not run (cancel or shutdown).
pub fn cancelRetryWait(self: *AgentSession) void {
    self.events.failRetry("Retry cancelled", .{
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
    return self.events.context_overflow_count;
}

pub fn retryAttempt(self: *const AgentSession) u8 {
    return self.events.retry_attempt;
}

pub fn queuedEchoes(self: *const AgentSession) []const QueuedEcho {
    return self.events.queued_echoes.items;
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
/// when compaction is disabled or there is nothing to compact. Spawns the
/// summary producer; the caller owns the
/// run and must drive it to settle, then destroy it.
pub fn shouldRunThresholdCompaction(self: *const AgentSession) bool {
    const settings = self.compaction_settings;
    if (!settings.auto_enabled) return false;
    const window = self.agent.state.model.context_window;
    if (window == 0) return false;
    const usage = self.contextUsage();
    const tokens = usage.tokens orelse return false;
    if (settings.reserve_tokens >= window) return true;
    return tokens > window - settings.reserve_tokens;
}

pub fn startCompactionRun(
    self: *AgentSession,
    reason: CompactionReason,
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
        if (run.state == .cancel_requested) {
            _ = run.stream.awaitProducer() catch {};
            if (run.outcome == .summary) self.allocator.free(run.outcome.summary);
            run.outcome = .{ .failure = error.OperationCancelled };
        } else {
            run.stream.awaitProducer() catch |err| {
                if (run.outcome == .summary) self.allocator.free(run.outcome.summary);
                run.outcome = .{ .failure = err };
            };
        }
        run.state = .settled;
        return false;
    };
    defer event.deinit();
    if (run.state == .cancel_requested) return true;
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
/// replace the runtime context, and (overflow) arm the resubmit retry.
/// On failure: an overflow compaction fails the operation
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
            if (run.will_retry) {
                self.events.failRetry(@errorName(err), null);
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
    _ = self.manager.commitPreparedEntry(entry);
    entry_committed = true;

    const messages = try self.manager.contextMessages(self.allocator);
    defer session_manager.SessionManager.deinitContextMessages(self.allocator, messages);
    try self.agent.replaceMessages(messages);

    if (run.will_retry) {
        const attempt = self.events.beginRetryAttempt();
        _ = attempt;
        return .{ .retry = .{ .kind = .resubmit_prompt, .delay_ms = 0 } };
    }
    if (run.reason == .manual) return .completed;
    return .{ .retry = .{ .kind = .resubmit_prompt, .delay_ms = 0 } };
}

/// Cancel an in-flight compaction and leave the settled handle for the owner
/// to observe and destroy.
pub fn cancelCompactionRun(self: *AgentSession, run: *CompactionRun) RunHandle.CancelRequestResult {
    return switch (run.state) {
        .producing => blk: {
            run.state = .cancel_requested;
            run.cancel.request();
            run.stream.cancelProducer() catch {};
            if (run.outcome == .summary) self.allocator.free(run.outcome.summary);
            run.outcome = .{ .failure = error.OperationCancelled };
            run.state = .settled;
            break :blk .requested;
        },
        .cancel_requested => .already_requested,
        .settled => .settled,
    };
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

pub fn latestFailureView(self: *const AgentSession) ?failure_display.View {
    if (self.agent.state.messages.len == 0) return null;
    const last = self.agent.state.messages[self.agent.state.messages.len - 1];
    if (last != .assistant) return null;
    return failure_display.fromAssistant(last.assistant);
}

pub fn latestAssistantError(self: *const AgentSession) ?[]const u8 {
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

// Session-owned event state: persistence, retry counters, and queue echoes.
pub const QueuedEcho = struct {
    id: u64,
    kind: Kind,
    text: []u8,

    pub const Kind = enum { steering, follow_up };
};

const SessionEvents = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    manager: *session_manager.SessionManager,
    store: ?*session_manager.SessionStore,
    queued_echoes: std.ArrayList(QueuedEcho) = .empty,
    next_queue_id: u64 = 1,
    context_overflow_count: usize = 0,
    retry_attempt: u8 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        manager: *session_manager.SessionManager,
        store: ?*session_manager.SessionStore,
    ) SessionEvents {
        return .{
            .allocator = allocator,
            .io = io,
            .manager = manager,
            .store = store,
        };
    }

    pub fn deinit(self: *SessionEvents) void {
        for (self.queued_echoes.items) |entry| self.allocator.free(entry.text);
        self.queued_echoes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn handle(self: *SessionEvents, event: agent_mod.AgentEvent) !void {
        if (event == .message_start and event.message_start.message == .user) {
            if (message_policy.userText(event.message_start.message.user)) |text| {
                _ = self.removeQueuedTextInternal(text);
            }
        }

        var persist_error: ?anyerror = null;
        if (event == .message_end) {
            _ = self.persistMessage(event.message_end.message) catch |err| blk: {
                persist_error = err;
                break :blk null;
            };
        }

        if (event == .message_end and event.message_end.message == .assistant) {
            const assistant = event.message_end.message.assistant;
            if (message_policy.isContextOverflowAssistant(assistant, assistantContextWindow(assistant))) {
                self.context_overflow_count += 1;
            }
            if (assistant.stop_reason != .error_ and self.retry_attempt > 0) {
                self.retry_attempt = 0;
            }
        }
        if (persist_error) |err| return err;
    }

    pub fn beginRetryAttempt(self: *SessionEvents) u8 {
        std.debug.assert(self.retry_attempt < std.math.maxInt(u8));
        self.retry_attempt += 1;
        return self.retry_attempt;
    }

    pub fn failRetry(self: *SessionEvents, error_text: []const u8, failure: ?ai.OperationalFailure) void {
        _ = failure;
        _ = error_text;
        if (self.retry_attempt == 0) return;
        self.retry_attempt = 0;
    }

    fn assistantContextWindow(message: ai.AssistantMessage) u64 {
        if (ai.getModel(message.provider, message.model)) |model| return model.context_window;
        return 0;
    }

    fn persistMessage(self: *SessionEvents, message: agent_mod.AgentMessage) !?[]const u8 {
        const timestamp = session_manager.timestampNow(self.io);
        const entry = try self.manager.prepareMessageEntry(message, &timestamp);
        errdefer self.manager.deinitPreparedEntry(entry);
        if (self.store) |store| try store.appendEntry(self.io, entry, self.manager.lastEntryId());
        return self.manager.commitPreparedEntry(entry);
    }

    pub fn appendSteering(self: *SessionEvents, text: []const u8) !void {
        try self.appendQueueEcho(text, .steering);
    }

    pub fn appendFollowUp(self: *SessionEvents, text: []const u8) !void {
        try self.appendQueueEcho(text, .follow_up);
    }

    fn appendQueueEcho(self: *SessionEvents, text: []const u8, kind: QueuedEcho.Kind) !void {
        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);
        const id = self.next_queue_id;
        self.next_queue_id +%= 1;
        try self.queued_echoes.append(self.allocator, .{ .id = id, .kind = kind, .text = owned });
    }

    pub fn removeQueuedText(self: *SessionEvents, text: []const u8) void {
        _ = self.removeQueuedTextInternal(text);
    }

    fn removeQueuedTextInternal(self: *SessionEvents, text: []const u8) bool {
        var index: usize = 0;
        while (index < self.queued_echoes.items.len) : (index += 1) {
            if (!std.mem.eql(u8, self.queued_echoes.items[index].text, text)) continue;
            const entry = self.queued_echoes.orderedRemove(index);
            self.allocator.free(entry.text);
            return true;
        }
        return false;
    }

    pub fn clearQueueEchoes(self: *SessionEvents) void {
        for (self.queued_echoes.items) |entry| self.allocator.free(entry.text);
        self.queued_echoes.clearRetainingCapacity();
    }
};

fn drainAgentEvent(
    _: std.Io,
    context: ?*anyopaque,
    event: agent_mod.AgentEvent,
    _: runtime.CancelToken,
) anyerror!void {
    const events: *SessionEvents = @ptrCast(@alignCast(context.?));
    try events.handle(event);
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
    _ = session;
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
    try std.testing.expectEqual(@as(u8, 1), session.retryAttempt());
    try std.testing.expectEqual(
        ai.OperationalFailure.Category.rate_limited,
        session.manager.entries.items[1].message.message.assistant.operational_failure.?.category,
    );

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

    session.events.retry_attempt = 2;
    _ = try session.agent.beginRun();
    try emitAssistantError(&session, "rate limit exceeded");
    session.agent.finishRun();
    drainAllPublicEvents(&session);

    const verdict = try session.settlePromptRun(.{ .overflow_count_before = 0, .overflow_retry_used = false });
    try std.testing.expect(verdict == .failed);
    try std.testing.expectEqual(@as(u8, 0), session.retryAttempt());
    try std.testing.expectEqual(ai.OperationalFailure.Category.rate_limited, session.latestOperationalFailure().?.category);
}

test "retry failure resets attempt when final error allocation fails" {
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

    session.events.retry_attempt = 1;
    failing.fail_index = failing.alloc_index;
    session.events.failRetry("rate limit exceeded", null);
    failing.fail_index = std.math.maxInt(usize);

    try std.testing.expectEqual(@as(u8, 0), session.retryAttempt());
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
    try std.testing.expectEqual(@as(u8, 0), session.events.retry_attempt);
}

test "drain settles in-flight retry on successful assistant message" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var session = try initTestSession(task_runtime, tmp.dir, .{});
    defer shutdownAndDeinit(&session);

    session.events.retry_attempt = 2;
    _ = try session.agent.beginRun();
    try emitAssistantText(&session, "recovered");
    session.agent.finishRun();

    try std.testing.expectEqual(@as(u8, 0), session.retryAttempt());
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

test "queue prompt rolls back echo when agent queue allocation fails" {
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
        session.deinit();
    }

    _ = try session.agent.beginRun();
    failing.fail_index = failing.alloc_index + 2;

    try std.testing.expectError(error.OutOfMemory, session.queuePrompt("hello", &.{}, .steer));
    try std.testing.expectEqual(@as(usize, 0), session.queuedEchoes().len);
    try std.testing.expect(!session.agent.steering_queue.hasItems());
}

test "agent session persists message_end" {
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
}

test "agent session shutdown complete requires stopped idle" {
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

    const run = verdict.compact;
    try driveCompactionRun(&session, run);
    const resubmit = try session.settleCompactionRun(run);
    session.destroyCompactionRun(run);
    const expected: SettleVerdict = .{ .retry = .{ .kind = .resubmit_prompt, .delay_ms = 0 } };
    try std.testing.expectEqual(expected, resubmit);
    try std.testing.expect(session.manager.entries.items[3] == .compaction);
    try std.testing.expectEqual(@as(u8, 1), session.retryAttempt());

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

test "cancel compaction run leaves history unchanged" {
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
    try std.testing.expectEqual(RunHandle.CancelRequestResult.requested, session.cancelCompactionRun(run));
    try driveCompactionRun(&session, run);
    _ = try session.settleCompactionRun(run);
    session.destroyCompactionRun(run);
    try std.testing.expectEqual(@as(usize, 2), session.manager.entries.items.len);
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
