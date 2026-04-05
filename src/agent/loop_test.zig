const AbortSignal = @import("../abort_signal.zig").AbortSignal;
const std = @import("std");
const ai = @import("../ai/root.zig");
const protocol = @import("protocol.zig");
const loop = @import("loop.zig");
const faux = ai.faux;

// ── helpers ─────────────────────────────────────────────────────────────

const EventTag = enum {
    agent_start,
    agent_end,
    turn_start,
    turn_end,
    message_start,
    message_update,
    message_end,
    tool_execution_start,
    tool_execution_update,
    tool_execution_end,
};

fn eventTag(event: protocol.AgentEvent) EventTag {
    return switch (event) {
        .agent_start => .agent_start,
        .agent_end => .agent_end,
        .turn_start => .turn_start,
        .turn_end => .turn_end,
        .message_start => .message_start,
        .message_update => .message_update,
        .message_end => .message_end,
        .tool_execution_start => .tool_execution_start,
        .tool_execution_update => .tool_execution_update,
        .tool_execution_end => .tool_execution_end,
    };
}

const AgentEndSnapshot = struct {
    count: usize,
    message_tags: []const AgentMessageTag,
};

const AgentMessageTag = enum { user, assistant, tool_result, compaction_summary, branch_summary, custom };

fn agentMessageTag(msg: protocol.AgentMessage) AgentMessageTag {
    return switch (msg) {
        .user => .user,
        .assistant => .assistant,
        .tool_result => .tool_result,
        .compaction_summary => .compaction_summary,
        .branch_summary => .branch_summary,
        .custom => .custom,
    };
}

const EventCollector = struct {
    events: std.ArrayListUnmanaged(protocol.AgentEvent),
    alloc: std.mem.Allocator,
    agent_end_snapshot: ?AgentEndSnapshot = null,

    fn init(allocator: std.mem.Allocator) EventCollector {
        return .{ .events = .empty, .alloc = allocator };
    }

    fn deinit(self: *EventCollector) void {
        self.events.deinit(self.alloc);
        if (self.agent_end_snapshot) |snap| {
            self.alloc.free(snap.message_tags);
        }
    }

    fn sink(event: protocol.AgentEvent, ctx: ?*anyopaque) void {
        const self: *EventCollector = @ptrCast(@alignCast(ctx.?));
        if (event == .agent_end) {
            const msgs = event.agent_end.messages;
            const tags_copy = self.alloc.alloc(AgentMessageTag, msgs.len) catch @panic("alloc");
            for (msgs, 0..) |m, i| {
                tags_copy[i] = agentMessageTag(m);
            }
            self.agent_end_snapshot = .{
                .count = msgs.len,
                .message_tags = tags_copy,
            };
        }
        self.events.append(self.alloc, event) catch @panic("alloc failed");
    }

    fn tags(self: *const EventCollector) []const EventTag {
        const result = self.alloc.alloc(EventTag, self.events.items.len) catch @panic("alloc");
        for (self.events.items, 0..) |e, i| {
            result[i] = eventTag(e);
        }
        return result;
    }
};

fn makeUserMessage(text: []const u8) protocol.AgentMessage {
    return .{ .user = .{
        .content = .{ .text = text },
        .timestamp = std.time.milliTimestamp(),
    } };
}

fn echoExecute(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    _: std.json.Value,
    _: AbortSignal,
    _: ?protocol.AgentToolUpdateCallback,
    _: ?*anyopaque,
) protocol.AgentToolResult {
    const content = allocator.alloc(protocol.AgentToolResult.ContentBlock, 1) catch
        return .{ .content = &.{}, .is_error = true };
    content[0] = .{ .text = .{ .text = "echoed" } };
    return .{ .content = content };
}

const agent_mod = @import("agent.zig");

/// Wrap faux provider stream_simple as a StreamHook.
fn fauxStreamFn(
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    model: ai.protocol.Model,
    context: ai.protocol.Context,
    options: ai.protocol.SimpleStreamOptions,
    callback: ai.provider.EventCallback,
    callback_ctx: ?*anyopaque,
) void {
    const fp: *faux.FauxProvider = @ptrCast(@alignCast(ctx.?));
    const prov = fp.provider();
    prov.streamSimple(allocator, model, context, options, callback, callback_ctx);
}

fn makeConfig(fp: *faux.FauxProvider) protocol.AgentLoopConfig {
    return .{
        .model = faux.fauxModel(),
        .stream = .{ .func = fauxStreamFn, .ctx = @ptrCast(fp) },
        .convert_to_llm = .{ .func = agent_mod.defaultConvertToLlm },
    };
}

// ── existing contract tests ─────────────────────────────────────────────

test "event ordering: text response emits canonical event sequence" {
    const allocator = std.testing.allocator;
    var loop_arena = std.heap.ArenaAllocator.init(allocator);
    defer loop_arena.deinit();

    var fp = faux.FauxProvider.init(allocator);
    defer fp.deinit();

    const content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("hello")};
    const msg = faux.fauxAssistantMessage(allocator, &content, .stop);
    defer allocator.free(msg.content);
    fp.setResponses(&.{msg});

    var collector = EventCollector.init(allocator);
    defer collector.deinit();

    const user_msg = makeUserMessage("hi");
    const prompts = [_]protocol.AgentMessage{user_msg};
    const context = protocol.AgentContext{
        .system_prompt = "test",
        .messages = &.{},
        .tools = null,
    };
    var config = makeConfig(&fp);
    _ = &config;

    loop.runAgentLoop(
        loop_arena.allocator(),
        &prompts,
        context,
        config,
        EventCollector.sink,
        &collector,
        AbortSignal.none,
    );

    const tags = collector.tags();
    defer allocator.free(tags);

    try std.testing.expect(tags.len >= 8);
    try std.testing.expectEqual(EventTag.agent_start, tags[0]);
    try std.testing.expectEqual(EventTag.turn_start, tags[1]);
    try std.testing.expectEqual(EventTag.message_start, tags[2]);
    try std.testing.expectEqual(EventTag.message_end, tags[3]);
    try std.testing.expectEqual(EventTag.message_start, tags[4]);

    var assistant_end_idx: usize = 0;
    for (tags, 0..) |t, i| {
        if (i > 4 and t == .message_end) {
            assistant_end_idx = i;
            break;
        }
    }
    try std.testing.expect(assistant_end_idx > 4);
    try std.testing.expectEqual(EventTag.turn_end, tags[assistant_end_idx + 1]);
    try std.testing.expectEqual(EventTag.agent_end, tags[assistant_end_idx + 2]);

    // agent_end contains user + assistant (newMessages only)
    const snap = collector.agent_end_snapshot orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), snap.count);
    try std.testing.expectEqual(AgentMessageTag.user, snap.message_tags[0]);
    try std.testing.expectEqual(AgentMessageTag.assistant, snap.message_tags[1]);
}

