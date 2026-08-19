const std = @import("std");
const ai = @import("../ai/root.zig");
const CredentialStore = @import("CredentialStore.zig");
const ModelConfig = @import("ModelConfig.zig");
const ZiPaths = @import("ZiPaths.zig");

pub const Error = error{
    OutOfMemory,
    InvalidCredentialFile,
    UnsupportedVersion,
    UnsafePath,
    ReadFailed,
    LockFailed,
    WriteFailed,
    CommitIndeterminate,
    Cancelled,
    TimedOut,
    InvalidUrl,
    InvalidRequest,
    ConnectionFailed,
    InvalidResponse,
    ResponseTooLarge,
    ConsumerStopped,
    Rejected,
    InvalidModelConfiguration,
    AuthenticationUnavailable,
    RefreshUnavailable,
};

pub const LoginInputs = struct {
    provider_id: []const u8,
    method: ai.oauth.LoginMethod,
    interaction: ai.oauth.Interaction,
    now_ms: u64,
};

pub const PersistentResolver = struct {
    allocator: std.mem.Allocator,
    paths: ZiPaths,
    model_config: ModelConfig,
    selection: ai.ModelIdentity,
    explicit_api_key: ?[]const u8,
    environment: ai.auth.Environment,
    clock_context: *anyopaque,
    now_ms_fn: *const fn (*anyopaque) u64,
    current: ?CredentialStore.Snapshot = null,

    pub fn init(
        allocator: std.mem.Allocator,
        cwd: []const u8,
        home: []const u8,
        model_config: ModelConfig,
        selection: ai.ModelIdentity,
        explicit_api_key: ?[]const u8,
        environment: ai.auth.Environment,
        clock_context: *anyopaque,
        now_ms_fn: *const fn (*anyopaque) u64,
    ) !*PersistentResolver {
        const self = try allocator.create(PersistentResolver);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .paths = try ZiPaths.init(allocator, cwd, home),
            .model_config = model_config,
            .selection = selection,
            .explicit_api_key = explicit_api_key,
            .environment = environment,
            .clock_context = clock_context,
            .now_ms_fn = now_ms_fn,
        };
        return self;
    }

    // Heap destruction follows explicit field invalidation.
    // ziglint-ignore: Z030
    pub fn deinit(self: *PersistentResolver) void {
        const allocator = self.allocator;
        if (self.current) |*snapshot| snapshot.deinit();
        self.paths.deinit();
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn resolver(self: *PersistentResolver) ai.auth.Resolver {
        return .{ .context = self, .resolve_fn = resolve };
    }

    // Context leads because this callback implements the erased resolver ABI.
    // ziglint-ignore: Z023
    fn resolve(
        context: *anyopaque,
        _: std.mem.Allocator, // ziglint-ignore: Z023
        _: std.mem.Allocator, // ziglint-ignore: Z023
        io: std.Io, // ziglint-ignore: Z023
        transport: ai.transport.Transport,
        policy: ai.auth.ProviderAuth,
        provider_id: []const u8,
        _: ai.auth.Inputs,
    ) anyerror!ai.ModelAuth {
        const self: *PersistentResolver = @ptrCast(@alignCast(context));
        if (self.current) |*snapshot| snapshot.deinit();
        self.current = null;
        self.current = try loadForRuntime(
            self.allocator,
            io,
            &self.paths,
            transport,
            .{
                .model_config = self.model_config,
                .selection = self.selection,
                .explicit_api_key = self.explicit_api_key,
                .now_ms = self.now_ms_fn(self.clock_context),
            },
        );
        return ai.auth.resolve(policy, provider_id, .{
            .explicit_api_key = self.explicit_api_key,
            .stored = self.current.?.entries,
            .environment = self.environment,
        });
    }
};

pub const Inputs = struct {
    model_config: ModelConfig,
    selection: ai.ModelIdentity,
    explicit_api_key: ?[]const u8 = null,
    now_ms: u64,
};

