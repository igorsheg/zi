const std = @import("std");
const DiagnosticText = @import("DiagnosticText.zig");
const agent = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const config = @import("../config/root.zig");
const persistence = @import("../persistence/root.zig");
const tool = @import("../tool/root.zig");
const terminal_module = @import("../terminal/root.zig");
const SecureAllocator = @import("../ai/SecureAllocator.zig");
const SecureOpen = @import("../SecureOpen.zig");
const CatalogService = @import("../CatalogService.zig");
const ProviderRuntime = @import("../ProviderRuntime.zig");
const ProviderConfig = @import("../ProviderConfig.zig");
const ProviderHeaders = @import("../ProviderHeaders.zig");
const CodexRuntime = @import("../CodexRuntime.zig");
const CodexAuth = @import("../CodexAuth.zig");
const ToolRuntime = @import("../ToolRuntime.zig");
const SessionDurability = @import("../SessionDurability.zig");
const SessionRetentionService = @import("../SessionRetentionService.zig");
const PromptAssembly = @import("../PromptAssembly.zig");
const GitProbe = @import("../GitProbe.zig");
const Args = @import("Args.zig");
const ProcessAdapters = @import("ProcessAdapters.zig");
const ProcessFacts = @import("ProcessFacts.zig");
const CodexFiles = @import("CodexFiles.zig");
const SessionStartup = @import("SessionStartup.zig");
const StartupConfig = @import("StartupConfig.zig");
const LocalStartup = @import("LocalStartup.zig");
const OneShot = @import("OneShot.zig");
const Interactive = @import("Interactive.zig");
const Stats = @import("Stats.zig");

pub const version = "0.1.0-dev";

pub const Mode = union(enum) {
    print: []const u8,
    interactive,
};

