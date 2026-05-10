const std = @import("std");
const builtin = @import("builtin");
const TaskGroup = @import("tasks.zig").TaskGroup;

pub const EnvPair = struct {
    key: []const u8,
    value: []const u8,
};

/// Owned adapter around one OS child process.
///
/// Owns spawn/wait, live stdin, concurrent stdout/stderr draining, process-group
/// termination, and event delivery. Higher-level modules decide whether events
/// become captured output (`zio.process`) or long-running job events (`zio.job`).
pub const StreamKind = enum { stdout, stderr };

pub const Event = union(enum) {
    stdout: []const u8,
    stderr: []const u8,
    exit: ?std.process.Child.Term,
    spawn_failed,
};

pub const EventSink = struct {
    ptr: *anyopaque,
    submit: *const fn (ptr: *anyopaque, event: Event) bool,
};

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
    tasks: TaskGroup = undefined,
    started: bool = false,
    mutex: std.Io.Mutex = .init,
    child_id: ?std.process.Child.Id = null,
    stdin_file: ?std.Io.File = null,
    ready: bool = false,
    exited: bool = false,
    close_stdin_requested: bool = false,

    pub fn init(io: std.Io, request: StartRequest, sink: EventSink) ChildProcess {
        return .{ .io = io, .request = request, .sink = sink };
    }

    pub fn start(self: *ChildProcess) !void {
        if (self.started) return;
        self.tasks = TaskGroup.init(self.io);
        errdefer self.tasks.cancel();
        try self.tasks.concurrent(run, .{self});
        self.started = true;
    }

    pub fn wait(self: *ChildProcess) void {
        if (!self.started) return;
        self.tasks.wait() catch {};
        self.started = false;
    }

    pub fn stop(self: *ChildProcess) void {
        self.mutex.lockUncancelable(self.io);
        const child_id = self.child_id;
        const process_group = self.request.process_group;
        self.mutex.unlock(self.io);

        if (child_id) |pid| {
            killChild(pid, process_group, .TERM);
            self.io.sleep(.fromMilliseconds(100), .awake) catch {};
            self.mutex.lockUncancelable(self.io);
            const still_running = self.child_id == pid;
            self.mutex.unlock(self.io);
            if (still_running) killChild(pid, process_group, .KILL);
        }
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
        self.mutex.unlock(self.io);

        var readers = TaskGroup.init(self.io);
        defer readers.cancel();
        if (child.stdout) |stdout_file| {
            readers.concurrent(readPipe, .{ self, stdout_file, StreamKind.stdout }) catch {};
        }
        if (child.stderr) |stderr_file| {
            readers.concurrent(readPipe, .{ self, stderr_file, StreamKind.stderr }) catch {};
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

        readers.wait() catch {};
        const term = child.wait(self.io) catch null;

        self.mutex.lockUncancelable(self.io);
        self.child_id = null;
        self.stdin_file = null;
        self.exited = true;
        self.mutex.unlock(self.io);

        _ = self.sink.submit(self.sink.ptr, .{ .exit = term });
    }

    fn markExited(self: *ChildProcess) void {
        self.mutex.lockUncancelable(self.io);
        self.exited = true;
        self.mutex.unlock(self.io);
    }

    fn readPipe(self: *ChildProcess, file: std.Io.File, kind: StreamKind) void {
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
