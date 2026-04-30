const std = @import("std");

/// Process environment captured by Zig 0.16 startup.
///
/// Prefer this over libc's global getenv so reads observe the same environment
/// snapshot that std.process.spawn receives through std.process.Init. The
/// pointer is installed once at program startup and then treated as immutable.
var process_environment: ?*const std.process.Environ.Map = null;

pub fn setProcessEnvironment(environ_map: *const std.process.Environ.Map) void {
    process_environment = environ_map;
}

pub fn get(name: []const u8) ?[]const u8 {
    if (process_environment) |environ_map| return environ_map.get(name);

    // Tests and standalone helpers may call env.get without going through
    // main(). Keep the fallback narrow and isolated in runtime/env.zig.
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
