const std = @import("std");
const posix = std.posix;
const wake_mod = @import("wake.zig");

pub const Wakeup = enum {
    none,
    pipe,
};

pub const Cleanup = union(enum) {
    none,
    deinit,
    custom: *const fn (item: *anyopaque, allocator: std.mem.Allocator) void,
};

pub const FullBehavior = enum {
    reject,
    drop_newest,
};

// Reject returns ownership to the caller. drop_newest consumes through queue cleanup.
pub const QueuePolicy = union(enum) {
    unbounded,
    bounded: struct {
        capacity: usize,
        on_full: FullBehavior,
    },
};

pub const Config = struct {
    cleanup: Cleanup = .none,
    policy: QueuePolicy = .unbounded,
    wakeup: Wakeup = .none,
};

pub const State = enum {
    active,
    closing,
    closed,
};

pub const CloseMode = enum {
    graceful,

    immediate,
};

pub fn Queue(comptime T: type, comptime config: Config) type {
    comptime validateConfig(T, config);

    return struct {
        queue: QueueStorage = .{},
        mutex: std.Io.Mutex = .init,
        allocator: std.mem.Allocator,
        io: std.Io,
        state: State = .active,
        rejected_count: usize = 0,
        dropped_count: usize = 0,
        high_water_depth: usize = 0,
        send_count: usize = 0,
        wake_count: usize = 0,
        wake_pipe: ?wake_mod.Pipe = null,
        wake_signaled: bool = false,

        const Self = @This();

        const QueueStorage = struct {
            storage: std.ArrayList(T) = .empty,
            head: usize = 0,
            len: usize = 0,

            fn deinit(self: *QueueStorage, allocator: std.mem.Allocator) void {
                self.storage.deinit(allocator);
                self.* = .{};
            }

            fn capacity(self: *const QueueStorage) usize {
                return self.storage.items.len;
            }

            fn append(self: *QueueStorage, allocator: std.mem.Allocator, item: T) !void {
                try self.ensureCapacity(allocator, self.len + 1);
                const cap = self.capacity();
                const tail = if (cap == 0) 0 else @mod(self.head + self.len, cap);
                self.storage.items[tail] = item;
                self.len += 1;
            }

            fn drainInto(self: *QueueStorage, out: []T) usize {
                const count = @min(self.len, out.len);
                if (count == 0) return 0;

                const cap = self.capacity();
                for (out[0..count], 0..) |*slot, i| {
                    slot.* = self.storage.items[@mod(self.head + i, cap)];
                }
                self.head = @mod(self.head + count, cap);
                self.len -= count;
                if (self.len == 0) self.head = 0;
                return count;
            }

            fn itemPtr(self: *QueueStorage, index: usize) *T {
                return &self.storage.items[@mod(self.head + index, self.capacity())];
            }

            fn ensureCapacity(self: *QueueStorage, allocator: std.mem.Allocator, needed: usize) !void {
                if (needed <= self.capacity()) return;

                var new_cap: usize = if (self.capacity() == 0) @max(needed, 8) else self.capacity();
                while (new_cap < needed) {
                    new_cap = std.math.mul(usize, new_cap, 2) catch return error.OutOfMemory;
                }

                var grown: std.ArrayList(T) = .empty;
                errdefer grown.deinit(allocator);
                try grown.resize(allocator, new_cap);
                for (0..self.len) |i| {
                    grown.items[i] = self.itemPtr(i).*;
                }

                self.storage.deinit(allocator);
                self.storage = grown;
                self.head = 0;
            }
        };

        pub const Stats = struct {
            pending_depth: usize,
            high_water_depth: usize,
            send_count: usize,
            wake_count: usize,
            state: State,
            closed: bool,
            rejected_count: usize,
            dropped_count: usize,
        };

        pub const TrySendResult = union(enum) {
            ok,
            dropped,
            closed: T,
            full: T,
            oom: T,
        };

        pub fn init(allocator: std.mem.Allocator) !Self {
            return initIo(allocator, std.Options.debug_io);
        }

        pub fn initIo(allocator: std.mem.Allocator, io: std.Io) !Self {
            var self = Self{ .allocator = allocator, .io = io };
            switch (config.wakeup) {
                .none => {},
                .pipe => self.wake_pipe = try wake_mod.Pipe.init(),
            }
            return self;
        }

        pub fn deinit(self: *Self) void {
            for (0..self.queue.len) |i| {
                const item = self.queue.itemPtr(i);
                Self.cleanupItem(item, self.allocator);
            }
            self.queue.deinit(self.allocator);
            if (self.wake_pipe) |*pipe| pipe.deinit();
            self.* = undefined;
        }

        // send consumes rejected items and runs cleanup. trySend returns ownership on failure.
        pub fn send(self: *Self, item: T) void {
            switch (self.trySend(item)) {
                .ok, .dropped => {},
                .closed, .full, .oom => |returned| {
                    var mutable = returned;
                    Self.cleanupItem(&mutable, self.allocator);
                },
            }
        }

        pub fn push(self: *Self, item: T) void {
            self.send(item);
        }

        pub fn trySend(self: *Self, item: T) TrySendResult {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            if (self.state != .active) {
                self.rejected_count += 1;
                return .{ .closed = item };
            }

            switch (config.policy) {
                .unbounded => {},
                .bounded => |bounded| {
                    if (self.queue.len >= bounded.capacity) {
                        return switch (bounded.on_full) {
                            .reject => blk: {
                                self.rejected_count += 1;
                                break :blk .{ .full = item };
                            },
                            .drop_newest => blk: {
                                self.dropped_count += 1;
                                var mutable = item;
                                Self.cleanupItem(&mutable, self.allocator);
                                break :blk .dropped;
                            },
                        };
                    }
                },
            }

            const was_empty = self.queue.len == 0;
            self.queue.append(self.allocator, item) catch {
                self.rejected_count += 1;
                return .{ .oom = item };
            };
            self.send_count += 1;
            self.high_water_depth = @max(self.high_water_depth, self.queue.len);
            if (was_empty) self.signalWakeLocked();
            return .ok;
        }

        pub fn close(self: *Self) void {
            self.closeMode(.graceful);
        }

        pub fn closeImmediate(self: *Self) void {
            self.closeMode(.immediate);
        }

        pub fn closeMode(self: *Self, mode: CloseMode) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            if (self.state == .closed) return;
            switch (mode) {
                .graceful => {
                    if (self.state != .active) return;
                    self.state = if (self.queue.len == 0) .closed else .closing;
                },
                .immediate => {
                    for (0..self.queue.len) |i| {
                        Self.cleanupItem(self.queue.itemPtr(i), self.allocator);
                    }
                    self.queue.len = 0;
                    self.queue.head = 0;
                    self.state = .closed;
                },
            }
            self.signalWakeLocked();
        }

        pub fn drainInto(self: *Self, out: []T) usize {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            const count = self.queue.drainInto(out);
            self.reconcileStateAndWakeLocked();
            return count;
        }

        pub fn visitPending(
            self: *Self,
            visitor: *const fn (item: *const T, ctx: ?*anyopaque) anyerror!void,
            ctx: ?*anyopaque,
        ) anyerror!void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            for (0..self.queue.len) |i| {
                try visitor(self.queue.itemPtr(i), ctx);
            }
        }

        pub fn visitAndClear(
            self: *Self,
            visitor: *const fn (item: *const T, ctx: ?*anyopaque) anyerror!void,
            ctx: ?*anyopaque,
        ) anyerror!void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            for (0..self.queue.len) |i| {
                try visitor(self.queue.itemPtr(i), ctx);
            }
            for (0..self.queue.len) |i| {
                Self.cleanupItem(self.queue.itemPtr(i), self.allocator);
            }
            self.queue.len = 0;
            self.queue.head = 0;
            self.reconcileStateAndWakeLocked();
        }

        pub fn dropMatching(
            self: *Self,
            predicate: *const fn (item: *const T, ctx: ?*anyopaque) bool,
            ctx: ?*anyopaque,
        ) usize {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            if (self.queue.len == 0) return 0;
            const original_len = self.queue.len;
            const snapshot = self.allocator.alloc(T, original_len) catch return 0;
            defer self.allocator.free(snapshot);

            for (0..original_len) |i| snapshot[i] = self.queue.itemPtr(i).*;

            var kept: usize = 0;
            var dropped: usize = 0;
            for (snapshot, 0..) |item, i| {
                if (predicate(&item, ctx)) {
                    Self.cleanupItem(self.queue.itemPtr(i), self.allocator);
                    dropped += 1;
                } else {
                    self.queue.storage.items[kept] = item;
                    kept += 1;
                }
            }
            self.queue.head = 0;
            self.queue.len = kept;
            self.dropped_count += dropped;
            self.reconcileStateAndWakeLocked();
            return dropped;
        }

        pub fn clear(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            for (0..self.queue.len) |i| {
                Self.cleanupItem(self.queue.itemPtr(i), self.allocator);
            }
            self.queue.len = 0;
            self.queue.head = 0;
            self.reconcileStateAndWakeLocked();
        }

        pub fn wait(self: *Self) void {
            switch (config.wakeup) {
                .none => {},
                .pipe => self.acknowledgeWake(),
            }
        }

        pub fn waitReadable(self: *Self, timeout_ms: i32) !bool {
            comptime if (config.wakeup != .pipe) {
                @compileError("Queue.waitReadable requires wakeup=.pipe");
            };

            var pfd = [1]posix.pollfd{.{
                .fd = self.wake_pipe.?.readFd(),
                .events = posix.POLL.IN,
                .revents = 0,
            }};
            const ready = try posix.poll(&pfd, timeout_ms);
            if (ready <= 0) return false;
            if (pfd[0].revents & posix.POLL.IN == 0) return false;
            self.acknowledgeWake();
            return true;
        }

        pub fn wakeReadFd(self: *const Self) ?posix.fd_t {
            return if (self.wake_pipe) |pipe| pipe.readFd() else null;
        }

        pub fn hasWakeFd(_: *const Self) bool {
            return config.wakeup == .pipe;
        }

        pub fn acknowledgeWake(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.queue.len != 0) return;
            self.clearWakeLocked();
        }

        pub fn stats(self: *Self) Stats {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return .{
                .pending_depth = self.queue.len,
                .high_water_depth = self.high_water_depth,
                .send_count = self.send_count,
                .wake_count = self.wake_count,
                .state = self.state,
                .closed = self.state == .closed,
                .rejected_count = self.rejected_count,
                .dropped_count = self.dropped_count,
            };
        }

        pub fn lifecycleState(self: *Self) State {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return self.state;
        }

        pub fn isClosed(self: *Self) bool {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return self.state != .active;
        }

        pub fn isDrained(self: *Self) bool {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return self.state == .closed;
        }

        pub fn pendingDepth(self: *Self) usize {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return self.queue.len;
        }

        fn reconcileStateAndWakeLocked(self: *Self) void {
            if (self.queue.len == 0 and self.state == .closing) {
                self.state = .closed;
            }
            if (self.queue.len == 0) {
                self.clearWakeLocked();
            }
        }

        fn signalWakeLocked(self: *Self) void {
            switch (config.wakeup) {
                .none => {},
                .pipe => {
                    if (self.wake_signaled) return;
                    if (!self.wake_pipe.?.signal(self.io)) return;
                    self.wake_signaled = true;
                    self.wake_count += 1;
                },
            }
        }

        fn clearWakeLocked(self: *Self) void {
            switch (config.wakeup) {
                .none => {},
                .pipe => {
                    if (!self.wake_signaled) return;
                    self.wake_signaled = false;
                    self.wake_pipe.?.drain();
                },
            }
        }

        fn cleanupItem(item: *T, allocator: std.mem.Allocator) void {
            switch (config.cleanup) {
                .none => {},
                .deinit => item.deinit(allocator),
                .custom => |func| func(@ptrCast(item), allocator),
            }
        }
    };
}

