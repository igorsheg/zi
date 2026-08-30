const std = @import("std");
const Effort = @import("Effort.zig");
const ModelMeta = @import("ModelMeta.zig");
const Wire = @import("Wire.zig").Wire;

pub const maximum_input_bytes: usize = 32 * 1024 * 1024;
pub const maximum_depth: usize = 64;
pub const maximum_tokens: usize = 1_048_576;
pub const maximum_string_bytes: usize = 64 * 1024;

pub const Limits = struct {
    max_input_bytes: usize = maximum_input_bytes,
    max_depth: usize = maximum_depth,
    max_tokens: usize = maximum_tokens,
    max_string_bytes: usize = maximum_string_bytes,
};

pub const Error = error{
    OutOfMemory,
    InvalidLimits,
    InvalidJson,
    InputTooLarge,
    NestingTooDeep,
    TooManyTokens,
    StringTooLong,
};

pub const WireHint = union(enum) {
    unknown,
    unsupported,
    wire: Wire,
};

/// One allocation-free, provider-neutral catalog contribution.
pub const Contribution = struct {
    metadata: ModelMeta.Metadata = .{},
    wire: WireHint = .unknown,

    pub fn hasMetadata(self: *const Contribution) bool {
        const value = &self.metadata;
        return value.context_window != 0 or value.max_output != 0 or
            value.image_input != .unknown or value.tools != .unknown or value.rates.input != null or
            value.rates.output != null or value.rates.cache_read != null or
            value.rates.cache_write != null or value.rates.cache_write_1h != null or
            value.tiers.count != 0 or value.efforts.known or
            value.reasoning_roundtrip != .unknown or value.wire != null or self.wire != .unknown;
    }
};

/// Looks up one exact models.dev provider and model without allocating a tree for
/// the full artifact. Returned metadata owns all variable data inline.
pub fn lookup(
    allocator: std.mem.Allocator,
    json: []const u8,
    provider_id: []const u8,
    model_id: []const u8,
    limits: Limits,
) Error!?Contribution {
    try validateLimits(limits);
    if (json.len > limits.max_input_bytes) return error.InputTooLarge;
    if (provider_id.len == 0 or model_id.len == 0) return null;
    const slice = try providerSlice(allocator, json, provider_id, limits) orelse return null;
    return lookupProviderSlice(allocator, slice, model_id, limits);
}

/// Fills contributions aligned with `model_ids`. The catalog is validated once
/// and the selected provider object is parsed once.
pub fn lookupBatch(
    allocator: std.mem.Allocator,
    json: []const u8,
    provider_id: []const u8,
    model_ids: []const []const u8,
    output: []Contribution,
    limits: Limits,
) Error!void {
    std.debug.assert(model_ids.len == output.len);
    for (output) |*value| value.* = .{};
    try validateLimits(limits);
    if (json.len > limits.max_input_bytes) return error.InputTooLarge;
    if (provider_id.len == 0 or model_ids.len == 0) return;
    const slice = try providerSlice(allocator, json, provider_id, limits) orelse return;
    try lookupProviderSliceBatch(allocator, slice, model_ids, output, limits);
}

/// Returns the borrowed JSON value slice for one exact top-level provider.
/// It scans structure without allocating the complete artifact.
pub fn providerSlice(
    allocator: std.mem.Allocator,
    json: []const u8,
    provider_id: []const u8,
    limits: Limits,
) Error!?[]const u8 {
    try validateLimits(limits);
    if (json.len > limits.max_input_bytes) return error.InputTooLarge;
    try validateBounds(allocator, json, limits);
    if (provider_id.len == 0) return null;
    return extractRootMember(allocator, json, provider_id, limits);
}

/// Parses a borrowed provider object slice in the pinned models.dev shape.
pub fn lookupProviderSlice(
    allocator: std.mem.Allocator,
    provider_json: []const u8,
    model_id: []const u8,
    limits: Limits,
) Error!?Contribution {
    try validateLimits(limits);
    if (provider_json.len > limits.max_input_bytes) return error.InputTooLarge;
    try validateBounds(allocator, provider_json, limits);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, provider_json, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .use_last,
        .max_value_len = limits.max_string_bytes,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    defer parsed.deinit();
    const provider = valueObject(parsed.value) orelse return null;
    const models = objectField(provider, "models") orelse return null;
    const model = valueObject(models.get(model_id) orelse return null) orelse return null;
    return parseContribution(provider, model, true);
}

