const std = @import("std");
const ai = @import("../ai/root.zig");
const json_util = @import("../ai/json_util.zig");
const AbortSignal = @import("../abort_signal.zig").AbortSignal;
const types = @import("types.zig");

pub fn runAgentLoop(
    run_allocator: std.mem.Allocator,
    turn_allocator_parent: std.mem.Allocator,
    prompts: []const types.AgentMessage,
    context: types.AgentContext,
    config: types.AgentLoopConfig,
    event_sink: types.AgentEventSink,
    event_ctx: ?*anyopaque,
    signal: AbortSignal,
) void {
    var new_messages: std.ArrayList(types.AgentMessage) = .empty;
    defer new_messages.deinit(run_allocator);
    for (prompts) |prompt| {
        new_messages.append(run_allocator, prompt) catch return;
    }

    var ctx_messages: std.ArrayList(types.AgentMessage) = .empty;
    defer ctx_messages.deinit(run_allocator);
    for (context.messages) |message| {
        ctx_messages.append(run_allocator, message) catch return;
    }
    for (prompts) |prompt| {
        ctx_messages.append(run_allocator, prompt) catch return;
    }

    event_sink(.agent_start, event_ctx);
    event_sink(.turn_start, event_ctx);
    for (prompts) |prompt| {
        event_sink(.{ .message_start = .{ .message = prompt } }, event_ctx);
        event_sink(.{ .message_end = .{ .message = prompt } }, event_ctx);
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
    context: types.AgentContext,
    config: types.AgentLoopConfig,
    event_sink: types.AgentEventSink,
    event_ctx: ?*anyopaque,
    signal: AbortSignal,
) ContinueError!void {
    if (context.messages.len == 0) return error.EmptyContext;
    if (context.messages[context.messages.len - 1] == .assistant) return error.AssistantTail;

    var new_messages: std.ArrayList(types.AgentMessage) = .empty;
    defer new_messages.deinit(run_allocator);

    var ctx_messages: std.ArrayList(types.AgentMessage) = .empty;
    defer ctx_messages.deinit(run_allocator);
    for (context.messages) |message| {
        ctx_messages.append(run_allocator, message) catch return;
    }

    event_sink(.agent_start, event_ctx);
    event_sink(.turn_start, event_ctx);

    runLoop(run_allocator, turn_allocator_parent, &ctx_messages, &new_messages, context, config, signal, event_sink, event_ctx);
}

fn runLoop(
    run_allocator: std.mem.Allocator,
    turn_allocator_parent: std.mem.Allocator,
    ctx_messages: *std.ArrayList(types.AgentMessage),
    new_messages: *std.ArrayList(types.AgentMessage),
    base_context: types.AgentContext,
    config: types.AgentLoopConfig,
    signal: AbortSignal,
    event_sink: types.AgentEventSink,
    event_ctx: ?*anyopaque,
) void {
    var first_turn = true;
    var pending_messages = pollMessages(config.get_steering_messages, run_allocator);

    outer: while (true) {
        var has_more_tool_calls = true;

        while (has_more_tool_calls or pending_messages.len > 0) {
            if (signal.isAborted()) {
                event_sink(.{ .agent_end = .{ .messages = new_messages.items } }, event_ctx);
                return;
            }

            if (!first_turn) {
                event_sink(.turn_start, event_ctx);
            } else {
                first_turn = false;
            }

            if (pending_messages.len > 0) {
                for (pending_messages) |message| {
                    event_sink(.{ .message_start = .{ .message = message } }, event_ctx);
                    event_sink(.{ .message_end = .{ .message = message } }, event_ctx);
                    ctx_messages.append(run_allocator, message) catch {};
                    new_messages.append(run_allocator, message) catch {};
                }
                pending_messages = &.{};
            }

            var turn_arena = std.heap.ArenaAllocator.init(turn_allocator_parent);
            defer turn_arena.deinit();
            const turn_allocator = turn_arena.allocator();

            const assistant = streamAssistantResponse(
                run_allocator,
                turn_allocator,
                ctx_messages,
                base_context,
                config,
                signal,
                event_sink,
                event_ctx,
            ) orelse {
                event_sink(.{ .agent_end = .{ .messages = new_messages.items } }, event_ctx);
                return;
            };
            new_messages.append(run_allocator, .{ .assistant = assistant }) catch {};

            if (assistant.stop_reason == .@"error" or assistant.stop_reason == .aborted) {
                event_sink(.{ .turn_end = .{
                    .message = .{ .assistant = assistant },
                    .tool_results = &.{},
                } }, event_ctx);
                event_sink(.{ .agent_end = .{ .messages = new_messages.items } }, event_ctx);
                return;
            }

            const tool_calls = countToolCalls(assistant.content);
            has_more_tool_calls = tool_calls > 0;

            var tool_results: []const ai.protocol.ToolResultMessage = &.{};
            if (has_more_tool_calls) {
                tool_results = executeToolCalls(
                    run_allocator,
                    turn_allocator,
                    ctx_messages.items,
                    base_context.system_prompt,
                    assistant,
                    base_context.tools orelse &.{},
                    config,
                    signal,
                    event_sink,
                    event_ctx,
                ) catch &.{};

                for (tool_results) |result| {
                    const wrapped: types.AgentMessage = .{ .tool_result = result };
                    ctx_messages.append(run_allocator, wrapped) catch {};
                    new_messages.append(run_allocator, wrapped) catch {};
                }

                if (signal.isAborted()) {
                    event_sink(.{ .turn_end = .{
                        .message = .{ .assistant = assistant },
                        .tool_results = tool_results,
                    } }, event_ctx);
                    event_sink(.{ .agent_end = .{ .messages = new_messages.items } }, event_ctx);
                    return;
                }
            }

            event_sink(.{ .turn_end = .{
                .message = .{ .assistant = assistant },
                .tool_results = tool_results,
            } }, event_ctx);

            pending_messages = pollMessages(config.get_steering_messages, run_allocator);
        }

        const follow_up_messages = pollMessages(config.get_follow_up_messages, run_allocator);
        if (follow_up_messages.len > 0) {
            pending_messages = follow_up_messages;
            continue :outer;
        }

        break;
    }

    event_sink(.{ .agent_end = .{ .messages = new_messages.items } }, event_ctx);
}

fn pollMessages(hook: ?types.GetMessagesHook, allocator: std.mem.Allocator) []const types.AgentMessage {
    if (hook) |get| return get.call(allocator);
    return &.{};
}

fn streamAssistantResponse(
    run_allocator: std.mem.Allocator,
    turn_allocator: std.mem.Allocator,
    ctx_messages: *std.ArrayList(types.AgentMessage),
    base_context: types.AgentContext,
    config: types.AgentLoopConfig,
    signal: AbortSignal,
    event_sink: types.AgentEventSink,
    event_ctx: ?*anyopaque,
) ?ai.protocol.AssistantMessage {
    const source_messages = if (config.transform_context) |transform|
        transform.call(turn_allocator, ctx_messages.items, signal)
    else
        ctx_messages.items;

    const llm_messages = config.convert_to_llm.call(turn_allocator, source_messages);

    var llm_tools: std.ArrayList(ai.protocol.Tool) = .empty;
    defer llm_tools.deinit(turn_allocator);
    if (base_context.tools) |tools| {
        for (tools) |tool| {
            llm_tools.append(turn_allocator, .{
                .name = tool.name,
                .description = tool.description,
                .parameters = tool.parameters,
            }) catch {};
        }
    }

    const llm_context: ai.protocol.Context = .{
        .system_prompt = if (base_context.system_prompt.len > 0) base_context.system_prompt else null,
        .messages = llm_messages,
        .tools = if (llm_tools.items.len > 0) llm_tools.items else null,
    };

    var stream_options = config.stream_options;
    stream_options.base.signal = signal;
    if (config.get_api_key) |get_api_key| {
        const provider_name = json_util.providerToString(config.model.provider);
        if (get_api_key.call(provider_name)) |api_key| {
            if (api_key.len > 0) {
                stream_options.base.api_key = turn_allocator.dupe(u8, api_key) catch api_key;
            }
        }
    }

    var collector = StreamCollector{
        .run_allocator = run_allocator,
        .ctx_messages = ctx_messages,
        .event_sink = event_sink,
        .event_ctx = event_ctx,
    };

    config.stream_fn.call(
        turn_allocator,
        config.model,
        llm_context,
        stream_options,
        &StreamCollector.onEvent,
        @ptrCast(&collector),
    );

    return collector.final_message;
}

const StreamCollector = struct {
    run_allocator: std.mem.Allocator,
    ctx_messages: *std.ArrayList(types.AgentMessage),
    event_sink: types.AgentEventSink,
    event_ctx: ?*anyopaque,
    final_message: ?ai.protocol.AssistantMessage = null,
    added_partial: bool = false,

    fn onEvent(event: ai.protocol.AssistantMessageEvent, raw_ctx: ?*anyopaque) void {
        const self: *StreamCollector = @ptrCast(@alignCast(raw_ctx));

        switch (event) {
            .start => |start| {
                self.added_partial = true;
                self.ctx_messages.append(self.run_allocator, .{ .assistant = start.partial }) catch {};
                self.event_sink(.{ .message_start = .{ .message = .{ .assistant = start.partial } } }, self.event_ctx);
            },
            .done => |done| {
                self.finish(done.message);
            },
            .@"error" => |err| {
                self.finish(err.@"error");
            },
            else => {
                if (extractPartial(event)) |partial| {
                    if (self.added_partial and self.ctx_messages.items.len > 0) {
                        self.ctx_messages.items[self.ctx_messages.items.len - 1] = .{ .assistant = partial };
                    }
                    self.event_sink(.{ .message_update = .{
                        .message = .{ .assistant = partial },
                        .assistant_message_event = event,
                    } }, self.event_ctx);
                }
            },
        }
    }

    fn finish(self: *StreamCollector, message: ai.protocol.AssistantMessage) void {
        var wrapped: types.AgentMessage = .{ .assistant = message };
        const owned_message = wrapped.clone(self.run_allocator) catch wrapped;
        const owned = owned_message.assistant;
        self.final_message = owned;
        if (self.added_partial and self.ctx_messages.items.len > 0) {
            self.ctx_messages.items[self.ctx_messages.items.len - 1] = .{ .assistant = owned };
        } else {
            self.ctx_messages.append(self.run_allocator, .{ .assistant = owned }) catch {};
            self.event_sink(.{ .message_start = .{ .message = .{ .assistant = owned } } }, self.event_ctx);
        }
        self.event_sink(.{ .message_end = .{ .message = .{ .assistant = owned } } }, self.event_ctx);
    }
};

fn extractPartial(event: ai.protocol.AssistantMessageEvent) ?ai.protocol.AssistantMessage {
    return switch (event) {
        .start => |payload| payload.partial,
        .text_start => |payload| payload.partial,
        .text_delta => |payload| payload.partial,
        .text_end => |payload| payload.partial,
        .thinking_start => |payload| payload.partial,
        .thinking_delta => |payload| payload.partial,
        .thinking_end => |payload| payload.partial,
        .toolcall_start => |payload| payload.partial,
        .toolcall_delta => |payload| payload.partial,
        .toolcall_end => |payload| payload.partial,
        .done => |payload| payload.message,
        .@"error" => |payload| payload.@"error",
    };
}

fn countToolCalls(blocks: []const ai.protocol.AssistantMessage.AssistantContentBlock) usize {
    var count: usize = 0;
    for (blocks) |block| {
        if (block == .tool_call) count += 1;
    }
    return count;
}

const PreparedToolCall = struct {
    tool_call: ai.protocol.ToolCall,
    tool: types.AgentTool,
    args: std.json.Value,
};

const ImmediateToolCallOutcome = struct {
    result: types.AgentToolResult,
    is_error: bool,
};

const ExecutedToolCallOutcome = struct {
    result: types.AgentToolResult,
    is_error: bool,
};

fn executeToolCalls(
    run_allocator: std.mem.Allocator,
    turn_allocator: std.mem.Allocator,
    context_messages: []const types.AgentMessage,
    system_prompt: []const u8,
    assistant_message: ai.protocol.AssistantMessage,
    tools: []const types.AgentTool,
    config: types.AgentLoopConfig,
    signal: AbortSignal,
    event_sink: types.AgentEventSink,
    event_ctx: ?*anyopaque,
) ![]const ai.protocol.ToolResultMessage {
    return switch (config.tool_execution) {
        .sequential => executeToolCallsSequential(run_allocator, turn_allocator, context_messages, system_prompt, assistant_message, tools, config, signal, event_sink, event_ctx),
        .parallel => @panic("agent3: parallel tool execution is not implemented yet"),
    };
}

fn executeToolCallsSequential(
    run_allocator: std.mem.Allocator,
    turn_allocator: std.mem.Allocator,
    context_messages: []const types.AgentMessage,
    system_prompt: []const u8,
    assistant_message: ai.protocol.AssistantMessage,
    tools: []const types.AgentTool,
    config: types.AgentLoopConfig,
    signal: AbortSignal,
    event_sink: types.AgentEventSink,
    event_ctx: ?*anyopaque,
) ![]const ai.protocol.ToolResultMessage {
    var results: std.ArrayList(ai.protocol.ToolResultMessage) = .empty;
    errdefer results.deinit(run_allocator);

    for (assistant_message.content) |block| {
        if (block != .tool_call) continue;
        const tool_call = block.tool_call;

        event_sink(.{ .tool_execution_start = .{
            .tool_call_id = tool_call.id,
            .tool_name = tool_call.name,
            .args = tool_call.arguments,
        } }, event_ctx);

        if (signal.isAborted()) break;

        const preparation = prepareToolCall(context_messages, system_prompt, assistant_message, tool_call, tools, config, signal, turn_allocator);
        const tool_result = switch (preparation) {
            .prepared => |prepared| blk: {
                const executed = executePreparedToolCall(prepared, signal, turn_allocator, event_sink, event_ctx);
                break :blk finalizeExecutedToolCall(run_allocator, turn_allocator, context_messages, system_prompt, assistant_message, prepared, executed, config, signal, event_sink, event_ctx) catch continue;
            },
            .immediate => |immediate| emitToolCallOutcome(run_allocator, turn_allocator, tool_call, immediate.result, immediate.is_error, event_sink, event_ctx) catch continue,
        };
        try results.append(run_allocator, tool_result);
    }

    return results.items;
}

const Preparation = union(enum) {
    prepared: PreparedToolCall,
    immediate: ImmediateToolCallOutcome,
};

fn prepareToolCall(
    context_messages: []const types.AgentMessage,
    system_prompt: []const u8,
    assistant_message: ai.protocol.AssistantMessage,
    tool_call: ai.protocol.ToolCall,
    tools: []const types.AgentTool,
    config: types.AgentLoopConfig,
    signal: AbortSignal,
    allocator: std.mem.Allocator,
) Preparation {
    const tool = findTool(tools, tool_call.name) orelse {
        return .{ .immediate = .{ .result = makeErrorToolResult(allocator, std.fmt.allocPrint(allocator, "Tool {s} not found", .{tool_call.name}) catch "Tool not found"), .is_error = true } };
    };

    const prepared_args = if (tool.prepare_arguments) |prepare_arguments|
        prepare_arguments(allocator, tool_call.arguments) catch {
            return .{ .immediate = .{ .result = makeErrorToolResult(allocator, "Tool argument preparation failed"), .is_error = true } };
        }
    else
        tool_call.arguments;

    if (config.before_tool_call) |before_tool_call| {
        const input: types.BeforeToolCallContext = .{
            .assistant_message = assistant_message,
            .tool_call = tool_call,
            .args = prepared_args,
            .context = .{
                .system_prompt = system_prompt,
                .messages = context_messages,
                .tools = if (tools.len > 0) tools else null,
            },
        };
        if (before_tool_call.call(input, signal)) |result| {
            if (result.block) {
                return .{ .immediate = .{ .result = makeErrorToolResult(allocator, result.reason orelse "Tool execution was blocked"), .is_error = true } };
            }
        }
    }

    return .{ .prepared = .{
        .tool_call = tool_call,
        .tool = tool,
        .args = prepared_args,
    } };
}

fn executePreparedToolCall(
    prepared: PreparedToolCall,
    signal: AbortSignal,
    allocator: std.mem.Allocator,
    event_sink: types.AgentEventSink,
    event_ctx: ?*anyopaque,
) ExecutedToolCallOutcome {
    const UpdateBridge = struct {
        event_sink: types.AgentEventSink,
        event_ctx: ?*anyopaque,
        tool_call_id: []const u8,
        tool_name: []const u8,
        args: std.json.Value,

        fn callback(partial_result: types.AgentToolResult, raw_ctx: ?*anyopaque) void {
            const self: *const @This() = @ptrCast(@alignCast(raw_ctx));
            self.event_sink(.{ .tool_execution_update = .{
                .tool_call_id = self.tool_call_id,
                .tool_name = self.tool_name,
                .args = self.args,
                .partial_result = partial_result,
            } }, self.event_ctx);
        }
    };

    var bridge: UpdateBridge = .{
        .event_sink = event_sink,
        .event_ctx = event_ctx,
        .tool_call_id = prepared.tool_call.id,
        .tool_name = prepared.tool_call.name,
        .args = prepared.args,
    };

    const result = prepared.tool.execute(
        prepared.tool.ctx,
        allocator,
        prepared.tool_call.id,
        prepared.args,
        signal,
        &UpdateBridge.callback,
        @ptrCast(&bridge),
    ) catch |err| {
        return .{
            .result = makeErrorToolResult(allocator, @errorName(err)),
            .is_error = true,
        };
    };

    return .{
        .result = result,
        .is_error = false,
    };
}

fn finalizeExecutedToolCall(
    run_allocator: std.mem.Allocator,
    turn_allocator: std.mem.Allocator,
    context_messages: []const types.AgentMessage,
    system_prompt: []const u8,
    assistant_message: ai.protocol.AssistantMessage,
    prepared: PreparedToolCall,
    executed: ExecutedToolCallOutcome,
    config: types.AgentLoopConfig,
    signal: AbortSignal,
    event_sink: types.AgentEventSink,
    event_ctx: ?*anyopaque,
) !ai.protocol.ToolResultMessage {
    var result = executed.result;
    var is_error = executed.is_error;

    if (config.after_tool_call) |after_tool_call| {
        const input: types.AfterToolCallContext = .{
            .assistant_message = assistant_message,
            .tool_call = prepared.tool_call,
            .args = prepared.args,
            .result = result,
            .is_error = is_error,
            .context = .{
                .system_prompt = system_prompt,
                .messages = context_messages,
                .tools = null,
            },
        };
        if (after_tool_call.call(input, signal)) |overrides| {
            if (overrides.content) |content| result.content = content;
            if (overrides.details) |details| result.details = details;
            if (overrides.is_error) |override_is_error| is_error = override_is_error;
        }
    }

    return emitToolCallOutcome(run_allocator, turn_allocator, prepared.tool_call, result, is_error, event_sink, event_ctx);
}

fn emitToolCallOutcome(
    run_allocator: std.mem.Allocator,
    allocator: std.mem.Allocator,
    tool_call: ai.protocol.ToolCall,
    result: types.AgentToolResult,
    is_error: bool,
    event_sink: types.AgentEventSink,
    event_ctx: ?*anyopaque,
) !ai.protocol.ToolResultMessage {
    event_sink(.{ .tool_execution_end = .{
        .tool_call_id = tool_call.id,
        .tool_name = tool_call.name,
        .result = result,
        .is_error = is_error,
    } }, event_ctx);

    const content = try cloneToolResultBlocks(run_allocator, result.content);
    errdefer {
        for (content) |block| freeToolResultBlock(run_allocator, block);
        run_allocator.free(content);
    }

    const details = try json_util.cloneJsonValue(run_allocator, result.details);
    errdefer json_util.freeJsonValue(run_allocator, details);

    const tool_result_message: ai.protocol.ToolResultMessage = .{
        .tool_call_id = try run_allocator.dupe(u8, tool_call.id),
        .tool_name = try run_allocator.dupe(u8, tool_call.name),
        .content = content,
        .details = details,
        .is_error = is_error,
        .timestamp = std.time.milliTimestamp(),
    };

    event_sink(.{ .message_start = .{ .message = .{ .tool_result = tool_result_message } } }, event_ctx);
    event_sink(.{ .message_end = .{ .message = .{ .tool_result = tool_result_message } } }, event_ctx);
    _ = allocator;
    return tool_result_message;
}

fn findTool(tools: []const types.AgentTool, name: []const u8) ?types.AgentTool {
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return tool;
    }
    return null;
}

