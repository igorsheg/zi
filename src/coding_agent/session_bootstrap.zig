const std = @import("std");
const runtime = @import("../runtime/root.zig");
const agent_mod = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const paths_mod = @import("paths.zig");
const AgentSession = @import("AgentSession.zig");
const RuntimeServices = @import("runtime_services.zig").RuntimeServices;
const session_listing = @import("session_listing.zig");
const session_manager = @import("session_manager.zig");
const settings_mod = @import("settings.zig");

pub const OpenSpec = union(enum) {
    create: struct {
        session_id: []const u8,
        timestamp: []const u8,
        persist: bool = true,
    },
    resume_existing: struct { session_file_name: []const u8 },
};

pub const Overrides = struct {
    model: ?ai.Model = null,
    thinking_level: ?agent_mod.ThinkingLevel = null,
    stream: ?ai.StreamFunction = null,
    cancel_token: ?runtime.CancelToken = null,
};

pub fn openSession(
    allocator: std.mem.Allocator,
    services: *RuntimeServices,
    current_date: []const u8,
    spec: OpenSpec,
    overrides: Overrides,
) !AgentSession {
    const snapshot = services.settings_manager.current();
    const project = settingsValue(snapshot.project);
    const global = settingsValue(snapshot.global);

    const model = overrides.model orelse resolveModel(services, project, global);
    var options: AgentSession.Options = .{
        .cwd = services.cwd,
        .agent_dir = services.agent_dir,
        .current_date = current_date,
        .session_id = "",
        .timestamp = "",
        .model = model,
        .thinking_level = overrides.thinking_level orelse resolveThinkingLevel(project, global),
        .hide_thinking = project.hide_thinking_block orelse global.hide_thinking_block orelse true,
        .openai_codex = resolveCodexOptions(project, global),
        .stream = overrides.stream orelse streamFor(services, model),
        .get_api_key = services.auth_manager.hook(),
        .dir = services.dir,
        .environ = services.environ,
        .retry_settings = retrySettings(project, global),
        .compaction_settings = compactionSettings(project, global),
        .task_runtime = services.task_runtime,
        .cancel_token = overrides.cancel_token,
    };

    switch (spec) {
        .create => |create| {
            options.session_id = create.session_id;
            options.timestamp = create.timestamp;
            if (create.persist) {
                const paths: paths_mod.PersistencePaths = .{ .global_dir = services.agent_dir, .cwd = services.cwd };
                const sessions_dir = try paths.sessionsDirForCwd(allocator);
                defer allocator.free(sessions_dir);
                var store = try session_manager.SessionStore.createDeferred(allocator, services.io, services.dir, .{
                    .sessions_dir = sessions_dir,
                    .cwd = services.cwd,
                    .session_id = create.session_id,
                    .timestamp = create.timestamp,
                });
                errdefer store.deinit();
                options.store = .{ .create = store };
            }
            return AgentSession.init(allocator, services.io, options);
        },
        .resume_existing => |existing| {
            const selected = try session_listing.selectRuntimeSession(allocator, services.io, .{
                .cwd = services.cwd,
                .agent_dir_override = services.agent_dir,
                .dir = services.dir,
                .environ = services.environ,
                .selector = existing.session_file_name,
                .cancel_token = overrides.cancel_token,
            }) orelse return error.SessionNotFound;
            defer allocator.free(selected);

            const paths: paths_mod.PersistencePaths = .{ .global_dir = services.agent_dir, .cwd = services.cwd };
            const sessions_dir = try paths.sessionsDirForCwd(allocator);
            defer allocator.free(sessions_dir);
            const file_name = try std.fs.path.join(allocator, &.{ sessions_dir, selected });
            errdefer allocator.free(file_name);
            options.store = .{ .restore = .{
                .allocator = allocator,
                .dir = services.dir,
                .file_name = file_name,
            } };
            return AgentSession.init(allocator, services.io, options);
        },
    }
}

pub fn streamFor(services: *const RuntimeServices, model: ai.Model) ?ai.StreamFunction {
    if (services.provider_registry.get(model.api)) |provider| return provider.stream_simple;
    return null;
}

fn resolveModel(
    services: *const RuntimeServices,
    project: settings_mod.Settings,
    global: settings_mod.Settings,
) ai.Model {
    const pair = if (project.default_provider != null or project.default_model != null) project else global;
    if (pair.default_provider) |provider_name| {
        if (pair.default_model) |model_id| {
            if (ai.getModel(provider_name, model_id)) |model| {
                if (services.auth_manager.hasAuth(model.provider) and
                    services.provider_registry.get(model.api) != null) return model;
            }
        }
    }
    for (ai.getProviders()) |provider_name| {
        for (ai.getModels(provider_name)) |model| {
            if (services.auth_manager.hasAuth(model.provider) and
                services.provider_registry.get(model.api) != null) return model;
        }
    }
    return agent_mod.Agent.defaultModel();
}

