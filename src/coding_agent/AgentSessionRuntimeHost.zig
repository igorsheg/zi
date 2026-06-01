const std = @import("std");
const zio = @import("zio");
const agent_mod = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const faux = @import("../ai/providers/faux.zig");
const runtime = @import("../runtime/root.zig");
const AgentSession = @import("AgentSession.zig");
const session_events = @import("session_events.zig");
const session_manager = @import("session_manager.zig");
const session_store = @import("session_store.zig");
const tool_registry = @import("tool_registry.zig");

const AgentSessionRuntimeHost = @This();

allocator: std.mem.Allocator,
io: std.Io,
base: BaseOptions,
session: AgentSession,
rebind_session: ?RebindSession = null,
before_session_invalidate: ?BeforeSessionInvalidate = null,

pub const BaseOptions = struct {
    cwd: []const u8,
    agent_dir: []const u8,
    current_date: []const u8,
    model: ai.Model = agent_mod.Agent.defaultModel(),
    thinking_level: agent_mod.ThinkingLevel = .off,
    compaction_settings: session_manager.CompactionSettings = .{},
    retry_settings: AgentSession.RetrySettings = .{},
    stream: ?ai.StreamFunction = null,
    get_api_key: ?agent_mod.GetApiKeyHook = null,
    zio_runtime: *runtime.Runtime,
    dir: std.Io.Dir = .cwd(),
    allow_paths_outside_cwd: bool = false,
    public_event_capacity: usize = AgentSession.public_event_capacity_default,
};

pub const SessionStart = struct {
    session_id: []const u8,
    timestamp: []const u8,
    session_store: ?session_store.SessionStore = null,
    resume_session_store: ?session_store.SessionStore = null,
};

pub const RebindSession = struct {
    context: ?*anyopaque = null,
    call_fn: *const fn (context: ?*anyopaque, session: *AgentSession) void,

    fn call(self: RebindSession, session: *AgentSession) void {
        self.call_fn(self.context, session);
    }
};

pub const BeforeSessionInvalidate = struct {
    context: ?*anyopaque = null,
    call_fn: *const fn (context: ?*anyopaque) void,

    fn call(self: BeforeSessionInvalidate) void {
        self.call_fn(self.context);
    }
};

pub const ReplaceResult = struct {
    old_event_count: usize,
};

pub const NewSessionResult = struct {
    cancelled: bool = false,
    old_event_count: usize,
};

pub const PublicEventHandler = struct {
    context: ?*anyopaque = null,
    call_fn: *const fn (context: ?*anyopaque, event: session_events.AgentSessionEvent) anyerror!void,

    fn call(self: PublicEventHandler, event: session_events.AgentSessionEvent) anyerror!void {
        try self.call_fn(self.context, event);
    }
};

pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    base: BaseOptions,
    start: SessionStart,
) !AgentSessionRuntimeHost {
    const session = try AgentSession.init(allocator, io, buildSessionOptions(base, start));
    return .{
        .allocator = allocator,
        .io = io,
        .base = base,
        .session = session,
    };
}

pub fn deinit(self: *AgentSessionRuntimeHost) void {
    self.session.deinit();
    self.* = undefined;
}

pub fn sessionHeader(self: *const AgentSessionRuntimeHost) session_manager.SessionHeader {
    return self.session.manager.header;
}

pub fn sessionId(self: *const AgentSessionRuntimeHost) []const u8 {
    return self.session.manager.header.id;
}

pub fn setRebindSession(self: *AgentSessionRuntimeHost, rebind_session: ?RebindSession) void {
    self.rebind_session = rebind_session;
}

pub fn setBeforeSessionInvalidate(
    self: *AgentSessionRuntimeHost,
    before_session_invalidate: ?BeforeSessionInvalidate,
) void {
    self.before_session_invalidate = before_session_invalidate;
}

pub fn newSession(self: *AgentSessionRuntimeHost, start: SessionStart) !NewSessionResult {
    const result = try self.replaceSession(start);
    return .{ .old_event_count = result.old_event_count };
}

pub fn replaceSession(self: *AgentSessionRuntimeHost, start: SessionStart) !ReplaceResult {
    if (self.session.statusSnapshot().status != .idle) return error.SessionReplacementRequiresIdle;

    var next_session = try AgentSession.init(self.allocator, self.io, buildSessionOptions(self.base, start));
    var next_session_needs_deinit = true;
    errdefer if (next_session_needs_deinit) shutdownAndDeinitSession(&next_session);

    self.session.requestShutdown();
    const old_event_count = drainSessionEvents(&self.session);
    if (!self.session.shutdownComplete()) return error.SessionReplacementRequiresShutdownComplete;

    if (self.before_session_invalidate) |callback| callback.call();
    self.session.deinit();
    next_session_needs_deinit = false;
    self.session = next_session;

    if (self.rebind_session) |callback| callback.call(&self.session);
    return .{ .old_event_count = old_event_count };
}

