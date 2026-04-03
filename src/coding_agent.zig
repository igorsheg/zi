const std = @import("std");
const ai = @import("ai/root.zig");
const agent_mod = @import("agent/root.zig");
const session_mod = @import("session/root.zig");
const bash_tool = @import("tools/bash.zig");

const protocol = agent_mod.protocol;
const Agent = agent_mod.Agent;
const SubscriptionToken = agent_mod.SubscriptionToken;
const SessionWriter = session_mod.writer.SessionWriter;

/// Composition root: wires Agent + SessionWriter + tools + model resolution.
///
/// pi-mono equivalent: packages/coding-agent/src/core/sdk.ts (createAgentSession)
/// + packages/coding-agent/src/core/agent-session.ts (AgentSession)
///
/// Owns:
/// - Agent (dual-loop, tool pipeline, event system)
/// - SessionWriter (JSONL persistence gated on first assistant message)
/// - Tool registry (bash + future tools)
/// - convertToLlm that handles compaction_summary, branch_summary, custom
/// - transformContext hook point (wired but no-op until compaction lands)
/// - Stream hook wrapping provider registry
pub const CodingAgent = struct {
    agent: Agent,
    session_writer: SessionWriter,
    allocator: std.mem.Allocator,
    tools: []const protocol.AgentTool,
    event_handler: ?EventHandler,
    _subscription_token: ?SubscriptionToken,
    _stream_closure: *StreamClosure,

    pub const EventHandler = struct {
        func: *const fn (event: protocol.AgentEvent, ctx: ?*anyopaque) void,
        ctx: ?*anyopaque = null,
    };

    pub const Options = struct {
        model: ai.protocol.Model,
        api_key: []const u8,
        cwd: []const u8,
        system_prompt: []const u8 = "You are a helpful assistant. Be concise. You have access to a bash tool to execute commands.",
        max_tokens: ?u64 = 4096,
        tools: ?[]const protocol.AgentTool = null,
        registry: *ai.provider.Registry,
        event_handler: ?EventHandler = null,
        /// Seed with existing messages for --continue.
        initial_messages: []const protocol.AgentMessage = &.{},
        session_id: ?[]const u8 = null,
        session_file: ?[]const u8 = null,
        leaf_id: ?[]const u8 = null,
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) CodingAgent {
        const tools = options.tools orelse blk: {
            const t = allocator.alloc(protocol.AgentTool, 1) catch break :blk @as([]const protocol.AgentTool, &.{});
            t[0] = bash_tool.makeTool();
            break :blk @as([]const protocol.AgentTool, t);
        };

        const sw = if (options.session_file != null)
            SessionWriter.initContinue(allocator, options.session_file.?, options.session_id.?, options.leaf_id)
        else
            SessionWriter.init(allocator, options.cwd);

        const closure = allocator.create(StreamClosure) catch @panic("OOM");
        closure.* = .{
            .registry = options.registry,
            .api_key = options.api_key,
            .max_tokens = options.max_tokens,
        };
        const stream_hook = protocol.StreamHook{
            .func = &StreamClosure.streamFn,
            .ctx = @ptrCast(closure),
        };

        const a = Agent.init(allocator, .{
            .initial_state = .{
                .system_prompt = options.system_prompt,
                .model = options.model,
                .tools = tools,
                .messages = options.initial_messages,
            },
            .convert_to_llm = .{ .func = &convertToLlm, .ctx = null },
            .stream_fn = stream_hook,
            .session_id = options.session_id,
        });

        const self = CodingAgent{
            .agent = a,
            .session_writer = sw,
            .allocator = allocator,
            .tools = tools,
            .event_handler = options.event_handler,
            ._subscription_token = null,
            ._stream_closure = closure,
        };

        // Subscribe for session persistence: write message_end entries.
        // We use a pointer to self, so self must be pinned after init.
        // The caller must not move self after calling init.
        // We'll wire this up in run/continueSession instead.

        return self;
    }

    pub fn deinit(self: *CodingAgent) void {
        if (self._subscription_token) |token| {
            self.agent.unsubscribe(token);
        }
        self.allocator.destroy(self._stream_closure);
        self.agent.deinit();
    }

    /// Subscribe the session persistence listener.
    /// Must be called after self is pinned (not moved).
    fn wireSubscription(self: *CodingAgent) void {
        if (self._subscription_token != null) return;
        self._subscription_token = self.agent.subscribe(&eventListener, @ptrCast(self));
    }

    /// Run a new prompt. Wires session persistence, then delegates to Agent.prompt.
    pub fn run(self: *CodingAgent, prompt_text: []const u8) void {
        self.wireSubscription();

        const user_msg = protocol.AgentMessage{
            .user = .{
                .content = .{ .text = prompt_text },
                .timestamp = std.time.milliTimestamp(),
            },
        };
        const prompts = [_]protocol.AgentMessage{user_msg};
        self.agent.prompt(&prompts) catch {};
    }

    /// Continue from loaded session context.
    /// Expects initial_messages were seeded via Options.
    /// If transcript ends with assistant (nothing to continue from),
    /// returns NeedsPrompt so the caller can provide one.
    pub fn continueSession(self: *CodingAgent) !void {
        self.wireSubscription();
        self.agent.@"continue"() catch |err| switch (err) {
            error.CannotContinueFromAssistant => return error.NeedsPrompt,
            else => return err,
        };
    }

    /// Get session file path (valid after first flush).
    pub fn getSessionFile(self: *const CodingAgent) []const u8 {
        return self.session_writer.session_file;
    }

    pub fn sessionFlushed(self: *const CodingAgent) bool {
        return self.session_writer.flushed;
    }

    /// Event listener: forwards to user-provided handler, then persists.
    /// pi-mono ordering: extensions → listeners → persistence (agent-session.ts:507-530)
    fn eventListener(event: protocol.AgentEvent, ctx: ?*anyopaque) void {
        const self: *CodingAgent = @ptrCast(@alignCast(ctx));

        // Forward to external handler first
        if (self.event_handler) |handler| {
            handler.func(event, handler.ctx);
        }

        // Session persistence on message_end
        switch (event) {
            .message_end => |me| {
                self.session_writer.appendMessage(me.message);
            },
            else => {},
        }
    }

    // -- Stream hook wrapping provider registry + auth -----------------------
    // pi-mono injects auth in the streamFn closure (sdk.ts:274-283).
    // We do the same: capture registry + api_key so the Agent doesn't need
    // to thread auth through AgentLoopConfig.

    const StreamClosure = struct {
        registry: *ai.provider.Registry,
        api_key: []const u8,
        max_tokens: ?u64,

        fn streamFn(
            ctx: ?*anyopaque,
            stream_alloc: std.mem.Allocator,
            model: ai.protocol.Model,
            stream_context: ai.protocol.Context,
            options: ai.protocol.SimpleStreamOptions,
            callback: ai.provider.EventCallback,
            callback_ctx: ?*anyopaque,
        ) void {
            const self: *const StreamClosure = @ptrCast(@alignCast(ctx.?));
            const api_str = ai.provider.apiToString(model.api);
            const prov = self.registry.get(api_str) orelse return;
            var opts = options;
            opts.base.api_key = self.api_key;
            if (self.max_tokens) |mt| opts.base.max_tokens = mt;
            prov.streamSimple(stream_alloc, model, stream_context, opts, callback, callback_ctx);
        }
    };
};

