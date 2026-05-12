const std = @import("std");
const builtin = @import("builtin");

pub const ReadOnlyBytesOptions = struct {
    max_bytes: usize,
    mmap_threshold: usize = 256 * 1024,
    prefer_mmap: bool = true,
};

pub const MappedFile = struct {
    bytes: []align(std.heap.page_size_min) const u8,

    pub fn deinit(self: *MappedFile) void {
        if (self.bytes.len != 0) std.posix.munmap(@constCast(self.bytes));
        self.bytes = &.{};
    }
};

pub const ReadOnlyBytes = union(enum) {
    mapped: MappedFile,
    allocated: []u8,

    pub fn bytes(self: *const ReadOnlyBytes) []const u8 {
        return switch (self.*) {
            .mapped => |m| m.bytes,
            .allocated => |b| b,
        };
    }

    pub fn deinit(self: *ReadOnlyBytes, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .mapped => |*m| m.deinit(),
            .allocated => |b| allocator.free(b),
        }
        self.* = .{ .allocated = &.{} };
    }
};

pub fn readFileAlloc(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    limit: std.Io.Limit,
) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false });
    defer file.close(io);
    return try readFileAllocFromFile(io, allocator, file, limit);
}

pub fn readOnlyBytes(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    opts: ReadOnlyBytesOptions,
) !ReadOnlyBytes {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false });
    defer file.close(io);

    const stat = try file.stat(io);
    if (stat.kind == .directory) return error.IsDir;
    if (stat.size > opts.max_bytes) return error.FileTooBig;
    if (stat.size == 0) return .{ .allocated = try allocator.alloc(u8, 0) };

    if (opts.prefer_mmap and stat.size >= opts.mmap_threshold) {
        if (mapFileReadOnly(file, stat.size)) |mapped| return .{ .mapped = mapped } else |_| {}
    }

    return .{ .allocated = try readFileAllocFromFile(io, allocator, file, .limited(opts.max_bytes)) };
}

fn readFileAllocFromFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    file: std.Io.File,
    limit: std.Io.Limit,
) ![]u8 {
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    return try reader.interface.allocRemaining(allocator, limit);
}

fn mapFileReadOnly(file: std.Io.File, size: u64) !MappedFile {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.Unsupported;
    const len: usize = std.math.cast(usize, size) orelse return error.FileTooBig;
    const mapped = try std.posix.mmap(
        null,
        len,
        .{ .READ = true },
        .{ .TYPE = .PRIVATE },
        file.handle,
        0,
    );
    return .{ .bytes = mapped };
}

test "readOnlyBytes maps larger files and falls back for small files" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "small.txt", .data = "abc" });
    const small_path = try tmp.dir.realPathFileAlloc(std.Options.debug_io, "small.txt", testing.allocator);
    defer testing.allocator.free(small_path);
    var small = try readOnlyBytes(std.Options.debug_io, testing.allocator, small_path, .{ .max_bytes = 1024, .mmap_threshold = 1024 });
    defer small.deinit(testing.allocator);
    try testing.expectEqualStrings("abc", small.bytes());
    try testing.expect(small == .allocated);

    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "mapped.txt", .data = "abcdef" });
    const mapped_path = try tmp.dir.realPathFileAlloc(std.Options.debug_io, "mapped.txt", testing.allocator);
    defer testing.allocator.free(mapped_path);
    var mapped = try readOnlyBytes(std.Options.debug_io, testing.allocator, mapped_path, .{ .max_bytes = 1024, .mmap_threshold = 1 });
    defer mapped.deinit(testing.allocator);
    try testing.expectEqualStrings("abcdef", mapped.bytes());
    if (builtin.os.tag != .windows and builtin.os.tag != .wasi) {
        try testing.expect(mapped == .mapped);
    }
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
    const file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write, .allow_directory = false }) catch |err| switch (err) {
        error.FileNotFound => try std.Io.Dir.cwd().createFile(io, path, .{}),
        else => return err,
    };
    defer file.close(io);
    const stat = try file.stat(io);
    try file.writePositionalAll(io, bytes, stat.size);
}

pub fn realPathOwned(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) ![]u8 {
    const real_z = try std.Io.Dir.realPathFileAbsoluteAlloc(io, path, allocator);
    defer allocator.free(real_z);
    return try allocator.dupe(u8, real_z);
}
