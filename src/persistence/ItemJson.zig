const std = @import("std");
const ai = @import("../ai/root.zig");

pub const default_max_line_bytes: usize = 8 * 1024 * 1024;
pub const default_max_nesting: usize = 64;
pub const default_max_fields: usize = 4096;
pub const default_max_tokens: usize = 262_144;

pub const Limits = struct {
    max_line_bytes: usize = default_max_line_bytes,
    max_nesting: usize = default_max_nesting,
    max_fields: usize = default_max_fields,
    max_tokens: usize = default_max_tokens,
};

/// Header selection used only when an old reasoning record omitted its identity.
pub const DecodeContext = struct {
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
};

pub const Error = error{
    OutOfMemory,
    InvalidLimits,
    InvalidItem,
    LineTooLarge,
    InvalidJson,
    TooDeep,
    TooManyFields,
    TooMuchWork,
    UnknownKind,
    MalformedItem,
};

/// Encodes one item as an owned compact JSON object without a trailing newline.
pub fn encode(allocator: std.mem.Allocator, item: ai.Item.Item, limits: Limits) Error![]u8 {
    try validateLimits(limits);
    try validateItem(item, limits);

    var scratch: [256]u8 = undefined;
    const scratch_len = @min(scratch.len, limits.max_line_bytes + 1);
    var counter: LimitedCounter = .init(scratch[0..scratch_len], limits.max_line_bytes);
    writeItem(&counter.writer, item) catch {
        if (counter.exceeded) return error.LineTooLarge;
        unreachable;
    };
    const length = counter.fullCount();
    if (length > limits.max_line_bytes) return error.LineTooLarge;

    const result = try allocator.alloc(u8, length);
    errdefer allocator.free(result);
    var writer: std.Io.Writer = .fixed(result);
    writeItem(&writer, item) catch unreachable;
    std.debug.assert(writer.end == result.len);
    try scanBounds(allocator, result, limits);
    return result;
}

/// Decodes one owned item. Legacy reasoning identity is left absent.
pub fn decode(allocator: std.mem.Allocator, line: []const u8, limits: Limits) Error!ai.Item.Item {
    return decodeWithContext(allocator, line, limits, .{});
}

