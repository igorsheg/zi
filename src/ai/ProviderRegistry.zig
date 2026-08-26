const std = @import("std");
const AnthropicMessages = @import("AnthropicMessages.zig").AnthropicMessages;
const CodexModule = @import("Codex.zig");
const Codex = CodexModule.Codex;
const Effort = @import("Effort.zig");
const ModelMeta = @import("ModelMeta.zig");
const OpenAiChat = @import("OpenAiChat.zig").OpenAiChat;
const OpenAiResponses = @import("OpenAiResponses.zig").OpenAiResponses;
const Provider = @import("Provider.zig");
const Transport = @import("Transport.zig");
const Wire = @import("Wire.zig").Wire;

pub const maximum_rules: usize = 64;
pub const maximum_pattern_bytes: usize = 1024;
pub const maximum_total_pattern_bytes: usize = maximum_rules * maximum_pattern_bytes;
pub const maximum_glob_work: usize = 4 * 1024 * 1024;
pub const maximum_endpoint_bytes: usize = 4096;
pub const maximum_id_bytes: usize = 128;
pub const maximum_model_bytes: usize = 1024;
pub const maximum_auth_bytes: usize = 8 * 1024;

pub const Kind = enum { builtin, recipe };

pub const Descriptor = struct {
    id: []const u8,
    display_name: []const u8,
    kind: Kind,
    selectable: bool = true,
    default_wire: ?Wire,
    base_url: ?[]const u8,
    catalog_id: ?[]const u8 = null,
    /// Reject user base URL overrides when the compiled API identity is fixed.
    pin_base_url: bool = false,
    /// Permit catalog metadata to select a model-specific wire.
    catalog_wires: bool = false,
};

// This order is both the picker order and the automatic-selection priority.
pub const descriptors = [_]Descriptor{
    .{
        .id = "codex",
        .display_name = "codex",
        .kind = .builtin,
        .default_wire = .openai_responses,
        .base_url = "https://chatgpt.com/backend-api/codex",
        .catalog_id = "openai",
        .pin_base_url = true,
    },
    .{
        .id = "llamacpp",
        .display_name = "llama.cpp",
        .kind = .builtin,
        .default_wire = .openai_chat,
        .base_url = "http://127.0.0.1:8080/v1",
    },
    .{
        .id = "openai",
        .display_name = "openai",
        .kind = .builtin,
        .default_wire = .openai_responses,
        .base_url = "https://api.openai.com/v1",
        .catalog_id = "openai",
        .pin_base_url = true,
    },
    .{
        .id = "anthropic",
        .display_name = "anthropic",
        .kind = .builtin,
        .default_wire = .anthropic_messages,
        .base_url = "https://api.anthropic.com/v1",
        .catalog_id = "anthropic",
        .pin_base_url = true,
    },
    .{
        .id = "openrouter",
        .display_name = "openrouter",
        .kind = .builtin,
        .default_wire = .openai_chat,
        .base_url = "https://openrouter.ai/api/v1",
        .pin_base_url = true,
    },
    .{
        .id = "openai-compatible",
        .display_name = "openai-compatible",
        .kind = .recipe,
        .default_wire = .openai_chat,
        .base_url = null,
    },
    .{
        .id = "anthropic-compatible",
        .display_name = "anthropic-compatible",
        .kind = .recipe,
        .default_wire = .anthropic_messages,
        .base_url = null,
    },
    .{
        .id = "opencode-zen",
        .display_name = "opencode-zen",
        .kind = .recipe,
        .default_wire = .openai_chat,
        .base_url = "https://opencode.ai/zen/v1",
        .catalog_id = "opencode",
        .catalog_wires = true,
    },
    .{
        .id = "opencode-go",
        .display_name = "opencode-go",
        .kind = .recipe,
        .default_wire = .openai_chat,
        .base_url = "https://opencode.ai/zen/go/v1",
        .catalog_id = "opencode-go",
        .catalog_wires = true,
    },
    .{
        .id = "ollama",
        .display_name = "ollama",
        .kind = .recipe,
        .default_wire = .openai_chat,
        .base_url = "http://127.0.0.1:11434/v1",
    },
};

const mock_descriptor: Descriptor = .{
    .id = "mock",
    .display_name = "mock",
    .kind = .builtin,
    .selectable = false,
    .default_wire = null,
    .base_url = null,
};

pub fn find(id: []const u8) ?*const Descriptor {
    const canonical = if (std.mem.eql(u8, id, "llama.cpp")) "llamacpp" else id;
    if (!validId(canonical)) return null;
    // Keep this as two passes: built-ins deliberately win future recipe collisions.
    for (&descriptors) |*descriptor| {
        if (descriptor.kind == .builtin and std.mem.eql(u8, descriptor.id, canonical)) return descriptor;
    }
    if (std.mem.eql(u8, mock_descriptor.id, canonical)) return &mock_descriptor;
    for (&descriptors) |*descriptor| {
        if (descriptor.kind == .recipe and std.mem.eql(u8, descriptor.id, canonical)) return descriptor;
    }
    return null;
}

pub fn order() []const Descriptor {
    return &descriptors;
}

pub fn default() *const Descriptor {
    return &descriptors[0];
}

pub const Auth = union(enum) {
    none,
    bearer: []const u8,
    anthropic_key: []const u8,
    codex: CodexModule.CredentialSource,
};

pub const CacheSetting = enum { automatic, off, on };

/// All members are borrowed. The resolver validates them before putting them in a plan.
pub const Overrides = struct {
    base_url: ?[]const u8 = null,
    display_name: ?[]const u8 = null,
    catalog_id: ?[]const u8 = null,
    wire: ?Wire = null,
    send_cache_key: ?bool = null,
    session_cache_key: ?[]const u8 = null,
    cache: CacheSetting = .automatic,
    cache_ttl: []const u8 = "1h",
    request_cost: ?bool = null,
    reasoning_format: ?OpenAiChat.ReasoningFormat = null,
    reasoning_roundtrip: ?ModelMeta.ReasoningRoundtrip = null,
    reasoning_roundtrip_field: ?[]const u8 = null,
    extra_headers: []const Transport.Header = &.{},
};

pub const WireHint = union(enum) {
    unknown,
    unsupported,
    wire: Wire,
};

/// Metadata and strings remain owned by the caller.
pub const ModelHints = struct {
    reported: ?*const ModelMeta.Metadata = null,
    catalog: ?*const ModelMeta.Metadata = null,
    catalog_wire: WireHint = .unknown,
};

pub const RuleTarget = union(enum) {
    wire: Wire,
    catalog,
};

pub const Rule = struct {
    pattern: []const u8,
    target: RuleTarget,
};

pub const Rules = struct {
    values: []const Rule = &.{},
};

pub const StableMetadata = struct {
    provider_id: []const u8,
    display_name: []const u8,
    catalog_id: ?[]const u8,
    model_id: []const u8,
    wire: Wire,
    efforts: Effort.Set,
    model: ModelMeta.Metadata,
    send_cache_key: bool,
};

pub const AdapterPlan = union(enum) {
    codex: CodexModule.Config,
    openai_responses: OpenAiResponses.Config,
    openai_chat: OpenAiChat.Config,
    anthropic_messages: AnthropicMessages.Config,
};

pub const Resolved = struct {
    allocator: std.mem.Allocator,
    endpoint: []u8,
    metadata: StableMetadata,
    adapter: AdapterPlan,
    cache_setting: CacheSetting,
    owned_headers: ?[]Transport.Header = null,

    /// Returns a request-specific adapter plan. Callers must use this instead of
    /// copying `adapter` directly so AUTO cache policy observes the active pricing tier.
    pub fn adapterForInput(self: *const Resolved, input_tokens: u64) AdapterPlan {
        var plan = self.adapter;
        switch (plan) {
            .openai_chat => |*config| {
                const rates = ModelMeta.ratesForInput(&self.metadata.model, input_tokens);
                const markers = resolveCache(
                    self.metadata.provider_id,
                    self.cache_setting,
                    rates,
                );
                config.body.cache_markers = markers;
                config.events.cache_write_1h = markers and
                    std.mem.eql(u8, config.body.cache_ttl, "1h");
            },
            .codex, .openai_responses, .anthropic_messages => {},
        }
        return plan;
    }

    pub fn deinit(self: *Resolved) void {
        self.allocator.free(self.endpoint);
        if (self.owned_headers) |headers| self.allocator.free(headers);
        self.* = undefined;
    }
};

