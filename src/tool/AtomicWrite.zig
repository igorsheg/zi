const std = @import("std");
const builtin = @import("builtin");
const text = @import("../text/root.zig");

const maximum_symlink_hops: usize = 32;
const read_buffer_bytes: usize = 8192;

pub const Options = struct {
    maximum_file_bytes: usize = 16 * 1024 * 1024,
    maximum_diff_bytes: usize = 1024 * 1024,
    maximum_path_bytes: usize = std.fs.max_path_bytes,
    expected_content: ?[]const u8 = null,
};

pub const Written = struct {
    diff: []u8,
    created: bool,
};

/// Runtime filesystem failures are ordinary, owned diagnostics. Only allocation
/// failure escapes `writeWithDiff`; callers can therefore pass diagnostics on to
/// a model without translating a large platform error set.
pub const Result = union(enum) {
    written: Written,
    diagnostic: []u8,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .written => |written| allocator.free(written.diff),
            .diagnostic => |diagnostic| allocator.free(diagnostic),
        }
        self.* = undefined;
    }
};

pub const Error = error{OutOfMemory};

const Target = struct {
    path: []u8,
    old_content: []u8,
    permissions: std.Io.File.Permissions = .default_file,
    identity: ?std.Io.File.Stat = null,
    existed: bool = false,

    fn deinit(self: *Target, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.old_content);
        self.* = undefined;
    }
};

/// Writes through the final symlink chain using a synced temporary file in the
/// destination directory, then atomically renames it into place. The returned
/// diff and every diagnostic are owned. No filesystem mutation occurs for an
/// unchanged file or until the bounded unified diff has been built.
///
/// Zig 0.16 std.Io cannot directory-sync after rename or atomically open only
/// regular files in nonblocking mode. Data is synced before rename, but parent
/// entries are not crash-durable; a final-component FIFO swap can still block
/// between the no-follow preflight and open. Identity is rechecked before the
/// unconditional atomic rename, whose final comparison race is also unavoidable.
pub fn writeWithDiff(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    content: []const u8,
    options: Options,
) Error!Result {
    return writeWithDiffAtPhysicalPathMax(
        allocator,
        io,
        path,
        content,
        options,
        std.fs.max_path_bytes,
    );
}

