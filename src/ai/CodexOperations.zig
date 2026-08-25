const std = @import("std");
const SecureAllocator = @import("SecureAllocator.zig");
const ApiError = @import("ApiError.zig");
const Codex = @import("Codex.zig");
const CodexModels = @import("CodexModels.zig");
const CodexUsage = @import("CodexUsage.zig");
const JsonTransport = @import("JsonTransport.zig");
const Provider = @import("Provider.zig");
const StreamingTransport = @import("Transport.zig");

pub const models_url = "https://chatgpt.com/backend-api/codex/models?client_version=999.0.0";
pub const usage_url = "https://chatgpt.com/backend-api/wham/usage";
pub const model_timeout_ms: u64 = 5_000;
pub const usage_timeout_ms: u64 = 30_000;

pub const CredentialSource = Codex.CredentialSource;
pub const Credential = Codex.Credential;
pub const FailureOverride = Codex.FailureOverride;

/// Authentication settings shared with the streaming Codex adapter. All
/// fields are borrowed and must outlive the client and synchronous calls.
pub const Config = struct {
    source: CredentialSource,
    user_agent: []const u8 = Codex.default_user_agent,
    extra_headers: []const StreamingTransport.Header = &.{},
    maximum_access_token_bytes: usize = Codex.default_maximum_access_token_bytes,
    maximum_account_id_bytes: usize = Codex.default_maximum_account_id_bytes,
};

/// Alias for callers which pass the authentication subset between adapters.
pub const AuthOptions = Config;

pub const Failure = struct {
    allocator: std.mem.Allocator,
    message: []u8,
    http_status: ?u16 = null,

    pub fn deinit(self: *Failure) void {
        self.allocator.free(self.message);
        self.* = undefined;
    }
};

pub const ModelOutcome = union(enum) {
    success: CodexModels.OwnedList,
    failure: Failure,

    pub fn deinit(self: *ModelOutcome) void {
        switch (self.*) {
            .success => |*value| value.deinit(),
            .failure => |*value| value.deinit(),
        }
        self.* = undefined;
    }
};

pub const UsageOutcome = union(enum) {
    success: CodexUsage.Usage,
    failure: Failure,

    pub fn deinit(self: *UsageOutcome, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .success => |*value| value.deinit(allocator),
            .failure => |*value| value.deinit(),
        }
        self.* = undefined;
    }
};

pub const Error = error{ OutOfMemory, Cancelled, InvalidRequest };

