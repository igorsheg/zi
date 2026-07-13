const std = @import("std");
const builtin = @import("builtin");
const async_runtime = @import("Runtime.zig");
const Runtime = async_runtime.Runtime;
const Mutex = async_runtime.Mutex;
const WakeEvent = @import("wake_event.zig").WakeEvent;

const chunk_bytes_max = 4096;
const output_queue_capacity = 64;
const application_queue_capacity = 24;
const application_bytes_max = 15 * 1024 * 1024;
const control_queue_capacity = 8;
const control_bytes_max = 1024 * 1024;
const control_burst_max = 4;

pub const Stream = enum { stdout, stderr };

pub const Chunk = struct {
    stream: Stream,
    bytes: [chunk_bytes_max]u8 = undefined,
    len: usize,

    pub fn slice(self: *const Chunk) []const u8 {
        return self.bytes[0..self.len];
    }
};

const WriteLane = enum { application, control };

const Write = struct {
    bytes: []u8,
    lane: WriteLane,
};

pub const Fault = enum(u8) {
    none,
    stdin,
    stdout,
    stderr,
    wait,
};

const WorkerDone = struct {
    ready: std.atomic.Value(bool) = .init(false),

    fn set(self: *WorkerDone) void {
        self.ready.store(true, .release);
    }

    fn isSet(self: *const WorkerDone) bool {
        return self.ready.load(.acquire);
    }
};

