const std = @import("std");

/// Allocator adapter that zeroes every complete allocation immediately before release.
/// Resize/remap are deliberately refused so no truncated tail can escape wiping.
pub const WipingAllocator = struct {
    child: std.mem.Allocator,

    pub fn init(child: std.mem.Allocator) WipingAllocator {
        return .{ .child = child };
    }

    pub fn allocator(self: *WipingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *WipingAllocator = @ptrCast(@alignCast(context));
        return self.child.rawAlloc(len, alignment, return_address);
    }

    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }

    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *WipingAllocator = @ptrCast(@alignCast(context));
        std.crypto.secureZero(u8, memory);
        self.child.rawFree(memory, alignment, return_address);
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };
};

/// Zero an owned byte slice without std.mem.Allocator.free's debug poison replacing the zeros.
pub fn wipeFree(allocator: std.mem.Allocator, value: []const u8) void {
    const mutable = @constCast(value);
    std.crypto.secureZero(u8, mutable);
    allocator.rawFree(mutable, .of(u8), @returnAddress());
}

/// Test observer for proving callers use wipeFree before raw release.
pub const FreeObserver = struct {
    child: std.mem.Allocator,
    zero_frees: usize = 0,
    other_frees: usize = 0,

    pub fn init(child: std.mem.Allocator) FreeObserver {
        return .{ .child = child };
    }

    pub fn allocator(self: *FreeObserver) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *FreeObserver = @ptrCast(@alignCast(context));
        return self.child.rawAlloc(len, alignment, return_address);
    }

    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }

    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *FreeObserver = @ptrCast(@alignCast(context));
        var all_zero = true;
        for (memory) |byte| all_zero = all_zero and byte == 0;
        if (all_zero) self.zero_frees += 1 else self.other_frees += 1;
        self.child.rawFree(memory, alignment, return_address);
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };
};

const ObserverAllocator = struct {
    fixed: std.heap.FixedBufferAllocator,
    frees: usize = 0,
    observed_zero: bool = true,

    fn init(storage: []u8) ObserverAllocator {
        return .{ .fixed = std.heap.FixedBufferAllocator.init(storage) };
    }

    fn allocator(self: *ObserverAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *ObserverAllocator = @ptrCast(@alignCast(context));
        return self.fixed.allocator().rawAlloc(len, alignment, return_address);
    }

    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }

    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }

    fn free(context: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
        const self: *ObserverAllocator = @ptrCast(@alignCast(context));
        self.frees += 1;
        for (memory) |byte| self.observed_zero = self.observed_zero and byte == 0;
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };
};

test "wiping allocator presents whole zero blocks to backing free" {
    var storage: [1024]u8 = undefined;
    var observer = ObserverAllocator.init(&storage);
    var wiping = WipingAllocator.init(observer.allocator());
    const allocator = wiping.allocator();
    const first = try allocator.alloc(u8, 31);
    @memset(first, 0x5a);
    const second = try allocator.alloc(u8, 127);
    @memset(second, 0xa5);
    allocator.free(first);
    allocator.free(second);
    try std.testing.expectEqual(@as(usize, 2), observer.frees);
    try std.testing.expect(observer.observed_zero);
}

test "wipeFree presents zero bytes to backing free" {
    var storage: [128]u8 = undefined;
    var observer = ObserverAllocator.init(&storage);
    const allocator = observer.allocator();
    const secret = try allocator.alloc(u8, 32);
    @memset(secret, 0xcc);
    wipeFree(allocator, secret);
    try std.testing.expectEqual(@as(usize, 1), observer.frees);
    try std.testing.expect(observer.observed_zero);
}
