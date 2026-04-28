const std = @import("std");
const agent_mod = @import("../agent3/root.zig");
const control_mod = @import("../agent3/control.zig");
const ai = @import("../ai/root.zig");
const json_util = @import("../ai/json_util.zig");
const agent_session_mod = @import("agent_session.zig");
const AgentSession = agent_session_mod.AgentSession;
const extension_ui = @import("extensions/ui.zig");
const sdk = @import("sdk.zig");
const resolve_mod = @import("resolve.zig");
const session_runner = @import("session_runner.zig");
const conversation_state = @import("../agent3/conversation_state.zig");
const auth_types = @import("auth/types.zig");
const oauth_mod = @import("auth/oauth.zig");
const theme_mod = @import("../tui/theme.zig");
const themes_builtin = @import("../themes/builtin.zig");
const session_event_mod = @import("session_event.zig");
const extension_runner_mod = @import("extensions/runner.zig");
const request_mod = @import("request.zig");
const event_bridge = @import("extensions/event_bridge.zig");
const session_bootstrap = @import("session_bootstrap.zig");
const profile = @import("../debug/profile.zig");

pub const QueueKind = control_mod.QueueKind;
pub const EnqueueResult = control_mod.EnqueueResult;
pub const QueuedMessageText = control_mod.QueuedMessageText;
pub const QueuedMessageSnapshot = control_mod.QueuedMessageSnapshot;

pub const RunOutcome = session_runner.RunOutcome;
pub const RetryStart = session_runner.RetryStart;
pub const RetryEnd = session_runner.RetryEnd;
pub const CompactionReason = session_runner.CompactionReason;
pub const CompactionStart = session_runner.CompactionStart;
pub const CompactionEnd = session_runner.CompactionEnd;
pub const SessionEvent = session_event_mod.SessionEvent;
pub const RetryPolicy = session_runner.RetryPolicy;
pub const CompactionPolicy = session_runner.CompactionPolicy;
pub const CompactionResult = session_runner.CompactionResult;
pub const CompactionExecutor = session_runner.CompactionExecutor;
pub const LifecycleHooks = session_runner.LifecycleHooks;
pub const Options = session_runner.Options;

pub const ConversationSnapshotPublisher = struct {
    func: *const fn (envelope: conversation_state.ConversationSnapshotEnvelope, ctx: ?*anyopaque) bool,
    ctx: ?*anyopaque = null,

    pub fn publish(self: ConversationSnapshotPublisher, envelope: conversation_state.ConversationSnapshotEnvelope) bool {
        return self.func(envelope, self.ctx);
    }
};
pub const QueuedSnapshotPublisher = struct {
    func: *const fn (snapshot: control_mod.QueuedMessageSnapshot, ctx: ?*anyopaque) bool,
    ctx: ?*anyopaque = null,

    pub fn publish(self: QueuedSnapshotPublisher, snapshot: control_mod.QueuedMessageSnapshot) bool {
        return self.func(snapshot, self.ctx);
    }
};

pub const ExtensionOAuthRefreshDispatcher = struct {
    func: *const fn (
        provider_id: []const u8,
        credential: auth_types.OAuthCredential,
        result_allocator: std.mem.Allocator,
        ctx: ?*anyopaque,
    ) oauth_mod.ExchangeResult,
    ctx: ?*anyopaque = null,

    pub fn dispatch(
        self: ExtensionOAuthRefreshDispatcher,
        provider_id: []const u8,
        credential: auth_types.OAuthCredential,
        result_allocator: std.mem.Allocator,
    ) oauth_mod.ExchangeResult {
        return self.func(provider_id, credential, result_allocator, self.ctx);
    }
};

