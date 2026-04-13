const std = @import("std");
const protocol = @import("protocol.zig");
const json_util = @import("json_util.zig");

pub const ConvertOptions = struct {
    include_system_prompt: bool = true,
};

pub fn writeResponsesInput(
    allocator: std.mem.Allocator,
    jw: *std.json.Stringify,
    model: protocol.Model,
    context: protocol.Context,
    options: ConvertOptions,
) !void {
    var transformed = try transformMessages(allocator, context.messages, model);
    defer transformed.deinit();

    var input = try convertResponsesMessages(allocator, model, context.system_prompt, transformed.messages, options);
    defer input.deinit();

    try writeConvertedResponsesInput(allocator, jw, input.items);
}

pub const TransformedMessages = struct {
    allocator: std.mem.Allocator,
    messages: []protocol.Message,

    pub fn deinit(self: *TransformedMessages) void {
        for (self.messages) |msg| deinitMessage(self.allocator, msg);
        self.allocator.free(self.messages);
    }
};

pub fn transformMessages(
    allocator: std.mem.Allocator,
    messages: []const protocol.Message,
    model: protocol.Model,
) !TransformedMessages {
    var result: std.ArrayListUnmanaged(protocol.Message) = .empty;
    errdefer deinitMessageList(allocator, result.items);
    errdefer result.deinit(allocator);

    var tool_id_map: std.ArrayListUnmanaged(ToolCallIdMapping) = .empty;
    defer {
        for (tool_id_map.items) |mapping| mapping.deinit(allocator);
        tool_id_map.deinit(allocator);
    }

    var pending_tool_calls: std.ArrayListUnmanaged(PendingToolCallRef) = .empty;
    defer pending_tool_calls.deinit(allocator);

    var existing_tool_result_ids: std.ArrayListUnmanaged([]const u8) = .empty;
    defer existing_tool_result_ids.deinit(allocator);

    for (messages) |msg| {
        switch (msg) {
            .user => |u| {
                try flushPendingSyntheticToolResults(allocator, &result, pending_tool_calls.items, existing_tool_result_ids.items);
                pending_tool_calls.clearRetainingCapacity();
                existing_tool_result_ids.clearRetainingCapacity();
                try result.append(allocator, .{ .user = try cloneUserMessage(allocator, u) });
            },
            .assistant => |a| {
                try flushPendingSyntheticToolResults(allocator, &result, pending_tool_calls.items, existing_tool_result_ids.items);
                pending_tool_calls.clearRetainingCapacity();
                existing_tool_result_ids.clearRetainingCapacity();

                if (a.stop_reason == .@"error" or a.stop_reason == .aborted) continue;

                const transformed = try transformAssistantMessage(allocator, a, model, &tool_id_map);
                try result.append(allocator, .{ .assistant = transformed });

                const appended = &result.items[result.items.len - 1].assistant;
                for (appended.content) |block| switch (block) {
                    .tool_call => |tool_call| try pending_tool_calls.append(allocator, .{
                        .id = tool_call.id,
                        .name = tool_call.name,
                    }),
                    else => {},
                };
            },
            .tool_result => |tr| {
                const transformed = try transformToolResultMessage(allocator, tr, tool_id_map.items);
                try result.append(allocator, .{ .tool_result = transformed });
                try existing_tool_result_ids.append(allocator, result.items[result.items.len - 1].tool_result.tool_call_id);
            },
        }
    }

    return .{
        .allocator = allocator,
        .messages = try result.toOwnedSlice(allocator),
    };
}

pub const ResponsesInputItems = struct {
    allocator: std.mem.Allocator,
    items: []ResponsesInputItem,

    pub fn deinit(self: *ResponsesInputItems) void {
        for (self.items) |item| deinitResponsesInputItem(self.allocator, item);
        self.allocator.free(self.items);
    }
};

pub fn convertResponsesMessages(
    allocator: std.mem.Allocator,
    model: protocol.Model,
    system_prompt: ?[]const u8,
    messages: []const protocol.Message,
    options: ConvertOptions,
) !ResponsesInputItems {
    var items: std.ArrayListUnmanaged(ResponsesInputItem) = .empty;
    errdefer deinitResponsesInputItemList(allocator, items.items);
    errdefer items.deinit(allocator);

    if (options.include_system_prompt) {
        if (system_prompt) |prompt| {
            try items.append(allocator, .{ .system_message = .{
                .role = if (model.reasoning) "developer" else "system",
                .content = try sanitizeTextAlloc(allocator, prompt),
            } });
        }
    }

    var msg_index: usize = 0;
    for (messages) |msg| {
        switch (msg) {
            .user => |u| {
                if (try convertUserMessage(allocator, model, u)) |item| {
                    try items.append(allocator, item);
                }
            },
            .assistant => |a| try appendAssistantItems(allocator, &items, model, a, msg_index),
            .tool_result => |tr| try items.append(allocator, try convertToolResultInput(allocator, model, tr)),
        }
        msg_index += 1;
    }

    return .{
        .allocator = allocator,
        .items = try items.toOwnedSlice(allocator),
    };
}

