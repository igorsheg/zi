const std = @import("std");
const ai = @import("ai/root.zig");
const persistence = @import("persistence/root.zig");

const Codex = @import("ai/Codex.zig");
const Credentials = ai.CodexCredentials;
const Refresh = ai.CodexRefresh;
const CredentialStore = persistence.CredentialStore;
const PrivateFileStore = persistence.PrivateFileStore;
const Provider = ai.Provider;
const SecureAllocator = @import("ai/SecureAllocator.zig");

pub const provider_id = "codex";
pub const metadata_margin_seconds: u64 = 60;
pub const maximum_rotation_body_bytes: usize = Refresh.maximum_response_bytes;

/// Explicit wall clock. The implementation and its context must outlive the source.
pub const Clock = struct {
    context: ?*anyopaque = null,
    now_fn: *const fn (std.Io, ?*anyopaque) u64 = systemNow,

    pub const system: Clock = .{};

    pub fn now(self: Clock, io: std.Io) u64 {
        return self.now_fn(io, self.context);
    }

    fn systemNow(io: std.Io, _: ?*anyopaque) u64 {
        const nanoseconds = std.Io.Clock.real.now(io).nanoseconds;
        if (nanoseconds <= 0) return 0;
        return std.math.cast(u64, @divFloor(nanoseconds, std.time.ns_per_s)) orelse std.math.maxInt(u64);
    }
};

/// Move-only result from a rotation. Response bodies use the allocator passed to
/// `Rotator.rotate` and are wiped by `deinit`.
pub const RotationResult = union(enum) {
    response: Response,
    transient,

    pub const Response = struct {
        status: u16,
        body: []u8,
    };

    pub fn deinit(self: *RotationResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .response => |response| SecureAllocator.wipeFree(allocator, response.body),
            .transient => {},
        }
        self.* = undefined;
    }
};

/// Erased synchronous refresh transport. It must bound returned response bodies
/// to `maximum_rotation_body_bytes`. It may poll `tick` before dispatch. Once a
/// POST is dispatched it must suppress cancellation and finish the bounded
/// exchange, because the server may already have consumed the refresh token.
/// It executes while `CredentialStore`'s intrinsic lock is held. Re-entering
/// the same store from `rotate` returns `Busy` and must be treated as transient.
pub const Rotator = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const Error = error{ OutOfMemory, Cancelled };
    pub const VTable = struct {
        rotate: *const fn (
            std.mem.Allocator,
            std.Io,
            *anyopaque,
            Refresh.Request,
            ?Provider.Tick,
        ) Error!RotationResult,
    };

    pub fn from(implementation: anytype) Rotator {
        const Pointer = @TypeOf(implementation);
        const info = @typeInfo(Pointer);
        if (info != .pointer or info.pointer.size != .one) {
            @compileError("Rotator.from expects a single-item pointer");
        }
        const Implementation = info.pointer.child;
        const Adapter = struct {
            fn rotateFn(
                allocator: std.mem.Allocator,
                io: std.Io,
                context: *anyopaque,
                request: Refresh.Request,
                tick: ?Provider.Tick,
            ) Error!RotationResult {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.rotate(allocator, io, request, tick);
            }
            const vtable: VTable = .{ .rotate = rotateFn };
        };
        return .{ .context = implementation, .vtable = &Adapter.vtable };
    }

    pub fn rotate(
        self: Rotator,
        allocator: std.mem.Allocator,
        io: std.Io,
        request: Refresh.Request,
        tick: ?Provider.Tick,
    ) Error!RotationResult {
        return self.vtable.rotate(allocator, io, self.context, request, tick);
    }
};

pub const PublicationOutcome = union(enum) {
    none,
    adopted_disk,
    published,
    not_published: CredentialStore.MutationCause,
    uncertain: CredentialStore.MutationCause,
};

pub const InitFailure = struct {
    managed: Credentials.Status,
    codex_cli: Credentials.Status,
};

pub const InitResult = union(enum) {
    ready: ManagedSource,
    failure: InitFailure,
};

/// Heap-stable, move-only credential composition. Move the handle, never copy
/// and deinitialize two copies. Its dependencies must outlive it.
pub const ManagedSource = struct {
    state: *State,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        store: *CredentialStore.Store,
        cli_loader: Credentials.Loader,
        clock: Clock,
        rotator: Rotator,
    ) error{OutOfMemory}!InitResult {
        const resolved = try canonicalLoad(allocator, store, cli_loader);
        switch (resolved) {
            .failure => |failure| return .{ .failure = failure },
            .loaded => |loaded_value| {
                var loaded = loaded_value;
                errdefer loaded.deinit();
                const pin = try allocator.dupe(u8, loaded.account_id);
                errdefer SecureAllocator.wipeFree(allocator, pin);
                const state = try allocator.create(State);
                state.* = .{
                    .allocator = allocator,
                    .init_io = io,
                    .store = store,
                    .cli_loader = cli_loader,
                    .clock = clock,
                    .rotator = rotator,
                    .current = loaded,
                    .account_pin = pin,
                };
                return .{ .ready = .{ .state = state } };
            },
        }
    }

    /// No credential-source callback may be active when this is called.
    pub fn deinit(self: *ManagedSource) void {
        const state = self.state;
        state.current.deinit();
        SecureAllocator.wipeFree(state.allocator, state.account_pin);
        const allocator = state.allocator;
        state.* = undefined;
        allocator.destroy(state);
        self.* = undefined;
    }

    pub fn credentialSource(self: *ManagedSource) Codex.CredentialSource {
        return Codex.CredentialSource.from(self.state);
    }

    pub fn source(self: *const ManagedSource) Credentials.Source {
        self.state.mutex.lockUncancelable(self.state.init_io);
        defer self.state.mutex.unlock(self.state.init_io);
        return self.state.current.source;
    }

    pub fn pinnedAccountId(self: *const ManagedSource) []const u8 {
        return self.state.account_pin;
    }

    pub fn publicationOutcome(self: *const ManagedSource) PublicationOutcome {
        self.state.mutex.lockUncancelable(self.state.init_io);
        defer self.state.mutex.unlock(self.state.init_io);
        return self.state.publication;
    }
};

