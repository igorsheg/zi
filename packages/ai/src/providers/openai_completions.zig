const std = @import("std");
const types = @import("../types.zig");
const sse = @import("sse.zig");

/// Stream state for tracking partial content and tool calls across SSE events
pub const StreamState = struct {
    allocator: std.mem.Allocator,
    /// Current text content being accumulated
    current_text: std.ArrayList(u8),
    /// Current thinking content being accumulated
    current_thinking: std.ArrayList(u8),
    /// Current tool call being built
    current_tool_call: ?ToolCallState,
    /// Index of current content block
    content_index: usize,

    pub const ToolCallState = struct {
        id: []const u8,
        name: []const u8,
        arguments: std.ArrayList(u8),
    };

    pub fn init(allocator: std.mem.Allocator) StreamState {
        return .{
            .allocator = allocator,
            .current_text = std.ArrayList(u8).init(allocator),
            .current_thinking = std.ArrayList(u8).init(allocator),
            .current_tool_call = null,
            .content_index = 0,
        };
    }

    pub fn deinit(self: *StreamState) void {
        self.current_text.deinit();
        self.current_thinking.deinit();
        if (self.current_tool_call) |*tc| {
            self.allocator.free(tc.id);
            self.allocator.free(tc.name);
            tc.arguments.deinit();
        }
    }
};

/// Check if conversation messages contain tool calls or tool results
fn hasToolHistory(messages: []const types.Message) bool {
    for (messages) |msg| {
        switch (msg) {
            .tool_result => return true,
            .assistant => |a| {
                for (a.content) |block| {
                    if (block == .tool_call) return true;
                }
            },
            else => {},
        }
    }
    return false;
}

/// Map reasoning effort level to provider-specific string
fn mapReasoningEffort(effort: types.ThinkingLevel, compat: types.OpenAICompletionsCompat) []const u8 {
    if (compat.reasoning_effort_map) |map| {
        const result = switch (effort) {
            .minimal => map.minimal,
            .low => map.low,
            .medium => map.medium,
            .high => map.high,
            .xhigh => map.xhigh,
        };
        if (result) |r| return r;
    }
    return switch (effort) {
        .minimal => "minimal",
        .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => "high",
    };
}

/// Normalize tool call ID for cross-provider compatibility
fn normalizeToolCallId(allocator: std.mem.Allocator, id: []const u8, provider: types.Provider) ![]const u8 {
    if (std.mem.indexOfScalar(u8, id, '|')) |pipe_pos| {
        const call_id = id[0..pipe_pos];
        var sanitized = try allocator.alloc(u8, @min(call_id.len, 40));
        for (call_id, 0..) |c, i| {
            if (i >= 40) break;
            sanitized[i] = if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') c else '_';
        }
        return sanitized;
    }

    if (provider == .openai and id.len > 40) {
        return try allocator.dupe(u8, id[0..40]);
    }

    return try allocator.dupe(u8, id);
}