/// Runs the production CLI. All process snapshots are taken once here and then
/// passed explicitly to lower layers.
pub fn run(
    init: std.process.Init,
    options: *const Args.Options,
    mode: Mode,
    parent_subagent_depth: u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const allocator = init.gpa;
    const io = init.io;
    var environment = ProcessAdapters.Environment.fromProcess(init);
    const path_inputs = environment.pathInputs();
    const cwd = try ProcessAdapters.acquireCwd(allocator, io);
    defer allocator.free(cwd);
    var paths = try ProcessAdapters.RuntimePaths.init(allocator, path_inputs);
    defer paths.deinit(allocator);
    var secure_open: SecureOpen.Posix = .{};
    var random = ProcessAdapters.Random.init(io);
    var task_time = ProcessAdapters.TaskTime.init(io);
    var facts = try ProcessFacts.init(allocator, io, environment.get("PATH"));
    defer facts.deinit();

    const canonicalizer: ProviderCanonicalizer = .{};
    var prepared = try StartupConfig.prepare(.{
        .allocator = allocator,
        .io = io,
        .path_inputs = path_inputs,
        .file_access = .{
            .secure_open = secure_open.configCapability(),
            .home = path_inputs.home,
            .cwd = cwd,
        },
        .environment = &environment,
        .selection = options.selection,
        .strict_one_shot = options.mode == .print,
        .provider_canonicalizer = config.Store.ProviderCanonicalizer.from(&canonicalizer),
    });
    var prepared_owned = true;
    defer if (prepared_owned) prepared.deinit();
    const retention_days = (try config.Settings.getInt(
        prepared.storeBeforeResume(),
        allocator,
        "session_retention_days",
    )).value;
    const now_epoch_seconds = ProcessAdapters.wallEpochSeconds(io);
    const resume_cutoff = retentionCutoff(now_epoch_seconds, retention_days);

    var resolved: ?*SessionStartup.Resolved = null;
    const resolution = try SessionStartup.resolve(.{
        .allocator = allocator,
        .io = io,
        .state_root = paths.state_root,
        .cwd = cwd,
        .resume_state = options.resume_state,
        .cutoff_epoch_seconds = resume_cutoff,
    });
    switch (resolution) {
        .absent => {},
        .found => |value| resolved = value,
        .not_found => return diagnostic(stderr, "no matching session found"),
        .ambiguous => return diagnostic(stderr, "session id is ambiguous"),
        .id_is_path => return diagnostic(stderr, "--resume expects a session id, not a path"),
        .requires_picker => return diagnostic(stderr, "interactive session selection is not implemented yet"),
    }
    defer if (resolved) |value| value.deinit();
    var retention: ?*SessionRetentionService.Owner = null;
    defer if (retention) |owner| owner.deinit();
    if (retention_days != 0) {
        if (paths.state_root) |state_root| {
            const owner = try SessionRetentionService.Owner.create(allocator, io, .{
                .state_root = state_root,
                .now_epoch_seconds = now_epoch_seconds,
                .days = @intCast(retention_days),
                .exclude_path = if (resolved) |value| value.path() else null,
            });
            retention = owner;
            _ = owner.start();
        }
    }
    const fresh_uuid = try random.uuidV4();
    var session_cache_key = formatUuid(fresh_uuid);

    const restored: ?config.Selection.RestoreMetadata = if (resolved) |value| blk: {
        const selection = value.selection();
        break :blk .{
            .provider = selection.provider,
            .model = selection.model,
            .effort = selection.effort,
            .preset = selection.preset,
        };
    } else null;
    const startup_result = try StartupConfig.finish(&prepared, restored);
    prepared_owned = false;
    var startup = switch (startup_result) {
        .owner => |value| value,
        .fatal => |value| {
            var problem = value;
            defer problem.deinit(allocator);
            try renderPresetDiagnostic(stderr, problem);
            return 1;
        },
    };
    defer startup.deinit();
    try renderWarnings(stderr, startup.warnings());
    try renderProviderWarnings(stderr, startup.providerWarnings());

    var codex_files = try CodexFiles.init(allocator, io, path_inputs.home);
    defer codex_files.deinit();
    var codex_settings = try loadCodexSettings(allocator, codex_files);
    defer codex_settings.deinit();

    var http = try ai.HttpTransport.Runtime.init(allocator, io, init.minimal.environ);
    defer http.deinit();
    var http_transport = http.transport();

    var codex_runtime: ?*CodexRuntime.Owner = null;
    defer if (codex_runtime) |owner| owner.deinit();
    var codex_failure: ?CodexAuth.InitFailure = null;
    switch (try CodexRuntime.Owner.create(
        allocator,
        io,
        paths.state_root,
        codex_files.credentialsLoader(),
        http_transport.json(),
        random.nonceSource(),
        .system,
    )) {
        .ready => |owner| codex_runtime = owner,
        .failure => |failure| codex_failure = failure,
    }
    var selected_provider = try config.Settings.getString(startup.store(), allocator, "provider");
    defer selected_provider.deinit(allocator);
    if (codex_failure) |failure| if (isExplicitCodex(selected_provider.value)) {
        try renderCodexAuthDiagnostic(stderr, codex_files.authPath(), failure);
        return 1;
    };

    var llama_outcome: ?LocalStartup.LlamaOutcome = null;
    defer if (llama_outcome) |*outcome| outcome.deinit();
    var llama_headers: ?LocalStartup.ResolvedHeaders = null;
    defer if (llama_headers) |*headers| headers.deinit(allocator);
    var ollama_headers: ?LocalStartup.ResolvedHeaders = null;
    defer if (ollama_headers) |*headers| headers.deinit(allocator);
    var ollama_available = false;
    if (isExplicitLlama(selected_provider.value)) {
        llama_headers = try LocalStartup.resolveHeaders(
            allocator,
            startup.providerDefinitions(),
            "llamacpp",
            environment.apiKey(),
        );
        try renderProviderHeaderWarnings(stderr, "llamacpp", llama_headers.?.warnings);
        var prepared_llama = try LocalStartup.PreparedLlama.init(
            allocator,
            startup.store(),
            llama_headers.?.headers,
            null,
        );
        defer prepared_llama.deinit();
        llama_outcome = try LocalStartup.executeLlama(
            allocator,
            io,
            http_transport.json(),
            &prepared_llama,
        );
        try llama_outcome.?.renderWarnings(stderr);
        if (llama_outcome.?.fatalForExplicit()) {
            try renderLlamaDiscoveryDiagnostic(stderr, prepared_llama.probe.base_url);
            return 1;
        }
    } else if (isExplicitOllama(selected_provider.value)) {
        ollama_headers = try LocalStartup.resolveHeaders(
            allocator,
            startup.providerDefinitions(),
            "ollama",
            environment.apiKey(),
        );
        try renderProviderHeaderWarnings(stderr, "ollama", ollama_headers.?.warnings);
    } else if (!hasExplicitProvider(selected_provider.value) and codex_runtime == null) {
        llama_headers = try LocalStartup.resolveHeaders(
            allocator,
            startup.providerDefinitions(),
            "llamacpp",
            environment.apiKey(),
        );
        try renderProviderHeaderWarnings(stderr, "llamacpp", llama_headers.?.warnings);
        ollama_headers = try LocalStartup.resolveHeaders(
            allocator,
            startup.providerDefinitions(),
            "ollama",
            environment.apiKey(),
        );
        try renderProviderHeaderWarnings(stderr, "ollama", ollama_headers.?.warnings);
        var prepared_llama = try LocalStartup.PreparedLlama.init(
            allocator,
            startup.store(),
            llama_headers.?.headers,
            null,
        );
        defer prepared_llama.deinit();
        var prepared_ollama = try LocalStartup.prepareOllama(
            allocator,
            startup.providerDefinitions(),
            ollama_headers.?.headers,
            null,
        );
        defer if (prepared_ollama) |*probe| probe.deinit();

        if (prepared_ollama) |*ollama_probe| {
            var llama_future = io.async(LocalStartup.executeReachability, .{
                allocator,
                io,
                http_transport.json(),
                &prepared_llama.probe,
            });
            var ollama_future = io.async(LocalStartup.executeReachability, .{
                allocator,
                io,
                http_transport.json(),
                ollama_probe,
            });
            // Future cancellation also joins the task. Keep both borrowed probes
            // alive even when either await reports cancellation or allocation failure.
            defer {
                _ = llama_future.cancel(io) catch false;
                _ = ollama_future.cancel(io) catch false;
            }
            const llama_reachable = try llama_future.await(io);
            ollama_available = try ollama_future.await(io);
            if (llama_reachable) {
                llama_outcome = try LocalStartup.executeLlama(
                    allocator,
                    io,
                    http_transport.json(),
                    &prepared_llama,
                );
            }
        } else if (try LocalStartup.executeReachability(
            allocator,
            io,
            http_transport.json(),
            &prepared_llama.probe,
        )) {
            llama_outcome = try LocalStartup.executeLlama(
                allocator,
                io,
                http_transport.json(),
                &prepared_llama,
            );
        }
        if (llama_outcome) |*outcome| try outcome.renderWarnings(stderr);
    }

    var catalog: ?*CatalogService.Owner = null;
    defer if (catalog) |value| {
        _ = value.cancelAndDrain();
        value.deinit();
    };
    var catalog_url = try config.Settings.getString(startup.store(), allocator, "catalog.url");
    defer catalog_url.deinit(allocator);
    const catalog_refresh = try config.Settings.getDurationMs(startup.store(), allocator, "catalog.refresh");
    if (paths.cache_root) |cache_root| if (catalog_url.value) |url| if (url.len != 0) {
        const cache_ready = ready: {
            ProcessAdapters.ensurePrivateCacheRoot(io, cache_root) catch {
                try stderr.writeAll("zi: warning: catalog cache directory is unavailable; skipping refresh\n");
                break :ready false;
            };
            break :ready true;
        };
        if (cache_ready) catalog = try CatalogService.Owner.create(allocator, io, http_transport.json(), .{
            .cache_root = cache_root,
            .url = url,
            .refresh_ms = catalog_refresh.value,
            .now_seconds = ProcessAdapters.wallEpochSeconds(io),
            .nonce_source = random.nonceSource(),
        });
    };
    var hints: CatalogHints = .{ .owner = catalog };
    const http_max_retries: u16 = @intCast((try config.Settings.getInt(
        startup.store(),
        allocator,
        "http.max_retries",
    )).value);
    const http_retry_base = (try config.Settings.getDurationMs(
        startup.store(),
        allocator,
        "http.retry_base",
    )).value;
    const http_idle_timeout = (try config.Settings.getDurationMs(
        startup.store(),
        allocator,
        "http.idle_timeout",
    )).value;

    var provider_runtime = try ProviderRuntime.init(.{
        .allocator = allocator,
        .store = startup.store(),
        .api_key_environment = environment.apiKey(),
        .provider_definitions = startup.providerDefinitions(),
        .codex_available = codex_runtime != null,
        .codex_source = if (codex_runtime) |owner| owner.credentialSource() else null,
        .default_model = codex_settings.model,
        .default_effort = codex_settings.model_reasoning_effort,
        .llamacpp_available = if (llama_outcome) |*outcome| outcome.constructible() else false,
        .ollama_available = ollama_available,
        .llama_reconciliation = if (llama_outcome) |*outcome| outcome.reconciliation() else null,
        .prepared_headers = if (llama_headers != null and
            (if (llama_outcome) |*outcome| outcome.constructible() else false))
            .{ .provider_id = "llamacpp", .headers = llama_headers.?.headers }
        else if (ollama_headers) |*headers|
            .{ .provider_id = "ollama", .headers = headers.headers }
        else
            null,
        .session_cache_key = &session_cache_key,
        .hints_source = if (catalog != null) ProviderConfig.ModelHintsSource.from(&hints) else null,
        .http_policy = .{
            .max_retries = http_max_retries,
            .retry_base_ms = http_retry_base,
            .idle_timeout_ms = http_idle_timeout,
        },
    }, http_transport.streaming(), 0);
    defer provider_runtime.deinit();
    try renderProviderHeaderWarnings(
        stderr,
        provider_runtime.metadata.provider_id,
        provider_runtime.headerWarnings(),
    );

    var selected_preset = try config.Settings.getString(startup.store(), allocator, "preset");
    defer selected_preset.deinit(allocator);
    const final_selection: persistence.SessionFile.Selection = .{
        .provider = provider_runtime.metadata.provider_id,
        .model = provider_runtime.model,
        .model_label = provider_runtime.model,
        .effort = provider_runtime.effort,
        .preset = selected_preset.value,
    };

    var no_session_setting = try config.Settings.getString(startup.store(), allocator, "no_session");
    defer no_session_setting.deinit(allocator);
    const no_session = options.no_session or noSessionConfigured(
        no_session_setting.value,
        provider_runtime.metadata.provider_id,
    );
    const needs_git_probe = shouldCreateGitEnvironment(resolved != null, no_session, paths.state_root != null);
    var environment_wiper = SecureAllocator.WipingAllocator.init(allocator);
    var environment_map: ?std.process.Environ.Map = if (needs_git_probe)
        try std.process.Environ.createMap(init.minimal.environ, environment_wiper.allocator())
    else
        null;
    defer if (environment_map) |*value| value.deinit();
    var git_adapter: ?LazyGit = if (environment_map) |*value| .{ .options = .{
        .cwd = cwd,
        .environ = value,
        .path = environment.get("PATH"),
    } } else null;
    const git_probe = if (git_adapter) |*value| persistence.SessionFile.GitProbe.from(value) else null;
    var session_run = try SessionStartup.start(resolved, final_selection, .{
        .allocator = allocator,
        .io = io,
        .state_root = paths.state_root,
        .cwd = cwd,
        .no_session = no_session,
        .new_identity = .{
            .timestamp = ProcessAdapters.wallTimestamp(io),
            .uuid = fresh_uuid,
            .git_probe = git_probe,
        },
        .writer_version = version,
    });
    resolved = null;
    defer session_run.deinit();
    if (session_run.warning()) |warning| switch (warning) {
        .resume_append_unavailable => |path| {
            try stderr.writeAll("zi: warning: cannot append to session '");
            try DiagnosticText.write(stderr, path);
            try stderr.writeAll("'; this run won't be recorded\n");
        },
    };

    const durability: ?*SessionDurability.Owner = if (session_run.log()) |log|
        try SessionDurability.Owner.create(allocator, log, .{})
    else
        null;
    defer if (durability) |value| value.deinit();
    const durability_seam = if (durability) |value| value.seamHook() else null;
    var compaction_marker: CompactionMarker = .{
        .stderr = stderr,
        .style = ProcessAdapters.isTty(io, .stderr()),
    };
    var run_seam: RunSeam = .{
        .downstream = durability_seam,
        .marker = &compaction_marker,
    };
    const run_seam_hook = agent.Loop.SeamHook.from(&run_seam);

    const store = startup.store();
    const no_tasks = (try config.Settings.getBool(store, allocator, "no_tasks")).value;
    const tool_output_cap = try usizeSetting(allocator, store, "tool_output_cap");
    const bash_timeout = (try config.Settings.getDurationMs(store, allocator, "bash.timeout")).value;
    const bash_timeout_max = (try config.Settings.getDurationMs(store, allocator, "bash.timeout_max")).value;
    const bash_timeout_grace = (try config.Settings.getDurationMs(store, allocator, "bash.timeout_grace")).value;
    const bash_background_yield = (try config.Settings.getDurationMs(
        store,
        allocator,
        "bash.background_yield",
    )).value;
    const task_wait_timeout = (try config.Settings.getDurationMs(store, allocator, "task.wait_timeout")).value;
    const task_max_running: usize = @intCast((try config.Settings.getInt(
        store,
        allocator,
        "task.max_running",
    )).value);
    var bash_shell = try config.Settings.getString(store, allocator, "bash.shell");
    defer bash_shell.deinit(allocator);
    var tools = try ToolRuntime.init(.{
        .allocator = allocator,
        .io = io,
        .environ = init.minimal.environ,
        .home = path_inputs.home,
        .path_env = environment.get("PATH"),
        .clock = task_time.clock(),
        .poller = task_time.poller(),
        .task_config = .{
            .max_running = task_max_running,
            .wait_timeout_ms = task_wait_timeout,
            .termination_grace_ms = bash_timeout_grace,
            .model_bytes = tool_output_cap,
        },
        .read_config = .{ .output_bytes = tool_output_cap },
        .bash_config = .{
            .shell = bash_shell.value,
            .timeout_ms = bash_timeout,
            .maximum_timeout_ms = bash_timeout_max,
            .termination_grace_ms = bash_timeout_grace,
            .output = .{ .model_bytes = tool_output_cap },
            .background_yield_ms = bash_background_yield,
        },
        .run_selection = .{
            .provider = provider_runtime.metadata.provider_id,
            .model = provider_runtime.model,
            .effort = provider_runtime.effort,
        },
        .parent_subagent_depth = parent_subagent_depth,
        .enable_tools = !options.raw,
        .enable_tasks = !options.raw and !no_tasks,
    });
    defer tools.deinit();
    const pre_request_hook = try tools.taskNotesHook(run_seam_hook);

    var base_prompt = try config.Settings.getString(store, allocator, "system_prompt");
    defer base_prompt.deinit(allocator);
    var append_prompt = try config.Settings.getString(store, allocator, "system_prompt_append");
    defer append_prompt.deinit(allocator);
    var resolved_base: ?config.PromptValue.Value = null;
    defer if (resolved_base) |*value| value.deinit(allocator);
    var resolved_append: ?config.PromptValue.Value = null;
    defer if (resolved_append) |*value| value.deinit(allocator);
    const config_root = if (startup.configResult()) |result| std.fs.path.dirname(result.path) else null;
    if (base_prompt.value) |value| resolved_base = try config.PromptValue.resolve(
        allocator,
        io,
        secure_open.configCapability(),
        value,
        config_root,
        path_inputs.home,
        cwd,
    );
    if (append_prompt.value) |value| resolved_append = try config.PromptValue.resolve(
        allocator,
        io,
        secure_open.configCapability(),
        value,
        config_root,
        path_inputs.home,
        cwd,
    );
    const no_environment = (try config.Settings.getBool(store, allocator, "no_env")).value;
    const no_project = options.bare or (try config.Settings.getBool(store, allocator, "no_agents_md")).value;
    const no_skills = options.bare or (try config.Settings.getBool(store, allocator, "no_skills")).value;
    const no_subagents = options.bare or (try config.Settings.getBool(store, allocator, "no_subagents")).value;
    const base_value = if (resolved_base) |value| value.text else null;
    const base_kind: agent.SystemPrompt.Base = if (base_value) |value|
        if (std.mem.eql(u8, value, "(none)")) .none else .{ .custom = value }
    else
        .default;
    const preset_plans = startup.presetPlans();
    const prompt_presets = try allocator.alloc(agent.Context.Preset, preset_plans.len);
    defer allocator.free(prompt_presets);
    for (preset_plans, prompt_presets) |plan, *preset| preset.* = .{
        .name = plan.name,
        .description = plan.description.value orelse "",
    };
    var system_prompt = try PromptAssembly.build(allocator, io, .{
        .raw = options.raw,
        .base = base_kind,
        .append = if (resolved_append) |value| value.text else null,
        .features = .{
            .tasks = !options.raw and !no_tasks,
            .subagents = !options.raw and !no_subagents,
            .environment = !options.raw and !no_environment,
            .project = !options.raw and !no_project,
            .skills = !options.raw and !no_skills,
        },
        .tool_facts = facts.toolFacts(),
        .environment = .{
            .cwd = cwd,
            .home = path_inputs.home,
            .os_description = facts.osDescription(),
            .command_shell = tools.commandShell(),
            .model = provider_runtime.model,
        },
        .guidance = .{
            .secure_open = secure_open.agentCapability(),
            .cwd = cwd,
            .home = path_inputs.home,
            .config_root = paths.config_root,
        },
        .skills = .{
            .secure_open = secure_open.agentCapability(),
            .cwd = cwd,
            .home = path_inputs.home,
            .config_root = paths.config_root,
        },
        .presets = prompt_presets,
    });
    defer if (system_prompt) |*value| value.deinit(allocator);

    var usage = try agent.UsageStats.UsageStats.init(allocator, agent.UsageStats.maximum_retained_attempts);
    defer usage.deinit();
    const context_override = (try config.Settings.getSize(store, allocator, "context_limit")).value;
    const manual_context_limit: ?u64 = if (context_override != 0) context_override else null;
    const context_limit: ?u64 = if (manual_context_limit) |value|
        value
    else if (provider_runtime.metadata.model.context_window != 0)
        provider_runtime.metadata.model.context_window
    else
        null;
    var stats: Stats.Renderer = .{ .context_limit = context_limit };
    var image_input_setting = try config.Settings.getString(store, allocator, "image_input");
    defer image_input_setting.deinit(allocator);
    const image_policy = try parseImageInputPolicy(image_input_setting.value);
    const image_input = image_policy.resolveFixed(provider_runtime.metadata.model.image_input);
    var catalog_runtime: CatalogRuntime = .{
        .allocator = allocator,
        .io = io,
        .owner = catalog,
        .runtime = &provider_runtime,
        .provider_id = provider_runtime.metadata.catalog_id,
        .model_id = provider_runtime.model,
    };
    var image_source: DynamicImageInput = .{
        .policy = image_policy,
        .catalog_runtime = &catalog_runtime,
    };
    var model_metadata_source: DynamicModelMetadata = .{
        .catalog_runtime = &catalog_runtime,
    };
    var effort_source: DynamicEffort = .{ .runtime = &provider_runtime };
    const compact_enabled = (try config.Settings.getBool(store, allocator, "compact.auto")).value;
    const configured_max_turns = (try config.Settings.getInt(store, allocator, "max_turns")).value;
    const interactive_max_turns: usize = if (configured_max_turns <= 0)
        agent.Loop.maximum_max_turns
    else
        @min(@as(usize, @intCast(configured_max_turns)), agent.Loop.maximum_max_turns);
    const compact_threshold: u8 = @intCast((try config.Settings.getInt(store, allocator, "compact.threshold")).value);
    var compaction: AutoCompact = .{
        .allocator = allocator,
        .io = io,
        .provider = provider_runtime.provider(),
        .model = provider_runtime.model,
        .metadata = provider_runtime.metadata.model,
        .model_metadata_source = agent.ModelMetadataSource.ModelMetadataSource.from(&model_metadata_source),
        .system_prompt = if (system_prompt) |value| value.bytes else "",
        .tools = tools.tools(),
        .tool_runtime = &tools,
        .durability = durability,
        .effort = provider_runtime.effort,
        .usage = &usage,
        .catalog_runtime = &catalog_runtime,
        .manual_context_limit = manual_context_limit,
        .seam_hook = run_seam_hook,
        .marker = &compaction_marker,
        .context_limit = context_limit,
        .enabled = compact_enabled,
        .threshold = compact_threshold,
    };
    var terminal: Terminal = .{ .tools = &tools };
    var session_info: SessionInfo = .{
        .run = session_run,
        .runtime = &provider_runtime,
        .preset = nonEmpty(selected_preset.value),
        .resumed = restored != null,
    };
    var catalog_hook: CatalogHook = .{
        .catalog_runtime = &catalog_runtime,
        .stats = &stats,
        .compaction = &compaction,
        .manual_context_limit = manual_context_limit,
    };
    image_source.effects = &catalog_hook;
    model_metadata_source.effects = &catalog_hook;
    compaction.effects = &catalog_hook;

    const run_result = switch (mode) {
        .print => |prompt| OneShot.run(allocator, io, .{
            .session = session_run.session(),
            .provider = provider_runtime.provider(),
            .model = provider_runtime.model,
            .model_metadata = provider_runtime.metadata.model,
            .model_metadata_source = agent.ModelMetadataSource.ModelMetadataSource.from(&model_metadata_source),
            .system_prompt = if (system_prompt) |value| value.bytes else "",
            .tools = tools.tools(),
            .effort = provider_runtime.effort,
            .image_input = image_input,
            .image_input_source = agent.ImageInputSource.ImageInputSource.from(&image_source),
            .prompt = prompt,
            .stdout = stdout,
            .stderr = stderr,
            .seam_hook = run_seam_hook,
            .pre_request_hook = pre_request_hook,
            .continuation_hook = agent.Loop.ContinuationHook.from(&compaction),
            .usage_stats = &usage,
            .session_info_hook = OneShot.SessionInfoHook.from(&session_info),
            .catalog_hook = if (catalog != null and provider_runtime.metadata.catalog_id != null)
                OneShot.CatalogHook.from(&catalog_hook)
            else
                null,
            .terminal_hook = OneShot.TerminalHook.from(&terminal),
            .stats_renderer = stats.renderer(),
            .style_diagnostics = ProcessAdapters.isTty(io, .stderr()),
        }),
        .interactive => interactive: {
            try stderr.flush();
            var interactive_catalog: InteractiveCatalog = .{
                .catalog_hook = &catalog_hook,
                .stderr = stderr,
            };
            var stdin_buffer: [4096]u8 = undefined;
            var stdin_file = std.Io.File.Reader.initStreaming(.stdin(), io, &stdin_buffer);
            const interactive_terminal = ProcessAdapters.isTty(io, .stdin()) and
                ProcessAdapters.isTty(io, .stdout());
            const interactive_inputs: Interactive.Inputs = .{
                .session = session_run.session(),
                .provider = provider_runtime.provider(),
                .model = provider_runtime.model,
                .model_metadata = provider_runtime.metadata.model,
                .model_metadata_source = agent.ModelMetadataSource.ModelMetadataSource.from(&model_metadata_source),
                .system_prompt = if (system_prompt) |value| value.bytes else "",
                .tools = tools.tools(),
                .effort = provider_runtime.effort,
                .effort_source = Interactive.EffortSource.from(&effort_source),
                .image_input = image_input,
                .image_input_source = agent.ImageInputSource.ImageInputSource.from(&image_source),
                .reader = &stdin_file.interface,
                .stdout = stdout,
                .stderr = stderr,
                .show_prompt = interactive_terminal,
                .seam_hook = run_seam_hook,
                .pre_request_hook = pre_request_hook,
                .continuation_hook = agent.Loop.ContinuationHook.from(&compaction),
                .usage_observer = agent.Loop.UsageObserver.from(&usage),
                .max_turns = interactive_max_turns,
                .before_first_send = if (catalog != null and provider_runtime.metadata.catalog_id != null)
                    Interactive.BeforeFirstSend.from(&interactive_catalog)
                else
                    null,
            };
            break :interactive if (interactive_terminal)
                runRawInteractive(
                    allocator,
                    io,
                    interactive_inputs,
                    http,
                    &compaction,
                    &terminal,
                )
            else
                runInteractiveWithFinish(allocator, io, interactive_inputs, &terminal);
        },
    };
    const publication = if (codex_runtime) |owner| owner.takePublicationOutcome() else null;
    if (run_result) |exit_code| {
        if (publication) |outcome| try renderPublicationWarning(stderr, outcome);
        return exit_code;
    } else |run_error| {
        stdout.flush() catch |write_error| ignoreWriterFailure(write_error);
        if (publication) |outcome| renderPublicationWarning(stderr, outcome) catch |write_error|
            ignoreWriterFailure(write_error);
        return run_error;
    }
}

