const std = @import("std");
const agent_mod = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const faux = @import("../ai/providers/faux.zig");
const AgentSession = @import("AgentSession.zig");
const AgentSessionRuntimeHost = @import("AgentSessionRuntimeHost.zig");
const paths_mod = @import("paths.zig");
const RuntimeServices = @import("runtime_services.zig").RuntimeServices;
const session_config = @import("session_config.zig");
const session_store = @import("session_store.zig");

pub const CreateRuntimeHostOptions = struct {
    cwd: []const u8 = ".",
    agent_dir_override: ?[]const u8 = null,
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

pub const ResumeRuntimeHostOptions = struct {
    cwd: []const u8 = ".",
    agent_dir_override: ?[]const u8 = null,
    current_date: []const u8,
    session_file_name: []const u8,
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
        drainHostEvents(&self.host);
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
    const resolved_agent_dir = if (options.agent_dir_override) |agent_dir_override|
        agent_dir_override
    else
        try paths_mod.resolveGlobalAgentDirFromEnv(allocator, options.environ);
    defer if (options.agent_dir_override == null) allocator.free(resolved_agent_dir);

    var services = try RuntimeServices.init(allocator, io, .{
        .cwd = options.cwd,
        .agent_dir = resolved_agent_dir,
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

    const sessions_dir = try services.paths().sessionsDirForCwd(allocator);
    defer allocator.free(sessions_dir);
    var store = try session_store.SessionStore.createInPath(
        allocator,
        io,
        options.dir,
        sessions_dir,
        services.cwd,
        options.session_id,
        options.timestamp,
    );
    errdefer store.deinit(allocator);

    const host = try AgentSessionRuntimeHost.init(allocator, io, base, .{
        .session_id = options.session_id,
        .timestamp = options.timestamp,
        .session_store = store,
    });
    errdefer {
        var host_copy = host;
        host_copy.requestShutdown();
        drainHostEvents(&host_copy);
        host_copy.deinit();
    }

    return .{ .services = services, .host = host };
}

pub fn resumeRuntimeHost(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: ResumeRuntimeHostOptions,
) !Runtime {
    if (!std.mem.eql(u8, std.fs.path.basename(options.session_file_name), options.session_file_name)) {
        return error.InvalidSessionFileName;
    }

    const resolved_agent_dir = if (options.agent_dir_override) |agent_dir_override|
        agent_dir_override
    else
        try paths_mod.resolveGlobalAgentDirFromEnv(allocator, options.environ);
    defer if (options.agent_dir_override == null) allocator.free(resolved_agent_dir);

    var services = try RuntimeServices.init(allocator, io, .{
        .cwd = options.cwd,
        .agent_dir = resolved_agent_dir,
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

    const sessions_dir = try services.paths().sessionsDirForCwd(allocator);
    defer allocator.free(sessions_dir);
    const file_name = try std.fs.path.join(allocator, &.{ sessions_dir, options.session_file_name });
    errdefer allocator.free(file_name);
    const store: session_store.SessionStore = .{ .dir = options.dir, .file_name = file_name };

    const host = try AgentSessionRuntimeHost.init(allocator, io, base, .{
        .session_id = "resume",
        .timestamp = "resume",
        .resume_session_store = store,
    });
    errdefer {
        var host_copy = host;
        host_copy.requestShutdown();
        drainHostEvents(&host_copy);
        host_copy.deinit();
    }

    return .{ .services = services, .host = host };
}

fn drainHostEvents(host: *AgentSessionRuntimeHost) void {
    _ = host.drainPublicEvents(.{ .call_fn = ignorePublicEvent }) catch unreachable;
}

fn ignorePublicEvent(_: ?*anyopaque, _: AgentSession.AgentSessionEvent) !void {}

fn runPromptForTest(host: *AgentSessionRuntimeHost, text: []const u8) !void {
    const run = try host.startPromptRun(text, &.{}, .{});
    defer host.destroyPromptRun(run);
    while (try host.stepPromptRun(run)) {}
}

test "sdk runtime owns services before host and deinitializes in order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var runtime = try createRuntimeHost(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .current_date = "2026-05-27",
        .session_id = "session",
        .timestamp = "2026-05-27T00:00:00Z",
        .dir = tmp.dir,
    });
    defer runtime.deinit();

    try std.testing.expectEqualStrings("repo", runtime.services.cwd);
    try std.testing.expectEqualStrings(runtime.services.cwd, runtime.host.base.cwd);
    try std.testing.expectEqualStrings("session", runtime.host.sessionId());
}

test "sdk runtime creates session store under service session path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var provider = try faux.Provider.init(std.testing.allocator, .{
        .min_token_size = 128,
        .max_token_size = 128,
    });
    defer provider.deinit();
    try provider.setResponses(&.{faux.assistantMessage(&.{faux.text("stored")}, .{})});

    var runtime = try createRuntimeHost(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .current_date = "2026-05-27",
        .session_id = "session",
        .timestamp = "2026-05-27T00:00:00Z",
        .model = provider.getModel(),
        .stream = provider.apiProvider().stream,
        .dir = tmp.dir,
    });

    const sessions_dir = try runtime.services.paths().sessionsDirForCwd(std.testing.allocator);
    defer std.testing.allocator.free(sessions_dir);
    const store_file_name = try std.fs.path.join(
        std.testing.allocator,
        &.{ sessions_dir, "2026-05-27T00:00:00Z_session.jsonl" },
    );
    errdefer std.testing.allocator.free(store_file_name);

    try runPromptForTest(&runtime.host, "persist me");
    runtime.deinit();

    var loader: session_store.SessionStore = .{ .dir = tmp.dir, .file_name = store_file_name };
    defer loader.deinit(std.testing.allocator);
    var loaded = try loader.load(std.testing.allocator, std.testing.io);
    defer loaded.deinit();
    const context = try loaded.buildSessionContext(std.testing.allocator);
    defer loaded.deinitSessionContext(std.testing.allocator, context);

    try std.testing.expectEqualStrings("session", loaded.header.id);
    try std.testing.expectEqual(@as(usize, 2), context.messages.len);
    try std.testing.expectEqualStrings("persist me", context.messages[0].user.content.string);
    try std.testing.expectEqualStrings("stored", context.messages[1].assistant.content[0].text.text);
}

