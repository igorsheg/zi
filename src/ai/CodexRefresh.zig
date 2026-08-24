const std = @import("std");
const CodexCredentials = @import("CodexCredentials.zig");
const SecureAllocator = @import("SecureAllocator.zig");

pub const oauth_client_id = "app_EMoamEEZ73f0CkXaXp7hrann";
pub const token_endpoint = "https://auth.openai.com/oauth/token";
pub const content_type = "application/json";
pub const request_timeout_seconds: u32 = 30;
pub const refresh_margin_seconds: u64 = 600;
pub const maximum_response_bytes: usize = CodexCredentials.maximum_file_bytes;

pub const Request = struct {
    allocator: std.mem.Allocator,
    endpoint: []const u8 = token_endpoint,
    content_type: []const u8 = content_type,
    timeout_seconds: u32 = request_timeout_seconds,
    body: []u8,

    pub fn deinit(self: *Request) void {
        freeSecret(self.allocator, self.body);
        self.* = undefined;
    }
};

/// Describe the refresh POST. This function does not dispatch it.
pub fn request(
    allocator: std.mem.Allocator,
    refresh_token: []const u8,
) error{ OutOfMemory, InvalidRefreshToken }!Request {
    if (refresh_token.len == 0 or
        refresh_token.len > CodexCredentials.maximum_refresh_token_bytes)
    {
        return error.InvalidRefreshToken;
    }
    const Body = struct {
        client_id: []const u8,
        grant_type: []const u8,
        refresh_token: []const u8,
    };
    const body_value: Body = .{
        .client_id = oauth_client_id,
        .grant_type = "refresh_token",
        .refresh_token = refresh_token,
    };
    var wiping = SecureAllocator.WipingAllocator.init(allocator);
    var arena = std.heap.ArenaAllocator.init(wiping.allocator());
    defer arena.deinit();
    const temporary_body = try std.json.Stringify.valueAlloc(arena.allocator(), body_value, .{});
    if (temporary_body.len > maximum_response_bytes) return error.InvalidRefreshToken;
    const body = try allocator.dupe(u8, temporary_body);
    return .{ .allocator = allocator, .body = body };
}

/// Unknown or malformed expiries are opaque and are left to unauthorized recovery.
pub fn tokenExpiring(
    allocator: std.mem.Allocator,
    access_token: []const u8,
    now_seconds: u64,
) error{OutOfMemory}!bool {
    const expiration = (try CodexCredentials.jwtExpiration(allocator, access_token)) orelse return false;
    const boundary = std.math.add(u64, now_seconds, refresh_margin_seconds) catch std.math.maxInt(u64);
    return expiration <= boundary;
}

/// Tokens with opaque expiries remain adoptable. Otherwise, expiry decides freshness.
pub fn tokenAsFresh(
    allocator: std.mem.Allocator,
    candidate: []const u8,
    current: []const u8,
) error{OutOfMemory}!bool {
    const candidate_exp = (try CodexCredentials.jwtExpiration(allocator, candidate)) orelse return true;
    const current_exp = (try CodexCredentials.jwtExpiration(allocator, current)) orelse return true;
    return candidate_exp >= current_exp;
}

pub const MergeFailure = enum { not_success, too_large, bad_json, unusable };

pub const MergeResult = union(enum) {
    merged: CodexCredentials.ManagedLoaded,
    failure: MergeFailure,
};

/// Parse and merge a successful token response. Account identity never changes during refresh.
pub fn mergeResponse(
    allocator: std.mem.Allocator,
    current: *const CodexCredentials.ManagedLoaded,
    http_status: u16,
    body: []const u8,
) error{OutOfMemory}!MergeResult {
    if (http_status < 200 or http_status >= 300) return .{ .failure = .not_success };
    if (body.len > maximum_response_bytes) return .{ .failure = .too_large };
    var wiping = SecureAllocator.WipingAllocator.init(allocator);
    var arena = std.heap.ArenaAllocator.init(wiping.allocator());
    defer arena.deinit();
    const temporary = arena.allocator();
    if (!(try validateJsonBounds(temporary, body))) return .{ .failure = .bad_json };

    var parsed = std.json.parseFromSlice(std.json.Value, temporary, body, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .use_last,
        .max_value_len = CodexCredentials.maximum_string_bytes,
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
        else => return .{ .failure = .unusable },
    };
    const access = boundedString(root, "access_token", CodexCredentials.maximum_access_token_bytes) orelse
        return .{ .failure = .unusable };
    const refresh = optionalBoundedString(
        root,
        "refresh_token",
        CodexCredentials.maximum_refresh_token_bytes,
    ) orelse current.refresh_token;
    const id = optionalBoundedString(root, "id_token", CodexCredentials.maximum_id_token_bytes);
    const selected_id = id orelse current.id_token;

    const owned_access = try allocator.dupe(u8, access);
    errdefer freeSecret(allocator, owned_access);
    const owned_refresh = try allocator.dupe(u8, refresh);
    errdefer freeSecret(allocator, owned_refresh);
    const owned_account = try allocator.dupe(u8, current.account_id);
    errdefer freeSecret(allocator, owned_account);
    const owned_id = if (selected_id) |value| try allocator.dupe(u8, value) else null;
    errdefer if (owned_id) |value| freeSecret(allocator, value);
    const email = if (selected_id) |value| try CodexCredentials.jwtEmail(allocator, value) else null;
    errdefer if (email) |value| freeSecret(allocator, value);

    return .{ .merged = .{
        .allocator = allocator,
        .access_token = owned_access,
        .refresh_token = owned_refresh,
        .account_id = owned_account,
        .id_token = owned_id,
        .email = email,
    } };
}

