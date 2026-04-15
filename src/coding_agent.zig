const std = @import("std");
const ai = @import("ai/root.zig");
const agent_mod = @import("agent/root.zig");
const session_mod = @import("session/root.zig");
const builtin_tools_mod = @import("tools/builtins.zig");
const tool_def = @import("tools/definition.zig");
const builtin_util = @import("tools/util.zig");
const system_prompt_mod = @import("system_prompt.zig");
const resources = @import("resources/root.zig");
const skills = @import("skills/root.zig");
const auth_storage_mod = @import("auth/storage.zig");
const settings_manager_mod = @import("settings/manager.zig");
const settings_types_mod = @import("settings/types.zig");
const storage = @import("storage.zig");
const extension_runner_mod = @import("extensions/runner.zig");
const lua_runtime = @import("extensions/lua_runtime.zig");
const extension_api = @import("extensions/api.zig");
const event_bridge = @import("extensions/event_bridge.zig");
const lua_tool_mod = @import("extensions/lua_tool.zig");

const protocol = agent_mod.protocol;
const Agent = agent_mod.Agent;
const SubscriptionToken = agent_mod.SubscriptionToken;
pub const SessionStore = session_mod.store.SessionStore;
pub const ExtensionRunner = extension_runner_mod.ExtensionRunner;
pub const ExtensionRunnerRef = extension_runner_mod.ExtensionRunnerRef;
pub const ContextUsage = session_mod.context_usage.ContextUsage;

