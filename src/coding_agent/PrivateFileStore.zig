const std = @import("std");
const builtin = @import("builtin");

pub const private_dir_permissions = std.Io.File.Permissions.fromMode(0o700);
pub const private_file_permissions = std.Io.File.Permissions.fromMode(0o600);
const lock_timeout_ms = 2000;
const lock_poll_ms = 10;

pub const Error = error{
    OutOfMemory,
    UnsafePath,
    ReadFailed,
    LockFailed,
    WriteFailed,
    CommitIndeterminate,
};

pub const Boundary = enum {
    after_write,
    after_file_sync,
    after_replace,
};

pub const Faults = struct {
    context: ?*anyopaque = null,
    boundary_fn: ?*const fn (*anyopaque, Boundary) anyerror!void = null,

    pub fn none() Faults {
        return .{};
    }

    fn boundary(self: Faults, point: Boundary) !void {
        const function = self.boundary_fn orelse return;
        return function(self.context.?, point);
    }
};

pub const Mutation = struct {
    io: std.Io,
    directory: std.Io.Dir,
    lock: std.Io.File,
    faults: Faults,

    pub fn deinit(self: *Mutation) void {
        self.lock.unlock(self.io);
        self.lock.close(self.io);
        self.directory.close(self.io);
        self.* = undefined;
    }

    /// The caller owns and must free the returned bytes.
    pub fn readFileAlloc(
        self: *Mutation,
        allocator: std.mem.Allocator,
        file_name: []const u8,
        maximum_bytes: usize,
    ) Error!?[]u8 {
        return readFromDirectory(
            allocator,
            self.io,
            self.directory,
            file_name,
            maximum_bytes,
            false,
        );
    }

    pub fn replace(self: *Mutation, file_name: []const u8, bytes: []const u8) Error!void {
        try validateRelativeLeaf(file_name);
        try validateReplaceTarget(self.io, self.directory, file_name);
        var atomic = self.directory.createFileAtomic(self.io, file_name, .{
            .permissions = private_file_permissions,
            .replace = true,
        }) catch return error.WriteFailed;
        defer atomic.deinit(self.io);
        atomic.file.writePositionalAll(self.io, bytes, 0) catch return error.WriteFailed;
        self.faults.boundary(.after_write) catch return error.WriteFailed;
        atomic.file.sync(self.io) catch return error.WriteFailed;
        self.faults.boundary(.after_file_sync) catch return error.WriteFailed;
        atomic.replace(self.io) catch return error.WriteFailed;
        self.faults.boundary(.after_replace) catch return error.CommitIndeterminate;
        validatePublishedFile(self.io, self.directory, file_name) catch
            return error.CommitIndeterminate;
        syncDirectory(self.directory) catch return error.CommitIndeterminate;
    }
};

/// The caller owns and must free the returned bytes.
pub fn readFileAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_path: []const u8,
    directory_path: []const u8,
    file_name: []const u8,
    maximum_bytes: usize,
) Error!?[]u8 {
    try validateRelativeLeaf(file_name);
    const directory = openDescendantDirectory(
        io,
        base_path,
        directory_path,
        .{},
        false,
    ) catch |failure| return switch (failure) {
        error.FileNotFound => null,
        else => error.UnsafePath,
    };
    defer directory.close(io);
    return readFromDirectory(
        allocator,
        io,
        directory,
        file_name,
        maximum_bytes,
        true,
    );
}

