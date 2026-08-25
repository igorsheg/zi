const std = @import("std");
const SecureAllocator = @import("SecureAllocator.zig");
const ApiError = @import("ApiError.zig");
const Body = @import("OpenAiResponsesBody.zig");
const Events = @import("OpenAiResponsesEvents.zig");
const Provider = @import("Provider.zig");
const StreamEvent = @import("StreamEvent.zig");
const StreamRetry = @import("StreamRetry.zig");
const Transport = @import("Transport.zig");
const Usage = @import("Usage.zig");

pub const provider_id = "codex";
pub const stable_id = provider_id;
pub const default_provider_id = provider_id;
pub const endpoint = "https://chatgpt.com/backend-api/codex/responses";
pub const responses_endpoint = endpoint;
pub const default_endpoint = endpoint;
pub const usage_endpoint = "https://chatgpt.com/backend-api/wham/usage";
pub const models_endpoint = "https://chatgpt.com/backend-api/codex/models";
pub const originator = "codex_cli_rs";
pub const default_user_agent = "codex_cli_rs/0.144.1 zi/0.1.0-dev";
pub const default_maximum_access_token_bytes: usize = 8 * 1024;
pub const default_maximum_account_id_bytes: usize = 1024;
pub const maximum_extra_headers: usize = 64;
pub const maximum_header_bytes: usize = 64 * 1024;
pub const maximum_header_buffer_bytes: usize = 128 * 1024;
pub const maximum_timeout_ms: u64 = 24 * 60 * 60 * 1_000;
pub const FailureOverride = StreamRetry.FailureOverride;

pub const default_limits: Transport.Limits = .{
    .max_request_body_bytes = Body.default_maximum_body_bytes,
    .max_header_bytes = 32 * 1024,
    .max_sse_event_bytes = Events.maximum_event_bytes,
    .max_error_body_bytes = 4 * 1024,
    .header_buffer_bytes = 64 * 1024,
    .connect_timeout_ms = 10 * 1_000,
    .idle_timeout_ms = 10 * 60 * 1_000,
};

/// Credential fields are borrowed. A source must keep fields returned by
/// `acquire` valid until the next source callback, and fields returned by
/// `recoverUnauthorized` valid until the synchronous operation returns.
pub const Credential = struct {
    access_token: []const u8,
    account_id: []const u8,
};

/// Move-only credential copy. Deinitialize exactly once.
pub const OwnedCredential = struct {
    allocator: std.mem.Allocator,
    access_token: []u8,
    account_id: []u8,

    pub fn init(allocator: std.mem.Allocator, value: Credential) error{OutOfMemory}!OwnedCredential {
        const access_token = try allocator.dupe(u8, value.access_token);
        errdefer SecureAllocator.wipeFree(allocator, access_token);
        const account_id = try allocator.dupe(u8, value.account_id);
        return .{ .allocator = allocator, .access_token = access_token, .account_id = account_id };
    }

    pub fn credential(self: *const OwnedCredential) Credential {
        return .{ .access_token = self.access_token, .account_id = self.account_id };
    }

    pub fn deinit(self: *OwnedCredential) void {
        SecureAllocator.wipeFree(self.allocator, self.account_id);
        SecureAllocator.wipeFree(self.allocator, self.access_token);
        self.* = undefined;
    }
};

pub const AcquirePurpose = enum { request, metadata };

pub const AcquireDecision = union(enum) {
    ready: OwnedCredential,
    /// A bounded, user-safe failure. It must never contain credential material.
    fail: FailureOverride,

    pub fn deinit(self: *AcquireDecision) void {
        switch (self.*) {
            .ready => |*credential| credential.deinit(),
            .fail => {},
        }
        self.* = undefined;
    }
};

pub const UnauthorizedDecision = union(enum) {
    retry: OwnedCredential,
    use_response,
    /// A bounded, user-safe failure. It must never contain credential material.
    fail: FailureOverride,

    pub fn deinit(self: *UnauthorizedDecision) void {
        switch (self.*) {
            .retry => |*credential| credential.deinit(),
            .use_response, .fail => {},
        }
        self.* = undefined;
    }
};