fn writeWithDiffAtPhysicalPathMax(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    content: []const u8,
    options: Options,
    physical_max_path_bytes: usize,
) Error!Result {
    if (path.len == 0) return diagnosticCopy(allocator, "cannot write an empty path");
    if (std.mem.findScalar(u8, path, 0) != null)
        return diagnosticCopy(allocator, "path contains a NUL byte");
    const maximum_path_bytes = pathPayloadCap(
        options.maximum_path_bytes,
        physical_max_path_bytes,
    );
    if (path.len > maximum_path_bytes) {
        return pathCapDiagnostic(allocator, path.len, maximum_path_bytes);
    }
    if (content.len > options.maximum_file_bytes) {
        return diagnosticFormat(
            allocator,
            "content is {d} bytes; write cap is {d}",
            .{ content.len, options.maximum_file_bytes },
        );
    }

    var expanded_path_length: ?usize = null;
    const target_path = resolveFinalSymlinksReportingLength(
        allocator,
        io,
        path,
        maximum_path_bytes,
        &expanded_path_length,
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (expanded_path_length) |length| {
            return pathCapDiagnostic(allocator, length, maximum_path_bytes);
        }
        return diagnosticFormat(
            allocator,
            "resolving {s}: {s}",
            .{ path, errorReason(err) },
        );
    };
    var target = inspectTarget(allocator, io, target_path, options.maximum_file_bytes) catch |err| {
        defer allocator.free(target_path);
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return switch (err) {
            error.NotRegular => try diagnosticFormat(
                allocator,
                "{s} exists but is not a regular file",
                .{target_path},
            ),
            error.StreamTooLong => try diagnosticFormat(
                allocator,
                "{s} exceeds the {d}-byte write cap",
                .{ target_path, options.maximum_file_bytes },
            ),
            else => try diagnosticFormat(
                allocator,
                "error reading {s}: {s}",
                .{ target_path, errorReason(err) },
            ),
        };
    };
    defer target.deinit(allocator);
    if (options.expected_content) |expected| {
        if (!target.existed or !std.mem.eql(u8, target.old_content, expected)) {
            return diagnosticFormat(
                allocator,
                "target {s} changed before write: refusing to replace it",
                .{target.path},
            );
        }
    }

    const old_label = try diffLabel(allocator, path, true, target.existed);
    defer allocator.free(old_label);
    const new_label = try diffLabel(allocator, path, false, target.existed);
    defer allocator.free(new_label);
    var diff = text.UnifiedDiff.make(
        allocator,
        target.old_content,
        content,
        old_label,
        new_label,
        options.maximum_diff_bytes,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ResultTooLarge => return diagnosticFormat(
            allocator,
            "diff for {s} exceeds the {d}-byte result cap",
            .{ path, options.maximum_diff_bytes },
        ),
    };
    var owns_diff = true;
    defer if (owns_diff) allocator.free(diff);
    if (!target.existed and diff.len == 0) {
        const visible_creation = try std.fmt.allocPrint(
            allocator,
            "--- /dev/null\n+++ {s}\n",
            .{new_label},
        );
        allocator.free(diff);
        diff = visible_creation;
        if (diff.len > options.maximum_diff_bytes) {
            const diagnostic = try diagnosticFormat(
                allocator,
                "diff for {s} exceeds the {d}-byte result cap",
                .{ path, options.maximum_diff_bytes },
            );
            return diagnostic;
        }
    }

    if (target.existed and std.mem.eql(u8, target.old_content, content)) {
        owns_diff = false;
        return .{ .written = .{ .diff = diff, .created = false } };
    }

    const parent = std.fs.path.dirname(target.path) orelse ".";
    std.Io.Dir.cwd().createDirPath(io, parent) catch |err| {
        return diagnosticFormat(
            allocator,
            "creating {s}: {s}",
            .{ parent, errorReason(err) },
        );
    };

    var atomic = std.Io.Dir.cwd().createFileAtomic(io, target.path, .{
        .permissions = target.permissions,
        .make_path = false,
        .replace = true,
    }) catch |err| {
        return diagnosticFormat(allocator, "creating temporary file: {s}", .{errorReason(err)});
    };
    // std.Io.Atomic owns best-effort temp deletion; its deinit cannot report cleanup failure.
    defer atomic.deinit(io);

    atomic.file.writeStreamingAll(io, content) catch |err| {
        return diagnosticFormat(allocator, "writing temporary file: {s}", .{errorReason(err)});
    };
    // Strict hax parity restores the complete mode, including set-ID bits. std.Io.Stat does
    // not expose owner/group, so atomic replacement preserves mode but not ownership metadata.
    // For a new file, leave the mode chosen by createFileAtomic after applying umask.
    if (target.existed) atomic.file.setPermissions(io, target.permissions) catch |err| {
        return diagnosticFormat(allocator, "setting temporary file mode: {s}", .{errorReason(err)});
    };
    atomic.file.sync(io) catch |err| {
        return diagnosticFormat(allocator, "syncing temporary file: {s}", .{errorReason(err)});
    };
    if (!targetIdentityUnchanged(io, &target)) {
        return diagnosticFormat(
            allocator,
            "target {s} changed while writing: refusing to replace it",
            .{target.path},
        );
    }
    // std.Io has no compare-and-rename operation; a final race after this check remains.
    atomic.replace(io) catch |err| {
        return diagnosticFormat(
            allocator,
            "renaming temporary file to {s}: {s}",
            .{ target.path, errorReason(err) },
        );
    };

    owns_diff = false;
    return .{ .written = .{ .diff = diff, .created = !target.existed } };
}

const InspectError = error{ OutOfMemory, NotRegular, StreamTooLong } ||
    std.Io.Dir.StatFileError || std.Io.File.OpenError || std.Io.File.StatError ||
    std.Io.File.Reader.Error;