const State = struct {
    allocator: std.mem.Allocator,
    init_io: std.Io,
    store: *CredentialStore.Store,
    cli_loader: Credentials.Loader,
    clock: Clock,
    rotator: Rotator,
    current: Credentials.ResolvedLoaded,
    account_pin: []u8,
    cli_stale: bool = false,
    publication: PublicationOutcome = .none,
    available: bool = true,
    mutex: std.Io.Mutex = .init,

    pub fn acquire(
        self: *State,
        allocator: std.mem.Allocator,
        io: std.Io,
        tick: ?Provider.Tick,
        purpose: Codex.AcquirePurpose,
    ) Codex.CredentialSource.CallbackError!Codex.AcquireDecision {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (!self.available) return .{ .fail = .{ .message = "codex is not logged in — run /login" } };
        switch (self.current.source) {
            .codex_cli => if (self.cli_stale) try self.reloadCli(),
            .managed => switch (purpose) {
                .request => {
                    const now = self.clock.now(io);
                    if (try Refresh.tokenExpiring(self.allocator, self.current.access_token, now)) {
                        _ = try self.refresh(io, tick, false);
                    }
                },
                .metadata => {
                    const now = self.clock.now(io);
                    if (try expiringWithin(self.allocator, self.current.access_token, now, metadata_margin_seconds)) {
                        return .{ .fail = .{ .message = "codex metadata deferred until credentials refresh" } };
                    }
                },
            },
        }
        return .{ .ready = try Codex.OwnedCredential.init(allocator, self.current.credential()) };
    }

    pub fn recoverUnauthorized(
        self: *State,
        allocator: std.mem.Allocator,
        io: std.Io,
        tick: ?Provider.Tick,
        failed: Codex.Credential,
    ) Codex.CredentialSource.CallbackError!Codex.UnauthorizedDecision {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const current = self.current.credential();
        if (!std.mem.eql(u8, failed.account_id, self.account_pin)) return .use_response;
        if (!credentialsEqual(failed, current)) return .{ .retry = try Codex.OwnedCredential.init(allocator, current) };
        if (self.current.source == .codex_cli) return .{ .fail = .{
            .message = "codex CLI token expired — rerun `codex`, or use /login",
        } };

        return switch (try self.refresh(io, tick, true)) {
            .fresh => .{ .retry = try Codex.OwnedCredential.init(allocator, self.current.credential()) },
            .transient => .{ .fail = .{
                .message = "could not refresh the codex login — retry, or run /login",
            } },
            .dead => fallback: {
                if (try self.adoptCanonicalRecovery(failed)) {
                    break :fallback .{ .retry = try Codex.OwnedCredential.init(
                        allocator,
                        self.current.credential(),
                    ) };
                }
                self.available = false;
                break :fallback .{ .fail = .{
                    .message = "codex login expired — run /login again",
                } };
            },
        };
    }

    pub fn noteUnauthorized(self: *State, failed: Codex.Credential) void {
        self.mutex.lockUncancelable(self.init_io);
        defer self.mutex.unlock(self.init_io);
        if (self.current.source != .codex_cli) return;
        if (credentialsEqual(failed, self.current.credential())) self.cli_stale = true;
    }

    fn reloadCli(self: *State) error{OutOfMemory}!void {
        const result = try Credentials.load(self.allocator, self.cli_loader);
        switch (result) {
            .failure => {},
            .loaded => |loaded_value| {
                var loaded = loaded_value;
                if (!std.mem.eql(u8, loaded.account_id, self.account_pin) or
                    std.mem.eql(u8, loaded.access_token, self.current.access_token))
                {
                    loaded.deinit();
                    return;
                }
                const resolved = resolvedFromCli(&loaded);
                self.current.deinit();
                self.current = resolved;
                self.cli_stale = false;
            },
        }
    }

    fn adoptCanonicalRecovery(self: *State, failed: Codex.Credential) error{OutOfMemory}!bool {
        const result = try canonicalLoad(self.allocator, self.store, self.cli_loader);
        switch (result) {
            .failure => return false,
            .loaded => |loaded_value| {
                var loaded = loaded_value;
                if (!std.mem.eql(u8, loaded.account_id, self.account_pin) or
                    credentialsEqual(loaded.credential(), failed) or
                    credentialsEqual(loaded.credential(), self.current.credential()))
                {
                    loaded.deinit();
                    return false;
                }
                self.current.deinit();
                self.current = loaded;
                self.available = true;
                self.cli_stale = false;
                return true;
            },
        }
    }

    fn refresh(
        self: *State,
        io: std.Io,
        tick: ?Provider.Tick,
        force: bool,
    ) Codex.CredentialSource.CallbackError!RefreshOutcome {
        var transaction: RefreshTransaction = .{
            .source = self,
            .io = io,
            .tick = tick,
            .force = force,
            .now = self.clock.now(io),
        };
        var result = self.store.update(self.allocator, provider_id, .{
            .context = &transaction,
            .call_fn = refreshTransaction,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Cancelled,
            else => return .transient,
        };
        defer result.deinit(self.allocator);

        self.publication = switch (result) {
            .unchanged => if (transaction.adopted != null) .adopted_disk else .none,
            .published => .published,
            .not_published => |failure| .{ .not_published = failure.cause },
            .uncertain => |failure| .{ .uncertain = failure.cause },
        };
        if (transaction.adopted) |loaded_value| {
            var loaded = loaded_value;
            transaction.adopted = null;
            const resolved = resolvedFromManaged(&loaded);
            self.current.deinit();
            self.current = resolved;
            self.available = true;
            return .fresh;
        }
        return transaction.outcome;
    }
};

const RefreshOutcome = enum { fresh, transient, dead };

const RefreshTransaction = struct {
    source: *State,
    io: std.Io,
    tick: ?Provider.Tick,
    force: bool,
    now: u64,
    adopted: ?Credentials.ManagedLoaded = null,
    outcome: RefreshOutcome = .dead,

    fn deinitAdopted(self: *RefreshTransaction) void {
        if (self.adopted) |loaded_value| {
            var loaded = loaded_value;
            loaded.deinit();
            self.adopted = null;
        }
    }
};

fn refreshTransaction(
    allocator: std.mem.Allocator,
    context: *anyopaque,
    current_json: ?[]const u8,
) CredentialStore.CallbackError!CredentialStore.Decision {
    const tx: *RefreshTransaction = @ptrCast(@alignCast(context));
    errdefer tx.deinitAdopted();
    const bytes = current_json orelse return .keep;
    const parsed = Credentials.parseManaged(allocator, bytes) catch return error.OutOfMemory;
    var disk = switch (parsed) {
        .failure => return .keep,
        .loaded => |loaded| loaded,
    };
    defer disk.deinit();

    const memory = &tx.source.current;
    if (!std.mem.eql(u8, disk.account_id, tx.source.account_pin)) return .keep;

    const differs = !std.mem.eql(u8, disk.access_token, memory.access_token) or
        !std.mem.eql(u8, disk.refresh_token, memory.refresh_token.?);
    const disk_as_fresh = differs and (Refresh.tokenAsFresh(
        allocator,
        disk.access_token,
        memory.access_token,
    ) catch return error.OutOfMemory);
    if (disk_as_fresh) {
        const disk_expiring = Refresh.tokenExpiring(allocator, disk.access_token, tx.now) catch
            return error.OutOfMemory;
        if (tx.force or !disk_expiring) {
            tx.adopted = cloneManaged(allocator, &disk) catch return error.OutOfMemory;
            tx.outcome = .fresh;
            return .keep;
        }
    }

    const base: *const Credentials.ManagedLoaded = if (differs and !disk_as_fresh) base: {
        const copied = managedFromResolved(allocator, memory) catch return error.OutOfMemory;
        tx.adopted = copied;
        break :base &tx.adopted.?;
    } else &disk;
    const used_disk_refresh = std.mem.eql(u8, base.refresh_token, disk.refresh_token);
    var request = Refresh.request(allocator, base.refresh_token) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidRefreshToken => return .keep,
    };
    defer request.deinit();
    if (tx.tick) |tick| tick.poll() catch return error.Canceled;
    var rotation = tx.source.rotator.rotate(allocator, tx.io, request, tx.tick) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Cancelled => return error.Canceled,
    };
    defer rotation.deinit(allocator);
    switch (rotation) {
        .transient => {
            tx.outcome = .transient;
            tx.deinitAdopted();
            return .keep;
        },
        .response => |response| {
            if (response.body.len > maximum_rotation_body_bytes) {
                tx.outcome = .transient;
                tx.deinitAdopted();
                return .keep;
            }
            const merged = Refresh.mergeResponse(allocator, base, response.status, response.body) catch
                return error.OutOfMemory;
            switch (merged) {
                .merged => |loaded_value| {
                    tx.deinitAdopted();
                    tx.adopted = loaded_value;
                    tx.outcome = .fresh;
                    return .{ .write = serializeManaged(allocator, &tx.adopted.?) catch
                        return error.OutOfMemory };
                },
                .failure => {},
            }
            const rejected = Refresh.refreshRejected(allocator, response.status, response.body) catch
                return error.OutOfMemory;
            tx.deinitAdopted();
            if (rejected) {
                tx.outcome = .dead;
                return if (used_disk_refresh) .remove else .keep;
            }
            tx.outcome = .transient;
            return .keep;
        },
    }
}

