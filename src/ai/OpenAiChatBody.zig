const std = @import("std");
const Item = @import("Item.zig");
const Provider = @import("Provider.zig");

pub const default_maximum_body_bytes: usize = 32 * 1024 * 1024;
pub const maximum_json_depth: usize = 64;
pub const maximum_json_fields: usize = 4096;
pub const maximum_json_work: usize = 65_536;

pub const ReasoningFormat = enum { flat, nested };

pub const Options = struct {
    provider_id: []const u8 = "openai",
    reasoning_field: ?[]const u8 = null,
    reasoning_format: ReasoningFormat = .flat,
    cache_markers: bool = false,
    cache_ttl: []const u8 = "1h",
    prompt_cache_key: ?[]const u8 = null,
    emit_progress: bool = false,
    request_cost: bool = false,
    /// A borrowed JSON object. Protocol-owned members are rejected rather than ignored.
    extra_body_json: ?[]const u8 = null,
    maximum_body_bytes: usize = default_maximum_body_bytes,
};

pub const Error = error{ OutOfMemory, InvalidRequest, BodyTooLarge };

/// Returns compact JSON owned by `allocator`. All request and option data is borrowed.
pub fn build(allocator: std.mem.Allocator, request: Provider.Request, options: Options) Error![]u8 {
    if (options.maximum_body_bytes == 0 or
        options.maximum_body_bytes > default_maximum_body_bytes)
    {
        return error.InvalidRequest;
    }
    var extra = try parseExtra(allocator, options.extra_body_json, options.maximum_body_bytes);
    defer if (extra) |*parsed| parsed.deinit();
    try validateRequest(request, options);

    var count_buffer: [256]u8 = undefined;
    const buffer_length = @min(count_buffer.len, options.maximum_body_bytes + 1);
    var counter: LimitedCounter = .init(count_buffer[0..buffer_length], options.maximum_body_bytes);
    writeBody(
        allocator,
        &counter.writer,
        request,
        options,
        if (extra) |*value| &value.value else null,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => if (counter.exceeded) return error.BodyTooLarge else unreachable,
    };
    const length = counter.fullCount();
    if (length > options.maximum_body_bytes) return error.BodyTooLarge;

    const body = try allocator.alloc(u8, length);
    errdefer allocator.free(body);
    var writer: std.Io.Writer = .fixed(body);
    writeBody(
        allocator,
        &writer,
        request,
        options,
        if (extra) |*value| &value.value else null,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => unreachable,
    };
    std.debug.assert(writer.end == body.len);
    return body;
}

const LimitedCounter = struct {
    count: usize = 0,
    limit: usize,
    exceeded: bool = false,
    writer: std.Io.Writer,

    fn init(buffer: []u8, limit: usize) LimitedCounter {
        return .{ .limit = limit, .writer = .{ .vtable = &.{ .drain = drain }, .buffer = buffer } };
    }

    fn fullCount(self: *const LimitedCounter) usize {
        return self.count + self.writer.end;
    }

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *LimitedCounter = @alignCast(@fieldParentPtr("writer", writer));
        var written = std.math.mul(usize, data[data.len - 1].len, splat) catch {
            self.exceeded = true;
            return error.WriteFailed;
        };
        for (data[0 .. data.len - 1]) |bytes| written = std.math.add(usize, written, bytes.len) catch {
            self.exceeded = true;
            return error.WriteFailed;
        };
        const current = std.math.add(usize, self.count, writer.end) catch {
            self.exceeded = true;
            return error.WriteFailed;
        };
        const final = std.math.add(usize, current, written) catch {
            self.exceeded = true;
            return error.WriteFailed;
        };
        if (final > self.limit) {
            self.exceeded = true;
            return error.WriteFailed;
        }
        self.count = final;
        writer.end = 0;
        return written;
    }
};

fn parseExtra(
    allocator: std.mem.Allocator,
    bytes: ?[]const u8,
    maximum_body_bytes: usize,
) Error!?std.json.Parsed(std.json.Value) {
    const source = bytes orelse return null;
    if (source.len > maximum_body_bytes) return error.BodyTooLarge;
    try validateJsonLimits(source);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, source, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidRequest,
    };
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRequest;
    for (reserved_members) |name| if (parsed.value.object.contains(name)) return error.InvalidRequest;
    return parsed;
}

const reserved_members = [_][]const u8{
    "model", "stream", "messages", "input", "include", "n", "system", "tools", "stream_options", "instructions",
};

