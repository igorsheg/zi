const std = @import("std");
const pkce = @import("pkce.zig");
const callback_server = @import("callback_server.zig");
const auth_types = @import("types.zig");
const provider_mod = @import("../../ai/provider.zig");

const log = std.log.scoped(.oauth);

/// Per-provider OAuth configuration.
/// Shared PKCE + callback infra; per-provider hooks for protocol differences.
pub const OAuthProvider = struct {
    pub const Kind = enum {
        builtin,
        extension_login,
        extension_refresh,
        extension_login_refresh,

        pub fn usesExtensionLogin(self: Kind) bool {
            return switch (self) {
                .extension_login, .extension_login_refresh => true,
                else => false,
            };
        }

        pub fn usesExtensionRefresh(self: Kind) bool {
            return switch (self) {
                .extension_refresh, .extension_login_refresh => true,
                else => false,
            };
        }
    };

    id: []const u8,
    name: []const u8,
    kind: Kind = .builtin,
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

// ── Built-in providers + dynamic claim-backed registry ───────────────────

pub const ProviderListEntry = struct {
    id: []const u8,
    name: []const u8,

    pub fn deinit(self: *ProviderListEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        self.* = undefined;
    }
};

const ClaimOAuthTemplate = enum {
    anthropic,
    openai_codex,
};

pub const ResolveClaimOAuthTemplateError = error{
    BuiltinOverrideUnsupported,
    UnsupportedApiFamily,
    ConflictingApiFamilies,
};

pub const SyncClaimProviderError = ResolveClaimOAuthTemplateError || error{OutOfMemory};

const DynamicOAuthProvider = struct {
    allocator: std.mem.Allocator,
    id: []const u8,
    name: []const u8,
    owner_id: []const u8,
    generation: u64,
    template: ClaimOAuthTemplate,
    kind: OAuthProvider.Kind,

    fn deinit(self: *DynamicOAuthProvider) void {
        self.allocator.free(self.id);
        self.allocator.free(self.name);
        self.allocator.free(self.owner_id);
        self.* = undefined;
    }
};

var dynamic_provider_mutex: std.Io.Mutex = .init;
var dynamic_providers: std.ArrayListUnmanaged(DynamicOAuthProvider) = .empty;

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
    return std.fmt.allocPrint(
        allocator,
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
    return std.fmt.allocPrint(
        allocator,
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
    return tokenExchangeForm(allocator, CODEX_TOKEN_URL, &[_]JsonField{
        .{ .key = "grant_type", .value = "authorization_code" },
        .{ .key = "client_id", .value = CODEX_CLIENT_ID },
        .{ .key = "code", .value = req.code },
        .{ .key = "code_verifier", .value = req.verifier },
        .{ .key = "redirect_uri", .value = req.redirect_uri },
    });
}

fn codexRefreshToken(allocator: std.mem.Allocator, credential: auth_types.OAuthCredential) ExchangeResult {
    // pi-mono: openai-codex.ts:133-172
    return tokenExchangeForm(allocator, CODEX_TOKEN_URL, &[_]JsonField{
        .{ .key = "grant_type", .value = "refresh_token" },
        .{ .key = "refresh_token", .value = credential.refresh },
        .{ .key = "client_id", .value = CODEX_CLIENT_ID },
    });
}

const builtin_providers = [_]OAuthProvider{
    anthropic_provider,
    openai_codex_provider,
};

fn findBuiltinProvider(id: []const u8) ?OAuthProvider {
    for (&builtin_providers) |*provider| {
        if (std.mem.eql(u8, provider.id, id)) return provider.*;
    }
    return null;
}

fn templateForApi(api_name: []const u8) ?ClaimOAuthTemplate {
    if (std.mem.eql(u8, api_name, "anthropic-messages")) return .anthropic;
    if (std.mem.eql(u8, api_name, "openai-codex-responses")) return .openai_codex;
    return null;
}

fn retagProvider(template: ClaimOAuthTemplate, id: []const u8, name: []const u8) OAuthProvider {
    return switch (template) {
        .anthropic => .{
            .id = id,
            .name = name,
            .kind = .builtin,
            .callback_port = anthropic_provider.callback_port,
            .callback_path = anthropic_provider.callback_path,
            .build_authorize_url = anthropic_provider.build_authorize_url,
            .exchange_code = anthropic_provider.exchange_code,
            .refresh_token = anthropic_provider.refresh_token,
        },
        .openai_codex => .{
            .id = id,
            .name = name,
            .kind = .builtin,
            .callback_port = openai_codex_provider.callback_port,
            .callback_path = openai_codex_provider.callback_path,
            .build_authorize_url = openai_codex_provider.build_authorize_url,
            .exchange_code = openai_codex_provider.exchange_code,
            .refresh_token = openai_codex_provider.refresh_token,
        },
    };
}

fn dupeProviderListEntry(allocator: std.mem.Allocator, id: []const u8, name: []const u8) !ProviderListEntry {
    const id_dup = try allocator.dupe(u8, id);
    errdefer allocator.free(id_dup);
    const name_dup = try allocator.dupe(u8, name);
    errdefer allocator.free(name_dup);
    return .{ .id = id_dup, .name = name_dup };
}

fn initDynamicProvider(
    allocator: std.mem.Allocator,
    claim: *const provider_mod.ClaimRegistration,
    display_name: []const u8,
    template: ClaimOAuthTemplate,
    kind: OAuthProvider.Kind,
) !DynamicOAuthProvider {
    const id = try allocator.dupe(u8, claim.name);
    errdefer allocator.free(id);
    const name = try allocator.dupe(u8, display_name);
    errdefer allocator.free(name);
    const owner_id = try allocator.dupe(u8, claim.owner_id);
    errdefer allocator.free(owner_id);

    return .{
        .allocator = allocator,
        .id = id,
        .name = name,
        .owner_id = owner_id,
        .generation = claim.generation,
        .template = template,
        .kind = kind,
    };
}

pub fn resolveClaimOAuthTemplate(
    provider_name: []const u8,
    api_name: []const u8,
    models: []const provider_mod.ClaimModelRegistration,
) ResolveClaimOAuthTemplateError!ClaimOAuthTemplate {
    if (findBuiltinProvider(provider_name) != null) return error.BuiltinOverrideUnsupported;

    const template = templateForApi(api_name) orelse return error.UnsupportedApiFamily;
    for (models) |model| {
        const effective_api = model.api orelse api_name;
        const model_template = templateForApi(effective_api) orelse return error.UnsupportedApiFamily;
        if (model_template != template) return error.ConflictingApiFamilies;
    }
    return template;
}

fn dynamicProviderIndexLocked(id: []const u8) ?usize {
    for (dynamic_providers.items, 0..) |provider, idx| {
        if (std.mem.eql(u8, provider.id, id)) return idx;
    }
    return null;
}

fn removeClaimProviderByOwnerLocked(id: []const u8, owner_id: []const u8) bool {
    const idx = dynamicProviderIndexLocked(id) orelse return false;
    const existing = dynamic_providers.items[idx];
    if (!std.mem.eql(u8, existing.owner_id, owner_id)) return false;

    var removed = dynamic_providers.orderedRemove(idx);
    removed.deinit();
    return true;
}

fn unregisterClaimProviderLocked(id: []const u8, owner_id: []const u8, generation: u64) bool {
    const idx = dynamicProviderIndexLocked(id) orelse return false;
    const existing = dynamic_providers.items[idx];
    if (!std.mem.eql(u8, existing.owner_id, owner_id)) return false;
    if (existing.generation != generation) return false;

    var removed = dynamic_providers.orderedRemove(idx);
    removed.deinit();
    return true;
}

pub fn syncClaimProvider(allocator: std.mem.Allocator, claim: *const provider_mod.ClaimRegistration) SyncClaimProviderError!void {
    dynamic_provider_mutex.lockUncancelable(std.Options.debug_io);
    defer dynamic_provider_mutex.unlock(std.Options.debug_io);

    if (!claim.oauth_enabled) {
        _ = removeClaimProviderByOwnerLocked(claim.name, claim.owner_id);
        return;
    }

    const template = try resolveClaimOAuthTemplate(claim.name, claim.api, claim.models);
    const display_name = claim.oauth_name orelse claim.name;
    const kind: OAuthProvider.Kind = if (claim.oauth_login_ref != null and claim.oauth_refresh_token_ref != null)
        .extension_login_refresh
    else if (claim.oauth_login_ref != null)
        .extension_login
    else if (claim.oauth_refresh_token_ref != null)
        .extension_refresh
    else
        .builtin;

    if (dynamicProviderIndexLocked(claim.name)) |idx| {
        const existing = &dynamic_providers.items[idx];
        std.debug.assert(std.mem.eql(u8, existing.owner_id, claim.owner_id));
        const new_name = try allocator.dupe(u8, display_name);
        allocator.free(existing.name);
        existing.name = new_name;
        existing.generation = claim.generation;
        existing.template = template;
        existing.kind = kind;
        return;
    }

    const provider = try initDynamicProvider(allocator, claim, display_name, template, kind);
    errdefer {
        var owned = provider;
        owned.deinit();
    }
    try dynamic_providers.append(std.heap.page_allocator, provider);
}

pub fn unregisterClaimProvider(id: []const u8, owner_id: []const u8, generation: u64) bool {
    dynamic_provider_mutex.lockUncancelable(std.Options.debug_io);
    defer dynamic_provider_mutex.unlock(std.Options.debug_io);
    return unregisterClaimProviderLocked(id, owner_id, generation);
}

pub fn unregisterProvidersByGeneration(generation: u64) void {
    dynamic_provider_mutex.lockUncancelable(std.Options.debug_io);
    defer dynamic_provider_mutex.unlock(std.Options.debug_io);

    var i: usize = 0;
    while (i < dynamic_providers.items.len) {
        if (dynamic_providers.items[i].generation != generation) {
            i += 1;
            continue;
        }
        var removed = dynamic_providers.orderedRemove(i);
        removed.deinit();
    }
}

pub fn listProviders(allocator: std.mem.Allocator) ![]ProviderListEntry {
    dynamic_provider_mutex.lockUncancelable(std.Options.debug_io);
    defer dynamic_provider_mutex.unlock(std.Options.debug_io);

    const total = builtin_providers.len + dynamic_providers.items.len;
    const entries = try allocator.alloc(ProviderListEntry, total);

    var built: usize = 0;
    errdefer {
        for (entries[0..built]) |*entry| entry.deinit(allocator);
        allocator.free(entries);
    }

    for (builtin_providers) |provider| {
        entries[built] = try dupeProviderListEntry(allocator, provider.id, provider.name);
        built += 1;
    }
    for (dynamic_providers.items) |provider| {
        entries[built] = try dupeProviderListEntry(allocator, provider.id, provider.name);
        built += 1;
    }
    return entries;
}

pub fn findProvider(id: []const u8) ?OAuthProvider {
    if (findBuiltinProvider(id)) |provider| return provider;

    dynamic_provider_mutex.lockUncancelable(std.Options.debug_io);
    defer dynamic_provider_mutex.unlock(std.Options.debug_io);

    for (dynamic_providers.items) |provider| {
        if (std.mem.eql(u8, provider.id, id)) {
            var resolved = retagProvider(provider.template, provider.id, provider.name);
            resolved.kind = provider.kind;
            return resolved;
        }
    }
    return null;
}

pub fn resetDynamicProvidersForTest() void {
    dynamic_provider_mutex.lockUncancelable(std.Options.debug_io);
    defer dynamic_provider_mutex.unlock(std.Options.debug_io);

    for (dynamic_providers.items) |*provider| provider.deinit();
    dynamic_providers.deinit(std.heap.page_allocator);
    dynamic_providers = .empty;
}

// ── Shared token exchange (JSON POST) ───────────────────────────────────

const JsonField = struct {
    key: []const u8,
    value: []const u8,
};

fn tokenExchangeJson(allocator: std.mem.Allocator, url_str: []const u8, fields: []const JsonField) ExchangeResult {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };

    jw.beginObject() catch return .{ .err = "JSON write error" };
    for (fields) |f| {
        jw.objectField(f.key) catch return .{ .err = "JSON write error" };
        jw.write(f.value) catch return .{ .err = "JSON write error" };
    }
    jw.endObject() catch return .{ .err = "JSON write error" };

    return doTokenExchange(allocator, url_str, "application/json", out.written(), 5 * 60 * 1000);
}

fn tokenExchangeForm(allocator: std.mem.Allocator, url_str: []const u8, fields: []const JsonField) ExchangeResult {
    var payload_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer payload_buf.deinit(allocator);

    for (fields, 0..) |f, i| {
        if (i > 0) payload_buf.append(allocator, '&') catch return .{ .err = "OOM building form body" };
        payload_buf.appendSlice(allocator, f.key) catch return .{ .err = "OOM building form body" };
        payload_buf.append(allocator, '=') catch return .{ .err = "OOM building form body" };
        percentEncodeInto(allocator, &payload_buf, f.value) catch return .{ .err = "OOM building form body" };
    }

    return doTokenExchange(allocator, url_str, "application/x-www-form-urlencoded", payload_buf.items, 0);
}

fn doTokenExchange(
    allocator: std.mem.Allocator,
    url_str: []const u8,
    content_type: []const u8,
    payload: []const u8,
    expires_buffer_ms: i64,
) ExchangeResult {
    var client: std.http.Client = .{ .allocator = allocator, .io = std.Options.debug_io };
    defer client.deinit();

    var body_writer_buf: [8192]u8 = undefined;
    var body_writer: std.Io.Writer = .fixed(&body_writer_buf);

    const result = client.fetch(.{
        .location = .{ .url = url_str },
        .method = .POST,
        .payload = payload,
        .extra_headers = &.{
            .{ .name = "accept", .value = "application/json" },
        },
        .headers = .{
            .content_type = .{ .override = content_type },
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

    const now_ms = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds();
    const expires_ms = now_ms + expires_in * 1000 - expires_buffer_ms;

    return .{ .success = .{
        .refresh = allocator.dupe(u8, refresh_token) catch return .{ .err = "OOM" },
        .access = allocator.dupe(u8, access_token) catch return .{ .err = "OOM" },
        .expires = expires_ms,
        .extras = .{},
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

const testing = std.testing;

test "dynamic oauth providers list claim-visible ids and labels" {
    resetDynamicProvidersForTest();
    defer resetDynamicProvidersForTest();

    var claim = provider_mod.ClaimRegistration{
        .name = try testing.allocator.dupe(u8, "corp-ai"),
        .api = try testing.allocator.dupe(u8, "anthropic-messages"),
        .base_url = try testing.allocator.dupe(u8, "https://proxy.example"),
        .oauth_enabled = true,
        .oauth_name = try testing.allocator.dupe(u8, "Corporate Claude"),
        .owner_id = try testing.allocator.dupe(u8, "state-123"),
        .generation = 5,
    };
    defer claim.deinit(testing.allocator);

    try syncClaimProvider(testing.allocator, &claim);

    const providers = try listProviders(testing.allocator);
    defer {
        for (providers) |*provider| provider.deinit(testing.allocator);
        testing.allocator.free(providers);
    }

    var saw_dynamic = false;
    for (providers) |provider| {
        if (!std.mem.eql(u8, provider.id, "corp-ai")) continue;
        saw_dynamic = true;
        try testing.expectEqualStrings("Corporate Claude", provider.name);
    }
    try testing.expect(saw_dynamic);
    const dynamic = findProvider("corp-ai") orelse return error.ExpectedDynamicProvider;
    try testing.expectEqual(OAuthProvider.Kind.builtin, dynamic.kind);
    try testing.expect(findProvider("anthropic-messages") == null);
}

test "dynamic oauth providers mark extension-login execution separately" {
    resetDynamicProvidersForTest();
    defer resetDynamicProvidersForTest();

    var claim = provider_mod.ClaimRegistration{
        .name = try testing.allocator.dupe(u8, "corp-login"),
        .api = try testing.allocator.dupe(u8, "anthropic-messages"),
        .base_url = try testing.allocator.dupe(u8, "https://proxy.example"),
        .oauth_enabled = true,
        .oauth_name = try testing.allocator.dupe(u8, "Corporate Login"),
        .oauth_login_ref = 17,
        .owner_id = try testing.allocator.dupe(u8, "state-456"),
        .generation = 6,
    };
    defer claim.deinit(testing.allocator);

    try syncClaimProvider(testing.allocator, &claim);

    const provider = findProvider("corp-login") orelse return error.ExpectedDynamicProvider;
    try testing.expectEqual(OAuthProvider.Kind.extension_login, provider.kind);
}

test "dynamic oauth providers mark extension-refresh execution separately" {
    resetDynamicProvidersForTest();
    defer resetDynamicProvidersForTest();

    var claim = provider_mod.ClaimRegistration{
        .name = try testing.allocator.dupe(u8, "corp-refresh"),
        .api = try testing.allocator.dupe(u8, "anthropic-messages"),
        .base_url = try testing.allocator.dupe(u8, "https://proxy.example"),
        .oauth_enabled = true,
        .oauth_name = try testing.allocator.dupe(u8, "Corporate Refresh"),
        .oauth_refresh_token_ref = 23,
        .owner_id = try testing.allocator.dupe(u8, "state-789"),
        .generation = 7,
    };
    defer claim.deinit(testing.allocator);

    try syncClaimProvider(testing.allocator, &claim);

    const provider = findProvider("corp-refresh") orelse return error.ExpectedDynamicProvider;
    try testing.expectEqual(OAuthProvider.Kind.extension_refresh, provider.kind);
    try testing.expect(provider.kind.usesExtensionRefresh());
    try testing.expect(!provider.kind.usesExtensionLogin());
}

test "dynamic oauth providers mark extension login and refresh execution separately" {
    resetDynamicProvidersForTest();
    defer resetDynamicProvidersForTest();

    var claim = provider_mod.ClaimRegistration{
        .name = try testing.allocator.dupe(u8, "corp-both"),
        .api = try testing.allocator.dupe(u8, "anthropic-messages"),
        .base_url = try testing.allocator.dupe(u8, "https://proxy.example"),
        .oauth_enabled = true,
        .oauth_name = try testing.allocator.dupe(u8, "Corporate Both"),
        .oauth_login_ref = 17,
        .oauth_refresh_token_ref = 29,
        .owner_id = try testing.allocator.dupe(u8, "state-101"),
        .generation = 8,
    };
    defer claim.deinit(testing.allocator);

    try syncClaimProvider(testing.allocator, &claim);

    const provider = findProvider("corp-both") orelse return error.ExpectedDynamicProvider;
    try testing.expectEqual(OAuthProvider.Kind.extension_login_refresh, provider.kind);
    try testing.expect(provider.kind.usesExtensionRefresh());
    try testing.expect(provider.kind.usesExtensionLogin());
}