pub const Client = struct {
    transport: JsonTransport.Transport,
    config: Config,

    pub fn init(transport: JsonTransport.Transport, config: Config) Client {
        return .{ .transport = transport, .config = config };
    }

    pub fn listModels(
        self: *Client,
        allocator: std.mem.Allocator,
        io: std.Io,
        tick: ?Provider.Tick,
    ) Error!ModelOutcome {
        try validateConfig(self.config);
        const operation = try Operation.begin(allocator, io, self.config, tick);
        return switch (operation) {
            .failure => |failure| .{ .failure = failure },
            .ready => |credential| self.listModelsWithCredential(allocator, io, tick, credential),
        };
    }

    pub fn queryUsage(
        self: *Client,
        allocator: std.mem.Allocator,
        io: std.Io,
        tick: ?Provider.Tick,
    ) Error!UsageOutcome {
        try validateConfig(self.config);
        const operation = try Operation.begin(allocator, io, self.config, tick);
        return switch (operation) {
            .failure => |failure| .{ .failure = failure },
            .ready => |credential| self.queryUsageWithCredential(allocator, io, tick, credential),
        };
    }

    fn listModelsWithCredential(
        self: *Client,
        allocator: std.mem.Allocator,
        io: std.Io,
        tick: ?Provider.Tick,
        initial: OwnedCredential,
    ) Error!ModelOutcome {
        var credential = initial;
        defer credential.deinit();
        const pinned_account = try allocator.dupe(u8, credential.value.credential().account_id);
        defer SecureAllocator.wipeFree(allocator, pinned_account);
        var recovered = false;

        while (true) {
            const response = self.get(
                allocator,
                io,
                tick,
                credential.value.credential(),
                models_url,
                model_timeout_ms,
                CodexModels.maximum_input_bytes,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Cancelled => return error.Cancelled,
                error.InvalidRequest => return error.InvalidRequest,
                error.InvalidResponse => return .{ .failure = try failureOwned(
                    allocator,
                    "codex sent an empty or truncated model catalog response",
                    null,
                ) },
                else => return .{ .failure = try failureOwned(
                    allocator,
                    "could not reach chatgpt.com to list models: check your network",
                    null,
                ) },
            };
            var owned_response = response;
            defer owned_response.deinit(allocator);

            if (owned_response.status == 401 and !recovered) {
                recovered = true;
                const decision = try self.config.source.recoverUnauthorized(
                    allocator,
                    io,
                    tick,
                    credential.value.credential(),
                );
                switch (decision) {
                    .retry => |replacement_value| {
                        var replacement = replacement_value;
                        defer replacement.deinit();
                        const replacement_borrowed = replacement.credential();
                        validateCredential(self.config, replacement_borrowed) catch {
                            self.config.source.noteUnauthorized(credential.value.credential());
                            return .{ .failure = try failureOwned(
                                allocator,
                                "authentication recovery returned invalid credentials",
                                401,
                            ) };
                        };
                        if (!std.mem.eql(u8, replacement_borrowed.account_id, pinned_account)) {
                            self.config.source.noteUnauthorized(credential.value.credential());
                            return .{ .failure = try failureOwned(
                                allocator,
                                "the codex login belongs to a different account: " ++
                                    "restart with the intended Codex CLI account or choose another --provider",
                                401,
                            ) };
                        }
                        const replacement_owned = try OwnedCredential.init(allocator, replacement_borrowed);
                        credential.deinit();
                        credential = replacement_owned;
                        continue;
                    },
                    .use_response => {},
                    .fail => |failure| {
                        defer self.config.source.noteUnauthorized(credential.value.credential());
                        const owned_failure = try failureFromOverride(allocator, failure, 401);
                        return .{ .failure = owned_failure };
                    },
                }
            }
            if (owned_response.status == 401) self.config.source.noteUnauthorized(credential.value.credential());
            if (owned_response.status < 200 or owned_response.status >= 300) {
                return .{ .failure = try modelHttpFailure(allocator, owned_response.status) };
            }
            if (owned_response.body.len == 0) return .{ .failure = try failureOwned(
                allocator,
                "codex sent an empty or truncated model catalog response",
                owned_response.status,
            ) };

            const models = CodexModels.parse(allocator, owned_response.body, .{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ResponseTooLarge => return .{ .failure = try failureOwned(
                    allocator,
                    "codex sent an empty or truncated model catalog response",
                    owned_response.status,
                ) },
                error.InvalidResponse => return .{ .failure = try failureOwned(
                    allocator,
                    try classifyModelParseFailure(allocator, owned_response.body),
                    owned_response.status,
                ) },
            };
            return .{ .success = models };
        }
    }

    fn queryUsageWithCredential(
        self: *Client,
        allocator: std.mem.Allocator,
        io: std.Io,
        tick: ?Provider.Tick,
        initial: OwnedCredential,
    ) Error!UsageOutcome {
        var credential = initial;
        defer credential.deinit();
        const pinned_account = try allocator.dupe(u8, credential.value.credential().account_id);
        defer SecureAllocator.wipeFree(allocator, pinned_account);
        var recovered = false;

        while (true) {
            const response = self.get(
                allocator,
                io,
                tick,
                credential.value.credential(),
                usage_url,
                usage_timeout_ms,
                CodexUsage.maximum_json_bytes,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Cancelled => return error.Cancelled,
                error.InvalidRequest => return error.InvalidRequest,
                else => return .{ .failure = try failureOwned(
                    allocator,
                    "failed to fetch usage from " ++ usage_url,
                    null,
                ) },
            };
            var owned_response = response;
            defer owned_response.deinit(allocator);

            if (owned_response.status == 401 and !recovered) {
                recovered = true;
                const decision = try self.config.source.recoverUnauthorized(
                    allocator,
                    io,
                    tick,
                    credential.value.credential(),
                );
                switch (decision) {
                    .retry => |replacement_value| {
                        var replacement = replacement_value;
                        defer replacement.deinit();
                        const replacement_borrowed = replacement.credential();
                        validateCredential(self.config, replacement_borrowed) catch {
                            self.config.source.noteUnauthorized(credential.value.credential());
                            return .{ .failure = try failureOwned(
                                allocator,
                                "authentication recovery returned invalid credentials",
                                401,
                            ) };
                        };
                        if (!std.mem.eql(u8, replacement_borrowed.account_id, pinned_account)) {
                            self.config.source.noteUnauthorized(credential.value.credential());
                            return .{ .failure = try failureOwned(
                                allocator,
                                "the codex login belongs to a different account: " ++
                                    "restart with the intended Codex CLI account or choose another --provider",
                                401,
                            ) };
                        }
                        const replacement_owned = try OwnedCredential.init(allocator, replacement_borrowed);
                        credential.deinit();
                        credential = replacement_owned;
                        continue;
                    },
                    .use_response => {},
                    .fail => |failure| {
                        defer self.config.source.noteUnauthorized(credential.value.credential());
                        const owned_failure = try failureFromOverride(allocator, failure, 401);
                        return .{ .failure = owned_failure };
                    },
                }
            }
            if (owned_response.status == 401) self.config.source.noteUnauthorized(credential.value.credential());
            if (owned_response.status < 200 or owned_response.status >= 300) {
                const message = if (owned_response.status == 401)
                    "codex login expired: authenticate with the Codex CLI again"
                else
                    "failed to fetch usage from " ++ usage_url;
                return .{ .failure = try failureOwned(allocator, message, owned_response.status) };
            }

            const usage = CodexUsage.parse(allocator, owned_response.body, .{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return .{ .failure = try failureOwned(
                    allocator,
                    "usage response is not valid JSON",
                    owned_response.status,
                ) },
            };
            return .{ .success = usage };
        }
    }

    fn get(
        self: *Client,
        allocator: std.mem.Allocator,
        io: std.Io,
        tick: ?Provider.Tick,
        credential: Credential,
        url: []const u8,
        timeout_ms: u64,
        response_limit: usize,
    ) JsonTransport.Error!JsonTransport.Response {
        const authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{credential.access_token});
        defer SecureAllocator.wipeFree(allocator, authorization);
        const headers = try allocator.alloc(StreamingTransport.Header, 5 + self.config.extra_headers.len);
        defer allocator.free(headers);
        headers[0] = .{ .name = "Authorization", .value = authorization, .privileged = true };
        headers[1] = .{
            .name = "chatgpt-account-id",
            .value = credential.account_id,
            .privileged = true,
        };
        headers[2] = .{ .name = "originator", .value = Codex.originator };
        headers[3] = .{ .name = "User-Agent", .value = self.config.user_agent };
        headers[4] = .{ .name = "Accept", .value = "application/json" };
        @memcpy(headers[5..], self.config.extra_headers);
        return self.transport.request(allocator, io, .{
            .method = .get,
            .url = url,
            .headers = headers,
            .tick = tick,
            .limits = .{
                .max_request_body_bytes = 1,
                .max_response_body_bytes = response_limit,
                .max_header_bytes = Codex.maximum_header_bytes,
                .header_buffer_bytes = 32 * 1024,
                .connect_timeout_ms = 2_000,
                .idle_timeout_ms = timeout_ms,
                .total_timeout_ms = timeout_ms,
            },
        });
    }
};

const Operation = union(enum) {
    ready: OwnedCredential,
    failure: Failure,

    fn begin(
        allocator: std.mem.Allocator,
        io: std.Io,
        config: Config,
        tick: ?Provider.Tick,
    ) Error!Operation {
        var acquired = try config.source.acquire(allocator, io, tick, .request);
        return switch (acquired) {
            .ready => |credential| ready: {
                acquired = undefined;
                break :ready .{ .ready = try OwnedCredential.initChecked(config, credential) };
            },
            .fail => |failure| .{ .failure = try failureFromOverride(allocator, failure, 401) },
        };
    }
};

const OwnedCredential = struct {
    value: Codex.OwnedCredential,

    fn initChecked(config: Config, owned: Codex.OwnedCredential) Error!OwnedCredential {
        var value = owned;
        errdefer value.deinit();
        try validateCredential(config, value.credential());
        return .{ .value = value };
    }

    fn init(allocator: std.mem.Allocator, value: Credential) error{OutOfMemory}!OwnedCredential {
        return .{ .value = try Codex.OwnedCredential.init(allocator, value) };
    }

    fn deinit(self: *OwnedCredential) void {
        self.value.deinit();
        self.* = undefined;
    }
};

fn validateConfig(config: Config) error{InvalidRequest}!void {
    if (config.user_agent.len == 0 or !headerValueSafe(config.user_agent) or
        config.maximum_access_token_bytes == 0 or
        config.maximum_access_token_bytes > Codex.default_maximum_access_token_bytes or
        config.maximum_account_id_bytes == 0 or
        config.maximum_account_id_bytes > Codex.default_maximum_account_id_bytes or
        config.extra_headers.len > Codex.maximum_extra_headers)
    {
        return error.InvalidRequest;
    }
    var total = "Authorization".len + "Bearer ".len + config.maximum_access_token_bytes +
        "chatgpt-account-id".len + config.maximum_account_id_bytes +
        "originator".len + Codex.originator.len + "User-Agent".len + config.user_agent.len +
        "Accept".len + "application/json".len;
    for (config.extra_headers, 0..) |header, index| {
        if (!validHeaderName(header.name) or !headerValueSafe(header.value) or fixedHeader(header.name)) {
            return error.InvalidRequest;
        }
        total = std.math.add(usize, total, header.name.len) catch return error.InvalidRequest;
        total = std.math.add(usize, total, header.value.len) catch return error.InvalidRequest;
        if (total > Codex.maximum_header_bytes) return error.InvalidRequest;
        for (config.extra_headers[index + 1 ..]) |other| {
            if (std.ascii.eqlIgnoreCase(header.name, other.name)) return error.InvalidRequest;
        }
    }
}

fn validateCredential(config: Config, credential: Credential) error{InvalidRequest}!void {
    if (credential.access_token.len == 0 or
        credential.access_token.len > config.maximum_access_token_bytes or
        !headerValueSafe(credential.access_token) or credential.account_id.len == 0 or
        credential.account_id.len > config.maximum_account_id_bytes or
        !headerValueSafe(credential.account_id)) return error.InvalidRequest;
}

fn fixedHeader(name: []const u8) bool {
    inline for (.{ "authorization", "chatgpt-account-id", "originator", "user-agent", "accept" }) |fixed| {
        if (std.ascii.eqlIgnoreCase(name, fixed)) return true;
    }
    return false;
}

fn validHeaderName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| if (!(std.ascii.isAlphanumeric(byte) or switch (byte) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    })) return false;
    return true;
}

