const abort_signal_mod = @import("../zio/root.zig");
const Token = abort_signal_mod.cancel.Token;
const std = @import("std");
const ai = @import("../ai/root.zig");
const protocol = @import("types.zig");
const bridge_mod = @import("stream_bridge.zig");
const json_util = @import("../ai/json_util.zig");
const message_memory = @import("message_memory.zig");
const tool_execution_group = @import("tool_execution_group.zig");

pub fn runAgentLoop(
    run_allocator: std.mem.Allocator,
    turn_allocator_parent: std.mem.Allocator,
    prompts: []const protocol.AgentMessage,
    context: protocol.AgentContext,
    config: protocol.AgentLoopConfig,
    event_sink: protocol.AgentEventSink,
    event_ctx: ?*anyopaque,
    signal: Token,
) void {
    var new_messages: std.ArrayListUnmanaged(protocol.AgentMessage) = .empty;
    for (prompts) |p| {
        new_messages.append(run_allocator, p) catch return;
    }

    var ctx_messages: std.ArrayListUnmanaged(protocol.AgentMessage) = .empty;
    for (context.messages) |m| {
        ctx_messages.append(run_allocator, m) catch return;
    }
    for (prompts) |p| {
        ctx_messages.append(run_allocator, p) catch return;
    }

    event_sink(.agent_start, event_ctx);
    event_sink(.turn_start, event_ctx);

    for (prompts) |p| {
        event_sink(.{ .message_start = .{ .message = p } }, event_ctx);
        event_sink(.{ .message_end = .{ .message = p } }, event_ctx);
    }

    runLoop(run_allocator, turn_allocator_parent, &ctx_messages, &new_messages, context, config, signal, event_sink, event_ctx);
}

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
    signal: Token,
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

    runLoop(run_allocator, turn_allocator_parent, &ctx_messages, &new_messages, context, config, signal, event_sink, event_ctx);
}

