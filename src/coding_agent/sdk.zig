//! Composition-root factory for AgentSession.
//!
//! This is the canonical bootstrap path used by print/json/interactive
//! modes. `main.zig` resolves mode-specific concerns (auth, settings,
//! model choice), then hands session construction to this module.
//!
//! `createAgentSession(...)` owns the shared bootstrap wiring that
//! should not be duplicated at top-level callsites:
//! - resolve the on-disk session directory
//! - create/open the SessionStore when needed
//! - construct the ResourceLoader as the single owner of loaded
//!   extensions, prompt inputs, skills, and future resource kinds
//! - assemble the provider/tool/extension environment the session runs in
//! - inject prepared deps into AgentSession

const std = @import("std");
const ai = @import("../ai/root.zig");
const agent_mod = @import("../agent3/root.zig");
const storage = @import("../storage.zig");
const agent_session_mod = @import("agent_session.zig");
const session_bootstrap = @import("session_bootstrap.zig");
const model_registry_mod = @import("model_registry.zig");
const resources = @import("resources/root.zig");
const tool_def = @import("tools/definition.zig");
const auth_storage_mod = @import("auth/storage.zig");
const settings_manager_mod = @import("settings/manager.zig");

pub const AgentSession = agent_session_mod.AgentSession;
pub const SessionStore = agent_session_mod.SessionStore;
pub const PreparedSessionDeps = session_bootstrap.PreparedDeps;

pub const CreateOptions = struct {
    model: ai.protocol.Model,
    /// Static API key fallback. Used only when no `auth_storage` is
    /// attached or its lookup returns empty.
    api_key: []const u8 = "",
    cwd: []const u8,
    /// ResourceLoader bootstrap input: custom system-prompt source.
    system_prompt: ?[]const u8 = null,
    /// ResourceLoader bootstrap input: injected AGENTS/CLAUDE-style files.
    context_files: []const resources.types.AgentsFile = &.{},
    /// ResourceLoader bootstrap input: explicit extension roots/paths.
    extension_paths: []const []const u8 = &.{},
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
    /// ResourceLoader bootstrap input: append-system-prompt source.
    append_system_prompt: ?[]const u8 = null,
    tool_allowlist: ?[]const []const u8 = null,
};

/// Resolve the on-disk directory for a session's files before the
/// SessionStore is created. Caller owns the returned slice.
pub fn resolveSessionDir(allocator: std.mem.Allocator, cwd: []const u8) ![]const u8 {
    return storage.getSessionDirForCwd(allocator, cwd, null);
}

/// Build a fully-initialized `AgentSession` from resolved external
/// dependencies (model, api key, registry, etc.). The caller still
/// owns auth/settings/model resolution because those have mode-specific
/// error handling (print mode exits, interactive mode surfaces a prompt).
pub fn createAgentSession(
    allocator: std.mem.Allocator,
    options: CreateOptions,
) !AgentSession {
    const prepared = try session_bootstrap.prepareSessionDeps(allocator, .{
        .api_key = options.api_key,
        .cwd = options.cwd,
        .system_prompt = options.system_prompt,
        .context_files = options.context_files,
        .extension_paths = options.extension_paths,
        .max_tokens = options.max_tokens,
        .tools = options.tools,
        .registry = options.registry,
        .auth_storage = options.auth_storage,
        .settings_manager = options.settings_manager,
        .session_store = options.session_store,
        .no_session = options.no_session,
        .append_system_prompt = options.append_system_prompt,
        .tool_allowlist = options.tool_allowlist,
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