test "sdk runtime resumes existing session store from service session path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var provider = try faux.Provider.init(std.testing.allocator, .{
        .min_token_size = 128,
        .max_token_size = 128,
    });
    defer provider.deinit();
    try provider.setResponses(&.{faux.assistantMessage(&.{faux.text("first response")}, .{})});

    const session_file_name = "2026-05-27T00:00:00Z_session.jsonl";
    {
        var runtime = try createRuntimeHost(std.testing.allocator, std.testing.io, .{
            .cwd = "repo",
            .agent_dir_override = "agent",
            .current_date = "2026-05-27",
            .session_id = "session",
            .timestamp = "2026-05-27T00:00:00Z",
            .model = provider.getModel(),
            .stream = provider.apiProvider().stream,
            .dir = tmp.dir,
        });
        defer runtime.deinit();

        try runPromptForTest(&runtime.host, "first prompt");
    }

    try provider.setResponses(&.{faux.assistantMessage(&.{faux.text("second response")}, .{})});
    var resumed = try resumeRuntimeHost(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .current_date = "2026-05-27",
        .session_file_name = session_file_name,
        .model = provider.getModel(),
        .stream = provider.apiProvider().stream,
        .dir = tmp.dir,
    });

    const sessions_dir = try resumed.services.paths().sessionsDirForCwd(std.testing.allocator);
    defer std.testing.allocator.free(sessions_dir);
    const store_file_name = try std.fs.path.join(std.testing.allocator, &.{ sessions_dir, session_file_name });
    errdefer std.testing.allocator.free(store_file_name);

    try std.testing.expectEqualStrings("session", resumed.host.sessionHeader().id);
    try std.testing.expectEqual(@as(usize, 2), resumed.host.session.agent.state.messages.len);
    try std.testing.expectEqualStrings(
        "first prompt",
        resumed.host.session.agent.state.messages[0].user.content.string,
    );
    try runPromptForTest(&resumed.host, "second prompt");
    resumed.deinit();

    var loader: session_store.SessionStore = .{ .dir = tmp.dir, .file_name = store_file_name };
    defer loader.deinit(std.testing.allocator);
    var loaded = try loader.load(std.testing.allocator, std.testing.io);
    defer loaded.deinit();
    const context = try loaded.buildSessionContext(std.testing.allocator);
    defer loaded.deinitSessionContext(std.testing.allocator, context);

    try std.testing.expectEqual(@as(usize, 4), context.messages.len);
    try std.testing.expectEqualStrings("first prompt", context.messages[0].user.content.string);
    try std.testing.expectEqualStrings("second prompt", context.messages[2].user.content.string);
}
