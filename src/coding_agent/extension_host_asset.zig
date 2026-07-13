const std = @import("std");
const generated = @import("extension_host_digest");
const paths_mod = @import("paths.zig");

pub const max_bytes: usize = 8 * 1024 * 1024;
const cache_scan_entries_max: usize = 1024;
const embedded = @embedFile("extension_host_bundle");
pub const bytes: []const u8 = embedded;
pub export const zi_extension_host_bundle = embedded.*;
pub const digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = generated.digest;

pub const Lease = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    lock_file: std.Io.File,
    locked: bool,

    pub fn deinit(self: *Lease) void {
        if (self.locked) self.lock_file.unlock(self.io);
        self.lock_file.close(self.io);
        self.allocator.free(self.path);
        self.* = undefined;
    }
};

pub fn digestHex() [digest.len * 2]u8 {
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn materialize(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    paths: paths_mod.PersistencePaths,
) !Lease {
    if (bytes.len > max_bytes) return error.AssetTooLarge;
    const digest_hex = digestHex();
    const version_dir = try paths.extensionHostVersionDir(allocator, &digest_hex);
    defer allocator.free(version_dir);
    const bundle_path = try paths.extensionHostBundlePath(allocator, &digest_hex);
    errdefer allocator.free(bundle_path);
    const lease_path = try paths.extensionHostLeasePath(allocator, &digest_hex);
    defer allocator.free(lease_path);

    _ = try dir.createDirPathStatus(io, version_dir, userDirPermissions());
    var lock_file = try dir.createFile(io, lease_path, .{
        .read = true,
        .truncate = false,
        .permissions = userFilePermissions(),
    });
    errdefer lock_file.close(io);
    var locks_supported = true;
    lock_file.lock(io, .shared) catch |err| switch (err) {
        error.FileLocksUnsupported => locks_supported = false,
        else => return err,
    };
    var lock_held = locks_supported;
    errdefer if (lock_held) lock_file.unlock(io);

    if (!try verifiedFile(io, dir, bundle_path)) {
        if (locks_supported) {
            lock_file.unlock(io);
            lock_held = false;
            try lock_file.lock(io, .exclusive);
            lock_held = true;
        }
        if (!try verifiedFile(io, dir, bundle_path)) {
            try publishVerified(allocator, io, dir, bundle_path);
        }
        if (!try verifiedFile(io, dir, bundle_path)) return error.AssetVerificationFailed;
        if (locks_supported) try lock_file.downgradeLock(io);
    }
    if (locks_supported) {
        // Cache cleanup is best effort; the verified current asset remains usable.
        // ziglint-ignore: Z026 eviction failure is diagnostic-only by policy.
        evictInactiveVersions(allocator, io, dir, paths, &digest_hex) catch {};
    }

    return .{
        .allocator = allocator,
        .io = io,
        .path = bundle_path,
        .lock_file = lock_file,
        .locked = locks_supported,
    };
}

fn verifiedFile(io: std.Io, dir: std.Io.Dir, path: []const u8) !bool {
    var file = dir.openFile(io, path, .{ .allow_directory = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size != bytes.len) return false;

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (offset < stat.size) {
        const remaining: usize = @intCast(@min(stat.size - offset, buffer.len));
        const read_len = try file.readPositionalAll(io, buffer[0..remaining], offset);
        if (read_len != remaining) return false;
        hasher.update(buffer[0..read_len]);
        offset += read_len;
    }
    var actual: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&actual);
    return std.mem.eql(u8, &actual, &digest);
}

fn publishVerified(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    bundle_path: []const u8,
) !void {
    const parent = std.fs.path.dirname(bundle_path) orelse return error.InvalidAssetPath;
    const stamp = std.Io.Timestamp.now(io, .awake).nanoseconds;
    var attempt: usize = 0;
    while (attempt < 64) : (attempt += 1) {
        const temp_name = try std.fmt.allocPrint(allocator, ".extension-host-{d}-{d}.tmp", .{ stamp, attempt });
        defer allocator.free(temp_name);
        const temp_path = try std.fs.path.join(allocator, &.{ parent, temp_name });
        defer allocator.free(temp_path);
        var file = dir.createFile(io, temp_path, .{
            .read = true,
            .exclusive = true,
            .permissions = userFilePermissions(),
        }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        var open = true;
        defer if (open) file.close(io);
        // ziglint-ignore: Z026 cleanup must not replace the publication error.
        errdefer dir.deleteFile(io, temp_path) catch {};
        try file.writeStreamingAll(io, bytes);
        try file.sync(io);
        try file.setPermissions(io, readOnlyFilePermissions());
        file.close(io);
        open = false;
        try std.Io.Dir.rename(dir, temp_path, dir, bundle_path, io);
        return;
    }
    return error.PathAlreadyExists;
}

fn evictInactiveVersions(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    paths: paths_mod.PersistencePaths,
    current_digest_hex: []const u8,
) !void {
    const cache_path = try paths.extensionHostCacheDir(allocator);
    defer allocator.free(cache_path);
    var cache_dir = try dir.openDir(io, cache_path, .{ .iterate = true });
    defer cache_dir.close(io);
    var iterator = cache_dir.iterate();
    var scanned: usize = 0;
    while (scanned < cache_scan_entries_max) : (scanned += 1) {
        const entry = try iterator.next(io) orelse break;
        if (entry.kind != .directory or !validDigestDirectory(entry.name)) continue;
        if (std.mem.eql(u8, entry.name, current_digest_hex)) continue;

        const lease_path = try paths.extensionHostLeasePath(allocator, entry.name);
        defer allocator.free(lease_path);
        var lock_file = dir.createFile(io, lease_path, .{
            .read = true,
            .truncate = false,
            .lock = .exclusive,
            .lock_nonblocking = true,
            .permissions = userFilePermissions(),
        }) catch |err| switch (err) {
            error.WouldBlock, error.FileLocksUnsupported => continue,
            else => return err,
        };
        const version_path = try paths.extensionHostVersionDir(allocator, entry.name);
        defer allocator.free(version_path);
        dir.deleteTree(io, version_path) catch {
            lock_file.close(io);
            continue;
        };
        lock_file.close(io);
        // ziglint-ignore: Z026 stale empty lock files are harmless.
        dir.deleteFile(io, lease_path) catch {};
    }
}

fn validDigestDirectory(name: []const u8) bool {
    if (name.len != digest.len * 2) return false;
    for (name) |char| if (!std.ascii.isHex(char)) return false;
    return true;
}

fn userDirPermissions() std.Io.File.Permissions {
    if (std.Io.File.Permissions.has_executable_bit) return .fromMode(0o700);
    return .default_dir;
}

fn userFilePermissions() std.Io.File.Permissions {
    if (std.Io.File.Permissions.has_executable_bit) return .fromMode(0o600);
    return .default_file;
}

fn readOnlyFilePermissions() std.Io.File.Permissions {
    if (std.Io.File.Permissions.has_executable_bit) return .fromMode(0o400);
    return std.Io.File.Permissions.default_file.setReadOnly(true);
}

test "embedded extension host has a matching SHA-256 digest" {
    try std.testing.expect(bytes.len > 0);
    try std.testing.expect(bytes.len <= max_bytes);
    try std.testing.expect(std.mem.startsWith(u8, bytes, "// Zi extension host protocol 1.0"));

    var actual: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &actual, .{});
    try std.testing.expectEqualSlices(u8, &digest, &actual);
}

test "materialization evicts an inactive derived host version" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const paths: paths_mod.PersistencePaths = .{ .global_dir = "agent", .cwd = "repo" };
    const old_digest = "0000000000000000000000000000000000000000000000000000000000000000";
    const old_dir = try paths.extensionHostVersionDir(std.testing.allocator, old_digest);
    defer std.testing.allocator.free(old_dir);
    try tmp.dir.createDirPath(std.testing.io, old_dir);
    const old_bundle = try paths.extensionHostBundlePath(std.testing.allocator, old_digest);
    defer std.testing.allocator.free(old_bundle);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = old_bundle, .data = "old" });

    var lease = try materialize(std.testing.allocator, std.testing.io, tmp.dir, paths);
    defer lease.deinit();
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, old_dir, .{}));
}

