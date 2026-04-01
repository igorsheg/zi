const std = @import("std");
const types = @import("../types.zig");

/// Google provider variant
pub const Variant = enum {
    /// Standard Google AI (generativelanguage.googleapis.com)
    google,
    /// Google Vertex AI
    vertex,
    /// Google Gemini CLI (different streaming format via WebSocket)
    gemini_cli,
};

/// Stream state for parsing Google responses
pub const StreamState = struct {
    /// Current text/thinking block being built
    current_block: ?BlockState = null,
    /// Counter for generating unique tool call IDs
    tool_call_counter: u32 = 0,
    /// Whether we've seen the first candidate
    has_started: bool = false,
    /// Accumulated finish reason
    stop_reason: types.StopReason = .stop,
    /// Accumulated usage metadata
    usage: types.Usage = .{
        .input = 0,
        .output = 0,
        .cache_read = 0,
        .cache_write = 0,
        .total_tokens = 0,
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 },
    },

    pub const BlockState = struct {
        block_type: enum { text, thinking },
        content: std.ArrayList(u8),
        signature: ?[]const u8,

        pub fn init(allocator: std.mem.Allocator, block_type: enum { text, thinking }, signature: ?[]const u8) BlockState {
            return .{
                .block_type = block_type,
                .content = std.ArrayList(u8).init(allocator),
                .signature = signature,
            };
        }

        pub fn deinit(self: *BlockState) void {
            self.content.deinit();
        }
    };

    pub fn deinit(self: *StreamState) void {
        if (self.current_block) |*block| {
            block.deinit();
        }
    }
};

/// Error types for Google provider
pub const GoogleError = error{
    InvalidJson,
    MissingRequiredField,
    UnsupportedVariant,
    OutOfMemory,
};

/// Build Google Generative AI request JSON
pub fn buildRequest(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
    variant: Variant,
) GoogleError![]u8 {
    // Gemini CLI is not yet supported
    if (variant == .gemini_cli) {
        return GoogleError.UnsupportedVariant;
    }

    var json = std.json.ObjectMap.init(allocator);
    errdefer json.deinit();

    // Add model parameter
    try json.put("model", std.json.Value{ .string = model.id });

    // Convert messages to Google contents format
    const contents = try convertMessages(allocator, model, context);
    defer {
        for (contents) |*content| {
            content.deinit();
        }
        allocator.free(contents);
    }

    var contents_array = std.json.Array.init(allocator);
    for (contents) |content| {
        try contents_array.append(try content.toJson(allocator));
    }
    try json.put("contents", std.json.Value{ .array = contents_array });

    // Build generation config
    var config = std.json.ObjectMap.init(allocator);
    errdefer config.deinit();

    if (options) |opts| {
        if (opts.temperature) |temp| {
            try config.put("temperature", std.json.Value{ .float = temp });
        }
        if (opts.max_tokens) |max| {
            try config.put("maxOutputTokens", std.json.Value{ .integer = @intCast(max) });
        }
    }

    // Add system instruction if present
    if (context.system_prompt) |prompt| {
        try json.put("systemInstruction", std.json.Value{
            .object = blk: {
                var sys_obj = std.json.ObjectMap.init(allocator);
                var parts = std.json.Array.init(allocator);
                try parts.append(std.json.Value{ .object = blk2: {
                    var text_obj = std.json.ObjectMap.init(allocator);
                    try text_obj.put("text", std.json.Value{ .string = prompt });
                    break :blk2 text_obj;
                } });
                try sys_obj.put("parts", std.json.Value{ .array = parts });
                break :blk sys_obj;
            },
        });
    }

    // Add tools if present
    if (context.tools) |tools| {
        if (tools.len > 0) {
            const tools_json = try convertTools(allocator, tools);
            try config.put("tools", tools_json);
        }
    }

    // Add thinking config if model supports reasoning
    if (model.reasoning) {
        const thinking_config = try buildThinkingConfig(allocator, model);
        try config.put("thinkingConfig", thinking_config);
    }

    if (config.count() > 0) {
        try json.put("generationConfig", std.json.Value{ .array = std.json.Array.init(allocator) });
    }

    // Add config if not empty
    if (config.count() > 0) {
        try json.put("config", std.json.Value{ .object = config });
    } else {
        config.deinit();
    }

    const root = std.json.Value{ .object = json };
    return std.json.stringifyAlloc(allocator, root, .{});
}

