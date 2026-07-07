const std = @import("std");
const runtime = @import("../runtime/root.zig");
const Terminal = @import("Terminal.zig");

pub const byte_capacity = 32 * 1024;
pub const stamp_capacity = 64;
pub const drain_cap = 4096;
pub const pump_poll_ms = 100;
pub const read_buffer_capacity = 4096;
pub const ReadFn = *const fn (*anyopaque, []u8) anyerror!usize;

pub const BatchStamp = struct {
    ring_pos: u32,
    read_ns: u64,
    byte_count: usize,
};

pub fn SpscRing(comptime T: type, comptime capacity: u32) type {
    if (capacity == 0) @compileError("SpscRing capacity must be non-zero");
    if (capacity & (capacity - 1) != 0) @compileError("SpscRing capacity must be a power of two");

    return struct {
        const Self = @This();
        const mask = capacity - 1;

        buffer: [capacity]T = undefined,
        head: std.atomic.Value(u32) = .init(0),
        tail: std.atomic.Value(u32) = .init(0),

        pub fn count(self: *const Self) usize {
            const head = self.head.load(.acquire);
            const tail = self.tail.load(.acquire);
            return @intCast(tail -% head);
        }

        pub fn available(self: *const Self) usize {
            return capacity - self.count();
        }

        pub fn push(self: *Self, item: T) error{Full}!void {
            const tail = self.tail.load(.monotonic);
            const head = self.head.load(.acquire);
            if (tail -% head >= capacity) return error.Full;
            self.buffer[tail & mask] = item;
            self.tail.store(tail +% 1, .release);
        }

        pub fn pop(self: *Self) ?T {
            const head = self.head.load(.monotonic);
            const tail = self.tail.load(.acquire);
            if (head == tail) return null;
            const item = self.buffer[head & mask];
            self.head.store(head +% 1, .release);
            return item;
        }

        pub fn peek(self: *const Self) ?T {
            const head = self.head.load(.monotonic);
            const tail = self.tail.load(.acquire);
            if (head == tail) return null;
            return self.buffer[head & mask];
        }

        pub fn popSlice(self: *Self, out: []T) usize {
            var len: usize = 0;
            while (len < out.len) : (len += 1) {
                out[len] = self.pop() orelse break;
            }
            return len;
        }
    };
}

pub const InputPump = struct {
    ring: SpscRing(u8, byte_capacity) = .{},
    stamps: SpscRing(BatchStamp, stamp_capacity) = .{},
    stop: std.atomic.Value(bool) = .init(false),
    dropped_bytes: std.atomic.Value(usize) = .init(0),
    dropped_stamps: std.atomic.Value(usize) = .init(0),
    thread: ?std.Thread = null,
    io: std.Io = undefined,
    source_context: ?*anyopaque = null,
    read_fn: ?ReadFn = null,

    pub const StartOptions = struct {
        io: std.Io,
        source_context: *anyopaque,
        read_fn: ReadFn,
    };

    pub fn start(self: *InputPump, options: StartOptions) !void {
        self.io = options.io;
        self.source_context = options.source_context;
        self.read_fn = options.read_fn;
        self.stop.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn startTerminal(self: *InputPump, io: std.Io, terminal: *Terminal) !void {
        try self.start(.{
            .io = io,
            .source_context = terminal,
            .read_fn = terminalRead,
        });
    }

    pub fn requestStop(self: *InputPump) void {
        self.stop.store(true, .release);
    }

    pub fn join(self: *InputPump) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    fn run(self: *InputPump) void {
        const read_fn = self.read_fn orelse return;
        const source_context = self.source_context orelse return;
        var buffer: [read_buffer_capacity]u8 = undefined;
        while (!self.stop.load(.acquire)) {
            const count = read_fn(source_context, &buffer) catch |err| {
                if (isTransientReadError(err)) continue;
                break;
            };
            if (count == 0) continue;
            _ = self.pushBatch(buffer[0..count], nowNs(self.io));
        }
    }

    fn isTransientReadError(err: anyerror) bool {
        return err == error.WouldBlock or err == error.SignalInterrupt or err == error.Interrupted;
    }

    fn terminalRead(context: *anyopaque, out: []u8) !usize {
        const terminal: *Terminal = @ptrCast(@alignCast(context));
        _ = if (terminal.tty) |*tty| tty else return error.TerminalNotInitialized;
        const stdin = std.Io.File.stdin();
        const readable = try runtime.pollReadableFdTimeout(stdin.handle, pump_poll_ms);
        if (!readable) return 0;
        return std.posix.read(stdin.handle, out) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => err,
        };
    }

    fn nowNs(io: std.Io) u64 {
        const raw = std.Io.Timestamp.now(io, .awake).toNanoseconds();
        return if (raw <= 0) 0 else @intCast(raw);
    }

    pub fn pushBatch(self: *InputPump, bytes: []const u8, read_ns: u64) bool {
        if (bytes.len > self.ring.available()) {
            _ = self.dropped_bytes.fetchAdd(bytes.len, .monotonic);
            return false;
        }
        const batch_start = self.ring.tail.load(.monotonic);
        for (bytes) |byte| self.ring.push(byte) catch unreachable;
        self.stamps.push(.{ .ring_pos = batch_start, .read_ns = read_ns, .byte_count = bytes.len }) catch {
            _ = self.dropped_stamps.fetchAdd(1, .monotonic);
        };
        return true;
    }

    pub fn drainBytes(self: *InputPump, out: []u8) usize {
        return self.ring.popSlice(out[0..@min(out.len, drain_cap)]);
    }

    pub fn popByte(self: *InputPump) ?u8 {
        return self.ring.pop();
    }

    pub fn popStamp(self: *InputPump) ?BatchStamp {
        return self.stamps.pop();
    }

    pub fn drainConsumedStamps(self: *InputPump, out: []BatchStamp) usize {
        const consumed_pos = self.ring.head.load(.acquire);
        var len: usize = 0;
        while (len < out.len) : (len += 1) {
            const stamp = self.stamps.peek() orelse break;
            if (consumed_pos -% stamp.ring_pos < stamp.byte_count) break;
            out[len] = self.stamps.pop().?;
        }
        return len;
    }

    pub fn droppedByteCount(self: *const InputPump) usize {
        return self.dropped_bytes.load(.acquire);
    }

    pub fn pendingByteCount(self: *const InputPump) usize {
        return self.ring.count();
    }
};

