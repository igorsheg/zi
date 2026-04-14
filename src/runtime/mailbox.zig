const std = @import("std");
const posix = std.posix;

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

/// Mailbox(T) is zi's small typed cross-thread message primitive.
///
/// Durable semantic contract:
/// - one mailbox carries mutation/work messages for a single owner boundary
/// - message payload ownership must remain explicit across the thread crossing
/// - queue policy is explicit at init time, never implicit at the call site
/// - close/drain/deinit are distinct operations
/// - wake integration is composed alongside queue storage, not confused with it
/// - snapshots remain a separate primitive; mailbox use must not become ask/reply for UI reads
///
/// Delivery/cleanup semantics:
/// - `send` is best-effort and performs cleanup for any undelivered message
/// - `trySend` preserves the original message on `.closed`, `.full`, and `.oom`
/// - `.dropped` means queue policy intentionally discarded the newest message and the mailbox already cleaned it up
/// - `drainInto` transfers ownership of drained messages to the consumer buffer
/// - `deinit` cleans up any undelivered messages still retained by the mailbox

pub fn Mailbox(comptime T: type, comptime config: Config) type {
    comptime validateConfig(T, config);

    return struct {
        items: std.ArrayListUnmanaged(T) = .empty,
        mutex: std.Thread.Mutex = .{},
        allocator: std.mem.Allocator,
        closed: bool = false,
        rejected_count: usize = 0,
        dropped_count: usize = 0,
        wake_read_fd: ?posix.fd_t = null,
        wake_write_fd: ?posix.fd_t = null,

        const Self = @This();

        pub const Stats = struct {
            pending_depth: usize,
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
            var self = Self{ .allocator = allocator };
            switch (config.wakeup) {
                .none => {},
                .pipe => {
                    const pipe = try posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
                    self.wake_read_fd = pipe[0];
                    self.wake_write_fd = pipe[1];
                },
            }
            return self;
        }

        pub fn deinit(self: *Self) void {
            if (self.wake_read_fd) |fd| posix.close(fd);
            if (self.wake_write_fd) |fd| posix.close(fd);
            for (self.items.items) |*item| Self.cleanupItem(item, self.allocator);
            self.items.deinit(self.allocator);
            self.* = undefined;
        }

        /// Best-effort enqueue surface for existing call sites.
        ///
        /// Semantics:
        /// - delivered items are retained for receiver-side drain
        /// - `.drop_newest` bounded policy cleans the item and treats that as a handled outcome
        /// - `.closed`, `.full`, and `.oom` all clean the unsent item locally
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

        /// Precise enqueue surface that preserves ownership on failure.
        ///
        /// Results:
        /// - `.ok`       — message enqueued
        /// - `.dropped`  — queue policy intentionally dropped newest; message already cleaned up by mailbox
        /// - `.closed`   — mailbox closed; caller receives original message back
        /// - `.full`     — bounded queue rejected send; caller receives original message back
        /// - `.oom`      — append allocation failed; caller receives original message back
        pub fn trySend(self: *Self, item: T) TrySendResult {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.closed) {
                self.rejected_count += 1;
                return .{ .closed = item };
            }

            switch (config.policy) {
                .unbounded => {},
                .bounded => |bounded| {
                    if (self.items.items.len >= bounded.capacity) {
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

            self.items.append(self.allocator, item) catch {
                self.rejected_count += 1;
                return .{ .oom = item };
            };
            self.signalWake();
            return .ok;
        }

        pub fn close(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.closed) return;
            self.closed = true;
            self.signalWake();
        }

        pub fn drainInto(self: *Self, out: []T) usize {
            self.mutex.lock();
            defer self.mutex.unlock();

            const count = @min(self.items.items.len, out.len);
            if (count == 0) {
                self.drainWakePipe();
                return 0;
            }
            @memcpy(out[0..count], self.items.items[0..count]);
            if (count < self.items.items.len) {
                const remaining = self.items.items.len - count;
                std.mem.copyForwards(T, self.items.items[0..remaining], self.items.items[count .. count + remaining]);
            }
            self.items.items.len -= count;
            if (self.items.items.len == 0) {
                self.drainWakePipe();
            } else {
                self.signalWake();
            }
            return count;
        }

        /// Non-blocking acknowledgement hook for wake-integrated mailboxes.
        ///
        /// Today this composes with pipe wakeups used by the TUI poll loop.
        /// For `.none` wakeups, the mailbox intentionally does not invent a
        /// blocking scheduler path.
        pub fn wait(self: *Self) void {
            switch (config.wakeup) {
                .none => {},
                .pipe => self.acknowledgeWake(),
            }
        }

        pub fn wakeReadFd(self: *const Self) ?posix.fd_t {
            return self.wake_read_fd;
        }

        pub fn hasWakeFd(_: *const Self) bool {
            return config.wakeup == .pipe;
        }

        pub fn acknowledgeWake(self: *Self) void {
            self.drainWakePipe();
        }

        pub fn stats(self: *Self) Stats {
            self.mutex.lock();
            defer self.mutex.unlock();
            return .{
                .pending_depth = self.items.items.len,
                .closed = self.closed,
                .rejected_count = self.rejected_count,
                .dropped_count = self.dropped_count,
            };
        }

        pub fn isClosed(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.closed;
        }

        pub fn pendingDepth(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.items.items.len;
        }

        fn signalWake(self: *Self) void {
            switch (config.wakeup) {
                .none => {},
                .pipe => {
                    _ = posix.write(self.wake_write_fd.?, &[1]u8{1}) catch |err| switch (err) {
                        error.WouldBlock => 0,
                        else => 0,
                    };
                },
            }
        }

        fn drainWakePipe(self: *Self) void {
            switch (config.wakeup) {
                .none => {},
                .pipe => {
                    var buf: [64]u8 = undefined;
                    while (true) {
                        const n = posix.read(self.wake_read_fd.?, &buf) catch |err| switch (err) {
                            error.WouldBlock => return,
                            else => return,
                        };
                        if (n == 0 or n < buf.len) return;
                    }
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
                @compileError("Mailbox cleanup=.deinit requires T.deinit(allocator)");
            }
        },
        .custom => |func| {
            const FuncType = @TypeOf(func);
            const info = @typeInfo(FuncType);
            if (info != .pointer or @typeInfo(info.pointer.child) != .@"fn") {
                @compileError("Mailbox cleanup=.custom requires a function pointer");
            }
        },
    }

    switch (config.policy) {
        .unbounded => {},
        .bounded => |bounded| {
            if (bounded.capacity == 0) {
                @compileError("bounded Mailbox capacity must be > 0");
            }
        },
    }
}


test "Mailbox delivers in FIFO order, preserves pending stats, and drains ownership to consumer" {
    const Msg = struct {
        value: u32,
    };

    var mailbox = try Mailbox(Msg, .{ .policy = .unbounded, .wakeup = .none }).init(std.testing.allocator);
    defer mailbox.deinit();

    try std.testing.expectEqual(@as(usize, 0), mailbox.pendingDepth());
    try std.testing.expectEqual(.ok, mailbox.trySend(.{ .value = 7 }));
    try std.testing.expectEqual(.ok, mailbox.trySend(.{ .value = 8 }));
    try std.testing.expectEqual(@as(usize, 2), mailbox.pendingDepth());
    try std.testing.expect(!mailbox.isClosed());

    var out: [4]Msg = undefined;
    const n = mailbox.drainInto(&out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(u32, 7), out[0].value);
    try std.testing.expectEqual(@as(u32, 8), out[1].value);
    try std.testing.expectEqual(@as(usize, 0), mailbox.pendingDepth());
}

test "Mailbox bounded policies make rejection vs drop explicit and preserve cleanup ownership" {
    const Msg = struct {
        value: u32,
    };

    const CleanupState = struct {
        var cleaned: usize = 0;

        fn cleanup(item: *anyopaque, _: std.mem.Allocator) void {
            const msg: *Msg = @ptrCast(@alignCast(item));
            _ = msg;
            cleaned += 1;
        }
    };

    var reject_box = try Mailbox(Msg, .{ .policy = .{ .bounded = .{ .capacity = 1, .on_full = .reject } } }).init(std.testing.allocator);
    defer reject_box.deinit();

    try std.testing.expectEqual(.ok, reject_box.trySend(.{ .value = 1 }));
    switch (reject_box.trySend(.{ .value = 2 })) {
        .full => |msg| try std.testing.expectEqual(@as(u32, 2), msg.value),
        else => return error.UnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 1), reject_box.stats().rejected_count);

    CleanupState.cleaned = 0;
    var drop_box = try Mailbox(Msg, .{
        .cleanup = .{ .custom = &CleanupState.cleanup },
        .policy = .{ .bounded = .{ .capacity = 1, .on_full = .drop_newest } },
    }).init(std.testing.allocator);
    defer drop_box.deinit();

    try std.testing.expectEqual(.ok, drop_box.trySend(.{ .value = 11 }));
    try std.testing.expectEqual(.dropped, drop_box.trySend(.{ .value = 12 }));
    try std.testing.expectEqual(@as(usize, 1), drop_box.stats().dropped_count);
    try std.testing.expectEqual(@as(usize, 1), CleanupState.cleaned);

    var out: [2]Msg = undefined;
    const n = drop_box.drainInto(&out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u32, 11), out[0].value);
}

test "Mailbox close stops future sends, preserves queued work, and wakes pipe-backed consumers" {
    const Msg = struct { value: u32 };
    var mailbox = try Mailbox(Msg, .{ .wakeup = .pipe }).init(std.testing.allocator);
    defer mailbox.deinit();

    try std.testing.expectEqual(.ok, mailbox.trySend(.{ .value = 9 }));
    try std.testing.expect(mailbox.hasWakeFd());

    var pfd = [1]posix.pollfd{.{
        .fd = mailbox.wakeReadFd().?,
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 1), try posix.poll(&pfd, 0));

    mailbox.close();
    switch (mailbox.trySend(.{ .value = 10 })) {
        .closed => |msg| try std.testing.expectEqual(@as(u32, 10), msg.value),
        else => return error.UnexpectedResult,
    }
    try std.testing.expect(mailbox.isClosed());

    var out: [2]Msg = undefined;
    const n = mailbox.drainInto(&out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u32, 9), out[0].value);
}