/// Parses one borrowed provider object once and fills aligned inline results.
pub fn lookupProviderSliceBatch(
    allocator: std.mem.Allocator,
    provider_json: []const u8,
    model_ids: []const []const u8,
    output: []Contribution,
    limits: Limits,
) Error!void {
    std.debug.assert(model_ids.len == output.len);
    for (output) |*value| value.* = .{};
    try validateLimits(limits);
    if (provider_json.len > limits.max_input_bytes) return error.InputTooLarge;
    try validateBounds(allocator, provider_json, limits);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, provider_json, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .use_last,
        .max_value_len = limits.max_string_bytes,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    defer parsed.deinit();
    const provider = valueObject(parsed.value) orelse return;
    const models = objectField(provider, "models") orelse return;
    for (model_ids, output) |model_id, *destination| {
        if (model_id.len == 0) continue;
        const model = valueObject(models.get(model_id) orelse continue) orelse continue;
        destination.* = parseContribution(provider, model, true);
    }
}

/// Parses a configuration override artifact. Provider members may contain a
/// direct model map or the models.dev `{ "models": ... }` wrapper.
pub fn lookupOverride(
    allocator: std.mem.Allocator,
    json: []const u8,
    provider_id: []const u8,
    model_id: []const u8,
    limits: Limits,
) Error!?Contribution {
    try validateLimits(limits);
    if (json.len > limits.max_input_bytes) return error.InputTooLarge;
    const slice = try providerSlice(allocator, json, provider_id, limits) orelse return null;
    try validateBounds(allocator, slice, limits);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, slice, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .use_last,
        .max_value_len = limits.max_string_bytes,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    defer parsed.deinit();
    const provider = valueObject(parsed.value) orelse return null;
    const models = objectField(provider, "models") orelse provider;
    const model = valueObject(models.get(model_id) orelse return null) orelse return null;
    return parseContribution(provider, model, false);
}

pub fn lookupOverrideBatch(
    allocator: std.mem.Allocator,
    json: []const u8,
    provider_id: []const u8,
    model_ids: []const []const u8,
    output: []Contribution,
    limits: Limits,
) Error!void {
    std.debug.assert(model_ids.len == output.len);
    for (output) |*value| value.* = .{};
    try validateLimits(limits);
    if (json.len > limits.max_input_bytes) return error.InputTooLarge;
    if (provider_id.len == 0 or model_ids.len == 0) return;
    const slice = try providerSlice(allocator, json, provider_id, limits) orelse return;
    try validateBounds(allocator, slice, limits);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, slice, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .use_last,
        .max_value_len = limits.max_string_bytes,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    defer parsed.deinit();
    const provider = valueObject(parsed.value) orelse return;
    const models = objectField(provider, "models") orelse provider;
    for (model_ids, output) |model_id, *destination| {
        if (model_id.len == 0) continue;
        const model = valueObject(models.get(model_id) orelse continue) orelse continue;
        destination.* = parseContribution(provider, model, false);
    }
}

/// Configuration wins field by field. Declared empty tier and effort lists win.
pub fn merge(config: ?*const Contribution, cache: ?*const Contribution) Contribution {
    var result: Contribution = if (config) |value| value.* else .{};
    const fallback = cache orelse return result;
    const destination = &result.metadata;
    const source = &fallback.metadata;
    if (destination.context_window == 0) destination.context_window = source.context_window;
    if (destination.max_output == 0) destination.max_output = source.max_output;
    if (destination.image_input == .unknown) destination.image_input = source.image_input;
    if (destination.tools == .unknown) destination.tools = source.tools;
    if (!destination.efforts.known) destination.efforts = source.efforts;
    if (destination.wire == null and !(config != null and config.?.wire == .unsupported)) {
        destination.wire = source.wire;
    }
    if (destination.reasoning_roundtrip == .unknown) {
        destination.reasoning_roundtrip = source.reasoning_roundtrip;
    }
    fillRates(&destination.rates, source.rates);
    if (!destination.tiers.known) destination.tiers = source.tiers;
    if (result.wire == .unknown) result.wire = fallback.wire;
    if (result.wire == .unsupported) destination.wire = null;
    return result;
}

