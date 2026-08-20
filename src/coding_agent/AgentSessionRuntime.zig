const std = @import("std");
const ai = @import("../ai/root.zig");
const agent_api = @import("../agent/root.zig");
const ai_catalog = ai.model_catalog;
const ai_model = ai.model;
const ai_models = ai.models;
const ai_protocol = ai.protocol_api;
const ai_protocols = ai.protocols;
const ai_settings = ai.settings;
const ai_transport = ai.transport;
const AgentSession = @import("AgentSession.zig");
const ModelConfig = @import("ModelConfig.zig");
const ModelConfigSnapshot = @import("ModelConfigSnapshot.zig");
const SessionCommit = @import("SessionCommit.zig");
const SessionFormat = @import("SessionFormat.zig");
const SessionJournal = @import("SessionJournal.zig");
const ZiPaths = @import("ZiPaths.zig");
const model_resolution = @import("ModelResolution.zig");

const AgentSessionRuntime = @This();
const max_credentials = 32;

pub const Credential = model_resolution.StoredCredential;
pub const Config = model_resolution.RuntimeConfig;

pub const Options = AgentSession.Options;

pub const CreateError = error{
    OutOfMemory,
    InvalidModelConfiguration,
    InvalidSystemPrompt,
    SystemPromptTooLarge,
    DuplicateToolName,
    InvalidToolDefinition,
    UnknownTool,
    InvalidToolArguments,
};

pub const DurableCreateError = error{
    OutOfMemory,
    InvalidModelConfiguration,
    InvalidSystemPrompt,
    SystemPromptTooLarge,
    DuplicateToolName,
    InvalidToolDefinition,
    UnknownTool,
    InvalidToolArguments,
    PersistenceFailed,
    CommitIndeterminate,
    SessionTooLarge,
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
model_runtime: ai_models,
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

pub fn createDurable(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    config: Config,
    options: Options,
    opened: *SessionJournal.Opened,
    sources: SessionFormat.Sources,
) DurableCreateError!*AgentSessionRuntime {
    var owned = opened.*;
    opened.* = undefined;
    var owned_live = true;
    errdefer if (owned_live) owned.deinit();
    const runtime = try allocator.create(AgentSessionRuntime);
    errdefer allocator.destroy(runtime);
    runtime.allocator = allocator;
    runtime.transport = .{ .http = ai_transport.HttpTransport.init(allocator) };
    const initialize_result = runtime.initializeDurable(
        io,
        cwd,
        config,
        options,
        &owned,
        sources,
        .none(),
    );
    owned_live = false;
    try initialize_result;
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

pub fn createDurableWithTransport(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    transport: ai_transport.Transport,
    config: Config,
    options: Options,
    opened: *SessionJournal.Opened,
    sources: SessionFormat.Sources,
    faults: SessionJournal.Faults,
) DurableCreateError!*AgentSessionRuntime {
    var owned = opened.*;
    opened.* = undefined;
    var owned_live = true;
    errdefer if (owned_live) owned.deinit();
    const runtime = try allocator.create(AgentSessionRuntime);
    errdefer allocator.destroy(runtime);
    runtime.allocator = allocator;
    runtime.transport = .{ .borrowed = transport };
    const initialize_result = runtime.initializeDurable(io, cwd, config, options, &owned, sources, faults);
    owned_live = false;
    try initialize_result;
    return runtime;
}

fn initialize(
    self: *AgentSessionRuntime,
    io: std.Io,
    cwd: std.Io.Dir,
    config: Config,
    options: Options,
) CreateError!void {
    self.model_runtime = ai_models.init(
        self.allocator,
        self.transport.view(),
        ai_protocol.Registry.init(&ai_protocols.builtin) catch return error.InvalidModelConfiguration,
        .{
            .catalog = config.model_config.catalog,
            .providers = config.model_config.providers,
            .credentials = config.credentials,
            .auth_resolver = config.auth_resolver,
            .selection = config.selection,
        },
    ) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidConfiguration => error.InvalidModelConfiguration,
    };
    errdefer self.model_runtime.deinit();
    self.session_value = try AgentSession.init(
        self.allocator,
        io,
        self.model_runtime.model(),
        cwd,
        options,
    );
}

fn initializeDurable(
    self: *AgentSessionRuntime,
    io: std.Io,
    cwd: std.Io.Dir,
    config: Config,
    options: Options,
    opened: *SessionJournal.Opened,
    sources: SessionFormat.Sources,
    faults: SessionJournal.Faults,
) DurableCreateError!void {
    var opened_owned = true;
    errdefer if (opened_owned) opened.deinit();
    try self.initialize(io, cwd, config, options);
    errdefer {
        self.session_value.deinit();
        self.model_runtime.deinit();
    }

    const commit_result = SessionCommit.create(
        self.allocator,
        opened,
        sources,
        self.model_runtime.model().identity,
        faults,
    );
    opened_owned = false;
    const commit_owner = commit_result catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        error.SessionTooLarge => error.SessionTooLarge,
        error.PersistenceFailed => error.PersistenceFailed,
        error.CommitIndeterminate => error.CommitIndeterminate,
    };
    errdefer commit_owner.deinit();
    try commit_owner.bindAgent(&self.session_value.agent);
    self.session_value.commit_owner = commit_owner;
}

