const std = @import("std");
const agent_mod = @import("../../agent/root.zig");
const json_value = @import("../../json/value.zig");
const process_executor = @import("../../runtime/process_executor.zig");

pub const Config = struct {
    allocator: std.mem.Allocator,
    parameters: json_value.OwnedValue,
    io: std.Io,
    cwd: ?[]const u8 = null,
    shell: []const u8 = "/bin/bash",
    timeout_ms: u64 = 30_000,
    max_stdout_bytes: usize = 64 * 1024,
    max_stderr_bytes: usize = 64 * 1024,
    kill_scope: process_executor.KillScope = .process,

    pub const Options = struct {
        io: std.Io,
        cwd: ?[]const u8 = null,
        shell: []const u8 = "/bin/bash",
        timeout_ms: u64 = 30_000,
        max_stdout_bytes: usize = 64 * 1024,
        max_stderr_bytes: usize = 64 * 1024,
        kill_scope: process_executor.KillScope = .process,
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) !Config {
        const shell = try allocator.dupe(u8, options.shell);
        errdefer allocator.free(shell);
        const cwd = if (options.cwd) |cwd_value| try allocator.dupe(u8, cwd_value) else null;
        errdefer if (cwd) |cwd_value| allocator.free(cwd_value);
        const parameters = try parametersSchema(allocator);
        errdefer {
            var mutable = parameters;
            mutable.deinit();
        }
        return .{
            .allocator = allocator,
            .parameters = parameters,
            .io = options.io,
            .cwd = cwd,
            .shell = shell,
            .timeout_ms = options.timeout_ms,
            .max_stdout_bytes = options.max_stdout_bytes,
            .max_stderr_bytes = options.max_stderr_bytes,
            .kill_scope = options.kill_scope,
        };
    }

    pub fn deinit(self: *Config) void {
        self.parameters.deinit();
        if (self.cwd) |cwd| self.allocator.free(cwd);
        self.allocator.free(self.shell);
        self.* = undefined;
    }
};

pub fn tool(config: *const Config) agent_mod.AgentTool {
    return .{
        .name = "bash",
        .description = "Run a non-interactive bash command with bounded output.",
        .parameters = config.parameters.borrowed(),
        .ctx = @constCast(config),
        .execute_fn = execute,
    };
}

fn execute(ctx: ?*anyopaque, allocator: std.mem.Allocator, inv: agent_mod.tool.ToolInvocation, sink: agent_mod.tool.ToolCompletionSink) void {
    const config: *const Config = @ptrCast(@alignCast(ctx.?));
    const cmd = parseCommand(inv.args) catch |err| {
        emitTerminal(allocator, inv, sink, .failed, true, @errorName(err));
        return;
    };

    const argv = [_][]const u8{ config.shell, "-lc", cmd };
    var capture = ProcessCapture{};
    defer capture.deinit();
    process_executor.SynchronousExecutor.run(allocator, config.io, .{
        .argv = &argv,
        .cwd = config.cwd,
        .stdout_limit = config.max_stdout_bytes,
        .stderr_limit = config.max_stderr_bytes,
        .timeout_ms = config.timeout_ms,
        .kill_scope = config.kill_scope,
    }, inv.signal, .{ .complete_fn = ProcessCapture.complete, .ctx = &capture });

    var completion = capture.take() orelse {
        emitTerminal(allocator, inv, sink, .failed, true, "process executor produced no completion");
        return;
    };
    defer completion.deinit();

    const terminal_kind: TerminalKind = switch (completion.status) {
        .cancelled => .aborted,
        .invalid_request, .spawn_failed, .timed_out, .output_limit_exceeded, .internal => .failed,
        .exited, .signaled, .stopped, .unknown => .completed,
    };
    const is_error = switch (completion.status) {
        .exited => |code| code != 0,
        .cancelled => false,
        .signaled, .stopped, .unknown, .invalid_request, .spawn_failed, .timed_out, .output_limit_exceeded, .internal => true,
    };
    const summary = formatCompletion(allocator, completion) catch {
        emitTerminal(allocator, inv, sink, .failed, true, "out of memory formatting command result");
        return;
    };
    emitOwnedTextTerminal(allocator, inv, sink, terminal_kind, is_error, summary);
}

