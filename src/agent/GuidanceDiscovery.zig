const std = @import("std");
const Context = @import("Context.zig");
const SecureOpen = @import("SecureOpen.zig");
const text = @import("../text/root.zig");

pub const file_cap_bytes: usize = 64 * 1024;
pub const maximum_levels: usize = 64;

pub const Inputs = struct {
    secure_open: SecureOpen.Capability,
    /// Absolute, normalized process working directory. No process state is read.
    cwd: []const u8,
    /// Used only to collapse model-facing absolute paths to `~`.
    home: ?[]const u8 = null,
    /// Already XDG-resolved Zi configuration directory.
    config_root: ?[]const u8 = null,
    /// Optional caller snapshot. `.discover` performs the bounded filesystem search.
    project_root: Context.ProjectRoot = .discover,
};

pub const Error = error{
    OutOfMemory,
    InvalidCwd,
    InvalidPath,
    FactsTooLarge,
};

/// Allocator-owned, move-only discovery result. Its files borrow only storage
/// owned by this value and can be passed directly to Context.Facts.
pub const OwnedFacts = struct {
    files: []Context.GuidanceFile,

    pub fn guidanceFiles(self: *const OwnedFacts) []const Context.GuidanceFile {
        return self.files;
    }

    pub fn deinit(self: *OwnedFacts, allocator: std.mem.Allocator) void {
        for (self.files) |file| {
            allocator.free(file.display_path);
            allocator.free(file.content);
        }
        allocator.free(self.files);
        self.* = undefined;
    }
};

const Collector = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    home: ?[]const u8,
    secure_open: SecureOpen.Capability,
    files: std.ArrayList(Context.GuidanceFile) = .empty,
    retained_bytes: usize = 0,

    fn deinit(self: *Collector) void {
        for (self.files.items) |file| {
            self.allocator.free(file.display_path);
            self.allocator.free(file.content);
        }
        self.files.deinit(self.allocator);
        self.* = undefined;
    }

    fn add(self: *Collector, kind: Context.GuidanceKind, path: []const u8) Error!void {
        if (self.files.items.len == Context.max_guidance_files) return error.FactsTooLarge;

        // Automatic guidance rejects final symlinks to avoid disclosing an
        // arbitrary local file. NONBLOCK closes the special-file race; the
        // opened handle is checked again before read.
        const named_stat = std.Io.Dir.cwd().statFile(self.io, path, .{ .follow_symlinks = false }) catch return;
        if (named_stat.kind != .file) return;
        var file = self.secure_open.openFile(self.io, .cwd(), path) catch return;
        defer file.close(self.io);
        const opened_stat = file.stat(self.io) catch return;
        if (opened_stat.kind != .file) return;

        var raw: [file_cap_bytes + 1]u8 = undefined;
        const count = file.readPositionalAll(self.io, &raw, 0) catch return;
        const retained_count = @min(count, file_cap_bytes);
        const truncated = count > file_cap_bytes;

        const display_source = try collapseHome(self.allocator, path, self.home);
        defer self.allocator.free(display_source);
        const remaining_for_path = Context.max_prompt_bytes -| self.retained_bytes;
        const display_path = text.Utf8.sanitize(
            self.allocator,
            display_source,
            remaining_for_path,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ResultTooLarge => return error.FactsTooLarge,
        };
        errdefer self.allocator.free(display_path);

        const after_path = self.retained_bytes + display_path.len;
        const content = text.Utf8.sanitize(
            self.allocator,
            raw[0..retained_count],
            Context.max_prompt_bytes -| after_path,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ResultTooLarge => return error.FactsTooLarge,
        };
        errdefer self.allocator.free(content);

        try self.files.append(self.allocator, .{
            .kind = kind,
            .display_path = display_path,
            .content = content,
            .truncated = truncated,
        });
        self.retained_bytes = after_path + content.len;
    }
};

