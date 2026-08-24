const std = @import("std");
const agent = @import("agent/root.zig");

/// Process-level POSIX implementation of agent discovery's secure-open seam.
pub const Posix = struct {
    pub fn capability(self: *Posix) agent.SecureOpen.Capability {
        return agent.SecureOpen.Capability.from(self);
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
};
