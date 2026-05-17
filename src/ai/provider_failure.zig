const std = @import("std");
const protocol = @import("protocol.zig");

pub const NormalizedHttpFailure = struct {
    failure: protocol.NormalizedFailure,
    display_message: []const u8,
};

pub fn normalizeHttpFailure(
    allocator: std.mem.Allocator,
    status: std.http.Status,
    body: []const u8,
) !NormalizedHttpFailure {
    const status_code: u16 = @intCast(@intFromEnum(status));
    const trimmed = std.mem.trim(u8, body, &std.ascii.whitespace);
    var parsed_detail = try parseHttpErrorDetail(allocator, trimmed);
    errdefer parsed_detail.deinit(allocator);

    const failure_kind = classifyHttpFailure(status_code, parsed_detail.provider_type, parsed_detail.provider_code, parsed_detail.provider_message);
    const display_message = try formatHttpErrorDetail(allocator, status_code, parsed_detail.provider_message orelse trimmed, trimmed.len == 0);

    const result: NormalizedHttpFailure = .{
        .failure = .{
            .kind = failure_kind,
            .http_status = status_code,
            .provider_code = parsed_detail.provider_code,
            .provider_type = parsed_detail.provider_type,
        },
        .display_message = display_message,
    };
    parsed_detail.provider_code = null;
    parsed_detail.provider_type = null;
    parsed_detail.deinit(allocator);
    return result;
}

pub fn formatTransportFailure(
    allocator: std.mem.Allocator,
    message: []const u8,
) !NormalizedHttpFailure {
    return .{
        .failure = .{ .kind = classifyTransportFailure(message) },
        .display_message = try allocator.dupe(u8, message),
    };
}

const ParsedHttpError = struct {
    provider_message: ?[]const u8 = null,
    provider_code: ?[]const u8 = null,
    provider_type: ?[]const u8 = null,

    fn deinit(self: *ParsedHttpError, allocator: std.mem.Allocator) void {
        if (self.provider_message) |message| allocator.free(message);
        if (self.provider_code) |code| allocator.free(code);
        if (self.provider_type) |provider_type| allocator.free(provider_type);
    }
};

fn parseHttpErrorDetail(
    allocator: std.mem.Allocator,
    trimmed: []const u8,
) !ParsedHttpError {
    if (trimmed.len == 0) return .{};
    if (std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{})) |parsed| {
        defer parsed.deinit();
        return try cloneParsedHttpError(allocator, extractJsonError(parsed.value));
    } else |_| {
        return .{ .provider_message = try allocator.dupe(u8, trimmed) };
    }
}

fn extractJsonError(value: std.json.Value) ParsedHttpError {
    if (value != .object) return .{};
    if (value.object.get("error")) |err| {
        switch (err) {
            .string => |s| return .{ .provider_message = s },
            .object => {
                return .{
                    .provider_message = if (err.object.get("message")) |msg| if (msg == .string and msg.string.len > 0) msg.string else null else null,
                    .provider_code = if (err.object.get("code")) |code| if (code == .string and code.string.len > 0) code.string else null else null,
                    .provider_type = if (err.object.get("type")) |t| if (t == .string and t.string.len > 0) t.string else null else null,
                };
            },
            else => {},
        }
    }
    return .{
        .provider_message = if (value.object.get("message")) |msg| if (msg == .string and msg.string.len > 0) msg.string else null else null,
        .provider_code = if (value.object.get("code")) |code| if (code == .string and code.string.len > 0) code.string else null else null,
        .provider_type = if (value.object.get("type")) |t| if (t == .string and t.string.len > 0) t.string else null else null,
    };
}

fn cloneParsedHttpError(allocator: std.mem.Allocator, parsed: ParsedHttpError) !ParsedHttpError {
    return .{
        .provider_message = if (parsed.provider_message) |message| try allocator.dupe(u8, message) else null,
        .provider_code = if (parsed.provider_code) |code| try allocator.dupe(u8, code) else null,
        .provider_type = if (parsed.provider_type) |provider_type| try allocator.dupe(u8, provider_type) else null,
    };
}

fn classifyHttpFailure(
    status_code: u16,
    provider_type: ?[]const u8,
    provider_code: ?[]const u8,
    provider_message: ?[]const u8,
) protocol.NormalizedFailure.Kind {
    const provider_kind = classifyProviderFailure(provider_type, provider_code, provider_message);
    if (status_code == 401 or status_code == 403) return .auth;
    if (status_code == 408 or status_code == 409 or status_code == 429) return .rate_limited;
    if (status_code == 500 or status_code == 502 or status_code == 503 or status_code == 504) return .transient;
    if (status_code == 413) return .context_overflow;
    if (status_code == 400) {
        return switch (provider_kind) {
            .context_overflow => .context_overflow,
            .auth => .auth,
            .rate_limited => .rate_limited,
            .transient => .transient,
            .invalid_request, .fatal, .aborted => .invalid_request,
        };
    }
    return if (provider_kind != .fatal) provider_kind else .fatal;
}