fn validateJsonLimits(bytes: []const u8) Error!void {
    var depth: usize = 0;
    var fields: usize = 0;
    var work: usize = 0;
    var in_string = false;
    var escaped = false;
    for (bytes) |byte| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_string = false;
            }
            continue;
        }
        switch (byte) {
            '"' => in_string = true,
            '{', '[' => {
                depth += 1;
                work += 1;
                if (depth > maximum_json_depth) return error.InvalidRequest;
            },
            '}', ']' => {
                if (depth == 0) return error.InvalidRequest;
                depth -= 1;
            },
            ':' => {
                fields += 1;
                work += 1;
                if (fields > maximum_json_fields) return error.InvalidRequest;
            },
            ',' => work += 1,
            else => {},
        }
        if (work > maximum_json_work) return error.InvalidRequest;
    }
    if (in_string or depth != 0) return error.InvalidRequest;
}
fn validateRequest(request: Provider.Request, options: Options) Error!void {
    if (options.maximum_body_bytes == 0 or options.maximum_body_bytes > default_maximum_body_bytes or
        request.model.len == 0 or options.provider_id.len == 0) return error.InvalidRequest;
    try textField(request.model, options.maximum_body_bytes, true);
    try textField(options.provider_id, options.maximum_body_bytes, true);
    try textField(request.context.system_prompt, options.maximum_body_bytes, false);
    try textField(options.cache_ttl, options.maximum_body_bytes, true);
    if (!std.ascii.eqlIgnoreCase(options.cache_ttl, "1h") and
        !std.ascii.eqlIgnoreCase(options.cache_ttl, "5m")) return error.InvalidRequest;
    if (options.reasoning_field) |value| try textField(value, options.maximum_body_bytes, true);
    if (options.prompt_cache_key) |value| try textField(value, options.maximum_body_bytes, true);
    if (request.context.effort) |value| try textField(value, options.maximum_body_bytes, false);

    for (request.context.items) |item| switch (item) {
        .user_message => |message| try textField(message.text, options.maximum_body_bytes, false),
        .assistant_message => |message| try textField(message.text, options.maximum_body_bytes, false),
        .tool_call => |call| {
            try textField(call.id, options.maximum_body_bytes, false);
            try textField(call.name, options.maximum_body_bytes, false);
            try textField(call.arguments_json, options.maximum_body_bytes, false);
        },
        .tool_result => |result| {
            try textField(result.call_id, options.maximum_body_bytes, false);
            try textField(result.output, options.maximum_body_bytes, false);
            for (result.images) |image| {
                try textField(image.mime, options.maximum_body_bytes, false);
                try textField(image.data_base64, options.maximum_body_bytes, false);
            }
        },
        .reasoning => |reasoning| {
            if (reasoning.text) |value| try textField(value, options.maximum_body_bytes, false);
            if (reasoning.opaque_json) |value| {
                if (value.len > options.maximum_body_bytes) return error.BodyTooLarge;
            }
        },
        .turn_boundary, .turn_usage => {},
    };
    for (request.context.tools) |tool| {
        try textField(tool.name, options.maximum_body_bytes, true);
        try textField(tool.description, options.maximum_body_bytes, false);
        for (tool.parameters) |parameter| {
            try textField(parameter.name, options.maximum_body_bytes, true);
            try textField(parameter.description, options.maximum_body_bytes, false);
        }
    }
}

fn textField(bytes: []const u8, maximum: usize, nonempty: bool) Error!void {
    if (bytes.len > maximum) return error.BodyTooLarge;
    if ((nonempty and bytes.len == 0) or !std.unicode.utf8ValidateSlice(bytes)) return error.InvalidRequest;
}

fn writeBody(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    request: Provider.Request,
    options: Options,
    extra: ?*const std.json.Value,
) !void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginObject();
    try field(&json, "model", request.model);
    try field(&json, "stream", true);
    try json.objectField("messages");
    try writeMessages(allocator, &json, request, options);
    try json.objectField("stream_options");
    try json.beginObject();
    try field(&json, "include_usage", true);
    try json.endObject();
    if (request.context.tools.len != 0) {
        try json.objectField("tools");
        try writeTools(&json, request.context.tools);
    }
    try writeOptionalGenerated(&json, request, options, extra);
    try writeExtraFields(&json, extra, request, options);
    try json.endObject();
}

