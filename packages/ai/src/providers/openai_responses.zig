const std = @import("std");
const types = @import("../types.zig");
const hash = @import("../utils/hash.zig");
const json_parse = @import("../utils/json_parse.zig");

/// Variant determines which URL format and auth mechanism to use
pub const Variant = enum {
    openai, // Standard OpenAI
    azure, // Azure OpenAI
    codex, // OpenAI Codex
};

/// URL configuration for building request URLs
pub const UrlConfig = struct {
    base_url: []const u8,
    model: []const u8,
    api_version: ?[]const u8 = null,
};

/// Build the request URL based on variant
pub fn buildUrl(allocator: std.mem.Allocator, config: UrlConfig, variant: Variant) ![]const u8 {
    return switch (variant) {
        .openai, .codex => std.fmt.allocPrint(allocator, "{s}/responses", .{config.base_url}),
        .azure => {
            const version = config.api_version orelse "2025-04-01-preview";
            return std.fmt.allocPrint(
                allocator,
                "{s}/openai/deployments/{s}/responses?api-version={s}",
                .{ config.base_url, config.model, version },
            );
        },
    };
}

/// Build request options for the Responses API
pub const BuildRequestOptions = struct {
    max_tokens: ?u64 = null,
    temperature: ?f64 = null,
    reasoning: ?ReasoningConfig = null,
    session_id: ?[]const u8 = null,
    cache_retention: ?types.CacheRetention = null,
    service_tier: ?[]const u8 = null,
    text_verbosity: ?[]const u8 = null,
    include_reasoning: bool = false,

    pub const ReasoningConfig = struct {
        effort: []const u8,
        summary: ?[]const u8 = null,
    };
};

/// Normalize a string for use as an ID (replace invalid chars with underscore)
fn normalizeIdPart(part: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    for (part) |c| {
        const is_valid = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_' or c == '-';

        if (is_valid) {
            try result.append(c);
        } else {
            try result.append('_');
        }
    }

    var len = result.items.len;
    if (len > 64) len = 64;
    while (len > 0 and result.items[len - 1] == '_') {
        len -= 1;
    }

    return try allocator.dupe(u8, result.items[0..len]);
}

/// Build a foreign responses item ID from a tool call ID
fn buildForeignResponsesItemId(id: []const u8) [13]u8 {
    return hash.shortHash(id);
}

/// Sanitize text by removing surrogate characters
fn sanitizeText(text: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];

        if (c >= 0x80) {
            const seq_len = std.unicode.utf8ByteSequenceLength(c) catch {
                i += 1;
                continue;
            };

            if (i + seq_len > text.len) {
                i += 1;
                continue;
            }

            const codepoint = std.unicode.utf8Decode(text[i..][0..seq_len]) catch {
                i += 1;
                continue;
            };

            if (codepoint >= 0xD800 and codepoint <= 0xDFFF) {
                i += seq_len;
                continue;
            }

            try result.appendSlice(text[i..][0..seq_len]);
            i += seq_len;
        } else {
            try result.append(c);
            i += 1;
        }
    }

    return result.toOwnedSlice();
}

fn hasImageInput(model: types.Model) bool {
    for (model.input) |input_type| {
        if (input_type == .image) return true;
    }
    return false;
}

/// Convert tools to OpenAI Responses format
fn convertTools(tools: []const types.Tool, allocator: std.mem.Allocator, strict: ?bool) !std.json.Value {
    var result = std.json.Array.init(allocator);
    errdefer {
        for (result.items) |*item| {
            item.deinit(allocator);
        }
        result.deinit();
    }

    const strict_mode = strict orelse false;

    for (tools) |tool| {
        var tool_obj = std.json.ObjectMap.init(allocator);
        try tool_obj.put("type", std.json.Value{ .string = "function" });
        try tool_obj.put("name", std.json.Value{ .string = tool.name });
        try tool_obj.put("description", std.json.Value{ .string = tool.description });
        try tool_obj.put("parameters", tool.parameters);
        try tool_obj.put("strict", std.json.Value{ .bool = strict_mode });
        try result.append(std.json.Value{ .object = tool_obj });
    }

    return std.json.Value{ .array = result };
}

