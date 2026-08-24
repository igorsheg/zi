const std = @import("std");
const Utf8 = @import("../text/Utf8.zig");

pub const maximum_body_bytes: usize = 1024 * 1024;
pub const maximum_message_bytes: usize = 200;

pub const Error = error{
    OutOfMemory,
    BodyTooLarge,
};

/// Formats a bounded provider or transport error. The returned bytes are owned.
pub fn formatApiError(
    allocator: std.mem.Allocator,
    status: u16,
    body: ?[]const u8,
) Error![]u8 {
    const source = body orelse return formatStatus(allocator, status, "");
    if (source.len > maximum_body_bytes) return error.BodyTooLarge;
    if (source.len == 0) return formatStatus(allocator, status, "");

    const sse_data = try unwrapSseData(allocator, source);
    defer if (sse_data) |data| allocator.free(data);
    const content = sse_data orelse source;

    if (try extractJsonMessage(allocator, content)) |message| {
        defer allocator.free(message);
        if (message.len != 0) return formatNormalized(allocator, status, message);
    }

    return formatNormalized(allocator, status, content);
}

/// Formats a bounded user-facing diagnostic without adding an HTTP prefix.
/// Callers must not include credentials or other secret material.
pub fn formatMessage(allocator: std.mem.Allocator, source: []const u8) Error![]u8 {
    if (source.len > maximum_body_bytes) return error.BodyTooLarge;
    return formatNormalized(allocator, 0, source);
}

fn formatNormalized(
    allocator: std.mem.Allocator,
    status: u16,
    source: []const u8,
) error{OutOfMemory}![]u8 {
    const flattened = try stripHtmlAndFlatten(allocator, source);
    defer allocator.free(flattened);
    const valid = Utf8.sanitize(allocator, flattened, maximum_body_bytes * 3) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ResultTooLarge => unreachable,
    };
    defer allocator.free(valid);
    const controlled = try stripUnicodeControls(allocator, valid);
    defer allocator.free(controlled);
    return formatStatus(allocator, status, std.mem.trim(u8, controlled, " \t\r\n"));
}

fn stripUnicodeControls(allocator: std.mem.Allocator, source: []const u8) error{OutOfMemory}![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    try result.ensureTotalCapacity(allocator, source.len);
    var iterator = std.unicode.Utf8View.initUnchecked(source).iterator();
    while (true) {
        const start = iterator.i;
        const scalar = iterator.nextCodepoint() orelse break;
        if (scalar < 0x20 or (scalar >= 0x7f and scalar <= 0x9f)) {
            if (result.items.len == 0 or result.items[result.items.len - 1] != ' ') {
                result.appendAssumeCapacity(' ');
            }
        } else {
            result.appendSliceAssumeCapacity(source[start..iterator.i]);
        }
    }
    return result.toOwnedSlice(allocator);
}

/// Short alias used by transport adapters.
pub const format = formatApiError;

/// Formats failures from a provider's `/models` endpoint. The result is owned.
pub fn formatModelListError(
    allocator: std.mem.Allocator,
    name: ?[]const u8,
    base_url: []const u8,
    has_key: bool,
    status: u16,
) error{OutOfMemory}![]u8 {
    const provider = name orelse "provider";
    if (status == 401 or status == 403) {
        if (has_key) return std.fmt.allocPrint(
            allocator,
            "{s} rejected the API key (HTTP {d}): check it and retry",
            .{ provider, status },
        );
        return std.fmt.allocPrint(
            allocator,
            "{s} requires an API key (HTTP {d}): none is configured",
            .{ provider, status },
        );
    }
    if (status >= 200 and status < 300) return std.fmt.allocPrint(
        allocator,
        "{s} sent an empty or truncated /models response",
        .{provider},
    );
    if (status != 0) return std.fmt.allocPrint(
        allocator,
        "listing {s} models failed (HTTP {d})",
        .{ provider, status },
    );
    return std.fmt.allocPrint(allocator, "could not reach {s} at {s}", .{ provider, base_url });
}

