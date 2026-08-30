//! Pure synchronous catalog orchestration. This primitive does not retry and
//! does not own a background task, timer, or shutdown lifecycle.

const std = @import("std");
const ai = @import("ai/root.zig");
const persistence = @import("persistence/root.zig");

pub const request_timeout_ms: u64 = 30_000;
pub const maximum_response_bytes: usize = ai.ModelCatalog.maximum_input_bytes;

pub const Method = enum { get };

pub const GetDescriptor = struct {
    method: Method = .get,
    url: []const u8,
    timeout_ms: u64 = request_timeout_ms,
    max_response_bytes: usize = maximum_response_bytes,
};

pub const TransportFailure = enum { failed, canceled };

/// Move-only successful HTTP response. Non-empty `body` was allocated with the
/// callback allocator and belongs to this value.
pub const HttpResponse = struct {
    status: u16,
    body: []u8,

    pub fn deinit(response: *HttpResponse, allocator: std.mem.Allocator) void {
        allocator.free(response.body);
        response.* = undefined;
    }
};

/// A transport failure has no HTTP status or body.
pub const FetchResult = union(enum) {
    response: HttpResponse,
    transport: TransportFailure,

    pub fn deinit(result: *FetchResult, allocator: std.mem.Allocator) void {
        switch (result.*) {
            .response => |*response| response.deinit(allocator),
            .transport => {},
        }
        result.* = undefined;
    }
};

pub const FetchError = error{OutOfMemory};

/// Erased synchronous HTTP GET capability. Implementations must honor the descriptor.
/// `context` is borrowed and must outlive every call through this value.
/// A response body with bytes must be allocated with the allocator supplied to
/// the callback. Ownership transfers to `FetchResult`, and may then transfer to
/// `RefreshResult`. Return an empty body when the HTTP response has no body.
pub const Fetcher = struct {
    context: *anyopaque,
    fetch_fn: *const fn (
        std.mem.Allocator,
        std.Io,
        *anyopaque,
        GetDescriptor,
    ) FetchError!FetchResult,

    pub fn from(pointer: anytype) Fetcher {
        const Pointer = @TypeOf(pointer);
        const info = @typeInfo(Pointer);
        if (info != .pointer or info.pointer.size != .one or info.pointer.is_const) {
            @compileError("Fetcher.from expects a mutable single-item pointer");
        }
        const Adapter = struct {
            fn fetch(
                allocator: std.mem.Allocator,
                io: std.Io,
                context: *anyopaque,
                descriptor: GetDescriptor,
            ) FetchError!FetchResult {
                const self: Pointer = @ptrCast(@alignCast(context));
                return self.fetch(allocator, io, descriptor);
            }
        };
        return .{ .context = pointer, .fetch_fn = Adapter.fetch };
    }

    pub fn fetch(
        fetcher: Fetcher,
        allocator: std.mem.Allocator,
        io: std.Io,
        descriptor: GetDescriptor,
    ) FetchError!FetchResult {
        return fetcher.fetch_fn(allocator, io, fetcher.context, descriptor);
    }
};

pub const RefreshOptions = struct {
    /// Explicit wall time used only for stale-warning age. CatalogCache's
    /// injected clock remains authoritative for its stat-first refresh decision.
    now_seconds: i64,
    url: []const u8,
    refresh_ms: u64,
    nonce_source: persistence.PrivateFileStore.NonceSource,
    commit_ops: persistence.PrivateFileStore.CommitOps = .standard,
};

pub const FetchFailure = union(enum) {
    transport: TransportFailure,
    status: u16,
    too_large,
    malformed,
};

pub const RefreshOutcome = union(enum) {
    disabled,
    fresh,
    replaced,
    fetch_failed: FetchFailure,
    not_published: persistence.CatalogCache.MutationFailure,
    publication_uncertain: persistence.CatalogCache.MutationFailure,
};

