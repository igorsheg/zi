const std = @import("std");
const ai = @import("ai/root.zig");
const agent_mod = @import("agent/root.zig");
const session_mod = @import("session/root.zig");
const bash_tool = @import("tools/bash.zig");
const system_prompt_mod = @import("system_prompt.zig");
const auth_storage_mod = @import("auth/storage.zig");

const protocol = agent_mod.protocol;
const Agent = agent_mod.Agent;
const SubscriptionToken = agent_mod.SubscriptionToken;
pub const SessionStore = session_mod.store.SessionStore;

/// Composition root: wires Agent + SessionStore + tools + model resolution.
///
/// pi-mono equivalent: packages/coding-agent/src/core/sdk.ts (createAgentSession)
/// + packages/coding-agent/src/core/agent-session.ts (AgentSession)
///
/// Owns:
/// - Agent (dual-loop, tool pipeline, event system)
/// - SessionStore (JSONL persistence + context building)
/// - Tool registry (bash + future tools)
/// - convertToLlm that handles compaction_summary, branch_summary, custom
/// - transformContext hook point (wired but no-op until compaction lands)
/// - Stream hook wrapping provider registry
pub const AgentSession = struct {
    agent: Agent,
    session_store: SessionStore,
    allocator: std.mem.Allocator,
    tools: []const protocol.AgentTool,
    event_handler: ?EventHandler,
    _subscription_token: ?SubscriptionToken,
    _stream_closure: *StreamClosure,
    auth_storage: ?*auth_storage_mod.AuthStorage,

    pub const EventHandler = struct {
        func: *const fn (event: protocol.AgentEvent, ctx: ?*anyopaque) void,
        ctx: ?*anyopaque = null,
    };

    pub const Options = struct {
        model: ai.protocol.Model,
        api_key: []const u8,
        cwd: []const u8,
        system_prompt: ?[]const u8 = null,
        context_files: []const system_prompt_mod.ContextFile = &.{},
        max_tokens: ?u64 = 4096,
        tools: ?[]const protocol.AgentTool = null,
        registry: *ai.provider.Registry,
        event_handler: ?EventHandler = null,
        auth_storage: ?*auth_storage_mod.AuthStorage = null,
        /// Seed with existing messages for --continue.
        initial_messages: []const protocol.AgentMessage = &.{},
        /// Pre-built session store (from SessionStore.open for --continue).
        /// If null, a new session is created for `cwd`.
        session_store: ?SessionStore = null,
        no_session: bool = false,
        append_system_prompt: ?[]const u8 = null,
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) AgentSession {
        const tools = options.tools orelse blk: {
            const t = allocator.alloc(protocol.AgentTool, 1) catch break :blk @as([]const protocol.AgentTool, &.{});
            t[0] = bash_tool.makeTool();
            break :blk @as([]const protocol.AgentTool, t);
        };

        const store = options.session_store orelse if (options.no_session)
            SessionStore.createEphemeral(allocator)
        else
            SessionStore.create(allocator, options.cwd);

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

        const tool_name_slice: []const []const u8 = blk: {
            const tn = allocator.alloc([]const u8, tools.len) catch break :blk &.{};
            for (tools, 0..) |t, i| tn[i] = t.name;
            break :blk tn;
        };

        const sys_prompt = blk: {
            if (options.system_prompt) |custom| {
                break :blk system_prompt_mod.buildSystemPrompt(allocator, .{
                    .custom_prompt = custom,
                    .cwd = options.cwd,
                    .context_files = options.context_files,
                    .tool_names = tool_name_slice,
                    .append_system_prompt = options.append_system_prompt,
                }) catch custom;
            }
            break :blk system_prompt_mod.buildSystemPrompt(allocator, .{
                .cwd = options.cwd,
                .tool_names = tool_name_slice,
                .context_files = options.context_files,
                .append_system_prompt = options.append_system_prompt,
            }) catch "You are a helpful coding assistant.";
        };

        const get_api_key_hook: ?protocol.GetApiKeyHook = if (options.auth_storage) |as| .{
            .func = &getApiKeyFromStorage,
            .ctx = @ptrCast(@constCast(as)),
        } else null;

        const a = Agent.init(allocator, .{
            .initial_state = .{
                .system_prompt = sys_prompt,
                .model = options.model,
                .tools = tools,
                .messages = options.initial_messages,
            },
            .convert_to_llm = .{ .func = &convertToLlm, .ctx = null },
            .stream_fn = stream_hook,
            .session_id = if (options.session_store) |s| s.sessionId() else null,
            .get_api_key = get_api_key_hook,
        });

        const self = AgentSession{
            .agent = a,
            .session_store = store,
            .allocator = allocator,
            .tools = tools,
            .event_handler = options.event_handler,
            ._subscription_token = null,
            ._stream_closure = closure,
            .auth_storage = options.auth_storage,
        };

        // Subscribe for session persistence: write message_end entries.
        // We use a pointer to self, so self must be pinned after init.
        // The caller must not move self after calling init.
        // We'll wire this up in run/continueSession instead.

        return self;
    }

    pub fn deinit(self: *AgentSession) void {
        if (self._subscription_token) |token| {
            self.agent.unsubscribe(token);
        }
        self.allocator.destroy(self._stream_closure);
        self.agent.deinit();
    }

    /// Subscribe the session persistence listener.
    /// Must be called after self is pinned (not moved).
    fn wireSubscription(self: *AgentSession) void {
        if (self._subscription_token != null) return;
        self._subscription_token = self.agent.subscribe(&eventListener, @ptrCast(self));
    }

    /// Run a new prompt. Wires session persistence, then delegates to Agent.prompt.
    pub fn run(self: *AgentSession, prompt_text: []const u8) !void {
        self.wireSubscription();

        const user_msg = protocol.AgentMessage{
            .user = .{
                .content = .{ .text = prompt_text },
                .timestamp = std.time.milliTimestamp(),
            },
        };
        const prompts = [_]protocol.AgentMessage{user_msg};
        try self.agent.prompt(&prompts);
    }

    /// Continue from loaded session context.
    /// Expects initial_messages were seeded via Options.
    /// If transcript ends with assistant (nothing to continue from),
    /// returns NeedsPrompt so the caller can provide one.
    pub fn continueSession(self: *AgentSession) !void {
        self.wireSubscription();
        self.agent.@"continue"() catch |err| switch (err) {
            error.CannotContinueFromAssistant => return error.NeedsPrompt,
            else => return err,
        };
    }

    /// Get session file path (valid after first flush).
    pub fn getSessionFile(self: *const AgentSession) []const u8 {
        return self.session_store.sessionFile();
    }

    pub fn sessionFlushed(self: *const AgentSession) bool {
        return self.session_store.writer.flushed;
    }

    /// Event listener: forwards to user-provided handler, then persists.
    /// pi-mono ordering: extensions → listeners → persistence (agent-session.ts:507-530)
    fn eventListener(event: protocol.AgentEvent, ctx: ?*anyopaque) void {
        const self: *AgentSession = @ptrCast(@alignCast(ctx));

        // Forward to external handler first
        if (self.event_handler) |handler| {
            handler.func(event, handler.ctx);
        }

        // Session persistence on message_end
        switch (event) {
            .message_end => |me| {
                self.session_store.appendMessage(me.message);
            },
            else => {},
        }
    }

    // -- Stream hook wrapping provider registry + auth -----------------------
    // pi-mono injects auth in the streamFn closure (sdk.ts:274-283).
    // We do the same: capture registry + api_key so the Agent doesn't need
    // to thread auth through AgentLoopConfig.

    fn getApiKeyFromStorage(provider_str: []const u8, ctx: ?*anyopaque) ?[]const u8 {
        const storage: *auth_storage_mod.AuthStorage = @ptrCast(@alignCast(ctx.?));
        return storage.getApiKey(provider_str);
    }

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
            if (opts.base.api_key == null or opts.base.api_key.?.len == 0) {
                opts.base.api_key = self.api_key;
            }
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

/// Open a session file and build context for --continue.
/// Returns a SessionStore (ready for appending) and the resolved context.
///
/// pi-mono: SessionManager.buildSessionContext → Agent.state.messages = existingSession.messages
pub fn openSession(
    allocator: std.mem.Allocator,
    session_path: []const u8,
) !struct {
    store: SessionStore,
    messages: []protocol.AgentMessage,
    model: ?session_mod.context.SessionContext.ModelInfo,
    thinking_level: []const u8,
} {
    var store = try SessionStore.open(allocator, session_path);
    const ctx = try store.buildContext(null);
    return .{
        .store = store,
        .messages = ctx.messages,
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

// ── AgentSession e2e tests (ported from pi-mono test-harness.test.ts) ───

const faux = ai.faux;

/// Test helper: create a AgentSession wired to a faux provider.
fn createTestAgentSession(
    allocator: std.mem.Allocator,
    _: *faux.FauxProvider,
    registry: *ai.provider.Registry,
    collector: *EventCollector,
) AgentSession {
    return AgentSession.init(allocator, .{
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

    fn getTextDeltas(self: *const EventCollector) []const []const u8 {
        var deltas: std.ArrayListUnmanaged([]const u8) = .empty;
        for (self.events.items) |e| {
            if (e == .message_update) {
                if (e.message_update.assistant_message_event == .text_delta) {
                    deltas.append(self.alloc, e.message_update.assistant_message_event.text_delta.delta) catch {};
                }
            }
        }
        return deltas.items;
    }
};

// pi-mono test-harness.test.ts: "simple text response"
test "AgentSession: simple text response" {
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
    var ca = createTestAgentSession(allocator, &fp, &registry, &collector);
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
test "AgentSession: error response sets stop_reason" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fp = faux.FauxProvider.init(allocator);
    const err_msg = faux.fauxAssistantMessage(allocator, &.{}, .@"error");
    fp.setResponses(&.{err_msg});

    var registry = ai.provider.Registry.init(allocator);
    try registry.register("faux", fp.provider(), null);

    var collector = EventCollector.init(allocator);
    var ca = createTestAgentSession(allocator, &fp, &registry, &collector);
    defer ca.deinit();

    ca.run("hi");

    try testing.expectEqual(@as(usize, 1), fp.call_count);
    try testing.expectEqual(@as(usize, 2), ca.agent.state.messages.len);
    const assistant = ca.agent.state.messages[1].assistant;
    try testing.expectEqual(ai.protocol.StopReason.@"error", assistant.stop_reason);
}

// pi-mono test-harness.test.ts: "event capture"
test "AgentSession: events emitted in correct order" {
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
    var ca = createTestAgentSession(allocator, &fp, &registry, &collector);
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
test "AgentSession: response sequence across multiple prompts" {
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
    var ca = createTestAgentSession(allocator, &fp, &registry, &collector);
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
test "AgentSession: session persistence round-trip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fp = faux.FauxProvider.init(allocator);
    const content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("persisted response")};
    fp.setResponses(&.{faux.fauxAssistantMessage(allocator, &content, .stop)});

    var registry = ai.provider.Registry.init(allocator);
    try registry.register("faux", fp.provider(), null);

    var collector = EventCollector.init(allocator);
    var ca = createTestAgentSession(allocator, &fp, &registry, &collector);
    defer ca.deinit();

    ca.run("persist me");

    // Session should have been flushed (assistant message triggers flush)
    try testing.expect(ca.sessionFlushed());
    const session_file = ca.getSessionFile();

    // Read back the session file
    const loaded = try openSession(allocator, session_file);
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

// tool call round-trip: faux returns tool_call → tool executes → faux called again
test "AgentSession: tool call triggers execution and second LLM call" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fp = faux.FauxProvider.init(allocator);

    // First response: tool call
    const tc_content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{
        faux.fauxToolCall("echo", "tc-1", .null),
    };
    // Second response: text after tool result
    const text_content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("done after tool")};
    fp.setResponses(&.{
        faux.fauxAssistantMessage(allocator, &tc_content, .toolUse),
        faux.fauxAssistantMessage(allocator, &text_content, .stop),
    });

    var registry = ai.provider.Registry.init(allocator);
    try registry.register("faux", fp.provider(), null);

    // Simple echo tool
    const echo_tool = protocol.AgentTool{
        .name = "echo",
        .description = "echo",
        .label = "echo",
        .parameters = .null,
        .execute = &struct {
            fn exec(_: ?*anyopaque, alloc: std.mem.Allocator, _: []const u8, _: std.json.Value, _: protocol.AbortSignal, _: ?protocol.AgentToolUpdateCallback, _: ?*anyopaque) protocol.AgentToolResult {
                const c = alloc.alloc(protocol.AgentToolResult.ContentBlock, 1) catch return .{ .content = &.{} };
                c[0] = .{ .text = .{ .text = "echoed" } };
                return .{ .content = c };
            }
        }.exec,
    };
    const tools = [_]protocol.AgentTool{echo_tool};

    var collector = EventCollector.init(allocator);
    var ca = AgentSession.init(allocator, .{
        .model = faux.fauxModel(),
        .api_key = "test-key",
        .cwd = "/tmp/zi-test",
        .registry = &registry,
        .tools = &tools,
        .event_handler = .{ .func = &EventCollector.callback, .ctx = @ptrCast(&collector) },
    });
    defer ca.deinit();

    ca.run("use the tool");

    // Faux called twice: once for tool call, once after tool result
    try testing.expectEqual(@as(usize, 2), fp.call_count);

    // Messages: user, assistant(tool_call), tool_result, assistant(text)
    try testing.expectEqual(@as(usize, 4), ca.agent.state.messages.len);
    try testing.expect(ca.agent.state.messages[0] == .user);
    try testing.expect(ca.agent.state.messages[1] == .assistant);
    try testing.expect(ca.agent.state.messages[2] == .tool_result);
    try testing.expect(ca.agent.state.messages[3] == .assistant);

    // Verify tool result content
    const tr = ca.agent.state.messages[2].tool_result;
    try testing.expectEqualStrings("echo", tr.tool_name);
    try testing.expectEqual(@as(usize, 1), tr.content.len);

    // Verify tool_execution events fired
    try testing.expect(collector.countType(.tool_execution_start) >= 1);
    try testing.expect(collector.countType(.tool_execution_end) >= 1);
}

// --continue round-trip: write session → load → continue → verify context sent to provider
test "AgentSession: continue sends restored context to provider" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Phase 1: create a session with one exchange
    var fp1 = faux.FauxProvider.init(allocator);
    const c1 = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("first response")};
    fp1.setResponses(&.{faux.fauxAssistantMessage(allocator, &c1, .stop)});

    var reg1 = ai.provider.Registry.init(allocator);
    try reg1.register("faux", fp1.provider(), null);

    var col1 = EventCollector.init(allocator);
    var ca1 = AgentSession.init(allocator, .{
        .model = faux.fauxModel(),
        .api_key = "test-key",
        .cwd = "/tmp/zi-test",
        .registry = &reg1,
        .tools = &.{},
        .event_handler = .{ .func = &EventCollector.callback, .ctx = @ptrCast(&col1) },
    });
    defer ca1.deinit();

    ca1.run("hello");
    try testing.expect(ca1.sessionFlushed());
    const session_file = ca1.getSessionFile();

    // Phase 2: load the session and continue with a new user message
    const loaded = try openSession(allocator, session_file);
    try testing.expectEqual(@as(usize, 2), loaded.messages.len);

    var fp2 = faux.FauxProvider.init(allocator);
    const c2 = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("continued response")};
    fp2.setResponses(&.{faux.fauxAssistantMessage(allocator, &c2, .stop)});

    var reg2 = ai.provider.Registry.init(allocator);
    try reg2.register("faux", fp2.provider(), null);

    var col2 = EventCollector.init(allocator);
    // Seed with loaded messages + a new user prompt
    const new_user = protocol.AgentMessage{ .user = .{
        .content = .{ .text = "follow up" },
        .timestamp = std.time.milliTimestamp(),
    } };
    var all_messages: std.ArrayListUnmanaged(protocol.AgentMessage) = .empty;
    try all_messages.appendSlice(allocator, loaded.messages);
    try all_messages.append(allocator, new_user);

    var ca2 = AgentSession.init(allocator, .{
        .model = faux.fauxModel(),
        .api_key = "test-key",
        .cwd = "/tmp/zi-test",
        .registry = &reg2,
        .tools = &.{},
        .event_handler = .{ .func = &EventCollector.callback, .ctx = @ptrCast(&col2) },
        .initial_messages = all_messages.items,
        .session_store = loaded.store,
    });
    defer ca2.deinit();

    // Continue — should send the full context to the provider
    try ca2.continueSession();

    try testing.expectEqual(@as(usize, 1), fp2.call_count);

    // Provider should have received context with restored messages
    try testing.expectEqual(@as(usize, 1), fp2.captured_contexts.items.len);
    const ctx = fp2.captured_contexts.items[0];
    // Context should have at least 3 LLM messages: user("hello"), assistant("first response"), user("follow up")
    try testing.expect(ctx.messages.len >= 3);

    // Clean up
    std.fs.deleteFileAbsolute(session_file) catch {};
}

// convertToLlm through the loop: compaction_summary in initial state → provider receives wrapped text
test "AgentSession: compaction_summary converted to user message for provider" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fp = faux.FauxProvider.init(allocator);
    const c = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("ok")};
    fp.setResponses(&.{faux.fauxAssistantMessage(allocator, &c, .stop)});

    var registry = ai.provider.Registry.init(allocator);
    try registry.register("faux", fp.provider(), null);

    var collector = EventCollector.init(allocator);

    // Seed with compaction_summary + user message
    const initial = [_]protocol.AgentMessage{
        .{ .compaction_summary = .{ .summary = "Previous work done", .tokens_before = 5000, .timestamp = 1 } },
        .{ .user = .{ .content = .{ .text = "next question" }, .timestamp = 2 } },
    };

    var ca = AgentSession.init(allocator, .{
        .model = faux.fauxModel(),
        .api_key = "test-key",
        .cwd = "/tmp/zi-test",
        .registry = &registry,
        .tools = &.{},
        .event_handler = .{ .func = &EventCollector.callback, .ctx = @ptrCast(&collector) },
        .initial_messages = &initial,
    });
    defer ca.deinit();

    // Continue from the seeded state (last message is user, so continue works)
    try ca.continueSession();

    try testing.expectEqual(@as(usize, 1), fp.call_count);
    try testing.expectEqual(@as(usize, 1), fp.captured_contexts.items.len);

    const ctx = fp.captured_contexts.items[0];
    // convertToLlm should have converted compaction_summary → user message with <summary> tags
    // So provider sees: user(compaction), user("next question") = 2 messages
    try testing.expectEqual(@as(usize, 2), ctx.messages.len);
    try testing.expect(ctx.messages[0] == .user);
    try testing.expect(ctx.messages[1] == .user);

    // First message should contain the summary wrapped in tags
    const first_user = ctx.messages[0].user;
    switch (first_user.content) {
        .blocks => |blocks| {
            try testing.expect(blocks.len > 0);
            const text = blocks[0].text.text;
            try testing.expect(std.mem.indexOf(u8, text, "<summary>") != null);
            try testing.expect(std.mem.indexOf(u8, text, "Previous work done") != null);
        },
        .text => |t| {
            try testing.expect(std.mem.indexOf(u8, t, "<summary>") != null);
        },
    }
}