test "tool call lifecycle: execute → result message → next turn" {
    const allocator = std.testing.allocator;
    var loop_arena = std.heap.ArenaAllocator.init(allocator);
    defer loop_arena.deinit();

    var fp = faux.FauxProvider.init(allocator);
    defer fp.deinit();

    const tc_content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{
        faux.fauxToolCall("echo", "tc-1", .null),
    };
    const tc_msg = faux.fauxAssistantMessage(allocator, &tc_content, .toolUse);
    defer allocator.free(tc_msg.content);

    const text_content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("done")};
    const text_msg = faux.fauxAssistantMessage(allocator, &text_content, .stop);
    defer allocator.free(text_msg.content);

    fp.setResponses(&.{ tc_msg, text_msg });

    const echo_tool = protocol.AgentTool{
        .name = "echo",
        .description = "echo tool",
        .label = "Echo",
        .parameters = .null,
        .execute = echoExecute,
    };

    var collector = EventCollector.init(allocator);
    defer collector.deinit();

    const user_msg = makeUserMessage("call echo");
    const prompts = [_]protocol.AgentMessage{user_msg};
    const tools = [_]protocol.AgentTool{echo_tool};
    const context = protocol.AgentContext{
        .system_prompt = "",
        .messages = &.{},
        .tools = &tools,
    };
    var config = makeConfig(&fp);
    _ = &config;

    loop.runAgentLoop(
        loop_arena.allocator(),
        &prompts,
        context,
        config,
        EventCollector.sink,
        &collector,
        AbortSignal.none,
    );

    const tags = collector.tags();
    defer allocator.free(tags);

    var found_tool_start = false;
    var found_tool_end = false;
    var found_tool_result_msg = false;
    var second_turn_start = false;
    var turn_start_count: usize = 0;

    for (collector.events.items) |e| {
        const tag = eventTag(e);
        switch (tag) {
            .tool_execution_start => {
                found_tool_start = true;
                try std.testing.expectEqualStrings("echo", e.tool_execution_start.tool_name);
            },
            .tool_execution_end => {
                found_tool_end = true;
                try std.testing.expect(!e.tool_execution_end.is_error);
            },
            .message_start => {
                if (e.message_start.message == .tool_result) {
                    found_tool_result_msg = true;
                    try std.testing.expectEqualStrings("echo", e.message_start.message.tool_result.tool_name);
                }
            },
            .turn_start => {
                turn_start_count += 1;
                if (turn_start_count == 2) second_turn_start = true;
            },
            else => {},
        }
    }

    try std.testing.expect(found_tool_start);
    try std.testing.expect(found_tool_end);
    try std.testing.expect(found_tool_result_msg);
    try std.testing.expect(second_turn_start);

    try std.testing.expectEqual(@as(usize, 2), fp.call_count);

    // agent_end: user + assistant(tool_call) + tool_result + assistant(text)
    const snap = collector.agent_end_snapshot orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 4), snap.count);
    try std.testing.expectEqual(AgentMessageTag.user, snap.message_tags[0]);
    try std.testing.expectEqual(AgentMessageTag.assistant, snap.message_tags[1]);
    try std.testing.expectEqual(AgentMessageTag.tool_result, snap.message_tags[2]);
    try std.testing.expectEqual(AgentMessageTag.assistant, snap.message_tags[3]);
}

test "error terminal: stream error emits message_end then agent_end" {
    const allocator = std.testing.allocator;
    var loop_arena = std.heap.ArenaAllocator.init(allocator);
    defer loop_arena.deinit();

    var fp = faux.FauxProvider.init(allocator);
    defer fp.deinit();

    const err_msg = faux.fauxAssistantMessage(allocator, &.{}, .@"error");
    defer allocator.free(err_msg.content);
    fp.setResponses(&.{err_msg});

    var collector = EventCollector.init(allocator);
    defer collector.deinit();

    const user_msg = makeUserMessage("fail");
    const prompts = [_]protocol.AgentMessage{user_msg};
    const context = protocol.AgentContext{
        .system_prompt = "",
        .messages = &.{},
        .tools = null,
    };
    var config = makeConfig(&fp);
    _ = &config;

    loop.runAgentLoop(
        loop_arena.allocator(),
        &prompts,
        context,
        config,
        EventCollector.sink,
        &collector,
        AbortSignal.none,
    );

    const tags = collector.tags();
    defer allocator.free(tags);

    const last_tag = tags[tags.len - 1];
    try std.testing.expectEqual(EventTag.agent_end, last_tag);
    try std.testing.expectEqual(EventTag.turn_end, tags[tags.len - 2]);

    var found_error_end = false;
    for (collector.events.items) |e| {
        if (eventTag(e) == .message_end) {
            if (e.message_end.message == .assistant) {
                if (e.message_end.message.assistant.stop_reason == .@"error") {
                    found_error_end = true;
                }
            }
        }
    }
    try std.testing.expect(found_error_end);

    var turn_count: usize = 0;
    for (tags) |t| {
        if (t == .turn_start) turn_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), turn_count);
}

test "no provider: stream error produces agent_end" {
    // Without a provider, the faux provider with no queued responses emits an error.
    const allocator = std.testing.allocator;
    var loop_arena = std.heap.ArenaAllocator.init(allocator);
    defer loop_arena.deinit();

    var fp = faux.FauxProvider.init(allocator);
    defer fp.deinit();
    // No responses queued — will emit error

    var collector = EventCollector.init(allocator);
    defer collector.deinit();

    const user_msg = makeUserMessage("hi");
    const prompts = [_]protocol.AgentMessage{user_msg};
    const context = protocol.AgentContext{
        .system_prompt = "",
        .messages = &.{},
        .tools = null,
    };
    var config = makeConfig(&fp);
    _ = &config;

    loop.runAgentLoop(
        loop_arena.allocator(),
        &prompts,
        context,
        config,
        EventCollector.sink,
        &collector,
        AbortSignal.none,
    );

    const tags = collector.tags();
    defer allocator.free(tags);

    try std.testing.expectEqual(EventTag.agent_end, tags[tags.len - 1]);

    var found_error = false;
    for (collector.events.items) |e| {
        if (eventTag(e) == .message_end) {
            if (e.message_end.message == .assistant) {
                if (e.message_end.message.assistant.stop_reason == .@"error") {
                    found_error = true;
                }
            }
        }
    }
    try std.testing.expect(found_error);
}