const fake_api = ai.transport_testing;

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
        .protocol_id = "openai-completions",
        .aliases = &.{"runtime-latest"},
        .profile = test_compatible_profile,
    },
    .{
        .identity = .{ .provider = "openai", .model = "responses-runtime" },
        .protocol_id = "openai-responses",
        .aliases = &.{"responses-latest"},
        .profile = test_responses_profile,
    },
    .{
        .identity = .{ .provider = "openai-codex", .model = "codex-runtime" },
        .protocol_id = "openai-codex-responses",
        .profile = test_codex_profile,
    },
};
const test_catalog: ai_catalog.Catalog = .{ .entries = &test_catalog_entries };
const test_provider_definitions = [_]ModelConfig.ProviderDefinition{
    .{
        .id = "runtime-openai",
        .name = "Runtime OpenAI",
        .base_url = "https://example.test/v1",
        .auth = .{ .api_key = .{} },
    },
    .{
        .id = "openai",
        .name = "OpenAI",
        .base_url = "https://api.openai.com/v1",
        .auth = .{ .api_key = .{} },
    },
    .{
        .id = "openai-codex",
        .name = "OpenAI Codex",
        .base_url = "https://chatgpt.com/backend-api",
        .auth = .{ .oauth = .{} },
    },
};
const test_model_config: ModelConfig = .{
    .catalog = test_catalog,
    .providers = &test_provider_definitions,
};

fn apiKeyCredential(provider_id: []const u8, key: []const u8) Credential {
    return .{ .provider_id = provider_id, .credential = .{ .api_key = .{ .key = key } } };
}

fn oauthCredential(provider_id: []const u8, access: []const u8, account_id: ?[]const u8) Credential {
    return .{
        .provider_id = provider_id,
        .credential = .{ .oauth = .{
            .access = access,
            .refresh = "refresh",
            .expires_at_ms = 1,
            .account_id = account_id,
        } },
    };
}

