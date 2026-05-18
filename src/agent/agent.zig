const std = @import("std");
const event = @import("event.zig");
const history_mod = @import("history.zig");
const projection_mod = @import("conversation_state.zig");
const state_mod = @import("state.zig");
const message = @import("message.zig");
const config_mod = @import("config.zig");
const run_mod = @import("run.zig");
const cancel = @import("../runtime/cancel.zig");

pub const Agent = struct {
    allocator: std.mem.Allocator,
    history: history_mod.History,
    projection: projection_mod.Projection = .{},
    listeners: std.ArrayListUnmanaged(Listener) = .empty,
    next_listener_id: u64 = 1,
    abort_source: cancel.Source = .{},

    const Listener = struct {
        id: u64,
        sink: event.Sink,
    };

    pub const Subscription = struct { id: u64 };

    pub fn init(allocator: std.mem.Allocator) Agent {
        return .{ .allocator = allocator, .history = history_mod.History.init(allocator) };
    }

    pub fn deinit(self: *Agent) void {
        self.listeners.deinit(self.allocator);
        self.history.deinit();
        self.* = undefined;
    }

    pub fn subscribe(self: *Agent, listener_sink: event.Sink) !Subscription {
        const id = self.next_listener_id;
        self.next_listener_id +%= 1;
        try self.listeners.append(self.allocator, .{ .id = id, .sink = listener_sink });
        return .{ .id = id };
    }

    pub fn unsubscribe(self: *Agent, token: Subscription) void {
        for (self.listeners.items, 0..) |listener, i| {
            if (listener.id == token.id) {
                _ = self.listeners.orderedRemove(i);
                return;
            }
        }
    }

    pub fn sink(self: *Agent) event.Sink {
        return .{ .emit_fn = applyEventSink, .ctx = self };
    }

    pub fn applyEventSink(value: event.AgentEvent, ctx: ?*anyopaque) void {
        const self: *Agent = @ptrCast(@alignCast(ctx.?));
        self.applyEvent(value) catch |err| {
            std.log.scoped(.agent).err("failed to apply event: {s}", .{@errorName(err)});
        };
    }

    pub fn applyEvent(self: *Agent, value: event.AgentEvent) !void {
        const effect = self.projection.apply(value);
        switch (effect) {
            .none, .terminal => {},
            .commit_message => |msg| try self.history.append(msg),
        }
        for (self.listeners.items) |listener| listener.sink.emit(value);
    }

    pub fn state(self: *const Agent) state_mod.AgentState {
        return .{
            .messages = self.history.view(),
            .activity = switch (self.projection.state) {
                .idle => .idle,
                .running => |running| .{ .running = .{ .turn_open = running.turn_open, .pending_tool_count = running.pending_tool_count } },
                .failed => |reason| .{ .failed = .{ .reason = reason } },
                .aborted => .aborted,
            },
        };
    }

    pub fn abort(self: *Agent) void {
        self.abort_source.requestAbort();
    }

    pub fn runStream(self: *Agent, input: message.AgentInput, config: config_mod.RunConfig) void {
        const signal = self.abort_source.beginRun();
        var run = run_mod.Run.init(self.allocator, input, self.sink(), signal);
        defer run.deinit();
        run.runStream(config);
    }
};

test "agent applies before notifying listeners" {
    const Collector = struct {
        saw_committed: bool = false,
        agent: *Agent,
        fn emit(_: event.AgentEvent, ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.saw_committed = self.agent.state().messages.len == 1;
        }
    };

    var agent = Agent.init(std.testing.allocator);
    defer agent.deinit();
    var collector = Collector{ .agent = &agent };
    _ = try agent.subscribe(.{ .emit_fn = Collector.emit, .ctx = &collector });

    try agent.applyEvent(.{ .lifecycle = .{ .turn_finished = .{ .completed = .{
        .message = .{ .assistant = .{
            .content = &.{},
            .api = .openai_responses,
            .provider = .openai,
            .model = "test",
            .usage = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total_tokens = 0, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 } },
            .stop_reason = .stop,
            .timestamp = 0,
        } },
        .tool_results = &.{},
    } } } });
    try std.testing.expect(collector.saw_committed);
}