/// Get compatibility settings for a model
fn getCompat(model: types.Model) types.OpenAICompletionsCompat {
    const provider = model.provider;
    const base_url = model.base_url;

    const is_zai = provider == .zai or std.mem.indexOf(u8, base_url, "api.z.ai") != null;

    const is_non_standard = provider == .cerebras or
        std.mem.indexOf(u8, base_url, "cerebras.ai") != null or
        provider == .xai or
        std.mem.indexOf(u8, base_url, "api.x.ai") != null or
        std.mem.indexOf(u8, base_url, "chutes.ai") != null or
        std.mem.indexOf(u8, base_url, "deepseek.com") != null or
        is_zai or
        provider == .opencode or
        std.mem.indexOf(u8, base_url, "opencode.ai") != null;

    const use_max_tokens = std.mem.indexOf(u8, base_url, "chutes.ai") != null;

    const is_grok = provider == .xai or std.mem.indexOf(u8, base_url, "api.x.ai") != null;
    const is_groq = provider == .groq or std.mem.indexOf(u8, base_url, "groq.com") != null;

    var compat = types.OpenAICompletionsCompat{
        .supports_store = !is_non_standard,
        .supports_developer_role = !is_non_standard,
        .supports_reasoning_effort = !is_grok and !is_zai,
        .supports_usage_in_streaming = true,
        .max_tokens_field = if (use_max_tokens) .max_tokens else .max_completion_tokens,
        .thinking_format = if (is_zai)
            .zai
        else if (provider == .openrouter or std.mem.indexOf(u8, base_url, "openrouter.ai") != null)
            .openrouter
        else
            .openai,
        .supports_strict_mode = true,
    };

    if (is_groq and std.mem.eql(u8, model.id, "qwen/qwen3-32b")) {
        compat.reasoning_effort_map = .{
            .minimal = "default",
            .low = "default",
            .medium = "default",
            .high = "default",
            .xhigh = "default",
        };
    }

    if (model.compat) |compat_union| {
        if (compat_union == .openai_completions) {
            const model_compat = compat_union.openai_completions;
            if (model_compat.supports_store) |v| compat.supports_store = v;
            if (model_compat.supports_developer_role) |v| compat.supports_developer_role = v;
            if (model_compat.supports_reasoning_effort) |v| compat.supports_reasoning_effort = v;
            if (model_compat.reasoning_effort_map) |v| compat.reasoning_effort_map = v;
            if (model_compat.supports_usage_in_streaming) |v| compat.supports_usage_in_streaming = v;
            if (model_compat.max_tokens_field) |v| compat.max_tokens_field = v;
            if (model_compat.requires_tool_result_name) |v| compat.requires_tool_result_name = v;
            if (model_compat.requires_assistant_after_tool_result) |v| compat.requires_assistant_after_tool_result = v;
            if (model_compat.requires_thinking_as_text) |v| compat.requires_thinking_as_text = v;
            if (model_compat.thinking_format) |v| compat.thinking_format = v;
            if (model_compat.zai_tool_stream) |v| compat.zai_tool_stream = v;
            if (model_compat.supports_strict_mode) |v| compat.supports_strict_mode = v;
        }
    }

    return compat;
}

/// Build OpenAI Chat Completions request JSON
pub fn buildRequest(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) ![]u8 {
    const compat = getCompat(model);

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    var writer = std.json.writeStream(buf.writer(), .{ .whitespace = .minified });

    try writer.beginObject();

    try writer.objectField("model");
    try writer.write(model.id);

    try writer.objectField("stream");
    try writer.write(true);

    if (compat.supports_usage_in_streaming != false) {
        try writer.objectField("stream_options");
        try writer.beginObject();
        try writer.objectField("include_usage");
        try writer.write(true);
        try writer.endObject();
    }

    if (compat.supports_store) |supports| {
        try writer.objectField("store");
        try writer.write(supports);
    }

    if (options) |opts| {
        if (opts.max_tokens) |max| {
            const field_name = if (compat.max_tokens_field == .max_tokens) "max_tokens" else "max_completion_tokens";
            try writer.objectField(field_name);
            try writer.write(max);
        }

        if (opts.temperature) |temp| {
            try writer.objectField("temperature");
            try writer.write(temp);
        }
    }

    try writer.objectField("messages");
    try writeMessages(&writer, allocator, model, context, compat);

    if (context.tools) |tools| {
        try writer.objectField("tools");
        try writeTools(&writer, tools, compat);

        if (compat.zai_tool_stream) |zts| {
            try writer.objectField("tool_stream");
            try writer.write(zts);
        }
    } else if (hasToolHistory(context.messages)) {
        try writer.objectField("tools");
        try writer.beginArray();
        try writer.endArray();
    }

    if (options) |opts| {
        const reasoning = opts.reasoning orelse .medium;
        switch (compat.thinking_format) {
            .zai, .qwen => {
                if (model.reasoning) {
                    try writer.objectField("enable_thinking");
                    try writer.write(true);
                }
            },
            .qwen_chat_template => {
                if (model.reasoning) {
                    try writer.objectField("chat_template_kwargs");
                    try writer.beginObject();
                    try writer.objectField("enable_thinking");
                    try writer.write(true);
                    try writer.endObject();
                }
            },
            .openrouter => {
                if (model.reasoning) {
                    try writer.objectField("reasoning");
                    try writer.beginObject();
                    try writer.objectField("effort");
                    try writer.write(mapReasoningEffort(reasoning, compat));
                    try writer.endObject();
                }
            },
            .openai => {
                if (compat.supports_reasoning_effort != false and model.reasoning) {
                    try writer.objectField("reasoning_effort");
                    try writer.write(mapReasoningEffort(reasoning, compat));
                }
            },
        }
    }

    if (std.mem.indexOf(u8, model.base_url, "openrouter.ai")) |_| {
        if (model.compat) |compat_union| {
            if (compat_union == .openai_completions) {
                if (compat_union.openai_completions.open_router_routing) |routing| {
                    try writer.objectField("provider");
                    try writer.beginObject();
                    if (routing.only) |only| {
                        try writer.objectField("only");
                        try writer.beginArray();
                        for (only) |p| try writer.write(p);
                        try writer.endArray();
                    }
                    if (routing.order) |order| {
                        try writer.objectField("order");
                        try writer.beginArray();
                        for (order) |p| try writer.write(p);
                        try writer.endArray();
                    }
                    try writer.endObject();
                }
            }
        }
    }

    if (std.mem.indexOf(u8, model.base_url, "ai-gateway.vercel.sh")) |_| {
        if (model.compat) |compat_union| {
            if (compat_union == .openai_completions) {
                if (compat_union.openai_completions.vercel_gateway_routing) |routing| {
                    try writer.objectField("providerOptions");
                    try writer.beginObject();
                    try writer.objectField("gateway");
                    try writer.beginObject();
                    if (routing.only) |only| {
                        try writer.objectField("only");
                        try writer.beginArray();
                        for (only) |p| try writer.write(p);
                        try writer.endArray();
                    }
                    if (routing.order) |order| {
                        try writer.objectField("order");
                        try writer.beginArray();
                        for (order) |p| try writer.write(p);
                        try writer.endArray();
                    }
                    try writer.endObject();
                    try writer.endObject();
                }
            }
        }
    }

    try writer.endObject();

    return try allocator.dupe(u8, buf.items);
}

