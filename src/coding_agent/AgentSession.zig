const std = @import("std");
const agent_mod = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const runtime = @import("../runtime/root.zig");
const event_drain_mod = @import("event_drain.zig");
const message_policy = @import("message_policy.zig");
const resources = @import("resources.zig");
const prompt_command = @import("prompt_command.zig");
const queue_mirror_mod = @import("queue_mirror.zig");
const session_events = @import("session_events.zig");
const session_history_snapshot = @import("session_history_snapshot.zig");
const session_manager = @import("session_manager.zig");
const session_store = @import("session_store.zig");
const system_prompt = @import("system_prompt.zig");
const tool_registry = @import("tool_registry.zig");

const AgentSession = @This();

pub const public_event_capacity_default = 256;
pub const max_compaction_summary_prompt_bytes = session_manager.max_compaction_serialized_input_bytes + 4096;
pub const max_auto_retry_attempts_limit = 8;
pub const live_prompt_event_capacity_count = 64;

allocator: std.mem.Allocator,
io: std.Io,
zio_runtime: *runtime.Runtime,
cwd: []const u8,
current_date: []const u8,
timestamp: []const u8,
prompt_resources: resources.PromptResources,
system_prompt_text: []const u8,
builtin_tools: tool_registry.BuiltinTools,
tools: tool_registry.ToolRegistry,
manager: *session_manager.SessionManager,
store: ?*session_store.SessionStore = null,
agent: *agent_mod.Agent,
public_event_buffer: []session_events.AgentSessionEvent,
public_events: *event_drain_mod.PublicEventQueue,
queue_mirror: *queue_mirror_mod.QueueMirror,
event_drain: *event_drain_mod.EventDrain,
lifecycle: Lifecycle = .accepting,
compaction_settings: session_manager.CompactionSettings = .{},
retry_settings: RetrySettings = .{},
active_compaction_cancel_source: ?*runtime.CancelSource = null,

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
    allow_paths_outside_cwd: bool = false,
    public_event_capacity: usize = public_event_capacity_default,
    session_store: ?session_store.SessionStore = null,
    resume_session_store: ?session_store.SessionStore = null,
    zio_runtime: *runtime.Runtime,
};

pub const StreamingBehavior = enum {
    steer,
    follow_up,
};

pub const PromptOptions = struct {
    streaming_behavior: ?StreamingBehavior = null,
};

pub const RetrySettings = struct {
    enabled: bool = false,
    max_attempts: u8 = 1,

    pub fn validate(self: RetrySettings) error{RetrySettingsOutOfBounds}!void {
        if (self.max_attempts > max_auto_retry_attempts_limit) return error.RetrySettingsOutOfBounds;
    }
};

const PromptRetryPolicy = struct {
    overflow: bool = true,
    transient: bool = true,
};

const ManualCompactionRequest = union(enum) {
    explicit: Explicit,
    prepared: Prepared,

    const Explicit = struct {
        summary: []const u8,
        first_kept_entry_id: []const u8,
        tokens_before: u64,
    };

    const Prepared = struct {
        summary: []const u8,
        settings: session_manager.CompactionSettings,
    };
};

pub const LivePromptRun = struct {
    token: runtime.CancelToken,
    stream: agent_mod.loop.AgentEventStream = undefined,
    buffer: [live_prompt_event_capacity_count]agent_mod.AgentEvent = undefined,
    prompts: [1]agent_mod.AgentMessage = undefined,
    active: bool = false,
};

pub const AgentSessionStatus = enum {
    idle,
    running,
    cancel_requested,
    shutdown_requested,
    stopped,
};

pub const RuntimeStatusSnapshot = struct {
    status: AgentSessionStatus,
    public_event_count: usize,
    dropped_public_event_count: usize,
    context_overflow_count: usize,
};

pub const PublicHistorySnapshot = session_history_snapshot.Snapshot;

pub fn publicHistorySnapshot(self: *const AgentSession, allocator: std.mem.Allocator) !PublicHistorySnapshot {
    return session_history_snapshot.build(allocator, self.manager);
}

