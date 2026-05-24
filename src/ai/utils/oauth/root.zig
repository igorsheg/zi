const std = @import("std");
const protocol = @import("../../protocol.zig");

pub const openai_codex = @import("openai_codex.zig");
pub const page = @import("page.zig");
pub const pkce = @import("pkce.zig");

pub const PkcePair = pkce.PkcePair;
pub const generatePkce = pkce.generate;
pub const oauthSuccessHtml = page.successHtml;
pub const oauthErrorHtml = page.errorHtml;

pub const OAuthProviderId = []const u8;
pub const OAuthProvider = OAuthProviderId;

pub const OAuthCredentials = struct {
    refresh: []const u8,
    access: []const u8,
    expires: i64,
    extra: ?std.json.Value = null,
};

pub const OAuthPrompt = struct {
    message: []const u8,
    placeholder: ?[]const u8 = null,
    allow_empty: bool = false,
};

pub const OAuthAuthInfo = struct {
    url: []const u8,
    instructions: ?[]const u8 = null,
};

pub const OAuthLoginCallbacks = struct {
    context: ?*anyopaque = null,
    on_auth_fn: *const fn (?*anyopaque, OAuthAuthInfo) anyerror!void,
    on_prompt_fn: *const fn (?*anyopaque, OAuthPrompt) anyerror![]const u8,
    on_progress_fn: ?*const fn (?*anyopaque, []const u8) anyerror!void = null,
    on_manual_code_input_fn: ?*const fn (?*anyopaque) anyerror![]const u8 = null,

    pub fn onAuth(self: OAuthLoginCallbacks, info: OAuthAuthInfo) !void {
        try self.on_auth_fn(self.context, info);
    }

    pub fn onPrompt(self: OAuthLoginCallbacks, prompt: OAuthPrompt) ![]const u8 {
        return self.on_prompt_fn(self.context, prompt);
    }

    pub fn onProgress(self: OAuthLoginCallbacks, message: []const u8) !void {
        if (self.on_progress_fn) |callback| try callback(self.context, message);
    }

    pub fn onManualCodeInput(self: OAuthLoginCallbacks) !?[]const u8 {
        return if (self.on_manual_code_input_fn) |callback| try callback(self.context) else null;
    }
};

pub const OAuthProviderInterface = struct {
    id: OAuthProviderId,
    name: []const u8,
    uses_callback_server: bool = false,
    context: ?*anyopaque = null,
    login_fn: *const fn (std.mem.Allocator, std.Io, ?*anyopaque, OAuthLoginCallbacks) anyerror!OAuthCredentials,
    refresh_token_fn: *const fn (std.mem.Allocator, std.Io, ?*anyopaque, OAuthCredentials) anyerror!OAuthCredentials,
    get_api_key_fn: *const fn (?*anyopaque, OAuthCredentials) anyerror![]const u8,
    modify_models_fn: ?*const fn (?*anyopaque, []protocol.Model, OAuthCredentials) anyerror![]protocol.Model = null,

    pub fn login(
        self: OAuthProviderInterface,
        allocator: std.mem.Allocator,
        io: std.Io,
        callbacks: OAuthLoginCallbacks,
    ) !OAuthCredentials {
        return self.login_fn(allocator, io, self.context, callbacks);
    }

    pub fn refreshToken(
        self: OAuthProviderInterface,
        allocator: std.mem.Allocator,
        io: std.Io,
        credentials: OAuthCredentials,
    ) !OAuthCredentials {
        return self.refresh_token_fn(allocator, io, self.context, credentials);
    }

    pub fn getApiKey(self: OAuthProviderInterface, credentials: OAuthCredentials) ![]const u8 {
        return self.get_api_key_fn(self.context, credentials);
    }

    pub fn modifyModels(
        self: OAuthProviderInterface,
        models: []protocol.Model,
        credentials: OAuthCredentials,
    ) ![]protocol.Model {
        return if (self.modify_models_fn) |callback|
            try callback(self.context, models, credentials)
        else
            models;
    }
};

pub const OAuthProviderInfo = struct {
    id: OAuthProviderId,
    name: []const u8,
    available: bool,
};

pub const openai_codex_oauth_provider = openai_codex.openai_codex_oauth_provider;

test "oauth credentials carry core token fields and provider extras" {
    const credentials: OAuthCredentials = .{
        .refresh = "refresh-token",
        .access = "access-token",
        .expires = 123,
        .extra = .{ .object = .empty },
    };

    try std.testing.expectEqualStrings("refresh-token", credentials.refresh);
    try std.testing.expectEqualStrings("access-token", credentials.access);
    try std.testing.expectEqual(@as(i64, 123), credentials.expires);
    try std.testing.expect(credentials.extra.? == .object);
}

test "oauth callbacks route through context" {
    var calls: CallbackCalls = .{};
    const callbacks: OAuthLoginCallbacks = .{
        .context = &calls,
        .on_auth_fn = testOnAuth,
        .on_prompt_fn = testOnPrompt,
        .on_progress_fn = testOnProgress,
        .on_manual_code_input_fn = testOnManualCodeInput,
    };

    try callbacks.onAuth(.{ .url = "https://example.test", .instructions = "open" });
    const prompt = try callbacks.onPrompt(.{ .message = "code", .placeholder = "123" });
    try callbacks.onProgress("progress");
    const manual = try callbacks.onManualCodeInput();

    try std.testing.expectEqual(@as(usize, 1), calls.auth_count);
    try std.testing.expectEqual(@as(usize, 1), calls.prompt_count);
    try std.testing.expectEqual(@as(usize, 1), calls.progress_count);
    try std.testing.expectEqual(@as(usize, 1), calls.manual_count);
    try std.testing.expectEqualStrings("prompt-response", prompt);
    try std.testing.expectEqualStrings("manual-code", manual.?);
}