/// Parse a Google SSE/streaming event
pub fn parseEvent(
    allocator: std.mem.Allocator,
    event_data: []const u8,
    state: *StreamState,
) GoogleError!?types.AssistantMessageEvent {
    // Parse the JSON response
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, event_data, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return GoogleError.InvalidJson,
    };
    defer parsed.deinit();

    const root = parsed.value;

    // Extract candidates
    const candidates = root.object.get("candidates") orelse return null;
    if (candidates.array.items.len == 0) return null;

    const candidate = candidates.array.items[0];
    const candidate_content = candidate.object.get("content") orelse return null;
    const parts = candidate_content.object.get("parts") orelse return null;

    // Handle usage metadata if present
    if (root.object.get("usageMetadata")) |usage| {
        if (usage.object.get("promptTokenCount")) |prompt| {
            const cached = if (usage.object.get("cachedContentTokenCount")) |c|
                c.integer
            else
                0;
            state.usage.input = @intCast(prompt.integer - cached);
            state.usage.cache_read = @intCast(cached);
        }
        if (usage.object.get("candidatesTokenCount")) |cand| {
            const thoughts = if (usage.object.get("thoughtsTokenCount")) |t|
                t.integer
            else
                0;
            state.usage.output = @intCast(cand.integer + thoughts);
        }
        if (usage.object.get("totalTokenCount")) |total| {
            state.usage.total_tokens = @intCast(total.integer);
        }
    }

    // Handle finish reason
    if (candidate.object.get("finishReason")) |finish| {
        state.stop_reason = mapStopReason(finish.string);
    }

    // Process parts
    for (parts.array.items) |part| {
        // Check for text content
        if (part.object.get("text")) |text| {
            const is_thinking = isThinkingPart(part);

            // If changing block types, finish current block
            if (state.current_block) |*current| {
                const current_is_thinking = current.block_type == .thinking;
                if (is_thinking != current_is_thinking) {
                    // Emit end event for current block
                    const block_content = try current.content.toOwnedSlice();
                    defer allocator.free(block_content);

                    const event_type: types.AssistantMessageEvent = if (current_is_thinking)
                        .{ .thinking_end = .{ .content_index = 0, .content = block_content, .partial = undefined } }
                    else
                        .{ .text_end = .{ .content_index = 0, .content = block_content, .partial = undefined } };

                    current.deinit();
                    state.current_block = null;
                    return event_type;
                }
            }

            // Start new block if needed
            if (state.current_block == null) {
                const signature = getThoughtSignature(part);
                state.current_block = StreamState.BlockState.init(
                    allocator,
                    if (is_thinking) .thinking else .text,
                    signature,
                );

                const event_type: types.AssistantMessageEvent = if (is_thinking)
                    .{ .thinking_start = .{ .content_index = 0, .partial = undefined } }
                else
                    .{ .text_start = .{ .content_index = 0, .partial = undefined } };

                return event_type;
            }

            // Append to current block
            if (state.current_block) |*current| {
                const text_str = text.string;
                try current.content.appendSlice(text_str);

                const event_type: types.AssistantMessageEvent = if (current.block_type == .thinking)
                    .{ .thinking_delta = .{ .content_index = 0, .delta = text_str, .partial = undefined } }
                else
                    .{ .text_delta = .{ .content_index = 0, .delta = text_str, .partial = undefined } };

                return event_type;
            }
        }

        // Check for function call (tool call)
        if (part.object.get("functionCall")) |_| {
            // Finish any current block first
            if (state.current_block) |*current| {
                const block_content = try current.content.toOwnedSlice();
                defer allocator.free(block_content);

                const event_type: types.AssistantMessageEvent = if (current.block_type == .thinking)
                    .{ .thinking_end = .{ .content_index = 0, .content = block_content, .partial = undefined } }
                else
                    .{ .text_end = .{ .content_index = 0, .content = block_content, .partial = undefined } };

                current.deinit();
                state.current_block = null;
                return event_type;
            }

            // Generate tool call ID
            state.tool_call_counter += 1;
            _ = state.tool_call_counter; // Used for ID generation in full implementation

            // Return tool call start event
            return types.AssistantMessageEvent{
                .toolcall_start = .{ .content_index = 0, .partial = undefined },
            };
        }
    }

    return null;
}

