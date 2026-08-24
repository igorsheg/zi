const std = @import("std");
const Body = @import("OpenAiChatBody.zig");
const Events = @import("OpenAiChatEvents.zig");
const Provider = @import("Provider.zig");
const StreamEvent = @import("StreamEvent.zig");
const StreamRetry = @import("StreamRetry.zig");
const Transport = @import("Transport.zig");
const Usage = @import("Usage.zig");

pub const default_maximum_api_key_bytes: usize = 8 * 1024;
pub const maximum_extra_headers: usize = 64;
pub const default_limits: Transport.Limits = .{
    .max_request_body_bytes = Body.default_maximum_body_bytes,
    .max_header_bytes = 16 * 1024,
    .max_sse_event_bytes = Events.maximum_event_bytes,
    .max_error_body_bytes = 4 * 1024,
    .header_buffer_bytes = 32 * 1024,
    .connect_timeout_ms = 10 * 1_000,
    .idle_timeout_ms = 10 * 60 * 1_000,
};

const ConfigData = struct {
    provider_id: []const u8,
    endpoint: []const u8,
    api_key: ?[]const u8 = null,
    extra_headers: []const Transport.Header = &.{},
    maximum_api_key_bytes: usize = default_maximum_api_key_bytes,
    body: Body.Options = .{},
    events: Events.Options = .{},
    limits: Transport.Limits = default_limits,
    retry: StreamRetry.Options = .{},
};

/// Generic OpenAI-compatible Chat Completions adapter. Recipe/registry owners
/// resolve dialect options and inject this borrowed configuration.
pub const OpenAiChat = struct {
    pub const Config = ConfigData;
    pub const ReasoningFormat = Body.ReasoningFormat;

    transport: Transport.Transport,
    config: Config,

    pub fn init(transport: Transport.Transport, config: Config) OpenAiChat {
        return .{ .transport = transport, .config = config };
    }

    pub fn provider(self: *OpenAiChat) Provider.Provider {
        return Provider.Provider.from(self, self.config.provider_id);
    }

    pub fn stream(
        allocator: std.mem.Allocator,
        io: std.Io,
        self: *OpenAiChat,
        request: Provider.Request,
        sink: Provider.EventSink,
    ) Provider.StreamError!void {
        try validateConfig(self.config);
        var body_options = self.config.body;
        body_options.provider_id = self.config.provider_id;
        body_options.maximum_body_bytes = @min(
            body_options.maximum_body_bytes,
            self.config.limits.max_request_body_bytes,
        );
        const body = Body.build(allocator, request, body_options) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidRequest, error.BodyTooLarge => return error.InvalidRequest,
        };
        defer allocator.free(body);

        var factory: AttemptFactory = .{
            .api_key = self.config.api_key,
            .extra_headers = self.config.extra_headers,
            .event_options = self.config.events,
        };
        return StreamRetry.run(
            allocator,
            io,
            self.transport,
            StreamRetry.Factory.from(&factory),
            .{
                .url = self.config.endpoint,
                .json_body = body,
                .tick = request.tick,
                .limits = self.config.limits,
            },
            sink,
            self.config.retry,
        );
    }
};