pub const Error = error{
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
    const zio_runtime = options.zio_runtime;

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

    var builtin_tools = try tool_registry.BuiltinTools.init(allocator, .{
        .cwd = options.cwd,
        .allow_paths_outside_cwd = options.allow_paths_outside_cwd,
    });
    errdefer builtin_tools.deinit();

    var tools: tool_registry.ToolRegistry = .{};
    errdefer tools.deinit(allocator);
    try builtin_tools.appendDefinitions(&tools);
    try tools.setActiveToolsByName(allocator, tool_registry.default_active_tool_names);

    const system_prompt_text = try buildSystemPromptText(
        allocator,
        options.cwd,
        options.current_date,
        &prompt_resources,
        &tools,
        tools.activeToolNames(),
    );
    errdefer allocator.free(system_prompt_text);

    if (options.session_store != null and options.resume_session_store != null) return error.DuplicateSessionStore;

    const manager = try allocator.create(session_manager.SessionManager);
    errdefer allocator.destroy(manager);
    manager.* = if (options.resume_session_store) |resume_store|
        try resume_store.load(allocator, io)
    else
        try session_manager.SessionManager.init(
            allocator,
            options.cwd,
            options.session_id,
            options.timestamp,
        );
    errdefer manager.deinit();

    const store = if (options.session_store orelse options.resume_session_store) |provided_store| blk: {
        const store_ptr = try allocator.create(session_store.SessionStore);
        errdefer allocator.destroy(store_ptr);
        store_ptr.* = provided_store;
        break :blk store_ptr;
    } else null;
    errdefer if (store) |store_ptr| {
        store_ptr.deinit(allocator);
        allocator.destroy(store_ptr);
    };

    const session_context = try manager.buildSessionContext(allocator);
    defer manager.deinitSessionContext(allocator, session_context);

    var agent_options: agent_mod.Agent.Options = .{
        .system_prompt = system_prompt_text,
        .model = options.model,
        .thinking_level = options.thinking_level,
        .tools = tools.activeAgentTools(),
        .messages = session_context.messages,
        .zio_runtime = zio_runtime,
    };
    if (options.stream) |stream| agent_options.stream = stream;
    if (options.get_api_key) |get_api_key| agent_options.get_api_key = get_api_key;

    const core_agent = try allocator.create(agent_mod.Agent);
    errdefer allocator.destroy(core_agent);
    core_agent.* = try agent_mod.Agent.init(allocator, io, agent_options);
    errdefer core_agent.deinit();

    if (options.public_event_capacity == 0) return error.PublicEventCapacityZero;
    const public_event_buffer = try allocator.alloc(session_events.AgentSessionEvent, options.public_event_capacity);
    errdefer allocator.free(public_event_buffer);
    const public_events = try allocator.create(event_drain_mod.PublicEventQueue);
    errdefer allocator.destroy(public_events);
    public_events.* = event_drain_mod.PublicEventQueue.init(public_event_buffer);

    const queue_mirror = try allocator.create(queue_mirror_mod.QueueMirror);
    errdefer allocator.destroy(queue_mirror);
    queue_mirror.* = .{};
    errdefer queue_mirror.deinit(allocator);

    const event_drain = try allocator.create(event_drain_mod.EventDrain);
    errdefer allocator.destroy(event_drain);
    event_drain.* = .{
        .allocator = allocator,
        .io = io,
        .manager = manager,
        .store = store,
        .queue_mirror = queue_mirror,
        .public_events = public_events,
        .timestamp = timestamp,
    };

    _ = try core_agent.subscribe(.{ .context = event_drain, .call_fn = drainAgentEvent });

    return .{
        .allocator = allocator,
        .io = io,
        .zio_runtime = zio_runtime,
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
        .public_event_buffer = public_event_buffer,
        .public_events = public_events,
        .queue_mirror = queue_mirror,
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
    self.allocator.destroy(self.event_drain);
    self.queue_mirror.deinit(self.allocator);
    self.allocator.destroy(self.queue_mirror);
    self.allocator.destroy(self.public_events);
    self.allocator.free(self.public_event_buffer);
    if (self.store) |store| {
        store.deinit(self.allocator);
        self.allocator.destroy(store);
    }
    self.manager.deinit();
    self.allocator.destroy(self.manager);
    self.tools.deinit(self.allocator);
    self.builtin_tools.deinit();
    self.allocator.free(self.system_prompt_text);
    self.prompt_resources.deinit();
    self.allocator.free(self.timestamp);
    self.allocator.free(self.current_date);
    self.allocator.free(self.cwd);
    self.* = undefined;
}

pub fn prompt(self: *AgentSession, text: []const u8, images: []const ai.ImageContent) !void {
    try self.promptWithOptions(text, images, .{});
}

pub fn promptWithOptions(
    self: *AgentSession,
    text: []const u8,
    images: []const ai.ImageContent,
    options: PromptOptions,
) !void {
    try self.promptWithOptionsInternal(text, images, options, .{});
}

fn promptWithOptionsInternal(
    self: *AgentSession,
    text: []const u8,
    images: []const ai.ImageContent,
    options: PromptOptions,
    retry_policy: PromptRetryPolicy,
) anyerror!void {
    try self.retry_settings.validate();
    const context_overflow_count_before = self.event_drain.context_overflow_count;
    const run = self.startPromptRun(text, images, options) catch |err| switch (err) {
        error.PromptCommandCannotStartLiveRun, error.PromptQueuedCannotStartLiveRun => return,
        else => |unexpected| return unexpected,
    };
    defer self.destroyPromptRun(run);
    while (try self.stepPromptRun(run)) {}
    const compacted = if (retry_policy.overflow)
        try self.checkPostPromptOverflowCompaction(context_overflow_count_before, true)
    else
        false;
    if (compacted and retry_policy.overflow) {
        try self.retryPromptAfterOverflowCompaction(text, images, options);
    } else if (retry_policy.transient) {
        if (self.latestRetryableAssistantError()) |error_message| {
            try self.retryPromptAfterRetryableError(text, images, options, error_message);
        }
    }
}

fn startPromptRun(
    self: *AgentSession,
    text: []const u8,
    images: []const ai.ImageContent,
    options: PromptOptions,
) !*LivePromptRun {
    try self.ensureAcceptsPrompt();
    var preflight = self.preparePromptInput(text, images, options);
    if (try self.tryHandlePromptCommand(&preflight)) return error.PromptCommandCannotStartLiveRun;
    if (try self.queuePromptIfStreaming(&preflight)) return error.PromptQueuedCannotStartLiveRun;
    try self.checkPrePromptCompaction();
    return self.startPreparedPromptRun(&preflight);
}

pub fn startLivePromptRun(
    self: *AgentSession,
    text: []const u8,
    images: []const ai.ImageContent,
    options: PromptOptions,
) !*LivePromptRun {
    return self.startPromptRun(text, images, options);
}

fn startPreparedPromptRun(self: *AgentSession, preflight: *const PromptPreflight) !*LivePromptRun {
    const run = try self.allocator.create(LivePromptRun);
    errdefer self.allocator.destroy(run);
    run.* = .{ .token = undefined };
    run.prompts[0] = try self.constructUserMessage(preflight.text, preflight.images);
    run.token = try self.agent.beginRun();
    errdefer self.agent.finishRun();
    agent_mod.loop.startPromptStream(
        &run.stream,
        self.allocator,
        self.zio_runtime,
        &run.prompts,
        .{
            .system_prompt = self.agent.state.system_prompt,
            .messages = self.agent.state.messages,
            .tools = self.agent.state.tools,
        },
        self.agent.loop_config,
        run.token,
        &run.buffer,
    );
    run.active = true;
    return run;
}

pub fn stepPromptRun(self: *AgentSession, run: *LivePromptRun) !bool {
    if (!run.active) return false;
    if (try run.stream.next()) |event| {
        return self.applyPromptRunEvent(run, event);
    }
    return self.finishPromptRun(run);
}

pub fn drainPromptRunReady(self: *AgentSession, run: *LivePromptRun) !?bool {
    if (!run.active) return false;
    return switch (run.stream.poll()) {
        .event => |event| try self.applyPromptRunEvent(run, event),
        .terminal => try self.finishPromptRun(run),
        .empty => null,
    };
}

pub fn promptRunProgress(run: *LivePromptRun) @TypeOf(run.stream.asyncNext()) {
    return run.stream.asyncNext();
}

pub fn applyPromptRunProgress(
    self: *AgentSession,
    run: *LivePromptRun,
    progress: @TypeOf(run.stream.asyncNext()).Result,
) !bool {
    if (!run.active) return false;
    const event = progress orelse return self.finishPromptRun(run);
    return self.applyPromptRunEvent(run, event);
}

fn applyPromptRunEvent(self: *AgentSession, run: *LivePromptRun, event: agent_mod.AgentEvent) !bool {
    std.debug.assert(run.active);
    try self.agent.emitEvent(event);
    return true;
}

fn finishPromptRun(self: *AgentSession, run: *LivePromptRun) !bool {
    std.debug.assert(run.active);
    run.stream.awaitProducer() catch |err| {
        try self.agent.failRun(run.token, @errorName(err));
        self.agent.finishRun();
        run.active = false;
        return err;
    };
    self.agent.finishRun();
    run.active = false;
    return false;
}

pub fn destroyPromptRun(self: *AgentSession, run: *LivePromptRun) void {
    if (run.active) {
        // Cancellation is cleanup. The producer may finish with its own error
        // while being drained; the invariant here is that ownership is settled.
        run.stream.cancelProducer() catch |err| {
            const ignored_cleanup_error = @errorName(err);
            _ = ignored_cleanup_error;
        };
        self.agent.finishRun();
        run.active = false;
    }
    run.stream.deinit();
    self.allocator.destroy(run);
}

pub fn continueRun(self: *AgentSession) !void {
    try self.ensureAcceptsIdleCommand();
    try self.agent.continueRun();
}

fn compactWithSummary(
    self: *AgentSession,
    summary: []const u8,
    first_kept_entry_id: []const u8,
    tokens_before: u64,
) !session_events.CompactionResult {
    return self.runManualCompaction(.{ .explicit = .{
        .summary = summary,
        .first_kept_entry_id = first_kept_entry_id,
        .tokens_before = tokens_before,
    } });
}

fn compactPreparedWithSummary(
    self: *AgentSession,
    summary: []const u8,
    settings: session_manager.CompactionSettings,
) !session_events.CompactionResult {
    return self.runManualCompaction(.{ .prepared = .{
        .summary = summary,
        .settings = settings,
    } });
}

pub fn compactWithPreparedSummary(self: *AgentSession, summary: []const u8) !session_events.CompactionResult {
    return self.runManualCompaction(.{ .prepared = .{
        .summary = summary,
        .settings = self.compaction_settings,
    } });
}

pub fn compactWithGeneratedSummary(self: *AgentSession) !session_events.CompactionResult {
    try self.ensureAcceptsIdleCommand();
    return self.runGeneratedCompaction(.manual, false);
}

fn runGeneratedCompaction(
    self: *AgentSession,
    reason: session_events.AgentSessionEvent.CompactionReason,
    will_retry: bool,
) !session_events.CompactionResult {
    self.event_drain.enqueuePublicEvent(.{ .compaction_start = .{ .reason = reason } });
    return self.generateAndApplyCompaction(reason, will_retry) catch |err| {
        const error_message = session_events.EventText.init(self.allocator, @errorName(err)) catch return err;
        self.event_drain.enqueuePublicEvent(.{ .compaction_end = .{
            .reason = reason,
            .aborted = err == error.OperationCancelled,
            .will_retry = false,
            .error_message = error_message,
        } });
        return err;
    };
}

fn runManualCompaction(
    self: *AgentSession,
    request: ManualCompactionRequest,
) !session_events.CompactionResult {
    try self.ensureAcceptsIdleCommand();
    self.event_drain.enqueuePublicEvent(.{ .compaction_start = .{ .reason = .manual } });
    return self.applyManualCompactionRequest(request) catch |err| {
        const error_message = session_events.EventText.init(self.allocator, @errorName(err)) catch return err;
        self.event_drain.enqueuePublicEvent(.{ .compaction_end = .{
            .reason = .manual,
            .aborted = false,
            .will_retry = false,
            .error_message = error_message,
        } });
        return err;
    };
}

pub fn cancel(self: *AgentSession) void {
    self.reconcileLifecycle();
    if (self.active_compaction_cancel_source) |source| {
        if (self.lifecycle == .shutdown_requested or self.lifecycle == .stopped) return;
        if (self.lifecycle == .cancel_requested) return;
        self.lifecycle = .cancel_requested;
        source.request();
        return;
    }
    if (self.agent.state.status == .settling) return;
    if (!self.agent.state.isStreaming()) return;
    if (self.lifecycle == .shutdown_requested or self.lifecycle == .stopped) return;
    if (self.lifecycle == .cancel_requested) return;
    self.lifecycle = .cancel_requested;
    self.agent.abort();
}

pub fn requestShutdown(self: *AgentSession) void {
    self.reconcileLifecycle();
    switch (self.lifecycle) {
        .stopped, .shutdown_requested => return,
        .accepting, .cancel_requested => {},
    }
    if (self.active_compaction_cancel_source) |source| {
        self.lifecycle = .shutdown_requested;
        source.request();
        return;
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

pub fn status(self: *AgentSession) AgentSessionStatus {
    self.reconcileLifecycle();
    return switch (self.lifecycle) {
        .stopped => .stopped,
        .shutdown_requested => .shutdown_requested,
        .cancel_requested => .cancel_requested,
        .accepting => if (self.agent.state.isStreaming() or
            self.active_compaction_cancel_source != null) .running else .idle,
    };
}

pub fn statusSnapshot(self: *AgentSession) RuntimeStatusSnapshot {
    return .{
        .status = self.status(),
        .public_event_count = self.public_events.count(),
        .dropped_public_event_count = self.public_events.dropped(),
        .context_overflow_count = self.event_drain.context_overflow_count,
    };
}

pub fn shutdownComplete(self: *AgentSession) bool {
    self.reconcileLifecycle();
    return self.lifecycle == .stopped and
        self.agent.waitForIdle() and
        self.public_events.empty();
}

pub fn setActiveToolsByName(self: *AgentSession, names: []const []const u8) !void {
    if (!self.agent.waitForIdle()) return error.SessionBusy;
    if (self.active_compaction_cancel_source != null) return error.SessionBusy;
    var active_set = try self.tools.buildActiveToolSet(self.allocator, names);
    defer active_set.deinit(self.allocator);
    const next_prompt = try self.buildPromptForActiveNames(active_set.names);
    errdefer self.allocator.free(next_prompt);

    try self.tools.ensureActiveCapacity(self.allocator, active_set.names.len);
    try self.agent.setTools(active_set.agent_tools);
    self.tools.commitActiveToolSet(active_set);
    self.agent.setSystemPrompt(next_prompt);
    self.allocator.free(self.system_prompt_text);
    self.system_prompt_text = next_prompt;
}

pub fn queueSnapshot(self: *const AgentSession, allocator: std.mem.Allocator) !session_events.QueueSnapshot {
    return self.queue_mirror.snapshot(allocator);
}

pub fn drainPublicEvent(self: *AgentSession) ?session_events.AgentSessionEvent {
    const event = self.public_events.pop() orelse return null;
    self.event_drain.enqueuePendingPublicEventOverflow();
    return event;
}

pub fn publicEventWake(self: *AgentSession) *runtime.ResetEvent {
    return &self.event_drain.public_event_wake;
}

test "agent session public event enqueue sets coalesced wake" {
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var session = try initTestSession(zio_runtime, tmp.dir);
    defer shutdownAndDeinit(&session);

    try std.testing.expect(!session.publicEventWake().isSet());

    session.event_drain.enqueuePublicEvent(.{ .agent_event = try session_events.OwnedAgentEvent.init(std.testing.allocator, .agent_start) });

    try std.testing.expect(session.publicEventWake().isSet());
    session.publicEventWake().reset();
    try std.testing.expect(!session.publicEventWake().isSet());

    var event = session.drainPublicEvent().?;
    defer event.deinit();
    try std.testing.expectEqual(agent_mod.AgentEvent.agent_start, event.agent_event.event);
}

fn ensureAcceptsPrompt(self: *AgentSession) Error!void {
    self.reconcileLifecycle();
    switch (self.lifecycle) {
        .accepting => {},
        .cancel_requested => return error.SessionCancelling,
        .shutdown_requested, .stopped => return error.SessionShuttingDown,
    }
    if (self.active_compaction_cancel_source != null) return error.SessionBusy;
}

fn ensureAcceptsIdleCommand(self: *AgentSession) Error!void {
    self.reconcileLifecycle();
    switch (self.lifecycle) {
        .accepting => {},
        .cancel_requested => return error.SessionCancelling,
        .shutdown_requested, .stopped => return error.SessionShuttingDown,
    }
    if (self.agent.state.isStreaming()) return error.SessionBusy;
    if (self.active_compaction_cancel_source != null) return error.SessionBusy;
}

fn applyManualCompaction(
    self: *AgentSession,
    reason: session_events.AgentSessionEvent.CompactionReason,
    will_retry: bool,
    summary: []const u8,
    first_kept_entry_id: []const u8,
    tokens_before: u64,
) !session_events.CompactionResult {
    try self.manager.ensureAppendCapacity(1);
    const entry = try self.manager.prepareCompactionEntry(
        summary,
        first_kept_entry_id,
        tokens_before,
        self.timestamp,
    );
    errdefer self.manager.deinitPreparedEntry(entry);

    if (self.store) |store| try store.appendEntry(self.allocator, self.io, entry);

    var event_result = try session_events.CompactionResult.init(self.allocator, entry.compaction);
    errdefer event_result.deinit();
    var return_result = try session_events.CompactionResult.init(self.allocator, entry.compaction);
    errdefer return_result.deinit();

    _ = self.manager.commitPreparedEntry(entry);

    const context = try self.manager.buildSessionContext(self.allocator);
    defer self.manager.deinitSessionContext(self.allocator, context);
    try self.agent.replaceMessages(context.messages);

    self.event_drain.enqueuePublicEvent(.{ .compaction_end = .{
        .reason = reason,
        .result = event_result,
        .aborted = false,
        .will_retry = will_retry,
    } });
    event_result = undefined;

    const result = return_result;
    return_result = undefined;
    return result;
}

fn applyManualCompactionRequest(
    self: *AgentSession,
    request: ManualCompactionRequest,
) !session_events.CompactionResult {
    return switch (request) {
        .explicit => |explicit| self.applyManualCompaction(
            .manual,
            false,
            explicit.summary,
            explicit.first_kept_entry_id,
            explicit.tokens_before,
        ),
        .prepared => |prepared| self.prepareAndApplyManualCompaction(
            prepared.summary,
            prepared.settings,
        ),
    };
}

fn prepareAndApplyManualCompaction(
    self: *AgentSession,
    summary: []const u8,
    settings: session_manager.CompactionSettings,
) !session_events.CompactionResult {
    var preparation = try self.manager.prepareCompaction(self.allocator, settings);
    defer preparation.deinit();
    return self.applyManualCompaction(
        .manual,
        false,
        summary,
        preparation.first_kept_entry_id,
        preparation.tokens_before,
    );
}

fn generateAndApplyCompaction(
    self: *AgentSession,
    reason: session_events.AgentSessionEvent.CompactionReason,
    will_retry: bool,
) !session_events.CompactionResult {
    var input = try self.manager.buildCompactionSummaryInput(self.allocator, self.compaction_settings);
    defer input.deinit();
    const serialized_input = try input.serialize(self.allocator);
    defer self.allocator.free(serialized_input);
    const summary = try self.generateCompactionSummary(serialized_input);
    defer self.allocator.free(summary);
    return self.applyManualCompaction(
        reason,
        will_retry,
        summary,
        input.first_kept_entry_id,
        input.tokens_before,
    );
}

fn generateCompactionSummary(self: *AgentSession, serialized_input: []const u8) ![]const u8 {
    const summary_prompt = try buildCompactionSummaryPrompt(self.allocator, serialized_input);
    defer self.allocator.free(summary_prompt);
    var messages = [_]ai.Message{.{ .user = .{
        .content = .{ .string = summary_prompt },
        .timestamp = 0,
    } }};

    var stream_options = self.agent.loop_config.options.stream;
    var owned_api_key: ?[]const u8 = null;
    defer if (owned_api_key) |api_key| self.allocator.free(api_key);
    if (self.agent.loop_config.get_api_key) |get_api_key| {
        if (try agent_mod.GetApiKeyHook.call(self.allocator, get_api_key, self.agent.state.model.provider)) |api_key| {
            owned_api_key = api_key;
            stream_options.api_key = api_key;
        }
    }

    var cancel_source = try runtime.CancelSource.init(self.allocator);
    defer cancel_source.deinit();
    std.debug.assert(self.active_compaction_cancel_source == null);
    self.active_compaction_cancel_source = &cancel_source;
    defer self.active_compaction_cancel_source = null;
    var response_arena = std.heap.ArenaAllocator.init(self.allocator);
    defer response_arena.deinit();
    var stream = self.agent.loop_config.stream.call(.{
        .allocator = response_arena.allocator(),
        .io = self.io,
        .zio_runtime = self.zio_runtime,
        .model = self.agent.state.model,
        .context = .{
            .system_prompt = null,
            .messages = &messages,
            .tools = &.{},
        },
        .options = stream_options,
        .cancel_token = cancel_source.token(),
    });
    defer stream.deinit();

    while (try stream.next(self.io)) |event| switch (event) {
        .@"error" => |payload| return extractCompactionSummary(self.allocator, payload.@"error"),
        else => {},
    };
    const result = stream.result() orelse return error.MissingCompactionSummary;
    return extractCompactionSummary(self.allocator, result);
}

fn buildCompactionSummaryPrompt(
    allocator: std.mem.Allocator,
    serialized_input: []const u8,
) ![]const u8 {
    const prefix =
        "Summarize the conversation for future continuation. Preserve user intent, decisions, files, " ++
        "tool outcomes, and unresolved work. Return only the summary.\n\n";
    const suffix = "\n";
    if (serialized_input.len > max_compaction_summary_prompt_bytes - prefix.len - suffix.len) {
        return error.CompactionSummaryPromptTooLarge;
    }
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ prefix, serialized_input, suffix });
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
        .text => |text| try appendGeneratedSummaryText(&writer, text.text),
        else => {},
    };
    if (writer.written().len == 0) return error.MissingCompactionSummary;
    return writer.toOwnedSlice();
}

