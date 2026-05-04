//! Generic helpers for building and walking `std.json.Value` trees.
//!
//! Home for JSON conveniences that are NOT tied to any particular
//! domain (AI providers, sessions, settings). Domain-specific wire
//! serializers live next to their types (`src/agent2/json.zig`,
//! `src/session/json.zig`, `src/settings/json.zig`).
//!
//! Exposed via `src/json/root.zig` as `json.value.*`. Also re-exported
//! from `src/ai/json_util.zig` for now so legacy call sites keep
//! working — migrate on touch, don't chase the whole graph.

const std = @import("std");

// =================================================================
// Deep clone / free
// =================================================================

/// Recursively clone a `std.json.Value` tree into `allocator`.
/// Strings and object keys are duped — the returned tree has no
/// borrowed references to the source. Safe to free the source
/// immediately after.
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
            for (arr.items) |item| {
                try new_arr.append(try cloneJsonValue(allocator, item));
            }
            return .{ .array = new_arr };
        },
        .object => |obj| {
            var new_obj: std.json.ObjectMap = .{};
            var it = obj.iterator();
            while (it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                const val = try cloneJsonValue(allocator, entry.value_ptr.*);
                try new_obj.put(allocator, key, val);
            }
            return .{ .object = new_obj };
        },
    }
}

/// Recursively free all owned memory in a `std.json.Value` tree.
/// Safe to call on a tree allocated by `cloneJsonValue` or the
/// `lua_runtime` conversion path. NOT safe on values whose strings
/// point into external buffers (e.g. raw stdlib parse output that
/// lives in a parent arena) — in that case, drop the arena instead.
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

// =================================================================
// Typed accessors
// =================================================================

/// Coerce a `std.json.Value` to an f64, treating ints as floats and
/// anything else as 0. Used for deserializing cost/usage fields that
/// stdlib may parse as either variant depending on the input form.
pub fn jsonToFloat(v: std.json.Value) f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => 0,
    };
}

/// Return the string payload of `v` if it is a `.string`, else null.
/// Accepts an optional so chaining on `ObjectMap.get` is idiomatic:
/// `json.value.asString(obj.get("key"))`.
pub fn asString(v: ?std.json.Value) ?[]const u8 {
    const val = v orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

/// Return `v` as a u64 if it is a non-negative `.integer`, else null.
/// Matches the "unsigned token count" shape used by provider protocols.
pub fn asU64(v: ?std.json.Value) ?u64 {
    const val = v orelse return null;
    return switch (val) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        else => null,
    };
}

/// Return the boolean payload of `v` if it is a `.bool`, else null.
pub fn asBool(v: ?std.json.Value) ?bool {
    const val = v orelse return null;
    return switch (val) {
        .bool => |b| b,
        else => null,
    };
}

/// Return the `ObjectMap` payload of `v` if it is a `.object`, else null.
pub fn asObject(v: ?std.json.Value) ?std.json.ObjectMap {
    const val = v orelse return null;
    return switch (val) {
        .object => |o| o,
        else => null,
    };
}

/// Return the `Array` payload of `v` if it is a `.array`, else null.
pub fn asArray(v: ?std.json.Value) ?std.json.Array {
    const val = v orelse return null;
    return switch (val) {
        .array => |a| a,
        else => null,
    };
}

// =================================================================
// Tests
// =================================================================

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