fn inspectTarget(
    allocator: std.mem.Allocator,
    io: std.Io,
    owned_path: []u8,
    maximum_file_bytes: usize,
) InspectError!Target {
    var target: Target = .{
        .path = owned_path,
        .old_content = try allocator.alloc(u8, 0),
    };
    errdefer allocator.free(target.old_content);

    const path_stat = std.Io.Dir.cwd().statFile(io, owned_path, .{ .follow_symlinks = false }) catch |err| {
        if (err == error.FileNotFound) return target;
        return err;
    };
    if (path_stat.kind != .file) return error.NotRegular;

    const file = try std.Io.Dir.cwd().openFile(io, owned_path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.NotRegular;
    if (stat.size > maximum_file_bytes) return error.StreamTooLong;

    var reader_buffer: [read_buffer_bytes]u8 = undefined;
    var reader = file.reader(io, &reader_buffer);
    const limit = if (maximum_file_bytes == std.math.maxInt(usize))
        std.Io.Limit.unlimited
    else
        std.Io.Limit.limited(maximum_file_bytes + 1);
    const old_content = reader.interface.allocRemaining(allocator, limit) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return error.StreamTooLong,
        error.ReadFailed => return reader.err orelse error.InputOutput,
    };
    if (old_content.len > maximum_file_bytes) {
        allocator.free(old_content);
        return error.StreamTooLong;
    }
    allocator.free(target.old_content);
    target.old_content = old_content;
    target.permissions = stat.permissions;
    target.identity = stat;
    target.existed = true;
    return target;
}

fn targetIdentityUnchanged(io: std.Io, target: *const Target) bool {
    const current = std.Io.Dir.cwd().statFile(
        io,
        target.path,
        .{ .follow_symlinks = false },
    ) catch |err| return !target.existed and err == error.FileNotFound;
    const original = target.identity orelse return false;
    return current.kind == .file and current.inode == original.inode and
        current.size == original.size and std.meta.eql(current.mtime, original.mtime) and
        std.meta.eql(current.ctime, original.ctime);
}

const ResolveError = error{OutOfMemory} || std.Io.Dir.StatFileError || std.Io.Dir.ReadLinkError;

fn resolveFinalSymlinks(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    maximum_path_bytes: usize,
) ResolveError![]u8 {
    var path_too_long_length: ?usize = null;
    return resolveFinalSymlinksReportingLength(
        allocator,
        io,
        path,
        maximum_path_bytes,
        &path_too_long_length,
    );
}

fn resolveFinalSymlinksReportingLength(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    maximum_path_bytes: usize,
    path_too_long_length: *?usize,
) ResolveError![]u8 {
    path_too_long_length.* = null;
    if (path.len > maximum_path_bytes) {
        path_too_long_length.* = path.len;
        return error.NameTooLong;
    }
    var current = try allocator.dupe(u8, path);
    errdefer allocator.free(current);
    for (0..maximum_symlink_hops) |_| {
        const stat = std.Io.Dir.cwd().statFile(io, current, .{ .follow_symlinks = false }) catch |err| {
            if (err == error.FileNotFound) return current;
            return err;
        };
        if (stat.kind != .sym_link) return current;

        var target_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const target_length = try std.Io.Dir.cwd().readLink(io, current, &target_buffer);
        const link_target = target_buffer[0..target_length];
        const next = if (std.fs.path.isAbsolute(link_target))
            try allocator.dupe(u8, link_target)
        else
            try std.fs.path.join(
                allocator,
                &.{ std.fs.path.dirname(current) orelse ".", link_target },
            );
        if (next.len > maximum_path_bytes) {
            path_too_long_length.* = next.len;
            allocator.free(next);
            return error.NameTooLong;
        }
        allocator.free(current);
        current = next;
    }
    return error.SymLinkLoop;
}

fn diffLabel(
    allocator: std.mem.Allocator,
    path: []const u8,
    old: bool,
    existed: bool,
) error{OutOfMemory}![]u8 {
    if (old and !existed) return allocator.dupe(u8, "/dev/null");
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    return std.fmt.allocPrint(allocator, "{c}/{s}", .{ if (old) @as(u8, 'a') else 'b', path });
}

fn pathPayloadCap(configured_max_path_bytes: usize, physical_max_path_bytes: usize) usize {
    if (physical_max_path_bytes == 0) return 0;
    return @min(configured_max_path_bytes, physical_max_path_bytes - 1);
}

fn pathCapDiagnostic(
    allocator: std.mem.Allocator,
    path_length: usize,
    maximum_path_bytes: usize,
) error{OutOfMemory}!Result {
    return diagnosticFormat(
        allocator,
        "path is {d} bytes; path cap is {d}",
        .{ path_length, maximum_path_bytes },
    );
}

fn diagnosticCopy(allocator: std.mem.Allocator, message: []const u8) error{OutOfMemory}!Result {
    return .{ .diagnostic = try allocator.dupe(u8, message) };
}