pub fn classifyProviderFailure(
    provider_type: ?[]const u8,
    provider_code: ?[]const u8,
    provider_message: ?[]const u8,
) protocol.NormalizedFailure.Kind {
    if (provider_type) |provider_type_value| {
        if (isNonOverflowNeedle(provider_type_value)) return .rate_limited;
    }
    if (provider_code) |code| {
        if (isNonOverflowNeedle(code)) return .rate_limited;
    }
    if (provider_message) |msg| {
        if (isNonOverflowNeedle(msg)) return .rate_limited;
    }
    if (provider_code) |code| {
        if (isOverflowNeedle(code)) return .context_overflow;
    }
    if (provider_message) |msg| {
        if (isOverflowNeedle(msg)) return .context_overflow;
    }
    if (provider_type) |provider_type_value| {
        if (containsAnyCI(provider_type_value, &.{ "authentication_error", "permission_error", "auth_error" })) {
            return .auth;
        }
        if (containsAnyCI(provider_type_value, &.{ "rate_limit_error", "throttling_error" })) {
            return .rate_limited;
        }
        if (containsAnyCI(provider_type_value, &.{ "overloaded_error", "api_error", "server_error" })) {
            return .transient;
        }
        if (containsAnyCI(provider_type_value, &.{ "invalid_request_error", "bad_request_error" })) {
            return .invalid_request;
        }
    }
    if (provider_message) |msg| {
        if (containsAnyCI(msg, &.{ "rate limit", "too many requests", "throttl" })) return .rate_limited;
        if (containsAnyCI(msg, &.{ "overloaded", "temporar", "try again", "service unavailable", "internal error" })) return .transient;
        if (containsAnyCI(msg, &.{ "unauthorized", "forbidden", "invalid api key", "api key" })) return .auth;
    }
    return .fatal;
}

pub fn classifyTransportFailure(message: []const u8) protocol.NormalizedFailure.Kind {
    if (containsAnyCI(message, &.{ "no api key", "accountid", "account id", "api key too long", "invalid api key", "unauthorized", "forbidden" })) {
        return .auth;
    }
    if (containsAnyCI(message, &.{ "timeout", "timed out", "connection", "network", "refused", "reset", "closed", "unavailable", "failed to open connection", "request failed", "failed to send body", "stream read error" })) {
        return .transient;
    }
    return .fatal;
}

fn formatHttpErrorDetail(
    allocator: std.mem.Allocator,
    status_code: u16,
    maybe_message: []const u8,
    empty_body: bool,
) ![]const u8 {
    const reason = httpStatusReason(status_code) orelse "";
    if (empty_body) {
        if (reason.len > 0) return std.fmt.allocPrint(allocator, "HTTP {d} {s} (empty body)", .{ status_code, reason });
        return std.fmt.allocPrint(allocator, "HTTP {d} (empty body)", .{status_code});
    }
    if (reason.len > 0) return std.fmt.allocPrint(allocator, "HTTP {d} {s}: {s}", .{ status_code, reason, maybe_message });
    return std.fmt.allocPrint(allocator, "HTTP {d}: {s}", .{ status_code, maybe_message });
}

fn httpStatusReason(status_code: u16) ?[]const u8 {
    return switch (status_code) {
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        408 => "Request Timeout",
        409 => "Conflict",
        413 => "Payload Too Large",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        else => null,
    };
}

fn isNonOverflowNeedle(text: []const u8) bool {
    return containsAnyCI(text, &.{
        "throttling error",
        "rate limit",
        "too many requests",
    });
}

fn isOverflowNeedle(text: []const u8) bool {
    return containsAnyCI(text, &.{
        "prompt is too long",
        "input is too long for requested model",
        "exceeds the context window",
        "maximum context length is",
        "context length exceeded",
        "context_length_exceeded",
        "model_context_window_exceeded",
        "token limit exceeded",
        "too many tokens",
    });
}

fn containsAnyCI(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (containsCI(haystack, needle)) return true;
    }
    return false;
}

