//! Process-owned background lifecycle for the on-disk model catalog.
//!
//! `Owner` is heap allocated so erased callbacks and the worker always point at
//! a stable address. The allocator and `std.Io` passed to `create` are explicit
//! process resources and must support use from the caller and worker threads.
//! Caller lookups and the worker use separate cache handles over the same atomic
//! file. Borrowed callback contexts must outlive `Owner.deinit`; transport,
//! nonce, and commit operations remain valid through join. The clock supports
//! concurrent lookup and worker use. Wakeup supports concurrent transport use.

const std = @import("std");
const ai = @import("ai/root.zig");
const persistence = @import("persistence/root.zig");
const CatalogManager = @import("CatalogManager.zig");

pub const Wakeup = struct {
    context: *anyopaque,
    wake_fn: *const fn (*anyopaque) void,

    pub fn from(pointer: anytype) Wakeup {
        const Pointer = @TypeOf(pointer);
        const info = @typeInfo(Pointer);
        if (info != .pointer or info.pointer.size != .one or info.pointer.is_const) {
            @compileError("Wakeup.from expects a mutable single-item pointer");
        }
        const Adapter = struct {
            fn wake(context: *anyopaque) void {
                const self: Pointer = @ptrCast(@alignCast(context));
                self.wake();
            }
        };
        return .{ .context = pointer, .wake_fn = Adapter.wake };
    }

    pub fn wake(self: Wakeup) void {
        self.wake_fn(self.context);
    }
};

pub const Options = struct {
    cache_root: []const u8,
    clock: persistence.CatalogCache.Clock = .system,
    url: []const u8,
    refresh_ms: u64,
    now_seconds: i64,
    nonce_source: persistence.PrivateFileStore.NonceSource,
    commit_ops: persistence.PrivateFileStore.CommitOps = .standard,
    wakeup: ?Wakeup = null,
};

pub const StartResult = enum {
    started,
    disabled,
    fresh,
    already_attempted,
};

pub const StartFailure = enum {
    out_of_memory,
    system_resources,
    thread_quota_exceeded,
    locked_memory_limit_exceeded,
    unexpected,
};

pub const Completion = union(enum) {
    disabled,
    fresh,
    refresh: CatalogManager.RefreshOutcome,
    start_failed: StartFailure,
    worker_out_of_memory,
};

/// Small by-value observation. It never borrows worker allocations.
pub const Summary = struct {
    attempted: bool,
    started: bool,
    running: bool,
    completion: ?Completion,
    warning_days: ?u64,
};

pub const CreateError = error{ OutOfMemory, InvalidRoot };
pub const StartError = error{
    OutOfMemory,
    SystemResources,
    ThreadQuotaExceeded,
    LockedMemoryLimitExceeded,
    Unexpected,
};

const JsonFetcher = struct {
    owner: *Owner,

    pub fn poll(self: *JsonFetcher) ai.Provider.DeliveryError!void {
        return self.owner.pollCancellation();
    }

    pub fn fetch(
        self: *JsonFetcher,
        allocator: std.mem.Allocator,
        io: std.Io,
        descriptor: CatalogManager.GetDescriptor,
    ) CatalogManager.FetchError!CatalogManager.FetchResult {
        std.debug.assert(descriptor.method == .get);
        self.owner.pollCancellation() catch return .{ .transport = .canceled };
        var response = self.owner.json_transport.request(allocator, io, .{
            .method = .get,
            .url = descriptor.url,
            .headers = &.{},
            .tick = ai.Provider.Tick.from(self),
            .limits = .{
                .max_request_body_bytes = 1,
                .max_response_body_bytes = descriptor.max_response_bytes,
                .max_header_bytes = ai.JsonTransport.maximum_header_bytes,
                .header_buffer_bytes = ai.JsonTransport.maximum_header_bytes,
                .connect_timeout_ms = 2_000,
                .idle_timeout_ms = 0,
                .total_timeout_ms = descriptor.timeout_ms,
            },
        }) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Cancelled => .{ .transport = .canceled },
            else => .{ .transport = .failed },
        };
        const result: CatalogManager.FetchResult = .{ .response = .{
            .status = response.status,
            .body = response.body,
        } };
        response = undefined;
        return result;
    }
};

