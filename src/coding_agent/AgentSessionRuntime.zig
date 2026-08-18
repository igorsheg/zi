const std = @import("std");
const ai_catalog = @import("../ai/model_catalog.zig");
const ai_model = @import("../ai/model.zig");
const ai_provider = @import("../ai/provider.zig");
const ai_settings = @import("../ai/settings.zig");
const ai_transport = @import("../ai/transport.zig");
const compatible = @import("../ai/providers/openai_compatible.zig");
const codex = @import("../ai/providers/openai_codex.zig");
const responses = @import("../ai/providers/openai_responses.zig");
const agent_limits = @import("../agent/limits.zig");
const AgentSession = @import("AgentSession.zig");
const ModelConfig = @import("ModelConfig.zig");
const model_resolution = @import("ModelResolution.zig");

const AgentSessionRuntime = @This();
const max_credentials = 32;

pub const Credential = model_resolution.Credential;
pub const Config = model_resolution.RuntimeConfig;

pub const Options = struct {
    limits: agent_limits.RunLimits = .{},
    events: ?AgentSession.EventSink = null,
};

pub const CreateError = error{
    OutOfMemory,
    InvalidModelConfiguration,
    DuplicateToolName,
    InvalidToolDefinition,
    UnknownTool,
    InvalidToolArguments,
};

const ProviderStorage = union(enum) {
    openai_completions: compatible.OpenAiCompatible,
    openai_responses: responses.OpenAiResponses,
    openai_codex_responses: codex.OpenAiCodex,

    fn view(self: *ProviderStorage) ai_provider.Provider {
        return switch (self.*) {
            .openai_completions => |*provider| provider.provider(),
            .openai_responses => |*provider| provider.provider(),
            .openai_codex_responses => |*provider| provider.provider(),
        };
    }
};