fn headerValueSafe(value: []const u8) bool {
    for (value) |byte| if ((byte < 0x20 and byte != '\t') or byte == 0x7f) return false;
    return true;
}

fn failureOwned(
    allocator: std.mem.Allocator,
    message: []const u8,
    status: ?u16,
) error{OutOfMemory}!Failure {
    return .{ .allocator = allocator, .message = try allocator.dupe(u8, message), .http_status = status };
}

fn failureFromOverride(
    allocator: std.mem.Allocator,
    failure: FailureOverride,
    fallback_status: u16,
) error{OutOfMemory}!Failure {
    const status: u16 = switch (failure) {
        .message => fallback_status,
        .formatted => |value| if (value.status) |candidate|
            if (candidate >= 100 and candidate <= 599) candidate else fallback_status
        else
            fallback_status,
    };
    const message = switch (failure) {
        .message => |value| ApiError.formatMessage(allocator, value) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BodyTooLarge => try allocator.dupe(u8, "credential acquisition failed"),
        },
        .formatted => |value| ApiError.formatApiError(allocator, status, value.body) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BodyTooLarge => try allocator.dupe(u8, "credential acquisition failed"),
        },
    };
    return .{ .allocator = allocator, .message = message, .http_status = status };
}

fn modelHttpFailure(allocator: std.mem.Allocator, status: u16) error{OutOfMemory}!Failure {
    if (status == 401) return failureOwned(
        allocator,
        "codex login expired: authenticate with the Codex CLI again",
        status,
    );
    if (status >= 200 and status < 300) return failureOwned(
        allocator,
        "codex sent an empty or truncated model catalog response",
        status,
    );
    const message = try std.fmt.allocPrint(allocator, "codex model catalog fetch failed (HTTP {d})", .{status});
    return .{ .allocator = allocator, .message = message, .http_status = status };
}