/// Decodes one owned item and supplies provenance for legacy reasoning records.
pub fn decodeWithContext(
    allocator: std.mem.Allocator,
    line: []const u8,
    limits: Limits,
    context: DecodeContext,
) Error!ai.Item.Item {
    try validateLimits(limits);
    if (line.len > limits.max_line_bytes) return error.LineTooLarge;
    if (line.len == 0 or !std.unicode.utf8ValidateSlice(line)) return error.InvalidJson;
    try scanBounds(allocator, line, limits);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{
        .duplicate_field_behavior = .use_last,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.MalformedItem;
    const object = parsed.value.object;
    const kind = requiredString(object, "kind") catch return error.MalformedItem;

    if (std.mem.eql(u8, kind, "user")) return decodeUser(allocator, object);
    if (std.mem.eql(u8, kind, "assistant")) return decodeAssistant(allocator, object);
    if (std.mem.eql(u8, kind, "tool_call")) return decodeToolCall(allocator, object);
    if (std.mem.eql(u8, kind, "tool_result")) return decodeToolResult(allocator, object);
    if (std.mem.eql(u8, kind, "reasoning")) return decodeReasoning(allocator, object, context);
    if (std.mem.eql(u8, kind, "turn_boundary")) {
        return .turn_boundary;
    }
    if (std.mem.eql(u8, kind, "turn_usage")) return decodeTurnUsage(allocator, object);
    return error.UnknownKind;
}

fn validateLimits(limits: Limits) Error!void {
    if (limits.max_line_bytes == 0 or limits.max_line_bytes > default_max_line_bytes or
        limits.max_nesting == 0 or limits.max_nesting > default_max_nesting or
        limits.max_fields == 0 or limits.max_fields > default_max_fields or
        limits.max_tokens == 0 or limits.max_tokens > default_max_tokens)
    {
        return error.InvalidLimits;
    }
}

fn scanBounds(allocator: std.mem.Allocator, line: []const u8, limits: Limits) Error!void {
    var scanner = std.json.Scanner.initCompleteInput(allocator, line);
    defer scanner.deinit();
    var depth: usize = 0;
    var fields: usize = 0;
    var tokens: usize = 0;
    while (true) {
        const token = scanner.nextAllocMax(
            allocator,
            .alloc_if_needed,
            limits.max_line_bytes,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidJson,
        };
        defer if (token == .allocated_string) allocator.free(token.allocated_string);
        tokens += 1;
        if (tokens > limits.max_tokens) return error.TooMuchWork;
        switch (token) {
            .object_begin, .array_begin => {
                depth += 1;
                if (depth > limits.max_nesting) return error.TooDeep;
            },
            .object_end, .array_end => {
                if (depth == 0) return error.InvalidJson;
                depth -= 1;
            },
            .string, .allocated_string => if (scanner.string_is_object_key) {
                fields += 1;
                if (fields > limits.max_fields) return error.TooManyFields;
            },
            .end_of_document => if (depth == 0) return else return error.InvalidJson,
            else => {},
        }
    }
}

fn validateItem(item: ai.Item.Item, limits: Limits) Error!void {
    if (encodedFieldCount(item) > limits.max_fields) return error.TooManyFields;
    switch (item) {
        .user_message => |value| {
            try validString(value.text, limits);
            try validateImages(value.images, limits);
        },
        .assistant_message => |value| try validString(value.text, limits),
        .tool_call => |value| {
            try validString(value.id, limits);
            try validString(value.name, limits);
            try validString(value.arguments_json, limits);
        },
        .tool_result => |value| {
            try validString(value.call_id, limits);
            try validString(value.output, limits);
            if (value.hidden_tail_bytes > value.output.len) return error.InvalidItem;
            try validateImages(value.images, limits);
        },
        .reasoning => |value| {
            if (value.opaque_json) |bytes| try validString(bytes, limits);
            if (value.text) |bytes| try validString(bytes, limits);
            try validateIdentity(value.source, limits);
        },
        .turn_boundary => {},
        .turn_usage => |value| {
            try validateUsage(value.value, limits);
            try validateIdentity(value.source, limits);
        },
    }
}

fn boolInt(value: bool) usize {
    return @intFromBool(value);
}

fn encodedFieldCount(item: ai.Item.Item) usize {
    return switch (item) {
        .user_message => |value| 2 + boolInt(value.origin != .external) + imageFieldCount(value.images),
        .assistant_message => |value| 2 + boolInt(value.origin != .external),
        .tool_call => 4,
        .tool_result => |value| 3 + boolInt(value.hidden_tail_bytes != 0) +
            boolInt(value.origin != .external) + imageFieldCount(value.images),
        .reasoning => |value| 1 + boolInt(value.opaque_json != null) +
            boolInt(value.text != null) + identityFieldCount(value.source),
        .turn_boundary => 1,
        .turn_usage => |value| 2 + identityFieldCount(value.source) + usageFieldCount(value.value),
    };
}

fn imageFieldCount(images: []const ai.Item.Image) usize {
    if (images.len == 0) return 0;
    var count: usize = 1;
    for (images) |image| count += 2 + boolInt((image.width orelse 0) != 0) +
        boolInt((image.height orelse 0) != 0);
    return count;
}

fn identityFieldCount(source: ?ai.Item.OwnedModelIdentity) usize {
    const value = source orelse return 0;
    return boolInt(value.provider != null) + boolInt(value.model != null);
}

fn usageFieldCount(value: ai.Usage.TurnUsage) usize {
    var count: usize = 0;
    inline for (.{
        "input_tokens",
        "output_tokens",
        "cached_tokens",
        "cache_write_tokens",
        "cache_write_1h_tokens",
        "cost_usd",
    }) |name| {
        count += boolInt(@field(value.stream, name) != null);
    }
    inline for (.{
        "elapsed_ms",
        "uncached_input_tokens",
        "cost_input_usd",
        "cost_cache_read_usd",
        "cost_cache_write_usd",
        "cost_output_usd",
        "cost_total_usd",
    }) |name| {
        count += boolInt(@field(value, name) != null);
    }
    count += boolInt(value.cost_estimated);
    inline for (.{ "provider_label", "model_label", "effort", "served_model", "route", "response_id" }) |name| {
        count += boolInt(@field(value.provenance, name) != null);
    }
    return count;
}

fn validString(value: []const u8, limits: Limits) Error!void {
    if (value.len > limits.max_line_bytes) return error.LineTooLarge;
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidItem;
}

fn validateIdentity(value: ?ai.Item.OwnedModelIdentity, limits: Limits) Error!void {
    const identity = value orelse return;
    if (identity.provider) |bytes| try validString(bytes, limits);
    if (identity.model) |bytes| try validString(bytes, limits);
}

fn validateImages(images: []const ai.Item.Image, limits: Limits) Error!void {
    if (images.len > limits.max_fields) return error.InvalidItem;
    var source_bytes: usize = 0;
    for (images) |image| {
        source_bytes = std.math.add(usize, source_bytes, image.mime.len) catch
            return error.LineTooLarge;
        source_bytes = std.math.add(usize, source_bytes, image.data_base64.len) catch
            return error.LineTooLarge;
        if (source_bytes > limits.max_line_bytes) return error.LineTooLarge;
    }
    for (images) |image| {
        try validString(image.mime, limits);
        try validString(image.data_base64, limits);
        if (!validImageMime(image.mime) or image.data_base64.len == 0 or
            !validBase64(image.data_base64)) return error.InvalidItem;
    }
}

fn validImageMime(bytes: []const u8) bool {
    if (bytes.len <= "image/".len or
        !std.ascii.eqlIgnoreCase(bytes[0.."image/".len], "image/")) return false;
    for (bytes["image/".len..]) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or switch (byte) {
            '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
            else => false,
        })) return false;
    }
    return true;
}

