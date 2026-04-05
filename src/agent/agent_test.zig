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
    try std.testing.expectEqual(protocol.ThinkingLevel.off, agent.state.thinking_level);
    try std.testing.expectEqualStrings("unknown", agent.state.model.id);
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

    // Track whether nested prompt was rejected
    const GuardState = struct {
        agent_ptr: *Agent,
        nested_rejected: bool = false,
    };
    var guard_state = GuardState{ .agent_ptr = &agent };

    const GuardListener = struct {
        fn listener(event: protocol.AgentEvent, ctx: ?*anyopaque) void {
            const s: *GuardState = @ptrCast(@alignCast(ctx.?));
            if (event == .agent_start) {
                // Try nested prompt while running — should fail
                const nested_prompts = [_]protocol.AgentMessage{makeUserMessage("nested")};
                const result = s.agent_ptr.prompt(&nested_prompts);
                if (result) |_| {
                    // Should not succeed
                } else |err| {
                    if (err == error.AlreadyProcessing) {
                        s.nested_rejected = true;
                    }
                }
            }
        }
    };

    _ = agent.subscribe(GuardListener.listener, @ptrCast(&guard_state));

    const prompts = [_]protocol.AgentMessage{makeUserMessage("hello")};
    try agent.prompt(&prompts);

    try std.testing.expect(guard_state.nested_rejected);
    try std.testing.expectEqual(false, agent.state.is_streaming);
}

// ── contract 6: abort (agent.test.ts:176-212) ──

test "Agent: abort sets flag, safe when not running" {
    const allocator = std.testing.allocator;
    var agent = Agent.init(allocator, .{});
    defer agent.deinit();

    // Should be a no-op when nothing is running (pi-mono guards on is_running)
    agent.abort();
    try std.testing.expectEqual(false, agent.abort_requested.load(.acquire));
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

// ── contract: one-at-a-time steering from assistant tail (agent.test.ts:394-436) ──
// pi-mono: steer 2 messages, continue() drains first only, inner loop drains second

test "Agent: continue keeps one-at-a-time steering semantics from assistant tail" {
    const allocator = std.testing.allocator;

    var fp = faux.FauxProvider.init(allocator);
    defer fp.deinit();

    // Need 3 responses: initial + 2 steering responses
    // But continue() with one-at-a-time drains first steering, runs loop.
    // The loop's inner getSteeringMessages will drain the second.
    // So we need: 1 initial response + 2 steering responses = 3 total
    const msg1 = createAssistantMessage(allocator, "Initial response");
    defer allocator.free(msg1.content);
    const msg2 = createAssistantMessage(allocator, "Processed 1");
    defer allocator.free(msg2.content);
    const msg3 = createAssistantMessage(allocator, "Processed 2");
    defer allocator.free(msg3.content);
    fp.setResponses(&.{ msg1, msg2, msg3 });

    var agent = Agent.init(allocator, .{
        .stream_fn = fauxStreamHook(&fp),
    });
    defer agent.deinit();

    // Initial prompt
    const prompts = [_]protocol.AgentMessage{makeUserMessage("Initial")};
    try agent.prompt(&prompts);

    // State: [user, assistant]
    try std.testing.expectEqual(@as(usize, 2), agent.state.messages.len);

    // Queue two steering messages
    agent.steer(makeUserMessage("Steering 1"));
    agent.steer(makeUserMessage("Steering 2"));

    // continue() drains first steering (one-at-a-time), runs loop.
    // The loop's getSteeringMessages poll drains the second.
    // pi-mono assertion: recentMessages.map(m => m.role) === ["user", "assistant", "user", "assistant"]
    // and responseCount === 2
    try agent.@"continue"();

    // pi-mono: last 4 messages are [user, assistant, user, assistant]
    const len = agent.state.messages.len;
    try std.testing.expect(len >= 4);
    const recent = agent.state.messages[len - 4 .. len];
    try std.testing.expect(recent[0] == .user);
    try std.testing.expect(recent[1] == .assistant);
    try std.testing.expect(recent[2] == .user);
    try std.testing.expect(recent[3] == .assistant);

    // pi-mono: responseCount === 2 (two LLM calls during continue)
    // Initial prompt used 1 response, continue used 2 = 3 total
    try std.testing.expectEqual(@as(usize, 3), fp.call_count);
}

// ── contract: continue with seeded initial state (agent.test.ts:356-392) ──

test "Agent: continue processes follow-up from seeded initial state" {
    const allocator = std.testing.allocator;

    var fp = faux.FauxProvider.init(allocator);
    defer fp.deinit();

    const msg = createAssistantMessage(allocator, "Processed");
    defer allocator.free(msg.content);
    fp.setResponses(&.{msg});

    // Seed initial state with [user, assistant] — like pi-mono's agent.state.messages = [...]
    const initial_user = makeUserMessage("Initial");
    const initial_assistant_content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("Initial response")};
    const initial_assistant = faux.fauxAssistantMessage(allocator, &initial_assistant_content, .stop);
    defer allocator.free(initial_assistant.content);

    const initial_messages = [_]protocol.AgentMessage{
        initial_user,
        .{ .assistant = initial_assistant },
    };

    var agent = Agent.init(allocator, .{
        .stream_fn = fauxStreamHook(&fp),
        .initial_state = protocol.AgentState{
            .messages = &initial_messages,
        },
    });
    defer agent.deinit();

    // Verify initial state loaded
    try std.testing.expectEqual(@as(usize, 2), agent.state.messages.len);

    // Queue follow-up
    agent.followUp(makeUserMessage("Queued follow-up"));

    // continue() should drain follow-up since last message is assistant
    try agent.@"continue"();

    // pi-mono assertion: hasQueuedFollowUp === true (the follow-up user message exists)
    var has_follow_up = false;
    for (agent.state.messages) |m| {
        if (m == .user) {
            if (m.user.content == .text) {
                if (std.mem.eql(u8, m.user.content.text, "Queued follow-up")) {
                    has_follow_up = true;
                }
            }
        }
    }
    try std.testing.expect(has_follow_up);

    // pi-mono: last message should be assistant
    const last = agent.state.messages[agent.state.messages.len - 1];
    try std.testing.expect(last == .assistant);
}

