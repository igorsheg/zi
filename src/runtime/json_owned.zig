const std = @import("std");

pub fn JsonOwned(comptime T: type) type {
    return struct {
        value: T,
        arena: *std.heap.ArenaAllocator,

        const Self = @This();

        fn initArena(backing_allocator: std.mem.Allocator) !Self {
            const arena = try backing_allocator.create(std.heap.ArenaAllocator);
            errdefer backing_allocator.destroy(arena);
            arena.* = std.heap.ArenaAllocator.init(backing_allocator);
            return .{ .value = undefined, .arena = arena };
        }

        pub fn initClone(
            backing_allocator: std.mem.Allocator,
            source: T,
            comptime cloneFn: fn (std.mem.Allocator, T) anyerror!T,
        ) !Self {
            var owned = try initArena(backing_allocator);
            errdefer owned.deinit();
            owned.value = try cloneFn(owned.arenaAllocator(), source);
            return owned;
        }

        pub fn fromJson(parsed: std.json.Parsed(T)) Self {
            return .{ .value = parsed.value, .arena = parsed.arena };
        }

        pub fn parseJson(
            backing_allocator: std.mem.Allocator,
            source: []const u8,
            options: std.json.ParseOptions,
        ) !Self {
            return fromJson(try std.json.parseFromSlice(T, backing_allocator, source, options));
        }

        pub fn arenaAllocator(self: *const Self) std.mem.Allocator {
            return self.arena.allocator();
        }

        pub fn takeArena(self: *Self) std.heap.ArenaAllocator {
            const arena = self.arena;
            const backing_allocator = arena.child_allocator;
            const value = arena.*;
            backing_allocator.destroy(arena);
            self.* = undefined;
            return value;
        }

        pub fn deinit(self: *Self) void {
            const arena = self.arena;
            const backing_allocator = arena.child_allocator;
            arena.deinit();
            backing_allocator.destroy(arena);
            self.* = undefined;
        }
    };
}

pub fn cloneJsonValue(allocator: std.mem.Allocator, source: std.json.Value) std.mem.Allocator.Error!std.json.Value {
    return switch (source) {
        .null => .null,
        .bool => |value| .{ .bool = value },
        .integer => |value| .{ .integer = value },
        .float => |value| .{ .float = value },
        .number_string => |value| .{ .number_string = try allocator.dupe(u8, value) },
        .string => |value| .{ .string = try allocator.dupe(u8, value) },
        .array => |array| blk: {
            var cloned: std.json.Array = .init(allocator);
            errdefer freeJsonValue(allocator, .{ .array = cloned });
            for (array.items) |item| try cloned.append(try cloneJsonValue(allocator, item));
            break :blk .{ .array = cloned };
        },
        .object => |object| blk: {
            var cloned: std.json.ObjectMap = .empty;
            errdefer freeJsonValue(allocator, .{ .object = cloned });
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                const value = cloneJsonValue(allocator, entry.value_ptr.*) catch |err| {
                    allocator.free(key);
                    return err;
                };
                cloned.put(allocator, key, value) catch |err| {
                    allocator.free(key);
                    freeJsonValue(allocator, value);
                    return err;
                };
            }
            break :blk .{ .object = cloned };
        },
    };
}

pub fn freeJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    switch (value) {
        .null, .bool, .integer, .float => {},
        .number_string, .string => |text| allocator.free(text),
        .array => |array| {
            for (array.items) |item| freeJsonValue(allocator, item);
            array.deinit();
        },
        .object => |object| {
            var owned = object;
            var iterator = owned.iterator();
            while (iterator.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeJsonValue(allocator, entry.value_ptr.*);
            }
            owned.deinit(allocator);
        },
    }
}

test "JsonOwned fromJson owns parsed arena" {
    const Value = struct { name: []const u8 };
    var owned = try JsonOwned(Value).parseJson(
        std.testing.allocator,
        "{\"name\":\"zi\"}",
        .{ .allocate = .alloc_always },
    );
    defer owned.deinit();

    try std.testing.expectEqualStrings("zi", owned.value.name);
}

test "JsonOwned initClone stores cloned value in owned arena" {
    const Value = struct { name: []const u8 };
    const clone = struct {
        fn call(allocator: std.mem.Allocator, source: Value) !Value {
            return .{ .name = try allocator.dupe(u8, source.name) };
        }
    }.call;

    var source = [_]u8{ 'z', 'i' };
    var owned = try JsonOwned(Value).initClone(std.testing.allocator, .{ .name = &source }, clone);
    defer owned.deinit();
    source[0] = 'p';

    try std.testing.expectEqualStrings("zi", owned.value.name);
}

test "json value clone owns nested strings and frees with one path" {
    var object: std.json.ObjectMap = .empty;
    defer object.deinit(std.testing.allocator);
    try object.put(std.testing.allocator, "name", .{ .string = "zi" });

    var array: std.json.Array = .init(std.testing.allocator);
    defer array.deinit();
    try array.append(.{ .object = object });

    const cloned = try cloneJsonValue(std.testing.allocator, .{ .array = array });
    defer freeJsonValue(std.testing.allocator, cloned);

    try std.testing.expectEqualStrings("zi", cloned.array.items[0].object.get("name").?.string);
}
