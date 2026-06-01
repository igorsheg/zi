const std = @import("std");
const zio = @import("zio");
const Runtime = zio.Runtime;

pub fn EventPipe(comptime Event: type, comptime TerminalResult: type) type {
    return struct {
        const Self = @This();
        const Channel = zio.Channel(Event);
        const ChannelReceive = @TypeOf(@as(*Channel, undefined).asyncReceive());

        channel: Channel,
        capacity_count: usize,
        closed: bool = false,
        terminal_result: ?TerminalResult = null,

        pub const EmitError = error{
            Closed,
            Canceled,
            Terminal,
        };

        pub const NextError = error{
            Canceled,
        };

        pub fn init(buffer: []Event) Self {
            std.debug.assert(buffer.len > 0);
            return .{
                .channel = Channel.init(buffer),
                .capacity_count = buffer.len,
            };
        }

        pub fn capacity(self: *const Self) usize {
            return self.capacity_count;
        }

        pub fn sink(self: *Self) Sink {
            return .{ .pipe = self };
        }

        pub fn stream(self: *Self) Stream {
            return .{ .pipe = self };
        }

        pub const Sink = struct {
            pipe: *Self,

            pub fn emit(self: Sink, event: Event) EmitError!void {
                try self.pipe.emit(event);
            }

            pub fn end(self: Sink, event: Event, terminal_result: TerminalResult) EmitError!void {
                try self.pipe.end(event, terminal_result);
            }

            pub fn abort(self: Sink) void {
                self.pipe.abort();
            }
        };

        pub const Stream = struct {
            pipe: *Self,

            pub const Poll = union(enum) {
                event: Event,
                empty,
                terminal,
            };

            pub fn next(self: Stream) NextError!?Event {
                return self.pipe.next();
            }

            pub fn poll(self: Stream) Poll {
                return self.pipe.poll();
            }

            pub fn asyncNext(self: Stream) AsyncNext {
                return .{ .receive = self.pipe.channel.asyncReceive() };
            }

            pub fn result(self: Stream) ?TerminalResult {
                return self.pipe.result();
            }

            pub const AsyncNext = struct {
                receive: ChannelReceive,

                pub const Result = ?Event;
                pub const WaitContext = ChannelReceive.WaitContext;

                pub fn asyncWait(self: *const AsyncNext, waiter: anytype, context: *WaitContext) bool {
                    return self.receive.asyncWait(waiter, context);
                }

                pub fn asyncCancelWait(self: *const AsyncNext, waiter: anytype, context: *WaitContext) bool {
                    return self.receive.asyncCancelWait(waiter, context);
                }

                pub fn getResult(self: *const AsyncNext, context: *WaitContext) Result {
                    return self.receive.getResult(context) catch |err| switch (err) {
                        error.ChannelClosed => null,
                    };
                }
            };
        };

        fn emit(self: *Self, event: Event) EmitError!void {
            if (self.closed) return error.Terminal;
            self.channel.send(event) catch |err| switch (err) {
                error.ChannelClosed => return error.Terminal,
                error.Canceled => return error.Canceled,
            };
        }

        fn end(self: *Self, event: Event, terminal_result: TerminalResult) EmitError!void {
            if (self.closed) return error.Terminal;
            self.terminal_result = terminal_result;
            self.closed = true;
            self.channel.send(event) catch |err| switch (err) {
                error.ChannelClosed => {
                    self.terminal_result = null;
                    return error.Terminal;
                },
                error.Canceled => {
                    self.terminal_result = null;
                    self.channel.close(.graceful);
                    return error.Canceled;
                },
            };
            self.channel.close(.graceful);
        }

        fn abort(self: *Self) void {
            if (self.closed) return;
            self.closed = true;
            self.channel.close(.graceful);
        }

        fn next(self: *Self) NextError!?Event {
            return self.channel.receive() catch |err| switch (err) {
                error.ChannelClosed => null,
                error.Canceled => error.Canceled,
            };
        }

        fn poll(self: *Self) Stream.Poll {
            const event = self.channel.tryReceive() catch |err| switch (err) {
                error.ChannelEmpty => return .empty,
                error.ChannelClosed => return .terminal,
            };
            return .{ .event = event };
        }

        fn result(self: *const Self) ?TerminalResult {
            return self.terminal_result;
        }
    };
}

