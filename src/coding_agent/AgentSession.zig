//! One session's policy spine: prompt resources, system prompt, builtin
//! tools, durable history, the long-lived agent, the bounded public event
//! queue, lifecycle, and the compaction/retry terminal policies.
//!
//! Known limit, by design until an operation-backed shape is needed:
//! auto-compaction and auto-retry run synchronously inside the owner loop.
//! Both are settings-gated and default off.

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
const session_store = @import("session_store.zig");
const system_prompt = @import("system_prompt.zig");
const tool_registry = @import("tool_registry.zig");

const AgentSession = @This();

pub const public_event_capacity_default = 256;
const max_compaction_summary_prompt_bytes = session_manager.max_compaction_serialized_input_bytes + 4096;
const live_prompt_event_capacity_count = 64;

allocator: std.mem.Allocator,
io: std.Io,
task_runtime: *runtime.Runtime,
cwd: []const u8,
current_date: []const u8,
timestamp: []const u8,
prompt_resources: resources.PromptResources,
system_prompt_text: []const u8,
builtin_tools: *tool_registry.BuiltinTools,
tools: tool_registry.ToolRegistry,
manager: *session_manager.SessionManager,
store: ?*session_store.SessionStore = null,
agent: *agent_mod.Agent,
event_drain: *event_drain_mod.EventDrain,
lifecycle: Lifecycle = .accepting,
compaction_settings: session_manager.CompactionSettings = .{},
retry_settings: RetrySettings = .{},

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
    create: session_store.SessionStore,
    restore: session_store.SessionStore,
};

pub const QueuePromptKind = enum { steer, follow_up };

pub const RetrySettings = struct {
    enabled: bool = false,
    max_attempts: u8 = 3,
    base_delay_ms: u64 = 2_000,
};

/// Hard ceiling on one retry backoff wait, whatever the settings say.
pub const retry_delay_max_ms = 60_000;

