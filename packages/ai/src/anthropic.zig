const std = @import("std");
const protocol = @import("protocol.zig");
const sse = @import("sse.zig");
const ai_provider = @import("provider.zig");

/// Anthropic Messages API provider implementation.
/// Streams to `{model.base_url}/v1/messages` with SSE parsing.
pub const AnthropicProvider = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) AnthropicProvider {
        return .{ .allocator = allocator };
    }

    /// Returns a vtable-wrapped Provider interface.
    pub fn provider(self: *AnthropicProvider) ai_provider.Provider {
        return .{
            .ptr = self,
            .vtable = &.{
                .stream = streamImplWrapper,
                .stream_simple = streamSimpleImplWrapper,
                .get_name = getNameImpl,
                .deinit = deinitImpl,
            },
        };
    }

    // =================================================================
    // VTable implementations
    // =================================================================

    fn streamImplWrapper(ptr: *anyopaque, allocator: std.mem.Allocator, model: protocol.Model, context: protocol.Context, options: protocol.StreamOptions, callback: ai_provider.EventCallback, callback_ctx: ?*anyopaque) void {
        const self: *AnthropicProvider = @ptrCast(@alignCast(ptr));
        self.streamImpl(allocator, model, context, options, callback, callback_ctx);
    }

    fn streamSimpleImplWrapper(ptr: *anyopaque, allocator: std.mem.Allocator, model: protocol.Model, context: protocol.Context, options: protocol.SimpleStreamOptions, callback: ai_provider.EventCallback, callback_ctx: ?*anyopaque) void {
        const self: *AnthropicProvider = @ptrCast(@alignCast(ptr));
        self.streamImpl(allocator, model, context, options.base, callback, callback_ctx);
    }

    fn getNameImpl(_: *anyopaque) []const u8 {
        return "anthropic";
    }

    fn deinitImpl(_: *anyopaque) void {}

    // =================================================================
    // Main streaming implementation
    // =================================================================

    fn streamImpl(self: *AnthropicProvider, allocator: std.mem.Allocator, model: protocol.Model, context: protocol.Context, options: protocol.StreamOptions, callback: ai_provider.EventCallback, callback_ctx: ?*anyopaque) void {
        _ = self;

        // Build request payload
        var payload_buf: std.ArrayListUnmanaged(u8) = .{};
        defer payload_buf.deinit(allocator);

        buildRequestJson(allocator, &payload_buf, model, context, options) catch |err| {
            emitError(allocator, callback, callback_ctx, "failed to build request: {s}", .{@errorName(err)});
            return;
        };

        const api_key = options.api_key orelse {
            emitError(allocator, callback, callback_ctx, "no API key provided", .{});
            return;
        };

        const uri_str = std.fmt.allocPrint(allocator, "{s}/v1/messages", .{model.base_url}) catch |err| {
            emitError(allocator, callback, callback_ctx, "failed to build URI: {s}", .{@errorName(err)});
            return;
        };
        defer allocator.free(uri_str);

        const uri = std.Uri.parse(uri_str) catch |err| {
            emitError(allocator, callback, callback_ctx, "failed to parse URI: {s}", .{@errorName(err)});
            return;
        };

        // Setup HTTP client
        var client: std.http.Client = .{ .allocator = allocator };
        defer client.deinit();

        // Build extra headers
        var extra_headers_buf: [16]std.http.Header = undefined;
        var n_extra: usize = 0;

        extra_headers_buf[n_extra] = .{ .name = "anthropic-version", .value = "2023-06-01" };
        n_extra += 1;
        extra_headers_buf[n_extra] = .{ .name = "x-api-key", .value = api_key };
        n_extra += 1;

        if (options.headers) |custom_headers| {
            for (custom_headers) |h| {
                if (n_extra < extra_headers_buf.len) {
                    extra_headers_buf[n_extra] = .{ .name = h.key, .value = h.value };
                    n_extra += 1;
                }
            }
        }

        // Send request
        var req = client.request(.POST, uri, .{
            .extra_headers = extra_headers_buf[0..n_extra],
            .headers = .{
                .content_type = .{ .override = "application/json" },
            },
        }) catch |err| {
            emitError(allocator, callback, callback_ctx, "failed to open connection: {s}", .{@errorName(err)});
            return;
        };
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = payload_buf.items.len };
        var body = req.sendBodyUnflushed(&.{}) catch |err| {
            emitError(allocator, callback, callback_ctx, "failed to send body: {s}", .{@errorName(err)});
            return;
        };
        body.writer.writeAll(payload_buf.items) catch |err| {
            emitError(allocator, callback, callback_ctx, "failed to write body: {s}", .{@errorName(err)});
            return;
        };
        body.end() catch |err| {
            emitError(allocator, callback, callback_ctx, "failed to end body: {s}", .{@errorName(err)});
            return;
        };
        if (req.connection) |conn| {
            conn.flush() catch |err| {
                emitError(allocator, callback, callback_ctx, "failed to flush: {s}", .{@errorName(err)});
                return;
            };
        }

        var redirect_buf: [4096]u8 = undefined;
        var response = req.receiveHead(&redirect_buf) catch |err| {
            emitError(allocator, callback, callback_ctx, "request failed: {s}", .{@errorName(err)});
            return;
        };

        const status = response.head.status;
        if (status != .ok) {
            var err_body: [4096]u8 = undefined;
            const reader = response.reader(&.{});
            var n_read: usize = 0;
            while (n_read < err_body.len) {
                const chunk = reader.read(err_body[n_read..]) catch break;
                if (chunk == 0) break;
                n_read += chunk;
            }
            emitError(allocator, callback, callback_ctx, "HTTP {d}: {s}", .{ @intFromEnum(status), err_body[0..n_read] });
            return;
        }

        // Parse SSE stream
        var parser = sse.SseParser{};
        var line_buf: [8192]u8 = undefined;
        const reader = response.reader(&.{});

        // Streaming state
        var state = StreamState{
            .allocator = allocator,
            .content_blocks = .{},
            .partial = protocol.AssistantMessage{
                .content = &.{},
                .api = .anthropic_messages,
                .provider = .anthropic,
                .model = model.id,
                .usage = .{
                    .input = 0,
                    .output = 0,
                    .cache_read = 0,
                    .cache_write = 0,
                    .total_tokens = 0,
                    .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 },
                },
                .stop_reason = .stop,
                .timestamp = std.time.milliTimestamp(),
            },
            .stop_reason = null,
        };
        defer {
            for (state.content_blocks.items) |*block| {
                block.deinit(allocator);
            }
            state.content_blocks.deinit(allocator);
        }

        // Emit start event
        callback(.{ .start = .{ .partial = state.partial } }, callback_ctx);

        // Process SSE events
        while (true) {
            const line = reader.readUntilDelimiter(&line_buf, '\n') catch |err| switch (err) {
                error.EndOfStream => {
                    if (parser.has_data or parser.event_len > 0) {
                        if (parser.feedLine("")) |evt| {
                            handleSseEvent(evt, &state, callback, callback_ctx);
                        }
                    }
                    break;
                },
                else => {
                    emitError(allocator, callback, callback_ctx, "stream read error: {s}", .{@errorName(err)});
                    return;
                },
            };

            const trimmed = std.mem.trimRight(u8, line, "\r");
            if (parser.feedLine(trimmed)) |evt| {
                handleSseEvent(evt, &state, callback, callback_ctx);
            }
        }

        // Emit final done event
        if (state.stop_reason) |sr| {
            const done_reason: protocol.AssistantMessageEvent.DoneReason = switch (sr) {
                .end_turn => .stop,
                .max_tokens => .length,
                .tool_use => .toolUse,
                else => .stop,
            };
            callback(.{ .done = .{ .reason = done_reason, .message = state.partial } }, callback_ctx);
        } else {
            callback(.{ .done = .{ .reason = .stop, .message = state.partial } }, callback_ctx);
        }
    }
};

