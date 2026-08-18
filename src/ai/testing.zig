const std = @import("std");
const message = @import("message.zig");
const model = @import("model.zig");
const stream = @import("stream.zig");
const usage = @import("usage.zig");

/// One deterministic step served by `ScriptedModel` per model request.
pub const ScriptedStep = union(enum) {
    text: []const u8,
    text_finish: TextFinish,
    tool_call: ToolCall,
    tool_calls: ToolCalls,

    pub const TextFinish = struct {
        text: []const u8,
        finish: usage.FinishCategory,
    };

    pub const ToolCall = struct {
        id: []const u8,
        name: []const u8,
        arguments_json: []const u8,
        finish: usage.FinishCategory = .tool_calls,
    };

    pub const ToolCalls = struct {
        calls: []const ToolCall,
        finish: usage.FinishCategory = .tool_calls,
    };
};

/// A model implementation that serves a declared sequence of normalized
/// responses. Each invoke consumes the next step; a request past the last
/// step fails with `error.InvalidRequest` so a mismatched script fails
/// loudly instead of looping.
pub const ScriptedModel = struct {
    identity: message.ModelIdentity,
    steps: []const ScriptedStep,
    /// Pop cursor over `steps`; counts every invoke admission, including
    /// requests that failed because the script was exhausted.
    calls: usize = 0,
    streaming: bool = true,
    /// Optional synchronous observer called with the zero-based request index
    /// and the borrowed request before the step is served.
    on_request: ?*const fn (index: usize, request: model.ModelRequest) void = null,

    pub fn invoke(
        self: *ScriptedModel,
        allocator: std.mem.Allocator,
        _: std.mem.Allocator,
        _: std.Io,
        request: model.ModelRequest,
        delivery: model.Delivery,
    ) model.ModelError!message.ResponseMessage {
        const index = self.calls;
        self.calls += 1;
        if (self.on_request) |observe| observe(index, request);

        if (index >= self.steps.len) return error.InvalidRequest;
        switch (self.steps[index]) {
            .text => |text| return self.textResponse(allocator, delivery, text, .stop),
            .text_finish => |response| return self.textResponse(
                allocator,
                delivery,
                response.text,
                response.finish,
            ),
            .tool_call => |call| {
                const calls = [_]ScriptedStep.ToolCall{call};
                return self.toolCallsResponse(allocator, delivery, &calls, call.finish);
            },
            .tool_calls => |response| return self.toolCallsResponse(
                allocator,
                delivery,
                response.calls,
                response.finish,
            ),
        }
    }

    /// The profile advertises `.streaming` and `.tools` so the agent loop can
    /// pass tool definitions through the real capability preflight.
    pub fn asModel(self: *ScriptedModel) model.Model {
        var profile: model.ModelProfile = .{};
        profile.capabilities.insert(.streaming);
        profile.capabilities.insert(.tools);
        return model.Model.from(self, self.identity, profile);
    }

    fn textResponse(
        self: *ScriptedModel,
        allocator: std.mem.Allocator,
        delivery: model.Delivery,
        text: []const u8,
        finish: usage.FinishCategory,
    ) model.ModelError!message.ResponseMessage {
        const copied = try allocator.dupe(u8, text);
        const parts = try allocator.alloc(message.ResponsePart, 1);
        parts[0] = .{ .text = .{ .text = copied } };
        switch (delivery) {
            .buffered => {},
            .streaming => |sink| {
                if (!self.streaming) return error.UnsupportedCapability;
                try emitEvent(sink, .{ .part_start = .{ .index = 0, .part = .text } });
                try emitEvent(sink, .{ .part_delta = .{ .index = 0, .delta = .{ .text = copied } } });
                try emitEvent(sink, .{ .part_end = .{ .index = 0, .part = parts[0] } });
            },
        }
        return .{ .parts = parts, .identity = self.identity, .finish = .{ .category = finish } };
    }

    fn toolCallsResponse(
        self: *ScriptedModel,
        allocator: std.mem.Allocator,
        delivery: model.Delivery,
        calls: []const ScriptedStep.ToolCall,
        finish: usage.FinishCategory,
    ) model.ModelError!message.ResponseMessage {
        const parts = try allocator.alloc(message.ResponsePart, calls.len);
        for (calls, parts) |call, *part| {
            part.* = .{ .tool_call = .{
                .id = try allocator.dupe(u8, call.id),
                .name = try allocator.dupe(u8, call.name),
                .arguments_json = try allocator.dupe(u8, call.arguments_json),
            } };
        }
        switch (delivery) {
            .buffered => {},
            .streaming => |sink| {
                if (!self.streaming) return error.UnsupportedCapability;
                for (parts, 0..) |part, part_index| {
                    const call = part.tool_call;
                    const start: stream.ResponsePartStart = .{ .tool_call = .{
                        .id = call.id,
                        .name = call.name,
                    } };
                    try emitEvent(sink, .{ .part_start = .{ .index = part_index, .part = start } });
                    const delta: stream.ResponsePartDelta = .{ .tool_call = .{
                        .arguments_delta = call.arguments_json,
                    } };
                    try emitEvent(sink, .{ .part_delta = .{ .index = part_index, .delta = delta } });
                    try emitEvent(sink, .{ .part_end = .{ .index = part_index, .part = part } });
                }
            },
        }
        return .{ .parts = parts, .identity = self.identity, .finish = .{ .category = finish } };
    }
};

