const std = @import("std");
const builtin = @import("builtin");
const ai = @import("../ai/root.zig");

comptime {
    switch (builtin.os.tag) {
        .macos, .linux, .freebsd, .openbsd, .netbsd, .dragonfly, .illumos => {},
        else => @compileError("cli.CodexFiles supports only Zi's Unix product targets"),
    }
}

pub const maximum_path_bytes: usize = std.fs.max_path_bytes;

pub const InitError = error{ OutOfMemory, InvalidPath, PathTooLong };
pub const SettingsResult = ai.CodexCredentials.LoaderResult;

/// Copyable handle to heap-stable Codex CLI file state. Only one copy may call
/// deinit. Every credential loader borrowed from it must expire before deinit.
pub const CodexFiles = @This();

context: *Context,

const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    auth_path: ?[]u8,
    config_path: ?[]u8,

    pub fn load(
        self: *Context,
        allocator: std.mem.Allocator,
        maximum_bytes: usize,
    ) error{OutOfMemory}!ai.CodexCredentials.LoaderResult {
        return loadPath(allocator, self.io, self.auth_path, maximum_bytes);
    }
};

/// HOME is borrowed only for this call. It must be an absolute UTF-8 path.
/// Null and empty HOME values construct a source whose loads report missing.
pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    home: ?[]const u8,
) InitError!CodexFiles {
    const context = try allocator.create(Context);
    errdefer allocator.destroy(context);
    context.* = .{
        .allocator = allocator,
        .io = io,
        .auth_path = null,
        .config_path = null,
    };
    const home_path = home orelse return .{ .context = context };
    if (home_path.len == 0) return .{ .context = context };
    try validateHome(home_path);
    context.auth_path = try buildPath(allocator, home_path, ".codex/auth.json");
    errdefer allocator.free(context.auth_path.?);
    context.config_path = try buildPath(allocator, home_path, ".codex/config.toml");
    return .{ .context = context };
}

pub fn deinit(self: *CodexFiles) void {
    const context = self.context;
    if (context.auth_path) |path| context.allocator.free(path);
    if (context.config_path) |path| context.allocator.free(path);
    context.allocator.destroy(context);
    self.* = undefined;
}

pub fn credentialsLoader(self: CodexFiles) ai.CodexCredentials.Loader {
    return .from(self.context);
}

/// Reads `~/.codex/config.toml` with CodexSettings' input limit. Returned
/// bytes belong to allocator and contain potentially sensitive user data;
/// callers must wipe them before freeing.
pub fn loadSettings(
    self: CodexFiles,
    allocator: std.mem.Allocator,
) error{OutOfMemory}!SettingsResult {
    return loadPath(allocator, self.context.io, self.context.config_path, ai.CodexSettings.maximum_file_bytes);
}

fn validateHome(home: []const u8) InitError!void {
    if (!std.fs.path.isAbsolute(home) or std.mem.indexOfScalar(u8, home, 0) != null or
        !std.unicode.utf8ValidateSlice(home)) return error.InvalidPath;
    if (home.len >= maximum_path_bytes) return error.PathTooLong;
}

fn buildPath(
    allocator: std.mem.Allocator,
    home: []const u8,
    suffix: []const u8,
) InitError![]u8 {
    const needs_separator = home[home.len - 1] != '/';
    const separator_len: usize = if (needs_separator) 1 else 0;
    const tail_len = std.math.add(usize, separator_len, suffix.len) catch return error.PathTooLong;
    const length = std.math.add(usize, home.len, tail_len) catch return error.PathTooLong;
    if (length >= maximum_path_bytes) return error.PathTooLong;
    const path = try allocator.alloc(u8, length);
    @memcpy(path[0..home.len], home);
    var cursor = home.len;
    if (needs_separator) {
        path[cursor] = '/';
        cursor += 1;
    }
    @memcpy(path[cursor..], suffix);
    return path;
}

