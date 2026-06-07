const std = @import("std");

/// Growable byte buffer with an optional capacity ceiling.
///
/// Growth is delegated to `std.ArrayListUnmanaged(u8)`; the only behaviour this
/// adds over the std list is the `capacity_max` policy (appends past the ceiling
/// fail with `error.CapacityExceeded` instead of growing) plus a stored
/// allocator so callers keep the managed-style `append(bytes)` ergonomics.
pub const ByteBuilder = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayListUnmanaged(u8) = .empty,
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
        self.list.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clearRetainingCapacity(self: *ByteBuilder) void {
        self.list.clearRetainingCapacity();
    }

    pub fn items(self: *const ByteBuilder) []const u8 {
        return self.list.items;
    }

    pub fn mutableItems(self: *ByteBuilder) []u8 {
        return self.list.items;
    }

    pub fn ensureUnusedCapacity(self: *ByteBuilder, additional: usize) Error!void {
        const needed = std.math.add(usize, self.list.items.len, additional) catch {
            if (self.capacity_max != null) return error.CapacityExceeded;
            return error.OutOfMemory;
        };
        try self.ensureTotalCapacity(needed);
    }

    pub fn ensureTotalCapacity(self: *ByteBuilder, needed: usize) Error!void {
        if (self.capacity_max) |max| {
            if (needed > max) return error.CapacityExceeded;
        }
        try self.list.ensureTotalCapacity(self.allocator, needed);
    }

    pub fn append(self: *ByteBuilder, bytes: []const u8) Error!void {
        try self.ensureUnusedCapacity(bytes.len);
        self.list.appendSliceAssumeCapacity(bytes);
    }

    pub fn appendByte(self: *ByteBuilder, byte: u8) Error!void {
        try self.ensureUnusedCapacity(1);
        self.list.appendAssumeCapacity(byte);
    }

    pub fn toOwnedSlice(self: *ByteBuilder) std.mem.Allocator.Error![]u8 {
        return self.list.toOwnedSlice(self.allocator);
    }

    pub fn copyTo(self: *const ByteBuilder, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return allocator.dupe(u8, self.list.items);
    }
};

test "ByteBuilder appends and clears while retaining capacity" {
    var builder = ByteBuilder.initUnbounded(std.testing.allocator);
    defer builder.deinit();

    try builder.append("hello");
    const capacity = builder.list.capacity;
    try std.testing.expectEqualStrings("hello", builder.items());
    builder.clearRetainingCapacity();
    try std.testing.expectEqual(@as(usize, 0), builder.items().len);
    try std.testing.expectEqual(capacity, builder.list.capacity);
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
    try std.testing.expectEqual(@as(usize, 0), builder.list.capacity);
}

test "ByteBuilder bounded mode rejects growth past capacity" {
    var builder = ByteBuilder.initBounded(std.testing.allocator, 3);
    defer builder.deinit();

    try builder.append("abc");
    try std.testing.expectError(error.CapacityExceeded, builder.appendByte('d'));
    try std.testing.expectEqualStrings("abc", builder.items());
}