pub fn startPromptRun(
    self: *AgentSessionRuntimeHost,
    text: []const u8,
    images: []const ai.ImageContent,
    options: AgentSession.PromptOptions,
) !*AgentSession.LivePromptRun {
    return self.session.startLivePromptRun(text, images, options);
}

pub fn stepPromptRun(self: *AgentSessionRuntimeHost, run: *AgentSession.LivePromptRun) !bool {
    return self.session.stepPromptRun(run);
}

pub fn drainPromptRunReady(self: *AgentSessionRuntimeHost, run: *AgentSession.LivePromptRun) !?bool {
    return self.session.drainPromptRunReady(run);
}

pub fn promptRunProgress(
    _: *AgentSessionRuntimeHost,
    run: *AgentSession.LivePromptRun,
) @TypeOf(AgentSession.promptRunProgress(run)) {
    return AgentSession.promptRunProgress(run);
}

pub fn applyPromptRunProgress(
    self: *AgentSessionRuntimeHost,
    run: *AgentSession.LivePromptRun,
    progress: @TypeOf(AgentSession.promptRunProgress(run)).Result,
) !bool {
    return self.session.applyPromptRunProgress(run, progress);
}

pub fn destroyPromptRun(self: *AgentSessionRuntimeHost, run: *AgentSession.LivePromptRun) void {
    self.session.destroyPromptRun(run);
}

pub fn continueRun(self: *AgentSessionRuntimeHost) !void {
    try self.session.continueRun();
}

pub fn compactWithPreparedSummary(
    self: *AgentSessionRuntimeHost,
    summary: []const u8,
) !session_events.CompactionResult {
    return self.session.compactWithPreparedSummary(summary);
}

pub fn compactWithGeneratedSummary(
    self: *AgentSessionRuntimeHost,
) !session_events.CompactionResult {
    return self.session.compactWithGeneratedSummary();
}

pub fn prepareCompactionSnapshot(
    self: *AgentSessionRuntimeHost,
) !session_events.CompactionPreparationSnapshot {
    return self.session.prepareCompactionSnapshot();
}

pub fn prepareCompactionSummaryInputSnapshot(
    self: *AgentSessionRuntimeHost,
) !session_events.CompactionSummaryInputSnapshot {
    return self.session.prepareCompactionSummaryInputSnapshot();
}

pub fn cancel(self: *AgentSessionRuntimeHost) void {
    self.session.cancel();
}

pub fn requestShutdown(self: *AgentSessionRuntimeHost) void {
    self.session.requestShutdown();
}

pub fn statusSnapshot(self: *AgentSessionRuntimeHost) AgentSession.RuntimeStatusSnapshot {
    return self.session.statusSnapshot();
}

pub fn zioRuntime(self: *AgentSessionRuntimeHost) *runtime.Runtime {
    return self.session.zio_runtime;
}

pub fn queueSnapshot(self: *const AgentSessionRuntimeHost, allocator: std.mem.Allocator) !session_events.QueueSnapshot {
    return self.session.queueSnapshot(allocator);
}

pub fn drainPublicEvent(self: *AgentSessionRuntimeHost) ?session_events.AgentSessionEvent {
    return self.session.drainPublicEvent();
}

pub fn drainPublicEvents(self: *AgentSessionRuntimeHost, handler: PublicEventHandler) !usize {
    var count: usize = 0;
    while (self.drainPublicEvent()) |event| {
        var owned_event = event;
        defer owned_event.deinit();
        try handler.call(owned_event);
        count += 1;
    }
    return count;
}

pub fn shutdownComplete(self: *AgentSessionRuntimeHost) bool {
    return self.session.shutdownComplete();
}

fn buildSessionOptions(base: BaseOptions, start: SessionStart) AgentSession.Options {
    return .{
        .cwd = base.cwd,
        .agent_dir = base.agent_dir,
        .current_date = base.current_date,
        .session_id = start.session_id,
        .timestamp = start.timestamp,
        .session_store = start.session_store,
        .resume_session_store = start.resume_session_store,
        .model = base.model,
        .thinking_level = base.thinking_level,
        .compaction_settings = base.compaction_settings,
        .retry_settings = base.retry_settings,
        .stream = base.stream,
        .get_api_key = base.get_api_key,
        .zio_runtime = base.zio_runtime,
        .dir = base.dir,
        .allow_paths_outside_cwd = base.allow_paths_outside_cwd,
        .public_event_capacity = base.public_event_capacity,
    };
}

fn shutdownAndDeinitSession(session: *AgentSession) void {
    session.requestShutdown();
    _ = drainSessionEvents(session);
    session.deinit();
}

fn drainSessionEvents(session: *AgentSession) usize {
    var count: usize = 0;
    while (session.drainPublicEvent()) |event| {
        var owned_event = event;
        defer owned_event.deinit();
        count += 1;
    }
    return count;
}

fn drainHostEvents(host: *AgentSessionRuntimeHost) void {
    _ = host.drainPublicEvents(.{ .call_fn = ignorePublicEvent }) catch unreachable;
}

fn ignorePublicEvent(_: ?*anyopaque, _: session_events.AgentSessionEvent) !void {}

