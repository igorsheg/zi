const std = @import("std");

const read_buffer_bytes = 8192;

pub const Outcome = union(enum) {
    missing,
    loaded: []const u8,
    too_large,
    invalid,
    unsafe,
    unreadable,
};

pub const Error = error{
    OutOfMemory,
    Cancelled,
};

/// Loaded bytes belong to `allocator`.
pub fn loadOptional(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    file_name: []const u8,
    max_bytes: usize,
) Error!Outcome {
    const path_stat = directory.statFile(io, file_name, .{ .follow_symlinks = false }) catch |failure| {
        return switch (failure) {
            error.FileNotFound, error.NotDir => .missing,
            error.Canceled => error.Cancelled,
            else => .unreadable,
        };
    };
    if (path_stat.kind != .file) return .unsafe;
    if (path_stat.size > max_bytes) return .too_large;

    const file = directory.openFile(io, file_name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
    }) catch |failure| return switch (failure) {
        error.FileNotFound, error.NotDir => .missing,
        error.Canceled => error.Cancelled,
        error.SymLinkLoop, error.IsDir => .unsafe,
        else => .unreadable,
    };
    defer file.close(io);
    const opened_stat = file.stat(io) catch return .unreadable;
    if (opened_stat.kind != .file) return .unsafe;
    if (opened_stat.size > max_bytes) return .too_large;

    const read_limit = std.math.add(usize, max_bytes, 1) catch return .too_large;
    var read_buffer: [read_buffer_bytes]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    const text = reader.interface.allocRemaining(
        allocator,
        .limited(read_limit),
    ) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => .too_large,
        else => .unreadable,
    };
    if (text.len > max_bytes) {
        allocator.free(text);
        return .too_large;
    }
    if (!std.unicode.utf8ValidateSlice(text) or std.mem.findScalar(u8, text, 0) != null) {
        allocator.free(text);
        return .invalid;
    }
    return .{ .loaded = text };
}

test "bounded text files classify optional external text" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    try std.testing.expect(try loadOptional(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        "missing.md",
        16,
    ) == .missing);

    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "context.md",
        .data = "context",
    });
    const loaded = try loadOptional(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        "context.md",
        16,
    );
    defer std.testing.allocator.free(loaded.loaded);
    try std.testing.expectEqualStrings("context", loaded.loaded);

    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "context.md",
        .data = "invalid\xff",
    });
    try std.testing.expect(try loadOptional(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        "context.md",
        16,
    ) == .invalid);

    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "context.md",
        .data = "seventeen bytes!!",
    });
    try std.testing.expect(try loadOptional(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        "context.md",
        16,
    ) == .too_large);

    try temporary.dir.deleteFile(std.testing.io, "context.md");
    try temporary.dir.createDir(std.testing.io, "context.md", .default_dir);
    try std.testing.expect(try loadOptional(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        "context.md",
        16,
    ) == .unsafe);
}

fn loadAndFree(allocator: std.mem.Allocator, directory: std.Io.Dir) !void {
    const outcome = try loadOptional(allocator, std.testing.io, directory, "context.md", 16);
    switch (outcome) {
        .loaded => |text| allocator.free(text),
        else => return error.UnexpectedOutcome,
    }
}

test "bounded text files settle every allocation failure" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "context.md",
        .data = "context",
    });

    try std.testing.checkAllAllocationFailures(std.testing.allocator, loadAndFree, .{temporary.dir});
}
