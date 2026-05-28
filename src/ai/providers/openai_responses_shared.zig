const std = @import("std");
const models_api = @import("../models.zig");
const mem = @import("../../zistd/root.zig");
const protocol = @import("../protocol.zig");
const json_parse = @import("../utils/json_parse.zig");

pub const ProcessError = error{
    InvalidJson,
    ProviderError,
    OutOfMemory,
} || protocol.AssistantMessageEventSinkEmitError;

pub const ResponseStreamReducer = struct {
    backing_allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    model: protocol.Model,
    output: protocol.AssistantMessage,
    content: std.ArrayList(protocol.AssistantContent) = .empty,
    current: CurrentBlock = .none,

    const CurrentBlock = union(enum) {
        none,
        thinking: TextState,
        text: TextState,
        tool_call: ToolCallState,
    };

    const TextState = struct {
        content_index: usize,
        bytes: mem.ByteBuilder,
    };

    const ToolCallState = struct {
        content_index: usize,
        partial_json: mem.ByteBuilder,
    };

    pub fn init(
        backing_allocator: std.mem.Allocator,
        model: protocol.Model,
        timestamp: protocol.Timestamp,
    ) ResponseStreamReducer {
        return .{
            .backing_allocator = backing_allocator,
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
            .model = model,
            .output = .{
                .content = &.{},
                .api = model.api,
                .provider = model.provider,
                .model = model.id,
                .usage = protocol.emptyUsage(),
                .stop_reason = .stop,
                .timestamp = timestamp,
            },
        };
    }

    pub fn deinit(self: *ResponseStreamReducer) void {
        self.discardCurrentBlock();
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn partial(self: *ResponseStreamReducer) std.mem.Allocator.Error!protocol.AssistantMessage {
        var snapshot = self.output;
        snapshot.content = self.content.items;
        return snapshot;
    }

    pub fn applySseData(
        self: *ResponseStreamReducer,
        io: std.Io,
        sink: protocol.AssistantMessageEventSink,
        data: []const u8,
    ) anyerror!void {
        if (std.mem.eql(u8, std.mem.trim(u8, data, " \t\r\n"), "[DONE]")) return;
        var parsed = json_parse.parseJsonWithRepair(self.arena.allocator(), data) catch return error.InvalidJson;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidJson;
        try self.applyEvent(io, sink, parsed.value.object);
    }

    pub fn finish(self: *ResponseStreamReducer, io: std.Io, sink: protocol.AssistantMessageEventSink) anyerror!void {
        try self.finishCurrentBlock(io, sink);
        self.output.content = try self.content.toOwnedSlice(self.arena.allocator());
        if (hasToolCall(self.output.content) and self.output.stop_reason == .stop) self.output.stop_reason = .tool_use;
        switch (self.output.stop_reason) {
            .stop => try sink.endDone(io, .stop, self.output),
            .length => try sink.endDone(io, .length, self.output),
            .tool_use => try sink.endDone(io, .tool_use, self.output),
            .error_ => try sink.endError(io, .error_, self.output),
            .aborted => try sink.endAborted(io, self.output),
        }
    }

    fn applyEvent(
        self: *ResponseStreamReducer,
        io: std.Io,
        sink: protocol.AssistantMessageEventSink,
        object: std.json.ObjectMap,
    ) anyerror!void {
        const event_type = jsonString(object.get("type")) orelse return;

        if (std.mem.eql(u8, event_type, "response.created")) {
            if (object.get("response")) |response| if (response == .object) {
                if (jsonString(response.object.get("id"))) |id| self.output.response_id = try dupe(self, id);
            };
        } else if (std.mem.eql(u8, event_type, "response.output_item.added")) {
            if (object.get("item")) |item| if (item == .object) try self.startItem(io, sink, item.object);
        } else if (std.mem.eql(u8, event_type, "response.reasoning_summary_text.delta")) {
            if (jsonString(object.get("delta"))) |delta| try self.appendThinking(io, sink, delta);
        } else if (std.mem.eql(u8, event_type, "response.reasoning_summary_part.done")) {
            try self.appendThinking(io, sink, "\n\n");
        } else if (std.mem.eql(u8, event_type, "response.output_text.delta")) {
            if (jsonString(object.get("delta"))) |delta| try self.appendText(io, sink, delta);
        } else if (std.mem.eql(u8, event_type, "response.refusal.delta")) {
            if (jsonString(object.get("delta"))) |delta| try self.appendText(io, sink, delta);
        } else if (std.mem.eql(u8, event_type, "response.function_call_arguments.delta")) {
            if (jsonString(object.get("delta"))) |delta| try self.appendToolArguments(io, sink, delta);
        } else if (std.mem.eql(u8, event_type, "response.function_call_arguments.done")) {
            if (jsonString(object.get("arguments"))) |arguments| try self.finishToolArguments(io, sink, arguments);
        } else if (std.mem.eql(u8, event_type, "response.output_item.done")) {
            if (object.get("item")) |item| if (item == .object) try self.finishItem(io, sink, item.object);
        } else if (std.mem.eql(u8, event_type, "response.completed") or
            std.mem.eql(u8, event_type, "response.done") or
            std.mem.eql(u8, event_type, "response.incomplete"))
        {
            if (object.get("response")) |response| if (response == .object) try self.applyCompleted(response.object);
        } else if (std.mem.eql(u8, event_type, "error")) {
            self.output.stop_reason = .error_;
            self.output.error_message = try self.formatProviderError(object);
            try sink.endError(io, .error_, try self.partial());
            return error.ErrorEmitted;
        } else if (std.mem.eql(u8, event_type, "response.failed")) {
            self.output.stop_reason = .error_;
            self.output.error_message = try self.formatFailedResponse(object);
            try sink.endError(io, .error_, try self.partial());
            return error.ErrorEmitted;
        }
    }

    fn startItem(
        self: *ResponseStreamReducer,
        io: std.Io,
        sink: protocol.AssistantMessageEventSink,
        item: std.json.ObjectMap,
    ) anyerror!void {
        try self.finishCurrentBlock(io, sink);
        const item_type = jsonString(item.get("type")) orelse return;
        if (std.mem.eql(u8, item_type, "reasoning")) {
            try self.content.append(self.arena.allocator(), .{ .thinking = .{ .thinking = "" } });
            const index = self.content.items.len - 1;
            self.current = .{ .thinking = .{ .content_index = index, .bytes = mem.ByteBuilder.init(self.arena.allocator()) } };
            try sink.emit(io, .{ .thinking_start = .{ .content_index = index, .partial = try self.partial() } });
        } else if (std.mem.eql(u8, item_type, "message")) {
            try self.content.append(self.arena.allocator(), .{ .text = .{ .text = "" } });
            const index = self.content.items.len - 1;
            self.current = .{ .text = .{ .content_index = index, .bytes = mem.ByteBuilder.init(self.arena.allocator()) } };
            try sink.emit(io, .{ .text_start = .{ .content_index = index, .partial = try self.partial() } });
        } else if (std.mem.eql(u8, item_type, "function_call")) {
            const call_id = jsonString(item.get("call_id")) orelse "";
            const item_id = jsonString(item.get("id")) orelse "";
            const name = jsonString(item.get("name")) orelse "";
            const id = try std.fmt.allocPrint(self.arena.allocator(), "{s}|{s}", .{ call_id, item_id });
            try self.content.append(self.arena.allocator(), .{ .tool_call = .{
                .id = id,
                .name = try dupe(self, name),
                .arguments = emptyObject(),
            } });
            const index = self.content.items.len - 1;
            self.current = .{ .tool_call = .{ .content_index = index, .partial_json = mem.ByteBuilder.init(self.backing_allocator) } };
            if (jsonString(item.get("arguments"))) |arguments| {
                try self.current.tool_call.partial_json.append(arguments);
            }
            try sink.emit(io, .{ .toolcall_start = .{ .content_index = index, .partial = try self.partial() } });
        }
    }

    fn finishCurrentBlock(
        self: *ResponseStreamReducer,
        io: std.Io,
        sink: protocol.AssistantMessageEventSink,
    ) anyerror!void {
        switch (self.current) {
            .none => {},
            .thinking => |*state| {
                const frozen = try state.bytes.copyTo(self.arena.allocator());
                self.content.items[state.content_index].thinking.thinking = frozen;
                try sink.emit(io, .{ .thinking_end = .{
                    .content_index = state.content_index,
                    .content = frozen,
                    .partial = try self.partial(),
                } });
            },
            .text => |*state| {
                const frozen = try state.bytes.copyTo(self.arena.allocator());
                self.content.items[state.content_index].text.text = frozen;
                try sink.emit(io, .{ .text_end = .{
                    .content_index = state.content_index,
                    .content = frozen,
                    .partial = try self.partial(),
                } });
            },
            .tool_call => |*state| {
                errdefer state.partial_json.deinit();
                try self.parseToolArguments(state);
                try sink.emit(io, .{ .toolcall_end = .{
                    .content_index = state.content_index,
                    .tool_call = self.content.items[state.content_index].tool_call,
                    .partial = try self.partial(),
                } });
                state.partial_json.deinit();
            },
        }
        self.current = .none;
    }

    fn discardCurrentBlock(self: *ResponseStreamReducer) void {
        switch (self.current) {
            .thinking, .text => {},
            .tool_call => |*state| state.partial_json.deinit(),
            .none => {},
        }
        self.current = .none;
    }

    fn appendThinking(
        self: *ResponseStreamReducer,
        io: std.Io,
        sink: protocol.AssistantMessageEventSink,
        delta: []const u8,
    ) anyerror!void {
        if (self.current != .thinking) return;
        const state = &self.current.thinking;
        try state.bytes.append(delta);
        const index = state.content_index;
        self.content.items[index].thinking.thinking = state.bytes.items();
        try sink.emit(io, .{ .thinking_delta = .{
            .content_index = index,
            .delta = try dupe(self, delta),
            .partial = try self.partial(),
        } });
    }

    fn appendText(
        self: *ResponseStreamReducer,
        io: std.Io,
        sink: protocol.AssistantMessageEventSink,
        delta: []const u8,
    ) anyerror!void {
        if (self.current != .text) return;
        const state = &self.current.text;
        try state.bytes.append(delta);
        const index = state.content_index;
        self.content.items[index].text.text = state.bytes.items();
        try sink.emit(io, .{ .text_delta = .{
            .content_index = index,
            .delta = try dupe(self, delta),
            .partial = try self.partial(),
        } });
    }

    fn appendToolArguments(
        self: *ResponseStreamReducer,
        io: std.Io,
        sink: protocol.AssistantMessageEventSink,
        delta: []const u8,
    ) anyerror!void {
        if (self.current != .tool_call) return;
        const state = &self.current.tool_call;
        try state.partial_json.append(delta);
        try sink.emit(io, .{ .toolcall_delta = .{
            .content_index = state.content_index,
            .delta = try dupe(self, delta),
            .partial = try self.partial(),
        } });
    }

    fn finishToolArguments(
        self: *ResponseStreamReducer,
        io: std.Io,
        sink: protocol.AssistantMessageEventSink,
        arguments: []const u8,
    ) anyerror!void {
        if (self.current != .tool_call) return;
        const state = &self.current.tool_call;
        const previous_len = state.partial_json.items().len;
        state.partial_json.clearRetainingCapacity();
        try state.partial_json.append(arguments);
        try self.parseToolArguments(state);
        if (arguments.len > previous_len) {
            const delta = arguments[previous_len..];
            try sink.emit(io, .{ .toolcall_delta = .{
                .content_index = state.content_index,
                .delta = try dupe(self, delta),
                .partial = try self.partial(),
            } });
        }
    }

    fn finishItem(
        self: *ResponseStreamReducer,
        io: std.Io,
        sink: protocol.AssistantMessageEventSink,
        item: std.json.ObjectMap,
    ) anyerror!void {
        const item_type = jsonString(item.get("type")) orelse return;
        if (std.mem.eql(u8, item_type, "message") and self.current == .text) {
            const index = self.current.text.content_index;
            if (jsonString(item.get("id"))) |id| {
                self.content.items[index].text.text_signature = encodeTextSignature(
                    self.arena.allocator(),
                    id,
                ) catch return error.OutOfMemory;
            }
        } else if (std.mem.eql(u8, item_type, "function_call") and self.current == .tool_call) {
            const state = &self.current.tool_call;
            if (jsonString(item.get("arguments"))) |arguments| {
                state.partial_json.clearRetainingCapacity();
                try state.partial_json.append(arguments);
            }
        }
        try self.finishCurrentBlock(io, sink);
    }

    fn parseToolArguments(self: *ResponseStreamReducer, state: *ToolCallState) !void {
        const parsed = try parseJsonValueLeaky(self.arena.allocator(), state.partial_json.items());
        self.content.items[state.content_index].tool_call.arguments = parsed;
    }

    fn applyCompleted(self: *ResponseStreamReducer, response: std.json.ObjectMap) !void {
        if (jsonString(response.get("id"))) |id| self.output.response_id = try dupe(self, id);
        if (response.get("usage")) |usage| if (usage == .object) {
            const cached = if (usage.object.get("input_tokens_details")) |details|
                if (details == .object) jsonU64(details.object.get("cached_tokens")) orelse 0 else 0
            else
                0;
            const input_tokens = jsonU64(usage.object.get("input_tokens")) orelse 0;
            self.output.usage.input = if (input_tokens > cached) input_tokens - cached else 0;
            self.output.usage.output = jsonU64(usage.object.get("output_tokens")) orelse 0;
            self.output.usage.cache_read = cached;
            self.output.usage.cache_write = 0;
            self.output.usage.total_tokens = jsonU64(usage.object.get("total_tokens")) orelse 0;
            _ = models_api.calculateCost(self.model, &self.output.usage);
        };
        self.output.stop_reason = mapStopReason(jsonString(response.get("status")));
    }

    fn formatProviderError(self: *ResponseStreamReducer, object: std.json.ObjectMap) ![]const u8 {
        const code = jsonString(object.get("code")) orelse "unknown";
        const message = jsonString(object.get("message")) orelse "Unknown error";
        return std.fmt.allocPrint(self.arena.allocator(), "Error Code {s}: {s}", .{ code, message });
    }

    fn formatFailedResponse(self: *ResponseStreamReducer, object: std.json.ObjectMap) ![]const u8 {
        if (object.get("response")) |response| if (response == .object) {
            if (response.object.get("error")) |err| if (err == .object) {
                const code = jsonString(err.object.get("code")) orelse "unknown";
                const message = jsonString(err.object.get("message")) orelse "no message";
                return std.fmt.allocPrint(self.arena.allocator(), "{s}: {s}", .{ code, message });
            };
            if (response.object.get("incomplete_details")) |details| if (details == .object) {
                if (jsonString(details.object.get("reason"))) |reason| {
                    return std.fmt.allocPrint(self.arena.allocator(), "incomplete: {s}", .{reason});
                }
            };
        };
        return dupe(self, "Unknown error (no error details in response)");
    }
};

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const resolved = value orelse return null;
    return switch (resolved) {
        .string => |string| string,
        else => null,
    };
}

