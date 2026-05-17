const std = @import("std");
const protocol = @import("../protocol.zig");

fn supportsAdaptiveThinking(model_id: []const u8) bool {
    if (std.mem.indexOf(u8, model_id, "opus-4-6") != null) return true;
    if (std.mem.indexOf(u8, model_id, "opus-4.6") != null) return true;
    if (std.mem.indexOf(u8, model_id, "sonnet-4-6") != null) return true;
    if (std.mem.indexOf(u8, model_id, "sonnet-4.6") != null) return true;
    return false;
}

fn mapThinkingLevelToEffort(level: protocol.ThinkingLevel, model_id: []const u8) []const u8 {
    return switch (level) {
        .minimal, .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => if (std.mem.indexOf(u8, model_id, "opus-4-6") != null or
            std.mem.indexOf(u8, model_id, "opus-4.6") != null) "max" else "high",
    };
}

fn adjustMaxTokensForThinking(
    base_max_tokens: u64,
    model_max_tokens: u64,
    level: protocol.ThinkingLevel,
    custom_budgets: ?protocol.ThinkingBudgets,
) struct { max_tokens: u64, thinking_budget: u64 } {
    const default_budgets = .{
        .minimal = @as(u64, 1024),
        .low = @as(u64, 2048),
        .medium = @as(u64, 8192),
        .high = @as(u64, 16384),
    };

    const thinking_budget_raw: u64 = switch (level) {
        .minimal => if (custom_budgets) |b| b.minimal orelse default_budgets.minimal else default_budgets.minimal,
        .low => if (custom_budgets) |b| b.low orelse default_budgets.low else default_budgets.low,
        .medium => if (custom_budgets) |b| b.medium orelse default_budgets.medium else default_budgets.medium,
        .high, .xhigh => if (custom_budgets) |b| b.high orelse default_budgets.high else default_budgets.high,
    };

    const min_output_tokens: u64 = 1024;
    const max_tokens = @min(base_max_tokens + thinking_budget_raw, model_max_tokens);
    const thinking_budget = if (max_tokens <= thinking_budget_raw)
        if (max_tokens > min_output_tokens) max_tokens - min_output_tokens else 0
    else
        thinking_budget_raw;

    return .{ .max_tokens = max_tokens, .thinking_budget = thinking_budget };
}

pub const AnthropicMetadataContext = struct {
    metadata: ?std.json.Value,
};

pub fn anthropicMetadataUserId(metadata: ?std.json.Value) ?[]const u8 {
    const value = metadata orelse return null;
    if (value != .object) return null;
    const user_id = value.object.get("user_id") orelse return null;
    if (user_id != .string or user_id.string.len == 0) return null;
    return user_id.string;
}

pub fn addAnthropicMetadata(
    allocator: std.mem.Allocator,
    payload: *std.json.Value,
    _: *const protocol.Model,
    ctx: ?*anyopaque,
) !bool {
    const metadata_context: *const AnthropicMetadataContext = @ptrCast(@alignCast(ctx.?));
    const user_id = anthropicMetadataUserId(metadata_context.metadata) orelse return false;

    var metadata: std.json.ObjectMap = .{};
    errdefer metadata.deinit(allocator);
    try metadata.put(allocator, "user_id", .{ .string = user_id });
    try payload.object.put(allocator, "metadata", .{ .object = metadata });
    return true;
}

pub fn buildRequestJson(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), model: protocol.Model, context: protocol.Context, options: protocol.StreamOptions, is_oauth: bool, reasoning: ?protocol.ThinkingLevel, thinking_budgets: ?protocol.ThinkingBudgets) !void {
    var out = std.Io.Writer.Allocating.fromArrayList(allocator, buf);
    var jw: std.json.Stringify = .{ .writer = &out.writer };

    try jw.beginObject();
    try jw.objectField("model");
    try jw.write(model.id);
    const effective_max_tokens = blk: {
        if (model.reasoning) {
            if (reasoning) |level| {
                if (!supportsAdaptiveThinking(model.id)) {
                    const adjusted = adjustMaxTokensForThinking(
                        options.max_tokens orelse model.max_tokens,
                        model.max_tokens,
                        level,
                        thinking_budgets,
                    );
                    break :blk adjusted.max_tokens;
                }
            }
        }
        break :blk options.max_tokens orelse model.max_tokens;
    };
    try jw.objectField("max_tokens");
    try jw.write(effective_max_tokens);
    try jw.objectField("stream");
    try jw.write(true);

    if (is_oauth) {
        try jw.objectField("system");
        try jw.beginArray();
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write("text");
        try jw.objectField("text");
        try jw.write("You are Claude Code, Anthropic's official CLI for Claude.");
        try jw.endObject();
        if (context.system_prompt) |system| {
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("text");
            try jw.objectField("text");
            try jw.write(system);
            try jw.endObject();
        }
        try jw.endArray();
    } else if (context.system_prompt) |system| {
        try jw.objectField("system");
        try jw.write(system);
    }

    try jw.objectField("messages");
    try jw.beginArray();
    var i: usize = 0;
    while (i < context.messages.len) : (i += 1) {
        const msg = context.messages[i];
        if (msg == .tool_result) {
            try jw.beginObject();
            try jw.objectField("role");
            try jw.write("user");
            try jw.objectField("content");
            try jw.beginArray();

            try writeToolResultBlock(&jw, msg.tool_result);
            while (i + 1 < context.messages.len and context.messages[i + 1] == .tool_result) : (i += 1) {
                try writeToolResultBlock(&jw, context.messages[i + 1].tool_result);
            }

            try jw.endArray();
            try jw.endObject();
            continue;
        }
        try writeMessageJson(&jw, msg);
    }
    try jw.endArray();

    if (context.tools) |tools| {
        if (tools.len > 0) {
            try jw.objectField("tools");
            try jw.beginArray();
            for (tools) |tool| {
                try jw.beginObject();
                try jw.objectField("name");
                try jw.write(tool.name);
                try jw.objectField("description");
                try jw.write(tool.description);
                try jw.objectField("input_schema");
                try jw.write(tool.parameters);
                try jw.endObject();
            }
            try jw.endArray();
        }
    }

    if (options.temperature) |temp| {
        if (reasoning == null) {
            try jw.objectField("temperature");
            try jw.print("{d}", .{temp});
        }
    }

    if (model.reasoning) {
        if (reasoning) |level| {
            if (supportsAdaptiveThinking(model.id)) {
                try jw.objectField("thinking");
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("adaptive");
                try jw.endObject();
                try jw.objectField("output_config");
                try jw.beginObject();
                try jw.objectField("effort");
                try jw.write(mapThinkingLevelToEffort(level, model.id));
                try jw.endObject();
            } else {
                const adjusted = adjustMaxTokensForThinking(
                    options.max_tokens orelse model.max_tokens,
                    model.max_tokens,
                    level,
                    thinking_budgets,
                );
                try jw.objectField("thinking");
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("enabled");
                try jw.objectField("budget_tokens");
                try jw.write(adjusted.thinking_budget);
                try jw.endObject();
            }
        } else {
            try jw.objectField("thinking");
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("disabled");
            try jw.endObject();
        }
    }

    try jw.endObject();
    buf.* = out.toArrayList();
}