fn writeOptionalGenerated(
    json: *std.json.Stringify,
    request: Provider.Request,
    options: Options,
    extra: ?*const std.json.Value,
) !void {
    if (options.prompt_cache_key) |value| try fieldOrExtra(json, "prompt_cache_key", value, extra);
    if (options.emit_progress) try fieldOrExtra(json, "return_progress", true, extra);
    if (options.request_cost) {
        try json.objectField("usage");
        if (extraValue(extra, "usage")) |override| {
            if (override.* != .object) {
                try json.write(override.*);
            } else {
                try writeUsageObject(json, &override.object);
            }
        } else {
            try writeUsageObject(json, null);
        }
    }
    if (request.context.effort) |effort| if (effort.len != 0) switch (options.reasoning_format) {
        .flat => try fieldOrExtra(json, "reasoning_effort", effort, extra),
        .nested => {
            try json.objectField("reasoning");
            if (extraValue(extra, "reasoning")) |override| {
                if (override.* != .object) {
                    try json.write(override.*);
                } else {
                    try writeReasoningObject(json, effort, &override.object);
                }
            } else {
                try writeReasoningObject(json, effort, null);
            }
        },
    };
}

fn writeUsageObject(json: *std.json.Stringify, object: ?*const std.json.ObjectMap) !void {
    try json.beginObject();
    try fieldOrObject(json, "include", true, object);
    if (object) |value| try writeObjectRemainder(json, value, &.{"include"});
    try json.endObject();
}

fn writeReasoningObject(
    json: *std.json.Stringify,
    effort: []const u8,
    object: ?*const std.json.ObjectMap,
) !void {
    try json.beginObject();
    const enabled = !std.mem.eql(u8, effort, "none");
    try fieldOrObject(json, "enabled", enabled, object);
    if (enabled) try fieldOrObject(json, "effort", effort, object);
    if (object) |value| {
        const skip: []const []const u8 = if (enabled) &.{ "enabled", "effort" } else &.{"enabled"};
        try writeObjectRemainder(json, value, skip);
    }
    try json.endObject();
}

fn writeExtraFields(
    json: *std.json.Stringify,
    extra: ?*const std.json.Value,
    request: Provider.Request,
    options: Options,
) !void {
    const value = extra orelse return;
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        const name = entry.key_ptr.*;
        if (generatedOptional(name, request, options)) continue;
        try json.objectField(name);
        try json.write(entry.value_ptr.*);
    }
}

fn generatedOptional(name: []const u8, request: Provider.Request, options: Options) bool {
    if (std.mem.eql(u8, name, "prompt_cache_key") and options.prompt_cache_key != null) return true;
    if (std.mem.eql(u8, name, "return_progress") and options.emit_progress) return true;
    if (std.mem.eql(u8, name, "usage") and options.request_cost) return true;
    const effort = request.context.effort orelse return false;
    if (effort.len == 0) return false;
    return switch (options.reasoning_format) {
        .flat => std.mem.eql(u8, name, "reasoning_effort"),
        .nested => std.mem.eql(u8, name, "reasoning"),
    };
}

fn fieldOrExtra(json: *std.json.Stringify, name: []const u8, value: anytype, extra: ?*const std.json.Value) !void {
    try json.objectField(name);
    if (extraValue(extra, name)) |override| try json.write(override.*) else try json.write(value);
}

fn fieldOrObject(
    json: *std.json.Stringify,
    name: []const u8,
    value: anytype,
    object: ?*const std.json.ObjectMap,
) !void {
    try json.objectField(name);
    if (object) |map| if (map.getPtr(name)) |override| {
        try json.write(override.*);
        return;
    };
    try json.write(value);
}

fn extraValue(extra: ?*const std.json.Value, name: []const u8) ?*const std.json.Value {
    const value = extra orelse return null;
    return value.object.getPtr(name);
}

fn extraObject(extra: ?*const std.json.Value, name: []const u8) ?*const std.json.ObjectMap {
    const value = extraValue(extra, name) orelse return null;
    if (value.* != .object) return null;
    return &value.object;
}

fn writeObjectRemainder(json: *std.json.Stringify, object: *const std.json.ObjectMap, skip: []const []const u8) !void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        var omitted = false;
        for (skip) |name| {
            if (std.mem.eql(u8, name, entry.key_ptr.*)) omitted = true;
        }
        if (omitted) continue;
        try json.objectField(entry.key_ptr.*);
        try json.write(entry.value_ptr.*);
    }
}

