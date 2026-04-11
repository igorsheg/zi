//! Composition-root factory for AgentSession.
//!
//! Why this module exists, even though v1 is a thin wrapper:
//!
//! Phase A of the extension system reorganizes the bootstrap path so
//! that creating a session is a single call into a well-known seam,
//! not a pile of inline wiring in `main.zig`. Today the factory already
//! owns session-store and ResourceLoader bootstrap. In subsequent phases
//! it grows to own the pieces that main.zig must not know about:
//!
//!   - A3: construct and own the ExtensionRunner (discovered extensions,
//!         registered tools, stub runtime) and thread it into the session.
//!   - A4: forward-declared runner ref pattern — the Agent's stream_fn,
//!         transform_context, and on_payload closures capture a mutable
//!         ref to the runner populated here, mirroring pi-mono's
//!         `extensionRunnerRef: { current?: ExtensionRunner }` dance.
//!   - A5: `resolveSessionDir(cwd)` pre-step runs BEFORE the session
//!         store is created, so v2's `session_directory` event can hook
//!         in without moving store ownership.
//!   - Phase D: bindRuntime(runner, session, ui?) happens here once the
//!         session is alive; provider_queue flushes; session_start fires.
//!
//! Keeping this factory in place — even when it's trivial — means every
//! downstream consumer (print mode, json mode, interactive mode) already
//! goes through the one door where that wiring will eventually land.
//! No retrofit into `main.zig` later.
//!
//! See docs/extensions.md § Architecture and § Lifecycle.

const std = @import("std");
const ai = @import("ai/root.zig");
const agent_mod = @import("agent/root.zig");
const coding_agent = @import("coding_agent.zig");
const storage = @import("storage.zig");
const resources = @import("resources/root.zig");
const tool_def = @import("tools/definition.zig");
const auth_storage_mod = @import("auth/storage.zig");
const extension_runner_mod = @import("extensions/runner.zig");

pub const AgentSession = coding_agent.AgentSession;
pub const SessionStore = coding_agent.SessionStore;
pub const SessionController = @import("session_controller.zig").SessionController;
pub const SessionEvent = @import("session_controller.zig").SessionEvent;
pub const SessionPhase = @import("session_controller.zig").Phase;
pub const RetryPolicy = @import("session_controller.zig").RetryPolicy;
pub const CompactionPolicy = @import("session_controller.zig").CompactionPolicy;
pub const CompactionExecutor = @import("session_controller.zig").CompactionExecutor;
pub const SessionCompactionResult = @import("session_controller.zig").CompactionResult;
pub const ExtensionRunnerRef = extension_runner_mod.ExtensionRunnerRef;

pub const CreateOptions = struct {
    model: ai.protocol.Model,
    /// Static API key fallback. Used only when no `auth_storage` is
    /// attached or its lookup returns empty.
    api_key: []const u8 = "",
    cwd: []const u8,
    system_prompt: ?[]const u8 = null,
    context_files: []const resources.types.AgentsFile = &.{},
    max_tokens: ?u64 = 4096,
    tools: ?[]const tool_def.ToolDefinition = null,
    registry: ?*ai.provider.Registry = null,
    event_handler: ?AgentSession.EventHandler = null,
    auth_storage: ?*auth_storage_mod.AuthStorage = null,
    model_registry: ?*ai.model_registry.ModelRegistry = null,
    initial_messages: []const agent_mod.protocol.AgentMessage = &.{},
    thinking_level: ?agent_mod.protocol.ThinkingLevel = null,
    session_store: ?SessionStore = null,
    no_session: bool = false,
    append_system_prompt: ?[]const u8 = null,
    tool_allowlist: ?[]const []const u8 = null,
};

/// Resolve the on-disk directory for a session's files. Runs BEFORE
/// `SessionStore.create` so v2's `session_directory` extension event
/// has a chance to override the default.
///
/// v1: `runner_ref` is accepted but unused — the function always
/// returns `storage.getSessionDirForCwd(cwd)`. v2 will check
/// `runner_ref.current` and, if present, emit the `session_directory`
/// event into the runner and return the extension's override.
///
/// Caller owns the returned slice.
///
/// See docs/extensions.md § Session Directory Resolution.
pub fn resolveSessionDir(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    runner_ref: ?*ExtensionRunnerRef,
) ![]const u8 {
    _ = runner_ref; // v1: no hook wiring yet.
    return storage.getSessionDirForCwd(allocator, cwd, null);
}

/// Build a fully-initialized `AgentSession` from resolved external
/// dependencies (model, api key, registry, etc.). The caller still
/// owns auth/settings/model resolution because those have mode-specific
/// error handling (print mode exits, interactive mode surfaces a prompt).
///
/// Bootstrap order (v1):
///   1. resolveSessionDir(cwd, null) — v2 hook point
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
        const session_dir = try resolveSessionDir(allocator, options.cwd, null);
        session_store = SessionStore.create(allocator, session_dir, options.cwd);
    }

    const resource_loader = try resources.ResourceLoader.init(allocator, .{
        .cwd = options.cwd,
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
        .model_registry = options.model_registry,
        .initial_messages = options.initial_messages,
        .thinking_level = options.thinking_level,
        .session_store = session_store,
        .no_session = options.no_session,
        .tool_allowlist = options.tool_allowlist,
    });
}
