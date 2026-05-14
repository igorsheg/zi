const std = @import("std");
const builtin = @import("builtin");
const process_engine = @import("process_engine.zig");

pub const EventKind = enum { stdout, stderr, exit };

pub const OwnedEvent = struct {
    id: u64,
    kind: EventKind,
    data: ?[]const u8 = null,
    code: ?i64 = null,

    pub fn clone(self: OwnedEvent, allocator: std.mem.Allocator) !OwnedEvent {
        return .{
            .id = self.id,
            .kind = self.kind,
            .data = if (self.data) |data| try allocator.dupe(u8, data) else null,
            .code = self.code,
        };
    }

    pub fn deinit(self: *OwnedEvent, allocator: std.mem.Allocator) void {
        if (self.data) |data| allocator.free(data);
        self.* = undefined;
    }
};

pub const Event = OwnedEvent;

pub const EventSink = struct {
    ptr: *anyopaque,
    // submit consumes event only when it returns true. When false, ownership remains with caller.
    submit: *const fn (ptr: *anyopaque, event: OwnedEvent) bool,
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
            .sink = self.sink,
            .request = owned_request,
        };
        job.engine = process_engine.Engine.init(self.io, .{
            .argv = job.request.argv,
            .cwd = job.request.cwd,
            .process_group = true,
        }, .{ .ptr = @ptrCast(job), .submit = Job.submitChildEvent });
        owned_request = .{ .argv = &.{} };
        errdefer job.deinit(self.allocator);
        try self.jobs.put(self.allocator, id, job);
        errdefer _ = self.jobs.remove(id);
        try job.engine.start();
    }

    pub fn stop(self: *Manager, id: u64) void {
        const job = self.jobs.get(id) orelse return;
        job.stop();
    }

    pub fn reap(self: *Manager, id: u64) bool {
        const job = self.jobs.get(id) orelse return false;
        if (!job.engine.isExited()) return false;
        _ = self.jobs.remove(id);
        self.destroyJob(job);
        return true;
    }

    pub fn remove(self: *Manager, id: u64) bool {
        const job = self.jobs.get(id) orelse return false;
        _ = self.jobs.remove(id);
        self.destroyJob(job);
        return true;
    }

    pub fn write(self: *Manager, id: u64, data: []const u8) !void {
        const job = self.jobs.get(id) orelse return error.UnknownJob;
        try job.write(data);
    }

    fn destroyJob(self: *Manager, job: *Job) void {
        job.stop();
        job.engine.join();
        job.deinit(self.allocator);
        self.allocator.destroy(job);
    }
};

