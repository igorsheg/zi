const std = @import("std");
const agent_mod = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const paths_mod = @import("paths.zig");
const AgentSession = @import("AgentSession.zig");
const RuntimeServices = @import("runtime_services.zig").RuntimeServices;
const session_listing = @import("session_listing.zig");
const session_manager = @import("session_manager.zig");
const settings_mod = @import("settings.zig");

pub const OpenSpec = union(enum) {
    create: struct { session_id: []const u8, timestamp: []const u8 },
    resume_existing: struct { session_file_name: []const u8 },
};

pub const Overrides = struct {
    model: ?ai.Model = null,
    thinking_level: ?agent_mod.ThinkingLevel = null,
    stream: ?ai.StreamFunction = null,
};

pub fn openSession(
    allocator: std.mem.Allocator,
    services: *RuntimeServices,
    current_date: []const u8,
    spec: OpenSpec,
    overrides: Overrides,
) !AgentSession {
    const paths: paths_mod.PersistencePaths = .{ .global_dir = services.agent_dir, .cwd = services.cwd };
    const sessions_dir = try paths.sessionsDirForCwd(allocator);
    defer allocator.free(sessions_dir);

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
        .thinking_level = overrides.thinking_level orelse .off,
        .hide_thinking = project.hide_thinking_block orelse global.hide_thinking_block orelse true,
        .stream = overrides.stream orelse streamFor(services, model),
        .get_api_key = services.auth_manager.hook(),
        .dir = services.dir,
        .environ = services.environ,
        .retry_settings = retrySettings(project, global),
        .compaction_settings = compactionSettings(project, global),
        .task_runtime = services.task_runtime,
    };

    switch (spec) {
        .create => |create| {
            var store = try session_manager.SessionStore.createDeferred(allocator, services.io, services.dir, .{
                .sessions_dir = sessions_dir,
                .cwd = services.cwd,
                .session_id = create.session_id,
                .timestamp = create.timestamp,
            });
            errdefer store.deinit();
            options.session_id = create.session_id;
            options.timestamp = create.timestamp;
            options.store = .{ .create = store };
            return AgentSession.init(allocator, services.io, options);
        },
        .resume_existing => |existing| {
            const selected = try session_listing.selectRuntimeSession(allocator, services.io, .{
                .cwd = services.cwd,
                .agent_dir_override = services.agent_dir,
                .dir = services.dir,
                .environ = services.environ,
                .selector = existing.session_file_name,
            }) orelse return error.SessionNotFound;
            defer allocator.free(selected);

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

test "settings mappers prefer project over global" {
    const global: settings_mod.Settings = .{
        .retry = .{ .enabled = true, .max_retries = 9, .base_delay_ms = 10 },
        .compaction = .{ .keep_recent_tokens = 1, .reserve_tokens = 2, .enabled = false },
    };
    const project: settings_mod.Settings = .{
        .retry = .{ .enabled = false, .max_retries = 3, .base_delay_ms = 20 },
        .compaction = .{ .keep_recent_tokens = 4, .reserve_tokens = 5, .enabled = true },
    };

    const retry = retrySettings(project, global);
    try std.testing.expect(!retry.enabled);
    try std.testing.expectEqual(@as(u8, 3), retry.max_attempts);
    try std.testing.expectEqual(@as(u64, 20), retry.base_delay_ms);

    const compaction = compactionSettings(project, global);
    try std.testing.expect(compaction.auto_enabled);
    try std.testing.expectEqual(@as(u64, 4), compaction.keep_recent_tokens);
    try std.testing.expectEqual(@as(u64, 5), compaction.reserve_tokens);
}
