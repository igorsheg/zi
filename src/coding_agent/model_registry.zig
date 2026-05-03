//! Session-owned visible model catalog.
//!
//! Owns a deep-copied snapshot built from:
//! - built-in generated models
//! - settings custom models captured at init
//! - active provider claims projected from `ai/provider.zig`
//!
//! The provider runtime registry and the model catalog stay separate
//! owners. This registry mirrors the current visible catalog for model
//! resolution, auth gating, session restore, and TUI publication.

const std = @import("std");
const protocol = @import("../ai/protocol.zig");
const generated = @import("../ai/models_generated.zig");
const json_util = @import("../ai/json_util.zig");
const provider_mod = @import("../ai/provider.zig");
const auth_storage_mod = @import("auth/storage.zig");
const resolve_config_value = @import("auth/resolve_config_value.zig");

pub const ModelRegistry = struct {
    allocator: std.mem.Allocator,
    /// Stable settings-owned custom models captured at init.
    custom_models: []protocol.Model,
    /// Current visible catalog. Rebuilt on the agent thread whenever the
    /// active provider claim projection changes.
    models: []protocol.Model,
    auth: *auth_storage_mod.AuthStorage,
    provider_registry: ?*const provider_mod.Registry,

    pub fn init(
        allocator: std.mem.Allocator,
        auth: *auth_storage_mod.AuthStorage,
        custom_models: []const protocol.Model,
    ) !ModelRegistry {
        var self: ModelRegistry = .{
            .allocator = allocator,
            .custom_models = &.{},
            .models = &.{},
            .auth = auth,
            .provider_registry = null,
        };
        errdefer self.deinit();

        self.custom_models = try cloneOwnedModels(allocator, custom_models);
        try self.rebuildFromActiveProviderClaims(null);
        return self;
    }

    pub fn deinit(self: *ModelRegistry) void {
        deinitOwnedModels(self.allocator, self.models);
        deinitOwnedModels(self.allocator, self.custom_models);
        self.models = &.{};
        self.custom_models = &.{};
    }

    pub fn rebuildFromActiveProviderClaims(
        self: *ModelRegistry,
        provider_registry: ?*const provider_mod.Registry,
    ) !void {
        const rebuilt = try buildVisibleModels(self.allocator, self.custom_models, provider_registry);
        errdefer deinitOwnedModels(self.allocator, rebuilt);

        deinitOwnedModels(self.allocator, self.models);
        self.models = rebuilt;
        self.provider_registry = provider_registry;
    }

    /// Stable slice until the next rebuild. Caller must not mutate.
    pub fn getAll(self: *const ModelRegistry) []const protocol.Model {
        return self.models;
    }

    /// Exact `(provider, id)` match. Byte-exact on id.
    pub fn find(
        self: *const ModelRegistry,
        provider: protocol.Provider,
        id: []const u8,
    ) ?protocol.Model {
        for (self.models) |m| {
            if (providersEqual(m.provider, provider) and std.mem.eql(u8, m.id, id)) {
                return m;
            }
        }
        return null;
    }

    pub fn findByProviderName(
        self: *const ModelRegistry,
        provider_name: []const u8,
        id: []const u8,
    ) ?protocol.Model {
        for (self.models) |m| {
            if (std.mem.eql(u8, json_util.providerToString(m.provider), provider_name) and
                std.mem.eql(u8, m.id, id))
            {
                return m;
            }
        }
        return null;
    }

    /// Synchronous hasAuth check. Unlike pi-mono's async counterpart,
    /// zi's AuthStorage is lock-protected and sync-friendly.
    pub fn hasConfiguredAuth(self: *const ModelRegistry, model: protocol.Model) bool {
        const provider_str = json_util.providerToString(model.provider);
        if (self.auth.hasAuth(provider_str)) return true;
        if (self.provider_registry) |registry| {
            const claim = registry.activeClaimRegistrationByName(provider_str) orelse return false;
            const config = claim.api_key orelse return false;
            const resolved = resolve_config_value.resolveConfigValue(config) orelse return false;
            if (resolved.len > 0) return true;
        }
        return false;
    }

    /// Caller-owned slice of models whose provider has configured auth.
    /// Sync — no oauth refresh side effects.
    pub fn getAvailable(
        self: *const ModelRegistry,
        allocator: std.mem.Allocator,
    ) ![]protocol.Model {
        var list: std.ArrayListUnmanaged(protocol.Model) = .empty;
        errdefer list.deinit(allocator);
        for (self.models) |m| {
            if (self.hasConfiguredAuth(m)) try list.append(allocator, m);
        }
        return list.toOwnedSlice(allocator);
    }
};

