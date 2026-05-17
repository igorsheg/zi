const std = @import("std");
const protocol = @import("../../agent/types.zig");
const json_util = @import("../../ai/json_util.zig");
const storage = @import("../../storage.zig");
const tool_def = @import("definition.zig");
const util = @import("util.zig");
const zio = @import("../../zio/root.zig");
const runtime_process = zio.process;

const MAX_CAPTURE_BYTES: usize = 50 * 1024;
const MAX_DISPLAY_BYTES: usize = 12 * 1024;
const STREAM_UPDATE_INTERVAL_MS: i128 = 100;

const bash_schema =
    \\{"type":"object","properties":{"cmd":{"type":"string","description":"The shell command to execute."},"cwd":{"type":"string","description":"Working directory for the command (absolute path). Defaults to workspace root."},"timeout":{"type":"number","description":"Timeout in seconds."}},"required":["cmd"]}
;

const DESCRIPTION =
    "Executes the given shell command using bash.\n\n" ++
    "- Do NOT use interactive commands (REPLs, editors, password prompts)\n" ++
    "- Output is bounded to 50KB each for stdout and stderr\n" ++
    "- Commands run with zi's process environment plus tool-specific overrides; environment changes and `cd` do not persist between commands\n" ++
    "- Commands run in the workspace root by default; only use `cwd` when you need a different directory\n" ++
    "- Use focused commands and prefer dedicated tools for file reads and searches.";

pub fn definition(ctx: *util.BuiltinCtx) tool_def.ToolDefinition {
    return .{
        .name = "bash",
        .description = DESCRIPTION,
        .label = "Bash",
        .display_call = "cmd",
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
    return .{ .ready = executeSync(raw_ctx, allocator, args, signal, on_update, update_ctx) };
}

fn executeSync(
    raw_ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    args: std.json.Value,
    signal: protocol.Token,
    on_update: ?protocol.AgentToolUpdateCallback,
    update_ctx: ?*anyopaque,
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

    return runCommand(allocator, ctx, command, effective_cwd, extractTimeout(args), signal, on_update, update_ctx);
}

fn runCommand(
    allocator: std.mem.Allocator,
    ctx: *util.BuiltinCtx,
    command: []const u8,
    cwd: []const u8,
    timeout_secs: ?u64,
    signal: protocol.Token,
    on_update: ?protocol.AgentToolUpdateCallback,
    update_ctx: ?*anyopaque,
) protocol.AgentToolResult {
    const io = ctx.io;
    const shell_argv: []const []const u8 = if (std.Io.Dir.accessAbsolute(io, "/bin/bash", .{}))
        &.{ "/bin/bash", "-c", command }
    else |_|
        &.{ "/bin/sh", "-c", command };

    var emitter = StreamEmitter{
        .allocator = allocator,
        .io = io,
        .cwd = ctx.cwd,
        .session_id = ctx.session_id,
        .command = command,
        .on_update = on_update,
        .update_ctx = update_ctx,
    };
    defer emitter.deinit();

    var proc_result = runtime_process.run(allocator, io, .{
        .argv = shell_argv,
        .cwd = .{ .path = cwd },
        .timeout_ms = if (timeout_secs) |secs| secs * std.time.ms_per_s else null,
        .signal = signal,
        .stdout_limit = .limited(MAX_DISPLAY_BYTES),
        .stderr_limit = .limited(MAX_DISPLAY_BYTES),
        .stdout_overflow = .truncate,
        .stderr_overflow = .truncate,
        .on_chunk = .{ .ctx = @ptrCast(&emitter), .func = StreamEmitter.callback },
    }) catch return util.errorResult(allocator, "command error: failed to run command");
    defer proc_result.deinit(allocator);
    emitter.flush();
    emitter.closeArtifact();

    const is_error, const tail = classifyResult(proc_result, signal, timeout_secs);
    const transcript = formatResult(allocator, command, proc_result, tail, emitter.artifactPath()) catch
        return util.errorResult(allocator, "bash tool: alloc failed");

    return ownedUtf8TextResult(allocator, transcript, is_error);
}

const StreamEmitter = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    session_id: []const u8,
    command: []const u8,
    on_update: ?protocol.AgentToolUpdateCallback,
    update_ctx: ?*anyopaque,
    stdout: std.ArrayList(u8) = .empty,
    stderr: std.ArrayList(u8) = .empty,
    artifact: OutputArtifact = .{},
    last_emit_ms: i128 = 0,
    mutex: std.Io.Mutex = .init,

    fn deinit(self: *StreamEmitter) void {
        self.closeArtifact();
        if (self.artifact.path) |path| self.allocator.free(path);
        self.artifact.cache.deinit(self.allocator);
        self.stdout.deinit(self.allocator);
        self.stderr.deinit(self.allocator);
    }

    fn callback(raw: ?*anyopaque, kind: runtime_process.StreamKind, bytes: []const u8) void {
        const self: *StreamEmitter = @ptrCast(@alignCast(raw.?));
        self.onChunk(kind, bytes);
    }

    fn onChunk(self: *StreamEmitter, kind: runtime_process.StreamKind, bytes: []const u8) void {
        if (bytes.len == 0) return;

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.artifact.addChunk(self.allocator, self.io, self.cwd, self.session_id, kind, bytes) catch {};

        if (self.on_update == null) return;

        const list = switch (kind) {
            .stdout => &self.stdout,
            .stderr => &self.stderr,
        };
        appendBounded(self.allocator, list, bytes, MAX_CAPTURE_BYTES) catch return;

        const now_ms = @divFloor(zio.deadline.nowNs(self.io), std.time.ns_per_ms);
        if (now_ms - self.last_emit_ms < STREAM_UPDATE_INTERVAL_MS) return;
        self.last_emit_ms = now_ms;
        self.emitLocked();
    }

    fn flush(self: *StreamEmitter) void {
        if (self.on_update == null) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.emitLocked();
    }

    fn emitLocked(self: *StreamEmitter) void {
        const cb = self.on_update orelse return;
        const result = self.makePartialResult() catch return;
        defer result.free(self.allocator);
        cb(result, self.update_ctx);
    }

    fn closeArtifact(self: *StreamEmitter) void {
        self.artifact.close(self.io);
    }

    fn artifactPath(self: *const StreamEmitter) ?[]const u8 {
        return self.artifact.visiblePath();
    }

    fn makePartialResult(self: *StreamEmitter) !protocol.AgentToolResult {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, "$ ");
        try out.appendSlice(self.allocator, self.command);
        try out.appendSlice(self.allocator, "\n\n");
        try appendCaptured(self.allocator, &out, self.stdout.items, self.stderr.items);
        return ownedUtf8TextResult(self.allocator, try out.toOwnedSlice(self.allocator), false);
    }
};

