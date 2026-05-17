const std = @import("std");
const builtin = @import("builtin");
const runtime_env = @import("env");
const types = @import("process_reactor_types.zig");

pub const EnvPair = types.EnvPair;

pub fn buildMap(allocator: std.mem.Allocator, env: []const EnvPair, clear_env: bool) !std.process.Environ.Map {
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

pub const SpawnArgv = struct {
    argv: []const []const u8,
    resolved_argv0: ?[]u8 = null,

    pub fn deinit(self: SpawnArgv, allocator: std.mem.Allocator) void {
        if (self.resolved_argv0) |path| {
            allocator.free(path);
            allocator.free(self.argv);
        }
    }
};

pub fn spawnArgv(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    env_map: ?*const std.process.Environ.Map,
) !SpawnArgv {
    const resolved = try resolveExecutableFromEnvPath(allocator, io, argv[0], env_map);
    if (resolved == null) return .{ .argv = argv };
    errdefer allocator.free(resolved.?);

    const out = try allocator.alloc([]const u8, argv.len);
    errdefer allocator.free(out);
    @memcpy(out, argv);
    out[0] = resolved.?;
    return .{ .argv = out, .resolved_argv0 = resolved };
}

/// Resolve a bare argv[0] from the explicit child environment PATH.
/// Empty and relative PATH entries are ignored intentionally: zio process
/// lookup should not depend on ambient cwd authority.
fn resolveExecutableFromEnvPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv0: []const u8,
    env_map: ?*const std.process.Environ.Map,
) !?[]u8 {
    if (argv0.len == 0) return null;
    if (std.mem.indexOfAny(u8, argv0, "/\\") != null) return null;

    const path_value = if (env_map) |map|
        map.get("PATH") orelse return null
    else
        runtime_env.get("PATH") orelse return null;

    var it = std.mem.splitScalar(u8, path_value, std.fs.path.delimiter);
    while (it.next()) |dir| {
        if (dir.len == 0 or !std.fs.path.isAbsolute(dir)) continue;
        const candidate = try std.fs.path.join(allocator, &.{ dir, argv0 });
        if (!isExecutableFile(allocator, io, candidate)) {
            allocator.free(candidate);
            continue;
        }
        return candidate;
    }
    return null;
}

fn isExecutableFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) bool {
    if (builtin.os.tag == .windows) return true;
    if (std.posix.mode_t == u0) return true;

    const file = std.Io.Dir.openFileAbsolute(io, path, .{ .allow_directory = false }) catch return false;
    file.close(io);

    const path_z = allocator.dupeZ(u8, path) catch return false;
    defer allocator.free(path_z);
    return std.c.access(path_z.ptr, std.c.X_OK) == 0;
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