fn runLoop(
    run_allocator: std.mem.Allocator,
    turn_allocator_parent: std.mem.Allocator,
    ctx_messages: *std.ArrayListUnmanaged(protocol.AgentMessage),
    new_messages: *std.ArrayListUnmanaged(protocol.AgentMessage),
    context: protocol.AgentContext,
    config: protocol.AgentLoopConfig,
    signal: Token,
    event_sink: protocol.AgentEventSink,
    event_ctx: ?*anyopaque,
) void {
    const trace = openTraceFile();
    defer if (trace) |f| f.close(std.Options.debug_io);

    var first_turn = true;

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

    var pending_messages = if (config.skip_initial_steering_poll)
        @as([]const protocol.AgentMessage, &.{})
    else if (config.get_steering_messages) |hook|
        hook.call(run_allocator)
    else
        @as([]const protocol.AgentMessage, &.{});

    outer: while (true) {
        var has_more_tool_calls = true;

        while (has_more_tool_calls or pending_messages.len > 0) {
            var turn_arena = std.heap.ArenaAllocator.init(turn_allocator_parent);
            defer turn_arena.deinit();
            const turn_allocator = turn_arena.allocator();

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

            if (pending_messages.len > 0) {
                for (pending_messages) |msg| {
                    event_sink(.{ .message_start = .{ .message = msg } }, event_ctx);
                    event_sink(.{ .message_end = .{ .message = msg } }, event_ctx);
                    ctx_messages.append(run_allocator, msg) catch {};
                    new_messages.append(run_allocator, msg) catch {};
                }
                pending_messages = &.{};
            }

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

            pending_messages = if (config.get_steering_messages) |hook|
                hook.call(run_allocator)
            else
                @as([]const protocol.AgentMessage, &.{});
            traceWrite(trace, "STEERING: pending={d}\n", .{pending_messages.len});
        }

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

fn streamAssistantResponse(
    run_allocator: std.mem.Allocator,
    turn_allocator: std.mem.Allocator,
    ctx_messages: *std.ArrayListUnmanaged(protocol.AgentMessage),
    config: protocol.AgentLoopConfig,
    signal: Token,
    event_sink: protocol.AgentEventSink,
    event_ctx: ?*anyopaque,
    llm_tools: []const ai.protocol.Tool,
    system_prompt: []const u8,
) ?ai.protocol.AssistantMessage {
    var messages: []const protocol.AgentMessage = ctx_messages.items;
    if (config.transform_context) |hook| {
        messages = hook.call(turn_allocator, messages, signal);
    }

    const llm_messages = config.convert_to_llm.call(turn_allocator, messages);

    const llm_context = ai.protocol.Context{
        .system_prompt = if (system_prompt.len > 0) system_prompt else null,
        .messages = llm_messages,
        .tools = if (llm_tools.len > 0) llm_tools else null,
    };

    var stream_options = config.buildStreamOptions();
    stream_options.base.signal = signal;
    if (config.on_payload != null) {
        stream_options.base.on_payload = onPayloadAdapter;
        stream_options.base.on_payload_ctx = @constCast(&config);
    }

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

    ctx_messages.append(run_allocator, .{ .assistant = assistant_msg }) catch {};

    return assistant_msg;
}

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

const PreparedToolCall = struct {
    tool_call: ai.protocol.ToolCall,
    tool: ?protocol.AgentTool,
    effective_args: std.json.Value,
    finalized: bool = false,
    result_message: ?ai.protocol.ToolResultMessage = null,
    worker_started: bool = false,
    pending_worker_result: ?protocol.AgentToolResult = null,
};

const WorkerExecution = struct {
    owner_allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    group: *tool_execution_group.ToolExecutionGroup,
    prepared_index: usize,
    tool_call_id: []const u8,
    tool_name: []const u8,
    args: std.json.Value,
    signal: Token,

    fn deinit(self: *WorkerExecution) void {
        self.group.allocator.free(self.tool_call_id);
        self.group.allocator.free(self.tool_name);
        json_util.freeJsonValue(self.group.allocator, self.args);
        self.arena.deinit();
        self.owner_allocator.destroy(self);
    }

    fn run(self: *WorkerExecution, prepared: *const PreparedToolCall) void {
        const tool = prepared.tool orelse {
            self.group.emit(.{ .completed = .{
                .prepared_index = self.prepared_index,
                .result = makeAgentToolTextResult(self.group.allocator, "Tool execution failed", true),
            } });
            self.deinit();
            return;
        };
        const execution = tool.start(
            self.arena.allocator(),
            prepared.tool_call.id,
            prepared.effective_args,
            self.signal,
            &workerUpdateCallback,
            @ptrCast(self),
        );
        const result = resolveToolExecution(execution, self.arena.allocator(), self.signal, &workerUpdateCallback, @ptrCast(self));
        const owned = result.clone(self.group.allocator) catch makeAgentToolTextResult(self.group.allocator, "Tool execution failed", true);
        self.group.emit(.{ .completed = .{
            .prepared_index = self.prepared_index,
            .result = owned,
        } });
        self.deinit();
    }
};

fn resolveToolExecution(
    execution: protocol.AgentToolExecution,
    allocator: std.mem.Allocator,
    signal: Token,
    on_update: ?protocol.AgentToolUpdateCallback,
    update_ctx: ?*anyopaque,
) protocol.AgentToolResult {
    return switch (execution) {
        .ready => |result| result,
        .pending => |pending| blk: {
            defer pending.free(allocator);
            if (isAborted(signal)) pending.requestCancel();
            break :blk pending.await(allocator, signal, on_update, update_ctx);
        },
    };
}

fn workerUpdateCallback(partial_result: protocol.AgentToolResult, ctx: ?*anyopaque) void {
    const worker: *WorkerExecution = @ptrCast(@alignCast(ctx.?));
    const allocator = worker.group.allocator;

    const tool_call_id = allocator.dupe(u8, worker.tool_call_id) catch return;
    const tool_name = allocator.dupe(u8, worker.tool_name) catch {
        allocator.free(tool_call_id);
        return;
    };
    const args = json_util.cloneJsonValue(allocator, worker.args) catch {
        allocator.free(tool_call_id);
        allocator.free(tool_name);
        return;
    };
    const owned = partial_result.clone(allocator) catch {
        allocator.free(tool_call_id);
        allocator.free(tool_name);
        json_util.freeJsonValue(allocator, args);
        return;
    };

    worker.group.emit(.{ .update = .{
        .prepared_index = worker.prepared_index,
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .args = args,
        .partial_result = owned,
    } });
}

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
    signal: Token,
    event_sink: protocol.AgentEventSink,
    event_ctx: ?*anyopaque,
) void {
    const tool_phase_messages = message_memory.cloneMessages(turn_allocator, ctx_messages.items) catch ctx_messages.items;
    var worker_group = tool_execution_group.ToolExecutionGroup.init(std.heap.page_allocator, config.io) catch null;
    defer if (worker_group) |*group| group.deinit();

    var prepared_calls: std.ArrayListUnmanaged(PreparedToolCall) = .empty;
    defer prepared_calls.deinit(turn_allocator);

    for (assistant_msg.content) |block| switch (block) {
        .tool_call => |tc| {
            if (isAborted(signal)) return;

            event_sink(.{ .tool_execution_start = .{
                .tool_call_id = tc.id,
                .tool_name = tc.name,
                .args = tc.arguments,
            } }, event_ctx);

            const tool = findTool(tools, tc.name);
            if (tool == null) {
                const err_msg = std.fmt.allocPrint(turn_allocator, "Tool {s} not found", .{tc.name}) catch "Tool not found";
                appendImmediateError(run_allocator, turn_allocator, &prepared_calls, tc, err_msg, event_sink, event_ctx);
                continue;
            }

            const t = tool.?;
            const prepared_args = if (t.prepare_arguments) |prep_fn|
                prep_fn(turn_allocator, tc.arguments) catch |err| {
                    const err_msg = std.fmt.allocPrint(turn_allocator, "Tool {s} argument preparation failed: {s}", .{ tc.name, @errorName(err) }) catch "Tool argument preparation failed";
                    appendImmediateError(run_allocator, turn_allocator, &prepared_calls, tc, err_msg, event_sink, event_ctx);
                    continue;
                }
            else
                tc.arguments;

            if (validateToolArguments(turn_allocator, t.parameters, prepared_args, "arguments")) |err_msg| {
                appendImmediateError(run_allocator, turn_allocator, &prepared_calls, tc, err_msg, event_sink, event_ctx);
                continue;
            }

            var effective_args = prepared_args;
            if (config.before_tool_call) |hook| {
                const hook_ctx = protocol.BeforeToolCallContext{
                    .assistant_message = assistant_msg,
                    .tool_call = tc,
                    .args = prepared_args,
                    .context = .{
                        .system_prompt = system_prompt,
                        .messages = tool_phase_messages,
                        .tools = if (tools.len > 0) tools else null,
                    },
                };
                if (hook.call(hook_ctx, signal)) |before_result| {
                    if (before_result.block) {
                        const reason = before_result.reason orelse "Tool execution was blocked";
                        appendImmediateError(run_allocator, turn_allocator, &prepared_calls, tc, reason, event_sink, event_ctx);
                        continue;
                    }
                    if (before_result.args) |replacement| {
                        if (validateToolArguments(turn_allocator, t.parameters, replacement, "arguments")) |err_msg| {
                            appendImmediateError(run_allocator, turn_allocator, &prepared_calls, tc, err_msg, event_sink, event_ctx);
                            continue;
                        }
                        effective_args = replacement;
                    }
                }
            }

            prepared_calls.append(turn_allocator, .{
                .tool_call = tc,
                .tool = t,
                .effective_args = effective_args,
            }) catch {};
        },
        else => {},
    };

    if (config.tool_execution == .parallel) {
        if (worker_group) |*group| {
            for (prepared_calls.items, 0..) |*prepared, prepared_index| {
                const tool = prepared.tool orelse continue;
                if (tool.affinity != .worker_thread) continue;
                const worker = std.heap.page_allocator.create(WorkerExecution) catch continue;
                const tool_call_id = group.allocator.dupe(u8, prepared.tool_call.id) catch {
                    std.heap.page_allocator.destroy(worker);
                    continue;
                };
                const tool_name = group.allocator.dupe(u8, prepared.tool_call.name) catch {
                    group.allocator.free(tool_call_id);
                    std.heap.page_allocator.destroy(worker);
                    continue;
                };
                const args = json_util.cloneJsonValue(group.allocator, prepared.tool_call.arguments) catch {
                    group.allocator.free(tool_call_id);
                    group.allocator.free(tool_name);
                    std.heap.page_allocator.destroy(worker);
                    continue;
                };
                worker.* = .{
                    .owner_allocator = std.heap.page_allocator,
                    .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
                    .group = group,
                    .prepared_index = prepared_index,
                    .tool_call_id = tool_call_id,
                    .tool_name = tool_name,
                    .args = args,
                    .signal = signal,
                };
                group.spawnThread(WorkerExecution.run, .{ worker, prepared }) catch {
                    worker.deinit();
                    continue;
                };
                prepared.worker_started = true;
            }
        }
    }

    var finalized_count = countFinalizedPreparedCalls(prepared_calls.items);
    while (finalized_count < prepared_calls.items.len) {
        if (isAborted(signal)) {
            if (worker_group) |*group| group.cancel();
            emitAbortedPreparedCalls(prepared_calls.items, event_sink, event_ctx, turn_allocator);
            return;
        }

        if (findNextAgentThreadCall(prepared_calls.items)) |inline_index| {
            var prepared = &prepared_calls.items[inline_index];
            var update_bridge = bridge_mod.UpdateBridge{
                .sink = event_sink,
                .sink_ctx = event_ctx,
                .tool_call_id = prepared.tool_call.id,
                .tool_name = prepared.tool_call.name,
                .args = prepared.tool_call.arguments,
            };
            const tool = prepared.tool orelse continue;
            const execution = tool.start(
                turn_allocator,
                prepared.tool_call.id,
                prepared.effective_args,
                signal,
                &bridge_mod.UpdateBridge.callback,
                @ptrCast(&update_bridge),
            );
            const result = resolveToolExecution(execution, turn_allocator, signal, &bridge_mod.UpdateBridge.callback, @ptrCast(&update_bridge));
            if (isAborted(signal)) {
                if (worker_group) |*group| group.cancel();
                emitAbortedPreparedCalls(prepared_calls.items, event_sink, event_ctx, turn_allocator);
                return;
            }
            prepared.result_message = finalizePreparedToolCall(run_allocator, turn_allocator, assistant_msg, tool_phase_messages, tools, prepared, result, config, system_prompt, signal, event_sink, event_ctx);
            prepared.finalized = true;
            finalized_count += 1;
            continue;
        }

        if (worker_group) |*group| {
            if (group.next() catch null) |event| {
                var owned_event = event;
                defer owned_event.deinit(group.allocator);
                switch (owned_event) {
                    .update => |update| emitWorkerUpdate(turn_allocator, prepared_calls.items, update, event_sink, event_ctx),
                    .completed => |completion| {
                        if (completion.prepared_index >= prepared_calls.items.len) continue;
                        var prepared = &prepared_calls.items[completion.prepared_index];
                        if (prepared.finalized) continue;
                        prepared.pending_worker_result = completion.result.clone(turn_allocator) catch
                            makeAgentToolTextResult(turn_allocator, "Tool execution result allocation failed", true);
                        finalized_count += finalizeReadyWorkerCompletions(run_allocator, turn_allocator, assistant_msg, tool_phase_messages, tools, prepared_calls.items, config, system_prompt, signal, event_sink, event_ctx);
                    },
                }
                continue;
            }
        }
        break;
    }

    emitPreparedToolResultMessagesInSourceOrder(run_allocator, ctx_messages, new_messages, tool_results, prepared_calls.items, event_sink, event_ctx);
}

fn appendImmediateError(
    run_allocator: std.mem.Allocator,
    turn_allocator: std.mem.Allocator,
    prepared_calls: *std.ArrayListUnmanaged(PreparedToolCall),
    tc: ai.protocol.ToolCall,
    msg: []const u8,
    event_sink: protocol.AgentEventSink,
    event_ctx: ?*anyopaque,
) void {
    const err_tool_result = makeAgentToolTextResult(turn_allocator, msg, true);
    const err_result = makeErrorToolResult(run_allocator, tc.id, tc.name, msg);
    emitToolExecutionEnd(event_sink, event_ctx, tc, true, err_tool_result);
    prepared_calls.append(turn_allocator, .{
        .tool_call = tc,
        .tool = null,
        .effective_args = tc.arguments,
        .finalized = true,
        .result_message = err_result,
    }) catch {};
}

fn countFinalizedPreparedCalls(prepared_calls: []const PreparedToolCall) usize {
    var count: usize = 0;
    for (prepared_calls) |prepared| {
        if (prepared.finalized) count += 1;
    }
    return count;
}

fn emitPreparedToolResultMessagesInSourceOrder(
    allocator: std.mem.Allocator,
    ctx_messages: *std.ArrayListUnmanaged(protocol.AgentMessage),
    new_messages: *std.ArrayListUnmanaged(protocol.AgentMessage),
    tool_results: *std.ArrayListUnmanaged(ai.protocol.ToolResultMessage),
    prepared_calls: []const PreparedToolCall,
    event_sink: protocol.AgentEventSink,
    event_ctx: ?*anyopaque,
) void {
    for (prepared_calls) |prepared| {
        const tool_result_msg = prepared.result_message orelse continue;
        emitToolResultMessage(event_sink, event_ctx, tool_result_msg);
        ctx_messages.append(allocator, .{ .tool_result = tool_result_msg }) catch {};
        new_messages.append(allocator, .{ .tool_result = tool_result_msg }) catch {};
        tool_results.append(allocator, tool_result_msg) catch {};
    }
}

fn finalizeReadyWorkerCompletions(
    run_allocator: std.mem.Allocator,
    turn_allocator: std.mem.Allocator,
    assistant_msg: ai.protocol.AssistantMessage,
    tool_phase_messages: []const protocol.AgentMessage,
    tools: []const protocol.AgentTool,
    prepared_calls: []PreparedToolCall,
    config: protocol.AgentLoopConfig,
    system_prompt: []const u8,
    signal: Token,
    event_sink: protocol.AgentEventSink,
    event_ctx: ?*anyopaque,
) usize {
    var finalized: usize = 0;
    for (prepared_calls) |*prepared| {
        if (prepared.finalized) continue;
        if (!prepared.worker_started) break;
        const result = prepared.pending_worker_result orelse break;
        prepared.result_message = finalizePreparedToolCall(run_allocator, turn_allocator, assistant_msg, tool_phase_messages, tools, prepared, result, config, system_prompt, signal, event_sink, event_ctx);
        prepared.finalized = true;
        finalized += 1;
    }
    return finalized;
}

fn findNextAgentThreadCall(prepared_calls: []const PreparedToolCall) ?usize {
    for (prepared_calls, 0..) |prepared, index| {
        if (prepared.finalized) continue;
        if (!prepared.worker_started) return index;
    }
    return null;
}

fn emitWorkerUpdate(
    allocator: std.mem.Allocator,
    prepared_calls: []const PreparedToolCall,
    update: tool_execution_group.ToolUpdate,
    event_sink: protocol.AgentEventSink,
    event_ctx: ?*anyopaque,
) void {
    if (update.prepared_index >= prepared_calls.len) return;

    const tool_call_id = allocator.dupe(u8, update.tool_call_id) catch update.tool_call_id;
    const tool_name = allocator.dupe(u8, update.tool_name) catch update.tool_name;
    const args = json_util.cloneJsonValue(allocator, update.args) catch update.args;
    const partial_result = update.partial_result.clone(allocator) catch update.partial_result;

    event_sink(.{ .tool_execution_update = .{
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .args = args,
        .partial_result = partial_result,
    } }, event_ctx);
}

fn emitAbortedPreparedCalls(
    prepared_calls: []PreparedToolCall,
    event_sink: protocol.AgentEventSink,
    event_ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
) void {
    for (prepared_calls) |prepared| {
        if (prepared.finalized) continue;
        emitAbortedToolEnd(event_sink, event_ctx, prepared.tool_call, allocator);
    }
}

fn finalizePreparedToolCall(
    run_allocator: std.mem.Allocator,
    turn_allocator: std.mem.Allocator,
    assistant_msg: ai.protocol.AssistantMessage,
    tool_phase_messages: []const protocol.AgentMessage,
    tools: []const protocol.AgentTool,
    prepared: *const PreparedToolCall,
    result: protocol.AgentToolResult,
    config: protocol.AgentLoopConfig,
    system_prompt: []const u8,
    signal: Token,
    event_sink: protocol.AgentEventSink,
    event_ctx: ?*anyopaque,
) ai.protocol.ToolResultMessage {
    var final_content = result.content;
    var final_details = result.details;
    const final_presentation = result.presentation;
    var final_is_error = result.is_error;

    if (config.after_tool_call) |hook| {
        const hook_ctx = protocol.AfterToolCallContext{
            .assistant_message = assistant_msg,
            .tool_call = prepared.tool_call,
            .args = prepared.effective_args,
            .result = result,
            .is_error = result.is_error,
            .context = .{
                .system_prompt = system_prompt,
                .messages = tool_phase_messages,
                .tools = if (tools.len > 0) tools else null,
            },
        };
        if (hook.call(hook_ctx, signal)) |after_result| {
            if (after_result.content) |c| final_content = c;
            if (after_result.details) |d| final_details = d;
            if (after_result.is_error) |e| final_is_error = e;
        }
    }

    const final_agent_result = protocol.AgentToolResult{
        .content = final_content,
        .details = final_details,
        .presentation = final_presentation,
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
        .tool_call_id = prepared.tool_call.id,
        .tool_name = prepared.tool_call.name,
        .content = trm_content.items,
        .details = final_details,
        .presentation = final_presentation,
        .is_error = final_is_error,
        .timestamp = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds(),
    };
    const tool_result_msg = message_memory.cloneToolResultMessage(run_allocator, unowned_tool_result_msg) catch unowned_tool_result_msg;

    emitToolExecutionEnd(event_sink, event_ctx, prepared.tool_call, final_is_error, final_agent_result);
    return tool_result_msg;
}

fn emitToolExecutionEnd(
    event_sink: protocol.AgentEventSink,
    event_ctx: ?*anyopaque,
    tc: ai.protocol.ToolCall,
    is_error: bool,
    tool_result: protocol.AgentToolResult,
) void {
    event_sink(.{ .tool_execution_end = .{
        .tool_call_id = tc.id,
        .tool_name = tc.name,
        .result = tool_result,
        .is_error = is_error,
    } }, event_ctx);
}

fn emitToolResultMessage(
    event_sink: protocol.AgentEventSink,
    event_ctx: ?*anyopaque,
    result: ai.protocol.ToolResultMessage,
) void {
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

fn validateToolArguments(
    allocator: std.mem.Allocator,
    schema: std.json.Value,
    args: std.json.Value,
    path: []const u8,
) ?[]const u8 {
    return validateSchemaValue(allocator, schema, args, path) catch |err| blk: {
        const msg = std.fmt.allocPrint(allocator, "argument validation failed: {s}", .{@errorName(err)}) catch "argument validation failed";
        break :blk msg;
    };
}

fn validateSchemaValue(
    allocator: std.mem.Allocator,
    schema: std.json.Value,
    value: std.json.Value,
    path: []const u8,
) !?[]const u8 {
    const schema_obj = switch (schema) {
        .object => |obj| obj,
        else => return null,
    };

    const schema_type: ?[]const u8 = if (schema_obj.get("type")) |kind| switch (kind) {
        .string => |s| s,
        else => null,
    } else if (schema_obj.get("properties") != null or schema_obj.get("required") != null)
        @as([]const u8, "object")
    else
        null;

    if (schema_type) |kind| {
        if (!valueMatchesSchemaType(kind, value)) {
            return std.fmt.allocPrint(allocator, "{s} must be {s}", .{ path, kind }) catch "argument type mismatch";
        }

        if (std.mem.eql(u8, kind, "object")) {
            const obj = value.object;
            if (schema_obj.get("required")) |required_value| switch (required_value) {
                .array => |required| {
                    for (required.items) |entry| switch (entry) {
                        .string => |required_key| {
                            if (obj.get(required_key) == null) {
                                return std.fmt.allocPrint(allocator, "missing required field {s}.{s}", .{ path, required_key }) catch "missing required field";
                            }
                        },
                        else => {},
                    };
                },
                else => {},
            };

            if (schema_obj.get("properties")) |properties_value| switch (properties_value) {
                .object => |properties| {
                    var it = properties.iterator();
                    while (it.next()) |entry| {
                        const child_value = obj.get(entry.key_ptr.*) orelse continue;
                        const child_path = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ path, entry.key_ptr.* });
                        defer allocator.free(child_path);
                        if (try validateSchemaValue(allocator, entry.value_ptr.*, child_value, child_path)) |err_msg| {
                            return err_msg;
                        }
                    }
                },
                else => {},
            };

            return null;
        }

        if (std.mem.eql(u8, kind, "array")) {
            const arr = value.array;
            if (schema_obj.get("minItems")) |min_value| switch (min_value) {
                .integer => |min_items| {
                    if (min_items >= 0 and arr.items.len < @as(usize, @intCast(min_items))) {
                        return std.fmt.allocPrint(allocator, "{s} must have at least {d} items", .{ path, min_items }) catch "array too short";
                    }
                },
                else => {},
            };
            if (schema_obj.get("maxItems")) |max_value| switch (max_value) {
                .integer => |max_items| {
                    if (max_items >= 0 and arr.items.len > @as(usize, @intCast(max_items))) {
                        return std.fmt.allocPrint(allocator, "{s} must have at most {d} items", .{ path, max_items }) catch "array too long";
                    }
                },
                else => {},
            };
            if (schema_obj.get("items")) |item_schema| {
                for (arr.items, 0..) |item, index| {
                    const child_path = try std.fmt.allocPrint(allocator, "{s}[{d}]", .{ path, index });
                    defer allocator.free(child_path);
                    if (try validateSchemaValue(allocator, item_schema, item, child_path)) |err_msg| {
                        return err_msg;
                    }
                }
            }
        }
    }

    return null;
}