fn parseContribution(provider: std.json.ObjectMap, model: std.json.ObjectMap, map_npm: bool) Contribution {
    var result: Contribution = .{};
    const metadata = &result.metadata;
    if (objectField(model, "cost")) |cost| {
        metadata.rates = parseRates(cost);
        if (cost.get("tiers")) |tiers| parseTiers(&metadata.tiers, tiers);
    }
    if (objectField(model, "limit")) |limit| {
        metadata.context_window = parseTokens(limit.get("context"));
        metadata.max_output = parseTokens(limit.get("output"));
    }
    parseModalities(&metadata.image_input, model.get("modalities"));
    metadata.tools = parseSupport(model.get("tool_call"));
    parseEfforts(&metadata.efforts, model);
    metadata.reasoning_roundtrip = parseInterleaved(model.get("interleaved"));

    if (stringField(model, "api")) |api| {
        result.wire = apiHint(api);
    } else if (map_npm) {
        const override = objectField(model, "provider");
        const npm = if (override) |object| stringField(object, "npm") else null;
        if (npm orelse stringField(provider, "npm")) |selector| result.wire = npmHint(selector);
    }
    switch (result.wire) {
        .wire => |wire| metadata.wire = wire,
        .unknown, .unsupported => {},
    }
    return result;
}

fn parseRates(object: std.json.ObjectMap) ModelMeta.Rates {
    return .{
        .input = parseRate(object.get("input")),
        .output = parseRate(object.get("output")),
        .cache_read = parseRate(object.get("cache_read")),
        .cache_write = parseRate(object.get("cache_write")),
        .cache_write_1h = parseRate(object.get("cache_write_1h")),
    };
}

fn parseRate(value: ?std.json.Value) ?f64 {
    const item = value orelse return null;
    const number = switch (item) {
        .integer => |integer| @as(f64, @floatFromInt(integer)),
        .float => |float| float,
        .string => |text| std.fmt.parseFloat(f64, text) catch return null,
        else => return null,
    };
    return if (number >= 0 and std.math.isFinite(number)) number else null;
}

fn parseTokens(value: ?std.json.Value) u64 {
    const item = value orelse return 0;
    return switch (item) {
        .integer => |integer| if (integer > 0) @intCast(integer) else 0,
        .string => |text| parseSize(text),
        else => 0,
    };
}

fn parseSize(text: []const u8) u64 {
    var cursor: usize = 0;
    while (cursor < text.len and isCWhitespace(text[cursor])) cursor += 1;
    if (cursor == text.len) return 0;
    var negative = false;
    if (text[cursor] == '+' or text[cursor] == '-') {
        negative = text[cursor] == '-';
        cursor += 1;
    }
    const digits_start = cursor;
    while (cursor < text.len and std.ascii.isDigit(text[cursor])) cursor += 1;
    if (cursor == digits_start or negative) return 0;
    const base = std.fmt.parseInt(u64, text[digits_start..cursor], 10) catch return 0;
    if (base == 0 or base > std.math.maxInt(i64)) return 0;
    while (cursor < text.len and (text[cursor] == ' ' or text[cursor] == '\t')) cursor += 1;
    var multiplier: u64 = 1;
    if (cursor < text.len) {
        multiplier = switch (text[cursor]) {
            'k', 'K' => 1024,
            'm', 'M' => 1024 * 1024,
            else => 1,
        };
        if (multiplier != 1) cursor += 1;
    }
    while (cursor < text.len and (text[cursor] == ' ' or text[cursor] == '\t')) cursor += 1;
    if (cursor != text.len or base > @as(u64, std.math.maxInt(i64)) / multiplier) return 0;
    return base * multiplier;
}

fn isCWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == 0x0b or byte == 0x0c;
}

fn parseTiers(destination: *ModelMeta.Tiers, value: std.json.Value) void {
    if (value != .array) return;
    destination.known = true;
    for (value.array.items) |tier_value| {
        if (destination.count >= ModelMeta.maximum_tiers) break;
        const tier = valueObject(tier_value) orelse continue;
        const selector = objectField(tier, "tier") orelse continue;
        const kind = stringField(selector, "type") orelse continue;
        if (!std.mem.eql(u8, kind, "context")) continue;
        const threshold = parseTokens(selector.get("size"));
        if (threshold == 0) continue;
        destination.add(.{ .context_threshold = threshold, .rates = parseRates(tier) }) catch continue;
    }
}

fn parseModalities(destination: *ModelMeta.Support, value: ?std.json.Value) void {
    const modalities = valueObject(value orelse return) orelse return;
    const input = modalities.get("input") orelse return;
    if (input != .array) return;
    destination.* = .no;
    for (input.array.items) |item| switch (item) {
        .string => |text| if (std.mem.eql(u8, text, "image")) {
            destination.* = .yes;
            return;
        },
        else => {},
    };
}

fn parseSupport(value: ?std.json.Value) ModelMeta.Support {
    return switch (value orelse return .unknown) {
        .bool => |supported| if (supported) .yes else .no,
        else => .unknown,
    };
}