pub const Error = error{
    OutOfMemory,
    InvalidProviderId,
    UnknownProvider,
    InvalidModelId,
    InvalidAuth,
    InvalidOverride,
    TooManyRules,
    InvalidRule,
    AdapterUnavailable,
    ProviderUnavailable,
    UnsupportedWire,
    MissingSessionCacheKey,
    InvalidHeaderValue,
};

const openrouter_headers = [_]Transport.Header{
    .{ .name = "X-Title", .value = "zi" },
    .{ .name = "HTTP-Referer", .value = "https://github.com/igorsheg/zi" },
    .{ .name = "X-OpenRouter-Categories", .value = "cli-agent" },
};

const MergedHeaders = struct {
    values: []const Transport.Header,
    owned: ?[]Transport.Header = null,
};

fn mergeHeaders(
    allocator: std.mem.Allocator,
    fixed: []const Transport.Header,
    configured: []const Transport.Header,
) error{OutOfMemory}!MergedHeaders {
    if (fixed.len == 0) return .{ .values = configured };
    if (configured.len == 0) return .{ .values = fixed };
    var retained_fixed: usize = 0;
    for (fixed) |header| {
        var replaced = false;
        for (configured) |replacement| {
            if (std.ascii.eqlIgnoreCase(header.name, replacement.name)) {
                replaced = true;
                break;
            }
        }
        retained_fixed += @intFromBool(!replaced);
    }
    if (retained_fixed == 0) return .{ .values = configured };
    const headers = try allocator.alloc(Transport.Header, retained_fixed + configured.len);
    var next: usize = 0;
    for (fixed) |header| {
        var replaced = false;
        for (configured) |replacement| {
            if (std.ascii.eqlIgnoreCase(header.name, replacement.name)) {
                replaced = true;
                break;
            }
        }
        if (!replaced) {
            headers[next] = header;
            next += 1;
        }
    }
    @memcpy(headers[next..], configured);
    return .{ .values = headers, .owned = headers };
}

fn validateAdapterHeaders(
    descriptor_id: []const u8,
    wire: Wire,
    api_key: ?[]const u8,
    headers: []const Transport.Header,
) Error!void {
    if (headers.len > 64) return error.InvalidHeaderValue;
    var header_bytes: usize = switch (wire) {
        .openai_chat, .openai_responses => "Accept".len + "text/event-stream".len +
            "Content-Type".len + "application/json".len,
        .anthropic_messages => "anthropic-version".len + "2023-06-01".len +
            "Accept".len + "text/event-stream".len +
            "Content-Type".len + "application/json".len,
    };
    if (api_key) |key| {
        const auth_bytes = switch (wire) {
            .openai_chat, .openai_responses => "Authorization".len + "Bearer ".len + key.len,
            .anthropic_messages => "x-api-key".len + key.len,
        };
        header_bytes = std.math.add(usize, header_bytes, auth_bytes) catch
            return error.InvalidHeaderValue;
    }
    for (headers, 0..) |header, index| {
        if (!Transport.headerSyntaxValid(header) or Transport.headerIsProtocolOwned(header.name))
            return error.InvalidHeaderValue;
        if (fixedHeaderCollision(descriptor_id, wire, api_key != null, header.name))
            return error.InvalidHeaderValue;
        header_bytes = std.math.add(usize, header_bytes, header.name.len) catch
            return error.InvalidHeaderValue;
        header_bytes = std.math.add(usize, header_bytes, header.value.len) catch
            return error.InvalidHeaderValue;
        if (header_bytes > 16 * 1024) return error.InvalidHeaderValue;
        for (headers[index + 1 ..]) |other| {
            if (std.ascii.eqlIgnoreCase(header.name, other.name)) return error.InvalidHeaderValue;
        }
    }
}

fn fixedHeaderCollision(
    descriptor_id: []const u8,
    wire: Wire,
    has_api_key: bool,
    name: []const u8,
) bool {
    if (std.mem.eql(u8, descriptor_id, "codex")) {
        inline for (.{
            "authorization",
            "chatgpt-account-id",
            "originator",
            "user-agent",
            "session-id",
            "x-client-request-id",
            "openai-beta",
            "accept",
            "content-type",
        }) |fixed| if (std.ascii.eqlIgnoreCase(name, fixed)) return true;
    }
    return switch (wire) {
        .openai_chat, .openai_responses => has_api_key and std.ascii.eqlIgnoreCase(name, "authorization"),
        .anthropic_messages => std.ascii.eqlIgnoreCase(name, "anthropic-version") or
            (has_api_key and std.ascii.eqlIgnoreCase(name, "x-api-key")),
    };
}

pub fn resolve(
    allocator: std.mem.Allocator,
    provider_id: []const u8,
    model_id: []const u8,
    auth: Auth,
    overrides: Overrides,
    hints: ModelHints,
    rules: Rules,
) Error!Resolved {
    if (!validId(if (std.mem.eql(u8, provider_id, "llama.cpp")) "llamacpp" else provider_id))
        return error.InvalidProviderId;
    const descriptor = find(provider_id) orelse return error.UnknownProvider;
    return resolveDescriptor(allocator, descriptor, model_id, auth, overrides, hints, rules);
}