// pi-mono test-harness.test.ts: "context capture"
test "AgentSession: context capture — provider receives user message" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fp = faux.FauxProvider.init(allocator);
    const c = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("reply")};
    fp.setResponses(&.{faux.fauxAssistantMessage(allocator, &c, .stop)});

    var registry = ai.provider.Registry.init(allocator);
    try registry.register("faux", fp.provider(), null);

    var collector = EventCollector.init(allocator);
    var ca = createTestAgentSession(allocator, &fp, &registry, &collector);
    defer ca.deinit();

    ca.run("my question");

    try testing.expectEqual(@as(usize, 1), fp.captured_contexts.items.len);
    const ctx = fp.captured_contexts.items[0];
    // Should contain user message
    var found_user = false;
    for (ctx.messages) |m| {
        if (m == .user) {
            found_user = true;
            break;
        }
    }
    try testing.expect(found_user);
}

// pi-mono test-harness.test.ts: "streams text deltas"
test "AgentSession: text deltas reconstruct full response" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fp = faux.FauxProvider.init(allocator);
    const c = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("hello world")};
    fp.setResponses(&.{faux.fauxAssistantMessage(allocator, &c, .stop)});

    var registry = ai.provider.Registry.init(allocator);
    try registry.register("faux", fp.provider(), null);

    var collector = EventCollector.init(allocator);
    var ca = createTestAgentSession(allocator, &fp, &registry, &collector);
    defer ca.deinit();

    ca.run("hi");

    const deltas = collector.getTextDeltas();
    try testing.expect(deltas.len > 0);

    // Reconstruct — faux sends full text as one delta
    var total_len: usize = 0;
    for (deltas) |d| total_len += d.len;
    var buf = try allocator.alloc(u8, total_len);
    var pos: usize = 0;
    for (deltas) |d| {
        @memcpy(buf[pos..][0..d.len], d);
        pos += d.len;
    }
    try testing.expectEqualStrings("hello world", buf);
}

