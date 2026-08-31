const std = @import("std");
const c = @cImport({
    @cInclude("sys/stat.h");
});

pub const Identity = struct {
    device: u64,
    inode: std.Io.File.INode,

    pub fn eql(a: Identity, b: Identity) bool {
        return a.device == b.device and a.inode == b.inode;
    }
};

pub fn opened(file: std.Io.File) error{IoFailure}!Identity {
    var native: c.struct_stat = undefined;
    if (c.fstat(file.handle, &native) != 0) return error.IoFailure;
    return .{
        .device = @intCast(native.st_dev),
        .inode = @intCast(native.st_ino),
    };
}

/// Opens the final component without following a symlink, then obtains device
/// and inode from that handle. The returned identity describes one named-path
/// observation and does not retain the descriptor.
pub fn named(io: std.Io, path: []const u8) error{IoFailure}!Identity {
    const file = std.Io.Dir.openFile(.cwd(), io, path, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
    }) catch return error.IoFailure;
    defer file.close(io);
    return opened(file);
}

test "identity compares device and inode" {
    const first: Identity = .{ .device = 1, .inode = 7 };
    try std.testing.expect(first.eql(.{ .device = 1, .inode = 7 }));
    try std.testing.expect(!first.eql(.{ .device = 2, .inode = 7 }));
    try std.testing.expect(!first.eql(.{ .device = 1, .inode = 8 }));
}
