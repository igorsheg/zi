const std = @import("std");
const types = @import("../types.zig");

/// Mistral API provider for chat completions.
/// API: https://api.mistral.ai/v1/chat/completions
/// Similar to OpenAI format with differences in role mapping and tool call format.

const MISTRAL_TOOL_CALL_ID_LENGTH = 9;

/// Stream state for parsing Mistral SSE events
pub const StreamState = struct {
    /// Current content block being built
    current_block: ?Block = null,
    /// Tool call blocks by their key (call_id:index)
    tool_blocks: std.StringHashMap(usize),
    /// Partial arguments being accumulated for tool calls
    partial_args: std.StringHashMap(std.ArrayList(u8)),
    allocator: std.mem.Allocator,

    pub const Block = union(enum) {
        text: TextBlock,
        thinking: ThinkingBlock,

        pub const TextBlock = struct {
            text: std.ArrayList(u8),
        };

        pub const ThinkingBlock = struct {
            thinking: std.ArrayList(u8),
        };
    };

    pub fn init(allocator: std.mem.Allocator) StreamState {
        return .{
            .current_block = null,
            .tool_blocks = std.StringHashMap(usize).init(allocator),
            .partial_args = std.StringHashMap(std.ArrayList(u8)).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *StreamState) void {
        // Clean up current block
        if (self.current_block) |*block| {
            switch (block.*) {
                .text => |*t| t.text.deinit(),
                .thinking => |*th| th.thinking.deinit(),
            }
        }

        // Clean up partial args
        var partial_iter = self.partial_args.valueIterator();
        while (partial_iter.next()) |list| {
            list.deinit();
        }
        self.partial_args.deinit();

        // Clean up tool blocks keys
        var tool_iter = self.tool_blocks.keyIterator();
        while (tool_iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.tool_blocks.deinit();
    }
};

/// Mistral chat message for API request
const ChatMessage = struct {
    role: []const u8,
    content: ?std.json.Value = null,
    tool_calls: ?[]const ToolCallMessage = null,
    tool_call_id: ?[]const u8 = null,
    name: ?[]const u8 = null,
};

const ToolCallMessage = struct {
    id: []const u8,
    type: []const u8,
    function: struct {
        name: []const u8,
        arguments: []const u8,
    },
};

const FunctionTool = struct {
    type: []const u8,
    function: struct {
        name: []const u8,
        description: []const u8,
        parameters: std.json.Value,
        strict: bool = false,
    },
};

/// Build the Mistral chat completions request body.
/// Caller owns the returned memory.
pub fn buildRequest(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) ![]u8 {
    var messages = std.ArrayList(ChatMessage).init(allocator);
    defer {
        for (messages.items) |*msg| {
            if (msg.content) |*c| c.deinit();
        }
        messages.deinit();
    }

    // Add system prompt if present
    if (context.system_prompt) |system| {
        try messages.append(.{
            .role = "system",
            .content = std.json.Value{ .string = try allocator.dupe(u8, system) },
        });
    }

    // Convert messages
    for (context.messages) |msg| {
        try convertMessage(allocator, &messages, msg, model);
    }

    // Build request payload
    var payload = std.json.ObjectMap.init(allocator);
    defer payload.deinit();

    try payload.put("model", std.json.Value{ .string = model.id });
    try payload.put("stream", std.json.Value{ .bool = true });

    // Convert messages to JSON array
    var json_messages = std.ArrayList(std.json.Value).init(allocator);
    defer {
        for (json_messages.items) |*item| item.deinit();
        json_messages.deinit();
    }

    for (messages.items) |msg| {
        var msg_obj = std.json.ObjectMap.init(allocator);
        try msg_obj.put("role", std.json.Value{ .string = msg.role });

        if (msg.content) |content| {
            try msg_obj.put("content", content);
        }

        if (msg.tool_calls) |tool_calls| {
            var tc_array = std.ArrayList(std.json.Value).init(allocator);
            defer {
                for (tc_array.items) |*item| item.deinit();
                tc_array.deinit();
            }

            for (tool_calls) |tc| {
                var tc_obj = std.json.ObjectMap.init(allocator);
                try tc_obj.put("id", std.json.Value{ .string = try allocator.dupe(u8, tc.id) });
                try tc_obj.put("type", std.json.Value{ .string = tc.type });

                var fn_obj = std.json.ObjectMap.init(allocator);
                try fn_obj.put("name", std.json.Value{ .string = try allocator.dupe(u8, tc.function.name) });
                try fn_obj.put("arguments", std.json.Value{ .string = try allocator.dupe(u8, tc.function.arguments) });
                try tc_obj.put("function", std.json.Value{ .object = fn_obj });

                try tc_array.append(std.json.Value{ .object = tc_obj });
            }

            try msg_obj.put("tool_calls", std.json.Value{ .array = tc_array });
        }

        if (msg.tool_call_id) |id| {
            try msg_obj.put("tool_call_id", std.json.Value{ .string = try allocator.dupe(u8, id) });
        }

        if (msg.name) |name| {
            try msg_obj.put("name", std.json.Value{ .string = try allocator.dupe(u8, name) });
        }

        try json_messages.append(std.json.Value{ .object = msg_obj });
    }

    try payload.put("messages", std.json.Value{ .array = json_messages });

    // Add tools if present
    if (context.tools) |tools| {
        var tools_array = std.ArrayList(std.json.Value).init(allocator);
        defer {
            for (tools_array.items) |*item| item.deinit();
            tools_array.deinit();
        }

        for (tools) |tool| {
            var tool_obj = std.json.ObjectMap.init(allocator);
            try tool_obj.put("type", std.json.Value{ .string = "function" });

            var fn_obj = std.json.ObjectMap.init(allocator);
            try fn_obj.put("name", std.json.Value{ .string = try allocator.dupe(u8, tool.name) });
            try fn_obj.put("description", std.json.Value{ .string = try allocator.dupe(u8, tool.description) });
            try fn_obj.put("parameters", tool.parameters);
            try fn_obj.put("strict", std.json.Value{ .bool = false });
            try tool_obj.put("function", std.json.Value{ .object = fn_obj });

            try tools_array.append(std.json.Value{ .object = tool_obj });
        }

        try payload.put("tools", std.json.Value{ .array = tools_array });
    }

    // Add optional parameters
    if (options) |opts| {
        if (opts.temperature) |temp| {
            try payload.put("temperature", std.json.Value{ .float = temp });
        }
        if (opts.max_tokens) |max| {
            try payload.put("max_tokens", std.json.Value{ .integer = @intCast(max) });
        }
    }

    const root = std.json.Value{ .object = payload };
    return std.json.stringifyAlloc(allocator, root, .{});
}

/// Parse a Mistral SSE event and produce an AssistantMessageEvent.
/// Returns null if the event is not a completion event (e.g., heartbeat).
pub fn parseEvent(
    allocator: std.mem.Allocator,
    event_data: []const u8,
    state: *StreamState,
) !?types.AssistantMessageEvent {
    // Parse the JSON event data
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, event_data, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        // If we can't parse, this might be a non-data event or error
        std.log.warn("Failed to parse Mistral event: {s}", .{event_data});
        return err;
    };
    defer parsed.deinit();

    const root = parsed.value;

    // Check for completion chunk
    const choices = root.object.get("choices") orelse return null;
    if (choices.array.items.len == 0) return null;

    const choice = choices.array.items[0];
    const delta = choice.object.get("delta") orelse return null;

    // Extract text/thinking content from delta
    if (delta.object.get("content")) |content| {
        switch (content) {
            .string => |text| {
                return try handleTextDelta(allocator, state, text);
            },
            .array => |items| {
                // Handle array content (thinking blocks, etc.)
                for (items) |item| {
                    if (item.object.get("type")) |item_type| {
                        if (std.mem.eql(u8, item_type.string, "thinking")) {
                            return try handleThinkingDelta(allocator, state, item);
                        } else if (std.mem.eql(u8, item_type.string, "text")) {
                            if (item.object.get("text")) |text| {
                                return try handleTextDelta(allocator, state, text.string);
                            }
                        }
                    }
                }
            },
            else => {},
        }
    }

    // Handle tool calls
    if (delta.object.get("tool_calls")) |tool_calls| {
        return try handleToolCallDelta(allocator, state, tool_calls);
    }

    // Check for finish reason
    if (choice.object.get("finish_reason")) |finish| {
        if (finish != .null) {
            const reason = mapStopReason(finish.string);
            return types.AssistantMessageEvent{
                .done = .{
                    .reason = switch (reason) {
                        .stop => .stop,
                        .length => .length,
                        .tool_use => .tool_use,
                        else => .stop,
                    },
                    .message = undefined, // Caller builds final message
                },
            };
        }
    }

    return null;
}

/// Handle text delta from Mistral
fn handleTextDelta(
    allocator: std.mem.Allocator,
    state: *StreamState,
    text: []const u8,
) !?types.AssistantMessageEvent {
    _ = allocator;

    // Check if we need to start a new text block
    if (state.current_block == null or state.current_block.? != .text) {
        // Finish any existing block
        if (state.current_block) |*block| {
            switch (block.*) {
                .text => |*t| t.text.deinit(),
                .thinking => |*th| th.thinking.deinit(),
            }
        }

        state.current_block = .{ .text = .{ .text = std.ArrayList(u8).init(state.allocator) } };

        // Return text_start event
        return types.AssistantMessageEvent{
            .text_start = .{
                .content_index = 0, // Determined by caller based on content array
                .partial = undefined,
            },
        };
    }

    // Append to current text block
    if (state.current_block) |*block| {
        switch (block.*) {
            .text => |*t| try t.text.appendSlice(text),
            else => {},
        }
    }

    return types.AssistantMessageEvent{
        .text_delta = .{
            .content_index = 0,
            .delta = try state.allocator.dupe(u8, text),
            .partial = undefined,
        },
    };
}

/// Handle thinking delta from Mistral
fn handleThinkingDelta(
    allocator: std.mem.Allocator,
    state: *StreamState,
    item: std.json.Value,
) !?types.AssistantMessageEvent {
    _ = allocator;

    // Extract thinking text from the item
    var thinking_text: []const u8 = "";
    if (item.object.get("thinking")) |thinking| {
        if (thinking.array.items.len > 0) {
            const part = thinking.array.items[0];
            if (part.object.get("text")) |text| {
                thinking_text = text.string;
            }
        }
    }

    // Check if we need to start a new thinking block
    if (state.current_block == null or state.current_block.? != .thinking) {
        // Finish any existing block
        if (state.current_block) |*block| {
            switch (block.*) {
                .text => |*t| t.text.deinit(),
                .thinking => |*th| th.thinking.deinit(),
            }
        }

        state.current_block = .{ .thinking = .{ .thinking = std.ArrayList(u8).init(state.allocator) } };

        // Return thinking_start event
        return types.AssistantMessageEvent{
            .thinking_start = .{
                .content_index = 0,
                .partial = undefined,
            },
        };
    }

    // Append to current thinking block
    if (state.current_block) |*block| {
        switch (block.*) {
            .thinking => |*th| try th.thinking.appendSlice(thinking_text),
            else => {},
        }
    }

    return types.AssistantMessageEvent{
        .thinking_delta = .{
            .content_index = 0,
            .delta = try state.allocator.dupe(u8, thinking_text),
            .partial = undefined,
        },
    };
}

/// Handle tool call delta from Mistral
fn handleToolCallDelta(
    allocator: std.mem.Allocator,
    state: *StreamState,
    tool_calls: std.json.Value,
) !?types.AssistantMessageEvent {
    if (tool_calls.array.items.len == 0) return null;

    const tool_call = tool_calls.array.items[0];

    // Get or create tool call ID
    var call_id: []const u8 = "";
    if (tool_call.object.get("id")) |id| {
        call_id = id.string;
    }
    if (call_id.len == 0 or std.mem.eql(u8, call_id, "null")) {
        call_id = "tc:0"; // Fallback ID
    }

    // Normalize to Mistral's 9-char limit
    const normalized_id = try normalizeToolCallId(allocator, call_id);
    defer allocator.free(normalized_id);

    // Get tool index
    var tool_index: usize = 0;
    if (tool_call.object.get("index")) |idx| {
        tool_index = @intCast(idx.integer);
    }

    const key = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ normalized_id, tool_index });
    defer allocator.free(key);

    // Check if this is a new tool call
    const existing = state.tool_blocks.get(key);

    if (existing == null) {
        // New tool call - extract name
        var name: []const u8 = "";
        if (tool_call.object.get("function")) |func| {
            if (func.object.get("name")) |n| {
                name = n.string;
            }
        }

        try state.tool_blocks.put(try allocator.dupe(u8, key), tool_index);

        // Initialize partial args storage
        const partial = std.ArrayList(u8).init(allocator);
        try state.partial_args.put(try allocator.dupe(u8, key), partial);

        return types.AssistantMessageEvent{
            .toolcall_start = .{
                .content_index = tool_index,
                .partial = undefined,
            },
        };
    }

    // Existing tool call - accumulate arguments
    if (tool_call.object.get("function")) |func| {
        if (func.object.get("arguments")) |args| {
            const args_str = switch (args) {
                .string => |s| s,
                else => "",
            };

            if (state.partial_args.getPtr(key)) |partial| {
                try partial.appendSlice(args_str);
            }

            return types.AssistantMessageEvent{
                .toolcall_delta = .{
                    .content_index = tool_index,
                    .delta = try allocator.dupe(u8, args_str),
                    .partial = undefined,
                },
            };
        }
    }

    return null;
}

