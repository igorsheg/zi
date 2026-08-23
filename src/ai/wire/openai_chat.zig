const std = @import("std");
const failure = @import("../failure.zig");
const message = @import("../message.zig");
const model = @import("../model.zig");
const sse = @import("sse.zig");
const stream = @import("../stream.zig");
const usage_api = @import("../usage.zig");
const transport_api = @import("../transport.zig");

const max_parts = 256;
const max_tool_arguments_bytes = 1024 * 1024;

pub fn encodeRequest(
    allocator: std.mem.Allocator,
    model_id: []const u8,
    request: model.ModelRequest,
    streaming: bool,
) failure.ModelError![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;

    writer.writeAll("{\"model\":") catch return error.OutOfMemory;
    writeJson(writer, model_id) catch return error.OutOfMemory;
    writer.print(",\"stream\":{s}", .{if (streaming) "true" else "false"}) catch return error.OutOfMemory;
    if (streaming) writer.writeAll(",\"stream_options\":{\"include_usage\":true}") catch return error.OutOfMemory;
    writer.writeAll(",\"messages\":[") catch return error.OutOfMemory;

    var wrote_message = false;
    for (request.instructions) |instruction| {
        try writeRoleText(writer, "system", instruction, &wrote_message);
    }
    for (request.messages) |entry| switch (entry) {
        .request => |request_message| for (request_message.parts) |part| switch (part) {
            .user => |content| try writeUserContent(writer, content, &wrote_message),
            .tool_result => |result| try writeToolResult(allocator, writer, result, &wrote_message),
            .retry_prompt => |text| try writeRoleText(writer, "user", text, &wrote_message),
        },
        .response => |response| try writeAssistant(allocator, writer, response, &wrote_message),
    };
    writer.writeByte(']') catch return error.OutOfMemory;

    if (request.settings.temperature) |value| {
        writer.print(",\"temperature\":{d}", .{value}) catch return error.OutOfMemory;
    }
    if (request.settings.top_p) |value| writer.print(",\"top_p\":{d}", .{value}) catch return error.OutOfMemory;
    if (request.settings.max_output_tokens) |value| {
        writer.print(",\"max_completion_tokens\":{}", .{value}) catch return error.OutOfMemory;
    }
    if (request.settings.seed) |value| writer.print(",\"seed\":{}", .{value}) catch return error.OutOfMemory;
    if (request.settings.stop_sequences) |values| {
        writer.writeAll(",\"stop\":[") catch return error.OutOfMemory;
        for (values, 0..) |value, index| {
            if (index > 0) writer.writeByte(',') catch return error.OutOfMemory;
            writeJson(writer, value) catch return error.OutOfMemory;
        }
        writer.writeByte(']') catch return error.OutOfMemory;
    }
    if (request.tools.len > 0) {
        writer.writeAll(",\"tools\":[") catch return error.OutOfMemory;
        for (request.tools, 0..) |tool, index| {
            if (tool.name.len == 0) return error.InvalidRequest;
            var parsed = std.json.parseFromSlice(
                std.json.Value,
                allocator,
                tool.parameters_json_schema,
                .{},
            ) catch |parse_failure| switch (parse_failure) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidRequest,
            };
            defer parsed.deinit();
            if (parsed.value != .object) return error.InvalidRequest;
            if (index > 0) writer.writeByte(',') catch return error.OutOfMemory;
            writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":") catch return error.OutOfMemory;
            writeJson(writer, tool.name) catch return error.OutOfMemory;
            writer.writeAll(",\"description\":") catch return error.OutOfMemory;
            writeJson(writer, tool.description) catch return error.OutOfMemory;
            writer.writeAll(",\"parameters\":") catch return error.OutOfMemory;
            writer.writeAll(tool.parameters_json_schema) catch return error.OutOfMemory;
            writer.writeAll("}}") catch return error.OutOfMemory;
        }
        writer.writeAll("],\"tool_choice\":\"auto\"") catch return error.OutOfMemory;
    }
    writer.writeByte('}') catch return error.OutOfMemory;
    return output.toOwnedSlice() catch return error.OutOfMemory;
}