// =================================================================
// Streaming state
// =================================================================

const ContentBlockState = struct {
    block_type: BlockType,
    index: usize,
    text: std.ArrayListUnmanaged(u8),
    thinking: std.ArrayListUnmanaged(u8),
    tool_call: ?protocol.ToolCall,

    const BlockType = enum { text, thinking, tool_call };

    fn init(block_type: BlockType, index: usize) ContentBlockState {
        return .{
            .block_type = block_type,
            .index = index,
            .text = .{},
            .thinking = .{},
            .tool_call = null,
        };
    }

    fn deinit(self: *ContentBlockState, allocator: std.mem.Allocator) void {
        self.text.deinit(allocator);
        self.thinking.deinit(allocator);
    }
};

const StreamState = struct {
    allocator: std.mem.Allocator,
    content_blocks: std.ArrayListUnmanaged(ContentBlockState),
    partial: protocol.AssistantMessage,
    stop_reason: ?StopReason,
};

const StopReason = enum {
    end_turn,
    max_tokens,
    tool_use,
    stop_sequence,
    sensitive,
};

// =================================================================
// SSE event handling
// =================================================================

fn handleSseEvent(evt: sse.SseEvent, state: *StreamState, callback: ai_provider.EventCallback, callback_ctx: ?*anyopaque) void {
    const data = evt.data;
    if (data.len == 0) return;

    const event_data_type = extractJsonField(data, "type") orelse return;

    if (std.mem.eql(u8, event_data_type, "message_start")) {
        if (extractJsonInt(data, "input_tokens")) |n_val| state.partial.usage.input = n_val;
        if (extractJsonInt(data, "output_tokens")) |n_val| state.partial.usage.output = n_val;
    } else if (std.mem.eql(u8, event_data_type, "content_block_start")) {
        if (extractJsonField(data, "content_block")) |block_json| {
            const block_type = extractJsonField(block_json, "type") orelse "text";
            const index = extractJsonInt(data, "index") orelse state.content_blocks.items.len;

            if (std.mem.eql(u8, block_type, "text")) {
                const block = ContentBlockState.init(.text, index);
                state.content_blocks.append(state.allocator, block) catch return;
                callback(.{ .text_start = .{ .content_index = state.content_blocks.items.len - 1, .partial = state.partial } }, callback_ctx);
            } else if (std.mem.eql(u8, block_type, "thinking")) {
                const block = ContentBlockState.init(.thinking, index);
                state.content_blocks.append(state.allocator, block) catch return;
                callback(.{ .thinking_start = .{ .content_index = state.content_blocks.items.len - 1, .partial = state.partial } }, callback_ctx);
            } else if (std.mem.eql(u8, block_type, "tool_use")) {
                var block = ContentBlockState.init(.tool_call, index);
                const tool_id = extractJsonField(block_json, "id") orelse "";
                const tool_name = extractJsonField(block_json, "name") orelse "";
                block.tool_call = .{
                    .id = tool_id,
                    .name = tool_name,
                    .arguments = .{ .null = {} },
                    .thought_signature = null,
                };
                state.content_blocks.append(state.allocator, block) catch return;
                callback(.{ .toolcall_start = .{ .content_index = state.content_blocks.items.len - 1, .partial = state.partial } }, callback_ctx);
            }
        }
    } else if (std.mem.eql(u8, event_data_type, "content_block_delta")) {
        if (extractJsonField(data, "delta")) |delta_json| {
            const delta_type = extractJsonField(delta_json, "type") orelse return;
            const index = extractJsonInt(data, "index") orelse return;

            if (std.mem.eql(u8, delta_type, "text_delta")) {
                if (extractJsonString(delta_json, "text")) |text_val| {
                    if (index < state.content_blocks.items.len) {
                        state.content_blocks.items[index].text.appendSlice(state.allocator, text_val) catch return;
                        callback(.{ .text_delta = .{ .content_index = index, .delta = text_val, .partial = state.partial } }, callback_ctx);
                    }
                }
            } else if (std.mem.eql(u8, delta_type, "thinking_delta")) {
                if (extractJsonString(delta_json, "thinking")) |thinking_val| {
                    if (index < state.content_blocks.items.len) {
                        state.content_blocks.items[index].thinking.appendSlice(state.allocator, thinking_val) catch return;
                        callback(.{ .thinking_delta = .{ .content_index = index, .delta = thinking_val, .partial = state.partial } }, callback_ctx);
                    }
                }
            } else if (std.mem.eql(u8, delta_type, "input_json_delta")) {
                if (extractJsonString(delta_json, "partial_json")) |json_delta| {
                    if (index < state.content_blocks.items.len) {
                        const block = &state.content_blocks.items[index];
                        if (block.tool_call) |*tc| {
                            block.text.appendSlice(state.allocator, json_delta) catch return;
                            tc.arguments = parsePartialJson(block.text.items);
                        }
                        callback(.{ .toolcall_delta = .{ .content_index = index, .delta = json_delta, .partial = state.partial } }, callback_ctx);
                    }
                }
            }
        }
    } else if (std.mem.eql(u8, event_data_type, "content_block_stop")) {
        const index = extractJsonInt(data, "index") orelse return;
        if (index >= state.content_blocks.items.len) return;

        const block = &state.content_blocks.items[index];
        switch (block.block_type) {
            .text => {
                callback(.{ .text_end = .{ .content_index = index, .content = block.text.items, .partial = state.partial } }, callback_ctx);
            },
            .thinking => {
                callback(.{ .thinking_end = .{ .content_index = index, .content = block.thinking.items, .partial = state.partial } }, callback_ctx);
            },
            .tool_call => {
                if (block.tool_call) |tc| {
                    const final_args = parsePartialJson(block.text.items);
                    var final_tc = tc;
                    final_tc.arguments = final_args;
                    callback(.{ .toolcall_end = .{ .content_index = index, .tool_call = final_tc, .partial = state.partial } }, callback_ctx);
                }
            },
        }
    } else if (std.mem.eql(u8, event_data_type, "message_delta")) {
        if (extractJsonField(data, "delta")) |delta_json| {
            if (extractJsonField(delta_json, "stop_reason")) |reason| {
                if (std.mem.eql(u8, reason, "end_turn")) {
                    state.stop_reason = .end_turn;
                } else if (std.mem.eql(u8, reason, "max_tokens")) {
                    state.stop_reason = .max_tokens;
                } else if (std.mem.eql(u8, reason, "tool_use")) {
                    state.stop_reason = .tool_use;
                }
            }
        }
        if (extractJsonInt(data, "input_tokens")) |n_val| state.partial.usage.input = n_val;
        if (extractJsonInt(data, "output_tokens")) |n_val| state.partial.usage.output = n_val;
    } else if (std.mem.eql(u8, event_data_type, "error")) {
        if (extractJsonField(data, "error")) |err_json| {
            const err_msg = extractJsonString(err_json, "message") orelse "unknown error";
            emitErrorDirect(callback, callback_ctx, err_msg);
        }
    }
}