test "oauth provider interface delegates to callbacks" {
    var calls: ProviderCalls = .{};
    const provider: OAuthProviderInterface = .{
        .id = "test-provider",
        .name = "Test Provider",
        .uses_callback_server = true,
        .context = &calls,
        .login_fn = testLogin,
        .refresh_token_fn = testRefreshToken,
        .get_api_key_fn = testGetApiKey,
        .modify_models_fn = testModifyModels,
    };
    const callbacks: OAuthLoginCallbacks = .{ .on_auth_fn = noopOnAuth, .on_prompt_fn = noopOnPrompt };
    const credentials = try provider.login(std.testing.allocator, std.Io.failing, callbacks);
    const refreshed = try provider.refreshToken(std.testing.allocator, std.Io.failing, credentials);
    const api_key = try provider.getApiKey(refreshed);
    var models = [_]protocol.Model{testModel()};
    const modified_models = try provider.modifyModels(&models, refreshed);

    try std.testing.expectEqual(@as(usize, 1), calls.login_count);
    try std.testing.expectEqual(@as(usize, 1), calls.refresh_count);
    try std.testing.expectEqual(@as(usize, 1), calls.api_key_count);
    try std.testing.expectEqual(@as(usize, 1), calls.modify_models_count);
    try std.testing.expectEqualStrings("refreshed", refreshed.access);
    try std.testing.expectEqualStrings("refreshed", api_key);
    try std.testing.expectEqual(@as(usize, 1), modified_models.len);
}

const CallbackCalls = struct {
    auth_count: usize = 0,
    prompt_count: usize = 0,
    progress_count: usize = 0,
    manual_count: usize = 0,
};

fn testOnAuth(context: ?*anyopaque, info: OAuthAuthInfo) !void {
    const calls: *CallbackCalls = @ptrCast(@alignCast(context.?));
    calls.auth_count += 1;
    try std.testing.expectEqualStrings("https://example.test", info.url);
    try std.testing.expectEqualStrings("open", info.instructions.?);
}

fn testOnPrompt(context: ?*anyopaque, prompt: OAuthPrompt) ![]const u8 {
    const calls: *CallbackCalls = @ptrCast(@alignCast(context.?));
    calls.prompt_count += 1;
    try std.testing.expectEqualStrings("code", prompt.message);
    try std.testing.expectEqualStrings("123", prompt.placeholder.?);
    return "prompt-response";
}

fn testOnProgress(context: ?*anyopaque, message: []const u8) !void {
    const calls: *CallbackCalls = @ptrCast(@alignCast(context.?));
    calls.progress_count += 1;
    try std.testing.expectEqualStrings("progress", message);
}

fn testOnManualCodeInput(context: ?*anyopaque) ![]const u8 {
    const calls: *CallbackCalls = @ptrCast(@alignCast(context.?));
    calls.manual_count += 1;
    return "manual-code";
}

const ProviderCalls = struct {
    login_count: usize = 0,
    refresh_count: usize = 0,
    api_key_count: usize = 0,
    modify_models_count: usize = 0,
};

fn testLogin(
    _: std.mem.Allocator,
    _: std.Io,
    context: ?*anyopaque,
    callbacks: OAuthLoginCallbacks,
) !OAuthCredentials {
    const calls: *ProviderCalls = @ptrCast(@alignCast(context.?));
    calls.login_count += 1;
    try callbacks.onAuth(.{ .url = "https://example.test" });
    return .{ .refresh = "refresh", .access = "access", .expires = 1 };
}

fn testRefreshToken(
    _: std.mem.Allocator,
    _: std.Io,
    context: ?*anyopaque,
    credentials: OAuthCredentials,
) !OAuthCredentials {
    const calls: *ProviderCalls = @ptrCast(@alignCast(context.?));
    calls.refresh_count += 1;
    return .{ .refresh = credentials.refresh, .access = "refreshed", .expires = 2 };
}

fn testGetApiKey(context: ?*anyopaque, credentials: OAuthCredentials) ![]const u8 {
    const calls: *ProviderCalls = @ptrCast(@alignCast(context.?));
    calls.api_key_count += 1;
    return credentials.access;
}

fn testModifyModels(
    context: ?*anyopaque,
    models: []protocol.Model,
    _: OAuthCredentials,
) ![]protocol.Model {
    const calls: *ProviderCalls = @ptrCast(@alignCast(context.?));
    calls.modify_models_count += 1;
    return models;
}

fn noopOnAuth(_: ?*anyopaque, _: OAuthAuthInfo) !void {}

fn noopOnPrompt(_: ?*anyopaque, _: OAuthPrompt) ![]const u8 {
    return "";
}

fn testModel() protocol.Model {
    return .{
        .id = "test-model",
        .name = "Test Model",
        .api = protocol.KnownApi.openai_responses,
        .provider = protocol.KnownProvider.openai,
        .base_url = "https://example.test",
        .reasoning = false,
        .input = &.{.text},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 1,
        .max_tokens = 1,
    };
}
