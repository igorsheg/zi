const std = @import("std");
const builtin = @import("builtin");
const agent = @import("../../agent/root.zig");
const ai = @import("../../ai/root.zig");
const runtime = @import("../../runtime/root.zig");
const path_utils = @import("path_utils.zig");
const output_accumulator = @import("output_accumulator.zig");
const output_tail = @import("output_tail.zig");
const test_support = @import("test_support.zig");
const tool_output_policy = @import("../tool_output_policy.zig");

pub const default_timeout_ms = 30_000;
pub const max_timeout_ms = 120_000;
pub const max_command_bytes = 16 * 1024;
pub const max_output_preview_bytes = tool_output_policy.default_max_bytes;
pub const max_output_preview_lines = tool_output_policy.default_max_lines;
pub const max_stdout_bytes = 16 * 1024 * 1024;
pub const max_stderr_bytes = 16 * 1024 * 1024;

const parameters_schema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "command": {
    \\      "type": "string",
    \\      "description": "Bash command to run in the session cwd via bash -c",
    \\      "maxLength": 16384
    \\    },
    \\    "timeout": { "type": "integer", "description": "Optional timeout in seconds, max 120" }
    \\  },
    \\  "required": ["command"]
    \\}
;

/// Classify a finished bash tool result as success or error from its details
/// payload. This is the one owner of the details schema written by
/// `resultDetails` below; the session layer calls it after every bash call.
pub fn classifyResult(details: ?std.json.Value, fallback_is_error: bool) bool {
    const value = details orelse return fallback_is_error;
    if (value != .object) return fallback_is_error;
    const object = value.object;
    if (jsonBool(object.get("timedOut"))) |timed_out| if (timed_out) return true;
    if (jsonBool(object.get("outputLimitExceeded"))) |limited| if (limited) return true;
    if (jsonBool(object.get("cancelled"))) |cancelled| if (cancelled) return true;
    if (object.get("signal") != null or object.get("stopped") != null or object.get("unknown") != null) {
        return true;
    }
    if (object.get("exitCode")) |code| if (code == .integer) return code.integer != 0;
    return fallback_is_error;
}

fn jsonBool(value: ?std.json.Value) ?bool {
    const resolved = value orelse return null;
    return if (resolved == .bool) resolved.bool else null;
}