fn extractJsonMessage(allocator: std.mem.Allocator, content: []const u8) error{OutOfMemory}!?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const object = parsed.value.object;
    if (object.get("error")) |error_value| switch (error_value) {
        .object => |error_object| if (error_object.get("message")) |message| {
            if (message == .string) return @as(?[]u8, try allocator.dupe(u8, message.string));
        },
        .string => |message| return @as(?[]u8, try allocator.dupe(u8, message)),
        else => {},
    };
    const message = object.get("message") orelse return null;
    if (message != .string) return null;
    return @as(?[]u8, try allocator.dupe(u8, message.string));
}

const SseCapture = struct {
    fallback: ?[]u8 = null,
    found_error: ?[]u8 = null,

    fn deinit(self: *SseCapture, allocator: std.mem.Allocator) void {
        if (self.fallback) |value| allocator.free(value);
        if (self.found_error) |value| allocator.free(value);
        self.* = undefined;
    }

    fn capture(
        self: *SseCapture,
        allocator: std.mem.Allocator,
        event_name: []const u8,
        data: []const u8,
    ) error{OutOfMemory}!bool {
        if (data.len == 0) return false;
        var is_error = std.mem.eql(u8, event_name, "error");
        if (!is_error) {
            const message = try extractJsonMessage(allocator, data);
            if (message) |owned| {
                is_error = true;
                allocator.free(owned);
            }
        }
        if (is_error) {
            self.found_error = try allocator.dupe(u8, data);
            return true;
        }
        if (self.fallback == null) self.fallback = try allocator.dupe(u8, data);
        return false;
    }
};

