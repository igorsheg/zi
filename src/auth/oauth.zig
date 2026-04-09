const std = @import("std");
const pkce = @import("pkce.zig");
const callback_server = @import("callback_server.zig");
const auth_types = @import("types.zig");

const log = std.log.scoped(.oauth);

/// Per-provider OAuth configuration.
/// Shared PKCE + callback infra; per-provider hooks for protocol differences.
pub const OAuthProvider = struct {
    id: []const u8,
    name: []const u8,
    callback_port: u16,
    callback_path: []const u8,

    /// Build the full authorization URL including PKCE challenge.
    /// Caller owns returned slice.
    build_authorize_url: *const fn (allocator: std.mem.Allocator, flow: *const FlowContext) ?[]u8,

    /// Exchange authorization code for tokens. POST to token endpoint.
    /// Caller owns the OAuthCredential (strings are allocated with allocator).
    exchange_code: *const fn (allocator: std.mem.Allocator, req: ExchangeRequest) ExchangeResult,

    /// Refresh an expired token.
    refresh_token: *const fn (allocator: std.mem.Allocator, credential: auth_types.OAuthCredential) ExchangeResult,
};

/// State carried through a single login flow.
pub const FlowContext = struct {
    verifier: []const u8,
    challenge: []const u8,
    state: []const u8,
    redirect_uri: []const u8,
};

pub const ExchangeRequest = struct {
    code: []const u8,
    state: []const u8,
    verifier: []const u8,
    redirect_uri: []const u8,
};

pub const ExchangeResult = union(enum) {
    success: auth_types.OAuthCredential,
    err: []const u8,
};

/// Callbacks from login flow to UI.
pub const LoginCallbacks = struct {
    /// Called with authorization URL. UI should open browser + display URL.
    on_auth: *const fn (url: []const u8, ctx: ?*anyopaque) void,
    /// Called with progress messages.
    on_progress: ?*const fn (msg: []const u8, ctx: ?*anyopaque) void = null,
    ctx: ?*anyopaque = null,
};

pub const LoginResult = union(enum) {
    success: auth_types.OAuthCredential,
    cancelled,
    err: []const u8,
};

/// Run the full PKCE login flow for a provider.
/// Blocks until complete — run on a worker thread.
///
/// Flow:
/// 1. Generate PKCE verifier + challenge
/// 2. Build authorization URL (provider-specific)
/// 3. Notify UI (on_auth callback)
/// 4. Start callback server, wait for redirect
/// 5. Exchange authorization code for tokens (provider-specific)
/// 6. Return credentials
pub fn login(
    allocator: std.mem.Allocator,
    provider: OAuthProvider,
    callbacks: LoginCallbacks,
    cancelled: *const std.atomic.Value(bool),
) LoginResult {
    const pkce_challenge = pkce.generate();

    const redirect_uri_buf = std.fmt.allocPrint(
        allocator,
        "http://localhost:{d}{s}",
        .{ provider.callback_port, provider.callback_path },
    ) catch return .{ .err = "OOM building redirect URI" };
    defer allocator.free(redirect_uri_buf);

    const state = pkce.generateState();
    const flow = FlowContext{
        .verifier = pkce_challenge.verifier(),
        .challenge = pkce_challenge.challenge(),
        .state = &state,
        .redirect_uri = redirect_uri_buf,
    };

    const auth_url = provider.build_authorize_url(allocator, &flow) orelse {
        return .{ .err = "failed to build authorization URL" };
    };
    defer allocator.free(auth_url);

    callbacks.on_auth(auth_url, callbacks.ctx);

    if (callbacks.on_progress) |progress| {
        progress("Waiting for browser authentication...", callbacks.ctx);
    }

    const cb_result = callback_server.waitForCallback(
        allocator,
        provider.callback_port,
        provider.callback_path,
        flow.state,
        cancelled,
    );
    defer cb_result.deinit(allocator);

    switch (cb_result) {
        .success => |s| {
            if (callbacks.on_progress) |progress| {
                progress("Exchanging authorization code for tokens...", callbacks.ctx);
            }

            const exchange_result = provider.exchange_code(allocator, .{
                .code = s.code,
                .state = s.state,
                .verifier = flow.verifier,
                .redirect_uri = redirect_uri_buf,
            });

            return switch (exchange_result) {
                .success => |cred| .{ .success = cred },
                .err => |msg| .{ .err = msg },
            };
        },
        .cancelled => return .cancelled,
        .err => |msg| return .{ .err = msg },
        .timeout => return .{ .err = "callback timed out" },
    }
}

