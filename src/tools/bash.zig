const std = @import("std");
const agent = @import("../agent/root.zig");
const json_util = @import("../ai/json_util.zig");
const tool_def = @import("definition.zig");
const util = @import("util.zig");
const AbortGuard = @import("../abort_guard.zig").AbortGuard;
const lock_registry = @import("../agent/lock_registry.zig");

const HEAD_LINES: usize = 50;
const TAIL_LINES: usize = 50;
const MAX_OUTPUT_BYTES: usize = 1024 * 1024;

const bash_schema =
    \\{"type":"object","properties":{"cmd":{"type":"string","description":"The shell command to execute."},"cwd":{"type":"string","description":"Working directory for the command (absolute path). Defaults to workspace root."},"timeout":{"type":"number","description":"Timeout in seconds."}},"required":["cmd"]}
;

const DESCRIPTION =
    "Executes the given shell command using bash.\n\n" ++
    "- Do NOT chain commands with `;` or `&&` or use `&` for background processes; make separate tool calls instead\n" ++
    "- Do NOT use interactive commands (REPLs, editors, password prompts)\n" ++
    "- Output shows first 50 and last 50 lines; middle is truncated for large outputs\n" ++
    "- Environment variables and `cd` do not persist between commands; use the `cwd` parameter instead\n" ++
    "- Commands run in the workspace root by default; only use `cwd` when you need a different directory\n" ++
    "- ALWAYS quote file paths: `cat \"path with spaces/file.txt\"`\n" ++
    "- Use the Grep tool instead of grep, the Read tool instead of cat\n" ++
    "- Only run `git commit` and `git push` if explicitly instructed by the user.";

