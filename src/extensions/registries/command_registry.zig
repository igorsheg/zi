//! Command registry — slash command name → CommandDef.
//!
//! v1 leaves this empty: `zi.register_command` is a v2 surface
//! (docs/extensions.md line 178). The registry exists from D2
//! anyway because the bind seam (`ExtensionRuntime.Bound.command_actions`)
//! is reserved in v1 and the runner needs SOMEWHERE to store
//! pending entries when v2 ships. Adding this as a same-shape sibling
//! to `tool_registry` keeps the runner's internal API symmetric.
//!
//! Same first-registered-wins rule as tools. Same precedence chain
//! (`explicit > user > project > builtin`).

const std = @import("std");
const tool_registry = @import("tool_registry.zig");

/// Slash command definition. v1 carries only enough fields for the
/// dispatch path that v2 will eventually wire — no zi-side dispatch
/// today. The handler is a Lua registry ref (resolved by D4-style
/// dispatch, but commands route through ExtensionCommandContext
/// instead of ExtensionContext, so they need a separate path).
pub const CommandDef = struct {
    /// Command name without leading `/`. Owned.
    name: []const u8,
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
    index: std.StringHashMapUnmanaged(usize) = .empty,
    entries: std.ArrayListUnmanaged(CommandDef) = .empty,

    pub fn init(allocator: std.mem.Allocator) CommandRegistry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CommandRegistry) void {
        for (self.entries.items) |*entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.description);
        }
        self.entries.deinit(self.allocator);

        var it = self.index.iterator();
        while (it.next()) |kv| self.allocator.free(kv.key_ptr.*);
        self.index.deinit(self.allocator);
    }

    /// First-registered-wins. Returns true on accept, false if a
    /// command with the same name was already registered (caller
    /// retains ownership of the rejected def's strings).
    pub fn register(self: *CommandRegistry, cmd: CommandDef) !bool {
        if (self.index.get(cmd.name) != null) return false;

        const idx = self.entries.items.len;
        try self.entries.append(self.allocator, cmd);
        errdefer _ = self.entries.pop();

        const key_dup = try self.allocator.dupe(u8, cmd.name);
        errdefer self.allocator.free(key_dup);

        try self.index.put(self.allocator, key_dup, idx);
        return true;
    }

    pub fn get(self: *const CommandRegistry, name: []const u8) ?*const CommandDef {
        const idx = self.index.get(name) orelse return null;
        return &self.entries.items[idx];
    }

    pub fn count(self: *const CommandRegistry) usize {
        return self.entries.items.len;
    }

    pub fn items(self: *const CommandRegistry) []const CommandDef {
        return self.entries.items;
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "CommandRegistry first-registered-wins" {
    var reg = CommandRegistry.init(testing.allocator);
    defer reg.deinit();

    const cmd1: CommandDef = .{
        .name = try testing.allocator.dupe(u8, "task"),
        .description = try testing.allocator.dupe(u8, "spawn task"),
        .lua_ref = 1,
        .source = .{ .kind = "user", .id = "task.lua" },
    };
    try testing.expect(try reg.register(cmd1));

    const cmd2: CommandDef = .{
        .name = try testing.allocator.dupe(u8, "task"),
        .description = try testing.allocator.dupe(u8, "shadowed"),
        .lua_ref = 2,
        .source = .{ .kind = "builtin", .id = "task" },
    };
    defer {
        testing.allocator.free(cmd2.name);
        testing.allocator.free(cmd2.description);
    }
    try testing.expect(!(try reg.register(cmd2)));

    try testing.expectEqual(@as(usize, 1), reg.count());
    try testing.expectEqual(@as(c_int, 1), reg.get("task").?.lua_ref);
}
