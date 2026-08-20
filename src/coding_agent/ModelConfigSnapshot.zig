const std = @import("std");
const bounded_json = @import("../BoundedJson.zig");
const ai = @import("../ai/root.zig");
const ai_catalog = ai.model_catalog;
const ai_protocol = ai.protocol_api;
const ai_protocols = ai.protocols;
const ai_settings = ai.settings;
const ModelConfig = @import("ModelConfig.zig");
const ZiPaths = @import("ZiPaths.zig");

const ModelConfigSnapshot = @This();

const models_file_name = "models.json";
const max_document_bytes = 1024 * 1024;
const max_value_bytes = 32 * 1024;
const max_json_depth = 32;
const max_collection_items = 4096;
const max_custom_providers = 30;
const max_models_per_provider = 64;
const max_custom_models = 256;
const max_cost_tiers = 16;
const max_provider_id_bytes = 256;
const max_provider_name_bytes = 256;
const max_model_id_bytes = 512;
const max_model_name_bytes = 512;
const max_endpoint_bytes = 8 * 1024;

pub const Diagnostic = enum {
    unreadable,
    too_large,
    invalid,
};

pub const LoadError = error{
    OutOfMemory,
    Cancelled,
};

const Source = struct {
    providers: std.json.ArrayHashMap(SourceProvider),
};

const SourceProvider = struct {
    name: ?[]const u8 = null,
    baseUrl: []const u8,
    protocol: []const u8,
    models: []const SourceModel,
    compat: ?Compat = null,
};

const SourceModel = struct {
    id: []const u8,
    name: ?[]const u8 = null,
    protocol: ?[]const u8 = null,
    baseUrl: ?[]const u8 = null,
    reasoning: bool = false,
    thinkingLevelMap: ?ThinkingLevelMap = null,
    input: []const Input = &.{.text},
    cost: ?Cost = null,
    contextWindow: u64 = 128_000,
    maxTokens: u64 = 16_384,
    compat: ?Compat = null,
};

const Input = enum {
    text,
    image,
};

const ThinkingLevelMap = struct {
    off: ThinkingMapping = .inherited,
    minimal: ThinkingMapping = .inherited,
    low: ThinkingMapping = .inherited,
    medium: ThinkingMapping = .inherited,
    high: ThinkingMapping = .inherited,
    xhigh: ThinkingMapping = .inherited,
    max: ThinkingMapping = .inherited,
};

const ThinkingMapping = union(enum) {
    inherited,
    unsupported,
    mapped: []const u8,

    // ziglint-ignore: Z012 -- std.json requires a public hook on this private wire type.
    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !ThinkingMapping {
        const token = try source.nextAlloc(allocator, options.allocate.?);
        return switch (token) {
            .null => .unsupported,
            inline .string, .allocated_string => |value| .{ .mapped = value },
            else => error.UnexpectedToken,
        };
    }
};

const Cost = struct {
    input: f64,
    output: f64,
    cacheRead: f64,
    cacheWrite: f64,
    tiers: []const CostTier = &.{},
};

const CostTier = struct {
    inputTokensAbove: u64,
    input: f64,
    output: f64,
    cacheRead: f64,
    cacheWrite: f64,
};

const Compat = struct {
    supportsStrictMode: ?bool = null,
    supportsOpenAIGrammarTools: ?bool = null,
};

arena: std.heap.ArenaAllocator,
state: State,

const State = union(enum) {
    builtin: ?Diagnostic,
    configured: ModelConfig,
};

pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    paths: *const ZiPaths,
) LoadError!ModelConfigSnapshot {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const directory = std.Io.Dir.openDirAbsolute(io, paths.global_agent, .{}) catch |failure| {
        return switch (failure) {
            error.Canceled => error.Cancelled,
            error.FileNotFound => settled(arena, null),
            else => settled(arena, .unreadable),
        };
    };
    defer directory.close(io);
    const source_text = directory.readFileAlloc(
        io,
        models_file_name,
        allocator,
        .limited(max_document_bytes),
    ) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Cancelled,
        error.FileNotFound => settled(arena, null),
        error.StreamTooLong => settled(arena, .too_large),
        else => settled(arena, .unreadable),
    };
    defer allocator.free(source_text);

    preflightJson(allocator, source_text) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidModelsFile => settled(arena, .invalid),
    };
    const source = std.json.parseFromSliceLeaky(Source, arena.allocator(), source_text, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
        .max_value_len = max_value_bytes,
    }) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        else => settled(arena, .invalid),
    };
    const config = compose(arena.allocator(), source) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidModelsFile => settled(arena, .invalid),
    };
    return .{
        .arena = arena,
        .state = .{ .configured = config },
    };
}

