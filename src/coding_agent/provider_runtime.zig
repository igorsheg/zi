const std = @import("std");
const ai = @import("../ai/root.zig");
const env_api_keys = @import("../ai/env_api_keys.zig");
const provider_defaults = @import("../ai/provider_defaults.zig");
const agent = @import("../agent/root.zig");
const runtime_env = @import("../runtime/env.zig");
const settings_mod = @import("../settings/root.zig");

pub const ProviderRuntime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    env: runtime_env.Env,
    provider_bundle: *provider_defaults.Bundle,
    static_provider: ?StaticProvider,
    settings_models: []const settings_mod.Model,

    pub const Options = struct {
        static_provider: ?StaticProvider = null,
        settings_models: []const settings_mod.Model = &.{},
    };

    pub const StaticProvider = struct {
        model: ai.protocol.Model,
        provider: ai.provider.Provider,
        api_key: ?[]const u8 = "test-key",
    };

    pub const ResolveModelResult = union(enum) {
        ok: agent.message.Model,
        unknown_model,
        invalid_settings_model: settings_mod.resolve.Diagnostic,
    };

    pub const ResolvedProvider = struct {
        provider: ai.provider.Provider,
        api_key: ?[]const u8,
        transport: ?ai.protocol.Transport = .sse,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, env: runtime_env.Env) !ProviderRuntime {
        return initWithOptions(allocator, io, env, .{});
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, io: std.Io, env: runtime_env.Env, options: Options) !ProviderRuntime {
        return .{
            .allocator = allocator,
            .io = io,
            .env = env,
            .provider_bundle = try provider_defaults.Bundle.init(allocator),
            .static_provider = options.static_provider,
            .settings_models = options.settings_models,
        };
    }

    pub fn deinit(self: *ProviderRuntime) void {
        self.provider_bundle.deinit();
        self.* = undefined;
    }

    pub fn resolveModel(self: *ProviderRuntime, model_ref: []const u8) ResolveModelResult {
        if (self.static_provider) |static| {
            if (std.mem.eql(u8, static.model.id, model_ref)) return .{ .ok = static.model };
        }
        if (self.resolveSettingsModel(model_ref)) |result| return result;
        if (ai.models.getModelById(model_ref) orelse ai.models.findModel(model_ref)) |model| return .{ .ok = model };
        return .unknown_model;
    }

    fn resolveSettingsModel(self: *ProviderRuntime, model_ref: []const u8) ?ResolveModelResult {
        for (self.settings_models) |model| {
            if (std.mem.eql(u8, model.id, model_ref)) return switch (settings_mod.resolve.modelToProtocol(model)) {
                .ok => |resolved| .{ .ok = resolved },
                .err => |diag| .{ .invalid_settings_model = diag },
            };
        }
        return null;
    }

    pub fn resolveProvider(self: *ProviderRuntime, model: agent.message.Model) !ResolvedProvider {
        if (self.static_provider) |static| {
            if (modelsMatch(static.model, model)) {
                return .{ .provider = static.provider, .api_key = static.api_key };
            }
        }

        const api = ai.protocol.apiToString(model.api);
        const provider_name = ai.protocol.providerToString(model.provider);
        const provider = self.provider_bundle.registry.getForModel(api, provider_name) orelse return error.ProviderUnavailable;
        const api_key = env_api_keys.getEnvApiKey(self.env, provider_name) orelse return error.MissingApiKey;
        return .{ .provider = provider, .api_key = api_key };
    }
};

fn modelsMatch(a: ai.protocol.Model, b: ai.protocol.Model) bool {
    return std.mem.eql(u8, a.id, b.id) and std.meta.eql(a.provider, b.provider) and std.meta.eql(a.api, b.api);
}

const testing = std.testing;

test "provider runtime can drive AgentSession through faux provider" {
    const coding_agent = @import("root.zig");

    var faux = ai.faux.FauxProvider.init(testing.allocator);
    defer faux.deinit();

    const content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{ai.faux.fauxText("faux runtime response")};
    const assistant = ai.faux.fauxAssistantMessage(testing.allocator, testing.io, &content, .stop);
    defer testing.allocator.free(assistant.content);
    faux.setResponses(&.{assistant});

    var runtime = try ProviderRuntime.initWithOptions(testing.allocator, testing.io, .empty, .{
        .static_provider = .{
            .model = ai.faux.fauxModel(),
            .provider = faux.provider(),
            .api_key = "faux-key",
        },
    });
    defer runtime.deinit();

    const model = switch (runtime.resolveModel("faux-1")) {
        .ok => |model| model,
        else => return error.MissingFauxModel,
    };
    const resolved_provider = try runtime.resolveProvider(model);
    var provider = resolved_provider.provider;
    const backend = coding_agent.provider_backend.synchronous(&provider, .{ .io = testing.io, .api_key = resolved_provider.api_key, .transport = resolved_provider.transport });

    const Capture = struct {
        terminal: ?agent.event.RunTerminal = null,

        fn emit(event: coding_agent.event.Event, ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            switch (event) {
                .agent => |agent_event| switch (agent_event) {
                    .lifecycle => |lifecycle| switch (lifecycle) {
                        .run_finished => |terminal| self.terminal = terminal,
                        else => {},
                    },
                    else => {},
                },
                else => {},
            }
        }
    };

    var capture = Capture{};
    var session = try coding_agent.AgentSession.init(testing.allocator, .{
        .event_sink = .{ .emit_fn = Capture.emit, .ctx = &capture },
        .extension_host = coding_agent.extension.Host.disabled,
        .policy = .{ .model = model },
        .execution = .{ .synchronous = backend },
    });
    defer session.deinit();

    const user = agent.AgentMessage{ .user = .{ .content = .{ .text = "hello" }, .timestamp = 0 } };
    const submit = try session.submit(.{ .submit_prompt = .{ .messages = &.{user} } });
    try testing.expect(submit == .accepted);
    session.drainCommands();

    switch (capture.terminal orelse return error.NoTerminal) {
        .completed => {},
        else => return error.NotCompleted,
    }
    try testing.expectEqual(@as(usize, 1), faux.call_count);
}

test "provider runtime resolves settings model before builtins" {
    const models = [_]settings_mod.Model{.{
        .id = "openrouter/sonnet",
        .name = "Sonnet via OpenRouter",
        .provider = "openrouter",
        .api = "openai-completions",
        .provider_model = "anthropic/claude-sonnet-4.5",
    }};
    var runtime = try ProviderRuntime.initWithOptions(testing.allocator, testing.io, .empty, .{ .settings_models = &models });
    defer runtime.deinit();

    const model = switch (runtime.resolveModel("openrouter/sonnet")) {
        .ok => |model| model,
        else => return error.ExpectedSettingsModel,
    };

    try testing.expectEqualStrings("openrouter/sonnet", model.id);
    try testing.expectEqualStrings("anthropic/claude-sonnet-4.5", model.provider_model.?);
    try testing.expectEqual(ai.protocol.Provider.openrouter, model.provider);
}
