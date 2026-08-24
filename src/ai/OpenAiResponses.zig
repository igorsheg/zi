const std = @import("std");
const Body = @import("OpenAiResponsesBody.zig");
const Events = @import("OpenAiResponsesEvents.zig");
const Item = @import("Item.zig");
const Provider = @import("Provider.zig");
const StreamEvent = @import("StreamEvent.zig");
const StreamRetry = @import("StreamRetry.zig");
const Transport = @import("Transport.zig");
const Usage = @import("Usage.zig");

pub const default_provider_id = "openai";
pub const default_endpoint = "https://api.openai.com/v1/responses";
pub const provider_id = default_provider_id;
pub const endpoint = default_endpoint;
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
    provider_id: []const u8 = default_provider_id,
    endpoint: []const u8 = default_endpoint,
    api_key: ?[]const u8 = null,
    extra_headers: []const Transport.Header = &.{},
    session_cache_key: ?[]const u8 = null,
    maximum_api_key_bytes: usize = default_maximum_api_key_bytes,
    limits: Transport.Limits = default_limits,
    retry: StreamRetry.Options = .{},
    events: Events.Options = .{},
};

/// Generic OpenAI-compatible Responses adapter. Configuration is borrowed and
/// must outlive every erased provider handle and synchronous stream call.
pub const OpenAiResponses = struct {
    pub const Config = ConfigData;

    transport: Transport.Transport,
    config: Config,

    pub fn init(transport: Transport.Transport, config: Config) OpenAiResponses {
        return .{ .transport = transport, .config = config };
    }

    pub fn provider(self: *OpenAiResponses) Provider.Provider {
        return Provider.Provider.from(self, self.config.provider_id);
    }

    pub fn stream(
        allocator: std.mem.Allocator,
        io: std.Io,
        self: *OpenAiResponses,
        request: Provider.Request,
        sink: Provider.EventSink,
    ) Provider.StreamError!void {
        try validateConfig(self.config);
        if (!validEffort(request.context.effort)) return error.InvalidRequest;
        const body_limit = @min(
            self.config.limits.max_request_body_bytes,
            Body.default_maximum_body_bytes,
        );
        const body = Body.build(allocator, request, .{
            .provider_id = self.config.provider_id,
            .prompt_cache_key = self.config.session_cache_key,
            .maximum_body_bytes = body_limit,
        }) catch |err| switch (err) {
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
        if (api_key.len == 0 or api_key.len > config.maximum_api_key_bytes or
            !headerValueSafe(api_key)) return error.InvalidRequest;
    }
    if (config.session_cache_key) |cache_key| {
        if (cache_key.len == 0 or cache_key.len > config.limits.max_request_body_bytes) {
            return error.InvalidRequest;
        }
    }
    if (config.limits.max_request_body_bytes == 0 or
        config.limits.max_request_body_bytes > Body.default_maximum_body_bytes or
        config.limits.max_sse_event_bytes == 0 or
        config.limits.max_sse_event_bytes > Events.maximum_event_bytes or
        config.limits.max_error_body_bytes == 0 or
        config.limits.max_error_body_bytes > 4 * 1024)
    {
        return error.InvalidRequest;
    }
    if (config.events.max_tracked_calls == 0 or
        config.events.max_tracked_calls > Events.maximum_tracked_calls or
        config.events.max_owned_state_bytes == 0 or
        config.events.max_owned_state_bytes > Events.maximum_owned_state_bytes or
        config.events.max_event_bytes == 0 or
        config.events.max_event_bytes > Events.maximum_event_bytes)
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
            fixedHeader(header.name)) return error.InvalidRequest;
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
    for (value) |byte| if (byte <= 0x20 or byte == 0x7f) return false;
    if (std.mem.findAny(u8, value, "?#") != null) return false;
    const tail = value[authority_start..];
    const authority_end = std.mem.findScalar(u8, tail, '/') orelse tail.len;
    const authority = tail[0..authority_end];
    if (authority.len == 0 or std.mem.findScalar(u8, authority, '@') != null) return false;

    var host: []const u8 = authority;
    var port: ?[]const u8 = null;
    if (authority[0] == '[') {
        const close = std.mem.findScalar(u8, authority, ']') orelse return false;
        if (close == 1) return false;
        host = authority[1..close];
        const rest = authority[close + 1 ..];
        if (rest.len != 0) {
            if (rest[0] != ':') return false;
            port = rest[1..];
        }
        for (host) |byte| if (!(std.ascii.isHex(byte) or byte == ':' or byte == '.')) return false;
    } else {
        if (std.mem.findScalar(u8, authority, ':')) |colon| {
            if (std.mem.findScalarPos(u8, authority, colon + 1, ':') != null) return false;
            host = authority[0..colon];
            port = authority[colon + 1 ..];
        }
        if (host.len == 0 or host[0] == '.' or host[host.len - 1] == '.' or
            host[0] == '-' or host[host.len - 1] == '-') return false;
        for (host) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '-')) return false;
    }
    if (port) |digits| {
        if (digits.len == 0) return false;
        const number = std.fmt.parseUnsigned(u16, digits, 10) catch return false;
        if (number == 0) return false;
    }
    return true;
}

