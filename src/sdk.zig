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

pub const AgentSession = coding_agent.AgentSession;

/// Options forwarded to `AgentSession.init`. Re-exported so callers
/// only need to import `sdk.zig`, not `coding_agent.zig`.
pub const CreateOptions = AgentSession.Options;

/// Build a fully-initialized `AgentSession` from resolved external
/// dependencies (model, api key, registry, etc.). The caller still
/// owns auth/settings/model resolution because those have mode-specific
/// error handling (print mode exits, interactive mode surfaces a prompt).
///
/// Returned session is owned by the caller — `defer session.deinit()`.
pub fn createAgentSession(
    allocator: std.mem.Allocator,
    options: CreateOptions,
) AgentSession {
    // v1: pass-through. A3 grows this body with ExtensionRunner
    // construction; A4 adds the forward-declared runner ref; A5 moves
    // session directory resolution here. Tracked in beads Phase A.
    return AgentSession.init(allocator, options);
}
