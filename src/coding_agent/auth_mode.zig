const std = @import("std");
const ai = @import("../ai/root.zig");
const auth_mod = @import("auth.zig");
const paths_mod = @import("paths.zig");

pub const Options = struct {
    cwd: []const u8 = ".",
    agent_dir: []const u8 = paths_mod.global_config_dir_name,
    dir: std.Io.Dir = .cwd(),
    environ: ?*const std.process.Environ.Map = null,
};

pub fn login(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    provider: ai.Provider,
    options: Options,
) !void {
    const oauth_provider = oauthProvider(provider) orelse {
        try stderr.print("unknown oauth provider: {s}\n", .{provider});
        return error.UnsupportedOAuthProvider;
    };
    var auth = try auth_mod.AuthManager.init(allocator, io, .{
        .environ = options.environ,
        .paths = .{ .global_dir = options.agent_dir, .cwd = options.cwd },
        .dir = options.dir,
    });
    defer auth.deinit();

    var callbacks: LoginCallbacks = .{ .stdout = stdout, .stderr = stderr };
    try auth.loginOAuth(io, oauth_provider, .{
        .context = &callbacks,
        .on_auth_fn = LoginCallbacks.onAuth,
        .on_prompt_fn = LoginCallbacks.onPrompt,
        .on_progress_fn = LoginCallbacks.onProgress,
    });
    try stdout.print("authenticated {s}\n", .{provider});
}

pub fn logout(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: *std.Io.Writer,
    provider: ai.Provider,
    options: Options,
) !void {
    var auth = try auth_mod.AuthManager.init(allocator, io, .{
        .environ = options.environ,
        .paths = .{ .global_dir = options.agent_dir, .cwd = options.cwd },
        .dir = options.dir,
    });
    defer auth.deinit();

    try auth.removeCredentials(io, provider);
    try stdout.print("logged out {s}\n", .{provider});
}

fn oauthProvider(provider: ai.Provider) ?ai.OAuthProviderInterface {
    if (std.mem.eql(u8, provider, ai.KnownProvider.openai_codex)) return ai.openai_codex_oauth_provider;
    return null;
}

const LoginCallbacks = struct {
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,

    fn onAuth(context: ?*anyopaque, info: ai.OAuthAuthInfo) !void {
        const self: *LoginCallbacks = @ptrCast(@alignCast(context.?));
        try self.stdout.print("open {s}\n", .{info.url});
        if (info.instructions) |instructions| try self.stdout.print("{s}\n", .{instructions});
    }

    fn onPrompt(context: ?*anyopaque, prompt: ai.OAuthPrompt) ![]const u8 {
        const self: *LoginCallbacks = @ptrCast(@alignCast(context.?));
        try self.stderr.print("{s}\n", .{prompt.message});
        return error.ManualOAuthPromptUnsupported;
    }

    fn onProgress(context: ?*anyopaque, message: []const u8) !void {
        const self: *LoginCallbacks = @ptrCast(@alignCast(context.?));
        try self.stdout.print("{s}\n", .{message});
    }
};

test "auth mode login rejects unsupported oauth provider" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stdout_buffer: [128]u8 = undefined;
    var stdout = std.Io.Writer.fixed(&stdout_buffer);
    var stderr_buffer: [128]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);

    try std.testing.expectError(
        error.UnsupportedOAuthProvider,
        login(std.testing.allocator, std.testing.io, &stdout, &stderr, "missing", .{
            .cwd = "repo",
            .agent_dir = "agent",
            .dir = tmp.dir,
        }),
    );
    try std.testing.expectEqualStrings("", stdout.buffered());
    try std.testing.expectEqualStrings("unknown oauth provider: missing\n", stderr.buffered());
}

test "auth mode logout removes stored provider auth" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "agent/auth.json",
        .data =
        \\{"openai-codex":{"type":"oauth","refresh":"refresh-token","access":"access-token","expires":123}}
        ,
    });

    var output_buffer: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    try logout(std.testing.allocator, std.testing.io, &output, ai.KnownProvider.openai_codex, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .dir = tmp.dir,
    });

    const bytes = try tmp.dir.readFileAlloc(std.testing.io, "agent/auth.json", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("logged out openai-codex\n", output.buffered());
    try std.testing.expectEqualStrings("{}\n", bytes);
}
