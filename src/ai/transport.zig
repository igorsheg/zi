const std = @import("std");
const model = @import("model.zig");

pub const Header = struct {
    name: []const u8,
    value: []const u8,
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

pub const ResponseHead = struct {
    status: u16,
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
};

pub const Error = error{
    OutOfMemory,
    Cancelled,
    TimedOut,
    InvalidUrl,
    ConnectionFailed,
    InvalidResponse,
    ResponseTooLarge,
    ConsumerStopped,
};

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
                .content_type = .{ .override = "application/json" },
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
            },
            .streaming => |sink| streaming: {
                sink.start(.{ .status = status }) catch |failure| return sinkFailure(failure);
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
                break :streaming .{ .status = status, .body = "" };
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
