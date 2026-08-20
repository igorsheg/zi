const std = @import("std");
const BoundedTextFile = @import("BoundedTextFile.zig");
const ProjectTrust = @import("ProjectTrust.zig");
const ZiPaths = @import("ZiPaths.zig");

const PromptFiles = @This();
const system_file_name = "SYSTEM.md";
const append_file_name = "APPEND_SYSTEM.md";
const max_file_bytes = 1024 * 1024;

pub const Requested = struct {
    system: bool = false,
    append: bool = false,
};

pub const Error = error{
    OutOfMemory,
    Cancelled,
    PromptFileTooLarge,
    InvalidPromptFile,
    UnsafePromptFile,
    PromptFileReadFailed,
};

arena: std.heap.ArenaAllocator,
system_text: ?[]const u8,
append_text: ?[]const u8,

pub fn hasProjectSources(
    io: std.Io,
    paths: *const ZiPaths,
    requested: Requested,
) Error!bool {
    const directory = std.Io.Dir.openDirAbsolute(io, paths.project, .{
        .follow_symlinks = false,
    }) catch |failure| return switch (failure) {
        error.FileNotFound => false,
        error.Canceled => error.Cancelled,
        error.NotDir, error.SymLinkLoop => true,
        else => true,
    };
    defer directory.close(io);
    if (requested.system and try sourceExists(io, directory, system_file_name)) return true;
    if (requested.append and try sourceExists(io, directory, append_file_name)) return true;
    return false;
}

pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    paths: *const ZiPaths,
    requested: Requested,
    project_trust: ProjectTrust.Decision,
) Error!PromptFiles {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const owned = arena.allocator();

    const project_directory: ?std.Io.Dir = if (project_trust == .trusted)
        try openOptionalDirectory(io, paths.project, false)
    else
        null;
    defer if (project_directory) |directory| directory.close(io);
    var system_text: ?[]const u8 = if (requested.system and project_directory != null)
        try loadOptionalText(owned, io, project_directory.?, system_file_name)
    else
        null;
    var append_text: ?[]const u8 = if (requested.append and project_directory != null)
        try loadOptionalText(owned, io, project_directory.?, append_file_name)
    else
        null;

    const needs_global_system = requested.system and system_text == null;
    const needs_global_append = requested.append and append_text == null;
    if (needs_global_system or needs_global_append) {
        const global_directory = try openOptionalDirectory(io, paths.global_agent, true);
        if (global_directory) |directory| {
            defer directory.close(io);
            if (needs_global_system) {
                system_text = try loadOptionalText(owned, io, directory, system_file_name);
            }
            if (needs_global_append) {
                append_text = try loadOptionalText(owned, io, directory, append_file_name);
            }
        }
    }
    return .{
        .arena = arena,
        .system_text = system_text,
        .append_text = append_text,
    };
}

pub fn deinit(self: *PromptFiles) void {
    self.arena.deinit();
    self.* = undefined;
}

pub fn system(self: *const PromptFiles) ?[]const u8 {
    return self.system_text;
}

pub fn append(self: *const PromptFiles) ?[]const u8 {
    return self.append_text;
}

fn openOptionalDirectory(
    io: std.Io,
    path: []const u8,
    follow_symlinks: bool,
) Error!?std.Io.Dir {
    return std.Io.Dir.openDirAbsolute(io, path, .{ .follow_symlinks = follow_symlinks }) catch |failure| {
        return switch (failure) {
            error.FileNotFound => null,
            error.Canceled => error.Cancelled,
            error.NotDir, error.SymLinkLoop => error.UnsafePromptFile,
            else => error.PromptFileReadFailed,
        };
    };
}

fn sourceExists(io: std.Io, directory: std.Io.Dir, path: []const u8) Error!bool {
    const file = directory.openFile(io, path, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
    }) catch |failure| return switch (failure) {
        error.FileNotFound => false,
        error.Canceled => error.Cancelled,
        else => true,
    };
    file.close(io);
    return true;
}

fn loadOptionalText(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    file_name: []const u8,
) Error!?[]const u8 {
    const outcome = try BoundedTextFile.loadOptional(
        allocator,
        io,
        directory,
        file_name,
        max_file_bytes,
    );
    return switch (outcome) {
        .missing => null,
        .loaded => |text| text,
        .too_large => error.PromptFileTooLarge,
        .invalid => error.InvalidPromptFile,
        .unsafe => error.UnsafePromptFile,
        .unreadable => error.PromptFileReadFailed,
    };
}

