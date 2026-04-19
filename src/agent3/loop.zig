const abort_signal_mod = @import("../abort_signal.zig");
const AbortSignal = abort_signal_mod.AbortSignal;
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
    if (config.on_payload != null) {
        stream_options.base.on_payload = onPayloadAdapter;
        stream_options.base.on_payload_ctx = @constCast(&config);
    }

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

const WorkerToolUpdate = struct {
    prepared_index: usize,
    partial_result: protocol.AgentToolResult,

    fn deinit(self: *WorkerToolUpdate, allocator: std.mem.Allocator) void {
        self.partial_result.free(allocator);
        self.* = undefined;
    }
};

const WorkerUpdateQueue = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    updates: std.ArrayList(WorkerToolUpdate) = .empty,

    fn init(allocator: std.mem.Allocator) WorkerUpdateQueue {
        return .{
            .allocator = allocator,
            .updates = .empty,
        };
    }

    fn deinit(self: *WorkerUpdateQueue) void {
        for (self.updates.items) |*update| update.deinit(self.allocator);
        self.updates.deinit(self.allocator);
        self.* = undefined;
    }

    fn enqueue(self: *WorkerUpdateQueue, update: WorkerToolUpdate) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.updates.append(self.allocator, update) catch {
            var dropped = update;
            dropped.deinit(self.allocator);
            return;
        };
        self.condition.broadcast();
    }

    fn drainInto(self: *WorkerUpdateQueue, out: *std.ArrayListUnmanaged(WorkerToolUpdate), allocator: std.mem.Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.updates.items) |update| {
            out.append(allocator, update) catch {
                var dropped = update;
                dropped.deinit(self.allocator);
            };
        }
        self.updates.clearRetainingCapacity();
    }

    fn waitForActivity(self: *WorkerUpdateQueue, timeout_ns: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.updates.items.len > 0) return;
        self.condition.timedWait(&self.mutex, timeout_ns) catch |err| switch (err) {
            error.Timeout => {},
        };
    }

    fn notify(self: *WorkerUpdateQueue) void {
        self.mutex.lock();
        self.condition.broadcast();
        self.mutex.unlock();
    }
};

const PreparedToolCall = struct {
    tool_call: ai.protocol.ToolCall,
    tool: protocol.AgentTool,
    effective_args: std.json.Value,
    finalized: bool = false,
    worker: ?WorkerExecution = null,
};

const WorkerExecution = struct {
    arena: std.heap.ArenaAllocator,
    queue: *WorkerUpdateQueue,
    prepared_index: usize,
    signal: AbortSignal,
    thread: ?std.Thread = null,
    result: ?protocol.AgentToolResult = null,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    updates_closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *WorkerExecution, prepared: *const PreparedToolCall) void {
        self.result = prepared.tool.execute(
            prepared.tool.ctx,
            self.arena.allocator(),
            prepared.tool_call.id,
            prepared.effective_args,
            self.signal,
            &workerUpdateCallback,
            @ptrCast(self),
        );
        self.done.store(true, .release);
        self.queue.notify();
    }
};

fn workerUpdateCallback(partial_result: protocol.AgentToolResult, ctx: ?*anyopaque) void {
    const worker: *WorkerExecution = @ptrCast(@alignCast(ctx.?));
    if (worker.updates_closed.load(.acquire)) return;

    const owned = partial_result.clone(worker.queue.allocator) catch return;
    if (worker.updates_closed.load(.acquire)) {
        owned.free(worker.queue.allocator);
        return;
    }

    worker.queue.enqueue(.{
        .prepared_index = worker.prepared_index,
        .partial_result = owned,
    });
}