pub fn view(self: *const ModelConfigSnapshot) ModelConfig {
    return switch (self.state) {
        .builtin => ModelConfig.builtin,
        .configured => |config| config,
    };
}

pub fn diagnostic(self: *const ModelConfigSnapshot) ?Diagnostic {
    return switch (self.state) {
        .builtin => |value| value,
        .configured => null,
    };
}

pub fn deinit(self: *ModelConfigSnapshot) void {
    self.arena.deinit();
    self.* = undefined;
}

fn settled(arena: std.heap.ArenaAllocator, diagnostic_value: ?Diagnostic) ModelConfigSnapshot {
    return .{
        .arena = arena,
        .state = .{ .builtin = diagnostic_value },
    };
}

fn compose(allocator: std.mem.Allocator, source: Source) error{ OutOfMemory, InvalidModelsFile }!ModelConfig {
    if (source.providers.map.count() > max_custom_providers) return error.InvalidModelsFile;

    const provider_ids = source.providers.map.keys();
    const source_providers = source.providers.map.values();
    var custom_model_count: usize = 0;
    for (provider_ids, source_providers) |provider_id, provider| {
        try validateProvider(provider_id, provider);
        if (provider.models.len > max_custom_models - custom_model_count) return error.InvalidModelsFile;
        custom_model_count += provider.models.len;
    }

    const entries = try allocator.alloc(
        ai_catalog.Entry,
        ModelConfig.builtin.catalog.entries.len + custom_model_count,
    );
    @memcpy(entries[0..ModelConfig.builtin.catalog.entries.len], ModelConfig.builtin.catalog.entries);
    var entry_index = ModelConfig.builtin.catalog.entries.len;
    for (provider_ids, source_providers) |provider_id, provider| {
        for (provider.models) |model| {
            entries[entry_index] = .{
                .identity = .{ .provider = provider_id, .model = model.id },
                .protocol_id = provider.protocol,
                .profile = try profile(provider.protocol, model),
            };
            entry_index += 1;
        }
    }

    const providers = try allocator.alloc(
        ModelConfig.ProviderDefinition,
        ModelConfig.builtin.providers.len + source_providers.len,
    );
    @memcpy(providers[0..ModelConfig.builtin.providers.len], ModelConfig.builtin.providers);
    for (provider_ids, source_providers, 0..) |provider_id, provider, index| {
        providers[ModelConfig.builtin.providers.len + index] = .{
            .id = provider_id,
            .name = provider.name orelse provider_id,
            .base_url = provider.baseUrl,
            .auth = .{ .api_key = .{} },
        };
    }
    return ModelConfig.init(.{ .entries = entries }, providers) catch return error.InvalidModelsFile;
}

fn validateProvider(provider_id: []const u8, provider: SourceProvider) error{InvalidModelsFile}!void {
    try validateIdentifierBytes(provider_id, max_provider_id_bytes);
    for (ModelConfig.builtin.providers) |builtin| {
        if (std.mem.eql(u8, provider_id, builtin.id)) return error.InvalidModelsFile;
    }
    _ = protocolRegistry().find(provider.protocol) orelse return error.InvalidModelsFile;
    if (provider.name) |name| try validateText(name, max_provider_name_bytes);
    try validateEndpoint(provider.baseUrl);
    if (provider.models.len == 0 or provider.models.len > max_models_per_provider) {
        return error.InvalidModelsFile;
    }
    for (provider.models) |model| {
        try validateModel(provider, model);
    }
}