fn classifyModelParseFailure(allocator: std.mem.Allocator, body: []const u8) error{OutOfMemory}![]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return "codex model catalog response is not valid JSON",
    };
    defer parsed.deinit();
    if (parsed.value != .object) return "codex model catalog response has no model list";
    const models = parsed.value.object.get("models") orelse
        return "codex model catalog response has no model list";
    if (models != .array) return "codex model catalog response has no model list";
    if (models.array.items.len != 0) {
        var has_slug = false;
        for (models.array.items) |entry| {
            if (entry == .object) if (entry.object.get("slug")) |slug| {
                if (slug == .string and slug.string.len != 0) has_slug = true;
            };
        }
        if (!has_slug) return "codex model catalog response contains no usable model slugs";
    }
    return "codex model catalog response is not valid JSON";
}

const TestSource = struct {
    mode: enum { rotate, switch_account, fail } = .rotate,
    acquires: usize = 0,
    recoveries: usize = 0,
    notes: usize = 0,

    pub fn acquire(
        self: *TestSource,
        allocator: std.mem.Allocator,
        _: std.Io,
        _: ?Provider.Tick,
        purpose: Codex.AcquirePurpose,
    ) CredentialSource.CallbackError!Codex.AcquireDecision {
        std.debug.assert(purpose == .request);
        self.acquires += 1;
        return .{ .ready = try Codex.OwnedCredential.init(allocator, .{
            .access_token = "old-token",
            .account_id = "account",
        }) };
    }

    pub fn recoverUnauthorized(
        self: *TestSource,
        allocator: std.mem.Allocator,
        _: std.Io,
        _: ?Provider.Tick,
        failed: Credential,
    ) CredentialSource.CallbackError!Codex.UnauthorizedDecision {
        self.recoveries += 1;
        std.debug.assert(std.mem.eql(u8, failed.access_token, "old-token"));
        return switch (self.mode) {
            .rotate => .{ .retry = try Codex.OwnedCredential.init(allocator, .{
                .access_token = "new-token",
                .account_id = "account",
            }) },
            .switch_account => .{ .retry = try Codex.OwnedCredential.init(allocator, .{
                .access_token = "new-token",
                .account_id = "other-account",
            }) },
            .fail => .{ .fail = .{ .message = "codex CLI token expired: rerun the Codex CLI to authenticate" } },
        };
    }

    pub fn noteUnauthorized(self: *TestSource, _: Credential) void {
        self.notes += 1;
    }
};