// pi-mono test-harness.test.ts: "streams thinking deltas"
test "AgentSession: thinking events emitted for thinking content" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fp = faux.FauxProvider.init(allocator);
    const c = [_]ai.protocol.AssistantMessage.AssistantContentBlock{
        .{ .thinking = .{ .thinking = "let me think" } },
        faux.fauxText("answer"),
    };
    fp.setResponses(&.{faux.fauxAssistantMessage(allocator, &c, .stop)});

    var registry = ai.provider.Registry.init(allocator);
    try registry.register("faux", fp.provider(), null);

    var collector = EventCollector.init(allocator);
    var ca = createTestAgentSession(allocator, &fp, &registry, &collector);
    defer ca.deinit();

    ca.run("hi");

    // Check for thinking events in message_update
    var thinking_starts: usize = 0;
    var thinking_deltas: usize = 0;
    var thinking_ends: usize = 0;
    for (collector.events.items) |e| {
        if (e == .message_update) {
            const ame = e.message_update.assistant_message_event;
            if (ame == .thinking_start) thinking_starts += 1;
            if (ame == .thinking_delta) thinking_deltas += 1;
            if (ame == .thinking_end) thinking_ends += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), thinking_starts);
    try testing.expect(thinking_deltas > 0);
    try testing.expectEqual(@as(usize, 1), thinking_ends);
}

