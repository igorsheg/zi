const std = @import("std");
const process_common = @import("process_common.zig");
const process_env = @import("process_env.zig");
const Group = @import("task.zig").Group;
const fd_util = @import("fd.zig");
const types = @import("process_engine_types.zig");
const logging = @import("../logging.zig");

const log = std.log.scoped(.zio_process_blocking);

pub const EnvPair = types.EnvPair;
pub const StreamKind = types.StreamKind;
pub const Event = types.Event;
pub const EventSink = types.EventSink;
pub const StartRequest = types.StartRequest;

pub const Engine = struct {
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
    timed_out: bool = false,
    aborted: bool = false,

    pub const StopReason = enum { requested, timeout, abort };

    pub fn init(io: std.Io, request: StartRequest, sink: EventSink) Engine {
        return .{ .io = io, .request = request, .sink = sink };
    }

    pub fn start(self: *Engine) !void {
        if (self.started) return;
        std.debug.assert(!self.ready and !self.exited);
        self.tasks = Group.init(std.heap.smp_allocator);
        errdefer self.tasks.cancel();
        try self.tasks.spawnThread(run, .{self});
        self.started = true;
    }

    pub fn join(self: *Engine) void {
        if (!self.started) return;
        self.tasks.join() catch |err| log.warn("process engine task join failed: {}", .{err});
        self.started = false;
    }

    pub fn stop(self: *Engine) void {
        self.stopWithReason(.requested);
    }

    pub fn stopWithReason(self: *Engine, reason: StopReason) void {
        self.mutex.lockUncancelable(self.io);
        self.stop_requested = true;
        switch (reason) {
            .requested => {},
            .timeout => self.timed_out = true,
            .abort => self.aborted = true,
        }
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);
    }

    pub fn didTimeout(self: *Engine) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.timed_out;
    }

    pub fn didAbort(self: *Engine) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.aborted;
    }

    pub fn childId(self: *Engine) ?std.process.Child.Id {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.child_id;
    }

    pub fn isExited(self: *Engine) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.exited;
    }

    pub fn write(self: *Engine, data: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        const file = self.stdin_file orelse {
            self.mutex.unlock(self.io);
            return error.ProcessNotReady;
        };
        self.mutex.unlock(self.io);
        try file.writeStreamingAll(self.io, data);
    }

    pub fn closeStdin(self: *Engine) void {
        self.mutex.lockUncancelable(self.io);
        self.close_stdin_requested = true;
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);
    }

    fn run(self: *Engine) void {
        logging.setThreadLabel(.process_engine);

        var env_map_storage = process_env.buildMap(std.heap.page_allocator, self.request.env, self.request.clear_env) catch {
            _ = self.sink.submit(self.sink.ptr, .spawn_failed);
            self.markExited();
            return;
        };
        defer if (env_map_storage) |*env_map| env_map.deinit();

        var child = std.process.spawn(self.io, .{
            .argv = self.request.argv,
            .cwd = if (self.request.cwd) |cwd| .{ .path = cwd } else .inherit,
            .environ_map = if (env_map_storage) |*env_map| env_map else null,
            .stdin = if (self.request.stdin) .pipe else .ignore,
            .stdout = if (self.request.stdout) .pipe else .ignore,
            .stderr = if (self.request.stderr) .pipe else .ignore,
            .pgid = if (self.request.process_group and process_common.supportsProcessGroups()) 0 else null,
        }) catch {
            _ = self.sink.submit(self.sink.ptr, .spawn_failed);
            self.markExited();
            return;
        };
        defer if (child.stdin) |stdin_file| stdin_file.close(self.io);

        self.mutex.lockUncancelable(self.io);
        self.child_id = child.id;
        self.stdin_file = child.stdin;
        self.ready = true;
        const stop_requested = self.stop_requested;
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);
        _ = self.sink.submit(self.sink.ptr, .ready);

        var readers = Group.init(std.heap.smp_allocator);
        defer readers.cancel();

        if (self.request.timeout_ms != null or !self.request.signal.isNone()) {
            readers.spawnThread(timeoutWatcher, .{self}) catch {
                self.terminateOwnedChild(child.id.?);
                waitChildLogged(self.io, &child, "timeout watcher start failure");
                self.markExited();
                _ = self.sink.submit(self.sink.ptr, .spawn_failed);
                return;
            };
        }

        readers.spawnThread(terminationWatcher, .{ self, child.id.? }) catch {
            self.terminateOwnedChild(child.id.?);
            waitChildLogged(self.io, &child, "termination watcher start failure");
            self.markExited();
            _ = self.sink.submit(self.sink.ptr, .spawn_failed);
            return;
        };

        if (stop_requested) self.condition.broadcast(self.io);

        if (child.stdout) |stdout_file| {
            child.stdout = null;
            setNonblockingLogged(stdout_file.handle, "stdout");
            readers.spawnThread(readPipe, .{ self, stdout_file, StreamKind.stdout }) catch {
                stdout_file.close(self.io);
                self.handleStartFailure(&child, &readers);
                return;
            };
        }
        if (child.stderr) |stderr_file| {
            child.stderr = null;
            setNonblockingLogged(stderr_file.handle, "stderr");
            readers.spawnThread(readPipe, .{ self, stderr_file, StreamKind.stderr }) catch {
                stderr_file.close(self.io);
                self.handleStartFailure(&child, &readers);
                return;
            };
        }

        if (self.request.close_stdin_before_wait) self.waitForCloseStdin(&child);

        const term = child.wait(self.io) catch |err| blk: {
            log.warn("child wait failed: {}", .{err});
            break :blk null;
        };
        self.mutex.lockUncancelable(self.io);
        self.child_id = null;
        self.stdin_file = null;
        self.exited = true;
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);

        readers.join() catch |err| log.warn("process reader task join failed: {}", .{err});

        _ = self.sink.submit(self.sink.ptr, .{ .exit = term });
    }

    fn waitForCloseStdin(self: *Engine, child: *std.process.Child) void {
        var waited: u64 = 0;
        while (waited < 5000) : (waited += 1) {
            self.mutex.lockUncancelable(self.io);
            const done = self.close_stdin_requested or self.stop_requested or self.exited;
            self.mutex.unlock(self.io);
            if (done) break;
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

    fn handleStartFailure(self: *Engine, child: *std.process.Child, readers: *Group) void {
        if (child.stdin) |stdin_file| {
            stdin_file.close(self.io);
            child.stdin = null;
        }
        if (child.stdout) |stdout_file| {
            stdout_file.close(self.io);
            child.stdout = null;
        }
        if (child.stderr) |stderr_file| {
            stderr_file.close(self.io);
            child.stderr = null;
        }
        if (child.id) |pid| self.terminateOwnedChild(pid);
        readers.join() catch |err| log.warn("process reader task join after start failure failed: {}", .{err});
        waitChildLogged(self.io, child, "start failure cleanup");
        self.mutex.lockUncancelable(self.io);
        self.child_id = null;
        self.stdin_file = null;
        self.exited = true;
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);
        _ = self.sink.submit(self.sink.ptr, .spawn_failed);
    }

    fn markExited(self: *Engine) void {
        self.mutex.lockUncancelable(self.io);
        self.exited = true;
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);
    }

    fn terminationWatcher(self: *Engine, child_id: std.process.Child.Id) void {
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

    fn timeoutWatcher(self: *Engine) void {
        const start_ms = std.Io.Clock.awake.now(self.io).toMilliseconds();
        while (true) {
            self.mutex.lockUncancelable(self.io);
            const done = self.exited or self.child_id == null or self.stop_requested;
            self.mutex.unlock(self.io);
            if (done) return;

            if (self.request.signal.isAborted()) {
                self.stopWithReason(.abort);
                return;
            }
            if (self.request.timeout_ms) |ms| {
                const now_ms = std.Io.Clock.awake.now(self.io).toMilliseconds();
                if (now_ms - start_ms >= ms) {
                    self.stopWithReason(.timeout);
                    return;
                }
            }
            self.io.sleep(.fromMilliseconds(10), .awake) catch {};
        }
    }

    fn terminateOwnedChild(self: *Engine, child_id: std.process.Child.Id) void {
        process_common.killChild(child_id, self.request.process_group, .TERM);
        self.io.sleep(.fromMilliseconds(100), .awake) catch {};
        self.mutex.lockUncancelable(self.io);
        const still_current = self.child_id == child_id and !self.exited;
        self.mutex.unlock(self.io);
        if (still_current) process_common.killChild(child_id, self.request.process_group, .KILL);
    }

    fn readPipe(self: *Engine, file: std.Io.File, kind: StreamKind) void {
        defer file.close(self.io);
        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            const n = std.posix.read(file.handle, &buf) catch |err| switch (err) {
                error.WouldBlock => {
                    self.mutex.lockUncancelable(self.io);
                    const done = self.stop_requested and self.exited;
                    self.mutex.unlock(self.io);
                    if (done) return;
                    self.io.sleep(.fromMilliseconds(10), .awake) catch {};
                    continue;
                },
                else => return,
            };
            if (n == 0) return;
            const bytes = buf[0..n];
            _ = self.sink.submit(self.sink.ptr, switch (kind) {
                .stdout => .{ .stdout = bytes },
                .stderr => .{ .stderr = bytes },
            });
        }
    }
};

fn waitChildLogged(io: std.Io, child: *std.process.Child, context: []const u8) void {
    _ = child.wait(io) catch |err| log.warn("child wait failed during {s}: {}", .{ context, err });
}

fn setNonblockingLogged(fd: std.posix.fd_t, stream_name: []const u8) void {
    fd_util.setNonblocking(fd) catch |err| log.warn("failed to set {s} pipe nonblocking: {}", .{ stream_name, err });
}
