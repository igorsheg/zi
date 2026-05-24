const std = @import("std");
const oauth = @import("root.zig");

pub const callback_host = "127.0.0.1";
pub const callback_port: u16 = 1455;
pub const client_id = "app_EMoamEEZ73f0CkXaXp7hrann";
pub const authorize_url = "https://auth.openai.com/oauth/authorize";
pub const token_url = "https://auth.openai.com/oauth/token";
pub const redirect_uri = "http://localhost:1455/auth/callback";
pub const scope = "openid profile email offline_access";
pub const jwt_claim_path = "https://api.openai.com/auth";

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

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, decoded, .{}) catch return null;
    defer parsed.deinit();
    const auth = parsed.value.object.get(jwt_claim_path) orelse return null;
    if (auth != .object) return null;
    const account_id = auth.object.get("chatgpt_account_id") orelse return null;
    if (account_id != .string or account_id.string.len == 0) return null;
    return allocator.dupe(u8, account_id.string);
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

fn login(_: ?*anyopaque, _: oauth.OAuthLoginCallbacks) !oauth.OAuthCredentials {
    return error.NotImplemented;
}

fn refreshToken(_: ?*anyopaque, _: oauth.OAuthCredentials) !oauth.OAuthCredentials {
    return error.NotImplemented;
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

test "openai codex provider exposes access token as api key" {
    const api_key = try openai_codex_oauth_provider.getApiKey(.{
        .refresh = "refresh",
        .access = "access",
        .expires = 1,
    });

    try std.testing.expectEqualStrings("access", api_key);
}
