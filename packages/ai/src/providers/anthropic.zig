const std = @import("std");
const types = @import("../types.zig");
const sse = @import("sse.zig");

/// Anthropic thinking effort levels
pub const AnthropicEffort = enum {
    low,
    medium,
    high,
    max,
};

/// Anthropic-specific options extending StreamOptions
pub const AnthropicOptions = struct {
    /// Enable extended thinking
    thinking_enabled: ?bool = null,
    /// Token budget for extended thinking (older models only)
    thinking_budget_tokens: ?u64 = null,
    /// Effort level for adaptive thinking (Opus 4.6 and Sonnet 4.6)
    effort: ?AnthropicEffort = null,
    /// Enable interleaved thinking (beta feature for older models)
    interleaved_thinking: ?bool = null,
};

/// Tool choice options
pub const ToolChoice = union(enum) {
    auto,
    any,
    none,
    tool: struct {
        name: []const u8,
    },
};

/// Stream state for tracking an Anthropic response
pub const StreamState = struct {
    allocator: std.mem.Allocator,
    /// Accumulated content blocks
    content_blocks: std.ArrayList(types.AssistantMessage.AssistantContentBlock),
    /// Current text being built
    current_text: std.ArrayList(u8),
    /// Current thinking content being built
    current_thinking: std.ArrayList(u8),
    /// Current tool JSON being built
    current_tool_json: std.ArrayList(u8),
    /// Usage statistics
    usage: types.Usage,
    /// Model ID from response
    model_id: []const u8,
    /// Response/message ID
    response_id: ?[]const u8,
    /// Current block type being processed
    current_block_type: BlockType,
    /// Current block index
    current_block_index: ?usize,
    /// Current tool call ID (when processing tool_use)
    current_tool_id: ?[]const u8,
    /// Current tool name
    current_tool_name: ?[]const u8,
    /// Stop reason from message_delta
    stop_reason: ?types.StopReason,

    pub const BlockType = enum {
        none,
        text,
        thinking,
        tool_use,
        redacted_thinking,
    };

    pub fn init(allocator: std.mem.Allocator) StreamState {
        return .{
            .allocator = allocator,
            .content_blocks = std.ArrayList(types.AssistantMessage.AssistantContentBlock).init(allocator),
            .current_text = std.ArrayList(u8).init(allocator),
            .current_thinking = std.ArrayList(u8).init(allocator),
            .current_tool_json = std.ArrayList(u8).init(allocator),
            .usage = .{
                .input = 0,
                .output = 0,
                .cache_read = 0,
                .cache_write = 0,
                .total_tokens = 0,
                .cost = .{
                    .input = 0,
                    .output = 0,
                    .cache_read = 0,
                    .cache_write = 0,
                    .total = 0,
                },
            },
            .model_id = "",
            .response_id = null,
            .current_block_type = .none,
            .current_block_index = null,
            .current_tool_id = null,
            .current_tool_name = null,
            .stop_reason = null,
        };
    }

    pub fn deinit(self: *StreamState) void {
        self.content_blocks.deinit();
        self.current_text.deinit();
        self.current_thinking.deinit();
        self.current_tool_json.deinit();
        if (self.response_id) |id| {
            self.allocator.free(id);
        }
        if (self.current_tool_id) |id| {
            self.allocator.free(id);
        }
        if (self.current_tool_name) |name| {
            self.allocator.free(name);
        }
    }

    /// Reset current accumulators
    pub fn resetCurrent(self: *StreamState) void {
        self.current_text.clearRetainingCapacity();
        self.current_thinking.clearRetainingCapacity();
        self.current_tool_json.clearRetainingCapacity();
        self.current_block_type = .none;
        self.current_block_index = null;
        if (self.current_tool_id) |id| {
            self.allocator.free(id);
            self.current_tool_id = null;
        }
        if (self.current_tool_name) |name| {
            self.allocator.free(name);
            self.current_tool_name = null;
        }
    }

    /// Build partial AssistantMessage for events
    pub fn buildPartialMessage(self: *const StreamState) types.AssistantMessage {
        return .{
            .content = self.content_blocks.items,
            .api = .anthropic_messages,
            .provider = .anthropic,
            .model = self.model_id,
            .response_id = self.response_id,
            .usage = self.usage,
            .stop_reason = self.stop_reason orelse .stop,
            .error_message = null,
            .timestamp = std.time.milliTimestamp(),
        };
    }
};

/// Check if model supports adaptive thinking (Opus 4.6 and Sonnet 4.6)
fn supportsAdaptiveThinking(model_id: []const u8) bool {
    return std.mem.indexOf(u8, model_id, "opus-4-6") != null or
        std.mem.indexOf(u8, model_id, "opus-4.6") != null or
        std.mem.indexOf(u8, model_id, "sonnet-4-6") != null or
        std.mem.indexOf(u8, model_id, "sonnet-4.6") != null;
}

/// Map ThinkingLevel to Anthropic effort
fn mapThinkingLevelToEffort(level: types.ThinkingLevel, model_id: []const u8) AnthropicEffort {
    const is_opus_46 = std.mem.indexOf(u8, model_id, "opus-4-6") != null or
        std.mem.indexOf(u8, model_id, "opus-4.6") != null;

    return switch (level) {
        .minimal => .low,
        .low => .low,
        .medium => .medium,
        .high => .high,
        .xhigh => if (is_opus_46) .max else .high,
    };
}

