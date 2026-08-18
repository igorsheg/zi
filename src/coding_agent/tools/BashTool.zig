const std = @import("std");
const ai_message = @import("../../ai/message.zig");
const ai_model = @import("../../ai/model.zig");
const tool_api = @import("../../agent/Tool.zig");

const BashTool = @This();

const max_arguments_bytes = 128 * 1024;
const max_command_bytes = 64 * 1024;
const max_capture_bytes = 8 * 1024 * 1024;
const max_output_bytes = 50 * 1024;
const max_output_lines = 2000;
const output_overhead_bytes = 512;
const output_overhead_lines = 3;
const invalid_arguments_message = "Bash arguments require one non-empty UTF-8 command without NUL bytes.";
const default_timeout: std.Io.Timeout = .{ .duration = .{
    .raw = .fromMilliseconds(120_000),
    .clock = .awake,
} };

cwd: std.Io.Dir,
timeout: std.Io.Timeout = default_timeout,

pub const definition: ai_message.ToolDefinition = .{
    .name = "bash",
    .description = "Execute one Bash command in the session working directory. " ++
        "Returns bounded stdout followed by stderr and the termination status. Commands time out after 120 seconds.",
    .parameters_json_schema = "{\"type\":\"object\",\"properties\":{" ++
        "\"command\":{\"type\":\"string\",\"description\":\"Bash command to execute\"}}," ++
        "\"required\":[\"command\"],\"additionalProperties\":false}",
};

const Arguments = struct {
    command: []const u8,
};

pub fn asTool(self: *BashTool) tool_api.Tool {
    return tool_api.Tool.from(self, definition);
}

pub fn execute(
    self: *BashTool,
    allocator: std.mem.Allocator,
    io: std.Io,
    run_context: tool_api.Tool.RunContext,
    arguments_json: []const u8,
) tool_api.ToolFatalError!tool_api.ToolExecution {
    try checkCancellation(run_context);
    if (arguments_json.len > max_arguments_bytes) {
        return modelFailure(allocator, "Bash arguments exceed the 128KB input limit.", .{});
    }

    var scratch_arena = std.heap.ArenaAllocator.init(allocator);
    defer scratch_arena.deinit();
    const scratch = scratch_arena.allocator();
    var parsed = std.json.parseFromSlice(Arguments, scratch, arguments_json, .{}) catch |failure| {
        return switch (failure) {
            error.OutOfMemory => error.OutOfMemory,
            else => modelFailure(allocator, invalid_arguments_message, .{}),
        };
    };
    defer parsed.deinit();
    const command = parsed.value.command;
    if (command.len == 0 or command.len > max_command_bytes or
        !std.unicode.utf8ValidateSlice(command) or std.mem.findScalar(u8, command, 0) != null)
    {
        return modelFailure(allocator, invalid_arguments_message, .{});
    }

    const result = std.process.run(scratch, io, .{
        .argv = &.{ "bash", "-c", command },
        .cwd = .{ .dir = self.cwd },
        .stdout_limit = .limited(max_capture_bytes),
        .stderr_limit = .limited(max_capture_bytes),
        .timeout = executionTimeout(io, self.timeout, run_context.deadline),
    }) catch |failure| switch (failure) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Cancelled,
        error.Timeout => return error.TimedOut,
        error.StreamTooLong => return modelFailure(
            allocator,
            "Command output exceeded the 8.0MB per-stream capture limit.",
            .{},
        ),
        else => return modelFailure(allocator, "Cannot execute command: {s}.", .{@errorName(failure)}),
    };

    const status = terminationStatus(scratch, result.term) catch return error.OutOfMemory;
    if (!std.unicode.utf8ValidateSlice(result.stdout) or !std.unicode.utf8ValidateSlice(result.stderr)) {
        return modelFailure(allocator, "Command output is not valid UTF-8.\n\n{s}", .{status});
    }
    var combined: std.ArrayList(u8) = .empty;
    defer combined.deinit(scratch);
    combined.appendSlice(scratch, result.stdout) catch return error.OutOfMemory;
    if (result.stderr.len > 0) {
        if (combined.items.len > 0 and !std.mem.endsWith(u8, combined.items, "\n")) {
            combined.append(scratch, '\n') catch return error.OutOfMemory;
        }
        combined.appendSlice(scratch, "[stderr]\n") catch return error.OutOfMemory;
        combined.appendSlice(scratch, result.stderr) catch return error.OutOfMemory;
    }

    const text = boundedOutput(allocator, combined.items, status) catch return error.OutOfMemory;
    return switch (result.term) {
        .exited => |code| if (code == 0) successExecution(allocator, text) else .{ .failure = text },
        .signal, .stopped, .unknown => .{ .failure = text },
    };
}

