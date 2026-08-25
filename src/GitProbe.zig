const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("paths.h");
});
const persistence = @import("persistence/root.zig");
const ProcessSpawn = @import("ProcessSpawn.zig");

pub const maximum_output_bytes: usize = 8192;
pub const maximum_path_bytes: usize = std.fs.max_path_bytes;
pub const default_timeout: std.Io.Duration = .fromMilliseconds(1000);

pub const Error = error{ OutOfMemory, Cancelled };

pub const Options = struct {
    /// Canonical absolute working directory. It is never inferred from process state.
    cwd: []const u8,
    /// Complete child environment. It is passed without additions or ambient inheritance.
    environ: *const std.process.Environ.Map,
    /// PATH used only for resolving git. Null selects libc `_CS_PATH`, the
    /// target's execvp default. Explicit empty and relative entries are rejected.
    path: ?[]const u8 = null,
    /// Optional canonical absolute executable path. When set, PATH is not searched.
    git_executable: ?[]const u8 = null,
    timeout: std.Io.Duration = default_timeout,
};

/// Allocator-owned repository snapshot. Each field is independently optional,
/// preserving hax's unborn and detached-HEAD behavior.
pub const State = struct {
    branch: ?[]u8 = null,
    commit: ?[]u8 = null,
    subject: ?[]u8 = null,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.branch) |value| allocator.free(value);
        if (self.commit) |value| allocator.free(value);
        if (self.subject) |value| allocator.free(value);
        self.* = undefined;
    }

    /// Copies session fields into the ownership shape used by persistence.
    pub fn toSessionFile(
        self: State,
        allocator: std.mem.Allocator,
    ) error{OutOfMemory}!persistence.SessionFile.GitState {
        var result: persistence.SessionFile.GitState = .{};
        errdefer result.deinit(allocator);
        result.branch = if (self.branch) |value| try allocator.dupe(u8, value) else null;
        result.commit = if (self.commit) |value| try allocator.dupe(u8, value) else null;
        result.subject = if (self.subject) |value| try allocator.dupe(u8, value) else null;
        return result;
    }
};

pub const Result = union(enum) {
    unavailable,
    available: State,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .unavailable => {},
            .available => |*state| state.deinit(allocator),
        }
        self.* = undefined;
    }
};

const CommandResult = struct {
    bytes: [maximum_output_bytes + 1]u8 = undefined,
    length: usize = 0,
    term: std.process.Child.Term = undefined,
    overflow: bool = false,
};

const RunError = error{ Canceled, Failed };
const CommandOutput = union(enum) { failed, timeout, success: usize };

/// Private command seam. Output bytes borrow the caller's fixed buffer; the
/// executor never transfers allocation ownership to the probe composer.
const CommandExecutor = struct {
    context: *anyopaque,
    execute_fn: *const fn (
        context: *anyopaque,
        argv: []const []const u8,
        output: *[maximum_output_bytes]u8,
    ) Error!CommandOutput,

    fn execute(
        self: CommandExecutor,
        argv: []const []const u8,
        output: *[maximum_output_bytes]u8,
    ) Error!CommandOutput {
        return self.execute_fn(self.context, argv, output);
    }
};

const Selection = union(enum) {
    command: RunError!CommandResult,
    timeout: error{Canceled}!void,
};

/// Probes only local repository state. It never invokes a shell or a network command.
pub fn probe(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
) Error!Result {
    if (preflightOptions(options) != null) return .unavailable;

    var executable_buffer: [maximum_path_bytes]u8 = undefined;
    const executable = resolveExecutable(io, options, &executable_buffer) orelse return .unavailable;
    var cwd_dir = std.Io.Dir.openDir(.cwd(), io, options.cwd, .{}) catch return .unavailable;
    defer cwd_dir.close(io);

    var context: ProductionExecutor = .{
        .io = io,
        .cwd = cwd_dir,
        .environ = options.environ,
        .timeout = options.timeout,
    };
    return composeProbe(allocator, executable, .{
        .context = &context,
        .execute_fn = ProductionExecutor.execute,
    });
}

const ProductionExecutor = struct {
    io: std.Io,
    cwd: std.Io.Dir,
    environ: *const std.process.Environ.Map,
    timeout: std.Io.Duration,

    fn execute(
        context: *anyopaque,
        argv: []const []const u8,
        output: *[maximum_output_bytes]u8,
    ) Error!CommandOutput {
        const self: *ProductionExecutor = @ptrCast(@alignCast(context));
        return runGit(self.io, self.cwd, self.environ, argv, self.timeout, output);
    }
};