const CustomResponsesInspector = struct {
    calls: usize = 0,

    fn inspect(context: *anyopaque, request: ai_transport.Request) error{Rejected}!void {
        const self: *CustomResponsesInspector = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, request.url, "https://example.test/openai/v1/responses")) {
            return error.Rejected;
        }
        if (std.mem.indexOf(u8, request.body, "\"model\":\"custom-reasoning-model\"") == null) {
            return error.Rejected;
        }
        if (!hasHeader(request, "authorization", "Bearer runtime-secret")) return error.Rejected;
        switch (self.calls) {
            0 => {
                if (std.mem.indexOf(u8, request.body, "read note.txt") == null) {
                    return error.Rejected;
                }
                if (std.mem.indexOf(u8, request.body, "\"name\":\"read\"") == null) return error.Rejected;
            },
            1 => {
                if (std.mem.indexOf(u8, request.body, "\"type\":\"function_call_output\"") == null) {
                    return error.Rejected;
                }
                if (std.mem.indexOf(u8, request.body, "runtime evidence") == null) return error.Rejected;
            },
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

const DurableSources = struct {
    next_id: u64 = 0,
    next_ms: u64 = 1_777_800_000_000,

    fn nextId(context: *anyopaque) [16]u8 {
        const self: *DurableSources = @ptrCast(@alignCast(context));
        self.next_id += 1;
        var bytes: [16]u8 = @splat(0);
        std.mem.writeInt(u64, bytes[8..16], self.next_id, .big);
        return bytes;
    }

    fn nowMs(context: *anyopaque) u64 {
        const self: *DurableSources = @ptrCast(@alignCast(context));
        defer self.next_ms += 1;
        return self.next_ms;
    }

    fn view(self: *DurableSources) SessionFormat.Sources {
        return .{
            .id_context = self,
            .nextIdFn = nextId,
            .clock_context = self,
            .nowMsFn = nowMs,
        };
    }
};

const AppendFault = struct {
    fail_on_record: usize,
    records_seen: usize = 0,
    failed: bool = false,

    fn boundary(context: *anyopaque, point: SessionJournal.Boundary) anyerror!void {
        const self: *AppendFault = @ptrCast(@alignCast(context));
        if (point != .after_append_record_write) return;
        self.records_seen += 1;
        if (!self.failed and self.records_seen == self.fail_on_record) {
            self.failed = true;
            return error.InjectedFault;
        }
    }

    fn faults(self: *AppendFault) SessionJournal.Faults {
        return .{ .context = self, .boundaryFn = boundary };
    }
};

const DurableEventRecorder = struct {
    model_completions: usize = 0,
    tool_completions: usize = 0,

    fn emit(context: *anyopaque, event: AgentSession.Event) agent_api.event.SinkError!void {
        const self: *DurableEventRecorder = @ptrCast(@alignCast(context));
        switch (event) {
            .message_end => |ended| switch (ended.message) {
                .published => |message| if (message == .response) {
                    self.model_completions += 1;
                },
                .discarded_response => {},
            },
            .tool_execution_end => |ended| switch (ended.result) {
                .published => self.tool_completions += 1,
                .discarded => {},
            },
            else => {},
        }
    }
};

fn createTestJournal(
    dir: std.Io.Dir,
    cwd: []const u8,
) !SessionJournal.Opened {
    return SessionJournal.create(
        std.testing.allocator,
        std.testing.io,
        dir,
        "session.jsonl",
        .{
            .id = "session-runtime",
            .timestamp = "2026-08-19T10:30:00.000Z",
            .cwd = cwd,
        },
        .none(),
    );
}

test "runtime owns catalog and provider configuration through a cwd-bound tool loop" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "note.txt", .data = "runtime evidence" });
    try temporary.dir.createDirPath(std.testing.io, ".zi/agent");
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".zi/agent/models.json",
        .data =
        \\{
        \\  "providers": {
        \\    "custom-openai": {
        \\      "baseUrl": "https://example.test/openai/v1",
        \\      "protocol": "openai-responses",
        \\      "models": [{
        \\        "id": "custom-reasoning-model",
        \\        "reasoning": true,
        \\        "input": ["text", "image"],
        \\        "contextWindow": 272000,
        \\        "maxTokens": 128000
        \\      }]
        \\    }
        \\  }
        \\}
        ,
    });

    const tool_response =
        // ziglint-ignore: Z024 -- compact provider wire fixture
        \\data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"read"}}
        \\
        \\data: {"type":"response.function_call_arguments.delta","output_index":0,"delta":"{\"path\":"}
        \\
        \\data: {"type":"response.function_call_arguments.delta","output_index":0,"delta":"\"note.txt\"}"}
        \\
        \\data: {"type":"response.function_call_arguments.done","output_index":0,"arguments":"{\"path\":\"note.txt\"}"}
        \\
        // ziglint-ignore: Z024 -- compact provider wire fixture
        \\data: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"read","arguments":"{\"path\":\"note.txt\"}"}}
        \\
        \\data: {"type":"response.completed","response":{"status":"completed"}}
        \\
    ;
    const final_response =
        // ziglint-ignore: Z024 -- compact provider wire fixture
        \\data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"msg_1","content":[]}}
        \\
        \\data: {"type":"response.output_text.delta","output_index":0,"delta":"runtime complete"}
        \\
        \\data: {"type":"response.completed","response":{"status":"completed"}}
        \\
    ;
    const exchanges = [_]fake_api.Exchange{
        .{ .response = .{ .status = 200, .body = tool_response, .chunk_bytes = 13 } },
        .{ .response = .{ .status = 200, .body = final_response, .chunk_bytes = 11 } },
    };
    var fake = fake_api.FakeTransport.init(&exchanges);
    var inspector: CustomResponsesInspector = .{};
    fake.inspector = .{ .context = &inspector, .inspect_fn = CustomResponsesInspector.inspect };

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_length = try temporary.dir.realPath(std.testing.io, &path_buffer);
    var paths = try ZiPaths.init(
        std.testing.allocator,
        path_buffer[0..path_length],
        path_buffer[0..path_length],
    );
    errdefer paths.deinit();
    var snapshot = try ModelConfigSnapshot.load(std.testing.allocator, std.testing.io, &paths);
    errdefer snapshot.deinit();
    try std.testing.expect(snapshot.diagnostic() == null);
    var resolved = try model_resolution.resolve(std.testing.allocator, .{
        .model_config = snapshot.view(),
        .requested_provider = "custom-openai",
        .requested_model = "custom-reasoning-model",
        .cli_api_key = "runtime-secret",
    });
    errdefer resolved.deinit();

    var runtime = try createWithTransport(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        fake.transport(),
        resolved.runtimeConfig(),
        .{},
    );
    defer runtime.deinit();
    resolved.deinit();
    snapshot.deinit();
    paths.deinit();

    const result = try runtime.session().prompt("read note.txt");
    try std.testing.expectEqualStrings("runtime complete", result);
    try std.testing.expect(runtime.session().state() == .ready);
    try std.testing.expectEqual(@as(usize, 2), fake.next_index);
    try std.testing.expectEqual(@as(usize, 2), inspector.calls);
    const history = runtime.session().messages();
    try std.testing.expectEqualStrings("custom-openai", history[3].response.identity.provider);
    try std.testing.expectEqualStrings("custom-reasoning-model", history[3].response.identity.model);
}

