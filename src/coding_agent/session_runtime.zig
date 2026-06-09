const std = @import("std");
const agent_mod = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const runtime = @import("../runtime/root.zig");
const AgentSession = @import("AgentSession.zig");
const client_protocol = @import("client_protocol.zig");
const paths_mod = @import("paths.zig");
const RuntimeServices = @import("runtime_services.zig").RuntimeServices;
const session_manager = @import("session_manager.zig");
const session_store = @import("session_store.zig");
const session_history_snapshot = @import("session_history_snapshot.zig");
const settings_mod = @import("settings.zig");
const tool_registry = @import("tool_registry.zig");

const CreateOptions = struct {
    cwd: []const u8 = ".",
    agent_dir_override: ?[]const u8 = null,
    current_date: []const u8,
    session_id: []const u8,
    timestamp: []const u8,
    model: ?ai.Model = null,
    thinking_level: ?agent_mod.ThinkingLevel = null,
    stream: ?ai.StreamFunction = null,
    dir: std.Io.Dir = .cwd(),
    environ: ?*const std.process.Environ.Map = null,
    zio_runtime: ?*runtime.Runtime = null,
    allow_paths_outside_cwd: bool = true,
    public_event_capacity: usize = AgentSession.public_event_capacity_default,
    command_capacity: usize = client_protocol.command_queue_capacity_default,
    event_capacity: usize = client_protocol.event_queue_capacity_default,
};

const ResumeOptions = struct {
    cwd: []const u8 = ".",
    agent_dir_override: ?[]const u8 = null,
    current_date: []const u8,
    session_file_name: []const u8,
    model: ?ai.Model = null,
    thinking_level: ?agent_mod.ThinkingLevel = null,
    stream: ?ai.StreamFunction = null,
    dir: std.Io.Dir = .cwd(),
    environ: ?*const std.process.Environ.Map = null,
    zio_runtime: ?*runtime.Runtime = null,
    allow_paths_outside_cwd: bool = true,
    public_event_capacity: usize = AgentSession.public_event_capacity_default,
    command_capacity: usize = client_protocol.command_queue_capacity_default,
    event_capacity: usize = client_protocol.event_queue_capacity_default,
};

pub const WakeResult = enum { input, session, frame };

