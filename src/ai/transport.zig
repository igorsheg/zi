const std = @import("std");
const model = @import("model.zig");

pub const Header = struct {
    name: []const u8,
    value: []const u8,
    sensitive: bool = false,

    pub fn isSensitive(self: Header) bool {
        return self.sensitive or isSensitiveHeaderName(self.name);
    }

    pub fn redactedValue(self: Header) []const u8 {
        return if (self.isSensitive()) "[redacted]" else self.value;
    }
};

pub const HeaderList = struct {
    allocator: std.mem.Allocator,
    values: std.ArrayList(Header) = .empty,

    pub fn init(allocator: std.mem.Allocator) HeaderList {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *HeaderList) void {
        self.values.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn append(self: *HeaderList, header: Header) error{ OutOfMemory, InvalidHeader, HeaderConflict }!void {
        try validateHeader(header);
        for (self.values.items) |existing| {
            if (std.ascii.eqlIgnoreCase(existing.name, header.name)) return error.HeaderConflict;
        }
        try self.values.append(self.allocator, header);
    }

    pub fn appendSlice(
        self: *HeaderList,
        headers: []const Header,
    ) error{ OutOfMemory, InvalidHeader, HeaderConflict }!void {
        for (headers) |header| try self.append(header);
    }

    pub fn items(self: *const HeaderList) []const Header {
        return self.values.items;
    }
};

pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
};

pub const Request = struct {
    method: Method,
    url: []const u8,
    headers: []const Header = &.{},
    body: []const u8 = "",
    max_response_bytes: usize = 8 * 1024 * 1024,
    deadline: ?std.Io.Clock.Timestamp = null,
    cancellation: ?*const model.CancellationToken = null,
};

pub const MetadataText = struct {
    pub const max_bytes = 256;

    buffer: [max_bytes]u8 = [_]u8{0} ** max_bytes,
    length: u16 = 0,

    pub fn init(value: []const u8) ?MetadataText {
        if (value.len == 0 or value.len > max_bytes) return null;
        var result: MetadataText = .{};
        @memcpy(result.buffer[0..value.len], value);
        result.length = @intCast(value.len);
        return result;
    }

    pub fn slice(self: *const MetadataText) []const u8 {
        return self.buffer[0..self.length];
    }
};

pub const ResponseMetadata = struct {
    request_id: ?MetadataText = null,
    retry_after_ms: ?u64 = null,
};

pub const ResponseHead = struct {
    status: u16,
    metadata: ResponseMetadata = .{},
};

pub const BodySink = struct {
    context: *anyopaque,
    start_fn: *const fn (*anyopaque, ResponseHead) SinkError!void,
    chunk_fn: *const fn (*anyopaque, []const u8) SinkError!void,

    pub fn start(self: BodySink, head: ResponseHead) SinkError!void {
        return self.start_fn(self.context, head);
    }

    pub fn chunk(self: BodySink, bytes: []const u8) SinkError!void {
        return self.chunk_fn(self.context, bytes);
    }
};

pub const SinkError = error{
    OutOfMemory,
    Cancelled,
    ConsumerStopped,
};

pub const Delivery = union(enum) {
    buffered,
    streaming: BodySink,
};

pub const Response = struct {
    status: u16,
    body: []const u8,
    metadata: ResponseMetadata = .{},
};

pub const Error = error{
    OutOfMemory,
    Cancelled,
    TimedOut,
    InvalidUrl,
    InvalidRequest,
    ConnectionFailed,
    InvalidResponse,
    ResponseTooLarge,
    ConsumerStopped,
};

pub fn validateExtraHeaders(headers: []const Header) error{InvalidRequest}!void {
    try validateHeaders(headers);
    const reserved = [_][]const u8{
        "authorization",
        "proxy-authorization",
        "content-type",
        "accept",
        "x-api-key",
        "api-key",
        "x-goog-api-key",
        "chatgpt-account-id",
        "openai-beta",
    };
    for (headers) |header| for (reserved) |name| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return error.InvalidRequest;
    };
}

fn validateRequest(request: Request) error{InvalidRequest}!void {
    return validateHeaders(request.headers);
}

