const std = @import("std");
const Codex = @import("Codex.zig");
const Provider = @import("Provider.zig");
const SecureAllocator = @import("SecureAllocator.zig");

pub const maximum_file_bytes: usize = 64 * 1024;
pub const maximum_depth: usize = 16;
pub const maximum_tokens: usize = 4096;
pub const maximum_string_bytes: usize = 8 * 1024;
pub const maximum_access_token_bytes: usize = 8 * 1024;
pub const maximum_refresh_token_bytes: usize = 8 * 1024;
pub const maximum_account_id_bytes: usize = 1024;
pub const maximum_id_token_bytes: usize = 8 * 1024;
pub const maximum_jwt_payload_bytes: usize = 16 * 1024;

pub const Status = enum { missing, unreadable, bad_json, no_tokens };

/// One read of the injected auth.json location. `bytes` must be allocated by
/// the allocator passed to `load`; the caller frees it with that allocator.
pub const LoaderResult = union(enum) {
    bytes: []u8,
    missing,
    unreadable,
};

/// Erased, synchronous file loader. The implementation must outlive every copy
/// of this handle and every BorrowedCliSource made from it. It must not return
/// more than `maximum_bytes` bytes.
pub const Loader = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        load: *const fn (std.mem.Allocator, *anyopaque, usize) error{OutOfMemory}!LoaderResult,
    };

    pub fn from(implementation: anytype) Loader {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("Loader.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn loadFn(
                allocator: std.mem.Allocator,
                context: *anyopaque,
                maximum_bytes: usize,
            ) error{OutOfMemory}!LoaderResult {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.load(allocator, maximum_bytes);
            }
            const vtable: VTable = .{ .load = loadFn };
        };
        return .{ .context = implementation, .vtable = &Adapter.vtable };
    }

    pub fn load(
        self: Loader,
        allocator: std.mem.Allocator,
        maximum_bytes: usize,
    ) error{OutOfMemory}!LoaderResult {
        return self.vtable.load(allocator, self.context, maximum_bytes);
    }
};

/// Owned credentials read from the Codex CLI file. Move this value; do not copy it.
pub const Loaded = struct {
    allocator: std.mem.Allocator,
    access_token: []u8,
    account_id: []u8,
    email: ?[]u8,

    pub fn deinit(self: *Loaded) void {
        freeSecret(self.allocator, self.access_token);
        freeSecret(self.allocator, self.account_id);
        if (self.email) |email| freeSecret(self.allocator, email);
        self.* = undefined;
    }

    pub fn credential(self: *const Loaded) Codex.Credential {
        return .{ .access_token = self.access_token, .account_id = self.account_id };
    }
};

pub const LoadResult = union(enum) {
    loaded: Loaded,
    failure: Status,
};

pub fn load(allocator: std.mem.Allocator, loader: Loader) error{OutOfMemory}!LoadResult {
    const raw = try loader.load(allocator, maximum_file_bytes);
    switch (raw) {
        .missing => return .{ .failure = .missing },
        .unreadable => return .{ .failure = .unreadable },
        .bytes => |bytes| {
            defer freeSecret(allocator, bytes);
            if (bytes.len > maximum_file_bytes) return .{ .failure = .unreadable };
            return parse(allocator, bytes);
        },
    }
}

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}!LoadResult {
    if (bytes.len > maximum_file_bytes) return .{ .failure = .bad_json };
    var wiping = SecureAllocator.WipingAllocator.init(allocator);
    var arena = std.heap.ArenaAllocator.init(wiping.allocator());
    defer arena.deinit();
    const temporary = arena.allocator();
    if (!(try validateJsonBounds(temporary, bytes, maximum_depth, maximum_tokens, maximum_string_bytes))) {
        return .{ .failure = .bad_json };
    }
    var parsed = std.json.parseFromSlice(std.json.Value, temporary, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .use_last,
        .max_value_len = maximum_string_bytes,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = .bad_json },
    };
    defer {
        scrubJson(&parsed.value);
        parsed.deinit();
    }

    const root = switch (parsed.value) {
        .object => |*object| object,
        else => return .{ .failure = .no_tokens },
    };
    const tokens_value = root.getPtr("tokens") orelse return .{ .failure = .no_tokens };
    const tokens = switch (tokens_value.*) {
        .object => |*object| object,
        else => return .{ .failure = .no_tokens },
    };
    const access_token = requiredString(tokens, "access_token", maximum_access_token_bytes) orelse
        return .{ .failure = .no_tokens };
    const account_id = requiredString(tokens, "account_id", maximum_account_id_bytes) orelse
        return .{ .failure = .no_tokens };
    if (hasHeaderControl(access_token) or hasHeaderControl(account_id)) {
        return .{ .failure = .no_tokens };
    }

    const owned_access = try allocator.dupe(u8, access_token);
    errdefer freeSecret(allocator, owned_access);
    const owned_account = try allocator.dupe(u8, account_id);
    errdefer freeSecret(allocator, owned_account);
    var email: ?[]u8 = null;
    if (optionalString(tokens, "id_token", maximum_id_token_bytes)) |id_token| {
        email = try jwtEmail(allocator, id_token);
    }
    errdefer if (email) |value| freeSecret(allocator, value);
    return .{ .loaded = .{
        .allocator = allocator,
        .access_token = owned_access,
        .account_id = owned_account,
        .email = email,
    } };
}

