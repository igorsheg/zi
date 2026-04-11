const std = @import("std");
const ai = @import("../ai/root.zig");
const auth = @import("../auth/root.zig");
const settings_mod = @import("../settings/root.zig");
const sdk = @import("../sdk.zig");
const interactive_mod = @import("../tui/interactive.zig");
const tool_display = @import("../tui/tool_display.zig");
const builtin_renderers = @import("../tui/renderers/builtins.zig");
const compactor = @import("../session/compactor.zig");
const args = @import("args.zig");
const common = @import("common.zig");
const context_mod = @import("context.zig");
const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };

pub fn run(ctx: context_mod.Context, options: args.RunOptions) !void {
    var auth_storage = auth.storage.AuthStorage.create(ctx.allocator, null) catch {
        try stderr.writeAll("warning: could not load auth storage\n");
        unreachable;
    };

    const cwd_buf = std.fs.cwd().realpathAlloc(ctx.allocator, ".") catch "/unknown";
    var settings = settings_mod.manager.SettingsManager.create(ctx.allocator, cwd_buf, null) catch {
        try stderr.writeAll("warning: could not load settings\n");
        unreachable;
    };

    const custom_models = common.convertCustomModels(ctx.allocator, settings.getModels()) catch &.{};
    var model_registry = ai.model_registry.ModelRegistry.init(
        ctx.allocator,
        &auth_storage,
        custom_models,
    ) catch {
        try stderr.writeAll("error: could not build model registry\n");
        std.process.exit(1);
    };

    const init_result = ai.resolve.findInitialModel(.{
        .cli_provider = null,
        .cli_model = options.model_id,
        .scoped_models = &.{},
        .is_continuing = false,
        .default_provider = settings.getDefaultProvider(),
        .default_model_id = settings.getDefaultModel(),
        .default_thinking_level = common.defaultThinkingLevel(&settings),
        .registry = &model_registry,
        .allocator = ctx.allocator,
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

    if (options.api_key) |cli_key| {
        const provider_str = ai.json_util.providerToString(effective_model.provider);
        auth_storage.setRuntimeApiKey(provider_str, cli_key);
    }
    const provider_str = ai.json_util.providerToString(effective_model.provider);
    const api_key: []const u8 = auth_storage.getApiKey(provider_str) orelse "";
    const needs_auth = api_key.len == 0;

    var ca = try sdk.createAgentSession(ctx.allocator, .{
        .model = effective_model,
        .api_key = api_key,
        .cwd = cwd_buf,
        .max_tokens = 4096,
        .auth_storage = &auth_storage,
        .model_registry = &model_registry,
        .thinking_level = common.aiToAgentThinking(init_result.thinking_level),
    });
    defer ca.deinit();

    const static_entries: []const tool_display.Registration = &.{
        .{ .tool_name = "bash", .renderer = builtin_renderers.bash_renderer },
        .{ .tool_name = "read", .renderer = builtin_renderers.read_renderer },
        .{ .tool_name = "write", .renderer = builtin_renderers.write_renderer },
        .{ .tool_name = "edit", .renderer = builtin_renderers.edit_renderer },
        .{ .tool_name = "grep", .renderer = builtin_renderers.grep_renderer },
        .{ .tool_name = "find", .renderer = builtin_renderers.find_renderer },
        .{ .tool_name = "ls", .renderer = builtin_renderers.ls_renderer },
    };
    const resolver = tool_display.ToolRendererResolver.fromStatic(&static_entries);
    const retry_settings = settings.getRetrySettings();
    const compaction_settings = settings.getCompactionSettings();
    const compaction_executor = compactor.createExecutor(&ca);
    const memory_diagnostics = @import("../debug/tracked_allocator.zig").Diagnostics{
        .root = ctx.root_tracker,
        .agent = ctx.agent_backing_tracker,
        .tui = ctx.tui_backing_tracker,
        .msg = ctx.msg_backing_tracker,
    };
    var interactive = try interactive_mod.Interactive.init(
        ctx.tui_backing_tracker.allocator(),
        ctx.msg_allocator,
        &ca,
        &memory_diagnostics,
        resolver,
        cwd_buf,
        &auth_storage,
        &settings,
        .{
            .enabled = retry_settings.enabled,
            .max_retries = @intCast(@max(retry_settings.max_retries, 0)),
            .base_delay_ms = @intCast(@max(retry_settings.base_delay_ms, 0)),
            .max_delay_ms = @intCast(@max(retry_settings.max_delay_ms, 0)),
        },
        .{
            .enabled = compaction_settings.enabled,
            .reserve_tokens = @intCast(@max(compaction_settings.reserve_tokens, 0)),
            .keep_recent_tokens = @intCast(@max(compaction_settings.keep_recent_tokens, 0)),
        },
        compaction_executor,
    );
    defer interactive.deinit();

    if (needs_auth) {
        interactive.status_text.setContent("no API key — use /login to authenticate");
        interactive.status_text.fg = interactive.theme.fg(.warning);
    }

    try interactive.run();
}