/// Finish any pending block and emit final event
pub fn flushEvent(
    allocator: std.mem.Allocator,
    state: *StreamState,
) GoogleError!?types.AssistantMessageEvent {
    if (state.current_block) |*current| {
        const block_content = try current.content.toOwnedSlice();
        defer allocator.free(block_content);

        const event_type: types.AssistantMessageEvent = if (current.block_type == .thinking)
            .{ .thinking_end = .{ .content_index = 0, .content = block_content, .partial = undefined } }
        else
            .{ .text_end = .{ .content_index = 0, .content = block_content, .partial = undefined } };

        current.deinit();
        state.current_block = null;
        return event_type;
    }
    return null;
}

/// Build the URL for a Google API request
pub fn buildUrl(
    allocator: std.mem.Allocator,
    model: types.Model,
    variant: Variant,
    project: ?[]const u8,
    location: ?[]const u8,
) GoogleError![]u8 {
    return switch (variant) {
        .google => blk: {
            const base_url = if (model.base_url.len > 0)
                model.base_url
            else
                "https://generativelanguage.googleapis.com";
            break :blk std.fmt.allocPrint(allocator, "{s}/v1beta/models/{s}:streamGenerateContent", .{ base_url, model.id });
        },
        .vertex => blk: {
            const loc = location orelse return GoogleError.MissingRequiredField;
            const proj = project orelse return GoogleError.MissingRequiredField;
            break :blk std.fmt.allocPrint(
                allocator,
                "https://{s}-aiplatform.googleapis.com/v1/projects/{s}/locations/{s}/publishers/google/models/{s}:streamGenerateContent",
                .{ loc, proj, loc, model.id },
            );
        },
        .gemini_cli => return GoogleError.UnsupportedVariant,
    };
}

// ============================================================================
// Internal helpers
// ============================================================================

const Content = struct {
    role: []const u8,
    parts: std.ArrayList(Part),

    pub fn init(allocator: std.mem.Allocator, role: []const u8) Content {
        return .{
            .role = role,
            .parts = std.ArrayList(Part).init(allocator),
        };
    }

    pub fn deinit(self: *Content) void {
        for (self.parts.items) |*part| {
            part.deinit();
        }
        self.parts.deinit();
    }

    pub fn toJson(self: Content, allocator: std.mem.Allocator) !std.json.Value {
        var obj = std.json.ObjectMap.init(allocator);
        try obj.put("role", std.json.Value{ .string = self.role });

        var parts_array = std.json.Array.init(allocator);
        for (self.parts.items) |part| {
            try parts_array.append(try part.toJson(allocator));
        }
        try obj.put("parts", std.json.Value{ .array = parts_array });

        return std.json.Value{ .object = obj };
    }
};

