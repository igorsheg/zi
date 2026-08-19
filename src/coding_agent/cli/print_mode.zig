const std = @import("std");
const AgentSession = @import("../AgentSession.zig");

const max_prompt_bytes = 8 * 1024 * 1024;
const max_prompts = 64;

pub const ExitCode = enum(u8) {
    success = 0,
    failure = 1,
};

pub const PrintModeOptions = struct {
    initial_message: ?[]const u8 = null,
    messages: []const []const u8 = &.{},
};

pub fn runPrintMode(
    session: *AgentSession,
    options: PrintModeOptions,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) std.Io.Writer.Error!ExitCode {
    const prompt_count = options.messages.len + @intFromBool(options.initial_message != null);
    if (prompt_count > max_prompts) {
        try stderr.writeAll("Print mode accepts at most 64 prompts.\n");
        return .failure;
    }
    if (options.initial_message) |message| {
        if (!try validatePrompt(message, stderr)) return .failure;
    }
    for (options.messages) |message| {
        if (!try validatePrompt(message, stderr)) return .failure;
    }

    var final_text: ?[]const u8 = null;
    if (options.initial_message) |message| {
        final_text = try prompt(session, message, stderr) orelse return .failure;
    }
    for (options.messages) |message| {
        final_text = try prompt(session, message, stderr) orelse return .failure;
    }
    if (final_text) |text| try stdout.print("{s}\n", .{text});
    return .success;
}

fn validatePrompt(message: []const u8, stderr: *std.Io.Writer) std.Io.Writer.Error!bool {
    if (message.len > max_prompt_bytes) {
        try stderr.writeAll("Prompt exceeds the 8.0MB input limit.\n");
        return false;
    }
    if (!std.unicode.utf8ValidateSlice(message)) {
        try stderr.writeAll("Prompt is not valid UTF-8.\n");
        return false;
    }
    return true;
}

fn prompt(
    session: *AgentSession,
    message: []const u8,
    stderr: *std.Io.Writer,
) std.Io.Writer.Error!?[]const u8 {
    return session.prompt(message) catch |failure| {
        try writeFailure(session, stderr, failure);
        return null;
    };
}

fn writeFailure(
    session: *const AgentSession,
    stderr: *std.Io.Writer,
    failure: AgentSession.RunError,
) std.Io.Writer.Error!void {
    if (session.providerFailure()) |provider_failure| {
        try stderr.print("Request failed: {s} (HTTP {d}: {s})\n", .{
            @errorName(failure),
            provider_failure.status,
            provider_failure.message,
        });
        return;
    }
    try stderr.print("Request failed: {s}\n", .{@errorName(failure)});
}
