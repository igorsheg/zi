const std = @import("std");
const lua_runtime = @import("lua_runtime.zig");
const lua_helpers = @import("lua_helpers.zig");
const runner_mod = @import("runner.zig");
const ai = @import("../../ai/root.zig");
const oauth_mod = @import("../auth/oauth.zig");

const c = lua_runtime.c;
const Lua = lua_helpers.Lua;
const FieldReader = lua_helpers.FieldReader;

const RegisterProviderError = error{
    MissingName,
    InvalidName,
    MissingConfig,
    InvalidConfig,
    MissingApi,
    InvalidApi,
    BuiltinOverrideApiMismatch,
    MissingBaseUrl,
    InvalidBaseUrl,
    InvalidApiKey,
    InvalidHeaders,
    InvalidOAuth,
    InvalidOAuthName,
    InvalidOAuthLogin,
    InvalidOAuthRefreshToken,
    InvalidOAuthRefreshTokenCamel,
    InvalidOAuthGetApiKey,
    UnsupportedOAuthModifyModels,
    UnsupportedOAuthRequiresModels,
    UnsupportedOAuthBuiltinOverride,
    UnsupportedOAuthApiFamily,
    UnsupportedOAuthMixedApiFamilies,
    DeferredAuthHeader,
    DeferredAuthHeaderCamel,
    DeferredStreamSimple,
    DeferredStreamSimpleCamel,
    InvalidModels,
    BuiltinOverrideModelsUnsupported,
    MissingModelId,
    InvalidModelId,
    MissingModelDisplayName,
    InvalidModelDisplayName,
    InvalidModelApi,
    MissingModelReasoning,
    InvalidModelReasoning,
    MissingModelInput,
    InvalidModelInput,
    MissingModelCost,
    InvalidModelCost,
    MissingModelContextWindow,
    InvalidModelContextWindow,
    MissingModelMaxTokens,
    InvalidModelMaxTokens,
    InvalidModelHeaders,
    InvalidModelCompat,
    OutOfMemory,
};