fn parseEfforts(destination: *Effort.Set, model: std.json.ObjectMap) void {
    if (model.get("reasoning")) |reasoning| if (reasoning == .bool and !reasoning.bool) {
        destination.known = true;
        return;
    };
    const options = model.get("reasoning_options") orelse return;
    if (options != .array or options.array.items.len == 0) return;
    for (options.array.items) |option_value| {
        const option = valueObject(option_value) orelse continue;
        const kind = stringField(option, "type") orelse continue;
        if (!std.mem.eql(u8, kind, "effort")) continue;
        const values = option.get("values") orelse continue;
        if (values != .array) continue;
        for (values.array.items) |item| switch (item) {
            .string => |text| {
                if (text.len == 0 or text.len > Effort.maximum_value_bytes) continue;
                if (!destination.has(text) and destination.count >= Effort.maximum_levels) continue;
                destination.add(text) catch unreachable;
            },
            else => {},
        };
    }
    destination.known = true;
}

fn parseInterleaved(value: ?std.json.Value) ModelMeta.ReasoningRoundtrip {
    const item = value orelse return .unknown;
    if (item == .bool and !item.bool) return .none;
    const text = switch (item) {
        .string => |string| string,
        .object => |object| stringField(object, "field") orelse return .unknown,
        else => return .unknown,
    };
    if (std.ascii.eqlIgnoreCase(text, "reasoning")) return .{ .field = .reasoning };
    if (std.ascii.eqlIgnoreCase(text, "reasoning_content")) return .{ .field = .reasoning_content };
    return .unknown;
}

fn npmHint(selector: []const u8) WireHint {
    if (std.mem.eql(u8, selector, "@ai-sdk/openai-compatible")) return .{ .wire = .openai_chat };
    if (std.mem.eql(u8, selector, "@ai-sdk/openai")) return .{ .wire = .openai_responses };
    if (std.mem.eql(u8, selector, "@ai-sdk/anthropic")) return .{ .wire = .anthropic_messages };
    return .unsupported;
}

fn apiHint(api: []const u8) WireHint {
    if (std.ascii.eqlIgnoreCase(api, "openai-completions")) return .{ .wire = .openai_chat };
    if (std.ascii.eqlIgnoreCase(api, "openai-responses")) return .{ .wire = .openai_responses };
    if (std.ascii.eqlIgnoreCase(api, "anthropic-messages")) return .{ .wire = .anthropic_messages };
    return .unsupported;
}

fn fillRates(destination: *ModelMeta.Rates, fallback: ModelMeta.Rates) void {
    if (destination.input == null) destination.input = fallback.input;
    if (destination.output == null) destination.output = fallback.output;
    if (destination.cache_read == null) destination.cache_read = fallback.cache_read;
    if (destination.cache_write == null) destination.cache_write = fallback.cache_write;
    if (destination.cache_write_1h == null) destination.cache_write_1h = fallback.cache_write_1h;
}

fn valueObject(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => null,
    };
}

fn objectField(object: std.json.ObjectMap, name: []const u8) ?std.json.ObjectMap {
    return valueObject(object.get(name) orelse return null);
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    return switch (object.get(name) orelse return null) {
        .string => |text| text,
        else => null,
    };
}

const Slice = struct { start: usize, end: usize };

fn extractRootMember(
    allocator: std.mem.Allocator,
    json: []const u8,
    key: []const u8,
    limits: Limits,
) Error!?[]const u8 {
    var cursor = skipWhitespace(json, 0);
    if (cursor >= json.len or json[cursor] != '{') return error.InvalidJson;
    cursor = skipWhitespace(json, cursor + 1);
    if (cursor < json.len and json[cursor] == '}') return null;
    var found: ?Slice = null;
    while (cursor < json.len) {
        const key_slice = try scanString(json, cursor);
        cursor = skipWhitespace(json, key_slice.end);
        if (cursor >= json.len or json[cursor] != ':') return error.InvalidJson;
        cursor = skipWhitespace(json, cursor + 1);
        const value = try scanValue(json, cursor, limits.max_depth);
        if (try decodedKeyEquals(allocator, json[key_slice.start..key_slice.end], key, limits)) {
            found = value;
        }
        cursor = skipWhitespace(json, value.end);
        if (cursor >= json.len) return error.InvalidJson;
        if (json[cursor] == '}') return if (found) |slice| json[slice.start..slice.end] else null;
        if (json[cursor] != ',') return error.InvalidJson;
        cursor = skipWhitespace(json, cursor + 1);
    }
    return error.InvalidJson;
}