fn executionTimeout(
    io: std.Io,
    configured: std.Io.Timeout,
    run_deadline: ?std.Io.Clock.Timestamp,
) std.Io.Timeout {
    const configured_deadline = configured.toDeadline(io);
    const deadline = run_deadline orelse return configured_deadline;
    const configured_remaining = configured_deadline.toDurationFromNow(io) orelse {
        return .{ .deadline = deadline };
    };
    const run_remaining = deadline.durationFromNow(io);
    return if (run_remaining.raw.nanoseconds <= configured_remaining.raw.nanoseconds)
        .{ .deadline = deadline }
    else
        configured_deadline;
}

fn terminationStatus(
    allocator: std.mem.Allocator,
    term: std.process.Child.Term,
) error{OutOfMemory}![]const u8 {
    return switch (term) {
        .exited => |code| std.fmt.allocPrint(allocator, "Command exited with code {d}", .{code}),
        .signal => |signal| std.fmt.allocPrint(
            allocator,
            "Command terminated by signal {d}",
            .{@intFromEnum(signal)},
        ),
        .stopped => |signal| std.fmt.allocPrint(
            allocator,
            "Command stopped by signal {d}",
            .{@intFromEnum(signal)},
        ),
        .unknown => |status| std.fmt.allocPrint(allocator, "Command terminated with status {d}", .{status}),
    } catch return error.OutOfMemory;
}

fn boundedOutput(
    allocator: std.mem.Allocator,
    output: []const u8,
    status: []const u8,
) error{OutOfMemory}![]const u8 {
    const max_body_bytes = max_output_bytes - output_overhead_bytes;
    const max_body_lines = max_output_lines - output_overhead_lines;
    const line_start = tailLineStart(output, max_body_lines);
    const byte_start = if (output.len > max_body_bytes) output.len - max_body_bytes else 0;
    var start = @max(line_start, byte_start);
    while (start < output.len and output[start] & 0xc0 == 0x80) start += 1;
    const truncated = start > 0;
    const body = output[start..];

    var text: std.Io.Writer.Allocating = .init(allocator);
    errdefer text.deinit();
    if (body.len == 0) {
        text.writer.writeAll("(no output)") catch return error.OutOfMemory;
    } else {
        text.writer.writeAll(body) catch return error.OutOfMemory;
    }
    if (body.len > 0 and std.mem.endsWith(u8, body, "\n")) {
        text.writer.writeByte('\n') catch return error.OutOfMemory;
    } else {
        text.writer.writeAll("\n\n") catch return error.OutOfMemory;
    }
    if (truncated) {
        text.writer.print(
            "[Output truncated; showing the last {d} bytes and at most {d} lines.]\n",
            .{ body.len, max_output_lines },
        ) catch return error.OutOfMemory;
    }
    text.writer.writeAll(status) catch return error.OutOfMemory;
    return text.toOwnedSlice() catch return error.OutOfMemory;
}

fn tailLineStart(output: []const u8, max_lines: usize) usize {
    if (output.len == 0) return 0;
    var index = output.len;
    var lines: usize = 1;
    while (index > 0) {
        index -= 1;
        if (output[index] != '\n' or index == output.len - 1) continue;
        lines += 1;
        if (lines > max_lines) return index + 1;
    }
    return 0;
}

fn successExecution(
    allocator: std.mem.Allocator,
    text: []const u8,
) tool_api.ToolFatalError!tool_api.ToolExecution {
    errdefer allocator.free(text);
    const content = try allocator.alloc(ai_message.Content, 1);
    content[0] = .{ .text = text };
    return .{ .success = .{ .content = content } };
}