pub fn ziProvider(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = runnerFromUpvalue(L);

    const claim = buildProviderRegistration(L, runner) catch |err| {
        return luaError(L, switch (err) {
            error.MissingName, error.InvalidName => "zi.provider: expected provider name string as first argument",
            error.MissingConfig, error.InvalidConfig => "zi.provider: expected config table as second argument",
            error.MissingApi => "zi.provider: missing required field 'api'",
            error.InvalidApi => "zi.provider: field 'api' must be a string",
            error.BuiltinOverrideApiMismatch => "zi.provider: field 'api' must match the built-in provider api family in this slice",
            error.MissingBaseUrl => "zi.provider: missing required field 'base_url'",
            error.InvalidBaseUrl => "zi.provider: field 'base_url' must be a string",
            error.InvalidApiKey => "zi.provider: field 'api_key' must be a string",
            error.InvalidHeaders => "zi.provider: field 'headers' must be a string map",
            error.InvalidOAuth => "zi.provider: field 'oauth' only supports optional string field 'name' plus function fields 'login', 'refresh_token', 'refreshToken', and 'getApiKey' in this slice",
            error.InvalidOAuthName => "zi.provider: field 'oauth.name' must be a string when present",
            error.InvalidOAuthLogin => "zi.provider: field 'oauth.login' must be a function",
            error.InvalidOAuthRefreshToken => "zi.provider: field 'oauth.refresh_token' must be a function",
            error.InvalidOAuthRefreshTokenCamel => "zi.provider: field 'oauth.refreshToken' must be a function",
            error.InvalidOAuthGetApiKey => "zi.provider: field 'oauth.getApiKey' must be a function",
            error.UnsupportedOAuthModifyModels => "zi.provider: field 'oauth.modifyModels' is unsupported in this slice",
            error.UnsupportedOAuthRequiresModels => "zi.provider: field 'oauth' requires claim-backed models in this slice",
            error.UnsupportedOAuthBuiltinOverride => "zi.provider: field 'oauth' does not support built-in provider override semantics in this slice",
            error.UnsupportedOAuthApiFamily => "zi.provider: field 'oauth' requires a built-in host oauth template for the claim api family in this slice",
            error.UnsupportedOAuthMixedApiFamilies => "zi.provider: field 'oauth' requires every claim-backed model to resolve to the same built-in oauth-capable api family",
            error.DeferredAuthHeader => "zi.provider: field 'auth_header' is deferred in this slice",
            error.DeferredAuthHeaderCamel => "zi.provider: field 'authHeader' is deferred in this slice",
            error.DeferredStreamSimple => "zi.provider: field 'stream_simple' is deferred in this slice",
            error.DeferredStreamSimpleCamel => "zi.provider: field 'streamSimple' is deferred in this slice",
            error.InvalidModels => "zi.provider: field 'models' must be an array of model tables",
            error.BuiltinOverrideModelsUnsupported => "zi.provider: built-in provider overrides do not support field 'models' in this slice",
            error.MissingModelId, error.InvalidModelId => "zi.provider: each model requires string field 'id'",
            error.MissingModelDisplayName, error.InvalidModelDisplayName => "zi.provider: each model requires string field 'name'",
            error.InvalidModelApi => "zi.provider: model field 'api' must be a string when present",
            error.MissingModelReasoning, error.InvalidModelReasoning => "zi.provider: each model requires boolean field 'reasoning'",
            error.MissingModelInput, error.InvalidModelInput => "zi.provider: each model requires array field 'input' containing 'text' and/or 'image'",
            error.MissingModelCost, error.InvalidModelCost => "zi.provider: each model requires cost table with numeric input/output/cache_read/cache_write fields",
            error.MissingModelContextWindow, error.InvalidModelContextWindow => "zi.provider: each model requires integer field 'context_window'",
            error.MissingModelMaxTokens, error.InvalidModelMaxTokens => "zi.provider: each model requires integer field 'max_tokens'",
            error.InvalidModelHeaders => "zi.provider: model field 'headers' must be a string map",
            error.InvalidModelCompat => "zi.provider: model field 'compat' must be a JSON-compatible table",
            error.OutOfMemory => "zi.provider: out of memory",
        });
    };

    const accepted = runner.registerProviderClaim(claim) catch |err| {
        return luaError(L, switch (err) {
            error.UnknownApi => "zi.provider: this slice only supports overriding an existing api",
            error.BuiltinOverrideUnsupported => "zi.provider: field 'oauth' does not support built-in provider override semantics in this slice",
            error.UnsupportedApiFamily => "zi.provider: field 'oauth' requires a built-in host oauth template for the claim api family in this slice",
            error.ConflictingApiFamilies => "zi.provider: field 'oauth' requires every claim-backed model to resolve to the same built-in oauth-capable api family",
            error.OutOfMemory => "zi.provider: out of memory",
        });
    };
    if (!accepted) {
        var rejected = claim;
        rejected.deinit(runner.allocator);
    }

    Lua.init(L).pushBool(accepted);
    return 1;
}

pub fn ziUnprovider(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = runnerFromUpvalue(L);

    if (Lua.init(L).typeOf(1) != .string) {
        return luaError(L, "zi.unprovider: expected provider name string as first argument");
    }

    var name_len: usize = 0;
    const name_ptr = c.lua_tolstring(L, 1, &name_len) orelse return luaError(L, "zi.unprovider: invalid provider name");
    const owned_name = runner.allocator.dupe(u8, name_ptr[0..name_len]) catch return luaError(L, "zi.unprovider: out of memory");
    const owned_owner = runner.allocator.dupe(u8, currentProviderOwnerId(runner)) catch {
        runner.allocator.free(owned_name);
        return luaError(L, "zi.unprovider: out of memory");
    };

    const removed = runner.unregisterProviderClaim(owned_name, owned_owner) catch |err| {
        return luaError(L, switch (err) {
            error.OutOfMemory => "zi.unprovider: out of memory",
        });
    };

    Lua.init(L).pushBool(removed);
    return 1;
}

fn supportedBuiltinOverrideApi(provider_name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, provider_name, "anthropic")) return "anthropic-messages";
    if (std.mem.eql(u8, provider_name, "openai")) return "openai-responses";
    if (std.mem.eql(u8, provider_name, "openrouter")) return "openai-completions";
    if (std.mem.eql(u8, provider_name, "openai-codex")) return "openai-codex-responses";
    return null;
}

