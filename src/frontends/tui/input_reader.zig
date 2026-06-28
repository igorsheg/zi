//! Frontend-owned raw terminal byte reader.
//!
//! The worker owns only stdin readiness/read calls, bounded raw-byte queue
//! writes, EOF, and cancellation. Vaxis parsing and App mutation stay in
//! `tui.Terminal` on the frontend owner thread.

const std = @import("std");

const runtime = @import("../../runtime/root.zig");

pub const capacity_bytes: usize = 16 * 1024;
pub const drain_chunk_bytes_max: usize = 4096;
const read_chunk_bytes_max: usize = 1024;

const ByteQueue = std.Io.Queue(u8);

pub const InputReader = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    wake: *runtime.WakeEvent,
    storage: []u8,
    queue: ByteQueue,
    thread: ?std.Thread = null,
    cancel_fds: ?[2]std.c.fd_t = null,
    queued_count: std.atomic.Value(usize) = .init(0),
    last_enqueue_ns: std.atomic.Value(i64) = .init(0),
    eof: std.atomic.Value(bool) = .init(false),
    faulted: std.atomic.Value(bool) = .init(false),

    const ThreadArgs = struct {
        self: *InputReader,
        stdin_fd: std.posix.fd_t,
        cancel_read_fd: std.c.fd_t,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        wake: *runtime.WakeEvent,
    ) !*InputReader {
        const self = try allocator.create(InputReader);
        errdefer allocator.destroy(self);
        const storage = try allocator.alloc(u8, capacity_bytes);
        errdefer allocator.free(storage);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .wake = wake,
            .storage = storage,
            .queue = ByteQueue.init(storage),
        };
        return self;
    }

    pub fn deinit(self: *InputReader) void {
        const allocator = self.allocator;
        self.stop();
        allocator.free(self.storage);
        self.* = undefined;
        allocator.destroy(self);
    }

    /// Start one reader epoch. Restarting discards any queued raw bytes from the
    /// previous epoch; external-editor suspension requires that Zi stop reading
    /// before another program owns the terminal.
    pub fn start(self: *InputReader, stdin_fd: std.posix.fd_t) !void {
        if (self.thread != null) return;
        self.queue = ByteQueue.init(self.storage);
        self.queued_count.store(0, .release);
        self.last_enqueue_ns.store(0, .release);
        self.eof.store(false, .release);
        self.faulted.store(false, .release);

        const fds = try createPipe();
        errdefer closePipe(fds);
        self.cancel_fds = fds;
        errdefer self.cancel_fds = null;

        self.thread = try std.Thread.spawn(.{}, threadMain, .{ThreadArgs{
            .self = self,
            .stdin_fd = stdin_fd,
            .cancel_read_fd = fds[0],
        }});
    }

    /// Stop accepting input reads and join the worker. Queued bytes are
    /// intentionally discarded so external programs never inherit Zi-owned
    /// pending terminal input.
    pub fn stop(self: *InputReader) void {
        const thread = self.thread orelse return;
        self.queue.close(self.io);
        if (self.cancel_fds) |fds| wakeCancel(fds[1]);
        thread.join();
        self.thread = null;
        if (self.cancel_fds) |fds| closePipe(fds);
        self.cancel_fds = null;
        self.queue = ByteQueue.init(self.storage);
        self.queued_count.store(0, .release);
        self.last_enqueue_ns.store(0, .release);
        self.eof.store(false, .release);
        self.faulted.store(false, .release);
    }

    pub const DrainResult = struct {
        bytes: []const u8,
        eof: bool = false,
        faulted: bool = false,
        enqueue_ns: ?i64 = null,
    };

    /// Non-blocking owner drain. At most `out.len` bytes are returned; callers
    /// pass a bounded chunk to enforce foreground turn budget.
    pub fn drain(self: *InputReader, out: []u8) DrainResult {
        const count = self.queue.get(self.io, out, 0) catch 0;
        const enqueue_ns = if (count > 0) blk: {
            _ = self.queued_count.fetchSub(count, .release);
            const ns = self.last_enqueue_ns.swap(0, .acq_rel);
            break :blk if (ns == 0) null else ns;
        } else null;
        const eof_now = count == 0 and self.eof.swap(false, .acq_rel);
        const faulted_now = count == 0 and self.faulted.swap(false, .acq_rel);
        return .{ .bytes = out[0..count], .eof = eof_now, .faulted = faulted_now, .enqueue_ns = enqueue_ns };
    }

    pub fn hasQueuedBytes(self: *const InputReader) bool {
        return self.queued_count.load(.acquire) > 0;
    }

    pub fn hasTerminalFact(self: *const InputReader) bool {
        return self.eof.load(.acquire) or self.faulted.load(.acquire);
    }

    fn threadMain(args: ThreadArgs) void {
        args.self.run(args.stdin_fd, args.cancel_read_fd);
    }

    fn run(self: *InputReader, stdin_fd: std.posix.fd_t, cancel_read_fd: std.c.fd_t) void {
        var poll_fds = [_]std.posix.pollfd{
            .{ .fd = stdin_fd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = cancel_read_fd, .events = std.posix.POLL.IN, .revents = 0 },
        };
        var buf: [read_chunk_bytes_max]u8 = undefined;
        while (true) {
            poll_fds[0].revents = 0;
            poll_fds[1].revents = 0;
            _ = std.posix.poll(&poll_fds, -1) catch {
                self.publishFault();
                return;
            };
            if (hasReadable(poll_fds[1].revents)) return;
            if (!hasReadable(poll_fds[0].revents)) continue;

            const read_count = std.posix.read(stdin_fd, &buf) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => {
                    self.publishFault();
                    return;
                },
            };
            if (read_count == 0) {
                self.eof.store(true, .release);
                self.wake.set(self.io);
                return;
            }

            var offset: usize = 0;
            while (offset < read_count) {
                const queued = self.queue.put(self.io, buf[offset..read_count], 1) catch return;
                const previous_count = self.queued_count.fetchAdd(queued, .release);
                if (previous_count == 0) self.last_enqueue_ns.store(self.nowNs(), .release);
                offset += queued;
                self.wake.set(self.io);
            }
        }
    }

    fn publishFault(self: *InputReader) void {
        self.faulted.store(true, .release);
        self.wake.set(self.io);
    }

    fn nowNs(self: *InputReader) i64 {
        const ns = std.Io.Clock.awake.now(self.io).nanoseconds;
        if (ns > std.math.maxInt(i64)) return std.math.maxInt(i64);
        if (ns < std.math.minInt(i64)) return std.math.minInt(i64);
        return @intCast(ns);
    }

    fn hasReadable(revents: anytype) bool {
        const mask: @TypeOf(revents) = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR;
        return (revents & mask) != 0;
    }
};