fn appendGeneratedSummaryText(writer: *std.Io.Writer.Allocating, text: []const u8) !void {
    if (text.len > session_manager.max_compaction_summary_bytes or
        writer.written().len > session_manager.max_compaction_summary_bytes - text.len)
    {
        return error.CompactionSummaryTooLarge;
    }
    try writer.writer.writeAll(text);
}

fn reconcileLifecycle(self: *AgentSession) void {
    if (!self.agent.waitForIdle()) return;
    switch (self.lifecycle) {
        .cancel_requested => self.lifecycle = .accepting,
        .shutdown_requested => self.lifecycle = .stopped,
        .accepting, .stopped => {},
    }
}

fn buildPromptForActiveNames(self: *AgentSession, active_names: []const []const u8) ![]const u8 {
    return buildSystemPromptText(
        self.allocator,
        self.cwd,
        self.current_date,
        &self.prompt_resources,
        &self.tools,
        active_names,
    );
}

fn buildSystemPromptText(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    current_date: []const u8,
    prompt_resources: *const resources.PromptResources,
    tools: *const tool_registry.ToolRegistry,
    active_names: []const []const u8,
) ![]const u8 {
    var snippets = std.ArrayList(system_prompt.ToolSnippet).empty;
    defer snippets.deinit(allocator);
    var guidelines = std.ArrayList([]const u8).empty;
    defer guidelines.deinit(allocator);

    for (active_names) |name| {
        const definition = tools.findDefinition(name) orelse return error.UnknownToolName;
        if (definition.metadata.prompt_snippet) |snippet| {
            try snippets.append(allocator, .{ .name = definition.metadata.name, .snippet = snippet });
        }
        for (definition.metadata.prompt_guidelines) |guideline| {
            try guidelines.append(allocator, guideline);
        }
    }

    return system_prompt.build(allocator, .{
        .cwd = cwd,
        .current_date = current_date,
        .selected_tools = active_names,
        .tool_snippets = snippets.items,
        .prompt_guidelines = guidelines.items,
        .context_files = prompt_resources.context_files.files,
        .skills = prompt_resources.skills.skills,
        .custom_prompt = prompt_resources.systemPromptFileContent(),
        .append_system_prompt = prompt_resources.appendSystemPrompt(),
    });
}

const PromptPreflight = struct {
    text: []const u8,
    images: []const ai.ImageContent,
    streaming_behavior: ?StreamingBehavior,
};

fn preparePromptInput(
    _: *AgentSession,
    text: []const u8,
    images: []const ai.ImageContent,
    options: PromptOptions,
) PromptPreflight {
    return .{ .text = text, .images = images, .streaming_behavior = options.streaming_behavior };
}

fn tryHandlePromptCommand(self: *AgentSession, preflight: *const PromptPreflight) !bool {
    const parsed = prompt_command.parse(preflight.text) orelse return false;

    const command_name = parsed.name orelse {
        const unknown_message = try prompt_command.unknownText(self.allocator, parsed.text);
        errdefer self.allocator.free(unknown_message);
        try self.emitPromptCommandOwned(
            parsed.text,
            .unknown,
            session_events.EventText.initOwned(self.allocator, unknown_message),
        );
        return true;
    };

    switch (command_name) {
        .help => try self.emitPromptCommand(parsed.text, .handled, prompt_command.helpText()),
        .session => {
            const snapshot = self.statusSnapshot();
            const message = try prompt_command.sessionText(self.allocator, .{
                .status_name = @tagName(snapshot.status),
                .public_event_count = snapshot.public_event_count,
                .dropped_public_event_count = snapshot.dropped_public_event_count,
                .active_tool_count = self.tools.activeToolNames().len,
            });
            errdefer self.allocator.free(message);
            try self.emitPromptCommandOwned(
                parsed.text,
                .handled,
                session_events.EventText.initOwned(self.allocator, message),
            );
        },
    }
    return true;
}

fn emitPromptCommand(
    self: *AgentSession,
    command: []const u8,
    result: session_events.AgentSessionEvent.PromptCommandResult,
    message_text: []const u8,
) !void {
    var message = try session_events.EventText.init(self.allocator, message_text);
    errdefer message.deinit();
    try self.emitPromptCommandOwned(command, result, message);
}

fn emitPromptCommandOwned(
    self: *AgentSession,
    command: []const u8,
    result: session_events.AgentSessionEvent.PromptCommandResult,
    message: session_events.EventText,
) !void {
    var owned_message = message;
    errdefer owned_message.deinit();
    self.event_drain.enqueuePublicEvent(.{ .prompt_command = .{
        .command = try session_events.EventText.init(self.allocator, command),
        .result = result,
        .message = owned_message,
    } });
}

fn queuePromptIfStreaming(self: *AgentSession, preflight: *const PromptPreflight) !bool {
    if (!self.agent.state.isStreaming()) return false;
    const behavior = preflight.streaming_behavior orelse return error.StreamingBehaviorRequired;
    switch (behavior) {
        .steer => if (!self.agent.steering_queue.hasCapacity()) return error.QueueFull,
        .follow_up => if (!self.agent.follow_up_queue.hasCapacity()) return error.QueueFull,
    }

    const message = try self.constructUserMessage(preflight.text, preflight.images);
    switch (behavior) {
        .steer => try self.agent.steer(message),
        .follow_up => try self.agent.followUp(message),
    }
    switch (behavior) {
        .steer => try self.queue_mirror.appendSteering(self.allocator, preflight.text),
        .follow_up => try self.queue_mirror.appendFollowUp(self.allocator, preflight.text),
    }
    try self.event_drain.emitQueueUpdate();
    return true;
}

fn checkPrePromptCompaction(self: *AgentSession) !void {
    if (!self.compaction_settings.auto_enabled) return;
    var preparation = self.manager.prepareCompaction(
        self.allocator,
        self.compaction_settings,
    ) catch |err| switch (err) {
        error.NothingToCompact, error.AlreadyCompacted => return,
        else => return err,
    };
    preparation.deinit();
    var result = self.runGeneratedCompaction(.threshold, false) catch |err| switch (err) {
        error.NothingToCompact, error.AlreadyCompacted => return,
        else => return err,
    };
    result.deinit();
}