pub fn cloneOwnedModels(
    allocator: std.mem.Allocator,
    models: []const protocol.Model,
) ![]protocol.Model {
    if (models.len == 0) return &.{};

    const owned = try allocator.alloc(protocol.Model, models.len);
    var built: usize = 0;
    errdefer {
        deinitOwnedModelRange(allocator, owned[0..built]);
        allocator.free(owned);
    }

    for (models, 0..) |model, i| {
        owned[i] = try cloneOwnedModel(allocator, model);
        built += 1;
    }
    return owned;
}

pub fn deinitOwnedModels(
    allocator: std.mem.Allocator,
    models: []const protocol.Model,
) void {
    if (models.len == 0) return;
    const mutable: []protocol.Model = @constCast(models);
    deinitOwnedModelRange(allocator, mutable);
    allocator.free(mutable);
}

fn deinitOwnedModelRange(allocator: std.mem.Allocator, models: []protocol.Model) void {
    for (models) |*model| deinitOwnedModel(allocator, model);
}

pub fn cloneOwnedModel(
    allocator: std.mem.Allocator,
    model: protocol.Model,
) !protocol.Model {
    const id = try allocator.dupe(u8, model.id);
    errdefer allocator.free(id);
    const name = try allocator.dupe(u8, model.name);
    errdefer allocator.free(name);
    const api = try cloneOwnedApi(allocator, model.api);
    errdefer deinitOwnedApi(allocator, api);
    const provider = try cloneOwnedProvider(allocator, model.provider);
    errdefer deinitOwnedProvider(allocator, provider);
    const base_url = try allocator.dupe(u8, model.base_url);
    errdefer allocator.free(base_url);
    const input = try allocator.dupe(protocol.Model.InputType, model.input);
    errdefer allocator.free(input);
    const headers = try cloneOwnedHeaders(allocator, model.headers);
    errdefer deinitOwnedHeaders(allocator, headers);
    const compat = try cloneOwnedCompat(allocator, model.compat);
    errdefer deinitOwnedCompat(allocator, compat);

    return .{
        .id = id,
        .name = name,
        .api = api,
        .provider = provider,
        .base_url = base_url,
        .reasoning = model.reasoning,
        .input = input,
        .cost = model.cost,
        .context_window = model.context_window,
        .max_tokens = model.max_tokens,
        .headers = headers,
        .compat = compat,
    };
}

pub fn deinitOwnedModel(
    allocator: std.mem.Allocator,
    model: *protocol.Model,
) void {
    allocator.free(model.id);
    allocator.free(model.name);
    deinitOwnedApi(allocator, model.api);
    deinitOwnedProvider(allocator, model.provider);
    allocator.free(model.base_url);
    allocator.free(@constCast(model.input));
    deinitOwnedHeaders(allocator, model.headers);
    deinitOwnedCompat(allocator, model.compat);
    model.* = undefined;
}

fn buildVisibleModels(
    allocator: std.mem.Allocator,
    custom_models: []const protocol.Model,
    provider_registry: ?*const provider_mod.Registry,
) ![]protocol.Model {
    var claim_model_count: usize = 0;
    if (provider_registry) |registry| {
        var i: usize = 0;
        while (i < registry.activeClaimCount()) : (i += 1) {
            claim_model_count += registry.activeClaimRegistrationAt(i).models.len;
        }
    }

    const total = generated.models.len + custom_models.len + claim_model_count;
    if (total == 0) return &.{};

    const visible = try allocator.alloc(protocol.Model, total);
    var built: usize = 0;
    errdefer {
        deinitOwnedModelRange(allocator, visible[0..built]);
        allocator.free(visible);
    }

    for (generated.models) |model| {
        visible[built] = try cloneOwnedModel(allocator, model);
        built += 1;
    }
    for (custom_models) |model| {
        visible[built] = try cloneOwnedModel(allocator, model);
        built += 1;
    }
    if (provider_registry) |registry| {
        var i: usize = 0;
        while (i < registry.activeClaimCount()) : (i += 1) {
            const claim = registry.activeClaimRegistrationAt(i);
            for (claim.models) |claim_model| {
                visible[built] = try synthesizeClaimModel(allocator, claim.*, claim_model);
                built += 1;
            }
        }
    }
    std.debug.assert(built == total);
    return visible;
}