test "event pipe exposes explicit capacity" {
    const Pipe = EventPipe(u8, u8);
    var buffer: [2]u8 = undefined;
    var pipe = Pipe.init(&buffer);

    try std.testing.expectEqual(@as(usize, 2), pipe.capacity());
}

test "event pipe drains events in order before terminal" {
    const Pipe = EventPipe(u8, u8);
    var buffer: [2]u8 = undefined;
    var pipe = Pipe.init(&buffer);
    const sink = pipe.sink();
    const stream = pipe.stream();

    try sink.emit(1);
    try sink.end(2, 9);

    try std.testing.expectEqual(@as(?u8, 1), try stream.next());
    try std.testing.expectEqual(@as(?u8, 2), try stream.next());
    try std.testing.expectEqual(@as(?u8, null), try stream.next());
    try std.testing.expectEqual(@as(?u8, 9), stream.result());
}

test "event pipe commits terminal result before terminal event is observed" {
    const Pipe = EventPipe(u8, u8);
    var buffer: [1]u8 = undefined;
    var pipe = Pipe.init(&buffer);
    const sink = pipe.sink();
    const stream = pipe.stream();

    try sink.end(1, 9);

    try std.testing.expectEqual(@as(?u8, 9), stream.result());
    try std.testing.expectEqual(@as(?u8, 1), try stream.next());
    try std.testing.expectEqual(@as(?u8, 9), stream.result());
}

test "event pipe rejects events after terminal" {
    const Pipe = EventPipe(u8, u8);
    var buffer: [1]u8 = undefined;
    var pipe = Pipe.init(&buffer);
    const sink = pipe.sink();

    try sink.end(1, 9);
    try std.testing.expectError(error.Terminal, sink.emit(2));
}

test "event pipe abort drains queued events without terminal result" {
    const Pipe = EventPipe(u8, u8);
    var buffer: [2]u8 = undefined;
    var pipe = Pipe.init(&buffer);
    const sink = pipe.sink();
    const stream = pipe.stream();

    try sink.emit(1);
    sink.abort();

    try std.testing.expectError(error.Terminal, sink.emit(2));
    try std.testing.expectEqual(@as(?u8, 1), try stream.next());
    try std.testing.expectEqual(@as(?u8, null), try stream.next());
    try std.testing.expectEqual(@as(?u8, null), stream.result());
}

test "event pipe leaves terminal empty when nonterminal event is queued" {
    const Pipe = EventPipe(u8, u8);
    var buffer: [1]u8 = undefined;
    var pipe = Pipe.init(&buffer);
    const sink = pipe.sink();
    const stream = pipe.stream();

    try sink.emit(1);
    try std.testing.expectEqual(@as(?u8, null), stream.result());
    try std.testing.expectEqual(@as(?u8, 1), try stream.next());
}

const ConcurrentProducerState = struct {
    pipe: *EventPipe(u8, u8),
    entered: zio.ResetEvent = .init,
};

fn produceMoreThanCapacity(state: *ConcurrentProducerState) !void {
    state.entered.set();
    const sink = state.pipe.sink();
    try sink.emit(1);
    try sink.emit(2);
    try sink.emit(3);
    try sink.end(4, 9);
}

test "event pipe supports bounded concurrent producer and owner drain" {
    var zio_runtime = try Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    const Pipe = EventPipe(u8, u8);
    var buffer: [1]u8 = undefined;
    var pipe = Pipe.init(&buffer);
    var state: ConcurrentProducerState = .{ .pipe = &pipe };
    var future = try zio_runtime.spawn(produceMoreThanCapacity, .{&state});
    defer future.cancel();

    try state.entered.wait();

    const stream = pipe.stream();
    try std.testing.expectEqual(@as(?u8, 1), try stream.next());
    try std.testing.expectEqual(@as(?u8, 2), try stream.next());
    try std.testing.expectEqual(@as(?u8, 3), try stream.next());
    try std.testing.expectEqual(@as(?u8, 4), try stream.next());
    try std.testing.expectEqual(@as(?u8, null), try stream.next());
    try std.testing.expectEqual(@as(?u8, 9), stream.result());
    try future.join();
}
