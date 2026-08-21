const std = @import("std");
const Text = @import("Text.zig");

const GraphemeStore = @This();

pub const Id = enum(u32) { _ };

const Entry = struct {
    offset: u32,
    len: u8,
};

allocator: std.mem.Allocator,
bytes: std.ArrayList(u8) = .empty,
entries: std.ArrayList(Entry) = .empty,

pub fn init(allocator: std.mem.Allocator) GraphemeStore {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *GraphemeStore) void {
    self.entries.deinit(self.allocator);
    self.bytes.deinit(self.allocator);
    self.* = undefined;
}

pub fn clone(self: *const GraphemeStore) !GraphemeStore {
    var copy = GraphemeStore.init(self.allocator);
    errdefer copy.deinit();
    try copy.bytes.appendSlice(self.allocator, self.bytes.items);
    try copy.entries.appendSlice(self.allocator, self.entries.items);
    return copy;
}

pub fn put(self: *GraphemeStore, bytes: []const u8) !Id {
    if (bytes.len == 0 or bytes.len > Text.max_grapheme_bytes) return error.InvalidGrapheme;
    if (self.entries.items.len > std.math.maxInt(u32)) return error.GraphemeStoreFull;
    if (self.bytes.items.len > std.math.maxInt(u32) - bytes.len) return error.GraphemeStoreFull;
    const id: Id = @enumFromInt(self.entries.items.len);
    const offset: u32 = @intCast(self.bytes.items.len);
    try self.bytes.appendSlice(self.allocator, bytes);
    errdefer self.bytes.shrinkRetainingCapacity(offset);
    try self.entries.append(self.allocator, .{
        .offset = offset,
        .len = @intCast(bytes.len),
    });
    return id;
}

pub fn get(self: *const GraphemeStore, id: Id) ?[]const u8 {
    const index = @intFromEnum(id);
    if (index >= self.entries.items.len) return null;
    const entry = self.entries.items[index];
    return self.bytes.items[entry.offset..][0..entry.len];
}

test "grapheme store clone preserves typed IDs" {
    var store = GraphemeStore.init(std.testing.allocator);
    defer store.deinit();
    const id = try store.put("👨‍👩‍👧‍👦");
    var copy = try store.clone();
    defer copy.deinit();
    try std.testing.expectEqualStrings(store.get(id).?, copy.get(id).?);
}