fn providersEqual(a: protocol.Provider, b: protocol.Provider) bool {
    return switch (a) {
        .custom => |a_name| switch (b) {
            .custom => |b_name| std.mem.eql(u8, a_name, b_name),
            else => false,
        },
        else => std.meta.eql(a, b),
    };
}

fn synthesizeClaimModel(
    allocator: std.mem.Allocator,
    claim: provider_mod.ClaimRegistration,
    claim_model: provider_mod.ClaimModelRegistration,
) !protocol.Model {
    const api_name = claim_model.api orelse claim.api;
    const api = try cloneOwnedApi(allocator, json_util.parseApi(api_name));
    errdefer deinitOwnedApi(allocator, api);
    const provider = try cloneOwnedProvider(allocator, json_util.parseProvider(claim.name));
    errdefer deinitOwnedProvider(allocator, provider);
    const id = try allocator.dupe(u8, claim_model.id);
    errdefer allocator.free(id);
    const name = try allocator.dupe(u8, claim_model.name);
    errdefer allocator.free(name);
    const base_url = try allocator.dupe(u8, claim.base_url);
    errdefer allocator.free(base_url);
    const input = try allocator.dupe(protocol.Model.InputType, claim_model.input);
    errdefer allocator.free(input);
    const headers = try cloneClaimHeaders(allocator, claim_model.headers);
    errdefer deinitOwnedHeaders(allocator, headers);
    const compat = try parseOwnedCompat(allocator, claim_model.compat, json_util.parseApi(api_name));
    errdefer deinitOwnedCompat(allocator, compat);

    return .{
        .id = id,
        .name = name,
        .api = api,
        .provider = provider,
        .base_url = base_url,
        .reasoning = claim_model.reasoning,
        .input = input,
        .cost = claim_model.cost,
        .context_window = claim_model.context_window,
        .max_tokens = claim_model.max_tokens,
        .headers = headers,
        .compat = compat,
    };
}

fn cloneOwnedApi(allocator: std.mem.Allocator, api: protocol.Api) !protocol.Api {
    return switch (api) {
        .custom => |value| .{ .custom = try allocator.dupe(u8, value) },
        else => api,
    };
}

fn deinitOwnedApi(allocator: std.mem.Allocator, api: protocol.Api) void {
    switch (api) {
        .custom => |value| allocator.free(value),
        else => {},
    }
}

fn cloneOwnedProvider(allocator: std.mem.Allocator, provider: protocol.Provider) !protocol.Provider {
    return switch (provider) {
        .custom => |value| .{ .custom = try allocator.dupe(u8, value) },
        else => provider,
    };
}

fn deinitOwnedProvider(allocator: std.mem.Allocator, provider: protocol.Provider) void {
    switch (provider) {
        .custom => |value| allocator.free(value),
        else => {},
    }
}

fn cloneOwnedHeaders(
    allocator: std.mem.Allocator,
    headers: ?[]const protocol.Header,
) !?[]const protocol.Header {
    const source = headers orelse return null;
    return cloneClaimHeaders(allocator, source);
}

fn cloneClaimHeaders(
    allocator: std.mem.Allocator,
    headers: []const protocol.Header,
) !?[]const protocol.Header {
    if (headers.len == 0) return null;

    const owned = try allocator.alloc(protocol.Header, headers.len);
    var built: usize = 0;
    errdefer {
        deinitOwnedHeaderRange(allocator, owned[0..built]);
        allocator.free(owned);
    }

    for (headers, 0..) |header, i| {
        const key = try allocator.dupe(u8, header.key);
        errdefer allocator.free(key);
        const value = try allocator.dupe(u8, header.value);
        errdefer allocator.free(value);
        owned[i] = .{ .key = key, .value = value };
        built += 1;
    }
    return owned;
}

