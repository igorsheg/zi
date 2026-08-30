const std = @import("std");
const ai = @import("ai/root.zig");
const ProviderConfig = @import("ProviderConfig.zig");
const ProviderHeaders = @import("ProviderHeaders.zig");

const Factory = ai.ProviderFactory;
const Provider = ai.Provider;
const Registry = ai.ProviderRegistry;
const Transport = ai.Transport;

pub const InitError = ProviderConfig.ResolveError;

/// Heap-stable, move-only provider composition. Move this handle, never copy it
/// or deinitialize two copies. The configuration and factory have separate
/// stable heap addresses, so moving the handle does not invalidate a provider
/// returned by `provider`.
///
/// The streaming and optional JSON transport implementations and contexts are
/// borrowed. They must outlive this value, every returned erased handle, and
/// each synchronous call. `Inputs.codex_source`, when present, is also borrowed
/// under `ProviderConfig.Inputs`' lifetime rule. Provider and listing calls
/// are serialized with catalog replacement and input-token updates. Catalog or
/// token mutation from a transport or sink callback is not allowed. Call
/// `deinit` exactly once, after all copied provider handles have stopped being used.
/// Listing-only provider composition. It deliberately exposes no streaming
/// provider handle and cannot enter RunSelection.commit.
pub const ListingOwned = struct {
    config: *ProviderConfig.Owned,
    json_transport: ?ai.JsonTransport.Transport,

    pub fn deinit(self: *ListingOwned) void {
        self.config.deinit();
        self.* = undefined;
    }

    pub fn listModels(
        self: *ListingOwned,
        allocator: std.mem.Allocator,
        io: std.Io,
        tick: ?Provider.Tick,
    ) ai.ModelListing.Error!ai.ModelListing.Outcome {
        return listResolvedModels(allocator, io, self.config, self.json_transport, tick);
    }

    pub fn providerId(self: *const ListingOwned) []const u8 {
        return self.config.resolved.metadata.provider_id;
    }

    pub fn displayName(self: *const ListingOwned) []const u8 {
        return self.config.resolved.metadata.display_name;
    }

    pub fn defaultModel(self: *const ListingOwned) ?[]const u8 {
        return self.config.listing_default_model;
    }

    pub fn modelDiscovered(self: *const ListingOwned) bool {
        return self.config.model_discovered;
    }

    pub fn providerEfforts(self: *const ListingOwned) ai.Effort.Set {
        return self.config.resolved.metadata.provider_efforts;
    }

    pub fn efforts(self: *const ListingOwned) ai.Effort.Set {
        return self.config.resolved.metadata.efforts;
    }

    pub fn catalogId(self: *const ListingOwned) ?[]const u8 {
        return self.config.resolved.metadata.catalog_id;
    }

    pub fn keepModelOrder(self: *const ListingOwned) bool {
        return self.config.keep_model_order;
    }
};

pub const Owned = struct {
    allocator: std.mem.Allocator,
    config: *ProviderConfig.Owned,
    factory: *Factory.Owner,
    /// Optional borrowed JSON transport. Its implementation and context must
    /// outlive this value, every model source, and each synchronous listing call.
    json_transport: ?ai.JsonTransport.Transport,
    model: []const u8,
    effort: ?[]const u8,
    metadata: *const Registry.StableMetadata,
    keep_model_order: bool,
    provider_autoselected: bool,
    model_discovered: bool,

    /// Returns a borrowed erased handle tied to this composition's factory.
    pub fn provider(self: *Owned) Provider.Provider {
        return self.factory.provider();
    }

    /// Returns a borrowed model-list source tied to this handle's current
    /// address. Move the Owned value before taking this source, and stop using
    /// the source before `deinit`.
    pub fn modelSource(self: *Owned) ai.ModelListing.Source {
        return ai.ModelListing.Source.from(self);
    }

    /// Lists models through the resolved adapter. The JSON transport, adapter
    /// configuration, and returned source inputs are borrowed only for this
    /// synchronous call. Listing is serialized with streaming and plan changes.
    pub fn listModels(
        self: *Owned,
        allocator: std.mem.Allocator,
        io: std.Io,
        tick: ?Provider.Tick,
    ) ai.ModelListing.Error!ai.ModelListing.Outcome {
        self.factory.lockPlan(io);
        defer self.factory.unlockPlan(io);

        return listResolvedModels(allocator, io, self.config, self.json_transport, tick);
    }

    pub fn setInputTokens(self: *Owned, io: std.Io, input_tokens: u64) void {
        self.factory.setInputTokens(io, input_tokens);
    }

    pub fn headerWarnings(self: *const Owned) []const ProviderHeaders.Warning {
        return self.config.header_warnings;
    }

    pub fn catalogWirePending(self: *Owned, io: std.Io) bool {
        self.factory.lockPlan(io);
        defer self.factory.unlockPlan(io);
        return self.config.catalogWirePending();
    }

    /// Transactionally rebuilds the provider plan from an authoritative catalog
    /// result while preserving existing provider handles.
    pub fn applyAuthoritativeCatalog(
        self: *Owned,
        io: std.Io,
        contribution: ai.ModelCatalog.Contribution,
    ) InitError!void {
        self.factory.lockPlan(io);
        defer self.factory.unlockPlan(io);
        try self.config.applyAuthoritativeCatalog(contribution);
        self.effort = self.config.effort;
    }

    /// Destroys the factory before wiping and destroying resolved configuration.
    pub fn deinit(self: *Owned) void { // ziglint-ignore: Z030
        const allocator = self.allocator;
        const factory = self.factory;
        const config = self.config;
        factory.* = undefined;
        allocator.destroy(factory);
        config.deinit();
        self.* = undefined;
    }
};