/// Move-only refresh result. `catalog_bytes`, when present, is the usable cache
/// snapshot and remains the old snapshot on every definite refresh failure.
pub const RefreshResult = struct {
    outcome: RefreshOutcome,
    catalog_bytes: ?[]u8,
    /// Floored age in days only after a fetch was required and retained cache
    /// bytes are strictly older than 30 days. Disabled and fresh are always null.
    /// Publication uncertainty keeps the pre-refresh bytes here.
    warning_days: ?u64,

    pub fn deinit(result: *RefreshResult, allocator: std.mem.Allocator) void {
        if (result.catalog_bytes) |bytes| allocator.free(bytes);
        result.* = undefined;
    }
};

pub const Error = error{OutOfMemory};

pub const PlannedFetchOptions = struct {
    url: []const u8,
    nonce_source: persistence.PrivateFileStore.NonceSource,
    commit_ops: persistence.PrivateFileStore.CommitOps = .standard,
    warning_days: ?u64 = null,
};

pub const PlannedFetchResult = struct {
    outcome: RefreshOutcome,
    warning_days: ?u64,
};

/// Executes one already-decided fetch. It does not inspect or retain the old catalog.
pub fn executePlannedFetch(
    allocator: std.mem.Allocator,
    io: std.Io,
    cache: *persistence.CatalogCache.CatalogCache,
    fetcher: Fetcher,
    options: PlannedFetchOptions,
) Error!PlannedFetchResult {
    var fetched = try fetcher.fetch(allocator, io, .{
        .url = options.url,
        .timeout_ms = request_timeout_ms,
        .max_response_bytes = maximum_response_bytes,
    });
    defer fetched.deinit(allocator);
    switch (fetched) {
        .transport => |failure| return .{
            .outcome = .{ .fetch_failed = .{ .transport = failure } },
            .warning_days = options.warning_days,
        },
        .response => |response| {
            if (response.status < 200 or response.status >= 300) return .{
                .outcome = .{ .fetch_failed = .{ .status = response.status } },
                .warning_days = options.warning_days,
            };
            if (response.body.len > maximum_response_bytes) return .{
                .outcome = .{ .fetch_failed = .too_large },
                .warning_days = options.warning_days,
            };
            if (!(try validCandidate(allocator, response.body))) return .{
                .outcome = .{ .fetch_failed = .malformed },
                .warning_days = options.warning_days,
            };
            return switch (cache.replaceWithOps(response.body, options.nonce_source, options.commit_ops)) {
                .published => .{ .outcome = .replaced, .warning_days = null },
                .not_published => |failure| .{
                    .outcome = .{ .not_published = failure },
                    .warning_days = options.warning_days,
                },
                .uncertain => |failure| .{
                    .outcome = .{ .publication_uncertain = failure },
                    .warning_days = options.warning_days,
                },
            };
        },
    }
}