pub const SessionRuntime = struct {
    allocator: std.mem.Allocator,
    services: RuntimeServices,
    session: AgentSession,
    command_buffer: []client_protocol.CommandEnvelope,
    event_buffer: []client_protocol.EventEnvelope,
    commands: client_protocol.CommandQueue,
    events: client_protocol.EventQueue,
    wake_event: runtime.ResetEvent = .init,
    active_run: ?*AgentSession.RuntimeAccess.PromptRun = null,
    active_request_id: ?client_protocol.RequestId = null,

    pub fn submit(self: *SessionRuntime, envelope: client_protocol.CommandEnvelope) !void {
        try self.commands.push(envelope);
        self.wake_event.set();
    }

    pub fn drainEvent(self: *SessionRuntime) ?client_protocol.EventEnvelope {
        return self.events.pop();
    }

    pub fn wake(self: *SessionRuntime) *runtime.ResetEvent {
        return &self.wake_event;
    }

    pub fn sessionHeader(self: *const SessionRuntime) session_manager.SessionHeader {
        return self.session.manager.header;
    }

    pub fn model(self: *const SessionRuntime) ai.Model {
        return self.session.agent.state.model;
    }

    pub fn buildHistorySnapshot(self: *const SessionRuntime, allocator: std.mem.Allocator) !session_history_snapshot.Snapshot {
        return session_history_snapshot.build(allocator, self.session.manager);
    }

    pub fn findToolDefinition(self: *const SessionRuntime, name: []const u8) ?tool_registry.ToolDefinition {
        return self.session.tools.findDefinition(name);
    }

    pub fn queuedMessagesSnapshot(self: *const SessionRuntime, allocator: std.mem.Allocator) !client_protocol.QueueSnapshot {
        return AgentSession.RuntimeAccess.queueSnapshot(&self.session, allocator);
    }

    pub fn dropQueuedMessages(self: *SessionRuntime) !void {
        try AgentSession.RuntimeAccess.clearQueue(&self.session);
        try self.drainSessionEvents(null);
    }

    pub fn waitForWake(self: *SessionRuntime, input_fd: std.posix.fd_t, frame_ms: u64) !WakeResult {
        const readable = runtime.ReadableFd.initBorrowed(input_fd);
        var input = readable.asyncReadable();
        var frame = runtime.Timeout.fromMilliseconds(frame_ms);
        var public_event_wake = AgentSession.RuntimeAccess.publicEventWake(&self.session);
        if (self.active_run) |run| {
            var progress = run.stream.asyncNext();
            switch (try runtime.select(.{ .input = &input, .prompt = &progress, .public_event = public_event_wake, .frame = &frame })) {
                .input => |result| {
                    result catch return .session;
                    return .input;
                },
                .prompt => |result| {
                    try self.applyPromptProgressResult(run, result);
                    return .session;
                },
                .public_event => {
                    public_event_wake.reset();
                    try self.drainSessionEvents(null);
                    return .session;
                },
                .frame => return .frame,
            }
        }
        switch (try runtime.select(.{ .input = &input, .public_event = public_event_wake, .frame = &frame })) {
            .input => |result| {
                result catch return .session;
                return .input;
            },
            .public_event => {
                public_event_wake.reset();
                try self.drainSessionEvents(null);
                return .session;
            },
            .frame => return .frame,
        }
    }

    pub fn stepPromptProgressBounded(self: *SessionRuntime, limit: usize) !usize {
        const run = self.active_run orelse return 0;
        var count: usize = 0;
        while (count < limit and self.active_run != null) : (count += 1) {
            var progress = run.stream.asyncNext();
            var ready = runtime.Timeout.fromMilliseconds(0);
            switch (try runtime.select(.{ .prompt = &progress, .ready = &ready })) {
                .prompt => |result| try self.applyPromptProgressResult(run, result),
                .ready => return count,
            }
        }
        return count;
    }

    pub fn step(self: *SessionRuntime) !void {
        while (self.commands.pop()) |envelope| {
            var command = envelope;
            defer command.deinit(self.allocator);
            try self.applyCommand(command);
        }
        _ = try self.stepPromptProgressBounded(64);
        try self.drainSessionEvents(null);
    }

    pub fn deinit(self: *SessionRuntime) void {
        if (self.active_run) |run| {
            AgentSession.RuntimeAccess.destroyPromptRun(&self.session, run);
            self.active_run = null;
        }
        drainQueuedCommands(self);
        drainQueuedEvents(self);
        shutdownAndDeinitSession(&self.session);
        self.services.deinit();
        self.allocator.free(self.event_buffer);
        self.allocator.free(self.command_buffer);
        self.* = undefined;
    }

    fn applyCommand(self: *SessionRuntime, envelope: client_protocol.CommandEnvelope) !void {
        switch (envelope.command) {
            .submit_prompt => |prompt| {
                if (self.active_run != null) {
                    AgentSession.RuntimeAccess.promptWithOptions(&self.session, prompt.text, &.{}, .{ .streaming_behavior = .steer }) catch |err| {
                        try self.enqueueRejected(envelope.id, .invalid_command, @errorName(err));
                        return;
                    };
                    try self.drainSessionEvents(envelope.id);
                    return;
                }
                self.active_run = AgentSession.RuntimeAccess.startPromptRun(&self.session, prompt.text, &.{}, .{}) catch |err| {
                    try self.enqueueRejected(envelope.id, .invalid_command, @errorName(err));
                    return;
                };
                self.active_request_id = envelope.id;
                try self.drainSessionEvents(envelope.id);
            },
            .cancel => {
                if (self.active_run) |run| {
                    AgentSession.RuntimeAccess.cancelPromptRun(&self.session, run) catch AgentSession.RuntimeAccess.cancel(&self.session);
                    AgentSession.RuntimeAccess.destroyPromptRun(&self.session, run);
                    self.active_run = null;
                    self.active_request_id = null;
                } else AgentSession.RuntimeAccess.cancel(&self.session);
                try self.drainSessionEvents(envelope.id);
                try self.enqueueEvent(.{ .request_id = envelope.id, .event = .{ .response = .canceled } });
            },
            .clear_queue => {
                try self.dropQueuedMessages();
                try self.enqueueEvent(.{ .request_id = envelope.id, .event = .{ .response = .queue_cleared } });
            },
            .request_snapshot => try self.enqueueEvent(.{ .request_id = envelope.id, .event = .{ .response = .snapshot_sent } }),
            .shutdown => {
                AgentSession.RuntimeAccess.requestShutdown(&self.session);
                try self.enqueueEvent(.{ .request_id = envelope.id, .event = .{ .response = .shutdown_started } });
            },
        }
    }

    fn applyPromptProgressResult(self: *SessionRuntime, run: *AgentSession.RuntimeAccess.PromptRun, result: anytype) !void {
        if (self.active_run != run) return;
        const request_id = self.active_request_id;
        const more = try AgentSession.RuntimeAccess.applyPromptRunProgress(&self.session, run, result);
        try self.drainSessionEvents(request_id);
        if (!more) {
            AgentSession.RuntimeAccess.destroyPromptRun(&self.session, run);
            self.active_run = null;
            self.active_request_id = null;
            try self.enqueueEvent(.{ .request_id = request_id, .event = .{ .response = .prompt_finished } });
        }
    }

    fn drainSessionEvents(self: *SessionRuntime, request_id: ?client_protocol.RequestId) !void {
        while (AgentSession.RuntimeAccess.drainPublicEvent(&self.session)) |event| {
            try self.enqueueEvent(.{ .request_id = request_id, .event = event });
        }
    }

    fn enqueueRejected(
        self: *SessionRuntime,
        request_id: ?client_protocol.RequestId,
        code: client_protocol.Rejection.Code,
        message: []const u8,
    ) !void {
        const owned_message = try client_protocol.EventText.init(self.allocator, message);
        try self.enqueueEvent(.{ .request_id = request_id, .event = .{ .rejected = .{ .code = code, .message = owned_message } } });
    }

    fn enqueueEvent(self: *SessionRuntime, envelope: client_protocol.EventEnvelope) !void {
        if (self.events.pushOrDrop(envelope)) return;
        var owned_envelope = envelope;
        owned_envelope.deinit(self.allocator);
        return error.EventQueueFull;
    }
};