fn deinitOwnedHeaders(
    allocator: std.mem.Allocator,
    headers: ?[]const protocol.Header,
) void {
    const source = headers orelse return;
    const mutable: []protocol.Header = @constCast(source);
    deinitOwnedHeaderRange(allocator, mutable);
    allocator.free(mutable);
}

fn deinitOwnedHeaderRange(allocator: std.mem.Allocator, headers: []protocol.Header) void {
    for (headers) |header| {
        allocator.free(header.key);
        allocator.free(header.value);
    }
}

fn cloneOwnedCompat(
    allocator: std.mem.Allocator,
    compat: ?protocol.Compat,
) !?protocol.Compat {
    const value = compat orelse return null;
    return switch (value) {
        .openai_completions => |openai| .{ .openai_completions = try cloneOpenAICompletionsCompat(allocator, openai) },
        .openai_responses => |responses| .{ .openai_responses = responses },
    };
}

fn deinitOwnedCompat(
    allocator: std.mem.Allocator,
    compat: ?protocol.Compat,
) void {
    const value = compat orelse return;
    switch (value) {
        .openai_completions => |openai| deinitOpenAICompletionsCompat(allocator, openai),
        .openai_responses => {},
    }
}

fn cloneOpenAICompletionsCompat(
    allocator: std.mem.Allocator,
    compat: protocol.OpenAICompletionsCompat,
) !protocol.OpenAICompletionsCompat {
    var out: protocol.OpenAICompletionsCompat = .{
        .supports_store = compat.supports_store,
        .supports_developer_role = compat.supports_developer_role,
        .supports_reasoning_effort = compat.supports_reasoning_effort,
        .supports_usage_in_streaming = compat.supports_usage_in_streaming,
        .max_tokens_field = compat.max_tokens_field,
        .requires_tool_result_name = compat.requires_tool_result_name,
        .requires_assistant_after_tool_result = compat.requires_assistant_after_tool_result,
        .requires_thinking_as_text = compat.requires_thinking_as_text,
        .thinking_format = compat.thinking_format,
        .zai_tool_stream = compat.zai_tool_stream,
        .supports_strict_mode = compat.supports_strict_mode,
    };
    errdefer deinitOpenAICompletionsCompat(allocator, out);
    out.reasoning_effort_map = try cloneReasoningEffortMap(allocator, compat.reasoning_effort_map);
    out.open_router_routing = try cloneOpenRouterRouting(allocator, compat.open_router_routing);
    out.vercel_gateway_routing = try cloneVercelGatewayRouting(allocator, compat.vercel_gateway_routing);
    return out;
}

fn deinitOpenAICompletionsCompat(
    allocator: std.mem.Allocator,
    compat: protocol.OpenAICompletionsCompat,
) void {
    deinitReasoningEffortMap(allocator, compat.reasoning_effort_map);
    deinitOpenRouterRouting(allocator, compat.open_router_routing);
    deinitVercelGatewayRouting(allocator, compat.vercel_gateway_routing);
}

fn cloneReasoningEffortMap(
    allocator: std.mem.Allocator,
    map: ?protocol.OpenAICompletionsCompat.ReasoningEffortMap,
) !?protocol.OpenAICompletionsCompat.ReasoningEffortMap {
    const source = map orelse return null;
    var out: protocol.OpenAICompletionsCompat.ReasoningEffortMap = .{};
    errdefer deinitReasoningEffortMap(allocator, out);
    out.minimal = try cloneOptionalString(allocator, source.minimal);
    out.low = try cloneOptionalString(allocator, source.low);
    out.medium = try cloneOptionalString(allocator, source.medium);
    out.high = try cloneOptionalString(allocator, source.high);
    out.xhigh = try cloneOptionalString(allocator, source.xhigh);
    return out;
}

