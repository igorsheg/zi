const std = @import("std");
const ai = @import("ai/root.zig");
const auth = @import("auth/root.zig");
const settings_mod = @import("settings/root.zig");
const agent = @import("agent/root.zig");
const session = @import("session/root.zig");
const bash_tool = @import("tools/bash.zig");

const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    // Arena allocator for the entire run. No explicit frees needed in print mode.
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var print_mode = false;
    var show_help = false;
    var show_version = false;
    var api_key_arg: ?[]const u8 = null;
    var model_id: ?[]const u8 = null;
    var list_models = false;
    var prompt_text: ?[]const u8 = null;

    var args = std.process.args();
    _ = args.next();
    while (args.next()) |arg| {
        if (eql(arg, "-p") or eql(arg, "--print")) {
            print_mode = true;
        } else if (eql(arg, "-h") or eql(arg, "--help")) {
            show_help = true;
        } else if (eql(arg, "-v") or eql(arg, "--version")) {
            show_version = true;
        } else if (eql(arg, "--api-key")) {
            api_key_arg = args.next();
        } else if (eql(arg, "--model")) {
            if (args.next()) |m| model_id = m;
        } else if (eql(arg, "--list-models")) {
            list_models = true;
        } else if (arg.len > 0 and arg[0] != '-') {
            prompt_text = arg;
        }
    }

    if (show_version) {
        try stdout.writeAll("zi v0.0.1\n");
        return;
    }
    if (show_help) {
        try stdout.writeAll(
            \\zi — AI coding agent
            \\
            \\Usage: zi [options] [message]
            \\
            \\Options:
            \\  -p, --print           Non-interactive mode
            \\  --model <id>          Model ID or pattern (default: from settings or claude-sonnet-4)
            \\  --api-key <key>       API key override (also reads ~/.pi/agent/auth.json)
            \\  --list-models         List available models
            \\  -h, --help            Show help
            \\  -v, --version         Show version
            \\
        );
        return;
    }

    if (list_models) {
        const all = ai.models.getAllModels();
        for (all) |m| {
            stdout.writeAll(ai.provider.apiToString(m.api)) catch {};
            stdout.writeAll("\t") catch {};
            stdout.writeAll(m.id) catch {};
            stdout.writeAll("\t") catch {};
            stdout.writeAll(m.name) catch {};
            stdout.writeAll("\n") catch {};
        }
        return;
    }

    if (print_mode or prompt_text != null) {
        const prompt = prompt_text orelse {
            try stderr.writeAll("error: no prompt provided\n");
            std.process.exit(1);
        };

        // Auth + settings — reads ~/.pi/agent/auth.json and settings.json
        var auth_storage = auth.storage.AuthStorage.create(allocator, null) catch {
            try stderr.writeAll("warning: could not load auth storage\n");
            unreachable;
        };
        _ = &auth_storage;

        const cwd_buf = std.fs.cwd().realpathAlloc(allocator, ".") catch "/unknown";
        var settings = settings_mod.manager.SettingsManager.create(allocator, cwd_buf, null) catch {
            try stderr.writeAll("warning: could not load settings\n");
            unreachable;
        };
        _ = &settings;

        // Resolve model: --model flag → settings default → first authed provider default
        // pi-mono: model-resolver.ts:474-554
        const model = resolveModel(model_id, &settings, &auth_storage) orelse {
            try stderr.writeAll("error: no model found. run `pi login` or set an API key env var.\n");
            try stderr.writeAll("use --list-models to see available models\n");
            std.process.exit(1);
        };

        // Only anthropic provider implemented for now
        if (!std.meta.eql(model.api, .anthropic_messages)) {
            try stderr.writeAll("error: only anthropic models supported currently. model '");
            try stderr.writeAll(model.id);
            try stderr.writeAll("' uses api '");
            try stderr.writeAll(ai.provider.apiToString(model.api));
            try stderr.writeAll("'\n");
            std.process.exit(1);
        }

        // Resolve API key: --api-key flag is tier 1 (runtime override),
        // then auth.json, oauth tokens, env vars via AuthStorage.getApiKey
        const provider_str = ai.json_util.providerToString(model.provider);
        if (api_key_arg) |cli_key| {
            auth_storage.setRuntimeApiKey(provider_str, cli_key);
        }
        const key = auth_storage.getApiKey(provider_str) orelse {
            try stderr.writeAll("error: no API key for provider '");
            try stderr.writeAll(provider_str);
            try stderr.writeAll("'. run `pi login` or set ");
            const env_hint = ai.env_api_keys.getEnvApiKey(provider_str);
            if (env_hint == null) {
                // Show the env var name they could set
                if (std.mem.eql(u8, provider_str, "anthropic")) {
                    try stderr.writeAll("ANTHROPIC_API_KEY");
                } else {
                    try stderr.writeAll("the provider's API key env var");
                }
            }
            try stderr.writeAll("\n");
            std.process.exit(1);
        };

        var anthropic_prov = ai.anthropic.AnthropicProvider.init(allocator);
        const prov = anthropic_prov.provider();

        var registry = ai.provider.Registry.init(allocator);
        defer registry.deinit();
        try registry.register("anthropic-messages", prov, null);

        const user_msg = agent.protocol.AgentMessage{
            .user = .{
                .content = .{ .text = prompt },
                .timestamp = std.time.milliTimestamp(),
            },
        };

        // Build tools
        const tools = [_]agent.protocol.AgentTool{
            bash_tool.makeTool(),
        };

        // Session writer — persists messages incrementally on message_end,
        // gated on first assistant message (matches pi-mono behavior).
        var sw = session.writer.SessionWriter.init(allocator, cwd_buf);

        var handler = PrintSessionHandler{ .session_writer = &sw };

        const prompts = [_]agent.protocol.AgentMessage{user_msg};
        const context = agent.protocol.AgentContext{
            .system_prompt = "You are a helpful assistant. Be concise. You have access to a bash tool to execute commands.",
            .messages = &.{},
            .tools = &tools,
        };

        // Wrap registry stream into a StreamHook
        const RegistryStream = struct {
            fn streamFn(
                ctx: ?*anyopaque,
                stream_alloc: std.mem.Allocator,
                stream_model: ai.protocol.Model,
                stream_context: ai.protocol.Context,
                options: ai.protocol.SimpleStreamOptions,
                callback: ai.provider.EventCallback,
                callback_ctx: ?*anyopaque,
            ) void {
                const reg: *ai.provider.Registry = @ptrCast(@alignCast(ctx.?));
                const api_str = ai.provider.apiToString(stream_model.api);
                const prov2 = reg.get(api_str) orelse return;
                prov2.streamSimple(stream_alloc, stream_model, stream_context, options, callback, callback_ctx);
            }
        };

        const config = agent.protocol.AgentLoopConfig{
            .model = model,
            .stream = .{ .func = RegistryStream.streamFn, .ctx = @ptrCast(&registry) },
            .convert_to_llm = agent.defaultConvertToLlmHook(),
            .api_key = key,
            .max_tokens = 4096,
        };

        agent.loop.runAgentLoop(
            allocator,
            &prompts,
            context,
            config,
            &PrintSessionHandler.callback,
            @ptrCast(&handler),
            null,
        );

        try stdout.writeAll("\n");

        if (sw.flushed) {
            stderr.writeAll("session: ") catch {};
            stderr.writeAll(sw.session_file) catch {};
            stderr.writeAll("\n") catch {};
        }
    } else {
        try stderr.writeAll("error: interactive mode not yet implemented. use -p flag.\n");
        std.process.exit(1);
    }
}

