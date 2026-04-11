const std = @import("std");
const memory_debug = @import("../debug/tracked_allocator.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    msg_allocator: std.mem.Allocator,
    root_tracker: *memory_debug.TrackedAllocator,
    agent_backing_tracker: *memory_debug.TrackedAllocator,
    tui_backing_tracker: *memory_debug.TrackedAllocator,
    msg_backing_tracker: *memory_debug.TrackedAllocator,
};