fn freeSecret(allocator: std.mem.Allocator, value: []u8) void {
    SecureAllocator.wipeFree(allocator, value);
}

fn scrubJson(value: *std.json.Value) void {
    switch (value.*) {
        .string => |text| std.crypto.secureZero(u8, @constCast(text)),
        .array => |*array| for (array.items) |*item| scrubJson(item),
        .object => |*object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| scrubJson(entry.value_ptr);
        },
        else => {},
    }
}

fn requiredString(object: *const std.json.ObjectMap, key: []const u8, maximum: usize) ?[]const u8 {
    const value = object.get(key) orelse return null;
    const text = switch (value) {
        .string => |text| text,
        else => return null,
    };
    if (text.len == 0 or text.len > maximum) return null;
    return text;
}

fn optionalString(object: *const std.json.ObjectMap, key: []const u8, maximum: usize) ?[]const u8 {
    return requiredString(object, key, maximum);
}

fn hasHeaderControl(text: []const u8) bool {
    for (text) |byte| if (byte < 0x20 or byte == 0x7f) return true;
    return false;
}

fn validateJsonBounds(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    depth_limit: usize,
    token_limit: usize,
    string_limit: usize,
) error{OutOfMemory}!bool {
    var scanner = std.json.Scanner.initCompleteInput(allocator, bytes);
    defer scanner.deinit();
    var depth: usize = 0;
    var token_count: usize = 0;
    while (true) {
        const token_type = scanner.peekNextTokenType() catch return false;
        const limit = if (token_type == .string) string_limit else bytes.len;
        const token = scanner.nextAllocMax(allocator, .alloc_if_needed, limit) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return false,
        };
        defer switch (token) {
            .allocated_string => |text| freeSecret(allocator, text),
            .allocated_number => |text| freeSecret(allocator, text),
            else => {},
        };
        if (token == .end_of_document) return depth == 0;
        token_count += 1;
        if (token_count > token_limit) return false;
        switch (token) {
            .object_begin, .array_begin => {
                depth += 1;
                if (depth > depth_limit) return false;
            },
            .object_end, .array_end => {
                if (depth == 0) return false;
                depth -= 1;
            },
            else => {},
        }
    }
}