fn buildProviderRegistration(
    L: *c.lua_State,
    runner: *runner_mod.ExtensionRunner,
) RegisterProviderError!ai.provider.ClaimRegistration {
    const a = runner.allocator;

    if (c.lua_type(L, 1) != c.LUA_TSTRING) return error.MissingName;
    if (c.lua_type(L, 2) != c.LUA_TTABLE) return error.MissingConfig;

    var name_len: usize = 0;
    const name_ptr = c.lua_tolstring(L, 1, &name_len) orelse return error.InvalidName;
    const name = a.dupe(u8, name_ptr[0..name_len]) catch return error.OutOfMemory;
    errdefer a.free(name);

    const builtin_api = supportedBuiltinOverrideApi(name);
    const api_name = blk: {
        const explicit_api = try optionalProviderFieldString(L, 2, "api", a, error.InvalidApi);
        if (explicit_api) |owned_api| {
            if (builtin_api) |expected_api| {
                if (!std.mem.eql(u8, owned_api, expected_api)) {
                    a.free(owned_api);
                    return error.BuiltinOverrideApiMismatch;
                }
            }
            break :blk owned_api;
        }
        if (builtin_api) |expected_api| {
            break :blk a.dupe(u8, expected_api) catch return error.OutOfMemory;
        }
        return error.MissingApi;
    };
    errdefer a.free(api_name);

    const base_url = try requireProviderFieldString(L, 2, "base_url", a, error.MissingBaseUrl, error.InvalidBaseUrl);
    errdefer a.free(base_url);

    const api_key = try optionalProviderFieldString(L, 2, "api_key", a, error.InvalidApiKey);
    errdefer if (api_key) |owned| a.free(owned);

    const headers = try optionalProviderHeaders(L, 2, a);
    errdefer {
        for (headers) |header| {
            a.free(header.key);
            a.free(header.value);
        }
        if (headers.len > 0) a.free(headers);
    }

    try rejectDeferredProviderFields(L, 2);

    const owner_id = a.dupe(u8, currentProviderOwnerId(runner)) catch return error.OutOfMemory;
    errdefer a.free(owner_id);

    const models = try optionalProviderModels(L, 2, a);
    errdefer {
        for (models) |*model| model.deinit(a);
        if (models.len > 0) a.free(models);
    }
    if (builtin_api != null and models.len > 0) return error.BuiltinOverrideModelsUnsupported;

    const oauth = try parseProviderOAuth(L, 2, a);
    errdefer if (oauth.name) |owned| a.free(owned);

    if (oauth.enabled) {
        if (builtin_api != null) return error.UnsupportedOAuthBuiltinOverride;
        if (models.len == 0) return error.UnsupportedOAuthRequiresModels;
        _ = oauth_mod.resolveClaimOAuthTemplate(name, api_name, models) catch |err| switch (err) {
            error.BuiltinOverrideUnsupported => return error.UnsupportedOAuthBuiltinOverride,
            error.UnsupportedApiFamily => return error.UnsupportedOAuthApiFamily,
            error.ConflictingApiFamilies => return error.UnsupportedOAuthMixedApiFamilies,
        };
    }

    return .{
        .name = name,
        .api = api_name,
        .base_url = base_url,
        .api_key = api_key,
        .headers = headers,
        .oauth_enabled = oauth.enabled,
        .oauth_name = oauth.name,
        .oauth_login_ref = oauth.login_ref,
        .oauth_refresh_token_ref = oauth.refresh_token_ref,
        .oauth_get_api_key_ref = oauth.get_api_key_ref,
        .owner_id = owner_id,
        .generation = runner.generation,
        .models = models,
    };
}

fn currentProviderOwnerId(runner: *const runner_mod.ExtensionRunner) []const u8 {
    const source = runner.currentLoadSource() orelse return "lua";
    return source.provenance.state_owner_id;
}

fn requireProviderFieldString(
    L: *c.lua_State,
    table_idx: c_int,
    field: [:0]const u8,
    allocator: std.mem.Allocator,
    missing_err: RegisterProviderError,
    invalid_err: RegisterProviderError,
) RegisterProviderError![]const u8 {
    return FieldReader.init(Lua.init(L), table_idx).requiredString(allocator, field) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.WrongType => {
            _ = c.lua_getfield(L, table_idx, field.ptr);
            defer c.lua_pop(L, 1);
            return if (c.lua_type(L, -1) == c.LUA_TNIL) missing_err else invalid_err;
        },
    };
}

