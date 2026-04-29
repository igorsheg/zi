const std = @import("std");
const logging = @import("../../logging.zig");
const coding_agent_mod = @import("../../coding_agent/root.zig");
const request_mod = @import("../../coding_agent/request.zig");
const auth_types = @import("../../coding_agent/auth/types.zig");
const oauth_mod = @import("../../coding_agent/auth/oauth.zig");
const extension_runner_mod = @import("../../coding_agent/extensions/runner.zig");
const agent_requests_mod = @import("agent_requests.zig");

const Interactive = @import("../interactive.zig").Interactive;
const AgentRequest = coding_agent_mod.AgentRequest;
const ExtensionRunner = coding_agent_mod.ExtensionRunner;

pub const agentThread = agentThreadFn;
pub const submitExtensionAsyncResult = submitExtensionAsyncResultFn;
pub const submitExtensionAsyncFromRunner = submitExtensionAsyncFromRunnerFn;
pub const dispatchExtensionOAuthRefresh = dispatchExtensionOAuthRefreshViaRequestQueue;

pub fn enqueueShutdown(self: *Interactive) void {
    switch (self.request_queue.trySend(.{ .shutdown = {} })) {
        .ok, .dropped => {},
        .closed, .full, .oom => {},
    }
}

pub fn discardRequests(self: *Interactive, requests: []AgentRequest) void {
    for (requests) |*req| req.deinit(self.msg_allocator);
}

pub fn discardQueuedRequests(self: *Interactive) void {
    var buf: [16]AgentRequest = undefined;
    while (true) {
        const n = self.request_queue.drainInto(&buf);
        if (n == 0) return;
        discardRequests(self, buf[0..n]);
    }
}

pub fn processRequests(self: *Interactive) bool {
    return agent_requests_mod.processWithBuffer(self, AgentRequest, &submitExtensionAsyncFromRunnerFn);
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

fn agentThreadFn(self: *Interactive) void {
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

fn submitExtensionAsyncFromRunnerFn(ptr: *anyopaque, runner: *ExtensionRunner, start: extension_runner_mod.AsyncStart) anyerror!void {
    const self: *Interactive = @ptrCast(@alignCast(ptr));
    var owned_start = start;
    defer owned_start.deinit(runner.allocator);
    switch (owned_start.request) {
        .ai_complete => |request| {
            const worker_request = try self.runtime_host.currentSession().buildAiCompleteWorkerRequest(self.msg_allocator, owned_start.id, request);
            errdefer {
                var failed = worker_request;
                failed.deinit(self.msg_allocator);
            }
            const worker = if (self.ai_complete_worker) |*worker| worker else return error.AiCompleteWorkerUnavailable;
            try worker.submit(worker_request);
        },
        .system => |request| {
            const cloned = try request.clone(self.msg_allocator);
            errdefer {
                var failed = cloned;
                failed.deinit(self.msg_allocator);
            }
            const worker = if (self.system_worker) |*worker| worker else return error.SystemWorkerUnavailable;
            try worker.submit(.{ .id = owned_start.id, .system = cloned });
        },
        else => {},
    }
}
