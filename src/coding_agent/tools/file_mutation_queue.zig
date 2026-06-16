//! Single owner gate for file mutations performed by builtin tools.
//!
//! `write` and `edit` both enter here before replacing a file. The queue is a
//! synchronous critical section today because tool execution already gives us a
//! bounded owner loop; the important product invariant is one mutation path,
//! one serialization point, and atomic replacement behind it.
const std = @import("std");
const builtin = @import("builtin");
const agent = @import("../../agent/root.zig");
const file_writer = @import("file_writer.zig");

pub const FileMutationQueue = struct {
    mutex: std.Io.Mutex = .init,

    pub const Options = struct {
        create_parent_dirs: bool = false,
    };

    pub fn atomicWriteFileStreamingUpdates(
        self: *FileMutationQueue,
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
        content: []const u8,
        on_update: ?agent.AgentToolUpdateCallback,
        options: Options,
    ) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        if (options.create_parent_dirs) try ensureParentDir(io, path);
        try file_writer.atomicWriteFileStreamingUpdates(allocator, io, path, content, on_update);
    }
};

fn ensureParentDir(io: std.Io, path: []const u8) !void {
    const dir_path = std.fs.path.dirname(path) orelse return;
    var dir = std.Io.Dir.openDir(.cwd(), io, dir_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try std.Io.Dir.createDirPath(.cwd(), io, dir_path);
            return;
        },
        else => return err,
    };
    dir.close(io);
}

test "file mutation queue writes through atomic replacement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPathFile(std.testing.io, ".", &root_buffer);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/file.txt", .{root_buffer[0..root_len]});
    defer std.testing.allocator.free(path);

    var queue: FileMutationQueue = .{};
    try queue.atomicWriteFileStreamingUpdates(std.testing.allocator, std.testing.io, path, "ok", null, .{});

    const written = try tmp.dir.readFileAlloc(std.testing.io, "file.txt", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings("ok", written);
}

test "file mutation queue creates parent directories under the mutation guard" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPathFile(std.testing.io, ".", &root_buffer);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/dir/file.txt", .{root_buffer[0..root_len]});
    defer std.testing.allocator.free(path);

    var queue: FileMutationQueue = .{};
    try queue.atomicWriteFileStreamingUpdates(std.testing.allocator, std.testing.io, path, "ok", null, .{
        .create_parent_dirs = true,
    });

    const written = try tmp.dir.readFileAlloc(std.testing.io, "dir/file.txt", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings("ok", written);
}

test "file mutation queue accepts symlink parent directories" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "target");
    try tmp.dir.symLink(std.testing.io, "target", "link", .{});

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPathFile(std.testing.io, ".", &root_buffer);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/link/file.txt", .{root_buffer[0..root_len]});
    defer std.testing.allocator.free(path);

    var queue: FileMutationQueue = .{};
    try queue.atomicWriteFileStreamingUpdates(std.testing.allocator, std.testing.io, path, "ok", null, .{
        .create_parent_dirs = true,
    });

    const written = try tmp.dir.readFileAlloc(std.testing.io, "target/file.txt", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings("ok", written);
}
