const std = @import("std");

pub const FileMutationQueue = struct {
    mutex: std.atomic.Mutex = .unlocked,

    pub fn lock(self: *FileMutationQueue) Guard {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        return .{ .queue = self };
    }

    pub const Guard = struct {
        queue: *FileMutationQueue,

        pub fn unlock(self: *Guard) void {
            self.queue.mutex.unlock();
            self.* = undefined;
        }
    };
};

test "file mutation queue serializes critical section" {
    var queue: FileMutationQueue = .{};
    var guard = queue.lock();
    guard.unlock();
}
