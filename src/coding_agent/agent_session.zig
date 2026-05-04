const std = @import("std");
const ai = @import("../ai/root.zig");
const agent_mod = @import("../agent/root.zig");
const agent_impl = @import("../agent/agent.zig");
const control_mod = @import("../agent/control.zig");
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
const message_conversion = @import("agent_session/message_conversion.zig");
const model_control = @import("agent_session/model_control.zig");
const ai_completion_runtime = @import("agent_session/ai_completion_runtime.zig");
const runtime_models = @import("agent_session/runtime_models.zig");
const runtime_binding = @import("agent_session/runtime_binding.zig");
const projection_runtime = @import("agent_session/projection_runtime.zig");
const extension_runner_mod = @import("extensions/runner.zig");
const ai_complete_worker_mod = @import("extensions/ai_complete_worker.zig");
const lua_runtime = @import("extensions/lua_runtime.zig");
const event_bridge = @import("extensions/event_bridge.zig");
const pending_extension_ui_mod = @import("agent_session/pending_extension_ui.zig");
const extension_ui = @import("extensions/ui.zig");
const session_event_mod = @import("session_event.zig");

const protocol = agent_mod.protocol;
const Agent = agent_mod.Agent;
const SubscriptionToken = agent_impl.SubscriptionToken;
pub const SessionStore = session_runtime.store.SessionStore;
pub const ExtensionRunner = extension_runner_mod.ExtensionRunner;
pub const ExtensionRunnerRef = extension_runner_mod.ExtensionRunnerRef;
pub const ContextUsage = session_core.context_usage.ContextUsage;
const PendingExtensionUi = pending_extension_ui_mod.PendingExtensionUi;
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
    pending_extension_ui: PendingExtensionUi,
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

    pub const ModelSwitchResult = model_control.ModelSwitchResult;
    pub const ThinkingLevelChangeResult = model_control.ThinkingLevelChangeResult;
    pub const StatusSnapshot = model_control.StatusSnapshot;

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
            .func = &runtime_binding.beforeToolCall,
            .ctx = @ptrCast(prepared.extension_runner_ref),
        };
        const after_tool_hook: ?protocol.AfterToolCallHook = .{
            .func = &runtime_binding.afterToolCall,
            .ctx = @ptrCast(prepared.extension_runner_ref),
        };

        const agent = Agent.init(allocator, .{
            .system_prompt = prepared.system_prompt,
            .model = options.model,
            .tools = prepared.tools,
            .messages = options.initial_messages,
            .thinking_level = options.thinking_level orelse .off,
            .io = prepared.stream_closure.io,
            .convert_to_llm = .{ .func = &message_conversion.convertToLlm, .ctx = null },
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
            .pending_extension_ui = PendingExtensionUi.init(allocator),
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

    pub fn trySetModel(self: *AgentSession, model: ai.protocol.Model) ModelSwitchResult {
        return model_control.trySetModel(self, model);
    }

    pub fn trySetThinkingLevel(self: *AgentSession, level: protocol.ThinkingLevel) ThinkingLevelChangeResult {
        return model_control.trySetThinkingLevel(self, level);
    }

    pub fn getAvailableThinkingLevelsForModel(model: ai.protocol.Model) []const protocol.ThinkingLevel {
        return model_control.availableThinkingLevelsForModel(model);
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
            model_control.agentThinkingLevelToString(self.agent.thinkingLevel()),
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

    pub fn rebuildVisibleModelCatalogFromActiveProviders(self: *AgentSession) !void {
        try projection_runtime.rebuildVisibleModelCatalogFromActiveProviders(self);
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
        self.pending_extension_ui.deinit();
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
            ctx.deinit(self.allocator);
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
                    &runtime_binding.agentEventSink,
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
        runtime_binding.bind(self, runner);
    }

    pub fn resolveModelRef(self: *AgentSession, model_ref: []const u8) ?ai.protocol.Model {
        return runtime_models.resolveModelRef(self, model_ref);
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

    pub fn takePendingExtensionReport(self: *AgentSession) ?extension_ui.Report {
        return self.pending_extension_ui.takeReport();
    }

    pub fn pendingExtensionPromptCount(self: *const AgentSession) usize {
        return self.pending_extension_ui.promptCount();
    }

    pub fn takePendingExtensionUiPublications(self: *AgentSession, allocator: std.mem.Allocator) ![]extension_ui.UiPublication {
        return self.pending_extension_ui.takeUiPublications(allocator);
    }

    pub fn takePendingExtensionSurfaceUpdates(self: *AgentSession, allocator: std.mem.Allocator) ![]extension_ui.SurfaceUpdate {
        return self.pending_extension_ui.takeSurfaceUpdates(allocator);
    }

    pub fn takePendingExtensionEditorActions(self: *AgentSession, allocator: std.mem.Allocator) ![]extension_ui.EditorAction {
        return self.pending_extension_ui.takeEditorActions(allocator);
    }

    fn flushPendingToolProjectionRefresh(self: *AgentSession) void {
        projection_runtime.flushPendingToolProjectionRefresh(self);
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
                .timestamp = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds(),
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
        return ai_completion_runtime.buildWorkerRequest(self, allocator, id, request);
    }

    pub fn completeUserText(
        self: *AgentSession,
        allocator: std.mem.Allocator,
        system_prompt: ?[]const u8,
        prompt_text: []const u8,
        max_tokens: u64,
    ) ![]u8 {
        return ai_completion_runtime.completeUserText(self, allocator, system_prompt, prompt_text, max_tokens);
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

    // pi-mono injects auth in the streamFn closure (sdk.ts:274-283).
    // We do the same: capture registry + api_key so the Agent doesn't need
    // to thread auth through AgentLoopConfig.

};

pub const convertToLlm = message_conversion.convertToLlm;

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
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "extensions/read.lua", .data = src });
}

fn createAgentDirWithReadOverride(
    allocator: std.mem.Allocator,
    tmp: *std.testing.TmpDir,
    snippet: []const u8,
    guideline: []const u8,
    result_text: []const u8,
) ![]const u8 {
    try tmp.dir.createDir(std.Options.debug_io, "extensions", .default_dir);
    try writeReadOverrideExtension(allocator, tmp, snippet, guideline, result_text);
    return tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
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
    var args_obj: std.json.ObjectMap = .{};
    try args_obj.put(allocator, try allocator.dupe(u8, "path"), .{ .string = try allocator.dupe(u8, "/tmp/ignored") });
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

test "AgentSession refreshes visible tools and prompt after runtime tool registration" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.Options.debug_io, "extensions", .default_dir);
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "extensions/dynamic.lua", .data = "return function(zi)\n" ++
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
    const agent_dir = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
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

    try testing.expect(ca.sessionFlushed());
    const session_file = ca.getSessionFile();

    var loaded = try SessionStore.openForResume(allocator, session_file);
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 2), loaded.messages.len);

    try testing.expect(loaded.messages[0] == .user);
    switch (loaded.messages[0].user.content) {
        .text => |t| try testing.expectEqualStrings("persist me", t),
        .blocks => |b| {
            try testing.expectEqual(@as(usize, 1), b.len);
            try testing.expectEqualStrings("persist me", b[0].text.text);
        },
    }

    try testing.expect(loaded.messages[1] == .assistant);
    const a = loaded.messages[1].assistant;
    try testing.expectEqual(@as(usize, 1), a.content.len);
    switch (a.content[0]) {
        .text => |t| try testing.expectEqualStrings("persisted response", t.text),
        else => return error.ExpectedTextBlock,
    }

    std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, session_file) catch {};
}