fn deinitReasoningEffortMap(
    allocator: std.mem.Allocator,
    map: ?protocol.OpenAICompletionsCompat.ReasoningEffortMap,
) void {
    const source = map orelse return;
    freeOptionalString(allocator, source.minimal);
    freeOptionalString(allocator, source.low);
    freeOptionalString(allocator, source.medium);
    freeOptionalString(allocator, source.high);
    freeOptionalString(allocator, source.xhigh);
}

fn cloneOpenRouterRouting(
    allocator: std.mem.Allocator,
    routing: ?protocol.OpenRouterRouting,
) !?protocol.OpenRouterRouting {
    const source = routing orelse return null;
    var out: protocol.OpenRouterRouting = .{};
    errdefer deinitOpenRouterRouting(allocator, out);
    out.only = try cloneOptionalStringList(allocator, source.only);
    out.order = try cloneOptionalStringList(allocator, source.order);
    return out;
}

fn deinitOpenRouterRouting(
    allocator: std.mem.Allocator,
    routing: ?protocol.OpenRouterRouting,
) void {
    const source = routing orelse return;
    freeOptionalStringList(allocator, source.only);
    freeOptionalStringList(allocator, source.order);
}

fn cloneVercelGatewayRouting(
    allocator: std.mem.Allocator,
    routing: ?protocol.VercelGatewayRouting,
) !?protocol.VercelGatewayRouting {
    const source = routing orelse return null;
    var out: protocol.VercelGatewayRouting = .{};
    errdefer deinitVercelGatewayRouting(allocator, out);
    out.only = try cloneOptionalStringList(allocator, source.only);
    out.order = try cloneOptionalStringList(allocator, source.order);
    return out;
}

fn deinitVercelGatewayRouting(
    allocator: std.mem.Allocator,
    routing: ?protocol.VercelGatewayRouting,
) void {
    const source = routing orelse return;
    freeOptionalStringList(allocator, source.only);
    freeOptionalStringList(allocator, source.order);
}

fn cloneOptionalString(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    const source = value orelse return null;
    return try allocator.dupe(u8, source);
}

fn freeOptionalString(allocator: std.mem.Allocator, value: ?[]const u8) void {
    if (value) |source| allocator.free(source);
}

fn cloneOptionalStringList(
    allocator: std.mem.Allocator,
    values: ?[][]const u8,
) !?[][]const u8 {
    const source = values orelse return null;
    if (source.len == 0) return try allocator.alloc([]const u8, 0);

    const owned = try allocator.alloc([]const u8, source.len);
    var built: usize = 0;
    errdefer {
        for (owned[0..built]) |item| allocator.free(item);
        allocator.free(owned);
    }

    for (source, 0..) |item, i| {
        owned[i] = try allocator.dupe(u8, item);
        built += 1;
    }
    return owned;
}

fn freeOptionalStringList(allocator: std.mem.Allocator, values: ?[][]const u8) void {
    const source = values orelse return;
    for (source) |item| allocator.free(item);
    allocator.free(source);
}

fn parseOwnedCompat(
    allocator: std.mem.Allocator,
    compat: ?std.json.Value,
    api: protocol.Api,
) !?protocol.Compat {
    const raw = compat orelse return null;
    const object = switch (raw) {
        .object => |value| value,
        else => return null,
    };
    return switch (api) {
        .openai_completions => .{ .openai_completions = try parseOpenAICompletionsCompat(allocator, object) },
        .openai_responses, .azure_openai_responses, .openai_codex_responses => .{ .openai_responses = .{} },
        else => null,
    };
}

fn parseOpenAICompletionsCompat(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
) !protocol.OpenAICompletionsCompat {
    var out: protocol.OpenAICompletionsCompat = .{
        .supports_store = jsonBool(object, "supports_store"),
        .supports_developer_role = jsonBool(object, "supports_developer_role"),
        .supports_reasoning_effort = jsonBool(object, "supports_reasoning_effort"),
        .supports_usage_in_streaming = jsonBool(object, "supports_usage_in_streaming"),
        .max_tokens_field = parseMaxTokensField(jsonString(object, "max_tokens_field")),
        .requires_tool_result_name = jsonBool(object, "requires_tool_result_name"),
        .requires_assistant_after_tool_result = jsonBool(object, "requires_assistant_after_tool_result"),
        .requires_thinking_as_text = jsonBool(object, "requires_thinking_as_text"),
        .thinking_format = parseThinkingFormat(jsonString(object, "thinking_format")),
        .zai_tool_stream = jsonBool(object, "zai_tool_stream"),
        .supports_strict_mode = jsonBool(object, "supports_strict_mode"),
    };
    errdefer deinitOpenAICompletionsCompat(allocator, out);
    out.reasoning_effort_map = try parseReasoningEffortMap(allocator, object);
    out.open_router_routing = try parseOpenRouterRouting(allocator, object);
    out.vercel_gateway_routing = try parseVercelGatewayRouting(allocator, object);
    return out;
}

