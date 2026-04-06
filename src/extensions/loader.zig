const std = @import("std");
const storage = @import("../storage.zig");

const log = std.log.scoped(.extensions);

/// Source of an extension file.
pub const ExtensionSource = enum { explicit, user, project, builtin };

/// Discovered extension descriptor. Strings owned by the allocator passed to discover().
pub const LoadedExtension = struct {
    id: []const u8, // basename without .lua, or dir name for init.lua
    path: []const u8, // absolute path to the .lua file to load
    source: ExtensionSource,
};

/// Options for extension discovery.
pub const DiscoverOptions = struct {
    allocator: std.mem.Allocator,
    cwd: []const u8,
    explicit_paths: []const []const u8 = &.{},
    agent_dir_override: ?[]const u8 = null,
};

/// Track seen IDs within a source to avoid duplicates.
const SeenIds = struct {
    ids: std.ArrayListUnmanaged([]const u8) = .empty,

    fn contains(self: *const SeenIds, id: []const u8) bool {
        for (self.ids.items) |existing| {
            if (std.mem.eql(u8, existing, id)) return true;
        }
        return false;
    }

    fn add(self: *SeenIds, allocator: std.mem.Allocator, id: []const u8) !void {
        const duped = try allocator.dupe(u8, id);
        errdefer allocator.free(duped);
        try self.ids.append(allocator, duped);
    }

    fn deinit(self: *SeenIds, allocator: std.mem.Allocator) void {
        for (self.ids.items) |id| allocator.free(id);
        self.ids.deinit(allocator);
    }
};

/// Discover all extensions in load order (explicit → user → project).
/// Caller owns returned slice and all strings. Use freeExtensions() to clean up.
/// Built-in extensions are NOT handled here (skip for C1).
pub fn discover(opts: DiscoverOptions) ![]LoadedExtension {
    var results: std.ArrayListUnmanaged(LoadedExtension) = .empty;
    var seen: SeenIds = .{};
    defer seen.deinit(opts.allocator);

    // 1. Explicit paths (highest priority)
    for (opts.explicit_paths) |path| {
        try loadExplicitPath(opts.allocator, path, &results, &seen);
    }

    // 2. User-global: <agent_dir>/extensions/*.lua
    const agent_dir = try storage.getAgentDir(opts.allocator, opts.agent_dir_override);
    defer opts.allocator.free(agent_dir);
    const user_ext_dir = try std.fs.path.join(opts.allocator, &.{ agent_dir, "extensions" });
    defer opts.allocator.free(user_ext_dir);
    try scanDirectory(opts.allocator, user_ext_dir, .user, &results, &seen);

    // 3. Project-local: <project_dir>/extensions/*.lua
    const project_dir = try storage.getProjectDir(opts.allocator, opts.cwd);
    defer opts.allocator.free(project_dir);
    const project_ext_dir = try std.fs.path.join(opts.allocator, &.{ project_dir, "extensions" });
    defer opts.allocator.free(project_ext_dir);
    try scanDirectory(opts.allocator, project_ext_dir, .project, &results, &seen);

    // Note: builtin extensions handled via @embedFile elsewhere

    return results.toOwnedSlice(opts.allocator);
}

/// Free all strings and the slice itself.
pub fn freeExtensions(allocator: std.mem.Allocator, list: []LoadedExtension) void {
    for (list) |ext| {
        allocator.free(ext.id);
        allocator.free(ext.path);
    }
    allocator.free(list);
}

/// Load an explicit path. Error if path doesn't exist.
fn loadExplicitPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    results: *std.ArrayListUnmanaged(LoadedExtension),
    seen: *SeenIds,
) !void {
    // Verify file exists
    std.fs.accessAbsolute(path, .{}) catch |err| {
        log.warn("explicit extension path not found: {s} ({s})", .{ path, @errorName(err) });
        return err;
    };

    const basename = std.fs.path.basename(path);
    const id = if (std.mem.endsWith(u8, basename, ".lua"))
        basename[0 .. basename.len - 4]
    else
        basename;

    if (seen.contains(id)) {
        log.debug("skipping duplicate explicit extension id: {s}", .{id});
        return;
    }

    const abs_path = try std.fs.realpathAlloc(allocator, path);
    errdefer allocator.free(abs_path);

    const duped_id = try allocator.dupe(u8, id);
    errdefer allocator.free(duped_id);

    try seen.add(allocator, id);
    try results.append(allocator, .{
        .id = duped_id,
        .path = abs_path,
        .source = .explicit,
    });
}