/// Write messages array to JSON
fn writeMessages(
    writer: *std.json.WriteStream(@TypeOf(std.ArrayList(u8).init(std.heap.page_allocator).writer()), .minified),
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    compat: types.OpenAICompletionsCompat,
) !void {
    try writer.beginArray();

    if (context.system_prompt) |system| {
        const use_developer = model.reasoning and compat.supports_developer_role == true;
        try writer.beginObject();
        try writer.objectField("role");
        try writer.write(if (use_developer) "developer" else "system");
        try writer.objectField("content");
        try writer.write(system);
        try writer.endObject();
    }

    var last_role: ?[]const u8 = null;

    for (context.messages) |msg| {
        if (compat.requires_assistant_after_tool_result == true) {
            if (last_role) |lr| {
                if (std.mem.eql(u8, lr, "tool") and msg == .user) {
                    try writer.beginObject();
                    try writer.objectField("role");
                    try writer.write("assistant");
                    try writer.objectField("content");
                    try writer.write("I have processed the tool results.");
                    try writer.endObject();
                }
            }
        }

        switch (msg) {
            .user => |u| {
                try writer.beginObject();
                try writer.objectField("role");
                try writer.write("user");
                try writer.objectField("content");

                switch (u.content) {
                    .text => |text| {
                        try writer.write(text);
                    },
                    .blocks => |blocks| {
                        try writer.beginArray();
                        for (blocks) |block| {
                            switch (block) {
                                .text => |t| {
                                    try writer.beginObject();
                                    try writer.objectField("type");
                                    try writer.write("text");
                                    try writer.objectField("text");
                                    try writer.write(t.text);
                                    try writer.endObject();
                                },
                                .image => |img| {
                                    try writer.beginObject();
                                    try writer.objectField("type");
                                    try writer.write("image_url");
                                    try writer.objectField("image_url");
                                    try writer.beginObject();
                                    try writer.objectField("url");
                                    var url_buf = std.ArrayList(u8).init(allocator);
                                    defer url_buf.deinit();
                                    try url_buf.writer().print("data:{s};base64,{s}", .{ img.mime_type, img.data });
                                    try writer.write(url_buf.items);
                                    try writer.endObject();
                                    try writer.endObject();
                                },
                            }
                        }
                        try writer.endArray();
                    },
                }
                try writer.endObject();
                last_role = "user";
            },
            .assistant => |a| {
                try writer.beginObject();
                try writer.objectField("role");
                try writer.write("assistant");

                var text_parts = std.ArrayList([]const u8).init(allocator);
                defer {
                    for (text_parts.items) |p| allocator.free(p);
                    text_parts.deinit();
                }

                for (a.content) |block| {
                    switch (block) {
                        .text => |t| {
                            if (t.text.len > 0) {
                                try text_parts.append(try allocator.dupe(u8, t.text));
                            }
                        },
                        .thinking => |th| {
                            if (compat.requires_thinking_as_text == true) {
                                if (th.thinking.len > 0) {
                                    try text_parts.append(try allocator.dupe(u8, th.thinking));
                                }
                            } else if (th.thinking_signature) |sig| {
                                try writer.objectField(sig);
                                try writer.write(th.thinking);
                            }
                        },
                        else => {},
                    }
                }

                if (text_parts.items.len > 0) {
                    try writer.objectField("content");
                    if (text_parts.items.len == 1) {
                        try writer.write(text_parts.items[0]);
                    } else {
                        var combined = std.ArrayList(u8).init(allocator);
                        defer combined.deinit();
                        for (text_parts.items, 0..) |part, i| {
                            if (i > 0) try combined.appendSlice("\n\n");
                            try combined.appendSlice(part);
                        }
                        try writer.write(combined.items);
                    }
                } else {
                    try writer.objectField("content");
                    if (compat.requires_assistant_after_tool_result == true) {
                        try writer.write("");
                    } else {
                        try writer.null();
                    }
                }

                var tool_calls = std.ArrayList(types.ToolCall).init(allocator);
                defer tool_calls.deinit();

                for (a.content) |block| {
                    if (block == .tool_call) {
                        try tool_calls.append(block.tool_call);
                    }
                }

                if (tool_calls.items.len > 0) {
                    try writer.objectField("tool_calls");
                    try writer.beginArray();
                    for (tool_calls.items) |tc| {
                        try writer.beginObject();
                        try writer.objectField("id");
                        const normalized_id = try normalizeToolCallId(allocator, tc.id, model.provider);
                        defer allocator.free(normalized_id);
                        try writer.write(normalized_id);
                        try writer.objectField("type");
                        try writer.write("function");
                        try writer.objectField("function");
                        try writer.beginObject();
                        try writer.objectField("name");
                        try writer.write(tc.name);
                        try writer.objectField("arguments");
                        var args_buf = std.ArrayList(u8).init(allocator);
                        defer args_buf.deinit();
                        try std.json.stringify(tc.arguments, .{}, args_buf.writer());
                        try writer.write(args_buf.items);
                        try writer.endObject();
                        try writer.endObject();
                    }
                    try writer.endArray();

                    var has_signatures = false;
                    for (tool_calls.items) |tc| {
                        if (tc.thought_signature != null) {
                            has_signatures = true;
                            break;
                        }
                    }
                    if (has_signatures) {
                        try writer.objectField("reasoning_details");
                        try writer.beginArray();
                        for (tool_calls.items) |tc| {
                            if (tc.thought_signature) |sig| {
                                try writer.write(sig);
                            }
                        }
                        try writer.endArray();
                    }
                }

                try writer.endObject();
                last_role = "assistant";
            },
            .tool_result => |tr| {
                try writer.beginObject();
                try writer.objectField("role");
                try writer.write("tool");
                try writer.objectField("tool_call_id");
                try writer.write(tr.tool_call_id);

                if (compat.requires_tool_result_name == true) {
                    try writer.objectField("name");
                    try writer.write(tr.tool_name);
                }

                var text_parts = std.ArrayList([]const u8).init(allocator);
                defer {
                    for (text_parts.items) |p| allocator.free(p);
                    text_parts.deinit();
                }

                for (tr.content) |block| {
                    switch (block) {
                        .text => |t| try text_parts.append(try allocator.dupe(u8, t.text)),
                        else => {},
                    }
                }

                try writer.objectField("content");
                if (text_parts.items.len > 0) {
                    if (text_parts.items.len == 1) {
                        try writer.write(text_parts.items[0]);
                    } else {
                        var combined = std.ArrayList(u8).init(allocator);
                        defer combined.deinit();
                        for (text_parts.items, 0..) |part, i| {
                            if (i > 0) try combined.append('\n');
                            try combined.appendSlice(part);
                        }
                        try writer.write(combined.items);
                    }
                } else {
                    try writer.write("(see attached image)");
                }

                try writer.endObject();
                last_role = "tool";
            },
        }
    }

    try writer.endArray();
}

