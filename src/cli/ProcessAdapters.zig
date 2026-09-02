const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config/root.zig");
const persistence = @import("../persistence/root.zig");
const tool = @import("../tool/root.zig");

comptime {
    switch (builtin.os.tag) {
        .macos, .linux, .freebsd, .openbsd, .netbsd, .dragonfly, .illumos => {},
        else => @compileError("cli.ProcessAdapters supports only Zi's Unix product targets"),
    }
}

pub const maximum_cwd_bytes: usize = persistence.Paths.default_max_cwd_bytes;

/// Borrowed view of the exact environment block supplied by std.process.Init.
/// It never consults ambient process state. The block and all its strings must
/// outlive this value and every synchronous interface call. The value is
/// immutable after construction and concurrent reads are safe.
pub const Environment = struct {
    environ: std.process.Environ,

    pub fn init(environ: std.process.Environ) Environment {
        return .{ .environ = environ };
    }

    pub fn fromProcess(init_value: std.process.Init) Environment {
        return .init(init_value.minimal.environ);
    }

    pub fn get(self: *const Environment, name: []const u8) ?[]const u8 {
        if (!validEnvironmentKey(name)) return null;
        return std.process.Environ.getPosix(self.environ, name);
    }

    /// `self` must stay at a stable address for the returned erased view.
    pub fn store(self: *const Environment) config.Store.Environment {
        return .from(self);
    }

    /// `self` must stay at a stable address for the returned erased view.
    pub fn apiKey(self: *const Environment) config.ApiKey.Environment {
        return .from(self);
    }

    pub fn pathInputs(self: *const Environment) config.Loader.PathInputs {
        return .{
            .xdg_config_home = self.get("XDG_CONFIG_HOME"),
            .xdg_state_home = self.get("XDG_STATE_HOME"),
            .xdg_cache_home = self.get("XDG_CACHE_HOME"),
            .home = self.get("HOME"),
        };
    }
};

fn validEnvironmentKey(name: []const u8) bool {
    return name.len != 0 and std.mem.findAny(u8, name, &.{ 0, '=' }) == null;
}

/// Owned process directories derived only from a stable PathInputs snapshot.
/// Each non-null field is a separate allocation and must be released by deinit.
pub const RuntimePaths = struct {
    config_root: ?[]u8,
    state_root: ?[]u8,
    cache_root: ?[]u8,

    pub fn init(
        allocator: std.mem.Allocator,
        inputs: config.Loader.PathInputs,
    ) config.Loader.PathError!RuntimePaths {
        const config_root = try loaderRoot(allocator, inputs, .config);
        errdefer if (config_root) |path| allocator.free(path);
        const state_root = try loaderRoot(allocator, inputs, .state);
        errdefer if (state_root) |path| allocator.free(path);
        const cache_root = try cacheRoot(allocator, inputs);
        return .{
            .config_root = config_root,
            .state_root = state_root,
            .cache_root = cache_root,
        };
    }

    pub fn deinit(self: *RuntimePaths, allocator: std.mem.Allocator) void {
        if (self.config_root) |path| allocator.free(path);
        if (self.state_root) |path| allocator.free(path);
        if (self.cache_root) |path| allocator.free(path);
        self.* = undefined;
    }
};

fn loaderRoot(
    allocator: std.mem.Allocator,
    inputs: config.Loader.PathInputs,
    tier: config.Loader.Tier,
) config.Loader.PathError!?[]u8 {
    const file_path = try config.Loader.buildPath(allocator, tier, inputs);
    defer if (file_path) |path| allocator.free(path);
    const path = file_path orelse return null;
    const separator = std.mem.lastIndexOfScalar(u8, path, '/') orelse unreachable;
    return allocator.dupe(u8, path[0..separator]) catch error.OutOfMemory;
}

fn cacheRoot(
    allocator: std.mem.Allocator,
    inputs: config.Loader.PathInputs,
) config.Loader.PathError!?[]u8 {
    var base = inputs.xdg_cache_home;
    var middle: []const u8 = "";
    if (base == null or base.?.len == 0) {
        base = inputs.home;
        middle = ".cache/";
    }
    const value = base orelse return null;
    if (value.len == 0) return null;
    if (value[0] != '/' or std.mem.indexOfScalar(u8, value, 0) != null or
        !std.unicode.utf8ValidateSlice(value)) return error.InvalidPath;
    const tail_len = 1 + middle.len + "zi".len;
    if (value.len > config.Loader.maximum_path_bytes or
        tail_len > config.Loader.maximum_path_bytes - value.len) return error.PathTooLong;
    const path_len = value.len + tail_len;
    if (path_len >= std.fs.max_path_bytes) return error.PathTooLong;
    return std.fmt.allocPrint(allocator, "{s}/{s}zi", .{ value, middle }) catch error.OutOfMemory;
}

