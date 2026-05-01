//! Extension keybinding registry — runtime extension-owned key claims.

const std = @import("std");
const keys = @import("../../../tui/keys.zig");
const tool_registry = @import("tool_registry.zig");
const lua_runtime = @import("../lua_runtime.zig");
const LuaRef = c_int;

pub const KeybindingDef = struct {
    /// Stable semantic id. Owned.
    id: []const u8,
    /// Short description for hotkey help. Owned.
    description: []const u8,
    /// Normalized trigger keys. Owned.
    keys: []keys.Key,
    /// User-facing key labels, parallel to keys. Owned strings + slice.
    displays: []const []const u8,
    /// Lua registry ref for handler closure.
    lua_ref: LuaRef,
    /// Provenance — extension file path or "builtin". Borrowed.
    source: tool_registry.RegistrationSource,

    pub fn deinit(self: *KeybindingDef, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.description);
        allocator.free(self.keys);
        for (self.displays) |display| allocator.free(display);
        allocator.free(self.displays);
        self.* = undefined;
    }
};

pub const Match = struct {
    def: *const KeybindingDef,
    key_index: usize,
};

pub const KeybindingRegistry = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(KeybindingDef) = .empty,

    pub fn init(allocator: std.mem.Allocator) KeybindingRegistry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *KeybindingRegistry) void {
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.deinit(self.allocator);
    }

    pub fn register(self: *KeybindingRegistry, def: KeybindingDef) !void {
        try self.entries.append(self.allocator, def);
    }

    pub fn count(self: *const KeybindingRegistry) usize {
        return self.entries.items.len;
    }

    pub fn items(self: *const KeybindingRegistry) []const KeybindingDef {
        return self.entries.items;
    }

    /// First claimant wins for a physical key inside this generation.
    pub fn matchKey(self: *const KeybindingRegistry, key: keys.Key) ?Match {
        for (self.entries.items) |*entry| {
            for (entry.keys, 0..) |candidate, i| {
                if (keys.Key.eql(candidate, key)) return .{ .def = entry, .key_index = i };
            }
        }
        return null;
    }
};

const testing = std.testing;

test "KeybindingRegistry returns first claimant for a physical key" {
    var reg = KeybindingRegistry.init(testing.allocator);
    defer reg.deinit();

    const key = keys.Key{ .code = .char, .char = 'f', .ctrl = true };
    inline for (.{ "first", "second" }, 0..) |id, idx| {
        const owned_keys = try testing.allocator.alloc(keys.Key, 1);
        owned_keys[0] = key;
        const displays = try testing.allocator.alloc([]const u8, 1);
        displays[0] = try testing.allocator.dupe(u8, "ctrl+f");
        try reg.register(.{
            .id = try testing.allocator.dupe(u8, id),
            .description = try testing.allocator.dupe(u8, id),
            .keys = owned_keys,
            .displays = displays,
            .lua_ref = @intCast(idx + 1),
            .source = .{ .kind = "user", .id = id },
        });
    }

    const found = reg.matchKey(key).?;
    try testing.expectEqualStrings("first", found.def.id);
    try testing.expectEqual(@as(usize, 0), found.key_index);
}