fn validateModel(provider: SourceProvider, model: SourceModel) error{InvalidModelsFile}!void {
    try validateIdentifierBytes(model.id, max_model_id_bytes);
    if (model.name) |name| try validateText(name, max_model_name_bytes);
    if (model.protocol) |protocol_id| {
        if (!std.mem.eql(u8, protocol_id, provider.protocol)) return error.InvalidModelsFile;
    }
    if (model.baseUrl) |base_url| {
        try validateEndpoint(base_url);
        if (!std.mem.eql(u8, base_url, provider.baseUrl)) return error.InvalidModelsFile;
    }
    if (model.contextWindow == 0 or model.maxTokens == 0 or model.maxTokens > model.contextWindow) {
        return error.InvalidModelsFile;
    }

    var inputs: std.EnumSet(Input) = .initEmpty();
    for (model.input) |input| {
        if (inputs.contains(input)) return error.InvalidModelsFile;
        inputs.insert(input);
    }
    if (!inputs.contains(.text)) return error.InvalidModelsFile;

    if (model.thinkingLevelMap) |thinking_map| {
        if (!model.reasoning) return error.InvalidModelsFile;
        try validateThinkingMapping(thinking_map.off, null);
        try validateThinkingMapping(thinking_map.minimal, "minimal");
        try validateThinkingMapping(thinking_map.low, "low");
        try validateThinkingMapping(thinking_map.medium, "medium");
        try validateThinkingMapping(thinking_map.high, "high");
        try validateThinkingMapping(thinking_map.xhigh, null);
        try validateThinkingMapping(thinking_map.max, null);
    }
    if (model.cost) |cost| try validateCost(cost);
}

fn protocolRegistry() ai_protocol.Registry {
    return ai_protocol.Registry.init(&ai_protocols.builtin) catch unreachable;
}

fn profile(protocol_id: []const u8, model: SourceModel) error{InvalidModelsFile}!ai_settings.ModelProfile {
    const protocol = protocolRegistry().find(protocol_id) orelse return error.InvalidModelsFile;
    var efforts: std.EnumSet(ai_settings.ReasoningEffort) = .initEmpty();
    if (model.reasoning) {
        if (model.thinkingLevelMap) |thinking_map| {
            if (thinking_map.minimal != .unsupported) efforts.insert(.minimal);
            if (thinking_map.low != .unsupported) efforts.insert(.low);
            if (thinking_map.medium != .unsupported) efforts.insert(.medium);
            if (thinking_map.high != .unsupported) efforts.insert(.high);
        } else {
            efforts = .initFull();
        }
    }
    var value = protocol.profile(.{
        .reasoning = model.reasoning,
        .reasoning_efforts = efforts,
    });
    value.context_window = model.contextWindow;
    value.max_output_tokens = model.maxTokens;
    return value;
}

fn validateThinkingMapping(
    mapping: ThinkingMapping,
    identity: ?[]const u8,
) error{InvalidModelsFile}!void {
    switch (mapping) {
        .inherited, .unsupported => {},
        .mapped => |value| {
            try validateText(value, max_value_bytes);
            if (identity) |expected| {
                if (!std.mem.eql(u8, value, expected)) return error.InvalidModelsFile;
            }
        },
    }
}

fn validateCost(cost: Cost) error{InvalidModelsFile}!void {
    try validateRate(cost.input);
    try validateRate(cost.output);
    try validateRate(cost.cacheRead);
    try validateRate(cost.cacheWrite);
    if (cost.tiers.len > max_cost_tiers) return error.InvalidModelsFile;
    var previous_threshold: u64 = 0;
    for (cost.tiers) |tier| {
        if (tier.inputTokensAbove == 0 or tier.inputTokensAbove <= previous_threshold) {
            return error.InvalidModelsFile;
        }
        try validateRate(tier.input);
        try validateRate(tier.output);
        try validateRate(tier.cacheRead);
        try validateRate(tier.cacheWrite);
        previous_threshold = tier.inputTokensAbove;
    }
}

fn validateRate(rate: f64) error{InvalidModelsFile}!void {
    if (!std.math.isFinite(rate) or rate < 0) return error.InvalidModelsFile;
}

fn validateIdentifierBytes(value: []const u8, maximum_bytes: usize) error{InvalidModelsFile}!void {
    if (value.len == 0 or value.len > maximum_bytes or !std.unicode.utf8ValidateSlice(value)) {
        return error.InvalidModelsFile;
    }
    for (value) |byte| {
        if (std.ascii.isControl(byte) or std.ascii.isWhitespace(byte)) return error.InvalidModelsFile;
    }
}

fn validateText(value: []const u8, maximum_bytes: usize) error{InvalidModelsFile}!void {
    if (value.len == 0 or value.len > maximum_bytes or !std.unicode.utf8ValidateSlice(value)) {
        return error.InvalidModelsFile;
    }
    var has_non_whitespace = false;
    for (value) |byte| {
        if (std.ascii.isControl(byte)) return error.InvalidModelsFile;
        if (!std.ascii.isWhitespace(byte)) has_non_whitespace = true;
    }
    if (!has_non_whitespace) return error.InvalidModelsFile;
}