fn validateConfig(comptime T: type, comptime config: Config) void {
    switch (config.cleanup) {
        .none => {},
        .deinit => {
            if (!@hasDecl(T, "deinit")) {
                @compileError("Queue cleanup=.deinit requires T.deinit(allocator)");
            }
        },
        .custom => |func| {
            const FuncType = @TypeOf(func);
            const info = @typeInfo(FuncType);
            if (info != .pointer or @typeInfo(info.pointer.child) != .@"fn") {
                @compileError("Queue cleanup=.custom requires a function pointer");
            }
        },
    }

    switch (config.policy) {
        .unbounded => {},
        .bounded => |bounded| {
            if (bounded.capacity == 0) {
                @compileError("bounded Queue capacity must be > 0");
            }
        },
    }
}

test "Queue ring storage preserves FIFO across partial drains and wraparound" {
    const Msg = struct { value: u32 };

    var queue = try Queue(Msg, .{ .policy = .unbounded, .wakeup = .none }).init(std.testing.allocator);
    defer queue.deinit();

    for (1..9) |i| {
        try std.testing.expectEqual(.ok, queue.trySend(.{ .value = @intCast(i) }));
    }

    var first: [3]Msg = undefined;
    try std.testing.expectEqual(@as(usize, 3), queue.drainInto(&first));
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, &[_]u32{ first[0].value, first[1].value, first[2].value });

    for (9..15) |i| {
        try std.testing.expectEqual(.ok, queue.trySend(.{ .value = @intCast(i) }));
    }

    var rest: [16]Msg = undefined;
    const n = queue.drainInto(&rest);
    try std.testing.expectEqual(@as(usize, 11), n);
    try std.testing.expectEqualSlices(u32, &.{ 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14 }, &[_]u32{
        rest[0].value,
        rest[1].value,
        rest[2].value,
        rest[3].value,
        rest[4].value,
        rest[5].value,
        rest[6].value,
        rest[7].value,
        rest[8].value,
        rest[9].value,
        rest[10].value,
    });
    const stats = queue.stats();
    try std.testing.expectEqual(@as(usize, 0), stats.pending_depth);
    try std.testing.expectEqual(@as(usize, 11), stats.high_water_depth);
    try std.testing.expectEqual(@as(usize, 14), stats.send_count);
    try std.testing.expectEqual(@as(usize, 0), stats.wake_count);
    try std.testing.expectEqual(State.active, queue.lifecycleState());
}

