const std = @import("std");

pub const Process = struct {
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: *std.process.Environ.Map,

    pub fn init(process: std.process.Init) Process {
        return .{
            .arena = process.arena.allocator(),
            .gpa = process.gpa,
            .io = process.io,
            .environ = process.environ_map,
        };
    }
};

test "process runtime stores explicit resources" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    const process: Process = .{
        .arena = std.testing.allocator,
        .gpa = std.testing.allocator,
        .io = std.Io.failing,
        .environ = &environ,
    };

    try std.testing.expect(process.arena.ptr == std.testing.allocator.ptr);
    try std.testing.expect(process.gpa.ptr == std.testing.allocator.ptr);
    try std.testing.expect(process.environ == &environ);
}
