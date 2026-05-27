const std = @import("std");
const agent_mod = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const runtime = @import("../runtime/root.zig");
const resources = @import("resources.zig");
const session_manager = @import("session_manager.zig");
const system_prompt = @import("system_prompt.zig");
const tool_registry = @import("tool_registry.zig");

const AgentSession = @This();

pub const public_event_capacity_default = 256;

allocator: std.mem.Allocator,
io: std.Io,
cwd: []const u8,
current_date: []const u8,
timestamp: []const u8,
prompt_resources: resources.PromptResources,
system_prompt_state: SystemPromptState,
builtin_tools: tool_registry.OwnedBuiltinTools,
tools: tool_registry.ToolRegistry,
manager: *session_manager.SessionManager,
agent: *agent_mod.Agent,
public_event_buffer: []AgentSessionEvent,
public_events: *PublicEventQueue,
queue_mirror: *QueueMirror,
event_drain: *EventDrain,
lifecycle: Lifecycle = .accepting,

pub const Options = struct {
    cwd: []const u8,
    agent_dir: []const u8,
    current_date: []const u8,
    session_id: []const u8,
    timestamp: []const u8,
    model: ai.Model = agent_mod.Agent.defaultModel(),
    thinking_level: agent_mod.ThinkingLevel = .off,
    stream: ?ai.StreamFunction = null,
    dir: std.Io.Dir = .cwd(),
    allow_paths_outside_cwd: bool = false,
    public_event_capacity: usize = public_event_capacity_default,
};

pub const StreamingBehavior = enum {
    steer,
    follow_up,
};

pub const PromptOptions = struct {
    streaming_behavior: ?StreamingBehavior = null,
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
};

pub const ToolSnapshot = struct {
    active_count: usize,
};

pub const Error = error{
    SessionBusy,
    SessionCancelling,
    SessionShuttingDown,
};

pub const OwnedEventText = struct {
    allocator: std.mem.Allocator,
    text: []const u8,

    pub fn init(allocator: std.mem.Allocator, text: []const u8) !OwnedEventText {
        return .{ .allocator = allocator, .text = try allocator.dupe(u8, text) };
    }

    pub fn deinit(self: *OwnedEventText) void {
        self.allocator.free(self.text);
        self.* = undefined;
    }
};

const Lifecycle = enum {
    accepting,
    cancel_requested,
    shutdown_requested,
    stopped,
};

pub const AgentSessionEvent = union(enum) {
    agent_event: agent_mod.AgentEvent,
    queue_update: QueueUpdate,
    compaction_start: CompactionStart,
    session_info_changed: SessionInfoChanged,
    compaction_end: CompactionEnd,
    auto_retry_start: AutoRetryStart,
    auto_retry_end: AutoRetryEnd,

    pub const QueueUpdate = struct {
        steering_count: usize,
        follow_up_count: usize,
        revision: u64,
    };

    pub const CompactionReason = enum {
        manual,
        threshold,
        overflow,
    };

    pub const CompactionResult = struct {
        placeholder: void = {},
    };

    pub const CompactionStart = struct {
        reason: CompactionReason,
    };

    pub const SessionInfoChanged = struct {
        name: ?OwnedEventText,
    };

    pub const CompactionEnd = struct {
        reason: CompactionReason,
        result: ?CompactionResult,
        aborted: bool,
        will_retry: bool,
        error_message: ?OwnedEventText = null,
    };

    pub const AutoRetryStart = struct {
        attempt: usize,
        max_attempts: usize,
        delay_ms: u64,
        error_message: OwnedEventText,
    };

    pub const AutoRetryEnd = struct {
        success: bool,
        attempt: usize,
        final_error: ?OwnedEventText = null,
    };
};

pub const QueueSnapshot = struct {
    allocator: std.mem.Allocator,
    revision: u64,
    steering: []const []const u8,
    follow_up: []const []const u8,

    pub fn deinit(self: *QueueSnapshot) void {
        for (self.steering) |text| self.allocator.free(text);
        for (self.follow_up) |text| self.allocator.free(text);
        self.allocator.free(self.steering);
        self.allocator.free(self.follow_up);
        self.* = undefined;
    }
};

