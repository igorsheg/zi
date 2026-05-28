const std = @import("std");
const ai = @import("../ai/root.zig");
const auth_mod = @import("auth.zig");
const paths_mod = @import("paths.zig");

pub const max_manual_input_bytes = 16 * 1024;

pub const Options = struct {
    cwd: []const u8 = ".",
    agent_dir_override: ?[]const u8 = null,
    dir: std.Io.Dir = .cwd(),
    environ: ?*const std.process.Environ.Map = null,
    stdin: ?*std.Io.Reader = null,
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
    var auth = try initAuth(allocator, io, options);
    defer auth.deinit();

    var stdin_buffer: [max_manual_input_bytes]u8 = undefined;
    var stdin_file_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buffer);
    var callbacks: LoginCallbacks = .{
        .stdout = stdout,
        .stderr = stderr,
        .stdin = options.stdin orelse &stdin_file_reader.interface,
    };
    try auth.loginOAuth(io, oauth_provider, .{
        .context = &callbacks,
        .on_auth_fn = LoginCallbacks.onAuth,
        .on_prompt_fn = LoginCallbacks.onPrompt,
        .on_progress_fn = LoginCallbacks.onProgress,
        .on_manual_code_input_fn = LoginCallbacks.onManualCodeInput,
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
    var auth = try initAuth(allocator, io, options);
    defer auth.deinit();

    try auth.removeCredentials(io, provider);
    try stdout.print("logged out {s}\n", .{provider});
}

pub fn status(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: *std.Io.Writer,
    provider: ai.Provider,
    options: Options,
) !void {
    var auth = try initAuth(allocator, io, options);
    defer auth.deinit();

    const state: []const u8 = if (auth.hasAuth(provider)) "authenticated" else "missing";
    try stdout.print("{s}: {s}\n", .{ provider, state });
}

fn initAuth(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
) !auth_mod.AuthManager {
    const resolved_agent_dir = if (options.agent_dir_override) |agent_dir_override|
        agent_dir_override
    else
        try paths_mod.resolveGlobalAgentDirFromEnv(allocator, options.environ);
    defer if (options.agent_dir_override == null) allocator.free(resolved_agent_dir);

    return auth_mod.AuthManager.init(allocator, io, .{
        .environ = options.environ,
        .paths = .{ .global_dir = resolved_agent_dir, .cwd = options.cwd },
        .dir = options.dir,
    });
}

fn oauthProvider(provider: ai.Provider) ?ai.OAuthProviderInterface {
    if (std.mem.eql(u8, provider, ai.KnownProvider.openai_codex)) return ai.openai_codex_oauth_provider;
    return null;
}

const LoginCallbacks = struct {
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    stdin: *std.Io.Reader,

    fn onAuth(context: ?*anyopaque, info: ai.OAuthAuthInfo) !void {
        const self: *LoginCallbacks = @ptrCast(@alignCast(context.?));
        try self.stdout.print("open {s}\n", .{info.url});
        if (info.instructions) |instructions| try self.stdout.print("{s}\n", .{instructions});
        try self.stdout.flush();
    }

    fn onPrompt(context: ?*anyopaque, prompt: ai.OAuthPrompt) ![]const u8 {
        const self: *LoginCallbacks = @ptrCast(@alignCast(context.?));
        try self.stderr.print("{s}\n", .{prompt.message});
        try self.stderr.flush();
        return self.readLine();
    }

    fn onManualCodeInput(context: ?*anyopaque) ![]const u8 {
        const self: *LoginCallbacks = @ptrCast(@alignCast(context.?));
        try self.stderr.writeAll("paste redirect url or code, then press enter:\n");
        try self.stderr.flush();
        return self.readLine();
    }

    fn readLine(self: *LoginCallbacks) ![]const u8 {
        const line = try self.stdin.takeDelimiter('\n') orelse return error.EmptyManualOAuthInput;
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) return error.EmptyManualOAuthInput;
        return trimmed;
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
            .agent_dir_override = "agent",
            .dir = tmp.dir,
        }),
    );
    try std.testing.expectEqualStrings("", stdout.buffered());
    try std.testing.expectEqualStrings("unknown oauth provider: missing\n", stderr.buffered());
}

test "auth mode reads manual oauth input" {
    var input = std.Io.Reader.fixed("  redirect-url\n");
    var stdout_buffer: [256]u8 = undefined;
    var stdout = std.Io.Writer.fixed(&stdout_buffer);
    var stderr_buffer: [256]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    var callbacks: LoginCallbacks = .{
        .stdout = &stdout,
        .stderr = &stderr,
        .stdin = &input,
    };
    const value = try LoginCallbacks.onManualCodeInput(&callbacks);

    try std.testing.expectEqualStrings("redirect-url", value);
    try std.testing.expectEqualStrings("paste redirect url or code, then press enter:\n", stderr.buffered());
}

test "auth mode prompt reads bounded oauth input" {
    var input = std.Io.Reader.fixed("prompt-code\n");
    var stdout_buffer: [256]u8 = undefined;
    var stdout = std.Io.Writer.fixed(&stdout_buffer);
    var stderr_buffer: [256]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    var callbacks: LoginCallbacks = .{
        .stdout = &stdout,
        .stderr = &stderr,
        .stdin = &input,
    };
    const value = try LoginCallbacks.onPrompt(&callbacks, .{ .message = "enter code:" });

    try std.testing.expectEqualStrings("prompt-code", value);
    try std.testing.expectEqualStrings("enter code:\n", stderr.buffered());
}

test "auth mode status reports stored oauth auth" {
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
    try status(std.testing.allocator, std.testing.io, &output, ai.KnownProvider.openai_codex, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .dir = tmp.dir,
    });

    try std.testing.expectEqualStrings("openai-codex: authenticated\n", output.buffered());
}

test "auth mode status reports env auth" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "agent");
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("OPENAI_API_KEY", "secret");

    var output_buffer: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    try status(std.testing.allocator, std.testing.io, &output, ai.KnownProvider.openai, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .dir = tmp.dir,
        .environ = &environ,
    });

    try std.testing.expectEqualStrings("openai: authenticated\n", output.buffered());
}

test "auth mode status reports missing auth" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "agent");

    var output_buffer: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    try status(std.testing.allocator, std.testing.io, &output, ai.KnownProvider.openai, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .dir = tmp.dir,
    });

    try std.testing.expectEqualStrings("openai: missing\n", output.buffered());
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
        .agent_dir_override = "agent",
        .dir = tmp.dir,
    });

    const bytes = try tmp.dir.readFileAlloc(std.testing.io, "agent/auth.json", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("logged out openai-codex\n", output.buffered());
    try std.testing.expectEqualStrings("{}\n", bytes);
}
