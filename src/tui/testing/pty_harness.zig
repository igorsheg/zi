const std = @import("std");
const builtin = @import("builtin");
const Loop = @import("../Loop.zig");

pub const max_output_default: usize = 256 * 1024;

pub const Action = struct {
    after_ms: u64,
    bytes: []const u8,
};

pub const RunOptions = struct {
    argv: []const []const u8,
    env: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    rows: u16 = 30,
    cols: u16 = 100,
    timeout_ms: u64 = 5_000,
    max_output_bytes: usize = max_output_default,
};

pub const RunResult = struct {
    output: []u8,
    status: i32,
    timed_out: bool,
    termios_restored: ?bool,

    pub fn deinit(self: *RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
        self.* = undefined;
    }
};

pub fn runScripted(allocator: std.mem.Allocator, options: RunOptions, actions: []const Action) !RunResult {
    if (options.argv.len == 0) return error.EmptyArgv;
    if (!supportsForkPty()) return error.SkipZigTest;

    var argv = try CStringList.init(allocator, options.argv);
    defer argv.deinit(allocator);
    var env = try CStringList.init(allocator, options.env);
    defer env.deinit(allocator);
    const cwd_z = if (options.cwd) |cwd| try allocator.dupeZ(u8, cwd) else null;
    defer if (cwd_z) |value| allocator.free(value);

    var master: c_int = -1;
    var winsize: std.posix.winsize = .{
        .row = options.rows,
        .col = options.cols,
        .xpixel = 0,
        .ypixel = 0,
    };
    const pid = c_forkpty(&master, null, null, &winsize);
    if (pid < 0) return error.ForkPtyFailed;
    if (pid == 0) {
        if (cwd_z) |cwd| if (std.c.chdir(cwd.ptr) != 0) std.c._exit(126);
        _ = std.c.execve(argv.ptrs[0].?, @ptrCast(argv.ptrs.ptr), @ptrCast(env.ptrs.ptr));
        std.c._exit(127);
    }
    var termios_before: std.c.termios = undefined;
    const have_termios_before = std.c.tcgetattr(master, &termios_before) == 0;
    const child: std.c.pid_t = @intCast(pid);
    defer _ = std.c.close(master);

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    var next_action: usize = 0;
    const started = nowNs();
    var status: c_int = 0;
    var child_done = false;
    var timed_out = false;

    while (true) {
        const elapsed_ms = elapsedMs(started);
        while (next_action < actions.len and elapsed_ms >= actions[next_action].after_ms) : (next_action += 1) {
            try writeAll(master, actions[next_action].bytes);
        }

        drainReadable(master, allocator, &output, options.max_output_bytes) catch |err| switch (err) {
            error.EndOfStream => child_done = true,
            else => return err,
        };

        const waited = std.c.waitpid(child, &status, std.c.W.NOHANG);
        if (waited == child) child_done = true;
        if (child_done) break;
        if (elapsed_ms >= options.timeout_ms) {
            timed_out = true;
            _ = std.c.kill(child, std.c.SIG.TERM);
            break;
        }
        sleepMs(10);
    }

    if (timed_out) {
        const kill_started = nowNs();
        while (elapsedMs(kill_started) < 500) {
            const waited = std.c.waitpid(child, &status, std.c.W.NOHANG);
            if (waited == child) break;
            sleepMs(10);
        }
    }

    drainReadable(master, allocator, &output, options.max_output_bytes) catch |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    };
    return .{
        .output = try output.toOwnedSlice(allocator),
        .status = status,
        .timed_out = timed_out,
        .termios_restored = termiosRestored(master, &termios_before, have_termios_before),
    };
}

fn supportsForkPty() bool {
    return switch (builtin.os.tag) {
        .macos, .linux => true,
        else => false,
    };
}

const CStringList = struct {
    values: [][:0]u8,
    ptrs: []?[*:0]const u8,

    fn init(allocator: std.mem.Allocator, values: []const []const u8) !CStringList {
        const owned = try allocator.alloc([:0]u8, values.len);
        errdefer allocator.free(owned);
        var initialized: usize = 0;
        errdefer for (owned[0..initialized]) |value| allocator.free(value);
        const ptrs = try allocator.alloc(?[*:0]const u8, values.len + 1);
        errdefer allocator.free(ptrs);
        for (values, 0..) |value, index| {
            owned[index] = try allocator.dupeZ(u8, value);
            ptrs[index] = owned[index].ptr;
            initialized += 1;
        }
        ptrs[values.len] = null;
        return .{ .values = owned, .ptrs = ptrs };
    }

    fn deinit(self: *CStringList, allocator: std.mem.Allocator) void {
        for (self.values) |value| allocator.free(value);
        allocator.free(self.values);
        allocator.free(self.ptrs);
        self.* = undefined;
    }
};

fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    const sec: u64 = if (ts.sec <= 0) 0 else @intCast(ts.sec);
    const nsec: u64 = if (ts.nsec <= 0) 0 else @intCast(ts.nsec);
    return sec * std.time.ns_per_s + nsec;
}

fn sleepMs(ms: u64) void {
    var request: std.c.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    while (std.c.nanosleep(&request, &request) != 0) {}
}

fn elapsedMs(started_ns: u64) u64 {
    return (nowNs() -| started_ns) / std.time.ns_per_ms;
}

fn writeAll(fd: c_int, bytes: []const u8) !void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const written = std.c.write(fd, remaining.ptr, remaining.len);
        if (written < 0) return error.WriteFailed;
        if (written == 0) return error.WriteFailed;
        remaining = remaining[@intCast(written)..];
    }
}

fn drainReadable(fd: c_int, allocator: std.mem.Allocator, output: *std.ArrayList(u8), max_output_bytes: usize) !void {
    var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    while (true) {
        const ready = std.posix.poll(&fds, 0) catch return error.PollFailed;
        if (ready == 0) return;
        if ((fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL)) != 0 and (fds[0].revents & std.posix.POLL.IN) == 0) return error.EndOfStream;
        var buffer: [4096]u8 = undefined;
        const read_count = std.c.read(fd, &buffer, buffer.len);
        if (read_count == 0) return error.EndOfStream;
        if (read_count < 0) return error.EndOfStream;
        const count: usize = @intCast(read_count);
        const room = max_output_bytes -| output.items.len;
        if (room > 0) try output.appendSlice(allocator, buffer[0..@min(room, count)]);
        if (count < buffer.len) return;
    }
}

fn termiosRestored(fd: c_int, before: *const std.c.termios, have_before: bool) ?bool {
    if (!have_before) return null;
    var after: std.c.termios = undefined;
    if (std.c.tcgetattr(fd, &after) != 0) return null;
    return std.mem.eql(u8, std.mem.asBytes(before), std.mem.asBytes(&after));
}

extern "c" fn forkpty(amaster: *c_int, name: ?[*:0]u8, termp: ?*const std.c.termios, winp: ?*const std.posix.winsize) c_int;

fn c_forkpty(amaster: *c_int, name: ?[*:0]u8, termp: ?*const std.c.termios, winp: ?*const std.posix.winsize) c_int {
    return forkpty(amaster, name, termp, winp);
}

fn envValue(name: [*:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.span(value);
}

fn tmpAbsPath(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir, rel_path: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..], rel_path });
}

fn exitedZero(status: i32) bool {
    if (status < 0) return false;
    const raw: u32 = @intCast(status);
    return std.c.W.IFEXITED(raw) and std.c.W.EXITSTATUS(raw) == 0;
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) != null) return;
    std.debug.print("missing pty output marker: {s}\n--- output ---\n{s}\n--- end output ---\n", .{ needle, haystack });
    return error.TestUnexpectedResult;
}

fn metricValue(report: []const u8, line_prefix: []const u8, key: []const u8) !u64 {
    var lines = std.mem.splitScalar(u8, report, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, line_prefix)) continue;
        const key_start = std.mem.indexOf(u8, line, key) orelse return error.MissingTraceMetric;
        const value_start = key_start + key.len;
        var value_end = value_start;
        while (value_end < line.len and std.ascii.isDigit(line[value_end])) : (value_end += 1) {}
        if (value_end == value_start) return error.MissingTraceMetric;
        return try std.fmt.parseInt(u64, line[value_start..value_end], 10);
    }
    return error.MissingTraceMetric;
}

fn readTrace(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, path, allocator, .limited(16 * 1024));
}

fn appendFloodTyping(actions: *std.ArrayList(Action), allocator: std.mem.Allocator, start_ms: u64, duration_ms: u64) !void {
    var elapsed_ms: u64 = 0;
    while (elapsed_ms < duration_ms) : (elapsed_ms += 33) {
        try actions.append(allocator, .{ .after_ms = start_ms + elapsed_ms, .bytes = "a" });
    }
}

