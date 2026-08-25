const std = @import("std");
const ai = @import("ai/root.zig");
const CodexAuth = @import("CodexAuth.zig");

const CodexRefreshRotator = @This();
const JsonTransport = ai.JsonTransport;
const Provider = ai.Provider;
const Refresh = ai.CodexRefresh;

pub const timeout_ms: u64 = @as(u64, Refresh.request_timeout_seconds) * std.time.ms_per_s;
pub const limits: JsonTransport.Limits = .{
    .max_request_body_bytes = Refresh.maximum_response_bytes,
    .max_response_body_bytes = Refresh.maximum_response_bytes,
    .max_header_bytes = JsonTransport.maximum_header_bytes,
    .header_buffer_bytes = JsonTransport.maximum_header_bytes,
    .connect_timeout_ms = 2_000,
    .idle_timeout_ms = 0,
    .total_timeout_ms = timeout_ms,
};

/// Stable adapter over a borrowed JSON transport. The adapter and the transport
/// implementation behind `transport` must outlive every Rotator returned by `rotator`.
transport: JsonTransport.Transport,

pub fn init(transport: JsonTransport.Transport) CodexRefreshRotator {
    return .{ .transport = transport };
}

/// The adapter must not move while the returned erased interface is in use.
pub fn rotator(self: *CodexRefreshRotator) CodexAuth.Rotator {
    return CodexAuth.Rotator.from(self);
}

pub fn rotate(
    self: *CodexRefreshRotator,
    allocator: std.mem.Allocator,
    io: std.Io,
    request: Refresh.Request,
    tick: ?Provider.Tick,
) CodexAuth.Rotator.Error!CodexAuth.RotationResult {
    // Refresh descriptors are public values, but credential rotation must never
    // accept a redirected endpoint or a widened exchange policy.
    if (!std.mem.eql(u8, request.endpoint, Refresh.token_endpoint) or
        !std.mem.eql(u8, request.content_type, Refresh.content_type) or
        request.timeout_seconds != Refresh.request_timeout_seconds or
        request.body.len > limits.max_request_body_bytes)
    {
        return .transient;
    }

    // This is the last cancellation point. Once dispatched, the server may have
    // consumed the one-use refresh token, so the bounded exchange must finish.
    if (tick) |value| try value.poll();

    var response = self.transport.request(allocator, io, .{
        .method = .post,
        .url = Refresh.token_endpoint,
        .headers = &.{.{ .name = "Content-Type", .value = Refresh.content_type }},
        .json_body = request.body,
        .tick = null,
        .limits = limits,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .transient,
    };

    // JsonTransport enforces this too. Keep the ownership boundary defensive
    // in case a future injected transport violates its response contract.
    if (response.body.len > limits.max_response_body_bytes) {
        response.deinit(allocator);
        return .transient;
    }

    const result: CodexAuth.RotationResult = .{ .response = .{
        .status = response.status,
        .body = response.body,
    } };
    response = undefined;
    return result;
}

const FakeTransport = struct {
    mode: Mode = .response,
    calls: usize = 0,
    status: u16 = 200,
    body: []const u8 = "{\"access_token\":\"new\"}",
    expected_body: []const u8 = "request-secret",
    exact_request: bool = false,
    saw_suppressed_tick: bool = false,

    const Mode = enum {
        response,
        out_of_memory,
        cancelled,
        connect_timed_out,
        idle_timed_out,
        invalid_request,
        connection_failed,
        tls_verification_failed,
        invalid_response,
        oversized,
    };

    pub fn request(
        allocator: std.mem.Allocator,
        _: std.Io,
        self: *FakeTransport,
        request_value: JsonTransport.Request,
    ) JsonTransport.Error!JsonTransport.Response {
        self.calls += 1;
        self.saw_suppressed_tick = request_value.tick == null;
        self.exact_request = request_value.method == .post and
            std.mem.eql(u8, request_value.url, Refresh.token_endpoint) and
            request_value.headers.len == 1 and
            std.mem.eql(u8, request_value.headers[0].name, "Content-Type") and
            std.mem.eql(u8, request_value.headers[0].value, Refresh.content_type) and
            request_value.json_body != null and
            std.mem.eql(u8, request_value.json_body.?, self.expected_body) and
            std.meta.eql(request_value.limits, limits);
        return switch (self.mode) {
            .response => .{ .status = self.status, .body = try allocator.dupe(u8, self.body) },
            .out_of_memory => error.OutOfMemory,
            .cancelled => error.Cancelled,
            .connect_timed_out => error.ConnectTimedOut,
            .idle_timed_out => error.IdleTimedOut,
            .invalid_request => error.InvalidRequest,
            .connection_failed => error.ConnectionFailed,
            .tls_verification_failed => error.TlsVerificationFailed,
            .invalid_response => error.InvalidResponse,
            .oversized => .{
                .status = 200,
                .body = try allocator.alloc(u8, Refresh.maximum_response_bytes + 1),
            },
        };
    }
};

fn testRefreshRequest(body: []u8) Refresh.Request {
    return .{ .allocator = std.testing.allocator, .body = body };
}

test "rotation dispatches the exact bounded refresh POST" {
    var fake: FakeTransport = .{};
    var adapter: CodexRefreshRotator = .init(JsonTransport.Transport.from(&fake));
    var body = [_]u8{ 'r', 'e', 'q', 'u', 'e', 's', 't', '-', 's', 'e', 'c', 'r', 'e', 't' };
    var result = try adapter.rotator().rotate(
        std.testing.allocator,
        std.testing.io,
        testRefreshRequest(&body),
        null,
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 2_000), limits.connect_timeout_ms);
    try std.testing.expectEqual(@as(u64, 30_000), limits.total_timeout_ms);
    try std.testing.expectEqual(@as(u64, 0), limits.idle_timeout_ms);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expect(fake.exact_request);
    try std.testing.expect(fake.saw_suppressed_tick);
    try std.testing.expectEqual(@as(u16, 200), result.response.status);
}