/// Heap-stable owner of one process-lifetime catalog refresh attempt.
pub const Owner = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cache: persistence.CatalogCache.CatalogCache,
    worker_cache: persistence.CatalogCache.CatalogCache,
    url: []u8,
    refresh_ms_value: u64,
    nonce_source: persistence.PrivateFileStore.NonceSource,
    commit_ops: persistence.PrivateFileStore.CommitOps,
    wakeup: ?Wakeup,
    json_transport: ai.JsonTransport.Transport,
    fetch_adapter: JsonFetcher,

    canceled: std.atomic.Value(bool) = .init(false),
    attempted: std.atomic.Value(bool) = .init(false),
    lifecycle_mutex: std.Io.Mutex = .init,
    lifecycle_condition: std.Io.Condition = .init,
    result_mutex: std.Io.Mutex = .init,
    thread: ?std.Thread = null,
    joining: bool = false,
    joined: bool = false,
    started: bool = false,
    running: bool = false,
    completion: ?Completion = null,
    warning_days: ?u64 = null,

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        json_transport: ai.JsonTransport.Transport,
        options: Options,
    ) CreateError!*Owner {
        const self = try allocator.create(Owner);
        errdefer allocator.destroy(self);
        const url = allocator.dupe(u8, options.url) catch return error.OutOfMemory;
        errdefer allocator.free(url);
        var cache = try persistence.CatalogCache.CatalogCache.init(
            allocator,
            io,
            options.cache_root,
            options.clock,
        );
        errdefer cache.deinit();
        var worker_cache = try persistence.CatalogCache.CatalogCache.init(
            allocator,
            io,
            options.cache_root,
            options.clock,
        );
        errdefer worker_cache.deinit();
        self.* = .{
            .allocator = allocator,
            .io = io,
            .cache = cache,
            .worker_cache = worker_cache,
            .url = url,
            .refresh_ms_value = options.refresh_ms,
            .json_transport = json_transport,
            .nonce_source = options.nonce_source,
            .commit_ops = options.commit_ops,
            .wakeup = options.wakeup,
            .fetch_adapter = undefined,
        };
        self.fetch_adapter = .{ .owner = self };
        return self;
    }

    /// Consumes the one-attempt latch before planning freshness. Concurrent
    /// calls are serialized with thread publication.
    pub fn start(self: *Owner) StartError!StartResult {
        self.lifecycle_mutex.lockUncancelable(self.io);
        defer self.lifecycle_mutex.unlock(self.io);
        if (self.attempted.swap(true, .acq_rel)) return .already_attempted;

        const plan = self.cache.planRefresh(.{
            .url = self.url,
            .refresh_ms = self.refreshMs(),
        });
        switch (plan.decision) {
            .disabled => {
                self.setCompletion(.disabled, plan.stale_days, false, false);
                self.joined = true;
                return .disabled;
            },
            .fresh => {
                self.setCompletion(.fresh, plan.stale_days, false, false);
                self.joined = true;
                return .fresh;
            },
            .fetch => {},
        }

        self.setCompletion(null, plan.stale_days, true, true);
        self.thread = std.Thread.spawn(.{}, workerMain, .{self}) catch |err| {
            self.setCompletion(.{ .start_failed = startFailure(err) }, plan.stale_days, false, false);
            self.joined = true;
            return err;
        };
        return .started;
    }

    /// Waits up to `max_wait_ms` for completion without requesting cancellation.
    pub fn wait(self: *Owner, max_wait_ms: u64) bool {
        if (!self.poll().running) return true;
        if (max_wait_ms == 0) return false;
        const start_ns = std.Io.Clock.awake.now(self.io).nanoseconds;
        const wait_ns = @as(i128, max_wait_ms) * std.time.ns_per_ms;
        while (self.poll().running) {
            const now_ns = std.Io.Clock.awake.now(self.io).nanoseconds;
            if (@as(i128, now_ns) - @as(i128, start_ns) >= wait_ns) return false;
            std.Io.sleep(self.io, .fromMilliseconds(1), .awake) catch
                std.Thread.yield() catch std.atomic.spinLoopHint();
        }
        return true;
    }

    /// Gives the worker a grace period, cancels and wakes it only if unfinished,
    /// then performs the sole join. Concurrent drains wait for that join.
    pub fn drain(self: *Owner, max_wait_ms: u64) Summary {
        _ = self.wait(max_wait_ms);
        self.lifecycle_mutex.lockUncancelable(self.io);
        while (self.joining) self.lifecycle_condition.waitUncancelable(
            self.io,
            &self.lifecycle_mutex,
        );
        if (self.joined) {
            self.lifecycle_mutex.unlock(self.io);
            return self.poll();
        }
        const thread = self.thread orelse {
            _ = self.attempted.swap(true, .acq_rel);
            self.joined = true;
            self.lifecycle_mutex.unlock(self.io);
            return self.poll();
        };
        self.joining = true;
        const unfinished = self.poll().running;
        if (unfinished) self.canceled.store(true, .release);
        self.lifecycle_mutex.unlock(self.io);

        if (unfinished) if (self.wakeup) |hook| hook.wake();
        thread.join();

        self.lifecycle_mutex.lockUncancelable(self.io);
        self.thread = null;
        self.joining = false;
        self.joined = true;
        self.lifecycle_condition.broadcast(self.io);
        self.lifecycle_mutex.unlock(self.io);
        return self.poll();
    }

    pub fn cancelAndDrain(self: *Owner) Summary {
        return self.drain(0);
    }

    pub fn poll(self: *Owner) Summary {
        self.result_mutex.lockUncancelable(self.io);
        defer self.result_mutex.unlock(self.io);
        return .{
            .attempted = self.attempted.load(.acquire),
            .started = self.started,
            .running = self.running,
            .completion = self.completion,
            .warning_days = self.warning_days,
        };
    }

    pub fn lookup(
        self: *Owner,
        allocator: std.mem.Allocator,
        override_json: []const u8,
        provider_id: []const u8,
        model_id: []const u8,
    ) CatalogManager.Error!ai.ModelCatalog.Contribution {
        return CatalogManager.lookup(allocator, &self.cache, override_json, provider_id, model_id);
    }

    /// Requires exclusive ownership: no other method call may overlap deinit.
    /// Borrowed callback contexts must remain valid through this call.
    pub fn deinit(self: *Owner) void { // ziglint-ignore: Z030
        _ = self.drain(0);
        const allocator = self.allocator;
        self.worker_cache.deinit();
        self.cache.deinit();
        allocator.free(self.url);
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn pollCancellation(self: *Owner) ai.Provider.DeliveryError!void {
        if (self.canceled.load(.acquire)) return error.Cancelled;
    }

    fn workerMain(self: *Owner) void {
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const warning_days = self.poll().warning_days;
        const result = CatalogManager.executePlannedFetch(
            arena.allocator(),
            self.io,
            &self.worker_cache,
            .from(&self.fetch_adapter),
            .{
                .url = self.url,
                .nonce_source = self.nonce_source,
                .commit_ops = self.commit_ops,
                .warning_days = warning_days,
            },
        ) catch {
            self.setCompletion(.worker_out_of_memory, warning_days, true, false);
            self.lifecycle_condition.broadcast(self.io);
            return;
        };
        self.setCompletion(.{ .refresh = result.outcome }, result.warning_days, true, false);
        self.lifecycle_condition.broadcast(self.io);
    }

    fn setCompletion(
        self: *Owner,
        completion: ?Completion,
        warning_days: ?u64,
        started: bool,
        running: bool,
    ) void {
        self.result_mutex.lockUncancelable(self.io);
        defer self.result_mutex.unlock(self.io);
        self.started = started;
        self.running = running;
        self.completion = completion;
        self.warning_days = warning_days;
    }

    fn refreshMs(self: *const Owner) u64 {
        return self.refresh_ms_value;
    }
};