/// Erased synchronous credential source. The implementation must outlive the
/// adapter and all copied provider handles.
pub const CredentialSource = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const CallbackError = error{ OutOfMemory, Cancelled };
    pub const VTable = struct {
        acquire: *const fn (
            std.mem.Allocator,
            std.Io,
            *anyopaque,
            ?Provider.Tick,
            AcquirePurpose,
        ) CallbackError!AcquireDecision,
        recover_unauthorized: *const fn (
            std.mem.Allocator,
            std.Io,
            *anyopaque,
            ?Provider.Tick,
            Credential,
        ) CallbackError!UnauthorizedDecision,
        note_unauthorized: *const fn (*anyopaque, Credential) void,
    };

    pub fn from(implementation: anytype) CredentialSource {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("CredentialSource.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn acquireFn(
                allocator: std.mem.Allocator,
                io: std.Io,
                context: *anyopaque,
                tick: ?Provider.Tick,
                purpose: AcquirePurpose,
            ) CallbackError!AcquireDecision {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.acquire(allocator, io, tick, purpose);
            }

            fn recoverUnauthorizedFn(
                allocator: std.mem.Allocator,
                io: std.Io,
                context: *anyopaque,
                tick: ?Provider.Tick,
                failed: Credential,
            ) CallbackError!UnauthorizedDecision {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.recoverUnauthorized(allocator, io, tick, failed);
            }

            fn noteUnauthorizedFn(context: *anyopaque, failed: Credential) void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                self.noteUnauthorized(failed);
            }

            const vtable: VTable = .{
                .acquire = acquireFn,
                .recover_unauthorized = recoverUnauthorizedFn,
                .note_unauthorized = noteUnauthorizedFn,
            };
        };
        return .{ .context = implementation, .vtable = &Adapter.vtable };
    }

    pub fn acquire(
        self: CredentialSource,
        allocator: std.mem.Allocator,
        io: std.Io,
        tick: ?Provider.Tick,
        purpose: AcquirePurpose,
    ) CallbackError!AcquireDecision {
        try pollTick(tick);
        var decision = self.vtable.acquire(allocator, io, self.context, tick, purpose) catch |err| {
            try pollTick(tick);
            return err;
        };
        pollTick(tick) catch |err| {
            decision.deinit();
            return err;
        };
        return decision;
    }

    pub fn recoverUnauthorized(
        self: CredentialSource,
        allocator: std.mem.Allocator,
        io: std.Io,
        tick: ?Provider.Tick,
        failed: Credential,
    ) CallbackError!UnauthorizedDecision {
        try pollTick(tick);
        var decision = self.vtable.recover_unauthorized(allocator, io, self.context, tick, failed) catch |err| {
            try pollTick(tick);
            return err;
        };
        pollTick(tick) catch |err| {
            decision.deinit();
            return err;
        };
        return decision;
    }

    pub fn noteUnauthorized(self: CredentialSource, failed: Credential) void {
        self.vtable.note_unauthorized(self.context, failed);
    }
};

fn pollTick(tick: ?Provider.Tick) error{Cancelled}!void {
    if (tick) |value| value.poll() catch return error.Cancelled;
}

pub const Config = struct {
    source: CredentialSource,
    /// Canonical lower-case UUID. Borrowed with the rest of this configuration.
    session_id: []const u8,
    user_agent: []const u8 = default_user_agent,
    extra_headers: []const Transport.Header = &.{},
    extra_body_json: ?[]const u8 = null,
    maximum_access_token_bytes: usize = default_maximum_access_token_bytes,
    maximum_account_id_bytes: usize = default_maximum_account_id_bytes,
    limits: Transport.Limits = default_limits,
    retry: StreamRetry.Options = .{},
    events: Events.Options = .{},
};

