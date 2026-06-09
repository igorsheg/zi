const std = @import("std");

const client_protocol = @import("../../coding_agent/client_protocol.zig");
const session_runtime = @import("../../coding_agent/session_runtime.zig");
const wire_protocol = @import("../../coding_agent/wire_protocol.zig");
const runtime = @import("../../runtime/root.zig");

pub const Error = anyerror;

pub fn run(
    app: *session_runtime.SessionRuntime,
    stdin: *std.Io.Reader,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) Error!void {
    var malformed_lines: usize = 0;
    while (true) {
        const raw_line = stdin.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                try writeRejected(app.allocator, stdout, null, .invalid_command, "input line too large");
                stderr.writeAll("rpc input line too large\n") catch return error.OutputClosed;
                return error.InputLineTooLarge;
            },
            error.ReadFailed => return error.OutputClosed,
        } orelse return;

        const result = try handleLine(app, stdout, stderr, raw_line, &malformed_lines, true);
        if (result == .shutdown) return;
    }
}

pub fn runPrompt(
    app: *session_runtime.SessionRuntime,
    stdout: *std.Io.Writer,
    prompt: []const u8,
) Error!void {
    var envelope = try client_protocol.CommandEnvelope.initSubmitPrompt(app.allocator, 1, prompt);
    var envelope_owned = true;
    defer if (envelope_owned) envelope.deinit(app.allocator);
    try app.submit(envelope);
    envelope_owned = false;
    _ = try drive(app, stdout, 1);
}

pub fn runFd(
    app: *session_runtime.SessionRuntime,
    input_fd: std.posix.fd_t,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) Error!void {
    var state: InputState = .{};
    while (true) {
        const wake = try app.waitForWake(input_fd, rpc_idle_tick_ms);
        if (wake == .input) {
            const input_result = try state.readAvailable(input_fd, app, stdout, stderr);
            if (input_result == .shutdown) return;
            if (input_result == .eof) {
                _ = try drive(app, stdout, null);
                return;
            }
        }
        const result = try drive(app, stdout, null);
        if (result == .shutdown) return;
    }
}

const rpc_idle_tick_ms: u64 = 16;
const read_chunk_bytes = 4096;

const DriveResult = enum { idle, terminal, shutdown };
const InputResult = enum { active, eof, shutdown };

fn handleLine(
    app: *session_runtime.SessionRuntime,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    raw_line: []const u8,
    malformed_lines: *usize,
    wait_for_terminal: bool,
) Error!DriveResult {
    var envelope = wire_protocol.decodeCommandLine(app.allocator, raw_line) catch |err| {
        malformed_lines.* += 1;
        try writeRejected(app.allocator, stdout, null, .invalid_command, @errorName(err));
        if (malformed_lines.* >= wire_protocol.max_malformed_lines) {
            stderr.writeAll("too many malformed rpc lines\n") catch return error.OutputClosed;
            return .shutdown;
        }
        return .idle;
    } orelse return .idle;
    malformed_lines.* = 0;

    const request_id = envelope.id;
    const terminal_request_id = if (wait_for_terminal and request_id != null) request_id else null;
    const command = envelope.command;
    var envelope_owned = true;
    defer if (envelope_owned) envelope.deinit(app.allocator);
    app.submit(envelope) catch |err| switch (err) {
        error.Full => {
            try writeRejected(app.allocator, stdout, request_id, .queue_full, "command queue full");
            return .idle;
        },
    };
    envelope_owned = false;

    if (wait_for_terminal) {
        const result = try drive(app, stdout, terminal_request_id);
        if (command == .shutdown) return .shutdown;
        return result;
    }
    return if (command == .shutdown) .shutdown else .idle;
}

