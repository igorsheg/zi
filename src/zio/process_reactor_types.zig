const std = @import("std");
const queue_mod = @import("queue.zig");

pub const ProcessId = u64;

pub const EnvPair = struct {
    key: []const u8,
    value: []const u8,
};

pub const SpawnRequest = struct {
    id: ProcessId,
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    env: []const EnvPair = &.{},
    clear_env: bool = false,
    process_group: bool = true,
    stdin: bool = true,
    stdout: bool = true,
    stderr: bool = true,
    timeout_ms: ?u64 = null,
    signal: @import("cancel.zig").Token = .none,

    pub fn clone(self: SpawnRequest, allocator: std.mem.Allocator) !SpawnRequest {
        const argv = try allocator.alloc([]const u8, self.argv.len);
        errdefer allocator.free(argv);
        var argv_built: usize = 0;
        errdefer for (argv[0..argv_built]) |arg| allocator.free(arg);
        for (self.argv, 0..) |arg, i| {
            argv[i] = try allocator.dupe(u8, arg);
            argv_built += 1;
        }

        const env = try allocator.alloc(EnvPair, self.env.len);
        errdefer allocator.free(env);
        var env_built: usize = 0;
        errdefer for (env[0..env_built]) |pair| {
            allocator.free(pair.key);
            allocator.free(pair.value);
        };
        for (self.env, 0..) |pair, i| {
            env[i] = .{
                .key = try allocator.dupe(u8, pair.key),
                .value = try allocator.dupe(u8, pair.value),
            };
            env_built += 1;
        }

        return .{
            .id = self.id,
            .argv = argv,
            .cwd = if (self.cwd) |cwd| try allocator.dupe(u8, cwd) else null,
            .env = env,
            .clear_env = self.clear_env,
            .process_group = self.process_group,
            .stdin = self.stdin,
            .stdout = self.stdout,
            .stderr = self.stderr,
            .timeout_ms = self.timeout_ms,
            .signal = self.signal,
        };
    }

    pub fn deinit(self: *SpawnRequest, allocator: std.mem.Allocator) void {
        for (self.argv) |arg| allocator.free(arg);
        allocator.free(self.argv);
        if (self.cwd) |cwd| allocator.free(cwd);
        for (self.env) |pair| {
            allocator.free(pair.key);
            allocator.free(pair.value);
        }
        allocator.free(self.env);
        self.* = undefined;
    }
};

pub const WriteRequest = struct {
    id: ProcessId,
    bytes: []const u8,

    pub fn clone(self: WriteRequest, allocator: std.mem.Allocator) !WriteRequest {
        return .{ .id = self.id, .bytes = try allocator.dupe(u8, self.bytes) };
    }

    pub fn deinit(self: *WriteRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const Request = union(enum) {
    spawn: SpawnRequest,
    write: WriteRequest,
    close_stdin: ProcessId,
    stop: ProcessId,
    shutdown,

    pub fn deinit(self: *Request, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .spawn => |*request| request.deinit(allocator),
            .write => |*request| request.deinit(allocator),
            .close_stdin, .stop, .shutdown => {},
        }
        self.* = undefined;
    }
};

pub const Event = union(enum) {
    ready: ProcessId,
    stdout: Output,
    stderr: Output,
    exit: Exit,
    spawn_failed: ProcessId,

    pub const Output = struct { id: ProcessId, bytes: []const u8 };
    pub const Exit = struct {
        id: ProcessId,
        term: ?std.process.Child.Term,
        timed_out: bool = false,
        aborted: bool = false,
    };

    pub fn deinit(self: *Event, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .stdout => |out| allocator.free(out.bytes),
            .stderr => |out| allocator.free(out.bytes),
            .ready, .exit, .spawn_failed => {},
        }
        self.* = undefined;
    }
};

fn cleanupRequest(item: *anyopaque, allocator: std.mem.Allocator) void {
    const request: *Request = @ptrCast(@alignCast(item));
    request.deinit(allocator);
}

fn cleanupEvent(item: *anyopaque, allocator: std.mem.Allocator) void {
    const event: *Event = @ptrCast(@alignCast(item));
    event.deinit(allocator);
}

pub const RequestQueue = queue_mod.Queue(Request, .{
    .cleanup = .{ .custom = cleanupRequest },
    .policy = .{ .bounded = .{ .capacity = 256, .on_full = .reject } },
    .wakeup = .pipe,
});

pub const EventQueue = queue_mod.Queue(Event, .{
    .cleanup = .{ .custom = cleanupEvent },
    .policy = .{ .bounded = .{ .capacity = 1024, .on_full = .reject } },
    .wakeup = .pipe,
});