/// Resolves only the supplied configuration snapshots and installs the supplied
/// streaming transport. This function performs no ambient configuration lookup
/// and no network operation. On failure it releases every completed allocation
/// and returns the original resolution or allocation error unchanged.
pub fn initListing(
    inputs_value: ProviderConfig.Inputs,
    json_transport: ?ai.JsonTransport.Transport,
) InitError!ListingOwned {
    var inputs = inputs_value;
    inputs.listing_only = true;
    const provider_config = try ProviderConfig.resolve(inputs);
    return .{ .config = provider_config, .json_transport = json_transport };
}

pub fn init(
    inputs: ProviderConfig.Inputs,
    transport: Transport.Transport,
    initial_input_tokens: u64,
) InitError!Owned {
    return initWithJson(inputs, transport, null, initial_input_tokens);
}

/// Resolves configuration and installs borrowed streaming and optional JSON
/// transports without performing a network operation. The transport
/// implementations and contexts must outlive the returned owner and calls.
pub fn initWithJson(
    inputs_value: ProviderConfig.Inputs,
    transport: Transport.Transport,
    json_transport: ?ai.JsonTransport.Transport,
    initial_input_tokens: u64,
) InitError!Owned {
    var inputs = inputs_value;
    inputs.listing_only = false;
    const config = try ProviderConfig.resolve(inputs);
    errdefer config.deinit();

    const factory = try inputs.allocator.create(Factory.Owner);
    factory.* = Factory.Owner.init(&config.resolved, transport, initial_input_tokens);

    return .{
        .allocator = inputs.allocator,
        .config = config,
        .factory = factory,
        .json_transport = json_transport,
        .model = config.model,
        .effort = config.effort,
        .metadata = &config.resolved.metadata,
        .keep_model_order = config.keep_model_order,
        .provider_autoselected = config.provider_autoselected,
        .model_discovered = config.model_discovered,
    };
}

fn listResolvedModels(
    allocator: std.mem.Allocator,
    io: std.Io,
    provider_config: *ProviderConfig.Owned,
    json_transport_value: ?ai.JsonTransport.Transport,
    tick: ?Provider.Tick,
) ai.ModelListing.Error!ai.ModelListing.Outcome {
    const json_transport = json_transport_value orelse return .unsupported;
    const stable_provider_id = provider_config.resolved.metadata.provider_id;
    switch (provider_config.resolved.adapter) {
        .codex => |config| {
            var client = ai.CodexOperations.Client.init(json_transport, .{
                .source = config.source,
                .user_agent = config.user_agent,
                .extra_headers = config.extra_headers,
                .maximum_access_token_bytes = config.maximum_access_token_bytes,
                .maximum_account_id_bytes = config.maximum_account_id_bytes,
            });
            return client.listModels(allocator, io, tick);
        },
        .openai_chat => |config| {
            var client = ai.OpenAiModels.Client.init(json_transport, .{
                .provider_id = stable_provider_id,
                .endpoint = config.endpoint,
                .api_key = config.api_key,
                .extra_headers = config.extra_headers,
                .privileged_header_policy = config.privileged_header_policy,
                .dialect = openAiDialect(stable_provider_id),
            });
            return client.listModels(allocator, io, tick);
        },
        .openai_responses => |config| {
            var client = ai.OpenAiModels.Client.init(json_transport, .{
                .provider_id = stable_provider_id,
                .endpoint = config.endpoint,
                .api_key = config.api_key,
                .extra_headers = config.extra_headers,
                .privileged_header_policy = config.privileged_header_policy,
                .dialect = openAiDialect(stable_provider_id),
            });
            return client.listModels(allocator, io, tick);
        },
        .anthropic_messages => |config| {
            var client = ai.AnthropicModels.Client.init(json_transport, .{
                .provider_id = stable_provider_id,
                .endpoint = config.endpoint,
                .api_key = config.api_key,
                .version = config.version,
                .extra_headers = config.extra_headers,
                .privileged_header_policy = config.privileged_header_policy,
            });
            return client.listModels(allocator, io, tick);
        },
        .mock => return .unsupported,
    }
}

fn openAiDialect(provider_id: []const u8) ai.OpenAiModels.Dialect {
    if (std.mem.eql(u8, provider_id, "llamacpp")) return .llamacpp;
    if (std.mem.eql(u8, provider_id, "openrouter")) return .openrouter;
    return .generic;
}

const config_module = @import("config/root.zig");

const TestEnvironment = struct {
    pub fn get(_: *const TestEnvironment, _: []const u8) ?[]const u8 {
        return null;
    }
};

fn testStore(document: *const config_module.Document, environment: *const TestEnvironment) config_module.Store {
    return .init(.{
        .file = document,
        .registry = config_module.Settings.storeRegistry(),
        .environment = .from(environment),
    });
}

