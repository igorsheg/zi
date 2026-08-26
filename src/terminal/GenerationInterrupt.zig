const std = @import("std");
const builtin = @import("builtin");
const EscapeClassifier = @import("EscapeClassifier.zig");
const PosixMode = @import("PosixMode.zig");
const ProcessSpawn = @import("../ProcessSpawn.zig");
const GenerationInterrupt = @This();

const posix = std.posix;
const system = posix.system;

pub const Signal = enum(u8) {
    none,
    pause,
    abort,
};

/// A synchronous erased callback. Its context must remain valid until `deinit`
/// has joined the watcher.
pub const Wake = struct {
    context: *anyopaque,
    call_fn: *const fn (*anyopaque) void,

    pub fn call(self: Wake) void {
        self.call_fn(self.context);
    }

    pub fn from(implementation: anytype) Wake {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one or
            pointer_info.pointer.is_const)
        {
            @compileError("Wake.from expects a mutable single-item pointer");
        }
        const Adapter = struct {
            fn call(context: *anyopaque) void {
                const self: Pointer = @ptrCast(@alignCast(context));
                self.wake();
            }
        };
        return .{ .context = implementation, .call_fn = Adapter.call };
    }
};

const Command = enum(u8) {
    idle,
    armed,
    stop,
};

const Shared = struct {
    io: std.Io,
    input_fd: posix.fd_t,
    wake_read_fd: posix.fd_t,
    wake_write_fd: posix.fd_t,
    callback: Wake,
    command: std.atomic.Value(Command) = .init(.idle),
    watching: std.atomic.Value(bool) = .init(false),
    signal: std.atomic.Value(Signal) = .init(.none),
    resolve_request: std.atomic.Value(u64) = .init(0),
    resolve_ack: std.atomic.Value(u64) = .init(0),
    escape_pending: std.atomic.Value(bool) = .init(false),
    classifying: std.atomic.Value(bool) = .init(false),
};

const Discard = struct {
    context: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, posix.fd_t) error{Unexpected}!void = posixDiscard,

    fn call(self: Discard, fd: posix.fd_t) error{Unexpected}!void {
        return self.call_fn(self.context, fd);
    }
};

allocator: std.mem.Allocator,
io: std.Io,
mode: PosixMode,
shared: ?*Shared = null,
flush_input: bool = false,
discard_pending: bool = false,
discard: Discard = .{},
joined: bool = false,

/// Creates an inert owner unless both explicit files are TTYs. Files stay owned
/// by the caller and must remain open through `deinit`.
pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdin_file: std.Io.File,
    stdout_file: std.Io.File,
    wake: Wake,
) !GenerationInterrupt {
    var self: GenerationInterrupt = .{
        .allocator = allocator,
        .io = io,
        .mode = .init(stdin_file),
    };
    if (!try stdin_file.isTty(io) or !try stdout_file.isTty(io)) return self;
    try self.start(stdin_file.handle, wake, true);
    return self;
}

/// Applies generation mode before publishing input ownership to the watcher.
pub fn clearAndArm(self: *GenerationInterrupt) !void {
    const shared = self.shared orelse return;
    if (shared.command.load(.acquire) != .idle or shared.watching.load(.acquire)) {
        return error.AlreadyArmed;
    }
    try self.mode.apply(.generation_interrupt);
    self.discard_pending = self.flush_input;
    shared.signal.store(.none, .release);
    shared.command.store(.armed, .release);
    wakeWatcher(shared);
}

/// Returns the strongest request latched for the current generation.
pub fn sample(self: *const GenerationInterrupt) Signal {
    const shared = self.shared orelse return .none;
    return shared.signal.load(.acquire);
}