const OutputArtifact = struct {
    const create_after_bytes: usize = MAX_CAPTURE_BYTES;

    path: ?[]u8 = null,
    file: ?std.Io.File = null,
    cache: std.ArrayList(u8) = .empty,
    total_bytes: usize = 0,
    last_kind: ?runtime_process.StreamKind = null,
    visible: bool = false,

    fn addChunk(self: *OutputArtifact, allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, session_id: []const u8, kind: runtime_process.StreamKind, bytes: []const u8) !void {
        self.total_bytes += bytes.len;
        if (self.total_bytes > create_after_bytes) self.visible = true;

        if (self.file == null and self.total_bytes > create_after_bytes) {
            try self.open(allocator, io, cwd, session_id);
            if (self.cache.items.len > 0) {
                try self.file.?.writeStreamingAll(io, self.cache.items);
                self.cache.clearRetainingCapacity();
            }
        }

        if (self.file) |file| {
            try self.writeLabeled(io, file, kind, bytes);
        } else {
            try self.appendLabeled(allocator, kind, bytes);
        }
    }

    fn visiblePath(self: *const OutputArtifact) ?[]const u8 {
        return if (self.visible) self.path else null;
    }

    fn close(self: *OutputArtifact, io: std.Io) void {
        if (self.file) |file| {
            file.close(io);
            self.file = null;
        }
    }

    fn open(self: *OutputArtifact, allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, session_id: []const u8) !void {
        const session_dir = try storage.getSessionDirForCwd(allocator, cwd, null);
        defer allocator.free(session_dir);
        const artifact_dir = try std.fs.path.join(allocator, &.{ session_dir, "artifacts" });
        defer allocator.free(artifact_dir);
        try std.Io.Dir.cwd().createDirPath(io, artifact_dir);

        const sid = if (session_id.len > 0) session_id else "no-session";
        const now = std.Io.Clock.real.now(io).toMilliseconds();
        const path = try std.fmt.allocPrint(allocator, "{s}/bash-{s}-{d}.log", .{ artifact_dir, sid, now });
        errdefer allocator.free(path);
        const file = try std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = true });
        self.path = path;
        self.file = file;
    }

    fn appendLabeled(self: *OutputArtifact, allocator: std.mem.Allocator, kind: runtime_process.StreamKind, bytes: []const u8) !void {
        if (self.last_kind == null or self.last_kind.? != kind) {
            try self.cache.appendSlice(allocator, labelFor(kind));
            self.last_kind = kind;
        }
        try self.cache.appendSlice(allocator, bytes);
    }

    fn writeLabeled(self: *OutputArtifact, io: std.Io, file: std.Io.File, kind: runtime_process.StreamKind, bytes: []const u8) !void {
        if (self.last_kind == null or self.last_kind.? != kind) {
            try file.writeStreamingAll(io, labelFor(kind));
            self.last_kind = kind;
        }
        try file.writeStreamingAll(io, bytes);
    }

    fn labelFor(kind: runtime_process.StreamKind) []const u8 {
        return switch (kind) {
            .stdout => "\n[stdout]\n",
            .stderr => "\n[stderr]\n",
        };
    }
};