fn checkPostPromptOverflowCompaction(
    self: *AgentSession,
    previous_overflow_count: usize,
    will_retry: bool,
) !bool {
    if (!self.compaction_settings.auto_enabled) return false;
    if (self.event_drain.context_overflow_count <= previous_overflow_count) return false;
    var preparation = self.manager.prepareCompaction(
        self.allocator,
        self.compaction_settings,
    ) catch |err| switch (err) {
        error.NothingToCompact, error.AlreadyCompacted => return false,
        else => return err,
    };
    preparation.deinit();
    var result = self.runGeneratedCompaction(.overflow, will_retry) catch |err| switch (err) {
        error.NothingToCompact, error.AlreadyCompacted => return false,
        else => return err,
    };
    result.deinit();
    return true;
}

fn retryPromptAfterOverflowCompaction(
    self: *AgentSession,
    text: []const u8,
    images: []const ai.ImageContent,
    options: PromptOptions,
) anyerror!void {
    var error_message = try session_events.EventText.init(self.allocator, "context overflow");
    var retry_start_owns_error_message = true;
    errdefer if (retry_start_owns_error_message) error_message.deinit();
    self.event_drain.enqueuePublicEvent(.{ .auto_retry_start = .{
        .attempt = 1,
        .max_attempts = 1,
        .delay_ms = 0,
        .error_message = error_message,
    } });
    retry_start_owns_error_message = false;

    self.promptWithOptionsInternal(text, images, options, .{ .overflow = false, .transient = false }) catch |err| {
        const final_error = session_events.EventText.init(self.allocator, @errorName(err)) catch return err;
        self.event_drain.enqueuePublicEvent(.{ .auto_retry_end = .{
            .success = false,
            .attempt = 1,
            .final_error = final_error,
        } });
        return err;
    };

    self.event_drain.enqueuePublicEvent(.{ .auto_retry_end = .{
        .success = true,
        .attempt = 1,
    } });
}

fn retryPromptAfterRetryableError(
    self: *AgentSession,
    _: []const u8,
    _: []const ai.ImageContent,
    _: PromptOptions,
    source_error_message: []const u8,
) anyerror!void {
    if (!self.retry_settings.enabled or self.retry_settings.max_attempts == 0) return;
    var current_error_message = source_error_message;
    const max_attempts: usize = self.retry_settings.max_attempts;
    var attempt: usize = 1;
    while (attempt <= max_attempts) : (attempt += 1) {
        var error_message = try session_events.EventText.init(self.allocator, current_error_message);
        var retry_start_owns_error_message = true;
        errdefer if (retry_start_owns_error_message) error_message.deinit();
        self.event_drain.enqueuePublicEvent(.{ .auto_retry_start = .{
            .attempt = attempt,
            .max_attempts = max_attempts,
            .delay_ms = 0,
            .error_message = error_message,
        } });
        retry_start_owns_error_message = false;

        self.removeLastAssistantRuntimeMessage() catch |err| {
            try self.emitAutoRetryFailure(attempt, @errorName(err));
            return err;
        };

        self.agent.continueRun() catch |err| {
            try self.emitAutoRetryFailure(attempt, @errorName(err));
            return err;
        };

        if (self.latestAssistantError()) |next_error| {
            if (message_policy.isRetryableAssistantErrorText(next_error) and attempt < max_attempts) {
                current_error_message = next_error;
                continue;
            }
            try self.emitAutoRetryFailure(attempt, next_error);
            return;
        }

        self.event_drain.enqueuePublicEvent(.{ .auto_retry_end = .{
            .success = true,
            .attempt = attempt,
        } });
        return;
    }
}

fn latestRetryableAssistantError(self: *const AgentSession) ?[]const u8 {
    if (!self.retry_settings.enabled or self.retry_settings.max_attempts == 0) return null;
    if (self.agent.state.messages.len == 0) return null;
    const last = self.agent.state.messages[self.agent.state.messages.len - 1];
    if (last != .assistant) return null;
    if (!message_policy.isRetryableAssistant(last.assistant)) return null;
    return last.assistant.error_message;
}

fn latestAssistantError(self: *const AgentSession) ?[]const u8 {
    if (self.agent.state.messages.len == 0) return null;
    const last = self.agent.state.messages[self.agent.state.messages.len - 1];
    if (last != .assistant) return null;
    if (last.assistant.stop_reason != .error_) return null;
    return last.assistant.error_message orelse "assistant error";
}

fn emitAutoRetryFailure(self: *AgentSession, attempt: usize, message: []const u8) !void {
    const final_error = try session_events.EventText.init(self.allocator, message);
    self.event_drain.enqueuePublicEvent(.{ .auto_retry_end = .{
        .success = false,
        .attempt = attempt,
        .final_error = final_error,
    } });
}

fn removeLastAssistantRuntimeMessage(self: *AgentSession) !void {
    if (self.agent.state.messages.len == 0) return error.NoMessages;
    const retained_len = self.agent.state.messages.len - 1;
    const retained = try agent_mod.copyAgentMessages(self.allocator, self.agent.state.messages[0..retained_len]);
    defer deinitOwnedAgentMessages(self.allocator, retained);
    try self.agent.replaceMessages(retained);
}

fn deinitOwnedAgentMessages(allocator: std.mem.Allocator, messages: []const agent_mod.AgentMessage) void {
    for (messages) |message| agent_mod.deinitAgentMessage(allocator, message);
    allocator.free(messages);
}

fn constructUserMessage(
    self: *AgentSession,
    text: []const u8,
    images: []const ai.ImageContent,
) !agent_mod.AgentMessage {
    return self.agent.userMessageFromText(text, images);
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

test "agent session initializes policy spine with definition-first builtin tools" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "agent/AGENTS.md", .data = "global" });
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
    });
    defer shutdownAndDeinit(&session);

    try std.testing.expectEqual(@as(usize, tool_registry.builtin_tool_count), session.tools.definitions.items.len);
    try std.testing.expectEqual(@as(usize, tool_registry.builtin_tool_count), session.agent.state.tools.len);
    try std.testing.expectEqualStrings("read", session.tools.activeToolNames()[0]);
    try std.testing.expectEqualStrings("bash", session.tools.activeToolNames()[4]);
    try std.testing.expectEqualStrings("bash", session.agent.state.tools[4].name);
    try std.testing.expectEqual(agent_mod.ToolExecutionMode.sequential, session.agent.state.tools[4].execution_mode.?);
    try std.testing.expect(std.mem.indexOf(u8, session.system_prompt_text, "global") != null);
}

test "live prompt run uses explicit bounded event buffer" {
    try std.testing.expectEqual(@as(usize, 64), live_prompt_event_capacity_count);
    try std.testing.expectEqual(
        live_prompt_event_capacity_count,
        @typeInfo(@FieldType(LivePromptRun, "buffer")).array.len,
    );
}

test "agent session persists message_end through session event drain" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
    });
    defer shutdownAndDeinit(&session);

    _ = try session.agent.beginRun();
    try session.agent.emitEvent(.{ .message_end = .{ .message = .{ .user = .{
        .content = .{ .string = "hello" },
        .timestamp = 0,
    } } } });
    session.agent.finishRun();

    try std.testing.expectEqual(@as(usize, 1), session.manager.entries.items.len);
    drainAllPublicEvents(&session);
}

test "agent session cancel while running is observable until terminal event" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
    });
    defer shutdownAndDeinit(&session);

    _ = try session.agent.beginRun();
    try std.testing.expectEqual(AgentSessionStatus.running, session.status());

    session.cancel();

    try std.testing.expectEqual(AgentSessionStatus.cancel_requested, session.status());
    try std.testing.expect(session.agent.signal().?.isRequested());

    try session.agent.emitEvent(.{ .agent_end = .{ .messages = session.agent.state.messages } });
    session.agent.finishRun();

    try std.testing.expectEqual(AgentSessionStatus.idle, session.status());
    drainAllPublicEvents(&session);
}

test "agent session shutdown complete requires stopped idle and drained events" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
    });
    defer shutdownAndDeinit(&session);

    try std.testing.expect(!session.shutdownComplete());
    session.requestShutdown();
    try std.testing.expect(session.shutdownComplete());
}

test "agent session shutdown rejects new prompts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
    });
    defer shutdownAndDeinit(&session);

    session.requestShutdown();

    try std.testing.expectEqual(AgentSessionStatus.stopped, session.status());
    try std.testing.expectError(error.SessionShuttingDown, session.prompt("blocked", &.{}));
    try std.testing.expectError(error.SessionShuttingDown, session.continueRun());
}

test "agent session continue while running returns session busy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
    });
    defer shutdownAndDeinit(&session);

    _ = try session.agent.beginRun();
    defer session.agent.finishRun();

    try std.testing.expectError(error.SessionBusy, session.continueRun());
}

test "agent session shutdown while running stops after terminal event" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
    });
    defer shutdownAndDeinit(&session);

    _ = try session.agent.beginRun();
    session.requestShutdown();

    try std.testing.expectEqual(AgentSessionStatus.shutdown_requested, session.status());
    try std.testing.expect(session.agent.signal().?.isRequested());
    try std.testing.expectError(error.SessionShuttingDown, session.prompt("blocked", &.{}));

    try session.agent.emitEvent(.{ .agent_end = .{ .messages = session.agent.state.messages } });
    session.agent.finishRun();

    try std.testing.expectEqual(AgentSessionStatus.stopped, session.status());
    drainAllPublicEvents(&session);
}

test "agent session active tool changes rebuild prompt and agent tools" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
    });
    defer shutdownAndDeinit(&session);

    try session.setActiveToolsByName(&.{"read"});

    try std.testing.expectEqual(@as(usize, 1), session.agent.state.tools.len);
    try std.testing.expectEqualStrings("read", session.agent.state.tools[0].name);
    try std.testing.expect(std.mem.indexOf(u8, session.system_prompt_text, "- read:") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.system_prompt_text, "- edit:") == null);
}

test "agent session active tool change validates before mutation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
    });
    defer shutdownAndDeinit(&session);

    try session.setActiveToolsByName(&.{"read"});
    try std.testing.expectError(error.UnknownToolName, session.setActiveToolsByName(&.{ "edit", "missing" }));

    try std.testing.expectEqual(@as(usize, 1), session.agent.state.tools.len);
    try std.testing.expectEqualStrings("read", session.agent.state.tools[0].name);
    try std.testing.expectEqual(@as(usize, 1), session.tools.activeToolNames().len);
    try std.testing.expectEqualStrings("read", session.tools.activeToolNames()[0]);
}

test "agent session rejects active tool changes while running" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
    });
    defer shutdownAndDeinit(&session);

    _ = try session.agent.beginRun();
    defer session.agent.finishRun();

    try std.testing.expectError(error.SessionBusy, session.setActiveToolsByName(&.{"read"}));
}