const HttpWake = struct {
    runtime: *ai.HttpTransport.Runtime,

    pub fn wake(self: *HttpWake) void {
        self.runtime.wakeup() catch |err| ignoreHttpWakeError(err);
    }
};

fn ignoreHttpWakeError(err: error{ OutOfMemory, ConnectionFailed }) void {
    _ = @errorName(err);
}

fn ignoreTerminalCleanupError(err: anyerror) void {
    _ = @errorName(err);
}

const TerminalCheckpoint = struct {
    interrupt: *terminal_module.GenerationInterrupt,

    pub fn sample(self: *TerminalCheckpoint) agent.Loop.Signal {
        return mapTerminalSignal(self.interrupt.sample());
    }

    pub fn resolve(self: *TerminalCheckpoint) agent.Loop.Signal {
        return mapTerminalSignal(self.interrupt.resolve());
    }
};

const CompactCancellation = struct {
    interrupt: *terminal_module.GenerationInterrupt,

    pub fn sample(self: *CompactCancellation) bool {
        return self.interrupt.sample() != .none;
    }
};

fn mapTerminalSignal(signal_value: terminal_module.GenerationInterrupt.Signal) agent.Loop.Signal {
    return switch (signal_value) {
        .none => .none,
        .pause => .pause,
        .abort => .abort,
    };
}