test "Queue bounded policies make rejection vs drop explicit and preserve cleanup ownership" {
    const Msg = struct { value: u32 };

    const CleanupState = struct {
        var cleaned: usize = 0;

        fn cleanup(item: *anyopaque, _: std.mem.Allocator) void {
            const msg: *Msg = @ptrCast(@alignCast(item));
            _ = msg;
            cleaned += 1;
        }
    };

    var reject_box = try Queue(Msg, .{ .policy = .{ .bounded = .{ .capacity = 1, .on_full = .reject } } }).init(std.testing.allocator);
    defer reject_box.deinit();

    try std.testing.expectEqual(.ok, reject_box.trySend(.{ .value = 1 }));
    switch (reject_box.trySend(.{ .value = 2 })) {
        .full => |msg| try std.testing.expectEqual(@as(u32, 2), msg.value),
        else => return error.UnexpectedResult,
    }
    const reject_stats = reject_box.stats();
    try std.testing.expectEqual(@as(usize, 1), reject_stats.pending_depth);
    try std.testing.expectEqual(@as(usize, 1), reject_stats.rejected_count);
    try std.testing.expectEqual(@as(usize, 1), reject_stats.high_water_depth);
    try std.testing.expectEqual(@as(usize, 1), reject_stats.send_count);

    CleanupState.cleaned = 0;
    var drop_box = try Queue(Msg, .{
        .cleanup = .{ .custom = &CleanupState.cleanup },
        .policy = .{ .bounded = .{ .capacity = 1, .on_full = .drop_newest } },
    }).init(std.testing.allocator);
    defer drop_box.deinit();

    try std.testing.expectEqual(.ok, drop_box.trySend(.{ .value = 11 }));
    try std.testing.expectEqual(.dropped, drop_box.trySend(.{ .value = 12 }));
    const drop_stats = drop_box.stats();
    try std.testing.expectEqual(@as(usize, 1), drop_stats.pending_depth);
    try std.testing.expectEqual(@as(usize, 1), drop_stats.dropped_count);
    try std.testing.expectEqual(@as(usize, 1), drop_stats.high_water_depth);
    try std.testing.expectEqual(@as(usize, 1), drop_stats.send_count);
    try std.testing.expectEqual(@as(usize, 1), CleanupState.cleaned);

    var out: [2]Msg = undefined;
    const n = drop_box.drainInto(&out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u32, 11), out[0].value);
}

