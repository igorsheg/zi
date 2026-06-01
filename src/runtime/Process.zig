const std = @import("std");
const zio = @import("zio");
const Runtime = zio.Runtime;

pub const Process = struct {
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    zio_runtime: *Runtime,
    environ: *std.process.Environ.Map,

    pub fn init(zio_runtime: *Runtime, process: std.process.Init) Process {
        return .{
            .arena = process.arena.allocator(),
            .gpa = process.gpa,
            .io = zio_runtime.io(),
            .zio_runtime = zio_runtime,
            .environ = process.environ_map,
        };
    }

    pub fn env(self: Process, name: []const u8) ?[]const u8 {
        return self.environ.get(name);
    }

    pub fn homeDir(self: Process) ![]const u8 {
        return self.env("HOME") orelse error.HomeNotSet;
    }
};

test "process runtime stores explicit resources" {
    var zio_runtime = try Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    const process: Process = .{
        .arena = std.testing.allocator,
        .gpa = std.testing.allocator,
        .io = zio_runtime.io(),
        .zio_runtime = zio_runtime,
        .environ = &environ,
    };

    try std.testing.expect(process.arena.ptr == std.testing.allocator.ptr);
    try std.testing.expect(process.gpa.ptr == std.testing.allocator.ptr);
    try std.testing.expect(process.environ == &environ);
}

test "process exposes environment resources" {
    var zio_runtime = try Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("HOME", "/home/me");

    const process: Process = .{
        .arena = std.testing.allocator,
        .gpa = std.testing.allocator,
        .io = zio_runtime.io(),
        .zio_runtime = zio_runtime,
        .environ = &environ,
    };

    try std.testing.expectEqualStrings("/home/me", try process.homeDir());
    try std.testing.expectEqualStrings("/home/me", process.env("HOME").?);
}
