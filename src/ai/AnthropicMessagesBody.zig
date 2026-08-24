const std = @import("std");
const Item = @import("Item.zig");
const Provider = @import("Provider.zig");

pub const default_maximum_body_bytes: usize = 32 * 1024 * 1024;
pub const maximum_json_depth: usize = 64;
pub const maximum_json_fields: usize = 4096;
pub const maximum_json_work: usize = 65_536;
pub const maximum_request_items: usize = 65_536;
pub const maximum_request_tools: usize = 1_024;
pub const maximum_tool_parameters: usize = 4_096;
pub const maximum_request_images: usize = 20;

pub const ThinkingMode = enum { adaptive, budget, off };

pub const Options = struct {
    provider_id: []const u8 = "anthropic",
    max_tokens: u32 = 32_000,
    thinking_mode: ThinkingMode = .budget,
    thinking_budget: ?u32 = null,
    show_reasoning: bool = false,
    allow_empty_signature: bool = false,
    cache_markers: bool = false,
    cache_ttl: []const u8 = "1h",
    /// A borrowed JSON object. Protocol-owned members are rejected.
    extra_body_json: ?[]const u8 = null,
    maximum_body_bytes: usize = default_maximum_body_bytes,
};

pub const Error = error{ OutOfMemory, InvalidRequest, BodyTooLarge };