pub const BashTool = struct {
    allocator: std.mem.Allocator,
    config: Config,
    parsed_parameters: runtime.JsonOwned(std.json.Value),

    pub const Config = struct {
        cwd: []const u8,
        environ: ?*const std.process.Environ.Map = null,
        timeout_ms: u64 = default_timeout_ms,
        max_timeout_ms: u64 = max_timeout_ms,
        max_stdout_bytes: usize = max_stdout_bytes,
        max_stderr_bytes: usize = max_stderr_bytes,
        temp_dir: ?[]const u8 = null,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !BashTool {
        try validateConfig(config);
        const cwd = try allocator.dupe(u8, config.cwd);
        errdefer allocator.free(cwd);
        const temp_dir = if (config.temp_dir) |path| try allocator.dupe(u8, path) else null;
        errdefer if (temp_dir) |path| allocator.free(path);
        const parsed_parameters = try runtime.JsonOwned(std.json.Value).parseJson(allocator, parameters_schema, .{});
        var owned_config = config;
        owned_config.cwd = cwd;
        owned_config.temp_dir = temp_dir;
        return .{
            .allocator = allocator,
            .config = owned_config,
            .parsed_parameters = parsed_parameters,
        };
    }

    pub fn deinit(self: *BashTool) void {
        self.allocator.free(self.config.cwd);
        if (self.config.temp_dir) |path| self.allocator.free(path);
        self.parsed_parameters.deinit();
        self.* = undefined;
    }

    pub fn tool(self: *BashTool) agent.AgentTool {
        return .{
            .name = "bash",
            .description = "Execute a bash command via bash -c in the current working directory. " ++
                "Falls back to sh only when bash is unavailable on Unix. Returns stdout and stderr. " ++
                "Output is truncated to last 2000 lines or 50KB; if truncated, full output is saved to a temp file.",
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
    if (config.temp_dir) |path| if (path.len == 0) return error.InvalidToolConfig;
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
        .output = output_accumulator.OutputAccumulator.init(allocator, io, .{
            .max_bytes = max_output_preview_bytes,
            .max_lines = max_output_preview_lines,
            .temp_dir = outputTempDir(self.config),
            .temp_file_prefix = "zi-bash",
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
            return resultFromObservedOutput(allocator, update_context.finalSnapshot(), status, null, .timeout);
        },
        error.OperationCancelled => return resultFromObservedOutput(
            allocator,
            update_context.finalSnapshot(),
            "Command aborted",
            null,
            .canceled,
        ),
        error.StreamTooLong => return resultFromObservedOutput(
            allocator,
            update_context.finalSnapshot(),
            "bash output limit exceeded",
            null,
            .output_limit,
        ),
        else => |unexpected| return unexpected,
    };
    defer freeRunResult(allocator, run_result);
    update_context.output.finish();
    try token.throwIfRequested();
    return resultFromObservedOutput(allocator, update_context.output.snapshot(), null, run_result.term, null);
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
    const shell = shellArgv(io, args.command);
    const run_result = runtime.runProcess(allocator, io, task_runtime, .{
        .argv = &shell.argv,
        .cwd = config.cwd,
        .environ = config.environ,
        .timeout_ms = args.timeout_ms,
        .max_stdout_bytes = config.max_stdout_bytes,
        .max_stderr_bytes = config.max_stderr_bytes,
        .capture_output = false,
        .cancel_token = token,
        .on_output = .{ .context = update_context, .call_fn = emitBashOutputUpdate },
    }) catch |err| switch (err) {
        error.FileNotFound => if (shell.fallback_to_sh_on_not_found)
            try runtime.runProcess(allocator, io, task_runtime, .{
                .argv = &.{ "sh", "-c", args.command },
                .cwd = config.cwd,
                .environ = config.environ,
                .timeout_ms = args.timeout_ms,
                .max_stdout_bytes = config.max_stdout_bytes,
                .max_stderr_bytes = config.max_stderr_bytes,
                .capture_output = false,
                .cancel_token = token,
                .on_output = .{ .context = update_context, .call_fn = emitBashOutputUpdate },
            })
        else
            return err,
        else => return err,
    };
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

    fn finalSnapshot(self: *BashUpdateContext) output_accumulator.Snapshot {
        self.output.finish();
        return self.output.snapshot();
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
    const text = try path_utils.dupSanitizedUtf8(self.allocator, bytes);
    defer self.allocator.free(text);
    const content = try self.allocator.alloc(ai.ToolResultContent, 1);
    defer self.allocator.free(content);
    content[0] = .{ .text = .{ .text = text } };
    try on_update.call(.{ .content = content });
}

fn outputTempDir(config: BashTool.Config) []const u8 {
    if (config.temp_dir) |path| return path;
    if (config.environ) |environ| {
        if (environ.get("TMPDIR")) |path| if (std.fs.path.isAbsolute(path)) return path;
        if (environ.get("TEMP")) |path| if (std.fs.path.isAbsolute(path)) return path;
        if (environ.get("TMP")) |path| if (std.fs.path.isAbsolute(path)) return path;
    }
    return if (builtin.os.tag == .windows) config.cwd else "/tmp";
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

const ShellArgv = struct {
    argv: [3][]const u8,
    fallback_to_sh_on_not_found: bool = false,
};

fn shellArgv(io: std.Io, command: []const u8) ShellArgv {
    return switch (builtin.os.tag) {
        .windows => .{ .argv = .{ windowsBashPath(io), "-c", command } },
        else => if (executableExists(io, "/bin/bash"))
            .{ .argv = .{ "/bin/bash", "-c", command } }
        else
            .{ .argv = .{ "bash", "-c", command }, .fallback_to_sh_on_not_found = true },
    };
}

fn windowsBashPath(io: std.Io) []const u8 {
    const git_bash = "C:\\Program Files\\Git\\bin\\bash.exe";
    if (executableExists(io, git_bash)) return git_bash;
    const git_bash_x86 = "C:\\Program Files (x86)\\Git\\bin\\bash.exe";
    if (executableExists(io, git_bash_x86)) return git_bash_x86;
    return "bash.exe";
}

fn executableExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.access(.cwd(), io, path, .{
        .read = false,
        .write = false,
        .execute = true,
        .follow_symlinks = true,
    }) catch return false;
    return true;
}

const FailureKind = enum {
    timeout,
    output_limit,
    canceled,
};

fn resultFromObservedOutput(
    allocator: std.mem.Allocator,
    observed_output: output_accumulator.Snapshot,
    status: ?[]const u8,
    term: ?std.process.Child.Term,
    failure: ?FailureKind,
) !agent.ToolExecutionResult {
    return resultFromOutputWithTotals(allocator, observed_output.content, status, term, failure, .{
        .total_lines = observed_output.total_lines,
        .total_bytes = observed_output.total_bytes,
        .truncated = observed_output.truncated,
        .last_line_partial = observed_output.last_line_partial,
        .full_output_path = observed_output.full_output_path,
    });
}

const OutputTotals = struct {
    total_lines: usize,
    total_bytes: usize,
    truncated: bool,
    last_line_partial: bool,
    full_output_path: ?[]const u8 = null,
};

const OutputFacts = struct {
    truncated: bool,
    total_lines: usize,
    total_bytes: usize,
    output_lines: usize,
    output_bytes: usize,
    last_line_partial: bool,
    full_output_path: ?[]const u8 = null,
};

fn resultFromOutputWithTotals(
    allocator: std.mem.Allocator,
    output: []const u8,
    status: ?[]const u8,
    term: ?std.process.Child.Term,
    failure: ?FailureKind,
    output_totals: ?OutputTotals,
) !agent.ToolExecutionResult {
    const preview = try output_tail.appendTail(allocator, "", output, .{
        .max_bytes = max_output_preview_bytes,
        .max_lines = max_output_preview_lines,
    });
    defer allocator.free(preview.bytes);

    const preview_truncated = preview.dropped_bytes > 0 or preview.dropped_lines > 0;
    const totals = output_totals orelse OutputTotals{
        .total_lines = countOutputLines(output),
        .total_bytes = output.len,
        .truncated = preview_truncated,
        .last_line_partial = preview.last_line_partial,
        .full_output_path = null,
    };
    const facts: OutputFacts = .{
        .truncated = totals.truncated or preview_truncated,
        .total_lines = totals.total_lines,
        .total_bytes = totals.total_bytes,
        .output_lines = countOutputLines(preview.bytes),
        .output_bytes = preview.bytes.len,
        .last_line_partial = totals.last_line_partial or preview.last_line_partial,
        .full_output_path = totals.full_output_path,
    };
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
    if (facts.truncated) {
        try appendTruncationFooter(&text_writer.writer, facts);
    }
    if (exit_status.len > 0) {
        try text_writer.writer.writeAll("\n\n");
        try text_writer.writer.writeAll(exit_status);
    }

    const details = try resultDetails(allocator, term, failure, facts);
    errdefer runtime.freeJsonValue(allocator, details);
    return path_utils.ownedTextResult(allocator, try text_writer.toOwnedSlice(), details);
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

fn appendTruncationFooter(writer: *std.Io.Writer, facts: OutputFacts) !void {
    const start_line = if (facts.output_lines == 0 or facts.total_lines < facts.output_lines)
        1
    else
        facts.total_lines - facts.output_lines + 1;
    if (facts.last_line_partial) {
        try writer.print(
            "\n\n[Showing last {d}KB of line {d} ({d}KB limit)",
            .{ facts.output_bytes / 1024, facts.total_lines, max_output_preview_bytes / 1024 },
        );
    } else {
        try writer.print(
            "\n\n[Showing lines {d}-{d} of {d} ({d}KB limit)",
            .{ start_line, facts.total_lines, facts.total_lines, max_output_preview_bytes / 1024 },
        );
    }
    if (facts.full_output_path) |path| try writer.print(". Full output: {s}", .{path});
    try writer.writeByte(']');
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

fn resultDetails(
    allocator: std.mem.Allocator,
    term: ?std.process.Child.Term,
    failure: ?FailureKind,
    facts: OutputFacts,
) !std.json.Value {
    var exit_code: ?i64 = null;
    var signal: ?i64 = null;
    var stopped: ?i64 = null;
    var unknown: ?i64 = null;
    var cancelled: ?bool = null;
    var timed_out = false;
    var output_limited = false;
    if (term) |resolved| switch (resolved) {
        .exited => |code| exit_code = code,
        .signal => |value| signal = @intFromEnum(value),
        .stopped => |value| stopped = @intFromEnum(value),
        .unknown => |code| unknown = code,
    } else {
        const kind = failure orelse .output_limit;
        timed_out = kind == .timeout;
        output_limited = kind == .output_limit;
        cancelled = kind == .canceled;
    }
    const truncation: ?std.json.Value = if (facts.truncated)
        try path_utils.jsonDetails(allocator, .{
            .truncated = true,
            .truncatedBy = @as([]const u8, if (facts.total_bytes > max_output_preview_bytes) "bytes" else "lines"),
            .totalLines = facts.total_lines,
            .totalBytes = facts.total_bytes,
            .outputLines = facts.output_lines,
            .outputBytes = facts.output_bytes,
            .lastLinePartial = facts.last_line_partial,
            .firstLineExceedsLimit = false,
            .maxLines = max_output_preview_lines,
            .maxBytes = max_output_preview_bytes,
        })
    else
        null;
    return path_utils.jsonDetails(allocator, .{
        .timedOut = timed_out,
        .outputLimitExceeded = output_limited,
        .cancelled = cancelled,
        .exitCode = exit_code,
        .signal = signal,
        .stopped = stopped,
        .unknown = unknown,
        .truncation = truncation,
        .fullOutputPath = facts.full_output_path,
    });
}

test "bash tool runs one cwd-bound command" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    try fixture.write("repo/file.txt", "ok");

    var tool = try BashTool.init(std.testing.allocator, .{ .cwd = fixture.cwd() });
    defer tool.deinit();

    var result = try test_support.execute(tool.tool(), "{\"command\":\"pwd; cat file.txt\"}");
    defer result.deinit();

    try std.testing.expect(std.mem.endsWith(u8, result.result.content[0].text.text, "repo\nok"));
    try std.testing.expectEqual(@as(i64, 0), result.result.details.?.object.get("exitCode").?.integer);
}

test "bash tool executes bash syntax on unix" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();

    var tool = try BashTool.init(std.testing.allocator, .{ .cwd = fixture.cwd() });
    defer tool.deinit();

    var result = try test_support.execute(tool.tool(), "{\"command\":\"value=(ok); printf %s \\\"${value[0]}\\\"\"}");
    defer result.deinit();

    try std.testing.expectEqualStrings("ok", result.result.content[0].text.text);
    try std.testing.expectEqual(@as(i64, 0), result.result.details.?.object.get("exitCode").?.integer);
}

test "bash tool description names bash shell contract" {
    var tool = try BashTool.init(std.testing.allocator, .{ .cwd = "." });
    defer tool.deinit();

    const description = tool.tool().description;
    try std.testing.expect(std.mem.indexOf(u8, description, "bash command") != null);
    try std.testing.expect(std.mem.indexOf(u8, description, "bash -c") != null);
}

test "bash tool passes explicit environment to child process" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("ZI_BASH_ENV_TEST", "present");
    try environ.put("PATH", "/usr/bin:/bin");

    var tool = try BashTool.init(std.testing.allocator, .{ .cwd = fixture.cwd(), .environ = &environ });
    defer tool.deinit();

    var result = try test_support.execute(tool.tool(), "{\"command\":\"printf %s \\\"$ZI_BASH_ENV_TEST\\\"\"}");
    defer result.deinit();

    try std.testing.expectEqualStrings("present", result.result.content[0].text.text);
}

test "bash tool sanitizes invalid utf8 output" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    var tool = try BashTool.init(std.testing.allocator, .{ .cwd = fixture.cwd() });
    defer tool.deinit();

    var result = try test_support.execute(tool.tool(), "{\"command\":\"printf '\\\\377'\"}");
    defer result.deinit();

    try std.testing.expect(std.unicode.utf8ValidateSlice(result.result.content[0].text.text));
    try std.testing.expectEqualStrings("�", result.result.content[0].text.text);
}

test "bash tool treats nonzero exit as result data" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    var tool = try BashTool.init(std.testing.allocator, .{ .cwd = fixture.cwd() });
    defer tool.deinit();

    var result = try test_support.execute(tool.tool(), "{\"command\":\"printf nope; exit 7\"}");
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "nope\n\nCommand exited with code 7",
        result.result.content[0].text.text,
    );
    try std.testing.expectEqual(@as(i64, 7), result.result.details.?.object.get("exitCode").?.integer);
}