/// Builds allocator-owned fields from independent borrowed command outputs.
/// On OOM, all fields already allocated by this function are released.
fn composeProbe(
    allocator: std.mem.Allocator,
    executable: []const u8,
    executor: CommandExecutor,
) Error!Result {
    var state: State = .{};
    errdefer state.deinit(allocator);
    var output_buffer: [maximum_output_bytes]u8 = undefined;
    // symbolic-ref, rather than rev-parse --abbrev-ref, makes detached HEAD
    // an error instead of returning the literal branch name "HEAD".
    const branch_args = [_][]const u8{ executable, "symbolic-ref", "--quiet", "--short", "HEAD" };
    switch (try executor.execute(&branch_args, &output_buffer)) {
        .failed, .timeout => {},
        .success => |length| state.branch = try dupeValid(allocator, visibleOutput(output_buffer[0..length])),
    }

    const head_args = [_][]const u8{ executable, "log", "-1", "--format=%h%n%s" };
    switch (try executor.execute(&head_args, &output_buffer)) {
        .failed, .timeout => {},
        .success => |length| try applyHead(allocator, &state, visibleOutput(output_buffer[0..length])),
    }

    if (state.branch == null and state.commit == null and state.subject == null) {
        state.deinit(allocator);
        return .unavailable;
    }
    return .{ .available = state };
}

/// Adapter for persistence.SessionFile.GitProbe. The returned collaborator
/// borrows this value and its Options for its full lifetime.
pub const SessionAdapter = struct {
    options: Options,

    pub fn probe(
        self: *SessionAdapter,
        allocator: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
    ) error{ OutOfMemory, Cancelled, Unavailable }!persistence.SessionFile.GitState {
        var options = self.options;
        options.cwd = cwd;
        var result = try GitProbe.probe(allocator, io, options);
        defer result.deinit(allocator);
        return switch (result) {
            .unavailable => error.Unavailable,
            .available => |state| state.toSessionFile(allocator),
        };
    }
};

const GitProbe = @This();

const PreflightFailure = enum { invalid_path, path_too_long, invalid_timeout };

fn preflightOptions(options: Options) ?PreflightFailure {
    if (!canonicalAbsolute(options.cwd)) return .invalid_path;
    if (options.cwd.len >= std.fs.max_path_bytes) return .path_too_long;
    if (options.timeout.nanoseconds <= 0 or options.timeout.nanoseconds > default_timeout.nanoseconds) {
        return .invalid_timeout;
    }

    if (options.git_executable) |executable| {
        if (!canonicalAbsolute(executable)) return .invalid_path;
        if (executable.len >= std.fs.max_path_bytes) return .path_too_long;
        return null;
    }
    const path = options.path orelse return null;
    // PATH is not itself passed to a pathname syscall, so its inclusive logical
    // cap is independent of the sentinel byte required by each candidate.
    if (path.len > maximum_path_bytes) return .path_too_long;
    if (!validSearchPath(path)) return .invalid_path;
    return null;
}

fn executablePathLength(directory: []const u8) ?usize {
    if (directory.len == 1) return "git".len + 1;
    return std.math.add(usize, directory.len, "/git".len) catch null;
}

fn resolveExecutable(io: std.Io, options: Options, buffer: []u8) ?[]const u8 {
    return resolveExecutableChecking(io, options, buffer, regularExecutable);
}

fn resolveExecutableChecking(
    io: std.Io,
    options: Options,
    buffer: []u8,
    is_executable: *const fn (std.Io, []const u8) bool,
) ?[]const u8 {
    if (options.git_executable) |path| {
        if (!canonicalAbsolute(path) or path.len >= std.fs.max_path_bytes or path.len > buffer.len) return null;
        @memcpy(buffer[0..path.len], path);
        return if (is_executable(io, buffer[0..path.len])) buffer[0..path.len] else null;
    }
    var system_path_buffer: [maximum_path_bytes]u8 = undefined;
    const path = options.path orelse systemSearchPath(&system_path_buffer) orelse return null;
    var iterator = std.mem.splitScalar(u8, path, ':');
    while (iterator.next()) |directory| {
        // This is an intentional security narrowing from execvp: empty and
        // relative namespaces never resolve against ambient cwd.
        if (!canonicalAbsolute(directory)) continue;
        const needed = executablePathLength(directory) orelse continue;
        if (needed >= std.fs.max_path_bytes or needed > buffer.len) continue;
        @memcpy(buffer[0..directory.len], directory);
        var end = directory.len;
        if (end != 1) {
            buffer[end] = '/';
            end += 1;
        }
        @memcpy(buffer[end .. end + 3], "git");
        end += 3;
        if (is_executable(io, buffer[0..end])) return buffer[0..end];
    }
    return null;
}