fn jsonU64(value: ?std.json.Value) ?u64 {
    const resolved = value orelse return null;
    return switch (resolved) {
        .integer => |integer| if (integer >= 0) @intCast(integer) else null,
        .float => |float| if (float >= 0 and float <= @as(f64, @floatFromInt(std.math.maxInt(u64))))
            @intFromFloat(float)
        else
            null,
        else => null,
    };
}

fn mapStopReason(status: ?[]const u8) protocol.StopReason {
    const value = status orelse return .stop;
    if (std.mem.eql(u8, value, "completed")) return .stop;
    if (std.mem.eql(u8, value, "incomplete")) return .length;
    if (std.mem.eql(u8, value, "failed")) return .error_;
    if (std.mem.eql(u8, value, "cancelled")) return .error_;
    if (std.mem.eql(u8, value, "in_progress")) return .stop;
    if (std.mem.eql(u8, value, "queued")) return .stop;
    return .error_;
}

fn hasToolCall(content: []const protocol.AssistantContent) bool {
    for (content) |block| if (block == .tool_call) return true;
    return false;
}

fn emptyObject() std.json.Value {
    const object: std.json.ObjectMap = .empty;
    return .{ .object = object };
}

fn parseJsonValueLeaky(allocator: std.mem.Allocator, json: []const u8) !std.json.Value {
    const trimmed = std.mem.trim(u8, json, " \t\r\n");
    if (trimmed.len == 0) return emptyObject();
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, trimmed, .{});
}