const Job = struct {
    id: u64,
    allocator: std.mem.Allocator,
    sink: EventSink,
    request: StartRequest,
    engine: process_engine.Engine = undefined,

    fn deinit(self: *Job, allocator: std.mem.Allocator) void {
        self.request.deinit(allocator);
        self.* = undefined;
    }

    fn stop(self: *Job) void {
        self.engine.stop();
    }

    fn write(self: *Job, data: []const u8) !void {
        return self.engine.write(data) catch |err| switch (err) {
            error.ProcessNotReady => error.JobNotReady,
            else => err,
        };
    }

    fn submitChildEvent(ptr: *anyopaque, event: process_engine.Event) bool {
        const self: *Job = @ptrCast(@alignCast(ptr));
        var owned: Event = switch (event) {
            .stdout => |bytes| .{ .id = self.id, .kind = .stdout, .data = self.allocator.dupe(u8, bytes) catch return false },
            .stderr => |bytes| .{ .id = self.id, .kind = .stderr, .data = self.allocator.dupe(u8, bytes) catch return false },
            .spawn_failed => .{ .id = self.id, .kind = .exit, .code = null },
            .exit => |term| .{ .id = self.id, .kind = .exit, .code = exitCode(term) },
        };
        if (self.sink.submit(self.sink.ptr, owned)) return true;
        owned.deinit(self.allocator);
        return false;
    }

    fn exitCode(term: ?std.process.Child.Term) ?i64 {
        return if (term) |t| switch (t) {
            .exited => |code| @intCast(code),
            else => null,
        } else null;
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
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);
        self.events.append(self.allocator, event) catch return false;
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

fn testManager(sink: *TestSink) Manager {
    return Manager.init(testing.allocator, std.Options.debug_io, .{ .ptr = @ptrCast(sink), .submit = &TestSink.sink });
}

fn ownedArgv(args: []const []const u8) ![]const []const u8 {
    const argv = try testing.allocator.alloc([]const u8, args.len);
    var initialized: usize = 0;
    errdefer {
        for (argv[0..initialized]) |arg| testing.allocator.free(arg);
        testing.allocator.free(argv);
    }
    for (args, 0..) |arg, i| {
        argv[i] = try testing.allocator.dupe(u8, arg);
        initialized += 1;
    }
    return argv;
}

fn startShellJob(manager: *Manager, id: u64, script: []const u8) !void {
    try manager.start(id, .{ .argv = try ownedArgv(&.{ "/bin/sh", "-c", script }) });
}

fn startCommandJob(manager: *Manager, id: u64, args: []const []const u8) !void {
    try manager.start(id, .{ .argv = try ownedArgv(args) });
}

fn writeWhenReady(manager: *Manager, id: u64, data: []const u8) !void {
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        manager.write(id, data) catch |err| switch (err) {
            error.JobNotReady => {
                std.Options.debug_io.sleep(.fromMilliseconds(10), .awake) catch {};
                continue;
            },
            else => return err,
        };
        return;
    }
    return error.Timeout;
}

test "zio job forwards stdout chunks and successful exit" {
    var sink = TestSink{ .allocator = testing.allocator };
    defer sink.deinit();
    var manager = testManager(&sink);
    defer manager.deinit();

    try startShellJob(&manager, 1, "printf hello");

    try waitUntil(struct {
        fn pred(s: *TestSink) bool {
            return s.contains(.stdout, "hello");
        }
    }.pred, &sink);
    try waitUntil(struct {
        fn pred(s: *TestSink) bool {
            return s.exitCode(1) == 0;
        }
    }.pred, &sink);
}

test "zio job writes to child stdin after the process is ready" {
    var sink = TestSink{ .allocator = testing.allocator };
    defer sink.deinit();
    var manager = testManager(&sink);
    defer manager.deinit();

    try startShellJob(&manager, 2, "IFS= read -r line; printf 'got:%s\\n' \"$line\"");
    try writeWhenReady(&manager, 2, "doom\n");

    try waitUntil(struct {
        fn pred(s: *TestSink) bool {
            return s.contains(.stdout, "got:doom");
        }
    }.pred, &sink);
    try waitUntil(struct {
        fn pred(s: *TestSink) bool {
            return s.exitCode(2) == 0;
        }
    }.pred, &sink);
}

test "zio job stop terminates a running child" {
    var sink = TestSink{ .allocator = testing.allocator };
    defer sink.deinit();
    var manager = testManager(&sink);
    defer manager.deinit();

    try startCommandJob(&manager, 3, &.{ "/bin/sleep", "100" });
    std.Options.debug_io.sleep(.fromMilliseconds(30), .awake) catch {};
    manager.stop(3);

    try waitUntil(struct {
        fn pred(s: *TestSink) bool {
            return s.hasExit(3);
        }
    }.pred, &sink);
}

test "zio job stop escalates children that ignore TERM" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;

    var sink = TestSink{ .allocator = testing.allocator };
    defer sink.deinit();
    var manager = testManager(&sink);
    defer manager.deinit();

    try startShellJob(&manager, 4, "trap '' TERM; while :; do sleep 1; done");
    std.Options.debug_io.sleep(.fromMilliseconds(30), .awake) catch {};
    manager.stop(4);

    try waitUntil(struct {
        fn pred(s: *TestSink) bool {
            return s.hasExit(4);
        }
    }.pred, &sink);
}
