const std = @import("std");
const types = @import("../types.zig");

/// AWS Bedrock ConverseStream API provider.
/// Uses AWS Signature V4 authentication and binary event-stream protocol.
///
/// NOTE: Full implementation requires:
/// 1. AWS Signature V4 request signing (complex, requires credential chain)
/// 2. Binary event-stream protocol parsing (not SSE)
/// 3. Proper AWS region resolution and endpoint construction
///
/// This is currently a scaffold with the message conversion logic.
/// HTTP/streaming implementation is TODO.

/// Bedrock-specific options
pub const BedrockOptions = struct {
    region: []const u8 = "us-east-1",
    profile: ?[]const u8 = null,
    tool_choice: ?ToolChoice = null,
    reasoning: ?types.ThinkingLevel = null,
    thinking_budgets: ?types.ThinkingBudgets = null,
    interleaved_thinking: bool = true,
    request_metadata: ?std.json.ObjectMap = null,

    pub const ToolChoice = union(enum) {
        auto,
        any,
        none,
        tool: struct { name: []const u8 },
    };
};

/// Bedrock conversation role
const ConversationRole = enum {
    user,
    assistant,

    pub fn toString(self: ConversationRole) []const u8 {
        return switch (self) {
            .user => "user",
            .assistant => "assistant",
        };
    }
};

/// Content block types for Bedrock
const ContentBlock = union(enum) {
    text: []const u8,
    image: ImageBlock,
    tool_use: ToolUseBlock,
    tool_result: ToolResultBlock,
    reasoning_content: ReasoningContentBlock,
    cache_point: CachePointBlock,

    pub const ImageBlock = struct {
        format: ImageFormat,
        source: struct { bytes: []const u8 },

        pub const ImageFormat = enum {
            jpeg,
            png,
            gif,
            webp,
        };
    };

    pub const ToolUseBlock = struct {
        tool_use_id: []const u8,
        name: []const u8,
        input: std.json.Value,
    };

    pub const ToolResultBlock = struct {
        tool_use_id: []const u8,
        content: []const ToolResultContent,
        status: ToolResultStatus,

        pub const ToolResultContent = union(enum) {
            text: []const u8,
            image: ImageBlock,
        };

        pub const ToolResultStatus = enum {
            success,
            err,
        };
    };

    pub const ReasoningContentBlock = struct {
        reasoning_text: ReasoningText,

        pub const ReasoningText = struct {
            text: []const u8,
            signature: ?[]const u8 = null,
        };
    };

    pub const CachePointBlock = struct {
        type: CachePointType,
        ttl: ?CacheTTL = null,

        pub const CachePointType = enum {
            default,
        };

        pub const CacheTTL = enum(u32) {
            one_hour = 3600,
        };
    };
};

/// Bedrock message structure
const BedrockMessage = struct {
    role: ConversationRole,
    content: []const ContentBlock,
};

/// Tool configuration for Bedrock
const ToolConfiguration = struct {
    tools: []const BedrockTool,
    tool_choice: ?ToolChoiceSpec = null,

    pub const BedrockTool = struct {
        tool_spec: struct {
            name: []const u8,
            description: []const u8,
            input_schema: struct { json: std.json.Value },
        },
    };

    pub const ToolChoiceSpec = union(enum) {
        auto: struct {},
        any: struct {},
        tool: struct { name: []const u8 },
    };
};

