const std = @import("std");
const ai = @import("../ai/root.zig");
const protocol = @import("protocol.zig");
const json_util = @import("../ai/json_util.zig");

/// Start an agent loop with new prompt messages.
/// Prompts are added to the context and events are emitted for them.
///
/// Matches pi-mono's runAgentLoop (agent-loop.ts:95-118).
pub fn runAgentLoop(
    allocator: std.mem.Allocator,
    prompts: []const protocol.AgentMessage,
    context: protocol.AgentContext,
    config: protocol.AgentLoopConfig,
    event_sink: protocol.AgentEventSink,
    event_ctx: ?*anyopaque,
    signal: ?*anyopaque,
) void {
    // newMessages tracks only messages created during this run
    var new_messages: std.ArrayListUnmanaged(protocol.AgentMessage) = .empty;
    for (prompts) |p| {
        new_messages.append(allocator, p) catch return;
    }

    // Working context = existing messages + prompts
    var ctx_messages: std.ArrayListUnmanaged(protocol.AgentMessage) = .empty;
    for (context.messages) |m| {
        ctx_messages.append(allocator, m) catch return;
    }
    for (prompts) |p| {
        ctx_messages.append(allocator, p) catch return;
    }

    event_sink(.agent_start, event_ctx);
    event_sink(.turn_start, event_ctx);

    // Emit message_start/end for prompt messages
    for (prompts) |p| {
        event_sink(.{ .message_start = .{ .message = p } }, event_ctx);
        event_sink(.{ .message_end = .{ .message = p } }, event_ctx);
    }

    runLoop(allocator, &ctx_messages, &new_messages, context, config, signal, event_sink, event_ctx);
}

/// Continue an agent loop from existing context without adding a new message.
/// Used for retries — context already has user message or tool results.
///
/// Matches pi-mono's runAgentLoopContinue (agent-loop.ts:120-143).
pub const ContinueError = error{
    EmptyContext,
    AssistantTail,
};

pub fn runAgentLoopContinue(
    allocator: std.mem.Allocator,
    context: protocol.AgentContext,
    config: protocol.AgentLoopConfig,
    event_sink: protocol.AgentEventSink,
    event_ctx: ?*anyopaque,
    signal: ?*anyopaque,
) ContinueError!void {
    if (context.messages.len == 0) {
        return error.EmptyContext;
    }

    const last = context.messages[context.messages.len - 1];
    if (last == .assistant) {
        return error.AssistantTail;
    }

    var new_messages: std.ArrayListUnmanaged(protocol.AgentMessage) = .empty;
    var ctx_messages: std.ArrayListUnmanaged(protocol.AgentMessage) = .empty;
    for (context.messages) |m| {
        ctx_messages.append(allocator, m) catch return;
    }

    event_sink(.agent_start, event_ctx);
    event_sink(.turn_start, event_ctx);

    // No message_start/end for existing messages — that's the key difference from runAgentLoop

    runLoop(allocator, &ctx_messages, &new_messages, context, config, signal, event_sink, event_ctx);
}