pub const RuntimeHost = struct {
    session: *AgentSession,
    session_allocator: std.mem.Allocator,
    msg_allocator: std.mem.Allocator,
    create_options: sdk.CreateOptions,
    runner: session_runner.SessionRunner,
    agent_event_listeners: std.ArrayList(AgentEventHandler),
    session_event_listeners: std.ArrayList(EventHandler),
    agent_event_token: ?AgentSession.AgentEventSubscriptionToken = null,
    session_event_token: ?AgentSession.EventSubscriptionToken = null,
    next_extension_generation: extension_runner_mod.Generation,
    session_generation: u64 = 1,
    extension_oauth_refresh_dispatcher: ?ExtensionOAuthRefreshDispatcher = null,

    pub const AgentEventHandler = struct {
        func: *const fn (event: agent_mod.protocol.AgentEvent, ctx: ?*anyopaque) void,
        ctx: ?*anyopaque = null,
    };

    pub const EventHandler = struct {
        func: *const fn (event: SessionEvent, ctx: ?*anyopaque) void,
        ctx: ?*anyopaque = null,
    };

    pub const AgentEventSubscriptionToken = struct {
        index: usize,
    };

    pub const EventSubscriptionToken = struct {
        index: usize,
    };

    pub fn init(
        session: *AgentSession,
        session_allocator: std.mem.Allocator,
        msg_allocator: std.mem.Allocator,
        create_options: sdk.CreateOptions,
        options: Options,
    ) !RuntimeHost {
        var self: RuntimeHost = .{
            .session = session,
            .session_allocator = session_allocator,
            .msg_allocator = msg_allocator,
            .create_options = create_options,
            .runner = session_runner.SessionRunner.init(options),
            .agent_event_listeners = .empty,
            .session_event_listeners = .empty,
            .next_extension_generation = nextExtensionGenerationFor(session),
            .session_generation = 1,
        };
        self.bindAuthStorageHooks(session);
        self.activateSessionLifecycle(.startup, null, null);
        return self;
    }

    pub fn deinit(self: *RuntimeHost) void {
        self.clearAuthStorageHooks(self.session);
        self.shutdownSessionLifecycle(.exit, null, null);
        self.session.deinit();
        self.session_allocator.destroy(self.session);
        self.agent_event_listeners.deinit(self.session_allocator);
        self.session_event_listeners.deinit(self.session_allocator);
        self.* = undefined;
    }

    pub fn shutdownCurrentSessionOnAgentThread(self: *RuntimeHost) void {
        self.shutdownSessionLifecycle(.exit, null, null);
    }

    pub fn currentSession(self: *RuntimeHost) *AgentSession {
        return self.session;
    }

    /// Dispatch an extension command on the agent thread by visible
    /// invocation name. Errors if no runner or no such command.
    pub fn dispatchExtensionCommand(self: *RuntimeHost, name: []const u8, args: []const u8) !void {
        const runner = self.session.extensionRunner() orelse return error.MissingExtensionRunner;
        try runner.dispatchCommand(name, args);
    }

    pub fn deliverExtensionAsyncResult(self: *RuntimeHost, id: extension_runner_mod.AsyncOpId, result: extension_runner_mod.AsyncResult) !void {
        var original = result;
        defer original.deinit(self.msg_allocator);
        const runner = self.session.extensionRunner() orelse return error.MissingExtensionRunner;
        const owned = try result.clone(runner.allocator);
        errdefer {
            var failed = owned;
            failed.deinit(runner.allocator);
        }
        try runner.resumeAsync(id, owned);
    }

    pub fn takePendingExtensionReport(self: *RuntimeHost, allocator: std.mem.Allocator) ?extension_ui.Report {
        var report = self.session.takePendingExtensionReport() orelse return null;
        defer report.deinit(self.session.allocator);
        return extension_ui.Report.clone(allocator, report) catch null;
    }

    pub fn takePendingExtensionRuntimeBundles(self: *RuntimeHost, allocator: std.mem.Allocator) []extension_ui.UiPublication {
        return self.session.takePendingExtensionRuntimeBundles(allocator) catch allocator.alloc(extension_ui.UiPublication, 0) catch &.{};
    }

    pub fn takePendingExtensionEditorActions(self: *RuntimeHost, allocator: std.mem.Allocator) []extension_ui.EditorAction {
        return self.session.takePendingExtensionEditorActions(allocator) catch allocator.alloc(extension_ui.EditorAction, 0) catch &.{};
    }

    pub fn reloadExtensionsOnAgentThread(self: *RuntimeHost) !void {
        if (self.session.agent.isStreaming() or self.session.agent.hasQueuedMessages()) return error.SessionBusy;
        if (self.session.extensionRunner()) |runner| {
            if (!runner.isReloadIdle()) return error.SessionBusy;
        }

        try self.session.resource_loader.reload();
        const next = try session_bootstrap.prepareExtensionRuntimeBundle(self.session_allocator, .{
            .resource_loader = self.session.resource_loader,
            .settings_manager = self.create_options.settings_manager,
            .tools = self.create_options.tools,
            .tool_allowlist = self.create_options.tool_allowlist,
            .session_id = self.session.session_store.sessionId(),
            .extension_generation = self.reserveExtensionGeneration(),
        });
        try self.session.replaceExtensionRuntimeBundleOnAgentThread(next);
    }

    pub fn dispatchExtensionOAuthLogin(self: *RuntimeHost, provider_id: []const u8, callbacks: request_mod.ExtensionOAuthLoginCallbacks) !request_mod.ExtensionOAuthLoginResponse.Result {
        const runner = self.session.extensionRunner() orelse return error.MissingExtensionRunner;
        return runner.dispatchOAuthLogin(provider_id, callbacks, self.msg_allocator);
    }

    pub fn dispatchExtensionOAuthRefresh(self: *RuntimeHost, provider_id: []const u8, credential: auth_types.OAuthCredential, allocator: std.mem.Allocator) !oauth_mod.ExchangeResult {
        const runner = self.session.extensionRunner() orelse return error.MissingExtensionRunner;
        if (runner.isOnLuaThread()) {
            return runner.dispatchOAuthRefresh(provider_id, credential, allocator);
        }
        if (self.extension_oauth_refresh_dispatcher) |dispatcher| {
            return dispatcher.dispatch(provider_id, credential, allocator);
        }
        return error.ExtensionOAuthRefreshRequiresAgentThread;
    }

    pub fn selectedTheme(self: *const RuntimeHost) theme_mod.Theme {
        if (self.create_options.settings_manager) |settings| {
            if (settings.getTheme()) |selected_name| {
                if (self.session.resource_loader.findThemeByName(selected_name)) |loaded| {
                    return loaded.theme;
                }
            }
        }

        const fallback_name: []const u8 = switch (theme_mod.Theme.detectTerminalBackground()) {
            .dark => "dark",
            .light => "light",
        };
        if (self.session.resource_loader.findThemeByName(fallback_name)) |loaded| {
            return loaded.theme;
        }

        return themes_builtin.defaultForTerminal().*;
    }

    pub fn subscribeAgentEvents(
        self: *RuntimeHost,
        func: *const fn (event: agent_mod.protocol.AgentEvent, ctx: ?*anyopaque) void,
        ctx: ?*anyopaque,
    ) AgentEventSubscriptionToken {
        self.bindAgentEvents();
        const index = self.agent_event_listeners.items.len;
        self.agent_event_listeners.append(self.session_allocator, .{ .func = func, .ctx = ctx }) catch return .{ .index = std.math.maxInt(usize) };
        return .{ .index = index };
    }

    pub fn unsubscribeAgentEvents(self: *RuntimeHost, token: AgentEventSubscriptionToken) void {
        if (token.index < self.agent_event_listeners.items.len) {
            _ = self.agent_event_listeners.orderedRemove(token.index);
        }
    }

    pub fn subscribeEvents(
        self: *RuntimeHost,
        func: *const fn (event: SessionEvent, ctx: ?*anyopaque) void,
        ctx: ?*anyopaque,
    ) EventSubscriptionToken {
        self.bindSessionEvents();
        const index = self.session_event_listeners.items.len;
        self.session_event_listeners.append(self.session_allocator, .{ .func = func, .ctx = ctx }) catch return .{ .index = std.math.maxInt(usize) };
        return .{ .index = index };
    }

    pub fn unsubscribeEvents(self: *RuntimeHost, token: EventSubscriptionToken) void {
        if (token.index < self.session_event_listeners.items.len) {
            _ = self.session_event_listeners.orderedRemove(token.index);
        }
    }

    pub fn setLifecycleHooks(self: *RuntimeHost, hooks: LifecycleHooks) void {
        self.runner.setLifecycleHooks(hooks);
    }

    pub fn setCompactionExecutor(self: *RuntimeHost, executor: ?CompactionExecutor) void {
        self.runner.setCompactionExecutor(executor);
    }

    pub fn setExtensionOAuthRefreshDispatcher(self: *RuntimeHost, dispatcher: ?ExtensionOAuthRefreshDispatcher) void {
        self.extension_oauth_refresh_dispatcher = dispatcher;
    }

    /// Agent-thread-only helper for the queued-input restore flow.
    pub fn restoreQueuedMessagesOnAgentThread(self: *RuntimeHost, allocator: std.mem.Allocator) !QueuedMessageSnapshot {
        return self.session.restoreQueuedMessagesOnAgentThread(allocator);
    }

    /// Thread-safe run-control enqueue. Callable from any thread while a
    /// run is active — this is the point of the run-control boundary.
    /// `text` is not retained; the agent clones it into an owned message.
    pub fn enqueueQueuedText(
        self: *RuntimeHost,
        kind: control_mod.QueueKind,
        text: []const u8,
    ) control_mod.EnqueueResult {
        const message: agent_mod.protocol.AgentMessage = .{ .user = .{
            .content = .{ .text = text },
            .timestamp = std.time.milliTimestamp(),
        } };
        return switch (kind) {
            .steering => self.session.agent.steer(message),
            .follow_up => self.session.agent.followUp(message),
        };
    }

    /// Thread-safe read of the current run-control queue state.
    pub fn snapshotQueuedMessages(self: *RuntimeHost, allocator: std.mem.Allocator) !QueuedMessageSnapshot {
        return self.session.cloneQueuedMessageSnapshot(allocator);
    }

    /// Thread-safe atomic drain: returns what was queued and clears the
    /// queues in a single run-control mutation.
    pub fn takeQueuedMessagesAndClear(self: *RuntimeHost, allocator: std.mem.Allocator) !QueuedMessageSnapshot {
        return self.session.restoreQueuedMessagesOnAgentThread(allocator);
    }

    pub fn currentQueuedVersion(self: *const RuntimeHost) u64 {
        return self.session.agent.currentQueuedVersion();
    }

    pub fn abortRetry(self: *RuntimeHost) void {
        self.runner.abortRetry(self.session);
    }

    pub fn abortCurrentRun(self: *RuntimeHost) void {
        self.session.agent.abort();
    }

    pub const ResumeResult = struct {
        restore_warning: ?[]u8 = null,
    };

    pub fn newSession(self: *RuntimeHost) !void {
        var create_options = self.create_options;
        create_options.cwd = self.session.resource_loader.cwd;
        create_options.model = self.session.agent.modelValue();
        create_options.initial_messages = &.{};
        create_options.thinking_level = self.session.agent.thinkingLevel();

        var new_store = try agent_session_mod.SessionStore.createForCwd(self.session_allocator, create_options.cwd, create_options.agent_dir_override);
        var owns_new_store = true;
        errdefer if (owns_new_store) new_store.deinit();
        create_options.session_store = new_store;

        const next = try self.createOwnedSession(create_options);
        owns_new_store = false;
        next.session_store.appendRuntimeDefaults(
            json_util.providerToString(next.agent.modelValue().provider),
            next.agent.modelValue().id,
            thinkingLevelToString(next.agent.thinkingLevel()),
        );
        try self.replaceSession(next, .new, null);
    }

    pub fn forkSession(self: *RuntimeHost, entry_id: []const u8) !void {
        var create_options = self.create_options;
        create_options.cwd = self.session.resource_loader.cwd;
        create_options.model = self.session.agent.modelValue();
        create_options.initial_messages = &.{};
        create_options.thinking_level = self.session.agent.thinkingLevel();

        var new_store = try agent_session_mod.SessionStore.createForCwd(self.session_allocator, create_options.cwd, create_options.agent_dir_override);
        var owns_new_store = true;
        errdefer if (owns_new_store) new_store.deinit();
        create_options.session_store = new_store;

        const next = try self.createOwnedSession(create_options);
        owns_new_store = false;
        next.session_store.appendRuntimeDefaults(
            json_util.providerToString(next.agent.modelValue().provider),
            next.agent.modelValue().id,
            thinkingLevelToString(next.agent.thinkingLevel()),
        );

        const current_ctx = lifecycleContext(self.session);
        if (current_ctx) |ctx| {
            var cancel_result = event_bridge.dispatchSessionBeforeFork(ctx, entry_id, self.msg_allocator) catch |err| {
                next.deinit();
                self.session_allocator.destroy(next);
                return err;
            };
            if (cancel_result.blocked) {
                next.deinit();
                self.session_allocator.destroy(next);
                cancel_result.deinit(self.msg_allocator);
                return error.SessionBeforeForkBlocked;
            }
            cancel_result.deinit(self.msg_allocator);
        }

        try self.replaceSession(next, .fork, entry_id);
    }

    pub fn resumeSession(self: *RuntimeHost, path: []const u8, restore_session_model: bool) !ResumeResult {
        var loaded = try agent_session_mod.SessionStore.openForResume(self.session_allocator, path);
        defer loaded.deinit();

        const loaded_store = loaded.store.?;
        if (std.mem.eql(u8, loaded_store.sessionId(), self.session.session_store.sessionId())) {
            return error.SessionAlreadyActive;
        }

        var create_options = self.create_options;
        create_options.cwd = loaded_store.cwd();
        create_options.initial_messages = loaded.messages;
        create_options.thinking_level = parseThinkingLevel(loaded.thinking_level);

        var restore_warning: ?[]u8 = null;
        create_options.model = self.session.agent.modelValue();
        if (restore_session_model) {
            if (loaded.model) |saved| {
                if (self.session.model_registry) |registry| {
                    const restore = resolve_mod.restoreModelFromSession(.{
                        .saved_provider = saved.provider,
                        .saved_model_id = saved.model_id,
                        .current_model = create_options.model,
                        .registry = registry,
                        .allocator = self.msg_allocator,
                    }) catch resolve_mod.RestoreResult{ .model = null, .fallback_message = null };
                    if (restore.model) |model| create_options.model = model;
                    restore_warning = restore.fallback_message;
                }
            }
        }

        var new_store = loaded.takeStore();
        var owns_new_store = true;
        errdefer if (owns_new_store) new_store.deinit();
        create_options.session_store = new_store;

        const next = try self.createOwnedSession(create_options);
        owns_new_store = false;
        try self.replaceSession(next, .@"resume", null);
        return .{ .restore_warning = restore_warning };
    }

    pub fn runUserContent(self: *RuntimeHost, content: ai.protocol.UserMessage.UserMessageContent) !RunOutcome {
        const runner = self.session.extensionRunner();
        if (runner) |extension_runner| {
            if (content == .text) {
                switch (event_bridge.dispatchInput(extension_runner, content.text, null, self.msg_allocator) catch .continue_) {
                    .continue_ => {},
                    .transform => |text| return self.runner.runUserContent(self.session, self.runnerEventEmitter(), .{ .text = text }),
                    .handled => return .success,
                    .blocked => return .success,
                }
            }
        }
        return self.runner.runUserContent(self.session, self.runnerEventEmitter(), content);
    }

    pub fn continueTurn(self: *RuntimeHost) !RunOutcome {
        return self.runner.continueTurn(self.session, self.runnerEventEmitter());
    }

    pub fn runCompaction(
        self: *RuntimeHost,
        reason: CompactionReason,
        will_retry: bool,
        run_ctx: session_runner.CompactionRunContext,
    ) !CompactionResult {
        return self.runner.runCompaction(self.session, self.runnerEventEmitter(), reason, will_retry, run_ctx);
    }

    pub fn publishConversationState(
        self: *RuntimeHost,
        publisher: ConversationSnapshotPublisher,
    ) bool {
        var publish_timer = profile.ScopedTimer.begin(.publish_conversation_state);
        defer publish_timer.end();

        var view = self.session.agent.cloneConversationView(self.msg_allocator) catch return false;
        errdefer view.deinit(self.msg_allocator);

        const envelope = conversation_state.ConversationSnapshotEnvelope{
            .session_generation = self.session_generation,
            .conversation_version = self.session.agent.currentConversationVersion(),
            .view = view,
        };
        if (!publisher.publish(envelope)) return false;
        return true;
    }

    pub fn publishQueuedSnapshot(
        self: *RuntimeHost,
        publisher: QueuedSnapshotPublisher,
    ) bool {
        var snapshot = self.session.cloneQueuedMessageSnapshot(self.msg_allocator) catch return false;
        errdefer snapshot.deinit(self.msg_allocator);

        if (!publisher.publish(snapshot)) return false;
        return true;
    }

    fn bindAgentEvents(self: *RuntimeHost) void {
        if (self.agent_event_token != null) return;
        self.agent_event_token = self.session.subscribeAgentEvents(&agentEventBridge, @ptrCast(self));
    }

    fn unbindAgentEvents(self: *RuntimeHost) void {
        if (self.agent_event_token) |token| {
            self.session.unsubscribeAgentEvents(token);
            self.agent_event_token = null;
        }
    }

    fn bindSessionEvents(self: *RuntimeHost) void {
        if (self.session_event_token != null) return;
        self.session_event_token = self.session.subscribeEvents(&sessionEventBridge, @ptrCast(self));
    }

    fn unbindSessionEvents(self: *RuntimeHost) void {
        if (self.session_event_token) |token| {
            self.session.unsubscribeEvents(token);
            self.session_event_token = null;
        }
    }

    fn emitAgentEvent(self: *RuntimeHost, event: agent_mod.protocol.AgentEvent) void {
        for (self.agent_event_listeners.items) |handler| {
            handler.func(event, handler.ctx);
        }
    }

    fn emitSessionEvent(self: *RuntimeHost, event: SessionEvent) void {
        for (self.session_event_listeners.items) |handler| {
            handler.func(event, handler.ctx);
        }
    }

    fn agentEventBridge(event: agent_mod.protocol.AgentEvent, ctx: ?*anyopaque) void {
        const self: *RuntimeHost = @ptrCast(@alignCast(ctx.?));
        self.emitAgentEvent(event);
    }

    fn sessionEventBridge(event: SessionEvent, ctx: ?*anyopaque) void {
        const self: *RuntimeHost = @ptrCast(@alignCast(ctx.?));
        self.emitSessionEvent(event);
    }

    fn runnerSessionEventBridge(event: SessionEvent, ctx: ?*anyopaque) void {
        const self: *RuntimeHost = @ptrCast(@alignCast(ctx.?));
        self.session.emitSessionEvent(event);
    }

    fn createOwnedSession(self: *RuntimeHost, create_options: sdk.CreateOptions) !*AgentSession {
        var next_options = create_options;
        next_options.extension_generation = self.reserveExtensionGeneration();

        const session = try self.session_allocator.create(AgentSession);
        errdefer self.session_allocator.destroy(session);
        session.* = try sdk.createAgentSession(self.session_allocator, next_options);
        return session;
    }

    fn activateSessionLifecycle(
        self: *RuntimeHost,
        reason: event_bridge.SessionLifecycleReason,
        previous: ?event_bridge.LifecyclePeer,
        fork_parent_entry_id: ?[]const u8,
    ) void {
        self.session.activateLifecycle();
        self.emitExtensionSessionStart(reason, previous, fork_parent_entry_id);
        if (self.agent_event_listeners.items.len > 0) self.bindAgentEvents();
        if (self.session_event_listeners.items.len > 0) self.bindSessionEvents();
    }

    fn shutdownSessionLifecycle(
        self: *RuntimeHost,
        reason: event_bridge.SessionLifecycleReason,
        next: ?event_bridge.SessionLifecycleContext,
        fork_parent_entry_id: ?[]const u8,
    ) void {
        self.emitExtensionSessionShutdown(reason, next, fork_parent_entry_id);
        self.unbindAgentEvents();
        self.unbindSessionEvents();
        self.session.shutdownLifecycleOnAgentThread();
    }

    fn reserveExtensionGeneration(self: *RuntimeHost) extension_runner_mod.Generation {
        const generation = self.next_extension_generation;
        std.debug.assert(generation < std.math.maxInt(extension_runner_mod.Generation));
        self.next_extension_generation += 1;
        return generation;
    }

    fn nextExtensionGenerationFor(session: *AgentSession) extension_runner_mod.Generation {
        const runner = session.extensionRunner() orelse return 0;
        return runner.generation + 1;
    }

    fn replaceSession(
        self: *RuntimeHost,
        next: *AgentSession,
        reason: event_bridge.SessionLifecycleReason,
        fork_parent_entry_id: ?[]const u8,
    ) !void {
        const old = self.session;
        const previous_ctx = lifecycleContext(old);
        const successor = lifecycleContext(next);

        if (previous_ctx) |ctx| {
            if (reason != .fork) {
                var cancel_result = event_bridge.dispatchSessionBeforeSwitch(ctx, successor, reason, self.msg_allocator) catch |err| {
                    next.deinit();
                    self.session_allocator.destroy(next);
                    return err;
                };
                if (cancel_result.blocked) {
                    next.deinit();
                    self.session_allocator.destroy(next);
                    cancel_result.deinit(self.msg_allocator);
                    return error.SessionBeforeSwitchBlocked;
                }
                cancel_result.deinit(self.msg_allocator);
            }
        }
        var previous_snapshot: ?event_bridge.SessionLifecycleSnapshot = null;
        if (previous_ctx) |ctx| {
            previous_snapshot = event_bridge.snapshotLifecycleContext(ctx, self.msg_allocator) catch |err| {
                next.deinit();
                self.session_allocator.destroy(next);
                return err;
            };
        }
        errdefer if (previous_snapshot) |*snap| snap.deinit();

        self.emitExtensionSessionShutdown(reason, successor, fork_parent_entry_id);
        self.unbindAgentEvents();
        self.unbindSessionEvents();
        old.shutdownLifecycleOnAgentThread();
        if (old.auth_storage != next.auth_storage) self.clearAuthStorageHooks(old);
        self.session = next;
        self.bindAuthStorageHooks(next);
        self.session_generation += 1;
        self.activateSessionLifecycle(reason, if (previous_snapshot) |*snap| .{ .snapshot = snap } else null, fork_parent_entry_id);
        if (previous_snapshot) |*snap| snap.deinit();
        old.deinit();
        self.session_allocator.destroy(old);
    }

    fn emitExtensionSessionStart(
        self: *RuntimeHost,
        reason: event_bridge.SessionLifecycleReason,
        previous: ?event_bridge.LifecyclePeer,
        fork_parent_entry_id: ?[]const u8,
    ) void {
        const current = lifecycleContext(self.session) orelse return;
        event_bridge.dispatchSessionStart(current, previous, reason, fork_parent_entry_id) catch |err| {
            std.log.scoped(.zi_bridge).warn("session_start dispatch failed: {s}", .{@errorName(err)});
        };
    }

    fn emitExtensionSessionShutdown(
        self: *RuntimeHost,
        reason: event_bridge.SessionLifecycleReason,
        next: ?event_bridge.SessionLifecycleContext,
        fork_parent_entry_id: ?[]const u8,
    ) void {
        const current = lifecycleContext(self.session) orelse return;
        event_bridge.dispatchSessionShutdown(current, next, reason, fork_parent_entry_id) catch |err| {
            std.log.scoped(.zi_bridge).warn("session_shutdown dispatch failed: {s}", .{@errorName(err)});
        };
    }

    fn lifecycleContext(session: *AgentSession) ?event_bridge.SessionLifecycleContext {
        const runner = session.extensionRunner() orelse return null;
        const session_file = session.getSessionFile();
        return .{
            .runner = runner,
            .workspace_id = session.resource_loader.cwd,
            .session_id = session.session_store.sessionId(),
            .session_file = if (session_file.len == 0) null else session_file,
        };
    }

    fn runnerEventEmitter(self: *RuntimeHost) session_runner.EventEmitter {
        return .{
            .func = &runnerSessionEventBridge,
            .ctx = @ptrCast(self),
        };
    }

    fn bindAuthStorageHooks(self: *RuntimeHost, session: *AgentSession) void {
        const auth = session.auth_storage orelse return;
        auth.setExtensionOAuthRefreshHook(.{
            .func = &dispatchExtensionOAuthRefreshFromAuthStorage,
            .ctx = @ptrCast(self),
        });
    }

    fn clearAuthStorageHooks(self: *RuntimeHost, session: *AgentSession) void {
        _ = self;
        const auth = session.auth_storage orelse return;
        auth.setExtensionOAuthRefreshHook(null);
    }

    fn dispatchExtensionOAuthRefreshFromAuthStorage(
        provider: []const u8,
        credential: auth_types.OAuthCredential,
        allocator: std.mem.Allocator,
        ctx: ?*anyopaque,
    ) oauth_mod.ExchangeResult {
        const self: *RuntimeHost = @ptrCast(@alignCast(ctx.?));
        return self.dispatchExtensionOAuthRefresh(provider, credential, allocator) catch |err| .{ .err = @errorName(err) };
    }
};

