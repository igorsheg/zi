const std = @import("std");
const provider_mod = @import("../../../ai/provider.zig");

pub const PendingProviderUnregister = struct {
    name: []const u8,
    owner_id: []const u8,

    pub fn deinit(self: *PendingProviderUnregister, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.owner_id);
        self.* = undefined;
    }
};

pub const PendingProviderOperation = union(enum) {
    register: provider_mod.ClaimRegistration,
    unregister: PendingProviderUnregister,

    pub fn deinit(self: *PendingProviderOperation, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .register => |*claim| claim.deinit(allocator),
            .unregister => |*claim| claim.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const ProviderQueue = struct {
    allocator: std.mem.Allocator,
    pending: std.ArrayListUnmanaged(PendingProviderOperation) = .empty,

    pub fn init(allocator: std.mem.Allocator) ProviderQueue {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ProviderQueue) void {
        for (self.pending.items) |*op| op.deinit(self.allocator);
        self.pending.deinit(self.allocator);
    }

    pub fn enqueueRegister(self: *ProviderQueue, claim: provider_mod.ClaimRegistration) !void {
        try self.pending.append(self.allocator, .{ .register = claim });
    }

    pub fn enqueueUnregister(self: *ProviderQueue, op: PendingProviderUnregister) !void {
        try self.pending.append(self.allocator, .{ .unregister = op });
    }

    pub fn drain(self: *ProviderQueue) ![]PendingProviderOperation {
        return try self.pending.toOwnedSlice(self.allocator);
    }

    pub fn count(self: *const ProviderQueue) usize {
        return self.pending.items.len;
    }
};

const testing = std.testing;

test "ProviderQueue preserves ordered register/unregister operations" {
    var q = ProviderQueue.init(testing.allocator);
    defer q.deinit();

    try q.enqueueRegister(.{
        .name = try testing.allocator.dupe(u8, "proxy-a"),
        .api = try testing.allocator.dupe(u8, "anthropic-messages"),
        .base_url = try testing.allocator.dupe(u8, "https://a.example"),
        .owner_id = try testing.allocator.dupe(u8, "ext-a"),
        .generation = 7,
    });
    try q.enqueueUnregister(.{
        .name = try testing.allocator.dupe(u8, "proxy-a"),
        .owner_id = try testing.allocator.dupe(u8, "ext-a"),
    });

    try testing.expectEqual(@as(usize, 2), q.count());

    const drained = try q.drain();
    defer {
        for (drained) |*op| op.deinit(testing.allocator);
        testing.allocator.free(drained);
    }

    try testing.expectEqual(@as(usize, 2), drained.len);
    try testing.expectEqual(@as(usize, 0), q.count());

    switch (drained[0]) {
        .register => |claim| {
            try testing.expectEqualStrings("proxy-a", claim.name);
            try testing.expectEqualStrings("anthropic-messages", claim.api);
        },
        else => return error.ExpectedRegisterFirst,
    }
    switch (drained[1]) {
        .unregister => |claim| {
            try testing.expectEqualStrings("proxy-a", claim.name);
            try testing.expectEqualStrings("ext-a", claim.owner_id);
        },
        else => return error.ExpectedUnregisterSecond,
    }
}