const ScriptTick = struct {
    polls: usize = 0,
    cancel_at: usize,

    pub fn poll(self: *ScriptTick) Provider.DeliveryError!void {
        self.polls += 1;
        if (self.polls >= self.cancel_at) return error.Cancelled;
    }
};

test "cancellation is honored before dispatch and suppressed during exchange" {
    var fake: FakeTransport = .{};
    var adapter: CodexRefreshRotator = .init(JsonTransport.Transport.from(&fake));
    var body = [_]u8{ 'r', 'e', 'q', 'u', 'e', 's', 't', '-', 's', 'e', 'c', 'r', 'e', 't' };

    var before: ScriptTick = .{ .cancel_at = 1 };
    try std.testing.expectError(error.Cancelled, adapter.rotator().rotate(
        std.testing.allocator,
        std.testing.io,
        testRefreshRequest(&body),
        Provider.Tick.from(&before),
    ));
    try std.testing.expectEqual(@as(usize, 0), fake.calls);

    var during: ScriptTick = .{ .cancel_at = 2 };
    var result = try adapter.rotator().rotate(
        std.testing.allocator,
        std.testing.io,
        testRefreshRequest(&body),
        Provider.Tick.from(&during),
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), during.polls);
    try std.testing.expect(fake.saw_suppressed_tick);
}

test "owned response transfers with HTTP status and is wiped by rotation result" {
    const SecureAllocator = @import("ai/SecureAllocator.zig");
    var observer = SecureAllocator.FreeObserver.init(std.testing.allocator);
    var fake: FakeTransport = .{ .status = 400, .body = "response-secret" };
    var adapter: CodexRefreshRotator = .init(JsonTransport.Transport.from(&fake));
    var body = [_]u8{ 'r', 'e', 'q', 'u', 'e', 's', 't', '-', 's', 'e', 'c', 'r', 'e', 't' };
    var result = try adapter.rotator().rotate(
        observer.allocator(),
        std.testing.io,
        testRefreshRequest(&body),
        null,
    );
    try std.testing.expectEqual(@as(u16, 400), result.response.status);
    try std.testing.expectEqualStrings("response-secret", result.response.body);
    result.deinit(observer.allocator());
    try std.testing.expectEqual(@as(usize, 1), observer.zero_frees);
}