/// Discovers global and project AGENTS.md facts. Missing, unreadable, and
/// non-regular candidates are ignored. OOM and invalid explicit inputs are
/// reported. No environment, rendering, configuration, or process lookup occurs.
/// Unlike hax, automatic guidance rejects final symlinks. This prevents a
/// project entry from silently disclosing an unrelated local file.
pub fn discover(
    allocator: std.mem.Allocator,
    io: std.Io,
    inputs: Inputs,
) Error!OwnedFacts {
    const cwd = try normalizedAbsolute(inputs.cwd, error.InvalidCwd);
    const home = if (inputs.home) |value|
        if (value.len == 0) null else try normalizedAbsolute(value, error.InvalidPath)
    else
        null;
    const config_root = if (inputs.config_root) |value|
        if (value.len == 0) null else try normalizedAbsolute(value, error.InvalidPath)
    else
        null;

    var collector: Collector = .{
        .allocator = allocator,
        .io = io,
        .home = home,
        .secure_open = inputs.secure_open,
    };
    defer collector.deinit();

    if (config_root) |root| {
        const path = try joinLeaf(allocator, root, "AGENTS.md");
        defer allocator.free(path);
        try collector.add(.global, path);
    }

    const discovered_root = switch (inputs.project_root) {
        .discover => try findProjectRoot(allocator, io, cwd),
        .missing, .found => null,
    };
    defer if (discovered_root) |root| allocator.free(root);
    const project_root: ?[]const u8 = switch (inputs.project_root) {
        .discover => discovered_root,
        .missing => null,
        .found => |root| root,
    };
    if (project_root) |root| {
        var directories: [maximum_levels][]const u8 = undefined;
        var count: usize = 0;
        var directory = cwd;
        while (count < maximum_levels) : (count += 1) {
            directories[count] = directory;
            if (std.mem.eql(u8, directory, root)) {
                count += 1;
                break;
            }
            const parent = parentPath(directory) orelse break;
            if (std.mem.eql(u8, parent, directory)) break;
            directory = parent;
        }
        var index = count;
        while (index > 0) {
            index -= 1;
            const path = try joinLeaf(allocator, directories[index], "AGENTS.md");
            defer allocator.free(path);
            try collector.add(.project, path);
        }
    } else {
        const path = try joinLeaf(allocator, cwd, "AGENTS.md");
        defer allocator.free(path);
        try collector.add(.project, path);
    }

    const files = try collector.files.toOwnedSlice(allocator);
    collector.files = .empty;
    return .{ .files = files };
}

/// Returns an owned copy of the nearest directory with a `.git` stat marker.
/// At most `maximum_levels` directories are checked. `cwd` must be normalized and
/// absolute. A marker stat failure is treated as absence.
pub fn findProjectRoot(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
) error{OutOfMemory}!?[]u8 {
    var directory = cwd;
    for (0..maximum_levels) |_| {
        const marker = try joinLeaf(allocator, directory, ".git");
        defer allocator.free(marker);
        _ = std.Io.Dir.cwd().statFile(io, marker, .{}) catch {
            const parent = parentPath(directory) orelse break;
            if (std.mem.eql(u8, parent, directory)) break;
            directory = parent;
            continue;
        };
        const root: ?[]u8 = try allocator.dupe(u8, directory);
        return root;
    }
    return null;
}

fn normalizedAbsolute(path: []const u8, invalid: Error) Error![]const u8 {
    if (path.len == 0 or path[0] != '/' or std.mem.indexOfScalar(u8, path, 0) != null) return invalid;
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    return path[0..end];
}

fn parentPath(path: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, path, "/")) return null;
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return null;
    return if (slash == 0) path[0..1] else path[0..slash];
}

fn joinLeaf(allocator: std.mem.Allocator, directory: []const u8, leaf: []const u8) error{OutOfMemory}![]u8 {
    return if (std.mem.eql(u8, directory, "/"))
        std.fmt.allocPrint(allocator, "/{s}", .{leaf})
    else
        std.fmt.allocPrint(allocator, "{s}/{s}", .{ directory, leaf });
}

