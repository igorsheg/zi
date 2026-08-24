const std = @import("std");
const PrivateFileStore = @import("PrivateFileStore.zig");

pub const managed_name = "catalog.json";
pub const max_file_size: usize = 32 * 1024 * 1024;
pub const max_root_bytes: usize = 4096;
pub const seconds_per_day: u64 = 86_400;
pub const stale_warning_days: u64 = 30;

pub const Error = error{ OutOfMemory, InvalidRoot };

/// An explicit wall clock. The context must outlive the cache.
pub const Clock = struct {
    context: ?*anyopaque = null,
    now_fn: *const fn (std.Io, ?*anyopaque) i64 = systemNow,

    pub fn now(clock: Clock, io: std.Io) i64 {
        return clock.now_fn(io, clock.context);
    }

    pub const system: Clock = .{};

    fn systemNow(io: std.Io, _: ?*anyopaque) i64 {
        const nanoseconds = std.Io.Clock.real.now(io).nanoseconds;
        const seconds = @divFloor(nanoseconds, std.time.ns_per_s);
        return std.math.cast(i64, seconds) orelse if (seconds < 0) std.math.minInt(i64) else std.math.maxInt(i64);
    }
};

pub const ReadFailure = enum { not_regular, io_failure, canceled };
const RootError = error{ NotRegular, IoFailure, Canceled };

pub const Cached = struct {
    bytes: []u8,
    modified_seconds: i64,
    age_seconds: u64,
};

/// Move-only result. `.cached.bytes` belongs to the result.
pub const ReadResult = union(enum) {
    missing,
    oversize: u64,
    unreadable: ReadFailure,
    cached: Cached,

    pub fn deinit(result: *ReadResult, allocator: std.mem.Allocator) void {
        switch (result.*) {
            .cached => |cached| allocator.free(cached.bytes),
            else => {},
        }
        result.* = undefined;
    }
};

pub const RefreshDecision = enum { disabled, fresh, fetch };

pub const RefreshPolicy = struct {
    url: []const u8,
    refresh_ms: u64,
};

/// Move-only inspection result. The cache remains readable when refresh is disabled.
pub const Inspection = struct {
    cache: ReadResult,
    refresh: RefreshDecision,
    /// Present only when raw cache age exceeds 30 days; the reported value is floored.
    stale_days: ?u64,

    pub fn deinit(result: *Inspection, allocator: std.mem.Allocator) void {
        result.cache.deinit(allocator);
        result.* = undefined;
    }
};

pub const RefreshPlan = struct {
    decision: RefreshDecision,
    stale_days: ?u64 = null,
};

pub const MutationCause = enum {
    too_large,
    busy,
    not_regular,
    io_failure,
    out_of_memory,
    canceled,
    poisoned,
};

pub const OrphanName = struct {
    buffer: [PrivateFileStore.max_name_size * 2]u8 = @splat(0),
    len: usize = 0,

    pub fn bytes(name: *const OrphanName) []const u8 {
        return name.buffer[0..name.len];
    }
};

pub const MutationFailure = struct {
    cause: MutationCause,
    orphan_name: ?OrphanName,
};

pub const ReplaceResult = union(enum) {
    published,
    not_published: MutationFailure,
    uncertain: MutationFailure,
};