fn validBase64(bytes: []const u8) bool {
    _ = std.base64.standard.Decoder.calcSizeForSlice(bytes) catch return false;
    var padding_start = bytes.len;
    while (padding_start > 0 and bytes[padding_start - 1] == '=') padding_start -= 1;
    if (bytes.len - padding_start > 2) return false;
    for (bytes[0..padding_start]) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '+' or byte == '/')) return false;
    }
    for (bytes[padding_start..]) |byte| if (byte != '=') return false;
    return true;
}

fn validCost(value: ?f64) bool {
    const cost = value orelse return true;
    return std.math.isFinite(cost) and cost >= 0;
}

fn validateUsage(value: ai.Usage.TurnUsage, limits: Limits) Error!void {
    if (!validCost(value.stream.cost_usd) or !validCost(value.cost_input_usd) or
        !validCost(value.cost_cache_read_usd) or !validCost(value.cost_cache_write_usd) or
        !validCost(value.cost_output_usd) or !validCost(value.cost_total_usd)) return error.InvalidItem;
    inline for (.{ "provider_label", "model_label", "effort", "served_model", "route", "response_id" }) |name| {
        if (@field(value.provenance, name)) |bytes| try validString(bytes, limits);
    }
}

fn writeItem(writer: *std.Io.Writer, item: ai.Item.Item) std.Io.Writer.Error!void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginObject();
    switch (item) {
        .user_message => |value| {
            try field(&json, "kind", "user");
            try field(&json, "text", value.text);
            try writeOrigin(&json, switch (value.origin) {
                .external => null,
                .compact_seed => "compact_seed",
                .continuation => "continuation",
                .task_note => "task_note",
            });
            try writeImages(&json, value.images);
        },
        .assistant_message => |value| {
            try field(&json, "kind", "assistant");
            try field(&json, "text", value.text);
            try writeOrigin(&json, switch (value.origin) {
                .external => null,
                .interrupted => "interrupted",
            });
        },
        .tool_call => |value| {
            try field(&json, "kind", "tool_call");
            try field(&json, "call_id", value.id);
            try field(&json, "tool_name", value.name);
            try field(&json, "arguments", value.arguments_json);
        },
        .tool_result => |value| {
            try field(&json, "kind", "tool_result");
            try field(&json, "call_id", value.call_id);
            try field(&json, "output", value.output);
            if (value.hidden_tail_bytes != 0) try field(&json, "output_hidden_tail", value.hidden_tail_bytes);
            try writeOrigin(&json, switch (value.origin) {
                .external => null,
                .skipped => "skipped",
                .refused => "refused",
                .summarized => "summarized",
            });
            try writeImages(&json, value.images);
        },
        .reasoning => |value| {
            try field(&json, "kind", "reasoning");
            if (value.opaque_json) |bytes| try field(&json, "reasoning_json", bytes);
            if (value.text) |bytes| try field(&json, "reasoning_text", bytes);
            try writeIdentity(&json, value.source);
        },
        .turn_boundary => try field(&json, "kind", "turn_boundary"),
        .turn_usage => |value| {
            try field(&json, "kind", "turn_usage");
            try writeIdentity(&json, value.source);
            try json.objectField("usage");
            try writeUsage(&json, value.value);
        },
    }
    try json.endObject();
}

fn field(json: *std.json.Stringify, name: []const u8, value: anytype) std.Io.Writer.Error!void {
    try json.objectField(name);
    try json.write(value);
}

fn writeOrigin(json: *std.json.Stringify, name: ?[]const u8) std.Io.Writer.Error!void {
    if (name) |value| try field(json, "origin", value);
}

fn writeIdentity(json: *std.json.Stringify, source: ?ai.Item.OwnedModelIdentity) std.Io.Writer.Error!void {
    const value = source orelse return;
    if (value.provider) |bytes| try field(json, "provider", bytes);
    if (value.model) |bytes| try field(json, "model", bytes);
}

fn writeImages(json: *std.json.Stringify, images: []const ai.Item.Image) std.Io.Writer.Error!void {
    if (images.len == 0) return;
    try json.objectField("images");
    try json.beginArray();
    for (images) |image| {
        try json.beginObject();
        try field(json, "mime", image.mime);
        try field(json, "data", image.data_base64);
        if (image.width) |width| if (width != 0) try field(json, "width", width);
        if (image.height) |height| if (height != 0) try field(json, "height", height);
        try json.endObject();
    }
    try json.endArray();
}

