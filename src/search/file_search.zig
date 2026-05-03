const std = @import("std");
const path_search = @import("path.zig");
const file_ignore = @import("file_ignore.zig");

pub const Candidate = struct {
    relative_path: []const u8,
    is_directory: bool,
};

pub const Options = struct {
    base_dir: []const u8,
    query: []const u8 = "",
    max_results: usize = 300,
    include_files: bool = true,
    include_dirs: bool = true,
    include_hidden: bool = true,
    exclude_git: bool = true,
    read_gitignore: bool = true,
    max_depth: usize = 64,
};

pub const Session = struct {
    shared: *Shared,
    thread: std.Thread,

    const Shared = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        options: Options,
        mutex: std.Io.Mutex = .init,
        results: std.ArrayList(Candidate) = .empty,
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    };

    pub fn start(allocator: std.mem.Allocator, io: std.Io, options: Options) !Session {
        const shared = try allocator.create(Shared);
        shared.* = .{ .allocator = allocator, .io = io, .options = options };
        errdefer allocator.destroy(shared);

        const thread = try std.Thread.spawn(.{}, workerMain, .{shared});
        return .{ .shared = shared, .thread = thread };
    }

    pub fn cancel(self: *Session) void {
        self.shared.cancelled.store(true, .release);
    }

    pub fn done(self: *const Session) bool {
        return self.shared.done.load(.acquire);
    }

    pub fn drain(self: *Session, allocator: std.mem.Allocator, out: *std.ArrayList(Candidate)) !void {
        self.shared.mutex.lockUncancelable(self.shared.io);
        defer self.shared.mutex.unlock(self.shared.io);
        for (self.shared.results.items) |candidate| {
            try out.append(allocator, candidate);
        }
        self.shared.results.clearRetainingCapacity();
    }

    pub fn deinit(self: *Session) void {
        self.cancel();
        self.thread.join();
        self.shared.results.deinit(self.shared.allocator);
        self.shared.allocator.destroy(self.shared);
        self.* = undefined;
    }

    fn workerMain(shared: *Shared) void {
        searchToShared(shared) catch {
            shared.failed.store(true, .release);
        };
        shared.done.store(true, .release);
    }
};

pub fn search(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    out: *std.ArrayList(Candidate),
) !void {
    var cancelled = std.atomic.Value(bool).init(false);
    try searchCancellable(allocator, io, options, &cancelled, out);
}

fn searchCancellable(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    cancelled: *const std.atomic.Value(bool),
    out: *std.ArrayList(Candidate),
) !void {
    var root = try std.Io.Dir.openDirAbsolute(io, options.base_dir, .{ .iterate = true });
    defer root.close(io);

    try searchDirCancellable(allocator, io, root, options, cancelled, out);
}

fn searchToShared(shared: *Session.Shared) !void {
    var root = try std.Io.Dir.openDirAbsolute(shared.io, shared.options.base_dir, .{ .iterate = true });
    defer root.close(shared.io);

    var ignore_stack = file_ignore.Stack{};
    defer ignore_stack.deinit(shared.allocator);
    if (shared.options.read_gitignore) {
        _ = try ignore_stack.tryPushDir(shared.allocator, shared.io, root, "");
    }
    try walkDirShared(shared, root, "", 0, &ignore_stack);
}

pub fn searchDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    options: Options,
    out: *std.ArrayList(Candidate),
) !void {
    var cancelled = std.atomic.Value(bool).init(false);
    try searchDirCancellable(allocator, io, root, options, &cancelled, out);
}

fn searchDirCancellable(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    options: Options,
    cancelled: *const std.atomic.Value(bool),
    out: *std.ArrayList(Candidate),
) !void {
    var ignore_stack = file_ignore.Stack{};
    defer ignore_stack.deinit(allocator);
    if (options.read_gitignore) {
        _ = try ignore_stack.tryPushDir(allocator, io, root, "");
    }
    try walkDir(allocator, io, root, "", 0, options, cancelled, &ignore_stack, out);
}

fn walkDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    rel_dir: []const u8,
    depth: usize,
    options: Options,
    cancelled: *const std.atomic.Value(bool),
    ignore_stack: *file_ignore.Stack,
    out: *std.ArrayList(Candidate),
) !void {
    if (cancelled.load(.acquire)) return;
    if (out.items.len >= options.max_results) return;
    if (depth > options.max_depth) return;

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (cancelled.load(.monotonic)) return;
        if (out.items.len >= options.max_results) return;
        if (entry.name.len == 0) continue;
        if (options.exclude_git and std.mem.eql(u8, entry.name, ".git")) continue;
        if (!options.include_hidden and entry.name[0] == '.') continue;

        var is_directory = entry.kind == .directory;
        if (!is_directory and entry.kind == .sym_link) {
            const stat: ?std.Io.File.Stat = dir.statFile(io, entry.name, .{}) catch null;
            if (stat) |value| is_directory = value.kind == .directory;
        }

        const rel_path = try joinRel(allocator, rel_dir, entry.name);
        if (ignore_stack.shouldIgnore(rel_path, is_directory)) continue;
        const include = if (is_directory) options.include_dirs else options.include_files;
        if (include and matches(options.query, rel_path, is_directory)) {
            try out.append(allocator, .{ .relative_path = rel_path, .is_directory = is_directory });
        }

        if (is_directory and out.items.len < options.max_results) {
            var child = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
            defer child.close(io);
            const mark = ignore_stack.mark();
            defer ignore_stack.popTo(allocator, mark);
            if (options.read_gitignore) _ = ignore_stack.tryPushDir(allocator, io, child, rel_path) catch false;
            try walkDir(allocator, io, child, rel_path, depth + 1, options, cancelled, ignore_stack, out);
        }
    }
}