// ── convertToLlm ──────────────────────────────────────────────────────────
//
// pi-mono source: packages/coding-agent/src/core/messages.ts:148-195
// The base agent's defaultConvertToLlm silently drops compaction_summary,
// branch_summary, and custom. The coding agent's version converts them to
// user messages with the proper prefix/suffix wrapping.

const COMPACTION_SUMMARY_PREFIX =
    "The conversation history before this point was compacted into the following summary:\n\n<summary>\n";
const COMPACTION_SUMMARY_SUFFIX = "\n</summary>";

const BRANCH_SUMMARY_PREFIX =
    "The following is a summary of a branch that this conversation came back from:\n\n<summary>\n";
const BRANCH_SUMMARY_SUFFIX = "</summary>";

pub fn convertToLlm(
    allocator: std.mem.Allocator,
    messages: []const protocol.AgentMessage,
    _: ?*anyopaque,
) []const ai.protocol.Message {
    var result: std.ArrayList(ai.protocol.Message) = .empty;
    for (messages) |msg| {
        switch (msg) {
            .user => |u| result.append(allocator, .{ .user = u }) catch continue,
            .assistant => |a| result.append(allocator, .{ .assistant = a }) catch continue,
            .tool_result => |t| result.append(allocator, .{ .tool_result = t }) catch continue,
            .compaction_summary => |cs| {
                const text = std.fmt.allocPrint(
                    allocator,
                    "{s}{s}{s}",
                    .{ COMPACTION_SUMMARY_PREFIX, cs.summary, COMPACTION_SUMMARY_SUFFIX },
                ) catch continue;
                const blocks = allocator.alloc(ai.protocol.UserMessage.UserMessageContent.Block, 1) catch continue;
                blocks[0] = .{ .text = .{ .text = text } };
                result.append(allocator, .{ .user = .{
                    .content = .{ .blocks = blocks },
                    .timestamp = cs.timestamp,
                } }) catch continue;
            },
            .branch_summary => |bs| {
                const text = std.fmt.allocPrint(
                    allocator,
                    "{s}{s}{s}",
                    .{ BRANCH_SUMMARY_PREFIX, bs.summary, BRANCH_SUMMARY_SUFFIX },
                ) catch continue;
                const blocks = allocator.alloc(ai.protocol.UserMessage.UserMessageContent.Block, 1) catch continue;
                blocks[0] = .{ .text = .{ .text = text } };
                result.append(allocator, .{ .user = .{
                    .content = .{ .blocks = blocks },
                    .timestamp = bs.timestamp,
                } }) catch continue;
            },
            .custom => |c| {
                const user_content: ai.protocol.UserMessage.UserMessageContent = switch (c.content) {
                    .text => |t| blk: {
                        const blocks = allocator.alloc(ai.protocol.UserMessage.UserMessageContent.Block, 1) catch continue;
                        blocks[0] = .{ .text = .{ .text = t } };
                        break :blk .{ .blocks = blocks };
                    },
                    .blocks => |b| .{ .blocks = b },
                };
                result.append(allocator, .{ .user = .{
                    .content = user_content,
                    .timestamp = c.timestamp,
                } }) catch continue;
            },
        }
    }
    return result.items;
}