fn fixedHeader(name: []const u8) bool {
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

fn validEffort(effort: ?[]const u8) bool {
    const value = effort orelse return true;
    if (value.len == 0) return true;
    inline for (.{ "none", "minimal", "low", "medium", "high", "xhigh", "max" }) |accepted| {
        if (std.mem.eql(u8, value, accepted)) return true;
    }
    return false;
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
        return self.parser.feed(event) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Cancelled => error.Cancelled,
            error.InvalidResponse => error.InvalidResponse,
        };
    }

    fn finalize(context: *anyopaque) StreamRetry.ParseError!void {
        const self: *AttemptState = @ptrCast(@alignCast(context));
        return self.parser.finalize() catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Cancelled => error.Cancelled,
            error.InvalidResponse => error.InvalidResponse,
        };
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

const TestTransport = struct {
    calls: usize = 0,
    request_valid: bool = true,
    retry_once: bool = false,
    expect_cache_key: bool = true,
    incomplete_once: bool = false,

    pub fn ssePost(
        allocator: std.mem.Allocator,
        _: std.Io,
        self: *TestTransport,
        request: Transport.Request,
        sink: Transport.EventSink,
    ) Transport.StreamError!Transport.Result {
        self.calls += 1;
        self.request_valid = self.request_valid and std.mem.eql(u8, request.url, endpoint);
        self.request_valid = self.request_valid and request.headers.len == 3;
        self.request_valid = self.request_valid and request.headers[0].isPrivileged();
        self.request_valid = self.request_valid and
            std.mem.eql(u8, request.headers[0].value, "Bearer secret");
        const has_cache_key = std.mem.find(
            u8,
            request.json_body,
            "\"prompt_cache_key\":\"cache\"",
        ) != null;
        self.request_valid = self.request_valid and has_cache_key == self.expect_cache_key;
        if (self.incomplete_once and self.calls == 1) {
            try sink.emit(.{
                .data = "{\"type\":\"response.created\",\"response\":{" ++
                    "\"id\":\"old\",\"model\":\"old-model\"}}",
            });
            return .{ .status = 200, .outcome = .completed };
        }
        if (self.retry_once and self.calls == 1) {
            return .{
                .status = 503,
                .outcome = .failed,
                .error_body = try allocator.dupe(u8, "temporary"),
            };
        }
        try sink.emit(.{
            .data = "{\"type\":\"response.completed\",\"response\":{" ++
                "\"id\":\"resp\",\"model\":\"gpt-5\",\"usage\":{" ++
                "\"input_tokens\":2,\"output_tokens\":3}}}",
        });
        return .{ .status = 200, .outcome = .completed };
    }
};

const TestCollector = struct {
    retries: usize = 0,
    done: usize = 0,
    input_tokens: ?u64 = null,
    response_id_ok: bool = false,

    pub fn emit(self: *TestCollector, event: StreamEvent.StreamEvent) Provider.DeliveryError!void {
        switch (event) {
            .retry => self.retries += 1,
            .done => |done| {
                self.done += 1;
                self.input_tokens = done.usage.input_tokens;
                self.response_id_ok = if (done.response.id) |id|
                    std.mem.eql(u8, id, "resp")
                else
                    false;
            },
            else => {},
        }
    }
};