const Part = struct {
    part_type: union(enum) {
        text: []const u8,
        inline_data: struct {
            mime_type: []const u8,
            data: []const u8,
        },
        function_call: struct {
            name: []const u8,
            args: std.json.Value,
            id: ?[]const u8,
            thought_signature: ?[]const u8,
        },
        function_response: struct {
            name: []const u8,
            response: std.json.Value,
            id: ?[]const u8,
        },
    },
    thought_signature: ?[]const u8,

    pub fn deinit(self: *Part) void {
        _ = self;
    }

    pub fn toJson(self: Part, allocator: std.mem.Allocator) !std.json.Value {
        var obj = std.json.ObjectMap.init(allocator);

        switch (self.part_type) {
            .text => |text| {
                try obj.put("text", std.json.Value{ .string = text });
            },
            .inline_data => |data| {
                var inline_obj = std.json.ObjectMap.init(allocator);
                try inline_obj.put("mimeType", std.json.Value{ .string = data.mime_type });
                try inline_obj.put("data", std.json.Value{ .string = data.data });
                try obj.put("inlineData", std.json.Value{ .object = inline_obj });
            },
            .function_call => |fc| {
                var func_obj = std.json.ObjectMap.init(allocator);
                try func_obj.put("name", std.json.Value{ .string = fc.name });
                try func_obj.put("args", fc.args);
                if (fc.id) |id| {
                    try func_obj.put("id", std.json.Value{ .string = id });
                }
                try obj.put("functionCall", std.json.Value{ .object = func_obj });
            },
            .function_response => |fr| {
                var func_obj = std.json.ObjectMap.init(allocator);
                try func_obj.put("name", std.json.Value{ .string = fr.name });
                try func_obj.put("response", fr.response);
                if (fr.id) |id| {
                    try func_obj.put("id", std.json.Value{ .string = id });
                }
                try obj.put("functionResponse", std.json.Value{ .object = func_obj });
            },
        }

        if (self.thought_signature) |sig| {
            try obj.put("thoughtSignature", std.json.Value{ .string = sig });
        }

        return std.json.Value{ .object = obj };
    }
};

