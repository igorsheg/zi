const std = @import("std");
const ai_protocol = @import("../ai/protocol.zig");

/// AgentRequest — TUI thread → agent thread mutation channel.
///
/// This is the second of the two cross-thread channels mandated by
/// the runtime ownership doctrine (the first being `EventQueue`, agent → TUI).
/// See `docs/runtime.md` and bead `zi-wub.14`.
///
/// Direction:
///
///   TUI thread                       agent thread
///   ──────────                       ────────────
///   push(AgentRequest)  ──────────▶  drainInto([])
///                                    dispatch by tag
///                                    publish result via EventQueue
///
/// Variants are added as consumers land. zi-wub.14 introduces the
/// channel itself with the variants the next beads will need:
///   - resume_session : consumed by zi-wub.15 (/resume)
///   - new_session    : consumed by /new
///   - set_model      : consumed by zi-wub.16 (/model)
///
/// `shutdown` (zi-wub.28) is the terminal request: pushed by
/// `Interactive.deinit` so the agent thread itself tears down the
/// extension runner and lua_State on the thread that owns them.
/// This unblocks zi-wub.7 (flipping wrong-thread lua access to
/// fatal) by ensuring `lua_close` no longer runs on the TUI thread.
///
/// Allocator rule (doctrine R3): every payload slice carried by an
/// AgentRequest MUST be allocated from the thread-safe `msg_allocator`,
/// not from `tui_arena` or `agent_arena`. The agent-thread consumer
/// frees with the same allocator after dispatch via `deinit`.
pub const AgentRequest = union(enum) {
    resume_session: struct { path: []const u8 },
    new_session: void,
    set_model: struct { model: ai_protocol.Model },
    set_thinking_level: struct { level: @import("protocol.zig").ThinkingLevel },
    refresh_status_snapshot: void,
    shutdown: void,

    pub fn deinit(self: *AgentRequest, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .resume_session => |r| allocator.free(r.path),
            .new_session => {},
            .set_model => {},
            .set_thinking_level => {},
            .refresh_status_snapshot => {},
            .shutdown => {},
        }
    }
};

/// Mpsc-ish queue for AgentRequest. Mirrors the shape of the
/// `EventQueue` in `tui/interactive.zig` but flows the opposite
/// direction. Kept as a dedicated type rather than a generic over T
/// because the two queues differ in payload-free semantics and the
/// generic indirection would obscure that.
///
/// Storage: `items` backing storage MUST be `msg_allocator` (R3) so
/// the cross-thread free path is sound. The owner (Interactive) is
/// responsible for passing `msg_allocator` at init.
pub const RequestQueue = struct {
    items: std.ArrayListUnmanaged(AgentRequest) = .empty,
    mutex: std.Thread.Mutex = .{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RequestQueue {
        return .{ .allocator = allocator };
    }

    /// Drains and frees any pending requests. Safe to call only when
    /// the agent thread is joined — there must be no concurrent push.
    pub fn deinit(self: *RequestQueue) void {
        for (self.items.items) |*req| req.deinit(self.allocator);
        self.items.deinit(self.allocator);
    }

    /// Push from the TUI thread. On allocation failure, the request
    /// is dropped and its payloads freed — the channel does not
    /// surface enqueue errors to the caller because there is no
    /// meaningful recovery at the call site. This matches EventQueue.
    pub fn push(self: *RequestQueue, req: AgentRequest) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.items.append(self.allocator, req) catch {
            var mutable = req;
            mutable.deinit(self.allocator);
            return;
        };
    }

    /// Drain up to `out.len` requests into the caller's buffer.
    /// Called from the agent thread at safe points (turn boundary).
    /// Returns 0 when empty — the consumer must NOT block waiting.
    /// See doctrine R5: this epic does not introduce an event loop.
    pub fn drainInto(self: *RequestQueue, out: []AgentRequest) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        const count = @min(self.items.items.len, out.len);
        if (count == 0) return 0;
        @memcpy(out[0..count], self.items.items[0..count]);
        if (count < self.items.items.len) {
            std.mem.copyForwards(AgentRequest, self.items.items[0..], self.items.items[count..]);
        }
        self.items.items.len -= count;
        return count;
    }
};

test "RequestQueue round-trips a resume_session payload" {
    const allocator = std.testing.allocator;
    var q = RequestQueue.init(allocator);
    defer q.deinit();

    const path = try allocator.dupe(u8, "/tmp/some/session.jsonl");
    q.push(.{ .resume_session = .{ .path = path } });

    var buf: [4]AgentRequest = undefined;
    const n = q.drainInto(&buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("/tmp/some/session.jsonl", buf[0].resume_session.path);
    buf[0].deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), q.drainInto(&buf));
}
