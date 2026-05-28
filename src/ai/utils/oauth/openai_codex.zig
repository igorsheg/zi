const std = @import("std");
const http_utils = @import("../http.zig");
const mem = @import("../../../mem/root.zig");
const oauth = @import("root.zig");

pub const callback_host = "127.0.0.1";
pub const callback_port: u16 = 1455;
pub const client_id = "app_EMoamEEZ73f0CkXaXp7hrann";
pub const authorize_url = "https://auth.openai.com/oauth/authorize";
pub const token_url = "https://auth.openai.com/oauth/token";
pub const redirect_uri = "http://localhost:1455/auth/callback";
pub const scope = "openid profile email offline_access";
pub const jwt_claim_path = "https://api.openai.com/auth";

const read_buffer_len = 8192;
const redirect_buffer_len = 0;
const max_error_body_bytes = 16 * 1024;
const callback_read_buffer_len = 4096;
const callback_write_buffer_len = 4096;

pub const AuthorizationFlow = struct {
    verifier: []u8,
    state: []u8,
    url: []u8,

    pub fn deinit(self: *AuthorizationFlow, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        allocator.free(self.state);
        allocator.free(self.verifier);
        self.* = undefined;
    }
};

pub const AuthorizationInput = struct {
    code: ?[]const u8 = null,
    state: ?[]const u8 = null,
};

pub const openai_codex_oauth_provider: oauth.OAuthProviderInterface = .{
    .id = "openai-codex",
    .name = "ChatGPT Plus/Pro (Codex Subscription)",
    .uses_callback_server = true,
    .login_fn = login,
    .refresh_token_fn = refreshToken,
    .get_api_key_fn = getApiKey,
};

pub fn createAuthorizationFlow(
    allocator: std.mem.Allocator,
    random: std.Random,
    originator: []const u8,
) !AuthorizationFlow {
    var pkce = try oauth.generatePkce(allocator, random);
    errdefer pkce.deinit(allocator);
    const state = try createState(allocator, random);
    errdefer allocator.free(state);
    const url = try authorizationUrl(allocator, pkce.challenge, state, originator);
    allocator.free(pkce.challenge);
    return .{ .verifier = pkce.verifier, .state = state, .url = url };
}

pub fn parseAuthorizationInput(input: []const u8) AuthorizationInput {
    const value = std.mem.trim(u8, input, &std.ascii.whitespace);
    if (value.len == 0) return .{};

    if (std.mem.find(u8, value, "code=")) |_| {
        return parseQuery(value);
    }
    if (std.mem.findScalar(u8, value, '#')) |separator| {
        return .{ .code = value[0..separator], .state = value[separator + 1 ..] };
    }
    return .{ .code = value };
}

pub fn getAccountId(allocator: std.mem.Allocator, access_token: []const u8) !?[]u8 {
    const payload_segment = jwtPayloadSegment(access_token) orelse return null;
    const decoded = try decodeBase64Url(allocator, payload_segment);
    defer allocator.free(decoded);

    var parsed = mem.Owned(std.json.Value).parseJson(allocator, decoded, .{}) catch return null;
    defer parsed.deinit();
    const auth = parsed.value.object.get(jwt_claim_path) orelse return null;
    if (auth != .object) return null;
    const account_id = auth.object.get("chatgpt_account_id") orelse return null;
    if (account_id != .string or account_id.string.len == 0) return null;
    const owned_account_id = try allocator.dupe(u8, account_id.string);
    return owned_account_id;
}

fn createState(allocator: std.mem.Allocator, random: std.Random) ![]u8 {
    var bytes: [16]u8 = undefined;
    random.bytes(&bytes);
    const alphabet = "0123456789abcdef";
    const state = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |byte, index| {
        state[index * 2] = alphabet[byte >> 4];
        state[index * 2 + 1] = alphabet[byte & 0x0f];
    }
    return state;
}

