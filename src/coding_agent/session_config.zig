const std = @import("std");
const agent_mod = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const AgentSession = @import("AgentSession.zig");
const AgentSessionRuntimeHost = @import("AgentSessionRuntimeHost.zig");
const RuntimeServices = @import("runtime_services.zig").RuntimeServices;
const session_manager = @import("session_manager.zig");
const settings_mod = @import("settings.zig");

pub const Options = struct {
    current_date: []const u8,
    model: ?ai.Model = null,
    thinking_level: ?agent_mod.ThinkingLevel = null,
    stream: ?ai.StreamFunction = null,
    dir: std.Io.Dir = .cwd(),
    allow_paths_outside_cwd: bool = false,
    public_event_capacity: usize = AgentSession.public_event_capacity_default,
};

pub fn resolve(services: *RuntimeServices, options: Options) AgentSessionRuntimeHost.BaseOptions {
    services.clearDiagnostics();
    const model = resolveModel(services, options.model);
    return .{
        .cwd = services.cwd,
        .agent_dir = services.agent_dir,
        .current_date = options.current_date,
        .model = model,
        .thinking_level = resolveThinkingLevel(services.settings_manager.current(), options.thinking_level),
        .compaction_settings = resolveCompactionSettings(services.settings_manager.current()),
        .retry_settings = resolveRetrySettings(services.settings_manager.current()),
        .stream = resolveStream(services, options.stream, model),
        .get_api_key = services.getApiKeyHook(),
        .zio_runtime = services.zio_runtime,
        .dir = options.dir,
        .allow_paths_outside_cwd = options.allow_paths_outside_cwd,
        .public_event_capacity = options.public_event_capacity,
    };
}

fn resolveStream(services: *RuntimeServices, explicit: ?ai.StreamFunction, model: ai.Model) ?ai.StreamFunction {
    if (explicit) |stream| return stream;
    const provider = services.provider_registry.get(model.api) orelse {
        if (!std.mem.eql(u8, model.api, "unknown")) {
            services.appendDiagnostic(.{ .unresolved_stream = .{ .api = model.api } });
        }
        return null;
    };
    return provider.stream_simple;
}

fn resolveModel(services: *RuntimeServices, explicit: ?ai.Model) ai.Model {
    if (explicit) |model| return model;
    if (modelSelectionFromSettings(services.settings_manager.current())) |settings| {
        if (settings.provider) |provider| {
            if (settings.model) |model_id| {
                if (services.model_registry.findAvailable(provider, model_id)) |model| return model;
            }
        }
        services.appendDiagnostic(.{ .unresolved_model_setting = .{
            .provider = settings.provider,
            .model = settings.model,
        } });
    }
    return services.model_registry.firstAvailable() orelse agent_mod.Agent.defaultModel();
}

fn resolveThinkingLevel(
    snapshot: *const settings_mod.SettingsSnapshot,
    explicit: ?agent_mod.ThinkingLevel,
) agent_mod.ThinkingLevel {
    if (explicit) |level| return level;
    const settings = thinkingLevelFromSettings(snapshot);
    if (settings.default_thinking_level) |level_text| {
        if (parseThinkingLevel(level_text)) |level| return level;
    }
    return .off;
}

const ModelSettings = struct {
    provider: ?[]const u8,
    model: ?[]const u8,
};

fn modelSelectionFromSettings(snapshot: *const settings_mod.SettingsSnapshot) ?ModelSettings {
    const global = fileSettings(snapshot.global);
    const project = fileSettings(snapshot.project);
    if (project.default_provider != null or project.default_model != null) {
        return .{ .provider = project.default_provider, .model = project.default_model };
    }
    if (global.default_provider != null or global.default_model != null) {
        return .{ .provider = global.default_provider, .model = global.default_model };
    }
    return null;
}

fn thinkingLevelFromSettings(snapshot: *const settings_mod.SettingsSnapshot) settings_mod.Settings {
    const global = fileSettings(snapshot.global);
    const project = fileSettings(snapshot.project);
    return .{ .default_thinking_level = project.default_thinking_level orelse global.default_thinking_level };
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
        if (retry.max_retries) |attempts| settings.max_attempts = boundedRetryAttempts(attempts);
    }
    if (project.retry) |retry| {
        if (retry.enabled) |enabled| settings.enabled = enabled;
        if (retry.max_retries) |attempts| settings.max_attempts = boundedRetryAttempts(attempts);
    }
    return settings;
}

