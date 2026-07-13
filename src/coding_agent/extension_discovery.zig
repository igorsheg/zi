const std = @import("std");
const ExtensionHost = @import("ExtensionHost.zig");
const paths_mod = @import("paths.zig");

pub const directory_entries_scanned_max: usize = 1024;

pub const Options = struct {
    paths: paths_mod.PersistencePaths,
    dir: std.Io.Dir = .cwd(),
    project_trusted: bool = false,
    explicit_paths: []const []const u8 = &.{},
};

pub fn discover(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
) !?ExtensionHost.ExtensionLoadPlan {
    var builder: PlanBuilder = .{ .allocator = allocator, .io = io, .dir = options.dir };
    defer builder.deinit();

    const global_dir = try options.paths.globalExtensionsDir(allocator);
    defer allocator.free(global_dir);
    try builder.appendDirectory(global_dir, .global);

    if (options.project_trusted) {
        const project_dir = try options.paths.projectExtensionsDir(allocator);
        defer allocator.free(project_dir);
        try builder.appendDirectory(project_dir, .project);
    }

    for (options.explicit_paths) |path| try builder.appendPath(path, .explicit);
    if (builder.len == 0) return null;
    const plan = try ExtensionHost.ExtensionLoadPlan.init(allocator, builder.specs[0..builder.len]);
    return plan;
}

pub fn hasProjectExtensions(
    allocator: std.mem.Allocator,
    io: std.Io,
    paths: paths_mod.PersistencePaths,
    dir: std.Io.Dir,
) !bool {
    const project_dir = try paths.projectExtensionsDir(allocator);
    defer allocator.free(project_dir);
    return directoryHasCandidate(allocator, io, dir, project_dir);
}

const PlanBuilder = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    specs: [ExtensionHost.load_plan_entries_max]ExtensionHost.ExtensionSpec = undefined,
    owned_paths: [ExtensionHost.load_plan_entries_max]?[:0]u8 = @splat(null),
    len: usize = 0,

    fn deinit(self: *PlanBuilder) void {
        for (self.owned_paths[0..self.len]) |maybe_path| {
            if (maybe_path) |path| self.allocator.free(path);
        }
        self.* = undefined;
    }

    fn appendDirectory(self: *PlanBuilder, path: []const u8, provenance: ExtensionHost.Provenance) !void {
        var candidates = try collectDirectoryCandidates(self.allocator, self.io, self.dir, path);
        defer candidates.deinit(self.allocator);
        std.mem.sort([]const u8, candidates.items, {}, stringLessThan);
        for (candidates.items) |candidate| try self.appendPath(candidate, provenance);
    }

    fn appendPath(self: *PlanBuilder, path: []const u8, provenance: ExtensionHost.Provenance) !void {
        const canonical = if (std.fs.path.isAbsolute(path))
            try std.Io.Dir.realPathFileAbsoluteAlloc(self.io, path, self.allocator)
        else
            try self.dir.realPathFileAlloc(self.io, path, self.allocator);
        errdefer self.allocator.free(canonical);
        for (self.specs[0..self.len]) |spec| {
            if (std.mem.eql(u8, spec.canonical_path, canonical)) {
                self.allocator.free(canonical);
                return;
            }
        }
        if (self.len == self.specs.len) return error.TooManyExtensions;
        self.owned_paths[self.len] = canonical;
        self.specs[self.len] = .{ .canonical_path = canonical, .provenance = provenance };
        self.len += 1;
    }
};

const CandidateList = struct {
    items: [][]const u8,

    fn deinit(self: *CandidateList, allocator: std.mem.Allocator) void {
        for (self.items) |item| allocator.free(item);
        if (self.items.len != 0) allocator.free(self.items);
        self.* = undefined;
    }
};