pub fn beginMutation(
    io: std.Io,
    base_path: []const u8,
    directory_path: []const u8,
    lock_name: []const u8,
    faults: Faults,
) Error!Mutation {
    try validateRelativeLeaf(lock_name);
    var directory = try openOrCreatePrivateDirectory(io, base_path, directory_path);
    errdefer directory.close(io);
    const lock = try openOrCreatePrivateLock(io, directory, lock_name);
    errdefer lock.close(io);
    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
        .raw = .fromMilliseconds(lock_timeout_ms),
        .clock = .awake,
    });
    while (!(lock.tryLock(io, .exclusive) catch return error.LockFailed)) {
        if (std.Io.Clock.Timestamp.now(io, .awake).compare(.gte, deadline)) {
            return error.LockFailed;
        }
        const poll: std.Io.Timeout = .{ .duration = .{
            .raw = .fromMilliseconds(lock_poll_ms),
            .clock = .awake,
        } };
        poll.sleep(io) catch return error.LockFailed;
    }
    return .{ .io = io, .directory = directory, .lock = lock, .faults = faults };
}

fn readFromDirectory(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    file_name: []const u8,
    maximum_bytes: usize,
    validate_directory: bool,
) Error!?[]u8 {
    try validateRelativeLeaf(file_name);
    const initial = directory.statFile(
        io,
        file_name,
        .{ .follow_symlinks = false },
    ) catch |failure| return switch (failure) {
        error.FileNotFound => null,
        else => error.ReadFailed,
    };
    try validatePrivateFile(initial);
    const file = directory.openFile(io, file_name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |failure| return switch (failure) {
        error.IsDir, error.NotDir, error.SymLinkLoop => error.UnsafePath,
        else => error.ReadFailed,
    };
    defer file.close(io);
    if (validate_directory) try validatePrivateDirectory(directory.stat(io) catch return error.ReadFailed);
    try validatePrivateFile(file.stat(io) catch return error.ReadFailed);
    var read_buffer: [8192]u8 = undefined;
    var file_reader = file.reader(io, &read_buffer);
    return file_reader.interface.allocRemaining(
        allocator,
        .limited(maximum_bytes + 1),
    ) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ReadFailed,
    };
}

fn openOrCreatePrivateDirectory(
    io: std.Io,
    base_path: []const u8,
    directory_path: []const u8,
) Error!std.Io.Dir {
    var directory = openDescendantDirectory(
        io,
        base_path,
        directory_path,
        .{ .iterate = true },
        true,
    ) catch return error.UnsafePath;
    errdefer directory.close(io);
    try validatePrivateDirectory(directory.stat(io) catch return error.UnsafePath);
    return directory;
}

fn openOrCreatePrivateLock(
    io: std.Io,
    directory: std.Io.Dir,
    lock_name: []const u8,
) Error!std.Io.File {
    var attempts: usize = 0;
    while (attempts < 2) : (attempts += 1) {
        const existing = directory.openFile(io, lock_name, .{
            .mode = .read_write,
            .allow_directory = false,
            .follow_symlinks = false,
            .resolve_beneath = true,
        }) catch |failure| switch (failure) {
            error.FileNotFound => {
                const created = directory.createFile(io, lock_name, .{
                    .read = true,
                    .exclusive = true,
                    .permissions = private_file_permissions,
                    .resolve_beneath = true,
                }) catch |create_failure| switch (create_failure) {
                    error.PathAlreadyExists => continue,
                    else => return error.LockFailed,
                };
                validatePrivateFile(created.stat(io) catch {
                    created.close(io);
                    return error.LockFailed;
                }) catch {
                    created.close(io);
                    return error.UnsafePath;
                };
                return created;
            },
            error.IsDir, error.NotDir, error.SymLinkLoop => return error.UnsafePath,
            else => return error.LockFailed,
        };
        errdefer existing.close(io);
        try validatePrivateFile(existing.stat(io) catch return error.LockFailed);
        return existing;
    }
    return error.LockFailed;
}

fn validateReplaceTarget(io: std.Io, directory: std.Io.Dir, file_name: []const u8) Error!void {
    const stat = directory.statFile(
        io,
        file_name,
        .{ .follow_symlinks = false },
    ) catch |failure| return switch (failure) {
        error.FileNotFound => {},
        else => error.WriteFailed,
    };
    try validatePrivateFile(stat);
    if (stat.permissions.toMode() & 0o200 == 0) return error.WriteFailed;
}