fn validateConfig(config: ConfigData) error{InvalidRequest}!void {
    if (config.provider_id.len == 0 or !std.unicode.utf8ValidateSlice(config.provider_id) or
        !validEndpoint(config.endpoint) or config.maximum_api_key_bytes == 0 or
        config.maximum_api_key_bytes > default_maximum_api_key_bytes)
    {
        return error.InvalidRequest;
    }
    if (config.api_key) |api_key| {
        if (api_key.len == 0 or api_key.len > config.maximum_api_key_bytes or !headerValueSafe(api_key)) {
            return error.InvalidRequest;
        }
    }
    if (config.limits.max_request_body_bytes == 0 or
        config.limits.max_request_body_bytes > Body.default_maximum_body_bytes or
        config.limits.max_sse_event_bytes == 0 or
        config.limits.max_sse_event_bytes > Events.maximum_event_bytes or
        config.limits.max_error_body_bytes == 0 or config.limits.max_error_body_bytes > 4 * 1024)
    {
        return error.InvalidRequest;
    }
    if (config.events.max_tracked_calls == 0 or
        config.events.max_tracked_calls > Events.maximum_tracked_calls or
        config.events.max_owned_state_bytes == 0 or
        config.events.max_owned_state_bytes > Events.maximum_owned_state_bytes or
        config.events.max_event_bytes == 0 or
        config.events.max_event_bytes > Events.maximum_event_bytes or
        config.events.emit_progress != config.body.emit_progress)
    {
        return error.InvalidRequest;
    }
    if (config.events.cache_write_1h !=
        (config.body.cache_markers and std.mem.eql(u8, config.body.cache_ttl, "1h")))
    {
        return error.InvalidRequest;
    }
    if (config.extra_headers.len > maximum_extra_headers) return error.InvalidRequest;
    var header_bytes: usize = "Accept".len + "text/event-stream".len +
        "Content-Type".len + "application/json".len;
    if (config.api_key) |api_key| {
        header_bytes = std.math.add(
            usize,
            header_bytes,
            "Authorization".len + "Bearer ".len + api_key.len,
        ) catch return error.InvalidRequest;
    }
    if (header_bytes > config.limits.max_header_bytes) return error.InvalidRequest;
    for (config.extra_headers, 0..) |header, index| {
        if (!validHeaderName(header.name) or !headerValueSafe(header.value) or
            standardHeader(header.name)) return error.InvalidRequest;
        header_bytes = std.math.add(usize, header_bytes, header.name.len) catch
            return error.InvalidRequest;
        header_bytes = std.math.add(usize, header_bytes, header.value.len) catch
            return error.InvalidRequest;
        if (header_bytes > config.limits.max_header_bytes) return error.InvalidRequest;
        for (config.extra_headers[index + 1 ..]) |other| {
            if (std.ascii.eqlIgnoreCase(header.name, other.name)) return error.InvalidRequest;
        }
    }
}

fn validEndpoint(value: []const u8) bool {
    const authority_start: usize = if (std.mem.startsWith(u8, value, "https://"))
        "https://".len
    else if (std.mem.startsWith(u8, value, "http://"))
        "http://".len
    else
        return false;
    if (value.len == authority_start or value[authority_start] == '/' or
        value[authority_start] == '?' or value[authority_start] == '#') return false;
    for (value) |byte| if (byte <= 0x20 or byte == 0x7f) return false;
    return true;
}

fn standardHeader(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "authorization") or
        std.ascii.eqlIgnoreCase(name, "accept") or
        std.ascii.eqlIgnoreCase(name, "content-type");
}

fn validHeaderName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or switch (byte) {
            '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
            else => false,
        })) return false;
    }
    return true;
}

fn headerValueSafe(value: []const u8) bool {
    for (value) |byte| {
        if ((byte < 0x20 and byte != '\t') or byte == 0x7f) return false;
    }
    return true;
}

const AttemptFactory = struct {
    api_key: ?[]const u8,
    extra_headers: []const Transport.Header,
    event_options: Events.Options,

    pub fn create(
        self: *AttemptFactory,
        allocator: std.mem.Allocator,
        _: u16,
        sink: Provider.EventSink,
    ) StreamRetry.BuildError!StreamRetry.Attempt {
        const state = try allocator.create(AttemptState);
        errdefer allocator.destroy(state);
        const authorization = if (self.api_key) |api_key|
            try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key})
        else
            null;
        errdefer if (authorization) |value| allocator.free(value);
        const header_count = 2 + self.extra_headers.len + @as(usize, @intFromBool(authorization != null));
        const headers = try allocator.alloc(Transport.Header, header_count);
        errdefer allocator.free(headers);
        var next: usize = 0;
        if (authorization) |value| {
            headers[next] = .{ .name = "Authorization", .value = value, .privileged = true };
            next += 1;
        }
        headers[next] = .{ .name = "Accept", .value = "text/event-stream" };
        next += 1;
        headers[next] = .{ .name = "Content-Type", .value = "application/json" };
        next += 1;
        for (self.extra_headers) |header| {
            headers[next] = header;
            next += 1;
        }
        const parser = Events.Parser.init(allocator, sink, self.event_options) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidResponse => return error.InvalidRequest,
            error.Cancelled => unreachable,
        };
        state.* = .{ .parser = parser, .authorization = authorization, .headers = headers };
        return .{ .context = state, .vtable = &AttemptState.vtable };
    }
};