/// Composition root: wires Agent + SessionStore + tools + model resolution.
///
/// pi-mono equivalent: packages/coding-agent/src/core/sdk.ts (createAgentSession)
/// + packages/coding-agent/src/core/agent-session.ts (AgentSession)
///
/// Owns:
/// - Agent (dual-loop, tool pipeline, event system)
/// - SessionStore (JSONL persistence + context building)
/// - Tool registry (bash + future tools)
/// - convertToLlm that handles compaction_summary, branch_summary, custom
/// - transformContext hook point (wired but no-op until compaction lands)
/// - Stream hook wrapping provider registry
pub const AgentSession = struct {
    agent: Agent,
    session_store: SessionStore,
    allocator: std.mem.Allocator,
    tools: []const protocol.AgentTool,
    event_handler: ?EventHandler,
    event_listeners: std.ArrayList(EventHandler),
    _subscription_token: ?SubscriptionToken,
    _stream_closure: *StreamClosure,
    auth_storage: ?*auth_storage_mod.AuthStorage,
    settings_manager: ?*settings_manager_mod.SettingsManager = null,
    resource_loader: resources.ResourceLoader,
    /// Borrowed ModelRegistry — lifetime owned by caller (main.zig in
    /// the interactive path). Used by the TUI to bind `[]const Model`
    /// at init, and by `/resume` for `restoreModelFromSession`.
    model_registry: ?*ai.model_registry.ModelRegistry = null,

    /// Owned ExtensionRunner — current generation. Populated by the
    /// sdk factory in Phase A3+; nil in v1 bootstraps until the runner
    /// construction path is wired. Reload replaces this pointer
    /// atomically with a new generation (see `docs/extensions.md`). When set,
    /// `deinit` takes it down before
    /// the agent so any final event observers can still fire against
    /// a live session.
    _extension_runner: ?*ExtensionRunner = null,

    /// Owned Lua state, paired 1:1 with `_extension_runner`. The
    /// runner BORROWS this — see `extensions/runner.zig` field doc.
    /// AgentSession owns the lifetime so the SDK bootstrap order
    /// (state → runner → install zi.* → attach) lines up with the
    /// teardown order (unsubscribe → runner.deinit → state.deinit).
    /// Both fields are nil when Lua init fails; the agent still runs.
    _extension_lua_state: ?*lua_runtime.LuaState = null,

    /// Subscription token for the extension event bridge. Separate
    /// from `_subscription_token` (session persistence) so the two
    /// can be torn down independently.
    _extension_subscription_token: ?SubscriptionToken = null,

    /// Owned built-in provider bundle. Set when the sdk factory created
    /// the registry on the caller's behalf (the common path); null when
    /// the caller passed their own pre-built `Options.registry` (tests,
    /// embedders that want a custom provider set). When set, `deinit`
    /// drops it AFTER the agent — provider structs and the registry
    /// must outlive any in-flight stream that might still hold them.
    _owned_provider_bundle: ?*ai.provider_defaults.Bundle = null,
    _builtin_ctx: ?*builtin_util.BuiltinCtx = null,
    /// Mirrors pi-mono's post-compaction semantics without re-reading the
    /// session file on every status render. True means the latest compaction
    /// on the active branch has not yet been followed by a successful
    /// assistant response with non-zero usage.
    context_usage_unknown_after_compaction: bool = false,

    pub const EventHandler = struct {
        func: *const fn (event: protocol.AgentEvent, ctx: ?*anyopaque) void,
        ctx: ?*anyopaque = null,
    };

    pub const EventSubscriptionToken = struct {
        index: usize,
    };

    pub const ModelSwitchResult = union(enum) {
        success: struct {
            model: ai.protocol.Model,
            thinking_level: protocol.ThinkingLevel,
            thinking_level_changed: bool,
        },
        no_auth: ai.protocol.Model,
        registry_unavailable: void,
    };

    pub const ThinkingLevelChangeResult = struct {
        level: protocol.ThinkingLevel,
        changed: bool,
    };

    pub const StatusSnapshot = struct {
        model_provider: []const u8,
        model_id: []const u8,
        thinking_level: protocol.ThinkingLevel,
        context_tokens: ?u64,
        context_window: u64,
    };

    pub const Options = struct {
        model: ai.protocol.Model,
        /// Static API key fallback. Used only when no `auth_storage` is
        /// attached or its lookup returns empty. Tests pass this; real
        /// callers should set `auth_storage` so token refresh / login
        /// flows are picked up live by the stream closure.
        api_key: []const u8 = "",
        cwd: []const u8,
        /// Canonical loaded resource state, constructed by the
        /// composition root (`sdk.createAgentSession`) and transferred
        /// into the session as an owned dependency.
        resource_loader: resources.ResourceLoader,
        max_tokens: ?u64 = 4096,
        tools: ?[]const tool_def.ToolDefinition = null,
        /// Optional pre-built provider registry. When null, the sdk
        /// factory creates one via `ai.provider_defaults.Bundle` and
        /// the session takes ownership. Tests typically pass their own
        /// faux-only registry and skip the bundle.
        registry: ?*ai.provider.Registry = null,
        event_handler: ?EventHandler = null,
        auth_storage: ?*auth_storage_mod.AuthStorage = null,
        settings_manager: ?*settings_manager_mod.SettingsManager = null,
        /// Borrowed, caller-owned. Session holds it for the TUI to
        /// read via `getAll()` and for future resolve calls. Phase 2:
        /// main.zig constructs the registry before this init.
        model_registry: ?*ai.model_registry.ModelRegistry = null,
        /// Seed with existing messages for --continue.
        initial_messages: []const protocol.AgentMessage = &.{},
        /// Initial thinking level (from findInitialModel).
        thinking_level: ?protocol.ThinkingLevel = null,
        /// Pre-built session store (from SessionStore.open for --continue).
        /// If null, a new session is created for `cwd`.
        session_store: ?SessionStore = null,
        no_session: bool = false,
        /// Strict tool allowlist. When non-null, the final
        /// precedence-resolved tool set is filtered to only tools
        /// whose `name` or `label` matches an entry in this
        /// list (case-insensitive). Empty slice → zero tools.
        /// Null → no filtering (default).
        ///
        /// Mirrors pi-mono's `--tools` CLI contract: the flag is a
        /// hard whitelist the parent binary enforces, so subagents
        /// (Task) that spawn children with `--tools bash,read` get
        /// EXACTLY those tools — not those plus whatever extensions
        /// the child process happens to discover. Without this,
        /// Task-in-Task spawns recurse because the child re-registers
        /// Task from `~/.zi/agent/extensions/task.lua`.
        tool_allowlist: ?[]const []const u8 = null,
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) AgentSession {
        // Fallback path when no store was pre-built by the sdk factory.
        // The preferred entry point is `sdk.createAgentSession`, which
        // runs `resolveSessionDir` up front (v2 hook point). Direct
        // `AgentSession.init` callers — tests, the odd standalone — get
        // the default directory here without the extension hook.
        const store = options.session_store orelse if (options.no_session)
            SessionStore.createEphemeral(allocator)
        else blk: {
            const default_dir = storage.getSessionDirForCwd(allocator, options.cwd, null) catch @panic("OOM");
            break :blk SessionStore.create(allocator, default_dir, options.cwd);
        };

        // Default built-ins: bash + read/write/edit/grep/find/ls.
        // The bundle owns a per-session BuiltinCtx (cwd + session id)
        // that every tool ctx pointer references for the session
        // lifetime.
        var builtin_ctx: ?*builtin_util.BuiltinCtx = null;
        const builtin_definitions = options.tools orelse blk: {
            var bundle = builtin_tools_mod.build(allocator, options.cwd) catch
                break :blk @as([]const tool_def.ToolDefinition, &.{});
            bundle.ctx.session_id = store.sessionId();
            builtin_ctx = bundle.ctx;
            break :blk @as([]const tool_def.ToolDefinition, bundle.definitions);
        };

        // Resolve the provider registry. The preferred path: sdk passes
        // null and we own a Bundle for the session lifetime. Tests pass
        // their own faux registry and we skip the bundle. Either way the
        // closure sees a real `*Registry` and never branches on null.
        var owned_bundle: ?*ai.provider_defaults.Bundle = null;
        const registry: *ai.provider.Registry = options.registry orelse blk: {
            const bundle = ai.provider_defaults.Bundle.init(allocator) catch @panic("OOM");
            owned_bundle = bundle;
            break :blk bundle.registry;
        };

        const closure = allocator.create(StreamClosure) catch @panic("OOM");
        closure.* = .{
            .registry = registry,
            .auth_storage = options.auth_storage,
            .api_key = options.api_key,
            .max_tokens = options.max_tokens,
        };
        const stream_hook = protocol.StreamHook{
            .func = &StreamClosure.streamFn,
            .ctx = @ptrCast(closure),
        };

        var resource_loader = options.resource_loader;
        const prompt_inputs = resource_loader.getPromptInputs();
        const loaded_extensions = resource_loader.getExtensions();

        // Construct the extension runtime BEFORE building the tools
        // list so Lua-registered tools can join the agent's tool set.
        // Failures here are non-fatal: ext_state/ext_runner stay null,
        // builtin tools still flow through, agent runs without
        // extensions. See `docs/extensions.md`.
        var ext_state: ?*lua_runtime.LuaState = null;
        var ext_runner: ?*ExtensionRunner = null;
        ext_setup: {
            const state_ptr = allocator.create(lua_runtime.LuaState) catch break :ext_setup;
            state_ptr.* = lua_runtime.LuaState.init(allocator) catch {
                allocator.destroy(state_ptr);
                break :ext_setup;
            };
            const runner_ptr = allocator.create(ExtensionRunner) catch {
                state_ptr.deinit();
                allocator.destroy(state_ptr);
                break :ext_setup;
            };
            runner_ptr.* = ExtensionRunner.init(allocator, 0);
            runner_ptr.cwd = options.cwd;
            runner_ptr.attachLuaState(state_ptr);
            extension_api.installZiTable(state_ptr, runner_ptr);
            ext_state = state_ptr;
            ext_runner = runner_ptr;

            // Configure `package.path` so extensions can
            // `require("lib/foo")` relative to their extension dir.
            // Dirs are best-effort — missing ones are silently
            // skipped.
            const agent_dir = storage.getAgentDir(allocator, null) catch null;
            defer if (agent_dir) |d| allocator.free(d);
            const project_dir = storage.getProjectDir(allocator, options.cwd) catch null;
            defer if (project_dir) |d| allocator.free(d);
            const agent_ext = if (agent_dir) |d| std.fs.path.join(allocator, &.{ d, "extensions" }) catch null else null;
            defer if (agent_ext) |d| allocator.free(d);
            const project_ext = if (project_dir) |d| std.fs.path.join(allocator, &.{ d, "extensions" }) catch null else null;
            defer if (project_ext) |d| allocator.free(d);
            var dirs_buf: [2][]const u8 = .{ "", "" };
            var dirs_n: usize = 0;
            if (project_ext) |d| {
                dirs_buf[dirs_n] = d;
                dirs_n += 1;
            }
            if (agent_ext) |d| {
                dirs_buf[dirs_n] = d;
                dirs_n += 1;
            }
            state_ptr.setPackagePath(dirs_buf[0..dirs_n]) catch {};

            runner_ptr.bindLuaOwnerThread(std.Thread.getCurrentId());
            if (loaded_extensions.extensions.len > 0) {
                const stats = resource_loader.loadExtensionsInto(state_ptr, runner_ptr);
                std.log.scoped(.extensions).info(
                    "extensions: {d} loaded, {d} failed of {d} discovered",
                    .{ stats.loaded, stats.failed, stats.attempted },
                );
            }

            registerBaseToolDefinitions(runner_ptr, builtin_definitions);
        }

        const definitions: []const tool_def.ToolDefinition = if (ext_runner) |r|
            r.tool_registry.items()
        else
            builtin_definitions;

        const filtered_definitions: []const tool_def.ToolDefinition = if (options.tool_allowlist) |allow| blk_f: {
            const filtered = allocator.alloc(tool_def.ToolDefinition, definitions.len) catch break :blk_f definitions;
            var fi: usize = 0;
            for (definitions) |t| {
                for (allow) |want| {
                    const w = std.mem.trim(u8, want, &std.ascii.whitespace);
                    if (w.len == 0) continue;
                    if (std.ascii.eqlIgnoreCase(w, t.name) or std.ascii.eqlIgnoreCase(w, t.label)) {
                        filtered[fi] = t;
                        fi += 1;
                        break;
                    }
                }
            }
            break :blk_f filtered[0..fi];
        } else definitions;

        const filtered_tools: []const protocol.AgentTool = blk: {
            const out = allocator.alloc(protocol.AgentTool, filtered_definitions.len) catch break :blk &.{};
            var n: usize = 0;
            for (filtered_definitions) |def| {
                const tool = switch (def.impl) {
                    .builtin => tool_def.toAgentTool(def),
                    .lua => if (ext_runner) |r|
                        lua_tool_mod.buildAgentTool(allocator, r, def) catch |err| {
                            std.log.scoped(.extensions).warn(
                                "failed to build agent tool for {s}: {s}",
                                .{ def.name, @errorName(err) },
                            );
                            continue;
                        }
                    else
                        continue,
                };
                out[n] = tool;
                n += 1;
            }
            break :blk out[0..n];
        };

        const tool_name_slice = toolNameSlice(allocator, filtered_definitions) catch &.{};
        const tool_snippets = collectToolSnippets(allocator, filtered_definitions) catch &.{};
        const prompt_guidelines = collectGuidelines(allocator, filtered_definitions) catch &.{};
        const skills_section: ?[]const u8 = if (hasToolNamed(filtered_definitions, "read"))
            skills.format.formatSkillsForPrompt(allocator, resource_loader.getSkills().skills) catch null
        else
            null;
        defer if (skills_section) |section| allocator.free(section);

        const sys_prompt = blk: {
            if (prompt_inputs.system_prompt) |custom| {
                break :blk system_prompt_mod.buildSystemPrompt(allocator, .{
                    .custom_prompt = custom,
                    .cwd = options.cwd,
                    .context_files = prompt_inputs.agents_files,
                    .tool_names = tool_name_slice,
                    .tool_snippets = tool_snippets,
                    .guidelines = prompt_guidelines,
                    .skills_section = skills_section,
                    .append_system_prompt = prompt_inputs.append_system_prompt,
                }) catch custom;
            }
            break :blk system_prompt_mod.buildSystemPrompt(allocator, .{
                .cwd = options.cwd,
                .tool_names = tool_name_slice,
                .tool_snippets = tool_snippets,
                .guidelines = prompt_guidelines,
                .skills_section = skills_section,
                .context_files = prompt_inputs.agents_files,
                .append_system_prompt = prompt_inputs.append_system_prompt,
            }) catch "You are a helpful coding assistant.";
        };

        const get_api_key_hook: ?protocol.GetApiKeyHook = if (options.auth_storage) |as| .{
            .func = &getApiKeyFromStorage,
            .ctx = @ptrCast(@constCast(as)),
        } else null;

        // Build hooks AFTER ext setup so we can use the runner ptr
        // as the hook ctx. Hooks are nil when no runner exists; the
        // agent loop already short-circuits null hooks.
        const before_tool_hook: ?protocol.BeforeToolCallHook = if (ext_runner) |r| .{
            .func = &event_bridge.beforeToolCall,
            .ctx = @ptrCast(r),
        } else null;
        const after_tool_hook: ?protocol.AfterToolCallHook = if (ext_runner) |r| .{
            .func = &event_bridge.afterToolCall,
            .ctx = @ptrCast(r),
        } else null;

        const a = Agent.init(allocator, .{
            .initial_state = .{
                .system_prompt = sys_prompt,
                .model = options.model,
                .tools = filtered_tools,
                .messages = options.initial_messages,
                .thinking_level = options.thinking_level orelse .off,
            },
            .convert_to_llm = .{ .func = &convertToLlm, .ctx = null },
            .stream_fn = stream_hook,
            .session_id = store.sessionId(),
            .get_api_key = get_api_key_hook,
            .before_tool_call = before_tool_hook,
            .after_tool_call = after_tool_hook,
        });
        const context_usage_unknown_after_compaction = contextUsageUnknownFromStore(allocator, &store);

        const self = AgentSession{
            .agent = a,
            .session_store = store,
            .allocator = allocator,
            .tools = filtered_tools,
            .event_handler = options.event_handler,
            .event_listeners = .empty,
            ._subscription_token = null,
            ._stream_closure = closure,
            .auth_storage = options.auth_storage,
            .settings_manager = options.settings_manager,
            .resource_loader = resource_loader,
            .model_registry = options.model_registry,
            ._owned_provider_bundle = owned_bundle,
            ._builtin_ctx = builtin_ctx,
            .context_usage_unknown_after_compaction = context_usage_unknown_after_compaction,
            ._extension_runner = ext_runner,
            ._extension_lua_state = ext_state,
        };

        // Subscribe for session persistence: write message_end entries.
        // We use a pointer to self, so self must be pinned after init.
        // The caller must not move self after calling init.
        // We'll wire this up in run/continueSession instead.

        return self;
    }

    fn registerBaseToolDefinitions(
        runner: *ExtensionRunner,
        defs: []const tool_def.ToolDefinition,
    ) void {
        for (defs) |def| {
            registerBaseToolDefinition(runner, def);
        }
    }

    fn registerBaseToolDefinition(runner: *ExtensionRunner, def: tool_def.ToolDefinition) void {
        var cloned = tool_def.cloneOwned(runner.allocator, def) catch |err| {
            std.log.scoped(.extensions).warn(
                "failed to clone base tool '{s}' for registry: {s}",
                .{ def.name, @errorName(err) },
            );
            return;
        };

        const accepted = runner.tool_registry.register(cloned) catch |err| {
            std.log.scoped(.extensions).warn(
                "failed to register base tool '{s}': {s}",
                .{ def.name, @errorName(err) },
            );
            tool_def.freeOwned(runner.allocator, &cloned);
            return;
        };
        if (!accepted) {
            const winner = runner.tool_registry.get(def.name) orelse unreachable;
            std.log.scoped(.extensions).info(
                "base tool '{s}' from {s} ignored; already registered by {s}:{s}",
                .{ def.name, def.source.kind, winner.source.kind, winner.source.id },
            );
            tool_def.freeOwned(runner.allocator, &cloned);
        }
    }

    fn toolNameSlice(
        allocator: std.mem.Allocator,
        defs: []const tool_def.ToolDefinition,
    ) ![]const []const u8 {
        const names = try allocator.alloc([]const u8, defs.len);
        for (defs, 0..) |def, i| names[i] = def.name;
        return names;
    }

    fn collectToolSnippets(
        allocator: std.mem.Allocator,
        defs: []const tool_def.ToolDefinition,
    ) ![]const system_prompt_mod.ToolSnippet {
        var count: usize = 0;
        for (defs) |def| {
            if (def.prompt_snippet != null) count += 1;
        }
        const snippets = try allocator.alloc(system_prompt_mod.ToolSnippet, count);
        var i: usize = 0;
        for (defs) |def| {
            const snippet = def.prompt_snippet orelse continue;
            snippets[i] = .{ .name = def.name, .snippet = snippet };
            i += 1;
        }
        return snippets;
    }

    fn hasToolNamed(defs: []const tool_def.ToolDefinition, wanted: []const u8) bool {
        for (defs) |def| {
            if (std.mem.eql(u8, def.name, wanted)) return true;
        }
        return false;
    }

    fn collectGuidelines(
        allocator: std.mem.Allocator,
        defs: []const tool_def.ToolDefinition,
    ) ![]const []const u8 {
        var total: usize = 0;
        for (defs) |def| total += def.prompt_guidelines.len;
        const guidelines = try allocator.alloc([]const u8, total);
        var i: usize = 0;
        for (defs) |def| {
            for (def.prompt_guidelines) |guideline| {
                var dup = false;
                for (guidelines[0..i]) |existing| {
                    if (std.mem.eql(u8, existing, guideline)) {
                        dup = true;
                        break;
                    }
                }
                if (dup) continue;
                guidelines[i] = guideline;
                i += 1;
            }
        }
        return guidelines[0..i];
    }

    /// Tear down the extension runner + lua_State on whichever thread
    /// owns the lua_State. This MUST run on the agent thread (the
    /// owner per zi-wub.5/.6) so `lua_close` happens on the bound
    /// thread. Called by the long-lived agent owner loop after
    /// `Interactive.deinit` closes the request inbox (zi-wub.28);
    /// after this runs, `AgentSession.deinit` sees null fields and
    /// skips the blocks.
    ///
    /// Idempotent. Unsubscribes the extension bridge first so no
    /// in-flight agent event can re-enter the runner mid-teardown.
    pub fn shutdownExtensionsOnAgentThread(self: *AgentSession) void {
        if (self._extension_subscription_token) |token| {
            self.agent.unsubscribe(token);
            self._extension_subscription_token = null;
        }
        if (self._extension_runner) |runner| {
            runner.deinit();
            self.allocator.destroy(runner);
            self._extension_runner = null;
        }
        if (self._extension_lua_state) |state| {
            state.deinit();
            self.allocator.destroy(state);
            self._extension_lua_state = null;
        }
    }

    /// Canonical session-owned model switch. Owns validation,
    /// in-memory state mutation, session persistence, and thinking-
    /// level reclamp for the new model's capabilities.
    pub fn trySetModel(self: *AgentSession, model: ai.protocol.Model) ModelSwitchResult {
        const registry = self.model_registry orelse return .registry_unavailable;
        if (!registry.hasConfiguredAuth(model)) {
            return .{ .no_auth = model };
        }

        const previous_thinking = self.agent.state.thinking_level;
        const next_thinking = clampThinkingLevelForModel(previous_thinking, model);
        const thinking_changed = next_thinking != previous_thinking;

        self.agent.state.model = model;
        self.agent.state.thinking_level = next_thinking;
        const provider_str = ai.json_util.providerToString(model.provider);
        self.session_store.appendModelChange(provider_str, model.id);
        if (self.settings_manager) |settings| {
            settings.setDefaultModelAndProvider(provider_str, model.id);
            persistDefaultThinkingLevel(settings, model, next_thinking);
        }
        if (thinking_changed) {
            self.session_store.appendThinkingLevelChange(agentThinkingLevelToString(next_thinking));
        }
        return .{ .success = .{
            .model = model,
            .thinking_level = next_thinking,
            .thinking_level_changed = thinking_changed,
        } };
    }

    pub fn trySetThinkingLevel(self: *AgentSession, level: protocol.ThinkingLevel) ThinkingLevelChangeResult {
        const effective = clampThinkingLevelForModel(level, self.agent.state.model);
        const changed = effective != self.agent.state.thinking_level;
        self.agent.state.thinking_level = effective;
        if (changed) {
            self.session_store.appendThinkingLevelChange(agentThinkingLevelToString(effective));
            if (self.settings_manager) |settings| {
                persistDefaultThinkingLevel(settings, self.agent.state.model, effective);
            }
        }
        return .{ .level = effective, .changed = changed };
    }

    pub fn getAvailableThinkingLevelsForModel(model: ai.protocol.Model) []const protocol.ThinkingLevel {
        return if (!model.reasoning)
            &.{.off}
        else if (ai.protocol.supportsXhigh(model))
            &.{ .off, .minimal, .low, .medium, .high, .xhigh }
        else
            &.{ .off, .minimal, .low, .medium, .high };
    }

    fn clampThinkingLevelForModel(level: protocol.ThinkingLevel, model: ai.protocol.Model) protocol.ThinkingLevel {
        if (!model.reasoning) return .off;
        return switch (level) {
            .xhigh => if (ai.protocol.supportsXhigh(model)) .xhigh else .high,
            else => level,
        };
    }

    fn agentThinkingLevelToString(level: protocol.ThinkingLevel) []const u8 {
        return switch (level) {
            .off => "off",
            .minimal => "minimal",
            .low => "low",
            .medium => "medium",
            .high => "high",
            .xhigh => "xhigh",
        };
    }

    fn agentThinkingLevelToDefault(level: protocol.ThinkingLevel) settings_types_mod.DefaultThinkingLevel {
        return switch (level) {
            .off => .off,
            .minimal => .minimal,
            .low => .low,
            .medium => .medium,
            .high => .high,
            .xhigh => .xhigh,
        };
    }

    fn persistDefaultThinkingLevel(
        settings: *settings_manager_mod.SettingsManager,
        model: ai.protocol.Model,
        level: protocol.ThinkingLevel,
    ) void {
        if (model.reasoning or level != .off) {
            settings.setDefaultThinkingLevel(agentThinkingLevelToDefault(level));
        }
    }

    pub fn replaceSessionStore(self: *AgentSession, new_store: SessionStore) !void {
        const session_id = new_store.sessionId();
        try self.agent.setSessionId(session_id);
        if (self._builtin_ctx) |ctx| {
            ctx.session_id = session_id;
        }
        self.session_store.deinit();
        self.session_store = new_store;
        self.refreshContextUsageStateFromStore();
    }

    /// Reset the active session to a fresh header-only session while
    /// preserving the current model + thinking defaults for future resume.
    ///
    /// Ownership: agent-thread only. Mutates `session_store` and
    /// `agent.state`, both owned by the agent thread per doctrine.
    pub fn startNewSession(self: *AgentSession) !void {
        var new_store = blk: {
            if (!self.session_store.writer.persist) {
                break :blk SessionStore.createEphemeral(self.allocator);
            }
            const cwd = self.resource_loader.cwd;
            const session_dir = try storage.getSessionDirForCwd(self.allocator, cwd, null);
            defer self.allocator.free(session_dir);
            break :blk SessionStore.create(self.allocator, session_dir, cwd);
        };
        errdefer new_store.deinit();

        try self.replaceSessionStore(new_store);
        self.agent.reset();
        self.session_store.appendModelChange(ai.json_util.providerToString(self.agent.state.model.provider), self.agent.state.model.id);
        self.session_store.appendThinkingLevelChange(agentThinkingLevelToString(self.agent.state.thinking_level));
    }

    /// Current context usage for the active model.
    ///
    /// Mirrors pi-mono's `AgentSession.getContextUsage()` semantics:
    /// - no model / zero context window → null
    /// - after compaction, usage stays unknown until the first successful
    ///   post-compaction assistant response lands
    /// - otherwise use the last assistant usage plus heuristic estimates for
    ///   trailing messages
    ///
    /// Unlike the earlier zi implementation, this hot path does NOT reread the
    /// session file. The compaction boundary is tracked on the agent thread and
    /// refreshed only when the active session store changes.
    pub fn getContextUsage(self: *const AgentSession) ?ContextUsage {
        const model = self.agent.state.model;
        if (model.context_window == 0) return null;

        if (self.context_usage_unknown_after_compaction) {
            return .{
                .tokens = null,
                .context_window = model.context_window,
                .percent = null,
            };
        }

        return contextUsageFromMessages(model.context_window, self.agent.state.messages);
    }

    pub fn statusSnapshot(self: *const AgentSession) StatusSnapshot {
        const usage = self.getContextUsage();
        return .{
            .model_provider = ai.json_util.providerToString(self.agent.state.model.provider),
            .model_id = self.agent.state.model.id,
            .thinking_level = self.agent.state.thinking_level,
            .context_tokens = if (usage) |u| u.tokens else null,
            .context_window = if (usage) |u| u.context_window else self.agent.state.model.context_window,
        };
    }

    pub fn noteCompactionApplied(self: *AgentSession) void {
        self.context_usage_unknown_after_compaction = true;
    }

    fn refreshContextUsageStateFromStore(self: *AgentSession) void {
        self.context_usage_unknown_after_compaction = contextUsageUnknownFromStore(self.allocator, &self.session_store);
    }

    fn noteMessageForContextUsage(self: *AgentSession, message: protocol.AgentMessage) void {
        if (!self.context_usage_unknown_after_compaction) return;
        switch (message) {
            .assistant => |assistant| switch (assistant.stop_reason) {
                .aborted, .@"error" => {},
                else => {
                    if (session_mod.context_usage.calculateContextTokens(assistant.usage) > 0) {
                        self.context_usage_unknown_after_compaction = false;
                    }
                },
            },
            else => {},
        }
    }

    fn contextUsageUnknownFromStore(
        allocator: std.mem.Allocator,
        store: *const SessionStore,
    ) bool {
        const entries = store.cached_entries orelse return false;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const branch = session_mod.context_usage.buildBranchEntries(
            arena.allocator(),
            entries,
            store.leafId(),
        ) catch return false;
        if (session_mod.context_usage.getLatestCompactionEntry(branch) == null) return false;
        return !hasPostCompactionUsage(branch);
    }

    fn hasPostCompactionUsage(branch: []const session_mod.protocol.SessionEntry) bool {
        var i: usize = branch.len;
        scan: while (i > 0) {
            i -= 1;
            switch (branch[i].entry) {
                .compaction => break :scan,
                .message => |m| switch (m.message) {
                    .assistant => |assistant| switch (assistant.stop_reason) {
                        .aborted, .@"error" => {},
                        else => return session_mod.context_usage.calculateContextTokens(assistant.usage) > 0,
                    },
                    else => {},
                },
                else => {},
            }
        }
        return false;
    }

    fn contextUsageFromMessages(context_window: u64, messages: []const protocol.AgentMessage) ContextUsage {
        const estimate = session_mod.context_usage.estimateContextTokens(messages);
        return .{
            .tokens = estimate.tokens,
            .context_window = context_window,
            .percent = (@as(f64, @floatFromInt(estimate.tokens)) / @as(f64, @floatFromInt(context_window))) * 100.0,
        };
    }

    pub fn deinit(self: *AgentSession) void {
        // Unsubscribe extension bridge FIRST so no agent event can
        // re-enter the runner mid-teardown. Then unsubscribe the
        // persistence listener.
        // zi-wub.28: in interactive mode the extension teardown
        // already ran on the agent thread via
        // shutdownExtensionsOnAgentThread() — these blocks are no-ops
        // because the fields are already null. Non-interactive callers
        // (tests, print mode without ext) still get the same teardown
        // here, on whatever thread owns lua (single-thread by default).
        if (self._extension_subscription_token) |token| {
            self.agent.unsubscribe(token);
            self._extension_subscription_token = null;
        }
        if (self._subscription_token) |token| {
            self.agent.unsubscribe(token);
        }
        if (self._extension_runner) |runner| {
            runner.deinit();
            self.allocator.destroy(runner);
            self._extension_runner = null;
        }
        if (self._extension_lua_state) |state| {
            state.deinit();
            self.allocator.destroy(state);
            self._extension_lua_state = null;
        }
        self.allocator.destroy(self._stream_closure);
        self.event_listeners.deinit(self.allocator);
        self.agent.deinit();
        self.session_store.deinit();
        self.resource_loader.deinit();
        // Provider bundle goes last — the agent's stream closure may
        // still hold references into the registry until agent.deinit
        // returns. Destroying earlier is a use-after-free risk.
        if (self._owned_provider_bundle) |bundle| {
            bundle.deinit();
            self._owned_provider_bundle = null;
        }
    }

    pub fn subscribeEvents(
        self: *AgentSession,
        func: *const fn (event: protocol.AgentEvent, ctx: ?*anyopaque) void,
        ctx: ?*anyopaque,
    ) EventSubscriptionToken {
        const index = self.event_listeners.items.len;
        self.event_listeners.append(self.allocator, .{ .func = func, .ctx = ctx }) catch return .{ .index = std.math.maxInt(usize) };
        return .{ .index = index };
    }

    pub fn unsubscribeEvents(self: *AgentSession, token: EventSubscriptionToken) void {
        if (token.index < self.event_listeners.items.len) {
            _ = self.event_listeners.orderedRemove(token.index);
        }
    }

    /// Subscribe the session persistence listener.
    /// Must be called after self is pinned (not moved).
    fn wireSubscription(self: *AgentSession) void {
        if (self._subscription_token == null) {
            self._subscription_token = self.agent.subscribe(&eventListener, @ptrCast(self));
        }
        // Wire the extension event bridge once the session is pinned.
        // The runner pointer is heap-allocated and stable for the
        // session lifetime; agent.subscribe stores the ctx ptr.
        if (self._extension_subscription_token == null) {
            if (self._extension_runner) |runner| {
                self._extension_subscription_token = self.agent.subscribe(
                    &event_bridge.agentEventSink,
                    @ptrCast(runner),
                );
            }
        }
    }

    fn bindExtensionRuntimeIfNeeded(self: *AgentSession) void {
        const runner = self._extension_runner orelse return;
        if (runner.isBound()) return;

        runner.bindRuntime(.{
            .session = @ptrCast(self),
            .ui = null,
            .command_actions = null,
            .get_model = &runtimeGetModel,
            .is_idle = &runtimeIsIdle,
            .abort = &runtimeAbort,
            .has_pending_messages = &runtimeHasPendingMessages,
            .shutdown = null,
            .get_context_usage = &runtimeGetContextUsage,
            .get_system_prompt = &runtimeGetSystemPrompt,
        }) catch {};
    }

    fn runtimeGetModel(session_ptr: *anyopaque) protocol.Model {
        const self: *AgentSession = @ptrCast(@alignCast(session_ptr));
        return self.agent.state.model;
    }

    fn runtimeIsIdle(session_ptr: *anyopaque) bool {
        const self: *AgentSession = @ptrCast(@alignCast(session_ptr));
        return !self.agent.state.is_streaming;
    }

    fn runtimeAbort(session_ptr: *anyopaque) void {
        const self: *AgentSession = @ptrCast(@alignCast(session_ptr));
        self.agent.abort();
    }

    fn runtimeHasPendingMessages(session_ptr: *anyopaque) bool {
        const self: *AgentSession = @ptrCast(@alignCast(session_ptr));
        return self.agent.hasQueuedMessages();
    }

    fn runtimeGetContextUsage(session_ptr: *anyopaque) ?ContextUsage {
        const self: *AgentSession = @ptrCast(@alignCast(session_ptr));
        return self.getContextUsage();
    }

    fn runtimeGetSystemPrompt(session_ptr: *anyopaque) []const u8 {
        const self: *AgentSession = @ptrCast(@alignCast(session_ptr));
        return self.agent.state.system_prompt;
    }

    /// Run a new prompt. Wires session persistence, then delegates to Agent.prompt.
    pub fn run(self: *AgentSession, prompt_text: []const u8) !void {
        // zi-wub.6: this thread is now the lua owner. Bind BEFORE
        // wireSubscription because subscribe→agentEventSink calls
        // assertOnLuaThread on the first event. Interactive mode now
        // uses one long-lived agent owner thread, so this bind is
        // idempotent after startup rather than a per-prompt rebind.
        if (self._extension_runner) |runner| {
            runner.bindLuaOwnerThread(std.Thread.getCurrentId());
        }
        self.bindExtensionRuntimeIfNeeded();
        self.wireSubscription();

        const user_msg = protocol.AgentMessage{
            .user = .{
                .content = .{ .text = prompt_text },
                .timestamp = std.time.milliTimestamp(),
            },
        };
        const prompts = [_]protocol.AgentMessage{user_msg};
        try self.agent.prompt(&prompts);
    }

    /// Continue from loaded session context.
    /// Expects initial_messages were seeded via Options.
    /// If transcript ends with assistant (nothing to continue from),
    /// returns NeedsPrompt so the caller can provide one.
    pub fn continueSession(self: *AgentSession) !void {
        // zi-wub.6: see `run()` for the bind rationale; on the
        // long-lived interactive agent owner thread this is idempotent.
        if (self._extension_runner) |runner| {
            runner.bindLuaOwnerThread(std.Thread.getCurrentId());
        }
        self.bindExtensionRuntimeIfNeeded();
        self.wireSubscription();
        self.agent.@"continue"() catch |err| switch (err) {
            error.CannotContinueFromAssistant => return error.NeedsPrompt,
            else => return err,
        };
    }

    pub fn completeUserText(
        self: *AgentSession,
        allocator: std.mem.Allocator,
        system_prompt: ?[]const u8,
        prompt_text: []const u8,
        max_tokens: u64,
    ) ![]u8 {
        const provider = self._stream_closure.registry.get(ai.provider.apiToString(self.agent.state.model.api)) orelse return error.ProviderUnavailable;

        const user_messages = [_]ai.protocol.Message{.{ .user = .{
            .content = .{ .text = prompt_text },
            .timestamp = std.time.milliTimestamp(),
        } }};
        const context = ai.protocol.Context{
            .system_prompt = system_prompt,
            .messages = &user_messages,
        };

        var collector = CompletionCollector{ .allocator = allocator };
        provider.streamSimple(
            allocator,
            self.agent.state.model,
            context,
            .{
                .base = .{
                    .api_key = self._stream_closure.resolveApiKey(self.agent.state.model),
                    .max_tokens = max_tokens,
                },
                .reasoning = if (self.agent.state.model.reasoning) .high else null,
            },
            &CompletionCollector.callback,
            @ptrCast(&collector),
        );

        if (collector.error_message) |msg| {
            defer allocator.free(msg);
            std.log.scoped(.coding_agent).warn("completion failed: {s}", .{msg});
            return error.ProviderCompletionFailed;
        }
        return collector.text orelse error.MissingCompletionText;
    }

    /// Get session file path (valid after first flush).
    pub fn getSessionFile(self: *const AgentSession) []const u8 {
        return self.session_store.sessionFile();
    }

    /// Public accessor — the TUI layer uses this to wire the
    /// runner into `Transcript.lua_runner` for render hook
    /// dispatch. Returns null in modes without extensions or
    /// when the runner failed to initialize.
    pub fn extensionRunner(self: *AgentSession) ?*ExtensionRunner {
        return self._extension_runner;
    }

    pub fn sessionFlushed(self: *const AgentSession) bool {
        return self.session_store.writer.flushed;
    }

    /// Event listener: forwards to user-provided handler, then persists.
    /// pi-mono ordering: extensions → listeners → persistence (agent-session.ts:507-530)
    fn eventListener(event: protocol.AgentEvent, ctx: ?*anyopaque) void {
        const self: *AgentSession = @ptrCast(@alignCast(ctx));

        switch (event) {
            .message_end => |me| {
                self.noteMessageForContextUsage(me.message);
            },
            else => {},
        }

        // Forward to external handler first
        if (self.event_handler) |handler| {
            handler.func(event, handler.ctx);
        }
        for (self.event_listeners.items) |handler| {
            handler.func(event, handler.ctx);
        }

        // Session persistence on message_end
        switch (event) {
            .message_end => |me| {
                self.session_store.appendMessage(me.message);
            },
            else => {},
        }
    }

    // -- Stream hook wrapping provider registry + auth -----------------------
    // pi-mono injects auth in the streamFn closure (sdk.ts:274-283).
    // We do the same: capture registry + api_key so the Agent doesn't need
    // to thread auth through AgentLoopConfig.

    fn getApiKeyFromStorage(provider_str: []const u8, ctx: ?*anyopaque) ?[]const u8 {
        const auth: *auth_storage_mod.AuthStorage = @ptrCast(@alignCast(ctx.?));
        return auth.getApiKey(provider_str);
    }

    /// Captured at session construction. The api key is resolved
    /// LIVE on every stream — the closure prefers `auth_storage`
    /// (so post-`/login` token refresh is picked up without
    /// rebuilding the session) and falls back to the static
    /// `api_key` snapshot only when no auth storage is attached
    /// (the test path). See beads zi-yjc for the bug this fixes.
    const StreamClosure = struct {
        registry: *ai.provider.Registry,
        auth_storage: ?*auth_storage_mod.AuthStorage,
        api_key: []const u8,
        max_tokens: ?u64,

        fn streamFn(
            ctx: ?*anyopaque,
            stream_alloc: std.mem.Allocator,
            model: ai.protocol.Model,
            stream_context: ai.protocol.Context,
            options: ai.protocol.SimpleStreamOptions,
            callback: ai.provider.EventCallback,
            callback_ctx: ?*anyopaque,
        ) void {
            const self: *const StreamClosure = @ptrCast(@alignCast(ctx.?));
            const api_str = ai.provider.apiToString(model.api);
            const prov = self.registry.get(api_str) orelse return;
            var opts = options;
            if (opts.base.api_key == null or opts.base.api_key.?.len == 0) {
                opts.base.api_key = self.resolveApiKey(model);
            }
            if (self.max_tokens) |mt| opts.base.max_tokens = mt;
            prov.streamSimple(stream_alloc, model, stream_context, opts, callback, callback_ctx);
        }

        /// Live key lookup. Auth storage wins so /login + token
        /// refresh take effect without restart; the static snapshot
        /// is the test fallback.
        fn resolveApiKey(self: *const StreamClosure, model: ai.protocol.Model) []const u8 {
            if (self.auth_storage) |as| {
                const provider_str = ai.json_util.providerToString(model.provider);
                if (as.getApiKey(provider_str)) |k| {
                    if (k.len > 0) return k;
                }
            }
            return self.api_key;
        }
    };

    const CompletionCollector = struct {
        allocator: std.mem.Allocator,
        text: ?[]u8 = null,
        error_message: ?[]u8 = null,

        fn callback(event: ai.protocol.AssistantMessageEvent, ctx: ?*anyopaque) void {
            const self: *CompletionCollector = @ptrCast(@alignCast(ctx.?));
            switch (event) {
                .done => |done| {
                    self.text = collectText(self.allocator, done.message) catch null;
                },
                .@"error" => |err| {
                    if (err.@"error".error_message) |msg| {
                        self.error_message = self.allocator.dupe(u8, msg) catch null;
                    } else {
                        self.error_message = self.allocator.dupe(u8, "provider error") catch null;
                    }
                },
                else => {},
            }
        }

        fn collectText(allocator: std.mem.Allocator, msg: ai.protocol.AssistantMessage) ![]u8 {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(allocator);
            for (msg.content) |block| switch (block) {
                .text => |t| try out.appendSlice(allocator, t.text),
                else => {},
            };
            return out.toOwnedSlice(allocator);
        }
    };
};