pub fn decodeResponse(
    allocator: std.mem.Allocator,
    identity: message.ModelIdentity,
    body: []const u8,
) failure.ModelError!message.ResponseMessage {
    const WireResponse = struct {
        choices: []const struct {
            message: struct {
                content: ?[]const u8 = null,
                reasoning_content: ?[]const u8 = null,
                tool_calls: ?[]const struct {
                    id: []const u8,
                    function: struct {
                        name: []const u8,
                        arguments: []const u8,
                    },
                } = null,
            },
            finish_reason: ?[]const u8 = null,
        },
        usage: ?struct {
            prompt_tokens: u64 = 0,
            completion_tokens: u64 = 0,
            prompt_tokens_details: ?struct {
                cached_tokens: u64 = 0,
                cache_write_tokens: u64 = 0,
            } = null,
            completion_tokens_details: ?struct { reasoning_tokens: u64 = 0 } = null,
        } = null,
    };

    var parsed = std.json.parseFromSlice(WireResponse, allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch |parse_failure| switch (parse_failure) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidProviderResponse,
    };
    defer parsed.deinit();
    if (parsed.value.choices.len == 0) return error.InvalidProviderResponse;
    const choice = parsed.value.choices[0];
    var parts: std.ArrayList(message.ResponsePart) = .empty;

    if (choice.message.reasoning_content) |text| if (text.len > 0) {
        parts.append(allocator, .{ .thinking = .{
            .text = try duplicate(allocator, text),
        } }) catch return error.OutOfMemory;
    };
    if (choice.message.content) |text| if (text.len > 0) {
        parts.append(allocator, .{ .text = .{
            .text = try duplicate(allocator, text),
        } }) catch return error.OutOfMemory;
    };
    if (choice.message.tool_calls) |calls| for (calls) |call| {
        validateJson(allocator, call.function.arguments) catch |validation_failure| switch (validation_failure) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidJson => return error.InvalidProviderResponse,
        };
        parts.append(allocator, .{ .tool_call = .{
            .id = try duplicate(allocator, call.id),
            .name = try duplicate(allocator, call.function.name),
            .arguments_json = try duplicate(allocator, call.function.arguments),
        } }) catch return error.OutOfMemory;
    };

    const finish_reason = choice.finish_reason orelse return error.InvalidProviderResponse;
    const wire_usage = parsed.value.usage;
    return .{
        .parts = parts.toOwnedSlice(allocator) catch return error.OutOfMemory,
        .identity = identity,
        .usage = if (wire_usage) |value| .{
            .input_tokens = value.prompt_tokens -|
                (if (value.prompt_tokens_details) |details| details.cached_tokens else 0) -|
                (if (value.prompt_tokens_details) |details| details.cache_write_tokens else 0),
            .output_tokens = value.completion_tokens,
            .cached_input_tokens = if (value.prompt_tokens_details) |details| details.cached_tokens else 0,
            .cache_write_tokens = if (value.prompt_tokens_details) |details| details.cache_write_tokens else 0,
            .reasoning_tokens = if (value.completion_tokens_details) |details| details.reasoning_tokens else 0,
        } else .{},
        .finish = try finish(allocator, finish_reason),
    };
}