fn convertMessages(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
) GoogleError![]Content {
    var contents = std.ArrayList(Content).init(allocator);
    errdefer {
        for (contents.items) |*c| {
            c.deinit();
        }
        contents.deinit();
    }

    // Check if we should normalize tool call IDs (for Claude models via Antigravity)
    const normalize_tool_ids = requiresToolCallId(model.id);

    for (context.messages) |msg| {
        switch (msg) {
            .user => |user_msg| {
                var content = Content.init(allocator, "user");

                switch (user_msg.content) {
                    .text => |text| {
                        try content.parts.append(.{
                            .part_type = .{ .text = sanitizeSurrogates(text) },
                            .thought_signature = null,
                        });
                    },
                    .blocks => |blocks| {
                        for (blocks) |block| {
                            switch (block) {
                                .text => |text| {
                                    try content.parts.append(.{
                                        .part_type = .{ .text = sanitizeSurrogates(text.text) },
                                        .thought_signature = null,
                                    });
                                },
                                .image => |image| {
                                    if (modelHasInputType(model, .image)) {
                                        try content.parts.append(.{
                                            .part_type = .{ .inline_data = .{
                                                .mime_type = image.mime_type,
                                                .data = image.data,
                                            } },
                                            .thought_signature = null,
                                        });
                                    }
                                },
                            }
                        }
                    },
                }

                if (content.parts.items.len > 0) {
                    try contents.append(content);
                } else {
                    content.deinit();
                }
            },
            .assistant => |assistant_msg| {
                var content = Content.init(allocator, "model");
                errdefer content.deinit();

                // Check if message is from same provider and model
                const is_same_provider_model = std.mem.eql(u8, @tagName(assistant_msg.provider), @tagName(model.provider)) and
                    std.mem.eql(u8, assistant_msg.model, model.id);

                for (assistant_msg.content) |block| {
                    switch (block) {
                        .text => |text| {
                            if (text.text.len == 0 or isEmpty(text.text)) continue;

                            const signature = resolveThoughtSignature(is_same_provider_model, text.text_signature);
                            try content.parts.append(.{
                                .part_type = .{ .text = sanitizeSurrogates(text.text) },
                                .thought_signature = signature,
                            });
                        },
                        .thinking => |thinking| {
                            if (thinking.thinking.len == 0 or isEmpty(thinking.thinking)) continue;

                            const signature = resolveThoughtSignature(is_same_provider_model, thinking.thinking_signature);

                            if (is_same_provider_model) {
                                // Keep as thinking block
                                try content.parts.append(.{
                                    .part_type = .{ .text = sanitizeSurrogates(thinking.thinking) },
                                    .thought_signature = signature,
                                });
                            } else {
                                // Convert to plain text
                                try content.parts.append(.{
                                    .part_type = .{ .text = sanitizeSurrogates(thinking.thinking) },
                                    .thought_signature = null,
                                });
                            }
                        },
                        .tool_call => |tc| {
                            const signature = resolveThoughtSignature(is_same_provider_model, tc.thought_signature);
                            const is_gemini3 = isGemini3Model(model.id);
                            const effective_signature = signature orelse (if (is_gemini3) SKIP_THOUGHT_SIGNATURE else null);

                            try content.parts.append(.{
                                .part_type = .{ .function_call = .{
                                    .name = tc.name,
                                    .args = tc.arguments,
                                    .id = if (normalize_tool_ids) normalizeToolCallId(allocator, tc.id) else null,
                                    .thought_signature = effective_signature,
                                } },
                                .thought_signature = effective_signature,
                            });
                        },
                    }
                }

                if (content.parts.items.len > 0) {
                    try contents.append(content);
                } else {
                    content.deinit();
                }
            },
            .tool_result => |tool_result| {
                // Extract text and image content
                var text_parts = std.ArrayList([]const u8).init(allocator);
                defer text_parts.deinit();
                var image_parts = std.ArrayList(types.ImageContent).init(allocator);
                defer image_parts.deinit();

                for (tool_result.content) |block| {
                    switch (block) {
                        .text => |text| try text_parts.append(text.text),
                        .image => |image| {
                            if (modelHasInputType(model, .image)) {
                                try image_parts.append(image);
                            }
                        },
                    }
                }

                const text_result = try std.mem.join(allocator, "\n", text_parts.items);
                defer allocator.free(text_result);

                const has_text = text_result.len > 0;
                const has_images = image_parts.items.len > 0;

                const response_value = if (has_text)
                    text_result
                else if (has_images)
                    "(see attached image)"
                else
                    "";

                const supports_multimodal = supportsMultimodalFunctionResponse(model.id);

                // Build response object
                var response_obj = std.json.ObjectMap.init(allocator);
                if (tool_result.is_error) {
                    try response_obj.put("error", std.json.Value{ .string = response_value });
                } else {
                    try response_obj.put("output", std.json.Value{ .string = response_value });
                }

                // Add image parts if supported
                if (has_images and supports_multimodal) {
                    var parts_array = std.json.Array.init(allocator);
                    for (image_parts.items) |img| {
                        var img_obj = std.json.ObjectMap.init(allocator);
                        try img_obj.put("mimeType", std.json.Value{ .string = img.mime_type });
                        try img_obj.put("data", std.json.Value{ .string = img.data });
                        try parts_array.append(std.json.Value{ .object = img_obj });
                    }
                    try response_obj.put("parts", std.json.Value{ .array = parts_array });
                }

                var content = Content.init(allocator, "user");
                errdefer content.deinit();

                // Check if we can merge with previous user turn
                var merged = false;
                if (contents.items.len > 0) {
                    const last = &contents.items[contents.items.len - 1];
                    if (std.mem.eql(u8, last.role, "user")) {
                        // Check if last turn has function responses
                        for (last.parts.items) |part| {
                            if (part.part_type == .function_response) {
                                // Merge into existing turn
                                try last.parts.append(.{
                                    .part_type = .{ .function_response = .{
                                        .name = tool_result.tool_name,
                                        .response = std.json.Value{ .object = response_obj },
                                        .id = if (normalize_tool_ids) normalizeToolCallId(allocator, tool_result.tool_call_id) else null,
                                    } },
                                    .thought_signature = null,
                                });
                                merged = true;
                                break;
                            }
                        }
                    }
                }

                if (!merged) {
                    try content.parts.append(.{
                        .part_type = .{ .function_response = .{
                            .name = tool_result.tool_name,
                            .response = std.json.Value{ .object = response_obj },
                            .id = if (normalize_tool_ids) normalizeToolCallId(allocator, tool_result.tool_call_id) else null,
                        } },
                        .thought_signature = null,
                    });
                    try contents.append(content);
                } else {
                    content.deinit();
                }

                // For Gemini < 3, add images in a separate user message
                if (has_images and !supports_multimodal) {
                    var image_content = Content.init(allocator, "user");
                    errdefer image_content.deinit();

                    try image_content.parts.append(.{
                        .part_type = .{ .text = "Tool result image:" },
                        .thought_signature = null,
                    });

                    for (image_parts.items) |img| {
                        try image_content.parts.append(.{
                            .part_type = .{ .inline_data = .{
                                .mime_type = img.mime_type,
                                .data = img.data,
                            } },
                            .thought_signature = null,
                        });
                    }

                    try contents.append(image_content);
                }
            },
        }
    }

    return contents.toOwnedSlice();
}