fn field(json: *std.json.Stringify, name: []const u8, value: anytype) !void {
    try json.objectField(name);
    try json.write(value);
}

const MessagePlan = struct { count: usize = 0, has_system: bool = false, tail_cacheable: ?usize = null };

fn planMessages(allocator: std.mem.Allocator, request: Provider.Request, options: Options) !MessagePlan {
    var plan: MessagePlan = .{};
    if (request.context.system_prompt.len != 0) {
        plan.has_system = true;
        plan.tail_cacheable = plan.count;
        plan.count += 1;
    }
    var index: usize = 0;
    while (index < request.context.items.len) switch (request.context.items[index]) {
        .user_message => {
            plan.tail_cacheable = plan.count;
            plan.count += 1;
            index += 1;
        },
        .assistant_message, .tool_call, .reasoning => {
            const run = try inspectAssistantRun(allocator, request, options, index);
            if (run.emit) {
                if (run.content) plan.tail_cacheable = plan.count;
                plan.count += 1;
            }
            index = run.end;
        },
        .tool_result => {
            var has_images = false;
            while (index < request.context.items.len and request.context.items[index] == .tool_result) : (index += 1) {
                plan.tail_cacheable = plan.count;
                plan.count += 1;
                has_images = has_images or request.context.items[index].tool_result.images.len != 0;
            }
            if (has_images and request.context.image_input != .unsupported) {
                plan.tail_cacheable = plan.count;
                plan.count += 1;
            }
        },
        .turn_boundary, .turn_usage => index += 1,
    };
    return plan;
}

const AssistantRun = struct { end: usize, emit: bool, content: bool, details: bool };

fn inspectAssistantRun(
    allocator: std.mem.Allocator,
    request: Provider.Request,
    options: Options,
    first: usize,
) !AssistantRun {
    var index = first;
    var has_text = false;
    var has_calls = false;
    var has_reasoning = false;
    var has_details = false;
    while (index < request.context.items.len) : (index += 1) switch (request.context.items[index]) {
        .assistant_message => |message| has_text = has_text or message.text.len != 0,
        .tool_call => has_calls = true,
        .reasoning => |reasoning| if (reasoningMatches(reasoning, options.provider_id, request.model)) {
            if (reasoning.text) |value| has_reasoning = has_reasoning or value.len != 0;
            has_details = has_details or try reasoningHasArray(allocator, reasoning.opaque_json);
        },
        else => break,
    };
    const plain = options.reasoning_field != null and has_reasoning and !has_details;
    return .{
        .end = index,
        .emit = has_text or has_calls or plain or has_details,
        .content = has_text,
        .details = has_details,
    };
}

fn writeMessages(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    request: Provider.Request,
    options: Options,
) !void {
    const plan = try planMessages(allocator, request, options);
    var ordinal: usize = 0;
    try json.beginArray();
    if (request.context.system_prompt.len != 0) {
        try writeTextMessage(
            json,
            "system",
            request.context.system_prompt,
            cacheAt(options, plan, ordinal),
            options.cache_ttl,
        );
        ordinal += 1;
    }
    var index: usize = 0;
    while (index < request.context.items.len) switch (request.context.items[index]) {
        .user_message => |message| {
            try writeTextMessage(json, "user", message.text, cacheAt(options, plan, ordinal), options.cache_ttl);
            ordinal += 1;
            index += 1;
        },
        .assistant_message, .tool_call, .reasoning => {
            const run = try inspectAssistantRun(allocator, request, options, index);
            if (run.emit) {
                try writeAssistantRun(allocator, json, request, options, index, run, cacheAt(options, plan, ordinal));
                ordinal += 1;
            }
            index = run.end;
        },
        .tool_result => {
            const first = index;
            var has_images = false;
            while (index < request.context.items.len and request.context.items[index] == .tool_result) : (index += 1) {
                const result = request.context.items[index].tool_result;
                has_images = has_images or result.images.len != 0;
                try writeToolResult(
                    json,
                    result,
                    request.context.image_input,
                    cacheAt(options, plan, ordinal),
                    options.cache_ttl,
                );
                ordinal += 1;
            }
            if (has_images and request.context.image_input != .unsupported) {
                try writeImageFollowup(
                    json,
                    request.context.items[first..index],
                    cacheAt(options, plan, ordinal),
                    options.cache_ttl,
                );
                ordinal += 1;
            }
        },
        .turn_boundary, .turn_usage => index += 1,
    };
    try json.endArray();
}

