const std = @import("std");
const message = @import("message.zig");
const usage = @import("usage.zig");

pub const StreamSinkError = error{
    OutOfMemory,
    Cancelled,
    ConsumerStopped,
};

pub const ToolCallStart = struct {
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
};

pub const ResponsePartStart = union(enum) {
    text,
    thinking,
    tool_call: ToolCallStart,
};

pub const PartStart = struct {
    index: usize,
    part: ResponsePartStart,
};

pub const ToolCallDelta = struct {
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    arguments_delta: []const u8 = "",
};

pub const ResponsePartDelta = union(enum) {
    text: []const u8,
    thinking: []const u8,
    tool_call: ToolCallDelta,
};

pub const PartDelta = struct {
    index: usize,
    delta: ResponsePartDelta,
};

pub const PartEnd = struct {
    index: usize,
    part: message.ResponsePart,
};

pub const StreamEvent = union(enum) {
    part_start: PartStart,
    part_delta: PartDelta,
    part_end: PartEnd,
    usage: usage.Usage,
};

pub const StreamSink = struct {
    context: *anyopaque,
    emitFn: *const fn (context: *anyopaque, event: StreamEvent) StreamSinkError!void,

    pub fn emit(self: StreamSink, event: StreamEvent) StreamSinkError!void {
        return self.emitFn(self.context, event);
    }
};

pub const PartialToolCall = struct {
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    arguments_json: []const u8 = "",
};

pub const ResponsePartSnapshot = union(enum) {
    text: []const u8,
    thinking: []const u8,
    tool_call: PartialToolCall,
};

/// A complete borrowed view of a response while it is streaming.
/// The view remains valid until the accumulator is mutated or deinitialized.
pub const ResponseSnapshot = struct {
    parts: []const ResponsePartSnapshot,
    identity: message.ModelIdentity,
    usage: usage.Usage = .{},
};

pub fn copySnapshotLeaky(
    allocator: std.mem.Allocator,
    source: ResponseSnapshot,
) error{OutOfMemory}!ResponseSnapshot {
    const parts = try allocator.alloc(ResponsePartSnapshot, source.parts.len);
    for (source.parts, parts) |part, *copy| copy.* = switch (part) {
        .text => |text| .{ .text = try allocator.dupe(u8, text) },
        .thinking => |thinking| .{ .thinking = try allocator.dupe(u8, thinking) },
        .tool_call => |call| .{ .tool_call = .{
            .id = if (call.id) |id| try allocator.dupe(u8, id) else null,
            .name = if (call.name) |name| try allocator.dupe(u8, name) else null,
            .arguments_json = try allocator.dupe(u8, call.arguments_json),
        } },
    };
    return .{
        .parts = parts,
        .identity = try message.copyIdentityLeaky(allocator, source.identity),
        .usage = source.usage,
    };
}

pub fn copyEventLeaky(
    allocator: std.mem.Allocator,
    source: StreamEvent,
) error{OutOfMemory}!StreamEvent {
    return switch (source) {
        .part_start => |start| .{ .part_start = .{
            .index = start.index,
            .part = switch (start.part) {
                .text => .text,
                .thinking => .thinking,
                .tool_call => |call| .{ .tool_call = .{
                    .id = if (call.id) |id| try allocator.dupe(u8, id) else null,
                    .name = if (call.name) |name| try allocator.dupe(u8, name) else null,
                } },
            },
        } },
        .part_delta => |delta| .{ .part_delta = .{
            .index = delta.index,
            .delta = switch (delta.delta) {
                .text => |text| .{ .text = try allocator.dupe(u8, text) },
                .thinking => |thinking| .{ .thinking = try allocator.dupe(u8, thinking) },
                .tool_call => |call| .{ .tool_call = .{
                    .id = if (call.id) |id| try allocator.dupe(u8, id) else null,
                    .name = if (call.name) |name| try allocator.dupe(u8, name) else null,
                    .arguments_delta = try allocator.dupe(u8, call.arguments_delta),
                } },
            },
        } },
        .part_end => |end| .{ .part_end = .{
            .index = end.index,
            .part = try message.copyResponsePartLeaky(allocator, end.part),
        } },
        .usage => |value| .{ .usage = value },
    };
}