/// Write tools array to JSON
fn writeTools(
    writer: *std.json.WriteStream(@TypeOf(std.ArrayList(u8).init(std.heap.page_allocator).writer()), .minified),
    tools: []const types.Tool,
    compat: types.OpenAICompletionsCompat,
) !void {
    try writer.beginArray();
    for (tools) |tool| {
        try writer.beginObject();
        try writer.objectField("type");
        try writer.write("function");
        try writer.objectField("function");
        try writer.beginObject();
        try writer.objectField("name");
        try writer.write(tool.name);
        try writer.objectField("description");
        try writer.write(tool.description);
        try writer.objectField("parameters");
        switch (tool.parameters) {
            .object => |obj| try writer.write(obj),
            .array => |arr| try writer.write(arr),
            else => try writer.null(),
        }
        if (compat.supports_strict_mode != false) {
            try writer.objectField("strict");
            try writer.write(false);
        }
        try writer.endObject();
        try writer.endObject();
    }
    try writer.endArray();
}

/// Map OpenAI finish_reason to StopReason
fn mapStopReason(reason: ?[]const u8) struct { stop_reason: types.StopReason, error_message: ?[]const u8 } {
    if (reason == null) return .{ .stop_reason = .stop, .error_message = null };
    const r = reason.?;
    if (std.mem.eql(u8, r, "stop") or std.mem.eql(u8, r, "end")) {
        return .{ .stop_reason = .stop, .error_message = null };
    } else if (std.mem.eql(u8, r, "length")) {
        return .{ .stop_reason = .length, .error_message = null };
    } else if (std.mem.eql(u8, r, "function_call") or std.mem.eql(u8, r, "tool_calls")) {
        return .{ .stop_reason = .tool_use, .error_message = null };
    } else if (std.mem.eql(u8, r, "content_filter")) {
        return .{ .stop_reason = .@"error", .error_message = "Provider finish_reason: content_filter" };
    } else if (std.mem.eql(u8, r, "network_error")) {
        return .{ .stop_reason = .@"error", .error_message = "Provider finish_reason: network_error" };
    } else {
        return .{ .stop_reason = .@"error", .error_message = "Provider finish_reason: " };
    }
}