pub fn definition(ctx: *util.BuiltinCtx) tool_def.ToolDefinition {
    return .{
        .name = "bash",
        .description = DESCRIPTION,
        .label = "Bash",
        .parameters = parseSchema(),
        .prompt_snippet = "Execute bash commands (ls, grep, find, etc.)",
        .impl = .{ .builtin = .{ .ctx = @ptrCast(ctx), .execute = &execute } },
        .source = .{ .kind = "builtin", .id = "bash" },
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

const PermissionAction = enum { allow, reject };

const PermissionRule = struct {
    tool: []const u8,
    cmd_patterns: []const []const u8 = &.{},
    action: PermissionAction,
    message: ?[]const u8 = null,
};

fn execute(
    raw_ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    args: std.json.Value,
    signal: agent.protocol.AbortSignal,
    _: ?agent.protocol.AgentToolUpdateCallback,
    _: ?*anyopaque,
) agent.protocol.AgentToolResult {
    const ctx: *util.BuiltinCtx = @ptrCast(@alignCast(raw_ctx orelse
        return util.errorResult(allocator, "bash tool: missing context")));

    var command = util.getString(args, "cmd") orelse
        return util.errorResult(allocator, "bash tool: missing 'cmd' argument");
    command = stripBackground(command);

    var effective_cwd = blk: {
        const cwd_arg = util.getString(args, "cwd") orelse break :blk allocator.dupe(u8, ctx.cwd) catch
            return util.errorResult(allocator, "bash tool: alloc failed");
        break :blk util.resolvePath(allocator, cwd_arg, ctx.cwd) catch
            return util.errorResult(allocator, "bash tool: failed to resolve cwd");
    };
    defer allocator.free(effective_cwd);

    if (splitCdCommand(command)) |cd_split| {
        const next_cwd = util.resolvePath(allocator, cd_split.cwd, effective_cwd) catch
            return util.errorResult(allocator, "bash tool: failed to resolve cwd");
        allocator.free(effective_cwd);
        effective_cwd = next_cwd;
        command = cd_split.command;
    }

    std.fs.accessAbsolute(effective_cwd, .{}) catch {
        return util.errorf(allocator, "working directory does not exist: {s}", .{effective_cwd});
    };

    const rules = loadPermissions(allocator) catch &.{};
    defer freePermissions(allocator, rules);
    const verdict = evaluatePermission(command, rules);
    if (verdict.action == .reject) {
        if (verdict.message) |message| {
            return util.errorf(allocator, "command rejected: {s}", .{message});
        }
        return util.errorf(allocator, "command rejected by permission rule. command: {s}", .{command});
    }

    const final_command = injectGitTrailers(allocator, command, ctx.session_id) catch allocator.dupe(u8, command) catch
        return util.errorResult(allocator, "bash tool: alloc failed");
    defer allocator.free(final_command);

    if (isGitCommand(final_command)) {
        const git_lock_key = std.fs.path.join(allocator, &.{ effective_cwd, ".git", "__zi_git_lock__" }) catch
            return util.errorResult(allocator, "bash tool: alloc failed");
        defer allocator.free(git_lock_key);
        const lock_entry = lock_registry.global().acquireKey(git_lock_key) catch
            return util.errorResult(allocator, "bash tool: failed to acquire git lock");
        defer lock_registry.global().release(lock_entry);
        return runCommand(allocator, final_command, effective_cwd, extractTimeout(args), signal);
    }

    return runCommand(allocator, final_command, effective_cwd, extractTimeout(args), signal);
}

fn runCommand(
    allocator: std.mem.Allocator,
    command: []const u8,
    cwd: []const u8,
    timeout_secs: ?u64,
    signal: agent.protocol.AbortSignal,
) agent.protocol.AgentToolResult {
    var thread_safe_allocator: std.heap.ThreadSafeAllocator = .{ .child_allocator = allocator };
    const io_allocator = thread_safe_allocator.allocator();

    const shell_argv: []const []const u8 = if (std.fs.accessAbsolute("/bin/bash", .{}))
        &.{ "/bin/bash", "-c", command }
    else |_|
        &.{ "/bin/sh", "-c", command };

    var child = std.process.Child.init(shell_argv, allocator);
    child.cwd = cwd;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch |err| {
        return util.errorf(allocator, "command error: {s}", .{@errorName(err)});
    };

    var abort_guard = AbortGuard.start(signal, .{ .kill_pid = child.id });
    defer abort_guard.stop();

    var timeout_guard = TimeoutGuard.start(timeout_secs, child.id);
    defer timeout_guard.stop();

    var stderr_result: ?[]u8 = null;
    var stderr_thread: ?std.Thread = null;
    if (child.stderr) |stderr_file| {
        stderr_thread = std.Thread.spawn(.{}, readStderr, .{ stderr_file, io_allocator, &stderr_result }) catch null;
    }

    const stdout_data = if (child.stdout) |stdout_file|
        stdout_file.readToEndAlloc(io_allocator, MAX_OUTPUT_BYTES) catch null
    else
        null;
    defer if (stdout_data) |data| io_allocator.free(data);

    if (stderr_thread) |t| t.join();
    defer if (stderr_result) |data| io_allocator.free(data);

    const term = child.wait() catch null;
    timeout_guard.markExited();

    var merged: std.ArrayListUnmanaged(u8) = .empty;
    defer merged.deinit(allocator);
    if (stdout_data) |data| {
        if (data.len > 0) merged.appendSlice(allocator, data) catch {};
    }
    if (stderr_result) |data| {
        if (data.len > 0) {
            if (merged.items.len > 0) merged.appendSlice(allocator, "\n") catch {};
            merged.appendSlice(allocator, data) catch {};
        }
    }

    const output_text = truncateHeadTail(allocator, merged.items) catch allocator.dupe(u8, merged.items) catch null;
    defer if (output_text) |text| allocator.free(text);

    var result = std.ArrayList(u8).empty;
    defer result.deinit(allocator);
    result.appendSlice(allocator, "$ ") catch return util.errorResult(allocator, "bash tool: alloc failed");
    result.appendSlice(allocator, command) catch return util.errorResult(allocator, "bash tool: alloc failed");
    result.appendSlice(allocator, "\n\n") catch return util.errorResult(allocator, "bash tool: alloc failed");
    result.appendSlice(allocator, if (output_text) |text| if (text.len > 0) text else "(no output)" else "(no output)") catch
        return util.errorResult(allocator, "bash tool: alloc failed");

    if (signal.isAborted()) {
        result.appendSlice(allocator, "\n\ncommand aborted") catch {};
        return .{ .content = oneText(allocator, result.items), .is_error = true };
    }

    if (timeout_guard.did_timeout.load(.acquire)) {
        if (timeout_secs) |secs| {
            const tail = std.fmt.allocPrint(allocator, "\n\ncommand timed out after {d} seconds", .{secs}) catch "";
            defer if (tail.len > 0) allocator.free(tail);
            result.appendSlice(allocator, tail) catch {};
        }
        return .{ .content = oneText(allocator, result.items), .is_error = true };
    }

    if (term) |t| switch (t) {
        .Exited => |code| {
            if (code != 0) {
                const tail = std.fmt.allocPrint(allocator, "\n\nexit code {d}", .{code}) catch "";
                defer if (tail.len > 0) allocator.free(tail);
                result.appendSlice(allocator, tail) catch {};
                return .{ .content = oneText(allocator, result.items), .is_error = true };
            }
        },
        else => {
            return .{ .content = oneText(allocator, result.items), .is_error = true };
        },
    };

    return .{ .content = oneText(allocator, result.items) };
}

const TimeoutGuard = struct {
    done: *std.atomic.Value(bool),
    did_timeout: *std.atomic.Value(bool),
    thread: ?std.Thread,

    fn start(timeout_secs: ?u64, pid: std.process.Child.Id) TimeoutGuard {
        const secs = timeout_secs orelse return .{ .done = &noop_done, .did_timeout = &noop_done, .thread = null };
        const done = std.heap.page_allocator.create(std.atomic.Value(bool)) catch return .{ .done = &noop_done, .did_timeout = &noop_done, .thread = null };
        errdefer std.heap.page_allocator.destroy(done);
        const did_timeout = std.heap.page_allocator.create(std.atomic.Value(bool)) catch return .{ .done = &noop_done, .did_timeout = &noop_done, .thread = null };
        done.* = std.atomic.Value(bool).init(false);
        did_timeout.* = std.atomic.Value(bool).init(false);
        const thread = std.Thread.spawn(.{}, watchdog, .{ secs, pid, done, did_timeout }) catch null;
        return .{ .done = done, .did_timeout = did_timeout, .thread = thread };
    }

    fn markExited(self: *TimeoutGuard) void {
        self.done.store(true, .release);
    }

    fn stop(self: *TimeoutGuard) void {
        self.done.store(true, .release);
        if (self.thread) |t| t.join();
        if (self.done != &noop_done) std.heap.page_allocator.destroy(self.done);
        if (self.did_timeout != &noop_done) std.heap.page_allocator.destroy(self.did_timeout);
        self.thread = null;
    }

    var noop_done = std.atomic.Value(bool).init(false);

    fn watchdog(timeout_secs: u64, pid: std.process.Child.Id, done: *std.atomic.Value(bool), did_timeout: *std.atomic.Value(bool)) void {
        const deadline_ns = timeout_secs * std.time.ns_per_s;
        var elapsed_ns: u64 = 0;
        const poll_ns = 100 * std.time.ns_per_ms;

        while (elapsed_ns < deadline_ns) {
            if (done.load(.acquire)) return;
            const remaining_ns = deadline_ns - elapsed_ns;
            const sleep_ns = @min(poll_ns, remaining_ns);
            std.Thread.sleep(sleep_ns);
            elapsed_ns += sleep_ns;
        }

        if (done.load(.acquire)) return;
        did_timeout.store(true, .release);
        std.posix.kill(pid, std.posix.SIG.KILL) catch {};
    }
};

test "TimeoutGuard.stop does not wait for the full timeout after process exit" {
    const testing = std.testing;

    var child = std.process.Child.init(&.{ "/bin/sh", "-c", "exit 0" }, testing.allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();

    var guard = TimeoutGuard.start(2, child.id);

    _ = try child.wait();
    try testing.expect(!guard.did_timeout.load(.acquire));
    guard.markExited();

    const start_ns = std.time.nanoTimestamp();
    guard.stop();
    const elapsed_ns = std.time.nanoTimestamp() - start_ns;

    try testing.expect(elapsed_ns < 500 * std.time.ns_per_ms);
}

test "oneText sanitizes invalid utf-8" {
    const allocator = std.testing.allocator;
    const blocks = oneText(allocator, "bad\xaa\xfftail");
    defer {
        allocator.free(blocks[0].text.text);
        allocator.free(blocks);
    }

    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqualStrings("bad��tail", blocks[0].text.text);
}

test "runCommand handles concurrent stdout and stderr" {
    const testing = std.testing;
    const cmd =
        \\i=0
        \\while [ "$i" -lt 400 ]; do
        \\  printf 'out%04d\n' "$i"
        \\  printf 'err%04d\n' "$i" 1>&2
        \\  i=$((i + 1))
        \\done
    ;

    var iteration: usize = 0;
    while (iteration < 32) : (iteration += 1) {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        const result = runCommand(arena.allocator(), cmd, "/tmp", 5, agent.protocol.AbortSignal.none);

        try testing.expect(!result.is_error);
        try testing.expectEqual(@as(usize, 1), result.content.len);
        try testing.expect(result.content[0] == .text);
        try testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "out0000") != null);
        try testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "err0399") != null);
        try testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "... output truncated ...") != null);
    }
}

