//! Command registry — ordered aggregation of slash command defs with
//! visible invocation name resolution.
//!
//! Registration always succeeds. Duplicate canonical names resolve into
//! deterministic visible names (`x:1`, `x:2`, …) in registration order.
//! Bare `x` is visible only when exactly one command with that canonical
//! name exists.

const std = @import("std");
const tool_registry = @import("tool_registry.zig");

/// Slash command definition.
pub const CommandDef = struct {
    /// Canonical command name without leading `/`. Owned.
    name: []const u8,
    /// Visible invocation name (`x` or `x:1`). Owned, rebuilt on every
    /// registry mutation to keep duplicate numbering truthful.
    visible_name: []const u8,
    /// Short description for `/help`. Owned.
    description: []const u8,
    /// Lua registry ref for the handler closure. The runner closes
    /// the Lua state on deinit; individual unref calls are not needed.
    lua_ref: c_int,
    /// Provenance — extension file path or "builtin". Borrowed.
    source: tool_registry.RegistrationSource,
};

pub const CommandRegistry = struct {
    allocator: std.mem.Allocator,
    /// All registered commands in registration order.
    entries: std.ArrayListUnmanaged(CommandDef) = .empty,
    /// Maps visible invocation name → index in `entries`.
    visible_index: std.StringHashMapUnmanaged(usize) = .empty,

    pub fn init(allocator: std.mem.Allocator) CommandRegistry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CommandRegistry) void {
        for (self.entries.items) |*entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.visible_name);
            self.allocator.free(entry.description);
        }
        self.entries.deinit(self.allocator);
        var it = self.visible_index.iterator();
        while (it.next()) |kv| self.allocator.free(kv.key_ptr.*);
        self.visible_index.deinit(self.allocator);
    }

    /// Register a command. Always appends; duplicate canonical names
    /// are resolved into visible invocation names at query time.
    pub fn register(self: *CommandRegistry, cmd: CommandDef) !void {
        const idx = self.entries.items.len;
        try self.entries.append(self.allocator, cmd);
        errdefer {
            self.allocator.free(self.entries.items[idx].name);
            self.allocator.free(self.entries.items[idx].visible_name);
            self.allocator.free(self.entries.items[idx].description);
            _ = self.entries.orderedRemove(idx);
        }
        try self.rebuildVisibleIndex();
    }

    /// Look up a command by its visible invocation name.
    pub fn getByVisibleName(self: *const CommandRegistry, name: []const u8) ?*const CommandDef {
        const idx = self.visible_index.get(name) orelse return null;
        return &self.entries.items[idx];
    }

    pub fn count(self: *const CommandRegistry) usize {
        return self.entries.items.len;
    }

    pub fn items(self: *const CommandRegistry) []const CommandDef {
        return self.entries.items;
    }

    pub fn visibleCount(self: *const CommandRegistry) usize {
        return self.visible_index.count();
    }

    pub const VisibleEntry = struct {
        visible_name: []const u8,
        description: []const u8,
    };

    /// Fill `buf` with visible entries. Returns the number written
    /// (capped at `buf.len`).
    pub fn visibleEntries(self: *const CommandRegistry, buf: []VisibleEntry) usize {
        const n = @min(buf.len, self.entries.items.len);
        for (self.entries.items[0..n], 0..) |entry, i| {
            buf[i] = .{
                .visible_name = entry.visible_name,
                .description = entry.description,
            };
        }
        return n;
    }

    fn rebuildVisibleIndex(self: *CommandRegistry) !void {
        var new_names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer new_names.deinit(self.allocator);
        errdefer for (new_names.items) |name| self.allocator.free(name);

        // Count occurrences per canonical name.
        var counts = std.StringHashMap(usize).init(self.allocator);
        defer counts.deinit();
        for (self.entries.items) |entry| {
            const gop = try counts.getOrPut(entry.name);
            if (gop.found_existing) {
                gop.value_ptr.* += 1;
            } else {
                gop.value_ptr.* = 1;
            }
        }

        // Track per-canonical occurrence index for suffix generation.
        var occurrence = std.StringHashMap(usize).init(self.allocator);
        defer occurrence.deinit();

        for (self.entries.items) |entry| {
            const canonical_count = counts.get(entry.name).?;
            const visible_name = if (canonical_count == 1) blk: {
                break :blk try self.allocator.dupe(u8, entry.name);
            } else blk: {
                const gop = try occurrence.getOrPut(entry.name);
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += 1;
                const idx = gop.value_ptr.*;
                break :blk try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ entry.name, idx });
            };
            try new_names.append(self.allocator, visible_name);
        }

        var new_index: std.StringHashMapUnmanaged(usize) = .empty;
        errdefer {
            var it = new_index.iterator();
            while (it.next()) |kv| self.allocator.free(kv.key_ptr.*);
            new_index.deinit(self.allocator);
        }

        for (new_names.items, 0..) |visible_name, i| {
            const key = try self.allocator.dupe(u8, visible_name);
            errdefer self.allocator.free(key);
            try new_index.put(self.allocator, key, i);
        }

        for (self.entries.items, new_names.items) |*entry, visible_name| {
            self.allocator.free(entry.visible_name);
            entry.visible_name = visible_name;
        }

        var old_it = self.visible_index.iterator();
        while (old_it.next()) |kv| self.allocator.free(kv.key_ptr.*);
        self.visible_index.deinit(self.allocator);
        self.visible_index = new_index;
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "CommandRegistry duplicate names resolve to visible invocation names" {
    var reg = CommandRegistry.init(testing.allocator);
    defer reg.deinit();

    try reg.register(.{
        .name = try testing.allocator.dupe(u8, "task"),
        .visible_name = try testing.allocator.dupe(u8, "task"),
        .description = try testing.allocator.dupe(u8, "first task"),
        .lua_ref = 1,
        .source = .{ .kind = "user", .id = "a.lua" },
    });
    try reg.register(.{
        .name = try testing.allocator.dupe(u8, "task"),
        .visible_name = try testing.allocator.dupe(u8, "task"),
        .description = try testing.allocator.dupe(u8, "second task"),
        .lua_ref = 2,
        .source = .{ .kind = "user", .id = "b.lua" },
    });
    try reg.register(.{
        .name = try testing.allocator.dupe(u8, "other"),
        .visible_name = try testing.allocator.dupe(u8, "other"),
        .description = try testing.allocator.dupe(u8, "other cmd"),
        .lua_ref = 3,
        .source = .{ .kind = "user", .id = "c.lua" },
    });

    try testing.expectEqual(@as(usize, 3), reg.count());
    try testing.expectEqual(@as(usize, 3), reg.visibleCount());

    // Bare name gone for duplicates.
    try testing.expect(reg.getByVisibleName("task") == null);

    // Suffixes exist in registration order.
    const t1 = reg.getByVisibleName("task:1").?;
    try testing.expectEqualStrings("first task", t1.description);
    try testing.expectEqual(@as(c_int, 1), t1.lua_ref);

    const t2 = reg.getByVisibleName("task:2").?;
    try testing.expectEqualStrings("second task", t2.description);
    try testing.expectEqual(@as(c_int, 2), t2.lua_ref);

    // Unique name stays bare.
    const o = reg.getByVisibleName("other").?;
    try testing.expectEqualStrings("other cmd", o.description);
    try testing.expectEqual(@as(c_int, 3), o.lua_ref);
}

test "CommandRegistry single command keeps bare visible name" {
    var reg = CommandRegistry.init(testing.allocator);
    defer reg.deinit();

    try reg.register(.{
        .name = try testing.allocator.dupe(u8, "hello"),
        .visible_name = try testing.allocator.dupe(u8, "hello"),
        .description = try testing.allocator.dupe(u8, "say hello"),
        .lua_ref = 42,
        .source = .{ .kind = "builtin", .id = "builtin" },
    });

    try testing.expectEqual(@as(usize, 1), reg.visibleCount());
    const cmd = reg.getByVisibleName("hello").?;
    try testing.expectEqualStrings("hello", cmd.name);
    try testing.expectEqualStrings("say hello", cmd.description);
    try testing.expectEqual(@as(c_int, 42), cmd.lua_ref);
}