pub const StreamDecoder = struct {
    allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    identity: message.ModelIdentity,
    sink: ?stream.StreamSink,
    parser: sse.Parser,
    parts: std.ArrayList(Part) = .empty,
    tool_parts: [max_parts]?usize = @splat(null),
    usage: usage_api.Usage = .{},
    finish_value: usage_api.Finish = .{},
    failure_value: ?failure.ModelError = null,
    status: u16 = 0,
    response_metadata: transport_api.ResponseMetadata = .{},
    error_body: std.ArrayList(u8) = .empty,

    const Part = union(enum) {
        text: std.ArrayList(u8),
        thinking: std.ArrayList(u8),
        tool_call: Tool,
    };

    const Tool = struct {
        id: std.ArrayList(u8) = .empty,
        name: std.ArrayList(u8) = .empty,
        arguments: std.ArrayList(u8) = .empty,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        scratch_allocator: std.mem.Allocator,
        identity: message.ModelIdentity,
        sink: ?stream.StreamSink,
    ) StreamDecoder {
        return .{
            .allocator = allocator,
            .scratch_allocator = scratch_allocator,
            .identity = identity,
            .sink = sink,
            .parser = sse.Parser.init(scratch_allocator, .{}),
        };
    }

    pub fn deinit(self: *StreamDecoder) void {
        self.parser.deinit();
        for (self.parts.items) |*part| switch (part.*) {
            .text => |*text| text.deinit(self.allocator),
            .thinking => |*text| text.deinit(self.allocator),
            .tool_call => |*tool| {
                tool.id.deinit(self.allocator);
                tool.name.deinit(self.allocator);
                tool.arguments.deinit(self.allocator);
            },
        };
        self.parts.deinit(self.allocator);
        self.error_body.deinit(self.scratch_allocator);
        self.* = undefined;
    }

    pub fn bodySink(self: *StreamDecoder) transport_api.BodySink {
        return .{ .context = self, .start_fn = startBody, .chunk_fn = chunkBody };
    }

    pub fn result(self: *StreamDecoder) failure.ModelError!message.ResponseMessage {
        if (self.failure_value) |value| return value;
        if (self.status < 200 or self.status >= 300) return statusError(self.status);
        const Sink = struct {
            const Self = @This();
            decoder: *StreamDecoder,
            pub fn emit(context: *Self, event: sse.Event) !void {
                try context.decoder.applyEvent(event);
            }
        };
        var sink_context: Sink = .{ .decoder = self };
        self.parser.finish(&sink_context) catch |decode_failure| return switch (decode_failure) {
            error.OutOfMemory => error.OutOfMemory,
            error.Cancelled => error.Cancelled,
            error.ConsumerStopped => error.StreamConsumerStopped,
            else => error.InvalidProviderResponse,
        };
        if (self.failure_value) |value| return value;
        if (self.finish_value.raw_reason == null) return error.StreamInterrupted;

        var output: std.ArrayList(message.ResponsePart) = .empty;
        for (self.parts.items, 0..) |part, index| {
            const completed: message.ResponsePart = switch (part) {
                .text => |text| .{ .text = .{ .text = try duplicate(self.allocator, text.items) } },
                .thinking => |text| .{ .thinking = .{ .text = try duplicate(self.allocator, text.items) } },
                .tool_call => |tool| tool_call: {
                    if (tool.id.items.len == 0 or tool.name.items.len == 0) return error.InvalidProviderResponse;
                    validateJson(
                        self.allocator,
                        tool.arguments.items,
                    ) catch |validation_failure| switch (validation_failure) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.InvalidJson => return error.InvalidProviderResponse,
                    };
                    break :tool_call .{ .tool_call = .{
                        .id = try duplicate(self.allocator, tool.id.items),
                        .name = try duplicate(self.allocator, tool.name.items),
                        .arguments_json = try duplicate(self.allocator, tool.arguments.items),
                    } };
                },
            };
            output.append(self.allocator, completed) catch return error.OutOfMemory;
            if (self.sink) |event_sink| event_sink.emit(.{ .part_end = .{
                .index = index,
                .part = completed,
            } }) catch |sink_failure| {
                return streamError(sink_failure);
            };
        }
        return .{
            .parts = output.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
            .identity = self.identity,
            .usage = self.usage,
            .finish = self.finish_value,
        };
    }

    fn startBody(context: *anyopaque, head: transport_api.ResponseHead) transport_api.SinkError!void {
        const self: *StreamDecoder = @ptrCast(@alignCast(context));
        self.status = head.status;
        self.response_metadata = head.metadata;
    }

    fn chunkBody(context: *anyopaque, bytes: []const u8) transport_api.SinkError!void {
        const self: *StreamDecoder = @ptrCast(@alignCast(context));
        if (self.status < 200 or self.status >= 300) {
            if (bytes.len > 2048 -| self.error_body.items.len) return;
            self.error_body.appendSlice(self.scratch_allocator, bytes) catch return error.OutOfMemory;
            return;
        }
        const Sink = struct {
            const Self = @This();
            decoder: *StreamDecoder,
            pub fn emit(sink_context: *Self, event: sse.Event) !void {
                try sink_context.decoder.applyEvent(event);
            }
        };
        var sink_context: Sink = .{ .decoder = self };
        self.parser.feed(bytes, &sink_context) catch |decode_failure| {
            self.failure_value = switch (decode_failure) {
                error.OutOfMemory => error.OutOfMemory,
                error.Cancelled => error.Cancelled,
                error.ConsumerStopped => error.StreamConsumerStopped,
                else => error.InvalidProviderResponse,
            };
            return switch (decode_failure) {
                error.OutOfMemory => error.OutOfMemory,
                error.Cancelled => error.Cancelled,
                else => error.ConsumerStopped,
            };
        };
    }

    fn applyEvent(self: *StreamDecoder, event: sse.Event) !void {
        const data = std.mem.trim(u8, event.data, " \t\r\n");
        if (std.mem.eql(u8, data, "[DONE]")) return;
        const Chunk = struct {
            choices: []const struct {
                delta: struct {
                    content: ?[]const u8 = null,
                    reasoning_content: ?[]const u8 = null,
                    tool_calls: ?[]const struct {
                        index: usize,
                        id: ?[]const u8 = null,
                        function: ?struct {
                            name: ?[]const u8 = null,
                            arguments: ?[]const u8 = null,
                        } = null,
                    } = null,
                } = .{},
                finish_reason: ?[]const u8 = null,
            } = &.{},
            usage: ?struct {
                prompt_tokens: u64 = 0,
                completion_tokens: u64 = 0,
                prompt_tokens_details: ?struct {
                    cached_tokens: u64 = 0,
                    cache_write_tokens: u64 = 0,
                } = null,
                completion_tokens_details: ?struct { reasoning_tokens: u64 = 0 } = null,
            } = null,
        };
        var scratch = std.heap.ArenaAllocator.init(self.scratch_allocator);
        defer scratch.deinit();
        var parsed = try std.json.parseFromSlice(Chunk, scratch.allocator(), data, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        if (parsed.value.usage) |value| {
            self.usage = .{
                .input_tokens = value.prompt_tokens -|
                    (if (value.prompt_tokens_details) |details| details.cached_tokens else 0) -|
                    (if (value.prompt_tokens_details) |details| details.cache_write_tokens else 0),
                .output_tokens = value.completion_tokens,
                .cached_input_tokens = if (value.prompt_tokens_details) |details| details.cached_tokens else 0,
                .cache_write_tokens = if (value.prompt_tokens_details) |details| details.cache_write_tokens else 0,
                .reasoning_tokens = if (value.completion_tokens_details) |details| details.reasoning_tokens else 0,
            };
            if (self.sink) |event_sink| try event_sink.emit(.{ .usage = self.usage });
        }
        if (parsed.value.choices.len == 0) return;
        const choice = parsed.value.choices[0];
        if (choice.delta.reasoning_content) |delta| if (delta.len > 0) try self.appendText(.thinking, delta);
        if (choice.delta.content) |delta| if (delta.len > 0) try self.appendText(.text, delta);
        if (choice.delta.tool_calls) |calls| {
            for (calls) |call| {
                try self.appendTool(call.index, call.id, call.function);
            }
        }
        if (choice.finish_reason) |reason| self.finish_value = try finish(self.allocator, reason);
    }

    fn appendText(self: *StreamDecoder, kind: enum { text, thinking }, delta: []const u8) !void {
        var part_index: usize = undefined;
        if (self.parts.items.len > 0 and switch (self.parts.items[self.parts.items.len - 1]) {
            .text => kind == .text,
            .thinking => kind == .thinking,
            .tool_call => false,
        }) {
            part_index = self.parts.items.len - 1;
        } else {
            if (self.parts.items.len >= max_parts) return error.InvalidProviderResponse;
            part_index = self.parts.items.len;
            try self.parts.append(
                self.allocator,
                if (kind == .text) .{ .text = .empty } else .{ .thinking = .empty },
            );
            if (self.sink) |event_sink| try event_sink.emit(.{ .part_start = .{
                .index = part_index,
                .part = if (kind == .text) .text else .thinking,
            } });
        }
        switch (self.parts.items[part_index]) {
            .text => |*text| try text.appendSlice(self.allocator, delta),
            .thinking => |*text| try text.appendSlice(self.allocator, delta),
            .tool_call => unreachable,
        }
        if (self.sink) |event_sink| try event_sink.emit(.{ .part_delta = .{
            .index = part_index,
            .delta = if (kind == .text) .{ .text = delta } else .{ .thinking = delta },
        } });
    }

    fn appendTool(self: *StreamDecoder, wire_index: usize, id: ?[]const u8, function: anytype) !void {
        if (wire_index >= self.tool_parts.len) return error.InvalidProviderResponse;
        const part_index = self.tool_parts[wire_index] orelse create: {
            if (self.parts.items.len >= max_parts) return error.InvalidProviderResponse;
            const next = self.parts.items.len;
            try self.parts.append(self.allocator, .{ .tool_call = .{} });
            self.tool_parts[wire_index] = next;
            if (self.sink) |event_sink| try event_sink.emit(.{ .part_start = .{
                .index = next,
                .part = .{ .tool_call = .{
                    .id = id,
                    .name = if (function) |value| value.name else null,
                } },
            } });
            break :create next;
        };
        const tool = &self.parts.items[part_index].tool_call;
        if (id) |value| try tool.id.appendSlice(self.allocator, value);
        var name: ?[]const u8 = null;
        var arguments: []const u8 = "";
        if (function) |value| {
            name = value.name;
            arguments = value.arguments orelse "";
            if (name) |text| try tool.name.appendSlice(self.allocator, text);
            if (arguments.len > max_tool_arguments_bytes -| tool.arguments.items.len) {
                return error.InvalidProviderResponse;
            }
            try tool.arguments.appendSlice(self.allocator, arguments);
        }
        if (self.sink) |event_sink| try event_sink.emit(.{ .part_delta = .{
            .index = part_index,
            .delta = .{ .tool_call = .{
                .id = id,
                .name = name,
                .arguments_delta = arguments,
            } },
        } });
    }
};