fn runPromptForTest(host: *AgentSessionRuntimeHost, text: []const u8) !void {
    const run = try host.startPromptRun(text, &.{}, .{});
    defer host.destroyPromptRun(run);
    while (try host.stepPromptRun(run)) {}
}

const EchoTool = struct {
    call_count: usize = 0,

    pub fn tool(self: *EchoTool) agent_mod.AgentTool {
        return .{
            .name = "echo",
            .description = "Echo test tool",
            .parameters = .{ .object = .empty },
            .label = "echo",
            .execute = .{ .context = self, .call_fn = execute },
        };
    }

    fn execute(
        allocator: std.mem.Allocator,
        _: std.Io,
        _: *runtime.Runtime,
        context: ?*anyopaque,
        _: runtime.CancelToken,
        _: []const u8,
        _: std.json.Value,
        _: ?agent_mod.AgentToolUpdateCallback,
    ) anyerror!agent_mod.ToolExecutionResult {
        const self: *EchoTool = @ptrCast(@alignCast(context.?));
        self.call_count += 1;
        const content = try allocator.alloc(ai.ToolResultContent, 1);
        content[0] = .{ .text = .{ .text = try allocator.dupe(u8, "echoed") } };
        return .{ .allocator = allocator, .result = .{ .content = content } };
    }
};

const ToolLoopObservation = struct {
    user_message_end: bool = false,
    tool_execution_start: bool = false,
    tool_execution_end: bool = false,
    final_text_delta: bool = false,
    agent_end_with_tool_result: bool = false,
    agent_end: bool = false,

    fn onEvent(context: ?*anyopaque, event: session_events.AgentSessionEvent) !void {
        const self: *ToolLoopObservation = @ptrCast(@alignCast(context.?));
        if (event != .agent_event) return;

        switch (event.agent_event) {
            .message_end => |payload| switch (payload.message) {
                .user => self.user_message_end = true,
                else => {},
            },
            .message_update => |payload| {
                switch (payload.assistant_message_event) {
                    .text_delta => |delta| {
                        if (std.mem.indexOf(u8, delta.delta, "done after tool") != null) {
                            self.final_text_delta = true;
                        }
                    },
                    else => {},
                }
            },
            .tool_execution_start => |payload| {
                if (std.mem.eql(u8, payload.tool_call_id, "tool-1") and
                    std.mem.eql(u8, payload.tool_name, "echo"))
                {
                    self.tool_execution_start = true;
                }
            },
            .tool_execution_end => |payload| {
                if (std.mem.eql(u8, payload.tool_call_id, "tool-1") and
                    std.mem.eql(u8, payload.tool_name, "echo"))
                {
                    self.tool_execution_end = true;
                }
            },
            .agent_end => |payload| {
                self.agent_end = true;
                for (payload.messages) |message| {
                    if (message == .tool_result and std.mem.eql(u8, message.tool_result.tool_call_id, "tool-1")) {
                        self.agent_end_with_tool_result = true;
                    }
                }
            },
            else => {},
        }
    }
};

const BashLimitObservation = struct {
    tool_execution_start: bool = false,
    tool_execution_end: bool = false,
    tool_error: bool = false,
    output_limit_exceeded: bool = false,
    tool_result_message: bool = false,

    fn onEvent(context: ?*anyopaque, event: session_events.AgentSessionEvent) !void {
        const self: *BashLimitObservation = @ptrCast(@alignCast(context.?));
        if (event != .agent_event) return;

        switch (event.agent_event) {
            .tool_execution_start => |payload| {
                if (std.mem.eql(u8, payload.tool_name, "bash")) self.tool_execution_start = true;
            },
            .tool_execution_end => |payload| {
                if (!std.mem.eql(u8, payload.tool_name, "bash")) return;
                self.tool_execution_end = true;
                self.tool_error = payload.is_error;
                if (payload.result.details) |details| {
                    if (details == .object) {
                        const exceeded = details.object.get("outputLimitExceeded") orelse return;
                        self.output_limit_exceeded = exceeded == .bool and exceeded.bool;
                    }
                }
            },
            .message_end => |payload| switch (payload.message) {
                .tool_result => |message| {
                    if (std.mem.eql(u8, message.tool_name, "bash")) self.tool_result_message = true;
                },
                else => {},
            },
            else => {},
        }
    }
};

fn waitForBashToolStart(host: *AgentSessionRuntimeHost, observed: *BashLimitObservation) !void {
    const yield_count_max = 1024;
    for (0..yield_count_max) |_| {
        _ = try host.drainPublicEvents(.{ .context = observed, .call_fn = BashLimitObservation.onEvent });
        if (observed.tool_execution_start) return;
        try zio.yield();
    }
    return error.BashToolStartNotObserved;
}