/// Normalize tool call ID to match Anthropic's required pattern
fn normalizeToolCallId(allocator: std.mem.Allocator, id: []const u8) ![]u8 {
    // Replace non-alphanumeric chars with underscore, truncate to 64 chars
    var result = try allocator.alloc(u8, @min(id.len, 64));
    for (id[0..result.len], 0..) |c, i| {
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') {
            result[i] = c;
        } else {
            result[i] = '_';
        }
    }
    return result;
}

/// Resolve cache retention preference
fn resolveCacheRetention(cache_retention: ?types.CacheRetention) types.CacheRetention {
    if (cache_retention) |cr| {
        return cr;
    }
    // Check environment variable (simplified - no env access in Zig directly)
    return .short;
}

/// Build cache control object
fn getCacheControl(base_url: []const u8, cache_retention: ?types.CacheRetention) ?std.json.Value {
    const retention = resolveCacheRetention(cache_retention);
    if (retention == .none) return null;

    // Long retention with Anthropic API gets 1h TTL
    const is_anthropic = std.mem.indexOf(u8, base_url, "api.anthropic.com") != null;
    if (retention == .long and is_anthropic) {
        return std.json.Value{ .object = std.json.ObjectMap.init(std.heap.page_allocator) };
        // Would need to properly build: { type: "ephemeral", ttl: "1h" }
    }

    return std.json.Value{ .object = std.json.ObjectMap.init(std.heap.page_allocator) };
    // Would need to properly build: { type: "ephemeral" }
}

/// Convert content blocks to Anthropic format (text or image)
fn convertContentBlocks(
    allocator: std.mem.Allocator,
    content: []const union { text: types.TextContent, image: types.ImageContent },
) !std.json.Value {
    // Check if any images present
    var has_images = false;
    for (content) |block| {
        if (block == .image) {
            has_images = true;
            break;
        }
    }

    // If only text, return as simple string
    if (!has_images) {
        var text_parts = std.ArrayList([]const u8).init(allocator);
        defer text_parts.deinit();

        for (content) |block| {
            if (block == .text) {
                try text_parts.append(block.text.text);
            }
        }

        const joined = try std.mem.join(allocator, "\n", text_parts.items);
        return std.json.Value{ .string = joined };
    }

    // Mixed content - build array of blocks
    var blocks = std.ArrayList(std.json.Value).init(allocator);
    defer blocks.deinit();

    var has_text = false;
    for (content) |block| {
        if (block == .text) {
            has_text = true;
            var text_block = std.json.ObjectMap.init(allocator);
            try text_block.put("type", std.json.Value{ .string = "text" });
            try text_block.put("text", std.json.Value{ .string = block.text.text });
            try blocks.append(std.json.Value{ .object = text_block });
        } else if (block == .image) {
            var image_block = std.json.ObjectMap.init(allocator);
            try image_block.put("type", std.json.Value{ .string = "image" });

            var source = std.json.ObjectMap.init(allocator);
            try source.put("type", std.json.Value{ .string = "base64" });
            try source.put("media_type", std.json.Value{ .string = block.image.mime_type });
            try source.put("data", std.json.Value{ .string = block.image.data });

            try image_block.put("source", std.json.Value{ .object = source });
            try blocks.append(std.json.Value{ .object = image_block });
        }
    }

    // If only images, add placeholder text
    if (!has_text) {
        var text_block = std.json.ObjectMap.init(allocator);
        try text_block.put("type", std.json.Value{ .string = "text" });
        try text_block.put("text", std.json.Value{ .string = "(see attached image)" });
        try blocks.insert(0, std.json.Value{ .object = text_block });
    }

    return std.json.Value{ .array = std.json.Array{ .items = blocks.items, .allocator = allocator } };
}

/// Convert our unified Tool array to Anthropic tool format
fn convertTools(
    allocator: std.mem.Allocator,
    tools: []const types.Tool,
    is_oauth: bool,
) !std.json.Value {
    var result = std.ArrayList(std.json.Value).init(allocator);
    defer result.deinit();

    for (tools) |tool| {
        var tool_obj = std.json.ObjectMap.init(allocator);

        const name = if (is_oauth) toClaudeCodeName(tool.name) else tool.name;
        try tool_obj.put("name", std.json.Value{ .string = name });
        try tool_obj.put("description", std.json.Value{ .string = tool.description });

        // Build input_schema from parameters
        var input_schema = std.json.ObjectMap.init(allocator);
        try input_schema.put("type", std.json.Value{ .string = "object" });

        // Extract properties and required from tool.parameters
        if (tool.parameters == .object) {
            if (tool.parameters.object.get("properties")) |props| {
                try input_schema.put("properties", props);
            } else {
                try input_schema.put("properties", std.json.Value{ .object = std.json.ObjectMap.init(allocator) });
            }
            if (tool.parameters.object.get("required")) |req| {
                try input_schema.put("required", req);
            } else {
                try input_schema.put("required", std.json.Value{ .array = std.json.Array.init(allocator) });
            }
        }

        try tool_obj.put("input_schema", std.json.Value{ .object = input_schema });
        try result.append(std.json.Value{ .object = tool_obj });
    }

    return std.json.Value{ .array = std.json.Array{ .items = result.items, .allocator = allocator } };
}