fn writeUsage(json: *std.json.Stringify, usage: ai.Usage.TurnUsage) std.Io.Writer.Error!void {
    try json.beginObject();
    const stream = usage.stream;
    if (stream.input_tokens) |value| try field(json, "input", value);
    if (stream.output_tokens) |value| try field(json, "output", value);
    if (stream.cached_tokens) |value| try field(json, "cached", value);
    if (stream.cache_write_tokens) |value| try field(json, "cache_write", value);
    if (stream.cache_write_1h_tokens) |value| try field(json, "cache_write_1h", value);
    if (stream.cost_usd) |value| try costField(json, "cost", value);
    if (usage.elapsed_ms) |value| try field(json, "elapsed_ms", value);
    if (usage.uncached_input_tokens) |value| try field(json, "in_tokens", value);
    if (usage.cost_input_usd) |value| try costField(json, "cost_in", value);
    if (usage.cost_cache_read_usd) |value| try costField(json, "cost_cache_read", value);
    if (usage.cost_cache_write_usd) |value| try costField(json, "cost_cache_write", value);
    if (usage.cost_output_usd) |value| try costField(json, "cost_out", value);
    if (usage.cost_total_usd) |value| try costField(json, "cost_total", value);
    if (usage.cost_estimated) try field(json, "cost_estimated", true);
    inline for (.{ "provider_label", "model_label", "effort", "served_model", "route", "response_id" }) |name| {
        if (@field(usage.provenance, name)) |value| try field(json, name, value);
    }
    try json.endObject();
}

fn costField(json: *std.json.Stringify, name: []const u8, value: f64) std.Io.Writer.Error!void {
    try json.objectField(name);
    try json.beginWriteRaw();
    var buffer: [64]u8 = undefined;
    const bytes = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch unreachable;
    try json.writer.writeAll(bytes);
    if (std.mem.findAny(u8, bytes, ".eE") == null) try json.writer.writeAll(".0");
    json.endWriteRaw();
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
        var written = std.math.mul(usize, data[data.len - 1].len, splat) catch return self.fail();
        for (data[0 .. data.len - 1]) |bytes| {
            written = std.math.add(usize, written, bytes.len) catch return self.fail();
        }
        const buffered = std.math.add(usize, self.count, writer.end) catch return self.fail();
        const total = std.math.add(usize, buffered, written) catch return self.fail();
        if (total > self.limit) return self.fail();
        self.count = total;
        writer.end = 0;
        return written;
    }

    fn fail(self: *LimitedCounter) std.Io.Writer.Error {
        self.exceeded = true;
        return error.WriteFailed;
    }
};

fn decodeUser(allocator: std.mem.Allocator, object: std.json.ObjectMap) Error!ai.Item.Item {
    const text = try dupeRequiredString(allocator, object, "text");
    errdefer allocator.free(text);
    return .{ .user_message = .{
        .text = text,
        .images = try decodeImages(allocator, object),
        .origin = decodeUserOrigin(object),
    } };
}

fn decodeAssistant(allocator: std.mem.Allocator, object: std.json.ObjectMap) Error!ai.Item.Item {
    return .{ .assistant_message = .{
        .text = try dupeRequiredString(allocator, object, "text"),
        .origin = decodeAssistantOrigin(object),
    } };
}

fn decodeToolCall(allocator: std.mem.Allocator, object: std.json.ObjectMap) Error!ai.Item.Item {
    const call_id = try dupeRequiredString(allocator, object, "call_id");
    errdefer allocator.free(call_id);
    const name = try dupeRequiredString(allocator, object, "tool_name");
    errdefer allocator.free(name);
    return .{ .tool_call = .{
        .id = call_id,
        .name = name,
        .arguments_json = try dupeRequiredString(allocator, object, "arguments"),
    } };
}

fn decodeToolResult(allocator: std.mem.Allocator, object: std.json.ObjectMap) Error!ai.Item.Item {
    const call_id = try dupeRequiredString(allocator, object, "call_id");
    errdefer allocator.free(call_id);
    const output = try dupeRequiredString(allocator, object, "output");
    errdefer allocator.free(output);
    const hidden_tail = try optionalUsize(object, "output_hidden_tail") orelse 0;
    if (hidden_tail > output.len) return error.MalformedItem;
    return .{ .tool_result = .{
        .call_id = call_id,
        .output = output,
        .hidden_tail_bytes = hidden_tail,
        .images = try decodeImages(allocator, object),
        .origin = decodeToolResultOrigin(object),
    } };
}

fn decodeReasoning(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    context: DecodeContext,
) Error!ai.Item.Item {
    var result: ai.Item.Reasoning = .{};
    errdefer deinitReasoning(allocator, &result);
    result.opaque_json = try dupeOptionalString(allocator, object, "reasoning_json");
    result.text = try dupeOptionalString(allocator, object, "reasoning_text");
    const provider = try optionalString(object, "provider") orelse context.provider;
    const model = try optionalString(object, "model") orelse context.model;
    result.source = try dupeIdentity(allocator, provider, model);
    return .{ .reasoning = result };
}

fn decodeTurnUsage(allocator: std.mem.Allocator, object: std.json.ObjectMap) Error!ai.Item.Item {
    const usage_value = object.get("usage") orelse return error.MalformedItem;
    if (usage_value != .object) return error.MalformedItem;
    var usage = try decodeUsage(allocator, usage_value.object);
    errdefer usage.deinit(allocator);
    const provider = try optionalString(object, "provider");
    const model = try optionalString(object, "model");
    return .{ .turn_usage = .{
        .value = usage,
        .source = try dupeIdentity(allocator, provider, model),
    } };
}