test "durable runtime commits a FakeTransport tool loop before publishing history" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "note.txt", .data = "durable evidence" });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_length = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const cwd = path_buffer[0..path_length];
    var opened = try createTestJournal(temporary.dir, cwd);

    const tool_response =
        // ziglint-ignore: Z024 -- compact provider wire fixture
        \\data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"read"}}
        \\
        \\data: {"type":"response.function_call_arguments.done","output_index":0,"arguments":"{\"path\":\"note.txt\"}"}
        \\
        // ziglint-ignore: Z024 -- compact provider wire fixture
        \\data: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"read","arguments":"{\"path\":\"note.txt\"}"}}
        \\
        \\data: {"type":"response.completed","response":{"status":"completed"}}
        \\
    ;
    const final_response =
        // ziglint-ignore: Z024 -- compact provider wire fixture
        \\data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"msg_1","content":[]}}
        \\
        \\data: {"type":"response.output_text.delta","output_index":0,"delta":"durably complete"}
        \\
        \\data: {"type":"response.completed","response":{"status":"completed"}}
        \\
    ;
    const exchanges = [_]fake_api.Exchange{
        .{ .response = .{ .status = 200, .body = tool_response, .chunk_bytes = 13 } },
        .{ .response = .{ .status = 200, .body = final_response, .chunk_bytes = 11 } },
    };
    var fake = fake_api.FakeTransport.init(&exchanges);
    var sources: DurableSources = .{};
    const credentials = [_]Credential{apiKeyCredential("openai", "responses-secret")};
    var runtime = try createDurableWithTransport(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        fake.transport(),
        .{
            .model_config = test_model_config,
            .credentials = &credentials,
            .selection = .{ .provider = "openai", .model = "responses-runtime" },
        },
        .{},
        &opened,
        sources.view(),
        .none(),
    );
    errdefer runtime.deinit();

    try std.testing.expectEqualStrings("durably complete", try runtime.session().prompt("read note.txt"));
    try std.testing.expectEqual(@as(usize, 4), runtime.session().messages().len);
    runtime.deinit();

    var restored = try SessionJournal.openReadOnly(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        "session.jsonl",
    );
    defer restored.deinit();
    const entries = restored.restore_candidate.entries;
    try std.testing.expectEqual(@as(usize, 6), entries.len);
    try std.testing.expect(entries[0] == .model_change);
    try std.testing.expect(entries[1] == .message);
    try std.testing.expect(entries[2] == .message);
    try std.testing.expect(entries[3] == .message);
    try std.testing.expect(entries[4] == .message);
    try std.testing.expect(entries[5].turn_end.outcome == .completed);
    try std.testing.expectEqual(@as(usize, 4), restored.restore_candidate.context_messages.len);
    try std.testing.expectEqualStrings(
        "durable evidence",
        restored.restore_candidate.context_messages[2].request.parts[0].tool_result.content[0].text,
    );
    try std.testing.expect(restored.restore_candidate.recovery == .clean);
}

