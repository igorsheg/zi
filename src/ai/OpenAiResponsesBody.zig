const std = @import("std");
const Item = @import("Item.zig");
const Provider = @import("Provider.zig");

pub const default_maximum_body_bytes: usize = 32 * 1024 * 1024;
pub const maximum_json_depth: usize = 64;
pub const maximum_json_fields: usize = 4096;
pub const maximum_json_work: usize = 65_536;

pub const TextVerbosity = enum { low, medium, high };

pub const Options = struct {
    /// Stable provider id used to gate replay of model-bound opaque reasoning.
    provider_id: []const u8 = "openai",
    prompt_cache_key: ?[]const u8 = null,
    text_verbosity: ?TextVerbosity = null,
    /// A borrowed JSON object. Protocol-owned members are rejected rather than ignored.
    extra_body_json: ?[]const u8 = null,
    maximum_body_bytes: usize = default_maximum_body_bytes,
};

pub const Error = error{
    OutOfMemory,
    InvalidRequest,
    BodyTooLarge,
};

/// Returns compact JSON owned by `allocator`.
///
/// Request data is borrowed. The caller owns and must free the returned slice.
pub fn build(
    allocator: std.mem.Allocator,
    request: Provider.Request,
    options: Options,
) Error![]u8 {
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
    var counting: LimitedCounter = .init(count_buffer[0..buffer_length], options.maximum_body_bytes);
    writeBody(
        allocator,
        &counting.writer,
        request,
        options,
        if (extra) |*value| &value.value else null,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => if (counting.exceeded) return error.BodyTooLarge else unreachable,
    };
    const body_length = counting.fullCount();
    if (body_length > options.maximum_body_bytes) return error.BodyTooLarge;

    const body = try allocator.alloc(u8, body_length);
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
        return .{
            .limit = limit,
            .writer = .{ .vtable = &.{ .drain = drain }, .buffer = buffer },
        };
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
        for (data[0 .. data.len - 1]) |bytes| {
            written = std.math.add(usize, written, bytes.len) catch {
                self.exceeded = true;
                return error.WriteFailed;
            };
        }
        const total = std.math.add(usize, self.count, writer.end) catch {
            self.exceeded = true;
            return error.WriteFailed;
        };
        const final = std.math.add(usize, total, written) catch {
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

fn replayIsContainer(allocator: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}!bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer parsed.deinit();
    return parsed.value == .object or parsed.value == .array;
}

fn validateRequest(request: Provider.Request, options: Options) Error!void {
    if (options.maximum_body_bytes == 0 or
        options.maximum_body_bytes > default_maximum_body_bytes or
        request.model.len == 0 or
        options.provider_id.len == 0) return error.InvalidRequest;
    try bounded(request.model, options.maximum_body_bytes);
    try bounded(options.provider_id, options.maximum_body_bytes);
    try bounded(request.context.system_prompt, options.maximum_body_bytes);
    if (!validText(request.model) or
        !validText(options.provider_id) or
        !validText(request.context.system_prompt)) return error.InvalidRequest;
    if (options.prompt_cache_key) |cache_key| {
        try bounded(cache_key, options.maximum_body_bytes);
        if (cache_key.len == 0 or !validText(cache_key)) return error.InvalidRequest;
    }
    if (request.context.effort) |effort| {
        try bounded(effort, options.maximum_body_bytes);
        if (!validText(effort)) return error.InvalidRequest;
    }

    for (request.context.items) |item| switch (item) {
        .user_message => |message| {
            try bounded(message.text, options.maximum_body_bytes);
            if (!validText(message.text)) return error.InvalidRequest;
            // User images are intentionally ignored by this dialect.
        },
        .assistant_message => |message| {
            try bounded(message.text, options.maximum_body_bytes);
            if (!validText(message.text)) return error.InvalidRequest;
        },
        .tool_call => |call| {
            try bounded(call.id, options.maximum_body_bytes);
            try bounded(call.name, options.maximum_body_bytes);
            try bounded(call.arguments_json, options.maximum_body_bytes);
            if (!validText(call.id) or !validText(call.name) or !validText(call.arguments_json))
                return error.InvalidRequest;
        },
        .tool_result => |result| {
            try bounded(result.call_id, options.maximum_body_bytes);
            try bounded(result.output, options.maximum_body_bytes);
            if (!validText(result.call_id) or !validText(result.output)) return error.InvalidRequest;
            for (result.images) |image| {
                try bounded(image.mime, options.maximum_body_bytes);
                try bounded(image.data_base64, options.maximum_body_bytes);
                if (!validText(image.mime) or !validText(image.data_base64)) return error.InvalidRequest;
            }
        },
        .reasoning => |reasoning| {
            if (reasoningMatches(reasoning, options.provider_id, request.model)) {
                try bounded(reasoning.opaque_json.?, options.maximum_body_bytes);
            }
        },
        .turn_boundary, .turn_usage => {},
    };

    for (request.context.tools) |tool| {
        try bounded(tool.name, options.maximum_body_bytes);
        try bounded(tool.description, options.maximum_body_bytes);
        if (!validNonemptyText(tool.name) or !validText(tool.description)) return error.InvalidRequest;
        for (tool.parameters) |parameter| {
            try bounded(parameter.name, options.maximum_body_bytes);
            try bounded(parameter.description, options.maximum_body_bytes);
            if (!validNonemptyText(parameter.name) or !validText(parameter.description))
                return error.InvalidRequest;
        }
    }
}

fn bounded(bytes: []const u8, maximum: usize) error{BodyTooLarge}!void {
    if (bytes.len > maximum) return error.BodyTooLarge;
}

fn validText(bytes: []const u8) bool {
    return std.unicode.utf8ValidateSlice(bytes);
}

fn validNonemptyText(bytes: []const u8) bool {
    return bytes.len != 0 and validText(bytes);
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
    try fieldOrExtra(&json, "store", false, extra);
    try field(&json, "instructions", request.context.system_prompt);

    try json.objectField("input");
    try writeInput(allocator, &json, request, options.provider_id);

    if (request.context.tools.len != 0) {
        try json.objectField("tools");
        try writeTools(&json, request.context.tools);
        try fieldOrExtra(&json, "tool_choice", "auto", extra);
        try fieldOrExtra(&json, "parallel_tool_calls", true, extra);
    }

    const effort = request.context.effort;
    const disabled = if (effort) |value| std.mem.eql(u8, value, "none") else false;
    if (!disabled) {
        try json.objectField("include");
        try json.beginArray();
        try json.write("reasoning.encrypted_content");
        try json.endArray();
    }
    if (effort) |value| if (value.len != 0) {
        try json.objectField("reasoning");
        if (extraValue(extra, "reasoning")) |override| {
            if (override.* == .object) {
                try writeReasoning(&json, value, disabled, &override.object);
            } else {
                try json.write(override.*);
            }
        } else {
            try writeReasoning(&json, value, disabled, null);
        }
    };

    if (options.text_verbosity) |verbosity| {
        try json.objectField("text");
        if (extraValue(extra, "text")) |override| {
            if (override.* == .object) {
                try writeText(&json, verbosity, &override.object);
            } else {
                try json.write(override.*);
            }
        } else {
            try writeText(&json, verbosity, null);
        }
    }
    if (options.prompt_cache_key) |cache_key| try fieldOrExtra(&json, "prompt_cache_key", cache_key, extra);
    try writeExtraFields(&json, extra, request, options);
    try json.endObject();
}

fn field(json: *std.json.Stringify, name: []const u8, value: anytype) !void {
    try json.objectField(name);
    try json.write(value);
}

fn fieldOrExtra(json: *std.json.Stringify, name: []const u8, value: anytype, extra: ?*const std.json.Value) !void {
    try json.objectField(name);
    if (extraValue(extra, name)) |override| try json.write(override.*) else try json.write(value);
}

fn extraValue(extra: ?*const std.json.Value, name: []const u8) ?*const std.json.Value {
    const value = extra orelse return null;
    return value.object.getPtr(name);
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

fn writeReasoning(
    json: *std.json.Stringify,
    effort: []const u8,
    disabled: bool,
    object: ?*const std.json.ObjectMap,
) !void {
    try json.beginObject();
    try fieldOrObject(json, "effort", effort, object);
    if (!disabled) try fieldOrObject(json, "summary", "auto", object);
    if (object) |value| {
        const skip: []const []const u8 = if (disabled) &.{"effort"} else &.{ "effort", "summary" };
        try writeObjectRemainder(json, value, skip);
    }
    try json.endObject();
}

fn writeText(
    json: *std.json.Stringify,
    verbosity: TextVerbosity,
    object: ?*const std.json.ObjectMap,
) !void {
    try json.beginObject();
    try fieldOrObject(json, "verbosity", @tagName(verbosity), object);
    if (object) |value| try writeObjectRemainder(json, value, &.{"verbosity"});
    try json.endObject();
}

fn writeObjectRemainder(
    json: *std.json.Stringify,
    object: *const std.json.ObjectMap,
    skip: []const []const u8,
) !void {
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

fn writeExtraFields(
    json: *std.json.Stringify,
    extra: ?*const std.json.Value,
    request: Provider.Request,
    options: Options,
) !void {
    const value = extra orelse return;
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        if (generatedField(entry.key_ptr.*, request, options)) continue;
        try json.objectField(entry.key_ptr.*);
        try json.write(entry.value_ptr.*);
    }
}

fn generatedField(name: []const u8, request: Provider.Request, options: Options) bool {
    if (std.mem.eql(u8, name, "store")) return true;
    if (request.context.tools.len != 0 and
        (std.mem.eql(u8, name, "tool_choice") or std.mem.eql(u8, name, "parallel_tool_calls"))) return true;
    if (request.context.effort) |effort| {
        if (effort.len != 0 and std.mem.eql(u8, name, "reasoning")) return true;
    }
    if (options.text_verbosity != null and std.mem.eql(u8, name, "text")) return true;
    return options.prompt_cache_key != null and std.mem.eql(u8, name, "prompt_cache_key");
}

fn writeInput(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    request: Provider.Request,
    provider_id: []const u8,
) !void {
    try json.beginArray();
    for (request.context.items) |item| switch (item) {
        .user_message => |message| try writeMessage(json, "user", "input_text", message.text),
        .assistant_message => |message| try writeMessage(json, "assistant", "output_text", message.text),
        .tool_call => |call| {
            try json.beginObject();
            try field(json, "type", "function_call");
            try field(json, "call_id", call.id);
            try field(json, "name", call.name);
            try field(json, "arguments", call.arguments_json);
            try json.endObject();
        },
        .tool_result => |result| try writeToolResult(json, result, request.context.image_input),
        .reasoning => |reasoning| {
            if (reasoningMatches(reasoning, provider_id, request.model) and
                try replayIsContainer(allocator, reasoning.opaque_json.?))
            {
                try json.beginWriteRaw();
                try json.writer.writeAll(reasoning.opaque_json.?);
                json.endWriteRaw();
            }
        },
        .turn_boundary, .turn_usage => {},
    };
    try json.endArray();
}

fn writeMessage(json: *std.json.Stringify, role: []const u8, content_type: []const u8, text: []const u8) !void {
    try json.beginObject();
    try field(json, "type", "message");
    try field(json, "role", role);
    try json.objectField("content");
    try json.beginArray();
    try json.beginObject();
    try field(json, "type", content_type);
    try field(json, "text", text);
    try json.endObject();
    try json.endArray();
    try json.endObject();
}

fn writeToolResult(
    json: *std.json.Stringify,
    result: Item.ToolResult,
    image_input: Provider.ImageInput,
) !void {
    try json.beginObject();
    try field(json, "type", "function_call_output");
    try field(json, "call_id", result.call_id);
    try json.objectField("output");
    if (result.images.len == 0) {
        try json.write(result.output);
    } else {
        try json.beginArray();
        if (result.output.len != 0) {
            try json.beginObject();
            try field(json, "type", "input_text");
            try field(json, "text", result.output);
            try json.endObject();
        }
        for (result.images) |image| {
            try json.beginObject();
            if (image_input != .unsupported) {
                try field(json, "type", "input_image");
                try json.objectField("image_url");
                try writeDataUri(json, image);
            } else {
                try field(json, "type", "input_text");
                try json.objectField("text");
                try writeImagePlaceholder(json, image);
            }
            try json.endObject();
        }
        try json.endArray();
    }
    try json.endObject();
}

fn writeDataUri(json: *std.json.Stringify, image: Item.Image) !void {
    try json.beginWriteRaw();
    try json.writer.writeByte('"');
    try json.writer.writeAll("data:");
    try std.json.Stringify.encodeJsonStringChars(
        image.mime,
        .{},
        json.writer,
    );
    try json.writer.writeAll(";base64,");
    try std.json.Stringify.encodeJsonStringChars(image.data_base64, .{}, json.writer);
    try json.writer.writeByte('"');
    json.endWriteRaw();
}

fn writeImagePlaceholder(json: *std.json.Stringify, image: Item.Image) !void {
    const decoded_bytes = image.data_base64.len / 4 * 3;
    try json.beginWriteRaw();
    try json.writer.writeByte('"');
    try json.writer.writeAll("[image: ");
    try std.json.Stringify.encodeJsonStringChars(
        image.mime,
        .{},
        json.writer,
    );
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

fn writeTools(json: *std.json.Stringify, tools: []const Provider.ToolDefinition) !void {
    try json.beginArray();
    for (tools) |tool| {
        try json.beginObject();
        try field(json, "type", "function");
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
        var has_required = false;
        for (tool.parameters) |parameter| has_required = has_required or parameter.required;
        if (has_required) {
            try json.objectField("required");
            try json.beginArray();
            for (tool.parameters) |parameter| if (parameter.required) try json.write(parameter.name);
            try json.endArray();
        }
        try json.endObject();
        try json.endObject();
    }
    try json.endArray();
}

fn mutable(bytes: []const u8) []u8 {
    return @constCast(bytes);
}

fn requestWith(items: []const Item.Item) Provider.Request {
    return .{
        .model = "gpt-5",
        .context = .{ .system_prompt = "be brief", .items = items, .tools = &.{} },
    };
}

test "input items have exact Responses shapes and ignore bookkeeping" {
    const items = [_]Item.Item{
        .{ .user_message = .{ .text = mutable("hi") } },
        .{ .assistant_message = .{ .text = mutable("yo") } },
        .{ .tool_call = .{
            .id = mutable("c1"),
            .name = mutable("bash"),
            .arguments_json = mutable("{\"command\":\"ls\"}"),
        } },
        .turn_boundary,
        .{ .turn_usage = .{ .value = .{} } },
        .{ .tool_result = .{ .call_id = mutable("c1"), .output = mutable("out") } },
    };
    const body = try build(std.testing.allocator, requestWith(&items), .{});
    defer std.testing.allocator.free(body);

    try std.testing.expectEqualStrings(
        "{\"model\":\"gpt-5\",\"stream\":true,\"store\":false," ++
            "\"instructions\":\"be brief\",\"input\":[" ++
            "{\"type\":\"message\",\"role\":\"user\",\"content\":[" ++
            "{\"type\":\"input_text\",\"text\":\"hi\"}]}," ++
            "{\"type\":\"message\",\"role\":\"assistant\",\"content\":[" ++
            "{\"type\":\"output_text\",\"text\":\"yo\"}]}," ++
            "{\"type\":\"function_call\",\"call_id\":\"c1\",\"name\":\"bash\"," ++
            "\"arguments\":\"{\\\"command\\\":\\\"ls\\\"}\"}," ++
            "{\"type\":\"function_call_output\",\"call_id\":\"c1\",\"output\":\"out\"}]," ++
            "\"include\":[\"reasoning.encrypted_content\"]}",
        body,
    );
}

test "tool-result images use data URIs or exact unsupported placeholders" {
    var images = [_]Item.Image{.{
        .mime = mutable("image/png"),
        .data_base64 = mutable("QUJD"),
        .width = 4,
        .height = 2,
    }};
    const items = [_]Item.Item{.{ .tool_result = .{
        .call_id = mutable("c9"),
        .output = mutable("note"),
        .images = &images,
    } }};
    var request = requestWith(&items);

    request.context.image_input = .supported;
    var body = try build(std.testing.allocator, request, .{});
    try std.testing.expect(std.mem.indexOf(u8, body, "\"output\":[{\"type\":\"input_text\",\"text\":\"note\"}," ++
        "{\"type\":\"input_image\",\"image_url\":\"data:image/png;base64,QUJD\"}]") != null);
    std.testing.allocator.free(body);

    request.context.image_input = .unknown;
    body = try build(std.testing.allocator, request, .{});
    try std.testing.expect(std.mem.indexOf(u8, body, "data:image/png;base64,QUJD") != null);
    std.testing.allocator.free(body);

    request.context.image_input = .unsupported;
    body = try build(std.testing.allocator, request, .{});
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(
        u8,
        body,
        "{\"type\":\"input_text\",\"text\":\"[image: image/png, 4x2, 3 bytes]\"}",
    ) != null);
}

test "user images are intentionally ignored" {
    var images = [_]Item.Image{.{
        .mime = mutable("image/png"),
        .data_base64 = mutable("SECRETBASE64"),
    }};
    const items = [_]Item.Item{.{ .user_message = .{
        .text = mutable("look"),
        .images = &images,
    } }};
    const body = try build(std.testing.allocator, requestWith(&items), .{});
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "SECRETBASE64") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"text\":\"look\"") != null);
}

