const std = @import("std");
const ai = @import("../../ai/root.zig");
const CredentialManager = @import("../CredentialManager.zig");
const ModelConfig = @import("../ModelConfig.zig");
const ZiPaths = @import("../ZiPaths.zig");
const args = @import("args.zig");

pub const ExitCode = enum(u8) {
    success = 0,
    failure = 1,
};

const TerminalInteraction = struct {
    stdin: *std.Io.Reader,
    stdout: *std.Io.Writer,

    fn notify(context: *anyopaque, event: ai.oauth.Event) anyerror!void {
        const self: *TerminalInteraction = @ptrCast(@alignCast(context));
        switch (event) {
            .auth_url => |auth_url| {
                try self.stdout.print("Open this URL to sign in:\n{s}\n\n{s}\n", .{
                    auth_url.url,
                    auth_url.instructions,
                });
            },
            .device_code => |device| {
                try self.stdout.print(
                    "Open {s} and enter this code:\n{s}\n",
                    .{ device.verification_uri, device.user_code },
                );
            },
        }
        try self.stdout.flush();
    }

    // Context leads because this callback implements the interaction ABI.
    // ziglint-ignore: Z023
    fn prompt(
        context: *anyopaque,
        allocator: std.mem.Allocator, // ziglint-ignore: Z023
        prompt_value: ai.oauth.Prompt,
    ) anyerror![]u8 {
        const self: *TerminalInteraction = @ptrCast(@alignCast(context));
        try self.stdout.writeAll(prompt_value.message);
        try self.stdout.flush();
        const line = (try self.stdin.takeDelimiter('\n')) orelse return error.EndOfStream;
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        return allocator.dupe(u8, trimmed);
    }

    fn interaction(self: *TerminalInteraction) ai.oauth.Interaction {
        const vtable: ai.oauth.Interaction.VTable = .{
            .notify = notify,
            .prompt = prompt,
        };
        return .{ .context = self, .vtable = &vtable };
    }
};

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    paths: *const ZiPaths,
    command: args.AuthCommand,
    stdin: *std.Io.Reader,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    now_ms: u64,
) std.Io.Writer.Error!ExitCode {
    switch (command) {
        .login => |login| {
            var http = ai.transport.HttpTransport.init(allocator);
            var interaction: TerminalInteraction = .{ .stdin = stdin, .stdout = stdout };
            CredentialManager.login(
                allocator,
                io,
                paths,
                http.transport(),
                ModelConfig.builtin,
                .{
                    .provider_id = login.provider_id,
                    .method = switch (login.method) {
                        .browser => .browser,
                        .device_code => .device_code,
                    },
                    .interaction = interaction.interaction(),
                    .now_ms = now_ms,
                },
            ) catch |failure| {
                try stderr.print(
                    "Unable to sign in to {s}: {s}. Check your connection and try again.\n",
                    .{ login.provider_id, @errorName(failure) },
                );
                return .failure;
            };
            try stdout.print("Signed in to {s}.\n", .{login.provider_id});
            return .success;
        },
        .logout => |logout| {
            const removed = CredentialManager.logout(
                allocator,
                io,
                paths,
                logout.provider_id,
            ) catch |failure| {
                try stderr.print(
                    "Unable to sign out of {s}: {s}. Try again.\n",
                    .{ logout.provider_id, @errorName(failure) },
                );
                return .failure;
            };
            if (removed) {
                try stdout.print("Signed out of {s}.\n", .{logout.provider_id});
            } else {
                try stdout.print("No stored credentials for {s}.\n", .{logout.provider_id});
            }
            return .success;
        },
    }
}