/// Build the full request JSON for the Responses API
pub fn buildRequest(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?BuildRequestOptions,
    variant: Variant,
) ![]u8 {
    const opts = options orelse .{};

    var request_obj = std.json.ObjectMap.init(allocator);
    errdefer request_obj.deinit();

    try request_obj.put("model", std.json.Value{ .string = model.id });
    try request_obj.put("stream", std.json.Value{ .bool = true });
    try request_obj.put("store", std.json.Value{ .bool = false });

    // Build input array
    const input = try buildInputArray(allocator, context, model, variant);
    try request_obj.put("input", input);

    // Codex variant uses "instructions" instead of system role
    if (variant == .codex and context.system_prompt != null) {
        const sanitized = try sanitizeText(context.system_prompt.?, allocator);
        defer allocator.free(sanitized);
        try request_obj.put("instructions", std.json.Value{ .string = sanitized });
    }

    // Text verbosity (Codex only)
    if (variant == .codex) {
        var text_obj = std.json.ObjectMap.init(allocator);
        try text_obj.put("verbosity", std.json.Value{ .string = opts.text_verbosity orelse "medium" });
        try request_obj.put("text", std.json.Value{ .object = text_obj });
    }

    // Session ID for prompt caching
    if (opts.session_id) |sid| {
        if (opts.cache_retention == null or opts.cache_retention.? != .none) {
            try request_obj.put("prompt_cache_key", std.json.Value{ .string = sid });
        }
    }

    // Cache retention (OpenAI only, for api.openai.com)
    if (variant == .openai and opts.cache_retention) |cr| {
        if (cr == .long and std.mem.indexOf(u8, model.base_url, "api.openai.com") != null) {
            try request_obj.put("prompt_cache_retention", std.json.Value{ .string = "24h" });
        }
    }

    // Max tokens
    if (opts.max_tokens) |max| {
        try request_obj.put("max_output_tokens", std.json.Value{ .integer = @intCast(max) });
    }

    // Temperature
    if (opts.temperature) |temp| {
        try request_obj.put("temperature", std.json.Value{ .float = temp });
    }

    // Reasoning configuration
    if (model.reasoning) {
        if (opts.reasoning) |reasoning| {
            var reasoning_obj = std.json.ObjectMap.init(allocator);
            try reasoning_obj.put("effort", std.json.Value{ .string = reasoning.effort });
            if (reasoning.summary) |summary| {
                try reasoning_obj.put("summary", std.json.Value{ .string = summary });
            }
            try request_obj.put("reasoning", std.json.Value{ .object = reasoning_obj });

            var include_arr = std.json.Array.init(allocator);
            try include_arr.append(std.json.Value{ .string = "reasoning.encrypted_content" });
            try request_obj.put("include", std.json.Value{ .array = include_arr });
        } else if (variant != .codex) {
            var reasoning_obj = std.json.ObjectMap.init(allocator);
            try reasoning_obj.put("effort", std.json.Value{ .string = "none" });
            try request_obj.put("reasoning", std.json.Value{ .object = reasoning_obj });
        }
    } else if (opts.include_reasoning) {
        if (request_obj.get("include")) |existing| {
            if (existing == .array) {
                try existing.array.append(std.json.Value{ .string = "reasoning.encrypted_content" });
            }
        } else {
            var include_arr = std.json.Array.init(allocator);
            try include_arr.append(std.json.Value{ .string = "reasoning.encrypted_content" });
            try request_obj.put("include", std.json.Value{ .array = include_arr });
        }
    }

    // Service tier (OpenAI only)
    if (variant == .openai and opts.service_tier) |tier| {
        try request_obj.put("service_tier", std.json.Value{ .string = tier });
    }

    // Tools
    if (context.tools) |tools| {
        const strict_mode: ?bool = if (variant == .codex) null else false;
        const tools_json = try convertTools(tools, allocator, strict_mode);
        try request_obj.put("tools", tools_json);
        try request_obj.put("tool_choice", std.json.Value{ .string = "auto" });
        try request_obj.put("parallel_tool_calls", std.json.Value{ .bool = true });
    }

    const request_value = std.json.Value{ .object = request_obj };
    return std.json.stringifyAlloc(allocator, request_value, .{});
}

/// Build the input array for the Responses API
fn buildInputArray(
    allocator: std.mem.Allocator,
    context: types.Context,
    model: types.Model,
    variant: Variant,
) !std.json.Value {
    var messages = std.json.Array.init(allocator);
    errdefer {
        for (messages.items) |*item| {
            item.deinit(allocator);
        }
        messages.deinit();
    }

    // Add system/developer message if present (for non-Codex variants)
    if (context.system_prompt != null and variant != .codex) {
        const role: []const u8 = if (model.reasoning) "developer" else "system";
        const sanitized = try sanitizeText(context.system_prompt.?, allocator);
        defer allocator.free(sanitized);

        var msg_obj = std.json.ObjectMap.init(allocator);
        try msg_obj.put("role", std.json.Value{ .string = role });
        try msg_obj.put("content", std.json.Value{ .string = sanitized });
        try messages.append(std.json.Value{ .object = msg_obj });
    }

    // Process conversation messages
    for (context.messages) |msg| {
        switch (msg) {
            .user => |user_msg| {
                try messages.append(try buildUserMessage(allocator, user_msg));
            },
            .assistant => |assistant_msg| {
                try messages.appendSlice(try buildAssistantOutput(allocator, assistant_msg));
            },
            .tool_result => |tool_result| {
                try messages.append(try buildToolResult(allocator, tool_result, model));
            },
        }
    }

    return std.json.Value{ .array = messages };
}

fn buildUserMessage(allocator: std.mem.Allocator, user_msg: types.UserMessage) !std.json.Value {
    var msg_obj = std.json.ObjectMap.init(allocator);
    errdefer msg_obj.deinit();

    try msg_obj.put("role", std.json.Value{ .string = "user" });

    switch (user_msg.content) {
        .text => |text| {
            const sanitized = try sanitizeText(text, allocator);
            defer allocator.free(sanitized);

            var content_arr = std.json.Array.init(allocator);
            var content_obj = std.json.ObjectMap.init(allocator);
            try content_obj.put("type", std.json.Value{ .string = "input_text" });
            try content_obj.put("text", std.json.Value{ .string = sanitized });
            try content_arr.append(std.json.Value{ .object = content_obj });
            try msg_obj.put("content", std.json.Value{ .array = content_arr });
        },
        .blocks => |blocks| {
            var content_arr = std.json.Array.init(allocator);
            errdefer {
                for (content_arr.items) |*p| {
                    p.deinit(allocator);
                }
                content_arr.deinit();
            }

            for (blocks) |block| {
                switch (block) {
                    .text => |text| {
                        const sanitized = try sanitizeText(text.text, allocator);
                        defer allocator.free(sanitized);

                        var content_obj = std.json.ObjectMap.init(allocator);
                        try content_obj.put("type", std.json.Value{ .string = "input_text" });
                        try content_obj.put("text", std.json.Value{ .string = sanitized });
                        try content_arr.append(std.json.Value{ .object = content_obj });
                    },
                    .image => |image| {
                        const data_url = try std.fmt.allocPrint(
                            allocator,
                            "data:{s};base64,{s}",
                            .{ image.mime_type, image.data },
                        );
                        defer allocator.free(data_url);

                        var content_obj = std.json.ObjectMap.init(allocator);
                        try content_obj.put("type", std.json.Value{ .string = "input_image" });
                        try content_obj.put("detail", std.json.Value{ .string = "auto" });
                        try content_obj.put("image_url", std.json.Value{ .string = data_url });
                        try content_arr.append(std.json.Value{ .object = content_obj });
                    },
                }
            }

            try msg_obj.put("content", std.json.Value{ .array = content_arr });
        },
    }

    return std.json.Value{ .object = msg_obj };
}

