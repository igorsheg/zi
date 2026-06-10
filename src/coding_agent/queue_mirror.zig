const std = @import("std");

const client_protocol = @import("client_protocol.zig");

pub const QueueMirror = struct {
    steering: std.ArrayList([]const u8) = .empty,
    follow_up: std.ArrayList([]const u8) = .empty,
    revision: u64 = 0,

    pub fn deinit(self: *QueueMirror, allocator: std.mem.Allocator) void {
        self.clearList(allocator, &self.steering);
        self.clearList(allocator, &self.follow_up);
        self.steering.deinit(allocator);
        self.follow_up.deinit(allocator);
        self.* = undefined;
    }

    pub fn appendSteering(self: *QueueMirror, allocator: std.mem.Allocator, text: []const u8) !void {
        try self.append(allocator, &self.steering, text);
    }

    pub fn appendFollowUp(self: *QueueMirror, allocator: std.mem.Allocator, text: []const u8) !void {
        try self.append(allocator, &self.follow_up, text);
    }

    pub fn removeUserText(self: *QueueMirror, allocator: std.mem.Allocator, text: []const u8) bool {
        return self.remove(allocator, &self.steering, text) or self.remove(allocator, &self.follow_up, text);
    }

    pub fn clear(self: *QueueMirror, allocator: std.mem.Allocator) bool {
        if (self.steering.items.len == 0 and self.follow_up.items.len == 0) return false;
        self.clearList(allocator, &self.steering);
        self.clearList(allocator, &self.follow_up);
        self.revision += 1;
        return true;
    }

    pub fn snapshot(self: *const QueueMirror, allocator: std.mem.Allocator) !client_protocol.QueueSnapshot {
        var steering = try client_protocol.EventTextList.init(allocator, self.steering.items);
        errdefer steering.deinit(allocator);
        return .{
            .revision = self.revision,
            .steering = steering,
            .follow_up = try client_protocol.EventTextList.init(allocator, self.follow_up.items),
        };
    }

    fn append(
        self: *QueueMirror,
        allocator: std.mem.Allocator,
        list: *std.ArrayList([]const u8),
        text: []const u8,
    ) !void {
        const owned = try allocator.dupe(u8, text);
        errdefer allocator.free(owned);
        try list.append(allocator, owned);
        self.revision += 1;
    }

    fn remove(
        self: *QueueMirror,
        allocator: std.mem.Allocator,
        list: *std.ArrayList([]const u8),
        text: []const u8,
    ) bool {
        for (list.items, 0..) |queued, index| {
            if (!std.mem.eql(u8, queued, text)) continue;
            allocator.free(queued);
            const remaining = list.items.len - index - 1;
            if (remaining > 0) @memmove(list.items[index .. index + remaining], list.items[index + 1 ..]);
            list.shrinkRetainingCapacity(list.items.len - 1);
            self.revision += 1;
            return true;
        }
        return false;
    }

    fn clearList(_: *QueueMirror, allocator: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
        for (list.items) |text| allocator.free(text);
        list.clearRetainingCapacity();
    }
};