test "Queue dropMatching cleans matches and preserves FIFO order" {
    const Msg = struct { value: u32 };
    const CleanupState = struct {
        var cleaned: usize = 0;
        fn cleanup(item: *anyopaque, _: std.mem.Allocator) void {
            const msg: *Msg = @ptrCast(@alignCast(item));
            _ = msg;
            cleaned += 1;
        }
        fn isEven(item: *const Msg, _: ?*anyopaque) bool {
            return item.value % 2 == 0;
        }
    };

    CleanupState.cleaned = 0;
    var queue = try Queue(Msg, .{ .cleanup = .{ .custom = &CleanupState.cleanup } }).init(std.testing.allocator);
    defer queue.deinit();

    for (1..6) |i| try std.testing.expectEqual(.ok, queue.trySend(.{ .value = @intCast(i) }));
    try std.testing.expectEqual(@as(usize, 2), queue.dropMatching(&CleanupState.isEven, null));
    try std.testing.expectEqual(@as(usize, 2), CleanupState.cleaned);

    var out: [4]Msg = undefined;
    const n = queue.drainInto(&out);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualSlices(u32, &.{ 1, 3, 5 }, &[_]u32{ out[0].value, out[1].value, out[2].value });

    for (10..18) |i| try std.testing.expectEqual(.ok, queue.trySend(.{ .value = @intCast(i) }));
    var partial: [3]Msg = undefined;
    try std.testing.expectEqual(@as(usize, 3), queue.drainInto(&partial));
    try std.testing.expectEqual(.ok, queue.trySend(.{ .value = 18 }));
    try std.testing.expectEqual(.ok, queue.trySend(.{ .value = 19 }));
    try std.testing.expectEqual(@as(usize, 3), queue.dropMatching(&CleanupState.isEven, null));

    var wrapped_out: [8]Msg = undefined;
    const wrapped_n = queue.drainInto(&wrapped_out);
    try std.testing.expectEqual(@as(usize, 4), wrapped_n);
    try std.testing.expectEqualSlices(u32, &.{ 13, 15, 17, 19 }, &[_]u32{ wrapped_out[0].value, wrapped_out[1].value, wrapped_out[2].value, wrapped_out[3].value });
}

