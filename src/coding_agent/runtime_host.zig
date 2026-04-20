const std = @import("std");
const agent_mod = @import("../agent3/root.zig");
const control_mod = @import("../agent3/control.zig");
const ai = @import("../ai/root.zig");
const json_util = @import("../ai/json_util.zig");
const agent_session_mod = @import("agent_session.zig");
const AgentSession = agent_session_mod.AgentSession;
const sdk = @import("sdk.zig");
const resolve_mod = @import("resolve.zig");
const session_runner = @import("session_runner.zig");
const conversation_state = @import("../agent3/conversation_state.zig");
const theme_mod = @import("../tui/theme.zig");
const themes_builtin = @import("../themes/builtin.zig");
const session_event_mod = @import("session_event.zig");
const profile = @import("../debug/profile.zig");

pub const QueueKind = control_mod.QueueKind;
pub const EnqueueResult = control_mod.EnqueueResult;
pub const QueuedMessageText = control_mod.QueuedMessageText;
pub const QueuedMessageSnapshot = control_mod.QueuedMessageSnapshot;

pub const RunOutcome = session_runner.RunOutcome;
pub const RetryStart = session_runner.RetryStart;
pub const RetryEnd = session_runner.RetryEnd;
pub const CompactionReason = session_runner.CompactionReason;
pub const CompactionEnd = session_runner.CompactionEnd;
pub const SessionEvent = session_event_mod.SessionEvent;
pub const RetryPolicy = session_runner.RetryPolicy;
pub const CompactionPolicy = session_runner.CompactionPolicy;
pub const CompactionResult = session_runner.CompactionResult;
pub const CompactionExecutor = session_runner.CompactionExecutor;
pub const LifecycleHooks = session_runner.LifecycleHooks;
pub const Options = session_runner.Options;

pub const ConversationStatePublisher = struct {
    func: *const fn (state: conversation_state.PublishedConversationState, ctx: ?*anyopaque) void,
    ctx: ?*anyopaque = null,

    pub fn publish(self: ConversationStatePublisher, state: conversation_state.PublishedConversationState) void {
        self.func(state, self.ctx);
    }
};