fn regularExecutable(io: std.Io, path: []const u8) bool {
    if (path.len >= std.fs.max_path_bytes or std.mem.findScalar(u8, path, 0) != null) return false;
    const file = std.Io.Dir.openFile(.cwd(), io, path, .{}) catch return false;
    defer file.close(io);
    const stat = file.stat(io) catch return false;
    if (stat.kind != .file) return false;
    if (comptime std.Io.File.Permissions.has_executable_bit) {
        return stat.permissions.toMode() & 0o111 != 0;
    }
    return true;
}

fn systemSearchPath(buffer: *[maximum_path_bytes]u8) ?[]const u8 {
    const configured: []const u8 = switch (builtin.target.os.tag) {
        .linux => if (builtin.target.abi.isMusl())
            "/usr/local/bin:/bin:/usr/bin"
        else if (builtin.target.abi.isGnu())
            "/bin:/usr/bin"
        else
            return null,
        .macos, .freebsd, .netbsd, .openbsd, .dragonfly => c._PATH_DEFPATH,
        else => return null,
    };
    if (configured.len == 0 or configured.len > buffer.len) return null;
    @memcpy(buffer[0..configured.len], configured);
    const path = buffer[0..configured.len];
    return if (validSearchPath(path)) path else null;
}

fn validSearchPath(path: []const u8) bool {
    if (path.len == 0 or std.mem.findScalar(u8, path, 0) != null) return false;
    var iterator = std.mem.splitScalar(u8, path, ':');
    while (iterator.next()) |directory| if (!canonicalAbsolute(directory)) return false;
    return true;
}

fn canonicalAbsolute(path: []const u8) bool {
    if (path.len == 0 or path[0] != '/' or std.mem.findScalar(u8, path, 0) != null) return false;
    if (path.len > 1 and path[path.len - 1] == '/') return false;
    if (path.len == 1) return true;
    var components = std.mem.splitScalar(u8, path[1..], '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

fn runGit(
    io: std.Io,
    cwd: std.Io.Dir,
    environ: *const std.process.Environ.Map,
    argv: []const []const u8,
    timeout: std.Io.Duration,
    output: *[maximum_output_bytes]u8,
) Error!CommandOutput {
    // The supplied absolute PATH namespace is trusted not to be replaced
    // between stat and exec. std.process requires the resolved absolute path
    // as argv[0], an observable deviation from execvp's bare "git" argv[0].
    // TODO: separate exec path from argv[0] when std.process exposes that safely
    // without duplicating the coordinated fork/exec seam.
    var guard = ProcessSpawn.lock(io);
    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .environ_map = environ,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
        .pgid = 0,
    }) catch |err| {
        guard.deinit();
        return switch (err) {
            error.Canceled => error.Cancelled,
            else => .failed,
        };
    };
    guard.deinit();
    const process_group: std.posix.pid_t = child.id.?;
    // Final same-group cleanup runs only after the command task has captured
    // term or has been canceled and joined on every path below.
    defer killGroup(process_group);

    var buffer: [2]Selection = undefined;
    var select = std.Io.Select(Selection).init(io, &buffer);
    select.async(.command, captureAndWait, .{ io, &child, process_group });
    // Like pinned hax, the one-second deadline starts after coordinated
    // fork/exec setup, not while the process-spawn lock is held.
    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .raw = timeout, .clock = .awake });
    select.async(.timeout, sleepUntil, .{ io, deadline });
    const first = select.await() catch {
        killGroup(process_group);
        select.cancelDiscard();
        return error.Cancelled;
    };
    switch (first) {
        .timeout => |outcome| {
            outcome catch |err| switch (err) {
                error.Canceled => {
                    killGroup(process_group);
                    select.cancelDiscard();
                    return error.Cancelled;
                },
            };
            // Only the command task owns Child. Cancel its read after killing
            // the original group: an escaped descendant may still retain stdout.
            // cancelDiscard joins the task, whose defer directly kills/reaps.
            killGroup(process_group);
            select.cancelDiscard();
            return .timeout;
        },
        .command => |outcome| {
            // Child is already reaped before the timer is canceled.
            select.cancelDiscard();
            const command = outcome catch |err| switch (err) {
                error.Canceled => return error.Cancelled,
                error.Failed => return .failed,
            };
            if (command.overflow or command.length == 0) return .failed;
            switch (command.term) {
                .exited => |code| if (code != 0) return .failed,
                else => return .failed,
            }
            @memcpy(output[0..command.length], command.bytes[0..command.length]);
            return .{ .success = command.length };
        },
    }
}

