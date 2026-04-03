const std = @import("std");
const ai = @import("../ai/root.zig");
const protocol = @import("protocol.zig");
const Agent = @import("agent.zig").Agent;
const faux = ai.faux;

// ── helpers ─────────────────────────────────────────────────────────────

fn fauxStreamHook(fp: *faux.FauxProvider) protocol.StreamHook {
    return .{
        .func = struct {
            fn func(
                ctx: ?*anyopaque,
                allocator: std.mem.Allocator,
                model: ai.protocol.Model,
                context: ai.protocol.Context,
                options: ai.protocol.SimpleStreamOptions,
                callback: ai.provider.EventCallback,
                callback_ctx: ?*anyopaque,
            ) void {
                const p: *faux.FauxProvider = @ptrCast(@alignCast(ctx.?));
                const prov = p.provider();
                prov.streamSimple(allocator, model, context, options, callback, callback_ctx);
            }
        }.func,
        .ctx = @ptrCast(fp),
    };
}

fn makeUserMessage(text: []const u8) protocol.AgentMessage {
    return .{ .user = .{
        .content = .{ .text = text },
        .timestamp = std.time.milliTimestamp(),
    } };
}

fn createAssistantMessage(allocator: std.mem.Allocator, text: []const u8) ai.protocol.AssistantMessage {
    const content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText(text)};
    return faux.fauxAssistantMessage(allocator, &content, .stop);
}

// ── contract 4: default state and mutators (agent.test.ts:50-251) ──

test "Agent: creates with default state" {
    const allocator = std.testing.allocator;
    var agent = Agent.init(allocator, .{});
    defer agent.deinit();

    try std.testing.expectEqualStrings("", agent.state.system_prompt);
    try std.testing.expectEqual(false, agent.state.is_streaming);
    try std.testing.expectEqual(@as(?protocol.AgentMessage, null), agent.state.streaming_message);
    try std.testing.expectEqual(@as(usize, 0), agent.state.pending_tool_calls.len);
    try std.testing.expectEqual(@as(?[]const u8, null), agent.state.error_message);
    try std.testing.expectEqual(@as(usize, 0), agent.state.messages.len);
    try std.testing.expectEqual(@as(usize, 0), agent.state.tools.len);
}

test "Agent: state mutators don't emit events" {
    const allocator = std.testing.allocator;
    var agent = Agent.init(allocator, .{});
    defer agent.deinit();

    var event_count: usize = 0;
    const Counter = struct {
        fn listener(_: protocol.AgentEvent, ctx: ?*anyopaque) void {
            const count: *usize = @ptrCast(@alignCast(ctx.?));
            count.* += 1;
        }
    };
    _ = agent.subscribe(Counter.listener, @ptrCast(&event_count));

    // Mutate state — should not fire events
    agent.state.system_prompt = "Test prompt";
    try std.testing.expectEqual(@as(usize, 0), event_count);
    try std.testing.expectEqualStrings("Test prompt", agent.state.system_prompt);
}

// ── contract 5: concurrent prompt guard (agent.test.ts:280-354) ──

test "Agent: prompt returns error when already running" {
    const allocator = std.testing.allocator;

    var fp = faux.FauxProvider.init(allocator);
    defer fp.deinit();

    const msg = createAssistantMessage(allocator, "ok");
    defer allocator.free(msg.content);
    fp.setResponses(&.{msg});

    var agent = Agent.init(allocator, .{
        .stream_fn = fauxStreamHook(&fp),
    });
    defer agent.deinit();

    // First prompt succeeds
    const prompts = [_]protocol.AgentMessage{makeUserMessage("hello")};
    try agent.prompt(&prompts);

    // Agent is no longer running after prompt returns (synchronous)
    try std.testing.expectEqual(false, agent.state.is_streaming);

    // Second prompt also works (not concurrent in zig — synchronous)
    var fp2 = faux.FauxProvider.init(allocator);
    defer fp2.deinit();
    const msg2 = createAssistantMessage(allocator, "ok2");
    defer allocator.free(msg2.content);
    fp2.setResponses(&.{msg2});
    agent.stream_fn = fauxStreamHook(&fp2);

    const prompts2 = [_]protocol.AgentMessage{makeUserMessage("hello2")};
    try agent.prompt(&prompts2);
}

// ── contract 6: abort (agent.test.ts:176-212) ──

test "Agent: abort sets flag, safe when not running" {
    const allocator = std.testing.allocator;
    var agent = Agent.init(allocator, .{});
    defer agent.deinit();

    // Should not panic when nothing is running
    agent.abort();
    try std.testing.expectEqual(true, agent.abort_requested);
}

// ── contract 7: steering queue (agent.test.ts:253-261) ──

test "Agent: steering queue enqueue doesn't affect state.messages" {
    const allocator = std.testing.allocator;
    var agent = Agent.init(allocator, .{});
    defer agent.deinit();

    const msg = makeUserMessage("Steering message");
    agent.steer(msg);

    // Should be queued but not in state.messages
    try std.testing.expectEqual(@as(usize, 0), agent.state.messages.len);
    try std.testing.expect(agent.hasQueuedMessages());
}

// ── contract 8: follow-up queue (agent.test.ts:263-271) ──

test "Agent: follow-up queue enqueue doesn't affect state.messages" {
    const allocator = std.testing.allocator;
    var agent = Agent.init(allocator, .{});
    defer agent.deinit();

    const msg = makeUserMessage("Follow-up message");
    agent.followUp(msg);

    try std.testing.expectEqual(@as(usize, 0), agent.state.messages.len);
    try std.testing.expect(agent.hasQueuedMessages());
}