fn cacheAt(options: Options, plan: MessagePlan, ordinal: usize) bool {
    if (!options.cache_markers) return false;
    return (plan.has_system and ordinal == 0) or
        (plan.tail_cacheable != null and plan.tail_cacheable.? == ordinal);
}

fn writeTextMessage(json: *std.json.Stringify, role: []const u8, text: []const u8, cache: bool, ttl: []const u8) !void {
    try json.beginObject();
    try field(json, "role", role);
    try json.objectField("content");
    if (!cache) {
        try json.write(text);
    } else {
        try json.beginArray();
        try json.beginObject();
        try field(json, "type", "text");
        try field(json, "text", text);
        try writeCacheControl(json, ttl);
        try json.endObject();
        try json.endArray();
    }
    try json.endObject();
}

fn writeAssistantRun(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    request: Provider.Request,
    options: Options,
    first: usize,
    run: AssistantRun,
    cache: bool,
) !void {
    try json.beginObject();
    try field(json, "role", "assistant");
    try json.objectField("content");
    if (!run.content) {
        try json.write(null);
    } else if (!cache) {
        try writeAssistantText(json, request.context.items[first..run.end]);
    } else {
        try json.beginArray();
        try json.beginObject();
        try field(json, "type", "text");
        try json.objectField("text");
        try writeAssistantText(json, request.context.items[first..run.end]);
        try writeCacheControl(json, options.cache_ttl);
        try json.endObject();
        try json.endArray();
    }

    var has_calls = false;
    for (request.context.items[first..run.end]) |item| {
        if (item == .tool_call) has_calls = true;
    }
    if (has_calls) {
        try json.objectField("tool_calls");
        try json.beginArray();
        for (request.context.items[first..run.end]) |item| {
            if (item == .tool_call) try writeToolCall(json, item.tool_call);
        }
        try json.endArray();
    }
    if (run.details) {
        try json.objectField("reasoning_details");
        try json.beginArray();
        for (request.context.items[first..run.end]) |item| if (item == .reasoning and
            reasoningMatches(item.reasoning, options.provider_id, request.model))
        {
            try appendReasoningArray(allocator, json, item.reasoning.opaque_json);
        };
        try json.endArray();
    } else if (options.reasoning_field) |name| {
        var any = false;
        for (request.context.items[first..run.end]) |item| {
            if (item == .reasoning and
                reasoningMatches(item.reasoning, options.provider_id, request.model) and
                item.reasoning.text != null and item.reasoning.text.?.len != 0) any = true;
        }
        if (any) {
            try json.objectField(name);
            try writeReasoningText(json, request.context.items[first..run.end], options.provider_id, request.model);
        }
    }
    try json.endObject();
}

fn writeAssistantText(json: *std.json.Stringify, items: []const Item.Item) !void {
    try json.beginWriteRaw();
    try json.writer.writeByte('"');
    for (items) |item| if (item == .assistant_message)
        try std.json.Stringify.encodeJsonStringChars(item.assistant_message.text, .{}, json.writer);
    try json.writer.writeByte('"');
    json.endWriteRaw();
}

fn writeReasoningText(
    json: *std.json.Stringify,
    items: []const Item.Item,
    provider_id: []const u8,
    model: []const u8,
) !void {
    try json.beginWriteRaw();
    try json.writer.writeByte('"');
    var wrote = false;
    for (items) |item| if (item == .reasoning and reasoningMatches(item.reasoning, provider_id, model)) {
        const text = item.reasoning.text orelse continue;
        if (text.len == 0) continue;
        if (wrote) try json.writer.writeAll("\\n");
        try std.json.Stringify.encodeJsonStringChars(text, .{}, json.writer);
        wrote = true;
    };
    try json.writer.writeByte('"');
    json.endWriteRaw();
}

fn writeToolCall(json: *std.json.Stringify, call: Item.ToolCall) !void {
    try json.beginObject();
    try field(json, "id", call.id);
    try field(json, "type", "function");
    try json.objectField("function");
    try json.beginObject();
    try field(json, "name", call.name);
    try field(json, "arguments", call.arguments_json);
    try json.endObject();
    try json.endObject();
}