// ── convertToLlm ──────────────────────────────────────────────────────────
//
// pi-mono source: packages/coding-agent/src/core/messages.ts:148-195
// The base agent's defaultConvertToLlm silently drops compaction_summary,
// branch_summary, and custom. The coding agent's version converts them to
// user messages with the proper prefix/suffix wrapping.

const COMPACTION_SUMMARY_PREFIX =
    "The conversation history before this point was compacted into the following summary:\n\n<summary>\n";
const COMPACTION_SUMMARY_SUFFIX = "\n</summary>";

const BRANCH_SUMMARY_PREFIX =
    "The following is a summary of a branch that this conversation came back from:\n\n<summary>\n";
const BRANCH_SUMMARY_SUFFIX = "</summary>";

pub fn convertToLlm(
    allocator: std.mem.Allocator,
    messages: []const protocol.AgentMessage,
    _: ?*anyopaque,
) []const ai.protocol.Message {
    var result: std.ArrayList(ai.protocol.Message) = .empty;
    for (messages) |msg| {
        switch (msg) {
            .user => |u| result.append(allocator, .{ .user = u }) catch continue,
            .assistant => |a| result.append(allocator, .{ .assistant = a }) catch continue,
            .tool_result => |t| result.append(allocator, .{ .tool_result = t }) catch continue,
            .compaction_summary => |cs| {
                const text = std.fmt.allocPrint(
                    allocator,
                    "{s}{s}{s}",
                    .{ COMPACTION_SUMMARY_PREFIX, cs.summary, COMPACTION_SUMMARY_SUFFIX },
                ) catch continue;
                const blocks = allocator.alloc(ai.protocol.UserMessage.UserMessageContent.Block, 1) catch continue;
                blocks[0] = .{ .text = .{ .text = text } };
                result.append(allocator, .{ .user = .{
                    .content = .{ .blocks = blocks },
                    .timestamp = cs.timestamp,
                } }) catch continue;
            },
            .branch_summary => |bs| {
                const text = std.fmt.allocPrint(
                    allocator,
                    "{s}{s}{s}",
                    .{ BRANCH_SUMMARY_PREFIX, bs.summary, BRANCH_SUMMARY_SUFFIX },
                ) catch continue;
                const blocks = allocator.alloc(ai.protocol.UserMessage.UserMessageContent.Block, 1) catch continue;
                blocks[0] = .{ .text = .{ .text = text } };
                result.append(allocator, .{ .user = .{
                    .content = .{ .blocks = blocks },
                    .timestamp = bs.timestamp,
                } }) catch continue;
            },
            .custom => |c| {
                const user_content: ai.protocol.UserMessage.UserMessageContent = switch (c.content) {
                    .text => |t| blk: {
                        const blocks = allocator.alloc(ai.protocol.UserMessage.UserMessageContent.Block, 1) catch continue;
                        blocks[0] = .{ .text = .{ .text = t } };
                        break :blk .{ .blocks = blocks };
                    },
                    .blocks => |b| .{ .blocks = b },
                };
                result.append(allocator, .{ .user = .{
                    .content = user_content,
                    .timestamp = c.timestamp,
                } }) catch continue;
            },
        }
    }
    return result.items;
}