/// Reports whether an explicit file is a terminal through the supplied Io.
/// Probe failures are treated as not-a-terminal, matching POSIX isatty usage.
pub fn isTty(io: std.Io, file: std.Io.File) bool {
    return file.isTty(io) catch false;
}

pub const ReadStdinError = error{ OutOfMemory, TooLarge, ReadFailed, Canceled };

/// Allocator-owned bytes read from an explicit file. This type is move-only.
pub const StdinResult = struct {
    bytes: []u8,

    pub fn deinit(self: *StdinResult, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

/// Reads stdin without consulting ambient I/O and consumes at most max + 1 bytes.
pub fn readStdin(
    allocator: std.mem.Allocator,
    io: std.Io,
    max: usize,
) ReadStdinError!StdinResult {
    return readFile(allocator, io, .stdin(), max);
}

/// Explicit-file form used when stdin is already adapted or injected by tests.
pub fn readFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    max: usize,
) ReadStdinError!StdinResult {
    const capacity = std.math.add(usize, max, 1) catch return error.OutOfMemory;
    const allocation = allocator.alloc(u8, capacity) catch return error.OutOfMemory;
    errdefer allocator.free(allocation);

    var reader_buffer: [1]u8 = undefined;
    var file_reader = std.Io.File.Reader.initStreaming(file, io, &reader_buffer);
    const count = file_reader.interface.readSliceShort(allocation) catch {
        const cause = file_reader.err orelse return error.ReadFailed;
        return switch (cause) {
            error.Canceled => error.Canceled,
            else => error.ReadFailed,
        };
    };
    if (count > max) return error.TooLarge;
    const bytes = allocator.realloc(allocation, count) catch return error.OutOfMemory;
    return .{ .bytes = bytes };
}

/// Creates the final cache directory below its trusted parent and rejects a final symlink.
pub fn ensurePrivateCacheRoot(io: std.Io, cache_root: []const u8) !void {
    const parts = try validatePrivateCacheRoot(cache_root);
    const parent_path = parts.parent;
    const name = parts.name;
    try std.Io.Dir.cwd().createDirPath(io, parent_path);
    const parent = try std.Io.Dir.cwd().openDir(io, parent_path, .{});
    defer parent.close(io);
    parent.createDir(io, name, .fromMode(0o700)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const directory = try parent.openDir(io, name, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer directory.close(io);
    try directory.setPermissions(io, .fromMode(0o700));
}

const CacheRootParts = struct {
    parent: []const u8,
    name: []const u8,
};

fn validatePrivateCacheRoot(cache_root: []const u8) error{InvalidPath}!CacheRootParts {
    if (cache_root.len == 0 or cache_root.len >= std.fs.max_path_bytes or
        !std.fs.path.isAbsolute(cache_root) or std.mem.findScalar(u8, cache_root, 0) != null or
        !std.unicode.utf8ValidateSlice(cache_root) or std.mem.eql(u8, cache_root, "/"))
    {
        return error.InvalidPath;
    }
    const parent = std.fs.path.dirname(cache_root) orelse return error.InvalidPath;
    const name = std.fs.path.basename(cache_root);
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) {
        return error.InvalidPath;
    }
    return .{ .parent = parent, .name = name };
}

pub const CwdError = error{ OutOfMemory, CwdTooLong, InvalidCwd, CurrentDirUnlinked, Canceled, Unexpected };

/// Returns an allocator-owned canonical current directory using only `io`.
/// The result is bounded for the persistence path contracts.
pub fn acquireCwd(allocator: std.mem.Allocator, io: std.Io) CwdError![]u8 {
    var buffer: [maximum_cwd_bytes + 1]u8 = undefined;
    const count = std.process.currentPath(io, &buffer) catch |err| switch (err) {
        error.NameTooLong => return error.CwdTooLong,
        error.CurrentDirUnlinked => return error.CurrentDirUnlinked,
        error.Canceled => return error.Canceled,
        error.Unexpected => return error.Unexpected,
    };
    if (count > maximum_cwd_bytes) return error.CwdTooLong;
    const cwd = buffer[0..count];
    if (cwd.len == 0 or cwd[0] != '/' or std.mem.findScalar(u8, cwd, 0) != null or
        !std.unicode.utf8ValidateSlice(cwd)) return error.InvalidCwd;
    return allocator.dupe(u8, cwd) catch error.OutOfMemory;
}

/// Address-stable adapter over one explicit Io value. Keep this object alive
/// and at the same address while any returned Clock or Poller is in use. Calls
/// are intended for TaskRegistry's single registry thread.
pub const TaskTime = struct {
    io: std.Io,

    pub fn init(io: std.Io) TaskTime {
        return .{ .io = io };
    }

    pub fn nowMs(self: *TaskTime) i64 {
        return millisecondsSaturated(std.Io.Clock.awake.now(self.io).nanoseconds);
    }

    pub fn wait(self: *TaskTime, milliseconds: u64) void {
        if (milliseconds == 0) return;
        const bounded: i64 = @intCast(@min(milliseconds, @as(u64, std.math.maxInt(i64))));
        std.Io.sleep(self.io, .fromMilliseconds(bounded), .awake) catch self.io.recancel();
    }

    pub fn clock(self: *TaskTime) tool.TaskRegistry.Clock {
        return .from(self);
    }

    pub fn poller(self: *TaskTime) tool.TaskRegistry.Poller {
        return .from(self);
    }
};

fn millisecondsSaturated(nanoseconds: i96) i64 {
    const milliseconds = @divTrunc(nanoseconds, std.time.ns_per_ms);
    return std.math.cast(i64, milliseconds) orelse
        if (milliseconds < 0) std.math.minInt(i64) else std.math.maxInt(i64);
}

/// Address-stable cryptographic random adapter. The copied Io value remains
/// valid while its underlying implementation remains valid. std.Io secure
/// random is thread-safe, so fill and uuidV4 may be called concurrently.
pub const Random = struct {
    io: std.Io,

    pub fn init(io: std.Io) Random {
        return .{ .io = io };
    }

    pub fn nonceSource(self: *Random) persistence.PrivateFileStore.NonceSource {
        return .{ .context = self, .fill_fn = fill };
    }

    pub fn stateNonceSource(self: *Random) config.StateWriter.NonceSource {
        return .{ .context = self, .fill_fn = fillState };
    }

    pub fn configNonceSource(self: *Random) config.ConfigWriter.NonceSource {
        return .{ .context = self, .fill_fn = fillState };
    }

    fn fillState(context: *anyopaque, bytes: []u8) config.StateWriter.NonceError!void {
        const self: *Random = @ptrCast(@alignCast(context));
        std.Io.randomSecure(self.io, bytes) catch |err| switch (err) {
            error.Canceled, error.EntropyUnavailable => return error.Failed,
        };
    }

    fn fill(context: *anyopaque, bytes: []u8) persistence.PrivateFileStore.Error!void {
        const self: *Random = @ptrCast(@alignCast(context));
        std.Io.randomSecure(self.io, bytes) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.EntropyUnavailable => return error.IoFailure,
        };
    }

    pub fn uuidV4(self: *Random) persistence.PrivateFileStore.Error![16]u8 {
        var uuid: [16]u8 = undefined;
        try fill(self, &uuid);
        uuid[6] = (uuid[6] & 0x0f) | 0x40;
        uuid[8] = (uuid[8] & 0x3f) | 0x80;
        return uuid;
    }
};

/// Saturating Unix epoch seconds from the explicit Io wall clock.
pub fn wallEpochSeconds(io: std.Io) i64 {
    const seconds = @divFloor(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s);
    return std.math.cast(i64, seconds) orelse
        if (seconds < 0) std.math.minInt(i64) else std.math.maxInt(i64);
}

pub fn wallTimestamp(io: std.Io) persistence.Paths.Timestamp {
    return .{ .epoch_seconds = wallEpochSeconds(io) };
}

fn testEnviron(entries: []const [*:0]const u8) std.process.Environ {
    return .{ .block = .{ .slice = @ptrCast(entries) } };
}

test "injected environment is borrowed exact and derives path inputs" {
    const entries = [_][*:0]const u8{
        "HOME=/injected",
        "XDG_CONFIG_HOME=",
        "XDG_STATE_HOME=/state",
        "SECRET=borrowed",
    };
    var environment = Environment.init(testEnviron(&entries));
    try std.testing.expectEqualStrings("borrowed", environment.store().get("SECRET").?);
    try std.testing.expectEqualStrings("borrowed", environment.apiKey().get("SECRET").?);
    try std.testing.expect(environment.get("MISSING") == null);
    try std.testing.expect(environment.get("") == null);
    try std.testing.expect(environment.get("BAD=KEY") == null);
    try std.testing.expect(environment.get("BAD\x00KEY") == null);
    const long_key = "LONG_" ++ "x" ** 300;
    const long_entry = long_key ++ "=long-value";
    const long_entries = [_][*:0]const u8{long_entry};
    var long_environment = Environment.init(testEnviron(&long_entries));
    try std.testing.expectEqualStrings("long-value", long_environment.get(long_key).?);

    const inputs = environment.pathInputs();
    try std.testing.expectEqualStrings("", inputs.xdg_config_home.?);
    try std.testing.expectEqualStrings("/state", inputs.xdg_state_home.?);
    try std.testing.expectEqualStrings("/injected", inputs.home.?);
    const path = (try config.Loader.configPath(std.testing.allocator, inputs)).?;
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/injected/.config/zi/config.json", path);
}

test "absent and empty environment blocks do not fall back to ambient state" {
    var empty = Environment.init(testEnviron(&.{}));
    try std.testing.expect(empty.get("HOME") == null);
    const entries = [_][*:0]const u8{"HOME="};
    var present_empty = Environment.init(testEnviron(&entries));
    try std.testing.expectEqualStrings("", present_empty.get("HOME").?);
    try std.testing.expect((try config.Loader.configPath(std.testing.allocator, present_empty.pathInputs())) == null);
}

test "injected path inputs preserve bounds and allocator errors" {
    const long_value = "/" ++ "x" ** config.Loader.maximum_path_bytes;
    const long_entry = "XDG_CONFIG_HOME=" ++ long_value;
    const long_entries = [_][*:0]const u8{long_entry};
    var long_environment = Environment.init(testEnviron(&long_entries));
    try std.testing.expectError(
        error.PathTooLong,
        config.Loader.configPath(std.testing.allocator, long_environment.pathInputs()),
    );

    const entries = [_][*:0]const u8{"XDG_CONFIG_HOME=/cfg"};
    var environment = Environment.init(testEnviron(&entries));
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        config.Loader.configPath(failing.allocator(), environment.pathInputs()),
    );
}

