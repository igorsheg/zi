//! Compaction extension seam.
//!
//! Defines the hook payload contract at the session layer so extensions can
//! observe preparation, cancel compaction, provide alternate compaction
//! content, and observe the persisted result — without reaching into runtime
//! internals and without weakening thread or ownership doctrine.
//!
//! pi-mono parity: session_before_compact + session_compact hooks.
//!
//! Wiring note: this slice establishes the seam types and the call-order
//! contract in the executor. Lua extension dispatch (pairing this surface
//! with ExtensionRunner handler lookup) is deliberately a follow-up step;
//! the point of this slice is that any extension runtime can bind a pair of
//! function pointers here without further executor changes.

const std = @import("std");
const prep = @import("compaction_prep.zig");
const proto = @import("../../session/protocol.zig");

/// Snapshot of compaction prep visible to an extension. Slices are
/// borrows owned by the caller's arena; do not retain past the hook call.
pub const BeforeCompactPayload = struct {
    reason: Reason,
    preparation: *const prep.CompactionPreparation,

    pub const Reason = enum { manual, threshold, overflow };
};

/// Result returned by a `session_before_compact` hook.
pub const BeforeCompactOutcome = union(enum) {
    /// Let zi's default summarization pass run.
    proceed,
    /// Abort compaction — propagates as error.CompactionCancelled.
    cancel,
    /// Skip zi's summarization and persist this content instead.
    /// `from_hook = true` will be written to the persisted entry.
    provide: ProvidedCompaction,
};

pub const ProvidedCompaction = struct {
    summary: []const u8,
    first_kept_entry_id: []const u8,
    tokens_before: u64,
    details: ?std.json.Value = null,
};

/// Payload for `session_compact` observers. Called after the compaction
/// entry has been persisted. `entry` is read-only; detail values borrow
/// from the cache arena and may not outlive the call.
pub const AfterCompactPayload = struct {
    reason: BeforeCompactPayload.Reason,
    entry: proto.CompactionEntry,
};

pub const CompactionHooks = struct {
    ctx: ?*anyopaque = null,
    before_compact: ?*const fn (payload: BeforeCompactPayload, ctx: ?*anyopaque) BeforeCompactOutcome = null,
    after_compact: ?*const fn (payload: AfterCompactPayload, ctx: ?*anyopaque) void = null,
};