pub fn refresh(
    allocator: std.mem.Allocator,
    io: std.Io,
    cache: *persistence.CatalogCache.CatalogCache,
    fetcher: Fetcher,
    options: RefreshOptions,
) Error!RefreshResult {
    var inspection = cache.inspect(allocator, .{
        .url = options.url,
        .refresh_ms = options.refresh_ms,
    }) catch return error.OutOfMemory;
    defer inspection.deinit(allocator);

    var old_bytes: ?[]u8 = null;
    var modified_seconds: ?i64 = null;
    if (inspection.cache == .cached) {
        modified_seconds = inspection.cache.cached.modified_seconds;
        old_bytes = inspection.cache.cached.bytes;
        inspection.cache = .missing;
    }
    errdefer if (old_bytes) |bytes| allocator.free(bytes);

    // Pinned hax parity checks freshness from metadata before interpreting the
    // file. A fresh but unreadable/oversized cache therefore suppresses fetch.
    // This deliberately trades availability for exact refresh cadence.
    switch (inspection.refresh) {
        .disabled => return .{ .outcome = .disabled, .catalog_bytes = old_bytes, .warning_days = null },
        .fresh => return .{ .outcome = .fresh, .catalog_bytes = old_bytes, .warning_days = null },
        .fetch => {},
    }
    const warning_days = if (modified_seconds) |modified|
        warningDays(options.now_seconds, modified)
    else
        inspection.stale_days;

    var fetched = try fetcher.fetch(allocator, io, .{
        .url = options.url,
        .timeout_ms = request_timeout_ms,
        .max_response_bytes = maximum_response_bytes,
    });
    defer fetched.deinit(allocator);
    switch (fetched) {
        .transport => |failure| return .{
            .outcome = .{ .fetch_failed = .{ .transport = failure } },
            .catalog_bytes = old_bytes,
            .warning_days = warning_days,
        },
        .response => |*response| {
            if (response.status < 200 or response.status >= 300) return .{
                .outcome = .{ .fetch_failed = .{ .status = response.status } },
                .catalog_bytes = old_bytes,
                .warning_days = warning_days,
            };
            if (response.body.len > maximum_response_bytes) return .{
                .outcome = .{ .fetch_failed = .too_large },
                .catalog_bytes = old_bytes,
                .warning_days = warning_days,
            };
            if (!(try validCandidate(allocator, response.body))) return .{
                .outcome = .{ .fetch_failed = .malformed },
                .catalog_bytes = old_bytes,
                .warning_days = warning_days,
            };
            switch (cache.replaceWithOps(response.body, options.nonce_source, options.commit_ops)) {
                .published => {
                    if (old_bytes) |bytes| allocator.free(bytes);
                    const replacement = response.body;
                    fetched = .{ .transport = .failed };
                    return .{ .outcome = .replaced, .catalog_bytes = replacement, .warning_days = null };
                },
                .not_published => |failure| return .{
                    .outcome = .{ .not_published = failure },
                    .catalog_bytes = old_bytes,
                    .warning_days = warning_days,
                },
                .uncertain => |failure| return .{
                    .outcome = .{ .publication_uncertain = failure },
                    .catalog_bytes = old_bytes,
                    .warning_days = warning_days,
                },
            }
        },
    }
}

/// Reads cache and configuration independently. Invalid, unavailable, or
/// oversized input contributes no fields. Only allocation failure is fatal.
pub fn lookup(
    allocator: std.mem.Allocator,
    cache: *persistence.CatalogCache.CatalogCache,
    override_json: []const u8,
    provider_id: []const u8,
    model_id: []const u8,
) Error!ai.ModelCatalog.Contribution {
    var output: [1]ai.ModelCatalog.Contribution = undefined;
    try lookupBatch(allocator, cache, override_json, provider_id, &.{model_id}, &output);
    return output[0];
}

/// Reads one cache snapshot and parses each selected provider at most once.
/// Results own all variable data inline and align with `model_ids`.
pub fn lookupBatch(
    allocator: std.mem.Allocator,
    cache: *persistence.CatalogCache.CatalogCache,
    override_json: []const u8,
    provider_id: []const u8,
    model_ids: []const []const u8,
    output: []ai.ModelCatalog.Contribution,
) Error!void {
    std.debug.assert(model_ids.len == output.len);
    std.debug.assert(model_ids.len <= ai.ModelListing.maximum_models);
    for (output) |*value| value.* = .{};
    if (model_ids.len == 0) return;

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var read_result = cache.read(allocator) catch return error.OutOfMemory;
    defer read_result.deinit(allocator);
    if (read_result == .cached) {
        ai.ModelCatalog.lookupBatch(
            scratch,
            read_result.cached.bytes,
            provider_id,
            model_ids,
            output,
            .{},
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                for (output) |*value| value.* = .{};
            },
        };
    }

    _ = arena.reset(.retain_capacity);
    const configured = try scratch.alloc(ai.ModelCatalog.Contribution, model_ids.len);
    ai.ModelCatalog.lookupOverrideBatch(
        scratch,
        override_json,
        provider_id,
        model_ids,
        configured,
        .{},
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            for (configured) |*value| value.* = .{};
        },
    };
    for (configured, output) |*config_contribution, *cache_contribution| {
        cache_contribution.* = ai.ModelCatalog.merge(config_contribution, cache_contribution);
    }
}