test "durable runtime publishes neither a message nor completion event before journal commit" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_length = try temporary.dir.realPath(std.testing.io, &path_buffer);
    var opened = try createTestJournal(temporary.dir, path_buffer[0..path_length]);
    const response =
        // ziglint-ignore: Z024 -- compact provider wire fixture
        \\data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"msg_1","content":[]}}
        \\
        \\data: {"type":"response.output_text.delta","output_index":0,"delta":"must not publish"}
        \\
        \\data: {"type":"response.completed","response":{"status":"completed"}}
        \\
    ;
    const exchanges = [_]fake_api.Exchange{.{ .response = .{
        .status = 200,
        .body = response,
        .chunk_bytes = 9,
    } }};
    var fake = fake_api.FakeTransport.init(&exchanges);
    var sources: DurableSources = .{};
    var fault: AppendFault = .{ .fail_on_record = 3 };
    var events: DurableEventRecorder = .{};
    const credentials = [_]Credential{apiKeyCredential("openai", "responses-secret")};
    var runtime = try createDurableWithTransport(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        fake.transport(),
        .{
            .model_config = test_model_config,
            .credentials = &credentials,
            .selection = .{ .provider = "openai", .model = "responses-runtime" },
        },
        .{ .events = .{ .context = &events, .emitFn = DurableEventRecorder.emit } },
        &opened,
        sources.view(),
        fault.faults(),
    );
    errdefer runtime.deinit();

    try std.testing.expectError(error.PersistenceFailed, runtime.session().prompt("hello"));
    try std.testing.expectEqual(@as(usize, 1), runtime.session().messages().len);
    try std.testing.expectEqual(@as(usize, 0), events.model_completions);
    try std.testing.expect(runtime.session().state() == .ready);
    runtime.deinit();

    var restored = try SessionJournal.openReadOnly(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        "session.jsonl",
    );
    defer restored.deinit();
    const entries = restored.restore_candidate.entries;
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expect(entries[0] == .model_change);
    try std.testing.expect(entries[1].message.message == .request);
    try std.testing.expectEqual(
        SessionFormat.FailureCategory.persistence_failed,
        entries[2].turn_end.outcome.failed,
    );
    try std.testing.expectEqual(@as(usize, 1), restored.restore_candidate.context_messages.len);
}