/// Resolves a caller-owned descriptor. The descriptor and every borrowed field
/// retained by the result must outlive it. This admits config-built providers
/// without making the provider-independent registry import config.
pub fn resolveDescriptor(
    allocator: std.mem.Allocator,
    descriptor: *const Descriptor,
    model_id: []const u8,
    auth: Auth,
    overrides: Overrides,
    hints: ModelHints,
    rules: Rules,
) Error!Resolved {
    if (!validId(descriptor.id)) return error.InvalidProviderId;
    if (descriptor.display_name.len == 0 or descriptor.display_name.len > maximum_id_bytes or
        !std.unicode.utf8ValidateSlice(descriptor.display_name) or
        std.mem.indexOfScalar(u8, descriptor.display_name, 0) != null)
        return error.InvalidOverride;
    if (descriptor.catalog_id) |value| if (value.len != 0 and !validId(value))
        return error.InvalidOverride;
    if (std.mem.eql(u8, descriptor.id, "mock")) return error.AdapterUnavailable;
    if (model_id.len == 0 or model_id.len > maximum_model_bytes or
        !std.unicode.utf8ValidateSlice(model_id) or std.mem.indexOfScalar(u8, model_id, 0) != null)
        return error.InvalidModelId;
    try validateOverrides(overrides);
    try validateRules(rules, model_id);
    const effective_catalog_id: ?[]const u8 = if (overrides.catalog_id) |value|
        (if (value.len == 0) null else value)
    else
        descriptor.catalog_id;
    const catalog_enabled = effective_catalog_id != null;
    var rule_wire: ?Wire = null;
    for (rules.values) |rule| {
        if (try globMatches(rule.pattern, model_id)) {
            rule_wire = switch (rule.target) {
                .wire => |wire| wire,
                .catalog => if (catalog_enabled) try catalogWire(hints) else null,
            };
            break;
        }
    }

    const catalog_wire = if (catalog_enabled and rule_wire == null and overrides.wire == null and
        descriptor.catalog_wires)
        try catalogWire(hints)
    else
        null;
    const wire = rule_wire orelse overrides.wire orelse catalog_wire orelse
        descriptor.default_wire orelse return error.UnsupportedWire;
    // Validate the final wire, including rule and catalog outcomes. Pinned
    // descriptors may vary within the OpenAI family, but never cross into or
    // out of Anthropic Messages.
    if (descriptor.pin_base_url) {
        const descriptor_is_anthropic = descriptor.default_wire == .anthropic_messages;
        const selected_is_anthropic = wire == .anthropic_messages;
        if (descriptor_is_anthropic != selected_is_anthropic) return error.InvalidOverride;
    }
    if (std.mem.eql(u8, descriptor.id, "codex") and wire != .openai_responses) {
        return error.InvalidOverride;
    }
    if (descriptor.pin_base_url and overrides.base_url != null) return error.InvalidOverride;

    const base_url = overrides.base_url orelse descriptor.base_url orelse return error.ProviderUnavailable;
    const endpoint = try makeEndpoint(allocator, base_url, wire);
    errdefer allocator.free(endpoint);

    const merged = ModelMeta.merge(hints.reported, if (catalog_enabled) hints.catalog else null);
    const provider_ladder = ladderFor(descriptor.id, wire);
    const unknown_efforts: Effort.Set = .{};
    const reported_efforts = if (hints.reported) |value| &value.efforts else &unknown_efforts;
    const catalog_efforts = if (catalog_enabled)
        if (hints.catalog) |value| &value.efforts else &unknown_efforts
    else
        &unknown_efforts;
    const efforts = ModelMeta.resolveEfforts(&provider_ladder, reported_efforts, catalog_efforts);
    const send_cache_key = overrides.send_cache_key orelse defaultSendCacheKey(descriptor.id);
    const codex_source: ?CodexModule.CredentialSource = switch (auth) {
        .codex => |source| source,
        else => null,
    };
    if (std.mem.eql(u8, descriptor.id, "codex") and codex_source == null) return error.InvalidAuth;
    if (!std.mem.eql(u8, descriptor.id, "codex") and codex_source != null) return error.InvalidAuth;
    const key = if (codex_source == null) try authValue(auth) else null;
    // The pure resolver cannot invent Zi's process/session ID. Callers must inject it.
    if (send_cache_key and overrides.session_cache_key == null) return error.MissingSessionCacheKey;
    if (std.mem.eql(u8, descriptor.id, "codex") and
        !validUuid(overrides.session_cache_key.?)) return error.InvalidOverride;
    const cache_markers = resolveCache(descriptor.id, overrides.cache, merged.rates);
    const is_1h = cache_markers and std.mem.eql(u8, overrides.cache_ttl, "1h");
    const reasoning_field = if (overrides.reasoning_roundtrip_field) |field|
        field
    else if (overrides.reasoning_roundtrip) |roundtrip|
        reasoningField(roundtrip)
    else if (std.mem.eql(u8, descriptor.id, "llamacpp"))
        "reasoning_content"
    else
        reasoningField(merged.reasoning_roundtrip);

    const merged_headers = try mergeHeaders(
        allocator,
        if (std.mem.eql(u8, descriptor.id, "openrouter")) &openrouter_headers else &.{},
        overrides.extra_headers,
    );
    errdefer if (merged_headers.owned) |headers| allocator.free(headers);
    const adapter_headers = merged_headers.values;
    try validateAdapterHeaders(descriptor.id, wire, key, adapter_headers);
    // HTTPS remains unrestricted. The relaxed policy additionally admits
    // privileged configured headers on canonical loopback HTTP only.
    const privileged_header_policy: Transport.PrivilegedHeaderPolicy = .https_or_loopback_http;
    const adapter: AdapterPlan = switch (wire) {
        .openai_responses => if (std.mem.eql(u8, descriptor.id, "codex"))
            .{ .codex = .{
                .source = codex_source.?,
                .session_id = overrides.session_cache_key.?,
                .extra_headers = adapter_headers,
            } }
        else
            .{ .openai_responses = .{
                .provider_id = descriptor.id,
                .endpoint = endpoint,
                .api_key = key,
                .extra_headers = adapter_headers,
                .privileged_header_policy = privileged_header_policy,
                .session_cache_key = if (send_cache_key) overrides.session_cache_key else null,
            } },
        .openai_chat => blk: {
            const emit_progress = std.mem.eql(u8, descriptor.id, "llamacpp");
            break :blk .{ .openai_chat = .{
                .provider_id = descriptor.id,
                .endpoint = endpoint,
                .api_key = key,
                .extra_headers = adapter_headers,
                .privileged_header_policy = privileged_header_policy,
                .body = .{
                    .reasoning_field = reasoning_field,
                    .reasoning_format = overrides.reasoning_format orelse
                        (if (std.mem.eql(u8, descriptor.id, "openrouter")) .nested else .flat),
                    .cache_markers = cache_markers,
                    .cache_ttl = overrides.cache_ttl,
                    .prompt_cache_key = if (send_cache_key) overrides.session_cache_key else null,
                    .emit_progress = emit_progress,
                    .request_cost = overrides.request_cost orelse std.mem.eql(u8, descriptor.id, "openrouter"),
                },
                .events = .{ .emit_progress = emit_progress, .cache_write_1h = is_1h },
            } };
        },
        .anthropic_messages => .{
            .anthropic_messages = .{
                .provider_id = descriptor.id,
                .endpoint = endpoint,
                // AnthropicMessages emits x-api-key. This intentionally maps an OpenCode bearer
                // credential to x-api-key when its catalog routes a model to Messages.
                .api_key = key,
                .extra_headers = adapter_headers,
                .privileged_header_policy = privileged_header_policy,
                .body = .{
                    .thinking_mode = if (std.mem.eql(u8, descriptor.id, "anthropic")) .adaptive else .budget,
                    .cache_markers = overrides.cache != .off and
                        (overrides.cache == .on or std.mem.eql(u8, descriptor.id, "anthropic")),
                    .cache_ttl = overrides.cache_ttl,
                },
            },
        },
    };

    return .{
        .allocator = allocator,
        .endpoint = endpoint,
        .metadata = .{
            .provider_id = descriptor.id,
            .display_name = overrides.display_name orelse descriptor.display_name,
            .catalog_id = effective_catalog_id,
            .model_id = model_id,
            .wire = wire,
            .efforts = efforts,
            .model = merged,
            .send_cache_key = send_cache_key,
        },
        .adapter = adapter,
        .cache_setting = overrides.cache,
        .owned_headers = merged_headers.owned,
    };
}

/// Validates borrowed rules without allocating. Callers which copy rules
/// can use this first so invalid or excessive input fails before retention.
pub fn validateRules(rules: Rules, model_id: []const u8) Error!void {
    if (model_id.len == 0 or model_id.len > maximum_model_bytes or
        !std.unicode.utf8ValidateSlice(model_id) or std.mem.indexOfScalar(u8, model_id, 0) != null)
        return error.InvalidModelId;
    if (rules.values.len > maximum_rules) return error.TooManyRules;
    var total_pattern_bytes: usize = 0;
    var total_glob_work: usize = 0;
    for (rules.values) |rule| {
        if (rule.pattern.len == 0 or rule.pattern.len > maximum_pattern_bytes or
            !std.unicode.utf8ValidateSlice(rule.pattern) or
            std.mem.indexOfScalar(u8, rule.pattern, 0) != null)
            return error.InvalidRule;
        try validateGlob(rule.pattern);
        total_pattern_bytes = std.math.add(usize, total_pattern_bytes, rule.pattern.len) catch
            return error.InvalidRule;
        if (total_pattern_bytes > maximum_total_pattern_bytes) return error.InvalidRule;
        const work = try globWork(rule.pattern, model_id.len);
        total_glob_work = std.math.add(usize, total_glob_work, work) catch
            return error.InvalidRule;
        if (total_glob_work > maximum_glob_work) return error.InvalidRule;
    }
}