fn expectP2FloodTrace(report: []const u8) !void {
    const input_count = try metricValue(report, "input_latency ", "count=");
    const input_p99_ns = try metricValue(report, "input_latency ", "p99_ns=");
    const max_frame_us = try metricValue(report, "frames ", "max_total_us=");
    const dropped = try metricValue(report, "dropped_input_bytes ", "count=");
    if (input_count < 100 or input_p99_ns >= Loop.frame_floor_ns or max_frame_us > Loop.watchdog_budget_ns / std.time.ns_per_us or dropped != 0) {
        std.debug.print("P2 flood trace gate failed\n{s}\n", .{report});
        return error.TestUnexpectedResult;
    }
}

test "pty e2e: streamed markdown renders, escape aborts, and ctrl-c exits" {
    if (!supportsForkPty()) return error.SkipZigTest;
    const zi_bin = envValue("ZI_PTY_E2E_BIN") orelse return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "repo/.zi");
    try tmp.dir.createDirPath(std.testing.io, "home");
    try tmp.dir.createDirPath(std.testing.io, "agent");

    var script = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer script.deinit();
    try script.writer.writeAll("# streamed markdown\n\n");
    for (0..200) |index| try script.writer.print("- pty abort line {d}\n", .{index});
    try script.writer.writeAll("\n# streamed-markdown-tail\n");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "script.md", .data = script.written() });

    const repo_abs = try tmpAbsPath(std.testing.allocator, &tmp, "repo");
    defer std.testing.allocator.free(repo_abs);
    const home_abs = try tmpAbsPath(std.testing.allocator, &tmp, "home");
    defer std.testing.allocator.free(home_abs);
    const agent_abs = try tmpAbsPath(std.testing.allocator, &tmp, "agent");
    defer std.testing.allocator.free(agent_abs);
    const script_abs = try tmpAbsPath(std.testing.allocator, &tmp, "script.md");
    defer std.testing.allocator.free(script_abs);

    const home_env = try std.fmt.allocPrint(std.testing.allocator, "HOME={s}", .{home_abs});
    defer std.testing.allocator.free(home_env);
    const agent_env = try std.fmt.allocPrint(std.testing.allocator, "ZI_CODING_AGENT_DIR={s}", .{agent_abs});
    defer std.testing.allocator.free(agent_env);
    const script_env = try std.fmt.allocPrint(std.testing.allocator, "ZI_FAUX_SCRIPT={s}", .{script_abs});
    defer std.testing.allocator.free(script_env);

    const stream_env = [_][]const u8{
        "TERM=xterm-256color",
        "NO_COLOR=1",
        "ZI_ENABLE_FAUX_PROVIDER=1",
        "ZI_FAUX_DELAY_MS=0",
        home_env,
        agent_env,
        script_env,
    };
    var streamed = try runScripted(std.testing.allocator, .{
        .argv = &.{ zi_bin, "pty prompt" },
        .env = &stream_env,
        .cwd = repo_abs,
        .rows = 24,
        .cols = 100,
        .timeout_ms = 8_000,
    }, &.{
        .{ .after_ms = 1_000, .bytes = "\r" },
        .{ .after_ms = 2_500, .bytes = "\x03" },
        .{ .after_ms = 2_700, .bytes = "\x03" },
    });
    defer streamed.deinit(std.testing.allocator);

    if (streamed.timed_out) {
        std.debug.print("pty stream e2e timed out\n--- output ---\n{s}\n--- end output ---\n", .{streamed.output});
        return error.TestUnexpectedResult;
    }
    try std.testing.expect(exitedZero(streamed.status));
    try std.testing.expect(streamed.termios_restored != false);
    try expectContains(streamed.output, "streamed-markdown-tail");

    const abort_env = [_][]const u8{
        "TERM=xterm-256color",
        "NO_COLOR=1",
        "ZI_ENABLE_FAUX_PROVIDER=1",
        "ZI_FAUX_DELAY_MS=50",
        home_env,
        agent_env,
        script_env,
    };
    var aborted = try runScripted(std.testing.allocator, .{
        .argv = &.{ zi_bin, "pty prompt" },
        .env = &abort_env,
        .cwd = repo_abs,
        .rows = 24,
        .cols = 100,
        .timeout_ms = 8_000,
    }, &.{
        .{ .after_ms = 1_000, .bytes = "\r" },
        .{ .after_ms = 1_500, .bytes = "\x1b" },
        .{ .after_ms = 3_500, .bytes = "\x03" },
        .{ .after_ms = 3_700, .bytes = "\x03" },
    });
    defer aborted.deinit(std.testing.allocator);

    if (aborted.timed_out) {
        std.debug.print("pty abort e2e timed out\n--- output ---\n{s}\n--- end output ---\n", .{aborted.output});
        return error.TestUnexpectedResult;
    }
    try std.testing.expect(exitedZero(aborted.status));
    try std.testing.expect(aborted.termios_restored != false);
    try expectContains(aborted.output, "aborted");
}

