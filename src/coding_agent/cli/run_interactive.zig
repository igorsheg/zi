const std = @import("std");
const ai = @import("../../ai/root.zig");
const model_resolve = @import("../resolve.zig");
const logging = @import("../../logging.zig");
const sdk = @import("../sdk.zig");
const interactive_mod = @import("../../tui/interactive.zig");
const theme_mod = @import("../../tui/theme.zig");
const themes_builtin = @import("../../themes/builtin.zig");
const tool_display = @import("../../tui/tool_display.zig");
const builtin_renderers = @import("../../tui/renderers/builtins.zig");
const compactor = @import("../session/compactor.zig");
const session_lookup_mod = @import("../session/lookup.zig");
const initial_message = @import("initial_message.zig");
const plan = @import("plan.zig");
const runtime_mod = @import("runtime.zig");
const result = @import("result.zig");
const common = @import("common.zig");
const context_mod = @import("context.zig");

const ResolvedStartupAction = union(enum) {
    none,
    prompt: ai.protocol.UserMessage.UserMessageContent,
    resume_session: struct {
        path: []const u8,
        restore_session_model: bool = true,
    },
    resume_picker: struct {
        restore_session_model: bool = true,
    },
};

const StartupResolution = union(enum) {
    ok: ResolvedStartupAction,
    err: result.ExecutionDiagnostic,
};

