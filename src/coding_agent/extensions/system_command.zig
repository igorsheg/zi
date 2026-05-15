const std = @import("std");
const zio = @import("../../zio/root.zig");
const process = zio.process;

pub const default_max_output_bytes: usize = process.default_max_output_bytes;
pub const EnvPair = process.EnvPair;

pub const Stdio = enum { capture, terminal };

pub const Request = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    stdin: ?[]const u8 = null,
    env: []const EnvPair = &.{},
    clear_env: bool = false,
    timeout_ms: ?u64 = null,
    max_stdout_bytes: usize = default_max_output_bytes,
    max_stderr_bytes: usize = default_max_output_bytes,
    text: bool = true,
    stdio: Stdio = .capture,
    signal: zio.cancel.Token = zio.cancel.Token.none,
};

pub const Completed = struct {
    code: ?u32 = null,
    signal: ?u32 = null,
    stdout: []const u8,
    stderr: []const u8,
};

pub const TimedOut = struct {
    stdout: []const u8,
    stderr: []const u8,
    message: []const u8,
};

pub const Failed = struct {
    message: []const u8,
    stdout: []const u8 = &.{},
    stderr: []const u8 = &.{},
};

pub const Result = union(enum) {
    completed: Completed,
    timeout: TimedOut,
    err: Failed,

    pub fn clone(self: Result, allocator: std.mem.Allocator) !Result {
        return switch (self) {
            .completed => |completed| .{ .completed = .{
                .code = completed.code,
                .signal = completed.signal,
                .stdout = try allocator.dupe(u8, completed.stdout),
                .stderr = try allocator.dupe(u8, completed.stderr),
            } },
            .timeout => |timeout| .{ .timeout = .{
                .stdout = try allocator.dupe(u8, timeout.stdout),
                .stderr = try allocator.dupe(u8, timeout.stderr),
                .message = try allocator.dupe(u8, timeout.message),
            } },
            .err => |err| .{ .err = .{
                .message = try allocator.dupe(u8, err.message),
                .stdout = try allocator.dupe(u8, err.stdout),
                .stderr = try allocator.dupe(u8, err.stderr),
            } },
        };
    }

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .completed => |completed| {
                allocator.free(completed.stdout);
                allocator.free(completed.stderr);
            },
            .timeout => |timeout| {
                allocator.free(timeout.stdout);
                allocator.free(timeout.stderr);
                allocator.free(timeout.message);
            },
            .err => |err| {
                allocator.free(err.message);
                if (err.stdout.len > 0) allocator.free(err.stdout);
                if (err.stderr.len > 0) allocator.free(err.stderr);
            },
        }
        self.* = undefined;
    }
};

pub fn run(allocator: std.mem.Allocator, io: std.Io, request: Request) Result {
    if (request.stdio == .terminal) {
        if (request.stdin != null) return errorResult(allocator, "stdin is invalid with terminal stdio");
        if (request.timeout_ms != null) return errorResult(allocator, "timeout_ms is unsupported with terminal stdio");
        return runTerminal(allocator, io, request);
    }
    var proc_result = process.run(allocator, io, .{
        .argv = request.argv,
        .cwd = if (request.cwd) |cwd| .{ .path = cwd } else .inherit,
        .stdin = if (request.stdin) |bytes| .{ .bytes = bytes } else .ignore,
        .env = request.env,
        .clear_env = request.clear_env,
        .timeout_ms = request.timeout_ms,
        .stdout_limit = .limited(request.max_stdout_bytes),
        .stderr_limit = .limited(request.max_stderr_bytes),
        .kill_scope = .process_group,
        .signal = request.signal,
    }) catch |err| return errorResult(allocator, @errorName(err));
    defer proc_result.deinit(allocator);

    return switch (proc_result) {
        .completed => |completed| completedResult(allocator, completed, request.text),
        .timed_out => |timeout| timeoutResult(allocator, timeout, request.text),
        .stdout_too_long, .stderr_too_long, .output_dropped, .aborted => |err| partialErrorResult(allocator, err, request.text),
    };
}

fn runTerminal(allocator: std.mem.Allocator, io: std.Io, request: Request) Result {
    const term = process.runInherit(io, .{
        .argv = request.argv,
        .cwd = if (request.cwd) |cwd| .{ .path = cwd } else .inherit,
        .env = request.env,
        .clear_env = request.clear_env,
        .kill_scope = .child,
        .signal = request.signal,
    }) catch |err| return errorResult(allocator, @errorName(err));
    return completedResult(allocator, .{
        .term = term,
        .stdout = .{ .bytes = @constCast(&.{}), .total_bytes = 0, .truncated = false },
        .stderr = .{ .bytes = @constCast(&.{}), .total_bytes = 0, .truncated = false },
    }, request.text);
}