test "opaque reasoning replay is gated by exact source model and canonical provider" {
    const reasoning_json = "{\"type\":\"reasoning\",\"summary\":[],\"encrypted_content\":\"abc==\"}";
    const items = [_]Item.Item{
        .{ .reasoning = .{
            .opaque_json = mutable(reasoning_json),
            .source = .{ .provider = "llama.cpp", .model = "gpt-5" },
        } },
        .{ .assistant_message = .{ .text = mutable("done") } },
    };
    const request = requestWith(&items);

    var body = try build(std.testing.allocator, request, .{ .provider_id = "llamacpp" });
    try std.testing.expect(std.mem.indexOf(u8, body, reasoning_json) != null);
    std.testing.allocator.free(body);

    body = try build(std.testing.allocator, request, .{ .provider_id = "openai" });
    try std.testing.expect(std.mem.indexOf(u8, body, "encrypted_content\":\"abc") == null);
    std.testing.allocator.free(body);

    var other_model = request;
    other_model.model = "gpt-5.1";
    body = try build(std.testing.allocator, other_model, .{ .provider_id = "llamacpp" });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "encrypted_content\":\"abc") == null);
}

test "tool definitions use flat function schemas" {
    const parameters = [_]Provider.ToolParameter{
        .{
            .name = "command",
            .type = .string,
            .description = "shell command",
            .required = true,
        },
        .{
            .name = "count",
            .type = .integer,
            .description = "repeat count",
            .minimum = 1,
        },
        .{
            .name = "names",
            .type = .array,
            .item_type = .string,
            .description = "names",
        },
    };
    const tools = [_]Provider.ToolDefinition{.{
        .name = "bash",
        .description = "run a command",
        .parameters = &parameters,
    }};
    var request = requestWith(&.{});
    request.context.tools = &tools;
    const body = try build(std.testing.allocator, request, .{});
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.indexOf(
        u8,
        body,
        "\"tools\":[{\"type\":\"function\",\"name\":\"bash\"," ++
            "\"description\":\"run a command\",\"parameters\":{\"type\":\"object\"," ++
            "\"properties\":{",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"function\":") == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        body,
        "\"names\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}," ++
            "\"description\":\"names\"}",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"required\":[\"command\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_choice\":\"auto\",\"parallel_tool_calls\":true") != null);
}

