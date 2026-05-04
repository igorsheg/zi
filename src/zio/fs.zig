const std = @import("std");

/// Low-level filesystem helpers for Zig 0.16 `std.Io`.
///
/// Higher-level storage modules own product paths and persistence policy; this
/// module only centralizes byte-level file operations so callsites do not
/// repeatedly hand-roll reader/writer setup, sentinel realpath handling, and
/// atomic writes.
pub fn readFileAlloc(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    limit: std.Io.Limit,
) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false });
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    return try reader.interface.allocRemaining(allocator, limit);
}

pub fn writeFileTruncate(
    io: std.Io,
    path: []const u8,
    bytes: []const u8,
) !void {
    if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

pub fn writeFileAtomic(
    io: std.Io,
    path: []const u8,
    bytes: []const u8,
    permissions: std.Io.File.Permissions,
) !void {
    if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
    var atomic_file = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .permissions = permissions, .replace = true });
    defer atomic_file.deinit(io);
    var buf: [4096]u8 = undefined;
    var writer = atomic_file.file.writer(io, &buf);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
    try atomic_file.finish(io);
}

pub fn appendFile(
    io: std.Io,
    path: []const u8,
    bytes: []const u8,
) !void {
    if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write, .allow_directory = false });
    defer file.close(io);
    const stat = try file.stat(io);
    try file.writePositionalAll(io, bytes, stat.size);
}

/// Returns a normal non-sentinel owned slice. Some std.Io realpath APIs return
/// sentinel-terminated allocations whose exact allocation length differs from
/// `slice.len`; duplicating avoids allocator/free mismatches at storage edges.
pub fn realPathOwned(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) ![]u8 {
    const real_z = try std.Io.Dir.realPathFileAbsoluteAlloc(io, path, allocator);
    defer allocator.free(real_z);
    return try allocator.dupe(u8, real_z);
}
