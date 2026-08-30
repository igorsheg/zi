const std = @import("std");
const AnthropicMessages = @import("AnthropicMessages.zig").AnthropicMessages;
const CodexModule = @import("Codex.zig");
const Codex = CodexModule.Codex;
const Mock = @import("Mock.zig");
const OpenAiChat = @import("OpenAiChat.zig").OpenAiChat;
const ModelMeta = @import("ModelMeta.zig");
const OpenAiResponses = @import("OpenAiResponses.zig").OpenAiResponses;
const Provider = @import("Provider.zig");
const ProviderRegistry = @import("ProviderRegistry.zig");
const StreamEvent = @import("StreamEvent.zig").StreamEvent;
const Transport = @import("Transport.zig");

/// Stable storage which adapts a resolved provider for each request.
///
/// `resolved`, its borrowed configuration, and the transport implementation must
/// outlive this value and every provider handle returned by `provider`. Put an
/// Owner in its final location before calling `provider`; moving or copying it
/// afterwards invalidates those handles. The operation mutex serializes streams,
/// input-token updates, and plan replacement. Mutation from a transport or sink
/// callback is not allowed because those callbacks run inside the operation.
pub const Owner = struct {
    resolved: *const ProviderRegistry.Resolved,
    transport: Transport.Transport,
    next_input_tokens: u64,
    operation_mutex: std.Io.Mutex,
    /// Cross-request script position for the mock provider. Meaningless for
    /// every other plan; serialized by the operation mutex like the tokens.
    mock_state: Mock.State,

    pub fn init(
        resolved: *const ProviderRegistry.Resolved,
        transport: Transport.Transport,
        next_input_tokens: u64,
    ) Owner {
        return .{
            .resolved = resolved,
            .transport = transport,
            .next_input_tokens = next_input_tokens,
            .operation_mutex = .init,
            .mock_state = .{},
        };
    }

    /// Returns a borrowed erased handle tied to this Owner's current address.
    pub fn provider(self: *Owner) Provider.Provider {
        return Provider.Provider.from(self, self.resolved.metadata.provider_id);
    }

    pub fn setInputTokens(self: *Owner, io: std.Io, input_tokens: u64) void {
        self.operation_mutex.lockUncancelable(io);
        defer self.operation_mutex.unlock(io);
        self.next_input_tokens = input_tokens;
    }

    /// Locks the resolved plan for a transactional replacement. Callers must
    /// pair a successful call with `unlockPlan`.
    pub fn lockPlan(self: *Owner, io: std.Io) void {
        self.operation_mutex.lockUncancelable(io);
    }

    pub fn unlockPlan(self: *Owner, io: std.Io) void {
        self.operation_mutex.unlock(io);
    }

    pub fn stream(
        allocator: std.mem.Allocator,
        io: std.Io,
        self: *Owner,
        request: Provider.Request,
        sink: Provider.EventSink,
    ) Provider.StreamError!void {
        self.operation_mutex.lockUncancelable(io);
        defer self.operation_mutex.unlock(io);

        const plan = self.resolved.adapterForInput(self.next_input_tokens);
        var tracking_sink: TrackingSink = .{ .downstream = sink };
        const erased_sink = Provider.EventSink.from(&tracking_sink);

        switch (plan) {
            .codex => |config| {
                var adapter = Codex.init(self.transport, config);
                try Codex.stream(allocator, io, &adapter, request, erased_sink);
            },
            .openai_responses => |config| {
                var adapter = OpenAiResponses.init(self.transport, config);
                try OpenAiResponses.stream(allocator, io, &adapter, request, erased_sink);
            },
            .openai_chat => |config| {
                var adapter = OpenAiChat.init(self.transport, config);
                try OpenAiChat.stream(allocator, io, &adapter, request, erased_sink);
            },
            .anthropic_messages => |config| {
                var adapter = AnthropicMessages.init(self.transport, config);
                try AnthropicMessages.stream(allocator, io, &adapter, request, erased_sink);
            },
            .mock => |config| {
                var adapter = Mock.Mock.init(config, &self.mock_state);
                try Mock.Mock.stream(allocator, io, &adapter, request, erased_sink);
            },
        }

        // Commit only after the adapter completed successfully. A transport,
        // parser, cancellation, or downstream error must preserve the snapshot.
        if (tracking_sink.terminal_input_tokens) |input_tokens| {
            self.next_input_tokens = input_tokens;
        }
    }
};