const TestTransport = struct {
    mode: enum {
        rotate_models,
        double_unauthorized,
        usage,
        forbidden,
        network,
        cancelled,
        malformed,
        oversize,
    } = .rotate_models,
    calls: usize = 0,
    valid: bool = true,

    pub fn request(
        allocator: std.mem.Allocator,
        _: std.Io,
        self: *TestTransport,
        value: JsonTransport.Request,
    ) JsonTransport.Error!JsonTransport.Response {
        self.calls += 1;
        self.valid = self.valid and value.method == .get;
        self.valid = self.valid and value.json_body == null;
        self.valid = self.valid and value.headers.len == 5;
        self.valid = self.valid and value.headers[0].isPrivileged();
        self.valid = self.valid and value.headers[1].isPrivileged();
        self.valid = self.valid and std.mem.eql(u8, value.headers[2].value, Codex.originator);
        self.valid = self.valid and std.mem.eql(u8, value.headers[3].value, Codex.default_user_agent);
        self.valid = self.valid and std.mem.eql(u8, value.headers[4].value, "application/json");
        switch (self.mode) {
            .rotate_models => {
                self.valid = self.valid and std.mem.eql(u8, value.url, models_url);
                self.valid = self.valid and value.limits.connect_timeout_ms == 2_000;
                self.valid = self.valid and value.limits.idle_timeout_ms == model_timeout_ms and
                    value.limits.total_timeout_ms == model_timeout_ms;
                if (self.calls == 1) {
                    self.valid = self.valid and std.mem.eql(u8, value.headers[0].value, "Bearer old-token");
                    return response(allocator, 401, "");
                }
                self.valid = self.valid and std.mem.eql(u8, value.headers[0].value, "Bearer new-token");
                return response(allocator, 200, "{\"models\":[{\"slug\":\"gpt-5.4\",\"context_window\":272000}]}");
            },
            .double_unauthorized => {
                self.valid = self.valid and std.mem.eql(u8, value.url, models_url);
                return response(allocator, 401, "");
            },
            .usage => {
                self.valid = self.valid and std.mem.eql(u8, value.url, usage_url);
                self.valid = self.valid and value.limits.connect_timeout_ms == 2_000;
                self.valid = self.valid and value.limits.idle_timeout_ms == usage_timeout_ms and
                    value.limits.total_timeout_ms == usage_timeout_ms;
                return response(
                    allocator,
                    200,
                    "{\"plan_type\":\"plus\",\"rate_limit\":{\"primary_window\":{\"used_percent\":12}}}",
                );
            },
            .forbidden => return response(allocator, 403, "denied"),
            .network => return error.ConnectionFailed,
            .cancelled => return error.Cancelled,
            .malformed => return response(allocator, 200, "{"),
            .oversize => return error.InvalidResponse,
        }
    }

    fn response(
        allocator: std.mem.Allocator,
        status: u16,
        body: []const u8,
    ) error{OutOfMemory}!JsonTransport.Response {
        return .{ .status = status, .body = try allocator.dupe(u8, body) };
    }
};