const QueueMirror = struct {
    steering: std.ArrayList([]const u8) = .empty,
    follow_up: std.ArrayList([]const u8) = .empty,
    revision: u64 = 0,

    fn deinit(self: *QueueMirror, allocator: std.mem.Allocator) void {
        self.clearList(allocator, &self.steering);
        self.clearList(allocator, &self.follow_up);
        self.steering.deinit(allocator);
        self.follow_up.deinit(allocator);
        self.* = undefined;
    }

    fn appendSteering(self: *QueueMirror, allocator: std.mem.Allocator, text: []const u8) !void {
        try self.append(allocator, &self.steering, text);
    }

    fn appendFollowUp(self: *QueueMirror, allocator: std.mem.Allocator, text: []const u8) !void {
        try self.append(allocator, &self.follow_up, text);
    }

    fn removeUserText(self: *QueueMirror, allocator: std.mem.Allocator, text: []const u8) bool {
        return self.remove(allocator, &self.steering, text) or self.remove(allocator, &self.follow_up, text);
    }

    fn removeSteeringText(self: *QueueMirror, allocator: std.mem.Allocator, text: []const u8) bool {
        return self.remove(allocator, &self.steering, text);
    }

    fn removeFollowUpText(self: *QueueMirror, allocator: std.mem.Allocator, text: []const u8) bool {
        return self.remove(allocator, &self.follow_up, text);
    }

    fn steeringCount(self: *const QueueMirror) usize {
        return self.steering.items.len;
    }

    fn followUpCount(self: *const QueueMirror) usize {
        return self.follow_up.items.len;
    }

    fn snapshot(self: *const QueueMirror, allocator: std.mem.Allocator) !QueueSnapshot {
        const steering = try cloneTextList(allocator, self.steering.items);
        errdefer freeTextList(allocator, steering);
        const follow_up = try cloneTextList(allocator, self.follow_up.items);
        errdefer freeTextList(allocator, follow_up);
        return .{
            .allocator = allocator,
            .revision = self.revision,
            .steering = steering,
            .follow_up = follow_up,
        };
    }

    fn append(
        self: *QueueMirror,
        allocator: std.mem.Allocator,
        list: *std.ArrayList([]const u8),
        text: []const u8,
    ) !void {
        const owned = try allocator.dupe(u8, text);
        errdefer allocator.free(owned);
        try list.append(allocator, owned);
        self.revision += 1;
    }

    fn remove(
        self: *QueueMirror,
        allocator: std.mem.Allocator,
        list: *std.ArrayList([]const u8),
        text: []const u8,
    ) bool {
        for (list.items, 0..) |queued, index| {
            if (!std.mem.eql(u8, queued, text)) continue;
            allocator.free(queued);
            const remaining = list.items.len - index - 1;
            if (remaining > 0) @memmove(list.items[index .. index + remaining], list.items[index + 1 ..]);
            list.shrinkRetainingCapacity(list.items.len - 1);
            self.revision += 1;
            return true;
        }
        return false;
    }

    fn clearList(_: *QueueMirror, allocator: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
        for (list.items) |text| allocator.free(text);
        list.clearRetainingCapacity();
    }

    fn cloneTextList(allocator: std.mem.Allocator, source: []const []const u8) ![]const []const u8 {
        const result = try allocator.alloc([]const u8, source.len);
        errdefer allocator.free(result);
        var initialized: usize = 0;
        errdefer for (result[0..initialized]) |owned| allocator.free(owned);
        for (source, 0..) |text, index| {
            result[index] = try allocator.dupe(u8, text);
            initialized += 1;
        }
        return result;
    }

    fn freeTextList(allocator: std.mem.Allocator, list: []const []const u8) void {
        for (list) |text| allocator.free(text);
        allocator.free(list);
    }
};

const PublicEventQueue = runtime.BoundedQueue(AgentSessionEvent);

