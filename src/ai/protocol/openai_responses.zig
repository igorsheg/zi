const std = @import("std");
const failure = @import("../failure.zig");
const message = @import("../message.zig");
const model = @import("../model.zig");
const sse = @import("sse.zig");
const stream = @import("../stream.zig");
const transport = @import("../transport.zig");
const usage_api = @import("../usage.zig");

const max_parts = 256;
const max_tool_arguments_bytes = 1024 * 1024;

pub fn encodeCodexRequest(
    allocator: std.mem.Allocator,
    model_id: []const u8,
    request: model.ModelRequest,
) failure.ModelError![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;

    writer.writeAll("{\"model\":") catch return error.OutOfMemory;
    writeJson(writer, model_id) catch return error.OutOfMemory;
    writer.writeAll(",\"store\":false,\"stream\":true,\"instructions\":") catch return error.OutOfMemory;
    if (request.instructions.len == 0) {
        writeJson(writer, "You are a helpful assistant.") catch return error.OutOfMemory;
    } else {
        var instructions: std.Io.Writer.Allocating = .init(allocator);
        defer instructions.deinit();
        for (request.instructions, 0..) |instruction, index| {
            if (index > 0) instructions.writer.writeByte('\n') catch return error.OutOfMemory;
            instructions.writer.writeAll(instruction) catch return error.OutOfMemory;
        }
        writeJson(writer, instructions.written()) catch return error.OutOfMemory;
    }
    writer.writeAll(",\"input\":[") catch return error.OutOfMemory;
    var wrote = false;
    for (request.messages) |entry| switch (entry) {
        .request => |request_message| for (request_message.parts) |part| switch (part) {
            .user => |content| switch (content) {
                .text => |text| try writeRoleText(writer, "user", "input_text", text, &wrote),
                .image => return error.UnsupportedCapability,
            },
            .retry_prompt => |text| try writeRoleText(writer, "user", "input_text", text, &wrote),
            .tool_result => |result| try writeToolResult(allocator, writer, result, &wrote),
        },
        .response => |response| for (response.parts) |part| switch (part) {
            .text => |text| try writeRoleText(writer, "assistant", "output_text", text.text, &wrote),
            .thinking => |thinking| try writeReasoningState(writer, thinking, &wrote),
            .tool_call => |call| try writeToolCall(allocator, writer, call, &wrote),
        },
    };
    writer.writeAll("],\"text\":{\"verbosity\":\"low\"},\"include\":[\"reasoning.encrypted_content\"],") catch
        return error.OutOfMemory;
    writer.writeAll("\"tool_choice\":\"auto\",\"parallel_tool_calls\":true") catch return error.OutOfMemory;
    if (request.settings.temperature) |value| {
        writer.print(",\"temperature\":{d}", .{value}) catch return error.OutOfMemory;
    }
    if (request.settings.reasoning_effort) |effort| {
        writer.writeAll(",\"reasoning\":{\"effort\":") catch return error.OutOfMemory;
        writeJson(writer, @tagName(effort)) catch return error.OutOfMemory;
        writer.writeAll(",\"summary\":\"auto\"}") catch return error.OutOfMemory;
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
            writer.writeAll("{\"type\":\"function\",\"name\":") catch return error.OutOfMemory;
            writeJson(writer, tool.name) catch return error.OutOfMemory;
            writer.writeAll(",\"description\":") catch return error.OutOfMemory;
            writeJson(writer, tool.description) catch return error.OutOfMemory;
            writer.writeAll(",\"parameters\":") catch return error.OutOfMemory;
            writer.writeAll(tool.parameters_json_schema) catch return error.OutOfMemory;
            writer.writeAll(",\"strict\":false}") catch return error.OutOfMemory;
        }
        writer.writeByte(']') catch return error.OutOfMemory;
    }
    writer.writeByte('}') catch return error.OutOfMemory;
    return output.toOwnedSlice() catch return error.OutOfMemory;
}