/// Event handler: prints to stdout/stderr AND persists messages on message_end.
const PrintSessionHandler = struct {
    session_writer: *session.writer.SessionWriter,

    fn callback(event: agent.protocol.AgentEvent, ctx: ?*anyopaque) void {
        const self: *PrintSessionHandler = @ptrCast(@alignCast(ctx));
        switch (event) {
            .message_update => |mu| {
                switch (mu.assistant_message_event) {
                    .text_delta => |d| stdout.writeAll(d.delta) catch {},
                    .@"error" => |e| {
                        if (e.@"error".error_message) |msg| {
                            stderr.writeAll("\nerror: ") catch {};
                            stderr.writeAll(msg) catch {};
                            stderr.writeAll("\n") catch {};
                        }
                    },
                    else => {},
                }
            },
            .tool_execution_start => |te| {
                stderr.writeAll("⚡ ") catch {};
                stderr.writeAll(te.tool_name) catch {};
                stderr.writeAll("\n") catch {};
            },
            .message_end => |me| {
                self.session_writer.appendMessage(me.message);
            },
            else => {},
        }
    }
};


fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Resolve model matching pi-mono's findInitialModel priority:
/// 1. --model CLI flag (exact or fuzzy match)
/// 2. settings.json defaultProvider + defaultModel
/// 3. first authed provider's default model (from defaultModelPerProvider)
/// 4. first model in catalog where auth is available
/// pi-mono: model-resolver.ts:474-554
fn resolveModel(
    cli_model: ?[]const u8,
    settings: *settings_mod.manager.SettingsManager,
    auth_storage: *auth.storage.AuthStorage,
) ?ai.protocol.Model {
    // 1. CLI flag
    if (cli_model) |id| {
        return ai.models.getModelById(id) orelse ai.models.findModel(id);
    }

    // 2. Settings default
    if (settings.getDefaultModel()) |model_id| {
        if (ai.models.getModelById(model_id) orelse ai.models.findModel(model_id)) |m| {
            return m;
        }
    }

    // 3. Default model per provider, for providers with auth
    // pi-mono: model-resolver.ts:540-546
    for (default_models_per_provider) |entry| {
        if (auth_storage.hasAuth(entry.provider)) {
            if (ai.models.getModelById(entry.model_id)) |m| return m;
        }
    }

    // 4. First model in catalog where auth exists
    for (ai.models.getAllModels()) |m| {
        const provider_str = ai.json_util.providerToString(m.provider);
        if (auth_storage.hasAuth(provider_str)) return m;
    }

    return null;
}

