const std = @import("std");
const agent_mod = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const runtime = @import("../runtime/root.zig");
const AgentSession = @import("AgentSession.zig");
const auth_mod = @import("auth.zig");
const session_manager = @import("session_manager.zig");
const session_store = @import("session_store.zig");
const paths_mod = @import("paths.zig");
const settings_mod = @import("settings.zig");

pub const RuntimeServices = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    zio_runtime: *runtime.Runtime,
    zio_runtime_owner: RuntimeOwner,
    cwd: []const u8,
    agent_dir: []const u8,
    settings_manager: settings_mod.SettingsManager,
    auth_manager: *auth_mod.AuthManager,
    provider_registry: ai.ProviderRegistry,
    environ: ?*const std.process.Environ.Map,
    openai_provider: *ai.OpenAiResponsesProvider,
    openai_codex_provider: *ai.OpenAiCodexResponsesProvider,
    diagnostics: [diagnostic_capacity]Diagnostic = undefined,
    diagnostic_count: usize = 0,

    const Options = struct {
        cwd: []const u8,
        agent_dir: []const u8,
        dir: std.Io.Dir = .cwd(),
        environ: ?*const std.process.Environ.Map = null,
        zio_runtime: ?*runtime.Runtime = null,
    };

    const RuntimeOwner = enum {
        owned,
        borrowed,
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) !RuntimeServices {
        const cwd = try allocator.dupe(u8, options.cwd);
        errdefer allocator.free(cwd);
        const agent_dir = try allocator.dupe(u8, options.agent_dir);
        errdefer allocator.free(agent_dir);
        const zio_runtime = options.zio_runtime orelse try runtime.Runtime.init(allocator, .{});
        errdefer if (options.zio_runtime == null) zio_runtime.deinit();
        const io = zio_runtime.io();

        const resource_paths: paths_mod.PersistencePaths = .{ .global_dir = agent_dir, .cwd = cwd };
        var settings_manager = try settings_mod.SettingsManager.init(allocator, io, .{
            .paths = resource_paths,
            .dir = options.dir,
        });
        errdefer settings_manager.deinit();

        const auth_manager = try allocator.create(auth_mod.AuthManager);
        errdefer allocator.destroy(auth_manager);
        auth_manager.* = try auth_mod.AuthManager.init(allocator, io, .{
            .environ = options.environ,
            .paths = resource_paths,
            .dir = options.dir,
        });
        errdefer auth_manager.deinit();

        const openai_provider = try allocator.create(ai.OpenAiResponsesProvider);
        errdefer allocator.destroy(openai_provider);
        openai_provider.* = ai.OpenAiResponsesProvider.init(.{});

        const openai_codex_provider = try allocator.create(ai.OpenAiCodexResponsesProvider);
        errdefer allocator.destroy(openai_codex_provider);
        openai_codex_provider.* = ai.OpenAiCodexResponsesProvider.init(.{});

        var provider_registry = ai.ProviderRegistry.init(allocator);
        errdefer provider_registry.deinit();
        try openai_provider.register(&provider_registry);
        try openai_codex_provider.register(&provider_registry);

        return .{
            .allocator = allocator,
            .io = io,
            .zio_runtime = zio_runtime,
            .zio_runtime_owner = if (options.zio_runtime == null) .owned else .borrowed,
            .cwd = cwd,
            .agent_dir = agent_dir,
            .settings_manager = settings_manager,
            .auth_manager = auth_manager,
            .provider_registry = provider_registry,
            .environ = options.environ,
            .openai_provider = openai_provider,
            .openai_codex_provider = openai_codex_provider,
        };
    }

    const diagnostic_capacity = 8;

    const Diagnostic = union(enum) {
        unresolved_model_setting: ModelSetting,
        unresolved_stream: StreamSetting,

        const ModelSetting = struct {
            provider: ?[]const u8,
            model: ?[]const u8,
        };

        const StreamSetting = struct {
            api: []const u8,
        };
    };

    fn findAvailableModel(self: *const RuntimeServices, provider: ai.Provider, model_id: []const u8) ?ai.Model {
        const model = ai.getModel(provider, model_id) orelse return null;
        return if (self.auth_manager.hasAuth(model.provider)) model else null;
    }

    fn firstAvailableModel(self: *const RuntimeServices) ?ai.Model {
        for (ai.getProviders()) |provider| {
            for (ai.getModels(provider)) |model| {
                if (self.auth_manager.hasAuth(model.provider)) return model;
            }
        }
        return null;
    }

    pub fn deinit(self: *RuntimeServices) void {
        self.provider_registry.deinit();
        switch (self.zio_runtime_owner) {
            .owned => self.zio_runtime.deinit(),
            .borrowed => {},
        }
        self.allocator.destroy(self.openai_codex_provider);
        self.allocator.destroy(self.openai_provider);
        self.auth_manager.deinit();
        self.allocator.destroy(self.auth_manager);
        self.settings_manager.deinit();
        self.allocator.free(self.agent_dir);
        self.allocator.free(self.cwd);
        self.* = undefined;
    }
};

const CreateSessionRuntimeOptions = struct {
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
};

const ResumeSessionRuntimeOptions = struct {
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
};

pub const SessionRuntime = struct {
    services: RuntimeServices,
    session: AgentSession,

    pub fn deinit(self: *SessionRuntime) void {
        shutdownAndDeinitSession(&self.session);
        self.services.deinit();
        self.* = undefined;
    }
};

pub fn createSessionRuntime(allocator: std.mem.Allocator, options: CreateSessionRuntimeOptions) !SessionRuntime {
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
    return .{ .services = init_result.services, .session = session };
}

pub fn resumeSessionRuntime(allocator: std.mem.Allocator, options: ResumeSessionRuntimeOptions) !SessionRuntime {
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
    return .{ .services = init_result.services, .session = session };
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
    session.requestShutdown();
    while (session.drainPublicEvent()) |event| {
        var owned_event = event;
        owned_event.deinit();
    }
    session.deinit();
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
        if (!std.mem.eql(u8, model.api, "unknown") and services.diagnostic_count < RuntimeServices.diagnostic_capacity) {
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
            if (services.findAvailableModel(provider_name, id)) |model| return model;
        };
        if (services.diagnostic_count < RuntimeServices.diagnostic_capacity) {
            services.diagnostics[services.diagnostic_count] = .{ .unresolved_model_setting = .{ .provider = provider, .model = model_id } };
            services.diagnostic_count += 1;
        }
    }
    return services.firstAvailableModel() orelse agent_mod.Agent.defaultModel();
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

test "runtime services owns stable cwd, agent dir, settings manager" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/.zi");

    var services = try RuntimeServices.init(std.testing.allocator, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .dir = tmp.dir,
    });
    defer services.deinit();

    try std.testing.expectEqualStrings("repo", services.cwd);
    try std.testing.expectEqualStrings("agent", services.agent_dir);
    try std.testing.expectEqualStrings("repo", services.cwd);
    try std.testing.expectEqualStrings("agent", services.agent_dir);
    try std.testing.expect(services.provider_registry.get(ai.KnownApi.openai_responses) != null);
    try std.testing.expect(services.provider_registry.get(ai.KnownApi.openai_codex_responses) != null);
}

test "runtime services can borrow process zio runtime" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/.zi");

    var services = try RuntimeServices.init(std.testing.allocator, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .dir = tmp.dir,
        .zio_runtime = zio_runtime,
    });
    defer services.deinit();

    try std.testing.expect(services.zio_runtime == zio_runtime);
    try std.testing.expectEqual(RuntimeServices.RuntimeOwner.borrowed, services.zio_runtime_owner);
}