test "agent session prompt uses preflight spine before agent submission" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
    });
    defer shutdownAndDeinit(&session);

    try session.prompt("hello", &.{});

    try std.testing.expectEqual(@as(usize, 2), session.manager.entries.items.len);
    try expectNextUserMessageEvent(.message_start, &session, "hello");
    drainAllPublicEvents(&session);
}

test "agent session prompt requires streaming behavior while running" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
    });
    defer shutdownAndDeinit(&session);

    _ = try session.agent.beginRun();
    defer session.agent.finishRun();

    try std.testing.expectError(error.StreamingBehaviorRequired, session.prompt("queued", &.{}));
    try std.testing.expect(!session.agent.hasQueuedMessages());
}

test "agent session slash command while running emits command event without queueing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var session = try initTestSession(zio_runtime, tmp.dir);
    defer shutdownAndDeinit(&session);

    _ = try session.agent.beginRun();
    defer session.agent.finishRun();

    try session.promptWithOptions("/help", &.{}, .{});

    try std.testing.expectEqual(@as(usize, 0), session.agent.steering_queue.count());
    try std.testing.expectEqual(@as(usize, 0), session.agent.follow_up_queue.count());
    try std.testing.expectEqual(@as(usize, 0), session.manager.entries.items.len);
    try expectNextPromptCommand(&session, .handled, "help", "available commands: /help, /session");
    try std.testing.expectEqual(@as(usize, 0), session.statusSnapshot().public_event_count);
}

test "agent session slash command public event overflow is bounded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var session = try initTestSessionWithCapacity(zio_runtime, tmp.dir, 1);
    defer shutdownAndDeinit(&session);

    try session.promptWithOptions("/help", &.{}, .{});
    try session.promptWithOptions("/session", &.{}, .{});

    try std.testing.expectEqual(@as(usize, 1), session.statusSnapshot().public_event_count);
    try std.testing.expectEqual(@as(usize, 1), session.statusSnapshot().dropped_public_event_count);
    try std.testing.expectEqual(@as(usize, 0), session.manager.entries.items.len);
    try expectNextPromptCommand(&session, .handled, "help", "available commands: /help, /session");
}

test "agent session prompt queues follow up while running" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
    });
    defer shutdownAndDeinit(&session);

    _ = try session.agent.beginRun();
    defer session.agent.finishRun();

    try session.promptWithOptions("queued", &.{}, .{ .streaming_behavior = .follow_up });

    try std.testing.expectEqual(@as(usize, 0), session.agent.steering_queue.count());
    try std.testing.expectEqual(@as(usize, 1), session.agent.follow_up_queue.count());
    var event = session.drainPublicEvent().?;
    defer event.deinit();
    const queue_update = event.queue_update;
    try std.testing.expectEqual(@as(usize, 0), queue_update.steering.items.len);
    try std.testing.expectEqual(@as(usize, 1), queue_update.follow_up.items.len);
    try std.testing.expectEqualStrings("queued", queue_update.follow_up.items[0]);
}

test "agent session prompt queues steering while running" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
    });
    defer shutdownAndDeinit(&session);

    _ = try session.agent.beginRun();
    defer session.agent.finishRun();

    try session.promptWithOptions("steer", &.{}, .{ .streaming_behavior = .steer });

    try std.testing.expectEqual(@as(usize, 1), session.agent.steering_queue.count());
    try std.testing.expectEqual(@as(usize, 0), session.agent.follow_up_queue.count());
    var event = session.drainPublicEvent().?;
    defer event.deinit();
    const queue_update = event.queue_update;
    try std.testing.expectEqual(@as(usize, 1), queue_update.steering.items.len);
    try std.testing.expectEqual(@as(usize, 0), queue_update.follow_up.items.len);
    try std.testing.expectEqualStrings("steer", queue_update.steering.items[0]);
}

test "agent session public events are caller drained after message persistence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
    });
    defer shutdownAndDeinit(&session);

    const message: agent_mod.AgentMessage = .{ .user = .{
        .content = .{ .string = "hello" },
        .timestamp = 0,
    } };

    _ = try session.agent.beginRun();
    try session.agent.emitEvent(.{ .message_start = .{ .message = message } });
    try session.agent.emitEvent(.{ .message_end = .{ .message = message } });
    session.agent.finishRun();

    try std.testing.expectEqual(@as(usize, 1), session.manager.entries.items.len);
    try std.testing.expectEqual(@as(usize, 2), session.statusSnapshot().public_event_count);
    var start_event = session.drainPublicEvent().?;
    defer start_event.deinit();
    try expectUserMessageEvent(.message_start, start_event.agent_event.event, "hello");
    var end_event = session.drainPublicEvent().?;
    defer end_event.deinit();
    try expectUserMessageEvent(.message_end, end_event.agent_event.event, "hello");
    try std.testing.expect(session.drainPublicEvent() == null);
}

test "agent session queue update carries revision and snapshot exposes queued text" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
    });
    defer shutdownAndDeinit(&session);

    _ = try session.agent.beginRun();
    defer session.agent.finishRun();
    try session.promptWithOptions("queued", &.{}, .{ .streaming_behavior = .follow_up });

    var event = session.drainPublicEvent().?;
    defer event.deinit();
    const queue_update = event.queue_update;
    try std.testing.expectEqual(@as(u64, 1), queue_update.revision);
    try std.testing.expectEqual(@as(usize, 0), queue_update.steering.items.len);
    try std.testing.expectEqual(@as(usize, 1), queue_update.follow_up.items.len);
    try std.testing.expectEqualStrings("queued", queue_update.follow_up.items[0]);
    var json_buffer: [128]u8 = undefined;
    var json_writer = std.Io.Writer.fixed(&json_buffer);
    try std.json.Stringify.value(event, .{}, &json_writer);
    try std.testing.expectEqualStrings(
        "{\"type\":\"queue_update\",\"steering\":[],\"followUp\":[\"queued\"],\"revision\":1}",
        json_writer.buffered(),
    );

    var snapshot = try session.queueSnapshot(std.testing.allocator);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(u64, 1), snapshot.revision);
    try std.testing.expectEqual(@as(usize, 0), snapshot.steering.items.len);
    try std.testing.expectEqual(@as(usize, 1), snapshot.follow_up.items.len);
    try std.testing.expectEqualStrings("queued", snapshot.follow_up.items[0]);
}

test "agent session queue update consumes block user message text" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
    });
    defer shutdownAndDeinit(&session);

    const image: ai.ImageContent = .{ .data = "abc", .mime_type = "image/png" };

    _ = try session.agent.beginRun();
    defer session.agent.finishRun();
    try session.promptWithOptions("queued image", &.{image}, .{ .streaming_behavior = .follow_up });

    var queued_event = session.drainPublicEvent().?;
    defer queued_event.deinit();
    const queued_update = queued_event.queue_update;
    try std.testing.expectEqual(@as(usize, 0), queued_update.steering.items.len);
    try std.testing.expectEqual(@as(usize, 1), queued_update.follow_up.items.len);
    try std.testing.expectEqualStrings("queued image", queued_update.follow_up.items[0]);

    const message = try session.agent.userMessageFromText("queued image", &.{image});
    try session.agent.emitEvent(.{ .message_start = .{ .message = message } });

    var consumed_event = session.drainPublicEvent().?;
    defer consumed_event.deinit();
    const consumed_update = consumed_event.queue_update;
    try std.testing.expectEqual(@as(usize, 0), consumed_update.steering.items.len);
    try std.testing.expectEqual(@as(usize, 0), consumed_update.follow_up.items.len);
    var message_event = session.drainPublicEvent().?;
    defer message_event.deinit();
    try expectUserMessageEvent(.message_start, message_event.agent_event.event, "queued image");
}

test "agent session queue update is emitted before queued user message start" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
    });
    defer shutdownAndDeinit(&session);

    _ = try session.agent.beginRun();
    defer session.agent.finishRun();
    try session.promptWithOptions("queued", &.{}, .{ .streaming_behavior = .steer });

    var queued_event = session.drainPublicEvent().?;
    defer queued_event.deinit();
    const queued_update = queued_event.queue_update;
    try std.testing.expectEqual(@as(usize, 1), queued_update.steering.items.len);
    try std.testing.expectEqual(@as(usize, 0), queued_update.follow_up.items.len);
    try std.testing.expectEqualStrings("queued", queued_update.steering.items[0]);

    const message = try session.agent.userMessageFromText("queued", &.{});
    try session.agent.emitEvent(.{ .message_start = .{ .message = message } });

    var consumed_event = session.drainPublicEvent().?;
    defer consumed_event.deinit();
    const consumed_update = consumed_event.queue_update;
    try std.testing.expectEqual(@as(usize, 0), consumed_update.steering.items.len);
    try std.testing.expectEqual(@as(usize, 0), consumed_update.follow_up.items.len);
    var message_event = session.drainPublicEvent().?;
    defer message_event.deinit();
    try expectUserMessageEvent(.message_start, message_event.agent_event.event, "queued");
}

test "agent session snapshots expose status and active tool read models" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
        .public_event_capacity = 1,
    });
    defer shutdownAndDeinit(&session);

    _ = try session.agent.beginRun();
    defer session.agent.finishRun();
    try session.agent.emitEvent(.agent_start);
    try session.agent.emitEvent(.agent_start);

    const status_snapshot = session.statusSnapshot();
    try std.testing.expectEqual(AgentSessionStatus.running, status_snapshot.status);
    try std.testing.expectEqual(@as(usize, 1), status_snapshot.public_event_count);
    try std.testing.expectEqual(@as(usize, 1), status_snapshot.dropped_public_event_count);

    try std.testing.expectEqual(@as(usize, tool_registry.builtin_tool_count), session.tools.activeToolNames().len);
}

test "agent session public event queue overflow is explicit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
        .public_event_capacity = 1,
    });
    defer shutdownAndDeinit(&session);

    const message: agent_mod.AgentMessage = .{ .user = .{
        .content = .{ .string = "overflow" },
        .timestamp = 0,
    } };

    _ = try session.agent.beginRun();
    defer session.agent.finishRun();
    try session.agent.emitEvent(.{ .message_start = .{ .message = message } });
    try session.agent.emitEvent(.agent_start);

    try std.testing.expectEqual(@as(usize, 1), session.statusSnapshot().public_event_count);
    try std.testing.expectEqual(@as(usize, 1), session.statusSnapshot().dropped_public_event_count);
    drainAllPublicEvents(&session);
}

test "agent session public event drain is caller driven" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
    });
    defer shutdownAndDeinit(&session);

    _ = try session.agent.beginRun();
    defer session.agent.finishRun();
    try session.agent.emitEvent(.agent_start);

    try std.testing.expectEqual(@as(usize, 1), session.statusSnapshot().public_event_count);
    var event = session.drainPublicEvent().?;
    event.deinit();
    try std.testing.expectEqual(@as(usize, 0), session.statusSnapshot().public_event_count);
}