/// Convert a message to Mistral chat format
fn convertMessage(
    allocator: std.mem.Allocator,
    messages: *std.ArrayList(ChatMessage),
    msg: types.Message,
    model: types.Model,
) !void {
    switch (msg) {
        .user => |user_msg| {
            switch (user_msg.content) {
                .text => |text| {
                    try messages.append(.{
                        .role = "user",
                        .content = std.json.Value{ .string = try allocator.dupe(u8, text) },
                    });
                },
                .blocks => |blocks| {
                    var content_parts = std.ArrayList(std.json.Value).init(allocator);
                    defer content_parts.deinit();

                    for (blocks) |block| {
                        switch (block) {
                            .text => |t| {
                                var text_obj = std.json.ObjectMap.init(allocator);
                                try text_obj.put("type", std.json.Value{ .string = "text" });
                                try text_obj.put("text", std.json.Value{ .string = try allocator.dupe(u8, t.text) });
                                try content_parts.append(std.json.Value{ .object = text_obj });
                            },
                            .image => |img| {
                                if (model.input.len > 1 or model.input[0] == .image) {
                                    var img_obj = std.json.ObjectMap.init(allocator);
                                    try img_obj.put("type", std.json.Value{ .string = "image_url" });
                                    const url = try std.fmt.allocPrint(allocator, "data:{s};base64,{s}", .{ img.mime_type, img.data });
                                    try img_obj.put("image_url", std.json.Value{ .string = url });
                                    try content_parts.append(std.json.Value{ .object = img_obj });
                                }
                            },
                        }
                    }

                    try messages.append(.{
                        .role = "user",
                        .content = std.json.Value{ .array = content_parts },
                    });
                },
            }
        },
        .assistant => |assistant_msg| {
            var content_parts = std.ArrayList(std.json.Value).init(allocator);
            defer content_parts.deinit();

            var tool_calls = std.ArrayList(ToolCallMessage).init(allocator);
            defer tool_calls.deinit();

            for (assistant_msg.content) |block| {
                switch (block) {
                    .text => |t| {
                        if (t.text.len > 0) {
                            var text_obj = std.json.ObjectMap.init(allocator);
                            try text_obj.put("type", std.json.Value{ .string = "text" });
                            try text_obj.put("text", std.json.Value{ .string = try allocator.dupe(u8, t.text) });
                            try content_parts.append(std.json.Value{ .object = text_obj });
                        }
                    },
                    .thinking => |th| {
                        if (th.thinking.len > 0) {
                            var think_obj = std.json.ObjectMap.init(allocator);
                            try think_obj.put("type", std.json.Value{ .string = "thinking" });

                            var parts = std.ArrayList(std.json.Value).init(allocator);
                            var text_obj = std.json.ObjectMap.init(allocator);
                            try text_obj.put("type", std.json.Value{ .string = "text" });
                            try text_obj.put("text", std.json.Value{ .string = try allocator.dupe(u8, th.thinking) });
                            try parts.append(std.json.Value{ .object = text_obj });

                            try think_obj.put("thinking", std.json.Value{ .array = parts });
                            try content_parts.append(std.json.Value{ .object = think_obj });
                        }
                    },
                    .tool_call => |tc| {
                        try tool_calls.append(.{
                            .id = tc.id,
                            .type = "function",
                            .function = .{
                                .name = tc.name,
                                .arguments = try std.json.stringifyAlloc(allocator, tc.arguments, .{}),
                            },
                        });
                    },
                }
            }

            try messages.append(.{
                .role = "assistant",
                .content = if (content_parts.items.len > 0) std.json.Value{ .array = content_parts } else null,
                .tool_calls = if (tool_calls.items.len > 0) try allocator.dupe(ToolCallMessage, tool_calls.items) else null,
            });
        },
        .tool_result => |tool_result| {
            var content_parts = std.ArrayList(std.json.Value).init(allocator);
            defer content_parts.deinit();

            // Build text content
            var text_parts = std.ArrayList(u8).init(allocator);
            defer text_parts.deinit();

            for (tool_result.content) |content| {
                switch (content) {
                    .text => |t| try text_parts.appendSlice(t.text),
                    .image => {}, // Images handled separately
                }
            }

            var text_obj = std.json.ObjectMap.init(allocator);
            try text_obj.put("type", std.json.Value{ .string = "text" });
            try text_obj.put("text", std.json.Value{ .string = try allocator.dupe(u8, text_parts.items) });
            try content_parts.append(std.json.Value{ .object = text_obj });

            // Add images if supported
            for (tool_result.content) |content| {
                switch (content) {
                    .image => |img| {
                        if (model.input.len > 1 or model.input[0] == .image) {
                            var img_obj = std.json.ObjectMap.init(allocator);
                            try img_obj.put("type", std.json.Value{ .string = "image_url" });
                            const url = try std.fmt.allocPrint(allocator, "data:{s};base64,{s}", .{ img.mime_type, img.data });
                            try img_obj.put("image_url", std.json.Value{ .string = url });
                            try content_parts.append(std.json.Value{ .object = img_obj });
                        }
                    },
                    else => {},
                }
            }

            try messages.append(.{
                .role = "tool",
                .content = std.json.Value{ .array = content_parts },
                .tool_call_id = tool_result.tool_call_id,
                .name = tool_result.tool_name,
            });
        },
    }
}