test "durable runtime withholds a tool result and completion event when its commit fails" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_length = try temporary.dir.realPath(std.testing.io, &path_buffer);
    var opened = try createTestJournal(temporary.dir, path_buffer[0..path_length]);
    const response =
        // ziglint-ignore: Z024 -- compact provider wire fixture
        \\data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"write"}}
        \\
        // ziglint-ignore: Z024 -- compact provider wire fixture
        \\data: {"type":"response.function_call_arguments.done","output_index":0,"arguments":"{\"path\":\"created.txt\",\"content\":\"tool effect\"}"}
        \\
        // ziglint-ignore: Z024 -- compact provider wire fixture
        \\data: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"write","arguments":"{\"path\":\"created.txt\",\"content\":\"tool effect\"}"}}
        \\
        \\data: {"type":"response.completed","response":{"status":"completed"}}
        \\
    ;
    const exchanges = [_]fake_api.Exchange{.{ .response = .{
        .status = 200,
        .body = response,
        .chunk_bytes = 11,
    } }};
    var fake = fake_api.FakeTransport.init(&exchanges);
    var sources: DurableSources = .{};
    var fault: AppendFault = .{ .fail_on_record = 4 };
    var events: DurableEventRecorder = .{};
    const credentials = [_]Credential{apiKeyCredential("openai", "responses-secret")};
    var runtime = try createDurableWithTransport(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        fake.transport(),
        .{
            .model_config = test_model_config,
            .credentials = &credentials,
            .selection = .{ .provider = "openai", .model = "responses-runtime" },
        },
        .{ .events = .{ .context = &events, .emitFn = DurableEventRecorder.emit } },
        &opened,
        sources.view(),
        fault.faults(),
    );
    errdefer runtime.deinit();

    try std.testing.expectError(error.PersistenceFailed, runtime.session().prompt("write the file"));
    try std.testing.expectEqual(@as(usize, 1), runtime.session().messages().len);
    try std.testing.expectEqual(@as(usize, 1), events.model_completions);
    try std.testing.expectEqual(@as(usize, 0), events.tool_completions);
    const created = try temporary.dir.readFileAlloc(
        std.testing.io,
        "created.txt",
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(created);
    try std.testing.expectEqualStrings("tool effect", created);
    runtime.deinit();

    var restored = try SessionJournal.openReadOnly(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        "session.jsonl",
    );
    defer restored.deinit();
    const entries = restored.restore_candidate.entries;
    try std.testing.expectEqual(@as(usize, 4), entries.len);
    try std.testing.expect(entries[2].message.message == .response);
    try std.testing.expectEqual(
        SessionFormat.FailureCategory.persistence_failed,
        entries[3].turn_end.outcome.failed,
    );
    try std.testing.expectEqual(@as(usize, 1), restored.restore_candidate.context_messages.len);
}

test "durable runtime closes a restored open turn before admitting cancellation" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_length = try temporary.dir.realPath(std.testing.io, &path_buffer);
    var opened = try createTestJournal(temporary.dir, path_buffer[0..path_length]);
    try opened.journal.append(.{ .model_change = .{
        .base = .{
            .id = "model-entry",
            .parent_id = null,
            .timestamp = "2026-08-19T10:30:01.000Z",
        },
        .selection = .{ .provider = "openai", .model = "responses-runtime" },
    } }, .none());
    try opened.journal.append(.{ .message = .{
        .base = .{
            .id = "open-turn",
            .parent_id = "model-entry",
            .timestamp = "2026-08-19T10:30:02.000Z",
        },
        .message = .{ .request = .{ .parts = &.{.{ .user = .{ .text = "before crash" } }} } },
    } }, .none());
    opened.deinit();
    opened = try SessionJournal.openWritable(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        "session.jsonl",
    );

    const exchanges: [0]fake_api.Exchange = .{};
    var fake = fake_api.FakeTransport.init(&exchanges);
    var sources: DurableSources = .{};
    const credentials = [_]Credential{apiKeyCredential("openai", "responses-secret")};
    var runtime = try createDurableWithTransport(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        fake.transport(),
        .{
            .model_config = test_model_config,
            .credentials = &credentials,
            .selection = .{ .provider = "openai", .model = "responses-runtime" },
        },
        .{},
        &opened,
        sources.view(),
        .none(),
    );
    errdefer runtime.deinit();
    try std.testing.expectEqual(@as(usize, 1), runtime.session().messages().len);
    try std.testing.expectEqualStrings(
        "before crash",
        runtime.session().messages()[0].request.parts[0].user.text,
    );

    var cancellation: ai_model.CancellationToken = .{};
    cancellation.cancel();
    try std.testing.expectError(
        error.Cancelled,
        runtime.session().promptWithControl("cancel this", .{ .cancellation = &cancellation }),
    );
    try std.testing.expect(runtime.session().state() == .ready);
    try std.testing.expectEqual(@as(usize, 0), fake.next_index);
    runtime.deinit();

    var restored = try SessionJournal.openReadOnly(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        "session.jsonl",
    );
    defer restored.deinit();
    const entries = restored.restore_candidate.entries;
    try std.testing.expectEqual(@as(usize, 5), entries.len);
    try std.testing.expect(entries[2].turn_end.outcome == .interrupted);
    try std.testing.expect(entries[3].message.message == .request);
    try std.testing.expect(entries[4].turn_end.outcome == .cancelled);
    try std.testing.expect(restored.restore_candidate.recovery == .clean);
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
    const credentials = [_]Credential{oauthCredential("openai-codex", "codex-secret", "account-runtime")};

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
    const empty_provider_id = [_]Credential{apiKeyCredential("", "key")};
    const empty_api_key = [_]Credential{apiKeyCredential("openai", "")};
    const unknown_provider = [_]Credential{apiKeyCredential("missing", "key")};
    const empty_access_token = [_]Credential{oauthCredential("openai-codex", "", null)};
    const empty_account_id = [_]Credential{oauthCredential("openai-codex", "token", "")};
    const duplicate_credentials = [_]Credential{
        apiKeyCredential("openai", "one"),
        apiKeyCredential("openai", "two"),
    };
    const openai_credential = [_]Credential{apiKeyCredential("openai", "key")};
    const no_auth_definitions = [_]ModelConfig.ProviderDefinition{.{
        .id = "runtime-openai",
        .name = "Runtime OpenAI",
        .base_url = "https://example.test/v1",
        .auth = .{ .allow_unauthenticated = true },
    }};
    const no_auth_config: ModelConfig = .{
        .catalog = test_catalog,
        .providers = &no_auth_definitions,
    };
    const unexpected_api_key = [_]Credential{apiKeyCredential("runtime-openai", "key")};
    const openai_only_definitions = [_]ModelConfig.ProviderDefinition{test_provider_definitions[1]};
    const openai_only_config: ModelConfig = .{
        .catalog = test_catalog,
        .providers = &openai_only_definitions,
    };
    const unexpected_codex = [_]Credential{oauthCredential("openai-codex", "token", null)};
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
        apiKeyCredential("runtime-openai", "runtime-secret"),
        apiKeyCredential("openai", "responses-secret"),
        oauthCredential("openai-codex", "codex-secret", "account-runtime"),
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

