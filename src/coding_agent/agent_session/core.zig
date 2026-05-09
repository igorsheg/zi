const std = @import("std");
const agent_root = @import("../../agent/root.zig");
const agent_impl = @import("../../agent/agent.zig");
const message_memory = @import("../../agent/message_memory.zig");
const session_core = @import("../../session/root.zig");

const protocol = agent_root.protocol;
pub const Agent = agent_root.Agent;
pub const SubscriptionToken = agent_impl.SubscriptionToken;
pub const ContextUsage = session_core.context_usage.ContextUsage;

pub const AgentPromptResult = union(enum) {
    completed: Completed,
    err: Err,
    cancelled: Cancelled,

    pub const Completed = struct {
        message: protocol.AgentMessage,
        messages: []protocol.AgentMessage,
        tool_results: []protocol.ToolResultMessage,
        context_usage: ?ContextUsage = null,

        pub fn deinit(self: *Completed, allocator: std.mem.Allocator) void {
            message_memory.freeMessage(allocator, &self.message);
            message_memory.freeMessages(allocator, self.messages);
            for (self.tool_results) |*tr| message_memory.freeToolResultMessage(allocator, tr);
            if (self.tool_results.len > 0) allocator.free(self.tool_results);
            self.* = undefined;
        }
    };

    pub const Err = struct {
        message: []const u8,
        partial_messages: []protocol.AgentMessage = &.{},

        pub fn deinit(self: *Err, allocator: std.mem.Allocator) void {
            allocator.free(self.message);
            message_memory.freeMessages(allocator, self.partial_messages);
            self.* = undefined;
        }
    };

    pub const Cancelled = struct {
        messages: []protocol.AgentMessage = &.{},

        pub fn deinit(self: *Cancelled, allocator: std.mem.Allocator) void {
            message_memory.freeMessages(allocator, self.messages);
            self.* = undefined;
        }
    };

    pub fn deinit(self: *AgentPromptResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .completed => |*completed| completed.deinit(allocator),
            .err => |*err| err.deinit(allocator),
            .cancelled => |*cancelled| cancelled.deinit(allocator),
        }
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
        const allocator = self.allocator;
        const agent_messages = self.agent.messages();
        if (self.agent.isAbortRequested()) return .{ .cancelled = .{ .messages = try message_memory.cloneMessages(allocator, agent_messages) } };
        if (self.agent.errorMessage()) |msg| return .{ .err = .{ .message = try allocator.dupe(u8, msg), .partial_messages = try message_memory.cloneMessages(allocator, agent_messages) } };
        const assistant = self.agent.latestAssistant() orelse return .{ .err = .{ .message = try allocator.dupe(u8, "agent finished without an assistant response"), .partial_messages = try message_memory.cloneMessages(allocator, agent_messages) } };
        var message: protocol.AgentMessage = try message_memory.cloneMessage(allocator, .{ .assistant = assistant });
        errdefer message_memory.freeMessage(allocator, &message);
        const cloned_messages = try message_memory.cloneMessages(allocator, agent_messages);
        errdefer message_memory.freeMessages(allocator, cloned_messages);
        var tool_results = std.ArrayList(protocol.ToolResultMessage).empty;
        errdefer {
            for (tool_results.items) |*tr| message_memory.freeToolResultMessage(allocator, tr);
            tool_results.deinit(allocator);
        }
        for (agent_messages) |m| switch (m) {
            .tool_result => |tr| try tool_results.append(allocator, try message_memory.cloneToolResultMessage(allocator, tr)),
            else => {},
        };
        return .{ .completed = .{ .message = message, .messages = cloned_messages, .tool_results = try tool_results.toOwnedSlice(allocator), .context_usage = self.contextUsage() } };
    }
};