// ── contract: convertToLlm filters custom messages (pi-mono agent-loop.test.ts:131-184) ──

test "convertToLlm: custom messages filtered before LLM call" {
    const allocator = std.testing.allocator;
    var loop_arena = std.heap.ArenaAllocator.init(allocator);
    defer loop_arena.deinit();

    var fp = faux.FauxProvider.init(allocator);
    defer fp.deinit();

    const content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("Response")};
    const msg = faux.fauxAssistantMessage(allocator, &content, .stop);
    defer allocator.free(msg.content);
    fp.setResponses(&.{msg});

    // Track what convertToLlm receives
    const ConvertState = struct {
        converted_count: usize = 0,
    };
    var state = ConvertState{};

    const filteringConvert = struct {
        fn func(alloc: std.mem.Allocator, messages: []const protocol.AgentMessage, ctx: ?*anyopaque) []const ai.protocol.Message {
            const s: *ConvertState = @ptrCast(@alignCast(ctx.?));
            var result: std.ArrayListUnmanaged(ai.protocol.Message) = .empty;
            for (messages) |m| {
                switch (m) {
                    .user => |u| result.append(alloc, .{ .user = u }) catch continue,
                    .assistant => |a| result.append(alloc, .{ .assistant = a }) catch continue,
                    .tool_result => |t| result.append(alloc, .{ .tool_result = t }) catch continue,
                    .custom, .compaction_summary, .branch_summary => continue,
                }
            }
            s.converted_count = result.items.len;
            return result.items;
        }
    }.func;

    // Context with a custom message already in it
    const custom_msg = protocol.AgentMessage{ .custom = .{
        .custom_type = "notification",
        .content = .{ .text = "This is a notification" },
        .timestamp = std.time.milliTimestamp(),
    } };

    const existing = [_]protocol.AgentMessage{custom_msg};
    const user_msg = makeUserMessage("Hello");
    const prompts = [_]protocol.AgentMessage{user_msg};

    const context = protocol.AgentContext{
        .system_prompt = "You are helpful.",
        .messages = &existing,
        .tools = null,
    };

    var config = makeConfig(&fp);
    config.convert_to_llm = .{ .func = filteringConvert, .ctx = @ptrCast(&state) };

    var collector = EventCollector.init(allocator);
    defer collector.deinit();

    loop.runAgentLoop(
        loop_arena.allocator(),
        &prompts,
        context,
        config,
        EventCollector.sink,
        &collector,
        AbortSignal.none,
    );

    // Custom message should have been filtered out — only user message passed to LLM
    try std.testing.expectEqual(@as(usize, 1), state.converted_count);
}

// ── contract: transformContext before convertToLlm (pi-mono agent-loop.test.ts:186-237) ──

test "transformContext: applied before convertToLlm, prunes old messages" {
    const allocator = std.testing.allocator;
    var loop_arena = std.heap.ArenaAllocator.init(allocator);
    defer loop_arena.deinit();

    var fp = faux.FauxProvider.init(allocator);
    defer fp.deinit();

    const content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("Response")};
    const msg = faux.fauxAssistantMessage(allocator, &content, .stop);
    defer allocator.free(msg.content);
    fp.setResponses(&.{msg});

    const TransformState = struct {
        transformed_count: usize = 0,
        converted_count: usize = 0,
    };
    var state = TransformState{};

    // transformContext: keep only last 2 messages
    const transformFn = struct {
        fn func(alloc: std.mem.Allocator, messages: []const protocol.AgentMessage, _: AbortSignal, ctx: ?*anyopaque) []const protocol.AgentMessage {
            const s: *TransformState = @ptrCast(@alignCast(ctx.?));
            if (messages.len <= 2) {
                s.transformed_count = messages.len;
                return messages;
            }
            const pruned = alloc.alloc(protocol.AgentMessage, 2) catch return messages;
            pruned[0] = messages[messages.len - 2];
            pruned[1] = messages[messages.len - 1];
            s.transformed_count = 2;
            return pruned;
        }
    }.func;

    const convertFn = struct {
        fn func(alloc: std.mem.Allocator, messages: []const protocol.AgentMessage, ctx: ?*anyopaque) []const ai.protocol.Message {
            const s: *TransformState = @ptrCast(@alignCast(ctx.?));
            var result: std.ArrayListUnmanaged(ai.protocol.Message) = .empty;
            for (messages) |m| {
                switch (m) {
                    .user => |u| result.append(alloc, .{ .user = u }) catch continue,
                    .assistant => |a| result.append(alloc, .{ .assistant = a }) catch continue,
                    .tool_result => |t| result.append(alloc, .{ .tool_result = t }) catch continue,
                    else => continue,
                }
            }
            s.converted_count = result.items.len;
            return result.items;
        }
    }.func;

    // Build context with 4 old messages
    const old1 = makeUserMessage("old message 1");
    const old_resp1_content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("old response 1")};
    const old_resp1 = faux.fauxAssistantMessage(allocator, &old_resp1_content, .stop);
    defer allocator.free(old_resp1.content);
    const old2 = makeUserMessage("old message 2");
    const old_resp2_content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("old response 2")};
    const old_resp2 = faux.fauxAssistantMessage(allocator, &old_resp2_content, .stop);
    defer allocator.free(old_resp2.content);

    const existing = [_]protocol.AgentMessage{
        old1,
        .{ .assistant = old_resp1 },
        old2,
        .{ .assistant = old_resp2 },
    };

    const user_msg = makeUserMessage("new message");
    const prompts = [_]protocol.AgentMessage{user_msg};
    const context = protocol.AgentContext{
        .system_prompt = "You are helpful.",
        .messages = &existing,
        .tools = null,
    };

    var config = makeConfig(&fp);
    config.convert_to_llm = .{ .func = convertFn, .ctx = @ptrCast(&state) };
    config.transform_context = .{ .func = transformFn, .ctx = @ptrCast(&state) };

    var collector = EventCollector.init(allocator);
    defer collector.deinit();

    loop.runAgentLoop(
        loop_arena.allocator(),
        &prompts,
        context,
        config,
        EventCollector.sink,
        &collector,
        AbortSignal.none,
    );

    // transformContext kept only last 2 messages
    try std.testing.expectEqual(@as(usize, 2), state.transformed_count);
    // convertToLlm then received those 2 pruned messages
    try std.testing.expectEqual(@as(usize, 2), state.converted_count);
}