/// Gives already queued or pending escape input up to 60 ms to become
/// unambiguous. Provider and tool cancellation polls should use `sample`
/// instead because this call may wait.
pub fn resolve(self: *GenerationInterrupt) Signal {
    const shared = self.shared orelse return .none;
    if (shared.command.load(.acquire) != .armed) return shared.signal.load(.acquire);
    if (!inputQueued(shared.input_fd) and
        !shared.classifying.load(.acquire) and
        !shared.escape_pending.load(.acquire))
    {
        return shared.signal.load(.acquire);
    }

    const ticket = shared.resolve_request.fetchAdd(1, .acq_rel) +% 1;
    wakeWatcher(shared);
    while (shared.resolve_ack.load(.acquire) < ticket) {
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    return shared.signal.load(.acquire);
}

/// Revokes input ownership, waits for the watcher to acknowledge idle, drops
/// generation input, and restores the exact saved terminal attributes.
pub fn disarm(self: *GenerationInterrupt) !void {
    const shared = self.shared orelse return;
    if (shared.command.load(.acquire) == .armed) {
        shared.command.store(.idle, .release);
        wakeWatcher(shared);
    }
    while (shared.watching.load(.acquire)) {
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    try self.mode.restore();
    if (self.discard_pending) {
        try self.discard.call(shared.input_fd);
        self.discard_pending = false;
    }
}

/// Stops and joins the finite watcher, then restores and closes owned state.
/// A failed terminal restore remains retryable by calling `deinit` again.
pub fn deinit(self: *GenerationInterrupt) !void { // ziglint-ignore: Z030
    const shared = self.shared orelse {
        try self.mode.restore();
        return;
    };
    const container = containingShared(shared);
    if (!self.joined) {
        shared.command.store(.stop, .release);
        wakeWatcher(shared);
        while (shared.watching.load(.acquire)) {
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }
        container.thread.join();
        container.thread = undefined;
        self.joined = true;
    }
    try self.mode.restore();
    var discard_error: ?error{Unexpected} = null;
    if (self.discard_pending) {
        self.discard.call(shared.input_fd) catch |err| {
            discard_error = err;
        };
        self.discard_pending = false;
    }
    closeFd(shared.wake_read_fd);
    closeFd(shared.wake_write_fd);
    self.shared = null;
    self.joined = false;
    self.allocator.destroy(container);
    if (discard_error) |err| return err;
}

fn start(self: *GenerationInterrupt, input_fd: posix.fd_t, wake: Wake, flush_input: bool) !void {
    const shared = try self.allocator.create(SharedWithThread);
    errdefer self.allocator.destroy(shared);

    var guard = ProcessSpawn.lock(self.io);
    const pipe_fds = createWakePipe() catch |err| {
        guard.deinit();
        return err;
    };
    guard.deinit();
    errdefer {
        closeFd(pipe_fds[0]);
        closeFd(pipe_fds[1]);
    }

    shared.* = .{
        .base = .{
            .io = self.io,
            .input_fd = input_fd,
            .wake_read_fd = pipe_fds[0],
            .wake_write_fd = pipe_fds[1],
            .callback = wake,
        },
        .thread = undefined,
    };
    var blocked = interruptSignalSet();
    var previous_mask: posix.sigset_t = undefined;
    const block_result = std.c.pthread_sigmask(@intCast(posix.SIG.BLOCK), &blocked, &previous_mask);
    if (block_result != 0) return error.Unexpected;
    defer {
        var ignored_mask: posix.sigset_t = undefined;
        const restore_result = std.c.pthread_sigmask(
            @intCast(posix.SIG.SETMASK),
            &previous_mask,
            &ignored_mask,
        );
        std.debug.assert(restore_result == 0);
    }
    shared.thread = try std.Thread.spawn(.{}, watcherMain, .{shared});
    self.shared = &shared.base;
    self.flush_input = flush_input;
}

// Keeping the thread handle beside the shared state gives one finite join while
// the watcher itself receives only a heap-stable pointer.
const SharedWithThread = struct {
    base: Shared,
    thread: std.Thread,
};

fn containingShared(base: *Shared) *SharedWithThread {
    return @fieldParentPtr("base", base);
}

fn interruptSignalSet() posix.sigset_t {
    var set = posix.sigemptyset();
    posix.sigaddset(&set, .INT);
    posix.sigaddset(&set, .TERM);
    posix.sigaddset(&set, .HUP);
    posix.sigaddset(&set, .QUIT);
    return set;
}

fn watcherMain(container: *SharedWithThread) void {
    const shared = &container.base;
    const all_signals = posix.sigfillset();
    var ignored_mask: posix.sigset_t = undefined;
    const mask_result = std.c.pthread_sigmask(@intCast(posix.SIG.BLOCK), &all_signals, &ignored_mask);
    std.debug.assert(mask_result == 0);

    var classifier = EscapeClassifier.init();
    var armed = false;
    var last_ns: i128 = 0;
    while (true) {
        const command = shared.command.load(.acquire);
        if (command == .stop) {
            shared.resolve_ack.store(shared.resolve_request.load(.acquire), .release);
            shared.watching.store(false, .release);
            return;
        }
        if (command == .idle) {
            if (armed) {
                drainClassifierInput(shared, &classifier);
                resolvePending(&classifier, shared);
                armed = false;
            }
            shared.resolve_ack.store(shared.resolve_request.load(.acquire), .release);
            shared.watching.store(false, .release);
        } else if (!armed) {
            classifier.reset();
            shared.escape_pending.store(false, .release);
            armed = true;
            last_ns = awakeNow(shared.io);
            shared.watching.store(true, .release);
        }

        var poll_fds = [2]posix.pollfd{
            .{ .fd = shared.wake_read_fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = if (armed) shared.input_fd else -1, .events = posix.POLL.IN, .revents = 0 },
        };
        _ = posix.poll(&poll_fds, if (armed) @intCast(EscapeClassifier.escape_timeout_ms) else -1) catch continue;

        // Control always wins when wake and input become readable together.
        if (poll_fds[0].revents != 0) {
            drainWake(shared.wake_read_fd);
            while (shared.command.load(.acquire) == .armed) {
                const request = shared.resolve_request.load(.acquire);
                if (request == shared.resolve_ack.load(.acquire)) break;
                resolveWindow(shared, &classifier, &last_ns);
                shared.resolve_ack.store(request, .release);
            }
            continue;
        }
        if (!armed or shared.command.load(.acquire) != .armed) continue;

        advanceClassifier(awakeNow(shared.io), &last_ns, &classifier, shared);
        if (poll_fds[1].revents != 0) {
            drainClassifierInput(shared, &classifier);
            publish(classifier.sample(), shared);
        }
    }
}

fn resolveWindow(shared: *Shared, classifier: *EscapeClassifier, last_ns: *i128) void {
    const deadline_ns = awakeNow(shared.io) + 60 * std.time.ns_per_ms;
    while (shared.command.load(.acquire) == .armed) {
        const now_ns = awakeNow(shared.io);
        advanceClassifier(now_ns, last_ns, classifier, shared);
        if (now_ns >= deadline_ns) return;
        if (!classifier.isEscapePending() and !inputQueued(shared.input_fd)) return;

        const remaining_ns = deadline_ns - now_ns;
        const remaining_ms: i32 = @intCast(@max(1, @divTrunc(
            remaining_ns + std.time.ns_per_ms - 1,
            std.time.ns_per_ms,
        )));
        var poll_fds = [2]posix.pollfd{
            .{ .fd = shared.wake_read_fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = shared.input_fd, .events = posix.POLL.IN, .revents = 0 },
        };
        _ = posix.poll(&poll_fds, remaining_ms) catch return;
        if (poll_fds[0].revents != 0) {
            drainWake(shared.wake_read_fd);
            if (shared.command.load(.acquire) != .armed) return;
        }
        if (poll_fds[1].revents != 0) drainClassifierInput(shared, classifier);
        publish(classifier.sample(), shared);
    }
}

fn advanceClassifier(
    now_ns: i128,
    last_ns: *i128,
    classifier: *EscapeClassifier,
    shared: *Shared,
) void {
    if (now_ns <= last_ns.*) return;
    const elapsed_ms: u64 = @intCast(@divTrunc(now_ns - last_ns.*, std.time.ns_per_ms));
    if (elapsed_ms == 0) return;
    shared.classifying.store(true, .release);
    classifier.advance(elapsed_ms);
    shared.escape_pending.store(classifier.isEscapePending(), .release);
    shared.classifying.store(false, .release);
    last_ns.* += @as(i128, elapsed_ms) * std.time.ns_per_ms;
    publish(classifier.sample(), shared);
}

fn drainClassifierInput(shared: *Shared, classifier: *EscapeClassifier) void {
    shared.classifying.store(true, .release);
    defer shared.classifying.store(false, .release);
    while (true) {
        var buffer: [256]u8 = undefined;
        const count = readAvailable(shared.input_fd, &buffer);
        for (buffer[0..count]) |byte| classifier.feed(byte);
        shared.escape_pending.store(classifier.isEscapePending(), .release);
        if (count < buffer.len) return;
    }
}

fn resolvePending(classifier: *EscapeClassifier, shared: *Shared) void {
    shared.classifying.store(true, .release);
    classifier.advance(EscapeClassifier.escape_timeout_ms);
    shared.escape_pending.store(classifier.isEscapePending(), .release);
    shared.classifying.store(false, .release);
    publish(classifier.sample(), shared);
}

fn publish(sample_value: EscapeClassifier.Sample, shared: *Shared) void {
    const next: Signal = switch (sample_value) {
        .none => .none,
        .pause => .pause,
        .abort => .abort,
    };
    if (@intFromEnum(next) <= @intFromEnum(shared.signal.load(.acquire))) return;
    // Consumers woken by the callback must already observe the request.
    shared.signal.store(next, .release);
    shared.callback.call();
}

fn awakeNow(io: std.Io) i128 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn wakeWatcher(shared: *Shared) void {
    const byte: [1]u8 = .{1};
    while (true) {
        const rc = system.write(shared.wake_write_fd, &byte, byte.len);
        switch (posix.errno(rc)) {
            .SUCCESS, .AGAIN => return,
            .INTR => continue,
            else => return,
        }
    }
}

fn drainWake(fd: posix.fd_t) void {
    var bytes: [64]u8 = undefined;
    while (true) {
        const rc = system.read(fd, &bytes, bytes.len);
        switch (posix.errno(rc)) {
            .SUCCESS => if (rc == 0 or rc < bytes.len) return,
            .INTR => continue,
            .AGAIN => return,
            else => return,
        }
    }
}

fn inputQueued(fd: posix.fd_t) bool {
    var poll_fds = [1]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
    _ = posix.poll(&poll_fds, 0) catch return false;
    return poll_fds[0].revents != 0;
}

fn readAvailable(fd: posix.fd_t, buffer: []u8) usize {
    while (true) {
        const rc = system.read(fd, buffer.ptr, buffer.len);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return 0,
            else => return 0,
        }
    }
}

fn createWakePipe() ![2]posix.fd_t {
    var fds: [2]posix.fd_t = undefined;
    const result = if (builtin.os.tag == .linux) linux: {
        var flags: posix.O = .{};
        flags.CLOEXEC = true;
        flags.NONBLOCK = true;
        break :linux system.pipe2(&fds, flags);
    } else system.pipe(&fds);
    switch (posix.errno(result)) {
        .SUCCESS => {},
        .NFILE => return error.SystemFdQuotaExceeded,
        .MFILE => return error.ProcessFdQuotaExceeded,
        else => return error.Unexpected,
    }
    if (builtin.os.tag != .linux) {
        errdefer {
            closeFd(fds[0]);
            closeFd(fds[1]);
        }
        try setCloseOnExec(fds[0]);
        try setCloseOnExec(fds[1]);
        try setNonblocking(fds[0]);
        try setNonblocking(fds[1]);
    }
    return fds;
}

fn setCloseOnExec(fd: posix.fd_t) !void {
    switch (posix.errno(system.fcntl(fd, posix.F.SETFD, @as(u32, posix.FD_CLOEXEC)))) {
        .SUCCESS => {},
        else => return error.Unexpected,
    }
}

fn setNonblocking(fd: posix.fd_t) !void {
    var flags: posix.O = .{};
    flags.NONBLOCK = true;
    switch (posix.errno(system.fcntl(fd, posix.F.SETFL, @as(u32, @bitCast(flags))))) {
        .SUCCESS => {},
        else => return error.Unexpected,
    }
}

fn inputFlushSelector(os_tag: std.Target.Os.Tag) c_int {
    return switch (os_tag) {
        .macos,
        .ios,
        .tvos,
        .visionos,
        .watchos,
        .freebsd,
        .netbsd,
        .openbsd,
        .dragonfly,
        => 1,
        else => 0,
    };
}

fn posixDiscard(_: ?*anyopaque, fd: posix.fd_t) error{Unexpected}!void {
    while (true) switch (posix.errno(tcflush(fd, inputFlushSelector(builtin.os.tag)))) {
        .SUCCESS => return,
        .INTR => continue,
        else => return error.Unexpected,
    };
}

extern "c" fn tcflush(fd: c_int, queue_selector: c_int) c_int;

fn closeFd(fd: posix.fd_t) void {
    if (fd >= 0) _ = system.close(fd);
}

test "TCIFLUSH selector follows Linux and Darwin BSD ABIs" {
    try std.testing.expectEqual(@as(c_int, 0), inputFlushSelector(.linux));
    try std.testing.expectEqual(@as(c_int, 1), inputFlushSelector(.macos));
    try std.testing.expectEqual(@as(c_int, 1), inputFlushSelector(.freebsd));
    try std.testing.expectEqual(@as(c_int, 1), inputFlushSelector(.netbsd));
    try std.testing.expectEqual(@as(c_int, 1), inputFlushSelector(.openbsd));
    try std.testing.expectEqual(@as(c_int, 1), inputFlushSelector(.dragonfly));
}

const TestMode = struct {
    attributes: std.posix.termios = std.mem.zeroes(std.posix.termios),
    sets: usize = 0,

    fn ops(self: *TestMode) PosixMode.Ops {
        return .{ .context = self, .get_fn = get, .set_fn = set };
    }

    fn get(context: ?*anyopaque, _: posix.fd_t) posix.TermiosGetError!posix.termios {
        const self: *TestMode = @ptrCast(@alignCast(context.?));
        return self.attributes;
    }

    fn set(
        context: ?*anyopaque,
        _: posix.fd_t,
        _: posix.TCSA,
        attributes: posix.termios,
    ) posix.TermiosSetError!void {
        const self: *TestMode = @ptrCast(@alignCast(context.?));
        self.attributes = attributes;
        self.sets += 1;
    }
};

const TestDiscard = struct {
    mode: *TestMode,
    calls: usize = 0,
    ordered: bool = true,
    fail: bool = false,

    fn ops(self: *TestDiscard) Discard {
        return .{ .context = self, .call_fn = call };
    }

    fn call(context: ?*anyopaque, _: posix.fd_t) error{Unexpected}!void {
        const self: *TestDiscard = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        self.ordered = self.ordered and self.mode.sets == self.calls * 2;
        if (self.fail) return error.Unexpected;
    }
};

const TestWake = struct {
    calls: std.atomic.Value(usize) = .init(0),

    fn wake(self: *TestWake) void {
        _ = self.calls.fetchAdd(1, .acq_rel);
    }
};

test "deinit cleans joined state after persistent discard failure" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;

    const input_fds = try createWakePipe();
    defer closeFd(input_fds[0]);
    defer closeFd(input_fds[1]);

    var fake_mode: TestMode = .{};
    var fake_discard: TestDiscard = .{ .mode = &fake_mode, .fail = true };
    var wake: TestWake = .{};
    var owner: GenerationInterrupt = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .mode = .initFd(input_fds[0], fake_mode.ops()),
        .discard = fake_discard.ops(),
    };
    try owner.start(input_fds[0], .from(&wake), true);
    try owner.clearAndArm();

    try std.testing.expectError(error.Unexpected, owner.deinit());
    try std.testing.expectEqual(@as(?*Shared, null), owner.shared);
    try std.testing.expect(!owner.joined);
    try std.testing.expect(!owner.discard_pending);
    try owner.deinit();
}