// ── Built-in providers ──────────────────────────────────────────────────

pub const PROVIDERS = [_]OAuthProvider{
    anthropic_provider,
    openai_codex_provider,
};

pub fn findProvider(id: []const u8) ?OAuthProvider {
    for (&PROVIDERS) |*p| {
        if (std.mem.eql(u8, p.id, id)) return p.*;
    }
    return null;
}

// ── Anthropic (Claude Pro/Max) ──────────────────────────────────────────
// pi-mono source: packages/ai/src/utils/oauth/anthropic.ts

const ANTHROPIC_CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
const ANTHROPIC_AUTHORIZE_URL = "https://claude.ai/oauth/authorize";
const ANTHROPIC_TOKEN_URL = "https://platform.claude.com/v1/oauth/token";
const ANTHROPIC_SCOPES = "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload";

pub const anthropic_provider = OAuthProvider{
    .id = "anthropic",
    .name = "Anthropic (Claude Pro/Max)",
    .callback_port = 53692,
    .callback_path = "/callback",
    .build_authorize_url = &anthropicBuildAuthorizeUrl,
    .exchange_code = &anthropicExchangeCode,
    .refresh_token = &anthropicRefreshToken,
};

fn anthropicBuildAuthorizeUrl(allocator: std.mem.Allocator, flow: *const FlowContext) ?[]u8 {
    // pi-mono: anthropic.ts:244-253
    return std.fmt.allocPrint(allocator,
        "{s}?code=true&client_id={s}&response_type=code&redirect_uri={s}&scope={s}&code_challenge={s}&code_challenge_method=S256&state={s}",
        .{
            ANTHROPIC_AUTHORIZE_URL,
            ANTHROPIC_CLIENT_ID,
            flow.redirect_uri,
            ANTHROPIC_SCOPES,
            flow.challenge,
            flow.state,
        },
    ) catch return null;
}

fn anthropicExchangeCode(allocator: std.mem.Allocator, req: ExchangeRequest) ExchangeResult {
    // pi-mono: anthropic.ts:189-224
    return tokenExchangeJson(allocator, ANTHROPIC_TOKEN_URL, &[_]JsonField{
        .{ .key = "grant_type", .value = "authorization_code" },
        .{ .key = "client_id", .value = ANTHROPIC_CLIENT_ID },
        .{ .key = "code", .value = req.code },
        .{ .key = "state", .value = req.state },
        .{ .key = "redirect_uri", .value = req.redirect_uri },
        .{ .key = "code_verifier", .value = req.verifier },
    });
}

fn anthropicRefreshToken(allocator: std.mem.Allocator, credential: auth_types.OAuthCredential) ExchangeResult {
    // pi-mono: anthropic.ts:348-378
    return tokenExchangeJson(allocator, ANTHROPIC_TOKEN_URL, &[_]JsonField{
        .{ .key = "grant_type", .value = "refresh_token" },
        .{ .key = "client_id", .value = ANTHROPIC_CLIENT_ID },
        .{ .key = "refresh_token", .value = credential.refresh },
    });
}

