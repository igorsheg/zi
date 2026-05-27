const std = @import("std");
const agent_mod = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const AgentSession = @import("AgentSession.zig");
const AgentSessionRuntimeHost = @import("AgentSessionRuntimeHost.zig");
const RuntimeServices = @import("runtime_services.zig").RuntimeServices;
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

pub fn resolve(services: *const RuntimeServices, options: Options) AgentSessionRuntimeHost.BaseOptions {
    const model = resolveModel(services.settings_manager.current(), options.model);
    return .{
        .cwd = services.cwd,
        .agent_dir = services.agent_dir,
        .current_date = options.current_date,
        .model = model,
        .thinking_level = resolveThinkingLevel(services.settings_manager.current(), options.thinking_level),
        .stream = resolveStream(services, options.stream, model),
        .dir = options.dir,
        .allow_paths_outside_cwd = options.allow_paths_outside_cwd,
        .public_event_capacity = options.public_event_capacity,
    };
}

fn resolveStream(services: *const RuntimeServices, explicit: ?ai.StreamFunction, model: ai.Model) ?ai.StreamFunction {
    if (explicit) |stream| return stream;
    const provider = services.provider_registry.get(model.api) orelse return null;
    return provider.stream_simple;
}

fn resolveModel(snapshot: *const settings_mod.SettingsSnapshot, explicit: ?ai.Model) ai.Model {
    if (explicit) |model| return model;
    if (effectiveModelSettings(snapshot)) |settings| {
        if (settings.provider) |provider| {
            if (settings.model) |model_id| {
                if (ai.getModel(provider, model_id)) |model| return model;
            }
        }
    }
    return agent_mod.Agent.defaultModel();
}

fn resolveThinkingLevel(
    snapshot: *const settings_mod.SettingsSnapshot,
    explicit: ?agent_mod.ThinkingLevel,
) agent_mod.ThinkingLevel {
    if (explicit) |level| return level;
    const settings = effectiveThinkingSettings(snapshot);
    if (settings.default_thinking_level) |level_text| {
        if (parseThinkingLevel(level_text)) |level| return level;
    }
    return .off;
}

const ModelSettings = struct {
    provider: ?[]const u8,
    model: ?[]const u8,
};

fn effectiveModelSettings(snapshot: *const settings_mod.SettingsSnapshot) ?ModelSettings {
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

fn effectiveThinkingSettings(snapshot: *const settings_mod.SettingsSnapshot) settings_mod.Settings {
    const global = fileSettings(snapshot.global);
    const project = fileSettings(snapshot.project);
    return .{ .default_thinking_level = project.default_thinking_level orelse global.default_thinking_level };
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

    var services = try RuntimeServices.init(std.testing.allocator, std.testing.io, .{
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

    var services = try RuntimeServices.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .dir = tmp.dir,
    });
    defer services.deinit();

    const base = resolve(&services, .{ .current_date = "2026-05-27", .dir = tmp.dir });

    try std.testing.expectEqualStrings("gpt-5.1", base.model.id);
    try std.testing.expectEqual(agent_mod.ThinkingLevel.xhigh, base.thinking_level);
    try std.testing.expect(base.stream != null);
}

test "session config keeps provider and model settings scope atomic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

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

    var services = try RuntimeServices.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .dir = tmp.dir,
    });
    defer services.deinit();

    const base = resolve(&services, .{ .current_date = "2026-05-27", .dir = tmp.dir });
    const default_model = agent_mod.Agent.defaultModel();

    try std.testing.expectEqualStrings(default_model.id, base.model.id);
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

    var services = try RuntimeServices.init(std.testing.allocator, std.testing.io, .{
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
}

fn testStream(_: ?*anyopaque, request: ai.StreamRequest) ai.AssistantMessageEventStream {
    return ai.AssistantMessageEventStream.init(request.event_buffer);
}
