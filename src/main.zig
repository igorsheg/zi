const std = @import("std");
const ai = @import("ai/root.zig");
const auth = @import("auth/root.zig");
const settings_mod = @import("settings/root.zig");
const agent = @import("agent/root.zig");
const coding_agent = @import("coding_agent.zig");
const interactive_mod = @import("tui/interactive.zig");
const terminal_mod = @import("tui/terminal.zig");

/// Restore terminal on panic (raw mode, cursor, keyboard protocol).
pub const panic = terminal_mod.panic;

const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();

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
    var continue_path: ?[]const u8 = null;

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
        } else if (eql(arg, "--continue")) {
            continue_path = args.next();
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
            \\  --continue <path>     Continue from a session file
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

    const has_prompt = print_mode or prompt_text != null;
    const is_continue = continue_path != null;

    if (has_prompt or is_continue) {
        const prompt = if (is_continue) null else (prompt_text orelse {
            try stderr.writeAll("error: no prompt provided\n");
            std.process.exit(1);
        });

        // Auth + settings
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

        // Load session BEFORE model resolution (pi-mono sdk.ts:194-218)
        var initial_messages: []const agent.protocol.AgentMessage = &.{};
        var session_id: ?[]const u8 = null;
        var leaf_id: ?[]const u8 = null;
        if (continue_path) |path| {
            const loaded = coding_agent.loadSessionContext(allocator, path) catch |err| {
                try stderr.writeAll("error: could not load session: ");
                const err_name = @errorName(err);
                try stderr.writeAll(err_name);
                try stderr.writeAll("\n");
                std.process.exit(1);
            };
            initial_messages = loaded.messages;
            session_id = loaded.session_id;
            leaf_id = loaded.leaf_id;
            if (initial_messages.len == 0) {
                try stderr.writeAll("error: session file has no messages\n");
                std.process.exit(1);
            }

            // Try session's model first (pi-mono sdk.ts:203-218)
            if (loaded.model) |session_model| {
                if (model_id == null) {
                    model_id = session_model.model_id;
                }
            }
        }

        const model = resolveModel(model_id, &settings, &auth_storage) orelse {
            try stderr.writeAll("error: no model found. run `pi login` or set an API key env var.\n");
            try stderr.writeAll("use --list-models to see available models\n");
            std.process.exit(1);
        };

        if (!std.meta.eql(model.api, .anthropic_messages)) {
            try stderr.writeAll("error: only anthropic models supported currently. model '");
            try stderr.writeAll(model.id);
            try stderr.writeAll("' uses api '");
            try stderr.writeAll(ai.provider.apiToString(model.api));
            try stderr.writeAll("'\n");
            std.process.exit(1);
        }

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

        var print_handler = PrintHandler{};

        var ca = coding_agent.CodingAgent.init(allocator, .{
            .model = model,
            .api_key = key,
            .cwd = cwd_buf,
            .max_tokens = 4096,
            .registry = &registry,
            .event_handler = .{ .func = &PrintHandler.callback, .ctx = @ptrCast(&print_handler) },
            .initial_messages = initial_messages,
            .session_id = session_id,
            .session_file = if (is_continue) continue_path else null,
            .leaf_id = leaf_id,
        });
        defer ca.deinit();

        if (is_continue) {
            ca.continueSession() catch |err| {
                if (err == error.NeedsPrompt) {
                    try stderr.writeAll("session loaded but transcript ends with assistant. provide a prompt to continue.\n");
                    std.process.exit(1);
                }
                try stderr.writeAll("error: could not continue session: ");
                try stderr.writeAll(@errorName(err));
                try stderr.writeAll("\n");
                std.process.exit(1);
            };
        } else {
            ca.run(prompt.?);
        }

        try stdout.writeAll("\n");

        if (ca.sessionFlushed()) {
            stderr.writeAll("session: ") catch {};
            stderr.writeAll(ca.getSessionFile()) catch {};
            stderr.writeAll("\n") catch {};
        }
    } else {
        // Interactive mode
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

        const model = resolveModel(model_id, &settings, &auth_storage) orelse {
            try stderr.writeAll("error: no model found. run `pi login` or set an API key env var.\n");
            try stderr.writeAll("use --list-models to see available models\n");
            std.process.exit(1);
        };

        if (!std.meta.eql(model.api, .anthropic_messages)) {
            try stderr.writeAll("error: only anthropic models supported currently\n");
            std.process.exit(1);
        }

        const provider_str = ai.json_util.providerToString(model.provider);
        if (api_key_arg) |cli_key| {
            auth_storage.setRuntimeApiKey(provider_str, cli_key);
        }
        const key = auth_storage.getApiKey(provider_str) orelse {
            try stderr.writeAll("error: no API key. run `pi login` or set ANTHROPIC_API_KEY\n");
            std.process.exit(1);
        };

        var anthropic_prov = ai.anthropic.AnthropicProvider.init(allocator);
        const prov = anthropic_prov.provider();

        var registry = ai.provider.Registry.init(allocator);
        defer registry.deinit();
        try registry.register("anthropic-messages", prov, null);

        var ca = coding_agent.CodingAgent.init(allocator, .{
            .model = model,
            .api_key = key,
            .cwd = cwd_buf,
            .max_tokens = 4096,
            .registry = &registry,
        });
        defer ca.deinit();

        var interactive = try interactive_mod.Interactive.init(allocator, &ca);
        defer interactive.deinit();
        try interactive.run();
    }
}

/// Print handler: renders events to stdout/stderr.
const PrintHandler = struct {
    fn callback(event: agent.protocol.AgentEvent, _: ?*anyopaque) void {
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
    if (settings.getDefaultModel()) |mid| {
        if (ai.models.getModelById(mid) orelse ai.models.findModel(mid)) |m| {
            return m;
        }
    }

    // 3. Default model per provider, for providers with auth
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
