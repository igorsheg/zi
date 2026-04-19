const AbortSignal = @import("../abort_signal.zig").AbortSignal;
const std = @import("std");
const ai = @import("../ai/root.zig");
const protocol = @import("types.zig");
const bridge_mod = @import("stream_bridge.zig");
const json_util = @import("../ai/json_util.zig");
const message_memory = @import("message_memory.zig");

/// Start an agent loop with new prompt messages.
/// Prompts are added to the context and events are emitted for them.
///
/// Matches pi-mono's runAgentLoop (agent-loop.ts:95-118).
pub fn runAgentLoop(
    run_allocator: std.mem.Allocator,
    turn_allocator_parent: std.mem.Allocator,
    prompts: []const protocol.AgentMessage,
    context: protocol.AgentContext,
    config: protocol.AgentLoopConfig,
    event_sink: protocol.AgentEventSink,
    event_ctx: ?*anyopaque,
    signal: AbortSignal,
) void {
    // newMessages tracks only messages created during this run
    var new_messages: std.ArrayListUnmanaged(protocol.AgentMessage) = .empty;
    for (prompts) |p| {
        new_messages.append(run_allocator, p) catch return;
    }

    // Working context = existing messages + prompts
    var ctx_messages: std.ArrayListUnmanaged(protocol.AgentMessage) = .empty;
    for (context.messages) |m| {
        ctx_messages.append(run_allocator, m) catch return;
    }
    for (prompts) |p| {
        ctx_messages.append(run_allocator, p) catch return;
    }

    event_sink(.agent_start, event_ctx);
    event_sink(.turn_start, event_ctx);

    // Emit message_start/end for prompt messages
    for (prompts) |p| {
        event_sink(.{ .message_start = .{ .message = p } }, event_ctx);
        event_sink(.{ .message_end = .{ .message = p } }, event_ctx);
    }

    runLoop(run_allocator, turn_allocator_parent, &ctx_messages, &new_messages, context, config, signal, event_sink, event_ctx);
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
    run_allocator: std.mem.Allocator,
    turn_allocator_parent: std.mem.Allocator,
    context: protocol.AgentContext,
    config: protocol.AgentLoopConfig,
    event_sink: protocol.AgentEventSink,
    event_ctx: ?*anyopaque,
    signal: AbortSignal,
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
        ctx_messages.append(run_allocator, m) catch return;
    }

    event_sink(.agent_start, event_ctx);
    event_sink(.turn_start, event_ctx);

    // No message_start/end for existing messages — that's the key difference from runAgentLoop

    runLoop(run_allocator, turn_allocator_parent, &ctx_messages, &new_messages, context, config, signal, event_sink, event_ctx);
}