// =================================================================
// JSON request building
// =================================================================

fn buildRequestJson(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), model: protocol.Model, context: protocol.Context, options: protocol.StreamOptions) !void {
    try buf.append(allocator, '{');

    // model
    try jsonKey(allocator, buf, "model");
    try jsonString(allocator, buf, model.id);
    try buf.append(allocator, ',');

    // max_tokens
    try jsonKey(allocator, buf, "max_tokens");
    const max_tokens = options.max_tokens orelse model.max_tokens;
    try jsonInt(allocator, buf, max_tokens);
    try buf.append(allocator, ',');

    // stream
    try jsonKey(allocator, buf, "stream");
    try jsonBool(allocator, buf, true);
    try buf.append(allocator, ',');

    // system prompt
    if (context.system_prompt) |system| {
        try jsonKey(allocator, buf, "system");
        try jsonString(allocator, buf, system);
        try buf.append(allocator, ',');
    }

    // messages
    try jsonKey(allocator, buf, "messages");
    try buf.append(allocator, '[');
    for (context.messages, 0..) |msg, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buildMessageJson(allocator, buf, msg);
    }
    try buf.append(allocator, ']');

    // tools (if provided)
    if (context.tools) |tools| {
        if (tools.len > 0) {
            try buf.append(allocator, ',');
            try jsonKey(allocator, buf, "tools");
            try buildToolsJson(allocator, buf, tools);
        }
    }

    // temperature (if provided)
    if (options.temperature) |temp| {
        try buf.append(allocator, ',');
        try jsonKey(allocator, buf, "temperature");
        try std.fmt.format(buf.writer(allocator), "{d}", .{temp});
    }

    try buf.append(allocator, '}');
}