pub const AccumulatorError = error{
    OutOfMemory,
    InvalidStream,
};

/// Reduces normalized stream events into a complete partial response. The
/// normalized stream contract requires contiguous part starts and matching
/// lifecycle tags.
pub const ResponseAccumulator = struct {
    const TextState = struct {
        bytes: std.ArrayList(u8) = .empty,

        // ziglint-ignore: Z023 -- allocator follows the conventional method receiver
        fn deinit(self: *TextState, allocator: std.mem.Allocator) void {
            self.bytes.deinit(allocator);
            self.* = undefined;
        }

        // ziglint-ignore: Z023 -- allocator follows the conventional method receiver
        fn replace(self: *TextState, allocator: std.mem.Allocator, value: []const u8) error{OutOfMemory}!void {
            self.bytes.clearRetainingCapacity();
            try self.bytes.appendSlice(allocator, value);
        }
    };

    const ToolCallState = struct {
        id: TextState = .{},
        has_id: bool = false,
        name: TextState = .{},
        has_name: bool = false,
        arguments: TextState = .{},

        // ziglint-ignore: Z023 -- allocator follows the conventional method receiver
        fn deinit(self: *ToolCallState, allocator: std.mem.Allocator) void {
            self.id.deinit(allocator);
            self.name.deinit(allocator);
            self.arguments.deinit(allocator);
            self.* = undefined;
        }
    };

    const PartState = union(enum) {
        text: TextState,
        thinking: TextState,
        tool_call: ToolCallState,

        // ziglint-ignore: Z023 -- allocator follows the conventional method receiver
        fn deinit(self: *PartState, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .text => |*value| value.deinit(allocator),
                .thinking => |*value| value.deinit(allocator),
                .tool_call => |*value| value.deinit(allocator),
            }
            self.* = undefined;
        }
    };

    allocator: std.mem.Allocator,
    identity: message.ModelIdentity,
    parts: std.ArrayList(PartState) = .empty,
    snapshot_parts: []ResponsePartSnapshot = &.{},
    current_usage: usage.Usage = .{},

    pub fn init(allocator: std.mem.Allocator, identity: message.ModelIdentity) ResponseAccumulator {
        return .{ .allocator = allocator, .identity = identity };
    }

    pub fn deinit(self: *ResponseAccumulator) void {
        self.allocator.free(self.snapshot_parts);
        for (self.parts.items) |*part| part.deinit(self.allocator);
        self.parts.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn snapshot(self: *const ResponseAccumulator) ResponseSnapshot {
        return .{
            .parts = self.snapshot_parts,
            .identity = self.identity,
            .usage = self.current_usage,
        };
    }

    pub fn apply(
        self: *ResponseAccumulator,
        event: StreamEvent,
    ) AccumulatorError!ResponseSnapshot {
        switch (event) {
            .part_start => |start| try self.startPart(start),
            .part_delta => |delta| try self.applyDelta(delta),
            .part_end => |end| try self.endPart(end),
            .usage => |value| self.current_usage = value,
        }
        try self.rebuildSnapshot();
        return self.snapshot();
    }

    /// Reconciles the streaming projection with the provider's final canonical
    /// response. Buffered models use this as their only accumulator update.
    pub fn finish(
        self: *ResponseAccumulator,
        response: message.ResponseMessage,
    ) error{OutOfMemory}!void {
        self.allocator.free(self.snapshot_parts);
        self.snapshot_parts = &.{};
        for (self.parts.items) |*part| part.deinit(self.allocator);
        self.parts.clearRetainingCapacity();
        for (response.parts) |part| {
            var state: PartState = switch (part) {
                .text => .{ .text = .{} },
                .thinking => .{ .thinking = .{} },
                .tool_call => .{ .tool_call = .{} },
            };
            errdefer state.deinit(self.allocator);
            switch (part) {
                .text => |value| try state.text.bytes.appendSlice(self.allocator, value.text),
                .thinking => |value| try state.thinking.bytes.appendSlice(self.allocator, value.text),
                .tool_call => |value| {
                    try state.tool_call.id.bytes.appendSlice(self.allocator, value.id);
                    state.tool_call.has_id = true;
                    try state.tool_call.name.bytes.appendSlice(self.allocator, value.name);
                    state.tool_call.has_name = true;
                    try state.tool_call.arguments.bytes.appendSlice(self.allocator, value.arguments_json);
                },
            }
            try self.parts.append(self.allocator, state);
        }
        self.identity = response.identity;
        self.current_usage = response.usage;
        try self.rebuildSnapshot();
    }

    fn startPart(self: *ResponseAccumulator, start: PartStart) AccumulatorError!void {
        if (start.index != self.parts.items.len) return error.InvalidStream;
        var part: PartState = switch (start.part) {
            .text => .{ .text = .{} },
            .thinking => .{ .thinking = .{} },
            .tool_call => |call| tool: {
                var state: ToolCallState = .{};
                errdefer state.deinit(self.allocator);
                if (call.id) |id| {
                    try state.id.bytes.appendSlice(self.allocator, id);
                    state.has_id = true;
                }
                if (call.name) |name| {
                    try state.name.bytes.appendSlice(self.allocator, name);
                    state.has_name = true;
                }
                break :tool .{ .tool_call = state };
            },
        };
        errdefer part.deinit(self.allocator);
        try self.parts.append(self.allocator, part);
    }

    fn applyDelta(self: *ResponseAccumulator, delta: PartDelta) AccumulatorError!void {
        if (delta.index >= self.parts.items.len) return error.InvalidStream;
        const part = &self.parts.items[delta.index];
        switch (delta.delta) {
            .text => |bytes| switch (part.*) {
                .text => |*state| try state.bytes.appendSlice(self.allocator, bytes),
                else => return error.InvalidStream,
            },
            .thinking => |bytes| switch (part.*) {
                .thinking => |*state| try state.bytes.appendSlice(self.allocator, bytes),
                else => return error.InvalidStream,
            },
            .tool_call => |call| switch (part.*) {
                .tool_call => |*state| {
                    if (call.id) |id| {
                        try state.id.replace(self.allocator, id);
                        state.has_id = true;
                    }
                    if (call.name) |name| {
                        try state.name.replace(self.allocator, name);
                        state.has_name = true;
                    }
                    try state.arguments.bytes.appendSlice(self.allocator, call.arguments_delta);
                },
                else => return error.InvalidStream,
            },
        }
    }

    fn endPart(self: *ResponseAccumulator, end: PartEnd) AccumulatorError!void {
        if (end.index >= self.parts.items.len) return error.InvalidStream;
        const part = &self.parts.items[end.index];
        switch (end.part) {
            .text => |value| switch (part.*) {
                .text => |*state| try state.replace(self.allocator, value.text),
                else => return error.InvalidStream,
            },
            .thinking => |value| switch (part.*) {
                .thinking => |*state| try state.replace(self.allocator, value.text),
                else => return error.InvalidStream,
            },
            .tool_call => |value| switch (part.*) {
                .tool_call => |*state| {
                    try state.id.replace(self.allocator, value.id);
                    state.has_id = true;
                    try state.name.replace(self.allocator, value.name);
                    state.has_name = true;
                    try state.arguments.replace(self.allocator, value.arguments_json);
                },
                else => return error.InvalidStream,
            },
        }
    }

    fn rebuildSnapshot(self: *ResponseAccumulator) error{OutOfMemory}!void {
        const replacement = try self.allocator.alloc(ResponsePartSnapshot, self.parts.items.len);
        errdefer self.allocator.free(replacement);
        for (self.parts.items, replacement) |part, *target| target.* = switch (part) {
            .text => |state| .{ .text = state.bytes.items },
            .thinking => |state| .{ .thinking = state.bytes.items },
            .tool_call => |state| .{ .tool_call = .{
                .id = if (state.has_id) state.id.bytes.items else null,
                .name = if (state.has_name) state.name.bytes.items else null,
                .arguments_json = state.arguments.bytes.items,
            } },
        };
        self.allocator.free(self.snapshot_parts);
        self.snapshot_parts = replacement;
    }
};