const InputState = struct {
    line: [wire_protocol.max_input_line_bytes]u8 = undefined,
    line_len: usize = 0,
    dropping_oversized: bool = false,
    malformed_lines: usize = 0,

    fn readAvailable(
        self: *InputState,
        input_fd: std.posix.fd_t,
        app: *session_runtime.SessionRuntime,
        stdout: *std.Io.Writer,
        stderr: *std.Io.Writer,
    ) Error!InputResult {
        var chunk: [read_chunk_bytes]u8 = undefined;
        const read_len = std.posix.read(input_fd, &chunk) catch |err| switch (err) {
            error.WouldBlock => return .active,
            else => return error.InputReadFailed,
        };
        if (read_len == 0) return .eof;
        return self.feed(chunk[0..read_len], app, stdout, stderr);
    }

    fn feed(
        self: *InputState,
        bytes: []const u8,
        app: *session_runtime.SessionRuntime,
        stdout: *std.Io.Writer,
        stderr: *std.Io.Writer,
    ) Error!InputResult {
        for (bytes) |byte| {
            if (self.dropping_oversized) {
                if (byte == '\n') self.dropping_oversized = false;
                continue;
            }
            if (byte == '\n') {
                const result = try handleLine(app, stdout, stderr, self.line[0..self.line_len], &self.malformed_lines, false);
                self.line_len = 0;
                if (result == .shutdown) return .shutdown;
                continue;
            }
            if (self.line_len == self.line.len) {
                try writeRejected(app.allocator, stdout, null, .invalid_command, "input line too large");
                stderr.writeAll("rpc input line too large\n") catch return error.OutputClosed;
                self.line_len = 0;
                self.dropping_oversized = true;
                continue;
            }
            self.line[self.line_len] = byte;
            self.line_len += 1;
        }
        return .active;
    }
};

fn drive(
    app: *session_runtime.SessionRuntime,
    stdout: *std.Io.Writer,
    terminal_request_id: ?client_protocol.RequestId,
) Error!DriveResult {
    var idle_ticks: usize = 0;
    while (true) {
        try app.step();
        const result = try drainEvents(app, stdout, terminal_request_id);
        switch (result) {
            .terminal, .shutdown => return result,
            .idle => {},
        }
        if (terminal_request_id == null) return .idle;
        idle_ticks += 1;
        if (idle_ticks > 0) try runtime.sleep(.fromMilliseconds(10));
    }
}

fn drainEvents(
    app: *session_runtime.SessionRuntime,
    stdout: *std.Io.Writer,
    terminal_request_id: ?client_protocol.RequestId,
) Error!DriveResult {
    var saw_terminal = false;
    var saw_shutdown = false;
    while (app.drainEvent()) |event| {
        var owned_event = event;
        defer owned_event.deinit(app.allocator);
        const event_request_id = owned_event.request_id;
        if (isShutdownEvent(owned_event.event)) saw_shutdown = true;
        if (terminal_request_id != null and event_request_id == terminal_request_id and isTerminalEvent(owned_event.event)) {
            saw_terminal = true;
        }
        try writeEvent(app.allocator, stdout, owned_event);
    }
    if (saw_shutdown) return .shutdown;
    if (saw_terminal) return .terminal;
    return .idle;
}

fn isTerminalEvent(event: client_protocol.ClientEvent) bool {
    return switch (event) {
        .rejected, .operation_finished, .snapshot, .shutdown_started => true,
        else => false,
    };
}

fn isShutdownEvent(event: client_protocol.ClientEvent) bool {
    return event == .shutdown_started;
}