/// Main loop logic shared by runAgentLoop and runAgentLoopContinue.
/// Implements pi-mono's dual loop (agent-loop.ts:155-232):
///   outer loop: continues when follow-up messages arrive after agent would stop
///   inner loop: processes tool calls and steering messages
fn runLoop(
    allocator: std.mem.Allocator,
    ctx_messages: *std.ArrayListUnmanaged(protocol.AgentMessage),
    new_messages: *std.ArrayListUnmanaged(protocol.AgentMessage),
    context: protocol.AgentContext,
    config: protocol.AgentLoopConfig,
    signal: ?*anyopaque,
    event_sink: protocol.AgentEventSink,
    event_ctx: ?*anyopaque,
) void {
    var first_turn = true;

    // Convert AgentTools to LLM Tools once
    var llm_tools: std.ArrayListUnmanaged(ai.protocol.Tool) = .empty;
    if (context.tools) |tools| {
        for (tools) |t| {
            llm_tools.append(allocator, .{
                .name = t.name,
                .description = t.description,
                .parameters = t.parameters,
            }) catch continue;
        }
    }

    // Initial steering poll (pi-mono agent-loop.ts:165)
    // Skip when continue() already drained one steering message (skipInitialSteeringPoll).
    var pending_messages = if (config.skip_initial_steering_poll)
        @as([]const protocol.AgentMessage, &.{})
    else if (config.get_steering_messages) |hook|
        hook.call(allocator)
    else
        @as([]const protocol.AgentMessage, &.{});

    // Outer loop: continues when follow-up messages arrive
    outer: while (true) {
        var has_more_tool_calls = true;

        // Inner loop: process tool calls and steering messages
        while (has_more_tool_calls or pending_messages.len > 0) {
            if (!first_turn) {
                event_sink(.turn_start, event_ctx);
            } else {
                first_turn = false;
            }

            // Inject pending messages before next assistant response
            if (pending_messages.len > 0) {
                for (pending_messages) |msg| {
                    event_sink(.{ .message_start = .{ .message = msg } }, event_ctx);
                    event_sink(.{ .message_end = .{ .message = msg } }, event_ctx);
                    ctx_messages.append(allocator, msg) catch {};
                    new_messages.append(allocator, msg) catch {};
                }
                pending_messages = &.{};
            }

            // Stream assistant response
            const assistant_msg = streamAssistantResponse(allocator, ctx_messages, config, signal, event_sink, event_ctx, llm_tools.items, context.system_prompt) orelse {
                event_sink(.{ .agent_end = .{ .messages = new_messages.items } }, event_ctx);
                return;
            };

            new_messages.append(allocator, .{ .assistant = assistant_msg }) catch {};

            if (assistant_msg.stop_reason == .@"error" or assistant_msg.stop_reason == .aborted) {
                event_sink(.{ .turn_end = .{
                    .message = .{ .assistant = assistant_msg },
                    .tool_results = &.{},
                } }, event_ctx);
                event_sink(.{ .agent_end = .{ .messages = new_messages.items } }, event_ctx);
                return;
            }

            // Check for tool calls
            var tool_call_count: usize = 0;
            for (assistant_msg.content) |block| {
                switch (block) {
                    .tool_call => tool_call_count += 1,
                    else => {},
                }
            }
            has_more_tool_calls = tool_call_count > 0;

            var tool_results: std.ArrayListUnmanaged(ai.protocol.ToolResultMessage) = .empty;
            if (has_more_tool_calls) {
                executeToolCalls(allocator, ctx_messages, new_messages, &tool_results, assistant_msg, context.tools orelse &.{}, config, context.system_prompt, signal, event_sink, event_ctx);
            }

            event_sink(.{ .turn_end = .{
                .message = .{ .assistant = assistant_msg },
                .tool_results = tool_results.items,
            } }, event_ctx);

            // Poll steering messages after tool execution
            pending_messages = if (config.get_steering_messages) |hook|
                hook.call(allocator)
            else
                @as([]const protocol.AgentMessage, &.{});
        }

        // Agent would stop here. Check for follow-up messages.
        const follow_ups = if (config.get_follow_up_messages) |hook|
            hook.call(allocator)
        else
            @as([]const protocol.AgentMessage, &.{});

        if (follow_ups.len > 0) {
            pending_messages = follow_ups;
            continue :outer;
        }

        break;
    }

    event_sink(.{ .agent_end = .{ .messages = new_messages.items } }, event_ctx);
}

/// Stream an assistant response from the LLM.
/// Applies transformContext → convertToLlm pipeline before calling the stream function.
/// Matches pi-mono's streamAssistantResponse (agent-loop.ts:238-331).
fn streamAssistantResponse(
    aa: std.mem.Allocator,
    ctx_messages: *std.ArrayListUnmanaged(protocol.AgentMessage),
    config: protocol.AgentLoopConfig,
    signal: ?*anyopaque,
    event_sink: protocol.AgentEventSink,
    event_ctx: ?*anyopaque,
    llm_tools: []const ai.protocol.Tool,
    system_prompt: []const u8,
) ?ai.protocol.AssistantMessage {
    // Apply context transform if configured (AgentMessage[] → AgentMessage[])
    var messages: []const protocol.AgentMessage = ctx_messages.items;
    if (config.transform_context) |hook| {
        messages = hook.call(aa, messages, signal);
    }

    // Convert to LLM messages (AgentMessage[] → Message[])
    const llm_messages = config.convert_to_llm.call(aa, messages);

    const llm_context = ai.protocol.Context{
        .system_prompt = if (system_prompt.len > 0) system_prompt else null,
        .messages = llm_messages,
        .tools = if (llm_tools.len > 0) llm_tools else null,
    };

    var stream_options = config.buildStreamOptions();
    stream_options.base.signal = signal;

    // Resolve API key dynamically (pi-mono agent-loop.ts:264-265)
    if (config.get_api_key) |hook| {
        const provider_str = json_util.providerToString(config.model.provider);
        if (hook.call(provider_str)) |resolved_key| {
            stream_options.base.api_key = resolved_key;
        }
    }

    var bridge = StreamBridge{
        .sink = event_sink,
        .sink_ctx = event_ctx,
    };
    config.stream.call(aa, config.model, llm_context, stream_options, &StreamBridge.callback, @ptrCast(&bridge));

    const assistant_msg = bridge.final_message orelse return null;

    // Add to context (pi-mono: context.messages.push or replace last)
    ctx_messages.append(aa, .{ .assistant = assistant_msg }) catch {};

    return assistant_msg;
}

