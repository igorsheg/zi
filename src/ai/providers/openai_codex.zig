const std = @import("std");
const BoundedJson = @import("../../BoundedJson.zig");
const oauth_api = @import("../oauth.zig");
const fake_transport = @import("../transport/fake.zig");
const model_api = @import("../model.zig");
const transport_api = @import("../transport.zig");

pub const client_id = "app_EMoamEEZ73f0CkXaXp7hrann";
pub const token_url = "https://auth.openai.com/oauth/token";
const authorize_url = "https://auth.openai.com/oauth/authorize";
const redirect_uri = "http://localhost:1455/auth/callback";
const device_redirect_uri = "https://auth.openai.com/deviceauth/callback";
const device_user_code_url = "https://auth.openai.com/api/accounts/deviceauth/usercode";
const device_token_url = "https://auth.openai.com/api/accounts/deviceauth/token";
const device_verification_uri = "https://auth.openai.com/codex/device";
const scope = "openid profile email offline_access";
const max_response_bytes = 64 * 1024;

pub const OAuth = struct {
    pub fn authenticator(self: *const OAuth) oauth_api.Authenticator {
        return oauth_api.Authenticator.from(self);
    }

    pub fn refresher(self: *const OAuth) oauth_api.Refresher {
        return oauth_api.Refresher.from(self);
    }

    pub fn login(
        _: *const OAuth,
        result_allocator: std.mem.Allocator,
        scratch_allocator: std.mem.Allocator,
        io: std.Io,
        transport: transport_api.Transport,
        request: oauth_api.LoginRequest,
    ) oauth_api.Error!oauth_api.Refreshed {
        return switch (request.method) {
            .browser => loginBrowser(
                result_allocator,
                scratch_allocator,
                io,
                transport,
                request,
            ),
            .device_code => loginDeviceCode(
                result_allocator,
                scratch_allocator,
                io,
                transport,
                request,
            ),
        };
    }

    pub fn refresh(
        _: *const OAuth,
        result_allocator: std.mem.Allocator,
        scratch_allocator: std.mem.Allocator,
        io: std.Io,
        transport: transport_api.Transport,
        request: oauth_api.Request,
    ) oauth_api.Error!oauth_api.Refreshed {
        var body: std.Io.Writer.Allocating = .init(scratch_allocator);
        defer {
            std.crypto.secureZero(u8, body.written());
            body.deinit();
        }
        var form: Form = .{};
        form.append(&body.writer, "grant_type", "refresh_token") catch return error.OutOfMemory;
        form.append(&body.writer, "refresh_token", request.credential.refresh) catch return error.OutOfMemory;
        form.append(&body.writer, "client_id", client_id) catch return error.OutOfMemory;

        const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
            .raw = .fromSeconds(15),
            .clock = .awake,
        });
        const response = try transport.exchange(scratch_allocator, io, .{
            .method = .POST,
            .url = token_url,
            .headers = &.{.{ .name = "content-type", .value = "application/x-www-form-urlencoded" }},
            .body = body.written(),
            .max_response_bytes = max_response_bytes,
            .deadline = deadline,
            .cancellation = request.cancellation,
        }, .buffered);
        defer wipeResponse(scratch_allocator, response.body);
        if (response.status < 200 or response.status >= 300) return error.Rejected;
        return parseTokenResponse(
            result_allocator,
            scratch_allocator,
            response.body,
            request.now_ms,
        );
    }
};