fn buildAssistantOutput(allocator: std.mem.Allocator, assistant_msg: types.AssistantMessage) ![]std.json.Value {
    var output = std.ArrayList(std.json.Value).init(allocator);
    errdefer {
        for (output.items) |*p| {
            p.deinit(allocator);
        }
        output.deinit();
    }

    for (assistant_msg.content) |block| {
        switch (block) {
            .thinking => |thinking| {
                if (thinking.thinking_signature) |sig| {
                    const parsed = std.json.parseFromSlice(std.json.Value, allocator, sig, .{
                        .ignore_unknown_fields = true,
                    }) catch |err| {
                        _ = err;
                        continue;
                    };
                    try output.append(parsed.value);
                }
            },
            .text => |text| {
                try output.append(try buildAssistantTextItem(allocator, text));
            },
            .tool_call => |tool_call| {
                try output.append(try buildToolCallItem(allocator, tool_call));
            },
        }
    }

    return output.toOwnedSlice();
}

fn buildAssistantTextItem(allocator: std.mem.Allocator, text: types.TextContent) !std.json.Value {
    var msg_id: []const u8 = "msg_0";
    var phase: ?[]const u8 = null;

    if (text.text_signature) |sig| {
        if (std.mem.startsWith(u8, sig, "{")) {
            const parsed_sig = std.json.parseFromSlice(struct {
                v: u8,
                id: []const u8,
                phase: ?[]const u8 = null,
            }, allocator, sig, .{
                .ignore_unknown_fields = true,
            }) catch null;
            if (parsed_sig) |ps| {
                msg_id = ps.value.id;
                phase = ps.value.phase;
                ps.deinit();
            }
        } else {
            msg_id = sig;
        }
    }

    // Truncate ID to 64 chars if needed
    if (msg_id.len > 64) {
        const hash_result = buildForeignResponsesItemId(msg_id);
        msg_id = try std.fmt.allocPrint(allocator, "msg_{s}", .{&hash_result});
    } else {
        msg_id = try allocator.dupe(u8, msg_id);
    }
    defer allocator.free(msg_id);

    const sanitized = try sanitizeText(text.text, allocator);
    defer allocator.free(sanitized);

    var msg_obj = std.json.ObjectMap.init(allocator);
    try msg_obj.put("type", std.json.Value{ .string = "message" });
    try msg_obj.put("role", std.json.Value{ .string = "assistant" });
    try msg_obj.put("status", std.json.Value{ .string = "completed" });
    try msg_obj.put("id", std.json.Value{ .string = msg_id });

    if (phase) |p| {
        try msg_obj.put("phase", std.json.Value{ .string = p });
    }

    var content_arr = std.json.Array.init(allocator);
    var content_obj = std.json.ObjectMap.init(allocator);
    try content_obj.put("type", std.json.Value{ .string = "output_text" });
    try content_obj.put("text", std.json.Value{ .string = sanitized });
    try content_obj.put("annotations", std.json.Value{ .array = std.json.Array.init(allocator) });
    try content_arr.append(std.json.Value{ .object = content_obj });
    try msg_obj.put("content", std.json.Value{ .array = content_arr });

    return std.json.Value{ .object = msg_obj };
}

fn buildToolCallItem(allocator: std.mem.Allocator, tool_call: types.ToolCall) !std.json.Value {
    const sep_idx = std.mem.indexOfScalar(u8, tool_call.id, '|');
    var call_id: []const u8 = tool_call.id;
    var item_id: ?[]const u8 = null;

    if (sep_idx) |idx| {
        call_id = tool_call.id[0..idx];
        item_id = tool_call.id[idx + 1 ..];
    }

    call_id = try normalizeIdPart(call_id, allocator);
    defer if (sep_idx != null) allocator.free(call_id);

    var fn_call_obj = std.json.ObjectMap.init(allocator);
    try fn_call_obj.put("type", std.json.Value{ .string = "function_call" });
    try fn_call_obj.put("call_id", std.json.Value{ .string = call_id });
    try fn_call_obj.put("name", std.json.Value{ .string = tool_call.name });

    const args_str = try std.json.stringifyAlloc(allocator, tool_call.arguments, .{});
    defer allocator.free(args_str);
    try fn_call_obj.put("arguments", std.json.Value{ .string = args_str });

    if (item_id) |id| {
        var norm_id = try normalizeIdPart(id, allocator);
        if (!std.mem.startsWith(u8, norm_id, "fc_")) {
            allocator.free(norm_id);
            norm_id = try std.fmt.allocPrint(allocator, "fc_{s}", .{id});
        }
        defer allocator.free(norm_id);
        try fn_call_obj.put("id", std.json.Value{ .string = norm_id });
    }

    return std.json.Value{ .object = fn_call_obj };
}