/// Owns only the normalized cache-root bytes. Existing root and parent
/// components are trusted private configuration. No XDG or process state is read.
pub const CatalogCache = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cache_root: []u8,
    clock: Clock,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        cache_root: []const u8,
        clock: Clock,
    ) Error!CatalogCache {
        if (!validRoot(cache_root)) return error.InvalidRoot;
        return .{
            .allocator = allocator,
            .io = io,
            .cache_root = allocator.dupe(u8, cache_root) catch return error.OutOfMemory,
            .clock = clock,
        };
    }

    pub fn deinit(cache: *CatalogCache) void {
        cache.allocator.free(cache.cache_root);
        cache.* = undefined;
    }

    pub fn read(cache: CatalogCache, allocator: std.mem.Allocator) Error!ReadResult {
        const root = openRoot(cache.io, cache.cache_root) catch |err| return .{
            .unreadable = rootReadFailure(err),
        };
        defer root.close(cache.io);
        const result = PrivateFileStore.Store.init(cache.io, root).readLimitedStat(
            allocator,
            managed_name,
            max_file_size,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TooLarge => unreachable,
            error.NotRegular => return .{ .unreadable = .not_regular },
            error.Canceled => return .{ .unreadable = .canceled },
            else => return .{ .unreadable = .io_failure },
        };
        return switch (result) {
            .missing => .missing,
            .oversize => |size| .{ .oversize = size },
            .file => |value| .{ .cached = .{
                .bytes = value.bytes,
                .modified_seconds = timestampSeconds(value.stat.mtime),
                .age_seconds = ageSeconds(cache.clock.now(cache.io), timestampSeconds(value.stat.mtime)),
            } },
        };
    }

    pub fn inspect(
        cache: CatalogCache,
        allocator: std.mem.Allocator,
        policy: RefreshPolicy,
    ) Error!Inspection {
        const freshness = cache.statFreshness(policy);
        var read_result = try cache.read(allocator);
        errdefer read_result.deinit(allocator);
        return .{
            .cache = read_result,
            .refresh = freshness.decision,
            .stale_days = freshness.stale_days,
        };
    }

    /// Uses metadata only. It never opens or allocates the catalog body.
    pub fn planRefresh(cache: CatalogCache, policy: RefreshPolicy) RefreshPlan {
        return cache.statFreshness(policy);
    }

    fn statFreshness(cache: CatalogCache, policy: RefreshPolicy) RefreshPlan {
        if (policy.url.len == 0 or policy.refresh_ms == 0) return .{ .decision = .disabled };
        const root = openRoot(cache.io, cache.cache_root) catch return .{ .decision = .fetch };
        defer root.close(cache.io);
        const stat = root.statFile(cache.io, managed_name, .{ .follow_symlinks = false }) catch
            return .{ .decision = .fetch };
        if (stat.kind != .file or stat.nlink != 1) return .{ .decision = .fetch };
        const modified = timestampSeconds(stat.mtime);
        const raw_age = rawAgeSeconds(cache.clock.now(cache.io), modified);
        const max_age_seconds: i128 = policy.refresh_ms / 1000;
        if (raw_age < max_age_seconds) return .{ .decision = .fresh };
        const warning_threshold: i128 = stale_warning_days * seconds_per_day;
        return .{
            .decision = .fetch,
            .stale_days = if (raw_age > warning_threshold)
                @intCast(@divFloor(raw_age, seconds_per_day))
            else
                null,
        };
    }

    /// Candidate schema validation belongs to the caller. A pre-publication
    /// failure leaves the previous catalog in place.
    pub fn replace(
        cache: CatalogCache,
        candidate: []const u8,
        nonce_source: PrivateFileStore.NonceSource,
    ) ReplaceResult {
        return cache.replaceWithOps(candidate, nonce_source, .standard);
    }

    pub fn replaceWithOps(
        cache: CatalogCache,
        candidate: []const u8,
        nonce_source: PrivateFileStore.NonceSource,
        commit_ops: PrivateFileStore.CommitOps,
    ) ReplaceResult {
        if (candidate.len > max_file_size) return .{ .not_published = .{
            .cause = .too_large,
            .orphan_name = null,
        } };
        const root = openRoot(cache.io, cache.cache_root) catch |err| return .{ .not_published = .{
            .cause = readFailureCause(rootReadFailure(err)),
            .orphan_name = null,
        } };
        defer root.close(cache.io);
        const store = PrivateFileStore.Store.init(cache.io, root);
        var transaction = store.begin(managed_name) catch |err| return .{ .not_published = .{
            .cause = mutationCause(err),
            .orphan_name = null,
        } };
        defer transaction.deinit();
        transaction.replaceLimitedWithOps(candidate, max_file_size, nonce_source, commit_ops) catch |err| {
            const failure: MutationFailure = .{
                .cause = mutationCause(err),
                .orphan_name = captureOrphan(&transaction),
            };
            return if (transaction.mutationState() == .uncertain)
                .{ .uncertain = failure }
            else
                .{ .not_published = failure };
        };
        return .published;
    }
};