fn collectDirectoryCandidates(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    path: []const u8,
) !CandidateList {
    var dir = root_dir.openDir(io, path, .{ .iterate = true, .access_sub_paths = true }) catch |err| switch (err) {
        error.FileNotFound => return .{ .items = &.{} },
        else => return err,
    };
    defer dir.close(io);

    var candidates = std.ArrayList([]const u8).empty;
    errdefer {
        for (candidates.items) |candidate| allocator.free(candidate);
        candidates.deinit(allocator);
    }
    var scanned: usize = 0;
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        scanned += 1;
        if (scanned > directory_entries_scanned_max) return error.TooManyExtensionDirectoryEntries;
        const candidate = switch (entry.kind) {
            .file => if (isTypeScriptFile(entry.name))
                try std.fs.path.join(allocator, &.{ path, entry.name })
            else
                continue,
            .directory => candidate: {
                const index_path = try std.fs.path.join(
                    allocator,
                    &.{ entry.name, paths_mod.extension_entry_file_name },
                );
                defer allocator.free(index_path);
                dir.access(io, index_path, .{}) catch continue;
                break :candidate try std.fs.path.join(allocator, &.{ path, index_path });
            },
            .sym_link => candidate: {
                if (isTypeScriptFile(entry.name)) {
                    break :candidate try std.fs.path.join(allocator, &.{ path, entry.name });
                }
                const index_path = try std.fs.path.join(
                    allocator,
                    &.{ entry.name, paths_mod.extension_entry_file_name },
                );
                defer allocator.free(index_path);
                dir.access(io, index_path, .{}) catch continue;
                break :candidate try std.fs.path.join(allocator, &.{ path, index_path });
            },
            else => continue,
        };
        if (candidates.items.len == ExtensionHost.load_plan_entries_max) {
            allocator.free(candidate);
            return error.TooManyExtensions;
        }
        candidates.append(allocator, candidate) catch |err| {
            allocator.free(candidate);
            return err;
        };
    }
    return .{ .items = try candidates.toOwnedSlice(allocator) };
}

fn directoryHasCandidate(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    path: []const u8,
) !bool {
    var dir = root_dir.openDir(io, path, .{ .iterate = true, .access_sub_paths = true }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer dir.close(io);

    var scanned: usize = 0;
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        scanned += 1;
        if (scanned > directory_entries_scanned_max) return error.TooManyExtensionDirectoryEntries;
        switch (entry.kind) {
            .file => if (isTypeScriptFile(entry.name)) return true,
            .directory => {
                const index_path = try std.fs.path.join(
                    allocator,
                    &.{ entry.name, paths_mod.extension_entry_file_name },
                );
                defer allocator.free(index_path);
                dir.access(io, index_path, .{}) catch continue;
                return true;
            },
            .sym_link => {
                if (isTypeScriptFile(entry.name)) return true;
                const index_path = try std.fs.path.join(
                    allocator,
                    &.{ entry.name, paths_mod.extension_entry_file_name },
                );
                defer allocator.free(index_path);
                dir.access(io, index_path, .{}) catch continue;
                return true;
            },
            else => {},
        }
    }
    return false;
}

fn isTypeScriptFile(name: []const u8) bool {
    return name.len > paths_mod.extension_file_suffix.len and
        std.mem.endsWith(u8, name, paths_mod.extension_file_suffix) and
        !std.mem.endsWith(u8, name, paths_mod.extension_declaration_file_suffix);
}

fn stringLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

test "discovery orders global project and explicit entries and deduplicates canonical paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "agent/extensions/pkg");
    try tmp.dir.createDirPath(std.testing.io, "repo/.zi/extensions");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "agent/extensions/z.ts", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "agent/extensions/a.ts", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "agent/extensions/pkg/index.ts", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "agent/extensions/ignored.js", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "agent/extensions/types.d.ts", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/.zi/extensions/project.ts", .data = "" });

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPathFile(std.testing.io, ".", &root_buffer);
    const explicit = try std.fs.path.join(
        std.testing.allocator,
        &.{ root_buffer[0..root_len], "agent/extensions/a.ts" },
    );
    defer std.testing.allocator.free(explicit);
    var plan = (try discover(std.testing.allocator, std.testing.io, .{
        .paths = .{ .global_dir = "agent", .cwd = "repo" },
        .dir = tmp.dir,
        .project_trusted = true,
        .explicit_paths = &.{explicit},
    })).?;
    defer plan.deinit();

    try std.testing.expectEqual(@as(usize, 4), plan.entries.len);
    try std.testing.expect(std.mem.endsWith(u8, plan.entries[0].canonical_path, "agent/extensions/a.ts"));
    try std.testing.expect(std.mem.endsWith(u8, plan.entries[1].canonical_path, "agent/extensions/pkg/index.ts"));
    try std.testing.expect(std.mem.endsWith(u8, plan.entries[2].canonical_path, "agent/extensions/z.ts"));
    try std.testing.expectEqual(ExtensionHost.Provenance.project, plan.entries[3].provenance);
}

test "discovery ignores untrusted project extensions and returns null when empty" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "repo/.zi/extensions");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/.zi/extensions/project.ts", .data = "" });

    const paths: paths_mod.PersistencePaths = .{ .global_dir = "agent", .cwd = "repo" };
    try std.testing.expect(try hasProjectExtensions(std.testing.allocator, std.testing.io, paths, tmp.dir));
    try std.testing.expect((try discover(std.testing.allocator, std.testing.io, .{
        .paths = paths,
        .dir = tmp.dir,
        .project_trusted = false,
    })) == null);
}