fn writeUserContent(
    writer: *std.Io.Writer,
    content: message.UserContent,
    wrote: *bool,
) failure.ModelError!void {
    switch (content) {
        .text => |text| try writeRoleText(writer, "user", text, wrote),
        .image => return error.UnsupportedCapability,
    }
}

fn writeRoleText(writer: *std.Io.Writer, role: []const u8, text: []const u8, wrote: *bool) failure.ModelError!void {
    if (wrote.*) writer.writeByte(',') catch return error.OutOfMemory;
    wrote.* = true;
    writer.writeAll("{\"role\":") catch return error.OutOfMemory;
    writeJson(writer, role) catch return error.OutOfMemory;
    writer.writeAll(",\"content\":") catch return error.OutOfMemory;
    writeJson(writer, text) catch return error.OutOfMemory;
    writer.writeByte('}') catch return error.OutOfMemory;
}

fn writeToolResult(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    result: message.ToolResult,
    wrote: *bool,
) failure.ModelError!void {
    if (wrote.*) writer.writeByte(',') catch return error.OutOfMemory;
    wrote.* = true;
    var content: std.Io.Writer.Allocating = .init(allocator);
    defer content.deinit();
    for (result.content, 0..) |part, index| switch (part) {
        .text => |text| {
            if (index > 0) content.writer.writeByte('\n') catch return error.OutOfMemory;
            content.writer.writeAll(text) catch return error.OutOfMemory;
        },
        .image => return error.UnsupportedCapability,
    };
    writer.writeAll("{\"role\":\"tool\",\"tool_call_id\":") catch return error.OutOfMemory;
    writeJson(writer, result.call_id) catch return error.OutOfMemory;
    writer.writeAll(",\"content\":") catch return error.OutOfMemory;
    writeJson(writer, content.written()) catch return error.OutOfMemory;
    writer.writeByte('}') catch return error.OutOfMemory;
}