fn deleteAllocationJournal(dir: std.Io.Dir) !void {
    dir.deleteFile(std.testing.io, "allocation-session.jsonl") catch |failure| switch (failure) {
        error.FileNotFound => {},
        else => return failure,
    };
}

fn createDurableForAllocationFailure(
    allocator: std.mem.Allocator,
    cwd_dir: std.Io.Dir,
    cwd: []const u8,
) !void {
    try deleteAllocationJournal(cwd_dir);
    defer deleteAllocationJournal(cwd_dir) catch unreachable;
    var opened = try SessionJournal.create(
        allocator,
        std.testing.io,
        cwd_dir,
        "allocation-session.jsonl",
        .{
            .id = "allocation-session",
            .timestamp = "2026-08-19T10:30:00.000Z",
            .cwd = cwd,
        },
        .none(),
    );
    var sources: DurableSources = .{};
    const exchanges: [0]fake_api.Exchange = .{};
    var fake = fake_api.FakeTransport.init(&exchanges);
    const credentials = [_]Credential{apiKeyCredential("openai", "responses-secret")};
    var runtime = try createDurableWithTransport(
        allocator,
        std.testing.io,
        cwd_dir,
        fake.transport(),
        .{
            .model_config = test_model_config,
            .credentials = &credentials,
            .selection = .{ .provider = "openai", .model = "responses-runtime" },
        },
        .{},
        &opened,
        sources.view(),
        .none(),
    );
    runtime.deinit();
}

test "durable runtime binding settles every allocation failure" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_length = try temporary.dir.realPath(std.testing.io, &path_buffer);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        createDurableForAllocationFailure,
        .{ temporary.dir, path_buffer[0..path_length] },
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
        apiKeyCredential("openai", "wipe-openai-secret"),
        oauthCredential("openai-codex", "wipe-codex-secret", "wipe-account-runtime"),
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
    try std.testing.expectEqual(@as(usize, 4), sensitive.len);
    var offsets: [4]usize = undefined;
    var lengths: [4]usize = undefined;
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
    const credentials = [_]Credential{apiKeyCredential("openai", "runtime-secret")};
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