fn validCandidate(allocator: std.mem.Allocator, bytes: []const u8) Error!bool {
    _ = ai.ModelCatalog.providerSlice(allocator, bytes, "", .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .use_last,
        .max_value_len = ai.ModelCatalog.maximum_string_bytes,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    var iterator = parsed.value.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .object) continue;
        const models = entry.value_ptr.object.get("models") orelse continue;
        if (models == .object) return true;
    }
    return false;
}

// Kept separate so wall-clock warning arithmetic is explicit and saturating.
fn warningDays(now_seconds: i64, modified_seconds: i64) ?u64 {
    const modified = modified_seconds;
    const age = @as(i128, now_seconds) - @as(i128, modified);
    const threshold: i128 = persistence.CatalogCache.stale_warning_days *
        persistence.CatalogCache.seconds_per_day;
    return if (age > threshold)
        @intCast(@divFloor(age, persistence.CatalogCache.seconds_per_day))
    else
        null;
}

fn testNonce() persistence.PrivateFileStore.NonceSource {
    const Source = struct {
        fn fill(_: *anyopaque, bytes: []u8) persistence.PrivateFileStore.Error!void {
            @memset(bytes, 7);
        }
    };
    return .{ .context = undefined, .fill_fn = Source.fill };
}

const TestFetch = struct {
    calls: usize = 0,
    status: u16 = 200,
    body: []const u8 = "{}",
    transport: ?TransportFailure = null,

    fn fetch(
        self: *TestFetch,
        allocator: std.mem.Allocator,
        _: std.Io,
        descriptor: GetDescriptor,
    ) FetchError!FetchResult {
        self.calls += 1;
        std.debug.assert(descriptor.method == .get);
        std.debug.assert(descriptor.timeout_ms == 30_000);
        std.debug.assert(descriptor.max_response_bytes == 32 * 1024 * 1024);
        if (self.transport) |failure| return .{ .transport = failure };
        return .{ .response = .{
            .status = self.status,
            .body = allocator.dupe(u8, self.body) catch return error.OutOfMemory,
        } };
    }
};

fn testCache(allocator: std.mem.Allocator, io: std.Io, root: []const u8) !persistence.CatalogCache.CatalogCache {
    return persistence.CatalogCache.CatalogCache.init(allocator, io, root, .system);
}

fn fixedClock(seconds: *i64) persistence.CatalogCache.Clock {
    const Fixed = struct {
        fn now(_: std.Io, context: ?*anyopaque) i64 {
            const value: *i64 = @ptrCast(@alignCast(context.?));
            return value.*;
        }
    };
    return .{ .context = seconds, .now_fn = Fixed.now };
}