test "bash tool treats timeout as bounded result data" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    var tool = try BashTool.init(std.testing.allocator, .{ .cwd = fixture.cwd(), .timeout_ms = 1 });
    defer tool.deinit();

    var result = try test_support.execute(tool.tool(), "{\"command\":\"sleep 60\"}");
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "(no output)\n\nCommand timed out after 1 seconds",
        result.result.content[0].text.text,
    );
    try std.testing.expect(result.result.details.?.object.get("timedOut").?.bool);
    try std.testing.expect(!result.result.details.?.object.get("outputLimitExceeded").?.bool);
}

test "bash tool treats output limit as bounded result data" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    var tool = try BashTool.init(std.testing.allocator, .{ .cwd = fixture.cwd(), .max_stdout_bytes = 4 });
    defer tool.deinit();

    var result = try test_support.execute(tool.tool(), "{\"command\":\"printf abcdef\"}");
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "(no output)\n\nbash output limit exceeded",
        result.result.content[0].text.text,
    );
    try std.testing.expect(!result.result.details.?.object.get("timedOut").?.bool);
    try std.testing.expect(result.result.details.?.object.get("outputLimitExceeded").?.bool);
}

test "bash result classification marks operational failures as errors" {
    const allocator = std.testing.allocator;

    const success = try path_utils.jsonDetails(allocator, .{ .exitCode = 0 });
    defer runtime.freeJsonValue(allocator, success);
    try std.testing.expect(!classifyResult(success, false));

    const nonzero = try path_utils.jsonDetails(allocator, .{ .exitCode = 7 });
    defer runtime.freeJsonValue(allocator, nonzero);
    try std.testing.expect(classifyResult(nonzero, false));

    const timed_out = try path_utils.jsonDetails(allocator, .{ .timedOut = true });
    defer runtime.freeJsonValue(allocator, timed_out);
    try std.testing.expect(classifyResult(timed_out, false));

    const output_limited = try path_utils.jsonDetails(allocator, .{ .outputLimitExceeded = true });
    defer runtime.freeJsonValue(allocator, output_limited);
    try std.testing.expect(classifyResult(output_limited, false));

    const cancelled = try path_utils.jsonDetails(allocator, .{ .cancelled = true });
    defer runtime.freeJsonValue(allocator, cancelled);
    try std.testing.expect(classifyResult(cancelled, false));

    const signal = try path_utils.jsonDetails(allocator, .{ .signal = 9 });
    defer runtime.freeJsonValue(allocator, signal);
    try std.testing.expect(classifyResult(signal, false));

    const stopped = try path_utils.jsonDetails(allocator, .{ .stopped = 19 });
    defer runtime.freeJsonValue(allocator, stopped);
    try std.testing.expect(classifyResult(stopped, false));

    const unknown = try path_utils.jsonDetails(allocator, .{ .unknown = 1 });
    defer runtime.freeJsonValue(allocator, unknown);
    try std.testing.expect(classifyResult(unknown, false));
}

