const std = @import("std");
const ai = @import("../ai/root.zig");
const config = @import("config.zig");
const stream = @import("stream.zig");
const failure = @import("failure.zig"); // ziglint-ignore: Z013
const message_memory = @import("../ai/root.zig").message_memory;

pub const StreamOp = struct {
    allocator: std.mem.Allocator,
    queue: stream.Queue,
    terminal_seen: bool = false,

    pub fn init(allocator: std.mem.Allocator) !StreamOp {
        return .{ .allocator = allocator, .queue = try stream.Queue.init(allocator) };
    }

    pub fn deinit(self: *StreamOp) void {
        self.queue.deinit();
        self.* = undefined;
    }

    pub fn start(
        self: *StreamOp,
        hook: config.StreamHook,
        model: ai.protocol.Model,
        context: ai.protocol.Context,
        options: ai.protocol.SimpleStreamOptions,
    ) void {
        self.queue.reserveTerminal() catch {
            self.queue.pushTerminal(.{ .failed = .{ .internal = "stream terminal reservation failed" } });
            return;
        };
        const sink = ai.provider.StreamEventSink{ .func = providerCallback, .ctx = self }; // ziglint-ignore: Z004
        hook.call(self.allocator, model, context, options, sink) catch |err| {
            self.pushTerminalIfNeeded(.{ .failed = .{ .out_of_memory = @errorName(err) } });
        };
        self.pushTerminalIfNeeded(.{ .failed = .{ .stream_failed = "stream ended without terminal event" } });
    }

    pub fn next(self: *StreamOp) ?stream.Completion {
        return self.queue.pop();
    }

    fn providerCallback(value: ai.protocol.AssistantMessageEvent, ctx: ?*anyopaque) void {
        const self: *StreamOp = @ptrCast(@alignCast(ctx.?));
        switch (value) {
            .start => self.pushDelta(value),
            .done => |done| {
                const owned = message_memory.cloneAssistant(self.allocator, done.message) catch {
                    self.pushTerminalIfNeeded(.{ .failed = .{ .out_of_memory = "clone stream assistant" } });
                    return;
                };
                self.pushTerminalIfNeeded(.{ .completed = owned });
            },
            .@"error" => |err| {
                const detail = err.@"error".error_message orelse "provider stream error";
                std.log.warn("provider stream error: {s}", .{detail});
                self.pushTerminalIfNeeded(.{ .failed = .{ .stream_failed = "provider stream error" } });
            },
            else => self.pushDelta(value),
        }
    }

    fn pushDelta(self: *StreamOp, value: ai.protocol.AssistantMessageEvent) void {
        const owned = message_memory.cloneAssistantEvent(self.allocator, value) catch {
            self.pushTerminalIfNeeded(.{ .failed = .{ .out_of_memory = "clone stream delta" } });
            return;
        };
        self.queue.pushDelta(owned);
    }

    fn pushTerminalIfNeeded(self: *StreamOp, terminal: stream.Terminal) void {
        if (self.terminal_seen) return;
        self.terminal_seen = true;
        self.queue.pushTerminal(terminal);
    }
};

test "stream op converts provider callback to terminal completion" {
    const Hook = struct {
        fn call(
            _: ?*anyopaque,
            _: std.mem.Allocator, // ziglint-ignore: Z023
            _: ai.protocol.Model,
            _: ai.protocol.Context,
            _: ai.protocol.SimpleStreamOptions,
            sink: ai.provider.StreamEventSink,
        ) error{OutOfMemory}!void {
            sink.emit(.{ .done = .{ .reason = .stop, .message = .{
                .content = &.{},
                .api = .openai_responses,
                .provider = .openai,
                .model = "test",
                .usage = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total_tokens = 0, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 } }, // ziglint-ignore: Z024
                .stop_reason = .stop,
                .timestamp = 0,
            } } });
        }
    };

    var op = try StreamOp.init(std.testing.allocator);
    defer op.deinit();
    op.start(.{ .call_fn = Hook.call }, .{
        .id = "test",
        .name = "test",
        .api = .openai_responses,
        .provider = .openai,
        .base_url = "",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 0,
        .max_tokens = 0,
    }, .{ .messages = &.{}, .tools = null, .system_prompt = null }, .{ .base = .{ .io = std.testing.io } });

    var saw_terminal = false;
    while (op.next()) |completion| switch (completion) {
        .terminal => |terminal| switch (terminal) {
            .completed => |assistant| {
                saw_terminal = true;
                message_memory.freeAssistant(std.testing.allocator, assistant);
            },
            else => {},
        },
        else => {},
    };
    try std.testing.expect(saw_terminal);
}