const CanonicalResult = union(enum) {
    loaded: Credentials.ResolvedLoaded,
    failure: InitFailure,
};

fn canonicalLoad(
    allocator: std.mem.Allocator,
    store: *CredentialStore.Store,
    cli_loader: Credentials.Loader,
) error{OutOfMemory}!CanonicalResult {
    var managed_status: Credentials.Status = .missing;
    var store_result = store.get(allocator, provider_id) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    if (store_result) |*result| {
        defer result.deinit(allocator);
        switch (result.*) {
            .missing => managed_status = .missing,
            .corrupt => managed_status = .bad_json,
            .value => |bytes| switch (try Credentials.parseManaged(allocator, bytes)) {
                .failure => |status| managed_status = status,
                .loaded => |loaded_value| {
                    var loaded = loaded_value;
                    return .{ .loaded = resolvedFromManaged(&loaded) };
                },
            },
        }
    } else managed_status = .unreadable;

    const cli = try Credentials.load(allocator, cli_loader);
    return switch (cli) {
        .failure => |status| .{ .failure = .{ .managed = managed_status, .codex_cli = status } },
        .loaded => |loaded_value| loaded: {
            var value = loaded_value;
            break :loaded .{ .loaded = resolvedFromCli(&value) };
        },
    };
}

fn resolvedFromManaged(loaded: *Credentials.ManagedLoaded) Credentials.ResolvedLoaded {
    const result: Credentials.ResolvedLoaded = .{
        .allocator = loaded.allocator,
        .access_token = loaded.access_token,
        .refresh_token = loaded.refresh_token,
        .account_id = loaded.account_id,
        .id_token = loaded.id_token,
        .email = loaded.email,
        .source = .managed,
    };
    loaded.* = undefined;
    return result;
}