fn testClient(source: *TestSource, transport: *TestTransport) Client {
    return .init(JsonTransport.Transport.from(transport), .{ .source = CredentialSource.from(source) });
}

test "model operation uses exact request and rotates one 401 on the pinned account" {
    var source: TestSource = .{};
    var transport: TestTransport = .{};
    var client = testClient(&source, &transport);
    var outcome = try client.listModels(std.testing.allocator, std.testing.io, null);
    defer outcome.deinit();
    try std.testing.expect(outcome == .success);
    try std.testing.expectEqualStrings("gpt-5.4", outcome.success.models[0].id);
    try std.testing.expect(transport.valid);
    try std.testing.expectEqual(@as(usize, 2), transport.calls);
    try std.testing.expectEqual(@as(usize, 1), source.recoveries);
    try std.testing.expectEqual(@as(usize, 0), source.notes);
}

test "operation credential copies reach allocator release as zeros" {
    var observer = SecureAllocator.FreeObserver.init(std.testing.allocator);
    var source: TestSource = .{};
    var transport: TestTransport = .{};
    var client = testClient(&source, &transport);
    var outcome = try client.listModels(observer.allocator(), std.testing.io, null);
    try std.testing.expect(outcome == .success);
    outcome.deinit();
    // Old and rotated credentials, pinned account, and two Authorization values.
    try std.testing.expect(observer.zero_frees >= 7);
}