fn sleepUntil(io: std.Io, deadline: std.Io.Clock.Timestamp) error{Canceled}!void {
    return deadline.wait(io);
}

fn captureAndWait(
    io: std.Io,
    child: *std.process.Child,
    process_group: std.posix.pid_t,
) RunError!CommandResult {
    // This task exclusively owns every Child mutation through direct reap.
    defer child.kill(io);
    const stdout = child.stdout.?;
    var result: CommandResult = .{};
    while (result.length < result.bytes.len) {
        const read = stdout.readStreaming(io, &.{result.bytes[result.length..]}) catch |err| switch (err) {
            error.EndOfStream => break,
            error.Canceled => return error.Canceled,
            else => return error.Failed,
        };
        if (read == 0) continue;
        result.length += read;
    }
    if (result.length > maximum_output_bytes) {
        result.overflow = true;
        killGroup(process_group);
        child.kill(io);
        result.term = .{ .exited = 1 };
        return result;
    }
    result.term = child.wait(io) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return error.Failed,
    };
    return result;
}

fn killGroup(process_group: std.posix.pid_t) void {
    if (process_group <= 0) return;
    std.posix.kill(-process_group, .KILL) catch return;
}

fn visibleOutput(raw: []const u8) []const u8 {
    const nul = std.mem.findScalar(u8, raw, 0) orelse raw.len;
    var end = nul;
    while (end > 0 and (raw[end - 1] == '\n' or raw[end - 1] == '\r')) end -= 1;
    return raw[0..end];
}

fn applyHead(allocator: std.mem.Allocator, state: *State, visible: []const u8) Error!void {
    if (std.mem.findScalar(u8, visible, '\n')) |newline| {
        state.commit = try dupeValid(allocator, visible[0..newline]);
        state.subject = try dupeValid(allocator, visible[newline + 1 ..]);
    } else {
        state.commit = try dupeValid(allocator, visible);
    }
}

fn dupeValid(allocator: std.mem.Allocator, value: []const u8) Error!?[]u8 {
    if (!std.unicode.utf8ValidateSlice(value)) return null;
    return allocator.dupe(u8, value) catch error.OutOfMemory;
}

fn exerciseHeadAllocations(allocator: std.mem.Allocator) !void {
    var state: State = .{};
    defer state.deinit(allocator);
    try applyHead(allocator, &state, "abc1234\nsubject");
}

test "head field allocation failures clean partial ownership" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseHeadAllocations,
        .{},
    );
}

test "absent PATH uses target libc execvp default order" {
    var buffer: [maximum_path_bytes]u8 = undefined;
    const path = systemSearchPath(&buffer) orelse return error.TestUnexpectedResult;
    const expected = switch (builtin.target.os.tag) {
        .macos => "/usr/bin:/bin",
        .linux => if (builtin.target.abi.isMusl())
            "/usr/local/bin:/bin:/usr/bin"
        else if (builtin.target.abi.isGnu())
            "/bin:/usr/bin"
        else
            return,
        else => return,
    };
    try std.testing.expectEqualStrings(expected, path);
}

test "canonical paths reject ambiguous components" {
    try std.testing.expect(canonicalAbsolute("/a/b"));
    try std.testing.expect(canonicalAbsolute("/"));
    try std.testing.expect(!canonicalAbsolute("a/b"));
    try std.testing.expect(!canonicalAbsolute("/a//b"));
    try std.testing.expect(!canonicalAbsolute("/a/../b"));
}

