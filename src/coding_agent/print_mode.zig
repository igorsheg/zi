const std = @import("std");
const ai = @import("../ai/root.zig");
const runtime = @import("../runtime/root.zig");
const AgentSessionRuntimeHost = @import("AgentSessionRuntimeHost.zig");
const session_events = @import("session_events.zig");
const session_manager = @import("session_manager.zig");

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
    host: *AgentSessionRuntimeHost,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    options: Options,
) !void {
    return runInner(host, stdout, stderr, options) catch |err| switch (err) {
        error.WriteFailed => error.OutputClosed,
        else => |unexpected| return unexpected,
    };
}

fn runInner(
    host: *AgentSessionRuntimeHost,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    options: Options,
) !void {
    const json_output = options.output == .json;
    if (json_output) try writeSessionHeader(host, stdout);
    const prompt_run = try host.session.startPromptRun(options.prompt, &.{}, .{});
    defer host.session.destroyPromptRun(prompt_run);
    while (try host.session.stepPromptRun(prompt_run)) {
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
    var drain: PrintDrain = .{
        .stdout = stdout,
        .stderr = stderr,
        .output = output,
    };
    while (host.session.drainPublicEvent()) |event| {
        var owned_event = event;
        errdefer owned_event.deinit();
        try PrintDrain.onEvent(&drain, owned_event);
        owned_event.deinit();
    }
    if (output == .text and drain.wrote_text) try stdout.writeByte('\n');
}

const PrintDrain = struct {
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    output: OutputMode,
    wrote_text: bool = false,

    fn onEvent(context: ?*anyopaque, event: session_events.AgentSessionEvent) !void {
        const self: *PrintDrain = @ptrCast(@alignCast(context.?));
        switch (self.output) {
            .text => try self.onTextEvent(event),
            .json => try drainJsonEvent(event, self.stdout),
        }
    }

    fn onTextEvent(
        self: *PrintDrain,
        event: session_events.AgentSessionEvent,
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
    event: session_events.AgentSessionEvent,
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
    try writeJsonSessionHeader(host.session.manager.header, stdout);
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
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var host = try AgentSessionRuntimeHost.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-27",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
        .stream = provider.apiProvider().stream,
    }, .{ .create = .{
        .session_id = "session",
        .timestamp = "2026-05-27T00:00:00Z",
    } });
    defer {
        host.session.requestShutdown();
        drainAllPublicEvents(&host);
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
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var host = try AgentSessionRuntimeHost.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .current_date = "2026-05-27",
        .zio_runtime = zio_runtime,
        .dir = tmp.dir,
        .stream = provider.apiProvider().stream,
    }, .{ .create = .{
        .session_id = "session",
        .timestamp = "2026-05-27T00:00:00Z",
    } });
    defer {
        host.session.requestShutdown();
        drainAllPublicEvents(&host);
        host.deinit();
    }

    var stdout_buffer: [8192]u8 = undefined;
    var stdout = std.Io.Writer.fixed(&stdout_buffer);
    var stderr_buffer: [64]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);

    try run(&host, &stdout, &stderr, .{ .prompt = "hello", .output = .json });
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

fn drainAllPublicEvents(host: *AgentSessionRuntimeHost) void {
    while (host.session.drainPublicEvent()) |event| {
        var owned_event = event;
        owned_event.deinit();
    }
}