fn requiredString(object: std.json.ObjectMap, name: []const u8) Error![]const u8 {
    return try optionalString(object, name) orelse error.MalformedItem;
}

fn optionalString(object: std.json.ObjectMap, name: []const u8) Error!?[]const u8 {
    const value = object.get(name) orelse return null;
    if (value == .null) return null;
    if (value != .string or !std.unicode.utf8ValidateSlice(value.string)) return error.MalformedItem;
    return value.string;
}

fn dupeRequiredString(allocator: std.mem.Allocator, object: std.json.ObjectMap, name: []const u8) Error![]u8 {
    return allocator.dupe(u8, try requiredString(object, name));
}

fn dupeOptionalString(allocator: std.mem.Allocator, object: std.json.ObjectMap, name: []const u8) Error!?[]u8 {
    const value = try optionalString(object, name) orelse return null;
    const owned = try allocator.dupe(u8, value);
    return owned;
}

fn optionalU64(object: std.json.ObjectMap, name: []const u8) Error!?u64 {
    const value = object.get(name) orelse return null;
    if (value == .null) return null;
    if (value != .integer or value.integer < 0) return error.MalformedItem;
    return std.math.cast(u64, value.integer) orelse error.MalformedItem;
}

fn optionalUsize(object: std.json.ObjectMap, name: []const u8) Error!?usize {
    const value = try optionalU64(object, name) orelse return null;
    return std.math.cast(usize, value) orelse error.MalformedItem;
}

fn optionalCost(object: std.json.ObjectMap, name: []const u8) Error!?f64 {
    const value = object.get(name) orelse return null;
    if (value == .null) return null;
    const number: f64 = switch (value) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        else => return error.MalformedItem,
    };
    if (!std.math.isFinite(number) or number < 0) return error.MalformedItem;
    return number;
}

fn optionalBool(object: std.json.ObjectMap, name: []const u8) Error!?bool {
    const value = object.get(name) orelse return null;
    if (value == .null) return null;
    if (value != .bool) return error.MalformedItem;
    return value.bool;
}

fn decodeImages(allocator: std.mem.Allocator, object: std.json.ObjectMap) Error![]ai.Item.Image {
    const value = object.get("images") orelse return &.{};
    if (value == .null) return &.{};
    if (value != .array) return error.MalformedItem;
    if (value.array.items.len == 0) return &.{};
    const images = try allocator.alloc(ai.Item.Image, value.array.items.len);
    var initialized: usize = 0;
    errdefer {
        for (images[0..initialized]) |*image| image.deinit(allocator);
        allocator.free(images);
    }
    for (value.array.items, 0..) |entry, index| {
        if (entry != .object) return error.MalformedItem;
        const mime = try dupeRequiredString(allocator, entry.object, "mime");
        errdefer allocator.free(mime);
        const data = try dupeRequiredString(allocator, entry.object, "data");
        errdefer allocator.free(data);
        if (!validImageMime(mime) or data.len == 0 or !validBase64(data)) {
            return error.MalformedItem;
        }
        const width_u64 = try optionalU64(entry.object, "width");
        const height_u64 = try optionalU64(entry.object, "height");
        const width = if (width_u64) |number| std.math.cast(u32, number) orelse return error.MalformedItem else null;
        const height = if (height_u64) |number| std.math.cast(u32, number) orelse return error.MalformedItem else null;
        images[index] = .{
            .mime = mime,
            .data_base64 = data,
            .width = width,
            .height = height,
        };
        if (images[index].width == 0) images[index].width = null;
        if (images[index].height == 0) images[index].height = null;
        initialized += 1;
    }
    return images;
}

fn originString(object: std.json.ObjectMap) ?[]const u8 {
    const value = object.get("origin") orelse return null;
    return if (value == .string) value.string else null;
}

fn decodeUserOrigin(object: std.json.ObjectMap) ai.Item.UserOrigin {
    const value = originString(object) orelse return .external;
    if (std.mem.eql(u8, value, "compact_seed")) return .compact_seed;
    if (std.mem.eql(u8, value, "continuation")) return .continuation;
    if (std.mem.eql(u8, value, "task_note")) return .task_note;
    return .external;
}

fn decodeAssistantOrigin(object: std.json.ObjectMap) ai.Item.AssistantOrigin {
    const value = originString(object) orelse return .external;
    return if (std.mem.eql(u8, value, "interrupted")) .interrupted else .external;
}

fn decodeToolResultOrigin(object: std.json.ObjectMap) ai.Item.ToolResultOrigin {
    const value = originString(object) orelse return .external;
    if (std.mem.eql(u8, value, "skipped")) return .skipped;
    if (std.mem.eql(u8, value, "refused")) return .refused;
    if (std.mem.eql(u8, value, "summarized")) return .summarized;
    return .external;
}

fn dupeIdentity(
    allocator: std.mem.Allocator,
    provider: ?[]const u8,
    model: ?[]const u8,
) Error!?ai.Item.OwnedModelIdentity {
    if (provider == null and model == null) return null;
    const owned_provider = if (provider) |bytes| try allocator.dupe(u8, bytes) else null;
    errdefer if (owned_provider) |bytes| allocator.free(bytes);
    return .{
        .provider = owned_provider,
        .model = if (model) |bytes| try allocator.dupe(u8, bytes) else null,
    };
}