// ── contract: steering injected after tool calls (pi-mono agent-loop.test.ts:533-637) ──

test "steering: queued messages injected after tool execution completes" {
    const allocator = std.testing.allocator;
    var loop_arena = std.heap.ArenaAllocator.init(allocator);
    defer loop_arena.deinit();

    var fp = faux.FauxProvider.init(allocator);
    defer fp.deinit();

    // First response: tool call
    const tc_content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{
        faux.fauxToolCall("echo", "tc-1", .null),
    };
    const tc_msg = faux.fauxAssistantMessage(allocator, &tc_content, .toolUse);
    defer allocator.free(tc_msg.content);

    // Second response: final text (after steering is injected)
    const text_content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("done")};
    const text_msg = faux.fauxAssistantMessage(allocator, &text_content, .stop);
    defer allocator.free(text_msg.content);

    fp.setResponses(&.{ tc_msg, text_msg });

    const echo_tool = protocol.AgentTool{
        .name = "echo",
        .description = "echo tool",
        .label = "Echo",
        .parameters = .null,
        .execute = echoExecute,
    };

    var collector = EventCollector.init(allocator);
    defer collector.deinit();

    const user_msg = makeUserMessage("start");
    const prompts = [_]protocol.AgentMessage{user_msg};
    const tools = [_]protocol.AgentTool{echo_tool};
    const context = protocol.AgentContext{
        .system_prompt = "",
        .messages = &.{},
        .tools = &tools,
    };

    var config = makeConfig(&fp);

    // Stateful callback: delivers steering message on second poll (after tool execution).
    // First poll is the initial poll before any streaming.
    const SteeringPollState = struct {
        poll_count: usize = 0,
        steering_msg: protocol.AgentMessage,
    };
    var poll_state = SteeringPollState{
        .steering_msg = makeUserMessage("interrupt"),
    };

    const steeringPollFn = struct {
        fn func(alloc: std.mem.Allocator, ctx: ?*anyopaque) []const protocol.AgentMessage {
            const s: *SteeringPollState = @ptrCast(@alignCast(ctx.?));
            s.poll_count += 1;
            // First poll is initial (before streaming). Second poll is after tool execution.
            if (s.poll_count == 2) {
                const result = alloc.alloc(protocol.AgentMessage, 1) catch return &.{};
                result[0] = s.steering_msg;
                return result;
            }
            return &.{};
        }
    }.func;

    config.get_steering_messages = .{ .func = steeringPollFn, .ctx = @ptrCast(&poll_state) };

    loop.runAgentLoop(
        loop_arena.allocator(),
        &prompts,
        context,
        config,
        EventCollector.sink,
        &collector,
        AbortSignal.none,
    );

    // Verify the interrupt message appears in events after tool result
    var saw_tool_result = false;
    var saw_interrupt_after_tool = false;
    for (collector.events.items) |e| {
        if (eventTag(e) == .message_start) {
            if (e.message_start.message == .tool_result) {
                saw_tool_result = true;
            }
            if (e.message_start.message == .user) {
                if (saw_tool_result) {
                    saw_interrupt_after_tool = true;
                }
            }
        }
    }
    try std.testing.expect(saw_tool_result);
    try std.testing.expect(saw_interrupt_after_tool);

    // Two LLM calls: first for tool call, second after steering injection
    try std.testing.expectEqual(@as(usize, 2), fp.call_count);
}

// ── contract: agentLoopContinue (pi-mono agent-loop.test.ts:640-757) ──

test "agentLoopContinue: resumes from context without emitting user message events" {
    const allocator = std.testing.allocator;
    var loop_arena = std.heap.ArenaAllocator.init(allocator);
    defer loop_arena.deinit();

    var fp = faux.FauxProvider.init(allocator);
    defer fp.deinit();

    const content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("Response")};
    const msg = faux.fauxAssistantMessage(allocator, &content, .stop);
    defer allocator.free(msg.content);
    fp.setResponses(&.{msg});

    var collector = EventCollector.init(allocator);
    defer collector.deinit();

    // Context already has a user message
    const user_msg = makeUserMessage("Hello");
    const existing = [_]protocol.AgentMessage{user_msg};
    const context = protocol.AgentContext{
        .system_prompt = "You are helpful.",
        .messages = &existing,
        .tools = null,
    };
    var config = makeConfig(&fp);
    _ = &config;

    try loop.runAgentLoopContinue(
        loop_arena.allocator(),
        context,
        config,
        EventCollector.sink,
        &collector,
        AbortSignal.none,
    );

    // Should only return the new assistant message (not existing user)
    const snap = collector.agent_end_snapshot orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), snap.count);
    try std.testing.expectEqual(AgentMessageTag.assistant, snap.message_tags[0]);

    // Should NOT have user message events
    var user_message_events: usize = 0;
    for (collector.events.items) |e| {
        if (eventTag(e) == .message_end) {
            if (e.message_end.message == .user) {
                user_message_events += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), user_message_events);

    // Should still have agent_start, turn_start, assistant message events, agent_end
    const tags = collector.tags();
    defer allocator.free(tags);
    try std.testing.expectEqual(EventTag.agent_start, tags[0]);
    try std.testing.expectEqual(EventTag.turn_start, tags[1]);
}

// ── contract: agentLoopContinue errors (pi-mono agent-loop.test.ts:641-654) ──