/// Returns compact JSON owned by `allocator`. Request and option data is borrowed.
pub fn build(allocator: std.mem.Allocator, request: Provider.Request, options: Options) Error![]u8 {
    if (options.maximum_body_bytes == 0 or options.maximum_body_bytes > default_maximum_body_bytes) {
        return error.InvalidRequest;
    }
    try preflightRequestWork(request, options);
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

const reserved_members = [_][]const u8{
    "model", "stream", "messages", "input", "include", "n", "system", "tools", "stream_options", "instructions",
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

fn validateJsonLimits(bytes: []const u8) Error!void {
    var depth: usize = 0;
    var fields: usize = 0;
    var work: usize = 0;
    var in_string = false;
    var escaped = false;
    for (bytes) |byte| {
        if (in_string) {
            if (escaped) escaped = false else if (byte == '\\') escaped = true else if (byte == '"') in_string = false;
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

fn preflightRequestWork(request: Provider.Request, options: Options) Error!void {
    if (request.context.items.len > maximum_request_items or
        request.context.tools.len > maximum_request_tools)
    {
        return error.BodyTooLarge;
    }
    var bytes: usize = 0;
    var json_work: usize = 0;
    var json_fields: usize = 0;
    var parameters: usize = 0;
    var images: usize = 0;
    try accountBytes(&bytes, request.model.len, options.maximum_body_bytes);
    try accountBytes(&bytes, options.provider_id.len, options.maximum_body_bytes);
    try accountBytes(&bytes, request.context.system_prompt.len, options.maximum_body_bytes);
    try accountBytes(&bytes, options.cache_ttl.len, options.maximum_body_bytes);
    if (request.context.effort) |effort| try accountBytes(&bytes, effort.len, options.maximum_body_bytes);
    for (request.context.items) |item| switch (item) {
        .user_message => |message| try accountBytes(&bytes, message.text.len, options.maximum_body_bytes),
        .assistant_message => |message| try accountBytes(&bytes, message.text.len, options.maximum_body_bytes),
        .tool_call => |call| {
            try accountBytes(&bytes, call.id.len, options.maximum_body_bytes);
            try accountBytes(&bytes, call.name.len, options.maximum_body_bytes);
            try accountBytes(&bytes, call.arguments_json.len, options.maximum_body_bytes);
            try accountJsonWork(&json_work, &json_fields, call.arguments_json);
        },
        .tool_result => |result| {
            try accountBytes(&bytes, result.call_id.len, options.maximum_body_bytes);
            try accountBytes(&bytes, result.output.len, options.maximum_body_bytes);
            images = std.math.add(usize, images, result.images.len) catch return error.BodyTooLarge;
            if (images > maximum_request_images) return error.BodyTooLarge;
            for (result.images) |image| {
                try accountBytes(&bytes, image.mime.len, options.maximum_body_bytes);
                try accountBytes(&bytes, image.data_base64.len, options.maximum_body_bytes);
            }
        },
        .reasoning => |reasoning| if (reasoningMatches(reasoning, options.provider_id, request.model)) {
            const opaque_json = reasoning.opaque_json.?;
            try accountBytes(&bytes, opaque_json.len, options.maximum_body_bytes);
            try accountJsonWork(&json_work, &json_fields, opaque_json);
        },
        .turn_boundary, .turn_usage => {},
    };
    for (request.context.tools) |tool| {
        try accountBytes(&bytes, tool.name.len, options.maximum_body_bytes);
        try accountBytes(&bytes, tool.description.len, options.maximum_body_bytes);
        parameters = std.math.add(usize, parameters, tool.parameters.len) catch return error.BodyTooLarge;
        if (parameters > maximum_tool_parameters) return error.BodyTooLarge;
        for (tool.parameters) |parameter| {
            try accountBytes(&bytes, parameter.name.len, options.maximum_body_bytes);
            try accountBytes(&bytes, parameter.description.len, options.maximum_body_bytes);
        }
    }
}

fn accountBytes(total: *usize, count: usize, maximum: usize) Error!void {
    total.* = std.math.add(usize, total.*, count) catch return error.BodyTooLarge;
    if (total.* > maximum) return error.BodyTooLarge;
}

fn accountJsonWork(total: *usize, fields: *usize, bytes: []const u8) Error!void {
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    for (bytes) |byte| {
        if (in_string) {
            if (escaped) escaped = false else if (byte == '\\') escaped = true else if (byte == '"') in_string = false;
            continue;
        }
        const added: usize = switch (byte) {
            '"' => blk: {
                in_string = true;
                break :blk 0;
            },
            '{', '[' => blk: {
                depth += 1;
                if (depth > maximum_json_depth) return error.InvalidRequest;
                break :blk 1;
            },
            '}', ']' => blk: {
                if (depth > 0) depth -= 1;
                break :blk 0;
            },
            ':' => blk: {
                fields.* = std.math.add(usize, fields.*, 1) catch return error.BodyTooLarge;
                if (fields.* > maximum_json_fields) return error.BodyTooLarge;
                break :blk 1;
            },
            ',' => 1,
            else => 0,
        };
        total.* = std.math.add(usize, total.*, added) catch return error.BodyTooLarge;
        if (total.* > maximum_json_work) return error.BodyTooLarge;
    }
}

fn validateRequest(request: Provider.Request, options: Options) Error!void {
    if (request.model.len == 0 or options.provider_id.len == 0 or options.max_tokens == 0) return error.InvalidRequest;
    try textField(request.model, options.maximum_body_bytes, true);
    try textField(options.provider_id, options.maximum_body_bytes, true);
    try textField(request.context.system_prompt, options.maximum_body_bytes, false);
    try textField(options.cache_ttl, options.maximum_body_bytes, true);
    if (!std.ascii.eqlIgnoreCase(options.cache_ttl, "1h") and
        !std.ascii.eqlIgnoreCase(options.cache_ttl, "5m")) return error.InvalidRequest;
    if (request.context.effort) |effort| try textField(effort, options.maximum_body_bytes, false);

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
        .reasoning => |reasoning| if (reasoningMatches(reasoning, options.provider_id, request.model)) {
            const opaque_json = reasoning.opaque_json.?;
            if (opaque_json.len > options.maximum_body_bytes) return error.BodyTooLarge;
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
    try json.objectField("max_tokens");
    if (extraValue(extra, "max_tokens")) |value| try json.write(value.*) else try json.write(options.max_tokens);
    try field(&json, "stream", true);
    try json.objectField("messages");
    try writeMessages(allocator, &json, request, options);

    if (request.context.system_prompt.len != 0) {
        try json.objectField("system");
        try json.beginArray();
        try json.beginObject();
        try field(&json, "type", "text");
        try field(&json, "text", request.context.system_prompt);
        if (options.cache_markers) try writeCacheControl(&json, options.cache_ttl);
        try json.endObject();
        try json.endArray();
    }
    if (request.context.tools.len != 0) {
        try json.objectField("tools");
        try writeTools(&json, request.context.tools, options);
    }
    try writeThinking(&json, request, options, extra);
    try writeExtraFields(&json, extra);
    try json.endObject();
}

fn writeThinking(
    json: *std.json.Stringify,
    request: Provider.Request,
    options: Options,
    extra: ?*const std.json.Value,
) !void {
    switch (options.thinking_mode) {
        .off => {
            if (extraValue(extra, "thinking")) |value| {
                try json.objectField("thinking");
                try json.write(value.*);
            }
            if (extraValue(extra, "output_config")) |value| {
                try json.objectField("output_config");
                try json.write(value.*);
            }
        },
        .adaptive => {
            try json.objectField("thinking");
            try writeMergedObject(json, &.{
                .{ "type", .{ .string = "adaptive" } },
                .{ "display", .{ .string = if (options.show_reasoning) "summarized" else "omitted" } },
            }, extraValue(extra, "thinking"));
            if (request.context.effort) |effort| {
                if (effort.len != 0) {
                    try json.objectField("output_config");
                    try writeMergedObject(
                        json,
                        &.{.{ "effort", .{ .string = effort } }},
                        extraValue(extra, "output_config"),
                    );
                } else if (extraValue(extra, "output_config")) |value| {
                    try json.objectField("output_config");
                    try json.write(value.*);
                }
            } else if (extraValue(extra, "output_config")) |value| {
                try json.objectField("output_config");
                try json.write(value.*);
            }
        },
        .budget => {
            if (options.max_tokens >= 2) {
                const requested = options.thinking_budget orelse options.max_tokens - 1;
                const budget = if (requested == 0 or requested >= options.max_tokens)
                    options.max_tokens - 1
                else
                    requested;
                try json.objectField("thinking");
                try writeMergedObject(json, &.{
                    .{ "type", .{ .string = "enabled" } },
                    .{ "budget_tokens", .{ .integer = budget } },
                }, extraValue(extra, "thinking"));
            } else if (extraValue(extra, "thinking")) |value| {
                try json.objectField("thinking");
                try json.write(value.*);
            }
            if (extraValue(extra, "output_config")) |value| {
                try json.objectField("output_config");
                try json.write(value.*);
            }
        },
    }
}

const GeneratedField = struct { []const u8, std.json.Value };

fn writeMergedObject(
    json: *std.json.Stringify,
    generated: []const GeneratedField,
    override: ?*const std.json.Value,
) !void {
    if (override) |value| if (value.* != .object) {
        try json.write(value.*);
        return;
    };
    try json.beginObject();
    for (generated) |entry| {
        try json.objectField(entry[0]);
        if (override) |value| if (value.object.getPtr(entry[0])) |replacement| {
            if (entry[1] == .object and replacement.* == .object) {
                try writeMergedValue(json, &entry[1], replacement);
            } else {
                try json.write(replacement.*);
            }
            continue;
        };
        try json.write(entry[1]);
    }
    if (override) |value| {
        var iterator = value.object.iterator();
        while (iterator.next()) |entry| {
            var generated_name = false;
            for (generated) |base| if (std.mem.eql(u8, base[0], entry.key_ptr.*)) {
                generated_name = true;
            };
            if (generated_name) continue;
            try json.objectField(entry.key_ptr.*);
            try json.write(entry.value_ptr.*);
        }
    }
    try json.endObject();
}

fn writeMergedValue(json: *std.json.Stringify, base: *const std.json.Value, extra: *const std.json.Value) !void {
    if (base.* != .object or extra.* != .object) {
        try json.write(extra.*);
        return;
    }
    try json.beginObject();
    var base_iterator = base.object.iterator();
    while (base_iterator.next()) |entry| {
        try json.objectField(entry.key_ptr.*);
        if (extra.object.getPtr(entry.key_ptr.*)) |replacement| {
            try writeMergedValue(json, entry.value_ptr, replacement);
        } else {
            try json.write(entry.value_ptr.*);
        }
    }
    var extra_iterator = extra.object.iterator();
    while (extra_iterator.next()) |entry| {
        if (base.object.contains(entry.key_ptr.*)) continue;
        try json.objectField(entry.key_ptr.*);
        try json.write(entry.value_ptr.*);
    }
    try json.endObject();
}

fn writeExtraFields(json: *std.json.Stringify, extra: ?*const std.json.Value) !void {
    const value = extra orelse return;
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "max_tokens") or
            std.mem.eql(u8, entry.key_ptr.*, "thinking") or
            std.mem.eql(u8, entry.key_ptr.*, "output_config")) continue;
        try json.objectField(entry.key_ptr.*);
        try json.write(entry.value_ptr.*);
    }
}

fn extraValue(extra: ?*const std.json.Value, name: []const u8) ?*const std.json.Value {
    const value = extra orelse return null;
    return value.object.getPtr(name);
}

fn field(json: *std.json.Stringify, name: []const u8, value: anytype) !void {
    try json.objectField(name);
    try json.write(value);
}

const MessagePlan = struct {
    count: usize = 0,
    tail_message: ?usize = null,
    tail_block_kind: BlockKind = .other,
};

const BlockKind = enum { thinking, redacted_thinking, other };

fn planMessages(allocator: std.mem.Allocator, request: Provider.Request, options: Options) !MessagePlan {
    var plan: MessagePlan = .{};
    var index: usize = 0;
    while (index < request.context.items.len) switch (request.context.items[index]) {
        .user_message => {
            plan.tail_message = plan.count;
            plan.tail_block_kind = .other;
            plan.count += 1;
            index += 1;
        },
        .assistant_message, .tool_call, .reasoning => {
            const run = try inspectAssistantRun(allocator, request, options, index);
            if (run.block_count != 0) {
                plan.tail_message = plan.count;
                plan.tail_block_kind = run.last_kind;
                plan.count += 1;
            }
            index = run.end;
        },
        .tool_result => {
            while (index < request.context.items.len and request.context.items[index] == .tool_result) : (index += 1) {}
            plan.tail_message = plan.count;
            plan.tail_block_kind = .other;
            plan.count += 1;
        },
        .turn_boundary, .turn_usage => index += 1,
    };
    return plan;
}

const AssistantRun = struct { end: usize, block_count: usize, last_kind: BlockKind };

fn inspectAssistantRun(
    allocator: std.mem.Allocator,
    request: Provider.Request,
    options: Options,
    first: usize,
) !AssistantRun {
    var result: AssistantRun = .{ .end = first, .block_count = 0, .last_kind = .other };
    while (result.end < request.context.items.len) : (result.end += 1) switch (request.context.items[result.end]) {
        .assistant_message => |message| if (message.text.len != 0) {
            result.block_count += 1;
            result.last_kind = .other;
        },
        .tool_call => {
            result.block_count += 1;
            result.last_kind = .other;
        },
        .reasoning => |reasoning| if (reasoningMatches(reasoning, options.provider_id, request.model)) {
            if (try inspectReasoning(allocator, reasoning.opaque_json.?, options.allow_empty_signature)) |block| {
                result.block_count += 1;
                result.last_kind = block;
            }
        },
        else => break,
    };
    return result;
}

fn inspectReasoning(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    allow_empty_signature: bool,
) error{OutOfMemory}!?BlockKind {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const type_value = parsed.value.object.get("type") orelse return .other;
    if (type_value != .string) return .other;
    if (std.mem.eql(u8, type_value.string, "redacted_thinking")) return .redacted_thinking;
    if (!std.mem.eql(u8, type_value.string, "thinking")) return .other;
    if (!allow_empty_signature and !hasNonemptyString(&parsed.value.object, "signature")) {
        if (hasNonemptyString(&parsed.value.object, "thinking")) return .other;
        return null;
    }
    return .thinking;
}

fn writeMessages(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    request: Provider.Request,
    options: Options,
) !void {
    const plan = try planMessages(allocator, request, options);
    var ordinal: usize = 0;
    var index: usize = 0;
    try json.beginArray();
    while (index < request.context.items.len) switch (request.context.items[index]) {
        .user_message => |message| {
            try json.beginObject();
            try field(json, "role", "user");
            try json.objectField("content");
            try json.beginArray();
            try writeTextBlock(json, message.text, cacheAt(options, plan, ordinal), options.cache_ttl);
            try json.endArray();
            try json.endObject();
            ordinal += 1;
            index += 1;
        },
        .assistant_message, .tool_call, .reasoning => {
            const run = try inspectAssistantRun(allocator, request, options, index);
            if (run.block_count != 0) {
                try writeAssistantRun(allocator, json, request, options, index, run, cacheAt(options, plan, ordinal));
                ordinal += 1;
            }
            index = run.end;
        },
        .tool_result => {
            try json.beginObject();
            try field(json, "role", "user");
            try json.objectField("content");
            try json.beginArray();
            while (index < request.context.items.len and request.context.items[index] == .tool_result) : (index += 1) {
                const is_last = index + 1 == request.context.items.len or
                    request.context.items[index + 1] != .tool_result;
                try writeToolResult(
                    json,
                    request.context.items[index].tool_result,
                    request.context.image_input,
                    cacheAt(options, plan, ordinal) and is_last,
                    options.cache_ttl,
                );
            }
            try json.endArray();
            try json.endObject();
            ordinal += 1;
        },
        .turn_boundary, .turn_usage => index += 1,
    };
    try json.endArray();
}

fn cacheAt(options: Options, plan: MessagePlan, ordinal: usize) bool {
    if (!options.cache_markers or plan.tail_message != ordinal) return false;
    return plan.tail_block_kind != .thinking and plan.tail_block_kind != .redacted_thinking;
}

fn writeAssistantRun(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    request: Provider.Request,
    options: Options,
    first: usize,
    run: AssistantRun,
    cache_tail: bool,
) !void {
    try json.beginObject();
    try field(json, "role", "assistant");
    try json.objectField("content");
    try json.beginArray();
    var block_ordinal: usize = 0;
    for (request.context.items[first..run.end]) |item| switch (item) {
        .assistant_message => |message| if (message.text.len != 0) {
            block_ordinal += 1;
            try writeTextBlock(json, message.text, cache_tail and block_ordinal == run.block_count, options.cache_ttl);
        },
        .tool_call => |call| {
            block_ordinal += 1;
            try writeToolUse(allocator, json, call, cache_tail and block_ordinal == run.block_count, options.cache_ttl);
        },
        .reasoning => |reasoning| if (reasoningMatches(reasoning, options.provider_id, request.model)) {
            if (try writeReasoning(
                allocator,
                json,
                reasoning.opaque_json.?,
                options.allow_empty_signature,
                cache_tail and block_ordinal + 1 == run.block_count,
                options.cache_ttl,
            )) block_ordinal += 1;
        },
        else => unreachable,
    };
    try json.endArray();
    try json.endObject();
}

fn writeReasoning(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    bytes: []const u8,
    allow_empty_signature: bool,
    cache: bool,
    cache_ttl: []const u8,
) !bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const kind = try inspectParsedReasoning(&parsed.value.object, allow_empty_signature);
    if (kind == null) return false;
    if (kind.? == .other and !allow_empty_signature and
        isStringEqual(&parsed.value.object, "type", "thinking") and
        !hasNonemptyString(&parsed.value.object, "signature"))
    {
        try writeTextBlock(json, parsed.value.object.get("thinking").?.string, cache, cache_ttl);
        return true;
    }
    if (!cache) {
        try json.write(parsed.value);
        return true;
    }
    try json.beginObject();
    var iterator = parsed.value.object.iterator();
    while (iterator.next()) |entry| {
        try json.objectField(entry.key_ptr.*);
        try json.write(entry.value_ptr.*);
    }
    try writeCacheControl(json, cache_ttl);
    try json.endObject();
    return true;
}

fn inspectParsedReasoning(object: *const std.json.ObjectMap, allow_empty_signature: bool) !?BlockKind {
    const type_value = object.get("type") orelse return .other;
    if (type_value != .string) return .other;
    if (std.mem.eql(u8, type_value.string, "redacted_thinking")) return .redacted_thinking;
    if (!std.mem.eql(u8, type_value.string, "thinking")) return .other;
    if (!allow_empty_signature and !hasNonemptyString(object, "signature")) {
        if (hasNonemptyString(object, "thinking")) return .other;
        return null;
    }
    return .thinking;
}

fn hasNonemptyString(object: *const std.json.ObjectMap, name: []const u8) bool {
    const value = object.get(name) orelse return false;
    return value == .string and value.string.len != 0;
}

fn isStringEqual(object: *const std.json.ObjectMap, name: []const u8, expected: []const u8) bool {
    const value = object.get(name) orelse return false;
    return value == .string and std.mem.eql(u8, value.string, expected);
}

fn writeToolUse(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    call: Item.ToolCall,
    cache: bool,
    cache_ttl: []const u8,
) !void {
    var input = std.json.parseFromSlice(std.json.Value, allocator, call.arguments_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    defer if (input) |*parsed| parsed.deinit();
    try json.beginObject();
    try field(json, "type", "tool_use");
    try field(json, "id", call.id);
    try field(json, "name", call.name);
    try json.objectField("input");
    if (input) |parsed| {
        if (parsed.value == .object) try json.write(parsed.value) else try writeEmptyObject(json);
    } else try writeEmptyObject(json);
    if (cache) try writeCacheControl(json, cache_ttl);
    try json.endObject();
}

fn writeEmptyObject(json: *std.json.Stringify) !void {
    try json.beginObject();
    try json.endObject();
}

fn writeToolResult(
    json: *std.json.Stringify,
    result: Item.ToolResult,
    image_input: Provider.ImageInput,
    cache: bool,
    cache_ttl: []const u8,
) !void {
    try json.beginObject();
    try field(json, "type", "tool_result");
    try field(json, "tool_use_id", result.call_id);
    try json.objectField("content");
    if (result.images.len == 0) {
        try json.write(result.output);
    } else {
        try json.beginArray();
        if (result.output.len != 0) try writeTextBlock(json, result.output, false, cache_ttl);
        for (result.images) |image| {
            if (image_input != .unsupported)
                try writeImageBlock(json, image)
            else
                try writeImagePlaceholder(json, image);
        }
        try json.endArray();
    }
    if (cache) try writeCacheControl(json, cache_ttl);
    try json.endObject();
}

fn writeTextBlock(json: *std.json.Stringify, text: []const u8, cache: bool, cache_ttl: []const u8) !void {
    try json.beginObject();
    try field(json, "type", "text");
    try field(json, "text", text);
    if (cache) try writeCacheControl(json, cache_ttl);
    try json.endObject();
}

fn writeImageBlock(json: *std.json.Stringify, image: Item.Image) !void {
    try json.beginObject();
    try field(json, "type", "image");
    try json.objectField("source");
    try json.beginObject();
    try field(json, "type", "base64");
    try field(json, "media_type", image.mime);
    try field(json, "data", image.data_base64);
    try json.endObject();
    try json.endObject();
}

fn writeImagePlaceholder(json: *std.json.Stringify, image: Item.Image) !void {
    const decoded_bytes = image.data_base64.len / 4 * 3;
    try json.beginObject();
    try field(json, "type", "text");
    try json.objectField("text");
    try json.beginWriteRaw();
    try json.writer.writeByte('"');
    try json.writer.writeAll("[image: ");
    try std.json.Stringify.encodeJsonStringChars(image.mime, .{}, json.writer);
    if ((image.width orelse 0) > 0 and (image.height orelse 0) > 0) {
        try json.writer.print(", {d}x{d}", .{ image.width.?, image.height.? });
    }
    if (decoded_bytes >= 1024 * 1024) {
        try json.writer.print(", {d:.1} MiB]", .{@as(f64, @floatFromInt(decoded_bytes)) / (1024 * 1024)});
    } else if (decoded_bytes >= 1024) {
        try json.writer.print(", {d:.1} KiB]", .{@as(f64, @floatFromInt(decoded_bytes)) / 1024});
    } else {
        try json.writer.print(", {d} bytes]", .{decoded_bytes});
    }
    try json.writer.writeByte('"');
    json.endWriteRaw();
    try json.endObject();
}

fn writeCacheControl(json: *std.json.Stringify, ttl: []const u8) !void {
    try json.objectField("cache_control");
    try json.beginObject();
    try field(json, "type", "ephemeral");
    if (std.ascii.eqlIgnoreCase(ttl, "1h")) try field(json, "ttl", "1h");
    try json.endObject();
}

fn writeTools(json: *std.json.Stringify, tools: []const Provider.ToolDefinition, options: Options) !void {
    try json.beginArray();
    for (tools, 0..) |tool, index| {
        try json.beginObject();
        try field(json, "name", tool.name);
        try field(json, "description", tool.description);
        try json.objectField("input_schema");
        try writeSchema(json, tool.parameters);
        if (options.cache_markers and index + 1 == tools.len) try writeCacheControl(json, options.cache_ttl);
        try json.endObject();
    }
    try json.endArray();
}

fn writeSchema(json: *std.json.Stringify, parameters: []const Provider.ToolParameter) !void {
    try json.beginObject();
    try field(json, "type", "object");
    try json.objectField("properties");
    try json.beginObject();
    for (parameters) |parameter| {
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
    var has_required = false;
    for (parameters) |parameter| has_required = has_required or parameter.required;
    if (has_required) {
        try json.objectField("required");
        try json.beginArray();
        for (parameters) |parameter| if (parameter.required) try json.write(parameter.name);
        try json.endArray();
    }
    try json.endObject();
}

fn reasoningMatches(reasoning: Item.Reasoning, provider_id: []const u8, model: []const u8) bool {
    const opaque_json = reasoning.opaque_json orelse return false;
    if (opaque_json.len == 0) return false;
    const source = reasoning.source orelse return false;
    const source_provider = source.provider orelse return false;
    const source_model = source.model orelse return false;
    return std.mem.eql(u8, canonicalProvider(source_provider), canonicalProvider(provider_id)) and
        std.mem.eql(u8, source_model, model);
}

fn canonicalProvider(provider_id: []const u8) []const u8 {
    return if (std.mem.eql(u8, provider_id, "llama.cpp")) "llamacpp" else provider_id;
}

fn mutable(bytes: []const u8) []u8 {
    return @constCast(bytes);
}

fn requestWith(items: []const Item.Item) Provider.Request {
    return .{ .model = "m", .context = .{ .system_prompt = "", .items = items, .tools = &.{} } };
}

test "groups assistant blocks and consecutive tool results" {
    const items = [_]Item.Item{
        .{ .reasoning = .{
            .opaque_json = mutable("{\"type\":\"thinking\",\"thinking\":\"why\",\"signature\":\"S\"}"),
            .source = .{ .provider = "anthropic", .model = "m" },
        } },
        .{ .assistant_message = .{ .text = mutable("done") } },
        .{ .tool_call = .{
            .id = mutable("t"),
            .name = mutable("bash"),
            .arguments_json = mutable("{\"cmd\":\"ls\"}"),
        } },
        .{ .tool_result = .{ .call_id = mutable("t"), .output = mutable("a") } },
        .{ .tool_result = .{ .call_id = mutable("u"), .output = mutable("b") } },
    };
    const body = try build(std.testing.allocator, requestWith(&items), .{ .thinking_mode = .off });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(
        u8,
        body,
        "\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        body,
        "\"role\":\"user\",\"content\":[{\"type\":\"tool_result\"",
    ) != null);
}

test "strict empty signature falls back to text and compatibility replays thinking" {
    const items = [_]Item.Item{.{ .reasoning = .{
        .opaque_json = mutable("{\"type\":\"thinking\",\"thinking\":\"cot\",\"signature\":\"\"}"),
        .source = .{ .provider = "anthropic", .model = "m" },
    } }};
    var body = try build(std.testing.allocator, requestWith(&items), .{ .thinking_mode = .off });
    try std.testing.expect(std.mem.indexOf(u8, body, "{\"type\":\"text\",\"text\":\"cot\"}") != null);
    std.testing.allocator.free(body);
    body = try build(std.testing.allocator, requestWith(&items), .{
        .thinking_mode = .off,
        .allow_empty_signature = true,
    });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"thinking\"") != null);
}

test "provenance mismatch drops reasoning and malformed tool input becomes object" {
    const items = [_]Item.Item{
        .{ .reasoning = .{
            .opaque_json = mutable("{\"type\":\"thinking\",\"thinking\":\"secret\",\"signature\":\"S\"}"),
            .source = .{ .provider = "anthropic", .model = "old" },
        } },
        .{ .tool_call = .{
            .id = mutable("t"),
            .name = mutable("bad"),
            .arguments_json = mutable("not json"),
        } },
    };
    const body = try build(std.testing.allocator, requestWith(&items), .{ .thinking_mode = .off });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"input\":{}") != null);
}