fn writeAssistant(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    response: message.ResponseMessage,
    wrote: *bool,
) failure.ModelError!void {
    if (wrote.*) writer.writeByte(',') catch return error.OutOfMemory;
    wrote.* = true;
    var text: std.Io.Writer.Allocating = .init(allocator);
    defer text.deinit();
    var tool_count: usize = 0;
    for (response.parts) |part| switch (part) {
        .text => |value| text.writer.writeAll(value.text) catch return error.OutOfMemory,
        .thinking => {},
        .tool_call => tool_count += 1,
    };
    writer.writeAll("{\"role\":\"assistant\",\"content\":") catch return error.OutOfMemory;
    if (text.written().len > 0) {
        writeJson(writer, text.written()) catch return error.OutOfMemory;
    } else {
        writer.writeAll("null") catch return error.OutOfMemory;
    }
    if (tool_count > 0) {
        writer.writeAll(",\"tool_calls\":[") catch return error.OutOfMemory;
        var index: usize = 0;
        for (response.parts) |part| switch (part) {
            .tool_call => |call| {
                validateJson(allocator, call.arguments_json) catch |validation_failure| switch (validation_failure) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidJson => return error.InvalidRequest,
                };
                if (index > 0) writer.writeByte(',') catch return error.OutOfMemory;
                writer.writeAll("{\"id\":") catch return error.OutOfMemory;
                writeJson(writer, call.id) catch return error.OutOfMemory;
                writer.writeAll(",\"type\":\"function\",\"function\":{\"name\":") catch return error.OutOfMemory;
                writeJson(writer, call.name) catch return error.OutOfMemory;
                writer.writeAll(",\"arguments\":") catch return error.OutOfMemory;
                writeJson(writer, call.arguments_json) catch return error.OutOfMemory;
                writer.writeAll("}}") catch return error.OutOfMemory;
                index += 1;
            },
            else => {},
        };
        writer.writeByte(']') catch return error.OutOfMemory;
    }
    writer.writeByte('}') catch return error.OutOfMemory;
}