const TestCodexSource = struct {
    pub fn acquire(
        _: *TestCodexSource,
        allocator: std.mem.Allocator,
        _: std.Io,
        _: ?Provider.Tick,
        _: ai.CodexAcquirePurpose,
    ) ai.CodexCredentialSource.CallbackError!ai.CodexAcquireDecision {
        return .{ .ready = try ai.CodexOwnedCredential.init(allocator, .{
            .access_token = "codex-token",
            .account_id = "account",
        }) };
    }

    pub fn recoverUnauthorized(
        _: *TestCodexSource,
        _: std.mem.Allocator,
        _: std.Io,
        _: ?Provider.Tick,
        _: ai.CodexCredential,
    ) ai.CodexCredentialSource.CallbackError!ai.CodexUnauthorizedDecision {
        return .use_response;
    }

    pub fn noteUnauthorized(_: *TestCodexSource, _: ai.CodexCredential) void {}
};

const FakeTransport = struct {
    calls: usize = 0,
    chat_calls: usize = 0,
    responses_calls: usize = 0,
    anthropic_calls: usize = 0,
    rewire_auth_valid: bool = true,
    rewire_body_valid: bool = true,
    saw_cache_a: bool = false,
    saw_cache_b: bool = false,

    pub fn ssePost(
        _: std.mem.Allocator,
        _: std.Io,
        self: *FakeTransport,
        request: Transport.Request,
        sink: Transport.EventSink,
    ) Transport.StreamError!Transport.Result {
        self.calls += 1;
        self.saw_cache_a = self.saw_cache_a or
            std.mem.find(u8, request.json_body, "12345678-1234-4234-8234-123456789abc") != null;
        self.saw_cache_b = self.saw_cache_b or
            std.mem.find(u8, request.json_body, "abcdefab-cdef-4abc-8def-abcdefabcdef") != null;
        var bearer_secret = false;
        var anthropic_secret = false;
        for (request.headers) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "authorization")) {
                bearer_secret = std.mem.eql(u8, header.value, "Bearer runtime-secret");
            }
            if (std.ascii.eqlIgnoreCase(header.name, "x-api-key")) {
                anthropic_secret = std.mem.eql(u8, header.value, "runtime-secret");
            }
        }
        if (std.mem.endsWith(u8, request.url, "/chat/completions")) {
            self.chat_calls += 1;
            self.rewire_auth_valid = self.rewire_auth_valid and bearer_secret;
            self.rewire_body_valid = self.rewire_body_valid and
                std.mem.eql(u8, request.url, "https://runtime.test/v1/chat/completions") and
                std.mem.find(u8, request.json_body, "\"messages\":[") != null;
            try sink.emit(.{ .data = "{\"id\":\"r\",\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}" });
            try sink.emit(.{ .data = "{\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":1},\"choices\":[]}" });
            try sink.emit(.{ .data = "[DONE]" });
        } else if (std.mem.endsWith(u8, request.url, "/messages")) {
            self.anthropic_calls += 1;
            self.rewire_auth_valid = self.rewire_auth_valid and anthropic_secret;
            self.rewire_body_valid = self.rewire_body_valid and
                std.mem.eql(u8, request.url, "https://runtime.test/v1/messages") and
                std.mem.find(u8, request.json_body, "\"messages\":[") != null;
            try sink.emit(.{ .data = "{\"type\":\"message_start\",\"message\":{" ++
                "\"id\":\"r\",\"model\":\"model\",\"usage\":{\"input_tokens\":2}}}" });
            try sink.emit(.{ .data = "{\"type\":\"message_delta\",\"delta\":{" ++
                "\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}" });
            try sink.emit(.{ .data = "{\"type\":\"message_stop\"}" });
        } else {
            self.responses_calls += 1;
            self.rewire_auth_valid = self.rewire_auth_valid and bearer_secret;
            self.rewire_body_valid = self.rewire_body_valid and
                std.mem.find(u8, request.json_body, "\"input\":[") != null;
            try sink.emit(.{ .data = "{\"type\":\"response.completed\",\"response\":{" ++
                "\"id\":\"r\",\"model\":\"model\",\"usage\":{" ++
                "\"input_tokens\":2,\"output_tokens\":1}}}" });
        }
        return .{ .status = 200, .outcome = .completed };
    }
};