fn writeToolResult(
    json: *std.json.Stringify,
    result: Item.ToolResult,
    image_input: Provider.ImageInput,
    cache: bool,
    ttl: []const u8,
) !void {
    try json.beginObject();
    try field(json, "role", "tool");
    try field(json, "tool_call_id", result.call_id);
    try json.objectField("content");
    if (cache) {
        try json.beginArray();
        try json.beginObject();
        try field(json, "type", "text");
        try json.objectField("text");
        try writeToolResultText(json, result, image_input);
        try writeCacheControl(json, ttl);
        try json.endObject();
        try json.endArray();
    } else try writeToolResultText(json, result, image_input);
    try json.endObject();
}

fn writeToolResultText(json: *std.json.Stringify, result: Item.ToolResult, image_input: Provider.ImageInput) !void {
    try json.beginWriteRaw();
    try json.writer.writeByte('"');
    try std.json.Stringify.encodeJsonStringChars(result.output, .{}, json.writer);
    var wrote = result.output.len != 0;
    if (image_input == .unsupported) for (result.images) |image| {
        if (wrote) try json.writer.writeAll("\\n");
        try writeImagePlaceholderChars(json.writer, image);
        wrote = true;
    };
    try json.writer.writeByte('"');
    json.endWriteRaw();
}

fn writeImageFollowup(
    json: *std.json.Stringify,
    items: []const Item.Item,
    cache: bool,
    ttl: []const u8,
) !void {
    try json.beginObject();
    try field(json, "role", "user");
    try json.objectField("content");
    try json.beginArray();
    try json.beginObject();
    try field(json, "type", "text");
    try field(json, "text", "Image(s) from the preceding tool result(s):");
    try json.endObject();
    var last_image: ?struct { item: usize, image: usize } = null;
    for (items, 0..) |item, item_index| {
        for (item.tool_result.images, 0..) |_, image_index| {
            last_image = .{ .item = item_index, .image = image_index };
        }
    }
    for (items, 0..) |item, item_index| for (item.tool_result.images, 0..) |image, image_index| {
        try json.beginObject();
        try field(json, "type", "image_url");
        try json.objectField("image_url");
        try json.beginObject();
        try json.objectField("url");
        try writeDataUri(json, image);
        try json.endObject();
        if (cache and last_image.?.item == item_index and last_image.?.image == image_index)
            try writeCacheControl(json, ttl);
        try json.endObject();
    };
    try json.endArray();
    try json.endObject();
}

fn writeDataUri(json: *std.json.Stringify, image: Item.Image) !void {
    try json.beginWriteRaw();
    try json.writer.writeByte('"');
    try json.writer.writeAll("data:");
    try std.json.Stringify.encodeJsonStringChars(image.mime, .{}, json.writer);
    try json.writer.writeAll(";base64,");
    try std.json.Stringify.encodeJsonStringChars(image.data_base64, .{}, json.writer);
    try json.writer.writeByte('"');
    json.endWriteRaw();
}

fn writeImagePlaceholderChars(writer: *std.Io.Writer, image: Item.Image) !void {
    const decoded_bytes = image.data_base64.len / 4 * 3;
    try writer.writeAll("[image: ");
    try std.json.Stringify.encodeJsonStringChars(image.mime, .{}, writer);
    if ((image.width orelse 0) > 0 and (image.height orelse 0) > 0)
        try writer.print(", {d}x{d}", .{ image.width.?, image.height.? });
    if (decoded_bytes >= 1024 * 1024) {
        try writer.print(", {d:.1} MiB]", .{@as(f64, @floatFromInt(decoded_bytes)) / (1024 * 1024)});
    } else if (decoded_bytes >= 1024) {
        try writer.print(", {d:.1} KiB]", .{@as(f64, @floatFromInt(decoded_bytes)) / 1024});
    } else try writer.print(", {d} bytes]", .{decoded_bytes});
}

fn writeCacheControl(json: *std.json.Stringify, ttl: []const u8) !void {
    try json.objectField("cache_control");
    try json.beginObject();
    try field(json, "type", "ephemeral");
    if (std.ascii.eqlIgnoreCase(ttl, "1h")) try field(json, "ttl", "1h");
    try json.endObject();
}

fn reasoningHasArray(allocator: std.mem.Allocator, bytes: ?[]const u8) error{OutOfMemory}!bool {
    const source = bytes orelse return false;
    validateJsonLimits(source) catch return false;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, source, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer parsed.deinit();
    return parsed.value == .array;
}

