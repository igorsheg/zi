const std = @import("std");
const ai = @import("../../ai/root.zig");
const model_resolve = @import("../resolve.zig");
const logging = @import("../../logging.zig");
const agent = @import("../../agent2/root.zig");
const coding_agent = @import("../root.zig");
const sdk = @import("../sdk.zig");
const agent_json = @import("../../agent2/json.zig");
const batch_contract = @import("batch_contract.zig");
const initial_message = @import("initial_message.zig");
const plan = @import("plan.zig");
const runtime_mod = @import("runtime.zig");
const result = @import("result.zig");
const common = @import("common.zig");

const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };

pub fn run(runtime: *runtime_mod.Runtime, options: plan.BatchPlan) !result.ExecutionResult {
    logging.setThreadLabel(.batch);

    const allocator = runtime.allocator;
    const prepare_options: initial_message.PrepareOptions = .{
        .inline_image_policy = .{
            .auto_resize = runtime.settings_manager.getImageAutoResize(),
        },
    };
    const prepared_input = switch (try initial_message.prepareBatchInput(
        allocator,
        runtime.cwd,
        options.prompt_sources,
        prepare_options,
    )) {
        .ok => |input| input,
        .err => |diag| return .{ .err = diag },
    };

    const init_result = model_resolve.findInitialModel(.{
        .cli_provider = null,
        .cli_model = options.model_id,
        .is_continuing = false,
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
    const model = init_result.model orelse return .{ .err = .no_model_found };

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
    const event_handler: ?coding_agent.AgentSession.EventHandler = if (options.output == .json)
        .{ .func = &JsonHandler.callback, .ctx = @ptrCast(&json_handler) }
    else
        null;

    var ca = try sdk.createAgentSession(allocator, .{
        .model = model,
        .api_key = key,
        .cwd = runtime.cwd,
        .max_tokens = 4096,
        .auth_storage = runtime.auth_storage,
        .settings_manager = runtime.settings_manager,
        .model_registry = runtime.model_registry,
        .event_handler = event_handler,
        .no_session = options.no_session,
        .append_system_prompt = options.append_system_prompt,
        .tool_allowlist = allowlist_opt,
    });
    defer ca.deinit();

    if (options.output == .json) {
        var out_buf: [4096]u8 = undefined;
        var out_writer = stdout.writerStreaming(&out_buf);
        try batch_contract.writeJsonSessionPreamble(&out_writer.interface, ca.session_store.header());
        try out_writer.end();
    }

    try ca.runUserContent(try prepared_input.toUserContent(allocator));

    return switch (options.output) {
        .json => .ok,
        .text => try finishTextMode(allocator, ca.agent.messages()),
    };
}

fn finishTextMode(allocator: std.mem.Allocator, messages: []const agent.protocol.AgentMessage) !result.ExecutionResult {
    switch (try batch_contract.evaluateTextModeResult(allocator, messages)) {
        .none => return .ok,
        .failure => |message| return .{ .err = .{ .batch_assistant_failed = message } },
        .success => |assistant| {
            var out_buf: [4096]u8 = undefined;
            var out_writer = stdout.writer(&out_buf);
            try batch_contract.writeAssistantText(&out_writer.interface, assistant);
            try out_writer.end();
            return .ok;
        },
    }
}

const JsonHandler = struct {
    fn callback(event: agent.protocol.AgentEvent, _: ?*anyopaque) void {
        var buf: [4096]u8 = undefined;
        var writer = stdout.writerStreaming(&buf);
        agent_json.writeAgentEvent(&writer.interface, event) catch return;
        writer.interface.writeAll("\n") catch {};
        writer.end() catch {};
    }
};
