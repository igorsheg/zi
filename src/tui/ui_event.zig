const std = @import("std");
const ai = @import("../ai/root.zig");
const agent_root = @import("../agent/root.zig");
const agent_protocol = agent_root.protocol;
const conversation_snapshot_mod = @import("../conversation_snapshot.zig");
const session_controller_mod = @import("../session_controller.zig");
const AgentToolResult = agent_protocol.AgentToolResult;
const RunOutcome = session_controller_mod.RunOutcome;

/// TUI-owned event type. All fields are deep-copied and owned by the
/// main thread. The agent thread converts AgentEvent → UiEvent before
/// pushing to the mailbox-backed event queue, ensuring no borrowed
/// pointers cross the thread boundary.
pub const UiEvent = union(enum) {
    // --- errors ---
    error_message: struct { message: []u8 },

    // --- assistant message finalization ---
    message_end_assistant: struct {
        is_aborted: bool,
        error_message: ?[]u8,
        failure_kind: ?ai.protocol.NormalizedFailure.Kind = null,
    },

    // --- tool execution lifecycle ---
    tool_end: struct {
        tool_call_id: []u8,
        result: ?AgentToolResult,
        is_error: bool,
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

    // --- conversation snapshot ---
    // Owned semantic snapshot of transcript-visible conversation state.
    // The agent/composition side publishes authoritative semantics;
    // the TUI rebuilds its retained transcript/editor state locally.
    conversation_snapshot: conversation_snapshot_mod.ConversationSnapshot,

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
            .error_message => |e| allocator.free(e.message),
            .message_end_assistant => |m| {
                if (m.error_message) |msg| allocator.free(msg);
            },
            .tool_end => |t| {
                allocator.free(t.tool_call_id);
                if (t.result) |r| r.free(allocator);
            },
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
            .conversation_snapshot => |*s| s.deinit(allocator),
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

// --- tests ---

const testing = std.testing;

test "UiEvent deinit handles null result" {
    var ev = UiEvent{ .tool_end = .{
        .tool_call_id = try testing.allocator.dupe(u8, "id-2"),
        .result = null,
        .is_error = false,
    } };
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
