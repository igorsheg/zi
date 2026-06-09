const std = @import("std");
const builtin = @import("builtin");
const agent = @import("../../agent/root.zig");
const ai = @import("../../ai/root.zig");
const runtime = @import("../../runtime/root.zig");
const path_utils = @import("path_utils.zig");
const output_accumulator = @import("output_accumulator.zig");
const output_tail = @import("output_tail.zig");

pub const default_timeout_ms = 30_000;
pub const max_timeout_ms = 120_000;
pub const max_command_bytes = 16 * 1024;
pub const max_output_preview_bytes = 50 * 1024;
pub const max_output_preview_lines = 2000;
pub const max_stdout_bytes = max_output_preview_bytes * 2;
pub const max_stderr_bytes = max_output_preview_bytes * 2;

const parameters_schema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "command": {
    \\      "type": "string",
    \\      "description": "Shell command to run in the session cwd",
    \\      "maxLength": 16384
    \\    },
    \\    "timeout": { "type": "integer", "description": "Optional timeout in seconds, max 120" }
    \\  },
    \\  "required": ["command"]
    \\}
;

pub const BashTool = struct {
    allocator: std.mem.Allocator,
    config: Config,
    parsed_parameters: runtime.JsonOwned(std.json.Value),

    pub const Config = struct {
        cwd: []const u8,
        environ: ?*const std.process.Environ.Map = null,
        shell_path: ?[]const u8 = null,
        command_prefix: ?[]const u8 = null,
        timeout_ms: u64 = default_timeout_ms,
        max_timeout_ms: u64 = max_timeout_ms,
        max_stdout_bytes: usize = max_stdout_bytes,
        max_stderr_bytes: usize = max_stderr_bytes,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !BashTool {
        try validateConfig(config);
        const cwd = try allocator.dupe(u8, config.cwd);
        errdefer allocator.free(cwd);
        const shell_path = if (config.shell_path) |path| try allocator.dupe(u8, path) else null;
        errdefer if (shell_path) |path| allocator.free(path);
        const command_prefix = if (config.command_prefix) |prefix| try allocator.dupe(u8, prefix) else null;
        errdefer if (command_prefix) |prefix| allocator.free(prefix);
        const parsed_parameters = try runtime.JsonOwned(std.json.Value).parseJson(allocator, parameters_schema, .{});
        return .{
            .allocator = allocator,
            .config = .{
                .cwd = cwd,
                .environ = config.environ,
                .shell_path = shell_path,
                .command_prefix = command_prefix,
                .timeout_ms = config.timeout_ms,
                .max_timeout_ms = config.max_timeout_ms,
                .max_stdout_bytes = config.max_stdout_bytes,
                .max_stderr_bytes = config.max_stderr_bytes,
            },
            .parsed_parameters = parsed_parameters,
        };
    }

    pub fn deinit(self: *BashTool) void {
        self.allocator.free(self.config.cwd);
        if (self.config.shell_path) |path| self.allocator.free(path);
        if (self.config.command_prefix) |prefix| self.allocator.free(prefix);
        self.parsed_parameters.deinit();
        self.* = undefined;
    }

    pub fn tool(self: *BashTool) agent.AgentTool {
        return .{
            .name = "bash",
            .description = "Execute a bash command in the current working directory. Returns stdout and stderr. " ++
                "Output is truncated to last 2000 lines or 50KB.",
            .parameters = self.parsed_parameters.value,
            .label = "bash",
            .execution_mode = .sequential,
            .execute = .{ .context = self, .call_fn = execute },
        };
    }
};

fn validateConfig(config: BashTool.Config) !void {
    if (config.cwd.len == 0) return error.InvalidToolConfig;
    if (config.timeout_ms < 1) return error.InvalidToolConfig;
    if (config.max_timeout_ms < 1) return error.InvalidToolConfig;
    if (config.timeout_ms > config.max_timeout_ms) return error.InvalidToolConfig;
    if (config.max_stdout_bytes == 0) return error.InvalidToolConfig;
    if (config.max_stderr_bytes == 0) return error.InvalidToolConfig;
    if (config.shell_path) |path| {
        if (path.len == 0 or path.len > max_command_bytes) return error.InvalidToolConfig;
    }
    if (config.command_prefix) |prefix| {
        if (prefix.len == 0 or prefix.len > max_command_bytes) return error.InvalidToolConfig;
    }
}

const Args = struct {
    command: []const u8,
    timeout_ms: u64,
};

fn execute(
    allocator: std.mem.Allocator,
    io: std.Io,
    task_runtime: *agent.ToolRuntime,
    context: ?*anyopaque,
    token: runtime.CancelToken,
    _: []const u8,
    params: std.json.Value,
    on_update: ?agent.AgentToolUpdateCallback,
) anyerror!agent.ToolExecutionResult {
    try token.throwIfRequested();
    const self: *BashTool = @ptrCast(@alignCast(context orelse return error.MissingToolContext));
    const args = try parseArgs(self.config, params);

    var update_context: BashUpdateContext = .{
        .allocator = allocator,
        .on_update = on_update,
        .output = output_accumulator.OutputAccumulator.init(allocator, .{
            .max_bytes = max_output_preview_bytes,
            .max_lines = max_output_preview_lines,
        }),
    };
    defer update_context.deinit();
    const run_result = runProcess(
        allocator,
        io,
        task_runtime,
        self.config,
        args,
        token,
        &update_context,
    ) catch |err| switch (err) {
        error.Timeout => {
            const status = try timeoutStatus(allocator, args.timeout_ms);
            defer allocator.free(status);
            return resultFromOutput(allocator, update_context.output.snapshot().content, status, null, .timeout);
        },
        error.OperationCancelled => return resultFromOutput(
            allocator,
            update_context.output.snapshot().content,
            "Command aborted",
            null,
            .canceled,
        ),
        error.StreamTooLong => return resultFromOutput(
            allocator,
            update_context.output.snapshot().content,
            "bash output limit exceeded",
            null,
            .output_limit,
        ),
        else => |unexpected| return unexpected,
    };
    defer freeRunResult(allocator, run_result);
    try token.throwIfRequested();
    return resultFromRun(allocator, run_result, update_context.output.snapshot().content);
}

fn runProcess(
    allocator: std.mem.Allocator,
    io: std.Io,
    task_runtime: *agent.ToolRuntime,
    config: BashTool.Config,
    args: Args,
    token: runtime.CancelToken,
    update_context: *BashUpdateContext,
) anyerror!std.process.RunResult {
    var command_writer: std.Io.Writer.Allocating = .init(allocator);
    defer command_writer.deinit();
    if (config.command_prefix) |prefix| {
        try command_writer.writer.writeAll(prefix);
        try command_writer.writer.writeByte('\n');
    }
    try command_writer.writer.writeAll(args.command);
    if (command_writer.written().len > max_command_bytes) return error.InvalidToolArguments;
    const argv = shellArgv(config, command_writer.written());
    const run_result = try runtime.runProcess(allocator, io, task_runtime, .{
        .argv = &argv,
        .cwd = config.cwd,
        .environ = config.environ,
        .timeout_ms = args.timeout_ms,
        .max_stdout_bytes = config.max_stdout_bytes,
        .max_stderr_bytes = config.max_stderr_bytes,
        .cancel_token = token,
        .on_output = .{ .context = update_context, .call_fn = emitBashOutputUpdate },
    });
    errdefer freeRunResult(allocator, run_result);
    return run_result;
}

const BashUpdateContext = struct {
    allocator: std.mem.Allocator,
    on_update: ?agent.AgentToolUpdateCallback,
    output: output_accumulator.OutputAccumulator,

    fn append(self: *BashUpdateContext, bytes: []const u8) !void {
        try self.output.append(bytes);
    }

    fn deinit(self: *BashUpdateContext) void {
        self.output.deinit();
        self.* = undefined;
    }
};

fn emitBashOutputUpdate(
    context: ?*anyopaque,
    _: runtime.OutputStream,
    bytes: []const u8,
) anyerror!void {
    const self: *BashUpdateContext = @ptrCast(@alignCast(context orelse return));
    try self.append(bytes);
    const on_update = self.on_update orelse return;
    const text = try self.allocator.dupe(u8, bytes);
    defer self.allocator.free(text);
    const content = try self.allocator.alloc(ai.ToolResultContent, 1);
    defer self.allocator.free(content);
    content[0] = .{ .text = .{ .text = text } };
    try on_update.call(.{ .content = content });
}

fn freeRunResult(allocator: std.mem.Allocator, run_result: std.process.RunResult) void {
    allocator.free(run_result.stdout);
    allocator.free(run_result.stderr);
}

fn parseArgs(config: BashTool.Config, params: std.json.Value) !Args {
    if (params != .object) return error.InvalidToolArguments;
    const command_value = params.object.get("command") orelse return error.InvalidToolArguments;
    if (command_value != .string or command_value.string.len == 0) return error.InvalidToolArguments;
    if (command_value.string.len > max_command_bytes) return error.InvalidToolArguments;

    const timeout_ms = if (params.object.get("timeout")) |value| blk: {
        if (value != .integer or value.integer < 1) return error.InvalidToolArguments;
        const requested_seconds = std.math.cast(u64, value.integer) orelse return error.InvalidToolArguments;
        const requested = std.math.mul(
            u64,
            requested_seconds,
            std.time.ms_per_s,
        ) catch return error.InvalidToolArguments;
        if (requested > config.max_timeout_ms) return error.InvalidToolArguments;
        break :blk requested;
    } else config.timeout_ms;

    return .{ .command = command_value.string, .timeout_ms = timeout_ms };
}

fn shellArgv(config: BashTool.Config, command: []const u8) [3][]const u8 {
    return switch (builtin.os.tag) {
        .windows => .{ config.shell_path orelse "cmd.exe", "/C", command },
        else => .{ config.shell_path orelse "/bin/sh", "-c", command },
    };
}

const FailureKind = enum {
    timeout,
    output_limit,
    canceled,
};

fn resultFromRun(
    allocator: std.mem.Allocator,
    run_result: std.process.RunResult,
    observed_output: []const u8,
) !agent.ToolExecutionResult {
    if (observed_output.len > 0) return resultFromOutput(allocator, observed_output, null, run_result.term, null);
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    if (run_result.stdout.len > 0) try writer.writer.writeAll(run_result.stdout);
    if (run_result.stderr.len > 0) {
        if (writer.written().len > 0) try writer.writer.writeByte('\n');
        try writer.writer.writeAll(run_result.stderr);
    }
    return resultFromOutput(allocator, writer.written(), null, run_result.term, null);
}

fn resultFromOutput(
    allocator: std.mem.Allocator,
    full_output: []const u8,
    status: ?[]const u8,
    term: ?std.process.Child.Term,
    failure: ?FailureKind,
) !agent.ToolExecutionResult {
    const preview = try output_tail.appendTail(allocator, "", full_output, .{
        .max_bytes = max_output_preview_bytes,
        .max_lines = max_output_preview_lines,
    });
    defer allocator.free(preview.bytes);

    const truncated = preview.dropped_bytes > 0 or preview.dropped_lines > 0;
    const exit_status = if (status) |text|
        try allocator.dupe(u8, text)
    else if (term) |resolved|
        try commandExitStatus(allocator, resolved)
    else
        try allocator.dupe(u8, "");
    defer allocator.free(exit_status);

    var text_writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer text_writer.deinit();
    if (preview.bytes.len > 0) {
        try text_writer.writer.writeAll(preview.bytes);
    } else {
        try text_writer.writer.writeAll("(no output)");
    }
    if (truncated) {
        try appendTruncationFooter(&text_writer.writer, full_output, preview);
    }
    if (exit_status.len > 0) {
        try appendStatus(&text_writer.writer, exit_status);
    }

    const text = try text_writer.toOwnedSlice();
    errdefer allocator.free(text);
    const result_content = try allocator.alloc(ai.ToolResultContent, 1);
    errdefer allocator.free(result_content);
    result_content[0] = .{ .text = .{ .text = text } };
    return .{
        .allocator = allocator,
        .result = .{
            .content = result_content,
            .details = try resultDetails(allocator, term, failure, full_output, preview),
        },
    };
}

fn timeoutStatus(allocator: std.mem.Allocator, timeout_ms: u64) ![]u8 {
    const seconds = @divTrunc(timeout_ms + std.time.ms_per_s - 1, std.time.ms_per_s);
    return std.fmt.allocPrint(allocator, "Command timed out after {d} seconds", .{seconds});
}

fn commandExitStatus(allocator: std.mem.Allocator, term: std.process.Child.Term) ![]u8 {
    return switch (term) {
        .exited => |code| if (code == 0)
            try allocator.dupe(u8, "")
        else
            try std.fmt.allocPrint(allocator, "Command exited with code {d}", .{code}),
        .signal => |signal| try std.fmt.allocPrint(
            allocator,
            "Command killed by signal {d}",
            .{@intFromEnum(signal)},
        ),
        .stopped => |signal| try std.fmt.allocPrint(
            allocator,
            "Command stopped by signal {d}",
            .{@intFromEnum(signal)},
        ),
        .unknown => |code| try std.fmt.allocPrint(allocator, "Command exited with unknown status {d}", .{code}),
    };
}

fn appendStatus(writer: *std.Io.Writer, status: []const u8) !void {
    try writer.writeAll("\n\n");
    try writer.writeAll(status);
}

fn appendTruncationFooter(
    writer: *std.Io.Writer,
    full_output: []const u8,
    preview: output_tail.TailAppendResult,
) !void {
    const total_lines = countOutputLines(full_output);
    const output_lines = countOutputLines(preview.bytes);
    const start_line = if (output_lines == 0 or total_lines < output_lines) 1 else total_lines - output_lines + 1;
    if (preview.last_line_partial) {
        try writer.print(
            "\n\n[Showing last {d}KB of line {d} ({d}KB limit)]",
            .{ preview.bytes.len / 1024, total_lines, max_output_preview_bytes / 1024 },
        );
    } else {
        try writer.print(
            "\n\n[Showing lines {d}-{d} of {d} ({d}KB limit)]",
            .{ start_line, total_lines, total_lines, max_output_preview_bytes / 1024 },
        );
    }
}

fn countOutputLines(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    var count: usize = 1;
    for (bytes) |byte| {
        if (byte == '\n') count += 1;
    }
    if (bytes[bytes.len - 1] == '\n') count -= 1;
    return count;
}

fn failureDetails(allocator: std.mem.Allocator, kind: FailureKind) !std.json.Value {
    var object: std.json.ObjectMap = .empty;
    errdefer object.deinit(allocator);
    try appendFailureDetails(allocator, &object, kind);
    return .{ .object = object };
}

fn appendFailureDetails(
    allocator: std.mem.Allocator,
    object: *std.json.ObjectMap,
    kind: FailureKind,
) !void {
    try path_utils.putJsonField(allocator, object, "timedOut", .{ .bool = kind == .timeout });
    try path_utils.putJsonField(allocator, object, "outputLimitExceeded", .{ .bool = kind == .output_limit });
    try path_utils.putJsonField(allocator, object, "cancelled", .{ .bool = kind == .canceled });
}

fn resultDetails(
    allocator: std.mem.Allocator,
    term: ?std.process.Child.Term,
    failure: ?FailureKind,
    full_output: []const u8,
    preview: output_tail.TailAppendResult,
) !std.json.Value {
    var object: std.json.ObjectMap = .empty;
    errdefer object.deinit(allocator);
    if (term) |resolved| try appendTermDetails(allocator, &object, resolved) else try appendFailureDetails(
        allocator,
        &object,
        failure orelse .output_limit,
    );
    if (preview.dropped_bytes > 0 or preview.dropped_lines > 0) {
        try path_utils.putJsonField(allocator, &object, "truncation", try truncationDetails(
            allocator,
            full_output,
            preview,
        ));
    }
    return .{ .object = object };
}

fn appendTermDetails(
    allocator: std.mem.Allocator,
    object: *std.json.ObjectMap,
    term: std.process.Child.Term,
) !void {
    try path_utils.putJsonField(allocator, object, "timedOut", .{ .bool = false });
    try path_utils.putJsonField(allocator, object, "outputLimitExceeded", .{ .bool = false });
    switch (term) {
        .exited => |code| try path_utils.putJsonField(allocator, object, "exitCode", .{ .integer = code }),
        .signal => |signal| {
            try path_utils.putJsonField(allocator, object, "signal", .{ .integer = @intFromEnum(signal) });
        },
        .stopped => |signal| {
            try path_utils.putJsonField(allocator, object, "stopped", .{ .integer = @intFromEnum(signal) });
        },
        .unknown => |code| try path_utils.putJsonField(allocator, object, "unknown", .{ .integer = code }),
    }
}

fn truncationDetails(
    allocator: std.mem.Allocator,
    full_output: []const u8,
    preview: output_tail.TailAppendResult,
) !std.json.Value {
    var truncation: std.json.ObjectMap = .empty;
    errdefer truncation.deinit(allocator);
    const total_lines = countOutputLines(full_output);
    const output_lines = countOutputLines(preview.bytes);
    try path_utils.putJsonField(allocator, &truncation, "truncated", .{ .bool = true });
    try path_utils.putJsonStringField(
        allocator,
        &truncation,
        "truncatedBy",
        if (full_output.len > max_output_preview_bytes) "bytes" else "lines",
    );
    try path_utils.putJsonField(allocator, &truncation, "totalLines", .{ .integer = @intCast(total_lines) });
    try path_utils.putJsonField(allocator, &truncation, "totalBytes", .{ .integer = @intCast(full_output.len) });
    try path_utils.putJsonField(allocator, &truncation, "outputLines", .{ .integer = @intCast(output_lines) });
    try path_utils.putJsonField(allocator, &truncation, "outputBytes", .{ .integer = @intCast(preview.bytes.len) });
    try path_utils.putJsonField(
        allocator,
        &truncation,
        "lastLinePartial",
        .{ .bool = preview.last_line_partial },
    );
    try path_utils.putJsonField(allocator, &truncation, "firstLineExceedsLimit", .{ .bool = false });
    try path_utils.putJsonField(allocator, &truncation, "maxLines", .{ .integer = max_output_preview_lines });
    try path_utils.putJsonField(allocator, &truncation, "maxBytes", .{ .integer = max_output_preview_bytes });
    return .{ .object = truncation };
}

test "bash tool runs one cwd-bound command" {
    var task_runtime = try agent.ToolRuntime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/file.txt", .data = "ok" });

    var tool = try initTestTool(tmp.dir, "repo", .{});
    defer tool.deinit();

    var result = try executeTestCommand(task_runtime, &tool, "pwd; cat file.txt");
    defer result.deinit();

    try std.testing.expect(std.mem.endsWith(u8, result.result.content[0].text.text, "repo\nok"));
    try std.testing.expectEqual(@as(i64, 0), result.result.details.?.object.get("exitCode").?.integer);
}

test "bash tool passes explicit environment to child process" {
    var task_runtime = try agent.ToolRuntime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try tmp.dir.realPathFile(std.testing.io, ".", &cwd_buffer);
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("ZI_BASH_ENV_TEST", "present");
    try environ.put("PATH", "/usr/bin:/bin");
    var tool = try BashTool.init(std.testing.allocator, .{
        .cwd = cwd_buffer[0..cwd_len],
        .environ = &environ,
    });
    defer tool.deinit();

    var result = try executeTestCommand(task_runtime, &tool, "printf %s \"$ZI_BASH_ENV_TEST\"");
    defer result.deinit();

    try std.testing.expectEqualStrings("present", result.result.content[0].text.text);
}

test "bash tool treats nonzero exit as result data" {
    var task_runtime = try agent.ToolRuntime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var tool = try initTestTool(tmp.dir, ".", .{});
    defer tool.deinit();

    var result = try executeTestCommand(task_runtime, &tool, "printf nope; exit 7");
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "nope\n\nCommand exited with code 7",
        result.result.content[0].text.text,
    );
    try std.testing.expectEqual(@as(i64, 7), result.result.details.?.object.get("exitCode").?.integer);
}

