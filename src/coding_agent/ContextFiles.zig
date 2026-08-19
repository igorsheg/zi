const std = @import("std");
const BoundedTextFile = @import("BoundedTextFile.zig");
const ZiPaths = @import("ZiPaths.zig");

const ContextFiles = @This();
// Candidate precedence and broad-to-narrow inheritance follow pi's context-file contract.
const candidate_names = [_][]const u8{
    "AGENTS.md",
    "AGENTS.MD",
    "CLAUDE.md",
    "CLAUDE.MD",
};
// These match fx's bounded defaults for project instruction files and their aggregate.
const max_file_bytes = 64 * 1024;
const max_total_bytes = 128 * 1024;
const max_context_files = 128;
const max_ancestor_directories = 1024;

pub const Section = struct {
    path: []const u8,
    text: []const u8,
};

pub const Error = error{
    OutOfMemory,
    Cancelled,
    ContextFileTooLarge,
    ContextFilesTooLarge,
    TooManyContextFiles,
    ContextTraversalTooDeep,
    InvalidContextFile,
    UnsafeContextFile,
    ContextFileReadFailed,
};

arena: std.heap.ArenaAllocator,
section_values: []const Section,

pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    paths: *const ZiPaths,
) Error!ContextFiles {
    return loadWithin(allocator, io, paths, null);
}

fn loadWithin(
    allocator: std.mem.Allocator,
    io: std.Io,
    paths: *const ZiPaths,
    ancestor_root: ?[]const u8,
) Error!ContextFiles {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const owned = arena.allocator();
    var collected_sections: std.ArrayList(Section) = .empty;
    var total_bytes: usize = 0;

    if (try loadFromDirectory(owned, io, paths.global_agent)) |section| {
        try appendUnique(owned, &collected_sections, &total_bytes, section);
    }

    var ancestors: std.ArrayList([]const u8) = .empty;
    var current = paths.cwd;
    while (true) {
        if (ancestors.items.len >= max_ancestor_directories) return error.ContextTraversalTooDeep;
        try ancestors.append(owned, current);
        if (ancestor_root) |root| {
            if (std.mem.eql(u8, current, root)) break;
        }
        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        current = parent;
    }
    var index = ancestors.items.len;
    while (index > 0) {
        index -= 1;
        if (try loadFromDirectory(owned, io, ancestors.items[index])) |section| {
            try appendUnique(owned, &collected_sections, &total_bytes, section);
        }
    }

    const section_values = try collected_sections.toOwnedSlice(owned);
    return .{
        .arena = arena,
        .section_values = section_values,
    };
}

pub fn deinit(self: *ContextFiles) void {
    self.arena.deinit();
    self.* = undefined;
}

pub fn sections(self: *const ContextFiles) []const Section {
    return self.section_values;
}

fn loadFromDirectory(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory_path: []const u8,
) Error!?Section {
    const directory = std.Io.Dir.openDirAbsolute(io, directory_path, .{}) catch |failure| {
        return switch (failure) {
            error.FileNotFound => null,
            error.Canceled => error.Cancelled,
            else => error.ContextFileReadFailed,
        };
    };
    defer directory.close(io);
    for (candidate_names) |file_name| {
        const outcome = try BoundedTextFile.loadOptional(
            allocator,
            io,
            directory,
            file_name,
            max_file_bytes,
        );
        switch (outcome) {
            .missing => continue,
            .loaded => |text| {
                const path = try std.fs.path.resolve(allocator, &.{ directory_path, file_name });
                if (path.len > ZiPaths.max_path_bytes) return error.ContextFileReadFailed;
                return .{ .path = path, .text = text };
            },
            .too_large => return error.ContextFileTooLarge,
            .invalid => return error.InvalidContextFile,
            .unsafe => return error.UnsafeContextFile,
            .unreadable => return error.ContextFileReadFailed,
        }
    }
    return null;
}

fn appendUnique(
    allocator: std.mem.Allocator,
    collected_sections: *std.ArrayList(Section),
    total_bytes: *usize,
    section: Section,
) Error!void {
    for (collected_sections.items) |existing| {
        if (std.mem.eql(u8, existing.path, section.path)) return;
    }
    if (collected_sections.items.len >= max_context_files) return error.TooManyContextFiles;
    if (section.text.len > max_total_bytes - total_bytes.*) return error.ContextFilesTooLarge;
    total_bytes.* += section.text.len;
    try collected_sections.append(allocator, section);
}

fn temporaryPath(temporary: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
    const length = try temporary.dir.realPath(std.testing.io, buffer);
    return buffer[0..length];
}