fn valueMatchesSchemaType(kind: []const u8, value: std.json.Value) bool {
    if (std.mem.eql(u8, kind, "object")) return value == .object;
    if (std.mem.eql(u8, kind, "array")) return value == .array;
    if (std.mem.eql(u8, kind, "string")) return value == .string;
    if (std.mem.eql(u8, kind, "boolean")) return value == .bool;
    if (std.mem.eql(u8, kind, "number")) {
        return switch (value) {
            .integer, .float, .number_string => true,
            else => false,
        };
    }
    if (std.mem.eql(u8, kind, "integer")) return value == .integer;
    if (std.mem.eql(u8, kind, "null")) return value == .null;
    return true;
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
        .details = .{ .object = .{} },
        .is_error = true,
        .timestamp = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds(),
    };
    errdefer allocator.free(owned_text);

    const content = allocator.alloc(ai.protocol.ToolResultMessage.ContentBlock, 1) catch return .{
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .content = &.{},
        .details = .{ .object = .{} },
        .is_error = true,
        .timestamp = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds(),
    };
    content[0] = .{ .text = .{ .text = owned_text } };
    return .{
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .content = content,
        .details = .{ .object = .{} },
        .is_error = true,
        .timestamp = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds(),
    };
}

fn onPayloadAdapter(allocator: std.mem.Allocator, payload: std.json.Value, model: *const protocol.Model, ctx: ?*anyopaque) ?std.json.Value {
    const config: *const protocol.AgentLoopConfig = @ptrCast(@alignCast(ctx orelse return null));
    const hook = config.on_payload orelse return null;
    return hook.call(allocator, payload, model.*);
}