fn diagnosticFormat(
    allocator: std.mem.Allocator,
    comptime format: []const u8,
    args: anytype,
) error{OutOfMemory}!Result {
    return .{ .diagnostic = try std.fmt.allocPrint(allocator, format, args) };
}

fn errorReason(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "No such file or directory",
        error.AccessDenied, error.PermissionDenied => "Permission denied",
        error.NotDir => "Not a directory",
        error.NameTooLong => "File name too long",
        error.SymLinkLoop => "Too many levels of symbolic links",
        error.InputOutput => "Input/output error",
        error.IsDir => "Is a directory",
        error.NoSpaceLeft => "No space left on device",
        error.ReadOnlyFileSystem => "Read-only file system",
        else => @errorName(err),
    };
}

fn testPath(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir, name: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, name });
}

fn writeTestFile(tmp: *std.testing.TmpDir, name: []const u8, bytes: []const u8) !void {
    const file = try tmp.dir.createFile(std.testing.io, name, .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, bytes);
}

fn readTestFile(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, name: []const u8) ![]u8 {
    return tmp.dir.readFileAlloc(std.testing.io, name, allocator, .unlimited);
}

test "create, replace, unchanged, parents, and modes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;

    const nested = try testPath(allocator, &tmp, "sub/deeper/file.txt");
    defer allocator.free(nested);
    var created = try writeWithDiff(allocator, std.testing.io, nested, "alpha\nbeta\n", .{});
    defer created.deinit(allocator);
    try std.testing.expect(created == .written);
    try std.testing.expect(created.written.created);
    try std.testing.expect(std.mem.startsWith(u8, created.written.diff, "--- /dev/null\n"));
    const initial = try readTestFile(allocator, &tmp, "sub/deeper/file.txt");
    defer allocator.free(initial);
    try std.testing.expectEqualStrings("alpha\nbeta\n", initial);

    const existing = try testPath(allocator, &tmp, "mode.txt");
    defer allocator.free(existing);
    try writeTestFile(&tmp, "mode.txt", "old\n");
    const old_file = try tmp.dir.openFile(std.testing.io, "mode.txt", .{ .mode = .read_write });
    try old_file.setPermissions(std.testing.io, @enumFromInt(0o750));
    const old_stat = try old_file.stat(std.testing.io);
    old_file.close(std.testing.io);

    var replaced = try writeWithDiff(allocator, std.testing.io, existing, "new\n", .{});
    defer replaced.deinit(allocator);
    try std.testing.expect(!replaced.written.created);
    try std.testing.expect(std.mem.indexOf(u8, replaced.written.diff, "-old\n+new\n") != null);
    const replaced_stat = try tmp.dir.statFile(std.testing.io, "mode.txt", .{});
    try std.testing.expectEqual(old_stat.permissions, replaced_stat.permissions);

    const inode = replaced_stat.inode;
    var unchanged = try writeWithDiff(allocator, std.testing.io, existing, "new\n", .{});
    defer unchanged.deinit(allocator);
    try std.testing.expectEqualStrings("", unchanged.written.diff);
    try std.testing.expectEqual(inode, (try tmp.dir.statFile(std.testing.io, "mode.txt", .{})).inode);
}

test "writes through existing and dangling relative symlink chains" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    try writeTestFile(&tmp, "real.txt", "old\n");
    try tmp.dir.symLink(std.testing.io, "real.txt", "middle", .{});
    try tmp.dir.symLink(std.testing.io, "middle", "link", .{});
    const link = try testPath(allocator, &tmp, "link");
    defer allocator.free(link);
    var through = try writeWithDiff(allocator, std.testing.io, link, "new\n", .{});
    defer through.deinit(allocator);
    const real = try readTestFile(allocator, &tmp, "real.txt");
    defer allocator.free(real);
    try std.testing.expectEqualStrings("new\n", real);
    try std.testing.expectEqual(.sym_link, (try tmp.dir.statFile(std.testing.io, "link", .{
        .follow_symlinks = false,
    })).kind);

    try tmp.dir.symLink(std.testing.io, "created.txt", "dangling", .{});
    const dangling = try testPath(allocator, &tmp, "dangling");
    defer allocator.free(dangling);
    var created = try writeWithDiff(allocator, std.testing.io, dangling, "hello\n", .{});
    defer created.deinit(allocator);
    try std.testing.expect(created.written.created);
    const content = try readTestFile(allocator, &tmp, "created.txt");
    defer allocator.free(content);
    try std.testing.expectEqualStrings("hello\n", content);
}

