const std = @import("std");
const wake = @import("wake.zig");

pub const Token = struct {
    controller: ?*Source,
    expected_generation: u64,

    pub const WaitPredicate = *const fn (ctx: ?*anyopaque) bool;
    pub const WaitResult = enum {
        aborted,
        predicate,
        timeout,
        none,
    };

    pub const none: Token = .{
        .controller = null,
        .expected_generation = 0,
    };

    pub const Callback = struct {
        ptr: *anyopaque,
        call: *const fn (ptr: *anyopaque) void,
    };

    pub const CallbackNode = struct {
        next: ?*CallbackNode = null,
        token: Token = Token.none,
        callback: Callback,
        registered: bool = false,
    };

    // Token validity is the Source generation, not only the aborted flag.
    pub fn isAborted(self: Token) bool {
        const controller = self.controller orelse return false;
        return controller.generation.load(.acquire) != self.expected_generation or controller.aborted.load(.acquire);
    }

    pub fn isNone(self: Token) bool {
        return self.controller == null and self.expected_generation == 0;
    }

    pub fn runId(self: Token) u64 {
        return self.expected_generation;
    }

    pub fn waitUntil(
        self: Token,
        timeout_ns: ?u64,
        predicate: ?WaitPredicate,
        predicate_ctx: ?*anyopaque,
    ) WaitResult {
        return self.waitUntilIo(std.Options.debug_io, timeout_ns, predicate, predicate_ctx);
    }

    pub fn waitUntilIo(
        self: Token,
        io: std.Io,
        timeout_ns: ?u64,
        predicate: ?WaitPredicate,
        predicate_ctx: ?*anyopaque,
    ) WaitResult {
        const controller = self.controller orelse {
            if (predicate) |pred| {
                if (pred(predicate_ctx)) return .predicate;
            }
            return if (timeout_ns == null) .none else .timeout;
        };

        const deadline_ns: ?i128 = if (timeout_ns) |timeout|
            @as(i128, @intCast(std.Io.Timestamp.now(io, .awake).toNanoseconds())) + @as(i128, @intCast(timeout))
        else
            null;

        controller.mutex.lockUncancelable(io);
        defer controller.mutex.unlock(io);

        while (true) {
            if (self.isAborted()) return .aborted;
            if (predicate) |pred| {
                if (pred(predicate_ctx)) return .predicate;
            }

            if (deadline_ns) |deadline| {
                const now = @as(i128, @intCast(std.Io.Timestamp.now(io, .awake).toNanoseconds()));
                if (now >= deadline) return .timeout;
                const remaining = @as(i96, @intCast(deadline - now));
                controller.mutex.unlock(io);
                io.sleep(.fromNanoseconds(remaining), .awake) catch {};
                controller.mutex.lockUncancelable(io);
            } else {
                controller.condition.waitUncancelable(io, &controller.mutex);
            }
        }
    }

    pub fn notifyWaiters(self: Token) void {
        const controller = self.controller orelse return;
        controller.notifyWaiters();
    }

    pub fn wakeReadFd(self: Token) ?std.posix.fd_t {
        const controller = self.controller orelse return null;
        return controller.wakeReadFd();
    }

    pub fn ensureWake(self: Token) !?std.posix.fd_t {
        const controller = self.controller orelse return null;
        return try controller.ensureWake();
    }

    pub fn acknowledgeWake(self: Token) void {
        const controller = self.controller orelse return;
        controller.acknowledgeWake();
    }

    pub fn registerCallback(self: Token, node: *CallbackNode, callback: Callback) void {
        const controller = self.controller orelse return;
        controller.mutex.lockUncancelable(std.Options.debug_io);
        defer controller.mutex.unlock(std.Options.debug_io);
        if (controller.generation.load(.acquire) != self.expected_generation) return;
        node.* = .{ .token = self, .callback = callback, .registered = true, .next = controller.callbacks };
        controller.callbacks = node;
    }

    pub fn unregisterCallback(self: Token, node: *CallbackNode) void {
        const controller = self.controller orelse return;
        controller.mutex.lockUncancelable(std.Options.debug_io);
        defer controller.mutex.unlock(std.Options.debug_io);
        controller.unlinkCallbackLocked(node);
    }
};

