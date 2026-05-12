const std = @import("std");
const protocol = @import("../../agent/types.zig");
const json_util = @import("../../ai/json_util.zig");
const tool_def = @import("definition.zig");
const util = @import("util.zig");
const runtime_process = @import("../../zio/root.zig").process;

const MAX_CAPTURE_BYTES: usize = 50 * 1024;

const bash_schema =
    \\{"type":"object","properties":{"cmd":{"type":"string","description":"The shell command to execute."},"cwd":{"type":"string","description":"Working directory for the command (absolute path). Defaults to workspace root."},"timeout":{"type":"number","description":"Timeout in seconds."}},"required":["cmd"]}
;

const DESCRIPTION =
    "Executes the given shell command using bash.\n\n" ++
    "- Do NOT use interactive commands (REPLs, editors, password prompts)\n" ++
    "- Output is bounded to 50KB each for stdout and stderr\n" ++
    "- Environment variables and `cd` do not persist between commands; use the `cwd` parameter instead\n" ++
    "- Commands run in the workspace root by default; only use `cwd` when you need a different directory\n" ++
    "- Use focused commands and prefer dedicated tools for file reads and searches.";

pub fn definition(ctx: *util.BuiltinCtx) tool_def.ToolDefinition {
    return .{
        .name = "bash",
        .description = DESCRIPTION,
        .label = "Bash",
        .parameters = util.parseSchema(bash_schema),
        .prompt_snippet = "Execute bash commands",
        .impl = .{ .builtin = .{ .ctx = @ptrCast(ctx), .execute = &execute } },
        .source = .{ .kind = "builtin", .id = "bash" },
    };
}

fn execute(
    raw_ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    tool_call_id: []const u8,
    args: std.json.Value,
    signal: protocol.Token,
    on_update: ?protocol.AgentToolUpdateCallback,
    update_ctx: ?*anyopaque,
) protocol.AgentToolExecution {
    _ = tool_call_id;
    _ = on_update;
    _ = update_ctx;
    return .{ .ready = executeSync(raw_ctx, allocator, args, signal) };
}

fn executeSync(
    raw_ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    args: std.json.Value,
    signal: protocol.Token,
) protocol.AgentToolResult {
    const ctx: *util.BuiltinCtx = @ptrCast(@alignCast(raw_ctx orelse
        return util.errorResult(allocator, "bash tool: missing context")));

    const command = util.getString(args, "cmd") orelse
        return util.errorResult(allocator, "bash tool: missing 'cmd' argument");

    const effective_cwd = blk: {
        const cwd_arg = util.getString(args, "cwd") orelse break :blk allocator.dupe(u8, ctx.cwd) catch
            return util.errorResult(allocator, "bash tool: alloc failed");
        break :blk util.resolvePath(allocator, cwd_arg, ctx.cwd) catch
            return util.errorResult(allocator, "bash tool: failed to resolve cwd");
    };
    defer allocator.free(effective_cwd);

    std.Io.Dir.accessAbsolute(ctx.io, effective_cwd, .{}) catch {
        return util.errorf(allocator, "working directory does not exist: {s}", .{effective_cwd});
    };

    return runCommand(allocator, ctx.io, command, effective_cwd, extractTimeout(args), signal);
}

fn runCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    command: []const u8,
    cwd: []const u8,
    timeout_secs: ?u64,
    signal: protocol.Token,
) protocol.AgentToolResult {
    const shell_argv: []const []const u8 = if (std.Io.Dir.accessAbsolute(io, "/bin/bash", .{}))
        &.{ "/bin/bash", "-c", command }
    else |_|
        &.{ "/bin/sh", "-c", command };

    var proc_result = runtime_process.run(allocator, io, .{
        .argv = shell_argv,
        .cwd = .{ .path = cwd },
        .timeout_ms = if (timeout_secs) |secs| secs * std.time.ms_per_s else null,
        .signal = signal,
        .stdout_limit = .limited(MAX_CAPTURE_BYTES),
        .stderr_limit = .limited(MAX_CAPTURE_BYTES),
    }) catch return util.errorResult(allocator, "command error: failed to run command");
    defer proc_result.deinit(allocator);

    const is_error, const tail = classifyResult(proc_result, signal, timeout_secs);
    const transcript = formatResult(allocator, command, proc_result, tail) catch
        return util.errorResult(allocator, "bash tool: alloc failed");

    return ownedUtf8TextResult(allocator, transcript, is_error);
}

fn classifyResult(result: runtime_process.RunResult, signal: protocol.Token, timeout_secs: ?u64) struct { bool, []const u8 } {
    if (signal.isAborted()) return .{ true, "command aborted" };

    return switch (result) {
        .completed => |completed| switch (completed.term) {
            .exited => |code| if (code == 0) .{ false, "" } else .{ true, "exit code" },
            else => .{ true, "command terminated" },
        },
        .timed_out => if (timeout_secs) |secs| blk: {
            _ = secs;
            break :blk .{ true, "command timed out" };
        } else .{ true, "command timed out" },
        .stdout_too_long => .{ true, "stdout exceeded output limit" },
        .stderr_too_long => .{ true, "stderr exceeded output limit" },
        .aborted => .{ true, "command aborted" },
    };
}