/// What the owner should do after a prompt run settles. `retry` means the
/// owner waits `delay_ms`, then starts the retry run; the session never
/// blocks here.
pub const SettleVerdict = union(enum) {
    completed,
    failed,
    retry: Retry,

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

pub const PromptRun = struct {
    state: State = .settled,
    stream: agent_mod.loop.AgentEventStream = undefined,
    buffer: [live_prompt_event_capacity_count]agent_mod.AgentEvent = undefined,
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

const Error = error{
    SessionBusy,
    SessionCancelling,
    SessionShuttingDown,
};

const Lifecycle = enum {
    accepting,
    cancel_requested,
    shutdown_requested,
    stopped,
};

pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) !AgentSession {
    const task_runtime = options.task_runtime;

    const cwd = try allocator.dupe(u8, options.cwd);
    errdefer allocator.free(cwd);
    const current_date = try allocator.dupe(u8, options.current_date);
    errdefer allocator.free(current_date);
    const timestamp = try allocator.dupe(u8, options.timestamp);
    errdefer allocator.free(timestamp);

    var prompt_resources = try resources.PromptResources.load(allocator, io, .{
        .dir = options.dir,
        .agent_dir = options.agent_dir,
        .cwd = options.cwd,
    });
    errdefer prompt_resources.deinit();

    const builtin_tools = try tool_registry.BuiltinTools.init(allocator, .{
        .cwd = options.cwd,
        .environ = options.environ,
        .allow_paths_outside_cwd = options.allow_paths_outside_cwd,
    });
    errdefer builtin_tools.deinit();

    var tools: tool_registry.ToolRegistry = .{};
    try builtin_tools.appendDefinitions(&tools);

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
        try options.store.?.restore.load(allocator, io)
    else
        try session_manager.SessionManager.init(
            allocator,
            options.cwd,
            options.session_id,
            options.timestamp,
        );
    errdefer manager.deinit();

    const store = if (options.store) |store_options| blk: {
        const store_ptr = try allocator.create(session_store.SessionStore);
        store_ptr.* = switch (store_options) {
            .create, .restore => |provided| provided,
        };
        break :blk store_ptr;
    } else null;
    errdefer if (store) |store_ptr| {
        store_ptr.deinit(allocator);
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
        timestamp,
        options.public_event_capacity,
    );
    errdefer event_drain.deinit();

    _ = try core_agent.subscribe(.{ .context = event_drain, .call_fn = drainAgentEvent });

    return .{
        .allocator = allocator,
        .io = io,
        .task_runtime = task_runtime,
        .cwd = cwd,
        .current_date = current_date,
        .timestamp = timestamp,
        .prompt_resources = prompt_resources,
        .system_prompt_text = system_prompt_text,
        .builtin_tools = builtin_tools,
        .tools = tools,
        .manager = manager,
        .store = store,
        .agent = core_agent,
        .event_drain = event_drain,
        .lifecycle = .accepting,
        .compaction_settings = options.compaction_settings,
        .retry_settings = options.retry_settings,
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
        store.deinit(self.allocator);
        self.allocator.destroy(store);
    }
    self.manager.deinit();
    self.allocator.destroy(self.manager);
    self.builtin_tools.deinit();
    self.allocator.free(self.system_prompt_text);
    self.prompt_resources.deinit();
    self.allocator.free(self.timestamp);
    self.allocator.free(self.current_date);
    self.allocator.free(self.cwd);
    self.* = undefined;
}

pub fn startPromptRun(
    self: *AgentSession,
    text: []const u8,
    images: []const ai.ImageContent,
) !*PromptRun {
    self.reconcileLifecycle();
    switch (self.lifecycle) {
        .accepting => {},
        .cancel_requested => return error.SessionCancelling,
        .shutdown_requested, .stopped => return error.SessionShuttingDown,
    }
    if (self.agent.state.isStreaming()) return error.SessionBusy;
    if (self.compaction_settings.auto_enabled) _ = try self.runAutoCompaction(.threshold, false);
    const run = try self.allocator.create(PromptRun);
    errdefer self.allocator.destroy(run);
    run.* = .{};
    run.prompts[0] = try self.agent.userMessageFromText(text, images);
    const token = try self.agent.beginRun();
    errdefer self.agent.finishRun();
    agent_mod.loop.startPromptStream(
        &run.stream,
        self.allocator,
        self.task_runtime,
        &run.prompts,
        .{
            .system_prompt = self.agent.state.system_prompt,
            .messages = self.agent.state.messages,
            .tools = self.agent.state.tools,
        },
        self.agent.loop_config,
        token,
        &run.buffer,
    );
    std.debug.assert(run.state == .settled);
    run.state = .{ .running = token };
    return run;
}

/// Begin a run that continues from the current transcript without a new
/// user message: the retry path after the failed assistant message has been
/// removed. Fails if the transcript still ends with an assistant message.
pub fn startContinueRun(self: *AgentSession) !*PromptRun {
    self.reconcileLifecycle();
    switch (self.lifecycle) {
        .accepting => {},
        .cancel_requested => return error.SessionCancelling,
        .shutdown_requested, .stopped => return error.SessionShuttingDown,
    }
    if (self.agent.state.isStreaming()) return error.SessionBusy;
    if (self.agent.state.messages.len == 0) return error.NoMessages;
    if (self.agent.state.messages[self.agent.state.messages.len - 1] == .assistant) {
        return error.CannotContinueFromAssistant;
    }
    const run = try self.allocator.create(PromptRun);
    errdefer self.allocator.destroy(run);
    run.* = .{};
    const token = try self.agent.beginRun();
    errdefer self.agent.finishRun();
    agent_mod.loop.startContinueStream(
        &run.stream,
        self.allocator,
        self.task_runtime,
        .{
            .system_prompt = self.agent.state.system_prompt,
            .messages = self.agent.state.messages,
            .tools = self.agent.state.tools,
        },
        self.agent.loop_config,
        token,
        &run.buffer,
    );
    std.debug.assert(run.state == .settled);
    run.state = .{ .running = token };
    return run;
}

/// Apply one stream progress result. Returns true while the run is live.
pub fn applyPromptRunProgress(
    self: *AgentSession,
    run: *PromptRun,
    progress: @TypeOf(run.stream.asyncNext()).Result,
) !bool {
    if (!run.isActive()) return false;
    const event = progress orelse {
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
    defer agent_mod.loop.deinitStreamEvent(self.allocator, event);
    try self.agent.emitEvent(event);
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

pub fn cancel(self: *AgentSession) void {
    self.reconcileLifecycle();
    if (self.lifecycle != .accepting) return;
    if (self.agent.state.status == .settling) return;
    if (!self.agent.state.isStreaming()) return;
    self.lifecycle = .cancel_requested;
    self.agent.abort();
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

pub fn queueSnapshot(self: *const AgentSession, allocator: std.mem.Allocator) !client_protocol.QueueSnapshot {
    return self.event_drain.queueSnapshot(allocator);
}

pub fn clearQueue(self: *AgentSession) !void {
    self.agent.clearAllQueues();
    try self.event_drain.clearQueueMirror();
}

pub fn drainPublicEvent(self: *AgentSession) ?client_protocol.ClientEvent {
    return self.event_drain.drainPublicEvent();
}

pub fn publicEventWake(self: *AgentSession) *runtime.ResetEvent {
    return self.event_drain.publicEventWake();
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
    const message = try self.agent.userMessageFromText(text, images);
    switch (kind) {
        .steer => {
            try self.agent.steer(message);
            try self.event_drain.queue_mirror.appendSteering(self.allocator, text);
        },
        .follow_up => {
            try self.agent.followUp(message);
            try self.event_drain.queue_mirror.appendFollowUp(self.allocator, text);
        },
    }
    try self.event_drain.emitQueueUpdate();
}

/// Terminal session policy after a prompt run settles. Decides between
/// completion, failure, overflow-compaction + prompt resubmission, and
/// provider-error retry with exponential backoff. Emits the retry protocol
/// events and repairs the runtime transcript; the owner does the waiting.
pub fn settlePromptRun(self: *AgentSession, context: SettleContext) !SettleVerdict {
    // Context overflow: compact once per operation, then resubmit.
    if (!context.overflow_retry_used and
        self.compaction_settings.auto_enabled and
        self.event_drain.context_overflow_count > context.overflow_count_before)
    {
        if (try self.runAutoCompaction(.overflow, true)) {
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
        const error_message = try client_protocol.EventText.init(self.allocator, error_text);
        self.event_drain.enqueuePublicEvent(.{ .auto_retry_start = .{
            .attempt = attempt,
            .max_attempts = self.retry_settings.max_attempts,
            .delay_ms = delay_ms,
            .error_message = error_message,
        } });
        try self.removeLastAssistantRuntimeMessage();
        return .{ .retry = .{ .kind = .continue_run, .delay_ms = delay_ms } };
    }

    self.event_drain.failRetry(error_text);
    return .failed;
}

/// Settle an in-flight retry that will not run (cancel or shutdown).
pub fn cancelRetryWait(self: *AgentSession) void {
    self.event_drain.failRetry("Retry cancelled");
}

fn retryBackoffMs(settings: RetrySettings, attempt: u8) u64 {
    std.debug.assert(attempt >= 1);
    const shift: u6 = @intCast(@min(attempt - 1, 16));
    return @min(settings.base_delay_ms *| (@as(u64, 1) << shift), retry_delay_max_ms);
}

pub fn contextOverflowCount(self: *const AgentSession) usize {
    return self.event_drain.context_overflow_count;
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

/// Run one settings-gated auto-compaction. Returns false (quietly) when
/// there is nothing to compact; emits compaction_start/_end otherwise.
fn runAutoCompaction(
    self: *AgentSession,
    reason: client_protocol.CompactionReason,
    will_retry: bool,
) !bool {
    var input = self.manager.buildCompactionSummaryInput(
        self.allocator,
        self.compaction_settings,
    ) catch |err| switch (err) {
        error.NothingToCompact, error.AlreadyCompacted => return false,
        else => return err,
    };
    defer input.deinit();
    self.event_drain.enqueuePublicEvent(.{ .compaction_start = .{ .reason = reason } });
    self.generateAndApplyCompaction(&input, reason, will_retry) catch |err| {
        const error_message = client_protocol.EventText.init(self.allocator, @errorName(err)) catch return err;
        self.event_drain.enqueuePublicEvent(.{ .compaction_end = .{
            .reason = reason,
            .aborted = err == error.OperationCancelled,
            .will_retry = false,
            .error_message = error_message,
        } });
        return err;
    };
    return true;
}

fn generateAndApplyCompaction(
    self: *AgentSession,
    input: *session_manager.CompactionSummaryInput,
    reason: client_protocol.CompactionReason,
    will_retry: bool,
) !void {
    const serialized_input = try input.serialize(self.allocator);
    defer self.allocator.free(serialized_input);
    const summary = try self.generateCompactionSummary(serialized_input);
    defer self.allocator.free(summary);

    // Persist the compaction entry durably before committing it in memory.
    try self.manager.ensureAppendCapacity(1);
    const entry = try self.manager.prepareCompactionEntry(
        summary,
        input.first_kept_entry_id,
        input.tokens_before,
        self.timestamp,
    );
    var entry_committed = false;
    errdefer if (!entry_committed) self.manager.deinitPreparedEntry(entry);
    if (self.store) |store| try store.appendEntry(self.allocator, self.io, entry);
    var result = try client_protocol.CompactionResult.init(self.allocator, entry.compaction);
    errdefer result.deinit(self.allocator);
    _ = self.manager.commitPreparedEntry(entry);
    entry_committed = true;

    const messages = try self.manager.contextMessages(self.allocator);
    defer session_manager.SessionManager.deinitContextMessages(self.allocator, messages);
    try self.agent.replaceMessages(messages);

    self.event_drain.enqueuePublicEvent(.{ .compaction_end = .{
        .reason = reason,
        .result = result,
        .aborted = false,
        .will_retry = will_retry,
    } });
}

fn generateCompactionSummary(self: *AgentSession, serialized_input: []const u8) ![]const u8 {
    const prefix =
        "Summarize the conversation for future continuation. Preserve user intent, decisions, files, " ++
        "tool outcomes, and unresolved work. Return only the summary.\n\n";
    if (serialized_input.len > max_compaction_summary_prompt_bytes - prefix.len - 1) {
        return error.CompactionSummaryPromptTooLarge;
    }
    const summary_prompt = try std.fmt.allocPrint(self.allocator, "{s}{s}\n", .{ prefix, serialized_input });
    defer self.allocator.free(summary_prompt);
    var messages = [_]ai.Message{.{ .user = .{
        .content = .{ .string = summary_prompt },
        .timestamp = 0,
    } }};

    var stream_options = self.agent.loop_config.options.stream;
    var owned_api_key: ?[]const u8 = null;
    defer if (owned_api_key) |api_key| self.allocator.free(api_key);
    if (self.agent.loop_config.get_api_key) |get_api_key| {
        const credential = try agent_mod.GetApiKeyHook.call(
            self.allocator,
            get_api_key,
            self.agent.state.model.provider,
        );
        if (credential) |value| {
            owned_api_key = value.api_key;
            stream_options.api_key = value.api_key;
            stream_options.auth_extra = value.auth_extra;
        }
    }

    var response_arena = std.heap.ArenaAllocator.init(self.allocator);
    defer response_arena.deinit();
    var stream = self.agent.loop_config.stream.call(.{
        .allocator = response_arena.allocator(),
        .io = self.io,
        .model = self.agent.state.model,
        .context = .{
            .system_prompt = null,
            .messages = &messages,
            .tools = &.{},
        },
        .options = stream_options,
        .cancel_token = null,
    });
    defer stream.deinit();

    while (try stream.next(self.io)) |event| switch (event) {
        .@"error" => |payload| return extractCompactionSummary(self.allocator, payload.@"error"),
        else => {},
    };
    const result = stream.result() orelse return error.MissingCompactionSummary;
    return extractCompactionSummary(self.allocator, result);
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
    if (!std.mem.eql(u8, context.tool_call.name, "bash")) return null;
    return .{ .is_error = bash_tool.classifyResult(context.result.details, context.is_error) };
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
    dir.createDirPath(std.testing.io, "agent") catch {};
    dir.createDirPath(std.testing.io, "repo") catch {};
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
    try std.testing.expectEqual(
        SettleVerdict{ .retry = .{ .kind = .continue_run, .delay_ms = 100 } },
        verdict,
    );
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

    try std.testing.expectEqual(tool_registry.default_active_tool_names.len, session.tools.len);
    try std.testing.expectEqual(tool_registry.default_active_tool_names.len, session.agent.state.tools.len);
    try std.testing.expectEqualStrings("read", session.tools.activeToolNames()[0]);
    try std.testing.expectEqualStrings("bash", session.agent.state.tools[4].name);
    try std.testing.expectEqual(agent_mod.ToolExecutionMode.sequential, session.agent.state.tools[4].execution_mode.?);
    try std.testing.expect(std.mem.indexOf(u8, session.system_prompt_text, "global") != null);
}

test "live prompt run uses explicit bounded event buffer" {
    try std.testing.expectEqual(@as(usize, 64), live_prompt_event_capacity_count);
    try std.testing.expectEqual(
        live_prompt_event_capacity_count,
        @typeInfo(@FieldType(PromptRun, "buffer")).array.len,
    );
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
    try std.testing.expectEqual(@as(usize, 1), session.event_drain.publicEventCount());
    var event = session.drainPublicEvent().?;
    defer event.deinit(std.testing.allocator);
    try std.testing.expect(event == .agent_event);
    try std.testing.expect(event.agent_event.event == .message_end);
    try std.testing.expect(session.drainPublicEvent() == null);
}

test "agent session cancel while running is observable until terminal event" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var session = try initTestSession(task_runtime, tmp.dir, .{});
    defer shutdownAndDeinit(&session);

    _ = try session.agent.beginRun();
    session.cancel();

    try std.testing.expectEqual(Lifecycle.cancel_requested, session.lifecycle);
    try std.testing.expect(session.agent.signal().?.isRequested());

    try session.agent.emitEvent(.agent_end);
    session.agent.finishRun();

    session.reconcileLifecycle();
    try std.testing.expectEqual(Lifecycle.accepting, session.lifecycle);
    drainAllPublicEvents(&session);
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
    try std.testing.expectEqual(@as(usize, 1), session.event_drain.droppedPublicEventCount());

    var first = session.drainPublicEvent().?;
    first.deinit(std.testing.allocator);
    var overflow_event = session.drainPublicEvent().?;
    defer overflow_event.deinit(std.testing.allocator);
    try std.testing.expect(overflow_event == .event_overflow);
    try std.testing.expectEqual(@as(usize, 1), overflow_event.event_overflow.dropped_count);
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

fn appendTwoCompactableMessages(session: *AgentSession) !void {
    _ = try session.manager.appendMessage(.{ .user = .{
        .content = .{ .string = "aaaaaaaa" },
        .timestamp = 0,
    } }, "t1");
    _ = try session.manager.appendMessage(.{ .user = .{
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

    const store = try session_store.SessionStore.create(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "repo",
        "session",
        "2026-05-25T00:00:00Z",
    );
    var session = try initCompactionTestSession(task_runtime, tmp.dir, &provider, .{ .create = store });
    defer shutdownAndDeinit(&session);

    _ = try session.agent.beginRun();
    try emitUserMessageEnd(&session, "aaaaaaaa");
    try emitUserMessageEnd(&session, "bbbbbbbb");
    session.agent.finishRun();
    drainAllPublicEvents(&session);
    const kept = session.manager.entries.items[1].id();

    try std.testing.expect(try session.runAutoCompaction(.threshold, false));

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
    var loaded = try session.store.?.load(std.testing.allocator, std.testing.io);
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

    try std.testing.expectError(
        error.CompactionSummaryGenerationFailed,
        session.runAutoCompaction(.threshold, false),
    );
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

    try std.testing.expectError(error.CompactionSummaryTooLarge, session.runAutoCompaction(.threshold, false));
    try std.testing.expectEqual(@as(usize, 2), session.manager.entries.items.len);
    drainAllPublicEvents(&session);
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

    var store: session_store.SessionStore = .{
        .dir = tmp.dir,
        .file_name = try std.testing.allocator.dupe(u8, "missing/session.jsonl"),
    };
    var store_needs_deinit = true;
    errdefer if (store_needs_deinit) store.deinit(std.testing.allocator);
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
