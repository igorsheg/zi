const std = @import("std");
const builtin = @import("builtin");
const deadline = @import("deadline.zig");
const process_reactor = @import("process_reactor.zig");
const task = @import("task.zig");
const logging = @import("../logging.zig");

pub const EventKind = enum { ready, stdout, stderr, output_dropped, exit };

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
    jobs: std.AutoHashMapUnmanaged(u64, void) = .empty,
    mutex: std.Io.Mutex = .init,
    reactor: ?process_reactor.Reactor = null,
    pump: ?task.Group = null,
    stats_data: Stats = .{},

    pub const Stats = struct {
        active_jobs: usize = 0,
        started_jobs: usize = 0,
        exited_jobs: usize = 0,
        stdout_bytes: usize = 0,
        stderr_bytes: usize = 0,
        output_dropped_events: usize = 0,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, sink: EventSink) Manager {
        return .{ .allocator = allocator, .io = io, .sink = sink };
    }

    pub fn deinit(self: *Manager) void {
        self.stopPump();
        if (self.reactor) |*reactor| reactor.deinit();
        self.jobs.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn start(self: *Manager, id: u64, request: StartRequest) !void {
        var owned_request = request;
        defer owned_request.deinit(self.allocator);
        try self.ensureReactor();

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.jobs.contains(id)) return error.DuplicateJob;
        try self.jobs.put(self.allocator, id, {});
        errdefer _ = self.jobs.remove(id);
        self.stats_data.active_jobs = self.jobs.count();
        self.stats_data.started_jobs += 1;

        try self.reactor.?.spawn(.{
            .id = id,
            .argv = owned_request.argv,
            .cwd = owned_request.cwd,
            .process_group = true,
            .stdin = true,
            .stdout = true,
            .stderr = true,
        });
    }

    pub fn stop(self: *Manager, id: u64) void {
        self.mutex.lockUncancelable(self.io);
        const exists = self.jobs.contains(id);
        self.mutex.unlock(self.io);
        if (!exists) return;
        if (self.reactor) |*reactor| reactor.kill(id) catch {};
    }

    pub fn remove(self: *Manager, id: u64) bool {
        self.mutex.lockUncancelable(self.io);
        const removed = self.jobs.remove(id);
        if (removed) self.stats_data.active_jobs = self.jobs.count();
        self.mutex.unlock(self.io);
        if (removed) if (self.reactor) |*reactor| reactor.kill(id) catch {};
        return removed;
    }

    pub fn write(self: *Manager, id: u64, data: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        const exists = self.jobs.contains(id);
        self.mutex.unlock(self.io);
        if (!exists) return error.UnknownJob;
        const reactor = &(self.reactor orelse return error.UnknownJob);
        return reactor.write(id, data) catch |err| switch (err) {
            error.ReactorStopped => error.JobNotReady,
            else => err,
        };
    }

    fn ensureReactor(self: *Manager) !void {
        if (self.reactor == null) self.reactor = try process_reactor.Reactor.initIo(self.allocator, self.io);
        try self.reactor.?.start();
        if (self.pump == null) {
            var group = task.Group.init(self.allocator);
            errdefer group.cancel();
            try group.spawnThread(pumpEvents, .{self});
            self.pump = group;
        }
    }

    fn stopPump(self: *Manager) void {
        if (self.reactor) |*reactor| reactor.stop();
        if (self.pump) |*group| {
            group.join() catch {};
            self.pump = null;
        }
    }

    fn pumpEvents(self: *Manager) void {
        logging.setThreadLabel(.process_reactor);
        while (true) {
            var batch: [32]process_reactor.Event = undefined;
            const reactor = &(self.reactor orelse return);
            const count = reactor.drainEvents(&batch);
            if (count == 0) {
                _ = reactor.waitEvents(100) catch false;
                if (reactor.events.stats().state == .closed and reactor.events.pendingDepth() == 0) return;
                continue;
            }
            for (batch[0..count]) |*event| {
                defer event.deinit(self.allocator);
                self.forwardEvent(event.*);
            }
        }
    }

    fn forwardEvent(self: *Manager, event: process_reactor.Event) void {
        self.recordEvent(event);
        var owned: Event = switch (event) {
            .ready => |id| .{ .id = id, .kind = .ready },
            .stdout => |out| .{ .id = out.id, .kind = .stdout, .data = self.allocator.dupe(u8, out.bytes) catch return },
            .stderr => |out| .{ .id = out.id, .kind = .stderr, .data = self.allocator.dupe(u8, out.bytes) catch return },
            .output_dropped => |dropped| .{ .id = dropped.id, .kind = .output_dropped, .code = @intCast(dropped.count) },
            .exit => |exit| blk: {
                self.markExited(exit.id);
                break :blk .{ .id = exit.id, .kind = .exit, .code = exitCode(exit.term) };
            },
            .spawn_failed => |id| blk: {
                self.markExited(id);
                break :blk .{ .id = id, .kind = .exit, .code = null };
            },
        };
        if (self.sink.submit(self.sink.ptr, owned)) return;
        owned.deinit(self.allocator);
    }

    fn markExited(self: *Manager, id: u64) void {
        self.mutex.lockUncancelable(self.io);
        if (self.jobs.remove(id)) self.stats_data.exited_jobs += 1;
        self.stats_data.active_jobs = self.jobs.count();
        self.mutex.unlock(self.io);
    }

    fn recordEvent(self: *Manager, event: process_reactor.Event) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        switch (event) {
            .stdout => |out| self.stats_data.stdout_bytes += out.bytes.len,
            .stderr => |out| self.stats_data.stderr_bytes += out.bytes.len,
            .output_dropped => self.stats_data.output_dropped_events += 1,
            else => {},
        }
    }

    pub fn stats(self: *Manager) Stats {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.stats_data;
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
    condition: std.Io.Condition = .init,
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
        self.condition.broadcast(std.Options.debug_io);
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

    fn hasKind(self: *TestSink, id: u64, kind: EventKind) bool {
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);
        for (self.events.items) |event| {
            if (event.id == id and event.kind == kind) return true;
        }
        return false;
    }

    fn waitUntil(self: *TestSink, comptime pred: fn (*const TestSink) bool, timeout_ms: u64) !void {
        const limit = deadline.Deadline.afterMs(std.Options.debug_io, timeout_ms);
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);
        while (!pred(self)) {
            if (limit.expired(std.Options.debug_io)) return error.Timeout;
            self.condition.waitUncancelable(std.Options.debug_io, &self.mutex);
        }
    }

    fn containsLocked(self: *const TestSink, kind: EventKind, needle: []const u8) bool {
        for (self.events.items) |event| {
            if (event.kind == kind and event.data != null and std.mem.indexOf(u8, event.data.?, needle) != null) return true;
        }
        return false;
    }

    fn exitCodeLocked(self: *const TestSink, id: u64) ?i64 {
        for (self.events.items) |event| {
            if (event.id == id and event.kind == .exit) return event.code;
        }
        return null;
    }

    fn hasExitLocked(self: *const TestSink, id: u64) bool {
        for (self.events.items) |event| {
            if (event.id == id and event.kind == .exit) return true;
        }
        return false;
    }

    fn hasKindLocked(self: *const TestSink, id: u64, kind: EventKind) bool {
        for (self.events.items) |event| {
            if (event.id == id and event.kind == kind) return true;
        }
        return false;
    }
};

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