test "runtime host replacement invalidates old session before rebinding new session" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var host = try AgentSessionRuntimeHost.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-26",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
    }, .{
        .session_id = "first",
        .timestamp = "2026-05-26T00:00:00Z",
    });
    defer {
        host.requestShutdown();
        drainHostEvents(&host);
        host.deinit();
    }

    const State = struct {
        before_count: usize = 0,
        rebind_count: usize = 0,
        rebound_session_id: []const u8 = "",

        const Self = @This();

        fn before(context: ?*anyopaque) void {
            const state: *Self = @ptrCast(@alignCast(context.?));
            state.before_count += 1;
        }

        fn rebind(context: ?*anyopaque, session: *AgentSession) void {
            const state: *Self = @ptrCast(@alignCast(context.?));
            state.rebind_count += 1;
            state.rebound_session_id = session.manager.header.id;
        }
    };

    var state: State = .{};
    host.setBeforeSessionInvalidate(.{ .context = &state, .call_fn = State.before });
    host.setRebindSession(.{ .context = &state, .call_fn = State.rebind });

    try runPromptForTest(&host, "old event");
    const result = try host.replaceSession(.{
        .session_id = "second",
        .timestamp = "2026-05-26T00:00:01Z",
    });

    try std.testing.expect(result.old_event_count > 0);
    try std.testing.expectEqual(@as(usize, 1), state.before_count);
    try std.testing.expectEqual(@as(usize, 1), state.rebind_count);
    try std.testing.expectEqualStrings("second", state.rebound_session_id);
    try std.testing.expectEqualStrings("second", host.sessionId());
    try std.testing.expectEqual(@as(usize, 0), host.statusSnapshot().public_event_count);
}

test "runtime host new session replaces current session" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var host = try AgentSessionRuntimeHost.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-26",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
    }, .{
        .session_id = "first",
        .timestamp = "2026-05-26T00:00:00Z",
    });
    defer {
        host.requestShutdown();
        drainHostEvents(&host);
        host.deinit();
    }

    const result = try host.newSession(.{
        .session_id = "second",
        .timestamp = "2026-05-26T00:00:01Z",
    });

    try std.testing.expect(!result.cancelled);
    try std.testing.expectEqual(@as(usize, 0), result.old_event_count);
    try std.testing.expectEqualStrings("second", host.sessionId());
}

test "runtime host zio runtime accessor returns explicit session runtime" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var host = try AgentSessionRuntimeHost.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-26",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
    }, .{
        .session_id = "session",
        .timestamp = "2026-05-26T00:00:00Z",
    });
    defer {
        host.requestShutdown();
        drainHostEvents(&host);
        host.deinit();
    }

    try std.testing.expect(host.base.zio_runtime == zio_runtime);
    try std.testing.expect(host.zioRuntime() == host.session.zio_runtime);
}

test "runtime host replacement rejects active old session" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var host = try AgentSessionRuntimeHost.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-26",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
    }, .{
        .session_id = "first",
        .timestamp = "2026-05-26T00:00:00Z",
    });
    defer {
        if (!host.session.agent.waitForIdle()) host.session.agent.finishRun();
        host.requestShutdown();
        drainHostEvents(&host);
        host.deinit();
    }

    _ = try host.session.agent.beginRun();

    try std.testing.expectError(error.SessionReplacementRequiresIdle, host.replaceSession(.{
        .session_id = "second",
        .timestamp = "2026-05-26T00:00:01Z",
    }));
    try std.testing.expectEqualStrings("first", host.sessionId());
}

test "runtime host owns current agent session public boundary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var host = try AgentSessionRuntimeHost.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-26",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
    }, .{
        .session_id = "session",
        .timestamp = "2026-05-26T00:00:00Z",
    });
    defer {
        host.requestShutdown();
        drainHostEvents(&host);
        host.deinit();
    }

    try runPromptForTest(&host, "hello");

    try std.testing.expect(host.statusSnapshot().public_event_count > 0);
    try std.testing.expectEqual(AgentSession.AgentSessionStatus.idle, host.statusSnapshot().status);
    try std.testing.expectEqual(@as(usize, tool_registry.builtin_tool_count), host.session.tools.activeToolNames().len);
}

test "runtime host persists run messages before frontend drains public events" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var host = try AgentSessionRuntimeHost.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-26",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
    }, .{
        .session_id = "session",
        .timestamp = "2026-05-26T00:00:00Z",
    });
    defer {
        host.requestShutdown();
        drainHostEvents(&host);
        host.deinit();
    }

    try runPromptForTest(&host, "durable");
    try std.testing.expect(host.statusSnapshot().public_event_count > 0);

    const context = try host.session.manager.buildSessionContext(std.testing.allocator);
    defer host.session.manager.deinitSessionContext(std.testing.allocator, context);

    try std.testing.expect(context.messages.len >= 1);
    try std.testing.expectEqualStrings("durable", context.messages[0].user.content.string);

    drainHostEvents(&host);
    try std.testing.expectEqual(@as(usize, 0), host.statusSnapshot().public_event_count);
    const drained_context = try host.session.manager.buildSessionContext(std.testing.allocator);
    defer host.session.manager.deinitSessionContext(std.testing.allocator, drained_context);
    try std.testing.expectEqual(context.messages.len, drained_context.messages.len);
}

