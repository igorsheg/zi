const std = @import("std");

pub const PathConfig = struct {
    cwd: []const u8,
    allow_paths_outside_cwd: bool = false,
};

pub fn copyConfig(allocator: std.mem.Allocator, config: PathConfig) !PathConfig {
    return .{
        .cwd = try allocator.dupe(u8, config.cwd),
        .allow_paths_outside_cwd = config.allow_paths_outside_cwd,
    };
}

pub fn deinitConfig(allocator: std.mem.Allocator, config: *PathConfig) void {
    allocator.free(config.cwd);
    config.* = undefined;
}

pub fn resolveExistingPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: PathConfig,
    path: []const u8,
) ![]const u8 {
    if (path.len == 0) return error.InvalidToolArguments;
    const resolved = if (std.fs.path.isAbsolute(path))
        try std.fs.path.resolve(allocator, &.{path})
    else
        try std.fs.path.resolve(allocator, &.{ config.cwd, path });
    errdefer allocator.free(resolved);

    if (!config.allow_paths_outside_cwd) {
        const canonical_cwd = try std.Io.Dir.realPathFileAlloc(.cwd(), io, config.cwd, allocator);
        defer allocator.free(canonical_cwd);
        const canonical_path = try std.Io.Dir.realPathFileAlloc(.cwd(), io, resolved, allocator);
        defer allocator.free(canonical_path);
        if (!isPathInside(canonical_cwd, canonical_path)) return error.PathOutsideCwd;
    }
    return resolved;
}

pub fn isPathInside(raw_cwd: []const u8, path: []const u8) bool {
    var cwd = raw_cwd;
    while (cwd.len > 1 and std.fs.path.isSep(cwd[cwd.len - 1])) cwd = cwd[0 .. cwd.len - 1];
    if (!std.mem.startsWith(u8, path, cwd)) return false;
    if (path.len == cwd.len) return true;
    return std.fs.path.isSep(path[cwd.len]);
}

pub fn putJsonField(
    allocator: std.mem.Allocator,
    object: *std.json.ObjectMap,
    key: []const u8,
    value: std.json.Value,
) !void {
    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);
    try object.put(allocator, owned_key, value);
}

test "path containment requires separator boundary" {
    try std.testing.expect(isPathInside("/repo", "/repo"));
    try std.testing.expect(isPathInside("/repo", "/repo/file"));
    try std.testing.expect(!isPathInside("/repo", "/repo2/file"));
}