/// Codex Responses adapter. Config and all config slices are borrowed and must
/// outlive the adapter, copied provider handles, and synchronous stream calls.
pub const Codex = struct {
    transport: Transport.Transport,
    config: Config,

    pub fn init(transport: Transport.Transport, config: Config) Codex {
        return .{ .transport = transport, .config = config };
    }

    pub fn provider(self: *Codex) Provider.Provider {
        return Provider.Provider.from(self, provider_id);
    }

    pub fn stream(
        allocator: std.mem.Allocator,
        io: std.Io,
        self: *Codex,
        request: Provider.Request,
        sink: Provider.EventSink,
    ) Provider.StreamError!void {
        try validateConfig(self.config);
        if (!validEffort(request.context.effort)) return error.InvalidRequest;

        var acquired = try self.config.source.acquire(allocator, io, request.tick, .request);
        var owned_credential = switch (acquired) {
            .ready => |value| value,
            .fail => |failure| {
                try emitFailure(allocator, sink, failure, 401);
                return;
            },
        };
        acquired = undefined;
        defer owned_credential.deinit();
        const pinned_credential = owned_credential.credential();
        try validateCredential(self.config, pinned_credential);
        const pinned_account_id = pinned_credential.account_id;

        const body_limit = @min(self.config.limits.max_request_body_bytes, Body.default_maximum_body_bytes);
        const body = Body.build(allocator, request, .{
            .provider_id = provider_id,
            .prompt_cache_key = self.config.session_id,
            .text_verbosity = .low,
            .extra_body_json = self.config.extra_body_json,
            .maximum_body_bytes = body_limit,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidRequest, error.BodyTooLarge => return error.InvalidRequest,
        };
        defer allocator.free(body);

        var factory: AttemptFactory = .{
            .config = &self.config,
            .credential = pinned_credential,
        };
        var recovery: Recovery = .{
            .source = self.config.source,
            .config = &self.config,
            .factory = &factory,
            .failed = pinned_credential,
            .pinned_account_id = pinned_account_id,
        };
        defer recovery.deinit();
        return StreamRetry.run(
            allocator,
            io,
            self.transport,
            StreamRetry.Factory.from(&factory),
            .{
                .url = endpoint,
                .json_body = body,
                .tick = request.tick,
                .unauthorized_recovery = StreamRetry.UnauthorizedRecovery.from(&recovery),
                .limits = self.config.limits,
            },
            sink,
            self.config.retry,
        );
    }
};

fn validateConfig(config: Config) error{InvalidRequest}!void {
    if (!validUuid(config.session_id) or !headerValueSafe(config.user_agent) or config.user_agent.len == 0 or
        config.maximum_access_token_bytes == 0 or
        config.maximum_access_token_bytes > default_maximum_access_token_bytes or
        config.maximum_account_id_bytes == 0 or
        config.maximum_account_id_bytes > default_maximum_account_id_bytes)
    {
        return error.InvalidRequest;
    }
    if (config.extra_body_json) |extra| {
        if (extra.len > config.limits.max_request_body_bytes) return error.InvalidRequest;
    }
    if (config.limits.max_header_bytes == 0 or
        config.limits.max_header_bytes > maximum_header_bytes or
        config.limits.header_buffer_bytes == 0 or
        config.limits.header_buffer_bytes > maximum_header_buffer_bytes or
        config.limits.connect_timeout_ms == 0 or
        config.limits.connect_timeout_ms > maximum_timeout_ms)
    {
        return error.InvalidRequest;
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

    var header_bytes: usize = fixedHeaderBytes(config);
    if (header_bytes > config.limits.max_header_bytes) return error.InvalidRequest;
    for (config.extra_headers, 0..) |header, index| {
        if (!validHeaderName(header.name) or !headerValueSafe(header.value) or fixedHeader(header.name)) {
            return error.InvalidRequest;
        }
        header_bytes = std.math.add(usize, header_bytes, header.name.len) catch return error.InvalidRequest;
        header_bytes = std.math.add(usize, header_bytes, header.value.len) catch return error.InvalidRequest;
        if (header_bytes > config.limits.max_header_bytes) return error.InvalidRequest;
        for (config.extra_headers[index + 1 ..]) |other| {
            if (std.ascii.eqlIgnoreCase(header.name, other.name)) return error.InvalidRequest;
        }
    }
}

fn validateCredential(config: Config, credential: Credential) error{InvalidRequest}!void {
    if (credential.access_token.len == 0 or
        credential.access_token.len > config.maximum_access_token_bytes or
        !headerValueSafe(credential.access_token) or
        credential.account_id.len == 0 or
        credential.account_id.len > config.maximum_account_id_bytes or
        !headerValueSafe(credential.account_id))
    {
        return error.InvalidRequest;
    }
}

fn fixedHeaderBytes(config: Config) usize {
    return "Authorization".len + "Bearer ".len + config.maximum_access_token_bytes +
        "chatgpt-account-id".len + config.maximum_account_id_bytes +
        "originator".len + originator.len +
        "User-Agent".len + config.user_agent.len +
        "session-id".len + config.session_id.len +
        "x-client-request-id".len + config.session_id.len +
        "OpenAI-Beta".len + "responses=experimental".len +
        "Accept".len + "text/event-stream".len +
        "Content-Type".len + "application/json".len;
}

fn fixedHeader(name: []const u8) bool {
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
    }) |fixed| {
        if (std.ascii.eqlIgnoreCase(name, fixed)) return true;
    }
    return false;
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
    for (value) |byte| if ((byte < 0x20 and byte != '\t') or byte == 0x7f) return false;
    return true;
}