const InteractiveCatalog = struct {
    catalog_hook: *CatalogHook,
    stderr: *std.Io.Writer,

    pub fn call(self: *InteractiveCatalog) Interactive.BeforeFirstSendError!void {
        try prefetchInteractiveCatalog(self.catalog_hook, self.stderr);
        try self.stderr.flush();
    }
};

fn prefetchInteractiveCatalog(
    catalog_hook: *CatalogHook,
    stderr: *std.Io.Writer,
) Interactive.BeforeFirstSendError!void {
    const outcome = catalog_hook.prefetch() catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Indeterminate => error.Indeterminate,
        error.InvalidPlan => error.InvalidPlan,
        error.Failed => {},
    };
    switch (outcome) {
        .started, .unavailable => {},
        .warning => |warning| {
            try stderr.writeAll("zi: warning: ");
            try DiagnosticText.write(stderr, warning);
            try stderr.writeByte('\n');
        },
    }
}

fn runRawInteractive(
    allocator: std.mem.Allocator,
    io: std.Io,
    inputs_value: Interactive.Inputs,
    http: *ai.HttpTransport.Runtime,
    compaction: *AutoCompact,
    terminal_owner: *Terminal,
) !u8 {
    const stdin_file: std.Io.File = .stdin();
    const stdout_file: std.Io.File = .stdout();
    const original = try std.posix.tcgetattr(stdin_file.handle);
    try terminal_module.SignalRestore.install(.{
        .terminal_fd = stdin_file.handle,
        .output_fd = stdout_file.handle,
        .saved_termios = original,
        .terminal_active = true,
        .interactive_terminal = true,
    });
    var restoration_owned = true;
    errdefer if (restoration_owned) terminal_module.SignalRestore.restore() catch |err| ignoreTerminalCleanupError(err);

    var http_wake: HttpWake = .{ .runtime = http };
    var interrupt = try terminal_module.GenerationInterrupt.init(
        allocator,
        io,
        stdin_file,
        stdout_file,
        terminal_module.GenerationInterrupt.Wake.from(&http_wake),
    );
    var interrupt_owned = true;
    errdefer if (interrupt_owned) interrupt.deinit() catch |err| ignoreTerminalCleanupError(err);

    var raw_input = terminal_module.RawLineInput.init(
        allocator,
        io,
        stdin_file,
        stdout_file,
        inputs_value.stdout,
        "> ",
        .{ .empty_submit = true },
    );
    var checkpoint: TerminalCheckpoint = .{ .interrupt = &interrupt };
    var compact_cancellation: CompactCancellation = .{ .interrupt = &interrupt };
    compaction.cancellation = agent.CompactRunner.Cancellation.from(&compact_cancellation);
    defer compaction.cancellation = null;

    var inputs = inputs_value;
    inputs.prompt_input = Interactive.PromptInput.from(&raw_input);
    inputs.show_prompt = false;
    inputs.generation = Interactive.Generation.from(&interrupt);
    inputs.checkpoint = agent.Loop.Checkpoint.from(&checkpoint);

    const exit_code = runInteractiveWithFinish(allocator, io, inputs, terminal_owner) catch |run_error| {
        try cleanupRawTerminal(&interrupt);
        interrupt_owned = false;
        restoration_owned = false;
        return run_error;
    };
    try cleanupRawTerminal(&interrupt);
    interrupt_owned = false;
    restoration_owned = false;
    return exit_code;
}

fn cleanupRawTerminal(interrupt: *terminal_module.GenerationInterrupt) !void {
    interrupt.deinit() catch |cleanup_error| {
        terminal_module.SignalRestore.restore() catch |err| ignoreTerminalCleanupError(err);
        // Signal restoration repairs the kernel state. Retry to release joined
        // watcher storage, its wake descriptors, and any pending input flush.
        interrupt.deinit() catch |err| ignoreTerminalCleanupError(err);
        return cleanup_error;
    };
    try terminal_module.SignalRestore.restore();
}

fn runInteractiveWithFinish(
    allocator: std.mem.Allocator,
    io: std.Io,
    inputs: Interactive.Inputs,
    terminal_owner: *Terminal,
) !u8 {
    const exit_code = Interactive.run(allocator, io, inputs) catch |original_error| {
        terminal_owner.finish(inputs.session, inputs.seam_hook) catch |finish_error| {
            if (finish_error == error.Indeterminate) return error.Indeterminate;
        };
        return original_error;
    };
    try terminal_owner.finish(inputs.session, inputs.seam_hook);
    return exit_code;
}

const LazyGit = struct {
    options: GitProbe.Options,

    pub fn probe(
        allocator: std.mem.Allocator,
        io: std.Io,
        self: *LazyGit,
        cwd: []const u8,
    ) error{ OutOfMemory, Cancelled, Unavailable }!persistence.SessionFile.GitState {
        var options = self.options;
        options.cwd = cwd;
        var result = try GitProbe.probe(allocator, io, options);
        defer result.deinit(allocator);
        return switch (result) {
            .unavailable => error.Unavailable,
            .available => |state| state.toSessionFile(allocator),
        };
    }
};

