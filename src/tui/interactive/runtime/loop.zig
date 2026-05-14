const std = @import("std");
const logging = @import("../../../logging.zig");
const coding_agent_mod = @import("../../../coding_agent/root.zig");
const request_mod = @import("../../../coding_agent/request.zig");
const auth_types = @import("../../../coding_agent/auth/types.zig");
const oauth_mod = @import("../../../coding_agent/auth/oauth.zig");
const extension_runner_mod = @import("../../../coding_agent/extensions/runner.zig");
const agent_requests_mod = @import("../agent_requests.zig");
const RuntimeHost = @import("../../../coding_agent/runtime_host.zig").RuntimeHost;
const UiEvent = @import("../../ui_event.zig").UiEvent;
const queues_mod = @import("queues.zig");
const tool_display_mod = @import("../../transcript/tool_display.zig");
const ai_complete_worker_mod = @import("../../../coding_agent/extensions/ai_complete_worker.zig");
const system_worker_mod = @import("../../../coding_agent/extensions/system_worker.zig");
const job_manager_mod = @import("job_manager.zig");
const conversation_publish = @import("../conversation_publish.zig");
const model_requests_mod = @import("../model_requests.zig");
const theme_flow = @import("../theme_flow.zig");
const status_snapshot_mod = @import("../status_snapshot.zig");
const log = std.log.scoped(.tui_interactive);

const Interactive = @import("../../interactive.zig").Interactive;
const TerminalSystemQueue = @import("../../interactive.zig").TerminalSystemQueue;
const AgentRequest = coding_agent_mod.AgentRequest;
const ExtensionRunner = coding_agent_mod.ExtensionRunner;

pub const agentThread = agentThreadFn;
pub const submitExtensionAsyncResult = submitExtensionAsyncResultFn;
pub const submitExtensionAiCompleteEvent = submitExtensionAiCompleteEventFn;
pub const submitExtensionAsyncFromRunner = extensionAsyncDispatcher;
pub const dispatchExtensionOAuthRefresh = dispatchExtensionOAuthRefreshViaRequestQueue;