/// Extract `chatgpt_account_id` from a JWT access token's payload.
/// The claim lives at `https://api.openai.com/auth` → `chatgpt_account_id`.
/// Returns an allocator-owned string, or null if extraction fails.
/// pi-mono: openai-codex.ts:79-87, 282-287
fn extractCodexAccountId(allocator: std.mem.Allocator, access_token: []const u8) ?[]const u8 {
    // JWT = header.payload.signature; we want the payload
    var parts = std.mem.splitScalar(u8, access_token, '.');
    _ = parts.next() orelse return null; // header
    const payload_b64 = parts.next() orelse return null;

    // Base64url decode — JWT uses no padding, url-safe alphabet
    const decoded_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload_b64) catch return null;
    const decoded = allocator.alloc(u8, decoded_len) catch return null;
    defer allocator.free(decoded);
    std.base64.url_safe_no_pad.Decoder.decode(decoded, payload_b64) catch return null;

    // Parse JSON
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, decoded, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;

    // Navigate: root["https://api.openai.com/auth"]["chatgpt_account_id"]
    const auth_claim = parsed.value.object.get("https://api.openai.com/auth") orelse return null;
    if (auth_claim != .object) return null;
    const account_id_val = auth_claim.object.get("chatgpt_account_id") orelse return null;
    if (account_id_val != .string or account_id_val.string.len == 0) return null;

    return allocator.dupe(u8, account_id_val.string) catch null;
}

// ── OpenAI Codex (ChatGPT subscription) ─────────────────────────────────
// pi-mono source: packages/ai/src/utils/oauth/openai-codex.ts

const CODEX_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann";
const CODEX_AUTHORIZE_URL = "https://auth.openai.com/oauth/authorize";
const CODEX_TOKEN_URL = "https://auth.openai.com/oauth/token";
const CODEX_SCOPE = "openid profile email offline_access";
const CODEX_REDIRECT_PORT: u16 = 1455;
const CODEX_REDIRECT_PATH = "/auth/callback";

pub const openai_codex_provider = OAuthProvider{
    .id = "openai-codex",
    .name = "ChatGPT Plus/Pro (Codex)",
    .callback_port = CODEX_REDIRECT_PORT,
    .callback_path = CODEX_REDIRECT_PATH,
    .build_authorize_url = &codexBuildAuthorizeUrl,
    .exchange_code = &codexExchangeCode,
    .refresh_token = &codexRefreshToken,
};

fn codexBuildAuthorizeUrl(allocator: std.mem.Allocator, flow: *const FlowContext) ?[]u8 {
    // pi-mono: openai-codex.ts:174-193
    return std.fmt.allocPrint(allocator,
        "{s}?response_type=code&client_id={s}&redirect_uri={s}&scope={s}&code_challenge={s}&code_challenge_method=S256&state={s}&id_token_add_organizations=true&codex_cli_simplified_flow=true&originator=zi",
        .{
            CODEX_AUTHORIZE_URL,
            CODEX_CLIENT_ID,
            flow.redirect_uri,
            CODEX_SCOPE,
            flow.challenge,
            flow.state,
        },
    ) catch return null;
}

fn codexExchangeCode(allocator: std.mem.Allocator, req: ExchangeRequest) ExchangeResult {
    // pi-mono: openai-codex.ts:91-131
    var result = tokenExchangeForm(allocator, CODEX_TOKEN_URL, &[_]JsonField{
        .{ .key = "grant_type", .value = "authorization_code" },
        .{ .key = "client_id", .value = CODEX_CLIENT_ID },
        .{ .key = "code", .value = req.code },
        .{ .key = "code_verifier", .value = req.verifier },
        .{ .key = "redirect_uri", .value = req.redirect_uri },
    });

    switch (result) {
        .success => |*cred| {
            // Stash accountId in extras for header injection at stream time
            if (extractCodexAccountId(allocator, cred.access)) |account_id| {
                const key = allocator.dupe(u8, "accountId") catch {
                    allocator.free(account_id);
                    return result;
                };
                cred.extras.put(key, .{ .string = account_id }) catch {
                    allocator.free(account_id);
                    allocator.free(key);
                };
            }
            return result;
        },
        .err => return result,
    }
}

