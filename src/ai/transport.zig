const std = @import("std");
const Provider = @import("Provider.zig");

/// Controls where a request may carry privileged origin headers. The default
/// keeps them on HTTPS; the relaxed policy admits them only on loopback HTTP.
pub const PrivilegedHeaderPolicy = enum {
    https_only,
    https_or_loopback_http,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
    /// Privileged headers must not be included in diagnostics or user-visible errors.
    privileged: bool = false,

    pub fn isPrivileged(self: Header) bool {
        return self.privileged or
            std.ascii.eqlIgnoreCase(self.name, "authorization") or
            std.ascii.eqlIgnoreCase(self.name, "proxy-authorization");
    }
};

/// Byte bounds and the connect timeout must be non-zero. An idle timeout of
/// zero disables idle timeout enforcement; it does not disable the connect timeout.
pub const Limits = struct {
    max_request_body_bytes: usize,
    max_header_bytes: usize,
    max_sse_event_bytes: usize,
    max_error_body_bytes: usize,
    header_buffer_bytes: usize,
    connect_timeout_ms: u64,
    idle_timeout_ms: u64,
};

/// Borrowed request. Every slice and the tick implementation must remain valid until
/// `ssePost` returns. `json_body` is already encoded and is not retained by transports.
pub const Request = struct {
    url: []const u8,
    headers: []const Header,
    json_body: []const u8,
    tick: ?Provider.Tick = null,
    privileged_header_policy: PrivilegedHeaderPolicy = .https_only,
    limits: Limits,
};

/// Borrowed SSE payload, valid only during the synchronous `emit` call.
pub const SseEvent = struct {
    event_name: ?[]const u8 = null,
    data: []const u8,
};

pub const DeliveryError = error{Cancelled};

pub const EventSink = struct {
    context: *anyopaque,
    emit_fn: *const fn (*anyopaque, SseEvent) DeliveryError!void,

    pub fn emit(self: EventSink, event: SseEvent) DeliveryError!void {
        return self.emit_fn(self.context, event);
    }

    pub fn from(implementation: anytype) EventSink {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("EventSink.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn emit(context: *anyopaque, event: SseEvent) DeliveryError!void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.emit(event);
            }
        };
        return .{ .context = implementation, .emit_fn = Adapter.emit };
    }
};

pub const Outcome = enum {
    completed,
    failed,
};

/// Owned transport result. A zero status means that no HTTP response was received.
/// `error_body`, when present, is owned by this value and freed by `deinit`.
pub const Result = struct {
    status: u16 = 0,
    retry_after_ms: ?u64 = null,
    outcome: Outcome,
    error_body: ?[]u8 = null,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        if (self.error_body) |body| allocator.free(body);
        self.* = undefined;
    }
};

pub const StreamError = error{
    OutOfMemory,
    Cancelled,
    ConnectTimedOut,
    IdleTimedOut,
    InvalidRequest,
    ConnectionFailed,
    TlsVerificationFailed,
    InvalidResponse,
};

/// Erased streaming HTTP POST interface. Implementations may borrow request data only
/// for the call. Returned `Result` ownership transfers to the caller.
pub const Transport = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Implementations inspect the HTTP status before delivery and invoke the
        /// event sink only for a 2xx SSE response. Non-2xx bodies belong in Result.
        sse_post: *const fn (
            std.mem.Allocator,
            std.Io,
            *anyopaque,
            Request,
            EventSink,
        ) StreamError!Result,
    };

    pub fn from(implementation: anytype) Transport {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("Transport.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn ssePostFn(
                allocator: std.mem.Allocator,
                io: std.Io,
                context: *anyopaque,
                request: Request,
                sink: EventSink,
            ) StreamError!Result {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return Implementation.ssePost(allocator, io, self, request, sink);
            }

            const vtable: VTable = .{ .sse_post = ssePostFn };
        };
        return .{ .context = implementation, .vtable = &Adapter.vtable };
    }

    pub fn ssePost(
        self: Transport,
        allocator: std.mem.Allocator,
        io: std.Io,
        request: Request,
        sink: EventSink,
    ) StreamError!Result {
        try validateRequest(request);
        if (request.tick) |tick| try tick.poll();

        var bounded_sink: BoundedSink = .{
            .downstream = sink,
            .max_event_bytes = request.limits.max_sse_event_bytes,
        };
        var result = self.vtable.sse_post(
            allocator,
            io,
            self.context,
            request,
            EventSink.from(&bounded_sink),
        ) catch |err| {
            if (bounded_sink.invalid_event) return error.InvalidResponse;
            if (bounded_sink.delivery_cancelled) return error.Cancelled;
            return err;
        };
        errdefer result.deinit(allocator);

        if (bounded_sink.invalid_event) return error.InvalidResponse;
        if (bounded_sink.delivery_cancelled) return error.Cancelled;
        try validateResult(result, request.limits);
        return result;
    }
};