test "agentLoopContinue: returns error on empty context" {
    // pi-mono: expect(() => agentLoopContinue(context, config)).toThrow("Cannot continue: no messages in context")
    const allocator = std.testing.allocator;
    var loop_arena = std.heap.ArenaAllocator.init(allocator);
    defer loop_arena.deinit();

    var fp = faux.FauxProvider.init(allocator);
    defer fp.deinit();

    var collector = EventCollector.init(allocator);
    defer collector.deinit();

    const context = protocol.AgentContext{
        .system_prompt = "You are helpful.",
        .messages = &.{},
        .tools = null,
    };
    var config = makeConfig(&fp);
    _ = &config;

    const result = loop.runAgentLoopContinue(
        loop_arena.allocator(),
        context,
        config,
        EventCollector.sink,
        &collector,
        AbortSignal.none,
    );

    try std.testing.expectError(loop.ContinueError.EmptyContext, result);
    // No events should have been emitted
    try std.testing.expectEqual(@as(usize, 0), collector.events.items.len);
}

test "agentLoopContinue: returns error when last message is assistant" {
    const allocator = std.testing.allocator;
    var loop_arena = std.heap.ArenaAllocator.init(allocator);
    defer loop_arena.deinit();

    var fp = faux.FauxProvider.init(allocator);
    defer fp.deinit();

    var collector = EventCollector.init(allocator);
    defer collector.deinit();

    const assistant_content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("response")};
    const assistant_msg = faux.fauxAssistantMessage(allocator, &assistant_content, .stop);
    defer allocator.free(assistant_msg.content);

    const existing = [_]protocol.AgentMessage{
        makeUserMessage("hello"),
        .{ .assistant = assistant_msg },
    };

    const context = protocol.AgentContext{
        .system_prompt = "",
        .messages = &existing,
        .tools = null,
    };
    var config = makeConfig(&fp);
    _ = &config;

    const result = loop.runAgentLoopContinue(
        loop_arena.allocator(),
        context,
        config,
        EventCollector.sink,
        &collector,
        AbortSignal.none,
    );

    try std.testing.expectError(loop.ContinueError.AssistantTail, result);
    try std.testing.expectEqual(@as(usize, 0), collector.events.items.len);
}

// ── contract: follow-up messages (pi-mono agent-loop.ts:219-225) ──

test "follow-up: messages processed after agent would stop" {
    const allocator = std.testing.allocator;
    var loop_arena = std.heap.ArenaAllocator.init(allocator);
    defer loop_arena.deinit();

    var fp = faux.FauxProvider.init(allocator);
    defer fp.deinit();

    // Two responses: one for initial prompt, one for follow-up
    const content1 = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("first response")};
    const msg1 = faux.fauxAssistantMessage(allocator, &content1, .stop);
    defer allocator.free(msg1.content);

    const content2 = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("follow-up response")};
    const msg2 = faux.fauxAssistantMessage(allocator, &content2, .stop);
    defer allocator.free(msg2.content);

    fp.setResponses(&.{ msg1, msg2 });

    const FollowUpState = struct {
        delivered: bool = false,
        follow_up_msg: protocol.AgentMessage,
    };
    var fus = FollowUpState{
        .follow_up_msg = makeUserMessage("follow-up"),
    };

    const followUpFn = struct {
        fn func(alloc: std.mem.Allocator, ctx: ?*anyopaque) []const protocol.AgentMessage {
            const s: *FollowUpState = @ptrCast(@alignCast(ctx.?));
            if (!s.delivered) {
                s.delivered = true;
                const result = alloc.alloc(protocol.AgentMessage, 1) catch return &.{};
                result[0] = s.follow_up_msg;
                return result;
            }
            return &.{};
        }
    }.func;

    var collector = EventCollector.init(allocator);
    defer collector.deinit();

    const user_msg = makeUserMessage("start");
    const prompts = [_]protocol.AgentMessage{user_msg};
    const context = protocol.AgentContext{
        .system_prompt = "",
        .messages = &.{},
        .tools = null,
    };

    var config = makeConfig(&fp);
    config.get_follow_up_messages = .{ .func = followUpFn, .ctx = @ptrCast(&fus) };

    loop.runAgentLoop(
        loop_arena.allocator(),
        &prompts,
        context,
        config,
        EventCollector.sink,
        &collector,
        AbortSignal.none,
    );

    // Two LLM calls: initial + follow-up
    try std.testing.expectEqual(@as(usize, 2), fp.call_count);

    // agent_end should have: user(start) + assistant + user(follow-up) + assistant
    const snap = collector.agent_end_snapshot orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 4), snap.count);
    try std.testing.expectEqual(AgentMessageTag.user, snap.message_tags[0]);
    try std.testing.expectEqual(AgentMessageTag.assistant, snap.message_tags[1]);
    try std.testing.expectEqual(AgentMessageTag.user, snap.message_tags[2]);
    try std.testing.expectEqual(AgentMessageTag.assistant, snap.message_tags[3]);
}

// ── test 1: strengthen tool call lifecycle — assert args received ──

fn trackingEchoExecute(
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    tool_call_id: []const u8,
    args: std.json.Value,
    _: AbortSignal,
    _: ?protocol.AgentToolUpdateCallback,
    _: ?*anyopaque,
) protocol.AgentToolResult {
    const state: *TrackingEchoState = @ptrCast(@alignCast(ctx.?));
    state.received_tool_call_id = tool_call_id;
    state.received_args = args;
    state.execute_count += 1;

    const content = allocator.alloc(protocol.AgentToolResult.ContentBlock, 1) catch
        return .{ .content = &.{}, .is_error = true };
    content[0] = .{ .text = .{ .text = "echoed" } };
    return .{ .content = content };
}

const TrackingEchoState = struct {
    received_tool_call_id: ?[]const u8 = null,
    received_args: ?std.json.Value = null,
    execute_count: usize = 0,
};