/// Returns an owned model-facing path, replacing HOME only at a component boundary.
/// Callers pass normalized absolute paths; this helper performs no I/O.
pub fn collapseHome(
    allocator: std.mem.Allocator,
    path: []const u8,
    home: ?[]const u8,
) error{OutOfMemory}![]u8 {
    const base = home orelse return allocator.dupe(u8, path);
    if (!std.mem.startsWith(u8, path, base) or
        (path.len != base.len and base.len != 1 and path[base.len] != '/'))
    {
        return allocator.dupe(u8, path);
    }
    if (path.len == base.len) return allocator.dupe(u8, "~");
    const suffix = if (base.len == 1) path else path[base.len..];
    return std.fmt.allocPrint(allocator, "~{s}", .{suffix});
}

fn testingSecureOpen() SecureOpen.Capability {
    const Adapter = struct {
        fn openFile(
            _: *anyopaque,
            _: std.Io,
            directory: std.Io.Dir,
            name: []const u8,
        ) anyerror!std.Io.File {
            const handle = try std.posix.openat(directory.handle, name, .{
                .ACCMODE = .RDONLY,
                .NONBLOCK = true,
                .CLOEXEC = true,
                .NOFOLLOW = true,
            }, 0);
            return .{ .handle = handle, .flags = .{ .nonblocking = true } };
        }
    };
    return .{ .context = undefined, .open_fn = Adapter.openFile };
}

fn temporaryRoot(tmp: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
    const length = try tmp.dir.realPath(std.testing.io, buffer);
    return buffer[0..length];
}

fn writeRelative(dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
    try dir.writeFile(std.testing.io, .{ .sub_path = path, .data = data });
}

test "outside git only cwd guidance is discovered" {
    const io = std.testing.io;
    var root_buffer: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(
        &root_buffer,
        "/tmp/zi-guidance-{x}",
        .{@intFromPtr(&root_buffer)},
    );
    try std.Io.Dir.createDirAbsolute(io, root, .default_dir);
    defer std.Io.Dir.deleteTree(.cwd(), io, root) catch @panic("test cleanup failed");
    var root_dir = try std.Io.Dir.openDirAbsolute(io, root, .{});
    defer root_dir.close(io);
    try root_dir.createDir(io, "nested", .default_dir);
    try writeRelative(root_dir, "AGENTS.md", "outer");
    try writeRelative(root_dir, "nested/AGENTS.md", "cwd");
    const cwd = try joinLeaf(std.testing.allocator, root, "nested");
    defer std.testing.allocator.free(cwd);

    var result = try discover(std.testing.allocator, io, .{ .secure_open = testingSecureOpen(), .cwd = cwd });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.files.len);
    try std.testing.expectEqualStrings("cwd", result.files[0].content);
    try std.testing.expectEqual(Context.GuidanceKind.project, result.files[0].kind);
}

test "global then root to nested guidance and git file marker" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "config", .default_dir);
    try tmp.dir.createDir(io, "repo", .default_dir);
    try tmp.dir.createDir(io, "repo/a", .default_dir);
    try tmp.dir.createDir(io, "repo/a/b", .default_dir);
    try writeRelative(tmp.dir, "config/AGENTS.md", "global");
    try writeRelative(tmp.dir, "repo/.git", "gitdir: elsewhere");
    try writeRelative(tmp.dir, "repo/AGENTS.md", "root");
    try writeRelative(tmp.dir, "repo/a/AGENTS.md", "middle");
    try writeRelative(tmp.dir, "repo/a/b/AGENTS.md", "inner");
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try temporaryRoot(&tmp, &path_buffer);
    const cwd = try std.fmt.allocPrint(std.testing.allocator, "{s}/repo/a/b", .{root});
    defer std.testing.allocator.free(cwd);
    const config = try std.fmt.allocPrint(std.testing.allocator, "{s}/config", .{root});
    defer std.testing.allocator.free(config);

    var result = try discover(std.testing.allocator, io, .{
        .secure_open = testingSecureOpen(),
        .cwd = cwd,
        .home = root,
        .config_root = config,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), result.files.len);
    try std.testing.expectEqualStrings("global", result.files[0].content);
    try std.testing.expectEqualStrings("root", result.files[1].content);
    try std.testing.expectEqualStrings("middle", result.files[2].content);
    try std.testing.expectEqualStrings("inner", result.files[3].content);
    try std.testing.expectEqual(Context.GuidanceKind.global, result.files[0].kind);
    try std.testing.expectEqualStrings("~/repo/AGENTS.md", result.files[1].display_path);
    try std.testing.expectEqualStrings("~/repo/a/b/AGENTS.md", result.files[3].display_path);
}