test "syscall paths reserve the sentinel while PATH keeps its inclusive cap" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    const base: Options = .{ .cwd = "/", .environ = &environ, .git_executable = "/git" };

    const cwd_last = try std.testing.allocator.alloc(u8, std.fs.max_path_bytes - 1);
    defer std.testing.allocator.free(cwd_last);
    @memset(cwd_last, 'a');
    cwd_last[0] = '/';
    var options = base;
    options.cwd = cwd_last;
    try std.testing.expectEqual(null, preflightOptions(options));

    const cwd_max = try std.testing.allocator.alloc(u8, std.fs.max_path_bytes);
    defer std.testing.allocator.free(cwd_max);
    @memset(cwd_max, 'a');
    cwd_max[0] = '/';
    options.cwd = cwd_max;
    try std.testing.expectEqual(.path_too_long, preflightOptions(options).?);

    const executable_last = try std.testing.allocator.alloc(u8, std.fs.max_path_bytes - 1);
    defer std.testing.allocator.free(executable_last);
    @memset(executable_last, 'a');
    executable_last[0] = '/';
    options = base;
    options.git_executable = executable_last;
    try std.testing.expectEqual(null, preflightOptions(options));

    const executable_max = try std.testing.allocator.alloc(u8, std.fs.max_path_bytes);
    defer std.testing.allocator.free(executable_max);
    @memset(executable_max, 'a');
    executable_max[0] = '/';
    options.git_executable = executable_max;
    try std.testing.expectEqual(.path_too_long, preflightOptions(options).?);

    const directory_last = try std.testing.allocator.alloc(u8, std.fs.max_path_bytes - 5);
    defer std.testing.allocator.free(directory_last);
    @memset(directory_last, 'a');
    directory_last[0] = '/';
    try std.testing.expectEqual(std.fs.max_path_bytes - 1, executablePathLength(directory_last).?);

    const directory_max = try std.testing.allocator.alloc(u8, std.fs.max_path_bytes - 4);
    defer std.testing.allocator.free(directory_max);
    @memset(directory_max, 'a');
    directory_max[0] = '/';
    try std.testing.expectEqual(std.fs.max_path_bytes, executablePathLength(directory_max).?);

    options = base;
    options.git_executable = null;
    const path_max = try std.testing.allocator.alloc(u8, maximum_path_bytes);
    defer std.testing.allocator.free(path_max);
    @memset(path_max, 'a');
    path_max[0] = '/';
    const split = path_max.len / 2;
    path_max[split] = ':';
    path_max[split + 1] = '/';
    options.path = path_max;
    try std.testing.expectEqual(null, preflightOptions(options));

    const path_over = try std.testing.allocator.alloc(u8, maximum_path_bytes + 1);
    defer std.testing.allocator.free(path_over);
    @memcpy(path_over[0..maximum_path_bytes], path_max);
    path_over[maximum_path_bytes] = 'a';
    options.path = path_over;
    try std.testing.expectEqual(.path_too_long, preflightOptions(options).?);
}

fn acceptRootGit(_: std.Io, path: []const u8) bool {
    return std.mem.eql(u8, path, "/git");
}

test "executable search skips oversized candidates and preserves first-hit order" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    const oversized = try std.testing.allocator.alloc(u8, std.fs.max_path_bytes - 4);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'a');
    oversized[0] = '/';
    var buffer: [maximum_path_bytes]u8 = undefined;

    const oversized_first = try std.fmt.allocPrint(std.testing.allocator, "{s}:/", .{oversized});
    defer std.testing.allocator.free(oversized_first);
    const after_oversized = resolveExecutableChecking(std.testing.io, .{
        .cwd = "/",
        .environ = &environ,
        .path = oversized_first,
    }, &buffer, acceptRootGit).?;
    try std.testing.expectEqualStrings("/git", after_oversized);

    const valid_first = try std.fmt.allocPrint(std.testing.allocator, "/:{s}", .{oversized});
    defer std.testing.allocator.free(valid_first);
    const before_oversized = resolveExecutableChecking(std.testing.io, .{
        .cwd = "/",
        .environ = &environ,
        .path = valid_first,
    }, &buffer, acceptRootGit).?;
    try std.testing.expectEqualStrings("/git", before_oversized);
}

test "preflight reports syntax before bounds and bounds before timeout" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    const invalid_long = try std.testing.allocator.alloc(u8, std.fs.max_path_bytes);
    defer std.testing.allocator.free(invalid_long);
    @memset(invalid_long, 'a');

    try std.testing.expectEqual(.invalid_path, preflightOptions(.{
        .cwd = invalid_long,
        .environ = &environ,
        .git_executable = "/git",
        .timeout = .fromNanoseconds(0),
    }).?);
    invalid_long[0] = '/';
    try std.testing.expectEqual(.path_too_long, preflightOptions(.{
        .cwd = invalid_long,
        .environ = &environ,
        .git_executable = "/git",
        .timeout = .fromNanoseconds(0),
    }).?);
}

