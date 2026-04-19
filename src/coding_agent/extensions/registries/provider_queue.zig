//! Provider queue — pending custom-provider registrations awaiting bind.
//!
//! v1 leaves this empty: `zi.register_provider` is not yet exposed.
//! The queue exists because the documented lifecycle separates load from
//! bind — the runner accepts registrations during
//! the load phase (when AgentSession isn't built yet) and flushes
//! them into the AI provider registry once binding completes.
//!
//! Why a queue, not a registry: providers are not addressable by
//! name from inside the extension system. Once flushed they belong
//! to `ai.provider.Registry` (the canonical zi-yjc bundle), and the
//! runner forgets about them. The queue is FIFO write-only; bind is
//! a single drain.
//!
//! v2 will add `unregister_provider`. That can be implemented either
//! as a queue scrub (before bind) or a passthrough to the AI registry's
//! `unregisterBySource` (after bind), keeping this file's job small.

const std = @import("std");
const tool_registry = @import("tool_registry.zig");

/// One pending provider registration. The shape is intentionally
/// minimal in v1 — fields will grow when v2 specifies what
/// `zi.register_provider` accepts. Today it's just enough to
/// document the seam.
pub const PendingProvider = struct {
    /// API identifier the provider answers to (e.g. "anthropic-messages").
    /// Owned.
    api: []const u8,
    /// Lua registry ref to the provider config table. Resolved during
    /// flush by the runner — it constructs the actual `ai.provider.Provider`
    /// from the table and registers it. Stored as raw c_int because
    /// extensions/runner.zig is the only thing that should reach into
    /// Lua memory at flush time.
    config_ref: c_int,
    /// Provenance — extension file path. Borrowed.
    source: tool_registry.RegistrationSource,
};

pub const ProviderQueue = struct {
    allocator: std.mem.Allocator,
    pending: std.ArrayListUnmanaged(PendingProvider) = .empty,

    pub fn init(allocator: std.mem.Allocator) ProviderQueue {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ProviderQueue) void {
        for (self.pending.items) |*p| self.allocator.free(p.api);
        self.pending.deinit(self.allocator);
    }

    /// Append a provider to the queue. Always succeeds (modulo OOM)
    /// — duplicate-api detection happens at flush time, when the
    /// queue collides with the existing AI provider registry, not
    /// here. The queue preserves registrations until bind, where normal
    /// extension precedence rules are applied.
    pub fn enqueue(self: *ProviderQueue, p: PendingProvider) !void {
        try self.pending.append(self.allocator, p);
    }

    /// Drain the queue. Caller takes ownership of every entry's
    /// `api` slice — the queue's own bookkeeping is reset and a
    /// subsequent enqueue starts from empty. The borrowed `source`
    /// strings remain owned by the loader.
    ///
    /// Used during `bindRuntime` (D7) once the AI provider registry
    /// is available; the runner walks the drained slice, resolves
    /// each Lua config, and hands it to the registry. v1 never
    /// invokes this — there's nothing to drain.
    pub fn drain(self: *ProviderQueue) []const PendingProvider {
        return self.pending.toOwnedSlice(self.allocator) catch &.{};
    }

    pub fn count(self: *const ProviderQueue) usize {
        return self.pending.items.len;
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "ProviderQueue accumulates and drains" {
    var q = ProviderQueue.init(testing.allocator);
    defer q.deinit();

    try q.enqueue(.{
        .api = try testing.allocator.dupe(u8, "anthropic-messages"),
        .config_ref = 1,
        .source = .{ .kind = "user", .id = "ext1" },
    });
    try q.enqueue(.{
        .api = try testing.allocator.dupe(u8, "openai-responses"),
        .config_ref = 2,
        .source = .{ .kind = "project", .id = "ext2" },
    });

    try testing.expectEqual(@as(usize, 2), q.count());

    const drained = q.drain();
    defer {
        for (drained) |p| testing.allocator.free(p.api);
        testing.allocator.free(drained);
    }

    try testing.expectEqual(@as(usize, 2), drained.len);
    try testing.expectEqual(@as(usize, 0), q.count());
    try testing.expectEqualStrings("anthropic-messages", drained[0].api);
    try testing.expectEqualStrings("openai-responses", drained[1].api);
}
