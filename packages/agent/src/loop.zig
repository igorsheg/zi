const std = @import("std");
const ai = @import("ai");
const protocol = @import("protocol.zig");

/// Multi-turn agent loop with sequential tool execution.
/// No steering, no follow-ups — just the inner tool-call loop.
///
/// Matches pi-mono's runLoop (agent-loop.ts:155-232) for the subset:
///   stream → if toolUse → execute tools → add results → stream again → if stop → done
///
/// Event ordering:
///   agent_start → turn_start → [user message_start/end]* →
///   [stream → message_start → message_update* → message_end →
///    [tool_execution_start → tool_execution_end → message_start(result) → message_end(result)]* →
///    turn_end]+ →
///   agent_end
pub fn runAgentLoop(
    allocator: std.mem.Allocator,
    provider_registry: *const ai.provider.Registry,
    model: ai.protocol.Model,
    system_prompt: []const u8,
    initial_messages: []const protocol.AgentMessage,
    tools: []const protocol.AgentTool,
    options: ai.protocol.StreamOptions,
    event_sink: protocol.AgentEventSink,
    event_ctx: ?*anyopaque,
) void {
    // Arena for per-turn allocations: tool result content blocks, error results,
    // LLM message lists. All freed together when the loop exits.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Mutable message list — grows as we add assistant responses and tool results.
    // Uses arena_alloc so tool result content slices (which point into arena memory)
    // stay valid for the loop's lifetime.
    var messages: std.ArrayListUnmanaged(protocol.AgentMessage) = .{};
    defer messages.deinit(arena_alloc);
    for (initial_messages) |msg| {
        messages.append(arena_alloc, msg) catch return;
    }

    // 1. agent_start
    event_sink(.agent_start, event_ctx);

    // 2. turn_start
    event_sink(.turn_start, event_ctx);

    // 3. Emit message_start/end for initial user messages
    for (initial_messages) |msg| {
        event_sink(.{ .message_start = .{ .message = msg } }, event_ctx);
        event_sink(.{ .message_end = .{ .message = msg } }, event_ctx);
    }

    // 4. Look up provider
    const api_str = ai.provider.apiToString(model.api);
    const prov = provider_registry.get(api_str) orelse {
        const err_msg = makeErrorAssistantMessage(model, "No provider registered for API");
        const agent_err = protocol.AgentMessage{ .assistant = err_msg };
        messages.append(arena_alloc, agent_err) catch {};
        event_sink(.{ .message_start = .{ .message = agent_err } }, event_ctx);
        event_sink(.{ .message_end = .{ .message = agent_err } }, event_ctx);
        event_sink(.{ .turn_end = .{ .message = agent_err, .tool_results = &.{} } }, event_ctx);
        event_sink(.{ .agent_end = .{ .messages = messages.items } }, event_ctx);
        return;
    };

    // Convert AgentTools to LLM Tools for the provider
    var llm_tools: std.ArrayListUnmanaged(ai.protocol.Tool) = .{};
    defer llm_tools.deinit(arena_alloc);
    for (tools) |t| {
        llm_tools.append(arena_alloc, .{
            .name = t.name,
            .description = t.description,
            .parameters = t.parameters,
        }) catch continue;
    }

    // 5. Inner loop: stream → tool calls → repeat
    var first_turn = true;
    while (true) {
        if (!first_turn) {
            event_sink(.turn_start, event_ctx);
        }
        first_turn = false;

        // Build LLM context from current messages
        var llm_messages: std.ArrayListUnmanaged(ai.protocol.Message) = .{};
        defer llm_messages.deinit(arena_alloc);
        for (messages.items) |agent_msg| {
            switch (agent_msg) {
                .user => |u| llm_messages.append(arena_alloc, .{ .user = u }) catch continue,
                .assistant => |a| llm_messages.append(arena_alloc, .{ .assistant = a }) catch continue,
                .tool_result => |t| llm_messages.append(arena_alloc, .{ .tool_result = t }) catch continue,
                .compaction_summary, .branch_summary, .custom => continue,
            }
        }

        const llm_context = ai.protocol.Context{
            .system_prompt = if (system_prompt.len > 0) system_prompt else null,
            .messages = llm_messages.items,
            .tools = if (llm_tools.items.len > 0) llm_tools.items else null,
        };

        // Stream assistant response
        var bridge = StreamBridge{
            .sink = event_sink,
            .sink_ctx = event_ctx,
        };
        prov.stream(arena_alloc, model, llm_context, options, &StreamBridge.callback, @ptrCast(&bridge));

        const assistant_msg = bridge.final_message orelse {
            // No response at all — emit agent_end and bail
            event_sink(.{ .agent_end = .{ .messages = messages.items } }, event_ctx);
            return;
        };

        // Add assistant message to context
        messages.append(arena_alloc, .{ .assistant = assistant_msg }) catch {};

        // Check for error/aborted
        if (assistant_msg.stop_reason == .@"error" or assistant_msg.stop_reason == .aborted) {
            event_sink(.{ .turn_end = .{
                .message = .{ .assistant = assistant_msg },
                .tool_results = &.{},
            } }, event_ctx);
            event_sink(.{ .agent_end = .{ .messages = messages.items } }, event_ctx);
            return;
        }

        // Extract tool calls from assistant message content
        var tool_call_count: usize = 0;
        for (assistant_msg.content) |block| {
            switch (block) {
                .tool_call => tool_call_count += 1,
                else => {},
            }
        }

        if (tool_call_count == 0) {
            // No tool calls — we're done
            event_sink(.{ .turn_end = .{
                .message = .{ .assistant = assistant_msg },
                .tool_results = &.{},
            } }, event_ctx);
            break;
        }

        // Execute tool calls sequentially
        var tool_results: std.ArrayListUnmanaged(ai.protocol.ToolResultMessage) = .{};
        defer tool_results.deinit(arena_alloc);

        for (assistant_msg.content) |block| {
            switch (block) {
                .tool_call => |tc| {
                    // Emit tool_execution_start
                    event_sink(.{ .tool_execution_start = .{
                        .tool_call_id = tc.id,
                        .tool_name = tc.name,
                        .args = tc.arguments,
                    } }, event_ctx);

                    // Find tool — pi-mono: prepareToolCall (agent-loop.ts:472-522)
                    const tool = findTool(tools, tc.name);
                    if (tool == null) {
                        const err_result = makeErrorToolResult(arena_alloc, tc.id, tc.name, "tool not found");
                        emitToolResult(event_sink, event_ctx, tc, err_result, true, null);
                        messages.append(arena_alloc, .{ .tool_result = err_result }) catch {};
                        tool_results.append(arena_alloc, err_result) catch {};
                        continue;
                    }

                    // Execute tool — pi-mono: executePreparedToolCall (agent-loop.ts:524-559)
                    const t = tool.?;
                    const result = t.execute(
                        t.ctx,
                        arena_alloc,
                        tc.id,
                        tc.arguments,
                        null, // signal
                        null, // on_update
                        null, // update_ctx
                    );

                    // Build ToolResultMessage — pi-mono: emitToolCallOutcome (agent-loop.ts:604-631)
                    // Propagate details and detect error from tool result content
                    var trm_content: std.ArrayListUnmanaged(ai.protocol.ToolResultMessage.ContentBlock) = .{};
                    for (result.content) |cb| {
                        switch (cb) {
                            .text => |txt| trm_content.append(arena_alloc, .{ .text = txt }) catch continue,
                            .image => |img| trm_content.append(arena_alloc, .{ .image = img }) catch continue,
                        }
                    }

                    const tool_result_msg = ai.protocol.ToolResultMessage{
                        .tool_call_id = tc.id,
                        .tool_name = tc.name,
                        .content = trm_content.items,
                        .details = result.details,
                        .is_error = result.is_error,
                        .timestamp = std.time.milliTimestamp(),
                    };

                    emitToolResult(event_sink, event_ctx, tc, tool_result_msg, result.is_error, result.details);
                    messages.append(arena_alloc, .{ .tool_result = tool_result_msg }) catch {};
                    tool_results.append(arena_alloc, tool_result_msg) catch {};
                },
                else => {},
            }
        }

        event_sink(.{ .turn_end = .{
            .message = .{ .assistant = assistant_msg },
            .tool_results = tool_results.items,
        } }, event_ctx);
    }

    // 6. agent_end
    event_sink(.{ .agent_end = .{ .messages = messages.items } }, event_ctx);
}