fn containsCI(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

const testing = std.testing;
const FailureKind = protocol.NormalizedFailure.Kind;

fn expectNormalizedHttpFailure(
    status: std.http.Status,
    body: []const u8,
    expected_kind: FailureKind,
    expected_message: []const u8,
    expected_code: ?[]const u8,
    expected_type: ?[]const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const result = try normalizeHttpFailure(arena.allocator(), status, body);
    try testing.expectEqual(expected_kind, result.failure.kind);
    try testing.expectEqual(@as(?u16, @intCast(@intFromEnum(status))), result.failure.http_status);
    try testing.expectEqualStrings(expected_message, result.display_message);

    if (expected_code) |code| {
        try testing.expectEqualStrings(code, result.failure.provider_code.?);
    } else {
        try testing.expectEqual(@as(?[]const u8, null), result.failure.provider_code);
    }

    if (expected_type) |provider_type| {
        try testing.expectEqualStrings(provider_type, result.failure.provider_type.?);
    } else {
        try testing.expectEqual(@as(?[]const u8, null), result.failure.provider_type);
    }
}

fn expectHttpKind(
    expected: FailureKind,
    status_code: u16,
    provider_type: ?[]const u8,
    provider_code: ?[]const u8,
    provider_message: ?[]const u8,
) !void {
    try testing.expectEqual(expected, classifyHttpFailure(status_code, provider_type, provider_code, provider_message));
}

fn expectProviderKind(
    expected: FailureKind,
    provider_type: ?[]const u8,
    provider_code: ?[]const u8,
    provider_message: ?[]const u8,
) !void {
    try testing.expectEqual(expected, classifyProviderFailure(provider_type, provider_code, provider_message));
}

fn expectTransportKind(expected: FailureKind, message: []const u8) !void {
    try testing.expectEqual(expected, classifyTransportFailure(message));
}

test "normalizeHttpFailure preserves provider metadata and formats nested JSON error" {
    try expectNormalizedHttpFailure(
        .bad_request,
        "{\"error\":{\"message\":\"context length exceeded\",\"code\":\"context_length_exceeded\",\"type\":\"invalid_request_error\"}}",
        .context_overflow,
        "HTTP 400 Bad Request: context length exceeded",
        "context_length_exceeded",
        "invalid_request_error",
    );
}

test "normalizeHttpFailure formats empty, raw, and top-level provider bodies" {
    try expectNormalizedHttpFailure(
        .bad_request,
        "  \n ",
        .invalid_request,
        "HTTP 400 Bad Request (empty body)",
        null,
        null,
    );

    try expectNormalizedHttpFailure(
        .internal_server_error,
        "upstream exploded",
        .transient,
        "HTTP 500 Internal Server Error: upstream exploded",
        null,
        null,
    );

    try expectNormalizedHttpFailure(
        .too_many_requests,
        "{\"message\":\"Too many requests\",\"code\":\"rate_limit\",\"type\":\"rate_limit_error\"}",
        .rate_limited,
        "HTTP 429 Too Many Requests: Too many requests",
        "rate_limit",
        "rate_limit_error",
    );
}

test "classifyHttpFailure lets HTTP status override misleading provider text" {
    try expectHttpKind(.auth, 401, null, null, "rate limit exceeded");
    try expectHttpKind(.rate_limited, 429, null, null, null);
    try expectHttpKind(.transient, 503, null, null, null);
    try expectHttpKind(.context_overflow, 413, null, null, null);
}

test "classifyHttpFailure refines bad requests with provider context" {
    try expectHttpKind(.invalid_request, 400, null, null, "unknown bad request");
    try expectHttpKind(.context_overflow, 400, null, "context_length_exceeded", null);
    try expectHttpKind(.auth, 400, "authentication_error", null, null);
    try expectHttpKind(.rate_limited, 400, null, null, "too many requests");
    try expectHttpKind(.transient, 400, "overloaded_error", null, null);
}

test "classifyProviderFailure maps provider type categories" {
    try expectProviderKind(.auth, "authentication_error", null, "bad key");
    try expectProviderKind(.auth, "permission_error", null, null);
    try expectProviderKind(.rate_limited, "rate_limit_error", null, null);
    try expectProviderKind(.transient, "overloaded_error", null, "try again");
    try expectProviderKind(.invalid_request, "invalid_request_error", null, "schema mismatch");
}

test "classifyProviderFailure detects rate limits before overflow wording" {
    try expectProviderKind(
        .rate_limited,
        "throttling_error",
        null,
        "Throttling error: Too many tokens, please wait before trying again.",
    );
    try expectProviderKind(.rate_limited, null, "rate limit exceeded", null);
}

test "classifyProviderFailure detects context overflow from code or message" {
    try expectProviderKind(.context_overflow, null, "context_length_exceeded", null);
    try expectProviderKind(.context_overflow, null, "model_context_window_exceeded", null);
    try expectProviderKind(.context_overflow, null, null, "maximum context length is 128000 tokens");
    try expectProviderKind(.context_overflow, null, null, "input is too long for requested model");
}

test "classifyProviderFailure maps message-only retry and auth signals" {
    try expectProviderKind(.rate_limited, null, null, "too many requests");
    try expectProviderKind(.transient, null, null, "service unavailable, try again");
    try expectProviderKind(.auth, null, null, "invalid api key");
    try expectProviderKind(.fatal, null, null, "invalid response shape");
}

test "classifyTransportFailure separates auth, retryable transport, and fatal" {
    try expectTransportKind(.auth, "invalid api key");
    try expectTransportKind(.auth, "missing AccountID");
    try expectTransportKind(.transient, "connection reset by peer");
    try expectTransportKind(.transient, "stream read error: timed out");
    try expectTransportKind(.fatal, "invalid response shape");
}