pub fn login(
    allocator: std.mem.Allocator,
    io: std.Io,
    paths: *const ZiPaths,
    transport: ai.transport.Transport,
    model_config: ModelConfig,
    inputs: LoginInputs,
) Error!void {
    const provider = model_config.findProvider(inputs.provider_id) orelse
        return error.InvalidModelConfiguration;
    const oauth_policy = provider.auth.oauth orelse return error.InvalidModelConfiguration;
    const authenticator = oauth_policy.authenticator orelse return error.AuthenticationUnavailable;
    var authenticated = try authenticator.login(
        allocator,
        allocator,
        io,
        transport,
        .{
            .method = inputs.method,
            .interaction = inputs.interaction,
            .now_ms = inputs.now_ms,
        },
    );
    defer authenticated.deinit();
    try CredentialStore.put(allocator, io, paths, .{
        .provider_id = provider.id,
        .credential = .{ .oauth = authenticated.credential },
    });
}

pub fn logout(
    allocator: std.mem.Allocator,
    io: std.Io,
    paths: *const ZiPaths,
    provider_id: []const u8,
) Error!bool {
    return CredentialStore.remove(allocator, io, paths, provider_id);
}

pub fn loadForRuntime(
    allocator: std.mem.Allocator,
    io: std.Io,
    paths: *const ZiPaths,
    transport: ai.transport.Transport,
    inputs: Inputs,
) Error!CredentialStore.Snapshot {
    if (inputs.explicit_api_key != null) return CredentialStore.empty(allocator);
    var snapshot = try CredentialStore.load(allocator, io, paths);
    var snapshot_live = true;
    errdefer if (snapshot_live) snapshot.deinit();
    if (!needsRefresh(snapshot.entries, inputs)) return snapshot;
    snapshot.deinit();
    snapshot_live = false;

    var mutation = try CredentialStore.beginMutation(io, paths);
    defer mutation.deinit();
    var current = try mutation.load(allocator);
    defer current.deinit();
    if (!needsRefresh(current.entries, inputs)) {
        return mutation.load(allocator);
    }

    const selected = inputs.model_config.resolve(inputs.selection) orelse
        return error.InvalidModelConfiguration;
    const provider = inputs.model_config.findProvider(selected.providerId()) orelse
        return error.InvalidModelConfiguration;
    const oauth_policy = provider.auth.oauth orelse return error.InvalidModelConfiguration;
    const refresher = oauth_policy.refresher orelse return error.RefreshUnavailable;
    const stored = findCredential(current.entries, provider.id) orelse
        return error.InvalidModelConfiguration;
    const existing = switch (stored) {
        .oauth => |oauth| oauth,
        .api_key => return error.InvalidModelConfiguration,
    };

    var refreshed = try refresher.refresh(
        allocator,
        allocator,
        io,
        transport,
        .{ .credential = existing, .now_ms = inputs.now_ms },
    );
    defer refreshed.deinit();
    try mutation.put(allocator, .{
        .provider_id = provider.id,
        .credential = .{ .oauth = refreshed.credential },
    });
    return mutation.load(allocator);
}

fn needsRefresh(entries: []const ai.credential.Entry, inputs: Inputs) bool {
    const selected = inputs.model_config.resolve(inputs.selection) orelse return false;
    const provider = inputs.model_config.findProvider(selected.providerId()) orelse return false;
    const oauth_policy = provider.auth.oauth orelse return false;
    const stored = findCredential(entries, provider.id) orelse return false;
    const oauth = switch (stored) {
        .oauth => |value| value,
        .api_key => return false,
    };
    const refresh_at = oauth.expires_at_ms -| oauth_policy.refresh_skew_ms;
    return refresh_at <= inputs.now_ms;
}

fn findCredential(entries: []const ai.credential.Entry, provider_id: []const u8) ?ai.Credential {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.provider_id, provider_id)) return entry.credential;
    }
    return null;
}