fn loginBrowser(
    result_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    io: std.Io,
    transport: transport_api.Transport,
    request: oauth_api.LoginRequest,
) oauth_api.Error!oauth_api.Refreshed {
    if (request.cancellation) |token| if (token.isCancelled()) return error.Cancelled;
    var verifier_bytes: [32]u8 = undefined;
    io.random(&verifier_bytes);
    var verifier: [std.base64.url_safe_no_pad.Encoder.calcSize(verifier_bytes.len)]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&verifier, &verifier_bytes);
    defer std.crypto.secureZero(u8, &verifier_bytes);
    defer std.crypto.secureZero(u8, &verifier);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&verifier, &digest, .{});
    var challenge: [std.base64.url_safe_no_pad.Encoder.calcSize(digest.len)]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&challenge, &digest);
    defer std.crypto.secureZero(u8, &digest);
    var state_bytes: [16]u8 = undefined;
    io.random(&state_bytes);
    defer std.crypto.secureZero(u8, &state_bytes);
    var state_buffer: [32]u8 = undefined;
    const state = std.fmt.bufPrint(&state_buffer, "{x}", .{state_bytes}) catch unreachable;

    var url: std.Io.Writer.Allocating = .init(scratch_allocator);
    defer url.deinit();
    url.writer.writeAll(authorize_url ++ "?") catch return error.OutOfMemory;
    var query: Form = .{};
    query.append(&url.writer, "response_type", "code") catch return error.OutOfMemory;
    query.append(&url.writer, "client_id", client_id) catch return error.OutOfMemory;
    query.append(&url.writer, "redirect_uri", redirect_uri) catch return error.OutOfMemory;
    query.append(&url.writer, "scope", scope) catch return error.OutOfMemory;
    query.append(&url.writer, "code_challenge", &challenge) catch return error.OutOfMemory;
    query.append(&url.writer, "code_challenge_method", "S256") catch return error.OutOfMemory;
    query.append(&url.writer, "state", state) catch return error.OutOfMemory;
    query.append(&url.writer, "id_token_add_organizations", "true") catch return error.OutOfMemory;
    query.append(&url.writer, "codex_cli_simplified_flow", "true") catch return error.OutOfMemory;
    query.append(&url.writer, "originator", "zi") catch return error.OutOfMemory;
    request.interaction.notify(.{ .auth_url = .{
        .url = url.written(),
        .instructions = "Open the URL, finish login, then paste the authorization code or redirect URL.",
    } }) catch return error.InvalidResponse;
    const input = request.interaction.prompt(scratch_allocator, .{
        .message = "Authorization code or redirect URL: ",
        .placeholder = redirect_uri,
    }) catch return error.InvalidResponse;
    defer {
        std.crypto.secureZero(u8, input);
        scratch_allocator.free(input);
    }
    if (request.cancellation) |token| if (token.isCancelled()) return error.Cancelled;
    const parsed = try parseAuthorizationInput(scratch_allocator, input);
    defer {
        std.crypto.secureZero(u8, parsed.code);
        scratch_allocator.free(parsed.code);
        if (parsed.state) |value| scratch_allocator.free(value);
    }
    if (parsed.state) |actual| {
        if (!std.mem.eql(u8, actual, state)) return error.Rejected;
    }
    return exchangeAuthorizationCode(
        result_allocator,
        scratch_allocator,
        io,
        transport,
        parsed.code,
        &verifier,
        redirect_uri,
        request.now_ms,
        request.cancellation,
    );
}

