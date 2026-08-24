const std = @import("std");

var mutex: std.Io.Mutex = .init;

/// Process-wide coordinator for descriptor creation through fork/exec on
/// platforms without atomic close-on-exec pipe creation. Every Zi fork/exec
/// owner must hold this guard across descriptor setup and process creation.
pub const Guard = struct {
    io: std.Io,

    pub fn deinit(self: *Guard) void {
        mutex.unlock(self.io);
        self.* = undefined;
    }
};

pub fn lock(io: std.Io) Guard {
    mutex.lockUncancelable(io);
    return .{ .io = io };
}