fn formatUuid(uuid: [16]u8) [36]u8 {
    var result: [36]u8 = undefined;
    var source: usize = 0;
    var target: usize = 0;
    while (source < uuid.len) : (source += 1) {
        if (target == 8 or target == 13 or target == 18 or target == 23) {
            result[target] = '-';
            target += 1;
        }
        result[target] = hexDigit(uuid[source] >> 4);
        result[target + 1] = hexDigit(uuid[source] & 0x0f);
        target += 2;
    }
    return result;
}

fn hexDigit(value: u8) u8 {
    return if (value < 10) '0' + value else 'a' + value - 10;
}

fn retentionCutoff(now_seconds: i64, days: i32) i64 {
    if (days <= 0) return 0;
    const seconds = std.math.mul(i64, days, 86_400) catch std.math.maxInt(i64);
    return std.math.sub(i64, now_seconds, seconds) catch std.math.minInt(i64);
}

const ProviderCanonicalizer = struct {
    pub fn canonical(_: *const ProviderCanonicalizer, id: []const u8) []const u8 {
        return if (std.mem.eql(u8, id, "llama.cpp")) "llamacpp" else id;
    }
};

fn usizeSetting(allocator: std.mem.Allocator, store: config.Store, key: []const u8) !usize {
    const value = (try config.Settings.getSize(store, allocator, key)).value;
    return std.math.cast(usize, value) orelse error.InvalidSetting;
}

fn parseImageInputPolicy(value: ?[]const u8) !ImageInputPolicy {
    const setting = value orelse "auto";
    if (std.ascii.eqlIgnoreCase(setting, "auto")) return .automatic;
    if (std.mem.eql(u8, setting, "1") or std.ascii.eqlIgnoreCase(setting, "yes") or
        std.ascii.eqlIgnoreCase(setting, "true") or std.ascii.eqlIgnoreCase(setting, "on"))
        return .{ .fixed = .supported };
    if (std.mem.eql(u8, setting, "0") or std.ascii.eqlIgnoreCase(setting, "no") or
        std.ascii.eqlIgnoreCase(setting, "false") or std.ascii.eqlIgnoreCase(setting, "off"))
        return .{ .fixed = .unsupported };
    return error.InvalidSetting;
}

fn imageInputFromSupport(support: ai.ModelMeta.Support) ai.Provider.ImageInput {
    return switch (support) {
        .yes => .supported,
        .no => .unsupported,
        .unknown => .unknown,
    };
}

const CatalogHints = struct {
    owner: ?*CatalogService.Owner,

    pub fn lookup(
        self: *CatalogHints,
        allocator: std.mem.Allocator,
        provider_id: []const u8,
        model_id: []const u8,
    ) error{OutOfMemory}!ai.ModelCatalog.Contribution {
        const owner = self.owner orelse return .{};
        return owner.lookup(allocator, "", provider_id, model_id);
    }
};

const CatalogRuntime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    owner: ?*CatalogService.Owner,
    runtime: *ProviderRuntime.Owned,
    provider_id: ?[]const u8,
    model_id: []const u8,
    applied_replacement: bool = false,

    fn pollApply(self: *CatalogRuntime, maximum_wait_ms: u64) OneShot.CallbackError!?ai.ModelMeta.Metadata {
        const owner = self.owner orelse return null;
        const provider_id = self.provider_id orelse return null;
        const summary = if (maximum_wait_ms == 0) owner.poll() else owner.drain(maximum_wait_ms);
        if (!refreshWasReplaced(summary)) return null;
        if (!self.applied_replacement) {
            const contribution = owner.lookup(self.allocator, "", provider_id, self.model_id) catch
                return error.OutOfMemory;
            self.runtime.applyAuthoritativeCatalog(self.io, contribution) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.InvalidPlan,
            };
            self.applied_replacement = true;
        }
        return self.runtime.metadata.model;
    }
};

const CatalogHook = struct {
    catalog_runtime: *CatalogRuntime,
    stats: *Stats.Renderer,
    compaction: *AutoCompact,
    manual_context_limit: ?u64,
    warning_buffer: [160]u8 = undefined,

    pub fn prefetch(self: *CatalogHook) OneShot.CallbackError!OneShot.PrefetchOutcome {
        const owner = self.catalog_runtime.owner orelse return .unavailable;
        const start_result = owner.start() catch
            return .{ .warning = "model catalog refresh could not start" };
        if (start_result == .started and self.catalog_runtime.runtime.catalogWirePending(self.catalog_runtime.io)) {
            if (try self.catalog_runtime.pollApply(5_000)) |metadata| self.applyViews(metadata);
        }
        const started: OneShot.PrefetchOutcome = switch (start_result) {
            .started => .started,
            .disabled, .fresh, .already_attempted => .unavailable,
        };
        if (owner.poll().warning_days) |days| {
            const warning = std.fmt.bufPrint(
                &self.warning_buffer,
                "model catalog last refreshed {d} days ago — cost estimates may be stale",
                .{days},
            ) catch return .{ .warning = "model catalog is stale — cost estimates may be stale" };
            return .{ .warning = warning };
        }
        return started;
    }

    pub fn currentMetadata(self: *CatalogHook) ?ai.ModelMeta.Metadata {
        return self.catalog_runtime.runtime.metadata.model;
    }

    pub fn drain(self: *CatalogHook, maximum_wait_ms: u64) OneShot.CallbackError!?ai.ModelMeta.Metadata {
        const metadata = try self.catalog_runtime.pollApply(maximum_wait_ms) orelse return null;
        self.applyViews(metadata);
        return metadata;
    }

    fn applyViews(self: *CatalogHook, metadata: ai.ModelMeta.Metadata) void {
        const context_limit = effectiveContextLimit(self.manual_context_limit, metadata.context_window);
        self.stats.context_limit = context_limit;
        self.compaction.metadata = metadata;
        self.compaction.effort = self.catalog_runtime.runtime.effort;
        self.compaction.context_limit = context_limit;
    }
};

const ImageInputPolicy = union(enum) {
    automatic,
    fixed: ai.Provider.ImageInput,

    fn resolveFixed(self: ImageInputPolicy, support: ai.ModelMeta.Support) ai.Provider.ImageInput {
        return switch (self) {
            .automatic => imageInputFromSupport(support),
            .fixed => |value| value,
        };
    }
};

const DynamicImageInput = struct {
    policy: ImageInputPolicy,
    catalog_runtime: *CatalogRuntime,
    effects: ?*CatalogHook = null,

    pub fn resolve(
        _: std.mem.Allocator,
        _: std.Io,
        self: *DynamicImageInput,
    ) agent.ImageInputSource.CallbackError!ai.Provider.ImageInput {
        return switch (self.policy) {
            .fixed => |value| value,
            .automatic => {
                const refreshed = self.catalog_runtime.pollApply(0) catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.Failed,
                };
                if (refreshed) |metadata| if (self.effects) |effects| {
                    effects.applyViews(metadata);
                };
                return imageInputFromSupport(self.catalog_runtime.runtime.metadata.model.image_input);
            },
        };
    }
};

const SessionInfo = struct {
    run: *SessionStartup.Run,
    runtime: *ProviderRuntime.Owned,
    preset: ?[]const u8,
    resumed: bool,

    pub fn get(self: *SessionInfo) OneShot.CallbackError!OneShot.SessionInfo {
        return .{
            .preset = self.preset,
            .provider_name = self.runtime.metadata.display_name,
            .model_label = self.runtime.model,
            .effort = self.runtime.effort,
            .provider_autoselected = self.runtime.provider_autoselected,
            .resumed = self.resumed,
            .materialized_session = self.run.resumeHint(),
        };
    }
};

const Terminal = struct {
    tools: *ToolRuntime.Owner,

    pub fn finish(
        self: *Terminal,
        session: *agent.Session.Session,
        seam: ?agent.Loop.SeamHook,
    ) OneShot.CallbackError!void {
        self.tools.finish(session, seam) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.HookIndeterminate => error.Indeterminate,
            else => error.Failed,
        };
    }
};

const DynamicEffort = struct {
    runtime: *ProviderRuntime.Owned,

    pub fn resolve(self: *DynamicEffort) ?[]const u8 {
        return self.runtime.effort;
    }
};

const DynamicModelMetadata = struct {
    catalog_runtime: *CatalogRuntime,
    effects: ?*CatalogHook = null,

    pub fn resolve(
        _: std.mem.Allocator,
        _: std.Io,
        self: *DynamicModelMetadata,
    ) agent.ModelMetadataSource.CallbackError!ai.ModelMeta.Metadata {
        const refreshed = self.catalog_runtime.pollApply(0) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Failed, error.Indeterminate, error.InvalidPlan => null,
        };
        if (refreshed) |metadata| if (self.effects) |effects| effects.applyViews(metadata);
        return self.catalog_runtime.runtime.metadata.model;
    }
};