pub fn run(
    ctx: context_mod.Context,
    runtime: *runtime_mod.Runtime,
    options: plan.InteractivePlan,
) !result.ExecutionResult {
    logging.setThreadLabel(.tui);

    const prepare_options: initial_message.PrepareOptions = .{
        .inline_image_policy = .{
            .auto_resize = runtime.settings_manager.getImageAutoResize(),
        },
    };
    const startup_action = switch (try resolveStartupAction(ctx.allocator, runtime.cwd, options, prepare_options)) {
        .ok => |action| action,
        .err => |diag| return .{ .err = diag },
    };

    const init_result = model_resolve.findInitialModel(.{
        .cli_provider = null,
        .cli_model = options.model_id,
        .scoped_models = &.{},
        .is_continuing = startupActionResumesSession(startup_action),
        .default_provider = runtime.settings_manager.getDefaultProvider(),
        .default_model_id = runtime.settings_manager.getDefaultModel(),
        .default_thinking_level = common.defaultThinkingLevel(runtime.settings_manager),
        .registry = runtime.model_registry,
        .allocator = ctx.allocator,
    }) catch {
        return .{ .err = .model_resolution_failed };
    };

    const effective_model = init_result.model orelse {
        if (init_result.fallback_message) |message| {
            return .{ .err = .{ .resolver_message = message } };
        }
        return .{ .err = .no_model_available };
    };

    if (options.api_key) |cli_key| {
        const provider_str = ai.json_util.providerToString(effective_model.provider);
        runtime.auth_storage.setRuntimeApiKey(provider_str, cli_key);
    }
    const provider_str = ai.json_util.providerToString(effective_model.provider);
    const api_key: []const u8 = runtime.auth_storage.getApiKey(provider_str) orelse "";
    const needs_auth = api_key.len == 0;
    const allowlist_opt = try common.parseToolAllowlist(ctx.allocator, options.tool_allowlist_csv);

    var ca = try sdk.createAgentSession(ctx.allocator, .{
        .model = effective_model,
        .api_key = api_key,
        .cwd = runtime.cwd,
        .max_tokens = 4096,
        .auth_storage = runtime.auth_storage,
        .settings_manager = runtime.settings_manager,
        .model_registry = runtime.model_registry,
        .thinking_level = common.aiToAgentThinking(init_result.thinking_level),
        .no_session = options.no_session,
        .append_system_prompt = options.append_system_prompt,
        .tool_allowlist = allowlist_opt,
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
    const retry_settings = runtime.settings_manager.getRetrySettings();
    const compaction_settings = runtime.settings_manager.getCompactionSettings();
    const compaction_executor = compactor.createExecutor(&ca);
    const memory_diagnostics = @import("../../debug/tracked_allocator.zig").Diagnostics{
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
        runtime.cwd,
        runtime.auth_storage,
        runtime.settings_manager,
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

    applyInteractiveTheme(&interactive, resolveSelectedTheme(&ca, runtime.settings_manager));
    interactive.setStartupAction(switch (startup_action) {
        .none => .none,
        .prompt => |prompt| .{ .prompt = prompt },
        .resume_session => |session_resume| .{ .resume_session = .{
            .path = session_resume.path,
            .restore_session_model = session_resume.restore_session_model,
        } },
        .resume_picker => |picker| .{ .resume_picker = .{
            .restore_session_model = picker.restore_session_model,
        } },
    });

    if (needs_auth) {
        interactive.status_text.setContent("no API key — use /login to authenticate");
        interactive.status_text.fg = interactive.theme.fg(.warning);
    }

    try interactive.run();
    return .ok;
}

fn resolveStartupAction(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    options: plan.InteractivePlan,
    prepare_options: initial_message.PrepareOptions,
) std.mem.Allocator.Error!StartupResolution {
    return switch (options.session_target) {
        .none => switch (try initial_message.prepareInitialMessage(allocator, cwd, options.prompt_sources, prepare_options)) {
            .ok => |prepared| .{ .ok = if (prepared) |content| .{ .prompt = try content.toUserContent(allocator) } else .none },
            .err => |diag| .{ .err = diag },
        },
        .picker => .{ .ok = .{ .resume_picker = .{
            .restore_session_model = shouldRestoreSessionModel(options),
        } } },
        .most_recent => switch (try session_lookup_mod.resolvePath(allocator, cwd, .most_recent)) {
            .ok => |path| .{ .ok = .{ .resume_session = .{
                .path = path,
                .restore_session_model = shouldRestoreSessionModel(options),
            } } },
            .err => |diag| .{ .err = result.fromSessionLookupDiagnostic(diag) },
        },
        .reference => |ref| switch (try session_lookup_mod.resolvePath(allocator, cwd, .{ .reference = ref })) {
            .ok => |path| .{ .ok = .{ .resume_session = .{
                .path = path,
                .restore_session_model = shouldRestoreSessionModel(options),
            } } },
            .err => |diag| .{ .err = result.fromSessionLookupDiagnostic(diag) },
        },
    };
}

fn shouldRestoreSessionModel(options: plan.InteractivePlan) bool {
    return options.model_id == null;
}

fn startupActionResumesSession(action: ResolvedStartupAction) bool {
    return switch (action) {
        .resume_session => true,
        .none, .prompt, .resume_picker => false,
    };
}

test "startup resume keeps explicit cli model instead of restoring session model" {
    try std.testing.expect(shouldRestoreSessionModel(.{}));
    try std.testing.expect(!shouldRestoreSessionModel(.{ .model_id = "claude-sonnet-4-5" }));

    const from_picker = try resolveStartupAction(std.testing.allocator, "/tmp", .{
        .session_target = .picker,
        .model_id = "claude-sonnet-4-5",
    }, .{});
    switch (from_picker) {
        .ok => |action| switch (action) {
            .resume_picker => |picker| try std.testing.expect(!picker.restore_session_model),
            else => return error.UnexpectedStartupAction,
        },
        .err => return error.UnexpectedDiagnostic,
    }
}

test "interactive startup prepares shared @file prompt content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "notes.txt", .data = "hello from file" });
    const cwd = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    const resolved = try resolveStartupAction(allocator, cwd, .{
        .prompt_sources = .{
            .file_args = &.{"notes.txt"},
            .prompt_text = "and prompt",
        },
    }, .{});
    switch (resolved) {
        .ok => |action| switch (action) {
            .prompt => |content| switch (content) {
                .text => |text| {
                    try std.testing.expect(std.mem.indexOf(u8, text, "notes.txt") != null);
                    try std.testing.expect(std.mem.indexOf(u8, text, "hello from file") != null);
                    try std.testing.expect(std.mem.indexOf(u8, text, "and prompt") != null);
                },
                .blocks => return error.ExpectedTextPrompt,
            },
            else => return error.UnexpectedStartupAction,
        },
        .err => return error.UnexpectedDiagnostic,
    }
}

fn resolveSelectedTheme(ca: *sdk.AgentSession, settings: *const @import("../settings/manager.zig").SettingsManager) *const theme_mod.Theme {
    if (settings.getTheme()) |selected_name| {
        if (ca.resource_loader.findThemeByName(selected_name)) |loaded| {
            return &loaded.theme;
        }
    }

    const fallback_name: []const u8 = switch (theme_mod.Theme.detectTerminalBackground()) {
        .dark => "dark",
        .light => "light",
    };
    if (ca.resource_loader.findThemeByName(fallback_name)) |loaded| {
        return &loaded.theme;
    }

    return themes_builtin.defaultForTerminal();
}

fn applyInteractiveTheme(interactive: *interactive_mod.Interactive, theme: *const theme_mod.Theme) void {
    interactive.theme = theme;
    interactive.greeter.theme = theme;
    interactive.footer.theme = theme;
    interactive.hotkeys_overlay.theme = theme;
    interactive.editor.setTheme(theme);
    interactive.transcript.theme = theme;
    interactive.loader.shimmer_edge_fg = theme.fg(.muted);
    interactive.loader.message_fg = theme.fg(.dim);
    interactive.loader.shimmer_peak_fg = @import("../../tui/cell.zig").Color.rgb(0xF2, 0xF1, 0xEF);
}