fn validUuid(value: []const u8) bool {
    if (value.len != 36) return false;
    for (value, 0..) |byte, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (byte != '-') return false;
        } else if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) {
            return false;
        }
    }
    return value[14] == '4' and (value[19] == '8' or value[19] == '9' or
        value[19] == 'a' or value[19] == 'b');
}

fn validEffort(effort: ?[]const u8) bool {
    const value = effort orelse return true;
    if (value.len == 0) return true;
    inline for (.{ "none", "low", "medium", "high", "xhigh", "max" }) |accepted| {
        if (std.mem.eql(u8, value, accepted)) return true;
    }
    return false;
}

fn emitFailure(
    allocator: std.mem.Allocator,
    sink: Provider.EventSink,
    failure: FailureOverride,
    fallback_status: u16,
) Provider.StreamError!void {
    const status: ?u16 = switch (failure) {
        .message => fallback_status,
        .formatted => |formatted| if (formatted.status) |value|
            if (value >= 100 and value <= 599) value else fallback_status
        else
            fallback_status,
    };
    const message = switch (failure) {
        .message => |source| ApiError.formatMessage(allocator, source) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BodyTooLarge => try allocator.dupe(u8, "credential acquisition failed"),
        },
        .formatted => |formatted| ApiError.formatApiError(
            allocator,
            status.?,
            formatted.body,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BodyTooLarge => try allocator.dupe(u8, "credential acquisition failed"),
        },
    };
    defer allocator.free(message);
    try sink.emit(.{ .failure = .{ .message = message, .http_status = status } });
}

const AttemptFactory = struct {
    config: *const Config,
    credential: Credential,

    pub fn create(
        self: *AttemptFactory,
        allocator: std.mem.Allocator,
        _: u16,
        sink: Provider.EventSink,
    ) StreamRetry.BuildError!StreamRetry.Attempt {
        try validateCredential(self.config.*, self.credential);
        const state = try allocator.create(AttemptState);
        errdefer allocator.destroy(state);
        const authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{self.credential.access_token});
        errdefer SecureAllocator.wipeFree(allocator, authorization);
        const account_id = try allocator.dupe(u8, self.credential.account_id);
        errdefer SecureAllocator.wipeFree(allocator, account_id);
        const headers = try allocator.alloc(Transport.Header, 9 + self.config.extra_headers.len);
        errdefer allocator.free(headers);
        headers[0] = .{ .name = "Authorization", .value = authorization, .privileged = true };
        headers[1] = .{
            .name = "chatgpt-account-id",
            .value = account_id,
            .privileged = true,
        };
        headers[2] = .{ .name = "originator", .value = originator };
        headers[3] = .{ .name = "User-Agent", .value = self.config.user_agent };
        headers[4] = .{ .name = "session-id", .value = self.config.session_id };
        headers[5] = .{ .name = "x-client-request-id", .value = self.config.session_id };
        headers[6] = .{ .name = "OpenAI-Beta", .value = "responses=experimental" };
        headers[7] = .{ .name = "Accept", .value = "text/event-stream" };
        headers[8] = .{ .name = "Content-Type", .value = "application/json" };
        @memcpy(headers[9..], self.config.extra_headers);
        const parser = Events.Parser.init(allocator, sink, self.config.events) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidResponse => return error.InvalidRequest,
            error.Cancelled => unreachable,
        };
        state.* = .{
            .parser = parser,
            .authorization = authorization,
            .account_id = account_id,
            .headers = headers,
        };
        return .{ .context = state, .vtable = &AttemptState.vtable };
    }
};