pub const DuplexChild = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    child: std.process.Child,
    process_id: ?std.process.Child.Id,
    stdin_file: std.Io.File,
    stdout_file: std.Io.File,
    stderr_file: std.Io.File,

    application_storage: [application_queue_capacity]Write = undefined,
    application_queue: std.Io.Queue(Write),
    control_storage: [control_queue_capacity]Write = undefined,
    control_queue: std.Io.Queue(Write),
    writes_ready: WakeEvent = .init,
    stdout_storage: [output_queue_capacity]Chunk = undefined,
    stdout_queue: std.Io.Queue(Chunk),
    stderr_storage: [output_queue_capacity]Chunk = undefined,
    stderr_queue: std.Io.Queue(Chunk),

    mutex: Mutex = .init,
    accepting_writes: bool = true,
    queued_application_count: usize = 0,
    queued_application_bytes: usize = 0,
    queued_control_count: usize = 0,
    queued_control_bytes: usize = 0,
    owner_wake: ?*WakeEvent = null,
    fault: std.atomic.Value(Fault) = .init(.none),
    term: std.process.Child.Term = undefined,
    writer_done: WorkerDone = .{},
    stdout_done: WorkerDone = .{},
    stderr_done: WorkerDone = .{},
    wait_done: WorkerDone = .{},

    writer_task: std.Io.Future(void) = undefined,
    stdout_task: std.Io.Future(void) = undefined,
    stderr_task: std.Io.Future(void) = undefined,
    wait_task: std.Io.Future(void) = undefined,
    tasks_started: bool = false,
    tasks_settled: bool = false,

    pub const Options = struct {
        argv: []const []const u8,
        cwd: ?[]const u8 = null,
        environ: ?*const std.process.Environ.Map = null,
    };

    pub fn spawn(
        allocator: std.mem.Allocator,
        io: std.Io,
        task_runtime: *Runtime,
        options: Options,
    ) !*DuplexChild {
        _ = task_runtime;
        std.debug.assert(options.argv.len > 0);
        const self = try allocator.create(DuplexChild);
        errdefer allocator.destroy(self);

        var child = try std.process.spawn(io, .{
            .argv = options.argv,
            .cwd = if (options.cwd) |cwd| .{ .path = cwd } else .inherit,
            .environ_map = options.environ,
            .expand_arg0 = .no_expand,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .pgid = if (builtin.os.tag == .windows) null else 0,
        });
        const stdin_file = child.stdin orelse {
            child.kill(io);
            return error.MissingStdinPipe;
        };
        const stdout_file = child.stdout orelse {
            child.kill(io);
            return error.MissingStdoutPipe;
        };
        const stderr_file = child.stderr orelse {
            child.kill(io);
            return error.MissingStderrPipe;
        };
        child.stdin = null;
        child.stdout = null;
        child.stderr = null;

        self.* = .{
            .allocator = allocator,
            .io = io,
            .child = child,
            .process_id = child.id,
            .stdin_file = stdin_file,
            .stdout_file = stdout_file,
            .stderr_file = stderr_file,
            .application_queue = .init(&self.application_storage),
            .control_queue = .init(&self.control_storage),
            .stdout_queue = .init(&self.stdout_storage),
            .stderr_queue = .init(&self.stderr_storage),
        };

        self.writer_task = std.Io.concurrent(io, writerMain, .{self}) catch |err| {
            stdin_file.close(io);
            stdout_file.close(io);
            stderr_file.close(io);
            child.kill(io);
            return err;
        };
        self.stdout_task = std.Io.concurrent(io, readerMain, .{ self, Stream.stdout }) catch |err| {
            self.writer_task.cancel(io);
            stdout_file.close(io);
            stderr_file.close(io);
            child.kill(io);
            return err;
        };
        self.stderr_task = std.Io.concurrent(io, readerMain, .{ self, Stream.stderr }) catch |err| {
            self.stdout_task.cancel(io);
            self.writer_task.cancel(io);
            stderr_file.close(io);
            child.kill(io);
            return err;
        };
        self.wait_task = std.Io.concurrent(io, waitMain, .{self}) catch |err| {
            child.kill(io);
            self.stderr_task.cancel(io);
            self.stdout_task.cancel(io);
            self.writer_task.cancel(io);
            return err;
        };
        self.tasks_started = true;
        return self;
    }

    pub fn setWake(self: *DuplexChild, wake: *WakeEvent) void {
        self.mutex.lockUncancelable();
        defer self.mutex.unlock();
        self.owner_wake = wake;
    }

    pub fn clearWake(self: *DuplexChild) void {
        self.mutex.lockUncancelable();
        defer self.mutex.unlock();
        self.owner_wake = null;
    }

    /// Takes ownership of `bytes` on success; the caller retains ownership on
    /// failure. Encoding and large copies stay outside this mechanism.
    pub fn enqueueOwned(self: *DuplexChild, bytes: []u8) !void {
        return self.enqueueLaneOwned(.application, bytes);
    }

    /// Reserved for replies, cancellation, shutdown, and protocol errors.
    pub fn enqueueControlOwned(self: *DuplexChild, bytes: []u8) !void {
        return self.enqueueLaneOwned(.control, bytes);
    }

    fn enqueueLaneOwned(self: *DuplexChild, lane: WriteLane, bytes: []u8) !void {
        if (bytes.len == 0) return error.EmptyWrite;
        self.mutex.lockUncancelable();
        if (!self.accepting_writes) {
            self.mutex.unlock();
            return error.Closed;
        }
        const count = switch (lane) {
            .application => &self.queued_application_count,
            .control => &self.queued_control_count,
        };
        const charged_bytes = switch (lane) {
            .application => &self.queued_application_bytes,
            .control => &self.queued_control_bytes,
        };
        const count_max: usize = if (lane == .application) application_queue_capacity else control_queue_capacity;
        const bytes_max: usize = if (lane == .application) application_bytes_max else control_bytes_max;
        if (count.* == count_max or bytes.len > bytes_max - charged_bytes.*) {
            self.mutex.unlock();
            return error.Busy;
        }
        count.* += 1;
        charged_bytes.* += bytes.len;
        self.mutex.unlock();

        const queue = if (lane == .application) &self.application_queue else &self.control_queue;
        const written = queue.put(self.io, &.{.{ .bytes = bytes, .lane = lane }}, 0) catch |err| {
            self.releaseWriteCharge(lane, bytes.len);
            return err;
        };
        if (written == 0) {
            self.releaseWriteCharge(lane, bytes.len);
            return error.Busy;
        }
        self.writes_ready.set(self.io);
    }

    pub fn pollChunk(self: *DuplexChild, stream: Stream) ?Chunk {
        const queue = switch (stream) {
            .stdout => &self.stdout_queue,
            .stderr => &self.stderr_queue,
        };
        var item: [1]Chunk = undefined;
        const count = queue.get(self.io, &item, 0) catch return null;
        return if (count == 1) item[0] else null;
    }

    /// Blocks a runtime task until one stream chunk or terminal EOF. Product
    /// owners use pollChunk; fixed transport workers use this method.
    pub fn nextChunk(self: *DuplexChild, stream: Stream) error{Canceled}!?Chunk {
        const queue = switch (stream) {
            .stdout => &self.stdout_queue,
            .stderr => &self.stderr_queue,
        };
        return queue.getOne(self.io) catch |err| switch (err) {
            error.Closed => null,
            error.Canceled => error.Canceled,
        };
    }

    pub fn workerFault(self: *const DuplexChild) ?Fault {
        const fault = self.fault.load(.acquire);
        return if (fault == .none) null else fault;
    }

    pub fn processComplete(self: *const DuplexChild) bool {
        return self.wait_done.isSet();
    }

    pub fn processTerm(self: *const DuplexChild) ?std.process.Child.Term {
        return if (self.processComplete()) self.term else null;
    }

    pub fn requestStop(self: *DuplexChild) void {
        self.mutex.lockUncancelable();
        self.accepting_writes = false;
        self.mutex.unlock();
        self.application_queue.close(self.io);
        self.control_queue.close(self.io);
        self.writes_ready.set(self.io);
        self.wakeOwner();
    }

    pub fn requestTermination(self: *DuplexChild) void {
        self.requestStop();
        if (!self.processComplete()) signalProcess(self.process_id, .graceful);
    }

    pub fn forceKill(self: *DuplexChild) void {
        self.requestStop();
        if (!self.processComplete()) signalProcess(self.process_id, .forced);
    }

    pub fn readyToSettle(self: *const DuplexChild) bool {
        return self.writer_done.isSet() and self.stdout_done.isSet() and
            self.stderr_done.isSet() and self.wait_done.isSet();
    }

    pub fn settle(self: *DuplexChild) void {
        std.debug.assert(self.tasks_started);
        std.debug.assert(self.readyToSettle());
        if (self.tasks_settled) return;
        self.writer_task.await(self.io);
        self.stdout_task.await(self.io);
        self.stderr_task.await(self.io);
        self.wait_task.await(self.io);
        self.tasks_settled = true;
    }

    pub fn cancelIoAfterExit(self: *DuplexChild) void {
        std.debug.assert(self.processComplete());
        self.requestStop();
        if (!self.writer_done.isSet()) self.writer_task.cancel(self.io);
        if (!self.stdout_done.isSet()) self.stdout_task.cancel(self.io);
        if (!self.stderr_done.isSet()) self.stderr_task.cancel(self.io);
    }

    // ziglint-ignore: Z030 heap owner is poisoned before allocator.destroy(self).
    pub fn deinit(self: *DuplexChild) void {
        std.debug.assert(self.tasks_settled);
        while (pollWrite(self.io, &self.application_queue)) |item| self.allocator.free(item.bytes);
        while (pollWrite(self.io, &self.control_queue)) |item| self.allocator.free(item.bytes);
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    fn releaseWriteCharge(self: *DuplexChild, lane: WriteLane, byte_count: usize) void {
        self.mutex.lockUncancelable();
        const count = switch (lane) {
            .application => &self.queued_application_count,
            .control => &self.queued_control_count,
        };
        const charged_bytes = switch (lane) {
            .application => &self.queued_application_bytes,
            .control => &self.queued_control_bytes,
        };
        std.debug.assert(count.* > 0);
        std.debug.assert(charged_bytes.* >= byte_count);
        count.* -= 1;
        charged_bytes.* -= byte_count;
        self.mutex.unlock();
        self.writes_ready.set(self.io);
    }

    fn writesComplete(self: *DuplexChild) bool {
        self.mutex.lockUncancelable();
        defer self.mutex.unlock();
        return !self.accepting_writes and
            self.queued_application_count == 0 and
            self.queued_control_count == 0;
    }

    fn wakeOwner(self: *DuplexChild) void {
        self.mutex.lockUncancelable();
        defer self.mutex.unlock();
        if (self.owner_wake) |wake| wake.set(self.io);
    }

    fn recordFault(self: *DuplexChild, fault: Fault) void {
        _ = self.fault.cmpxchgStrong(.none, fault, .acq_rel, .acquire);
        self.wakeOwner();
    }
};

