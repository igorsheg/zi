const std = @import("std");

var process_environment: ?*const std.process.Environ.Map = null;

pub fn setProcessEnvironment(environ_map: *const std.process.Environ.Map) void {
    process_environment = environ_map;
}

pub fn map() ?*const std.process.Environ.Map {
    return process_environment;
}

pub fn get(name: []const u8) ?[]const u8 {
    if (process_environment) |environ_map| return environ_map.get(name);

    return getenvFallback(name);
}

fn getenvFallback(name: []const u8) ?[]const u8 {
    if (name.len > 255) return null;
    var buf: [256:0]u8 = undefined;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const raw = std.c.getenv(@ptrCast(&buf)) orelse return null;
    return std.mem.span(raw);
}