fn convertTools(
    allocator: std.mem.Allocator,
    tools: []const types.Tool,
) !std.json.Value {
    var tools_array = std.json.Array.init(allocator);

    var func_decls = std.json.Array.init(allocator);
    for (tools) |tool| {
        var func_obj = std.json.ObjectMap.init(allocator);
        try func_obj.put("name", std.json.Value{ .string = tool.name });
        try func_obj.put("description", std.json.Value{ .string = tool.description });
        try func_obj.put("parametersJsonSchema", tool.parameters);
        try func_decls.append(std.json.Value{ .object = func_obj });
    }

    var tool_obj = std.json.ObjectMap.init(allocator);
    try tool_obj.put("functionDeclarations", std.json.Value{ .array = func_decls });
    try tools_array.append(std.json.Value{ .object = tool_obj });

    return std.json.Value{ .array = tools_array };
}

fn buildThinkingConfig(
    allocator: std.mem.Allocator,
    model: types.Model,
) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);

    // Default: include thoughts
    try obj.put("includeThoughts", std.json.Value{ .bool = true });

    // Check if we have thinking budgets or levels
    // For now, use defaults based on model type
    if (isGemini3ProModel(model.id) or isGemini3FlashModel(model.id)) {
        // Gemini 3 uses thinking levels
        try obj.put("thinkingLevel", std.json.Value{ .string = "MEDIUM" });
    } else {
        // Gemini 2.x uses thinking budget
        try obj.put("thinkingBudget", std.json.Value{ .integer = -1 }); // Dynamic
    }

    return std.json.Value{ .object = obj };
}

fn isThinkingPart(part: std.json.Value) bool {
    // Check for thought: true marker
    if (part.object.get("thought")) |thought| {
        if (thought == .bool and thought.bool) {
            return true;
        }
    }
    return false;
}

fn getThoughtSignature(part: std.json.Value) ?[]const u8 {
    if (part.object.get("thoughtSignature")) |sig| {
        if (sig == .string and sig.string.len > 0) {
            return sig.string;
        }
    }
    return null;
}

fn isGemini3Model(model_id: []const u8) bool {
    const lower = std.ascii.lowerString(@constCast(&[0]u8{}), model_id); // Simplified check
    return std.mem.indexOf(u8, lower, "gemini-3") != null;
}

