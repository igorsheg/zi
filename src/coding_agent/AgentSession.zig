const std = @import("std");
const agent_mod = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const runtime = @import("../runtime/root.zig");
const resources = @import("resources.zig");
const session_manager = @import("session_manager.zig");
const system_prompt = @import("system_prompt.zig");
const tool_registry = @import("tool_registry.zig");

const AgentSession = @This();

allocator: std.mem.Allocator,
io: std.Io,
cwd: []const u8,
current_date: []const u8,
timestamp: []const u8,
prompt_resources: resources.PromptResources,
system_prompt_state: SystemPromptState,
builtin_tools: tool_registry.OwnedBuiltinTools,
tools: tool_registry.ToolRegistry,
manager: *session_manager.SessionManager,
agent: *agent_mod.Agent,
event_drain: *EventDrain,

pub const Options = struct {
    cwd: []const u8,
    agent_dir: []const u8,
    current_date: []const u8,
    session_id: []const u8,
    timestamp: []const u8,
    model: ai.Model = agent_mod.Agent.defaultModel(),
    thinking_level: agent_mod.ThinkingLevel = .off,
    stream: ?ai.StreamFunction = null,
    dir: std.Io.Dir = .cwd(),
    allow_paths_outside_cwd: bool = false,
};

const SystemPromptState = struct {
    text: []const u8,

    fn init(
        allocator: std.mem.Allocator,
        cwd: []const u8,
        current_date: []const u8,
        prompt_resources: *const resources.PromptResources,
        tools: *const tool_registry.ToolRegistry,
    ) !SystemPromptState {
        return .{ .text = try buildText(allocator, cwd, current_date, prompt_resources, tools) };
    }

    fn deinit(self: *SystemPromptState, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }

    fn replaceText(self: *SystemPromptState, allocator: std.mem.Allocator, text: []const u8) void {
        allocator.free(self.text);
        self.text = text;
    }

    fn buildText(
        allocator: std.mem.Allocator,
        cwd: []const u8,
        current_date: []const u8,
        prompt_resources: *const resources.PromptResources,
        tools: *const tool_registry.ToolRegistry,
    ) ![]const u8 {
        var snippets = std.ArrayList(system_prompt.ToolSnippet).empty;
        defer snippets.deinit(allocator);
        var guidelines = std.ArrayList([]const u8).empty;
        defer guidelines.deinit(allocator);

        for (tools.activeToolNames()) |name| {
            const definition = tools.findDefinition(name) orelse return error.UnknownToolName;
            if (definition.metadata.prompt_snippet) |snippet| {
                try snippets.append(allocator, .{ .name = definition.metadata.name, .snippet = snippet });
            }
            for (definition.metadata.prompt_guidelines) |guideline| {
                try guidelines.append(allocator, guideline);
            }
        }

        return system_prompt.build(allocator, .{
            .cwd = cwd,
            .current_date = current_date,
            .selected_tools = tools.activeToolNames(),
            .tool_snippets = snippets.items,
            .prompt_guidelines = guidelines.items,
            .context_files = prompt_resources.context_files.files,
            .skills = prompt_resources.skills.skills,
            .custom_prompt = prompt_resources.customPrompt(),
            .append_system_prompt = prompt_resources.appendSystemPrompt(),
        });
    }
};

const EventDrain = struct {
    manager: *session_manager.SessionManager,
    timestamp: []const u8,

    pub fn handle(self: *EventDrain, event: agent_mod.AgentEvent) !void {
        try self.updateQueueMirror(event);
        try self.runSessionHooks(event);
        try self.emitPublicEvent(event);
        try self.persistEvent(event);
        try self.handleTerminalPolicy(event);
    }

    fn updateQueueMirror(_: *EventDrain, _: agent_mod.AgentEvent) !void {}

    fn runSessionHooks(_: *EventDrain, _: agent_mod.AgentEvent) !void {}

    fn emitPublicEvent(_: *EventDrain, _: agent_mod.AgentEvent) !void {}

    fn persistEvent(self: *EventDrain, event: agent_mod.AgentEvent) !void {
        if (event != .message_end) return;
        _ = try self.manager.appendMessage(event.message_end.message, self.timestamp);
    }

    fn handleTerminalPolicy(_: *EventDrain, _: agent_mod.AgentEvent) !void {}
};

pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) !AgentSession {
    const cwd = try allocator.dupe(u8, options.cwd);
    errdefer allocator.free(cwd);
    const current_date = try allocator.dupe(u8, options.current_date);
    errdefer allocator.free(current_date);
    const timestamp = try allocator.dupe(u8, options.timestamp);
    errdefer allocator.free(timestamp);

    var prompt_resources = try resources.PromptResources.load(allocator, io, .{
        .dir = options.dir,
        .agent_dir = options.agent_dir,
        .cwd = options.cwd,
    });
    errdefer prompt_resources.deinit();

    var builtin_tools = try tool_registry.OwnedBuiltinTools.init(allocator, .{
        .cwd = options.cwd,
        .allow_paths_outside_cwd = options.allow_paths_outside_cwd,
    });
    errdefer builtin_tools.deinit();

    var tools: tool_registry.ToolRegistry = .{};
    errdefer tools.deinit(allocator);
    try builtin_tools.appendDefinitions(&tools);
    try tools.setActiveToolsByName(allocator, &.{ "read", "edit", "write" });

    var system_prompt_state = try SystemPromptState.init(
        allocator,
        options.cwd,
        options.current_date,
        &prompt_resources,
        &tools,
    );
    errdefer system_prompt_state.deinit(allocator);

    const manager = try allocator.create(session_manager.SessionManager);
    errdefer allocator.destroy(manager);
    manager.* = try session_manager.SessionManager.init(
        allocator,
        options.cwd,
        options.session_id,
        options.timestamp,
    );
    errdefer manager.deinit();

    var agent_options: agent_mod.Agent.Options = .{
        .system_prompt = system_prompt_state.text,
        .model = options.model,
        .thinking_level = options.thinking_level,
        .tools = tools.activeAgentTools(),
    };
    if (options.stream) |stream| agent_options.stream = stream;

    const core_agent = try allocator.create(agent_mod.Agent);
    errdefer allocator.destroy(core_agent);
    core_agent.* = try agent_mod.Agent.init(allocator, io, agent_options);
    errdefer core_agent.deinit();

    const event_drain = try allocator.create(EventDrain);
    errdefer allocator.destroy(event_drain);
    event_drain.* = .{ .manager = manager, .timestamp = timestamp };

    _ = try core_agent.subscribe(.{ .context = event_drain, .call_fn = drainAgentEvent });

    return .{
        .allocator = allocator,
        .io = io,
        .cwd = cwd,
        .current_date = current_date,
        .timestamp = timestamp,
        .prompt_resources = prompt_resources,
        .system_prompt_state = system_prompt_state,
        .builtin_tools = builtin_tools,
        .tools = tools,
        .manager = manager,
        .agent = core_agent,
        .event_drain = event_drain,
    };
}

pub fn deinit(self: *AgentSession) void {
    self.agent.deinit();
    self.allocator.destroy(self.agent);
    self.allocator.destroy(self.event_drain);
    self.manager.deinit();
    self.allocator.destroy(self.manager);
    self.tools.deinit(self.allocator);
    self.builtin_tools.deinit();
    self.system_prompt_state.deinit(self.allocator);
    self.prompt_resources.deinit();
    self.allocator.free(self.timestamp);
    self.allocator.free(self.current_date);
    self.allocator.free(self.cwd);
    self.* = undefined;
}

pub fn prompt(self: *AgentSession, text: []const u8, images: []const ai.ImageContent) !void {
    const expanded = try self.expandPromptText(text);
    defer self.allocator.free(expanded);
    try self.sendPrompt(expanded, images);
}

pub fn continueRun(self: *AgentSession) !void {
    try self.agent.continueRun();
}

pub fn setActiveToolsByName(self: *AgentSession, names: []const []const u8) !void {
    if (!self.agent.waitForIdle()) return error.SessionBusy;
    var active_set = try self.tools.buildActiveToolSet(self.allocator, names);
    defer active_set.deinit(self.allocator);
    const next_prompt = try self.buildPromptForActiveNames(active_set.names);
    errdefer self.allocator.free(next_prompt);

    try self.tools.ensureActiveCapacity(self.allocator, active_set.names.len);
    try self.agent.setTools(active_set.agent_tools);
    self.tools.commitActiveToolSet(active_set);
    self.agent.setSystemPrompt(next_prompt);
    self.system_prompt_state.replaceText(self.allocator, next_prompt);
}

pub fn state(self: *const AgentSession) agent_mod.AgentState {
    return self.agent.state;
}

pub fn activeToolNames(self: *const AgentSession) []const []const u8 {
    return self.tools.activeToolNames();
}