const ModelRuntime = struct {
    arena: std.heap.ArenaAllocator,
    registry: ai_provider.Registry,
    catalog: ai_catalog.Catalog,
    providers: []ProviderStorage,
    sensitive: [][]u8,
    sensitive_count: usize,
    model_value: ai_model.Model,

    const InitError = error{ OutOfMemory, InvalidModelConfiguration };

    fn init(
        self: *ModelRuntime,
        allocator: std.mem.Allocator,
        transport: ai_transport.Transport,
        config: Config,
    ) InitError!void {
        try validateConfig(config);
        self.arena = std.heap.ArenaAllocator.init(allocator);
        errdefer self.arena.deinit();
        self.registry = ai_provider.Registry.init(allocator);
        errdefer self.registry.deinit();

        const owned = self.arena.allocator();
        self.catalog = try copyCatalog(owned, config.model_config.catalog);
        self.providers = try owned.alloc(ProviderStorage, config.model_config.providers.len);
        self.sensitive = try owned.alloc([]u8, config.credentials.len * 2);
        self.sensitive_count = 0;
        errdefer self.wipeSensitive();
        var provider_count: usize = 0;
        for (config.model_config.providers) |provider| {
            switch (provider) {
                .openai_completions => |definition| {
                    const api_key = switch (definition.authentication) {
                        .none => null,
                        .api_key => key: {
                            const value = findApiKey(config.credentials, definition.id) orelse continue;
                            break :key try self.copySensitive(value);
                        },
                    };
                    self.providers[provider_count] = .{
                        .openai_completions = compatible.OpenAiCompatible.init(transport, .{
                            .provider_id = try owned.dupe(u8, definition.id),
                            .catalog = self.catalog,
                            .base_url = try owned.dupe(u8, definition.base_url),
                            .api_key = api_key,
                        }),
                    };
                },
                .openai_responses => |definition| {
                    const api_key = switch (definition.authentication) {
                        .none => null,
                        .api_key => key: {
                            const value = findApiKey(config.credentials, definition.id) orelse continue;
                            break :key try self.copySensitive(value);
                        },
                    };
                    self.providers[provider_count] = .{
                        .openai_responses = responses.OpenAiResponses.init(transport, .{
                            .provider_id = try owned.dupe(u8, definition.id),
                            .catalog = self.catalog,
                            .base_url = try owned.dupe(u8, definition.base_url),
                            .api_key = api_key,
                        }),
                    };
                },
                .openai_codex_responses => |definition| {
                    const credential = findCodexCredential(config.credentials) orelse continue;
                    self.providers[provider_count] = .{
                        .openai_codex_responses = codex.OpenAiCodex.init(transport, .{
                            .catalog = self.catalog,
                            .base_url = try owned.dupe(u8, definition.base_url),
                            .access_token = try self.copySensitive(credential.access_token),
                            .account_id = if (credential.account_id) |account_id|
                                try self.copySensitive(account_id)
                            else
                                null,
                        }),
                    };
                },
            }
            self.registry.register(self.providers[provider_count].view()) catch |failure| switch (failure) {
                error.OutOfMemory => return error.OutOfMemory,
                error.DuplicateProvider, error.InvalidProvider => return error.InvalidModelConfiguration,
            };
            provider_count += 1;
        }
        self.providers = self.providers[0..provider_count];
        self.model_value = self.resolve(config.selection) orelse return error.InvalidModelConfiguration;
    }

    fn resolve(self: *const ModelRuntime, selection: ai_model.ModelIdentity) ?ai_model.Model {
        const resolved = self.catalog.resolve(selection) orelse return null;
        return self.registry.resolve(resolved.entry.identity);
    }

    fn model(self: *const ModelRuntime) ai_model.Model {
        return self.model_value;
    }

    fn deinit(self: *ModelRuntime) void {
        self.wipeSensitive();
        self.registry.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    fn copySensitive(self: *ModelRuntime, value: []const u8) error{OutOfMemory}![]u8 {
        const copied = try self.arena.allocator().dupe(u8, value);
        self.sensitive[self.sensitive_count] = copied;
        self.sensitive_count += 1;
        return copied;
    }

    fn wipeSensitive(self: *ModelRuntime) void {
        for (self.sensitive[0..self.sensitive_count]) |value| std.crypto.secureZero(u8, value);
    }
};

const TransportOwner = union(enum) {
    http: ai_transport.HttpTransport,
    borrowed: ai_transport.Transport,

    fn view(self: *TransportOwner) ai_transport.Transport {
        return switch (self.*) {
            .http => |*http| http.transport(),
            .borrowed => |transport| transport,
        };
    }
};

allocator: std.mem.Allocator,
transport: TransportOwner,
model_runtime: ModelRuntime,
session_value: AgentSession,

pub fn create(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    config: Config,
    options: Options,
) CreateError!*AgentSessionRuntime {
    const runtime = try allocator.create(AgentSessionRuntime);
    errdefer allocator.destroy(runtime);
    runtime.allocator = allocator;
    runtime.transport = .{ .http = ai_transport.HttpTransport.init(allocator) };
    try runtime.initialize(io, cwd, config, options);
    return runtime;
}

pub fn session(self: *AgentSessionRuntime) *AgentSession {
    return &self.session_value;
}

// Heap destruction follows explicit field invalidation.
// ziglint-ignore: Z030
pub fn deinit(self: *AgentSessionRuntime) void {
    const allocator = self.allocator;
    self.session_value.deinit();
    self.model_runtime.deinit();
    self.* = undefined;
    allocator.destroy(self);
}

fn createWithTransport(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    transport: ai_transport.Transport,
    config: Config,
    options: Options,
) CreateError!*AgentSessionRuntime {
    const runtime = try allocator.create(AgentSessionRuntime);
    errdefer allocator.destroy(runtime);
    runtime.allocator = allocator;
    runtime.transport = .{ .borrowed = transport };
    try runtime.initialize(io, cwd, config, options);
    return runtime;
}

fn initialize(
    self: *AgentSessionRuntime,
    io: std.Io,
    cwd: std.Io.Dir,
    config: Config,
    options: Options,
) CreateError!void {
    try self.model_runtime.init(self.allocator, self.transport.view(), config);
    errdefer self.model_runtime.deinit();
    self.session_value = try AgentSession.init(
        self.allocator,
        io,
        self.model_runtime.model(),
        cwd,
        options.limits,
        options.events,
    );
}

fn validateConfig(config: Config) error{InvalidModelConfiguration}!void {
    config.model_config.validate() catch return error.InvalidModelConfiguration;
    if (config.credentials.len > max_credentials) return error.InvalidModelConfiguration;
    for (config.credentials, 0..) |credential, index| {
        switch (credential) {
            .api_key => |api_key| {
                if (api_key.provider_id.len == 0 or api_key.value.len == 0) {
                    return error.InvalidModelConfiguration;
                }
                const provider = config.model_config.findProvider(api_key.provider_id) orelse
                    return error.InvalidModelConfiguration;
                const accepts_api_key = switch (provider.*) {
                    .openai_completions, .openai_responses => |definition| switch (definition.authentication) {
                        .none => false,
                        .api_key => true,
                    },
                    .openai_codex_responses => false,
                };
                if (!accepts_api_key) return error.InvalidModelConfiguration;
            },
            .openai_codex => |openai_codex| {
                if (openai_codex.access_token.len == 0) return error.InvalidModelConfiguration;
                if (openai_codex.account_id) |account_id| {
                    if (account_id.len == 0) return error.InvalidModelConfiguration;
                }
                const provider = config.model_config.findProvider("openai-codex") orelse
                    return error.InvalidModelConfiguration;
                if (provider.* != .openai_codex_responses) return error.InvalidModelConfiguration;
            },
        }
        for (config.credentials[0..index]) |previous| {
            if (std.mem.eql(u8, previous.providerId(), credential.providerId())) {
                return error.InvalidModelConfiguration;
            }
        }
    }
    const selected = config.model_config.resolve(config.selection) orelse
        return error.InvalidModelConfiguration;
    const provider = config.model_config.findProvider(selected.providerId()).?;
    if (!providerAvailable(provider.*, config.credentials)) return error.InvalidModelConfiguration;
}

fn providerAvailable(provider: ModelConfig.ProviderDefinition, credentials: []const Credential) bool {
    return switch (provider) {
        .openai_completions, .openai_responses => |definition| switch (definition.authentication) {
            .none => true,
            .api_key => findApiKey(credentials, definition.id) != null,
        },
        .openai_codex_responses => findCodexCredential(credentials) != null,
    };
}

fn findApiKey(credentials: []const Credential, provider_id: []const u8) ?[]const u8 {
    for (credentials) |credential| switch (credential) {
        .api_key => |api_key| if (std.mem.eql(u8, api_key.provider_id, provider_id)) return api_key.value,
        .openai_codex => {},
    };
    return null;
}

fn findCodexCredential(credentials: []const Credential) ?Credential.OpenAiCodex {
    for (credentials) |credential| switch (credential) {
        .api_key => {},
        .openai_codex => |openai_codex| return openai_codex,
    };
    return null;
}

fn copyCatalog(allocator: std.mem.Allocator, source: ai_catalog.Catalog) error{OutOfMemory}!ai_catalog.Catalog {
    const entries = try allocator.alloc(ai_catalog.Entry, source.entries.len);
    for (source.entries, 0..) |entry, index| {
        const aliases = try allocator.alloc([]const u8, entry.aliases.len);
        for (entry.aliases, 0..) |alias, alias_index| {
            aliases[alias_index] = try allocator.dupe(u8, alias);
        }
        entries[index] = .{
            .identity = .{
                .provider = try allocator.dupe(u8, entry.identity.provider),
                .model = try allocator.dupe(u8, entry.identity.model),
            },
            .aliases = aliases,
            .source_url = if (entry.source_url) |source_url| try allocator.dupe(u8, source_url) else null,
            .profile = entry.profile,
        };
    }
    return .{ .entries = entries };
}

const fake_api = @import("../ai/transport/fake.zig");

const test_compatible_profile = profile: {
    var value: ai_settings.ModelProfile = .{};
    value.capabilities = .initMany(&.{ .streaming, .tools, .parallel_tool_calls, .thinking });
    value.settings = .initMany(&.{ .temperature, .top_p, .max_output_tokens, .stop_sequences, .seed });
    break :profile value;
};
const test_responses_profile = profile: {
    var value: ai_settings.ModelProfile = .{};
    value.capabilities = .initMany(&.{ .streaming, .tools, .parallel_tool_calls, .thinking });
    value.settings = .initMany(&.{ .max_output_tokens, .reasoning_effort });
    value.reasoning_efforts = .initMany(&.{ .low, .medium, .high });
    break :profile value;
};
const test_codex_profile = profile: {
    var value: ai_settings.ModelProfile = .{};
    value.capabilities = .initMany(&.{ .streaming, .tools, .parallel_tool_calls, .thinking });
    value.settings = .initMany(&.{.reasoning_effort});
    value.reasoning_efforts = .initMany(&.{ .minimal, .low, .medium, .high });
    break :profile value;
};
const test_catalog_entries = [_]ai_catalog.Entry{
    .{
        .identity = .{ .provider = "runtime-openai", .model = "runtime-model" },
        .aliases = &.{"runtime-latest"},
        .profile = test_compatible_profile,
    },
    .{
        .identity = .{ .provider = "openai", .model = "responses-runtime" },
        .aliases = &.{"responses-latest"},
        .profile = test_responses_profile,
    },
    .{
        .identity = .{ .provider = "openai-codex", .model = "codex-runtime" },
        .profile = test_codex_profile,
    },
};
const test_catalog: ai_catalog.Catalog = .{ .entries = &test_catalog_entries };
const test_provider_definitions = [_]ModelConfig.ProviderDefinition{
    .{ .openai_completions = .{
        .id = "runtime-openai",
        .name = "Runtime OpenAI",
        .base_url = "https://example.test/v1",
        .authentication = .api_key,
    } },
    .{ .openai_responses = .{
        .id = "openai",
        .name = "OpenAI",
        .base_url = "https://api.openai.com/v1",
        .authentication = .api_key,
    } },
    .{ .openai_codex_responses = .{
        .id = "openai-codex",
        .name = "OpenAI Codex",
        .base_url = "https://chatgpt.com/backend-api",
    } },
};
const test_model_config: ModelConfig = .{
    .catalog = test_catalog,
    .providers = &test_provider_definitions,
};

const CompatibleInspector = struct {
    calls: usize = 0,

    fn inspect(context: *anyopaque, request: ai_transport.Request) error{Rejected}!void {
        const self: *CompatibleInspector = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, request.url, "https://example.test/v1/chat/completions")) return error.Rejected;
        if (std.mem.indexOf(u8, request.body, "\"model\":\"runtime-model\"") == null) return error.Rejected;
        if (!hasHeader(request, "authorization", "Bearer runtime-secret")) return error.Rejected;
        switch (self.calls) {
            0 => {
                if (std.mem.indexOf(u8, request.body, "\"content\":\"read note.txt\"") == null) {
                    return error.Rejected;
                }
                if (std.mem.indexOf(u8, request.body, "\"name\":\"read\"") == null) return error.Rejected;
            },
            1 => if (std.mem.indexOf(u8, request.body, "runtime evidence") == null) return error.Rejected,
            else => return error.Rejected,
        }
        self.calls += 1;
    }
};

