const std = @import("std");

/// Agent-internal state shared across TUI components.
///
/// Carries only data that extensions can't trivially obtain on their own:
/// model identity, context window usage, streaming state, extension statuses.
///
/// Owned by Interactive (the composition root). Read by editor border
/// and future extension widgets. Extensions will mutate via
/// setStatus(key, text) on the extension API.
pub const StatusData = struct {
    /// Current model provider identifier. Owned alongside `model_id` so
    /// the TUI can resolve the stable catalog model without agent-thread reads.
    model_provider: []const u8 = "",
    /// Current model identifier. Owned by StatusData so TUI widgets can
    /// read a stable snapshot without reaching back into agent-owned state.
    model_id: []const u8 = "",
    /// Current thinking level label (e.g. "medium", "high"). Empty = off.
    /// Owned for the same reason as `model_id`.
    thinking_level: []const u8 = "",
    /// Estimated context window usage (tokens consumed / total).
    /// null = unknown immediately after compaction, before the first
    /// post-compaction assistant usage lands.
    context_tokens: ?u64 = null,
    context_window: u64 = 0,
    /// Whether the agent is currently streaming.
    is_streaming: bool = false,
    /// Extension-owned named statuses. Future: setStatus(key, text) API.
    extension_statuses: std.StringHashMapUnmanaged([]const u8) = .{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) StatusData {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *StatusData) void {
        if (self.model_provider.len > 0) self.allocator.free(self.model_provider);
        if (self.model_id.len > 0) self.allocator.free(self.model_id);
        if (self.thinking_level.len > 0) self.allocator.free(self.thinking_level);
        var iter = self.extension_statuses.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.extension_statuses.deinit(self.allocator);
    }

    pub fn setModelProvider(self: *StatusData, value: []const u8) void {
        self.replaceOwnedField(&self.model_provider, value);
    }

    pub fn setModelId(self: *StatusData, value: []const u8) void {
        self.replaceOwnedField(&self.model_id, value);
    }

    pub fn setThinkingLevel(self: *StatusData, value: []const u8) void {
        self.replaceOwnedField(&self.thinking_level, value);
    }

    /// Set an extension status entry (deep-copies both key and value).
    /// Pass null value to remove.
    pub fn setStatus(self: *StatusData, key: []const u8, value: ?[]const u8) void {
        if (value) |v| {
            const owned_key = self.allocator.dupe(u8, key) catch return;
            const owned_val = self.allocator.dupe(u8, v) catch {
                self.allocator.free(owned_key);
                return;
            };
            if (self.extension_statuses.fetchRemove(key)) |old| {
                self.allocator.free(old.key);
                self.allocator.free(old.value);
            }
            self.extension_statuses.put(self.allocator, owned_key, owned_val) catch {
                self.allocator.free(owned_key);
                self.allocator.free(owned_val);
            };
        } else {
            if (self.extension_statuses.fetchRemove(key)) |old| {
                self.allocator.free(old.key);
                self.allocator.free(old.value);
            }
        }
    }

    pub const ExtensionStatusItem = struct {
        key: []const u8,
        text: []const u8,
    };

    pub fn collectExtensionStatuses(self: *const StatusData, allocator: std.mem.Allocator) ![]ExtensionStatusItem {
        var items = try allocator.alloc(ExtensionStatusItem, self.extension_statuses.count());
        errdefer allocator.free(items);

        var iter = self.extension_statuses.iterator();
        var i: usize = 0;
        while (iter.next()) |entry| : (i += 1) {
            items[i] = .{ .key = entry.key_ptr.*, .text = entry.value_ptr.* };
        }
        std.mem.sort(ExtensionStatusItem, items, {}, extensionStatusLessThan);
        return items;
    }

    pub fn formatExtensionStatuses(self: *const StatusData, allocator: std.mem.Allocator, separator: []const u8) ![]u8 {
        const items = try self.collectExtensionStatuses(allocator);
        defer allocator.free(items);
        if (items.len == 0) return try allocator.dupe(u8, "");

        var total: usize = 0;
        for (items, 0..) |item, i| {
            if (i > 0) total += separator.len;
            total += item.text.len;
        }

        var out = try allocator.alloc(u8, total);
        var pos: usize = 0;
        for (items, 0..) |item, i| {
            if (i > 0) {
                @memcpy(out[pos..][0..separator.len], separator);
                pos += separator.len;
            }
            @memcpy(out[pos..][0..item.text.len], item.text);
            pos += item.text.len;
        }
        return out;
    }

    fn extensionStatusLessThan(_: void, a: ExtensionStatusItem, b: ExtensionStatusItem) bool {
        return std.mem.lessThan(u8, a.key, b.key);
    }

    fn replaceOwnedField(self: *StatusData, field: *[]const u8, value: []const u8) void {
        const owned = if (value.len > 0)
            self.allocator.dupe(u8, value) catch return
        else
            "";
        if (field.*.len > 0) self.allocator.free(field.*);
        field.* = owned;
    }
};

const testing = std.testing;

test "StatusData formats extension status values in key order" {
    var sd = StatusData.init(testing.allocator);
    defer sd.deinit();

    sd.setStatus("zeta", "last");
    sd.setStatus("alpha", "first");
    sd.setStatus("middle", "middle");

    const formatted = try sd.formatExtensionStatuses(testing.allocator, " ");
    defer testing.allocator.free(formatted);
    try testing.expectEqualStrings("first middle last", formatted);
}