fn temporaryPath(temporary: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
    const length = try temporary.dir.realPath(std.testing.io, buffer);
    return buffer[0..length];
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

test "expired Codex credentials refresh and persist under one store mutation" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try temporaryPath(&temporary, &root_buffer);
    var paths = try ZiPaths.init(std.testing.allocator, root, root);
    defer paths.deinit();
    try CredentialStore.put(std.testing.allocator, std.testing.io, &paths, .{
        .provider_id = "openai-codex",
        .credential = .{ .oauth = .{
            .access = "expired-access",
            .refresh = "old-refresh",
            .expires_at_ms = 100,
            .account_id = "old-account",
        } },
    });

    const access = try testAccessToken(std.testing.allocator, "new-account");
    defer std.testing.allocator.free(access);
    const response_body = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"access_token\":\"{s}\",\"refresh_token\":\"new-refresh\",\"expires_in\":3600}}",
        .{access},
    );
    defer std.testing.allocator.free(response_body);
    const exchanges = [_]ai.transport_testing.Exchange{.{ .response = .{
        .status = 200,
        .body = response_body,
    } }};
    var fake = ai.transport_testing.FakeTransport.init(&exchanges);
    var snapshot = try loadForRuntime(
        std.testing.allocator,
        std.testing.io,
        &paths,
        fake.transport(),
        .{
            .model_config = ModelConfig.builtin,
            .selection = .{ .provider = "openai-codex", .model = "gpt-5.6-terra" },
            .now_ms = 1000,
        },
    );
    defer snapshot.deinit();

    try std.testing.expectEqual(@as(usize, 1), snapshot.entries.len);
    const refreshed = snapshot.entries[0].credential.oauth;
    try std.testing.expectEqualStrings(access, refreshed.access);
    try std.testing.expectEqualStrings("new-refresh", refreshed.refresh);
    try std.testing.expectEqualStrings("new-account", refreshed.account_id.?);
    try std.testing.expectEqual(@as(u64, 3_601_000), refreshed.expires_at_ms);
    try std.testing.expectEqual(@as(usize, 1), fake.next_index);
}

test "failed OAuth refresh preserves the stored credential" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try temporaryPath(&temporary, &root_buffer);
    var paths = try ZiPaths.init(std.testing.allocator, root, root);
    defer paths.deinit();
    try CredentialStore.put(std.testing.allocator, std.testing.io, &paths, .{
        .provider_id = "openai-codex",
        .credential = .{ .oauth = .{
            .access = "expired-access",
            .refresh = "preserved-refresh",
            .expires_at_ms = 1,
            .account_id = "preserved-account",
        } },
    });
    const exchanges = [_]ai.transport_testing.Exchange{.{ .response = .{
        .status = 400,
        .body = "{\"error\":\"invalid_grant\"}",
    } }};
    var fake = ai.transport_testing.FakeTransport.init(&exchanges);
    try std.testing.expectError(error.Rejected, loadForRuntime(
        std.testing.allocator,
        std.testing.io,
        &paths,
        fake.transport(),
        .{
            .model_config = ModelConfig.builtin,
            .selection = .{ .provider = "openai-codex", .model = "gpt-5.6-terra" },
            .now_ms = 1000,
        },
    ));
    var stored = try CredentialStore.load(std.testing.allocator, std.testing.io, &paths);
    defer stored.deinit();
    const oauth = stored.entries[0].credential.oauth;
    try std.testing.expectEqualStrings("expired-access", oauth.access);
    try std.testing.expectEqualStrings("preserved-refresh", oauth.refresh);
    try std.testing.expectEqualStrings("preserved-account", oauth.account_id.?);
}

test "fresh OAuth credentials do not contact the refresh transport" {
    const entries = [_]ai.credential.Entry{.{
        .provider_id = "openai-codex",
        .credential = .{ .oauth = .{
            .access = "fresh-access",
            .refresh = "fresh-refresh",
            .expires_at_ms = 1_000_000,
        } },
    }};
    try std.testing.expect(!needsRefresh(&entries, .{
        .model_config = ModelConfig.builtin,
        .selection = .{ .provider = "openai-codex", .model = "gpt-5.6-terra" },
        .now_ms = 1000,
    }));
}
