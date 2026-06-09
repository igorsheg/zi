const std = @import("std");
const http_utils = @import("../http.zig");
const runtime = @import("../../../runtime/root.zig");
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
    var context = try parseJwtAuthContext(allocator, access_token) orelse return null;
    defer context.deinit(allocator);
    if (context.chatgpt_account_id) |account_id| return @as(?[]u8, try allocator.dupe(u8, account_id));
    if (context.organization_account_id) |account_id| return @as(?[]u8, try allocator.dupe(u8, account_id));
    return null;
}

pub fn getAccountIdFromExtra(allocator: std.mem.Allocator, extra: ?std.json.Value) !?[]u8 {
    const value = extra orelse return null;
    if (value != .object) return null;
    if (nonEmptyJsonString(value.object.get("chatgpt_account_id"))) |account_id| {
        return @as(?[]u8, try allocator.dupe(u8, account_id));
    }
    if (nonEmptyJsonString(value.object.get("account_id"))) |account_id| {
        return @as(?[]u8, try allocator.dupe(u8, account_id));
    }
    return null;
}

pub fn resolveAccountId(
    allocator: std.mem.Allocator,
    access_token: []const u8,
    auth_extra: ?std.json.Value,
) ![]u8 {
    if (try getAccountIdFromExtra(allocator, auth_extra)) |account_id| return account_id;
    return try getAccountId(allocator, access_token) orelse error.MissingAccountId;
}

const JwtAuthContext = struct {
    chatgpt_account_id: ?[]u8 = null,
    organization_account_id: ?[]u8 = null,
    chatgpt_user_id: ?[]u8 = null,
    email: ?[]u8 = null,
    plan: ?[]u8 = null,

    fn deinit(self: *JwtAuthContext, allocator: std.mem.Allocator) void {
        if (self.chatgpt_account_id) |value| allocator.free(value);
        if (self.organization_account_id) |value| allocator.free(value);
        if (self.chatgpt_user_id) |value| allocator.free(value);
        if (self.email) |value| allocator.free(value);
        if (self.plan) |value| allocator.free(value);
        self.* = undefined;
    }
};