fn appendBounded(allocator: std.mem.Allocator, list: *std.ArrayList(u8), bytes: []const u8, limit: usize) !void {
    if (limit == 0) return;
    if (bytes.len >= limit) {
        try list.resize(allocator, limit);
        @memcpy(list.items, bytes[bytes.len - limit ..]);
        return;
    }
    try list.appendSlice(allocator, bytes);
    if (list.items.len > limit) {
        const excess = list.items.len - limit;
        std.mem.copyForwards(u8, list.items[0..limit], list.items[excess..]);
        try list.resize(allocator, limit);
    }
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
        .output_dropped => .{ true, "process output events dropped" },
        .aborted => .{ true, "command aborted" },
    };
}

fn formatResult(
    allocator: std.mem.Allocator,
    command: []const u8,
    result: runtime_process.RunResult,
    tail: []const u8,
    artifact_path: ?[]const u8,
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "$ ");
    try out.appendSlice(allocator, command);
    try out.appendSlice(allocator, "\n\n");

    switch (result) {
        .completed => |completed| {
            try appendCaptured(allocator, &out, completed.stdout.bytes, completed.stderr.bytes);
            try appendTruncationNotice(allocator, &out, completed.stdout, completed.stderr, artifact_path);
            if (completed.term == .exited and completed.term.exited != 0) {
                const msg = try std.fmt.allocPrint(allocator, "\n\nexit code {d}", .{completed.term.exited});
                defer allocator.free(msg);
                try out.appendSlice(allocator, msg);
            } else if (completed.term != .exited) {
                try out.appendSlice(allocator, "\n\ncommand terminated");
            }
        },
        .timed_out, .stdout_too_long, .stderr_too_long, .output_dropped, .aborted => |partial| {
            try appendCaptured(allocator, &out, partial.stdout.bytes, partial.stderr.bytes);
            try appendTruncationNotice(allocator, &out, partial.stdout, partial.stderr, artifact_path);
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

fn appendTruncationNotice(allocator: std.mem.Allocator, out: *std.ArrayList(u8), stdout: runtime_process.CapturedStream, stderr: runtime_process.CapturedStream, artifact_path: ?[]const u8) !void {
    if (!stdout.truncated and !stderr.truncated) return;
    try out.appendSlice(allocator, "\n\n[output truncated");
    if (stdout.truncated) {
        const msg = try std.fmt.allocPrint(allocator, ": stdout kept {d} of {d} bytes", .{ stdout.bytes.len, stdout.total_bytes });
        defer allocator.free(msg);
        try out.appendSlice(allocator, msg);
    }
    if (stderr.truncated) {
        const msg = try std.fmt.allocPrint(allocator, "{s}stderr kept {d} of {d} bytes", .{ if (stdout.truncated) ", " else ": ", stderr.bytes.len, stderr.total_bytes });
        defer allocator.free(msg);
        try out.appendSlice(allocator, msg);
    }
    if (artifact_path) |path| {
        const msg = try std.fmt.allocPrint(allocator, "; full output: {s}", .{path});
        defer allocator.free(msg);
        try out.appendSlice(allocator, msg);
    }
    try out.appendSlice(allocator, "]");
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

fn testCtx() util.BuiltinCtx {
    return .{ .cwd = "/tmp", .io = std.Options.debug_io, .session_id = "test-session" };
}

test "runCommand returns stdout and stderr" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = testCtx();

    const result = runCommand(
        arena.allocator(),
        &ctx,
        "printf out; printf err 1>&2",
        "/tmp",
        5,
        protocol.Token.none,
        null,
        null,
    );

    try std.testing.expect(!result.is_error);
    try expectTextBlockContains(result, "out");
    try expectTextBlockContains(result, "err");
}

test "runCommand exits naturally before timeout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = testCtx();

    const start = std.Io.Timestamp.now(std.Options.debug_io, .awake).toMilliseconds();
    const result = runCommand(
        arena.allocator(),
        &ctx,
        "sleep 0.1; printf done",
        "/tmp",
        5,
        protocol.Token.none,
        null,
        null,
    );
    const elapsed = std.Io.Timestamp.now(std.Options.debug_io, .awake).toMilliseconds() - start;

    try std.testing.expect(!result.is_error);
    try std.testing.expect(elapsed < 1000);
    try expectTextBlockContains(result, "done");
}

test "runCommand true returns immediately before long timeout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = testCtx();

    const start = std.Io.Timestamp.now(std.Options.debug_io, .awake).toMilliseconds();
    const result = runCommand(
        arena.allocator(),
        &ctx,
        "true",
        "/tmp",
        10,
        protocol.Token.none,
        null,
        null,
    );
    const elapsed = std.Io.Timestamp.now(std.Options.debug_io, .awake).toMilliseconds() - start;

    try std.testing.expect(!result.is_error);
    try std.testing.expect(elapsed < 500);
}

