const std = @import("std");
const agent_mod = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const runtime = @import("../runtime/root.zig");
const resources = @import("resources.zig");
const session_manager = @import("session_manager.zig");
const session_store = @import("session_store.zig");
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
builtin_tools: tool_registry.BuiltinTools,
tools: tool_registry.ToolRegistry,
manager: *session_manager.SessionManager,
store: ?*session_store.SessionStore = null,
agent: *agent_mod.Agent,
public_event_buffer: []AgentSessionEvent,
public_events: *PublicEventQueue,
queue_mirror: *QueueMirror,
event_drain: *EventDrain,
lifecycle: Lifecycle = .accepting,
compaction_settings: session_manager.CompactionSettings = .{},

pub const Options = struct {
    cwd: []const u8,
    agent_dir: []const u8,
    current_date: []const u8,
    session_id: []const u8,
    timestamp: []const u8,
    model: ai.Model = agent_mod.Agent.defaultModel(),
    thinking_level: agent_mod.ThinkingLevel = .off,
    compaction_settings: session_manager.CompactionSettings = .{},
    stream: ?ai.StreamFunction = null,
    get_api_key: ?agent_mod.GetApiKeyHook = null,
    dir: std.Io.Dir = .cwd(),
    allow_paths_outside_cwd: bool = false,
    public_event_capacity: usize = public_event_capacity_default,
    session_store: ?session_store.SessionStore = null,
    resume_session_store: ?session_store.SessionStore = null,
};

pub const StreamingBehavior = enum {
    steer,
    follow_up,
};

pub const PromptOptions = struct {
    streaming_behavior: ?StreamingBehavior = null,
};

const PromptCommandName = enum {
    help,
    session,
};

const prompt_commands: []const PromptCommandName = &.{ .help, .session };

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
    buffer: [64]agent_mod.AgentEvent = undefined,
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
};

pub const ToolSnapshot = struct {
    active_count: usize,
};

pub const Error = error{
    SessionBusy,
    SessionCancelling,
    SessionShuttingDown,
    CompactionEntryNotInBranch,
};

pub const EventText = struct {
    allocator: std.mem.Allocator,
    text: []const u8,

    pub fn init(allocator: std.mem.Allocator, text: []const u8) !EventText {
        return .{ .allocator = allocator, .text = try allocator.dupe(u8, text) };
    }

    fn initOwned(allocator: std.mem.Allocator, text: []const u8) EventText {
        return .{ .allocator = allocator, .text = text };
    }

    pub fn deinit(self: *EventText) void {
        self.allocator.free(self.text);
        self.* = undefined;
    }

    pub fn jsonStringify(self: EventText, stringify: *std.json.Stringify) !void {
        try stringify.write(self.text);
    }
};

pub const EventTextList = struct {
    allocator: std.mem.Allocator,
    items: []const []const u8,

    pub fn init(allocator: std.mem.Allocator, source: []const []const u8) !EventTextList {
        const items = try allocator.alloc([]const u8, source.len);
        errdefer allocator.free(items);
        var initialized: usize = 0;
        errdefer {
            for (items[0..initialized]) |item| allocator.free(item);
        }
        for (source) |text| {
            items[initialized] = try allocator.dupe(u8, text);
            initialized += 1;
        }
        return .{ .allocator = allocator, .items = items };
    }

    pub fn deinit(self: *EventTextList) void {
        for (self.items) |item| self.allocator.free(item);
        self.allocator.free(self.items);
        self.* = undefined;
    }

    pub fn jsonStringify(self: EventTextList, stringify: *std.json.Stringify) !void {
        try stringify.beginArray();
        for (self.items) |item| try stringify.write(item);
        try stringify.endArray();
    }
};