const CompatibleTransport = struct {
    valid: bool = true,

    pub fn ssePost(
        _: std.mem.Allocator,
        _: std.Io,
        self: *CompatibleTransport,
        request: Transport.Request,
        sink: Transport.EventSink,
    ) Transport.StreamError!Transport.Result {
        self.valid = self.valid and std.mem.eql(u8, request.url, "http://localhost:8080/v1/responses");
        self.valid = self.valid and request.headers.len == 3;
        for (request.headers) |header| self.valid = self.valid and !header.isPrivileged();
        self.valid = self.valid and std.mem.eql(u8, request.headers[2].name, "X-Route");
        self.valid = self.valid and std.mem.eql(u8, request.headers[2].value, "local");
        self.valid = self.valid and std.mem.find(u8, request.json_body, "encrypted_content\":\"abc") != null;
        try sink.emit(.{
            .data = "{\"type\":\"response.completed\",\"response\":{" ++
                "\"id\":\"resp\",\"model\":\"gpt-5\",\"usage\":{" ++
                "\"input_tokens\":2,\"output_tokens\":3}}}",
        });
        return .{ .status = 200, .outcome = .completed };
    }
};

test "compatible adapter uses configured provenance endpoint and extra headers without auth" {
    const extra_headers = [_]Transport.Header{.{ .name = "X-Route", .value = "local" }};
    var fake: CompatibleTransport = .{};
    var adapter = OpenAiResponses.init(Transport.Transport.from(&fake), .{
        .provider_id = "compatible",
        .endpoint = "http://localhost:8080/v1/responses",
        .extra_headers = &extra_headers,
    });
    try std.testing.expectEqualStrings("compatible", adapter.provider().id);
    const items = [_]Item.Item{.{ .reasoning = .{
        .opaque_json = @constCast("{\"type\":\"reasoning\",\"summary\":[]," ++
            "\"encrypted_content\":\"abc\"}"),
        .source = .{ .provider = "compatible", .model = "gpt-5" },
    } }};
    var collector: TestCollector = .{};
    try adapter.provider().stream(std.testing.allocator, std.testing.io, .{
        .model = "gpt-5",
        .context = .{ .system_prompt = "system", .items = &items, .tools = &.{} },
    }, Provider.EventSink.from(&collector));
    try std.testing.expect(fake.valid);
    try std.testing.expectEqual(@as(usize, 1), collector.done);
}