fn makeErrorToolResult(allocator: std.mem.Allocator, message: []const u8) types.AgentToolResult {
    const content = allocator.alloc(types.AgentToolResult.ContentBlock, 1) catch return .{ .content = &.{}, .details = .null };
    content[0] = .{ .text = .{ .text = allocator.dupe(u8, message) catch message } };

    const details_map = std.json.ObjectMap.init(allocator);
    return .{
        .content = content,
        .details = .{ .object = details_map },
    };
}

fn cloneToolResultBlocks(allocator: std.mem.Allocator, blocks: []const types.AgentToolResult.ContentBlock) ![]ai.protocol.ToolResultMessage.ContentBlock {
    const owned = try allocator.alloc(ai.protocol.ToolResultMessage.ContentBlock, blocks.len);
    var initialized: usize = 0;
    errdefer {
        for (owned[0..initialized]) |block| freeToolResultBlock(allocator, block);
        allocator.free(owned);
    }

    for (blocks, 0..) |block, i| {
        owned[i] = switch (block) {
            .text => |text| .{ .text = .{
                .text = try allocator.dupe(u8, text.text),
                .text_signature = if (text.text_signature) |sig| try allocator.dupe(u8, sig) else null,
            } },
            .image => |image| .{ .image = .{
                .data = try allocator.dupe(u8, image.data),
                .mime_type = try allocator.dupe(u8, image.mime_type),
            } },
        };
        initialized += 1;
    }

    return owned;
}