fn buildToolResult(allocator: std.mem.Allocator, tool_result: types.ToolResultMessage, model: types.Model) !std.json.Value {
    var text_parts = std.ArrayList([]const u8).init(allocator);
    defer {
        for (text_parts.items) |p| {
            allocator.free(p);
        }
        text_parts.deinit();
    }

    var has_images = false;
    var image_parts = std.json.Array.init(allocator);
    defer {
        for (image_parts.items) |*p| {
            p.deinit(allocator);
        }
        image_parts.deinit();
    }

    for (tool_result.content) |block| {
        switch (block) {
            .text => |text| {
                const sanitized = try sanitizeText(text.text, allocator);
                try text_parts.append(sanitized);
            },
            .image => |image| {
                has_images = true;
                const data_url = try std.fmt.allocPrint(
                    allocator,
                    "data:{s};base64,{s}",
                    .{ image.mime_type, image.data },
                );
                defer allocator.free(data_url);

                var img_obj = std.json.ObjectMap.init(allocator);
                try img_obj.put("type", std.json.Value{ .string = "input_image" });
                try img_obj.put("detail", std.json.Value{ .string = "auto" });
                try img_obj.put("image_url", std.json.Value{ .string = data_url });
                try image_parts.append(std.json.Value{ .object = img_obj });
            },
        }
    }

    const text_result = try std.mem.join(allocator, "\n", text_parts.items);
    defer allocator.free(text_result);

    const call_id = blk: {
        if (std.mem.indexOfScalar(u8, tool_result.tool_call_id, '|')) |idx| {
            break :blk tool_result.tool_call_id[0..idx];
        }
        break :blk tool_result.tool_call_id;
    };

    var fn_output_obj = std.json.ObjectMap.init(allocator);
    try fn_output_obj.put("type", std.json.Value{ .string = "function_call_output" });
    try fn_output_obj.put("call_id", std.json.Value{ .string = call_id });

    if (has_images and model.input.len > 0 and hasImageInput(model)) {
        var output_arr = std.json.Array.init(allocator);

        if (text_result.len > 0) {
            var text_obj = std.json.ObjectMap.init(allocator);
            try text_obj.put("type", std.json.Value{ .string = "input_text" });
            try text_obj.put("text", std.json.Value{ .string = text_result });
            try output_arr.append(std.json.Value{ .object = text_obj });
        }

        for (image_parts.items) |img| {
            try output_arr.append(img);
        }

        try fn_output_obj.put("output", std.json.Value{ .array = output_arr });
    } else {
        const output_text = if (text_result.len > 0) text_result else "(see attached image)";
        try fn_output_obj.put("output", std.json.Value{ .string = output_text });
    }

    return std.json.Value{ .object = fn_output_obj };
}

/// State for parsing streaming responses
pub const StreamState = struct {
    current_item: ?CurrentItem = null,
    current_block: ?CurrentBlock = null,
    response_id: ?[]const u8 = null,
    usage: types.Usage,
    stop_reason: types.StopReason = .stop,

    pub const CurrentItem = union(enum) {
        reasoning: ReasoningItem,
        message: MessageItem,
        function_call: FunctionCallItem,
    };

    pub const ReasoningItem = struct {
        id: []const u8,
        summary_parts: std.ArrayList(SummaryPart),

        pub const SummaryPart = struct {
            type: []const u8,
            text: []const u8,
        };
    };

    pub const MessageItem = struct {
        id: []const u8,
        role: []const u8,
        content: std.ArrayList(ContentPart),
        phase: ?[]const u8 = null,

        pub const ContentPart = union(enum) {
            output_text: struct {
                text: []const u8,
            },
            refusal: struct {
                refusal: []const u8,
            },
        };
    };

    pub const FunctionCallItem = struct {
        id: ?[]const u8,
        call_id: []const u8,
        name: []const u8,
        arguments: ?[]const u8,
    };

    pub const CurrentBlock = union(enum) {
        thinking: types.ThinkingContent,
        text: types.TextContent,
        tool_call: ToolCallBlock,
    };

    pub const ToolCallBlock = struct {
        id: []const u8,
        name: []const u8,
        arguments: std.json.Value,
        partial_json: []const u8,
    };

    pub fn init() StreamState {
        return .{
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
        };
    }
};

/// Parse a single SSE event from the Responses API stream
pub fn parseEvent(
    allocator: std.mem.Allocator,
    event_type: ?[]const u8,
    event_data: []const u8,
    state: *StreamState,
    model: types.Model,
) !?types.AssistantMessageEvent {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, event_data, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        _ = err;
        return null;
    };
    defer parsed.deinit();

    const data = parsed.value;

    const etype = event_type orelse blk: {
        if (data.object.get("type")) |t| {
            if (t == .string) break :blk t.string;
        }
        break :blk "";
    };

    if (std.mem.eql(u8, etype, "response.created")) {
        return try handleResponseCreated(allocator, data, state, model);
    }
    if (std.mem.eql(u8, etype, "response.output_item.added")) {
        return try handleOutputItemAdded(allocator, data, state, model);
    }
    if (std.mem.eql(u8, etype, "response.reasoning_summary_text.delta")) {
        return try handleReasoningDelta(allocator, data, state, model);
    }
    if (std.mem.eql(u8, etype, "response.output_text.delta")) {
        return try handleOutputTextDelta(allocator, data, state, model);
    }
    if (std.mem.eql(u8, etype, "response.refusal.delta")) {
        return try handleRefusalDelta(allocator, data, state, model);
    }
    if (std.mem.eql(u8, etype, "response.function_call_arguments.delta")) {
        return try handleFunctionCallDelta(allocator, data, state, model);
    }
    if (std.mem.eql(u8, etype, "response.output_item.done")) {
        return try handleOutputItemDone(allocator, data, state, model);
    }
    if (std.mem.eql(u8, etype, "response.completed") or
        std.mem.eql(u8, etype, "response.done") or
        std.mem.eql(u8, etype, "response.incomplete"))
    {
        return try handleResponseCompleted(allocator, data, state, model);
    }
    if (std.mem.eql(u8, etype, "error")) {
        return try handleError(allocator, data, state, model);
    }
    if (std.mem.eql(u8, etype, "response.failed")) {
        return try handleResponseFailed(allocator, data, state, model);
    }

    return null;
}