/// Normalize tool call ID to Mistral's 9-character limit
fn normalizeToolCallId(allocator: std.mem.Allocator, id: []const u8) ![]const u8 {
    // Remove non-alphanumeric characters
    var sanitized = std.ArrayList(u8).init(allocator);
    defer sanitized.deinit();

    for (id) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            try sanitized.append(c);
        }
    }

    // If already 9 chars, return as-is
    if (sanitized.items.len == MISTRAL_TOOL_CALL_ID_LENGTH) {
        return allocator.dupe(u8, sanitized.items);
    }

    // Otherwise, hash it
    var hash_bytes: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(sanitized.items, &hash_bytes, .{});

    // Convert to alphanumeric string, take first 9 chars
    var result = std.ArrayList(u8).init(allocator);
    for (hash_bytes) |b| {
        const c = switch (b % 62) {
            0...25 => 'a' + @as(u8, @intCast(b % 26)),
            26...51 => 'A' + @as(u8, @intCast((b - 26) % 26)),
            else => '0' + @as(u8, @intCast((b - 52) % 10)),
        };
        try result.append(c);
        if (result.items.len >= MISTRAL_TOOL_CALL_ID_LENGTH) break;
    }

    return result.toOwnedSlice();
}

/// Map Mistral finish reason to StopReason
fn mapStopReason(reason: ?[]const u8) types.StopReason {
    const r = reason orelse return .stop;

    if (std.mem.eql(u8, r, "stop")) return .stop;
    if (std.mem.eql(u8, r, "length")) return .length;
    if (std.mem.eql(u8, r, "model_length")) return .length;
    if (std.mem.eql(u8, r, "tool_calls")) return .tool_use;
    if (std.mem.eql(u8, r, "error")) return .@"error";

    return .stop;
}