/// Parse an OpenAI SSE event
pub fn parseEvent(
    allocator: std.mem.Allocator,
    event_data: []const u8,
    state: *StreamState,
) !?types.AssistantMessageEvent {
    // Check for [DONE] marker
    if (std.mem.eql(u8, event_data, "[DONE]")) {
        return null;
    }

    // Parse the JSON payload
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, event_data, .{}) catch |err| {
        // If we can't parse, return null (may be a comment or other non-data line)
        if (err == error.SyntaxError or err == error.UnexpectedEndOfInput) {
            return null;
        }
        return err;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return null;

    // Check for error in the response
    if (root.object.get("error")) |err| {
        return types.AssistantMessageEvent{ .@"error" = .{
            .reason = .@"error",
            .@"error" = .{
                .content = &.{},
                .api = .openai_completions,
                .provider = .openai,
                .model = "",
                .response_id = null,
                .usage = .{
                    .input = 0,
                    .output = 0,
                    .cache_read = 0,
                    .cache_write = 0,
                    .total_tokens = 0,
                    .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 },
                },
                .stop_reason = .@"error",
                .error_message = if (err.object.get("message")) |m| (if (m == .string) m.string else "Unknown error") else "Unknown error",
                .timestamp = std.time.milliTimestamp(),
            },
        } };
    }

    // Get choices array
    const choices = root.object.get("choices") orelse return null;
    if (choices != .array or choices.array.items.len == 0) return null;

    const choice = choices.array.items[0];
    if (choice != .object) return null;

    // Check for finish_reason
    if (choice.object.get("finish_reason")) |fr| {
        if (fr != .null) {
            const finish_reason = if (fr == .string) fr.string else null;
            const result = mapStopReason(finish_reason);

            // Flush any pending content before returning done
            if (state.current_text.items.len > 0) {
                const text = try state.allocator.dupe(u8, state.current_text.items);
                state.current_text.clearRetainingCapacity();
                return types.AssistantMessageEvent{ .text_end = .{
                    .content_index = state.content_index,
                    .content = text,
                    .partial = buildPartialMessage(state),
                } };
            }

            if (state.current_thinking.items.len > 0) {
                const thinking = try state.allocator.dupe(u8, state.current_thinking.items);
                state.current_thinking.clearRetainingCapacity();
                return types.AssistantMessageEvent{ .thinking_end = .{
                    .content_index = state.content_index,
                    .content = thinking,
                    .partial = buildPartialMessage(state),
                } };
            }

            if (state.current_tool_call) |*tc| {
                const id = try state.allocator.dupe(u8, tc.id);
                const name = try state.allocator.dupe(u8, tc.name);
                const args_str = try state.allocator.dupe(u8, tc.arguments.items);

                // Parse arguments JSON
                const args_parsed = std.json.parseFromSlice(std.json.Value, allocator, args_str, .{}) catch std.json.Value.null;
                defer if (args_parsed != std.json.Value.null) args_parsed.deinit();

                const tool_call = types.ToolCall{
                    .id = id,
                    .name = name,
                    .arguments = if (args_parsed != std.json.Value.null) args_parsed.value else std.json.Value.null,
                };

                state.allocator.free(tc.id);
                state.allocator.free(tc.name);
                tc.arguments.deinit();
                state.current_tool_call = null;

                return types.AssistantMessageEvent{ .toolcall_end = .{
                    .content_index = state.content_index,
                    .tool_call = tool_call,
                    .partial = buildPartialMessage(state),
                } };
            }

            if (result.stop_reason == .@"error") {
                return types.AssistantMessageEvent{ .@"error" = .{
                    .reason = .@"error",
                    .@"error" = buildPartialMessage(state),
                } };
            }

            return types.AssistantMessageEvent{ .done = .{
                .reason = switch (result.stop_reason) {
                    .stop => .stop,
                    .length => .length,
                    .tool_use => .tool_use,
                    else => .stop,
                },
                .message = buildPartialMessage(state),
            } };
        }
    }

    // Get delta
    const delta = choice.object.get("delta") orelse return null;
    if (delta != .object) return null;

    // Handle content deltas
    if (delta.object.get("content")) |content| {
        if (content == .string) {
            const text = content.string;
            if (text.len > 0) {
                // Start new text block if needed
                if (state.current_text.items.len == 0) {
                    state.content_index += 1;
                    return types.AssistantMessageEvent{ .text_start = .{
                        .content_index = state.content_index - 1,
                        .partial = buildPartialMessage(state),
                    } };
                }

                try state.current_text.appendSlice(text);
                return types.AssistantMessageEvent{ .text_delta = .{
                    .content_index = state.content_index - 1,
                    .delta = try state.allocator.dupe(u8, text),
                    .partial = buildPartialMessage(state),
                } };
            }
        }
    }

    // Handle reasoning/thinking deltas
    const reasoning_fields = [_][]const u8{ "reasoning_content", "reasoning", "reasoning_text" };
    for (reasoning_fields) |field| {
        if (delta.object.get(field)) |reasoning| {
            if (reasoning == .string) {
                const text = reasoning.string;
                if (text.len > 0) {
                    if (state.current_thinking.items.len == 0) {
                        state.content_index += 1;
                        return types.AssistantMessageEvent{ .thinking_start = .{
                            .content_index = state.content_index - 1,
                            .partial = buildPartialMessage(state),
                        } };
                    }

                    try state.current_thinking.appendSlice(text);
                    return types.AssistantMessageEvent{ .thinking_delta = .{
                        .content_index = state.content_index - 1,
                        .delta = try state.allocator.dupe(u8, text),
                        .partial = buildPartialMessage(state),
                    } };
                }
            }
        }
    }

    // Handle tool call deltas
    if (delta.object.get("tool_calls")) |tool_calls| {
        if (tool_calls == .array and tool_calls.array.items.len > 0) {
            const tc_delta = tool_calls.array.items[0];
            if (tc_delta == .object) {
                var new_tool_call = false;

                // Get or create current tool call state
                if (state.current_tool_call == null) {
                    state.content_index += 1;
                    new_tool_call = true;
                    state.current_tool_call = .{
                        .id = &.{},
                        .name = &.{},
                        .arguments = std.ArrayList(u8).init(state.allocator),
                    };
                }

                var tc_state = &state.current_tool_call.?;

                // Update ID if provided
                if (tc_delta.object.get("id")) |id_val| {
                    if (id_val == .string and id_val.string.len > 0) {
                        if (tc_state.id.len > 0) state.allocator.free(tc_state.id);
                        tc_state.id = try state.allocator.dupe(u8, id_val.string);
                    }
                }

                // Update name if provided
                if (tc_delta.object.get("function")) |func| {
                    if (func == .object) {
                        if (func.object.get("name")) |name_val| {
                            if (name_val == .string and name_val.string.len > 0) {
                                if (tc_state.name.len > 0) state.allocator.free(tc_state.name);
                                tc_state.name = try state.allocator.dupe(u8, name_val.string);
                            }
                        }

                        // Update arguments
                        if (func.object.get("arguments")) |args_val| {
                            if (args_val == .string) {
                                try tc_state.arguments.appendSlice(args_val.string);
                            }
                        }
                    }
                }

                if (new_tool_call) {
                    return types.AssistantMessageEvent{ .toolcall_start = .{
                        .content_index = state.content_index - 1,
                        .partial = buildPartialMessage(state),
                    } };
                } else {
                    return types.AssistantMessageEvent{ .toolcall_delta = .{
                        .content_index = state.content_index - 1,
                        .delta = try state.allocator.dupe(u8, ""),
                        .partial = buildPartialMessage(state),
                    } };
                }
            }
        }
    }

    return null;
}

