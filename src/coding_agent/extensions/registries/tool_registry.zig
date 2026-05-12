const std = @import("std");
const definition = @import("../../tools/definition.zig");

pub const BuiltinImpl = definition.BuiltinImpl;
pub const ToolImpl = definition.ToolImpl;
pub const RegistrationSource = definition.RegistrationSource;

pub const ToolDefinition = definition.ToolDefinition;

pub const ToolRegistry = struct {
    allocator: std.mem.Allocator,

    index: std.StringHashMapUnmanaged(usize) = .empty,

    entries: std.ArrayListUnmanaged(ToolDefinition) = .empty,

    pub fn init(allocator: std.mem.Allocator) ToolRegistry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ToolRegistry) void {
        for (self.entries.items) |*entry| {
            self.freeEntry(entry);
        }
        self.entries.deinit(self.allocator);

        var it = self.index.iterator();
        while (it.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
        }
        self.index.deinit(self.allocator);
    }

    pub fn register(self: *ToolRegistry, tool: ToolDefinition) !bool {
        if (self.index.get(tool.name) != null) return false;

        const idx = self.entries.items.len;
        try self.entries.append(self.allocator, tool);
        errdefer _ = self.entries.pop();

        const key_dup = try self.allocator.dupe(u8, tool.name);
        errdefer self.allocator.free(key_dup);

        try self.index.put(self.allocator, key_dup, idx);
        return true;
    }

    pub fn get(self: *const ToolRegistry, name: []const u8) ?*const ToolDefinition {
        const idx = self.index.get(name) orelse return null;
        return &self.entries.items[idx];
    }

    pub fn count(self: *const ToolRegistry) usize {
        return self.entries.items.len;
    }

    pub fn items(self: *const ToolRegistry) []const ToolDefinition {
        return self.entries.items;
    }

    fn freeEntry(self: *ToolRegistry, entry: *ToolDefinition) void {
        definition.freeOwned(self.allocator, entry);
    }
};

const testing = std.testing;

fn dummyTool(allocator: std.mem.Allocator, name: []const u8, source_kind: []const u8) !ToolDefinition {
    return .{
        .name = try allocator.dupe(u8, name),
        .label = try allocator.dupe(u8, name),
        .description = try allocator.dupe(u8, "test tool"),
        .parameters = .{ .object = .{} },
        .impl = .{ .lua = 1 },
        .source = .{ .kind = source_kind, .id = name },
        .owned = true,
    };
}

test "ToolRegistry first-registered-wins" {
    var reg = ToolRegistry.init(testing.allocator);
    defer reg.deinit();

    const t1 = try dummyTool(testing.allocator, "task", "user");
    try testing.expect(try reg.register(t1));
    try testing.expectEqual(@as(usize, 1), reg.count());

    const t2 = try dummyTool(testing.allocator, "task", "builtin");
    defer {
        testing.allocator.free(t2.name);
        testing.allocator.free(t2.label);
        testing.allocator.free(t2.description);
        var p = t2.parameters.object;
        p.deinit(testing.allocator);
    }
    try testing.expect(!(try reg.register(t2)));
    try testing.expectEqual(@as(usize, 1), reg.count());

    const got = reg.get("task").?;
    try testing.expectEqualStrings("user", got.source.kind);
}

test "ToolRegistry preserves insertion order in items()" {
    var reg = ToolRegistry.init(testing.allocator);
    defer reg.deinit();

    _ = try reg.register(try dummyTool(testing.allocator, "alpha", "user"));
    _ = try reg.register(try dummyTool(testing.allocator, "beta", "user"));
    _ = try reg.register(try dummyTool(testing.allocator, "gamma", "user"));

    const all = reg.items();
    try testing.expectEqual(@as(usize, 3), all.len);
    try testing.expectEqualStrings("alpha", all[0].name);
    try testing.expectEqualStrings("beta", all[1].name);
    try testing.expectEqualStrings("gamma", all[2].name);
}
