const std = @import("std");
const ai = @import("../ai/root.zig");
const auth = @import("../auth/root.zig");
const settings_mod = @import("../settings/root.zig");
const agent = @import("../agent/root.zig");
const coding_agent = @import("../coding_agent.zig");
const sdk = @import("../sdk.zig");
const agent_json = @import("../agent/json.zig");
const args = @import("args.zig");
const common = @import("common.zig");

const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };

pub fn run(allocator: std.mem.Allocator, options: args.RunOptions) !void {
    const is_continue = options.continue_path != null;
    const prompt = if (is_continue) null else (options.prompt_text orelse {
        try stderr.writeAll("error: no prompt provided\n");
        std.process.exit(1);
    });

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

    var initial_messages: []const agent.protocol.AgentMessage = &.{};
    var session_store: ?coding_agent.SessionStore = null;
    var saved_session_model: ?@import("../session/context.zig").SessionContext.ModelInfo = null;
    var loaded_session: ?coding_agent.OpenSessionResult = null;
    defer if (loaded_session) |*loaded| loaded.deinit();
    if (options.continue_path) |path| {
        loaded_session = coding_agent.openSession(allocator, path) catch |err| {
            try stderr.writeAll("error: could not load session: ");
            try stderr.writeAll(@errorName(err));
            try stderr.writeAll("\n");
            std.process.exit(1);
        };
        initial_messages = loaded_session.?.messages;
        if (initial_messages.len == 0) {
            try stderr.writeAll("error: session file has no messages\n");
            std.process.exit(1);
        }
        session_store = loaded_session.?.takeStore();
        saved_session_model = loaded_session.?.model;
    }

    const custom_models = common.convertCustomModels(allocator, settings.getModels()) catch &.{};
    var model_registry = ai.model_registry.ModelRegistry.init(
        allocator,
        &auth_storage,
        custom_models,
    ) catch {
        try stderr.writeAll("error: could not build model registry\n");
        std.process.exit(1);
    };

    var restored_model: ?ai.protocol.Model = null;
    if (options.model_id == null) {
        if (saved_session_model) |saved| {
            const restore = ai.resolve.restoreModelFromSession(.{
                .saved_provider = saved.provider,
                .saved_model_id = saved.model_id,
                .current_model = null,
                .registry = &model_registry,
                .allocator = allocator,
            }) catch ai.resolve.RestoreResult{ .model = null, .fallback_message = null };
            restored_model = restore.model;
        }
    }

    const model = restored_model orelse blk: {
        const init_result = ai.resolve.findInitialModel(.{
            .cli_provider = null,
            .cli_model = options.model_id,
            .is_continuing = is_continue,
            .default_provider = settings.getDefaultProvider(),
            .default_model_id = settings.getDefaultModel(),
            .registry = &model_registry,
            .allocator = allocator,
        }) catch {
            try stderr.writeAll("error: model resolution failed\n");
            std.process.exit(1);
        };
        break :blk init_result.model orelse {
            try stderr.writeAll("error: no model found. run `pi login` or set an API key env var.\n");
            try stderr.writeAll("use --list-models to see available models\n");
            std.process.exit(1);
        };
    };

    const provider_str = ai.json_util.providerToString(model.provider);
    if (options.api_key) |cli_key| {
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

    const allowlist_opt = try common.parseToolAllowlist(allocator, options.tools_filter);
    var json_handler = JsonHandler{};
    var print_handler = PrintHandler{};
    const event_handler: coding_agent.AgentSession.EventHandler = if (options.mode == .json)
        .{ .func = &JsonHandler.callback, .ctx = @ptrCast(&json_handler) }
    else
        .{ .func = &PrintHandler.callback, .ctx = @ptrCast(&print_handler) };

    var ca = try sdk.createAgentSession(allocator, .{
        .model = model,
        .api_key = key,
        .cwd = cwd_buf,
        .max_tokens = 4096,
        .auth_storage = &auth_storage,
        .settings_manager = &settings,
        .event_handler = event_handler,
        .initial_messages = initial_messages,
        .session_store = session_store,
        .no_session = options.no_session,
        .append_system_prompt = options.append_system_prompt,
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
}

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

const JsonHandler = struct {
    fn callback(event: agent.protocol.AgentEvent, _: ?*anyopaque) void {
        var buf: [4096]u8 = undefined;
        var writer = stdout.writerStreaming(&buf);
        agent_json.writeAgentEvent(&writer.interface, event) catch return;
        writer.interface.writeAll("\n") catch {};
        writer.end() catch {};
    }
};