fn validatePublishedFile(io: std.Io, directory: std.Io.Dir, file_name: []const u8) Error!void {
    const stat = directory.statFile(io, file_name, .{ .follow_symlinks = false }) catch
        return error.CommitIndeterminate;
    try validatePrivateFile(stat);
}

fn validateRelativeLeaf(name: []const u8) Error!void {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or
        std.mem.findAny(u8, name, "/\\") != null)
    {
        return error.UnsafePath;
    }
}

fn validatePrivateDirectory(stat: std.Io.File.Stat) Error!void {
    if (stat.kind != .directory) return error.UnsafePath;
    if (comptime builtin.os.tag != .windows) {
        if (stat.permissions.toMode() & 0o777 != 0o700) return error.UnsafePath;
    }
}

fn validatePrivateFile(stat: std.Io.File.Stat) Error!void {
    if (stat.kind != .file or stat.nlink != 1) return error.UnsafePath;
    if (comptime builtin.os.tag != .windows) {
        if (stat.permissions.toMode() & 0o777 != 0o600) return error.UnsafePath;
    }
}

fn openDescendantDirectory(
    io: std.Io,
    base_path: []const u8,
    target_path: []const u8,
    options: std.Io.Dir.OpenOptions,
    create_missing: bool,
) !std.Io.Dir {
    const relative = try descendantPath(base_path, target_path);
    var components = std.fs.path.componentIterator(relative);
    var component = components.next() orelse return error.InvalidPath;
    var directory = try std.Io.Dir.openDirAbsolute(io, base_path, .{});
    errdefer directory.close(io);
    while (true) {
        if (std.mem.eql(u8, component.name, ".") or std.mem.eql(u8, component.name, "..")) {
            return error.InvalidPath;
        }
        const next_component = components.next();
        var child_options: std.Io.Dir.OpenOptions = if (next_component == null) options else .{};
        child_options.follow_symlinks = false;
        const child = directory.openDir(io, component.name, child_options) catch |failure| child: {
            if (!create_missing or failure != error.FileNotFound) return failure;
            directory.createDir(
                io,
                component.name,
                private_dir_permissions,
            ) catch |create_failure| switch (create_failure) {
                error.PathAlreadyExists => {},
                else => return create_failure,
            };
            break :child try directory.openDir(io, component.name, child_options);
        };
        directory.close(io);
        directory = child;
        component = next_component orelse return directory;
    }
}

fn descendantPath(base_path: []const u8, target_path: []const u8) ![]const u8 {
    if (!std.fs.path.isAbsolute(base_path) or !std.fs.path.isAbsolute(target_path)) {
        return error.InvalidPath;
    }
    if (!std.mem.startsWith(u8, target_path, base_path) or target_path.len <= base_path.len) {
        return error.InvalidPath;
    }
    if (std.fs.path.isSep(base_path[base_path.len - 1])) {
        return target_path[base_path.len..];
    }
    if (!std.fs.path.isSep(target_path[base_path.len])) return error.InvalidPath;
    return target_path[base_path.len + 1 ..];
}

fn syncDirectory(directory: std.Io.Dir) !void {
    if (comptime builtin.os.tag == .windows) return error.OperationUnsupported;
    while (true) {
        const result = std.c.fsync(directory.handle);
        if (result == 0) return;
        if (std.c.errno(result) == .INTR) continue;
        return error.DirectorySyncFailed;
    }
}

test "private file store rejects non-leaf names" {
    try std.testing.expectError(error.UnsafePath, validateRelativeLeaf(""));
    try std.testing.expectError(error.UnsafePath, validateRelativeLeaf("../secret"));
    try std.testing.expectError(error.UnsafePath, validateRelativeLeaf("nested/file"));
    try validateRelativeLeaf("state.json");
}