test "zio job forwards stdout chunks and successful exit" {
    var sink = TestSink{ .allocator = testing.allocator };
    defer sink.deinit();
    var manager = testManager(&sink);
    defer manager.deinit();

    try startShellJob(&manager, 1, "printf hello");

    try sink.waitUntil(struct {
        fn pred(s: *const TestSink) bool {
            return s.containsLocked(.stdout, "hello");
        }
    }.pred, 2000);
    try sink.waitUntil(struct {
        fn pred(s: *const TestSink) bool {
            return s.exitCodeLocked(1) == 0;
        }
    }.pred, 2000);
    const stats = manager.stats();
    try std.testing.expectEqual(@as(usize, 1), stats.started_jobs);
    try std.testing.expectEqual(@as(usize, 1), stats.exited_jobs);
    try std.testing.expectEqual(@as(usize, 0), stats.active_jobs);
    try std.testing.expectEqual(@as(usize, 5), stats.stdout_bytes);
}

test "zio job writes to child stdin after the process is ready" {
    var sink = TestSink{ .allocator = testing.allocator };
    defer sink.deinit();
    var manager = testManager(&sink);
    defer manager.deinit();

    try startShellJob(&manager, 2, "IFS= read -r line; printf 'got:%s\\n' \"$line\"");
    try sink.waitUntil(struct {
        fn pred(s: *const TestSink) bool {
            return s.hasKindLocked(2, .ready);
        }
    }.pred, 2000);
    try manager.write(2, "doom\n");

    try sink.waitUntil(struct {
        fn pred(s: *const TestSink) bool {
            return s.containsLocked(.stdout, "got:doom");
        }
    }.pred, 2000);
    try sink.waitUntil(struct {
        fn pred(s: *const TestSink) bool {
            return s.exitCodeLocked(2) == 0;
        }
    }.pred, 2000);
}

test "zio job stop terminates a running child" {
    var sink = TestSink{ .allocator = testing.allocator };
    defer sink.deinit();
    var manager = testManager(&sink);
    defer manager.deinit();

    try startCommandJob(&manager, 3, &.{ "/bin/sleep", "100" });
    try sink.waitUntil(struct {
        fn pred(s: *const TestSink) bool {
            return s.hasKindLocked(3, .ready);
        }
    }.pred, 2000);
    manager.stop(3);

    try sink.waitUntil(struct {
        fn pred(s: *const TestSink) bool {
            return s.hasExitLocked(3);
        }
    }.pred, 2000);
}

test "zio job stop escalates children that ignore TERM" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;

    var sink = TestSink{ .allocator = testing.allocator };
    defer sink.deinit();
    var manager = testManager(&sink);
    defer manager.deinit();

    try startShellJob(&manager, 4, "trap '' TERM; while :; do sleep 1; done");
    try sink.waitUntil(struct {
        fn pred(s: *const TestSink) bool {
            return s.hasKindLocked(4, .ready);
        }
    }.pred, 2000);
    manager.stop(4);

    try sink.waitUntil(struct {
        fn pred(s: *const TestSink) bool {
            return s.hasExitLocked(4);
        }
    }.pred, 2000);
}