fn isAborted(signal: Token) bool {
    return signal.isAborted();
}

fn testLoopConfig(tool_execution: protocol.ToolExecutionMode) protocol.AgentLoopConfig {
    return .{
        .model = .{
            .id = "gpt-test",
            .name = "gpt-test",
            .api = .openai_responses,
            .provider = .openai,
            .base_url = "",
            .reasoning = false,
            .input = &.{},
            .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
            .context_window = 0,
            .max_tokens = 0,
        },
        .stream = undefined,
        .convert_to_llm = undefined,
        .tool_execution = tool_execution,
    };
}

test "synthetic tool results own copied text" {
    const allocator = std.testing.allocator;

    const agent_result = makeAgentToolTextResult(allocator, "aborted", true);
    defer agent_result.free(allocator);

    try std.testing.expectEqual(@as(usize, 1), agent_result.content.len);
    try std.testing.expectEqualStrings("aborted", agent_result.content[0].text.text);
    try std.testing.expect(agent_result.content[0].text.text.ptr != "aborted".ptr);
    try std.testing.expect(agent_result.is_error);

    const error_result = makeErrorToolResult(allocator, "tc-1", "echo", "tool failure");
    defer {
        allocator.free(error_result.content[0].text.text);
        allocator.free(error_result.content);
        var details = error_result.details.?.object;
        details.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), error_result.content.len);
    try std.testing.expectEqualStrings("tool failure", error_result.content[0].text.text);
    try std.testing.expect(error_result.content[0].text.text.ptr != "tool failure".ptr);
    try std.testing.expect(error_result.is_error);
}

