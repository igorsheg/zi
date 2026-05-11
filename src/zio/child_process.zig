const std = @import("std");
const builtin = @import("builtin");
const Group = @import("task.zig").Group;

pub const EnvPair = struct {
    key: []const u8,
    value: []const u8,
};

/// Owned adapter around one OS child process.
///
/// Owns spawn/wait, live stdin, concurrent stdout/stderr draining, process-group
/// termination, and event delivery. Higher-level modules decide whether events
/// become captured output (`zio.process`) or long-running job events (`zio.process.Jobs`).
pub const StreamKind = enum { stdout, stderr };

/// Child process event delivered synchronously to `EventSink.submit`.
///
/// `stdout`/`stderr` byte slices are temporary reader stack buffers. A sink that
/// retains event data after `submit` returns must copy it first.
pub const Event = union(enum) {
    stdout: []const u8,
    stderr: []const u8,
    exit: ?std.process.Child.Term,
    spawn_failed,
};

/// Synchronous event consumer. Returning `false` only reports backpressure to
/// the caller; `ChildProcess` keeps draining to avoid pipe deadlock.
pub const EventSink = struct {
    ptr: *anyopaque,
    submit: *const fn (ptr: *anyopaque, event: Event) bool,
};

pub const StartFailure = enum {
    stdout_reader,
    stderr_reader,
};

/// Borrowed child start configuration. All slices (`argv`, `cwd`, `env` and env
/// pair members) must outlive `ChildProcess.start()` through `wait()`.
pub const StartRequest = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    env: []const EnvPair = &.{},
    clear_env: bool = false,
    process_group: bool = true,
    stdin: bool = true,
    close_stdin_before_wait: bool = false,
    stdout: bool = true,
    stderr: bool = true,
};