fn resolvedFromCli(loaded: *Credentials.Loaded) Credentials.ResolvedLoaded {
    const result: Credentials.ResolvedLoaded = .{
        .allocator = loaded.allocator,
        .access_token = loaded.access_token,
        .refresh_token = null,
        .account_id = loaded.account_id,
        .id_token = null,
        .email = loaded.email,
        .source = .codex_cli,
    };
    loaded.* = undefined;
    return result;
}

fn managedFromResolved(
    allocator: std.mem.Allocator,
    source: *const Credentials.ResolvedLoaded,
) error{OutOfMemory}!Credentials.ManagedLoaded {
    const refresh_token = source.refresh_token orelse return error.OutOfMemory;
    const access = try allocator.dupe(u8, source.access_token);
    errdefer SecureAllocator.wipeFree(allocator, access);
    const refresh = try allocator.dupe(u8, refresh_token);
    errdefer SecureAllocator.wipeFree(allocator, refresh);
    const account = try allocator.dupe(u8, source.account_id);
    errdefer SecureAllocator.wipeFree(allocator, account);
    const id = if (source.id_token) |value| try allocator.dupe(u8, value) else null;
    errdefer if (id) |value| SecureAllocator.wipeFree(allocator, value);
    const email = if (source.email) |value| try allocator.dupe(u8, value) else null;
    return .{
        .allocator = allocator,
        .access_token = access,
        .refresh_token = refresh,
        .account_id = account,
        .id_token = id,
        .email = email,
    };
}

fn cloneManaged(
    allocator: std.mem.Allocator,
    source: *const Credentials.ManagedLoaded,
) error{OutOfMemory}!Credentials.ManagedLoaded {
    const access = try allocator.dupe(u8, source.access_token);
    errdefer SecureAllocator.wipeFree(allocator, access);
    const refresh = try allocator.dupe(u8, source.refresh_token);
    errdefer SecureAllocator.wipeFree(allocator, refresh);
    const account = try allocator.dupe(u8, source.account_id);
    errdefer SecureAllocator.wipeFree(allocator, account);
    const id = if (source.id_token) |value| try allocator.dupe(u8, value) else null;
    errdefer if (id) |value| SecureAllocator.wipeFree(allocator, value);
    const email = if (source.email) |value| try allocator.dupe(u8, value) else null;
    return .{
        .allocator = allocator,
        .access_token = access,
        .refresh_token = refresh,
        .account_id = account,
        .id_token = id,
        .email = email,
    };
}

fn serializeManaged(
    allocator: std.mem.Allocator,
    loaded: *const Credentials.ManagedLoaded,
) error{OutOfMemory}![]u8 {
    var wiping = SecureAllocator.WipingAllocator.init(allocator);
    var arena = std.heap.ArenaAllocator.init(wiping.allocator());
    defer arena.deinit();
    const temporary = try std.json.Stringify.valueAlloc(arena.allocator(), .{
        .access_token = loaded.access_token,
        .refresh_token = loaded.refresh_token,
        .account_id = loaded.account_id,
        .id_token = loaded.id_token,
    }, .{});
    if (temporary.len > Credentials.maximum_file_bytes) return error.OutOfMemory;
    return allocator.dupe(u8, temporary);
}

fn credentialsEqual(a: Codex.Credential, b: Codex.Credential) bool {
    return std.mem.eql(u8, a.access_token, b.access_token) and
        std.mem.eql(u8, a.account_id, b.account_id);
}

fn expiringWithin(
    allocator: std.mem.Allocator,
    token: []const u8,
    now: u64,
    margin: u64,
) error{OutOfMemory}!bool {
    const expiration = (try Credentials.jwtExpiration(allocator, token)) orelse return false;
    const boundary = std.math.add(u64, now, margin) catch std.math.maxInt(u64);
    return expiration <= boundary;
}