fn writerMain(self: *DuplexChild) void {
    defer self.writer_done.set();
    defer self.wakeOwner();
    defer self.stdin_file.close(self.io);
    while (true) {
        var wrote = false;
        var control_count: usize = 0;
        while (control_count < control_burst_max) : (control_count += 1) {
            const item = pollWrite(self.io, &self.control_queue) orelse break;
            if (!writeItem(self, item)) return;
            wrote = true;
        }
        if (pollWrite(self.io, &self.application_queue)) |item| {
            if (!writeItem(self, item)) return;
            wrote = true;
        }
        if (wrote) continue;
        if (self.writesComplete()) return;

        self.writes_ready.reset();
        if (pollWrite(self.io, &self.control_queue)) |item| {
            if (!writeItem(self, item)) return;
            continue;
        }
        if (pollWrite(self.io, &self.application_queue)) |item| {
            if (!writeItem(self, item)) return;
            continue;
        }
        if (self.writesComplete()) return;
        self.writes_ready.wait(self.io) catch return;
    }
}

fn pollWrite(io: std.Io, queue: *std.Io.Queue(Write)) ?Write {
    var item: [1]Write = undefined;
    const count = queue.get(io, &item, 0) catch return null;
    return if (count == 1) item[0] else null;
}

fn writeItem(self: *DuplexChild, item: Write) bool {
    defer {
        self.releaseWriteCharge(item.lane, item.bytes.len);
        self.allocator.free(item.bytes);
    }
    self.stdin_file.writeStreamingAll(self.io, item.bytes) catch {
        self.recordFault(.stdin);
        return false;
    };
    return true;
}