pub const StreamDecoder = struct {
    allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    identity: message.ModelIdentity,
    sink: ?stream.StreamSink,
    parser: sse.Parser,
    parts: std.ArrayList(Part) = .empty,
    output_parts: [max_parts]?usize = @splat(null),
    current_output: ?usize = null,
    usage: usage_api.Usage = .{},
    finish_value: usage_api.Finish = .{},
    status: u16 = 0,
    terminal: bool = false,
    failure_value: ?failure.ModelError = null,
    error_body: std.ArrayList(u8) = .empty,

    const Part = union(enum) {
        text: std.ArrayList(u8),
        thinking: Thinking,
        tool_call: Tool,
    };

    const Thinking = struct {
        text: std.ArrayList(u8) = .empty,
        item_id: ?[]const u8 = null,
        encrypted_content: ?[]const u8 = null,
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
            .thinking => |*thinking| {
                thinking.text.deinit(self.allocator);
                if (thinking.item_id) |value| self.allocator.free(value);
                if (thinking.encrypted_content) |value| self.allocator.free(value);
            },
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

    pub fn bodySink(self: *StreamDecoder) transport.BodySink {
        return .{ .context = self, .start_fn = startBody, .chunk_fn = chunkBody };
    }

    pub fn result(self: *StreamDecoder) failure.ModelError!message.ResponseMessage {
        if (self.failure_value) |value| return value;
        if (self.status < 200 or self.status >= 300) return statusError(self.status);
        if (!self.terminal) {
            const event_sink_type = EventSinkType();
            var event_sink: event_sink_type = .{ .decoder = self };
            self.parser.finish(&event_sink) catch |decode_failure| return switch (decode_failure) {
                error.OutOfMemory => error.OutOfMemory,
                error.Cancelled => error.Cancelled,
                error.ConsumerStopped => error.StreamConsumerStopped,
                else => error.InvalidProviderResponse,
            };
        }
        if (!self.terminal) return error.StreamInterrupted;

        var response_parts: std.ArrayList(message.ResponsePart) = .empty;
        for (self.parts.items, 0..) |part, index| {
            const completed: message.ResponsePart = switch (part) {
                .text => |text| .{ .text = .{ .text = try duplicate(self.allocator, text.items) } },
                .thinking => |thinking| .{ .thinking = .{
                    .text = try duplicate(self.allocator, thinking.text.items),
                    .provider_state = try self.reasoningState(thinking),
                } },
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
            response_parts.append(self.allocator, completed) catch return error.OutOfMemory;
            if (self.sink) |event_sink| event_sink.emit(.{ .part_end = .{
                .index = index,
                .part = completed,
            } }) catch |sink_failure| {
                return streamError(sink_failure);
            };
        }
        return .{
            .parts = response_parts.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
            .identity = self.identity,
            .usage = self.usage,
            .finish = self.finish_value,
        };
    }

    fn startBody(context: *anyopaque, head: transport.ResponseHead) transport.SinkError!void {
        const self: *StreamDecoder = @ptrCast(@alignCast(context));
        self.status = head.status;
    }

    fn chunkBody(context: *anyopaque, bytes: []const u8) transport.SinkError!void {
        const self: *StreamDecoder = @ptrCast(@alignCast(context));
        if (self.status < 200 or self.status >= 300) {
            if (bytes.len <= 2048 -| self.error_body.items.len) {
                self.error_body.appendSlice(self.scratch_allocator, bytes) catch return error.OutOfMemory;
            }
            return;
        }
        const event_sink_type = EventSinkType();
        var event_sink: event_sink_type = .{ .decoder = self };
        self.parser.feed(bytes, &event_sink) catch |decode_failure| {
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
        if (self.terminal) return error.ConsumerStopped;
    }

    fn EventSinkType() type {
        return struct {
            const Self = @This();
            decoder: *StreamDecoder,

            pub fn emit(self: *Self, event: sse.Event) !void {
                try self.decoder.applyEvent(event);
            }
        };
    }

    fn applyEvent(self: *StreamDecoder, event: sse.Event) !void {
        const data = std.mem.trim(u8, event.data, " \t\r\n");
        if (std.mem.eql(u8, data, "[DONE]")) return;
        const WireEvent = struct {
            type: []const u8,
            output_index: ?usize = null,
            delta: ?[]const u8 = null,
            item: ?struct {
                type: []const u8,
                id: ?[]const u8 = null,
                call_id: ?[]const u8 = null,
                name: ?[]const u8 = null,
                arguments: ?[]const u8 = null,
                encrypted_content: ?[]const u8 = null,
                content: []const struct {
                    type: []const u8,
                    text: ?[]const u8 = null,
                } = &.{},
            } = null,
            part: ?struct {
                type: []const u8,
                text: ?[]const u8 = null,
            } = null,
            response: ?struct {
                status: ?[]const u8 = null,
                incomplete_details: ?struct { reason: ?[]const u8 = null } = null,
                usage: ?struct {
                    input_tokens: u64 = 0,
                    output_tokens: u64 = 0,
                    input_tokens_details: ?struct { cached_tokens: u64 = 0 } = null,
                    output_tokens_details: ?struct { reasoning_tokens: u64 = 0 } = null,
                } = null,
            } = null,
        };
        var scratch = std.heap.ArenaAllocator.init(self.scratch_allocator);
        defer scratch.deinit();
        var parsed = try std.json.parseFromSlice(WireEvent, scratch.allocator(), data, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const wire = parsed.value;

        if (std.mem.eql(u8, wire.type, "response.output_item.added")) {
            const item = wire.item orelse return error.InvalidProviderResponse;
            const output_index = wire.output_index orelse self.firstFreeOutput();
            self.current_output = output_index;
            if (std.mem.eql(u8, item.type, "reasoning")) {
                const part_index = try self.ensurePart(output_index, .thinking, null, null);
                if (item.id) |id| try self.setReasoningId(part_index, id);
            } else if (std.mem.eql(u8, item.type, "function_call")) {
                _ = try self.ensurePart(output_index, .tool_call, item.call_id orelse item.id, item.name);
            }
            return;
        }
        if (std.mem.eql(u8, wire.type, "response.content_part.added")) {
            const part = wire.part orelse return error.InvalidProviderResponse;
            if (std.mem.eql(u8, part.type, "output_text")) {
                const output_index = wire.output_index orelse self.current_output orelse self.firstFreeOutput();
                _ = try self.ensurePart(output_index, .text, null, null);
            }
            return;
        }
        if (std.mem.eql(u8, wire.type, "response.output_text.delta")) {
            const delta = wire.delta orelse return;
            const output_index = wire.output_index orelse self.current_output orelse self.firstFreeOutput();
            const part_index = try self.ensurePart(output_index, .text, null, null);
            try self.parts.items[part_index].text.appendSlice(self.allocator, delta);
            try self.emitDelta(part_index, .{ .text = delta });
            return;
        }
        if (std.mem.eql(u8, wire.type, "response.reasoning_summary_text.delta")) {
            const delta = wire.delta orelse return;
            const output_index = wire.output_index orelse self.current_output orelse self.firstFreeOutput();
            const part_index = try self.ensurePart(output_index, .thinking, null, null);
            try self.parts.items[part_index].thinking.text.appendSlice(self.allocator, delta);
            try self.emitDelta(part_index, .{ .thinking = delta });
            return;
        }
        if (std.mem.eql(u8, wire.type, "response.function_call_arguments.delta")) {
            const delta = wire.delta orelse return;
            const output_index = wire.output_index orelse self.current_output orelse
                return error.InvalidProviderResponse;
            const part_index = try self.ensurePart(output_index, .tool_call, null, null);
            const tool = &self.parts.items[part_index].tool_call;
            if (delta.len > max_tool_arguments_bytes -| tool.arguments.items.len) {
                return error.InvalidProviderResponse;
            }
            try tool.arguments.appendSlice(self.allocator, delta);
            try self.emitDelta(part_index, .{ .tool_call = .{ .arguments_delta = delta } });
            return;
        }
        if (std.mem.eql(u8, wire.type, "response.output_item.done")) {
            const item = wire.item orelse return error.InvalidProviderResponse;
            const output_index = wire.output_index orelse self.current_output orelse self.firstFreeOutput();
            if (std.mem.eql(u8, item.type, "function_call")) {
                const part_index = try self.ensurePart(
                    output_index,
                    .tool_call,
                    item.call_id orelse item.id,
                    item.name,
                );
                const tool = &self.parts.items[part_index].tool_call;
                if (item.arguments) |arguments| if (tool.arguments.items.len == 0) {
                    if (arguments.len > max_tool_arguments_bytes) return error.InvalidProviderResponse;
                    try tool.arguments.appendSlice(self.allocator, arguments);
                };
            } else if (std.mem.eql(u8, item.type, "reasoning")) {
                const part_index = try self.ensurePart(output_index, .thinking, null, null);
                if (item.id) |id| try self.setReasoningId(part_index, id);
                if (item.encrypted_content) |encrypted| {
                    const thinking = &self.parts.items[part_index].thinking;
                    if (thinking.encrypted_content == null) {
                        thinking.encrypted_content = try duplicate(self.allocator, encrypted);
                    }
                }
            } else if (std.mem.eql(u8, item.type, "message")) {
                for (item.content) |content| if (std.mem.eql(u8, content.type, "output_text")) {
                    const part_index = try self.ensurePart(output_index, .text, null, null);
                    if (self.parts.items[part_index].text.items.len == 0) if (content.text) |text| {
                        try self.parts.items[part_index].text.appendSlice(self.allocator, text);
                    };
                };
            }
            return;
        }
        if (std.mem.eql(u8, wire.type, "response.completed") or
            std.mem.eql(u8, wire.type, "response.incomplete"))
        {
            const response = wire.response orelse return error.InvalidProviderResponse;
            if (response.usage) |value| {
                self.usage = .{
                    .input_tokens = value.input_tokens,
                    .output_tokens = value.output_tokens,
                    .cached_input_tokens = if (value.input_tokens_details) |details| details.cached_tokens else 0,
                    .reasoning_tokens = if (value.output_tokens_details) |details| details.reasoning_tokens else 0,
                };
                if (self.sink) |event_sink| try event_sink.emit(.{ .usage = self.usage });
            }
            if (std.mem.eql(u8, wire.type, "response.incomplete") or
                (response.status != null and std.mem.eql(u8, response.status.?, "incomplete")))
            {
                const reason = if (response.incomplete_details) |details| details.reason else null;
                self.finish_value = .{
                    .category = .length,
                    .raw_reason = if (reason) |value| try duplicate(self.allocator, value) else null,
                };
            } else {
                self.finish_value = .{ .category = if (hasTools(self.parts.items)) .tool_calls else .stop };
            }
            self.terminal = true;
        }
    }

    const PartKind = enum { text, thinking, tool_call };

    fn ensurePart(
        self: *StreamDecoder,
        output_index: usize,
        kind: PartKind,
        id: ?[]const u8,
        name: ?[]const u8,
    ) !usize {
        if (output_index >= self.output_parts.len) return error.InvalidProviderResponse;
        if (self.output_parts[output_index]) |part_index| return part_index;
        if (self.parts.items.len >= max_parts) return error.InvalidProviderResponse;
        const part_index = self.parts.items.len;
        try self.parts.append(self.allocator, switch (kind) {
            .text => .{ .text = .empty },
            .thinking => .{ .thinking = .{} },
            .tool_call => .{ .tool_call = .{} },
        });
        self.output_parts[output_index] = part_index;
        if (kind == .tool_call) {
            const tool = &self.parts.items[part_index].tool_call;
            if (id) |value| try tool.id.appendSlice(self.allocator, value);
            if (name) |value| try tool.name.appendSlice(self.allocator, value);
        }
        if (self.sink) |event_sink| try event_sink.emit(.{ .part_start = .{
            .index = part_index,
            .part = switch (kind) {
                .text => .text,
                .thinking => .thinking,
                .tool_call => .{ .tool_call = .{ .id = id, .name = name } },
            },
        } });
        return part_index;
    }

    fn emitDelta(self: *StreamDecoder, index: usize, delta: stream.ResponsePartDelta) !void {
        if (self.sink) |event_sink| try event_sink.emit(.{ .part_delta = .{ .index = index, .delta = delta } });
    }

    fn setReasoningId(self: *StreamDecoder, part_index: usize, id: []const u8) !void {
        const thinking = &self.parts.items[part_index].thinking;
        if (thinking.item_id == null) thinking.item_id = try duplicate(self.allocator, id);
    }

    fn reasoningState(
        self: *StreamDecoder,
        thinking: Thinking,
    ) failure.ModelError!?message.ProviderState {
        const encrypted = thinking.encrypted_content orelse return null;
        const item_id = thinking.item_id orelse return error.InvalidProviderResponse;
        var value: std.json.ObjectMap = .empty;
        value.put(self.allocator, "type", .{ .string = "reasoning" }) catch return error.OutOfMemory;
        value.put(self.allocator, "id", .{
            .string = try duplicate(self.allocator, item_id),
        }) catch return error.OutOfMemory;
        value.put(self.allocator, "summary", .{
            .array = std.json.Array.init(self.allocator),
        }) catch return error.OutOfMemory;
        value.put(self.allocator, "encrypted_content", .{
            .string = try duplicate(self.allocator, encrypted),
        }) catch return error.OutOfMemory;
        return .{
            .provider = self.identity.provider,
            .protocol = "openai-codex-responses",
            .value = .{ .object = value },
        };
    }

    fn firstFreeOutput(self: *StreamDecoder) usize {
        for (self.output_parts, 0..) |part, index| if (part == null) return index;
        return self.output_parts.len;
    }
};

fn writeReasoningState(
    writer: *std.Io.Writer,
    thinking: message.ThinkingPart,
    wrote: *bool,
) failure.ModelError!void {
    const state = thinking.provider_state orelse return;
    if (!std.mem.eql(u8, state.provider, "openai-codex") or
        !std.mem.eql(u8, state.protocol, "openai-codex-responses")) return;
    if (state.value != .object) return error.InvalidRequest;
    const kind = state.value.object.get("type") orelse return error.InvalidRequest;
    const item_id = state.value.object.get("id") orelse return error.InvalidRequest;
    const encrypted = state.value.object.get("encrypted_content") orelse return error.InvalidRequest;
    if (kind != .string or !std.mem.eql(u8, kind.string, "reasoning")) return error.InvalidRequest;
    if (item_id != .string or item_id.string.len == 0) return error.InvalidRequest;
    if (encrypted != .string or encrypted.string.len == 0) return error.InvalidRequest;
    if (wrote.*) writer.writeByte(',') catch return error.OutOfMemory;
    wrote.* = true;
    writeJson(writer, state.value) catch return error.OutOfMemory;
}

fn writeRoleText(
    writer: *std.Io.Writer,
    role: []const u8,
    content_type: []const u8,
    text: []const u8,
    wrote: *bool,
) failure.ModelError!void {
    if (wrote.*) writer.writeByte(',') catch return error.OutOfMemory;
    wrote.* = true;
    writer.writeAll("{\"role\":") catch return error.OutOfMemory;
    writeJson(writer, role) catch return error.OutOfMemory;
    writer.writeAll(",\"content\":[{\"type\":") catch return error.OutOfMemory;
    writeJson(writer, content_type) catch return error.OutOfMemory;
    writer.writeAll(",\"text\":") catch return error.OutOfMemory;
    writeJson(writer, text) catch return error.OutOfMemory;
    writer.writeAll("}]}") catch return error.OutOfMemory;
}

fn writeToolCall(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    call: message.ToolCall,
    wrote: *bool,
) failure.ModelError!void {
    validateJson(allocator, call.arguments_json) catch |validation_failure| switch (validation_failure) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidJson => return error.InvalidRequest,
    };
    if (wrote.*) writer.writeByte(',') catch return error.OutOfMemory;
    wrote.* = true;
    writer.writeAll("{\"type\":\"function_call\",\"call_id\":") catch return error.OutOfMemory;
    writeJson(writer, call.id) catch return error.OutOfMemory;
    writer.writeAll(",\"name\":") catch return error.OutOfMemory;
    writeJson(writer, call.name) catch return error.OutOfMemory;
    writer.writeAll(",\"arguments\":") catch return error.OutOfMemory;
    writeJson(writer, call.arguments_json) catch return error.OutOfMemory;
    writer.writeByte('}') catch return error.OutOfMemory;
}

fn writeToolResult(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    result: message.ToolResult,
    wrote: *bool,
) failure.ModelError!void {
    var text: std.Io.Writer.Allocating = .init(allocator);
    defer text.deinit();
    for (result.content, 0..) |content, index| switch (content) {
        .text => |value| {
            if (index > 0) text.writer.writeByte('\n') catch return error.OutOfMemory;
            text.writer.writeAll(value) catch return error.OutOfMemory;
        },
        .image => return error.UnsupportedCapability,
    };
    if (wrote.*) writer.writeByte(',') catch return error.OutOfMemory;
    wrote.* = true;
    writer.writeAll("{\"type\":\"function_call_output\",\"call_id\":") catch return error.OutOfMemory;
    writeJson(writer, result.call_id) catch return error.OutOfMemory;
    writer.writeAll(",\"output\":") catch return error.OutOfMemory;
    writeJson(writer, text.written()) catch return error.OutOfMemory;
    writer.writeByte('}') catch return error.OutOfMemory;
}

fn writeJson(writer: *std.Io.Writer, value: anytype) !void {
    try std.json.Stringify.value(value, .{}, writer);
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

fn duplicate(allocator: std.mem.Allocator, value: []const u8) failure.ModelError![]const u8 {
    return allocator.dupe(u8, value) catch return error.OutOfMemory;
}

fn hasTools(parts: []const StreamDecoder.Part) bool {
    for (parts) |part| if (part == .tool_call) return true;
    return false;
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