fn parseReasoningEffortMap(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
) !?protocol.OpenAICompletionsCompat.ReasoningEffortMap {
    const value = object.get("reasoning_effort_map") orelse return null;
    const map_object = switch (value) {
        .object => |map| map,
        else => return null,
    };
    var out: protocol.OpenAICompletionsCompat.ReasoningEffortMap = .{};
    errdefer deinitReasoningEffortMap(allocator, out);
    out.minimal = try cloneOptionalString(allocator, jsonString(map_object, "minimal"));
    out.low = try cloneOptionalString(allocator, jsonString(map_object, "low"));
    out.medium = try cloneOptionalString(allocator, jsonString(map_object, "medium"));
    out.high = try cloneOptionalString(allocator, jsonString(map_object, "high"));
    out.xhigh = try cloneOptionalString(allocator, jsonString(map_object, "xhigh"));
    return out;
}

fn parseOpenRouterRouting(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
) !?protocol.OpenRouterRouting {
    const value = object.get("open_router_routing") orelse return null;
    const routing_object = switch (value) {
        .object => |routing| routing,
        else => return null,
    };
    var out: protocol.OpenRouterRouting = .{};
    errdefer deinitOpenRouterRouting(allocator, out);
    out.only = try parseStringArray(allocator, routing_object.get("only"));
    out.order = try parseStringArray(allocator, routing_object.get("order"));
    return out;
}

fn parseVercelGatewayRouting(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
) !?protocol.VercelGatewayRouting {
    const value = object.get("vercel_gateway_routing") orelse return null;
    const routing_object = switch (value) {
        .object => |routing| routing,
        else => return null,
    };
    var out: protocol.VercelGatewayRouting = .{};
    errdefer deinitVercelGatewayRouting(allocator, out);
    out.only = try parseStringArray(allocator, routing_object.get("only"));
    out.order = try parseStringArray(allocator, routing_object.get("order"));
    return out;
}

fn parseStringArray(
    allocator: std.mem.Allocator,
    value: ?std.json.Value,
) !?[][]const u8 {
    const raw = value orelse return null;
    const array = switch (raw) {
        .array => |items| items,
        else => return null,
    };
    const owned = try allocator.alloc([]const u8, array.items.len);
    var built: usize = 0;
    errdefer {
        for (owned[0..built]) |item| allocator.free(item);
        allocator.free(owned);
    }

    for (array.items, 0..) |item, i| {
        const string = switch (item) {
            .string => |text| text,
            else => {
                for (owned[0..built]) |owned_item| allocator.free(owned_item);
                allocator.free(owned);
                return null;
            },
        };
        owned[i] = try allocator.dupe(u8, string);
        built += 1;
    }
    return owned;
}

fn jsonBool(object: std.json.ObjectMap, field: []const u8) ?bool {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .bool => |flag| flag,
        else => null,
    };
}