fn oneText(allocator: std.mem.Allocator, text: []const u8) []agent.protocol.AgentToolResult.ContentBlock {
    const owned = json_util.utf8LossyAlloc(allocator, text) catch allocator.dupe(u8, text) catch return &.{};
    errdefer allocator.free(owned);

    const blocks = allocator.alloc(agent.protocol.AgentToolResult.ContentBlock, 1) catch return &.{};
    blocks[0] = .{ .text = .{ .text = owned } };
    return blocks;
}

fn readStderr(stderr_file: std.fs.File, alloc: std.mem.Allocator, result: *?[]u8) void {
    result.* = stderr_file.readToEndAlloc(alloc, MAX_OUTPUT_BYTES) catch null;
}

fn extractTimeout(args: std.json.Value) ?u64 {
    switch (args) {
        .object => |obj| {
            if (obj.get("timeout")) |value| switch (value) {
                .integer => |i| if (i > 0) return @intCast(i),
                .float => |f| if (f > 0) return @intFromFloat(@floor(f)),
                else => {},
            };
            return null;
        },
        else => return null,
    }
}

const CdSplit = struct {
    cwd: []const u8,
    command: []const u8,
};

fn splitCdCommand(cmd: []const u8) ?CdSplit {
    const trimmed = std.mem.trim(u8, cmd, &std.ascii.whitespace);
    if (!std.mem.startsWith(u8, trimmed, "cd ")) return null;

    const rest = trimmed[3..];
    var sep_idx: ?usize = null;
    var sep_len: usize = 0;
    if (std.mem.indexOf(u8, rest, "&&")) |idx| {
        sep_idx = idx;
        sep_len = 2;
    }
    if (std.mem.indexOfScalar(u8, rest, ';')) |idx| {
        if (sep_idx == null or idx < sep_idx.?) {
            sep_idx = idx;
            sep_len = 1;
        }
    }
    const idx = sep_idx orelse return null;

    const raw_dir = std.mem.trim(u8, rest[0..idx], &std.ascii.whitespace);
    const raw_command = std.mem.trim(u8, rest[idx + sep_len ..], &std.ascii.whitespace);
    if (raw_dir.len == 0 or raw_command.len == 0) return null;
    return .{ .cwd = unquote(raw_dir), .command = raw_command };
}

