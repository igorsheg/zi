const std = @import("std");
const zio = @import("zio");

const runtime = @import("../runtime/root.zig");
const terminal = @import("terminal.zig");

pub const TerminalEvents = struct {
    pub const capacity_count = 512;

    const Channel = zio.Channel(terminal.Event);
    const ChannelReceive = @TypeOf(@as(*Channel, undefined).asyncReceive());

    loop: *terminal.EventLoop,
    buffer: [capacity_count]terminal.Event = undefined,
    channel: Channel = undefined,
    pump: zio.JoinHandle(anyerror!void),

    pub fn init(
        self: *TerminalEvents,
        zio_runtime: *runtime.Runtime,
        loop: *terminal.EventLoop,
    ) !void {
        self.loop = loop;
        self.channel = Channel.init(&self.buffer);
        self.pump = try zio_runtime.spawn(pumpTerminalEvents, .{ loop, &self.channel });
    }

    pub fn deinit(self: *TerminalEvents) void {
        self.channel.close(.immediate);
        self.pump.cancel();
        self.pump.result catch |err| switch (err) {
            error.Canceled => {},
            else => std.debug.panic("terminal event pump failed during shutdown: {s}", .{@errorName(err)}),
        };
        self.* = undefined;
    }

    pub fn tryNext(self: *TerminalEvents) ?terminal.Event {
        return self.channel.tryReceive() catch |err| switch (err) {
            error.ChannelEmpty => null,
            error.ChannelClosed => null,
        };
    }

    pub fn next(self: *TerminalEvents) !?terminal.Event {
        return self.channel.receive() catch |err| switch (err) {
            error.ChannelClosed => null,
            error.Canceled => error.Canceled,
        };
    }

    pub fn asyncNext(self: *TerminalEvents) Receive {
        return .{ .receive = self.channel.asyncReceive() };
    }

    pub const Receive = struct {
        receive: ChannelReceive,

        pub const Result = ?terminal.Event;
        pub const WaitContext = ChannelReceive.WaitContext;

        pub fn asyncWait(self: *const Receive, waiter: anytype, context: *WaitContext) bool {
            return self.receive.asyncWait(waiter, context);
        }

        pub fn asyncCancelWait(self: *const Receive, waiter: anytype, context: *WaitContext) bool {
            return self.receive.asyncCancelWait(waiter, context);
        }

        pub fn getResult(self: *const Receive, context: *WaitContext) Result {
            return self.receive.getResult(context) catch |err| switch (err) {
                error.ChannelClosed => null,
            };
        }
    };
};

fn pumpTerminalEvents(
    loop: *terminal.EventLoop,
    channel: *TerminalEvents.Channel,
) anyerror!void {
    while (true) {
        const event = try loop.nextEvent();
        channel.send(event) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.ChannelClosed => return,
        };
    }
}

test "terminal events bridge forwards vaxis queue events through zio channel" {
    const vaxis = @import("vaxis");

    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    const io = zio_runtime.io();

    var tty: vaxis.Tty = undefined;
    var vx: vaxis.Vaxis = undefined;
    var loop = terminal.EventLoop.init(io, &tty, &vx);
    var terminal_events: TerminalEvents = undefined;
    try terminal_events.init(zio_runtime, &loop);
    defer terminal_events.deinit();

    try loop.postEvent(.focus_in);

    const receive = terminal_events.asyncNext();
    const selected = try zio.select(.{ .terminal = receive });
    try std.testing.expectEqual(terminal.Event.focus_in, selected.terminal.?);
}
