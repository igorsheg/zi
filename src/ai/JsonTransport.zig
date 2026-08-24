const std = @import("std");
const Provider = @import("Provider.zig");
const Retry = @import("Retry.zig");
const StreamingTransport = @import("Transport.zig");

pub const Header = StreamingTransport.Header;

pub const maximum_request_body_bytes: usize = 16 * 1024 * 1024;
pub const maximum_response_body_bytes: usize = 32 * 1024 * 1024;
pub const maximum_headers: usize = 64;
pub const maximum_header_bytes: usize = 64 * 1024;
pub const maximum_url_bytes: usize = 8 * 1024;
pub const maximum_timeout_ms: u64 = 24 * 60 * 60 * 1_000;

pub const Method = enum {
    get,
    post,
};

/// Limits are checked before an implementation is called. Byte bounds, the
/// connect timeout, and the total timeout are non-zero. `idle_timeout_ms = 0`
/// disables idle timeout enforcement. Non-zero timeouts may not exceed the cap.
pub const Limits = struct {
    max_request_body_bytes: usize = 1024 * 1024,
    max_response_body_bytes: usize = maximum_response_body_bytes,
    max_header_bytes: usize = 16 * 1024,
    header_buffer_bytes: usize = 32 * 1024,
    connect_timeout_ms: u64 = 10_000,
    idle_timeout_ms: u64 = 30_000,
    total_timeout_ms: u64 = 60_000,
};

pub const default_limits: Limits = .{};

/// Borrowed request. Implementations may retain no request slice or tick after
/// `request` returns. `json_body`, when present, is already encoded JSON.
pub const Request = struct {
    method: Method,
    url: []const u8,
    headers: []const Header,
    json_body: ?[]const u8 = null,
    tick: ?Provider.Tick = null,
    limits: Limits = default_limits,
};

/// Owned HTTP response. The body allocation transfers to the caller and is
/// released by `deinit`. Non-success HTTP statuses are ordinary responses.
pub const Response = struct {
    status: u16,
    body: []u8,
    retry_after_ms: ?u64 = null,

    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        self.* = undefined;
    }
};

pub const Error = StreamingTransport.StreamError;

/// Erased synchronous JSON HTTP interface. Implementations receive only
/// validated borrowed input and must return an allocator-owned response body.
pub const Transport = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        request: *const fn (
            std.mem.Allocator,
            std.Io,
            *anyopaque,
            Request,
        ) Error!Response,
    };

    pub fn from(implementation: anytype) Transport {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("JsonTransport.Transport.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn requestFn(
                allocator: std.mem.Allocator,
                io: std.Io,
                context: *anyopaque,
                value: Request,
            ) Error!Response {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return Implementation.request(allocator, io, self, value);
            }

            const vtable: VTable = .{ .request = requestFn };
        };
        return .{ .context = implementation, .vtable = &Adapter.vtable };
    }

    pub fn request(
        self: Transport,
        allocator: std.mem.Allocator,
        io: std.Io,
        value: Request,
    ) Error!Response {
        try validateRequest(value);
        try poll(value.tick);

        var response = self.vtable.request(allocator, io, self.context, value) catch |err| {
            // A cancellation observed during a blocked operation is more useful
            // than the connection or timeout error that unblocked it.
            poll(value.tick) catch return error.Cancelled;
            return err;
        };
        errdefer response.deinit(allocator);

        try poll(value.tick);
        try validateResponse(response, value.limits);
        return response;
    }
};

fn poll(tick: ?Provider.Tick) error{Cancelled}!void {
    if (tick) |value| try value.poll();
}

fn validateRequest(value: Request) Error!void {
    try validateLimits(value.limits);
    if (value.url.len > maximum_url_bytes or !validUrl(value.url)) return error.InvalidRequest;
    if (value.headers.len > maximum_headers) return error.InvalidRequest;
    if (value.json_body) |body| {
        if (body.len > value.limits.max_request_body_bytes) return error.InvalidRequest;
    }

    var header_bytes: usize = 0;
    var has_privileged_header = false;
    for (value.headers, 0..) |header, index| {
        has_privileged_header = has_privileged_header or header.isPrivileged();
        if (!validHeaderName(header.name) or !validHeaderValue(header.value)) {
            return error.InvalidRequest;
        }
        for (value.headers[index + 1 ..]) |other| {
            if (std.ascii.eqlIgnoreCase(header.name, other.name)) return error.InvalidRequest;
        }
        header_bytes = std.math.add(usize, header_bytes, header.name.len) catch
            return error.InvalidRequest;
        header_bytes = std.math.add(usize, header_bytes, header.value.len) catch
            return error.InvalidRequest;
        if (header_bytes > value.limits.max_header_bytes) return error.InvalidRequest;
    }
    if (has_privileged_header and !std.mem.startsWith(u8, value.url, "https://")) {
        return error.InvalidRequest;
    }
}

