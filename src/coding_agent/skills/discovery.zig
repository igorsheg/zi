const std = @import("std");

pub fn discoverSkillFiles(allocator: std.mem.Allocator, root_dir: []const u8) ![]const []const u8 {
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (files.items) |path| allocator.free(path);
        files.deinit(allocator);
    }

    try discoverRecursive(allocator, root_dir, true, &files);
    return try files.toOwnedSlice(allocator);
}

fn discoverRecursive(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    include_root_markdown: bool,
    files: *std.ArrayListUnmanaged([]const u8),
) !void {
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close();

    var entries = std.ArrayListUnmanaged(std.fs.Dir.Entry){};
    defer entries.deinit(allocator);
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        try entries.append(allocator, entry);
    }

    for (entries.items) |entry| {
        if (std.mem.eql(u8, entry.name, "SKILL.md")) {
            const path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
            try files.append(allocator, path);
            return;
        }
    }

    for (entries.items) |entry| {
        if (entry.name.len > 0 and entry.name[0] == '.') continue;
        if (std.mem.eql(u8, entry.name, "node_modules")) continue;

        const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(full_path);

        switch (entry.kind) {
            .directory => try discoverRecursive(allocator, full_path, false, files),
            .file => if (include_root_markdown and std.mem.endsWith(u8, entry.name, ".md")) {
                try files.append(allocator, try allocator.dupe(u8, full_path));
            },
            else => {},
        }
    }
}

test "discover skill files finds SKILL roots and root markdown files" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("skills/git");
    try tmp.dir.writeFile(.{ .sub_path = "skills/readme.md", .data = "plain" });
    try tmp.dir.writeFile(.{ .sub_path = "skills/git/SKILL.md", .data = "skill" });
    const root = try tmp.dir.realpathAlloc(allocator, "skills");
    defer allocator.free(root);

    const files = try discoverSkillFiles(allocator, root);
    defer {
        for (files) |path| allocator.free(path);
        allocator.free(files);
    }

    try std.testing.expectEqual(@as(usize, 2), files.len);
}
