const std = @import("std");
const ai = @import("../ai/root.zig");
const bounded_json = @import("../BoundedJson.zig");
const ZiPaths = @import("ZiPaths.zig");

pub const Config = struct {
    const ai_catalog = ai.model_catalog;
    const ai_model = ai.model;
    const snapshot = ai.model_catalog_snapshot;
    const max_providers = 32;

    pub const Error = error{
        InvalidProviderDefinition,
        DuplicateProvider,
        ProviderHasNoModels,
        InvalidModelCatalog,
    };

    pub const ProviderDefinition = ai.provider.Definition;

    catalog: ai_catalog.Catalog,
    providers: []const ProviderDefinition,

    pub fn init(catalog: ai_catalog.Catalog, providers: []const ProviderDefinition) Error!Config {
        const config: Config = .{ .catalog = catalog, .providers = providers };
        try config.validate();
        return config;
    }

    pub fn validate(self: Config) Error!void {
        self.catalog.validate() catch return error.InvalidModelCatalog;
        if (self.providers.len > max_providers) return error.InvalidProviderDefinition;
        for (self.providers, 0..) |provider, index| {
            if (provider.id.len == 0 or provider.name.len == 0 or provider.base_url.len == 0) {
                return error.InvalidProviderDefinition;
            }
            const has_auth = provider.auth.api_key != null or provider.auth.oauth != null or
                provider.auth.allow_unauthenticated;
            if (!has_auth) return error.InvalidProviderDefinition;
            for (self.providers[0..index]) |previous| {
                if (std.mem.eql(u8, previous.id, provider.id)) return error.DuplicateProvider;
            }
            var has_model = false;
            for (self.catalog.entries) |entry| {
                if (std.mem.eql(u8, entry.identity.provider, provider.id)) {
                    has_model = true;
                    break;
                }
            }
            if (!has_model) return error.ProviderHasNoModels;
        }
    }

    pub fn findProvider(self: Config, provider_id: []const u8) ?*const ProviderDefinition {
        for (self.providers) |*definition| {
            if (std.mem.eql(u8, definition.id, provider_id)) return definition;
        }
        return null;
    }

    pub fn resolve(self: Config, selection: ai_model.ModelIdentity) ?ai_catalog.Resolved {
        _ = self.findProvider(selection.provider) orelse return null;
        return self.catalog.resolve(selection);
    }

    pub const builtin: Config = .{
        .catalog = snapshot.value,
        .providers = &ai.providers.builtin,
    };

    test "built-in model configuration resolves only defined providers" {
        try builtin.validate();
        const openai = builtin.resolve(.{ .provider = "openai", .model = "gpt-5.6" }).?;
        try std.testing.expectEqualStrings("gpt-5.6-sol", openai.canonicalModelId());
        try std.testing.expect(builtin.resolve(.{ .provider = "missing", .model = "gpt-5.6-sol" }) == null);
        try std.testing.expectEqual(
            @as(usize, 1),
            builtin.findProvider("openai").?.auth.api_key.?.environment_names.len,
        );
    }

    test "model configuration rejects duplicate and model-less providers" {
        const entries = [_]ai_catalog.Entry{.{
            .identity = .{ .provider = "configured", .model = "model" },
            .protocol_id = "openai-completions",
            .profile = .{},
        }};
        const catalog: ai_catalog.Catalog = .{ .entries = &entries };
        const duplicate = [_]ProviderDefinition{
            .{
                .id = "configured",
                .name = "Configured",
                .base_url = "https://example.test/v1",
                .auth = .{ .allow_unauthenticated = true },
            },
            .{
                .id = "configured",
                .name = "Configured Again",
                .base_url = "https://example.test/v1",
                .auth = .{ .allow_unauthenticated = true },
            },
        };
        try std.testing.expectError(error.DuplicateProvider, init(catalog, &duplicate));

        const missing = [_]ProviderDefinition{.{
            .id = "missing",
            .name = "Missing",
            .base_url = "https://example.test/v1",
            .auth = .{ .allow_unauthenticated = true },
        }};
        try std.testing.expectError(error.ProviderHasNoModels, init(catalog, &missing));

        const invalid = [_]ProviderDefinition{
            .{
                .id = "",
                .name = "Configured",
                .base_url = "https://example.test/v1",
                .auth = .{ .allow_unauthenticated = true },
            },
            .{
                .id = "configured",
                .name = "",
                .base_url = "https://example.test/v1",
                .auth = .{ .allow_unauthenticated = true },
            },
            .{
                .id = "configured",
                .name = "Configured",
                .base_url = "",
                .auth = .{ .allow_unauthenticated = true },
            },
            .{
                .id = "configured",
                .name = "Configured",
                .base_url = "https://example.test/v1",
                .auth = .{},
            },
        };
        for (invalid) |provider_definition| {
            try std.testing.expectError(
                error.InvalidProviderDefinition,
                init(catalog, &.{provider_definition}),
            );
        }
    }
};