/// Owned, unverified JWT payload. Claims are display and routing inputs only.
pub const JwtPayloadState = struct {
    allocator: std.mem.Allocator,
    wiping: SecureAllocator.WipingAllocator,
    arena: std.heap.ArenaAllocator,
    parsed: ?std.json.Parsed(std.json.Value) = null,

    fn destroy(self: *JwtPayloadState) void {
        if (self.parsed) |*parsed| parsed.deinit();
        self.arena.deinit();
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};

pub const JwtPayload = struct {
    state: *JwtPayloadState,

    pub fn deinit(self: *JwtPayload) void {
        self.state.destroy();
        self.* = undefined;
    }

    pub fn root(self: *const JwtPayload) ?*const std.json.ObjectMap {
        return switch (self.state.parsed.?.value) {
            .object => |*object| object,
            else => null,
        };
    }
};

pub fn parseJwtPayload(allocator: std.mem.Allocator, jwt: []const u8) error{OutOfMemory}!?JwtPayload {
    if (jwt.len == 0 or jwt.len > maximum_id_token_bytes) return null;
    const first = std.mem.indexOfScalar(u8, jwt, '.') orelse return null;
    const after_first = first + 1;
    const relative_second = std.mem.indexOfScalar(u8, jwt[after_first..], '.') orelse return null;
    const encoded = jwt[after_first .. after_first + relative_second];
    if (encoded.len == 0) return null;
    const padded = std.mem.endsWith(u8, encoded, "=");
    const decoded_length = if (padded)
        std.base64.url_safe.Decoder.calcSizeForSlice(encoded) catch return null
    else
        std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(encoded) catch return null;
    if (decoded_length == 0 or decoded_length > maximum_jwt_payload_bytes) return null;

    const state = try allocator.create(JwtPayloadState);
    state.allocator = allocator;
    state.wiping = SecureAllocator.WipingAllocator.init(allocator);
    state.arena = std.heap.ArenaAllocator.init(state.wiping.allocator());
    state.parsed = null;
    var retained = false;
    defer if (!retained) state.destroy();
    const temporary = state.arena.allocator();

    const decoded = try temporary.alloc(u8, decoded_length);
    if (padded)
        std.base64.url_safe.Decoder.decode(decoded, encoded) catch return null
    else
        std.base64.url_safe_no_pad.Decoder.decode(decoded, encoded) catch return null;
    if (!(try validateJsonBounds(temporary, decoded, maximum_depth, maximum_tokens, maximum_string_bytes))) {
        return null;
    }
    state.parsed = std.json.parseFromSlice(std.json.Value, temporary, decoded, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .use_last,
        .max_value_len = maximum_string_bytes,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (state.parsed.?.value != .object) return null;
    retained = true;
    return .{ .state = state };
}

pub fn jwtEmail(allocator: std.mem.Allocator, jwt: []const u8) error{OutOfMemory}!?[]u8 {
    var payload = (try parseJwtPayload(allocator, jwt)) orelse return null;
    defer payload.deinit();
    const root = payload.root().?;
    if (claimString(root, "email")) |email| {
        const owned: ?[]u8 = try allocator.dupe(u8, email);
        return owned;
    }
    const profile_value = root.get("https://api.openai.com/profile") orelse return null;
    const profile = switch (profile_value) {
        .object => |*object| object,
        else => return null,
    };
    const email = claimString(profile, "email") orelse return null;
    const owned: ?[]u8 = try allocator.dupe(u8, email);
    return owned;
}

pub fn jwtExpiration(allocator: std.mem.Allocator, jwt: []const u8) error{OutOfMemory}!?u64 {
    var payload = (try parseJwtPayload(allocator, jwt)) orelse return null;
    defer payload.deinit();
    const value = payload.root().?.get("exp") orelse return null;
    return switch (value) {
        .integer => |number| if (number > 0) @intCast(number) else null,
        .float => |number| blk: {
            if (!std.math.isFinite(number) or number < 1 or number >= @as(f64, 0x1p64)) {
                break :blk null;
            }
            break :blk @intFromFloat(number);
        },
        else => null,
    };
}

pub fn jwtAccountId(allocator: std.mem.Allocator, jwt: []const u8) error{OutOfMemory}!?[]u8 {
    var payload = (try parseJwtPayload(allocator, jwt)) orelse return null;
    defer payload.deinit();
    const auth_value = payload.root().?.get("https://api.openai.com/auth") orelse return null;
    const auth = switch (auth_value) {
        .object => |*object| object,
        else => return null,
    };
    const account_id = claimString(auth, "chatgpt_account_id") orelse return null;
    const owned: ?[]u8 = try allocator.dupe(u8, account_id);
    return owned;
}

fn claimString(object: *const std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    const text = switch (value) {
        .string => |text| text,
        else => return null,
    };
    return if (text.len > 0 and text.len <= maximum_string_bytes) text else null;
}

pub fn failureOverride(status: Status) Codex.FailureOverride {
    return .{ .message = switch (status) {
        .missing, .no_tokens => "not logged in (authenticate with the Codex CLI)",
        .unreadable => "could not read Codex CLI auth.json",
        .bad_json => "auth.json not valid JSON",
    } };
}

/// Owned credentials from Zi's managed Codex provider entry. Move this value; do not copy it.
pub const ManagedLoaded = struct {
    allocator: std.mem.Allocator,
    access_token: []u8,
    refresh_token: []u8,
    account_id: []u8,
    id_token: ?[]u8,
    email: ?[]u8,

    pub fn deinit(self: *ManagedLoaded) void {
        freeSecret(self.allocator, self.access_token);
        freeSecret(self.allocator, self.refresh_token);
        freeSecret(self.allocator, self.account_id);
        if (self.id_token) |value| freeSecret(self.allocator, value);
        if (self.email) |value| freeSecret(self.allocator, value);
        self.* = undefined;
    }

    pub fn credential(self: *const ManagedLoaded) Codex.Credential {
        return .{ .access_token = self.access_token, .account_id = self.account_id };
    }
};

pub const ManagedLoadResult = union(enum) {
    loaded: ManagedLoaded,
    failure: Status,
};

pub fn loadManaged(allocator: std.mem.Allocator, loader: Loader) error{OutOfMemory}!ManagedLoadResult {
    const raw = try loader.load(allocator, maximum_file_bytes);
    switch (raw) {
        .missing => return .{ .failure = .missing },
        .unreadable => return .{ .failure = .unreadable },
        .bytes => |bytes| {
            defer freeSecret(allocator, bytes);
            if (bytes.len > maximum_file_bytes) return .{ .failure = .unreadable };
            return parseManaged(allocator, bytes);
        },
    }
}

/// Parse one provider entry, not the credential-store document around it.
pub fn parseManaged(allocator: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}!ManagedLoadResult {
    if (bytes.len > maximum_file_bytes) return .{ .failure = .bad_json };
    var wiping = SecureAllocator.WipingAllocator.init(allocator);
    var arena = std.heap.ArenaAllocator.init(wiping.allocator());
    defer arena.deinit();
    const temporary = arena.allocator();
    if (!(try validateJsonBounds(temporary, bytes, maximum_depth, maximum_tokens, maximum_string_bytes))) {
        return .{ .failure = .bad_json };
    }
    var parsed = std.json.parseFromSlice(std.json.Value, temporary, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .use_last,
        .max_value_len = maximum_string_bytes,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = .bad_json },
    };
    defer {
        scrubJson(&parsed.value);
        parsed.deinit();
    }

    const entry = switch (parsed.value) {
        .object => |*object| object,
        else => return .{ .failure = .no_tokens },
    };
    const access_token = requiredString(entry, "access_token", maximum_access_token_bytes) orelse
        return .{ .failure = .no_tokens };
    const refresh_token = requiredString(entry, "refresh_token", maximum_refresh_token_bytes) orelse
        return .{ .failure = .no_tokens };
    const account_id = requiredString(entry, "account_id", maximum_account_id_bytes) orelse
        return .{ .failure = .no_tokens };
    if (hasHeaderControl(access_token) or hasHeaderControl(account_id)) {
        return .{ .failure = .no_tokens };
    }
    const id_token = optionalString(entry, "id_token", maximum_id_token_bytes);

    const owned_access = try allocator.dupe(u8, access_token);
    errdefer freeSecret(allocator, owned_access);
    const owned_refresh = try allocator.dupe(u8, refresh_token);
    errdefer freeSecret(allocator, owned_refresh);
    const owned_account = try allocator.dupe(u8, account_id);
    errdefer freeSecret(allocator, owned_account);
    const owned_id = if (id_token) |value| try allocator.dupe(u8, value) else null;
    errdefer if (owned_id) |value| freeSecret(allocator, value);
    const email = if (id_token) |value| try jwtEmail(allocator, value) else null;
    errdefer if (email) |value| freeSecret(allocator, value);

    return .{ .loaded = .{
        .allocator = allocator,
        .access_token = owned_access,
        .refresh_token = owned_refresh,
        .account_id = owned_account,
        .id_token = owned_id,
        .email = email,
    } };
}

pub const Source = enum { managed, codex_cli };

/// Canonical owned credential returned by resolve. Move this value; do not copy it.
pub const ResolvedLoaded = struct {
    allocator: std.mem.Allocator,
    access_token: []u8,
    refresh_token: ?[]u8,
    account_id: []u8,
    id_token: ?[]u8,
    email: ?[]u8,
    source: Source,

    pub fn deinit(self: *ResolvedLoaded) void {
        freeSecret(self.allocator, self.access_token);
        if (self.refresh_token) |value| freeSecret(self.allocator, value);
        freeSecret(self.allocator, self.account_id);
        if (self.id_token) |value| freeSecret(self.allocator, value);
        if (self.email) |value| freeSecret(self.allocator, value);
        self.* = undefined;
    }

    pub fn credential(self: *const ResolvedLoaded) Codex.Credential {
        return .{ .access_token = self.access_token, .account_id = self.account_id };
    }
};

pub const ResolveFailure = struct {
    managed: Status,
    codex_cli: Status,
};

pub const ResolveResult = union(enum) {
    loaded: ResolvedLoaded,
    failure: ResolveFailure,
};

/// Prefer managed credentials. Any unusable managed entry falls through to the CLI loader.
pub fn resolve(
    allocator: std.mem.Allocator,
    managed_loader: Loader,
    cli_loader: Loader,
) error{OutOfMemory}!ResolveResult {
    const managed_result = try loadManaged(allocator, managed_loader);
    const managed_status: Status = switch (managed_result) {
        .loaded => |managed_value| {
            var managed = managed_value;
            const resolved: ResolvedLoaded = .{
                .allocator = managed.allocator,
                .access_token = managed.access_token,
                .refresh_token = managed.refresh_token,
                .account_id = managed.account_id,
                .id_token = managed.id_token,
                .email = managed.email,
                .source = .managed,
            };
            managed = undefined;
            return .{ .loaded = resolved };
        },
        .failure => |status| status,
    };

    const cli_result = try load(allocator, cli_loader);
    switch (cli_result) {
        .loaded => |cli_value| {
            var cli = cli_value;
            const resolved: ResolvedLoaded = .{
                .allocator = cli.allocator,
                .access_token = cli.access_token,
                .refresh_token = null,
                .account_id = cli.account_id,
                .id_token = null,
                .email = cli.email,
                .source = .codex_cli,
            };
            cli = undefined;
            return .{ .loaded = resolved };
        },
        .failure => |status| return .{ .failure = .{
            .managed = managed_status,
            .codex_cli = status,
        } },
    }
}

pub const InitResult = union(enum) {
    ready: BorrowedCliSource,
    failure: Status,
};

/// Read-only adapter for Codex CLI credentials. Move this value; do not copy it.
/// The allocator, I/O, and Loader implementation passed to init must outlive it.
pub const BorrowedCliSource = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    loader: Loader,
    mutex: std.Io.Mutex = .init,
    current: Loaded,
    pinned_account_id: []u8,
    stale: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        loader: Loader,
    ) error{OutOfMemory}!InitResult {
        const result = try load(allocator, loader);
        switch (result) {
            .failure => |status| return .{ .failure = status },
            .loaded => |loaded_value| {
                var loaded = loaded_value;
                errdefer loaded.deinit();
                const pin = try allocator.dupe(u8, loaded.account_id);
                return .{ .ready = .{
                    .allocator = allocator,
                    .io = io,
                    .loader = loader,
                    .current = loaded,
                    .pinned_account_id = pin,
                } };
            },
        }
    }

    /// No credential-source callback may be active when this is called.
    pub fn deinit(self: *BorrowedCliSource) void {
        self.current.deinit();
        freeSecret(self.allocator, self.pinned_account_id);
        self.* = undefined;
    }

    pub fn credentialSource(self: *BorrowedCliSource) Codex.CredentialSource {
        return Codex.CredentialSource.from(self);
    }

    pub fn acquire(
        self: *BorrowedCliSource,
        allocator: std.mem.Allocator,
        io: std.Io,
        _: ?Provider.Tick,
        purpose: Codex.AcquirePurpose,
    ) Codex.CredentialSource.CallbackError!Codex.AcquireDecision {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        std.debug.assert(purpose == .request);
        if (self.stale) try self.reloadIfChanged();
        return .{ .ready = try Codex.OwnedCredential.init(allocator, self.current.credential()) };
    }

    fn reloadIfChanged(self: *BorrowedCliSource) error{OutOfMemory}!void {
        const result = try load(self.allocator, self.loader);
        switch (result) {
            .failure => return,
            .loaded => |loaded_value| {
                var candidate = loaded_value;
                if (!std.mem.eql(u8, candidate.account_id, self.pinned_account_id) or
                    std.mem.eql(u8, candidate.access_token, self.current.access_token))
                {
                    candidate.deinit();
                    return;
                }
                self.current.deinit();
                self.current = candidate;
                self.stale = false;
            },
        }
    }

    pub fn recoverUnauthorized(
        self: *BorrowedCliSource,
        _: std.mem.Allocator,
        io: std.Io,
        _: ?Provider.Tick,
        _: Codex.Credential,
    ) Codex.CredentialSource.CallbackError!Codex.UnauthorizedDecision {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return .{ .fail = .{
            .message = "codex CLI token expired — rerun the Codex CLI to authenticate",
        } };
    }

    pub fn noteUnauthorized(self: *BorrowedCliSource, failed: Codex.Credential) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const current = self.current.credential();
        if (std.mem.eql(u8, failed.access_token, current.access_token) and
            std.mem.eql(u8, failed.account_id, current.account_id))
        {
            self.stale = true;
        }
    }
};