const ProcessCapture = struct {
    completion: ?process_executor.OwnedCompletion = null,

    fn complete(completion: *process_executor.OwnedCompletion, ctx: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        std.debug.assert(self.completion == null);
        self.completion = completion.*;
        completion.* = undefined;
    }

    fn take(self: *@This()) ?process_executor.OwnedCompletion {
        const completion = self.completion;
        self.completion = null;
        return completion;
    }

    fn deinit(self: *@This()) void {
        if (self.completion) |*completion| completion.deinit();
        self.* = undefined;
    }
};

fn parseCommand(args: json_value.BorrowedValue) ![]const u8 {
    if (args != .object) return error.InvalidArguments;
    const value = args.object.get("cmd") orelse return error.MissingCommand;
    if (value != .string) return error.InvalidCommand;
    if (value.string.len == 0) return error.EmptyCommand;
    return value.string;
}

const TerminalKind = enum { completed, failed, aborted };

fn emitTerminal(
    allocator: std.mem.Allocator,
    inv: agent_mod.tool.ToolInvocation,
    sink: agent_mod.tool.ToolCompletionSink,
    kind: TerminalKind,
    is_error: bool,
    message: []const u8,
) void {
    const text = allocator.dupe(u8, message) catch @panic("OOM while recording bash tool result");
    emitOwnedTextTerminal(allocator, inv, sink, kind, is_error, text);
}

fn emitOwnedTextTerminal(
    allocator: std.mem.Allocator,
    inv: agent_mod.tool.ToolInvocation,
    sink: agent_mod.tool.ToolCompletionSink,
    kind: TerminalKind,
    is_error: bool,
    text: []u8,
) void {
    const content = allocator.alloc(agent_mod.tool.AgentToolResult.ContentBlock, 1) catch @panic("OOM while recording bash tool result content");
    content[0] = .{ .text = .{ .text = text } };
    const result = agent_mod.tool.AgentToolResult{ .content = content, .is_error = is_error };
    const terminal: agent_mod.tool.ToolTerminal = switch (kind) {
        .completed => .{ .completed = result },
        .failed => .{ .failed = result },
        .aborted => .{ .aborted = result },
    };
    var completion = agent_mod.tool.ToolCompletion{ .terminal = .{
        .op_id = inv.op_id,
        .source_index = inv.source_index,
        .tool_call_id = inv.tool_call_id,
        .tool_name = inv.tool_name,
        .terminal = terminal,
    } };
    sink.emit(&completion);
}

fn formatCompletion(allocator: std.mem.Allocator, completion: process_executor.OwnedCompletion) ![]u8 {
    const status = try formatStatus(allocator, completion.status);
    defer allocator.free(status);
    return std.fmt.allocPrint(allocator, "{s}\nstdout:\n{s}\nstderr:\n{s}", .{ status, completion.stdout.bytes, completion.stderr.bytes });
}