test "reasoning effort and include follow hax semantics" {
    var request = requestWith(&.{});
    var body = try build(std.testing.allocator, request, .{});
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning\":") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "reasoning.encrypted_content") != null);
    std.testing.allocator.free(body);

    request.context.effort = "";
    body = try build(std.testing.allocator, request, .{});
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning\":") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "reasoning.encrypted_content") != null);
    std.testing.allocator.free(body);

    request.context.effort = "none";
    body = try build(std.testing.allocator, request, .{});
    try std.testing.expect(std.mem.indexOf(u8, body, "\"include\":") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning\":{\"effort\":\"none\"}") != null);
    std.testing.allocator.free(body);

    request.context.effort = "medium";
    body = try build(std.testing.allocator, request, .{ .prompt_cache_key = "sess-2" });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(
        u8,
        body,
        "\"reasoning\":{\"effort\":\"medium\",\"summary\":\"auto\"}",
    ) != null);
    try std.testing.expect(std.mem.endsWith(u8, body, "\"prompt_cache_key\":\"sess-2\"}"));
}

test "Codex options add exact text verbosity and prompt cache key" {
    const body = try build(std.testing.allocator, requestWith(&.{}), .{
        .text_verbosity = .low,
        .prompt_cache_key = "sess",
    });
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings(
        "{\"model\":\"gpt-5\",\"stream\":true,\"store\":false," ++
            "\"instructions\":\"be brief\",\"input\":[]," ++
            "\"include\":[\"reasoning.encrypted_content\"]," ++
            "\"text\":{\"verbosity\":\"low\"},\"prompt_cache_key\":\"sess\"}",
        body,
    );
}