/// Execute tool calls using pi-mono's 3-phase pipeline:
/// prepare sequentially, optionally execute worker-safe tools in parallel,
/// finalize in assistant source order.
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
    const tool_phase_messages = message_memory.cloneMessages(turn_allocator, ctx_messages.items) catch ctx_messages.items;
    var update_queue = WorkerUpdateQueue.init(std.heap.page_allocator);
    defer update_queue.deinit();
    var drained_updates: std.ArrayListUnmanaged(WorkerToolUpdate) = .empty;
    defer {
        for (drained_updates.items) |*update| update.deinit(update_queue.allocator);
        drained_updates.deinit(turn_allocator);
    }

    var prepared_calls: std.ArrayListUnmanaged(PreparedToolCall) = .empty;
    defer {
        closeWorkerUpdates(prepared_calls.items);
        for (prepared_calls.items) |*prepared| {
            if (prepared.worker) |*worker| {
                if (worker.thread) |thread| thread.join();
                worker.arena.deinit();
            }
        }
        prepared_calls.deinit(turn_allocator);
    }

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
                emitImmediateError(run_allocator, turn_allocator, ctx_messages, new_messages, tool_results, tc, err_msg, event_sink, event_ctx);
                continue;
            }

            const t = tool.?;
            const prepared_args = if (t.prepare_arguments) |prep_fn|
                prep_fn(turn_allocator, tc.arguments) catch |err| {
                    const err_msg = std.fmt.allocPrint(turn_allocator, "Tool {s} argument preparation failed: {s}", .{ tc.name, @errorName(err) }) catch "Tool argument preparation failed";
                    emitImmediateError(run_allocator, turn_allocator, ctx_messages, new_messages, tool_results, tc, err_msg, event_sink, event_ctx);
                    continue;
                }
            else
                tc.arguments;

            if (validateToolArguments(turn_allocator, t.parameters, prepared_args, "arguments")) |err_msg| {
                emitImmediateError(run_allocator, turn_allocator, ctx_messages, new_messages, tool_results, tc, err_msg, event_sink, event_ctx);
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
                        emitImmediateError(run_allocator, turn_allocator, ctx_messages, new_messages, tool_results, tc, reason, event_sink, event_ctx);
                        continue;
                    }
                    if (before_result.args) |replacement| {
                        if (validateToolArguments(turn_allocator, t.parameters, replacement, "arguments")) |err_msg| {
                            emitImmediateError(run_allocator, turn_allocator, ctx_messages, new_messages, tool_results, tc, err_msg, event_sink, event_ctx);
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
        for (prepared_calls.items, 0..) |*prepared, prepared_index| {
            if (prepared.tool.affinity != .worker_thread) continue;
            prepared.worker = .{
                .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
                .queue = &update_queue,
                .prepared_index = prepared_index,
                .signal = signal,
            };
            prepared.worker.?.thread = std.Thread.spawn(.{}, WorkerExecution.run, .{ &prepared.worker.?, prepared }) catch {
                prepared.worker.?.arena.deinit();
                prepared.worker = null;
                continue;
            };
        }
    }

    for (prepared_calls.items, 0..) |*prepared, index| {
        if (isAborted(signal)) {
            closeWorkerUpdates(prepared_calls.items[index..]);
            emitAbortedPreparedCalls(prepared_calls.items[index..], event_sink, event_ctx, turn_allocator);
            return;
        }

        if (prepared.worker) |*worker| {
            while (!worker.done.load(.acquire)) {
                drainWorkerUpdates(&update_queue, &drained_updates, turn_allocator, prepared_calls.items, event_sink, event_ctx);
                if (isAborted(signal)) {
                    closeWorkerUpdates(prepared_calls.items[index..]);
                    emitAbortedPreparedCalls(prepared_calls.items[index..], event_sink, event_ctx, turn_allocator);
                    return;
                }
                if (worker.done.load(.acquire)) break;
                update_queue.waitForActivity(std.time.ns_per_ms);
            }

            worker.updates_closed.store(true, .release);
            if (worker.thread) |thread| {
                thread.join();
                worker.thread = null;
            }
            drainWorkerUpdates(&update_queue, &drained_updates, turn_allocator, prepared_calls.items, event_sink, event_ctx);

            const result = worker.result orelse makeAgentToolTextResult(turn_allocator, "Tool execution failed", true);
            if (isAborted(signal)) {
                closeWorkerUpdates(prepared_calls.items[index..]);
                emitAbortedPreparedCalls(prepared_calls.items[index..], event_sink, event_ctx, turn_allocator);
                return;
            }
            finalizePreparedToolCall(run_allocator, turn_allocator, ctx_messages, new_messages, tool_results, assistant_msg, tool_phase_messages, tools, prepared, result, config, system_prompt, signal, event_sink, event_ctx);
            prepared.finalized = true;
            continue;
        }

        var update_bridge = bridge_mod.UpdateBridge{
            .sink = event_sink,
            .sink_ctx = event_ctx,
            .tool_call_id = prepared.tool_call.id,
            .tool_name = prepared.tool_call.name,
            .args = prepared.tool_call.arguments,
        };
        const result = prepared.tool.execute(
            prepared.tool.ctx,
            turn_allocator,
            prepared.tool_call.id,
            prepared.effective_args,
            signal,
            &bridge_mod.UpdateBridge.callback,
            @ptrCast(&update_bridge),
        );
        if (isAborted(signal)) {
            closeWorkerUpdates(prepared_calls.items[index..]);
            emitAbortedPreparedCalls(prepared_calls.items[index..], event_sink, event_ctx, turn_allocator);
            return;
        }
        finalizePreparedToolCall(run_allocator, turn_allocator, ctx_messages, new_messages, tool_results, assistant_msg, tool_phase_messages, tools, prepared, result, config, system_prompt, signal, event_sink, event_ctx);
        prepared.finalized = true;
    }
}