pub fn createSessionRuntime(allocator: std.mem.Allocator, options: CreateOptions) !SessionRuntime {
    var init_result = try initSessionRuntimeBase(allocator, options);
    errdefer init_result.services.deinit();

    const sessions_dir = try (paths_mod.PersistencePaths{ .global_dir = init_result.services.agent_dir, .cwd = init_result.services.cwd }).sessionsDirForCwd(allocator);
    defer allocator.free(sessions_dir);
    var store = try session_store.SessionStore.createInPath(
        allocator,
        init_result.services.io,
        options.dir,
        sessions_dir,
        init_result.services.cwd,
        options.session_id,
        options.timestamp,
    );
    errdefer store.deinit(allocator);

    var session_options = init_result.options;
    session_options.session_id = options.session_id;
    session_options.timestamp = options.timestamp;
    session_options.session_store = store;
    var session = try AgentSession.init(allocator, init_result.services.io, session_options);
    errdefer shutdownAndDeinitSession(&session);

    return initWithSession(allocator, init_result.services, session, options.command_capacity, options.event_capacity);
}

pub fn resumeSessionRuntime(allocator: std.mem.Allocator, options: ResumeOptions) !SessionRuntime {
    if (!std.mem.eql(u8, std.fs.path.basename(options.session_file_name), options.session_file_name)) {
        return error.InvalidSessionFileName;
    }

    var init_result = try initSessionRuntimeBase(allocator, options);
    errdefer init_result.services.deinit();

    const sessions_dir = try (paths_mod.PersistencePaths{ .global_dir = init_result.services.agent_dir, .cwd = init_result.services.cwd }).sessionsDirForCwd(allocator);
    defer allocator.free(sessions_dir);
    const file_name = try std.fs.path.join(allocator, &.{ sessions_dir, options.session_file_name });
    errdefer allocator.free(file_name);

    var session_options = init_result.options;
    session_options.resume_session_store = .{ .dir = options.dir, .file_name = file_name };
    var session = try AgentSession.init(allocator, init_result.services.io, session_options);
    errdefer shutdownAndDeinitSession(&session);

    return initWithSession(allocator, init_result.services, session, options.command_capacity, options.event_capacity);
}