const PendingToolCallRef = struct {
    id: []const u8,
    name: []const u8,
};

const ToolCallIdMapping = struct {
    original_id: []const u8,
    mapped_id: []const u8,

    fn deinit(self: ToolCallIdMapping, allocator: std.mem.Allocator) void {
        allocator.free(self.original_id);
        allocator.free(self.mapped_id);
    }
};

const ResponsesInputContentPart = union(enum) {
    input_text: []const u8,
    input_image: struct {
        detail: []const u8,
        image_url: []const u8,
    },
};

const ResponsesInputItem = union(enum) {
    system_message: struct {
        role: []const u8,
        content: []const u8,
    },
    user_message: struct {
        content: []const ResponsesInputContentPart,
    },
    reasoning_item: []const u8,
    assistant_message: struct {
        id: []const u8,
        phase: ?[]const u8,
        text: []const u8,
    },
    function_call: struct {
        id: ?[]const u8,
        call_id: []const u8,
        name: []const u8,
        arguments: []const u8,
    },
    function_call_output_text: struct {
        call_id: []const u8,
        output: []const u8,
    },
    function_call_output_parts: struct {
        call_id: []const u8,
        output: []const ResponsesInputContentPart,
    },
};

fn appendAssistantItems(
    allocator: std.mem.Allocator,
    items: *std.ArrayListUnmanaged(ResponsesInputItem),
    model: protocol.Model,
    assistant: protocol.AssistantMessage,
    msg_index: usize,
) !void {
    const is_different_model = !std.mem.eql(u8, assistant.model, model.id) and
        providersEqual(assistant.provider, model.provider) and
        apisEqual(assistant.api, model.api);

    for (assistant.content) |block| switch (block) {
        .thinking => |thinking| {
            const sig = thinking.thinking_signature orelse continue;
            try items.append(allocator, .{ .reasoning_item = try allocator.dupe(u8, sig) });
        },
        .text => |text| {
            const resolved = try resolveAssistantMessageId(allocator, text.text_signature, msg_index);
            errdefer allocator.free(resolved.id);

            try items.append(allocator, .{ .assistant_message = .{
                .id = resolved.id,
                .phase = resolved.phase,
                .text = try sanitizeTextAlloc(allocator, text.text),
            } });
        },
        .tool_call => |tool_call| {
            const split = splitToolCallId(tool_call.id);
            const item_id = if (split.item_id) |raw_item_id|
                if (is_different_model and std.mem.startsWith(u8, raw_item_id, "fc_")) null else try allocator.dupe(u8, raw_item_id)
            else
                null;
            errdefer if (item_id) |id| allocator.free(id);

            var args_buf: std.io.Writer.Allocating = .init(allocator);
            defer args_buf.deinit();
            var inner = std.json.Stringify{ .writer = &args_buf.writer, .options = .{} };
            try inner.write(tool_call.arguments);

            try items.append(allocator, .{ .function_call = .{
                .id = item_id,
                .call_id = try allocator.dupe(u8, split.call_id),
                .name = try allocator.dupe(u8, tool_call.name),
                .arguments = try allocator.dupe(u8, args_buf.written()),
            } });
        },
    };
}

fn convertUserMessage(
    allocator: std.mem.Allocator,
    model: protocol.Model,
    user: protocol.UserMessage,
) !?ResponsesInputItem {
    var content: std.ArrayListUnmanaged(ResponsesInputContentPart) = .empty;
    errdefer deinitResponsesInputContentList(allocator, content.items);
    errdefer content.deinit(allocator);

    switch (user.content) {
        .text => |text| try content.append(allocator, .{ .input_text = try sanitizeTextAlloc(allocator, text) }),
        .blocks => |blocks| for (blocks) |block| switch (block) {
            .text => |text| try content.append(allocator, .{ .input_text = try sanitizeTextAlloc(allocator, text.text) }),
            .image => |image| {
                if (!modelSupportsInputType(model, .image)) continue;
                const url = try std.fmt.allocPrint(
                    allocator,
                    "data:{s};base64,{s}",
                    .{ image.mime_type, image.data },
                );
                try content.append(allocator, .{ .input_image = .{
                    .detail = "auto",
                    .image_url = url,
                } });
            },
        },
    }

    if (content.items.len == 0) return null;
    return .{ .user_message = .{ .content = try content.toOwnedSlice(allocator) } };
}