pub const Snapshot = struct {
    const ai_catalog = ai.model_catalog;
    const ai_protocol = ai.protocol_api;
    const ai_adapters = ai.adapters;
    const ai_settings = ai.settings;
    pub const ModelConfig = Config;
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
    ) LoadError!Snapshot {
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

    pub fn view(self: *const Snapshot) ModelConfig {
        return switch (self.state) {
            .builtin => ModelConfig.builtin,
            .configured => |config| config,
        };
    }

    pub fn diagnostic(self: *const Snapshot) ?Diagnostic {
        return switch (self.state) {
            .builtin => |value| value,
            .configured => null,
        };
    }

    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
        self.* = undefined;
    }

    fn settled(arena: std.heap.ArenaAllocator, diagnostic_value: ?Diagnostic) Snapshot {
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
        for (ModelConfig.builtin.providers) |builtin_provider| {
            if (std.mem.eql(u8, provider_id, builtin_provider.id)) return error.InvalidModelsFile;
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
        return ai_protocol.Registry.init(&ai_adapters.builtin) catch unreachable;
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
};

pub const BootstrapPolicy = struct {
    pub const max_scoped_models: usize = 256;
    pub const max_available_models: usize = 256;

    pub const SessionState = enum {
        fresh,
        existing,
    };

    /// The process edge records whether an explicit selection was complete without
    /// passing raw command-line state through the bootstrap policy.
    pub const ExplicitSelection = union(enum) {
        absent,
        complete: ai.ModelIdentity,
        provider_only,
        model_only,
    };

    pub const ProviderDefault = enum {
        openai,
        openai_codex,
    };

    pub const ProviderDefaultPreference = struct {
        provider: ProviderDefault,
        identity: ai.ModelIdentity,
    };

    // Provenance: pi-mono packages/coding-agent/src/core/model-resolver.ts,
    // findInitialModel. These are Zi's current built-in provider preferences.
    pub const provider_default_preferences = [_]ProviderDefaultPreference{
        .{ .provider = .openai, .identity = .{ .provider = "openai", .model = "gpt-5.6-sol" } },
        .{ .provider = .openai_codex, .identity = .{ .provider = "openai-codex", .model = "gpt-5.6-terra" } },
    };

    pub const max_plan_candidates: usize = provider_default_preferences.len + 4;

    pub const Provenance = union(enum) {
        explicit_cli,
        fresh_scope,
        restored_session,
        settings_default,
        provider_default: ProviderDefault,
        first_available,
    };

    pub const Candidate = struct {
        identity: ai.ModelIdentity,
        provenance: Provenance,
    };

    /// A fixed-capacity, borrowed plan. Identity bytes remain owned by the caller.
    pub const Plan = struct {
        candidates: [max_plan_candidates]Candidate = undefined,
        len: usize = 0,

        pub fn items(self: *const Plan) []const Candidate {
            return self.candidates[0..self.len];
        }

        /// Returns null for an explicit selection, because its admission failure is
        /// terminal. Other candidates allow the caller to attempt the next source.
        pub fn nextAfterAdmissionFailure(self: *const Plan, index: usize) ?usize {
            if (index >= self.len or self.candidates[index].provenance == .explicit_cli) return null;
            const next = index + 1;
            return if (next < self.len) next else null;
        }

        fn appendUnique(self: *Plan, candidate: Candidate) Error!void {
            for (self.items()) |existing| {
                if (identitiesEqual(existing.identity, candidate.identity)) return;
            }
            if (self.len == self.candidates.len) return error.TooManyCandidates;
            self.candidates[self.len] = candidate;
            self.len += 1;
        }
    };

    pub const Inputs = struct {
        session_state: SessionState,
        explicit: ExplicitSelection = .absent,
        fresh_scoped_models: []const ai.ModelIdentity = &.{},
        restored_model: ?ai.ModelIdentity = null,
        effective_settings_default: ?ai.ModelIdentity = null,
        available_models: []const ai.ModelIdentity = &.{},
    };

    pub const Error = error{
        IncompleteExplicitSelection,
        TooManyScopedModels,
        TooManyAvailableModels,
        TooManyCandidates,
    };

    /// Produces the pure selection order. Candidate admission, including strict
    /// ModelResolution and credentials, belongs to the caller.
    pub fn plan(inputs: Inputs) Error!Plan {
        if (inputs.fresh_scoped_models.len > max_scoped_models) return error.TooManyScopedModels;
        if (inputs.available_models.len > max_available_models) return error.TooManyAvailableModels;

        var result: Plan = .{};
        switch (inputs.explicit) {
            .absent => {},
            .provider_only, .model_only => return error.IncompleteExplicitSelection,
            .complete => |selection| {
                try result.appendUnique(.{ .identity = selection, .provenance = .explicit_cli });
                return result;
            },
        }

        if (inputs.session_state == .fresh and inputs.fresh_scoped_models.len > 0) {
            try result.appendUnique(.{
                .identity = inputs.fresh_scoped_models[0],
                .provenance = .fresh_scope,
            });
        }
        if (inputs.restored_model) |restored| {
            try result.appendUnique(.{ .identity = restored, .provenance = .restored_session });
        }
        if (inputs.effective_settings_default) |settings_default| {
            try result.appendUnique(.{ .identity = settings_default, .provenance = .settings_default });
        }
        for (provider_default_preferences) |preference| {
            if (!containsIdentity(inputs.available_models, preference.identity)) continue;
            try result.appendUnique(.{
                .identity = preference.identity,
                .provenance = .{ .provider_default = preference.provider },
            });
        }
        if (inputs.available_models.len > 0) {
            try result.appendUnique(.{
                .identity = inputs.available_models[0],
                .provenance = .first_available,
            });
        }
        return result;
    }

    fn containsIdentity(identities: []const ai.ModelIdentity, wanted: ai.ModelIdentity) bool {
        for (identities) |candidate| {
            if (identitiesEqual(candidate, wanted)) return true;
        }
        return false;
    }

    fn identitiesEqual(left: ai.ModelIdentity, right: ai.ModelIdentity) bool {
        return std.mem.eql(u8, left.provider, right.provider) and std.mem.eql(u8, left.model, right.model);
    }

    fn identity(provider: []const u8, model: []const u8) ai.ModelIdentity {
        return .{ .provider = provider, .model = model };
    }

    fn expectCandidate(candidate: Candidate, expected: ai.ModelIdentity, provenance: Provenance) !void {
        try std.testing.expect(identitiesEqual(candidate.identity, expected));
        try std.testing.expectEqual(provenance, candidate.provenance);
    }

    test "complete explicit CLI selection is the only terminal bootstrap candidate" {
        const scoped = [_]ai.ModelIdentity{identity("scope", "model")};
        const available = [_]ai.ModelIdentity{identity("openai", "gpt-5.6-sol")};
        const result = try plan(.{
            .session_state = .fresh,
            .explicit = .{ .complete = identity("cli", "model") },
            .fresh_scoped_models = &scoped,
            .restored_model = identity("restored", "model"),
            .effective_settings_default = identity("settings", "model"),
            .available_models = &available,
        });

        try std.testing.expectEqual(@as(usize, 1), result.items().len);
        try expectCandidate(result.items()[0], identity("cli", "model"), .explicit_cli);
        try std.testing.expect(result.nextAfterAdmissionFailure(0) == null);
    }

    test "partial explicit CLI selection is rejected" {
        for ([_]ExplicitSelection{ .provider_only, .model_only }) |explicit| {
            try std.testing.expectError(error.IncompleteExplicitSelection, plan(.{
                .session_state = .fresh,
                .explicit = explicit,
            }));
        }
    }

    test "fresh sessions prefer the first scoped model" {
        const scoped = [_]ai.ModelIdentity{
            identity("scope", "first"),
            identity("scope", "second"),
        };
        const available = [_]ai.ModelIdentity{identity("openai", "gpt-5.6-sol")};
        const result = try plan(.{
            .session_state = .fresh,
            .fresh_scoped_models = &scoped,
            .restored_model = identity("restored", "model"),
            .effective_settings_default = identity("settings", "model"),
            .available_models = &available,
        });

        try expectCandidate(result.items()[0], scoped[0], .fresh_scope);
        try expectCandidate(result.items()[1], identity("restored", "model"), .restored_session);
    }

    test "existing sessions skip fresh scope and restore before settings" {
        const scoped = [_]ai.ModelIdentity{identity("scope", "model")};
        const result = try plan(.{
            .session_state = .existing,
            .fresh_scoped_models = &scoped,
            .restored_model = identity("restored", "model"),
            .effective_settings_default = identity("settings", "model"),
        });

        try std.testing.expectEqual(@as(usize, 2), result.items().len);
        try expectCandidate(result.items()[0], identity("restored", "model"), .restored_session);
        try expectCandidate(result.items()[1], identity("settings", "model"), .settings_default);
    }

    test "effective settings default precedes provider defaults and first available" {
        const available = [_]ai.ModelIdentity{
            identity("other", "first"),
            identity("openai", "gpt-5.6-sol"),
        };
        const result = try plan(.{
            .session_state = .fresh,
            .effective_settings_default = identity("settings", "model"),
            .available_models = &available,
        });

        try expectCandidate(result.items()[0], identity("settings", "model"), .settings_default);
        try expectCandidate(
            result.items()[1],
            identity("openai", "gpt-5.6-sol"),
            .{ .provider_default = .openai },
        );
        try expectCandidate(result.items()[2], available[0], .first_available);
    }

    test "provider defaults use Zi's deterministic preference order" {
        const available = [_]ai.ModelIdentity{
            identity("custom", "first"),
            identity("openai-codex", "gpt-5.6-terra"),
            identity("openai", "gpt-5.6-sol"),
        };
        const result = try plan(.{ .session_state = .fresh, .available_models = &available });

        try expectCandidate(
            result.items()[0],
            identity("openai", "gpt-5.6-sol"),
            .{ .provider_default = .openai },
        );
        try expectCandidate(
            result.items()[1],
            identity("openai-codex", "gpt-5.6-terra"),
            .{ .provider_default = .openai_codex },
        );
        try expectCandidate(result.items()[2], available[0], .first_available);
    }

    test "first available model is used when no provider default is available" {
        const available = [_]ai.ModelIdentity{identity("custom", "model")};
        const result = try plan(.{ .session_state = .fresh, .available_models = &available });

        try std.testing.expectEqual(@as(usize, 1), result.items().len);
        try expectCandidate(result.items()[0], available[0], .first_available);
        try std.testing.expect(result.nextAfterAdmissionFailure(0) == null);
    }

    test "duplicate identities retain their first provenance" {
        const repeated = identity("openai", "gpt-5.6-sol");
        const available = [_]ai.ModelIdentity{ repeated, identity("openai-codex", "gpt-5.6-terra") };
        const result = try plan(.{
            .session_state = .fresh,
            .fresh_scoped_models = &.{repeated},
            .restored_model = repeated,
            .effective_settings_default = repeated,
            .available_models = &available,
        });

        try std.testing.expectEqual(@as(usize, 2), result.items().len);
        try expectCandidate(result.items()[0], repeated, .fresh_scope);
        try expectCandidate(
            result.items()[1],
            identity("openai-codex", "gpt-5.6-terra"),
            .{ .provider_default = .openai_codex },
        );
    }

    test "absent candidates produce no model" {
        const result = try plan(.{ .session_state = .existing });
        try std.testing.expectEqual(@as(usize, 0), result.items().len);
        try std.testing.expect(result.nextAfterAdmissionFailure(0) == null);
    }

    test "candidate inputs and output plan are bounded" {
        var too_many_scoped: [max_scoped_models + 1]ai.ModelIdentity = undefined;
        try std.testing.expectError(error.TooManyScopedModels, plan(.{
            .session_state = .fresh,
            .fresh_scoped_models = &too_many_scoped,
        }));

        var too_many_available: [max_available_models + 1]ai.ModelIdentity = undefined;
        try std.testing.expectError(error.TooManyAvailableModels, plan(.{
            .session_state = .fresh,
            .available_models = &too_many_available,
        }));

        const scoped = [_]ai.ModelIdentity{identity("scope", "model")};
        const available = [_]ai.ModelIdentity{
            identity("custom", "first"),
            identity("openai", "gpt-5.6-sol"),
            identity("openai-codex", "gpt-5.6-terra"),
        };
        const result = try plan(.{
            .session_state = .fresh,
            .fresh_scoped_models = &scoped,
            .restored_model = identity("restored", "model"),
            .effective_settings_default = identity("settings", "model"),
            .available_models = &available,
        });
        try std.testing.expectEqual(max_plan_candidates, result.items().len);
    }
};

pub const Resolution = struct {
    const ai_catalog = ai.model_catalog;
    const ai_model = ai.model;
    pub const ModelConfig = Config;
    const max_credentials = ai.credential.max_credentials;
    const max_secret_bytes = ai.credential.max_secret_bytes;
    pub const StoredCredential = ai.credential.Entry;

    pub const Error = error{
        OutOfMemory,
        InvalidModelConfiguration,
        SelectionRequired,
        IncompleteSelection,
        UnknownSelection,
        MissingCredential,
        InvalidCredential,
        DuplicateCredential,
        UnsupportedCliCredential,
    };

    pub const RuntimeConfig = struct {
        model_config: ModelConfig,
        credentials: []const StoredCredential,
        auth_resolver: ?ai.auth.Resolver = null,
        selection: ai_model.ModelIdentity,
    };

    pub const Inputs = struct {
        model_config: ModelConfig = ModelConfig.builtin,
        requested_provider: ?[]const u8,
        requested_model: ?[]const u8,
        cli_api_key: ?[]const u8 = null,
        stored_credentials: []const StoredCredential = &.{},
        environment: ai.auth.Environment = .{},
    };

    pub const Resolved = struct {
        arena: std.heap.ArenaAllocator,
        model_config: ModelConfig,
        credentials: []const StoredCredential,
        selection: ai_model.ModelIdentity,
        sensitive: [3]?[]u8,

        // ziglint-ignore: Z012
        pub fn runtimeConfig(self: *const Resolved) RuntimeConfig {
            return .{
                .model_config = self.model_config,
                .credentials = self.credentials,
                .selection = self.selection,
            };
        }

        /// Securely erases the copied credential secrets once. After this, the
        /// canonical selection and configuration remain valid while
        /// `credentials` is empty and `deinit` has nothing left to erase.
        /// Repeating the call is a no-op.
        pub fn wipeCredentials(self: *Resolved) void {
            for (self.sensitive) |value| {
                if (value) |secret| std.crypto.secureZero(u8, secret);
            }
            self.sensitive = .{ null, null, null };
            self.credentials = &.{};
        }

        pub fn deinit(self: *Resolved) void {
            for (self.sensitive) |value| {
                if (value) |secret| std.crypto.secureZero(u8, secret);
            }
            self.arena.deinit();
            self.* = undefined;
        }
    };

    pub fn resolve(allocator: std.mem.Allocator, inputs: Inputs) Error!Resolved {
        inputs.model_config.validate() catch return error.InvalidModelConfiguration;
        if (inputs.stored_credentials.len > max_credentials) return error.InvalidCredential;

        const requested_provider = inputs.requested_provider orelse {
            if (inputs.requested_model != null) return error.IncompleteSelection;
            return error.SelectionRequired;
        };
        const requested_model = inputs.requested_model orelse return error.IncompleteSelection;
        const selected = inputs.model_config.resolve(.{
            .provider = requested_provider,
            .model = requested_model,
        }) orelse return error.UnknownSelection;
        const selected_credential = ai.Models.resolveAuth(
            inputs.model_config.catalog,
            inputs.model_config.providers,
            selected.entry.identity,
            .{
                .explicit_api_key = inputs.cli_api_key,
                .stored = inputs.stored_credentials,
                .environment = inputs.environment,
            },
        ) catch |failure| return switch (failure) {
            error.MissingCredential => error.MissingCredential,
            error.InvalidCredential => error.InvalidCredential,
            error.DuplicateCredential => error.DuplicateCredential,
            error.UnsupportedCredential => if (inputs.cli_api_key != null)
                error.UnsupportedCliCredential
            else
                error.InvalidCredential,
            error.InvalidConfiguration => error.InvalidModelConfiguration,
        };
        const provider = inputs.model_config.findProvider(selected.providerId()).?;

        var result: Resolved = .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .model_config = inputs.model_config,
            .credentials = &.{},
            .selection = selected.entry.identity,
            .sensitive = .{ null, null, null },
        };
        errdefer {
            for (result.sensitive) |value| {
                if (value) |secret| std.crypto.secureZero(u8, secret);
            }
            result.arena.deinit();
        }

        switch (selected_credential) {
            .unauthenticated => {},
            .api_key => |source| {
                const key = try result.arena.allocator().dupe(u8, source);
                result.sensitive[0] = key;
                const credentials = try result.arena.allocator().alloc(StoredCredential, 1);
                credentials[0] = .{
                    .provider_id = try result.arena.allocator().dupe(u8, provider.id),
                    .credential = .{ .api_key = .{ .key = key } },
                };
                result.credentials = credentials;
            },
            .oauth => |source| {
                const access = try result.arena.allocator().dupe(u8, source.access);
                result.sensitive[0] = access;
                const refresh = try result.arena.allocator().dupe(u8, source.refresh);
                result.sensitive[1] = refresh;
                const account_id = if (source.account_id) |value| copied: {
                    const copy = try result.arena.allocator().dupe(u8, value);
                    result.sensitive[2] = copy;
                    break :copied copy;
                } else null;
                const credentials = try result.arena.allocator().alloc(StoredCredential, 1);
                credentials[0] = .{
                    .provider_id = try result.arena.allocator().dupe(u8, provider.id),
                    .credential = .{ .oauth = .{
                        .access = access,
                        .refresh = refresh,
                        .expires_at_ms = source.expires_at_ms,
                        .account_id = account_id,
                    } },
                };
                result.credentials = credentials;
            },
        }
        return result;
    }

    fn storedApiKey(provider_id: []const u8, key: []const u8) StoredCredential {
        return .{ .provider_id = provider_id, .credential = .{ .api_key = .{ .key = key } } };
    }

    fn storedOauth(provider_id: []const u8, oauth: ai.Credential.OAuth) StoredCredential {
        return .{ .provider_id = provider_id, .credential = .{ .oauth = oauth } };
    }

    test "resolution canonicalizes provider-scoped aliases and applies API key precedence" {
        const cli_key = try std.testing.allocator.dupe(u8, "cli-key");
        defer std.testing.allocator.free(cli_key);
        const stored = [_]StoredCredential{storedApiKey("openai", "stored-key")};
        var resolved = try resolve(std.testing.allocator, .{
            .requested_provider = "openai",
            .requested_model = "gpt-5.6",
            .cli_api_key = cli_key,
            .stored_credentials = &stored,
            .environment = .{ .entries = &.{.{ .name = "OPENAI_API_KEY", .value = "environment-key" }} },
        });
        defer resolved.deinit();
        @memset(cli_key, 'x');

        try std.testing.expectEqualStrings("openai", resolved.selection.provider);
        try std.testing.expectEqualStrings("gpt-5.6-sol", resolved.selection.model);
        try std.testing.expectEqual(@as(usize, 1), resolved.credentials.len);
        try std.testing.expectEqualStrings("cli-key", resolved.credentials[0].credential.api_key.key);
    }

    test "resolution uses stored credentials before environment and filters unrelated providers" {
        const stored = [_]StoredCredential{
            storedApiKey("unsupported", "ignored"),
            storedOauth("openai-codex", .{ .access = "", .refresh = "refresh", .expires_at_ms = 1 }),
            storedApiKey("openai", "stored-key"),
        };
        var resolved = try resolve(std.testing.allocator, .{
            .requested_provider = "openai",
            .requested_model = "gpt-5.6-sol",
            .stored_credentials = &stored,
            .environment = .{ .entries = &.{.{ .name = "OPENAI_API_KEY", .value = "environment-key" }} },
        });
        defer resolved.deinit();

        try std.testing.expectEqual(@as(usize, 1), resolved.credentials.len);
        try std.testing.expectEqualStrings("stored-key", resolved.credentials[0].credential.api_key.key);
    }

    test "resolution uses the admitted OpenAI environment value only as fallback" {
        var resolved = try resolve(std.testing.allocator, .{
            .requested_provider = "openai",
            .requested_model = "gpt-5.6-sol",
            .environment = .{ .entries = &.{.{ .name = "OPENAI_API_KEY", .value = "environment-key" }} },
        });
        defer resolved.deinit();
        try std.testing.expectEqualStrings("environment-key", resolved.credentials[0].credential.api_key.key);

        try std.testing.expectError(error.MissingCredential, resolve(std.testing.allocator, .{
            .requested_provider = "openai-codex",
            .requested_model = "gpt-5.6-terra",
            .environment = .{ .entries = &.{.{ .name = "OPENAI_API_KEY", .value = "openai-only" }} },
        }));
    }

    test "resolution does not reinterpret OpenAI environment or CLI credentials for custom authentication" {
        const entries = [_]ai_catalog.Entry{.{
            .identity = .{ .provider = "custom", .model = "custom-model" },
            .protocol_id = "openai-completions",
            .profile = .{},
        }};
        const catalog: ai_catalog.Catalog = .{ .entries = &entries };
        const api_key_providers = [_]ModelConfig.ProviderDefinition{.{
            .id = "custom",
            .name = "Custom",
            .base_url = "https://example.test/v1",
            .auth = .{ .api_key = .{} },
        }};
        const api_key_config = try ModelConfig.init(catalog, &api_key_providers);
        try std.testing.expectError(error.MissingCredential, resolve(std.testing.allocator, .{
            .model_config = api_key_config,
            .requested_provider = "custom",
            .requested_model = "custom-model",
            .environment = .{ .entries = &.{.{ .name = "OPENAI_API_KEY", .value = "openai-only" }} },
        }));
        var custom = try resolve(std.testing.allocator, .{
            .model_config = api_key_config,
            .requested_provider = "custom",
            .requested_model = "custom-model",
            .cli_api_key = "custom-key",
        });
        defer custom.deinit();
        try std.testing.expectEqualStrings("custom-key", custom.credentials[0].credential.api_key.key);

        const no_auth_providers = [_]ModelConfig.ProviderDefinition{.{
            .id = "custom",
            .name = "Custom",
            .base_url = "https://example.test/v1",
            .auth = .{ .allow_unauthenticated = true },
        }};
        const no_auth_config = try ModelConfig.init(catalog, &no_auth_providers);
        try std.testing.expectError(error.UnsupportedCliCredential, resolve(std.testing.allocator, .{
            .model_config = no_auth_config,
            .requested_provider = "custom",
            .requested_model = "custom-model",
            .cli_api_key = "unneeded",
        }));
    }

    test "resolution admits already-resolved Codex OAuth without API-key fallback" {
        const stored = [_]StoredCredential{storedOauth("openai-codex", .{
            .access = "codex-token",
            .refresh = "codex-refresh",
            .expires_at_ms = 1_777_800_000_000,
            .account_id = "codex-account",
        })};
        var resolved = try resolve(std.testing.allocator, .{
            .requested_provider = "openai-codex",
            .requested_model = "gpt-5.6-terra",
            .stored_credentials = &stored,
            .environment = .{ .entries = &.{.{ .name = "OPENAI_API_KEY", .value = "openai-only" }} },
        });
        defer resolved.deinit();

        try std.testing.expectEqualStrings("codex-token", resolved.credentials[0].credential.oauth.access);
        try std.testing.expectEqualStrings("codex-account", resolved.credentials[0].credential.oauth.account_id.?);
        try std.testing.expectError(error.UnsupportedCliCredential, resolve(std.testing.allocator, .{
            .requested_provider = "openai-codex",
            .requested_model = "gpt-5.6-terra",
            .cli_api_key = "not-codex-oauth",
            .stored_credentials = &stored,
        }));
    }

    test "resolution rejects incomplete, unknown, unavailable, and invalid inputs" {
        try std.testing.expectError(error.SelectionRequired, resolve(std.testing.allocator, .{
            .requested_provider = null,
            .requested_model = null,
        }));
        try std.testing.expectError(error.IncompleteSelection, resolve(std.testing.allocator, .{
            .requested_provider = "openai",
            .requested_model = null,
        }));
        try std.testing.expectError(error.IncompleteSelection, resolve(std.testing.allocator, .{
            .requested_provider = null,
            .requested_model = "gpt-5.6-sol",
        }));
        try std.testing.expectError(error.UnknownSelection, resolve(std.testing.allocator, .{
            .requested_provider = "openai",
            .requested_model = "missing",
        }));
        try std.testing.expectError(error.MissingCredential, resolve(std.testing.allocator, .{
            .requested_provider = "openai",
            .requested_model = "gpt-5.6-sol",
        }));
        try std.testing.expectError(error.InvalidCredential, resolve(std.testing.allocator, .{
            .requested_provider = "openai",
            .requested_model = "gpt-5.6-sol",
            .cli_api_key = "",
        }));

        const invalid_stored = [_]StoredCredential{storedApiKey("openai", "")};
        try std.testing.expectError(error.InvalidCredential, resolve(std.testing.allocator, .{
            .requested_provider = "openai",
            .requested_model = "gpt-5.6-sol",
            .stored_credentials = &invalid_stored,
            .environment = .{ .entries = &.{.{ .name = "OPENAI_API_KEY", .value = "must-not-mask-invalid-stored" }} },
        }));

        const duplicate = [_]StoredCredential{
            storedApiKey("openai", "one"),
            storedApiKey("openai", "two"),
        };
        try std.testing.expectError(error.DuplicateCredential, resolve(std.testing.allocator, .{
            .requested_provider = "openai",
            .requested_model = "gpt-5.6-sol",
            .stored_credentials = &duplicate,
        }));

        const oversized_secret = try std.testing.allocator.alloc(u8, max_secret_bytes + 1);
        defer std.testing.allocator.free(oversized_secret);
        @memset(oversized_secret, 'x');
        try std.testing.expectError(error.InvalidCredential, resolve(std.testing.allocator, .{
            .requested_provider = "openai",
            .requested_model = "gpt-5.6-sol",
            .cli_api_key = oversized_secret,
        }));

        var too_many: [max_credentials + 1]StoredCredential = undefined;
        for (&too_many) |*credential| {
            credential.* = storedApiKey("unsupported", "ignored");
        }
        try std.testing.expectError(error.InvalidCredential, resolve(std.testing.allocator, .{
            .requested_provider = "openai",
            .requested_model = "gpt-5.6-sol",
            .stored_credentials = &too_many,
            .environment = .{ .entries = &.{.{ .name = "OPENAI_API_KEY", .value = "environment-key" }} },
        }));
    }

    fn resolveAndDeinit(allocator: std.mem.Allocator) !void {
        const stored = [_]StoredCredential{storedOauth("openai-codex", .{
            .access = "codex-token",
            .refresh = "codex-refresh",
            .expires_at_ms = 1_777_800_000_000,
            .account_id = "codex-account",
        })};
        var resolved = try resolve(allocator, .{
            .requested_provider = "openai-codex",
            .requested_model = "gpt-5.6-terra",
            .stored_credentials = &stored,
        });
        resolved.deinit();
    }

    test "resolution settles every allocation failure" {
        try std.testing.checkAllAllocationFailures(std.testing.allocator, resolveAndDeinit, .{});
    }

    test "resolution wipes its selected credential copy" {
        const backing = try std.testing.allocator.alloc(u8, 4096);
        defer std.testing.allocator.free(backing);
        @memset(backing, 0xa5);
        var fixed = std.heap.FixedBufferAllocator.init(backing);
        const stored = [_]StoredCredential{storedOauth("openai-codex", .{
            .access = "wipe-resolution-token",
            .refresh = "wipe-resolution-refresh",
            .expires_at_ms = 1_777_800_000_000,
            .account_id = "wipe-resolution-account",
        })};
        var resolved = try resolve(fixed.allocator(), .{
            .requested_provider = "openai-codex",
            .requested_model = "gpt-5.6-terra",
            .stored_credentials = &stored,
        });
        const credential = resolved.credentials[0].credential.oauth;
        const secrets = [_][]const u8{ credential.access, credential.refresh, credential.account_id.? };
        var offsets: [secrets.len]usize = undefined;
        var lengths: [secrets.len]usize = undefined;
        for (secrets, 0..) |secret, index| {
            offsets[index] = @intFromPtr(secret.ptr) - @intFromPtr(backing.ptr);
            lengths[index] = secret.len;
        }
        resolved.deinit();
        for (offsets, lengths) |offset, length| {
            for (backing[offset..][0..length]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
        }
    }

    test "resolution wipes copied credentials once while selection stays valid" {
        const backing = try std.testing.allocator.alloc(u8, 4096);
        defer std.testing.allocator.free(backing);
        @memset(backing, 0xa5);
        var fixed = std.heap.FixedBufferAllocator.init(backing);
        const stored = [_]StoredCredential{storedOauth("openai-codex", .{
            .access = "wipe-once-token",
            .refresh = "wipe-once-refresh",
            .expires_at_ms = 1_777_800_000_000,
            .account_id = "wipe-once-account",
        })};
        var resolved = try resolve(fixed.allocator(), .{
            .requested_provider = "openai-codex",
            .requested_model = "gpt-5.6-terra",
            .stored_credentials = &stored,
        });
        const credential = resolved.credentials[0].credential.oauth;
        const secrets = [_][]const u8{ credential.access, credential.refresh, credential.account_id.? };
        var offsets: [secrets.len]usize = undefined;
        var lengths: [secrets.len]usize = undefined;
        for (secrets, 0..) |secret, index| {
            offsets[index] = @intFromPtr(secret.ptr) - @intFromPtr(backing.ptr);
            lengths[index] = secret.len;
        }

        resolved.wipeCredentials();
        try std.testing.expectEqual(@as(usize, 0), resolved.credentials.len);
        try std.testing.expectEqualStrings("openai-codex", resolved.selection.provider);
        try std.testing.expectEqualStrings("gpt-5.6-terra", resolved.selection.model);
        // The wipe is idempotent and leaves deinit with nothing to erase.
        resolved.wipeCredentials();
        resolved.deinit();
        for (offsets, lengths) |offset, length| {
            for (backing[offset..][0..length]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
        }
    }
};