fn checkCancellation(run_context: tool_api.Tool.RunContext) tool_api.ToolFatalError!void {
    if (run_context.cancellation) |token| if (token.isCancelled()) return error.Cancelled;
}

fn modelFailure(
    allocator: std.mem.Allocator,
    comptime format: []const u8,
    arguments: anytype,
) tool_api.ToolFatalError!tool_api.ToolExecution {
    const text = std.fmt.allocPrint(allocator, format, arguments) catch return error.OutOfMemory;
    return .{ .failure = text };
}

test "bash executes in the borrowed cwd and captures stderr and exit zero" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "marker", .data = "" });
    var implementation: BashTool = .{ .cwd = temporary.dir };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const execution = try implementation.execute(
        arena.allocator(),
        std.testing.io,
        .{},
        "{\"command\":\"test -f marker && printf stdout; printf stderr >&2\"}",
    );
    try std.testing.expectEqualStrings(
        "stdout\n[stderr]\nstderr\n\nCommand exited with code 0",
        execution.success.content[0].text,
    );
}

test "bash returns bounded model failures for non-zero and empty output" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var implementation: BashTool = .{ .cwd = temporary.dir };
    var failure_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer failure_arena.deinit();
    const failure = try implementation.execute(
        failure_arena.allocator(),
        std.testing.io,
        .{},
        "{\"command\":\"printf problem; exit 7\"}",
    );
    try std.testing.expectEqualStrings(
        "problem\n\nCommand exited with code 7",
        failure.failure,
    );

    var success_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer success_arena.deinit();
    const success = try implementation.execute(
        success_arena.allocator(),
        std.testing.io,
        .{},
        "{\"command\":\":\"}",
    );
    try std.testing.expectEqualStrings(
        "(no output)\n\nCommand exited with code 0",
        success.success.content[0].text,
    );

    var signal_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer signal_arena.deinit();
    const signal = try implementation.execute(
        signal_arena.allocator(),
        std.testing.io,
        .{},
        "{\"command\":\"kill -TERM $$\"}",
    );
    try std.testing.expect(std.mem.endsWith(u8, signal.failure, "Command terminated by signal 15"));
}

test "bash retains bounded line and byte tails" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var implementation: BashTool = .{ .cwd = temporary.dir };
    var lines_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer lines_arena.deinit();

    const lines = try implementation.execute(
        lines_arena.allocator(),
        std.testing.io,
        .{},
        "{\"command\":\"i=1; while [ $i -lt 2100 ]; do printf 'line-%04d\\n' $i; i=$((i+1)); done; " ++
            "printf 'line-%04d' $i\"}",
    );
    const line_text = lines.success.content[0].text;
    try std.testing.expect(line_text.len <= max_output_bytes);
    try std.testing.expect(std.mem.find(u8, line_text, "line-0001") == null);
    try std.testing.expect(std.mem.find(u8, line_text, "line-0103") == null);
    try std.testing.expect(std.mem.find(u8, line_text, "line-0104") != null);
    try std.testing.expect(std.mem.find(u8, line_text, "line-2100") != null);
    try std.testing.expect(std.mem.find(u8, line_text, "[Output truncated;") != null);
    try std.testing.expect(std.mem.count(u8, line_text, "\n") + 1 <= max_output_lines);

    var bytes_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer bytes_arena.deinit();
    const bytes = try implementation.execute(
        bytes_arena.allocator(),
        std.testing.io,
        .{},
        "{\"command\":\"printf '%060000d' 0\"}",
    );
    const byte_text = bytes.success.content[0].text;
    try std.testing.expect(byte_text.len <= max_output_bytes);
    try std.testing.expect(std.mem.find(u8, byte_text, "[Output truncated;") != null);
    try std.testing.expect(std.mem.endsWith(u8, byte_text, "Command exited with code 0"));
}