fn validateEndpoint(value: []const u8) error{InvalidModelsFile}!void {
    if (value.len == 0 or value.len > max_endpoint_bytes or !std.unicode.utf8ValidateSlice(value)) {
        return error.InvalidModelsFile;
    }
    if (std.mem.indexOfAny(u8, value, "\r\n\x00") != null) return error.InvalidModelsFile;
    const uri = std.Uri.parse(value) catch return error.InvalidModelsFile;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) {
        return error.InvalidModelsFile;
    }
    if (uri.host == null or uri.host.?.isEmpty() or
        uri.user != null or uri.password != null or uri.query != null or uri.fragment != null)
    {
        return error.InvalidModelsFile;
    }
}

fn preflightJson(allocator: std.mem.Allocator, source: []const u8) error{ OutOfMemory, InvalidModelsFile }!void {
    bounded_json.validate(allocator, source, .{
        .document_bytes = max_document_bytes,
        .value_bytes = max_value_bytes,
        .depth = max_json_depth,
        .collection_items = max_collection_items,
    }) catch |failure| switch (failure) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidModelsFile,
    };
}

const custom_openai_provider_source =
    \\{
    \\  "providers": {
    \\    "custom-openai": {
    \\      "baseUrl": "https://example.test/openai/v1",
    \\      "protocol": "openai-responses",
    \\      "models": [{
    \\        "id": "custom-reasoning-model",
    \\        "name": "Custom Reasoning Model",
    \\        "reasoning": true,
    \\        "input": ["text", "image"],
    \\        "contextWindow": 272000,
    \\        "maxTokens": 128000,
    \\        "cost": {
    \\          "input": 5,
    \\          "output": 30,
    \\          "cacheRead": 0.5,
    \\          "cacheWrite": 6.25,
    \\          "tiers": [{
    \\            "inputTokensAbove": 272000,
    \\            "input": 10,
    \\            "output": 45,
    \\            "cacheRead": 1,
    \\            "cacheWrite": 12.5
    \\          }]
    \\        },
    \\        "thinkingLevelMap": {
    \\          "off": "none",
    \\          "minimal": null,
    \\          "low": "low",
    \\          "medium": "medium",
    \\          "high": "high",
    \\          "xhigh": "xhigh",
    \\          "max": "max"
    \\        },
    \\        "compat": {
    \\          "supportsStrictMode": true,
    \\          "supportsOpenAIGrammarTools": true
    \\        }
    \\      }]
    \\    }
    \\  }
    \\}
;

const completions_source =
    \\{
    \\  "providers": {
    \\    "local": {
    \\      "name": "Local Models",
    \\      "baseUrl": "http://127.0.0.1:11434/v1",
    \\      "protocol": "openai-completions",
    \\      "models": [{"id": "qwen-coder"}]
    \\    }
    \\  }
    \\}
;

const sparse_thinking_source =
    \\{
    \\  "providers": {
    \\    "sparse": {
    \\      "baseUrl": "https://example.test/v1",
    \\      "protocol": "openai-responses",
    \\      "models": [{
    \\        "id": "reasoner",
    \\        "reasoning": true,
    \\        "thinkingLevelMap": {"off": null}
    \\      }]
    \\    }
    \\  }
    \\}
;

fn testPaths(temporary: *std.testing.TmpDir, buffer: []u8) !ZiPaths {
    const length = try temporary.dir.realPath(std.testing.io, buffer);
    return ZiPaths.init(std.testing.allocator, buffer[0..length], buffer[0..length]);
}

fn writeModels(temporary: *std.testing.TmpDir, contents: []const u8) !void {
    try temporary.dir.createDirPath(std.testing.io, ".zi/agent");
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".zi/agent/models.json",
        .data = contents,
    });
}

test "missing global models file settles to built-ins" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var paths = try testPaths(&temporary, &path_buffer);
    defer paths.deinit();

    var snapshot = try load(std.testing.allocator, std.testing.io, &paths);
    defer snapshot.deinit();
    try std.testing.expect(snapshot.diagnostic() == null);
    try std.testing.expectEqual(ModelConfig.builtin.providers.len, snapshot.view().providers.len);
    try std.testing.expectEqual(ModelConfig.builtin.catalog.entries.len, snapshot.view().catalog.entries.len);
}