fn convertToolResultInput(
    allocator: std.mem.Allocator,
    model: protocol.Model,
    tool_result: protocol.ToolResultMessage,
) !ResponsesInputItem {
    var joined_text: std.ArrayListUnmanaged(u8) = .empty;
    defer joined_text.deinit(allocator);

    var has_images = false;
    var has_text = false;
    for (tool_result.content) |block| switch (block) {
        .text => |text| {
            if (has_text) try joined_text.append(allocator, '\n');
            try joined_text.appendSlice(allocator, text.text);
            has_text = true;
        },
        .image => has_images = true,
    };

    const split = splitToolCallId(tool_result.tool_call_id);
    const call_id = try allocator.dupe(u8, split.call_id);
    errdefer allocator.free(call_id);

    if (has_images and modelSupportsInputType(model, .image)) {
        var parts: std.ArrayListUnmanaged(ResponsesInputContentPart) = .empty;
        errdefer deinitResponsesInputContentList(allocator, parts.items);
        errdefer parts.deinit(allocator);

        if (has_text) {
            try parts.append(allocator, .{ .input_text = try sanitizeTextAlloc(allocator, joined_text.items) });
        }

        for (tool_result.content) |block| switch (block) {
            .text => {},
            .image => |image| {
                const url = try std.fmt.allocPrint(
                    allocator,
                    "data:{s};base64,{s}",
                    .{ image.mime_type, image.data },
                );
                try parts.append(allocator, .{ .input_image = .{
                    .detail = "auto",
                    .image_url = url,
                } });
            },
        };

        return .{ .function_call_output_parts = .{
            .call_id = call_id,
            .output = try parts.toOwnedSlice(allocator),
        } };
    }

    return .{ .function_call_output_text = .{
        .call_id = call_id,
        .output = try sanitizeTextAlloc(allocator, if (has_text) joined_text.items else "(see attached image)"),
    } };
}

fn writeConvertedResponsesInput(
    allocator: std.mem.Allocator,
    jw: *std.json.Stringify,
    items: []const ResponsesInputItem,
) !void {
    for (items) |item| switch (item) {
        .system_message => |msg| {
            try jw.beginObject();
            try jw.objectField("role");
            try jw.write(msg.role);
            try jw.objectField("content");
            try jw.write(msg.content);
            try jw.endObject();
        },
        .user_message => |msg| {
            try jw.beginObject();
            try jw.objectField("role");
            try jw.write("user");
            try jw.objectField("content");
            try jw.beginArray();
            try writeResponsesInputContentParts(jw, msg.content);
            try jw.endArray();
            try jw.endObject();
        },
        .reasoning_item => |raw_json| {
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw_json, .{}) catch continue;
            defer parsed.deinit();
            try jw.write(parsed.value);
        },
        .assistant_message => |msg| {
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("message");
            try jw.objectField("role");
            try jw.write("assistant");
            try jw.objectField("content");
            try jw.beginArray();
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("output_text");
            try jw.objectField("text");
            try jw.write(msg.text);
            try jw.objectField("annotations");
            try jw.beginArray();
            try jw.endArray();
            try jw.endObject();
            try jw.endArray();
            try jw.objectField("status");
            try jw.write("completed");
            try jw.objectField("id");
            try jw.write(msg.id);
            if (msg.phase) |phase| {
                try jw.objectField("phase");
                try jw.write(phase);
            }
            try jw.endObject();
        },
        .function_call => |call| {
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("function_call");
            if (call.id) |id| {
                try jw.objectField("id");
                try jw.write(id);
            }
            try jw.objectField("call_id");
            try jw.write(call.call_id);
            try jw.objectField("name");
            try jw.write(call.name);
            try jw.objectField("arguments");
            try jw.write(call.arguments);
            try jw.endObject();
        },
        .function_call_output_text => |output| {
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("function_call_output");
            try jw.objectField("call_id");
            try jw.write(output.call_id);
            try jw.objectField("output");
            try jw.write(output.output);
            try jw.endObject();
        },
        .function_call_output_parts => |output| {
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("function_call_output");
            try jw.objectField("call_id");
            try jw.write(output.call_id);
            try jw.objectField("output");
            try jw.beginArray();
            try writeResponsesInputContentParts(jw, output.output);
            try jw.endArray();
            try jw.endObject();
        },
    };
}

fn writeResponsesInputContentParts(
    jw: *std.json.Stringify,
    parts: []const ResponsesInputContentPart,
) !void {
    for (parts) |part| switch (part) {
        .input_text => |text| {
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("input_text");
            try jw.objectField("text");
            try jw.write(text);
            try jw.endObject();
        },
        .input_image => |image| {
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("input_image");
            try jw.objectField("detail");
            try jw.write(image.detail);
            try jw.objectField("image_url");
            try jw.write(image.image_url);
            try jw.endObject();
        },
    };
}