fn loginDeviceCode(
    result_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    io: std.Io,
    transport: transport_api.Transport,
    request: oauth_api.LoginRequest,
) oauth_api.Error!oauth_api.Refreshed {
    const request_body = "{\"client_id\":\"" ++ client_id ++ "\"}";
    if (request.cancellation) |token| if (token.isCancelled()) return error.Cancelled;
    const response = try exchangeJson(
        scratch_allocator,
        io,
        transport,
        device_user_code_url,
        request_body,
        request.cancellation,
    );
    defer wipeResponse(scratch_allocator, response.body);
    if (response.status < 200 or response.status >= 300) return error.Rejected;
    const DeviceResponse = struct {
        device_auth_id: []const u8,
        user_code: []const u8,
        interval: std.json.Value,
    };
    var parsed = std.json.parseFromSlice(DeviceResponse, scratch_allocator, response.body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
        .max_value_len = 64 * 1024,
    }) catch |failure| return mapParseFailure(failure);
    defer parsed.deinit();
    const interval_seconds = parseInterval(parsed.value.interval) orelse return error.InvalidResponse;
    if (parsed.value.device_auth_id.len == 0 or parsed.value.user_code.len == 0) {
        return error.InvalidResponse;
    }
    request.interaction.notify(.{ .device_code = .{
        .user_code = parsed.value.user_code,
        .verification_uri = device_verification_uri,
        .interval_seconds = interval_seconds,
        .expires_in_seconds = 15 * 60,
    } }) catch return error.InvalidResponse;

    const attempts = @divFloor(@as(u64, 15 * 60), @max(interval_seconds, 1)) + 1;
    var attempt: u64 = 0;
    var interval = interval_seconds;
    while (attempt < attempts) : (attempt += 1) {
        if (request.cancellation) |token| if (token.isCancelled()) return error.Cancelled;
        var poll_body: std.Io.Writer.Allocating = .init(scratch_allocator);
        defer poll_body.deinit();
        var json: std.json.Stringify = .{ .writer = &poll_body.writer };
        json.beginObject() catch return error.OutOfMemory;
        json.objectField("device_auth_id") catch return error.OutOfMemory;
        json.write(parsed.value.device_auth_id) catch return error.OutOfMemory;
        json.objectField("user_code") catch return error.OutOfMemory;
        json.write(parsed.value.user_code) catch return error.OutOfMemory;
        json.endObject() catch return error.OutOfMemory;
        const poll = try exchangeJson(
            scratch_allocator,
            io,
            transport,
            device_token_url,
            poll_body.written(),
            request.cancellation,
        );
        defer wipeResponse(scratch_allocator, poll.body);
        if (poll.status >= 200 and poll.status < 300) {
            const Success = struct {
                authorization_code: []const u8,
                code_verifier: []const u8,
            };
            var success = std.json.parseFromSlice(Success, scratch_allocator, poll.body, .{
                .allocate = .alloc_always,
                .ignore_unknown_fields = true,
                .max_value_len = 64 * 1024,
            }) catch |failure| return mapParseFailure(failure);
            defer success.deinit();
            return exchangeAuthorizationCode(
                result_allocator,
                scratch_allocator,
                io,
                transport,
                success.value.authorization_code,
                success.value.code_verifier,
                device_redirect_uri,
                request.now_ms,
                request.cancellation,
            );
        }
        const disposition = devicePollDisposition(scratch_allocator, poll.status, poll.body);
        if (disposition == .failed) return error.Rejected;
        if (disposition == .slow_down) interval = @min(interval + 5, 60);
        if (interval > 0) try cancellableSleep(io, interval, request.cancellation);
    }
    return error.TimedOut;
}

fn cancellableSleep(
    io: std.Io,
    seconds: u64,
    cancellation: ?*const model_api.CancellationToken,
) oauth_api.Error!void {
    var remaining_ms = std.math.mul(u64, seconds, 1000) catch return error.TimedOut;
    while (remaining_ms != 0) {
        if (cancellation) |token| if (token.isCancelled()) return error.Cancelled;
        const slice_ms = @min(remaining_ms, 100);
        const timeout: std.Io.Timeout = .{ .duration = .{
            .raw = .fromMilliseconds(@intCast(slice_ms)),
            .clock = .awake,
        } };
        timeout.sleep(io) catch return error.Cancelled;
        remaining_ms -= slice_ms;
    }
    if (cancellation) |token| if (token.isCancelled()) return error.Cancelled;
}

const PollDisposition = enum { pending, slow_down, failed };