const BoundedSink = struct {
    downstream: EventSink,
    max_event_bytes: usize,
    invalid_event: bool = false,
    delivery_cancelled: bool = false,

    fn emit(self: *BoundedSink, event: SseEvent) DeliveryError!void {
        if (self.invalid_event or self.delivery_cancelled) return error.Cancelled;
        const event_name_len = if (event.event_name) |name| name.len else 0;
        const total = std.math.add(usize, event_name_len, event.data.len) catch {
            self.invalid_event = true;
            return error.Cancelled;
        };
        if (total > self.max_event_bytes or !validEventName(event.event_name)) {
            self.invalid_event = true;
            return error.Cancelled;
        }
        self.downstream.emit(event) catch {
            self.delivery_cancelled = true;
            return error.Cancelled;
        };
    }
};

fn validateRequest(request: Request) StreamError!void {
    const limits = request.limits;
    if (limits.max_request_body_bytes == 0 or
        limits.max_header_bytes == 0 or
        limits.max_sse_event_bytes == 0 or
        limits.max_error_body_bytes == 0 or
        limits.header_buffer_bytes == 0 or
        limits.connect_timeout_ms == 0)
    {
        return error.InvalidRequest;
    }
    try validateRequestSecurity(request.url, request.headers, request.privileged_header_policy);
    if (request.json_body.len == 0 or request.json_body.len > limits.max_request_body_bytes) {
        return error.InvalidRequest;
    }

    var header_bytes: usize = 0;
    for (request.headers) |header| {
        header_bytes = std.math.add(usize, header_bytes, header.name.len) catch
            return error.InvalidRequest;
        header_bytes = std.math.add(usize, header_bytes, header.value.len) catch
            return error.InvalidRequest;
        if (header_bytes > limits.max_header_bytes) return error.InvalidRequest;
    }
}

fn validateResult(result: Result, limits: Limits) StreamError!void {
    if (result.status != 0 and (result.status < 100 or result.status > 599)) {
        return error.InvalidResponse;
    }
    if (result.error_body) |body| {
        if (body.len > limits.max_error_body_bytes) return error.InvalidResponse;
    }
    if (result.retry_after_ms) |delay| {
        if (delay > 120_000) return error.InvalidResponse;
    }
    if (result.outcome == .completed and
        (result.status < 200 or result.status >= 300 or
            result.error_body != null or result.retry_after_ms != null))
    {
        return error.InvalidResponse;
    }
}

/// Validates URL syntax, header syntax, duplicate names, and privileged-header
/// placement without allocating. Concrete transports must call this too because
/// callers can bypass the erased transport seam.
pub fn validateRequestSecurity(
    url: []const u8,
    headers: []const Header,
    privileged_header_policy: PrivilegedHeaderPolicy,
) error{InvalidRequest}!void {
    if (!validUrl(url)) return error.InvalidRequest;
    for (headers, 0..) |header, index| {
        if (!validHeaderName(header.name) or !validHeaderValue(header.value)) {
            return error.InvalidRequest;
        }
        for (headers[index + 1 ..]) |other| {
            if (std.ascii.eqlIgnoreCase(header.name, other.name)) return error.InvalidRequest;
        }
    }

    if (std.mem.startsWith(u8, url, "https://")) return;
    for (headers) |header| {
        if (!header.isPrivileged()) continue;
        const loopback_privileged = privileged_header_policy == .https_or_loopback_http and
            !std.ascii.eqlIgnoreCase(header.name, "proxy-authorization") and
            validCanonicalLoopbackHttp(url);
        if (!loopback_privileged) return error.InvalidRequest;
    }
}

