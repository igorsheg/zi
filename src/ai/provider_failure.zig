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
    if (value.object.get("message")) |msg| {
        if (msg == .string and msg.string.len > 0) return .{ .provider_message = msg.string };
    }
    return .{};
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

test "normalizeHttpFailure extracts openai error metadata" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try normalizeHttpFailure(allocator, .bad_request, "{\"error\":{\"message\":\"context length exceeded\",\"code\":\"context_length_exceeded\",\"type\":\"invalid_request_error\"}}");
    try testing.expectEqual(protocol.NormalizedFailure.Kind.context_overflow, result.failure.kind);
    try testing.expectEqual(@as(?u16, 400), result.failure.http_status);
    try testing.expectEqualStrings("context_length_exceeded", result.failure.provider_code.?);
    try testing.expectEqualStrings("HTTP 400 Bad Request: context length exceeded", result.display_message);
}

test "normalizeHttpFailure labels empty bodies" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try normalizeHttpFailure(allocator, .bad_request, "  \n ");
    try testing.expectEqual(protocol.NormalizedFailure.Kind.invalid_request, result.failure.kind);
    try testing.expectEqualStrings("HTTP 400 Bad Request (empty body)", result.display_message);
}

test "normalizeHttpFailure extracts anthropic rate limit metadata" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try normalizeHttpFailure(allocator, .too_many_requests, "{\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"rate limit exceeded\"}}");
    try testing.expectEqual(protocol.NormalizedFailure.Kind.rate_limited, result.failure.kind);
    try testing.expectEqualStrings("rate_limit_error", result.failure.provider_type.?);
    try testing.expectEqualStrings("HTTP 429 Too Many Requests: rate limit exceeded", result.display_message);
}

test "classifyProviderFailure maps anthropic sse error types" {
    try testing.expectEqual(protocol.NormalizedFailure.Kind.auth, classifyProviderFailure("authentication_error", null, "bad key"));
    try testing.expectEqual(protocol.NormalizedFailure.Kind.rate_limited, classifyProviderFailure("rate_limit_error", null, "please slow down"));
    try testing.expectEqual(protocol.NormalizedFailure.Kind.invalid_request, classifyProviderFailure("invalid_request_error", null, "schema mismatch"));
}
