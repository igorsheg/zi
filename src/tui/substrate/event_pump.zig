const std = @import("std");

const primitive = @import("../primitive/root.zig");
const runtime = @import("../../runtime/root.zig");
const terminal = @import("terminal.zig");

pub const TerminalEvents = struct {
    pub const capacity_count = 512;

    const Channel = runtime.Channel(terminal.Event);
    const ChannelReceive = @TypeOf(@as(*Channel, undefined).asyncReceive());

    loop: *terminal.EventLoop,
    buffer: [capacity_count]terminal.Event = undefined,
    channel: Channel = undefined,
    pump: runtime.JoinHandle(anyerror!void),
    loop_started: bool = false,

    pub fn init(
        self: *TerminalEvents,
        zio_runtime: *runtime.Runtime,
        loop: *terminal.EventLoop,
    ) !void {
        self.loop = loop;
        self.channel = Channel.init(&self.buffer);
        try loop.start();
        self.loop_started = true;
        errdefer {
            self.loop.stop();
            self.loop_started = false;
        }
        self.pump = try zio_runtime.spawn(pumpTerminalEvents, .{ loop, &self.channel });
    }

    pub fn deinit(self: *TerminalEvents) void {
        if (self.loop_started) {
            self.loop.stop();
            self.loop_started = false;
        }
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
        const event = terminal.Event.copyFromVaxis(try loop.nextEvent()) catch |err| switch (err) {
            // The terminal event queue carries owned, fixed-size key text. Drop
            // oversized key payloads at the substrate boundary as invalid input.
            error.KeyTextTooLarge => continue,
        };
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

    var env_map = try std.testing.environ.createMap(std.testing.allocator);
    defer env_map.deinit();

    var tty = try vaxis.Tty.init(io, &.{});
    defer tty.deinit();

    var vx = try vaxis.init(io, std.testing.allocator, &env_map, .{});
    defer vx.deinit(std.testing.allocator, tty.writer());

    var loop = terminal.EventLoop.init(io, &tty, &vx);
    var terminal_events: TerminalEvents = undefined;
    try terminal_events.init(zio_runtime, &loop);
    defer terminal_events.deinit();

    try loop.postEvent(.focus_in);

    const receive = terminal_events.asyncNext();
    const selected = try runtime.select(.{ .terminal = receive });
    try std.testing.expectEqual(terminal.Event.focus_in, selected.terminal.?);
}

test "terminal events copy key text before crossing zio channel boundary" {
    var source = [_]u8{ 'h', 'i' };

    const event = try terminal.Event.copyFromVaxis(.{
        .key_press = .{
            .codepoint = 'h',
            .text = source[0..],
        },
    });
    source[0] = 'b';

    try std.testing.expectEqualStrings("hi", event.key_press.text().?);
}

test "terminal events reject oversized key text before queueing" {
    const bytes = "x" ** (primitive.input.key_text_size_bytes_max + 1);

    try std.testing.expectError(
        error.KeyTextTooLarge,
        terminal.Event.copyFromVaxis(.{ .key_press = .{ .codepoint = 'x', .text = bytes } }),
    );
}