const TestNonce = struct {
    value: u8 = 1,

    fn fill(context: *anyopaque, bytes: []u8) PrivateFileStore.Error!void {
        const self: *TestNonce = @ptrCast(@alignCast(context));
        @memset(bytes, self.value);
        self.value +%= 1;
    }
};

const TestCliLoader = struct {
    pub fn load(_: *TestCliLoader, _: std.mem.Allocator, _: usize) error{OutOfMemory}!Credentials.LoaderResult {
        return .missing;
    }
};

const TestRotator = struct {
    const Mode = enum { success, transient, terminal, out_of_memory, reenter };
    calls: usize = 0,
    mode: Mode = .success,
    store: ?*CredentialStore.Store = null,
    reentry_busy: bool = false,
    saw_disk_refresh: bool = false,

    pub fn rotate(
        self: *TestRotator,
        allocator: std.mem.Allocator,
        _: std.Io,
        request: Refresh.Request,
        _: ?Provider.Tick,
    ) Rotator.Error!RotationResult {
        self.calls += 1;
        self.saw_disk_refresh = std.mem.indexOf(u8, request.body, "disk-refresh") != null;
        return switch (self.mode) {
            .success => .{ .response = .{
                .status = 200,
                .body = try allocator.dupe(u8, "{\"access_token\":\"new-access\",\"refresh_token\":\"new-refresh\"}"),
            } },
            .transient => .transient,
            .terminal => .{ .response = .{
                .status = 400,
                .body = try allocator.dupe(u8, "{\"error\":\"invalid_grant\"}"),
            } },
            .out_of_memory => error.OutOfMemory,
            .reenter => reenter: {
                _ = self.store.?.set(allocator, provider_id, "{\"x\":true}") catch |err| {
                    self.reentry_busy = err == error.Busy;
                    break :reenter .transient;
                };
                break :reenter .transient;
            },
        };
    }
};

fn fixedNow(_: std.Io, _: ?*anyopaque) u64 {
    return 1000;
}

test "managed source proactively rotates once and keeps the adopted credential" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var nonce: TestNonce = .{};
    const nonce_source: PrivateFileStore.NonceSource = .{ .context = &nonce, .fill_fn = TestNonce.fill };
    var store = CredentialStore.Store.init(
        PrivateFileStore.Store.init(io, temporary.dir),
        nonce_source,
    );
    const expiring = "e.eyJleHAiOjE2MDB9.s";
    const set_result = try store.set(std.testing.allocator, provider_id, "{\"access_token\":\"" ++ expiring ++
        "\",\"refresh_token\":\"old-refresh\",\"account_id\":\"account\"}");
    try std.testing.expect(set_result == .published);

    var cli: TestCliLoader = .{};
    var rotator: TestRotator = .{};
    const initialized = try ManagedSource.init(
        std.testing.allocator,
        io,
        &store,
        Credentials.Loader.from(&cli),
        .{ .now_fn = fixedNow },
        Rotator.from(&rotator),
    );
    var source = switch (initialized) {
        .ready => |value| value,
        .failure => return error.TestUnexpectedResult,
    };
    defer source.deinit();
    const erased = source.credentialSource();
    var first = try erased.acquire(std.testing.allocator, io, null, .request);
    defer first.deinit();
    try std.testing.expectEqualStrings("new-access", first.ready.access_token);
    var second = try erased.acquire(std.testing.allocator, io, null, .request);
    defer second.deinit();
    try std.testing.expectEqualStrings("new-access", second.ready.access_token);
    try std.testing.expectEqual(@as(usize, 1), rotator.calls);
    try std.testing.expect(source.publicationOutcome() == .published);
}

fn seedManaged(store: *CredentialStore.Store) !void {
    const expiring = "e.eyJleHAiOjE2MDB9.s";
    const result = try store.set(std.testing.allocator, provider_id, "{\"access_token\":\"" ++ expiring ++
        "\",\"refresh_token\":\"old-refresh\",\"account_id\":\"account\"}");
    if (result != .published) return error.TestUnexpectedResult;
}

fn initTestSource(
    store: *CredentialStore.Store,
    cli: *TestCliLoader,
    rotator: *TestRotator,
) !ManagedSource {
    const result = try ManagedSource.init(
        std.testing.allocator,
        std.testing.io,
        store,
        Credentials.Loader.from(cli),
        .{ .now_fn = fixedNow },
        Rotator.from(rotator),
    );
    return switch (result) {
        .ready => |source| source,
        .failure => error.TestUnexpectedResult,
    };
}

test "locked refresh adopts a fresher disk lineage without a POST" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var nonce: TestNonce = .{};
    var store = CredentialStore.Store.init(
        PrivateFileStore.Store.init(io, temporary.dir),
        .{ .context = &nonce, .fill_fn = TestNonce.fill },
    );
    try seedManaged(&store);
    var cli: TestCliLoader = .{};
    var rotator: TestRotator = .{};
    var source = try initTestSource(&store, &cli, &rotator);
    defer source.deinit();
    const newer = "e.eyJleHAiOjE3MDB9.s";
    _ = try store.set(std.testing.allocator, provider_id, "{\"access_token\":\"" ++ newer ++
        "\",\"refresh_token\":\"disk-refresh\",\"account_id\":\"account\"}");
    var decision = try source.credentialSource().acquire(std.testing.allocator, io, null, .request);
    defer decision.deinit();
    try std.testing.expectEqualStrings(newer, decision.ready.access_token);
    try std.testing.expectEqual(@as(usize, 0), rotator.calls);
    try std.testing.expect(source.publicationOutcome() == .adopted_disk);
}

