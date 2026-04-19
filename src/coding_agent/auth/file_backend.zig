const std = @import("std");
const storage = @import("../../storage.zig");

/// Auth storage backend — dispatches to shared LockedFile or MemoryFile.
pub const Backend = union(enum) {
    file: storage.LockedFile,
    memory: storage.MemoryFile,

    pub fn readContent(self: *const Backend, allocator: std.mem.Allocator) ?[]const u8 {
        return switch (self.*) {
            .file => |*f| f.readContent(allocator),
            .memory => |*m| m.readContent(allocator),
        };
    }

    pub fn writeContent(self: *Backend, content: []const u8) !void {
        return switch (self.*) {
            .file => |*f| f.writeContent(content),
            .memory => |*m| m.writeContent(content),
        };
    }

    pub fn acquireLock(self: *const Backend) bool {
        return switch (self.*) {
            .file => |*f| f.acquireLock(),
            .memory => |*m| m.acquireLock(),
        };
    }

    pub fn releaseLock(self: *const Backend) void {
        switch (self.*) {
            .file => |*f| f.releaseLock(),
            .memory => |*m| m.releaseLock(),
        }
    }
};

pub fn defaultAuthPath(allocator: std.mem.Allocator) ![]const u8 {
    const agent_dir = try storage.getAgentDir(allocator, null);
    defer allocator.free(agent_dir);
    return std.fs.path.join(allocator, &.{ agent_dir, "auth.json" });
}