fn completedResult(allocator: std.mem.Allocator, completed: process.Completed, text: bool) Result {
    const stdout = cloneOutput(allocator, completed.stdout.bytes, text) catch return errorResult(allocator, "failed to allocate stdout");
    errdefer allocator.free(stdout);
    const stderr = cloneOutput(allocator, completed.stderr.bytes, text) catch return errorResult(allocator, "failed to allocate stderr");
    return .{ .completed = .{
        .code = switch (completed.term) {
            .exited => |code| code,
            else => null,
        },
        .signal = switch (completed.term) {
            .signal => |sig| @intFromEnum(sig),
            .stopped => |sig| @intFromEnum(sig),
            .unknown => |sig| sig,
            else => null,
        },
        .stdout = stdout,
        .stderr = stderr,
    } };
}

fn timeoutResult(allocator: std.mem.Allocator, timeout: process.Partial, text: bool) Result {
    const stdout = cloneOutput(allocator, timeout.stdout.bytes, text) catch return errorResult(allocator, "failed to allocate stdout");
    errdefer allocator.free(stdout);
    const stderr = cloneOutput(allocator, timeout.stderr.bytes, text) catch return errorResult(allocator, "failed to allocate stderr");
    errdefer allocator.free(stderr);
    const message = allocator.dupe(u8, timeout.message) catch return errorResult(allocator, "timed out");
    return .{ .timeout = .{ .stdout = stdout, .stderr = stderr, .message = message } };
}

fn partialErrorResult(allocator: std.mem.Allocator, failed: process.Partial, text: bool) Result {
    const stdout = cloneOutput(allocator, failed.stdout.bytes, text) catch return errorResult(allocator, "failed to allocate stdout");
    errdefer allocator.free(stdout);
    const stderr = cloneOutput(allocator, failed.stderr.bytes, text) catch return errorResult(allocator, "failed to allocate stderr");
    errdefer allocator.free(stderr);
    const message = allocator.dupe(u8, failed.message) catch return errorResult(allocator, "process failed");
    return .{ .err = .{ .message = message, .stdout = stdout, .stderr = stderr } };
}

fn cloneOutput(allocator: std.mem.Allocator, bytes: []const u8, text: bool) ![]u8 {
    if (!text) return allocator.dupe(u8, bytes);
    return normalizeText(allocator, bytes);
}

fn normalizeText(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] == '\r' and i + 1 < bytes.len and bytes[i + 1] == '\n') {
            try out.append(allocator, '\n');
            i += 1;
        } else {
            try out.append(allocator, bytes[i]);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn errorResult(allocator: std.mem.Allocator, msg: []const u8) Result {
    return .{ .err = .{ .message = allocator.dupe(u8, msg) catch &.{} } };
}

test "system command runs argv and captures stdout" {
    const allocator = std.testing.allocator;
    var result = run(allocator, std.Options.debug_io, .{ .argv = &.{ "/bin/sh", "-c", "printf hello" } });
    defer result.deinit(allocator);
    try std.testing.expect(result == .completed);
    try std.testing.expectEqual(@as(?u32, 0), result.completed.code);
    try std.testing.expectEqualStrings("hello", result.completed.stdout);
    try std.testing.expectEqualStrings("", result.completed.stderr);
}

test "system command passes cwd env and stdin" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(cwd);

    var result = run(allocator, std.Options.debug_io, .{
        .argv = &.{ "/bin/sh", "-c", "printf \"$FOO:\"; pwd; printf ':'; cat" },
        .cwd = cwd,
        .stdin = "input",
        .env = &.{.{ .key = "FOO", .value = "bar" }},
    });
    defer result.deinit(allocator);
    try std.testing.expect(result == .completed);
    const expected = try std.fmt.allocPrint(allocator, "bar:{s}\n:input", .{cwd});
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, result.completed.stdout);
}

test "system command reports nonzero exit as completed" {
    const allocator = std.testing.allocator;
    var result = run(allocator, std.Options.debug_io, .{ .argv = &.{ "/bin/sh", "-c", "printf nope >&2; exit 7" } });
    defer result.deinit(allocator);
    try std.testing.expect(result == .completed);
    try std.testing.expectEqual(@as(?u32, 7), result.completed.code);
    try std.testing.expectEqualStrings("nope", result.completed.stderr);
}

test "system command reports timeout with partial output" {
    const allocator = std.testing.allocator;
    var result = run(allocator, std.Options.debug_io, .{
        .argv = &.{ "/bin/sh", "-c", "printf start; sleep 2" },
        .timeout_ms = 100,
    });
    defer result.deinit(allocator);
    try std.testing.expect(result == .timeout);
    try std.testing.expect(std.mem.indexOf(u8, result.timeout.stdout, "start") != null);
}
