const std = @import("std");

/// Shared status data for the TUI — cwd, model, git branch, extension statuses.
///
/// Owned by Interactive (the composition root). Read by editor border,
/// footer, and future extension widgets. Extensions will mutate via
/// setStatus(key, text) on the extension API.
///
/// Design: pi-mono's FooterDataProvider provides git branch + extension
/// statuses. We match that contract: a single mutable provider with a
/// read-only snapshot view. No allocations on the render path.
pub const StatusData = struct {
    cwd: []const u8 = "",
    model_id: []const u8 = "",
    git_branch: ?[]const u8 = null,
    /// Extension-owned named statuses. Future: setStatus(key, text).
    extension_statuses: std.StringHashMapUnmanaged([]const u8) = .{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) StatusData {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *StatusData) void {
        if (self.git_branch) |b| self.allocator.free(b);
        var iter = self.extension_statuses.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.extension_statuses.deinit(self.allocator);
    }

    /// Set git branch (deep-copies). Pass null to clear.
    pub fn setGitBranch(self: *StatusData, branch: ?[]const u8) void {
        if (self.git_branch) |old| self.allocator.free(old);
        self.git_branch = if (branch) |b| (self.allocator.dupe(u8, b) catch null) else null;
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

test "StatusData git branch set and clear" {
    var sd = StatusData.init(testing.allocator);
    defer sd.deinit();

    sd.setGitBranch("main");
    try testing.expectEqualStrings("main", sd.git_branch.?);

    sd.setGitBranch("feature/foo");
    try testing.expectEqualStrings("feature/foo", sd.git_branch.?);

    sd.setGitBranch(null);
    try testing.expect(sd.git_branch == null);
}

test "StatusData extension status set and remove" {
    var sd = StatusData.init(testing.allocator);
    defer sd.deinit();

    sd.setStatus("lsp", "ready");
    try testing.expectEqualStrings("ready", sd.extension_statuses.get("lsp").?);

    sd.setStatus("lsp", null);
    try testing.expect(sd.extension_statuses.get("lsp") == null);
}