test "runtime host preserves session header active leaf and context after public drain" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var host = try AgentSessionRuntimeHost.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-26",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
    }, .{
        .session_id = "session",
        .timestamp = "2026-05-26T00:00:00Z",
    });
    defer {
        host.requestShutdown();
        drainHostEvents(&host);
        host.deinit();
    }

    try runPromptForTest(&host, "first");
    const first_leaf = (try host.session.manager.getLeafEntry()).?.id();
    try runPromptForTest(&host, "second");

    const header = host.sessionHeader();
    try std.testing.expectEqualStrings("session", header.id);
    try std.testing.expectEqualStrings("repo", header.cwd);
    try std.testing.expectEqualStrings("2026-05-26T00:00:00Z", header.timestamp);

    const leaf = (try host.session.manager.getLeafEntry()).?;
    try std.testing.expectEqual(@as(usize, 4), host.session.manager.entries.items.len);
    try std.testing.expectEqualStrings(first_leaf, host.session.manager.entries.items[2].parentId().?);
    try std.testing.expectEqualStrings(host.session.manager.entries.items[2].id(), leaf.parentId().?);

    const context = try host.session.manager.buildSessionContext(std.testing.allocator);
    defer host.session.manager.deinitSessionContext(std.testing.allocator, context);
    try std.testing.expectEqual(@as(usize, 4), context.messages.len);
    try std.testing.expectEqualStrings("first", context.messages[0].user.content.string);
    try std.testing.expectEqualStrings("second", context.messages[2].user.content.string);

    drainHostEvents(&host);
    const drained_leaf = (try host.session.manager.getLeafEntry()).?;
    try std.testing.expectEqualStrings(leaf.id(), drained_leaf.id());
    try std.testing.expectEqualStrings(host.session.manager.entries.items[2].id(), drained_leaf.parentId().?);
}

test "runtime host persists session store that loads after host deinit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var store = try session_store.SessionStore.create(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "repo",
        "session",
        "2026-05-26T00:00:00Z",
    );
    const store_file_name = try std.testing.allocator.dupe(u8, store.file_name);
    errdefer std.testing.allocator.free(store_file_name);

    {
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

        var host = try AgentSessionRuntimeHost.init(std.testing.allocator, std.testing.io, .{
            .cwd = "repo",
            .agent_dir = "agent",
            .current_date = "2026-05-26",
        .zio_runtime = zio_runtime,
            .dir = tmp.dir,
        }, .{
            .session_id = "session",
            .timestamp = "2026-05-26T00:00:00Z",
            .session_store = store,
        });
        store = undefined;
        defer {
            host.requestShutdown();
            drainHostEvents(&host);
            host.deinit();
        }

        try runPromptForTest(&host, "first");
        try runPromptForTest(&host, "second");
    }

    var loader: session_store.SessionStore = .{ .dir = tmp.dir, .file_name = store_file_name };
    defer loader.deinit(std.testing.allocator);
    var loaded = try loader.load(std.testing.allocator, std.testing.io);
    defer loaded.deinit();

    try std.testing.expectEqualStrings("session", loaded.header.id);
    try std.testing.expectEqualStrings("repo", loaded.header.cwd);
    try std.testing.expectEqual(@as(usize, 4), loaded.entries.items.len);
    try std.testing.expectEqualStrings(loaded.entries.items[1].id(), loaded.entries.items[2].parentId().?);
    try std.testing.expectEqualStrings(loaded.entries.items[2].id(), loaded.entries.items[3].parentId().?);

    const context = try loaded.buildSessionContext(std.testing.allocator);
    defer loaded.deinitSessionContext(std.testing.allocator, context);
    try std.testing.expectEqual(@as(usize, 4), context.messages.len);
    try std.testing.expectEqualStrings("first", context.messages[0].user.content.string);
    try std.testing.expectEqualStrings("second", context.messages[2].user.content.string);
}