fn decodedKeyEquals(
    allocator: std.mem.Allocator,
    quoted: []const u8,
    expected: []const u8,
    limits: Limits,
) Error!bool {
    var scanner = std.json.Scanner.initCompleteInput(allocator, quoted);
    defer scanner.deinit();
    const token = scanner.nextAllocMax(allocator, .alloc_if_needed, limits.max_string_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ValueTooLong => return error.StringTooLong,
        else => return error.InvalidJson,
    };
    defer switch (token) {
        .allocated_string => |text| allocator.free(text),
        .allocated_number => |text| allocator.free(text),
        else => {},
    };
    return switch (token) {
        .string => |text| std.mem.eql(u8, text, expected),
        .allocated_string => |text| std.mem.eql(u8, text, expected),
        else => error.InvalidJson,
    };
}

fn scanValue(json: []const u8, start: usize, max_depth: usize) Error!Slice {
    if (start >= json.len) return error.InvalidJson;
    if (json[start] == '"') return scanString(json, start);
    if (json[start] != '{' and json[start] != '[') {
        var end = start;
        while (end < json.len and std.mem.indexOfScalar(u8, ",}] \t\r\n", json[end]) == null) end += 1;
        if (end == start) return error.InvalidJson;
        return .{ .start = start, .end = end };
    }
    var cursor = start;
    var depth: usize = 0;
    while (cursor < json.len) {
        if (json[cursor] == '"') {
            cursor = (try scanString(json, cursor)).end;
            continue;
        }
        if (json[cursor] == '{' or json[cursor] == '[') {
            depth += 1;
            if (depth > max_depth) return error.NestingTooDeep;
        } else if (json[cursor] == '}' or json[cursor] == ']') {
            if (depth == 0) return error.InvalidJson;
            depth -= 1;
            if (depth == 0) return .{ .start = start, .end = cursor + 1 };
        }
        cursor += 1;
    }
    return error.InvalidJson;
}

fn scanString(json: []const u8, start: usize) Error!Slice {
    if (start >= json.len or json[start] != '"') return error.InvalidJson;
    var cursor = start + 1;
    while (cursor < json.len) : (cursor += 1) {
        if (json[cursor] == '\\') {
            cursor += 1;
            if (cursor >= json.len) return error.InvalidJson;
        } else if (json[cursor] == '"') {
            return .{ .start = start, .end = cursor + 1 };
        }
    }
    return error.InvalidJson;
}

fn skipWhitespace(json: []const u8, start: usize) usize {
    var cursor = start;
    while (cursor < json.len and (json[cursor] == ' ' or json[cursor] == '\t' or
        json[cursor] == '\r' or json[cursor] == '\n')) cursor += 1;
    return cursor;
}

fn validateLimits(limits: Limits) Error!void {
    if (limits.max_input_bytes == 0 or limits.max_input_bytes > maximum_input_bytes or
        limits.max_depth == 0 or limits.max_depth > maximum_depth or
        limits.max_tokens == 0 or limits.max_tokens > maximum_tokens or
        limits.max_string_bytes == 0 or limits.max_string_bytes > maximum_string_bytes)
    {
        return error.InvalidLimits;
    }
}

fn validateBounds(allocator: std.mem.Allocator, json: []const u8, limits: Limits) Error!void {
    var scanner = std.json.Scanner.initCompleteInput(allocator, json);
    defer scanner.deinit();
    var depth: usize = 0;
    var tokens: usize = 0;
    while (true) {
        const token_type = scanner.peekNextTokenType() catch return error.InvalidJson;
        const maximum = if (token_type == .string) limits.max_string_bytes else json.len;
        const token = scanner.nextAllocMax(allocator, .alloc_if_needed, maximum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ValueTooLong => return error.StringTooLong,
            else => return error.InvalidJson,
        };
        defer switch (token) {
            .allocated_string => |text| allocator.free(text),
            .allocated_number => |text| allocator.free(text),
            else => {},
        };
        if (token == .end_of_document) {
            if (depth != 0) return error.InvalidJson;
            return;
        }
        tokens += 1;
        if (tokens > limits.max_tokens) return error.TooManyTokens;
        switch (token) {
            .object_begin, .array_begin => {
                depth += 1;
                if (depth > limits.max_depth) return error.NestingTooDeep;
            },
            .object_end, .array_end => {
                if (depth == 0) return error.InvalidJson;
                depth -= 1;
            },
            .string => |text| if (text.len > limits.max_string_bytes) return error.StringTooLong,
            .allocated_string => |text| if (text.len > limits.max_string_bytes) return error.StringTooLong,
            else => {},
        }
    }
}