pub const AgentRuntime = struct {
    ui_ptr: *anyopaque,
    msg_allocator: std.mem.Allocator,
    runtime_host: *RuntimeHost,
    request_queue: *coding_agent_mod.RequestQueue,
    snapshot_event_queue: *queues_mod.UiSnapshotQueue,
    lifecycle_event_queue: *queues_mod.UiLifecycleQueue,
    snapshot_coalesced_dropped: *usize,
    last_published_queued_version: *u64,
    last_published_status_snapshot: *?status_snapshot_mod.PublishedStatusSnapshot,
    resolver: *tool_display_mod.ToolRendererResolver,
    ai_complete_worker: *?ai_complete_worker_mod.AiCompleteWorker,
    system_worker: *?system_worker_mod.SystemWorker,
    terminal_system_queue: *TerminalSystemQueue,
    job_manager: *job_manager_mod.JobManager,
    extension_command_actions: extension_runner_mod.ExtensionCommandActions = undefined,
    extension_deferred_user_prompts: std.ArrayListUnmanaged([]u8) = .empty,

    pub fn init(self: *Interactive) AgentRuntime {
        return .{
            .ui_ptr = @ptrCast(self),
            .msg_allocator = self.msg_allocator,
            .runtime_host = &self.runtime_host,
            .request_queue = &self.request_queue,
            .snapshot_event_queue = &self.snapshot_event_queue,
            .lifecycle_event_queue = &self.lifecycle_event_queue,
            .snapshot_coalesced_dropped = &self.snapshot_coalesced_dropped,
            .last_published_queued_version = &self.last_published_queued_version,
            .last_published_status_snapshot = &self.last_published_status_snapshot,
            .resolver = &self.resolver,
            .ai_complete_worker = &self.ai_complete_worker,
            .system_worker = &self.system_worker,
            .terminal_system_queue = &self.terminal_system_queue,
            .job_manager = &self.job_manager,
        };
    }

    pub fn deinit(self: *AgentRuntime) void {
        for (self.extension_deferred_user_prompts.items) |prompt| self.msg_allocator.free(prompt);
        self.extension_deferred_user_prompts.deinit(self.msg_allocator);
    }

    fn ui(self: *AgentRuntime) *Interactive {
        return @ptrCast(@alignCast(self.ui_ptr));
    }

    pub fn publishLifecycleUiEvent(self: *AgentRuntime, event: UiEvent) bool {
        switch (self.lifecycle_event_queue.trySend(event)) {
            .ok => return true,
            .dropped => unreachable,
            .closed, .full, .oom => |rejected| {
                var failed = rejected;
                defer failed.deinit(self.msg_allocator);
                log.warn("lifecycle queue rejected ui event", .{});
                return false;
            },
        }
    }

    pub fn publishSnapshotUiEvent(self: *AgentRuntime, event: UiEvent) bool {
        self.coalescePendingSnapshot(event);
        switch (self.snapshot_event_queue.trySend(event)) {
            .ok => return true,
            .dropped => return false,
            .closed, .full, .oom => |rejected| {
                var failed = rejected;
                failed.deinit(self.msg_allocator);
                return false;
            },
        }
    }

    fn coalescePendingSnapshot(self: *AgentRuntime, event: UiEvent) void {
        const dropped = switch (event) {
            .conversation_snapshot, .queued_snapshot, .status_snapshot => self.snapshot_event_queue.dropMatching(sameEventTag, @constCast(&event)),
            else => 0,
        };
        self.snapshot_coalesced_dropped.* += dropped;
    }

    pub fn publishExtensionCommandsUpdate(self: *AgentRuntime) void {
        self.ui().publishExtensionCommandsUpdate();
    }
    pub fn publishExtensionKeybindingsSnapshot(self: *AgentRuntime) void {
        self.ui().publishExtensionKeybindingsSnapshot();
    }
    pub fn publishPendingExtensionUi(self: *AgentRuntime) void {
        self.ui().publishPendingExtensionUi();
    }
    pub fn handleManualCompactRequest(self: *AgentRuntime, custom_instructions: ?[]const u8) void {
        self.ui().handleManualCompactRequest(custom_instructions);
    }
    pub fn handleNewSession(self: *AgentRuntime) void {
        self.ui().handleNewSession();
    }
    pub fn handleForkSession(self: *AgentRuntime, entry_id: []const u8) void {
        self.ui().handleForkSession(entry_id);
    }
    pub fn handleResumeSession(self: *AgentRuntime, path: []const u8, restore_session_model: bool) void {
        self.ui().handleResumeSession(path, restore_session_model);
    }
    pub fn publishConversationState(self: *AgentRuntime) bool {
        return conversation_publish.publishConversationStateWithPublisher(self.conversationPublisher());
    }
    pub fn publishQueuedSnapshotIfChanged(self: *AgentRuntime) void {
        conversation_publish.publishQueuedSnapshotIfChangedWithPublisher(self.conversationPublisher());
    }
    pub fn handleSetModel(self: *AgentRuntime, m: anytype) void {
        self.ui().handleSetModel(m);
    }
    pub fn handleSetModelPattern(self: *AgentRuntime, pattern: []const u8) void {
        self.ui().handleSetModelPattern(pattern);
    }
    pub fn publishThemeSnapshot(self: *AgentRuntime) void {
        theme_flow.publishSnapshotWithPublisher(self.runtime_host, self);
    }
    pub fn publishVisibleModelsSnapshot(self: *AgentRuntime) void {
        model_requests_mod.publishVisibleModelsSnapshotWithPublisher(self.modelSnapshotPublisher());
    }
    pub fn publishStatusSnapshot(self: *AgentRuntime) void {
        model_requests_mod.publishStatusSnapshotWithPublisher(self.modelSnapshotPublisher());
    }
    pub fn handleSetThinkingLevel(self: *AgentRuntime, level: anytype) void {
        self.ui().handleSetThinkingLevel(level);
    }
    pub fn discardAgentRequests(self: *AgentRuntime, requests: []AgentRequest) void {
        discardRequests(self.msg_allocator, requests);
    }
    pub fn discardQueuedAgentRequests(self: *AgentRuntime) void {
        discardQueuedRequests(self.msg_allocator, self.request_queue);
    }
    pub fn enqueueTerminalSystem(self: *AgentRuntime, id: extension_runner_mod.AsyncOpId, request: extension_runner_mod.SystemRequest) !void {
        const cloned = try request.clone(self.msg_allocator);
        switch (self.terminal_system_queue.trySend(.{ .id = id, .system = cloned })) {
            .ok => {},
            .full, .closed, .oom => |rejected| {
                var failed = rejected;
                failed.deinit(self.msg_allocator);
                return error.TerminalSystemQueueUnavailable;
            },
            .dropped => unreachable,
        }
    }

    fn conversationPublisher(self: *AgentRuntime) conversation_publish.Publisher {
        return .{
            .runtime_host = self.runtime_host,
            .publish_snapshot = &publishConversationSnapshotFromRuntime,
            .publish_ctx = @ptrCast(self),
            .last_published_queued_version = self.last_published_queued_version,
        };
    }

    fn modelSnapshotPublisher(self: *AgentRuntime) model_requests_mod.SnapshotPublisher {
        return .{
            .msg_allocator = self.msg_allocator,
            .runtime_host = self.runtime_host,
            .last_published_status_snapshot = self.last_published_status_snapshot,
            .publish_snapshot = &publishSnapshotUiEventFromRuntime,
            .publish_lifecycle = &publishLifecycleUiEventFromRuntime,
            .ctx = @ptrCast(self),
        };
    }
};