fn handleResponseCreated(allocator: std.mem.Allocator, data: std.json.Value, state: *StreamState, model: types.Model) !?types.AssistantMessageEvent {
    if (data.object.get("response")) |resp| {
        if (resp.object.get("id")) |id| {
            if (id == .string) {
                state.response_id = try allocator.dupe(u8, id.string);
            }
        }
    }
    return .{
        .start = .{
            .partial = .{
                .content = &.{},
                .api = model.api,
                .provider = model.provider,
                .model = model.id,
                .response_id = state.response_id,
                .usage = state.usage,
                .stop_reason = .stop,
                .timestamp = std.time.milliTimestamp(),
            },
        },
    };
}

fn handleOutputItemAdded(allocator: std.mem.Allocator, data: std.json.Value, state: *StreamState, model: types.Model) !?types.AssistantMessageEvent {
    const item = data.object.get("item") orelse return null;
    const item_type = item.object.get("type") orelse return null;
    if (item_type != .string) return null;

    if (std.mem.eql(u8, item_type.string, "reasoning")) {
        const id = if (item.object.get("id")) |id_val| if (id_val == .string) id_val.string else "rs_0" else "rs_0";

        state.current_item = .{
            .reasoning = .{
                .id = try allocator.dupe(u8, id),
                .summary_parts = std.ArrayList(StreamState.ReasoningItem.SummaryPart).init(allocator),
            },
        };
        state.current_block = .{
            .thinking = .{
                .thinking = "",
                .thinking_signature = null,
                .redacted = false,
            },
        };

        return .{
            .thinking_start = .{
                .content_index = 0,
                .partial = .{
                    .content = &.{},
                    .api = model.api,
                    .provider = model.provider,
                    .model = model.id,
                    .response_id = state.response_id,
                    .usage = state.usage,
                    .stop_reason = .stop,
                    .timestamp = std.time.milliTimestamp(),
                },
            },
        };
    } else if (std.mem.eql(u8, item_type.string, "message")) {
        const id = if (item.object.get("id")) |id_val| if (id_val == .string) id_val.string else "msg_0" else "msg_0";
        const role = if (item.object.get("role")) |r| if (r == .string) r.string else "assistant" else "assistant";
        const phase = if (item.object.get("phase")) |p| if (p == .string) p.string else null else null;

        state.current_item = .{
            .message = .{
                .id = try allocator.dupe(u8, id),
                .role = try allocator.dupe(u8, role),
                .content = std.ArrayList(StreamState.MessageItem.ContentPart).init(allocator),
                .phase = if (phase) |p| try allocator.dupe(u8, p) else null,
            },
        };
        state.current_block = .{
            .text = .{
                .text = "",
                .text_signature = null,
            },
        };

        return .{
            .text_start = .{
                .content_index = 0,
                .partial = .{
                    .content = &.{},
                    .api = model.api,
                    .provider = model.provider,
                    .model = model.id,
                    .response_id = state.response_id,
                    .usage = state.usage,
                    .stop_reason = .stop,
                    .timestamp = std.time.milliTimestamp(),
                },
            },
        };
    } else if (std.mem.eql(u8, item_type.string, "function_call")) {
        const call_id = if (item.object.get("call_id")) |cid| if (cid == .string) cid.string else "fc_0" else "fc_0";
        const name = if (item.object.get("name")) |n| if (n == .string) n.string else "" else "";
        const id = if (item.object.get("id")) |id_val| if (id_val == .string) id_val.string else null else null;

        state.current_item = .{
            .function_call = .{
                .id = if (id) |i| try allocator.dupe(u8, i) else null,
                .call_id = try allocator.dupe(u8, call_id),
                .name = try allocator.dupe(u8, name),
                .arguments = null,
            },
        };

        const full_id = if (id) |i| try std.fmt.allocPrint(allocator, "{s}|{s}", .{ call_id, i }) else try allocator.dupe(u8, call_id);

        state.current_block = .{
            .tool_call = .{
                .id = full_id,
                .name = try allocator.dupe(u8, name),
                .arguments = std.json.Value{ .object = std.json.ObjectMap.init(allocator) },
                .partial_json = "",
            },
        };

        return .{
            .toolcall_start = .{
                .content_index = 0,
                .partial = .{
                    .content = &.{},
                    .api = model.api,
                    .provider = model.provider,
                    .model = model.id,
                    .response_id = state.response_id,
                    .usage = state.usage,
                    .stop_reason = .stop,
                    .timestamp = std.time.milliTimestamp(),
                },
            },
        };
    }

    return null;
}

fn handleReasoningDelta(allocator: std.mem.Allocator, data: std.json.Value, state: *StreamState, model: types.Model) !?types.AssistantMessageEvent {
    const delta = data.object.get("delta") orelse return null;
    if (delta != .string) return null;

    if (state.current_block) |*block| {
        if (block.* == .thinking) {
            const old_len = block.thinking.thinking.len;
            const new_text = try allocator.alloc(u8, old_len + delta.string.len);
            @memcpy(new_text[0..old_len], block.thinking.thinking);
            @memcpy(new_text[old_len..], delta.string);
            block.thinking.thinking = new_text;

            return .{
                .thinking_delta = .{
                    .content_index = 0,
                    .delta = delta.string,
                    .partial = .{
                        .content = &.{},
                        .api = model.api,
                        .provider = model.provider,
                        .model = model.id,
                        .response_id = state.response_id,
                        .usage = state.usage,
                        .stop_reason = .stop,
                        .timestamp = std.time.milliTimestamp(),
                    },
                },
            };
        }
    }
    return null;
}