test "git root search checks at most 64 directory levels" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, ".git", .default_dir);
    var relative: std.ArrayList(u8) = .empty;
    defer relative.deinit(std.testing.allocator);
    for (0..63) |index| {
        if (index != 0) try relative.append(std.testing.allocator, '/');
        try relative.append(std.testing.allocator, 'd');
    }
    try tmp.dir.createDirPath(io, relative.items);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try temporaryRoot(&tmp, &path_buffer);
    const within = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ root, relative.items });
    defer std.testing.allocator.free(within);
    const found = (try findProjectRoot(std.testing.allocator, io, within)).?;
    defer std.testing.allocator.free(found);
    try std.testing.expectEqualStrings(root, found);

    try relative.appendSlice(std.testing.allocator, "/d");
    try tmp.dir.createDirPath(io, relative.items);
    const beyond = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ root, relative.items });
    defer std.testing.allocator.free(beyond);
    try std.testing.expect((try findProjectRoot(std.testing.allocator, io, beyond)) == null);
}

test "missing directories and symlink guidance are filtered safely" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, ".git", .default_dir);
    try tmp.dir.createDir(io, "real", .default_dir);
    try tmp.dir.createDir(io, "nested", .default_dir);
    try tmp.dir.createDir(io, "nested/AGENTS.md", .default_dir);
    try writeRelative(tmp.dir, "real/rules", "linked");
    try tmp.dir.symLink(io, "real/rules", "AGENTS.md", .{});
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try temporaryRoot(&tmp, &path_buffer);
    const cwd = try joinLeaf(std.testing.allocator, root, "nested");
    defer std.testing.allocator.free(cwd);

    var result = try discover(std.testing.allocator, io, .{ .secure_open = testingSecureOpen(), .cwd = cwd });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), result.files.len);
}

test "content cap probe and sanitizer preserve exact cap semantics" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, ".git", .default_dir);
    var bytes: [file_cap_bytes + 1]u8 = undefined;
    @memset(&bytes, 'x');
    bytes[0] = 0;
    bytes[1] = 0xff;
    try writeRelative(tmp.dir, "AGENTS.md", &bytes);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try temporaryRoot(&tmp, &path_buffer);

    var result = try discover(std.testing.allocator, io, .{ .secure_open = testingSecureOpen(), .cwd = root });
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.files[0].truncated);
    try std.testing.expectEqualStrings("\xef\xbf\xbd\xef\xbf\xbd", result.files[0].content[0..6]);
    try std.testing.expectEqual(file_cap_bytes + 4, result.files[0].content.len);

    try writeRelative(tmp.dir, "AGENTS.md", bytes[0..file_cap_bytes]);
    var exact = try discover(std.testing.allocator, io, .{ .secure_open = testingSecureOpen(), .cwd = root });
    defer exact.deinit(std.testing.allocator);
    try std.testing.expect(!exact.files[0].truncated);
}

fn exerciseDiscoveryAllocations(allocator: std.mem.Allocator) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, ".git", .default_dir);
    try writeRelative(tmp.dir, "AGENTS.md", "rules");
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try temporaryRoot(&tmp, &path_buffer);
    var result = try discover(allocator, io, .{ .secure_open = testingSecureOpen(), .cwd = root, .home = root, .config_root = root });
    result.deinit(allocator);
}

test "discovery allocation failures do not leak" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseDiscoveryAllocations,
        .{},
    );
}
