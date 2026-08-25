const std = @import("std");
const Utf8 = @import("../text/Utf8.zig");
const SecureOpen = @import("SecureOpen.zig");

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
/// The injected loader must reject a final symbolic link and use nonblocking
/// mode. The opened descriptor is checked again before reading, so FIFO or kind
/// substitution cannot stall startup. Prompt paths and their parents are trusted
/// inputs; a platform cannot promise that every device honors nonblocking mode.
pub fn resolve(
    allocator: std.mem.Allocator,
    io: std.Io,
    secure_open: SecureOpen.Capability,
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
    return loadFile(allocator, io, secure_open, path);
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

fn loadFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    secure_open: SecureOpen.Capability,
    path: []const u8,
) Error!Value {
    const named_stat = secure_open.statFile(io, path) catch |err| return mapOpenError(err);
    if (named_stat.kind != .file) return error.NonRegular;
    if (named_stat.size > maximum_file_bytes) return error.TooLarge;

    const file = secure_open.openFile(io, path) catch |err| return mapOpenError(err);
    defer file.close(io);

    const stat = file.stat(io) catch return error.Read;
    if (stat.kind != .file or stat.nlink == 0) return error.NonRegular;
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

fn mapOpenError(err: SecureOpen.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Unreadable => error.Unreadable,
        error.InvalidPath => error.InvalidPath,
        error.FileNotFound, error.Failed => error.Read,
    };
}

const TestSecureOpen = struct {
    directory: ?std.Io.Dir = null,
    base: []const u8 = "",
    fail_open_oom: bool = false,
    open_substitute: ?[]const u8 = null,

    fn relative(self: *TestSecureOpen, path: []const u8) SecureOpen.Error![]const u8 {
        if (self.directory == null or !std.mem.startsWith(u8, path, self.base) or
            path.len <= self.base.len or path[self.base.len] != '/') return error.FileNotFound;
        return path[self.base.len + 1 ..];
    }

    pub fn statAbsolute(self: *TestSecureOpen, io: std.Io, path: []const u8) SecureOpen.Error!std.Io.File.Stat {
        const sub_path = try self.relative(path);
        return self.directory.?.statFile(io, sub_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => error.FileNotFound,
            error.AccessDenied, error.PermissionDenied => error.Unreadable,
            else => error.Failed,
        };
    }

    pub fn openAbsolute(self: *TestSecureOpen, io: std.Io, path: []const u8) SecureOpen.Error!std.Io.File {
        if (self.fail_open_oom) return error.OutOfMemory;
        const sub_path = self.open_substitute orelse try self.relative(path);
        return self.directory.?.openFile(io, sub_path, .{}) catch |err| switch (err) {
            error.FileNotFound => error.FileNotFound,
            error.AccessDenied, error.PermissionDenied => error.Unreadable,
            else => error.Failed,
        };
    }
};

fn testPath(allocator: std.mem.Allocator, base: []const u8, leaf: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ base, leaf });
}

test "literal empty and none values are owned" {
    var secure_open_impl: TestSecureOpen = .{};
    const secure_open = SecureOpen.Capability.from(&secure_open_impl);
    const cases = [_][]const u8{ "literal", "", "(none)" };
    for (cases) |source| {
        var value = try resolve(std.testing.allocator, std.testing.io, secure_open, source, null, null, null);
        defer value.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(source, value.text);
    }
}

test "relative home and absolute paths load" {
    var secure_open_impl: TestSecureOpen = .{};
    const secure_open = SecureOpen.Capability.from(&secure_open_impl);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "prompt", .data = "hello" });
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    secure_open_impl = .{ .directory = tmp.dir, .base = base };
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
        var value = try resolve(std.testing.allocator, std.testing.io, secure_open, source, form.root, form.home, null);
        defer value.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("hello", value.text);
    }
}

test "tilde without slash uses the injected cwd" {
    var secure_open_impl: TestSecureOpen = .{};
    const secure_open = SecureOpen.Capability.from(&secure_open_impl);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "~draft", .data = "cwd prompt" });
    const cwd = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    secure_open_impl = .{ .directory = tmp.dir, .base = cwd };

    var value = try resolve(std.testing.allocator, std.testing.io, secure_open, "@~draft", null, null, cwd);
    defer value.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("cwd prompt", value.text);

    try std.testing.expectError(
        error.Unresolved,
        resolve(std.testing.allocator, std.testing.io, secure_open, "@~draft", null, null, null),
    );
}

test "permission failures map to unreadable" {
    try std.testing.expectEqual(error.Unreadable, mapOpenError(error.Unreadable));
}

test "missing roots invalid paths and missing files are typed" {
    var secure_open_impl: TestSecureOpen = .{};
    const secure_open = SecureOpen.Capability.from(&secure_open_impl);
    try std.testing.expectError(
        error.Unresolved,
        resolve(std.testing.allocator, std.testing.io, secure_open, "@relative", null, null, null),
    );
    try std.testing.expectError(
        error.Unresolved,
        resolve(std.testing.allocator, std.testing.io, secure_open, "@~/file", null, null, null),
    );
    try std.testing.expectError(
        error.InvalidPath,
        resolve(std.testing.allocator, std.testing.io, secure_open, "@file", "relative", null, null),
    );
    try std.testing.expectError(
        error.InvalidPath,
        resolve(std.testing.allocator, std.testing.io, secure_open, "@/bad\x00path", null, null, null),
    );
    try std.testing.expectError(
        error.InvalidPath,
        resolve(std.testing.allocator, std.testing.io, secure_open, "@/bad\xffpath", null, null, null),
    );
    try std.testing.expectError(
        error.Read,
        resolve(std.testing.allocator, std.testing.io, secure_open, "@/surely/not/a/zi/prompt", null, null, null),
    );
}