const FakeListingTransport = struct {
    const Route = enum { openai_chat, openai_responses, anthropic, codex };

    route: Route = .openai_chat,
    transport_error: ?ai.JsonTransport.Error = null,
    calls: usize = 0,
    valid: bool = true,

    pub fn request(
        allocator: std.mem.Allocator,
        _: std.Io,
        self: *FakeListingTransport,
        value: ai.JsonTransport.Request,
    ) ai.JsonTransport.Error!ai.JsonTransport.Response {
        self.calls += 1;
        if (self.transport_error) |err| return err;
        self.valid = self.valid and value.method == .get;
        const body = switch (self.route) {
            .openai_chat => body: {
                self.valid = self.valid and std.mem.eql(u8, value.url, "https://listing.test/v1/models");
                self.valid = self.valid and hasHeader(value.headers, "authorization", "Bearer runtime-secret");
                break :body "{\"data\":[{\"id\":\"chat-model\"}]}";
            },
            .openai_responses => body: {
                self.valid = self.valid and std.mem.eql(u8, value.url, "https://listing.test/v1/models");
                self.valid = self.valid and hasHeader(value.headers, "authorization", "Bearer runtime-secret");
                break :body "{\"data\":[{\"id\":\"responses-model\"}]}";
            },
            .anthropic => body: {
                self.valid = self.valid and
                    std.mem.eql(u8, value.url, "https://listing.test/v1/models?limit=1000");
                self.valid = self.valid and hasHeader(value.headers, "x-api-key", "runtime-secret");
                self.valid = self.valid and hasHeader(
                    value.headers,
                    "anthropic-version",
                    ai.AnthropicModels.default_version,
                );
                break :body "{\"data\":[{\"id\":\"anthropic-model\"}]}";
            },
            .codex => body: {
                self.valid = self.valid and std.mem.eql(u8, value.url, ai.CodexOperations.models_url);
                self.valid = self.valid and hasHeader(value.headers, "authorization", "Bearer codex-token");
                self.valid = self.valid and hasHeader(value.headers, "chatgpt-account-id", "account");
                break :body "{\"models\":[{\"slug\":\"codex-model\"}]}";
            },
        };
        return .{ .status = 200, .body = try allocator.dupe(u8, body) };
    }

    fn hasHeader(headers: []const ai.JsonTransport.Header, name: []const u8, value: []const u8) bool {
        for (headers) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, name) and std.mem.eql(u8, header.value, value)) return true;
        }
        return false;
    }
};

const Collector = struct {
    done: usize = 0,

    pub fn emit(self: *Collector, event: ai.StreamEvent.StreamEvent) Provider.DeliveryError!void {
        if (event == .done) self.done += 1;
    }
};

fn streamRuntime(runtime: *Owned, collector: *Collector) !void {
    try runtime.provider().stream(
        std.testing.allocator,
        std.testing.io,
        .{
            .model = runtime.model,
            .context = .{ .system_prompt = "system", .items = &.{}, .tools = &.{} },
        },
        Provider.EventSink.from(collector),
    );
}

test "model listing routes resolved adapters through public source after moving the owner" {
    const Definition = config_module.ProviderDefinitions.Definition;
    const Api = config_module.ProviderDefinitions.Api;
    const cases = [_]struct {
        id: []const u8,
        api: Api,
        route: FakeListingTransport.Route,
        expected_model: []const u8,
    }{
        .{ .id = "listing-chat", .api = .openai_completions, .route = .openai_chat, .expected_model = "chat-model" },
        .{
            .id = "listing-responses",
            .api = .openai_responses,
            .route = .openai_responses,
            .expected_model = "responses-model",
        },
        .{
            .id = "listing-anthropic",
            .api = .anthropic_messages,
            .route = .anthropic,
            .expected_model = "anthropic-model",
        },
    };
    const environment: TestEnvironment = .{};
    var stream_transport: FakeTransport = .{};

    for (cases) |case| {
        var document = try config_module.Document.parse(std.testing.allocator, "{\"model\":\"model\"}", .{});
        defer document.deinit();
        const definition: Definition = .{
            .id = @constCast(case.id),
            .api = case.api,
            .base_url = @constCast("https://listing.test/v1"),
            .api_key = @constCast("runtime-secret"),
        };
        var json_transport: FakeListingTransport = .{ .route = case.route };
        const original = try initWithJson(.{
            .allocator = std.testing.allocator,
            .store = testStore(&document, &environment),
            .api_key_environment = .from(&environment),
            .provider_override = case.id,
            .provider_definitions = &.{definition},
        }, Transport.Transport.from(&stream_transport), ai.JsonTransport.Transport.from(&json_transport), 0);
        const factory_address = original.factory;
        var moved = original;
        defer moved.deinit();
        try std.testing.expectEqual(@intFromPtr(factory_address), @intFromPtr(moved.factory));

        const source = moved.modelSource();
        var outcome = try source.listModels(std.testing.allocator, std.testing.io, null);
        defer outcome.deinit();
        try std.testing.expect(outcome == .models);
        try std.testing.expectEqualStrings(case.expected_model, outcome.models.models[0].id);
        try std.testing.expect(json_transport.valid);
        try std.testing.expectEqual(@as(usize, 1), json_transport.calls);
    }

    var codex_document = try config_module.Document.parse(std.testing.allocator, "{}", .{});
    defer codex_document.deinit();
    var credential_source: TestCodexSource = .{};
    var codex_json: FakeListingTransport = .{ .route = .codex };
    var codex = try initWithJson(.{
        .allocator = std.testing.allocator,
        .store = testStore(&codex_document, &environment),
        .api_key_environment = .from(&environment),
        .codex_available = true,
        .codex_source = .from(&credential_source),
        .default_model = "model",
        .session_cache_key = "12345678-1234-4234-8234-123456789abc",
    }, Transport.Transport.from(&stream_transport), ai.JsonTransport.Transport.from(&codex_json), 0);
    defer codex.deinit();
    var codex_outcome = try codex.listModels(std.testing.allocator, std.testing.io, null);
    defer codex_outcome.deinit();
    try std.testing.expectEqualStrings("codex-model", codex_outcome.models.models[0].id);
    try std.testing.expect(codex_json.valid);
}