test "runtime host resumes session store into agent context and appends new history" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var seed_store = try session_store.SessionStore.create(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "repo",
        "session",
        "2026-05-26T00:00:00Z",
    );
    const store_file_name = try std.testing.allocator.dupe(u8, seed_store.file_name);
    errdefer std.testing.allocator.free(store_file_name);

    {
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

        var host = try AgentSessionRuntimeHost.init(std.testing.allocator, std.testing.io, .{
            .cwd = "repo",
            .agent_dir = "agent",
            .current_date = "2026-05-26",
        .zio_runtime = zio_runtime,
            .dir = tmp.dir,
        }, .{
            .session_id = "session",
            .timestamp = "2026-05-26T00:00:00Z",
            .session_store = seed_store,
        });
        seed_store = undefined;
        defer {
            host.requestShutdown();
            drainHostEvents(&host);
            host.deinit();
        }

        try runPromptForTest(&host, "seed");
    }

    const resume_file_name = try std.testing.allocator.dupe(u8, store_file_name);
    errdefer std.testing.allocator.free(resume_file_name);
    var resume_store: session_store.SessionStore = .{ .dir = tmp.dir, .file_name = resume_file_name };
    {
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

        var host = try AgentSessionRuntimeHost.init(std.testing.allocator, std.testing.io, .{
            .cwd = "repo",
            .agent_dir = "agent",
            .current_date = "2026-05-26",
        .zio_runtime = zio_runtime,
            .dir = tmp.dir,
        }, .{
            .session_id = "ignored",
            .timestamp = "ignored",
            .resume_session_store = resume_store,
        });
        resume_store = undefined;
        defer {
            host.requestShutdown();
            drainHostEvents(&host);
            host.deinit();
        }

        try std.testing.expectEqualStrings("session", host.sessionHeader().id);
        try std.testing.expectEqual(@as(usize, 2), host.session.agent.state.messages.len);
        try std.testing.expectEqualStrings("seed", host.session.agent.state.messages[0].user.content.string);
        try runPromptForTest(&host, "after resume");
    }

    var loader: session_store.SessionStore = .{ .dir = tmp.dir, .file_name = store_file_name };
    defer loader.deinit(std.testing.allocator);
    var loaded = try loader.load(std.testing.allocator, std.testing.io);
    defer loaded.deinit();
    const context = try loaded.buildSessionContext(std.testing.allocator);
    defer loaded.deinitSessionContext(std.testing.allocator, context);

    try std.testing.expectEqual(@as(usize, 4), context.messages.len);
    try std.testing.expectEqualStrings("seed", context.messages[0].user.content.string);
    try std.testing.expectEqualStrings("after resume", context.messages[2].user.content.string);
}

test "runtime host live run executes a tool and continues the assistant turn" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var provider = try faux.Provider.init(std.testing.allocator, .{
        .min_token_size = 128,
        .max_token_size = 128,
    });
    defer provider.deinit();

    const tool_call_content = [_]ai.AssistantContent{
        faux.toolCall("tool-1", "echo", .{ .object = .empty }),
    };
    const final_content = [_]ai.AssistantContent{
        faux.text("done after tool"),
    };
    const responses = [_]ai.AssistantMessage{
        faux.assistantMessage(&tool_call_content, .{ .stop_reason = .tool_use }),
        faux.assistantMessage(&final_content, .{ .stop_reason = .stop }),
    };
    try provider.setResponses(&responses);
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var host = try AgentSessionRuntimeHost.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-26",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
        .model = provider.getModel(),
        .stream = provider.apiProvider().stream,
    }, .{
        .session_id = "session",
        .timestamp = "2026-05-26T00:00:00Z",
    });
    defer {
        host.requestShutdown();
        drainHostEvents(&host);
        host.deinit();
    }

    var echo: EchoTool = .{};
    try host.session.tools.append(
        std.testing.allocator,
        tool_registry.ToolDefinition.init(&echo, .{
            .name = "echo",
            .label = "echo",
            .description = "Echo test tool",
        }),
    );
    try host.session.setActiveToolsByName(&.{"echo"});

    const run = try host.startPromptRun("use the tool", &.{}, .{});
    defer host.destroyPromptRun(run);
    while (try host.stepPromptRun(run)) {}

    var observed: ToolLoopObservation = .{};
    _ = try host.drainPublicEvents(.{ .context = &observed, .call_fn = ToolLoopObservation.onEvent });

    try std.testing.expectEqual(@as(usize, 2), provider.call_count);
    try std.testing.expectEqual(@as(usize, 1), echo.call_count);
    try std.testing.expect(observed.user_message_end);
    try std.testing.expect(observed.tool_execution_start);
    try std.testing.expect(observed.tool_execution_end);
    try std.testing.expect(observed.final_text_delta);
    try std.testing.expect(observed.agent_end_with_tool_result);
    try std.testing.expect(observed.agent_end);
    try std.testing.expectEqual(AgentSession.AgentSessionStatus.idle, host.statusSnapshot().status);
}

test "runtime host applies prompt progress from zio stream future" {
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    const io = zio_runtime.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var provider = try faux.Provider.init(std.testing.allocator, .{
        .min_token_size = 128,
        .max_token_size = 128,
    });
    defer provider.deinit();

    const content = [_]ai.AssistantContent{faux.text("future progress")};
    const responses = [_]ai.AssistantMessage{
        faux.assistantMessage(&content, .{ .stop_reason = .stop }),
    };
    try provider.setResponses(&responses);

    var host = try AgentSessionRuntimeHost.init(std.testing.allocator, io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-26",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
        .model = provider.getModel(),
        .stream = provider.apiProvider().stream,
    }, .{
        .session_id = "session",
        .timestamp = "2026-05-26T00:00:00Z",
    });
    defer {
        host.requestShutdown();
        drainHostEvents(&host);
        host.deinit();
    }

    const run = try host.startPromptRun("hello", &.{}, .{});
    defer host.destroyPromptRun(run);

    var progress = host.promptRunProgress(run);
    const selected = try zio.select(.{ .prompt = &progress });
    const more = try host.applyPromptRunProgress(run, selected.prompt);
    try std.testing.expect(more);

    while (try host.stepPromptRun(run)) {}

    try std.testing.expectEqual(@as(usize, 1), provider.call_count);
    try std.testing.expect(host.statusSnapshot().public_event_count > 0);
}

