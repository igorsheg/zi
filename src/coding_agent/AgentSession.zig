const std = @import("std");
const ai = @import("../ai/root.zig");
const agent_api = @import("../agent/root.zig");
const ai_failure = ai.failure;
const ai_message = ai.message;
const ai_model = ai.model;
const Agent = agent_api.Agent;
const agent_limits = agent_api.limits;
const tool_api = agent_api.tool;
const ToolsModule = @import("Tools.zig");
const Session = @import("Session.zig");
const SessionFormat = @import("SessionFormat.zig");
const SessionCommit = Session.Commit;
const Prompt = @import("Prompt.zig");
const SystemPrompt = Prompt.SystemPrompt;

pub const Availability = enum {
    ready,
    poisoned,
};

pub const AgentSettled = struct {
    run_id: agent_api.event.RunId,
    availability: Availability,
};

/// Coding-agent events extend the core agent lifecycle without replacing its
/// payloads. The repeated tags keep consumption flat while the shared payload
/// declarations prevent a second event vocabulary.
pub const Event = union(enum) {
    agent_start: agent_api.event.AgentStart,
    agent_end: agent_api.event.AgentEnd,
    turn_start: agent_api.event.TurnStart,
    turn_end: agent_api.event.TurnEnd,
    message_start: agent_api.event.MessageStart,
    message_update: agent_api.event.MessageUpdate,
    message_end: agent_api.event.MessageFinished,
    tool_execution_start: agent_api.event.ToolExecutionStart,
    tool_execution_end: agent_api.event.ToolExecutionEnd,
    agent_settled: AgentSettled,
};

pub const SinkError = agent_api.event.SinkError;

/// Event payload slices are borrowed for the duration of `emitFn`.
pub const Sink = struct {
    context: *anyopaque,
    emitFn: *const fn (context: *anyopaque, event: Event) SinkError!void,

    pub fn emit(self: Sink, event: Event) SinkError!void {
        return self.emitFn(self.context, event);
    }
};

pub fn fromAgent(value: agent_api.event.Event) Event {
    return switch (value) {
        .agent_start => |payload| .{ .agent_start = payload },
        .agent_end => |payload| .{ .agent_end = payload },
        .turn_start => |payload| .{ .turn_start = payload },
        .turn_end => |payload| .{ .turn_end = payload },
        .message_start => |payload| .{ .message_start = payload },
        .message_update => |payload| .{ .message_update = payload },
        .message_end => |payload| .{ .message_end = payload },
        .tool_execution_start => |payload| .{ .tool_execution_start = payload },
        .tool_execution_end => |payload| .{ .tool_execution_end = payload },
    };
}

test "session events preserve every core event tag" {
    const core: agent_api.event.Event = .{ .agent_start = .{ .run_id = @enumFromInt(7) } };
    const value = fromAgent(core);
    try std.testing.expect(value == .agent_start);
    try std.testing.expectEqual(@as(u64, 7), @intFromEnum(value.agent_start.run_id));
}