fn writeMessageJson(jw: *std.json.Stringify, msg: protocol.Message) !void {
    try jw.beginObject();
    switch (msg) {
        .user => |user| {
            try jw.objectField("role");
            try jw.write("user");
            try jw.objectField("content");
            switch (user.content) {
                .text => |text_val| try jw.write(text_val),
                .blocks => |blocks| {
                    try jw.beginArray();
                    for (blocks) |block| {
                        switch (block) {
                            .text => |t| {
                                try jw.beginObject();
                                try jw.objectField("type");
                                try jw.write("text");
                                try jw.objectField("text");
                                try jw.write(t.text);
                                try jw.endObject();
                            },
                            .image => |img| try writeAnthropicImageBlock(jw, img),
                        }
                    }
                    try jw.endArray();
                },
            }
        },
        .assistant => |assistant| {
            try jw.objectField("role");
            try jw.write("assistant");
            try jw.objectField("content");
            try jw.beginArray();
            for (assistant.content) |block| {
                switch (block) {
                    .text => |t| {
                        try jw.beginObject();
                        try jw.objectField("type");
                        try jw.write("text");
                        try jw.objectField("text");
                        try jw.write(t.text);
                        try jw.endObject();
                    },
                    .thinking => |th| {
                        try jw.beginObject();
                        try jw.objectField("type");
                        try jw.write("thinking");
                        try jw.objectField("thinking");
                        try jw.write(th.thinking);
                        if (th.thinking_signature) |sig| {
                            try jw.objectField("signature");
                            try jw.write(sig);
                        }
                        try jw.endObject();
                    },
                    .tool_call => |tc| {
                        try jw.beginObject();
                        try jw.objectField("type");
                        try jw.write("tool_use");
                        try jw.objectField("id");
                        try jw.write(tc.id);
                        try jw.objectField("name");
                        try jw.write(tc.name);
                        try jw.objectField("input");
                        if (tc.arguments == .null) {
                            try jw.beginObject();
                            try jw.endObject();
                        } else {
                            try jw.write(tc.arguments);
                        }
                        try jw.endObject();
                    },
                }
            }
            try jw.endArray();
        },
        .tool_result => |tr| {
            try jw.objectField("role");
            try jw.write("user");
            try jw.objectField("content");
            try jw.beginArray();
            try writeToolResultBlock(jw, tr);
            try jw.endArray();
        },
    }
    try jw.endObject();
}

fn writeToolResultBlock(jw: *std.json.Stringify, tr: protocol.ToolResultMessage) !void {
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("tool_result");
    try jw.objectField("tool_use_id");
    try jw.write(tr.tool_call_id);
    try jw.objectField("content");
    try jw.beginArray();
    for (tr.content) |content_block| {
        switch (content_block) {
            .text => |t| {
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("text");
                try jw.objectField("text");
                try jw.write(t.text);
                try jw.endObject();
            },
            .image => |img| try writeAnthropicImageBlock(jw, img),
        }
    }
    try jw.endArray();
    if (tr.is_error) {
        try jw.objectField("is_error");
        try jw.write(true);
    }
    try jw.endObject();
}

fn writeAnthropicImageBlock(jw: *std.json.Stringify, img: protocol.ImageContent) !void {
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("image");
    try jw.objectField("source");
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("base64");
    try jw.objectField("media_type");
    try jw.write(img.mime_type);
    try jw.objectField("data");
    try jw.write(img.data);
    try jw.endObject();
    try jw.endObject();
}