fn validateHeaders(headers: []const Header) error{InvalidRequest}!void {
    for (headers, 0..) |header, index| {
        validateHeader(header) catch return error.InvalidRequest;
        for (headers[index + 1 ..]) |other| {
            if (std.ascii.eqlIgnoreCase(header.name, other.name)) return error.InvalidRequest;
        }
    }
}

fn validateHeader(header: Header) error{InvalidHeader}!void {
    if (header.name.len == 0) return error.InvalidHeader;
    for (header.name) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or
            std.mem.findScalar(u8, "!#$%&'*+-.^_`|~", byte) != null)) return error.InvalidHeader;
    }
    for (header.value) |byte| if (byte == '\r' or byte == '\n' or byte == 0) return error.InvalidHeader;
    const transport_owned = [_][]const u8{
        "content-length",
        "host",
        "connection",
        "transfer-encoding",
        "accept-encoding",
    };
    for (transport_owned) |name| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return error.InvalidHeader;
    }
}

fn isSensitiveHeaderName(name: []const u8) bool {
    const sensitive = [_][]const u8{
        "authorization",
        "proxy-authorization",
        "x-api-key",
        "api-key",
        "x-goog-api-key",
        "cookie",
        "set-cookie",
    };
    for (sensitive) |candidate| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    }
    return false;
}

pub const Transport = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        exchange: *const fn (
            allocator: std.mem.Allocator,
            io: std.Io,
            context: *anyopaque,
            request: Request,
            delivery: Delivery,
        ) Error!Response,
    };

    pub fn exchange(
        self: Transport,
        allocator: std.mem.Allocator,
        io: std.Io,
        request: Request,
        delivery: Delivery,
    ) Error!Response {
        try validateRequest(request);
        return self.vtable.exchange(allocator, io, self.context, request, delivery);
    }

    pub fn from(implementation: anytype) Transport {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        comptime {
            if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
                @compileError("Transport.from expects a single-item pointer");
            }
        }

        const Adapter = struct {
            fn exchangeFn(
                allocator: std.mem.Allocator,
                io: std.Io,
                context: *anyopaque,
                request: Request,
                delivery: Delivery,
            ) Error!Response {
                const self: Pointer = @ptrCast(@alignCast(context));
                return self.exchange(allocator, io, request, delivery);
            }

            const vtable: VTable = .{ .exchange = exchangeFn };
        };

        return .{ .context = implementation, .vtable = &Adapter.vtable };
    }
};