/// Bounded arena-owned copy for worker and UI boundaries.
pub const Owned = struct {
    pub const default_max_retained_bytes = SessionFormat.max_journal_bytes;
    pub const default_max_items = SessionFormat.max_entries;

    pub const Limits = struct {
        max_retained_bytes: usize = default_max_retained_bytes,
        max_items: usize = default_max_items,
    };

    pub const Error = error{
        OutOfMemory,
        EventTooLarge,
        TooManyItems,
    };

    arena: std.heap.ArenaAllocator,
    value: Event,
    retained_bytes: usize,
    item_count: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        source: Event,
        limits: Limits,
    ) Error!Owned {
        var budget: Budget = .{ .limits = limits };
        try budget.addEvent(source);

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const value = try copyEventLeaky(arena.allocator(), source);
        return .{
            .arena = arena,
            .value = value,
            .retained_bytes = budget.bytes,
            .item_count = budget.items,
        };
    }

    pub fn deinit(self: *Owned) void {
        self.arena.deinit();
        self.* = undefined;
    }

    fn copyEventLeaky(
        allocator: std.mem.Allocator,
        source: Event,
    ) error{OutOfMemory}!Event {
        return switch (source) {
            .agent_start => |value| .{ .agent_start = value },
            .agent_end => |value| .{ .agent_end = .{
                .run_id = value.run_id,
                .outcome = value.outcome,
                .messages = try copyMessagesLeaky(allocator, value.messages),
            } },
            .turn_start => |value| .{ .turn_start = value },
            .turn_end => |value| .{ .turn_end = .{
                .run_id = value.run_id,
                .index = value.index,
                .response = try copyResponseEndLeaky(allocator, value.response),
                .tool_results = try copyToolResultsLeaky(allocator, value.tool_results),
            } },
            .message_start => |value| .{ .message_start = .{
                .run_id = value.run_id,
                .turn_index = value.turn_index,
                .message = switch (value.message) {
                    .request => |request| .{ .request = try ai.message.copyRequestLeaky(allocator, request) },
                    .response => |response| .{ .response = try ai.stream.copySnapshotLeaky(allocator, response) },
                },
            } },
            .message_update => |value| .{ .message_update = .{
                .run_id = value.run_id,
                .turn_index = value.turn_index,
                .message = try ai.stream.copySnapshotLeaky(allocator, value.message),
                .update = try ai.stream.copyEventLeaky(allocator, value.update),
            } },
            .message_end => |value| .{ .message_end = .{
                .run_id = value.run_id,
                .turn_index = value.turn_index,
                .message = try copyMessageEndLeaky(allocator, value.message),
            } },
            .tool_execution_start => |value| .{ .tool_execution_start = .{
                .run_id = value.run_id,
                .turn_index = value.turn_index,
                .call_id = try allocator.dupe(u8, value.call_id),
                .name = try allocator.dupe(u8, value.name),
                .arguments_json = try allocator.dupe(u8, value.arguments_json),
            } },
            .tool_execution_end => |value| .{ .tool_execution_end = .{
                .run_id = value.run_id,
                .turn_index = value.turn_index,
                .call_id = try allocator.dupe(u8, value.call_id),
                .name = try allocator.dupe(u8, value.name),
                .result = switch (value.result) {
                    .published => |result| .{ .published = try ai.message.copyToolResultLeaky(allocator, result) },
                    .discarded => |outcome| .{ .discarded = outcome },
                },
            } },
            .agent_settled => |value| .{ .agent_settled = value },
        };
    }

    fn copyMessagesLeaky(
        allocator: std.mem.Allocator,
        source: []const ai.message.Message,
    ) error{OutOfMemory}![]const ai.message.Message {
        const result = try allocator.alloc(ai.message.Message, source.len);
        for (source, result) |message, *copy| copy.* = try ai.message.copyLeaky(allocator, message);
        return result;
    }

    fn copyToolResultsLeaky(
        allocator: std.mem.Allocator,
        source: []const ai.message.ToolResult,
    ) error{OutOfMemory}![]const ai.message.ToolResult {
        const result = try allocator.alloc(ai.message.ToolResult, source.len);
        for (source, result) |value, *copy| copy.* = try ai.message.copyToolResultLeaky(allocator, value);
        return result;
    }

    fn copyResponseEndLeaky(
        allocator: std.mem.Allocator,
        source: agent_api.event.ResponseEnd,
    ) error{OutOfMemory}!agent_api.event.ResponseEnd {
        return switch (source) {
            .published => |response| .{ .published = try ai.message.copyResponseLeaky(allocator, response) },
            .discarded => |discarded| .{ .discarded = try copyDiscardedLeaky(allocator, discarded) },
        };
    }

    fn copyMessageEndLeaky(
        allocator: std.mem.Allocator,
        source: agent_api.event.MessageEnd,
    ) error{OutOfMemory}!agent_api.event.MessageEnd {
        return switch (source) {
            .published => |message| .{ .published = try ai.message.copyLeaky(allocator, message) },
            .discarded_response => |discarded| .{
                .discarded_response = try copyDiscardedLeaky(allocator, discarded),
            },
        };
    }

    fn copyDiscardedLeaky(
        allocator: std.mem.Allocator,
        source: agent_api.event.DiscardedResponse,
    ) error{OutOfMemory}!agent_api.event.DiscardedResponse {
        return .{
            .response = try ai.stream.copySnapshotLeaky(allocator, source.response),
            .outcome = source.outcome,
        };
    }

    const Budget = struct {
        limits: Limits,
        bytes: usize = 0,
        items: usize = 0,

        fn addEvent(self: *Budget, event: Event) Error!void {
            switch (event) {
                .agent_start, .turn_start, .agent_settled => {},
                .agent_end => |value| try self.addMessages(value.messages),
                .turn_end => |value| {
                    try self.addResponseEnd(value.response);
                    try self.addItems(value.tool_results.len);
                    for (value.tool_results) |result| try self.addToolResult(result);
                },
                .message_start => |value| switch (value.message) {
                    .request => |request| try self.addRequest(request),
                    .response => |response| try self.addSnapshot(response),
                },
                .message_update => |value| {
                    try self.addSnapshot(value.message);
                    try self.addStreamEvent(value.update);
                },
                .message_end => |value| switch (value.message) {
                    .published => |message| try self.addMessage(message),
                    .discarded_response => |discarded| try self.addSnapshot(discarded.response),
                },
                .tool_execution_start => |value| {
                    try self.addBytes(value.call_id.len);
                    try self.addBytes(value.name.len);
                    try self.addBytes(value.arguments_json.len);
                },
                .tool_execution_end => |value| {
                    try self.addBytes(value.call_id.len);
                    try self.addBytes(value.name.len);
                    switch (value.result) {
                        .published => |result| try self.addToolResult(result),
                        .discarded => {},
                    }
                },
            }
        }

        fn addMessages(self: *Budget, messages: []const ai.message.Message) Error!void {
            try self.addItems(messages.len);
            for (messages) |message| try self.addMessage(message);
        }

        fn addMessage(self: *Budget, value: ai.message.Message) Error!void {
            switch (value) {
                .request => |request| try self.addRequest(request),
                .response => |response| try self.addResponse(response),
            }
        }

        fn addRequest(self: *Budget, value: ai.message.RequestMessage) Error!void {
            try self.addItems(value.parts.len);
            for (value.parts) |part| switch (part) {
                .user => |user| switch (user) {
                    .text => |text| try self.addBytes(text.len),
                    .image => |image| try self.addImage(image),
                },
                .tool_result => |result| try self.addToolResult(result),
                .retry_prompt => |text| try self.addBytes(text.len),
            };
        }

        fn addResponse(self: *Budget, value: ai.message.ResponseMessage) Error!void {
            try self.addBytes(value.identity.provider.len);
            try self.addBytes(value.identity.model.len);
            if (value.finish.raw_reason) |reason| try self.addBytes(reason.len);
            try self.addItems(value.parts.len);
            for (value.parts) |part| try self.addResponsePart(part);
        }

        fn addResponsePart(self: *Budget, part: ai.message.ResponsePart) Error!void {
            switch (part) {
                .text => |text| {
                    try self.addBytes(text.text.len);
                    if (text.provider_state) |state| try self.addProviderState(state);
                },
                .thinking => |thinking| {
                    try self.addBytes(thinking.text.len);
                    if (thinking.provider_state) |state| try self.addProviderState(state);
                },
                .tool_call => |call| {
                    try self.addBytes(call.id.len);
                    try self.addBytes(call.name.len);
                    try self.addBytes(call.arguments_json.len);
                    if (call.provider_state) |state| try self.addProviderState(state);
                },
            }
        }

        fn addToolResult(self: *Budget, result: ai.message.ToolResult) Error!void {
            try self.addBytes(result.call_id.len);
            try self.addBytes(result.name.len);
            try self.addItems(result.content.len);
            for (result.content) |content| switch (content) {
                .text => |text| try self.addBytes(text.len),
                .image => |image| try self.addImage(image),
            };
        }

        fn addImage(self: *Budget, image: ai.message.Image) Error!void {
            try self.addBytes(image.media_type.len);
            try self.addBytes(switch (image.source) {
                .bytes => |bytes| bytes.len,
                .url => |url| url.len,
            });
        }

        fn addProviderState(self: *Budget, state: ai.message.ProviderState) Error!void {
            try self.addBytes(state.provider.len);
            try self.addBytes(state.protocol.len);
            try self.addJson(state.value);
        }

        fn addJson(self: *Budget, value: std.json.Value) Error!void {
            try self.addItems(1);
            switch (value) {
                .null, .bool, .integer, .float => {},
                .number_string => |text| try self.addBytes(text.len),
                .string => |text| try self.addBytes(text.len),
                .array => |array| for (array.items) |item| try self.addJson(item),
                .object => |object| {
                    var iterator = object.iterator();
                    while (iterator.next()) |entry| {
                        try self.addBytes(entry.key_ptr.*.len);
                        try self.addJson(entry.value_ptr.*);
                    }
                },
            }
        }

        fn addSnapshot(self: *Budget, value: ai.stream.ResponseSnapshot) Error!void {
            try self.addBytes(value.identity.provider.len);
            try self.addBytes(value.identity.model.len);
            try self.addItems(value.parts.len);
            for (value.parts) |part| switch (part) {
                .text => |text| try self.addBytes(text.len),
                .thinking => |thinking| try self.addBytes(thinking.len),
                .tool_call => |call| {
                    if (call.id) |id| try self.addBytes(id.len);
                    if (call.name) |name| try self.addBytes(name.len);
                    try self.addBytes(call.arguments_json.len);
                },
            };
        }

        fn addStreamEvent(self: *Budget, value: ai.stream.StreamEvent) Error!void {
            switch (value) {
                .part_start => |start| switch (start.part) {
                    .text, .thinking => {},
                    .tool_call => |call| {
                        if (call.id) |id| try self.addBytes(id.len);
                        if (call.name) |name| try self.addBytes(name.len);
                    },
                },
                .part_delta => |delta| switch (delta.delta) {
                    .text => |text| try self.addBytes(text.len),
                    .thinking => |thinking| try self.addBytes(thinking.len),
                    .tool_call => |call| {
                        if (call.id) |id| try self.addBytes(id.len);
                        if (call.name) |name| try self.addBytes(name.len);
                        try self.addBytes(call.arguments_delta.len);
                    },
                },
                .part_end => |end| try self.addResponsePart(end.part),
                .usage => {},
            }
        }

        fn addResponseEnd(self: *Budget, value: agent_api.event.ResponseEnd) Error!void {
            switch (value) {
                .published => |response| try self.addResponse(response),
                .discarded => |discarded| try self.addSnapshot(discarded.response),
            }
        }

        fn addBytes(self: *Budget, count: usize) Error!void {
            self.bytes = std.math.add(usize, self.bytes, count) catch return error.EventTooLarge;
            if (self.bytes > self.limits.max_retained_bytes) return error.EventTooLarge;
        }

        fn addItems(self: *Budget, count: usize) Error!void {
            self.items = std.math.add(usize, self.items, count) catch return error.TooManyItems;
            if (self.items > self.limits.max_items) return error.TooManyItems;
        }
    };
};

