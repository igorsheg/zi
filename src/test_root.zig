const std = @import("std");
const log = @import("runtime/log.zig");

pub var std_options_debug_threaded_io_storage: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
pub const std_options_debug_threaded_io: *std.Io.Threaded = &std_options_debug_threaded_io_storage;

test {
    std.testing.log_level = .err;

    std.Io.Threaded.global_single_threaded.allocator = std.heap.smp_allocator;
    log.setThreadLabel(.@"test");
    _ = @import("storage.zig");
    _ = @import("runtime/log.zig");
    _ = @import("ai/root.zig");
    _ = @import("json/root.zig");
    _ = @import("agent/root.zig");
}
