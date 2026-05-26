const std = @import("std");
const mem = @import("../mem/root.zig");

pub const PersistencePaths = struct {
    global_dir: []const u8,
    cwd: []const u8,

    pub fn sessionsDirForCwd(self: PersistencePaths, allocator: std.mem.Allocator) ![]const u8 {
        const encoded = try encodeCwd(allocator, self.cwd);
        defer allocator.free(encoded);
        return std.fs.path.join(allocator, &.{ self.global_dir, "sessions", encoded });
    }
};

pub fn encodeCwd(allocator: std.mem.Allocator, cwd: []const u8) ![]const u8 {
    var out = mem.ByteBuilder.init(allocator);
    errdefer out.deinit();
    try out.append("--");
    const start: usize = if (cwd.len > 0 and (cwd[0] == '/' or cwd[0] == '\\')) 1 else 0;
    for (cwd[start..]) |char| {
        switch (char) {
            '/', '\\', ':' => try out.appendByte('-'),
            else => try out.appendByte(char),
        }
    }
    try out.append("--");
    return out.toOwnedSlice();
}

test "cwd encoding matches pi session directory shape" {
    const encoded = try encodeCwd(std.testing.allocator, "/Users/me/project:one");
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqualStrings("--Users-me-project-one--", encoded);
}

test "persistence paths computes cwd session directory" {
    const paths: PersistencePaths = .{ .global_dir = "/home/me/.zi", .cwd = "/repo/app" };
    const session_dir = try paths.sessionsDirForCwd(std.testing.allocator);
    defer std.testing.allocator.free(session_dir);

    try std.testing.expect(std.mem.endsWith(u8, session_dir, "sessions/--repo-app--"));
}