fn handleOutputTextDelta(allocator: std.mem.Allocator, data: std.json.Value, state: *StreamState, model: types.Model) !?types.AssistantMessageEvent {
    const delta = data.object.get("delta") orelse return null;
    if (delta != .string) return null;

    if (state.current_block) |*block| {
        if (block.* == .text) {
            const old_len = block.text.text.len;
            const new_text = try allocator.alloc(u8, old_len + delta.string.len);
            @memcpy(new_text[0..old_len], block.text.text);
            @memcpy(new_text[old_len..], delta.string);
            allocator.free(block.text.text);
            block.text.text = new_text;

            return .{
                .text_delta = .{
                    .content_index = 0,
                    .delta = delta.string,
                    .partial = .{
                        .content = &.{},
                        .api = model.api,
                        .provider = model.provider,
                        .model = model.id,
                        .response_id = state.response_id,
                        .usage = state.usage,
                        .stop_reason = .stop,
                        .timestamp = std.time.milliTimestamp(),
                    },
                },
            };
        }
    }
    return null;
}

fn handleRefusalDelta(allocator: std.mem.Allocator, data: std.json.Value, state: *StreamState, model: types.Model) !?types.AssistantMessageEvent {
    const delta = data.object.get("delta") orelse return null;
    if (delta != .string) return null;

    if (state.current_block) |*block| {
        if (block.* == .text) {
            const old_len = block.text.text.len;
            const new_text = try allocator.alloc(u8, old_len + delta.string.len);
            @memcpy(new_text[0..old_len], block.text.text);
            @memcpy(new_text[old_len..], delta.string);
            allocator.free(block.text.text);
            block.text.text = new_text;

            return .{
                .text_delta = .{
                    .content_index = 0,
                    .delta = delta.string,
                    .partial = .{
                        .content = &.{},
                        .api = model.api,
                        .provider = model.provider,
                        .model = model.id,
                        .response_id = state.response_id,
                        .usage = state.usage,
                        .stop_reason = .stop,
                        .timestamp = std.time.milliTimestamp(),
                    },
                },
            };
        }
    }
    return null;
}

fn handleFunctionCallDelta(allocator: std.mem.Allocator, data: std.json.Value, state: *StreamState, model: types.Model) !?types.AssistantMessageEvent {
    const delta = data.object.get("delta") orelse return null;
    if (delta != .string) return null;

    if (state.current_block) |*block| {
        if (block.* == .tool_call) {
            const old_len = block.tool_call.partial_json.len;
            const new_json = try allocator.alloc(u8, old_len + delta.string.len);
            @memcpy(new_json[0..old_len], block.tool_call.partial_json);
            @memcpy(new_json[old_len..], delta.string);
            if (old_len > 0) allocator.free(@constCast(block.tool_call.partial_json));
            block.tool_call.partial_json = new_json;

            const parsed_args = try json_parse.parseStreamingJson(allocator, block.tool_call.partial_json);
            block.tool_call.arguments = parsed_args;

            return .{
                .toolcall_delta = .{
                    .content_index = 0,
                    .delta = delta.string,
                    .partial = .{
                        .content = &.{},
                        .api = model.api,
                        .provider = model.provider,
                        .model = model.id,
                        .response_id = state.response_id,
                        .usage = state.usage,
                        .stop_reason = .stop,
                        .timestamp = std.time.milliTimestamp(),
                    },
                },
            };
        }
    }
    return null;
}

fn handleOutputItemDone(allocator: std.mem.Allocator, data: std.json.Value, state: *StreamState, model: types.Model) !?types.AssistantMessageEvent {
    const item = data.object.get("item") orelse return null;
    const item_type = item.object.get("type") orelse return null;
    if (item_type != .string) return null;

    if (std.mem.eql(u8, item_type.string, "reasoning")) {
        return try handleReasoningDone(allocator, item, state, model);
    } else if (std.mem.eql(u8, item_type.string, "message")) {
        return try handleMessageDone(allocator, item, state, model);
    } else if (std.mem.eql(u8, item_type.string, "function_call")) {
        return try handleFunctionCallDone(allocator, item, state, model);
    }

    return null;
}

fn handleReasoningDone(allocator: std.mem.Allocator, item: std.json.Value, state: *StreamState, model: types.Model) !?types.AssistantMessageEvent {
    if (state.current_item) |*ci| {
        if (ci.* == .reasoning) {
            const sig = try std.json.stringifyAlloc(allocator, item, .{});

            if (state.current_block) |*block| {
                if (block.* == .thinking) {
                    block.thinking.thinking_signature = sig;

                    if (ci.reasoning.summary_parts.items.len > 0) {
                        var total_len: usize = 0;
                        for (ci.reasoning.summary_parts.items) |part| {
                            total_len += part.text.len;
                        }
                        total_len += (ci.reasoning.summary_parts.items.len - 1) * 2;

                        const full_thinking = try allocator.alloc(u8, total_len);
                        var pos: usize = 0;
                        for (ci.reasoning.summary_parts.items, 0..) |part, i| {
                            if (i > 0) {
                                full_thinking[pos] = '\n';
                                full_thinking[pos + 1] = '\n';
                                pos += 2;
                            }
                            @memcpy(full_thinking[pos..][0..part.text.len], part.text);
                            pos += part.text.len;
                        }
                        allocator.free(block.thinking.thinking);
                        block.thinking.thinking = full_thinking;
                    }

                    const content = try allocator.dupe(u8, block.thinking.thinking);

                    for (ci.reasoning.summary_parts.items) |*part| {
                        allocator.free(part.text);
                    }
                    ci.reasoning.summary_parts.deinit();
                    allocator.free(ci.reasoning.id);

                    return .{
                        .thinking_end = .{
                            .content_index = 0,
                            .content = content,
                            .partial = .{
                                .content = &.{},
                                .api = model.api,
                                .provider = model.provider,
                                .model = model.id,
                                .response_id = state.response_id,
                                .usage = state.usage,
                                .stop_reason = .stop,
                                .timestamp = std.time.milliTimestamp(),
                            },
                        },
                    };
                }
            }
        }
    }
    return null;
}

