const std = @import("std");

pub fn Owned(comptime T: type) type {
    return struct {
        value: T,
        arena: *std.heap.ArenaAllocator,

        const Self = @This();

        pub fn fromJson(parsed: std.json.Parsed(T)) Self {
            return .{ .value = parsed.value, .arena = parsed.arena };
        }

        pub fn parseJson(allocator: std.mem.Allocator, source: []const u8, options: std.json.ParseOptions) !Self {
            return fromJson(try std.json.parseFromSlice(T, allocator, source, options));
        }

        pub fn deinit(self: *Self) void {
            const arena = self.arena;
            const allocator = arena.child_allocator;
            arena.deinit();
            allocator.destroy(arena);
            self.* = undefined;
        }
    };
}

test "Owned fromJson owns parsed arena" {
    const Value = struct { name: []const u8 };
    var owned = try Owned(Value).parseJson(std.testing.allocator, "{\"name\":\"zi\"}", .{ .allocate = .alloc_always });
    defer owned.deinit();

    try std.testing.expectEqualStrings("zi", owned.value.name);
}