fn formatStatus(allocator: std.mem.Allocator, status: process_executor.OwnedCompletion.Status) ![]u8 {
    return switch (status) {
        .exited => |code| std.fmt.allocPrint(allocator, "exit code: {d}", .{code}),
        .signaled => |sig| std.fmt.allocPrint(allocator, "signal: {d}", .{sig}),
        .stopped => |sig| std.fmt.allocPrint(allocator, "stopped: {d}", .{sig}),
        .unknown => |code| std.fmt.allocPrint(allocator, "unknown: {d}", .{code}),
        .invalid_request => |message| std.fmt.allocPrint(allocator, "invalid request: {s}", .{message}),
        .spawn_failed => |message| std.fmt.allocPrint(allocator, "spawn failed: {s}", .{message}),
        .timed_out => allocator.dupe(u8, "timed out"),
        .cancelled => allocator.dupe(u8, "cancelled"),
        .output_limit_exceeded => |stream| std.fmt.allocPrint(allocator, "output limit exceeded: {s}", .{@tagName(stream)}),
        .internal => |message| std.fmt.allocPrint(allocator, "internal error: {s}", .{message}),
    };
}
fn parametersSchema(allocator: std.mem.Allocator) !json_value.OwnedValue {
    var root: std.json.ObjectMap = .{};
    errdefer freeObject(allocator, root);

    try putString(allocator, &root, "type", "object");
    try putBool(allocator, &root, "additionalProperties", false);

    var properties: std.json.ObjectMap = .{};
    errdefer freeObject(allocator, properties);
    var cmd: std.json.ObjectMap = .{};
    errdefer freeObject(allocator, cmd);
    try putString(allocator, &cmd, "type", "string");
    try putString(allocator, &cmd, "description", "Non-interactive bash command executed with fixed cwd, timeout, and output byte limits.");
    try putOwned(allocator, &properties, "cmd", .{ .object = cmd });
    cmd = .{};
    try putOwned(allocator, &root, "properties", .{ .object = properties });
    properties = .{};

    var required = try std.json.Array.initCapacity(allocator, 1);
    errdefer required.deinit();
    const cmd_name = try allocator.dupe(u8, "cmd");
    errdefer allocator.free(cmd_name);
    try required.append(.{ .string = cmd_name });
    try putOwned(allocator, &root, "required", .{ .array = required });

    return json_value.OwnedValue.adopt(allocator, .{ .object = root });
}

fn putString(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: []const u8) !void {
    const owned_value = try allocator.dupe(u8, value);
    errdefer allocator.free(owned_value);
    try putOwned(allocator, object, key, .{ .string = owned_value });
}

fn putBool(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: bool) !void {
    try putOwned(allocator, object, key, .{ .bool = value });
}

fn putOwned(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: std.json.Value) !void {
    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);
    try object.put(allocator, owned_key, value);
}

fn freeObject(allocator: std.mem.Allocator, object: std.json.ObjectMap) void {
    var mutable = object;
    var it = mutable.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        json_value.freeJsonValue(allocator, entry.value_ptr.*);
    }
    mutable.deinit(allocator);
}

const CompletionCapture = struct {
    terminal: ?agent_mod.tool.ToolTerminalCompletion = null,

    fn emit(completion: *agent_mod.tool.ToolCompletion, ctx: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        switch (completion.*) {
            .terminal => |terminal| self.terminal = terminal,
            .update => |update| update.deinit(std.testing.allocator),
        }
        completion.* = undefined;
    }

    fn deinit(self: *@This()) void {
        if (self.terminal) |terminal| terminal.deinit(std.testing.allocator);
        self.* = undefined;
    }
};

fn testInvocation(args: json_value.BorrowedValue) agent_mod.tool.ToolInvocation {
    return .{ .op_id = 1, .source_index = 0, .tool_call_id = "call-1", .tool_name = "bash", .args = args, .signal = .none };
}

fn commandArgs(allocator: std.mem.Allocator, cmd: []const u8) !std.json.Value {
    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "cmd", .{ .string = cmd });
    return .{ .object = obj };
}

test "bash tool exposes command argument schema" {
    var config = try Config.init(std.testing.allocator, .{ .io = std.testing.io });
    defer config.deinit();

    const params = tool(&config).parameters;
    try std.testing.expect(params == .object);
    try std.testing.expectEqualStrings("object", params.object.get("type").?.string);
    try std.testing.expectEqual(false, params.object.get("additionalProperties").?.bool);
    const properties = params.object.get("properties").?.object;
    try std.testing.expect(properties.get("cmd") != null);
    const required = params.object.get("required").?.array;
    try std.testing.expectEqual(@as(usize, 1), required.items.len);
    try std.testing.expectEqualStrings("cmd", required.items[0].string);
}