test "refresh disabled, malformed, offline, and valid replacement" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    var cache = try testCache(allocator, io, root);
    defer cache.deinit();
    const old =
        \\{"old":{"models":{"m":{"limit":{"context":10}}}}}
    ;
    try std.testing.expect(cache.replace(old, testNonce()) == .published);

    var fetch: TestFetch = .{};
    var disabled = try refresh(allocator, io, &cache, .from(&fetch), .{
        .now_seconds = std.math.maxInt(i64),
        .url = "",
        .refresh_ms = 1,
        .nonce_source = testNonce(),
    });
    defer disabled.deinit(allocator);
    try std.testing.expect(disabled.outcome == .disabled);
    try std.testing.expect(disabled.warning_days == null);
    try std.testing.expectEqual(@as(usize, 0), fetch.calls);
    try std.testing.expectEqualStrings(old, disabled.catalog_bytes.?);

    var fresh = try refresh(allocator, io, &cache, .from(&fetch), .{
        .now_seconds = 0,
        .url = "url",
        .refresh_ms = std.math.maxInt(u64),
        .nonce_source = testNonce(),
    });
    defer fresh.deinit(allocator);
    try std.testing.expect(fresh.outcome == .fresh);
    try std.testing.expect(fresh.warning_days == null);
    try std.testing.expectEqual(@as(usize, 0), fetch.calls);

    fetch.transport = .canceled;
    var offline = try refresh(allocator, io, &cache, .from(&fetch), .{
        .now_seconds = std.math.maxInt(i64),
        .url = "url",
        .refresh_ms = 1,
        .nonce_source = testNonce(),
    });
    defer offline.deinit(allocator);
    try std.testing.expect(offline.outcome.fetch_failed.transport == .canceled);
    try std.testing.expectEqualStrings(old, offline.catalog_bytes.?);
    try std.testing.expect(offline.warning_days != null);

    fetch.transport = null;
    fetch.body = "[]";
    var malformed = try refresh(allocator, io, &cache, .from(&fetch), .{
        .now_seconds = 0,
        .url = "url",
        .refresh_ms = 1,
        .nonce_source = testNonce(),
    });
    defer malformed.deinit(allocator);
    try std.testing.expect(malformed.outcome.fetch_failed == .malformed);
    try std.testing.expectEqualStrings(old, malformed.catalog_bytes.?);

    const candidate =
        \\{"new":{"models":{"m":{"limit":{"context":20}}}}}
    ;
    fetch.body = candidate;
    var replaced = try refresh(allocator, io, &cache, .from(&fetch), .{
        .now_seconds = 0,
        .url = "url",
        .refresh_ms = 1,
        .nonce_source = testNonce(),
    });
    defer replaced.deinit(allocator);
    try std.testing.expect(replaced.outcome == .replaced);
    try std.testing.expectEqualStrings(candidate, replaced.catalog_bytes.?);
    var stored = try cache.read(allocator);
    defer stored.deinit(allocator);
    try std.testing.expectEqualStrings(candidate, stored.cached.bytes);
}

test "stale warning uses explicit 40 and 60 day ages only after fetch" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    var clock_now: i64 = 0;
    var cache = try persistence.CatalogCache.CatalogCache.init(
        allocator,
        io,
        root,
        fixedClock(&clock_now),
    );
    defer cache.deinit();
    const old =
        \\{"p":{"models":{}}}
    ;
    try std.testing.expect(cache.replace(old, testNonce()) == .published);
    var baseline = try cache.read(allocator);
    const modified = baseline.cached.modified_seconds;
    baseline.deinit(allocator);
    const day: i64 = @intCast(persistence.CatalogCache.seconds_per_day);
    clock_now = modified + 60 * day;
    var fetch: TestFetch = .{ .transport = .failed };

    var forty = try refresh(allocator, io, &cache, .from(&fetch), .{
        .now_seconds = modified + 40 * day,
        .url = "url",
        .refresh_ms = 1,
        .nonce_source = testNonce(),
    });
    defer forty.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 40), forty.warning_days.?);

    var sixty = try refresh(allocator, io, &cache, .from(&fetch), .{
        .now_seconds = modified + 60 * day,
        .url = "url",
        .refresh_ms = 1,
        .nonce_source = testNonce(),
    });
    defer sixty.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 60), sixty.warning_days.?);

    var disabled = try refresh(allocator, io, &cache, .from(&fetch), .{
        .now_seconds = modified + 60 * day,
        .url = "",
        .refresh_ms = 1,
        .nonce_source = testNonce(),
    });
    defer disabled.deinit(allocator);
    try std.testing.expect(disabled.outcome == .disabled);
    try std.testing.expect(disabled.warning_days == null);
}

test "fresh unusable cache suppresses fetch for pinned hax parity" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    var cache = try testCache(allocator, io, root);
    defer cache.deinit();
    try std.testing.expect(cache.replace("not json", testNonce()) == .published);
    var fetch: TestFetch = .{ .body =
        \\{"p":{"models":{}}}
    };
    var result = try refresh(allocator, io, &cache, .from(&fetch), .{
        .now_seconds = 0,
        .url = "url",
        .refresh_ms = std.math.maxInt(u64),
        .nonce_source = testNonce(),
    });
    defer result.deinit(allocator);
    try std.testing.expect(result.outcome == .fresh);
    try std.testing.expectEqual(@as(usize, 0), fetch.calls);
    try std.testing.expectEqualStrings("not json", result.catalog_bytes.?);
}