test "tool call lifecycle: execute receives correct tool_call_id and args" {
    const allocator = std.testing.allocator;
    var loop_arena = std.heap.ArenaAllocator.init(allocator);
    defer loop_arena.deinit();

    var fp = faux.FauxProvider.init(allocator);
    defer fp.deinit();

    // Send a json object as args — matches pi-mono pattern of {value: "hello"}
    var obj = std.json.Value{ .object = std.json.ObjectMap.init(allocator) };
    defer obj.object.deinit();
    try obj.object.put("value", .{ .string = "hello" });

    const tc_content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{
        faux.fauxToolCall("echo", "tc-args-1", obj),
    };
    const tc_msg = faux.fauxAssistantMessage(allocator, &tc_content, .toolUse);
    defer allocator.free(tc_msg.content);

    const text_content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("done")};
    const text_msg = faux.fauxAssistantMessage(allocator, &text_content, .stop);
    defer allocator.free(text_msg.content);

    fp.setResponses(&.{ tc_msg, text_msg });

    var tracking = TrackingEchoState{};
    const echo_tool = protocol.AgentTool{
        .name = "echo",
        .description = "echo tool",
        .label = "Echo",
        .parameters = .null,
        .ctx = @ptrCast(&tracking),
        .execute = trackingEchoExecute,
    };

    var collector = EventCollector.init(allocator);
    defer collector.deinit();

    const user_msg = makeUserMessage("call echo");
    const prompts = [_]protocol.AgentMessage{user_msg};
    const tools = [_]protocol.AgentTool{echo_tool};
    const context = protocol.AgentContext{
        .system_prompt = "",
        .messages = &.{},
        .tools = &tools,
    };
    var config = makeConfig(&fp);
    _ = &config;

    loop.runAgentLoop(
        loop_arena.allocator(),
        &prompts,
        context,
        config,
        EventCollector.sink,
        &collector,
        AbortSignal.none,
    );

    // Tool was executed exactly once
    try std.testing.expectEqual(@as(usize, 1), tracking.execute_count);
    // Received correct tool_call_id
    try std.testing.expectEqualStrings("tc-args-1", tracking.received_tool_call_id.?);
    // Received correct args — object with "value": "hello"
    const received = tracking.received_args.?;
    try std.testing.expect(received == .object);
    const val = received.object.get("value").?;
    try std.testing.expect(val == .string);
    try std.testing.expectEqualStrings("hello", val.string);
}

// ── test 2: steering with 2 tool calls — both complete before inject ──

test "steering: injected after ALL tool executions complete, visible in LLM context" {
    const allocator = std.testing.allocator;
    var loop_arena = std.heap.ArenaAllocator.init(allocator);
    defer loop_arena.deinit();

    var fp = faux.FauxProvider.init(allocator);
    defer fp.deinit();

    // First response: 2 tool calls
    const tc_content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{
        faux.fauxToolCall("echo", "tc-a", .null),
        faux.fauxToolCall("echo", "tc-b", .null),
    };
    const tc_msg = faux.fauxAssistantMessage(allocator, &tc_content, .toolUse);
    defer allocator.free(tc_msg.content);

    // Second response: final text (after steering)
    const text_content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("done")};
    const text_msg = faux.fauxAssistantMessage(allocator, &text_content, .stop);
    defer allocator.free(text_msg.content);

    fp.setResponses(&.{ tc_msg, text_msg });

    const echo_tool = protocol.AgentTool{
        .name = "echo",
        .description = "echo tool",
        .label = "Echo",
        .parameters = .null,
        .execute = echoExecute,
    };

    var collector = EventCollector.init(allocator);
    defer collector.deinit();

    const user_msg = makeUserMessage("start");
    const prompts = [_]protocol.AgentMessage{user_msg};
    const tools = [_]protocol.AgentTool{echo_tool};
    const context = protocol.AgentContext{
        .system_prompt = "",
        .messages = &.{},
        .tools = &tools,
    };

    var config = makeConfig(&fp);

    const SteeringPollState2 = struct {
        poll_count: usize = 0,
        steering_msg: protocol.AgentMessage,
    };
    var poll_state = SteeringPollState2{
        .steering_msg = makeUserMessage("interrupt"),
    };

    const steeringPollFn2 = struct {
        fn func(alloc: std.mem.Allocator, ctx: ?*anyopaque) []const protocol.AgentMessage {
            const s: *SteeringPollState2 = @ptrCast(@alignCast(ctx.?));
            s.poll_count += 1;
            if (s.poll_count == 2) {
                const result = alloc.alloc(protocol.AgentMessage, 1) catch return &.{};
                result[0] = s.steering_msg;
                return result;
            }
            return &.{};
        }
    }.func;

    config.get_steering_messages = .{ .func = steeringPollFn2, .ctx = @ptrCast(&poll_state) };

    loop.runAgentLoop(
        loop_arena.allocator(),
        &prompts,
        context,
        config,
        EventCollector.sink,
        &collector,
        AbortSignal.none,
    );

    // Both tool_execution_end events should be non-error
    var tool_end_count: usize = 0;
    var tool_end_errors: usize = 0;
    var tool_result_count: usize = 0;
    var saw_all_tool_results = false;
    var saw_interrupt_after_all_results = false;

    for (collector.events.items) |e| {
        switch (eventTag(e)) {
            .tool_execution_end => {
                tool_end_count += 1;
                if (e.tool_execution_end.is_error) tool_end_errors += 1;
            },
            .message_start => {
                if (e.message_start.message == .tool_result) {
                    tool_result_count += 1;
                    if (tool_result_count == 2) saw_all_tool_results = true;
                }
                if (e.message_start.message == .user) {
                    if (saw_all_tool_results) saw_interrupt_after_all_results = true;
                }
            },
            else => {},
        }
    }

    // Both tools executed without error
    try std.testing.expectEqual(@as(usize, 2), tool_end_count);
    try std.testing.expectEqual(@as(usize, 0), tool_end_errors);

    // Interrupt appears after BOTH tool results
    try std.testing.expect(saw_all_tool_results);
    try std.testing.expect(saw_interrupt_after_all_results);

    // Two LLM calls
    try std.testing.expectEqual(@as(usize, 2), fp.call_count);
}

// ── test 3: agentLoopContinue with custom tail message ──

