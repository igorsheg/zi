const std = @import("std");
const ai = @import("../ai/root.zig");
const protocol = @import("types.zig");
const message_memory = @import("message_memory.zig");

pub const StreamBridge = struct {
    sink: protocol.AgentEventSink,
    sink_ctx: ?*anyopaque,
    owned_allocator: std.mem.Allocator,
    final_message: ?ai.protocol.AssistantMessage = null,
    added_partial: bool = false,

    pub fn callback(event: ai.protocol.AssistantMessageEvent, ctx: ?*anyopaque) void {
        const self: *StreamBridge = @ptrCast(@alignCast(ctx));

        switch (event) {
            .start => |s| {
                self.added_partial = true;
                self.sink(.{ .message_start = .{ .message = .{ .assistant = s.partial } } }, self.sink_ctx);
            },
            .done => |d| {
                const owned = message_memory.cloneAssistantMessage(self.owned_allocator, d.message) catch d.message;
                self.final_message = owned;
                if (!self.added_partial) {
                    self.sink(.{ .message_start = .{ .message = .{ .assistant = owned } } }, self.sink_ctx);
                }
                self.sink(.{ .message_end = .{ .message = .{ .assistant = owned } } }, self.sink_ctx);
            },
            .@"error" => |e| {
                const owned = message_memory.cloneAssistantMessage(self.owned_allocator, e.@"error") catch e.@"error";
                self.final_message = owned;
                if (!self.added_partial) {
                    self.sink(.{ .message_start = .{ .message = .{ .assistant = owned } } }, self.sink_ctx);
                }
                self.sink(.{ .message_end = .{ .message = .{ .assistant = owned } } }, self.sink_ctx);
            },
            else => {
                if (extractPartial(event)) |partial| {
                    self.sink(.{ .message_update = .{
                        .message = .{ .assistant = partial },
                        .assistant_message_event = event,
                    } }, self.sink_ctx);
                }
            },
        }
    }
};

pub const UpdateBridge = struct {
    sink: protocol.AgentEventSink,
    sink_ctx: ?*anyopaque,
    tool_call_id: []const u8,
    tool_name: []const u8,
    args: std.json.Value,

    pub fn callback(partial_result: protocol.AgentToolResult, ctx: ?*anyopaque) void {
        const self: *const UpdateBridge = @ptrCast(@alignCast(ctx));
        self.sink(.{ .tool_execution_update = .{
            .tool_call_id = self.tool_call_id,
            .tool_name = self.tool_name,
            .args = self.args,
            .partial_result = partial_result,
        } }, self.sink_ctx);
    }
};

fn extractPartial(event: ai.protocol.AssistantMessageEvent) ?ai.protocol.AssistantMessage {
    return switch (event) {
        .start => |s| s.partial,
        .text_start => |s| s.partial,
        .text_delta => |s| s.partial,
        .text_end => |s| s.partial,
        .thinking_start => |s| s.partial,
        .thinking_delta => |s| s.partial,
        .thinking_end => |s| s.partial,
        .toolcall_start => |s| s.partial,
        .toolcall_delta => |s| s.partial,
        .toolcall_end => |s| s.partial,
        .done => |d| d.message,
        .@"error" => |e| e.@"error",
    };
}
