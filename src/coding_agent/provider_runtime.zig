const std = @import("std");
const ai = @import("../ai/root.zig");
const env_api_keys = @import("../ai/env_api_keys.zig");
const agent = @import("../agent/root.zig");
const runtime_env = @import("../runtime/env.zig");
const provider_backend = @import("provider_backend.zig");
const session_mod = @import("session.zig");
const openai_responses = @import("../ai/openai/responses/provider.zig");

pub const ProviderRuntime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    env: runtime_env.Env,
    openai_responses_provider: openai_responses.OpenAIResponsesProvider,
    static_provider: ?StaticProvider,
    active_provider: ?ai.provider.Provider = null,

    pub const Options = struct {
        static_provider: ?StaticProvider = null,
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
            .openai_responses_provider = openai_responses.OpenAIResponsesProvider.init(allocator),
            .static_provider = options.static_provider,
        };
    }

    pub fn deinit(self: *ProviderRuntime) void {
        self.* = undefined;
    }

    pub fn resolveModel(self: *ProviderRuntime, model_ref: []const u8) ?agent.message.Model {
        if (self.static_provider) |static| {
            if (std.mem.eql(u8, static.model.id, model_ref)) return static.model;
        }
        return ai.models.getModelById(model_ref) orelse ai.models.findModel(model_ref);
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

        if (model.provider != .openai or model.api != .openai_responses) return error.ProviderUnavailable;
        const provider_name = ai.protocol.providerToString(model.provider);
        const api_key = env_api_keys.getEnvApiKey(self.env, provider_name) orelse return error.MissingApiKey;
        self.active_provider = self.openai_responses_provider.provider();
        return provider_backend.synchronous(&self.active_provider.?, .{
            .io = self.io,
            .api_key = api_key,
            .transport = .sse,
        });
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