test "agentLoopContinue: allows custom message as last message via convertToLlm" {
    const allocator = std.testing.allocator;
    var loop_arena = std.heap.ArenaAllocator.init(allocator);
    defer loop_arena.deinit();

    var fp = faux.FauxProvider.init(allocator);
    defer fp.deinit();

    const content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("Response")};
    const msg = faux.fauxAssistantMessage(allocator, &content, .stop);
    defer allocator.free(msg.content);
    fp.setResponses(&.{msg});

    // convertToLlm maps custom → user message
    const customConvert = struct {
        fn func(alloc: std.mem.Allocator, messages: []const protocol.AgentMessage, _: ?*anyopaque) []const ai.protocol.Message {
            var result: std.ArrayListUnmanaged(ai.protocol.Message) = .empty;
            for (messages) |m| {
                switch (m) {
                    .user => |u| result.append(alloc, .{ .user = u }) catch continue,
                    .assistant => |a| result.append(alloc, .{ .assistant = a }) catch continue,
                    .tool_result => |t| result.append(alloc, .{ .tool_result = t }) catch continue,
                    .custom => {
                        result.append(alloc, .{ .user = .{
                            .content = .{ .text = "custom-mapped" },
                            .timestamp = std.time.milliTimestamp(),
                        } }) catch continue;
                    },
                    else => continue,
                }
            }
            return result.items;
        }
    }.func;

    var collector = EventCollector.init(allocator);
    defer collector.deinit();

    // Context ends with a custom message (not assistant)
    const custom_msg = protocol.AgentMessage{ .custom = .{
        .custom_type = "notification",
        .content = .{ .text = "custom tail" },
        .timestamp = std.time.milliTimestamp(),
    } };
    const existing = [_]protocol.AgentMessage{
        makeUserMessage("Hello"),
        custom_msg,
    };

    const context = protocol.AgentContext{
        .system_prompt = "You are helpful.",
        .messages = &existing,
        .tools = null,
    };

    var config = makeConfig(&fp);
    config.convert_to_llm = .{ .func = customConvert };

    try loop.runAgentLoopContinue(
        loop_arena.allocator(),
        context,
        config,
        EventCollector.sink,
        &collector,
        AbortSignal.none,
    );

    // Result has 1 assistant message, no user message events
    const snap = collector.agent_end_snapshot orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), snap.count);
    try std.testing.expectEqual(AgentMessageTag.assistant, snap.message_tags[0]);

    // No user message_end events emitted (continue doesn't emit for existing messages)
    var user_message_events: usize = 0;
    for (collector.events.items) |e| {
        if (eventTag(e) == .message_end) {
            if (e.message_end.message == .user) {
                user_message_events += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), user_message_events);
}

// ── contract: tool call pipeline hooks (pi-mono agent-loop.test.ts:310-450) ──

test "prepareArguments: rewrites args before execution receives them" {
    const allocator = std.testing.allocator;
    var loop_arena = std.heap.ArenaAllocator.init(allocator);
    defer loop_arena.deinit();

    var fp = faux.FauxProvider.init(allocator);
    defer fp.deinit();

    // LLM sends flat {oldText: "before", newText: "after"}
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"oldText\":\"before\",\"newText\":\"after\"}", .{});
    defer parsed.deinit();

    const tc_content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{
        faux.fauxToolCall("edit", "tc-prep-1", parsed.value),
    };
    const tc_msg = faux.fauxAssistantMessage(allocator, &tc_content, .toolUse);
    defer allocator.free(tc_msg.content);

    const text_content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("done")};
    const text_msg = faux.fauxAssistantMessage(allocator, &text_content, .stop);
    defer allocator.free(text_msg.content);

    fp.setResponses(&.{ tc_msg, text_msg });

    // Track what args execute receives
    const PrepState = struct {
        received_args: ?std.json.Value = null,
        execute_count: usize = 0,
    };
    var prep_state = PrepState{};

    const prepFn = struct {
        fn func(args: std.json.Value) std.json.Value {
            // Rewrite flat {oldText, newText} → {edits: [{oldText, newText}]}
            // We just return a sentinel object to prove prepare_arguments ran
            _ = args;
            // Build {edits: "rewritten"} as sentinel
            return .{ .string = "prepared-sentinel" };
        }
    }.func;

    const execFn = struct {
        fn func(
            ctx: ?*anyopaque,
            alloc: std.mem.Allocator,
            _: []const u8,
            args: std.json.Value,
            _: AbortSignal,
            _: ?protocol.AgentToolUpdateCallback,
            _: ?*anyopaque,
        ) protocol.AgentToolResult {
            const s: *PrepState = @ptrCast(@alignCast(ctx.?));
            s.received_args = args;
            s.execute_count += 1;
            const content = alloc.alloc(protocol.AgentToolResult.ContentBlock, 1) catch
                return .{ .content = &.{}, .is_error = true };
            content[0] = .{ .text = .{ .text = "ok" } };
            return .{ .content = content };
        }
    }.func;

    const edit_tool = protocol.AgentTool{
        .name = "edit",
        .description = "edit tool",
        .label = "Edit",
        .parameters = .null,
        .ctx = @ptrCast(&prep_state),
        .prepare_arguments = prepFn,
        .execute = execFn,
    };

    var collector = EventCollector.init(allocator);
    defer collector.deinit();

    const user_msg = makeUserMessage("edit something");
    const prompts = [_]protocol.AgentMessage{user_msg};
    const tools = [_]protocol.AgentTool{edit_tool};
    const context = protocol.AgentContext{
        .system_prompt = "",
        .messages = &.{},
        .tools = &tools,
    };
    var config = makeConfig(&fp);
    _ = &config;

    loop.runAgentLoop(
        loop_arena.allocator(),
        &prompts,
        context,
        config,
        EventCollector.sink,
        &collector,
        AbortSignal.none,
    );

    // Execute was called exactly once
    try std.testing.expectEqual(@as(usize, 1), prep_state.execute_count);
    // Execute received the prepared sentinel, not the original args
    const received = prep_state.received_args.?;
    try std.testing.expect(received == .string);
    try std.testing.expectEqualStrings("prepared-sentinel", received.string);
}