const SystemPromptState = struct {
    text: []const u8,

    fn init(
        allocator: std.mem.Allocator,
        cwd: []const u8,
        current_date: []const u8,
        prompt_resources: *const resources.PromptResources,
        tools: *const tool_registry.ToolRegistry,
    ) !SystemPromptState {
        return .{ .text = try buildText(allocator, cwd, current_date, prompt_resources, tools) };
    }

    fn deinit(self: *SystemPromptState, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }

    fn replaceText(self: *SystemPromptState, allocator: std.mem.Allocator, text: []const u8) void {
        allocator.free(self.text);
        self.text = text;
    }

    fn buildText(
        allocator: std.mem.Allocator,
        cwd: []const u8,
        current_date: []const u8,
        prompt_resources: *const resources.PromptResources,
        tools: *const tool_registry.ToolRegistry,
    ) ![]const u8 {
        var snippets = std.ArrayList(system_prompt.ToolSnippet).empty;
        defer snippets.deinit(allocator);
        var guidelines = std.ArrayList([]const u8).empty;
        defer guidelines.deinit(allocator);

        for (tools.activeToolNames()) |name| {
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
            .selected_tools = tools.activeToolNames(),
            .tool_snippets = snippets.items,
            .prompt_guidelines = guidelines.items,
            .context_files = prompt_resources.context_files.files,
            .skills = prompt_resources.skills.skills,
            .custom_prompt = prompt_resources.customPrompt(),
            .append_system_prompt = prompt_resources.appendSystemPrompt(),
        });
    }
};

const EventDrain = struct {
    allocator: std.mem.Allocator,
    manager: *session_manager.SessionManager,
    queue_mirror: *QueueMirror,
    public_events: *PublicEventQueue,
    timestamp: []const u8,
    dropped_public_event_count: usize = 0,
    terminal_snapshot_entry_count: usize = 0,

    pub fn handle(self: *EventDrain, event: agent_mod.AgentEvent) !void {
        try self.updateQueueMirror(event);
        try self.runSessionHooks(event);
        try self.emitPublicEvent(event);
        // TODO(owner: coding_agent): When terminal policy can run for the same event as fallible persistence,
        // preserve the persistence error but still apply terminal policy before returning.
        try self.persistEvent(event);
        try self.handleTerminalPolicy(event);
    }

    fn updateQueueMirror(self: *EventDrain, event: agent_mod.AgentEvent) !void {
        if (event != .message_start) return;
        if (event.message_start.message != .user) return;
        const text = userMessageText(event.message_start.message.user) orelse return;
        if (!self.queue_mirror.removeUserText(self.allocator, text)) return;
        self.emitQueueUpdate();
    }

    fn runSessionHooks(_: *EventDrain, _: agent_mod.AgentEvent) !void {}

    fn emitPublicEvent(self: *EventDrain, event: agent_mod.AgentEvent) !void {
        self.enqueuePublicEvent(.{ .agent_event = event });
    }

    fn persistEvent(self: *EventDrain, event: agent_mod.AgentEvent) !void {
        if (event != .message_end) return;
        _ = try self.manager.appendMessage(event.message_end.message, self.timestamp);
    }

    fn handleTerminalPolicy(self: *EventDrain, event: agent_mod.AgentEvent) !void {
        if (event != .agent_end) return;
        self.terminal_snapshot_entry_count = self.manager.entries.items.len;
    }

    fn emitQueueUpdate(self: *EventDrain) void {
        self.enqueuePublicEvent(.{ .queue_update = .{
            .steering_count = self.queue_mirror.steeringCount(),
            .follow_up_count = self.queue_mirror.followUpCount(),
            .revision = self.queue_mirror.revision,
        } });
    }

    fn enqueuePublicEvent(self: *EventDrain, event: AgentSessionEvent) void {
        _ = self.public_events.pushOrDrop(event);
        self.dropped_public_event_count = self.public_events.dropped();
    }
};

pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) !AgentSession {
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

    var builtin_tools = try tool_registry.OwnedBuiltinTools.init(allocator, .{
        .cwd = options.cwd,
        .allow_paths_outside_cwd = options.allow_paths_outside_cwd,
    });
    errdefer builtin_tools.deinit();

    var tools: tool_registry.ToolRegistry = .{};
    errdefer tools.deinit(allocator);
    try builtin_tools.appendDefinitions(&tools);
    try tools.setActiveToolsByName(allocator, &.{ "read", "edit", "write" });

    var system_prompt_state = try SystemPromptState.init(
        allocator,
        options.cwd,
        options.current_date,
        &prompt_resources,
        &tools,
    );
    errdefer system_prompt_state.deinit(allocator);

    const manager = try allocator.create(session_manager.SessionManager);
    errdefer allocator.destroy(manager);
    manager.* = try session_manager.SessionManager.init(
        allocator,
        options.cwd,
        options.session_id,
        options.timestamp,
    );
    errdefer manager.deinit();

    var agent_options: agent_mod.Agent.Options = .{
        .system_prompt = system_prompt_state.text,
        .model = options.model,
        .thinking_level = options.thinking_level,
        .tools = tools.activeAgentTools(),
    };
    if (options.stream) |stream| agent_options.stream = stream;

    const core_agent = try allocator.create(agent_mod.Agent);
    errdefer allocator.destroy(core_agent);
    core_agent.* = try agent_mod.Agent.init(allocator, io, agent_options);
    errdefer core_agent.deinit();

    if (options.public_event_capacity == 0) return error.PublicEventCapacityZero;
    const public_event_buffer = try allocator.alloc(AgentSessionEvent, options.public_event_capacity);
    errdefer allocator.free(public_event_buffer);
    const public_events = try allocator.create(PublicEventQueue);
    errdefer allocator.destroy(public_events);
    public_events.* = PublicEventQueue.init(public_event_buffer);

    const queue_mirror = try allocator.create(QueueMirror);
    errdefer allocator.destroy(queue_mirror);
    queue_mirror.* = .{};
    errdefer queue_mirror.deinit(allocator);

    const event_drain = try allocator.create(EventDrain);
    errdefer allocator.destroy(event_drain);
    event_drain.* = .{
        .allocator = allocator,
        .manager = manager,
        .queue_mirror = queue_mirror,
        .public_events = public_events,
        .timestamp = timestamp,
    };

    _ = try core_agent.subscribe(.{ .context = event_drain, .call_fn = drainAgentEvent });

    return .{
        .allocator = allocator,
        .io = io,
        .cwd = cwd,
        .current_date = current_date,
        .timestamp = timestamp,
        .prompt_resources = prompt_resources,
        .system_prompt_state = system_prompt_state,
        .builtin_tools = builtin_tools,
        .tools = tools,
        .manager = manager,
        .agent = core_agent,
        .public_event_buffer = public_event_buffer,
        .public_events = public_events,
        .queue_mirror = queue_mirror,
        .event_drain = event_drain,
        .lifecycle = .accepting,
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
    self.manager.deinit();
    self.allocator.destroy(self.manager);
    self.tools.deinit(self.allocator);
    self.builtin_tools.deinit();
    self.system_prompt_state.deinit(self.allocator);
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
    try self.ensureAcceptsPrompt();
    var preflight = try self.preparePromptInput(text, images, options);
    defer preflight.deinit(self.allocator);
    if (try self.tryHandlePromptCommand(&preflight)) return;
    try self.runInputHooks(&preflight);
    try self.expandPromptResources(&preflight);
    if (try self.queuePromptIfStreaming(&preflight)) return;
    try self.flushPendingSessionMessages();
    try self.checkModelPreconditions();
    try self.checkPrePromptCompaction();
    try self.runBeforeAgentStartHooks(&preflight);
    const message = try self.constructUserMessage(preflight.text, preflight.images);
    try self.sendPreparedPrompt(&.{message});
}

pub fn continueRun(self: *AgentSession) !void {
    try self.ensureAcceptsContinue();
    try self.agent.continueRun();
}

pub fn cancel(self: *AgentSession) void {
    self.reconcileLifecycle();
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
        .accepting => if (self.agent.state.isStreaming()) .running else .idle,
    };
}

pub fn statusSnapshot(self: *AgentSession) RuntimeStatusSnapshot {
    return .{
        .status = self.status(),
        .public_event_count = self.public_events.count(),
        .dropped_public_event_count = self.public_events.dropped(),
    };
}