fn devicePollDisposition(
    allocator: std.mem.Allocator,
    status: u16,
    body: []const u8,
) PollDisposition {
    if (status == 403 or status == 404) return .pending;
    if (status == 429) return .slow_down;
    const ErrorResponse = struct { @"error": std.json.Value };
    var parsed = std.json.parseFromSlice(ErrorResponse, allocator, body, .{
        .ignore_unknown_fields = true,
        .max_value_len = 64 * 1024,
    }) catch return .failed;
    defer parsed.deinit();
    const code = switch (parsed.value.@"error") {
        .string => |value| value,
        .object => |object| code: {
            const value = object.get("code") orelse return .failed;
            if (value != .string) return .failed;
            break :code value.string;
        },
        else => return .failed,
    };
    if (std.mem.eql(u8, code, "deviceauth_authorization_pending")) return .pending;
    if (std.mem.eql(u8, code, "slow_down")) return .slow_down;
    return .failed;
}

const AuthorizationInput = struct {
    code: []u8,
    state: ?[]u8 = null,
};

fn parseAuthorizationInput(
    allocator: std.mem.Allocator,
    source: []const u8,
) oauth_api.Error!AuthorizationInput {
    const value = std.mem.trim(u8, source, " \t\r\n");
    if (value.len == 0 or value.len > 64 * 1024) return error.InvalidResponse;
    if (std.mem.findScalar(u8, value, '#')) |separator| {
        return .{
            .code = try decodeComponent(allocator, value[0..separator]),
            .state = try decodeComponent(allocator, value[separator + 1 ..]),
        };
    }
    const query_source = if (std.mem.findScalar(u8, value, '?')) |separator|
        value[separator + 1 ..]
    else if (std.mem.find(u8, value, "code=") != null)
        value
    else
        return .{ .code = allocator.dupe(u8, value) catch return error.OutOfMemory };
    const code = try queryValue(allocator, query_source, "code") orelse return error.InvalidResponse;
    errdefer allocator.free(code);
    return .{ .code = code, .state = try queryValue(allocator, query_source, "state") };
}

fn queryValue(
    allocator: std.mem.Allocator,
    query: []const u8,
    name: []const u8,
) oauth_api.Error!?[]u8 {
    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        const separator = std.mem.findScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..separator], name)) {
            return @as(?[]u8, try decodeComponent(allocator, pair[separator + 1 ..]));
        }
    }
    return null;
}

fn decodeComponent(allocator: std.mem.Allocator, source: []const u8) oauth_api.Error![]u8 {
    const output = allocator.alloc(u8, source.len) catch return error.OutOfMemory;
    errdefer allocator.free(output);
    var input_index: usize = 0;
    var output_index: usize = 0;
    while (input_index < source.len) {
        if (source[input_index] == '%') {
            if (input_index + 2 >= source.len) return error.InvalidResponse;
            const high = std.fmt.charToDigit(source[input_index + 1], 16) catch return error.InvalidResponse;
            const low = std.fmt.charToDigit(source[input_index + 2], 16) catch return error.InvalidResponse;
            output[output_index] = @intCast(high * 16 + low);
            input_index += 3;
        } else {
            output[output_index] = if (source[input_index] == '+') ' ' else source[input_index];
            input_index += 1;
        }
        output_index += 1;
    }
    return allocator.realloc(output, output_index) catch return error.OutOfMemory;
}

fn exchangeAuthorizationCode(
    result_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    io: std.Io,
    transport: transport_api.Transport,
    code: []const u8,
    verifier: []const u8,
    redirect: []const u8,
    now_ms: u64,
    cancellation: ?*const model_api.CancellationToken,
) oauth_api.Error!oauth_api.Refreshed {
    var body: std.Io.Writer.Allocating = .init(scratch_allocator);
    defer {
        std.crypto.secureZero(u8, body.written());
        body.deinit();
    }
    var form: Form = .{};
    form.append(&body.writer, "grant_type", "authorization_code") catch return error.OutOfMemory;
    form.append(&body.writer, "client_id", client_id) catch return error.OutOfMemory;
    form.append(&body.writer, "code", code) catch return error.OutOfMemory;
    form.append(&body.writer, "code_verifier", verifier) catch return error.OutOfMemory;
    form.append(&body.writer, "redirect_uri", redirect) catch return error.OutOfMemory;
    const response = try exchangeForm(
        scratch_allocator,
        io,
        transport,
        body.written(),
        cancellation,
    );
    defer wipeResponse(scratch_allocator, response.body);
    if (response.status < 200 or response.status >= 300) return error.Rejected;
    return parseTokenResponse(result_allocator, scratch_allocator, response.body, now_ms);
}