/// Reports whether resolving this model may change wire after an unknown catalog
/// wire becomes available. Inputs must satisfy the same validation contract as
/// `resolveDescriptor`.
pub fn catalogWirePending(
    descriptor: *const Descriptor,
    model_id: []const u8,
    overrides: Overrides,
    hints: ModelHints,
    rules: Rules,
) Error!bool {
    const effective_catalog_id: ?[]const u8 = if (overrides.catalog_id) |value|
        (if (value.len == 0) null else value)
    else
        descriptor.catalog_id;
    const catalog_enabled = effective_catalog_id != null;
    const unknown = hints.catalog_wire == .unknown and
        (hints.catalog == null or hints.catalog.?.wire == null);

    for (rules.values) |rule| {
        if (try globMatches(rule.pattern, model_id)) {
            return switch (rule.target) {
                .wire => false,
                .catalog => catalog_enabled and unknown,
            };
        }
    }
    if (overrides.wire != null) return false;
    return catalog_enabled and descriptor.catalog_wires and unknown;
}

fn catalogWire(hints: ModelHints) Error!?Wire {
    return switch (hints.catalog_wire) {
        .unknown => if (hints.catalog) |catalog| catalog.wire else null,
        .unsupported => error.UnsupportedWire,
        .wire => |wire| wire,
    };
}

fn validId(value: []const u8) bool {
    if (value.len == 0 or value.len > maximum_id_bytes or !std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_')) return false;
    }
    return true;
}

fn validateOverrides(overrides: Overrides) Error!void {
    if (overrides.base_url) |value| if (value.len == 0 or value.len > maximum_endpoint_bytes)
        return error.InvalidOverride;
    if (overrides.display_name) |value| if (value.len == 0 or value.len > maximum_id_bytes or
        !std.unicode.utf8ValidateSlice(value)) return error.InvalidOverride;
    if (overrides.catalog_id) |value| if (value.len != 0 and !validId(value)) return error.InvalidOverride;
    if (overrides.session_cache_key) |value| if (value.len == 0 or value.len > maximum_model_bytes)
        return error.InvalidOverride;
    if (!std.mem.eql(u8, overrides.cache_ttl, "1h") and
        !std.mem.eql(u8, overrides.cache_ttl, "5m")) return error.InvalidOverride;
    if (overrides.session_cache_key) |value| {
        if (!std.unicode.utf8ValidateSlice(value) or std.mem.indexOfScalar(u8, value, 0) != null)
            return error.InvalidOverride;
    }
    if (overrides.reasoning_roundtrip_field) |value| {
        if (value.len == 0 or value.len > maximum_id_bytes or !std.unicode.utf8ValidateSlice(value))
            return error.InvalidOverride;
        for (value) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidOverride;
    }
}

fn authValue(auth: Auth) Error!?[]const u8 {
    const value: ?[]const u8 = switch (auth) {
        .none => null,
        .bearer, .anthropic_key => |credential| credential,
        .codex => return error.InvalidAuth,
    };
    if (value) |credential| {
        if (credential.len == 0 or credential.len > maximum_auth_bytes)
            return error.InvalidAuth;
        for (credential) |byte| {
            if ((byte < 0x20 and byte != '\t') or byte == 0x7f) return error.InvalidAuth;
        }
    }
    return value;
}

fn makeEndpoint(allocator: std.mem.Allocator, base_url: []const u8, wire: Wire) Error![]u8 {
    var trimmed = base_url;
    while (trimmed.len > 0 and trimmed[trimmed.len - 1] == '/') trimmed = trimmed[0 .. trimmed.len - 1];
    if (trimmed.len == 0 or trimmed.len + wire.path().len > maximum_endpoint_bytes or
        !(std.mem.startsWith(u8, trimmed, "https://") or std.mem.startsWith(u8, trimmed, "http://")))
        return error.InvalidOverride;
    for (trimmed) |byte| {
        if (byte <= 0x20 or byte == 0x7f or byte == '\\') return error.InvalidOverride;
    }
    const scheme_end = std.mem.indexOf(u8, trimmed, "://") orelse
        return error.InvalidOverride;
    const authority_start = scheme_end + "://".len;
    const authority_end = std.mem.indexOfScalarPos(u8, trimmed, authority_start, '/') orelse
        trimmed.len;
    const authority = trimmed[authority_start..authority_end];
    if (authority.len == 0 or std.mem.indexOfScalar(u8, authority, '%') != null)
        return error.InvalidOverride;

    const uri = std.Uri.parse(trimmed) catch return error.InvalidOverride;
    if (uri.host == null or uri.user != null or uri.password != null or uri.query != null or
        uri.fragment != null or uri.port == 0) return error.InvalidOverride;
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ trimmed, wire.path() });
}

fn defaultSendCacheKey(id: []const u8) bool {
    return std.mem.eql(u8, id, "openai") or std.mem.eql(u8, id, "openrouter") or
        std.mem.eql(u8, id, "codex");
}

fn resolveCache(id: []const u8, setting: CacheSetting, rates: ModelMeta.Rates) bool {
    return switch (setting) {
        .off => false,
        .on => true,
        .automatic => std.mem.eql(u8, id, "openrouter") and rates.cache_write != null and
            ModelMeta.cacheWriteMode(rates) == .replacement,
    };
}

fn reasoningField(value: ModelMeta.ReasoningRoundtrip) ?[]const u8 {
    return switch (value) {
        .unknown, .none => null,
        .field => |field| switch (field) {
            .reasoning => "reasoning",
            .reasoning_content => "reasoning_content",
        },
    };
}

fn ladderFor(id: []const u8, wire: Wire) Effort.Set {
    if (std.mem.eql(u8, id, "codex")) {
        return Effort.Set.init(&.{ "none", "low", "medium", "high", "xhigh", "max" }) catch unreachable;
    }
    if (std.mem.eql(u8, id, "ollama")) return Effort.Set.init(&.{}) catch unreachable;
    return switch (wire) {
        .anthropic_messages => Effort.Set.init(&.{ "low", "medium", "high", "xhigh", "max" }) catch unreachable,
        .openai_chat, .openai_responses => Effort.Set.init(&Effort.canonical_ladder) catch unreachable,
    };
}

const BracketResult = struct {
    end: usize,
    matched: bool,
};

fn validUuid(value: []const u8) bool {
    if (value.len != 36 or value[14] != '4' or
        !(value[19] == '8' or value[19] == '9' or value[19] == 'a' or value[19] == 'b'))
    {
        return false;
    }
    for (value, 0..) |byte, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (byte != '-') return false;
        } else if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
}

fn validateGlob(pattern: []const u8) Error!void {
    var index: usize = 0;
    while (index < pattern.len) {
        switch (pattern[index]) {
            '\\' => {
                index += 1;
                if (index == pattern.len) return error.InvalidRule;
                index = try scalarEnd(pattern, index);
            },
            '[' => index = (try parseBracket(pattern, index, null)).end,
            else => index = try scalarEnd(pattern, index),
        }
    }
}

fn globWork(pattern: []const u8, value_bytes: usize) Error!usize {
    const value_width = std.math.add(usize, value_bytes, 1) catch return error.InvalidRule;
    var units = pattern.len;
    var index: usize = 0;
    while (index < pattern.len) {
        if (pattern[index] == '[') {
            const end = (try parseBracket(pattern, index, null)).end;
            units = std.math.add(usize, units, end - index) catch return error.InvalidRule;
            index = end;
        } else if (pattern[index] == '\\') {
            index += 1;
            index = try scalarEnd(pattern, index);
        } else {
            index = try scalarEnd(pattern, index);
        }
    }
    return std.math.mul(usize, units, value_width) catch return error.InvalidRule;
}