test "disarm and armed deinit restore before discarding input" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;

    const input_fds = try createWakePipe();
    defer closeFd(input_fds[0]);
    defer closeFd(input_fds[1]);

    var fake_mode: TestMode = .{};
    var fake_discard: TestDiscard = .{ .mode = &fake_mode };
    var wake: TestWake = .{};
    var owner: GenerationInterrupt = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .mode = .initFd(input_fds[0], fake_mode.ops()),
        .discard = fake_discard.ops(),
    };
    try owner.start(input_fds[0], .from(&wake), true);
    errdefer owner.deinit() catch {};

    try owner.clearAndArm();
    try owner.disarm();
    try std.testing.expectEqual(@as(usize, 1), fake_discard.calls);
    try std.testing.expect(fake_discard.ordered);

    try owner.clearAndArm();
    try owner.deinit();
    try std.testing.expectEqual(@as(usize, 2), fake_discard.calls);
    try std.testing.expect(fake_discard.ordered);
}

test "POSIX watcher classifies input and joins idle before restore" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;

    const input_fds = try createWakePipe();
    defer closeFd(input_fds[0]);
    defer closeFd(input_fds[1]);

    var fake_mode: TestMode = .{};
    var wake: TestWake = .{};
    var owner: GenerationInterrupt = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .mode = .initFd(input_fds[0], fake_mode.ops()),
    };
    var empty_mask = posix.sigemptyset();
    var mask_before: posix.sigset_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        std.c.pthread_sigmask(@intCast(posix.SIG.BLOCK), &empty_mask, &mask_before),
    );
    try owner.start(input_fds[0], .from(&wake), false);
    var mask_after: posix.sigset_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        std.c.pthread_sigmask(@intCast(posix.SIG.BLOCK), &empty_mask, &mask_after),
    );
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&mask_before), std.mem.asBytes(&mask_after));
    errdefer owner.deinit() catch {};

    try owner.clearAndArm();
    const esc: [1]u8 = .{0x1b};
    try std.testing.expectEqual(posix.E.SUCCESS, posix.errno(system.write(input_fds[1], &esc, esc.len)));

    var attempts: usize = 0;
    while (owner.sample() == .none and attempts < 1_000) : (attempts += 1) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch
            std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    try std.testing.expectEqual(Signal.pause, owner.sample());
    try std.testing.expectEqual(@as(usize, 1), wake.calls.load(.acquire));

    try owner.disarm();
    try std.testing.expectEqual(@as(usize, 2), fake_mode.sets);
    try owner.deinit();
    try owner.deinit();
}

