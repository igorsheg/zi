const std = @import("std");
const ai = @import("../ai/root.zig");
const message = @import("message.zig");

pub const StreamHook = struct {
    ctx: ?*anyopaque = null,
    call_fn: *const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        model: message.Model,
        context: ai.protocol.Context,
        options: ai.protocol.SimpleStreamOptions,
        sink: ai.provider.StreamEventSink,
    ) error{OutOfMemory}!void,

    pub fn call(
        self: StreamHook,
        allocator: std.mem.Allocator,
        model: message.Model,
        context: ai.protocol.Context,
        options: ai.protocol.SimpleStreamOptions,
        sink: ai.provider.StreamEventSink,
    ) error{OutOfMemory}!void {
        return self.call_fn(self.ctx, allocator, model, context, options, sink);
    }
};

pub const ConvertMessagesHook = struct {
    ctx: ?*anyopaque = null,
    call_fn: *const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator, messages: []const message.AgentMessage) error{OutOfMemory}![]const ai.protocol.Message,

    pub fn call(self: ConvertMessagesHook, allocator: std.mem.Allocator, messages: []const message.AgentMessage) error{OutOfMemory}![]const ai.protocol.Message {
        return self.call_fn(self.ctx, allocator, messages);
    }
};

pub const MessageSourceHook = struct {
    ctx: ?*anyopaque = null,
    call_fn: *const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator) error{OutOfMemory}![]const message.AgentMessage,

    pub fn call(self: MessageSourceHook, allocator: std.mem.Allocator) error{OutOfMemory}![]const message.AgentMessage {
        return self.call_fn(self.ctx, allocator);
    }
};

pub const RunConfig = struct {
    model: message.Model,
    stream: StreamHook,
    convert_messages: ConvertMessagesHook,
    steering_messages: ?MessageSourceHook = null,
    follow_up_messages: ?MessageSourceHook = null,
    io: std.Io,
    temperature: ?f64 = null,
    max_tokens: ?u64 = null,
    api_key: ?[]const u8 = null,
    cache_retention: ?ai.protocol.CacheRetention = null,
    session_id: ?[]const u8 = null,
    max_retry_delay_ms: ?u64 = null,
    thinking_budgets: ?ai.protocol.ThinkingBudgets = null,
    transport: ?ai.protocol.Transport = null,
    reasoning: ?ai.protocol.ThinkingLevel = null,

    pub fn streamOptions(self: RunConfig) ai.protocol.SimpleStreamOptions {
        return .{
            .base = .{
                .io = self.io,
                .temperature = self.temperature,
                .max_tokens = self.max_tokens,
                .api_key = self.api_key,
                .cache_retention = self.cache_retention,
                .session_id = self.session_id,
                .max_retry_delay_ms = self.max_retry_delay_ms,
                .transport = self.transport,
            },
            .thinking_budgets = self.thinking_budgets,
            .reasoning = self.reasoning,
        };
    }
};