const ResponsesInspector = struct {
    saw_request: bool = false,

    fn inspect(context: *anyopaque, request: ai_transport.Request) error{Rejected}!void {
        const self: *ResponsesInspector = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, request.url, "https://api.openai.com/v1/responses")) return error.Rejected;
        if (!hasHeader(request, "authorization", "Bearer responses-secret")) return error.Rejected;
        if (std.mem.indexOf(u8, request.body, "\"model\":\"responses-runtime\"") == null) {
            return error.Rejected;
        }
        self.saw_request = true;
    }
};

const CodexInspector = struct {
    saw_request: bool = false,

    fn inspect(context: *anyopaque, request: ai_transport.Request) error{Rejected}!void {
        const self: *CodexInspector = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, request.url, "https://chatgpt.com/backend-api/codex/responses")) {
            return error.Rejected;
        }
        if (!hasHeader(request, "authorization", "Bearer codex-secret")) return error.Rejected;
        if (!hasHeader(request, "chatgpt-account-id", "account-runtime")) return error.Rejected;
        if (std.mem.indexOf(u8, request.body, "\"model\":\"codex-runtime\"") == null) return error.Rejected;
        if (std.mem.indexOf(u8, request.body, "hello codex") == null) return error.Rejected;
        self.saw_request = true;
    }
};

