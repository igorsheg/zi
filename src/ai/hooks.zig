const std = @import("std");
const ai = @import("root.zig");

pub const StreamHook = struct {
    ctx: ?*anyopaque = null,
    call_fn: *const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        model: ai.protocol.Model,
        context: ai.protocol.Context,
        options: ai.protocol.SimpleStreamOptions,
        sink: ai.provider.StreamEventSink,
    ) error{OutOfMemory}!void,

    pub fn call(
        self: StreamHook,
        allocator: std.mem.Allocator,
        model: ai.protocol.Model,
        context: ai.protocol.Context,
        options: ai.protocol.SimpleStreamOptions,
        sink: ai.provider.StreamEventSink,
    ) error{OutOfMemory}!void {
        return self.call_fn(self.ctx, allocator, model, context, options, sink);
    }
};

pub const ConvertMessagesHook = struct {
    ctx: ?*anyopaque = null,
    call_fn: *const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator, messages: []const ai.protocol.AgentMessage) error{OutOfMemory}![]const ai.protocol.Message, // ziglint-ignore: Z024

    pub fn call(self: ConvertMessagesHook, allocator: std.mem.Allocator, messages: []const ai.protocol.AgentMessage) error{OutOfMemory}![]const ai.protocol.Message { // ziglint-ignore: Z024
        return self.call_fn(self.ctx, allocator, messages);
    }
};

pub const TransformContextHook = struct {
    ctx: ?*anyopaque = null,
    call_fn: *const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        messages: []const ai.protocol.AgentMessage,
    ) error{OutOfMemory}![]const ai.protocol.AgentMessage,

    pub fn call(
        self: TransformContextHook,
        allocator: std.mem.Allocator,
        messages: []const ai.protocol.AgentMessage,
    ) error{OutOfMemory}![]const ai.protocol.AgentMessage {
        return self.call_fn(self.ctx, allocator, messages);
    }
};