test "bash rejects invalid arguments and invalid UTF-8 output" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var implementation: BashTool = .{ .cwd = temporary.dir };
    const cases = [_][]const u8{
        "{}",
        "{\"command\":\"\"}",
        "{\"command\":1}",
        "{\"command\":\"printf ok\",\"extra\":true}",
        "{\"command\":\"\\uD800\"}",
        "{\"command\":\"printf \\u0000\"}",
    };
    for (cases) |arguments| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const execution = try implementation.execute(arena.allocator(), std.testing.io, .{}, arguments);
        try std.testing.expectEqualStrings(invalid_arguments_message, execution.failure);
    }

    var output_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer output_arena.deinit();
    const invalid_output = try implementation.execute(
        output_arena.allocator(),
        std.testing.io,
        .{},
        "{\"command\":\"printf '\\\\377'\"}",
    );
    try std.testing.expectEqualStrings(
        "Command output is not valid UTF-8.\n\nCommand exited with code 0",
        invalid_output.failure,
    );
}

test "bash enforces command bounds and settles timeout" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var implementation: BashTool = .{ .cwd = temporary.dir };
    const exact_command = try std.testing.allocator.alloc(u8, max_command_bytes);
    defer std.testing.allocator.free(exact_command);
    @memset(exact_command, ' ');
    exact_command[0] = ':';
    const exact_arguments = try std.json.Stringify.valueAlloc(
        std.testing.allocator,
        .{ .command = exact_command },
        .{},
    );
    defer std.testing.allocator.free(exact_arguments);
    var exact_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer exact_arena.deinit();
    const exact = try implementation.execute(exact_arena.allocator(), std.testing.io, .{}, exact_arguments);
    try std.testing.expectEqualStrings(
        "(no output)\n\nCommand exited with code 0",
        exact.success.content[0].text,
    );

    const command = try std.testing.allocator.alloc(u8, max_command_bytes + 1);
    defer std.testing.allocator.free(command);
    @memset(command, 'x');
    const arguments = try std.json.Stringify.valueAlloc(std.testing.allocator, .{ .command = command }, .{});
    defer std.testing.allocator.free(arguments);
    var command_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer command_arena.deinit();
    const command_failure = try implementation.execute(command_arena.allocator(), std.testing.io, .{}, arguments);
    try std.testing.expectEqualStrings(invalid_arguments_message, command_failure.failure);

    const oversized_arguments = try std.testing.allocator.alloc(u8, max_arguments_bytes + 1);
    defer std.testing.allocator.free(oversized_arguments);
    @memset(oversized_arguments, 'x');
    var arguments_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arguments_arena.deinit();
    const arguments_failure = try implementation.execute(
        arguments_arena.allocator(),
        std.testing.io,
        .{},
        oversized_arguments,
    );
    try std.testing.expectEqualStrings("Bash arguments exceed the 128KB input limit.", arguments_failure.failure);

    var timeout_implementation: BashTool = .{
        .cwd = temporary.dir,
        .timeout = .{ .duration = .{ .raw = .fromMilliseconds(10), .clock = .awake } },
    };
    var timeout_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer timeout_arena.deinit();
    try std.testing.expectError(error.TimedOut, timeout_implementation.execute(
        timeout_arena.allocator(),
        std.testing.io,
        .{},
        "{\"command\":\"while :; do :; done\"}",
    ));

    const deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
        .raw = .fromMilliseconds(10),
        .clock = .awake,
    });
    var deadline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer deadline_arena.deinit();
    try std.testing.expectError(error.TimedOut, implementation.execute(
        deadline_arena.allocator(),
        std.testing.io,
        .{ .deadline = deadline },
        "{\"command\":\"while :; do :; done\"}",
    ));
}

test "bash honors pre-cancellation without spawning" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var implementation: BashTool = .{ .cwd = temporary.dir };
    var cancellation: ai_model.CancellationToken = .{};
    cancellation.cancel();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.Cancelled, implementation.execute(
        arena.allocator(),
        std.testing.io,
        .{ .cancellation = &cancellation },
        "{\"command\":\"touch spawned\"}",
    ));
    try std.testing.expectError(error.FileNotFound, temporary.dir.access(std.testing.io, "spawned", .{}));
}