fn temporaryRoot(tmp: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
    const length = try tmp.dir.realPath(std.testing.io, buffer);
    return buffer[0..length];
}

fn writeExecutable(dir: std.Io.Dir, path: []const u8, source: []const u8) !void {
    const file = try dir.createFile(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, source);
    try file.setPermissions(std.testing.io, .fromMode(0o700));
}

test "fake git snapshot preserves branch head and subject" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "bin with spaces", .default_dir);
    try tmp.dir.createDir(io, ".git", .default_dir);
    try writeExecutable(tmp.dir, "bin with spaces/git", "#!/bin/sh\n" ++
        "case \"$1\" in\n" ++
        "symbolic-ref) printf 'topic/name\\n';;\n" ++
        "log) printf 'abc1234\\nSubject line\\n';;\n" ++
        "esac\n");
    var root_buffer: [maximum_path_bytes]u8 = undefined;
    const root = try temporaryRoot(&tmp, &root_buffer);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/bin with spaces", .{root});
    defer std.testing.allocator.free(path);
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();

    var result = try probe(std.testing.allocator, io, .{
        .cwd = root,
        .environ = &environ,
        .path = path,
    });
    defer result.deinit(std.testing.allocator);
    const state = result.available;
    try std.testing.expectEqualStrings("topic/name", state.branch.?);
    try std.testing.expectEqualStrings("abc1234", state.commit.?);
    try std.testing.expectEqualStrings("Subject line", state.subject.?);
}

test "timeout is typed unavailable and child is reaped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeExecutable(tmp.dir, "git", "#!/bin/sh\n/bin/sleep 5\n");
    var root_buffer: [maximum_path_bytes]u8 = undefined;
    const root = try temporaryRoot(&tmp, &root_buffer);
    const executable = try std.fmt.allocPrint(std.testing.allocator, "{s}/git", .{root});
    defer std.testing.allocator.free(executable);
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    var result = try probe(std.testing.allocator, std.testing.io, .{
        .cwd = root,
        .environ = &environ,
        .git_executable = executable,
        .timeout = .fromMilliseconds(20),
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result == .unavailable);
}

test "leading NUL is a present owned empty field while zero output is absent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeExecutable(tmp.dir, "git", "#!/bin/sh\n" ++
        "[ \"$1\" = symbolic-ref ] || exit 0\n" ++
        "printf '\\000ignored'\n");
    var root_buffer: [maximum_path_bytes]u8 = undefined;
    const root = try temporaryRoot(&tmp, &root_buffer);
    const executable = try std.fmt.allocPrint(std.testing.allocator, "{s}/git", .{root});
    defer std.testing.allocator.free(executable);
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    var result = try probe(std.testing.allocator, std.testing.io, .{
        .cwd = root,
        .environ = &environ,
        .git_executable = executable,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.available.branch != null);
    try std.testing.expectEqual(@as(usize, 0), result.available.branch.?.len);
    try std.testing.expect(result.available.commit == null);
    try std.testing.expect(result.available.subject == null);
}

test "exact cap is accepted and cap plus one is unavailable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var root_buffer: [maximum_path_bytes]u8 = undefined;
    const root = try temporaryRoot(&tmp, &root_buffer);
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();

    try writeExecutable(tmp.dir, "git", "#!/bin/sh\n" ++
        "[ \"$1\" = symbolic-ref ] || exit 1\n" ++
        "i=0; while [ $i -lt 819 ]; do printf aaaaaaaaaa; i=$((i+1)); done; printf aa\n");
    const executable = try std.fmt.allocPrint(std.testing.allocator, "{s}/git", .{root});
    defer std.testing.allocator.free(executable);
    var exact = try probe(std.testing.allocator, io, .{
        .cwd = root,
        .environ = &environ,
        .git_executable = executable,
    });
    defer exact.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, maximum_output_bytes), exact.available.branch.?.len);

    try writeExecutable(tmp.dir, "git", "#!/bin/sh\n" ++
        "[ \"$1\" = symbolic-ref ] || exit 1\n" ++
        "i=0; while [ $i -lt 819 ]; do printf aaaaaaaaaa; i=$((i+1)); done; printf aaa\n");
    var overflow = try probe(std.testing.allocator, io, .{
        .cwd = root,
        .environ = &environ,
        .git_executable = executable,
    });
    defer overflow.deinit(std.testing.allocator);
    try std.testing.expect(overflow == .unavailable);
}