/// pi-mono: model-resolver.ts:14-38
const ProviderDefault = struct { provider: []const u8, model_id: []const u8 };
const default_models_per_provider = [_]ProviderDefault{
    .{ .provider = "anthropic", .model_id = "claude-sonnet-4-20250514" },
    .{ .provider = "openai", .model_id = "gpt-5.4" },
    .{ .provider = "google", .model_id = "gemini-2.5-pro" },
    .{ .provider = "amazon-bedrock", .model_id = "us.anthropic.claude-opus-4-6-v1" },
    .{ .provider = "google-gemini-cli", .model_id = "gemini-2.5-pro" },
    .{ .provider = "google-antigravity", .model_id = "gemini-3.1-pro-high" },
    .{ .provider = "google-vertex", .model_id = "gemini-3-pro-preview" },
    .{ .provider = "openai-codex", .model_id = "gpt-5.4" },
    .{ .provider = "azure-openai-responses", .model_id = "gpt-5.2" },
    .{ .provider = "github-copilot", .model_id = "gpt-4o" },
    .{ .provider = "xai", .model_id = "grok-4-fast-non-reasoning" },
    .{ .provider = "groq", .model_id = "openai/gpt-oss-120b" },
    .{ .provider = "cerebras", .model_id = "zai-glm-4.7" },
    .{ .provider = "openrouter", .model_id = "openai/gpt-5.1-codex" },
    .{ .provider = "vercel-ai-gateway", .model_id = "anthropic/claude-opus-4-6" },
    .{ .provider = "zai", .model_id = "glm-5" },
    .{ .provider = "mistral", .model_id = "devstral-medium-latest" },
    .{ .provider = "minimax", .model_id = "MiniMax-M2.7" },
    .{ .provider = "minimax-cn", .model_id = "MiniMax-M2.7" },
    .{ .provider = "huggingface", .model_id = "moonshotai/Kimi-K2.5" },
    .{ .provider = "opencode", .model_id = "claude-opus-4-6" },
    .{ .provider = "opencode-go", .model_id = "kimi-k2.5" },
    .{ .provider = "kimi-coding", .model_id = "kimi-k2-thinking" },
};