test "bounds and nonregular targets are diagnostics without replacement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const directory = try testPath(allocator, &tmp, "directory");
    defer allocator.free(directory);
    try tmp.dir.createDir(std.testing.io, "directory", .default_dir);
    var nonregular = try writeWithDiff(allocator, std.testing.io, directory, "x", .{});
    defer nonregular.deinit(allocator);
    try std.testing.expect(nonregular == .diagnostic);
    try std.testing.expect(std.mem.indexOf(u8, nonregular.diagnostic, "not a regular file") != null);

    const bounded = try testPath(allocator, &tmp, "bounded");
    defer allocator.free(bounded);
    var too_large = try writeWithDiff(allocator, std.testing.io, bounded, "12345", .{
        .maximum_file_bytes = 4,
    });
    defer too_large.deinit(allocator);
    try std.testing.expect(too_large == .diagnostic);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "bounded", .{}));
}

fn exerciseAllocationFailures(allocator: std.mem.Allocator, path: []const u8) !void {
    // Reset through std.Io without using the allocator under test. Each injected
    // failure therefore sees the same old file and allocation path.
    const file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, "old\n");
    var result = try writeWithDiff(allocator, std.testing.io, path, "new\n", .{});
    result.deinit(allocator);
}

test "all allocation failures release state and do not leave temporary files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPath(std.testing.allocator, &tmp, "file.txt");
    defer std.testing.allocator.free(path);
    try writeTestFile(&tmp, "file.txt", "old\n");
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{path},
    );

    var dir = try tmp.dir.openDir(std.testing.io, ".", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var iterator = dir.iterate();
    while (try iterator.next(std.testing.io)) |entry| {
        try std.testing.expectEqualStrings("file.txt", entry.name);
    }
}

test "empty creation retains visible hax diff headers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPath(std.testing.allocator, &tmp, "empty");
    defer std.testing.allocator.free(path);
    var result = try writeWithDiff(std.testing.allocator, std.testing.io, path, "", .{});
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result == .written);
    try std.testing.expect(result.written.created);
    const expected = try std.fmt.allocPrint(
        std.testing.allocator,
        "--- /dev/null\n+++ b/{s}\n",
        .{path},
    );
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, result.written.diff);
}

fn exerciseEmptyCreationAllocations(allocator: std.mem.Allocator, path: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    var result = try writeWithDiff(allocator, std.testing.io, path, "", .{});
    result.deinit(allocator);
}

test "empty creation releases every allocation failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPath(std.testing.allocator, &tmp, "empty-oom");
    defer std.testing.allocator.free(path);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseEmptyCreationAllocations,
        .{path},
    );
}

fn exerciseDiagnosticAllocations(allocator: std.mem.Allocator, path: []const u8) !void {
    var result = try writeWithDiff(allocator, std.testing.io, path, "x", .{});
    result.deinit(allocator);
}

test "inspection diagnostics release the resolved path on OOM" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "directory", .default_dir);
    const path = try testPath(std.testing.allocator, &tmp, "directory");
    defer std.testing.allocator.free(path);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseDiagnosticAllocations,
        .{path},
    );
}

test "path and symlink expansion bounds fail before mutation" {
    const allocator = std.testing.allocator;
    var nul = try writeWithDiff(allocator, std.testing.io, "bad\x00path", "x", .{});
    defer nul.deinit(allocator);
    try std.testing.expectEqualStrings("path contains a NUL byte", nul.diagnostic);

    var bounded = try writeWithDiff(allocator, std.testing.io, "12345", "x", .{
        .maximum_path_bytes = 4,
    });
    defer bounded.deinit(allocator);
    try std.testing.expectEqualStrings("path is 5 bytes; path cap is 4", bounded.diagnostic);

    var physical_max_minus_one = try writeWithDiffAtPhysicalPathMax(
        allocator,
        std.testing.io,
        "1234",
        "x",
        .{ .maximum_file_bytes = 0, .maximum_path_bytes = 4 },
        5,
    );
    defer physical_max_minus_one.deinit(allocator);
    try std.testing.expectEqualStrings(
        "content is 1 bytes; write cap is 0",
        physical_max_minus_one.diagnostic,
    );

    var physical_max = try writeWithDiffAtPhysicalPathMax(
        allocator,
        std.testing.io,
        "12345",
        "x",
        .{ .maximum_path_bytes = 5 },
        5,
    );
    defer physical_max.deinit(allocator);
    try std.testing.expectEqualStrings("path is 5 bytes; path cap is 4", physical_max.diagnostic);

    var zero_physical_max = try writeWithDiffAtPhysicalPathMax(
        allocator,
        std.testing.io,
        "1",
        "x",
        .{ .maximum_path_bytes = 1 },
        0,
    );
    defer zero_physical_max.deinit(allocator);
    try std.testing.expectEqualStrings("path is 1 bytes; path cap is 0", zero_physical_max.diagnostic);
}