const TrackingSink = struct {
    downstream: Provider.EventSink,
    terminal_input_tokens: ?u64 = null,

    pub fn emit(self: *TrackingSink, event: StreamEvent) Provider.DeliveryError!void {
        try self.downstream.emit(event);
        switch (event) {
            .done => |done| {
                self.terminal_input_tokens = done.usage.input_tokens;
            },
            .retry, .failure => self.terminal_input_tokens = null,
            else => {},
        }
    }
};

test "done usage selects the next request cache tier" {
    const FakeTransport = struct {
        const Self = @This();
        calls: usize = 0,
        first_had_marker: bool = false,
        second_had_marker: bool = false,
        request_valid: bool = true,

        pub fn ssePost(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            request: Transport.Request,
            sink: Transport.EventSink,
        ) Transport.StreamError!Transport.Result {
            self.calls += 1;
            const marker = std.mem.find(u8, request.json_body, "\"cache_control\":") != null;
            if (self.calls == 1) self.first_had_marker = marker else self.second_had_marker = marker;
            self.request_valid = self.request_valid and
                std.mem.eql(u8, request.url, "https://openrouter.ai/api/v1/chat/completions") and
                std.mem.find(u8, request.json_body, "\"model\":\"model\"") != null;
            var saw_auth = false;
            for (request.headers) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "authorization")) {
                    saw_auth = std.mem.eql(u8, header.value, "Bearer secret");
                }
            }
            self.request_valid = self.request_valid and saw_auth;
            try sink.emit(.{ .data = "{\"id\":\"response\",\"choices\":[{\"delta\":{}," ++
                "\"finish_reason\":\"stop\"}]}" });
            try sink.emit(.{ .data = "{\"usage\":{\"prompt_tokens\":101,\"completion_tokens\":1}," ++
                "\"choices\":[]}" });
            try sink.emit(.{ .data = "[DONE]" });
            return .{ .status = 200, .outcome = .completed };
        }
    };
    const Collector = struct {
        const Self = @This();
        done: usize = 0,
        pub fn emit(self: *Self, event: StreamEvent) Provider.DeliveryError!void {
            if (event == .done) self.done += 1;
        }
    };

    const tiers = try ModelMeta.Tiers.init(&.{.{
        .context_threshold = 100,
        .rates = .{ .input = 1, .cache_write = 1 },
    }});
    const metadata: ModelMeta.Metadata = .{ .tiers = tiers };
    var resolved = try ProviderRegistry.resolve(
        std.testing.allocator,
        "openrouter",
        "model",
        .{ .bearer = "secret" },
        .{ .session_cache_key = "session" },
        .{ .reported = &metadata },
        .{},
    );
    defer resolved.deinit();
    var fake: FakeTransport = .{};
    var owner = Owner.init(&resolved, Transport.Transport.from(&fake), 100);
    const erased = owner.provider();
    try std.testing.expectEqualStrings("openrouter", erased.id);
    var collector: Collector = .{};
    const request: Provider.Request = .{
        .model = "model",
        .context = .{ .system_prompt = "system", .items = &.{}, .tools = &.{} },
    };
    try erased.stream(std.testing.allocator, std.testing.io, request, Provider.EventSink.from(&collector));
    try erased.stream(std.testing.allocator, std.testing.io, request, Provider.EventSink.from(&collector));
    try std.testing.expect(!fake.first_had_marker);
    try std.testing.expect(fake.second_had_marker);
    try std.testing.expect(fake.request_valid);
    try std.testing.expectEqual(@as(usize, 2), collector.done);
}