fn resolveThinkingLevel(project: settings_mod.Settings, global: settings_mod.Settings) agent_mod.ThinkingLevel {
    const level = project.default_thinking_level orelse global.default_thinking_level orelse return .off;
    return std.meta.stringToEnum(agent_mod.ThinkingLevel, level) orelse .off;
}

fn resolveCodexOptions(
    project: settings_mod.Settings,
    global: settings_mod.Settings,
) ai.OpenAiCodexOptions {
    const project_codex = project.codex orelse settings_mod.Settings.Codex{};
    const global_codex = global.codex orelse settings_mod.Settings.Codex{};
    const fast_mode = project_codex.fast_mode orelse global_codex.fast_mode orelse false;
    return .{
        .service_tier = if (fast_mode) .priority else null,
        .verbosity = project_codex.verbosity orelse global_codex.verbosity orelse .low,
    };
}

fn retrySettings(project: settings_mod.Settings, global: settings_mod.Settings) AgentSession.RetrySettings {
    var out: AgentSession.RetrySettings = .{};
    const retry = project.retry orelse global.retry orelse return out;
    if (retry.enabled) |enabled| out.enabled = enabled;
    if (retry.max_retries) |max| out.max_attempts = std.math.lossyCast(u8, max);
    if (retry.base_delay_ms) |delay| out.base_delay_ms = delay;
    return out;
}

fn compactionSettings(
    project: settings_mod.Settings,
    global: settings_mod.Settings,
) session_manager.CompactionSettings {
    var out: session_manager.CompactionSettings = .{};
    const compaction = project.compaction orelse global.compaction orelse return out;
    if (compaction.keep_recent_tokens) |tokens| out.keep_recent_tokens = tokens;
    if (compaction.reserve_tokens) |tokens| out.reserve_tokens = tokens;
    if (compaction.enabled) |enabled| out.auto_enabled = enabled;
    return out;
}

fn settingsValue(file: settings_mod.SettingsFile) settings_mod.Settings {
    return switch (file) {
        .missing => .{},
        .loaded => |settings| settings.value,
    };
}

test "session bootstrap applies codex settings to agent run configuration" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/.zi");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "agent/settings.json",
        .data = "{\"codex\":{\"fastMode\":true,\"verbosity\":\"high\"}}",
    });
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var services = try RuntimeServices.init(std.testing.allocator, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .dir = tmp.dir,
        .task_runtime = task_runtime,
    });
    defer services.deinit();

    const stamp = session_manager.SessionStamp.now(services.io);
    var session = try openSession(std.testing.allocator, &services, stamp.date(), .{ .create = .{
        .session_id = "codex-settings",
        .timestamp = stamp.timestamp(),
        .persist = false,
    } }, .{});
    defer {
        session.requestShutdown();
        session.deinit();
    }

    const options = session.openAiCodexOptions();
    try std.testing.expectEqual(ai.OpenAiCodexServiceTier.priority, options.service_tier.?);
    try std.testing.expectEqual(ai.TextVerbosity.high, options.verbosity);
}

test "settings mappers prefer project over global" {
    const global: settings_mod.Settings = .{
        .default_thinking_level = "low",
        .retry = .{ .enabled = true, .max_retries = 9, .base_delay_ms = 10 },
        .compaction = .{ .keep_recent_tokens = 1, .reserve_tokens = 2, .enabled = false },
    };
    const project: settings_mod.Settings = .{
        .default_thinking_level = "high",
        .retry = .{ .enabled = false, .max_retries = 3, .base_delay_ms = 20 },
        .compaction = .{ .keep_recent_tokens = 4, .reserve_tokens = 5, .enabled = true },
    };

    try std.testing.expectEqual(agent_mod.ThinkingLevel.high, resolveThinkingLevel(project, global));
    try std.testing.expectEqual(agent_mod.ThinkingLevel.low, resolveThinkingLevel(.{}, global));
    try std.testing.expectEqual(agent_mod.ThinkingLevel.off, resolveThinkingLevel(.{ .default_thinking_level = "bogus" }, global));

    const codex = resolveCodexOptions(project, global);
    try std.testing.expect(codex.service_tier == null);
    try std.testing.expectEqual(ai.TextVerbosity.low, codex.verbosity);
    const inherited_codex = resolveCodexOptions(
        .{ .codex = .{ .verbosity = .high } },
        .{ .codex = .{ .fast_mode = true, .verbosity = .medium } },
    );
    try std.testing.expectEqual(
        ai.OpenAiCodexServiceTier.priority,
        inherited_codex.service_tier.?,
    );
    try std.testing.expectEqual(ai.TextVerbosity.high, inherited_codex.verbosity);

    const retry = retrySettings(project, global);
    try std.testing.expect(!retry.enabled);
    try std.testing.expectEqual(@as(u8, 3), retry.max_attempts);
    try std.testing.expectEqual(@as(u64, 20), retry.base_delay_ms);

    const compaction = compactionSettings(project, global);
    try std.testing.expect(compaction.auto_enabled);
    try std.testing.expectEqual(@as(u64, 4), compaction.keep_recent_tokens);
    try std.testing.expectEqual(@as(u64, 5), compaction.reserve_tokens);
}
