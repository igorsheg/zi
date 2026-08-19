const std = @import("std");
const BoundedTextFile = @import("BoundedTextFile.zig");
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

pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    paths: *const ZiPaths,
    requested: Requested,
) Error!PromptFiles {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const owned = arena.allocator();
    const directory = std.Io.Dir.openDirAbsolute(io, paths.global_agent, .{}) catch |failure| {
        return switch (failure) {
            error.FileNotFound => .{
                .arena = arena,
                .system_text = null,
                .append_text = null,
            },
            error.Canceled => error.Cancelled,
            else => error.PromptFileReadFailed,
        };
    };
    defer directory.close(io);
    const system_text = if (requested.system)
        try loadOptionalText(owned, io, directory, system_file_name)
    else
        null;
    const append_text = if (requested.append)
        try loadOptionalText(owned, io, directory, append_file_name)
    else
        null;
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
    });
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

    var files = try load(std.testing.allocator, std.testing.io, &paths, .{ .append = true });
    defer files.deinit();
    try std.testing.expect(files.system() == null);
    try std.testing.expect(files.append() == null);
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
        load(std.testing.allocator, std.testing.io, &paths, .{ .system = true }),
    );
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".zi/agent/SYSTEM.md",
        .data = "invalid\x00text",
    });
    try std.testing.expectError(
        error.InvalidPromptFile,
        load(std.testing.allocator, std.testing.io, &paths, .{ .system = true }),
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
        load(std.testing.allocator, std.testing.io, &paths, .{ .system = true }),
    );

    try temporary.dir.deleteFile(std.testing.io, ".zi/agent/SYSTEM.md");
    try temporary.dir.createDir(std.testing.io, ".zi/agent/SYSTEM.md", .default_dir);
    try std.testing.expectError(
        error.UnsafePromptFile,
        load(std.testing.allocator, std.testing.io, &paths, .{ .system = true }),
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
        load(std.testing.allocator, std.testing.io, &paths, .{ .system = true }),
    );
}

const AllocationContext = struct {
    paths: *const ZiPaths,
};

fn loadAndDeinit(allocator: std.mem.Allocator, context: *AllocationContext) !void {
    var files = try load(allocator, std.testing.io, context.paths, .{
        .system = true,
        .append = true,
    });
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
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var paths = try testPaths(&temporary, &root_buffer);
    defer paths.deinit();
    var context: AllocationContext = .{ .paths = &paths };

    try std.testing.checkAllAllocationFailures(std.testing.allocator, loadAndDeinit, .{&context});
}