test "owned event retains stream bytes after sources are mutated" {
    var text = [_]u8{ 'h', 'e', 'l', 'l', 'o' };
    var owned = try Owned.init(std.testing.allocator, .{ .message_update = .{
        .run_id = @enumFromInt(9),
        .turn_index = 2,
        .message = .{
            .parts = &.{.{ .text = &text }},
            .identity = .{ .provider = "script", .model = "owned" },
        },
        .update = .{ .part_delta = .{ .index = 0, .delta = .{ .text = &text } } },
    } }, .{});
    defer owned.deinit();
    @memset(&text, 'x');

    try std.testing.expectEqualStrings("hello", owned.value.message_update.message.parts[0].text);
    try std.testing.expectEqualStrings("hello", owned.value.message_update.update.part_delta.delta.text);
    try std.testing.expectEqual(@as(u64, 9), @intFromEnum(owned.value.message_update.run_id));
}

test "owned event rejects byte and item bounds before allocation" {
    try std.testing.expectError(error.EventTooLarge, Owned.init(
        std.testing.allocator,
        .{ .tool_execution_start = .{
            .run_id = @enumFromInt(1),
            .turn_index = 1,
            .call_id = "call",
            .name = "read",
            .arguments_json = "{}",
        } },
        .{ .max_retained_bytes = 5 },
    ));
    try std.testing.expectError(error.TooManyItems, Owned.init(
        std.testing.allocator,
        .{ .agent_end = .{
            .run_id = @enumFromInt(1),
            .outcome = .completed,
            .messages = &.{.{ .request = .{ .parts = &.{} } }},
        } },
        .{ .max_items = 0 },
    ));
}