fn writeJson(writer: *std.Io.Writer, value: anytype) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

test "Chat buffered and streamed usage separates uncached reads and writes" {
    const identity: message.ModelIdentity = .{ .provider = "openai", .model = "chat" };
    const buffered =
        "{\"choices\":[{\"message\":{\"content\":\"ok\"},\"finish_reason\":\"stop\"}]," ++
        "\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":3," ++
        "\"prompt_tokens_details\":{\"cached_tokens\":2,\"cache_write_tokens\":1}}}";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const decoded = try decodeResponse(arena.allocator(), identity, buffered);
    try std.testing.expectEqual(@as(u64, 2), decoded.usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 2), decoded.usage.cached_input_tokens);
    try std.testing.expectEqual(@as(u64, 1), decoded.usage.cache_write_tokens);
    try std.testing.expectEqual(@as(u64, 3), decoded.usage.output_tokens);

    var decoder = StreamDecoder.init(arena.allocator(), std.testing.allocator, identity, null);
    defer decoder.deinit();
    const sink = decoder.bodySink();
    try sink.start(.{ .status = 200 });
    try sink.chunk(
        "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"},\"finish_reason\":\"stop\"}]}\n\n" ++
            "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":3," ++
            "\"prompt_tokens_details\":{\"cached_tokens\":2,\"cache_write_tokens\":1}}}\n\n" ++
            "data: [DONE]\n\n",
    );
    const streamed = try decoder.result();
    try std.testing.expectEqual(@as(u64, 2), streamed.usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 2), streamed.usage.cached_input_tokens);
    try std.testing.expectEqual(@as(u64, 1), streamed.usage.cache_write_tokens);
    try std.testing.expectEqual(@as(u64, 3), streamed.usage.output_tokens);
}

fn duplicate(allocator: std.mem.Allocator, value: []const u8) failure.ModelError![]const u8 {
    return allocator.dupe(u8, value) catch return error.OutOfMemory;
}

const JsonValidationError = error{ OutOfMemory, InvalidJson };

fn validateJson(allocator: std.mem.Allocator, value: []const u8) JsonValidationError!void {
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        value,
        .{},
    ) catch |parse_failure| switch (parse_failure) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    defer parsed.deinit();
}

fn finish(
    allocator: std.mem.Allocator,
    value: []const u8,
) failure.ModelError!usage_api.Finish {
    return .{
        .category = if (std.mem.eql(u8, value, "stop"))
            .stop
        else if (std.mem.eql(u8, value, "tool_calls"))
            .tool_calls
        else if (std.mem.eql(u8, value, "length"))
            .length
        else if (std.mem.eql(u8, value, "content_filter"))
            .content_filter
        else
            .unknown,
        .raw_reason = try duplicate(allocator, value),
    };
}

fn statusError(status: u16) failure.ModelError {
    return switch (status) {
        401, 403 => error.ProviderRejectedRequest,
        429 => error.RateLimited,
        500, 502, 503, 504 => error.ProviderUnavailable,
        else => error.ProviderRejectedRequest,
    };
}

fn streamError(value: stream.StreamSinkError) failure.ModelError {
    return switch (value) {
        error.OutOfMemory => error.OutOfMemory,
        error.Cancelled => error.Cancelled,
        error.ConsumerStopped => error.StreamConsumerStopped,
    };
}
