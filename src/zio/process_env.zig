const std = @import("std");
const builtin = @import("builtin");
const runtime_env = @import("env");
const types = @import("process_engine_types.zig");

pub const EnvPair = types.EnvPair;

pub fn buildMap(allocator: std.mem.Allocator, env: []const EnvPair, clear_env: bool) !?std.process.Environ.Map {
    if (env.len == 0 and !clear_env) return null;

    var map = std.process.Environ.Map.init(allocator);
    errdefer map.deinit();

    if (!clear_env) {
        if (runtime_env.map()) |inherited| {
            try copyInto(&map, inherited);
        } else {
            try copyProcessEnvironmentFallback(&map);
        }
    }

    for (env) |pair| try map.put(pair.key, pair.value);
    return map;
}

fn copyInto(dest: *std.process.Environ.Map, source: *const std.process.Environ.Map) !void {
    var it = source.iterator();
    while (it.next()) |entry| {
        try dest.put(entry.key_ptr.*, entry.value_ptr.*);
    }
}

fn copyProcessEnvironmentFallback(dest: *std.process.Environ.Map) !void {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi or builtin.os.tag == .emscripten) return;

    var i: usize = 0;
    while (std.c.environ[i]) |entry_z| : (i += 1) {
        const entry = std.mem.span(entry_z);
        const sep = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (sep == 0) continue;
        try dest.put(entry[0..sep], entry[sep + 1 ..]);
    }
}
