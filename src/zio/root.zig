const std = @import("std");

/// zi + std.Io: zi's low-level I/O and concurrency primitives.
pub const Io = std.Io;

pub const TaskGroup = @import("task_group.zig").TaskGroup;
pub const AbortController = @import("abort_signal.zig").AbortController;
pub const AbortSignal = @import("abort_signal.zig").AbortSignal;
pub const AbortGuard = @import("abort_guard.zig").AbortGuard;
pub const abort = struct {
    pub const AbortController = @import("abort_signal.zig").AbortController;
    pub const AbortSignal = @import("abort_signal.zig").AbortSignal;
    pub const AbortGuard = @import("abort_guard.zig").AbortGuard;
};
pub const mailbox = @import("mailbox.zig");
pub const Mailbox = mailbox.Mailbox;
pub const process = @import("process.zig");
pub const job = @import("job.zig");
pub const fs = @import("fs.zig");
pub const worker = @import("worker.zig");
pub const BlockingWorker = worker.BlockingWorker;

pub const default_io: Io = std.Options.debug_io;

/// Prefer this over direct `std.Thread.spawn` for new fan-out code.
pub fn concurrent(
    io: Io,
    function: anytype,
    args: std.meta.ArgsTuple(@TypeOf(function)),
) Io.ConcurrentError!Io.Future(@typeInfo(@TypeOf(function)).@"fn".return_type.?) {
    return Io.concurrent(io, function, args);
}

/// Prefer this for opportunistic background work that may legally run inline on
/// single-threaded/evented backends.
pub fn async(
    io: Io,
    function: anytype,
    args: std.meta.ArgsTuple(@TypeOf(function)),
) Io.Future(@typeInfo(@TypeOf(function)).@"fn".return_type.?) {
    return Io.async(io, function, args);
}