test "materialization permits concurrent leases of one verified asset" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const paths: paths_mod.PersistencePaths = .{ .global_dir = "agent", .cwd = "repo" };

    var first = try materialize(std.testing.allocator, std.testing.io, tmp.dir, paths);
    defer first.deinit();
    var second = try materialize(std.testing.allocator, std.testing.io, tmp.dir, paths);
    defer second.deinit();
    try std.testing.expectEqualStrings(first.path, second.path);
}

test "materialization verifies and repairs the embedded host" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const paths: paths_mod.PersistencePaths = .{ .global_dir = "agent", .cwd = "repo" };

    var lease = try materialize(std.testing.allocator, std.testing.io, tmp.dir, paths);
    const owned_path = try std.testing.allocator.dupe(u8, lease.path);
    defer std.testing.allocator.free(owned_path);
    lease.deinit();

    try std.testing.expect(try verifiedFile(std.testing.io, tmp.dir, owned_path));
    var corrupt_file = try tmp.dir.openFile(std.testing.io, owned_path, .{});
    try corrupt_file.setPermissions(std.testing.io, userFilePermissions());
    corrupt_file.close(std.testing.io);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = owned_path, .data = "corrupt" });
    try std.testing.expect(!try verifiedFile(std.testing.io, tmp.dir, owned_path));

    var repaired = try materialize(std.testing.allocator, std.testing.io, tmp.dir, paths);
    defer repaired.deinit();
    try std.testing.expectEqualStrings(owned_path, repaired.path);
    try std.testing.expect(try verifiedFile(std.testing.io, tmp.dir, repaired.path));
}