fn buildMessageJson(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), msg: protocol.Message) !void {
    try buf.append(allocator, '{');

    switch (msg) {
        .user => |user| {
            try jsonKey(allocator, buf, "role");
            try jsonString(allocator, buf, "user");
            try buf.append(allocator, ',');
            try jsonKey(allocator, buf, "content");
            switch (user.content) {
                .text => |text_val| {
                    try jsonString(allocator, buf, text_val);
                },
                .blocks => |blocks| {
                    try buf.append(allocator, '[');
                    for (blocks, 0..) |block, i| {
                        if (i > 0) try buf.append(allocator, ',');
                        switch (block) {
                            .text => |t| {
                                try buf.append(allocator, '{');
                                try jsonKey(allocator, buf, "type");
                                try jsonString(allocator, buf, "text");
                                try buf.append(allocator, ',');
                                try jsonKey(allocator, buf, "text");
                                try jsonString(allocator, buf, t.text);
                                try buf.append(allocator, '}');
                            },
                            .image => |img| {
                                try buf.append(allocator, '{');
                                try jsonKey(allocator, buf, "type");
                                try jsonString(allocator, buf, "image");
                                try buf.append(allocator, ',');
                                try jsonKey(allocator, buf, "source");
                                try buf.append(allocator, '{');
                                try jsonKey(allocator, buf, "type");
                                try jsonString(allocator, buf, "base64");
                                try buf.append(allocator, ',');
                                try jsonKey(allocator, buf, "media_type");
                                try jsonString(allocator, buf, img.mime_type);
                                try buf.append(allocator, ',');
                                try jsonKey(allocator, buf, "data");
                                try jsonString(allocator, buf, img.data);
                                try buf.append(allocator, '}');
                                try buf.append(allocator, '}');
                            },
                        }
                    }
                    try buf.append(allocator, ']');
                },
            }
        },
        .assistant => |assistant| {
            try jsonKey(allocator, buf, "role");
            try jsonString(allocator, buf, "assistant");
            try buf.append(allocator, ',');
            try jsonKey(allocator, buf, "content");
            try buf.append(allocator, '[');
            for (assistant.content, 0..) |block, i| {
                if (i > 0) try buf.append(allocator, ',');
                switch (block) {
                    .text => |t| {
                        try buf.append(allocator, '{');
                        try jsonKey(allocator, buf, "type");
                        try jsonString(allocator, buf, "text");
                        try buf.append(allocator, ',');
                        try jsonKey(allocator, buf, "text");
                        try jsonString(allocator, buf, t.text);
                        try buf.append(allocator, '}');
                    },
                    .thinking => |th| {
                        try buf.append(allocator, '{');
                        try jsonKey(allocator, buf, "type");
                        try jsonString(allocator, buf, "thinking");
                        try buf.append(allocator, ',');
                        try jsonKey(allocator, buf, "thinking");
                        try jsonString(allocator, buf, th.thinking);
                        if (th.thinking_signature) |sig| {
                            try buf.append(allocator, ',');
                            try jsonKey(allocator, buf, "signature");
                            try jsonString(allocator, buf, sig);
                        }
                        try buf.append(allocator, '}');
                    },
                    .tool_call => |tc| {
                        try buf.append(allocator, '{');
                        try jsonKey(allocator, buf, "type");
                        try jsonString(allocator, buf, "tool_use");
                        try buf.append(allocator, ',');
                        try jsonKey(allocator, buf, "id");
                        try jsonString(allocator, buf, tc.id);
                        try buf.append(allocator, ',');
                        try jsonKey(allocator, buf, "name");
                        try jsonString(allocator, buf, tc.name);
                        try buf.append(allocator, ',');
                        try jsonKey(allocator, buf, "input");
                        // TODO: serialize tc.arguments (std.json.Value) — not needed for text-only vertical slice
                        try buf.appendSlice(allocator, "{}");

                        try buf.append(allocator, '}');
                    },
                }
            }
            try buf.append(allocator, ']');
        },
        .tool_result => |tr| {
            try jsonKey(allocator, buf, "role");
            try jsonString(allocator, buf, "user");
            try buf.append(allocator, ',');
            try jsonKey(allocator, buf, "content");
            try buf.append(allocator, '[');
            try buf.append(allocator, '{');
            try jsonKey(allocator, buf, "type");
            try jsonString(allocator, buf, "tool_result");
            try buf.append(allocator, ',');
            try jsonKey(allocator, buf, "tool_use_id");
            try jsonString(allocator, buf, tr.tool_call_id);
            try buf.append(allocator, ',');
            try jsonKey(allocator, buf, "content");
            try buf.append(allocator, '[');
            for (tr.content, 0..) |content_block, i| {
                if (i > 0) try buf.append(allocator, ',');
                switch (content_block) {
                    .text => |t| {
                        try buf.append(allocator, '{');
                        try jsonKey(allocator, buf, "type");
                        try jsonString(allocator, buf, "text");
                        try buf.append(allocator, ',');
                        try jsonKey(allocator, buf, "text");
                        try jsonString(allocator, buf, t.text);
                        try buf.append(allocator, '}');
                    },
                    .image => |img| {
                        try buf.append(allocator, '{');
                        try jsonKey(allocator, buf, "type");
                        try jsonString(allocator, buf, "image");
                        try buf.append(allocator, ',');
                        try jsonKey(allocator, buf, "source");
                        try buf.append(allocator, '{');
                        try jsonKey(allocator, buf, "type");
                        try jsonString(allocator, buf, "base64");
                        try buf.append(allocator, ',');
                        try jsonKey(allocator, buf, "media_type");
                        try jsonString(allocator, buf, img.mime_type);
                        try buf.append(allocator, ',');
                        try jsonKey(allocator, buf, "data");
                        try jsonString(allocator, buf, img.data);
                        try buf.append(allocator, '}');
                        try buf.append(allocator, '}');
                    },
                }
            }
            try buf.append(allocator, ']');
            try buf.append(allocator, '}');
            try buf.append(allocator, ']');
        },
    }

    try buf.append(allocator, '}');
}

