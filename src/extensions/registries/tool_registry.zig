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

/// Tool execution backing. Two flavors share the same registry slot
/// because the spec calls for "built-in tools register through the
/// same mechanism as extension tools, just with zig function pointers
/// instead of Lua coroutines" (docs §Architecture decision 3).
///
/// `builtin` is an opaque pointer to an `agent.protocol.AgentTool` —
/// kept untyped here to avoid an extensions → agent dependency loop
/// while D2 is in flight. Real wiring lands once the registries are
/// hooked into AgentSession; the cast site will document the type.
///
/// `lua` carries a `c_int` reference returned by `luaL_ref` against
/// the runner's Lua state. Resolving it back to a callable lives in
/// the dispatch path (D4 / E1) — the registry stores it raw.
pub const ToolImpl = union(enum) {
    builtin: *anyopaque,
    lua: c_int,
};

/// Provenance of a registration. Used for diagnostics ("tool X
/// already registered by Y") and, eventually, for `unregisterBySource`
/// during /reload of a single extension. The string is borrowed from
/// the loader and is expected to live as long as the registry.
pub const RegistrationSource = struct {
    /// One of "explicit", "user", "project", "builtin".
    kind: []const u8,
    /// Human-readable identifier — usually the extension's file path
    /// or built-in tool name. Borrowed; the loader keeps it alive
    /// for the registry's lifetime.
    id: []const u8,
};

/// Full tool definition as registered through `zi.register_tool` (or
/// the equivalent zig path for built-ins).
///
/// Ownership: every owned slice / std.json.Value here is allocated
/// with the runner's allocator. The registry deinit walks every entry
/// and frees them. Lua-side garbage collection cannot reach into
/// these fields — they live in zig memory only.
pub const ExtensionTool = struct {
    /// Stable identifier. Used as the registry key AND the wire name
    /// the LLM sees in tool_use blocks. Owned.
    name: []const u8,
    /// Display label for UIs. Owned. Defaults to `name` when omitted.
    label: []const u8,
    /// Long-form description for the system prompt. Owned.
    description: []const u8,
    /// JSON schema for the tool's parameters. Owned (deep-cloned from
    /// the Lua table at registration time).
    parameters: std.json.Value,
    /// Optional snippet appended to the system prompt to teach the
    /// LLM when to use this tool. Owned.
    prompt_snippet: ?[]const u8 = null,
    /// Optional list of usage guidelines woven into the system prompt.
    /// Each entry is owned.
    prompt_guidelines: []const []const u8 = &.{},
    /// Execution backend.
    impl: ToolImpl,
    /// Where this registration came from. Borrowed.
    source: RegistrationSource,

    /// Optional Lua function ref (`luaL_ref` slot) for the
    /// tool's result renderer. When present, the TUI calls it at
    /// `tool_execution_end` time to produce structured render spans
    /// for the transcript (see extensions/lua_renderer.zig).
    ///
    /// `null` → no custom result rendering; the transcript falls
    /// back to its default text-wrap formatter.
    ///
    /// Lifetime: released when the Lua state closes during runner
    /// teardown (all refs get GC'd wholesale), so we don't track
    /// it individually here.
    render_result_ref: ?c_int = null,
};

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
    entries: std.ArrayListUnmanaged(ExtensionTool) = .empty,

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
    pub fn register(self: *ToolRegistry, tool: ExtensionTool) !bool {
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
    pub fn get(self: *const ToolRegistry, name: []const u8) ?*const ExtensionTool {
        const idx = self.index.get(name) orelse return null;
        return &self.entries.items[idx];
    }

    /// Number of registered tools.
    pub fn count(self: *const ToolRegistry) usize {
        return self.entries.items.len;
    }

    /// Iterate in registration order — the order matters for system
    /// prompt assembly and `--list-tools` UX.
    pub fn items(self: *const ToolRegistry) []const ExtensionTool {
        return self.entries.items;
    }

    fn freeEntry(self: *ToolRegistry, entry: *ExtensionTool) void {
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

fn dummyTool(allocator: std.mem.Allocator, name: []const u8, source_kind: []const u8) !ExtensionTool {
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