pub const OpenSessionResult = struct {
    allocator: std.mem.Allocator,
    store: ?SessionStore,
    context_arena: std.heap.ArenaAllocator,
    messages: []protocol.AgentMessage,
    model: ?session_mod.context.SessionContext.ModelInfo,
    thinking_level: []const u8,

    pub fn deinit(self: *OpenSessionResult) void {
        self.context_arena.deinit();
        if (self.store) |*store| {
            store.deinit();
            self.store = null;
        }
    }

    pub fn takeStore(self: *OpenSessionResult) SessionStore {
        const store = self.store orelse @panic("OpenSessionResult.takeStore called twice");
        self.store = null;
        return store;
    }
};

/// Open a session file and build context for --continue.
/// Returns an owned result that carries both the SessionStore (ready for
/// appending) and the resolved context. Callers must either `deinit()` the
/// result or `takeStore()` before deinit when transferring store ownership.
///
/// pi-mono: SessionManager.buildSessionContext → Agent.state.messages = existingSession.messages
pub fn openSession(
    allocator: std.mem.Allocator,
    session_path: []const u8,
) !OpenSessionResult {
    var store = try SessionStore.open(allocator, session_path);
    errdefer store.deinit();

    var context_arena = std.heap.ArenaAllocator.init(allocator);
    errdefer context_arena.deinit();

    const ctx = try session_mod.context.buildSessionContext(context_arena.allocator(), store.cached_entries.?, null);
    return .{
        .allocator = allocator,
        .store = store,
        .context_arena = context_arena,
        .messages = ctx.messages,
        .model = ctx.model,
        .thinking_level = ctx.thinking_level,
    };
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "trySetModel updates session state and appends model change when auth exists" {
    const alloc = testing.allocator;

    var auth = try auth_storage_mod.AuthStorage.create(alloc, null);
    defer auth.deinit();
    auth.setRuntimeApiKey("anthropic", "test-key");

    var model_registry = try ai.model_registry.ModelRegistry.init(alloc, &auth, &.{});
    defer model_registry.deinit();

    var fp = faux.FauxProvider.init(alloc);
    var registry = ai.provider.Registry.init(alloc);
    defer registry.deinit();
    try registry.register("faux", fp.provider(), null);

    const target = model_registry.find(.anthropic, "claude-opus-4-6") orelse return error.MissingCatalogEntry;
    var ca = AgentSession.init(alloc, .{
        .model = faux.fauxModel(),
        .api_key = "test-key",
        .cwd = "/tmp/zi-test",
        .resource_loader = createTestResourceLoader(alloc, "/tmp/zi-test"),
        .registry = &registry,
        .auth_storage = &auth,
        .model_registry = &model_registry,
        .no_session = true,
    });
    defer ca.deinit();

    const result = ca.trySetModel(target);
    try testing.expect(result == .success);
    try testing.expectEqualStrings(target.id, result.success.model.id);
    try testing.expectEqual(.off, result.success.thinking_level);
    try testing.expect(!result.success.thinking_level_changed);
    try testing.expectEqualStrings(target.id, ca.agent.state.model.id);
    try testing.expectEqual(@as(usize, 1), ca.session_store.writer.buffered_entries.items.len);
    const entry = ca.session_store.writer.buffered_entries.items[0].entry;
    try testing.expect(entry.entry == .model_change);
    try testing.expectEqualStrings("anthropic", entry.entry.model_change.provider);
    try testing.expectEqualStrings(target.id, entry.entry.model_change.model_id);
}

test "trySetModel reclamps xhigh to high and persists thinking change when target lacks xhigh" {
    const alloc = testing.allocator;

    var auth = try auth_storage_mod.AuthStorage.create(alloc, null);
    defer auth.deinit();
    auth.setRuntimeApiKey("anthropic", "test-key");

    var model_registry = try ai.model_registry.ModelRegistry.init(alloc, &auth, &.{});
    defer model_registry.deinit();

    var fp = faux.FauxProvider.init(alloc);
    var registry = ai.provider.Registry.init(alloc);
    defer registry.deinit();
    try registry.register("faux", fp.provider(), null);

    const target = model_registry.find(.anthropic, "claude-sonnet-4-20250514") orelse return error.MissingCatalogEntry;
    var ca = AgentSession.init(alloc, .{
        .model = model_registry.find(.anthropic, "claude-opus-4-6") orelse return error.MissingCatalogEntry,
        .api_key = "test-key",
        .cwd = "/tmp/zi-test",
        .resource_loader = createTestResourceLoader(alloc, "/tmp/zi-test"),
        .registry = &registry,
        .auth_storage = &auth,
        .model_registry = &model_registry,
        .thinking_level = .xhigh,
        .no_session = true,
    });
    defer ca.deinit();

    const result = ca.trySetModel(target);
    try testing.expect(result == .success);
    try testing.expectEqual(.high, result.success.thinking_level);
    try testing.expect(result.success.thinking_level_changed);
    try testing.expectEqual(.high, ca.agent.state.thinking_level);
    try testing.expectEqual(@as(usize, 2), ca.session_store.writer.buffered_entries.items.len);
    const thinking_entry = ca.session_store.writer.buffered_entries.items[1].entry;
    try testing.expect(thinking_entry.entry == .thinking_level_change);
    try testing.expectEqualStrings("high", thinking_entry.entry.thinking_level_change.thinking_level);
}

test "trySetModel persists defaults through settings manager" {
    const alloc = testing.allocator;

    var auth = try auth_storage_mod.AuthStorage.create(alloc, null);
    defer auth.deinit();
    auth.setRuntimeApiKey("anthropic", "test-key");

    var settings = try settings_manager_mod.SettingsManager.inMemory(alloc, null);
    defer settings.deinit();

    var model_registry = try ai.model_registry.ModelRegistry.init(alloc, &auth, &.{});
    defer model_registry.deinit();

    var fp = faux.FauxProvider.init(alloc);
    var registry = ai.provider.Registry.init(alloc);
    defer registry.deinit();
    try registry.register("faux", fp.provider(), null);

    const target = model_registry.find(.anthropic, "claude-opus-4-6") orelse return error.MissingCatalogEntry;
    var ca = AgentSession.init(alloc, .{
        .model = faux.fauxModel(),
        .api_key = "test-key",
        .cwd = "/tmp/zi-test",
        .resource_loader = createTestResourceLoader(alloc, "/tmp/zi-test"),
        .registry = &registry,
        .auth_storage = &auth,
        .settings_manager = &settings,
        .model_registry = &model_registry,
        .no_session = true,
    });
    defer ca.deinit();

    const result = ca.trySetModel(target);
    try testing.expect(result == .success);
    try testing.expectEqualStrings("anthropic", settings.getDefaultProvider().?);
    try testing.expectEqualStrings(target.id, settings.getDefaultModel().?);
    try testing.expectEqual(settings_types_mod.DefaultThinkingLevel.off, settings.getDefaultThinkingLevel().?);
}

test "trySetThinkingLevel persists default through settings manager" {
    const alloc = testing.allocator;

    var auth = try auth_storage_mod.AuthStorage.create(alloc, null);
    defer auth.deinit();
    auth.setRuntimeApiKey("anthropic", "test-key");

    var settings = try settings_manager_mod.SettingsManager.inMemory(alloc, null);
    defer settings.deinit();

    var model_registry = try ai.model_registry.ModelRegistry.init(alloc, &auth, &.{});
    defer model_registry.deinit();

    var fp = faux.FauxProvider.init(alloc);
    var registry = ai.provider.Registry.init(alloc);
    defer registry.deinit();
    try registry.register("faux", fp.provider(), null);

    const initial = model_registry.find(.anthropic, "claude-opus-4-6") orelse return error.MissingCatalogEntry;
    var ca = AgentSession.init(alloc, .{
        .model = initial,
        .api_key = "test-key",
        .cwd = "/tmp/zi-test",
        .resource_loader = createTestResourceLoader(alloc, "/tmp/zi-test"),
        .registry = &registry,
        .auth_storage = &auth,
        .settings_manager = &settings,
        .model_registry = &model_registry,
        .no_session = true,
    });
    defer ca.deinit();

    const result = ca.trySetThinkingLevel(.high);
    try testing.expect(result.changed);
    try testing.expectEqual(.high, result.level);
    try testing.expectEqual(settings_types_mod.DefaultThinkingLevel.high, settings.getDefaultThinkingLevel().?);
}

test "trySetModel rejects unauthed model without mutating state or session" {
    const alloc = testing.allocator;

    var auth = try auth_storage_mod.AuthStorage.create(alloc, null);
    defer auth.deinit();

    var model_registry = try ai.model_registry.ModelRegistry.init(alloc, &auth, &.{});
    defer model_registry.deinit();

    var fp = faux.FauxProvider.init(alloc);
    var registry = ai.provider.Registry.init(alloc);
    defer registry.deinit();
    try registry.register("faux", fp.provider(), null);

    const initial = faux.fauxModel();
    const blocked = model_registry.find(.anthropic, "claude-opus-4-6") orelse return error.MissingCatalogEntry;
    var ca = AgentSession.init(alloc, .{
        .model = initial,
        .api_key = "test-key",
        .cwd = "/tmp/zi-test",
        .resource_loader = createTestResourceLoader(alloc, "/tmp/zi-test"),
        .registry = &registry,
        .auth_storage = &auth,
        .model_registry = &model_registry,
        .no_session = true,
    });
    defer ca.deinit();

    const result = ca.trySetModel(blocked);
    try testing.expect(result == .no_auth);
    try testing.expectEqualStrings(initial.id, ca.agent.state.model.id);
    try testing.expectEqual(@as(usize, 0), ca.session_store.writer.buffered_entries.items.len);
}

test "convertToLlm passes through user/assistant/tool_result" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const content = alloc.alloc(ai.protocol.AssistantMessage.AssistantContentBlock, 1) catch unreachable;
    content[0] = .{ .text = .{ .text = "hi" } };

    const messages = &[_]protocol.AgentMessage{
        .{ .user = .{ .content = .{ .text = "hello" }, .timestamp = 1 } },
        .{ .assistant = .{
            .content = content,
            .api = .anthropic_messages,
            .provider = .anthropic,
            .model = "test",
            .usage = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total_tokens = 0, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 } },
            .stop_reason = .stop,
            .timestamp = 2,
        } },
    };

    const result = convertToLlm(alloc, messages, null);
    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expect(result[0] == .user);
    try testing.expect(result[1] == .assistant);
}