test "model listing is unsupported without JSON and for the mock adapter" {
    const environment: TestEnvironment = .{};
    var stream_transport: FakeTransport = .{};
    var document = try config_module.Document.parse(std.testing.allocator, "{\"model\":\"model\"}", .{});
    defer document.deinit();
    const definition: config_module.ProviderDefinitions.Definition = .{
        .id = @constCast("listing-unsupported"),
        .api = .openai_responses,
        .base_url = @constCast("https://listing.test/v1"),
    };
    var without_json = try init(.{
        .allocator = std.testing.allocator,
        .store = testStore(&document, &environment),
        .api_key_environment = .from(&environment),
        .provider_override = "listing-unsupported",
        .provider_definitions = &.{definition},
    }, Transport.Transport.from(&stream_transport), 0);
    defer without_json.deinit();
    var unsupported = try without_json.listModels(std.testing.allocator, std.testing.io, null);
    defer unsupported.deinit();
    try std.testing.expect(unsupported == .unsupported);

    var mock_document = try config_module.Document.parse(
        std.testing.allocator,
        "{\"provider\":\"mock\"}",
        .{},
    );
    defer mock_document.deinit();
    var json_transport: FakeListingTransport = .{};
    var mock = try initWithJson(.{
        .allocator = std.testing.allocator,
        .store = testStore(&mock_document, &environment),
        .api_key_environment = .from(&environment),
    }, Transport.Transport.from(&stream_transport), ai.JsonTransport.Transport.from(&json_transport), 0);
    defer mock.deinit();
    var mock_outcome = try mock.modelSource().listModels(std.testing.allocator, std.testing.io, null);
    defer mock_outcome.deinit();
    try std.testing.expect(mock_outcome == .unsupported);
    try std.testing.expectEqual(@as(usize, 0), json_transport.calls);
}

test "model listing preserves typed transport errors and stable dialect selection" {
    try std.testing.expectEqual(ai.OpenAiModels.Dialect.llamacpp, openAiDialect("llamacpp"));
    try std.testing.expectEqual(ai.OpenAiModels.Dialect.openrouter, openAiDialect("openrouter"));
    try std.testing.expectEqual(ai.OpenAiModels.Dialect.generic, openAiDialect("compatible"));

    const environment: TestEnvironment = .{};
    var document = try config_module.Document.parse(std.testing.allocator, "{\"model\":\"model\"}", .{});
    defer document.deinit();
    const definition: config_module.ProviderDefinitions.Definition = .{
        .id = @constCast("listing-errors"),
        .api = .openai_responses,
        .base_url = @constCast("https://listing.test/v1"),
    };
    var stream_transport: FakeTransport = .{};
    var json_transport: FakeListingTransport = .{ .route = .openai_responses };
    var runtime = try initWithJson(.{
        .allocator = std.testing.allocator,
        .store = testStore(&document, &environment),
        .api_key_environment = .from(&environment),
        .provider_override = "listing-errors",
        .provider_definitions = &.{definition},
    }, Transport.Transport.from(&stream_transport), ai.JsonTransport.Transport.from(&json_transport), 0);
    defer runtime.deinit();

    inline for (.{ error.OutOfMemory, error.Cancelled, error.InvalidRequest }) |expected| {
        json_transport.transport_error = expected;
        try std.testing.expectError(
            expected,
            runtime.listModels(std.testing.allocator, std.testing.io, null),
        );
    }
}

test "composition streams every wire family and remains stable when its handle moves" {
    const Definition = config_module.ProviderDefinitions.Definition;
    const Api = config_module.ProviderDefinitions.Api;
    const cases = [_]struct { id: []const u8, api: Api }{
        .{ .id = "dynamic-chat", .api = .openai_completions },
        .{ .id = "dynamic-responses", .api = .openai_responses },
        .{ .id = "dynamic-anthropic", .api = .anthropic_messages },
    };
    const environment: TestEnvironment = .{};
    var fake: FakeTransport = .{};
    var collector: Collector = .{};

    for (cases) |case| {
        var document = try config_module.Document.parse(std.testing.allocator, "{\"model\":\"model\"}", .{});
        defer document.deinit();
        const definition: Definition = .{
            .id = @constCast(case.id),
            .api = case.api,
            .base_url = @constCast("https://runtime.test/v1"),
            .sort_models = false,
        };
        const original = try init(.{
            .allocator = std.testing.allocator,
            .store = testStore(&document, &environment),
            .api_key_environment = .from(&environment),
            .provider_override = case.id,
            .provider_definitions = &.{definition},
        }, Transport.Transport.from(&fake), 11);
        const factory_address = original.factory;
        var moved = original;
        try std.testing.expectEqual(@intFromPtr(factory_address), @intFromPtr(moved.provider().context));
        try std.testing.expectEqualStrings("model", moved.model);
        try std.testing.expectEqualStrings(case.id, moved.metadata.provider_id);
        try std.testing.expect(moved.keep_model_order);
        try std.testing.expect(!moved.provider_autoselected);
        moved.setInputTokens(std.testing.io, 12);
        try streamRuntime(&moved, &collector);
        moved.deinit();
    }

    var codex_document = try config_module.Document.parse(std.testing.allocator, "{}", .{});
    defer codex_document.deinit();
    var source: TestCodexSource = .{};
    var codex = try init(.{
        .allocator = std.testing.allocator,
        .store = testStore(&codex_document, &environment),
        .api_key_environment = .from(&environment),
        .codex_available = true,
        .codex_source = .from(&source),
        .default_model = "model",
        .default_effort = "high",
        .session_cache_key = "12345678-1234-4234-8234-123456789abc",
    }, Transport.Transport.from(&fake), 0);
    defer codex.deinit();
    try std.testing.expectEqualStrings("high", codex.effort.?);
    try std.testing.expect(codex.provider_autoselected);
    try streamRuntime(&codex, &collector);
    try std.testing.expectEqual(@as(usize, 4), fake.calls);
    try std.testing.expectEqual(@as(usize, 4), collector.done);
}