fn formatResult(
    allocator: std.mem.Allocator,
    command: []const u8,
    result: runtime_process.RunResult,
    tail: []const u8,
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "$ ");
    try out.appendSlice(allocator, command);
    try out.appendSlice(allocator, "\n\n");

    switch (result) {
        .completed => |completed| {
            try appendCaptured(allocator, &out, completed.stdout, completed.stderr);
            if (completed.term == .exited and completed.term.exited != 0) {
                const msg = try std.fmt.allocPrint(allocator, "\n\nexit code {d}", .{completed.term.exited});
                defer allocator.free(msg);
                try out.appendSlice(allocator, msg);
            } else if (completed.term != .exited) {
                try out.appendSlice(allocator, "\n\ncommand terminated");
            }
        },
        .timed_out, .stdout_too_long, .stderr_too_long, .aborted => |partial| {
            try appendCaptured(allocator, &out, partial.stdout, partial.stderr);
            if (partial.message.len > 0) {
                try out.appendSlice(allocator, "\n\n");
                try out.appendSlice(allocator, partial.message);
            } else if (tail.len > 0) {
                try out.appendSlice(allocator, "\n\n");
                try out.appendSlice(allocator, tail);
            }
        },
    }

    return out.toOwnedSlice(allocator);
}

fn appendCaptured(allocator: std.mem.Allocator, out: *std.ArrayList(u8), stdout: []const u8, stderr: []const u8) !void {
    if (stdout.len == 0 and stderr.len == 0) {
        try out.appendSlice(allocator, "(no output)");
        return;
    }

    if (stdout.len > 0) {
        try out.appendSlice(allocator, stdout);
        if (stderr.len > 0 and stdout[stdout.len - 1] != '\n') try out.append(allocator, '\n');
    }
    if (stderr.len > 0) {
        if (stdout.len > 0) try out.appendSlice(allocator, "\n[stderr]\n");
        try out.appendSlice(allocator, stderr);
    }
}

fn ownedUtf8TextResult(allocator: std.mem.Allocator, owned_text: []u8, is_error: bool) protocol.AgentToolResult {
    const utf8_text_const = json_util.utf8LossyAlloc(allocator, owned_text) catch owned_text;
    const utf8_text: []u8 = @constCast(utf8_text_const);
    if (utf8_text.ptr != owned_text.ptr) allocator.free(owned_text);
    return util.ownedTextResult(allocator, utf8_text, is_error);
}

fn extractTimeout(args: std.json.Value) ?u64 {
    switch (args) {
        .object => |obj| {
            if (obj.get("timeout")) |value| switch (value) {
                .integer => |i| if (i > 0) return @intCast(i),
                .float => |f| if (f >= 1) return @intFromFloat(@floor(f)),
                else => {},
            };
            return null;
        },
        else => return null,
    }
}

fn expectTextBlockContains(result: protocol.AgentToolResult, needle_text: []const u8) !void {
    try std.testing.expectEqual(@as(usize, 1), result.content.len);
    try std.testing.expect(result.content[0] == .text);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, needle_text) != null);
}

test "runCommand returns stdout and stderr" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = runCommand(
        arena.allocator(),
        std.Options.debug_io,
        "printf out; printf err 1>&2",
        "/tmp",
        5,
        protocol.Token.none,
    );

    try std.testing.expect(!result.is_error);
    try expectTextBlockContains(result, "out");
    try expectTextBlockContains(result, "err");
}

test "runCommand exits naturally before timeout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const start = std.Io.Timestamp.now(std.Options.debug_io, .awake).toMilliseconds();
    const result = runCommand(
        arena.allocator(),
        std.Options.debug_io,
        "sleep 0.1; printf done",
        "/tmp",
        5,
        protocol.Token.none,
    );
    const elapsed = std.Io.Timestamp.now(std.Options.debug_io, .awake).toMilliseconds() - start;

    try std.testing.expect(!result.is_error);
    try std.testing.expect(elapsed < 1000);
    try expectTextBlockContains(result, "done");
}

test "runCommand true returns immediately before long timeout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const start = std.Io.Timestamp.now(std.Options.debug_io, .awake).toMilliseconds();
    const result = runCommand(
        arena.allocator(),
        std.Options.debug_io,
        "true",
        "/tmp",
        10,
        protocol.Token.none,
    );
    const elapsed = std.Io.Timestamp.now(std.Options.debug_io, .awake).toMilliseconds() - start;

    try std.testing.expect(!result.is_error);
    try std.testing.expect(elapsed < 500);
}

test "runCommand reports timeout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = runCommand(
        arena.allocator(),
        std.Options.debug_io,
        "sleep 2",
        "/tmp",
        1,
        protocol.Token.none,
    );

    try std.testing.expect(result.is_error);
    try expectTextBlockContains(result, "timed out");
}