test "convertToLlm wraps compaction_summary as user message" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const messages = &[_]protocol.AgentMessage{
        .{ .compaction_summary = .{ .summary = "Previous work summarized", .tokens_before = 5000, .timestamp = 1 } },
    };

    const result = convertToLlm(alloc, messages, null);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expect(result[0] == .user);

    // Verify the text contains prefix + summary + suffix
    const user = result[0].user;
    switch (user.content) {
        .blocks => |blocks| {
            try testing.expectEqual(@as(usize, 1), blocks.len);
            const text = blocks[0].text.text;
            try testing.expect(std.mem.indexOf(u8, text, "compacted into the following summary") != null);
            try testing.expect(std.mem.indexOf(u8, text, "Previous work summarized") != null);
            try testing.expect(std.mem.indexOf(u8, text, "<summary>") != null);
            try testing.expect(std.mem.indexOf(u8, text, "</summary>") != null);
        },
        .text => return error.ExpectedBlocks,
    }
}

test "convertToLlm wraps branch_summary as user message" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const messages = &[_]protocol.AgentMessage{
        .{ .branch_summary = .{ .summary = "Tried approach X", .from_id = "abc", .timestamp = 1 } },
    };

    const result = convertToLlm(alloc, messages, null);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expect(result[0] == .user);

    const user = result[0].user;
    switch (user.content) {
        .blocks => |blocks| {
            const text = blocks[0].text.text;
            try testing.expect(std.mem.indexOf(u8, text, "summary of a branch") != null);
            try testing.expect(std.mem.indexOf(u8, text, "Tried approach X") != null);
        },
        .text => return error.ExpectedBlocks,
    }
}

test "convertToLlm converts custom to user message" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const messages = &[_]protocol.AgentMessage{
        .{ .custom = .{ .custom_type = "skill", .content = .{ .text = "Do X" }, .display = true, .timestamp = 1 } },
    };

    const result = convertToLlm(alloc, messages, null);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expect(result[0] == .user);

    const user = result[0].user;
    switch (user.content) {
        .blocks => |blocks| {
            try testing.expectEqualStrings("Do X", blocks[0].text.text);
        },
        .text => return error.ExpectedBlocks,
    }
}

test "convertToLlm handles mixed message types in order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const content = alloc.alloc(ai.protocol.AssistantMessage.AssistantContentBlock, 1) catch unreachable;
    content[0] = .{ .text = .{ .text = "response" } };

    const messages = &[_]protocol.AgentMessage{
        .{ .compaction_summary = .{ .summary = "Summary", .tokens_before = 1000, .timestamp = 0 } },
        .{ .user = .{ .content = .{ .text = "question" }, .timestamp = 1 } },
        .{ .assistant = .{
            .content = content,
            .api = .anthropic_messages,
            .provider = .anthropic,
            .model = "test",
            .usage = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total_tokens = 0, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 } },
            .stop_reason = .stop,
            .timestamp = 2,
        } },
        .{ .branch_summary = .{ .summary = "Branch work", .from_id = "x", .timestamp = 3 } },
        .{ .custom = .{ .custom_type = "ext", .content = .{ .text = "Custom content" }, .timestamp = 4 } },
    };

    const result = convertToLlm(alloc, messages, null);
    try testing.expectEqual(@as(usize, 5), result.len);
    // All 5 should be present: compaction→user, user, assistant, branch→user, custom→user
    try testing.expect(result[0] == .user); // compaction
    try testing.expect(result[1] == .user); // original user
    try testing.expect(result[2] == .assistant);
    try testing.expect(result[3] == .user); // branch
    try testing.expect(result[4] == .user); // custom
}

// ── AgentSession e2e tests (ported from pi-mono test-harness.test.ts) ───

const faux = ai.faux;

fn createTestResourceLoader(allocator: std.mem.Allocator, cwd: []const u8) resources.ResourceLoader {
    return resources.ResourceLoader.init(allocator, .{ .cwd = cwd }) catch @panic("OOM");
}

fn createTestResourceLoaderWithAgentDir(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    agent_dir: []const u8,
) resources.ResourceLoader {
    return resources.ResourceLoader.init(allocator, .{
        .cwd = cwd,
        .agent_dir_override = agent_dir,
    }) catch @panic("OOM");
}

fn createAgentDirWithReadOverride(
    allocator: std.mem.Allocator,
    tmp: *std.testing.TmpDir,
    snippet: []const u8,
    guideline: []const u8,
    result_text: []const u8,
) ![]const u8 {
    try tmp.dir.makeDir("extensions");

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll(
        "return function(zi)\n" ++
            "  zi.register_tool({\n" ++
            "    name = \"read\",\n" ++
            "    label = \"Override Read\",\n" ++
            "    description = \"Override read for precedence tests\",\n",
    );
    try w.print("    prompt_snippet = \"{s}\",\n", .{snippet});
    try w.print("    prompt_guidelines = {{ \"{s}\" }},\n", .{guideline});
    try w.writeAll(
        "    parameters = { type = \"object\", properties = {}, required = {} },\n" ++
            "    execute = function(params, ctx)\n" ++
            "      return {\n" ++
            "        content = { { type = \"text\", text = \"",
    );
    try w.writeAll(result_text);
    try w.writeAll(
        "\" } },\n" ++
            "      }\n" ++
            "    end,\n" ++
            "  })\n" ++
            "end\n",
    );

    const src = try out.toOwnedSlice();
    defer allocator.free(src);
    try tmp.dir.writeFile(.{ .sub_path = "extensions/read.lua", .data = src });
    return tmp.dir.realpathAlloc(allocator, ".");
}

/// Test helper: create a AgentSession wired to a faux provider.
fn createTestAgentSession(
    allocator: std.mem.Allocator,
    _: *faux.FauxProvider,
    registry: *ai.provider.Registry,
    collector: *EventCollector,
) AgentSession {
    return AgentSession.init(allocator, .{
        .model = faux.fauxModel(),
        .api_key = "test-key",
        .cwd = "/tmp/zi-test",
        .resource_loader = createTestResourceLoader(allocator, "/tmp/zi-test"),
        .registry = registry,
        .tools = &.{},
        .event_handler = .{ .func = &EventCollector.callback, .ctx = @ptrCast(collector) },
    });
}

fn testUserMessage(text: []const u8, timestamp: i64) protocol.AgentMessage {
    return .{ .user = .{
        .content = .{ .text = text },
        .timestamp = timestamp,
    } };
}

fn testAssistantMessageWithUsage(
    allocator: std.mem.Allocator,
    text: []const u8,
    total_tokens: u64,
    timestamp: i64,
) protocol.AgentMessage {
    const content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText(text)};
    var message = faux.fauxAssistantMessage(allocator, &content, .stop);
    message.timestamp = timestamp;
    message.usage = .{
        .input = total_tokens,
        .output = 0,
        .cache_read = 0,
        .cache_write = 0,
        .total_tokens = total_tokens,
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 },
    };
    return .{ .assistant = message };
}

fn syncMessagesFromStore(session: *AgentSession) !void {
    const context = try session.session_store.buildContext(session.session_store.leafId());
    session.agent.loadMessages(context.messages);
    session.refreshContextUsageStateFromStore();
}

const EventCollector = struct {
    events: std.ArrayListUnmanaged(protocol.AgentEvent),
    alloc: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator) EventCollector {
        return .{ .events = .empty, .alloc = alloc };
    }

    fn deinit(self: *EventCollector) void {
        self.events.deinit(self.alloc);
    }

    fn callback(event: protocol.AgentEvent, ctx: ?*anyopaque) void {
        const self: *EventCollector = @ptrCast(@alignCast(ctx));
        self.events.append(self.alloc, event) catch {};
    }

    fn countType(self: *const EventCollector, comptime tag: std.meta.Tag(protocol.AgentEvent)) usize {
        var n: usize = 0;
        for (self.events.items) |e| {
            if (e == tag) n += 1;
        }
        return n;
    }

    fn getTextDeltas(self: *const EventCollector) []const []const u8 {
        var deltas: std.ArrayListUnmanaged([]const u8) = .empty;
        for (self.events.items) |e| {
            if (e == .message_update) {
                if (e.message_update.assistant_message_event == .text_delta) {
                    deltas.append(self.alloc, e.message_update.assistant_message_event.text_delta.delta) catch {};
                }
            }
        }
        return deltas.items;
    }
};

fn stubExec(
    _: ?*anyopaque,
    _: std.mem.Allocator,
    _: []const u8,
    _: std.json.Value,
    _: protocol.AbortSignal,
    _: ?protocol.AgentToolUpdateCallback,
    _: ?*anyopaque,
) protocol.AgentToolResult {
    return .{ .content = &.{}, .is_error = false };
}

fn testToolDefinition(name: []const u8, label: []const u8) tool_def.ToolDefinition {
    return .{
        .name = name,
        .label = label,
        .description = "x",
        .parameters = std.json.Value{ .null = {} },
        .impl = .{ .builtin = .{ .execute = &stubExec } },
        .source = .{ .kind = "test", .id = name },
    };
}