test "bash tail truncation details include line byte and limit facts" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    for (0..max_output_preview_lines + 2) |index| {
        try output.writer.print("line {d}\n", .{index + 1});
    }

    var result = try resultFromOutputWithTotals(
        std.testing.allocator,
        output.written(),
        null,
        .{ .exited = 0 },
        null,
        null,
    );
    defer result.deinit();

    const truncation = result.result.details.?.object.get("truncation").?.object;
    try std.testing.expectEqualStrings("lines", truncation.get("truncatedBy").?.string);
    try std.testing.expectEqual(@as(i64, max_output_preview_lines + 2), truncation.get("totalLines").?.integer);
    try std.testing.expectEqual(@as(i64, max_output_preview_lines), truncation.get("outputLines").?.integer);
    try std.testing.expect(truncation.get("totalBytes").?.integer > truncation.get("outputBytes").?.integer);
    try std.testing.expectEqual(@as(i64, max_output_preview_lines), truncation.get("maxLines").?.integer);
    try std.testing.expectEqual(@as(i64, max_output_preview_bytes), truncation.get("maxBytes").?.integer);
    try std.testing.expect(!truncation.get("lastLinePartial").?.bool);
    try std.testing.expect(!truncation.get("firstLineExceedsLimit").?.bool);
}