test "invalid subject is omitted without losing valid commit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeExecutable(tmp.dir, "git", "#!/bin/sh\n" ++
        "[ \"$1\" = log ] || exit 1\n" ++
        "printf 'abc1234\\n\\377\\n'\n");
    var root_buffer: [maximum_path_bytes]u8 = undefined;
    const root = try temporaryRoot(&tmp, &root_buffer);
    const executable = try std.fmt.allocPrint(std.testing.allocator, "{s}/git", .{root});
    defer std.testing.allocator.free(executable);
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    var result = try probe(std.testing.allocator, std.testing.io, .{
        .cwd = root,
        .environ = &environ,
        .git_executable = executable,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("abc1234", result.available.commit.?);
    try std.testing.expect(result.available.subject == null);
}

const StubOutcome = union(enum) { timeout, success: []const u8 };

const StubExecutor = struct {
    branch: StubOutcome,
    head: StubOutcome,

    fn executor(self: *StubExecutor) CommandExecutor {
        return .{ .context = self, .execute_fn = execute };
    }

    fn execute(
        context: *anyopaque,
        argv: []const []const u8,
        output: *[maximum_output_bytes]u8,
    ) Error!CommandOutput {
        const self: *StubExecutor = @ptrCast(@alignCast(context));
        const outcome = if (std.mem.eql(u8, argv[1], "symbolic-ref")) self.branch else self.head;
        return switch (outcome) {
            .timeout => .timeout,
            .success => |bytes| success: {
                if (bytes.len > output.len) break :success .failed;
                @memcpy(output[0..bytes.len], bytes);
                break :success .{ .success = bytes.len };
            },
        };
    }
};

fn exerciseCompositionAllocations(allocator: std.mem.Allocator) !void {
    var stub: StubExecutor = .{
        .branch = .{ .success = "topic\n" },
        .head = .{ .success = "abc1234\nsubject\n" },
    };
    var result = try composeProbe(allocator, "/git", stub.executor());
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("topic", result.available.branch.?);
    try std.testing.expectEqualStrings("abc1234", result.available.commit.?);
    try std.testing.expectEqualStrings("subject", result.available.subject.?);
}

test "probe composition cleans owned fields on allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseCompositionAllocations,
        .{},
    );
}

test "field timeouts preserve the independent successful probe" {
    var head_stub: StubExecutor = .{
        .branch = .timeout,
        .head = .{ .success = "abc1234\nsubject\n" },
    };
    var head = try composeProbe(std.testing.allocator, "/git", head_stub.executor());
    defer head.deinit(std.testing.allocator);
    try std.testing.expect(head.available.branch == null);
    try std.testing.expectEqualStrings("abc1234", head.available.commit.?);
    try std.testing.expectEqualStrings("subject", head.available.subject.?);

    var branch_stub: StubExecutor = .{
        .branch = .{ .success = "topic\n" },
        .head = .timeout,
    };
    var branch = try composeProbe(std.testing.allocator, "/git", branch_stub.executor());
    defer branch.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("topic", branch.available.branch.?);
    try std.testing.expect(branch.available.commit == null);
    try std.testing.expect(branch.available.subject == null);
}

