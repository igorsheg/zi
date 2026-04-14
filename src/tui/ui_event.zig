const std = @import("std");
const ai = @import("../ai/root.zig");
const json_util = @import("../ai/json_util.zig");
const agent_root = @import("../agent/root.zig");
const agent_protocol = agent_root.protocol;
const message_memory = agent_root.message_memory;
const session_controller_mod = @import("../session_controller.zig");
const AgentToolResult = agent_protocol.AgentToolResult;
const RunOutcome = session_controller_mod.RunOutcome;

/// TUI-owned event type. All fields are deep-copied and owned by the
/// main thread. The agent thread converts AgentEvent → UiEvent before
/// pushing to the mailbox-backed event queue, ensuring no borrowed
/// pointers cross the thread boundary.
pub const UiEvent = union(enum) {
    // --- message lifecycle ---
    message_start_assistant: void,
    message_start_user: void,

    // --- streaming content ---
    assistant_text_delta: struct {
        content_index: usize,
        delta: []u8,
    },
    assistant_thinking_delta: struct {
        content_index: usize,
        delta: []u8,
    },

    // --- errors ---
    error_message: struct { message: []u8 },

    // --- tool call streaming (from assistant message content, before execution) ---
    // Emitted both for in-progress deltas (`is_complete = false`) and
    // the final toolcall_end (`is_complete = true`). The transcript
    // only marks args as "complete" (which freezes the renderer cache)
    // on the terminal event; intermediate events keep args mutable so
    // incremental parses can overwrite them as the model types.
    tool_call_streaming: struct {
        tool_call_id: []u8,
        tool_name: []u8,
        args: std.json.Value,
        is_complete: bool,
    },

    // --- assistant message finalization ---
    message_end_assistant: struct {
        is_aborted: bool,
        error_message: ?[]u8,
        failure_kind: ?ai.protocol.NormalizedFailure.Kind = null,
    },

    // --- tool execution lifecycle ---
    tool_start: struct {
        tool_call_id: []u8,
        tool_name: []u8,
        args: std.json.Value,
    },
    tool_update: struct {
        tool_call_id: []u8,
        result: ?AgentToolResult,
        is_error: bool,
    },
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

    // --- request-worker lifecycle (zi-wub.15) ---
    // Emitted by a drain-only agent worker thread after it finishes
    // processing AgentRequests. Separate from `agent_finished` so the
    // TUI can run request-mode cleanup (e.g. hide the "loading session"
    // loader) WITHOUT stomping on status_text that a successful resume
    // just set. See oracle review for .15: `.agent_finished` already
    // clears status_text and restores editor focus — reusing it for
    // request work would wipe the success message.
    request_worker_finished: void,

    // --- /resume outcomes (zi-wub.15) ---
    // Published by the agent thread after processing a
    // resume_session AgentRequest. The TUI rebuilds the transcript
    // from an owned AgentMessage snapshot and frees it after apply.
    //
    // Payload is a full deep-cloned message list allocated from
    // `msg_allocator` so the TUI can reconstruct transcript surfaces
    // without re-reading agent-owned session state.
    session_resumed: struct {
        messages: []agent_protocol.AgentMessage,
        /// Optional warning from `restoreModelFromSession` when the
        /// saved model could not be brought back verbatim (missing
        /// from the catalog or lost auth). Owned by the event —
        /// freed in `deinit`. Rendered after the transcript rebuild
        /// so it survives the "session resumed" status update.
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
    status_snapshot: struct {
        model_provider: []u8,
        model_id: []u8,
        thinking_level: []u8,
        context_tokens: ?u64,
        context_window: u64,
    },

    // --- /model outcomes (zi-wub.16) ---
    // Published by the agent thread after processing a set_model
    // AgentRequest. Provider + model id are owned (cloned into
    // msg_allocator) so the TUI can both render status and persist
    // the new default without reaching back into agent state.
    model_switched: struct {
        provider: []u8,
        id: []u8,
    },
    model_switch_failed: struct {
        message: []u8,
    },

    // --- /settings thinking-level outcomes ---
    thinking_level_changed: struct {
        level: []u8,
    },
    thinking_level_change_failed: struct {
        message: []u8,
    },

    /// Free all owned memory.
    pub fn deinit(self: *UiEvent, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .assistant_text_delta => |d| allocator.free(d.delta),
            .assistant_thinking_delta => |d| allocator.free(d.delta),
            .error_message => |e| allocator.free(e.message),
            .tool_call_streaming => |t| {
                allocator.free(t.tool_call_id);
                allocator.free(t.tool_name);
                json_util.freeJsonValue(allocator, t.args);
            },
            .message_end_assistant => |m| {
                if (m.error_message) |msg| allocator.free(msg);
            },
            .tool_start => |t| {
                allocator.free(t.tool_call_id);
                allocator.free(t.tool_name);
                json_util.freeJsonValue(allocator, t.args);
            },
            .tool_update => |t| {
                allocator.free(t.tool_call_id);
                if (t.result) |r| r.free(allocator);
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
            .session_resumed => |s| {
                message_memory.freeMessages(allocator, s.messages);
                if (s.restore_warning) |w| allocator.free(w);
            },
            .session_resume_failed => |f| allocator.free(f.message),
            .session_new_started => {},
            .session_new_failed => |f| allocator.free(f.message),
            .status_snapshot => |s| {
                allocator.free(s.model_provider);
                allocator.free(s.model_id);
                allocator.free(s.thinking_level);
            },
            .model_switched => |m| {
                allocator.free(m.provider);
                allocator.free(m.id);
            },
            .model_switch_failed => |m| allocator.free(m.message),
            .thinking_level_changed => |t| allocator.free(t.level),
            .thinking_level_change_failed => |t| allocator.free(t.message),
            .prompt_worker_finished => |p| {
                if (p.internal_error) |msg| allocator.free(msg);
            },
            .message_start_assistant, .message_start_user, .retry_wait_finished, .request_worker_finished => {},
        }
    }
};

// --- tests ---

const testing = std.testing;

test "UiEvent deinit frees owned fields" {
    var ev = UiEvent{ .assistant_text_delta = .{
        .content_index = 0,
        .delta = try testing.allocator.dupe(u8, "hello"),
    } };
    ev.deinit(testing.allocator);
    // no leak = pass (allocator detects leaks)
}

test "UiEvent deinit handles tool_start fields" {
    var ev = UiEvent{ .tool_start = .{
        .tool_call_id = try testing.allocator.dupe(u8, "id-1"),
        .tool_name = try testing.allocator.dupe(u8, "bash"),
        .args = .null,
    } };
    ev.deinit(testing.allocator);
}

test "UiEvent deinit handles null result" {
    var ev = UiEvent{ .tool_end = .{
        .tool_call_id = try testing.allocator.dupe(u8, "id-2"),
        .result = null,
        .is_error = false,
    } };
    ev.deinit(testing.allocator);
}
