const std = @import("std");

pub const Token = struct {
    source: ?*const Source = null,
    generation: u64 = 0,

    pub const none: Token = .{};

    pub fn isNone(self: Token) bool {
        return self.source == null;
    }

    pub fn isAborted(self: Token) bool {
        const source = self.source orelse return false;
        return source.generation.load(.acquire) != self.generation or source.aborted.load(.acquire);
    }

    pub fn requestAbort(self: Token) void {
        const source = self.source orelse return;
        if (source.generation.load(.acquire) != self.generation) return;
        @constCast(source).requestAbort();
    }
};

pub const Source = struct {
    aborted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(1),

    pub fn beginRun(self: *Source) Token {
        const next = self.generation.fetchAdd(1, .acq_rel) + 1;
        self.aborted.store(false, .release);
        return .{ .source = self, .generation = next };
    }

    pub fn signal(self: *Source) Token {
        return .{ .source = self, .generation = self.generation.load(.acquire) };
    }

    pub fn requestAbort(self: *Source) void {
        self.aborted.store(true, .release);
    }

    pub fn notifyWaiters(_: *Source) void {}

    pub fn isAborted(self: *const Source) bool {
        return self.aborted.load(.acquire);
    }
};

test "stale tokens abort when a new run begins" {
    var source = Source{};
    const first = source.beginRun();
    source.requestAbort();
    try std.testing.expect(first.isAborted());

    const second = source.beginRun();
    try std.testing.expect(!second.isAborted());
    try std.testing.expect(first.isAborted());
}
