const std = @import("std");
const ai = @import("../ai/root.zig");
const protocol = @import("types.zig");
const message_memory = @import("message_memory.zig");
const json_value = @import("../json/value.zig");

pub const StreamBridge = struct {
    sink: protocol.AgentEventSink,
    sink_ctx: ?*anyopaque,
    owned_allocator: std.mem.Allocator,
    model: ai.protocol.Model,
    started: bool = false,
    final_message: ?ai.protocol.AssistantMessage = null,

    pub fn callback(event: ai.protocol.AssistantMessageEvent, ctx: ?*anyopaque) void {
        const self: *StreamBridge = @ptrCast(@alignCast(ctx));

        switch (event) {
            .start => self.emitStart(),
            .done => |d| {
                if (!self.started) self.emitStart();
                const owned = message_memory.cloneAssistantMessage(self.owned_allocator, d.message) catch {
                    self.emitCloneFailure();
                    return;
                };
                self.final_message = owned;
                self.sink(.{ .message_end = .{ .message = .{ .assistant = owned } } }, self.sink_ctx);
            },
            .@"error" => |e| {
                if (!self.started) self.emitStart();
                const owned = message_memory.cloneAssistantMessage(self.owned_allocator, e.@"error") catch {
                    self.emitCloneFailure();
                    return;
                };
                self.final_message = owned;
                self.sink(.{ .message_end = .{ .message = .{ .assistant = owned } } }, self.sink_ctx);
            },
            else => self.sink(.{ .message_delta = .{ .assistant_message_event = event } }, self.sink_ctx),
        }
    }

    fn emitStart(self: *StreamBridge) void {
        if (self.started) return;
        self.started = true;
        self.sink(.{ .message_start = .{ .message = .{ .assistant = .{
            .content = &.{},
            .api = self.model.api,
            .provider = self.model.provider,
            .model = self.model.id,
            .usage = .{
                .input = 0,
                .output = 0,
                .cache_read = 0,
                .cache_write = 0,
                .total_tokens = 0,
                .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 },
            },
            .stop_reason = .stop,
            .timestamp = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds(),
        } } } }, self.sink_ctx);
    }
    fn emitCloneFailure(self: *StreamBridge) void {
        self.sink(.{ .message_end = .{ .message = .{ .assistant = .{
            .content = &.{},
            .api = self.model.api,
            .provider = self.model.provider,
            .model = self.model.id,
            .usage = .{
                .input = 0,
                .output = 0,
                .cache_read = 0,
                .cache_write = 0,
                .total_tokens = 0,
                .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 },
            },
            .stop_reason = .@"error",
            .error_message = "failed to copy assistant stream result",
            .failure = .{ .kind = .fatal },
            .timestamp = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds(),
        } } } }, self.sink_ctx);
    }
};

pub const UpdateBridge = struct {
    sink: protocol.AgentEventSink,
    sink_ctx: ?*anyopaque,
    tool_call_id: []const u8,
    tool_name: []const u8,
    args: json_value.BorrowedValue,

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