/// POSIX fnmatch model patterns. `*` also matches `/`, as it does in hax model IDs.
fn globMatches(pattern: []const u8, value: []const u8) Error!bool {
    var previous_storage: [maximum_model_bytes + 1]bool = @splat(false);
    var next_storage: [maximum_model_bytes + 1]bool = @splat(false);
    var previous = previous_storage[0 .. value.len + 1];
    var next = next_storage[0 .. value.len + 1];
    previous[0] = true;

    var pattern_index: usize = 0;
    while (pattern_index < pattern.len) {
        @memset(next, false);
        if (pattern[pattern_index] == '*') {
            next[0] = previous[0];
            var value_index: usize = 0;
            while (value_index < value.len) {
                const value_end = try scalarEnd(value, value_index);
                next[value_end] = previous[value_end] or next[value_index];
                value_index = value_end;
            }
            pattern_index += 1;
        } else {
            const bracket = pattern[pattern_index] == '[';
            const escaped = pattern[pattern_index] == '\\';
            var token_end: usize = undefined;
            var literal: ?u21 = null;
            if (!bracket) {
                if (escaped) pattern_index += 1;
                token_end = try scalarEnd(pattern, pattern_index);
                literal = try decodeScalar(pattern, pattern_index);
            }

            var value_index: usize = 0;
            while (value_index < value.len) {
                const value_end = try scalarEnd(value, value_index);
                if (previous[value_index]) {
                    const scalar = try decodeScalar(value, value_index);
                    const matches = if (bracket)
                        (try parseBracket(pattern, pattern_index, scalar)).matched
                    else if (!escaped and pattern[pattern_index] == '?')
                        true
                    else
                        scalar == literal.?;
                    if (matches) next[value_end] = true;
                }
                value_index = value_end;
            }
            if (bracket) {
                token_end = (try parseBracket(pattern, pattern_index, null)).end;
            }
            pattern_index = token_end;
        }
        const temporary = previous;
        previous = next;
        next = temporary;
    }
    return previous[value.len];
}

fn parseBracket(pattern: []const u8, start: usize, candidate: ?u21) Error!BracketResult {
    var index = start + 1;
    if (index >= pattern.len) return error.InvalidRule;
    var negated = false;
    if (pattern[index] == '!' or pattern[index] == '^') {
        negated = true;
        index += 1;
    }

    var matched = false;
    var members: usize = 0;
    if (index < pattern.len and pattern[index] == ']') {
        matched = candidate != null and candidate.? == ']';
        members += 1;
        index += 1;
    }
    while (index < pattern.len and pattern[index] != ']') {
        if (pattern[index] == '[' and index + 1 < pattern.len) {
            if (pattern[index + 1] == '.' or pattern[index + 1] == '=') {
                return error.InvalidRule;
            }
            if (pattern[index + 1] == ':') {
                const class_end = std.mem.indexOfPos(u8, pattern, index + 2, ":]") orelse
                    return error.InvalidRule;
                const name = pattern[index + 2 .. class_end];
                if (!validClass(name)) return error.InvalidRule;
                if (candidate) |scalar| matched = matched or classMatches(name, scalar);
                members += 1;
                index = class_end + 2;
                continue;
            }
        }

        const first = try bracketScalar(pattern, &index);
        members += 1;
        if (index < pattern.len and pattern[index] == '-' and
            index + 1 < pattern.len and pattern[index + 1] != ']')
        {
            index += 1;
            if (pattern[index] == '[' and index + 1 < pattern.len and
                (pattern[index + 1] == ':' or pattern[index + 1] == '.' or
                    pattern[index + 1] == '=')) return error.InvalidRule;
            const last = try bracketScalar(pattern, &index);
            if (last < first) return error.InvalidRule;
            if (candidate) |scalar| matched = matched or (scalar >= first and scalar <= last);
        } else if (candidate) |scalar| {
            matched = matched or scalar == first;
        }
    }
    if (index >= pattern.len or members == 0) return error.InvalidRule;
    return .{ .end = index + 1, .matched = if (negated) !matched else matched };
}

fn bracketScalar(pattern: []const u8, index: *usize) Error!u21 {
    if (pattern[index.*] == '\\') {
        index.* += 1;
        if (index.* >= pattern.len) return error.InvalidRule;
    }
    const scalar = try decodeScalar(pattern, index.*);
    index.* = try scalarEnd(pattern, index.*);
    return scalar;
}

fn scalarEnd(value: []const u8, start: usize) Error!usize {
    const length = std.unicode.utf8ByteSequenceLength(value[start]) catch
        return error.InvalidRule;
    const end = start + length;
    if (end > value.len) return error.InvalidRule;
    _ = try decodeScalar(value, start);
    return end;
}

fn decodeScalar(value: []const u8, start: usize) Error!u21 {
    const length = std.unicode.utf8ByteSequenceLength(value[start]) catch
        return error.InvalidRule;
    const end = start + length;
    if (end > value.len) return error.InvalidRule;
    return switch (length) {
        1 => value[start],
        2 => std.unicode.utf8Decode2(value[start..end][0..2].*) catch
            return error.InvalidRule,
        3 => std.unicode.utf8Decode3(value[start..end][0..3].*) catch
            return error.InvalidRule,
        4 => std.unicode.utf8Decode4(value[start..end][0..4].*) catch
            return error.InvalidRule,
        else => unreachable,
    };
}

fn validClass(name: []const u8) bool {
    inline for (.{
        "alnum", "alpha", "blank", "cntrl", "digit",  "graph", "lower",
        "print", "punct", "space", "upper", "xdigit",
    }) |known| {
        if (std.mem.eql(u8, name, known)) return true;
    }
    return false;
}

fn classMatches(name: []const u8, scalar: u21) bool {
    if (scalar > 0x7f) return false;
    const byte: u8 = @intCast(scalar);
    if (std.mem.eql(u8, name, "alnum")) return std.ascii.isAlphanumeric(byte);
    if (std.mem.eql(u8, name, "alpha")) return std.ascii.isAlphabetic(byte);
    if (std.mem.eql(u8, name, "blank")) return byte == ' ' or byte == '\t';
    if (std.mem.eql(u8, name, "cntrl")) return byte < 0x20 or byte == 0x7f;
    if (std.mem.eql(u8, name, "digit")) return std.ascii.isDigit(byte);
    if (std.mem.eql(u8, name, "graph")) return byte >= 0x21 and byte <= 0x7e;
    if (std.mem.eql(u8, name, "lower")) return std.ascii.isLower(byte);
    if (std.mem.eql(u8, name, "print")) return byte >= 0x20 and byte <= 0x7e;
    if (std.mem.eql(u8, name, "punct")) return byte >= 0x21 and byte <= 0x7e and
        !std.ascii.isAlphanumeric(byte);
    if (std.mem.eql(u8, name, "space")) return std.ascii.isWhitespace(byte);
    if (std.mem.eql(u8, name, "upper")) return std.ascii.isUpper(byte);
    if (std.mem.eql(u8, name, "xdigit")) return std.ascii.isHex(byte);
    unreachable;
}

test "registry order visibility alias and invalid ids" {
    try std.testing.expectEqualStrings("codex", default().id);
    try std.testing.expectEqualStrings("llamacpp", find("llama.cpp").?.id);
    try std.testing.expect(find("mock") != null);
    try std.testing.expect(!find("mock").?.selectable);
    try std.testing.expect(find("") == null);
    try std.testing.expect(find("open.ai") == null);
    try std.testing.expectEqual(@as(usize, 10), order().len);
}

test "resolution snapshots rules endpoints mixed wires and policy" {
    const rules = [_]Rule{
        .{ .pattern = "claude-*", .target = .{ .wire = .anthropic_messages } },
        .{ .pattern = "*", .target = .{ .wire = .openai_chat } },
    };
    var result = try resolve(
        std.testing.allocator,
        "opencode-zen",
        "claude-sonnet",
        .{ .bearer = "key" },
        .{},
        .{},
        .{ .values = &rules },
    );
    defer result.deinit();
    try std.testing.expectEqual(Wire.anthropic_messages, result.metadata.wire);
    try std.testing.expectEqualStrings("https://opencode.ai/zen/v1/messages", result.endpoint);
    try std.testing.expectEqualStrings("key", result.adapter.anthropic_messages.api_key.?);
    try std.testing.expectEqual(@as(u8, 5), result.metadata.efforts.count);

    var router = try resolve(
        std.testing.allocator,
        "openrouter",
        "m",
        .none,
        .{ .send_cache_key = false, .catalog_id = "openrouter" },
        .{ .catalog = &.{ .rates = .{ .cache_write = 2 } } },
        .{},
    );
    defer router.deinit();
    try std.testing.expectEqualStrings("https://openrouter.ai/api/v1/chat/completions", router.endpoint);
    try std.testing.expect(router.adapter.openai_chat.body.cache_markers);
    try std.testing.expect(router.adapter.openai_chat.body.request_cost);
    try std.testing.expectEqual(
        OpenAiChat.ReasoningFormat.nested,
        router.adapter.openai_chat.body.reasoning_format,
    );
}