fn initWithSession(
    allocator: std.mem.Allocator,
    services: RuntimeServices,
    session: AgentSession,
    command_capacity: usize,
    event_capacity: usize,
) !SessionRuntime {
    if (command_capacity == 0) return error.CommandCapacityZero;
    if (event_capacity == 0) return error.EventCapacityZero;
    const command_buffer = try allocator.alloc(client_protocol.CommandEnvelope, command_capacity);
    errdefer allocator.free(command_buffer);
    const event_buffer = try allocator.alloc(client_protocol.EventEnvelope, event_capacity);
    errdefer allocator.free(event_buffer);
    return .{
        .allocator = allocator,
        .services = services,
        .session = session,
        .command_buffer = command_buffer,
        .event_buffer = event_buffer,
        .commands = client_protocol.CommandQueue.init(command_buffer),
        .events = client_protocol.EventQueue.init(event_buffer),
    };
}

const SessionRuntimeInit = struct {
    services: RuntimeServices,
    options: AgentSession.Options,
};

fn initSessionRuntimeBase(allocator: std.mem.Allocator, options: anytype) !SessionRuntimeInit {
    const resolved_agent_dir = if (options.agent_dir_override) |agent_dir_override|
        agent_dir_override
    else
        try paths_mod.resolveGlobalAgentDirFromEnv(allocator, options.environ);
    defer if (options.agent_dir_override == null) allocator.free(resolved_agent_dir);

    var services = try RuntimeServices.init(allocator, .{
        .cwd = options.cwd,
        .agent_dir = resolved_agent_dir,
        .dir = options.dir,
        .environ = options.environ,
        .zio_runtime = options.zio_runtime,
    });
    errdefer services.deinit();

    return .{ .services = services, .options = resolveSessionOptions(&services, .{
        .current_date = options.current_date,
        .model = options.model,
        .thinking_level = options.thinking_level,
        .stream = options.stream,
        .dir = options.dir,
        .allow_paths_outside_cwd = options.allow_paths_outside_cwd,
        .public_event_capacity = options.public_event_capacity,
    }) };
}

fn shutdownAndDeinitSession(session: *AgentSession) void {
    AgentSession.RuntimeAccess.requestShutdown(session);
    while (AgentSession.RuntimeAccess.drainPublicEvent(session)) |event| {
        var owned_event = event;
        owned_event.deinit();
    }
    session.deinit();
}

fn drainQueuedCommands(self: *SessionRuntime) void {
    while (self.commands.pop()) |envelope| {
        var owned_envelope = envelope;
        owned_envelope.deinit(self.allocator);
    }
}

fn drainQueuedEvents(self: *SessionRuntime) void {
    while (self.events.pop()) |envelope| {
        var owned_envelope = envelope;
        owned_envelope.deinit(self.allocator);
    }
}

