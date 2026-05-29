const std = @import("std");
const AgentSession = @import("AgentSession.zig");
const AgentSessionRuntimeHost = @import("AgentSessionRuntimeHost.zig");

pub const Options = struct {
    prompt: []const u8,
};

pub fn run(
    host: *AgentSessionRuntimeHost,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    options: Options,
) !void {
    try host.prompt(options.prompt, &.{});
    try drainEvents(host, stdout, stderr);
}

fn drainEvents(
    host: *AgentSessionRuntimeHost,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    var wrote_text = false;
    while (host.drainPublicEvent()) |event| {
        try drainTextEvent(event, stdout, stderr, &wrote_text);
    }
    if (wrote_text) try stdout.writeByte('\n');
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

test "print mode emits assistant text from injected stream" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    const ai = @import("../ai/root.zig");
    const content = [_]ai.AssistantContent{ai.faux.text("hi")};
    const message = ai.faux.assistantMessage(&content, .{});
    var event_buffer: [8]ai.AssistantMessageEvent = undefined;
    const State = struct {
        events: []ai.AssistantMessageEvent,
        message: ai.AssistantMessage,

        const Self = @This();

        fn stream(context: ?*anyopaque, request: ai.StreamRequest) ai.AssistantMessageEventStream {
            const state: *Self = @ptrCast(@alignCast(context.?));
            var stream_result = ai.AssistantMessageEventStream.init(state.events);
            const sink = stream_result.sink();
            sink.emit(request.io, .{ .start = .{ .partial = state.message } }) catch unreachable;
            sink.endDone(request.io, .stop, state.message) catch unreachable;
            return stream_result;
        }
    };
    var state: State = .{ .events = &event_buffer, .message = message };

    var host = try AgentSessionRuntimeHost.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-27",
        .dir = tmp.dir,
        .stream = .{ .context = &state, .call_fn = State.stream },
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