fn parseThinkingLevel(value: []const u8) agent_mod.protocol.ThinkingLevel {
    if (std.mem.eql(u8, value, "minimal")) return .minimal;
    if (std.mem.eql(u8, value, "low")) return .low;
    if (std.mem.eql(u8, value, "medium")) return .medium;
    if (std.mem.eql(u8, value, "high")) return .high;
    if (std.mem.eql(u8, value, "xhigh")) return .xhigh;
    return .off;
}

fn thinkingLevelToString(level: agent_mod.protocol.ThinkingLevel) []const u8 {
    return switch (level) {
        .off => "off",
        .minimal => "minimal",
        .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => "xhigh",
    };
}

const testing = std.testing;
const faux = ai.faux;
const resources = @import("resources/root.zig");

const LifecycleCollector = struct {
    allocator: std.mem.Allocator,
    retry_starts: std.ArrayListUnmanaged(RetryStart) = .empty,
    retry_ends: std.ArrayListUnmanaged(RetryEnd) = .empty,
    compaction_starts: std.ArrayListUnmanaged(CompactionStart) = .empty,
    compaction_ends: std.ArrayListUnmanaged(CompactionEnd) = .empty,
    compaction_starts_seen_before_first_end: usize = 0,
    retry_wait_finished_count: usize = 0,

    fn onRetryStart(event: RetryStart, ctx: ?*anyopaque) void {
        const self: *LifecycleCollector = @ptrCast(@alignCast(ctx.?));
        self.retry_starts.append(self.allocator, event) catch {};
    }

    fn onRetryWaitFinished(ctx: ?*anyopaque) void {
        const self: *LifecycleCollector = @ptrCast(@alignCast(ctx.?));
        self.retry_wait_finished_count += 1;
    }

    fn onRetryEnd(event: RetryEnd, ctx: ?*anyopaque) void {
        const self: *LifecycleCollector = @ptrCast(@alignCast(ctx.?));
        self.retry_ends.append(self.allocator, event) catch {};
    }

    fn onCompactionStart(event: CompactionStart, ctx: ?*anyopaque) void {
        const self: *LifecycleCollector = @ptrCast(@alignCast(ctx.?));
        self.compaction_starts.append(self.allocator, event) catch {};
    }

    fn onCompactionEnd(event: CompactionEnd, ctx: ?*anyopaque) void {
        const self: *LifecycleCollector = @ptrCast(@alignCast(ctx.?));
        if (self.compaction_ends.items.len == 0) self.compaction_starts_seen_before_first_end = self.compaction_starts.items.len;
        self.compaction_ends.append(self.allocator, event) catch {};
    }

    fn deinit(self: *LifecycleCollector) void {
        self.retry_starts.deinit(self.allocator);
        self.retry_ends.deinit(self.allocator);
        self.compaction_starts.deinit(self.allocator);
        self.compaction_ends.deinit(self.allocator);
    }
};

