const std = @import("std");
const transport_api = @import("../transport.zig");

pub const Exchange = union(enum) {
    response: struct {
        status: u16,
        body: []const u8,
        chunk_bytes: usize = 0,
        metadata: transport_api.ResponseMetadata = .{},
    },
    failure: transport_api.Error,
};

pub const Inspector = struct {
    context: *anyopaque,
    inspect_fn: *const fn (*anyopaque, transport_api.Request) error{Rejected}!void,

    pub fn inspect(self: Inspector, request: transport_api.Request) error{Rejected}!void {
        return self.inspect_fn(self.context, request);
    }
};

pub const FakeTransport = struct {
    exchanges: []const Exchange,
    inspector: ?Inspector = null,
    next_index: usize = 0,

    pub fn init(exchanges: []const Exchange) FakeTransport {
        return .{ .exchanges = exchanges };
    }

    pub fn transport(self: *FakeTransport) transport_api.Transport {
        return transport_api.Transport.from(self);
    }

    pub fn exchange(
        self: *FakeTransport,
        allocator: std.mem.Allocator,
        _: std.Io,
        request: transport_api.Request,
        delivery: transport_api.Delivery,
    ) transport_api.Error!transport_api.Response {
        if (self.inspector) |inspector| inspector.inspect(request) catch return error.InvalidResponse;
        if (self.next_index >= self.exchanges.len) return error.InvalidResponse;
        const exchange_value = self.exchanges[self.next_index];
        self.next_index += 1;
        return switch (exchange_value) {
            .failure => |failure| failure,
            .response => |response| switch (delivery) {
                .buffered => .{
                    .status = response.status,
                    .body = allocator.dupe(u8, response.body) catch return error.OutOfMemory,
                    .metadata = response.metadata,
                },
                .streaming => |sink| streaming: {
                    sink.start(.{ .status = response.status, .metadata = response.metadata }) catch |failure| {
                        return sinkError(failure);
                    };
                    const chunk_bytes = if (response.chunk_bytes == 0) response.body.len else response.chunk_bytes;
                    var offset: usize = 0;
                    while (offset < response.body.len) {
                        const end = @min(response.body.len, offset + chunk_bytes);
                        sink.chunk(response.body[offset..end]) catch |failure| return sinkError(failure);
                        offset = end;
                    }
                    break :streaming .{ .status = response.status, .body = "", .metadata = response.metadata };
                },
            },
        };
    }
};

fn sinkError(failure: transport_api.SinkError) transport_api.Error {
    return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        error.Cancelled => error.Cancelled,
        error.ConsumerStopped => error.ConsumerStopped,
    };
}

test "fake transport streams configured chunks through the production seam" {
    const Context = struct {
        const Self = @This();
        body_seen: bool = false,

        fn inspect(context: *anyopaque, request: transport_api.Request) error{Rejected}!void {
            const self: *Self = @ptrCast(@alignCast(context));
            if (!std.mem.eql(u8, request.body, "request")) return error.Rejected;
            self.body_seen = true;
        }
    };
    const Sink = struct {
        const Self = @This();
        bytes: std.ArrayList(u8) = .empty,

        fn start(_: *anyopaque, head: transport_api.ResponseHead) transport_api.SinkError!void {
            if (head.status != 200) return error.ConsumerStopped;
        }

        fn chunk(context: *anyopaque, bytes: []const u8) transport_api.SinkError!void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.bytes.appendSlice(std.testing.allocator, bytes) catch return error.OutOfMemory;
        }
    };

    var context: Context = .{};
    const exchanges = [_]Exchange{.{ .response = .{ .status = 200, .body = "response", .chunk_bytes = 2 } }};
    var fake = FakeTransport.init(&exchanges);
    fake.inspector = .{ .context = &context, .inspect_fn = Context.inspect };
    var sink: Sink = .{};
    defer sink.bytes.deinit(std.testing.allocator);

    const response = try fake.transport().exchange(
        std.testing.allocator,
        std.testing.io,
        .{ .method = .POST, .url = "https://example.test", .body = "request" },
        .{ .streaming = .{ .context = &sink, .start_fn = Sink.start, .chunk_fn = Sink.chunk } },
    );

    try std.testing.expect(context.body_seen);
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("response", sink.bytes.items);
}
