const std = @import("std");
const ai = @import("../../ai/root.zig");
const model_resolve = @import("../resolve.zig");
const logging = @import("../../logging.zig");
const coding_agent_mod = @import("../root.zig");
const sdk = @import("../sdk.zig");
const interactive_mod = @import("../../tui/interactive.zig");
const tool_display = @import("../../tui/conversation/tool_display.zig");
const builtin_renderers = @import("../../tui/conversation/renderers/builtins.zig");
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

    const stdin_file: std.Io.File = .{ .handle = std.posix.STDIN_FILENO, .flags = .{ .nonblocking = false } };
    const stdout_file: std.Io.File = .{ .handle = std.posix.STDOUT_FILENO, .flags = .{ .nonblocking = false } };
    if (!(stdin_file.isTty(std.Options.debug_io) catch false) or !(stdout_file.isTty(std.Options.debug_io) catch false)) {
        return .{ .err = .interactive_requires_tty };
    }

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

    const provider_str = ai.json_util.providerToString(effective_model.provider);
    const api_key: []const u8 = if (options.api_key) |cli_key| blk: {
        runtime.auth_storage.setRuntimeApiKey(provider_str, cli_key);
        break :blk cli_key;
    } else "";
    const needs_auth = !runtime.auth_storage.hasAuth(provider_str);
    const allowlist_opt = try common.parseToolAllowlist(ctx.allocator, options.tool_allowlist_csv);

    const session_create_options: sdk.CreateOptions = .{
        .model = effective_model,
        .api_key = api_key,
        .cwd = runtime.cwd,
        .io = runtime.io,
        .max_tokens = 4096,
        .auth_storage = runtime.auth_storage,
        .settings_manager = runtime.settings_manager,
        .model_registry = runtime.model_registry,
        .thinking_level = common.aiToAgentThinking(init_result.thinking_level),
        .no_session = options.no_session,
        .append_system_prompt = options.append_system_prompt,
        .tool_allowlist = allowlist_opt,
    };
    const session_ptr = try ctx.allocator.create(sdk.AgentSession);
    errdefer ctx.allocator.destroy(session_ptr);
    session_ptr.* = try sdk.createAgentSession(ctx.allocator, session_create_options);
    errdefer session_ptr.deinit();

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
    const runtime_host = try coding_agent_mod.RuntimeHost.init(session_ptr, ctx.allocator, ctx.msg_allocator, session_create_options, .{
        .retry_policy = .{
            .enabled = retry_settings.enabled,
            .max_retries = @intCast(@max(retry_settings.max_retries, 0)),
            .base_delay_ms = @intCast(@max(retry_settings.base_delay_ms, 0)),
            .max_delay_ms = @intCast(@max(retry_settings.max_delay_ms, 0)),
        },
        .compaction_policy = .{
            .enabled = compaction_settings.enabled,
            .reserve_tokens = @intCast(@max(compaction_settings.reserve_tokens, 0)),
            .keep_recent_tokens = @intCast(@max(compaction_settings.keep_recent_tokens, 0)),
        },
    });
    var interactive = try interactive_mod.Interactive.init(
        ctx.allocator,
        ctx.msg_allocator,
        runtime_host,
        resolver,
        runtime.cwd,
        runtime.io,
        runtime.auth_storage,
        runtime.settings_manager,
    );
    defer interactive.deinit();

    interactive.runtime_host.setCompactionExecutor(compactor.createExecutor());
    interactive.applyTheme(interactive.runtime_host.selectedTheme());
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
        interactive.status_line.setPrimary("no API key — use /login to authenticate", interactive.theme.fg(.warning));
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

    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "notes.txt", .data = "hello from file" });
    const cwd = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
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