test "resolve drains queued terminal sequences before resolving bare Esc" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;

    const input_fds = try createWakePipe();
    defer closeFd(input_fds[0]);
    defer closeFd(input_fds[1]);

    var fake_mode: TestMode = .{};
    var wake: TestWake = .{};
    var owner: GenerationInterrupt = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .mode = .initFd(input_fds[0], fake_mode.ops()),
    };
    try owner.start(input_fds[0], .from(&wake), false);
    errdefer owner.deinit() catch {};
    try owner.clearAndArm();
    try std.testing.expectEqual(Signal.none, owner.resolve());
    try std.testing.expectEqual(@as(u64, 0), owner.shared.?.resolve_request.load(.acquire));

    const csi = "\x1b[A";
    try std.testing.expectEqual(posix.E.SUCCESS, posix.errno(system.write(input_fds[1], csi.ptr, csi.len)));
    try std.testing.expectEqual(Signal.none, owner.resolve());

    const esc: [1]u8 = .{0x1b};
    try std.testing.expectEqual(posix.E.SUCCESS, posix.errno(system.write(input_fds[1], &esc, esc.len)));
    try std.testing.expectEqual(Signal.pause, owner.resolve());

    try owner.disarm();
    try owner.deinit();
}

test "resolving idle preserves a pending bare Esc" {
    var wake: TestWake = .{};
    var shared: Shared = .{
        .io = std.testing.io,
        .input_fd = -1,
        .wake_read_fd = -1,
        .wake_write_fd = -1,
        .callback = .from(&wake),
    };
    var classifier = EscapeClassifier.init();
    classifier.feed(0x1b);

    resolvePending(&classifier, &shared);

    try std.testing.expectEqual(Signal.pause, shared.signal.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), wake.calls.load(.acquire));
}

test "abort is published before each wake callback" {
    var wake: TestWake = .{};
    var shared: Shared = .{
        .io = std.testing.io,
        .input_fd = -1,
        .wake_read_fd = -1,
        .wake_write_fd = -1,
        .callback = .from(&wake),
    };

    publish(.pause, &shared);
    try std.testing.expectEqual(Signal.pause, shared.signal.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), wake.calls.load(.acquire));
    publish(.abort, &shared);
    try std.testing.expectEqual(Signal.abort, shared.signal.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), wake.calls.load(.acquire));
    publish(.pause, &shared);
    try std.testing.expectEqual(@as(usize, 2), wake.calls.load(.acquire));
}