fn temporaryPath(temporary: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
    const length = try temporary.dir.realPath(std.testing.io, buffer);
    return buffer[0..length];
}

fn testPaths(temporary: *std.testing.TmpDir, buffer: []u8) !ZiPaths {
    const root = try temporaryPath(temporary, buffer);
    return ZiPaths.init(std.testing.allocator, root, root);
}

test "prompt files load requested global text and own its bytes" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, ".zi/agent");
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".zi/agent/SYSTEM.md",
        .data = "Global base.",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".zi/agent/APPEND_SYSTEM.md",
        .data = "Global rules.",
    });
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var paths = try testPaths(&temporary, &root_buffer);
    defer paths.deinit();

    var files = try load(std.testing.allocator, std.testing.io, &paths, .{
        .system = true,
        .append = true,
    }, .untrusted);
    defer files.deinit();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".zi/agent/SYSTEM.md",
        .data = "Changed.",
    });

    try std.testing.expectEqualStrings("Global base.", files.system().?);
    try std.testing.expectEqualStrings("Global rules.", files.append().?);
}

test "prompt files distinguish absent and unrequested sources" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, ".zi/agent");
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".zi/agent/SYSTEM.md",
        .data = "Ignored base.",
    });
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var paths = try testPaths(&temporary, &root_buffer);
    defer paths.deinit();

    var files = try load(std.testing.allocator, std.testing.io, &paths, .{ .append = true }, .untrusted);
    defer files.deinit();
    try std.testing.expect(files.system() == null);
    try std.testing.expect(files.append() == null);
}

test "project prompt source detection is role-aware and treats unsafe roots as present" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(std.testing.io, ".zi", .default_dir);
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".zi/SYSTEM.md",
        .data = "Project base.",
    });
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var paths = try testPaths(&temporary, &root_buffer);
    defer paths.deinit();
    try std.testing.expect(try hasProjectSources(std.testing.io, &paths, .{ .system = true }));
    try std.testing.expect(!try hasProjectSources(std.testing.io, &paths, .{ .append = true }));

    try temporary.dir.deleteTree(std.testing.io, ".zi");
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = ".zi", .data = "unsafe" });
    try std.testing.expect(try hasProjectSources(std.testing.io, &paths, .{ .system = true }));
}

test "trusted project prompt files shadow global sources independently" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, ".zi/agent");
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".zi/agent/SYSTEM.md",
        .data = "Global base.",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".zi/agent/APPEND_SYSTEM.md",
        .data = "Global rules.",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".zi/SYSTEM.md",
        .data = "Project base.",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".zi/APPEND_SYSTEM.md",
        .data = "Project rules.",
    });
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var paths = try testPaths(&temporary, &root_buffer);
    defer paths.deinit();

    var project = try load(std.testing.allocator, std.testing.io, &paths, .{
        .system = true,
        .append = true,
    }, .trusted);
    try std.testing.expectEqualStrings("Project base.", project.system().?);
    try std.testing.expectEqualStrings("Project rules.", project.append().?);
    project.deinit();

    try temporary.dir.deleteFile(std.testing.io, ".zi/APPEND_SYSTEM.md");
    var partial = try load(std.testing.allocator, std.testing.io, &paths, .{
        .system = true,
        .append = true,
    }, .trusted);
    try std.testing.expectEqualStrings("Project base.", partial.system().?);
    try std.testing.expectEqualStrings("Global rules.", partial.append().?);
    partial.deinit();

    try temporary.dir.deleteFile(std.testing.io, ".zi/SYSTEM.md");
    try temporary.dir.createDir(std.testing.io, ".zi/SYSTEM.md", .default_dir);
    var untrusted = try load(std.testing.allocator, std.testing.io, &paths, .{
        .system = true,
        .append = true,
    }, .untrusted);
    defer untrusted.deinit();
    try std.testing.expectEqualStrings("Global base.", untrusted.system().?);
    try std.testing.expectEqualStrings("Global rules.", untrusted.append().?);
}

test "trusted project prompt files prevent reads from shadowed global sources" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, ".zi/agent/SYSTEM.md");
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".zi/SYSTEM.md",
        .data = "Project base.",
    });
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var paths = try testPaths(&temporary, &root_buffer);
    defer paths.deinit();

    var files = try load(
        std.testing.allocator,
        std.testing.io,
        &paths,
        .{ .system = true },
        .trusted,
    );
    defer files.deinit();
    try std.testing.expectEqualStrings("Project base.", files.system().?);
}