fn loadPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    maybe_path: ?[]const u8,
    maximum_bytes: usize,
) error{OutOfMemory}!ai.CodexCredentials.LoaderResult {
    const path = maybe_path orelse return .missing;
    const file = openFinal(path) catch |err| return switch (err) {
        error.FileNotFound => .missing,
        else => .unreadable,
    };
    defer file.close(io);

    const stat = file.stat(io) catch return .unreadable;
    if (stat.kind != .file or stat.nlink != 1) return .unreadable;

    const capacity = std.math.add(usize, maximum_bytes, 1) catch return .unreadable;
    const scratch = allocator.alloc(u8, capacity) catch return error.OutOfMemory;
    defer wipeFree(allocator, scratch);

    var reader_buffer: [1]u8 = undefined;
    var reader = std.Io.File.Reader.initStreaming(file, io, &reader_buffer);
    const count = reader.interface.readSliceShort(scratch) catch return .unreadable;
    if (count > maximum_bytes) return .unreadable;
    const bytes = allocator.alloc(u8, count) catch return error.OutOfMemory;
    @memcpy(bytes, scratch[0..count]);
    return .{ .bytes = bytes };
}

// Security narrowing: HOME and ~/.codex are trusted parents. Only the final
// file is protected here: no symlink traversal, regular type, and one link.
fn openFinal(path: []const u8) !std.Io.File {
    const handle = try std.posix.openat(std.posix.AT.FDCWD, path, .{
        .ACCMODE = .RDONLY,
        .NONBLOCK = true,
        .CLOEXEC = true,
        .NOFOLLOW = true,
    }, 0);
    return .{ .handle = handle, .flags = .{ .nonblocking = true } };
}

fn wipeFree(allocator: std.mem.Allocator, bytes: []u8) void {
    std.crypto.secureZero(u8, bytes);
    allocator.rawFree(bytes, .of(u8), @returnAddress());
}

const Fixture = struct { tmp: std.testing.TmpDir, home: [:0]u8 };

fn makeFixture() !Fixture {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, ".codex", .default_dir);
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    return .{ .tmp = tmp, .home = home };
}

fn freeFixture(fixture: *Fixture) void {
    std.testing.allocator.free(fixture.home);
    fixture.tmp.cleanup();
}

fn expectBytes(result: SettingsResult, expected: []const u8) !void {
    switch (result) {
        .bytes => |bytes| {
            defer wipeFree(std.testing.allocator, bytes);
            try std.testing.expectEqualStrings(expected, bytes);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "HOME absent is missing and paths are exact and owned" {
    var absent = try init(std.testing.allocator, std.testing.io, null);
    defer absent.deinit();
    try std.testing.expect((try absent.credentialsLoader().load(std.testing.allocator, 8)) == .missing);
    try std.testing.expect((try absent.loadSettings(std.testing.allocator)) == .missing);

    var empty = try init(std.testing.allocator, std.testing.io, "");
    defer empty.deinit();
    try std.testing.expect((try empty.credentialsLoader().load(std.testing.allocator, 8)) == .missing);
    try std.testing.expect((try empty.loadSettings(std.testing.allocator)) == .missing);

    var fixture = try makeFixture();
    defer freeFixture(&fixture);
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".codex/auth.json", .data = "auth" });
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".codex/config.toml", .data = "model='o3'" });
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "auth.json", .data = "decoy" });
    var files = try init(std.testing.allocator, std.testing.io, fixture.home);
    defer files.deinit();
    @memset(fixture.home, 'x');
    switch (try files.credentialsLoader().load(std.testing.allocator, 8)) {
        .bytes => |bytes| {
            defer wipeFree(std.testing.allocator, bytes);
            try std.testing.expectEqualStrings("auth", bytes);
        },
        else => return error.TestUnexpectedResult,
    }
    try expectBytes(try files.loadSettings(std.testing.allocator), "model='o3'");
}