pub const RuntimeHost = struct {
    session: *AgentSession,
    session_allocator: std.mem.Allocator,
    msg_allocator: std.mem.Allocator,
    create_options: sdk.CreateOptions,
    runner: session_runner.SessionRunner,
    event_listeners: std.ArrayList(EventHandler),
    session_event_token: ?AgentSession.EventSubscriptionToken = null,

    pub const EventHandler = struct {
        func: *const fn (event: SessionEvent, ctx: ?*anyopaque) void,
        ctx: ?*anyopaque = null,
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
            .event_listeners = .empty,
        };
        self.session.activateRuntimeHooks();
        return self;
    }

    pub fn deinit(self: *RuntimeHost) void {
        self.unbindSessionEvents();
        self.session.deinit();
        self.session_allocator.destroy(self.session);
        self.event_listeners.deinit(self.session_allocator);
        self.* = undefined;
    }

    pub fn currentSession(self: *RuntimeHost) *AgentSession {
        return self.session;
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

    pub fn subscribeEvents(
        self: *RuntimeHost,
        func: *const fn (event: SessionEvent, ctx: ?*anyopaque) void,
        ctx: ?*anyopaque,
    ) EventSubscriptionToken {
        self.bindSessionEvents();
        const index = self.event_listeners.items.len;
        self.event_listeners.append(self.session_allocator, .{ .func = func, .ctx = ctx }) catch return .{ .index = std.math.maxInt(usize) };
        return .{ .index = index };
    }

    pub fn unsubscribeEvents(self: *RuntimeHost, token: EventSubscriptionToken) void {
        if (token.index < self.event_listeners.items.len) {
            _ = self.event_listeners.orderedRemove(token.index);
        }
    }

    pub fn setLifecycleHooks(self: *RuntimeHost, hooks: LifecycleHooks) void {
        self.runner.setLifecycleHooks(hooks);
    }

    pub fn setCompactionExecutor(self: *RuntimeHost, executor: ?CompactionExecutor) void {
        self.runner.setCompactionExecutor(executor);
    }

    /// Agent-thread-only helper for the queued-input restore flow.
    pub fn restoreQueuedMessagesOnAgentThread(self: *RuntimeHost, allocator: std.mem.Allocator) !QueuedMessageSnapshot {
        return self.session.restoreQueuedMessagesOnAgentThread(allocator);
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

        var new_store = try agent_session_mod.SessionStore.createForCwd(self.session_allocator, create_options.cwd);
        errdefer new_store.deinit();
        create_options.session_store = new_store;

        const next = try self.createOwnedSession(create_options);
        next.session_store.appendRuntimeDefaults(
            json_util.providerToString(next.agent.modelValue().provider),
            next.agent.modelValue().id,
            thinkingLevelToString(next.agent.thinkingLevel()),
        );
        self.replaceSession(next);
    }

    pub fn resumeSession(self: *RuntimeHost, path: []const u8, restore_session_model: bool) !ResumeResult {
        var loaded = try agent_session_mod.SessionStore.openForResume(self.session_allocator, path);
        defer loaded.deinit();

        var create_options = self.create_options;
        create_options.cwd = loaded.store.?.cwd();
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
        errdefer new_store.deinit();
        create_options.session_store = new_store;

        const next = try self.createOwnedSession(create_options);
        self.replaceSession(next);
        return .{ .restore_warning = restore_warning };
    }

    pub fn runUserContent(self: *RuntimeHost, content: ai.protocol.UserMessage.UserMessageContent) !RunOutcome {
        return self.runner.runUserContent(self.session, self.runnerEventEmitter(), content);
    }

    pub fn continueTurn(self: *RuntimeHost) !RunOutcome {
        return self.runner.continueTurn(self.session, self.runnerEventEmitter());
    }

    pub fn runCompaction(self: *RuntimeHost, reason: CompactionReason, will_retry: bool) !CompactionResult {
        return self.runner.runCompaction(self.session, self.runnerEventEmitter(), reason, will_retry);
    }

    pub fn publishConversationState(
        self: *RuntimeHost,
        publisher: ConversationStatePublisher,
    ) bool {
        var publish_timer = profile.ScopedTimer.begin(.publish_conversation_state);
        defer publish_timer.end();

        var view = self.session.agent.cloneConversationView(self.msg_allocator) catch return false;
        errdefer view.deinit(self.msg_allocator);

        var queued = self.session.cloneQueuedMessageSnapshot(self.msg_allocator) catch return false;
        errdefer queued.deinit(self.msg_allocator);

        publisher.publish(.{
            .view = view,
            .queued = queued,
        });
        return true;
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

    fn emitSessionEvent(self: *RuntimeHost, event: SessionEvent) void {
        for (self.event_listeners.items) |handler| {
            handler.func(event, handler.ctx);
        }
    }

    fn sessionEventBridge(event: SessionEvent, ctx: ?*anyopaque) void {
        const self: *RuntimeHost = @ptrCast(@alignCast(ctx.?));
        self.emitSessionEvent(event);
    }

    fn createOwnedSession(self: *RuntimeHost, create_options: sdk.CreateOptions) !*AgentSession {
        const session = try self.session_allocator.create(AgentSession);
        errdefer self.session_allocator.destroy(session);
        session.* = try sdk.createAgentSession(self.session_allocator, create_options);
        return session;
    }

    fn replaceSession(self: *RuntimeHost, next: *AgentSession) void {
        const had_runtime_listeners = self.event_listeners.items.len > 0;
        self.unbindSessionEvents();
        self.session.shutdownExtensionsOnAgentThread();
        self.session.deinit();
        self.session_allocator.destroy(self.session);
        self.session = next;
        self.session.activateRuntimeHooks();
        if (had_runtime_listeners) self.bindSessionEvents();
    }

    fn runnerEventEmitter(self: *RuntimeHost) session_runner.EventEmitter {
        return .{
            .func = &sessionEventBridge,
            .ctx = @ptrCast(self),
        };
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
    compaction_ends: std.ArrayListUnmanaged(CompactionEnd) = .empty,
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

    fn onCompactionEnd(event: CompactionEnd, ctx: ?*anyopaque) void {
        const self: *LifecycleCollector = @ptrCast(@alignCast(ctx.?));
        self.compaction_ends.append(self.allocator, event) catch {};
    }

    fn deinit(self: *LifecycleCollector) void {
        self.retry_starts.deinit(self.allocator);
        self.retry_ends.deinit(self.allocator);
        self.compaction_ends.deinit(self.allocator);
    }
};

const CompactionSpy = struct {
    allocator: std.mem.Allocator,
    calls: std.ArrayListUnmanaged(CompactionReason) = .empty,

    fn execute(_: *AgentSession, reason: CompactionReason, _: CompactionPolicy, ctx: ?*anyopaque) anyerror!CompactionResult {
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

fn fauxErrorAssistantMessage(
    allocator: std.mem.Allocator,
    error_message: []const u8,
) ai.protocol.AssistantMessage {
    var message = faux.fauxAssistantMessage(allocator, &.{}, .@"error");
    message.error_message = error_message;
    return message;
}

fn createTestCreateOptions(registry: ?*ai.provider.Registry) sdk.CreateOptions {
    return .{
        .model = faux.fauxModel(),
        .api_key = "test-key",
        .cwd = "/tmp/zi-test",
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

test "runtime host publishes committed and queued conversation state" {
    const session = try createOwnedTestAgentSession(testing.allocator, null);

    try session.agent.setMessages(&.{.{ .user = .{
        .content = .{ .text = "hello" },
        .timestamp = 1,
    } }});

    var published: ?conversation_state.PublishedConversationState = null;
    defer if (published) |*state| state.deinit(testing.allocator);

    const Capture = struct {
        fn publish(state: conversation_state.PublishedConversationState, ctx: ?*anyopaque) void {
            const out: *?conversation_state.PublishedConversationState = @ptrCast(@alignCast(ctx.?));
            out.* = state;
        }
    };

    var host = try RuntimeHost.init(session, testing.allocator, testing.allocator, createTestCreateOptions(null), .{});
    defer host.deinit();

    try testing.expectEqual(.ok, host.currentSession().agent.followUp(.{ .user = .{
        .content = .{ .text = "queued" },
        .timestamp = 2,
    } }));

    try testing.expect(host.publishConversationState(.{
        .func = &Capture.publish,
        .ctx = @ptrCast(&published),
    }));
    try testing.expect(published != null);
    try testing.expectEqual(@as(usize, 1), published.?.view.committed.flat.len);
    try testing.expectEqualStrings("hello", published.?.view.committed.flat[0].user.content.text);
    try testing.expectEqual(@as(usize, 0), published.?.queued.steering.len);
    try testing.expectEqual(@as(usize, 1), published.?.queued.follow_up.len);
    try testing.expectEqualStrings("queued", published.?.queued.follow_up[0].text);
}

test "runtime host keeps session-event subscriptions across session replacement" {
    const session = try createOwnedTestAgentSession(testing.allocator, null);
    var host = try RuntimeHost.init(session, testing.allocator, testing.allocator, createTestCreateOptions(null), .{});
    defer host.deinit();

    const Collector = struct {
        queue_updates: usize = 0,

        fn onEvent(event: SessionEvent, ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            switch (event) {
                .queue_update => self.queue_updates += 1,
                else => {},
            }
        }
    };

    var collector = Collector{};
    const token = host.subscribeEvents(&Collector.onEvent, @ptrCast(&collector));
    defer host.unsubscribeEvents(token);

    const before_session_id = host.currentSession().session_store.sessionId();
    try host.newSession();
    try testing.expect(!std.mem.eql(u8, before_session_id, host.currentSession().session_store.sessionId()));

    try testing.expectEqual(.ok, host.currentSession().agent.followUp(.{ .user = .{
        .content = .{ .text = "queued after replace" },
        .timestamp = 1,
    } }));
    try testing.expectEqual(@as(usize, 1), collector.queue_updates);
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
        .on_compaction_end = &LifecycleCollector.onCompactionEnd,
        .ctx = @ptrCast(&collector),
    });

    const outcome = try host.runUserContent(.{ .text = "hi" });

    try testing.expectEqual(RunOutcome.success, outcome);
    try testing.expectEqual(@as(usize, 2), fp.call_count);
    try testing.expectEqual(@as(usize, 1), compaction_spy.calls.items.len);
    try testing.expectEqual(CompactionReason.overflow, compaction_spy.calls.items[0]);
    try testing.expectEqual(@as(usize, 1), collector.compaction_ends.items.len);
    try testing.expect(collector.compaction_ends.items[0].success);
    try testing.expect(collector.compaction_ends.items[0].will_retry);
    try testing.expectEqual(@as(usize, 0), collector.retry_starts.items.len);
    try testing.expectEqual(@as(usize, 2), host.currentSession().agent.messages().len);
    try testing.expectEqualStrings("after compaction", host.currentSession().agent.messages()[1].assistant.content[0].text.text);
}