fn appendReasoningArray(allocator: std.mem.Allocator, json: *std.json.Stringify, bytes: ?[]const u8) !void {
    const source = bytes orelse return;
    validateJsonLimits(source) catch return;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, source, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer parsed.deinit();
    if (parsed.value != .array) return;
    for (parsed.value.array.items) |value| try json.write(value);
}

fn reasoningMatches(reasoning: Item.Reasoning, provider_id: []const u8, model: []const u8) bool {
    const source = reasoning.source orelse return false;
    const provider = source.provider orelse return false;
    const source_model = source.model orelse return false;
    return std.mem.eql(u8, canonicalProvider(provider), canonicalProvider(provider_id)) and
        std.mem.eql(u8, source_model, model);
}

fn canonicalProvider(provider: []const u8) []const u8 {
    return if (std.mem.eql(u8, provider, "llama.cpp")) "llamacpp" else provider;
}

fn writeTools(json: *std.json.Stringify, tools: []const Provider.ToolDefinition) !void {
    try json.beginArray();
    for (tools) |tool| {
        try json.beginObject();
        try field(json, "type", "function");
        try json.objectField("function");
        try json.beginObject();
        try field(json, "name", tool.name);
        try field(json, "description", tool.description);
        try json.objectField("parameters");
        try json.beginObject();
        try field(json, "type", "object");
        try json.objectField("properties");
        try json.beginObject();
        for (tool.parameters) |parameter| {
            try json.objectField(parameter.name);
            try json.beginObject();
            try field(json, "type", @tagName(parameter.type));
            if (parameter.item_type) |item_type| {
                try json.objectField("items");
                try json.beginObject();
                try field(json, "type", @tagName(item_type));
                try json.endObject();
            }
            try field(json, "description", parameter.description);
            if (parameter.minimum != 0) try field(json, "minimum", parameter.minimum);
            try json.endObject();
        }
        try json.endObject();
        var required = false;
        for (tool.parameters) |parameter| required = required or parameter.required;
        if (required) {
            try json.objectField("required");
            try json.beginArray();
            for (tool.parameters) |parameter| if (parameter.required) try json.write(parameter.name);
            try json.endArray();
        }
        try json.endObject();
        try json.endObject();
        try json.endObject();
    }
    try json.endArray();
}

fn mutable(bytes: []const u8) []u8 {
    return @constCast(bytes);
}

fn requestWith(items: []const Item.Item) Provider.Request {
    return .{ .model = "m1", .context = .{ .system_prompt = "sys", .items = items, .tools = &.{} } };
}

test "groups assistant runs and consecutive tool results with image followup" {
    var images = [_]Item.Image{.{ .mime = mutable("image/png"), .data_base64 = mutable("QUJD") }};
    const items = [_]Item.Item{
        .{ .reasoning = .{ .text = mutable("think"), .source = .{ .provider = "openai", .model = "m1" } } },
        .{ .assistant_message = .{ .text = mutable("answer") } },
        .{ .tool_call = .{ .id = mutable("c1"), .name = mutable("read"), .arguments_json = mutable("{}") } },
        .{ .tool_result = .{ .call_id = mutable("c1"), .output = mutable("done"), .images = &images } },
        .{ .tool_result = .{ .call_id = mutable("c2"), .output = mutable("two") } },
    };
    const body = try build(std.testing.allocator, requestWith(&items), .{ .reasoning_field = "reasoning_content" });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":\"answer\",\"tool_calls\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_content\":\"think\"") != null);
    const c1 = std.mem.indexOf(u8, body, "\"tool_call_id\":\"c1\"").?;
    const c2 = std.mem.indexOf(u8, body, "\"tool_call_id\":\"c2\"").?;
    const image = std.mem.indexOf(u8, body, "Image(s) from the preceding tool result(s):").?;
    try std.testing.expect(c1 < c2 and c2 < image);
}

test "typed reasoning arrays concatenate and supersede plain reasoning" {
    const items = [_]Item.Item{
        .{ .reasoning = .{
            .opaque_json = mutable("[{\"data\":\"a\"}]"),
            .text = mutable("plain"),
            .source = .{ .provider = "openai", .model = "m1" },
        } },
        .{ .reasoning = .{
            .opaque_json = mutable("[{\"data\":\"b\"}]"),
            .source = .{ .provider = "openai", .model = "m1" },
        } },
    };
    const body = try build(std.testing.allocator, requestWith(&items), .{ .reasoning_field = "reasoning" });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(
        u8,
        body,
        "\"reasoning_details\":[{\"data\":\"a\"},{\"data\":\"b\"}]",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning\":\"plain\"") == null);
}