fn startFailure(err: std.Thread.SpawnError) StartFailure {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.SystemResources => .system_resources,
        error.ThreadQuotaExceeded => .thread_quota_exceeded,
        error.LockedMemoryLimitExceeded => .locked_memory_limit_exceeded,
        error.Unexpected => .unexpected,
    };
}

fn testNonce() persistence.PrivateFileStore.NonceSource {
    const Source = struct {
        fn fill(_: *anyopaque, bytes: []u8) persistence.PrivateFileStore.Error!void {
            @memset(bytes, 9);
        }
    };
    return .{ .context = undefined, .fill_fn = Source.fill };
}

const BlockingTransport = struct {
    entered: std.atomic.Value(bool) = .init(false),
    woken: std.atomic.Value(bool) = .init(false),
    calls: std.atomic.Value(usize) = .init(0),
    exact_request: std.atomic.Value(bool) = .init(false),

    pub fn request(
        _: std.mem.Allocator,
        _: std.Io,
        self: *BlockingTransport,
        value: ai.JsonTransport.Request,
    ) ai.JsonTransport.Error!ai.JsonTransport.Response {
        _ = self.calls.fetchAdd(1, .acq_rel);
        self.exact_request.store(value.method == .get and
            std.mem.eql(u8, value.url, "https://catalog.test/models.json") and
            value.headers.len == 0 and value.json_body == null and
            value.limits.max_response_body_bytes == 32 * 1024 * 1024 and
            value.limits.connect_timeout_ms == 2_000 and
            value.limits.idle_timeout_ms == 0 and
            value.limits.total_timeout_ms == 30_000 and value.tick != null, .release);
        self.entered.store(true, .release);
        while (!self.woken.load(.acquire)) {
            if (value.tick) |tick| try tick.poll();
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }
        if (value.tick) |tick| try tick.poll();
        return error.Cancelled;
    }

    fn wake(self: *BlockingTransport) void {
        self.woken.store(true, .release);
    }
};

