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
            .home = self.get("HOME"),
        };
    }
};

fn validEnvironmentKey(name: []const u8) bool {
    return name.len != 0 and std.mem.findAny(u8, name, &.{ 0, '=' }) == null;
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