pub fn toolSnapshot(self: *const AgentSession) ToolSnapshot {
    return .{ .active_count = self.tools.activeToolNames().len };
}

pub fn shutdownComplete(self: *AgentSession) bool {
    self.reconcileLifecycle();
    return self.lifecycle == .stopped and
        self.agent.waitForIdle() and
        self.public_events.empty();
}

pub fn setActiveToolsByName(self: *AgentSession, names: []const []const u8) !void {
    if (!self.agent.waitForIdle()) return error.SessionBusy;
    var active_set = try self.tools.buildActiveToolSet(self.allocator, names);
    defer active_set.deinit(self.allocator);
    const next_prompt = try self.buildPromptForActiveNames(active_set.names);
    errdefer self.allocator.free(next_prompt);

    try self.tools.ensureActiveCapacity(self.allocator, active_set.names.len);
    try self.agent.setTools(active_set.agent_tools);
    self.tools.commitActiveToolSet(active_set);
    self.agent.setSystemPrompt(next_prompt);
    self.system_prompt_state.replaceText(self.allocator, next_prompt);
}

pub fn state(self: *const AgentSession) agent_mod.AgentState {
    return self.agent.state;
}

pub fn publicEventCount(self: *const AgentSession) usize {
    return self.public_events.count();
}

pub fn queueSnapshot(self: *const AgentSession, allocator: std.mem.Allocator) !QueueSnapshot {
    return self.queue_mirror.snapshot(allocator);
}

pub fn drainPublicEvent(self: *AgentSession) ?AgentSessionEvent {
    return self.public_events.pop();
}

pub fn activeToolNames(self: *const AgentSession) []const []const u8 {
    return self.tools.activeToolNames();
}

fn ensureAcceptsPrompt(self: *AgentSession) Error!void {
    self.reconcileLifecycle();
    switch (self.lifecycle) {
        .accepting => {},
        .cancel_requested => return error.SessionCancelling,
        .shutdown_requested, .stopped => return error.SessionShuttingDown,
    }
}

fn ensureAcceptsContinue(self: *AgentSession) Error!void {
    self.reconcileLifecycle();
    switch (self.lifecycle) {
        .accepting => {},
        .cancel_requested => return error.SessionCancelling,
        .shutdown_requested, .stopped => return error.SessionShuttingDown,
    }
    if (self.agent.state.isStreaming()) return error.SessionBusy;
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
    var snippets = std.ArrayList(system_prompt.ToolSnippet).empty;
    defer snippets.deinit(self.allocator);
    var guidelines = std.ArrayList([]const u8).empty;
    defer guidelines.deinit(self.allocator);

    for (active_names) |name| {
        const definition = self.tools.findDefinition(name) orelse return error.UnknownToolName;
        if (definition.metadata.prompt_snippet) |snippet| {
            try snippets.append(self.allocator, .{ .name = definition.metadata.name, .snippet = snippet });
        }
        for (definition.metadata.prompt_guidelines) |guideline| {
            try guidelines.append(self.allocator, guideline);
        }
    }

    return system_prompt.build(self.allocator, .{
        .cwd = self.cwd,
        .current_date = self.current_date,
        .selected_tools = active_names,
        .tool_snippets = snippets.items,
        .prompt_guidelines = guidelines.items,
        .context_files = self.prompt_resources.context_files.files,
        .skills = self.prompt_resources.skills.skills,
        .custom_prompt = self.prompt_resources.customPrompt(),
        .append_system_prompt = self.prompt_resources.appendSystemPrompt(),
    });
}