const ImmediateTransport = struct {
    calls: std.atomic.Value(usize) = .init(0),
    wakes: std.atomic.Value(usize) = .init(0),
    status: u16 = 503,
    body: []const u8 = "",

    pub fn request(
        allocator: std.mem.Allocator,
        _: std.Io,
        self: *ImmediateTransport,
        _: ai.JsonTransport.Request,
    ) ai.JsonTransport.Error!ai.JsonTransport.Response {
        _ = self.calls.fetchAdd(1, .acq_rel);
        return .{
            .status = self.status,
            .body = allocator.dupe(u8, self.body) catch return error.OutOfMemory,
        };
    }

    fn wake(self: *ImmediateTransport) void {
        _ = self.wakes.fetchAdd(1, .acq_rel);
    }
};

const StartCall = struct {
    owner: *Owner,
    result: ?StartResult = null,
    failed: bool = false,

    fn run(self: *StartCall) void {
        self.result = self.owner.start() catch {
            self.failed = true;
            return;
        };
    }
};

const DrainCall = struct {
    owner: *Owner,
    summary: ?Summary = null,

    fn run(self: *DrainCall) void {
        self.summary = self.owner.drain(0);
    }
};

fn waitFor(value: *std.atomic.Value(bool)) void {
    while (!value.load(.acquire)) std.Thread.yield() catch std.atomic.spinLoopHint();
}

fn waitUntilStopped(owner: *Owner) void {
    while (owner.poll().running) std.Thread.yield() catch std.atomic.spinLoopHint();
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

const CountingClock = struct {
    seconds: i64,
    calls: std.atomic.Value(usize) = .init(0),

    fn now(_: std.Io, context: ?*anyopaque) i64 {
        const self: *CountingClock = @ptrCast(@alignCast(context.?));
        _ = self.calls.fetchAdd(1, .acq_rel);
        return self.seconds;
    }

    fn clock(self: *CountingClock) persistence.CatalogCache.Clock {
        return .{ .context = self, .now_fn = now };
    }
};

test "freshness latch is consumed by a disabled attempt" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    var transport: ImmediateTransport = .{};
    const owner = try Owner.create(allocator, io, .from(&transport), .{
        .cache_root = root,
        .url = "",
        .refresh_ms = 1,
        .now_seconds = 0,
        .nonce_source = testNonce(),
    });
    defer owner.deinit();

    try std.testing.expect(try owner.start() == .disabled);
    try std.testing.expect(try owner.start() == .already_attempted);
    const summary = owner.cancelAndDrain();
    try std.testing.expect(summary.attempted);
    try std.testing.expect(!summary.started);
    try std.testing.expect(!summary.running);
    try std.testing.expect(summary.completion.? == .disabled);
    try std.testing.expectEqual(@as(usize, 0), transport.calls.load(.acquire));

    var cache = try persistence.CatalogCache.CatalogCache.init(allocator, io, root, .system);
    defer cache.deinit();
    try std.testing.expect(cache.replace(
        \\{"p":{"models":{}}}
    , testNonce()) == .published);
    const fresh_owner = try Owner.create(allocator, io, .from(&transport), .{
        .cache_root = root,
        .url = "https://catalog.test/models.json",
        .refresh_ms = std.math.maxInt(u64),
        .now_seconds = 0,
        .nonce_source = testNonce(),
    });
    defer fresh_owner.deinit();
    try std.testing.expect(try fresh_owner.start() == .fresh);
    try std.testing.expect(try fresh_owner.start() == .already_attempted);
    try std.testing.expect(fresh_owner.poll().completion.? == .fresh);
    try std.testing.expectEqual(@as(usize, 0), transport.calls.load(.acquire));

    var stale_now: i64 = std.math.maxInt(i64);
    const canceled_owner = try Owner.create(allocator, io, .from(&transport), .{
        .cache_root = root,
        .clock = fixedClock(&stale_now),
        .url = "https://catalog.test/models.json",
        .refresh_ms = 1,
        .now_seconds = stale_now,
        .nonce_source = testNonce(),
    });
    defer canceled_owner.deinit();
    canceled_owner.canceled.store(true, .release);
    try std.testing.expect(try canceled_owner.start() == .started);
    const canceled_summary = canceled_owner.drain(100);
    try std.testing.expect(canceled_summary.completion.?.refresh.fetch_failed.transport == .canceled);
    try std.testing.expectEqual(@as(usize, 0), transport.calls.load(.acquire));
}