const TestCommitFailure = struct {
    fn write(_: std.Io, _: ?*anyopaque, _: std.Io.File, _: []const u8) PrivateFileStore.Error!void {
        return error.IoFailure;
    }

    fn rename(
        _: std.Io,
        _: ?*anyopaque,
        _: std.Io.Dir,
        _: []const u8,
        _: []const u8,
    ) PrivateFileStore.Error!void {
        return error.IoFailure;
    }
};

const TestPublication = enum { published, not_published, uncertain };

test "successful rotation is adopted for every publication outcome" {
    inline for (.{
        TestPublication.published,
        TestPublication.not_published,
        TestPublication.uncertain,
    }) |expected| {
        const io = std.testing.io;
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var nonce: TestNonce = .{};
        var store = CredentialStore.Store.init(
            PrivateFileStore.Store.init(io, temporary.dir),
            .{ .context = &nonce, .fill_fn = TestNonce.fill },
        );
        try seedManaged(&store);
        store.commit_ops = switch (expected) {
            .published => .standard,
            .not_published => .{ .write_fn = TestCommitFailure.write },
            .uncertain => .{ .rename_fn = TestCommitFailure.rename },
        };
        var cli: TestCliLoader = .{};
        var rotator: TestRotator = .{};
        var source = try initTestSource(&store, &cli, &rotator);
        defer source.deinit();
        var decision = try source.credentialSource().acquire(std.testing.allocator, io, null, .request);
        defer decision.deinit();
        try std.testing.expectEqualStrings("new-access", decision.ready.access_token);
        switch (expected) {
            .published => try std.testing.expect(source.publicationOutcome() == .published),
            .not_published => try std.testing.expect(source.publicationOutcome() == .not_published),
            .uncertain => try std.testing.expect(source.publicationOutcome() == .uncertain),
        }
    }
}

test "terminal removes transient retains and same-store reentry is transient" {
    inline for (.{ TestRotator.Mode.terminal, TestRotator.Mode.transient, TestRotator.Mode.reenter }) |mode| {
        const io = std.testing.io;
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var nonce: TestNonce = .{};
        var store = CredentialStore.Store.init(
            PrivateFileStore.Store.init(io, temporary.dir),
            .{ .context = &nonce, .fill_fn = TestNonce.fill },
        );
        try seedManaged(&store);
        var cli: TestCliLoader = .{};
        var rotator: TestRotator = .{ .mode = mode, .store = &store };
        var source = try initTestSource(&store, &cli, &rotator);
        defer source.deinit();
        var decision = try source.credentialSource().acquire(std.testing.allocator, io, null, .request);
        defer decision.deinit();
        try std.testing.expectEqualStrings("e.eyJleHAiOjE2MDB9.s", decision.ready.access_token);
        var stored = try store.get(std.testing.allocator, provider_id);
        defer stored.deinit(std.testing.allocator);
        if (mode == .terminal) try std.testing.expect(stored == .missing) else try std.testing.expect(stored == .value);
        if (mode == .reenter) try std.testing.expect(rotator.reentry_busy);
    }
}

const ScriptCliLoader = struct {
    bytes: []const u8,

    pub fn load(
        self: *ScriptCliLoader,
        allocator: std.mem.Allocator,
        _: usize,
    ) error{OutOfMemory}!Credentials.LoaderResult {
        return .{ .bytes = try allocator.dupe(u8, self.bytes) };
    }
};

test "CLI reload adopts only a changed token on the pinned account" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var nonce: TestNonce = .{};
    var store = CredentialStore.Store.init(
        PrivateFileStore.Store.init(io, temporary.dir),
        .{ .context = &nonce, .fill_fn = TestNonce.fill },
    );
    var cli: ScriptCliLoader = .{
        .bytes = "{\"tokens\":{\"access_token\":\"one\",\"account_id\":\"account\"}}",
    };
    var rotator: TestRotator = .{};
    const initialized = try ManagedSource.init(
        std.testing.allocator,
        io,
        &store,
        Credentials.Loader.from(&cli),
        .{ .now_fn = fixedNow },
        Rotator.from(&rotator),
    );
    var source = switch (initialized) {
        .ready => |value| value,
        .failure => return error.TestUnexpectedResult,
    };
    defer source.deinit();
    const erased = source.credentialSource();
    var first = try erased.acquire(std.testing.allocator, io, null, .request);
    erased.noteUnauthorized(first.ready.credential());
    first.deinit();
    cli.bytes = "{\"tokens\":{\"access_token\":\"two\",\"account_id\":\"account\"}}";
    var second = try erased.acquire(std.testing.allocator, io, null, .request);
    try std.testing.expectEqualStrings("two", second.ready.access_token);
    erased.noteUnauthorized(second.ready.credential());
    second.deinit();
    cli.bytes = "{\"tokens\":{\"access_token\":\"foreign\",\"account_id\":\"other\"}}";
    var third = try erased.acquire(std.testing.allocator, io, null, .request);
    defer third.deinit();
    try std.testing.expectEqualStrings("two", third.ready.access_token);
}

