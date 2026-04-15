const std = @import("std");
const ai_protocol = @import("../ai/protocol.zig");
const mailbox_mod = @import("../runtime/mailbox.zig");

/// AgentRequest — mailbox payload for the TUI → agent mutation channel.
///
/// This is one of zi's two cross-thread mailbox-backed channels:
/// request queue here (TUI → agent) and event queue in the TUI
/// integration (agent/helper → TUI). See `docs/runtime.md`.
///
/// Direction:
///
///   TUI thread                       agent thread
///   ──────────                       ────────────
///   trySend/push(AgentRequest) ───▶  drainInto([])
///                                    dispatch by tag
///                                    publish result via UiEvent queue
///
/// Active request variants:
///   - resume_session
///   - new_session
///   - set_model
///   - set_thinking_level
///   - refresh_status_snapshot
///   - shutdown
///
/// `shutdown` is the terminal request: `Interactive.deinit` enqueues it
/// so the agent thread itself tears down the extension runner and
/// lua_State on the thread that owns them.
///
/// Allocator rule (doctrine R3): every payload slice carried by an
/// AgentRequest MUST be allocated from the thread-safe `msg_allocator`,
/// not from the TUI-local state allocator or `agent_arena`. The
/// agent-thread consumer frees with the same allocator after dispatch
/// via `deinit`.
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

pub const RequestQueue = mailbox_mod.Mailbox(AgentRequest, .{
    .cleanup = .deinit,
    .policy = .unbounded,
    // The TUI explicitly decides when to spawn/drain agent workers, so
    // this mailbox does not need an internal wake primitive.
    .wakeup = .none,
});

test "RequestQueue round-trips a resume_session payload" {
    const allocator = std.testing.allocator;
    var q = try RequestQueue.init(allocator);
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