test "unsupported tool images use placeholders and small budget omits generated thinking" {
    var images = [_]Item.Image{.{
        .mime = mutable("image/png"),
        .data_base64 = mutable("QUJD"),
        .width = 4,
        .height = 2,
    }};
    const items = [_]Item.Item{.{ .tool_result = .{
        .call_id = mutable("t"),
        .output = mutable("note"),
        .images = &images,
    } }};
    var request = requestWith(&items);
    request.context.image_input = .unsupported;
    const body = try build(std.testing.allocator, request, .{
        .max_tokens = 1,
        .extra_body_json = "{\"metadata\":{\"source\":\"test\"}}",
    });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "[image: image/png, 4x2, 3 bytes]") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"thinking\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"metadata\":{\"source\":\"test\"}") != null);
}

test "images schema caching thinking and recursive extra match Anthropic shapes" {
    var images = [_]Item.Image{.{
        .mime = mutable("image/png"),
        .data_base64 = mutable("QUJD"),
        .width = 4,
        .height = 2,
    }};
    const items = [_]Item.Item{.{ .tool_result = .{
        .call_id = mutable("t"),
        .output = mutable("note"),
        .images = &images,
    } }};
    const parameters = [_]Provider.ToolParameter{.{
        .name = "path",
        .type = .string,
        .description = "file",
        .required = true,
    }};
    const tools = [_]Provider.ToolDefinition{.{ .name = "read", .description = "read", .parameters = &parameters }};
    var request = requestWith(&items);
    request.context.system_prompt = "system";
    request.context.tools = &tools;
    request.context.effort = "high";
    const body = try build(std.testing.allocator, request, .{
        .thinking_mode = .adaptive,
        .show_reasoning = true,
        .cache_markers = true,
        .extra_body_json = "{\"thinking\":{\"display\":\"omitted\",\"config\":{\"x\":1}},\"temperature\":0}",
    });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(
        u8,
        body,
        "\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"QUJD\"}",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        body,
        "\"input_schema\":{\"type\":\"object\",\"properties\":{\"path\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        body,
        "\"thinking\":{\"type\":\"adaptive\",\"display\":\"omitted\",\"config\":{\"x\":1}}",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"output_config\":{\"effort\":\"high\"}") != null);
}

