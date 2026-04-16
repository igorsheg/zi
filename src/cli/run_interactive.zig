const std = @import("std");
const ai = @import("../ai/root.zig");
const logging = @import("../logging.zig");
const sdk = @import("../sdk.zig");
const interactive_mod = @import("../tui/interactive.zig");
const theme_mod = @import("../tui/theme.zig");
const themes_builtin = @import("../themes/builtin.zig");
const tool_display = @import("../tui/tool_display.zig");
const builtin_renderers = @import("../tui/renderers/builtins.zig");
const compactor = @import("../session/compactor.zig");
const session_store_mod = @import("../session/store.zig");
const plan = @import("plan.zig");
const runtime_mod = @import("runtime.zig");
const result = @import("result.zig");
const common = @import("common.zig");
const context_mod = @import("context.zig");

const ResolvedStartupAction = union(enum) {
    none,
    prompt: []const u8,
    resume_session: []const u8,
    resume_picker,
};

const StartupResolution = union(enum) {
    ok: ResolvedStartupAction,
    err: result.ExecutionDiagnostic,
};

const SessionPathResolution = union(enum) {
    ok: []const u8,
    err: result.ExecutionDiagnostic,
};

pub fn run(
    ctx: context_mod.Context,
    runtime: *runtime_mod.Runtime,
    options: plan.InteractivePlan,
) !result.ExecutionResult {
    logging.setThreadLabel(.tui);

    const startup_action = switch (try resolveStartupAction(ctx.allocator, runtime.cwd, options)) {
        .ok => |action| action,
        .err => |diag| return .{ .err = diag },
    };

    const init_result = ai.resolve.findInitialModel(.{
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
        .resume_session => |path| .{ .resume_session = path },
        .resume_picker => .resume_picker,
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
) std.mem.Allocator.Error!StartupResolution {
    return switch (options.session_target) {
        .none => .{ .ok = if (options.initial_prompt) |prompt| .{ .prompt = prompt } else .none },
        .picker => .{ .ok = .resume_picker },
        .most_recent => .{ .ok = .{ .resume_session = switch (try resolveMostRecentSessionPath(allocator, cwd)) {
            .ok => |path| path,
            .err => |diag| return .{ .err = diag },
        } } },
        .reference => |ref| .{ .ok = .{ .resume_session = switch (try resolveSessionReference(allocator, cwd, ref)) {
            .ok => |path| path,
            .err => |diag| return .{ .err = diag },
        } } },
    };
}

fn startupActionResumesSession(action: ResolvedStartupAction) bool {
    return switch (action) {
        .resume_session => true,
        .none, .prompt, .resume_picker => false,
    };
}

fn resolveMostRecentSessionPath(
    allocator: std.mem.Allocator,
    cwd: []const u8,
) std.mem.Allocator.Error!SessionPathResolution {
    const path = session_store_mod.findMostRecentSession(allocator, cwd) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .err = .{ .session_lookup_failed = @errorName(err) } },
    };
    return .{ .ok = path orelse return .{ .err = .no_recent_session } };
}

fn resolveSessionReference(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    ref: []const u8,
) std.mem.Allocator.Error!SessionPathResolution {
    if (looksLikeSessionPath(ref)) {
        return try resolveExplicitSessionPath(allocator, cwd, ref);
    }

    const sessions = session_store_mod.listSessions(allocator, cwd) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .err = .{ .session_lookup_failed = @errorName(err) } },
    };
    defer session_store_mod.freeSessionInfos(allocator, sessions);

    var matched_path: ?[]const u8 = null;
    var match_count: usize = 0;
    for (sessions) |session| {
        if (!std.mem.startsWith(u8, session.session_id, ref)) continue;
        matched_path = session.path;
        match_count += 1;
        if (match_count > 1) break;
    }

    if (match_count == 0) return .{ .err = .{ .session_target_not_found = ref } };
    if (match_count > 1) return .{ .err = .{ .session_target_ambiguous = ref } };
    return .{ .ok = try allocator.dupe(u8, matched_path.?) };
}

fn resolveExplicitSessionPath(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    ref: []const u8,
) std.mem.Allocator.Error!SessionPathResolution {
    if (std.fs.path.isAbsolute(ref)) {
        return resolveAbsoluteSessionPath(allocator, ref, ref);
    }

    const joined = try std.fs.path.join(allocator, &.{ cwd, ref });
    defer allocator.free(joined);
    return resolveAbsoluteSessionPath(allocator, joined, ref);
}

fn resolveAbsoluteSessionPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    display_ref: []const u8,
) SessionPathResolution {
    const resolved = std.fs.realpathAlloc(allocator, path) catch |err| switch (err) {
        error.FileNotFound => return .{ .err = .{ .session_target_not_found = display_ref } },
        else => return .{ .err = .{ .session_lookup_failed = @errorName(err) } },
    };
    return .{ .ok = resolved };
}

fn looksLikeSessionPath(ref: []const u8) bool {
    return std.fs.path.isAbsolute(ref) or
        std.mem.indexOfScalar(u8, ref, '/') != null or
        std.mem.indexOfScalar(u8, ref, '\\') != null or
        std.mem.endsWith(u8, ref, ".jsonl");
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
    interactive.loader.shimmer_peak_fg = @import("../tui/cell.zig").Color.rgb(0xF2, 0xF1, 0xEF);
}