const AttemptState = struct {
    parser: Events.Parser,
    authorization: ?[]u8,
    headers: []Transport.Header,

    fn getHeaders(context: *anyopaque) []const Transport.Header {
        const self: *AttemptState = @ptrCast(@alignCast(context));
        return self.headers;
    }
    fn feed(context: *anyopaque, event: Transport.SseEvent) StreamRetry.ParseError!void {
        const self: *AttemptState = @ptrCast(@alignCast(context));
        return mapParserError(self.parser.feed(event));
    }
    fn finalize(context: *anyopaque) StreamRetry.ParseError!void {
        const self: *AttemptState = @ptrCast(@alignCast(context));
        return mapParserError(self.parser.finalize());
    }
    fn deinit(allocator: std.mem.Allocator, context: *anyopaque) void {
        const self: *AttemptState = @ptrCast(@alignCast(context));
        self.parser.deinit();
        allocator.free(self.headers);
        if (self.authorization) |value| allocator.free(value);
        allocator.destroy(self);
    }
    fn isComplete(context: *const anyopaque) bool {
        const self: *const AttemptState = @ptrCast(@alignCast(context));
        return self.parser.isComplete();
    }
    fn usage(context: *const anyopaque) ?Usage.StreamUsage {
        const self: *const AttemptState = @ptrCast(@alignCast(context));
        return self.parser.usage();
    }
    fn recoverIncomplete(context: *anyopaque) StreamRetry.ParseError!bool {
        const self: *AttemptState = @ptrCast(@alignCast(context));
        return self.parser.recover() catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Cancelled => error.Cancelled,
            error.InvalidResponse => error.InvalidResponse,
        };
    }
    fn failure(_: *const anyopaque) ?StreamRetry.Attempt.Failure {
        return null;
    }

    const vtable: StreamRetry.Attempt.VTable = .{
        .headers = getHeaders,
        .feed = feed,
        .finalize = finalize,
        .deinit = deinit,
        .is_complete = isComplete,
        .usage = usage,
        .recover_incomplete = recoverIncomplete,
        .failure = failure,
    };
};

fn mapParserError(result: Events.Error!void) StreamRetry.ParseError!void {
    return result catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Cancelled => error.Cancelled,
        error.InvalidResponse => error.InvalidResponse,
    };
}

const TestTransport = struct {
    calls: usize = 0,
    valid: bool = true,
    incomplete_once: bool = false,

    pub fn ssePost(
        _: std.mem.Allocator,
        _: std.Io,
        self: *TestTransport,
        request: Transport.Request,
        sink: Transport.EventSink,
    ) Transport.StreamError!Transport.Result {
        self.calls += 1;
        self.valid = self.valid and std.mem.eql(u8, request.url, "https://chat.test/v1/chat/completions");
        self.valid = self.valid and request.headers.len == 4;
        self.valid = self.valid and request.headers[0].isPrivileged();
        self.valid = self.valid and std.mem.eql(u8, request.headers[0].value, "Bearer secret");
        self.valid = self.valid and std.mem.eql(u8, request.headers[3].name, "X-Title");
        self.valid = self.valid and std.mem.find(u8, request.json_body, "\"stream_options\":") != null;
        if (self.incomplete_once and self.calls == 1) {
            try sink.emit(.{
                .data = "{\"id\":\"old\",\"model\":\"old\",\"usage\":{" ++
                    "\"prompt_tokens\":4},\"choices\":[{\"delta\":{" ++
                    "\"content\":\"partial\"},\"finish_reason\":null}]}",
            });
            return .{ .status = 200, .outcome = .completed };
        }
        try sink.emit(.{
            .data = "{\"id\":\"new\",\"model\":\"served\",\"provider\":\"route\"," ++
                "\"choices\":[{\"delta\":{\"content\":\"ok\"}," ++
                "\"finish_reason\":\"stop\"}]}",
        });
        try sink.emit(.{
            .data = "{\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":3},\"choices\":[]}",
        });
        try sink.emit(.{ .data = "[DONE]" });
        return .{ .status = 200, .outcome = .completed };
    }
};

const TestCollector = struct {
    retries: usize = 0,
    done: usize = 0,
    response_ok: bool = false,
    retry_usage: ?Usage.StreamUsage = null,

    pub fn emit(self: *TestCollector, event: StreamEvent.StreamEvent) Provider.DeliveryError!void {
        switch (event) {
            .retry => |retry| {
                self.retries += 1;
                self.retry_usage = retry.usage;
            },
            .done => |done| {
                self.done += 1;
                self.response_ok = done.response.id != null and
                    std.mem.eql(u8, done.response.id.?, "new") and
                    done.response.route != null and
                    std.mem.eql(u8, done.response.route.?, "route") and
                    done.usage.input_tokens == 2 and done.usage.output_tokens == 3;
            },
            else => {},
        }
    }
};

