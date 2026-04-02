const std = @import("std");
const ai = @import("ai");
const protocol = @import("protocol.zig");

/// Run a single-turn agent loop. No tools. No steering. No follow-ups.
/// This is the minimal viable loop for `zi -p "hello"`.
///
/// Matches pi-mono's runAgentLoop event ordering for the simple case:
/// agent_start → turn_start → message_start(user) → message_end(user) →
/// message_start(assistant) → message_update* → message_end(assistant) →
/// turn_end → agent_end
pub fn runSingleTurn(
    allocator: std.mem.Allocator,
    provider_registry: *const ai.provider.Registry,
    model: ai.protocol.Model,
    context: protocol.AgentContext,
    options: ai.protocol.StreamOptions,
    event_sink: protocol.AgentEventSink,
    event_ctx: ?*anyopaque,
) void {
    // 1. agent_start
    event_sink(.agent_start, event_ctx);

    // 2. turn_start
    event_sink(.turn_start, event_ctx);

    // 3. Emit message_start/end for each user message in context
    for (context.messages) |msg| {
        event_sink(.{ .message_start = .{ .message = msg } }, event_ctx);
        event_sink(.{ .message_end = .{ .message = msg } }, event_ctx);
    }

    // 4. Look up provider
    const api_str = ai.provider.apiToString(model.api);
    const prov = provider_registry.get(api_str) orelse {
        const err_msg = makeErrorAssistantMessage(model, "No provider registered for API");
        event_sink(.{ .message_start = .{ .message = .{ .assistant = err_msg } } }, event_ctx);
        event_sink(.{ .message_end = .{ .message = .{ .assistant = err_msg } } }, event_ctx);
        event_sink(.{ .turn_end = .{ .message = .{ .assistant = err_msg }, .tool_results = &.{} } }, event_ctx);
        event_sink(.{ .agent_end = .{ .messages = &.{} } }, event_ctx);
        return;
    };

    // 5. Build LLM context from agent context
    var llm_messages: std.ArrayListUnmanaged(ai.protocol.Message) = .{};
    defer llm_messages.deinit(allocator);
    for (context.messages) |agent_msg| {
        switch (agent_msg) {
            .user => |u| llm_messages.append(allocator, .{ .user = u }) catch continue,
            .assistant => |a| llm_messages.append(allocator, .{ .assistant = a }) catch continue,
            .tool_result => |t| llm_messages.append(allocator, .{ .tool_result = t }) catch continue,
            .custom => continue,
        }
    }

    const llm_context = ai.protocol.Context{
        .system_prompt = if (context.system_prompt.len > 0) context.system_prompt else null,
        .messages = llm_messages.items,
        .tools = null,
    };

    // 6. Stream — use a wrapper struct to bridge provider callback → agent events
    const StreamBridge = struct {
        sink: protocol.AgentEventSink,
        sink_ctx: ?*anyopaque,
        final_message: ?ai.protocol.AssistantMessage = null,
        started: bool = false,

        fn callback(event: ai.protocol.AssistantMessageEvent, ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));

            if (!self.started) {
                self.started = true;
                switch (event) {
                    .start => |s| {
                        self.sink(.{ .message_start = .{ .message = .{ .assistant = s.partial } } }, self.sink_ctx);
                    },
                    else => {},
                }
            }

            switch (event) {
                .done => |d| {
                    self.final_message = d.message;
                    self.sink(.{ .message_update = .{ .message = .{ .assistant = d.message }, .assistant_message_event = event } }, self.sink_ctx);
                },
                .@"error" => |e| {
                    self.final_message = e.@"error";
                    self.sink(.{ .message_update = .{ .message = .{ .assistant = e.@"error" }, .assistant_message_event = event } }, self.sink_ctx);
                },
                else => {
                    const partial = extractPartial(event);
                    if (partial) |p| {
                        self.sink(.{ .message_update = .{ .message = .{ .assistant = p }, .assistant_message_event = event } }, self.sink_ctx);
                    }
                },
            }
        }

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
    };

    var bridge = StreamBridge{
        .sink = event_sink,
        .sink_ctx = event_ctx,
    };

    prov.stream(allocator, model, llm_context, options, &StreamBridge.callback, @ptrCast(&bridge));

    // 7. Emit message_end for assistant
    if (bridge.final_message) |final| {
        const agent_msg = protocol.AgentMessage{ .assistant = final };
        event_sink(.{ .message_end = .{ .message = agent_msg } }, event_ctx);
        event_sink(.{ .turn_end = .{ .message = agent_msg, .tool_results = &.{} } }, event_ctx);
        event_sink(.{ .agent_end = .{ .messages = &.{} } }, event_ctx);
    } else {
        event_sink(.{ .agent_end = .{ .messages = &.{} } }, event_ctx);
    }
}

fn makeErrorAssistantMessage(model: ai.protocol.Model, error_message: []const u8) ai.protocol.AssistantMessage {
    return .{
        .content = &.{},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = .{
            .input = 0,
            .output = 0,
            .cache_read = 0,
            .cache_write = 0,
            .total_tokens = 0,
            .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 },
        },
        .stop_reason = .@"error",
        .error_message = error_message,
        .timestamp = std.time.milliTimestamp(),
    };
}
