const std = @import("std");
const ai = @import("ai/root.zig");
const ProviderConfig = @import("ProviderConfig.zig");

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
/// The transport implementation and its context are borrowed and must outlive
/// this value and every provider call. `Inputs.codex_source`, when present, is
/// also borrowed under `ProviderConfig.Inputs`' lifetime rule. Provider calls
/// and `setInputTokens` must not overlap. Call `deinit` exactly once, after all
/// copied provider handles have stopped being used.
pub const Owned = struct {
    allocator: std.mem.Allocator,
    config: *ProviderConfig.Owned,
    factory: *Factory.Owner,
    model: []const u8,
    effort: ?[]const u8,
    metadata: *const Registry.StableMetadata,
    keep_model_order: bool,
    provider_autoselected: bool,

    /// Returns a borrowed erased handle tied to this composition's factory.
    pub fn provider(self: *Owned) Provider.Provider {
        return self.factory.provider();
    }

    pub fn setInputTokens(self: *Owned, input_tokens: u64) void {
        self.factory.setInputTokens(input_tokens);
    }

    /// Installs fresh catalog facts without changing provider or wire selection.
    pub fn mergeRefreshedCatalog(
        self: *Owned,
        contribution: ai.ModelCatalog.Contribution,
    ) void {
        self.config.mergeRefreshedCatalog(contribution);
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
pub fn init(
    inputs: ProviderConfig.Inputs,
    transport: Transport.Transport,
    initial_input_tokens: u64,
) InitError!Owned {
    const config = try ProviderConfig.resolve(inputs);
    errdefer config.deinit();

    const factory = try inputs.allocator.create(Factory.Owner);
    factory.* = Factory.Owner.init(&config.resolved, transport, initial_input_tokens);

    return .{
        .allocator = inputs.allocator,
        .config = config,
        .factory = factory,
        .model = config.model,
        .effort = config.effort,
        .metadata = &config.resolved.metadata,
        .keep_model_order = config.keep_model_order,
        .provider_autoselected = config.provider_autoselected,
    };
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
        if (std.mem.endsWith(u8, request.url, "/chat/completions")) {
            try sink.emit(.{ .data = "{\"id\":\"r\",\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}" });
            try sink.emit(.{ .data = "{\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":1},\"choices\":[]}" });
            try sink.emit(.{ .data = "[DONE]" });
        } else if (std.mem.endsWith(u8, request.url, "/messages")) {
            try sink.emit(.{ .data = "{\"type\":\"message_start\",\"message\":{" ++
                "\"id\":\"r\",\"model\":\"model\",\"usage\":{\"input_tokens\":2}}}" });
            try sink.emit(.{ .data = "{\"type\":\"message_delta\",\"delta\":{" ++
                "\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}" });
            try sink.emit(.{ .data = "{\"type\":\"message_stop\"}" });
        } else {
            try sink.emit(.{ .data = "{\"type\":\"response.completed\",\"response\":{" ++
                "\"id\":\"r\",\"model\":\"model\",\"usage\":{" ++
                "\"input_tokens\":2,\"output_tokens\":1}}}" });
        }
        return .{ .status = 200, .outcome = .completed };
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
        moved.setInputTokens(12);
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