pub const HttpTransport = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) HttpTransport {
        return .{ .allocator = allocator };
    }

    pub fn transport(self: *HttpTransport) Transport {
        return Transport.from(self);
    }

    pub fn exchange(
        self: *HttpTransport,
        allocator: std.mem.Allocator,
        io: std.Io,
        request_value: Request,
        delivery: Delivery,
    ) Error!Response {
        if (request_value.cancellation) |token| if (token.isCancelled()) return error.Cancelled;
        if (request_value.deadline) |deadline| {
            const now = std.Io.Clock.Timestamp.now(io, deadline.clock);
            if (now.durationTo(deadline).raw.nanoseconds <= 0) return error.TimedOut;
        }
        if (request_value.deadline == null and request_value.cancellation == null) {
            return self.exchangeDirect(allocator, io, request_value, delivery);
        }
        return controlledExchange(allocator, io, self, request_value, delivery);
    }

    fn exchangeDirect(
        self: *HttpTransport,
        allocator: std.mem.Allocator,
        io: std.Io,
        request_value: Request,
        delivery: Delivery,
    ) Error!Response {
        const uri = std.Uri.parse(request_value.url) catch return error.InvalidUrl;
        var client: std.http.Client = .{ .allocator = self.allocator, .io = io };
        defer client.deinit();

        var headers: std.ArrayList(std.http.Header) = .empty;
        defer headers.deinit(allocator);
        for (request_value.headers) |header| {
            headers.append(allocator, .{ .name = header.name, .value = header.value }) catch return error.OutOfMemory;
        }

        var http_request = client.request(httpMethod(request_value.method), uri, .{
            .redirect_behavior = .unhandled,
            .headers = .{
                .accept_encoding = .omit,
            },
            .extra_headers = headers.items,
        }) catch return error.ConnectionFailed;
        defer http_request.deinit();

        if (request_value.body.len == 0) {
            http_request.sendBodiless() catch return error.ConnectionFailed;
        } else {
            http_request.transfer_encoding = .{ .content_length = request_value.body.len };
            var request_body = http_request.sendBodyUnflushed(&.{}) catch return error.ConnectionFailed;
            request_body.writer.writeAll(request_value.body) catch return error.ConnectionFailed;
            request_body.end() catch return error.ConnectionFailed;
            http_request.connection.?.flush() catch return error.ConnectionFailed;
        }

        var response = http_request.receiveHead(&.{}) catch return error.InvalidResponse;
        const status: u16 = @intFromEnum(response.head.status);
        const metadata = responseMetadata(response.head);
        var transfer_buffer: [64 * 1024]u8 = undefined;
        const reader = response.reader(&transfer_buffer);

        return switch (delivery) {
            .buffered => .{
                .status = status,
                .body = readBounded(
                    allocator,
                    reader,
                    request_value.max_response_bytes,
                ) catch |failure| switch (failure) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.StreamTooLong => return error.ResponseTooLarge,
                    else => return error.InvalidResponse,
                },
                .metadata = metadata,
            },
            .streaming => |sink| streaming: {
                sink.start(.{ .status = status, .metadata = metadata }) catch |failure| return sinkFailure(failure);
                var chunk_buffer: [16 * 1024]u8 = undefined;
                var received: usize = 0;
                while (true) {
                    if (request_value.cancellation) |token| if (token.isCancelled()) return error.Cancelled;
                    var chunk_writer: std.Io.Writer = .fixed(&chunk_buffer);
                    const count = reader.stream(
                        &chunk_writer,
                        .limited(chunk_buffer.len),
                    ) catch |read_failure| switch (read_failure) {
                        error.EndOfStream => break,
                        else => return error.InvalidResponse,
                    };
                    if (count == 0) continue;
                    received = std.math.add(usize, received, count) catch return error.ResponseTooLarge;
                    if (received > request_value.max_response_bytes) return error.ResponseTooLarge;
                    sink.chunk(chunk_buffer[0..count]) catch |failure| return sinkFailure(failure);
                }
                break :streaming .{ .status = status, .body = "", .metadata = metadata };
            },
        };
    }
};

const ExchangeOutcome = union(enum) {
    response: Error!Response,
    deadline: std.Io.Cancelable!void,
    cancelled: std.Io.Cancelable!void,
};

fn controlledExchange(
    allocator: std.mem.Allocator,
    io: std.Io,
    transport: *HttpTransport,
    request: Request,
    delivery: Delivery,
) Error!Response {
    var outcomes: [3]ExchangeOutcome = undefined;
    var select: std.Io.Select(ExchangeOutcome) = .init(io, &outcomes);
    defer drainExchange(allocator, &select);
    select.concurrent(.response, HttpTransport.exchangeDirect, .{
        transport,
        allocator,
        io,
        request,
        delivery,
    }) catch return error.ConnectionFailed;
    if (request.deadline) |deadline| {
        select.concurrent(.deadline, waitForDeadline, .{ io, deadline }) catch return error.ConnectionFailed;
    }
    if (request.cancellation) |token| {
        select.concurrent(.cancelled, waitForCancellation, .{ io, token }) catch return error.ConnectionFailed;
    }
    const outcome = select.await() catch return error.Cancelled;
    return switch (outcome) {
        .response => |response| response,
        .deadline => |result| deadline: {
            result catch return error.Cancelled;
            break :deadline error.TimedOut;
        },
        .cancelled => |result| cancelled: {
            result catch return error.Cancelled;
            break :cancelled error.Cancelled;
        },
    };
}

fn waitForDeadline(io: std.Io, deadline: std.Io.Clock.Timestamp) std.Io.Cancelable!void {
    return deadline.wait(io);
}