test "global models snapshot owns a Pi-shaped Responses provider" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try writeModels(&temporary, custom_openai_provider_source);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var paths = try testPaths(&temporary, &path_buffer);
    var snapshot = try load(std.testing.allocator, std.testing.io, &paths);
    defer snapshot.deinit();
    paths.deinit();
    try writeModels(&temporary, "invalid after load");

    try std.testing.expect(snapshot.diagnostic() == null);
    const config = snapshot.view();
    try std.testing.expectEqual(ModelConfig.builtin.providers.len + 1, config.providers.len);
    try std.testing.expectEqual(ModelConfig.builtin.catalog.entries.len + 1, config.catalog.entries.len);
    const provider = config.findProvider("custom-openai").?.*;
    try std.testing.expectEqualStrings("custom-openai", provider.name);
    try std.testing.expectEqualStrings("https://example.test/openai/v1", provider.base_url);
    try std.testing.expect(provider.auth.api_key != null);
    const resolved = config.resolve(.{
        .provider = "custom-openai",
        .model = "custom-reasoning-model",
    }).?;
    try std.testing.expect(resolved.entry.profile.supports(.streaming));
    try std.testing.expect(resolved.entry.profile.supports(.tools));
    try std.testing.expect(resolved.entry.profile.supports(.thinking));
    try std.testing.expect(!resolved.entry.profile.supports(.image_input));
    try std.testing.expect(!resolved.entry.profile.reasoning_efforts.contains(.minimal));
    try std.testing.expect(resolved.entry.profile.reasoning_efforts.contains(.low));
    try std.testing.expectEqual(@as(?u64, 272_000), resolved.entry.profile.context_window);
    try std.testing.expectEqual(@as(?u64, 128_000), resolved.entry.profile.max_output_tokens);
}

test "Pi defaults project into a custom Chat Completions profile" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try writeModels(&temporary, completions_source);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var paths = try testPaths(&temporary, &path_buffer);
    defer paths.deinit();
    var snapshot = try load(std.testing.allocator, std.testing.io, &paths);
    defer snapshot.deinit();

    const config = snapshot.view();
    const provider = config.findProvider("local").?.*;
    try std.testing.expectEqualStrings("Local Models", provider.name);
    const resolved = config.resolve(.{ .provider = "local", .model = "qwen-coder" }).?;
    try std.testing.expect(resolved.entry.profile.supportsSetting(.temperature));
    try std.testing.expect(!resolved.entry.profile.supports(.thinking));
    try std.testing.expectEqual(@as(?u64, 128_000), resolved.entry.profile.context_window);
    try std.testing.expectEqual(@as(?u64, 16_384), resolved.entry.profile.max_output_tokens);
}

test "omitted thinking mappings inherit while explicit null remains unsupported" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try writeModels(&temporary, sparse_thinking_source);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var paths = try testPaths(&temporary, &path_buffer);
    defer paths.deinit();
    var snapshot = try load(std.testing.allocator, std.testing.io, &paths);
    defer snapshot.deinit();

    const resolved = snapshot.view().resolve(.{ .provider = "sparse", .model = "reasoner" }).?;
    try std.testing.expect(resolved.entry.profile.supportsSetting(.reasoning_effort));
    try std.testing.expect(resolved.entry.profile.reasoning_efforts.contains(.minimal));
    try std.testing.expect(resolved.entry.profile.reasoning_efforts.contains(.low));
    try std.testing.expect(resolved.entry.profile.reasoning_efforts.contains(.medium));
    try std.testing.expect(resolved.entry.profile.reasoning_efforts.contains(.high));
}