test "managed metadata defers inside sixty seconds without rotation" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var nonce: TestNonce = .{};
    var store = CredentialStore.Store.init(
        PrivateFileStore.Store.init(io, temporary.dir),
        .{ .context = &nonce, .fill_fn = TestNonce.fill },
    );
    const near = "e.eyJleHAiOjEwNjB9.s";
    _ = try store.set(std.testing.allocator, provider_id, "{\"access_token\":\"" ++ near ++
        "\",\"refresh_token\":\"refresh\",\"account_id\":\"account\"}");
    var cli: TestCliLoader = .{};
    var rotator: TestRotator = .{};
    var source = try initTestSource(&store, &cli, &rotator);
    defer source.deinit();
    var decision = try source.credentialSource().acquire(std.testing.allocator, io, null, .metadata);
    defer decision.deinit();
    try std.testing.expect(decision == .fail);
    try std.testing.expectEqual(@as(usize, 0), rotator.calls);
}

const CancelTick = struct {
    pub fn poll(_: *CancelTick) Provider.DeliveryError!void {
        return error.Cancelled;
    }
};

test "managed refresh preserves cancellation and rotation OOM" {
    inline for (.{ TestRotator.Mode.out_of_memory, TestRotator.Mode.success }) |mode| {
        const io = std.testing.io;
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var nonce: TestNonce = .{};
        var store = CredentialStore.Store.init(
            PrivateFileStore.Store.init(io, temporary.dir),
            .{ .context = &nonce, .fill_fn = TestNonce.fill },
        );
        try seedManaged(&store);
        var cli: TestCliLoader = .{};
        var rotator: TestRotator = .{ .mode = mode };
        var source = try initTestSource(&store, &cli, &rotator);
        defer source.deinit();
        if (mode == .out_of_memory) {
            try std.testing.expectError(error.OutOfMemory, source.credentialSource().acquire(
                std.testing.allocator,
                io,
                null,
                .request,
            ));
        } else {
            var cancel: CancelTick = .{};
            try std.testing.expectError(error.Cancelled, source.credentialSource().acquire(
                std.testing.allocator,
                io,
                Provider.Tick.from(&cancel),
                .request,
            ));
            try std.testing.expectEqual(@as(usize, 0), rotator.calls);
        }
    }
}

fn exerciseSerializeManaged(allocator: std.mem.Allocator) !void {
    const parsed = try Credentials.parseManaged(
        allocator,
        "{\"access_token\":\"secret-a\",\"refresh_token\":\"secret-r\"," ++
            "\"account_id\":\"account\"}",
    );
    var loaded = switch (parsed) {
        .loaded => |value| value,
        .failure => return error.TestUnexpectedResult,
    };
    defer loaded.deinit();
    const bytes = try serializeManaged(allocator, &loaded);
    SecureAllocator.wipeFree(allocator, bytes);
}

test "managed serialization wipes scratch and frees every OOM path" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseSerializeManaged, .{});
    var observer = SecureAllocator.FreeObserver.init(std.testing.allocator);
    try exerciseSerializeManaged(observer.allocator());
    try std.testing.expect(observer.zero_frees >= 5);
}

const BlockingRotator = struct {
    entered: std.atomic.Value(bool) = .init(false),
    released: std.atomic.Value(bool) = .init(false),

    pub fn rotate(
        self: *BlockingRotator,
        allocator: std.mem.Allocator,
        _: std.Io,
        _: Refresh.Request,
        _: ?Provider.Tick,
    ) Rotator.Error!RotationResult {
        self.entered.store(true, .release);
        while (!self.released.load(.acquire)) std.atomic.spinLoopHint();
        return .{ .response = .{
            .status = 200,
            .body = try allocator.dupe(
                u8,
                "{\"access_token\":\"thread-owned\"," ++
                    "\"refresh_token\":\"thread-refresh\"}",
            ),
        } };
    }
};

const AcquireThread = struct {
    source: Codex.CredentialSource,
    decision: ?Codex.AcquireDecision = null,
    failure: ?anyerror = null,
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *AcquireThread) void {
        self.decision = self.source.acquire(std.testing.allocator, std.testing.io, null, .request) catch |err| {
            self.failure = err;
            self.done.store(true, .release);
            return;
        };
        self.done.store(true, .release);
    }

    fn deinit(self: *AcquireThread) void {
        if (self.decision) |*decision| decision.deinit();
        self.* = undefined;
    }
};

