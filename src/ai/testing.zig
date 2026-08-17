const std = @import("std");
const message = @import("message.zig");
const model = @import("model.zig");
const stream = @import("stream.zig");

pub const ScriptedModel = struct {
    response_text: []const u8,
    identity: message.ModelIdentity,
    streaming: bool = true,

    pub fn invoke(
        self: *ScriptedModel,
        allocator: std.mem.Allocator,
        _: std.mem.Allocator,
        _: std.Io,
        _: model.ModelRequest,
        delivery: model.Delivery,
    ) model.ModelError!message.ResponseMessage {
        const text = try allocator.dupe(u8, self.response_text);
        const parts = try allocator.alloc(message.ResponsePart, 1);
        parts[0] = .{ .text = .{ .text = text } };

        switch (delivery) {
            .buffered => {},
            .streaming => |sink| {
                if (!self.streaming) return error.UnsupportedCapability;
                try emitEvent(sink, .{ .part_start = .{ .index = 0, .part = .text } });
                try emitEvent(sink, .{ .part_delta = .{ .index = 0, .delta = .{ .text = text } } });
                try emitEvent(sink, .{ .part_end = .{ .index = 0, .part = parts[0] } });
            },
        }

        return .{
            .parts = parts,
            .identity = self.identity,
            .finish = .{ .category = .stop },
        };
    }

    pub fn asModel(self: *ScriptedModel) model.Model {
        var profile: model.ModelProfile = .{};
        profile.capabilities.insert(.streaming);
        return model.Model.from(self, self.identity, profile);
    }
};

fn emitEvent(sink: stream.StreamSink, event: stream.StreamEvent) model.ModelError!void {
    sink.emit(event) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        error.Cancelled => error.Cancelled,
        error.ConsumerStopped => error.StreamConsumerStopped,
    };
}

test "two scripted implementations share the model seam" {
    var first: ScriptedModel = .{ .response_text = "first", .identity = .{ .provider = "script", .model = "one" } };
    var second: ScriptedModel = .{ .response_text = "second", .identity = .{ .provider = "script", .model = "two" } };
    const io = std.testing.io;
    const request: model.ModelRequest = .{ .messages = &.{} };

    var first_result = try first.asModel().complete(std.testing.allocator, io, request);
    defer first_result.deinit();
    var second_result = try second.asModel().complete(std.testing.allocator, io, request);
    defer second_result.deinit();
    try std.testing.expectEqualStrings("first", first_result.value.parts[0].text.text);
    try std.testing.expectEqualStrings("second", second_result.value.parts[0].text.text);
}

test "scripted model emits indexed stream lifecycle" {
    var scripted: ScriptedModel = .{
        .response_text = "stream",
        .identity = .{ .provider = "script", .model = "stream" },
    };
    var events: std.ArrayList(stream.StreamEvent) = .empty;
    defer events.deinit(std.testing.allocator);

    const Sink = struct {
        const Self = @This();
        events: *std.ArrayList(stream.StreamEvent),
        fn emit(context: *anyopaque, event: stream.StreamEvent) stream.StreamSinkError!void {
            const self: *Self = @ptrCast(@alignCast(context));
            try self.events.append(std.testing.allocator, event);
        }
    };
    var sink_state: Sink = .{ .events = &events };
    const sink: stream.StreamSink = .{ .context = &sink_state, .emitFn = Sink.emit };
    var result = try scripted.asModel().stream(std.testing.allocator, std.testing.io, .{ .messages = &.{} }, sink);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 3), events.items.len);
    try std.testing.expectEqual(@as(usize, 0), events.items[0].part_start.index);
    try std.testing.expectEqual(@as(usize, 0), events.items[2].part_end.index);
}

test "unsupported settings are rejected before implementation invocation" {
    var scripted: ScriptedModel = .{
        .response_text = "never",
        .identity = .{ .provider = "script", .model = "limited" },
    };
    const profile: model.ModelProfile = .{};
    const limited = model.Model.from(&scripted, scripted.identity, profile);
    try std.testing.expectError(error.UnsupportedSetting, limited.complete(std.testing.allocator, std.testing.io, .{
        .messages = &.{},
        .settings = .{ .temperature = 0.2 },
    }));
}
