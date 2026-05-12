const std = @import("std");
const ai = @import("../ai/root.zig");
const agent_mod = @import("../agent/root.zig");
const storage = @import("../storage.zig");
const agent_session_mod = @import("agent_session.zig");
const session_bootstrap = @import("session_bootstrap.zig");
const model_registry_mod = @import("model_registry.zig");
const resources = @import("resources/root.zig");
const tool_def = @import("tools/definition.zig");
const auth_storage_mod = @import("auth/storage.zig");
const settings_manager_mod = @import("settings/manager.zig");
const extension_runner_mod = @import("extensions/runner.zig");

pub const AgentSession = agent_session_mod.AgentSession;
pub const SessionStore = agent_session_mod.SessionStore;
pub const PreparedSessionDeps = session_bootstrap.PreparedDeps;

pub const CreateOptions = struct {
    model: ai.protocol.Model,

    api_key: []const u8 = "",
    cwd: []const u8,
    io: std.Io = std.Options.debug_io,

    system_prompt: ?[]const u8 = null,

    context_files: []const resources.types.AgentsFile = &.{},

    extension_paths: []const []const u8 = &.{},
    agent_dir_override: ?[]const u8 = null,
    max_tokens: ?u64 = 4096,
    tools: ?[]const tool_def.ToolDefinition = null,
    registry: ?*ai.provider.Registry = null,
    event_handler: ?AgentSession.EventHandler = null,
    auth_storage: ?*auth_storage_mod.AuthStorage = null,
    settings_manager: ?*settings_manager_mod.SettingsManager = null,
    model_registry: ?*model_registry_mod.ModelRegistry = null,
    initial_messages: []const agent_mod.protocol.AgentMessage = &.{},
    thinking_level: ?agent_mod.protocol.ThinkingLevel = null,
    session_store: ?SessionStore = null,
    no_session: bool = false,

    append_system_prompt: ?[]const u8 = null,
    tool_allowlist: ?[]const []const u8 = null,
    extension_generation: extension_runner_mod.Generation = 0,
};

pub fn resolveSessionDir(allocator: std.mem.Allocator, cwd: []const u8) ![]const u8 {
    return storage.getSessionDirForCwd(allocator, cwd, null);
}

pub fn createAgentSession(
    allocator: std.mem.Allocator,
    options: CreateOptions,
) !AgentSession {
    const prepared = try session_bootstrap.prepareSessionDeps(allocator, .{
        .model = options.model,
        .api_key = options.api_key,
        .cwd = options.cwd,
        .io = options.io,
        .system_prompt = options.system_prompt,
        .context_files = options.context_files,
        .extension_paths = options.extension_paths,
        .agent_dir_override = options.agent_dir_override,
        .max_tokens = options.max_tokens,
        .tools = options.tools,
        .registry = options.registry,
        .auth_storage = options.auth_storage,
        .settings_manager = options.settings_manager,
        .session_store = options.session_store,
        .no_session = options.no_session,
        .append_system_prompt = options.append_system_prompt,
        .tool_allowlist = options.tool_allowlist,
        .extension_generation = options.extension_generation,
    });
    return AgentSession.init(allocator, .{
        .model = options.model,
        .prepared = prepared,
        .event_handler = options.event_handler,
        .auth_storage = options.auth_storage,
        .settings_manager = options.settings_manager,
        .model_registry = options.model_registry,
        .initial_messages = options.initial_messages,
        .thinking_level = options.thinking_level,
    });
}