test "runtime host compacts through public command boundary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var host = try AgentSessionRuntimeHost.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-26",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
        .compaction_settings = .{ .keep_recent_tokens = 2 },
    }, .{
        .session_id = "session",
        .timestamp = "2026-05-26T00:00:00Z",
    });
    defer {
        host.requestShutdown();
        drainHostEvents(&host);
        host.deinit();
    }

    _ = try host.session.manager.appendMessage(.{ .user = .{
        .content = .{ .string = "aaaaaaaa" },
        .timestamp = 0,
    } }, "t1");
    _ = try host.session.manager.appendMessage(.{ .user = .{
        .content = .{ .string = "bbbbbbbb" },
        .timestamp = 0,
    } }, "t2");
    const kept = try host.session.manager.appendMessage(.{ .user = .{
        .content = .{ .string = "cccccccc" },
        .timestamp = 0,
    } }, "t3");

    var result = try host.compactWithPreparedSummary("summary");
    defer result.deinit();

    try std.testing.expectEqualStrings(kept, result.first_kept_entry_id.text);
    try std.testing.expectEqual(@as(usize, 4), host.session.manager.entries.items.len);
    try std.testing.expectEqual(@as(usize, 2), host.session.agent.state.messages.len);
    try std.testing.expectEqual(AgentSession.AgentSessionStatus.idle, host.statusSnapshot().status);

    var start_event = host.drainPublicEvent().?;
    defer start_event.deinit();
    try std.testing.expect(start_event == .compaction_start);
    var end_event = host.drainPublicEvent().?;
    defer end_event.deinit();
    try std.testing.expect(end_event == .compaction_end);
    try std.testing.expectEqualStrings(kept, end_event.compaction_end.result.?.first_kept_entry_id.text);
}

test "runtime host compacts with generated summary through public command boundary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var provider = try faux.Provider.init(std.testing.allocator, .{});
    defer provider.deinit();
    const summary_content = [_]ai.AssistantContent{faux.text("generated summary")};
    const summaries = [_]ai.AssistantMessage{
        faux.assistantMessage(&summary_content, .{ .stop_reason = .stop }),
    };
    try provider.setResponses(&summaries);
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var host = try AgentSessionRuntimeHost.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-26",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
        .model = provider.getModel(),
        .stream = provider.apiProvider().stream,
        .compaction_settings = .{ .keep_recent_tokens = 2 },
    }, .{
        .session_id = "session",
        .timestamp = "2026-05-26T00:00:00Z",
    });
    defer {
        host.requestShutdown();
        drainHostEvents(&host);
        host.deinit();
    }

    _ = try host.session.manager.appendMessage(.{ .user = .{
        .content = .{ .string = "aaaaaaaa" },
        .timestamp = 0,
    } }, "t1");
    const kept = try host.session.manager.appendMessage(.{ .user = .{
        .content = .{ .string = "bbbbbbbb" },
        .timestamp = 0,
    } }, "t2");

    var result = try host.compactWithGeneratedSummary();
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), provider.call_count);
    try std.testing.expectEqualStrings("generated summary", result.summary.text);
    try std.testing.expectEqualStrings(kept, result.first_kept_entry_id.text);
    try std.testing.expectEqual(@as(usize, 3), host.session.manager.entries.items.len);

    var start_event = host.drainPublicEvent().?;
    defer start_event.deinit();
    try std.testing.expect(start_event == .compaction_start);
    var end_event = host.drainPublicEvent().?;
    defer end_event.deinit();
    try std.testing.expect(end_event == .compaction_end);
    try std.testing.expectEqualStrings("generated summary", end_event.compaction_end.result.?.summary.text);
}

test "runtime host exposes compaction preparation snapshot" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var host = try AgentSessionRuntimeHost.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-26",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
        .compaction_settings = .{ .keep_recent_tokens = 2 },
    }, .{
        .session_id = "session",
        .timestamp = "2026-05-26T00:00:00Z",
    });
    defer {
        host.requestShutdown();
        drainHostEvents(&host);
        host.deinit();
    }

    _ = try host.session.manager.appendMessage(.{ .user = .{
        .content = .{ .string = "aaaaaaaa" },
        .timestamp = 0,
    } }, "t1");
    const kept = try host.session.manager.appendMessage(.{ .user = .{
        .content = .{ .string = "bbbbbbbb" },
        .timestamp = 0,
    } }, "t2");

    var snapshot = try host.prepareCompactionSnapshot();
    defer snapshot.deinit();

    try std.testing.expectEqualStrings(kept, snapshot.first_kept_entry_id.text);
    try std.testing.expectEqual(@as(u64, 4), snapshot.tokens_before);
}

