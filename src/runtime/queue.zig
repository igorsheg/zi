const std = @import("std");

pub fn BoundedQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        items: []T,
        head: usize = 0,
        len: usize = 0,

        pub const Error = error{Full};

        pub fn init(allocator: std.mem.Allocator, cap: usize) !Self {
            std.debug.assert(cap > 0);
            return .{
                .allocator = allocator,
                .items = try allocator.alloc(T, cap),
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.items);
            self.* = undefined;
        }

        pub fn capacity(self: *const Self) usize {
            return self.items.len;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.len == 0;
        }

        pub fn isFull(self: *const Self) bool {
            return self.len == self.items.len;
        }

        pub fn push(self: *Self, item: T) Error!void {
            if (self.isFull()) return error.Full;
            const index = (self.head + self.len) % self.items.len;
            self.items[index] = item;
            self.len += 1;
        }

        pub fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            const item = self.items[self.head];
            self.discardFront();
            return item;
        }

        pub fn peek(self: *const Self) ?T {
            if (self.len == 0) return null;
            return self.items[self.head];
        }

        pub fn discardFront(self: *Self) void {
            std.debug.assert(self.len > 0);
            self.head = (self.head + 1) % self.items.len;
            self.len -= 1;
        }
    };
}

test "bounded queue rejects overflow and preserves order" {
    var q = try BoundedQueue(u8).init(std.testing.allocator, 2);
    defer q.deinit();

    try q.push(1);
    try q.push(2);
    try std.testing.expectError(error.Full, q.push(3));
    try std.testing.expectEqual(@as(?u8, 1), q.pop());
    try q.push(3);
    try std.testing.expectEqual(@as(?u8, 2), q.pop());
    try std.testing.expectEqual(@as(?u8, 3), q.pop());
    try std.testing.expectEqual(@as(?u8, null), q.pop());
}