const CompactionSpy = struct {
    allocator: std.mem.Allocator,
    calls: std.ArrayListUnmanaged(CompactionReason) = .empty,

    fn execute(
        _: *AgentSession,
        reason: CompactionReason,
        _: CompactionPolicy,
        _: session_runner.CompactionRunContext,
        ctx: ?*anyopaque,
    ) anyerror!CompactionResult {
        const self: *CompactionSpy = @ptrCast(@alignCast(ctx.?));
        try self.calls.append(self.allocator, reason);
        return .{
            .summary = "condensed history",
            .first_kept_entry_id = "keep-user",
            .tokens_before = 2048,
        };
    }

    fn deinit(self: *CompactionSpy) void {
        self.calls.deinit(self.allocator);
    }
};

const CancelCompactionSpy = struct {
    fn execute(
        _: *AgentSession,
        _: CompactionReason,
        _: CompactionPolicy,
        _: session_runner.CompactionRunContext,
        _: ?*anyopaque,
    ) anyerror!CompactionResult {
        return error.CompactionCancelled;
    }
};

fn fauxErrorAssistantMessage(
    allocator: std.mem.Allocator,
    error_message: []const u8,
) ai.protocol.AssistantMessage {
    var message = faux.fauxAssistantMessage(allocator, &.{}, .@"error");
    message.error_message = error_message;
    return message;
}

fn persistSessionFixture(_: std.mem.Allocator, store: *agent_session_mod.SessionStore) void {
    _ = store.appendMessage(.{ .user = .{
        .content = .{ .text = "persist me" },
        .timestamp = 1,
    } });

    const content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("persisted")};
    var assistant = faux.fauxAssistantMessage(std.heap.page_allocator, &content, .stop);
    assistant.timestamp = 2;
    _ = store.appendMessage(.{ .assistant = assistant });
}

fn createTestCreateOptions(registry: ?*ai.provider.Registry) sdk.CreateOptions {
    return .{
        .model = faux.fauxModel(),
        .api_key = "test-key",
        .cwd = "/tmp/zi-test",
        .agent_dir_override = "/tmp/zi-test-agent-empty",
        .registry = registry,
        .tools = &.{},
        .no_session = true,
    };
}

fn createOwnedTestAgentSession(
    allocator: std.mem.Allocator,
    registry: ?*ai.provider.Registry,
) !*AgentSession {
    const session = try allocator.create(AgentSession);
    errdefer allocator.destroy(session);
    session.* = try sdk.createAgentSession(allocator, createTestCreateOptions(registry));
    return session;
}