test "budget clamp tail thinking cache rule and user images ignored" {
    var images = [_]Item.Image{.{ .mime = mutable("bad"), .data_base64 = mutable("SECRET") }};
    const items = [_]Item.Item{
        .{ .user_message = .{ .text = mutable("look"), .images = &images } },
        .{ .reasoning = .{
            .opaque_json = mutable("{\"type\":\"redacted_thinking\",\"data\":\"ENC\"}"),
            .source = .{ .provider = "anthropic", .model = "m" },
        } },
    };
    const body = try build(std.testing.allocator, requestWith(&items), .{
        .max_tokens = 100,
        .thinking_budget = 100,
        .cache_markers = true,
    });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"budget_tokens\":99") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "SECRET") == null);
    const redacted = std.mem.indexOf(u8, body, "\"redacted_thinking\"").?;
    try std.testing.expect(std.mem.indexOf(u8, body[redacted..], "cache_control") == null);
}

fn exerciseAllocationFailures(allocator: std.mem.Allocator) !void {
    const items = [_]Item.Item{
        .{ .reasoning = .{
            .opaque_json = mutable("{\"type\":\"thinking\",\"thinking\":\"x\",\"signature\":\"S\"}"),
            .source = .{ .provider = "anthropic", .model = "m" },
        } },
        .{ .tool_call = .{ .id = mutable("t"), .name = mutable("x"), .arguments_json = mutable("{\"a\":1}") } },
    };
    const body = try build(allocator, requestWith(&items), .{ .extra_body_json = "{\"metadata\":{\"a\":1}}" });
    allocator.free(body);
}