test "models.dev mapping fields tiers and malformed values" {
    const fixture =
        "{\"openai\":{\"npm\":\"@ai-sdk/openai\",\"models\":{" ++
        "\"good\":{\"provider\":{\"npm\":\"@ai-sdk/anthropic\"}," ++
        "\"cost\":{\"input\":2,\"output\":\"8.5\",\"cache_read\":-1," ++
        "\"tiers\":[{\"input\":4,\"tier\":{\"type\":\"context\",\"size\":\"200k\"}}," ++
        "{\"tier\":{\"type\":\"tokens_per_day\",\"size\":2}}]}," ++
        "\"limit\":{\"context\":\"256k\",\"output\":100000}," ++
        "\"modalities\":{\"input\":[\"text\",\"image\"]}," ++
        "\"reasoning_options\":[{\"type\":\"effort\",\"values\":[\"low\",7,\"high\"]}]," ++
        "\"interleaved\":{\"field\":\"REASONING_CONTENT\"}}," ++
        "\"bad\":{\"cost\":{\"input\":{},\"output\":-2}," ++
        "\"limit\":{\"context\":0,\"output\":1.5}}}}}";
    const found = (try lookup(std.testing.allocator, fixture, "openai", "good", .{})).?;
    try std.testing.expect(found.wire == .wire);
    try std.testing.expectEqual(Wire.anthropic_messages, found.wire.wire);
    try std.testing.expectEqual(Wire.anthropic_messages, found.metadata.wire.?);
    try std.testing.expectEqual(@as(f64, 2), found.metadata.rates.input.?);
    try std.testing.expectEqual(@as(u64, 256 * 1024), found.metadata.context_window);
    try std.testing.expectEqual(ModelMeta.Support.yes, found.metadata.image_input);
    try std.testing.expectEqual(@as(u8, 2), found.metadata.efforts.count);
    try std.testing.expectEqual(@as(u8, 1), found.metadata.tiers.count);
    try std.testing.expectEqual(@as(u64, 200 * 1024), found.metadata.tiers.at(0).context_threshold);
    try std.testing.expect(found.metadata.reasoning_roundtrip == .field);
    const bad = (try lookup(std.testing.allocator, fixture, "openai", "bad", .{})).?;
    try std.testing.expect(bad.metadata.rates.input == null);
    try std.testing.expectEqual(@as(u64, 0), bad.metadata.max_output);
}

fn batchAllocationExercise(allocator: std.mem.Allocator) !void {
    const fixture =
        "{\"p\":{\"models\":{" ++
        "\"a\":{\"limit\":{\"context\":100}}," ++
        "\"b\":{\"tool_call\":false}}}}";
    const ids = [_][]const u8{ "b", "missing", "a", "b" };
    var batch: [ids.len]Contribution = undefined;
    try lookupBatch(allocator, fixture, "p", &ids, &batch, .{});
    for (ids, batch) |model_id, contribution| {
        const scalar = try lookup(allocator, fixture, "p", model_id, .{});
        if (scalar) |value| {
            try std.testing.expectEqualDeep(value, contribution);
        } else {
            const empty: Contribution = .{};
            try std.testing.expectEqualDeep(empty, contribution);
        }
    }
    try std.testing.expectEqual(ModelMeta.Support.no, batch[0].metadata.tools);
    try std.testing.expectEqual(@as(u64, 100), batch[2].metadata.context_window);
}

test "batch lookup is aligned and equivalent to scalar lookup" {
    try batchAllocationExercise(std.testing.allocator);
}

test "batch lookup reports every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, batchAllocationExercise, .{});
}

test "wire selectors image and reasoning tri-states" {
    const fixture =
        "{\"p\":{\"npm\":\"unknown-sdk\",\"models\":{" ++
        "\"text\":{\"modalities\":{\"input\":[\"text\"]},\"reasoning\":false,\"interleaved\":false}," ++
        "\"unknown\":{},\"chat\":{\"provider\":{\"npm\":\"@ai-sdk/openai-compatible\"}}}}}";
    const text = (try lookup(std.testing.allocator, fixture, "p", "text", .{})).?;
    try std.testing.expect(text.wire == .unsupported);
    try std.testing.expectEqual(ModelMeta.Support.no, text.metadata.image_input);
    try std.testing.expect(text.metadata.efforts.known);
    try std.testing.expect(text.metadata.reasoning_roundtrip == .none);
    const unknown = (try lookup(std.testing.allocator, fixture, "p", "unknown", .{})).?;
    try std.testing.expectEqual(ModelMeta.Support.unknown, unknown.metadata.image_input);
    try std.testing.expect(!unknown.metadata.efforts.known);
    const chat = (try lookup(std.testing.allocator, fixture, "p", "chat", .{})).?;
    try std.testing.expectEqual(Wire.openai_chat, chat.wire.wire);
}