test "runtime paths use injected XDG roots" {
    const config_entry = "XDG_CONFIG_HOME=/cfg";
    const state_entry = "XDG_STATE_HOME=/state";
    const cache_entry = "XDG_CACHE_HOME=/cache";
    const entries = [_][*:0]const u8{ config_entry, state_entry, cache_entry, "HOME=/ignored" };
    var environment = Environment.init(testEnviron(&entries));
    var paths = try RuntimePaths.init(std.testing.allocator, environment.pathInputs());
    defer paths.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("/cfg/zi", paths.config_root.?);
    try std.testing.expectEqualStrings("/state/zi", paths.state_root.?);
    try std.testing.expectEqualStrings("/cache/zi", paths.cache_root.?);
}

test "runtime paths apply empty XDG fallback and unavailable HOME" {
    const fallback_entries = [_][*:0]const u8{
        "XDG_CONFIG_HOME=",
        "XDG_STATE_HOME=",
        "XDG_CACHE_HOME=",
        "HOME=/home/me",
    };
    var fallback_environment = Environment.init(testEnviron(&fallback_entries));
    var fallback = try RuntimePaths.init(std.testing.allocator, fallback_environment.pathInputs());
    defer fallback.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("/home/me/.config/zi", fallback.config_root.?);
    try std.testing.expectEqualStrings("/home/me/.local/state/zi", fallback.state_root.?);
    try std.testing.expectEqualStrings("/home/me/.cache/zi", fallback.cache_root.?);

    const no_home_entries = [_][*:0]const u8{
        "XDG_CONFIG_HOME=",
        "XDG_STATE_HOME=",
        "XDG_CACHE_HOME=",
    };
    var no_home_environment = Environment.init(testEnviron(&no_home_entries));
    var unavailable = try RuntimePaths.init(std.testing.allocator, no_home_environment.pathInputs());
    defer unavailable.deinit(std.testing.allocator);
    try std.testing.expect(unavailable.config_root == null);
    try std.testing.expect(unavailable.state_root == null);
    try std.testing.expect(unavailable.cache_root == null);
}

