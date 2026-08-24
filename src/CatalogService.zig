//! Process-owned background lifecycle for the on-disk model catalog.
//!
//! `Owner` is heap allocated so erased callbacks and the worker always point at
//! a stable address. The allocator used by `create` does not need to be thread
//! safe: the worker uses a private arena and `deinit` touches the owner
//! allocator only after joining it. Transport, clock, nonce, commit, and wakeup
//! callback contexts are borrowed and must outlive `cancelAndDrain`.

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

    fn poll(self: *JsonFetcher) ai.Provider.DeliveryError!void {
        return self.owner.pollCancellation();
    }

    fn fetch(
        self: *JsonFetcher,
        allocator: std.mem.Allocator,
        io: std.Io,
        descriptor: CatalogManager.GetDescriptor,
    ) CatalogManager.FetchError!CatalogManager.FetchResult {
        std.debug.assert(descriptor.method == .get);
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
                .connect_timeout_ms = descriptor.timeout_ms,
                .idle_timeout_ms = descriptor.timeout_ms,
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
    url: []u8,
    refresh_ms: u64,
    now_seconds: i64,
    json_transport: ai.JsonTransport.Transport,
    nonce_source: persistence.PrivateFileStore.NonceSource,
    commit_ops: persistence.PrivateFileStore.CommitOps,
    wakeup: ?Wakeup,
    fetch_adapter: JsonFetcher,
    canceled: std.atomic.Value(bool) = .init(false),
    attempted: std.atomic.Value(bool) = .init(false),
    mutex: std.atomic.Mutex = .unlocked,
    thread: ?std.Thread = null,
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
        self.* = .{
            .allocator = allocator,
            .io = io,
            .cache = cache,
            .url = url,
            .refresh_ms = options.refresh_ms,
            .now_seconds = options.now_seconds,
            .json_transport = json_transport,
            .nonce_source = options.nonce_source,
            .commit_ops = options.commit_ops,
            .wakeup = options.wakeup,
            .fetch_adapter = undefined,
        };
        self.fetch_adapter = .{ .owner = self };
        return self;
    }

    /// Inspects freshness on the caller thread. Like hax, the one-attempt latch
    /// is consumed before disabled/fresh checks and is not reset on failures.
    pub fn start(self: *Owner) StartError!StartResult {
        if (self.attempted.swap(true, .acq_rel)) return .already_attempted;

        var inspection = self.cache.inspect(self.allocator, .{
            .url = self.url,
            .refresh_ms = self.refresh_ms,
        }) catch |err| {
            self.setStartFailure(.out_of_memory);
            return err;
        };
        defer inspection.deinit(self.allocator);
        switch (inspection.refresh) {
            .disabled => {
                self.setCompletion(.disabled, null);
                return .disabled;
            },
            .fresh => {
                self.setCompletion(.fresh, null);
                return .fresh;
            },
            .fetch => {},
        }

        self.mutex.lock();
        self.started = true;
        self.running = true;
        self.mutex.unlock();
        self.thread = std.Thread.spawn(.{}, workerMain, .{self}) catch |err| {
            self.mutex.lock();
            self.started = false;
            self.running = false;
            self.completion = .{ .start_failed = startFailure(err) };
            self.mutex.unlock();
            return err;
        };
        return .started;
    }

    /// Requests cancellation, wakes a transport that supports it, and joins.
    /// This is idempotent after the sole worker has been joined.
    pub fn cancelAndDrain(self: *Owner) Summary {
        self.canceled.store(true, .release);
        if (self.wakeup) |hook| hook.wake();
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        return self.poll();
    }

    /// Returns the current bounded observation without invoking user code.
    pub fn poll(self: *Owner) Summary {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{
            .attempted = self.attempted.load(.acquire),
            .started = self.started,
            .running = self.running,
            .completion = self.completion,
            .warning_days = self.warning_days,
        };
    }

    /// Reads the atomic cache file each time. The caller allocator owns all
    /// returned contribution fields according to ModelCatalog's value contract.
    pub fn lookup(
        self: *Owner,
        allocator: std.mem.Allocator,
        override_json: []const u8,
        provider_id: []const u8,
        model_id: []const u8,
    ) CatalogManager.Error!ai.ModelCatalog.Contribution {
        return CatalogManager.lookup(allocator, &self.cache, override_json, provider_id, model_id);
    }

    pub fn deinit(self: *Owner) void { // ziglint-ignore: Z030
        _ = self.cancelAndDrain();
        const allocator = self.allocator;
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
        var result = CatalogManager.refresh(
            arena.allocator(),
            self.io,
            &self.cache,
            .from(&self.fetch_adapter),
            .{
                .now_seconds = self.now_seconds,
                .url = self.url,
                .refresh_ms = self.refresh_ms,
                .nonce_source = self.nonce_source,
                .commit_ops = self.commit_ops,
            },
        ) catch {
            self.mutex.lock();
            self.running = false;
            self.completion = .worker_out_of_memory;
            self.warning_days = null;
            self.mutex.unlock();
            return;
        };
        defer result.deinit(arena.allocator());
        self.mutex.lock();
        self.running = false;
        self.completion = .{ .refresh = result.outcome };
        self.warning_days = result.warning_days;
        self.mutex.unlock();
    }

    fn setCompletion(self: *Owner, completion: Completion, warning_days: ?u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.completion = completion;
        self.warning_days = warning_days;
    }

    fn setStartFailure(self: *Owner, failure: StartFailure) void {
        self.setCompletion(.{ .start_failed = failure }, null);
    }
};

fn startFailure(err: std.Thread.SpawnError) StartFailure {
    return switch (err) {
        error.SystemResources => .system_resources,
        error.ThreadQuotaExceeded => .thread_quota_exceeded,
        error.LockedMemoryLimitExceeded => .locked_memory_limit_exceeded,
        error.Unexpected => .unexpected,
    };
}