fn unquote(text: []const u8) []const u8 {
    if (text.len >= 2 and ((text[0] == '"' and text[text.len - 1] == '"') or (text[0] == '\'' and text[text.len - 1] == '\''))) {
        return text[1 .. text.len - 1];
    }
    return text;
}

fn stripBackground(cmd: []const u8) []const u8 {
    const trimmed = std.mem.trimRight(u8, cmd, &std.ascii.whitespace);
    if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '&') {
        return std.mem.trimRight(u8, trimmed[0 .. trimmed.len - 1], &std.ascii.whitespace);
    }
    return trimmed;
}

fn isGitCommand(cmd: []const u8) bool {
    return std.mem.indexOf(u8, cmd, "git ") != null;
}

fn injectGitTrailers(allocator: std.mem.Allocator, cmd: []const u8, session_id: []const u8) ![]u8 {
    if (session_id.len == 0) return allocator.dupe(u8, cmd);
    if (std.mem.indexOf(u8, cmd, "git commit") == null) return allocator.dupe(u8, cmd);
    if (std.mem.indexOf(u8, cmd, "--trailer") != null) return allocator.dupe(u8, cmd);
    const needle = "git commit";
    const idx = std.mem.indexOf(u8, cmd, needle) orelse return allocator.dupe(u8, cmd);
    return std.fmt.allocPrint(allocator, "{s}git commit --trailer \"Session-Id: {s}\"{s}", .{
        cmd[0..idx],
        session_id,
        cmd[idx + needle.len ..],
    });
}