test "pty e2e: synthetic flood trace meets P2 gate three times" {
    if (!supportsForkPty()) return error.SkipZigTest;
    const zi_bin = envValue("ZI_PTY_E2E_BIN") orelse return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "repo/.zi");
    try tmp.dir.createDirPath(std.testing.io, "home");
    try tmp.dir.createDirPath(std.testing.io, "agent");

    const repo_abs = try tmpAbsPath(std.testing.allocator, &tmp, "repo");
    defer std.testing.allocator.free(repo_abs);
    const home_abs = try tmpAbsPath(std.testing.allocator, &tmp, "home");
    defer std.testing.allocator.free(home_abs);
    const agent_abs = try tmpAbsPath(std.testing.allocator, &tmp, "agent");
    defer std.testing.allocator.free(agent_abs);

    const home_env = try std.fmt.allocPrint(std.testing.allocator, "HOME={s}", .{home_abs});
    defer std.testing.allocator.free(home_env);
    const agent_env = try std.fmt.allocPrint(std.testing.allocator, "ZI_CODING_AGENT_DIR={s}", .{agent_abs});
    defer std.testing.allocator.free(agent_env);

    for (0..3) |run_index| {
        var trace_name_buffer: [32]u8 = undefined;
        const trace_name = try std.fmt.bufPrint(&trace_name_buffer, "trace-{d}.log", .{run_index});
        const trace_abs = try tmpAbsPath(std.testing.allocator, &tmp, trace_name);
        defer std.testing.allocator.free(trace_abs);
        const trace_env = try std.fmt.allocPrint(std.testing.allocator, "ZI_TUI_TRACE_FILE={s}", .{trace_abs});
        defer std.testing.allocator.free(trace_env);

        const env = [_][]const u8{
            "TERM=xterm-256color",
            "NO_COLOR=1",
            "ZI_TUI_SYNTHETIC_FLOOD=1",
            home_env,
            agent_env,
            trace_env,
        };
        var actions = std.ArrayList(Action).empty;
        defer actions.deinit(std.testing.allocator);
        try appendFloodTyping(&actions, std.testing.allocator, 1_000, Loop.synthetic_flood_duration_ns / std.time.ns_per_ms);
        try actions.append(std.testing.allocator, .{ .after_ms = 31_500, .bytes = "\x03" });
        try actions.append(std.testing.allocator, .{ .after_ms = 31_700, .bytes = "\x03" });

        var result = try runScripted(std.testing.allocator, .{
            .argv = &.{zi_bin},
            .env = &env,
            .cwd = repo_abs,
            .rows = 24,
            .cols = 100,
            .timeout_ms = 38_000,
            .max_output_bytes = 512 * 1024,
        }, actions.items);
        defer result.deinit(std.testing.allocator);

        if (result.timed_out) {
            std.debug.print("pty flood e2e timed out on run {d}\n--- output ---\n{s}\n--- end output ---\n", .{ run_index, result.output });
            return error.TestUnexpectedResult;
        }
        try std.testing.expect(exitedZero(result.status));
        try std.testing.expect(result.termios_restored != false);

        const report = try readTrace(std.testing.allocator, trace_abs);
        defer std.testing.allocator.free(report);
        try expectP2FloodTrace(report);
    }
}
test "pty harness runs a simple child and captures output" {
    if (!supportsForkPty()) return error.SkipZigTest;
    var result = try runScripted(std.testing.allocator, .{
        .argv = &.{ "/bin/sh", "-c", "printf ready; read line; printf -- \"-$line-\"" },
        .timeout_ms = 2_000,
    }, &.{.{ .after_ms = 50, .bytes = "ok\n" }});
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.timed_out);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "ready") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "-ok-") != null);
}