fn writeEvent(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    event: client_protocol.EventEnvelope,
) Error!void {
    const encoded = wire_protocol.encodeEventEnvelope(allocator, event) catch |err| switch (err) {
        error.OutputEventTooLarge => return writeRejected(allocator, stdout, event.request_id, .overflow, "output event too large"),
        error.EventJsonNotObject => return writeRejected(allocator, stdout, event.request_id, .invalid_command, "event json invalid"),
        error.WriteFailed => return error.OutputClosed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer allocator.free(encoded);
    stdout.writeAll(encoded) catch return error.OutputClosed;
    stdout.flush() catch return error.OutputClosed;
}

fn writeRejected(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    request_id: ?client_protocol.RequestId,
    code: client_protocol.Rejection.Code,
    message: []const u8,
) Error!void {
    var owned_message = try client_protocol.EventText.init(allocator, message);
    defer owned_message.deinit();
    const envelope: client_protocol.EventEnvelope = .{
        .request_id = request_id,
        .event = .{ .rejected = .{ .code = code, .message = owned_message } },
    };
    try writeEvent(allocator, stdout, envelope);
}

test "rpc stdio decodes commands and emits snapshot and shutdown" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var app = try session_runtime.createSessionRuntime(std.testing.allocator, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .current_date = "2026-06-09",
        .session_id = "rpc-session",
        .timestamp = "2026-06-09T00:00:00Z",
        .dir = tmp.dir,
        .task_runtime = task_runtime,
    });
    defer app.deinit();

    var input = std.Io.Reader.fixed(
        \\{"id":1,"type":"snapshot"}
        \\{"id":2,"type":"shutdown"}
        \\
    );
    var stdout_buffer: [8192]u8 = undefined;
    var stdout = std.Io.Writer.fixed(&stdout_buffer);
    var stderr_buffer: [256]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);

    try run(&app, &input, &stdout, &stderr);

    const output = stdout.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"id\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"type\":\"snapshot\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"id\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"shutdown_started\"") != null);
    try std.testing.expectEqualStrings("", stderr.buffered());
}

test "rpc input accepts targeted cancel while prompt is active" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var app = try session_runtime.createSessionRuntime(std.testing.allocator, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .current_date = "2026-06-09",
        .session_id = "rpc-session",
        .timestamp = "2026-06-09T00:00:00Z",
        .dir = tmp.dir,
        .task_runtime = task_runtime,
    });
    defer app.deinit();

    var prompt = try client_protocol.CommandEnvelope.initSubmitPrompt(std.testing.allocator, 1, "first");
    var prompt_owned = true;
    defer if (prompt_owned) prompt.deinit(std.testing.allocator);
    try app.submit(prompt);
    prompt_owned = false;
    try app.step();

    var started = app.drainEvent().?;
    defer started.deinit(std.testing.allocator);
    try std.testing.expect(started.event == .operation_started);
    const operation_id = started.operation_id.?;

    var stdout_buffer: [8192]u8 = undefined;
    var stdout = std.Io.Writer.fixed(&stdout_buffer);
    var stderr_buffer: [256]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    var state: InputState = .{};
    const line = try std.fmt.allocPrint(std.testing.allocator, "{{\"id\":2,\"type\":\"cancel\",\"target\":{{\"operationId\":{}}}}}\n", .{operation_id});
    defer std.testing.allocator.free(line);

    try std.testing.expectEqual(InputResult.active, try state.feed(line, &app, &stdout, &stderr));
    try app.step();

    var found_canceled = false;
    while (app.drainEvent()) |event| {
        var owned = event;
        defer owned.deinit(std.testing.allocator);
        if (owned.event == .operation_finished and owned.event.operation_finished.reason == .canceled) {
            found_canceled = true;
        }
    }
    try std.testing.expect(found_canceled);
}

test "rpc stdio reports malformed json and continues" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var app = try session_runtime.createSessionRuntime(std.testing.allocator, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .current_date = "2026-06-09",
        .session_id = "rpc-session",
        .timestamp = "2026-06-09T00:00:00Z",
        .dir = tmp.dir,
        .task_runtime = task_runtime,
    });
    defer app.deinit();

    var input = std.Io.Reader.fixed(
        \\{
        \\{"id":2,"type":"shutdown"}
        \\
    );
    var stdout_buffer: [8192]u8 = undefined;
    var stdout = std.Io.Writer.fixed(&stdout_buffer);
    var stderr_buffer: [256]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);

    try run(&app, &input, &stdout, &stderr);

    const output = stdout.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "InvalidJson") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"id\":2") != null);
}
