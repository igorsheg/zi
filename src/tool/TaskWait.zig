const std = @import("std");
const ToolContract = @import("Tool.zig");
const TaskRegistryModule = @import("TaskRegistry.zig");

const maximum_json_bytes: usize = 64 * 1024;

pub const TaskWait = struct {
    registry: *TaskRegistryModule.TaskRegistry,
    enabled: bool = true,

    pub fn tool(self: *TaskWait) ToolContract.Tool {
        return ToolContract.Tool.from(self, definition, .{
            .preview_mode = .head_tail,
            .format_argument = formatArgument,
        });
    }

    pub fn advertise(self: *TaskWait) ?*const ToolContract.Definition {
        return if (self.enabled) &definition else null;
    }

    pub fn run(
        allocator: std.mem.Allocator,
        _: std.Io,
        self: *TaskWait,
        args_json: ?[]const u8,
        run_context: ToolContract.RunContext,
    ) ToolContract.RunError!ToolContract.Result {
        if (!self.enabled) return resultCopy(allocator, "background tasks are disabled");
        const input = args_json orelse "{}";
        if (input.len > maximum_json_bytes)
            return resultCopy(allocator, "invalid arguments: input exceeds 65536 bytes");
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, input, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return resultFormat("invalid arguments: {s}", allocator, .{@errorName(err)}),
        };
        defer parsed.deinit();
        if (parsed.value != .object)
            return resultCopy(allocator, "missing 'id': name the task to wait on, e.g. \"t1\"");
        const id_value = parsed.value.object.get("id") orelse
            return resultCopy(allocator, "missing 'id': name the task to wait on, e.g. \"t1\"");
        if (id_value != .string or id_value.string.len == 0)
            return resultCopy(allocator, "missing 'id': name the task to wait on, e.g. \"t1\"");

        var kill = false;
        if (parsed.value.object.get("kill")) |value| {
            if (value != .bool) return resultCopy(allocator, "'kill' must be a boolean");
            kill = value.bool;
        }
        var timeout_ms: u64 = if (kill) 0 else self.registry.config.wait_timeout_ms;
        if (parsed.value.object.get("timeout_seconds")) |value| {
            if (value != .integer or value.integer < 0)
                return resultCopy(allocator, "'timeout_seconds' must be an integer >= 0");
            const seconds: u64 = @intCast(value.integer);
            timeout_ms = std.math.mul(u64, seconds, 1000) catch std.math.maxInt(u64);
        }
        const output = self.registry.wait(allocator, id_value.string, .{
            .timeout_ms = timeout_ms,
            .kill_on_timeout = kill,
            .display = run_context.display,
            .cancel = run_context.cancel,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidJob,
            error.CapacityReached,
            error.InvalidName,
            error.Reentrant,
            error.Busy,
            error.OutputUnavailable,
            => return error.InvalidResult,
        };
        return .{ .output = output };
    }
};

const parameters = [_]ToolContract.Parameter{
    .{
        .name = "id",
        .type = .string,
        .required = true,
        .description = "Task id to wait on (e.g. \"t1\").",
    },
    .{
        .name = "timeout_seconds",
        .type = .integer,
        .description = "How long to block waiting for the task to finish; 0 does not block. " ++
            "Defaults to a configured value (10 minutes unless changed); with `kill` it " ++
            "defaults to 0 (kill immediately).",
    },
    .{
        .name = "kill",
        .type = .boolean,
        .description = "Kill the task and report its final output. With `timeout_seconds`, the " ++
            "task first gets that window to finish on its own; the kill fires only if it is " ++
            "still running when the timeout elapses.",
    },
};

const definition: ToolContract.Definition = .{
    .name = "task_wait",
    .description = "Wait on one background task; returns the output it produced since you last saw it plus " ++
        "its status.\n\nReturns immediately for an already-finished task (this is also how you collect a task " ++
        "announced as finished), and returns early when a different task finishes so you can react " ++
        "to it. Wait on the task whose result you need next; do not poll in a loop of short waits.\n\n" ++
        "With `kill`, the task is stopped (SIGTERM, then SIGKILL after a grace period) and its " ++
        "final output is returned; add `timeout_seconds` to first give the task that long to " ++
        "finish on its own.",
    .parameters = &parameters,
};

