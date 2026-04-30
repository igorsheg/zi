const std = @import("std");
const builtin = @import("builtin");

/// Process-level runtime policy for the zi executable.
///
/// Keep this module small: it owns process-boundary choices that should be
/// consistent across startup, not subsystem behavior. Focused runtime modules
/// (`fs`, `process`, `mailbox`, ...) own behavior.
pub const use_debug_allocator = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;

/// Main process heap policy.
///
/// Debug/Safe builds keep DebugAllocator diagnostics. Fast/Small builds use the
/// lean stdlib SMP allocator so release startup does not pay debug bookkeeping.
pub const MainHeap = struct {
    debug_allocator: if (use_debug_allocator) std.heap.DebugAllocator(.{}) else void = if (use_debug_allocator) .init else {},

    pub fn allocator(self: *MainHeap) std.mem.Allocator {
        return if (use_debug_allocator) self.debug_allocator.allocator() else std.heap.smp_allocator;
    }

    pub fn deinit(self: *MainHeap) void {
        if (use_debug_allocator) {
            _ = self.debug_allocator.deinit();
        }
    }
};

/// Runtime capabilities captured at the process boundary and threaded through
/// zi subsystems. Keep this small: it is a capability bag, not a service
/// locator.
pub const Caps = struct {
    io: std.Io,
    environ: *const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    msg_allocator: std.mem.Allocator,
};