fn encodeTextSignature(allocator: std.mem.Allocator, id: []const u8) ![]const u8 {
    var value = std.Io.Writer.Allocating.init(allocator);
    errdefer value.deinit();
    try value.writer.writeAll("{\"v\":1,\"id\":");
    try std.json.Stringify.value(id, .{}, &value.writer);
    try value.writer.writeByte('}');
    return value.toOwnedSlice();
}

fn concat(allocator: std.mem.Allocator, left: []const u8, right: []const u8) ![]const u8 {
    const output = try allocator.alloc(u8, left.len + right.len);
    @memcpy(output[0..left.len], left);
    @memcpy(output[left.len..], right);
    return output;
}

fn dupe(self: *ResponseStreamReducer, value: []const u8) ![]const u8 {
    return self.arena.allocator().dupe(u8, value);
}

test "responses reducer emits text deltas and done" {
    const model = testModel();
    var reducer = ResponseStreamReducer.init(std.testing.allocator, model, 123);
    defer reducer.deinit();
    var buffer: [16]protocol.AssistantMessageEvent = undefined;
    var stream = protocol.AssistantMessageEventStream.init(&buffer);
    const sink = stream.sink();

    try sink.emit(std.Io.failing, .{ .start = .{ .partial = try reducer.partial() } });
    try reducer.applySseData(std.Io.failing, sink,
        \\{"type":"response.output_item.added","item":{"type":"message","id":"msg_1"}}
    );
    try reducer.applySseData(std.Io.failing, sink,
        \\{"type":"response.output_text.delta","delta":"hi"}
    );
    try reducer.applySseData(std.Io.failing, sink,
        \\{"type":"response.output_item.done","item":{"type":"message","id":"msg_1"}}
    );
    try reducer.applySseData(std.Io.failing, sink,
        \\{"type":"response.completed","response":{"id":"resp_1","status":"completed",
        \\"usage":{"input_tokens":10,"output_tokens":2,"total_tokens":12,
        \\"input_tokens_details":{"cached_tokens":3}}}}
    );
    try reducer.finish(std.Io.failing, sink);

    var handler: CountingHandler = .{};
    const result = try protocol.AssistantMessageEventStream.drain(CountingHandler, std.Io.failing, &stream, &handler);
    try std.testing.expectEqual(@as(usize, 5), handler.event_count);
    try std.testing.expectEqualStrings("hi", result.content[0].text.text);
    try std.testing.expectEqualStrings("resp_1", result.response_id.?);
    try std.testing.expectEqual(@as(u64, 7), result.usage.input);
    try std.testing.expectEqual(@as(u64, 3), result.usage.cache_read);
    try std.testing.expectEqual(protocol.StopReason.stop, result.stop_reason);
}