/// Claude Code tool names for canonical casing
const claude_code_tools = &[_][]const u8{
    "Read", "Write", "Edit", "Bash", "Grep", "Glob",
    "AskUserQuestion", "EnterPlanMode", "ExitPlanMode",
    "KillShell", "NotebookEdit", "Skill", "Task", "TaskOutput",
    "TodoWrite", "WebFetch", "WebSearch",
};

/// Convert tool name to Claude Code canonical casing
fn toClaudeCodeName(name: []const u8) []const u8 {
    for (claude_code_tools) |cc_name| {
        if (std.ascii.eqlIgnoreCase(cc_name, name)) {
            return cc_name;
        }
    }
    return name;
}

/// Convert from Claude Code name back to original tool name
fn fromClaudeCodeName(name: []const u8, tools: ?[]const types.Tool) []const u8 {
    if (tools) |t| {
        for (t) |tool| {
            if (std.ascii.eqlIgnoreCase(tool.name, name)) {
                return tool.name;
            }
        }
    }
    return name;
}

/// Convert messages to Anthropic format
fn convertMessages(
    allocator: std.mem.Allocator,
    messages: []const types.Message,
    model: types.Model,
    is_oauth: bool,
    cache_control: ?std.json.Value,
) !std.json.Value {
    var result = std.ArrayList(std.json.Value).init(allocator);
    defer result.deinit();

    var i: usize = 0;
    while (i < messages.len) : (i += 1) {
        const msg = messages[i];

        switch (msg) {
            .user => |user_msg| {
                var msg_obj = std.json.ObjectMap.init(allocator);
                try msg_obj.put("role", std.json.Value{ .string = "user" });

                switch (user_msg.content) {
                    .text => |text| {
                        if (std.mem.trim(u8, text, " \t\n\r").len > 0) {
                            try msg_obj.put("content", std.json.Value{ .string = text });
                            try result.append(std.json.Value{ .object = msg_obj });
                        }
                    },
                    .blocks => |blocks| {
                        var content_blocks = std.ArrayList(std.json.Value).init(allocator);
                        defer content_blocks.deinit();

                        var has_images = false;
                        for (blocks) |block| {
                            switch (block) {
                                .text => |t| {
                                    var text_block = std.json.ObjectMap.init(allocator);
                                    try text_block.put("type", std.json.Value{ .string = "text" });
                                    try text_block.put("text", std.json.Value{ .string = t.text });
                                    try content_blocks.append(std.json.Value{ .object = text_block });
                                },
                                .image => |img| {
                                    has_images = true;
                                    if (std.mem.indexOf(u8, model.input, "image") != null) {
                                        var image_block = std.json.ObjectMap.init(allocator);
                                        try image_block.put("type", std.json.Value{ .string = "image" });

                                        var source = std.json.ObjectMap.init(allocator);
                                        try source.put("type", std.json.Value{ .string = "base64" });
                                        try source.put("media_type", std.json.Value{ .string = img.mime_type });
                                        try source.put("data", std.json.Value{ .string = img.data });

                                        try image_block.put("source", std.json.Value{ .object = source });
                                        try content_blocks.append(std.json.Value{ .object = image_block });
                                    }
                                },
                            }
                        }

                        // Filter empty text blocks
                        var filtered = std.ArrayList(std.json.Value).init(allocator);
                        defer filtered.deinit();
                        for (content_blocks.items) |block| {
                            if (block == .object) {
                                if (block.object.get("type")) |t| {
                                    if (t == .string and std.mem.eql(u8, t.string, "text")) {
                                        if (block.object.get("text")) |txt| {
                                            if (txt == .string and std.mem.trim(u8, txt.string, " \t\n\r").len > 0) {
                                                try filtered.append(block);
                                            }
                                        }
                                    } else {
                                        try filtered.append(block);
                                    }
                                }
                            }
                        }

                        if (filtered.items.len > 0) {
                            try msg_obj.put("content", std.json.Value{ .array = std.json.Array{ .items = filtered.items, .allocator = allocator } });
                            try result.append(std.json.Value{ .object = msg_obj });
                        }
                    },
                }
            },
            .assistant => |assistant_msg| {
                var msg_obj = std.json.ObjectMap.init(allocator);
                try msg_obj.put("role", std.json.Value{ .string = "assistant" });

                var blocks = std.ArrayList(std.json.Value).init(allocator);
                defer blocks.deinit();

                for (assistant_msg.content) |block| {
                    switch (block) {
                        .text => |t| {
                            if (std.mem.trim(u8, t.text, " \t\n\r").len > 0) {
                                var text_block = std.json.ObjectMap.init(allocator);
                                try text_block.put("type", std.json.Value{ .string = "text" });
                                try text_block.put("text", std.json.Value{ .string = t.text });
                                try blocks.append(std.json.Value{ .object = text_block });
                            }
                        },
                        .thinking => |th| {
                            if (th.redacted) {
                                // Redacted thinking block
                                var redacted_block = std.json.ObjectMap.init(allocator);
                                try redacted_block.put("type", std.json.Value{ .string = "redacted_thinking" });
                                if (th.thinking_signature) |sig| {
                                    try redacted_block.put("data", std.json.Value{ .string = sig });
                                }
                                try blocks.append(std.json.Value{ .object = redacted_block });
                            } else if (std.mem.trim(u8, th.thinking, " \t\n\r").len > 0) {
                                // Normal thinking block with signature
                                if (th.thinking_signature) |sig| {
                                    if (sig.len > 0) {
                                        var thinking_block = std.json.ObjectMap.init(allocator);
                                        try thinking_block.put("type", std.json.Value{ .string = "thinking" });
                                        try thinking_block.put("thinking", std.json.Value{ .string = th.thinking });
                                        try thinking_block.put("signature", std.json.Value{ .string = sig });
                                        try blocks.append(std.json.Value{ .object = thinking_block });
                                    } else {
                                        // No signature - convert to text
                                        var text_block = std.json.ObjectMap.init(allocator);
                                        try text_block.put("type", std.json.Value{ .string = "text" });
                                        try text_block.put("text", std.json.Value{ .string = th.thinking });
                                        try blocks.append(std.json.Value{ .object = text_block });
                                    }
                                } else {
                                    // No signature - convert to text
                                    var text_block = std.json.ObjectMap.init(allocator);
                                    try text_block.put("type", std.json.Value{ .string = "text" });
                                    try text_block.put("text", std.json.Value{ .string = th.thinking });
                                    try blocks.append(std.json.Value{ .object = text_block });
                                }
                            }
                        },
                        .tool_call => |tc| {
                            var tool_block = std.json.ObjectMap.init(allocator);
                            try tool_block.put("type", std.json.Value{ .string = "tool_use" });
                            try tool_block.put("id", std.json.Value{ .string = tc.id });

                            const tool_name = if (is_oauth) toClaudeCodeName(tc.name) else tc.name;
                            try tool_block.put("name", std.json.Value{ .string = tool_name });
                            try tool_block.put("input", tc.arguments);

                            try blocks.append(std.json.Value{ .object = tool_block });
                        },
                    }
                }

                if (blocks.items.len > 0) {
                    try msg_obj.put("content", std.json.Value{ .array = std.json.Array{ .items = blocks.items, .allocator = allocator } });
                    try result.append(std.json.Value{ .object = msg_obj });
                }
            },
            .tool_result => |tr| {
                // Collect all consecutive tool results
                var tool_results = std.ArrayList(std.json.Value).init(allocator);
                defer tool_results.deinit();

                // Add current tool result
                var tool_result_block = std.json.ObjectMap.init(allocator);
                try tool_result_block.put("type", std.json.Value{ .string = "tool_result" });
                try tool_result_block.put("tool_use_id", std.json.Value{ .string = tr.tool_call_id });

                const converted = try convertContentBlocks(allocator, tr.content);
                try tool_result_block.put("content", converted);
                try tool_result_block.put("is_error", std.json.Value{ .bool = tr.is_error });

                try tool_results.append(std.json.Value{ .object = tool_result_block });

                // Look ahead for consecutive tool results
                var j = i + 1;
                while (j < messages.len) : (j += 1) {
                    if (messages[j] == .tool_result) {
                        const next_tr = messages[j].tool_result;
                        var next_block = std.json.ObjectMap.init(allocator);
                        try next_block.put("type", std.json.Value{ .string = "tool_result" });
                        try next_block.put("tool_use_id", std.json.Value{ .string = next_tr.tool_call_id });

                        const next_converted = try convertContentBlocks(allocator, next_tr.content);
                        try next_block.put("content", next_converted);
                        try next_block.put("is_error", std.json.Value{ .bool = next_tr.is_error });

                        try tool_results.append(std.json.Value{ .object = next_block });
                    } else {
                        break;
                    }
                }

                // Skip processed messages
                i = j - 1;

                // Add user message with all tool results
                var msg_obj = std.json.ObjectMap.init(allocator);
                try msg_obj.put("role", std.json.Value{ .string = "user" });
                try msg_obj.put("content", std.json.Value{ .array = std.json.Array{ .items = tool_results.items, .allocator = allocator } });
                try result.append(std.json.Value{ .object = msg_obj });
            },
        }
    }

    // Add cache_control to last user message block
    if (cache_control) |cc| {
        if (result.items.len > 0) {
            const last = &result.items[result.items.len - 1];
            if (last == .object) {
                if (last.object.get("role")) |role| {
                    if (role == .string and std.mem.eql(u8, role.string, "user")) {
                        // Add cache_control to the last block in the message
                        if (last.object.get("content")) |content| {
                            if (content == .array and content.array.items.len > 0) {
                                const last_block = &content.array.items[content.array.items.len - 1];
                                if (last_block == .object) {
                                    try last_block.object.put("cache_control", cc);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    return std.json.Value{ .array = std.json.Array{ .items = result.items, .allocator = allocator } };
}

/// Build Anthropic API request JSON from unified types
pub fn buildRequest(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
    anthropic_options: ?AnthropicOptions,
) ![]u8 {
    var root = std.json.ObjectMap.init(allocator);
    defer root.deinit();

    // Model ID
    try root.put("model", std.json.Value{ .string = model.id });

    // Max tokens - default to model max / 3 if not specified
    const max_tokens = if (options) |o| o.max_tokens else null;
    const effective_max_tokens = max_tokens orelse model.max_tokens / 3;
    try root.put("max_tokens", std.json.Value{ .integer = @intCast(effective_max_tokens) });

    // Stream flag
    try root.put("stream", std.json.Value{ .bool = true });

    // System prompt
    const cache_control = getCacheControl(model.base_url, if (options) |o| o.cache_retention else null);
    if (context.system_prompt) |sys| {
        var system_blocks = std.ArrayList(std.json.Value).init(allocator);
        defer system_blocks.deinit();

        var system_block = std.json.ObjectMap.init(allocator);
        try system_block.put("type", std.json.Value{ .string = "text" });
        try system_block.put("text", std.json.Value{ .string = sys });
        if (cache_control) |cc| {
            try system_block.put("cache_control", cc);
        }
        try system_blocks.append(std.json.Value{ .object = system_block });

        try root.put("system", std.json.Value{ .array = std.json.Array{ .items = system_blocks.items, .allocator = allocator } });
    }

    // Messages
    const is_oauth = blk: {
        if (options) |o| {
            if (o.api_key) |key| {
                break :blk std.mem.indexOf(u8, key, "sk-ant-oat") != null;
            }
        }
        break :blk false;
    };

    const messages = try convertMessages(allocator, context.messages, model, is_oauth, cache_control);
    try root.put("messages", messages);

    // Temperature (incompatible with extended thinking)
    const thinking_enabled = if (anthropic_options) |ao| ao.thinking_enabled else null;
    if (options) |o| {
        if (o.temperature) |temp| {
            if (!(thinking_enabled orelse false)) {
                try root.put("temperature", std.json.Value{ .float = temp });
            }
        }
    }

    // Tools
    if (context.tools) |tools| {
        const converted_tools = try convertTools(allocator, tools, is_oauth);
        try root.put("tools", converted_tools);
    }

    // Thinking configuration
    if (model.reasoning) {
        if (thinking_enabled orelse false) {
            if (supportsAdaptiveThinking(model.id)) {
                // Adaptive thinking
                var thinking = std.json.ObjectMap.init(allocator);
                try thinking.put("type", std.json.Value{ .string = "adaptive" });
                try root.put("thinking", std.json.Value{ .object = thinking });

                // Effort level
                if (anthropic_options) |ao| {
                    if (ao.effort) |effort| {
                        var output_config = std.json.ObjectMap.init(allocator);
                        try output_config.put("effort", std.json.Value{ .string = @tagName(effort) });
                        try root.put("output_config", std.json.Value{ .object = output_config });
                    }
                }
            } else {
                // Budget-based thinking for older models
                var thinking = std.json.ObjectMap.init(allocator);
                try thinking.put("type", std.json.Value{ .string = "enabled" });
                const budget = if (anthropic_options) |ao| ao.thinking_budget_tokens else null;
                try thinking.put("budget_tokens", std.json.Value{ .integer = @intCast(budget orelse 1024) });
                try root.put("thinking", std.json.Value{ .object = thinking });
            }
        } else if (thinking_enabled == false) {
            var thinking = std.json.ObjectMap.init(allocator);
            try thinking.put("type", std.json.Value{ .string = "disabled" });
            try root.put("thinking", std.json.Value{ .object = thinking });
        }
    }

    // Metadata
    if (options) |o| {
        if (o.metadata) |metadata| {
            if (metadata == .object) {
                if (metadata.object.get("user_id")) |user_id| {
                    var meta = std.json.ObjectMap.init(allocator);
                    try meta.put("user_id", user_id);
                    try root.put("metadata", std.json.Value{ .object = meta });
                }
            }
        }
    }

    // Serialize to JSON
    const value = std.json.Value{ .object = root };
    return try std.json.stringifyAlloc(allocator, value, .{});
}

/// Map Anthropic stop reason to unified StopReason
fn mapStopReason(reason: []const u8) types.StopReason {
    if (std.mem.eql(u8, reason, "end_turn")) return .stop;
    if (std.mem.eql(u8, reason, "max_tokens")) return .length;
    if (std.mem.eql(u8, reason, "tool_use")) return .tool_use;
    if (std.mem.eql(u8, reason, "refusal")) return .@"error";
    if (std.mem.eql(u8, reason, "pause_turn")) return .stop;
    if (std.mem.eql(u8, reason, "stop_sequence")) return .stop;
    if (std.mem.eql(u8, reason, "sensitive")) return .@"error";
    return .@"error";
}

/// Parse streaming JSON (best effort parsing of partial JSON)
fn parseStreamingJson(allocator: std.mem.Allocator, partial_json: []const u8) !std.json.Value {
    // Try to parse as is first
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        partial_json,
        .{ .ignore_unknown_fields = true },
    ) catch {
        // If that fails, try adding closing braces/brackets
        const fixed = try allocator.dupe(u8, partial_json);
        defer allocator.free(fixed);

        // Count open braces/brackets
        var open_braces: usize = 0;
        var open_brackets: usize = 0;
        for (fixed) |c| {
            if (c == '{') open_braces += 1;
            if (c == '}') open_braces -= 1;
            if (c == '[') open_brackets += 1;
            if (c == ']') open_brackets -= 1;
        }

        // Append closing characters
        var extra = std.ArrayList(u8).init(allocator);
        defer extra.deinit();
        while (open_braces > 0) : (open_braces -= 1) {
            try extra.append('}');
        }
        while (open_brackets > 0) : (open_brackets -= 1) {
            try extra.append(']');
        }

        const combined = try std.mem.concat(allocator, u8, &.{ fixed, extra.items });
        defer allocator.free(combined);

        return std.json.parseFromSlice(
            std.json.Value,
            allocator,
            combined,
            .{ .ignore_unknown_fields = true },
        ) catch {
            // Return empty object if all parsing fails
            return std.json.Value{ .object = std.json.ObjectMap.init(allocator) };
        };
    };

    defer parsed.deinit();
    return try parsed.value.clone(allocator);
}

/// Parse an Anthropic SSE event and produce AssistantMessageEvents
pub fn parseEvent(
    allocator: std.mem.Allocator,
    event: sse.SseEvent,
    state: *StreamState,
    tools: ?[]const types.Tool,
) !?types.AssistantMessageEvent {
    const event_type = event.event orelse return null;
    const data = event.data;

    if (std.mem.eql(u8, event_type, "message_start")) {
        return try parseMessageStart(allocator, data, state);
    } else if (std.mem.eql(u8, event_type, "content_block_start")) {
        return try parseContentBlockStart(allocator, data, state, tools);
    } else if (std.mem.eql(u8, event_type, "content_block_delta")) {
        return try parseContentBlockDelta(allocator, data, state);
    } else if (std.mem.eql(u8, event_type, "content_block_stop")) {
        return try parseContentBlockStop(allocator, state);
    } else if (std.mem.eql(u8, event_type, "message_delta")) {
        return try parseMessageDelta(allocator, data, state);
    } else if (std.mem.eql(u8, event_type, "message_stop")) {
        return try parseMessageStop(allocator, state);
    } else if (std.mem.eql(u8, event_type, "error")) {
        return types.AssistantMessageEvent{ .@"error" = .{
            .reason = .@"error",
            .@"error" = state.buildPartialMessage(),
        } };
    }

    return null;
}

fn parseMessageStart(
    allocator: std.mem.Allocator,
    data: []const u8,
    state: *StreamState,
) !?types.AssistantMessageEvent {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        data,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return null;

    // Extract message ID
    if (root.object.get("message")) |msg| {
        if (msg == .object) {
            if (msg.object.get("id")) |id| {
                if (id == .string) {
                    state.response_id = try state.allocator.dupe(u8, id.string);
                }
            }

            // Extract usage
            if (msg.object.get("usage")) |usage| {
                if (usage == .object) {
                    if (usage.object.get("input_tokens")) |t| {
                        if (t == .integer) state.usage.input = @intCast(t.integer);
                    }
                    if (usage.object.get("output_tokens")) |t| {
                        if (t == .integer) state.usage.output = @intCast(t.integer);
                    }
                    if (usage.object.get("cache_read_input_tokens")) |t| {
                        if (t == .integer) state.usage.cache_read = @intCast(t.integer);
                    }
                    if (usage.object.get("cache_creation_input_tokens")) |t| {
                        if (t == .integer) state.usage.cache_write = @intCast(t.integer);
                    }
                }
            }

            // Extract model
            if (msg.object.get("model")) |m| {
                if (m == .string) {
                    state.model_id = m.string;
                }
            }
        }
    }

    // Calculate total tokens
    state.usage.total_tokens = state.usage.input +
        state.usage.output +
        state.usage.cache_read +
        state.usage.cache_write;

    return types.AssistantMessageEvent{ .start = .{ .partial = state.buildPartialMessage() } };
}

fn parseContentBlockStart(
    allocator: std.mem.Allocator,
    data: []const u8,
    state: *StreamState,
    tools: ?[]const types.Tool,
) !?types.AssistantMessageEvent {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        data,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return null;

    // Get block index
    if (root.object.get("index")) |idx| {
        if (idx == .integer) {
            state.current_block_index = @intCast(idx.integer);
        }
    }

    // Get content block type
    if (root.object.get("content_block")) |block| {
        if (block == .object) {
            if (block.object.get("type")) |t| {
                if (t == .string) {
                    if (std.mem.eql(u8, t.string, "text")) {
                        state.current_block_type = .text;
                        state.current_text.clearRetainingCapacity();

                        // Add new text block to content
                        try state.content_blocks.append(.{ .text = .{ .text = "" } });

                        return types.AssistantMessageEvent{ .text_start = .{
                            .content_index = state.content_blocks.items.len - 1,
                            .partial = state.buildPartialMessage(),
                        } };
                    } else if (std.mem.eql(u8, t.string, "thinking")) {
                        state.current_block_type = .thinking;
                        state.current_thinking.clearRetainingCapacity();

                        // Add new thinking block
                        try state.content_blocks.append(.{ .thinking = .{ .thinking = "", .redacted = false } });

                        return types.AssistantMessageEvent{ .thinking_start = .{
                            .content_index = state.content_blocks.items.len - 1,
                            .partial = state.buildPartialMessage(),
                        } };
                    } else if (std.mem.eql(u8, t.string, "redacted_thinking")) {
                        state.current_block_type = .redacted_thinking;

                        var thinking_content = types.ThinkingContent{
                            .thinking = "[Reasoning redacted]",
                            .redacted = true,
                        };

                        if (block.object.get("data")) |d| {
                            if (d == .string) {
                                thinking_content.thinking_signature = d.string;
                            }
                        }

                        try state.content_blocks.append(.{ .thinking = thinking_content });

                        return types.AssistantMessageEvent{ .thinking_start = .{
                            .content_index = state.content_blocks.items.len - 1,
                            .partial = state.buildPartialMessage(),
                        } };
                    } else if (std.mem.eql(u8, t.string, "tool_use")) {
                        state.current_block_type = .tool_use;
                        state.current_tool_json.clearRetainingCapacity();

                        // Extract tool use details
                        var tool_call = types.ToolCall{
                            .id = "",
                            .name = "",
                            .arguments = std.json.Value{ .object = std.json.ObjectMap.init(allocator) },
                        };

                        if (block.object.get("id")) |id| {
                            if (id == .string) {
                                tool_call.id = id.string;
                                state.current_tool_id = try state.allocator.dupe(u8, id.string);
                            }
                        }

                        if (block.object.get("name")) |n| {
                            if (n == .string) {
                                const original_name = fromClaudeCodeName(n.string, tools);
                                tool_call.name = original_name;
                                state.current_tool_name = try state.allocator.dupe(u8, original_name);
                            }
                        }

                        if (block.object.get("input")) |input| {
                            tool_call.arguments = try input.clone(allocator);
                        }

                        try state.content_blocks.append(.{ .tool_call = tool_call });

                        return types.AssistantMessageEvent{ .toolcall_start = .{
                            .content_index = state.content_blocks.items.len - 1,
                            .partial = state.buildPartialMessage(),
                        } };
                    }
                }
            }
        }
    }

    return null;
}

fn parseContentBlockDelta(
    allocator: std.mem.Allocator,
    data: []const u8,
    state: *StreamState,
) !?types.AssistantMessageEvent {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        data,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return null;

    // Get block index
    var block_index: usize = 0;
    if (root.object.get("index")) |idx| {
        if (idx == .integer) {
            block_index = @intCast(idx.integer);
        }
    }

    if (root.object.get("delta")) |delta| {
        if (delta == .object) {
            // Text delta
            if (delta.object.get("type")) |t| {
                if (t == .string and std.mem.eql(u8, t.string, "text_delta")) {
                    if (delta.object.get("text")) |txt| {
                        if (txt == .string) {
                            try state.current_text.appendSlice(txt.string);

                            // Update the content block
                            if (block_index < state.content_blocks.items.len) {
                                const block = &state.content_blocks.items[block_index];
                                if (block.* == .text) {
                                    // Free old string and replace
                                    block.text.text = try state.allocator.dupe(u8, state.current_text.items);
                                }
                            }

                            return types.AssistantMessageEvent{ .text_delta = .{
                                .content_index = block_index,
                                .delta = txt.string,
                                .partial = state.buildPartialMessage(),
                            } };
                        }
                    }
                }
            }

            // Thinking delta
            if (delta.object.get("thinking")) |th| {
                if (th == .string) {
                    try state.current_thinking.appendSlice(th.string);

                    // Update the content block
                    if (block_index < state.content_blocks.items.len) {
                        const block = &state.content_blocks.items[block_index];
                        if (block.* == .thinking) {
                            block.thinking.thinking = try state.allocator.dupe(u8, state.current_thinking.items);
                        }
                    }

                    return types.AssistantMessageEvent{ .thinking_delta = .{
                        .content_index = block_index,
                        .delta = th.string,
                        .partial = state.buildPartialMessage(),
                    } };
                }
            }

            // Input JSON delta (for tool calls)
            if (delta.object.get("partial_json")) |pj| {
                if (pj == .string) {
                    try state.current_tool_json.appendSlice(pj.string);

                    // Try to parse the accumulated JSON
                    const parsed_args = try parseStreamingJson(allocator, state.current_tool_json.items);

                    // Update the content block
                    if (block_index < state.content_blocks.items.len) {
                        const block = &state.content_blocks.items[block_index];
                        if (block.* == .tool_call) {
                            block.tool_call.arguments = parsed_args;
                        }
                    }

                    return types.AssistantMessageEvent{ .toolcall_delta = .{
                        .content_index = block_index,
                        .delta = pj.string,
                        .partial = state.buildPartialMessage(),
                    } };
                }
            }

            // Signature delta (for thinking)
            if (delta.object.get("signature")) |sig| {
                if (sig == .string) {
                    if (block_index < state.content_blocks.items.len) {
                        const block = &state.content_blocks.items[block_index];
                        if (block.* == .thinking) {
                            if (block.thinking.thinking_signature) |existing| {
                                const new_sig = try std.mem.concat(allocator, u8, &.{ existing, sig.string });
                                allocator.free(existing);
                                block.thinking.thinking_signature = new_sig;
                            } else {
                                block.thinking.thinking_signature = try allocator.dupe(u8, sig.string);
                            }
                        }
                    }
                }
            }
        }
    }

    return null;
}

fn parseContentBlockStop(
    allocator: std.mem.Allocator,
    state: *StreamState,
) !?types.AssistantMessageEvent {
    const block_index = state.content_blocks.items.len - 1;
    if (block_index >= state.content_blocks.items.len) return null;

    const block = &state.content_blocks.items[block_index];

    switch (state.current_block_type) {
        .text => {
            const content = try state.allocator.dupe(u8, state.current_text.items);
            block.text.text = content;

            const event = types.AssistantMessageEvent{ .text_end = .{
                .content_index = block_index,
                .content = content,
                .partial = state.buildPartialMessage(),
            } };

            state.resetCurrent();
            return event;
        },
        .thinking, .redacted_thinking => {
            const content = try state.allocator.dupe(u8, state.current_thinking.items);
            block.thinking.thinking = content;

            const event = types.AssistantMessageEvent{ .thinking_end = .{
                .content_index = block_index,
                .content = content,
                .partial = state.buildPartialMessage(),
            } };

            state.resetCurrent();
            return event;
        },
        .tool_use => {
            // Parse final JSON
            const final_args = try parseStreamingJson(allocator, state.current_tool_json.items);
            block.tool_call.arguments = final_args;

            // Make a copy of the tool call for the event
            const tool_call_copy = types.ToolCall{
                .id = block.tool_call.id,
                .name = block.tool_call.name,
                .arguments = try final_args.clone(allocator),
            };

            const event = types.AssistantMessageEvent{ .toolcall_end = .{
                .content_index = block_index,
                .tool_call = tool_call_copy,
                .partial = state.buildPartialMessage(),
            } };

            state.resetCurrent();
            return event;
        },
        .none => return null,
    }
}

fn parseMessageDelta(
    allocator: std.mem.Allocator,
    data: []const u8,
    state: *StreamState,
) !?types.AssistantMessageEvent {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        data,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return null;

    // Update stop reason
    if (root.object.get("delta")) |delta| {
        if (delta == .object) {
            if (delta.object.get("stop_reason")) |sr| {
                if (sr == .string) {
                    state.stop_reason = mapStopReason(sr.string);
                }
            }
        }
    }

    // Update usage if present (only update non-null fields)
    if (root.object.get("usage")) |usage| {
        if (usage == .object) {
            if (usage.object.get("input_tokens")) |t| {
                if (t == .integer) state.usage.input = @intCast(t.integer);
            }
            if (usage.object.get("output_tokens")) |t| {
                if (t == .integer) state.usage.output = @intCast(t.integer);
            }
            if (usage.object.get("cache_read_input_tokens")) |t| {
                if (t == .integer) state.usage.cache_read = @intCast(t.integer);
            }
            if (usage.object.get("cache_creation_input_tokens")) |t| {
                if (t == .integer) state.usage.cache_write = @intCast(t.integer);
            }
        }
    }

    // Calculate total
    state.usage.total_tokens = state.usage.input +
        state.usage.output +
        state.usage.cache_read +
        state.usage.cache_write;

    // message_delta doesn't emit an event directly, just updates state
    return null;
}

fn parseMessageStop(
    allocator: std.mem.Allocator,
    state: *StreamState,
) !?types.AssistantMessageEvent {
    _ = allocator;

    var message = state.buildPartialMessage();
    message.content = try state.content_blocks.toOwnedSlice();

    return types.AssistantMessageEvent{ .done = .{
        .reason = if (state.stop_reason) |sr|
            switch (sr) {
                .stop => .stop,
                .length => .length,
                .tool_use => .tool_use,
                else => .stop,
            }
        else
            .stop,
        .message = message,
    } };
}

/// Get default headers for Anthropic requests
pub fn getHeaders(api_key: []const u8, extra_headers: ?[]const types.Header) ![]const types.Header {
    var headers = std.ArrayList(types.Header).init(std.heap.page_allocator);
    defer headers.deinit();

    // Required headers
    try headers.append(.{ .key = "anthropic-version", .value = "2023-06-01" });
    try headers.append(.{ .key = "content-type", .value = "application/json" });

    // Check if OAuth token
    const is_oauth = std.mem.indexOf(u8, api_key, "sk-ant-oat") != null;

    if (is_oauth) {
        try headers.append(.{ .key = "authorization", .value = try std.fmt.allocPrint(std.heap.page_allocator, "Bearer {s}", .{api_key}) });
        try headers.append(.{ .key = "anthropic-beta", .value = "claude-code-20250219,oauth-2025-04-20,fine-grained-tool-streaming-2025-05-14" });
        try headers.append(.{ .key = "user-agent", .value = "claude-cli/2.1.75" });
        try headers.append(.{ .key = "x-app", .value = "cli" });
    } else {
        try headers.append(.{ .key = "x-api-key", .value = api_key });
        try headers.append(.{ .key = "anthropic-beta", .value = "fine-grained-tool-streaming-2025-05-14" });
    }

    // Add extra headers
    if (extra_headers) |eh| {
        for (eh) |h| {
            try headers.append(h);
        }
    }

    return headers.toOwnedSlice();
}

/// Default Anthropic API base URL
pub const default_base_url = "https://api.anthropic.com/v1";

/// Messages endpoint path
pub const messages_endpoint = "/messages";

/// Check if API key is an OAuth token
pub fn isOAuthToken(api_key: []const u8) bool {
    return std.mem.indexOf(u8, api_key, "sk-ant-oat") != null;
}

/// Build complete API URL
pub fn buildApiUrl(allocator: std.mem.Allocator, base_url: []const u8) ![]u8 {
    // Trim trailing slash if present
    const trimmed = std.mem.trimRight(u8, base_url, "/");
    return std.fmt.allocPrint(allocator, "{s}/messages", .{trimmed});
}