test "bash tool treats timeout as bounded result data" {
    var task_runtime = try agent.ToolRuntime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var tool = try initTestTool(tmp.dir, ".", .{ .timeout_ms = 1 });
    defer tool.deinit();

    var result = try executeTestCommand(task_runtime, &tool, "sleep 60");
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "(no output)\n\nCommand timed out after 1 seconds",
        result.result.content[0].text.text,
    );
    try std.testing.expect(result.result.details.?.object.get("timedOut").?.bool);
    try std.testing.expect(!result.result.details.?.object.get("outputLimitExceeded").?.bool);
}

test "bash tool treats output limit as bounded result data" {
    var task_runtime = try agent.ToolRuntime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var tool = try initTestTool(tmp.dir, ".", .{ .max_stdout_bytes = 4 });
    defer tool.deinit();

    var result = try executeTestCommand(task_runtime, &tool, "printf abcdef");
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "(no output)\n\nbash output limit exceeded",
        result.result.content[0].text.text,
    );
    try std.testing.expect(!result.result.details.?.object.get("timedOut").?.bool);
    try std.testing.expect(result.result.details.?.object.get("outputLimitExceeded").?.bool);
}

test "bash tool applies command prefix" {
    var task_runtime = try agent.ToolRuntime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var tool = try initTestTool(tmp.dir, ".", .{ .command_prefix = "ZI_PREFIX_VALUE=ok" });
    defer tool.deinit();

    var result = try executeTestCommand(task_runtime, &tool, "printf %s \"$ZI_PREFIX_VALUE\"");
    defer result.deinit();

    try std.testing.expectEqualStrings("ok", result.result.content[0].text.text);
}