fn validateLimits(limits: Limits) Error!void {
    if (limits.max_request_body_bytes == 0 or
        limits.max_request_body_bytes > maximum_request_body_bytes or
        limits.max_response_body_bytes == 0 or
        limits.max_response_body_bytes > maximum_response_body_bytes or
        limits.max_header_bytes == 0 or
        limits.max_header_bytes > maximum_header_bytes or
        limits.header_buffer_bytes == 0 or
        limits.header_buffer_bytes > maximum_header_bytes or
        limits.connect_timeout_ms == 0 or
        limits.connect_timeout_ms > maximum_timeout_ms or
        limits.idle_timeout_ms > maximum_timeout_ms or
        limits.total_timeout_ms == 0 or
        limits.total_timeout_ms > maximum_timeout_ms)
    {
        return error.InvalidRequest;
    }
}

fn validateResponse(response: Response, limits: Limits) Error!void {
    if (response.status < 100 or response.status > 599) return error.InvalidResponse;
    if (response.body.len > limits.max_response_body_bytes) return error.InvalidResponse;
    if (response.retry_after_ms) |delay| {
        if (delay > Retry.retry_after_max_ms) return error.InvalidResponse;
    }
}

fn validUrl(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| {
        if (byte <= 0x20 or byte == 0x7f or byte == '\\') return false;
    }

    const uri = std.Uri.parse(value) catch return false;
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

fn testRequest() Request {
    return .{
        .method = .get,
        .url = "https://example.test/backend-api/models?client_version=1",
        .headers = &.{.{ .name = "Accept", .value = "application/json" }},
        .limits = .{
            .max_request_body_bytes = 64,
            .max_response_body_bytes = 64,
            .max_header_bytes = 64,
            .header_buffer_bytes = 128,
            .connect_timeout_ms = 1_000,
            .idle_timeout_ms = 2_000,
        },
    };
}

test "zero idle timeout is disabled while connect timeout remains required" {
    var value = testRequest();
    value.limits.idle_timeout_ms = 0;
    try validateRequest(value);

    value.limits.connect_timeout_ms = 0;
    try std.testing.expectError(error.InvalidRequest, validateRequest(value));
}

test "erased transport dispatches method query and borrowed JSON" {
    const Fake = struct {
        const Self = @This();
        calls: usize = 0,
        saw_post: bool = false,
        saw_body: bool = false,
        saw_query: bool = false,

        fn request(
            allocator: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            value: Request,
        ) Error!Response {
            self.calls += 1;
            self.saw_post = value.method == .post;
            self.saw_body = value.json_body != null and std.mem.eql(u8, "{}", value.json_body.?);
            self.saw_query = std.mem.endsWith(u8, value.url, "?client_version=1");
            return .{ .status = 201, .body = try allocator.dupe(u8, "{\"ok\":true}") };
        }
    };

    var fake: Fake = .{};
    var value = testRequest();
    value.method = .post;
    value.json_body = "{}";
    var response = try Transport.from(&fake).request(std.testing.allocator, std.testing.io, value);
    defer response.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 201), response.status);
    try std.testing.expectEqualStrings("{\"ok\":true}", response.body);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expect(fake.saw_post);
    try std.testing.expect(fake.saw_body);
    try std.testing.expect(fake.saw_query);
}