test "lookup is liberal and merges override fields" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    var cache = try testCache(allocator, io, root);
    defer cache.deinit();
    try std.testing.expect(cache.replace(
        \\{"p":{"models":{"m":{"limit":{"context":100,"output":20},"tool_call":true}}}}
    , testNonce()) == .published);
    const result = try lookup(allocator, &cache,
        \\{"p":{"m":{"limit":{"output":7},"modalities":{"input":["image"]}}}}
    , "p", "m");
    try std.testing.expectEqual(@as(u64, 100), result.metadata.context_window);
    try std.testing.expectEqual(@as(u64, 7), result.metadata.max_output);
    try std.testing.expect(result.metadata.tools == .yes);
    try std.testing.expect(result.metadata.image_input == .yes);

    const malformed = try lookup(allocator, &cache, "not json", "p", "m");
    try std.testing.expectEqual(@as(u64, 100), malformed.metadata.context_window);
}

test "HTTP status and publication uncertainty are typed" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    var cache = try testCache(allocator, io, root);
    defer cache.deinit();
    var fetch: TestFetch = .{ .status = 503 };
    var status = try refresh(allocator, io, &cache, .from(&fetch), .{
        .now_seconds = 0,
        .url = "url",
        .refresh_ms = 1,
        .nonce_source = testNonce(),
    });
    defer status.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 503), status.outcome.fetch_failed.status);

    const Fail = struct {
        fn dirSync(_: std.Io, _: ?*anyopaque, _: std.Io.Dir) persistence.PrivateFileStore.Error!void {
            return error.IoFailure;
        }
    };
    const old =
        \\{"old":{"models":{}}}
    ;
    try std.testing.expect(cache.replace(old, testNonce()) == .published);
    fetch.status = 200;
    fetch.body =
        \\{"p":{"models":{}}}
    ;
    var uncertain = try refresh(allocator, io, &cache, .from(&fetch), .{
        .now_seconds = 0,
        .url = "url",
        .refresh_ms = 1,
        .nonce_source = testNonce(),
        .commit_ops = .{ .dir_sync_fn = Fail.dirSync },
    });
    defer uncertain.deinit(allocator);
    try std.testing.expect(uncertain.outcome == .publication_uncertain);
    try std.testing.expectEqualStrings(old, uncertain.catalog_bytes.?);
    var disk = try cache.read(allocator);
    defer disk.deinit(allocator);
    try std.testing.expectEqualStrings(fetch.body, disk.cached.bytes);
}

fn candidateAllocationExercise(allocator: std.mem.Allocator) !void {
    try std.testing.expect(try validCandidate(allocator,
        \\{"p":{"models":{"m":{}}}}
    ));
}

test "candidate validation reports every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        candidateAllocationExercise,
        .{},
    );
}