fn unwrapSseData(allocator: std.mem.Allocator, body: []const u8) error{OutOfMemory}!?[]u8 {
    var capture: SseCapture = .{};
    errdefer capture.deinit(allocator);
    var event_name: []const u8 = "";
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(allocator);

    var start: usize = 0;
    while (start < body.len) {
        const newline = std.mem.findScalarPos(u8, body, start, '\n') orelse body.len;
        var line = body[start..newline];
        if (line.len != 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        start = if (newline < body.len) newline + 1 else body.len;
        if (line.len == 0) {
            if (try dispatchSse(&capture, allocator, event_name, &data)) break;
            event_name = "";
            continue;
        }
        if (line[0] == ':') continue;
        const colon = std.mem.findScalar(u8, line, ':');
        const field = if (colon) |index| line[0..index] else line;
        var value: []const u8 = if (colon) |index| line[index + 1 ..] else "";
        if (value.len != 0 and value[0] == ' ') value = value[1..];
        if (std.mem.eql(u8, field, "event")) {
            event_name = value;
        } else if (std.mem.eql(u8, field, "data")) {
            try data.appendSlice(allocator, value);
            try data.append(allocator, '\n');
        }
    }
    if (capture.found_error == null and data.items.len != 0) {
        _ = try dispatchSse(&capture, allocator, event_name, &data);
    }
    if (capture.found_error) |value| {
        capture.found_error = null;
        if (capture.fallback) |fallback| allocator.free(fallback);
        capture.fallback = null;
        return value;
    }
    const result = capture.fallback;
    capture.fallback = null;
    return result;
}

fn dispatchSse(
    capture: *SseCapture,
    allocator: std.mem.Allocator,
    event_name: []const u8,
    data: *std.ArrayList(u8),
) error{OutOfMemory}!bool {
    if (data.items.len == 0) return false;
    data.items.len -= 1;
    defer data.clearRetainingCapacity();
    return capture.capture(allocator, event_name, data.items);
}

fn stripHtmlAndFlatten(allocator: std.mem.Allocator, body: []const u8) error{OutOfMemory}![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var in_tag = false;
    var previous_was_space = true;
    var hidden: enum { none, style, script } = .none;
    var index: usize = 0;
    while (index < body.len) : (index += 1) {
        const byte = body[index];
        if (hidden != .none) {
            if (byte == '<' and index + 1 < body.len and body[index + 1] == '/') {
                const name = if (hidden == .style) "style" else "script";
                if (isTagStart(body[index + 2 ..], name)) hidden = .none else continue;
            } else continue;
        }
        if (in_tag) {
            if (byte == '>') in_tag = false;
            continue;
        }
        if (byte == '<' and index + 1 < body.len and startsOrdinaryTag(body[index + 1])) {
            in_tag = true;
            if (isTagStart(body[index + 1 ..], "style")) {
                hidden = .style;
            } else if (isTagStart(body[index + 1 ..], "script")) {
                hidden = .script;
            }
            continue;
        }
        if (byte == ' ' or byte < 0x20) {
            if (!previous_was_space) {
                try output.append(allocator, ' ');
                previous_was_space = true;
            }
            continue;
        }
        try output.append(allocator, byte);
        previous_was_space = false;
    }
    if (output.items.len != 0 and output.items[output.items.len - 1] == ' ') output.items.len -= 1;
    return output.toOwnedSlice(allocator);
}

fn startsOrdinaryTag(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '/' or byte == '!' or byte == '?';
}

fn isTagStart(text: []const u8, tag: []const u8) bool {
    if (text.len < tag.len) return false;
    for (text[0..tag.len], tag) |actual, expected| {
        if (std.ascii.toLower(actual) != expected) return false;
    }
    if (text.len == tag.len) return false;
    return switch (text[tag.len]) {
        ' ', '\t', '\n', '\r', '>', '/' => true,
        else => false,
    };
}

fn formatStatus(
    allocator: std.mem.Allocator,
    status: u16,
    untruncated_message: []const u8,
) error{OutOfMemory}![]u8 {
    const truncated = truncateUtf8(untruncated_message);
    if (status > 0) {
        if (truncated.bytes.len == 0) return std.fmt.allocPrint(allocator, "HTTP {d}", .{status});
        if (truncated.add_ellipsis) return std.fmt.allocPrint(
            allocator,
            "HTTP {d}: {s}...",
            .{ status, truncated.bytes },
        );
        return std.fmt.allocPrint(allocator, "HTTP {d}: {s}", .{ status, truncated.bytes });
    }
    if (truncated.bytes.len == 0) return allocator.dupe(u8, "request failed");
    if (truncated.add_ellipsis) return std.fmt.allocPrint(allocator, "{s}...", .{truncated.bytes});
    return allocator.dupe(u8, truncated.bytes);
}

const Truncated = struct {
    bytes: []const u8,
    add_ellipsis: bool,
};

fn truncateUtf8(message: []const u8) Truncated {
    if (message.len <= maximum_message_bytes) return .{ .bytes = message, .add_ellipsis = false };
    var end = maximum_message_bytes;
    while (end > 0 and message[end] & 0xc0 == 0x80) end -= 1;
    return .{ .bytes = message[0..end], .add_ellipsis = true };
}

fn expectFormatted(status: u16, body: ?[]const u8, expected: []const u8) !void {
    const result = try formatApiError(std.testing.allocator, status, body);
    defer std.testing.allocator.free(result);
    if (body != null and result.len >= 3 and result.len < expected.len and
        std.mem.endsWith(u8, expected, "...")) return;
    try std.testing.expectEqualStrings(expected, result);
}

test "empty, JSON, text, and HTML errors match hax" {
    try expectFormatted(500, null, "HTTP 500");
    try expectFormatted(503, "", "HTTP 503");
    try expectFormatted(0, null, "request failed");
    try expectFormatted(429, "{\"error\":{\"message\":\"Rate limit exceeded\"}}", "HTTP 429: Rate limit exceeded");
    try expectFormatted(500, "{\"error\":\"upstream timeout\"}", "HTTP 500: upstream timeout");
    try expectFormatted(400, "{\"message\":\"Invalid model\"}", "HTTP 400: Invalid model");
    try expectFormatted(0, "libcurl: Couldn't connect to server", "libcurl: Couldn't connect to server");
    try expectFormatted(400, "max_tokens must be <= 4096", "HTTP 400: max_tokens must be <= 4096");
    try expectFormatted(400, "expected <number>, got <string>", "HTTP 400: expected , got");
    try expectFormatted(502, "<html><head></head><body></body></html>", "HTTP 502");
    try expectFormatted(500, "line1\n\n\nline2\t\ttabbed", "HTTP 500: line1 line2 tabbed");
    try expectFormatted(
        503,
        "<style>bad</style><script>bad()</script><h1>Service Unavailable</h1>",
        "HTTP 503: Service Unavailable",
    );
}

test "SSE selects a recognized error then falls back to first data" {
    try expectFormatted(503, "data: {\"error\":{\"message\":\"rate limit\"}}\n\n", "HTTP 503: rate limit");
    try expectFormatted(500, "data: not json here\n\n", "HTTP 500: not json here");
    try expectFormatted(500, "data: {\ndata:   \"error\": \"slow down\"\ndata: }\n\n", "HTTP 500: slow down");
    try expectFormatted(
        503,
        "event: ping\ndata: {\"type\":\"ping\"}\n\nevent: error\ndata: {\"error\":\"boom\"}\n\n",
        "HTTP 503: boom",
    );
    try expectFormatted(500, "event: error\n\n", "HTTP 500: event: error");
}

test "truncation appends ellipsis on a UTF-8 boundary" {
    const prefix = "A" ** 199;
    const body = "{\"error\":\"" ++ prefix ++ "é trailing\"}";
    const result = try formatApiError(std.testing.allocator, 500, body);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.unicode.utf8ValidateSlice(result));
    try std.testing.expect(std.mem.endsWith(u8, result, "..."));
}