const TestLoader = struct {
    value: union(enum) { bytes: []const u8, missing, unreadable },
    loads: usize = 0,

    fn load(self: *TestLoader, allocator: std.mem.Allocator, maximum_bytes: usize) !LoaderResult {
        self.loads += 1;
        _ = maximum_bytes;
        return switch (self.value) {
            .bytes => |bytes| .{ .bytes = try allocator.dupe(u8, bytes) },
            .missing => .missing,
            .unreadable => .unreadable,
        };
    }
};

fn expectFailure(expected: Status, result: LoadResult) !void {
    switch (result) {
        .failure => |actual| try std.testing.expectEqual(expected, actual),
        .loaded => |loaded_value| {
            var loaded = loaded_value;
            loaded.deinit();
            return error.TestUnexpectedResult;
        },
    }
}

fn expectParsed(bytes: []const u8) !Loaded {
    const result = try parse(std.testing.allocator, bytes);
    return switch (result) {
        .loaded => |loaded| loaded,
        .failure => error.TestUnexpectedResult,
    };
}

test "Codex CLI auth schema is strict only for required token fields" {
    var loaded = try expectParsed(
        "{\"unknown\":[1,true],\"tokens\":{" ++
            "\"access_token\":\"access\",\"account_id\":\"account\",\"future\":{}}}",
    );
    defer loaded.deinit();
    try std.testing.expectEqualStrings("access", loaded.access_token);
    try std.testing.expectEqualStrings("account", loaded.account_id);
    try std.testing.expectEqual(@as(?[]u8, null), loaded.email);

    try expectFailure(.no_tokens, try parse(std.testing.allocator, "{}"));
    try expectFailure(.no_tokens, try parse(std.testing.allocator, "{\"tokens\":null}"));
    try expectFailure(.no_tokens, try parse(
        std.testing.allocator,
        "{\"tokens\":{\"access_token\":\"\",\"account_id\":\"a\"}}",
    ));
    try expectFailure(.no_tokens, try parse(
        std.testing.allocator,
        "{\"tokens\":{\"access_token\":7,\"account_id\":\"a\"}}",
    ));
}