test "AgentSession: getContextUsage reports current context from assistant usage" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fp = faux.FauxProvider.init(allocator);
    var registry = ai.provider.Registry.init(allocator);
    try registry.register("faux", fp.provider(), null);
    var collector = EventCollector.init(allocator);
    var session = createTestAgentSession(allocator, &fp, &registry, &collector);
    defer session.deinit();
    defer collector.deinit();
    defer registry.deinit();
    defer fp.deinit();

    session.session_store.appendMessage(testUserMessage("hello", 1));
    session.session_store.appendMessage(testAssistantMessageWithUsage(allocator, "hi", 200, 2));
    try syncMessagesFromStore(&session);

    const usage = session.getContextUsage().?;
    try testing.expectEqual(@as(?u64, 200), usage.tokens);
    try testing.expectEqual(faux.fauxModel().context_window, usage.context_window);
    try testing.expect(usage.percent != null);
    try testing.expectApproxEqRel((@as(f64, @floatFromInt(200)) / @as(f64, @floatFromInt(faux.fauxModel().context_window))) * 100.0, usage.percent.?, 1e-9);
}

test "AgentSession: getContextUsage falls back to in-memory messages for no-session runs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fp = faux.FauxProvider.init(allocator);
    var registry = ai.provider.Registry.init(allocator);
    try registry.register("faux", fp.provider(), null);
    var collector = EventCollector.init(allocator);
    var session = AgentSession.init(allocator, .{
        .model = faux.fauxModel(),
        .api_key = "test-key",
        .cwd = "/tmp/zi-test",
        .resource_loader = createTestResourceLoader(allocator, "/tmp/zi-test"),
        .registry = &registry,
        .tools = &.{},
        .event_handler = .{ .func = &EventCollector.callback, .ctx = @ptrCast(&collector) },
        .no_session = true,
    });
    defer session.deinit();
    defer collector.deinit();
    defer registry.deinit();
    defer fp.deinit();

    const messages = [_]protocol.AgentMessage{
        testUserMessage("hello", 1),
        testAssistantMessageWithUsage(allocator, "hi", 200, 2),
    };
    session.agent.loadMessages(&messages);

    const usage = session.getContextUsage().?;
    try testing.expectEqual(@as(?u64, 200), usage.tokens);
    try testing.expectEqual(faux.fauxModel().context_window, usage.context_window);
    try testing.expect(usage.percent != null);
}

test "AgentSession: getContextUsage is unknown immediately after compaction" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fp = faux.FauxProvider.init(allocator);
    var registry = ai.provider.Registry.init(allocator);
    try registry.register("faux", fp.provider(), null);
    var collector = EventCollector.init(allocator);
    var session = createTestAgentSession(allocator, &fp, &registry, &collector);
    defer session.deinit();
    defer collector.deinit();
    defer registry.deinit();
    defer fp.deinit();

    session.session_store.appendMessage(testUserMessage("first", 1));
    session.session_store.appendMessage(testAssistantMessageWithUsage(allocator, "response1", 180_000, 2));
    session.session_store.appendMessage(testUserMessage("second", 3));
    const kept_user_id = session.session_store.leafId().?;
    session.session_store.appendMessage(testAssistantMessageWithUsage(allocator, "response2", 195_000, 4));
    session.session_store.appendCompaction("summary", kept_user_id, 195_000);
    session.session_store.appendMessage(testUserMessage("third", 5));
    try syncMessagesFromStore(&session);

    const usage = session.getContextUsage().?;
    try testing.expectEqual(@as(?u64, null), usage.tokens);
    try testing.expectEqual(@as(?f64, null), usage.percent);
    try testing.expectEqual(faux.fauxModel().context_window, usage.context_window);
}

test "AgentSession: in-memory compaction state clears on the first successful post-compaction assistant" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fp = faux.FauxProvider.init(allocator);
    var registry = ai.provider.Registry.init(allocator);
    try registry.register("faux", fp.provider(), null);
    var collector = EventCollector.init(allocator);
    var session = AgentSession.init(allocator, .{
        .model = faux.fauxModel(),
        .api_key = "test-key",
        .cwd = "/tmp/zi-test",
        .resource_loader = createTestResourceLoader(allocator, "/tmp/zi-test"),
        .registry = &registry,
        .tools = &.{},
        .event_handler = .{ .func = &EventCollector.callback, .ctx = @ptrCast(&collector) },
        .no_session = true,
    });
    defer session.deinit();
    defer collector.deinit();
    defer registry.deinit();
    defer fp.deinit();

    const before = [_]protocol.AgentMessage{
        .{ .compaction_summary = .{ .summary = "summary", .tokens_before = 195_000, .timestamp = 1 } },
        testUserMessage("third", 2),
    };
    session.agent.loadMessages(&before);
    session.noteCompactionApplied();

    const unknown_usage = session.getContextUsage().?;
    try testing.expectEqual(@as(?u64, null), unknown_usage.tokens);
    try testing.expectEqual(@as(?f64, null), unknown_usage.percent);

    const post = testAssistantMessageWithUsage(allocator, "response3", 25_000, 3);
    const after = [_]protocol.AgentMessage{
        before[0],
        before[1],
        post,
    };
    session.agent.loadMessages(&after);
    session.noteMessageForContextUsage(post);

    const known_usage = session.getContextUsage().?;
    try testing.expectEqual(@as(?u64, 25_000), known_usage.tokens);
    try testing.expect(known_usage.percent != null);
}

test "AgentSession: getContextUsage prefers post-compaction assistant usage" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fp = faux.FauxProvider.init(allocator);
    var registry = ai.provider.Registry.init(allocator);
    try registry.register("faux", fp.provider(), null);
    var collector = EventCollector.init(allocator);
    var session = createTestAgentSession(allocator, &fp, &registry, &collector);
    defer session.deinit();
    defer collector.deinit();
    defer registry.deinit();
    defer fp.deinit();

    session.session_store.appendMessage(testUserMessage("first", 1));
    session.session_store.appendMessage(testAssistantMessageWithUsage(allocator, "response1", 180_000, 2));
    session.session_store.appendMessage(testUserMessage("second", 3));
    const kept_user_id = session.session_store.leafId().?;
    session.session_store.appendMessage(testAssistantMessageWithUsage(allocator, "response2", 195_000, 4));
    session.session_store.appendCompaction("summary", kept_user_id, 195_000);
    session.session_store.appendMessage(testUserMessage("third", 5));
    session.session_store.appendMessage(testAssistantMessageWithUsage(allocator, "response3", 25_000, 6));
    try syncMessagesFromStore(&session);

    const usage = session.getContextUsage().?;
    try testing.expectEqual(@as(?u64, 25_000), usage.tokens);
    try testing.expect(usage.percent != null);
    try testing.expectApproxEqRel((@as(f64, @floatFromInt(25_000)) / @as(f64, @floatFromInt(faux.fauxModel().context_window))) * 100.0, usage.percent.?, 1e-9);
}

// zi-1ry: `tool_allowlist` is a strict whitelist applied AFTER
// precedence resolution. This keeps subagent spawns deterministic and
// ensures an overriding extension still wins if its tool name is
// allowlisted.
test "AgentSession: tool_allowlist filters the post-precedence tool set" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const agent_dir = try createAgentDirWithReadOverride(
        allocator,
        &tmp,
        "Allowlisted override snippet",
        "Allowlisted override guideline",
        "allowlisted override result",
    );
    defer allocator.free(agent_dir);

    var fp = faux.FauxProvider.init(allocator);
    defer fp.deinit();
    var registry = ai.provider.Registry.init(allocator);
    defer registry.deinit();
    try registry.register("faux", fp.provider(), null);

    const allow = [_][]const u8{"read"};
    var ca = AgentSession.init(allocator, .{
        .model = faux.fauxModel(),
        .api_key = "k",
        .cwd = "/tmp/zi-test",
        .resource_loader = createTestResourceLoaderWithAgentDir(allocator, "/tmp/zi-test", agent_dir),
        .registry = &registry,
        .tool_allowlist = &allow,
        .no_session = true,
    });
    defer ca.deinit();

    try testing.expectEqual(@as(usize, 1), ca.tools.len);
    try testing.expectEqualStrings("read", ca.tools[0].name);
    try testing.expect(std.mem.indexOf(u8, ca.agent.state.system_prompt, "Allowlisted override snippet") != null);
    try testing.expect(std.mem.indexOf(u8, ca.agent.state.system_prompt, "Read file contents") == null);
    try testing.expect(std.mem.indexOf(u8, ca.agent.state.system_prompt, "- bash:") == null);
}

test "AgentSession: user extension overrides builtin tool at execution time" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const agent_dir = try createAgentDirWithReadOverride(
        allocator,
        &tmp,
        "Execution override snippet",
        "Execution override guideline",
        "override read result",
    );
    defer allocator.free(agent_dir);

    var fp = faux.FauxProvider.init(allocator);
    defer fp.deinit();
    var args_obj = std.json.ObjectMap.init(allocator);
    try args_obj.put(try allocator.dupe(u8, "path"), .{ .string = try allocator.dupe(u8, "/tmp/ignored") });
    const tc_content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{
        faux.fauxToolCall("read", "tc-read-1", .{ .object = args_obj }),
    };
    const text_content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("done after override")};
    fp.setResponses(&.{
        faux.fauxAssistantMessage(allocator, &tc_content, .toolUse),
        faux.fauxAssistantMessage(allocator, &text_content, .stop),
    });

    var registry = ai.provider.Registry.init(allocator);
    defer registry.deinit();
    try registry.register("faux", fp.provider(), null);

    var collector = EventCollector.init(allocator);
    defer collector.deinit();
    var ca = AgentSession.init(allocator, .{
        .model = faux.fauxModel(),
        .api_key = "test-key",
        .cwd = "/tmp/zi-test",
        .resource_loader = createTestResourceLoaderWithAgentDir(allocator, "/tmp/zi-test", agent_dir),
        .registry = &registry,
        .event_handler = .{ .func = &EventCollector.callback, .ctx = @ptrCast(&collector) },
        .no_session = true,
    });
    defer ca.deinit();

    try ca.run("use read");

    try testing.expectEqual(@as(usize, 2), fp.call_count);
    try testing.expectEqual(@as(usize, 4), ca.agent.state.messages.len);
    try testing.expect(ca.agent.state.messages[2] == .tool_result);
    const tr = ca.agent.state.messages[2].tool_result;
    try testing.expectEqualStrings("read", tr.tool_name);
    try testing.expectEqual(@as(usize, 1), tr.content.len);
    switch (tr.content[0]) {
        .text => |txt| try testing.expectEqualStrings("override read result", txt.text),
        else => return error.ExpectedTextBlock,
    }
}

test "AgentSession: final prompt metadata comes from the winning tool definition" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const agent_dir = try createAgentDirWithReadOverride(
        allocator,
        &tmp,
        "Winning read snippet",
        "Winning read guideline",
        "prompt metadata override result",
    );
    defer allocator.free(agent_dir);

    var fp = faux.FauxProvider.init(allocator);
    defer fp.deinit();
    var registry = ai.provider.Registry.init(allocator);
    defer registry.deinit();
    try registry.register("faux", fp.provider(), null);

    var ca = AgentSession.init(allocator, .{
        .model = faux.fauxModel(),
        .api_key = "test-key",
        .cwd = "/tmp/zi-test",
        .resource_loader = createTestResourceLoaderWithAgentDir(allocator, "/tmp/zi-test", agent_dir),
        .registry = &registry,
        .no_session = true,
    });
    defer ca.deinit();

    try testing.expect(std.mem.indexOf(u8, ca.agent.state.system_prompt, "Winning read snippet") != null);
    try testing.expect(std.mem.indexOf(u8, ca.agent.state.system_prompt, "Winning read guideline") != null);
    try testing.expect(std.mem.indexOf(u8, ca.agent.state.system_prompt, "Read file contents") == null);
    try testing.expect(std.mem.indexOf(u8, ca.agent.state.system_prompt, "Use read to examine files instead of cat or sed.") == null);
}

// pi-mono test-harness.test.ts: "simple text response"
test "AgentSession: simple text response" {
    // Use arena — SessionWriter allocates internally with no deinit
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fp = faux.FauxProvider.init(allocator);
    const content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("hello world")};
    const msg = faux.fauxAssistantMessage(allocator, &content, .stop);
    fp.setResponses(&.{msg});

    var registry = ai.provider.Registry.init(allocator);
    const prov = fp.provider();
    try registry.register("faux", prov, null);

    var collector = EventCollector.init(allocator);
    var ca = createTestAgentSession(allocator, &fp, &registry, &collector);
    defer ca.deinit();

    try ca.run("hi");

    try testing.expectEqual(@as(usize, 1), fp.call_count);
    try testing.expectEqual(@as(usize, 2), ca.agent.state.messages.len);
    try testing.expect(ca.agent.state.messages[0] == .user);
    try testing.expect(ca.agent.state.messages[1] == .assistant);

    const assistant = ca.agent.state.messages[1].assistant;
    try testing.expectEqual(@as(usize, 1), assistant.content.len);
    switch (assistant.content[0]) {
        .text => |t| try testing.expectEqualStrings("hello world", t.text),
        else => return error.ExpectedTextBlock,
    }
}

