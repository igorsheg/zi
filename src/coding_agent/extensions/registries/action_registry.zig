const std = @import("std");
const event_registry = @import("event_registry.zig");

pub const ActionRegistry = struct {
    allocator: std.mem.Allocator,
    actions: std.StringHashMapUnmanaged(event_registry.EventHandler) = .empty,

    pub fn init(allocator: std.mem.Allocator) ActionRegistry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ActionRegistry) void {
        var it = self.actions.iterator();
        while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.actions.deinit(self.allocator);
    }

    pub fn put(self: *ActionRegistry, name: []const u8, handler: event_registry.EventHandler) !void {
        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);
        if (try self.actions.fetchPut(self.allocator, owned, handler)) |old| self.allocator.free(old.key);
    }

    pub fn get(self: *const ActionRegistry, name: []const u8) ?event_registry.EventHandler {
        return self.actions.get(name);
    }
};