fn handleMessageDone(allocator: std.mem.Allocator, item: std.json.Value, state: *StreamState, model: types.Model) !?types.AssistantMessageEvent {
    if (state.current_item) |*ci| {
        if (ci.* == .message) {
            var final_text = std.ArrayList(u8).init(allocator);
            defer final_text.deinit();

            if (item.object.get("content")) |content_arr| {
                if (content_arr == .array) {
                    for (content_arr.array.items) |part| {
                        if (part.object.get("type")) |part_type| {
                            if (part_type == .string) {
                                if (std.mem.eql(u8, part_type.string, "output_text")) {
                                    if (part.object.get("text")) |t| {
                                        if (t == .string) {
                                            try final_text.appendSlice(t.string);
                                        }
                                    }
                                } else if (std.mem.eql(u8, part_type.string, "refusal")) {
                                    if (part.object.get("refusal")) |r| {
                                        if (r == .string) {
                                            try final_text.appendSlice(r.string);
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            const content = try final_text.toOwnedSlice();

            for (ci.message.content.items) |*c| {
                switch (c.*) {
                    .output_text => |*ot| allocator.free(ot.text),
                    .refusal => |*r| allocator.free(r.refusal),
                }
            }
            ci.message.content.deinit();
            allocator.free(ci.message.id);
            allocator.free(ci.message.role);
            if (ci.message.phase) |p| allocator.free(p);

            return .{
                .text_end = .{
                    .content_index = 0,
                    .content = content,
                    .partial = .{
                        .content = &.{},
                        .api = model.api,
                        .provider = model.provider,
                        .model = model.id,
                        .response_id = state.response_id,
                        .usage = state.usage,
                        .stop_reason = .stop,
                        .timestamp = std.time.milliTimestamp(),
                    },
                },
            };
        }
    }
    return null;
}

fn handleFunctionCallDone(allocator: std.mem.Allocator, item: std.json.Value, state: *StreamState, model: types.Model) !?types.AssistantMessageEvent {
    if (state.current_item) |*ci| {
        if (ci.* == .function_call) {
            var final_args: std.json.Value = undefined;

            if (item.object.get("arguments")) |args| {
                if (args == .string) {
                    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, args.string, .{
                        .ignore_unknown_fields = true,
                    });
                    final_args = parsed.value;
                } else {
                    final_args = args;
                }
            } else if (state.current_block) |*block| {
                if (block.* == .tool_call) {
                    final_args = try json_parse.parseStreamingJson(allocator, block.tool_call.partial_json);
                } else {
                    final_args = std.json.Value{ .object = std.json.ObjectMap.init(allocator) };
                }
            } else {
                final_args = std.json.Value{ .object = std.json.ObjectMap.init(allocator) };
            }

            const call_id = if (ci.function_call.id) |id|
                try std.fmt.allocPrint(allocator, "{s}|{s}", .{ ci.function_call.call_id, id })
            else
                try allocator.dupe(u8, ci.function_call.call_id);

            const tool_call = types.ToolCall{
                .id = call_id,
                .name = try allocator.dupe(u8, ci.function_call.name),
                .arguments = final_args,
            };

            if (ci.function_call.id) |id| allocator.free(id);
            allocator.free(ci.function_call.call_id);
            allocator.free(ci.function_call.name);

            return .{
                .toolcall_end = .{
                    .content_index = 0,
                    .tool_call = tool_call,
                    .partial = .{
                        .content = &.{},
                        .api = model.api,
                        .provider = model.provider,
                        .model = model.id,
                        .response_id = state.response_id,
                        .usage = state.usage,
                        .stop_reason = .stop,
                        .timestamp = std.time.milliTimestamp(),
                    },
                },
            };
        }
    }
    return null;
}

fn handleResponseCompleted(allocator: std.mem.Allocator, data: std.json.Value, state: *StreamState, model: types.Model) !?types.AssistantMessageEvent {
    if (data.object.get("response")) |resp| {
        if (resp.object.get("id")) |id| {
            if (id == .string) {
                if (state.response_id) |old_id| {
                    allocator.free(old_id);
                }
                state.response_id = try allocator.dupe(u8, id.string);
            }
        }

        if (resp.object.get("usage")) |usage| {
            if (usage == .object) {
                const input_tokens: u64 = if (usage.object.get("input_tokens")) |it|
                    if (it == .integer) @as(u64, @intCast(it.integer)) else 0
                else
                    0;

                const output_tokens: u64 = if (usage.object.get("output_tokens")) |ot|
                    if (ot == .integer) @as(u64, @intCast(ot.integer)) else 0
                else
                    0;

                const total_tokens: u64 = if (usage.object.get("total_tokens")) |tt|
                    if (tt == .integer) @as(u64, @intCast(tt.integer)) else 0
                else
                    input_tokens + output_tokens;

                var cached_tokens: u64 = 0;
                if (usage.object.get("input_tokens_details")) |details| {
                    if (details == .object) {
                        if (details.object.get("cached_tokens")) |ct| {
                            if (ct == .integer) {
                                cached_tokens = @intCast(ct.integer);
                            }
                        }
                    }
                }

                const actual_input = if (input_tokens > cached_tokens) input_tokens - cached_tokens else 0;

                state.usage.input = actual_input;
                state.usage.output = output_tokens;
                state.usage.cache_read = cached_tokens;
                state.usage.cache_write = 0;
                state.usage.total_tokens = total_tokens;
            }
        }

        const status = if (resp.object.get("status")) |s|
            if (s == .string) s.string else "completed"
        else
            "completed";

        state.stop_reason = mapStopReason(status);
    }

    return .{
        .done = .{
            .reason = switch (state.stop_reason) {
                .stop => .stop,
                .length => .length,
                .tool_use => .tool_use,
                else => .stop,
            },
            .message = .{
                .content = &.{},
                .api = model.api,
                .provider = model.provider,
                .model = model.id,
                .response_id = state.response_id,
                .usage = state.usage,
                .stop_reason = state.stop_reason,
                .timestamp = std.time.milliTimestamp(),
            },
        },
    };
}

fn handleError(allocator: std.mem.Allocator, data: std.json.Value, state: *StreamState, model: types.Model) !?types.AssistantMessageEvent {
    const code = if (data.object.get("code")) |c|
        if (c == .string) c.string else "unknown"
    else
        "unknown";

    const message = if (data.object.get("message")) |m|
        if (m == .string) m.string else "Unknown error"
    else
        "Unknown error";

    const error_msg = try std.fmt.allocPrint(allocator, "Error Code {s}: {s}", .{ code, message });

    return .{
        .@"error" = .{
            .reason = .@"error",
            .@"error" = .{
                .content = &.{},
                .api = model.api,
                .provider = model.provider,
                .model = model.id,
                .response_id = state.response_id,
                .usage = state.usage,
                .stop_reason = .@"error",
                .error_message = error_msg,
                .timestamp = std.time.milliTimestamp(),
            },
        },
    };
}

fn handleResponseFailed(allocator: std.mem.Allocator, data: std.json.Value, state: *StreamState, model: types.Model) !?types.AssistantMessageEvent {
    var error_msg: []const u8 = "Unknown error";

    if (data.object.get("response")) |resp| {
        if (resp.object.get("error")) |err| {
            if (err == .object) {
                const code = if (err.object.get("code")) |c|
                    if (c == .string) c.string else null
                else
                    null;

                const msg = if (err.object.get("message")) |m|
                    if (m == .string) m.string else null
                else
                    null;

                if (code != null and msg != null) {
                    error_msg = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ code.?, msg.? });
                } else if (msg != null) {
                    error_msg = try allocator.dupe(u8, msg.?);
                } else if (code != null) {
                    error_msg = try std.fmt.allocPrint(allocator, "Error code: {s}", .{code.?});
                }
            }
        } else if (resp.object.get("incomplete_details")) |details| {
            if (details == .object) {
                if (details.object.get("reason")) |r| {
                    if (r == .string) {
                        error_msg = try std.fmt.allocPrint(allocator, "incomplete: {s}", .{r.string});
                    }
                }
            }
        }
    }

    return .{
        .@"error" = .{
            .reason = .@"error",
            .@"error" = .{
                .content = &.{},
                .api = model.api,
                .provider = model.provider,
                .model = model.id,
                .response_id = state.response_id,
                .usage = state.usage,
                .stop_reason = .@"error",
                .error_message = error_msg,
                .timestamp = std.time.milliTimestamp(),
            },
        },
    };
}

/// Map OpenAI response status to StopReason
fn mapStopReason(status: []const u8) types.StopReason {
    if (std.mem.eql(u8, status, "completed")) return .stop;
    if (std.mem.eql(u8, status, "incomplete")) return .length;
    if (std.mem.eql(u8, status, "failed")) return .@"error";
    if (std.mem.eql(u8, status, "cancelled")) return .@"error";
    if (std.mem.eql(u8, status, "in_progress")) return .stop;
    if (std.mem.eql(u8, status, "queued")) return .stop;
    return .stop;
}

/// Get service tier cost multiplier for pricing adjustments
pub fn getServiceTierCostMultiplier(service_tier: ?[]const u8) f64 {
    if (service_tier) |tier| {
        if (std.mem.eql(u8, tier, "flex")) return 0.5;
        if (std.mem.eql(u8, tier, "priority")) return 2.0;
    }
    return 1.0;
}

/// Apply service tier pricing multiplier to usage cost
pub fn applyServiceTierPricing(usage: *types.Usage, service_tier: ?[]const u8) void {
    const multiplier = getServiceTierCostMultiplier(service_tier);
    if (multiplier == 1.0) return;

    usage.cost.input *= multiplier;
    usage.cost.output *= multiplier;
    usage.cost.cache_read *= multiplier;
    usage.cost.cache_write *= multiplier;
    usage.cost.total = usage.cost.input + usage.cost.output + usage.cost.cache_read + usage.cost.cache_write;
}

/// Clamp reasoning effort based on model capabilities
pub fn clampReasoningEffort(model_id: []const u8, effort: []const u8) []const u8 {
    const base_id = if (std.mem.indexOfScalar(u8, model_id, '/')) |idx|
        model_id[idx + 1 ..]
    else
        model_id;

    if (std.mem.startsWith(u8, base_id, "gpt-5.2") or
        std.mem.startsWith(u8, base_id, "gpt-5.3") or
        std.mem.startsWith(u8, base_id, "gpt-5.4"))
    {
        if (std.mem.eql(u8, effort, "minimal")) return "low";
    }

    if (std.mem.eql(u8, base_id, "gpt-5.1")) {
        if (std.mem.eql(u8, effort, "xhigh")) return "high";
    }

    if (std.mem.eql(u8, base_id, "gpt-5.1-codex-mini")) {
        if (std.mem.eql(u8, effort, "high") or std.mem.eql(u8, effort, "xhigh")) return "high";
        return "medium";
    }

    return effort;
}