test "catalog merge honors declared empty lists" {
    const config: Contribution = .{ .metadata = .{
        .rates = .{ .input = 9 },
        .tiers = try ModelMeta.Tiers.init(&.{}),
        .efforts = try Effort.Set.init(&.{}),
    } };
    const cache: Contribution = .{ .metadata = .{
        .context_window = 100,
        .rates = .{ .input = 2, .output = 8 },
        .tiers = try ModelMeta.Tiers.init(&.{.{ .context_threshold = 10 }}),
        .efforts = try Effort.Set.init(&.{"high"}),
    }, .wire = .{ .wire = .openai_responses } };
    const result = merge(&config, &cache);
    try std.testing.expectEqual(@as(f64, 9), result.metadata.rates.input.?);
    try std.testing.expectEqual(@as(f64, 8), result.metadata.rates.output.?);
    try std.testing.expectEqual(@as(u64, 100), result.metadata.context_window);
    try std.testing.expect(result.metadata.tiers.known);
    try std.testing.expectEqual(@as(u8, 0), result.metadata.tiers.count);
    try std.testing.expectEqual(@as(u8, 0), result.metadata.efforts.count);
    try std.testing.expectEqual(Wire.openai_responses, result.wire.wire);
}

test "provider fixture slices and explicit structural bounds" {
    const fixture = "{\"skip\":{\"x\":[1,2]},\"p\":{\"models\":{\"m\":{\"limit\":{\"context\":1}}}}}";
    const slice = (try providerSlice(std.testing.allocator, fixture, "p", .{})).?;
    const found = (try lookupProviderSlice(std.testing.allocator, slice, "m", .{})).?;
    try std.testing.expectEqual(@as(u64, 1), found.metadata.context_window);
    try std.testing.expectError(error.InputTooLarge, lookup(
        std.testing.allocator,
        fixture,
        "p",
        "m",
        .{ .max_input_bytes = fixture.len - 1 },
    ));
    try std.testing.expectError(error.NestingTooDeep, lookupProviderSlice(
        std.testing.allocator,
        "{\"models\":{\"m\":{}}}",
        "m",
        .{ .max_depth = 2 },
    ));
    try std.testing.expectError(error.TooManyTokens, lookupProviderSlice(
        std.testing.allocator,
        "{\"models\":{\"m\":{}}}",
        "m",
        .{ .max_tokens = 2 },
    ));
}

test "lookup reports allocation failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, lookupProviderSlice(
        failing.allocator(),
        "{\"models\":{\"m\":{}}}",
        "m",
        .{},
    ));
}

test "whole artifact validation covers skipped providers and root locator semantics" {
    const malformed = [_][]const u8{
        "{\"p\":{\"models\":{\"m\":{}}}} trailing",
        "{\"skip\":[},\"p\":{\"models\":{\"m\":{}}}}",
        "{\"p\":{\"models\":{\"m\":{}}},\"bad\":}",
    };
    for (malformed) |json| {
        try std.testing.expectError(error.InvalidJson, lookup(std.testing.allocator, json, "p", "m", .{}));
    }

    const escaped_duplicate =
        "{\"p\":{\"models\":{\"m\":{\"limit\":{\"context\":1}}}}," ++
        "\"\\u0070\":{\"models\":{\"m\":{\"limit\":{\"context\":2}}}}}";
    const slice = (try providerSlice(std.testing.allocator, escaped_duplicate, "p", .{})).?;
    const found = (try lookupProviderSlice(std.testing.allocator, slice, "m", .{})).?;
    try std.testing.expectEqual(@as(u64, 2), found.metadata.context_window);

    const skipped_long =
        "{\"skip\":\"abcdefgh\",\"p\":{\"models\":{\"m\":{}}}}";
    try std.testing.expectError(error.StringTooLong, lookup(
        std.testing.allocator,
        skipped_long,
        "p",
        "m",
        .{ .max_string_bytes = 4 },
    ));
    const skipped_work =
        "{\"skip\":[1,2,3,4,5],\"p\":{\"models\":{\"m\":{}}}}";
    try std.testing.expectError(error.TooManyTokens, lookup(
        std.testing.allocator,
        skipped_work,
        "p",
        "m",
        .{ .max_tokens = 8 },
    ));
}

