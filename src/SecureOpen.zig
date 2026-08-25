const std = @import("std");
const agent = @import("agent/root.zig");
const config = @import("config/root.zig");

/// Process-level POSIX implementation of the agent and config secure-open seams.
pub const Posix = struct {
    pub fn capability(self: *Posix) agent.SecureOpen.Capability {
        return self.agentCapability();
    }

    pub fn agentCapability(self: *Posix) agent.SecureOpen.Capability {
        return agent.SecureOpen.Capability.from(self);
    }

    pub fn configCapability(self: *Posix) config.SecureOpen.Capability {
        return config.SecureOpen.Capability.from(self);
    }

    pub fn openFile(
        _: *Posix,
        _: std.Io,
        directory: std.Io.Dir,
        name: []const u8,
    ) std.posix.OpenError!std.Io.File {
        const handle = try std.posix.openat(directory.handle, name, .{
            .ACCMODE = .RDONLY,
            .NONBLOCK = true,
            .CLOEXEC = true,
            .NOFOLLOW = true,
        }, 0);
        return .{ .handle = handle, .flags = .{ .nonblocking = true } };
    }

    pub fn statAbsolute(
        _: *Posix,
        io: std.Io,
        path: []const u8,
    ) config.SecureOpen.Error!std.Io.File.Stat {
        if (!absolutePathValid(path)) return error.InvalidPath;
        return std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err|
            return mapConfigError(err);
    }

    pub fn openAbsolute(
        _: *Posix,
        _: std.Io,
        path: []const u8,
    ) config.SecureOpen.Error!std.Io.File {
        if (!absolutePathValid(path)) return error.InvalidPath;
        const handle = std.posix.openat(std.posix.AT.FDCWD, path, .{
            .ACCMODE = .RDONLY,
            .NONBLOCK = true,
            .CLOEXEC = true,
            .NOFOLLOW = true,
        }, 0) catch |err| return mapConfigError(err);
        return .{ .handle = handle, .flags = .{ .nonblocking = true } };
    }
};

fn absolutePathValid(path: []const u8) bool {
    return path.len != 0 and path[0] == '/' and std.mem.indexOfScalar(u8, path, 0) == null;
}

fn mapConfigError(err: anyerror) config.SecureOpen.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.FileNotFound => error.FileNotFound,
        error.AccessDenied, error.PermissionDenied => error.Unreadable,
        error.NameTooLong, error.BadPathName, error.InvalidUtf8 => error.InvalidPath,
        else => error.Failed,
    };
}

extern "c" fn mkfifo(path: [*:0]const u8, mode: c_uint) c_int;

test "config adapter rejects symlink open and opens FIFO without blocking" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "target", .data = "x" });
    try tmp.dir.symLink(std.testing.io, "target", "link", .{});
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    const link = try std.fs.path.join(std.testing.allocator, &.{ base, "link" });
    defer std.testing.allocator.free(link);
    const fifo = try std.fs.path.join(std.testing.allocator, &.{ base, "fifo" });
    defer std.testing.allocator.free(fifo);
    const fifo_z = try std.testing.allocator.dupeZ(u8, fifo);
    defer std.testing.allocator.free(fifo_z);
    try std.testing.expectEqual(@as(c_int, 0), mkfifo(fifo_z.ptr, 0o600));

    var implementation: Posix = .{};
    const capability = implementation.configCapability();
    const link_stat = try capability.statFile(std.testing.io, link);
    try std.testing.expect(link_stat.kind == .sym_link);
    try std.testing.expectError(error.Failed, capability.openFile(std.testing.io, link));

    const fifo_stat = try capability.statFile(std.testing.io, fifo);
    try std.testing.expect(fifo_stat.kind == .named_pipe);
    const file = try capability.openFile(std.testing.io, fifo);
    defer file.close(std.testing.io);
    const opened_stat = try file.stat(std.testing.io);
    try std.testing.expect(opened_stat.kind == .named_pipe);
}