test "extra body recursively merges last over generated fields" {
    var request = requestWith(&.{});
    request.context.effort = "medium";
    const body = try build(std.testing.allocator, request, .{
        .text_verbosity = .low,
        .prompt_cache_key = "generated",
        .extra_body_json = "{\"store\":true,\"reasoning\":{\"summary\":\"detailed\",\"budget\":7}," ++
            "\"text\":{\"verbosity\":\"high\",\"format\":{\"type\":\"plain\"}}," ++
            "\"prompt_cache_key\":\"extra\",\"metadata\":{\"nested\":{\"ok\":true}}}",
    });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"store\":true") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        body,
        "\"reasoning\":{\"effort\":\"medium\",\"summary\":\"detailed\",\"budget\":7}",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        body,
        "\"text\":{\"verbosity\":\"high\",\"format\":{\"type\":\"plain\"}}",
    ) != null);
    try std.testing.expect(std.mem.endsWith(
        u8,
        body,
        "\"prompt_cache_key\":\"extra\",\"metadata\":{\"nested\":{\"ok\":true}}}",
    ));
}

test "extra body rejects malformed, non-object, and protocol-owned JSON" {
    const request = requestWith(&.{});
    try std.testing.expectError(error.InvalidRequest, build(
        std.testing.allocator,
        request,
        .{ .extra_body_json = "{" },
    ));
    try std.testing.expectError(error.InvalidRequest, build(
        std.testing.allocator,
        request,
        .{ .extra_body_json = "[]" },
    ));
    try std.testing.expectError(error.InvalidRequest, build(
        std.testing.allocator,
        request,
        .{ .extra_body_json = "{\"input\":[]}" },
    ));

    var deep: std.ArrayList(u8) = .empty;
    defer deep.deinit(std.testing.allocator);
    try deep.appendSlice(std.testing.allocator, "{\"x\":");
    try deep.appendNTimes(std.testing.allocator, '[', maximum_json_depth);
    try deep.appendNTimes(std.testing.allocator, ']', maximum_json_depth);
    try deep.append(std.testing.allocator, '}');
    try std.testing.expectError(error.InvalidRequest, build(
        std.testing.allocator,
        request,
        .{ .extra_body_json = deep.items },
    ));
}