test "Queue coalesces pipe wake readiness until the queue drains" {
    const Msg = struct { value: u32 };
    var queue = try Queue(Msg, .{ .wakeup = .pipe }).init(std.testing.allocator);
    defer queue.deinit();

    try std.testing.expectEqual(.ok, queue.trySend(.{ .value = 9 }));
    try std.testing.expectEqual(.ok, queue.trySend(.{ .value = 10 }));
    try std.testing.expect(queue.hasWakeFd());

    var pfd = [1]posix.pollfd{.{
        .fd = queue.wakeReadFd().?,
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 1), try posix.poll(&pfd, 0));
    try std.testing.expect(try queue.waitReadable(0));
    try std.testing.expectEqual(@as(usize, 1), queue.stats().wake_count);

    pfd[0].revents = 0;
    try std.testing.expectEqual(@as(usize, 1), try posix.poll(&pfd, 0));

    var out: [1]Msg = undefined;
    try std.testing.expectEqual(@as(usize, 1), queue.drainInto(&out));
    try std.testing.expectEqual(@as(u32, 9), out[0].value);

    pfd[0].revents = 0;
    try std.testing.expectEqual(@as(usize, 1), try posix.poll(&pfd, 0));

    try std.testing.expectEqual(@as(usize, 1), queue.drainInto(&out));
    try std.testing.expectEqual(@as(u32, 10), out[0].value);

    pfd[0].revents = 0;
    try std.testing.expectEqual(@as(usize, 0), try posix.poll(&pfd, 0));
}

