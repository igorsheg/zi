const std = @import("std");
const WakeEvent = @import("wake_event.zig").WakeEvent;

pub fn EventPipe(comptime Event: type, comptime TerminalResult: type) type {
    return struct {
        const Self = @This();
        const Queue = std.Io.Queue(Event);

        io: std.Io,
        queue: Queue,
        capacity_count: usize,
        wake: ?WakeRegistration = null,
        closed: bool = false,
        terminal_result: ?TerminalResult = null,

        const WakeRegistration = struct {
            io: std.Io,
            event: *WakeEvent,
        };

        pub const EmitError = error{
            Closed,
            Canceled,
            Terminal,
        };

        pub const NextError = error{
            Canceled,
        };

        pub fn init(io: std.Io, buffer: []Event) Self {
            std.debug.assert(buffer.len > 0);
            return .{
                .io = io,
                .queue = Queue.init(buffer),
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

        pub fn setWake(self: *Self, io: std.Io, event: *WakeEvent) void {
            self.wake = .{ .io = io, .event = event };
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

            pub fn result(self: Stream) ?TerminalResult {
                return self.pipe.result();
            }
        };

        fn emit(self: *Self, event: Event) EmitError!void {
            if (self.closed) return error.Terminal;
            self.queue.putAll(self.io, &.{event}) catch |err| switch (err) {
                error.Closed => return error.Terminal,
                error.Canceled => return error.Canceled,
            };
            self.wakeOwner();
        }

        fn end(self: *Self, event: Event, terminal_result: TerminalResult) EmitError!void {
            if (self.closed) return error.Terminal;
            self.terminal_result = terminal_result;
            self.closed = true;
            self.queue.putAll(self.io, &.{event}) catch |err| switch (err) {
                error.Closed => {
                    self.terminal_result = null;
                    return error.Terminal;
                },
                error.Canceled => {
                    self.terminal_result = null;
                    self.queue.close(self.io);
                    return error.Canceled;
                },
            };
            self.queue.close(self.io);
            self.wakeOwner();
        }

        fn abort(self: *Self) void {
            if (self.closed) return;
            self.closed = true;
            self.queue.close(self.io);
            self.wakeOwner();
        }

        fn next(self: *Self) NextError!?Event {
            return self.queue.getOne(self.io) catch |err| switch (err) {
                error.Closed => null,
                error.Canceled => error.Canceled,
            };
        }

        fn poll(self: *Self) Stream.Poll {
            var item: [1]Event = undefined;
            const count = self.queue.get(self.io, &item, 0) catch |err| switch (err) {
                error.Closed => return .terminal,
                error.Canceled => return .empty,
            };
            if (count == 0) return .empty;
            return .{ .event = item[0] };
        }

        fn result(self: *const Self) ?TerminalResult {
            return self.terminal_result;
        }

        fn wakeOwner(self: *Self) void {
            if (self.wake) |wake| wake.event.set(wake.io);
        }
    };
}

test "event pipe exposes explicit capacity" {
    const Pipe = EventPipe(u8, u8);
    var buffer: [2]u8 = undefined;
    var pipe = Pipe.init(std.testing.io, &buffer);

    try std.testing.expectEqual(@as(usize, 2), pipe.capacity());
}

test "event pipe wakes owner on emit end and abort" {
    const Pipe = EventPipe(u8, u8);
    var buffer: [2]u8 = undefined;
    var pipe = Pipe.init(std.testing.io, &buffer);
    var wake: WakeEvent = .init;
    pipe.setWake(std.testing.io, &wake);
    const sink = pipe.sink();

    try sink.emit(1);
    try std.testing.expect(wake.isSet());
    wake.reset();

    try sink.end(2, 9);
    try std.testing.expect(wake.isSet());

    var abort_buffer: [1]u8 = undefined;
    var abort_pipe = Pipe.init(std.testing.io, &abort_buffer);
    var abort_wake: WakeEvent = .init;
    abort_pipe.setWake(std.testing.io, &abort_wake);
    abort_pipe.sink().abort();
    try std.testing.expect(abort_wake.isSet());
}

test "event pipe drains events in order before terminal" {
    const Pipe = EventPipe(u8, u8);
    var buffer: [2]u8 = undefined;
    var pipe = Pipe.init(std.testing.io, &buffer);
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
    var pipe = Pipe.init(std.testing.io, &buffer);
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
    var pipe = Pipe.init(std.testing.io, &buffer);
    const sink = pipe.sink();

    try sink.end(1, 9);
    try std.testing.expectError(error.Terminal, sink.emit(2));
}

test "event pipe abort drains queued events without terminal result" {
    const Pipe = EventPipe(u8, u8);
    var buffer: [2]u8 = undefined;
    var pipe = Pipe.init(std.testing.io, &buffer);
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
    var pipe = Pipe.init(std.testing.io, &buffer);
    const sink = pipe.sink();
    const stream = pipe.stream();

    try sink.emit(1);
    try std.testing.expectEqual(@as(?u8, null), stream.result());
    try std.testing.expectEqual(@as(?u8, 1), try stream.next());
}

const ConcurrentProducerState = struct {
    pipe: *EventPipe(u8, u8),
    entered: WakeEvent = .init,
};

fn produceMoreThanCapacity(state: *ConcurrentProducerState) anyerror!void {
    state.entered.set(state.pipe.io);
    const sink = state.pipe.sink();
    try sink.emit(1);
    try sink.emit(2);
    try sink.emit(3);
    try sink.end(4, 9);
}

test "event pipe supports bounded concurrent producer and owner drain" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const Pipe = EventPipe(u8, u8);
    var buffer: [1]u8 = undefined;
    var pipe = Pipe.init(io, &buffer);
    var state: ConcurrentProducerState = .{ .pipe = &pipe };
    var future = try std.Io.concurrent(io, produceMoreThanCapacity, .{&state});
    defer _ = future.cancel(io) catch {};

    try state.entered.wait(io);

    const stream = pipe.stream();
    try std.testing.expectEqual(@as(?u8, 1), try stream.next());
    try std.testing.expectEqual(@as(?u8, 2), try stream.next());
    try std.testing.expectEqual(@as(?u8, 3), try stream.next());
    try std.testing.expectEqual(@as(?u8, 4), try stream.next());
    try std.testing.expectEqual(@as(?u8, null), try stream.next());
    try std.testing.expectEqual(@as(?u8, 9), stream.result());
    try future.await(io);
}