test "retry and failure invalidate a delivered done usage candidate" {
    const Downstream = struct {
        const Self = @This();
        pub fn emit(_: *Self, _: StreamEvent) Provider.DeliveryError!void {}
    };
    var downstream: Downstream = .{};
    var tracking: TrackingSink = .{ .downstream = Provider.EventSink.from(&downstream) };
    try tracking.emit(.{ .done = .{ .usage = .{ .input_tokens = 999 } } });
    try std.testing.expectEqual(@as(?u64, 999), tracking.terminal_input_tokens);
    try tracking.emit(.{ .retry = .{
        .attempt = 1,
        .maximum_attempts = 2,
        .delay_ms = 0,
    } });
    try std.testing.expectEqual(@as(?u64, null), tracking.terminal_input_tokens);
    try tracking.emit(.{ .done = .{ .usage = .{ .input_tokens = 1000 } } });
    try tracking.emit(.{ .failure = .{ .message = "failed" } });
    try std.testing.expectEqual(@as(?u64, null), tracking.terminal_input_tokens);
}

test "delivery cancellation does not advance the tier snapshot" {
    const Downstream = struct {
        const Self = @This();
        pub fn emit(_: *Self, event: StreamEvent) Provider.DeliveryError!void {
            if (event == .done) return error.Cancelled;
        }
    };
    var downstream: Downstream = .{};
    var tracking: TrackingSink = .{ .downstream = Provider.EventSink.from(&downstream) };
    try std.testing.expectError(error.Cancelled, tracking.emit(.{
        .done = .{ .usage = .{ .input_tokens = 999 } },
    }));
    try std.testing.expectEqual(@as(?u64, null), tracking.terminal_input_tokens);
}

fn testResolved(
    endpoint: []u8,
    provider_id: []const u8,
    adapter: ProviderRegistry.AdapterPlan,
) ProviderRegistry.Resolved {
    return .{
        .allocator = std.testing.allocator,
        .endpoint = endpoint,
        .metadata = .{
            .provider_id = provider_id,
            .display_name = provider_id,
            .catalog_id = null,
            .model_id = "model",
            .wire = switch (adapter) {
                .codex, .openai_responses => .openai_responses,
                .openai_chat => .openai_chat,
                .anthropic_messages => .anthropic_messages,
                .mock => null,
            },
            .provider_efforts = .{},
            .efforts = .{},
            .model = .{},
            .send_cache_key = false,
        },
        .adapter = adapter,
        .cache_setting = .off,
    };
}