fn optionalProviderFieldString(
    L: *c.lua_State,
    table_idx: c_int,
    field: [:0]const u8,
    allocator: std.mem.Allocator,
    invalid_err: RegisterProviderError,
) RegisterProviderError!?[]const u8 {
    return FieldReader.init(Lua.init(L), table_idx).optionalString(allocator, field) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.WrongType => return invalid_err,
    };
}

fn optionalProviderHeaders(
    L: *c.lua_State,
    table_idx: c_int,
    allocator: std.mem.Allocator,
) RegisterProviderError![]const ai.protocol.Header {
    _ = c.lua_getfield(L, table_idx, "headers");
    defer c.lua_pop(L, 1);

    switch (c.lua_type(L, -1)) {
        c.LUA_TNIL => return &.{},
        c.LUA_TTABLE => {},
        else => return error.InvalidHeaders,
    }

    const headers_idx = c.lua_gettop(L);
    var headers: std.ArrayListUnmanaged(ai.protocol.Header) = .empty;
    errdefer {
        for (headers.items) |header| {
            allocator.free(header.key);
            allocator.free(header.value);
        }
        headers.deinit(allocator);
    }

    c.lua_pushnil(L);
    while (c.lua_next(L, headers_idx) != 0) {
        defer c.lua_pop(L, 1);
        if (c.lua_type(L, -2) != c.LUA_TSTRING) return error.InvalidHeaders;
        if (c.lua_type(L, -1) != c.LUA_TSTRING) return error.InvalidHeaders;
        const key = allocator.dupe(u8, lstring(L, -2)) catch return error.OutOfMemory;
        errdefer allocator.free(key);
        const value = allocator.dupe(u8, lstring(L, -1)) catch return error.OutOfMemory;
        errdefer allocator.free(value);
        try headers.append(allocator, .{ .key = key, .value = value });
    }

    if (headers.items.len == 0) return &.{};
    return headers.toOwnedSlice(allocator);
}

const ProviderOAuthConfig = struct {
    enabled: bool = false,
    name: ?[]const u8 = null,
    login_ref: ?c_int = null,
    refresh_token_ref: ?c_int = null,
    get_api_key_ref: ?c_int = null,
};

fn parseProviderOAuth(
    L: *c.lua_State,
    table_idx: c_int,
    allocator: std.mem.Allocator,
) RegisterProviderError!ProviderOAuthConfig {
    _ = c.lua_getfield(L, table_idx, "oauth");
    defer c.lua_pop(L, 1);

    switch (c.lua_type(L, -1)) {
        c.LUA_TNIL => return .{},
        c.LUA_TTABLE => {},
        else => return error.InvalidOAuth,
    }

    const oauth_idx = c.lua_gettop(L);
    var oauth = ProviderOAuthConfig{ .enabled = true };
    errdefer if (oauth.name) |owned| allocator.free(owned);
    errdefer if (oauth.login_ref) |ref| c.luaL_unref(L, c.LUA_REGISTRYINDEX, ref);
    errdefer if (oauth.refresh_token_ref) |ref| c.luaL_unref(L, c.LUA_REGISTRYINDEX, ref);
    errdefer if (oauth.get_api_key_ref) |ref| c.luaL_unref(L, c.LUA_REGISTRYINDEX, ref);

    c.lua_pushnil(L);
    while (c.lua_next(L, oauth_idx) != 0) {
        defer c.lua_pop(L, 1);
        if (c.lua_type(L, -2) != c.LUA_TSTRING) return error.InvalidOAuth;

        const field = lstring(L, -2);
        if (std.mem.eql(u8, field, "name")) {
            if (c.lua_type(L, -1) != c.LUA_TSTRING) return error.InvalidOAuthName;
            if (oauth.name) |owned| allocator.free(owned);
            oauth.name = allocator.dupe(u8, lstring(L, -1)) catch return error.OutOfMemory;
            continue;
        }
        if (std.mem.eql(u8, field, "login")) {
            if (c.lua_type(L, -1) != c.LUA_TFUNCTION) return error.InvalidOAuthLogin;
            c.lua_pushvalue(L, -1);
            oauth.login_ref = c.luaL_ref(L, c.LUA_REGISTRYINDEX);
            continue;
        }
        if (std.mem.eql(u8, field, "refresh_token")) {
            if (c.lua_type(L, -1) != c.LUA_TFUNCTION) return error.InvalidOAuthRefreshToken;
            c.lua_pushvalue(L, -1);
            oauth.refresh_token_ref = c.luaL_ref(L, c.LUA_REGISTRYINDEX);
            continue;
        }
        if (std.mem.eql(u8, field, "refreshToken")) {
            if (c.lua_type(L, -1) != c.LUA_TFUNCTION) return error.InvalidOAuthRefreshTokenCamel;
            c.lua_pushvalue(L, -1);
            oauth.refresh_token_ref = c.luaL_ref(L, c.LUA_REGISTRYINDEX);
            continue;
        }
        if (std.mem.eql(u8, field, "getApiKey")) {
            if (c.lua_type(L, -1) != c.LUA_TFUNCTION) return error.InvalidOAuthGetApiKey;
            c.lua_pushvalue(L, -1);
            oauth.get_api_key_ref = c.luaL_ref(L, c.LUA_REGISTRYINDEX);
            continue;
        }
        if (std.mem.eql(u8, field, "modifyModels")) return error.UnsupportedOAuthModifyModels;
        return error.InvalidOAuth;
    }

    return oauth;
}