fn createTestCreateOptionsForCwd(
    cwd: []const u8,
    extension_paths: []const []const u8,
    no_session: bool,
) sdk.CreateOptions {
    return .{
        .model = faux.fauxModel(),
        .api_key = "test-key",
        .cwd = cwd,
        .agent_dir_override = "/tmp/zi-test-agent-empty",
        .tools = &.{},
        .no_session = no_session,
        .extension_paths = extension_paths,
    };
}

fn createOwnedTestAgentSessionWithOptions(
    allocator: std.mem.Allocator,
    options: sdk.CreateOptions,
) !*AgentSession {
    const session = try allocator.create(AgentSession);
    errdefer allocator.destroy(session);
    session.* = try sdk.createAgentSession(allocator, options);
    return session;
}

fn makeLifecycleLoggerSource(
    allocator: std.mem.Allocator,
    log_path: []const u8,
    extension_name: []const u8,
) ![]u8 {
    const template =
        "local log_path = \"{s}\"\n" ++
        "local extension_name = \"{s}\"\n" ++
        "local function value(v)\n" ++
        "  if v == nil then return \"\" end\n" ++
        "  return tostring(v)\n" ++
        "end\n" ++
        "local function write_event(event, ctx, related_key)\n" ++
        "  local binding = event.binding or {{}}\n" ++
        "  local related = event[related_key]\n" ++
        "  local f = assert(io.open(log_path, \"a\"))\n" ++
        "  f:write(table.concat({{\n" ++
        "    extension_name,\n" ++
        "    value(event.type),\n" ++
        "    value(event.reason),\n" ++
        "    ctx.models and ctx.models.current() and \"1\" or \"0\",\n" ++
        "    value(binding.runtime_root_id),\n" ++
        "    value(binding.state_owner_id),\n" ++
        "    value(binding.workspace_id),\n" ++
        "    value(binding.namespace_id),\n" ++
        "    value(binding.generation_id),\n" ++
        "    value(binding.session_id),\n" ++
        "    binding.session_file and \"1\" or \"0\",\n" ++
        "    related_key,\n" ++
        "    related and value(related.workspace_id) or \"\",\n" ++
        "  }}, \"|\"), \"\\n\")\n" ++
        "  f:close()\n" ++
        "end\n" ++
        "return function(zi)\n" ++
        "  zi.on(\"session_start\", function(event, ctx) write_event(event, ctx, \"previous\") end)\n" ++
        "  zi.on(\"session_shutdown\", function(event, ctx) write_event(event, ctx, \"next\") end)\n" ++
        "end\n";

    return std.fmt.allocPrint(allocator, template, .{ log_path, extension_name });
}

test "runtime host rejects self-resume and only replaces with a different persisted session" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(workspace);

    const create_options = createTestCreateOptionsForCwd(workspace, &.{}, false);
    const session = try createOwnedTestAgentSessionWithOptions(testing.allocator, create_options);
    persistSessionFixture(testing.allocator, &session.session_store);
    var host = try RuntimeHost.init(session, testing.allocator, testing.allocator, create_options, .{});
    defer host.deinit();

    const initial_runner = host.currentSession().extensionRunner() orelse return error.MissingExtensionRunner;
    try testing.expect(initial_runner.isBound());
    const initial_generation = initial_runner.generation;
    const initial_session_file = try testing.allocator.dupe(u8, host.currentSession().getSessionFile());
    defer testing.allocator.free(initial_session_file);
    const initial_session_id = try testing.allocator.dupe(u8, host.currentSession().session_store.sessionId());
    defer testing.allocator.free(initial_session_id);

    try host.newSession();
    persistSessionFixture(testing.allocator, &host.currentSession().session_store);
    const after_new_runner = host.currentSession().extensionRunner() orelse return error.MissingExtensionRunner;
    try testing.expect(after_new_runner.isBound());
    try testing.expectEqual(initial_generation + 1, after_new_runner.generation);

    const active_session_file = try testing.allocator.dupe(u8, host.currentSession().getSessionFile());
    defer testing.allocator.free(active_session_file);
    const active_session_id = try testing.allocator.dupe(u8, host.currentSession().session_store.sessionId());
    defer testing.allocator.free(active_session_id);
    try testing.expect(!std.mem.eql(u8, initial_session_id, active_session_id));

    try testing.expectError(error.SessionAlreadyActive, host.resumeSession(active_session_file, false));
    const after_failed_resume_runner = host.currentSession().extensionRunner() orelse return error.MissingExtensionRunner;
    try testing.expect(after_failed_resume_runner.isBound());
    try testing.expectEqual(initial_generation + 1, after_failed_resume_runner.generation);
    try testing.expectEqualStrings(active_session_file, host.currentSession().getSessionFile());
    try testing.expectEqualStrings(active_session_id, host.currentSession().session_store.sessionId());

    _ = try host.resumeSession(initial_session_file, false);
    const after_resume_runner = host.currentSession().extensionRunner() orelse return error.MissingExtensionRunner;
    try testing.expect(after_resume_runner.isBound());
    try testing.expectEqual(initial_generation + 2, after_resume_runner.generation);
    try testing.expectEqualStrings(initial_session_file, host.currentSession().getSessionFile());
    try testing.expectEqualStrings(initial_session_id, host.currentSession().session_store.sessionId());
}