/// Stream state for Bedrock (binary event-stream protocol)
pub const StreamState = struct {
    /// Current content blocks being built, indexed by content block index
    blocks: std.AutoHashMap(u32, Block),
    allocator: std.mem.Allocator,

    pub const Block = union(enum) {
        text: TextBlock,
        thinking: ThinkingBlock,
        tool_call: ToolCallBlock,

        pub const TextBlock = struct {
            text: std.ArrayList(u8),
        };

        pub const ThinkingBlock = struct {
            thinking: std.ArrayList(u8),
            signature: std.ArrayList(u8),
        };

        pub const ToolCallBlock = struct {
            id: []const u8,
            name: []const u8,
            partial_json: std.ArrayList(u8),
        };
    };

    pub fn init(allocator: std.mem.Allocator) StreamState {
        return .{
            .blocks = std.AutoHashMap(u32, Block).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *StreamState) void {
        var iter = self.blocks.valueIterator();
        while (iter.next()) |block| {
            switch (block.*) {
                .text => |*t| t.text.deinit(),
                .thinking => |*th| {
                    th.thinking.deinit();
                    th.signature.deinit();
                },
                .tool_call => |*tc| {
                    self.allocator.free(tc.id);
                    self.allocator.free(tc.name);
                    tc.partial_json.deinit();
                },
            }
        }
        self.blocks.deinit();
    }
};

/// Bedrock stop reasons
const BedrockStopReason = enum {
    end_turn,
    max_tokens,
    stop_sequence,
    tool_use,
    model_context_window_exceeded,
};

/// Build the Bedrock ConverseStream request body.
/// Caller owns the returned memory.
///
/// NOTE: This builds the JSON payload. Actual request requires:
/// - AWS SigV4 signing
/// - Proper endpoint: https://bedrock-runtime.{region}.amazonaws.com/model/{modelId}/converse-stream
pub fn buildRequest(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) ![]u8 {
    var payload = std.json.ObjectMap.init(allocator);
    defer payload.deinit();

    // Add model ID
    try payload.put("modelId", std.json.Value{ .string = try allocator.dupe(u8, model.id) });

    // Convert and add messages
    const cache_retention = resolveCacheRetention(if (options) |o| o.cache_retention else null);
    const messages = try convertMessages(allocator, context, model, cache_retention);
    defer {
        for (messages) |*msg| {
            allocator.free(msg.content);
        }
        allocator.free(messages);
    }

    var json_messages = std.ArrayList(std.json.Value).init(allocator);
    defer {
        for (json_messages.items) |*item| item.deinit();
        json_messages.deinit();
    }

    for (messages) |msg| {
        var msg_obj = std.json.ObjectMap.init(allocator);
        try msg_obj.put("role", std.json.Value{ .string = msg.role.toString() });

        var content_array = std.ArrayList(std.json.Value).init(allocator);
        defer {
            for (content_array.items) |*item| item.deinit();
            content_array.deinit();
        }

        for (msg.content) |block| {
            try content_array.append(try contentBlockToJson(allocator, block));
        }

        try msg_obj.put("content", std.json.Value{ .array = content_array });
        try json_messages.append(std.json.Value{ .object = msg_obj });
    }

    try payload.put("messages", std.json.Value{ .array = json_messages });

    // Add system prompt if present
    if (context.system_prompt) |system| {
        const system_blocks = try buildSystemPrompt(allocator, system, model, cache_retention);
        defer {
            for (system_blocks) |*block| {
                block.deinit(allocator);
            }
            allocator.free(system_blocks);
        }

        var system_array = std.ArrayList(std.json.Value).init(allocator);
        defer {
            for (system_array.items) |*item| item.deinit();
            system_array.deinit();
        }

        for (system_blocks) |block| {
            try system_array.append(try contentBlockToJson(allocator, block));
        }

        try payload.put("system", std.json.Value{ .array = system_array });
    }

    // Add inference config
    var inference_config = std.json.ObjectMap.init(allocator);
    if (options) |opts| {
        if (opts.max_tokens) |max| {
            try inference_config.put("maxTokens", std.json.Value{ .integer = @intCast(max) });
        }
        if (opts.temperature) |temp| {
            try inference_config.put("temperature", std.json.Value{ .float = temp });
        }
    }
    if (inference_config.count() > 0) {
        try payload.put("inferenceConfig", std.json.Value{ .object = inference_config });
    } else {
        inference_config.deinit();
    }

    // Add tool config if tools present
    if (context.tools) |tools| {
        const tool_config = try convertToolConfig(allocator, tools, null);
        defer tool_config.deinit(allocator);
        try payload.put("toolConfig", try toolConfigToJson(allocator, tool_config));
    }

    // Add additional model request fields for reasoning (Claude models)
    if (model.reasoning) {
        if (options) |opts| {
            const additional_fields = try buildAdditionalModelRequestFields(allocator, model, opts);
            if (additional_fields) |fields| {
                defer fields.deinit();
                try payload.put("additionalModelRequestFields", std.json.Value{ .object = fields });
            }
        }
    }

    const root = std.json.Value{ .object = payload };
    return std.json.stringifyAlloc(allocator, root, .{});
}

/// Parse a Bedrock event-stream event.
///
/// NOTE: Bedrock uses binary event-stream protocol, not SSE.
/// This function expects already-decoded JSON event data.
/// Full implementation requires AWS SDK-style event-stream parsing.
pub fn parseEvent(
    allocator: std.mem.Allocator,
    event_data: []const u8,
    state: *StreamState,
) !?types.AssistantMessageEvent {
    _ = allocator;
    _ = state;
    _ = event_data;

    // TODO: Implement binary event-stream protocol parsing
    // AWS event-stream format:
    // - 4 bytes: total message length
    // - 4 bytes: headers length
    // - Variable: headers (key-value pairs)
    // - Variable: payload (JSON)
    // - 4 bytes: CRC32 checksum

    // For now, return null to indicate not implemented
    return null;
}

// ============================================================================
// Internal helper functions
// ============================================================================

fn resolveCacheRetention(cache_retention: ?types.CacheRetention) types.CacheRetention {
    return cache_retention orelse .short;
}

fn buildSystemPrompt(
    allocator: std.mem.Allocator,
    system_prompt: []const u8,
    model: types.Model,
    cache_retention: types.CacheRetention,
) ![]ContentBlock {
    var blocks = std.ArrayList(ContentBlock).init(allocator);
    errdefer blocks.deinit();

    try blocks.append(.{ .text = try allocator.dupe(u8, system_prompt) });

    // Add cache point for supported Claude models
    if (cache_retention != .none and supportsPromptCaching(model)) {
        try blocks.append(.{ .cache_point = .{
            .type = .default,
            .ttl = if (cache_retention == .long) .one_hour else null,
        } });
    }

    return blocks.toOwnedSlice();
}

fn supportsPromptCaching(model: types.Model) bool {
    const id = std.ascii.lowerString(&[_:0]u8{}, model.id); // Note: stack allocation issue, need proper handling
    _ = id;
    // Claude models support caching
    // This is a simplified check - production code should be more robust
    return std.mem.indexOf(u8, &lowerSlice(model.id), "claude") != null;
}

fn lowerSlice(input: []const u8) [256]u8 {
    var result: [256]u8 = undefined;
    for (input, 0..) |c, i| {
        if (i >= 256) break;
        result[i] = std.ascii.toLower(c);
    }
    return result;
}

fn convertMessages(
    allocator: std.mem.Allocator,
    context: types.Context,
    model: types.Model,
    cache_retention: types.CacheRetention,
) ![]BedrockMessage {
    var result = std.ArrayList(BedrockMessage).init(allocator);
    defer result.deinit();

    for (context.messages) |msg| {
        switch (msg) {
            .user => |user_msg| {
                var content_blocks = std.ArrayList(ContentBlock).init(allocator);
                defer content_blocks.deinit();

                switch (user_msg.content) {
                    .text => |text| {
                        try content_blocks.append(.{ .text = try allocator.dupe(u8, text) });
                    },
                    .blocks => |blocks| {
                        for (blocks) |block| {
                            switch (block) {
                                .text => |t| {
                                    try content_blocks.append(.{ .text = try allocator.dupe(u8, t.text) });
                                },
                                .image => |img| {
                                    try content_blocks.append(.{
                                        .image = .{
                                            .format = parseImageFormat(img.mime_type),
                                            .source = .{ .bytes = try allocator.dupe(u8, img.data) },
                                        },
                                    });
                                },
                            }
                        }
                    },
                }

                try result.append(.{
                    .role = .user,
                    .content = try allocator.dupe(ContentBlock, content_blocks.items),
                });
            },
            .assistant => |assistant_msg| {
                // Skip empty assistant messages
                if (assistant_msg.content.len == 0) continue;

                var content_blocks = std.ArrayList(ContentBlock).init(allocator);
                defer content_blocks.deinit();

                for (assistant_msg.content) |block| {
                    switch (block) {
                        .text => |t| {
                            if (t.text.len > 0) {
                                try content_blocks.append(.{ .text = try allocator.dupe(u8, t.text) });
                            }
                        },
                        .thinking => |th| {
                            if (th.thinking.len > 0) {
                                const has_signature = th.thinking_signature != null and
                                    th.thinking_signature.?.len > 0;

                                if (supportsThinkingSignature(model) and has_signature) {
                                    try content_blocks.append(.{
                                        .reasoning_content = .{
                                            .reasoning_text = .{
                                                .text = try allocator.dupe(u8, th.thinking),
                                                .signature = if (th.thinking_signature) |sig|
                                                    try allocator.dupe(u8, sig)
                                                else
                                                    null,
                                            },
                                        },
                                    });
                                } else {
                                    // Fall back to plain text for non-Claude models or missing signatures
                                    try content_blocks.append(.{ .text = try allocator.dupe(u8, th.thinking) });
                                }
                            }
                        },
                        .tool_call => |tc| {
                            try content_blocks.append(.{
                                .tool_use = .{
                                    .tool_use_id = try allocator.dupe(u8, tc.id),
                                    .name = try allocator.dupe(u8, tc.name),
                                    .input = tc.arguments,
                                },
                            });
                        },
                    }
                }

                // Skip if all content blocks were filtered out
                if (content_blocks.items.len == 0) continue;

                try result.append(.{
                    .role = .assistant,
                    .content = try allocator.dupe(ContentBlock, content_blocks.items),
                });
            },
            .tool_result => |tool_result| {
                // Collect all consecutive tool results into a single user message
                var tool_results = std.ArrayList(ContentBlock).init(allocator);
                defer tool_results.deinit();

                // Add current tool result
                var result_content = std.ArrayList(ContentBlock.ToolResultBlock.ToolResultContent).init(allocator);
                defer result_content.deinit();

                for (tool_result.content) |content| {
                    switch (content) {
                        .text => |t| {
                            try result_content.append(.{ .text = try allocator.dupe(u8, t.text) });
                        },
                        .image => |img| {
                            try result_content.append(.{
                                .image = .{
                                    .format = parseImageFormat(img.mime_type),
                                    .source = .{ .bytes = try allocator.dupe(u8, img.data) },
                                },
                            });
                        },
                    }
                }

                try tool_results.append(.{
                    .tool_result = .{
                        .tool_use_id = try allocator.dupe(u8, tool_result.tool_call_id),
                        .content = try allocator.dupe(ContentBlock.ToolResultBlock.ToolResultContent, result_content.items),
                        .status = if (tool_result.is_error) .err else .success,
                    },
                });

                try result.append(.{
                    .role = .user,
                    .content = try allocator.dupe(ContentBlock, tool_results.items),
                });
            },
        }
    }

    // Add cache point to last user message for supported Claude models
    if (cache_retention != .none and supportsPromptCaching(model) and result.items.len > 0) {
        const last_idx = result.items.len - 1;
        if (result.items[last_idx].role == .user) {
            const old_content = result.items[last_idx].content;
            var new_content = try allocator.alloc(ContentBlock, old_content.len + 1);
            @memcpy(new_content[0..old_content.len], old_content);
            new_content[old_content.len] = .{
                .cache_point = .{
                    .type = .default,
                    .ttl = if (cache_retention == .long) .one_hour else null,
                },
            };
            allocator.free(old_content);
            result.items[last_idx].content = new_content;
        }
    }

    return result.toOwnedSlice();
}

fn parseImageFormat(mime_type: []const u8) ContentBlock.ImageBlock.ImageFormat {
    if (std.mem.eql(u8, mime_type, "image/jpeg") or std.mem.eql(u8, mime_type, "image/jpg")) {
        return .jpeg;
    } else if (std.mem.eql(u8, mime_type, "image/png")) {
        return .png;
    } else if (std.mem.eql(u8, mime_type, "image/gif")) {
        return .gif;
    } else if (std.mem.eql(u8, mime_type, "image/webp")) {
        return .webp;
    }
    return .jpeg; // Default fallback
}

fn supportsThinkingSignature(model: types.Model) bool {
    const id_lower = std.ascii.lowerString(&[_:0]u8{}, model.id);
    _ = id_lower;
    return std.mem.indexOf(u8, &lowerSlice(model.id), "anthropic") != null;
}

fn convertToolConfig(
    allocator: std.mem.Allocator,
    tools: []const types.Tool,
    tool_choice: ?BedrockOptions.ToolChoice,
) !ToolConfiguration {
    var bedrock_tools = std.ArrayList(ToolConfiguration.BedrockTool).init(allocator);
    defer bedrock_tools.deinit();

    for (tools) |tool| {
        try bedrock_tools.append(.{
            .tool_spec = .{
                .name = tool.name,
                .description = tool.description,
                .input_schema = .{ .json = tool.parameters },
            },
        });
    }

    var choice: ?ToolConfiguration.ToolChoiceSpec = null;
    if (tool_choice) |tc| {
        choice = switch (tc) {
            .auto => .{ .auto = .{} },
            .any => .{ .any = .{} },
            .none => null,
            .tool => |t| .{ .tool = .{ .name = t.name } },
        };
    }

    return .{
        .tools = try allocator.dupe(ToolConfiguration.BedrockTool, bedrock_tools.items),
        .tool_choice = choice,
    };
}

fn buildAdditionalModelRequestFields(
    allocator: std.mem.Allocator,
    model: types.Model,
    options: types.StreamOptions,
) !?std.json.ObjectMap {
    _ = options;
    // Only Claude models support thinking
    if (!supportsThinkingSignature(model)) return null;

    var result = std.json.ObjectMap.init(allocator);

    // For now, simplified - production would check model ID for adaptive thinking
    // and map thinking levels to appropriate budgets
    try result.put("thinking", std.json.Value{
        .object = blk: {
            var obj = std.json.ObjectMap.init(allocator);
            try obj.put("type", std.json.Value{ .string = "enabled" });
            try obj.put("budget_tokens", std.json.Value{ .integer = 8192 }); // Default medium budget
            break :blk obj;
        },
    });

    return result;
}

fn contentBlockToJson(allocator: std.mem.Allocator, block: ContentBlock) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);

    switch (block) {
        .text => |text| {
            try obj.put("text", std.json.Value{ .string = text });
        },
        .image => |img| {
            var image_obj = std.json.ObjectMap.init(allocator);
            try image_obj.put("format", std.json.Value{ .string = @tagName(img.format) });

            var source_obj = std.json.ObjectMap.init(allocator);
            // Note: bytes should be base64 encoded in actual implementation
            try source_obj.put("bytes", std.json.Value{ .string = img.source.bytes });
            try image_obj.put("source", std.json.Value{ .object = source_obj });

            try obj.put("image", std.json.Value{ .object = image_obj });
        },
        .tool_use => |tool| {
            var tool_obj = std.json.ObjectMap.init(allocator);
            try tool_obj.put("toolUseId", std.json.Value{ .string = tool.tool_use_id });
            try tool_obj.put("name", std.json.Value{ .string = tool.name });
            try tool_obj.put("input", tool.input);
            try obj.put("toolUse", std.json.Value{ .object = tool_obj });
        },
        .tool_result => |result| {
            var tool_obj = std.json.ObjectMap.init(allocator);
            try tool_obj.put("toolUseId", std.json.Value{ .string = result.tool_use_id });
            try tool_obj.put("status", std.json.Value{ .string = @tagName(result.status) });

            var content_array = std.ArrayList(std.json.Value).init(allocator);
            defer content_array.deinit();

            for (result.content) |content| {
                switch (content) {
                    .text => |text| {
                        try content_array.append(.{ .object = blk: {
                            var t = std.json.ObjectMap.init(allocator);
                            try t.put("text", std.json.Value{ .string = text });
                            break :blk t;
                        } });
                    },
                    .image => |img| {
                        try content_array.append(try contentBlockToJson(allocator, .{ .image = img }));
                    },
                }
            }
            try tool_obj.put("content", std.json.Value{ .array = content_array });
            try obj.put("toolResult", std.json.Value{ .object = tool_obj });
        },
        .reasoning_content => |reasoning| {
            var reasoning_obj = std.json.ObjectMap.init(allocator);
            var text_obj = std.json.ObjectMap.init(allocator);
            try text_obj.put("text", std.json.Value{ .string = reasoning.reasoning_text.text });
            if (reasoning.reasoning_text.signature) |sig| {
                try text_obj.put("signature", std.json.Value{ .string = sig });
            }
            try reasoning_obj.put("reasoningText", std.json.Value{ .object = text_obj });
            try obj.put("reasoningContent", std.json.Value{ .object = reasoning_obj });
        },
        .cache_point => |cache| {
            var cache_obj = std.json.ObjectMap.init(allocator);
            try cache_obj.put("type", std.json.Value{ .string = @tagName(cache.type) });
            if (cache.ttl) |ttl| {
                try cache_obj.put("ttl", std.json.Value{ .integer = @intFromEnum(ttl) });
            }
            try obj.put("cachePoint", std.json.Value{ .object = cache_obj });
        },
    }

    return std.json.Value{ .object = obj };
}