const SessionOptionsInput = struct {
    current_date: []const u8,
    model: ?ai.Model = null,
    thinking_level: ?agent_mod.ThinkingLevel = null,
    stream: ?ai.StreamFunction = null,
    dir: std.Io.Dir = .cwd(),
    allow_paths_outside_cwd: bool = true,
    public_event_capacity: usize = AgentSession.public_event_capacity_default,
};

fn resolveSessionOptions(services: *RuntimeServices, options: SessionOptionsInput) AgentSession.Options {
    services.diagnostic_count = 0;
    const model = resolveModel(services, options.model);
    return .{
        .cwd = services.cwd,
        .agent_dir = services.agent_dir,
        .current_date = options.current_date,
        .session_id = "",
        .timestamp = "",
        .model = model,
        .thinking_level = resolveThinkingLevel(services.settings_manager.current(), options.thinking_level),
        .compaction_settings = resolveCompactionSettings(services.settings_manager.current()),
        .retry_settings = resolveRetrySettings(services.settings_manager.current()),
        .stream = resolveStream(services, options.stream, model),
        .get_api_key = services.auth_manager.hook(),
        .zio_runtime = services.zio_runtime,
        .dir = options.dir,
        .environ = services.environ,
        .allow_paths_outside_cwd = options.allow_paths_outside_cwd,
        .public_event_capacity = options.public_event_capacity,
    };
}

fn resolveStream(services: *RuntimeServices, explicit: ?ai.StreamFunction, model: ai.Model) ?ai.StreamFunction {
    if (explicit) |stream| return stream;
    const provider = services.provider_registry.get(model.api) orelse {
        if (!std.mem.eql(u8, model.api, "unknown") and services.diagnostic_count < services.diagnostics.len) {
            services.diagnostics[services.diagnostic_count] = .{ .unresolved_stream = .{ .api = model.api } };
            services.diagnostic_count += 1;
        }
        return null;
    };
    return provider.stream_simple;
}

fn resolveModel(services: *RuntimeServices, explicit: ?ai.Model) ai.Model {
    if (explicit) |model| return model;
    const snapshot = services.settings_manager.current();
    const project = fileSettings(snapshot.project);
    const global = fileSettings(snapshot.global);
    const provider = project.default_provider orelse global.default_provider;
    const model_id = project.default_model orelse global.default_model;
    if (provider != null or model_id != null) {
        if (provider) |provider_name| if (model_id) |id| {
            if (findAvailableModel(services, provider_name, id)) |model| return model;
        };
        if (services.diagnostic_count < services.diagnostics.len) {
            services.diagnostics[services.diagnostic_count] = .{ .unresolved_model_setting = .{ .provider = provider, .model = model_id } };
            services.diagnostic_count += 1;
        }
    }
    return firstAvailableModel(services) orelse agent_mod.Agent.defaultModel();
}

fn findAvailableModel(services: *const RuntimeServices, provider: ai.Provider, model_id: []const u8) ?ai.Model {
    const model = ai.getModel(provider, model_id) orelse return null;
    return if (services.auth_manager.hasAuth(model.provider)) model else null;
}

fn firstAvailableModel(services: *const RuntimeServices) ?ai.Model {
    for (ai.getProviders()) |provider| {
        for (ai.getModels(provider)) |model| {
            if (services.auth_manager.hasAuth(model.provider)) return model;
        }
    }
    return null;
}

fn resolveThinkingLevel(snapshot: *const settings_mod.SettingsSnapshot, explicit: ?agent_mod.ThinkingLevel) agent_mod.ThinkingLevel {
    if (explicit) |level| return level;
    const global = fileSettings(snapshot.global);
    const project = fileSettings(snapshot.project);
    if (project.default_thinking_level orelse global.default_thinking_level) |level_text| {
        if (parseThinkingLevel(level_text)) |level| return level;
    }
    return .off;
}