fn exerciseRuntimePathAllocations(allocator: std.mem.Allocator) !void {
    var paths = try RuntimePaths.init(allocator, .{
        .xdg_config_home = "/config",
        .xdg_state_home = "/state",
        .xdg_cache_home = "/cache",
        .home = "/home",
    });
    defer paths.deinit(allocator);
}

test "cache paths reserve the physical sentinel byte before allocation or I/O" {
    const suffix_len = "/zi".len;
    if (std.fs.max_path_bytes <= suffix_len or
        std.fs.max_path_bytes > config.Loader.maximum_path_bytes) return;

    const last_base_len = std.fs.max_path_bytes - 1 - suffix_len;
    const last_base = try std.testing.allocator.alloc(u8, last_base_len);
    defer std.testing.allocator.free(last_base);
    @memset(last_base, 'x');
    last_base[0] = '/';
    const last_root = (try cacheRoot(std.testing.allocator, .{ .xdg_cache_home = last_base })).?;
    defer std.testing.allocator.free(last_root);
    try std.testing.expectEqual(std.fs.max_path_bytes - 1, last_root.len);
    _ = try validatePrivateCacheRoot(last_root);

    const boundary_base = try std.testing.allocator.alloc(u8, last_base_len + 1);
    defer std.testing.allocator.free(boundary_base);
    @memset(boundary_base, 'x');
    boundary_base[0] = '/';
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.PathTooLong,
        cacheRoot(failing.allocator(), .{ .xdg_cache_home = boundary_base }),
    );

    const boundary_root = try std.testing.allocator.alloc(u8, std.fs.max_path_bytes);
    defer std.testing.allocator.free(boundary_root);
    @memset(boundary_root, 'x');
    boundary_root[0] = '/';
    try std.testing.expectError(error.InvalidPath, validatePrivateCacheRoot(boundary_root));
}

