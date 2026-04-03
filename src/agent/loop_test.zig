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
    /// Stores the tag (user/assistant/tool_result/etc) for each message
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
        // Snapshot agent_end messages before the slice gets freed
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
    _: ?*anyopaque,
    _: ?protocol.AgentToolUpdateCallback,
    _: ?*anyopaque,
) protocol.AgentToolResult {
    const content = allocator.alloc(protocol.AgentToolResult.ContentBlock, 1) catch
        return .{ .content = &.{}, .is_error = true };
    content[0] = .{ .text = .{ .text = "echoed" } };
    return .{ .content = content };
}

fn setupRegistry(allocator: std.mem.Allocator, faux_provider: *faux.FauxProvider) ai.provider.Registry {
    var registry = ai.provider.Registry.init(allocator);
    registry.register("faux", faux_provider.provider(), null) catch @panic("register failed");
    return registry;
}

// ── tests ───────────────────────────────────────────────────────────────

test "event ordering: text response emits canonical event sequence" {
    // Verifies: agent_start → turn_start → message_start/end (user) →
    //           message_start → message_update* → message_end (assistant) →
    //           turn_end → agent_end
    const allocator = std.testing.allocator;

    var fp = faux.FauxProvider.init(allocator);
    defer fp.deinit();

    const content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("hello")};
    const msg = faux.fauxAssistantMessage(allocator, &content, .stop);
    defer allocator.free(msg.content);
    fp.setResponses(&.{msg});

    var registry = setupRegistry(allocator, &fp);
    defer registry.deinit();

    var collector = EventCollector.init(allocator);
    defer collector.deinit();

    const user_msg = makeUserMessage("hi");
    const initial = [_]protocol.AgentMessage{user_msg};

    loop.runAgentLoop(
        allocator,
        &registry,
        faux.fauxModel(),
        "test",
        &initial,
        &.{},
        .{},
        EventCollector.sink,
        &collector,
    );

    const tags = collector.tags();
    defer allocator.free(tags);

    // Minimum required ordering
    try std.testing.expect(tags.len >= 8);
    try std.testing.expectEqual(EventTag.agent_start, tags[0]);
    try std.testing.expectEqual(EventTag.turn_start, tags[1]);
    // user message_start + message_end
    try std.testing.expectEqual(EventTag.message_start, tags[2]);
    try std.testing.expectEqual(EventTag.message_end, tags[3]);
    // assistant message_start, then updates, then message_end
    try std.testing.expectEqual(EventTag.message_start, tags[4]);

    // Find the assistant message_end (skip updates)
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

    // Verify agent_end contains both messages
    const snap = collector.agent_end_snapshot orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), snap.count);
    try std.testing.expectEqual(AgentMessageTag.user, snap.message_tags[0]);
    try std.testing.expectEqual(AgentMessageTag.assistant, snap.message_tags[1]);
}

test "tool call lifecycle: execute → result message → next turn" {
    // Verifies: tool_execution_start → tool_execution_end →
    //           message_start(tool_result) → message_end(tool_result) →
    //           turn_end → turn_start → message_start(assistant) → ... → agent_end
    const allocator = std.testing.allocator;

    var fp = faux.FauxProvider.init(allocator);
    defer fp.deinit();

    // First response: tool call
    const tc_content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{
        faux.fauxToolCall("echo", "tc-1", .null),
    };
    const tc_msg = faux.fauxAssistantMessage(allocator, &tc_content, .toolUse);
    defer allocator.free(tc_msg.content);

    // Second response: text (after tool result)
    const text_content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("done")};
    const text_msg = faux.fauxAssistantMessage(allocator, &text_content, .stop);
    defer allocator.free(text_msg.content);

    fp.setResponses(&.{ tc_msg, text_msg });

    var registry = setupRegistry(allocator, &fp);
    defer registry.deinit();

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
    const initial = [_]protocol.AgentMessage{user_msg};
    const tools = [_]protocol.AgentTool{echo_tool};

    loop.runAgentLoop(
        allocator,
        &registry,
        faux.fauxModel(),
        "",
        &initial,
        &tools,
        .{},
        EventCollector.sink,
        &collector,
    );

    const tags = collector.tags();
    defer allocator.free(tags);

    // Find tool lifecycle events
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

    // Verify 2 calls to provider
    try std.testing.expectEqual(@as(usize, 2), fp.call_count);

    // agent_end should have: user, assistant(tool_call), tool_result, assistant(text)
    const snap = collector.agent_end_snapshot orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 4), snap.count);
    try std.testing.expectEqual(AgentMessageTag.user, snap.message_tags[0]);
    try std.testing.expectEqual(AgentMessageTag.assistant, snap.message_tags[1]);
    try std.testing.expectEqual(AgentMessageTag.tool_result, snap.message_tags[2]);
    try std.testing.expectEqual(AgentMessageTag.assistant, snap.message_tags[3]);
}

test "error terminal: stream error emits message_end then agent_end" {
    // Verifies: error stop_reason → message_start → message_end → turn_end → agent_end
    const allocator = std.testing.allocator;

    var fp = faux.FauxProvider.init(allocator);
    defer fp.deinit();

    const err_msg = faux.fauxAssistantMessage(allocator, &.{}, .@"error");
    defer allocator.free(err_msg.content);
    fp.setResponses(&.{err_msg});

    var registry = setupRegistry(allocator, &fp);
    defer registry.deinit();

    var collector = EventCollector.init(allocator);
    defer collector.deinit();

    const user_msg = makeUserMessage("fail");
    const initial = [_]protocol.AgentMessage{user_msg};

    loop.runAgentLoop(
        allocator,
        &registry,
        faux.fauxModel(),
        "",
        &initial,
        &.{},
        .{},
        EventCollector.sink,
        &collector,
    );

    const tags = collector.tags();
    defer allocator.free(tags);

    // Should still have turn_end and agent_end after error
    const last_tag = tags[tags.len - 1];
    try std.testing.expectEqual(EventTag.agent_end, last_tag);
    try std.testing.expectEqual(EventTag.turn_end, tags[tags.len - 2]);

    // The error message_end should reference an assistant with error stop_reason
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

    // Should NOT have a second turn (error is terminal)
    var turn_count: usize = 0;
    for (tags) |t| {
        if (t == .turn_start) turn_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), turn_count);
}

test "no provider registered emits error and agent_end" {
    const allocator = std.testing.allocator;

    // Empty registry — no provider for "faux"
    var registry = ai.provider.Registry.init(allocator);
    defer registry.deinit();

    var collector = EventCollector.init(allocator);
    defer collector.deinit();

    const user_msg = makeUserMessage("hi");
    const initial = [_]protocol.AgentMessage{user_msg};

    loop.runAgentLoop(
        allocator,
        &registry,
        faux.fauxModel(),
        "",
        &initial,
        &.{},
        .{},
        EventCollector.sink,
        &collector,
    );

    const tags = collector.tags();
    defer allocator.free(tags);

    // Should still complete with agent_end
    try std.testing.expectEqual(EventTag.agent_end, tags[tags.len - 1]);

    // Should have an error assistant message
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