test "runtime host emits truthful session lifecycle events across startup new resume and exit" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("shared/extensions");
    try tmp.dir.makePath("workspace-a/.zi/extensions");
    try tmp.dir.makePath("workspace-b/.zi/extensions");
    try tmp.dir.writeFile(.{ .sub_path = "lifecycle.log", .data = "" });

    const shared_root = try tmp.dir.realpathAlloc(allocator, "shared");
    defer allocator.free(shared_root);
    const workspace_a = try tmp.dir.realpathAlloc(allocator, "workspace-a");
    defer allocator.free(workspace_a);
    const workspace_b = try tmp.dir.realpathAlloc(allocator, "workspace-b");
    defer allocator.free(workspace_b);
    const project_root_a = try std.fs.path.join(allocator, &.{ workspace_a, ".zi" });
    defer allocator.free(project_root_a);
    const project_root_b = try std.fs.path.join(allocator, &.{ workspace_b, ".zi" });
    defer allocator.free(project_root_b);
    const log_path = try tmp.dir.realpathAlloc(allocator, "lifecycle.log");
    defer allocator.free(log_path);

    const explicit_src = try makeLifecycleLoggerSource(allocator, log_path, "explicit");
    defer allocator.free(explicit_src);
    const project_src = try makeLifecycleLoggerSource(allocator, log_path, "project");
    defer allocator.free(project_src);

    try tmp.dir.writeFile(.{ .sub_path = "shared/extensions/explicit.lua", .data = explicit_src });
    try tmp.dir.writeFile(.{ .sub_path = "workspace-a/.zi/extensions/project.lua", .data = project_src });
    try tmp.dir.writeFile(.{ .sub_path = "workspace-b/.zi/extensions/project.lua", .data = project_src });

    const extension_paths = [_][]const u8{shared_root};
    const create_options = createTestCreateOptionsForCwd(workspace_a, &extension_paths, false);
    const session = try createOwnedTestAgentSessionWithOptions(allocator, create_options);
    var host = try RuntimeHost.init(session, allocator, allocator, create_options, .{});

    try host.newSession();

    const readLines = struct {
        fn run(alloc: std.mem.Allocator, path_: []const u8) !std.ArrayListUnmanaged([]u8) {
            const file = try std.fs.openFileAbsolute(path_, .{});
            defer file.close();
            const raw = try file.readToEndAlloc(alloc, 1024 * 1024);
            defer alloc.free(raw);

            var lines: std.ArrayListUnmanaged([]u8) = .empty;
            errdefer {
                for (lines.items) |line| alloc.free(line);
                lines.deinit(alloc);
            }

            var it = std.mem.splitScalar(u8, raw, '\n');
            while (it.next()) |line| {
                if (line.len == 0) continue;
                try lines.append(alloc, try alloc.dupe(u8, line));
            }
            return lines;
        }
    };

    var lines_before_failed_resume = try readLines.run(allocator, log_path);
    defer {
        for (lines_before_failed_resume.items) |line| allocator.free(line);
        lines_before_failed_resume.deinit(allocator);
    }
    try testing.expectEqual(@as(usize, 6), lines_before_failed_resume.items.len);

    const missing_resume = try std.fs.path.join(allocator, &.{ workspace_a, "missing-session.jsonl" });
    defer allocator.free(missing_resume);
    try testing.expectError(error.FileNotFound, host.resumeSession(missing_resume, false));

    var lines_after_failed_resume = try readLines.run(allocator, log_path);
    defer {
        for (lines_after_failed_resume.items) |line| allocator.free(line);
        lines_after_failed_resume.deinit(allocator);
    }
    try testing.expectEqual(lines_before_failed_resume.items.len, lines_after_failed_resume.items.len);

    var resume_store = try agent_session_mod.SessionStore.createForCwd(allocator, workspace_b, "/tmp/zi-test-agent-empty");
    persistSessionFixture(allocator, &resume_store);
    const resume_path = try allocator.dupe(u8, resume_store.sessionFile());
    resume_store.deinit();
    defer allocator.free(resume_path);

    _ = try host.resumeSession(resume_path, false);
    host.deinit();

    var lines = try readLines.run(allocator, log_path);
    defer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }
    try testing.expectEqual(@as(usize, 12), lines.items.len);

    const Parsed = struct { fields: [13][]const u8 };
    const parse = struct {
        fn line(input: []const u8) !Parsed {
            var out: [13][]const u8 = undefined;
            var i: usize = 0;
            var it = std.mem.splitScalar(u8, input, '|');
            while (it.next()) |field| {
                if (i >= out.len) return error.TooManyFields;
                out[i] = field;
                i += 1;
            }
            if (i != out.len) return error.NotEnoughFields;
            return .{ .fields = out };
        }
    };

    const expectLine = struct {
        fn run(parsed: Parsed, expected: struct {
            ext: []const u8,
            event_type: []const u8,
            reason: []const u8,
            runtime_root: []const u8,
            workspace: []const u8,
            generation: []const u8,
            related_kind: []const u8,
            related_workspace: []const u8,
        }) !void {
            try testing.expectEqualStrings(expected.ext, parsed.fields[0]);
            try testing.expectEqualStrings(expected.event_type, parsed.fields[1]);
            try testing.expectEqualStrings(expected.reason, parsed.fields[2]);
            try testing.expectEqualStrings("1", parsed.fields[3]);
            try testing.expectEqualStrings(expected.runtime_root, parsed.fields[4]);
            const expected_state_owner = try std.fmt.allocPrint(testing.allocator, "{s}::{s}", .{ expected.runtime_root, expected.ext });
            defer testing.allocator.free(expected_state_owner);
            try testing.expectEqualStrings(expected_state_owner, parsed.fields[5]);
            try testing.expectEqualStrings(expected.workspace, parsed.fields[6]);
            const expected_namespace = try std.fmt.allocPrint(testing.allocator, "{s}::{s}", .{ expected_state_owner, expected.generation });
            defer testing.allocator.free(expected_namespace);
            try testing.expectEqualStrings(expected_namespace, parsed.fields[7]);
            try testing.expectEqualStrings(expected.generation, parsed.fields[8]);
            try testing.expect(parsed.fields[9].len > 0);
            try testing.expectEqualStrings("1", parsed.fields[10]);
            try testing.expectEqualStrings(expected.related_kind, parsed.fields[11]);
            try testing.expectEqualStrings(expected.related_workspace, parsed.fields[12]);
        }
    };

    try expectLine.run(try parse.line(lines.items[0]), .{ .ext = "explicit", .event_type = "session_start", .reason = "startup", .runtime_root = shared_root, .workspace = workspace_a, .generation = "0", .related_kind = "previous", .related_workspace = "" });
    try expectLine.run(try parse.line(lines.items[1]), .{ .ext = "project", .event_type = "session_start", .reason = "startup", .runtime_root = project_root_a, .workspace = workspace_a, .generation = "0", .related_kind = "previous", .related_workspace = "" });
    try expectLine.run(try parse.line(lines.items[2]), .{ .ext = "explicit", .event_type = "session_shutdown", .reason = "new", .runtime_root = shared_root, .workspace = workspace_a, .generation = "0", .related_kind = "next", .related_workspace = workspace_a });
    try expectLine.run(try parse.line(lines.items[3]), .{ .ext = "project", .event_type = "session_shutdown", .reason = "new", .runtime_root = project_root_a, .workspace = workspace_a, .generation = "0", .related_kind = "next", .related_workspace = workspace_a });
    try expectLine.run(try parse.line(lines.items[4]), .{ .ext = "explicit", .event_type = "session_start", .reason = "new", .runtime_root = shared_root, .workspace = workspace_a, .generation = "1", .related_kind = "previous", .related_workspace = workspace_a });
    try expectLine.run(try parse.line(lines.items[5]), .{ .ext = "project", .event_type = "session_start", .reason = "new", .runtime_root = project_root_a, .workspace = workspace_a, .generation = "1", .related_kind = "previous", .related_workspace = workspace_a });
    try expectLine.run(try parse.line(lines.items[6]), .{ .ext = "explicit", .event_type = "session_shutdown", .reason = "resume", .runtime_root = shared_root, .workspace = workspace_a, .generation = "1", .related_kind = "next", .related_workspace = workspace_b });
    try expectLine.run(try parse.line(lines.items[7]), .{ .ext = "project", .event_type = "session_shutdown", .reason = "resume", .runtime_root = project_root_a, .workspace = workspace_a, .generation = "1", .related_kind = "next", .related_workspace = workspace_b });
    try expectLine.run(try parse.line(lines.items[8]), .{ .ext = "explicit", .event_type = "session_start", .reason = "resume", .runtime_root = shared_root, .workspace = workspace_b, .generation = "2", .related_kind = "previous", .related_workspace = workspace_a });
    try expectLine.run(try parse.line(lines.items[9]), .{ .ext = "project", .event_type = "session_start", .reason = "resume", .runtime_root = project_root_b, .workspace = workspace_b, .generation = "2", .related_kind = "previous", .related_workspace = workspace_a });
    try expectLine.run(try parse.line(lines.items[10]), .{ .ext = "explicit", .event_type = "session_shutdown", .reason = "exit", .runtime_root = shared_root, .workspace = workspace_b, .generation = "2", .related_kind = "next", .related_workspace = "" });
    try expectLine.run(try parse.line(lines.items[11]), .{ .ext = "project", .event_type = "session_shutdown", .reason = "exit", .runtime_root = project_root_b, .workspace = workspace_b, .generation = "2", .related_kind = "next", .related_workspace = "" });
}

test "runtime host publishes committed view and queued snapshots independently" {
    const session = try createOwnedTestAgentSession(testing.allocator, null);

    try session.agent.setMessages(&.{.{ .user = .{
        .content = .{ .text = "hello" },
        .timestamp = 1,
    } }});

    var published_snapshot: ?conversation_state.ConversationSnapshotEnvelope = null;
    defer if (published_snapshot) |*snapshot| snapshot.deinit(testing.allocator);

    var published_queued: ?control_mod.QueuedMessageSnapshot = null;
    defer if (published_queued) |*snapshot| snapshot.deinit(testing.allocator);

    const Capture = struct {
        fn publishSnapshot(envelope: conversation_state.ConversationSnapshotEnvelope, ctx: ?*anyopaque) bool {
            const out: *?conversation_state.ConversationSnapshotEnvelope = @ptrCast(@alignCast(ctx.?));
            out.* = envelope;
            return true;
        }

        fn publishQueued(snapshot: control_mod.QueuedMessageSnapshot, ctx: ?*anyopaque) bool {
            const out: *?control_mod.QueuedMessageSnapshot = @ptrCast(@alignCast(ctx.?));
            out.* = snapshot;
            return true;
        }
    };

    var host = try RuntimeHost.init(session, testing.allocator, testing.allocator, createTestCreateOptions(null), .{});
    defer host.deinit();

    try testing.expectEqual(.ok, host.currentSession().agent.followUp(.{ .user = .{
        .content = .{ .text = "queued" },
        .timestamp = 2,
    } }));

    try testing.expect(host.publishConversationState(.{
        .func = &Capture.publishSnapshot,
        .ctx = @ptrCast(&published_snapshot),
    }));
    try testing.expect(host.publishQueuedSnapshot(.{
        .func = &Capture.publishQueued,
        .ctx = @ptrCast(&published_queued),
    }));

    try testing.expect(published_snapshot != null);
    try testing.expectEqual(@as(u64, 1), published_snapshot.?.session_generation);
    try testing.expectEqual(@as(u64, 1), published_snapshot.?.conversation_version);
    try testing.expectEqual(@as(usize, 1), published_snapshot.?.view.committed.flat.len);
    try testing.expectEqualStrings("hello", published_snapshot.?.view.committed.flat[0].user.content.text);

    try testing.expect(published_queued != null);
    try testing.expectEqual(@as(usize, 0), published_queued.?.steering.len);
    try testing.expectEqual(@as(usize, 1), published_queued.?.follow_up.len);
    try testing.expectEqualStrings("queued", published_queued.?.follow_up[0].text);
}