fn transformAssistantMessage(
    allocator: std.mem.Allocator,
    assistant: protocol.AssistantMessage,
    model: protocol.Model,
    tool_id_map: *std.ArrayListUnmanaged(ToolCallIdMapping),
) !protocol.AssistantMessage {
    const same_model = assistantMessageIsSameModel(assistant, model);

    var content: std.ArrayListUnmanaged(protocol.AssistantMessage.AssistantContentBlock) = .empty;
    errdefer deinitAssistantContentList(allocator, content.items);
    errdefer content.deinit(allocator);

    for (assistant.content) |block| switch (block) {
        .thinking => |thinking| {
            if (thinking.redacted orelse false) {
                if (!same_model) continue;
                try content.append(allocator, .{ .thinking = try cloneThinkingContent(allocator, thinking) });
                continue;
            }
            if (same_model and thinking.thinking_signature != null) {
                try content.append(allocator, .{ .thinking = try cloneThinkingContent(allocator, thinking) });
                continue;
            }
            if (std.mem.trim(u8, thinking.thinking, &std.ascii.whitespace).len == 0) continue;
            if (same_model) {
                try content.append(allocator, .{ .thinking = try cloneThinkingContent(allocator, thinking) });
            } else {
                try content.append(allocator, .{ .text = .{
                    .text = try allocator.dupe(u8, thinking.thinking),
                    .text_signature = null,
                } });
            }
        },
        .text => |text| {
            if (same_model) {
                try content.append(allocator, .{ .text = try cloneTextContent(allocator, text) });
            } else {
                try content.append(allocator, .{ .text = .{
                    .text = try allocator.dupe(u8, text.text),
                    .text_signature = null,
                } });
            }
        },
        .tool_call => |tool_call| {
            const id = if (same_model)
                try allocator.dupe(u8, tool_call.id)
            else
                try normalizeResponsesToolCallId(allocator, model, assistant, tool_call.id);
            errdefer allocator.free(id);

            if (!same_model and !std.mem.eql(u8, id, tool_call.id)) {
                try recordToolCallIdMapping(allocator, tool_id_map, tool_call.id, id);
            }

            try content.append(allocator, .{ .tool_call = .{
                .id = id,
                .name = try allocator.dupe(u8, tool_call.name),
                .arguments = try json_util.cloneJsonValue(allocator, tool_call.arguments),
                .thought_signature = if (!same_model) null else if (tool_call.thought_signature) |sig| try allocator.dupe(u8, sig) else null,
            } });
        },
    };

    return .{
        .content = try content.toOwnedSlice(allocator),
        .api = assistant.api,
        .provider = assistant.provider,
        .model = assistant.model,
        .response_id = assistant.response_id,
        .usage = assistant.usage,
        .stop_reason = assistant.stop_reason,
        .error_message = assistant.error_message,
        .failure = assistant.failure,
        .timestamp = assistant.timestamp,
    };
}

fn transformToolResultMessage(
    allocator: std.mem.Allocator,
    tool_result: protocol.ToolResultMessage,
    tool_id_map: []const ToolCallIdMapping,
) !protocol.ToolResultMessage {
    var content: std.ArrayListUnmanaged(protocol.ToolResultMessage.ContentBlock) = .empty;
    errdefer deinitToolResultContentList(allocator, content.items);
    errdefer content.deinit(allocator);

    for (tool_result.content) |block| switch (block) {
        .text => |text| try content.append(allocator, .{ .text = try cloneTextContent(allocator, text) }),
        .image => |image| try content.append(allocator, .{ .image = try cloneImageContent(allocator, image) }),
    };

    return .{
        .tool_call_id = try getMappedToolCallId(allocator, tool_id_map, tool_result.tool_call_id),
        .tool_name = try allocator.dupe(u8, tool_result.tool_name),
        .content = try content.toOwnedSlice(allocator),
        .details = if (tool_result.details) |details| try json_util.cloneJsonValue(allocator, details) else null,
        .is_error = tool_result.is_error,
        .timestamp = tool_result.timestamp,
    };
}

fn flushPendingSyntheticToolResults(
    allocator: std.mem.Allocator,
    result: *std.ArrayListUnmanaged(protocol.Message),
    pending_tool_calls: []const PendingToolCallRef,
    existing_tool_result_ids: []const []const u8,
) !void {
    for (pending_tool_calls) |pending| {
        var found = false;
        for (existing_tool_result_ids) |existing| {
            if (std.mem.eql(u8, existing, pending.id)) {
                found = true;
                break;
            }
        }
        if (found) continue;

        const text = try allocator.dupe(u8, "No result provided");
        errdefer allocator.free(text);
        const tool_call_id = try allocator.dupe(u8, pending.id);
        errdefer allocator.free(tool_call_id);
        const tool_name = try allocator.dupe(u8, pending.name);
        errdefer allocator.free(tool_name);
        const content = try allocator.alloc(protocol.ToolResultMessage.ContentBlock, 1);
        errdefer allocator.free(content);
        content[0] = .{ .text = .{ .text = text } };

        try result.append(allocator, .{ .tool_result = .{
            .tool_call_id = tool_call_id,
            .tool_name = tool_name,
            .content = content,
            .details = null,
            .is_error = true,
            .timestamp = std.time.milliTimestamp(),
        } });
    }
}

fn recordToolCallIdMapping(
    allocator: std.mem.Allocator,
    tool_id_map: *std.ArrayListUnmanaged(ToolCallIdMapping),
    original_id: []const u8,
    mapped_id: []const u8,
) !void {
    for (tool_id_map.items) |*mapping| {
        if (std.mem.eql(u8, mapping.original_id, original_id)) {
            allocator.free(mapping.mapped_id);
            mapping.mapped_id = try allocator.dupe(u8, mapped_id);
            return;
        }
    }

    try tool_id_map.append(allocator, .{
        .original_id = try allocator.dupe(u8, original_id),
        .mapped_id = try allocator.dupe(u8, mapped_id),
    });
}