const CompactionMarker = struct {
    pending: bool = false,
    stderr: *std.Io.Writer,
    style: bool,

    fn write(self: *CompactionMarker) std.Io.Writer.Error!void {
        var style_open = false;
        if (self.style) {
            try self.stderr.writeAll("\x1b[2m");
            style_open = true;
        }
        errdefer if (style_open) self.stderr.writeAll("\x1b[0m") catch {};
        try self.stderr.writeAll("[compacted context]");
        if (style_open) {
            try self.stderr.writeAll("\x1b[0m");
            style_open = false;
        }
        try self.stderr.writeByte('\n');
    }
};

const RunSeam = struct {
    downstream: ?agent.Loop.SeamHook,
    marker: *CompactionMarker,

    pub fn call(
        self: *RunSeam,
        session: *const agent.Session.Session,
        kind: agent.Loop.SeamKind,
        next_action: bool,
    ) agent.Loop.HookError!void {
        if (self.downstream) |downstream| try downstream.call(session, kind, next_action);
        if (kind != .compaction or !self.marker.pending) return;
        self.marker.write() catch return error.Failed;
        self.marker.pending = false;
    }
};

const AutoCompact = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    provider: ai.Provider.Provider,
    model: []const u8,
    metadata: ai.ModelMeta.Metadata,
    model_metadata_source: agent.ModelMetadataSource.ModelMetadataSource,
    system_prompt: []const u8,
    tools: []const tool.Tool.Tool,
    tool_runtime: *ToolRuntime.Owner,
    durability: ?*SessionDurability.Owner,
    effort: ?[]const u8,
    usage: *agent.UsageStats.UsageStats,
    catalog_runtime: *CatalogRuntime,
    effects: ?*CatalogHook = null,
    manual_context_limit: ?u64,
    seam_hook: ?agent.Loop.SeamHook,
    marker: *CompactionMarker,
    context_limit: ?u64,
    enabled: bool,
    threshold: u8,
    cancellation: ?agent.CompactRunner.Cancellation = null,

    pub fn call(
        self: *AutoCompact,
        session: *agent.Session.Session,
    ) agent.Loop.HookError!agent.Loop.ContinuationResult {
        try self.refreshCatalog();
        if (!agent.Compact.shouldAuto(
            self.usage.last_ordinary_context_tokens,
            self.context_limit,
            self.enabled,
            self.threshold,
        )) return .unchanged;
        const effort_changed = try self.syncEffort(session);
        var result = agent.CompactRunner.runContinuation(self.allocator, self.io, .{
            .session = session,
            .provider = self.provider,
            .model = self.model,
            .model_metadata = self.metadata,
            .model_metadata_source = self.model_metadata_source,
            .system_prompt = self.system_prompt,
            .tools = self.tools,
            .effort = self.effort,
            .cancellation = self.cancellation,
            .seam_hook = self.seam_hook,
            .usage_observer = agent.Loop.UsageObserver.from(self.usage),
        }) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.HookIndeterminate => error.Indeterminate,
            else => error.Failed,
        };
        defer result.deinit(self.allocator);
        return switch (result.outcome) {
            .compacted => compacted: {
                self.marker.pending = true;
                break :compacted .changed;
            },
            .cancelled => .paused,
            .no_summary, .provider_failure => if (effort_changed) .selection_changed else .unchanged,
        };
    }

    fn syncEffort(self: *AutoCompact, session: *agent.Session.Session) agent.Loop.HookError!bool {
        const current = session.currentSelection();
        if (optionalEqual(current.effort, self.effort)) return false;

        self.tool_runtime.updateRunEffort(self.effort) catch |err| return switch (err) {
            error.PendingDurability => error.Indeterminate,
            error.Reentrant, error.InvalidConfig => error.Failed,
        };
        if (self.durability) |owner| {
            const update = owner.updateSelection(session, .{
                .provider = current.provider_id,
                .model = current.model,
                .model_label = current.model_label,
                .effort = self.effort,
                .preset = current.preset,
            }) catch |err| {
                if (err == error.Indeterminate) return error.Indeterminate;
                self.rollbackToolEffort(current.effort) catch return error.Indeterminate;
                return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.Failed => error.Failed,
                    error.Indeterminate => unreachable,
                };
            };
            if (update == .partial) return error.Indeterminate;
            return true;
        }
        session.reconfigureSelection(.{
            .provider_id = current.provider_id,
            .model = current.model,
            .model_label = current.model_label,
            .effort = self.effort,
            .preset = current.preset,
        }) catch |err| {
            self.rollbackToolEffort(current.effort) catch return error.Indeterminate;
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.Failed,
            };
        };
        return true;
    }

    fn rollbackToolEffort(self: *AutoCompact, effort: ?[]const u8) error{Failed}!void {
        self.tool_runtime.updateRunEffort(effort) catch return error.Failed;
    }

    fn refreshCatalog(self: *AutoCompact) agent.Loop.HookError!void {
        const refreshed = self.catalog_runtime.pollApply(0) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Failed,
        };
        const metadata = refreshed orelse return;
        self.effort = self.catalog_runtime.runtime.effort;
        if (self.effects) |effects| {
            effects.applyViews(metadata);
            return;
        }
        self.metadata = metadata;
        self.context_limit = effectiveContextLimit(
            self.manual_context_limit,
            metadata.context_window,
        );
    }
};

fn refreshWasReplaced(summary: CatalogService.Summary) bool {
    const completion = summary.completion orelse return false;
    return switch (completion) {
        .refresh => |outcome| outcome == .replaced,
        else => false,
    };
}

fn optionalEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn effectiveContextLimit(manual: ?u64, discovered: u64) ?u64 {
    if (manual) |value| return value;
    return if (discovered == 0) null else discovered;
}

fn shouldCreateGitEnvironment(has_resolved: bool, no_session: bool, has_state_root: bool) bool {
    return !has_resolved and !no_session and has_state_root;
}

fn exerciseGitEnvironmentAllocation(
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
) !void {
    var wiping = SecureAllocator.WipingAllocator.init(allocator);
    var map = try std.process.Environ.createMap(environ, wiping.allocator());
    defer map.deinit();
    try std.testing.expectEqualStrings("super-secret", map.get("SECRET").?);
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const text = value orelse return null;
    return if (text.len == 0) null else text;
}

fn noSessionConfigured(value: ?[]const u8, provider_id: []const u8) bool {
    const text = value orelse return false;
    if (std.ascii.eqlIgnoreCase(text, "auto")) return std.mem.eql(u8, provider_id, "mock");
    return std.mem.eql(u8, text, "1") or std.ascii.eqlIgnoreCase(text, "true") or
        std.ascii.eqlIgnoreCase(text, "yes") or std.ascii.eqlIgnoreCase(text, "on");
}

fn ignoreWriterFailure(err: std.Io.Writer.Error) void {
    switch (err) {
        error.WriteFailed => return,
    }
}

fn loadCodexSettings(
    allocator: std.mem.Allocator,
    files: CodexFiles,
) error{OutOfMemory}!ai.CodexSettings.Owned {
    const loaded = try files.loadSettings(allocator);
    return switch (loaded) {
        .missing, .unreadable => .{ .allocator = allocator },
        .bytes => |bytes| parsed: {
            defer SecureAllocator.wipeFree(allocator, bytes);
            break :parsed try ai.CodexSettings.parse(allocator, bytes);
        },
    };
}

fn isExplicitCodex(provider: ?[]const u8) bool {
    return if (provider) |value| std.mem.eql(u8, value, "codex") else false;
}

fn isExplicitLlama(provider: ?[]const u8) bool {
    const value = provider orelse return false;
    return std.mem.eql(u8, value, "llamacpp") or std.mem.eql(u8, value, "llama.cpp");
}

fn isExplicitOllama(provider: ?[]const u8) bool {
    return if (provider) |value| std.mem.eql(u8, value, "ollama") else false;
}

fn hasExplicitProvider(provider: ?[]const u8) bool {
    const value = provider orelse return false;
    return value.len != 0;
}

fn renderProviderHeaderWarnings(
    writer: *std.Io.Writer,
    provider: []const u8,
    warnings: []const ProviderHeaders.Warning,
) !void {
    for (warnings) |warning| {
        try writer.writeAll("zi: warning: providers.");
        try DiagnosticText.write(writer, provider);
        try writer.writeAll(".extra_headers: header '");
        try DiagnosticText.write(writer, warning.name);
        try writer.writeAll(switch (warning.kind) {
            .missing_environment => "' dropped — $",
            .invalid_resolved_value => "' needs a control-character-free value — ignoring it\n",
            .protocol_owned => "' is protocol-owned — ignoring it\n",
            .duplicate => "' duplicates another header name — ignoring it\n",
        });
        if (warning.kind == .missing_environment) {
            try DiagnosticText.write(writer, warning.environment_name.?);
            try writer.writeAll(" is not set\n");
        }
    }
}