fn deinitReasoning(allocator: std.mem.Allocator, value: *ai.Item.Reasoning) void {
    if (value.opaque_json) |bytes| allocator.free(bytes);
    if (value.text) |bytes| allocator.free(bytes);
    if (value.source) |source| {
        if (source.provider) |bytes| allocator.free(bytes);
        if (source.model) |bytes| allocator.free(bytes);
    }
}

fn decodeUsage(allocator: std.mem.Allocator, object: std.json.ObjectMap) Error!ai.Usage.TurnUsage {
    var usage: ai.Usage.TurnUsage = .{
        .stream = .{
            .input_tokens = try optionalU64(object, "input"),
            .output_tokens = try optionalU64(object, "output"),
            .cached_tokens = try optionalU64(object, "cached"),
            .cache_write_tokens = try optionalU64(object, "cache_write"),
            .cache_write_1h_tokens = try optionalU64(object, "cache_write_1h"),
            .cost_usd = try optionalCost(object, "cost"),
        },
        .elapsed_ms = try optionalU64(object, "elapsed_ms"),
        .uncached_input_tokens = try optionalU64(object, "in_tokens"),
        .cost_input_usd = try optionalCost(object, "cost_in"),
        .cost_cache_read_usd = try optionalCost(object, "cost_cache_read"),
        .cost_cache_write_usd = try optionalCost(object, "cost_cache_write"),
        .cost_output_usd = try optionalCost(object, "cost_out"),
        .cost_total_usd = try optionalCost(object, "cost_total"),
        .cost_estimated = try optionalBool(object, "cost_estimated") orelse false,
    };
    errdefer usage.deinit(allocator);
    inline for (.{ "provider_label", "model_label", "effort", "served_model", "route", "response_id" }) |name| {
        @field(usage.provenance, name) = try dupeOptionalString(allocator, object, name);
    }
    // hax v1 reconstructs this for records written before `in_tokens` existed.
    if (usage.uncached_input_tokens == null) {
        const input = usage.stream.input_tokens orelse 0;
        const cached = usage.stream.cached_tokens orelse 0;
        const written = usage.stream.cache_write_tokens orelse 0;
        usage.uncached_input_tokens = input -| cached -| written;
    }
    return usage;
}

fn mutable(bytes: []const u8) []u8 {
    return @constCast(bytes);
}

fn expectGolden(item: ai.Item.Item, expected: []const u8) !void {
    const encoded = try encode(std.testing.allocator, item, .{});
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings(expected, encoded);

    var decoded = try decode(std.testing.allocator, expected, .{});
    defer decoded.deinit(std.testing.allocator);
    const roundtrip = try encode(std.testing.allocator, decoded, .{});
    defer std.testing.allocator.free(roundtrip);
    try std.testing.expectEqualStrings(expected, roundtrip);
}

test "hax v1 golden records cover every item kind" {
    var images = [_]ai.Item.Image{.{
        .mime = mutable("image/png"),
        .data_base64 = mutable("QUJD"),
        .width = 2,
        .height = 3,
    }};
    try expectGolden(.{ .user_message = .{
        .text = mutable("hello"),
        .images = &images,
        .origin = .compact_seed,
    } }, "{\"kind\":\"user\",\"text\":\"hello\",\"origin\":\"compact_seed\"," ++
        "\"images\":[{\"mime\":\"image/png\",\"data\":\"QUJD\",\"width\":2,\"height\":3}]}");
    try expectGolden(.{ .assistant_message = .{
        .text = mutable("partial"),
        .origin = .interrupted,
    } }, "{\"kind\":\"assistant\",\"text\":\"partial\",\"origin\":\"interrupted\"}");
    try expectGolden(.{ .tool_call = .{
        .id = mutable("call_1"),
        .name = mutable("read"),
        .arguments_json = mutable("{\"path\":\"a\"}"),
    } }, "{\"kind\":\"tool_call\",\"call_id\":\"call_1\",\"tool_name\":\"read\"," ++
        "\"arguments\":\"{\\\"path\\\":\\\"a\\\"}\"}");
    try expectGolden(.{ .tool_result = .{
        .call_id = mutable("call_1"),
        .output = mutable("abc..."),
        .hidden_tail_bytes = 3,
        .origin = .summarized,
    } }, "{\"kind\":\"tool_result\",\"call_id\":\"call_1\",\"output\":\"abc...\"," ++
        "\"output_hidden_tail\":3,\"origin\":\"summarized\"}");
    try expectGolden(.{ .reasoning = .{
        .opaque_json = mutable("{\"id\":1}"),
        .text = mutable("why"),
        .source = .{ .provider = "openai", .model = "o3" },
    } }, "{\"kind\":\"reasoning\",\"reasoning_json\":\"{\\\"id\\\":1}\"," ++
        "\"reasoning_text\":\"why\",\"provider\":\"openai\",\"model\":\"o3\"}");
    try expectGolden(.turn_boundary, "{\"kind\":\"turn_boundary\"}");
    try expectGolden(.{ .turn_usage = .{
        .value = .{
            .stream = .{ .input_tokens = 10, .output_tokens = 2, .cost_usd = 0.25 },
            .elapsed_ms = 8,
            .uncached_input_tokens = 7,
            .cost_total_usd = 0.25,
            .cost_estimated = true,
            .provenance = .{ .provider_label = mutable("OpenAI"), .response_id = mutable("resp") },
        },
        .source = .{ .provider = "openai", .model = "o3" },
    } }, "{\"kind\":\"turn_usage\",\"provider\":\"openai\",\"model\":\"o3\",\"usage\":{" ++
        "\"input\":10,\"output\":2,\"cost\":0.25,\"elapsed_ms\":8,\"in_tokens\":7," ++
        "\"cost_total\":0.25,\"cost_estimated\":true,\"provider_label\":\"OpenAI\"," ++
        "\"response_id\":\"resp\"}}");
}