test "strict hax parity preserves complete existing mode including set-ID" {
    if (!std.Io.File.Permissions.has_executable_bit) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(&tmp, "privileged", "old\n");
    const file = try tmp.dir.openFile(std.testing.io, "privileged", .{ .mode = .read_write });
    const permissions: std.Io.File.Permissions = @enumFromInt(0o4755);
    try file.setPermissions(std.testing.io, permissions);
    file.close(std.testing.io);
    const path = try testPath(std.testing.allocator, &tmp, "privileged");
    defer std.testing.allocator.free(path);
    var result = try writeWithDiff(std.testing.allocator, std.testing.io, path, "new\n", .{});
    defer result.deinit(std.testing.allocator);
    const stat = try tmp.dir.statFile(std.testing.io, "privileged", .{});
    try std.testing.expectEqual(
        @intFromEnum(permissions),
        @intFromEnum(stat.permissions) & 0o7777,
    );
}

test "target identity detects concurrent creation and mutation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const missing_path = try testPath(allocator, &tmp, "missing");
    defer allocator.free(missing_path);
    const empty = try allocator.alloc(u8, 0);
    defer allocator.free(empty);
    var missing: Target = .{ .path = missing_path, .old_content = empty };
    try std.testing.expect(targetIdentityUnchanged(std.testing.io, &missing));
    try writeTestFile(&tmp, "missing", "created");
    try std.testing.expect(!targetIdentityUnchanged(std.testing.io, &missing));

    const existing_path = try testPath(allocator, &tmp, "existing");
    defer allocator.free(existing_path);
    try writeTestFile(&tmp, "existing", "old");
    const original = try tmp.dir.statFile(std.testing.io, "existing", .{});
    var existing: Target = .{
        .path = existing_path,
        .old_content = empty,
        .identity = original,
        .existed = true,
    };
    try std.testing.expect(targetIdentityUnchanged(std.testing.io, &existing));
    try writeTestFile(&tmp, "existing", "changed-size");
    try std.testing.expect(!targetIdentityUnchanged(std.testing.io, &existing));
}

fn createSymlinkChain(tmp: *std.testing.TmpDir, prefix: []const u8, links: usize) !void {
    for (0..links) |index| {
        var name_buffer: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "{s}{d}", .{ prefix, index });
        var target_buffer: [64]u8 = undefined;
        const target = if (index + 1 == links)
            "target"
        else
            try std.fmt.bufPrint(&target_buffer, "{s}{d}", .{ prefix, index + 1 });
        try tmp.dir.symLink(std.testing.io, target, name, .{});
    }
}

test "symlink resolver pins hax 32-iteration exhaustion" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(&tmp, "target", "x");
    try createSymlinkChain(&tmp, "ok", 31);
    const ok_path = try testPath(std.testing.allocator, &tmp, "ok0");
    defer std.testing.allocator.free(ok_path);
    const resolved = try resolveFinalSymlinks(
        std.testing.allocator,
        std.testing.io,
        ok_path,
        std.fs.max_path_bytes,
    );
    defer std.testing.allocator.free(resolved);
    try std.testing.expect(std.mem.endsWith(u8, resolved, "/target"));

    try createSymlinkChain(&tmp, "loop", 32);
    const loop_path = try testPath(std.testing.allocator, &tmp, "loop0");
    defer std.testing.allocator.free(loop_path);
    try std.testing.expectError(
        error.SymLinkLoop,
        resolveFinalSymlinks(
            std.testing.allocator,
            std.testing.io,
            loop_path,
            std.fs.max_path_bytes,
        ),
    );
}

