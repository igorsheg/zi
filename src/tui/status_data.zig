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

test "StatusData owns model and thinking labels" {
    var sd = StatusData.init(testing.allocator);
    defer sd.deinit();
    sd.setModelProvider("anthropic");
    sd.setModelId("claude-4-opus");
    sd.setThinkingLevel("high");
    try testing.expectEqualStrings("anthropic", sd.model_provider);
    try testing.expectEqualStrings("claude-4-opus", sd.model_id);
    try testing.expectEqualStrings("high", sd.thinking_level);
}

test "StatusData extension status set and remove" {
    var sd = StatusData.init(testing.allocator);
    defer sd.deinit();

    sd.setStatus("lsp", "ready");
    try testing.expectEqualStrings("ready", sd.extension_statuses.get("lsp").?);

    sd.setStatus("lsp", null);
    try testing.expect(sd.extension_statuses.get("lsp") == null);
}