fn parseJwtAuthContext(allocator: std.mem.Allocator, token: []const u8) !?JwtAuthContext {
    const payload_segment = jwtPayloadSegment(token) orelse return null;
    const decoded = decodeBase64Url(allocator, payload_segment) catch return null;
    defer allocator.free(decoded);

    var parsed = runtime.JsonOwned(std.json.Value).parseJson(allocator, decoded, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;

    var context: JwtAuthContext = .{};
    errdefer context.deinit(allocator);
    if (nonEmptyJsonString(parsed.value.object.get("email"))) |email| {
        context.email = try allocator.dupe(u8, email);
    }

    const auth = parsed.value.object.get(jwt_claim_path) orelse return context;
    if (auth != .object) return context;
    if (nonEmptyJsonString(auth.object.get("chatgpt_account_id"))) |account_id| {
        context.chatgpt_account_id = try allocator.dupe(u8, account_id);
    }
    context.organization_account_id = try organizationAccountId(allocator, auth.object);
    const user_id = nonEmptyJsonString(auth.object.get("chatgpt_user_id")) orelse
        nonEmptyJsonString(auth.object.get("user_id"));
    if (user_id) |value| context.chatgpt_user_id = try allocator.dupe(u8, value);
    if (nonEmptyJsonString(auth.object.get("chatgpt_plan_type"))) |plan| {
        context.plan = try allocator.dupe(u8, plan);
    }
    return context;
}

fn organizationAccountId(allocator: std.mem.Allocator, auth: std.json.ObjectMap) !?[]u8 {
    const organizations_value = auth.get("organizations") orelse return null;
    if (organizations_value != .array) return null;

    var first_id: ?[]const u8 = null;
    for (organizations_value.array.items) |organization_value| {
        if (organization_value != .object) continue;
        const id = nonEmptyJsonString(organization_value.object.get("id")) orelse continue;
        if (first_id == null) first_id = id;
        const is_default = if (organization_value.object.get("is_default")) |default_value| switch (default_value) {
            .bool => |value| value,
            else => false,
        } else false;
        if (is_default) return @as(?[]u8, try allocator.dupe(u8, id));
    }

    if (first_id) |id| return @as(?[]u8, try allocator.dupe(u8, id));
    return null;
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
    task_runtime: *runtime.Runtime,
    _: ?*anyopaque,
    callbacks: oauth.OAuthLoginCallbacks,
) !oauth.OAuthCredentials {
    var attempt = try beginLogin(allocator, io, callbacks);
    defer attempt.deinit(allocator, io);

    const code = try waitForLoginCode(allocator, io, task_runtime, callbacks, &attempt);
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
    var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
    io.random(&seed);
    defer std.crypto.secureZero(u8, &seed);
    var csprng = std.Random.DefaultCsprng.init(seed);
    var flow = try createAuthorizationFlow(allocator, csprng.random(), "zi");
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
    task_runtime: *runtime.Runtime,
    callbacks: oauth.OAuthLoginCallbacks,
    attempt: *LoginAttempt,
) ![]const u8 {
    if (attempt.callback_server) |*server| {
        if (callbacks.on_manual_code_input_fn != null) {
            return raceLoginCode(allocator, io, task_runtime, callbacks, server, attempt.flow.state);
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
const LoginCodeTaskState = enum {
    active,
    drained,
};

const LoginCodeTask = struct {
    handle: runtime.Task(LoginCodeResult),
    state: LoginCodeTaskState = .active,

    fn cancelAndDiscard(self: *LoginCodeTask, allocator: std.mem.Allocator) void {
        if (self.state == .drained) return;
        self.state = .drained;
        self.handle.cancel();
        if (self.handle.result) |code| {
            allocator.free(code);
        } else |_| {}
    }

    fn joinAndTakeResult(self: *LoginCodeTask) LoginCodeResult {
        std.debug.assert(self.state == .active);
        self.state = .drained;
        self.handle.cancel();
        return self.handle.result;
    }
};

fn raceLoginCode(
    allocator: std.mem.Allocator,
    io: std.Io,
    task_runtime: *runtime.Runtime,
    callbacks: oauth.OAuthLoginCallbacks,
    server: *CallbackServer,
    expected_state: []const u8,
) ![]const u8 {
    var callback: LoginCodeTask = .{
        .handle = try task_runtime.spawn(waitForCallbackCode, .{ allocator, io, server, expected_state }),
    };
    errdefer callback.cancelAndDiscard(allocator);
    var manual: LoginCodeTask = .{
        .handle = try task_runtime.spawn(waitForManualCode, .{ allocator, callbacks, expected_state }),
    };
    errdefer manual.cancelAndDiscard(allocator);

    switch (try runtime.select(.{
        .callback = &callback.handle,
        .manual = &manual.handle,
    })) {
        .callback => {
            manual.cancelAndDiscard(allocator);
            return callback.joinAndTakeResult();
        },
        .manual => {
            server.shutdown(io);
            callback.cancelAndDiscard(allocator);
            return manual.joinAndTakeResult();
        },
    }
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
    closed: bool = false,

    fn start(io: std.Io) !CallbackServer {
        const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(callback_port) };
        return .{ .server = try address.listen(io, .{ .reuse_address = true }) };
    }

    fn shutdown(self: *CallbackServer, io: std.Io) void {
        if (self.closed) return;
        self.server.socket.close(io);
        self.closed = true;
    }

    fn deinit(self: *CallbackServer, io: std.Io) void {
        self.shutdown(io);
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
    var parsed = try runtime.JsonOwned(std.json.Value).parseJson(allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidTokenResponse;
    const object = parsed.value.object;
    const access = jsonString(object.get("access_token")) orelse return error.InvalidTokenResponse;
    const refresh = jsonString(object.get("refresh_token")) orelse return error.InvalidTokenResponse;
    const expires_in = jsonI64(object.get("expires_in")) orelse return error.InvalidTokenResponse;
    const id_token = nonEmptyJsonString(object.get("id_token"));
    const response_account_id = nonEmptyJsonString(object.get("account_id"));
    const extra = try buildAuthExtra(allocator, access, id_token, response_account_id);
    errdefer if (extra) |value| runtime.freeJsonValue(allocator, value);
    const now_ms: i64 = @intCast(std.Io.Timestamp.now(io, .real).toMilliseconds());
    return .{
        .access = try allocator.dupe(u8, access),
        .refresh = try allocator.dupe(u8, refresh),
        .expires = now_ms + expires_in * 1000,
        .extra = extra,
    };
}

fn buildAuthExtra(
    allocator: std.mem.Allocator,
    access_token: []const u8,
    id_token: ?[]const u8,
    response_account_id: ?[]const u8,
) !?std.json.Value {
    var access_context = try parseJwtAuthContext(allocator, access_token) orelse JwtAuthContext{};
    defer access_context.deinit(allocator);
    var id_context = if (id_token) |token| try parseJwtAuthContext(allocator, token) else null;
    defer if (id_context) |*context| context.deinit(allocator);

    const jwt_account_id = firstString(&.{
        if (id_context) |context| context.chatgpt_account_id else null,
        access_context.chatgpt_account_id,
    });
    if (response_account_id) |account_id| {
        if (jwt_account_id) |jwt_id| {
            if (!std.mem.eql(u8, account_id, jwt_id)) return error.AccountIdMismatch;
        }
    }

    const resolved_account_id = response_account_id orelse jwt_account_id orelse firstString(&.{
        if (id_context) |context| context.organization_account_id else null,
        access_context.organization_account_id,
    }) orelse return error.MissingAccountId;

    var object: std.json.ObjectMap = .empty;
    errdefer runtime.freeJsonValue(allocator, .{ .object = object });
    if (id_token) |token| try putStringField(allocator, &object, "id_token", token);
    if (response_account_id) |account_id| try putStringField(allocator, &object, "account_id", account_id);
    try putStringField(allocator, &object, "chatgpt_account_id", resolved_account_id);
    const user_id = firstString(&.{
        if (id_context) |context| context.chatgpt_user_id else null,
        access_context.chatgpt_user_id,
    });
    if (user_id) |value| try putStringField(allocator, &object, "chatgpt_user_id", value);
    if (firstString(&.{ if (id_context) |context| context.email else null, access_context.email })) |email| {
        try putStringField(allocator, &object, "email", email);
    }
    if (firstString(&.{ if (id_context) |context| context.plan else null, access_context.plan })) |plan| {
        try putStringField(allocator, &object, "plan", plan);
    }
    return .{ .object = object };
}

fn firstString(values: []const ?[]const u8) ?[]const u8 {
    for (values) |value| if (value) |text| if (text.len > 0) return text;
    return null;
}

fn putStringField(
    allocator: std.mem.Allocator,
    object: *std.json.ObjectMap,
    key: []const u8,
    value: []const u8,
) !void {
    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);
    const owned_value = try allocator.dupe(u8, value);
    errdefer allocator.free(owned_value);
    try object.put(allocator, owned_key, .{ .string = owned_value });
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const resolved = value orelse return null;
    return switch (resolved) {
        .string => |string| string,
        else => null,
    };
}

fn nonEmptyJsonString(value: ?std.json.Value) ?[]const u8 {
    const string = jsonString(value) orelse return null;
    if (string.len == 0) return null;
    return string;
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
    const access = try jwtForPayload(std.testing.allocator, payload);
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
    defer if (credentials.extra) |extra| runtime.freeJsonValue(std.testing.allocator, extra);

    try std.testing.expectEqualStrings(access, credentials.access);
    try std.testing.expectEqualStrings("refresh", credentials.refresh);
    try std.testing.expect(credentials.expires > 0);
}

fn jwtForPayload(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    const encoded_payload = try oauth.pkce.base64UrlEncode(allocator, payload);
    defer allocator.free(encoded_payload);
    return std.fmt.allocPrint(allocator, "header.{s}.signature", .{encoded_payload});
}

fn expectExtraString(extra: std.json.Value, key: []const u8, expected: []const u8) !void {
    try std.testing.expect(extra == .object);
    const value = nonEmptyJsonString(extra.object.get(key)) orelse return error.MissingExtraField;
    try std.testing.expectEqualStrings(expected, value);
}

test "token response preserves id token and codex auth context" {
    const id_payload =
        \\{"email":"User@Example.COM","https://api.openai.com/auth":
    ++
        \\{"chatgpt_account_id":"acct_id","chatgpt_user_id":"user_id","chatgpt_plan_type":"pro"}}
    ;
    const id_token = try jwtForPayload(std.testing.allocator, id_payload);
    defer std.testing.allocator.free(id_token);
    const access = try jwtForPayload(std.testing.allocator, id_payload);
    defer std.testing.allocator.free(access);
    const body = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"access_token\":\"{s}\",\"id_token\":\"{s}\"," ++
            "\"refresh_token\":\"refresh\",\"expires_in\":60}}",
        .{ access, id_token },
    );
    defer std.testing.allocator.free(body);

    const credentials = try parseTokenResponse(std.testing.allocator, std.testing.io, body);
    defer std.testing.allocator.free(credentials.access);
    defer std.testing.allocator.free(credentials.refresh);
    defer if (credentials.extra) |extra| runtime.freeJsonValue(std.testing.allocator, extra);

    const extra = credentials.extra.?;
    try expectExtraString(extra, "id_token", id_token);
    try expectExtraString(extra, "chatgpt_account_id", "acct_id");
    try expectExtraString(extra, "chatgpt_user_id", "user_id");
    try expectExtraString(extra, "email", "User@Example.COM");
    try expectExtraString(extra, "plan", "pro");
}

test "token response uses default organization as account context" {
    const id_payload =
        \\{"https://api.openai.com/auth":{"organizations":
    ++
        \\[{"id":"org-other","is_default":false},{"id":"org-default","is_default":true}],"user_id":"user_id"}}
    ;
    const id_token = try jwtForPayload(std.testing.allocator, id_payload);
    defer std.testing.allocator.free(id_token);
    const body = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"access_token\":\"{s}\",\"id_token\":\"{s}\"," ++
            "\"refresh_token\":\"refresh\",\"expires_in\":60}}",
        .{ id_token, id_token },
    );
    defer std.testing.allocator.free(body);

    const credentials = try parseTokenResponse(std.testing.allocator, std.testing.io, body);
    defer std.testing.allocator.free(credentials.access);
    defer std.testing.allocator.free(credentials.refresh);
    defer if (credentials.extra) |extra| runtime.freeJsonValue(std.testing.allocator, extra);

    try expectExtraString(credentials.extra.?, "chatgpt_account_id", "org-default");
}

test "token response rejects mismatched explicit account id" {
    const payload =
        \\{"https://api.openai.com/auth":{"chatgpt_account_id":"acct_id"}}
    ;
    const token = try jwtForPayload(std.testing.allocator, payload);
    defer std.testing.allocator.free(token);
    const body = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"access_token\":\"{s}\",\"id_token\":\"{s}\",\"account_id\":\"other\"," ++
            "\"refresh_token\":\"refresh\",\"expires_in\":60}}",
        .{ token, token },
    );
    defer std.testing.allocator.free(body);

    try std.testing.expectError(
        error.AccountIdMismatch,
        parseTokenResponse(std.testing.allocator, std.testing.io, body),
    );
}

test "resolve account id prefers stored auth extra" {
    var object: std.json.ObjectMap = .empty;
    try putStringField(
        std.testing.allocator,
        &object,
        "chatgpt_account_id",
        "stored-account",
    );
    const extra: std.json.Value = .{ .object = object };
    defer runtime.freeJsonValue(std.testing.allocator, extra);

    const account_id = try resolveAccountId(std.testing.allocator, "not-a-jwt", extra);
    defer std.testing.allocator.free(account_id);

    try std.testing.expectEqualStrings("stored-account", account_id);
}

test "openai codex provider exposes access token as api key" {
    const api_key = try openai_codex_oauth_provider.getApiKey(.{
        .refresh = "refresh",
        .access = "access",
        .expires = 1,
    });

    try std.testing.expectEqualStrings("access", api_key);
}

test "oauth login race returns manual code and shuts callback waiter down" {
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    const io = task_runtime.io();

    var server = try CallbackServer.start(io);
    defer server.deinit(io);
    var state: LoginRaceTestState = .{ .expected_state = "state-a", .manual_input = "manual-code#state-a" };
    const callbacks = loginRaceCallbacks(&state, immediateManualInput);

    const code = try raceLoginCode(std.testing.allocator, io, task_runtime, callbacks, &server, state.expected_state);
    defer std.testing.allocator.free(code);

    try std.testing.expectEqualStrings("manual-code", code);
    try std.testing.expect(server.closed);
}

test "oauth login race shuts callback waiter down when manual input is unavailable" {
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    const io = task_runtime.io();

    var server = try CallbackServer.start(io);
    defer server.deinit(io);
    var state: LoginRaceTestState = .{ .expected_state = "state-unavailable", .manual_input = "" };
    const callbacks = loginRaceCallbacks(&state, unavailableManualInput);

    try std.testing.expectError(
        error.ManualOAuthInputUnavailable,
        raceLoginCode(std.testing.allocator, io, task_runtime, callbacks, &server, state.expected_state),
    );
    try std.testing.expect(server.closed);
    try std.testing.expectEqual(@as(usize, 1), state.manual_count.load(.acquire));
}

test "oauth login race returns callback code while manual input is blocked" {
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    const io = task_runtime.io();

    var server = try CallbackServer.start(io);
    defer server.deinit(io);
    var state: LoginRaceTestState = .{ .expected_state = "state-b", .manual_input = "manual-code#state-b" };
    const callbacks = loginRaceCallbacks(&state, delayedManualInput);
    var callback_client = try task_runtime.spawn(sendCallbackRequest, .{ io, state.expected_state, "callback-code" });
    defer callback_client.cancel();

    const code = try raceLoginCode(std.testing.allocator, io, task_runtime, callbacks, &server, state.expected_state);
    defer std.testing.allocator.free(code);

    try callback_client.join();
    try std.testing.expectEqualStrings("callback-code", code);
    try std.testing.expectEqual(@as(usize, 1), state.manual_count.load(.acquire));
}

const LoginRaceTestState = struct {
    expected_state: []const u8,
    manual_input: []const u8,
    manual_count: std.atomic.Value(usize) = .init(0),
};

fn loginRaceCallbacks(
    state: *LoginRaceTestState,
    manual_fn: *const fn (?*anyopaque) anyerror![]const u8,
) oauth.OAuthLoginCallbacks {
    return .{
        .context = state,
        .on_auth_fn = noopRaceOnAuth,
        .on_prompt_fn = noopRaceOnPrompt,
        .on_manual_code_input_fn = manual_fn,
    };
}

fn noopRaceOnAuth(_: ?*anyopaque, _: oauth.OAuthAuthInfo) !void {}

fn noopRaceOnPrompt(_: ?*anyopaque, _: oauth.OAuthPrompt) ![]const u8 {
    return error.UnexpectedPrompt;
}

fn immediateManualInput(context: ?*anyopaque) ![]const u8 {
    const state: *LoginRaceTestState = @ptrCast(@alignCast(context.?));
    _ = state.manual_count.fetchAdd(1, .monotonic);
    return state.manual_input;
}

fn unavailableManualInput(context: ?*anyopaque) ![]const u8 {
    const state: *LoginRaceTestState = @ptrCast(@alignCast(context.?));
    _ = state.manual_count.fetchAdd(1, .monotonic);
    return error.ManualOAuthInputUnavailable;
}

fn delayedManualInput(context: ?*anyopaque) ![]const u8 {
    const state: *LoginRaceTestState = @ptrCast(@alignCast(context.?));
    _ = state.manual_count.fetchAdd(1, .monotonic);
    try runtime.sleep(.fromMilliseconds(250));
    return state.manual_input;
}

fn sendCallbackRequest(io: std.Io, state: []const u8, code: []const u8) !void {
    try runtime.sleep(.fromMilliseconds(10));
    const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(callback_port) };
    const stream = try std.Io.net.IpAddress.connect(&address, io, .{ .mode = .stream });
    defer stream.close(io);

    var write_buffer: [512]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.print(
        "GET /auth/callback?code={s}&state={s} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
        .{ code, state },
    );
    try writer.interface.flush();
    try stream.shutdown(io, .send);

    var read_buffer: [512]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var response_buffer: [512]u8 = undefined;
    _ = reader.interface.readSliceShort(&response_buffer) catch return;
}