const Recovery = struct {
    source: CredentialSource,
    config: *const Config,
    factory: *AttemptFactory,
    failed: Credential,
    pinned_account_id: []const u8,
    replacement: ?OwnedCredential = null,

    fn deinit(self: *Recovery) void {
        if (self.replacement) |*credential| credential.deinit();
        self.* = undefined;
    }

    pub fn noteUnauthorized(self: *Recovery) void {
        self.source.noteUnauthorized(self.factory.credential);
    }

    pub fn recover(
        self: *Recovery,
        allocator: std.mem.Allocator,
        io: std.Io,
        tick: ?Provider.Tick,
    ) error{ OutOfMemory, Cancelled }!StreamRetry.UnauthorizedDecision {
        var decision = try self.source.recoverUnauthorized(allocator, io, tick, self.failed);
        return switch (decision) {
            .retry => |credential_value| retry: {
                var credential = credential_value;
                decision = undefined;
                errdefer credential.deinit();
                const borrowed = credential.credential();
                validateCredential(self.config.*, borrowed) catch {
                    credential.deinit();
                    break :retry .{ .fail = .{
                        .message = "authentication recovery returned invalid credentials",
                    } };
                };
                if (!std.mem.eql(u8, borrowed.account_id, self.pinned_account_id)) {
                    credential.deinit();
                    break :retry .{ .fail = .{
                        .message = "the codex login belongs to a different account: " ++
                            "run /login or /provider to switch",
                    } };
                }
                if (self.replacement) |*previous| previous.deinit();
                self.replacement = credential;
                self.factory.credential = self.replacement.?.credential();
                break :retry .retry;
            },
            .use_response => .use_response,
            .fail => |failure| .{ .fail = failure },
        };
    }
};