fn getMappedToolCallId(
    allocator: std.mem.Allocator,
    mappings: []const ToolCallIdMapping,
    tool_call_id: []const u8,
) ![]const u8 {
    for (mappings) |mapping| {
        if (std.mem.eql(u8, mapping.original_id, tool_call_id)) {
            return allocator.dupe(u8, mapping.mapped_id);
        }
    }
    return allocator.dupe(u8, tool_call_id);
}

fn resolveAssistantMessageId(
    allocator: std.mem.Allocator,
    text_signature: ?[]const u8,
    msg_index: usize,
) !struct { id: []const u8, phase: ?[]const u8 } {
    var parsed_phase: ?[]const u8 = null;
    var candidate_id: ?[]const u8 = null;

    if (text_signature) |sig| {
        if (sig.len > 0 and sig[0] == '{') {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            if (std.json.parseFromSlice(std.json.Value, arena.allocator(), sig, .{})) |parsed| {
                defer parsed.deinit();
                if (parsed.value == .object) {
                    if (parsed.value.object.get("v")) |v| {
                        if (v == .integer and v.integer != 1) {
                            candidate_id = null;
                        } else if (parsed.value.object.get("id")) |id| {
                            if (id == .string) {
                                candidate_id = id.string;
                                if (parsed.value.object.get("phase")) |phase| {
                                    if (phase == .string) {
                                        if (std.mem.eql(u8, phase.string, "commentary") or std.mem.eql(u8, phase.string, "final_answer")) {
                                            parsed_phase = try allocator.dupe(u8, phase.string);
                                        }
                                    }
                                }
                            }
                        }
                    } else if (parsed.value.object.get("id")) |id| {
                        if (id == .string) candidate_id = id.string;
                    }
                }
            } else |_| {
                candidate_id = sig;
            }
        } else {
            candidate_id = sig;
        }
    }

    const final_id = if (candidate_id) |id|
        if (id.len == 0)
            try std.fmt.allocPrint(allocator, "msg_{d}", .{msg_index})
        else if (id.len > 64)
            try std.fmt.allocPrint(allocator, "msg_{s}", .{try shortHashAlloc(allocator, id)})
        else
            try allocator.dupe(u8, id)
    else
        try std.fmt.allocPrint(allocator, "msg_{d}", .{msg_index});

    return .{ .id = final_id, .phase = parsed_phase };
}

fn splitToolCallId(id: []const u8) struct { call_id: []const u8, item_id: ?[]const u8 } {
    if (std.mem.indexOfScalar(u8, id, '|')) |sep| {
        return .{ .call_id = id[0..sep], .item_id = id[sep + 1 ..] };
    }
    return .{ .call_id = id, .item_id = null };
}

fn normalizeResponsesToolCallId(
    allocator: std.mem.Allocator,
    target_model: protocol.Model,
    source: protocol.AssistantMessage,
    id: []const u8,
) ![]const u8 {
    if (!targetUsesResponsesToolCallNormalization(target_model.provider)) {
        return normalizeIdPart(allocator, id);
    }
    if (std.mem.indexOfScalar(u8, id, '|')) |sep| {
        const normalized_call_id = try normalizeIdPart(allocator, id[0..sep]);
        errdefer allocator.free(normalized_call_id);

        const item_part = id[sep + 1 ..];
        const is_foreign_tool_call = !providersEqual(source.provider, target_model.provider) or !apisEqual(source.api, target_model.api);
        var normalized_item_id = if (is_foreign_tool_call)
            try buildForeignResponsesItemId(allocator, item_part)
        else
            try normalizeIdPart(allocator, item_part);
        errdefer allocator.free(normalized_item_id);

        if (!std.mem.startsWith(u8, normalized_item_id, "fc_")) {
            const prefixed = try std.fmt.allocPrint(allocator, "fc_{s}", .{normalized_item_id});
            defer allocator.free(prefixed);
            allocator.free(normalized_item_id);
            normalized_item_id = try normalizeIdPart(allocator, prefixed);
        }

        return std.fmt.allocPrint(allocator, "{s}|{s}", .{ normalized_call_id, normalized_item_id });
    }
    return normalizeIdPart(allocator, id);
}

fn targetUsesResponsesToolCallNormalization(provider: protocol.Provider) bool {
    return switch (provider) {
        .openai, .openai_codex, .azure_openai_responses, .opencode => true,
        else => false,
    };
}

fn normalizeIdPart(allocator: std.mem.Allocator, part: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    for (part) |c| {
        const normalized = switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-' => c,
            else => '_',
        };
        try out.append(allocator, normalized);
        if (out.items.len >= 64) break;
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '_') {
        _ = out.pop();
    }
    if (out.items.len == 0) {
        try out.appendSlice(allocator, "id");
    }
    return out.toOwnedSlice(allocator);
}

fn buildForeignResponsesItemId(allocator: std.mem.Allocator, item_id: []const u8) ![]const u8 {
    const hash = try shortHashAlloc(allocator, item_id);
    defer allocator.free(hash);
    const raw = try std.fmt.allocPrint(allocator, "fc_{s}", .{hash});
    defer allocator.free(raw);
    return normalizeIdPart(allocator, raw);
}