fn buildPromptForActiveNames(self: *AgentSession, active_names: []const []const u8) ![]const u8 {
    var snippets = std.ArrayList(system_prompt.ToolSnippet).empty;
    defer snippets.deinit(self.allocator);
    var guidelines = std.ArrayList([]const u8).empty;
    defer guidelines.deinit(self.allocator);

    for (active_names) |name| {
        const definition = self.tools.findDefinition(name) orelse return error.UnknownToolName;
        if (definition.metadata.prompt_snippet) |snippet| {
            try snippets.append(self.allocator, .{ .name = definition.metadata.name, .snippet = snippet });
        }
        for (definition.metadata.prompt_guidelines) |guideline| {
            try guidelines.append(self.allocator, guideline);
        }
    }

    return system_prompt.build(self.allocator, .{
        .cwd = self.cwd,
        .current_date = self.current_date,
        .selected_tools = active_names,
        .tool_snippets = snippets.items,
        .prompt_guidelines = guidelines.items,
        .context_files = self.prompt_resources.context_files.files,
        .skills = self.prompt_resources.skills.skills,
        .custom_prompt = self.prompt_resources.customPrompt(),
        .append_system_prompt = self.prompt_resources.appendSystemPrompt(),
    });
}

fn expandPromptText(self: *AgentSession, text: []const u8) ![]const u8 {
    return self.allocator.dupe(u8, text);
}

fn sendPrompt(self: *AgentSession, text: []const u8, images: []const ai.ImageContent) !void {
    try self.agent.promptText(text, images);
}

fn drainAgentEvent(
    _: std.Io,
    context: ?*anyopaque,
    event: agent_mod.AgentEvent,
    _: runtime.CancelToken,
) anyerror!void {
    const drain: *EventDrain = @ptrCast(@alignCast(context.?));
    try drain.handle(event);
}

test "agent session initializes policy spine with definition-first builtin tools" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "agent/AGENTS.md", .data = "global" });

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .dir = tmp.dir,
    });
    defer session.deinit();

    try std.testing.expectEqual(@as(usize, tool_registry.builtin_tool_count), session.tools.definitions.items.len);
    try std.testing.expectEqual(@as(usize, tool_registry.builtin_tool_count), session.agent.state.tools.len);
    try std.testing.expectEqualStrings("read", session.activeToolNames()[0]);
    try std.testing.expect(std.mem.indexOf(u8, session.system_prompt_state.text, "global") != null);
}

test "agent session persists message_end through session event drain" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .dir = tmp.dir,
    });
    defer session.deinit();

    _ = try session.agent.beginRun();
    try session.agent.emitEvent(.{ .message_end = .{ .message = .{ .user = .{
        .content = .{ .string = "hello" },
        .timestamp = 0,
    } } } });
    session.agent.finishRun();

    try std.testing.expectEqual(@as(usize, 1), session.manager.entries.items.len);
}

test "agent session active tool changes rebuild prompt and agent tools" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .dir = tmp.dir,
    });
    defer session.deinit();

    try session.setActiveToolsByName(&.{"read"});

    try std.testing.expectEqual(@as(usize, 1), session.agent.state.tools.len);
    try std.testing.expectEqualStrings("read", session.agent.state.tools[0].name);
    try std.testing.expect(std.mem.indexOf(u8, session.system_prompt_state.text, "- read:") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.system_prompt_state.text, "- edit:") == null);
}

test "agent session active tool change validates before mutation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .dir = tmp.dir,
    });
    defer session.deinit();

    try session.setActiveToolsByName(&.{"read"});
    try std.testing.expectError(error.UnknownToolName, session.setActiveToolsByName(&.{ "edit", "missing" }));

    try std.testing.expectEqual(@as(usize, 1), session.agent.state.tools.len);
    try std.testing.expectEqualStrings("read", session.agent.state.tools[0].name);
    try std.testing.expectEqual(@as(usize, 1), session.activeToolNames().len);
    try std.testing.expectEqualStrings("read", session.activeToolNames()[0]);
}

test "agent session rejects active tool changes while running" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var session = try AgentSession.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-25",
        .session_id = "session",
        .timestamp = "2026-05-25T00:00:00Z",
        .dir = tmp.dir,
    });
    defer session.deinit();

    _ = try session.agent.beginRun();
    defer session.agent.finishRun();

    try std.testing.expectError(error.SessionBusy, session.setActiveToolsByName(&.{"read"}));
}