fn testConfig() OpenAiChat.Config {
    return .{
        .provider_id = "compatible",
        .endpoint = "https://chat.test/v1/chat/completions",
        .api_key = "secret",
        .extra_headers = &.{.{ .name = "X-Title", .value = "Zi" }},
        .retry = .{ .policy = .{ .max_attempts = 2, .base_delay_ms = 0 } },
    };
}

test "generic Chat adapter retries incomplete streams with fresh parser state" {
    var fake: TestTransport = .{ .incomplete_once = true };
    var adapter = OpenAiChat.init(Transport.Transport.from(&fake), testConfig());
    try std.testing.expectEqualStrings("compatible", adapter.provider().id);
    var collector: TestCollector = .{};
    try adapter.provider().stream(std.testing.allocator, std.testing.io, .{
        .model = "model",
        .context = .{ .system_prompt = "system", .items = &.{}, .tools = &.{} },
    }, Provider.EventSink.from(&collector));
    try std.testing.expect(fake.valid);
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    try std.testing.expectEqual(@as(usize, 1), collector.retries);
    try std.testing.expectEqual(@as(?u64, 4), collector.retry_usage.?.input_tokens);
    try std.testing.expectEqual(@as(usize, 1), collector.done);
    try std.testing.expect(collector.response_ok);
}

test "Chat config rejects credential injection and owned-header replacement" {
    var fake: TestTransport = .{};
    var config = testConfig();
    config.api_key = "bad\nkey";
    var adapter = OpenAiChat.init(Transport.Transport.from(&fake), config);
    var collector: TestCollector = .{};
    const request: Provider.Request = .{
        .model = "model",
        .context = .{ .system_prompt = "", .items = &.{}, .tools = &.{} },
    };
    try std.testing.expectError(error.InvalidRequest, adapter.provider().stream(
        std.testing.allocator,
        std.testing.io,
        request,
        Provider.EventSink.from(&collector),
    ));
    config.api_key = null;
    config.extra_headers = &.{.{ .name = "Content-Type", .value = "text/plain" }};
    adapter = OpenAiChat.init(Transport.Transport.from(&fake), config);
    try std.testing.expectError(error.InvalidRequest, adapter.provider().stream(
        std.testing.allocator,
        std.testing.io,
        request,
        Provider.EventSink.from(&collector),
    ));
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

fn exerciseChatAdapterAllocations(allocator: std.mem.Allocator) !void {
    var fake: TestTransport = .{};
    var adapter = OpenAiChat.init(Transport.Transport.from(&fake), testConfig());
    var collector: TestCollector = .{};
    try adapter.provider().stream(allocator, std.testing.io, .{
        .model = "model",
        .context = .{ .system_prompt = "system", .items = &.{}, .tools = &.{} },
    }, Provider.EventSink.from(&collector));
}

test "Chat attempt construction releases every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseChatAdapterAllocations,
        .{},
    );
}

test "complete header budget is validated at the exact boundary" {
    var fake: TestTransport = .{};
    var config = testConfig();
    const exact = "Authorization".len + "Bearer ".len + "secret".len +
        "Accept".len + "text/event-stream".len +
        "Content-Type".len + "application/json".len +
        "X-Title".len + "Zi".len;
    config.limits.max_header_bytes = exact;
    var adapter = OpenAiChat.init(Transport.Transport.from(&fake), config);
    var collector: TestCollector = .{};
    const request: Provider.Request = .{
        .model = "model",
        .context = .{ .system_prompt = "", .items = &.{}, .tools = &.{} },
    };
    try adapter.provider().stream(
        std.testing.allocator,
        std.testing.io,
        request,
        Provider.EventSink.from(&collector),
    );
    try std.testing.expectEqual(@as(usize, 1), fake.calls);

    config.limits.max_header_bytes = exact - 1;
    adapter = OpenAiChat.init(Transport.Transport.from(&fake), config);
    try std.testing.expectError(error.InvalidRequest, adapter.provider().stream(
        std.testing.allocator,
        std.testing.io,
        request,
        Provider.EventSink.from(&collector),
    ));
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
}