fn buildToolsJson(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), tools: []const protocol.Tool) !void {
    try buf.append(allocator, '[');
    for (tools, 0..) |tool, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.append(allocator, '{');
        try jsonKey(allocator, buf, "name");
        try jsonString(allocator, buf, tool.name);
        try buf.append(allocator, ',');
        try jsonKey(allocator, buf, "description");
        try jsonString(allocator, buf, tool.description);
        try buf.append(allocator, ',');
        try jsonKey(allocator, buf, "input_schema");
        // TODO: serialize tool.parameters (std.json.Value)
        try buf.appendSlice(allocator, "{}");
        try buf.append(allocator, '}');
    }
    try buf.append(allocator, ']');
}

// =================================================================
// JSON helpers
// =================================================================

fn jsonString(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    try buf.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            0x08 => try buf.appendSlice(allocator, "\\b"),
            0x0C => try buf.appendSlice(allocator, "\\f"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            0x00...0x07, 0x0B, 0x0E...0x1f => try std.fmt.format(buf.writer(allocator), "\\u{x:0>4}", .{c}),
            else => try buf.append(allocator, c),
        }
    }
    try buf.append(allocator, '"');
}

fn jsonKey(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), key: []const u8) !void {
    try jsonString(allocator, buf, key);
    try buf.append(allocator, ':');
}

