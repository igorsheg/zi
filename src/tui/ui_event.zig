const std = @import("std");
const json_util = @import("../ai/json_util.zig");
const agent_protocol = @import("../agent/root.zig").protocol;
const AgentToolResult = agent_protocol.AgentToolResult;

/// TUI-owned event type. All fields are deep-copied and owned by the
/// main thread. The agent thread converts AgentEvent → UiEvent before
/// pushing to the EventQueue, ensuring no borrowed pointers cross
/// the thread boundary.
pub const UiEvent = union(enum) {
    // --- message lifecycle ---
    message_start_assistant: void,
    message_start_user: void,

    // --- streaming content ---
    text_delta: struct { delta: []u8 },

    // --- errors ---
    error_message: struct { message: []u8 },

    // --- tool call streaming (from assistant message content, before execution) ---
    tool_call_streaming: struct {
        tool_call_id: []u8,
        tool_name: []u8,
        args: std.json.Value,
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

    // --- agent lifecycle ---
    agent_finished: void,
    agent_error: void,

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
            .message_start_assistant, .message_start_user,
            .agent_finished, .agent_error,
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
