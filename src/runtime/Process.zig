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

    pub fn env(self: Process, name: []const u8) ?[]const u8 {
        return self.environ.get(name);
    }

    pub fn homeDir(self: Process) ![]const u8 {
        return self.env("HOME") orelse error.HomeNotSet;
    }
};

test "process stores explicit resources" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    const process: Process = .{
        .arena = std.testing.allocator,
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .environ = &environ,
    };

    try std.testing.expect(process.arena.ptr == std.testing.allocator.ptr);
    try std.testing.expect(process.gpa.ptr == std.testing.allocator.ptr);
    try std.testing.expect(process.environ == &environ);
}

test "process exposes environment resources" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("HOME", "/home/me");

    const process: Process = .{
        .arena = std.testing.allocator,
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .environ = &environ,
    };

    try std.testing.expectEqualStrings("/home/me", try process.homeDir());
    try std.testing.expectEqualStrings("/home/me", process.env("HOME").?);
}