test "runtime host keeps queued-snapshot reads wired after session replacement" {
    const session = try createOwnedTestAgentSession(testing.allocator, null);
    var host = try RuntimeHost.init(session, testing.allocator, testing.allocator, createTestCreateOptions(null), .{});
    defer host.deinit();

    const before_session_id = host.currentSession().session_store.sessionId();
    try host.newSession();
    try testing.expect(!std.mem.eql(u8, before_session_id, host.currentSession().session_store.sessionId()));

    try testing.expectEqual(.ok, host.currentSession().agent.followUp(.{ .user = .{
        .content = .{ .text = "queued after replace" },
        .timestamp = 1,
    } }));

    var snap = try host.currentSession().cloneQueuedMessageSnapshot(testing.allocator);
    defer snap.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), snap.follow_up.len);
    try testing.expectEqualStrings("queued after replace", snap.follow_up[0].text);
}

test "runtime host retries transient assistant failures and prunes the failed assistant turn before continue" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fp = faux.FauxProvider.init(allocator);
    const transient_err = fauxErrorAssistantMessage(allocator, "provider returned error: 503 service unavailable");
    const success_content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("recovered")};
    const success_msg = faux.fauxAssistantMessage(allocator, &success_content, .stop);
    fp.setResponses(&.{ transient_err, success_msg });

    var registry = ai.provider.Registry.init(allocator);
    try registry.register("faux", fp.provider(), null);

    const session = try createOwnedTestAgentSession(allocator, &registry);

    var collector = LifecycleCollector{ .allocator = allocator };
    defer collector.deinit();

    var host = try RuntimeHost.init(session, allocator, allocator, createTestCreateOptions(&registry), .{
        .retry_policy = .{
            .enabled = true,
            .max_retries = 2,
            .base_delay_ms = 0,
            .max_delay_ms = 0,
        },
    });
    defer host.deinit();
    host.setLifecycleHooks(.{
        .on_retry_start = &LifecycleCollector.onRetryStart,
        .on_retry_wait_finished = &LifecycleCollector.onRetryWaitFinished,
        .on_retry_end = &LifecycleCollector.onRetryEnd,
        .ctx = @ptrCast(&collector),
    });

    const outcome = try host.runUserContent(.{ .text = "hi" });

    try testing.expectEqual(RunOutcome.success, outcome);
    try testing.expectEqual(@as(usize, 2), fp.call_count);
    try testing.expectEqual(@as(usize, 1), collector.retry_starts.items.len);
    try testing.expectEqual(@as(usize, 1), collector.retry_ends.items.len);
    try testing.expectEqual(@as(usize, 1), collector.retry_wait_finished_count);
    try testing.expectEqual(@as(u32, 1), collector.retry_starts.items[0].attempt);
    try testing.expectEqual(@as(u32, 1), collector.retry_ends.items[0].attempt);
    try testing.expect(collector.retry_ends.items[0].success);
    try testing.expectEqual(@as(usize, 2), host.currentSession().agent.messages().len);
    try testing.expectEqualStrings("recovered", host.currentSession().agent.messages()[1].assistant.content[0].text.text);
}

test "runtime host recovers overflow with one compaction pass before retrying continue" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fp = faux.FauxProvider.init(allocator);
    const overflow_err = fauxErrorAssistantMessage(allocator, "prompt is too long for requested model");
    const success_content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("after compaction")};
    const success_msg = faux.fauxAssistantMessage(allocator, &success_content, .stop);
    fp.setResponses(&.{ overflow_err, success_msg });

    var registry = ai.provider.Registry.init(allocator);
    try registry.register("faux", fp.provider(), null);

    const session = try createOwnedTestAgentSession(allocator, &registry);

    var collector = LifecycleCollector{ .allocator = allocator };
    defer collector.deinit();

    var compaction_spy = CompactionSpy{ .allocator = allocator };
    defer compaction_spy.deinit();

    var host = try RuntimeHost.init(session, allocator, allocator, createTestCreateOptions(&registry), .{
        .compaction_executor = .{
            .func = &CompactionSpy.execute,
            .ctx = @ptrCast(&compaction_spy),
        },
    });
    defer host.deinit();
    host.setLifecycleHooks(.{
        .on_retry_start = &LifecycleCollector.onRetryStart,
        .on_retry_end = &LifecycleCollector.onRetryEnd,
        .on_compaction_start = &LifecycleCollector.onCompactionStart,
        .on_compaction_end = &LifecycleCollector.onCompactionEnd,
        .ctx = @ptrCast(&collector),
    });

    const outcome = try host.runUserContent(.{ .text = "hi" });

    try testing.expectEqual(RunOutcome.success, outcome);
    try testing.expectEqual(@as(usize, 2), fp.call_count);
    try testing.expectEqual(@as(usize, 1), compaction_spy.calls.items.len);
    try testing.expectEqual(CompactionReason.overflow, compaction_spy.calls.items[0]);
    try testing.expectEqual(@as(usize, 1), collector.compaction_starts.items.len);
    try testing.expectEqual(CompactionReason.overflow, collector.compaction_starts.items[0].reason);
    try testing.expectEqual(@as(usize, 1), collector.compaction_starts_seen_before_first_end);
    try testing.expectEqual(@as(usize, 1), collector.compaction_ends.items.len);
    try testing.expect(collector.compaction_ends.items[0].success);
    try testing.expect(!collector.compaction_ends.items[0].aborted);
    try testing.expect(collector.compaction_ends.items[0].result != null);
    try testing.expect(collector.compaction_ends.items[0].will_retry);
    try testing.expectEqual(@as(usize, 0), collector.retry_starts.items.len);
    try testing.expectEqual(@as(usize, 2), host.currentSession().agent.messages().len);
    try testing.expectEqualStrings("after compaction", host.currentSession().agent.messages()[1].assistant.content[0].text.text);
}

test "runtime host runs threshold compaction after successful turn when context exceeds threshold" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fp = faux.FauxProvider.init(allocator);
    const content = try allocator.alloc(ai.protocol.AssistantMessage.AssistantContentBlock, 1);
    content[0] = .{ .text = .{ .text = "ok" } };
    // Heavy assistant usage (~112k tokens) clears the default threshold
    // of context_window (128000) minus reserve_tokens (16384) = 111616.
    const heavy_msg: ai.protocol.AssistantMessage = .{
        .content = content,
        .api = .{ .custom = "faux" },
        .provider = .{ .custom = "faux" },
        .model = "faux-1",
        .usage = .{
            .input = 112_000,
            .output = 0,
            .cache_read = 0,
            .cache_write = 0,
            .total_tokens = 112_000,
            .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 },
        },
        .stop_reason = .stop,
        .timestamp = std.time.milliTimestamp(),
    };
    fp.setResponses(&.{heavy_msg});

    var registry = ai.provider.Registry.init(allocator);
    try registry.register("faux", fp.provider(), null);

    const session = try createOwnedTestAgentSession(allocator, &registry);

    var collector = LifecycleCollector{ .allocator = allocator };
    defer collector.deinit();
    var compaction_spy = CompactionSpy{ .allocator = allocator };
    defer compaction_spy.deinit();

    var host = try RuntimeHost.init(session, allocator, allocator, createTestCreateOptions(&registry), .{
        .compaction_executor = .{
            .func = &CompactionSpy.execute,
            .ctx = @ptrCast(&compaction_spy),
        },
    });
    defer host.deinit();
    host.setLifecycleHooks(.{
        .on_compaction_start = &LifecycleCollector.onCompactionStart,
        .on_compaction_end = &LifecycleCollector.onCompactionEnd,
        .ctx = @ptrCast(&collector),
    });

    const outcome = try host.runUserContent(.{ .text = "hi" });

    try testing.expectEqual(RunOutcome.success, outcome);
    try testing.expectEqual(@as(usize, 1), compaction_spy.calls.items.len);
    try testing.expectEqual(CompactionReason.threshold, compaction_spy.calls.items[0]);
    try testing.expectEqual(@as(usize, 1), collector.compaction_starts.items.len);
    try testing.expectEqual(CompactionReason.threshold, collector.compaction_starts.items[0].reason);
    try testing.expectEqual(@as(usize, 1), collector.compaction_starts_seen_before_first_end);
    try testing.expectEqual(@as(usize, 1), collector.compaction_ends.items.len);
    try testing.expectEqual(CompactionReason.threshold, collector.compaction_ends.items[0].reason);
    try testing.expect(collector.compaction_ends.items[0].success);
    try testing.expect(!collector.compaction_ends.items[0].aborted);
    try testing.expect(collector.compaction_ends.items[0].result != null);
    try testing.expect(!collector.compaction_ends.items[0].will_retry);
}

