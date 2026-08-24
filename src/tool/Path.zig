const std = @import("std");

pub fn expandHome(
    allocator: std.mem.Allocator,
    path: []const u8,
    home: ?[]const u8,
) error{OutOfMemory}![]u8 {
    const home_path = home orelse return allocator.dupe(u8, path);
    if (home_path.len == 0 or path.len == 0 or path[0] != '~' or
        (path.len > 1 and path[1] != '/'))
    {
        return allocator.dupe(u8, path);
    }
    if (path.len == 1) return allocator.dupe(u8, home_path);
    return std.fs.path.join(allocator, &.{ home_path, path[2..] });
}

/// Rewrites one string `path` member to a strict cwd descendant. The returned
/// compact JSON is owned. Null means the original arguments remain effective.
pub fn preprocessArgs(
    allocator: std.mem.Allocator,
    io: std.Io,
    args_json: ?[]const u8,
    home: ?[]const u8,
    maximum_json_bytes: usize,
) error{OutOfMemory}!?[]u8 {
    const input = args_json orelse return null;
    if (input.len > maximum_json_bytes) return null;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, input, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const path_value = parsed.value.object.get("path") orelse return null;
    if (path_value != .string) return null;
    const expanded = try expandHome(allocator, path_value.string, home);
    defer allocator.free(expanded);
    if (!std.fs.path.isAbsolute(expanded)) return null;

    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_length = std.process.currentPath(io, &cwd_buffer) catch return null;
    const relative = descendantPath(expanded, cwd_buffer[0..cwd_length]) orelse return null;

    // parseFromSlice owns the source map with its parsed allocator. Build a
    // separate map rather than reallocating that storage with `allocator`.
    var object: std.json.ObjectMap = .empty;
    defer object.deinit(allocator);
    var iterator = parsed.value.object.iterator();
    while (iterator.next()) |entry| {
        const value: std.json.Value = if (std.mem.eql(u8, entry.key_ptr.*, "path"))
            .{ .string = relative }
        else
            entry.value_ptr.*;
        try object.put(allocator, entry.key_ptr.*, value);
    }
    const rewritten = try std.json.Stringify.valueAlloc(
        allocator,
        @as(std.json.Value, .{ .object = object }),
        .{},
    );
    return rewritten;
}

pub fn descendantPath(path: []const u8, cwd: []const u8) ?[]const u8 {
    if (!std.fs.path.isAbsolute(path) or !std.fs.path.isAbsolute(cwd) or
        hasParentComponent(path)) return null;
    var cwd_length = cwd.len;
    while (cwd_length > 1 and cwd[cwd_length - 1] == '/') cwd_length -= 1;
    var relative_start: usize = undefined;
    if (cwd_length == 1) {
        relative_start = 1;
    } else {
        if (path.len <= cwd_length or !std.mem.eql(u8, path[0..cwd_length], cwd[0..cwd_length]) or
            path[cwd_length] != '/') return null;
        relative_start = cwd_length + 1;
    }
    while (relative_start < path.len and path[relative_start] == '/') relative_start += 1;
    if (relative_start == path.len) return null;
    return path[relative_start..];
}

fn hasParentComponent(path: []const u8) bool {
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return true;
    }
    return false;
}

test "home expansion only recognizes tilde and tilde slash" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { path: []const u8, home: ?[]const u8, expected: []const u8 }{
        .{ .path = "~", .home = "/home/u", .expected = "/home/u" },
        .{ .path = "~/x", .home = "/home/u/", .expected = "/home/u/x" },
        .{ .path = "~other/x", .home = "/home/u", .expected = "~other/x" },
        .{ .path = "~/x", .home = null, .expected = "~/x" },
    };
    for (cases) |case| {
        const expanded = try expandHome(allocator, case.path, case.home);
        defer allocator.free(expanded);
        try std.testing.expectEqualStrings(case.expected, expanded);
    }
}

test "descendant path matches hax separator and parent rules" {
    try std.testing.expectEqualStrings("src/a", descendantPath("/work//src/a", "/work").?);
    try std.testing.expectEqualStrings("src//a", descendantPath("/work/src//a", "/work").?);
    try std.testing.expectEqualStrings("work/src", descendantPath("//work/src", "/").?);
    try std.testing.expect(descendantPath("/work/src/../a", "/work") == null);
    try std.testing.expect(descendantPath("/work", "/work") == null);
    try std.testing.expect(descendantPath("/other/a", "/work") == null);
}