fn pathInRoot(root: []const u8, parts: []const []const u8) ![]u8 {
    var all_parts: std.ArrayList([]const u8) = .empty;
    defer all_parts.deinit(std.testing.allocator);
    try all_parts.append(std.testing.allocator, root);
    try all_parts.appendSlice(std.testing.allocator, parts);
    return std.fs.path.resolve(std.testing.allocator, all_parts.items);
}

test "context files own global and broad-to-narrow ancestor instructions" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, ".zi/agent");
    try temporary.dir.createDirPath(std.testing.io, "workspace/project/sub");
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".zi/agent/AGENTS.md",
        .data = "Global instructions.",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "workspace/CLAUDE.md",
        .data = "Workspace instructions.",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "workspace/project/AGENTS.md",
        .data = "Project instructions.",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "workspace/project/CLAUDE.md",
        .data = "Shadowed Claude instructions.",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "workspace/project/sub/AGENTS.MD",
        .data = "Subdirectory instructions.",
    });
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try temporaryPath(&temporary, &root_buffer);
    const cwd = try pathInRoot(root, &.{ "workspace", "project", "sub" });
    defer std.testing.allocator.free(cwd);
    var paths = try ZiPaths.init(std.testing.allocator, cwd, root);
    defer paths.deinit();

    var context = try loadWithin(std.testing.allocator, std.testing.io, &paths, root);
    defer context.deinit();
    const loaded = context.sections();
    try std.testing.expectEqual(@as(usize, 4), loaded.len);
    try std.testing.expectEqualStrings("Global instructions.", loaded[0].text);
    try std.testing.expect(std.mem.endsWith(u8, loaded[0].path, "/.zi/agent/AGENTS.md"));
    try std.testing.expectEqualStrings("Workspace instructions.", loaded[1].text);
    try std.testing.expectEqualStrings("Project instructions.", loaded[2].text);
    try std.testing.expectEqualStrings("Subdirectory instructions.", loaded[3].text);
}

test "context files distinguish missing sources" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try temporaryPath(&temporary, &root_buffer);
    var paths = try ZiPaths.init(std.testing.allocator, root, root);
    defer paths.deinit();

    var context = try loadWithin(std.testing.allocator, std.testing.io, &paths, root);
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.sections().len);
}

test "context files reject invalid excessive and unsafe sources" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try temporaryPath(&temporary, &root_buffer);
    var paths = try ZiPaths.init(std.testing.allocator, root, root);
    defer paths.deinit();

    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "AGENTS.md",
        .data = "invalid\x00context",
    });
    try std.testing.expectError(
        error.InvalidContextFile,
        loadWithin(std.testing.allocator, std.testing.io, &paths, root),
    );

    const oversized = try std.testing.allocator.alloc(u8, max_file_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "AGENTS.md",
        .data = oversized,
    });
    try std.testing.expectError(
        error.ContextFileTooLarge,
        loadWithin(std.testing.allocator, std.testing.io, &paths, root),
    );

    try temporary.dir.deleteFile(std.testing.io, "AGENTS.md");
    try temporary.dir.createDir(std.testing.io, "AGENTS.md", .default_dir);
    try std.testing.expectError(
        error.UnsafeContextFile,
        loadWithin(std.testing.allocator, std.testing.io, &paths, root),
    );
}

test "context files bound aggregate ancestor instructions" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "one/two");
    const content = try std.testing.allocator.alloc(u8, 48 * 1024);
    defer std.testing.allocator.free(content);
    @memset(content, 'x');
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "AGENTS.md", .data = content });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "one/AGENTS.md", .data = content });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "one/two/AGENTS.md", .data = content });
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try temporaryPath(&temporary, &root_buffer);
    const cwd = try pathInRoot(root, &.{ "one", "two" });
    defer std.testing.allocator.free(cwd);
    var paths = try ZiPaths.init(std.testing.allocator, cwd, root);
    defer paths.deinit();

    try std.testing.expectError(
        error.ContextFilesTooLarge,
        loadWithin(std.testing.allocator, std.testing.io, &paths, root),
    );
}

const AllocationContext = struct {
    paths: *const ZiPaths,
    ancestor_root: []const u8,
};

fn loadAndDeinit(allocator: std.mem.Allocator, context: *AllocationContext) !void {
    var files = try loadWithin(allocator, std.testing.io, context.paths, context.ancestor_root);
    files.deinit();
}

test "context files settle every allocation failure" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, ".zi/agent");
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".zi/agent/AGENTS.md",
        .data = "Global instructions.",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "AGENTS.md",
        .data = "Project instructions.",
    });
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try temporaryPath(&temporary, &root_buffer);
    var paths = try ZiPaths.init(std.testing.allocator, root, root);
    defer paths.deinit();
    var context: AllocationContext = .{ .paths = &paths, .ancestor_root = root };

    try std.testing.checkAllAllocationFailures(std.testing.allocator, loadAndDeinit, .{&context});
}