fn hasHeader(request: ai_transport.Request, name: []const u8, value: []const u8) bool {
    for (request.headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name) and std.mem.eql(u8, header.value, value)) return true;
    }
    return false;
}

test "runtime owns catalog and provider configuration through a cwd-bound tool loop" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "note.txt", .data = "runtime evidence" });

    const tool_response =
        // ziglint-ignore: Z024 -- compact provider wire fixture
        \\{"choices":[{"message":{"content":null,"tool_calls":[{"id":"call-1","function":{"name":"read","arguments":"{\"path\":\"note.txt\"}"}}]},"finish_reason":"tool_calls"}]}
    ;
    const final_response =
        \\{"choices":[{"message":{"content":"runtime complete"},"finish_reason":"stop"}]}
    ;
    const exchanges = [_]fake_api.Exchange{
        .{ .response = .{ .status = 200, .body = tool_response } },
        .{ .response = .{ .status = 200, .body = final_response } },
    };
    var fake = fake_api.FakeTransport.init(&exchanges);
    var inspector: CompatibleInspector = .{};
    fake.inspector = .{ .context = &inspector, .inspect_fn = CompatibleInspector.inspect };

    const provider_id = try std.testing.allocator.dupe(u8, "runtime-openai");
    defer std.testing.allocator.free(provider_id);
    const model_id = try std.testing.allocator.dupe(u8, "runtime-latest");
    defer std.testing.allocator.free(model_id);
    const canonical_model_id = try std.testing.allocator.dupe(u8, "runtime-model");
    defer std.testing.allocator.free(canonical_model_id);
    const aliases = [_][]const u8{model_id};
    var catalog_entries = test_catalog_entries;
    catalog_entries[0].identity = .{ .provider = provider_id, .model = canonical_model_id };
    catalog_entries[0].aliases = &aliases;
    const caller_catalog: ai_catalog.Catalog = .{ .entries = &catalog_entries };
    const base_url = try std.testing.allocator.dupe(u8, "https://example.test/v1");
    defer std.testing.allocator.free(base_url);
    const api_key = try std.testing.allocator.dupe(u8, "runtime-secret");
    defer std.testing.allocator.free(api_key);
    var provider_definitions = test_provider_definitions;
    provider_definitions[0] = .{ .openai_completions = .{
        .id = provider_id,
        .name = "Runtime OpenAI",
        .base_url = base_url,
        .authentication = .api_key,
    } };
    const caller_model_config: ModelConfig = .{
        .catalog = caller_catalog,
        .providers = &provider_definitions,
    };
    const credentials = [_]Credential{
        .{ .api_key = .{ .provider_id = provider_id, .value = api_key } },
        .{ .api_key = .{ .provider_id = "openai", .value = "unused-responses-secret" } },
        .{ .openai_codex = .{
            .access_token = "unused-codex-secret",
            .account_id = "unused-account",
        } },
    };

    var runtime = try createWithTransport(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        fake.transport(),
        .{
            .model_config = caller_model_config,
            .credentials = &credentials,
            .selection = .{ .provider = provider_id, .model = model_id },
        },
        .{},
    );
    defer runtime.deinit();
    @memset(provider_id, 'x');
    @memset(model_id, 'x');
    @memset(canonical_model_id, 'x');
    @memset(base_url, 'x');
    @memset(api_key, 'x');

    const result = try runtime.session().prompt("read note.txt");
    try std.testing.expectEqualStrings("runtime complete", result);
    try std.testing.expect(runtime.session().state() == .completed);
    try std.testing.expectEqual(@as(usize, 2), fake.next_index);
    try std.testing.expectEqual(@as(usize, 2), inspector.calls);
    const history = runtime.session().messages();
    try std.testing.expectEqualStrings("runtime-openai", history[3].response.identity.provider);
    try std.testing.expectEqualStrings("runtime-model", history[3].response.identity.model);
}