fn validCanonicalLoopbackHttp(url: []const u8) bool {
    const prefix = "http://";
    if (!std.mem.startsWith(u8, url, prefix)) return false;
    const remainder = url[prefix.len..];
    const authority_end = std.mem.indexOfAny(u8, remainder, "/?#") orelse remainder.len;
    const authority = remainder[0..authority_end];
    if (authority.len == 0 or
        std.mem.indexOfScalar(u8, authority, '%') != null or
        std.mem.indexOfScalar(u8, authority, '@') != null)
    {
        return false;
    }

    if (std.mem.startsWith(u8, authority, "[")) {
        const host = "[::1]";
        if (!std.mem.startsWith(u8, authority, host)) return false;
        if (authority.len == host.len) return true;
        if (authority[host.len] != ':') return false;
        return validPort(authority[host.len + 1 ..]);
    }

    const colon = std.mem.findScalar(u8, authority, ':');
    const host = if (colon) |index| authority[0..index] else authority;
    if (colon) |index| {
        if (!validPort(authority[index + 1 ..])) return false;
    }
    return validCanonicalIpv4Loopback(host);
}

fn validCanonicalIpv4Loopback(host: []const u8) bool {
    var octets: usize = 0;
    var remaining = host;
    while (true) {
        const dot = std.mem.findScalar(u8, remaining, '.');
        const octet = if (dot) |index| remaining[0..index] else remaining;
        if (octet.len == 0 or (octet.len > 1 and octet[0] == '0')) return false;
        var value: u16 = 0;
        for (octet) |byte| {
            if (!std.ascii.isDigit(byte)) return false;
            value = value * 10 + (byte - '0');
            if (value > 255) return false;
        }
        if (octets == 0 and value != 127) return false;
        octets += 1;
        if (dot == null) break;
        remaining = remaining[dot.? + 1 ..];
    }
    return octets == 4;
}

fn validPort(port: []const u8) bool {
    if (port.len == 0) return false;
    var value: u32 = 0;
    for (port) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
        value = value * 10 + (byte - '0');
        if (value > 65_535) return false;
    }
    return value != 0;
}

fn validUrl(url: []const u8) bool {
    if (url.len == 0) return false;
    for (url) |byte| {
        if (byte <= 0x20 or byte == 0x7f or byte == '\\') return false;
    }
    const uri = std.Uri.parse(url) catch return false;
    if (!std.mem.eql(u8, uri.scheme, "https") and !std.mem.eql(u8, uri.scheme, "http")) return false;
    if (uri.host == null or uri.user != null or uri.password != null or uri.fragment != null) return false;
    return !uri.host.?.isEmpty();
}

fn validHeaderName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        if (!isTokenByte(byte)) return false;
    }
    return true;
}

fn isTokenByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or switch (byte) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

fn validHeaderValue(value: []const u8) bool {
    for (value) |byte| {
        if ((byte < 0x20 and byte != '\t') or byte == 0x7f) return false;
    }
    return true;
}

fn validEventName(event_name: ?[]const u8) bool {
    const name = event_name orelse return true;
    for (name) |byte| {
        if (byte == '\r' or byte == '\n' or byte == 0) return false;
    }
    return true;
}

const test_limits: Limits = .{
    .max_request_body_bytes = 64,
    .max_header_bytes = 64,
    .max_sse_event_bytes = 64,
    .max_error_body_bytes = 64,
    .header_buffer_bytes = 128,
    .connect_timeout_ms = 1_000,
    .idle_timeout_ms = 2_000,
};

fn testRequest() Request {
    return .{
        .url = "https://example.test/stream",
        .headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        .json_body = "{}",
        .limits = test_limits,
    };
}