/// Only an exact terminal OAuth code on a 4xx response rejects the credential.
pub fn refreshRejected(
    allocator: std.mem.Allocator,
    http_status: u16,
    body: []const u8,
) error{OutOfMemory}!bool {
    if (http_status < 400 or http_status >= 500 or body.len > maximum_response_bytes) return false;
    var wiping = SecureAllocator.WipingAllocator.init(allocator);
    var arena = std.heap.ArenaAllocator.init(wiping.allocator());
    defer arena.deinit();
    const temporary = arena.allocator();
    if (!(try validateJsonBounds(temporary, body))) return false;
    var parsed = std.json.parseFromSlice(std.json.Value, temporary, body, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .use_last,
        .max_value_len = CodexCredentials.maximum_string_bytes,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer {
        scrubJson(&parsed.value);
        parsed.deinit();
    }
    const root = switch (parsed.value) {
        .object => |*object| object,
        else => return false,
    };
    const code = oauthErrorCode(root) orelse return false;
    return std.mem.eql(u8, code, "invalid_grant") or
        std.mem.eql(u8, code, "refresh_token_expired") or
        std.mem.eql(u8, code, "refresh_token_reused") or
        std.mem.eql(u8, code, "refresh_token_invalidated");
}

fn oauthErrorCode(root: *const std.json.ObjectMap) ?[]const u8 {
    if (root.get("error")) |error_value| switch (error_value) {
        .object => |*object| if (boundedString(object, "code", CodexCredentials.maximum_string_bytes)) |code| {
            return code;
        },
        .string => |code| if (code.len > 0 and code.len <= CodexCredentials.maximum_string_bytes) {
            return code;
        },
        else => {},
    };
    return boundedString(root, "code", CodexCredentials.maximum_string_bytes);
}

fn boundedString(object: *const std.json.ObjectMap, key: []const u8, maximum: usize) ?[]const u8 {
    const value = object.get(key) orelse return null;
    const text = switch (value) {
        .string => |text| text,
        else => return null,
    };
    return if (text.len > 0 and text.len <= maximum) text else null;
}

fn optionalBoundedString(
    object: *const std.json.ObjectMap,
    key: []const u8,
    maximum: usize,
) ?[]const u8 {
    return boundedString(object, key, maximum);
}

fn validateJsonBounds(allocator: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}!bool {
    var scanner = std.json.Scanner.initCompleteInput(allocator, bytes);
    defer scanner.deinit();
    var depth: usize = 0;
    var count: usize = 0;
    while (true) {
        const token_type = scanner.peekNextTokenType() catch return false;
        const limit = if (token_type == .string) CodexCredentials.maximum_string_bytes else bytes.len;
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
        count += 1;
        if (count > CodexCredentials.maximum_tokens) return false;
        switch (token) {
            .object_begin, .array_begin => {
                depth += 1;
                if (depth > CodexCredentials.maximum_depth) return false;
            },
            .object_end, .array_end => {
                if (depth == 0) return false;
                depth -= 1;
            },
            else => {},
        }
    }
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

test "refresh request has exact protocol descriptor and escaped body" {
    var descriptor = try request(std.testing.allocator, "r\\\"t");
    defer descriptor.deinit();
    try std.testing.expectEqualStrings(token_endpoint, descriptor.endpoint);
    try std.testing.expectEqualStrings(content_type, descriptor.content_type);
    try std.testing.expectEqual(@as(u32, 30), descriptor.timeout_seconds);
    try std.testing.expectEqualStrings(
        "{\"client_id\":\"app_EMoamEEZ73f0CkXaXp7hrann\",\"grant_type\":\"refresh_token\"," ++
            "\"refresh_token\":\"r\\\\\\\"t\"}",
        descriptor.body,
    );
}

test "expiry boundary and opaque freshness policy" {
    const at_boundary = "e.eyJleHAiOjE2MDB9.s";
    const after_boundary = "e.eyJleHAiOjE2MDF9.s";
    try std.testing.expect(try tokenExpiring(std.testing.allocator, at_boundary, 1000));
    try std.testing.expect(!try tokenExpiring(std.testing.allocator, after_boundary, 1000));
    try std.testing.expect(!try tokenExpiring(std.testing.allocator, "opaque", 1000));
    try std.testing.expect(try tokenAsFresh(std.testing.allocator, after_boundary, at_boundary));
    try std.testing.expect(!try tokenAsFresh(std.testing.allocator, at_boundary, after_boundary));
    try std.testing.expect(try tokenAsFresh(std.testing.allocator, "opaque", after_boundary));
}

test "2xx response merge preserves omitted rotation fields and account" {
    const parsed = try CodexCredentials.parseManaged(
        std.testing.allocator,
        "{\"access_token\":\"old\",\"refresh_token\":\"old-r\",\"id_token\":\"old-id\",\"account_id\":\"acc\"}",
    );
    var current = switch (parsed) {
        .loaded => |loaded| loaded,
        .failure => return error.TestUnexpectedResult,
    };
    defer current.deinit();
    const result = try mergeResponse(
        std.testing.allocator,
        &current,
        200,
        "{\"access_token\":\"new\",\"account_id\":\"foreign\"}",
    );
    var merged = switch (result) {
        .merged => |loaded| loaded,
        .failure => return error.TestUnexpectedResult,
    };
    defer merged.deinit();
    try std.testing.expectEqualStrings("new", merged.access_token);
    try std.testing.expectEqualStrings("old-r", merged.refresh_token);
    try std.testing.expectEqualStrings("old-id", merged.id_token.?);
    try std.testing.expectEqualStrings("acc", merged.account_id);

    try std.testing.expectEqual(
        MergeFailure.unusable,
        (try mergeResponse(std.testing.allocator, &current, 204, "{}")).failure,
    );
    try std.testing.expectEqual(
        MergeFailure.not_success,
        (try mergeResponse(std.testing.allocator, &current, 500, "{}")).failure,
    );
}

test "terminal refresh codes require an exact code on 4xx" {
    try std.testing.expect(try refreshRejected(std.testing.allocator, 400, "{\"error\":\"invalid_grant\"}"));
    try std.testing.expect(try refreshRejected(
        std.testing.allocator,
        401,
        "{\"error\":{\"code\":\"refresh_token_reused\"}}",
    ));
    try std.testing.expect(try refreshRejected(
        std.testing.allocator,
        403,
        "{\"code\":\"refresh_token_invalidated\"}",
    ));
    try std.testing.expect(!try refreshRejected(std.testing.allocator, 500, "{\"error\":\"invalid_grant\"}"));
    try std.testing.expect(!try refreshRejected(std.testing.allocator, 403, "<html>denied</html>"));
    try std.testing.expect(!try refreshRejected(std.testing.allocator, 400, "{\"error\":\"invalid_grant_extra\"}"));
}

fn exerciseRefreshAllocations(allocator: std.mem.Allocator) !void {
    var descriptor = try request(allocator, "refresh-secret");
    descriptor.deinit();

    const parsed = try CodexCredentials.parseManaged(
        allocator,
        "{\"access_token\":\"old\",\"refresh_token\":\"old-r\",\"account_id\":\"acc\"}",
    );
    var current = switch (parsed) {
        .loaded => |loaded| loaded,
        .failure => return error.TestUnexpectedResult,
    };
    defer current.deinit();
    const result = try mergeResponse(
        allocator,
        &current,
        200,
        "{\"access_token\":\"new\",\"refresh_token\":\"new-r\"}",
    );
    switch (result) {
        .merged => |loaded| {
            var merged = loaded;
            merged.deinit();
        },
        .failure => return error.TestUnexpectedResult,
    }
}

test "refresh protocol releases every owned allocation on OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseRefreshAllocations, .{});
}

test "refresh parser rejects malformed and oversized responses" {
    const parsed = try CodexCredentials.parseManaged(
        std.testing.allocator,
        "{\"access_token\":\"old\",\"refresh_token\":\"old-r\",\"account_id\":\"acc\"}",
    );
    var current = switch (parsed) {
        .loaded => |loaded| loaded,
        .failure => return error.TestUnexpectedResult,
    };
    defer current.deinit();
    try std.testing.expectEqual(
        MergeFailure.bad_json,
        (try mergeResponse(std.testing.allocator, &current, 200, "{")).failure,
    );
    const oversized = "x" ** (maximum_response_bytes + 1);
    try std.testing.expectEqual(
        MergeFailure.too_large,
        (try mergeResponse(std.testing.allocator, &current, 200, oversized)).failure,
    );
}

test "refresh temporary blocks and returned body are wiped at backing free" {
    var observer = SecureAllocator.FreeObserver.init(std.testing.allocator);
    var descriptor = try request(observer.allocator(), "refresh-secret");
    descriptor.deinit();
    try std.testing.expect(!try refreshRejected(
        observer.allocator(),
        400,
        "{\"error\":\"refresh-secret",
    ));
    try std.testing.expect(observer.zero_frees >= 2);
}
