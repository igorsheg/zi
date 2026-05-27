const std = @import("std");
const ai = @import("../ai/root.zig");
const AgentSession = @import("AgentSession.zig");

const AgentSessionRuntimeHost = @This();

session: AgentSession,
rebind_session: ?RebindSession = null,
before_session_invalidate: ?BeforeSessionInvalidate = null,

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

pub fn init(allocator: std.mem.Allocator, io: std.Io, options: AgentSession.Options) !AgentSessionRuntimeHost {
    return .{ .session = try AgentSession.init(allocator, io, options) };
}

pub fn deinit(self: *AgentSessionRuntimeHost) void {
    self.session.deinit();
    self.* = undefined;
}

pub fn currentSession(self: *AgentSessionRuntimeHost) *AgentSession {
    return &self.session;
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

pub fn newSession(
    self: *AgentSessionRuntimeHost,
    allocator: std.mem.Allocator,
    io: std.Io,
    options: AgentSession.Options,
) !NewSessionResult {
    const result = try self.replaceSession(allocator, io, options);
    return .{ .old_event_count = result.old_event_count };
}

pub fn replaceSession(
    self: *AgentSessionRuntimeHost,
    allocator: std.mem.Allocator,
    io: std.Io,
    options: AgentSession.Options,
) !ReplaceResult {
    if (self.session.statusSnapshot().status != .idle) return error.SessionReplacementRequiresIdle;

    var next_session = try AgentSession.init(allocator, io, options);
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

pub fn prompt(
    self: *AgentSessionRuntimeHost,
    text: []const u8,
    images: []const ai.ImageContent,
) !void {
    try self.session.prompt(text, images);
}

pub fn promptWithOptions(
    self: *AgentSessionRuntimeHost,
    text: []const u8,
    images: []const ai.ImageContent,
    options: AgentSession.PromptOptions,
) !void {
    try self.session.promptWithOptions(text, images, options);
}

pub fn continueRun(self: *AgentSessionRuntimeHost) !void {
    try self.session.continueRun();
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

pub fn toolSnapshot(self: *const AgentSessionRuntimeHost) AgentSession.ToolSnapshot {
    return self.session.toolSnapshot();
}

pub fn queueSnapshot(self: *const AgentSessionRuntimeHost, allocator: std.mem.Allocator) !AgentSession.QueueSnapshot {
    return self.session.queueSnapshot(allocator);
}

pub fn publicEventCount(self: *const AgentSessionRuntimeHost) usize {
    return self.session.publicEventCount();
}

pub fn drainPublicEvent(self: *AgentSessionRuntimeHost) ?AgentSession.AgentSessionEvent {
    return self.session.drainPublicEvent();
}

pub fn shutdownComplete(self: *AgentSessionRuntimeHost) bool {
    return self.session.shutdownComplete();
}

fn shutdownAndDeinitSession(session: *AgentSession) void {
    session.requestShutdown();
    _ = drainSessionEvents(session);
    session.deinit();
}

fn drainSessionEvents(session: *AgentSession) usize {
    var count: usize = 0;
    while (session.drainPublicEvent() != null) count += 1;
    return count;
}

test "runtime host replacement invalidates old session before rebinding new session" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var host = try AgentSessionRuntimeHost.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-26",
        .session_id = "first",
        .timestamp = "2026-05-26T00:00:00Z",
        .dir = tmp.dir,
    });
    defer {
        host.requestShutdown();
        while (host.drainPublicEvent() != null) {}
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

    try host.prompt("old event", &.{});
    const result = try host.replaceSession(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-26",
        .session_id = "second",
        .timestamp = "2026-05-26T00:00:01Z",
        .dir = tmp.dir,
    });

    try std.testing.expect(result.old_event_count > 0);
    try std.testing.expectEqual(@as(usize, 1), state.before_count);
    try std.testing.expectEqual(@as(usize, 1), state.rebind_count);
    try std.testing.expectEqualStrings("second", state.rebound_session_id);
    try std.testing.expectEqualStrings("second", host.currentSession().manager.header.id);
    try std.testing.expectEqual(@as(usize, 0), host.publicEventCount());
}

test "runtime host new session replaces current session" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var host = try AgentSessionRuntimeHost.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-26",
        .session_id = "first",
        .timestamp = "2026-05-26T00:00:00Z",
        .dir = tmp.dir,
    });
    defer {
        host.requestShutdown();
        while (host.drainPublicEvent() != null) {}
        host.deinit();
    }

    const result = try host.newSession(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-26",
        .session_id = "second",
        .timestamp = "2026-05-26T00:00:01Z",
        .dir = tmp.dir,
    });

    try std.testing.expect(!result.cancelled);
    try std.testing.expectEqual(@as(usize, 0), result.old_event_count);
    try std.testing.expectEqualStrings("second", host.currentSession().manager.header.id);
}

test "runtime host replacement rejects active old session" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var host = try AgentSessionRuntimeHost.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-26",
        .session_id = "first",
        .timestamp = "2026-05-26T00:00:00Z",
        .dir = tmp.dir,
    });
    defer {
        if (!host.currentSession().agent.waitForIdle()) host.currentSession().agent.finishRun();
        host.requestShutdown();
        while (host.drainPublicEvent() != null) {}
        host.deinit();
    }

    _ = try host.currentSession().agent.beginRun();

    try std.testing.expectError(error.SessionReplacementRequiresIdle, host.replaceSession(
        std.testing.allocator,
        std.testing.io,
        .{
            .cwd = "repo",
            .agent_dir = "agent",
            .current_date = "2026-05-26",
            .session_id = "second",
            .timestamp = "2026-05-26T00:00:01Z",
            .dir = tmp.dir,
        },
    ));
    try std.testing.expectEqualStrings("first", host.currentSession().manager.header.id);
}

test "runtime host owns current agent session public boundary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var host = try AgentSessionRuntimeHost.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-26",
        .session_id = "session",
        .timestamp = "2026-05-26T00:00:00Z",
        .dir = tmp.dir,
    });
    defer {
        host.requestShutdown();
        while (host.drainPublicEvent() != null) {}
        host.deinit();
    }

    try host.prompt("hello", &.{});

    try std.testing.expect(host.publicEventCount() > 0);
    try std.testing.expectEqual(AgentSession.AgentSessionStatus.idle, host.statusSnapshot().status);
    try std.testing.expectEqual(@as(usize, 3), host.toolSnapshot().active_count);
}