fn emitEvent(sink: stream.StreamSink, event: stream.StreamEvent) model.ModelError!void {
    sink.emit(event) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        error.Cancelled => error.Cancelled,
        error.ConsumerStopped => error.StreamConsumerStopped,
    };
}

var observed_indices: [8]usize = undefined;
var observed_count: usize = 0;

fn recordRequest(index: usize, _: model.ModelRequest) void {
    if (observed_count < observed_indices.len) observed_indices[observed_count] = index;
    observed_count += 1;
}

test "two scripted implementations share the model seam" {
    var first: ScriptedModel = .{
        .steps = &.{.{ .text = "first" }},
        .identity = .{ .provider = "script", .model = "one" },
    };
    var second: ScriptedModel = .{
        .steps = &.{.{ .text = "second" }},
        .identity = .{ .provider = "script", .model = "two" },
    };
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
        .steps = &.{.{ .text = "stream" }},
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
        .steps = &.{},
        .identity = .{ .provider = "script", .model = "limited" },
    };
    const profile: model.ModelProfile = .{};
    const limited = model.Model.from(&scripted, scripted.identity, profile);
    try std.testing.expectError(error.UnsupportedSetting, limited.complete(std.testing.allocator, std.testing.io, .{
        .messages = &.{},
        .settings = .{ .temperature = 0.2 },
    }));
}

test "scripted model serves ordered steps through the model seam" {
    var scripted: ScriptedModel = .{
        .steps = &.{
            .{ .tool_call = .{ .id = "call-1", .name = "read", .arguments_json = "{}" } },
            .{ .text = "final" },
        },
        .identity = .{ .provider = "script", .model = "loop" },
    };
    const request: model.ModelRequest = .{
        .messages = &.{},
        .tools = &.{.{ .name = "read", .description = "", .parameters_json_schema = "{}" }},
    };

    var first = try scripted.asModel().complete(std.testing.allocator, std.testing.io, request);
    defer first.deinit();
    try std.testing.expectEqual(message.ResponsePart.tool_call, std.meta.activeTag(first.value.parts[0]));
    try std.testing.expectEqualStrings("read", first.value.parts[0].tool_call.name);
    try std.testing.expectEqualStrings("call-1", first.value.parts[0].tool_call.id);
    try std.testing.expect(first.value.finish.category == .tool_calls);

    var second = try scripted.asModel().complete(std.testing.allocator, std.testing.io, request);
    defer second.deinit();
    try std.testing.expectEqual(message.ResponsePart.text, std.meta.activeTag(second.value.parts[0]));
    try std.testing.expectEqualStrings("final", second.value.parts[0].text.text);
    try std.testing.expect(second.value.finish.category == .stop);
    try std.testing.expectEqual(@as(usize, 2), scripted.calls);
}

test "scripted model observes requests in order" {
    observed_count = 0;
    var scripted: ScriptedModel = .{
        .steps = &.{ .{ .text = "a" }, .{ .text = "b" } },
        .identity = .{ .provider = "script", .model = "observe" },
        .on_request = recordRequest,
    };
    const io = std.testing.io;
    const request: model.ModelRequest = .{ .messages = &.{} };

    var first = try scripted.asModel().complete(std.testing.allocator, io, request);
    defer first.deinit();
    var second = try scripted.asModel().complete(std.testing.allocator, io, request);
    defer second.deinit();

    try std.testing.expectEqual(@as(usize, 2), observed_count);
    try std.testing.expectEqual(@as(usize, 0), observed_indices[0]);
    try std.testing.expectEqual(@as(usize, 1), observed_indices[1]);
    try std.testing.expectEqual(@as(usize, 2), scripted.calls);
}

test "scripted model fails loudly when steps are exhausted" {
    var scripted: ScriptedModel = .{
        .steps = &.{.{ .text = "only" }},
        .identity = .{ .provider = "script", .model = "exhaust" },
    };
    const io = std.testing.io;
    const request: model.ModelRequest = .{ .messages = &.{} };

    var first = try scripted.asModel().complete(std.testing.allocator, io, request);
    defer first.deinit();
    try std.testing.expectError(
        error.InvalidRequest,
        scripted.asModel().complete(std.testing.allocator, io, request),
    );
    try std.testing.expectEqual(@as(usize, 2), scripted.calls);
}