test "external origins are omitted and unknown origins remain external" {
    try expectGolden(.{ .user_message = .{ .text = mutable("x") } }, "{\"kind\":\"user\",\"text\":\"x\"}");
    var decoded = try decode(std.testing.allocator, "{\"kind\":\"user\",\"text\":\"x\",\"origin\":\"future\"}", .{});
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(ai.Item.UserOrigin.external, decoded.user_message.origin);
}

test "legacy reasoning uses caller identity and usage reconstructs uncached input" {
    var reasoning = try decodeWithContext(
        std.testing.allocator,
        "{\"kind\":\"reasoning\",\"reasoning_text\":\"why\"}",
        .{},
        .{ .provider = "anthropic", .model = "claude" },
    );
    defer reasoning.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("anthropic", reasoning.reasoning.source.?.provider.?);

    const legacy_usage = "{\"kind\":\"turn_usage\",\"usage\":{" ++
        "\"input\":10,\"cached\":3,\"cache_write\":2}}";
    var usage = try decode(std.testing.allocator, legacy_usage, .{});
    defer usage.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u64, 5), usage.turn_usage.value.uncached_input_tokens);
}

test "decode rejects malformed, unsafe, and bounded records" {
    const hidden_tail = "{\"kind\":\"tool_result\",\"call_id\":\"c\"," ++
        "\"output\":\"x\",\"output_hidden_tail\":2}";
    const bad_image = "{\"kind\":\"user\",\"text\":\"x\",\"images\":[" ++
        "{\"mime\":\"image/png\",\"data\":\"***\"}]}";
    const extra = "{\"kind\":\"user\",\"text\":\"x\",\"extra\":1}";
    const empty_images = "{\"kind\":\"user\",\"text\":\"x\",\"images\":[]}";
    const user = "{\"kind\":\"user\",\"text\":\"x\"}";
    const boundary = "{\"kind\":\"turn_boundary\"}";

    try std.testing.expectError(error.UnknownKind, decode(std.testing.allocator, "{\"kind\":\"future\"}", .{}));
    try std.testing.expectError(error.MalformedItem, decode(std.testing.allocator, hidden_tail, .{}));
    try std.testing.expectError(error.MalformedItem, decode(std.testing.allocator, bad_image, .{}));
    var with_extra = try decode(std.testing.allocator, extra, .{});
    with_extra.deinit(std.testing.allocator);
    try std.testing.expectError(error.TooDeep, decode(std.testing.allocator, empty_images, .{ .max_nesting = 1 }));
    try std.testing.expectError(error.TooManyFields, decode(std.testing.allocator, user, .{ .max_fields = 1 }));
    try std.testing.expectError(error.LineTooLarge, decode(std.testing.allocator, boundary, .{ .max_line_bytes = 8 }));
}

fn exerciseCodecAllocations(allocator: std.mem.Allocator) !void {
    var image = [_]ai.Item.Image{.{
        .mime = mutable("image/png"),
        .data_base64 = mutable("QUJD"),
    }};
    const encoded = try encode(allocator, .{ .user_message = .{
        .text = mutable("hello"),
        .images = &image,
    } }, .{});
    allocator.free(encoded);

    var item = try decodeWithContext(
        allocator,
        "{\"kind\":\"reasoning\",\"reasoning_json\":\"{}\",\"reasoning_text\":\"why\"}",
        .{},
        .{ .provider = "p", .model = "m" },
    );
    item.deinit(allocator);

    const result_json = "{\"kind\":\"tool_result\",\"call_id\":\"c\",\"output\":\"ok\"," ++
        "\"images\":[{\"mime\":\"image/png\",\"data\":\"QUJD\"}]}";
    var result = try decode(allocator, result_json, .{});
    result.deinit(allocator);
}

test "decode frees every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseCodecAllocations, .{});
}