test "factory dispatches every resolved adapter plan with borrowed configuration" {
    const Source = struct {
        const Self = @This();
        pub fn acquire(
            _: *Self,
            allocator: std.mem.Allocator,
            _: std.Io,
            _: ?Provider.Tick,
            _: CodexModule.AcquirePurpose,
        ) CodexModule.CredentialSource.CallbackError!CodexModule.AcquireDecision {
            return .{ .ready = try CodexModule.OwnedCredential.init(allocator, .{
                .access_token = "codex-token",
                .account_id = "account",
            }) };
        }
        pub fn recoverUnauthorized(
            _: *Self,
            _: std.mem.Allocator,
            _: std.Io,
            _: ?Provider.Tick,
            _: CodexModule.Credential,
        ) CodexModule.CredentialSource.CallbackError!CodexModule.UnauthorizedDecision {
            return .use_response;
        }
        pub fn noteUnauthorized(_: *Self, _: CodexModule.Credential) void {}
    };
    const FakeTransport = struct {
        const Self = @This();
        calls: usize = 0,
        valid: bool = true,

        pub fn ssePost(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            request: Transport.Request,
            sink: Transport.EventSink,
        ) Transport.StreamError!Transport.Result {
            self.calls += 1;
            self.valid = self.valid and std.mem.find(u8, request.json_body, "\"model\":\"model\"") != null;
            if (std.mem.eql(u8, request.url, "https://factory.test/responses")) {
                self.valid = self.valid and hasHeader(request.headers, "Authorization", "Bearer responses-token");
                try completedResponses(sink);
            } else if (std.mem.eql(u8, request.url, "https://factory.test/chat/completions")) {
                self.valid = self.valid and hasHeader(request.headers, "Authorization", "Bearer chat-token");
                try completedChat(sink);
            } else if (std.mem.eql(u8, request.url, "https://factory.test/messages")) {
                self.valid = self.valid and hasHeader(request.headers, "x-api-key", "anthropic-token");
                try completedAnthropic(sink);
            } else if (std.mem.eql(u8, request.url, "https://chatgpt.com/backend-api/codex/responses")) {
                self.valid = self.valid and hasHeader(request.headers, "Authorization", "Bearer codex-token");
                self.valid = self.valid and hasHeader(request.headers, "chatgpt-account-id", "account");
                self.valid = self.valid and std.mem.find(u8, request.json_body, "\"prompt_cache_key\":") != null;
                try completedResponses(sink);
            } else self.valid = false;
            return .{ .status = 200, .outcome = .completed };
        }

        fn hasHeader(headers: []const Transport.Header, name: []const u8, value: []const u8) bool {
            for (headers) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, name) and
                    std.mem.eql(u8, header.value, value)) return true;
            }
            return false;
        }
        fn completedResponses(sink: Transport.EventSink) Provider.DeliveryError!void {
            try sink.emit(.{ .data = "{\"type\":\"response.completed\",\"response\":{" ++
                "\"id\":\"response\",\"model\":\"model\",\"usage\":{" ++
                "\"input_tokens\":2,\"output_tokens\":1}}}" });
        }
        fn completedChat(sink: Transport.EventSink) Provider.DeliveryError!void {
            try sink.emit(.{ .data = "{\"id\":\"response\",\"choices\":[{" ++
                "\"delta\":{},\"finish_reason\":\"stop\"}]}" });
            try sink.emit(.{ .data = "{\"usage\":{\"prompt_tokens\":2," ++
                "\"completion_tokens\":1},\"choices\":[]}" });
            try sink.emit(.{ .data = "[DONE]" });
        }
        fn completedAnthropic(sink: Transport.EventSink) Provider.DeliveryError!void {
            try sink.emit(.{ .data = "{\"type\":\"message_start\",\"message\":{" ++
                "\"id\":\"response\",\"model\":\"model\",\"usage\":{" ++
                "\"input_tokens\":2}}}" });
            try sink.emit(.{ .data = "{\"type\":\"message_delta\",\"delta\":{" ++
                "\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}" });
            try sink.emit(.{ .data = "{\"type\":\"message_stop\"}" });
        }
    };
    const Collector = struct {
        const Self = @This();
        done: usize = 0,
        pub fn emit(self: *Self, event: StreamEvent) Provider.DeliveryError!void {
            if (event == .done) self.done += 1;
        }
    };

    var source: Source = .{};
    var fake: FakeTransport = .{};
    const transport = Transport.Transport.from(&fake);
    var responses_endpoint = "https://factory.test/responses".*;
    var chat_endpoint = "https://factory.test/chat/completions".*;
    var anthropic_endpoint = "https://factory.test/messages".*;
    var codex_endpoint = "https://chatgpt.com/backend-api/codex/responses".*;
    var plans = [_]ProviderRegistry.Resolved{
        testResolved(&responses_endpoint, "responses", .{ .openai_responses = .{
            .provider_id = "responses",
            .endpoint = &responses_endpoint,
            .api_key = "responses-token",
        } }),
        testResolved(&chat_endpoint, "chat", .{ .openai_chat = .{
            .provider_id = "chat",
            .endpoint = &chat_endpoint,
            .api_key = "chat-token",
        } }),
        testResolved(&anthropic_endpoint, "anthropic", .{ .anthropic_messages = .{
            .provider_id = "anthropic",
            .endpoint = &anthropic_endpoint,
            .api_key = "anthropic-token",
        } }),
        testResolved(&codex_endpoint, "codex", .{ .codex = .{
            .source = CodexModule.CredentialSource.from(&source),
            .session_id = "12345678-1234-4234-8234-123456789abc",
        } }),
    };
    var collector: Collector = .{};
    const request: Provider.Request = .{
        .model = "model",
        .context = .{ .system_prompt = "system", .items = &.{}, .tools = &.{} },
    };
    for (&plans) |*plan| {
        var owner = Owner.init(plan, transport, 0);
        try owner.provider().stream(
            std.testing.allocator,
            std.testing.io,
            request,
            Provider.EventSink.from(&collector),
        );
    }
    try std.testing.expect(fake.valid);
    try std.testing.expectEqual(@as(usize, 4), fake.calls);
    try std.testing.expectEqual(@as(usize, 4), collector.done);
}