/// Formats `t1`, `t1 (up to 30s)`, `t1 (kill)`, or `t1 (up to 30s, then kill)`.
/// Malformed arguments return an owned copy of the raw JSON through Tool display fallback.
fn formatArgument(allocator: std.mem.Allocator, args_json: ?[]const u8) error{OutOfMemory}![]u8 {
    const input = args_json orelse return allocator.dupe(u8, "");
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, input, .{}) catch
        return allocator.dupe(u8, input);
    defer parsed.deinit();
    if (parsed.value != .object) return allocator.dupe(u8, input);
    const id_value = parsed.value.object.get("id") orelse return allocator.dupe(u8, input);
    if (id_value != .string or id_value.string.len == 0) return allocator.dupe(u8, input);
    const kill_value = parsed.value.object.get("kill");
    const kill = kill_value != null and kill_value.? == .bool and kill_value.?.bool;
    const timeout = parsed.value.object.get("timeout_seconds");
    if (timeout != null and timeout.? == .integer and timeout.?.integer > 0) {
        const seconds: u64 = @intCast(timeout.?.integer);
        const duration: PreviewDuration = .{ .seconds = seconds };
        return if (kill)
            std.fmt.allocPrint(
                allocator,
                "{s} (up to {f}, then kill)",
                .{ id_value.string, duration },
            )
        else
            std.fmt.allocPrint(
                allocator,
                "{s} (up to {f})",
                .{ id_value.string, duration },
            );
    }
    if (kill) return std.fmt.allocPrint(allocator, "{s} (kill)", .{id_value.string});
    return allocator.dupe(u8, id_value.string);
}

pub const PreviewDuration = struct {
    seconds: u64,
    pub fn format(self: PreviewDuration, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.seconds < 60) return writer.print("{d}s", .{self.seconds});
        if (self.seconds < 3600 and self.seconds % 60 == 0)
            return writer.print("{d}m", .{self.seconds / 60});
        if (self.seconds < 3600)
            return writer.print("{d}m {d:0>2}s", .{ self.seconds / 60, self.seconds % 60 });
        if (self.seconds % 3600 == 0) return writer.print("{d}h", .{self.seconds / 3600});
        return writer.print("{d}h {d:0>2}m", .{ self.seconds / 3600, self.seconds % 3600 / 60 });
    }
};

fn resultCopy(allocator: std.mem.Allocator, text: []const u8) error{OutOfMemory}!ToolContract.Result {
    return .{ .output = try allocator.dupe(u8, text) };
}

// Allocator and comptime ordering rules conflict for this helper.
// ziglint-ignore: Z023
fn resultFormat(
    comptime format: []const u8,
    allocator: std.mem.Allocator, // ziglint-ignore: Z023
    args: anytype,
) error{OutOfMemory}!ToolContract.Result {
    return .{ .output = try std.fmt.allocPrint(allocator, format, args) };
}

test "display argument duration dialect is exact" {
    const cases = [_]struct { json: []const u8, expected: []const u8 }{
        .{ .json = "{\"id\":\"t1\",\"timeout_seconds\":90}", .expected = "t1 (up to 1m 30s)" },
        .{ .json = "{\"id\":\"t1\",\"timeout_seconds\":3600}", .expected = "t1 (up to 1h)" },
        .{ .json = "{\"id\":\"t1\",\"timeout_seconds\":90,\"kill\":true}", .expected = "t1 (up to 1m 30s, then kill)" },
        .{ .json = "{\"id\":\"t1\",\"kill\":true}", .expected = "t1 (kill)" },
    };
    for (cases) |case| {
        const output = try formatArgument(std.testing.allocator, case.json);
        defer std.testing.allocator.free(output);
        try std.testing.expectEqualStrings(case.expected, output);
    }
}