test "symlink expansion obeys the configured path cap" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.symLink(std.testing.io, "a-much-longer-target-name", "x", .{});
    const path = try testPath(std.testing.allocator, &tmp, "x");
    defer std.testing.allocator.free(path);
    try std.testing.expectError(
        error.NameTooLong,
        resolveFinalSymlinks(
            std.testing.allocator,
            std.testing.io,
            path,
            path.len,
        ),
    );
}

fn exerciseExpandedPathCapAllocations(
    allocator: std.mem.Allocator,
    path: []const u8,
    physical_max_path_bytes: usize,
) !void {
    var result = try writeWithDiffAtPhysicalPathMax(
        allocator,
        std.testing.io,
        path,
        "x",
        .{ .maximum_path_bytes = physical_max_path_bytes },
        physical_max_path_bytes,
    );
    result.deinit(allocator);
}

test "symlink expansion rejects the exact injected physical maximum" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.symLink(std.testing.io, "ab", "ok", .{});
    try tmp.dir.symLink(std.testing.io, "abc", "no", .{});

    const ok_path = try testPath(std.testing.allocator, &tmp, "ok");
    defer std.testing.allocator.free(ok_path);
    const no_path = try testPath(std.testing.allocator, &tmp, "no");
    defer std.testing.allocator.free(no_path);
    const physical_max_path_bytes = no_path.len + 1;
    const maximum_path_bytes = physical_max_path_bytes - 1;

    var accepted = try writeWithDiffAtPhysicalPathMax(
        std.testing.allocator,
        std.testing.io,
        ok_path,
        "x",
        .{ .maximum_file_bytes = 0, .maximum_path_bytes = physical_max_path_bytes },
        physical_max_path_bytes,
    );
    defer accepted.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("content is 1 bytes; write cap is 0", accepted.diagnostic);

    var rejected = try writeWithDiffAtPhysicalPathMax(
        std.testing.allocator,
        std.testing.io,
        no_path,
        "x",
        .{ .maximum_path_bytes = physical_max_path_bytes },
        physical_max_path_bytes,
    );
    defer rejected.deinit(std.testing.allocator);
    const expected_diagnostic = try std.fmt.allocPrint(
        std.testing.allocator,
        "path is {d} bytes; path cap is {d}",
        .{ physical_max_path_bytes, maximum_path_bytes },
    );
    defer std.testing.allocator.free(expected_diagnostic);
    try std.testing.expectEqualStrings(expected_diagnostic, rejected.diagnostic);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseExpandedPathCapAllocations,
        .{ no_path, physical_max_path_bytes },
    );
}

test "expected content prevents stale read-modify-write replacement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(&tmp, "file", "concurrent\n");
    const path = try testPath(std.testing.allocator, &tmp, "file");
    defer std.testing.allocator.free(path);
    var result = try writeWithDiff(
        std.testing.allocator,
        std.testing.io,
        path,
        "updated\n",
        .{ .expected_content = "old\n" },
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result == .diagnostic);
    try std.testing.expect(std.mem.find(u8, result.diagnostic, "changed before write") != null);
    const content = try tmp.dir.readFileAlloc(
        std.testing.io,
        "file",
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("concurrent\n", content);
}

fn exercisePostDiffDiagnosticAllocations(
    allocator: std.mem.Allocator,
    path: []const u8,
) !void {
    var result = try writeWithDiff(allocator, std.testing.io, path, "new\n", .{});
    result.deinit(allocator);
}

test "post-diff filesystem diagnostics release the owned diff" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "locked", .default_dir);
    try writeTestFile(&tmp, "locked/file", "old\n");
    const locked = try tmp.dir.openDir(std.testing.io, "locked", .{});
    defer locked.close(std.testing.io);
    try locked.setPermissions(std.testing.io, @enumFromInt(0o555));
    defer locked.setPermissions(std.testing.io, @enumFromInt(0o755)) catch {};
    const path = try testPath(
        std.testing.allocator,
        &tmp,
        "locked/file",
    );
    defer std.testing.allocator.free(path);
    var probe = try writeWithDiff(std.testing.allocator, std.testing.io, path, "new\n", .{});
    defer probe.deinit(std.testing.allocator);
    if (probe == .written) return error.SkipZigTest;
    try std.testing.expect(std.mem.find(u8, probe.diagnostic, "temporary") != null);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exercisePostDiffDiagnosticAllocations,
        .{path},
    );
}