test "bounds validation and all allocation failure paths" {
    const unbounded = try build(std.testing.allocator, requestWith(&.{}), .{});
    const body_length = unbounded.len;
    std.testing.allocator.free(unbounded);
    const exact = try build(std.testing.allocator, requestWith(&.{}), .{
        .maximum_body_bytes = body_length,
    });
    std.testing.allocator.free(exact);
    try std.testing.expectError(
        error.BodyTooLarge,
        build(std.testing.allocator, requestWith(&.{}), .{
            .maximum_body_bytes = body_length - 1,
        }),
    );
    try std.testing.expectError(
        error.InvalidRequest,
        build(std.testing.allocator, requestWith(&.{}), .{ .max_tokens = 0 }),
    );
    try std.testing.expectError(
        error.InvalidRequest,
        build(std.testing.allocator, requestWith(&.{}), .{ .extra_body_json = "{\"model\":\"x\"}" }),
    );
    try std.testing.expectError(
        error.InvalidRequest,
        build(std.testing.allocator, requestWith(&.{}), .{ .extra_body_json = "[]" }),
    );
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseAllocationFailures, .{});
}

test "preflight bounds aggregate body work and nested model JSON" {
    const messages = [_]Item.Item{
        .{ .user_message = .{ .text = mutable("0123456789012345678901234567890123456789") } },
        .{ .assistant_message = .{ .text = mutable("0123456789012345678901234567890123456789") } },
    };
    try std.testing.expectError(error.BodyTooLarge, build(
        std.testing.allocator,
        requestWith(&messages),
        .{ .maximum_body_bytes = 64 },
    ));

    var deep: std.ArrayList(u8) = .empty;
    defer deep.deinit(std.testing.allocator);
    try deep.appendNTimes(std.testing.allocator, '[', maximum_json_depth + 1);
    try deep.appendNTimes(std.testing.allocator, ']', maximum_json_depth + 1);
    const call = [_]Item.Item{.{ .tool_call = .{
        .id = mutable("call"),
        .name = mutable("bash"),
        .arguments_json = deep.items,
    } }};
    try std.testing.expectError(error.InvalidRequest, build(
        std.testing.allocator,
        requestWith(&call),
        .{},
    ));
}