test "agent session slash command emits public command event without model run" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var session = try initTestSession(zio_runtime, tmp.dir);
    defer shutdownAndDeinit(&session);

    try session.promptWithOptions("/missing arg", &.{}, .{});

    try std.testing.expectEqual(AgentSessionStatus.idle, session.status());
    try std.testing.expectEqual(@as(usize, 0), session.agent.state.messages.len);
    try std.testing.expectEqual(@as(usize, 0), session.manager.entries.items.len);
    try expectNextPromptCommand(&session, .unknown, "missing", "unknown command: /missing");
    try std.testing.expectEqual(@as(usize, 0), session.statusSnapshot().public_event_count);
}

test "agent session help command emits handled event without model run" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var session = try initTestSession(zio_runtime, tmp.dir);
    defer shutdownAndDeinit(&session);

    try session.promptWithOptions("/help", &.{}, .{});

    try std.testing.expectEqual(AgentSessionStatus.idle, session.status());
    try std.testing.expectEqual(@as(usize, 0), session.agent.state.messages.len);
    try std.testing.expectEqual(@as(usize, 0), session.manager.entries.items.len);
    try expectNextPromptCommand(&session, .handled, "help", "available commands: /help, /session");
    try std.testing.expectEqual(@as(usize, 0), session.statusSnapshot().public_event_count);
}

test "agent session session command emits snapshot without model run" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var session = try initTestSession(zio_runtime, tmp.dir);
    defer shutdownAndDeinit(&session);

    const expected_tools = session.tools.activeToolNames().len;
    try session.promptWithOptions("/session", &.{}, .{});

    try std.testing.expectEqual(AgentSessionStatus.idle, session.status());
    try std.testing.expectEqual(@as(usize, 0), session.agent.state.messages.len);
    try std.testing.expectEqual(@as(usize, 0), session.manager.entries.items.len);
    var event = session.drainPublicEvent().?;
    defer event.deinit();
    try std.testing.expect(event == .prompt_command);
    try std.testing.expectEqual(
        session_events.AgentSessionEvent.PromptCommandResult.handled,
        event.prompt_command.result,
    );
    try std.testing.expectEqualStrings("session", event.prompt_command.command.text);
    const expected_message = try std.fmt.allocPrint(
        std.testing.allocator,
        "session: idle; public events: 0; dropped events: 0; active tools: {}",
        .{expected_tools},
    );
    defer std.testing.allocator.free(expected_message);
    try std.testing.expectEqualStrings(expected_message, event.prompt_command.message.text);
    try std.testing.expectEqual(@as(usize, 0), session.statusSnapshot().public_event_count);
}

test "agent session manual compaction persists and replaces agent context" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    const store = try session_store.SessionStore.create(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "repo",
        "session",
        "2026-05-25T00:00:00Z",
    );
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
        .session_store = store,
    });
    defer shutdownAndDeinit(&session);

    _ = try session.agent.beginRun();
    try session.agent.emitEvent(.{ .message_end = .{ .message = .{ .user = .{
        .content = .{ .string = "dropped" },
        .timestamp = 0,
    } } } });
    try session.agent.emitEvent(.{ .message_end = .{ .message = .{ .user = .{
        .content = .{ .string = "kept" },
        .timestamp = 0,
    } } } });
    session.agent.finishRun();
    drainAllPublicEvents(&session);

    const kept = session.manager.entries.items[1].id();
    var result = try session.compactWithSummary("summary", kept, 2048);
    defer result.deinit();

    try std.testing.expectEqualStrings("summary", result.summary.text);
    try std.testing.expectEqualStrings(kept, result.first_kept_entry_id.text);
    try std.testing.expectEqual(@as(u64, 2048), result.tokens_before);
    try std.testing.expectEqual(@as(usize, 3), session.manager.entries.items.len);
    try std.testing.expect(session.manager.entries.items[2] == .compaction);
    try std.testing.expectEqual(@as(usize, 2), session.agent.state.messages.len);
    try std.testing.expect(std.mem.indexOf(u8, session.agent.state.messages[0].user.content.string, "summary") != null);
    try std.testing.expectEqualStrings("kept", session.agent.state.messages[1].user.content.string);

    var start_event = session.drainPublicEvent().?;
    defer start_event.deinit();
    try std.testing.expect(start_event == .compaction_start);
    try std.testing.expectEqual(
        session_events.AgentSessionEvent.CompactionReason.manual,
        start_event.compaction_start.reason,
    );

    var end_event = session.drainPublicEvent().?;
    defer end_event.deinit();
    try std.testing.expect(end_event == .compaction_end);
    try std.testing.expect(end_event.compaction_end.result != null);
    try std.testing.expectEqualStrings("summary", end_event.compaction_end.result.?.summary.text);
    try std.testing.expect(session.drainPublicEvent() == null);

    var loaded = try session.store.?.load(std.testing.allocator, std.testing.io);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 3), loaded.entries.items.len);
    try std.testing.expect(loaded.entries.items[2] == .compaction);
    try std.testing.expectEqualStrings("summary", loaded.entries.items[2].compaction.summary);
}

test "agent session prepared manual compaction owns cutpoint selection" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var session = try initTestSession(zio_runtime, tmp.dir);
    defer shutdownAndDeinit(&session);

    _ = try session.agent.beginRun();
    try session.agent.emitEvent(.{ .message_end = .{ .message = .{ .user = .{
        .content = .{ .string = "aaaaaaaa" },
        .timestamp = 0,
    } } } });
    try session.agent.emitEvent(.{ .message_end = .{ .message = .{ .user = .{
        .content = .{ .string = "bbbbbbbb" },
        .timestamp = 0,
    } } } });
    try session.agent.emitEvent(.{ .message_end = .{ .message = .{ .user = .{
        .content = .{ .string = "cccccccc" },
        .timestamp = 0,
    } } } });
    session.agent.finishRun();
    drainAllPublicEvents(&session);

    const kept = session.manager.entries.items[2].id();
    var result = try session.compactPreparedWithSummary("summary", .{ .keep_recent_tokens = 2 });
    defer result.deinit();

    try std.testing.expectEqualStrings(kept, result.first_kept_entry_id.text);
    try std.testing.expectEqual(@as(u64, 6), result.tokens_before);
    try std.testing.expectEqual(@as(usize, 4), session.manager.entries.items.len);
    try std.testing.expectEqualStrings(kept, session.manager.entries.items[3].compaction.first_kept_entry_id);

    var start_event = session.drainPublicEvent().?;
    defer start_event.deinit();
    try std.testing.expect(start_event == .compaction_start);
    var end_event = session.drainPublicEvent().?;
    defer end_event.deinit();
    try std.testing.expect(end_event == .compaction_end);
    try std.testing.expectEqualStrings(kept, end_event.compaction_end.result.?.first_kept_entry_id.text);
}

test "agent session prepared manual compaction uses session settings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
        .compaction_settings = .{ .keep_recent_tokens = 2 },
    });
    defer shutdownAndDeinit(&session);

    _ = try session.agent.beginRun();
    try session.agent.emitEvent(.{ .message_end = .{ .message = .{ .user = .{
        .content = .{ .string = "aaaaaaaa" },
        .timestamp = 0,
    } } } });
    try session.agent.emitEvent(.{ .message_end = .{ .message = .{ .user = .{
        .content = .{ .string = "bbbbbbbb" },
        .timestamp = 0,
    } } } });
    session.agent.finishRun();
    drainAllPublicEvents(&session);

    const kept = session.manager.entries.items[1].id();
    var result = try session.compactWithPreparedSummary("summary");
    defer result.deinit();

    try std.testing.expectEqualStrings(kept, result.first_kept_entry_id.text);
    try std.testing.expectEqual(@as(u64, 4), result.tokens_before);
}

test "agent session generated manual compaction summarizes and persists" {
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
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
        .model = provider.getModel(),
        .stream = provider.apiProvider().stream,
        .compaction_settings = .{ .keep_recent_tokens = 2 },
    });
    defer shutdownAndDeinit(&session);

    _ = try session.manager.appendMessage(.{ .user = .{
        .content = .{ .string = "aaaaaaaa" },
        .timestamp = 0,
    } }, "t1");
    const kept = try session.manager.appendMessage(.{ .user = .{
        .content = .{ .string = "bbbbbbbb" },
        .timestamp = 0,
    } }, "t2");

    var result = try session.compactWithGeneratedSummary();
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), provider.call_count);
    try std.testing.expectEqualStrings("generated summary", result.summary.text);
    try std.testing.expectEqualStrings(kept, result.first_kept_entry_id.text);
    try std.testing.expectEqualStrings("generated summary", session.manager.entries.items[2].compaction.summary);
    try std.testing.expect(std.mem.indexOf(
        u8,
        session.agent.state.messages[0].user.content.string,
        "generated summary",
    ) != null);

    var start_event = session.drainPublicEvent().?;
    defer start_event.deinit();
    try std.testing.expect(start_event == .compaction_start);
    var end_event = session.drainPublicEvent().?;
    defer end_event.deinit();
    try std.testing.expect(end_event == .compaction_end);
    try std.testing.expectEqualStrings("generated summary", end_event.compaction_end.result.?.summary.text);
}

test "agent session generated manual compaction failure does not mutate history" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var provider = try ai.FauxProvider.init(std.testing.allocator, .{});
    defer provider.deinit();
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
        .model = provider.getModel(),
        .stream = provider.apiProvider().stream,
        .compaction_settings = .{ .keep_recent_tokens = 2 },
    });
    defer shutdownAndDeinit(&session);

    _ = try session.manager.appendMessage(.{ .user = .{
        .content = .{ .string = "aaaaaaaa" },
        .timestamp = 0,
    } }, "t1");
    _ = try session.manager.appendMessage(.{ .user = .{
        .content = .{ .string = "bbbbbbbb" },
        .timestamp = 0,
    } }, "t2");

    try std.testing.expectError(error.CompactionSummaryGenerationFailed, session.compactWithGeneratedSummary());
    try std.testing.expectEqual(@as(usize, 2), session.manager.entries.items.len);
    try std.testing.expectEqual(@as(usize, 0), session.agent.state.messages.len);

    var start_event = session.drainPublicEvent().?;
    defer start_event.deinit();
    try std.testing.expect(start_event == .compaction_start);
    var end_event = session.drainPublicEvent().?;
    defer end_event.deinit();
    try std.testing.expect(end_event == .compaction_end);
    try std.testing.expect(end_event.compaction_end.result == null);
    try std.testing.expectEqualStrings(
        "CompactionSummaryGenerationFailed",
        end_event.compaction_end.error_message.?.text,
    );
}

