const std = @import("std");
const agent_root = @import("../../agent/root.zig");
const agent_impl = @import("../../agent/agent.zig");
const message_memory = @import("../../agent/message_memory.zig");
const session_core = @import("../../session/root.zig");

const protocol = agent_root.protocol;
pub const Agent = agent_root.Agent;
pub const SubscriptionToken = agent_impl.SubscriptionToken;
pub const ContextUsage = session_core.context_usage.ContextUsage;

pub const AgentPromptResult = struct {
    arena: std.heap.ArenaAllocator,
    status: Status,

    pub const Status = union(enum) {
        completed: Completed,
        err: Err,
        cancelled: Cancelled,
    };

    pub const Completed = struct {
        message: protocol.AgentMessage,
        messages: []const protocol.AgentMessage,
        tool_results: []const protocol.ToolResultMessage,
        context_usage: ?ContextUsage = null,
    };

    pub const Err = struct {
        message: []const u8,
        partial_messages: []const protocol.AgentMessage = &.{},
    };

    pub const Cancelled = struct {
        messages: []const protocol.AgentMessage = &.{},
    };

    pub fn completed(allocator: std.mem.Allocator, value: Completed) !AgentPromptResult {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();

        const message = try message_memory.cloneMessage(arena_allocator, value.message);
        const messages = if (value.messages.len > 0) try message_memory.cloneMessages(arena_allocator, value.messages) else &.{};
        const tool_results = if (value.tool_results.len > 0) blk: {
            const out = try arena_allocator.alloc(protocol.ToolResultMessage, value.tool_results.len);
            for (value.tool_results, 0..) |tool_result, i| out[i] = try message_memory.cloneToolResultMessage(arena_allocator, tool_result);
            break :blk out;
        } else &.{};

        return .{ .arena = arena, .status = .{ .completed = .{
            .message = message,
            .messages = messages,
            .tool_results = tool_results,
            .context_usage = value.context_usage,
        } } };
    }

    pub fn errMessage(allocator: std.mem.Allocator, message: []const u8, partial_messages: []const protocol.AgentMessage) !AgentPromptResult {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();
        return .{ .arena = arena, .status = .{ .err = .{
            .message = try arena_allocator.dupe(u8, message),
            .partial_messages = if (partial_messages.len > 0) try message_memory.cloneMessages(arena_allocator, partial_messages) else &.{},
        } } };
    }

    pub fn cancelledResult(allocator: std.mem.Allocator, messages: []const protocol.AgentMessage) !AgentPromptResult {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();
        return .{ .arena = arena, .status = .{ .cancelled = .{
            .messages = if (messages.len > 0) try message_memory.cloneMessages(arena_allocator, messages) else &.{},
        } } };
    }

    pub fn deinit(self: *AgentPromptResult) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const AgentSessionCore = struct {
    allocator: std.mem.Allocator,
    agent: Agent,
    context_usage_fn: ?ContextUsageFn = null,

    pub const ContextUsageFn = struct {
        ptr: *anyopaque,
        func: *const fn (ptr: *anyopaque) ?ContextUsage,
    };

    pub const Options = Agent.Options;

    pub fn init(allocator: std.mem.Allocator, options: Options) !AgentSessionCore {
        return .{ .allocator = allocator, .agent = try Agent.init(allocator, options) };
    }

    pub fn deinit(self: *AgentSessionCore) void {
        self.agent.deinit();
        self.* = undefined;
    }

    pub fn prompt(self: *AgentSessionCore, prompts: []const protocol.AgentMessage) !AgentPromptResult {
        try self.agent.prompt(prompts);
        return try self.resultFromAgent();
    }

    pub fn continueTurn(self: *AgentSessionCore) !AgentPromptResult {
        try self.agent.continueTurn();
        return try self.resultFromAgent();
    }

    pub fn abort(self: *AgentSessionCore) void {
        self.agent.abort();
    }
    pub fn isBusy(self: *const AgentSessionCore) bool {
        return self.agent.isRunning();
    }
    pub fn messages(self: *const AgentSessionCore) []const protocol.AgentMessage {
        return self.agent.messages();
    }

    pub fn contextUsage(self: *AgentSessionCore) ?ContextUsage {
        if (self.context_usage_fn) |f| return f.func(f.ptr);
        const model = self.agent.modelValue();
        if (model.context_window == 0) return null;
        const estimate = session_core.context_usage.estimateContextTokensWithInFlight(self.agent.messages(), self.agent.inFlightState());
        return .{ .tokens = estimate.tokens, .context_window = model.context_window, .percent = (@as(f64, @floatFromInt(estimate.tokens)) / @as(f64, @floatFromInt(model.context_window))) * 100.0 };
    }

    pub fn replaceRuntimeInputs(self: *AgentSessionCore, system_prompt: []const u8, tools: []const protocol.AgentTool) void {
        self.agent.replaceRuntimeInputs(system_prompt, tools);
    }

    fn resultFromAgent(self: *AgentSessionCore) !AgentPromptResult {
        const agent_messages = self.agent.messages();
        if (self.agent.isAbortRequested()) return try AgentPromptResult.cancelledResult(self.allocator, agent_messages);
        if (self.agent.errorMessage()) |msg| return try AgentPromptResult.errMessage(self.allocator, msg, agent_messages);
        const assistant = self.agent.latestAssistant() orelse return try AgentPromptResult.errMessage(self.allocator, "agent finished without an assistant response", agent_messages);

        var tool_results = std.ArrayList(protocol.ToolResultMessage).empty;
        defer tool_results.deinit(self.allocator);
        for (agent_messages) |m| switch (m) {
            .tool_result => |tr| try tool_results.append(self.allocator, tr),
            else => {},
        };
        return try AgentPromptResult.completed(self.allocator, .{
            .message = .{ .assistant = assistant },
            .messages = agent_messages,
            .tool_results = tool_results.items,
            .context_usage = self.contextUsage(),
        });
    }
};