test "request bounds URL and header injection are rejected before dispatch" {
    const Fake = struct {
        const Self = @This();
        calls: usize = 0,
        fn request(allocator: std.mem.Allocator, _: std.Io, self: *Self, _: Request) Error!Response {
            self.calls += 1;
            return .{ .status = 200, .body = try allocator.alloc(u8, 0) };
        }
    };

    var fake: Fake = .{};
    const erased = Transport.from(&fake);
    inline for (.{
        "https://user@example.test/models",
        "https://example.test/models#fragment",
        "https://example.test\\models",
        "https://example.test/models\nnext",
    }) |url| {
        var value = testRequest();
        value.url = url;
        try std.testing.expectError(error.InvalidRequest, erased.request(
            std.testing.allocator,
            std.testing.io,
            value,
        ));
    }

    var value = testRequest();
    value.headers = &.{.{ .name = "X-Test", .value = "one\r\ntwo" }};
    try std.testing.expectError(error.InvalidRequest, erased.request(
        std.testing.allocator,
        std.testing.io,
        value,
    ));
    value = testRequest();
    value.headers = &.{
        .{ .name = "X-Test", .value = "one" },
        .{ .name = "x-test", .value = "two" },
    };
    try std.testing.expectError(error.InvalidRequest, erased.request(
        std.testing.allocator,
        std.testing.io,
        value,
    ));
    value = testRequest();
    value.json_body = "body too large";
    value.limits.max_request_body_bytes = 4;
    try std.testing.expectError(error.InvalidRequest, erased.request(
        std.testing.allocator,
        std.testing.io,
        value,
    ));
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

test "privileged headers are inferred case insensitively" {
    try std.testing.expect((Header{ .name = "AUTHORIZATION", .value = "secret" }).isPrivileged());
    try std.testing.expect((Header{ .name = "Proxy-Authorization", .value = "secret" }).isPrivileged());
    try std.testing.expect((Header{ .name = "X-Secret", .value = "secret", .privileged = true }).isPrivileged());
}

test "invalid owned response is cleaned up" {
    const Fake = struct {
        const Self = @This();
        fn request(allocator: std.mem.Allocator, _: std.Io, _: *Self, _: Request) Error!Response {
            return .{ .status = 99, .body = try allocator.dupe(u8, "owned") };
        }
    };

    var fake: Fake = .{};
    try std.testing.expectError(error.InvalidResponse, Transport.from(&fake).request(
        std.testing.allocator,
        std.testing.io,
        testRequest(),
    ));
}

test "cancellation wins over a later transport error and owned response" {
    const Canceller = struct {
        const Self = @This();
        polls: usize = 0,
        pub fn poll(self: *Self) Provider.DeliveryError!void {
            self.polls += 1;
            if (self.polls > 1) return error.Cancelled;
        }
    };
    const Fails = struct {
        const Self = @This();
        fn request(_: std.mem.Allocator, _: std.Io, _: *Self, _: Request) Error!Response {
            return error.ConnectionFailed;
        }
    };
    const Returns = struct {
        const Self = @This();
        fn request(allocator: std.mem.Allocator, _: std.Io, _: *Self, _: Request) Error!Response {
            return .{ .status = 200, .body = try allocator.dupe(u8, "owned") };
        }
    };

    var canceller: Canceller = .{};
    var value = testRequest();
    value.tick = Provider.Tick.from(&canceller);
    var fails: Fails = .{};
    try std.testing.expectError(error.Cancelled, Transport.from(&fails).request(
        std.testing.allocator,
        std.testing.io,
        value,
    ));

    canceller.polls = 0;
    var returns: Returns = .{};
    try std.testing.expectError(error.Cancelled, Transport.from(&returns).request(
        std.testing.allocator,
        std.testing.io,
        value,
    ));
}

test "allocation failure is preserved" {
    const Fake = struct {
        const Self = @This();
        fn request(allocator: std.mem.Allocator, _: std.Io, _: *Self, _: Request) Error!Response {
            return .{ .status = 200, .body = try allocator.dupe(u8, "body") };
        }
    };

    var fake: Fake = .{};
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, Transport.from(&fake).request(
        failing.allocator(),
        std.testing.io,
        testRequest(),
    ));
}

test "response bounds retry delay and expected HTTP failures" {
    const Fake = struct {
        const Self = @This();
        status: u16 = 429,
        retry_after_ms: ?u64 = 1_000,
        fn request(allocator: std.mem.Allocator, _: std.Io, self: *Self, _: Request) Error!Response {
            return .{
                .status = self.status,
                .body = try allocator.dupe(u8, "slow down"),
                .retry_after_ms = self.retry_after_ms,
            };
        }
    };

    var fake: Fake = .{};
    var response = try Transport.from(&fake).request(
        std.testing.allocator,
        std.testing.io,
        testRequest(),
    );
    response.deinit(std.testing.allocator);

    var value = testRequest();
    value.limits.max_response_body_bytes = 4;
    try std.testing.expectError(error.InvalidResponse, Transport.from(&fake).request(
        std.testing.allocator,
        std.testing.io,
        value,
    ));
    fake.retry_after_ms = Retry.retry_after_max_ms + 1;
    value.limits.max_response_body_bytes = 64;
    try std.testing.expectError(error.InvalidResponse, Transport.from(&fake).request(
        std.testing.allocator,
        std.testing.io,
        value,
    ));
}

test "privileged headers require HTTPS and URLs are bounded" {
    const Fake = struct {
        const Self = @This();

        fn request(
            allocator: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            _: Request,
        ) Error!Response {
            return .{ .status = 200, .body = try allocator.dupe(u8, "{}") };
        }
    };
    var transport: Fake = .{};
    const erased = Transport.from(&transport);
    var request_value = testRequest();
    request_value.url = "http://example.test/models";
    request_value.headers = &.{.{ .name = "Authorization", .value = "Bearer secret" }};
    try std.testing.expectError(error.InvalidRequest, erased.request(
        std.testing.allocator,
        std.testing.io,
        request_value,
    ));

    request_value.headers = &.{.{ .name = "Accept", .value = "application/json" }};
    var response = try erased.request(std.testing.allocator, std.testing.io, request_value);
    response.deinit(std.testing.allocator);

    const oversized_url = "https://example.test/" ++ ("x" ** maximum_url_bytes);
    request_value.url = oversized_url;
    try std.testing.expectError(error.InvalidRequest, erased.request(
        std.testing.allocator,
        std.testing.io,
        request_value,
    ));
}