fn boundedRetryAttempts(attempts: u64) u8 {
    return if (attempts > std.math.maxInt(u8)) std.math.maxInt(u8) else @intCast(attempts);
}

fn fileSettings(file: settings_mod.SettingsFile) settings_mod.Settings {
    return switch (file) {
        .missing => .{},
        .loaded => |settings| settings.value,
    };
}

fn parseThinkingLevel(text: []const u8) ?agent_mod.ThinkingLevel {
    inline for (@typeInfo(agent_mod.ThinkingLevel).@"enum".fields) |field| {
        if (std.mem.eql(u8, text, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

test "session config uses explicit model thinking and stream before settings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/.zi");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.zi/settings.json",
        .data = "{\"defaultProvider\":\"openai\",\"defaultModel\":\"gpt-5.1\",\"defaultThinkingLevel\":\"high\"}",
    });

    var services = try RuntimeServices.init(std.testing.allocator, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .dir = tmp.dir,
    });
    defer services.deinit();

    const explicit_model = ai.getModel(ai.KnownProvider.openai_codex, "gpt-5.1-codex-max").?;
    const stream: ai.StreamFunction = .{ .call_fn = testStream };
    const base = resolve(&services, .{
        .current_date = "2026-05-27",
        .model = explicit_model,
        .thinking_level = .minimal,
        .stream = stream,
        .dir = tmp.dir,
    });

    try std.testing.expectEqualStrings(explicit_model.id, base.model.id);
    try std.testing.expectEqual(agent_mod.ThinkingLevel.minimal, base.thinking_level);
    try std.testing.expect(base.stream != null);
}

test "session config uses project settings before global settings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("OPENAI_API_KEY", "secret");

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/.zi");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "agent/settings.json",
        .data = "{\"defaultProvider\":\"openai\",\"defaultModel\":\"gpt-5.1\",\"defaultThinkingLevel\":\"low\"}",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.zi/settings.json",
        .data = "{\"defaultProvider\":\"openai\",\"defaultModel\":\"gpt-5.1\"," ++
            "\"defaultThinkingLevel\":\"xhigh\"}",
    });

    var services = try RuntimeServices.init(std.testing.allocator, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .dir = tmp.dir,
        .environ = &environ,
    });
    defer services.deinit();

    const base = resolve(&services, .{ .current_date = "2026-05-27", .dir = tmp.dir });

    try std.testing.expectEqualStrings("gpt-5.1", base.model.id);
    try std.testing.expectEqual(agent_mod.ThinkingLevel.xhigh, base.thinking_level);
    try std.testing.expect(base.stream != null);
    try std.testing.expectEqual(@as(usize, 0), services.diagnosticSlice().len);
}

test "session config uses project compaction and retry settings before global settings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/.zi");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "agent/settings.json",
        .data = "{\"compaction\":{\"keepRecentTokens\":111,\"enabled\":true}," ++
            "\"retry\":{\"enabled\":false,\"maxRetries\":1}}",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.zi/settings.json",
        .data = "{\"compaction\":{\"keepRecentTokens\":222,\"enabled\":false}," ++
            "\"retry\":{\"enabled\":true,\"maxRetries\":2}}",
    });

    var services = try RuntimeServices.init(std.testing.allocator, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .dir = tmp.dir,
    });
    defer services.deinit();

    const base = resolve(&services, .{ .current_date = "2026-05-27", .dir = tmp.dir });

    try std.testing.expectEqual(@as(u64, 222), base.compaction_settings.keep_recent_tokens);
    try std.testing.expect(!base.compaction_settings.auto_enabled);
    try std.testing.expect(base.retry_settings.enabled);
    try std.testing.expectEqual(@as(u8, 2), base.retry_settings.max_attempts);
}

