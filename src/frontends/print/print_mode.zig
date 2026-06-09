const std = @import("std");
const ai = @import("../../ai/root.zig");
const runtime = @import("../../runtime/root.zig");
const client_protocol = @import("../../coding_agent/client_protocol.zig");
const session_manager = @import("../../coding_agent/session_manager.zig");
const session_runtime = @import("../../coding_agent/session_runtime.zig");

const OutputMode = enum {
    text,
    json,
};

const Error = error{
    OutputClosed,
};

const Options = struct {
    prompt: []const u8,
    output: OutputMode = .text,
};

pub fn run(
    app: *session_runtime.SessionRuntime,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    options: Options,
) !void {
    return runInner(app, stdout, stderr, options) catch |err| switch (err) {
        error.WriteFailed => error.OutputClosed,
        else => |unexpected| return unexpected,
    };
}

fn runInner(
    app: *session_runtime.SessionRuntime,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    options: Options,
) !void {
    const json_output = options.output == .json;
    if (json_output) try writeSessionHeader(app, stdout);

    var envelope = try client_protocol.CommandEnvelope.initSubmitPrompt(app.allocator, 1, options.prompt);
    var envelope_owned = true;
    defer if (envelope_owned) envelope.deinit(app.allocator);
    try app.submit(envelope);
    envelope_owned = false;

    var done = false;
    while (!done) {
        try app.step();
        done = try drainEvents(app, stdout, stderr, options.output);
    }
}

fn drainEvents(
    app: *session_runtime.SessionRuntime,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    output: OutputMode,
) !bool {
    var drain: PrintDrain = .{
        .stdout = stdout,
        .stderr = stderr,
        .output = output,
    };
    var done = false;
    while (app.drainEvent()) |event| {
        var owned_event = event;
        defer owned_event.deinit(app.allocator);
        switch (owned_event.event) {
            .agent_event,
            .queue_update,
            .prompt_command,
            .snapshot,
            .compaction_start,
            .session_info_changed,
            .compaction_end,
            .auto_retry_start,
            .auto_retry_end,
            .event_overflow,
            => try drain.onEvent(owned_event.event),
            .response => |response| switch (response) {
                .prompt_finished => done = true,
                else => {},
            },
            .rejected => |rejection| {
                try printAssistantError(stderr, rejection.message.text);
                done = true;
            },
        }
    }
    if (output == .text and drain.wrote_text) try stdout.writeByte('\n');
    return done;
}

const PrintDrain = struct {
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    output: OutputMode,
    wrote_text: bool = false,

    fn onEvent(self: *PrintDrain, event: client_protocol.ClientEvent) !void {
        switch (self.output) {
            .text => try self.onTextEvent(event),
            .json => try drainJsonEvent(event, self.stdout),
        }
    }

    fn onTextEvent(
        self: *PrintDrain,
        event: client_protocol.ClientEvent,
    ) !void {
        switch (event) {
            .agent_event => |agent_event| switch (agent_event.event) {
                .message_end => |payload| switch (payload.message) {
                    .assistant => |assistant| {
                        if (assistant.error_message) |message| return printAssistantError(self.stderr, message);
                        if (assistant.stop_reason == .error_) {
                            return printAssistantError(self.stderr, "assistant request failed");
                        }
                        for (assistant.content) |content| {
                            if (content != .text) continue;
                            try self.stdout.writeAll(content.text.text);
                            self.wrote_text = true;
                        }
                    },
                    else => {},
                },
                else => {},
            },
            else => {},
        }
    }
};

fn printAssistantError(stderr: *std.Io.Writer, message: []const u8) !void {
    try stderr.writeAll(message);
    try stderr.writeByte('\n');
}

fn drainJsonEvent(
    event: client_protocol.ClientEvent,
    stdout: *std.Io.Writer,
) !void {
    try std.json.Stringify.value(event, .{}, stdout);
    try stdout.writeByte('\n');
    try stdout.flush();
}

fn writeSessionHeader(
    app: *const session_runtime.SessionRuntime,
    stdout: *std.Io.Writer,
) !void {
    try writeJsonSessionHeader(app.sessionHeader(), stdout);
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
        try stdout.writeAll(",\"parentSession\":");
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
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();

    var app = try session_runtime.createSessionRuntime(std.testing.allocator, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .current_date = "2026-05-27",
        .session_id = "session",
        .timestamp = "2026-05-27T00:00:00Z",
        .dir = tmp.dir,
        .stream = provider.apiProvider().stream,
    });
    defer app.deinit();

    var stdout_buffer: [64]u8 = undefined;
    var stdout = std.Io.Writer.fixed(&stdout_buffer);
    var stderr_buffer: [64]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);

    try run(&app, &stdout, &stderr, .{ .prompt = "hello" });
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
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();

    var app = try session_runtime.createSessionRuntime(std.testing.allocator, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .current_date = "2026-05-27",
        .session_id = "session",
        .timestamp = "2026-05-27T00:00:00Z",
        .dir = tmp.dir,
        .stream = provider.apiProvider().stream,
    });
    defer app.deinit();

    var stdout_buffer: [8192]u8 = undefined;
    var stdout = std.Io.Writer.fixed(&stdout_buffer);
    var stderr_buffer: [64]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);

    try run(&app, &stdout, &stderr, .{ .prompt = "hello", .output = .json });
    const output = stdout.buffered();
    try std.testing.expect(std.mem.startsWith(u8, output, "{\"type\":\"session\",\"version\":3"));
    try std.testing.expect(std.mem.indexOf(u8, output, "{\"type\":\"message_start\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "{\"type\":\"message_update\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"assistantMessageEvent\":{\"type\":\"text_delta\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"role\":\"assistant\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"stopReason\":\"stop\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"totalTokens\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "{\"type\":\"message_end\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "{\"type\":\"agent_end\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"agent_event\"") == null);
    try std.testing.expectEqualStrings("", stderr.buffered());
}