test "future fields and canonical-empty images remain readable" {
    var user = try decode(
        std.testing.allocator,
        "{\"kind\":\"user\",\"text\":\"hi\",\"images\":[],\"future\":{\"v\":1}}",
        .{},
    );
    defer user.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("hi", user.user_message.text);
    try std.testing.expectEqual(@as(usize, 0), user.user_message.images.len);

    var usage = try decode(
        std.testing.allocator,
        "{\"kind\":\"turn_usage\",\"usage\":{\"input\":1,\"future_counter\":2}," ++
            "\"future_top\":true}",
        .{},
    );
    defer usage.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 1), usage.turn_usage.value.stream.input_tokens.?);
}

test "optional nulls follow hax omission while malformed origins remain corruption" {
    var reasoning = try decodeWithContext(
        std.testing.allocator,
        "{\"kind\":\"reasoning\",\"reasoning_json\":null,\"reasoning_text\":null," ++
            "\"provider\":null,\"model\":null,\"future\":1}",
        .{},
        .{ .provider = "p", .model = "m" },
    );
    defer reasoning.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("p", reasoning.reasoning.source.?.provider.?);
    try std.testing.expect(reasoning.reasoning.text == null);

    var result = try decode(
        std.testing.allocator,
        "{\"kind\":\"tool_result\",\"call_id\":\"c\",\"output\":\"x\"," ++
            "\"output_hidden_tail\":null,\"images\":null,\"origin\":null}",
        .{},
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), result.tool_result.hidden_tail_bytes);
    var malformed_origin = try decode(
        std.testing.allocator,
        "{\"kind\":\"user\",\"text\":\"x\",\"origin\":1}",
        .{},
    );
    defer malformed_origin.deinit(std.testing.allocator);
    try std.testing.expectEqual(ai.Item.UserOrigin.external, malformed_origin.user_message.origin);
}

test "cost spelling MIME and total JSON work are bounded" {
    const usage: ai.Item.Item = .{ .turn_usage = .{ .value = .{
        .stream = .{ .cost_usd = 1.0 },
    } } };
    const encoded = try encode(std.testing.allocator, usage, .{});
    defer std.testing.allocator.free(encoded);
    try std.testing.expect(std.mem.find(u8, encoded, "\"cost\":1.0") != null);

    var invalid_mime = [_]ai.Item.Image{.{
        .mime = mutable("image/"),
        .data_base64 = mutable("QUJD"),
    }};
    try std.testing.expectError(error.InvalidItem, encode(
        std.testing.allocator,
        .{ .user_message = .{ .text = mutable("x"), .images = &invalid_mime } },
        .{},
    ));
    invalid_mime[0].mime = mutable("image/png");
    invalid_mime[0].data_base64 = mutable("");
    try std.testing.expectError(error.InvalidItem, encode(
        std.testing.allocator,
        .{ .user_message = .{ .text = mutable("x"), .images = &invalid_mime } },
        .{},
    ));

    const many = "[0,0,0,0]";
    try std.testing.expectError(error.TooMuchWork, decode(
        std.testing.allocator,
        "{\"kind\":\"turn_boundary\",\"future\":" ++ many ++ "}",
        .{ .max_tokens = 4 },
    ));
}

test "encode enforces the same JSON token and nesting work bounds" {
    try std.testing.expectError(error.TooMuchWork, encode(
        std.testing.allocator,
        .turn_boundary,
        .{ .max_tokens = 1 },
    ));
    var text = [_]u8{'x'};
    var mime = "image/png".*;
    var data = "YQ==".*;
    var images = [_]ai.Item.Image{.{ .mime = &mime, .data_base64 = &data }};
    try std.testing.expectError(error.TooDeep, encode(
        std.testing.allocator,
        .{ .user_message = .{ .text = &text, .images = &images } },
        .{ .max_nesting = 1 },
    ));
}

test "wrong-type origins follow hax external fallback after owned fields" {
    var assistant = try decode(
        std.testing.allocator,
        "{\"kind\":\"assistant\",\"text\":\"owned\",\"origin\":{}}",
        .{},
    );
    defer assistant.deinit(std.testing.allocator);
    try std.testing.expectEqual(ai.Item.AssistantOrigin.external, assistant.assistant_message.origin);

    var user = try decode(
        std.testing.allocator,
        "{\"kind\":\"user\",\"text\":\"x\",\"images\":[{\"mime\":\"image/png\",\"data\":\"YQ==\"}],\"origin\":false}",
        .{},
    );
    defer user.deinit(std.testing.allocator);
    try std.testing.expectEqual(ai.Item.UserOrigin.external, user.user_message.origin);
    try std.testing.expectEqual(@as(usize, 1), user.user_message.images.len);
}

test "duplicate persistence fields use the last value like hax" {
    var item = try decode(
        std.testing.allocator,
        "{\"kind\":\"user\",\"text\":\"old\",\"text\":\"new\"}",
        .{},
    );
    defer item.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("new", item.user_message.text);

    var changed_kind = try decode(
        std.testing.allocator,
        "{\"kind\":\"user\",\"kind\":\"assistant\",\"text\":\"x\"}",
        .{},
    );
    defer changed_kind.deinit(std.testing.allocator);
    try std.testing.expect(changed_kind == .assistant_message);
}