fn createPipe() ![2]std.c.fd_t {
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.SystemResources;
    return fds;
}

fn closePipe(fds: [2]std.c.fd_t) void {
    _ = std.c.close(fds[0]);
    _ = std.c.close(fds[1]);
}

fn wakeCancel(fd: std.c.fd_t) void {
    const byte: [1]u8 = .{1};
    _ = std.c.write(fd, &byte, byte.len);
}

test "input reader queues bytes and wakes owner" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var wake: runtime.WakeEvent = .init;
    const reader = try InputReader.init(std.testing.allocator, io, &wake);
    defer reader.deinit();

    const source = try createPipe();
    defer closePipe(source);
    try reader.start(source[0]);

    const bytes = "abc";
    try std.testing.expectEqual(@as(isize, bytes.len), std.c.write(source[1], bytes.ptr, bytes.len));
    try wake.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(1000), .clock = .awake } });

    var out: [drain_chunk_bytes_max]u8 = undefined;
    const drained = reader.drain(&out);
    try std.testing.expectEqualStrings(bytes, drained.bytes);
    try std.testing.expect(drained.enqueue_ns != null);
}

test "input reader reports eof as bounded fact" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var wake: runtime.WakeEvent = .init;
    const reader = try InputReader.init(std.testing.allocator, io, &wake);
    defer reader.deinit();

    const source = try createPipe();
    defer _ = std.c.close(source[0]);
    try reader.start(source[0]);
    _ = std.c.close(source[1]);

    try wake.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(1000), .clock = .awake } });
    var out: [drain_chunk_bytes_max]u8 = undefined;
    const drained = reader.drain(&out);
    try std.testing.expect(drained.eof);
}