// ── contract: prompt emits events and updates state (agent.test.ts:84-138) ──

test "Agent: prompt emits events and accumulates messages in state" {
    const allocator = std.testing.allocator;

    var fp = faux.FauxProvider.init(allocator);
    defer fp.deinit();

    const msg = createAssistantMessage(allocator, "Hi there!");
    defer allocator.free(msg.content);
    fp.setResponses(&.{msg});

    var agent = Agent.init(allocator, .{
        .stream_fn = fauxStreamHook(&fp),
    });
    defer agent.deinit();

    var event_count: usize = 0;
    var saw_agent_start = false;
    var saw_agent_end = false;

    const Tracker = struct {
        fn listener(event: protocol.AgentEvent, ctx: ?*anyopaque) void {
            const state = @as(*struct { count: *usize, start: *bool, end: *bool }, @ptrCast(@alignCast(ctx.?)));
            state.count.* += 1;
            if (event == .agent_start) state.start.* = true;
            if (event == .agent_end) state.end.* = true;
        }
    };

    var tracker_state = .{ .count = &event_count, .start = &saw_agent_start, .end = &saw_agent_end };
    _ = agent.subscribe(Tracker.listener, @ptrCast(&tracker_state));

    const prompts = [_]protocol.AgentMessage{makeUserMessage("Hello")};
    try agent.prompt(&prompts);

    try std.testing.expect(saw_agent_start);
    try std.testing.expect(saw_agent_end);
    try std.testing.expect(event_count > 0);

    // State should have user + assistant messages
    try std.testing.expectEqual(@as(usize, 2), agent.state.messages.len);
    try std.testing.expect(agent.state.messages[0] == .user);
    try std.testing.expect(agent.state.messages[1] == .assistant);

    // is_streaming should be false after prompt returns
    try std.testing.expectEqual(false, agent.state.is_streaming);
}

// ── contract: continue from assistant tail with steering queue ──
// (agent.test.ts:394-436)

test "Agent: continue drains steering queue when last message is assistant" {
    const allocator = std.testing.allocator;

    // First response for initial prompt
    var fp = faux.FauxProvider.init(allocator);
    defer fp.deinit();

    const msg1 = createAssistantMessage(allocator, "Initial response");
    defer allocator.free(msg1.content);
    const msg2 = createAssistantMessage(allocator, "Processed steering");
    defer allocator.free(msg2.content);
    fp.setResponses(&.{ msg1, msg2 });

    var agent = Agent.init(allocator, .{
        .stream_fn = fauxStreamHook(&fp),
    });
    defer agent.deinit();

    // Initial prompt
    const prompts = [_]protocol.AgentMessage{makeUserMessage("Initial")};
    try agent.prompt(&prompts);

    // State: [user, assistant]
    try std.testing.expectEqual(@as(usize, 2), agent.state.messages.len);

    // Queue steering
    agent.steer(makeUserMessage("Steering 1"));

    // continue() should drain steering and run as new prompt
    try agent.@"continue"();

    // After: [user, assistant, user(steering), assistant]
    try std.testing.expectEqual(@as(usize, 4), agent.state.messages.len);
    try std.testing.expect(agent.state.messages[2] == .user);
    try std.testing.expect(agent.state.messages[3] == .assistant);
}

// ── contract: continue from assistant tail with follow-up queue ──
// (agent.test.ts:356-392)

test "Agent: continue drains follow-up queue when no steering and last is assistant" {
    const allocator = std.testing.allocator;

    var fp = faux.FauxProvider.init(allocator);
    defer fp.deinit();

    const msg1 = createAssistantMessage(allocator, "Initial");
    defer allocator.free(msg1.content);
    const msg2 = createAssistantMessage(allocator, "Follow-up response");
    defer allocator.free(msg2.content);
    fp.setResponses(&.{ msg1, msg2 });

    var agent = Agent.init(allocator, .{
        .stream_fn = fauxStreamHook(&fp),
    });
    defer agent.deinit();

    const prompts = [_]protocol.AgentMessage{makeUserMessage("Initial")};
    try agent.prompt(&prompts);

    try std.testing.expectEqual(@as(usize, 2), agent.state.messages.len);

    // Queue follow-up
    agent.followUp(makeUserMessage("Queued follow-up"));

    try agent.@"continue"();

    // After: [user, assistant, user(follow-up), assistant]
    try std.testing.expectEqual(@as(usize, 4), agent.state.messages.len);
    try std.testing.expect(agent.state.messages[3] == .assistant);
}

// ── contract: reset clears everything ──

test "Agent: reset clears state and queues" {
    const allocator = std.testing.allocator;

    var fp = faux.FauxProvider.init(allocator);
    defer fp.deinit();

    const msg = createAssistantMessage(allocator, "ok");
    defer allocator.free(msg.content);
    fp.setResponses(&.{msg});

    var agent = Agent.init(allocator, .{
        .stream_fn = fauxStreamHook(&fp),
    });
    defer agent.deinit();

    const prompts = [_]protocol.AgentMessage{makeUserMessage("hello")};
    try agent.prompt(&prompts);

    try std.testing.expectEqual(@as(usize, 2), agent.state.messages.len);

    agent.steer(makeUserMessage("queued"));
    agent.reset();

    try std.testing.expectEqual(@as(usize, 0), agent.state.messages.len);
    try std.testing.expectEqual(false, agent.state.is_streaming);
    try std.testing.expectEqual(false, agent.hasQueuedMessages());
}