pub const CompactionResult = struct {
    summary: EventText,
    first_kept_entry_id: EventText,
    tokens_before: u64,

    pub fn init(
        allocator: std.mem.Allocator,
        entry: session_manager.SessionEntry.Compaction,
    ) !CompactionResult {
        return .{
            .summary = try EventText.init(allocator, entry.summary),
            .first_kept_entry_id = try EventText.init(allocator, entry.first_kept_entry_id),
            .tokens_before = entry.tokens_before,
        };
    }

    pub fn deinit(self: *CompactionResult) void {
        self.summary.deinit();
        self.first_kept_entry_id.deinit();
        self.* = undefined;
    }

    pub fn jsonStringify(self: CompactionResult, stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try writeJsonField("summary", stringify, self.summary);
        try writeJsonField("firstKeptEntryId", stringify, self.first_kept_entry_id);
        try writeJsonField("tokensBefore", stringify, self.tokens_before);
        try stringify.endObject();
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
    prompt_command: PromptCommand,
    compaction_start: CompactionStart,
    session_info_changed: SessionInfoChanged,
    compaction_end: CompactionEnd,
    auto_retry_start: AutoRetryStart,
    auto_retry_end: AutoRetryEnd,

    pub const QueueUpdate = struct {
        steering: EventTextList,
        follow_up: EventTextList,
        revision: u64,

        pub fn deinit(self: *QueueUpdate) void {
            self.steering.deinit();
            self.follow_up.deinit();
            self.* = undefined;
        }
    };

    pub const PromptCommandResult = enum {
        handled,
        unknown,
    };

    pub const PromptCommand = struct {
        command: EventText,
        result: PromptCommandResult,
        message: EventText,

        pub fn deinit(self: *PromptCommand) void {
            self.command.deinit();
            self.message.deinit();
            self.* = undefined;
        }
    };

    pub const CompactionReason = enum {
        manual,
        threshold,
        overflow,
    };

    pub const CompactionStart = struct {
        reason: CompactionReason,
    };

    pub const SessionInfoChanged = struct {
        name: ?EventText,
    };

    pub const CompactionEnd = struct {
        reason: CompactionReason,
        result: ?CompactionResult = null,
        aborted: bool,
        will_retry: bool,
        error_message: ?EventText = null,

        pub fn deinit(self: *CompactionEnd) void {
            if (self.result) |*result| result.deinit();
            if (self.error_message) |*message| message.deinit();
            self.* = undefined;
        }
    };

    pub const AutoRetryStart = struct {
        attempt: usize,
        max_attempts: usize,
        delay_ms: u64,
        error_message: EventText,
    };

    pub const AutoRetryEnd = struct {
        success: bool,
        attempt: usize,
        final_error: ?EventText = null,
    };

    pub fn deinit(self: *AgentSessionEvent) void {
        switch (self.*) {
            .agent_event => {},
            .queue_update => |*payload| payload.deinit(),
            .prompt_command => |*payload| payload.deinit(),
            .compaction_start => {},
            .session_info_changed => |*payload| {
                if (payload.name) |*name| name.deinit();
            },
            .compaction_end => |*payload| payload.deinit(),
            .auto_retry_start => |*payload| payload.error_message.deinit(),
            .auto_retry_end => |*payload| {
                if (payload.final_error) |*err| err.deinit();
            },
        }
        self.* = undefined;
    }

    pub fn jsonStringify(self: AgentSessionEvent, stringify: *std.json.Stringify) !void {
        switch (self) {
            .agent_event => |event| try stringify.write(event),
            .queue_update => |payload| {
                try stringify.beginObject();
                try writeJsonField("type", stringify, "queue_update");
                try writeJsonField("steering", stringify, payload.steering);
                try writeJsonField("followUp", stringify, payload.follow_up);
                try writeJsonField("revision", stringify, payload.revision);
                try stringify.endObject();
            },
            .prompt_command => |payload| {
                try stringify.beginObject();
                try writeJsonField("type", stringify, "prompt_command");
                try writeJsonField("command", stringify, payload.command);
                try writeJsonField("result", stringify, payload.result);
                try writeJsonField("message", stringify, payload.message);
                try stringify.endObject();
            },
            .compaction_start => |payload| {
                try stringify.beginObject();
                try writeJsonField("type", stringify, "compaction_start");
                try writeJsonField("reason", stringify, payload.reason);
                try stringify.endObject();
            },
            .session_info_changed => |payload| {
                try stringify.beginObject();
                try writeJsonField("type", stringify, "session_info_changed");
                if (payload.name) |name| try writeJsonField("name", stringify, name);
                try stringify.endObject();
            },
            .compaction_end => |payload| {
                try stringify.beginObject();
                try writeJsonField("type", stringify, "compaction_end");
                try writeJsonField("reason", stringify, payload.reason);
                if (payload.result) |result| try writeJsonField("result", stringify, result);
                try writeJsonField("aborted", stringify, payload.aborted);
                try writeJsonField("willRetry", stringify, payload.will_retry);
                if (payload.error_message) |message| try writeJsonField("errorMessage", stringify, message);
                try stringify.endObject();
            },
            .auto_retry_start => |payload| {
                try stringify.beginObject();
                try writeJsonField("type", stringify, "auto_retry_start");
                try writeJsonField("attempt", stringify, payload.attempt);
                try writeJsonField("maxAttempts", stringify, payload.max_attempts);
                try writeJsonField("delayMs", stringify, payload.delay_ms);
                try writeJsonField("errorMessage", stringify, payload.error_message);
                try stringify.endObject();
            },
            .auto_retry_end => |payload| {
                try stringify.beginObject();
                try writeJsonField("type", stringify, "auto_retry_end");
                try writeJsonField("success", stringify, payload.success);
                try writeJsonField("attempt", stringify, payload.attempt);
                if (payload.final_error) |err| try writeJsonField("finalError", stringify, err);
                try stringify.endObject();
            },
        }
    }
};

fn writeJsonField(comptime name: []const u8, stringify: *std.json.Stringify, value: anytype) !void {
    try stringify.objectField(name);
    try stringify.write(value);
}

pub const QueueSnapshot = struct {
    revision: u64,
    steering: EventTextList,
    follow_up: EventTextList,

    pub fn deinit(self: *QueueSnapshot) void {
        self.steering.deinit();
        self.follow_up.deinit();
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
        var steering = try EventTextList.init(allocator, self.steering.items);
        errdefer steering.deinit();
        var follow_up = try EventTextList.init(allocator, self.follow_up.items);
        errdefer follow_up.deinit();
        return .{
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
    io: std.Io,
    manager: *session_manager.SessionManager,
    store: ?*session_store.SessionStore,
    queue_mirror: *QueueMirror,
    public_events: *PublicEventQueue,
    timestamp: []const u8,
    dropped_public_event_count: usize = 0,
    terminal_snapshot_entry_count: usize = 0,

    pub fn handle(self: *EventDrain, event: agent_mod.AgentEvent) !void {
        try self.updateQueueMirror(event);
        try self.runSessionHooks(event);
        self.emitPublicEvent(event);
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
        try self.emitQueueUpdate();
    }

    fn runSessionHooks(_: *EventDrain, _: agent_mod.AgentEvent) !void {}

    fn emitPublicEvent(self: *EventDrain, event: agent_mod.AgentEvent) void {
        self.enqueuePublicEvent(.{ .agent_event = event });
    }

    fn persistEvent(self: *EventDrain, event: agent_mod.AgentEvent) !void {
        if (event != .message_end) return;
        try self.manager.ensureAppendCapacity(1);
        const entry = try self.manager.prepareMessageEntry(event.message_end.message, self.timestamp);
        errdefer self.manager.deinitPreparedEntry(entry);
        if (self.store) |store| try store.appendEntry(self.allocator, self.io, entry);
        _ = self.manager.commitPreparedEntry(entry);
    }

    fn handleTerminalPolicy(self: *EventDrain, event: agent_mod.AgentEvent) !void {
        if (event != .agent_end) return;
        self.terminal_snapshot_entry_count = self.manager.entries.items.len;
    }

    fn emitQueueUpdate(self: *EventDrain) !void {
        var steering = try EventTextList.init(self.allocator, self.queue_mirror.steering.items);
        errdefer steering.deinit();
        var follow_up = try EventTextList.init(self.allocator, self.queue_mirror.follow_up.items);
        errdefer follow_up.deinit();
        self.enqueuePublicEvent(.{ .queue_update = .{
            .steering = steering,
            .follow_up = follow_up,
            .revision = self.queue_mirror.revision,
        } });
    }

    fn enqueuePublicEvent(self: *EventDrain, event: AgentSessionEvent) void {
        var owned_event = event;
        if (!self.public_events.pushOrDrop(owned_event)) owned_event.deinit();
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

    var builtin_tools = try tool_registry.BuiltinTools.init(allocator, .{
        .cwd = options.cwd,
        .allow_paths_outside_cwd = options.allow_paths_outside_cwd,
    });
    errdefer builtin_tools.deinit();

    var tools: tool_registry.ToolRegistry = .{};
    errdefer tools.deinit(allocator);
    try builtin_tools.appendDefinitions(&tools);
    try tools.setActiveToolsByName(allocator, &.{ "read", "ls", "grep", "find", "bash", "edit", "write" });

    var system_prompt_state = try SystemPromptState.init(
        allocator,
        options.cwd,
        options.current_date,
        &prompt_resources,
        &tools,
    );
    errdefer system_prompt_state.deinit(allocator);

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
        .system_prompt = system_prompt_state.text,
        .model = options.model,
        .thinking_level = options.thinking_level,
        .tools = tools.activeAgentTools(),
        .messages = session_context.messages,
    };
    if (options.stream) |stream| agent_options.stream = stream;
    if (options.get_api_key) |get_api_key| agent_options.get_api_key = get_api_key;

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
        .cwd = cwd,
        .current_date = current_date,
        .timestamp = timestamp,
        .prompt_resources = prompt_resources,
        .system_prompt_state = system_prompt_state,
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
    const run = self.startPromptRun(text, images, options) catch |err| switch (err) {
        error.PromptCommandCannotStartLiveRun, error.PromptQueuedCannotStartLiveRun => return,
        else => |unexpected| return unexpected,
    };
    defer self.destroyPromptRun(run);
    while (try self.stepPromptRun(run)) {}
}

fn startPromptRun(
    self: *AgentSession,
    text: []const u8,
    images: []const ai.ImageContent,
    options: PromptOptions,
) !*LivePromptRun {
    try self.ensureAcceptsPrompt();
    var preflight = try self.preparePromptInput(text, images, options);
    defer preflight.deinit(self.allocator);
    if (try self.tryHandlePromptCommand(&preflight)) return error.PromptCommandCannotStartLiveRun;
    try self.runInputHooks(&preflight);
    try self.expandPromptResources(&preflight);
    if (try self.queuePromptIfStreaming(&preflight)) return error.PromptQueuedCannotStartLiveRun;
    try self.flushPendingSessionMessages();
    try self.checkModelPreconditions();
    try self.checkPrePromptCompaction();
    try self.runBeforeAgentStartHooks(&preflight);
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
        self.io,
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
    if (try run.stream.next(self.io)) |event| {
        try self.agent.emitEvent(event);
        return true;
    }
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
    try self.ensureAcceptsContinue();
    try self.agent.continueRun();
}

pub fn compactWithSummary(
    self: *AgentSession,
    summary: []const u8,
    first_kept_entry_id: []const u8,
    tokens_before: u64,
) !CompactionResult {
    return self.runManualCompaction(.{ .explicit = .{
        .summary = summary,
        .first_kept_entry_id = first_kept_entry_id,
        .tokens_before = tokens_before,
    } });
}

pub fn compactPreparedWithSummary(
    self: *AgentSession,
    summary: []const u8,
    settings: session_manager.CompactionSettings,
) !CompactionResult {
    return self.runManualCompaction(.{ .prepared = .{
        .summary = summary,
        .settings = settings,
    } });
}

pub fn compactWithPreparedSummary(self: *AgentSession, summary: []const u8) !CompactionResult {
    return self.runManualCompaction(.{ .prepared = .{
        .summary = summary,
        .settings = self.compaction_settings,
    } });
}

fn runManualCompaction(
    self: *AgentSession,
    request: ManualCompactionRequest,
) !CompactionResult {
    try self.ensureAcceptsContinue();
    self.event_drain.enqueuePublicEvent(.{ .compaction_start = .{ .reason = .manual } });
    return self.applyManualCompactionRequest(request) catch |err| {
        const error_message = EventText.init(self.allocator, @errorName(err)) catch return err;
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

fn applyManualCompaction(
    self: *AgentSession,
    summary: []const u8,
    first_kept_entry_id: []const u8,
    tokens_before: u64,
) !CompactionResult {
    try self.ensureEntryInActiveBranch(first_kept_entry_id);
    try self.manager.ensureAppendCapacity(1);
    const entry = try self.manager.prepareCompactionEntry(
        summary,
        first_kept_entry_id,
        tokens_before,
        self.timestamp,
    );
    errdefer self.manager.deinitPreparedEntry(entry);

    if (self.store) |store| try store.appendEntry(self.allocator, self.io, entry);

    var event_result = try CompactionResult.init(self.allocator, entry.compaction);
    errdefer event_result.deinit();
    var return_result = try CompactionResult.init(self.allocator, entry.compaction);
    errdefer return_result.deinit();

    _ = self.manager.commitPreparedEntry(entry);

    const context = try self.manager.buildSessionContext(self.allocator);
    defer self.manager.deinitSessionContext(self.allocator, context);
    try self.agent.replaceMessages(context.messages);

    self.event_drain.enqueuePublicEvent(.{ .compaction_end = .{
        .reason = .manual,
        .result = event_result,
        .aborted = false,
        .will_retry = false,
    } });
    event_result = undefined;

    const result = return_result;
    return_result = undefined;
    return result;
}

fn applyManualCompactionRequest(
    self: *AgentSession,
    request: ManualCompactionRequest,
) !CompactionResult {
    return switch (request) {
        .explicit => |explicit| self.applyManualCompaction(
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
) !CompactionResult {
    var preparation = try self.manager.prepareCompaction(self.allocator, settings);
    defer preparation.deinit();
    return self.applyManualCompaction(
        summary,
        preparation.first_kept_entry_id,
        preparation.tokens_before,
    );
}

fn ensureEntryInActiveBranch(self: *AgentSession, entry_id: []const u8) !void {
    const branch = try self.manager.getBranch(self.allocator);
    defer self.allocator.free(branch);
    for (branch) |entry| {
        if (std.mem.eql(u8, entry.id(), entry_id)) return;
    }
    return error.CompactionEntryNotInBranch;
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

fn tryHandlePromptCommand(self: *AgentSession, preflight: *const PromptPreflight) !bool {
    const command = parsePromptCommand(preflight.text) orelse return false;

    const command_name = parsePromptCommandName(command) orelse {
        const unknown_message = try std.fmt.allocPrint(self.allocator, "unknown command: /{s}", .{command});
        errdefer self.allocator.free(unknown_message);
        try self.emitPromptCommandOwned(command, .unknown, EventText.initOwned(self.allocator, unknown_message));
        return true;
    };

    switch (command_name) {
        .help => try self.emitPromptCommand(command, .handled, "available commands: /help, /session"),
        .session => {
            const snapshot = self.statusSnapshot();
            const tools = self.toolSnapshot();
            const message = try std.fmt.allocPrint(
                self.allocator,
                "session: {s}; public events: {}; dropped events: {}; active tools: {}",
                .{
                    @tagName(snapshot.status),
                    snapshot.public_event_count,
                    snapshot.dropped_public_event_count,
                    tools.active_count,
                },
            );
            errdefer self.allocator.free(message);
            try self.emitPromptCommandOwned(command, .handled, EventText.initOwned(self.allocator, message));
        },
    }
    return true;
}

fn parsePromptCommandName(command: []const u8) ?PromptCommandName {
    for (prompt_commands) |name| {
        if (std.mem.eql(u8, command, @tagName(name))) return name;
    }
    return null;
}

fn emitPromptCommand(
    self: *AgentSession,
    command: []const u8,
    result: AgentSessionEvent.PromptCommandResult,
    message_text: []const u8,
) !void {
    var message = try EventText.init(self.allocator, message_text);
    errdefer message.deinit();
    try self.emitPromptCommandOwned(command, result, message);
}

fn emitPromptCommandOwned(
    self: *AgentSession,
    command: []const u8,
    result: AgentSessionEvent.PromptCommandResult,
    message: EventText,
) !void {
    var owned_message = message;
    errdefer owned_message.deinit();
    self.event_drain.enqueuePublicEvent(.{ .prompt_command = .{
        .command = try EventText.init(self.allocator, command),
        .result = result,
        .message = owned_message,
    } });
}

fn parsePromptCommand(text: []const u8) ?[]const u8 {
    if (text.len < 2 or text[0] != '/') return null;
    var end: usize = 1;
    while (end < text.len and !std.ascii.isWhitespace(text[end])) end += 1;
    if (end == 1) return null;
    return text[1..end];
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
    const message = try self.constructUserMessage(preflight.text, preflight.images);
    try self.event_drain.emitQueueUpdate();
    switch (behavior) {
        .steer => self.agent.steer(message) catch |err| {
            self.rollbackQueuedPrompt(behavior, preflight.text);
            try self.event_drain.emitQueueUpdate();
            return err;
        },
        .follow_up => self.agent.followUp(message) catch |err| {
            self.rollbackQueuedPrompt(behavior, preflight.text);
            try self.event_drain.emitQueueUpdate();
            return err;
        },
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
    try std.testing.expectEqualStrings("bash", session.activeToolNames()[4]);
    try std.testing.expectEqualStrings("bash", session.agent.state.tools[4].name);
    try std.testing.expectEqual(agent_mod.ToolExecutionMode.sequential, session.agent.state.tools[4].execution_mode.?);
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

test "agent session slash command while running emits command event without queueing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try initTestSession(tmp.dir);
    defer shutdownAndDeinit(&session);

    _ = try session.agent.beginRun();
    defer session.agent.finishRun();

    try session.promptWithOptions("/help", &.{}, .{});

    try std.testing.expectEqual(@as(usize, 0), session.agent.steering_queue.count());
    try std.testing.expectEqual(@as(usize, 0), session.agent.follow_up_queue.count());
    try std.testing.expectEqual(@as(usize, 0), session.manager.entries.items.len);
    try expectNextPromptCommand(&session, .handled, "help", "available commands: /help, /session");
    try std.testing.expectEqual(@as(usize, 0), session.publicEventCount());
}

test "agent session slash command public event overflow is bounded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try initTestSessionWithCapacity(tmp.dir, 1);
    defer shutdownAndDeinit(&session);

    try session.promptWithOptions("/help", &.{}, .{});
    try session.promptWithOptions("/session", &.{}, .{});

    try std.testing.expectEqual(@as(usize, 1), session.publicEventCount());
    try std.testing.expectEqual(@as(usize, 1), session.event_drain.dropped_public_event_count);
    try std.testing.expectEqual(@as(usize, 0), session.manager.entries.items.len);
    try expectNextPromptCommand(&session, .handled, "help", "available commands: /help, /session");
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
    var start_event = session.drainPublicEvent().?;
    defer start_event.deinit();
    try expectUserMessageEvent(.message_start, start_event.agent_event, "hello");
    var end_event = session.drainPublicEvent().?;
    defer end_event.deinit();
    try expectUserMessageEvent(.message_end, end_event.agent_event, "hello");
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
    try expectUserMessageEvent(.message_start, message_event.agent_event, "queued image");
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
    try expectUserMessageEvent(.message_start, message_event.agent_event, "queued");
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
    var event = session.drainPublicEvent().?;
    event.deinit();
    try std.testing.expectEqual(@as(usize, 0), session.publicEventCount());
}

test "agent session slash command emits public command event without model run" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try initTestSession(tmp.dir);
    defer shutdownAndDeinit(&session);

    try session.promptWithOptions("/missing arg", &.{}, .{});

    try std.testing.expectEqual(AgentSessionStatus.idle, session.status());
    try std.testing.expectEqual(@as(usize, 0), session.agent.state.messages.len);
    try std.testing.expectEqual(@as(usize, 0), session.manager.entries.items.len);
    try expectNextPromptCommand(&session, .unknown, "missing", "unknown command: /missing");
    try std.testing.expectEqual(@as(usize, 0), session.publicEventCount());
}

test "agent session help command emits handled event without model run" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try initTestSession(tmp.dir);
    defer shutdownAndDeinit(&session);

    try session.promptWithOptions("/help", &.{}, .{});

    try std.testing.expectEqual(AgentSessionStatus.idle, session.status());
    try std.testing.expectEqual(@as(usize, 0), session.agent.state.messages.len);
    try std.testing.expectEqual(@as(usize, 0), session.manager.entries.items.len);
    try expectNextPromptCommand(&session, .handled, "help", "available commands: /help, /session");
    try std.testing.expectEqual(@as(usize, 0), session.publicEventCount());
}

test "agent session session command emits snapshot without model run" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try initTestSession(tmp.dir);
    defer shutdownAndDeinit(&session);

    const expected_tools = session.toolSnapshot().active_count;
    try session.promptWithOptions("/session", &.{}, .{});

    try std.testing.expectEqual(AgentSessionStatus.idle, session.status());
    try std.testing.expectEqual(@as(usize, 0), session.agent.state.messages.len);
    try std.testing.expectEqual(@as(usize, 0), session.manager.entries.items.len);
    var event = session.drainPublicEvent().?;
    defer event.deinit();
    try std.testing.expect(event == .prompt_command);
    try std.testing.expectEqual(AgentSessionEvent.PromptCommandResult.handled, event.prompt_command.result);
    try std.testing.expectEqualStrings("session", event.prompt_command.command.text);
    const expected_message = try std.fmt.allocPrint(
        std.testing.allocator,
        "session: idle; public events: 0; dropped events: 0; active tools: {}",
        .{expected_tools},
    );
    defer std.testing.allocator.free(expected_message);
    try std.testing.expectEqualStrings(expected_message, event.prompt_command.message.text);
    try std.testing.expectEqual(@as(usize, 0), session.publicEventCount());
}

test "agent session slash command parser requires command name" {
    try std.testing.expect(parsePromptCommand("hello") == null);
    try std.testing.expect(parsePromptCommand("/") == null);
    try std.testing.expect(parsePromptCommand("/ missing") == null);
    try std.testing.expectEqualStrings("missing", parsePromptCommand("/missing arg").?);
}

test "agent session slash command event serializes public shape" {
    var unknown_event: AgentSessionEvent = .{ .prompt_command = .{
        .command = try EventText.init(std.testing.allocator, "missing"),
        .result = .unknown,
        .message = try EventText.init(std.testing.allocator, "unknown command: /missing"),
    } };
    defer unknown_event.deinit();

    var unknown_writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer unknown_writer.deinit();

    try std.json.Stringify.value(unknown_event, .{}, &unknown_writer.writer);

    try std.testing.expectEqualStrings(
        "{\"type\":\"prompt_command\",\"command\":\"missing\",\"result\":\"unknown\"," ++
            "\"message\":\"unknown command: /missing\"}",
        unknown_writer.written(),
    );

    var handled_event: AgentSessionEvent = .{ .prompt_command = .{
        .command = try EventText.init(std.testing.allocator, "help"),
        .result = .handled,
        .message = try EventText.init(std.testing.allocator, "available commands: /help, /session"),
    } };
    defer handled_event.deinit();

    var handled_writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer handled_writer.deinit();

    try std.json.Stringify.value(handled_event, .{}, &handled_writer.writer);

    try std.testing.expectEqualStrings(
        "{\"type\":\"prompt_command\",\"command\":\"help\",\"result\":\"handled\"," ++
            "\"message\":\"available commands: /help, /session\"}",
        handled_writer.written(),
    );
}

test "agent session failed compaction end event omits result" {
    var event: AgentSessionEvent = .{ .compaction_end = .{
        .reason = .manual,
        .aborted = true,
        .will_retry = false,
        .error_message = try EventText.init(std.testing.allocator, "not implemented"),
    } };
    defer event.deinit();

    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();

    try std.json.Stringify.value(event, .{}, &writer.writer);

    try std.testing.expectEqualStrings(
        "{\"type\":\"compaction_end\",\"reason\":\"manual\",\"aborted\":true," ++
            "\"willRetry\":false,\"errorMessage\":\"not implemented\"}",
        writer.written(),
    );
}

test "agent session compaction end event serializes owned result" {
    var manager = try session_manager.SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();

    const first_kept = try manager.appendMessage(.{ .user = .{
        .content = .{ .string = "kept" },
        .timestamp = 0,
    } }, "t1");
    _ = try manager.appendCompaction("summary", first_kept, 42, "t2");

    var event: AgentSessionEvent = .{ .compaction_end = .{
        .reason = .manual,
        .result = try CompactionResult.init(
            std.testing.allocator,
            manager.entries.items[1].compaction,
        ),
        .aborted = false,
        .will_retry = false,
    } };
    defer event.deinit();

    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();

    try std.json.Stringify.value(event, .{}, &writer.writer);

    try std.testing.expectEqualStrings(
        "{\"type\":\"compaction_end\",\"reason\":\"manual\",\"result\":{\"summary\":\"summary\"," ++
            "\"firstKeptEntryId\":\"00000001\",\"tokensBefore\":42},\"aborted\":false,\"willRetry\":false}",
        writer.written(),
    );
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

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
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
    try std.testing.expectEqual(AgentSessionEvent.CompactionReason.manual, start_event.compaction_start.reason);

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

    var session = try initTestSession(tmp.dir);
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

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
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

test "agent session prepared manual compaction emits failure event" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try initTestSession(tmp.dir);
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

fn initTestSession(dir: std.Io.Dir) !AgentSession {
    return initTestSessionWithCapacity(dir, public_event_capacity_default);
}

fn initTestSessionWithCapacity(dir: std.Io.Dir, public_event_capacity: usize) !AgentSession {
    try dir.createDirPath(std.testing.io, "agent");
    try dir.createDirPath(std.testing.io, "repo");

    return AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
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
    result: AgentSessionEvent.PromptCommandResult,
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
        if (std.meta.activeTag(owned_event.agent_event) != tag) continue;
        try expectUserMessageEvent(tag, owned_event.agent_event, text);
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