pub const ChildProcess = struct {
    io: std.Io,
    request: StartRequest,
    sink: EventSink,
    tasks: Group = undefined,
    started: bool = false,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    child_id: ?std.process.Child.Id = null,
    stdin_file: ?std.Io.File = null,
    ready: bool = false,
    exited: bool = false,
    close_stdin_requested: bool = false,
    stop_requested: bool = false,

    pub fn init(io: std.Io, request: StartRequest, sink: EventSink) ChildProcess {
        return .{ .io = io, .request = request, .sink = sink };
    }

    pub fn start(self: *ChildProcess) !void {
        if (self.started) return;
        self.tasks = Group.init(std.heap.smp_allocator, self.io);
        errdefer self.tasks.cancel();
        try self.tasks.spawnThread(run, .{self});
        self.started = true;
    }

    pub fn wait(self: *ChildProcess) void {
        if (!self.started) return;
        self.tasks.join() catch {};
        self.started = false;
    }

    pub fn stop(self: *ChildProcess) void {
        self.mutex.lockUncancelable(self.io);
        self.stop_requested = true;
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);
    }

    pub fn childId(self: *ChildProcess) ?std.process.Child.Id {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.child_id;
    }

    pub fn isExited(self: *ChildProcess) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.exited;
    }

    pub fn waitReady(self: *ChildProcess, timeout_ms: u64) bool {
        var waited: u64 = 0;
        while (waited <= timeout_ms) : (waited += 1) {
            self.mutex.lockUncancelable(self.io);
            const ready = self.ready;
            const exited = self.exited;
            self.mutex.unlock(self.io);
            if (ready) return true;
            if (exited) return false;
            self.io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
        return false;
    }

    pub fn write(self: *ChildProcess, data: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        const file = self.stdin_file orelse {
            self.mutex.unlock(self.io);
            return error.ProcessNotReady;
        };
        self.mutex.unlock(self.io);
        try file.writeStreamingAll(self.io, data);
    }

    pub fn closeStdin(self: *ChildProcess) void {
        self.mutex.lockUncancelable(self.io);
        self.close_stdin_requested = true;
        self.mutex.unlock(self.io);
    }

    fn run(self: *ChildProcess) void {
        var env_map_storage: ?std.process.Environ.Map = null;
        defer if (env_map_storage) |*env_map| env_map.deinit();
        if (self.request.env.len > 0 or self.request.clear_env) {
            env_map_storage = std.process.Environ.Map.init(std.heap.page_allocator);
            for (self.request.env) |pair| {
                env_map_storage.?.put(pair.key, pair.value) catch {
                    _ = self.sink.submit(self.sink.ptr, .spawn_failed);
                    self.markExited();
                    return;
                };
            }
        }

        var child = std.process.spawn(self.io, .{
            .argv = self.request.argv,
            .cwd = if (self.request.cwd) |cwd| .{ .path = cwd } else .inherit,
            .environ_map = if (env_map_storage) |*env_map| env_map else null,
            .stdin = if (self.request.stdin) .pipe else .ignore,
            .stdout = if (self.request.stdout) .pipe else .ignore,
            .stderr = if (self.request.stderr) .pipe else .ignore,
            .pgid = if (self.request.process_group and supportsProcessGroups()) 0 else null,
        }) catch {
            _ = self.sink.submit(self.sink.ptr, .spawn_failed);
            self.markExited();
            return;
        };

        self.mutex.lockUncancelable(self.io);
        self.child_id = child.id;
        self.stdin_file = child.stdin;
        self.ready = true;
        const stop_requested = self.stop_requested;
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);

        var readers = Group.init(std.heap.smp_allocator, self.io);
        defer readers.cancel();

        readers.spawnThread(terminationWatcher, .{ self, child.id.? }) catch {
            self.terminateOwnedChild(child.id.?);
            _ = child.wait(self.io) catch null;
            self.markExited();
            _ = self.sink.submit(self.sink.ptr, .spawn_failed);
            return;
        };

        if (stop_requested) self.condition.broadcast(self.io);

        if (child.stdout) |stdout_file| {
            child.stdout = null;
            readers.spawnThread(readPipe, .{ self, stdout_file, StreamKind.stdout }) catch {
                stdout_file.close(self.io);
                self.handleStartFailure(&child, &readers, .stdout_reader);
                return;
            };
        }
        if (child.stderr) |stderr_file| {
            child.stderr = null;
            readers.spawnThread(readPipe, .{ self, stderr_file, StreamKind.stderr }) catch {
                stderr_file.close(self.io);
                self.handleStartFailure(&child, &readers, .stderr_reader);
                return;
            };
        }

        if (self.request.close_stdin_before_wait) {
            var waited: u64 = 0;
            while (waited < 5000) : (waited += 1) {
                self.mutex.lockUncancelable(self.io);
                const close_requested = self.close_stdin_requested;
                self.mutex.unlock(self.io);
                if (close_requested) break;
                self.io.sleep(.fromMilliseconds(1), .awake) catch {};
            }
            if (child.stdin) |stdin_file| {
                stdin_file.close(self.io);
                child.stdin = null;
                self.mutex.lockUncancelable(self.io);
                self.stdin_file = null;
                self.mutex.unlock(self.io);
            }
        }

        const term = child.wait(self.io) catch null;
        self.mutex.lockUncancelable(self.io);
        self.child_id = null;
        self.stdin_file = null;
        self.exited = true;
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);

        readers.join() catch {};

        _ = self.sink.submit(self.sink.ptr, .{ .exit = term });
    }

    fn handleStartFailure(self: *ChildProcess, child: *std.process.Child, readers: *Group, failure: StartFailure) void {
        _ = failure;
        if (child.id) |pid| self.terminateOwnedChild(pid);
        readers.join() catch {};
        _ = child.wait(self.io) catch null;
        self.mutex.lockUncancelable(self.io);
        self.child_id = null;
        self.stdin_file = null;
        self.exited = true;
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);
        _ = self.sink.submit(self.sink.ptr, .spawn_failed);
    }

    fn markExited(self: *ChildProcess) void {
        self.mutex.lockUncancelable(self.io);
        self.exited = true;
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);
    }

    fn terminationWatcher(self: *ChildProcess, child_id: std.process.Child.Id) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        while (!self.stop_requested and self.child_id == child_id and !self.exited) {
            self.condition.waitUncancelable(self.io, &self.mutex);
        }
        if (!self.stop_requested or self.child_id != child_id or self.exited) return;

        self.mutex.unlock(self.io);
        self.terminateOwnedChild(child_id);
        self.mutex.lockUncancelable(self.io);
    }

    fn terminateOwnedChild(self: *ChildProcess, child_id: std.process.Child.Id) void {
        killChild(child_id, self.request.process_group, .TERM);
        self.io.sleep(.fromMilliseconds(100), .awake) catch {};
        self.mutex.lockUncancelable(self.io);
        const still_current = self.child_id == child_id and !self.exited;
        self.mutex.unlock(self.io);
        if (still_current) killChild(child_id, self.request.process_group, .KILL);
    }

    fn readPipe(self: *ChildProcess, file: std.Io.File, kind: StreamKind) void {
        defer file.close(self.io);
        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            const n = std.posix.read(file.handle, &buf) catch return;
            if (n == 0) return;
            const bytes = buf[0..n];
            _ = self.sink.submit(self.sink.ptr, switch (kind) {
                .stdout => .{ .stdout = bytes },
                .stderr => .{ .stderr = bytes },
            });
        }
    }
};

fn supportsProcessGroups() bool {
    return builtin.os.tag != .windows and builtin.os.tag != .wasi;
}

fn killChild(child_id: std.process.Child.Id, process_group: bool, sig: std.posix.SIG) void {
    if (process_group and supportsProcessGroups()) {
        const group_pid: std.posix.pid_t = -@as(std.posix.pid_t, @intCast(child_id));
        std.posix.kill(group_pid, sig) catch {};
    } else {
        std.posix.kill(child_id, sig) catch {};
    }
}