// pi-mono test-harness.test.ts: "error response"
test "AgentSession: error response sets stop_reason" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fp = faux.FauxProvider.init(allocator);
    const err_msg = faux.fauxAssistantMessage(allocator, &.{}, .@"error");
    fp.setResponses(&.{err_msg});

    var registry = ai.provider.Registry.init(allocator);
    try registry.register("faux", fp.provider(), null);

    var collector = EventCollector.init(allocator);
    var ca = createTestAgentSession(allocator, &fp, &registry, &collector);
    defer ca.deinit();

    try ca.run("hi");

    try testing.expectEqual(@as(usize, 1), fp.call_count);
    try testing.expectEqual(@as(usize, 2), ca.agent.state.messages.len);
    const assistant = ca.agent.state.messages[1].assistant;
    try testing.expectEqual(ai.protocol.StopReason.@"error", assistant.stop_reason);
}

// pi-mono test-harness.test.ts: "event capture"
test "AgentSession: events emitted in correct order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fp = faux.FauxProvider.init(allocator);
    const content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("hi")};
    const msg = faux.fauxAssistantMessage(allocator, &content, .stop);
    fp.setResponses(&.{msg});

    var registry = ai.provider.Registry.init(allocator);
    try registry.register("faux", fp.provider(), null);

    var collector = EventCollector.init(allocator);
    var ca = createTestAgentSession(allocator, &fp, &registry, &collector);
    defer ca.deinit();

    try ca.run("hello");

    // Should have: agent_start, turn_start, message_start(user), message_end(user),
    // message_start(assistant-stream), message_update*, message_end(assistant),
    // turn_end, agent_end
    try testing.expect(collector.countType(.agent_start) >= 1);
    try testing.expect(collector.countType(.agent_end) >= 1);
    try testing.expect(collector.countType(.message_end) >= 2); // user + assistant
    try testing.expect(collector.countType(.turn_end) >= 1);
}

// pi-mono test-harness.test.ts: "response sequence"
test "AgentSession: response sequence across multiple prompts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fp = faux.FauxProvider.init(allocator);
    const c1 = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("first")};
    const c2 = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("second")};
    fp.setResponses(&.{
        faux.fauxAssistantMessage(allocator, &c1, .stop),
        faux.fauxAssistantMessage(allocator, &c2, .stop),
    });

    var registry = ai.provider.Registry.init(allocator);
    try registry.register("faux", fp.provider(), null);

    var collector = EventCollector.init(allocator);
    var ca = createTestAgentSession(allocator, &fp, &registry, &collector);
    defer ca.deinit();

    try ca.run("a");
    try ca.run("b");

    try testing.expectEqual(@as(usize, 2), fp.call_count);
    try testing.expectEqual(@as(usize, 4), ca.agent.state.messages.len);
    // user, assistant("first"), user, assistant("second")
    const a1 = ca.agent.state.messages[1].assistant;
    switch (a1.content[0]) {
        .text => |t| try testing.expectEqualStrings("first", t.text),
        else => return error.ExpectedText,
    }
    const a2 = ca.agent.state.messages[3].assistant;
    switch (a2.content[0]) {
        .text => |t| try testing.expectEqualStrings("second", t.text),
        else => return error.ExpectedText,
    }
}

// session persistence: prompt → JSONL written → read back → context matches
test "AgentSession: session persistence round-trip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fp = faux.FauxProvider.init(allocator);
    const content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("persisted response")};
    fp.setResponses(&.{faux.fauxAssistantMessage(allocator, &content, .stop)});

    var registry = ai.provider.Registry.init(allocator);
    try registry.register("faux", fp.provider(), null);

    var collector = EventCollector.init(allocator);
    var ca = createTestAgentSession(allocator, &fp, &registry, &collector);
    defer ca.deinit();

    try ca.run("persist me");

    // Session should have been flushed (assistant message triggers flush)
    try testing.expect(ca.sessionFlushed());
    const session_file = ca.getSessionFile();

    // Read back the session file
    var loaded = try openSession(allocator, session_file);
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 2), loaded.messages.len);

    // First message: user
    try testing.expect(loaded.messages[0] == .user);
    switch (loaded.messages[0].user.content) {
        .text => |t| try testing.expectEqualStrings("persist me", t),
        .blocks => |b| {
            try testing.expectEqual(@as(usize, 1), b.len);
            try testing.expectEqualStrings("persist me", b[0].text.text);
        },
    }

    // Second message: assistant with correct text
    try testing.expect(loaded.messages[1] == .assistant);
    const a = loaded.messages[1].assistant;
    try testing.expectEqual(@as(usize, 1), a.content.len);
    switch (a.content[0]) {
        .text => |t| try testing.expectEqualStrings("persisted response", t.text),
        else => return error.ExpectedTextBlock,
    }

    // Clean up the session file
    std.fs.deleteFileAbsolute(session_file) catch {};
}

// tool call round-trip: faux returns tool_call → tool executes → faux called again
test "AgentSession: tool call triggers execution and second LLM call" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fp = faux.FauxProvider.init(allocator);

    // First response: tool call
    const tc_content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{
        faux.fauxToolCall("echo", "tc-1", .null),
    };
    // Second response: text after tool result
    const text_content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("done after tool")};
    fp.setResponses(&.{
        faux.fauxAssistantMessage(allocator, &tc_content, .toolUse),
        faux.fauxAssistantMessage(allocator, &text_content, .stop),
    });

    var registry = ai.provider.Registry.init(allocator);
    try registry.register("faux", fp.provider(), null);

    // Simple echo tool
    const echo_tool = tool_def.ToolDefinition{
        .name = "echo",
        .description = "echo",
        .label = "echo",
        .parameters = .null,
        .impl = .{ .builtin = .{ .execute = &struct {
            fn exec(_: ?*anyopaque, alloc: std.mem.Allocator, _: []const u8, _: std.json.Value, _: protocol.AbortSignal, _: ?protocol.AgentToolUpdateCallback, _: ?*anyopaque) protocol.AgentToolResult {
                const c = alloc.alloc(protocol.AgentToolResult.ContentBlock, 1) catch return .{ .content = &.{} };
                c[0] = .{ .text = .{ .text = "echoed" } };
                return .{ .content = c };
            }
        }.exec } },
        .source = .{ .kind = "test", .id = "echo" },
    };
    const tools = [_]tool_def.ToolDefinition{echo_tool};

    var collector = EventCollector.init(allocator);
    var ca = AgentSession.init(allocator, .{
        .model = faux.fauxModel(),
        .api_key = "test-key",
        .cwd = "/tmp/zi-test",
        .resource_loader = createTestResourceLoader(allocator, "/tmp/zi-test"),
        .registry = &registry,
        .tools = &tools,
        .event_handler = .{ .func = &EventCollector.callback, .ctx = @ptrCast(&collector) },
    });
    defer ca.deinit();

    try ca.run("use the tool");

    // Faux called twice: once for tool call, once after tool result
    try testing.expectEqual(@as(usize, 2), fp.call_count);

    // Messages: user, assistant(tool_call), tool_result, assistant(text)
    try testing.expectEqual(@as(usize, 4), ca.agent.state.messages.len);
    try testing.expect(ca.agent.state.messages[0] == .user);
    try testing.expect(ca.agent.state.messages[1] == .assistant);
    try testing.expect(ca.agent.state.messages[2] == .tool_result);
    try testing.expect(ca.agent.state.messages[3] == .assistant);

    // Verify tool result content
    const tr = ca.agent.state.messages[2].tool_result;
    try testing.expectEqualStrings("echo", tr.tool_name);
    try testing.expectEqual(@as(usize, 1), tr.content.len);

    // Verify tool_execution events fired
    try testing.expect(collector.countType(.tool_execution_start) >= 1);
    try testing.expect(collector.countType(.tool_execution_end) >= 1);
}

test "AgentSession: replaceSessionStore rebinds resumed session ids for agent and builtins" {
    const allocator = testing.allocator;

    const makeStore = struct {
        fn make(alloc: std.mem.Allocator, session_id: []const u8) SessionStore {
            return .{
                .allocator = alloc,
                .writer = session_mod.writer.SessionWriter.initContinue(
                    alloc,
                    "",
                    alloc.dupe(u8, session_id) catch @panic("OOM"),
                    null,
                ),
                .cache_arena = null,
                .cached_entries = null,
                .cached_header = null,
            };
        }
    }.make;

    var registry = ai.provider.Registry.init(allocator);
    defer registry.deinit();

    var ca = AgentSession.init(allocator, .{
        .model = faux.fauxModel(),
        .cwd = "/tmp/zi-test",
        .resource_loader = createTestResourceLoader(allocator, "/tmp/zi-test"),
        .registry = &registry,
        .session_store = makeStore(allocator, "session-one"),
    });
    defer ca.deinit();

    try testing.expect(ca._builtin_ctx != null);
    try testing.expect(ca.agent.session_id != null);
    try testing.expectEqualStrings("session-one", ca.agent.session_id.?);
    try testing.expect(ca.agent.session_id.?.ptr != ca.session_store.sessionId().ptr);
    try testing.expectEqualStrings("session-one", ca._builtin_ctx.?.session_id);
    try testing.expect(ca._builtin_ctx.?.session_id.ptr == ca.session_store.sessionId().ptr);

    try ca.replaceSessionStore(makeStore(allocator, "session-two"));

    try testing.expect(ca.agent.session_id != null);
    try testing.expectEqualStrings("session-two", ca.agent.session_id.?);
    try testing.expect(ca.agent.session_id.?.ptr != ca.session_store.sessionId().ptr);
    try testing.expectEqualStrings("session-two", ca._builtin_ctx.?.session_id);
    try testing.expect(ca._builtin_ctx.?.session_id.ptr == ca.session_store.sessionId().ptr);
}

test "AgentSession: startNewSession resets transcript and seeds model plus thinking defaults" {
    const allocator = testing.allocator;

    var registry = ai.provider.Registry.init(allocator);
    defer registry.deinit();

    var ca = AgentSession.init(allocator, .{
        .model = faux.fauxModel(),
        .cwd = "/tmp/zi-test",
        .resource_loader = createTestResourceLoader(allocator, "/tmp/zi-test"),
        .registry = &registry,
        .thinking_level = .medium,
    });
    defer ca.deinit();

    const existing = [_]protocol.AgentMessage{
        .{ .user = .{ .content = .{ .text = "hello" }, .timestamp = 1 } },
    };
    ca.agent.loadMessages(&existing);
    const old_session_id = try allocator.dupe(u8, ca.session_store.sessionId());
    defer allocator.free(old_session_id);

    try ca.startNewSession();

    try testing.expect(!std.mem.eql(u8, old_session_id, ca.session_store.sessionId()));
    try testing.expectEqual(@as(usize, 0), ca.agent.state.messages.len);
    try testing.expect(ca.agent.session_id != null);
    try testing.expectEqualStrings(ca.session_store.sessionId(), ca.agent.session_id.?);
    try testing.expect(ca._builtin_ctx != null);
    try testing.expectEqualStrings(ca.session_store.sessionId(), ca._builtin_ctx.?.session_id);

    const buffered = ca.session_store.writer.buffered_entries.items;
    try testing.expectEqual(@as(usize, 3), buffered.len);
    try testing.expect(buffered[0] == .header);
    try testing.expect(buffered[1] == .entry);
    try testing.expect(buffered[1].entry.entry == .model_change);
    try testing.expectEqualStrings("faux", buffered[1].entry.entry.model_change.provider);
    try testing.expectEqualStrings(faux.fauxModel().id, buffered[1].entry.entry.model_change.model_id);
    try testing.expect(buffered[2] == .entry);
    try testing.expect(buffered[2].entry.entry == .thinking_level_change);
    try testing.expectEqualStrings("medium", buffered[2].entry.entry.thinking_level_change.thinking_level);
}

test "AgentSession: startNewSession preserves ephemeral mode" {
    const allocator = testing.allocator;

    var registry = ai.provider.Registry.init(allocator);
    defer registry.deinit();

    var ca = AgentSession.init(allocator, .{
        .model = faux.fauxModel(),
        .cwd = "/tmp/zi-test",
        .resource_loader = createTestResourceLoader(allocator, "/tmp/zi-test"),
        .registry = &registry,
        .session_store = SessionStore.createEphemeral(allocator),
        .thinking_level = .low,
    });
    defer ca.deinit();

    try testing.expect(!ca.session_store.writer.persist);
    try ca.startNewSession();

    try testing.expect(!ca.session_store.writer.persist);
    try testing.expectEqual(@as(usize, 0), ca.session_store.sessionFile().len);
    try testing.expectEqual(@as(usize, 2), ca.session_store.writer.buffered_entries.items.len);
    try testing.expect(ca.session_store.writer.buffered_entries.items[0].entry.entry == .model_change);
    try testing.expect(ca.session_store.writer.buffered_entries.items[1].entry.entry == .thinking_level_change);
}

