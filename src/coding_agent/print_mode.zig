const std = @import("std");
const ai = @import("../ai/root.zig");
const AgentSession = @import("AgentSession.zig");
const AgentSessionRuntimeHost = @import("AgentSessionRuntimeHost.zig");
const session_manager = @import("session_manager.zig");

pub const OutputMode = enum {
    text,
    json,
};

pub const Options = struct {
    prompt: []const u8,
    output: OutputMode = .text,
};

pub fn run(
    host: *AgentSessionRuntimeHost,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    options: Options,
) !void {
    const json_output = options.output == .json;
    if (json_output) try writeSessionHeader(host, stdout);
    const prompt_run = try host.startPromptRun(options.prompt, &.{}, .{});
    defer host.destroyPromptRun(prompt_run);
    while (try host.stepPromptRun(prompt_run)) {
        try drainEvents(host, stdout, stderr, options.output);
    }
    try drainEvents(host, stdout, stderr, options.output);
}

fn drainEvents(
    host: *AgentSessionRuntimeHost,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    output: OutputMode,
) !void {
    var wrote_text = false;
    while (host.drainPublicEvent()) |event| {
        switch (output) {
            .text => try drainTextEvent(event, stdout, stderr, &wrote_text),
            .json => try drainJsonEvent(event, stdout),
        }
    }
    if (output == .text and wrote_text) try stdout.writeByte('\n');
}

fn drainTextEvent(
    event: AgentSession.AgentSessionEvent,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    wrote_text: *bool,
) !void {
    switch (event) {
        .agent_event => |agent_event| switch (agent_event) {
            .message_end => |payload| switch (payload.message) {
                .assistant => |assistant| {
                    if (assistant.error_message) |message| return printAssistantError(stderr, message);
                    if (assistant.stop_reason == .error_) {
                        return printAssistantError(stderr, "assistant request failed");
                    }
                    for (assistant.content) |content| {
                        if (content != .text) continue;
                        try stdout.writeAll(content.text.text);
                        wrote_text.* = true;
                    }
                },
                else => {},
            },
            else => {},
        },
        else => {},
    }
}

fn printAssistantError(stderr: *std.Io.Writer, message: []const u8) !void {
    try stderr.writeAll(message);
    try stderr.writeByte('\n');
}

fn drainJsonEvent(
    event: AgentSession.AgentSessionEvent,
    stdout: *std.Io.Writer,
) !void {
    try std.json.Stringify.value(event, .{}, stdout);
    try stdout.writeByte('\n');
    try stdout.flush();
}

fn writeSessionHeader(
    host: *AgentSessionRuntimeHost,
    stdout: *std.Io.Writer,
) !void {
    try writeJsonSessionHeader(host.currentSession().manager.header, stdout);
}

fn writeJsonSessionHeader(
    header: session_manager.SessionHeader,
    stdout: *std.Io.Writer,
) !void {
    try stdout.writeAll("{\"type\":\"session\",\"version\":");
    try stdout.print("{}", .{header.version});
    try stdout.writeAll(",\"id\":");
    try std.json.Stringify.value(header.id, .{}, stdout);
    try stdout.writeAll(",\"timestamp\":");
    try std.json.Stringify.value(header.timestamp, .{}, stdout);
    try stdout.writeAll(",\"cwd\":");
    try std.json.Stringify.value(header.cwd, .{}, stdout);
    if (header.parent_session) |parent_session| {
        try stdout.writeAll(",\"parent_session\":");
        try std.json.Stringify.value(parent_session, .{}, stdout);
    }
    try stdout.writeAll("}\n");
    try stdout.flush();
}

test "print mode emits assistant text from injected stream" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var provider = try ai.FauxProvider.init(std.testing.allocator, .{ .min_token_size = 1, .max_token_size = 1 });
    defer provider.deinit();
    const content = [_]ai.AssistantContent{ai.faux.text("hi")};
    const message = ai.faux.assistantMessage(&content, .{});
    try provider.setResponses(&.{message});

    var host = try AgentSessionRuntimeHost.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-27",
        .dir = tmp.dir,
        .stream = provider.apiProvider().stream,
    }, .{
        .session_id = "session",
        .timestamp = "2026-05-27T00:00:00Z",
    });
    defer {
        host.requestShutdown();
        while (host.drainPublicEvent() != null) {}
        host.deinit();
    }

    var stdout_buffer: [64]u8 = undefined;
    var stdout = std.Io.Writer.fixed(&stdout_buffer);
    var stderr_buffer: [64]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);

    try run(&host, &stdout, &stderr, .{ .prompt = "hello" });
    try std.testing.expectEqualStrings("hi\n", stdout.buffered());
    try std.testing.expectEqualStrings("", stderr.buffered());
}

test "json print mode streams session header and public events" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var provider = try ai.FauxProvider.init(std.testing.allocator, .{ .min_token_size = 1, .max_token_size = 1 });
    defer provider.deinit();
    const content = [_]ai.AssistantContent{ai.faux.text("hi")};
    const message = ai.faux.assistantMessage(&content, .{});
    try provider.setResponses(&.{message});

    var host = try AgentSessionRuntimeHost.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-27",
        .dir = tmp.dir,
        .stream = provider.apiProvider().stream,
    }, .{
        .session_id = "session",
        .timestamp = "2026-05-27T00:00:00Z",
    });
    defer {
        host.requestShutdown();
        while (host.drainPublicEvent() != null) {}
        host.deinit();
    }

    var stdout_buffer: [8192]u8 = undefined;
    var stdout = std.Io.Writer.fixed(&stdout_buffer);
    var stderr_buffer: [64]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);

    try run(&host, &stdout, &stderr, .{ .prompt = "hello", .output = .json });
    const output = stdout.buffered();
    try std.testing.expect(std.mem.startsWith(u8, output, "{\"type\":\"session\",\"version\":3"));
    try std.testing.expect(std.mem.indexOf(u8, output, "{\"agent_event\":{\"message_start\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "{\"agent_event\":{\"message_update\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"assistant_message_event\":{\"text_delta\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "{\"agent_event\":{\"message_end\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "{\"agent_event\":{\"agent_end\"") != null);
    try std.testing.expectEqualStrings("", stderr.buffered());
}