fn authorizationUrl(
    allocator: std.mem.Allocator,
    challenge: []const u8,
    state: []const u8,
    originator: []const u8,
) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll(authorize_url ++ "?");
    try appendParam(&writer.writer, "response_type", "code", false);
    try appendParam(&writer.writer, "client_id", client_id, true);
    try appendParam(&writer.writer, "redirect_uri", redirect_uri, true);
    try appendParam(&writer.writer, "scope", scope, true);
    try appendParam(&writer.writer, "code_challenge", challenge, true);
    try appendParam(&writer.writer, "code_challenge_method", "S256", true);
    try appendParam(&writer.writer, "state", state, true);
    try appendParam(&writer.writer, "id_token_add_organizations", "true", true);
    try appendParam(&writer.writer, "codex_cli_simplified_flow", "true", true);
    try appendParam(&writer.writer, "originator", originator, true);
    return writer.toOwnedSlice();
}

fn appendParam(writer: *std.Io.Writer, key: []const u8, value: []const u8, separator: bool) !void {
    if (separator) try writer.writeByte('&');
    try percentEncode(writer, key);
    try writer.writeByte('=');
    try percentEncode(writer, value);
}

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

fn parseQuery(value: []const u8) AuthorizationInput {
    const query = if (std.mem.findScalar(u8, value, '?')) |index| value[index + 1 ..] else value;
    var out: AuthorizationInput = .{};
    var iterator = std.mem.splitScalar(u8, query, '&');
    while (iterator.next()) |part| {
        const equals = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        const key = part[0..equals];
        const field_value = part[equals + 1 ..];
        if (std.mem.eql(u8, key, "code")) out.code = field_value;
        if (std.mem.eql(u8, key, "state")) out.state = field_value;
    }
    return out;
}

fn jwtPayloadSegment(token: []const u8) ?[]const u8 {
    const first = std.mem.indexOfScalar(u8, token, '.') orelse return null;
    const rest = token[first + 1 ..];
    const second_relative = std.mem.indexOfScalar(u8, rest, '.') orelse return null;
    const payload = rest[0..second_relative];
    if (payload.len == 0) return null;
    return payload;
}

fn decodeBase64Url(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const output = try allocator.alloc(u8, try decoder.calcSizeForSlice(encoded));
    errdefer allocator.free(output);
    try decoder.decode(output, encoded);
    return output;
}

fn login(
    allocator: std.mem.Allocator,
    io: std.Io,
    _: ?*anyopaque,
    callbacks: oauth.OAuthLoginCallbacks,
) !oauth.OAuthCredentials {
    var attempt = try beginLogin(allocator, io, callbacks);
    defer attempt.deinit(allocator, io);

    const code = try waitForLoginCode(allocator, io, callbacks, &attempt);
    defer allocator.free(code);
    return completeLogin(allocator, io, &attempt, code);
}

const LoginAttempt = struct {
    flow: AuthorizationFlow,
    callback_server: ?CallbackServer,

    fn deinit(self: *LoginAttempt, allocator: std.mem.Allocator, io: std.Io) void {
        if (self.callback_server) |*server| server.deinit(io);
        self.flow.deinit(allocator);
        self.* = undefined;
    }
};

fn beginLogin(
    allocator: std.mem.Allocator,
    io: std.Io,
    callbacks: oauth.OAuthLoginCallbacks,
) !LoginAttempt {
    var prng = std.Random.DefaultPrng.init(@intCast(std.Io.Clock.awake.now(io).nanoseconds));
    var flow = try createAuthorizationFlow(allocator, prng.random(), "zi");
    errdefer flow.deinit(allocator);

    var callback_server = CallbackServer.start(io) catch null;
    errdefer if (callback_server) |*server| server.deinit(io);

    try callbacks.onAuth(.{
        .url = flow.url,
        .instructions = "Complete login in the browser. If callback capture fails, paste the redirect URL or code.",
    });

    return .{ .flow = flow, .callback_server = callback_server };
}

fn waitForLoginCode(
    allocator: std.mem.Allocator,
    io: std.Io,
    callbacks: oauth.OAuthLoginCallbacks,
    attempt: *LoginAttempt,
) ![]const u8 {
    if (attempt.callback_server) |*server| {
        if (callbacks.on_manual_code_input_fn != null) {
            return raceLoginCode(allocator, callbacks, server, attempt.flow.state);
        }
        return server.waitForCode(allocator, io, attempt.flow.state) catch
            promptForCode(allocator, callbacks, attempt.flow.state);
    }
    if (try callbacks.onManualCodeInput()) |manual| {
        return codeFromInput(allocator, manual, attempt.flow.state);
    }
    return promptForCode(allocator, callbacks, attempt.flow.state);
}

const LoginCodeResult = anyerror![]const u8;

