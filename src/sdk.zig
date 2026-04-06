//! Composition-root factory for AgentSession.
//!
//! Why this module exists, even though v1 is a thin wrapper:
//!
//! Phase A of the extension system reorganizes the bootstrap path so
//! that creating a session is a single call into a well-known seam,
//! not a pile of inline wiring in `main.zig`. Today the factory just
//! forwards to `AgentSession.init`. In subsequent phases it grows to
//! own the pieces that main.zig must not know about:
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
const coding_agent = @import("coding_agent.zig");
const storage = @import("storage.zig");
const extension_runner_mod = @import("extensions/runner.zig");

pub const AgentSession = coding_agent.AgentSession;
pub const SessionStore = coding_agent.SessionStore;
pub const ExtensionRunnerRef = extension_runner_mod.ExtensionRunnerRef;

/// Options forwarded to `AgentSession.init`. Re-exported so callers
/// only need to import `sdk.zig`, not `coding_agent.zig`.
pub const CreateOptions = AgentSession.Options;

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
///   3. AgentSession.init(...) — wires Agent + SessionStore + tools
///
/// Returned session is owned by the caller — `defer session.deinit()`.
pub fn createAgentSession(
    allocator: std.mem.Allocator,
    options: CreateOptions,
) !AgentSession {
    var opts = options;

    // Pre-build the session store using the resolved directory.
    // A store passed in by the caller (e.g. from --continue via
    // SessionStore.open) wins — we never overwrite it.
    if (opts.session_store == null and !opts.no_session) {
        const session_dir = try resolveSessionDir(allocator, opts.cwd, null);
        opts.session_store = SessionStore.create(allocator, session_dir, opts.cwd);
    }

    // A3+ will construct and attach the ExtensionRunner here.
    return AgentSession.init(allocator, opts);
}
