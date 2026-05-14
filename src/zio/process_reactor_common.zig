const std = @import("std");
const process_common = @import("process_common.zig");
const process_env = @import("process_env.zig");
const types = @import("process_reactor_types.zig");

pub const Stream = enum { stdout, stderr };

pub const SpawnedChild = struct {
    request: types.SpawnRequest,
    child: std.process.Child,
    pid: std.process.Child.Id,
    stdin_file: ?std.Io.File,
    stdout_file: ?std.Io.File,
    stderr_file: ?std.Io.File,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, request: types.SpawnRequest) !SpawnedChild {
        var owned = try request.clone(allocator);
        errdefer owned.deinit(allocator);
        var env_map_storage = process_env.buildMap(std.heap.page_allocator, owned.env, owned.clear_env) catch return error.EnvironmentBuildFailed;
        defer if (env_map_storage) |*env_map| env_map.deinit();
        var child = try std.process.spawn(io, .{
            .argv = owned.argv,
            .cwd = if (owned.cwd) |cwd| .{ .path = cwd } else .inherit,
            .environ_map = if (env_map_storage) |*env_map| env_map else null,
            .stdin = if (owned.stdin) .pipe else .ignore,
            .stdout = if (owned.stdout) .pipe else .ignore,
            .stderr = if (owned.stderr) .pipe else .ignore,
            .pgid = if (owned.process_group and process_common.supportsProcessGroups()) 0 else null,
        });
        errdefer if (child.id) |pid| process_common.killChild(pid, owned.process_group, .KILL);
        errdefer _ = child.wait(io) catch null;

        const stdin_file = child.stdin;
        const stdout_file = child.stdout;
        const stderr_file = child.stderr;
        child.stdin = null;
        child.stdout = null;
        child.stderr = null;
        return .{
            .request = owned,
            .child = child,
            .pid = child.id.?,
            .stdin_file = stdin_file,
            .stdout_file = stdout_file,
            .stderr_file = stderr_file,
        };
    }
};

pub fn closeFile(io: std.Io, file: *?std.Io.File) void {
    if (file.*) |f| f.close(io);
    file.* = null;
}

pub fn forceReap(io: std.Io, child: *std.process.Child, pid: std.process.Child.Id, process_group: bool, alive: *bool) void {
    if (!alive.*) return;
    process_common.killChild(pid, process_group, .KILL);
    _ = child.wait(io) catch null;
    alive.* = false;
}

pub fn publishEvent(allocator: std.mem.Allocator, queue: *types.EventQueue, event: types.Event) bool {
    switch (queue.trySend(event)) {
        .ok, .dropped => return true,
        .closed, .oom => |returned| {
            var current = returned;
            current.deinit(allocator);
            return false;
        },
        .full => |returned| {
            if (isTerminal(returned)) {
                const dropped = queue.dropMatching(isOutputEvent, null);
                if (dropped > 0) {
                    switch (queue.trySend(returned)) {
                        .ok, .dropped => return true,
                        .closed, .full, .oom => |retry_returned| {
                            var current = retry_returned;
                            current.deinit(allocator);
                            return false;
                        },
                    }
                }
            }
            var current = returned;
            current.deinit(allocator);
            return false;
        },
    }
}

pub fn publishOutput(allocator: std.mem.Allocator, queue: *types.EventQueue, id: types.ProcessId, stream: Stream, bytes: []const u8) !bool {
    const owned = try allocator.dupe(u8, bytes);
    const event: types.Event = switch (stream) {
        .stdout => .{ .stdout = .{ .id = id, .bytes = owned } },
        .stderr => .{ .stderr = .{ .id = id, .bytes = owned } },
    };
    switch (queue.trySend(event)) {
        .ok, .dropped => return true,
        .closed, .oom => |returned| {
            var current = returned;
            current.deinit(allocator);
            return false;
        },
        .full => |returned| {
            var current = returned;
            current.deinit(allocator);
            const dropped = queue.dropMatching(isOutputEvent, null);
            if (dropped == 0) return false;
            return publishEvent(allocator, queue, .{ .output_dropped = .{ .id = id, .count = dropped + 1 } });
        },
    }
}

fn isTerminal(event: types.Event) bool {
    return switch (event) {
        .ready, .exit, .spawn_failed => true,
        .stdout, .stderr, .output_dropped => false,
    };
}

fn isOutputEvent(item: *const types.Event, _: ?*anyopaque) bool {
    return switch (item.*) {
        .stdout, .stderr, .output_dropped => true,
        .ready, .exit, .spawn_failed => false,
    };
}