fn openRoot(io: std.Io, path: []const u8) RootError!std.Io.Dir {
    return std.Io.Dir.openDir(.cwd(), io, path, .{
        .iterate = false,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.Canceled => error.Canceled,
        error.SymLinkLoop, error.NotDir => error.NotRegular,
        else => error.IoFailure,
    };
}

fn validRoot(path: []const u8) bool {
    if (path.len == 0 or path.len > max_root_bytes or path[0] != '/' or
        std.mem.findScalar(u8, path, 0) != null or !std.unicode.utf8ValidateSlice(path)) return false;
    if (path.len > 1 and path[path.len - 1] == '/') return false;
    var components = std.mem.splitScalar(u8, path[1..], '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

fn timestampSeconds(timestamp: std.Io.Timestamp) i64 {
    const seconds = @divFloor(timestamp.nanoseconds, std.time.ns_per_s);
    return std.math.cast(i64, seconds) orelse if (seconds < 0) std.math.minInt(i64) else std.math.maxInt(i64);
}

fn ageSeconds(now: i64, modified: i64) u64 {
    if (now <= modified) return 0;
    return @intCast(@as(i128, now) - @as(i128, modified));
}

fn rawAgeSeconds(now: i64, modified: i64) i128 {
    return @as(i128, now) - @as(i128, modified);
}

fn rootReadFailure(err: RootError) ReadFailure {
    return switch (err) {
        error.NotRegular => .not_regular,
        error.IoFailure => .io_failure,
        error.Canceled => .canceled,
    };
}

fn readFailureCause(failure: ReadFailure) MutationCause {
    return switch (failure) {
        .not_regular => .not_regular,
        .io_failure => .io_failure,
        .canceled => .canceled,
    };
}

fn mutationCause(err: PrivateFileStore.Error) MutationCause {
    return switch (err) {
        error.TooLarge => .too_large,
        error.Busy => .busy,
        error.NotRegular, error.Invalid => .not_regular,
        error.IoFailure => .io_failure,
        error.OutOfMemory => .out_of_memory,
        error.Canceled => .canceled,
        error.Poisoned => .poisoned,
    };
}

fn captureOrphan(transaction: *const PrivateFileStore.Transaction) ?OrphanName {
    const bytes = transaction.orphanName() orelse return null;
    var result: OrphanName = .{};
    result.len = bytes.len;
    @memcpy(result.buffer[0..bytes.len], bytes);
    return result;
}

fn testNonce() PrivateFileStore.NonceSource {
    const Source = struct {
        var value: u8 = 0;
        fn fill(_: *anyopaque, bytes: []u8) PrivateFileStore.Error!void {
            @memset(bytes, value);
            value +%= 1;
        }
    };
    return .{ .context = undefined, .fill_fn = Source.fill };
}

fn fixedClock(seconds: *i64) Clock {
    const Fixed = struct {
        fn now(_: std.Io, context: ?*anyopaque) i64 {
            const value: *i64 = @ptrCast(@alignCast(context.?));
            return value.*;
        }
    };
    return .{ .context = seconds, .now_fn = Fixed.now };
}

test "fresh stale missing and disabled decisions" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root_path = try temporary.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root_path);
    var now: i64 = 1000;
    var cache = try CatalogCache.init(std.testing.allocator, io, root_path, fixedClock(&now));
    defer cache.deinit();

    var missing = try cache.inspect(std.testing.allocator, .{ .url = "https://example", .refresh_ms = 10_000 });
    defer missing.deinit(std.testing.allocator);
    try std.testing.expect(missing.cache == .missing);
    try std.testing.expectEqual(RefreshDecision.fetch, missing.refresh);

    try std.testing.expect(cache.replace("{}", testNonce()) == .published);
    var fresh = try cache.inspect(std.testing.allocator, .{ .url = "https://example", .refresh_ms = 10_000 });
    defer fresh.deinit(std.testing.allocator);
    try std.testing.expectEqual(RefreshDecision.fresh, fresh.refresh);

    try std.testing.expect(fresh.stale_days == null);

    now = fresh.cache.cached.modified_seconds + @as(i64, @intCast(stale_warning_days * seconds_per_day + 1));
    var stale = try cache.inspect(std.testing.allocator, .{ .url = "https://example", .refresh_ms = 10_000 });
    defer stale.deinit(std.testing.allocator);
    try std.testing.expectEqual(RefreshDecision.fetch, stale.refresh);
    try std.testing.expectEqual(@as(u64, 30), stale.stale_days.?);

    var disabled = try cache.inspect(std.testing.allocator, .{ .url = "", .refresh_ms = 10_000 });
    defer disabled.deinit(std.testing.allocator);
    try std.testing.expectEqual(RefreshDecision.disabled, disabled.refresh);
    try std.testing.expect(disabled.cache == .cached);
    try std.testing.expect(disabled.stale_days == null);

    var refresh_zero = try cache.inspect(std.testing.allocator, .{ .url = "https://example", .refresh_ms = 0 });
    defer refresh_zero.deinit(std.testing.allocator);
    try std.testing.expectEqual(RefreshDecision.disabled, refresh_zero.refresh);
    try std.testing.expect(refresh_zero.stale_days == null);
}

test "subsecond refresh truncates to seconds and future mtime is fresh" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root_path = try temporary.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root_path);
    var now: i64 = 0;
    var cache = try CatalogCache.init(std.testing.allocator, io, root_path, fixedClock(&now));
    defer cache.deinit();
    try std.testing.expect(cache.replace("{}", testNonce()) == .published);
    var baseline = try cache.read(std.testing.allocator);
    const modified = baseline.cached.modified_seconds;
    baseline.deinit(std.testing.allocator);

    now = modified;
    var age_zero = try cache.inspect(std.testing.allocator, .{ .url = "url", .refresh_ms = 1 });
    defer age_zero.deinit(std.testing.allocator);
    try std.testing.expectEqual(RefreshDecision.fetch, age_zero.refresh);
    now = modified + 1;
    var age_one = try cache.inspect(std.testing.allocator, .{ .url = "url", .refresh_ms = 1 });
    defer age_one.deinit(std.testing.allocator);
    try std.testing.expectEqual(RefreshDecision.fetch, age_one.refresh);
    now = modified - 1;
    var future = try cache.inspect(std.testing.allocator, .{ .url = "url", .refresh_ms = 1 });
    defer future.deinit(std.testing.allocator);
    try std.testing.expectEqual(RefreshDecision.fresh, future.refresh);
    try std.testing.expect(future.stale_days == null);
}

