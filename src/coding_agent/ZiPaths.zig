const std = @import("std");

const ZiPaths = @This();
const max_path_bytes = 32 * 1024;

pub const Error = error{
    OutOfMemory,
    InvalidPath,
};

arena: std.heap.ArenaAllocator,
cwd: []const u8,
global_agent: []const u8,
project: []const u8,
global_models_file: []const u8,

pub fn init(allocator: std.mem.Allocator, cwd: []const u8, home: []const u8) Error!ZiPaths {
    try validateAbsolutePath(cwd);
    try validateAbsolutePath(home);

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const owned = arena.allocator();
    const normalized_cwd = try std.fs.path.resolve(owned, &.{cwd});
    const normalized_home = try std.fs.path.resolve(owned, &.{home});
    const global_agent = try std.fs.path.resolve(owned, &.{ normalized_home, ".zi", "agent" });
    const project = try std.fs.path.resolve(owned, &.{ normalized_cwd, ".zi" });
    const global_models_file = try std.fs.path.resolve(owned, &.{ global_agent, "models.json" });
    if (normalized_cwd.len > max_path_bytes or
        global_agent.len > max_path_bytes or
        project.len > max_path_bytes or
        global_models_file.len > max_path_bytes)
    {
        return error.InvalidPath;
    }

    return .{
        .arena = arena,
        .cwd = normalized_cwd,
        .global_agent = global_agent,
        .project = project,
        .global_models_file = global_models_file,
    };
}

pub fn deinit(self: *ZiPaths) void {
    self.arena.deinit();
    self.* = undefined;
}

fn validateAbsolutePath(path: []const u8) error{InvalidPath}!void {
    if (path.len == 0 or path.len > max_path_bytes) return error.InvalidPath;
    if (!std.unicode.utf8ValidateSlice(path)) return error.InvalidPath;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    if (!std.fs.path.isAbsolute(path)) return error.InvalidPath;
}

test "Zi paths own normalized cwd-bound configuration roots" {
    const cwd_input = try std.testing.allocator.dupe(u8, "/tmp/zi-work/./child/..");
    defer std.testing.allocator.free(cwd_input);
    const home_input = try std.testing.allocator.dupe(u8, "/tmp/zi-home/./user/..");
    defer std.testing.allocator.free(home_input);

    var paths = try init(std.testing.allocator, cwd_input, home_input);
    defer paths.deinit();
    @memset(cwd_input, 'x');
    @memset(home_input, 'x');

    try std.testing.expectEqualStrings("/tmp/zi-work", paths.cwd);
    try std.testing.expectEqualStrings("/tmp/zi-home/.zi/agent", paths.global_agent);
    try std.testing.expectEqualStrings("/tmp/zi-work/.zi", paths.project);
    try std.testing.expectEqualStrings("/tmp/zi-home/.zi/agent/models.json", paths.global_models_file);
}

test "Zi paths reject invalid admitted roots" {
    try std.testing.expectError(error.InvalidPath, init(std.testing.allocator, "", "/tmp/home"));
    try std.testing.expectError(error.InvalidPath, init(std.testing.allocator, "relative", "/tmp/home"));
    try std.testing.expectError(error.InvalidPath, init(std.testing.allocator, "/tmp/work", "relative"));
    try std.testing.expectError(error.InvalidPath, init(std.testing.allocator, "/tmp/\x00work", "/tmp/home"));
    try std.testing.expectError(error.InvalidPath, init(std.testing.allocator, "/tmp/\xffwork", "/tmp/home"));

    const overlong = try std.testing.allocator.alloc(u8, max_path_bytes + 1);
    defer std.testing.allocator.free(overlong);
    @memset(overlong, 'a');
    overlong[0] = '/';
    try std.testing.expectError(error.InvalidPath, init(std.testing.allocator, overlong, "/tmp/home"));
}

fn initAndDeinit(allocator: std.mem.Allocator) !void {
    var paths = try init(allocator, "/tmp/zi-work/./child/..", "/tmp/zi-home");
    paths.deinit();
}

test "Zi paths settle every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, initAndDeinit, .{});
}