test "a second 401 is terminal and noted without a second recovery" {
    var source: TestSource = .{};
    var transport: TestTransport = .{ .mode = .double_unauthorized };
    var client = testClient(&source, &transport);
    var outcome = try client.listModels(std.testing.allocator, std.testing.io, null);
    defer outcome.deinit();
    try std.testing.expect(outcome == .failure);
    try std.testing.expectEqual(@as(usize, 2), transport.calls);
    try std.testing.expectEqual(@as(usize, 1), source.recoveries);
    try std.testing.expectEqual(@as(usize, 1), source.notes);
}

test "usage operation uses exact endpoint and parses owned usage" {
    var source: TestSource = .{};
    var transport: TestTransport = .{ .mode = .usage };
    var client = testClient(&source, &transport);
    var outcome = try client.queryUsage(std.testing.allocator, std.testing.io, null);
    defer outcome.deinit(std.testing.allocator);
    try std.testing.expect(outcome == .success);
    try std.testing.expectEqualStrings("plus", outcome.success.plan_type.?);
    try std.testing.expect(transport.valid);
}

test "account switch, 403, network, malformed, and oversized responses are bounded failures" {
    var source: TestSource = .{ .mode = .switch_account };
    var transport: TestTransport = .{};
    var client = testClient(&source, &transport);
    var switched = try client.listModels(std.testing.allocator, std.testing.io, null);
    defer switched.deinit();
    try std.testing.expect(switched == .failure);
    try std.testing.expect(std.mem.find(u8, switched.failure.message, "different account") != null);
    try std.testing.expectEqual(@as(usize, 1), source.notes);

    source = .{};
    transport = .{ .mode = .forbidden };
    client = testClient(&source, &transport);
    var forbidden = try client.listModels(std.testing.allocator, std.testing.io, null);
    defer forbidden.deinit();
    try std.testing.expectEqualStrings("codex model catalog fetch failed (HTTP 403)", forbidden.failure.message);
    try std.testing.expectEqual(@as(usize, 0), source.recoveries);

    source = .{};
    transport = .{ .mode = .cancelled };
    client = testClient(&source, &transport);
    try std.testing.expectError(
        error.Cancelled,
        client.listModels(std.testing.allocator, std.testing.io, null),
    );

    inline for (.{
        TestTransport{ .mode = .network },
        TestTransport{ .mode = .malformed },
        TestTransport{ .mode = .oversize },
    }) |initial_transport| {
        source = .{};
        transport = initial_transport;
        client = testClient(&source, &transport);
        var failed = try client.listModels(std.testing.allocator, std.testing.io, null);
        defer failed.deinit();
        try std.testing.expect(failed == .failure);
        try std.testing.expect(failed.failure.message.len <= ApiError.maximum_message_bytes);
    }
}

fn exerciseOperationAllocations(allocator: std.mem.Allocator) !void {
    var source: TestSource = .{};
    var transport: TestTransport = .{};
    var client = testClient(&source, &transport);
    var outcome = try client.listModels(allocator, std.testing.io, null);
    outcome.deinit();
}

test "operation allocation failures do not leak" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseOperationAllocations, .{});
}