test "runtime host runs pre-prompt threshold compaction before sending next prompt" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fp = faux.FauxProvider.init(allocator);
    const response_content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("ok")};
    fp.setResponses(&.{faux.fauxAssistantMessage(allocator, &response_content, .stop)});

    var registry = ai.provider.Registry.init(allocator);
    try registry.register("faux", fp.provider(), null);

    const session = try createOwnedTestAgentSession(allocator, &registry);
    const prior_content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("prior oversized context")};
    var prior = faux.fauxAssistantMessage(allocator, &prior_content, .stop);
    prior.usage.total_tokens = 112_000;
    prior.usage.input = 112_000;
    try session.agent.setMessages(&.{.{ .assistant = prior }});

    var compaction_spy = CompactionSpy{ .allocator = allocator };
    defer compaction_spy.deinit();

    var host = try RuntimeHost.init(session, allocator, allocator, createTestCreateOptions(&registry), .{
        .compaction_executor = .{
            .func = &CompactionSpy.execute,
            .ctx = @ptrCast(&compaction_spy),
        },
    });
    defer host.deinit();

    const outcome = try host.runUserContent(.{ .text = "continue" });

    try testing.expectEqual(RunOutcome.success, outcome);
    try testing.expectEqual(@as(usize, 1), compaction_spy.calls.items.len);
    try testing.expectEqual(CompactionReason.threshold, compaction_spy.calls.items[0]);
    try testing.expectEqual(@as(usize, 1), fp.call_count);
}

test "runtime host reports cancelled compaction as aborted without an error string" {
    const session = try createOwnedTestAgentSession(testing.allocator, null);
    var host = try RuntimeHost.init(session, testing.allocator, testing.allocator, createTestCreateOptions(null), .{
        .compaction_executor = .{
            .func = &CancelCompactionSpy.execute,
        },
    });
    defer host.deinit();

    var collector = LifecycleCollector{ .allocator = testing.allocator };
    defer collector.deinit();
    host.setLifecycleHooks(.{
        .on_compaction_end = &LifecycleCollector.onCompactionEnd,
        .ctx = @ptrCast(&collector),
    });

    try testing.expectError(error.CompactionCancelled, host.runCompaction(.manual, false, .{}));
    try testing.expectEqual(@as(usize, 1), collector.compaction_ends.items.len);
    try testing.expect(!collector.compaction_ends.items[0].success);
    try testing.expect(collector.compaction_ends.items[0].aborted);
    try testing.expect(collector.compaction_ends.items[0].result == null);
    try testing.expect(collector.compaction_ends.items[0].error_message == null);
}

test "runtime host aborts replacement when session_before_switch is blocked" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(".zi/extensions");
    try tmp.dir.writeFile(.{
        .sub_path = ".zi/extensions/block.lua",
        .data =
        \\return function(zi)
        \\  zi.on("session_before_switch", function(event, ctx)
        \\    return { block = true, reason = "test-block" }
        \\  end)
        \\end
        ,
    });

    const cwd = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    const create_options = createTestCreateOptionsForCwd(cwd, &.{}, false);
    const session = try createOwnedTestAgentSessionWithOptions(allocator, create_options);
    var host = try RuntimeHost.init(session, allocator, allocator, create_options, .{});
    defer host.deinit();

    const before_session_id = try allocator.dupe(u8, host.currentSession().session_store.sessionId());
    defer allocator.free(before_session_id);
    const before_generation = host.currentSession().extensionRunner().?.generation;

    try testing.expectError(error.SessionBeforeSwitchBlocked, host.newSession());

    try testing.expectEqualStrings(before_session_id, host.currentSession().session_store.sessionId());
    try testing.expectEqual(before_generation, host.currentSession().extensionRunner().?.generation);
}

test "runtime host aborts replacement when session_before_fork is blocked" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(".zi/extensions");
    try tmp.dir.writeFile(.{
        .sub_path = ".zi/extensions/block.lua",
        .data =
        \\return function(zi)
        \\  zi.on("session_before_fork", function(event, ctx)
        \\    return { block = true, reason = "test-fork-block" }
        \\  end)
        \\end
        ,
    });

    const cwd = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    const create_options = createTestCreateOptionsForCwd(cwd, &.{}, false);
    const session = try createOwnedTestAgentSessionWithOptions(allocator, create_options);
    var host = try RuntimeHost.init(session, allocator, allocator, create_options, .{});
    defer host.deinit();

    const before_session_id = try allocator.dupe(u8, host.currentSession().session_store.sessionId());
    defer allocator.free(before_session_id);
    const before_generation = host.currentSession().extensionRunner().?.generation;

    try testing.expectError(error.SessionBeforeForkBlocked, host.forkSession("entry-1"));

    try testing.expectEqualStrings(before_session_id, host.currentSession().session_store.sessionId());
    try testing.expectEqual(before_generation, host.currentSession().extensionRunner().?.generation);
}

test "runtime host forkSession replaces session and skips session_before_switch" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(".zi/extensions");
    try tmp.dir.writeFile(.{
        .sub_path = ".zi/extensions/block.lua",
        .data =
        \\return function(zi)
        \\  zi.on("session_before_switch", function(event, ctx)
        \\    return { block = true, reason = "should-not-fire" }
        \\  end)
        \\end
        ,
    });

    const cwd = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    const create_options = createTestCreateOptionsForCwd(cwd, &.{}, false);
    const session = try createOwnedTestAgentSessionWithOptions(allocator, create_options);
    var host = try RuntimeHost.init(session, allocator, allocator, create_options, .{});
    defer host.deinit();

    const before_session_id = try allocator.dupe(u8, host.currentSession().session_store.sessionId());
    defer allocator.free(before_session_id);
    const before_generation = host.currentSession().extensionRunner().?.generation;

    try host.forkSession("entry-1");

    try testing.expect(!std.mem.eql(u8, before_session_id, host.currentSession().session_store.sessionId()));
    try testing.expectEqual(before_generation + 1, host.currentSession().extensionRunner().?.generation);
}

test "runtime host forkSession emits fork_parent_entry_id in lifecycle payloads" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    const log_path = try std.fs.path.join(allocator, &.{ cwd, "forklog.txt" });
    defer allocator.free(log_path);

    const lua_src = try std.fmt.allocPrint(allocator,
        \\return function(zi)
        \\  zi.on("session_shutdown", function(event, ctx)
        \\    if event.reason == "fork" then
        \\      local f = assert(io.open("{s}", "a"))
        \\      f:write((event.fork_parent_entry_id or "MISSING") .. "|shutdown\n")
        \\      f:close()
        \\    end
        \\  end)
        \\  zi.on("session_start", function(event, ctx)
        \\    if event.reason == "fork" then
        \\      local f = assert(io.open("{s}", "a"))
        \\      f:write((event.fork_parent_entry_id or "MISSING") .. "|start\n")
        \\      f:close()
        \\    end
        \\  end)
        \\end
    , .{ log_path, log_path });
    defer allocator.free(lua_src);

    try tmp.dir.makePath(".zi/extensions");
    try tmp.dir.writeFile(.{ .sub_path = ".zi/extensions/fork-log.lua", .data = lua_src });

    const create_options = createTestCreateOptionsForCwd(cwd, &.{}, false);
    const session = try createOwnedTestAgentSessionWithOptions(allocator, create_options);
    var host = try RuntimeHost.init(session, allocator, allocator, create_options, .{});
    defer host.deinit();

    try host.forkSession("entry-42");

    const file = try std.fs.openFileAbsolute(log_path, .{});
    defer file.close();
    const raw = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(raw);

    var lines_out: std.ArrayListUnmanaged([]const u8) = .empty;
    defer lines_out.deinit(allocator);
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        try lines_out.append(allocator, line);
    }

    try testing.expectEqual(@as(usize, 2), lines_out.items.len);
    try testing.expectEqualStrings("entry-42|shutdown", lines_out.items[0]);
    try testing.expectEqualStrings("entry-42|start", lines_out.items[1]);
}

test "session_generation bumps on newSession" {
    const session = try createOwnedTestAgentSession(testing.allocator, null);
    var host = try RuntimeHost.init(session, testing.allocator, testing.allocator, createTestCreateOptions(null), .{});
    defer host.deinit();

    try testing.expectEqual(@as(u64, 1), host.session_generation);

    try host.newSession();
    try testing.expectEqual(@as(u64, 2), host.session_generation);

    try host.newSession();
    try testing.expectEqual(@as(u64, 3), host.session_generation);
}
