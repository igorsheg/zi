const std = @import("std");
const pkce = @import("pkce.zig");
const callback_server = @import("callback_server.zig");
const auth_types = @import("types.zig");
const provider_mod = @import("../../ai/provider.zig");
const zio_fs = @import("../../zio/file.zig");

const log = std.log.scoped(.oauth);

extern "c" fn system(command: [*:0]const u8) c_int;

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

    build_authorize_url: *const fn (allocator: std.mem.Allocator, flow: *const FlowContext) ?[]u8,

    exchange_code: *const fn (allocator: std.mem.Allocator, req: ExchangeRequest) ExchangeResult,

    refresh_token: *const fn (allocator: std.mem.Allocator, credential: auth_types.OAuthCredential) ExchangeResult,
};

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

pub const LoginCallbacks = struct {
    on_auth: *const fn (url: []const u8, ctx: ?*anyopaque) void,
    on_progress: ?*const fn (msg: []const u8, ctx: ?*anyopaque) void = null,
    ctx: ?*anyopaque = null,
};

pub const LoginResult = union(enum) {
    success: auth_types.OAuthCredential,
    cancelled,
    err: []const u8,
};

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
    return tokenExchangeJson(allocator, ANTHROPIC_TOKEN_URL, &[_]JsonField{
        .{ .key = "grant_type", .value = "refresh_token" },
        .{ .key = "client_id", .value = ANTHROPIC_CLIENT_ID },
        .{ .key = "refresh_token", .value = credential.refresh },
    });
}

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
    return tokenExchangeForm(allocator, CODEX_TOKEN_URL, &[_]JsonField{
        .{ .key = "grant_type", .value = "authorization_code" },
        .{ .key = "client_id", .value = CODEX_CLIENT_ID },
        .{ .key = "code", .value = req.code },
        .{ .key = "code_verifier", .value = req.verifier },
        .{ .key = "redirect_uri", .value = req.redirect_uri },
    });
}

fn codexRefreshToken(allocator: std.mem.Allocator, credential: auth_types.OAuthCredential) ExchangeResult {
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
    const state = pkce.generateState();
    const body_path = std.fmt.allocPrint(allocator, ".zig-cache/zi-oauth-{s}.body", .{&state}) catch return .{ .err = "OOM" };
    defer allocator.free(body_path);
    const out_path = std.fmt.allocPrint(allocator, ".zig-cache/zi-oauth-{s}.out", .{&state}) catch return .{ .err = "OOM" };
    defer allocator.free(out_path);
    const err_path = std.fmt.allocPrint(allocator, ".zig-cache/zi-oauth-{s}.err", .{&state}) catch return .{ .err = "OOM" };
    defer allocator.free(err_path);
    defer std.Io.Dir.cwd().deleteFile(std.Options.debug_io, body_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.Options.debug_io, out_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.Options.debug_io, err_path) catch {};

    zio_fs.writeFileTruncate(std.Options.debug_io, body_path, payload) catch return .{ .err = "failed to write token request" };

    const command = std.fmt.allocPrint(
        allocator,
        "/usr/bin/curl --silent --show-error --fail-with-body --max-time 20 --request POST --header 'accept: application/json' --header 'content-type: {s}' --data-binary '@{s}' '{s}' >'{s}' 2>'{s}'",
        .{ content_type, body_path, url_str, out_path, err_path },
    ) catch return .{ .err = "OOM" };
    defer allocator.free(command);

    const command_z = allocator.dupeZ(u8, command) catch return .{ .err = "OOM" };
    defer allocator.free(command_z);
    const rc = system(command_z.ptr);
    const body = zio_fs.readFileAlloc(std.Options.debug_io, allocator, out_path, .limited(64 * 1024)) catch return .{ .err = "failed to read token response" };
    defer allocator.free(body);
    if (rc != 0) {
        const stderr = zio_fs.readFileAlloc(std.Options.debug_io, allocator, err_path, .limited(8 * 1024)) catch "";
        defer if (stderr.len > 0) allocator.free(stderr);
        log.err("token exchange failed: {s}", .{stderr});
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

const TestClaimOptions = struct {
    name: []const u8,
    label: []const u8,
    owner_id: []const u8,
    generation: u64,
    login_ref: ?c_int = null,
    refresh_ref: ?c_int = null,
};

fn initAnthropicTestClaim(allocator: std.mem.Allocator, options: TestClaimOptions) !provider_mod.ClaimRegistration {
    return .{
        .name = try allocator.dupe(u8, options.name),
        .api = try allocator.dupe(u8, "anthropic-messages"),
        .base_url = try allocator.dupe(u8, "https://proxy.example"),
        .oauth_enabled = true,
        .oauth_name = try allocator.dupe(u8, options.label),
        .oauth_login_ref = options.login_ref,
        .oauth_refresh_token_ref = options.refresh_ref,
        .owner_id = try allocator.dupe(u8, options.owner_id),
        .generation = options.generation,
    };
}

test "oauth form encoding percent-escapes reserved bytes and keeps unreserved bytes" {
    var encoded: std.ArrayListUnmanaged(u8) = .empty;
    defer encoded.deinit(testing.allocator);

    try percentEncodeInto(testing.allocator, &encoded, "azAZ09-._~ /?&=");

    try testing.expectEqualStrings("azAZ09-._~%20%2F%3F%26%3D", encoded.items);
}

test "dynamic oauth providers list claim-visible ids and labels" {
    resetDynamicProvidersForTest();
    defer resetDynamicProvidersForTest();

    var claim = try initAnthropicTestClaim(testing.allocator, .{
        .name = "corp-ai",
        .label = "Corporate Claude",
        .owner_id = "state-123",
        .generation = 5,
    });
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

    var claim = try initAnthropicTestClaim(testing.allocator, .{
        .name = "corp-login",
        .label = "Corporate Login",
        .owner_id = "state-456",
        .generation = 6,
        .login_ref = 17,
    });
    defer claim.deinit(testing.allocator);

    try syncClaimProvider(testing.allocator, &claim);

    const provider = findProvider("corp-login") orelse return error.ExpectedDynamicProvider;
    try testing.expectEqual(OAuthProvider.Kind.extension_login, provider.kind);
}

test "dynamic oauth providers mark extension-refresh execution separately" {
    resetDynamicProvidersForTest();
    defer resetDynamicProvidersForTest();

    var claim = try initAnthropicTestClaim(testing.allocator, .{
        .name = "corp-refresh",
        .label = "Corporate Refresh",
        .owner_id = "state-789",
        .generation = 7,
        .refresh_ref = 23,
    });
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

    var claim = try initAnthropicTestClaim(testing.allocator, .{
        .name = "corp-both",
        .label = "Corporate Both",
        .owner_id = "state-101",
        .generation = 8,
        .login_ref = 17,
        .refresh_ref = 29,
    });
    defer claim.deinit(testing.allocator);

    try syncClaimProvider(testing.allocator, &claim);

    const provider = findProvider("corp-both") orelse return error.ExpectedDynamicProvider;
    try testing.expectEqual(OAuthProvider.Kind.extension_login_refresh, provider.kind);
    try testing.expect(provider.kind.usesExtensionRefresh());
    try testing.expect(provider.kind.usesExtensionLogin());
}