fn isGemini3ProModel(model_id: []const u8) bool {
    const lower_id = std.ascii.lowerString(@constCast(&[0]u8{}), model_id);
    return std.mem.indexOf(u8, lower_id, "gemini-3") != null and std.mem.indexOf(u8, lower_id, "-pro") != null;
}

fn isGemini3FlashModel(model_id: []const u8) bool {
    const lower_id = std.ascii.lowerString(@constCast(&[0]u8{}), model_id);
    return std.mem.indexOf(u8, lower_id, "gemini-3") != null and std.mem.indexOf(u8, lower_id, "-flash") != null;
}

fn requiresToolCallId(model_id: []const u8) bool {
    return std.mem.startsWith(u8, model_id, "claude-") or std.mem.startsWith(u8, model_id, "gpt-oss-");
}

fn supportsMultimodalFunctionResponse(model_id: []const u8) bool {
    // Gemini 3+ supports multimodal function responses
    if (isGemini3Model(model_id)) return true;
    // Default to true for other models (e.g., Claude via Antigravity)
    return true;
}

fn modelHasInputType(model: types.Model, input_type: types.Model.InputType) bool {
    for (model.input) |it| {
        if (it == input_type) return true;
    }
    return false;
}

fn mapStopReason(reason: ?[]const u8) types.StopReason {
    const r = reason orelse return .stop;

    if (std.mem.eql(u8, r, "STOP")) return .stop;
    if (std.mem.eql(u8, r, "MAX_TOKENS")) return .length;
    if (std.mem.eql(u8, r, "SAFETY")) return .@"error";
    if (std.mem.eql(u8, r, "RECITATION")) return .@"error";
    if (std.mem.eql(u8, r, "OTHER")) return .@"error";
    if (std.mem.eql(u8, r, "BLOCKLIST")) return .@"error";
    if (std.mem.eql(u8, r, "PROHIBITED_CONTENT")) return .@"error";
    if (std.mem.eql(u8, r, "SPII")) return .@"error";
    if (std.mem.eql(u8, r, "IMAGE_SAFETY")) return .@"error";
    if (std.mem.eql(u8, r, "MALFORMED_FUNCTION_CALL")) return .@"error";
    if (std.mem.eql(u8, r, "UNEXPECTED_TOOL_CALL")) return .@"error";

    return .@"error";
}

fn resolveThoughtSignature(is_same_provider_model: bool, signature: ?[]const u8) ?[]const u8 {
    if (!is_same_provider_model) return null;
    if (signature) |s| {
        if (isValidThoughtSignature(s)) return s;
    }
    return null;
}

fn isValidThoughtSignature(signature: []const u8) bool {
    if (signature.len == 0) return false;
    if (signature.len % 4 != 0) return false;

    // Check base64 pattern
    for (signature) |c| {
        const is_valid = (c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '+' or c == '/' or c == '=';
        if (!is_valid) return false;
    }
    return true;
}

fn normalizeToolCallId(allocator: std.mem.Allocator, id: []const u8) ![]const u8 {
    // Replace invalid characters with underscore, limit to 64 chars
    const result = try allocator.alloc(u8, @min(id.len, 64));
    for (result, 0..) |*c, i| {
        const ch = id[i];
        const is_valid = (ch >= 'a' and ch <= 'z') or
            (ch >= 'A' and ch <= 'Z') or
            (ch >= '0' and ch <= '9') or
            ch == '_' or ch == '-';
        c.* = if (is_valid) ch else '_';
    }
    return result;
}

fn isEmpty(str: []const u8) bool {
    for (str) |c| {
        if (!std.ascii.isWhitespace(c)) return false;
    }
    return true;
}

fn sanitizeSurrogates(text: []const u8) []const u8 {
    // Google APIs require valid Unicode - replace surrogates with replacement char
    // For now, just return as-is (proper implementation would scan for surrogates)
    return text;
}

const SKIP_THOUGHT_SIGNATURE = "skip_thought_signature_validator";
