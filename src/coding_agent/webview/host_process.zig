const std = @import("std");
const protocol = @import("protocol.zig");
const types = @import("types.zig");
const log = @import("log.zig");

const graceful_close_ms: u64 = 150;
const terminate_grace_ms: u64 = 150;
const poll_interval_ms: u64 = 10;

pub const StartOptions = struct {
    id: []const u8,
    title: []const u8,
    width: u32,
    height: u32,
    floating: bool,
};

pub const Host = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    event_dispatcher: ?types.EventDispatcher,
    id: []const u8,
    child: std.process.Child,
    child_id: ?std.process.Child.Id = null,
    stdin_file: ?std.Io.File,
    stdout_thread: ?std.Thread = null,
    process_done: std.atomic.Value(bool) = .init(true),
    write_mutex: std.atomic.Mutex = .unlocked,
    event_mutex: std.atomic.Mutex = .unlocked,
    events: std.ArrayListUnmanaged(protocol.HostEvent) = .empty,
    closed: bool = false,

    pub fn create(allocator: std.mem.Allocator, io: std.Io, event_dispatcher: ?types.EventDispatcher, options: StartOptions) !*Host {
        log.coreLog("host.create begin id={s} title={s} size={d}x{d}", .{ options.id, options.title, options.width, options.height });
        const self = try allocator.create(Host);
        errdefer allocator.destroy(self);
        const id = try allocator.dupe(u8, options.id);
        errdefer allocator.free(id);

        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(allocator);
        const host_path = try resolveHostPath(io, allocator);
        defer allocator.free(host_path);
        log.coreLog("host.create resolved path={s}", .{host_path});
        try argv.append(allocator, host_path);
        try argv.append(allocator, "--id");
        try argv.append(allocator, options.id);
        try argv.append(allocator, "--title");
        try argv.append(allocator, if (options.title.len > 0) options.title else options.id);
        try argv.append(allocator, "--width");
        const width_arg = try std.fmt.allocPrint(allocator, "{d}", .{options.width});
        defer allocator.free(width_arg);
        try argv.append(allocator, width_arg);
        try argv.append(allocator, "--height");
        const height_arg = try std.fmt.allocPrint(allocator, "{d}", .{options.height});
        defer allocator.free(height_arg);
        try argv.append(allocator, height_arg);
        if (options.floating) try argv.append(allocator, "--floating");

        var child = std.process.spawn(io, .{
            .argv = argv.items,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
        }) catch |err| {
            log.coreLog("host.create spawn failed path={s} err={s}", .{ host_path, @errorName(err) });
            return err;
        };
        log.coreLog("host.create spawned id={s}", .{options.id});
        const stdin_file = child.stdin;
        child.stdin = null;
        const stdout_file = child.stdout;
        child.stdout = null;
        errdefer _ = child.wait(io) catch null;

        self.* = .{
            .allocator = allocator,
            .io = io,
            .event_dispatcher = event_dispatcher,
            .id = id,
            .child = child,
            .child_id = child.id,
            .stdin_file = stdin_file,
            .process_done = .init(false),
        };
        errdefer self.destroy();

        if (stdout_file) |file| {
            self.stdout_thread = std.Thread.spawn(.{}, Host.readStdout, .{ self, file }) catch |err| {
                file.close(io);
                log.coreLog("host.create stdout thread failed id={s} err={s}", .{ options.id, @errorName(err) });
                return err;
            };
        }
        log.coreLog("host.create done id={s}", .{options.id});
        return self;
    }

    pub fn createTest(allocator: std.mem.Allocator, io: std.Io, event_dispatcher: ?types.EventDispatcher, id: []const u8) !*Host {
        const host = try allocator.create(Host);
        const owned_id = try allocator.dupe(u8, id);
        host.* = .{
            .allocator = allocator,
            .io = io,
            .event_dispatcher = event_dispatcher,
            .id = owned_id,
            .child = undefined,
            .child_id = null,
            .stdin_file = null,
            .process_done = .init(true),
        };
        return host;
    }

    pub fn destroy(self: *Host) void {
        self.shutdownBounded();
        if (self.stdout_thread) |thread| thread.join();
        self.drainEvents();
        self.allocator.free(self.id);
        self.allocator.destroy(self);
    }


    /// Close the helper using bounded escalation. Zig threads do not have a
    /// timed join API, so this waits on `process_done`; if the stdout reader is
    /// stuck in read/wait, TERM/KILL should make stdout close and let join
    /// complete without hanging zi during normal teardown.
    fn shutdownBounded(self: *Host) void {
        self.closeHost();
        if (self.waitForProcessDone(graceful_close_ms)) return;
        const pid = self.child_id orelse return;

        log.coreLog("host.shutdown term id={s}", .{self.id});
        signalChild(pid, .TERM);
        if (self.waitForProcessDone(terminate_grace_ms)) return;

        log.coreLog("host.shutdown kill id={s}", .{self.id});
        signalChild(pid, .KILL);
    }

    fn waitForProcessDone(self: *Host, timeout_ms: u64) bool {
        if (self.process_done.load(.acquire)) return true;
        var waited: u64 = 0;
        while (waited < timeout_ms) : (waited += poll_interval_ms) {
            self.io.sleep(.fromMilliseconds(poll_interval_ms), .awake) catch {};
            if (self.process_done.load(.acquire)) return true;
        }
        return self.process_done.load(.acquire);
    }

    pub fn closeHost(self: *Host) void {
        lockMutex(&self.write_mutex);
        defer self.write_mutex.unlock();
        if (self.closed) return;
        self.closed = true;
        if (self.stdin_file) |file| {
            protocol.writeJsonLine(self.allocator, file, self.io, "{\"type\":\"close\"}") catch {};
            file.close(self.io);
            self.stdin_file = null;
        }
    }

    pub fn pushEvent(self: *Host, event: protocol.HostEvent) !void {
        lockMutex(&self.event_mutex);
        defer self.event_mutex.unlock();
        try self.events.append(self.allocator, event);
        if (self.event_dispatcher) |dispatcher| _ = dispatcher.wake();
    }

    pub fn popEvent(self: *Host) ?protocol.HostEvent {
        lockMutex(&self.event_mutex);
        defer self.event_mutex.unlock();
        if (self.events.items.len == 0) return null;
        return self.events.orderedRemove(0);
    }

    pub fn sendRaw(self: *Host, raw_line: []const u8) !void {
        lockMutex(&self.write_mutex);
        defer self.write_mutex.unlock();
        const file = self.stdin_file orelse return error.HostClosed;
        try protocol.writeJsonLine(self.allocator, file, self.io, raw_line);
    }

    fn readStdout(self: *Host, file: std.Io.File) void {
        defer file.close(self.io);
        defer self.process_done.store(true, .release);
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);
        var chunk: [4096]u8 = undefined;
        var dropping_oversized_line = false;
        while (true) {
            const n = std.posix.read(file.handle, &chunk) catch break;
            if (n == 0) break;
            for (chunk[0..n]) |byte| {
                if (byte == '\n') {
                    if (!dropping_oversized_line) self.recordLine(buf.items);
                    buf.clearRetainingCapacity();
                    dropping_oversized_line = false;
                } else if (!dropping_oversized_line) {
                    if (buf.items.len < types.max_host_line_bytes) {
                        buf.append(self.allocator, byte) catch {
                            buf.clearRetainingCapacity();
                            dropping_oversized_line = true;
                            break;
                        };
                    } else {
                        buf.clearRetainingCapacity();
                        dropping_oversized_line = true;
                    }
                }
            }
        }
        if (buf.items.len > 0 and !dropping_oversized_line) self.recordLine(buf.items);
        _ = self.child.wait(self.io) catch null;
    }

    fn recordLine(self: *Host, line: []const u8) void {
        const event = protocol.parseHostEvent(self.allocator, line) catch return;
        self.pushEvent(event) catch {
            var owned = event;
            owned.deinit(self.allocator);
        };
    }

    fn drainEvents(self: *Host) void {
        lockMutex(&self.event_mutex);
        defer self.event_mutex.unlock();
        for (self.events.items) |*event| event.deinit(self.allocator);
        self.events.clearAndFree(self.allocator);
    }
};

fn lockMutex(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.Thread.yield() catch {};
}

fn signalChild(pid: std.process.Child.Id, sig: std.posix.SIG) void {
    std.posix.kill(pid, sig) catch {};
}

fn resolveHostPath(path_io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    if (getenv("ZI_WEBVIEW_HOST")) |path| return allocator.dupe(u8, path);
    const dir = try std.process.executableDirPathAlloc(path_io, allocator);
    defer allocator.free(dir);
    return std.fs.path.join(allocator, &.{ dir, "zi-webview-host" });
}

fn getenv(name: [:0]const u8) ?[]const u8 {
    const raw = std.c.getenv(name.ptr) orelse return null;
    return std.mem.span(raw);
}