fn renderLlamaDiscoveryDiagnostic(writer: *std.Io.Writer, base_url: []const u8) !void {
    try writer.writeAll("zi: llama.cpp: failed to auto-discover model from ");
    try DiagnosticText.write(writer, base_url);
    try writer.writeAll(
        "/models\nzi: is llama-server running? " ++
            "(set HAX_MODEL to tolerate an unreachable server, or adjust " ++
            "HAX_LLAMACPP_PORT / HAX_LLAMACPP_BASE_URL)\n",
    );
}

fn renderCodexAuthDiagnostic(
    writer: *std.Io.Writer,
    auth_path: ?[]const u8,
    failure: CodexAuth.InitFailure,
) std.Io.Writer.Error!void {
    try writer.writeAll("zi: Codex authentication unavailable: ");
    if (auth_path) |path| {
        try writer.writeAll("'");
        try DiagnosticText.write(writer, path);
        try writer.writeAll("' ");
    } else {
        try writer.writeAll("HOME is not set and the Codex auth path ");
    }
    try writer.writeAll(switch (failure.codex_cli) {
        .missing => "is missing; authenticate with the Codex CLI to create it",
        .unreadable => "cannot be read safely; check its ownership and permissions",
        .bad_json => "contains invalid JSON; repair it with the Codex CLI",
        .no_tokens => "has no usable access token and account ID; authenticate with the Codex CLI",
    });
    switch (failure.managed) {
        .bad_json => try writer.writeAll("; Zi's managed Codex credential is also corrupt"),
        .unreadable => try writer.writeAll("; Zi's managed Codex credential is also unreadable"),
        .no_tokens => try writer.writeAll("; Zi's managed Codex credential also has no usable tokens"),
        .missing => {},
    }
    try writer.writeByte('\n');
}

fn renderPublicationWarning(
    writer: *std.Io.Writer,
    outcome: CodexAuth.PublicationOutcome,
) std.Io.Writer.Error!void {
    const failure = switch (outcome) {
        .not_published => |value| value,
        .uncertain => |value| value,
        .none, .adopted_disk, .published => return,
    };
    try writer.writeAll("zi: warning: Codex credential update ");
    switch (outcome) {
        .not_published => try writer.writeAll("was definitely not published"),
        .uncertain => try writer.writeAll("may or may not have been published"),
        else => unreachable,
    }
    try writer.writeAll(": ");
    try writer.writeAll(publicationCause(failure.cause));
    if (failure.orphan_name) |*name| {
        try writer.writeAll("; temporary file '");
        try DiagnosticText.write(writer, name.bytes());
        try writer.writeAll("' may need removal");
    }
    try writer.writeAll("; retry authentication if the next Codex request fails\n");
}

fn publicationCause(cause: persistence.CredentialStore.MutationCause) []const u8 {
    return switch (cause) {
        .invalid => "the stored credential state was invalid",
        .too_large => "the credential update exceeded its safe size limit",
        .busy => "another credential update was in progress",
        .not_regular => "the credential path was not a regular private file",
        .io_failure => "the credential file operation failed",
        .out_of_memory => "the credential update ran out of memory",
        .canceled => "the credential update was canceled",
        .poisoned => "an earlier uncertain write blocked safe replacement",
        .invalid_provider => "the credential provider name was invalid",
        .invalid_value => "the credential value was invalid",
        .too_deep => "the credential JSON nesting was too deep",
        .too_many_tokens => "the credential JSON had too many tokens",
        .string_too_large => "a credential JSON string exceeded its safe limit",
    };
}

fn diagnostic(writer: *std.Io.Writer, message: []const u8) !u8 {
    try writer.print("zi: {s}\n", .{message});
    return 1;
}

fn renderPresetDiagnostic(writer: *std.Io.Writer, problem: StartupConfig.PresetDiagnostic) !void {
    try writer.writeAll("zi: preset '");
    try DiagnosticText.write(writer, problem.name);
    try writer.writeAll("' ");
    switch (problem.issue) {
        .missing => try writer.writeAll("was not found"),
        .invalid => try writer.writeAll("is invalid"),
        .mismatched => try writer.writeAll("does not match the recorded session"),
    }
    if (problem.append_session_hint) try writer.writeAll("; use --no-session to continue without recording");
    try writer.writeByte('\n');
}

fn renderWarnings(writer: *std.Io.Writer, warnings: []const StartupConfig.Warning) !void {
    for (warnings) |warning| {
        try writer.writeAll("zi: warning: startup setting ignored: ");
        try DiagnosticText.write(writer, warning.subject);
        try writer.writeByte('\n');
    }
}

fn renderProviderWarnings(
    writer: *std.Io.Writer,
    warnings: []const config.ProviderDefinitions.Warning,
) !void {
    for (warnings) |warning| {
        try writer.writeAll("zi: warning: ");
        switch (warning.reason) {
            .dotted_name => {
                try writer.writeAll("ignoring custom provider '");
                try DiagnosticText.write(writer, warning.provider);
                try writer.writeAll("': name cannot contain '.'");
            },
            .unknown_field => {
                try writer.writeAll("provider '");
                try DiagnosticText.write(writer, warning.provider);
                try writer.writeAll("': unknown field '");
                try DiagnosticText.write(writer, warning.field orelse "(unknown)");
                try writer.writeAll("' (see docs/providers.md)");
            },
            .wrong_dialect => {
                try writeProviderField(writer, warning);
                try writer.writeAll(" is not used by API providers");
            },
            .non_scalar => {
                try writeProviderField(writer, warning);
                try writer.writeAll(" must be scalar");
            },
            .invalid_provider_id => {
                try writer.writeAll("ignoring custom provider '");
                try DiagnosticText.write(writer, warning.provider);
                try writer.writeAll("': invalid provider name");
            },
            .invalid_api => try writeInvalidProviderField(writer, warning, "API value"),
            .invalid_boolean => try writeInvalidProviderField(writer, warning, "boolean value"),
            .invalid_integer => try writeInvalidProviderField(writer, warning, "integer value"),
            .invalid_cache_ttl => try writeInvalidProviderField(writer, warning, "cache TTL"),
            .expected_object => try writeInvalidProviderField(writer, warning, "object value"),
            .invalid_model_api => try writeInvalidProviderField(writer, warning, "model API"),
            .invalid_header_name => try writeInvalidProviderField(writer, warning, "header name"),
            .invalid_header_value => try writeInvalidProviderField(writer, warning, "header value"),
        }
        try writer.writeByte('\n');
    }
}

fn writeProviderField(
    writer: *std.Io.Writer,
    warning: config.ProviderDefinitions.Warning,
) std.Io.Writer.Error!void {
    try writer.writeAll("provider '");
    try DiagnosticText.write(writer, warning.provider);
    try writer.writeAll("': field '");
    try DiagnosticText.write(writer, warning.field orelse "(unknown)");
    try writer.writeByte('\'');
}

fn writeInvalidProviderField(
    writer: *std.Io.Writer,
    warning: config.ProviderDefinitions.Warning,
    expected: []const u8,
) std.Io.Writer.Error!void {
    try writeProviderField(writer, warning);
    try writer.writeAll(" has an invalid ");
    try writer.writeAll(expected);
}

test "resume retention cutoff handles disabled current expired and saturation" {
    try std.testing.expectEqual(@as(i64, 0), retentionCutoff(1_000_000, 0));
    try std.testing.expectEqual(@as(i64, 913_600), retentionCutoff(1_000_000, 1));
    try std.testing.expect(retentionCutoff(1_000_000, 30) < 0);
    try std.testing.expectEqual(std.math.minInt(i64), retentionCutoff(std.math.minInt(i64), 1));
}

test "provider aliases are canonical before resumed selection comparison" {
    const canonicalizer: ProviderCanonicalizer = .{};
    try std.testing.expectEqualStrings("llamacpp", canonicalizer.canonical("llama.cpp"));
    try std.testing.expectEqualStrings("openai", canonicalizer.canonical("openai"));
}

test "image input setting resolves explicit and automatic policy" {
    try std.testing.expectEqual(
        ai.Provider.ImageInput.supported,
        (try parseImageInputPolicy("yes")).resolveFixed(.no),
    );
    try std.testing.expectEqual(
        ai.Provider.ImageInput.unsupported,
        (try parseImageInputPolicy("off")).resolveFixed(.yes),
    );
    try std.testing.expectEqual(
        ai.Provider.ImageInput.supported,
        (try parseImageInputPolicy("auto")).resolveFixed(.yes),
    );
    try std.testing.expectEqual(
        ai.Provider.ImageInput.unknown,
        (try parseImageInputPolicy(null)).resolveFixed(.unknown),
    );
    try std.testing.expectError(error.InvalidSetting, parseImageInputPolicy("sometimes"));
}

test "diagnostic text visibly escapes terminal controls without allocation" {
    var storage: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try DiagnosticText.write(&writer, "safe hé\n\r\t\x1b\x00end");
    try std.testing.expectEqualStrings(
        "safe hé\\n\\r\\t\\x1b\\x00end",
        writer.buffered(),
    );
}

