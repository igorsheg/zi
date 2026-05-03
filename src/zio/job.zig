const std = @import("std");

/// Small zio-owned long-running process supervisor.
///
/// This owns process/job mechanics only: ids, process threads, abort, stdin
/// writes, stdout/stderr chunk forwarding, and lifecycle cleanup. Product
/// layers provide a typed `EventSink` and translate events into their own
/// domain messages.
pub const EventKind = enum { stdout, stderr, exit };

pub const Event = struct {
    id: u64,
    kind: EventKind,
    data: ?[]const u8 = null,
    code: ?i64 = null,

    pub fn clone(self: Event, allocator: std.mem.Allocator) !Event {
        return .{
            .id = self.id,
            .kind = self.kind,
            .data = if (self.data) |data| try allocator.dupe(u8, data) else null,
            .code = self.code,
        };
    }

    pub fn deinit(self: *Event, allocator: std.mem.Allocator) void {
        if (self.data) |data| allocator.free(data);
        self.* = undefined;
    }
};

pub const EventSink = struct {
    ptr: *anyopaque,
    submit: *const fn (ptr: *anyopaque, event: Event) bool,
};

pub const StartRequest = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,

    pub fn deinit(self: *StartRequest, allocator: std.mem.Allocator) void {
        for (self.argv) |arg| allocator.free(arg);
        allocator.free(self.argv);
        if (self.cwd) |cwd| allocator.free(cwd);
        self.* = undefined;
    }
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    sink: EventSink,
    jobs: std.AutoHashMapUnmanaged(u64, *Job) = .empty,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, sink: EventSink) Manager {
        return .{ .allocator = allocator, .io = io, .sink = sink };
    }

    pub fn deinit(self: *Manager) void {
        var it = self.jobs.iterator();
        while (it.next()) |entry| destroyJob(self, entry.value_ptr.*);
        self.jobs.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn start(self: *Manager, id: u64, request: StartRequest) !void {
        var owned_request = request;
        errdefer owned_request.deinit(self.allocator);
        if (self.jobs.contains(id)) return error.DuplicateJob;
        const job = try self.allocator.create(Job);
        errdefer self.allocator.destroy(job);
        job.* = .{
            .id = id,
            .allocator = self.allocator,
            .io = self.io,
            .sink = self.sink,
            .request = owned_request,
        };
        owned_request = .{ .argv = &.{} };
        errdefer job.deinit(self.allocator);
        try self.jobs.put(self.allocator, id, job);
        errdefer _ = self.jobs.remove(id);
        job.thread = try std.Thread.spawn(.{}, Job.run, .{job});
    }

    pub fn stop(self: *Manager, id: u64) void {
        const job = self.jobs.get(id) orelse return;
        job.stop();
    }

    pub fn write(self: *Manager, id: u64, data: []const u8) !void {
        const job = self.jobs.get(id) orelse return error.UnknownJob;
        try job.write(data);
    }

    fn destroyJob(self: *Manager, job: *Job) void {
        job.stop();
        job.thread.join();
        job.deinit(self.allocator);
        self.allocator.destroy(job);
    }
};

const Job = struct {
    id: u64,
    allocator: std.mem.Allocator,
    io: std.Io,
    sink: EventSink,
    request: StartRequest,
    thread: std.Thread = undefined,
    mutex: std.Io.Mutex = .init,
    child_id: ?std.process.Child.Id = null,
    stdin_file: ?std.Io.File = null,
    stopping: bool = false,

    fn deinit(self: *Job, allocator: std.mem.Allocator) void {
        self.request.deinit(allocator);
        self.* = undefined;
    }

    fn run(self: *Job) void {
        var child = std.process.spawn(self.io, .{
            .argv = self.request.argv,
            .cwd = if (self.request.cwd) |cwd| .{ .path = cwd } else .inherit,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .pgid = null,
        }) catch {
            _ = self.sink.submit(self.sink.ptr, .{ .id = self.id, .kind = .exit, .code = null });
            return;
        };

        self.mutex.lockUncancelable(self.io);
        self.child_id = child.id;
        self.stdin_file = child.stdin;
        self.mutex.unlock(self.io);

        var stdout_thread: ?std.Thread = null;
        var stderr_thread: ?std.Thread = null;
        if (child.stdout) |stdout_file| {
            stdout_thread = std.Thread.spawn(.{}, readPipe, .{ self, stdout_file, EventKind.stdout }) catch null;
        }
        if (child.stderr) |stderr_file| {
            stderr_thread = std.Thread.spawn(.{}, readPipe, .{ self, stderr_file, EventKind.stderr }) catch null;
        }

        const term = child.wait(self.io) catch null;
        if (stdout_thread) |thread| thread.join();
        if (stderr_thread) |thread| thread.join();

        self.mutex.lockUncancelable(self.io);
        self.child_id = null;
        self.stdin_file = null;
        self.mutex.unlock(self.io);

        const code: ?i64 = if (term) |t| switch (t) {
            .exited => |code| @intCast(code),
            else => null,
        } else null;
        _ = self.sink.submit(self.sink.ptr, .{ .id = self.id, .kind = .exit, .code = code });
    }

    fn stop(self: *Job) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        const child_id = self.child_id;
        self.mutex.unlock(self.io);
        if (child_id) |pid| std.posix.kill(pid, .TERM) catch {};
    }

    fn write(self: *Job, data: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        const file = self.stdin_file orelse {
            self.mutex.unlock(self.io);
            return error.JobNotReady;
        };
        self.mutex.unlock(self.io);
        try file.writeStreamingAll(self.io, data);
    }

    fn readPipe(self: *Job, file: std.Io.File, kind: EventKind) void {
        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            const n = std.posix.read(file.handle, &buf) catch return;
            if (n == 0) return;
            _ = self.sink.submit(self.sink.ptr, .{ .id = self.id, .kind = kind, .data = buf[0..n] });
        }
    }
};