test "validateToolArguments rejects missing required field" {
    var schema_obj: std.json.ObjectMap = .{};
    defer schema_obj.deinit(std.testing.allocator);
    try schema_obj.put(std.testing.allocator, "type", .{ .string = "object" });

    var required = std.json.Array.init(std.testing.allocator);
    defer required.deinit();
    try required.append(.{ .string = "path" });
    try schema_obj.put(std.testing.allocator, "required", .{ .array = required });

    var args_obj: std.json.ObjectMap = .{};
    defer args_obj.deinit(std.testing.allocator);

    const err_msg = validateToolArguments(
        std.testing.allocator,
        .{ .object = schema_obj },
        .{ .object = args_obj },
        "arguments",
    );
    defer if (err_msg) |msg| std.testing.allocator.free(msg);

    try std.testing.expect(err_msg != null);
    try std.testing.expect(std.mem.indexOf(u8, err_msg.?, "arguments.path") != null);
}

test "parallel worker updates stream live before completion-ordered finalization" {
    const ToolCtx = struct {
        which: enum { first, second },
    };
    const Event = union(enum) {
        update: []const u8,
        end: []const u8,
    };
    const Collector = struct {
        allocator: std.mem.Allocator,
        events: std.ArrayListUnmanaged(Event) = .empty,

        fn emit(event: protocol.AgentEvent, raw_ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx.?));
            switch (event) {
                .tool_execution_update => |payload| self.events.append(self.allocator, .{ .update = payload.tool_call_id }) catch {},
                .tool_execution_end => |payload| self.events.append(self.allocator, .{ .end = payload.tool_call_id }) catch {},
                else => {},
            }
        }
    };
    const Exec = struct {
        fn run(
            raw_ctx: ?*anyopaque,
            allocator: std.mem.Allocator,
            _: []const u8,
            _: std.json.Value,
            _: Token,
            on_update: ?protocol.AgentToolUpdateCallback,
            update_ctx: ?*anyopaque,
        ) protocol.AgentToolExecution {
            const ctx: *ToolCtx = @ptrCast(@alignCast(raw_ctx.?));
            switch (ctx.which) {
                .first => std.Options.debug_io.sleep(.fromMilliseconds(30), .awake) catch {},
                .second => {
                    if (on_update) |cb| {
                        cb(.{
                            .content = &.{.{ .text = .{ .text = "progress" } }},
                            .is_error = false,
                        }, update_ctx);
                    }
                    std.Options.debug_io.sleep(.fromNanoseconds(@intCast(5 * std.time.ns_per_ms)), .awake) catch {};
                },
            }
            return .{ .ready = makeAgentToolTextResult(allocator, switch (ctx.which) {
                .first => "first",
                .second => "second",
            }, false) };
        }
    };

    var first_ctx = ToolCtx{ .which = .first };
    var second_ctx = ToolCtx{ .which = .second };
    const assistant_content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{
        .{ .tool_call = .{ .id = "call-1", .name = "one", .arguments = .null } },
        .{ .tool_call = .{ .id = "call-2", .name = "two", .arguments = .null } },
    };
    const assistant_msg: ai.protocol.AssistantMessage = .{
        .content = &assistant_content,
        .api = .openai_responses,
        .provider = .openai,
        .model = "gpt-test",
        .usage = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total_tokens = 0, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 } },
        .stop_reason = .toolUse,
        .timestamp = 0,
    };
    const tools = [_]protocol.AgentTool{
        .{ .name = "one", .description = "", .label = "One", .parameters = .null, .ctx = @ptrCast(&first_ctx), .affinity = .worker_thread, .execute = &Exec.run },
        .{ .name = "two", .description = "", .label = "Two", .parameters = .null, .ctx = @ptrCast(&second_ctx), .affinity = .worker_thread, .execute = &Exec.run },
    };

    var run_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer run_arena.deinit();
    var turn_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer turn_arena.deinit();
    var ctx_messages: std.ArrayListUnmanaged(protocol.AgentMessage) = .empty;
    var new_messages: std.ArrayListUnmanaged(protocol.AgentMessage) = .empty;
    var tool_results: std.ArrayListUnmanaged(ai.protocol.ToolResultMessage) = .empty;
    var collector = Collector{ .allocator = std.testing.allocator };
    defer collector.events.deinit(std.testing.allocator);

    executeToolCalls(
        run_arena.allocator(),
        turn_arena.allocator(),
        &ctx_messages,
        &new_messages,
        &tool_results,
        assistant_msg,
        &tools,
        testLoopConfig(.parallel),
        "",
        Token.none,
        Collector.emit,
        @ptrCast(&collector),
    );

    try std.testing.expectEqual(@as(usize, 3), collector.events.items.len);
    var saw_update = false;
    var saw_call_1_end = false;
    var saw_call_2_end = false;
    for (collector.events.items) |event| switch (event) {
        .update => |id| {
            try std.testing.expectEqualStrings("call-2", id);
            saw_update = true;
        },
        .end => |id| {
            if (std.mem.eql(u8, id, "call-1")) saw_call_1_end = true;
            if (std.mem.eql(u8, id, "call-2")) saw_call_2_end = true;
        },
    };
    try std.testing.expect(saw_update);
    try std.testing.expect(saw_call_1_end);
    try std.testing.expect(saw_call_2_end);
    try std.testing.expectEqual(@as(usize, 2), tool_results.items.len);
    try std.testing.expectEqualStrings("call-1", tool_results.items[0].tool_call_id);
    try std.testing.expectEqualStrings("call-2", tool_results.items[1].tool_call_id);
}