test "authoritative catalog rewires an existing provider handle" {
    const environment: TestEnvironment = .{};
    var document = try config_module.Document.parse(
        std.testing.allocator,
        "{\"model\":\"model\"}",
        .{},
    );
    defer document.deinit();
    const definition: config_module.ProviderDefinitions.Definition = .{
        .id = @constCast("dynamic-catalog"),
        .api = .catalog,
        .base_url = @constCast("https://runtime.test/v1"),
        .api_key = @constCast("runtime-secret"),
    };
    var fake: FakeTransport = .{};
    var runtime = try init(.{
        .allocator = std.testing.allocator,
        .store = testStore(&document, &environment),
        .api_key_environment = .from(&environment),
        .provider_override = "dynamic-catalog",
        .provider_definitions = &.{definition},
    }, Transport.Transport.from(&fake), 0);
    defer runtime.deinit();

    try std.testing.expect(runtime.catalogWirePending(std.testing.io));
    const provider = runtime.provider();
    var collector: Collector = .{};
    const request: Provider.Request = .{
        .model = runtime.model,
        .context = .{ .system_prompt = "system", .items = &.{}, .tools = &.{} },
    };
    try provider.stream(
        std.testing.allocator,
        std.testing.io,
        request,
        Provider.EventSink.from(&collector),
    );
    try runtime.applyAuthoritativeCatalog(std.testing.io, .{ .wire = .{ .wire = .anthropic_messages } });
    try std.testing.expect(!runtime.catalogWirePending(std.testing.io));
    try provider.stream(
        std.testing.allocator,
        std.testing.io,
        request,
        Provider.EventSink.from(&collector),
    );
    try runtime.applyAuthoritativeCatalog(std.testing.io, .{ .wire = .{ .wire = .openai_responses } });
    try provider.stream(
        std.testing.allocator,
        std.testing.io,
        request,
        Provider.EventSink.from(&collector),
    );
    try std.testing.expectEqual(@as(usize, 1), fake.chat_calls);
    try std.testing.expectEqual(@as(usize, 1), fake.anthropic_calls);
    try std.testing.expectEqual(@as(usize, 1), fake.responses_calls);
    try std.testing.expect(fake.rewire_auth_valid);
    try std.testing.expect(fake.rewire_body_valid);
    try std.testing.expectEqual(@as(usize, 3), collector.done);
}

test "runtime effort changes only after a successful authoritative apply" {
    const environment: TestEnvironment = .{};
    var document = try config_module.Document.parse(std.testing.allocator, "{}", .{});
    defer document.deinit();
    var source: TestCodexSource = .{};
    var fake: FakeTransport = .{};
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = std.math.maxInt(usize),
    });
    var runtime = try init(.{
        .allocator = failing.allocator(),
        .store = testStore(&document, &environment),
        .api_key_environment = .from(&environment),
        .codex_available = true,
        .codex_source = .from(&source),
        .default_model = "model",
        .default_effort = "high",
        .session_cache_key = "12345678-1234-4234-8234-123456789abc",
    }, Transport.Transport.from(&fake), 0);
    defer runtime.deinit();
    try std.testing.expectEqualStrings("high", runtime.effort.?);

    const low = try ai.Effort.Set.init(&.{"low"});
    try runtime.applyAuthoritativeCatalog(std.testing.io, .{ .metadata = .{ .efforts = low } });
    try std.testing.expectEqualStrings("low", runtime.effort.?);
    failing.fail_index = failing.alloc_index;
    const high = try ai.Effort.Set.init(&.{"high"});
    try std.testing.expectError(error.OutOfMemory, runtime.applyAuthoritativeCatalog(
        std.testing.io,
        .{ .metadata = .{ .efforts = high } },
    ));
    try std.testing.expectEqualStrings("low", runtime.effort.?);

    failing.fail_index = std.math.maxInt(usize);
    try runtime.applyAuthoritativeCatalog(std.testing.io, .{ .metadata = .{ .efforts = high } });
    try std.testing.expectEqualStrings("high", runtime.effort.?);
}