fn shortHashAlloc(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var h1: u32 = 0xdeadbeef;
    var h2: u32 = 0x41c6ce57;

    for (text) |c| {
        h1 = imul32(h1 ^ @as(u32, c), 2654435761);
        h2 = imul32(h2 ^ @as(u32, c), 1597334677);
    }

    h1 = imul32(h1 ^ (h1 >> 16), 2246822507) ^ imul32(h2 ^ (h2 >> 13), 3266489909);
    h2 = imul32(h2 ^ (h2 >> 16), 2246822507) ^ imul32(h1 ^ (h1 >> 13), 3266489909);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendBase36U32(allocator, &out, h2);
    try appendBase36U32(allocator, &out, h1);
    return out.toOwnedSlice(allocator);
}

fn appendBase36U32(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    value: u32,
) !void {
    if (value == 0) {
        try out.append(allocator, '0');
        return;
    }

    var buf: [16]u8 = undefined;
    var idx: usize = buf.len;
    var n = value;
    while (n != 0) {
        const digit = n % 36;
        idx -= 1;
        buf[idx] = if (digit < 10) @as(u8, '0') + @as(u8, @intCast(digit)) else @as(u8, 'a') + @as(u8, @intCast(digit - 10));
        n /= 36;
    }
    try out.appendSlice(allocator, buf[idx..]);
}

fn imul32(a: u32, b: u32) u32 {
    return a *% b;
}

fn assistantMessageIsSameModel(assistant: protocol.AssistantMessage, model: protocol.Model) bool {
    return providersEqual(assistant.provider, model.provider) and
        apisEqual(assistant.api, model.api) and
        std.mem.eql(u8, assistant.model, model.id);
}

fn modelSupportsInputType(model: protocol.Model, input_type: protocol.Model.InputType) bool {
    for (model.input) |candidate| {
        if (candidate == input_type) return true;
    }
    return false;
}

fn sanitizeTextAlloc(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    return json_util.utf8LossyAlloc(allocator, text);
}

fn cloneUserMessage(allocator: std.mem.Allocator, user: protocol.UserMessage) !protocol.UserMessage {
    return .{
        .content = switch (user.content) {
            .text => |text| .{ .text = try allocator.dupe(u8, text) },
            .blocks => |blocks| blk: {
                const cloned = try allocator.alloc(protocol.UserMessage.UserMessageContent.Block, blocks.len);
                errdefer allocator.free(cloned);
                for (blocks, 0..) |block, i| cloned[i] = switch (block) {
                    .text => |text| .{ .text = try cloneTextContent(allocator, text) },
                    .image => |image| .{ .image = try cloneImageContent(allocator, image) },
                };
                break :blk .{ .blocks = cloned };
            },
        },
        .timestamp = user.timestamp,
    };
}

fn cloneTextContent(allocator: std.mem.Allocator, text: protocol.TextContent) !protocol.TextContent {
    return .{
        .text = try allocator.dupe(u8, text.text),
        .text_signature = if (text.text_signature) |sig| try allocator.dupe(u8, sig) else null,
    };
}

fn cloneThinkingContent(allocator: std.mem.Allocator, thinking: protocol.ThinkingContent) !protocol.ThinkingContent {
    return .{
        .thinking = try allocator.dupe(u8, thinking.thinking),
        .thinking_signature = if (thinking.thinking_signature) |sig| try allocator.dupe(u8, sig) else null,
        .redacted = thinking.redacted,
    };
}

fn cloneImageContent(allocator: std.mem.Allocator, image: protocol.ImageContent) !protocol.ImageContent {
    return .{
        .data = try allocator.dupe(u8, image.data),
        .mime_type = try allocator.dupe(u8, image.mime_type),
    };
}

fn deinitMessageList(allocator: std.mem.Allocator, messages: []protocol.Message) void {
    for (messages) |msg| deinitMessage(allocator, msg);
}

fn deinitMessage(allocator: std.mem.Allocator, msg: protocol.Message) void {
    switch (msg) {
        .user => |user| deinitUserMessage(allocator, user),
        .assistant => |assistant| deinitAssistantMessage(allocator, assistant),
        .tool_result => |tool_result| deinitToolResultMessage(allocator, tool_result),
    }
}

fn deinitUserMessage(allocator: std.mem.Allocator, user: protocol.UserMessage) void {
    switch (user.content) {
        .text => |text| allocator.free(text),
        .blocks => |blocks| {
            for (blocks) |block| switch (block) {
                .text => |text| deinitTextContent(allocator, text),
                .image => |image| deinitImageContent(allocator, image),
            };
            allocator.free(blocks);
        },
    }
}

fn deinitAssistantMessage(allocator: std.mem.Allocator, assistant: protocol.AssistantMessage) void {
    deinitAssistantContentList(allocator, assistant.content);
    allocator.free(assistant.content);
}

fn deinitToolResultMessage(allocator: std.mem.Allocator, tool_result: protocol.ToolResultMessage) void {
    allocator.free(tool_result.tool_call_id);
    allocator.free(tool_result.tool_name);
    deinitToolResultContentList(allocator, tool_result.content);
    allocator.free(tool_result.content);
    if (tool_result.details) |details| json_util.freeJsonValue(allocator, details);
}