fn wipeResponse(allocator: std.mem.Allocator, body: []const u8) void {
    if (body.len == 0) return;
    const mutable = @constCast(body);
    std.crypto.secureZero(u8, mutable);
    allocator.free(mutable);
}

fn exchangeForm(
    allocator: std.mem.Allocator,
    io: std.Io,
    transport: transport_api.Transport,
    body: []const u8,
    cancellation: ?*const model_api.CancellationToken,
) oauth_api.Error!transport_api.Response {
    return transport.exchange(allocator, io, .{
        .method = .POST,
        .url = token_url,
        .headers = &.{.{ .name = "content-type", .value = "application/x-www-form-urlencoded" }},
        .body = body,
        .max_response_bytes = max_response_bytes,
        .deadline = std.Io.Clock.Timestamp.fromNow(io, .{
            .raw = .fromSeconds(15),
            .clock = .awake,
        }),
        .cancellation = cancellation,
    }, .buffered);
}

fn exchangeJson(
    allocator: std.mem.Allocator,
    io: std.Io,
    transport: transport_api.Transport,
    url: []const u8,
    body: []const u8,
    cancellation: ?*const model_api.CancellationToken,
) oauth_api.Error!transport_api.Response {
    return transport.exchange(allocator, io, .{
        .method = .POST,
        .url = url,
        .headers = &.{.{ .name = "content-type", .value = "application/json" }},
        .body = body,
        .max_response_bytes = max_response_bytes,
        .deadline = std.Io.Clock.Timestamp.fromNow(io, .{
            .raw = .fromSeconds(15),
            .clock = .awake,
        }),
        .cancellation = cancellation,
    }, .buffered);
}

fn parseInterval(value: std.json.Value) ?u64 {
    return switch (value) {
        .integer => |integer| if (integer >= 0) @intCast(integer) else null,
        .string => |string| std.fmt.parseInt(u64, std.mem.trim(u8, string, " \t\r\n"), 10) catch null,
        else => null,
    };
}

fn mapParseFailure(failure: anyerror) oauth_api.Error {
    return if (failure == error.OutOfMemory) error.OutOfMemory else error.InvalidResponse;
}

fn parseTokenResponse(
    result_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    body: []const u8,
    now_ms: u64,
) oauth_api.Error!oauth_api.Refreshed {
    BoundedJson.validate(scratch_allocator, body, .{
        .document_bytes = max_response_bytes,
        .value_bytes = 64 * 1024,
        .depth = 3,
        .collection_items = 32,
    }) catch |failure| return mapParseFailure(failure);
    const TokenResponse = struct {
        access_token: []const u8,
        refresh_token: []const u8,
        expires_in: u64,
    };
    var parsed = std.json.parseFromSlice(TokenResponse, scratch_allocator, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
        .max_value_len = 64 * 1024,
    }) catch |failure| return mapParseFailure(failure);
    defer {
        std.crypto.secureZero(u8, @constCast(parsed.value.access_token));
        std.crypto.secureZero(u8, @constCast(parsed.value.refresh_token));
        parsed.deinit();
    }
    if (parsed.value.access_token.len == 0 or parsed.value.refresh_token.len == 0 or
        parsed.value.expires_in == 0)
    {
        return error.InvalidResponse;
    }
    const duration_ms = std.math.mul(u64, parsed.value.expires_in, 1000) catch
        return error.InvalidResponse;
    const expires_at_ms = std.math.add(u64, now_ms, duration_ms) catch return error.InvalidResponse;
    var arena = std.heap.ArenaAllocator.init(result_allocator);
    errdefer arena.deinit();
    const owned = arena.allocator();
    const access = owned.dupe(u8, parsed.value.access_token) catch return error.OutOfMemory;
    errdefer std.crypto.secureZero(u8, access);
    const refresh_token = owned.dupe(u8, parsed.value.refresh_token) catch return error.OutOfMemory;
    errdefer std.crypto.secureZero(u8, refresh_token);
    const account_id = accountIdFromJwt(owned, access) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidToken => error.InvalidResponse,
    };
    errdefer std.crypto.secureZero(u8, account_id);
    return .{ .arena = arena, .credential = .{
        .access = access,
        .refresh = refresh_token,
        .expires_at_ms = expires_at_ms,
        .account_id = account_id,
    } };
}

