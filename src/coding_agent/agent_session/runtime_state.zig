const std = @import("std");
const ai = @import("../../ai/root.zig");

const extension_state_entry_type = "extension_state";

pub fn get(
    self: anytype,
    allocator: std.mem.Allocator,
    state_owner_id: []const u8,
    key: []const u8,
) ?std.json.Value {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();

    const branch = self.session_store.buildCurrentVisibleBranchAlloc(arena.allocator()) catch return null;
    var latest: ?std.json.Value = null;
    var deleted = false;

    for (branch) |entry| {
        const custom = switch (entry.entry) {
            .custom => |custom| custom,
            else => continue,
        };
        if (!std.mem.eql(u8, custom.custom_type, extension_state_entry_type)) continue;
        const data = custom.data orelse continue;
        if (data != .object) continue;
        const owner_value = data.object.get("state_owner_id") orelse continue;
        const key_value = data.object.get("key") orelse continue;
        if (owner_value != .string or key_value != .string) continue;
        if (!std.mem.eql(u8, owner_value.string, state_owner_id)) continue;
        if (!std.mem.eql(u8, key_value.string, key)) continue;

        deleted = if (data.object.get("deleted")) |value| value == .bool and value.bool else false;
        latest = data.object.get("value");
    }

    if (deleted) return null;
    const value = latest orelse return null;
    return ai.json_util.cloneJsonValue(allocator, value) catch null;
}

pub fn set(
    self: anytype,
    state_owner_id: []const u8,
    key: []const u8,
    value: std.json.Value,
) !void {
    var data: std.json.ObjectMap = .{};
    errdefer {
        const wrapped: std.json.Value = .{ .object = data };
        ai.json_util.freeJsonValue(self.allocator, wrapped);
    }

    try data.put(self.allocator, try self.allocator.dupe(u8, "state_owner_id"), .{ .string = try self.allocator.dupe(u8, state_owner_id) });
    try data.put(self.allocator, try self.allocator.dupe(u8, "key"), .{ .string = try self.allocator.dupe(u8, key) });
    try data.put(self.allocator, try self.allocator.dupe(u8, "value"), try ai.json_util.cloneJsonValue(self.allocator, value));

    self.session_store.appendCustomEntry(extension_state_entry_type, .{ .object = data });
}

pub fn delete(
    self: anytype,
    state_owner_id: []const u8,
    key: []const u8,
) !void {
    var data: std.json.ObjectMap = .{};
    errdefer {
        const wrapped: std.json.Value = .{ .object = data };
        ai.json_util.freeJsonValue(self.allocator, wrapped);
    }

    try data.put(self.allocator, try self.allocator.dupe(u8, "state_owner_id"), .{ .string = try self.allocator.dupe(u8, state_owner_id) });
    try data.put(self.allocator, try self.allocator.dupe(u8, "key"), .{ .string = try self.allocator.dupe(u8, key) });
    try data.put(self.allocator, try self.allocator.dupe(u8, "deleted"), .{ .bool = true });

    self.session_store.appendCustomEntry(extension_state_entry_type, .{ .object = data });
}