fn walkDirShared(
    shared: *Session.Shared,
    dir: std.Io.Dir,
    rel_dir: []const u8,
    depth: usize,
    ignore_stack: *file_ignore.Stack,
) !void {
    const options = shared.options;
    if (shared.cancelled.load(.acquire)) return;
    if (depth > options.max_depth) return;

    var iter = dir.iterate();
    while (try iter.next(shared.io)) |entry| {
        if (shared.cancelled.load(.monotonic)) return;
        if (entry.name.len == 0) continue;
        if (options.exclude_git and std.mem.eql(u8, entry.name, ".git")) continue;
        if (!options.include_hidden and entry.name[0] == '.') continue;

        var is_directory = entry.kind == .directory;
        if (!is_directory and entry.kind == .sym_link) {
            const stat: ?std.Io.File.Stat = dir.statFile(shared.io, entry.name, .{}) catch null;
            if (stat) |value| is_directory = value.kind == .directory;
        }

        const rel_path = try joinRel(shared.allocator, rel_dir, entry.name);
        if (ignore_stack.shouldIgnore(rel_path, is_directory)) continue;

        const include = if (is_directory) options.include_dirs else options.include_files;
        if (include and matches(options.query, rel_path, is_directory)) {
            shared.mutex.lockUncancelable(shared.io);
            const can_append = shared.results.items.len < options.max_results;
            if (can_append) try shared.results.append(shared.allocator, .{ .relative_path = rel_path, .is_directory = is_directory });
            shared.mutex.unlock(shared.io);
            if (!can_append) return;
        }

        if (is_directory) {
            var child = dir.openDir(shared.io, entry.name, .{ .iterate = true }) catch continue;
            defer child.close(shared.io);
            const mark = ignore_stack.mark();
            defer ignore_stack.popTo(shared.allocator, mark);
            if (options.read_gitignore) _ = ignore_stack.tryPushDir(shared.allocator, shared.io, child, rel_path) catch false;
            try walkDirShared(shared, child, rel_path, depth + 1, ignore_stack);
        }
    }
}

fn matches(query: []const u8, rel_path: []const u8, is_directory: bool) bool {
    const trimmed = std.mem.trim(u8, query, " \t\r\n");
    if (trimmed.len == 0) return true;
    const m = path_search.rankWithOptions(trimmed, rel_path, .{});
    if (!m.matches) return false;
    _ = is_directory;
    return true;
}

fn joinRel(allocator: std.mem.Allocator, rel_dir: []const u8, name: []const u8) ![]const u8 {
    if (rel_dir.len == 0) return try allocator.dupe(u8, name);
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ rel_dir, name });
}


test "native file search excludes git and includes hidden" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    try tmp.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".env", .data = "" });
    try tmp.dir.createDir(io, ".git", .default_dir);
    var git = try tmp.dir.openDir(io, ".git", .{});
    defer git.close(io);
    try git.writeFile(io, .{ .sub_path = "config", .data = "" });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var out = std.ArrayList(Candidate).empty;
    try searchDir(arena.allocator(), io, tmp.dir, .{ .base_dir = "" }, &out);

    var saw_main = false;
    var saw_hidden = false;
    for (out.items) |c| {
        if (std.mem.eql(u8, c.relative_path, "main.zig")) saw_main = true;
        if (std.mem.eql(u8, c.relative_path, ".env")) saw_hidden = true;
        try std.testing.expect(!std.mem.startsWith(u8, c.relative_path, ".git"));
    }
    try std.testing.expect(saw_main);
    try std.testing.expect(saw_hidden);
}

test "native file search honors root gitignore negation for scoped dirs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "serverless\n!/serverless\nnode_modules\n" });
    try tmp.dir.createDirPath(io, "serverless/p3-portal");
    try tmp.dir.writeFile(io, .{ .sub_path = "serverless/p3-portal/config.yml", .data = "" });
    try tmp.dir.createDirPath(io, "node_modules/@wix/p3-portal");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var out = std.ArrayList(Candidate).empty;
    try searchDir(arena.allocator(), io, tmp.dir, .{ .base_dir = "", .query = "p3-portal" }, &out);

    var saw_serverless_portal = false;
    for (out.items) |c| {
        if (std.mem.eql(u8, c.relative_path, "serverless/p3-portal")) saw_serverless_portal = true;
        try std.testing.expect(!std.mem.startsWith(u8, c.relative_path, "node_modules/"));
    }
    try std.testing.expect(saw_serverless_portal);
}