fn jsonString(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn parseMaxTokensField(
    value: ?[]const u8,
) @FieldType(protocol.OpenAICompletionsCompat, "max_tokens_field") {
    const text = value orelse return null;
    if (std.mem.eql(u8, text, "max_completion_tokens")) return .max_completion_tokens;
    if (std.mem.eql(u8, text, "max_tokens")) return .max_tokens;
    return null;
}

fn parseThinkingFormat(
    value: ?[]const u8,
) ?protocol.OpenAICompletionsCompat.ThinkingFormat {
    const text = value orelse return null;
    if (std.mem.eql(u8, text, "openai")) return .openai;
    if (std.mem.eql(u8, text, "openrouter")) return .openrouter;
    if (std.mem.eql(u8, text, "zai")) return .zai;
    if (std.mem.eql(u8, text, "qwen")) return .qwen;
    if (std.mem.eql(u8, text, "qwen_chat_template")) return .qwen_chat_template;
    return null;
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

const test_provider = struct {
    fn stream(_: *anyopaque, _: std.mem.Allocator, _: protocol.Model, _: protocol.Context, _: protocol.StreamOptions, _: provider_mod.EventCallback, _: ?*anyopaque) void {}
    fn streamSimple(_: *anyopaque, _: std.mem.Allocator, _: protocol.Model, _: protocol.Context, _: protocol.SimpleStreamOptions, _: provider_mod.EventCallback, _: ?*anyopaque) void {}
    fn getName(_: *anyopaque) []const u8 {
        return "baseline";
    }
    fn deinit(_: *anyopaque) void {}

    const vtable: provider_mod.Provider.VTable = .{
        .stream = stream,
        .stream_simple = streamSimple,
        .get_name = getName,
        .deinit = deinit,
    };
};

fn registerAnthropicBaseline(providers: *provider_mod.Registry) !void {
    try providers.register("anthropic-messages", .{
        .ptr = undefined,
        .vtable = &test_provider.vtable,
    }, null);
}

fn testModel(id: []const u8, provider: protocol.Provider) protocol.Model {
    return .{
        .id = id,
        .name = "Test Model",
        .api = .openai_completions,
        .provider = provider,
        .base_url = "https://example.com",
        .reasoning = false,
        .input = &.{.text},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 4096,
        .max_tokens = 4096,
    };
}

fn testClaimModelRegistration(allocator: std.mem.Allocator) !provider_mod.ClaimModelRegistration {
    return .{
        .id = try allocator.dupe(u8, "proxy-model"),
        .name = try allocator.dupe(u8, "Proxy Model"),
        .reasoning = true,
        .input = try allocator.dupe(protocol.Model.InputType, &.{ .text, .image }),
        .cost = .{ .input = 1, .output = 2, .cache_read = 3, .cache_write = 4 },
        .context_window = 8192,
        .max_tokens = 4096,
    };
}

test "registry exposes built-ins, custom models, and exact lookups" {
    const alloc = testing.allocator;
    var auth = try auth_storage_mod.AuthStorage.create(alloc, null);
    defer auth.deinit();

    const custom = testModel("my-model", .{ .custom = "my-provider" });
    var reg = try ModelRegistry.init(alloc, &auth, &.{custom});
    defer reg.deinit();

    try testing.expectEqual(generated.models.len + 1, reg.getAll().len);
    try testing.expectEqualStrings(generated.models[0].id, reg.getAll()[0].id);

    const built_in = reg.find(.anthropic, "claude-opus-4-6") orelse return error.MissingCatalogEntry;
    try testing.expectEqualStrings("claude-opus-4-6", built_in.id);
    try testing.expect(std.meta.eql(protocol.Provider.anthropic, built_in.provider));

    const custom_by_name = reg.findByProviderName("my-provider", "my-model") orelse return error.MissingCatalogEntry;
    try testing.expectEqualStrings("Test Model", custom_by_name.name);
    try testing.expect(reg.find(.anthropic, "CLAUDE-OPUS-4-6") == null);
    try testing.expect(reg.find(.openai, "claude-opus-4-6") == null);
}

test "active provider claims extend catalog without changing built-in identity" {
    const alloc = testing.allocator;
    var auth = try auth_storage_mod.AuthStorage.create(alloc, null);
    defer auth.deinit();
    var reg = try ModelRegistry.init(alloc, &auth, &.{});
    defer reg.deinit();

    var providers = provider_mod.Registry.init(alloc);
    defer providers.deinit();
    try registerAnthropicBaseline(&providers);

    const claim_models = try alloc.alloc(provider_mod.ClaimModelRegistration, 1);
    claim_models[0] = try testClaimModelRegistration(alloc);
    const claim: provider_mod.ClaimRegistration = .{
        .name = try alloc.dupe(u8, "proxy-a"),
        .api = try alloc.dupe(u8, "anthropic-messages"),
        .base_url = try alloc.dupe(u8, "https://proxy-a.example"),
        .owner_id = try alloc.dupe(u8, "ext-a"),
        .generation = 1,
        .models = claim_models,
    };
    try testing.expect(try providers.registerClaim(claim));

    try reg.rebuildFromActiveProviderClaims(&providers);

    try testing.expectEqual(generated.models.len + 1, reg.getAll().len);
    const claim_model = reg.find(.{ .custom = "proxy-a" }, "proxy-model") orelse return error.MissingCatalogEntry;
    try testing.expectEqualStrings("Proxy Model", claim_model.name);
    try testing.expectEqualStrings("https://proxy-a.example", claim_model.base_url);
    try testing.expectEqual(@as(usize, 2), claim_model.input.len);
    try testing.expect(std.meta.eql(protocol.Api.anthropic_messages, claim_model.api));

    const built_in = reg.find(.anthropic, "claude-opus-4-6") orelse return error.MissingCatalogEntry;
    try testing.expectEqualStrings("anthropic", json_util.providerToString(built_in.provider));
}

test "auth visibility includes stored keys and claim api_key without leaking provider headers" {
    const alloc = testing.allocator;
    var auth = try auth_storage_mod.AuthStorage.create(alloc, null);
    defer auth.deinit();
    auth.setRuntimeApiKey("anthropic", "stored-key");

    var reg = try ModelRegistry.init(alloc, &auth, &.{});
    defer reg.deinit();

    const built_in = reg.find(.anthropic, "claude-opus-4-6") orelse return error.MissingCatalogEntry;
    try testing.expect(reg.hasConfiguredAuth(built_in));

    var providers = provider_mod.Registry.init(alloc);
    defer providers.deinit();
    try registerAnthropicBaseline(&providers);

    const claim_models = try alloc.alloc(provider_mod.ClaimModelRegistration, 1);
    claim_models[0] = try testClaimModelRegistration(alloc);
    claim_models[0].headers = blk: {
        const headers = try alloc.alloc(protocol.Header, 1);
        headers[0] = .{
            .key = try alloc.dupe(u8, "x-model"),
            .value = try alloc.dupe(u8, "model-visible"),
        };
        break :blk headers;
    };
    const provider_headers = blk: {
        const headers = try alloc.alloc(protocol.Header, 1);
        headers[0] = .{
            .key = try alloc.dupe(u8, "x-provider"),
            .value = try alloc.dupe(u8, "provider-secret"),
        };
        break :blk headers;
    };
    const claim: provider_mod.ClaimRegistration = .{
        .name = try alloc.dupe(u8, "proxy-auth"),
        .api = try alloc.dupe(u8, "anthropic-messages"),
        .base_url = try alloc.dupe(u8, "https://proxy-auth.example"),
        .api_key = try alloc.dupe(u8, "claim-key"),
        .headers = provider_headers,
        .owner_id = try alloc.dupe(u8, "ext-a"),
        .generation = 1,
        .models = claim_models,
    };
    try testing.expect(try providers.registerClaim(claim));
    try reg.rebuildFromActiveProviderClaims(&providers);

    const claim_model = reg.find(.{ .custom = "proxy-auth" }, "proxy-model") orelse return error.MissingCatalogEntry;
    try testing.expect(reg.hasConfiguredAuth(claim_model));

    const available = try reg.getAvailable(alloc);
    defer alloc.free(available);
    var saw_claim = false;
    for (available) |model| {
        if (providersEqual(model.provider, .{ .custom = "proxy-auth" }) and std.mem.eql(u8, model.id, "proxy-model")) {
            saw_claim = true;
        }
    }
    try testing.expect(saw_claim);

    try testing.expect(claim_model.headers != null);
    try testing.expectEqual(@as(usize, 1), claim_model.headers.?.len);
    try testing.expectEqualStrings("x-model", claim_model.headers.?[0].key);
    try testing.expectEqualStrings("model-visible", claim_model.headers.?[0].value);
    for (claim_model.headers.?) |header| {
        try testing.expect(!std.mem.eql(u8, header.key, "x-provider"));
    }
}