test "session config keeps provider and model settings scope atomic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("OPENAI_API_KEY", "secret");

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/.zi");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "agent/settings.json",
        .data = "{\"defaultProvider\":\"openai\",\"defaultModel\":\"gpt-5.1\"}",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.zi/settings.json",
        .data = "{\"defaultModel\":\"gpt-5.1-codex-max\"}",
    });

    var services = try RuntimeServices.init(std.testing.allocator, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .dir = tmp.dir,
        .environ = &environ,
    });
    defer services.deinit();

    const base = resolve(&services, .{ .current_date = "2026-05-27", .dir = tmp.dir });

    try std.testing.expectEqualStrings(ai.KnownProvider.openai, base.model.provider);
    try std.testing.expectEqual(@as(usize, 1), services.diagnosticSlice().len);
    try std.testing.expect(services.diagnosticSlice()[0] == .unresolved_model_setting);
}

test "session config falls back when settings are absent or unresolved" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/.zi");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "agent/settings.json",
        .data = "{\"defaultProvider\":\"missing\",\"defaultModel\":\"missing\",\"defaultThinkingLevel\":\"nope\"}",
    });

    var services = try RuntimeServices.init(std.testing.allocator, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .dir = tmp.dir,
    });
    defer services.deinit();

    const base = resolve(&services, .{ .current_date = "2026-05-27", .dir = tmp.dir });
    const default_model = agent_mod.Agent.defaultModel();

    try std.testing.expectEqualStrings(default_model.id, base.model.id);
    try std.testing.expectEqual(agent_mod.ThinkingLevel.off, base.thinking_level);
    try std.testing.expect(base.stream == null);
    try std.testing.expectEqual(@as(usize, 1), services.diagnosticSlice().len);
    try std.testing.expect(services.diagnosticSlice()[0] == .unresolved_model_setting);
}

test "session config exposes auth hook from runtime services" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("OPENAI_API_KEY", "secret");

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/.zi");

    var services = try RuntimeServices.init(std.testing.allocator, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .dir = tmp.dir,
        .environ = &environ,
    });
    defer services.deinit();

    const base = resolve(&services, .{ .current_date = "2026-05-27", .dir = tmp.dir });
    const key = try agent_mod.GetApiKeyHook.call(std.testing.allocator, base.get_api_key.?, ai.KnownProvider.openai);
    defer std.testing.allocator.free(key.?);

    try std.testing.expectEqualStrings("secret", key.?);
}

test "session config skips unauthed codex settings and falls back to available model" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/.zi");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.zi/settings.json",
        .data = "{\"defaultProvider\":\"openai-codex\",\"defaultModel\":\"gpt-5.1-codex-max\"}",
    });

    var services = try RuntimeServices.init(std.testing.allocator, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .dir = tmp.dir,
    });
    defer services.deinit();

    const base = resolve(&services, .{ .current_date = "2026-05-27", .dir = tmp.dir });

    try std.testing.expectEqualStrings("unknown", base.model.id);
    try std.testing.expect(base.stream == null);
    try std.testing.expectEqual(@as(usize, 1), services.diagnosticSlice().len);
    try std.testing.expect(services.diagnosticSlice()[0] == .unresolved_model_setting);
}

test "session config resolves codex settings when oauth credentials are stored" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/.zi");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "agent/auth.json",
        .data =
        \\{"openai-codex":{"type":"oauth","refresh":"refresh-token","access":"access-token","expires":123}}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.zi/settings.json",
        .data = "{\"defaultProvider\":\"openai-codex\",\"defaultModel\":\"gpt-5.1-codex-max\"}",
    });

    var services = try RuntimeServices.init(std.testing.allocator, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .dir = tmp.dir,
    });
    defer services.deinit();

    const base = resolve(&services, .{ .current_date = "2026-05-27", .dir = tmp.dir });

    try std.testing.expectEqualStrings("gpt-5.1-codex-max", base.model.id);
    try std.testing.expect(base.stream != null);
    try std.testing.expectEqual(@as(usize, 0), services.diagnosticSlice().len);
}

fn testStream(_: ?*anyopaque, request: ai.StreamRequest) ai.AssistantMessageEventStream {
    _ = request;
    return ai.AssistantMessageEventStream.initBuffered();
}