test "agent session generated manual compaction oversized summary does not mutate history" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

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
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
        .model = provider.getModel(),
        .stream = provider.apiProvider().stream,
        .compaction_settings = .{ .keep_recent_tokens = 2 },
    });
    defer shutdownAndDeinit(&session);

    _ = try session.manager.appendMessage(.{ .user = .{
        .content = .{ .string = "aaaaaaaa" },
        .timestamp = 0,
    } }, "t1");
    _ = try session.manager.appendMessage(.{ .user = .{
        .content = .{ .string = "bbbbbbbb" },
        .timestamp = 0,
    } }, "t2");

    try std.testing.expectError(error.CompactionSummaryTooLarge, session.compactWithGeneratedSummary());
    try std.testing.expectEqual(@as(usize, 2), session.manager.entries.items.len);

    var start_event = session.drainPublicEvent().?;
    defer start_event.deinit();
    try std.testing.expect(start_event == .compaction_start);
    var end_event = session.drainPublicEvent().?;
    defer end_event.deinit();
    try std.testing.expect(end_event == .compaction_end);
    try std.testing.expect(end_event.compaction_end.result == null);
    try std.testing.expectEqualStrings("CompactionSummaryTooLarge", end_event.compaction_end.error_message.?.text);
}

test "agent session generated manual compaction cancellation is observable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var provider = try ai.FauxProvider.init(std.testing.allocator, .{});
    defer provider.deinit();
    var factory_state: CancelGeneratedCompactionFactory = .{};
    try provider.appendFactory(.{ .context = &factory_state, .call_fn = CancelGeneratedCompactionFactory.call });
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
        .model = provider.getModel(),
        .stream = provider.apiProvider().stream,
        .compaction_settings = .{ .keep_recent_tokens = 2 },
    });
    defer shutdownAndDeinit(&session);
    factory_state.session = &session;

    _ = try session.manager.appendMessage(.{ .user = .{
        .content = .{ .string = "aaaaaaaa" },
        .timestamp = 0,
    } }, "t1");
    _ = try session.manager.appendMessage(.{ .user = .{
        .content = .{ .string = "bbbbbbbb" },
        .timestamp = 0,
    } }, "t2");

    try std.testing.expectError(error.OperationCancelled, session.compactWithGeneratedSummary());
    try std.testing.expectEqual(@as(usize, 1), factory_state.call_count);
    try std.testing.expect(factory_state.observed_cancel_request);
    try std.testing.expectEqual(@as(usize, 2), session.manager.entries.items.len);
    try std.testing.expectEqual(AgentSessionStatus.idle, session.status());

    var start_event = session.drainPublicEvent().?;
    defer start_event.deinit();
    try std.testing.expect(start_event == .compaction_start);
    var end_event = session.drainPublicEvent().?;
    defer end_event.deinit();
    try std.testing.expect(end_event == .compaction_end);
    try std.testing.expect(end_event.compaction_end.aborted);
    try std.testing.expect(end_event.compaction_end.result == null);
    try std.testing.expectEqualStrings("OperationCancelled", end_event.compaction_end.error_message.?.text);
}

test "agent session auto compacts before prompt when enabled" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var provider = try ai.FauxProvider.init(std.testing.allocator, .{});
    defer provider.deinit();
    const summary_content = [_]ai.AssistantContent{ai.faux.text("generated summary")};
    const prompt_content = [_]ai.AssistantContent{ai.faux.text("prompt response")};
    const responses = [_]ai.AssistantMessage{
        ai.faux.assistantMessage(&summary_content, .{ .stop_reason = .stop }),
        ai.faux.assistantMessage(&prompt_content, .{ .stop_reason = .stop }),
    };
    try provider.setResponses(&responses);
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
        .model = provider.getModel(),
        .stream = provider.apiProvider().stream,
        .compaction_settings = .{ .keep_recent_tokens = 2 },
    });
    defer shutdownAndDeinit(&session);

    _ = try session.agent.beginRun();
    try session.agent.emitEvent(.{ .message_end = .{ .message = .{ .user = .{
        .content = .{ .string = "aaaaaaaa" },
        .timestamp = 0,
    } } } });
    try session.agent.emitEvent(.{ .message_end = .{ .message = .{ .user = .{
        .content = .{ .string = "bbbbbbbb" },
        .timestamp = 0,
    } } } });
    session.agent.finishRun();
    drainAllPublicEvents(&session);
    session.compaction_settings.auto_enabled = true;

    try session.prompt("next", &.{});

    try std.testing.expectEqual(@as(usize, 2), provider.call_count);
    try std.testing.expect(session.manager.entries.items[2] == .compaction);
    try std.testing.expectEqualStrings("generated summary", session.manager.entries.items[2].compaction.summary);

    var start_event = session.drainPublicEvent().?;
    defer start_event.deinit();
    try std.testing.expect(start_event == .compaction_start);
    try std.testing.expectEqual(
        session_events.AgentSessionEvent.CompactionReason.threshold,
        start_event.compaction_start.reason,
    );
    var end_event = session.drainPublicEvent().?;
    defer end_event.deinit();
    try std.testing.expect(end_event == .compaction_end);
    try std.testing.expectEqual(
        session_events.AgentSessionEvent.CompactionReason.threshold,
        end_event.compaction_end.reason,
    );
    try std.testing.expect(end_event.compaction_end.result != null);

    var agent_start = session.drainPublicEvent().?;
    defer agent_start.deinit();
    try std.testing.expect(agent_start == .agent_event);
    try std.testing.expect(agent_start.agent_event.event == .agent_start);
}

test "agent session auto compaction skips already compacted branch before prompt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var provider = try ai.FauxProvider.init(std.testing.allocator, .{});
    defer provider.deinit();
    const prompt_content = [_]ai.AssistantContent{ai.faux.text("prompt response")};
    const responses = [_]ai.AssistantMessage{
        ai.faux.assistantMessage(&prompt_content, .{ .stop_reason = .stop }),
    };
    try provider.setResponses(&responses);
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
        .model = provider.getModel(),
        .stream = provider.apiProvider().stream,
        .compaction_settings = .{ .keep_recent_tokens = 2, .auto_enabled = true },
    });
    defer shutdownAndDeinit(&session);

    const kept = try session.manager.appendMessage(.{ .user = .{
        .content = .{ .string = "aaaaaaaa" },
        .timestamp = 0,
    } }, "t1");
    _ = try session.manager.appendCompaction("summary", kept, 2, "t2");
    const context = try session.manager.buildSessionContext(std.testing.allocator);
    defer session.manager.deinitSessionContext(std.testing.allocator, context);
    try session.agent.replaceMessages(context.messages);

    try session.prompt("next", &.{});

    try std.testing.expectEqual(@as(usize, 1), provider.call_count);
    try std.testing.expectEqual(@as(usize, 4), session.manager.entries.items.len);
    var saw_agent_start = false;
    while (session.drainPublicEvent()) |event| {
        var owned_event = event;
        defer owned_event.deinit();
        try std.testing.expect(owned_event != .compaction_start);
        try std.testing.expect(owned_event != .compaction_end);
        if (owned_event == .agent_event and owned_event.agent_event.event == .agent_start) saw_agent_start = true;
    }
    try std.testing.expect(saw_agent_start);
}

test "agent session auto compacts after context overflow and retries once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var provider = try ai.FauxProvider.init(std.testing.allocator, .{});
    defer provider.deinit();
    const summary_content = [_]ai.AssistantContent{ai.faux.text("overflow summary")};
    const responses = [_]ai.AssistantMessage{
        ai.faux.assistantMessage(&.{}, .{
            .stop_reason = .error_,
            .error_message = "maximum context length exceeded",
        }),
        ai.faux.assistantMessage(&summary_content, .{ .stop_reason = .stop }),
        ai.faux.assistantMessage(&.{.{ .text = .{ .text = "retried response" } }}, .{ .stop_reason = .stop }),
    };
    try provider.setResponses(&responses);
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
        .model = provider.getModel(),
        .stream = provider.apiProvider().stream,
        .compaction_settings = .{ .keep_recent_tokens = 0, .auto_enabled = true },
    });
    defer shutdownAndDeinit(&session);

    try session.prompt("overflow request", &.{});

    try std.testing.expectEqual(@as(usize, 3), provider.call_count);
    try std.testing.expectEqual(@as(usize, 1), session.statusSnapshot().context_overflow_count);
    try std.testing.expectEqual(@as(usize, 5), session.manager.entries.items.len);
    try std.testing.expect(session.manager.entries.items[2] == .compaction);
    try std.testing.expectEqualStrings("overflow summary", session.manager.entries.items[2].compaction.summary);

    var saw_overflow_start = false;
    var saw_overflow_end = false;
    var saw_retry_start = false;
    var saw_retry_end = false;
    while (session.drainPublicEvent()) |event| {
        var owned_event = event;
        defer owned_event.deinit();
        if (owned_event == .compaction_start) {
            try std.testing.expectEqual(
                session_events.AgentSessionEvent.CompactionReason.overflow,
                owned_event.compaction_start.reason,
            );
            saw_overflow_start = true;
        }
        if (owned_event == .compaction_end) {
            try std.testing.expectEqual(
                session_events.AgentSessionEvent.CompactionReason.overflow,
                owned_event.compaction_end.reason,
            );
            try std.testing.expect(owned_event.compaction_end.will_retry);
            saw_overflow_end = true;
        }
        if (owned_event == .auto_retry_start) {
            try std.testing.expectEqual(@as(usize, 1), owned_event.auto_retry_start.attempt);
            try std.testing.expectEqual(@as(usize, 1), owned_event.auto_retry_start.max_attempts);
            saw_retry_start = true;
        }
        if (owned_event == .auto_retry_end) {
            try std.testing.expect(owned_event.auto_retry_end.success);
            try std.testing.expectEqual(@as(usize, 1), owned_event.auto_retry_end.attempt);
            saw_retry_end = true;
        }
    }
    try std.testing.expect(saw_overflow_start);
    try std.testing.expect(saw_overflow_end);
    try std.testing.expect(saw_retry_start);
    try std.testing.expect(saw_retry_end);
}

test "agent session overflow retry does not recurse on second overflow" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var provider = try ai.FauxProvider.init(std.testing.allocator, .{});
    defer provider.deinit();
    const summary_content = [_]ai.AssistantContent{ai.faux.text("overflow summary")};
    const responses = [_]ai.AssistantMessage{
        ai.faux.assistantMessage(&.{}, .{
            .stop_reason = .error_,
            .error_message = "maximum context length exceeded",
        }),
        ai.faux.assistantMessage(&summary_content, .{ .stop_reason = .stop }),
        ai.faux.assistantMessage(&.{}, .{
            .stop_reason = .error_,
            .error_message = "maximum context length exceeded",
        }),
    };
    try provider.setResponses(&responses);
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
        .model = provider.getModel(),
        .stream = provider.apiProvider().stream,
        .compaction_settings = .{ .keep_recent_tokens = 0, .auto_enabled = true },
    });
    defer shutdownAndDeinit(&session);

    try session.prompt("overflow request", &.{});

    try std.testing.expectEqual(@as(usize, 3), provider.call_count);
    try std.testing.expectEqual(@as(usize, 2), session.statusSnapshot().context_overflow_count);
    try std.testing.expectEqual(@as(usize, 5), session.manager.entries.items.len);

    var retry_start_count: usize = 0;
    var overflow_compaction_count: usize = 0;
    while (session.drainPublicEvent()) |event| {
        var owned_event = event;
        defer owned_event.deinit();
        if (owned_event == .auto_retry_start) retry_start_count += 1;
        if (owned_event == .compaction_end and owned_event.compaction_end.reason == .overflow) {
            overflow_compaction_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), retry_start_count);
    try std.testing.expectEqual(@as(usize, 1), overflow_compaction_count);
}