test "credential read accepts max and rejects max plus one" {
    var fixture = try makeFixture();
    defer freeFixture(&fixture);
    var files = try init(std.testing.allocator, std.testing.io, fixture.home);
    defer files.deinit();
    const data = "x" ** 17;
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".codex/auth.json", .data = data[0..16] });
    switch (try files.credentialsLoader().load(std.testing.allocator, 16)) {
        .bytes => |bytes| {
            defer wipeFree(std.testing.allocator, bytes);
            try std.testing.expectEqualStrings(data[0..16], bytes);
        },
        else => return error.TestUnexpectedResult,
    }
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".codex/auth.json", .data = data });
    try std.testing.expect((try files.credentialsLoader().load(std.testing.allocator, 16)) == .unreadable);
}

test "missing directory nonregular hardlink and final symlink are rejected" {
    var fixture = try makeFixture();
    defer freeFixture(&fixture);
    var files = try init(std.testing.allocator, std.testing.io, fixture.home);
    defer files.deinit();
    try std.testing.expect((try files.credentialsLoader().load(std.testing.allocator, 8)) == .missing);

    try fixture.tmp.dir.createDir(std.testing.io, ".codex/auth.json", .default_dir);
    try std.testing.expect((try files.credentialsLoader().load(std.testing.allocator, 8)) == .unreadable);
    try fixture.tmp.dir.deleteDir(std.testing.io, ".codex/auth.json");

    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".codex/target", .data = "x" });
    try fixture.tmp.dir.symLink(std.testing.io, "target", ".codex/auth.json", .{});
    try std.testing.expect((try files.credentialsLoader().load(std.testing.allocator, 8)) == .unreadable);
    try fixture.tmp.dir.deleteFile(std.testing.io, ".codex/auth.json");

    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".codex/auth.json", .data = "x" });
    try fixture.tmp.dir.hardLink(
        ".codex/auth.json",
        fixture.tmp.dir,
        ".codex/second-hard",
        std.testing.io,
        .{},
    );
    try std.testing.expect((try files.credentialsLoader().load(std.testing.allocator, 8)) == .unreadable);
}

test "loader context remains stable when the source handle moves" {
    var fixture = try makeFixture();
    defer freeFixture(&fixture);
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".codex/auth.json", .data = "stable" });
    var source = try init(std.testing.allocator, std.testing.io, fixture.home);
    const loader = source.credentialsLoader();
    var owner = source;
    source = undefined;
    defer owner.deinit();
    switch (try loader.load(std.testing.allocator, 16)) {
        .bytes => |bytes| {
            defer wipeFree(std.testing.allocator, bytes);
            try std.testing.expectEqualStrings("stable", bytes);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "invalid HOME path and path overflow are rejected" {
    try std.testing.expectError(error.InvalidPath, init(std.testing.allocator, std.testing.io, "relative"));
    try std.testing.expectError(error.InvalidPath, init(std.testing.allocator, std.testing.io, "/bad\x00path"));
    try std.testing.expectError(error.InvalidPath, init(std.testing.allocator, std.testing.io, "/bad\xffpath"));
    const long_home = "/" ++ "x" ** maximum_path_bytes;
    try std.testing.expectError(error.PathTooLong, init(std.testing.allocator, std.testing.io, long_home));
}

test "PATH_MAX reserves its final byte for NUL" {
    const auth_suffix = ".codex/auth.json";
    const config_suffix = ".codex/config.toml";

    const config_boundary_len = maximum_path_bytes - 1 - config_suffix.len;
    const config_boundary = try std.testing.allocator.alloc(u8, config_boundary_len);
    defer std.testing.allocator.free(config_boundary);
    @memset(config_boundary, 'x');
    config_boundary[0] = '/';
    try std.testing.expectError(
        error.PathTooLong,
        init(std.testing.allocator, std.testing.io, config_boundary),
    );

    const auth_boundary_len = maximum_path_bytes - 1 - auth_suffix.len;
    const auth_boundary = try std.testing.allocator.alloc(u8, auth_boundary_len);
    defer std.testing.allocator.free(auth_boundary);
    @memset(auth_boundary, 'x');
    auth_boundary[0] = '/';
    try std.testing.expectError(
        error.PathTooLong,
        init(std.testing.allocator, std.testing.io, auth_boundary),
    );

    const last_valid_home_len = maximum_path_bytes - 2 - config_suffix.len;
    const last_valid_home = try std.testing.allocator.alloc(u8, last_valid_home_len);
    defer std.testing.allocator.free(last_valid_home);
    @memset(last_valid_home, 'x');
    last_valid_home[0] = '/';
    var files = try init(std.testing.allocator, std.testing.io, last_valid_home);
    files.deinit();
}

fn exerciseInitFailures(allocator: std.mem.Allocator) !void {
    var files = try init(allocator, std.testing.io, "/tmp/codex-files-home");
    files.deinit();
}

test "initialization allocation failures clean up" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseInitFailures, .{});
}