fn readerMain(self: *DuplexChild, stream: Stream) void {
    const file = switch (stream) {
        .stdout => self.stdout_file,
        .stderr => self.stderr_file,
    };
    const queue = switch (stream) {
        .stdout => &self.stdout_queue,
        .stderr => &self.stderr_queue,
    };
    defer switch (stream) {
        .stdout => self.stdout_done.set(),
        .stderr => self.stderr_done.set(),
    };
    defer self.wakeOwner();
    defer queue.close(self.io);
    defer file.close(self.io);

    while (true) {
        var chunk: Chunk = .{ .stream = stream, .len = 0 };
        chunk.len = file.readStreaming(self.io, &.{&chunk.bytes}) catch |err| switch (err) {
            error.EndOfStream => return,
            error.WouldBlock => {
                async_runtime.yield() catch return;
                continue;
            },
            else => {
                self.recordFault(if (stream == .stdout) .stdout else .stderr);
                return;
            },
        };
        queue.putOne(self.io, chunk) catch return;
        self.wakeOwner();
    }
}

fn waitMain(self: *DuplexChild) void {
    defer self.wait_done.set();
    defer self.wakeOwner();
    self.term = self.child.wait(self.io) catch {
        self.recordFault(.wait);
        return;
    };
}

const TerminationMode = enum { graceful, forced };

fn signalProcess(process_id: ?std.process.Child.Id, mode: TerminationMode) void {
    const id = process_id orelse return;
    switch (builtin.os.tag) {
        .windows => _ = std.os.windows.ntdll.NtTerminateProcess(id, @enumFromInt(1)),
        else => {
            const signal: std.posix.SIG = switch (mode) {
                .graceful => .TERM,
                .forced => .KILL,
            };
            if (id > 1) _ = std.posix.system.kill(-id, signal);
        },
    }
}