const BodyObserver = struct {
    backing: std.mem.Allocator,
    allocations: usize = 0,
    fail_index: ?usize = null,
    target: ?[*]u8 = null,
    target_freed: bool = false,

    fn allocator(self: *BodyObserver) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *BodyObserver = @ptrCast(@alignCast(context));
        const index = self.allocations;
        self.allocations += 1;
        if (self.fail_index == index) return null;
        return self.backing.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *BodyObserver = @ptrCast(@alignCast(context));
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *BodyObserver = @ptrCast(@alignCast(context));
        return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *BodyObserver = @ptrCast(@alignCast(context));
        if (self.target) |target| {
            if (memory.ptr == target) self.target_freed = true;
        }
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

const ObservedFetch = struct {
    observer: *BodyObserver,
    status: u16,
    body: []const u8,

    fn fetch(
        self: *ObservedFetch,
        allocator: std.mem.Allocator,
        _: std.Io,
        _: GetDescriptor,
    ) FetchError!FetchResult {
        const body = allocator.dupe(u8, self.body) catch return error.OutOfMemory;
        self.observer.target = body.ptr;
        return .{ .response = .{ .status = self.status, .body = body } };
    }
};

fn expectRejectedBodyFreed(body: []const u8, status: u16, fail_index: ?usize) !void {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var cache = try testCache(std.testing.allocator, io, root);
    defer cache.deinit();
    var observer: BodyObserver = .{
        .backing = std.testing.allocator,
        .fail_index = fail_index,
    };
    var fetch: ObservedFetch = .{ .observer = &observer, .status = status, .body = body };
    var result = refresh(observer.allocator(), io, &cache, .from(&fetch), .{
        .now_seconds = 0,
        .url = "url",
        .refresh_ms = 1,
        .nonce_source = testNonce(),
    }) catch |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
        try std.testing.expect(observer.target_freed);
        return;
    };
    result.deinit(observer.allocator());
    try std.testing.expect(observer.target_freed);
}

test "rejected and OOM response bodies return to the callback allocator" {
    try expectRejectedBodyFreed("status body", 500, null);
    try expectRejectedBodyFreed("[]", 200, null);

    const oversized = try std.testing.allocator.alloc(u8, maximum_response_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');
    try expectRejectedBodyFreed(oversized, 200, null);

    // The body duplication is allocation zero. Candidate validation then fails.
    try expectRejectedBodyFreed(
        \\{"p":{"models":{"m":{}}}}
    , 200, 1);
}

fn refreshAllocationExercise(
    allocator: std.mem.Allocator,
    cache: *persistence.CatalogCache.CatalogCache,
) !void {
    var fetch: TestFetch = .{ .body = "{}" };
    var result = try refresh(allocator, std.testing.io, cache, .from(&fetch), .{
        .now_seconds = 0,
        .url = "url",
        .refresh_ms = 1,
        .nonce_source = testNonce(),
    });
    defer result.deinit(allocator);
    try std.testing.expect(result.outcome.fetch_failed == .malformed);
}

fn lookupAllocationExercise(
    allocator: std.mem.Allocator,
    cache: *persistence.CatalogCache.CatalogCache,
) !void {
    const ids = [_][]const u8{ "m", "other", "missing", "m" };
    var output: [ids.len]ai.ModelCatalog.Contribution = undefined;
    try lookupBatch(allocator, cache,
        \\{"p":{"m":{"limit":{"output":7}},"other":{"tool_call":false}}}
    , "p", &ids, &output);
    for (ids, output) |model_id, contribution| {
        const scalar = try lookup(allocator, cache,
            \\{"p":{"m":{"limit":{"output":7}},"other":{"tool_call":false}}}
        , "p", model_id);
        try std.testing.expectEqualDeep(scalar, contribution);
    }
    try std.testing.expectEqual(@as(u64, 7), output[0].metadata.max_output);
    try std.testing.expectEqual(ai.ModelMeta.Support.no, output[1].metadata.tools);
}

test "batch lookup is scalar-equivalent and aligned" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var cache = try testCache(std.testing.allocator, io, root);
    defer cache.deinit();
    try std.testing.expect(cache.replace(
        \\{"p":{"models":{"m":{"limit":{"context":100}},"other":{"tool_call":true}}}}
    , testNonce()) == .published);
    try lookupAllocationExercise(std.testing.allocator, &cache);
}

test "refresh and lookup release all partial allocations" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var cache = try testCache(std.testing.allocator, io, root);
    defer cache.deinit();
    try std.testing.expect(cache.replace(
        \\{"p":{"models":{"m":{"limit":{"context":100}}}}}
    , testNonce()) == .published);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        refreshAllocationExercise,
        .{&cache},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        lookupAllocationExercise,
        .{&cache},
    );
}
