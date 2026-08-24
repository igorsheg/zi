const std = @import("std");
const failure = @import("../failure.zig");
const message = @import("../message.zig");
const model = @import("../model.zig");
const settings = @import("../settings.zig");
const sse = @import("sse.zig");
const stream = @import("../stream.zig");
const transport = @import("../transport.zig");
const usage_api = @import("../usage.zig");

const max_parts = 256;
const max_tool_arguments_bytes = 1024 * 1024;

pub fn encodeRequest(
    allocator: std.mem.Allocator,
    identity: message.ModelIdentity,
    profile: settings.ModelProfile,
    request: model.ModelRequest,
) failure.ModelError![]const u8 {
    return encode(allocator, identity, profile, request, .openai);
}

pub fn encodeCodexRequest(
    allocator: std.mem.Allocator,
    identity: message.ModelIdentity,
    profile: settings.ModelProfile,
    request: model.ModelRequest,
) failure.ModelError![]const u8 {
    return encode(allocator, identity, profile, request, .codex);
}

const Flavor = enum {
    openai,
    codex,

    fn inheritedThinkingOffValue(_: Flavor) []const u8 {
        return "none";
    }
};

fn encode(
    allocator: std.mem.Allocator,
    identity: message.ModelIdentity,
    profile: settings.ModelProfile,
    request: model.ModelRequest,
    flavor: Flavor,
) failure.ModelError![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;

    writer.writeAll("{\"model\":") catch return error.OutOfMemory;
    writeJson(writer, identity.model) catch return error.OutOfMemory;
    writer.writeAll(",\"store\":false,\"stream\":true") catch return error.OutOfMemory;
    if (flavor == .codex) {
        writer.writeAll(",\"instructions\":") catch return error.OutOfMemory;
        try writeInstructions(allocator, writer, request.instructions, true);
    }
    writer.writeAll(",\"input\":[") catch return error.OutOfMemory;
    var wrote = false;
    if (flavor == .openai and request.instructions.len > 0) {
        var instructions: std.Io.Writer.Allocating = .init(allocator);
        defer instructions.deinit();
        try joinInstructions(&instructions.writer, request.instructions);
        try writeRoleText(writer, "developer", "input_text", instructions.written(), &wrote);
    }
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
            .text => |text| try writeAssistantText(
                writer,
                identity,
                response.identity,
                if (flavor == .codex) "openai-codex-responses" else "openai-responses",
                text,
                &wrote,
            ),
            .thinking => |thinking| try writeReasoningState(
                writer,
                identity,
                response.identity,
                if (flavor == .codex) "openai-codex-responses" else "openai-responses",
                thinking,
                &wrote,
            ),
            .tool_call => |call| try writeToolCall(
                allocator,
                writer,
                identity,
                response.identity,
                if (flavor == .codex) "openai-codex-responses" else "openai-responses",
                call,
                &wrote,
            ),
        },
    };
    writer.writeByte(']') catch return error.OutOfMemory;
    if (flavor == .codex) {
        writer.writeAll(",\"text\":{\"verbosity\":\"low\"}") catch return error.OutOfMemory;
        writer.writeAll(",\"include\":[\"reasoning.encrypted_content\"]") catch return error.OutOfMemory;
        writer.writeAll(",\"tool_choice\":\"auto\",\"parallel_tool_calls\":true") catch
            return error.OutOfMemory;
    }
    if (request.settings.temperature) |value| {
        writer.print(",\"temperature\":{d}", .{value}) catch return error.OutOfMemory;
    }
    if (flavor == .openai) if (request.settings.max_output_tokens) |value| {
        writer.print(",\"max_output_tokens\":{}", .{@max(value, 16)}) catch return error.OutOfMemory;
    };
    if (profile.thinking != null) if (profile.thinkingWireValue(
        request.settings.thinking_level,
        flavor.inheritedThinkingOffValue(),
    )) |effort| {
        writer.writeAll(",\"reasoning\":{\"effort\":") catch return error.OutOfMemory;
        writeJson(writer, effort) catch return error.OutOfMemory;
        writer.writeAll(",\"summary\":\"auto\"}") catch return error.OutOfMemory;
        if (flavor == .openai) {
            writer.writeAll(",\"include\":[\"reasoning.encrypted_content\"]") catch
                return error.OutOfMemory;
        }
    };
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