test "response accumulator exposes the complete partial response after every event" {
    var accumulator = ResponseAccumulator.init(
        std.testing.allocator,
        .{ .provider = "script", .model = "snapshot" },
    );
    defer accumulator.deinit();

    var snapshot = try accumulator.apply(.{ .part_start = .{ .index = 0, .part = .text } });
    try std.testing.expectEqual(@as(usize, 1), snapshot.parts.len);
    try std.testing.expectEqualStrings("", snapshot.parts[0].text);

    snapshot = try accumulator.apply(.{ .part_delta = .{
        .index = 0,
        .delta = .{ .text = "hel" },
    } });
    try std.testing.expectEqualStrings("hel", snapshot.parts[0].text);

    snapshot = try accumulator.apply(.{ .part_delta = .{
        .index = 0,
        .delta = .{ .text = "lo" },
    } });
    try std.testing.expectEqualStrings("hello", snapshot.parts[0].text);

    snapshot = try accumulator.apply(.{ .part_end = .{
        .index = 0,
        .part = .{ .text = .{ .text = "hello" } },
    } });
    try std.testing.expectEqualStrings("hello", snapshot.parts[0].text);
}

fn accumulateForAllocationFailure(allocator: std.mem.Allocator) !void {
    var accumulator = ResponseAccumulator.init(
        allocator,
        .{ .provider = "script", .model = "allocation" },
    );
    defer accumulator.deinit();
    _ = try accumulator.apply(.{ .part_start = .{
        .index = 0,
        .part = .{ .tool_call = .{ .id = "call", .name = "read" } },
    } });
    _ = try accumulator.apply(.{ .part_delta = .{
        .index = 0,
        .delta = .{ .tool_call = .{ .arguments_delta = "{}" } },
    } });
    try accumulator.finish(.{
        .parts = &.{.{ .tool_call = .{ .id = "call", .name = "read", .arguments_json = "{}" } }},
        .identity = .{ .provider = "script", .model = "allocation" },
        .finish = .{ .category = .tool_calls },
    });
}