fn jsonInt(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), n: anytype) !void {
    try std.fmt.format(buf.writer(allocator), "{d}", .{n});
}

fn jsonBool(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), b: bool) !void {
    try buf.appendSlice(allocator, if (b) "true" else "false");
}

// =================================================================
// Simple JSON field extraction helpers
// =================================================================

fn extractJsonField(json: []const u8, field: []const u8) ?[]const u8 {
    const pattern = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\"", .{field}) catch return null;
    defer std.heap.page_allocator.free(pattern);

    const idx = std.mem.indexOf(u8, json, pattern) orelse return null;
    const after = json[idx + pattern.len..];

    var i: usize = 0;
    while (i < after.len and (after[i] == ' ' or after[i] == '\t' or after[i] == '\n' or after[i] == '\r')) : (i += 1) {}
    if (i < after.len and after[i] == ':') i += 1;
    while (i < after.len and (after[i] == ' ' or after[i] == '\t' or after[i] == '\n' or after[i] == '\r')) : (i += 1) {}

    if (i >= after.len) return null;

    if (after[i] == '"') {
        const start = i + 1;
        var j = start;
        while (j < after.len) : (j += 1) {
            if (after[j] == '"' and after[j - 1] != '\\') {
                return after[start..j];
            }
        }
        return after[start..];
    } else if (after[i] == '{') {
        var depth: usize = 1;
        var j = i + 1;
        while (j < after.len and depth > 0) : (j += 1) {
            if (after[j] == '{') depth += 1;
            if (after[j] == '}') depth -= 1;
        }
        return after[i..j];
    } else if (after[i] == '[') {
        var depth: usize = 1;
        var j = i + 1;
        while (j < after.len and depth > 0) : (j += 1) {
            if (after[j] == '[') depth += 1;
            if (after[j] == ']') depth -= 1;
        }
        return after[i..j];
    } else {
        const start = i;
        var j = start;
        while (j < after.len and after[j] != ',' and after[j] != '}' and after[j] != ']') : (j += 1) {}
        return std.mem.trim(u8, after[start..j], " \t\n\r");
    }
}