pub const AccountIdError = error{ OutOfMemory, InvalidToken };

pub fn accountIdFromJwt(
    allocator: std.mem.Allocator,
    access_token: []const u8,
) AccountIdError![]u8 {
    var segments = std.mem.splitScalar(u8, access_token, '.');
    _ = segments.next() orelse return error.InvalidToken;
    const payload_segment = segments.next() orelse return error.InvalidToken;
    if (segments.next() == null or segments.next() != null) return error.InvalidToken;
    const decoded_size = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload_segment) catch
        return error.InvalidToken;
    const decoded = allocator.alloc(u8, decoded_size) catch return error.OutOfMemory;
    defer {
        std.crypto.secureZero(u8, decoded);
        allocator.free(decoded);
    }
    std.base64.url_safe_no_pad.Decoder.decode(decoded, payload_segment) catch return error.InvalidToken;
    const Claims = struct {
        @"https://api.openai.com/auth": struct {
            chatgpt_account_id: []const u8,
        },
    };
    var parsed = std.json.parseFromSlice(Claims, allocator, decoded, .{
        .ignore_unknown_fields = true,
        .max_value_len = 64 * 1024,
    }) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidToken,
    };
    defer parsed.deinit();
    const account_id = parsed.value.@"https://api.openai.com/auth".chatgpt_account_id;
    if (account_id.len == 0) return error.InvalidToken;
    defer std.crypto.secureZero(u8, @constCast(account_id));
    return allocator.dupe(u8, account_id) catch return error.OutOfMemory;
}

const Form = struct {
    first: bool = true,

    fn append(self: *Form, writer: *std.Io.Writer, key: []const u8, value: []const u8) !void {
        if (!self.first) try writer.writeByte('&');
        self.first = false;
        try percentEncode(writer, key);
        try writer.writeByte('=');
        try percentEncode(writer, value);
    }
};

fn percentEncode(writer: *std.Io.Writer, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try writer.writeByte(byte);
        } else {
            try writer.writeByte('%');
            try writer.writeByte(hex[byte >> 4]);
            try writer.writeByte(hex[byte & 0x0f]);
        }
    }
}

fn testAccessToken(allocator: std.mem.Allocator, account_id: []const u8) ![]u8 {
    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"https://api.openai.com/auth\":{{\"chatgpt_account_id\":\"{s}\"}}}}",
        .{account_id},
    );
    defer allocator.free(payload);
    const encoded = try allocator.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(payload.len));
    defer allocator.free(encoded);
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, payload);
    return std.fmt.allocPrint(allocator, "header.{s}.signature", .{encoded});
}

