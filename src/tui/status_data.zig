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
    /// Current model identifier (borrowed from agent state).
    model_id: []const u8 = "",
    /// Estimated context window usage (tokens consumed / total).
    /// null = unknown (e.g., before first LLM response).
    context_tokens: ?u32 = null,
    context_window: u32 = 0,
    /// Whether the agent is currently streaming.
    is_streaming: bool = false,
    /// Extension-owned named statuses. Future: setStatus(key, text) API.
    extension_statuses: std.StringHashMapUnmanaged([]const u8) = .{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) StatusData {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *StatusData) void {
        var iter = self.extension_statuses.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.extension_statuses.deinit(self.allocator);
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
};

const testing = std.testing;

test "StatusData model_id is borrowed" {
    var sd = StatusData.init(testing.allocator);
    defer sd.deinit();
    sd.model_id = "claude-4-opus";
    try testing.expectEqualStrings("claude-4-opus", sd.model_id);
}

test "StatusData extension status set and remove" {
    var sd = StatusData.init(testing.allocator);
    defer sd.deinit();

    sd.setStatus("lsp", "ready");
    try testing.expectEqualStrings("ready", sd.extension_statuses.get("lsp").?);

    sd.setStatus("lsp", null);
    try testing.expect(sd.extension_statuses.get("lsp") == null);
}