test "catalog apply waits for an in-flight old provider handle" {
    const BlockingTransport = struct {
        const Self = @This();
        entered: std.Io.Event = .unset,
        release: std.Io.Event = .unset,
        calls: usize = 0,
        old_endpoint_valid: bool = false,
        new_endpoint_valid: bool = false,

        pub fn ssePost(
            _: std.mem.Allocator,
            io: std.Io,
            self: *Self,
            request: Transport.Request,
            sink: Transport.EventSink,
        ) Transport.StreamError!Transport.Result {
            self.calls += 1;
            if (self.calls == 1) {
                self.entered.set(io);
                self.release.waitUncancelable(io);
                self.old_endpoint_valid = std.mem.eql(
                    u8,
                    request.url,
                    "https://blocked.test/v1/chat/completions",
                );
                try sink.emit(.{ .data = "{\"id\":\"r\",\"choices\":[{" ++
                    "\"delta\":{},\"finish_reason\":\"stop\"}]}" });
                try sink.emit(.{ .data = "[DONE]" });
            } else {
                self.new_endpoint_valid = std.mem.eql(
                    u8,
                    request.url,
                    "https://blocked.test/v1/messages",
                );
                try sink.emit(.{ .data = "{\"type\":\"message_start\",\"message\":{" ++
                    "\"id\":\"r\",\"model\":\"model\",\"usage\":{\"input_tokens\":2}}}" });
                try sink.emit(.{ .data = "{\"type\":\"message_delta\",\"delta\":{" ++
                    "\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}" });
                try sink.emit(.{ .data = "{\"type\":\"message_stop\"}" });
            }
            return .{ .status = 200, .outcome = .completed };
        }
    };
    const StreamThread = struct {
        const Self = @This();
        runtime: *Owned,
        collector: *Collector,
        result: ?anyerror = null,

        fn run(self: *Self) void {
            streamRuntime(self.runtime, self.collector) catch |err| {
                self.result = err;
            };
        }
    };
    const ApplyThread = struct {
        const Self = @This();
        runtime: *Owned,
        started: std.Io.Event = .unset,
        finished: std.Io.Event = .unset,
        result: ?anyerror = null,

        fn run(self: *Self) void {
            self.started.set(std.testing.io);
            self.runtime.applyAuthoritativeCatalog(std.testing.io, .{
                .wire = .{ .wire = .anthropic_messages },
            }) catch |err| {
                self.result = err;
            };
            self.finished.set(std.testing.io);
        }
    };
    const QueryThread = struct {
        const Self = @This();
        runtime: *Owned,
        started: std.Io.Event = .unset,
        finished: std.Io.Event = .unset,
        pending: bool = false,

        fn run(self: *Self) void {
            self.started.set(std.testing.io);
            self.pending = self.runtime.catalogWirePending(std.testing.io);
            self.finished.set(std.testing.io);
        }
    };

    const environment: TestEnvironment = .{};
    var document = try config_module.Document.parse(
        std.testing.allocator,
        "{\"model\":\"model\"}",
        .{},
    );
    defer document.deinit();
    const definition: config_module.ProviderDefinitions.Definition = .{
        .id = @constCast("blocked-catalog"),
        .api = .catalog,
        .base_url = @constCast("https://blocked.test/v1"),
    };
    var transport: BlockingTransport = .{};
    var runtime = try init(.{
        .allocator = std.testing.allocator,
        .store = testStore(&document, &environment),
        .api_key_environment = .from(&environment),
        .provider_override = "blocked-catalog",
        .provider_definitions = &.{definition},
    }, Transport.Transport.from(&transport), 0);
    defer runtime.deinit();
    const old_handle = runtime.provider();
    var collector: Collector = .{};

    var stream_context: StreamThread = .{ .runtime = &runtime, .collector = &collector };
    var stream_thread = try std.Thread.spawn(.{}, StreamThread.run, .{&stream_context});
    defer {
        transport.release.set(std.testing.io);
        stream_thread.join();
    }
    transport.entered.waitUncancelable(std.testing.io);
    try std.testing.expect(!runtime.factory.operation_mutex.tryLock());

    var query_context: QueryThread = .{ .runtime = &runtime };
    var query_thread = try std.Thread.spawn(.{}, QueryThread.run, .{&query_context});
    defer query_thread.join();
    query_context.started.waitUncancelable(std.testing.io);
    try std.testing.expect(!query_context.finished.isSet());

    var apply_context: ApplyThread = .{ .runtime = &runtime };
    var apply_thread = try std.Thread.spawn(.{}, ApplyThread.run, .{&apply_context});
    defer apply_thread.join();
    apply_context.started.waitUncancelable(std.testing.io);
    try std.testing.expect(!apply_context.finished.isSet());
    transport.release.set(std.testing.io);
    query_context.finished.waitUncancelable(std.testing.io);
    apply_context.finished.waitUncancelable(std.testing.io);

    if (stream_context.result) |err| return err;
    if (apply_context.result) |err| return err;
    try old_handle.stream(
        std.testing.allocator,
        std.testing.io,
        .{
            .model = runtime.model,
            .context = .{ .system_prompt = "system", .items = &.{}, .tools = &.{} },
        },
        Provider.EventSink.from(&collector),
    );
    try std.testing.expect(transport.old_endpoint_valid);
    try std.testing.expect(transport.new_endpoint_valid);
    try std.testing.expectEqual(@as(usize, 2), collector.done);
}

fn exerciseInitAllocationFailures(
    allocator: std.mem.Allocator,
    document: *const config_module.Document,
    environment: *const TestEnvironment,
    fake: *FakeTransport,
) !void {
    const definition: config_module.ProviderDefinitions.Definition = .{
        .id = @constCast("oom-dynamic"),
        .api = .openai_responses,
        .base_url = @constCast("https://runtime.test/v1"),
        .api_key = @constCast("runtime-secret"),
    };
    var runtime = try init(.{
        .allocator = allocator,
        .store = testStore(document, environment),
        .api_key_environment = .from(environment),
        .provider_override = "oom-dynamic",
        .provider_definitions = &.{definition},
        .session_cache_key = "12345678-1234-4234-8234-123456789abc",
    }, Transport.Transport.from(fake), 0);
    runtime.deinit();
}

