const std = @import("std");

pub const Deadline = struct {
    ns: i128,

    pub fn afterMs(io: std.Io, ms: u64) Deadline {
        return .{ .ns = nowNs(io) + @as(i128, @intCast(ms)) * std.time.ns_per_ms };
    }

    pub fn expired(self: Deadline, io: std.Io) bool {
        return self.ns <= nowNs(io);
    }

    pub fn remainingMs(self: Deadline, io: std.Io, max_ms: i32) i32 {
        return remainingMsFromNow(self.ns, nowNs(io), max_ms);
    }
};

pub fn nowNs(io: std.Io) i128 {
    return @as(i128, @intCast(std.Io.Timestamp.now(io, .awake).toNanoseconds()));
}

pub fn timeoutUntil(deadline_ns: ?i128, now_ns: i128, max_ms: i32) i32 {
    return if (deadline_ns) |deadline|
        remainingMsFromNow(deadline, now_ns, max_ms)
    else
        max_ms;
}

pub fn remainingMsFromNow(deadline_ns: i128, now_ns: i128, max_ms: i32) i32 {
    if (deadline_ns <= now_ns) return 0;
    const remaining_ns = deadline_ns - now_ns;
    const remaining_ms = @divFloor(remaining_ns + std.time.ns_per_ms - 1, std.time.ns_per_ms);
    const capped = @min(remaining_ms, @as(i128, max_ms));
    return @intCast(capped);
}

test "timeoutUntil returns max when no deadline exists" {
    try std.testing.expectEqual(@as(i32, 50), timeoutUntil(null, 100, 50));
}

test "timeoutUntil returns zero for expired deadline" {
    try std.testing.expectEqual(@as(i32, 0), timeoutUntil(100, 100, 50));
    try std.testing.expectEqual(@as(i32, 0), timeoutUntil(99, 100, 50));
}

test "timeoutUntil rounds up and caps future deadlines" {
    try std.testing.expectEqual(@as(i32, 1), timeoutUntil(101, 100, 50));
    try std.testing.expectEqual(@as(i32, 2), timeoutUntil(100 + std.time.ns_per_ms + 1, 100, 50));
    try std.testing.expectEqual(@as(i32, 50), timeoutUntil(100 + 1000 * std.time.ns_per_ms, 100, 50));
}