test "runtime paths validate cache inputs bounds and allocation failures" {
    try std.testing.expectError(
        error.InvalidPath,
        RuntimePaths.init(std.testing.allocator, .{ .xdg_cache_home = "relative" }),
    );
    try std.testing.expectError(
        error.InvalidPath,
        RuntimePaths.init(std.testing.allocator, .{ .xdg_cache_home = "/bad\x00path" }),
    );
    try std.testing.expectError(
        error.InvalidPath,
        RuntimePaths.init(std.testing.allocator, .{ .xdg_cache_home = "/\xff" }),
    );
    const long = "/" ++ "x" ** config.Loader.maximum_path_bytes;
    try std.testing.expectError(
        error.PathTooLong,
        RuntimePaths.init(std.testing.allocator, .{ .xdg_cache_home = long }),
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseRuntimePathAllocations,
        .{},
    );
}

fn writeOnlyFile(directory: std.Io.Dir, name: []const u8) !std.Io.File {
    try directory.writeFile(std.testing.io, .{ .sub_path = name, .data = "unreadable" });
    return directory.openFile(std.testing.io, name, .{ .mode = .write_only });
}

test "explicit file stdin read is bounded owned and reports failures" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "input", .data = "prompt" });

    const input = try tmp.dir.openFile(std.testing.io, "input", .{});
    defer input.close(std.testing.io);
    var result = try readFile(std.testing.allocator, std.testing.io, input, 6);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("prompt", result.bytes);
    try std.testing.expect(!isTty(std.testing.io, input));

    const oversized = try tmp.dir.openFile(std.testing.io, "input", .{});
    defer oversized.close(std.testing.io);
    try std.testing.expectError(
        error.TooLarge,
        readFile(std.testing.allocator, std.testing.io, oversized, 5),
    );

    const unreadable = try writeOnlyFile(tmp.dir, "write-only");
    defer unreadable.close(std.testing.io);
    try std.testing.expectError(
        error.ReadFailed,
        readFile(std.testing.allocator, std.testing.io, unreadable, 20),
    );

    const oom_input = try tmp.dir.openFile(std.testing.io, "input", .{});
    defer oom_input.close(std.testing.io);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        readFile(failing.allocator(), std.testing.io, oom_input, 6),
    );
    try std.testing.expectError(
        error.OutOfMemory,
        readFile(std.testing.allocator, std.testing.io, oom_input, std.math.maxInt(usize)),
    );
}

