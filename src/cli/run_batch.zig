const std = @import("std");
const ai = @import("../ai/root.zig");
const logging = @import("../logging.zig");
const agent = @import("../agent/root.zig");
const coding_agent = @import("../coding_agent.zig");
const sdk = @import("../sdk.zig");
const agent_json = @import("../agent/json.zig");
const session_context = @import("../session/context.zig");
const plan = @import("plan.zig");
const runtime_mod = @import("runtime.zig");
const result = @import("result.zig");
const common = @import("common.zig");

const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };

pub fn run(runtime: *runtime_mod.Runtime, options: plan.BatchPlan) !result.ExecutionResult {
    logging.setThreadLabel(.batch);

    const allocator = runtime.allocator;
    const is_continue = options.session_target != .none;
    const prompt = if (is_continue) null else options.prompt;

    var initial_messages: []const agent.protocol.AgentMessage = &.{};
    var session_store: ?coding_agent.SessionStore = null;
    var saved_session_model: ?session_context.SessionContext.ModelInfo = null;
    var loaded_session: ?coding_agent.OpenSessionResult = null;
    defer if (loaded_session) |*loaded| loaded.deinit();

    switch (options.session_target) {
        .none => {},
        .continue_path => |path| {
            loaded_session = coding_agent.openSession(allocator, path) catch |err| {
                return .{ .err = .{ .session_load_failed = @errorName(err) } };
            };
            initial_messages = loaded_session.?.messages;
            if (initial_messages.len == 0) {
                return .{ .err = .session_file_has_no_messages };
            }
            session_store = loaded_session.?.takeStore();
            saved_session_model = loaded_session.?.model;
        },
    }

    var restored_model: ?ai.protocol.Model = null;
    if (options.model_id == null) {
        if (saved_session_model) |saved| {
            const restore = ai.resolve.restoreModelFromSession(.{
                .saved_provider = saved.provider,
                .saved_model_id = saved.model_id,
                .current_model = null,
                .registry = runtime.model_registry,
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
            .default_provider = runtime.settings_manager.getDefaultProvider(),
            .default_model_id = runtime.settings_manager.getDefaultModel(),
            .registry = runtime.model_registry,
            .allocator = allocator,
        }) catch {
            return .{ .err = .model_resolution_failed };
        };
        if (init_result.fallback_message) |message| {
            return .{ .err = .{ .resolver_message = message } };
        }
        break :blk init_result.model orelse return .{ .err = .no_model_found };
    };

    const provider_str = ai.json_util.providerToString(model.provider);
    if (options.api_key) |cli_key| {
        runtime.auth_storage.setRuntimeApiKey(provider_str, cli_key);
    }
    const key = runtime.auth_storage.getApiKey(provider_str) orelse {
        return .{ .err = .{ .no_api_key_for_provider = .{
            .provider = provider_str,
            .env_hint = ai.env_api_keys.getEnvApiKey(provider_str),
        } } };
    };

    const allowlist_opt = try common.parseToolAllowlist(allocator, options.tool_allowlist_csv);
    var json_handler = JsonHandler{};
    var print_handler = PrintHandler{};
    const event_handler: coding_agent.AgentSession.EventHandler = if (options.output == .json)
        .{ .func = &JsonHandler.callback, .ctx = @ptrCast(&json_handler) }
    else
        .{ .func = &PrintHandler.callback, .ctx = @ptrCast(&print_handler) };

    var ca = try sdk.createAgentSession(allocator, .{
        .model = model,
        .api_key = key,
        .cwd = runtime.cwd,
        .max_tokens = 4096,
        .auth_storage = runtime.auth_storage,
        .settings_manager = runtime.settings_manager,
        .model_registry = runtime.model_registry,
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
                return .{ .err = .continue_session_needs_prompt };
            }
            return .{ .err = .{ .continue_session_failed = @errorName(err) } };
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

    return .ok;
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
