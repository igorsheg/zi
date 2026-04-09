const std = @import("std");
const agent = @import("../agent/root.zig");

/// Bash tool — executes shell commands via /bin/sh -c.
/// pi-mono equivalent: packages/coding-agent/src/core/tools/bash/

const bash_schema =
    \\{"type":"object","properties":{"command":{"type":"string","description":"The bash command to execute"}},"required":["command"]}
;

pub fn makeTool() agent.protocol.AgentTool {
    return .{
        .name = "Bash",
        .description = "Execute a bash command on the system. Use for running shell commands, scripts, or system operations.",
        .label = "bash",
        .parameters = parseSchema(),
        .execute = &execute,
    };
}

fn parseSchema() std.json.Value {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        std.heap.page_allocator,
        bash_schema,
        .{ .allocate = .alloc_if_needed },
    ) catch return .null;
    return parsed.value;
}

const max_output_bytes = 1024 * 1024;

fn execute(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    args: std.json.Value,
    signal: agent.protocol.AbortSignal,
    _: ?agent.protocol.AgentToolUpdateCallback,
    _: ?*anyopaque,
) agent.protocol.AgentToolResult {
    const command = extractCommand(args) orelse {
        return errorResult(allocator, "missing 'command' argument");
    };

    const argv: []const []const u8 = &.{ "/bin/sh", "-c", command };
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch |err| {
        return errorResult(allocator, std.fmt.allocPrint(
            allocator,
            "failed to execute command: {s}",
            .{@errorName(err)},
        ) catch "failed to execute command");
    };

    var watchdog_done = std.atomic.Value(bool).init(false);
    var watchdog_thread: ?std.Thread = null;
    if (!signal.isNone()) {
        const ctx = WatchdogCtx{
            .signal = signal.flag,
            .child_id = child.id,
            .done = &watchdog_done,
        };
        watchdog_thread = std.Thread.spawn(.{}, abortWatchdog, .{ctx}) catch null;
    }

    var stderr_result: ?[]u8 = null;
    var stderr_thread: ?std.Thread = null;
    if (child.stderr) |stderr_file| {
        stderr_thread = std.Thread.spawn(.{}, readStderr, .{ stderr_file, allocator, &stderr_result }) catch null;
    }

    const stdout_data = if (child.stdout) |stdout_file|
        stdout_file.readToEndAlloc(allocator, max_output_bytes) catch null
    else
        null;

    if (stderr_thread) |t| t.join();

    watchdog_done.store(true, .release);
    if (watchdog_thread) |t| t.join();

    const term = child.wait() catch null;

    const is_error = if (term) |t| switch (t) {
        .Exited => |code| code != 0,
        else => true,
    } else true;

    var output_parts: std.ArrayListUnmanaged(u8) = .empty;
    if (stdout_data) |data| {
        if (data.len > 0) output_parts.appendSlice(allocator, data) catch {};
    }
    if (stderr_result) |data| {
        if (data.len > 0) {
            if (output_parts.items.len > 0) output_parts.appendSlice(allocator, "\n") catch {};
            output_parts.appendSlice(allocator, data) catch {};
        }
    }

    if (output_parts.items.len == 0 and is_error) {
        const exit_code: u32 = if (term) |t| switch (t) {
            .Exited => |code| code,
            .Signal => |sig| @as(u32, @intCast(sig)) + 128,
            else => 1,
        } else 1;
        output_parts.appendSlice(allocator, std.fmt.allocPrint(
            allocator,
            "command exited with code {d}",
            .{exit_code},
        ) catch "command failed") catch {};
    }

    const text_content = allocator.alloc(agent.protocol.AgentToolResult.ContentBlock, 1) catch {
        return errorResult(allocator, "allocation failed");
    };
    text_content[0] = .{ .text = .{ .text = output_parts.items } };

    return .{
        .content = text_content,
        .is_error = is_error,
    };
}

fn readStderr(stderr_file: std.fs.File, alloc: std.mem.Allocator, result: *?[]u8) void {
    result.* = stderr_file.readToEndAlloc(alloc, max_output_bytes) catch null;
}

const WatchdogCtx = struct {
    signal: *const std.atomic.Value(bool),
    child_id: std.process.Child.Id,
    done: *std.atomic.Value(bool),
};

fn abortWatchdog(ctx: WatchdogCtx) void {
    while (true) {
        if (ctx.done.load(.acquire)) return;
        if (ctx.signal.load(.acquire)) break;
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }
    if (ctx.done.load(.acquire)) return;

    // Kill the child first — this causes its stdout to hit EOF,
    // unblocking the parent's readToEndAlloc. close() on a pipe fd
    // is racy (double-close hazard with the reader thread), but
    // SIGKILL is safe and sufficient: the child dies, its pipe
    // endpoints close, and the blocking read returns.
    std.posix.kill(ctx.child_id, std.posix.SIG.KILL) catch {};
}

fn extractCommand(args: std.json.Value) ?[]const u8 {
    switch (args) {
        .object => |obj| {
            if (obj.get("command")) |cmd| {
                switch (cmd) {
                    .string => |s| return s,
                    else => return null,
                }
            }
            return null;
        },
        else => return null,
    }
}

fn errorResult(allocator: std.mem.Allocator, msg: []const u8) agent.protocol.AgentToolResult {
    const content = allocator.alloc(agent.protocol.AgentToolResult.ContentBlock, 1) catch {
        return .{ .content = &.{} };
    };
    content[0] = .{ .text = .{ .text = msg } };
    return .{ .content = content };
}
