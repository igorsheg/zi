const std = @import("std");
const agent_mod = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const AgentSession = @import("AgentSession.zig");
const AgentSessionRuntimeHost = @import("AgentSessionRuntimeHost.zig");
const paths_mod = @import("paths.zig");
const RuntimeServices = @import("runtime_services.zig").RuntimeServices;
const session_config = @import("session_config.zig");

pub const CreateRuntimeHostOptions = struct {
    cwd: []const u8 = ".",
    agent_dir: []const u8 = paths_mod.global_config_dir_name,
    current_date: []const u8,
    session_id: []const u8,
    timestamp: []const u8,
    model: ?ai.Model = null,
    thinking_level: ?agent_mod.ThinkingLevel = null,
    stream: ?ai.StreamFunction = null,
    dir: std.Io.Dir = .cwd(),
    environ: ?*const std.process.Environ.Map = null,
    allow_paths_outside_cwd: bool = false,
    public_event_capacity: usize = AgentSession.public_event_capacity_default,
};

pub const Runtime = struct {
    services: RuntimeServices,
    host: AgentSessionRuntimeHost,

    pub fn deinit(self: *Runtime) void {
        self.host.requestShutdown();
        while (self.host.drainPublicEvent() != null) {}
        self.host.deinit();
        self.services.deinit();
        self.* = undefined;
    }
};

pub fn createRuntimeHost(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: CreateRuntimeHostOptions,
) !Runtime {
    var services = try RuntimeServices.init(allocator, io, .{
        .cwd = options.cwd,
        .agent_dir = options.agent_dir,
        .dir = options.dir,
        .environ = options.environ,
    });
    errdefer services.deinit();

    const base = session_config.resolve(&services, .{
        .current_date = options.current_date,
        .model = options.model,
        .thinking_level = options.thinking_level,
        .stream = options.stream,
        .dir = options.dir,
        .allow_paths_outside_cwd = options.allow_paths_outside_cwd,
        .public_event_capacity = options.public_event_capacity,
    });

    const host = try AgentSessionRuntimeHost.init(allocator, io, base, .{
        .session_id = options.session_id,
        .timestamp = options.timestamp,
    });
    errdefer {
        var host_copy = host;
        host_copy.requestShutdown();
        while (host_copy.drainPublicEvent() != null) {}
        host_copy.deinit();
    }

    return .{ .services = services, .host = host };
}

test "sdk runtime owns services before host and deinitializes in order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var runtime = try createRuntimeHost(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-27",
        .session_id = "session",
        .timestamp = "2026-05-27T00:00:00Z",
        .dir = tmp.dir,
    });
    defer runtime.deinit();

    try std.testing.expectEqualStrings("repo", runtime.services.cwd);
    try std.testing.expectEqualStrings(runtime.services.cwd, runtime.host.base.cwd);
    try std.testing.expectEqualStrings("session", runtime.host.currentSession().manager.header.id);
}