test "exact size boundary and oversized read are typed" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root_path = try temporary.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root_path);
    var now: i64 = 0;
    var cache = try CatalogCache.init(std.testing.allocator, io, root_path, fixedClock(&now));
    defer cache.deinit();
    const bytes = try std.testing.allocator.alloc(u8, max_file_size);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 'x');
    try std.testing.expect(cache.replace(bytes, testNonce()) == .published);
    var read = try cache.read(std.testing.allocator);
    defer read.deinit(std.testing.allocator);
    try std.testing.expectEqual(max_file_size, read.cached.bytes.len);

    const file = try temporary.dir.openFile(io, managed_name, .{ .mode = .read_write, .follow_symlinks = false });
    try file.setLength(io, max_file_size + 1);
    file.close(io);
    var oversized = try cache.read(std.testing.allocator);
    defer oversized.deinit(std.testing.allocator);
    try std.testing.expect(oversized == .oversize);
    const stat = try temporary.dir.statFile(io, managed_name, .{ .follow_symlinks = false });
    now = timestampSeconds(stat.mtime);
    var inspected = try cache.inspect(std.testing.allocator, .{ .url = "url", .refresh_ms = 10_000 });
    defer inspected.deinit(std.testing.allocator);
    try std.testing.expect(inspected.cache == .oversize);
    try std.testing.expectEqual(RefreshDecision.fresh, inspected.refresh);
}

test "failed write preserves old catalog and symlinks are unreadable" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root_path = try temporary.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root_path);
    var now: i64 = 0;
    var cache = try CatalogCache.init(std.testing.allocator, io, root_path, fixedClock(&now));
    defer cache.deinit();
    try std.testing.expect(cache.replace("old", testNonce()) == .published);
    const Fail = struct {
        fn write(_: std.Io, _: ?*anyopaque, _: std.Io.File, _: []const u8) PrivateFileStore.Error!void {
            return error.IoFailure;
        }
    };
    const failed = cache.replaceWithOps("new", testNonce(), .{ .write_fn = Fail.write });
    try std.testing.expect(failed == .not_published);
    var old = try cache.read(std.testing.allocator);
    defer old.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("old", old.cached.bytes);

    try temporary.dir.deleteFile(io, managed_name);
    try temporary.dir.symLink(io, "target", managed_name, .{});
    var linked = try cache.read(std.testing.allocator);
    defer linked.deinit(std.testing.allocator);
    try std.testing.expectEqual(ReadFailure.not_regular, linked.unreadable);
}

fn readAllocationExercise(allocator: std.mem.Allocator, cache: *CatalogCache) !void {
    var result = try cache.read(allocator);
    defer result.deinit(allocator);
}

fn inspectAllocationExercise(allocator: std.mem.Allocator, cache: *CatalogCache) !void {
    var result = try cache.inspect(allocator, .{ .url = "url", .refresh_ms = 1000 });
    defer result.deinit(allocator);
}

fn allocationExercise(allocator: std.mem.Allocator) !void {
    var now: i64 = 0;
    var cache = try CatalogCache.init(allocator, std.testing.io, "/trusted/cache", fixedClock(&now));
    cache.deinit();
}

test "root validation and allocation failures" {
    var now: i64 = 0;
    try std.testing.expectError(
        error.InvalidRoot,
        CatalogCache.init(std.testing.allocator, std.testing.io, "/a/../b", fixedClock(&now)),
    );
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationExercise, .{});

    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root_path = try temporary.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root_path);
    var cache = try CatalogCache.init(std.testing.allocator, io, root_path, fixedClock(&now));
    defer cache.deinit();
    try std.testing.expect(cache.replace("moderate fixture", testNonce()) == .published);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        readAllocationExercise,
        .{&cache},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        inspectAllocationExercise,
        .{&cache},
    );
}