test "tool support is tri-state and tools-only metadata resolves" {
    const fixture =
        "{\"p\":{\"models\":{" ++
        "\"yes\":{\"tool_call\":true}," ++
        "\"no\":{\"tool_call\":false}," ++
        "\"unknown\":{\"tool_call\":\"yes\"}}}}";
    const yes = (try lookup(std.testing.allocator, fixture, "p", "yes", .{})).?;
    try std.testing.expectEqual(ModelMeta.Support.yes, yes.metadata.tools);
    try std.testing.expect(yes.hasMetadata());
    const no = (try lookup(std.testing.allocator, fixture, "p", "no", .{})).?;
    try std.testing.expectEqual(ModelMeta.Support.no, no.metadata.tools);
    try std.testing.expect(no.hasMetadata());
    const unknown = (try lookup(std.testing.allocator, fixture, "p", "unknown", .{})).?;
    try std.testing.expectEqual(ModelMeta.Support.unknown, unknown.metadata.tools);
    try std.testing.expect(!unknown.hasMetadata());

    const declared_empty: Contribution = .{ .metadata = .{
        .tiers = try ModelMeta.Tiers.init(&.{}),
    } };
    try std.testing.expect(!declared_empty.hasMetadata());
}

test "config ignores npm aliases are unsupported and unsupported blocks wire fallback" {
    const config_json =
        "{\"p\":{\"npm\":\"@ai-sdk/openai\",\"m\":{" ++
        "\"provider\":{\"npm\":\"@ai-sdk/anthropic\"},\"api\":\"responses\"}}}";
    const config = (try lookupOverride(std.testing.allocator, config_json, "p", "m", .{})).?;
    try std.testing.expect(config.wire == .unsupported);
    try std.testing.expect(config.metadata.wire == null);

    const npm_only =
        "{\"p\":{\"npm\":\"@ai-sdk/openai\",\"m\":{" ++
        "\"provider\":{\"npm\":\"@ai-sdk/anthropic\"}}}}";
    const ignored = (try lookupOverride(std.testing.allocator, npm_only, "p", "m", .{})).?;
    try std.testing.expect(ignored.wire == .unknown);

    const cache: Contribution = .{
        .metadata = .{ .wire = .openai_responses },
        .wire = .{ .wire = .openai_responses },
    };
    const merged = merge(&config, &cache);
    try std.testing.expect(merged.wire == .unsupported);
    try std.testing.expect(merged.metadata.wire == null);
}

test "size strings match bounded strtol suffix grammar" {
    try std.testing.expectEqual(@as(u64, 1024), parseSize(" +1k\t"));
    try std.testing.expectEqual(@as(u64, 2 * 1024 * 1024), parseSize("\n2M"));
    try std.testing.expectEqual(@as(u64, 0), parseSize("3g"));
    try std.testing.expectEqual(@as(u64, 0), parseSize("-1k"));
    try std.testing.expectEqual(@as(u64, 0), parseSize("1kb"));
    try std.testing.expectEqual(@as(u64, 0), parseSize("1k\n"));
    try std.testing.expectEqual(@as(u64, 0), parseSize("9223372036854775808"));
    try std.testing.expectEqual(@as(u64, 0), parseSize("9223372036854775807k"));
}

fn exerciseLookupAllocations(allocator: std.mem.Allocator) !void {
    const fixture =
        "{\"skip\":{\"nested\":[\"escaped\\nstring\"]}," ++
        "\"\\u0070\":{\"npm\":\"@ai-sdk/openai\",\"models\":{" ++
        "\"m\":{\"reasoning_options\":[{\"type\":\"effort\",\"values\":[\"low\"]}]}}}}";
    const found = (try lookup(allocator, fixture, "p", "m", .{})).?;
    try std.testing.expectEqual(Wire.openai_responses, found.metadata.wire.?);
}

fn exerciseProviderSliceAllocations(allocator: std.mem.Allocator) !void {
    const fixture = "{\"\\u0070\":{\"models\":{\"m\":{}}}}";
    const slice = (try providerSlice(allocator, fixture, "p", .{})).?;
    const found = (try lookupProviderSlice(allocator, slice, "m", .{})).?;
    try std.testing.expect(!found.hasMetadata());
}

fn exerciseOverrideAllocations(allocator: std.mem.Allocator) !void {
    const fixture = "{\"\\u0070\":{\"m\":{\"cost\":{\"input\":1}}}}";
    const found = (try lookupOverride(allocator, fixture, "p", "m", .{})).?;
    try std.testing.expectEqual(@as(f64, 1), found.metadata.rates.input.?);
}

test "all catalog allocation sites clean up on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseLookupAllocations, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseProviderSliceAllocations, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseOverrideAllocations, .{});
}