/// Bridge for streaming tool execution updates to the event sink.
/// Passed as opaque context to AgentToolUpdateCallback.
const UpdateBridge = struct {
    sink: protocol.AgentEventSink,
    sink_ctx: ?*anyopaque,
    tool_call_id: []const u8,
    tool_name: []const u8,
    args: std.json.Value,

    fn callback(partial_result: protocol.AgentToolResult, ctx: ?*anyopaque) void {
        const self: *const UpdateBridge = @ptrCast(@alignCast(ctx));
        self.sink(.{ .tool_execution_update = .{
            .tool_call_id = self.tool_call_id,
            .tool_name = self.tool_name,
            .args = self.args,
            .partial_result = partial_result,
        } }, self.sink_ctx);
    }
};

/// Execute tool calls sequentially using the 3-phase pipeline:
///   prepareToolCall → executePreparedToolCall → finalizeExecutedToolCall
/// Matches pi-mono's agent-loop.ts:350-388 (sequential) calling 458-595 (phases).
fn executeToolCalls(
    aa: std.mem.Allocator,
    ctx_messages: *std.ArrayListUnmanaged(protocol.AgentMessage),
    new_messages: *std.ArrayListUnmanaged(protocol.AgentMessage),
    tool_results: *std.ArrayListUnmanaged(ai.protocol.ToolResultMessage),
    assistant_msg: ai.protocol.AssistantMessage,
    tools: []const protocol.AgentTool,
    config: protocol.AgentLoopConfig,
    system_prompt: []const u8,
    signal: ?*anyopaque,
    event_sink: protocol.AgentEventSink,
    event_ctx: ?*anyopaque,
) void {
    for (assistant_msg.content) |block| {
        switch (block) {
            .tool_call => |tc| {
                // --- Phase 1: prepareToolCall (pi-mono agent-loop.ts:472-522) ---

                event_sink(.{ .tool_execution_start = .{
                    .tool_call_id = tc.id,
                    .tool_name = tc.name,
                    .args = tc.arguments,
                } }, event_ctx);

                const tool = findTool(tools, tc.name);
                if (tool == null) {
                    const err_msg = std.fmt.allocPrint(aa, "Tool {s} not found", .{tc.name}) catch "Tool not found";
                    emitImmediateError(aa, ctx_messages, new_messages, tool_results, tc, err_msg, event_sink, event_ctx);
                    continue;
                }

                const t = tool.?;

                // prepare_arguments: optional arg transform before execution
                const prepared_args = if (t.prepare_arguments) |prep_fn|
                    prep_fn(tc.arguments)
                else
                    tc.arguments;

                // beforeToolCall hook: can block execution
                if (config.before_tool_call) |hook| {
                    const hook_ctx = protocol.BeforeToolCallContext{
                        .assistant_message = assistant_msg,
                        .tool_call = tc,
                        .args = prepared_args,
                        .context = .{
                            .system_prompt = system_prompt,
                            .messages = ctx_messages.items,
                            .tools = if (tools.len > 0) tools else null,
                        },
                    };
                    if (hook.call(hook_ctx, signal)) |before_result| {
                        if (before_result.block) {
                            const reason = before_result.reason orelse "Tool execution was blocked";
                            emitImmediateError(aa, ctx_messages, new_messages, tool_results, tc, reason, event_sink, event_ctx);
                            continue;
                        }
                    }
                }

                // --- Phase 2: executePreparedToolCall (pi-mono agent-loop.ts:524-559) ---

                var update_bridge = UpdateBridge{
                    .sink = event_sink,
                    .sink_ctx = event_ctx,
                    .tool_call_id = tc.id,
                    .tool_name = tc.name,
                    .args = tc.arguments,
                };

                const result = t.execute(
                    t.ctx,
                    aa,
                    tc.id,
                    prepared_args,
                    signal,
                    &UpdateBridge.callback,
                    @ptrCast(&update_bridge),
                );

                // --- Phase 3: finalizeExecutedToolCall (pi-mono agent-loop.ts:561-595) ---

                var final_content = result.content;
                var final_details = result.details;
                var final_is_error = result.is_error;

                if (config.after_tool_call) |hook| {
                    const hook_ctx = protocol.AfterToolCallContext{
                        .assistant_message = assistant_msg,
                        .tool_call = tc,
                        .args = prepared_args,
                        .result = result,
                        .is_error = result.is_error,
                        .context = .{
                            .system_prompt = system_prompt,
                            .messages = ctx_messages.items,
                            .tools = if (tools.len > 0) tools else null,
                        },
                    };
                    if (hook.call(hook_ctx, signal)) |after_result| {
                        if (after_result.content) |c| final_content = c;
                        if (after_result.details) |d| final_details = d;
                        if (after_result.is_error) |e| final_is_error = e;
                    }
                }

                // Build final AgentToolResult and ToolResultMessage
                const final_agent_result = protocol.AgentToolResult{
                    .content = final_content,
                    .details = final_details,
                    .is_error = final_is_error,
                };

                var trm_content: std.ArrayListUnmanaged(ai.protocol.ToolResultMessage.ContentBlock) = .empty;
                for (final_content) |cb| {
                    switch (cb) {
                        .text => |txt| trm_content.append(aa, .{ .text = txt }) catch continue,
                        .image => |img| trm_content.append(aa, .{ .image = img }) catch continue,
                    }
                }

                const tool_result_msg = ai.protocol.ToolResultMessage{
                    .tool_call_id = tc.id,
                    .tool_name = tc.name,
                    .content = trm_content.items,
                    .details = final_details,
                    .is_error = final_is_error,
                    .timestamp = std.time.milliTimestamp(),
                };

                emitToolResult(event_sink, event_ctx, tc, tool_result_msg, final_is_error, final_agent_result);
                ctx_messages.append(aa, .{ .tool_result = tool_result_msg }) catch {};
                new_messages.append(aa, .{ .tool_result = tool_result_msg }) catch {};
                tool_results.append(aa, tool_result_msg) catch {};
            },
            else => {},
        }
    }
}