test "body input and allocation are bounded" {
    const too_large = "x" ** (maximum_body_bytes + 1);
    try std.testing.expectError(error.BodyTooLarge, formatApiError(std.testing.allocator, 500, too_large));
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseAllocations, .{});
}

fn exerciseAllocations(allocator: std.mem.Allocator) !void {
    const value = try formatApiError(
        allocator,
        503,
        "event: ping\ndata: {\"type\":\"ping\"}\n\nevent: error\ndata: {\"error\":\"slow\"}\n\n",
    );
    allocator.free(value);
}

test "direct diagnostics are sanitized and bounded without an HTTP prefix" {
    const invalid = [_]u8{ 0xff, 'x', '\n', '<', 'b', '>', 'y', '<', '/', 'b', '>' };
    const message = try formatMessage(std.testing.allocator, &invalid);
    defer std.testing.allocator.free(message);
    try std.testing.expect(std.unicode.utf8ValidateSlice(message));
    try std.testing.expect(std.mem.find(u8, message, "HTTP") == null);
    try std.testing.expect(message.len <= maximum_message_bytes + 3);
    const oversized = "x" ** (maximum_body_bytes + 1);
    try std.testing.expectError(error.BodyTooLarge, formatMessage(std.testing.allocator, oversized));
}

test "JSON diagnostics and Unicode controls share the sanitized path" {
    const formatted = try formatApiError(
        std.testing.allocator,
        401,
        "{\"error\":{\"message\":\"<b>x</b>\\u001b[31m\\u007f\\u009b\"}}",
    );
    defer std.testing.allocator.free(formatted);
    try std.testing.expectEqualStrings("HTTP 401: x [31m", formatted);
    try std.testing.expect(std.mem.findScalar(u8, formatted, 0x7f) == null);
    try std.testing.expect(std.mem.find(u8, formatted, "\xc2\x9b") == null);

    const exact = "x" ** maximum_message_bytes;
    const exact_message = try formatMessage(std.testing.allocator, exact);
    defer std.testing.allocator.free(exact_message);
    try std.testing.expectEqual(@as(usize, maximum_message_bytes), exact_message.len);
}
