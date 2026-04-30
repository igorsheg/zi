const std = @import("std");

const agent_mod = @import("../../agent/root.zig");
const ai_protocol = @import("../../ai/protocol.zig");
const string_util = @import("../../lib/string_util.zig");
const ui_event_mod = @import("../ui_event.zig");

const AgentEvent = agent_mod.protocol.AgentEvent;
const UiEvent = ui_event_mod.UiEvent;

pub fn userFacingFailureMessage(
    failure_kind: ?ai_protocol.NormalizedFailure.Kind,
    raw_message: []const u8,
) []const u8 {
    return switch (failure_kind orelse return raw_message) {
        .auth => "authentication failed. run /login or refresh your credentials.",
        .context_overflow => "context window exceeded. compact the session or switch to a larger-context model.",
        .rate_limited => "provider rate limit reached. wait and try again, or switch providers.",
        .transient => "provider or network failure. try again shortly.",
        .invalid_request => if (string_util.containsCI(raw_message, "content_filter"))
            "request blocked by the provider safety filter. try rephrasing and try again."
        else
            raw_message,
        else => raw_message,
    };
}

/// Convert an AgentEvent to a small TUI side-effect event.
/// Conversation semantics cross separately as `conversation_state`.
pub fn convertAgentUiEvent(event: AgentEvent, allocator: std.mem.Allocator) ?UiEvent {
    switch (event) {
        .message_update => |mu| switch (mu.assistant_message_event) {
            .@"error" => |e| {
                const assistant = e.@"error";
                if (assistant.error_message) |msg| {
                    const display = userFacingFailureMessage(if (assistant.failure) |failure| failure.kind else null, msg);
                    const owned = allocator.dupe(u8, display) catch return null;
                    return .{ .error_message = .{ .message = owned } };
                }
                return null;
            },
            else => return null,
        },
        .tool_execution_start => |te| {
            const tool_name = allocator.dupe(u8, te.tool_name) catch return null;
            return .{ .tool_running = .{ .tool_name = tool_name } };
        },
        .message_end => |me| switch (me.message) {
            .assistant => |assistant| {
                if (assistant.stop_reason != .aborted and assistant.stop_reason != .@"error") return null;
                const err_msg = if (assistant.error_message) |msg|
                    (allocator.dupe(u8, msg) catch null)
                else
                    null;
                return .{ .assistant_run_finished = .{
                    .is_aborted = assistant.stop_reason == .aborted,
                    .error_message = err_msg,
                    .failure_kind = if (assistant.failure) |failure| failure.kind else null,
                } };
            },
            else => return null,
        },
        .agent_start, .agent_end, .turn_start, .turn_end, .message_start, .tool_execution_update, .tool_execution_end => return null,
    }
}