test "bash tool rejects invalid arguments" {
    var config = try Config.init(std.testing.allocator, .{ .io = std.testing.io });
    defer config.deinit();
    var capture = CompletionCapture{};
    defer capture.deinit();

    tool(&config).execute(std.testing.allocator, testInvocation(.null), .{ .emit_fn = CompletionCapture.emit, .ctx = &capture });

    try std.testing.expect(capture.terminal.?.terminal == .failed);
}

test "bash tool captures stdout for successful command" {
    var config = try Config.init(std.testing.allocator, .{ .io = std.testing.io, .timeout_ms = 5_000 });
    defer config.deinit();
    const args = try commandArgs(std.testing.allocator, "printf hello");
    defer {
        var obj = args.object;
        obj.deinit(std.testing.allocator);
    }
    var capture = CompletionCapture{};
    defer capture.deinit();

    tool(&config).execute(std.testing.allocator, testInvocation(args), .{ .emit_fn = CompletionCapture.emit, .ctx = &capture });

    const completed = capture.terminal.?.terminal.completed;
    try std.testing.expect(!completed.is_error);
    try std.testing.expect(std.mem.indexOf(u8, completed.content[0].text.text, "hello") != null);
}

test "bash tool marks nonzero exit as error result" {
    var config = try Config.init(std.testing.allocator, .{ .io = std.testing.io, .timeout_ms = 5_000 });
    defer config.deinit();
    const args = try commandArgs(std.testing.allocator, "exit 7");
    defer {
        var obj = args.object;
        obj.deinit(std.testing.allocator);
    }
    var capture = CompletionCapture{};
    defer capture.deinit();

    tool(&config).execute(std.testing.allocator, testInvocation(args), .{ .emit_fn = CompletionCapture.emit, .ctx = &capture });

    const completed = capture.terminal.?.terminal.completed;
    try std.testing.expect(completed.is_error);
    try std.testing.expect(std.mem.indexOf(u8, completed.content[0].text.text, "exit code: 7") != null);
}

test "bash tool reports pre-cancelled invocation as aborted" {
    var config = try Config.init(std.testing.allocator, .{ .io = std.testing.io });
    defer config.deinit();
    var source = @import("../../runtime/cancel.zig").Source{};
    const token = source.beginRun();
    source.requestAbort();
    const args = try commandArgs(std.testing.allocator, "printf nope");
    defer {
        var obj = args.object;
        obj.deinit(std.testing.allocator);
    }
    var inv = testInvocation(args);
    inv.signal = token;
    var capture = CompletionCapture{};
    defer capture.deinit();

    tool(&config).execute(std.testing.allocator, inv, .{ .emit_fn = CompletionCapture.emit, .ctx = &capture });

    const aborted = capture.terminal.?.terminal.aborted;
    try std.testing.expect(!aborted.is_error);
}

test "bash tool fails unsupported process group kill scope with baseline executor" {
    var config = try Config.init(std.testing.allocator, .{ .io = std.testing.io, .kill_scope = .process_group });
    defer config.deinit();
    const args = try commandArgs(std.testing.allocator, "printf nope");
    defer {
        var obj = args.object;
        obj.deinit(std.testing.allocator);
    }
    var capture = CompletionCapture{};
    defer capture.deinit();

    tool(&config).execute(std.testing.allocator, testInvocation(args), .{ .emit_fn = CompletionCapture.emit, .ctx = &capture });

    const failed = capture.terminal.?.terminal.failed;
    try std.testing.expect(failed.is_error);
    try std.testing.expect(std.mem.indexOf(u8, failed.content[0].text.text, "UnsupportedKillScope") != null);
}