fn publishSnapshotUiEventFromRuntime(ctx: ?*anyopaque, event: UiEvent) bool {
    const self: *AgentRuntime = @ptrCast(@alignCast(ctx.?));
    return self.publishSnapshotUiEvent(event);
}

fn publishLifecycleUiEventFromRuntime(ctx: ?*anyopaque, event: UiEvent) bool {
    const self: *AgentRuntime = @ptrCast(@alignCast(ctx.?));
    return self.publishLifecycleUiEvent(event);
}

fn publishConversationSnapshotFromRuntime(ctx: ?*anyopaque, event: conversation_publish.Publisher.UiSnapshot) bool {
    const self: *AgentRuntime = @ptrCast(@alignCast(ctx.?));
    return switch (event) {
        .conversation => |snapshot| self.publishSnapshotUiEvent(.{ .conversation_snapshot = snapshot }),
        .queued => |snapshot| self.publishSnapshotUiEvent(.{ .queued_snapshot = snapshot }),
    };
}

fn sameEventTag(item: *const UiEvent, ctx: ?*anyopaque) bool {
    const target: *const UiEvent = @ptrCast(@alignCast(ctx.?));
    return std.meta.activeTag(item.*) == std.meta.activeTag(target.*);
}

pub fn enqueueShutdown(self: *Interactive) void {
    switch (self.request_queue.trySend(.{ .shutdown = {} })) {
        .ok, .dropped => {},
        .closed, .full, .oom => {},
    }
}

// Agent thread mutates session and extension state. UI code sends requests through queues.
pub fn discardRequests(allocator: std.mem.Allocator, requests: []AgentRequest) void {
    for (requests) |*req| req.deinit(allocator);
}

pub fn discardQueuedRequests(allocator: std.mem.Allocator, request_queue: *coding_agent_mod.RequestQueue) void {
    var buf: [16]AgentRequest = undefined;
    while (true) {
        const n = request_queue.drainInto(&buf);
        if (n == 0) return;
        discardRequests(allocator, buf[0..n]);
    }
}

pub fn processRequests(self: anytype) bool {
    return agent_requests_mod.processWithBuffer(self, AgentRequest, &extensionAsyncDispatcher);
}