fn deinitAssistantContentList(allocator: std.mem.Allocator, content: []const protocol.AssistantMessage.AssistantContentBlock) void {
    for (content) |block| switch (block) {
        .text => |text| deinitTextContent(allocator, text),
        .thinking => |thinking| deinitThinkingContent(allocator, thinking),
        .tool_call => |tool_call| deinitToolCall(allocator, tool_call),
    };
}

fn deinitToolResultContentList(allocator: std.mem.Allocator, content: []const protocol.ToolResultMessage.ContentBlock) void {
    for (content) |block| switch (block) {
        .text => |text| deinitTextContent(allocator, text),
        .image => |image| deinitImageContent(allocator, image),
    };
}

fn deinitTextContent(allocator: std.mem.Allocator, text: protocol.TextContent) void {
    allocator.free(text.text);
    if (text.text_signature) |sig| allocator.free(sig);
}

fn deinitThinkingContent(allocator: std.mem.Allocator, thinking: protocol.ThinkingContent) void {
    allocator.free(thinking.thinking);
    if (thinking.thinking_signature) |sig| allocator.free(sig);
}

fn deinitImageContent(allocator: std.mem.Allocator, image: protocol.ImageContent) void {
    allocator.free(image.data);
    allocator.free(image.mime_type);
}

fn deinitToolCall(allocator: std.mem.Allocator, tool_call: protocol.ToolCall) void {
    allocator.free(tool_call.id);
    allocator.free(tool_call.name);
    json_util.freeJsonValue(allocator, tool_call.arguments);
    if (tool_call.thought_signature) |sig| allocator.free(sig);
}

fn deinitResponsesInputItemList(allocator: std.mem.Allocator, items: []ResponsesInputItem) void {
    for (items) |item| deinitResponsesInputItem(allocator, item);
}

fn deinitResponsesInputItem(allocator: std.mem.Allocator, item: ResponsesInputItem) void {
    switch (item) {
        .system_message => |msg| allocator.free(msg.content),
        .user_message => |msg| {
            deinitResponsesInputContentList(allocator, msg.content);
            allocator.free(msg.content);
        },
        .reasoning_item => |raw_json| allocator.free(raw_json),
        .assistant_message => |msg| {
            allocator.free(msg.id);
            if (msg.phase) |phase| allocator.free(phase);
            allocator.free(msg.text);
        },
        .function_call => |call| {
            if (call.id) |id| allocator.free(id);
            allocator.free(call.call_id);
            allocator.free(call.name);
            allocator.free(call.arguments);
        },
        .function_call_output_text => |output| {
            allocator.free(output.call_id);
            allocator.free(output.output);
        },
        .function_call_output_parts => |output| {
            allocator.free(output.call_id);
            deinitResponsesInputContentList(allocator, output.output);
            allocator.free(output.output);
        },
    }
}

fn deinitResponsesInputContentList(allocator: std.mem.Allocator, parts: []const ResponsesInputContentPart) void {
    for (parts) |part| switch (part) {
        .input_text => |text| allocator.free(text),
        .input_image => |image| allocator.free(image.image_url),
    };
}

fn providersEqual(a: protocol.Provider, b: protocol.Provider) bool {
    return std.meta.eql(a, b);
}

fn apisEqual(a: protocol.Api, b: protocol.Api) bool {
    return std.meta.eql(a, b);
}

const testing = std.testing;

test "transformMessages converts cross-model thinking to text and strips tool thought signatures" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var args = std.json.Value{ .object = std.json.ObjectMap.init(alloc) };
    defer args.object.deinit();

    const messages: []const protocol.Message = &.{
        .{ .user = .{ .content = .{ .text = "hello" }, .timestamp = 0 } },
        .{ .assistant = .{
            .content = &.{
                .{ .thinking = .{ .thinking = "Let me think", .thinking_signature = "{\"type\":\"reasoning\"}" } },
                .{ .tool_call = .{
                    .id = "call_123",
                    .name = "bash",
                    .arguments = args,
                    .thought_signature = "opaque-signature",
                } },
            },
            .api = .openai_responses,
            .provider = .github_copilot,
            .model = "gpt-5",
            .usage = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total_tokens = 0, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 } },
            .stop_reason = .toolUse,
            .timestamp = 0,
        } },
    };

    const target_model = protocol.Model{
        .id = "claude-sonnet-4",
        .name = "Claude Sonnet 4",
        .api = .anthropic_messages,
        .provider = .github_copilot,
        .base_url = "https://api.individual.githubcopilot.com",
        .reasoning = true,
        .input = &.{ .text, .image },
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128000,
        .max_tokens = 16000,
    };

    var transformed = try transformMessages(alloc, messages, target_model);
    defer transformed.deinit();

    const assistant = transformed.messages[1].assistant;
    try testing.expectEqual(@as(usize, 2), assistant.content.len);
    try testing.expect(assistant.content[0] == .text);
    try testing.expectEqualStrings("Let me think", assistant.content[0].text.text);
    try testing.expect(assistant.content[1] == .tool_call);
    try testing.expect(assistant.content[1].tool_call.thought_signature == null);
}