test "compatible needs a base and catalog unsupported does not guess" {
    try std.testing.expectError(
        error.ProviderUnavailable,
        resolve(std.testing.allocator, "openai-compatible", "m", .none, .{}, .{}, .{}),
    );
    try std.testing.expectError(
        error.UnsupportedWire,
        resolve(
            std.testing.allocator,
            "opencode-go",
            "m",
            .none,
            .{},
            .{ .catalog_wire = .unsupported },
            .{},
        ),
    );
    try std.testing.expectError(
        error.InvalidAuth,
        resolve(std.testing.allocator, "codex", "m", .none, .{}, .{}, .{}),
    );
}

test "resolver allocation failures are clean" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var result = try resolve(allocator, "ollama", "qwen", .none, .{}, .{}, .{});
            defer result.deinit();
            try std.testing.expectEqual(@as(u8, 0), result.metadata.efforts.count);
            try std.testing.expectEqual(
                Transport.PrivilegedHeaderPolicy.https_or_loopback_http,
                result.adapter.openai_chat.privileged_header_policy,
            );
        }
    }.run, .{});
}

test "descriptor recipes and default plans are exact" {
    const expected = [_]struct {
        id: []const u8,
        wire: Wire,
        base: ?[]const u8,
        catalog: ?[]const u8,
    }{
        .{
            .id = "codex",
            .wire = .openai_responses,
            .base = "https://chatgpt.com/backend-api/codex",
            .catalog = "openai",
        },
        .{ .id = "llamacpp", .wire = .openai_chat, .base = "http://127.0.0.1:8080/v1", .catalog = null },
        .{ .id = "openai", .wire = .openai_responses, .base = "https://api.openai.com/v1", .catalog = "openai" },
        .{
            .id = "anthropic",
            .wire = .anthropic_messages,
            .base = "https://api.anthropic.com/v1",
            .catalog = "anthropic",
        },
        .{ .id = "openrouter", .wire = .openai_chat, .base = "https://openrouter.ai/api/v1", .catalog = null },
        .{ .id = "openai-compatible", .wire = .openai_chat, .base = null, .catalog = null },
        .{ .id = "anthropic-compatible", .wire = .anthropic_messages, .base = null, .catalog = null },
        .{ .id = "opencode-zen", .wire = .openai_chat, .base = "https://opencode.ai/zen/v1", .catalog = "opencode" },
        .{
            .id = "opencode-go",
            .wire = .openai_chat,
            .base = "https://opencode.ai/zen/go/v1",
            .catalog = "opencode-go",
        },
        .{ .id = "ollama", .wire = .openai_chat, .base = "http://127.0.0.1:11434/v1", .catalog = null },
    };
    try std.testing.expectEqual(expected.len, descriptors.len);
    for (expected, descriptors) |want, actual| {
        try std.testing.expectEqualStrings(want.id, actual.id);
        try std.testing.expectEqual(want.wire, actual.default_wire.?);
        if (want.base) |value| {
            try std.testing.expectEqualStrings(value, actual.base_url.?);
        } else try std.testing.expect(actual.base_url == null);
        if (want.catalog) |value| {
            try std.testing.expectEqualStrings(value, actual.catalog_id.?);
        } else try std.testing.expect(actual.catalog_id == null);
    }
}

test "first party adapter plans preserve pinned auth headers and policy" {
    var openai = try resolve(
        std.testing.allocator,
        "openai",
        "gpt",
        .{ .bearer = "openai-key" },
        .{ .session_cache_key = "session" },
        .{},
        .{},
    );
    defer openai.deinit();
    try std.testing.expectEqualStrings("https://api.openai.com/v1/responses", openai.endpoint);
    try std.testing.expectEqualStrings("openai-key", openai.adapter.openai_responses.api_key.?);
    try std.testing.expectEqualStrings("session", openai.adapter.openai_responses.session_cache_key.?);
    var openai_without_key = try resolve(
        std.testing.allocator,
        "openai",
        "gpt",
        .none,
        .{ .send_cache_key = false },
        .{},
        .{},
    );
    openai_without_key.deinit();
    try std.testing.expectError(error.InvalidOverride, resolve(
        std.testing.allocator,
        "openai",
        "gpt",
        .{ .bearer = "key" },
        .{ .base_url = "https://proxy.test/v1" },
        .{},
        .{},
    ));

    var anthropic = try resolve(
        std.testing.allocator,
        "anthropic",
        "claude",
        .{ .anthropic_key = "anthropic-key" },
        .{},
        .{},
        .{},
    );
    defer anthropic.deinit();
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1/messages", anthropic.endpoint);
    try std.testing.expectEqualStrings("anthropic-key", anthropic.adapter.anthropic_messages.api_key.?);
    try std.testing.expectEqual(
        AnthropicMessages.ThinkingMode.adaptive,
        anthropic.adapter.anthropic_messages.body.thinking_mode,
    );
    try std.testing.expect(anthropic.adapter.anthropic_messages.body.cache_markers);
}

test "compatible routing is bounded explicit and never silently misroutes Responses" {
    var compatible = try resolve(
        std.testing.allocator,
        "openai-compatible",
        "model",
        .none,
        .{ .base_url = "https://gateway.test/root///", .cache = .on, .cache_ttl = "1h" },
        .{},
        .{},
    );
    defer compatible.deinit();
    try std.testing.expectEqualStrings("https://gateway.test/root/chat/completions", compatible.endpoint);
    try std.testing.expect(compatible.adapter.openai_chat.body.cache_markers);
    try std.testing.expect(compatible.adapter.openai_chat.events.cache_write_1h);
    try std.testing.expect(!compatible.metadata.send_cache_key);

    try std.testing.expectError(error.InvalidOverride, resolve(
        std.testing.allocator,
        "openai-compatible",
        "model",
        .none,
        .{ .base_url = "https://user@gateway.test/v1" },
        .{},
        .{},
    ));
    var responses = try resolve(
        std.testing.allocator,
        "opencode-zen",
        "response-model",
        .{ .bearer = "key" },
        .{},
        .{},
        .{ .values = &.{.{ .pattern = "*", .target = .{ .wire = .openai_responses } }} },
    );
    defer responses.deinit();
    try std.testing.expectEqualStrings(
        "https://opencode.ai/zen/v1/responses",
        responses.endpoint,
    );
    try std.testing.expectEqualStrings(
        "opencode-zen",
        responses.adapter.openai_responses.provider_id,
    );
}

test "all rules validate and metadata narrows provider effort policy" {
    const bad_rules = [_]Rule{
        .{ .pattern = "*", .target = .{ .wire = .openai_chat } },
        .{ .pattern = "", .target = .{ .wire = .openai_chat } },
    };
    try std.testing.expectError(error.InvalidRule, resolve(
        std.testing.allocator,
        "ollama",
        "model",
        .none,
        .{},
        .{},
        .{ .values = &bad_rules },
    ));

    const catalog_efforts = try Effort.Set.init(&.{ "medium", "high" });
    const catalog: ModelMeta.Metadata = .{ .efforts = catalog_efforts };
    var result = try resolve(
        std.testing.allocator,
        "openrouter",
        "model",
        .none,
        .{ .send_cache_key = false, .catalog_id = "openrouter" },
        .{ .catalog = &catalog },
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 2), result.metadata.efforts.count);
    try std.testing.expectEqualStrings("medium", result.metadata.efforts.valueAt(0));
    try std.testing.expectEqualStrings("high", result.metadata.efforts.valueAt(1));
    try std.testing.expectEqual(@as(usize, 3), result.adapter.openai_chat.extra_headers.len);
    try std.testing.expectEqualStrings("zi", result.adapter.openai_chat.extra_headers[0].value);
}