fn dispatchExtensionOAuthRefreshViaRequestQueue(
    provider_id: []const u8,
    credential: auth_types.OAuthCredential,
    result_allocator: std.mem.Allocator,
    ctx: ?*anyopaque,
) oauth_mod.ExchangeResult {
    const self: *Interactive = @ptrCast(@alignCast(ctx.?));
    var response: request_mod.ExtensionOAuthRefreshResponse = .{};
    const provider_copy = self.msg_allocator.dupe(u8, provider_id) catch return .{ .err = "out of memory" };
    const credential_copy = auth_types.cloneOAuthCredential(self.msg_allocator, credential) catch {
        self.msg_allocator.free(provider_copy);
        return .{ .err = "out of memory" };
    };
    switch (self.request_queue.trySend(.{ .extension_oauth_refresh = .{
        .provider_id = provider_copy,
        .credential = credential_copy,
        .result_allocator = result_allocator,
        .response = &response,
    } })) {
        .ok => {},
        .full => |rejected| {
            var req = rejected;
            req.deinit(self.msg_allocator);
            return .{ .err = "refresh request queue is full" };
        },
        .closed => |rejected| {
            var req = rejected;
            req.deinit(self.msg_allocator);
            return .{ .err = "refresh request queue is closed" };
        },
        .oom => return .{ .err = "out of memory" },
        .dropped => unreachable,
    }
    return switch (response.wait()) {
        .success => |cred| .{ .success = cred },
        .err => |msg| .{ .err = msg },
        .unsupported => .{ .err = "extension OAuth refresh is unsupported for this provider" },
    };
}

fn agentThreadFn(self: *AgentRuntime) void {
    logging.setThreadLabel(.agent);

    if (self.runtime_host.currentSession().extensionRunner()) |runner| {
        runner.bindLuaOwnerThread(std.Thread.getCurrentId());
        self.publishExtensionCommandsUpdate();
    }
    self.publishVisibleModelsSnapshot();
    _ = self.publishConversationState();
    self.publishQueuedSnapshotIfChanged();

    while (true) {
        _ = self.request_queue.waitReadable(-1) catch break;
        if (self.request_queue.isDrained()) break;
        if (!processRequests(self)) break;
        if (self.request_queue.isDrained()) break;
    }

    self.runtime_host.shutdownCurrentSessionOnAgentThread();
}

fn submitExtensionAsyncResultFn(ptr: *anyopaque, id: extension_runner_mod.AsyncOpId, result: extension_runner_mod.AsyncResult) bool {
    const self: *Interactive = @ptrCast(@alignCast(ptr));
    switch (self.request_queue.trySend(.{ .extension_async_result = .{ .id = id, .result = result } })) {
        .ok, .dropped => return true,
        .full, .closed, .oom => |rejected| {
            var failed = rejected;
            failed.deinit(self.msg_allocator);
            return false;
        },
    }
}
fn submitExtensionAiCompleteEventFn(ptr: *anyopaque, id: extension_runner_mod.AsyncOpId, event: extension_runner_mod.AiCompleteStreamEvent) bool {
    const self: *Interactive = @ptrCast(@alignCast(ptr));
    switch (self.request_queue.trySend(.{ .extension_async_event = .{ .id = id, .event = event } })) {
        .ok, .dropped => return true,
        .full, .closed, .oom => |rejected| {
            var failed = rejected;
            failed.deinit(self.msg_allocator);
            return false;
        },
    }
}

pub fn extensionAsyncDispatcher(self: *AgentRuntime) extension_runner_mod.AsyncDispatcher {
    return .{
        .ptr = @ptrCast(self),
        .submit = &submitExtensionAsyncFromRunnerFn,
        .job_start = &startExtensionJobFromRunnerFn,
        .job_write = &writeExtensionJobFromRunnerFn,
        .job_stop = &stopExtensionJobFromRunnerFn,
        .ai_complete_event = &dispatchAiCompleteEventFromRunnerFn,
    };
}

const SidePromptEventQueue = struct {
    runtime: *AgentRuntime,
    id: extension_runner_mod.AsyncOpId,
    dropped: usize = 0,

    fn emit(ptr: *anyopaque, event: extension_runner_mod.AiCompleteStreamEvent) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        deliverAiSessionPromptEvent(self.runtime, self.id, event) catch {
            self.dropped += 1;
        };
    }
};

fn deliverAiSessionPromptEvent(self: *AgentRuntime, id: extension_runner_mod.AsyncOpId, event: extension_runner_mod.AiCompleteStreamEvent) !void {
    const runner = self.runtime_host.currentSession().extensionRunner() orelse return error.MissingExtensionRunner;
    const owned = try event.clone(runner.allocator);
    try runner.dispatchAiCompleteStreamEvent(id, owned);
    self.publishPendingExtensionUi();
}