// --continue round-trip: write session → load → continue → verify context sent to provider
test "AgentSession: continue sends restored context to provider" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Phase 1: create a session with one exchange
    var fp1 = faux.FauxProvider.init(allocator);
    const c1 = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("first response")};
    fp1.setResponses(&.{faux.fauxAssistantMessage(allocator, &c1, .stop)});

    var reg1 = ai.provider.Registry.init(allocator);
    try reg1.register("faux", fp1.provider(), null);

    var col1 = EventCollector.init(allocator);
    var ca1 = AgentSession.init(allocator, .{
        .model = faux.fauxModel(),
        .api_key = "test-key",
        .cwd = "/tmp/zi-test",
        .resource_loader = createTestResourceLoader(allocator, "/tmp/zi-test"),
        .registry = &reg1,
        .tools = &.{},
        .event_handler = .{ .func = &EventCollector.callback, .ctx = @ptrCast(&col1) },
    });
    defer ca1.deinit();

    try ca1.run("hello");
    try testing.expect(ca1.sessionFlushed());
    const session_file = ca1.getSessionFile();

    // Phase 2: load the session and continue with a new user message
    var loaded = try openSession(allocator, session_file);
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 2), loaded.messages.len);

    var fp2 = faux.FauxProvider.init(allocator);
    const c2 = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("continued response")};
    fp2.setResponses(&.{faux.fauxAssistantMessage(allocator, &c2, .stop)});

    var reg2 = ai.provider.Registry.init(allocator);
    try reg2.register("faux", fp2.provider(), null);

    var col2 = EventCollector.init(allocator);
    // Seed with loaded messages + a new user prompt
    const new_user = protocol.AgentMessage{ .user = .{
        .content = .{ .text = "follow up" },
        .timestamp = std.time.milliTimestamp(),
    } };
    var all_messages: std.ArrayListUnmanaged(protocol.AgentMessage) = .empty;
    try all_messages.appendSlice(allocator, loaded.messages);
    try all_messages.append(allocator, new_user);

    var ca2 = AgentSession.init(allocator, .{
        .model = faux.fauxModel(),
        .api_key = "test-key",
        .cwd = "/tmp/zi-test",
        .resource_loader = createTestResourceLoader(allocator, "/tmp/zi-test"),
        .registry = &reg2,
        .tools = &.{},
        .event_handler = .{ .func = &EventCollector.callback, .ctx = @ptrCast(&col2) },
        .initial_messages = all_messages.items,
        .session_store = loaded.takeStore(),
    });
    defer ca2.deinit();

    // Continue — should send the full context to the provider
    try ca2.continueSession();

    try testing.expectEqual(@as(usize, 1), fp2.call_count);

    // Provider should have received context with restored messages
    try testing.expectEqual(@as(usize, 1), fp2.captured_contexts.items.len);
    const ctx = fp2.captured_contexts.items[0];
    // Context should have at least 3 LLM messages: user("hello"), assistant("first response"), user("follow up")
    try testing.expect(ctx.messages.len >= 3);

    // Clean up
    std.fs.deleteFileAbsolute(session_file) catch {};
}

// convertToLlm through the loop: compaction_summary in initial state → provider receives wrapped text
test "AgentSession: compaction_summary converted to user message for provider" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fp = faux.FauxProvider.init(allocator);
    const c = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("ok")};
    fp.setResponses(&.{faux.fauxAssistantMessage(allocator, &c, .stop)});

    var registry = ai.provider.Registry.init(allocator);
    try registry.register("faux", fp.provider(), null);

    var collector = EventCollector.init(allocator);

    // Seed with compaction_summary + user message
    const initial = [_]protocol.AgentMessage{
        .{ .compaction_summary = .{ .summary = "Previous work done", .tokens_before = 5000, .timestamp = 1 } },
        .{ .user = .{ .content = .{ .text = "next question" }, .timestamp = 2 } },
    };

    var ca = AgentSession.init(allocator, .{
        .model = faux.fauxModel(),
        .api_key = "test-key",
        .cwd = "/tmp/zi-test",
        .resource_loader = createTestResourceLoader(allocator, "/tmp/zi-test"),
        .registry = &registry,
        .tools = &.{},
        .event_handler = .{ .func = &EventCollector.callback, .ctx = @ptrCast(&collector) },
        .initial_messages = &initial,
    });
    defer ca.deinit();

    // Continue from the seeded state (last message is user, so continue works)
    try ca.continueSession();

    try testing.expectEqual(@as(usize, 1), fp.call_count);
    try testing.expectEqual(@as(usize, 1), fp.captured_contexts.items.len);

    const ctx = fp.captured_contexts.items[0];
    // convertToLlm should have converted compaction_summary → user message with <summary> tags
    // So provider sees: user(compaction), user("next question") = 2 messages
    try testing.expectEqual(@as(usize, 2), ctx.messages.len);
    try testing.expect(ctx.messages[0] == .user);
    try testing.expect(ctx.messages[1] == .user);

    // First message should contain the summary wrapped in tags
    const first_user = ctx.messages[0].user;
    switch (first_user.content) {
        .blocks => |blocks| {
            try testing.expect(blocks.len > 0);
            const text = blocks[0].text.text;
            try testing.expect(std.mem.indexOf(u8, text, "<summary>") != null);
            try testing.expect(std.mem.indexOf(u8, text, "Previous work done") != null);
        },
        .text => |t| {
            try testing.expect(std.mem.indexOf(u8, t, "<summary>") != null);
        },
    }
}

// pi-mono test-harness.test.ts: "context capture"
test "AgentSession: context capture — provider receives user message" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fp = faux.FauxProvider.init(allocator);
    const c = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("reply")};
    fp.setResponses(&.{faux.fauxAssistantMessage(allocator, &c, .stop)});

    var registry = ai.provider.Registry.init(allocator);
    try registry.register("faux", fp.provider(), null);

    var collector = EventCollector.init(allocator);
    var ca = createTestAgentSession(allocator, &fp, &registry, &collector);
    defer ca.deinit();

    try ca.run("my question");

    try testing.expectEqual(@as(usize, 1), fp.captured_contexts.items.len);
    const ctx = fp.captured_contexts.items[0];
    // Should contain user message
    var found_user = false;
    for (ctx.messages) |m| {
        if (m == .user) {
            found_user = true;
            break;
        }
    }
    try testing.expect(found_user);
}

// pi-mono test-harness.test.ts: "streams text deltas"
test "AgentSession: text deltas reconstruct full response" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fp = faux.FauxProvider.init(allocator);
    const c = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("hello world")};
    fp.setResponses(&.{faux.fauxAssistantMessage(allocator, &c, .stop)});

    var registry = ai.provider.Registry.init(allocator);
    try registry.register("faux", fp.provider(), null);

    var collector = EventCollector.init(allocator);
    var ca = createTestAgentSession(allocator, &fp, &registry, &collector);
    defer ca.deinit();

    try ca.run("hi");

    const deltas = collector.getTextDeltas();
    try testing.expect(deltas.len > 0);

    // Reconstruct — faux sends full text as one delta
    var total_len: usize = 0;
    for (deltas) |d| total_len += d.len;
    var buf = try allocator.alloc(u8, total_len);
    var pos: usize = 0;
    for (deltas) |d| {
        @memcpy(buf[pos..][0..d.len], d);
        pos += d.len;
    }
    try testing.expectEqualStrings("hello world", buf);
}

// pi-mono test-harness.test.ts: "streams thinking deltas"
test "AgentSession: thinking events emitted for thinking content" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fp = faux.FauxProvider.init(allocator);
    const c = [_]ai.protocol.AssistantMessage.AssistantContentBlock{
        .{ .thinking = .{ .thinking = "let me think" } },
        faux.fauxText("answer"),
    };
    fp.setResponses(&.{faux.fauxAssistantMessage(allocator, &c, .stop)});

    var registry = ai.provider.Registry.init(allocator);
    try registry.register("faux", fp.provider(), null);

    var collector = EventCollector.init(allocator);
    var ca = createTestAgentSession(allocator, &fp, &registry, &collector);
    defer ca.deinit();

    try ca.run("hi");

    // Check for thinking events in message_update
    var thinking_starts: usize = 0;
    var thinking_deltas: usize = 0;
    var thinking_ends: usize = 0;
    for (collector.events.items) |e| {
        if (e == .message_update) {
            const ame = e.message_update.assistant_message_event;
            if (ame == .thinking_start) thinking_starts += 1;
            if (ame == .thinking_delta) thinking_deltas += 1;
            if (ame == .thinking_end) thinking_ends += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), thinking_starts);
    try testing.expect(thinking_deltas > 0);
    try testing.expectEqual(@as(usize, 1), thinking_ends);
}

test "resumed session context is sent to LLM" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Simulate a prior conversation (user + assistant)
    const prior_assistant_content = allocator.alloc(ai.protocol.AssistantMessage.AssistantContentBlock, 1) catch unreachable;
    prior_assistant_content[0] = faux.fauxText("I explained X");

    const prior_messages = &[_]protocol.AgentMessage{
        .{ .user = .{ .content = .{ .text = "explain X" }, .timestamp = 1 } },
        .{ .assistant = .{
            .content = prior_assistant_content,
            .api = .{ .custom = "faux" },
            .provider = .{ .custom = "faux" },
            .model = "faux-model",
            .usage = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total_tokens = 0, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 } },
            .stop_reason = .stop,
            .timestamp = 2,
        } },
    };

    var fp = faux.FauxProvider.init(allocator);
    const reply_content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("follow-up answer")};
    fp.setResponses(&.{faux.fauxAssistantMessage(allocator, &reply_content, .stop)});

    var registry = ai.provider.Registry.init(allocator);
    try registry.register("faux", fp.provider(), null);

    var collector = EventCollector.init(allocator);
    var ca = createTestAgentSession(allocator, &fp, &registry, &collector);
    defer ca.deinit();

    // Simulate /resume: load prior messages into agent
    ca.agent.loadMessages(prior_messages);
    try testing.expectEqual(@as(usize, 2), ca.agent.state.messages.len);

    // Send a new prompt (the "follow-up" after resume)
    try ca.run("now explain Y");

    // The LLM should have received the full context: prior user + prior assistant + new user
    try testing.expectEqual(@as(usize, 1), fp.call_count);
    const ctx = fp.captured_contexts.items[0];
    // convertToLlm maps AgentMessage → LLM Message; prior user + prior assistant + new user = 3
    try testing.expectEqual(@as(usize, 3), ctx.messages.len);
    try testing.expect(ctx.messages[0] == .user);
    try testing.expect(ctx.messages[1] == .assistant);
    try testing.expect(ctx.messages[2] == .user);
}

/// Context passed to extension tool `execute` functions and event handlers.
///
/// v1 shape — read-only session access + basic actions. Populated by the
/// ExtensionRunner when dispatching to a Lua handler (or a builtin tool
/// with the same signature). `signal` is non-null only inside an active
/// turn; `ui` is non-null only when the runner was bound with a TUI
/// context (interactive mode).
///
/// Ownership: the context is stack-allocated by the runner per call and
/// never escapes the handler. All pointers are borrowed.
pub const ExtensionContext = struct {
    /// Opaque back-pointer to the owning AgentSession. Handlers that need
    /// session state go through action methods on the runtime, not this
    /// pointer — the field exists so action methods can resolve it
    /// without another parameter.
    session: *anyopaque,

    /// Current working directory for this turn.
    cwd: []const u8,

    /// True when bound in interactive mode. Gates access to `ui`.
    has_ui: bool,

    /// Abort signal for the current in-flight operation, or null when idle.
    /// Yieldable host functions (zi.spawn, ctx.ui.*) check this to
    /// short-circuit into a cancelled result instead of blocking.
    signal: ?*anyopaque = null,

    /// UI primitive bag, non-null only when `has_ui`. Opaque here to
    /// avoid a cycle between tui/ and extensions/; the real type is
    /// bound by the runner in interactive mode.
    ui: ?*anyopaque = null,
};

/// Context passed to slash command handlers (v2). Extends ExtensionContext
/// with session-control methods that are only safe inside a user-initiated
/// command — never inside a tool execute() or an event observer, because
/// those run mid-turn and can't legally fork / switch / reload.
///
/// The internal seam exists from v1: ExtensionRuntime.Bound.command_actions
/// is typed as *anyopaque and stays null until the command registry gains
/// entries in v2. Reserving the type here means v2 is pure wiring, not a
/// struct reshuffle.
///
/// Matches pi-mono's ExtensionCommandContext:
///   .references/pi-mono/packages/coding-agent/src/core/extensions/runtime.ts
pub const ExtensionCommandContext = struct {
    /// Embedded base context — every command context IS an extension
    /// context with extra capabilities.
    base: ExtensionContext,

    // v2 action method seats — left as anyopaque function pointers so
    // the table can be populated without importing the concrete types
    // (AgentSession, SessionStore, ExtensionRunner) that would create
    // circular deps. The ExtensionRunner binds real fn pointers into
    // these slots in bindRuntime() once the command registry is active.
    //
    // v1: all null. v2: runner populates before dispatching commands.

    wait_for_idle: ?*const fn (ctx: *anyopaque) anyerror!void = null,
    new_session: ?*const fn (ctx: *anyopaque, opts: *const anyopaque) anyerror!void = null,
    fork: ?*const fn (ctx: *anyopaque, entry_id: []const u8) anyerror!void = null,
    navigate_tree: ?*const fn (ctx: *anyopaque, target_id: []const u8) anyerror!void = null,
    switch_session: ?*const fn (ctx: *anyopaque, path: []const u8) anyerror!void = null,
    reload: ?*const fn (ctx: *anyopaque) anyerror!void = null,
};