test "bash tool applies configured shell path" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var task_runtime = try agent.ToolRuntime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var tool = try initTestTool(tmp.dir, ".", .{ .shell_path = "/bin/sh" });
    defer tool.deinit();

    var result = try executeTestCommand(task_runtime, &tool, "printf shell-ok");
    defer result.deinit();

    try std.testing.expectEqualStrings("shell-ok", result.result.content[0].text.text);
}

test "bash tool accepts timeout seconds" {
    var object: std.json.ObjectMap = .empty;
    defer object.deinit(std.testing.allocator);
    try putCommand(&object, "echo ok");
    try object.put(std.testing.allocator, "timeout", .{ .integer = 2 });

    const args = try parseArgs(.{ .cwd = ".", .timeout_ms = default_timeout_ms }, .{ .object = object });
    try std.testing.expectEqual(@as(u64, 2 * std.time.ms_per_s), args.timeout_ms);
}

test "bash tool rejects oversized commands before process start" {
    var task_runtime = try agent.ToolRuntime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var tool = try initTestTool(tmp.dir, ".", .{});
    defer tool.deinit();

    const oversized = try std.testing.allocator.alloc(u8, max_command_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');

    try std.testing.expectError(error.InvalidToolArguments, executeTestCommand(task_runtime, &tool, oversized));
}

test "bash tool rejects invalid config bounds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try tmp.dir.realPathFile(std.testing.io, ".", &cwd_buffer);

    try std.testing.expectError(error.InvalidToolConfig, BashTool.init(std.testing.allocator, .{
        .cwd = cwd_buffer[0..cwd_len],
        .timeout_ms = max_timeout_ms + 1,
        .max_timeout_ms = max_timeout_ms,
    }));
    try std.testing.expectError(error.InvalidToolConfig, BashTool.init(std.testing.allocator, .{
        .cwd = cwd_buffer[0..cwd_len],
        .max_stdout_bytes = 0,
    }));
}