test "OpenAI Responses runtime crosses the provider and protocol seams" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const response =
        // ziglint-ignore: Z024 -- compact provider wire fixture
        \\data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"msg_1","content":[]}}
        \\
        \\data: {"type":"response.output_text.delta","output_index":0,"delta":"responses complete"}
        \\
        \\data: {"type":"response.completed","response":{"status":"completed"}}
        \\
    ;
    const exchanges = [_]fake_api.Exchange{.{ .response = .{ .status = 200, .body = response, .chunk_bytes = 9 } }};
    var fake = fake_api.FakeTransport.init(&exchanges);
    var inspector: ResponsesInspector = .{};
    fake.inspector = .{ .context = &inspector, .inspect_fn = ResponsesInspector.inspect };
    var resolved = try model_resolution.resolve(std.testing.allocator, .{
        .model_config = test_model_config,
        .requested_provider = "openai",
        .requested_model = "responses-latest",
        .cli_api_key = "responses-secret",
    });
    defer resolved.deinit();

    var runtime = try createWithTransport(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        fake.transport(),
        resolved.runtimeConfig(),
        .{},
    );
    defer runtime.deinit();

    try std.testing.expectEqualStrings("responses complete", try runtime.session().prompt("hello responses"));
    try std.testing.expect(inspector.saw_request);
}