fn dispatchAiCompleteEventFromRunnerFn(ptr: *anyopaque, runner: *ExtensionRunner, id: extension_runner_mod.AsyncOpId, event: extension_runner_mod.AiCompleteStreamEvent) anyerror!void {
    const self: *AgentRuntime = @ptrCast(@alignCast(ptr));
    var original = event;
    defer original.deinit(runner.allocator);
    const cloned = try event.clone(self.msg_allocator);
    switch (self.request_queue.trySend(.{ .extension_async_event = .{ .id = id, .event = cloned } })) {
        .ok, .dropped => {},
        .full, .closed, .oom => |rejected| {
            var failed = rejected;
            failed.deinit(self.msg_allocator);
            return error.AiCompleteEventUnavailable;
        },
    }
}

fn submitExtensionAsyncFromRunnerFn(ptr: *anyopaque, runner: *ExtensionRunner, start: extension_runner_mod.AsyncStart) anyerror!void {
    const self: *AgentRuntime = @ptrCast(@alignCast(ptr));
    var owned_start = start;
    defer owned_start.deinit(runner.allocator);
    switch (owned_start.request) {
        .ai_complete => |request| {
            const worker_request = try self.runtime_host.currentSession().buildAiCompleteWorkerRequest(self.msg_allocator, owned_start.id, request);
            var submitted = false;
            errdefer if (!submitted) {
                var failed = worker_request;
                failed.deinit(self.msg_allocator);
            };
            const worker = if (self.ai_complete_worker.*) |*worker| worker else return error.AiCompleteWorkerUnavailable;
            try worker.submit(worker_request);
            submitted = true;
        },
        .ai_session_prompt => |request| {
            const session = self.runtime_host.currentSession();
            var event_queue = SidePromptEventQueue{ .runtime = self, .id = owned_start.id };
            var result = try session.runAiSessionAgentPrompt(self.msg_allocator, request, .{ .ptr = @ptrCast(&event_queue), .emit = SidePromptEventQueue.emit });
            errdefer result.deinit(self.msg_allocator);
            if (event_queue.dropped > 0) try deliverAiSessionPromptEvent(self, owned_start.id, .{ .events_dropped = event_queue.dropped });
            switch (result.status) {
                .completed => {},
                .err => |msg| try deliverAiSessionPromptEvent(self, owned_start.id, .{ .err = msg }),
                .cancelled => {},
            }
            switch (self.request_queue.trySend(.{ .extension_async_result = .{ .id = owned_start.id, .result = .{ .ai_session_prompt = result } } })) {
                .ok, .dropped => {},
                .full, .closed, .oom => |rejected| {
                    var failed = rejected;
                    failed.deinit(self.msg_allocator);
                    return error.AiSessionPromptUnavailable;
                },
            }
        },
        .system => |request| {
            switch (request.stdio) {
                .capture => {
                    const cloned = try request.clone(self.msg_allocator);
                    var submitted = false;
                    errdefer if (!submitted) {
                        var failed = cloned;
                        failed.deinit(self.msg_allocator);
                    };
                    const worker = if (self.system_worker.*) |*worker| worker else return error.SystemWorkerUnavailable;
                    try worker.submit(.{ .id = owned_start.id, .system = cloned });
                    submitted = true;
                },
                .terminal => try self.enqueueTerminalSystem(owned_start.id, request),
            }
        },
        else => {},
    }
}

fn startExtensionJobFromRunnerFn(ptr: *anyopaque, runner: *ExtensionRunner, id: u64, request: extension_runner_mod.JobStartRequest) anyerror!void {
    const self: *AgentRuntime = @ptrCast(@alignCast(ptr));
    var original = request;
    defer original.deinit(runner.allocator);
    const cloned = try request.clone(self.msg_allocator);
    try self.job_manager.start(id, cloned);
}

fn writeExtensionJobFromRunnerFn(ptr: *anyopaque, _: *ExtensionRunner, id: u64, data: []const u8) anyerror!void {
    const self: *AgentRuntime = @ptrCast(@alignCast(ptr));
    try self.job_manager.write(id, data);
}

fn stopExtensionJobFromRunnerFn(ptr: *anyopaque, _: *ExtensionRunner, id: u64) anyerror!void {
    const self: *AgentRuntime = @ptrCast(@alignCast(ptr));
    self.job_manager.stop(id);
}
