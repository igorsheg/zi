const std = @import("std");
const operation = @import("Operation.zig");

pub fn CompletionQueue(comptime Completion: type) type {
    return struct {
        const Self = @This();

        buffer: []Completion,
        head: usize = 0,
        tail: usize = 0,
        len: usize = 0,
        terminal_count: usize = 0,

        pub const PushError = error{Full};

        pub fn init(buffer: []Completion) Self {
            std.debug.assert(buffer.len > 0);
            return .{ .buffer = buffer };
        }

        pub fn capacity(self: *const Self) usize {
            return self.buffer.len;
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }

        pub fn push(self: *Self, completion: Completion) PushError!void {
            if (self.len == self.buffer.len) return error.Full;
            self.buffer[self.tail] = completion;
            self.tail = (self.tail + 1) % self.buffer.len;
            self.len += 1;
            if (isTerminal(completion)) self.terminal_count += 1;
        }

        pub fn pop(self: *Self) ?Completion {
            if (self.len == 0) return null;
            const completion = self.buffer[self.head];
            self.head = (self.head + 1) % self.buffer.len;
            self.len -= 1;
            return completion;
        }

        pub fn terminalCompletions(self: *const Self) usize {
            return self.terminal_count;
        }
    };
}

pub const TestCompletion = union(enum) {
    event: operation.OperationId,
    done: operation.OperationId,
    failed: operation.OperationId,
    canceled: operation.OperationId,
};

pub fn isTerminal(completion: anytype) bool {
    return switch (completion) {
        .done, .failed, .canceled => true,
        else => false,
    };
}

test "completion queue is bounded and preserves fifo order" {
    const Queue = CompletionQueue(TestCompletion);
    var buffer: [2]TestCompletion = undefined;
    var queue = Queue.init(&buffer);
    const first = operation.OperationId.first();
    const second = first.next();

    try queue.push(.{ .event = first });
    try queue.push(.{ .done = second });
    try std.testing.expectError(error.Full, queue.push(.{ .failed = second.next() }));

    try std.testing.expectEqual(@as(TestCompletion, .{ .event = first }), queue.pop().?);
    try std.testing.expectEqual(@as(TestCompletion, .{ .done = second }), queue.pop().?);
    try std.testing.expect(queue.pop() == null);
}

test "completion queue counts terminal completions without dropping them silently" {
    const Queue = CompletionQueue(TestCompletion);
    var buffer: [4]TestCompletion = undefined;
    var queue = Queue.init(&buffer);
    const id = operation.OperationId.first();

    try queue.push(.{ .event = id });
    try queue.push(.{ .canceled = id });

    try std.testing.expectEqual(@as(usize, 1), queue.terminalCompletions());
}