fn closeWorkerUpdates(prepared_calls: []PreparedToolCall) void {
    for (prepared_calls) |*prepared| {
        if (prepared.worker) |*worker| {
            worker.updates_closed.store(true, .release);
            worker.queue.notify();
        }
    }
}

fn drainWorkerUpdates(
    update_queue: *WorkerUpdateQueue,
    drained_updates: *std.ArrayListUnmanaged(WorkerToolUpdate),
    allocator: std.mem.Allocator,
    prepared_calls: []const PreparedToolCall,
    event_sink: protocol.AgentEventSink,
    event_ctx: ?*anyopaque,
) void {
    update_queue.drainInto(drained_updates, allocator);
    defer {
        for (drained_updates.items) |*update| update.deinit(update_queue.allocator);
        drained_updates.clearRetainingCapacity();
    }

    for (drained_updates.items) |update| {
        const prepared = prepared_calls[update.prepared_index];
        event_sink(.{ .tool_execution_update = .{
            .tool_call_id = prepared.tool_call.id,
            .tool_name = prepared.tool_call.name,
            .args = prepared.tool_call.arguments,
            .partial_result = update.partial_result,
        } }, event_ctx);
    }
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
    ctx_messages: *std.ArrayListUnmanaged(protocol.AgentMessage),
    new_messages: *std.ArrayListUnmanaged(protocol.AgentMessage),
    tool_results: *std.ArrayListUnmanaged(ai.protocol.ToolResultMessage),
    assistant_msg: ai.protocol.AssistantMessage,
    tool_phase_messages: []const protocol.AgentMessage,
    tools: []const protocol.AgentTool,
    prepared: *const PreparedToolCall,
    result: protocol.AgentToolResult,
    config: protocol.AgentLoopConfig,
    system_prompt: []const u8,
    signal: AbortSignal,
    event_sink: protocol.AgentEventSink,
    event_ctx: ?*anyopaque,
) void {
    var final_content = result.content;
    var final_details = result.details;
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
        .is_error = final_is_error,
        .timestamp = std.time.milliTimestamp(),
    };
    const tool_result_msg = message_memory.cloneToolResultMessage(run_allocator, unowned_tool_result_msg) catch unowned_tool_result_msg;

    emitToolResult(event_sink, event_ctx, prepared.tool_call, tool_result_msg, final_is_error, final_agent_result);
    ctx_messages.append(run_allocator, .{ .tool_result = tool_result_msg }) catch {};
    new_messages.append(run_allocator, .{ .tool_result = tool_result_msg }) catch {};
    tool_results.append(run_allocator, tool_result_msg) catch {};
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

