const std = @import("std");
const prep = @import("compaction_prep.zig");
const proto = @import("../../session/protocol.zig");

pub const BeforeCompactPayload = struct {
    reason: Reason,
    preparation: *const prep.CompactionPreparation,

    pub const Reason = enum { manual, threshold, overflow };
};

pub const BeforeCompactOutcome = union(enum) {
    proceed,

    cancel,

    provide: ProvidedCompaction,
};

pub const ProvidedCompaction = struct {
    summary: []const u8,
    first_kept_entry_id: []const u8,
    tokens_before: u64,
    details: ?std.json.Value = null,
};

pub const AfterCompactPayload = struct {
    reason: BeforeCompactPayload.Reason,
    entry: proto.CompactionEntry,
};

pub const CompactionHooks = struct {
    ctx: ?*anyopaque = null,
    before_compact: ?*const fn (payload: BeforeCompactPayload, ctx: ?*anyopaque) BeforeCompactOutcome = null,
    after_compact: ?*const fn (payload: AfterCompactPayload, ctx: ?*anyopaque) void = null,
};