fn waitForCancellation(io: std.Io, token: *const model.CancellationToken) std.Io.Cancelable!void {
    const poll: std.Io.Timeout = .{ .duration = .{
        .raw = .fromMilliseconds(5),
        .clock = .awake,
    } };
    while (!token.isCancelled()) try poll.sleep(io);
}

fn drainExchange(allocator: std.mem.Allocator, select: *std.Io.Select(ExchangeOutcome)) void {
    while (select.cancel()) |outcome| switch (outcome) {
        .response => |result| if (result) |response| {
            if (response.body.len > 0) allocator.free(response.body);
        } else |_| {},
        .deadline, .cancelled => {},
    };
}

fn httpMethod(method: Method) std.http.Method {
    return switch (method) {
        .GET => .GET,
        .POST => .POST,
        .PUT => .PUT,
        .DELETE => .DELETE,
    };
}

fn responseMetadata(head: std.http.Client.Response.Head) ResponseMetadata {
    var metadata: ResponseMetadata = .{};
    var iterator = head.iterateHeaders();
    while (iterator.next()) |header| {
        if (metadata.request_id == null and isRequestIdHeader(header.name)) {
            metadata.request_id = MetadataText.init(header.value);
        }
        if (metadata.retry_after_ms == null and std.ascii.eqlIgnoreCase(header.name, "retry-after")) {
            const seconds = std.fmt.parseInt(u64, std.mem.trim(u8, header.value, " \t"), 10) catch continue;
            metadata.retry_after_ms = std.math.mul(u64, seconds, 1000) catch std.math.maxInt(u64);
        }
    }
    return metadata;
}

fn isRequestIdHeader(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "x-request-id") or
        std.ascii.eqlIgnoreCase(name, "request-id") or
        std.ascii.eqlIgnoreCase(name, "openai-request-id");
}

fn readBounded(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    maximum_bytes: usize,
) (std.mem.Allocator.Error || std.Io.Reader.Error || error{StreamTooLong})![]u8 {
    const limit = std.math.add(usize, maximum_bytes, 1) catch return error.StreamTooLong;
    const body = try reader.allocRemaining(allocator, .limited(limit));
    if (body.len > maximum_bytes) {
        allocator.free(body);
        return error.StreamTooLong;
    }
    return body;
}

fn sinkFailure(failure: SinkError) Error {
    return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        error.Cancelled => error.Cancelled,
        error.ConsumerStopped => error.ConsumerStopped,
    };
}

test "header composition rejects invalid and duplicate wire names" {
    var headers = HeaderList.init(std.testing.allocator);
    defer headers.deinit();
    try headers.append(.{ .name = "content-type", .value = "application/json" });
    try headers.append(.{ .name = "authorization", .value = "Bearer secret" });
    try std.testing.expectError(error.HeaderConflict, headers.append(.{
        .name = "Content-Type",
        .value = "text/plain",
    }));
    try std.testing.expectError(error.InvalidHeader, headers.append(.{
        .name = "content-length",
        .value = "1",
    }));
    try std.testing.expectEqualStrings("[redacted]", headers.items()[1].redactedValue());
    try std.testing.expectEqualStrings("application/json", headers.items()[0].redactedValue());
    try std.testing.expectEqualStrings("[redacted]", (Header{
        .name = "x-private",
        .value = "secret",
        .sensitive = true,
    }).redactedValue());
    try validateExtraHeaders(&.{.{ .name = "x-feature", .value = "enabled" }});
    try std.testing.expectError(error.InvalidRequest, validateExtraHeaders(&.{.{
        .name = "content-type",
        .value = "text/plain",
    }}));
}