/// Load a session file and build context for --continue.
/// Returns messages that can be passed as CodingAgent.Options.initial_messages.
///
/// pi-mono: SessionManager.buildSessionContext → Agent.state.messages = existingSession.messages
pub fn loadSessionContext(
    allocator: std.mem.Allocator,
    session_path: []const u8,
) !struct {
    messages: []protocol.AgentMessage,
    session_id: ?[]const u8,
    leaf_id: ?[]const u8,
    model: ?session_mod.context.SessionContext.ModelInfo,
    thinking_level: []const u8,
} {
    const data = try session_mod.reader.readSessionFile(allocator, session_path);
    const ctx = try session_mod.context.buildSessionContext(allocator, data.entries, null);
    return .{
        .messages = ctx.messages,
        .session_id = if (data.header) |h| h.id else null,
        .leaf_id = if (data.entries.len > 0) data.entries[data.entries.len - 1].id else null,
        .model = ctx.model,
        .thinking_level = ctx.thinking_level,
    };
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "convertToLlm passes through user/assistant/tool_result" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const content = alloc.alloc(ai.protocol.AssistantMessage.AssistantContentBlock, 1) catch unreachable;
    content[0] = .{ .text = .{ .text = "hi" } };

    const messages = &[_]protocol.AgentMessage{
        .{ .user = .{ .content = .{ .text = "hello" }, .timestamp = 1 } },
        .{ .assistant = .{
            .content = content,
            .api = .anthropic_messages,
            .provider = .anthropic,
            .model = "test",
            .usage = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total_tokens = 0, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 } },
            .stop_reason = .stop,
            .timestamp = 2,
        } },
    };

    const result = convertToLlm(alloc, messages, null);
    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expect(result[0] == .user);
    try testing.expect(result[1] == .assistant);
}