test "runCommand reports timeout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = testCtx();

    const result = runCommand(
        arena.allocator(),
        &ctx,
        "sleep 2",
        "/tmp",
        1,
        protocol.Token.none,
        null,
        null,
    );

    try std.testing.expect(result.is_error);
    try expectTextBlockContains(result, "timed out");
}

test "runCommand emits partial updates while preserving final result" {
    const Collector = struct {
        saw_first: bool = false,
        updates: usize = 0,

        fn onUpdate(result: protocol.AgentToolResult, raw: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.updates += 1;
            if (result.content.len == 0 or result.content[0] != .text) return;
            if (std.mem.indexOf(u8, result.content[0].text.text, "first") != null) self.saw_first = true;
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var collector = Collector{};
    var ctx = testCtx();

    const result = runCommand(
        arena.allocator(),
        &ctx,
        "printf first; sleep 0.2; printf second",
        "/tmp",
        5,
        protocol.Token.none,
        Collector.onUpdate,
        @ptrCast(&collector),
    );

    try std.testing.expect(!result.is_error);
    try std.testing.expect(collector.updates > 0);
    try std.testing.expect(collector.saw_first);
    try expectTextBlockContains(result, "firstsecond");
}

test "runCommand preserves full truncated output in artifact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = testCtx();

    const result = runCommand(
        arena.allocator(),
        &ctx,
        "yes x | head -c 110000",
        "/tmp",
        5,
        protocol.Token.none,
        null,
        null,
    );

    try std.testing.expect(!result.is_error);
    try expectTextBlockContains(result, "output truncated");
    try expectTextBlockContains(result, "full output:");
    const text = result.content[0].text.text;
    const marker = "; full output: ";
    const start = (std.mem.indexOf(u8, text, marker) orelse return error.MissingArtifactPath) + marker.len;
    const end = std.mem.indexOfScalarPos(u8, text, start, ']') orelse return error.MissingArtifactPath;
    const path = text[start..end];
    defer std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, path) catch {};

    const data = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(data);
    try std.testing.expect(std.mem.indexOf(u8, data, "[stdout]") != null);
    try std.testing.expect(data.len >= 110000);
}