test "duplex child reserves control capacity during application backpressure" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();
    const argv = [_][]const u8{ "/bin/sh", "-c", "sleep 60" };
    var child = try DuplexChild.spawn(std.testing.allocator, runtime.io(), runtime, .{ .argv = &argv });
    defer settleTestChild(child, runtime);

    var index: usize = 0;
    while (index < 15) : (index += 1) {
        const application = try std.testing.allocator.alloc(u8, 1024 * 1024);
        @memset(application, 'a');
        child.enqueueOwned(application) catch |err| {
            std.testing.allocator.free(application);
            return err;
        };
    }
    const overflow = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(overflow);
    try std.testing.expectError(error.Busy, child.enqueueOwned(overflow));

    const control = try std.testing.allocator.dupe(u8, "control");
    child.enqueueControlOwned(control) catch |err| {
        std.testing.allocator.free(control);
        return err;
    };
    child.mutex.lockUncancelable();
    defer child.mutex.unlock();
    try std.testing.expectEqual(@as(usize, 15), child.queued_application_count);
    try std.testing.expectEqual(@as(usize, 1), child.queued_control_count);
}

test "duplex child forced termination settles every worker" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();
    const argv = [_][]const u8{ "/bin/sh", "-c", "trap '' TERM; printf ready; while :; do sleep 1; done" };
    var child = try DuplexChild.spawn(std.testing.allocator, runtime.io(), runtime, .{ .argv = &argv });
    defer settleTestChild(child, runtime);

    var ready = false;
    var attempts: usize = 0;
    while (!ready and attempts < 1000) : (attempts += 1) {
        if (child.pollChunk(.stdout)) |chunk| {
            ready = std.mem.eql(u8, chunk.slice(), "ready");
        } else {
            runtime.sleep(.fromMilliseconds(1)) catch return error.Canceled;
        }
    }
    try std.testing.expect(ready);
    child.requestTermination();
    runtime.sleep(.fromMilliseconds(10)) catch return error.Canceled;
    try std.testing.expect(!child.processComplete());
    child.forceKill();
    attempts = 0;
    while (!child.processComplete() and attempts < 1000) : (attempts += 1) {
        runtime.sleep(.fromMilliseconds(1)) catch return error.Canceled;
    }
    try std.testing.expect(child.processComplete());
}

fn settleTestChild(child: *DuplexChild, runtime: *Runtime) void {
    if (!child.processComplete()) child.forceKill();
    while (!child.processComplete()) runtime.sleep(.fromMilliseconds(1)) catch break;
    child.cancelIoAfterExit();
    while (!child.readyToSettle()) runtime.sleep(.fromMilliseconds(1)) catch break;
    child.settle();
    child.deinit();
}

test "duplex child writes and reads before observed shutdown" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();
    const argv = [_][]const u8{ "/bin/sh", "-c", "cat" };
    var child = try DuplexChild.spawn(std.testing.allocator, runtime.io(), runtime, .{ .argv = &argv });
    defer {
        if (!child.processComplete()) child.forceKill();
        while (!child.processComplete()) runtime.sleep(.fromMilliseconds(1)) catch break;
        child.cancelIoAfterExit();
        while (!child.readyToSettle()) runtime.sleep(.fromMilliseconds(1)) catch break;
        child.settle();
        child.deinit();
    }

    const input = try std.testing.allocator.dupe(u8, "hello");
    child.enqueueOwned(input) catch |err| {
        std.testing.allocator.free(input);
        return err;
    };
    child.requestStop();
    var output: [5]u8 = undefined;
    var output_len: usize = 0;
    var attempts: usize = 0;
    while (attempts < 1000 and (!child.processComplete() or output_len < output.len)) : (attempts += 1) {
        if (child.pollChunk(.stdout)) |chunk| {
            const data = chunk.slice();
            @memcpy(output[output_len .. output_len + data.len], data);
            output_len += data.len;
        } else runtime.sleep(.fromMilliseconds(1)) catch return;
    }
    try std.testing.expectEqualStrings("hello", output[0..output_len]);
    try std.testing.expect(child.processComplete());
}