test "fnmatch rules support POSIX forms and Unicode scalar question" {
    try validateGlob("claude-[34]*");
    try std.testing.expect(try globMatches("claude-[34]*", "claude-3-opus"));
    try std.testing.expect(!(try globMatches("claude-[34]*", "claude-2-opus")));
    try std.testing.expect(try globMatches("literal-\\*", "literal-*"));
    try std.testing.expect(try globMatches("literal-\\?", "literal-?"));
    try std.testing.expect(!(try globMatches("literal-\\?", "literal-x")));
    try std.testing.expect(try globMatches("model-[!0-9]", "model-x"));
    try std.testing.expect(!(try globMatches("model-[^0-9]", "model-7")));
    try std.testing.expect(try globMatches("model-[[:digit:]]", "model-7"));
    try std.testing.expect(try globMatches("m?del", "médel"));
    try std.testing.expect(!(try globMatches("m?del", "méédel")));
}

test "malformed and excessive fnmatch rules are rejected before matching" {
    inline for (.{
        "unterminated-[abc",
        "trailing-\\",
        "[[.ch.]]",
        "[[=a=]]",
        "[[:unknown:]]",
        "[z-a]",
    }) |pattern| {
        try std.testing.expectError(error.InvalidRule, validateGlob(pattern));
    }

    const expensive_pattern: [maximum_pattern_bytes]u8 = @splat('*');
    const expensive_rules = [_]Rule{
        .{ .pattern = &expensive_pattern, .target = .{ .wire = .openai_chat } },
        .{ .pattern = &expensive_pattern, .target = .{ .wire = .openai_chat } },
        .{ .pattern = &expensive_pattern, .target = .{ .wire = .openai_chat } },
        .{ .pattern = &expensive_pattern, .target = .{ .wire = .openai_chat } },
        .{ .pattern = &expensive_pattern, .target = .{ .wire = .openai_chat } },
    };
    const long_model: [maximum_model_bytes]u8 = @splat('m');
    try std.testing.expectError(error.InvalidRule, resolve(
        std.testing.allocator,
        "ollama",
        &long_model,
        .none,
        .{},
        .{},
        .{ .values = &expensive_rules },
    ));
}

test "endpoint validation rejects raw URI hazards and malformed authorities" {
    inline for (.{
        "https://gateway.test/a b",
        "https://gateway.test/a\\b",
        "https://gate%77ay.test/v1",
        "https:///v1",
        "https://user@gateway.test/v1",
        "https://gateway.test/v1?query",
        "https://gateway.test/v1#fragment",
        "https://gateway.test:0/v1",
        "ftp://gateway.test/v1",
    }) |base_url| {
        try std.testing.expectError(error.InvalidOverride, resolve(
            std.testing.allocator,
            "openai-compatible",
            "model",
            .none,
            .{ .base_url = base_url },
            .{},
            .{},
        ));
    }

    const del_url = "https://gateway.test/a" ++ [_]u8{0x7f};
    try std.testing.expectError(error.InvalidOverride, resolve(
        std.testing.allocator,
        "openai-compatible",
        "model",
        .none,
        .{ .base_url = del_url[0..] },
        .{},
        .{},
    ));

    var encoded_path = try resolve(
        std.testing.allocator,
        "openai-compatible",
        "model",
        .none,
        .{ .base_url = "https://gateway.test/a%20b" },
        .{},
        .{},
    );
    defer encoded_path.deinit();
    try std.testing.expectEqualStrings(
        "https://gateway.test/a%20b/chat/completions",
        encoded_path.endpoint,
    );
}

test "pinned API policy and catalog wire scope preserve rule priority" {
    inline for (.{ "openai", "anthropic", "openrouter" }) |provider_id| {
        try std.testing.expectError(error.InvalidOverride, resolve(
            std.testing.allocator,
            provider_id,
            "model",
            .none,
            .{ .base_url = "https://proxy.test/v1", .send_cache_key = false },
            .{},
            .{},
        ));
    }
    try std.testing.expectError(error.InvalidOverride, resolve(
        std.testing.allocator,
        "anthropic",
        "model",
        .none,
        .{ .wire = .openai_chat },
        .{},
        .{},
    ));
    try std.testing.expectError(error.InvalidOverride, resolve(
        std.testing.allocator,
        "openai",
        "model",
        .none,
        .{ .wire = .anthropic_messages, .send_cache_key = false },
        .{},
        .{},
    ));

    try std.testing.expectError(error.InvalidOverride, resolve(
        std.testing.allocator,
        "openai",
        "claude-model",
        .{ .anthropic_key = "key" },
        .{ .send_cache_key = false },
        .{ .catalog_wire = .{ .wire = .openai_chat } },
        .{ .values = &.{.{ .pattern = "claude-*", .target = .{ .wire = .anthropic_messages } }} },
    ));

    var ignored_catalog = try resolve(
        std.testing.allocator,
        "openai",
        "model",
        .none,
        .{ .send_cache_key = false },
        .{ .catalog_wire = .{ .wire = .openai_chat } },
        .{},
    );
    defer ignored_catalog.deinit();
    try std.testing.expectEqual(Wire.openai_responses, ignored_catalog.metadata.wire);

    var explicit = try resolve(
        std.testing.allocator,
        "opencode-zen",
        "model",
        .none,
        .{ .wire = .openai_chat },
        .{ .catalog_wire = .unsupported },
        .{},
    );
    defer explicit.deinit();
    try std.testing.expectEqual(Wire.openai_chat, explicit.metadata.wire);
}

test "auth follows the selected wire and OpenRouter headers cover Messages" {
    var anthropic_bearer = try resolve(
        std.testing.allocator,
        "anthropic",
        "claude",
        .{ .bearer = "bearer-key" },
        .{},
        .{},
        .{},
    );
    defer anthropic_bearer.deinit();
    try std.testing.expectEqualStrings("bearer-key", anthropic_bearer.adapter.anthropic_messages.api_key.?);

    try std.testing.expectError(error.InvalidOverride, resolve(
        std.testing.allocator,
        "openrouter",
        "claude",
        .{ .anthropic_key = "router-key" },
        .{ .send_cache_key = false },
        .{},
        .{ .values = &.{.{ .pattern = "*", .target = .{ .wire = .anthropic_messages } }} },
    ));
}

test "cache-key sending requires an injected session ID" {
    try std.testing.expectError(error.MissingSessionCacheKey, resolve(
        std.testing.allocator,
        "openrouter",
        "model",
        .none,
        .{},
        .{},
        .{},
    ));
    try std.testing.expectError(error.MissingSessionCacheKey, resolve(
        std.testing.allocator,
        "ollama",
        "model",
        .none,
        .{ .send_cache_key = true },
        .{},
        .{},
    ));
}

test "AUTO cache planning uses the request input pricing tier" {
    const tiers = try ModelMeta.Tiers.init(&.{.{
        .context_threshold = 100,
        .rates = .{ .input = 10 },
    }});
    const catalog: ModelMeta.Metadata = .{
        .rates = .{ .input = 2, .output = 4, .cache_write = 2.5 },
        .tiers = tiers,
    };
    var result = try resolve(
        std.testing.allocator,
        "openrouter",
        "model",
        .none,
        .{ .session_cache_key = "session", .catalog_id = "openrouter" },
        .{ .catalog = &catalog },
        .{},
    );
    defer result.deinit();
    const base = result.adapterForInput(100);
    try std.testing.expect(base.openai_chat.body.cache_markers);
    const tier = result.adapterForInput(101);
    try std.testing.expect(!tier.openai_chat.body.cache_markers);
    try std.testing.expect(!tier.openai_chat.events.cache_write_1h);
}