test "bash execute path preserves tail truncation totals" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    var tool = try BashTool.init(std.testing.allocator, .{ .cwd = fixture.cwd(), .temp_dir = fixture.cwd() });
    defer tool.deinit();

    const args = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"command\":\"" ++
            "i=1; while [ $i -le {d} ]; do printf 'line %s\\\\n' $i; " ++
            "i=$((i+1)); done; sleep 0.05" ++
            "\"}}",
        .{max_output_preview_lines + 2},
    );
    defer std.testing.allocator.free(args);

    var result = try test_support.execute(tool.tool(), args);
    defer result.deinit();

    const truncation = result.result.details.?.object.get("truncation").?.object;
    try std.testing.expectEqualStrings("lines", truncation.get("truncatedBy").?.string);
    try std.testing.expectEqual(@as(i64, max_output_preview_lines + 2), truncation.get("totalLines").?.integer);
    try std.testing.expectEqual(@as(i64, max_output_preview_lines), truncation.get("outputLines").?.integer);
    const full_output_path = result.result.details.?.object.get("fullOutputPath").?.string;
    try std.testing.expect(std.fs.path.isAbsolute(full_output_path));
    try std.testing.expect(std.mem.indexOf(u8, result.result.content[0].text.text, "Full output: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.result.content[0].text.text, full_output_path) != null);

    var file = try std.Io.Dir.openFileAbsolute(std.testing.io, full_output_path, .{});
    defer file.close(std.testing.io);
    var prefix: [14]u8 = undefined;
    const prefix_len = try file.readPositionalAll(std.testing.io, &prefix, 0);
    try std.testing.expectEqual(@as(usize, prefix.len), prefix_len);
    try std.testing.expectEqualStrings("line 1\nline 2\n", prefix[0..prefix_len]);
}

test "bash tool accepts timeout seconds" {
    var object: std.json.ObjectMap = .empty;
    defer object.deinit(std.testing.allocator);
    try object.put(std.testing.allocator, "command", .{ .string = "echo ok" });
    try object.put(std.testing.allocator, "timeout", .{ .integer = 2 });

    const args = try parseArgs(.{ .cwd = ".", .timeout_ms = default_timeout_ms }, .{ .object = object });
    try std.testing.expectEqual(@as(u64, 2 * std.time.ms_per_s), args.timeout_ms);
}

test "bash tool rejects oversized commands before process start" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    var tool = try BashTool.init(std.testing.allocator, .{ .cwd = fixture.cwd() });
    defer tool.deinit();

    var args = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer args.deinit();
    try args.writer.writeAll("{\"command\":\"");
    try args.writer.splatByteAll('x', max_command_bytes + 1);
    try args.writer.writeAll("\"}");

    try std.testing.expectError(
        error.InvalidToolArguments,
        test_support.execute(tool.tool(), args.written()),
    );
}

test "bash tool rejects invalid config bounds" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();

    try std.testing.expectError(error.InvalidToolConfig, BashTool.init(std.testing.allocator, .{
        .cwd = fixture.cwd(),
        .timeout_ms = max_timeout_ms + 1,
        .max_timeout_ms = max_timeout_ms,
    }));
    try std.testing.expectError(error.InvalidToolConfig, BashTool.init(std.testing.allocator, .{
        .cwd = fixture.cwd(),
        .max_stdout_bytes = 0,
    }));
}

test "bash tool cancels running process through owner race" {
    var task_runtime = try agent.ToolRuntime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    const io = task_runtime.io();

    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    var tool = try BashTool.init(std.testing.allocator, .{ .cwd = fixture.cwd() });
    defer tool.deinit();

    var object: std.json.ObjectMap = .empty;
    defer object.deinit(std.testing.allocator);
    try object.put(std.testing.allocator, "command", .{ .string = "sleep 60" });

    var cancel_source = try runtime.CancelSource.init(std.testing.allocator, task_runtime.io());
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
