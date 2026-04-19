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
//! - inject that loader into AgentSession
//!
//! Keeping this wiring here gives the application one composition root
//! instead of scattered ad hoc setup in `main.zig` and `coding_agent.zig`.

const std = @import("std");
const ai = @import("../ai/root.zig");
const agent_mod = @import("../agent3/root.zig");
const coding_agent = @import("root.zig");
const model_registry_mod = @import("model_registry.zig");
const storage = @import("../storage.zig");
const resources = @import("resources/root.zig");
const tool_def = @import("tools/definition.zig");
const auth_storage_mod = @import("auth/storage.zig");
const settings_manager_mod = @import("settings/manager.zig");

pub const AgentSession = coding_agent.AgentSession;
pub const SessionStore = coding_agent.SessionStore;
pub const RuntimeHost = @import("runtime_host.zig").RuntimeHost;
pub const RuntimeHostOptions = @import("runtime_host.zig").Options;
pub const ConversationStatePublisher = @import("runtime_host.zig").ConversationStatePublisher;
pub const RunOutcome = @import("runtime_host.zig").RunOutcome;
pub const RetryStart = @import("runtime_host.zig").RetryStart;
pub const RetryEnd = @import("runtime_host.zig").RetryEnd;
pub const CompactionReason = @import("runtime_host.zig").CompactionReason;
pub const CompactionEnd = @import("runtime_host.zig").CompactionEnd;
pub const LifecycleHooks = @import("runtime_host.zig").LifecycleHooks;
pub const RetryPolicy = @import("runtime_host.zig").RetryPolicy;
pub const CompactionPolicy = @import("runtime_host.zig").CompactionPolicy;
pub const CompactionExecutor = @import("runtime_host.zig").CompactionExecutor;
pub const SessionCompactionResult = @import("runtime_host.zig").CompactionResult;

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
///
/// Bootstrap order:
///   1. resolveSessionDir(cwd)
///   2. SessionStore.create(session_dir, cwd) — if no store was passed in
///   3. ResourceLoader.init(...) — canonical resource owner for the session
///   4. AgentSession.init(...) — consumes the injected loader dependency
///
/// Returned session is owned by the caller — `defer session.deinit()`.
pub fn createAgentSession(
    allocator: std.mem.Allocator,
    options: CreateOptions,
) !AgentSession {
    var session_store = options.session_store;

    // Pre-build the session store using the resolved directory.
    // A store passed in by the caller (e.g. from --continue via
    // SessionStore.open) wins — we never overwrite it.
    if (session_store == null and !options.no_session) {
        const session_dir = try resolveSessionDir(allocator, options.cwd);
        session_store = SessionStore.create(allocator, session_dir, options.cwd);
    }

    const resource_loader = try resources.ResourceLoader.init(allocator, .{
        .cwd = options.cwd,
        .settings_manager = options.settings_manager,
        .system_prompt = options.system_prompt,
        .append_system_prompt = options.append_system_prompt,
        .injected_agents_files = options.context_files,
    });

    // A3+ will construct and attach the ExtensionRunner here.
    return AgentSession.init(allocator, .{
        .model = options.model,
        .api_key = options.api_key,
        .cwd = options.cwd,
        .resource_loader = resource_loader,
        .max_tokens = options.max_tokens,
        .tools = options.tools,
        .registry = options.registry,
        .event_handler = options.event_handler,
        .auth_storage = options.auth_storage,
        .settings_manager = options.settings_manager,
        .model_registry = options.model_registry,
        .initial_messages = options.initial_messages,
        .thinking_level = options.thinking_level,
        .session_store = session_store,
        .no_session = options.no_session,
        .tool_allowlist = options.tool_allowlist,
    });
}