test "trusted project prompt files reject a linked project configuration root" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "home/.zi/agent");
    try temporary.dir.createDir(std.testing.io, "workspace", .default_dir);
    try temporary.dir.createDir(std.testing.io, "outside", .default_dir);
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.zi/agent/SYSTEM.md",
        .data = "Global base.",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "outside/SYSTEM.md",
        .data = "Linked project base.",
    });
    try temporary.dir.symLink(
        std.testing.io,
        "../outside",
        "workspace/.zi",
        .{ .is_directory = true },
    );
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try temporaryPath(&temporary, &root_buffer);
    const cwd = try std.fs.path.resolve(std.testing.allocator, &.{ root, "workspace" });
    defer std.testing.allocator.free(cwd);
    const home = try std.fs.path.resolve(std.testing.allocator, &.{ root, "home" });
    defer std.testing.allocator.free(home);
    var paths = try ZiPaths.init(std.testing.allocator, cwd, home);
    defer paths.deinit();

    try std.testing.expectError(
        error.UnsafePromptFile,
        load(std.testing.allocator, std.testing.io, &paths, .{ .system = true }, .trusted),
    );
    var untrusted = try load(
        std.testing.allocator,
        std.testing.io,
        &paths,
        .{ .system = true },
        .untrusted,
    );
    defer untrusted.deinit();
    try std.testing.expectEqualStrings("Global base.", untrusted.system().?);
}

test "prompt files reject invalid excessive and non-regular sources" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, ".zi/agent");
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var paths = try testPaths(&temporary, &root_buffer);
    defer paths.deinit();

    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".zi/agent/SYSTEM.md",
        .data = "invalid\xff",
    });
    try std.testing.expectError(
        error.InvalidPromptFile,
        load(std.testing.allocator, std.testing.io, &paths, .{ .system = true }, .untrusted),
    );
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".zi/agent/SYSTEM.md",
        .data = "invalid\x00text",
    });
    try std.testing.expectError(
        error.InvalidPromptFile,
        load(std.testing.allocator, std.testing.io, &paths, .{ .system = true }, .untrusted),
    );

    const oversized = try std.testing.allocator.alloc(u8, max_file_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".zi/agent/SYSTEM.md",
        .data = oversized,
    });
    try std.testing.expectError(
        error.PromptFileTooLarge,
        load(std.testing.allocator, std.testing.io, &paths, .{ .system = true }, .untrusted),
    );

    try temporary.dir.deleteFile(std.testing.io, ".zi/agent/SYSTEM.md");
    try temporary.dir.createDir(std.testing.io, ".zi/agent/SYSTEM.md", .default_dir);
    try std.testing.expectError(
        error.UnsafePromptFile,
        load(std.testing.allocator, std.testing.io, &paths, .{ .system = true }, .untrusted),
    );

    try temporary.dir.deleteTree(std.testing.io, ".zi/agent/SYSTEM.md");
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".zi/agent/target.md",
        .data = "Linked base.",
    });
    try temporary.dir.symLink(
        std.testing.io,
        "target.md",
        ".zi/agent/SYSTEM.md",
        .{},
    );
    try std.testing.expectError(
        error.UnsafePromptFile,
        load(std.testing.allocator, std.testing.io, &paths, .{ .system = true }, .untrusted),
    );
}

const AllocationContext = struct {
    paths: *const ZiPaths,
};

fn loadAndDeinit(allocator: std.mem.Allocator, context: *AllocationContext) !void {
    var files = try load(allocator, std.testing.io, context.paths, .{
        .system = true,
        .append = true,
    }, .trusted);
    files.deinit();
}

test "prompt files settle every allocation failure" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, ".zi/agent");
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".zi/agent/SYSTEM.md",
        .data = "Global base.",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".zi/agent/APPEND_SYSTEM.md",
        .data = "Global rules.",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".zi/SYSTEM.md",
        .data = "Project base.",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".zi/APPEND_SYSTEM.md",
        .data = "Project rules.",
    });
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var paths = try testPaths(&temporary, &root_buffer);
    defer paths.deinit();
    var context: AllocationContext = .{ .paths = &paths };

    try std.testing.checkAllAllocationFailures(std.testing.allocator, loadAndDeinit, .{&context});
}