test "cache markers, nested tools, options, and recursive extra body" {
    const parameters = [_]Provider.ToolParameter{.{
        .name = "path",
        .type = .string,
        .description = "file",
        .required = true,
    }};
    const tools = [_]Provider.ToolDefinition{.{ .name = "read", .description = "read", .parameters = &parameters }};
    var request = requestWith(&.{.{ .user_message = .{ .text = mutable("hi") } }});
    request.context.tools = &tools;
    request.context.effort = "high";
    const body = try build(std.testing.allocator, request, .{
        .reasoning_format = .nested,
        .cache_markers = true,
        .cache_ttl = "1h",
        .prompt_cache_key = "session",
        .emit_progress = true,
        .request_cost = true,
        .extra_body_json = "{\"reasoning\":{\"budget\":7},\"usage\":{\"details\":true},\"temperature\":0}",
    });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"function\":{\"name\":\"read\"") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        body,
        "\"cache_control\":{\"type\":\"ephemeral\",\"ttl\":\"1h\"}",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        body,
        "\"reasoning\":{\"enabled\":true,\"effort\":\"high\",\"budget\":7}",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"usage\":{\"include\":true,\"details\":true}") != null);
}

test "unsupported images become placeholders and reserved extra members fail" {
    var images = [_]Item.Image{.{
        .mime = mutable("image/png"),
        .data_base64 = mutable("QUJD"),
        .width = 4,
        .height = 2,
    }};
    const items = [_]Item.Item{.{ .tool_result = .{
        .call_id = mutable("c"),
        .output = mutable("out"),
        .images = &images,
    } }};
    var request = requestWith(&items);
    request.context.image_input = .unsupported;
    const body = try build(std.testing.allocator, request, .{});
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "out\\n[image: image/png, 4x2, 3 bytes]") != null);
    try std.testing.expectError(error.InvalidRequest, build(
        std.testing.allocator,
        request,
        .{ .extra_body_json = "{\"model\":\"bad\"}" },
    ));
}

test "body bound, JSON limits, and allocation failures" {
    const request = requestWith(&.{});
    const body = try build(std.testing.allocator, request, .{});
    const length = body.len;
    std.testing.allocator.free(body);
    const exact = try build(std.testing.allocator, request, .{ .maximum_body_bytes = length });
    std.testing.allocator.free(exact);
    try std.testing.expectError(error.BodyTooLarge, build(
        std.testing.allocator,
        request,
        .{ .maximum_body_bytes = length - 1 },
    ));
    try std.testing.expectError(error.InvalidRequest, build(
        std.testing.allocator,
        request,
        .{ .extra_body_json = "[]" },
    ));
}

fn exerciseAllocationFailures(allocator: std.mem.Allocator) !void {
    const items = [_]Item.Item{.{ .reasoning = .{
        .opaque_json = mutable("[{\"type\":\"reasoning\",\"data\":\"x\"}]"),
        .source = .{ .provider = "openai", .model = "m1" },
    } }};
    const body = try build(allocator, requestWith(&items), .{ .extra_body_json = "{\"metadata\":{\"a\":1}}" });
    allocator.free(body);
}

test "builder frees partial allocations after OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseAllocationFailures, .{});
}

test "invalid hard body maximum is rejected before extra JSON allocation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.InvalidRequest, build(
        failing.allocator(),
        requestWith(&.{}),
        .{
            .maximum_body_bytes = default_maximum_body_bytes + 1,
            .extra_body_json = "{\"custom\":true}",
        },
    ));
}

test "unsupported image placeholders remain newline separated without text" {
    var images = [_]Item.Image{
        .{ .mime = mutable("image/png"), .data_base64 = mutable("QUJD") },
        .{ .mime = mutable("image/jpeg"), .data_base64 = mutable("REVG") },
    };
    const items = [_]Item.Item{.{ .tool_result = .{
        .call_id = mutable("c"),
        .output = mutable(""),
        .images = &images,
    } }};
    var request = requestWith(&items);
    request.context.image_input = .unsupported;
    const body = try build(std.testing.allocator, request, .{});
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.find(
        u8,
        body,
        "[image: image/png, 3 bytes]\\n[image: image/jpeg, 3 bytes]",
    ) != null);
}