test "response accumulator settles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        accumulateForAllocationFailure,
        .{},
    );
}

test "response accumulator rejects malformed normalized lifecycle" {
    var accumulator = ResponseAccumulator.init(
        std.testing.allocator,
        .{ .provider = "script", .model = "snapshot" },
    );
    defer accumulator.deinit();

    try std.testing.expectError(error.InvalidStream, accumulator.apply(.{ .part_delta = .{
        .index = 0,
        .delta = .{ .text = "orphan" },
    } }));
}

test "response accumulator retains partial tool identity and arguments" {
    var accumulator = ResponseAccumulator.init(
        std.testing.allocator,
        .{ .provider = "script", .model = "snapshot" },
    );
    defer accumulator.deinit();

    _ = try accumulator.apply(.{ .part_start = .{
        .index = 0,
        .part = .{ .tool_call = .{ .name = "read" } },
    } });
    const snapshot = try accumulator.apply(.{ .part_delta = .{
        .index = 0,
        .delta = .{ .tool_call = .{
            .id = "call-1",
            .arguments_delta = "{\"path\":",
        } },
    } });
    const call = snapshot.parts[0].tool_call;
    try std.testing.expectEqualStrings("call-1", call.id.?);
    try std.testing.expectEqualStrings("read", call.name.?);
    try std.testing.expectEqualStrings("{\"path\":", call.arguments_json);
}