test "body limit is exact and configurable" {
    const request = requestWith(&.{});
    const body = try build(std.testing.allocator, request, .{});
    const body_length = body.len;
    std.testing.allocator.free(body);

    const exact = try build(std.testing.allocator, request, .{ .maximum_body_bytes = body_length });
    defer std.testing.allocator.free(exact);
    try std.testing.expectEqual(body_length, exact.len);
    try std.testing.expectError(error.BodyTooLarge, build(
        std.testing.allocator,
        request,
        .{ .maximum_body_bytes = body_length - 1 },
    ));
}

test "invalid request fields are rejected" {
    var request = requestWith(&.{});
    request.model = "";
    try std.testing.expectError(error.InvalidRequest, build(std.testing.allocator, request, .{}));

    request = requestWith(&.{});
    try std.testing.expectError(error.InvalidRequest, build(
        std.testing.allocator,
        request,
        .{ .provider_id = "" },
    ));
    try std.testing.expectError(error.InvalidRequest, build(
        std.testing.allocator,
        request,
        .{ .prompt_cache_key = "" },
    ));
    try std.testing.expectError(error.InvalidRequest, build(
        std.testing.allocator,
        request,
        .{ .maximum_body_bytes = 0 },
    ));

    const invalid_utf8 = [_]u8{0xff};
    request.context.effort = &invalid_utf8;
    try std.testing.expectError(error.InvalidRequest, build(std.testing.allocator, request, .{}));
}