/// Build a partial AssistantMessage from current stream state
fn buildPartialMessage(state: *StreamState) types.AssistantMessage {
    var content = std.ArrayList(types.AssistantMessage.AssistantContentBlock).init(state.allocator);

    // Add text content if present
    if (state.current_text.items.len > 0) {
        content.append(.{ .text = .{ .text = state.current_text.items } }) catch {};
    }

    // Add thinking content if present
    if (state.current_thinking.items.len > 0) {
        content.append(.{ .thinking = .{ .thinking = state.current_thinking.items } }) catch {};
    }

    // Add tool call if present
    if (state.current_tool_call) |*tc| {
        // Parse arguments
        const args = std.json.parseFromSlice(std.json.Value, state.allocator, tc.arguments.items, .{}) catch std.json.Value.null;

        content.append(.{ .tool_call = .{
            .id = tc.id,
            .name = tc.name,
            .arguments = if (args != std.json.Value.null) args else std.json.Value.null,
        } }) catch {};
    }

    return .{
        .content = content.toOwnedSlice() catch &.{},
        .api = .openai_completions,
        .provider = .openai,
        .model = "",
        .response_id = null,
        .usage = .{
            .input = 0,
            .output = 0,
            .cache_read = 0,
            .cache_write = 0,
            .total_tokens = 0,
            .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 },
        },
        .stop_reason = .stop,
        .error_message = null,
        .timestamp = std.time.milliTimestamp(),
    };
}

