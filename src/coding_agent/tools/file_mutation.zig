const std = @import("std");

pub fn atomicWrite(path: []const u8, content: []const u8, permissions: ?std.Io.File.Permissions) !void {
    if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, parent);
    var atomic_file = try std.Io.Dir.cwd().createFileAtomic(std.Options.debug_io, path, .{ .permissions = permissions orelse .fromMode(0o666), .replace = true });
    defer atomic_file.deinit(std.Options.debug_io);
    var buf: [4096]u8 = undefined;
    var writer = atomic_file.file.writer(std.Options.debug_io, &buf);
    try writer.interface.writeAll(content);
    try writer.interface.flush();
    try atomic_file.file.sync(std.Options.debug_io);
    try atomic_file.replace(std.Options.debug_io);
}

pub fn statPermissions(path: []const u8) ?std.Io.File.Permissions {
    const stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, path, .{}) catch return null;
    return stat.permissions;
}