test "zero idle timeout is disabled while connect timeout remains required" {
    var request = testRequest();
    request.limits.idle_timeout_ms = 0;
    try validateRequest(request);

    request.limits.connect_timeout_ms = 0;
    try std.testing.expectError(error.InvalidRequest, validateRequest(request));
}

test "erased transport delivers borrowed SSE data synchronously" {
    const Fake = struct {
        const Self = @This();
        saw_request: bool = false,

        fn ssePost(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            request: Request,
            sink: EventSink,
        ) StreamError!Result {
            self.saw_request = std.mem.eql(u8, request.json_body, "{}");
            var bytes = [_]u8{ 'o', 'k' };
            try sink.emit(.{ .event_name = "message", .data = &bytes });
            bytes = .{ 'x', 'x' };
            return .{ .status = 200, .outcome = .completed };
        }
    };
    const Collector = struct {
        const Self = @This();
        bytes: [2]u8 = undefined,
        named_message: bool = false,

        fn emit(self: *Self, event: SseEvent) DeliveryError!void {
            self.named_message = std.mem.eql(u8, "message", event.event_name.?);
            @memcpy(&self.bytes, event.data);
        }
    };

    var fake: Fake = .{};
    var collector: Collector = .{};
    var result = try Transport.from(&fake).ssePost(
        std.testing.allocator,
        std.testing.io,
        testRequest(),
        EventSink.from(&collector),
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(fake.saw_request);
    try std.testing.expect(collector.named_message);
    try std.testing.expectEqualStrings("ok", &collector.bytes);
}

test "result owns and deinitializes bounded error body" {
    const Fake = struct {
        const Self = @This();

        fn ssePost(
            allocator: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            _: Request,
            _: EventSink,
        ) StreamError!Result {
            return .{
                .status = 429,
                .retry_after_ms = 500,
                .outcome = .failed,
                .error_body = try allocator.dupe(u8, "slow down"),
            };
        }
    };
    const Ignore = struct {
        const Self = @This();
        fn emit(_: *Self, _: SseEvent) DeliveryError!void {}
    };

    var fake: Fake = .{};
    var ignore: Ignore = .{};
    var result = try Transport.from(&fake).ssePost(
        std.testing.allocator,
        std.testing.io,
        testRequest(),
        EventSink.from(&ignore),
    );
    try std.testing.expectEqualStrings("slow down", result.error_body.?);
    result.deinit(std.testing.allocator);
}

test "request bounds and header syntax are validated before dispatch" {
    const Fake = struct {
        const Self = @This();
        calls: usize = 0,
        fn ssePost(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            _: Request,
            _: EventSink,
        ) StreamError!Result {
            self.calls += 1;
            return .{ .outcome = .completed };
        }
    };
    const Ignore = struct {
        const Self = @This();
        fn emit(_: *Self, _: SseEvent) DeliveryError!void {}
    };

    var fake: Fake = .{};
    var ignore: Ignore = .{};
    var request = testRequest();
    request.headers = &.{.{ .name = "Bad Name", .value = "value" }};
    try std.testing.expectError(error.InvalidRequest, Transport.from(&fake).ssePost(
        std.testing.allocator,
        std.testing.io,
        request,
        EventSink.from(&ignore),
    ));
    request = testRequest();
    request.headers = &.{
        .{ .name = "X-Test", .value = "one" },
        .{ .name = "x-test", .value = "two" },
    };
    try std.testing.expectError(error.InvalidRequest, Transport.from(&fake).ssePost(
        std.testing.allocator,
        std.testing.io,
        request,
        EventSink.from(&ignore),
    ));
    try std.testing.expect((Header{ .name = "AUTHORIZATION", .value = "secret" }).isPrivileged());
    request = testRequest();
    request.limits.max_request_body_bytes = 1;
    try std.testing.expectError(error.InvalidRequest, Transport.from(&fake).ssePost(
        std.testing.allocator,
        std.testing.io,
        request,
        EventSink.from(&ignore),
    ));
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

test "oversized SSE event is an invalid response" {
    const Fake = struct {
        const Self = @This();
        fn ssePost(
            _: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            _: Request,
            sink: EventSink,
        ) StreamError!Result {
            try sink.emit(.{ .data = "too large" });
            return .{ .outcome = .completed };
        }
    };
    const Ignore = struct {
        const Self = @This();
        fn emit(_: *Self, _: SseEvent) DeliveryError!void {}
    };

    var fake: Fake = .{};
    var ignore: Ignore = .{};
    var request = testRequest();
    request.limits.max_sse_event_bytes = 3;
    try std.testing.expectError(error.InvalidResponse, Transport.from(&fake).ssePost(
        std.testing.allocator,
        std.testing.io,
        request,
        EventSink.from(&ignore),
    ));
}

test "sink and tick cancellation remain cancellation" {
    const Fake = struct {
        const Self = @This();
        fn ssePost(
            _: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            _: Request,
            sink: EventSink,
        ) StreamError!Result {
            sink.emit(.{ .data = "stop" }) catch return .{ .outcome = .completed };
            return .{ .outcome = .completed };
        }
    };
    const Canceller = struct {
        const Self = @This();
        fn emit(_: *Self, _: SseEvent) DeliveryError!void {
            return error.Cancelled;
        }
    };
    const TickCanceller = struct {
        const Self = @This();
        pub fn poll(_: *Self) Provider.DeliveryError!void {
            return error.Cancelled;
        }
    };

    var fake: Fake = .{};
    var canceller: Canceller = .{};
    try std.testing.expectError(error.Cancelled, Transport.from(&fake).ssePost(
        std.testing.allocator,
        std.testing.io,
        testRequest(),
        EventSink.from(&canceller),
    ));
    var ticker: TickCanceller = .{};
    var request = testRequest();
    request.tick = Provider.Tick.from(&ticker);
    try std.testing.expectError(error.Cancelled, Transport.from(&fake).ssePost(
        std.testing.allocator,
        std.testing.io,
        request,
        EventSink.from(&canceller),
    ));
}

test "allocation failure is returned without dispatch result" {
    const Fake = struct {
        const Self = @This();
        fn ssePost(
            allocator: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            _: Request,
            _: EventSink,
        ) StreamError!Result {
            return .{
                .outcome = .failed,
                .error_body = try allocator.dupe(u8, "body"),
            };
        }
    };
    const Ignore = struct {
        const Self = @This();
        fn emit(_: *Self, _: SseEvent) DeliveryError!void {}
    };

    var fake: Fake = .{};
    var ignore: Ignore = .{};
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, Transport.from(&fake).ssePost(
        failing.allocator(),
        std.testing.io,
        testRequest(),
        EventSink.from(&ignore),
    ));
}

test "invalid owned result is deinitialized" {
    const Fake = struct {
        const Self = @This();
        fn ssePost(
            allocator: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            _: Request,
            _: EventSink,
        ) StreamError!Result {
            return .{
                .status = 503,
                .outcome = .failed,
                .error_body = try allocator.dupe(u8, "body exceeds bound"),
            };
        }
    };
    const Ignore = struct {
        const Self = @This();
        fn emit(_: *Self, _: SseEvent) DeliveryError!void {}
    };

    var fake: Fake = .{};
    var ignore: Ignore = .{};
    var request = testRequest();
    request.limits.max_error_body_bytes = 4;
    try std.testing.expectError(error.InvalidResponse, Transport.from(&fake).ssePost(
        std.testing.allocator,
        std.testing.io,
        request,
        EventSink.from(&ignore),
    ));
}

test "proxy authorization is privileged" {
    try std.testing.expect((Header{ .name = "Proxy-Authorization", .value = "secret" }).isPrivileged());
}

test "bounded sink cancellation is sticky" {
    const Reject = struct {
        const Self = @This();
        calls: usize = 0,
        pub fn emit(self: *Self, _: SseEvent) DeliveryError!void {
            self.calls += 1;
            return error.Cancelled;
        }
    };
    var reject: Reject = .{};
    var bounded: BoundedSink = .{
        .downstream = EventSink.from(&reject),
        .max_event_bytes = 16,
    };
    try std.testing.expectError(error.Cancelled, bounded.emit(.{ .data = "one" }));
    try std.testing.expectError(error.Cancelled, bounded.emit(.{ .data = "two" }));
    try std.testing.expectEqual(@as(usize, 1), reject.calls);
}

test "downstream cancellation wins over a later transport error" {
    const Reject = struct {
        const Self = @This();
        pub fn emit(_: *Self, _: SseEvent) DeliveryError!void {
            return error.Cancelled;
        }
    };
    const BadTransport = struct {
        const Self = @This();
        pub fn ssePost(
            _: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            _: Request,
            sink: EventSink,
        ) StreamError!Result {
            sink.emit(.{ .data = "one" }) catch |err| std.debug.assert(err == error.Cancelled);
            sink.emit(.{ .data = "two" }) catch |err| std.debug.assert(err == error.Cancelled);
            return error.ConnectionFailed;
        }
    };
    var reject: Reject = .{};
    var bad: BadTransport = .{};
    try std.testing.expectError(error.Cancelled, Transport.from(&bad).ssePost(
        std.testing.allocator,
        std.testing.io,
        testRequest(),
        EventSink.from(&reject),
    ));
}

test "streaming URL userinfo and privileged cleartext headers are rejected" {
    const Fake = struct {
        const Self = @This();
        calls: usize = 0,

        fn ssePost(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            _: Request,
            _: EventSink,
        ) StreamError!Result {
            self.calls += 1;
            return .{ .status = 200, .outcome = .completed };
        }
    };
    const Ignore = struct {
        const Self = @This();
        fn emit(_: *Self, _: SseEvent) DeliveryError!void {}
    };
    var fake: Fake = .{};
    var ignore: Ignore = .{};
    var value = testRequest();
    value.url = "https://user@example.test/stream";
    try std.testing.expectError(error.InvalidRequest, Transport.from(&fake).ssePost(
        std.testing.allocator,
        std.testing.io,
        value,
        EventSink.from(&ignore),
    ));
    value = testRequest();
    value.url = "http://example.test/stream";
    value.headers = &.{.{ .name = "Authorization", .value = "Bearer secret" }};
    try std.testing.expectError(error.InvalidRequest, Transport.from(&fake).ssePost(
        std.testing.allocator,
        std.testing.io,
        value,
        EventSink.from(&ignore),
    ));
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

test "loopback HTTP policy admits privileged origin headers only on canonical addresses" {
    const authorization = &.{Header{ .name = "Authorization", .value = "Bearer secret" }};
    inline for (.{
        "http://127.0.0.1/v1/models",
        "http://127.255.2.3:8080/v1/models",
        "http://[::1]/v1/models",
        "http://[::1]:11434/v1/models",
    }) |url| {
        try validateRequestSecurity(url, authorization, .https_or_loopback_http);
    }

    inline for (.{
        "http://localhost:8080/v1/models",
        "http://127.0.0.1.evil.test/v1/models",
        "http://127.0.0.1@evil.test/v1/models",
        "http://127%2e0%2e0%2e1/v1/models",
        "http://127.1/v1/models",
        "http://127.00.0.1/v1/models",
        "http://127.0.0.1:0/v1/models",
        "http://[::1]:65536/v1/models",
    }) |url| {
        try std.testing.expectError(error.InvalidRequest, validateRequestSecurity(
            url,
            authorization,
            .https_or_loopback_http,
        ));
    }

    try validateRequestSecurity(
        "http://127.0.0.1/v1/models",
        &.{.{ .name = "X-Token", .value = "secret", .privileged = true }},
        .https_or_loopback_http,
    );
    try std.testing.expectError(error.InvalidRequest, validateRequestSecurity(
        "http://127.0.0.1/v1/models",
        &.{.{ .name = "Proxy-Authorization", .value = "secret" }},
        .https_or_loopback_http,
    ));
    try std.testing.expectError(error.InvalidRequest, validateRequestSecurity(
        "http://127.0.0.1/v1/models",
        authorization,
        .https_only,
    ));
}