test "resumed session context is sent to LLM" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Simulate a prior conversation (user + assistant)
    const prior_assistant_content = allocator.alloc(ai.protocol.AssistantMessage.AssistantContentBlock, 1) catch unreachable;
    prior_assistant_content[0] = faux.fauxText("I explained X");

    const prior_messages = &[_]protocol.AgentMessage{
        .{ .user = .{ .content = .{ .text = "explain X" }, .timestamp = 1 } },
        .{ .assistant = .{
            .content = prior_assistant_content,
            .api = .{ .custom = "faux" },
            .provider = .{ .custom = "faux" },
            .model = "faux-model",
            .usage = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total_tokens = 0, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 } },
            .stop_reason = .stop,
            .timestamp = 2,
        } },
    };

    var fp = faux.FauxProvider.init(allocator);
    const reply_content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("follow-up answer")};
    fp.setResponses(&.{faux.fauxAssistantMessage(allocator, &reply_content, .stop)});

    var registry = ai.provider.Registry.init(allocator);
    try registry.register("faux", fp.provider(), null);

    var collector = EventCollector.init(allocator);
    var ca = createTestAgentSession(allocator, &fp, &registry, &collector);
    defer ca.deinit();

    // Simulate /resume: load prior messages into agent
    ca.agent.loadMessages(prior_messages);
    try testing.expectEqual(@as(usize, 2), ca.agent.state.messages.len);

    // Send a new prompt (the "follow-up" after resume)
    ca.run("now explain Y");

    // The LLM should have received the full context: prior user + prior assistant + new user
    try testing.expectEqual(@as(usize, 1), fp.call_count);
    const ctx = fp.captured_contexts.items[0];
    // convertToLlm maps AgentMessage → LLM Message; prior user + prior assistant + new user = 3
    try testing.expectEqual(@as(usize, 3), ctx.messages.len);
    try testing.expect(ctx.messages[0] == .user);
    try testing.expect(ctx.messages[1] == .assistant);
    try testing.expect(ctx.messages[2] == .user);
}