fn rejectDeferredProviderFields(
    L: *c.lua_State,
    table_idx: c_int,
) RegisterProviderError!void {
    try rejectDeferredProviderField(L, table_idx, "auth_header", error.DeferredAuthHeader);
    try rejectDeferredProviderField(L, table_idx, "authHeader", error.DeferredAuthHeaderCamel);
    try rejectDeferredProviderField(L, table_idx, "stream_simple", error.DeferredStreamSimple);
    try rejectDeferredProviderField(L, table_idx, "streamSimple", error.DeferredStreamSimpleCamel);
}

fn rejectDeferredProviderField(
    L: *c.lua_State,
    table_idx: c_int,
    field: [:0]const u8,
    err: RegisterProviderError,
) RegisterProviderError!void {
    _ = c.lua_getfield(L, table_idx, field.ptr);
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TNIL) return err;
}

fn requireProviderFieldBool(
    L: *c.lua_State,
    table_idx: c_int,
    field: [:0]const u8,
    missing_err: RegisterProviderError,
    invalid_err: RegisterProviderError,
) RegisterProviderError!bool {
    _ = c.lua_getfield(L, table_idx, field.ptr);
    defer c.lua_pop(L, 1);

    return switch (c.lua_type(L, -1)) {
        c.LUA_TNIL => missing_err,
        c.LUA_TBOOLEAN => c.lua_toboolean(L, -1) != 0,
        else => invalid_err,
    };
}

fn requireProviderFieldF64(
    L: *c.lua_State,
    table_idx: c_int,
    field: [:0]const u8,
    missing_err: RegisterProviderError,
    invalid_err: RegisterProviderError,
) RegisterProviderError!f64 {
    _ = c.lua_getfield(L, table_idx, field.ptr);
    defer c.lua_pop(L, 1);

    return switch (c.lua_type(L, -1)) {
        c.LUA_TNIL => missing_err,
        c.LUA_TNUMBER => c.lua_tonumberx(L, -1, null),
        else => invalid_err,
    };
}

fn requireProviderFieldU64(
    L: *c.lua_State,
    table_idx: c_int,
    field: [:0]const u8,
    missing_err: RegisterProviderError,
    invalid_err: RegisterProviderError,
) RegisterProviderError!u64 {
    _ = c.lua_getfield(L, table_idx, field.ptr);
    defer c.lua_pop(L, 1);

    return switch (c.lua_type(L, -1)) {
        c.LUA_TNIL => missing_err,
        c.LUA_TNUMBER => blk: {
            if (c.lua_isinteger(L, -1) == 0) return invalid_err;
            const value = c.lua_tointegerx(L, -1, null);
            if (value < 0) return invalid_err;
            break :blk @intCast(value);
        },
        else => invalid_err,
    };
}

