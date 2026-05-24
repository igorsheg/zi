const std = @import("std");

pub const CancelSource = struct {
    requested: std.atomic.Value(bool) = .init(false),

    pub fn token(self: *CancelSource) CancelToken {
        return .{ .requested = &self.requested };
    }

    pub fn request(self: *CancelSource) void {
        self.requested.store(true, .release);
    }

    pub fn reset(self: *CancelSource) void {
        self.requested.store(false, .release);
    }
};

pub const CancelToken = struct {
    requested: *const std.atomic.Value(bool),

    pub fn isRequested(self: CancelToken) bool {
        return self.requested.load(.acquire);
    }
};

test "cancel source owns mutation and token only observes" {
    var source: CancelSource = .{};
    const token = source.token();

    try std.testing.expect(!token.isRequested());
    source.request();
    try std.testing.expect(token.isRequested());
    source.reset();
    try std.testing.expect(!token.isRequested());
}
