const std = @import("std");
const Utf8 = @import("../text/Utf8.zig");

pub const maximum_file_bytes: usize = 64 * 1024;

pub const Error = error{
    OutOfMemory,
    Unresolved,
    Read,
    Unreadable,
    NonRegular,
    TooLarge,
    InvalidPath,
};

/// Allocator-owned, move-only prompt text. Do not copy it. Call `deinit`
/// exactly once with the allocator passed to `resolve`.
pub const Value = struct {
    text: []u8,

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        @memset(self.text, 0);
        allocator.free(self.text);
        self.* = undefined;
    }
};

/// Resolves one already-selected config prompt value without consulting
/// ambient process state. Literal values, including empty and "(none)", are
/// returned as owned copies.
///
/// A leading `@` loads a file. Absolute paths are unchanged. `~` and `~/`
/// use `home`. A `~` followed by another byte is rooted at the injected `cwd`,
/// matching hax's current-directory lookup without consulting ambient state.
/// Other relative paths use `config_root`. Bases are required only for forms
/// which use them and must be absolute UTF-8 paths.
///
/// The file loader follows symbolic links to regular files, matching hax. It
/// opens with POSIX O_NONBLOCK and checks the opened descriptor before reading,
/// so FIFO substitution cannot stall startup. Prompt values and path parents are
/// trusted inputs; POSIX cannot promise that every device honors O_NONBLOCK.
pub fn resolve(
    allocator: std.mem.Allocator,
    io: std.Io,
    literal_value: []const u8,
    config_root: ?[]const u8,
    home: ?[]const u8,
    cwd: ?[]const u8,
) Error!Value {
    if (literal_value.len == 0 or literal_value[0] != '@') {
        const owned = allocator.dupe(u8, literal_value) catch return error.OutOfMemory;
        return .{ .text = owned };
    }

    const path = try resolvePath(allocator, literal_value[1..], config_root, home, cwd);
    defer allocator.free(path);
    return loadFile(allocator, io, path);
}

fn resolvePath(
    allocator: std.mem.Allocator,
    spec: []const u8,
    config_root: ?[]const u8,
    home: ?[]const u8,
    cwd: ?[]const u8,
) Error![]u8 {
    try validatePathBytes(spec, false);
    if (spec.len != 0 and spec[0] == '/')
        return allocator.dupe(u8, spec) catch error.OutOfMemory;

    if (std.mem.eql(u8, spec, "~") or std.mem.startsWith(u8, spec, "~/")) {
        const base = home orelse return error.Unresolved;
        try validatePathBytes(base, true);
        return std.mem.concat(allocator, u8, &.{ base, spec[1..] }) catch error.OutOfMemory;
    }
    if (spec.len != 0 and spec[0] == '~') {
        const base = cwd orelse return error.Unresolved;
        try validatePathBytes(base, true);
        return std.mem.concat(allocator, u8, &.{ base, "/", spec }) catch error.OutOfMemory;
    }

    const base = config_root orelse return error.Unresolved;
    try validatePathBytes(base, true);
    return std.mem.concat(allocator, u8, &.{ base, "/", spec }) catch error.OutOfMemory;
}

fn validatePathBytes(path: []const u8, require_absolute: bool) Error!void {
    if ((require_absolute and (path.len == 0 or path[0] != '/')) or
        std.mem.indexOfScalar(u8, path, 0) != null or
        !std.unicode.utf8ValidateSlice(path)) return error.InvalidPath;
}

