const std = @import("std");
const ai = @import("../ai/root.zig");
const agent_root = @import("../agent/root.zig");
const conversation_snapshot_mod = @import("../conversation_snapshot.zig");
const message_memory = agent_root.message_memory;
const session_controller_mod = @import("../session_controller.zig");
const RunOutcome = session_controller_mod.RunOutcome;

/// TUI-owned event type. All cross-thread payloads are deep-copied and
/// mailbox-owned. Conversation changes cross either as full semantic
/// snapshots (resync / resume / reset) or as incremental semantic patches
/// for the live hot path.
pub const UiEvent = union(enum) {
    // --- conversation transport ---
    conversation_patch: agent_root.conversation.ConversationPatch,
    conversation_snapshot: conversation_snapshot_mod.ConversationSnapshot,

    // --- errors / status side effects ---
    error_message: struct { message: []u8 },
    assistant_run_finished: struct {
        is_aborted: bool,
        error_message: ?[]u8,
        failure_kind: ?ai.protocol.NormalizedFailure.Kind = null,
    },
    tool_running: struct {
        tool_name: []u8,
    },

    // --- login lifecycle ---
    // zi-wub.17: login thread publishes progress/auth-url through the
    // event queue instead of mutating status_text directly. Single-owner
    // invariant restored for status_text — only the TUI thread writes.
    login_progress: struct {
        message: []u8,
        kind: enum { info, auth_url },
    },
    login_complete: struct {
        provider_id: []u8,
        success: bool,
        message: []u8,
    },

    // --- retry lifecycle ---
    retry_start: struct {
        attempt: u32,
        max_attempts: u32,
        delay_ms: u64,
        error_message: []u8,
    },
    retry_wait_finished: void,
    retry_end: struct {
        success: bool,
        attempt: u32,
        final_error: ?[]u8 = null,
    },

    // --- prompt lifecycle ---
    prompt_worker_finished: struct {
        outcome: RunOutcome,
        internal_error: ?[]u8 = null,
    },

    // --- request drain lifecycle ---
    // Emitted by the long-lived agent owner thread after it finishes a
    // non-prompt AgentRequest drain. Separate from `prompt_worker_finished`
    // so the TUI can unwind request-mode loaders without stomping on
    // status_text or focus that the individual request handlers already set.
    request_worker_finished: void,

    // --- queued-message snapshot ---
    // Authoritative snapshot of the run-control steering/follow-up boundary.
    // Used by the TUI to render queued user-message rows and restore them
    // for amendment without maintaining a parallel semantic mirror.
    queue_snapshot: agent_root.QueuedMessageSnapshot,

    // --- /resume outcomes ---
    // Banner-only outcome. Transcript state now crosses separately via
    // `conversation_snapshot` so resume no longer ships raw AgentMessage[]
    // through this event.
    session_resumed: struct {
        restore_warning: ?[]u8 = null,
    },
    session_resume_failed: struct {
        message: []u8,
    },

    // --- /new outcomes ---
    session_new_started: void,
    session_new_failed: struct {
        message: []u8,
    },

    // --- shared status snapshot ---
    // Agent-thread owned model/thinking/context snapshot for the editor
    // border chips. Published whenever session state changes in a way the
    // TUI must render without reading agent-owned state directly.
    // Semantic state crosses the boundary; chip formatting/layout stays
    // TUI-owned rather than becoming part of the mailbox payload.
    status_snapshot: struct {
        model_provider: []u8,
        model_id: []u8,
        thinking_level: []u8,
        context_tokens: ?u64,
        context_window: u64,
    },

    // --- /model outcomes (zi-wub.16) ---
    // Published by the agent thread after processing a set_model
    // AgentRequest. Success is banner-only; semantic model state is
    // carried by the adjacent status_snapshot publication.
    model_switched: void,
    model_switch_failed: struct {
        message: []u8,
    },

    // --- /settings thinking-level outcomes ---
    // Success is banner-only; semantic thinking state is carried by
    // the adjacent status_snapshot publication.
    thinking_level_changed: void,
    thinking_level_change_failed: struct {
        message: []u8,
    },

    /// Free all owned memory.
    pub fn deinit(self: *UiEvent, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .conversation_patch => |*patch| patch.deinit(allocator),
            .conversation_snapshot => |*snapshot| snapshot.deinit(allocator),
            .error_message => |e| allocator.free(e.message),
            .assistant_run_finished => |m| {
                if (m.error_message) |msg| allocator.free(msg);
            },
            .tool_running => |t| allocator.free(t.tool_name),
            .login_progress => |l| allocator.free(l.message),
            .login_complete => |l| {
                allocator.free(l.provider_id);
                allocator.free(l.message);
            },
            .retry_start => |r| allocator.free(r.error_message),
            .retry_end => |r| {
                if (r.final_error) |msg| allocator.free(msg);
            },
            .queue_snapshot => |*q| q.deinit(allocator),
            .session_resumed => |s| {
                if (s.restore_warning) |warning| allocator.free(warning);
            },
            .session_resume_failed => |f| allocator.free(f.message),
            .session_new_started => {},
            .session_new_failed => |f| allocator.free(f.message),
            .status_snapshot => |s| {
                allocator.free(s.model_provider);
                allocator.free(s.model_id);
                allocator.free(s.thinking_level);
            },
            .model_switch_failed => |m| allocator.free(m.message),
            .thinking_level_change_failed => |t| allocator.free(t.message),
            .prompt_worker_finished => |p| {
                if (p.internal_error) |msg| allocator.free(msg);
            },
            .retry_wait_finished, .request_worker_finished, .model_switched, .thinking_level_changed => {},
        }
    }
};

const testing = std.testing;

test "UiEvent deinit frees conversation patch payloads" {
    var ev = UiEvent{ .conversation_patch = .{ .append_frontier_content = .{
        .target = .{ .assistant_content = .{ .content_index = 0, .kind = .text } },
        .bytes = try testing.allocator.dupe(u8, "hello"),
    } } };
    ev.deinit(testing.allocator);
}

test "UiEvent deinit frees conversation snapshot payload" {
    const snapshot = try conversation_snapshot_mod.build(testing.allocator, .{
        .version = 1,
        .messages = &.{},
    });
    var ev = UiEvent{ .conversation_snapshot = snapshot };
    ev.deinit(testing.allocator);
}

test "UiEvent deinit frees tool-running label" {
    var ev = UiEvent{ .tool_running = .{
        .tool_name = try testing.allocator.dupe(u8, "bash"),
    } };
    ev.deinit(testing.allocator);
}

test "UiEvent deinit handles assistant failure without message" {
    var ev = UiEvent{ .assistant_run_finished = .{
        .is_aborted = false,
        .error_message = null,
    } };
    ev.deinit(testing.allocator);
}