fn codexRefreshToken(allocator: std.mem.Allocator, credential: auth_types.OAuthCredential) ExchangeResult {
    // pi-mono: openai-codex.ts:133-172
    var result = tokenExchangeForm(allocator, CODEX_TOKEN_URL, &[_]JsonField{
        .{ .key = "grant_type", .value = "refresh_token" },
        .{ .key = "refresh_token", .value = credential.refresh },
        .{ .key = "client_id", .value = CODEX_CLIENT_ID },
    });

    switch (result) {
        .success => |*cred| {
            // Try to extract accountId from new token; fall back to old
            if (extractCodexAccountId(allocator, cred.access)) |account_id| {
                const key = allocator.dupe(u8, "accountId") catch {
                    allocator.free(account_id);
                    return result;
                };
                cred.extras.put(key, .{ .string = account_id }) catch {
                    allocator.free(account_id);
                    allocator.free(key);
                };
            } else {
                // Preserve old accountId if we can't decode the new token
                if (credential.extras.get("accountId")) |old_val| {
                    if (old_val == .string and old_val.string.len > 0) {
                        const key = allocator.dupe(u8, "accountId") catch return result;
                        const val = allocator.dupe(u8, old_val.string) catch {
                            allocator.free(key);
                            return result;
                        };
                        cred.extras.put(key, .{ .string = val }) catch {
                            allocator.free(key);
                            allocator.free(val);
                        };
                    }
                }
            }
            return result;
        },
        .err => return result,
    }
}

// ── Shared token exchange (JSON POST) ───────────────────────────────────

const JsonField = struct {
    key: []const u8,
    value: []const u8,
};

/// Generic JSON POST token exchange. Used by Anthropic.
/// Future form-urlencoded variant for OpenAI Codex would be a separate function.
fn tokenExchangeJson(allocator: std.mem.Allocator, url_str: []const u8, fields: []const JsonField) ExchangeResult {
    // Build JSON body into payload_buf via Writer.Allocating.fromArrayList
    var payload_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer payload_buf.deinit(allocator);

    {
        var out: std.io.Writer.Allocating = .fromArrayList(allocator, &payload_buf);
        var jw: std.json.Stringify = .{ .writer = &out.writer };

        jw.beginObject() catch return .{ .err = "JSON write error" };
        for (fields) |f| {
            jw.objectField(f.key) catch return .{ .err = "JSON write error" };
            jw.write(f.value) catch return .{ .err = "JSON write error" };
        }
        jw.endObject() catch return .{ .err = "JSON write error" };
        // Flush writer's internal buffer into payload_buf
        payload_buf = out.toArrayList();
    }

    // HTTP POST using fetch() — handles chunked encoding, compression, redirects
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var body_writer_buf: [8192]u8 = undefined;
    var body_writer: std.Io.Writer = .fixed(&body_writer_buf);

    const result = client.fetch(.{
        .location = .{ .url = url_str },
        .method = .POST,
        .payload = payload_buf.items,
        .extra_headers = &.{
            .{ .name = "accept", .value = "application/json" },
        },
        .headers = .{
            .content_type = .{ .override = "application/json" },
        },
        .response_writer = &body_writer,
    }) catch |err| {
        log.err("token exchange request failed: {s}", .{@errorName(err)});
        return .{ .err = "failed to connect to token endpoint" };
    };

    const body = body_writer.buffered();

    if (result.status != .ok) {
        log.err("token exchange failed: HTTP {d}: {s}", .{ @intFromEnum(result.status), body });
        return .{ .err = "token exchange failed" };
    }

    // Parse JSON response: { access_token, refresh_token, expires_in }
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        log.err("token response is not valid JSON ({d} bytes)", .{body.len});
        return .{ .err = "invalid token response JSON" };
    };
    defer parsed.deinit();

    const root = parsed.value.object;
    const access_token = (root.get("access_token") orelse return .{ .err = "missing access_token" }).string;
    const refresh_token = (root.get("refresh_token") orelse return .{ .err = "missing refresh_token" }).string;
    const expires_in_val = root.get("expires_in") orelse return .{ .err = "missing expires_in" };
    const expires_in: i64 = switch (expires_in_val) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => return .{ .err = "expires_in is not a number" },
    };

    // Calculate expiration: now + expires_in_seconds - 5 minutes buffer
    // pi-mono: Date.now() + expires_in * 1000 - 5 * 60 * 1000
    const now_ms = std.time.milliTimestamp();
    const expires_ms = now_ms + expires_in * 1000 - 5 * 60 * 1000;

    return .{ .success = .{
        .refresh = allocator.dupe(u8, refresh_token) catch return .{ .err = "OOM" },
        .access = allocator.dupe(u8, access_token) catch return .{ .err = "OOM" },
        .expires = expires_ms,
        .extras = std.json.ObjectMap.init(allocator),
    } };
}