fn loadFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) Error!Value {
    const file = openNonblocking(path) catch |err| return mapOpenError(err);
    defer file.close(io);

    const stat = file.stat(io) catch return error.Read;
    if (stat.kind != .file) return error.NonRegular;
    if (stat.size > maximum_file_bytes) return error.TooLarge;

    // The extra byte is an explicit truncation probe. It also catches a file
    // which grows after fstat without silently cutting the prompt.
    const bytes = allocator.alloc(u8, maximum_file_bytes + 1) catch return error.OutOfMemory;
    defer {
        @memset(bytes, 0);
        allocator.free(bytes);
    }
    const count = file.readPositionalAll(io, bytes, 0) catch return error.Read;
    if (count > maximum_file_bytes) return error.TooLarge;

    // Sanitization can replace each malformed source byte with three bytes.
    // The 64 KiB cap applies to the source file, as it does in hax.
    var clean = Utf8.sanitize(allocator, bytes[0..count], maximum_file_bytes * 3) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ResultTooLarge => unreachable,
    };
    var end = clean.len;
    while (end != 0 and (clean[end - 1] == '\r' or clean[end - 1] == '\n')) end -= 1;
    if (end != clean.len) {
        const trimmed = allocator.dupe(u8, clean[0..end]) catch {
            @memset(clean, 0);
            allocator.free(clean);
            return error.OutOfMemory;
        };
        @memset(clean, 0);
        allocator.free(clean);
        clean = trimmed;
    }
    return .{ .text = clean };
}

fn openNonblocking(path: []const u8) std.posix.OpenError!std.Io.File {
    const handle = try std.posix.openat(std.posix.AT.FDCWD, path, .{
        .ACCMODE = .RDONLY,
        .NONBLOCK = true,
        .CLOEXEC = true,
    }, 0);
    return .{ .handle = handle, .flags = .{ .nonblocking = true } };
}

fn mapOpenError(err: std.posix.OpenError) Error {
    return switch (err) {
        error.AccessDenied, error.PermissionDenied => error.Unreadable,
        error.NameTooLong, error.BadPathName => error.InvalidPath,
        else => error.Read,
    };
}

fn testPath(allocator: std.mem.Allocator, base: []const u8, leaf: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ base, leaf });
}

test "literal empty and none values are owned" {
    const cases = [_][]const u8{ "literal", "", "(none)" };
    for (cases) |source| {
        var value = try resolve(std.testing.allocator, std.testing.io, source, null, null, null);
        defer value.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(source, value.text);
    }
}

test "relative home and absolute paths load" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "prompt", .data = "hello" });
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    const absolute = try testPath(std.testing.allocator, base, "prompt");
    defer std.testing.allocator.free(absolute);

    const forms = [_]struct { source: []const u8, root: ?[]const u8, home: ?[]const u8 }{
        .{ .source = "@prompt", .root = base, .home = null },
        .{ .source = "@~/prompt", .root = null, .home = base },
        .{ .source = absolute, .root = null, .home = null },
    };
    for (forms) |form| {
        const source = if (form.source.ptr == absolute.ptr)
            try std.mem.concat(std.testing.allocator, u8, &.{ "@", form.source })
        else
            try std.testing.allocator.dupe(u8, form.source);
        defer std.testing.allocator.free(source);
        var value = try resolve(std.testing.allocator, std.testing.io, source, form.root, form.home, null);
        defer value.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("hello", value.text);
    }
}

test "tilde without slash uses the injected cwd" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "~draft", .data = "cwd prompt" });
    const cwd = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(cwd);

    var value = try resolve(std.testing.allocator, std.testing.io, "@~draft", null, null, cwd);
    defer value.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("cwd prompt", value.text);

    try std.testing.expectError(
        error.Unresolved,
        resolve(std.testing.allocator, std.testing.io, "@~draft", null, null, null),
    );
}

test "permission failures map to unreadable" {
    try std.testing.expectEqual(error.Unreadable, mapOpenError(error.AccessDenied));
    try std.testing.expectEqual(error.Unreadable, mapOpenError(error.PermissionDenied));
}

