const std = @import("std");
const ai = @import("../ai/root.zig");
const agent_mod = @import("../agent3/root.zig");
const agent_impl = @import("../agent3/agent.zig");
const control_mod = @import("../agent3/control.zig");
const session_runtime = @import("session/root.zig");
const session_core = @import("../session/root.zig");
const tool_def = @import("tools/definition.zig");
const builtin_util = @import("tools/util.zig");
const resources = @import("resources/root.zig");
const auth_storage_mod = @import("auth/storage.zig");
const settings_manager_mod = @import("settings/manager.zig");
const settings_types_mod = @import("settings/types.zig");
const model_registry_mod = @import("model_registry.zig");
const session_bootstrap = @import("session_bootstrap.zig");
const extension_runner_mod = @import("extensions/runner.zig");
const ai_complete_worker_mod = @import("extensions/ai_complete_worker.zig");
const ai_completion = @import("ai_completion.zig");
const lua_runtime = @import("extensions/lua_runtime.zig");
const event_bridge = @import("extensions/event_bridge.zig");
const extension_ui = @import("extensions/ui.zig");
const session_event_mod = @import("session_event.zig");
const request_mod = @import("request.zig");
const resolve_mod = @import("resolve.zig");

const protocol = agent_mod.protocol;
const Agent = agent_mod.Agent;
const SubscriptionToken = agent_impl.SubscriptionToken;
pub const SessionStore = session_runtime.store.SessionStore;
pub const ExtensionRunner = extension_runner_mod.ExtensionRunner;
pub const ExtensionRunnerRef = extension_runner_mod.ExtensionRunnerRef;
pub const ContextUsage = session_core.context_usage.ContextUsage;
const session_proto = session_core.protocol;

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
    event_handler: ?RawEventHandler,
    agent_event_listeners: std.ArrayList(RawEventHandler),
    session_event_listeners: std.ArrayList(SessionEventHandler),
    _subscription_token: ?SubscriptionToken,
    _stream_closure: *StreamClosure,
    auth_storage: ?*auth_storage_mod.AuthStorage,
    settings_manager: ?*settings_manager_mod.SettingsManager = null,
    resource_loader: resources.ResourceLoader,
    /// Borrowed visible-model registry. Lifetime stays caller-owned,
    /// but AgentSession is the rebuild owner on the agent thread. Used
    /// for model resolution, restore, and TUI snapshot publication.
    model_registry: ?*model_registry_mod.ModelRegistry = null,

    /// Owned ExtensionRunner — current generation. Populated by the
    /// sdk factory in Phase A3+; nil in v1 bootstraps until the runner
    /// construction path is wired. Reload replaces this pointer
    /// atomically with a new generation (see `docs/extensions.md`). When set,
    /// `deinit` takes it down before
    /// the agent so any final event observers can still fire against
    /// a live session.
    _extension_runner: ?*ExtensionRunner = null,
    _extension_runner_ref: *ExtensionRunnerRef,

    /// Owned Lua state, paired 1:1 with `_extension_runner`. The
    /// runner BORROWS this — see `extensions/runner.zig` field doc.
    /// AgentSession owns the lifetime so the SDK bootstrap order
    /// (state → runner → install zi.* → attach) lines up with the
    /// teardown order (unsubscribe → runner.deinit → state.deinit).
    /// Both fields are nil when Lua init fails; the agent still runs.
    _extension_lua_state: ?*lua_runtime.LuaState = null,
    pending_extension_report: ?extension_ui.Report = null,
    pending_extension_prompts: std.ArrayListUnmanaged(extension_ui.PromptRequest) = .empty,
    pending_extension_ui_publications: std.ArrayListUnmanaged(extension_ui.UiPublication) = .empty,
    pending_extension_editor_actions: std.ArrayListUnmanaged(extension_ui.EditorAction) = .empty,
    pending_tool_projection_refresh: bool = false,

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
    _owned_system_prompt: []const u8 = "",
    _builtin_ctx: ?*builtin_util.BuiltinCtx = null,
    /// Mirrors pi-mono's post-compaction semantics without re-reading the
    /// session file on every status render. True means the latest compaction
    /// on the active branch has not yet been followed by a successful
    /// assistant response with non-zero usage.
    context_usage_unknown_after_compaction: bool = false,

    /// Compaction extension seam (zi-v3j.10.7). Extensions register a
    /// pair of function pointers here to observe preparation, cancel,
    /// provide alternate compaction content, and observe the persisted
    /// result. Nil when no extension participates, in which case the
    /// executor runs zi's default summarization pass.
    compaction_hooks: @import("session/compaction_hooks.zig").CompactionHooks = .{},

    pub const RawEventHandler = struct {
        func: *const fn (event: protocol.AgentEvent, ctx: ?*anyopaque) void,
        ctx: ?*anyopaque = null,
    };

    pub const SessionEventHandler = struct {
        func: *const fn (event: session_event_mod.SessionEvent, ctx: ?*anyopaque) void,
        ctx: ?*anyopaque = null,
    };

    pub const EventHandler = RawEventHandler;
    pub const SessionEvent = session_event_mod.SessionEvent;
    pub const AgentEventSubscriptionToken = struct {
        index: usize,
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

    pub const PreparedDeps = session_bootstrap.PreparedDeps;
    pub const StreamClosure = session_bootstrap.StreamClosure;
    pub const ExtensionRuntimeBundle = session_bootstrap.ExtensionRuntimeBundle;

    pub const Options = struct {
        model: ai.protocol.Model,
        prepared: PreparedDeps,
        event_handler: ?RawEventHandler = null,
        auth_storage: ?*auth_storage_mod.AuthStorage = null,
        settings_manager: ?*settings_manager_mod.SettingsManager = null,
        model_registry: ?*model_registry_mod.ModelRegistry = null,
        initial_messages: []const protocol.AgentMessage = &.{},
        thinking_level: ?protocol.ThinkingLevel = null,
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) AgentSession {
        var prepared = options.prepared;
        const stream_hook = protocol.StreamHook{
            .func = &StreamClosure.streamFn,
            .ctx = @ptrCast(prepared.stream_closure),
        };

        const before_tool_hook: ?protocol.BeforeToolCallHook = .{
            .func = &beforeToolCallFromRunnerRef,
            .ctx = @ptrCast(prepared.extension_runner_ref),
        };
        const after_tool_hook: ?protocol.AfterToolCallHook = .{
            .func = &afterToolCallFromRunnerRef,
            .ctx = @ptrCast(prepared.extension_runner_ref),
        };

        const agent = Agent.init(allocator, .{
            .system_prompt = prepared.system_prompt,
            .model = options.model,
            .tools = prepared.tools,
            .messages = options.initial_messages,
            .thinking_level = options.thinking_level orelse .off,
            .convert_to_llm = .{ .func = &convertToLlm, .ctx = null },
            .stream_fn = stream_hook,
            .session_id = prepared.session_store.sessionId(),
            .get_api_key = null,
            .before_tool_call = before_tool_hook,
            .after_tool_call = after_tool_hook,
        }) catch @panic("OOM");
        const context_usage_unknown_after_compaction = prepared.session_store.contextUsageUnknownAfterCompaction(allocator);

        return .{
            .agent = agent,
            .session_store = prepared.session_store,
            .allocator = allocator,
            .tools = prepared.tools,
            .event_handler = options.event_handler,
            .agent_event_listeners = .empty,
            .session_event_listeners = .empty,
            ._subscription_token = null,
            ._stream_closure = prepared.stream_closure,
            .auth_storage = options.auth_storage,
            .settings_manager = options.settings_manager,
            .resource_loader = prepared.resource_loader,
            .model_registry = options.model_registry,
            ._owned_provider_bundle = prepared.owned_provider_bundle,
            ._owned_system_prompt = prepared.system_prompt,
            ._builtin_ctx = prepared.builtin_ctx,
            .context_usage_unknown_after_compaction = context_usage_unknown_after_compaction,
            ._extension_runner = prepared.extension_runner,
            ._extension_runner_ref = prepared.extension_runner_ref,
            ._extension_lua_state = prepared.extension_lua_state,
        };
    }

    /// Test-only convenience wrapper around the shared bootstrap path.
    ///
    /// Production construction flows through `sdk.createAgentSession`.
    /// In-file tests call the same bootstrap assembler via
    /// `session_bootstrap.prepareSessionDeps`, then hand the prepared
    /// deps to `AgentSession.init`.
    const TestInitOptions = struct {
        model: ai.protocol.Model,
        api_key: []const u8 = "",
        cwd: []const u8,
        resource_loader: resources.ResourceLoader,
        max_tokens: ?u64 = 4096,
        tools: ?[]const tool_def.ToolDefinition = null,
        registry: ?*ai.provider.Registry = null,
        event_handler: ?RawEventHandler = null,
        auth_storage: ?*auth_storage_mod.AuthStorage = null,
        settings_manager: ?*settings_manager_mod.SettingsManager = null,
        model_registry: ?*model_registry_mod.ModelRegistry = null,
        initial_messages: []const protocol.AgentMessage = &.{},
        thinking_level: ?protocol.ThinkingLevel = null,
        session_store: ?SessionStore = null,
        no_session: bool = false,
        tool_allowlist: ?[]const []const u8 = null,
        agent_dir_override: ?[]const u8 = "/tmp/zi-test-agent-empty",
    };

    pub fn initTestSession(allocator: std.mem.Allocator, options: TestInitOptions) AgentSession {
        const prepared = session_bootstrap.prepareSessionDeps(allocator, .{
            .api_key = options.api_key,
            .cwd = options.cwd,
            .resource_loader = options.resource_loader,
            .max_tokens = options.max_tokens,
            .tools = options.tools,
            .registry = options.registry,
            .auth_storage = options.auth_storage,
            .settings_manager = options.settings_manager,
            .session_store = options.session_store,
            .no_session = options.no_session,
            .tool_allowlist = options.tool_allowlist,
            .agent_dir_override = options.agent_dir_override,
        }) catch @panic("OOM");
        return AgentSession.init(allocator, .{
            .model = options.model,
            .prepared = prepared,
            .event_handler = options.event_handler,
            .auth_storage = options.auth_storage,
            .settings_manager = options.settings_manager,
            .model_registry = options.model_registry,
            .initial_messages = options.initial_messages,
            .thinking_level = options.thinking_level,
        });
    }

    /// Tear down the extension runner + lua_State on whichever thread
    /// owns the lua_State. This MUST run on the agent thread (the
    /// owner per zi-wub.5/.6) so `lua_close` happens on the bound
    /// thread. Called by the long-lived agent owner loop after
    /// `Interactive.deinit` closes the request inbox (zi-wub.28);
    /// after this runs, `AgentSession.deinit` sees null fields and
    /// skips the blocks.
    ///
    /// Idempotent. Unsubscribes the extension bridge and unbinds the
    /// runtime. Replacement flows snapshot provenance before calling
    /// this so `session_start` payloads remain truthful.
    pub fn deactivateLifecycleOnAgentThread(self: *AgentSession) void {
        self.deactivateLifecycle();
    }

    /// Idempotent. Unsubscribes the extension bridge first so no
    /// in-flight agent event can re-enter the runner mid-teardown,
    /// then explicitly unbinds the runtime before destroy.
    pub fn shutdownLifecycleOnAgentThread(self: *AgentSession) void {
        self.deactivateLifecycleOnAgentThread();
        self.destroyExtensionRuntime();
    }

    /// Canonical session-owned model switch. Owns validation,
    /// in-memory state mutation, session persistence, and thinking-
    /// level reclamp for the new model's capabilities.
    pub fn trySetModel(self: *AgentSession, model: ai.protocol.Model) ModelSwitchResult {
        const registry = self.model_registry orelse return .registry_unavailable;
        if (!registry.hasConfiguredAuth(model)) {
            return .{ .no_auth = model };
        }

        const previous_model = self.agent.modelValue();
        const previous_thinking = self.agent.thinkingLevel();
        const next_thinking = clampThinkingLevelForModel(previous_thinking, model);
        const thinking_changed = next_thinking != previous_thinking;

        self.agent.setModel(model);
        self.agent.setThinkingLevel(next_thinking);
        const provider_str = ai.json_util.providerToString(model.provider);
        self.session_store.appendModelChange(provider_str, model.id);
        if (self.settings_manager) |settings| {
            settings.setDefaultModelAndProvider(provider_str, model.id);
            persistDefaultThinkingLevel(settings, model, next_thinking);
        }
        if (thinking_changed) {
            self.session_store.appendThinkingLevelChange(agentThinkingLevelToString(next_thinking));
        }

        if (self._extension_runner) |runner| {
            if (!ai.models.modelsAreEqual(previous_model, model)) {
                event_bridge.dispatchModelSelect(runner, model, previous_model, "set");
            }
        }

        return .{ .success = .{
            .model = model,
            .thinking_level = next_thinking,
            .thinking_level_changed = thinking_changed,
        } };
    }

    pub fn trySetThinkingLevel(self: *AgentSession, level: protocol.ThinkingLevel) ThinkingLevelChangeResult {
        const effective = clampThinkingLevelForModel(level, self.agent.modelValue());
        const changed = effective != self.agent.thinkingLevel();
        self.agent.setThinkingLevel(effective);
        if (changed) {
            self.session_store.appendThinkingLevelChange(agentThinkingLevelToString(effective));
            if (self.settings_manager) |settings| {
                persistDefaultThinkingLevel(settings, self.agent.modelValue(), effective);
            }
        }
        return .{ .level = effective, .changed = changed };
    }

    pub fn getAvailableThinkingLevelsForModel(model: ai.protocol.Model) []const protocol.ThinkingLevel {
        return if (!model.reasoning)
            &.{.off}
        else if (ai.models.supportsXhigh(model))
            &.{ .off, .minimal, .low, .medium, .high, .xhigh }
        else
            &.{ .off, .minimal, .low, .medium, .high };
    }

    fn clampThinkingLevelForModel(level: protocol.ThinkingLevel, model: ai.protocol.Model) protocol.ThinkingLevel {
        if (!model.reasoning) return .off;
        return switch (level) {
            .xhigh => if (ai.models.supportsXhigh(model)) .xhigh else .high,
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
    /// Contract: this always creates a normal persisted session, even if the
    /// current session was launched with `--no-session`. This matches
    /// pi-mono's startup-only `--no-session` behavior: `/resume` can switch
    /// into a persisted session, and `/new` is not an ephemeral-mode toggle.
    ///
    /// Ownership: agent-thread only. Mutates `session_store` and
    /// `agent.state`, both owned by the agent thread per doctrine.
    pub fn startNewSession(self: *AgentSession) !void {
        var new_store = try SessionStore.createForCwd(self.allocator, self.resource_loader.cwd, self.resource_loader.agent_dir);
        errdefer new_store.deinit();

        // Reset the agent FIRST. If reset fails (OOM allocating the
        // empty SharedCommitted), we avoid the half-applied state of
        // "new session store installed but old conversation retained."
        try self.agent.reset();
        try self.replaceSessionStore(new_store);
        const current_model = self.agent.modelValue();
        self.session_store.appendRuntimeDefaults(
            ai.json_util.providerToString(current_model.provider),
            current_model.id,
            agentThinkingLevelToString(self.agent.thinkingLevel()),
        );
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
        const model = self.agent.modelValue();
        if (model.context_window == 0) return null;

        if (self.context_usage_unknown_after_compaction) {
            return .{
                .tokens = null,
                .context_window = model.context_window,
                .percent = null,
            };
        }

        return contextUsageFromEstimate(model.context_window, session_core.context_usage.estimateContextTokensWithInFlight(
            self.agent.messages(),
            self.agent.inFlightState(),
        ));
    }

    pub fn statusSnapshot(self: *const AgentSession) StatusSnapshot {
        const usage = self.getContextUsage();
        return .{
            .model_provider = ai.json_util.providerToString(self.agent.modelValue().provider),
            .model_id = self.agent.modelValue().id,
            .thinking_level = self.agent.thinkingLevel(),
            .context_tokens = if (usage) |u| u.tokens else null,
            .context_window = if (usage) |u| u.context_window else self.agent.modelValue().context_window,
        };
    }

    fn rebuildVisibleModelCatalogFromActiveProviders(self: *AgentSession) !void {
        const registry = self.model_registry orelse return;
        const current = self.agent.modelValue();
        const provider_name = try self.allocator.dupe(u8, ai.json_util.providerToString(current.provider));
        defer self.allocator.free(provider_name);
        const model_id = try self.allocator.dupe(u8, current.id);
        defer self.allocator.free(model_id);
        const thinking_level = self.agent.thinkingLevel();

        try registry.rebuildFromActiveProviderClaims(self._stream_closure.registry);
        if (registry.findByProviderName(provider_name, model_id)) |refreshed| {
            self.agent.setModel(refreshed);
            self.agent.setThinkingLevel(clampThinkingLevelForModel(thinking_level, refreshed));
        }
        self.emitSessionEvent(.{ .visible_models_changed = {} });
    }

    pub fn noteCompactionApplied(self: *AgentSession) void {
        self.context_usage_unknown_after_compaction = true;
    }

    /// Extension entry point for registering compaction hook callbacks.
    /// Hook functions run on the agent thread, inside the executor's
    /// compaction flow. Callbacks must not block on cross-thread I/O.
    pub fn setCompactionHooks(
        self: *AgentSession,
        hooks: @import("session/compaction_hooks.zig").CompactionHooks,
    ) void {
        self.compaction_hooks = hooks;
    }

    fn refreshContextUsageStateFromStore(self: *AgentSession) void {
        self.context_usage_unknown_after_compaction = self.session_store.contextUsageUnknownAfterCompaction(self.allocator);
    }

    fn noteMessageForContextUsage(self: *AgentSession, message: protocol.AgentMessage) void {
        if (!self.context_usage_unknown_after_compaction) return;
        switch (message) {
            .assistant => |assistant| switch (assistant.stop_reason) {
                .aborted, .@"error" => {},
                else => {
                    if (session_core.context_usage.calculateContextTokens(assistant.usage) > 0) {
                        self.context_usage_unknown_after_compaction = false;
                    }
                },
            },
            else => {},
        }
    }

    fn contextUsageFromEstimate(context_window: u64, estimate: session_core.context_usage.ContextUsageEstimate) ContextUsage {
        return .{
            .tokens = estimate.tokens,
            .context_window = context_window,
            .percent = (@as(f64, @floatFromInt(estimate.tokens)) / @as(f64, @floatFromInt(context_window))) * 100.0,
        };
    }

    pub fn deinit(self: *AgentSession) void {
        // zi-wub.28: in interactive mode the lifecycle teardown may
        // already have run on the agent thread via
        // shutdownLifecycleOnAgentThread() — the helpers are
        // idempotent, so direct/non-interactive callers still use the
        // same path here on whatever thread owns lua.
        self.deactivateLifecycle();
        self.destroyExtensionRuntime();
        self.clearPendingExtensionReport();
        self.clearPendingExtensionPrompts();
        self.clearPendingExtensionRuntimeBundles();
        self.clearPendingExtensionEditorActions();
        self.allocator.destroy(self._stream_closure);
        self.allocator.destroy(self._extension_runner_ref);
        self.agent_event_listeners.deinit(self.allocator);
        self.session_event_listeners.deinit(self.allocator);
        self.agent.deinit();
        self.allocator.free(self.tools);
        if (self._owned_system_prompt.len > 0) {
            self.allocator.free(self._owned_system_prompt);
            self._owned_system_prompt = "";
        }
        self.session_store.deinit();
        self.resource_loader.deinit();
        if (self._builtin_ctx) |ctx| {
            self.allocator.destroy(ctx);
            self._builtin_ctx = null;
        }
        // Provider bundle goes last — the agent's stream closure may
        // still hold references into the registry until agent.deinit
        // returns. Destroying earlier is a use-after-free risk.
        if (self._owned_provider_bundle) |bundle| {
            bundle.deinit();
            self._owned_provider_bundle = null;
        }
    }

    pub fn subscribeAgentEvents(
        self: *AgentSession,
        func: *const fn (event: protocol.AgentEvent, ctx: ?*anyopaque) void,
        ctx: ?*anyopaque,
    ) AgentEventSubscriptionToken {
        const index = self.agent_event_listeners.items.len;
        self.agent_event_listeners.append(self.allocator, .{ .func = func, .ctx = ctx }) catch return .{ .index = std.math.maxInt(usize) };
        return .{ .index = index };
    }

    pub fn unsubscribeAgentEvents(self: *AgentSession, token: AgentEventSubscriptionToken) void {
        if (token.index < self.agent_event_listeners.items.len) {
            _ = self.agent_event_listeners.orderedRemove(token.index);
        }
    }

    pub fn subscribeEvents(
        self: *AgentSession,
        func: *const fn (event: SessionEvent, ctx: ?*anyopaque) void,
        ctx: ?*anyopaque,
    ) EventSubscriptionToken {
        const index = self.session_event_listeners.items.len;
        self.session_event_listeners.append(self.allocator, .{ .func = func, .ctx = ctx }) catch return .{ .index = std.math.maxInt(usize) };
        return .{ .index = index };
    }

    pub fn unsubscribeEvents(self: *AgentSession, token: EventSubscriptionToken) void {
        if (token.index < self.session_event_listeners.items.len) {
            _ = self.session_event_listeners.orderedRemove(token.index);
        }
    }

    pub fn cloneQueuedMessageSnapshot(self: *AgentSession, allocator: std.mem.Allocator) !control_mod.QueuedMessageSnapshot {
        return self.agent.snapshotQueuedMessages(allocator);
    }

    pub fn restoreQueuedMessagesOnAgentThread(self: *AgentSession, allocator: std.mem.Allocator) !control_mod.QueuedMessageSnapshot {
        return self.agent.takeQueuedMessagesAndClear(allocator);
    }

    fn emitAgentEvent(self: *AgentSession, event: protocol.AgentEvent) void {
        if (self.event_handler) |handler| {
            handler.func(event, handler.ctx);
        }
        for (self.agent_event_listeners.items) |handler| {
            handler.func(event, handler.ctx);
        }
    }

    pub fn emitSessionEvent(self: *AgentSession, event: SessionEvent) void {
        for (self.session_event_listeners.items) |handler| {
            handler.func(event, handler.ctx);
        }
    }

    /// Activate session-owned lifecycle seams once the session is pinned.
    pub fn activateLifecycle(self: *AgentSession) void {
        self.bindExtensionRuntime();
        self.wireSubscription();
    }

    fn deactivateLifecycle(self: *AgentSession) void {
        self.unwireExtensionSubscription();
        self.unwireSubscription();
        self.unbindExtensionRuntime();
    }

    fn wireSubscription(self: *AgentSession) void {
        // Extension observers run before session listeners/persistence so
        // event-time retained UI publications exist before RuntimeHost/TUI
        // listeners drain them. This also matches the pi-mono ordering noted
        // on eventListener below: extensions → listeners → persistence.
        if (self._extension_subscription_token == null) {
            if (self._extension_runner != null) {
                self._extension_subscription_token = self.agent.subscribe(
                    &agentEventSinkFromRunnerRef,
                    @ptrCast(self._extension_runner_ref),
                );
            }
        }
        if (self._subscription_token == null) {
            self._subscription_token = self.agent.subscribe(&eventListener, @ptrCast(self));
        }
    }

    fn unwireSubscription(self: *AgentSession) void {
        if (self._subscription_token) |token| {
            self.agent.unsubscribe(token);
            self._subscription_token = null;
        }
    }

    fn unwireExtensionSubscription(self: *AgentSession) void {
        if (self._extension_subscription_token) |token| {
            self.agent.unsubscribe(token);
            self._extension_subscription_token = null;
        }
    }

    fn bindExtensionRuntime(self: *AgentSession) void {
        const runner = self._extension_runner orelse return;
        self.bindExtensionRuntimeFor(runner);
    }

    fn bindExtensionRuntimeFor(self: *AgentSession, runner: *ExtensionRunner) void {
        if (runner.isBound()) return;

        runner.bindRuntime(.{
            .session = @ptrCast(self),
            .ui = null,
            .command_actions = null,
            .get_model = &runtimeGetModel,
            .models_get = &runtimeModelsGet,
            .models_get_one = &runtimeModelsGetOne,
            .is_idle = &runtimeIsIdle,
            .abort = &runtimeAbort,
            .has_pending_messages = &runtimeHasPendingMessages,
            .shutdown = null,
            .get_context_usage = &runtimeGetContextUsage,
            .get_system_prompt = &runtimeGetSystemPrompt,
            .get_binding_info = &runtimeGetBindingInfo,
            .session_state_get = &runtimeSessionStateGet,
            .session_state_set = &runtimeSessionStateSet,
            .session_state_delete = &runtimeSessionStateDelete,
            .session_info_get = &runtimeSessionInfoGet,
            .session_name_get = &runtimeSessionNameGet,
            .session_name_set = &runtimeSessionNameSet,
            .session_tool_results_get = &runtimeSessionToolResultsGet,
            .session_messages_get = &runtimeSessionMessagesGet,
            .session_note_append = &runtimeSessionNoteAppend,
            .session_notes_get = &runtimeSessionNotesGet,
            .session_label_set = &runtimeSessionLabelSet,
            .session_labels_get = &runtimeSessionLabelsGet,
            .session_entry_get = &runtimeSessionEntryGet,
            .session_entries_get = &runtimeSessionEntriesGet,
            .publish_report = &runtimePublishReport,
            .publish_prompt = &runtimePublishPrompt,
            .resolve_prompt = &runtimeResolvePrompt,
            .cancel_prompts = &runtimeCancelPrompts,
            .publish_ui = &runtimePublishUi,
            .revoke_ui = &runtimeRevokeUi,
            .publish_editor_action = &runtimePublishEditorAction,
            .clear_editor_actions = &runtimeClearEditorActions,
            .provider_projection_changed = &runtimeProviderProjectionChanged,
            .tool_projection_changed = &runtimeToolProjectionChanged,
        }, self._stream_closure.registry) catch {};
    }

    fn unbindExtensionRuntime(self: *AgentSession) void {
        if (self._extension_runner) |runner| {
            runner.unbindRuntime();
        }
    }

    pub fn replaceExtensionRuntimeBundleOnAgentThread(self: *AgentSession, next: ExtensionRuntimeBundle) !void {
        if (self.agent.isStreaming() or self.agent.hasQueuedMessages()) return error.SessionBusy;
        if (self._extension_runner) |runner| {
            if (!runner.isReloadIdle()) return error.SessionBusy;
        }

        var replacement = next;
        errdefer replacement.deinit(self.allocator);
        if (replacement.extension_runner) |runner| self.bindExtensionRuntimeFor(runner);

        var old: ExtensionRuntimeBundle = .{
            .system_prompt = self._owned_system_prompt,
            .tools = self.tools,
            .builtin_ctx = self._builtin_ctx,
            .extension_runner = self._extension_runner,
            .extension_lua_state = self._extension_lua_state,
        };

        _ = self._extension_runner_ref.swap(replacement.extension_runner);
        self._extension_runner = replacement.extension_runner;
        self._extension_lua_state = replacement.extension_lua_state;
        self.tools = replacement.tools;
        self._owned_system_prompt = replacement.system_prompt;
        self._builtin_ctx = replacement.builtin_ctx;
        self.agent.replaceRuntimeInputs(replacement.system_prompt, replacement.tools);

        replacement = .{ .system_prompt = "", .tools = &.{} };
        if (old.extension_runner) |runner| runner.unbindRuntime();
        old.deinit(self.allocator);
    }

    fn destroyExtensionRuntime(self: *AgentSession) void {
        if (self._extension_runner) |runner| {
            _ = self._extension_runner_ref.swap(null);
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

    fn agentEventSinkFromRunnerRef(event: protocol.AgentEvent, ctx: ?*anyopaque) void {
        const ref: *ExtensionRunnerRef = @ptrCast(@alignCast(ctx.?));
        const runner = ref.current orelse return;
        event_bridge.agentEventSink(event, @ptrCast(runner));
    }

    fn beforeToolCallFromRunnerRef(
        ctx_arg: protocol.BeforeToolCallContext,
        signal: @import("../abort_signal.zig").AbortSignal,
        ctx: ?*anyopaque,
    ) ?protocol.BeforeToolCallResult {
        const ref: *ExtensionRunnerRef = @ptrCast(@alignCast(ctx.?));
        const runner = ref.current orelse return null;
        return event_bridge.beforeToolCall(ctx_arg, signal, @ptrCast(runner));
    }

    fn afterToolCallFromRunnerRef(
        ctx_arg: protocol.AfterToolCallContext,
        signal: @import("../abort_signal.zig").AbortSignal,
        ctx: ?*anyopaque,
    ) ?protocol.AfterToolCallResult {
        const ref: *ExtensionRunnerRef = @ptrCast(@alignCast(ctx.?));
        const runner = ref.current orelse return null;
        return event_bridge.afterToolCall(ctx_arg, signal, @ptrCast(runner));
    }

    fn runtimeGetModel(session_ptr: *anyopaque) protocol.Model {
        const self: *AgentSession = @ptrCast(@alignCast(session_ptr));
        return self.agent.modelValue();
    }

    fn runtimeModelsGet(session_ptr: *anyopaque, allocator: std.mem.Allocator) ?std.json.Value {
        const self: *AgentSession = @ptrCast(@alignCast(session_ptr));
        const registry = self.model_registry orelse return null;
        var arr = std.json.Array.init(allocator);
        for (registry.getAll()) |model| arr.append(modelJson(allocator, model) catch return null) catch return null;
        return .{ .array = arr };
    }

    fn runtimeModelsGetOne(session_ptr: *anyopaque, allocator: std.mem.Allocator, model_ref: []const u8) ?std.json.Value {
        const self: *AgentSession = @ptrCast(@alignCast(session_ptr));
        const model = self.resolveModelRef(model_ref) orelse return null;
        return modelJson(allocator, model) catch null;
    }

    fn resolveModelRef(self: *AgentSession, model_ref: []const u8) ?ai.protocol.Model {
        const registry = self.model_registry orelse return null;
        const parsed = resolve_mod.parseModelPattern(self.allocator, model_ref, registry.getAll(), .{});
        return parsed.model orelse registry.findByProviderName(ai.json_util.providerToString(self.agent.modelValue().provider), model_ref);
    }

    fn modelJson(allocator: std.mem.Allocator, model: protocol.Model) !std.json.Value {
        var obj = std.json.ObjectMap.init(allocator);
        try obj.put(try allocator.dupe(u8, "id"), .{ .string = try allocator.dupe(u8, model.id) });
        try obj.put(try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, model.name) });
        const provider = ai.json_util.providerToString(model.provider);
        try obj.put(try allocator.dupe(u8, "provider"), .{ .string = try allocator.dupe(u8, provider) });
        const api = ai.provider.apiToString(model.api);
        try obj.put(try allocator.dupe(u8, "api"), .{ .string = try allocator.dupe(u8, api) });
        try obj.put(try allocator.dupe(u8, "context_window"), .{ .integer = @intCast(model.context_window) });
        try obj.put(try allocator.dupe(u8, "max_tokens"), .{ .integer = @intCast(model.max_tokens) });
        try obj.put(try allocator.dupe(u8, "reasoning"), .{ .bool = model.reasoning });
        return .{ .object = obj };
    }

    fn runtimeIsIdle(session_ptr: *anyopaque) bool {
        const self: *AgentSession = @ptrCast(@alignCast(session_ptr));
        return !self.agent.isStreaming();
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
        return self.agent.systemPrompt();
    }

    fn runtimeGetBindingInfo(session_ptr: *anyopaque) extension_runner_mod.ExtensionBindingInfo {
        const self: *AgentSession = @ptrCast(@alignCast(session_ptr));
        const session_file = self.getSessionFile();
        return .{
            .workspace_id = self.resource_loader.cwd,
            .session_id = self.session_store.sessionId(),
            .session_file = if (session_file.len == 0) null else session_file,
        };
    }

    const extension_state_entry_type = "extension_state";

    fn runtimeSessionStateGet(
        session_ptr: *anyopaque,
        allocator: std.mem.Allocator,
        state_owner_id: []const u8,
        key: []const u8,
    ) ?std.json.Value {
        const self: *AgentSession = @ptrCast(@alignCast(session_ptr));
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const branch = self.session_store.buildCurrentVisibleBranchAlloc(arena.allocator()) catch return null;
        var latest: ?std.json.Value = null;
        var deleted = false;

        for (branch) |entry| {
            const custom = switch (entry.entry) {
                .custom => |custom| custom,
                else => continue,
            };
            if (!std.mem.eql(u8, custom.custom_type, extension_state_entry_type)) continue;
            const data = custom.data orelse continue;
            if (data != .object) continue;
            const owner_value = data.object.get("state_owner_id") orelse continue;
            const key_value = data.object.get("key") orelse continue;
            if (owner_value != .string or key_value != .string) continue;
            if (!std.mem.eql(u8, owner_value.string, state_owner_id)) continue;
            if (!std.mem.eql(u8, key_value.string, key)) continue;

            deleted = if (data.object.get("deleted")) |value| value == .bool and value.bool else false;
            latest = data.object.get("value");
        }

        if (deleted) return null;
        const value = latest orelse return null;
        return ai.json_util.cloneJsonValue(allocator, value) catch null;
    }

    fn runtimeSessionStateSet(
        session_ptr: *anyopaque,
        state_owner_id: []const u8,
        key: []const u8,
        value: std.json.Value,
    ) !void {
        const self: *AgentSession = @ptrCast(@alignCast(session_ptr));
        var data = std.json.ObjectMap.init(self.allocator);
        errdefer {
            const wrapped: std.json.Value = .{ .object = data };
            ai.json_util.freeJsonValue(self.allocator, wrapped);
        }

        try data.put(try self.allocator.dupe(u8, "state_owner_id"), .{ .string = try self.allocator.dupe(u8, state_owner_id) });
        try data.put(try self.allocator.dupe(u8, "key"), .{ .string = try self.allocator.dupe(u8, key) });
        try data.put(try self.allocator.dupe(u8, "value"), try ai.json_util.cloneJsonValue(self.allocator, value));

        self.session_store.appendCustomEntry(extension_state_entry_type, .{ .object = data });
    }

    fn runtimeSessionStateDelete(
        session_ptr: *anyopaque,
        state_owner_id: []const u8,
        key: []const u8,
    ) !void {
        const self: *AgentSession = @ptrCast(@alignCast(session_ptr));
        var data = std.json.ObjectMap.init(self.allocator);
        errdefer {
            const wrapped: std.json.Value = .{ .object = data };
            ai.json_util.freeJsonValue(self.allocator, wrapped);
        }

        try data.put(try self.allocator.dupe(u8, "state_owner_id"), .{ .string = try self.allocator.dupe(u8, state_owner_id) });
        try data.put(try self.allocator.dupe(u8, "key"), .{ .string = try self.allocator.dupe(u8, key) });
        try data.put(try self.allocator.dupe(u8, "deleted"), .{ .bool = true });

        self.session_store.appendCustomEntry(extension_state_entry_type, .{ .object = data });
    }

    fn runtimeSessionInfoGet(session_ptr: *anyopaque, allocator: std.mem.Allocator) ?std.json.Value {
        const self: *AgentSession = @ptrCast(@alignCast(session_ptr));
        var obj = std.json.ObjectMap.init(allocator);
        obj.put(allocator.dupe(u8, "id") catch return null, .{ .string = allocator.dupe(u8, self.session_store.sessionId()) catch return null }) catch return null;
        obj.put(allocator.dupe(u8, "cwd") catch return null, .{ .string = allocator.dupe(u8, self.resource_loader.cwd) catch return null }) catch return null;
        const session_file = self.session_store.sessionFile();
        obj.put(allocator.dupe(u8, "file") catch return null, if (session_file.len > 0) .{ .string = allocator.dupe(u8, session_file) catch return null } else .null) catch return null;
        const name = latestSessionName(self, allocator);
        defer if (name) |value| allocator.free(value);
        obj.put(allocator.dupe(u8, "name") catch return null, if (name) |value| .{ .string = allocator.dupe(u8, value) catch return null } else .null) catch return null;
        return .{ .object = obj };
    }

    fn runtimeSessionNameGet(session_ptr: *anyopaque, allocator: std.mem.Allocator) ?[]const u8 {
        const self: *AgentSession = @ptrCast(@alignCast(session_ptr));
        return latestSessionName(self, allocator);
    }

    fn runtimeSessionNameSet(session_ptr: *anyopaque, name: ?[]const u8) !void {
        const self: *AgentSession = @ptrCast(@alignCast(session_ptr));
        self.session_store.appendSessionInfo(name);
    }

    fn latestSessionName(self: *AgentSession, allocator: std.mem.Allocator) ?[]const u8 {
        const branch = self.session_store.buildCurrentVisibleBranchAlloc(allocator) catch return null;
        defer allocator.free(branch);
        var i = branch.len;
        while (i > 0) {
            i -= 1;
            const info = switch (branch[i].entry) {
                .session_info => |si| si,
                else => continue,
            };
            return if (info.name) |name| allocator.dupe(u8, name) catch null else null;
        }
        return null;
    }

    fn runtimeSessionToolResultsGet(session_ptr: *anyopaque, allocator: std.mem.Allocator, tool_name: []const u8) ?std.json.Value {
        const self: *AgentSession = @ptrCast(@alignCast(session_ptr));
        const branch = self.session_store.buildCurrentVisibleBranchAlloc(allocator) catch return null;
        defer allocator.free(branch);
        var arr = std.json.Array.init(allocator);
        for (branch) |entry| {
            const msg = switch (entry.entry) {
                .message => |m| m.message,
                else => continue,
            };
            if (msg != .tool_result) continue;
            const tr = msg.tool_result;
            if (!std.mem.eql(u8, tr.tool_name, tool_name)) continue;
            arr.append(sessionToolResultJson(allocator, entry.id, tr) catch return null) catch return null;
        }
        return .{ .array = arr };
    }

    fn runtimeSessionNoteAppend(session_ptr: *anyopaque, kind: []const u8, title: ?[]const u8, body: []const u8, source_entry_id: ?[]const u8) !void {
        const self: *AgentSession = @ptrCast(@alignCast(session_ptr));
        const allocator = self.session_store.writer.allocator;
        var obj = std.json.ObjectMap.init(allocator);
        errdefer ai.json_util.freeJsonValue(allocator, .{ .object = obj });
        try obj.put(try allocator.dupe(u8, "kind"), .{ .string = try allocator.dupe(u8, kind) });
        if (title) |value| try obj.put(try allocator.dupe(u8, "title"), .{ .string = try allocator.dupe(u8, value) });
        if (source_entry_id) |value| try obj.put(try allocator.dupe(u8, "source_entry_id"), .{ .string = try allocator.dupe(u8, value) });
        try obj.put(try allocator.dupe(u8, "body"), .{ .string = try allocator.dupe(u8, body) });
        self.session_store.appendCustomEntry("extension_note", .{ .object = obj });
    }

    fn runtimeSessionNotesGet(session_ptr: *anyopaque, allocator: std.mem.Allocator, kind: ?[]const u8, source_entry_id: ?[]const u8, limit: usize) ?std.json.Value {
        const self: *AgentSession = @ptrCast(@alignCast(session_ptr));
        const branch = self.session_store.buildCurrentVisibleBranchAlloc(allocator) catch return null;
        defer allocator.free(branch);
        var all = std.json.Array.init(allocator);
        for (branch) |entry| {
            const custom = switch (entry.entry) {
                .custom => |c| c,
                else => continue,
            };
            if (!std.mem.eql(u8, custom.custom_type, "extension_note")) continue;
            const data = custom.data orelse continue;
            if (data != .object) continue;
            if (kind) |wanted| {
                const value = data.object.get("kind") orelse continue;
                if (value != .string or !std.mem.eql(u8, value.string, wanted)) continue;
            }
            if (source_entry_id) |wanted| {
                const value = data.object.get("source_entry_id") orelse continue;
                if (value != .string or !std.mem.eql(u8, value.string, wanted)) continue;
            }
            var note = ai.json_util.cloneJsonValue(allocator, data) catch return null;
            if (note == .object) {
                note.object.put(allocator.dupe(u8, "entry_id") catch return null, .{ .string = allocator.dupe(u8, entry.id) catch return null }) catch return null;
            }
            all.append(note) catch return null;
        }
        if (all.items.len <= limit) return .{ .array = all };
        const start = all.items.len - limit;
        for (all.items[0..start]) |value| ai.json_util.freeJsonValue(allocator, value);
        var out = std.json.Array.init(allocator);
        for (all.items[start..]) |value| out.append(value) catch return null;
        all.deinit();
        return .{ .array = out };
    }

    fn runtimeSessionMessagesGet(session_ptr: *anyopaque, allocator: std.mem.Allocator, limit: usize, include_tools: bool) ?std.json.Value {
        const self: *AgentSession = @ptrCast(@alignCast(session_ptr));
        const branch = self.session_store.buildCurrentVisibleBranchAlloc(allocator) catch return null;
        defer allocator.free(branch);
        var all = std.json.Array.init(allocator);
        for (branch) |entry| {
            const msg = switch (entry.entry) {
                .message => |m| m.message,
                else => continue,
            };
            appendSessionMessageJson(allocator, &all, entry.id, msg, include_tools) catch return null;
        }
        if (all.items.len <= limit) return .{ .array = all };
        const start = all.items.len - limit;
        for (all.items[0..start]) |value| ai.json_util.freeJsonValue(allocator, value);
        var out = std.json.Array.init(allocator);
        for (all.items[start..]) |value| out.append(value) catch return null;
        all.deinit();
        return .{ .array = out };
    }

    fn appendSessionMessageJson(allocator: std.mem.Allocator, arr: *std.json.Array, entry_id: []const u8, msg: protocol.AgentMessage, include_tools: bool) !void {
        switch (msg) {
            .user => |user| try arr.append(try sessionUserMessageJson(allocator, entry_id, user)),
            .assistant => |assistant| {
                var text = std.ArrayList(u8).empty;
                defer text.deinit(allocator);
                for (assistant.content) |block| switch (block) {
                    .text => |t| {
                        if (text.items.len > 0) try text.append(allocator, '\n');
                        try text.appendSlice(allocator, t.text);
                    },
                    .tool_call => |call| if (include_tools) try arr.append(try sessionToolCallJson(allocator, entry_id, call)),
                    .thinking => {},
                };
                if (text.items.len > 0) try arr.append(try sessionRoleTextJson(allocator, entry_id, "assistant", text.items));
            },
            .tool_result => |tr| if (include_tools) try arr.append(try sessionToolResultMessageJson(allocator, entry_id, tr)),
            .compaction_summary, .branch_summary, .custom => {},
        }
    }

    fn sessionUserMessageJson(allocator: std.mem.Allocator, entry_id: []const u8, user: ai.protocol.UserMessage) !std.json.Value {
        const text = switch (user.content) {
            .text => |text| text,
            .blocks => |blocks| blk: {
                for (blocks) |block| switch (block) {
                    .text => |text| break :blk text.text,
                    .image => {},
                };
                break :blk "";
            },
        };
        return sessionRoleTextJson(allocator, entry_id, "user", text);
    }

    fn sessionRoleTextJson(allocator: std.mem.Allocator, entry_id: []const u8, role: []const u8, text: []const u8) !std.json.Value {
        var obj = std.json.ObjectMap.init(allocator);
        try obj.put(try allocator.dupe(u8, "entry_id"), .{ .string = try allocator.dupe(u8, entry_id) });
        try obj.put(try allocator.dupe(u8, "role"), .{ .string = try allocator.dupe(u8, role) });
        try obj.put(try allocator.dupe(u8, "text"), .{ .string = try allocator.dupe(u8, text) });
        return .{ .object = obj };
    }

    fn sessionToolCallJson(allocator: std.mem.Allocator, entry_id: []const u8, call: ai.protocol.ToolCall) !std.json.Value {
        var obj = std.json.ObjectMap.init(allocator);
        try obj.put(try allocator.dupe(u8, "entry_id"), .{ .string = try allocator.dupe(u8, entry_id) });
        try obj.put(try allocator.dupe(u8, "role"), .{ .string = try allocator.dupe(u8, "tool_call") });
        try obj.put(try allocator.dupe(u8, "tool_call_id"), .{ .string = try allocator.dupe(u8, call.id) });
        try obj.put(try allocator.dupe(u8, "tool_name"), .{ .string = try allocator.dupe(u8, call.name) });
        try obj.put(try allocator.dupe(u8, "args"), try ai.json_util.cloneJsonValue(allocator, call.arguments));
        return .{ .object = obj };
    }

    fn sessionToolResultMessageJson(allocator: std.mem.Allocator, entry_id: []const u8, tr: ai.protocol.ToolResultMessage) !std.json.Value {
        var value = try sessionToolResultJson(allocator, entry_id, tr);
        try value.object.put(try allocator.dupe(u8, "role"), .{ .string = try allocator.dupe(u8, "tool_result") });
        return value;
    }

    fn sessionToolResultJson(allocator: std.mem.Allocator, entry_id: []const u8, tr: ai.protocol.ToolResultMessage) !std.json.Value {
        var obj = std.json.ObjectMap.init(allocator);
        try obj.put(try allocator.dupe(u8, "entry_id"), .{ .string = try allocator.dupe(u8, entry_id) });
        try obj.put(try allocator.dupe(u8, "tool_call_id"), .{ .string = try allocator.dupe(u8, tr.tool_call_id) });
        try obj.put(try allocator.dupe(u8, "tool_name"), .{ .string = try allocator.dupe(u8, tr.tool_name) });
        try obj.put(try allocator.dupe(u8, "is_error"), .{ .bool = tr.is_error });
        if (tr.details) |details| {
            try obj.put(try allocator.dupe(u8, "details"), try ai.json_util.cloneJsonValue(allocator, details));
        } else {
            try obj.put(try allocator.dupe(u8, "details"), .null);
        }
        var content = std.json.Array.init(allocator);
        for (tr.content) |block| {
            switch (block) {
                .text => |text| {
                    var block_obj = std.json.ObjectMap.init(allocator);
                    try block_obj.put(try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "text") });
                    try block_obj.put(try allocator.dupe(u8, "text"), .{ .string = try allocator.dupe(u8, text.text) });
                    try content.append(.{ .object = block_obj });
                },
                .image => {},
            }
        }
        try obj.put(try allocator.dupe(u8, "content"), .{ .array = content });
        return .{ .object = obj };
    }

    fn runtimeSessionEntryGet(session_ptr: *anyopaque, allocator: std.mem.Allocator, entry_id: []const u8) ?std.json.Value {
        const self: *AgentSession = @ptrCast(@alignCast(session_ptr));
        const branch = self.session_store.buildCurrentVisibleBranchAlloc(allocator) catch return null;
        defer allocator.free(branch);
        for (branch) |entry| {
            if (!std.mem.eql(u8, entry.id, entry_id)) continue;
            return sessionEntryJson(allocator, entry) catch return null;
        }
        return null;
    }

    fn sessionEntryJson(allocator: std.mem.Allocator, entry: session_proto.SessionEntry) !std.json.Value {
        switch (entry.entry) {
            .message => |message| return sessionMessageEntryJson(allocator, entry.id, message.message),
            .custom => |custom| {
                if (std.mem.eql(u8, custom.custom_type, "extension_note")) {
                    const data = custom.data orelse return sessionCustomEntryJson(allocator, entry.id, custom);
                    if (data == .object) {
                        var note = try ai.json_util.cloneJsonValue(allocator, data);
                        try note.object.put(try allocator.dupe(u8, "entry_id"), .{ .string = try allocator.dupe(u8, entry.id) });
                        try note.object.put(try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "extension_note") });
                        return note;
                    }
                }
                return sessionCustomEntryJson(allocator, entry.id, custom);
            },
            .label => |label| return sessionLabelJson(allocator, entry.id, label),
            else => return sessionTypedEntryJson(allocator, entry.id, @tagName(entry.entry)),
        }
    }

    fn sessionMessageEntryJson(allocator: std.mem.Allocator, entry_id: []const u8, msg: protocol.AgentMessage) !std.json.Value {
        var messages = std.json.Array.init(allocator);
        try appendSessionMessageJson(allocator, &messages, entry_id, msg, true);
        if (messages.items.len == 1) {
            var value = messages.items[0];
            messages.deinit();
            try value.object.put(try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "message") });
            return value;
        }
        var obj = std.json.ObjectMap.init(allocator);
        try obj.put(try allocator.dupe(u8, "entry_id"), .{ .string = try allocator.dupe(u8, entry_id) });
        try obj.put(try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "message") });
        try obj.put(try allocator.dupe(u8, "messages"), .{ .array = messages });
        return .{ .object = obj };
    }

    fn sessionCustomEntryJson(allocator: std.mem.Allocator, entry_id: []const u8, custom: session_proto.CustomEntry) !std.json.Value {
        var obj = std.json.ObjectMap.init(allocator);
        try obj.put(try allocator.dupe(u8, "entry_id"), .{ .string = try allocator.dupe(u8, entry_id) });
        try obj.put(try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "custom") });
        try obj.put(try allocator.dupe(u8, "custom_type"), .{ .string = try allocator.dupe(u8, custom.custom_type) });
        try obj.put(try allocator.dupe(u8, "data"), if (custom.data) |data| try ai.json_util.cloneJsonValue(allocator, data) else .null);
        return .{ .object = obj };
    }

    fn sessionTypedEntryJson(allocator: std.mem.Allocator, entry_id: []const u8, entry_type: []const u8) !std.json.Value {
        var obj = std.json.ObjectMap.init(allocator);
        try obj.put(try allocator.dupe(u8, "entry_id"), .{ .string = try allocator.dupe(u8, entry_id) });
        try obj.put(try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, entry_type) });
        return .{ .object = obj };
    }

    fn runtimeSessionLabelSet(session_ptr: *anyopaque, target_entry_id: []const u8, label: ?[]const u8) !void {
        const self: *AgentSession = @ptrCast(@alignCast(session_ptr));
        self.session_store.appendLabel(target_entry_id, label);
    }

    fn runtimeSessionEntriesGet(session_ptr: *anyopaque, allocator: std.mem.Allocator, label: ?[]const u8, limit: usize) ?std.json.Value {
        const wanted = label orelse return .{ .array = std.json.Array.init(allocator) };
        const self: *AgentSession = @ptrCast(@alignCast(session_ptr));
        const branch = self.session_store.buildCurrentVisibleBranchAlloc(allocator) catch return null;
        defer allocator.free(branch);

        var latest_labels: std.StringHashMapUnmanaged(?[]const u8) = .{};
        defer latest_labels.deinit(allocator);
        for (branch) |entry| {
            const label_entry = switch (entry.entry) {
                .label => |value| value,
                else => continue,
            };
            latest_labels.put(allocator, label_entry.target_id, label_entry.label) catch return null;
        }

        var all = std.json.Array.init(allocator);
        for (branch) |entry| {
            const current = latest_labels.get(entry.id) orelse continue;
            const current_label = current orelse continue;
            if (!std.mem.eql(u8, current_label, wanted)) continue;
            all.append(sessionEntryJson(allocator, entry) catch return null) catch return null;
        }
        if (all.items.len <= limit) return .{ .array = all };
        const start = all.items.len - limit;
        for (all.items[0..start]) |value| ai.json_util.freeJsonValue(allocator, value);
        var out = std.json.Array.init(allocator);
        for (all.items[start..]) |value| out.append(value) catch return null;
        all.deinit();
        return .{ .array = out };
    }

    fn sessionLabelJson(allocator: std.mem.Allocator, entry_id: []const u8, label_entry: session_proto.LabelEntry) !std.json.Value {
        var obj = std.json.ObjectMap.init(allocator);
        try obj.put(try allocator.dupe(u8, "entry_id"), .{ .string = try allocator.dupe(u8, entry_id) });
        try obj.put(try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "label") });
        try obj.put(try allocator.dupe(u8, "target_entry_id"), .{ .string = try allocator.dupe(u8, label_entry.target_id) });
        try obj.put(try allocator.dupe(u8, "label"), if (label_entry.label) |value| .{ .string = try allocator.dupe(u8, value) } else .null);
        return .{ .object = obj };
    }

    fn runtimeSessionLabelsGet(session_ptr: *anyopaque, allocator: std.mem.Allocator, target_entry_id: ?[]const u8, limit: usize) ?std.json.Value {
        const self: *AgentSession = @ptrCast(@alignCast(session_ptr));
        const branch = self.session_store.buildCurrentVisibleBranchAlloc(allocator) catch return null;
        defer allocator.free(branch);
        var all = std.json.Array.init(allocator);
        for (branch) |entry| {
            const label_entry = switch (entry.entry) {
                .label => |label| label,
                else => continue,
            };
            if (target_entry_id) |wanted| {
                if (!std.mem.eql(u8, label_entry.target_id, wanted)) continue;
            }
            all.append(sessionLabelJson(allocator, entry.id, label_entry) catch return null) catch return null;
        }
        if (all.items.len <= limit) return .{ .array = all };
        const start = all.items.len - limit;
        for (all.items[0..start]) |value| ai.json_util.freeJsonValue(allocator, value);
        var out = std.json.Array.init(allocator);
        for (all.items[start..]) |value| out.append(value) catch return null;
        all.deinit();
        return .{ .array = out };
    }

    fn runtimePublishReport(session_ptr: *anyopaque, report: extension_ui.Report) !void {
        const self: *AgentSession = @ptrCast(@alignCast(session_ptr));
        self.clearPendingExtensionReport();
        self.pending_extension_report = try extension_ui.Report.clone(self.allocator, report);
    }

    pub fn takePendingExtensionReport(self: *AgentSession) ?extension_ui.Report {
        const report = self.pending_extension_report;
        self.pending_extension_report = null;
        return report;
    }

    fn clearPendingExtensionReport(self: *AgentSession) void {
        if (self.pending_extension_report) |*report| report.deinit(self.allocator);
        self.pending_extension_report = null;
    }

    fn runtimePublishPrompt(session_ptr: *anyopaque, prompt: extension_ui.PromptRequest) !void {
        const self: *AgentSession = @ptrCast(@alignCast(session_ptr));
        var cloned = try extension_ui.PromptRequest.clone(self.allocator, prompt);
        errdefer cloned.deinit(self.allocator);
        try self.pending_extension_prompts.append(self.allocator, cloned);
    }

    fn runtimeResolvePrompt(session_ptr: *anyopaque, prompt: extension_ui.PromptRequest, response: *request_mod.ExtensionPromptResponse) void {
        const self: *AgentSession = @ptrCast(@alignCast(session_ptr));
        self.emitSessionEvent(.{ .extension_prompt_request = .{ .prompt = prompt, .response = response } });
    }

    fn runtimeCancelPrompts(session_ptr: *anyopaque) void {
        const self: *AgentSession = @ptrCast(@alignCast(session_ptr));
        self.clearPendingExtensionPrompts();
    }

    pub fn pendingExtensionPromptCount(self: *const AgentSession) usize {
        return self.pending_extension_prompts.items.len;
    }

    fn clearPendingExtensionPrompts(self: *AgentSession) void {
        for (self.pending_extension_prompts.items) |*prompt| prompt.deinit(self.allocator);
        self.pending_extension_prompts.deinit(self.allocator);
        self.pending_extension_prompts = .empty;
    }

    fn runtimePublishUi(session_ptr: *anyopaque, update: extension_ui.UiPublication) !void {
        const self: *AgentSession = @ptrCast(@alignCast(session_ptr));
        var cloned = try extension_ui.UiPublication.clone(self.allocator, update);
        errdefer cloned.deinit(self.allocator);
        try self.pending_extension_ui_publications.append(self.allocator, cloned);
    }

    fn runtimeRevokeUi(session_ptr: *anyopaque) void {
        const self: *AgentSession = @ptrCast(@alignCast(session_ptr));
        self.clearPendingExtensionRuntimeBundles();
    }

    pub fn takePendingExtensionRuntimeBundles(self: *AgentSession, allocator: std.mem.Allocator) ![]extension_ui.UiPublication {
        const out = try allocator.alloc(extension_ui.UiPublication, self.pending_extension_ui_publications.items.len);
        errdefer allocator.free(out);
        var initialized: usize = 0;
        errdefer {
            for (out[0..initialized]) |*update| update.deinit(allocator);
        }
        for (self.pending_extension_ui_publications.items, 0..) |update, i| {
            out[i] = try extension_ui.UiPublication.clone(allocator, update);
            initialized += 1;
        }
        self.clearPendingExtensionRuntimeBundles();
        return out;
    }

    fn clearPendingExtensionRuntimeBundles(self: *AgentSession) void {
        for (self.pending_extension_ui_publications.items) |*update| update.deinit(self.allocator);
        self.pending_extension_ui_publications.deinit(self.allocator);
        self.pending_extension_ui_publications = .empty;
    }

    fn runtimePublishEditorAction(session_ptr: *anyopaque, action: extension_ui.EditorAction) !void {
        const self: *AgentSession = @ptrCast(@alignCast(session_ptr));
        var cloned = try extension_ui.EditorAction.clone(self.allocator, action);
        errdefer cloned.deinit(self.allocator);
        try self.pending_extension_editor_actions.append(self.allocator, cloned);
    }

    fn runtimeClearEditorActions(session_ptr: *anyopaque) void {
        const self: *AgentSession = @ptrCast(@alignCast(session_ptr));
        self.clearPendingExtensionEditorActions();
    }

    pub fn takePendingExtensionEditorActions(self: *AgentSession, allocator: std.mem.Allocator) ![]extension_ui.EditorAction {
        const out = try allocator.alloc(extension_ui.EditorAction, self.pending_extension_editor_actions.items.len);
        errdefer allocator.free(out);
        var initialized: usize = 0;
        errdefer {
            for (out[0..initialized]) |*action| action.deinit(allocator);
        }
        for (self.pending_extension_editor_actions.items, 0..) |action, i| {
            out[i] = try extension_ui.EditorAction.clone(allocator, action);
            initialized += 1;
        }
        self.clearPendingExtensionEditorActions();
        return out;
    }

    fn clearPendingExtensionEditorActions(self: *AgentSession) void {
        for (self.pending_extension_editor_actions.items) |*action| action.deinit(self.allocator);
        self.pending_extension_editor_actions.deinit(self.allocator);
        self.pending_extension_editor_actions = .empty;
    }

    fn runtimeProviderProjectionChanged(session_ptr: *anyopaque) void {
        const self: *AgentSession = @ptrCast(@alignCast(session_ptr));
        self.rebuildVisibleModelCatalogFromActiveProviders() catch |err| {
            std.log.scoped(.coding_agent).warn("failed to rebuild visible model catalog: {s}", .{@errorName(err)});
        };
    }

    fn runtimeToolProjectionChanged(session_ptr: *anyopaque) void {
        const self: *AgentSession = @ptrCast(@alignCast(session_ptr));
        if (self.agent.isStreaming() or self.agent.hasQueuedMessages()) {
            self.pending_tool_projection_refresh = true;
            return;
        }
        self.rebuildVisibleToolsAndPromptFromRunner() catch |err| {
            self.pending_tool_projection_refresh = true;
            std.log.scoped(.coding_agent).warn("failed to rebuild visible tool projection: {s}", .{@errorName(err)});
        };
    }

    fn flushPendingToolProjectionRefresh(self: *AgentSession) void {
        if (!self.pending_tool_projection_refresh) return;
        if (self.agent.isStreaming() or self.agent.hasQueuedMessages()) return;
        self.rebuildVisibleToolsAndPromptFromRunner() catch |err| {
            std.log.scoped(.coding_agent).warn("failed to refresh visible tool projection: {s}", .{@errorName(err)});
            return;
        };
        self.pending_tool_projection_refresh = false;
    }

    fn rebuildVisibleToolsAndPromptFromRunner(self: *AgentSession) !void {
        const runner = self._extension_runner orelse return;
        const definitions = runner.tool_registry.items();
        const tools = try session_bootstrap.buildAgentTools(self.allocator, definitions, runner);
        errdefer self.allocator.free(tools);
        const system_prompt = try session_bootstrap.buildSystemPrompt(self.allocator, self.resource_loader, definitions);
        errdefer self.allocator.free(system_prompt);

        const old_tools = self.tools;
        const old_system_prompt = self._owned_system_prompt;
        self.tools = tools;
        self._owned_system_prompt = system_prompt;
        self.agent.replaceRuntimeInputs(system_prompt, tools);
        if (old_tools.len > 0) self.allocator.free(old_tools);
        if (old_system_prompt.len > 0) self.allocator.free(old_system_prompt);
    }

    /// Run a new text prompt. Wires session persistence, then delegates to Agent.prompt.
    pub fn run(self: *AgentSession, prompt_text: []const u8) !void {
        try self.runUserContent(.{ .text = prompt_text });
    }

    /// Run a new user message with explicit text/image content blocks.
    pub fn runUserContent(self: *AgentSession, user_content: ai.protocol.UserMessage.UserMessageContent) !void {
        self.flushPendingToolProjectionRefresh();
        self.wireSubscription();

        const user_msg = protocol.AgentMessage{
            .user = .{
                .content = user_content,
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
        self.flushPendingToolProjectionRefresh();
        self.wireSubscription();
        self.agent.continueTurn() catch |err| switch (err) {
            error.CannotContinueFromAssistant => return error.NeedsPrompt,
            else => return err,
        };
    }

    pub fn buildAiCompleteWorkerRequest(
        self: *AgentSession,
        allocator: std.mem.Allocator,
        id: extension_runner_mod.AsyncOpId,
        request: extension_runner_mod.AiCompleteRequest,
    ) !ai_complete_worker_mod.Request {
        const current_model = self.resolveExtensionAiModel(request.model) orelse return error.ModelUnavailable;
        const provider = self._stream_closure.registry.getForModel(
            ai.provider.apiToString(current_model.api),
            ai.json_util.providerToString(current_model.provider),
        ) orelse return error.ProviderUnavailable;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const api_key = self._stream_closure.resolveApiKey(arena.allocator(), current_model);
        var built = ai_complete_worker_mod.Request{
            .id = id,
            .provider = provider,
            .model = current_model,
            .prompt = try allocator.dupe(u8, request.prompt),
            .system_prompt = null,
            .api_key = null,
            .headers = null,
            .max_tokens = request.max_tokens,
            .reasoning = resolveAiCompleteReasoning(current_model, request.reasoning),
        };
        errdefer built.deinit(allocator);
        if (request.system_prompt) |value| built.system_prompt = try allocator.dupe(u8, value);
        if (api_key.len > 0) built.api_key = try allocator.dupe(u8, api_key);
        built.headers = try self._stream_closure.mergeClaimHeaders(current_model, allocator, null);
        return built;
    }

    fn resolveAiCompleteReasoning(model: ai.protocol.Model, override: ?protocol.ThinkingLevel) ?ai.protocol.ThinkingLevel {
        if (!model.reasoning) return null;
        const level = override orelse return .high;
        return switch (level) {
            .off => null,
            .minimal => .minimal,
            .low => .low,
            .medium => .medium,
            .high => .high,
            .xhigh => .xhigh,
        };
    }

    fn resolveExtensionAiModel(self: *AgentSession, model_ref: ?[]const u8) ?ai.protocol.Model {
        const value = model_ref orelse return self.agent.modelValue();
        return self.resolveModelRef(value);
    }

    pub fn completeUserText(
        self: *AgentSession,
        allocator: std.mem.Allocator,
        system_prompt: ?[]const u8,
        prompt_text: []const u8,
        max_tokens: u64,
    ) ![]u8 {
        const current_model = self.agent.modelValue();
        const provider = self._stream_closure.registry.getForModel(
            ai.provider.apiToString(current_model.api),
            ai.json_util.providerToString(current_model.provider),
        ) orelse return error.ProviderUnavailable;

        const api_key = self._stream_closure.resolveApiKey(allocator, current_model);
        const result = ai_completion.runPreparedTextCompletion(allocator, .{
            .provider = provider,
            .model = current_model,
            .prompt = prompt_text,
            .system_prompt = system_prompt,
            .api_key = if (api_key.len > 0) api_key else null,
            .max_tokens = max_tokens,
            .reasoning = if (current_model.reasoning) .high else null,
        });
        return switch (result) {
            .completed => |completed| completed.text,
            .err => |msg| {
                defer allocator.free(msg);
                std.log.scoped(.coding_agent).warn("completion failed: {s}", .{msg});
                return error.ProviderCompletionFailed;
            },
            .cancelled => error.MissingCompletionText,
        };
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
        return self._extension_runner_ref.current;
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

        self.emitAgentEvent(event);

        // Session persistence on message_end
        switch (event) {
            .message_end => |me| {
                const entry_id = self.session_store.appendMessage(me.message) orelse return;
                if (self._extension_runner_ref.current) |runner| {
                    event_bridge.dispatchSemanticMessage(runner, me.message, entry_id) catch |err| {
                        std.log.scoped(.zi_bridge).warn("semantic message dispatch failed: {s}", .{@errorName(err)});
                    };
                }
            },
            else => {},
        }
    }

    // -- Stream hook wrapping provider registry + auth -----------------------
    // pi-mono injects auth in the streamFn closure (sdk.ts:274-283).
    // We do the same: capture registry + api_key so the Agent doesn't need
    // to thread auth through AgentLoopConfig.

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

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "trySetModel updates session state and appends model change when auth exists" {
    const alloc = testing.allocator;

    var auth = try auth_storage_mod.AuthStorage.inMemory(alloc, null);
    defer auth.deinit();
    auth.setRuntimeApiKey("anthropic", "test-key");

    var model_registry = try model_registry_mod.ModelRegistry.init(alloc, &auth, &.{});
    defer model_registry.deinit();

    var fp = faux.FauxProvider.init(alloc);
    var registry = ai.provider.Registry.init(alloc);
    defer registry.deinit();
    try registry.register("faux", fp.provider(), null);

    const target = model_registry.find(.anthropic, "claude-opus-4-6") orelse return error.MissingCatalogEntry;
    var ca = AgentSession.initTestSession(alloc, .{
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
    try testing.expectEqualStrings(target.id, ca.agent.modelValue().id);
    try testing.expectEqual(@as(usize, 1), ca.session_store.writer.buffered_entries.items.len);
    const entry = ca.session_store.writer.buffered_entries.items[0].entry;
    try testing.expect(entry.entry == .model_change);
    try testing.expectEqualStrings("anthropic", entry.entry.model_change.provider);
    try testing.expectEqualStrings(target.id, entry.entry.model_change.model_id);
}

test "trySetModel reclamps xhigh to high and persists thinking change when target lacks xhigh" {
    const alloc = testing.allocator;

    var auth = try auth_storage_mod.AuthStorage.inMemory(alloc, null);
    defer auth.deinit();
    auth.setRuntimeApiKey("anthropic", "test-key");

    var model_registry = try model_registry_mod.ModelRegistry.init(alloc, &auth, &.{});
    defer model_registry.deinit();

    var fp = faux.FauxProvider.init(alloc);
    var registry = ai.provider.Registry.init(alloc);
    defer registry.deinit();
    try registry.register("faux", fp.provider(), null);

    const target = model_registry.find(.anthropic, "claude-sonnet-4-20250514") orelse return error.MissingCatalogEntry;
    var ca = AgentSession.initTestSession(alloc, .{
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
    try testing.expectEqual(.high, ca.agent.thinkingLevel());
    try testing.expectEqual(@as(usize, 2), ca.session_store.writer.buffered_entries.items.len);
    const thinking_entry = ca.session_store.writer.buffered_entries.items[1].entry;
    try testing.expect(thinking_entry.entry == .thinking_level_change);
    try testing.expectEqualStrings("high", thinking_entry.entry.thinking_level_change.thinking_level);
}

test "provider projection refreshes the current model from the rebuilt catalog" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var auth = try auth_storage_mod.AuthStorage.inMemory(alloc, null);
    defer auth.deinit();
    auth.setRuntimeApiKey("proxy-a", "test-key");

    var model_registry = try model_registry_mod.ModelRegistry.init(alloc, &auth, &.{});
    defer model_registry.deinit();

    var fp = faux.FauxProvider.init(alloc);
    var registry = ai.provider.Registry.init(alloc);
    defer registry.deinit();
    try registry.register("anthropic-messages", fp.provider(), null);

    const claim_models = try alloc.alloc(ai.provider.ClaimModelRegistration, 1);
    claim_models[0] = .{
        .id = try alloc.dupe(u8, "proxy-model"),
        .name = try alloc.dupe(u8, "Proxy Model v1"),
        .reasoning = false,
        .input = try alloc.dupe(ai.protocol.Model.InputType, &.{.text}),
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 4096,
        .max_tokens = 2048,
    };
    try testing.expect(try registry.registerClaim(.{
        .name = try alloc.dupe(u8, "proxy-a"),
        .api = try alloc.dupe(u8, "anthropic-messages"),
        .base_url = try alloc.dupe(u8, "https://proxy-a.example/v1"),
        .owner_id = try alloc.dupe(u8, "ext-a"),
        .generation = 1,
        .models = claim_models,
    }));
    try model_registry.rebuildFromActiveProviderClaims(&registry);

    const initial = model_registry.find(.{ .custom = "proxy-a" }, "proxy-model") orelse return error.MissingCatalogEntry;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const agent_dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(agent_dir);

    var ca = AgentSession.initTestSession(alloc, .{
        .model = initial,
        .api_key = "test-key",
        .cwd = "/tmp/zi-test",
        .resource_loader = createTestResourceLoaderWithAgentDir(alloc, "/tmp/zi-test", agent_dir),
        .registry = &registry,
        .auth_storage = &auth,
        .model_registry = &model_registry,
        .no_session = true,
    });
    defer ca.deinit();

    const updated_models = try alloc.alloc(ai.provider.ClaimModelRegistration, 1);
    updated_models[0] = .{
        .id = try alloc.dupe(u8, "proxy-model"),
        .name = try alloc.dupe(u8, "Proxy Model v2"),
        .reasoning = false,
        .input = try alloc.dupe(ai.protocol.Model.InputType, &.{.text}),
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 8192,
        .max_tokens = 4096,
    };
    try testing.expect(try registry.registerClaim(.{
        .name = try alloc.dupe(u8, "proxy-a"),
        .api = try alloc.dupe(u8, "anthropic-messages"),
        .base_url = try alloc.dupe(u8, "https://proxy-a.example/v2"),
        .owner_id = try alloc.dupe(u8, "ext-a"),
        .generation = 1,
        .models = updated_models,
    }));

    try ca.rebuildVisibleModelCatalogFromActiveProviders();

    try testing.expectEqualStrings("Proxy Model v1", ca.agent.modelValue().name);
    try testing.expectEqualStrings("https://proxy-a.example/v1", ca.agent.modelValue().base_url);
    try testing.expectEqual(@as(u64, 4096), ca.agent.modelValue().context_window);
}

test "trySetModel persists defaults through settings manager" {
    const alloc = testing.allocator;

    var auth = try auth_storage_mod.AuthStorage.inMemory(alloc, null);
    defer auth.deinit();
    auth.setRuntimeApiKey("anthropic", "test-key");

    var settings = try settings_manager_mod.SettingsManager.inMemory(alloc, null);
    defer settings.deinit();

    var model_registry = try model_registry_mod.ModelRegistry.init(alloc, &auth, &.{});
    defer model_registry.deinit();

    var fp = faux.FauxProvider.init(alloc);
    var registry = ai.provider.Registry.init(alloc);
    defer registry.deinit();
    try registry.register("faux", fp.provider(), null);

    const target = model_registry.find(.anthropic, "claude-opus-4-6") orelse return error.MissingCatalogEntry;
    var ca = AgentSession.initTestSession(alloc, .{
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

    var auth = try auth_storage_mod.AuthStorage.inMemory(alloc, null);
    defer auth.deinit();
    auth.setRuntimeApiKey("anthropic", "test-key");

    var settings = try settings_manager_mod.SettingsManager.inMemory(alloc, null);
    defer settings.deinit();

    var model_registry = try model_registry_mod.ModelRegistry.init(alloc, &auth, &.{});
    defer model_registry.deinit();

    var fp = faux.FauxProvider.init(alloc);
    var registry = ai.provider.Registry.init(alloc);
    defer registry.deinit();
    try registry.register("faux", fp.provider(), null);

    const initial = model_registry.find(.anthropic, "claude-opus-4-6") orelse return error.MissingCatalogEntry;
    var ca = AgentSession.initTestSession(alloc, .{
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

    var auth = try auth_storage_mod.AuthStorage.inMemory(alloc, null);
    defer auth.deinit();

    var model_registry = try model_registry_mod.ModelRegistry.init(alloc, &auth, &.{});
    defer model_registry.deinit();

    var fp = faux.FauxProvider.init(alloc);
    var registry = ai.provider.Registry.init(alloc);
    defer registry.deinit();
    try registry.register("faux", fp.provider(), null);

    const initial = faux.fauxModel();
    const blocked = model_registry.find(.anthropic, "claude-opus-4-6") orelse return error.MissingCatalogEntry;
    var ca = AgentSession.initTestSession(alloc, .{
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
    try testing.expectEqualStrings(initial.id, ca.agent.modelValue().id);
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
    return resources.ResourceLoader.init(allocator, .{
        .cwd = cwd,
        .agent_dir_override = "/tmp/zi-test-agent-empty",
    }) catch @panic("OOM");
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

fn writeReadOverrideExtension(
    allocator: std.mem.Allocator,
    tmp: *std.testing.TmpDir,
    snippet: []const u8,
    guideline: []const u8,
    result_text: []const u8,
) !void {
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
}

fn createAgentDirWithReadOverride(
    allocator: std.mem.Allocator,
    tmp: *std.testing.TmpDir,
    snippet: []const u8,
    guideline: []const u8,
    result_text: []const u8,
) ![]const u8 {
    try tmp.dir.makeDir("extensions");
    try writeReadOverrideExtension(allocator, tmp, snippet, guideline, result_text);
    return tmp.dir.realpathAlloc(allocator, ".");
}

/// Test helper: create a AgentSession wired to a faux provider.
fn createTestAgentSession(
    allocator: std.mem.Allocator,
    _: *faux.FauxProvider,
    registry: *ai.provider.Registry,
    collector: *EventCollector,
) AgentSession {
    return AgentSession.initTestSession(allocator, .{
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
    const context = try session.session_store.buildCurrentContext();
    try session.agent.setMessages(context.messages);
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

    _ = session.session_store.appendMessage(testUserMessage("hello", 1));
    _ = session.session_store.appendMessage(testAssistantMessageWithUsage(allocator, "hi", 200, 2));
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
    var session = AgentSession.initTestSession(allocator, .{
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
    try session.agent.setMessages(&messages);

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

    _ = session.session_store.appendMessage(testUserMessage("first", 1));
    _ = session.session_store.appendMessage(testAssistantMessageWithUsage(allocator, "response1", 180_000, 2));
    _ = session.session_store.appendMessage(testUserMessage("second", 3));
    const kept_user_id = session.session_store.currentEntryId().?;
    _ = session.session_store.appendMessage(testAssistantMessageWithUsage(allocator, "response2", 195_000, 4));
    session.session_store.appendCompaction("summary", kept_user_id, 195_000, null, null);
    _ = session.session_store.appendMessage(testUserMessage("third", 5));
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
    var session = AgentSession.initTestSession(allocator, .{
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
    try session.agent.setMessages(&before);
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
    try session.agent.setMessages(&after);
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

    _ = session.session_store.appendMessage(testUserMessage("first", 1));
    _ = session.session_store.appendMessage(testAssistantMessageWithUsage(allocator, "response1", 180_000, 2));
    _ = session.session_store.appendMessage(testUserMessage("second", 3));
    const kept_user_id = session.session_store.currentEntryId().?;
    _ = session.session_store.appendMessage(testAssistantMessageWithUsage(allocator, "response2", 195_000, 4));
    session.session_store.appendCompaction("summary", kept_user_id, 195_000, null, null);
    _ = session.session_store.appendMessage(testUserMessage("third", 5));
    _ = session.session_store.appendMessage(testAssistantMessageWithUsage(allocator, "response3", 25_000, 6));
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
    var ca = AgentSession.initTestSession(allocator, .{
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
    try testing.expect(std.mem.indexOf(u8, ca.agent.systemPrompt(), "Allowlisted override snippet") != null);
    try testing.expect(std.mem.indexOf(u8, ca.agent.systemPrompt(), "Read file contents") == null);
    try testing.expect(std.mem.indexOf(u8, ca.agent.systemPrompt(), "- bash:") == null);
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
    var ca = AgentSession.initTestSession(allocator, .{
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
    try testing.expectEqual(@as(usize, 4), ca.agent.messages().len);
    try testing.expect(ca.agent.messages()[2] == .tool_result);
    const tr = ca.agent.messages()[2].tool_result;
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

    var ca = AgentSession.initTestSession(allocator, .{
        .model = faux.fauxModel(),
        .api_key = "test-key",
        .cwd = "/tmp/zi-test",
        .resource_loader = createTestResourceLoaderWithAgentDir(allocator, "/tmp/zi-test", agent_dir),
        .registry = &registry,
        .no_session = true,
    });
    defer ca.deinit();

    try testing.expect(std.mem.indexOf(u8, ca.agent.systemPrompt(), "Winning read snippet") != null);
    try testing.expect(std.mem.indexOf(u8, ca.agent.systemPrompt(), "Winning read guideline") != null);
    try testing.expect(std.mem.indexOf(u8, ca.agent.systemPrompt(), "Read file contents") == null);
    try testing.expect(std.mem.indexOf(u8, ca.agent.systemPrompt(), "Use read to examine files instead of cat or sed.") == null);
}

test "AgentSession refreshes visible tools and prompt after runtime tool registration" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("extensions");
    try tmp.dir.writeFile(.{ .sub_path = "extensions/dynamic.lua", .data = "return function(zi)\n" ++
        "  zi.register_command({\n" ++
        "    name = \"add_dynamic_tool\",\n" ++
        "    description = \"add a dynamic tool\",\n" ++
        "    handler = function(args, ctx)\n" ++
        "      return zi.register_tool({\n" ++
        "        name = \"runtime_echo\",\n" ++
        "        label = \"Runtime Echo\",\n" ++
        "        description = \"registered after bind\",\n" ++
        "        prompt_snippet = \"Runtime echo prompt metadata\",\n" ++
        "        parameters = { type = \"object\", properties = {}, required = {} },\n" ++
        "        execute = function(params, ctx) return { content = { { type = \"text\", text = \"ok\" } } } end,\n" ++
        "      })\n" ++
        "    end,\n" ++
        "  })\n" ++
        "end\n" });
    const agent_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(agent_dir);

    var fp = faux.FauxProvider.init(allocator);
    defer fp.deinit();
    var registry = ai.provider.Registry.init(allocator);
    defer registry.deinit();
    try registry.register("faux", fp.provider(), null);

    var ca = AgentSession.initTestSession(allocator, .{
        .model = faux.fauxModel(),
        .api_key = "test-key",
        .cwd = "/tmp/zi-test",
        .resource_loader = createTestResourceLoaderWithAgentDir(allocator, "/tmp/zi-test", agent_dir),
        .registry = &registry,
        .no_session = true,
    });
    defer ca.deinit();
    ca.activateLifecycle();

    try testing.expect(std.mem.indexOf(u8, ca.agent.systemPrompt(), "Runtime echo prompt metadata") == null);
    try (ca.extensionRunner() orelse return error.MissingExtensionRunner).dispatchCommand("add_dynamic_tool", "");

    try testing.expect(std.mem.indexOf(u8, ca.agent.systemPrompt(), "Runtime echo prompt metadata") != null);
    var found = false;
    for (ca.tools) |tool| {
        if (std.mem.eql(u8, tool.name, "runtime_echo")) found = true;
    }
    try testing.expect(found);
}

test "AgentSession: extension ui_publication swap publishes the next runner generation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const agent_dir = try createAgentDirWithReadOverride(
        allocator,
        &tmp,
        "Reload v1 snippet",
        "Reload v1 guideline",
        "reload v1 result",
    );
    defer allocator.free(agent_dir);

    var fp = faux.FauxProvider.init(allocator);
    defer fp.deinit();
    var registry = ai.provider.Registry.init(allocator);
    defer registry.deinit();
    try registry.register("faux", fp.provider(), null);

    var ca = AgentSession.initTestSession(allocator, .{
        .model = faux.fauxModel(),
        .api_key = "test-key",
        .cwd = "/tmp/zi-test",
        .resource_loader = createTestResourceLoaderWithAgentDir(allocator, "/tmp/zi-test", agent_dir),
        .registry = &registry,
        .no_session = true,
    });
    defer ca.deinit();

    const initial_runner = ca.extensionRunner() orelse return error.MissingExtensionRunner;
    try testing.expectEqual(@as(extension_runner_mod.Generation, 0), initial_runner.generation);
    try testing.expect(std.mem.indexOf(u8, ca.agent.systemPrompt(), "Reload v1 snippet") != null);

    try writeReadOverrideExtension(
        allocator,
        &tmp,
        "Reload v2 snippet",
        "Reload v2 guideline",
        "reload v2 result",
    );
    try ca.resource_loader.reload();
    const next = try session_bootstrap.prepareExtensionRuntimeBundle(allocator, .{
        .resource_loader = ca.resource_loader,
        .session_id = ca.session_store.sessionId(),
        .extension_generation = 1,
    });
    try ca.replaceExtensionRuntimeBundleOnAgentThread(next);

    const swapped_runner = ca.extensionRunner() orelse return error.MissingExtensionRunner;
    try testing.expectEqual(@as(extension_runner_mod.Generation, 1), swapped_runner.generation);
    try testing.expect(std.mem.indexOf(u8, ca.agent.systemPrompt(), "Reload v2 snippet") != null);
    try testing.expect(std.mem.indexOf(u8, ca.agent.systemPrompt(), "Reload v1 snippet") == null);
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
    try testing.expectEqual(@as(usize, 2), ca.agent.messages().len);
    try testing.expect(ca.agent.messages()[0] == .user);
    try testing.expect(ca.agent.messages()[1] == .assistant);

    const assistant = ca.agent.messages()[1].assistant;
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
    try testing.expectEqual(@as(usize, 2), ca.agent.messages().len);
    const assistant = ca.agent.messages()[1].assistant;
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
    try testing.expectEqual(@as(usize, 4), ca.agent.messages().len);
    // user, assistant("first"), user, assistant("second")
    const a1 = ca.agent.messages()[1].assistant;
    switch (a1.content[0]) {
        .text => |t| try testing.expectEqualStrings("first", t.text),
        else => return error.ExpectedText,
    }
    const a2 = ca.agent.messages()[3].assistant;
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
    var loaded = try SessionStore.openForResume(allocator, session_file);
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
    var ca = AgentSession.initTestSession(allocator, .{
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
    try testing.expectEqual(@as(usize, 4), ca.agent.messages().len);
    try testing.expect(ca.agent.messages()[0] == .user);
    try testing.expect(ca.agent.messages()[1] == .assistant);
    try testing.expect(ca.agent.messages()[2] == .tool_result);
    try testing.expect(ca.agent.messages()[3] == .assistant);

    // Verify tool result content
    const tr = ca.agent.messages()[2].tool_result;
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
                .writer = session_runtime.writer.SessionWriter.initContinue(
                    alloc,
                    "",
                    alloc.dupe(u8, session_id) catch @panic("OOM"),
                    "",
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

    var ca = AgentSession.initTestSession(allocator, .{
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

    var ca = AgentSession.initTestSession(allocator, .{
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
    try ca.agent.setMessages(&existing);
    const old_session_id = try allocator.dupe(u8, ca.session_store.sessionId());
    defer allocator.free(old_session_id);

    try ca.startNewSession();

    try testing.expect(!std.mem.eql(u8, old_session_id, ca.session_store.sessionId()));
    try testing.expectEqual(@as(usize, 0), ca.agent.messages().len);
    try testing.expect(ca.agent.sessionId() != null);
    try testing.expectEqualStrings(ca.session_store.sessionId(), ca.agent.sessionId().?);
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

test "AgentSession: startNewSession switches ephemeral sessions onto normal persistence" {
    const allocator = testing.allocator;

    var registry = ai.provider.Registry.init(allocator);
    defer registry.deinit();

    var ca = AgentSession.initTestSession(allocator, .{
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

    try testing.expect(ca.session_store.writer.persist);
    try testing.expect(ca.session_store.sessionFile().len > 0);
    try testing.expectEqual(@as(usize, 3), ca.session_store.writer.buffered_entries.items.len);
    try testing.expect(ca.session_store.writer.buffered_entries.items[0] == .header);
    try testing.expect(ca.session_store.writer.buffered_entries.items[1].entry.entry == .model_change);
    try testing.expect(ca.session_store.writer.buffered_entries.items[2].entry.entry == .thinking_level_change);
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
    var ca1 = AgentSession.initTestSession(allocator, .{
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
    var loaded = try SessionStore.openForResume(allocator, session_file);
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

    var ca2 = AgentSession.initTestSession(allocator, .{
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

    var ca = AgentSession.initTestSession(allocator, .{
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

test "AgentSession: runUserContent forwards text and image blocks to the provider" {
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

    const blocks = try allocator.alloc(ai.protocol.UserMessage.UserMessageContent.Block, 2);
    blocks[0] = .{ .text = .{ .text = "describe this image" } };
    blocks[1] = .{ .image = .{ .data = "QUJD", .mime_type = "image/png" } };
    try ca.runUserContent(.{ .blocks = blocks });

    try testing.expectEqual(@as(usize, 1), fp.captured_contexts.items.len);
    const ctx = fp.captured_contexts.items[0];
    try testing.expect(ctx.messages[0] == .user);
    switch (ctx.messages[0].user.content) {
        .blocks => |captured| {
            try testing.expectEqual(@as(usize, 2), captured.len);
            try testing.expectEqualStrings("describe this image", captured[0].text.text);
            try testing.expectEqualStrings("QUJD", captured[1].image.data);
            try testing.expectEqualStrings("image/png", captured[1].image.mime_type);
        },
        .text => return error.ExpectedBlocks,
    }
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
    try ca.agent.setMessages(prior_messages);
    try testing.expectEqual(@as(usize, 2), ca.agent.messages().len);

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