test "agent session retries transient assistant errors through continue" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var provider = try ai.FauxProvider.init(std.testing.allocator, .{});
    defer provider.deinit();
    const responses = [_]ai.AssistantMessage{
        ai.faux.assistantMessage(&.{}, .{
            .stop_reason = .error_,
            .error_message = "429 rate limit",
        }),
        ai.faux.assistantMessage(&.{.{ .text = .{ .text = "retried response" } }}, .{ .stop_reason = .stop }),
    };
    try provider.setResponses(&responses);
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
        .model = provider.getModel(),
        .stream = provider.apiProvider().stream,
        .retry_settings = .{ .enabled = true, .max_attempts = 1 },
    });
    defer shutdownAndDeinit(&session);

    try session.prompt("retry request", &.{});

    try std.testing.expectEqual(@as(usize, 2), provider.call_count);
    try std.testing.expectEqual(@as(usize, 3), session.manager.entries.items.len);
    try std.testing.expectEqual(@as(usize, 2), session.agent.state.messages.len);
    try std.testing.expect(session.agent.state.messages[1] == .assistant);
    try std.testing.expectEqual(.stop, session.agent.state.messages[1].assistant.stop_reason);

    var saw_retry_start = false;
    var saw_retry_end = false;
    while (session.drainPublicEvent()) |event| {
        var owned_event = event;
        defer owned_event.deinit();
        if (owned_event == .auto_retry_start) {
            try std.testing.expectEqual(@as(usize, 1), owned_event.auto_retry_start.attempt);
            try std.testing.expectEqual(@as(usize, 1), owned_event.auto_retry_start.max_attempts);
            try std.testing.expectEqualStrings("429 rate limit", owned_event.auto_retry_start.error_message.text);
            saw_retry_start = true;
        }
        if (owned_event == .auto_retry_end) {
            try std.testing.expect(owned_event.auto_retry_end.success);
            try std.testing.expectEqual(@as(usize, 1), owned_event.auto_retry_end.attempt);
            saw_retry_end = true;
        }
    }
    try std.testing.expect(saw_retry_start);
    try std.testing.expect(saw_retry_end);
}

test "agent session transient retry stops at bounded attempts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var provider = try ai.FauxProvider.init(std.testing.allocator, .{});
    defer provider.deinit();
    const responses = [_]ai.AssistantMessage{
        ai.faux.assistantMessage(&.{}, .{
            .stop_reason = .error_,
            .error_message = "server_error",
        }),
        ai.faux.assistantMessage(&.{}, .{
            .stop_reason = .error_,
            .error_message = "Network connection lost.",
        }),
    };
    try provider.setResponses(&responses);
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
        .model = provider.getModel(),
        .stream = provider.apiProvider().stream,
        .retry_settings = .{ .enabled = true, .max_attempts = 1 },
    });
    defer shutdownAndDeinit(&session);

    try session.prompt("retry request", &.{});

    try std.testing.expectEqual(@as(usize, 2), provider.call_count);
    try std.testing.expectEqual(@as(usize, 3), session.manager.entries.items.len);

    var retry_start_count: usize = 0;
    var saw_failed_retry_end = false;
    while (session.drainPublicEvent()) |event| {
        var owned_event = event;
        defer owned_event.deinit();
        if (owned_event == .auto_retry_start) retry_start_count += 1;
        if (owned_event == .auto_retry_end) {
            try std.testing.expect(!owned_event.auto_retry_end.success);
            try std.testing.expectEqualStrings(
                "Network connection lost.",
                owned_event.auto_retry_end.final_error.?.text,
            );
            saw_failed_retry_end = true;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), retry_start_count);
    try std.testing.expect(saw_failed_retry_end);
}

test "agent session prepared manual compaction emits failure event" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var session = try initTestSession(zio_runtime, tmp.dir);
    defer shutdownAndDeinit(&session);

    const root = try session.manager.appendMessage(.{ .user = .{
        .content = .{ .string = "aaaaaaaa" },
        .timestamp = 0,
    } }, "t1");
    _ = try session.manager.appendCompaction("summary", root, 2, "t2");
    try session.agent.replaceMessages(&.{});

    try std.testing.expectError(
        error.AlreadyCompacted,
        session.compactPreparedWithSummary("next", .{ .keep_recent_tokens = 1 }),
    );

    var start_event = session.drainPublicEvent().?;
    defer start_event.deinit();
    try std.testing.expect(start_event == .compaction_start);
    var end_event = session.drainPublicEvent().?;
    defer end_event.deinit();
    try std.testing.expect(end_event == .compaction_end);
    try std.testing.expect(end_event.compaction_end.result == null);
    try std.testing.expectEqualStrings("AlreadyCompacted", end_event.compaction_end.error_message.?.text);
}

test "agent session terminal policy runs after persistence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
    });
    defer shutdownAndDeinit(&session);

    const message: agent_mod.AgentMessage = .{ .user = .{
        .content = .{ .string = "hello" },
        .timestamp = 0,
    } };
    const overflow_message: agent_mod.AgentMessage = .{ .assistant = .{
        .content = &.{},
        .api = ai.KnownApi.openai_responses,
        .provider = ai.KnownProvider.openai,
        .model = "gpt",
        .usage = ai.protocol.emptyUsage(),
        .stop_reason = .error_,
        .error_message = "maximum context length exceeded",
        .timestamp = 0,
    } };

    _ = try session.agent.beginRun();
    try session.agent.emitEvent(.{ .message_end = .{ .message = message } });
    try session.agent.emitEvent(.{ .message_end = .{ .message = overflow_message } });
    session.agent.finishRun();

    try std.testing.expectEqual(@as(usize, 2), session.manager.entries.items.len);
    try std.testing.expectEqual(@as(usize, 1), session.statusSnapshot().context_overflow_count);
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
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
        .session_store = store,
    });
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
    try std.testing.expectEqual(@as(usize, 1), session.statusSnapshot().context_overflow_count);
    drainAllPublicEvents(&session);
}

test "agent session terminal policy classifies context overflow errors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var session = try initTestSession(zio_runtime, tmp.dir);
    defer shutdownAndDeinit(&session);

    _ = try session.agent.beginRun();
    try session.agent.emitEvent(.{ .message_end = .{ .message = .{ .assistant = .{
        .content = &.{},
        .api = ai.KnownApi.openai_responses,
        .provider = ai.KnownProvider.openai,
        .model = "gpt",
        .usage = ai.protocol.emptyUsage(),
        .stop_reason = .error_,
        .error_message = "maximum context length exceeded",
        .timestamp = 0,
    } } } });
    session.agent.finishRun();

    try std.testing.expectEqual(@as(usize, 1), session.statusSnapshot().context_overflow_count);
    try std.testing.expectEqual(@as(usize, 1), session.manager.entries.items.len);
    drainAllPublicEvents(&session);
}

test "agent session terminal policy ignores non context errors for overflow" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var session = try initTestSession(zio_runtime, tmp.dir);
    defer shutdownAndDeinit(&session);

    _ = try session.agent.beginRun();
    try session.agent.emitEvent(.{ .message_end = .{ .message = .{ .assistant = .{
        .content = &.{},
        .api = ai.KnownApi.openai_responses,
        .provider = ai.KnownProvider.openai,
        .model = "gpt",
        .usage = ai.protocol.emptyUsage(),
        .stop_reason = .error_,
        .error_message = "rate limit exceeded",
        .timestamp = 0,
    } } } });
    session.agent.finishRun();

    try std.testing.expectEqual(@as(usize, 0), session.statusSnapshot().context_overflow_count);
    drainAllPublicEvents(&session);
}

fn initTestSession(zio_runtime: *runtime.Runtime, dir: std.Io.Dir) !AgentSession {
    return initTestSessionWithCapacity(zio_runtime, dir, public_event_capacity_default);
}

const CancelGeneratedCompactionFactory = struct {
    session: ?*AgentSession = null,
    call_count: usize = 0,
    observed_cancel_request: bool = false,

    fn call(
        context: ?*anyopaque,
        request: ai.StreamRequest,
        _: *const ai.faux.State,
    ) ai.faux.FactoryError!ai.AssistantMessage {
        const self: *CancelGeneratedCompactionFactory = @ptrCast(@alignCast(context.?));
        self.call_count += 1;
        self.session.?.cancel();
        self.observed_cancel_request = request.cancel_token.?.isRequested();
        return ai.protocol.emptyAssistantMessageFromRequest(request, .aborted, "aborted");
    }
};

fn initTestSessionWithCapacity(
    zio_runtime: *runtime.Runtime,
    dir: std.Io.Dir,
    public_event_capacity: usize,
) !AgentSession {
    try dir.createDirPath(std.testing.io, "agent");
    try dir.createDirPath(std.testing.io, "repo");

    return AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .zio_runtime = zio_runtime,
        .dir = dir,
        .public_event_capacity = public_event_capacity,
    });
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
        owned_event.deinit();
    }
}

fn expectNextPromptCommand(
    session: *AgentSession,
    result: session_events.AgentSessionEvent.PromptCommandResult,
    command: []const u8,
    message: []const u8,
) !void {
    var event = session.drainPublicEvent().?;
    defer event.deinit();
    try std.testing.expect(event == .prompt_command);
    try std.testing.expectEqual(result, event.prompt_command.result);
    try std.testing.expectEqualStrings(command, event.prompt_command.command.text);
    try std.testing.expectEqualStrings(message, event.prompt_command.message.text);
}

fn expectNextUserMessageEvent(
    comptime tag: std.meta.Tag(agent_mod.AgentEvent),
    session: *AgentSession,
    text: []const u8,
) !void {
    while (session.drainPublicEvent()) |event| {
        var owned_event = event;
        defer owned_event.deinit();
        if (owned_event != .agent_event) continue;
        if (std.meta.activeTag(owned_event.agent_event.event) != tag) continue;
        try expectUserMessageEvent(tag, owned_event.agent_event.event, text);
        return;
    }
    return error.ExpectedUserMessageEvent;
}

fn expectUserMessageEvent(
    comptime tag: std.meta.Tag(agent_mod.AgentEvent),
    event: agent_mod.AgentEvent,
    text: []const u8,
) !void {
    try std.testing.expectEqual(tag, std.meta.activeTag(event));
    const message = switch (event) {
        .message_start => |payload| payload.message,
        .message_end => |payload| payload.message,
        else => unreachable,
    };
    try std.testing.expectEqual(.user, std.meta.activeTag(message));
    const user = message.user;
    try std.testing.expectEqualStrings(text, message_policy.userText(user).?);
}