fn writeInstructions(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    instructions: []const []const u8,
    default_when_empty: bool,
) failure.ModelError!void {
    if (instructions.len == 0 and default_when_empty) {
        writeJson(writer, "You are a helpful assistant.") catch return error.OutOfMemory;
        return;
    }
    var joined: std.Io.Writer.Allocating = .init(allocator);
    defer joined.deinit();
    try joinInstructions(&joined.writer, instructions);
    writeJson(writer, joined.written()) catch return error.OutOfMemory;
}

fn joinInstructions(writer: *std.Io.Writer, instructions: []const []const u8) failure.ModelError!void {
    for (instructions, 0..) |instruction, index| {
        if (index > 0) writer.writeByte('\n') catch return error.OutOfMemory;
        writer.writeAll(instruction) catch return error.OutOfMemory;
    }
}

pub const StreamDecoder = struct {
    // The model result arena owns transient state and any finalized response, including failed finalization.
    allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    identity: message.ModelIdentity,
    protocol_id: []const u8,
    sink: ?stream.StreamSink,
    parser: sse.Parser,
    parts: std.ArrayList(Part) = .empty,
    output_parts: [max_parts]?usize = @splat(null),
    current_output: ?usize = null,
    usage: usage_api.Usage = .{},
    finish_value: usage_api.Finish = .{},
    status: u16 = 0,
    response_metadata: transport.ResponseMetadata = .{},
    terminal: bool = false,
    failure_value: ?failure.ModelError = null,
    error_body: std.ArrayList(u8) = .empty,

    const Part = union(enum) {
        text: Text,
        thinking: Thinking,
        tool_call: Tool,
    };

    const Text = struct {
        text: std.ArrayList(u8) = .empty,
        item_id: ?[]const u8 = null,
        phase: ?[]const u8 = null,
    };

    const Thinking = struct {
        text: std.ArrayList(u8) = .empty,
        item_id: ?[]const u8 = null,
        encrypted_content: ?[]const u8 = null,
    };

    const Tool = struct {
        id: std.ArrayList(u8) = .empty,
        item_id: ?[]const u8 = null,
        name: std.ArrayList(u8) = .empty,
        arguments: std.ArrayList(u8) = .empty,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        scratch_allocator: std.mem.Allocator,
        identity: message.ModelIdentity,
        protocol_id: []const u8,
        sink: ?stream.StreamSink,
    ) StreamDecoder {
        return .{
            .allocator = allocator,
            .scratch_allocator = scratch_allocator,
            .identity = identity,
            .protocol_id = protocol_id,
            .sink = sink,
            .parser = sse.Parser.init(scratch_allocator, .{}),
        };
    }

    pub fn deinit(self: *StreamDecoder) void {
        self.parser.deinit();
        for (self.parts.items) |*part| switch (part.*) {
            .text => |*text| {
                text.text.deinit(self.allocator);
                if (text.item_id) |value| self.allocator.free(value);
                if (text.phase) |value| self.allocator.free(value);
            },
            .thinking => |*thinking| {
                thinking.text.deinit(self.allocator);
                if (thinking.item_id) |value| self.allocator.free(value);
                if (thinking.encrypted_content) |value| self.allocator.free(value);
            },
            .tool_call => |*tool| {
                tool.id.deinit(self.allocator);
                if (tool.item_id) |value| self.allocator.free(value);
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
                .text => |text| .{ .text = .{
                    .text = try duplicate(self.allocator, text.text.items),
                    .provider_state = try self.textState(text),
                } },
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
                        .provider_state = try self.toolState(tool),
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
        self.response_metadata = head.metadata;
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
        const WireContent = struct {
            type: []const u8,
            text: ?[]const u8 = null,
            refusal: ?[]const u8 = null,
        };
        const WireItem = struct {
            type: []const u8,
            id: ?[]const u8 = null,
            call_id: ?[]const u8 = null,
            name: ?[]const u8 = null,
            arguments: ?[]const u8 = null,
            encrypted_content: ?[]const u8 = null,
            phase: ?[]const u8 = null,
            summary: []const WireContent = &.{},
            content: []const WireContent = &.{},
        };
        const WireEvent = struct {
            type: []const u8,
            output_index: ?usize = null,
            delta: ?[]const u8 = null,
            arguments: ?[]const u8 = null,
            item: ?WireItem = null,
            part: ?WireContent = null,
            response: ?struct {
                status: ?[]const u8 = null,
                output: []const WireItem = &.{},
                incomplete_details: ?struct { reason: ?[]const u8 = null } = null,
                usage: ?struct {
                    input_tokens: u64 = 0,
                    output_tokens: u64 = 0,
                    input_tokens_details: ?struct {
                        cached_tokens: u64 = 0,
                        cache_write_tokens: u64 = 0,
                    } = null,
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

        if (std.mem.eql(u8, wire.type, "error") or
            std.mem.eql(u8, wire.type, "response.failed"))
        {
            return error.InvalidProviderResponse;
        }
        if (std.mem.eql(u8, wire.type, "response.output_item.added")) {
            const item = wire.item orelse return error.InvalidProviderResponse;
            const output_index = wire.output_index orelse self.firstFreeOutput();
            if (std.mem.eql(u8, item.type, "reasoning")) {
                const part_index = try self.ensurePart(output_index, .thinking, null, null);
                if (item.id) |id| try self.setReasoningId(part_index, id);
            } else if (std.mem.eql(u8, item.type, "function_call")) {
                const part_index = try self.ensurePart(
                    output_index,
                    .tool_call,
                    item.call_id orelse item.id,
                    item.name,
                );
                try self.setToolItemId(part_index, item.id);
            } else if (std.mem.eql(u8, item.type, "message")) {
                const part_index = try self.ensurePart(output_index, .text, null, null);
                try self.setTextState(part_index, item.id, item.phase);
            } else {
                return;
            }
            self.current_output = output_index;
            return;
        }
        if (std.mem.eql(u8, wire.type, "response.content_part.added")) {
            const part = wire.part orelse return error.InvalidProviderResponse;
            if (std.mem.eql(u8, part.type, "output_text") or std.mem.eql(u8, part.type, "refusal")) {
                const output_index = wire.output_index orelse self.current_output orelse self.firstFreeOutput();
                _ = try self.ensurePart(output_index, .text, null, null);
            }
            return;
        }
        if (std.mem.eql(u8, wire.type, "response.output_text.delta") or
            std.mem.eql(u8, wire.type, "response.refusal.delta"))
        {
            const delta = wire.delta orelse return;
            const output_index = wire.output_index orelse self.current_output orelse self.firstFreeOutput();
            const part_index = try self.ensurePart(output_index, .text, null, null);
            try self.parts.items[part_index].text.text.appendSlice(self.allocator, delta);
            try self.emitDelta(part_index, .{ .text = delta });
            return;
        }
        if (std.mem.eql(u8, wire.type, "response.reasoning_summary_text.delta") or
            std.mem.eql(u8, wire.type, "response.reasoning_text.delta"))
        {
            const delta = wire.delta orelse return;
            const output_index = wire.output_index orelse self.current_output orelse self.firstFreeOutput();
            const part_index = try self.ensurePart(output_index, .thinking, null, null);
            try self.parts.items[part_index].thinking.text.appendSlice(self.allocator, delta);
            try self.emitDelta(part_index, .{ .thinking = delta });
            return;
        }
        if (std.mem.eql(u8, wire.type, "response.reasoning_summary_part.done")) {
            const output_index = wire.output_index orelse self.current_output orelse self.firstFreeOutput();
            const part_index = try self.ensurePart(output_index, .thinking, null, null);
            try self.parts.items[part_index].thinking.text.appendSlice(self.allocator, "\n\n");
            try self.emitDelta(part_index, .{ .thinking = "\n\n" });
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
        if (std.mem.eql(u8, wire.type, "response.function_call_arguments.done")) {
            const arguments = wire.arguments orelse return error.InvalidProviderResponse;
            if (arguments.len > max_tool_arguments_bytes) return error.InvalidProviderResponse;
            const output_index = wire.output_index orelse self.current_output orelse
                return error.InvalidProviderResponse;
            const part_index = try self.ensurePart(output_index, .tool_call, null, null);
            const tool = &self.parts.items[part_index].tool_call;
            if (std.mem.startsWith(u8, arguments, tool.arguments.items)) {
                const suffix = arguments[tool.arguments.items.len..];
                if (suffix.len > 0) try self.emitDelta(part_index, .{
                    .tool_call = .{ .arguments_delta = suffix },
                });
            }
            tool.arguments.clearRetainingCapacity();
            try tool.arguments.appendSlice(self.allocator, arguments);
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
                try self.setToolItemId(part_index, item.id);
                const tool = &self.parts.items[part_index].tool_call;
                if (item.arguments) |arguments| if (tool.arguments.items.len == 0) {
                    if (arguments.len > max_tool_arguments_bytes) return error.InvalidProviderResponse;
                    try tool.arguments.appendSlice(self.allocator, arguments);
                };
            } else if (std.mem.eql(u8, item.type, "reasoning")) {
                const part_index = try self.ensurePart(output_index, .thinking, null, null);
                if (item.id) |id| try self.setReasoningId(part_index, id);
                const thinking = &self.parts.items[part_index].thinking;
                const final_content = if (item.summary.len > 0) item.summary else item.content;
                if (final_content.len > 0) {
                    thinking.text.clearRetainingCapacity();
                    var wrote_content = false;
                    for (final_content) |content| if (content.text) |text| {
                        if (wrote_content) try thinking.text.appendSlice(self.allocator, "\n\n");
                        try thinking.text.appendSlice(self.allocator, text);
                        wrote_content = true;
                    };
                }
                if (item.encrypted_content) |encrypted| if (thinking.encrypted_content == null) {
                    thinking.encrypted_content = try duplicate(self.allocator, encrypted);
                };
            } else if (std.mem.eql(u8, item.type, "message")) {
                const part_index = try self.ensurePart(output_index, .text, null, null);
                try self.setTextState(part_index, item.id, item.phase);
                const text = &self.parts.items[part_index].text.text;
                if (item.content.len > 0) text.clearRetainingCapacity();
                for (item.content) |content| {
                    const value = if (std.mem.eql(u8, content.type, "output_text"))
                        content.text
                    else if (std.mem.eql(u8, content.type, "refusal"))
                        content.refusal
                    else
                        null;
                    if (value) |final_text| try text.appendSlice(self.allocator, final_text);
                }
            }
            return;
        }
        if (std.mem.eql(u8, wire.type, "response.done") or
            std.mem.eql(u8, wire.type, "response.completed") or
            std.mem.eql(u8, wire.type, "response.incomplete"))
        {
            const response = wire.response orelse return error.InvalidProviderResponse;
            if (response.status) |status| {
                if (std.mem.eql(u8, status, "failed")) return error.InvalidProviderResponse;
                if (std.mem.eql(u8, status, "cancelled")) return error.Cancelled;
            }
            for (response.output) |item| {
                if (!std.mem.eql(u8, item.type, "reasoning")) continue;
                const item_id = item.id orelse continue;
                const encrypted = item.encrypted_content orelse continue;
                for (self.parts.items) |*part| switch (part.*) {
                    .thinking => |*thinking| {
                        const stored_id = thinking.item_id orelse continue;
                        if (!std.mem.eql(u8, stored_id, item_id) or thinking.encrypted_content != null) continue;
                        thinking.encrypted_content = try duplicate(self.allocator, encrypted);
                    },
                    else => {},
                };
            }
            if (response.usage) |value| {
                const cached_input = if (value.input_tokens_details) |details| details.cached_tokens else 0;
                const cache_write = if (value.input_tokens_details) |details| details.cache_write_tokens else 0;
                self.usage = .{
                    .input_tokens = value.input_tokens -| cached_input -| cache_write,
                    .output_tokens = value.output_tokens,
                    .cached_input_tokens = cached_input,
                    .cache_write_tokens = cache_write,
                    .reasoning_tokens = if (value.output_tokens_details) |details| details.reasoning_tokens else 0,
                };
                if (self.sink) |event_sink| try event_sink.emit(.{ .usage = self.usage });
            }
            if (std.mem.eql(u8, wire.type, "response.incomplete") or
                (response.status != null and std.mem.eql(u8, response.status.?, "incomplete")))
            {
                const reason = if (response.incomplete_details) |details| details.reason else null;
                self.finish_value = .{
                    .category = incompleteFinishCategory(reason),
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
        if (self.output_parts[output_index]) |part_index| {
            const matches = switch (kind) {
                .text => self.parts.items[part_index] == .text,
                .thinking => self.parts.items[part_index] == .thinking,
                .tool_call => self.parts.items[part_index] == .tool_call,
            };
            if (!matches) return error.InvalidProviderResponse;
            if (kind == .tool_call) {
                const tool = &self.parts.items[part_index].tool_call;
                if (tool.id.items.len == 0) if (id) |value| try tool.id.appendSlice(self.allocator, value);
                if (tool.name.items.len == 0) if (name) |value| try tool.name.appendSlice(self.allocator, value);
            }
            return part_index;
        }
        if (self.parts.items.len >= max_parts) return error.InvalidProviderResponse;
        const part_index = self.parts.items.len;
        try self.parts.append(self.allocator, switch (kind) {
            .text => .{ .text = .{} },
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

    fn setToolItemId(self: *StreamDecoder, part_index: usize, item_id: ?[]const u8) !void {
        const value = item_id orelse return;
        const tool = &self.parts.items[part_index].tool_call;
        if (tool.item_id == null) tool.item_id = try duplicate(self.allocator, value);
    }

    fn toolState(self: *StreamDecoder, tool: Tool) failure.ModelError!?message.ProviderState {
        const item_id = tool.item_id orelse return null;
        var value: std.json.ObjectMap = .empty;
        value.put(self.allocator, "type", .{ .string = "function_call" }) catch return error.OutOfMemory;
        value.put(self.allocator, "id", .{
            .string = try duplicate(self.allocator, item_id),
        }) catch return error.OutOfMemory;
        return .{
            .provider = self.identity.provider,
            .protocol = self.protocol_id,
            .value = .{ .object = value },
        };
    }

    fn setTextState(
        self: *StreamDecoder,
        part_index: usize,
        item_id: ?[]const u8,
        phase: ?[]const u8,
    ) !void {
        const text = &self.parts.items[part_index].text;
        if (text.item_id == null) if (item_id) |value| {
            text.item_id = try duplicate(self.allocator, value);
        };
        if (phase) |value| {
            const replacement = try duplicate(self.allocator, value);
            if (text.phase) |previous| self.allocator.free(previous);
            text.phase = replacement;
        }
    }

    fn textState(self: *StreamDecoder, text: Text) failure.ModelError!?message.ProviderState {
        const item_id = text.item_id orelse return null;
        var value: std.json.ObjectMap = .empty;
        value.put(self.allocator, "type", .{ .string = "message" }) catch return error.OutOfMemory;
        value.put(self.allocator, "id", .{
            .string = try duplicate(self.allocator, item_id),
        }) catch return error.OutOfMemory;
        value.put(self.allocator, "status", .{ .string = "completed" }) catch return error.OutOfMemory;
        if (text.phase) |phase| value.put(self.allocator, "phase", .{
            .string = try duplicate(self.allocator, phase),
        }) catch return error.OutOfMemory;
        return .{
            .provider = self.identity.provider,
            .protocol = self.protocol_id,
            .value = .{ .object = value },
        };
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
            .protocol = self.protocol_id,
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
    identity: message.ModelIdentity,
    source_identity: message.ModelIdentity,
    protocol_id: []const u8,
    thinking: message.ThinkingPart,
    wrote: *bool,
) failure.ModelError!void {
    const state = thinking.provider_state orelse {
        if (thinking.text.len > 0) try writeRoleText(writer, "assistant", "output_text", thinking.text, wrote);
        return;
    };
    if (!sameIdentity(source_identity, identity) or
        !std.mem.eql(u8, state.provider, identity.provider) or
        !std.mem.eql(u8, state.protocol, protocol_id))
    {
        if (thinking.text.len > 0) try writeRoleText(writer, "assistant", "output_text", thinking.text, wrote);
        return;
    }
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

fn writeAssistantText(
    writer: *std.Io.Writer,
    identity: message.ModelIdentity,
    source_identity: message.ModelIdentity,
    protocol_id: []const u8,
    text: message.TextPart,
    wrote: *bool,
) failure.ModelError!void {
    const state = text.provider_state orelse {
        try writeRoleText(writer, "assistant", "output_text", text.text, wrote);
        return;
    };
    if (!sameIdentity(source_identity, identity) or
        !std.mem.eql(u8, state.provider, identity.provider) or
        !std.mem.eql(u8, state.protocol, protocol_id))
    {
        try writeRoleText(writer, "assistant", "output_text", text.text, wrote);
        return;
    }
    if (state.value != .object) return error.InvalidRequest;
    const kind = state.value.object.get("type") orelse return error.InvalidRequest;
    const item_id = state.value.object.get("id") orelse return error.InvalidRequest;
    const status = state.value.object.get("status") orelse return error.InvalidRequest;
    if (kind != .string or !std.mem.eql(u8, kind.string, "message")) return error.InvalidRequest;
    if (item_id != .string or item_id.string.len == 0) return error.InvalidRequest;
    if (status != .string or status.string.len == 0) return error.InvalidRequest;
    const phase = state.value.object.get("phase");
    if (phase) |value| if (value != .string or value.string.len == 0) return error.InvalidRequest;

    if (wrote.*) writer.writeByte(',') catch return error.OutOfMemory;
    wrote.* = true;
    writer.writeAll("{\"type\":\"message\",\"role\":\"assistant\"") catch return error.OutOfMemory;
    writer.writeAll(",\"content\":[{\"type\":\"output_text\",\"text\":") catch return error.OutOfMemory;
    writeJson(writer, text.text) catch return error.OutOfMemory;
    writer.writeAll("}],\"status\":") catch return error.OutOfMemory;
    writeJson(writer, status.string) catch return error.OutOfMemory;
    writer.writeAll(",\"id\":") catch return error.OutOfMemory;
    writeJson(writer, item_id.string) catch return error.OutOfMemory;
    if (phase) |value| {
        writer.writeAll(",\"phase\":") catch return error.OutOfMemory;
        writeJson(writer, value.string) catch return error.OutOfMemory;
    }
    writer.writeByte('}') catch return error.OutOfMemory;
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
    identity: message.ModelIdentity,
    source_identity: message.ModelIdentity,
    protocol_id: []const u8,
    call: message.ToolCall,
    wrote: *bool,
) failure.ModelError!void {
    validateJson(allocator, call.arguments_json) catch |validation_failure| switch (validation_failure) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidJson => return error.InvalidRequest,
    };
    var item_id: ?[]const u8 = null;
    if (call.provider_state) |state| if (sameIdentity(source_identity, identity) and
        std.mem.eql(u8, state.provider, identity.provider) and
        std.mem.eql(u8, state.protocol, protocol_id))
    {
        if (state.value != .object) return error.InvalidRequest;
        const kind = state.value.object.get("type") orelse return error.InvalidRequest;
        const id = state.value.object.get("id") orelse return error.InvalidRequest;
        if (kind != .string or !std.mem.eql(u8, kind.string, "function_call")) return error.InvalidRequest;
        if (id != .string or id.string.len == 0) return error.InvalidRequest;
        item_id = id.string;
    };
    if (wrote.*) writer.writeByte(',') catch return error.OutOfMemory;
    wrote.* = true;
    writer.writeAll("{\"type\":\"function_call\",\"call_id\":") catch return error.OutOfMemory;
    writeJson(writer, call.id) catch return error.OutOfMemory;
    if (item_id) |id| {
        writer.writeAll(",\"id\":") catch return error.OutOfMemory;
        writeJson(writer, id) catch return error.OutOfMemory;
    }
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
    const output = if (text.written().len == 0) "(no tool output)" else text.written();
    writeJson(writer, output) catch return error.OutOfMemory;
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

fn sameIdentity(left: message.ModelIdentity, right: message.ModelIdentity) bool {
    return std.mem.eql(u8, left.provider, right.provider) and
        std.mem.eql(u8, left.model, right.model);
}

fn incompleteFinishCategory(reason: ?[]const u8) usage_api.FinishCategory {
    const value = reason orelse return .unknown;
    if (std.mem.eql(u8, value, "max_output_tokens")) return .length;
    if (std.mem.eql(u8, value, "content_filter")) return .content_filter;
    return .unknown;
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