const AttemptState = struct {
    parser: Events.Parser,
    authorization: []u8,
    account_id: []u8,
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
        SecureAllocator.wipeFree(allocator, self.account_id);
        SecureAllocator.wipeFree(allocator, self.authorization);
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

const TestSource = struct {
    token: []const u8 = "old-token",
    account: []const u8 = "account",
    recovery: enum { rotate, switch_account, use_response, fail } = .rotate,
    acquires: usize = 0,
    recoveries: usize = 0,
    notes: usize = 0,

    pub fn acquire(
        self: *TestSource,
        allocator: std.mem.Allocator,
        _: std.Io,
        _: ?Provider.Tick,
        purpose: AcquirePurpose,
    ) CredentialSource.CallbackError!AcquireDecision {
        std.debug.assert(purpose == .request);
        self.acquires += 1;
        return .{ .ready = try OwnedCredential.init(allocator, .{
            .access_token = self.token,
            .account_id = self.account,
        }) };
    }

    pub fn recoverUnauthorized(
        self: *TestSource,
        allocator: std.mem.Allocator,
        _: std.Io,
        _: ?Provider.Tick,
        failed: Credential,
    ) CredentialSource.CallbackError!UnauthorizedDecision {
        self.recoveries += 1;
        std.debug.assert(std.mem.eql(u8, failed.access_token, "old-token"));
        return switch (self.recovery) {
            .rotate => .{ .retry = try OwnedCredential.init(allocator, .{
                .access_token = "new-token",
                .account_id = self.account,
            }) },
            .switch_account => .{ .retry = try OwnedCredential.init(allocator, .{
                .access_token = "new-token",
                .account_id = "other-account",
            }) },
            .use_response => .use_response,
            .fail => .{ .fail = .{ .message = "refresh failed" } },
        };
    }

    pub fn noteUnauthorized(self: *TestSource, failed: Credential) void {
        std.debug.assert(std.mem.eql(u8, failed.account_id, "account"));
        self.notes += 1;
    }
};

const TestTransport = struct {
    calls: usize = 0,
    valid: bool = true,

    pub fn ssePost(
        _: std.mem.Allocator,
        _: std.Io,
        self: *TestTransport,
        request: Transport.Request,
        sink: Transport.EventSink,
    ) Transport.StreamError!Transport.Result {
        self.calls += 1;
        self.valid = self.valid and std.mem.eql(u8, request.url, endpoint);
        self.valid = self.valid and request.headers.len == 9;
        self.valid = self.valid and request.headers[0].isPrivileged();
        self.valid = self.valid and request.headers[1].privileged;
        self.valid = self.valid and std.mem.eql(u8, request.headers[1].value, "account");
        self.valid = self.valid and std.mem.eql(u8, request.headers[4].value, request.headers[5].value);
        self.valid = self.valid and std.mem.find(u8, request.json_body, "\"prompt_cache_key\":") != null;
        self.valid = self.valid and
            std.mem.find(u8, request.json_body, "\"text\":{\"verbosity\":\"low\"}") != null;
        if (self.calls == 1) {
            self.valid = self.valid and std.mem.eql(u8, request.headers[0].value, "Bearer old-token");
            return .{ .status = 401, .outcome = .failed };
        }
        self.valid = self.valid and std.mem.eql(u8, request.headers[0].value, "Bearer new-token");
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
    failures: usize = 0,
    message_is_account_switch: bool = false,

    pub fn emit(self: *TestCollector, event: StreamEvent.StreamEvent) Provider.DeliveryError!void {
        switch (event) {
            .retry => self.retries += 1,
            .done => self.done += 1,
            .failure => |failure| {
                self.failures += 1;
                self.message_is_account_switch = std.mem.find(u8, failure.message, "different account") != null;
            },
            else => {},
        }
    }
};

fn testRequest() Provider.Request {
    return .{
        .model = "gpt-5",
        .context = .{ .system_prompt = "system", .items = &.{}, .tools = &.{} },
    };
}

test "401 rotates token for the same attempt without a retry event" {
    var source: TestSource = .{};
    var transport: TestTransport = .{};
    var collector: TestCollector = .{};
    var codex: Codex = .init(Transport.Transport.from(&transport), .{
        .source = CredentialSource.from(&source),
        .session_id = "12345678-1234-4234-8234-123456789abc",
    });

    try Codex.stream(std.testing.allocator, std.testing.io, &codex, testRequest(), Provider.EventSink.from(&collector));
    try std.testing.expect(transport.valid);
    try std.testing.expectEqual(@as(usize, 2), transport.calls);
    try std.testing.expectEqual(@as(usize, 1), source.acquires);
    try std.testing.expectEqual(@as(usize, 1), source.recoveries);
    try std.testing.expectEqual(@as(usize, 0), collector.retries);
    try std.testing.expectEqual(@as(usize, 1), collector.done);
}

test "401 recovery refuses an account switch and notes terminal unauthorized" {
    var source: TestSource = .{ .recovery = .switch_account };
    var transport: TestTransport = .{};
    var collector: TestCollector = .{};
    var codex: Codex = .init(Transport.Transport.from(&transport), .{
        .source = CredentialSource.from(&source),
        .session_id = "12345678-1234-4234-8234-123456789abc",
    });

    try Codex.stream(std.testing.allocator, std.testing.io, &codex, testRequest(), Provider.EventSink.from(&collector));
    try std.testing.expectEqual(@as(usize, 1), transport.calls);
    try std.testing.expectEqual(@as(usize, 1), source.notes);
    try std.testing.expectEqual(@as(usize, 1), collector.failures);
    try std.testing.expect(collector.message_is_account_switch);
}

test "copied stream credentials reach allocator release as zeros" {
    var observer = SecureAllocator.FreeObserver.init(std.testing.allocator);
    var source: TestSource = .{};
    var transport: TestTransport = .{};
    var collector: TestCollector = .{};
    var codex: Codex = .init(Transport.Transport.from(&transport), .{
        .source = CredentialSource.from(&source),
        .session_id = "12345678-1234-4234-8234-123456789abc",
    });
    try Codex.stream(
        observer.allocator(),
        std.testing.io,
        &codex,
        testRequest(),
        Provider.EventSink.from(&collector),
    );
    // Pinned token/account plus two attempts' Authorization/account pairs.
    try std.testing.expect(observer.zero_frees >= 6);
}

test "configuration permits disabled idle timeout but requires connect timeout" {
    var source: TestSource = .{};
    var config: Config = .{
        .source = CredentialSource.from(&source),
        .session_id = "12345678-1234-4234-8234-123456789abc",
    };
    config.limits.idle_timeout_ms = 0;
    try validateConfig(config);
    config.limits.idle_timeout_ms = std.math.maxInt(u64);
    try validateConfig(config);

    config.limits.connect_timeout_ms = 0;
    try std.testing.expectError(error.InvalidRequest, validateConfig(config));
}

test "configuration rejects header injection and fixed collisions" {
    var source: TestSource = .{};
    var transport: TestTransport = .{};
    var collector: TestCollector = .{};
    var codex: Codex = .init(Transport.Transport.from(&transport), .{
        .source = CredentialSource.from(&source),
        .session_id = "12345678-1234-4234-8234-123456789abc",
        .extra_headers = &.{.{ .name = "AUTHORIZATION", .value = "replacement" }},
    });
    try std.testing.expectError(
        error.InvalidRequest,
        Codex.stream(std.testing.allocator, std.testing.io, &codex, testRequest(), Provider.EventSink.from(&collector)),
    );
    try std.testing.expectEqual(@as(usize, 0), source.acquires);

    codex.config.extra_headers = &.{.{ .name = "x-test", .value = "ok\r\ninjected: yes" }};
    try std.testing.expectError(
        error.InvalidRequest,
        Codex.stream(std.testing.allocator, std.testing.io, &codex, testRequest(), Provider.EventSink.from(&collector)),
    );
}

const MutatingSource = struct {
    token: [9]u8 = "old-token".*,
    account: [7]u8 = "account".*,
    noted_safe_copy: bool = false,

    pub fn acquire(
        self: *MutatingSource,
        allocator: std.mem.Allocator,
        _: std.Io,
        _: ?Provider.Tick,
        _: AcquirePurpose,
    ) CredentialSource.CallbackError!AcquireDecision {
        return .{ .ready = try OwnedCredential.init(allocator, .{
            .access_token = &self.token,
            .account_id = &self.account,
        }) };
    }

    pub fn recoverUnauthorized(
        self: *MutatingSource,
        _: std.mem.Allocator,
        _: std.Io,
        _: ?Provider.Tick,
        _: Credential,
    ) CredentialSource.CallbackError!UnauthorizedDecision {
        @memset(&self.token, 'x');
        @memset(&self.account, 'y');
        return .{ .fail = .{ .message = "refresh failed" } };
    }

    pub fn noteUnauthorized(self: *MutatingSource, failed: Credential) void {
        self.noted_safe_copy = std.mem.eql(u8, failed.access_token, "old-token") and
            std.mem.eql(u8, failed.account_id, "account");
    }
};

test "credential identity is pinned across a source callback that invalidates its buffers" {
    var source: MutatingSource = .{};
    var transport: TestTransport = .{};
    var collector: TestCollector = .{};
    var codex: Codex = .init(Transport.Transport.from(&transport), .{
        .source = CredentialSource.from(&source),
        .session_id = "12345678-1234-4234-8234-123456789abc",
    });
    try Codex.stream(
        std.testing.allocator,
        std.testing.io,
        &codex,
        testRequest(),
        Provider.EventSink.from(&collector),
    );
    try std.testing.expect(source.noted_safe_copy);
    try std.testing.expectEqual(@as(usize, 1), collector.failures);
}

fn exerciseCodexAllocations(allocator: std.mem.Allocator) !void {
    var source: TestSource = .{};
    var transport: TestTransport = .{};
    var collector: TestCollector = .{};
    var codex: Codex = .init(Transport.Transport.from(&transport), .{
        .source = CredentialSource.from(&source),
        .session_id = "12345678-1234-4234-8234-123456789abc",
    });
    try Codex.stream(
        allocator,
        std.testing.io,
        &codex,
        testRequest(),
        Provider.EventSink.from(&collector),
    );
}

test "Codex stream frees every partial allocation and caps transport controls" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseCodexAllocations,
        .{},
    );
    var source: TestSource = .{};
    var transport: TestTransport = .{};
    var collector: TestCollector = .{};
    var codex: Codex = .init(Transport.Transport.from(&transport), .{
        .source = CredentialSource.from(&source),
        .session_id = "12345678-1234-4234-8234-123456789abc",
    });
    codex.config.limits.header_buffer_bytes = maximum_header_buffer_bytes + 1;
    try std.testing.expectError(error.InvalidRequest, Codex.stream(
        std.testing.allocator,
        std.testing.io,
        &codex,
        testRequest(),
        Provider.EventSink.from(&collector),
    ));
    try std.testing.expectEqual(@as(usize, 0), source.acquires);
    codex.config.limits = default_limits;
    codex.config.session_id = "12345678-1234-4234-7234-123456789abc";
    try std.testing.expectError(error.InvalidRequest, Codex.stream(
        std.testing.allocator,
        std.testing.io,
        &codex,
        testRequest(),
        Provider.EventSink.from(&collector),
    ));
}