test "explicit file stdin read preserves cancellation" {
    var descriptors: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&descriptors));
    const read_end: std.Io.File = .{ .handle = descriptors[0], .flags = .{ .nonblocking = false } };
    defer read_end.close(std.testing.io);
    const write_end: std.Io.File = .{ .handle = descriptors[1], .flags = .{ .nonblocking = false } };
    defer write_end.close(std.testing.io);

    var future = std.testing.io.async(
        readFile,
        .{ std.testing.allocator, std.testing.io, read_end, 16 },
    );
    try std.testing.expectError(error.Canceled, future.cancel(std.testing.io));
}

test "millisecond conversion saturates both directions" {
    try std.testing.expectEqual(std.math.maxInt(i64), millisecondsSaturated(std.math.maxInt(i96)));
    try std.testing.expectEqual(std.math.minInt(i64), millisecondsSaturated(std.math.minInt(i96)));
    try std.testing.expectEqual(@as(i64, 12), millisecondsSaturated(12 * std.time.ns_per_ms + 999));
    try std.testing.expectEqual(@as(i64, -12), millisecondsSaturated(-12 * std.time.ns_per_ms - 999));
}

test "cwd is owned bounded and reports allocation failure" {
    const cwd = try acquireCwd(std.testing.allocator, std.testing.io);
    defer std.testing.allocator.free(cwd);
    try std.testing.expect(cwd.len <= maximum_cwd_bytes);
    try std.testing.expect(cwd[0] == '/');

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, acquireCwd(failing.allocator(), std.testing.io));
}

test "secure random UUIDs set RFC 4122 version and variant bits and differ" {
    var random = Random.init(std.testing.io);
    const first = try random.uuidV4();
    const second = try random.uuidV4();
    try std.testing.expectEqual(@as(u8, 0x40), first[6] & 0xf0);
    try std.testing.expectEqual(@as(u8, 0x80), first[8] & 0xc0);
    try std.testing.expect(!std.mem.eql(u8, &first, &second));

    var nonce: [32]u8 = undefined;
    try random.nonceSource().fill(&nonce);
    try std.testing.expect(!std.mem.allEqual(u8, &nonce, 0));
}

test "private cache root creates mode 0700 and rejects file and symlink finals" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try acquireCwd(std.testing.allocator, std.testing.io);
    defer std.testing.allocator.free(cwd);
    const base = try std.fs.path.join(
        std.testing.allocator,
        &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path },
    );
    defer std.testing.allocator.free(base);
    const cache = try std.fs.path.join(std.testing.allocator, &.{ base, "nested", "zi" });
    defer std.testing.allocator.free(cache);

    try ensurePrivateCacheRoot(std.testing.io, cache);
    try ensurePrivateCacheRoot(std.testing.io, cache);
    const directory = try std.Io.Dir.cwd().openDir(std.testing.io, cache, .{ .iterate = true });
    defer directory.close(std.testing.io);
    const stat = try directory.stat(std.testing.io);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), stat.permissions.toMode() & 0o777);

    const file_path = try std.fs.path.join(std.testing.allocator, &.{ base, "file" });
    defer std.testing.allocator.free(file_path);
    var file = try std.Io.Dir.cwd().createFile(std.testing.io, file_path, .{});
    file.close(std.testing.io);
    try std.testing.expectError(error.NotDir, ensurePrivateCacheRoot(std.testing.io, file_path));

    const target_path = try std.fs.path.join(std.testing.allocator, &.{ base, "target" });
    defer std.testing.allocator.free(target_path);
    try std.Io.Dir.cwd().createDir(std.testing.io, target_path, .fromMode(0o700));
    const link_path = try std.fs.path.join(std.testing.allocator, &.{ base, "link" });
    defer std.testing.allocator.free(link_path);
    try std.Io.Dir.cwd().symLink(std.testing.io, target_path, link_path, .{ .is_directory = true });
    try std.testing.expectError(error.NotDir, ensurePrivateCacheRoot(std.testing.io, link_path));
    try std.testing.expectError(error.InvalidPath, ensurePrivateCacheRoot(std.testing.io, "relative"));
    try std.testing.expectError(error.InvalidPath, ensurePrivateCacheRoot(std.testing.io, "/"));
    try std.testing.expectError(error.InvalidPath, ensurePrivateCacheRoot(std.testing.io, "/tmp/zi\x00bad"));
}