fn exerciseAllocationFailures(allocator: std.mem.Allocator) !void {
    const items = [_]Item.Item{.{ .reasoning = .{
        .opaque_json = mutable("{\"type\":\"reasoning\",\"summary\":[]}"),
        .source = .{ .provider = "openai", .model = "gpt-5" },
    } }};
    const body = try build(allocator, requestWith(&items), .{
        .text_verbosity = .low,
        .extra_body_json = "{\"text\":{\"format\":{\"type\":\"plain\"}}}",
    });
    allocator.free(body);
}

test "builder frees every allocation after OOM" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}

test "scalar opaque reasoning replay is omitted" {
    const items = [_]Item.Item{.{ .reasoning = .{
        .opaque_json = mutable("null"),
        .source = .{ .provider = "openai", .model = "gpt-5" },
    } }};
    const body = try build(std.testing.allocator, requestWith(&items), .{});
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "null") == null);
}

test "counting stops at the configured body limit" {
    const huge = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(huge);
    @memset(huge, 'x');
    const items = [_]Item.Item{.{ .user_message = .{ .text = huge } }};
    try std.testing.expectError(error.BodyTooLarge, build(
        std.testing.allocator,
        requestWith(&items),
        .{ .maximum_body_bytes = 64 },
    ));
    try std.testing.expectError(error.InvalidRequest, build(
        std.testing.allocator,
        requestWith(&.{}),
        .{ .maximum_body_bytes = default_maximum_body_bytes + 1 },
    ));
}
