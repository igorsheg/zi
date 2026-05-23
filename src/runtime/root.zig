const std = @import("std");

pub const EventPipe = @import("event_pipe.zig").EventPipe;

pub const Process = struct {
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,

    pub fn init(process: std.process.Init) Process {
        return .{
            .arena = process.arena.allocator(),
            .gpa = process.gpa,
            .io = process.io,
        };
    }
};

test {
    _ = @import("event_pipe.zig");
}

test "process runtime stores explicit resources" {
    const process: Process = .{
        .arena = std.testing.allocator,
        .gpa = std.testing.allocator,
        .io = std.Io.failing,
    };

    try std.testing.expect(process.arena.ptr == std.testing.allocator.ptr);
    try std.testing.expect(process.gpa.ptr == std.testing.allocator.ptr);
}