test "initialization is transactional at every allocation index and preserves resolver errors" {
    const environment: TestEnvironment = .{};
    var fake: FakeTransport = .{};
    var document = try config_module.Document.parse(std.testing.allocator, "{\"model\":\"model\"}", .{});
    defer document.deinit();
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseInitAllocationFailures,
        .{ &document, &environment, &fake },
    );

    const invalid: config_module.ProviderDefinitions.Definition = .{
        .id = @constCast("invalid-dynamic"),
        .api_invalid = true,
        .base_url = @constCast("https://runtime.test/v1"),
    };
    try std.testing.expectError(error.InvalidSetting, init(.{
        .allocator = std.testing.allocator,
        .store = testStore(&document, &environment),
        .api_key_environment = .from(&environment),
        .provider_override = "invalid-dynamic",
        .provider_definitions = &.{invalid},
    }, Transport.Transport.from(&fake), 0));
}

fn exerciseListingWithoutModel(allocator: std.mem.Allocator) !void {
    const environment: TestEnvironment = .{};
    const definition: config_module.ProviderDefinitions.Definition = .{
        .id = @constCast("listing-dynamic"),
        .api = .openai_completions,
        .base_url = @constCast("https://listing.test/v1"),
        .api_key = @constCast("runtime-secret"),
    };
    var listing_transport: FakeListingTransport = .{ .route = .openai_chat };
    const reported: ai.ModelMeta.Metadata = .{ .efforts = try ai.Effort.Set.init(&.{"high"}) };
    var runtime = try initListing(.{
        .allocator = allocator,
        .store = .init(.{
            .registry = config_module.Settings.storeRegistry(),
            .environment = .from(&environment),
        }),
        .api_key_environment = .from(&environment),
        .provider_override = "listing-dynamic",
        .provider_definitions = &.{definition},
        .hints = .{ .reported = &reported },
    }, ai.JsonTransport.Transport.from(&listing_transport));
    defer runtime.deinit();
    try std.testing.expect(runtime.defaultModel() == null);
    try std.testing.expect(runtime.providerEfforts().count > runtime.efforts().count);
    try std.testing.expectEqualStrings("high", runtime.efforts().valueAt(0));
    var outcome = try runtime.listModels(allocator, std.testing.io, null);
    defer outcome.deinit();
    try std.testing.expectEqualStrings("chat-model", outcome.models.models[0].id);
    try std.testing.expect(listing_transport.valid);
}

test "listing-only runtime enumerates without a configured model" {
    try exerciseListingWithoutModel(std.testing.allocator);
}

test "listing-only runtime releases every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseListingWithoutModel, .{});
}

test "streaming initialization rejects a missing model even when inputs request listing mode" {
    const environment: TestEnvironment = .{};
    const definition: config_module.ProviderDefinitions.Definition = .{
        .id = @constCast("streaming-missing-model"),
        .api = .openai_completions,
        .base_url = @constCast("https://streaming.test/v1"),
        .api_key = @constCast("runtime-secret"),
    };
    var fake: FakeTransport = .{};
    try std.testing.expectError(error.MissingModel, initWithJson(.{
        .allocator = std.testing.allocator,
        .store = .init(.{
            .registry = config_module.Settings.storeRegistry(),
            .environment = .from(&environment),
        }),
        .api_key_environment = .from(&environment),
        .provider_override = "streaming-missing-model",
        .provider_definitions = &.{definition},
        .listing_only = true,
    }, ai.Transport.Transport.from(&fake), null, 0));
}

test "independent owners retain independent cache keys" {
    const environment: TestEnvironment = .{};
    var document = try config_module.Document.parse(std.testing.allocator, "{\"model\":\"model\"}", .{});
    defer document.deinit();
    const definition: config_module.ProviderDefinitions.Definition = .{
        .id = @constCast("cache-dynamic"),
        .api = .openai_responses,
        .base_url = @constCast("https://runtime.test/v1"),
        .send_cache_key = .on,
    };
    var fake: FakeTransport = .{};
    const common: ProviderConfig.Inputs = .{
        .allocator = std.testing.allocator,
        .store = testStore(&document, &environment),
        .api_key_environment = .from(&environment),
        .provider_override = "cache-dynamic",
        .provider_definitions = &.{definition},
    };
    var inputs_a = common;
    inputs_a.session_cache_key = "12345678-1234-4234-8234-123456789abc";
    var inputs_b = common;
    inputs_b.session_cache_key = "abcdefab-cdef-4abc-8def-abcdefabcdef";
    var runtime_a = try init(inputs_a, Transport.Transport.from(&fake), 1);
    defer runtime_a.deinit();
    var runtime_b = try init(inputs_b, Transport.Transport.from(&fake), 2);
    defer runtime_b.deinit();
    var collector: Collector = .{};
    try streamRuntime(&runtime_a, &collector);
    try streamRuntime(&runtime_b, &collector);
    try std.testing.expect(fake.saw_cache_a);
    try std.testing.expect(fake.saw_cache_b);
    try std.testing.expect(runtime_a.factory != runtime_b.factory);
    try std.testing.expect(runtime_a.config != runtime_b.config);
}
