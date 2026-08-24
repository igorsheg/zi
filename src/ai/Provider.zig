const std = @import("std");
const Item = @import("Item.zig").Item;
const StreamEvent = @import("StreamEvent.zig").StreamEvent;

pub const ToolParameter = struct {
    name: []const u8,
    type: enum { string, integer, boolean, array },
    item_type: ?enum { string, integer, boolean } = null,
    description: []const u8,
    required: bool = false,
    /// Zero is omitted on the wire, matching hax's schema subset.
    minimum: i64 = 0,
};

pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    parameters: []const ToolParameter,
};

pub const ImageInput = enum {
    unknown,
    supported,
    unsupported,
};

/// Borrowed provider request context. Providers may regroup items for their wire
/// protocol, but they may not retain any slice after `stream` returns.
pub const Context = struct {
    system_prompt: []const u8,
    items: []const Item,
    tools: []const ToolDefinition,
    effort: ?[]const u8 = null,
    image_input: ImageInput = .unknown,
};

pub const DeliveryError = error{Cancelled};

/// Independent cancellation hook for stalled or non-emitting transfers.
/// The pointed-to implementation must outlive the request.
pub const Tick = struct {
    context: *anyopaque,
    poll_fn: *const fn (*anyopaque) DeliveryError!void,

    pub fn poll(self: Tick) DeliveryError!void {
        return self.poll_fn(self.context);
    }

    pub fn from(implementation: anytype) Tick {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("Tick.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn poll(context: *anyopaque) DeliveryError!void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.poll();
            }
        };
        return .{ .context = implementation, .poll_fn = Adapter.poll };
    }
};

pub const Request = struct {
    model: []const u8,
    context: Context,
    tick: ?Tick = null,
};

/// Synchronous sink for borrowed stream events. The implementation must outlive
/// every copied handle. Event payloads are valid only for the `emit` call.
pub const EventSink = struct {
    context: *anyopaque,
    emit_fn: *const fn (*anyopaque, StreamEvent) DeliveryError!void,

    pub fn emit(self: EventSink, event: StreamEvent) DeliveryError!void {
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
            fn emit(context: *anyopaque, event: StreamEvent) DeliveryError!void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.emit(event);
            }
        };
        return .{ .context = implementation, .emit_fn = Adapter.emit };
    }
};

pub const StreamError = error{
    OutOfMemory,
    Cancelled,
    TimedOut,
    InvalidRequest,
    ProviderUnavailable,
    ProviderRejectedRequest,
    InvalidProviderResponse,
};

/// Erased provider interface. Implementations own protocol and transport quirks.
/// The implementation and borrowed `id` must outlive every copied handle and call.
pub const Provider = struct {
    context: *anyopaque,
    vtable: *const VTable,
    id: []const u8,

    pub const VTable = struct {
        stream: *const fn (
            std.mem.Allocator,
            std.Io,
            *anyopaque,
            Request,
            EventSink,
        ) StreamError!void,
    };

    pub fn from(implementation: anytype, id: []const u8) Provider {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("Provider.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn streamFn(
                allocator: std.mem.Allocator,
                io: std.Io,
                context: *anyopaque,
                request: Request,
                sink: EventSink,
            ) StreamError!void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return Implementation.stream(allocator, io, self, request, sink);
            }

            const vtable: VTable = .{ .stream = streamFn };
        };
        return .{ .context = implementation, .vtable = &Adapter.vtable, .id = id };
    }

    pub fn stream(
        self: Provider,
        allocator: std.mem.Allocator,
        io: std.Io,
        request: Request,
        sink: EventSink,
    ) StreamError!void {
        return self.vtable.stream(allocator, io, self.context, request, sink);
    }
};

test "erased provider delivers borrowed events synchronously" {
    const Fake = struct {
        const Self = @This();

        fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            request: Request,
            sink: EventSink,
        ) StreamError!void {
            if (!std.mem.eql(u8, "model", request.model)) return error.InvalidRequest;
            if (request.tick) |tick| try tick.poll();
            var stack_bytes = [_]u8{ 'o', 'k' };
            try sink.emit(.{ .text_delta = &stack_bytes });
            stack_bytes = .{ 'x', 'x' };
            try sink.emit(.{ .done = .{} });
        }
    };
    const Collector = struct {
        const Self = @This();

        bytes: [2]u8 = undefined,
        done: bool = false,

        fn emit(self: *Self, event: StreamEvent) DeliveryError!void {
            switch (event) {
                .text_delta => |delta| @memcpy(&self.bytes, delta),
                .done => self.done = true,
                else => {},
            }
        }
    };

    const Ticker = struct {
        const Self = @This();

        polls: usize = 0,

        fn poll(self: *Self) DeliveryError!void {
            self.polls += 1;
        }
    };

    var fake: Fake = .{};
    var collector: Collector = .{};
    var ticker: Ticker = .{};
    const erased = Provider.from(&fake, "fake");
    try erased.stream(std.testing.allocator, std.testing.io, .{
        .model = "model",
        .context = .{ .system_prompt = "system", .items = &.{}, .tools = &.{} },
        .tick = Tick.from(&ticker),
    }, EventSink.from(&collector));
    try std.testing.expectEqualStrings("ok", &collector.bytes);
    try std.testing.expect(collector.done);
    try std.testing.expectEqual(@as(usize, 1), ticker.polls);
}

test "tick cancellation aborts before event delivery" {
    const Fake = struct {
        const Self = @This();

        fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            request: Request,
            sink: EventSink,
        ) StreamError!void {
            try request.tick.?.poll();
            try sink.emit(.{ .done = .{} });
        }
    };
    const Canceller = struct {
        const Self = @This();

        fn poll(_: *Self) DeliveryError!void {
            return error.Cancelled;
        }
    };
    const Collector = struct {
        const Self = @This();
        delivered: bool = false,

        fn emit(self: *Self, _: StreamEvent) DeliveryError!void {
            self.delivered = true;
        }
    };

    var fake: Fake = .{};
    var canceller: Canceller = .{};
    var collector: Collector = .{};
    try std.testing.expectError(error.Cancelled, Provider.from(&fake, "fake").stream(
        std.testing.allocator,
        std.testing.io,
        .{
            .model = "model",
            .context = .{ .system_prompt = "system", .items = &.{}, .tools = &.{} },
            .tick = Tick.from(&canceller),
        },
        EventSink.from(&collector),
    ));
    try std.testing.expect(!collector.delivered);
}

test "sink cancellation stops provider delivery" {
    const Fake = struct {
        const Self = @This();

        fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            _: Request,
            sink: EventSink,
        ) StreamError!void {
            try sink.emit(.{ .text_delta = "stop" });
            try sink.emit(.{ .done = .{} });
        }
    };
    const CancellingSink = struct {
        const Self = @This();
        deliveries: usize = 0,

        fn emit(self: *Self, _: StreamEvent) DeliveryError!void {
            self.deliveries += 1;
            return error.Cancelled;
        }
    };

    var fake: Fake = .{};
    var sink: CancellingSink = .{};
    try std.testing.expectError(error.Cancelled, Provider.from(&fake, "fake").stream(
        std.testing.allocator,
        std.testing.io,
        .{
            .model = "model",
            .context = .{ .system_prompt = "system", .items = &.{}, .tools = &.{} },
        },
        EventSink.from(&sink),
    ));
    try std.testing.expectEqual(@as(usize, 1), sink.deliveries);
}