test "responses reducer parses tool call arguments and maps stop to tool use" {
    const model = testModel();
    var reducer = ResponseStreamReducer.init(std.testing.allocator, model, 123);
    defer reducer.deinit();
    var buffer: [16]protocol.AssistantMessageEvent = undefined;
    var stream = protocol.AssistantMessageEventStream.init(&buffer);
    const sink = stream.sink();

    try sink.emit(std.Io.failing, .{ .start = .{ .partial = try reducer.partial() } });
    try reducer.applySseData(std.Io.failing, sink,
        \\{"type":"response.output_item.added","item":{"type":"function_call",
        \\"id":"fc_1","call_id":"call_1","name":"echo","arguments":""}}
    );
    try reducer.applySseData(std.Io.failing, sink,
        \\{"type":"response.function_call_arguments.delta","delta":"{\"text\":"}
    );
    try reducer.applySseData(std.Io.failing, sink,
        \\{"type":"response.function_call_arguments.done","arguments":"{\"text\":\"ok\"}"}
    );
    try reducer.applySseData(std.Io.failing, sink,
        \\{"type":"response.output_item.done","item":{"type":"function_call",
        \\"id":"fc_1","call_id":"call_1","name":"echo",
        \\"arguments":"{\"text\":\"ok\"}"}}
    );
    try reducer.applySseData(std.Io.failing, sink,
        \\{"type":"response.completed","response":{"status":"completed"}}
    );
    try reducer.finish(std.Io.failing, sink);

    var handler: CountingHandler = .{};
    const result = try protocol.AssistantMessageEventStream.drain(CountingHandler, std.Io.failing, &stream, &handler);
    const call = result.content[0].tool_call;
    try std.testing.expectEqualStrings("call_1|fc_1", call.id);
    try std.testing.expectEqualStrings("echo", call.name);
    try std.testing.expectEqualStrings("ok", call.arguments.object.get("text").?.string);
    try std.testing.expectEqual(protocol.StopReason.tool_use, result.stop_reason);
}

const CountingHandler = struct {
    event_count: usize = 0,

    pub fn onAssistantMessageEvent(self: *CountingHandler, _: protocol.AssistantMessageEvent) !void {
        self.event_count += 1;
    }
};

fn testModel() protocol.Model {
    return .{
        .id = "gpt-test",
        .name = "GPT Test",
        .api = protocol.KnownApi.openai_responses,
        .provider = protocol.KnownProvider.openai,
        .base_url = "https://api.openai.test/v1",
        .reasoning = true,
        .input = &.{ .text, .image },
        .cost = .{ .input = 1, .output = 2, .cache_read = 0.5, .cache_write = 1.5 },
        .context_window = 128_000,
        .max_tokens = 32_000,
    };
}