test "request JSON field and structural work thresholds are explicit" {
    var fields: std.ArrayList(u8) = .empty;
    defer fields.deinit(std.testing.allocator);
    try fields.append(std.testing.allocator, '{');
    for (0..maximum_json_fields + 1) |index| {
        if (index != 0) try fields.append(std.testing.allocator, ',');
        try fields.appendSlice(std.testing.allocator, "\"f\":0");
    }
    try fields.append(std.testing.allocator, '}');
    const field_call = [_]Item.Item{.{ .tool_call = .{
        .id = mutable("call"),
        .name = mutable("bash"),
        .arguments_json = fields.items,
    } }};
    try std.testing.expectError(error.BodyTooLarge, build(
        std.testing.allocator,
        requestWith(&field_call),
        .{},
    ));

    var work: std.ArrayList(u8) = .empty;
    defer work.deinit(std.testing.allocator);
    try work.append(std.testing.allocator, '[');
    for (0..maximum_json_work + 1) |index| {
        if (index != 0) try work.append(std.testing.allocator, ',');
        try work.append(std.testing.allocator, '0');
    }
    try work.append(std.testing.allocator, ']');
    const work_call = [_]Item.Item{.{ .tool_call = .{
        .id = mutable("call"),
        .name = mutable("bash"),
        .arguments_json = work.items,
    } }};
    try std.testing.expectError(error.BodyTooLarge, build(
        std.testing.allocator,
        requestWith(&work_call),
        .{},
    ));
}