fn truncateHeadTail(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var lines = std.ArrayList([]const u8).empty;
    defer lines.deinit(allocator);

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        try lines.append(allocator, line);
    }

    if (lines.items.len <= HEAD_LINES + TAIL_LINES) return allocator.dupe(u8, text);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    for (lines.items[0..HEAD_LINES], 0..) |line, idx| {
        if (idx > 0) try out.append(allocator, '\n');
        try out.appendSlice(allocator, line);
    }
    try out.appendSlice(allocator, "\n... output truncated ...\n");
    const tail_start = lines.items.len - TAIL_LINES;
    for (lines.items[tail_start..], 0..) |line, idx| {
        if (idx > 0) try out.append(allocator, '\n');
        try out.appendSlice(allocator, line);
    }
    return out.toOwnedSlice(allocator);
}

fn globMatches(pattern: []const u8, text: []const u8) bool {
    if (pattern.len == 0) return text.len == 0;
    if (pattern[0] == '*') {
        if (globMatches(pattern[1..], text)) return true;
        return text.len > 0 and globMatches(pattern, text[1..]);
    }
    if (text.len == 0) return false;
    return std.ascii.toLower(pattern[0]) == std.ascii.toLower(text[0]) and globMatches(pattern[1..], text[1..]);
}

fn evaluatePermission(cmd: []const u8, rules: []const PermissionRule) PermissionRule {
    for (rules) |rule| {
        if (!globMatches(rule.tool, "Bash")) continue;
        if (rule.cmd_patterns.len > 0) {
            var matched = false;
            for (rule.cmd_patterns) |pattern| {
                if (globMatches(pattern, cmd)) {
                    matched = true;
                    break;
                }
            }
            if (!matched) continue;
        }
        return rule;
    }
    return .{ .tool = "Bash", .action = .allow };
}

fn loadPermissions(allocator: std.mem.Allocator) ![]PermissionRule {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return &.{};
    defer allocator.free(home);
    const permissions_path = try std.fs.path.join(allocator, &.{ home, ".pi", "agent", "permissions.json" });
    defer allocator.free(permissions_path);

    const raw = std.fs.cwd().readFileAlloc(allocator, permissions_path, 1024 * 1024) catch return &.{};
    defer allocator.free(raw);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return &.{};
    defer parsed.deinit();
    if (parsed.value != .array) return &.{};

    var rules = std.ArrayList(PermissionRule).empty;
    errdefer {
        freePermissions(allocator, rules.items);
        rules.deinit(allocator);
    }

    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const obj = item.object;
        const tool = switch (obj.get("tool") orelse continue) {
            .string => |s| try allocator.dupe(u8, s),
            else => continue,
        };
        errdefer allocator.free(tool);

        const action = switch (obj.get("action") orelse continue) {
            .string => |s| if (std.mem.eql(u8, s, "reject")) PermissionAction.reject else PermissionAction.allow,
            else => PermissionAction.allow,
        };
        const message = switch (obj.get("message") orelse .null) {
            .string => |s| try allocator.dupe(u8, s),
            else => null,
        };
        errdefer if (message) |m| allocator.free(m);

        var cmd_patterns = std.ArrayList([]const u8).empty;
        errdefer {
            for (cmd_patterns.items) |p| allocator.free(p);
            cmd_patterns.deinit(allocator);
        }
        if (obj.get("matches")) |matches_val| {
            if (matches_val == .object) {
                if (matches_val.object.get("cmd")) |cmd_val| switch (cmd_val) {
                    .string => |s| try cmd_patterns.append(allocator, try allocator.dupe(u8, s)),
                    .array => |arr| for (arr.items) |entry| if (entry == .string) try cmd_patterns.append(allocator, try allocator.dupe(u8, entry.string)),
                    else => {},
                };
            }
        }

        try rules.append(allocator, .{
            .tool = tool,
            .cmd_patterns = try cmd_patterns.toOwnedSlice(allocator),
            .action = action,
            .message = message,
        });
    }

    return rules.toOwnedSlice(allocator);
}

fn freePermissions(allocator: std.mem.Allocator, rules: []const PermissionRule) void {
    for (rules) |rule| {
        allocator.free(rule.tool);
        for (rule.cmd_patterns) |pattern| allocator.free(pattern);
        if (rule.cmd_patterns.len > 0) allocator.free(rule.cmd_patterns);
        if (rule.message) |message| allocator.free(message);
    }
    if (rules.len > 0) allocator.free(rules);
}