fn extractJsonString(json: []const u8, field: []const u8) ?[]const u8 {
    return extractJsonField(json, field);
}

fn extractJsonInt(json: []const u8, field: []const u8) ?u64 {
    const val = extractJsonField(json, field) orelse return null;
    return std.fmt.parseInt(u64, val, 10) catch null;
}

fn parsePartialJson(json_str: []const u8) std.json.Value {
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, json_str, .{ .allocate = .alloc_if_needed }) catch {
        return .{ .null = {} };
    };
    defer parsed.deinit();
    return parsed.value;
}

// =================================================================
// Error handling
// =================================================================

fn emitError(allocator: std.mem.Allocator, callback: ai_provider.EventCallback, ctx: ?*anyopaque, comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.allocPrint(allocator, fmt, args) catch {
        callback(.{ .@"error" = .{ .reason = .@"error", .@"error" = .{
            .content = &.{},
            .api = .anthropic_messages,
            .provider = .anthropic,
            .model = "unknown",
            .usage = .{
                .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total_tokens = 0,
                .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 },
            },
            .stop_reason = .@"error",
            .error_message = "failed to format error",
            .timestamp = std.time.milliTimestamp(),
        } } }, ctx);
        return;
    };
    defer allocator.free(msg);
    emitErrorDirect(callback, ctx, msg);
}

fn emitErrorDirect(callback: ai_provider.EventCallback, ctx: ?*anyopaque, msg: []const u8) void {
    callback(.{ .@"error" = .{ .reason = .@"error", .@"error" = .{
        .content = &.{},
        .api = .anthropic_messages,
        .provider = .anthropic,
        .model = "unknown",
        .usage = .{
            .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total_tokens = 0,
            .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 },
        },
        .stop_reason = .@"error",
        .error_message = msg,
        .timestamp = std.time.milliTimestamp(),
    } } }, ctx);
}
