const std = @import("std");

/// Ownership helpers for `std.json.Value`.
///
/// Contract:
/// - `cloneJsonValue` returns a value fully owned by `allocator`.
/// - `freeJsonValue` must only be used for values produced by `cloneJsonValue`
///   or constructed with the same ownership rules.
/// - Borrowed values from `std.json.parseFromSliceLeaky` are not accepted by
///   `freeJsonValue` unless they were first cloned.
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

pub fn jsonToFloat(v: std.json.Value) f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => 0,
    };
}

pub fn asString(v: ?std.json.Value) ?[]const u8 {
    const val = v orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

pub fn asU64(v: ?std.json.Value) ?u64 {
    const val = v orelse return null;
    return switch (val) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        else => null,
    };
}

pub fn asBool(v: ?std.json.Value) ?bool {
    const val = v orelse return null;
    return switch (val) {
        .bool => |b| b,
        else => null,
    };
}

pub fn asObject(v: ?std.json.Value) ?std.json.ObjectMap {
    const val = v orelse return null;
    return switch (val) {
        .object => |o| o,
        else => null,
    };
}

pub fn asArray(v: ?std.json.Value) ?std.json.Array {
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