const LoginCodeCompletion = union(enum) {
    callback: LoginCodeResult,
    manual: LoginCodeResult,
};

fn raceLoginCode(
    allocator: std.mem.Allocator,
    callbacks: oauth.OAuthLoginCallbacks,
    server: *CallbackServer,
    expected_state: []const u8,
) ![]const u8 {
    var threaded = std.Io.Threaded.init(allocator, .{ .concurrent_limit = .limited(2) });
    defer threaded.deinit();
    const race_io = threaded.io();

    var completions_buffer: [2]LoginCodeCompletion = undefined;
    var select = std.Io.Select(LoginCodeCompletion).init(race_io, &completions_buffer);
    try select.concurrent(.callback, waitForCallbackCode, .{ allocator, race_io, server, expected_state });
    try select.concurrent(.manual, waitForManualCode, .{ allocator, callbacks, expected_state });

    const winner = try select.await();
    defer drainLoginCodeLosers(allocator, &select);
    return switch (winner) {
        .callback => |result| result,
        .manual => |result| result,
    };
}

fn waitForCallbackCode(
    allocator: std.mem.Allocator,
    io: std.Io,
    server: *CallbackServer,
    expected_state: []const u8,
) LoginCodeResult {
    return server.waitForCode(allocator, io, expected_state);
}

fn waitForManualCode(
    allocator: std.mem.Allocator,
    callbacks: oauth.OAuthLoginCallbacks,
    expected_state: []const u8,
) LoginCodeResult {
    const manual = (try callbacks.onManualCodeInput()) orelse return error.ManualOAuthInputUnavailable;
    return codeFromInput(allocator, manual, expected_state);
}

fn drainLoginCodeLosers(allocator: std.mem.Allocator, select: *std.Io.Select(LoginCodeCompletion)) void {
    while (select.cancel()) |completion| {
        switch (completion) {
            .callback => |result| if (result) |code| allocator.free(code) else |_| {},
            .manual => |result| if (result) |code| allocator.free(code) else |_| {},
        }
    }
}

fn completeLogin(
    allocator: std.mem.Allocator,
    io: std.Io,
    attempt: *LoginAttempt,
    code: []const u8,
) !oauth.OAuthCredentials {
    return exchangeAuthorizationCode(allocator, io, code, attempt.flow.verifier);
}

const CallbackServer = struct {
    server: std.Io.net.Server,

    fn start(io: std.Io) !CallbackServer {
        const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(callback_port) };
        return .{ .server = try address.listen(io, .{ .reuse_address = true }) };
    }

    fn deinit(self: *CallbackServer, io: std.Io) void {
        self.server.deinit(io);
        self.* = undefined;
    }

    fn waitForCode(
        self: *CallbackServer,
        allocator: std.mem.Allocator,
        io: std.Io,
        expected_state: []const u8,
    ) ![]const u8 {
        var stream = try self.server.accept(io);
        defer stream.close(io);
        var read_buffer: [callback_read_buffer_len]u8 = undefined;
        var write_buffer: [callback_write_buffer_len]u8 = undefined;
        var reader = stream.reader(io, &read_buffer);
        var writer = stream.writer(io, &write_buffer);
        var http_server = std.http.Server.init(&reader.interface, &writer.interface);
        var request = try http_server.receiveHead();
        if (!std.mem.startsWith(u8, request.head.target, "/auth/callback")) {
            const html = try oauth.oauthErrorHtml(allocator, "Callback route not found.", null);
            defer allocator.free(html);
            try request.respond(html, .{ .status = .not_found });
            return error.CallbackRouteNotFound;
        }
        const input = parseAuthorizationInput(request.head.target);
        if (input.state == null or !std.mem.eql(u8, input.state.?, expected_state)) {
            const html = try oauth.oauthErrorHtml(allocator, "State mismatch.", null);
            defer allocator.free(html);
            try request.respond(html, .{ .status = .bad_request });
            return error.StateMismatch;
        }
        const code = input.code orelse {
            const html = try oauth.oauthErrorHtml(allocator, "Missing authorization code.", null);
            defer allocator.free(html);
            try request.respond(html, .{ .status = .bad_request });
            return error.MissingAuthorizationCode;
        };
        const owned_code = try allocator.dupe(u8, code);
        errdefer allocator.free(owned_code);
        const html = try oauth.oauthSuccessHtml(
            allocator,
            "OpenAI authentication completed. You can close this window.",
        );
        defer allocator.free(html);
        try request.respond(html, .{});
        return owned_code;
    }
};