test "OpenAI Codex runtime crosses the provider and Responses SSE seams" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const response =
        // ziglint-ignore: Z024 -- compact provider wire fixture
        \\data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"msg_1","content":[]}}
        \\
        \\data: {"type":"response.output_text.delta","output_index":0,"delta":"codex complete"}
        \\
        \\data: {"type":"response.completed","response":{"status":"completed"}}
        \\
    ;
    const exchanges = [_]fake_api.Exchange{.{ .response = .{ .status = 200, .body = response, .chunk_bytes = 11 } }};
    var fake = fake_api.FakeTransport.init(&exchanges);
    var inspector: CodexInspector = .{};
    fake.inspector = .{ .context = &inspector, .inspect_fn = CodexInspector.inspect };
    const credentials = [_]Credential{.{ .openai_codex = .{
        .access_token = "codex-secret",
        .account_id = "account-runtime",
    } }};

    var runtime = try createWithTransport(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        fake.transport(),
        .{
            .model_config = test_model_config,
            .credentials = &credentials,
            .selection = .{ .provider = "openai-codex", .model = "codex-runtime" },
        },
        .{},
    );
    defer runtime.deinit();

    try std.testing.expectEqualStrings("codex complete", try runtime.session().prompt("hello codex"));
    try std.testing.expect(inspector.saw_request);
}

test "runtime rejects invalid credentials and unavailable selections before transport admission" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const exchanges: [0]fake_api.Exchange = .{};
    var fake = fake_api.FakeTransport.init(&exchanges);
    const no_credentials: [0]Credential = .{};
    const empty_provider_id = [_]Credential{.{ .api_key = .{ .provider_id = "", .value = "key" } }};
    const empty_api_key = [_]Credential{.{ .api_key = .{ .provider_id = "openai", .value = "" } }};
    const unknown_provider = [_]Credential{.{ .api_key = .{ .provider_id = "missing", .value = "key" } }};
    const empty_access_token = [_]Credential{.{ .openai_codex = .{ .access_token = "" } }};
    const empty_account_id = [_]Credential{.{ .openai_codex = .{
        .access_token = "token",
        .account_id = "",
    } }};
    const duplicate_credentials = [_]Credential{
        .{ .api_key = .{ .provider_id = "openai", .value = "one" } },
        .{ .api_key = .{ .provider_id = "openai", .value = "two" } },
    };
    const openai_credential = [_]Credential{.{ .api_key = .{
        .provider_id = "openai",
        .value = "key",
    } }};
    const no_auth_definitions = [_]ModelConfig.ProviderDefinition{.{ .openai_completions = .{
        .id = "runtime-openai",
        .name = "Runtime OpenAI",
        .base_url = "https://example.test/v1",
        .authentication = .none,
    } }};
    const no_auth_config: ModelConfig = .{
        .catalog = test_catalog,
        .providers = &no_auth_definitions,
    };
    const unexpected_api_key = [_]Credential{.{ .api_key = .{
        .provider_id = "runtime-openai",
        .value = "key",
    } }};
    const openai_only_definitions = [_]ModelConfig.ProviderDefinition{test_provider_definitions[1]};
    const openai_only_config: ModelConfig = .{
        .catalog = test_catalog,
        .providers = &openai_only_definitions,
    };
    const unexpected_codex = [_]Credential{.{ .openai_codex = .{ .access_token = "token" } }};
    const cases = [_]Config{
        .{ .model_config = test_model_config, .credentials = &empty_provider_id, .selection = .{
            .provider = "openai",
            .model = "responses-runtime",
        } },
        .{ .model_config = test_model_config, .credentials = &empty_api_key, .selection = .{
            .provider = "openai",
            .model = "responses-runtime",
        } },
        .{ .model_config = test_model_config, .credentials = &unknown_provider, .selection = .{
            .provider = "openai",
            .model = "responses-runtime",
        } },
        .{ .model_config = no_auth_config, .credentials = &unexpected_api_key, .selection = .{
            .provider = "runtime-openai",
            .model = "runtime-model",
        } },
        .{ .model_config = test_model_config, .credentials = &empty_access_token, .selection = .{
            .provider = "openai-codex",
            .model = "codex-runtime",
        } },
        .{ .model_config = test_model_config, .credentials = &empty_account_id, .selection = .{
            .provider = "openai-codex",
            .model = "codex-runtime",
        } },
        .{ .model_config = test_model_config, .credentials = &duplicate_credentials, .selection = .{
            .provider = "openai",
            .model = "responses-runtime",
        } },
        .{ .model_config = test_model_config, .credentials = &no_credentials, .selection = .{
            .provider = "openai",
            .model = "responses-runtime",
        } },
        .{ .model_config = openai_only_config, .credentials = &unexpected_codex, .selection = .{
            .provider = "openai",
            .model = "responses-runtime",
        } },
        .{ .model_config = test_model_config, .credentials = &openai_credential, .selection = .{
            .provider = "openai",
            .model = "missing",
        } },
    };
    for (cases) |config| {
        try std.testing.expectError(error.InvalidModelConfiguration, createWithTransport(
            std.testing.allocator,
            std.testing.io,
            temporary.dir,
            fake.transport(),
            config,
            .{},
        ));
    }
    try std.testing.expectEqual(@as(usize, 0), fake.next_index);
}