test "managed callbacks serialize while returned credentials remain independently owned" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var nonce: TestNonce = .{};
    var store = CredentialStore.Store.init(
        PrivateFileStore.Store.init(io, temporary.dir),
        .{ .context = &nonce, .fill_fn = TestNonce.fill },
    );
    try seedManaged(&store);
    var cli: TestCliLoader = .{};
    var rotator: BlockingRotator = .{};
    const initialized = try ManagedSource.init(
        std.testing.allocator,
        io,
        &store,
        Credentials.Loader.from(&cli),
        .{ .now_fn = fixedNow },
        Rotator.from(&rotator),
    );
    var source = switch (initialized) {
        .ready => |value| value,
        .failure => return error.TestUnexpectedResult,
    };
    defer source.deinit();
    const erased = source.credentialSource();
    var first: AcquireThread = .{ .source = erased };
    defer first.deinit();
    var second: AcquireThread = .{ .source = erased };
    defer second.deinit();
    const first_thread = try std.Thread.spawn(.{}, AcquireThread.run, .{&first});
    while (!rotator.entered.load(.acquire)) std.atomic.spinLoopHint();
    const second_thread = try std.Thread.spawn(.{}, AcquireThread.run, .{&second});
    try std.testing.expect(!second.done.load(.acquire));
    rotator.released.store(true, .release);
    first_thread.join();
    second_thread.join();
    try std.testing.expect(first.failure == null);
    try std.testing.expect(second.failure == null);
    try std.testing.expectEqualStrings("thread-owned", first.decision.?.ready.access_token);
    try std.testing.expectEqualStrings("thread-owned", second.decision.?.ready.access_token);
    @memset(source.state.current.access_token, 'x');
    try std.testing.expectEqualStrings("thread-owned", first.decision.?.ready.access_token);
    try std.testing.expectEqualStrings("thread-owned", second.decision.?.ready.access_token);
}

test "proactive refresh rotates a changed disk token that is still expiring" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var nonce: TestNonce = .{};
    var store = CredentialStore.Store.init(
        PrivateFileStore.Store.init(io, temporary.dir),
        .{ .context = &nonce, .fill_fn = TestNonce.fill },
    );
    try seedManaged(&store);
    var cli: TestCliLoader = .{};
    var rotator: TestRotator = .{};
    var source = try initTestSource(&store, &cli, &rotator);
    defer source.deinit();
    _ = try store.set(
        std.testing.allocator,
        provider_id,
        "{\"access_token\":\"e.eyJleHAiOjE2MDB9.s\"," ++
            "\"refresh_token\":\"disk-refresh\",\"account_id\":\"account\"}",
    );
    var decision = try source.credentialSource().acquire(std.testing.allocator, io, null, .request);
    defer decision.deinit();
    try std.testing.expectEqualStrings("new-access", decision.ready.access_token);
    try std.testing.expectEqual(@as(usize, 1), rotator.calls);
    try std.testing.expect(rotator.saw_disk_refresh);
}

fn initScriptSource(
    store: *CredentialStore.Store,
    cli: *ScriptCliLoader,
    rotator: *TestRotator,
) !ManagedSource {
    const initialized = try ManagedSource.init(
        std.testing.allocator,
        std.testing.io,
        store,
        Credentials.Loader.from(cli),
        .{ .now_fn = fixedNow },
        Rotator.from(rotator),
    );
    return switch (initialized) {
        .ready => |source| source,
        .failure => error.TestUnexpectedResult,
    };
}

test "forced terminal recovery retries a different stale-behind managed credential" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var nonce: TestNonce = .{};
    var store = CredentialStore.Store.init(
        PrivateFileStore.Store.init(io, temporary.dir),
        .{ .context = &nonce, .fill_fn = TestNonce.fill },
    );
    try seedManaged(&store);
    var cli: TestCliLoader = .{};
    var rotator: TestRotator = .{ .mode = .terminal };
    var source = try initTestSource(&store, &cli, &rotator);
    defer source.deinit();
    const failed = source.state.current.credential();
    _ = try store.set(
        std.testing.allocator,
        provider_id,
        "{\"access_token\":\"e.eyJleHAiOjE1MDB9.s\"," ++
            "\"refresh_token\":\"disk-refresh\",\"account_id\":\"account\"}",
    );
    var decision = try source.credentialSource().recoverUnauthorized(
        std.testing.allocator,
        io,
        null,
        failed,
    );
    defer decision.deinit();
    try std.testing.expect(decision == .retry);
    try std.testing.expectEqualStrings("e.eyJleHAiOjE1MDB9.s", decision.retry.access_token);
    try std.testing.expectEqual(@as(usize, 1), rotator.calls);
}

test "forced terminal recovery honors canonical precedence before CLI fallback" {
    inline for (.{ false, true }) |publish_remove| {
        const io = std.testing.io;
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var nonce: TestNonce = .{};
        var store = CredentialStore.Store.init(
            PrivateFileStore.Store.init(io, temporary.dir),
            .{ .context = &nonce, .fill_fn = TestNonce.fill },
        );
        try seedManaged(&store);
        if (!publish_remove) store.commit_ops = .{ .write_fn = TestCommitFailure.write };
        var cli: ScriptCliLoader = .{ .bytes = "{\"tokens\":{\"access_token\":\"cli-fallback\"," ++
            "\"account_id\":\"account\"}}" };
        var rotator: TestRotator = .{ .mode = .terminal };
        var source = try initScriptSource(&store, &cli, &rotator);
        defer source.deinit();
        const failed = source.state.current.credential();
        var decision = try source.credentialSource().recoverUnauthorized(
            std.testing.allocator,
            io,
            null,
            failed,
        );
        defer decision.deinit();
        if (publish_remove) {
            try std.testing.expect(decision == .retry);
            try std.testing.expectEqualStrings("cli-fallback", decision.retry.access_token);
        } else {
            try std.testing.expect(decision == .fail);
            var later = try source.credentialSource().acquire(std.testing.allocator, io, null, .request);
            defer later.deinit();
            try std.testing.expect(later == .fail);
        }
    }
}