fn optionalProviderModels(
    L: *c.lua_State,
    table_idx: c_int,
    allocator: std.mem.Allocator,
) RegisterProviderError![]ai.provider.ClaimModelRegistration {
    _ = c.lua_getfield(L, table_idx, "models");
    defer c.lua_pop(L, 1);

    switch (c.lua_type(L, -1)) {
        c.LUA_TNIL => return &.{},
        c.LUA_TTABLE => {},
        else => return error.InvalidModels,
    }

    const len = c.lua_rawlen(L, -1);
    if (len == 0) return &.{};

    const models = allocator.alloc(ai.provider.ClaimModelRegistration, len) catch return error.OutOfMemory;
    var built: usize = 0;
    errdefer {
        for (models[0..built]) |*model| model.deinit(allocator);
        allocator.free(models);
    }

    var i: c.lua_Integer = 1;
    while (@as(usize, @intCast(i)) <= len) : (i += 1) {
        _ = c.lua_rawgeti(L, -1, i);
        defer c.lua_pop(L, 1);
        if (c.lua_type(L, -1) != c.LUA_TTABLE) return error.InvalidModels;
        const model_idx = c.lua_gettop(L);
        models[built] = try buildProviderModelRegistration(L, model_idx, allocator);
        built += 1;
    }

    return models;
}

fn buildProviderModelRegistration(
    L: *c.lua_State,
    model_idx: c_int,
    allocator: std.mem.Allocator,
) RegisterProviderError!ai.provider.ClaimModelRegistration {
    const id = try requireProviderFieldString(L, model_idx, "id", allocator, error.MissingModelId, error.InvalidModelId);
    errdefer allocator.free(id);

    const name = try requireProviderFieldString(L, model_idx, "name", allocator, error.MissingModelDisplayName, error.InvalidModelDisplayName);
    errdefer allocator.free(name);

    const api = try optionalProviderFieldString(L, model_idx, "api", allocator, error.InvalidModelApi);
    errdefer if (api) |owned| allocator.free(owned);

    const reasoning = try requireProviderFieldBool(L, model_idx, "reasoning", error.MissingModelReasoning, error.InvalidModelReasoning);
    const input = try requireProviderModelInputs(L, model_idx, allocator);
    errdefer if (input.len > 0) allocator.free(input);

    const cost = try requireProviderModelCost(L, model_idx);
    const context_window = try requireProviderFieldU64(L, model_idx, "context_window", error.MissingModelContextWindow, error.InvalidModelContextWindow);
    const max_tokens = try requireProviderFieldU64(L, model_idx, "max_tokens", error.MissingModelMaxTokens, error.InvalidModelMaxTokens);
    const headers = try optionalProviderModelHeaders(L, model_idx, allocator);
    errdefer {
        for (headers) |header| {
            allocator.free(header.key);
            allocator.free(header.value);
        }
        if (headers.len > 0) allocator.free(headers);
    }
    const compat = try optionalProviderModelCompat(L, model_idx, allocator);
    errdefer if (compat) |value| ai.json_util.freeJsonValue(allocator, value);

    return .{
        .id = id,
        .name = name,
        .api = api,
        .reasoning = reasoning,
        .input = input,
        .cost = cost,
        .context_window = context_window,
        .max_tokens = max_tokens,
        .headers = headers,
        .compat = compat,
    };
}

fn requireProviderModelInputs(
    L: *c.lua_State,
    model_idx: c_int,
    allocator: std.mem.Allocator,
) RegisterProviderError![]const ai.protocol.Model.InputType {
    _ = c.lua_getfield(L, model_idx, "input");
    defer c.lua_pop(L, 1);

    switch (c.lua_type(L, -1)) {
        c.LUA_TNIL => return error.MissingModelInput,
        c.LUA_TTABLE => {},
        else => return error.InvalidModelInput,
    }

    const len = c.lua_rawlen(L, -1);
    if (len == 0) return error.InvalidModelInput;

    const input = allocator.alloc(ai.protocol.Model.InputType, len) catch return error.OutOfMemory;
    var built: usize = 0;
    errdefer allocator.free(input);

    var i: c.lua_Integer = 1;
    while (@as(usize, @intCast(i)) <= len) : (i += 1) {
        _ = c.lua_rawgeti(L, -1, i);
        defer c.lua_pop(L, 1);
        if (c.lua_type(L, -1) != c.LUA_TSTRING) return error.InvalidModelInput;
        const value = lstring(L, -1);
        input[built] = if (std.mem.eql(u8, value, "text"))
            .text
        else if (std.mem.eql(u8, value, "image"))
            .image
        else
            return error.InvalidModelInput;
        built += 1;
    }

    return input;
}