test "abort during parallel worker updates balances tool execution lifecycle" {
    const ToolCtx = struct {};
    const Collector = struct {
        allocator: std.mem.Allocator,
        starts: std.ArrayListUnmanaged([]const u8) = .empty,
        ends: std.ArrayListUnmanaged([]const u8) = .empty,

        fn emit(event: protocol.AgentEvent, raw_ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx.?));
            switch (event) {
                .tool_execution_start => |payload| self.starts.append(self.allocator, payload.tool_call_id) catch {},
                .tool_execution_end => |payload| self.ends.append(self.allocator, payload.tool_call_id) catch {},
                else => {},
            }
        }
    };
    const Exec = struct {
        fn run(
            raw_ctx: ?*anyopaque,
            allocator: std.mem.Allocator,
            _: []const u8,
            _: std.json.Value,
            signal: Token,
            on_update: ?protocol.AgentToolUpdateCallback,
            update_ctx: ?*anyopaque,
        ) protocol.AgentToolExecution {
            _ = raw_ctx;
            if (on_update) |cb| {
                cb(.{ .content = &.{.{ .text = .{ .text = "working" } }}, .is_error = false }, update_ctx);
            }
            while (!signal.isAborted()) {
                std.Options.debug_io.sleep(.fromNanoseconds(@intCast(std.time.ns_per_ms)), .awake) catch {};
            }
            std.Options.debug_io.sleep(.fromNanoseconds(@intCast(5 * std.time.ns_per_ms)), .awake) catch {};
            return .{ .ready = makeAgentToolTextResult(allocator, "aborted", true) };
        }
    };
    const Aborter = struct {
        fn run(controller: *abort_signal_mod.cancel.Source) void {
            std.Options.debug_io.sleep(.fromNanoseconds(@intCast(5 * std.time.ns_per_ms)), .awake) catch {};
            controller.requestAbort();
        }
    };

    var tool_ctx = ToolCtx{};
    const assistant_content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{
        .{ .tool_call = .{ .id = "call-1", .name = "one", .arguments = .null } },
        .{ .tool_call = .{ .id = "call-2", .name = "two", .arguments = .null } },
    };
    const assistant_msg: ai.protocol.AssistantMessage = .{
        .content = &assistant_content,
        .api = .openai_responses,
        .provider = .openai,
        .model = "gpt-test",
        .usage = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total_tokens = 0, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 } },
        .stop_reason = .toolUse,
        .timestamp = 0,
    };
    const tools = [_]protocol.AgentTool{
        .{ .name = "one", .description = "", .label = "One", .parameters = .null, .ctx = @ptrCast(&tool_ctx), .affinity = .worker_thread, .execute = &Exec.run },
        .{ .name = "two", .description = "", .label = "Two", .parameters = .null, .ctx = @ptrCast(&tool_ctx), .affinity = .worker_thread, .execute = &Exec.run },
    };

    var controller = abort_signal_mod.cancel.Source{};
    const signal = controller.beginRun();
    const aborter = try std.Thread.spawn(.{}, Aborter.run, .{&controller});
    defer aborter.join();

    var run_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer run_arena.deinit();
    var turn_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer turn_arena.deinit();
    var ctx_messages: std.ArrayListUnmanaged(protocol.AgentMessage) = .empty;
    var new_messages: std.ArrayListUnmanaged(protocol.AgentMessage) = .empty;
    var tool_results: std.ArrayListUnmanaged(ai.protocol.ToolResultMessage) = .empty;
    var collector = Collector{ .allocator = std.testing.allocator };
    defer collector.starts.deinit(std.testing.allocator);
    defer collector.ends.deinit(std.testing.allocator);

    executeToolCalls(
        run_arena.allocator(),
        turn_arena.allocator(),
        &ctx_messages,
        &new_messages,
        &tool_results,
        assistant_msg,
        &tools,
        testLoopConfig(.parallel),
        "",
        signal,
        Collector.emit,
        @ptrCast(&collector),
    );

    try std.testing.expectEqual(@as(usize, 2), collector.starts.items.len);
    try std.testing.expectEqual(@as(usize, 2), collector.ends.items.len);
    try std.testing.expectEqualStrings("call-1", collector.ends.items[0]);
    try std.testing.expectEqualStrings("call-2", collector.ends.items[1]);
}

fn openTraceFile() ?std.Io.File {
    const path = @import("env").get("ZI_LOOP_TRACE") orelse return null;
    if (path.len == 0) return null;
    return std.Io.Dir.cwd().createFile(std.Options.debug_io, path, .{
        .read = false,
        .truncate = false,
    }) catch return null;
}

fn traceWrite(f: ?std.Io.File, comptime fmt: []const u8, args: anytype) void {
    const file = f orelse return;
    var buf: [4096]u8 = undefined;
    var writer = file.writer(std.Options.debug_io, &buf);
    writer.interface.print(fmt, args) catch return;
    writer.interface.flush() catch {};
}