test "transport seam rejects duplicate and unsafe headers before adapters" {
    const Adapter = struct {
        const Self = @This();

        called: bool = false,

        pub fn exchange(
            self: *Self,
            _: std.mem.Allocator,
            _: std.Io,
            _: Request,
            _: Delivery,
        ) Error!Response {
            self.called = true;
            return error.ConnectionFailed;
        }
    };
    var adapter: Adapter = .{};
    const transport = Transport.from(&adapter);
    try std.testing.expectError(error.InvalidRequest, transport.exchange(
        std.testing.allocator,
        std.testing.io,
        .{
            .method = .POST,
            .url = "https://example.test",
            .headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        },
        .buffered,
    ));
    try std.testing.expectError(error.InvalidRequest, transport.exchange(
        std.testing.allocator,
        std.testing.io,
        .{
            .method = .POST,
            .url = "https://example.test",
            .headers = &.{.{ .name = "x-value", .value = "unsafe\r\nheader" }},
        },
        .buffered,
    ));
    try std.testing.expect(!adapter.called);
}

test "HTTP transport emits each composed singleton header exactly once" {
    const Fixture = struct {
        const Self = @This();

        content_type_count: usize = 0,
        authorization_count: usize = 0,

        fn serve(self: *Self, io: std.Io, server: *std.Io.net.Server) !void {
            var stream = try server.accept(io);
            defer stream.close(io);
            var read_buffer: [4096]u8 = undefined;
            var stream_reader = std.Io.net.Stream.Reader.init(stream, io, &read_buffer);
            while (true) {
                const line = stream_reader.interface.takeDelimiterInclusive('\n') catch |failure| switch (failure) {
                    error.EndOfStream => break,
                    else => return failure,
                };
                if (std.mem.eql(u8, line, "\r\n")) break;
                const separator = std.mem.findScalar(u8, line, ':') orelse continue;
                const name = std.mem.trim(u8, line[0..separator], " \t\r\n");
                if (std.ascii.eqlIgnoreCase(name, "content-type")) self.content_type_count += 1;
                if (std.ascii.eqlIgnoreCase(name, "authorization")) self.authorization_count += 1;
            }
            var write_buffer: [256]u8 = undefined;
            var stream_writer = std.Io.net.Stream.Writer.init(stream, io, &write_buffer);
            try stream_writer.interface.writeAll(
                "HTTP/1.1 200 OK\r\n" ++
                    "Content-Length: 2\r\n" ++
                    "X-Request-Id: request-123\r\n" ++
                    "Retry-After: 3\r\n\r\n{}",
            );
            try stream_writer.interface.flush();
        }
    };

    const io = std.testing.io;
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var fixture: Fixture = .{};
    var server_future = io.async(Fixture.serve, .{ &fixture, io, &server });
    defer server_future.cancel(io) catch |failure| {
        std.debug.panic("loopback server cancellation failed: {s}", .{@errorName(failure)});
    };
    var url_buffer: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(
        &url_buffer,
        "http://127.0.0.1:{d}/test",
        .{server.socket.address.getPort()},
    );
    var http = HttpTransport.init(std.testing.allocator);
    const response = try http.transport().exchange(std.testing.allocator, io, .{
        .method = .POST,
        .url = url,
        .headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "authorization", .value = "Bearer test", .sensitive = true },
        },
        .body = "{}",
    }, .buffered);
    defer std.testing.allocator.free(response.body);
    try server_future.await(io);
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqual(@as(usize, 1), fixture.content_type_count);
    try std.testing.expectEqual(@as(usize, 1), fixture.authorization_count);
    try std.testing.expectEqualStrings("request-123", response.metadata.request_id.?.slice());
    try std.testing.expectEqual(@as(?u64, 3000), response.metadata.retry_after_ms);
}

test "HTTP transport rejects cancelled and expired requests before network I/O" {
    var http = HttpTransport.init(std.testing.allocator);
    var cancellation: model.CancellationToken = .{};
    cancellation.cancel();
    try std.testing.expectError(error.Cancelled, http.transport().exchange(
        std.testing.allocator,
        std.testing.io,
        .{
            .method = .POST,
            .url = "not a URL",
            .cancellation = &cancellation,
        },
        .buffered,
    ));

    const deadline = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    try std.testing.expectError(error.TimedOut, http.transport().exchange(
        std.testing.allocator,
        std.testing.io,
        .{
            .method = .POST,
            .url = "not a URL",
            .deadline = deadline,
        },
        .buffered,
    ));
}