test "runtime host exposes compaction summary input snapshot" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var host = try AgentSessionRuntimeHost.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-26",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
        .compaction_settings = .{ .keep_recent_tokens = 2 },
    }, .{
        .session_id = "session",
        .timestamp = "2026-05-26T00:00:00Z",
    });
    defer {
        host.requestShutdown();
        drainHostEvents(&host);
        host.deinit();
    }

    _ = try host.session.manager.appendMessage(.{ .user = .{
        .content = .{ .string = "aaaaaaaa" },
        .timestamp = 0,
    } }, "t1");
    const kept = try host.session.manager.appendMessage(.{ .user = .{
        .content = .{ .string = "bbbbbbbb" },
        .timestamp = 0,
    } }, "t2");

    var snapshot = try host.prepareCompactionSummaryInputSnapshot();
    defer snapshot.deinit();

    try std.testing.expectEqualStrings(kept, snapshot.first_kept_entry_id.text);
    try std.testing.expectEqual(@as(usize, 1), snapshot.message_count);
    try std.testing.expect(std.mem.indexOf(u8, snapshot.serialized_input.text, "[User]: aaaaaaaa") != null);
}

test "runtime host preserves bash output limit details through public events" {
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    const io = zio_runtime.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try tmp.dir.realPathFile(std.testing.io, "repo", &cwd_buffer);

    var provider = try faux.Provider.init(std.testing.allocator, .{
        .min_token_size = 128,
        .max_token_size = 128,
    });
    defer provider.deinit();

    var args: std.json.ObjectMap = .empty;
    defer args.deinit(std.testing.allocator);
    try args.put(std.testing.allocator, "command", .{ .string = "printf '%070000d' 0" });

    const tool_call_content = [_]ai.AssistantContent{
        faux.toolCall("tool-1", "bash", .{ .object = args }),
    };
    const final_content = [_]ai.AssistantContent{
        faux.text("done after bash"),
    };
    const responses = [_]ai.AssistantMessage{
        faux.assistantMessage(&tool_call_content, .{ .stop_reason = .tool_use }),
        faux.assistantMessage(&final_content, .{ .stop_reason = .stop }),
    };
    try provider.setResponses(&responses);

    var host = try AgentSessionRuntimeHost.init(std.testing.allocator, io, .{
        .cwd = cwd_buffer[0..cwd_len],
        .agent_dir = "agent",
        .current_date = "2026-05-26",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
        .model = provider.getModel(),
        .stream = provider.apiProvider().stream,
    }, .{
        .session_id = "session",
        .timestamp = "2026-05-26T00:00:00Z",
    });
    defer {
        host.requestShutdown();
        drainHostEvents(&host);
        host.deinit();
    }

    const run = try host.startPromptRun("use bash", &.{}, .{});
    defer host.destroyPromptRun(run);
    while (try host.stepPromptRun(run)) {}

    var observed: BashLimitObservation = .{};
    _ = try host.drainPublicEvents(.{ .context = &observed, .call_fn = BashLimitObservation.onEvent });

    try std.testing.expectEqual(@as(usize, 2), provider.call_count);
    try std.testing.expect(observed.tool_execution_end);
    try std.testing.expect(observed.output_limit_exceeded);
    try std.testing.expect(observed.tool_result_message);
    try std.testing.expectEqual(AgentSession.AgentSessionStatus.idle, host.statusSnapshot().status);
}

test "runtime host cancellation reaches running bash tool through agent loop" {
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    const io = zio_runtime.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try tmp.dir.realPathFile(std.testing.io, "repo", &cwd_buffer);

    var provider = try faux.Provider.init(std.testing.allocator, .{
        .min_token_size = 128,
        .max_token_size = 128,
    });
    defer provider.deinit();

    var args: std.json.ObjectMap = .empty;
    defer args.deinit(std.testing.allocator);
    try args.put(std.testing.allocator, "command", .{ .string = "sleep 60" });

    const tool_call_content = [_]ai.AssistantContent{
        faux.toolCall("tool-1", "bash", .{ .object = args }),
    };
    const responses = [_]ai.AssistantMessage{
        faux.assistantMessage(&tool_call_content, .{ .stop_reason = .tool_use }),
    };
    try provider.setResponses(&responses);

    var host = try AgentSessionRuntimeHost.init(std.testing.allocator, io, .{
        .cwd = cwd_buffer[0..cwd_len],
        .agent_dir = "agent",
        .current_date = "2026-05-26",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
        .model = provider.getModel(),
        .stream = provider.apiProvider().stream,
    }, .{
        .session_id = "session",
        .timestamp = "2026-05-26T00:00:00Z",
    });
    defer {
        host.requestShutdown();
        drainHostEvents(&host);
        host.deinit();
    }

    var future = try zio_runtime.spawn(runPromptForTest, .{ &host, "use bash" });
    defer future.cancel();
    var observed: BashLimitObservation = .{};
    try waitForBashToolStart(&host, &observed);
    try std.testing.expectEqual(AgentSession.AgentSessionStatus.running, host.statusSnapshot().status);
    host.cancel();

    try future.join();
    _ = try host.drainPublicEvents(.{ .context = &observed, .call_fn = BashLimitObservation.onEvent });

    try std.testing.expect(observed.tool_execution_start);
    try std.testing.expect(observed.tool_execution_end);
    try std.testing.expect(observed.tool_error);
    try std.testing.expectEqual(AgentSession.AgentSessionStatus.idle, host.statusSnapshot().status);
}