test "convertToLlm wraps compaction_summary as user message" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const messages = &[_]protocol.AgentMessage{
        .{ .compaction_summary = .{ .summary = "Previous work summarized", .tokens_before = 5000, .timestamp = 1 } },
    };

    const result = convertToLlm(alloc, messages, null);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expect(result[0] == .user);

    // Verify the text contains prefix + summary + suffix
    const user = result[0].user;
    switch (user.content) {
        .blocks => |blocks| {
            try testing.expectEqual(@as(usize, 1), blocks.len);
            const text = blocks[0].text.text;
            try testing.expect(std.mem.indexOf(u8, text, "compacted into the following summary") != null);
            try testing.expect(std.mem.indexOf(u8, text, "Previous work summarized") != null);
            try testing.expect(std.mem.indexOf(u8, text, "<summary>") != null);
            try testing.expect(std.mem.indexOf(u8, text, "</summary>") != null);
        },
        .text => return error.ExpectedBlocks,
    }
}

test "convertToLlm wraps branch_summary as user message" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const messages = &[_]protocol.AgentMessage{
        .{ .branch_summary = .{ .summary = "Tried approach X", .from_id = "abc", .timestamp = 1 } },
    };

    const result = convertToLlm(alloc, messages, null);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expect(result[0] == .user);

    const user = result[0].user;
    switch (user.content) {
        .blocks => |blocks| {
            const text = blocks[0].text.text;
            try testing.expect(std.mem.indexOf(u8, text, "summary of a branch") != null);
            try testing.expect(std.mem.indexOf(u8, text, "Tried approach X") != null);
        },
        .text => return error.ExpectedBlocks,
    }
}

test "convertToLlm converts custom to user message" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const messages = &[_]protocol.AgentMessage{
        .{ .custom = .{ .custom_type = "skill", .content = .{ .text = "Do X" }, .display = true, .timestamp = 1 } },
    };

    const result = convertToLlm(alloc, messages, null);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expect(result[0] == .user);

    const user = result[0].user;
    switch (user.content) {
        .blocks => |blocks| {
            try testing.expectEqualStrings("Do X", blocks[0].text.text);
        },
        .text => return error.ExpectedBlocks,
    }
}

test "convertToLlm handles mixed message types in order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const content = alloc.alloc(ai.protocol.AssistantMessage.AssistantContentBlock, 1) catch unreachable;
    content[0] = .{ .text = .{ .text = "response" } };

    const messages = &[_]protocol.AgentMessage{
        .{ .compaction_summary = .{ .summary = "Summary", .tokens_before = 1000, .timestamp = 0 } },
        .{ .user = .{ .content = .{ .text = "question" }, .timestamp = 1 } },
        .{ .assistant = .{
            .content = content,
            .api = .anthropic_messages,
            .provider = .anthropic,
            .model = "test",
            .usage = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total_tokens = 0, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 } },
            .stop_reason = .stop,
            .timestamp = 2,
        } },
        .{ .branch_summary = .{ .summary = "Branch work", .from_id = "x", .timestamp = 3 } },
        .{ .custom = .{ .custom_type = "ext", .content = .{ .text = "Custom content" }, .timestamp = 4 } },
    };

    const result = convertToLlm(alloc, messages, null);
    try testing.expectEqual(@as(usize, 5), result.len);
    // All 5 should be present: compaction→user, user, assistant, branch→user, custom→user
    try testing.expect(result[0] == .user); // compaction
    try testing.expect(result[1] == .user); // original user
    try testing.expect(result[2] == .assistant);
    try testing.expect(result[3] == .user); // branch
    try testing.expect(result[4] == .user); // custom
}