test "empty trim invalid UTF-8 and NUL file contents" {
    var secure_open_impl: TestSecureOpen = .{};
    const secure_open = SecureOpen.Capability.from(&secure_open_impl);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "empty", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "trim", .data = "a\r\n\n\r" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "dirty", .data = "a\xff\x00b" });
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    secure_open_impl = .{ .directory = tmp.dir, .base = base };

    const cases = [_]struct { leaf: []const u8, expected: []const u8 }{
        .{ .leaf = "empty", .expected = "" },
        .{ .leaf = "trim", .expected = "a" },
        .{ .leaf = "dirty", .expected = "a\xef\xbf\xbd\xef\xbf\xbdb" },
    };
    for (cases) |case| {
        const source = try std.mem.concat(std.testing.allocator, u8, &.{ "@", base, "/", case.leaf });
        defer std.testing.allocator.free(source);
        var value = try resolve(std.testing.allocator, std.testing.io, secure_open, source, null, null, null);
        defer value.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(case.expected, value.text);
    }
}

test "exact cap succeeds and one byte over fails" {
    var secure_open_impl: TestSecureOpen = .{};
    const secure_open = SecureOpen.Capability.from(&secure_open_impl);
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
    secure_open_impl = .{ .directory = tmp.dir, .base = base };

    const exact_source = try std.mem.concat(std.testing.allocator, u8, &.{ "@", base, "/exact" });
    defer std.testing.allocator.free(exact_source);
    var value = try resolve(std.testing.allocator, std.testing.io, secure_open, exact_source, null, null, null);
    defer value.deinit(std.testing.allocator);
    try std.testing.expectEqual(maximum_file_bytes, value.text.len);

    const over_source = try std.mem.concat(std.testing.allocator, u8, &.{ "@", base, "/over" });
    defer std.testing.allocator.free(over_source);
    try std.testing.expectError(
        error.TooLarge,
        resolve(std.testing.allocator, std.testing.io, secure_open, over_source, null, null, null),
    );
}

test "directory and symlink are rejected" {
    var secure_open_impl: TestSecureOpen = .{};
    const secure_open = SecureOpen.Capability.from(&secure_open_impl);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "directory", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "target", .data = "linked" });
    try tmp.dir.symLink(std.testing.io, "target", "link", .{});
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    secure_open_impl = .{ .directory = tmp.dir, .base = base };

    const directory = try std.mem.concat(std.testing.allocator, u8, &.{ "@", base, "/directory" });
    defer std.testing.allocator.free(directory);
    try std.testing.expectError(
        error.NonRegular,
        resolve(std.testing.allocator, std.testing.io, secure_open, directory, null, null, null),
    );

    const link = try std.mem.concat(std.testing.allocator, u8, &.{ "@", base, "/link" });
    defer std.testing.allocator.free(link);
    try std.testing.expectError(
        error.NonRegular,
        resolve(std.testing.allocator, std.testing.io, secure_open, link, null, null, null),
    );
}

fn exerciseAllocations(
    allocator: std.mem.Allocator,
    secure_open: SecureOpen.Capability,
    source: []const u8,
) !void {
    var value = try resolve(allocator, std.testing.io, secure_open, source, null, null, null);
    value.deinit(allocator);
}

test "file resolve frees every allocation on OOM" {
    var secure_open_impl: TestSecureOpen = .{};
    const secure_open = SecureOpen.Capability.from(&secure_open_impl);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "prompt", .data = "dirty \xff text\n" });
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    secure_open_impl = .{ .directory = tmp.dir, .base = base };
    const source = try std.mem.concat(std.testing.allocator, u8, &.{ "@", base, "/prompt" });
    defer std.testing.allocator.free(source);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocations,
        .{ secure_open, source },
    );
}

test "injected open OOM propagates and opened kind drift is rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "prompt", .data = "hello" });
    try tmp.dir.createDir(std.testing.io, "replacement", .default_dir);
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    const source = try std.mem.concat(std.testing.allocator, u8, &.{ "@", base, "/prompt" });
    defer std.testing.allocator.free(source);

    var implementation: TestSecureOpen = .{
        .directory = tmp.dir,
        .base = base,
        .fail_open_oom = true,
    };
    const secure_open = SecureOpen.Capability.from(&implementation);
    try std.testing.expectError(
        error.OutOfMemory,
        resolve(std.testing.allocator, std.testing.io, secure_open, source, null, null, null),
    );

    implementation.fail_open_oom = false;
    implementation.open_substitute = "replacement";
    try std.testing.expectError(
        error.NonRegular,
        resolve(std.testing.allocator, std.testing.io, secure_open, source, null, null, null),
    );
}