const CancellationTick = struct {
    cancelled: bool = false,

    pub fn poll(self: *CancellationTick) Provider.DeliveryError!void {
        if (self.cancelled) return error.Cancelled;
    }
};

const CancellationSource = struct {
    tick: *CancellationTick,
    calls: usize = 0,
    mode: enum { ready, fail, out_of_memory } = .ready,

    pub fn acquire(
        self: *CancellationSource,
        allocator: std.mem.Allocator,
        _: std.Io,
        _: ?Provider.Tick,
        _: AcquirePurpose,
    ) CredentialSource.CallbackError!AcquireDecision {
        self.calls += 1;
        self.tick.cancelled = true;
        return switch (self.mode) {
            .ready => .{ .ready = try OwnedCredential.init(allocator, .{
                .access_token = "token",
                .account_id = "account",
            }) },
            .fail => .{ .fail = .{ .message = "failed" } },
            .out_of_memory => error.OutOfMemory,
        };
    }

    pub fn recoverUnauthorized(
        self: *CancellationSource,
        _: std.mem.Allocator,
        _: std.Io,
        _: ?Provider.Tick,
        _: Credential,
    ) CredentialSource.CallbackError!UnauthorizedDecision {
        self.calls += 1;
        self.tick.cancelled = true;
        return .use_response;
    }

    pub fn noteUnauthorized(_: *CancellationSource, _: Credential) void {}
};