test "fresh provider cache key is the canonical session UUID" {
    const uuid = [_]u8{
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x46, 0x77,
        0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
    };
    try std.testing.expectEqualStrings("00112233-4455-4677-8899-aabbccddeeff", &formatUuid(uuid));
    var next = uuid;
    next[15] = 0xfe;
    try std.testing.expect(!std.mem.eql(u8, &formatUuid(uuid), &formatUuid(next)));
}

test "fresh Git environment releases every inherited value through the wiping allocator" {
    const entries = [_][*:0]const u8{ "SECRET=super-secret", "PATH=/bin" };
    const environ: std.process.Environ = .{ .block = .{ .slice = @ptrCast(&entries) } };
    var observer = SecureAllocator.FreeObserver.init(std.testing.allocator);
    var wiping = SecureAllocator.WipingAllocator.init(observer.allocator());
    var map = try std.process.Environ.createMap(environ, wiping.allocator());
    map.deinit();
    try std.testing.expect(observer.zero_frees > 0);
    try std.testing.expectEqual(@as(usize, 0), observer.other_frees);
}

test "Git environment exists only for a fresh recordable session and is OOM safe" {
    try std.testing.expect(shouldCreateGitEnvironment(false, false, true));
    try std.testing.expect(!shouldCreateGitEnvironment(true, false, true));
    try std.testing.expect(!shouldCreateGitEnvironment(false, true, true));
    try std.testing.expect(!shouldCreateGitEnvironment(false, false, false));
    const entries = [_][*:0]const u8{"SECRET=super-secret"};
    const environ: std.process.Environ = .{ .block = .{ .slice = @ptrCast(&entries) } };
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseGitEnvironmentAllocation,
        .{environ},
    );
}

test "run seam prints compaction marker only after durable compaction seam" {
    const Downstream = struct {
        const Self = @This();
        writer: *std.Io.Writer,
        fail: bool = false,

        pub fn call(
            self: *Self,
            _: *const agent.Session.Session,
            _: agent.Loop.SeamKind,
            _: bool,
        ) agent.Loop.HookError!void {
            self.writer.writeAll("durable\n") catch return error.Failed;
            if (self.fail) return error.Failed;
        }
    };

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var session = try agent.Session.Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var marker: CompactionMarker = .{
        .pending = true,
        .stderr = &output.writer,
        .style = false,
    };
    var downstream: Downstream = .{ .writer = &output.writer };
    var seam: RunSeam = .{
        .downstream = agent.Loop.SeamHook.from(&downstream),
        .marker = &marker,
    };

    try seam.call(&session, .compaction, true);
    try std.testing.expectEqualStrings("durable\n[compacted context]\n", output.written());
    try std.testing.expect(!marker.pending);
}

test "run seam retains marker when downstream durability fails" {
    const Downstream = struct {
        const Self = @This();

        pub fn call(
            _: *Self,
            _: *const agent.Session.Session,
            _: agent.Loop.SeamKind,
            _: bool,
        ) agent.Loop.HookError!void {
            return error.Failed;
        }
    };

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var session = try agent.Session.Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var marker: CompactionMarker = .{
        .pending = true,
        .stderr = &output.writer,
        .style = false,
    };
    var downstream: Downstream = .{};
    var seam: RunSeam = .{
        .downstream = agent.Loop.SeamHook.from(&downstream),
        .marker = &marker,
    };

    try std.testing.expectError(error.Failed, seam.call(&session, .compaction, true));
    try std.testing.expectEqualStrings("", output.written());
    try std.testing.expect(marker.pending);
}

test "run seam prints styled marker without downstream durability" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var session = try agent.Session.Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var marker: CompactionMarker = .{
        .pending = true,
        .stderr = &output.writer,
        .style = true,
    };
    var seam: RunSeam = .{ .downstream = null, .marker = &marker };

    try seam.call(&session, .compaction, true);
    try std.testing.expectEqualStrings(
        "\x1b[2m[compacted context]\x1b[0m\n",
        output.written(),
    );
}

test "provider warnings use actionable safe prose" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const warnings = [_]config.ProviderDefinitions.Warning{
        .{ .provider = @constCast("bad.name\n"), .field = null, .reason = .dotted_name },
        .{ .provider = @constCast("custom"), .field = @constCast("mystery\x1b"), .reason = .unknown_field },
        .{ .provider = @constCast("custom"), .field = @constCast("api_key"), .reason = .wrong_dialect },
        .{ .provider = @constCast("custom"), .field = @constCast("cache"), .reason = .invalid_boolean },
    };
    try renderProviderWarnings(&output.writer, &warnings);
    try std.testing.expectEqualStrings(
        "zi: warning: ignoring custom provider 'bad.name\\n': name cannot contain '.'\n" ++
            "zi: warning: provider 'custom': unknown field 'mystery\\x1b' (see docs/providers.md)\n" ++
            "zi: warning: provider 'custom': field 'api_key' is not used by API providers\n" ++
            "zi: warning: provider 'custom': field 'cache' has an invalid boolean value\n",
        output.written(),
    );
}

test "explicit provider detection matches canonical local spellings" {
    try std.testing.expect(isExplicitCodex("codex"));
    try std.testing.expect(!isExplicitCodex("Codex"));
    try std.testing.expect(!isExplicitCodex(null));
    try std.testing.expect(isExplicitLlama("llamacpp"));
    try std.testing.expect(isExplicitLlama("llama.cpp"));
    try std.testing.expect(!isExplicitLlama("Llama.cpp"));
    try std.testing.expect(isExplicitOllama("ollama"));
    try std.testing.expect(!isExplicitOllama("Ollama"));
    try std.testing.expect(hasExplicitProvider("ollama"));
    try std.testing.expect(!hasExplicitProvider(""));
    try std.testing.expect(!hasExplicitProvider(null));
}

test "llama discovery diagnostic escapes the configured endpoint" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try renderLlamaDiscoveryDiagnostic(&output.writer, "http://127.0.0.1:8080/v1\nspoof");
    try std.testing.expectEqualStrings(
        "zi: llama.cpp: failed to auto-discover model from " ++
            "http://127.0.0.1:8080/v1\\nspoof/models\n" ++
            "zi: is llama-server running? (set HAX_MODEL to tolerate an unreachable server, " ++
            "or adjust HAX_LLAMACPP_PORT / HAX_LLAMACPP_BASE_URL)\n",
        output.written(),
    );
}

test "Codex settings defaults are empty when explicit HOME has no config" {
    var files = try CodexFiles.init(std.testing.allocator, std.testing.io, null);
    defer files.deinit();
    var settings = try loadCodexSettings(std.testing.allocator, files);
    defer settings.deinit();
    try std.testing.expect(settings.model == null);
    try std.testing.expect(settings.model_reasoning_effort == null);
}

test "explicit Codex auth diagnostics name the exact safe path and statuses" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try renderCodexAuthDiagnostic(&output.writer, "/home/name\n/.codex/auth.json", .{
        .managed = .bad_json,
        .codex_cli = .no_tokens,
    });
    try std.testing.expectEqualStrings(
        "zi: Codex authentication unavailable: '/home/name\\n/.codex/auth.json' " ++
            "has no usable access token and account ID; authenticate with the Codex CLI; " ++
            "Zi's managed Codex credential is also corrupt\n",
        output.written(),
    );

    output.clearRetainingCapacity();
    try renderCodexAuthDiagnostic(&output.writer, null, .{
        .managed = .unreadable,
        .codex_cli = .missing,
    });
    try std.testing.expectEqualStrings(
        "zi: Codex authentication unavailable: HOME is not set and the Codex auth path " ++
            "is missing; authenticate with the Codex CLI to create it; " ++
            "Zi's managed Codex credential is also unreadable\n",
        output.written(),
    );
}

test "Codex publication warnings distinguish certainty and escape orphan names" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try renderPublicationWarning(&output.writer, .{ .not_published = .{
        .cause = .busy,
        .orphan_name = null,
    } });
    try std.testing.expectEqualStrings(
        "zi: warning: Codex credential update was definitely not published: " ++
            "another credential update was in progress; " ++
            "retry authentication if the next Codex request fails\n",
        output.written(),
    );

    output.clearRetainingCapacity();
    var orphan: persistence.CredentialStore.OrphanName = .{};
    const unsafe_name = "tmp\n\x1b";
    @memcpy(orphan.buffer[0..unsafe_name.len], unsafe_name);
    orphan.len = unsafe_name.len;
    try renderPublicationWarning(&output.writer, .{ .uncertain = .{
        .cause = .io_failure,
        .orphan_name = orphan,
    } });
    try std.testing.expectEqualStrings(
        "zi: warning: Codex credential update may or may not have been published: " ++
            "the credential file operation failed; temporary file 'tmp\\n\\x1b' may need removal; " ++
            "retry authentication if the next Codex request fails\n",
        output.written(),
    );
}