test "transport HTTP failures and oversized bodies are transient" {
    inline for (.{
        FakeTransport.Mode.cancelled,
        FakeTransport.Mode.connect_timed_out,
        FakeTransport.Mode.idle_timed_out,
        FakeTransport.Mode.invalid_request,
        FakeTransport.Mode.connection_failed,
        FakeTransport.Mode.tls_verification_failed,
        FakeTransport.Mode.invalid_response,
        FakeTransport.Mode.oversized,
    }) |mode| {
        var fake: FakeTransport = .{ .mode = mode };
        var adapter: CodexRefreshRotator = .init(JsonTransport.Transport.from(&fake));
        var body = [_]u8{ 'r', 'e', 'q', 'u', 'e', 's', 't', '-', 's', 'e', 'c', 'r', 'e', 't' };
        const result = try adapter.rotator().rotate(
            std.testing.allocator,
            std.testing.io,
            testRefreshRequest(&body),
            null,
        );
        try std.testing.expect(result == .transient);
    }
}

test "refresh descriptor overrides are transient before dispatch" {
    var fake: FakeTransport = .{};
    var adapter: CodexRefreshRotator = .init(JsonTransport.Transport.from(&fake));
    var body = [_]u8{ 'r', 'e', 'q', 'u', 'e', 's', 't', '-', 's', 'e', 'c', 'r', 'e', 't' };

    var request_value = testRefreshRequest(&body);
    request_value.endpoint = "https://example.test/oauth/token";
    try std.testing.expect((try adapter.rotator().rotate(
        std.testing.allocator,
        std.testing.io,
        request_value,
        null,
    )) == .transient);

    request_value = testRefreshRequest(&body);
    request_value.content_type = "application/x-www-form-urlencoded";
    try std.testing.expect((try adapter.rotator().rotate(
        std.testing.allocator,
        std.testing.io,
        request_value,
        null,
    )) == .transient);

    request_value = testRefreshRequest(&body);
    request_value.timeout_seconds = Refresh.request_timeout_seconds + 1;
    try std.testing.expect((try adapter.rotator().rotate(
        std.testing.allocator,
        std.testing.io,
        request_value,
        null,
    )) == .transient);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

test "oversized request body is transient before dispatch" {
    var fake: FakeTransport = .{};
    var adapter: CodexRefreshRotator = .init(JsonTransport.Transport.from(&fake));
    var body: [Refresh.maximum_response_bytes + 1]u8 = undefined;
    const result = try adapter.rotator().rotate(
        std.testing.allocator,
        std.testing.io,
        testRefreshRequest(&body),
        null,
    );
    try std.testing.expect(result == .transient);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

test "transport allocation failure is preserved" {
    var fake: FakeTransport = .{ .mode = .out_of_memory };
    var adapter: CodexRefreshRotator = .init(JsonTransport.Transport.from(&fake));
    var body = [_]u8{ 'r', 'e', 'q', 'u', 'e', 's', 't', '-', 's', 'e', 'c', 'r', 'e', 't' };
    try std.testing.expectError(error.OutOfMemory, adapter.rotator().rotate(
        std.testing.allocator,
        std.testing.io,
        testRefreshRequest(&body),
        null,
    ));
}

test "adapter borrows a stable transport implementation" {
    var fake: FakeTransport = .{};
    var adapter: CodexRefreshRotator = .init(JsonTransport.Transport.from(&fake));
    const erased = adapter.rotator();
    fake.status = 202;
    var body = [_]u8{ 'r', 'e', 'q', 'u', 'e', 's', 't', '-', 's', 'e', 'c', 'r', 'e', 't' };
    var result = try erased.rotate(
        std.testing.allocator,
        std.testing.io,
        testRefreshRequest(&body),
        null,
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 202), result.response.status);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
}