fn exerciseLoadFailures(
    allocator: std.mem.Allocator,
    loader: ai.CodexCredentials.Loader,
) !void {
    switch (try loader.load(allocator, 32)) {
        .bytes => |bytes| wipeFree(allocator, bytes),
        else => return error.TestUnexpectedResult,
    }
}

test "load allocation failures wipe and release scratch" {
    var fixture = try makeFixture();
    defer freeFixture(&fixture);
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".codex/auth.json", .data = "secret" });
    var files = try init(std.testing.allocator, std.testing.io, fixture.home);
    defer files.deinit();
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseLoadFailures,
        .{files.credentialsLoader()},
    );
}

test "settings read accepts its exact limit and rejects one extra byte" {
    var fixture = try makeFixture();
    defer freeFixture(&fixture);
    var files = try init(std.testing.allocator, std.testing.io, fixture.home);
    defer files.deinit();
    const maximum = ai.CodexSettings.maximum_file_bytes;
    const data = try std.testing.allocator.alloc(u8, maximum + 1);
    defer std.testing.allocator.free(data);
    @memset(data, 'c');
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".codex/config.toml", .data = data[0..maximum] });
    switch (try files.loadSettings(std.testing.allocator)) {
        .bytes => |bytes| {
            defer wipeFree(std.testing.allocator, bytes);
            try std.testing.expectEqual(maximum, bytes.len);
        },
        else => return error.TestUnexpectedResult,
    }
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".codex/config.toml", .data = data });
    try std.testing.expect((try files.loadSettings(std.testing.allocator)) == .unreadable);
}

const WipeObserver = struct {
    child: std.mem.Allocator,
    zero_frees: usize = 0,
    other_frees: usize = 0,

    fn allocator(self: *WipeObserver) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn alloc(
        context: *anyopaque,
        length: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *WipeObserver = @ptrCast(@alignCast(context));
        return self.child.rawAlloc(length, alignment, return_address);
    }

    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }

    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *WipeObserver = @ptrCast(@alignCast(context));
        var all_zero = true;
        for (memory) |byte| all_zero = all_zero and byte == 0;
        if (all_zero) self.zero_frees += 1 else self.other_frees += 1;
        self.child.rawFree(memory, alignment, return_address);
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };
};

test "scratch is wiped and returned content remains caller-owned" {
    var fixture = try makeFixture();
    defer freeFixture(&fixture);
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".codex/auth.json", .data = "secret" });
    var files = try init(std.testing.allocator, std.testing.io, fixture.home);
    defer files.deinit();
    var observer: WipeObserver = .{ .child = std.testing.allocator };
    const allocator = observer.allocator();
    switch (try files.credentialsLoader().load(allocator, 16)) {
        .bytes => |bytes| {
            try std.testing.expectEqualStrings("secret", bytes);
            try std.testing.expectEqual(@as(usize, 1), observer.zero_frees);
            try std.testing.expectEqual(@as(usize, 0), observer.other_frees);
            wipeFree(allocator, bytes);
            try std.testing.expectEqual(@as(usize, 2), observer.zero_frees);
            try std.testing.expectEqual(@as(usize, 0), observer.other_frees);
        },
        else => return error.TestUnexpectedResult,
    }
}