/// Emit an immediate error result for a tool call that failed during preparation.
/// Covers: tool not found, beforeToolCall blocked, arg preparation failure.
fn emitImmediateError(
    aa: std.mem.Allocator,
    ctx_messages: *std.ArrayListUnmanaged(protocol.AgentMessage),
    new_messages: *std.ArrayListUnmanaged(protocol.AgentMessage),
    tool_results: *std.ArrayListUnmanaged(ai.protocol.ToolResultMessage),
    tc: ai.protocol.ToolCall,
    msg: []const u8,
    event_sink: protocol.AgentEventSink,
    event_ctx: ?*anyopaque,
) void {
    const err_content_buf = aa.alloc(protocol.AgentToolResult.ContentBlock, 1) catch @as([]protocol.AgentToolResult.ContentBlock, &.{});
    if (err_content_buf.len > 0) {
        err_content_buf[0] = .{ .text = .{ .text = msg } };
    }
    const err_tool_result = protocol.AgentToolResult{ .content = err_content_buf, .is_error = true, .details = .{ .object = std.json.ObjectMap.init(aa) } };
    const err_result = makeErrorToolResult(aa, tc.id, tc.name, msg);
    emitToolResult(event_sink, event_ctx, tc, err_result, true, err_tool_result);
    ctx_messages.append(aa, .{ .tool_result = err_result }) catch {};
    new_messages.append(aa, .{ .tool_result = err_result }) catch {};
    tool_results.append(aa, err_result) catch {};
}

fn emitToolResult(
    event_sink: protocol.AgentEventSink,
    event_ctx: ?*anyopaque,
    tc: ai.protocol.ToolCall,
    result: ai.protocol.ToolResultMessage,
    is_error: bool,
    tool_result: protocol.AgentToolResult,
) void {
    event_sink(.{ .tool_execution_end = .{
        .tool_call_id = tc.id,
        .tool_name = tc.name,
        .result = tool_result,
        .is_error = is_error,
    } }, event_ctx);

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
        .details = .{ .object = std.json.ObjectMap.init(allocator) },
        .is_error = true,
        .timestamp = std.time.milliTimestamp(),
    };
    content[0] = .{ .text = .{ .text = msg } };
    return .{
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .content = content,
        .details = .{ .object = std.json.ObjectMap.init(allocator) },
        .is_error = true,
        .timestamp = std.time.milliTimestamp(),
    };
}

/// Bridge between provider events and agent events.
/// Translates AssistantMessageEvent → AgentEvent.
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