/// Scan a directory for .lua files and foo/init.lua patterns.
fn scanDirectory(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    source: ExtensionSource,
    results: *std.ArrayListUnmanaged(LoadedExtension),
    seen: *SeenIds,
) !void {
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return, // graceful: missing dir = no extensions
        else => {
            log.warn("failed to open extension dir {s}: {s}", .{ dir_path, @errorName(err) });
            return;
        },
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.name[0] == '.') continue; // skip dotfiles

        const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(full_path);

        switch (entry.kind) {
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".lua")) continue;
                const id = entry.name[0 .. entry.name.len - 4];
                if (seen.contains(id)) {
                    log.debug("skipping duplicate extension id in {s}: {s}", .{ @tagName(source), id });
                    continue;
                }
                try addExtension(allocator, id, full_path, source, results, seen);
            },
            .directory => {
                // Check for <dir>/init.lua
                const init_path = try std.fs.path.join(allocator, &.{ full_path, "init.lua" });
                defer allocator.free(init_path);

                std.fs.accessAbsolute(init_path, .{}) catch continue; // no init.lua, skip

                if (seen.contains(entry.name)) {
                    log.debug("skipping duplicate extension id in {s}: {s}", .{ @tagName(source), entry.name });
                    continue;
                }
                try addExtension(allocator, entry.name, init_path, source, results, seen);
            },
            else => continue,
        }
    }
}

/// Add an extension to results, duplicating strings.
fn addExtension(
    allocator: std.mem.Allocator,
    id: []const u8,
    path: []const u8,
    source: ExtensionSource,
    results: *std.ArrayListUnmanaged(LoadedExtension),
    seen: *SeenIds,
) !void {
    const duped_id = try allocator.dupe(u8, id);
    errdefer allocator.free(duped_id);

    const duped_path = try allocator.dupe(u8, path);
    errdefer allocator.free(duped_path);

    try seen.add(allocator, id);
    try results.append(allocator, .{
        .id = duped_id,
        .path = duped_path,
        .source = source,
    });
}

// ── Tests ───────────────────────────────────────────────────────────

test "discover finds foo.lua and bar/init.lua in a temp dir" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create extensions directory structure
    try tmp.dir.makeDir("extensions");
    var ext_dir = try tmp.dir.openDir("extensions", .{});

    // foo.lua (single-file extension)
    try ext_dir.writeFile("foo.lua", "-- foo extension");

    // bar/init.lua (directory extension)
    try ext_dir.makeDir("bar");
    var bar_dir = try ext_dir.openDir("bar", .{});
    try bar_dir.writeFile("init.lua", "-- bar extension");

    // Get absolute path to the extensions dir
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Discover using agent_dir_override
    const opts = DiscoverOptions{
        .allocator = allocator,
        .cwd = "/nonexistent/project", // won't be used since we override agent dir
        .explicit_paths = &.{},
        .agent_dir_override = tmp_path,
    };

    const exts = try discover(opts);
    defer freeExtensions(allocator, exts);

    // Should find exactly 2 extensions
    try std.testing.expectEqual(@as(usize, 2), exts.len);

    // Verify we found both foo and bar (order depends on filesystem iteration)
    var found_foo = false;
    var found_bar = false;
    for (exts) |ext| {
        if (std.mem.eql(u8, ext.id, "foo")) {
            found_foo = true;
            try std.testing.expectEqual(ExtensionSource.user, ext.source);
            try std.testing.expect(std.mem.endsWith(u8, ext.path, "foo.lua"));
        } else if (std.mem.eql(u8, ext.id, "bar")) {
            found_bar = true;
            try std.testing.expectEqual(ExtensionSource.user, ext.source);
            try std.testing.expect(std.mem.endsWith(u8, ext.path, "bar/init.lua"));
        }
    }
    try std.testing.expect(found_foo);
    try std.testing.expect(found_bar);
}

test "discover returns empty when directories missing" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Use a path with no extensions subdirectory
    const opts = DiscoverOptions{
        .allocator = allocator,
        .cwd = tmp_path, // will try <tmp_path>/.zi/extensions (doesn't exist)
        .explicit_paths = &.{},
        .agent_dir_override = tmp_path, // will try <tmp_path>/extensions (doesn't exist)
    };

    const exts = try discover(opts);
    defer freeExtensions(allocator, exts);

    try std.testing.expectEqual(@as(usize, 0), exts.len);
}

test "explicit paths come first in result order" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create user extensions dir with one extension
    try tmp.dir.makeDir("extensions");
    var ext_dir = try tmp.dir.openDir("extensions", .{});
    try ext_dir.writeFile("user_ext.lua", "-- user");

    // Create explicit extension file
    try tmp.dir.writeFile("explicit_ext.lua", "-- explicit");

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const explicit_path = try std.fs.path.join(allocator, &.{ tmp_path, "explicit_ext.lua" });
    defer allocator.free(explicit_path);

    const opts = DiscoverOptions{
        .allocator = allocator,
        .cwd = "/nonexistent/project",
        .explicit_paths = &.{explicit_path},
        .agent_dir_override = tmp_path,
    };

    const exts = try discover(opts);
    defer freeExtensions(allocator, exts);

    // Should have exactly 2 extensions, explicit first
    try std.testing.expectEqual(@as(usize, 2), exts.len);
    try std.testing.expectEqualStrings("explicit_ext", exts[0].id);
    try std.testing.expectEqual(ExtensionSource.explicit, exts[0].source);
    try std.testing.expectEqualStrings("user_ext", exts[1].id);
    try std.testing.expectEqual(ExtensionSource.user, exts[1].source);
}