test "beforeToolCall: block=true prevents execution and emits error" {
    const allocator = std.testing.allocator;
    var loop_arena = std.heap.ArenaAllocator.init(allocator);
    defer loop_arena.deinit();

    var fp = faux.FauxProvider.init(allocator);
    defer fp.deinit();

    const tc_content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{
        faux.fauxToolCall("echo", "tc-block-1", .null),
    };
    const tc_msg = faux.fauxAssistantMessage(allocator, &tc_content, .toolUse);
    defer allocator.free(tc_msg.content);

    const text_content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("done")};
    const text_msg = faux.fauxAssistantMessage(allocator, &text_content, .stop);
    defer allocator.free(text_msg.content);

    fp.setResponses(&.{ tc_msg, text_msg });

    // Track whether execute is called
    const BlockState = struct {
        execute_count: usize = 0,
    };
    var block_state = BlockState{};

    const blockExecFn = struct {
        fn func(
            ctx: ?*anyopaque,
            alloc: std.mem.Allocator,
            _: []const u8,
            _: std.json.Value,
            _: AbortSignal,
            _: ?protocol.AgentToolUpdateCallback,
            _: ?*anyopaque,
        ) protocol.AgentToolResult {
            const s: *BlockState = @ptrCast(@alignCast(ctx.?));
            s.execute_count += 1;
            const content = alloc.alloc(protocol.AgentToolResult.ContentBlock, 1) catch
                return .{ .content = &.{}, .is_error = true };
            content[0] = .{ .text = .{ .text = "should not reach" } };
            return .{ .content = content };
        }
    }.func;

    const echo_tool = protocol.AgentTool{
        .name = "echo",
        .description = "echo tool",
        .label = "Echo",
        .parameters = .null,
        .ctx = @ptrCast(&block_state),
        .execute = blockExecFn,
    };

    const blockHookFn = struct {
        fn func(_: protocol.BeforeToolCallContext, _: AbortSignal, _: ?*anyopaque) ?protocol.BeforeToolCallResult {
            return .{ .block = true, .reason = "not allowed" };
        }
    }.func;

    var collector = EventCollector.init(allocator);
    defer collector.deinit();

    const user_msg = makeUserMessage("call echo");
    const prompts = [_]protocol.AgentMessage{user_msg};
    const tools = [_]protocol.AgentTool{echo_tool};
    const context = protocol.AgentContext{
        .system_prompt = "",
        .messages = &.{},
        .tools = &tools,
    };
    var config = makeConfig(&fp);
    config.before_tool_call = .{ .func = blockHookFn };

    loop.runAgentLoop(
        loop_arena.allocator(),
        &prompts,
        context,
        config,
        EventCollector.sink,
        &collector,
        AbortSignal.none,
    );

    // Execute was NOT called
    try std.testing.expectEqual(@as(usize, 0), block_state.execute_count);

    // tool_execution_end was emitted with is_error=true
    var found_tool_end = false;
    var tool_end_is_error = false;
    var tool_end_has_reason = false;
    for (collector.events.items) |e| {
        if (eventTag(e) == .tool_execution_end) {
            found_tool_end = true;
            tool_end_is_error = e.tool_execution_end.is_error;
            // Check the error content contains the reason
            for (e.tool_execution_end.result.content) |cb| {
                switch (cb) {
                    .text => |txt| {
                        if (std.mem.indexOf(u8, txt.text, "not allowed") != null) {
                            tool_end_has_reason = true;
                        }
                    },
                    else => {},
                }
            }
        }
    }
    try std.testing.expect(found_tool_end);
    try std.testing.expect(tool_end_is_error);
    try std.testing.expect(tool_end_has_reason);
}

test "afterToolCall: overrides content and isError in emitted result" {
    const allocator = std.testing.allocator;
    var loop_arena = std.heap.ArenaAllocator.init(allocator);
    defer loop_arena.deinit();

    var fp = faux.FauxProvider.init(allocator);
    defer fp.deinit();

    const tc_content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{
        faux.fauxToolCall("echo", "tc-after-1", .null),
    };
    const tc_msg = faux.fauxAssistantMessage(allocator, &tc_content, .toolUse);
    defer allocator.free(tc_msg.content);

    const text_content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("done")};
    const text_msg = faux.fauxAssistantMessage(allocator, &text_content, .stop);
    defer allocator.free(text_msg.content);

    fp.setResponses(&.{ tc_msg, text_msg });

    // Execute returns {content: [{text: "original"}], is_error: false}
    const origExecFn = struct {
        fn func(
            _: ?*anyopaque,
            alloc: std.mem.Allocator,
            _: []const u8,
            _: std.json.Value,
            _: AbortSignal,
            _: ?protocol.AgentToolUpdateCallback,
            _: ?*anyopaque,
        ) protocol.AgentToolResult {
            const content = alloc.alloc(protocol.AgentToolResult.ContentBlock, 1) catch
                return .{ .content = &.{}, .is_error = true };
            content[0] = .{ .text = .{ .text = "original" } };
            return .{ .content = content, .is_error = false };
        }
    }.func;

    const echo_tool = protocol.AgentTool{
        .name = "echo",
        .description = "echo tool",
        .label = "Echo",
        .parameters = .null,
        .execute = origExecFn,
    };

    // afterToolCall overrides content and flips is_error to true
    const afterHookFn = struct {
        fn func(_: protocol.AfterToolCallContext, _: AbortSignal, hook_ctx: ?*anyopaque) ?protocol.AfterToolCallResult {
            _ = hook_ctx;
            return .{
                .content = &.{.{ .text = .{ .text = "overridden" } }},
                .is_error = true,
            };
        }
    }.func;

    var collector = EventCollector.init(allocator);
    defer collector.deinit();

    const user_msg = makeUserMessage("call echo");
    const prompts = [_]protocol.AgentMessage{user_msg};
    const tools = [_]protocol.AgentTool{echo_tool};
    const context = protocol.AgentContext{
        .system_prompt = "",
        .messages = &.{},
        .tools = &tools,
    };
    var config = makeConfig(&fp);
    config.after_tool_call = .{ .func = afterHookFn };

    loop.runAgentLoop(
        loop_arena.allocator(),
        &prompts,
        context,
        config,
        EventCollector.sink,
        &collector,
        AbortSignal.none,
    );

    // tool_execution_end should have the overridden values
    var found_tool_end = false;
    var end_is_error = false;
    var end_has_overridden_content = false;
    for (collector.events.items) |e| {
        if (eventTag(e) == .tool_execution_end) {
            found_tool_end = true;
            end_is_error = e.tool_execution_end.is_error;
            for (e.tool_execution_end.result.content) |cb| {
                switch (cb) {
                    .text => |txt| {
                        if (std.mem.eql(u8, txt.text, "overridden")) {
                            end_has_overridden_content = true;
                        }
                    },
                    else => {},
                }
            }
        }
    }
    try std.testing.expect(found_tool_end);
    try std.testing.expect(end_is_error);
    try std.testing.expect(end_has_overridden_content);
}