const PromptPreflight = struct {
    text: []const u8,
    images: []const ai.ImageContent,
    streaming_behavior: ?StreamingBehavior,

    fn deinit(self: *PromptPreflight, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

fn preparePromptInput(
    self: *AgentSession,
    text: []const u8,
    images: []const ai.ImageContent,
    options: PromptOptions,
) !PromptPreflight {
    return .{
        .text = try self.allocator.dupe(u8, text),
        .images = images,
        .streaming_behavior = options.streaming_behavior,
    };
}

fn tryHandlePromptCommand(_: *AgentSession, _: *const PromptPreflight) !bool {
    return false;
}

fn runInputHooks(_: *AgentSession, _: *const PromptPreflight) !void {}

fn expandPromptResources(_: *AgentSession, _: *PromptPreflight) !void {}

fn queuePromptIfStreaming(self: *AgentSession, preflight: *const PromptPreflight) !bool {
    if (!self.agent.state.isStreaming()) return false;
    const behavior = preflight.streaming_behavior orelse return error.StreamingBehaviorRequired;
    switch (behavior) {
        .steer => if (!self.agent.steering_queue.hasCapacity()) return error.QueueFull,
        .follow_up => if (!self.agent.follow_up_queue.hasCapacity()) return error.QueueFull,
    }
    switch (behavior) {
        .steer => try self.queue_mirror.appendSteering(self.allocator, preflight.text),
        .follow_up => try self.queue_mirror.appendFollowUp(self.allocator, preflight.text),
    }
    errdefer self.rollbackQueuedPrompt(behavior, preflight.text);
    self.event_drain.emitQueueUpdate();
    const message = try self.constructUserMessage(preflight.text, preflight.images);
    switch (behavior) {
        .steer => try self.agent.steer(message),
        .follow_up => try self.agent.followUp(message),
    }
    return true;
}

fn flushPendingSessionMessages(_: *AgentSession) !void {}

fn checkModelPreconditions(_: *AgentSession) !void {}

fn checkPrePromptCompaction(_: *AgentSession) !void {}

fn constructUserMessage(
    self: *AgentSession,
    text: []const u8,
    images: []const ai.ImageContent,
) !agent_mod.AgentMessage {
    return self.agent.userMessageFromText(text, images);
}

fn rollbackQueuedPrompt(self: *AgentSession, behavior: StreamingBehavior, text: []const u8) void {
    switch (behavior) {
        .steer => _ = self.queue_mirror.removeSteeringText(self.allocator, text),
        .follow_up => _ = self.queue_mirror.removeFollowUpText(self.allocator, text),
    }
    self.event_drain.emitQueueUpdate();
}

fn userMessageText(message: ai.UserMessage) ?[]const u8 {
    return switch (message.content) {
        .string => |text| text,
        .blocks => |blocks| for (blocks) |block| {
            if (block == .text) break block.text.text;
        } else null,
    };
}

fn runBeforeAgentStartHooks(_: *AgentSession, _: *const PromptPreflight) !void {}

fn sendPreparedPrompt(self: *AgentSession, messages: []const agent_mod.AgentMessage) !void {
    try self.agent.promptMessages(messages);
}

fn drainAgentEvent(
    _: std.Io,
    context: ?*anyopaque,
    event: agent_mod.AgentEvent,
    _: runtime.CancelToken,
) anyerror!void {
    const drain: *EventDrain = @ptrCast(@alignCast(context.?));
    try drain.handle(event);
}

test "agent session initializes policy spine with definition-first builtin tools" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "agent/AGENTS.md", .data = "global" });

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .dir = tmp.dir,
    });
    defer shutdownAndDeinit(&session);

    try std.testing.expectEqual(@as(usize, tool_registry.builtin_tool_count), session.tools.definitions.items.len);
    try std.testing.expectEqual(@as(usize, tool_registry.builtin_tool_count), session.agent.state.tools.len);
    try std.testing.expectEqualStrings("read", session.activeToolNames()[0]);
    try std.testing.expect(std.mem.indexOf(u8, session.system_prompt_state.text, "global") != null);
}

test "agent session persists message_end through session event drain" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
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

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
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

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
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

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
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

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
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

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
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

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .dir = tmp.dir,
    });
    defer shutdownAndDeinit(&session);

    try session.setActiveToolsByName(&.{"read"});

    try std.testing.expectEqual(@as(usize, 1), session.agent.state.tools.len);
    try std.testing.expectEqualStrings("read", session.agent.state.tools[0].name);
    try std.testing.expect(std.mem.indexOf(u8, session.system_prompt_state.text, "- read:") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.system_prompt_state.text, "- edit:") == null);
}