fn createAndDisposeForAllocationFailure(allocator: std.mem.Allocator, cwd: std.Io.Dir) !void {
    const exchanges: [0]fake_api.Exchange = .{};
    var fake = fake_api.FakeTransport.init(&exchanges);
    const credentials = [_]Credential{
        .{ .api_key = .{ .provider_id = "runtime-openai", .value = "runtime-secret" } },
        .{ .api_key = .{ .provider_id = "openai", .value = "responses-secret" } },
        .{ .openai_codex = .{
            .access_token = "codex-secret",
            .account_id = "account-runtime",
        } },
    };
    var runtime = try createWithTransport(
        allocator,
        std.testing.io,
        cwd,
        fake.transport(),
        .{
            .model_config = test_model_config,
            .credentials = &credentials,
            .selection = .{ .provider = "runtime-openai", .model = "runtime-model" },
        },
        .{},
    );
    runtime.deinit();
}

test "runtime construction settles every allocation failure" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        createAndDisposeForAllocationFailure,
        .{temporary.dir},
    );
}

test "runtime wipes every copied credential and Codex account ID" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const backing = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(backing);
    @memset(backing, 0xa5);
    var fixed = std.heap.FixedBufferAllocator.init(backing);
    const exchanges: [0]fake_api.Exchange = .{};
    var fake = fake_api.FakeTransport.init(&exchanges);
    const credentials = [_]Credential{
        .{ .api_key = .{ .provider_id = "openai", .value = "wipe-openai-secret" } },
        .{ .openai_codex = .{
            .access_token = "wipe-codex-secret",
            .account_id = "wipe-account-runtime",
        } },
    };

    var runtime = try createWithTransport(
        fixed.allocator(),
        std.testing.io,
        temporary.dir,
        fake.transport(),
        .{
            .model_config = test_model_config,
            .credentials = &credentials,
            .selection = .{ .provider = "openai", .model = "responses-runtime" },
        },
        .{},
    );
    const sensitive = runtime.model_runtime.sensitive[0..runtime.model_runtime.sensitive_count];
    try std.testing.expectEqual(@as(usize, 3), sensitive.len);
    var offsets: [3]usize = undefined;
    var lengths: [3]usize = undefined;
    for (sensitive, 0..) |value, index| {
        offsets[index] = @intFromPtr(value.ptr) - @intFromPtr(backing.ptr);
        lengths[index] = value.len;
    }
    runtime.deinit();
    for (offsets, lengths) |offset, length| {
        for (backing[offset..][0..length]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "production runtime uses built-in model configuration without model IO" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const credentials = [_]Credential{.{ .api_key = .{
        .provider_id = "openai",
        .value = "runtime-secret",
    } }};
    var runtime = try create(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        .{
            .model_config = ModelConfig.builtin,
            .credentials = &credentials,
            .selection = .{ .provider = "openai", .model = "gpt-5.6" },
        },
        .{},
    );
    runtime.deinit();
}