fn copyForAllocationFailure(allocator: std.mem.Allocator) !void {
    var update = try Owned.init(allocator, .{ .message_update = .{
        .run_id = @enumFromInt(3),
        .turn_index = 4,
        .message = .{
            .parts = &.{.{ .tool_call = .{
                .id = "call",
                .name = "read",
                .arguments_json = "{}",
            } }},
            .identity = .{ .provider = "script", .model = "allocation" },
        },
        .update = .{ .part_end = .{
            .index = 0,
            .part = .{ .text = .{
                .text = "contents",
                .provider_state = .{
                    .provider = "script",
                    .protocol = "test",
                    .value = .{ .string = "opaque" },
                },
            } },
        } },
    } }, .{});
    update.deinit();

    var tool = try Owned.init(allocator, .{ .tool_execution_end = .{
        .run_id = @enumFromInt(3),
        .turn_index = 4,
        .call_id = "call",
        .name = "read",
        .result = .{ .published = .{
            .call_id = "call",
            .name = "read",
            .content = &.{.{ .text = "contents" }},
            .outcome = .success,
        } },
    } }, .{});
    tool.deinit();
}

test "owned event settles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        copyForAllocationFailure,
        .{},
    );
}

pub const EventSink = Sink;

pub const AgentSession = struct {
    pub const RunControl = Agent.RunControl;
    pub const RunError = Agent.RunError;
    pub const State = Agent.State;

    pub const Options = struct {
        limits: agent_limits.RunLimits = .{},
        events: ?EventSink = null,
        prompt: SystemPrompt.Config = .{},
        thinking_level: ai.ThinkingLevel = .off,
    };

    pub const InitError = error{
        OutOfMemory,
        InvalidSystemPrompt,
        SystemPromptTooLarge,
        DuplicateToolName,
        InvalidToolDefinition,
        UnknownTool,
        InvalidToolArguments,
        UnsupportedSetting,
    };

    const Tools = struct {
        toolset: *ToolsModule.Toolset,
        events: ?EventSink,
        last_run_id: ?agent_api.event.RunId = null,

        fn emitAgentEvent(context: *anyopaque, event: Agent.Event) agent_api.event.SinkError!void {
            const self: *Tools = @ptrCast(@alignCast(context));
            const sink = self.events orelse return;
            if (event == .agent_start) self.last_run_id = event.agent_start.run_id;
            return sink.emit(fromAgent(event));
        }
    };

    allocator: std.mem.Allocator,
    tools: *Tools,
    system_prompt: SystemPrompt,
    agent: Agent,
    commit_owner: ?*SessionCommit = null,

    /// Takes ownership of `cwd`. On success the session closes it in deinit;
    /// on any failure this function closes it exactly once before returning.
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        model: ai_model.Model,
        cwd: std.Io.Dir,
        options: Options,
    ) InitError!AgentSession {
        var cwd_owned = true;
        defer if (cwd_owned) cwd.close(io);

        var system_prompt = try SystemPrompt.init(allocator, options.prompt);
        errdefer system_prompt.deinit();
        const tools = try allocator.create(Tools);
        errdefer allocator.destroy(tools);
        const toolset = try ToolsModule.Toolset.init(allocator, io, cwd);
        cwd_owned = false;
        tools.* = .{
            .toolset = toolset,
            .events = options.events,
        };
        errdefer tools.toolset.deinit();
        const admitted = tools.toolset.tools();
        return .{
            .allocator = allocator,
            .tools = tools,
            .system_prompt = system_prompt,
            .agent = try Agent.init(
                allocator,
                io,
                model,
                system_prompt.instructions(),
                &admitted,
                options.limits,
                if (options.events == null) null else .{
                    .context = tools,
                    .emitFn = Tools.emitAgentEvent,
                },
                options.thinking_level,
            ),
        };
    }

    pub fn deinit(self: *AgentSession) void {
        self.agent.deinit();
        if (self.commit_owner) |commit_owner| commit_owner.deinit();
        self.system_prompt.deinit();
        self.tools.toolset.deinit();
        self.allocator.destroy(self.tools);
        self.* = undefined;
    }

    /// Binds a durable commit to the core agent. Ownership of `commit_owner`
    /// transfers to the session only after the agent binding succeeds, so a
    /// failed binding leaves the commit with the caller.
    pub fn bindCommit(self: *AgentSession, commit_owner: *SessionCommit) SessionCommit.Error!void {
        try commit_owner.bindAgent(&self.agent);
        self.commit_owner = commit_owner;
    }

    /// Construction-only binding used when the session is transferred to a worker.
    pub fn bindEvents(self: *AgentSession, sink: EventSink) error{EventsAlreadyBound}!void {
        if (self.tools.events != null) return error.EventsAlreadyBound;
        try self.agent.bindEvents(.{
            .context = self.tools,
            .emitFn = Tools.emitAgentEvent,
        });
        self.tools.events = sink;
    }

    pub fn prompt(self: *AgentSession, input: []const u8) Agent.RunError![]const u8 {
        return self.promptInternal(input, .{});
    }

    pub fn promptWithControl(
        self: *AgentSession,
        input: []const u8,
        control: Agent.RunControl,
    ) Agent.RunError![]const u8 {
        return self.promptInternal(input, control);
    }

    fn promptInternal(
        self: *AgentSession,
        input: []const u8,
        control: Agent.RunControl,
    ) Agent.RunError![]const u8 {
        const result = self.agent.runWithControl(input, control);
        if (result) |text| {
            try self.emitSettled();
            return text;
        } else |failure| {
            const settled = self.emitSettled();
            if (settled) |_| {} else |_| {}
            return failure;
        }
    }

    fn emitSettled(self: *AgentSession) Agent.RunError!void {
        const sink = self.tools.events orelse return;
        const availability: Availability = switch (self.agent.state()) {
            .ready => .ready,
            .poisoned => .poisoned,
            .running => unreachable,
        };
        sink.emit(.{ .agent_settled = .{
            .run_id = self.tools.last_run_id orelse unreachable,
            .availability = availability,
        } }) catch |failure| return switch (failure) {
            error.OutOfMemory => error.OutOfMemory,
            error.Cancelled => error.Cancelled,
            error.ConsumerStopped => error.EventConsumerStopped,
        };
    }

    pub fn messages(self: *const AgentSession) []const ai_message.Message {
        return self.agent.messages();
    }

    pub fn providerFailure(self: *const AgentSession) ?ai_failure.ProviderFailure {
        return self.agent.providerFailure();
    }

    pub fn state(self: *const AgentSession) Agent.State {
        return self.agent.state();
    }

    pub fn thinkingLevel(self: *const AgentSession) ai.ThinkingLevel {
        return self.agent.thinkingLevel();
    }

    pub fn systemPrompt(self: *const AgentSession) []const u8 {
        return self.system_prompt.text();
    }

    fn hasCodingInstructions(request: ai_model.ModelRequest) bool {
        if (request.instructions.len != 1) return false;
        return std.mem.find(u8, request.instructions[0], "You are Zi") != null and
            std.mem.find(u8, request.instructions[0], "<work_policy>") != null and
            std.mem.find(u8, request.instructions[0], "<tool_calling>") != null;
    }

    const ai_testing = ai.testing;

    const RequestRecorder = struct {
        count: usize = 0,
        instructions_valid: bool = true,
        write_result_seen: bool = false,
        read_result_seen: bool = false,

        fn observe(context: *anyopaque, index: usize, request: ai_model.ModelRequest) void {
            const self: *RequestRecorder = @ptrCast(@alignCast(context));
            self.count += 1;
            self.instructions_valid = self.instructions_valid and hasCodingInstructions(request);
            if (index != 1 and index != 2) return;
            for (request.messages) |entry| switch (entry) {
                .response => {},
                .request => |message| for (message.parts) |part| switch (part) {
                    .user, .retry_prompt => {},
                    .tool_result => |result| for (result.content) |content| switch (content) {
                        .image => {},
                        .text => |text| {
                            if (index == 1 and result.outcome == .success and
                                std.mem.eql(u8, result.name, "write") and
                                std.mem.eql(u8, text, "Successfully wrote 22 bytes to src/main.zig"))
                            {
                                self.write_result_seen = true;
                            }
                            if (index == 2 and result.outcome == .success and
                                std.mem.eql(u8, result.name, "read") and
                                std.mem.eql(u8, text, "pub fn main() void {}\n"))
                            {
                                self.read_result_seen = true;
                            }
                        },
                    },
                },
            };
        }
    };

    const EditRequestRecorder = struct {
        count: usize = 0,
        instructions_valid: bool = true,
        original_seen: bool = false,
        edit_seen: bool = false,
        updated_seen: bool = false,

        fn observe(context: *anyopaque, index: usize, request: ai_model.ModelRequest) void {
            const self: *EditRequestRecorder = @ptrCast(@alignCast(context));
            self.count += 1;
            self.instructions_valid = self.instructions_valid and hasCodingInstructions(request);
            for (request.messages) |entry| switch (entry) {
                .response => {},
                .request => |message| for (message.parts) |part| switch (part) {
                    .user, .retry_prompt => {},
                    .tool_result => |result| for (result.content) |content| switch (content) {
                        .image => {},
                        .text => |text| {
                            if (index == 1 and result.outcome == .success and
                                std.mem.eql(u8, result.name, "read") and
                                std.mem.eql(u8, text, "const enabled = false;\n"))
                            {
                                self.original_seen = true;
                            }
                            if (index == 2 and result.outcome == .success and
                                std.mem.eql(u8, result.name, "edit") and
                                std.mem.eql(u8, text, "Successfully replaced 1 block(s) in config.zig."))
                            {
                                self.edit_seen = true;
                            }
                            if (index == 3 and result.outcome == .success and
                                std.mem.eql(u8, result.name, "read") and
                                std.mem.eql(u8, text, "const enabled = true;\n"))
                            {
                                self.updated_seen = true;
                            }
                        },
                    },
                },
            };
        }
    };

    test "coding-agent session extends core lifecycle with final settlement" {
        const Recorder = struct {
            const Self = @This();

            tags: [16]std.meta.Tag(Event) = undefined,
            count: usize = 0,
            saw_complete_partial: bool = false,
            settled: ?Availability = null,
            settled_run_id: ?agent_api.event.RunId = null,

            fn emit(context: *anyopaque, event: Event) SinkError!void {
                const self: *Self = @ptrCast(@alignCast(context));
                self.tags[self.count] = std.meta.activeTag(event);
                self.count += 1;
                switch (event) {
                    .message_update => |update| if (update.message.parts.len > 0 and
                        update.message.parts[0] == .text)
                    {
                        self.saw_complete_partial = std.mem.eql(u8, update.message.parts[0].text, "complete");
                    },
                    .agent_settled => |settled| {
                        self.settled = settled.availability;
                        self.settled_run_id = settled.run_id;
                    },
                    else => {},
                }
            }
        };

        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var scripted: ai_testing.ScriptedModel = .{
            .identity = .{ .provider = "script", .model = "session-events" },
            .steps = &.{.{ .text = "complete" }},
        };
        var recorder: Recorder = .{};
        var session = try AgentSession.init(
            std.testing.allocator,
            std.testing.io,
            scripted.asModel(),
            try temporary.dir.openDir(std.testing.io, ".", .{}),
            .{ .events = .{ .context = &recorder, .emitFn = Recorder.emit } },
        );
        defer session.deinit();

        try std.testing.expectEqualStrings("complete", try session.prompt("question"));
        const expected = [_]std.meta.Tag(Event){
            .agent_start,
            .turn_start,
            .message_start,
            .message_end,
            .message_start,
            .message_update,
            .message_update,
            .message_update,
            .message_end,
            .turn_end,
            .agent_end,
            .agent_settled,
        };
        try std.testing.expectEqualSlices(std.meta.Tag(Event), &expected, recorder.tags[0..recorder.count]);
        try std.testing.expect(recorder.saw_complete_partial);
        try std.testing.expectEqual(Availability.ready, recorder.settled.?);
        try std.testing.expectEqual(@as(u64, 1), @intFromEnum(recorder.settled_run_id.?));
    }

    test "coding-agent session sends its owned custom system prompt" {
        const Recorder = struct {
            const Self = @This();

            valid: bool = true,

            fn observe(context: *anyopaque, _: usize, request: ai_model.ModelRequest) void {
                const self: *Self = @ptrCast(@alignCast(context));
                self.valid = self.valid and request.instructions.len == 1 and
                    std.mem.eql(u8, request.instructions[0], "Answer with one word.");
            }
        };
        var recorder: Recorder = .{};
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var scripted: ai_testing.ScriptedModel = .{
            .identity = .{ .provider = "script", .model = "custom-system-prompt" },
            .steps = &.{.{ .text = "Done" }},
            .request_observer = .{ .context = &recorder, .observeFn = Recorder.observe },
        };
        var session = try AgentSession.init(
            std.testing.allocator,
            std.testing.io,
            scripted.asModel(),
            try temporary.dir.openDir(std.testing.io, ".", .{}),
            .{ .prompt = .{ .policy = .{ .verbatim = "Answer with one word." } } },
        );
        defer session.deinit();

        try std.testing.expectEqualStrings("Answer with one word.", session.systemPrompt());
        try std.testing.expectEqualStrings("Done", try session.prompt("Finish."));
        try std.testing.expect(recorder.valid);
    }

    test "coding-agent session writes and reads a workspace file before a later prompt" {
        var request_recorder: RequestRecorder = .{};
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var scripted: ai_testing.ScriptedModel = .{
            .identity = .{ .provider = "script", .model = "coding-write-read" },
            .steps = &.{
                .{ .tool_call = .{
                    .id = "call-1",
                    .name = "write",
                    .arguments_json = "{\"path\":\"src/main.zig\",\"content\":\"pub fn main() void {}\\n\"}",
                } },
                .{ .tool_call = .{
                    .id = "call-2",
                    .name = "read",
                    .arguments_json = "{\"path\":\"src/main.zig\"}",
                } },
                .{ .text = "Created and verified the entrypoint." },
                .{ .text = "No additional work." },
            },
            .request_observer = .{ .context = &request_recorder, .observeFn = RequestRecorder.observe },
        };
        var session = try AgentSession.init(
            std.testing.allocator,
            std.testing.io,
            scripted.asModel(),
            try temporary.dir.openDir(std.testing.io, ".", .{}),
            .{},
        );
        defer session.deinit();
        const text = try session.prompt("Create and verify the entrypoint.");

        try std.testing.expectEqualStrings("Created and verified the entrypoint.", text);
        try std.testing.expect(request_recorder.instructions_valid);
        try std.testing.expect(request_recorder.write_result_seen);
        try std.testing.expect(request_recorder.read_result_seen);
        try std.testing.expectEqual(@as(usize, 3), request_recorder.count);
        try std.testing.expect(session.state() == .ready);
        try std.testing.expectEqual(@as(usize, 6), session.messages().len);
        try std.testing.expectEqualStrings(
            "Successfully wrote 22 bytes to src/main.zig",
            session.messages()[2].request.parts[0].tool_result.content[0].text,
        );
        try std.testing.expectEqualStrings(
            "pub fn main() void {}\n",
            session.messages()[4].request.parts[0].tool_result.content[0].text,
        );
        const bytes = try temporary.dir.readFileAlloc(
            std.testing.io,
            "src/main.zig",
            std.testing.allocator,
            .unlimited,
        );
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqualStrings("pub fn main() void {}\n", bytes);

        const follow_up = try session.prompt("Anything else?");
        try std.testing.expectEqualStrings("No additional work.", follow_up);
        try std.testing.expect(request_recorder.instructions_valid);
        try std.testing.expectEqual(@as(usize, 4), request_recorder.count);
        const history = session.messages();
        try std.testing.expectEqual(@as(usize, 8), history.len);
        try std.testing.expectEqual(ai_message.Message.request, std.meta.activeTag(history[0]));
        try std.testing.expectEqualStrings("Create and verify the entrypoint.", history[0].request.parts[0].user.text);
        try std.testing.expectEqual(ai_message.Message.response, std.meta.activeTag(history[1]));
        try std.testing.expectEqualStrings("write", history[1].response.parts[0].tool_call.name);
        try std.testing.expectEqual(ai_message.Message.request, std.meta.activeTag(history[2]));
        try std.testing.expectEqualStrings("write", history[2].request.parts[0].tool_result.name);
        try std.testing.expectEqual(ai_message.Message.response, std.meta.activeTag(history[3]));
        try std.testing.expectEqualStrings("read", history[3].response.parts[0].tool_call.name);
        try std.testing.expectEqual(ai_message.Message.request, std.meta.activeTag(history[4]));
        try std.testing.expectEqualStrings("read", history[4].request.parts[0].tool_result.name);
        try std.testing.expectEqual(ai_message.Message.response, std.meta.activeTag(history[5]));
        try std.testing.expectEqualStrings(
            "Created and verified the entrypoint.",
            history[5].response.parts[0].text.text,
        );
        try std.testing.expectEqual(ai_message.Message.request, std.meta.activeTag(history[6]));
        try std.testing.expectEqualStrings("Anything else?", history[6].request.parts[0].user.text);
        try std.testing.expectEqual(ai_message.Message.response, std.meta.activeTag(history[7]));
        try std.testing.expectEqualStrings("No additional work.", history[7].response.parts[0].text.text);
    }

    fn cancelAfterBashStarts(
        io: std.Io,
        cwd: std.Io.Dir,
        token: *ai_model.CancellationToken,
    ) !void {
        const delay: std.Io.Timeout = .{ .duration = .{
            .raw = .fromMilliseconds(1),
            .clock = .awake,
        } };
        while (true) {
            cwd.access(io, "started", .{}) catch |failure| switch (failure) {
                error.FileNotFound => {
                    try delay.sleep(io);
                    continue;
                },
                else => return failure,
            };
            token.cancel();
            return;
        }
    }

    const BashRequestRecorder = struct {
        count: usize = 0,
        instructions_valid: bool = true,
        result_seen: bool = false,

        fn observe(context: *anyopaque, index: usize, request: ai_model.ModelRequest) void {
            const self: *BashRequestRecorder = @ptrCast(@alignCast(context));
            self.count += 1;
            self.instructions_valid = self.instructions_valid and hasCodingInstructions(request);
            if (index != 1) return;
            for (request.messages) |entry| switch (entry) {
                .response => {},
                .request => |message| for (message.parts) |part| switch (part) {
                    .user, .retry_prompt => {},
                    .tool_result => |result| for (result.content) |content| switch (content) {
                        .image => {},
                        .text => |text| if (result.outcome == .success and
                            std.mem.eql(u8, result.name, "bash") and
                            std.mem.eql(u8, text, "cwd-ok\n\nCommand exited with code 0"))
                        {
                            self.result_seen = true;
                        },
                    },
                },
            };
        }
    };

    test "coding-agent session reads, edits, and verifies an existing file" {
        var request_recorder: EditRequestRecorder = .{};
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = "config.zig",
            .data = "const enabled = false;\n",
        });
        var scripted: ai_testing.ScriptedModel = .{
            .identity = .{ .provider = "script", .model = "coding-edit" },
            .steps = &.{
                .{ .tool_call = .{
                    .id = "call-1",
                    .name = "read",
                    .arguments_json = "{\"path\":\"config.zig\"}",
                } },
                .{ .tool_call = .{
                    .id = "call-2",
                    .name = "edit",
                    .arguments_json = "{\"path\":\"config.zig\",\"edits\":[" ++
                        "{\"oldText\":\"false\",\"newText\":\"true\"}]}",
                } },
                .{ .tool_call = .{
                    .id = "call-3",
                    .name = "read",
                    .arguments_json = "{\"path\":\"config.zig\"}",
                } },
                .{ .text = "Enabled and verified the configuration." },
            },
            .request_observer = .{ .context = &request_recorder, .observeFn = EditRequestRecorder.observe },
        };
        var session = try AgentSession.init(
            std.testing.allocator,
            std.testing.io,
            scripted.asModel(),
            try temporary.dir.openDir(std.testing.io, ".", .{}),
            .{},
        );
        defer session.deinit();

        const text = try session.prompt("Enable the configuration.");
        try std.testing.expectEqualStrings("Enabled and verified the configuration.", text);
        try std.testing.expect(request_recorder.instructions_valid);
        try std.testing.expect(request_recorder.original_seen);
        try std.testing.expect(request_recorder.edit_seen);
        try std.testing.expect(request_recorder.updated_seen);
        try std.testing.expectEqual(@as(usize, 4), request_recorder.count);
        const history = session.messages();
        try std.testing.expectEqual(@as(usize, 8), history.len);
        try std.testing.expectEqualStrings("call-1", history[1].response.parts[0].tool_call.id);
        try std.testing.expectEqualStrings("read", history[1].response.parts[0].tool_call.name);
        try std.testing.expect(history[2].request.parts[0].tool_result.outcome == .success);
        try std.testing.expectEqualStrings("call-1", history[2].request.parts[0].tool_result.call_id);
        try std.testing.expectEqualStrings(
            "const enabled = false;\n",
            history[2].request.parts[0].tool_result.content[0].text,
        );
        try std.testing.expectEqualStrings("call-2", history[3].response.parts[0].tool_call.id);
        try std.testing.expectEqualStrings("edit", history[3].response.parts[0].tool_call.name);
        try std.testing.expect(history[4].request.parts[0].tool_result.outcome == .success);
        try std.testing.expectEqualStrings("call-2", history[4].request.parts[0].tool_result.call_id);
        try std.testing.expectEqualStrings(
            "Successfully replaced 1 block(s) in config.zig.",
            history[4].request.parts[0].tool_result.content[0].text,
        );
        try std.testing.expectEqualStrings("call-3", history[5].response.parts[0].tool_call.id);
        try std.testing.expectEqualStrings("read", history[5].response.parts[0].tool_call.name);
        try std.testing.expect(history[6].request.parts[0].tool_result.outcome == .success);
        try std.testing.expectEqualStrings("call-3", history[6].request.parts[0].tool_result.call_id);
        try std.testing.expectEqualStrings(
            "const enabled = true;\n",
            history[6].request.parts[0].tool_result.content[0].text,
        );
        try std.testing.expectEqualStrings(
            "Enabled and verified the configuration.",
            history[7].response.parts[0].text.text,
        );
        const bytes = try temporary.dir.readFileAlloc(
            std.testing.io,
            "config.zig",
            std.testing.allocator,
            .unlimited,
        );
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqualStrings("const enabled = true;\n", bytes);
    }

    test "coding-agent session executes bash in the workspace and continues" {
        var request_recorder: BashRequestRecorder = .{};
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "marker", .data = "" });
        var scripted: ai_testing.ScriptedModel = .{
            .identity = .{ .provider = "script", .model = "coding-bash" },
            .steps = &.{
                .{ .tool_call = .{
                    .id = "call-1",
                    .name = "bash",
                    .arguments_json = "{\"command\":\"test -f marker && printf cwd-ok\"}",
                } },
                .{ .text = "The workspace command passed." },
            },
            .request_observer = .{ .context = &request_recorder, .observeFn = BashRequestRecorder.observe },
        };
        var session = try AgentSession.init(
            std.testing.allocator,
            std.testing.io,
            scripted.asModel(),
            try temporary.dir.openDir(std.testing.io, ".", .{}),
            .{},
        );
        defer session.deinit();

        const text = try session.prompt("Verify the workspace marker.");
        try std.testing.expectEqualStrings("The workspace command passed.", text);
        try std.testing.expect(request_recorder.instructions_valid);
        try std.testing.expect(request_recorder.result_seen);
        try std.testing.expectEqual(@as(usize, 2), request_recorder.count);
        const history = session.messages();
        try std.testing.expectEqual(@as(usize, 4), history.len);
        try std.testing.expectEqualStrings("call-1", history[1].response.parts[0].tool_call.id);
        try std.testing.expectEqualStrings("bash", history[1].response.parts[0].tool_call.name);
        try std.testing.expect(history[2].request.parts[0].tool_result.outcome == .success);
        try std.testing.expectEqualStrings(
            "cwd-ok\n\nCommand exited with code 0",
            history[2].request.parts[0].tool_result.content[0].text,
        );
        try std.testing.expectEqualStrings("The workspace command passed.", history[3].response.parts[0].text.text);
    }

    test "coding-agent cancellation settles a running bash process" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var scripted: ai_testing.ScriptedModel = .{
            .identity = .{ .provider = "script", .model = "coding-bash-cancel" },
            .steps = &.{.{ .tool_call = .{
                .id = "call-1",
                .name = "bash",
                .arguments_json = "{\"command\":\": > started; end=$((SECONDS+1)); " ++
                    "while (( SECONDS < end )); do :; done; : > late\"}",
            } }},
        };
        var session = try AgentSession.init(
            std.testing.allocator,
            std.testing.io,
            scripted.asModel(),
            try temporary.dir.openDir(std.testing.io, ".", .{}),
            .{},
        );
        defer session.deinit();
        var cancellation: ai_model.CancellationToken = .{};
        var cancel_future = std.testing.io.async(
            cancelAfterBashStarts,
            .{ std.testing.io, temporary.dir, &cancellation },
        );
        const prompt_result = session.promptWithControl("Run until cancelled.", .{ .cancellation = &cancellation });
        try cancel_future.await(std.testing.io);
        try std.testing.expectError(error.Cancelled, prompt_result);
        try temporary.dir.access(std.testing.io, "started", .{});
        try std.testing.expectError(error.FileNotFound, temporary.dir.access(std.testing.io, "late", .{}));
        try std.testing.expect(session.state() == .ready);
    }
};