const TestInteraction = struct {
    saw_auth_url: bool = false,
    saw_device_code: bool = false,
    prompt_value: []const u8 = "authorization-code",

    fn notify(context: *anyopaque, event: oauth_api.Event) anyerror!void {
        const self: *TestInteraction = @ptrCast(@alignCast(context));
        switch (event) {
            .auth_url => |auth_url| {
                if (!std.mem.startsWith(u8, auth_url.url, authorize_url ++ "?")) return error.Rejected;
                if (std.mem.find(u8, auth_url.url, "code_challenge_method=S256") == null) {
                    return error.Rejected;
                }
                self.saw_auth_url = true;
            },
            .device_code => |device| {
                if (!std.mem.eql(u8, device.user_code, "ABCD-EFGH")) return error.Rejected;
                if (!std.mem.eql(u8, device.verification_uri, device_verification_uri)) {
                    return error.Rejected;
                }
                self.saw_device_code = true;
            },
        }
    }

    // Context leads because this callback implements the interaction ABI.
    // ziglint-ignore: Z023
    fn prompt(
        context: *anyopaque,
        allocator: std.mem.Allocator, // ziglint-ignore: Z023
        _: oauth_api.Prompt,
    ) anyerror![]u8 {
        const self: *TestInteraction = @ptrCast(@alignCast(context));
        return allocator.dupe(u8, self.prompt_value);
    }

    fn interaction(self: *TestInteraction) oauth_api.Interaction {
        const vtable: oauth_api.Interaction.VTable = .{
            .notify = notify,
            .prompt = prompt,
        };
        return .{ .context = self, .vtable = &vtable };
    }
};

fn refreshAndDeinit(allocator: std.mem.Allocator) !void {
    const response =
        "{\"access_token\":\"header." ++
        "eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjb3VudCJ9fQ" ++
        ".signature\",\"refresh_token\":\"rotated\",\"expires_in\":3600}";
    const exchanges = [_]fake_transport.Exchange{.{ .response = .{
        .status = 200,
        .body = response,
    } }};
    var fake = fake_transport.FakeTransport.init(&exchanges);
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const implementation: OAuth = .{};
    var refreshed = try implementation.refresher().refresh(
        allocator,
        scratch.allocator(),
        std.testing.io,
        fake.transport(),
        .{
            .credential = .{
                .access = "old-access",
                .refresh = "old-refresh",
                .expires_at_ms = 1,
            },
            .now_ms = 1000,
        },
    );
    refreshed.deinit();
}

test "Codex login honors cancellation before interaction or transport" {
    var token: model_api.CancellationToken = .{};
    token.cancel();
    var fake = fake_transport.FakeTransport.init(&.{});
    var interaction: TestInteraction = .{};
    const implementation: OAuth = .{};
    try std.testing.expectError(error.Cancelled, implementation.authenticator().login(
        std.testing.allocator,
        std.testing.allocator,
        std.testing.io,
        fake.transport(),
        .{
            .method = .browser,
            .interaction = interaction.interaction(),
            .now_ms = 1000,
            .cancellation = &token,
        },
    ));
    try std.testing.expect(!interaction.saw_auth_url);
    try std.testing.expectEqual(@as(usize, 0), fake.next_index);
}

test "Codex browser login emits PKCE authorization and exchanges a manual code" {
    const access = try testAccessToken(std.testing.allocator, "browser-account");
    defer std.testing.allocator.free(access);
    const token_response = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"access_token\":\"{s}\",\"refresh_token\":\"browser-refresh\",\"expires_in\":3600}}",
        .{access},
    );
    defer std.testing.allocator.free(token_response);
    const exchanges = [_]fake_transport.Exchange{.{ .response = .{
        .status = 200,
        .body = token_response,
    } }};
    var fake = fake_transport.FakeTransport.init(&exchanges);
    var interaction: TestInteraction = .{};
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    const implementation: OAuth = .{};
    var credential = try implementation.authenticator().login(
        std.testing.allocator,
        scratch.allocator(),
        std.testing.io,
        fake.transport(),
        .{
            .method = .browser,
            .interaction = interaction.interaction(),
            .now_ms = 1000,
        },
    );
    defer credential.deinit();
    try std.testing.expect(interaction.saw_auth_url);
    try std.testing.expectEqualStrings("browser-account", credential.credential.account_id.?);
}