// ── contract: agentLoopContinue errors bubble through Agent.continue ──

test "Agent: continue returns error on empty messages" {
    const allocator = std.testing.allocator;
    var agent = Agent.init(allocator, .{});
    defer agent.deinit();

    const result = agent.@"continue"();
    try std.testing.expectError(error.NoMessages, result);
}

test "Agent: continue returns error on assistant tail with no queued messages" {
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

    // Last message is assistant, no steering or follow-up queued
    const result = agent.@"continue"();
    try std.testing.expectError(error.CannotContinueFromAssistant, result);
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

// ── test 4: continue returns error when called while running ──

test "Agent: continue returns error when called while running" {
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

    const GuardState = struct {
        agent_ptr: *Agent,
        nested_rejected: bool = false,
    };
    var guard_state = GuardState{ .agent_ptr = &agent };

    const GuardListener = struct {
        fn listener(event: protocol.AgentEvent, ctx: ?*anyopaque) void {
            const s: *GuardState = @ptrCast(@alignCast(ctx.?));
            if (event == .agent_start) {
                const result = s.agent_ptr.@"continue"();
                if (result) |_| {} else |err| {
                    if (err == error.AlreadyProcessing) {
                        s.nested_rejected = true;
                    }
                }
            }
        }
    };

    _ = agent.subscribe(GuardListener.listener, @ptrCast(&guard_state));

    const prompts = [_]protocol.AgentMessage{makeUserMessage("hello")};
    try agent.prompt(&prompts);

    try std.testing.expect(guard_state.nested_rejected);
}

// ── test 5: custom initial state loads config fields ──

test "Agent: custom initial state loads config fields" {
    const allocator = std.testing.allocator;

    var state = protocol.AgentState{
        .system_prompt = "Custom system prompt",

        .thinking_level = .high,
    };
    _ = &state;

    var agent = Agent.init(allocator, .{
        .initial_state = state,
    });
    defer agent.deinit();

    try std.testing.expectEqualStrings("Custom system prompt", agent.state.system_prompt);
    try std.testing.expectEqual(protocol.ThinkingLevel.high, agent.state.thinking_level);
}

// ── test 6: subscribe and unsubscribe ──

test "Agent: unsubscribe stops listener notifications" {
    const allocator = std.testing.allocator;

    var fp = faux.FauxProvider.init(allocator);
    defer fp.deinit();

    const msg1 = createAssistantMessage(allocator, "first");
    defer allocator.free(msg1.content);
    const msg2 = createAssistantMessage(allocator, "second");
    defer allocator.free(msg2.content);
    fp.setResponses(&.{ msg1, msg2 });

    var agent = Agent.init(allocator, .{
        .stream_fn = fauxStreamHook(&fp),
    });
    defer agent.deinit();

    var event_count: usize = 0;
    const Counter = struct {
        fn listener(_: protocol.AgentEvent, ctx: ?*anyopaque) void {
            const count: *usize = @ptrCast(@alignCast(ctx.?));
            count.* += 1;
        }
    };
    const token = agent.subscribe(Counter.listener, @ptrCast(&event_count));

    // First prompt — listener should fire
    const prompts1 = [_]protocol.AgentMessage{makeUserMessage("first")};
    try agent.prompt(&prompts1);
    const count_after_first = event_count;
    try std.testing.expect(count_after_first > 0);

    // Unsubscribe
    agent.unsubscribe(token);

    // Second prompt — listener should NOT fire
    const prompts2 = [_]protocol.AgentMessage{makeUserMessage("second")};
    try agent.prompt(&prompts2);
    try std.testing.expectEqual(count_after_first, event_count);
}

// ── test 7: sessionId forwarded to streamFn options ──

test "Agent: sessionId forwarded to streamFn options" {
    const allocator = std.testing.allocator;

    var fp = faux.FauxProvider.init(allocator);
    defer fp.deinit();

    const msg = createAssistantMessage(allocator, "ok");
    defer allocator.free(msg.content);
    fp.setResponses(&.{msg});

    const CaptureState = struct {
        captured_session_id: ?[]const u8 = null,
        fp_ptr: *faux.FauxProvider,
    };
    var capture = CaptureState{ .fp_ptr = &fp };

    const capturingStreamFn = struct {
        fn func(
            ctx: ?*anyopaque,
            alloc: std.mem.Allocator,
            model: ai.protocol.Model,
            context: ai.protocol.Context,
            options: ai.protocol.SimpleStreamOptions,
            callback: ai.provider.EventCallback,
            callback_ctx: ?*anyopaque,
        ) void {
            const s: *CaptureState = @ptrCast(@alignCast(ctx.?));
            s.captured_session_id = options.base.session_id;
            const prov = s.fp_ptr.provider();
            prov.streamSimple(alloc, model, context, options, callback, callback_ctx);
        }
    }.func;

    var agent = Agent.init(allocator, .{
        .stream_fn = .{ .func = capturingStreamFn, .ctx = @ptrCast(&capture) },
        .session_id = "session-abc",
    });
    defer agent.deinit();

    const prompts = [_]protocol.AgentMessage{makeUserMessage("hello")};
    try agent.prompt(&prompts);

    try std.testing.expect(capture.captured_session_id != null);
    try std.testing.expectEqualStrings("session-abc", capture.captured_session_id.?);
}