fn waitProcessGone(io: std.Io, pid: std.posix.pid_t) !void {
    for (0..100) |_| {
        std.posix.kill(pid, .CONT) catch return;
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    return error.TestUnexpectedResult;
}

test "timeout includes wait after stdout closes and kills the whole process group" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var root_buffer: [maximum_path_bytes]u8 = undefined;
    const root = try temporaryRoot(&tmp, &root_buffer);
    const executable = try std.fmt.allocPrint(std.testing.allocator, "{s}/git", .{root});
    defer std.testing.allocator.free(executable);
    const pid_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/pids", .{root});
    defer std.testing.allocator.free(pid_path);
    const script = try std.fmt.allocPrint(
        std.testing.allocator,
        "#!/bin/sh\n" ++
            "[ \"$1\" = symbolic-ref ] || exit 1\n" ++
            "exec 1>&-\n" ++
            "/bin/sleep 30 & descendant=$!\n" ++
            "printf '%s %s\\n' \"$$\" \"$descendant\" > '{s}'\n" ++
            "wait\n",
        .{pid_path},
    );
    defer std.testing.allocator.free(script);
    try writeExecutable(tmp.dir, "git", script);
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();

    var result = try probe(std.testing.allocator, io, .{
        .cwd = root,
        .environ = &environ,
        .git_executable = executable,
        .timeout = default_timeout,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result == .unavailable);

    const recorded = try std.Io.Dir.readFileAlloc(.cwd(), io, pid_path, std.testing.allocator, .limited(128));
    defer std.testing.allocator.free(recorded);
    var fields = std.mem.tokenizeAny(u8, recorded, " \r\n");
    const direct = try std.fmt.parseInt(std.posix.pid_t, fields.next().?, 10);
    const descendant = try std.fmt.parseInt(std.posix.pid_t, fields.next().?, 10);
    _ = direct; // Child ownership is proven by captureAndWait's completed join.
    try waitProcessGone(io, descendant);
}

test "successful field reaps direct child then removes a closed-stdout descendant" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var root_buffer: [maximum_path_bytes]u8 = undefined;
    const root = try temporaryRoot(&tmp, &root_buffer);
    const executable = try std.fmt.allocPrint(std.testing.allocator, "{s}/git", .{root});
    defer std.testing.allocator.free(executable);
    const pid_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/success-pid", .{root});
    defer std.testing.allocator.free(pid_path);
    const script = try std.fmt.allocPrint(
        std.testing.allocator,
        "#!/bin/sh\n" ++
            "[ \"$1\" = symbolic-ref ] || exit 1\n" ++
            "(/bin/sleep 30) </dev/null >/dev/null 2>&1 & descendant=$!\n" ++
            "printf '%s\\n' \"$descendant\" > '{s}'\n" ++
            "printf 'topic\\n'\n" ++
            "exit 0\n",
        .{pid_path},
    );
    defer std.testing.allocator.free(script);
    try writeExecutable(tmp.dir, "git", script);
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();

    var result = try probe(std.testing.allocator, io, .{
        .cwd = root,
        .environ = &environ,
        .git_executable = executable,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("topic", result.available.branch.?);

    const recorded = try std.Io.Dir.readFileAlloc(.cwd(), io, pid_path, std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(recorded);
    const descendant = try std.fmt.parseInt(
        std.posix.pid_t,
        std.mem.trim(u8, recorded, " \r\n"),
        10,
    );
    try waitProcessGone(io, descendant);
}

test "timeout cancels capture when a setsid descendant escapes with stdout" {
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var root_buffer: [maximum_path_bytes]u8 = undefined;
    const root = try temporaryRoot(&tmp, &root_buffer);
    const executable = try std.fmt.allocPrint(std.testing.allocator, "{s}/git", .{root});
    defer std.testing.allocator.free(executable);
    const pid_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/escaped-pids", .{root});
    defer std.testing.allocator.free(pid_path);
    const script = try std.fmt.allocPrint(
        std.testing.allocator,
        "#!/bin/sh\n" ++
            "[ \"$1\" = symbolic-ref ] || exit 1\n" ++
            "exec /usr/bin/python3 -c \"import os,time\n" ++
            "child=os.fork()\n" ++
            "if child == 0:\n" ++
            " os.setsid()\n" ++
            " time.sleep(30)\n" ++
            " os._exit(0)\n" ++
            "with open('{s}','w') as f: f.write(str(os.getpid())+' '+str(child))\n" ++
            "print('topic', flush=True)\"\n",
        .{pid_path},
    );
    defer std.testing.allocator.free(script);
    try writeExecutable(tmp.dir, "git", script);
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();

    const started = std.Io.Clock.awake.now(io);
    var result = try probe(std.testing.allocator, io, .{
        .cwd = root,
        .environ = &environ,
        .git_executable = executable,
        .timeout = default_timeout,
    });
    defer result.deinit(std.testing.allocator);
    const elapsed = started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
    try std.testing.expect(elapsed < 2000);

    const recorded = try std.Io.Dir.readFileAlloc(.cwd(), io, pid_path, std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(recorded);
    var fields = std.mem.tokenizeAny(u8, recorded, " \r\n");
    const direct = try std.fmt.parseInt(std.posix.pid_t, fields.next().?, 10);
    const escaped = try std.fmt.parseInt(std.posix.pid_t, fields.next().?, 10);
    try waitProcessGone(io, direct);
    std.posix.kill(escaped, .CONT) catch return error.TestUnexpectedResult;
    try std.posix.kill(escaped, .KILL);
    try waitProcessGone(io, escaped);
}