test "invalid global models files retain built-ins with one diagnostic" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var paths = try testPaths(&temporary, &path_buffer);
    defer paths.deinit();
    const cases = [_][]const u8{
        "not json",
        \\{"version":1,"providers":{}}
        ,
        \\{"providers":{},"unknown":true}
        ,
        // ziglint-ignore: Z024 -- compact invalid JSON fixture
        \\{"providers":{"openai":{"baseUrl":"https://example.test/v1","protocol":"openai-responses","models":[{"id":"model"}]}}}
        ,
        // ziglint-ignore: Z024 -- compact invalid JSON fixture
        \\{"providers":{"bad":{"baseUrl":"file:///tmp/model","protocol":"openai-responses","models":[{"id":"model"}]}}}
        ,
        // ziglint-ignore: Z024 -- compact invalid JSON fixture
        \\{"providers":{"bad":{"baseUrl":"https://example.test/v1","protocol":"anthropic-messages","models":[{"id":"model"}]}}}
        ,
        // ziglint-ignore: Z024 -- compact invalid JSON fixture
        \\{"providers":{"bad":{"baseUrl":"https://example.test/v1","protocol":"openai-responses","apiKey":"secret","models":[{"id":"model"}]}}}
        ,
        // ziglint-ignore: Z024 -- compact invalid JSON fixture
        \\{"providers":{"bad":{"baseUrl":"https://example.test/v1","protocol":"openai-responses","models":[{"id":"model","input":["image"]}]}}}
        ,
        // ziglint-ignore: Z024 -- compact invalid JSON fixture
        \\{"providers":{"bad":{"baseUrl":"https://example.test/v1","protocol":"openai-responses","models":[{"id":"model","protocol":"openai-completions"}]}}}
        ,
        // ziglint-ignore: Z024 -- compact invalid JSON fixture
        \\{"providers":{"bad":{"baseUrl":"https://example.test/v1","protocol":"openai-responses","models":[{"id":"model"},{"id":"model"}]}}}
        ,
        // ziglint-ignore: Z024 -- compact invalid JSON fixture
        \\{"providers":{"bad":{"baseUrl":"https://example.test/v1","protocol":"openai-responses","models":[{"id":"model","reasoning":true,"thinkingLevelMap":{"high":"maximum"}}]}}}
        ,
    };
    for (cases) |contents| {
        try writeModels(&temporary, contents);
        var snapshot = try load(std.testing.allocator, std.testing.io, &paths);
        defer snapshot.deinit();
        try std.testing.expectEqual(Diagnostic.invalid, snapshot.diagnostic().?);
        try std.testing.expectEqual(ModelConfig.builtin.providers.len, snapshot.view().providers.len);
        try std.testing.expect(snapshot.view().findProvider("bad") == null);
    }
}

test "global models JSON depth and collection bounds retain built-ins" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var paths = try testPaths(&temporary, &path_buffer);
    defer paths.deinit();

    const too_deep = "[" ** (max_json_depth + 1) ++ "]" ** (max_json_depth + 1);
    try writeModels(&temporary, too_deep);
    var deep_snapshot = try load(std.testing.allocator, std.testing.io, &paths);
    defer deep_snapshot.deinit();
    try std.testing.expectEqual(Diagnostic.invalid, deep_snapshot.diagnostic().?);

    const too_many = "[0," ** max_collection_items ++ "0]";
    try writeModels(&temporary, too_many);
    var collection_snapshot = try load(std.testing.allocator, std.testing.io, &paths);
    defer collection_snapshot.deinit();
    try std.testing.expectEqual(Diagnostic.invalid, collection_snapshot.diagnostic().?);
}

test "global models read failures and document bounds retain built-ins" {
    var oversized_temporary = std.testing.tmpDir(.{});
    defer oversized_temporary.cleanup();
    const oversized = try std.testing.allocator.alloc(u8, max_document_bytes);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, ' ');
    try writeModels(&oversized_temporary, oversized);
    var oversized_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var oversized_paths = try testPaths(&oversized_temporary, &oversized_buffer);
    defer oversized_paths.deinit();
    var oversized_snapshot = try load(std.testing.allocator, std.testing.io, &oversized_paths);
    defer oversized_snapshot.deinit();
    try std.testing.expectEqual(Diagnostic.too_large, oversized_snapshot.diagnostic().?);

    var unreadable_temporary = std.testing.tmpDir(.{});
    defer unreadable_temporary.cleanup();
    try unreadable_temporary.dir.createDirPath(std.testing.io, ".zi/agent/models.json");
    var unreadable_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var unreadable_paths = try testPaths(&unreadable_temporary, &unreadable_buffer);
    defer unreadable_paths.deinit();
    var unreadable_snapshot = try load(std.testing.allocator, std.testing.io, &unreadable_paths);
    defer unreadable_snapshot.deinit();
    try std.testing.expectEqual(Diagnostic.unreadable, unreadable_snapshot.diagnostic().?);
}

fn loadAndDeinit(allocator: std.mem.Allocator, paths: *const ZiPaths) !void {
    var snapshot = try load(allocator, std.testing.io, paths);
    snapshot.deinit();
}

test "global models snapshot settles every allocation failure" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try writeModels(&temporary, custom_openai_provider_source);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var paths = try testPaths(&temporary, &path_buffer);
    defer paths.deinit();
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        loadAndDeinit,
        .{&paths},
    );
}
