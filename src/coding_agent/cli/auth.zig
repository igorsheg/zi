const std = @import("std");
const ai = @import("../../ai/root.zig");
const CredentialManager = @import("../CredentialManager.zig");
const ModelConfigSnapshot = @import("../ModelConfigSnapshot.zig");
const ZiPaths = @import("../ZiPaths.zig");
const surface = @import("surface.zig");

const max_prompt_bytes = 16 * 1024;

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    home: []const u8,
    input: *std.Io.Reader,
    output: *std.Io.Writer,
    error_output: *std.Io.Writer,
};

pub fn run(request: surface.AuthRequest, context: Context) !u8 {
    var paths = try ZiPaths.init(context.allocator, context.cwd, context.home);
    defer paths.deinit();
    var snapshot = ModelConfigSnapshot.load(context.allocator, context.io, &paths) catch |failure| {
        try context.error_output.print("Unable to load model configuration: {s}.\n", .{@errorName(failure)});
        return 1;
    };
    defer snapshot.deinit();

    var interaction_context: InteractionContext = .{
        .allocator = context.allocator,
        .input = context.input,
        .output = context.output,
    };
    var transport = ai.transport.HttpTransport.init(context.allocator);
    CredentialManager.login(
        context.allocator,
        context.io,
        &paths,
        transport.transport(),
        snapshot.view(),
        .{
            .provider_id = request.provider,
            .method = request.method,
            .interaction = .{
                .context = &interaction_context,
                .vtable = &.{ .notify = notify, .prompt = prompt },
            },
            .now_ms = nowMs(context.io),
        },
    ) catch |failure| {
        try context.error_output.print("Unable to log in: {s}.\n", .{@errorName(failure)});
        return 1;
    };
    try context.output.print("Logged in to {s}.\n", .{request.provider});
    return 0;
}

const InteractionContext = struct {
    allocator: std.mem.Allocator,
    input: *std.Io.Reader,
    output: *std.Io.Writer,
};

fn notify(context: *anyopaque, event: ai.oauth.Event) anyerror!void {
    const self: *InteractionContext = @ptrCast(@alignCast(context));
    switch (event) {
        .auth_url => |value| try self.output.print("{s}\n{s}\n", .{ value.instructions, value.url }),
        .device_code => |value| try self.output.print(
            "Open {s}\nEnter code: {s}\n",
            .{ value.verification_uri, value.user_code },
        ),
    }
}

// Context leads because this callback implements the erased OAuth interaction ABI.
// ziglint-ignore: Z023
fn prompt(context: *anyopaque, allocator: std.mem.Allocator, request: ai.oauth.Prompt) anyerror![]u8 {
    const self: *InteractionContext = @ptrCast(@alignCast(context));
    try self.output.writeAll(request.message);
    if (request.placeholder) |placeholder| try self.output.print(" ({s})", .{placeholder});
    try self.output.writeAll(": ");
    const line = (try self.input.takeDelimiter('\n')) orelse return error.ConsumerStopped;
    if (line.len > max_prompt_bytes) return error.ConsumerStopped;
    const value = std.mem.trim(u8, line, " \t\r\n");
    if (value.len == 0) return error.ConsumerStopped;
    return allocator.dupe(u8, value);
}

fn nowMs(io: std.Io) u64 {
    const value = std.Io.Timestamp.now(io, .real).toMilliseconds();
    return if (value > 0) @intCast(value) else 0;
}

test "auth parser inputs retain provider and login method" {
    const request: surface.AuthRequest = .{ .provider = "openai-codex", .method = .device_code };
    try std.testing.expectEqualStrings("openai-codex", request.provider);
    try std.testing.expectEqual(ai.oauth.LoginMethod.device_code, request.method);
}