/// Emit tool_execution_end → message_start → message_end for a tool result.
/// Matches pi-mono's emitToolCallOutcome (agent-loop.ts:604-631).
fn emitToolResult(
    event_sink: protocol.AgentEventSink,
    event_ctx: ?*anyopaque,
    tc: ai.protocol.ToolCall,
    result: ai.protocol.ToolResultMessage,
    is_error: bool,
    tool_result_value: ?std.json.Value,
) void {
    // tool_execution_end — pi-mono passes the actual result here
    event_sink(.{ .tool_execution_end = .{
        .tool_call_id = tc.id,
        .tool_name = tc.name,
        .result = tool_result_value,
        .is_error = is_error,
    } }, event_ctx);

    // message_start/end for tool result
    const msg = protocol.AgentMessage{ .tool_result = result };
    event_sink(.{ .message_start = .{ .message = msg } }, event_ctx);
    event_sink(.{ .message_end = .{ .message = msg } }, event_ctx);
}

fn findTool(tools: []const protocol.AgentTool, name: []const u8) ?protocol.AgentTool {
    for (tools) |t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

fn makeErrorToolResult(allocator: std.mem.Allocator, tool_call_id: []const u8, tool_name: []const u8, msg: []const u8) ai.protocol.ToolResultMessage {
    const content = allocator.alloc(ai.protocol.ToolResultMessage.ContentBlock, 1) catch return .{
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .content = &.{},
        .is_error = true,
        .timestamp = std.time.milliTimestamp(),
    };
    content[0] = .{ .text = .{ .text = msg } };
    return .{
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .content = content,
        .is_error = true,
        .timestamp = std.time.milliTimestamp(),
    };
}

/// Bridge between provider events and agent events.
/// Translates AssistantMessageEvent → AgentEvent.
///
/// Event mapping matches pi-mono's streamAssistantResponse (agent-loop.ts:276-320):
///   start        → message_start only (no message_update)
///   content_*    → message_update
///   done/error   → backfill message_start if needed, then message_end (no message_update)
const StreamBridge = struct {
    sink: protocol.AgentEventSink,
    sink_ctx: ?*anyopaque,
    final_message: ?ai.protocol.AssistantMessage = null,
    added_partial: bool = false,

    fn callback(event: ai.protocol.AssistantMessageEvent, ctx: ?*anyopaque) void {
        const self: *StreamBridge = @ptrCast(@alignCast(ctx));

        switch (event) {
            .start => |s| {
                self.added_partial = true;
                self.sink(.{ .message_start = .{ .message = .{ .assistant = s.partial } } }, self.sink_ctx);
            },

            .done => |d| {
                self.final_message = d.message;
                if (!self.added_partial) {
                    self.sink(.{ .message_start = .{ .message = .{ .assistant = d.message } } }, self.sink_ctx);
                }
                self.sink(.{ .message_end = .{ .message = .{ .assistant = d.message } } }, self.sink_ctx);
            },

            .@"error" => |e| {
                self.final_message = e.@"error";
                if (!self.added_partial) {
                    self.sink(.{ .message_start = .{ .message = .{ .assistant = e.@"error" } } }, self.sink_ctx);
                }
                self.sink(.{ .message_end = .{ .message = .{ .assistant = e.@"error" } } }, self.sink_ctx);
            },

            // Incremental content events → message_update
            else => |_| {
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