test "bash tool cancels running process through owner race" {
    var task_runtime = try agent.ToolRuntime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    const io = task_runtime.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var tool = try initTestTool(tmp.dir, ".", .{});
    defer tool.deinit();

    var object: std.json.ObjectMap = .empty;
    defer object.deinit(std.testing.allocator);
    try putCommand(&object, "sleep 60");

    var cancel_source = try runtime.CancelSource.init(std.testing.allocator);
    defer cancel_source.deinit();
    var future = try task_runtime.spawn(execute, .{
        std.testing.allocator,
        io,
        task_runtime,
        &tool,
        cancel_source.token(),
        "call",
        std.json.Value{ .object = object },
        null,
    });
    cancel_source.request();

    try std.testing.expectError(error.OperationCancelled, future.join());
}

fn initTestTool(dir: std.Io.Dir, sub_path: []const u8, config: struct {
    timeout_ms: ?u64 = null,
    max_stdout_bytes: ?usize = null,
    shell_path: ?[]const u8 = null,
    command_prefix: ?[]const u8 = null,
}) !BashTool {
    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try dir.realPathFile(std.testing.io, sub_path, &cwd_buffer);
    return BashTool.init(std.testing.allocator, .{
        .cwd = cwd_buffer[0..cwd_len],
        .timeout_ms = config.timeout_ms orelse default_timeout_ms,
        .max_stdout_bytes = config.max_stdout_bytes orelse max_stdout_bytes,
        .shell_path = config.shell_path,
        .command_prefix = config.command_prefix,
    });
}

fn putCommand(object: *std.json.ObjectMap, command: []const u8) !void {
    try object.put(std.testing.allocator, "command", .{ .string = command });
}

fn executeTestCommand(
    task_runtime: *agent.ToolRuntime,
    tool: *BashTool,
    command: []const u8,
) !agent.ToolExecutionResult {
    var object: std.json.ObjectMap = .empty;
    defer object.deinit(std.testing.allocator);
    try putCommand(&object, command);

    var cancel_source = try runtime.CancelSource.init(std.testing.allocator);
    defer cancel_source.deinit();
    return execute(std.testing.allocator, task_runtime.io(), task_runtime, tool, cancel_source.token(), "call", .{
        .object = object,
    }, null);
}