test "concurrent start and drain serialize thread publication" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    var transport: BlockingTransport = .{};
    const owner = try Owner.create(allocator, io, .from(&transport), .{
        .cache_root = root,
        .url = "https://catalog.test/models.json",
        .refresh_ms = 1,
        .now_seconds = 0,
        .nonce_source = testNonce(),
        .wakeup = .from(&transport),
    });
    defer owner.deinit();
    var start_call: StartCall = .{ .owner = owner };
    var drain_call: DrainCall = .{ .owner = owner };
    const start_thread = try std.Thread.spawn(.{}, StartCall.run, .{&start_call});
    const drain_thread = try std.Thread.spawn(.{}, DrainCall.run, .{&drain_call});
    start_thread.join();
    drain_thread.join();
    try std.testing.expect(!start_call.failed);
    try std.testing.expect(start_call.result.? == .started or
        start_call.result.? == .already_attempted);
    try std.testing.expect(!drain_call.summary.?.running);
    try std.testing.expect(owner.thread == null);
}

test "background request is exact, lookup is concurrent, and shutdown cancels and joins" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    var transport: BlockingTransport = .{};
    const owner = try Owner.create(allocator, io, .from(&transport), .{
        .cache_root = root,
        .url = "https://catalog.test/models.json",
        .refresh_ms = 1,
        .now_seconds = 0,
        .nonce_source = testNonce(),
        .wakeup = .from(&transport),
    });
    defer owner.deinit();

    try std.testing.expect(try owner.start() == .started);
    waitFor(&transport.entered);
    const contribution = try owner.lookup(allocator,
        \\{"p":{"m":{"limit":{"output":17}}}}
    , "p", "m");
    try std.testing.expectEqual(@as(u64, 17), contribution.metadata.max_output);

    var drain_a: DrainCall = .{ .owner = owner };
    var drain_b: DrainCall = .{ .owner = owner };
    const thread_a = try std.Thread.spawn(.{}, DrainCall.run, .{&drain_a});
    const thread_b = try std.Thread.spawn(.{}, DrainCall.run, .{&drain_b});
    thread_a.join();
    thread_b.join();
    const summary = drain_a.summary.?;
    try std.testing.expect(drain_b.summary.?.completion.?.refresh.fetch_failed.transport == .canceled);
    try std.testing.expect(summary.started);
    try std.testing.expect(!summary.running);
    try std.testing.expect(summary.completion.?.refresh.fetch_failed.transport == .canceled);
    try std.testing.expect(summary.warning_days == null);
    try std.testing.expect(transport.woken.load(.acquire));
    try std.testing.expect(transport.exact_request.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), transport.calls.load(.acquire));
    try std.testing.expect(owner.thread == null);
}

test "drain reports stale warning without retaining catalog bytes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    var now_seconds: i64 = 0;
    var cache = try persistence.CatalogCache.CatalogCache.init(
        allocator,
        io,
        root,
        fixedClock(&now_seconds),
    );
    defer cache.deinit();
    try std.testing.expect(cache.replace(
        \\{"p":{"models":{"m":{"limit":{"context":41}}}}}
    , testNonce()) == .published);
    var disk = try cache.read(allocator);
    const modified_seconds = disk.cached.modified_seconds;
    disk.deinit(allocator);
    const day: i64 = @intCast(persistence.CatalogCache.seconds_per_day);
    now_seconds = modified_seconds + 40 * day;

    var transport: ImmediateTransport = .{};
    var counting_clock: CountingClock = .{ .seconds = now_seconds };
    const owner = try Owner.create(allocator, io, .from(&transport), .{
        .cache_root = root,
        .clock = counting_clock.clock(),
        .url = "https://catalog.test/models.json",
        .refresh_ms = 1,
        .now_seconds = now_seconds,
        .nonce_source = testNonce(),
        .wakeup = .from(&transport),
    });
    defer owner.deinit();
    try std.testing.expect(try owner.start() == .started);
    const summary = owner.drain(100);
    try std.testing.expectEqual(@as(usize, 0), transport.wakes.load(.acquire));
    try std.testing.expectEqual(@as(u64, 40), summary.warning_days.?);
    try std.testing.expectEqual(@as(u16, 503), summary.completion.?.refresh.fetch_failed.status);
    try std.testing.expectEqual(@as(usize, 1), counting_clock.calls.load(.acquire));

    const contribution = try owner.lookup(allocator, "", "p", "m");
    try std.testing.expectEqual(@as(u64, 41), contribution.metadata.context_window);
}