test "Queue closeImmediate closes, cleans pending work, and wakes terminal waiters" {
    const Msg = struct { value: u32 };
    const CleanupState = struct {
        var cleaned: usize = 0;
        fn cleanup(item: *anyopaque, _: std.mem.Allocator) void {
            const msg: *Msg = @ptrCast(@alignCast(item));
            _ = msg;
            cleaned += 1;
        }
    };

    CleanupState.cleaned = 0;
    var queue = try Queue(Msg, .{ .cleanup = .{ .custom = &CleanupState.cleanup }, .wakeup = .pipe }).init(std.testing.allocator);
    defer queue.deinit();

    try std.testing.expectEqual(.ok, queue.trySend(.{ .value = 1 }));
    try std.testing.expectEqual(.ok, queue.trySend(.{ .value = 2 }));
    queue.closeImmediate();

    try std.testing.expectEqual(State.closed, queue.lifecycleState());
    try std.testing.expect(queue.isDrained());
    try std.testing.expectEqual(@as(usize, 2), CleanupState.cleaned);
    try std.testing.expectEqual(@as(usize, 0), queue.pendingDepth());
    try std.testing.expect(try queue.waitReadable(0));

    switch (queue.trySend(.{ .value = 3 })) {
        .closed => |msg| try std.testing.expectEqual(@as(u32, 3), msg.value),
        else => return error.UnexpectedResult,
    }
}

test "Queue close transitions active to closing to closed and preserves queued work" {
    const Msg = struct { value: u32 };
    var queue = try Queue(Msg, .{ .wakeup = .pipe }).init(std.testing.allocator);
    defer queue.deinit();

    try std.testing.expectEqual(.ok, queue.trySend(.{ .value = 21 }));
    queue.close();

    try std.testing.expect(queue.isClosed());
    try std.testing.expectEqual(State.closing, queue.lifecycleState());
    switch (queue.trySend(.{ .value = 22 })) {
        .closed => |msg| try std.testing.expectEqual(@as(u32, 22), msg.value),
        else => return error.UnexpectedResult,
    }

    var out: [2]Msg = undefined;
    try std.testing.expectEqual(@as(usize, 1), queue.drainInto(&out));
    try std.testing.expectEqual(@as(u32, 21), out[0].value);
    const stats = queue.stats();
    try std.testing.expectEqual(@as(usize, 1), stats.rejected_count);
    try std.testing.expectEqual(@as(usize, 1), stats.send_count);
    try std.testing.expectEqual(@as(usize, 1), stats.high_water_depth);
    try std.testing.expectEqual(State.closed, queue.lifecycleState());
    try std.testing.expect(queue.isDrained());
}