/// Form-urlencoded POST token exchange. Used by OpenAI Codex.
/// Unlike `tokenExchangeJson`, does NOT subtract a 5-minute safety buffer
/// from `expires` — matches pi-mono's `openai-codex.ts:125-130`.
fn tokenExchangeForm(allocator: std.mem.Allocator, url_str: []const u8, fields: []const JsonField) ExchangeResult {
    // Build form body: key=value&key=value (percent-encoded values)
    var payload_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer payload_buf.deinit(allocator);

    for (fields, 0..) |f, i| {
        if (i > 0) payload_buf.append(allocator, '&') catch return .{ .err = "OOM building form body" };
        payload_buf.appendSlice(allocator, f.key) catch return .{ .err = "OOM building form body" };
        payload_buf.append(allocator, '=') catch return .{ .err = "OOM building form body" };
        // Values are already safe ASCII in our usage (codes, client_id, URIs),
        // but percent-encode for correctness.
        percentEncodeInto(allocator, &payload_buf, f.value) catch return .{ .err = "OOM building form body" };
    }

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var body_writer_buf: [8192]u8 = undefined;
    var body_writer: std.Io.Writer = .fixed(&body_writer_buf);

    const result = client.fetch(.{
        .location = .{ .url = url_str },
        .method = .POST,
        .payload = payload_buf.items,
        .extra_headers = &.{
            .{ .name = "accept", .value = "application/json" },
        },
        .headers = .{
            .content_type = .{ .override = "application/x-www-form-urlencoded" },
        },
        .response_writer = &body_writer,
    }) catch |err| {
        log.err("form token exchange request failed: {s}", .{@errorName(err)});
        return .{ .err = "failed to connect to token endpoint" };
    };

    const body = body_writer.buffered();

    if (result.status != .ok) {
        log.err("form token exchange failed: HTTP {d}: {s}", .{ @intFromEnum(result.status), body });
        return .{ .err = "token exchange failed" };
    }

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        log.err("form token response is not valid JSON ({d} bytes)", .{body.len});
        return .{ .err = "invalid token response JSON" };
    };
    defer parsed.deinit();

    const root = parsed.value.object;
    const access_token = (root.get("access_token") orelse return .{ .err = "missing access_token" }).string;
    const refresh_token = (root.get("refresh_token") orelse return .{ .err = "missing refresh_token" }).string;
    const expires_in_val = root.get("expires_in") orelse return .{ .err = "missing expires_in" };
    const expires_in: i64 = switch (expires_in_val) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => return .{ .err = "expires_in is not a number" },
    };

    // No safety buffer — pi-mono codex stores raw expiry:
    // Date.now() + expires_in * 1000
    const now_ms = std.time.milliTimestamp();
    const expires_ms = now_ms + expires_in * 1000;

    return .{ .success = .{
        .refresh = allocator.dupe(u8, refresh_token) catch return .{ .err = "OOM" },
        .access = allocator.dupe(u8, access_token) catch return .{ .err = "OOM" },
        .expires = expires_ms,
        .extras = std.json.ObjectMap.init(allocator),
    } };
}

/// Percent-encode a string into an ArrayList, encoding all non-unreserved chars.
/// RFC 3986 unreserved: ALPHA / DIGIT / "-" / "." / "_" / "~"
fn percentEncodeInto(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), input: []const u8) !void {
    for (input) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~') {
            try out.append(allocator, c);
        } else {
            const hex = "0123456789ABCDEF";
            try out.append(allocator, '%');
            try out.append(allocator, hex[c >> 4]);
            try out.append(allocator, hex[c & 0xf]);
        }
    }
}