test "credential seam gives cancellation precedence before and after callbacks" {
    var tick_state: CancellationTick = .{ .cancelled = true };
    var source_state: CancellationSource = .{ .tick = &tick_state };
    const source = CredentialSource.from(&source_state);
    try std.testing.expectError(error.Cancelled, source.acquire(
        std.testing.allocator,
        std.testing.io,
        Provider.Tick.from(&tick_state),
        .request,
    ));
    try std.testing.expectEqual(@as(usize, 0), source_state.calls);

    inline for (.{ CancellationSource{ .tick = &tick_state, .mode = .ready }, CancellationSource{
        .tick = &tick_state,
        .mode = .fail,
    }, CancellationSource{ .tick = &tick_state, .mode = .out_of_memory } }) |initial| {
        tick_state.cancelled = false;
        var state = initial;
        const candidate = CredentialSource.from(&state);
        try std.testing.expectError(error.Cancelled, candidate.acquire(
            std.testing.allocator,
            std.testing.io,
            Provider.Tick.from(&tick_state),
            .request,
        ));
    }

    tick_state.cancelled = false;
    source_state = .{ .tick = &tick_state };
    try std.testing.expectError(error.Cancelled, CredentialSource.from(&source_state).recoverUnauthorized(
        std.testing.allocator,
        std.testing.io,
        Provider.Tick.from(&tick_state),
        .{ .access_token = "token", .account_id = "account" },
    ));
}