test "agent session active tool change validates before mutation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .dir = tmp.dir,
    });
    defer shutdownAndDeinit(&session);

    try session.setActiveToolsByName(&.{"read"});
    try std.testing.expectError(error.UnknownToolName, session.setActiveToolsByName(&.{ "edit", "missing" }));

    try std.testing.expectEqual(@as(usize, 1), session.agent.state.tools.len);
    try std.testing.expectEqualStrings("read", session.agent.state.tools[0].name);
    try std.testing.expectEqual(@as(usize, 1), session.activeToolNames().len);
    try std.testing.expectEqualStrings("read", session.activeToolNames()[0]);
}

test "agent session rejects active tool changes while running" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
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

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
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

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .dir = tmp.dir,
    });
    defer shutdownAndDeinit(&session);

    _ = try session.agent.beginRun();
    defer session.agent.finishRun();

    try std.testing.expectError(error.StreamingBehaviorRequired, session.prompt("queued", &.{}));
    try std.testing.expect(!session.agent.hasQueuedMessages());
}

test "agent session prompt queues follow up while running" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .dir = tmp.dir,
    });
    defer shutdownAndDeinit(&session);

    _ = try session.agent.beginRun();
    defer session.agent.finishRun();

    try session.promptWithOptions("queued", &.{}, .{ .streaming_behavior = .follow_up });

    try std.testing.expectEqual(@as(usize, 0), session.agent.steering_queue.count());
    try std.testing.expectEqual(@as(usize, 1), session.agent.follow_up_queue.count());
    const queue_update = session.drainPublicEvent().?.queue_update;
    try std.testing.expectEqual(@as(usize, 0), queue_update.steering_count);
    try std.testing.expectEqual(@as(usize, 1), queue_update.follow_up_count);
}

test "agent session prompt queues steering while running" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .dir = tmp.dir,
    });
    defer shutdownAndDeinit(&session);

    _ = try session.agent.beginRun();
    defer session.agent.finishRun();

    try session.promptWithOptions("steer", &.{}, .{ .streaming_behavior = .steer });

    try std.testing.expectEqual(@as(usize, 1), session.agent.steering_queue.count());
    try std.testing.expectEqual(@as(usize, 0), session.agent.follow_up_queue.count());
    const queue_update = session.drainPublicEvent().?.queue_update;
    try std.testing.expectEqual(@as(usize, 1), queue_update.steering_count);
    try std.testing.expectEqual(@as(usize, 0), queue_update.follow_up_count);
}

test "agent session public events are caller drained after message persistence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
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
    try std.testing.expectEqual(@as(usize, 2), session.publicEventCount());
    try expectUserMessageEvent(.message_start, session.drainPublicEvent().?.agent_event, "hello");
    try expectUserMessageEvent(.message_end, session.drainPublicEvent().?.agent_event, "hello");
    try std.testing.expect(session.drainPublicEvent() == null);
}

test "agent session queue update carries revision and snapshot exposes queued text" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .dir = tmp.dir,
    });
    defer shutdownAndDeinit(&session);

    _ = try session.agent.beginRun();
    defer session.agent.finishRun();
    try session.promptWithOptions("queued", &.{}, .{ .streaming_behavior = .follow_up });

    const queue_update = session.drainPublicEvent().?.queue_update;
    try std.testing.expectEqual(@as(u64, 1), queue_update.revision);

    var snapshot = try session.queueSnapshot(std.testing.allocator);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(u64, 1), snapshot.revision);
    try std.testing.expectEqual(@as(usize, 0), snapshot.steering.len);
    try std.testing.expectEqual(@as(usize, 1), snapshot.follow_up.len);
    try std.testing.expectEqualStrings("queued", snapshot.follow_up[0]);
}