fn promptForCode(
    allocator: std.mem.Allocator,
    callbacks: oauth.OAuthLoginCallbacks,
    expected_state: []const u8,
) ![]const u8 {
    const input = try callbacks.onPrompt(.{ .message = "Paste the OpenAI Codex authorization code or redirect URL:" });
    return codeFromInput(allocator, input, expected_state);
}

fn codeFromInput(allocator: std.mem.Allocator, input: []const u8, expected_state: []const u8) ![]const u8 {
    const parsed = parseAuthorizationInput(input);
    if (parsed.state) |state| if (!std.mem.eql(u8, state, expected_state)) return error.StateMismatch;
    const code = parsed.code orelse return error.MissingAuthorizationCode;
    return allocator.dupe(u8, code);
}

fn refreshToken(
    allocator: std.mem.Allocator,
    io: std.Io,
    _: ?*anyopaque,
    credentials: oauth.OAuthCredentials,
) !oauth.OAuthCredentials {
    return refreshAccessToken(allocator, io, credentials.refresh);
}

fn exchangeAuthorizationCode(
    allocator: std.mem.Allocator,
    io: std.Io,
    code: []const u8,
    verifier: []const u8,
) !oauth.OAuthCredentials {
    var body = std.Io.Writer.Allocating.init(allocator);
    defer body.deinit();
    try appendParam(&body.writer, "grant_type", "authorization_code", false);
    try appendParam(&body.writer, "client_id", client_id, true);
    try appendParam(&body.writer, "code", code, true);
    try appendParam(&body.writer, "code_verifier", verifier, true);
    try appendParam(&body.writer, "redirect_uri", redirect_uri, true);
    return requestToken(allocator, io, body.written());
}

fn refreshAccessToken(allocator: std.mem.Allocator, io: std.Io, refresh_token: []const u8) !oauth.OAuthCredentials {
    var body = std.Io.Writer.Allocating.init(allocator);
    defer body.deinit();
    try appendParam(&body.writer, "grant_type", "refresh_token", false);
    try appendParam(&body.writer, "refresh_token", refresh_token, true);
    try appendParam(&body.writer, "client_id", client_id, true);
    return requestToken(allocator, io, body.written());
}

