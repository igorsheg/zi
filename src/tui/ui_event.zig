const std = @import("std");
const json_util = @import("../ai/json_util.zig");
const agent_protocol = @import("../agent/root.zig").protocol;
const AgentToolResult = agent_protocol.AgentToolResult;

/// TUI-owned event type. All fields are deep-copied and owned by the
/// main thread. The agent thread converts AgentEvent → UiEvent before
/// pushing to the EventQueue, ensuring no borrowed pointers cross
/// the thread boundary.
/// Projection of a session message into a form the transcript can
/// rebuild from without borrowing agent-owned AgentMessage data.
/// Extended by zi-wub.24 to cover tool calls + results.
pub const ResumedEntry = union(enum) {
    user_text: []u8,
    assistant_text: []u8,

    pub fn deinit(self: *ResumedEntry, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .user_text => |s| allocator.free(s),
            .assistant_text => |s| allocator.free(s),
        }
    }
};

pub const UiEvent = union(enum) {
    // --- message lifecycle ---
    message_start_assistant: void,
    message_start_user: void,

    // --- streaming content ---
    text_delta: struct { delta: []u8 },

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

    // --- agent lifecycle ---
    agent_finished: void,
    agent_error: void,

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
    // from `entries` and frees them.
    //
    // Payload shape is intentionally a display projection, NOT the
    // full AgentMessage list — AgentMessage ownership stays on the
    // agent thread (doctrine R3). The shape is extensible: today
    // only `user_text` and `assistant_text` are populated, matching
    // pre-.15 rebuild fidelity. zi-wub.24 will extend it to carry
    // tool calls and results for full parity with pi-mono.
    session_resumed: struct {
        entries: []ResumedEntry,
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

    // --- /model outcomes (zi-wub.16) ---
    // Published by the agent thread after processing a set_model
    // AgentRequest. The model id is owned (cloned into msg_allocator)
    // so the TUI can display it without reaching back into agent state.
    model_switched: struct {
        id: []u8,
    },

    /// Free all owned memory.
    pub fn deinit(self: *UiEvent, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .text_delta => |d| allocator.free(d.delta),
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
            .session_resumed => |s| {
                for (s.entries) |*e| e.deinit(allocator);
                allocator.free(s.entries);
                if (s.restore_warning) |w| allocator.free(w);
            },
            .session_resume_failed => |f| allocator.free(f.message),
            .model_switched => |m| allocator.free(m.id),
            .message_start_assistant, .message_start_user,
            .agent_finished, .agent_error, .request_worker_finished,
            => {},
        }
    }
};

// --- tests ---

const testing = std.testing;

test "UiEvent deinit frees owned fields" {
    var ev = UiEvent{ .text_delta = .{
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