test "malformed bounded JSON and header controls are rejected" {
    try expectFailure(.bad_json, try parse(std.testing.allocator, "{"));
    try expectFailure(.no_tokens, try parse(std.testing.allocator, "[]"));
    try expectFailure(.no_tokens, try parse(
        std.testing.allocator,
        "{\"tokens\":{\"access_token\":\"a\\nb\",\"account_id\":\"id\"}}",
    ));

    var deep = std.ArrayList(u8).empty;
    defer deep.deinit(std.testing.allocator);
    try deep.appendNTimes(std.testing.allocator, '[', maximum_depth + 1);
    try deep.appendNTimes(std.testing.allocator, ']', maximum_depth + 1);
    try expectFailure(.bad_json, try parse(std.testing.allocator, deep.items));

    const long_access = "x" ** (maximum_access_token_bytes + 1);
    var document = std.ArrayList(u8).empty;
    defer document.deinit(std.testing.allocator);
    try document.appendSlice(std.testing.allocator, "{\"tokens\":{\"access_token\":\"");
    try document.appendSlice(std.testing.allocator, long_access);
    try document.appendSlice(std.testing.allocator, "\",\"account_id\":\"a\"}}");
    try expectFailure(.bad_json, try parse(std.testing.allocator, document.items));
}

test "loader statuses remain distinct and returned bytes are owned" {
    var loader_state: TestLoader = .{ .value = .missing };
    try expectFailure(.missing, try load(std.testing.allocator, Loader.from(&loader_state)));
    loader_state.value = .unreadable;
    try expectFailure(.unreadable, try load(std.testing.allocator, Loader.from(&loader_state)));
    loader_state.value = .{ .bytes = "not json" };
    try expectFailure(.bad_json, try load(std.testing.allocator, Loader.from(&loader_state)));
    try std.testing.expectEqual(@as(usize, 3), loader_state.loads);
}

