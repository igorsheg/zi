const std = @import("std");

pub const ByteBuilder = struct {
    allocator: std.mem.Allocator,
    buf: []u8 = &.{},
    len: usize = 0,
    capacity_max: ?usize = null,

    pub const Error = std.mem.Allocator.Error || error{CapacityExceeded};

    /// Creates a builder without an internal capacity ceiling. Use this only
    /// when the caller owns an external bound for all appended data.
    pub fn initUnbounded(allocator: std.mem.Allocator) ByteBuilder {
        return .{ .allocator = allocator };
    }

    pub fn initBounded(allocator: std.mem.Allocator, capacity_max: usize) ByteBuilder {
        return .{ .allocator = allocator, .capacity_max = capacity_max };
    }

    pub fn deinit(self: *ByteBuilder) void {
        self.allocator.free(self.buf);
        self.* = undefined;
    }

    pub fn clearRetainingCapacity(self: *ByteBuilder) void {
        self.len = 0;
    }

    pub fn items(self: *const ByteBuilder) []const u8 {
        std.debug.assert(self.len <= self.buf.len);
        return self.buf[0..self.len];
    }

    pub fn mutableItems(self: *ByteBuilder) []u8 {
        std.debug.assert(self.len <= self.buf.len);
        return self.buf[0..self.len];
    }

    pub fn ensureUnusedCapacity(self: *ByteBuilder, additional: usize) Error!void {
        std.debug.assert(self.len <= self.buf.len);
        if (additional <= self.buf.len - self.len) return;
        const needed = std.math.add(usize, self.len, additional) catch {
            if (self.capacity_max != null) return error.CapacityExceeded;
            return error.OutOfMemory;
        };
        try self.ensureTotalCapacity(needed);
    }

    pub fn ensureTotalCapacity(self: *ByteBuilder, needed: usize) Error!void {
        if (self.capacity_max) |max| {
            if (needed > max) return error.CapacityExceeded;
        }
        if (needed <= self.buf.len) return;
        var capacity = if (self.buf.len == 0) @as(usize, 64) else self.buf.len;
        while (capacity < needed) {
            capacity = std.math.mul(usize, capacity, 2) catch needed;
            if (capacity < needed) capacity = needed;
        }
        if (self.capacity_max) |max| capacity = @min(capacity, max);
        const next = try self.allocator.alloc(u8, capacity);
        @memcpy(next[0..self.len], self.buf[0..self.len]);
        self.allocator.free(self.buf);
        self.buf = next;
    }

    pub fn append(self: *ByteBuilder, bytes: []const u8) Error!void {
        try self.ensureUnusedCapacity(bytes.len);
        @memcpy(self.buf[self.len .. self.len + bytes.len], bytes);
        self.len += bytes.len;
    }

    pub fn appendByte(self: *ByteBuilder, byte: u8) Error!void {
        try self.ensureUnusedCapacity(1);
        self.buf[self.len] = byte;
        self.len += 1;
    }

    pub fn toOwnedSlice(self: *ByteBuilder) std.mem.Allocator.Error![]u8 {
        std.debug.assert(self.len <= self.buf.len);
        if (self.len == 0) return self.allocator.alloc(u8, 0);
        const out = try self.allocator.realloc(self.buf, self.len);
        self.buf = &.{};
        self.len = 0;
        return out;
    }

    pub fn copyTo(self: *const ByteBuilder, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return allocator.dupe(u8, self.items());
    }
};

test "ByteBuilder appends and clears while retaining capacity" {
    var builder = ByteBuilder.initUnbounded(std.testing.allocator);
    defer builder.deinit();

    try builder.append("hello");
    const capacity = builder.buf.len;
    try std.testing.expectEqualStrings("hello", builder.items());
    builder.clearRetainingCapacity();
    try std.testing.expectEqual(@as(usize, 0), builder.items().len);
    try std.testing.expectEqual(capacity, builder.buf.len);
    try builder.append("world");
    try std.testing.expectEqualStrings("world", builder.items());
}

test "ByteBuilder toOwnedSlice transfers ownership and resets" {
    var builder = ByteBuilder.initUnbounded(std.testing.allocator);
    defer builder.deinit();

    try builder.append("abc");
    const owned = try builder.toOwnedSlice();
    defer std.testing.allocator.free(owned);

    try std.testing.expectEqualStrings("abc", owned);
    try std.testing.expectEqual(@as(usize, 0), builder.items().len);
    try std.testing.expectEqual(@as(usize, 0), builder.buf.len);
}

test "ByteBuilder bounded mode rejects growth past capacity" {
    var builder = ByteBuilder.initBounded(std.testing.allocator, 3);
    defer builder.deinit();

    try builder.append("abc");
    try std.testing.expectError(error.CapacityExceeded, builder.appendByte('d'));
    try std.testing.expectEqualStrings("abc", builder.items());
}