fn requireProviderModelCost(
    L: *c.lua_State,
    model_idx: c_int,
) RegisterProviderError!ai.protocol.Model.Cost {
    _ = c.lua_getfield(L, model_idx, "cost");
    defer c.lua_pop(L, 1);

    switch (c.lua_type(L, -1)) {
        c.LUA_TNIL => return error.MissingModelCost,
        c.LUA_TTABLE => {},
        else => return error.InvalidModelCost,
    }

    const cost_idx = c.lua_gettop(L);
    return .{
        .input = try requireProviderFieldF64(L, cost_idx, "input", error.MissingModelCost, error.InvalidModelCost),
        .output = try requireProviderFieldF64(L, cost_idx, "output", error.MissingModelCost, error.InvalidModelCost),
        .cache_read = try requireProviderFieldF64(L, cost_idx, "cache_read", error.MissingModelCost, error.InvalidModelCost),
        .cache_write = try requireProviderFieldF64(L, cost_idx, "cache_write", error.MissingModelCost, error.InvalidModelCost),
    };
}

fn optionalProviderModelHeaders(
    L: *c.lua_State,
    model_idx: c_int,
    allocator: std.mem.Allocator,
) RegisterProviderError![]const ai.protocol.Header {
    _ = c.lua_getfield(L, model_idx, "headers");
    defer c.lua_pop(L, 1);

    switch (c.lua_type(L, -1)) {
        c.LUA_TNIL => return &.{},
        c.LUA_TTABLE => {},
        else => return error.InvalidModelHeaders,
    }

    const headers_idx = c.lua_gettop(L);
    var headers: std.ArrayListUnmanaged(ai.protocol.Header) = .empty;
    errdefer {
        for (headers.items) |header| {
            allocator.free(header.key);
            allocator.free(header.value);
        }
        headers.deinit(allocator);
    }

    c.lua_pushnil(L);
    while (c.lua_next(L, headers_idx) != 0) {
        defer c.lua_pop(L, 1);
        if (c.lua_type(L, -2) != c.LUA_TSTRING) return error.InvalidModelHeaders;
        if (c.lua_type(L, -1) != c.LUA_TSTRING) return error.InvalidModelHeaders;
        const key = allocator.dupe(u8, lstring(L, -2)) catch return error.OutOfMemory;
        errdefer allocator.free(key);
        const value = allocator.dupe(u8, lstring(L, -1)) catch return error.OutOfMemory;
        errdefer allocator.free(value);
        try headers.append(allocator, .{ .key = key, .value = value });
    }

    if (headers.items.len == 0) return &.{};
    return headers.toOwnedSlice(allocator);
}

fn optionalProviderModelCompat(
    L: *c.lua_State,
    model_idx: c_int,
    allocator: std.mem.Allocator,
) RegisterProviderError!?std.json.Value {
    _ = c.lua_getfield(L, model_idx, "compat");
    defer c.lua_pop(L, 1);

    return switch (c.lua_type(L, -1)) {
        c.LUA_TNIL => null,
        c.LUA_TTABLE => blk: {
            var budget = lua_runtime.JsonConvertBudget{ .limits = lua_runtime.default_json_convert_limits };
            break :blk lua_runtime.luaValueToJsonLimited(L, -1, allocator, &budget) catch |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.InvalidModelCompat,
            };
        },
        else => error.InvalidModelCompat,
    };
}

fn lstring(L: *c.lua_State, idx: c_int) []const u8 {
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, idx, &len) orelse return &.{};
    return ptr[0..len];
}

fn luaError(L: *c.lua_State, msg: [:0]const u8) c_int {
    return lua_helpers.raiseError(Lua.init(L), msg);
}

fn runnerFromUpvalue(L: *c.lua_State) *runner_mod.ExtensionRunner {
    return lua_helpers.ptrFromUpvalue(runner_mod.ExtensionRunner, Lua.init(L), 1);
}
