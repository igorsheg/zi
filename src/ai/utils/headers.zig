const std = @import("std");

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const HeaderRecord = struct {
    allocator: std.mem.Allocator,
    values: std.StringArrayHashMapUnmanaged([]const u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) HeaderRecord {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *HeaderRecord) void {
        for (self.values.keys()) |key| self.allocator.free(key);
        for (self.values.values()) |value| self.allocator.free(value);
        self.values.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn get(self: *const HeaderRecord, name: []const u8) ?[]const u8 {
        return self.values.get(name);
    }
};

pub fn headersToRecord(allocator: std.mem.Allocator, headers: []const Header) !HeaderRecord {
    var record = HeaderRecord.init(allocator);
    errdefer record.deinit();

    for (headers) |header| {
        const owned_name = try allocator.dupe(u8, header.name);
        errdefer allocator.free(owned_name);
        const owned_value = try allocator.dupe(u8, header.value);
        errdefer allocator.free(owned_value);

        const result = try record.values.getOrPut(allocator, owned_name);
        if (result.found_existing) {
            allocator.free(owned_name);
            allocator.free(result.value_ptr.*);
        } else {
            result.key_ptr.* = owned_name;
        }
        result.value_ptr.* = owned_value;
    }

    return record;
}

test "headers to record copies names and values" {
    var name_buffer = [_]u8{ 'x', '-', 'i', 'd' };
    var value_buffer = [_]u8{ 'o', 'n', 'e' };
    var record = try headersToRecord(std.testing.allocator, &.{.{ .name = &name_buffer, .value = &value_buffer }});
    defer record.deinit();
    name_buffer[0] = 'y';
    value_buffer[0] = 'z';

    try std.testing.expectEqualStrings("one", record.get("x-id").?);
    try std.testing.expectEqual(@as(?[]const u8, null), record.get("y-id"));
}

test "headers to record keeps last duplicate value" {
    var record = try headersToRecord(std.testing.allocator, &.{
        .{ .name = "content-type", .value = "text/plain" },
        .{ .name = "content-type", .value = "application/json" },
    });
    defer record.deinit();

    try std.testing.expectEqualStrings("application/json", record.get("content-type").?);
}
