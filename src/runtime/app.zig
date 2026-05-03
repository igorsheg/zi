const std = @import("std");

pub const name = "zi";
pub const version = "0.0.1";
pub const tagline = "AI coding agent";

pub fn writeVersionLine(writer: anytype) !void {
    try writer.print("{s} {s}\n", .{ name, version });
}

test "version line uses app metadata" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try writeVersionLine(&out.writer);
    const rendered = try out.toOwnedSlice();
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("zi 0.0.1\n", rendered);
}

/// Process-level runtime policy for the zi executable.
///
/// Keep this module small: it owns process-boundary choices that should be
/// consistent across startup, not subsystem behavior. Focused runtime modules
/// (`fs`, `process`, `mailbox`, ...) own behavior.
pub const use_debug_allocator = false;

/// Main process heap policy.
///
/// zi's interactive mode is long-lived and multi-threaded; the default process
/// heap must stay fast and thread-safe even for `zig build run`. Use external
/// leak tools / focused tests for deep allocator diagnostics rather than
/// putting the whole TUI behind DebugAllocator bookkeeping.
pub const MainHeap = struct {
    debug_allocator: if (use_debug_allocator) std.heap.DebugAllocator(.{}) else void = if (use_debug_allocator) .init else {},

    pub fn allocator(self: *MainHeap) std.mem.Allocator {
        return if (use_debug_allocator) self.debug_allocator.allocator() else std.heap.smp_allocator;
    }

    pub fn deinit(self: *MainHeap) void {
        if (use_debug_allocator) {
            switch (self.debug_allocator.deinit()) {
                .ok => {},
                .leak => @panic("memory leak detected"),
            }
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