test "Codex device login polls and exchanges the authorization grant" {
    const access = try testAccessToken(std.testing.allocator, "device-account");
    defer std.testing.allocator.free(access);
    const token_response = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"access_token\":\"{s}\",\"refresh_token\":\"device-refresh\",\"expires_in\":3600}}",
        .{access},
    );
    defer std.testing.allocator.free(token_response);
    const exchanges = [_]fake_transport.Exchange{
        .{ .response = .{
            .status = 200,
            .body = "{\"device_auth_id\":\"device-id\",\"user_code\":\"ABCD-EFGH\",\"interval\":0}",
        } },
        .{ .response = .{
            .status = 200,
            .body = "{\"authorization_code\":\"authorization-code\",\"code_verifier\":\"verifier\"}",
        } },
        .{ .response = .{ .status = 200, .body = token_response } },
    };
    var fake = fake_transport.FakeTransport.init(&exchanges);
    var interaction: TestInteraction = .{};
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    const implementation: OAuth = .{};
    var credential = try implementation.authenticator().login(
        std.testing.allocator,
        scratch.allocator(),
        std.testing.io,
        fake.transport(),
        .{
            .method = .device_code,
            .interaction = interaction.interaction(),
            .now_ms = 1000,
        },
    );
    defer credential.deinit();
    try std.testing.expect(interaction.saw_device_code);
    try std.testing.expectEqualStrings("device-account", credential.credential.account_id.?);
    try std.testing.expectEqual(@as(usize, 3), fake.next_index);
}

test "Codex OAuth refresh settles every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, refreshAndDeinit, .{});
}

test "Codex OAuth refresh rotates tokens and extracts the account identity" {
    const Inspector = struct {
        fn inspect(_: *anyopaque, request: transport_api.Request) error{Rejected}!void {
            if (!std.mem.eql(u8, request.url, token_url)) return error.Rejected;
            if (request.method != .POST) return error.Rejected;
            var content_type = false;
            for (request.headers) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "content-type") and
                    std.mem.eql(u8, header.value, "application/x-www-form-urlencoded")) content_type = true;
            }
            if (!content_type) return error.Rejected;
            const expected = "grant_type=refresh_token&refresh_token=old%20refresh%2B%2F%3F&client_id=" ++ client_id;
            if (!std.mem.eql(u8, request.body, expected)) return error.Rejected;
            if (request.max_response_bytes != max_response_bytes or request.deadline == null) {
                return error.Rejected;
            }
        }
    };
    const access = try testAccessToken(std.testing.allocator, "account-123");
    defer std.testing.allocator.free(access);
    const response_body = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"access_token\":\"{s}\",\"refresh_token\":\"rotated\",\"expires_in\":3600}}",
        .{access},
    );
    defer std.testing.allocator.free(response_body);
    const exchanges = [_]fake_transport.Exchange{.{ .response = .{
        .status = 200,
        .body = response_body,
    } }};
    var fake = fake_transport.FakeTransport.init(&exchanges);
    var inspector_context: u8 = 0;
    fake.inspector = .{ .context = &inspector_context, .inspect_fn = Inspector.inspect };
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    const implementation: OAuth = .{};
    var refreshed = try implementation.refresher().refresh(
        std.testing.allocator,
        scratch.allocator(),
        std.testing.io,
        fake.transport(),
        .{
            .credential = .{
                .access = "old-access",
                .refresh = "old refresh+/?",
                .expires_at_ms = 1,
            },
            .now_ms = 1000,
        },
    );
    defer refreshed.deinit();

    try std.testing.expectEqualStrings(access, refreshed.credential.access);
    try std.testing.expectEqualStrings("rotated", refreshed.credential.refresh);
    try std.testing.expectEqual(@as(u64, 3_601_000), refreshed.credential.expires_at_ms);
    try std.testing.expectEqualStrings("account-123", refreshed.credential.account_id.?);
    try std.testing.expectEqual(@as(usize, 1), fake.next_index);
}