fn toolConfigToJson(allocator: std.mem.Allocator, config: ToolConfiguration) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);

    var tools_array = std.ArrayList(std.json.Value).init(allocator);
    defer tools_array.deinit();

    for (config.tools) |tool| {
        var tool_obj = std.json.ObjectMap.init(allocator);
        var spec_obj = std.json.ObjectMap.init(allocator);
        try spec_obj.put("name", std.json.Value{ .string = tool.tool_spec.name });
        try spec_obj.put("description", std.json.Value{ .string = tool.tool_spec.description });
        try spec_obj.put("inputSchema", std.json.Value{ .object = blk: {
            var s = std.json.ObjectMap.init(allocator);
            try s.put("json", tool.tool_spec.input_schema.json);
            break :blk s;
        } });
        try tool_obj.put("toolSpec", std.json.Value{ .object = spec_obj });
        try tools_array.append(std.json.Value{ .object = tool_obj });
    }

    try obj.put("tools", std.json.Value{ .array = tools_array });

    if (config.tool_choice) |choice| {
        const choice_json: std.json.Value = switch (choice) {
            .auto => .{ .object = blk: {
                var c = std.json.ObjectMap.init(allocator);
                try c.put("auto", std.json.Value{ .object = .{} });
                break :blk c;
            } },
            .any => .{ .object = blk: {
                var c = std.json.ObjectMap.init(allocator);
                try c.put("any", std.json.Value{ .object = .{} });
                break :blk c;
            } },
            .tool => |t| .{ .object = blk: {
                var c = std.json.ObjectMap.init(allocator);
                var tool_obj = std.json.ObjectMap.init(allocator);
                try tool_obj.put("name", std.json.Value{ .string = t.name });
                try c.put("tool", std.json.Value{ .object = tool_obj });
                break :blk c;
            } },
        };
        try obj.put("toolChoice", choice_json);
    }

    return std.json.Value{ .object = obj };
}

// Extension methods for deinit
fn ToolConfiguration_deinit(self: ToolConfiguration, allocator: std.mem.Allocator) void {
    allocator.free(self.tools);
}

fn ContentBlock_deinit(self: *ContentBlock, allocator: std.mem.Allocator) void {
    switch (self.*) {
        .text => |t| allocator.free(t),
        .image => |img| allocator.free(img.source.bytes),
        .tool_use => |tool| {
            allocator.free(tool.tool_use_id);
            allocator.free(tool.name);
        },
        .tool_result => |result| {
            allocator.free(result.tool_use_id);
            allocator.free(result.content);
        },
        .reasoning_content => |r| {
            allocator.free(r.reasoning_text.text);
            if (r.reasoning_text.signature) |s| allocator.free(s);
        },
        .cache_point => {},
    }
}