fn requestToken(allocator: std.mem.Allocator, io: std.Io, body: []const u8) !oauth.OAuthCredentials {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    const uri = try std.Uri.parse(token_url);
    var req = try client.request(.POST, uri, .{
        .headers = .{
            .content_type = .{ .override = "application/x-www-form-urlencoded" },
            .accept_encoding = .omit,
        },
        .redirect_behavior = .unhandled,
        .keep_alive = false,
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = body.len };
    var body_writer = try req.sendBodyUnflushed(&.{});
    try body_writer.writer.writeAll(body);
    try body_writer.end();
    try req.connection.?.flush();

    var redirects: [redirect_buffer_len]u8 = .{};
    var response = try req.receiveHead(&redirects);
    var transfer_buffer: [read_buffer_len]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    const response_body = try http_utils.readBoundedBody(allocator, reader, max_error_body_bytes);
    defer allocator.free(response_body);
    if (response.head.status != .ok) return error.TokenRequestFailed;
    return parseTokenResponse(allocator, io, response_body);
}

fn parseTokenResponse(allocator: std.mem.Allocator, io: std.Io, body: []const u8) !oauth.OAuthCredentials {
    var parsed = try mem.Owned(std.json.Value).parseJson(allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidTokenResponse;
    const object = parsed.value.object;
    const access = jsonString(object.get("access_token")) orelse return error.InvalidTokenResponse;
    const refresh = jsonString(object.get("refresh_token")) orelse return error.InvalidTokenResponse;
    const expires_in = jsonI64(object.get("expires_in")) orelse return error.InvalidTokenResponse;
    const account_id = try getAccountId(allocator, access) orelse return error.MissingAccountId;
    allocator.free(account_id);
    const now_ms: i64 = @intCast(@divTrunc(std.Io.Clock.awake.now(io).nanoseconds, 1_000_000));
    return .{
        .access = try allocator.dupe(u8, access),
        .refresh = try allocator.dupe(u8, refresh),
        .expires = now_ms + expires_in * 1000,
    };
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const resolved = value orelse return null;
    return switch (resolved) {
        .string => |string| string,
        else => null,
    };
}

fn jsonI64(value: ?std.json.Value) ?i64 {
    const resolved = value orelse return null;
    return switch (resolved) {
        .integer => |integer| if (integer >= 0 and integer <= std.math.maxInt(i64)) @intCast(integer) else null,
        .float => |float| if (float >= 0 and float <= @as(f64, @floatFromInt(std.math.maxInt(i64))))
            @intFromFloat(float)
        else
            null,
        else => null,
    };
}

fn getApiKey(_: ?*anyopaque, credentials: oauth.OAuthCredentials) ![]const u8 {
    return credentials.access;
}

test "authorization flow builds codex authorization url with pkce challenge and state" {
    var prng = std.Random.DefaultPrng.init(1);
    var flow = try createAuthorizationFlow(std.testing.allocator, prng.random(), "zi");
    defer flow.deinit(std.testing.allocator);

    try std.testing.expect(flow.verifier.len > 0);
    try std.testing.expectEqual(@as(usize, 32), flow.state.len);
    try std.testing.expect(std.mem.startsWith(u8, flow.url, authorize_url));
    try std.testing.expect(std.mem.indexOf(u8, flow.url, "client_id=app_EMoamEEZ73f0CkXaXp7hrann") != null);
    try std.testing.expect(std.mem.indexOf(u8, flow.url, "code_challenge_method=S256") != null);
    try std.testing.expect(std.mem.indexOf(u8, flow.url, "originator=zi") != null);
}

test "parse authorization input accepts url query fragment and raw code" {
    const url = parseAuthorizationInput("http://localhost:1455/auth/callback?code=abc&state=xyz");
    try std.testing.expectEqualStrings("abc", url.code.?);
    try std.testing.expectEqualStrings("xyz", url.state.?);

    const fragment = parseAuthorizationInput("abc#xyz");
    try std.testing.expectEqualStrings("abc", fragment.code.?);
    try std.testing.expectEqualStrings("xyz", fragment.state.?);

    const raw = parseAuthorizationInput(" abc ");
    try std.testing.expectEqualStrings("abc", raw.code.?);
}

test "get account id extracts openai auth claim from jwt payload" {
    const payload =
        \\{"https://api.openai.com/auth":{"chatgpt_account_id":"acct_123"}}
    ;
    const encoded_payload = try oauth.pkce.base64UrlEncode(std.testing.allocator, payload);
    defer std.testing.allocator.free(encoded_payload);
    const token = try std.fmt.allocPrint(std.testing.allocator, "header.{s}.signature", .{encoded_payload});
    defer std.testing.allocator.free(token);

    const account_id = (try getAccountId(std.testing.allocator, token)).?;
    defer std.testing.allocator.free(account_id);
    try std.testing.expectEqualStrings("acct_123", account_id);
}

test "token response validates account id and owns credentials" {
    const payload =
        \\{"https://api.openai.com/auth":{"chatgpt_account_id":"acct_123"}}
    ;
    const encoded_payload = try oauth.pkce.base64UrlEncode(std.testing.allocator, payload);
    defer std.testing.allocator.free(encoded_payload);
    const access = try std.fmt.allocPrint(std.testing.allocator, "header.{s}.signature", .{encoded_payload});
    defer std.testing.allocator.free(access);
    const body = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"access_token\":\"{s}\",\"refresh_token\":\"refresh\",\"expires_in\":60}}",
        .{access},
    );
    defer std.testing.allocator.free(body);

    const credentials = try parseTokenResponse(std.testing.allocator, std.testing.io, body);
    defer std.testing.allocator.free(credentials.access);
    defer std.testing.allocator.free(credentials.refresh);

    try std.testing.expectEqualStrings(access, credentials.access);
    try std.testing.expectEqualStrings("refresh", credentials.refresh);
    try std.testing.expect(credentials.expires > 0);
}

test "openai codex provider exposes access token as api key" {
    const api_key = try openai_codex_oauth_provider.getApiKey(.{
        .refresh = "refresh",
        .access = "access",
        .expires = 1,
    });

    try std.testing.expectEqualStrings("access", api_key);
}
