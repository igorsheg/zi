const std = @import("std");
const builtin = @import("builtin");

const unlocked: u32 = 0;
const locked: u32 = 1;
const spin_limit: usize = 64;
// Generous by design: debug allocators inflate bounded work 10-50x, and this
// assert exists to catch category errors (I/O, O(session) scans) under a
// shared lock, not microsecond regressions. The byte caps are the real bound.
const lock_hold_assert_ns: i128 = 10 * std.time.ns_per_ms;

pub const SharedMutex = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(unlocked),

    pub fn tryLock(self: *SharedMutex) bool {
        return self.state.cmpxchgStrong(unlocked, locked, .acquire, .monotonic) == null;
    }

    pub fn lock(self: *SharedMutex) void {
        if (self.tryLock()) return;
        var spins: usize = 0;
        while (spins < spin_limit) : (spins += 1) {
            std.atomic.spinLoopHint();
            if (self.tryLock()) return;
        }
        while (!self.tryLock()) std.Thread.yield() catch {};
    }

    pub fn unlock(self: *SharedMutex) void {
        std.debug.assert(self.state.load(.unordered) == locked);
        self.state.store(unlocked, .release);
    }
};

pub const HoldTimer = struct {
    start_ns: i128,

    pub fn start() HoldTimer {
        return .{ .start_ns = nowNs() };
    }

    pub fn assertUnderLimit(self: HoldTimer) void {
        // Inert under the test runner: wall time on a saturated parallel
        // runner measures descheduling, not held work, and flakes. The net
        // targets interactive debug runs; tests assert the byte bounds
        // directly.
        if (!std.debug.runtime_safety or builtin.is_test) return;
        std.debug.assert(nowNs() - self.start_ns < lock_hold_assert_ns);
    }
};

pub fn nowNs() i128 {
    var timespec: std.posix.timespec = undefined;
    const rc = std.posix.system.clock_gettime(std.posix.CLOCK.MONOTONIC, &timespec);
    if (std.posix.errno(rc) != .SUCCESS) return 0;
    return @as(i128, timespec.sec) * std.time.ns_per_s + timespec.nsec;
}

test "tryLock reports contention" {
    var mutex: SharedMutex = .{};
    try std.testing.expect(mutex.tryLock());
    try std.testing.expect(!mutex.tryLock());
    mutex.unlock();
    try std.testing.expect(mutex.tryLock());
    mutex.unlock();
}

const Stress = struct {
    mutex: SharedMutex = .{},
    stop: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    counter: u64 = 0,
    batch: u64 = 0,
    bad: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

fn writerStress(state: *Stress) void {
    while (state.stop.load(.acquire) == 0) {
        state.mutex.lock();
        var i: usize = 0;
        while (i < 10) : (i += 1) state.counter += 1;
        state.batch += 1;
        state.mutex.unlock();
    }
}

fn readerStress(state: *Stress) void {
    while (state.stop.load(.acquire) == 0) {
        state.mutex.lock();
        if (state.counter != state.batch * 10) state.bad.store(1, .release);
        state.mutex.unlock();
    }
}

test "SharedMutex guards batches across two OS threads" {
    var state: Stress = .{};
    const writer = try std.Thread.spawn(.{}, writerStress, .{&state});
    const reader = try std.Thread.spawn(.{}, readerStress, .{&state});

    const deadline = nowNs() + 100 * std.time.ns_per_ms;
    while (nowNs() < deadline) std.Thread.yield() catch {};
    state.stop.store(1, .release);
    writer.join();
    reader.join();

    try std.testing.expectEqual(@as(u32, 0), state.bad.load(.acquire));
    try std.testing.expect(state.batch > 0);
}
