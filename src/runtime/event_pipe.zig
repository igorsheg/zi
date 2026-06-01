const std = @import("std");

pub fn EventPipe(comptime Event: type, comptime Result: type) type {
    return struct {
        const Self = @This();
        const Queue = std.Io.Queue(Event);

        queue: Queue,
        closed: bool = false,
        terminal_result: ?Result = null,

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
            return .{ .queue = Queue.init(buffer) };
        }

        pub fn capacity(self: *const Self) usize {
            return self.queue.capacity();
        }

        pub fn sink(self: *Self) Sink {
            return .{ .pipe = self };
        }

        pub fn stream(self: *Self) Stream {
            return .{ .pipe = self };
        }

        pub const Sink = struct {
            pipe: *Self,

            pub fn emit(self: Sink, io: std.Io, event: Event) EmitError!void {
                try self.pipe.emit(io, event);
            }

            pub fn end(self: Sink, io: std.Io, event: Event, terminal_result: Result) EmitError!void {
                try self.pipe.end(io, event, terminal_result);
            }

            pub fn abort(self: Sink, io: std.Io) void {
                self.pipe.abort(io);
            }
        };

        pub const Stream = struct {
            pipe: *Self,

            pub fn next(self: Stream, io: std.Io) NextError!?Event {
                return self.pipe.next(io);
            }

            pub fn result(self: Stream) ?Result {
                return self.pipe.result();
            }
        };

        fn emit(self: *Self, io: std.Io, event: Event) EmitError!void {
            if (self.closed) return error.Terminal;
            try self.queue.putOne(io, event);
        }

        fn end(self: *Self, io: std.Io, event: Event, terminal_result: Result) EmitError!void {
            if (self.closed) return error.Terminal;
            try self.queue.putOne(io, event);
            self.terminal_result = terminal_result;
            self.closed = true;
            self.queue.close(io);
        }

        fn abort(self: *Self, io: std.Io) void {
            if (self.closed) return;
            self.closed = true;
            self.queue.close(io);
        }

        fn next(self: *Self, io: std.Io) NextError!?Event {
            return self.queue.getOne(io) catch |err| switch (err) {
                error.Closed => null,
                error.Canceled => error.Canceled,
            };
        }

        fn result(self: *const Self) ?Result {
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

    try sink.emit(std.Io.failing, 1);
    try sink.end(std.Io.failing, 2, 9);

    try std.testing.expectEqual(@as(?u8, 1), try stream.next(std.Io.failing));
    try std.testing.expectEqual(@as(?u8, 2), try stream.next(std.Io.failing));
    try std.testing.expectEqual(@as(?u8, null), try stream.next(std.Io.failing));
    try std.testing.expectEqual(@as(?u8, 9), stream.result());
}

test "event pipe rejects events after terminal" {
    const Pipe = EventPipe(u8, u8);
    var buffer: [1]u8 = undefined;
    var pipe = Pipe.init(&buffer);
    const sink = pipe.sink();

    try sink.end(std.Io.failing, 1, 9);
    try std.testing.expectError(error.Terminal, sink.emit(std.Io.failing, 2));
}

test "event pipe abort drains queued events without terminal result" {
    const Pipe = EventPipe(u8, u8);
    var buffer: [2]u8 = undefined;
    var pipe = Pipe.init(&buffer);
    const sink = pipe.sink();
    const stream = pipe.stream();

    try sink.emit(std.Io.failing, 1);
    sink.abort(std.Io.failing);

    try std.testing.expectError(error.Terminal, sink.emit(std.Io.failing, 2));
    try std.testing.expectEqual(@as(?u8, 1), try stream.next(std.Io.failing));
    try std.testing.expectEqual(@as(?u8, null), try stream.next(std.Io.failing));
    try std.testing.expectEqual(@as(?u8, null), stream.result());
}

test "event pipe leaves terminal empty when nonterminal event is queued" {
    const Pipe = EventPipe(u8, u8);
    var buffer: [1]u8 = undefined;
    var pipe = Pipe.init(&buffer);
    const sink = pipe.sink();
    const stream = pipe.stream();

    try sink.emit(std.Io.failing, 1);
    try std.testing.expectEqual(@as(?u8, null), stream.result());
    try std.testing.expectEqual(@as(?u8, 1), try stream.next(std.Io.failing));
}

const ConcurrentProducerState = struct {
    pipe: *EventPipe(u8, u8),
    entered: std.atomic.Value(bool) = .init(false),
};

fn produceMoreThanCapacity(io: std.Io, state: *ConcurrentProducerState) !void {
    state.entered.store(true, .release);
    const sink = state.pipe.sink();
    try sink.emit(io, 1);
    try sink.emit(io, 2);
    try sink.emit(io, 3);
    try sink.end(io, 4, 9);
}

test "event pipe supports bounded concurrent producer and owner drain" {
    const Pipe = EventPipe(u8, u8);
    var buffer: [1]u8 = undefined;
    var pipe = Pipe.init(&buffer);
    var state: ConcurrentProducerState = .{ .pipe = &pipe };
    var future = std.testing.io.async(produceMoreThanCapacity, .{ std.testing.io, &state });

    while (!state.entered.load(.acquire)) {
        std.testing.io.sleep(.fromMilliseconds(1), .awake) catch |err| switch (err) {
            error.Canceled => return err,
        };
    }

    const stream = pipe.stream();
    try std.testing.expectEqual(@as(?u8, 1), try stream.next(std.testing.io));
    try std.testing.expectEqual(@as(?u8, 2), try stream.next(std.testing.io));
    try std.testing.expectEqual(@as(?u8, 3), try stream.next(std.testing.io));
    try std.testing.expectEqual(@as(?u8, 4), try stream.next(std.testing.io));
    try std.testing.expectEqual(@as(?u8, null), try stream.next(std.testing.io));
    try std.testing.expectEqual(@as(?u8, 9), stream.result());
    try future.await(std.testing.io);
}