fn resolveCompactionSettings(snapshot: *const settings_mod.SettingsSnapshot) session_manager.CompactionSettings {
    const global = fileSettings(snapshot.global);
    const project = fileSettings(snapshot.project);
    var settings: session_manager.CompactionSettings = .{};
    if (global.compaction) |compaction| {
        if (compaction.keep_recent_tokens) |tokens| settings.keep_recent_tokens = tokens;
        if (compaction.enabled) |enabled| settings.auto_enabled = enabled;
    }
    if (project.compaction) |compaction| {
        if (compaction.keep_recent_tokens) |tokens| settings.keep_recent_tokens = tokens;
        if (compaction.enabled) |enabled| settings.auto_enabled = enabled;
    }
    return settings;
}

fn resolveRetrySettings(snapshot: *const settings_mod.SettingsSnapshot) AgentSession.RetrySettings {
    const global = fileSettings(snapshot.global);
    const project = fileSettings(snapshot.project);
    var settings: AgentSession.RetrySettings = .{};
    if (global.retry) |retry| {
        if (retry.enabled) |enabled| settings.enabled = enabled;
        if (retry.max_retries) |attempts| settings.max_attempts = if (attempts > std.math.maxInt(u8)) std.math.maxInt(u8) else @intCast(attempts);
    }
    if (project.retry) |retry| {
        if (retry.enabled) |enabled| settings.enabled = enabled;
        if (retry.max_retries) |attempts| settings.max_attempts = if (attempts > std.math.maxInt(u8)) std.math.maxInt(u8) else @intCast(attempts);
    }
    return settings;
}

fn fileSettings(file: settings_mod.SettingsFile) settings_mod.Settings {
    return switch (file) {
        .missing => .{},
        .loaded => |settings| settings.value,
    };
}

fn parseThinkingLevel(text: []const u8) ?agent_mod.ThinkingLevel {
    if (std.ascii.eqlIgnoreCase(text, "minimal")) return .minimal;
    if (std.ascii.eqlIgnoreCase(text, "low")) return .low;
    if (std.ascii.eqlIgnoreCase(text, "medium")) return .medium;
    if (std.ascii.eqlIgnoreCase(text, "high")) return .high;
    if (std.ascii.eqlIgnoreCase(text, "xhigh")) return .xhigh;
    if (std.ascii.eqlIgnoreCase(text, "off")) return .off;
    return null;
}

test "session runtime owns services session and bounded mailboxes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    var session_runtime = try createSessionRuntime(std.testing.allocator, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .current_date = "2026-06-09",
        .session_id = "session",
        .timestamp = "2026-06-09T00:00:00Z",
        .dir = tmp.dir,
        .zio_runtime = zio_runtime,
        .command_capacity = 2,
        .event_capacity = 2,
    });
    defer session_runtime.deinit();

    try std.testing.expectEqual(@as(usize, 2), session_runtime.commands.capacity());
    try std.testing.expectEqual(@as(usize, 2), session_runtime.events.capacity());
    try std.testing.expectEqualStrings("session", session_runtime.session.manager.header.id);
}

test "session runtime drains submitted command into response event" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    var session_runtime = try createSessionRuntime(std.testing.allocator, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .current_date = "2026-06-09",
        .session_id = "session",
        .timestamp = "2026-06-09T00:00:00Z",
        .dir = tmp.dir,
        .zio_runtime = zio_runtime,
        .command_capacity = 2,
        .event_capacity = 2,
    });
    defer session_runtime.deinit();

    try session_runtime.submit(.{ .id = 1, .command = .clear_queue });
    try session_runtime.step();
    var event = session_runtime.drainEvent().?;
    defer event.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?client_protocol.RequestId, 1), event.request_id);
    try std.testing.expectEqual(client_protocol.Response.queue_cleared, event.event.response);
}