test "adapter rejects malformed endpoints and injected or conflicting extra headers" {
    const malformed = [_][]const u8{
        "api.test/v1/responses",
        "https:///v1/responses",
        "https://user@api.test/v1/responses",
        "https://api.test/v1/responses?x=1",
        "https://api.test:0/v1/responses",
    };
    var fake: TestTransport = .{};
    var collector: TestCollector = .{};
    for (malformed) |bad_endpoint| {
        var adapter = OpenAiResponses.init(Transport.Transport.from(&fake), .{ .endpoint = bad_endpoint });
        try std.testing.expectError(error.InvalidRequest, adapter.provider().stream(
            std.testing.allocator,
            std.testing.io,
            .{
                .model = "gpt-5",
                .context = .{ .system_prompt = "system", .items = &.{}, .tools = &.{} },
            },
            Provider.EventSink.from(&collector),
        ));
    }

    const injected = [_]Transport.Header{.{ .name = "X-Test", .value = "bad\nvalue" }};
    var adapter = OpenAiResponses.init(Transport.Transport.from(&fake), .{ .extra_headers = &injected });
    try std.testing.expectError(error.InvalidRequest, adapter.provider().stream(
        std.testing.allocator,
        std.testing.io,
        .{
            .model = "gpt-5",
            .context = .{ .system_prompt = "system", .items = &.{}, .tools = &.{} },
        },
        Provider.EventSink.from(&collector),
    ));

    const conflicting = [_]Transport.Header{.{ .name = "authorization", .value = "other" }};
    adapter.config.extra_headers = &conflicting;
    try std.testing.expectError(error.InvalidRequest, adapter.provider().stream(
        std.testing.allocator,
        std.testing.io,
        .{
            .model = "gpt-5",
            .context = .{ .system_prompt = "system", .items = &.{}, .tools = &.{} },
        },
        Provider.EventSink.from(&collector),
    ));
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

test "first-party adapter owns body headers retry and parser lifecycle" {
    var fake: TestTransport = .{ .retry_once = true };
    var adapter = OpenAiResponses.init(Transport.Transport.from(&fake), .{
        .api_key = "secret",
        .session_cache_key = "cache",
        .retry = .{ .policy = .{ .max_attempts = 2, .base_delay_ms = 0 } },
    });
    var collector: TestCollector = .{};
    try adapter.provider().stream(std.testing.allocator, std.testing.io, .{
        .model = "gpt-5",
        .context = .{ .system_prompt = "system", .items = &.{}, .tools = &.{} },
    }, Provider.EventSink.from(&collector));
    try std.testing.expect(fake.request_valid);
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    try std.testing.expectEqual(@as(usize, 1), collector.retries);
    try std.testing.expectEqual(@as(usize, 1), collector.done);
    try std.testing.expectEqual(@as(?u64, 2), collector.input_tokens);
    try std.testing.expect(collector.response_id_ok);
}

test "adapter rejects invalid injected credentials before transport" {
    var fake: TestTransport = .{};
    var adapter = OpenAiResponses.init(Transport.Transport.from(&fake), .{
        .api_key = "bad\nkey",
        .session_cache_key = "cache",
    });
    var collector: TestCollector = .{};
    try std.testing.expectError(error.InvalidRequest, adapter.provider().stream(
        std.testing.allocator,
        std.testing.io,
        .{
            .model = "gpt-5",
            .context = .{ .system_prompt = "system", .items = &.{}, .tools = &.{} },
        },
        Provider.EventSink.from(&collector),
    ));
    try std.testing.expectEqual(@as(usize, 0), fake.calls);

    adapter.config.api_key = "secret";
    try std.testing.expectError(error.InvalidRequest, adapter.provider().stream(
        std.testing.allocator,
        std.testing.io,
        .{
            .model = "gpt-5",
            .context = .{
                .system_prompt = "system",
                .items = &.{},
                .tools = &.{},
                .effort = "extreme",
            },
        },
        Provider.EventSink.from(&collector),
    ));
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

test "first-party cache key can be disabled" {
    var fake: TestTransport = .{ .expect_cache_key = false };
    var adapter = OpenAiResponses.init(Transport.Transport.from(&fake), .{
        .api_key = "secret",
        .session_cache_key = null,
    });
    var collector: TestCollector = .{};
    try adapter.provider().stream(std.testing.allocator, std.testing.io, .{
        .model = "gpt-5",
        .context = .{ .system_prompt = "system", .items = &.{}, .tools = &.{} },
    }, Provider.EventSink.from(&collector));
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expect(fake.request_valid);
    try std.testing.expectEqual(@as(usize, 1), collector.done);
}

test "incomplete success retries with fresh OpenAI parser identity" {
    var fake: TestTransport = .{ .incomplete_once = true };
    var adapter = OpenAiResponses.init(Transport.Transport.from(&fake), .{
        .api_key = "secret",
        .session_cache_key = "cache",
        .retry = .{ .policy = .{ .max_attempts = 2, .base_delay_ms = 0 } },
    });
    var collector: TestCollector = .{};
    try adapter.provider().stream(std.testing.allocator, std.testing.io, .{
        .model = "gpt-5",
        .context = .{ .system_prompt = "system", .items = &.{}, .tools = &.{} },
    }, Provider.EventSink.from(&collector));
    try std.testing.expect(fake.request_valid);
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    try std.testing.expectEqual(@as(usize, 1), collector.retries);
    try std.testing.expectEqual(@as(usize, 1), collector.done);
    try std.testing.expect(collector.response_id_ok);
}

fn exerciseAdapterAllocations(allocator: std.mem.Allocator) !void {
    var fake: TestTransport = .{};
    var adapter = OpenAiResponses.init(Transport.Transport.from(&fake), .{
        .api_key = "secret",
        .session_cache_key = "cache",
    });
    var collector: TestCollector = .{};
    try adapter.provider().stream(allocator, std.testing.io, .{
        .model = "gpt-5",
        .context = .{ .system_prompt = "system", .items = &.{}, .tools = &.{} },
    }, Provider.EventSink.from(&collector));
}

test "adapter attempt factory releases every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAdapterAllocations,
        .{},
    );
}

test "terminal sink cancellation propagates and releases attempt state" {
    const Cancel = struct {
        const Self = @This();
        pub fn emit(_: *Self, event: StreamEvent.StreamEvent) Provider.DeliveryError!void {
            if (event == .done) return error.Cancelled;
        }
    };
    var fake: TestTransport = .{};
    var adapter = OpenAiResponses.init(Transport.Transport.from(&fake), .{
        .api_key = "secret",
        .session_cache_key = "cache",
    });
    var cancel: Cancel = .{};
    try std.testing.expectError(error.Cancelled, adapter.provider().stream(
        std.testing.allocator,
        std.testing.io,
        .{
            .model = "gpt-5",
            .context = .{ .system_prompt = "system", .items = &.{}, .tools = &.{} },
        },
        Provider.EventSink.from(&cancel),
    ));
}