test "buildRequest creates valid JSON" {
    const allocator = std.testing.allocator;

    const model = types.Model{
        .id = "gpt-4",
        .name = "GPT-4",
        .api = .openai_completions,
        .provider = .openai,
        .base_url = "https://api.openai.com/v1",
        .reasoning = false,
        .input = &.{.text},
        .cost = .{ .input = 0.03, .output = 0.06, .cache_read = 0.015, .cache_write = 0.0225 },
        .context_window = 8192,
        .max_tokens = 4096,
    };

    const context = types.Context{
        .system_prompt = "You are a helpful assistant.",
        .messages = &.{},
    };

    const request = try buildRequest(allocator, model, context, null);
    defer allocator.free(request);

    // Verify it's valid JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, request, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value.object.get("model") != null);
    try std.testing.expect(parsed.value.object.get("stream") != null);
    try std.testing.expect(parsed.value.object.get("messages") != null);
}

test "parseEvent handles [DONE]" {
    const allocator = std.testing.allocator;
    var state = StreamState.init(allocator);
    defer state.deinit();

    const result = try parseEvent(allocator, "[DONE]", &state);
    try std.testing.expect(result == null);
}

test "StreamState init and deinit" {
    const allocator = std.testing.allocator;
    var state = StreamState.init(allocator);
    defer state.deinit();

    try std.testing.expect(state.current_text.items.len == 0);
    try std.testing.expect(state.current_thinking.items.len == 0);
    try std.testing.expect(state.current_tool_call == null);
    try std.testing.expect(state.content_index == 0);
}