const testing = std.testing;

const TestSink = struct {
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    events: std.ArrayList(Event) = .empty,

    fn deinit(self: *TestSink) void {
        for (self.events.items) |*event| event.deinit(self.allocator);
        self.events.deinit(self.allocator);
    }

    fn sink(ptr: *anyopaque, event: Event) bool {
        const self: *TestSink = @ptrCast(@alignCast(ptr));
        const cloned = event.clone(self.allocator) catch return false;
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);
        self.events.append(self.allocator, cloned) catch {
            var failed = cloned;
            failed.deinit(self.allocator);
            return false;
        };
        return true;
    }

    fn contains(self: *TestSink, kind: EventKind, needle: []const u8) bool {
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);
        for (self.events.items) |event| {
            if (event.kind == kind and event.data != null and std.mem.indexOf(u8, event.data.?, needle) != null) return true;
        }
        return false;
    }

    fn exitCode(self: *TestSink, id: u64) ?i64 {
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);
        for (self.events.items) |event| {
            if (event.id == id and event.kind == .exit) return event.code;
        }
        return null;
    }

    fn hasExit(self: *TestSink, id: u64) bool {
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);
        for (self.events.items) |event| {
            if (event.id == id and event.kind == .exit) return true;
        }
        return false;
    }
};

fn waitUntil(comptime pred: fn (*TestSink) bool, sink: *TestSink) !void {
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        if (pred(sink)) return;
        std.Options.debug_io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    return error.Timeout;
}

test "zio job streams stdout and reports exit" {
    var sink = TestSink{ .allocator = testing.allocator };
    defer sink.deinit();
    var manager = Manager.init(testing.allocator, std.Options.debug_io, .{ .ptr = @ptrCast(&sink), .submit = &TestSink.sink });
    defer manager.deinit();

    const argv = try testing.allocator.dupe([]const u8, &.{ try testing.allocator.dupe(u8, "/bin/sh"), try testing.allocator.dupe(u8, "-c"), try testing.allocator.dupe(u8, "printf hello") });
    try manager.start(1, .{ .argv = argv });

    try waitUntil(struct {
        fn pred(s: *TestSink) bool { return s.contains(.stdout, "hello"); }
    }.pred, &sink);
    try waitUntil(struct {
        fn pred(s: *TestSink) bool { return s.exitCode(1) == 0; }
    }.pred, &sink);
}

test "zio job write reaches child stdin" {
    var sink = TestSink{ .allocator = testing.allocator };
    defer sink.deinit();
    var manager = Manager.init(testing.allocator, std.Options.debug_io, .{ .ptr = @ptrCast(&sink), .submit = &TestSink.sink });
    defer manager.deinit();

    const script = "IFS= read -r line; printf 'got:%s\\n' \"$line\"";
    const argv = try testing.allocator.dupe([]const u8, &.{ try testing.allocator.dupe(u8, "/bin/sh"), try testing.allocator.dupe(u8, "-c"), try testing.allocator.dupe(u8, script) });
    try manager.start(2, .{ .argv = argv });

    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        manager.write(2, "doom\n") catch |err| switch (err) {
            error.JobNotReady => {
                std.Options.debug_io.sleep(.fromMilliseconds(10), .awake) catch {};
                continue;
            },
            else => return err,
        };
        break;
    }
    if (attempts == 100) return error.Timeout;

    try waitUntil(struct {
        fn pred(s: *TestSink) bool { return s.contains(.stdout, "got:doom"); }
    }.pred, &sink);
    try waitUntil(struct {
        fn pred(s: *TestSink) bool { return s.exitCode(2) == 0; }
    }.pred, &sink);
}

test "zio job stop terminates a running child" {
    var sink = TestSink{ .allocator = testing.allocator };
    defer sink.deinit();
    var manager = Manager.init(testing.allocator, std.Options.debug_io, .{ .ptr = @ptrCast(&sink), .submit = &TestSink.sink });
    defer manager.deinit();

    const argv = try testing.allocator.dupe([]const u8, &.{ try testing.allocator.dupe(u8, "/bin/sleep"), try testing.allocator.dupe(u8, "100") });
    try manager.start(3, .{ .argv = argv });
    std.Options.debug_io.sleep(.fromMilliseconds(30), .awake) catch {};
    manager.stop(3);

    try waitUntil(struct {
        fn pred(s: *TestSink) bool { return s.hasExit(3); }
    }.pred, &sink);
}
