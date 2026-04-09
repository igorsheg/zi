const std = @import("std");
const ai = @import("ai/root.zig");
const auth = @import("auth/root.zig");
const settings_mod = @import("settings/root.zig");
const agent = @import("agent/root.zig");
const coding_agent = @import("coding_agent.zig");
const sdk = @import("sdk.zig");
const agent_json = @import("agent/json.zig");
const interactive_mod = @import("tui/interactive.zig");
const terminal_mod = @import("tui/terminal.zig");

/// Restore terminal on panic (raw mode, cursor, keyboard protocol).
pub const panic = terminal_mod.panic;

const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    // zi-wub.12: dedicated arena owned by the agent thread. Single
    // owner during steady state — TUI thread only touches it during
    // pre-spawn init (auth, settings, ca creation) and post-join
    // deinit, never concurrently with the agent thread. Cross-thread
    // payloads route through msg_allocator (zi-wub.9/.10) and the
    // TUI thread allocates from its own tui_arena (zi-wub.11), so
    // the ThreadSafeAllocator band-aid (.13) is no longer needed.
    var agent_arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer agent_arena.deinit();
    const allocator = agent_arena.allocator();

    // zi-wub.8: dedicated thread-safe GPA for cross-thread message
    // payloads and queue backing storage (EventQueue, AgentRequest
    // queue, convertAgentEvent clones, login callbacks). Wraps the
    // ROOT GPA directly — NOT the arena — so producer/consumer pairs
    // can free individually and we don't pin growing payloads in the
    // arena's lifetime. See .zi/design-notes/threading-doctrine.md
    // (R2, R3) for why this is the foundation of phase 3.
    var ts_msg: std.heap.ThreadSafeAllocator = .{ .child_allocator = gpa.allocator() };
    const msg_allocator = ts_msg.allocator();

    var print_mode = false;
    var show_help = false;
    var show_version = false;
    var api_key_arg: ?[]const u8 = null;
    var model_id: ?[]const u8 = null;
    var list_models = false;
    var prompt_text: ?[]const u8 = null;
    var continue_path: ?[]const u8 = null;
    var mode: enum { text, json } = .text;
    var no_session = false;
    var tools_filter: ?[]const u8 = null;
    var append_system_prompt_arg: ?[]const u8 = null;

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
        } else if (eql(arg, "--mode")) {
            if (args.next()) |m| {
                if (eql(m, "json")) {
                    mode = .json;
                } else if (eql(m, "text")) {
                    mode = .text;
                } else {
                    try stderr.writeAll("error: unknown mode '");
                    try stderr.writeAll(m);
                    try stderr.writeAll("'. use 'json' or 'text'\n");
                    std.process.exit(1);
                }
            }
        } else if (eql(arg, "--no-session")) {
            no_session = true;
        } else if (eql(arg, "--tools")) {
            tools_filter = args.next();
        } else if (eql(arg, "--append-system-prompt")) {
            append_system_prompt_arg = args.next();
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
            \\  --api-key <key>       API key override (also reads ~/.zi/agent/auth.json)
            \\  --continue <path>     Continue from a session file
            \\  --mode <text|json>    Output mode (default: text)
            \\  --no-session          Disable session persistence
            \\  --tools <filter>      Comma-separated list of allowed tools
            \\  --append-system-prompt <text|path>  Append to system prompt (literal text or file path)
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

    const has_prompt = print_mode or mode == .json or prompt_text != null;
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
        var session_store: ?coding_agent.SessionStore = null;
        if (continue_path) |path| {
            const loaded = coding_agent.openSession(allocator, path) catch |err| {
                try stderr.writeAll("error: could not load session: ");
                const err_name = @errorName(err);
                try stderr.writeAll(err_name);
                try stderr.writeAll("\n");
                std.process.exit(1);
            };
            initial_messages = loaded.messages;
            session_store = loaded.store;
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

        const custom_models = convertCustomModels(allocator, settings.getModels()) catch &.{};
        var model_registry = ai.model_registry.ModelRegistry.init(
            allocator,
            &auth_storage,
            custom_models,
        ) catch {
            try stderr.writeAll("error: could not build model registry\n");
            std.process.exit(1);
        };

        const print_init = ai.resolve.findInitialModel(.{
            .cli_provider = null,
            .cli_model = model_id,
            .is_continuing = is_continue,
            .default_provider = settings.getDefaultProvider(),
            .default_model_id = settings.getDefaultModel(),
            .registry = &model_registry,
            .allocator = allocator,
        }) catch {
            try stderr.writeAll("error: model resolution failed\n");
            std.process.exit(1);
        };
        const model = print_init.model orelse {
            try stderr.writeAll("error: no model found. run `pi login` or set an API key env var.\n");
            try stderr.writeAll("use --list-models to see available models\n");
            std.process.exit(1);
        };

        // Phase 3: any registered provider works. Bundle.init
        // registers anthropic-messages and openai-completions; the
        // stream closure looks up the model's api in the registry
        // and fails cleanly if the api isn't registered yet
        // (openai-responses / openai-codex-responses land in 3b/3c).
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

        // Provider registry is built inside AgentSession via the
        // canonical `ai.provider_defaults.Bundle`. main.zig no longer
        // hand-registers providers per mode.

        // Resolve --append-system-prompt: file path -> read contents, else treat as literal text
        var append_system_prompt: ?[]const u8 = null;
        if (append_system_prompt_arg) |asp| {
            if (std.fs.cwd().openFile(asp, .{})) |file| {
                defer file.close();
                append_system_prompt = file.readToEndAlloc(allocator, 1024 * 1024) catch null;
            } else |_| {
                append_system_prompt = asp;
            }
        }
        // Resolve --tools allowlist: comma-separated tool names →
        // strict whitelist applied inside AgentSession.init AFTER the
        // builtin + Lua-extension tool merge. Passing the list through
        // (rather than pre-filtering the builtin slice here) lets the
        // filter also drop extension-registered tools like Task —
        // critical for preventing Task-in-Task subagent recursion
        // when a child zi is spawned with `--tools bash,read`.
        var allowlist_opt: ?[]const []const u8 = null;
        if (tools_filter) |filter_str| {
            var list: std.ArrayListUnmanaged([]const u8) = .empty;
            var it = std.mem.splitScalar(u8, filter_str, ',');
            while (it.next()) |name| {
                const trimmed = std.mem.trim(u8, name, &std.ascii.whitespace);
                if (trimmed.len == 0) continue;
                list.append(allocator, trimmed) catch {};
            }
            allowlist_opt = list.items;
        }

        var json_handler = JsonHandler{};
        var print_handler = PrintHandler{};
        const event_handler: coding_agent.AgentSession.EventHandler = if (mode == .json)
            .{ .func = &JsonHandler.callback, .ctx = @ptrCast(&json_handler) }
        else
            .{ .func = &PrintHandler.callback, .ctx = @ptrCast(&print_handler) };

        var ca = try sdk.createAgentSession(allocator, .{
            .model = model,
            .api_key = key,
            .cwd = cwd_buf,
            .max_tokens = 4096,
            .auth_storage = &auth_storage,
            .event_handler = event_handler,
            .initial_messages = initial_messages,
            .session_store = session_store,
            .no_session = no_session,
            .append_system_prompt = append_system_prompt,
            .tool_allowlist = allowlist_opt,
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
            try ca.run(prompt.?);
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

        const cwd_buf = std.fs.cwd().realpathAlloc(allocator, ".") catch "/unknown";
        var settings = settings_mod.manager.SettingsManager.create(allocator, cwd_buf, null) catch {
            try stderr.writeAll("warning: could not load settings\n");
            unreachable;
        };

        // Session-owned ModelRegistry. Main owns the lifetime;
        // AgentSession holds a borrowed pointer.
        const custom_models_interactive = convertCustomModels(allocator, settings.getModels()) catch &.{};
        var model_registry = ai.model_registry.ModelRegistry.init(
            allocator,
            &auth_storage,
            custom_models_interactive,
        ) catch {
            try stderr.writeAll("error: could not build model registry\n");
            std.process.exit(1);
        };

        // Resolve initial model via pi-mono's findInitialModel ladder.
        // pi-mono source: model-resolver.ts:474-554
        const default_thinking: ?ai.protocol.ThinkingLevel = blk: {
            const lvl = settings.getDefaultThinkingLevel() orelse break :blk null;
            break :blk switch (lvl) {
                .off => null,
                .minimal => .minimal,
                .low => .low,
                .medium => .medium,
                .high => .high,
                .xhigh => .xhigh,
            };
        };
        const init_result = ai.resolve.findInitialModel(.{
            .cli_provider = null, // zi has no --provider flag yet
            .cli_model = model_id,
            .scoped_models = &.{},
            .is_continuing = false,
            .default_provider = settings.getDefaultProvider(),
            .default_model_id = settings.getDefaultModel(),
            .default_thinking_level = default_thinking,
            .registry = &model_registry,
            .allocator = allocator,
        }) catch {
            try stderr.writeAll("error: model resolution failed\n");
            std.process.exit(1);
        };

        const effective_model = init_result.model orelse {
            if (init_result.fallback_message) |msg| {
                stderr.writeAll("error: ") catch {};
                stderr.writeAll(msg) catch {};
                stderr.writeAll("\n") catch {};
            } else {
                try stderr.writeAll(
                    "no model available — configure auth via /login or pass --api-key, then --model.\n",
                );
            }
            std.process.exit(1);
        };

        // Stage CLI api key under the effective model's provider so
        // the stream closure sees it on the first request.
        if (api_key_arg) |cli_key| {
            const provider_str = ai.json_util.providerToString(effective_model.provider);
            auth_storage.setRuntimeApiKey(provider_str, cli_key);
        }
        const effective_provider_str = ai.json_util.providerToString(effective_model.provider);
        const api_key: []const u8 = auth_storage.getApiKey(effective_provider_str) orelse "";
        const needs_auth = api_key.len == 0;

        // Provider registry is owned by AgentSession via Bundle.
        var ca = try sdk.createAgentSession(allocator, .{
            .model = effective_model,
            .api_key = api_key,
            .cwd = cwd_buf,
            .max_tokens = 4096,
            .auth_storage = &auth_storage,
            .model_registry = &model_registry,
            .thinking_level = aiToAgentThinking(init_result.thinking_level),
        });
        defer ca.deinit();

        const tool_display = @import("tui/tool_display.zig");
        const builtin_renderers = @import("tui/renderers/builtins.zig");
        // Static built-in entries. The resolver hands these out when
        // no Lua render hook claims the tool name. Lua-registered
        // tools hook in via the composed resolver inside Interactive.
        const static_entries: []const tool_display.Registration = &.{
            .{ .tool_name = "Bash", .renderer = builtin_renderers.bash_renderer },
            .{ .tool_name = "read", .renderer = builtin_renderers.read_renderer },
            .{ .tool_name = "write", .renderer = builtin_renderers.write_renderer },
            .{ .tool_name = "edit", .renderer = builtin_renderers.edit_renderer },
            .{ .tool_name = "grep", .renderer = builtin_renderers.grep_renderer },
            .{ .tool_name = "find", .renderer = builtin_renderers.find_renderer },
            .{ .tool_name = "ls", .renderer = builtin_renderers.ls_renderer },
        };
        const resolver = tool_display.ToolRendererResolver.fromStatic(&static_entries);
        // zi-wub.11: TUI thread owns its own arena. Single-thread,
        // no ThreadSafeAllocator wrap — all consumers live on the
        // TUI thread. Cross-thread payloads use msg_allocator;
        // cross-thread requests use ca's shared allocator (until .12).
        var tui_arena = std.heap.ArenaAllocator.init(gpa.allocator());
        defer tui_arena.deinit();
        var interactive = try interactive_mod.Interactive.init(tui_arena.allocator(), msg_allocator, &ca, resolver, cwd_buf, &auth_storage);
        defer interactive.deinit();

        if (needs_auth) {
            interactive.status_text.setContent("no API key — use /login to authenticate");
            interactive.status_text.fg = interactive.theme.fg(.warning);
        }

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

/// JSON handler: serializes each AgentEvent as a JSONL line to stdout.
const JsonHandler = struct {
    fn callback(event: agent.protocol.AgentEvent, _: ?*anyopaque) void {
        const serialized = agent_json.serializeAgentEvent(
            std.heap.page_allocator,
            event,
        ) catch return;
        defer std.heap.page_allocator.free(serialized);
        stdout.writeAll(serialized) catch {};
        stdout.writeAll("\n") catch {};
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn aiToAgentThinking(level: ai.protocol.ThinkingLevel) agent.protocol.ThinkingLevel {
    return switch (level) {
        .minimal => .minimal,
        .low => .low,
        .medium => .medium,
        .high => .high,
        .xhigh => .xhigh,
    };
}

const TEXT_ONLY: []const ai.protocol.Model.InputType = &.{.text};
const TEXT_IMAGE: []const ai.protocol.Model.InputType = &.{ .text, .image };

/// Convert settings CustomModel entries to protocol.Model for ModelRegistry.
/// Validates api (must be known built-in) and provider (must NOT shadow built-in).
/// Skips invalid entries with a log warning.
fn convertCustomModels(
    allocator: std.mem.Allocator,
    customs: ?[]const settings_mod.types.CustomModel,
) ![]const ai.protocol.Model {
    const items = customs orelse return &.{};
    if (items.len == 0) return &.{};

    var result = try allocator.alloc(ai.protocol.Model, items.len);
    var count: usize = 0;

    const log = std.log.scoped(.settings);
    for (items, 0..) |cm, i| {
        // Validate api: must be known built-in, not .custom
        const api = ai.json_util.parseApi(cm.api);
        switch (api) {
            .custom => {
                log.warn("settings.models[{d}]: unknown api '{s}', skipping", .{ i, cm.api });
                continue;
            },
            else => {},
        }

        // Validate provider: must NOT be a known built-in (shadowing)
        const provider = ai.json_util.parseProvider(cm.provider);
        switch (provider) {
            .custom => {}, // good — it's a new custom provider name
            else => {
                log.warn("settings.models[{d}]: provider '{s}' shadows a built-in, skipping", .{ i, cm.provider });
                continue;
            },
        }

        if (cm.id.len == 0 or cm.base_url.len == 0) {
            log.warn("settings.models[{d}]: empty id or baseUrl, skipping", .{i});
            continue;
        }

        result[count] = .{
            .id = cm.id,
            .name = cm.name,
            .api = api,
            .provider = provider,
            .base_url = cm.base_url,
            .reasoning = cm.reasoning,
            .input = if (cm.input_has_image) TEXT_IMAGE else TEXT_ONLY,
            .cost = .{
                .input = cm.cost_input,
                .output = cm.cost_output,
                .cache_read = cm.cost_cache_read,
                .cache_write = cm.cost_cache_write,
            },
            .context_window = cm.context_window,
            .max_tokens = cm.max_tokens,
        };
        count += 1;
    }

    return result[0..count];
}