pub const Source = struct {
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    aborted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(1),
    wake_pipe: ?wake.Pipe = null,
    callbacks: ?*Token.CallbackNode = null,

    pub fn deinit(self: *Source) void {
        if (self.wake_pipe) |*pipe| pipe.deinit();
        self.* = .{};
    }

    // beginRun invalidates old tokens and wakes waiters before returning the new token.
    pub fn beginRun(self: *Source) Token {
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);

        self.aborted.store(true, .release);
        self.invokeCallbacksLocked();
        const next_generation = self.generation.load(.acquire) + 1;
        self.generation.store(next_generation, .release);
        self.condition.broadcast(std.Options.debug_io);
        self.signalWakeLocked(std.Options.debug_io);
        self.aborted.store(false, .release);

        return .{
            .controller = self,
            .expected_generation = next_generation,
        };
    }

    pub fn signal(self: *Source) Token {
        return .{
            .controller = self,
            .expected_generation = self.generation.load(.acquire),
        };
    }

    pub fn requestAbort(self: *Source) void {
        self.mutex.lockUncancelable(std.Options.debug_io);
        self.aborted.store(true, .release);
        self.condition.broadcast(std.Options.debug_io);
        self.signalWakeLocked(std.Options.debug_io);
        self.invokeCallbacksLocked();
        self.mutex.unlock(std.Options.debug_io);
    }

    pub fn notifyWaiters(self: *Source) void {
        self.notifyWaitersIo(std.Options.debug_io);
    }

    pub fn notifyWaitersIo(self: *Source, io: std.Io) void {
        self.condition.broadcast(io);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.signalWakeLocked(io);
    }

    pub fn ensureWake(self: *Source) !std.posix.fd_t {
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);
        if (self.wake_pipe == null) self.wake_pipe = try wake.Pipe.init();
        return self.wake_pipe.?.readFd();
    }

    pub fn wakeReadFd(self: *Source) ?std.posix.fd_t {
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);
        return if (self.wake_pipe) |pipe| pipe.readFd() else null;
    }

    pub fn acknowledgeWake(self: *Source) void {
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);
        if (self.wake_pipe) |pipe| pipe.drain();
    }

    fn signalWakeLocked(self: *Source, io: std.Io) void {
        if (self.wake_pipe) |pipe| _ = pipe.signal(io);
    }

    fn invokeCallbacksLocked(self: *Source) void {
        var node = self.callbacks;
        while (node) |current| : (node = current.next) {
            if (current.registered and current.token.expected_generation == self.generation.load(.acquire)) {
                current.callback.call(current.callback.ptr);
            }
        }
    }

    fn unlinkCallbackLocked(self: *Source, node: *Token.CallbackNode) void {
        var link = &self.callbacks;
        while (link.*) |current| {
            if (current == node) {
                link.* = current.next;
                node.registered = false;
                node.next = null;
                return;
            }
            link = &current.next;
        }
    }

    pub fn isAborted(self: *const Source) bool {
        return self.aborted.load(.acquire);
    }

    pub fn currentRunId(self: *const Source) u64 {
        return self.generation.load(.acquire);
    }
};

test "Source invalidates stale signals when a new run begins" {
    var controller = Source{};

    const first = controller.beginRun();
    try std.testing.expect(!first.isAborted());
    try std.testing.expect(first.runId() != 0);

    controller.requestAbort();
    try std.testing.expect(first.isAborted());

    const second = controller.beginRun();
    try std.testing.expect(!second.isAborted());
    try std.testing.expect(second.runId() != first.runId());
    try std.testing.expect(first.isAborted());
}

test "Token.waitUntil wakes for abort without polling" {
    var controller = Source{};
    const signal = controller.beginRun();

    const WaitCtx = struct {
        signal: Token,
        result: *Token.WaitResult,

        fn run(ctx: *@This()) void {
            ctx.result.* = ctx.signal.waitUntil(null, null, null);
        }
    };

    var result: Token.WaitResult = .none;
    var ctx: WaitCtx = .{ .signal = signal, .result = &result };
    const thread = try std.Thread.spawn(.{}, WaitCtx.run, .{&ctx});

    std.Options.debug_io.sleep(.fromNanoseconds(@intCast(10 * std.time.ns_per_ms)), .awake) catch {};
    controller.requestAbort();
    thread.join();
    try std.testing.expectEqual(.aborted, result);
}

test "Source exposes pollable cancellation wake" {
    var source = Source{};
    defer source.deinit();
    const token = source.beginRun();
    const fd = try source.ensureWake();

    var pfd = [1]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(usize, 0), try std.posix.poll(&pfd, 0));

    source.requestAbort();
    pfd[0].revents = 0;
    try std.testing.expectEqual(@as(usize, 1), try std.posix.poll(&pfd, 0));
    token.acknowledgeWake();
    pfd[0].revents = 0;
    try std.testing.expectEqual(@as(usize, 0), try std.posix.poll(&pfd, 0));
}

test "Token cancellation callbacks run without helper threads and unregister cleanly" {
    const Ctx = struct {
        count: u32 = 0,
        fn callback(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.count += 1;
        }
    };

    var source = Source{};
    defer source.deinit();
    const token = source.beginRun();
    var ctx = Ctx{};
    var node: Token.CallbackNode = undefined;

    token.registerCallback(&node, .{ .ptr = @ptrCast(&ctx), .call = Ctx.callback });
    source.requestAbort();
    try std.testing.expectEqual(@as(u32, 1), ctx.count);

    token.unregisterCallback(&node);
    source.requestAbort();
    try std.testing.expectEqual(@as(u32, 1), ctx.count);
}
