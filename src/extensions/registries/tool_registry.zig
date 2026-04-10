//! Tool registry — name → ExtensionTool, first-registered-wins.
//!
//! Owned by `ExtensionRunner`. One registry per generation; reload
//! creates a fresh registry from a fresh Lua state, leaving the old
//! one untouched until the new generation is bound.
//!
//! Why first-registered-wins (and not last-wins): the loader walks
//! sources in precedence order — `explicit > user > project > builtin`
//! (see docs/extensions.md §Discovery) — so an earlier registration
//! is by definition the more authoritative one. A user's
//! `~/.zi/agent/extensions/task.lua` overrides the builtin `task`
//! tool because it loads first. Late registrations with the same
//! name are silently dropped with a diagnostic; this matches pi-mono's
//! behavior under its inverted load order.
//!
//! Tool definitions OWN their strings and JSON schema via the runner's
//! allocator. The schema in particular MUST be deep-cloned out of Lua
//! memory at registration time — Lua tables can be GC'd while zig is
//! still holding pointers to them. See docs/extensions.md §Ownership
//! and Reload §Invariants.

const std = @import("std");
const definition = @import("../../tools/definition.zig");

pub const BuiltinImpl = definition.BuiltinImpl;
pub const ToolImpl = definition.ToolImpl;
pub const RegistrationSource = definition.RegistrationSource;

pub const ToolDefinition = definition.ToolDefinition;

/// First-registered-wins map.
///
/// Stores entries in BOTH a hash map (for `get`) and an ordered list
/// (for iteration in registration order). Iteration order matters for
/// system-prompt assembly: snippets and guidelines are stitched
/// together in the same order users see in `--list-tools`, which
/// matches load order.
pub const ToolRegistry = struct {
    allocator: std.mem.Allocator,
    /// Lookup index. Keys are owned dupes of tool names; values are
    /// indices into `entries`.
    index: std.StringHashMapUnmanaged(usize) = .empty,
    /// Insertion-ordered storage. Index stability is required by the
    /// `index` map, so this list never shrinks except on `deinit`.
    entries: std.ArrayListUnmanaged(ToolDefinition) = .empty,

    pub fn init(allocator: std.mem.Allocator) ToolRegistry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ToolRegistry) void {
        // Free every entry's owned strings + JSON schema. The hash
        // map's keys are dupes of the same `name` slices that the
        // entries themselves own — we free them via the entry, then
        // tear down the index without re-freeing.
        for (self.entries.items) |*entry| {
            self.freeEntry(entry);
        }
        self.entries.deinit(self.allocator);

        // The index keys are independent dupes (so the map can outlive
        // a hypothetical entry-by-value rewrite). Free them here.
        var it = self.index.iterator();
        while (it.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
        }
        self.index.deinit(self.allocator);
    }

    /// Try to register a tool. Returns true if accepted, false if a
    /// tool with the same `name` was already registered (the new one
    /// is dropped, the old one wins).
    ///
    /// On accept the registry takes ownership of every owned field
    /// in `tool` — caller MUST NOT free them. On drop the caller
    /// retains ownership and is responsible for freeing.
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

    /// Look up a tool by name. Returned pointer is stable until
    /// `deinit` (entries are append-only within a generation).
    pub fn get(self: *const ToolRegistry, name: []const u8) ?*const ToolDefinition {
        const idx = self.index.get(name) orelse return null;
        return &self.entries.items[idx];
    }

    /// Number of registered tools.
    pub fn count(self: *const ToolRegistry) usize {
        return self.entries.items.len;
    }

    /// Iterate in registration order — the order matters for system
    /// prompt assembly and `--list-tools` UX.
    pub fn items(self: *const ToolRegistry) []const ToolDefinition {
        return self.entries.items;
    }

    fn freeEntry(self: *ToolRegistry, entry: *ToolDefinition) void {
        const a = self.allocator;
        a.free(entry.name);
        a.free(entry.label);
        a.free(entry.description);
        if (entry.prompt_snippet) |s| a.free(s);
        for (entry.prompt_guidelines) |g| a.free(g);
        if (entry.prompt_guidelines.len > 0) a.free(entry.prompt_guidelines);
        json_value.freeJsonValue(a, entry.parameters);
        // `source` strings are borrowed by contract — do not free.
    }
};

const json_value = @import("../../json/value.zig");

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn dummyTool(allocator: std.mem.Allocator, name: []const u8, source_kind: []const u8) !ToolDefinition {
    return .{
        .name = try allocator.dupe(u8, name),
        .label = try allocator.dupe(u8, name),
        .description = try allocator.dupe(u8, "test tool"),
        .parameters = .{ .object = std.json.ObjectMap.init(allocator) },
        .impl = .{ .lua = 1 },
        .source = .{ .kind = source_kind, .id = name },
    };
}

test "ToolRegistry first-registered-wins" {
    var reg = ToolRegistry.init(testing.allocator);
    defer reg.deinit();

    // First registration accepted.
    const t1 = try dummyTool(testing.allocator, "task", "user");
    try testing.expect(try reg.register(t1));
    try testing.expectEqual(@as(usize, 1), reg.count());

    // Second registration with same name dropped — but the caller
    // still owns the rejected tool, so we must free it ourselves.
    const t2 = try dummyTool(testing.allocator, "task", "builtin");
    defer {
        testing.allocator.free(t2.name);
        testing.allocator.free(t2.label);
        testing.allocator.free(t2.description);
        var p = t2.parameters.object;
        p.deinit();
    }
    try testing.expect(!(try reg.register(t2)));
    try testing.expectEqual(@as(usize, 1), reg.count());

    // The first one still wins, with its source preserved.
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
