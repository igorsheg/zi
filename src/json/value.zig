const std = @import("std");

pub const BorrowedValue = std.json.Value;

pub const OwnedValue = union(enum) {
    null,
    owned: struct {
        allocator: std.mem.Allocator,
        value: std.json.Value,
    },

    pub fn clone(allocator: std.mem.Allocator, value: std.json.Value) !OwnedValue {
        return .{ .owned = .{ .allocator = allocator, .value = try cloneJsonValue(allocator, value) } };
    }

    pub fn adopt(allocator: std.mem.Allocator, value: std.json.Value) OwnedValue {
        return .{ .owned = .{ .allocator = allocator, .value = value } };
    }

    pub fn nullValue() OwnedValue {
        return .null;
    }

    pub fn borrowed(self: OwnedValue) std.json.Value {
        return switch (self) {
            .null => .null,
            .owned => |owned| owned.value,
        };
    }

    pub fn deinit(self: *OwnedValue) void {
        switch (self.*) {
            .null => {},
            .owned => |owned| freeJsonValue(owned.allocator, owned.value),
        }
        self.* = undefined;
    }

    pub fn move(self: *OwnedValue) OwnedValue {
        const moved = self.*;
        self.* = undefined;
        return moved;
    }
};

pub fn cloneJsonValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    switch (value) {
        .null => return .null,
        .bool => |b| return .{ .bool = b },
        .integer => |i| return .{ .integer = i },
        .float => |f| return .{ .float = f },
        .number_string => |s| return .{ .number_string = try allocator.dupe(u8, s) },
        .string => |s| return .{ .string = try allocator.dupe(u8, s) },
        .array => |arr| {
            var new_arr = std.json.Array.initCapacity(allocator, arr.items.len) catch return error.OutOfMemory;
            errdefer {
                for (new_arr.items) |item| freeJsonValue(allocator, item);
                new_arr.deinit();
            }
            for (arr.items) |item| {
                try new_arr.append(try cloneJsonValue(allocator, item));
            }
            return .{ .array = new_arr };
        },
        .object => |obj| {
            var new_obj: std.json.ObjectMap = .{};
            errdefer {
                var cleanup = new_obj;
                var cleanup_it = cleanup.iterator();
                while (cleanup_it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    freeJsonValue(allocator, entry.value_ptr.*);
                }
                cleanup.deinit(allocator);
            }
            var it = obj.iterator();
            while (it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                const val = cloneJsonValue(allocator, entry.value_ptr.*) catch |err| {
                    allocator.free(key);
                    return err;
                };
                new_obj.put(allocator, key, val) catch |err| {
                    allocator.free(key);
                    freeJsonValue(allocator, val);
                    return err;
                };
            }
            return .{ .object = new_obj };
        },
    }
}

pub fn freeJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    switch (value) {
        .string => |s| allocator.free(s),
        .number_string => |s| allocator.free(s),
        .array => |arr| {
            for (arr.items) |item| freeJsonValue(allocator, item);
            var mutable = arr;
            mutable.deinit();
        },
        .object => |obj| {
            var mutable = obj;
            var it = mutable.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeJsonValue(allocator, entry.value_ptr.*);
            }
            mutable.deinit(allocator);
        },
        else => {},
    }
}

pub fn writeJsonValue(writer: *std.Io.Writer, value: std.json.Value) std.Io.Writer.Error!void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .integer => |i| try writer.print("{}", .{i}),
        .float => |f| try writer.print("{}", .{f}),
        .number_string => |s| try writer.writeAll(s),
        .string => |s| try writeJsonString(writer, s),
        .array => |arr| {
            try writer.writeByte('[');
            for (arr.items, 0..) |item, i| {
                if (i != 0) try writer.writeByte(',');
                try writeJsonValue(writer, item);
            }
            try writer.writeByte(']');
        },
        .object => |obj| {
            try writer.writeByte('{');
            var it = obj.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try writer.writeByte(',');
                first = false;
                try writeJsonString(writer, entry.key_ptr.*);
                try writer.writeByte(':');
                try writeJsonValue(writer, entry.value_ptr.*);
            }
            try writer.writeByte('}');
        },
    }
}

pub fn writeJsonString(writer: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    try writer.writeByte('"');
    for (value) |c| switch (c) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0...8, 11...12, 14...0x1f => try writer.print("\\u{x:0>4}", .{c}),
        else => try writer.writeByte(c),
    };
    try writer.writeByte('"');
}

pub fn expectNumber(v: std.json.Value) !f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => error.ExpectedNumber,
    };
}

pub fn optionalString(v: ?std.json.Value) ?[]const u8 {
    const val = v orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

pub fn optionalU64(v: ?std.json.Value) ?u64 {
    const val = v orelse return null;
    return switch (val) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        else => null,
    };
}

pub fn optionalBool(v: ?std.json.Value) ?bool {
    const val = v orelse return null;
    return switch (val) {
        .bool => |b| b,
        else => null,
    };
}

pub fn optionalObject(v: ?std.json.Value) ?std.json.ObjectMap {
    const val = v orelse return null;
    return switch (val) {
        .object => |o| o,
        else => null,
    };
}

pub fn optionalArray(v: ?std.json.Value) ?std.json.Array {
    const val = v orelse return null;
    return switch (val) {
        .array => |a| a,
        else => null,
    };
}

const testing = std.testing;

test "cloneJsonValue dupes strings and keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        \\{"k":"v","n":[1,2]}
    ,
        .{},
    );
    const cloned = try cloneJsonValue(testing.allocator, parsed);
    defer freeJsonValue(testing.allocator, cloned);

    try testing.expect(cloned == .object);
    try testing.expectEqualStrings("v", cloned.object.get("k").?.string);
    try testing.expectEqual(@as(usize, 2), cloned.object.get("n").?.array.items.len);
}

test "OwnedValue carries allocator and releases cloned tree" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        \\{"k":"v","n":[1,2]}
    ,
        .{},
    );

    var owned = try OwnedValue.clone(testing.allocator, parsed);
    defer owned.deinit();

    try testing.expect(owned.borrowed() == .object);
    try testing.expectEqualStrings("v", owned.borrowed().object.get("k").?.string);
}

test "expectNumber rejects non-numeric values" {
    try testing.expectEqual(@as(f64, 2), try expectNumber(.{ .integer = 2 }));
    try testing.expectError(error.ExpectedNumber, expectNumber(.{ .string = "2" }));
}