test "JWT helpers decode bounded unverified claims" {
    const token = "e.eyJlbWFpbCI6InRvcEBleGFtcGxlLmNvbSIsImh0dHBzOi8vYXBpLm9wZW5haS5jb20vcHJvZmlsZSI6" ++
        "eyJlbWFpbCI6Im5lc3RlZEBleGFtcGxlLmNvbSJ9LCJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsi" ++
        "Y2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjdCJ9LCJleHAiOjEyMzQuNzV9.s";
    const email = (try jwtEmail(std.testing.allocator, token)).?;
    defer std.testing.allocator.free(email);
    try std.testing.expectEqualStrings("top@example.com", email);
    try std.testing.expectEqual(@as(?u64, 1234), try jwtExpiration(std.testing.allocator, token));
    const account = (try jwtAccountId(std.testing.allocator, token)).?;
    defer std.testing.allocator.free(account);
    try std.testing.expectEqualStrings("acct", account);

    const nested = "e.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL3Byb2ZpbGUiOnsiZW1haWwiOiJuZXN0ZWRAZXhhbXBsZS5jb20ifX0.s";
    const nested_email = (try jwtEmail(std.testing.allocator, nested)).?;
    defer std.testing.allocator.free(nested_email);
    try std.testing.expectEqualStrings("nested@example.com", nested_email);
    const padded = "e.eyJlbWFpbCI6ImEifQ==.s";
    const padded_email = (try jwtEmail(std.testing.allocator, padded)).?;
    defer std.testing.allocator.free(padded_email);
    try std.testing.expectEqualStrings("a", padded_email);
    try std.testing.expectEqual(@as(?[]u8, null), try jwtEmail(std.testing.allocator, "bad"));
    try std.testing.expectEqual(@as(?u64, null), try jwtExpiration(std.testing.allocator, "e.W10.s"));
    const two_to_64 = "e.eyJleHAiOjEuODQ0Njc0NDA3MzcwOTU1MmUxOX0.s";
    try std.testing.expectEqual(
        @as(?u64, null),
        try jwtExpiration(std.testing.allocator, two_to_64),
    );
}

test "borrowed CLI source reloads changed token only for its pinned account" {
    const initial_json = "{\"tokens\":{\"access_token\":\"one\",\"account_id\":\"account\"}}";
    var loader_state: TestLoader = .{ .value = .{ .bytes = initial_json } };
    const initialized = try BorrowedCliSource.init(std.testing.allocator, std.testing.io, Loader.from(&loader_state));
    var source = switch (initialized) {
        .ready => |ready| ready,
        .failure => return error.TestUnexpectedResult,
    };
    defer source.deinit();

    const unauthorized = try source.recoverUnauthorized(
        std.testing.allocator,
        std.testing.io,
        null,
        source.current.credential(),
    );
    try std.testing.expectEqualStrings(
        "codex CLI token expired — rerun the Codex CLI to authenticate",
        unauthorized.fail.message,
    );

    source.noteUnauthorized(.{ .access_token = "other", .account_id = "account" });
    try std.testing.expect(!source.stale);
    source.noteUnauthorized(source.current.credential());
    try std.testing.expect(source.stale);

    loader_state.value = .{ .bytes = "{\"tokens\":{\"access_token\":\"two\",\"account_id\":\"account\"}}" };
    try source.reloadIfChanged();
    try std.testing.expectEqualStrings("two", source.current.access_token);
    try std.testing.expect(!source.stale);

    source.stale = true;
    loader_state.value = .{ .bytes = "{\"tokens\":{\"access_token\":\"foreign\",\"account_id\":\"other\"}}" };
    try source.reloadIfChanged();
    try std.testing.expectEqualStrings("two", source.current.access_token);
    try std.testing.expect(source.stale);

    loader_state.value = .missing;
    try source.reloadIfChanged();
    try std.testing.expectEqualStrings("two", source.current.access_token);
    try std.testing.expect(source.stale);
}