fn freeToolResultBlock(allocator: std.mem.Allocator, block: ai.protocol.ToolResultMessage.ContentBlock) void {
    switch (block) {
        .text => |text| {
            allocator.free(text.text);
            if (text.text_signature) |sig| allocator.free(sig);
        },
        .image => |image| {
            allocator.free(image.data);
            allocator.free(image.mime_type);
        },
    }
}

test "runAgentLoop emits prompt and assistant lifecycle" {
    const allocator = std.testing.allocator;

    const test_model: ai.protocol.Model = .{
        .id = "test-model",
        .name = "test-model",
        .api = .openai_responses,
        .provider = .openai,
        .base_url = "",
        .reasoning = false,
        .input = &.{.text},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 1024,
        .max_tokens = 256,
    };

    const Stream = struct {
        fn run(_: ?*anyopaque, _: std.mem.Allocator, _: types.Model, _: ai.protocol.Context, _: ai.protocol.SimpleStreamOptions, callback: ai.provider.EventCallback, callback_ctx: ?*anyopaque) void {
            const content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{
                .{ .text = .{ .text = "hi" } },
            };
            const message: ai.protocol.AssistantMessage = .{
                .content = &content,
                .api = .openai_responses,
                .provider = .openai,
                .model = "test-model",
                .usage = .{ .input = 1, .output = 1, .cache_read = 0, .cache_write = 0, .total_tokens = 2, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 } },
                .stop_reason = .stop,
                .timestamp = 1,
            };
            callback(.{ .start = .{ .partial = message } }, callback_ctx);
            callback(.{ .done = .{ .reason = .stop, .message = message } }, callback_ctx);
        }
    };

    const Events = struct {
        items: std.ArrayList([]const u8),

        fn sink(event: types.AgentEvent, raw_ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx));
            const name: []const u8 = switch (event) {
                .agent_start => "agent_start",
                .agent_end => "agent_end",
                .turn_start => "turn_start",
                .turn_end => "turn_end",
                .message_start => "message_start",
                .message_update => "message_update",
                .message_end => "message_end",
                .tool_execution_start => "tool_execution_start",
                .tool_execution_update => "tool_execution_update",
                .tool_execution_end => "tool_execution_end",
            };
            self.items.append(allocator, name) catch unreachable;
        }
    };

    var events: Events = .{ .items = .empty };
    defer events.items.deinit(allocator);

    var run_arena = std.heap.ArenaAllocator.init(allocator);
    defer run_arena.deinit();

    const prompts = [_]types.AgentMessage{
        .{ .user = .{ .content = .{ .text = "hello" }, .timestamp = 1 } },
    };

    runAgentLoop(
        run_arena.allocator(),
        allocator,
        &prompts,
        .{ .system_prompt = "", .messages = &.{}, .tools = null },
        .{
            .model = test_model,
            .stream_fn = .{ .func = &Stream.run },
            .convert_to_llm = .{ .func = testConvertToLlm },
        },
        &Events.sink,
        @ptrCast(&events),
        AbortSignal.none,
    );

    try std.testing.expectEqualStrings("agent_start", events.items.items[0]);
    try std.testing.expectEqualStrings("turn_start", events.items.items[1]);
    try std.testing.expectEqualStrings("message_start", events.items.items[2]);
    try std.testing.expectEqualStrings("message_end", events.items.items[3]);
    try std.testing.expectEqualStrings("message_start", events.items.items[4]);
    try std.testing.expectEqualStrings("message_end", events.items.items[5]);
    try std.testing.expectEqualStrings("turn_end", events.items.items[6]);
    try std.testing.expectEqualStrings("agent_end", events.items.items[7]);
}

fn testConvertToLlm(allocator: std.mem.Allocator, messages: []const types.AgentMessage, _: ?*anyopaque) []const ai.protocol.Message {
    var result: std.ArrayList(ai.protocol.Message) = .empty;
    for (messages) |message| {
        switch (message) {
            .user => |user| result.append(allocator, .{ .user = user }) catch {},
            .assistant => |assistant| result.append(allocator, .{ .assistant = assistant }) catch {},
            .tool_result => |tool_result| result.append(allocator, .{ .tool_result = tool_result }) catch {},
            .custom => {},
        }
    }
    return result.items;
}