test "agent session queue update consumes block user message text" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .dir = tmp.dir,
    });
    defer shutdownAndDeinit(&session);

    const image: ai.ImageContent = .{ .data = "abc", .mime_type = "image/png" };

    _ = try session.agent.beginRun();
    defer session.agent.finishRun();
    try session.promptWithOptions("queued image", &.{image}, .{ .streaming_behavior = .follow_up });

    const queued_update = session.drainPublicEvent().?.queue_update;
    try std.testing.expectEqual(@as(usize, 0), queued_update.steering_count);
    try std.testing.expectEqual(@as(usize, 1), queued_update.follow_up_count);

    const message = try session.agent.userMessageFromText("queued image", &.{image});
    try session.agent.emitEvent(.{ .message_start = .{ .message = message } });

    const consumed_update = session.drainPublicEvent().?.queue_update;
    try std.testing.expectEqual(@as(usize, 0), consumed_update.steering_count);
    try std.testing.expectEqual(@as(usize, 0), consumed_update.follow_up_count);
    try expectUserMessageEvent(.message_start, session.drainPublicEvent().?.agent_event, "queued image");
}

test "agent session queue update is emitted before queued user message start" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .dir = tmp.dir,
    });
    defer shutdownAndDeinit(&session);

    _ = try session.agent.beginRun();
    defer session.agent.finishRun();
    try session.promptWithOptions("queued", &.{}, .{ .streaming_behavior = .steer });

    const queued_update = session.drainPublicEvent().?.queue_update;
    try std.testing.expectEqual(@as(usize, 1), queued_update.steering_count);
    try std.testing.expectEqual(@as(usize, 0), queued_update.follow_up_count);

    const message = try session.agent.userMessageFromText("queued", &.{});
    try session.agent.emitEvent(.{ .message_start = .{ .message = message } });

    const consumed_update = session.drainPublicEvent().?.queue_update;
    try std.testing.expectEqual(@as(usize, 0), consumed_update.steering_count);
    try std.testing.expectEqual(@as(usize, 0), consumed_update.follow_up_count);
    try expectUserMessageEvent(.message_start, session.drainPublicEvent().?.agent_event, "queued");
}

test "agent session snapshots expose status and active tool read models" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
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

    const tool_snapshot = session.toolSnapshot();
    try std.testing.expectEqual(@as(usize, tool_registry.builtin_tool_count), tool_snapshot.active_count);
}

test "agent session public event queue overflow is explicit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
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

    try std.testing.expectEqual(@as(usize, 1), session.publicEventCount());
    try std.testing.expectEqual(@as(usize, 1), session.event_drain.dropped_public_event_count);
    drainAllPublicEvents(&session);
}

test "agent session public event drain is caller driven" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .dir = tmp.dir,
    });
    defer shutdownAndDeinit(&session);

    _ = try session.agent.beginRun();
    defer session.agent.finishRun();
    try session.agent.emitEvent(.agent_start);

    try std.testing.expectEqual(@as(usize, 1), session.publicEventCount());
    _ = session.drainPublicEvent().?;
    try std.testing.expectEqual(@as(usize, 0), session.publicEventCount());
}

test "agent session terminal policy runs after persistence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .dir = tmp.dir,
    });
    defer shutdownAndDeinit(&session);

    const message: agent_mod.AgentMessage = .{ .user = .{
        .content = .{ .string = "hello" },
        .timestamp = 0,
    } };

    _ = try session.agent.beginRun();
    try session.agent.emitEvent(.{ .message_end = .{ .message = message } });
    try session.agent.emitEvent(.{ .agent_end = .{ .messages = session.agent.state.messages } });
    session.agent.finishRun();

    try std.testing.expectEqual(@as(usize, 1), session.event_drain.terminal_snapshot_entry_count);
    drainAllPublicEvents(&session);
}

fn shutdownAndDeinit(session: *AgentSession) void {
    if (!session.agent.waitForIdle()) session.agent.finishRun();
    session.requestShutdown();
    drainAllPublicEvents(session);
    session.deinit();
}

fn drainAllPublicEvents(session: *AgentSession) void {
    while (session.drainPublicEvent() != null) {}
}

fn expectNextUserMessageEvent(
    comptime tag: std.meta.Tag(agent_mod.AgentEvent),
    session: *AgentSession,
    text: []const u8,
) !void {
    while (session.drainPublicEvent()) |event| {
        if (event != .agent_event) continue;
        if (std.meta.activeTag(event.agent_event) != tag) continue;
        try expectUserMessageEvent(tag, event.agent_event, text);
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
    try std.testing.expectEqualStrings(text, userMessageText(user).?);
}
