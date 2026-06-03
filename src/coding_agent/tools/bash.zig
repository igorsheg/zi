const std = @import("std");
const builtin = @import("builtin");
const agent = @import("../../agent/root.zig");
const ai = @import("../../ai/root.zig");
const runtime = @import("../../runtime/root.zig");
const path_utils = @import("path_utils.zig");

pub const default_timeout_ms = 30_000;
pub const max_timeout_ms = 120_000;
pub const max_command_bytes = 16 * 1024;
pub const max_stdout_bytes = 64 * 1024;
pub const max_stderr_bytes = 64 * 1024;

const parameters_schema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "command": {
    \\      "type": "string",
    \\      "description": "Shell command to run in the session cwd",
    \\      "maxLength": 16384
    \\    },
    \\    "timeout_ms": { "type": "integer", "description": "Optional timeout in milliseconds, max 120000" }
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
        timeout_ms: u64 = default_timeout_ms,
        max_timeout_ms: u64 = max_timeout_ms,
        max_stdout_bytes: usize = max_stdout_bytes,
        max_stderr_bytes: usize = max_stderr_bytes,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !BashTool {
        try validateConfig(config);
        const cwd = try allocator.dupe(u8, config.cwd);
        errdefer allocator.free(cwd);
        const parsed_parameters = try runtime.JsonOwned(std.json.Value).parseJson(allocator, parameters_schema, .{});
        return .{
            .allocator = allocator,
            .config = .{
                .cwd = cwd,
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
        self.parsed_parameters.deinit();
        self.* = undefined;
    }

    pub fn tool(self: *BashTool) agent.AgentTool {
        return .{
            .name = "bash",
            .description = "Run one shell command in the session cwd with timeout and bounded output.",
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
}

const Args = struct {
    command: []const u8,
    timeout_ms: u64,
};

fn execute(
    allocator: std.mem.Allocator,
    io: std.Io,
    zio_runtime: *agent.ToolRuntime,
    context: ?*anyopaque,
    token: runtime.CancelToken,
    _: []const u8,
    params: std.json.Value,
    on_update: ?agent.AgentToolUpdateCallback,
) anyerror!agent.ToolExecutionResult {
    try token.throwIfRequested();
    const self: *BashTool = @ptrCast(@alignCast(context orelse return error.MissingToolContext));
    const args = try parseArgs(self.config, params);

    var update_context: BashUpdateContext = .{ .allocator = allocator, .on_update = on_update };
    const run_result = runProcess(
        allocator,
        io,
        zio_runtime,
        self.config,
        args,
        token,
        &update_context,
    ) catch |err| switch (err) {
        error.Timeout => return resultFromFailure(allocator, "bash timed out", .timeout),
        error.StreamTooLong => return resultFromFailure(allocator, "bash output limit exceeded", .output_limit),
        else => |unexpected| return unexpected,
    };
    defer freeRunResult(allocator, run_result);
    try token.throwIfRequested();
    return resultFromRun(allocator, run_result);
}

fn runProcess(
    allocator: std.mem.Allocator,
    io: std.Io,
    zio_runtime: *agent.ToolRuntime,
    config: BashTool.Config,
    args: Args,
    token: runtime.CancelToken,
    update_context: *BashUpdateContext,
) anyerror!std.process.RunResult {
    const argv = shellArgv(args.command);
    const run_result = try runtime.runProcess(allocator, io, zio_runtime, .{
        .argv = &argv,
        .cwd = config.cwd,
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
};

fn emitBashOutputUpdate(
    context: ?*anyopaque,
    _: runtime.OutputStream,
    bytes: []const u8,
) anyerror!void {
    const self: *BashUpdateContext = @ptrCast(@alignCast(context orelse return));
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

    const timeout_ms = if (params.object.get("timeout_ms")) |value| blk: {
        if (value != .integer or value.integer < 1) return error.InvalidToolArguments;
        const requested = std.math.cast(u64, value.integer) orelse return error.InvalidToolArguments;
        if (requested > config.max_timeout_ms) return error.InvalidToolArguments;
        break :blk requested;
    } else config.timeout_ms;

    return .{ .command = command_value.string, .timeout_ms = timeout_ms };
}

fn shellArgv(command: []const u8) [3][]const u8 {
    return switch (builtin.os.tag) {
        .windows => .{ "cmd.exe", "/C", command },
        else => .{ "/bin/sh", "-c", command },
    };
}

const FailureKind = enum {
    timeout,
    output_limit,
};

fn resultFromFailure(
    allocator: std.mem.Allocator,
    message: []const u8,
    kind: FailureKind,
) !agent.ToolExecutionResult {
    const text = try allocator.dupe(u8, message);
    errdefer allocator.free(text);
    const result_content = try allocator.alloc(ai.ToolResultContent, 1);
    errdefer allocator.free(result_content);
    result_content[0] = .{ .text = .{ .text = text } };
    return .{
        .allocator = allocator,
        .result = .{
            .content = result_content,
            .details = try failureDetails(allocator, kind),
        },
    };
}

fn resultFromRun(
    allocator: std.mem.Allocator,
    run_result: std.process.RunResult,
) !agent.ToolExecutionResult {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    if (run_result.stdout.len > 0) try writer.writer.writeAll(run_result.stdout);
    if (run_result.stderr.len > 0) {
        if (writer.written().len > 0) try writer.writer.writeByte('\n');
        try writer.writer.writeAll(run_result.stderr);
    }
    const text = try writer.toOwnedSlice();
    errdefer allocator.free(text);
    const result_content = try allocator.alloc(ai.ToolResultContent, 1);
    errdefer allocator.free(result_content);
    result_content[0] = .{ .text = .{ .text = text } };
    return .{
        .allocator = allocator,
        .result = .{
            .content = result_content,
            .details = try termDetails(allocator, run_result.term),
        },
    };
}

fn failureDetails(allocator: std.mem.Allocator, kind: FailureKind) !std.json.Value {
    var object: std.json.ObjectMap = .empty;
    errdefer object.deinit(allocator);
    try path_utils.putJsonField(allocator, &object, "timedOut", .{ .bool = kind == .timeout });
    try path_utils.putJsonField(allocator, &object, "outputLimitExceeded", .{ .bool = kind == .output_limit });
    return .{ .object = object };
}

fn termDetails(allocator: std.mem.Allocator, term: std.process.Child.Term) !std.json.Value {
    var object: std.json.ObjectMap = .empty;
    errdefer object.deinit(allocator);
    try path_utils.putJsonField(allocator, &object, "timedOut", .{ .bool = false });
    try path_utils.putJsonField(allocator, &object, "outputLimitExceeded", .{ .bool = false });
    switch (term) {
        .exited => |code| try path_utils.putJsonField(allocator, &object, "exitCode", .{ .integer = code }),
        .signal => |signal| {
            try path_utils.putJsonField(allocator, &object, "signal", .{ .integer = @intFromEnum(signal) });
        },
        .stopped => |signal| {
            try path_utils.putJsonField(allocator, &object, "stopped", .{ .integer = @intFromEnum(signal) });
        },
        .unknown => |code| try path_utils.putJsonField(allocator, &object, "unknown", .{ .integer = code }),
    }
    return .{ .object = object };
}

test "bash tool runs one cwd-bound command" {
    var zio_runtime = try agent.ToolRuntime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/file.txt", .data = "ok" });

    var tool = try initTestTool(tmp.dir, "repo", .{});
    defer tool.deinit();

    var result = try executeTestCommand(zio_runtime, &tool, "pwd; cat file.txt");
    defer result.deinit();

    try std.testing.expect(std.mem.endsWith(u8, result.result.content[0].text.text, "repo\nok"));
    try std.testing.expectEqual(@as(i64, 0), result.result.details.?.object.get("exitCode").?.integer);
}

test "bash tool treats nonzero exit as result data" {
    var zio_runtime = try agent.ToolRuntime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var tool = try initTestTool(tmp.dir, ".", .{});
    defer tool.deinit();

    var result = try executeTestCommand(zio_runtime, &tool, "printf nope; exit 7");
    defer result.deinit();

    try std.testing.expectEqualStrings("nope", result.result.content[0].text.text);
    try std.testing.expectEqual(@as(i64, 7), result.result.details.?.object.get("exitCode").?.integer);
}

test "bash tool treats timeout as bounded result data" {
    var zio_runtime = try agent.ToolRuntime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var tool = try initTestTool(tmp.dir, ".", .{ .timeout_ms = 1 });
    defer tool.deinit();

    var result = try executeTestCommand(zio_runtime, &tool, "sleep 60");
    defer result.deinit();

    try std.testing.expectEqualStrings("bash timed out", result.result.content[0].text.text);
    try std.testing.expect(result.result.details.?.object.get("timedOut").?.bool);
    try std.testing.expect(!result.result.details.?.object.get("outputLimitExceeded").?.bool);
}

test "bash tool treats output limit as bounded result data" {
    var zio_runtime = try agent.ToolRuntime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var tool = try initTestTool(tmp.dir, ".", .{ .max_stdout_bytes = 4 });
    defer tool.deinit();

    var result = try executeTestCommand(zio_runtime, &tool, "printf abcdef");
    defer result.deinit();

    try std.testing.expectEqualStrings("bash output limit exceeded", result.result.content[0].text.text);
    try std.testing.expect(!result.result.details.?.object.get("timedOut").?.bool);
    try std.testing.expect(result.result.details.?.object.get("outputLimitExceeded").?.bool);
}

test "bash tool rejects oversized commands before process start" {
    var zio_runtime = try agent.ToolRuntime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var tool = try initTestTool(tmp.dir, ".", .{});
    defer tool.deinit();

    const oversized = try std.testing.allocator.alloc(u8, max_command_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');

    try std.testing.expectError(error.InvalidToolArguments, executeTestCommand(zio_runtime, &tool, oversized));
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
    var zio_runtime = try agent.ToolRuntime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    const io = zio_runtime.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var tool = try initTestTool(tmp.dir, ".", .{});
    defer tool.deinit();

    var object: std.json.ObjectMap = .empty;
    defer object.deinit(std.testing.allocator);
    try putCommand(&object, "sleep 60");

    var cancel_source = try runtime.CancelSource.init(std.testing.allocator);
    defer cancel_source.deinit();
    var future = try zio_runtime.spawn(execute, .{
        std.testing.allocator,
        io,
        zio_runtime,
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
}) !BashTool {
    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try dir.realPathFile(std.testing.io, sub_path, &cwd_buffer);
    return BashTool.init(std.testing.allocator, .{
        .cwd = cwd_buffer[0..cwd_len],
        .timeout_ms = config.timeout_ms orelse default_timeout_ms,
        .max_stdout_bytes = config.max_stdout_bytes orelse max_stdout_bytes,
    });
}

fn putCommand(object: *std.json.ObjectMap, command: []const u8) !void {
    try object.put(std.testing.allocator, "command", .{ .string = command });
}

fn executeTestCommand(
    zio_runtime: *agent.ToolRuntime,
    tool: *BashTool,
    command: []const u8,
) !agent.ToolExecutionResult {
    var object: std.json.ObjectMap = .empty;
    defer object.deinit(std.testing.allocator);
    try putCommand(&object, command);

    var cancel_source = try runtime.CancelSource.init(std.testing.allocator);
    defer cancel_source.deinit();
    return execute(std.testing.allocator, zio_runtime.io(), zio_runtime, tool, cancel_source.token(), "call", .{
        .object = object,
    }, null);
}