test "AgentSession: tool call triggers execution and second LLM call" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fp = faux.FauxProvider.init(allocator);

    const tc_content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{
        faux.fauxToolCall("echo", "tc-1", .null),
    };
    const text_content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("done after tool")};
    fp.setResponses(&.{
        faux.fauxAssistantMessage(allocator, &tc_content, .toolUse),
        faux.fauxAssistantMessage(allocator, &text_content, .stop),
    });

    var registry = ai.provider.Registry.init(allocator);
    try registry.register("faux", fp.provider(), null);

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

    try testing.expectEqual(@as(usize, 2), fp.call_count);

    try testing.expectEqual(@as(usize, 4), ca.agent.messages().len);
    try testing.expect(ca.agent.messages()[0] == .user);
    try testing.expect(ca.agent.messages()[1] == .assistant);
    try testing.expect(ca.agent.messages()[2] == .tool_result);
    try testing.expect(ca.agent.messages()[3] == .assistant);

    const tr = ca.agent.messages()[2].tool_result;
    try testing.expectEqualStrings("echo", tr.tool_name);
    try testing.expectEqual(@as(usize, 1), tr.content.len);

    try testing.expect(collector.countType(.tool_execution_start) >= 1);
    try testing.expect(collector.countType(.tool_execution_end) >= 1);
}

test "AgentSession: startNewSession resets transcript and changes session id" {
    const allocator = testing.allocator;

    var registry = ai.provider.Registry.init(allocator);
    defer registry.deinit();

    var ca = AgentSession.initTestSession(allocator, .{
        .model = faux.fauxModel(),
        .cwd = "/tmp/zi-test",
        .resource_loader = createTestResourceLoader(allocator, "/tmp/zi-test"),
        .registry = &registry,
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
}

test "AgentSession: continue sends restored context to provider" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

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

    var loaded = try SessionStore.openForResume(allocator, session_file);
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 2), loaded.messages.len);

    var fp2 = faux.FauxProvider.init(allocator);
    const c2 = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("continued response")};
    fp2.setResponses(&.{faux.fauxAssistantMessage(allocator, &c2, .stop)});

    var reg2 = ai.provider.Registry.init(allocator);
    try reg2.register("faux", fp2.provider(), null);

    var col2 = EventCollector.init(allocator);
    const new_user = protocol.AgentMessage{ .user = .{
        .content = .{ .text = "follow up" },
        .timestamp = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds(),
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

    try ca2.continueSession();

    try testing.expectEqual(@as(usize, 1), fp2.call_count);

    try testing.expectEqual(@as(usize, 1), fp2.captured_contexts.items.len);
    const ctx = fp2.captured_contexts.items[0];
    try testing.expect(ctx.messages.len >= 3);

    std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, session_file) catch {};
}

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

    try ca.continueSession();

    try testing.expectEqual(@as(usize, 1), fp.call_count);
    try testing.expectEqual(@as(usize, 1), fp.captured_contexts.items.len);

    const ctx = fp.captured_contexts.items[0];
    try testing.expectEqual(@as(usize, 2), ctx.messages.len);
    try testing.expect(ctx.messages[0] == .user);
    try testing.expect(ctx.messages[1] == .user);

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
    // v1: all null. v2: runner populates before dispatching commands.

    wait_for_idle: ?*const fn (ctx: *anyopaque) anyerror!void = null,
    new_session: ?*const fn (ctx: *anyopaque, opts: *const anyopaque) anyerror!void = null,
    fork: ?*const fn (ctx: *anyopaque, entry_id: []const u8) anyerror!void = null,
    navigate_tree: ?*const fn (ctx: *anyopaque, target_id: []const u8) anyerror!void = null,
    switch_session: ?*const fn (ctx: *anyopaque, path: []const u8) anyerror!void = null,
    reload: ?*const fn (ctx: *anyopaque) anyerror!void = null,
};
