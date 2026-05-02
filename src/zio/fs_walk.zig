const std = @import("std");

pub const Options = struct {
    max_visited: usize = 10_000,
    max_depth: usize = 32,
    include_files: bool = true,
    include_dirs: bool = true,
    include_hidden: bool = true,
    follow_symlinks: bool = false,
};

pub const Entry = struct {
    relative_path: []const u8,
    is_directory: bool,
};

pub fn walkProject(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    opts: Options,
    ctx: anytype,
    comptime on_entry: fn (@TypeOf(ctx), Entry) anyerror!void,
) !void {
    var root_dir = try std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true });
    defer root_dir.close(io);

    var path_buf: [4096]u8 = undefined;
    var visited: usize = 0;
    try walkDir(io, allocator, root_dir, "", &path_buf, 0, opts, &visited, ctx, on_entry);
}

fn walkDir(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    prefix: []const u8,
    path_buf: []u8,
    depth: usize,
    opts: Options,
    visited: *usize,
    ctx: anytype,
    comptime on_entry: fn (@TypeOf(ctx), Entry) anyerror!void,
) !void {
    if (depth >= opts.max_depth or visited.* >= opts.max_visited) return;

    var iter = dir.iterate();
    while (visited.* < opts.max_visited) {
        const entry = iter.next(io) catch continue;
        const value = entry orelse break;
        if (value.name.len == 0) continue;
        if (shouldSkipName(value.name, opts)) continue;

        const rel = buildRelativePath(path_buf, prefix, value.name) orelse continue;
        visited.* += 1;

        var is_directory = value.kind == .directory;
        if (!is_directory and value.kind == .sym_link and opts.follow_symlinks) {
            const stat: ?std.Io.File.Stat = dir.statFile(io, value.name, .{}) catch null;
            if (stat) |s| is_directory = s.kind == .directory;
        }

        if (is_directory) {
            if (opts.include_dirs) try on_entry(ctx, .{ .relative_path = rel, .is_directory = true });

            var child = dir.openDir(io, value.name, .{ .iterate = true }) catch continue;
            defer child.close(io);
            try walkDir(io, allocator, child, rel, path_buf, depth + 1, opts, visited, ctx, on_entry);
        } else if (opts.include_files) {
            try on_entry(ctx, .{ .relative_path = rel, .is_directory = false });
        }
    }

}

fn buildRelativePath(buf: []u8, prefix: []const u8, name: []const u8) ?[]const u8 {
    const extra_sep: usize = if (prefix.len == 0) 0 else 1;
    const len = prefix.len + extra_sep + name.len;
    if (len > buf.len) return null;
    if (prefix.len > 0) {
        if (buf.ptr != prefix.ptr) @memcpy(buf[0..prefix.len], prefix);
        buf[prefix.len] = std.fs.path.sep;
    }
    @memcpy(buf[prefix.len + extra_sep ..][0..name.len], name);
    return buf[0..len];
}

fn shouldSkipName(name: []const u8, opts: Options) bool {
    if (std.mem.eql(u8, name, ".git")) return true;
    if (!opts.include_hidden and name[0] == '.') return true;
    if (std.mem.eql(u8, name, ".zig-cache") or
        std.mem.eql(u8, name, "zig-cache") or
        std.mem.eql(u8, name, "node_modules") or
        std.mem.eql(u8, name, "target")) return true;
    return false;
}

test "walkProject visits files and directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.Options.debug_io, "src/nested");
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "src/main.zig", .data = "" });
    try tmp.dir.createDirPath(std.Options.debug_io, ".git/objects");
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = ".git/config", .data = "" });

    const root = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    const Ctx = struct {
        count: usize = 0,
        saw_main: bool = false,
        fn onEntry(self: *@This(), entry: Entry) !void {
            self.count += 1;
            if (std.mem.eql(u8, entry.relative_path, "src/main.zig")) self.saw_main = true;
            try std.testing.expect(!std.mem.startsWith(u8, entry.relative_path, ".git"));
        }
    };
    var ctx = Ctx{};
    try walkProject(std.Options.debug_io, std.testing.allocator, root, .{}, &ctx, Ctx.onEntry);
    try std.testing.expect(ctx.count >= 2);
    try std.testing.expect(ctx.saw_main);
}