fn onPayloadAdapter(payload: std.json.Value, model: *const protocol.Model, ctx: ?*anyopaque) ?std.json.Value {
    const config: *const protocol.AgentLoopConfig = @ptrCast(@alignCast(ctx orelse return null));
    const hook = config.on_payload orelse return null;
    return hook.call(payload, model.*);
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

test "validateToolArguments rejects missing required field" {
    var schema_obj = std.json.ObjectMap.init(std.testing.allocator);
    defer schema_obj.deinit();
    try schema_obj.put("type", .{ .string = "object" });

    var required = std.json.Array.init(std.testing.allocator);
    defer required.deinit();
    try required.append(.{ .string = "path" });
    try schema_obj.put("required", .{ .array = required });

    var args_obj = std.json.ObjectMap.init(std.testing.allocator);
    defer args_obj.deinit();

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

test "parallel worker tools overlap and finalize in source order" {
    const Shared = struct {
        started_first: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        started_second: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        first_saw_second: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        second_saw_first: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    };
    const ToolCtx = struct {
        shared: *Shared,
        which: enum { first, second },
    };
    const Exec = struct {
        fn run(
            raw_ctx: ?*anyopaque,
            allocator: std.mem.Allocator,
            _: []const u8,
            _: std.json.Value,
            _: AbortSignal,
            _: ?protocol.AgentToolUpdateCallback,
            _: ?*anyopaque,
        ) protocol.AgentToolResult {
            const ctx: *ToolCtx = @ptrCast(@alignCast(raw_ctx.?));
            switch (ctx.which) {
                .first => {
                    ctx.shared.started_first.store(true, .release);
                    var i: usize = 0;
                    while (i < 100 and !ctx.shared.started_second.load(.acquire)) : (i += 1) {
                        std.Thread.sleep(1_000_000);
                    }
                    ctx.shared.first_saw_second.store(ctx.shared.started_second.load(.acquire), .release);
                },
                .second => {
                    ctx.shared.started_second.store(true, .release);
                    var i: usize = 0;
                    while (i < 100 and !ctx.shared.started_first.load(.acquire)) : (i += 1) {
                        std.Thread.sleep(1_000_000);
                    }
                    ctx.shared.second_saw_first.store(ctx.shared.started_first.load(.acquire), .release);
                },
            }
            return makeAgentToolTextResult(allocator, switch (ctx.which) {
                .first => "first",
                .second => "second",
            }, false);
        }
    };
    const Sink = struct {
        fn emit(_: protocol.AgentEvent, _: ?*anyopaque) void {}
    };

    var shared = Shared{};
    var first_ctx = ToolCtx{ .shared = &shared, .which = .first };
    var second_ctx = ToolCtx{ .shared = &shared, .which = .second };

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

    executeToolCalls(
        run_arena.allocator(),
        turn_arena.allocator(),
        &ctx_messages,
        &new_messages,
        &tool_results,
        assistant_msg,
        &tools,
        .{
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
            .tool_execution = .parallel,
        },
        "",
        AbortSignal.none,
        Sink.emit,
        null,
    );

    try std.testing.expect(shared.first_saw_second.load(.acquire));
    try std.testing.expect(shared.second_saw_first.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), tool_results.items.len);
    try std.testing.expectEqualStrings("call-1", tool_results.items[0].tool_call_id);
    try std.testing.expectEqualStrings("call-2", tool_results.items[1].tool_call_id);
}

test "parallel worker updates stream live before source-ordered finalization" {
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
            _: AbortSignal,
            on_update: ?protocol.AgentToolUpdateCallback,
            update_ctx: ?*anyopaque,
        ) protocol.AgentToolResult {
            const ctx: *ToolCtx = @ptrCast(@alignCast(raw_ctx.?));
            switch (ctx.which) {
                .first => std.Thread.sleep(30 * std.time.ns_per_ms),
                .second => {
                    if (on_update) |cb| {
                        cb(.{
                            .content = &.{.{ .text = .{ .text = "progress" } }},
                            .is_error = false,
                        }, update_ctx);
                    }
                    std.Thread.sleep(5 * std.time.ns_per_ms);
                },
            }
            return makeAgentToolTextResult(allocator, switch (ctx.which) {
                .first => "first",
                .second => "second",
            }, false);
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
        .{
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
            .tool_execution = .parallel,
        },
        "",
        AbortSignal.none,
        Collector.emit,
        @ptrCast(&collector),
    );

    try std.testing.expectEqual(@as(usize, 3), collector.events.items.len);
    try std.testing.expect(collector.events.items[0] == .update);
    try std.testing.expectEqualStrings("call-2", collector.events.items[0].update);
    try std.testing.expect(collector.events.items[1] == .end);
    try std.testing.expectEqualStrings("call-1", collector.events.items[1].end);
    try std.testing.expect(collector.events.items[2] == .end);
    try std.testing.expectEqualStrings("call-2", collector.events.items[2].end);
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
            signal: AbortSignal,
            on_update: ?protocol.AgentToolUpdateCallback,
            update_ctx: ?*anyopaque,
        ) protocol.AgentToolResult {
            _ = raw_ctx;
            if (on_update) |cb| {
                cb(.{ .content = &.{.{ .text = .{ .text = "working" } }}, .is_error = false }, update_ctx);
            }
            while (!signal.isAborted()) {
                std.Thread.sleep(std.time.ns_per_ms);
            }
            std.Thread.sleep(5 * std.time.ns_per_ms);
            return makeAgentToolTextResult(allocator, "aborted", true);
        }
    };
    const Aborter = struct {
        fn run(controller: *abort_signal_mod.AbortController) void {
            std.Thread.sleep(5 * std.time.ns_per_ms);
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

    var controller = abort_signal_mod.AbortController{};
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
        .{
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
            .tool_execution = .parallel,
        },
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
