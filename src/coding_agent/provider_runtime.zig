const std = @import("std");
const ai = @import("../ai/root.zig");
const env_api_keys = @import("../ai/env_api_keys.zig");
const agent = @import("../agent/root.zig");
const runtime_env = @import("../runtime/env.zig");
const settings_mod = @import("../settings/root.zig");
const provider_backend = @import("provider_backend.zig");
const session_mod = @import("session.zig");
const openai_completions = @import("../ai/openai/completions/provider.zig");
const openai_responses = @import("../ai/openai/responses/provider.zig");

pub const ProviderRuntime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    env: runtime_env.Env,
    openai_completions_provider: openai_completions.OpenAICompletionsProvider,
    openai_responses_provider: openai_responses.OpenAIResponsesProvider,
    static_provider: ?StaticProvider,
    settings_models: []const settings_mod.Model,
    active_provider: ?ai.provider.Provider = null,

    pub const Options = struct {
        static_provider: ?StaticProvider = null,
        settings_models: []const settings_mod.Model = &.{},
    };

    pub const StaticProvider = struct {
        model: ai.protocol.Model,
        provider: ai.provider.Provider,
        api_key: ?[]const u8 = "test-key",
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, env: runtime_env.Env) !ProviderRuntime {
        return initWithOptions(allocator, io, env, .{});
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, io: std.Io, env: runtime_env.Env, options: Options) !ProviderRuntime {
        return .{
            .allocator = allocator,
            .io = io,
            .env = env,
            .openai_completions_provider = openai_completions.OpenAICompletionsProvider.init(allocator),
            .openai_responses_provider = openai_responses.OpenAIResponsesProvider.init(allocator),
            .static_provider = options.static_provider,
            .settings_models = options.settings_models,
        };
    }

    pub fn deinit(self: *ProviderRuntime) void {
        self.* = undefined;
    }

    pub fn resolveModel(self: *ProviderRuntime, model_ref: []const u8) ?agent.message.Model {
        if (self.static_provider) |static| {
            if (std.mem.eql(u8, static.model.id, model_ref)) return static.model;
        }
        if (self.resolveSettingsModel(model_ref)) |model| return model;
        return ai.models.getModelById(model_ref) orelse ai.models.findModel(model_ref);
    }

    fn resolveSettingsModel(self: *ProviderRuntime, model_ref: []const u8) ?agent.message.Model {
        for (self.settings_models) |model| {
            if (std.mem.eql(u8, model.id, model_ref)) return settingsModelToProtocol(model);
        }
        return null;
    }

    pub fn executionBackend(self: *ProviderRuntime, model: agent.message.Model) !session_mod.AgentSession.ExecutionBackend {
        if (self.static_provider) |static| {
            if (modelsMatch(static.model, model)) {
                self.active_provider = static.provider;
                return provider_backend.synchronous(&self.active_provider.?, .{
                    .io = self.io,
                    .api_key = static.api_key,
                    .transport = .sse,
                });
            }
        }

        if (model.provider == .openrouter and model.api == .openai_completions) {
            return self.executionBackendForProvider(model, self.openai_completions_provider.provider());
        }
        if (model.provider != .openai or model.api != .openai_responses) return error.ProviderUnavailable;
        return self.executionBackendForProvider(model, self.openai_responses_provider.provider());
    }

    fn executionBackendForProvider(self: *ProviderRuntime, model: agent.message.Model, provider: ai.provider.Provider) !session_mod.AgentSession.ExecutionBackend {
        const provider_name = ai.protocol.providerToString(model.provider);
        const api_key = env_api_keys.getEnvApiKey(self.env, provider_name) orelse return error.MissingApiKey;
        self.active_provider = provider;
        return provider_backend.synchronous(&self.active_provider.?, .{
            .io = self.io,
            .api_key = api_key,
            .transport = .sse,
        });
    }
};

fn settingsModelToProtocol(model: settings_mod.Model) ai.protocol.Model {
    return .{
        .id = model.provider_model orelse model.id,
        .name = model.name orelse model.id,
        .api = ai.protocol.parseApi(model.api),
        .provider = ai.protocol.parseProvider(model.provider),
        .base_url = model.base_url orelse defaultBaseUrl(model.provider),
        .reasoning = false,
        .input = &.{.text},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = model.context_window orelse 0,
        .max_tokens = model.max_tokens orelse 0,
    };
}

fn defaultBaseUrl(provider: []const u8) []const u8 {
    if (std.mem.eql(u8, provider, "openai")) return "https://api.openai.com/v1";
    if (std.mem.eql(u8, provider, "openrouter")) return "https://openrouter.ai/api/v1";
    if (std.mem.eql(u8, provider, "anthropic")) return "https://api.anthropic.com";
    return "";
}

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

    const model = runtime.resolveModel("faux-1") orelse return error.MissingFauxModel;
    const backend = try runtime.executionBackend(model);

    const Capture = struct {
        terminal: ?coding_agent.event.RunTerminal = null,

        fn emit(event: coding_agent.event.Event, ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            switch (event) {
                .run => |run_event| switch (run_event) {
                    .finished => |finished| self.terminal = finished.terminal,
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
        .api = "openai-completions",
        .provider = "openrouter",
        .base_url = "https://openrouter.ai/api/v1",
        .provider_model = "anthropic/claude-sonnet-4",
        .context_window = 200000,
        .max_tokens = 8192,
    }};

    var runtime = try ProviderRuntime.initWithOptions(testing.allocator, testing.io, .empty, .{
        .settings_models = &models,
    });
    defer runtime.deinit();

    const model = runtime.resolveModel("openrouter/sonnet") orelse return error.MissingSettingsModel;
    try testing.expectEqualStrings("anthropic/claude-sonnet-4", model.id);
    try testing.expectEqualStrings("Sonnet via OpenRouter", model.name);
    try testing.expect(model.api == .openai_completions);
    try testing.expect(model.provider == .openrouter);
    try testing.expectEqualStrings("https://openrouter.ai/api/v1", model.base_url);
    try testing.expectEqual(@as(u64, 200000), model.context_window);
    try testing.expectEqual(@as(u64, 8192), model.max_tokens);
}