test "convertResponsesMessages hashes foreign responses item ids like pi-mono" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var args = std.json.Value{ .object = std.json.ObjectMap.init(alloc) };
    defer args.object.deinit();

    const raw_id = "call_4VnzVawQXPB9MgYib7CiQFEY|I9b95oN1wD/cHXKTw3PpRkL6KkCtzTJhUxMouMWYwHeTo2j3htzfSk7YPx2vifiIM4g3A8XXyOj8q4Bt6SLUG7gqY1E3ELkrkVQNHglRfUmWj84lqxJY+Puieb3VKyX0FB+83TUzn91cDMF/4gzt990IzqVrc+nIb9RRscRD070Du16q1glydVjWR0SBJsE6TbY/esOjFpqplogQqrajm1eI++f3eLi73R6q7hVusY0QbeFySVxABCjhN0lXB04caBe1rzHjYzul6MAXj7uq+0r17VLq+yrtyYhN12wkmFqHeqTyEei6EFPbMy24Nc+IbJlkP0OCg02W+gOnyBFcbi2ctvJFSOhSjt1CqBdqCnnhwUqXjbWiT0wh3DmLScRgTHmGkaI+oAcQQjfic65nxj+TnEkReA==";

    const transformed_messages: []const protocol.Message = &.{
        .{ .assistant = .{
            .content = &.{.{ .tool_call = .{
                .id = raw_id,
                .name = "edit",
                .arguments = args,
            } }},
            .api = .openai_responses,
            .provider = .github_copilot,
            .model = "gpt-5.3-codex",
            .usage = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total_tokens = 0, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 } },
            .stop_reason = .toolUse,
            .timestamp = 0,
        } },
    };

    const model = protocol.Model{
        .id = "gpt-5.3-codex",
        .name = "GPT-5.3 Codex",
        .api = .openai_codex_responses,
        .provider = .openai_codex,
        .base_url = "https://chatgpt.com/backend-api",
        .reasoning = true,
        .input = &.{.text},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 400000,
        .max_tokens = 128000,
    };

    var transformed = try transformMessages(alloc, transformed_messages, model);
    defer transformed.deinit();
    var input = try convertResponsesMessages(alloc, model, null, transformed.messages, .{});
    defer input.deinit();

    try testing.expectEqual(@as(usize, 1), input.items.len);
    try testing.expect(input.items[0] == .function_call);
    try testing.expectEqualStrings("call_4VnzVawQXPB9MgYib7CiQFEY", input.items[0].function_call.call_id);
    try testing.expectEqualStrings("fc_ifd2c719fz6a9", input.items[0].function_call.id.?);
}

test "convertResponsesMessages preserves legacy plain-string text signatures" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const messages: []const protocol.Message = &.{
        .{ .assistant = .{
            .content = &.{.{ .text = .{ .text = "hello", .text_signature = "legacy_msg_id" } }},
            .api = .openai_responses,
            .provider = .openai,
            .model = "gpt-5.4",
            .usage = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total_tokens = 0, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 } },
            .stop_reason = .stop,
            .timestamp = 0,
        } },
    };
    const model = protocol.Model{
        .id = "gpt-5.4",
        .name = "GPT-5.4",
        .api = .openai_responses,
        .provider = .openai,
        .base_url = "https://api.openai.com",
        .reasoning = true,
        .input = &.{.text},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128000,
        .max_tokens = 4096,
    };

    var input = try convertResponsesMessages(alloc, model, null, messages, .{});
    defer input.deinit();

    try testing.expectEqual(@as(usize, 1), input.items.len);
    try testing.expect(input.items[0] == .assistant_message);
    try testing.expectEqualStrings("legacy_msg_id", input.items[0].assistant_message.id);
}

test "convertResponsesMessages preserves text signature phase as string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const messages: []const protocol.Message = &.{
        .{ .assistant = .{
            .content = &.{.{ .text = .{ .text = "hello", .text_signature = "{\"v\":1,\"id\":\"msg_123\",\"phase\":\"final_answer\"}" } }},
            .api = .openai_responses,
            .provider = .openai,
            .model = "gpt-5.4",
            .usage = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total_tokens = 0, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 } },
            .stop_reason = .stop,
            .timestamp = 0,
        } },
    };
    const model = protocol.Model{
        .id = "gpt-5.4",
        .name = "GPT-5.4",
        .api = .openai_responses,
        .provider = .openai,
        .base_url = "https://api.openai.com",
        .reasoning = true,
        .input = &.{.text},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128000,
        .max_tokens = 4096,
    };

    var input = try convertResponsesMessages(alloc, model, null, messages, .{});
    defer input.deinit();

    try testing.expectEqual(@as(usize, 1), input.items.len);
    try testing.expect(input.items[0] == .assistant_message);
    try testing.expectEqualStrings("msg_123", input.items[0].assistant_message.id);
    try testing.expect(input.items[0].assistant_message.phase != null);
    try testing.expectEqualStrings("final_answer", input.items[0].assistant_message.phase.?);
}