fn exerciseParseAllocations(allocator: std.mem.Allocator) !void {
    const result = try parse(
        allocator,
        "{\"tokens\":{\"access_token\":\"access\",\"account_id\":\"account\"," ++
            "\"id_token\":\"e.eyJlbWFpbCI6ImVAeC5jb20ifQ.s\"}}",
    );
    switch (result) {
        .loaded => |loaded_value| {
            var loaded = loaded_value;
            loaded.deinit();
        },
        .failure => return error.TestUnexpectedResult,
    }
}

test "credential parsing releases all allocations on OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseParseAllocations, .{});
}

fn exerciseSourceAllocations(allocator: std.mem.Allocator, loader_state: *TestLoader) !void {
    const initialized = try BorrowedCliSource.init(allocator, std.testing.io, Loader.from(loader_state));
    switch (initialized) {
        .ready => |ready| {
            var source = ready;
            source.deinit();
        },
        .failure => return error.TestUnexpectedResult,
    }
}

test "borrowed source initialization releases all allocations on OOM" {
    const auth_json = "{\"tokens\":{\"access_token\":\"access\",\"account_id\":\"account\"}}";
    var loader_state: TestLoader = .{ .value = .{ .bytes = auth_json } };
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseSourceAllocations,
        .{&loader_state},
    );
}

test "managed provider entry schema and bounds" {
    const result = try parseManaged(
        std.testing.allocator,
        "{\"access_token\":\"at\",\"refresh_token\":\"rt\",\"account_id\":\"acc\",\"id_token\":\"id\",\"future\":true}",
    );
    var loaded = switch (result) {
        .loaded => |value| value,
        .failure => return error.TestUnexpectedResult,
    };
    defer loaded.deinit();
    try std.testing.expectEqualStrings("at", loaded.access_token);
    try std.testing.expectEqualStrings("rt", loaded.refresh_token);
    try std.testing.expectEqualStrings("acc", loaded.account_id);
    try std.testing.expectEqualStrings("id", loaded.id_token.?);

    const missing_refresh = try parseManaged(
        std.testing.allocator,
        "{\"access_token\":\"at\",\"account_id\":\"acc\"}",
    );
    try std.testing.expectEqual(Status.no_tokens, missing_refresh.failure);
    const empty_id = try parseManaged(
        std.testing.allocator,
        "{\"access_token\":\"at\",\"refresh_token\":\"rt\",\"account_id\":\"acc\",\"id_token\":\"\"}",
    );
    var without_id = switch (empty_id) {
        .loaded => |value| value,
        .failure => return error.TestUnexpectedResult,
    };
    defer without_id.deinit();
    try std.testing.expectEqual(@as(?[]u8, null), without_id.id_token);
}

test "resolve prefers managed and reports both fallback statuses" {
    var managed_loader: TestLoader = .{ .value = .{
        .bytes = "{\"access_token\":\"managed\",\"refresh_token\":\"rt\",\"account_id\":\"m\"}",
    } };
    var cli_loader: TestLoader = .{ .value = .{
        .bytes = "{\"tokens\":{\"access_token\":\"cli\",\"account_id\":\"c\"}}",
    } };
    var preferred = switch (try resolve(
        std.testing.allocator,
        Loader.from(&managed_loader),
        Loader.from(&cli_loader),
    )) {
        .loaded => |value| value,
        .failure => return error.TestUnexpectedResult,
    };
    defer preferred.deinit();
    try std.testing.expectEqual(Source.managed, preferred.source);
    try std.testing.expectEqual(@as(usize, 0), cli_loader.loads);

    managed_loader.value = .{ .bytes = "{}" };
    var fallback = switch (try resolve(
        std.testing.allocator,
        Loader.from(&managed_loader),
        Loader.from(&cli_loader),
    )) {
        .loaded => |value| value,
        .failure => return error.TestUnexpectedResult,
    };
    defer fallback.deinit();
    try std.testing.expectEqual(Source.codex_cli, fallback.source);
    try std.testing.expectEqual(@as(?[]u8, null), fallback.refresh_token);

    managed_loader.value = .unreadable;
    cli_loader.value = .missing;
    const failed = try resolve(
        std.testing.allocator,
        Loader.from(&managed_loader),
        Loader.from(&cli_loader),
    );
    try std.testing.expectEqual(Status.unreadable, failed.failure.managed);
    try std.testing.expectEqual(Status.missing, failed.failure.codex_cli);
}