/// Main loop logic shared by runAgentLoop and runAgentLoopContinue.
/// Implements pi-mono's dual loop (agent-loop.ts:155-232):
///   outer loop: continues when follow-up messages arrive after agent would stop
///   inner loop: processes tool calls and steering messages
fn runLoop(
    run_allocator: std.mem.Allocator,
    turn_allocator_parent: std.mem.Allocator,
    ctx_messages: *std.ArrayListUnmanaged(protocol.AgentMessage),
    new_messages: *std.ArrayListUnmanaged(protocol.AgentMessage),
    context: protocol.AgentContext,
    config: protocol.AgentLoopConfig,
    signal: AbortSignal,
    event_sink: protocol.AgentEventSink,
    event_ctx: ?*anyopaque,
) void {
    const trace = openTraceFile();
    defer if (trace) |f| f.close();

    var first_turn = true;

    // Convert AgentTools to LLM Tools once
    var llm_tools: std.ArrayListUnmanaged(ai.protocol.Tool) = .empty;
    if (context.tools) |tools| {
        for (tools) |t| {
            llm_tools.append(run_allocator, .{
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
        hook.call(run_allocator)
    else
        @as([]const protocol.AgentMessage, &.{});

    // Outer loop: continues when follow-up messages arrive
    outer: while (true) {
        var has_more_tool_calls = true;

        // Inner loop: process tool calls and steering messages
        while (has_more_tool_calls or pending_messages.len > 0) {
            var turn_arena = std.heap.ArenaAllocator.init(turn_allocator_parent);
            defer turn_arena.deinit();
            const turn_allocator = turn_arena.allocator();

            // Check abort before each turn (catches abort during tool execution)
            if (isAborted(signal)) {
                traceWrite(trace, "EXIT: abort before turn\n", .{});
                event_sink(.{ .agent_end = .{ .messages = new_messages.items } }, event_ctx);
                return;
            }

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
                    ctx_messages.append(run_allocator, msg) catch {};
                    new_messages.append(run_allocator, msg) catch {};
                }
                pending_messages = &.{};
            }

            // Stream assistant response
            traceWrite(trace, "STREAM: start model={s}\n", .{config.model.id});
            const assistant_msg = streamAssistantResponse(run_allocator, turn_allocator, ctx_messages, config, signal, event_sink, event_ctx, llm_tools.items, context.system_prompt) orelse {
                traceWrite(trace, "EXIT: stream returned null (no final message)\n", .{});
                event_sink(.{ .agent_end = .{ .messages = new_messages.items } }, event_ctx);
                return;
            };

            new_messages.append(run_allocator, .{ .assistant = assistant_msg }) catch {};
            traceWrite(trace, "STREAM: done stop_reason={s} content_blocks={d}\n", .{
                @tagName(assistant_msg.stop_reason),
                assistant_msg.content.len,
            });

            if (assistant_msg.stop_reason == .@"error" or assistant_msg.stop_reason == .aborted) {
                traceWrite(trace, "EXIT: stop_reason={s} error={s}\n", .{
                    @tagName(assistant_msg.stop_reason),
                    assistant_msg.error_message orelse "(none)",
                });
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
            traceWrite(trace, "TOOLS: count={d} has_more={}\n", .{ tool_call_count, has_more_tool_calls });

            var tool_results: std.ArrayListUnmanaged(ai.protocol.ToolResultMessage) = .empty;
            if (has_more_tool_calls) {
                executeToolCalls(run_allocator, turn_allocator, ctx_messages, new_messages, &tool_results, assistant_msg, context.tools orelse &.{}, config, context.system_prompt, signal, event_sink, event_ctx);
                traceWrite(trace, "TOOLS: executed results={d}\n", .{tool_results.items.len});

                // Abort during tool execution — emit turn_end before agent_end
                if (isAborted(signal)) {
                    traceWrite(trace, "EXIT: abort during tool execution\n", .{});
                    event_sink(.{ .turn_end = .{
                        .message = .{ .assistant = assistant_msg },
                        .tool_results = tool_results.items,
                    } }, event_ctx);
                    event_sink(.{ .agent_end = .{ .messages = new_messages.items } }, event_ctx);
                    return;
                }
            }

            event_sink(.{ .turn_end = .{
                .message = .{ .assistant = assistant_msg },
                .tool_results = tool_results.items,
            } }, event_ctx);

            // Poll steering messages after tool execution
            pending_messages = if (config.get_steering_messages) |hook|
                hook.call(run_allocator)
            else
                @as([]const protocol.AgentMessage, &.{});
            traceWrite(trace, "STEERING: pending={d}\n", .{pending_messages.len});
        }

        // Agent would stop here. Check for follow-up messages.
        const follow_ups = if (config.get_follow_up_messages) |hook|
            hook.call(run_allocator)
        else
            @as([]const protocol.AgentMessage, &.{});

        traceWrite(trace, "FOLLOW_UP: count={d}\n", .{follow_ups.len});
        if (follow_ups.len > 0) {
            pending_messages = follow_ups;
            continue :outer;
        }

        break;
    }

    traceWrite(trace, "EXIT: normal (no more tool calls, no follow-ups)\n", .{});
    event_sink(.{ .agent_end = .{ .messages = new_messages.items } }, event_ctx);
}

/// Stream an assistant response from the LLM.
/// Applies transformContext → convertToLlm pipeline before calling the stream function.
/// Matches pi-mono's streamAssistantResponse (agent-loop.ts:238-331).
fn streamAssistantResponse(
    run_allocator: std.mem.Allocator,
    turn_allocator: std.mem.Allocator,
    ctx_messages: *std.ArrayListUnmanaged(protocol.AgentMessage),
    config: protocol.AgentLoopConfig,
    signal: AbortSignal,
    event_sink: protocol.AgentEventSink,
    event_ctx: ?*anyopaque,
    llm_tools: []const ai.protocol.Tool,
    system_prompt: []const u8,
) ?ai.protocol.AssistantMessage {
    // Apply context transform if configured (AgentMessage[] → AgentMessage[])
    var messages: []const protocol.AgentMessage = ctx_messages.items;
    if (config.transform_context) |hook| {
        messages = hook.call(turn_allocator, messages, signal);
    }

    // Convert to LLM messages (AgentMessage[] → Message[])
    const llm_messages = config.convert_to_llm.call(turn_allocator, messages);

    const llm_context = ai.protocol.Context{
        .system_prompt = if (system_prompt.len > 0) system_prompt else null,
        .messages = llm_messages,
        .tools = if (llm_tools.len > 0) llm_tools else null,
    };

    var stream_options = config.buildStreamOptions();
    stream_options.base.signal = signal;

    // Resolve API key dynamically (pi-mono agent-loop.ts:264-265)
    // JS `||` treats empty string as falsy, so we must check len > 0.
    //
    // zi-wub.27: dupe into the loop arena immediately. The slice
    // returned by the hook is BORROWED from AuthStorage's internal
    // map; AuthStorage.set() from the login thread can reallocate
    // or free that slice during the upcoming stream call. The
    // stream call can take many seconds, well long enough for a
    // login to land mid-flight. Owning the copy on `aa` removes
    // the lifetime hazard at the cost of one alloc per turn.
    if (config.get_api_key) |hook| {
        const provider_str = json_util.providerToString(config.model.provider);
        const resolved_key = hook.call(provider_str);
        if (resolved_key != null and resolved_key.?.len > 0) {
            const owned = turn_allocator.dupe(u8, resolved_key.?) catch resolved_key.?;
            stream_options.base.api_key = owned;
        }
    }

    var bridge = bridge_mod.StreamBridge{
        .sink = event_sink,
        .sink_ctx = event_ctx,
        .owned_allocator = run_allocator,
    };
    config.stream.call(turn_allocator, config.model, llm_context, stream_options, &bridge_mod.StreamBridge.callback, @ptrCast(&bridge));

    const assistant_msg = bridge.final_message orelse return null;

    // Add to context (pi-mono: context.messages.push or replace last)
    ctx_messages.append(run_allocator, .{ .assistant = assistant_msg }) catch {};

    return assistant_msg;
}

/// Emit a synthetic tool_execution_end for a tool that was started but not
/// finished due to abort. Ensures balanced start/end lifecycle events.
fn emitAbortedToolEnd(
    event_sink: protocol.AgentEventSink,
    event_ctx: ?*anyopaque,
    tc: ai.protocol.ToolCall,
    aa: std.mem.Allocator,
) void {
    event_sink(.{ .tool_execution_end = .{
        .tool_call_id = tc.id,
        .tool_name = tc.name,
        .result = makeAgentToolTextResult(aa, "aborted", true),
        .is_error = true,
    } }, event_ctx);
}

/// Execute tool calls sequentially using the 3-phase pipeline:
///   prepareToolCall → executePreparedToolCall → finalizeExecutedToolCall
/// Matches pi-mono's agent-loop.ts:350-388 (sequential) calling 458-595 (phases).
fn executeToolCalls(
    run_allocator: std.mem.Allocator,
    turn_allocator: std.mem.Allocator,
    ctx_messages: *std.ArrayListUnmanaged(protocol.AgentMessage),
    new_messages: *std.ArrayListUnmanaged(protocol.AgentMessage),
    tool_results: *std.ArrayListUnmanaged(ai.protocol.ToolResultMessage),
    assistant_msg: ai.protocol.AssistantMessage,
    tools: []const protocol.AgentTool,
    config: protocol.AgentLoopConfig,
    system_prompt: []const u8,
    signal: AbortSignal,
    event_sink: protocol.AgentEventSink,
    event_ctx: ?*anyopaque,
) void {
    var started_current = false;
    var current_tc: ?ai.protocol.ToolCall = null;
    for (assistant_msg.content) |block| {
        switch (block) {
            .tool_call => |tc| {
                // Check abort between tool calls — previous tool already got its end event
                if (isAborted(signal)) return;

                // --- Phase 1: prepareToolCall (pi-mono agent-loop.ts:472-522) ---

                event_sink(.{ .tool_execution_start = .{
                    .tool_call_id = tc.id,
                    .tool_name = tc.name,
                    .args = tc.arguments,
                } }, event_ctx);
                current_tc = tc;
                started_current = true;

                const tool = findTool(tools, tc.name);
                if (tool == null) {
                    const err_msg = std.fmt.allocPrint(turn_allocator, "Tool {s} not found", .{tc.name}) catch "Tool not found";
                    emitImmediateError(run_allocator, turn_allocator, ctx_messages, new_messages, tool_results, tc, err_msg, event_sink, event_ctx);
                    started_current = false;
                    current_tc = null;
                    continue;
                }

                const t = tool.?;

                // prepare_arguments: optional arg transform before hooks and execution
                const prepared_args = if (t.prepare_arguments) |prep_fn|
                    prep_fn(turn_allocator, tc.arguments) catch |err| {
                        const err_msg = std.fmt.allocPrint(turn_allocator, "Tool {s} argument preparation failed: {s}", .{ tc.name, @errorName(err) }) catch "Tool argument preparation failed";
                        emitImmediateError(run_allocator, turn_allocator, ctx_messages, new_messages, tool_results, tc, err_msg, event_sink, event_ctx);
                        started_current = false;
                        current_tc = null;
                        continue;
                    }
                else
                    tc.arguments;

                // beforeToolCall hook: can block execution OR replace args.
                // Replacement args come from extension `tool_call` handlers
                // that return a new input table; null means "unchanged".
                // See `docs/extensions.md`.
                var effective_args = prepared_args;
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
                            emitImmediateError(run_allocator, turn_allocator, ctx_messages, new_messages, tool_results, tc, reason, event_sink, event_ctx);
                            started_current = false;
                            current_tc = null;
                            continue;
                        }
                        if (before_result.args) |replacement| {
                            effective_args = replacement;
                        }
                    }
                }

                // --- Phase 2: executePreparedToolCall (pi-mono agent-loop.ts:524-559) ---

                var update_bridge = bridge_mod.UpdateBridge{
                    .sink = event_sink,
                    .sink_ctx = event_ctx,
                    .tool_call_id = tc.id,
                    .tool_name = tc.name,
                    .args = effective_args,
                };

                const result = t.execute(
                    t.ctx,
                    turn_allocator,
                    tc.id,
                    effective_args,
                    signal,
                    &bridge_mod.UpdateBridge.callback,
                    @ptrCast(&update_bridge),
                );

                // Abort after tool execution — emit synthetic end before returning
                if (isAborted(signal)) {
                    if (started_current) emitAbortedToolEnd(event_sink, event_ctx, current_tc.?, turn_allocator);
                    return;
                }

                // --- Phase 3: finalizeExecutedToolCall (pi-mono agent-loop.ts:561-595) ---

                var final_content = result.content;
                var final_details = result.details;
                var final_is_error = result.is_error;

                if (config.after_tool_call) |hook| {
                    const hook_ctx = protocol.AfterToolCallContext{
                        .assistant_message = assistant_msg,
                        .tool_call = tc,
                        .args = effective_args,
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

                if (isAborted(signal)) {
                    if (started_current) emitAbortedToolEnd(event_sink, event_ctx, current_tc.?, turn_allocator);
                    return;
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
                        .text => |txt| trm_content.append(turn_allocator, .{ .text = txt }) catch continue,
                        .image => |img| trm_content.append(turn_allocator, .{ .image = img }) catch continue,
                    }
                }

                const unowned_tool_result_msg: ai.protocol.ToolResultMessage = .{
                    .tool_call_id = tc.id,
                    .tool_name = tc.name,
                    .content = trm_content.items,
                    .details = final_details,
                    .is_error = final_is_error,
                    .timestamp = std.time.milliTimestamp(),
                };
                const tool_result_msg = message_memory.cloneToolResultMessage(run_allocator, unowned_tool_result_msg) catch unowned_tool_result_msg;

                emitToolResult(event_sink, event_ctx, tc, tool_result_msg, final_is_error, final_agent_result);
                started_current = false;
                current_tc = null;
                ctx_messages.append(run_allocator, .{ .tool_result = tool_result_msg }) catch {};
                new_messages.append(run_allocator, .{ .tool_result = tool_result_msg }) catch {};
                tool_results.append(run_allocator, tool_result_msg) catch {};
            },
            else => {},
        }
    }
}

/// Emit an immediate error result for a tool call that failed during preparation.
/// Covers: tool not found, beforeToolCall blocked, arg preparation failure.
fn emitImmediateError(
    run_allocator: std.mem.Allocator,
    turn_allocator: std.mem.Allocator,
    ctx_messages: *std.ArrayListUnmanaged(protocol.AgentMessage),
    new_messages: *std.ArrayListUnmanaged(protocol.AgentMessage),
    tool_results: *std.ArrayListUnmanaged(ai.protocol.ToolResultMessage),
    tc: ai.protocol.ToolCall,
    msg: []const u8,
    event_sink: protocol.AgentEventSink,
    event_ctx: ?*anyopaque,
) void {
    const err_tool_result = makeAgentToolTextResult(turn_allocator, msg, true);
    const err_result = makeErrorToolResult(run_allocator, tc.id, tc.name, msg);
    emitToolResult(event_sink, event_ctx, tc, err_result, true, err_tool_result);
    ctx_messages.append(run_allocator, .{ .tool_result = err_result }) catch {};
    new_messages.append(run_allocator, .{ .tool_result = err_result }) catch {};
    tool_results.append(run_allocator, err_result) catch {};
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

fn makeAgentToolTextResult(allocator: std.mem.Allocator, text: []const u8, is_error: bool) protocol.AgentToolResult {
    const owned_text = allocator.dupe(u8, text) catch return .{ .content = &.{}, .is_error = is_error };
    errdefer allocator.free(owned_text);

    const content = allocator.alloc(protocol.AgentToolResult.ContentBlock, 1) catch
        return .{ .content = &.{}, .is_error = is_error };
    content[0] = .{ .text = .{ .text = owned_text } };
    return .{ .content = content, .is_error = is_error };
}

fn makeErrorToolResult(allocator: std.mem.Allocator, tool_call_id: []const u8, tool_name: []const u8, msg: []const u8) ai.protocol.ToolResultMessage {
    const owned_text = allocator.dupe(u8, msg) catch return .{
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .content = &.{},
        .details = .{ .object = std.json.ObjectMap.init(allocator) },
        .is_error = true,
        .timestamp = std.time.milliTimestamp(),
    };
    errdefer allocator.free(owned_text);

    const content = allocator.alloc(ai.protocol.ToolResultMessage.ContentBlock, 1) catch return .{
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .content = &.{},
        .details = .{ .object = std.json.ObjectMap.init(allocator) },
        .is_error = true,
        .timestamp = std.time.milliTimestamp(),
    };
    content[0] = .{ .text = .{ .text = owned_text } };
    return .{
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .content = content,
        .details = .{ .object = std.json.ObjectMap.init(allocator) },
        .is_error = true,
        .timestamp = std.time.milliTimestamp(),
    };
}

fn isAborted(signal: AbortSignal) bool {
    return signal.isAborted();
}

test "makeAgentToolTextResult owns copied text" {
    const allocator = std.testing.allocator;
    const literal = "aborted";

    const result = makeAgentToolTextResult(allocator, literal, true);
    defer result.free(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.content.len);
    try std.testing.expectEqualStrings(literal, result.content[0].text.text);
    try std.testing.expect(result.content[0].text.text.ptr != literal.ptr);
    try std.testing.expect(result.is_error);
}

test "makeErrorToolResult owns copied text" {
    const allocator = std.testing.allocator;
    const literal = "tool failure";

    const result = makeErrorToolResult(allocator, "tc-1", "echo", literal);
    defer {
        allocator.free(result.content[0].text.text);
        allocator.free(result.content);
        var details = result.details.?.object;
        details.deinit();
    }

    try std.testing.expectEqual(@as(usize, 1), result.content.len);
    try std.testing.expectEqualStrings(literal, result.content[0].text.text);
    try std.testing.expect(result.content[0].text.text.ptr != literal.ptr);
    try std.testing.expect(result.is_error);
}

// ── trace file (ZI_LOOP_TRACE) ──────────────────────────────────────

fn openTraceFile() ?std.fs.File {
    const path = std.posix.getenv("ZI_LOOP_TRACE") orelse return null;
    if (path.len == 0) return null;
    return std.fs.cwd().createFile(path, .{
        .read = false,
        .truncate = false,
    }) catch return null;
}

fn traceWrite(f: ?std.fs.File, comptime fmt: []const u8, args: anytype) void {
    const file = f orelse return;
    file.seekFromEnd(0) catch {};
    var buf: [4096]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, fmt, args) catch return;
    file.writeAll(slice) catch {};
}