// ── CodingAgent e2e tests (ported from pi-mono test-harness.test.ts) ───

const faux = ai.faux;

/// Test helper: create a CodingAgent wired to a faux provider.
fn createTestCodingAgent(
    allocator: std.mem.Allocator,
    _: *faux.FauxProvider,
    registry: *ai.provider.Registry,
    collector: *EventCollector,
) CodingAgent {
    return CodingAgent.init(allocator, .{
        .model = faux.fauxModel(),
        .api_key = "test-key",
        .cwd = "/tmp/zi-test",
        .registry = registry,
        .tools = &.{},
        .event_handler = .{ .func = &EventCollector.callback, .ctx = @ptrCast(collector) },
    });
}

const EventCollector = struct {
    events: std.ArrayListUnmanaged(protocol.AgentEvent),
    alloc: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator) EventCollector {
        return .{ .events = .empty, .alloc = alloc };
    }

    fn deinit(self: *EventCollector) void {
        self.events.deinit(self.alloc);
    }

    fn callback(event: protocol.AgentEvent, ctx: ?*anyopaque) void {
        const self: *EventCollector = @ptrCast(@alignCast(ctx));
        self.events.append(self.alloc, event) catch {};
    }

    fn countType(self: *const EventCollector, comptime tag: std.meta.Tag(protocol.AgentEvent)) usize {
        var n: usize = 0;
        for (self.events.items) |e| {
            if (e == tag) n += 1;
        }
        return n;
    }
};

// pi-mono test-harness.test.ts: "simple text response"
test "CodingAgent: simple text response" {
    // Use arena — SessionWriter allocates internally with no deinit
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fp = faux.FauxProvider.init(allocator);
    const content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("hello world")};
    const msg = faux.fauxAssistantMessage(allocator, &content, .stop);
    fp.setResponses(&.{msg});

    var registry = ai.provider.Registry.init(allocator);
    const prov = fp.provider();
    try registry.register("faux", prov, null);

    var collector = EventCollector.init(allocator);
    var ca = createTestCodingAgent(allocator, &fp, &registry, &collector);
    defer ca.deinit();

    ca.run("hi");

    try testing.expectEqual(@as(usize, 1), fp.call_count);
    try testing.expectEqual(@as(usize, 2), ca.agent.state.messages.len);
    try testing.expect(ca.agent.state.messages[0] == .user);
    try testing.expect(ca.agent.state.messages[1] == .assistant);

    const assistant = ca.agent.state.messages[1].assistant;
    try testing.expectEqual(@as(usize, 1), assistant.content.len);
    switch (assistant.content[0]) {
        .text => |t| try testing.expectEqualStrings("hello world", t.text),
        else => return error.ExpectedTextBlock,
    }
}

// pi-mono test-harness.test.ts: "error response"
test "CodingAgent: error response sets stop_reason" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fp = faux.FauxProvider.init(allocator);
    const err_msg = faux.fauxAssistantMessage(allocator, &.{}, .@"error");
    fp.setResponses(&.{err_msg});

    var registry = ai.provider.Registry.init(allocator);
    try registry.register("faux", fp.provider(), null);

    var collector = EventCollector.init(allocator);
    var ca = createTestCodingAgent(allocator, &fp, &registry, &collector);
    defer ca.deinit();

    ca.run("hi");

    try testing.expectEqual(@as(usize, 1), fp.call_count);
    try testing.expectEqual(@as(usize, 2), ca.agent.state.messages.len);
    const assistant = ca.agent.state.messages[1].assistant;
    try testing.expectEqual(ai.protocol.StopReason.@"error", assistant.stop_reason);
}