test "missing roots invalid paths and missing files are typed" {
    try std.testing.expectError(
        error.Unresolved,
        resolve(std.testing.allocator, std.testing.io, "@relative", null, null, null),
    );
    try std.testing.expectError(
        error.Unresolved,
        resolve(std.testing.allocator, std.testing.io, "@~/file", null, null, null),
    );
    try std.testing.expectError(
        error.InvalidPath,
        resolve(std.testing.allocator, std.testing.io, "@file", "relative", null, null),
    );
    try std.testing.expectError(
        error.InvalidPath,
        resolve(std.testing.allocator, std.testing.io, "@/bad\x00path", null, null, null),
    );
    try std.testing.expectError(
        error.InvalidPath,
        resolve(std.testing.allocator, std.testing.io, "@/bad\xffpath", null, null, null),
    );
    try std.testing.expectError(
        error.Read,
        resolve(std.testing.allocator, std.testing.io, "@/surely/not/a/zi/prompt", null, null, null),
    );
}

test "empty trim invalid UTF-8 and NUL file contents" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "empty", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "trim", .data = "a\r\n\n\r" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "dirty", .data = "a\xff\x00b" });
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);

    const cases = [_]struct { leaf: []const u8, expected: []const u8 }{
        .{ .leaf = "empty", .expected = "" },
        .{ .leaf = "trim", .expected = "a" },
        .{ .leaf = "dirty", .expected = "a\xef\xbf\xbd\xef\xbf\xbdb" },
    };
    for (cases) |case| {
        const source = try std.mem.concat(std.testing.allocator, u8, &.{ "@", base, "/", case.leaf });
        defer std.testing.allocator.free(source);
        var value = try resolve(std.testing.allocator, std.testing.io, source, null, null, null);
        defer value.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(case.expected, value.text);
    }
}

test "exact cap succeeds and one byte over fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const exact = try std.testing.allocator.alloc(u8, maximum_file_bytes);
    defer std.testing.allocator.free(exact);
    @memset(exact, 'x');
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "exact", .data = exact });
    const over = try std.testing.allocator.alloc(u8, maximum_file_bytes + 1);
    defer std.testing.allocator.free(over);
    @memset(over, 'x');
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "over", .data = over });
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);

    const exact_source = try std.mem.concat(std.testing.allocator, u8, &.{ "@", base, "/exact" });
    defer std.testing.allocator.free(exact_source);
    var value = try resolve(std.testing.allocator, std.testing.io, exact_source, null, null, null);
    defer value.deinit(std.testing.allocator);
    try std.testing.expectEqual(maximum_file_bytes, value.text.len);

    const over_source = try std.mem.concat(std.testing.allocator, u8, &.{ "@", base, "/over" });
    defer std.testing.allocator.free(over_source);
    try std.testing.expectError(
        error.TooLarge,
        resolve(std.testing.allocator, std.testing.io, over_source, null, null, null),
    );
}

test "directory is rejected and symlink to regular file is followed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "directory", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "target", .data = "linked" });
    try tmp.dir.symLink(std.testing.io, "target", "link", .{});
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);

    const directory = try std.mem.concat(std.testing.allocator, u8, &.{ "@", base, "/directory" });
    defer std.testing.allocator.free(directory);
    try std.testing.expectError(
        error.NonRegular,
        resolve(std.testing.allocator, std.testing.io, directory, null, null, null),
    );

    const link = try std.mem.concat(std.testing.allocator, u8, &.{ "@", base, "/link" });
    defer std.testing.allocator.free(link);
    var value = try resolve(std.testing.allocator, std.testing.io, link, null, null, null);
    defer value.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("linked", value.text);
}

fn exerciseAllocations(allocator: std.mem.Allocator, source: []const u8) !void {
    var value = try resolve(allocator, std.testing.io, source, null, null, null);
    value.deinit(allocator);
}

test "file resolve frees every allocation on OOM" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "prompt", .data = "dirty \xff text\n" });
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    const source = try std.mem.concat(std.testing.allocator, u8, &.{ "@", base, "/prompt" });
    defer std.testing.allocator.free(source);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseAllocations, .{source});
}