const RegistryCodexSource = struct {
    pub fn acquire(
        _: *RegistryCodexSource,
        allocator: std.mem.Allocator,
        _: std.Io,
        _: ?Provider.Tick,
        _: CodexModule.AcquirePurpose,
    ) CodexModule.CredentialSource.CallbackError!CodexModule.AcquireDecision {
        return .{ .ready = try CodexModule.OwnedCredential.init(allocator, .{
            .access_token = "token",
            .account_id = "account",
        }) };
    }

    pub fn recoverUnauthorized(
        _: *RegistryCodexSource,
        _: std.mem.Allocator,
        _: std.Io,
        _: ?Provider.Tick,
        _: CodexModule.Credential,
    ) CodexModule.CredentialSource.CallbackError!CodexModule.UnauthorizedDecision {
        return .use_response;
    }

    pub fn noteUnauthorized(_: *RegistryCodexSource, _: CodexModule.Credential) void {}
};

test "Codex registry plan requires typed credentials and a canonical session ID" {
    var source: RegistryCodexSource = .{};
    const auth: Auth = .{ .codex = CodexModule.CredentialSource.from(&source) };
    try std.testing.expectError(error.MissingSessionCacheKey, resolve(
        std.testing.allocator,
        "codex",
        "gpt-5.4",
        auth,
        .{},
        .{},
        .{},
    ));
    try std.testing.expectError(error.InvalidOverride, resolve(
        std.testing.allocator,
        "codex",
        "gpt-5.4",
        auth,
        .{ .session_cache_key = "not-a-uuid" },
        .{},
        .{},
    ));
    var result = try resolve(
        std.testing.allocator,
        "codex",
        "gpt-5.4",
        auth,
        .{
            .session_cache_key = "12345678-1234-4234-8234-123456789abc",
            .extra_headers = &.{.{ .name = "X-Test", .value = "value" }},
        },
        .{},
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(CodexModule.endpoint, result.endpoint);
    try std.testing.expectEqualStrings(
        "12345678-1234-4234-8234-123456789abc",
        result.adapter.codex.session_id,
    );
    try std.testing.expectEqualStrings("openai", result.metadata.catalog_id.?);
    try std.testing.expectEqualStrings("X-Test", result.adapter.codex.extra_headers[0].name);
    try std.testing.expectEqual(@as(u8, 6), result.metadata.efforts.count);
}

test "pinned descriptors reject cross-family rule and catalog wires" {
    try std.testing.expectError(error.InvalidOverride, resolve(
        std.testing.allocator,
        "openai",
        "claude",
        .none,
        .{ .send_cache_key = false },
        .{},
        .{ .values = &.{.{ .pattern = "*", .target = .{ .wire = .anthropic_messages } }} },
    ));
    try std.testing.expectError(error.InvalidOverride, resolve(
        std.testing.allocator,
        "anthropic",
        "gpt",
        .none,
        .{},
        .{},
        .{ .values = &.{.{ .pattern = "*", .target = .{ .wire = .openai_responses } }} },
    ));
    try std.testing.expectError(error.InvalidOverride, resolve(
        std.testing.allocator,
        "openai",
        "catalog-model",
        .none,
        .{ .send_cache_key = false },
        .{ .catalog_wire = .{ .wire = .anthropic_messages } },
        .{ .values = &.{.{ .pattern = "*", .target = .catalog }} },
    ));
}

test "empty effective catalog disables wire and metadata hints" {
    const descriptor: Descriptor = .{
        .id = "custom",
        .display_name = "custom",
        .kind = .recipe,
        .default_wire = .openai_chat,
        .base_url = "https://custom.test/v1",
        .catalog_id = "catalog",
        .catalog_wires = true,
    };
    const catalog: ModelMeta.Metadata = .{
        .wire = .anthropic_messages,
        .rates = .{ .input = 1, .cache_write = 2 },
        .reasoning_roundtrip = .{ .field = .reasoning },
    };
    var result = try resolveDescriptor(
        std.testing.allocator,
        &descriptor,
        "model",
        .none,
        .{ .catalog_id = "" },
        .{ .catalog = &catalog, .catalog_wire = .{ .wire = .anthropic_messages } },
        .{},
    );
    defer result.deinit();
    try std.testing.expect(result.metadata.catalog_id == null);
    try std.testing.expect(result.metadata.wire == .openai_chat);
    try std.testing.expect(result.metadata.model.rates.input == null);
    try std.testing.expect(result.adapter.openai_chat.body.reasoning_field == null);
}

test "rule validation is allocation-free and enforces aggregate bounds" {
    var patterns: [maximum_rules][]const u8 = undefined;
    var rules: [maximum_rules]Rule = undefined;
    const pattern = "x" ** maximum_pattern_bytes;
    for (&rules, 0..) |*rule, index| {
        patterns[index] = pattern;
        rule.* = .{ .pattern = patterns[index], .target = .{ .wire = .openai_chat } };
    }
    try validateRules(.{ .values = &rules }, "model");
    rules[maximum_rules - 1].pattern = pattern ++ "x";
    try std.testing.expectError(error.InvalidRule, validateRules(.{ .values = &rules }, "model"));
}

test "adapter header validation covers aggregate bounds and wire-specific collisions" {
    var too_many: [65]Transport.Header = undefined;
    for (&too_many) |*header| header.* = .{ .name = "X-Test", .value = "value" };
    try std.testing.expectError(
        error.InvalidHeaderValue,
        validateAdapterHeaders("openai", .openai_chat, null, &too_many),
    );

    const version = &.{Transport.Header{ .name = "anthropic-version", .value = "custom" }};
    try validateAdapterHeaders("gateway", .openai_chat, null, version);
    try std.testing.expectError(
        error.InvalidHeaderValue,
        validateAdapterHeaders("gateway", .anthropic_messages, null, version),
    );
    try std.testing.expectError(
        error.InvalidHeaderValue,
        validateAdapterHeaders(
            "gateway",
            .openai_chat,
            null,
            &.{.{ .name = "Host", .value = "other.test" }},
        ),
    );
    try std.testing.expectError(
        error.InvalidHeaderValue,
        validateAdapterHeaders(
            "gateway",
            .openai_chat,
            null,
            &.{.{ .name = "Bad Name", .value = "value" }},
        ),
    );
    try std.testing.expectError(
        error.InvalidHeaderValue,
        validateAdapterHeaders(
            "codex",
            .openai_responses,
            null,
            &.{.{ .name = "User-Agent", .value = "custom" }},
        ),
    );
}

test "OpenRouter configured attribution headers replace defaults" {
    var result = try resolve(
        std.testing.allocator,
        "openrouter",
        "model",
        .{ .bearer = "secret" },
        .{
            .extra_headers = &.{.{ .name = "x-title", .value = "custom" }},
            .session_cache_key = "session",
        },
        .{},
        .{},
    );
    defer result.deinit();
    const headers = result.adapter.openai_chat.extra_headers;
    try std.testing.expectEqual(@as(usize, 3), headers.len);
    try std.testing.expectEqualStrings("x-title", headers[2].name);
    try std.testing.expectEqualStrings("custom", headers[2].value);
}

test "configured headers reach every generic HTTP adapter" {
    inline for (.{ Wire.openai_chat, Wire.openai_responses, Wire.anthropic_messages }) |wire| {
        const descriptor: Descriptor = .{
            .id = "gateway",
            .display_name = "gateway",
            .kind = .recipe,
            .selectable = true,
            .default_wire = wire,
            .base_url = "https://gateway.test/v1",
        };
        var result = try resolveDescriptor(
            std.testing.allocator,
            &descriptor,
            "model",
            .none,
            .{ .extra_headers = &.{.{ .name = "X-Test", .value = "value" }} },
            .{},
            .{},
        );
        defer result.deinit();
        const headers = switch (result.adapter) {
            .openai_chat => |config| config.extra_headers,
            .openai_responses => |config| config.extra_headers,
            .anthropic_messages => |config| config.extra_headers,
            .codex => unreachable,
        };
        try std.testing.expectEqual(@as(usize, 1), headers.len);
        try std.testing.expectEqualStrings("X-Test", headers[0].name);
    }
}