fn exerciseManagedAllocations(allocator: std.mem.Allocator) !void {
    const result = try parseManaged(
        allocator,
        "{\"access_token\":\"access\",\"refresh_token\":\"refresh\"," ++
            "\"account_id\":\"account\",\"id_token\":\"e.eyJlbWFpbCI6ImVAeC5jb20ifQ.s\"}",
    );
    switch (result) {
        .loaded => |value| {
            var loaded = value;
            loaded.deinit();
        },
        .failure => return error.TestUnexpectedResult,
    }
}

test "managed parsing releases every allocation on OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseManagedAllocations, .{});
}

const WipeTestAllocator = struct {
    fixed: std.heap.FixedBufferAllocator,

    fn init(buffer: []u8) WipeTestAllocator {
        return .{ .fixed = std.heap.FixedBufferAllocator.init(buffer) };
    }

    fn allocator(self: *WipeTestAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *WipeTestAllocator = @ptrCast(@alignCast(context));
        return self.fixed.allocator().rawAlloc(len, alignment, return_address);
    }

    fn resize(
        _: *anyopaque,
        _: []u8,
        _: std.mem.Alignment,
        _: usize,
        _: usize,
    ) bool {
        return false;
    }

    fn remap(
        _: *anyopaque,
        _: []u8,
        _: std.mem.Alignment,
        _: usize,
        _: usize,
    ) ?[*]u8 {
        return null;
    }

    fn free(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {}

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };
};

test "managed credential deinit wipes owned secret bytes" {
    var storage: [128 * 1024]u8 = undefined;
    var wipe_allocator = WipeTestAllocator.init(&storage);
    const result = try parseManaged(
        wipe_allocator.allocator(),
        "{\"access_token\":\"access-secret\",\"refresh_token\":\"refresh-secret\"," ++
            "\"account_id\":\"account-secret\",\"id_token\":\"id-secret\"}",
    );
    var loaded = switch (result) {
        .loaded => |value| value,
        .failure => return error.TestUnexpectedResult,
    };
    const access = loaded.access_token;
    const refresh = loaded.refresh_token;
    const account = loaded.account_id;
    const id = loaded.id_token.?;
    loaded.deinit();
    for (access) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    for (refresh) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    for (account) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    for (id) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "malformed credential and JWT parser blocks reach backing free as zeros" {
    var observer = SecureAllocator.FreeObserver.init(std.testing.allocator);
    try expectFailure(.bad_json, try parse(observer.allocator(), "{\"tokens\":{\"access_token\":\"secret"));
    const managed = try parseManaged(
        observer.allocator(),
        "{\"access_token\":\"secret\",\"refresh_token\":\"rotation\"",
    );
    try std.testing.expectEqual(Status.bad_json, managed.failure);
    try std.testing.expectEqual(
        @as(?JwtPayload, null),
        try parseJwtPayload(observer.allocator(), "e.eyJlbWFpbCI6InNlY3JldCI=.s"),
    );
    try std.testing.expect(observer.zero_frees >= 2);
}

const BorrowedCliThread = struct {
    source: *BorrowedCliSource,
    failed: std.atomic.Value(bool) = .init(false),

    fn run(self: *BorrowedCliThread) void {
        for (0..32) |_| {
            var decision = self.source.credentialSource().acquire(
                std.testing.allocator,
                std.testing.io,
                null,
                .request,
            ) catch {
                self.failed.store(true, .release);
                return;
            };
            const credential = decision.ready.credential();
            if (!std.mem.eql(u8, credential.account_id, "account")) {
                self.failed.store(true, .release);
            }
            self.source.credentialSource().noteUnauthorized(credential);
            decision.deinit();
        }
    }
};

test "borrowed CLI callbacks serialize and return independently owned credentials" {
    var loader: TestLoader = .{ .value = .{ .bytes = "{\"tokens\":{\"access_token\":\"token\"," ++
        "\"account_id\":\"account\"}}" } };
    const initialized = try BorrowedCliSource.init(
        std.testing.allocator,
        std.testing.io,
        Loader.from(&loader),
    );
    var source = switch (initialized) {
        .ready => |value| value,
        .failure => return error.TestUnexpectedResult,
    };
    defer source.deinit();
    var first: BorrowedCliThread = .{ .source = &source };
    var second: BorrowedCliThread = .{ .source = &source };
    const a = try std.Thread.spawn(.{}, BorrowedCliThread.run, .{&first});
    const b = try std.Thread.spawn(.{}, BorrowedCliThread.run, .{&second});
    a.join();
    b.join();
    try std.testing.expect(!first.failed.load(.acquire));
    try std.testing.expect(!second.failed.load(.acquire));
    try std.testing.expect(loader.loads >= 2);
}
