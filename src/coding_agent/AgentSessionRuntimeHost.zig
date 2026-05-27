const std = @import("std");
const ai = @import("../ai/root.zig");
const AgentSession = @import("AgentSession.zig");

const AgentSessionRuntimeHost = @This();

session: AgentSession,

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