// pi-mono test-harness.test.ts: "event capture"
test "CodingAgent: events emitted in correct order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fp = faux.FauxProvider.init(allocator);
    const content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("hi")};
    const msg = faux.fauxAssistantMessage(allocator, &content, .stop);
    fp.setResponses(&.{msg});

    var registry = ai.provider.Registry.init(allocator);
    try registry.register("faux", fp.provider(), null);

    var collector = EventCollector.init(allocator);
    var ca = createTestCodingAgent(allocator, &fp, &registry, &collector);
    defer ca.deinit();

    ca.run("hello");

    // Should have: agent_start, turn_start, message_start(user), message_end(user),
    // message_start(assistant-stream), message_update*, message_end(assistant),
    // turn_end, agent_end
    try testing.expect(collector.countType(.agent_start) >= 1);
    try testing.expect(collector.countType(.agent_end) >= 1);
    try testing.expect(collector.countType(.message_end) >= 2); // user + assistant
    try testing.expect(collector.countType(.turn_end) >= 1);
}

// pi-mono test-harness.test.ts: "response sequence"
test "CodingAgent: response sequence across multiple prompts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fp = faux.FauxProvider.init(allocator);
    const c1 = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("first")};
    const c2 = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("second")};
    fp.setResponses(&.{
        faux.fauxAssistantMessage(allocator, &c1, .stop),
        faux.fauxAssistantMessage(allocator, &c2, .stop),
    });

    var registry = ai.provider.Registry.init(allocator);
    try registry.register("faux", fp.provider(), null);

    var collector = EventCollector.init(allocator);
    var ca = createTestCodingAgent(allocator, &fp, &registry, &collector);
    defer ca.deinit();

    ca.run("a");
    ca.run("b");

    try testing.expectEqual(@as(usize, 2), fp.call_count);
    try testing.expectEqual(@as(usize, 4), ca.agent.state.messages.len);
    // user, assistant("first"), user, assistant("second")
    const a1 = ca.agent.state.messages[1].assistant;
    switch (a1.content[0]) {
        .text => |t| try testing.expectEqualStrings("first", t.text),
        else => return error.ExpectedText,
    }
    const a2 = ca.agent.state.messages[3].assistant;
    switch (a2.content[0]) {
        .text => |t| try testing.expectEqualStrings("second", t.text),
        else => return error.ExpectedText,
    }
}

// session persistence: prompt → JSONL written → read back → context matches
test "CodingAgent: session persistence round-trip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fp = faux.FauxProvider.init(allocator);
    const content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("persisted response")};
    fp.setResponses(&.{faux.fauxAssistantMessage(allocator, &content, .stop)});

    var registry = ai.provider.Registry.init(allocator);
    try registry.register("faux", fp.provider(), null);

    var collector = EventCollector.init(allocator);
    var ca = createTestCodingAgent(allocator, &fp, &registry, &collector);
    defer ca.deinit();

    ca.run("persist me");

    // Session should have been flushed (assistant message triggers flush)
    try testing.expect(ca.sessionFlushed());
    const session_file = ca.getSessionFile();

    // Read back the session file
    const loaded = try loadSessionContext(allocator, session_file);
    try testing.expectEqual(@as(usize, 2), loaded.messages.len);

    // First message: user
    try testing.expect(loaded.messages[0] == .user);
    switch (loaded.messages[0].user.content) {
        .text => |t| try testing.expectEqualStrings("persist me", t),
        .blocks => |b| {
            try testing.expectEqual(@as(usize, 1), b.len);
            try testing.expectEqualStrings("persist me", b[0].text.text);
        },
    }

    // Second message: assistant with correct text
    try testing.expect(loaded.messages[1] == .assistant);
    const a = loaded.messages[1].assistant;
    try testing.expectEqual(@as(usize, 1), a.content.len);
    switch (a.content[0]) {
        .text => |t| try testing.expectEqualStrings("persisted response", t.text),
        else => return error.ExpectedTextBlock,
    }

    // Clean up the session file
    std.fs.deleteFileAbsolute(session_file) catch {};
}
