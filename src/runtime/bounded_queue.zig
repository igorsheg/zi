const std = @import("std");

/// Fixed-capacity FIFO over caller-owned storage.
///
/// BoundedQueue never allocates and never destroys queued values. It is a
/// mechanism for non-owning values or values whose cleanup is handled by the
/// owner after pop(). Calling discardQueuedItems() forgets queued values
/// without cleanup.
pub fn BoundedQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        buffer: []T,
        head: usize = 0,
        tail: usize = 0,
        len: usize = 0,
        dropped_count: usize = 0,

        pub const PushError = error{Full};

        pub fn init(buffer: []T) Self {
            std.debug.assert(buffer.len > 0);
            return .{ .buffer = buffer };
        }

        pub fn capacity(self: *const Self) usize {
            return self.buffer.len;
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }

        pub fn empty(self: *const Self) bool {
            return self.len == 0;
        }

        pub fn dropped(self: *const Self) usize {
            return self.dropped_count;
        }

        pub fn push(self: *Self, item: T) PushError!void {
            if (self.len == self.buffer.len) return error.Full;
            self.buffer[self.tail] = item;
            self.tail = (self.tail + 1) % self.buffer.len;
            self.len += 1;
        }

        pub fn pushOrDrop(self: *Self, item: T) bool {
            self.push(item) catch |err| switch (err) {
                error.Full => {
                    self.dropped_count += 1;
                    return false;
                },
            };
            return true;
        }

        pub fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            const item = self.buffer[self.head];
            self.head = (self.head + 1) % self.buffer.len;
            self.len -= 1;
            return item;
        }

        pub fn discardQueuedItems(self: *Self) void {
            self.head = 0;
            self.tail = 0;
            self.len = 0;
        }
    };
}

test "bounded queue preserves fifo order and reports full" {
    const Queue = BoundedQueue(u8);
    var buffer: [2]u8 = undefined;
    var queue = Queue.init(&buffer);

    try std.testing.expectEqual(@as(usize, 2), queue.capacity());
    try std.testing.expect(queue.empty());
    try queue.push(1);
    try queue.push(2);
    try std.testing.expectError(error.Full, queue.push(3));

    try std.testing.expectEqual(@as(?u8, 1), queue.pop());
    try std.testing.expectEqual(@as(?u8, 2), queue.pop());
    try std.testing.expectEqual(@as(?u8, null), queue.pop());
    try std.testing.expect(queue.empty());
}

test "bounded queue pushOrDrop counts explicit drops" {
    const Queue = BoundedQueue(u8);
    var buffer: [1]u8 = undefined;
    var queue = Queue.init(&buffer);

    try std.testing.expect(queue.pushOrDrop(1));
    try std.testing.expect(!queue.pushOrDrop(2));

    try std.testing.expectEqual(@as(usize, 1), queue.count());
    try std.testing.expectEqual(@as(usize, 1), queue.dropped());
    try std.testing.expectEqual(@as(?u8, 1), queue.pop());
}

test "bounded queue discard keeps drop accounting observable" {
    const Queue = BoundedQueue(u8);
    var buffer: [1]u8 = undefined;
    var queue = Queue.init(&buffer);

    try queue.push(1);
    _ = queue.pushOrDrop(2);
    queue.discardQueuedItems();

    try std.testing.expect(queue.empty());
    try std.testing.expectEqual(@as(usize, 1), queue.dropped());
    try queue.push(3);
    try std.testing.expectEqual(@as(?u8, 3), queue.pop());
}