test "spsc ring preserves order through wrap and reports full" {
    const Ring = SpscRing(u8, 4);
    var ring: Ring = .{};

    try ring.push(1);
    try ring.push(2);
    try ring.push(3);
    try ring.push(4);
    try std.testing.expectError(error.Full, ring.push(5));
    try std.testing.expectEqual(@as(?u8, 1), ring.pop());
    try std.testing.expectEqual(@as(?u8, 2), ring.pop());
    try ring.push(5);
    try ring.push(6);
    try std.testing.expectEqual(@as(?u8, 3), ring.pop());
    try std.testing.expectEqual(@as(?u8, 4), ring.pop());
    try std.testing.expectEqual(@as(?u8, 5), ring.pop());
    try std.testing.expectEqual(@as(?u8, 6), ring.pop());
    try std.testing.expectEqual(@as(?u8, null), ring.pop());
}

test "spsc ring pops bounded slices" {
    const Ring = SpscRing(u8, 8);
    var ring: Ring = .{};
    try ring.push('a');
    try ring.push('b');
    try ring.push('c');

    var out: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), ring.popSlice(&out));
    try std.testing.expectEqualStrings("ab", &out);
    try std.testing.expectEqual(@as(?u8, 'c'), ring.pop());
}

test "input pump drops whole byte batch on overflow" {
    var pump: InputPump = .{};
    var bytes: [byte_capacity]u8 = undefined;
    @memset(&bytes, 'x');

    try std.testing.expect(pump.pushBatch(&bytes, 10));
    try std.testing.expect(!pump.pushBatch("y", 11));
    try std.testing.expectEqual(@as(usize, 1), pump.droppedByteCount());

    const stamp = pump.popStamp().?;
    try std.testing.expectEqual(@as(u64, 10), stamp.read_ns);
    try std.testing.expectEqual(@as(usize, byte_capacity), stamp.byte_count);
}

test "input pump drainBytes is capped per owner iteration" {
    var pump: InputPump = .{};
    var bytes: [drain_cap + 8]u8 = undefined;
    @memset(&bytes, 'z');
    try std.testing.expect(pump.pushBatch(&bytes, 1));

    var out: [drain_cap + 8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, drain_cap), pump.drainBytes(&out));
    try std.testing.expectEqual(@as(usize, 8), pump.drainBytes(&out));
}

test "input pump exposes stamps only after batch bytes are drained" {
    var pump: InputPump = .{};
    try std.testing.expect(pump.pushBatch("abc", 10));

    var stamps: [stamp_capacity]BatchStamp = undefined;
    try std.testing.expectEqual(@as(usize, 0), pump.drainConsumedStamps(&stamps));

    var first: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), pump.drainBytes(&first));
    try std.testing.expectEqual(@as(usize, 0), pump.drainConsumedStamps(&stamps));

    var second: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), pump.drainBytes(&second));
    try std.testing.expectEqual(@as(usize, 1), pump.drainConsumedStamps(&stamps));
    try std.testing.expectEqual(@as(u64, 10), stamps[0].read_ns);
    try std.testing.expectEqual(@as(usize, 3), stamps[0].byte_count);
}

test "input pump thread reads source into ring" {
    const FakeSource = struct {
        bytes: []const u8,
        emitted: bool = false,

        fn read(context: *anyopaque, out: []u8) !usize {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.emitted) return error.EndOfStream;
            self.emitted = true;
            @memcpy(out[0..self.bytes.len], self.bytes);
            return self.bytes.len;
        }
    };

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var source: FakeSource = .{ .bytes = "abc" };
    var pump: InputPump = .{};
    try pump.start(.{
        .io = io,
        .source_context = &source,
        .read_fn = FakeSource.read,
    });
    defer pump.join();

    const wait_start_ns = InputPump.nowNs(io);
    while (pump.pendingByteCount() == 0 and InputPump.nowNs(io) -| wait_start_ns < std.time.ns_per_s) {
        runtime.sleep(io, .fromMilliseconds(1)) catch break;
    }
    pump.requestStop();
    try std.testing.expect(pump.pendingByteCount() > 0);

    var out: [3]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), pump.drainBytes(&out));
    try std.testing.expectEqualStrings("abc", &out);
}
