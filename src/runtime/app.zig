const std = @import("std");

/// Runtime capabilities captured at the process boundary and threaded through
/// zi subsystems. Keep this small: it is a capability bag, not a service
/// locator. Use focused runtime modules (`fs`, `process`, `mailbox`, ...)
/// for behavior.
pub const Caps = struct {
    io: std.Io,
    environ: *const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    msg_allocator: std.mem.Allocator,
};
