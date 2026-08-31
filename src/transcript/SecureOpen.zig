//! Erased secure writable-file capability and its POSIX implementation.

const std = @import("std");
const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("sys/stat.h");
    @cInclude("unistd.h");
});

pub const Error = error{
    OutOfMemory,
    InvalidPath,
    PathTooLong,
    Symlink,
    NotRegular,
    WrongOwner,
    LinkCount,
    Permission,
    Busy,
    IdentityChanged,
    IoFailure,
};

pub const Identity = struct {
    device: u64,
    inode: std.Io.File.INode,
};

pub const Token = struct {
    size: u64,
    mode: std.posix.mode_t,
    mtime_ns: i96,
    ctime_ns: i96,
};

pub const Snapshot = struct {
    identity: Identity,
    token: Token,
    nlink: std.Io.File.NLink,
    regular: bool,

    pub fn sameIdentity(a: Snapshot, b: Snapshot) bool {
        return a.identity.device == b.identity.device and a.identity.inode == b.identity.inode;
    }

    pub fn sameToken(a: Snapshot, b: Snapshot) bool {
        return a.sameIdentity(b) and a.nlink == b.nlink and a.regular == b.regular and
            a.token.size == b.token.size and a.token.mode == b.token.mode and
            a.token.mtime_ns == b.token.mtime_ns and a.token.ctime_ns == b.token.ctime_ns;
    }
};

pub const Opened = struct {
    context: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        close: *const fn (std.mem.Allocator, std.Io, *anyopaque) void,
        try_lock: *const fn (std.Io, *anyopaque) Error!bool,
        stat_opened: *const fn (std.Io, *anyopaque) Error!Snapshot,
        stat_named: *const fn (std.Io, *anyopaque) Error!Snapshot,
        set_permissions: *const fn (std.Io, *anyopaque) Error!void,
        set_length: *const fn (std.Io, *anyopaque, u64) Error!void,
        write_all: *const fn (std.Io, *anyopaque, []const u8, u64) Error!void,
    };

    pub fn close(self: Opened, allocator: std.mem.Allocator, io: std.Io) void {
        self.vtable.close(allocator, io, self.context);
    }

    pub fn tryLock(self: Opened, io: std.Io) Error!bool {
        return self.vtable.try_lock(io, self.context);
    }

    pub fn statOpened(self: Opened, io: std.Io) Error!Snapshot {
        return self.vtable.stat_opened(io, self.context);
    }

    pub fn statNamed(self: Opened, io: std.Io) Error!Snapshot {
        return self.vtable.stat_named(io, self.context);
    }

    pub fn setPermissions(self: Opened, io: std.Io) Error!void {
        return self.vtable.set_permissions(io, self.context);
    }

    pub fn setLength(self: Opened, io: std.Io, length: u64) Error!void {
        return self.vtable.set_length(io, self.context, length);
    }

    pub fn writeAll(self: Opened, io: std.Io, bytes: []const u8, offset: u64) Error!void {
        return self.vtable.write_all(io, self.context, bytes, offset);
    }

    pub fn from(implementation: anytype) Opened {
        const Pointer = @TypeOf(implementation);
        const info = @typeInfo(Pointer);
        if (info != .pointer or info.pointer.size != .one or info.pointer.is_const) {
            @compileError("Opened.from expects a mutable single-item pointer");
        }
        const Implementation = info.pointer.child;
        const Adapter = struct {
            fn close(allocator: std.mem.Allocator, io: std.Io, context: *anyopaque) void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                self.close(allocator, io);
            }
            fn tryLock(io: std.Io, context: *anyopaque) Error!bool {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.tryLock(io);
            }
            fn statOpened(io: std.Io, context: *anyopaque) Error!Snapshot {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.statOpened(io);
            }
            fn statNamed(io: std.Io, context: *anyopaque) Error!Snapshot {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.statNamed(io);
            }
            fn setPermissions(io: std.Io, context: *anyopaque) Error!void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.setPermissions(io);
            }
            fn setLength(io: std.Io, context: *anyopaque, length: u64) Error!void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.setLength(io, length);
            }
            fn writeAll(io: std.Io, context: *anyopaque, bytes: []const u8, offset: u64) Error!void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.writeAll(io, bytes, offset);
            }
        };
        return .{ .context = implementation, .vtable = &.{
            .close = Adapter.close,
            .try_lock = Adapter.tryLock,
            .stat_opened = Adapter.statOpened,
            .stat_named = Adapter.statNamed,
            .set_permissions = Adapter.setPermissions,
            .set_length = Adapter.setLength,
            .write_all = Adapter.writeAll,
        } };
    }
};

/// Opens one writable target without following any path component. Implementations
/// validate regular kind, current-user ownership, and a single link before returning.
/// The returned handle retains its final parent directory for named no-follow stats.
pub const Capability = struct {
    context: *anyopaque,
    open_fn: *const fn (std.mem.Allocator, std.Io, *anyopaque, []const u8) Error!Opened,

    pub fn open(
        self: Capability,
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
    ) Error!Opened {
        return self.open_fn(allocator, io, self.context, path);
    }

    pub fn from(implementation: anytype) Capability {
        const Pointer = @TypeOf(implementation);
        const info = @typeInfo(Pointer);
        if (info != .pointer or info.pointer.size != .one or info.pointer.is_const) {
            @compileError("Capability.from expects a mutable single-item pointer");
        }
        const Implementation = info.pointer.child;
        const Adapter = struct {
            fn open(
                allocator: std.mem.Allocator,
                io: std.Io,
                context: *anyopaque,
                path: []const u8,
            ) Error!Opened {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.open(allocator, io, path);
            }
        };
        return .{ .context = implementation, .open_fn = Adapter.open };
    }
};

pub const Posix = struct {
    pub fn capability(self: *Posix) Capability {
        return .from(self);
    }

    pub fn open(
        _: *Posix,
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
    ) Error!Opened {
        if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
        if (path.len > std.fs.max_path_bytes) return error.PathTooLong;

        var parent = openStart(io, path[0] == '/') catch |err| return mapOpen(err);
        errdefer parent.close(io);
        var components = std.mem.tokenizeScalar(u8, path, '/');
        var component = components.next() orelse return error.InvalidPath;
        while (components.next()) |next| {
            if (std.mem.eql(u8, component, ".")) {
                component = next;
                continue;
            }
            const child = openDirectory(io, parent, component) catch |err| return mapOpen(err);
            parent.close(io);
            parent = child;
            component = next;
        }
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) {
            return error.InvalidPath;
        }

        const handle = std.posix.openat(parent.handle, component, .{
            .ACCMODE = .RDWR,
            .CLOEXEC = true,
            .CREAT = true,
            .NONBLOCK = true,
            .NOFOLLOW = true,
        }, 0o600) catch |err| return mapOpen(err);
        const file: std.Io.File = .{ .handle = handle, .flags = .{ .nonblocking = true } };
        errdefer file.close(io);
        const name = allocator.dupe(u8, component) catch return error.OutOfMemory;
        errdefer allocator.free(name);
        const state = allocator.create(PosixOpened) catch return error.OutOfMemory;
        errdefer allocator.destroy(state);
        state.* = .{ .file = file, .parent = parent, .name = name };

        const opened = Opened.from(state);
        const initial = try opened.statOpened(io);
        try validateTarget(initial);
        try validateOwner(file);
        const named = try opened.statNamed(io);
        if (!initial.sameIdentity(named)) return error.IdentityChanged;
        return opened;
    }
};

const PosixOpened = struct {
    file: std.Io.File,
    parent: std.Io.Dir,
    name: []u8,

    fn close(self: *PosixOpened, allocator: std.mem.Allocator, io: std.Io) void {
        self.file.close(io);
        self.parent.close(io);
        allocator.free(self.name);
        allocator.destroy(self);
    }

    fn tryLock(self: *PosixOpened, io: std.Io) Error!bool {
        return self.file.tryLock(io, .exclusive) catch |err| switch (err) {
            error.Canceled => error.IoFailure,
            else => error.IoFailure,
        };
    }

    fn statOpened(self: *PosixOpened, io: std.Io) Error!Snapshot {
        var result = snapshot(self.file.stat(io) catch return error.IoFailure);
        var native: c.struct_stat = undefined;
        if (c.fstat(self.file.handle, &native) != 0) return error.IoFailure;
        result.identity.device = @intCast(native.st_dev);
        return result;
    }

    fn statNamed(self: *PosixOpened, io: std.Io) Error!Snapshot {
        const stat = self.parent.statFile(io, self.name, .{ .follow_symlinks = false }) catch |err|
            return mapStat(err);
        var result = snapshot(stat);
        const name_z = std.posix.toPosixPath(self.name) catch return error.PathTooLong;
        var native: c.struct_stat = undefined;
        if (c.fstatat(self.parent.handle, &name_z, &native, c.AT_SYMLINK_NOFOLLOW) != 0) {
            return error.IdentityChanged;
        }
        result.identity.device = @intCast(native.st_dev);
        return result;
    }

    fn setPermissions(self: *PosixOpened, io: std.Io) Error!void {
        self.file.setPermissions(io, .fromMode(0o600)) catch return error.Permission;
    }

    fn setLength(self: *PosixOpened, io: std.Io, length: u64) Error!void {
        self.file.setLength(io, length) catch return error.IoFailure;
    }

    fn writeAll(self: *PosixOpened, io: std.Io, bytes: []const u8, offset: u64) Error!void {
        self.file.writePositionalAll(io, bytes, offset) catch return error.IoFailure;
    }
};

fn openStart(io: std.Io, absolute: bool) !std.Io.Dir {
    return std.Io.Dir.openDir(.cwd(), io, if (absolute) "/" else ".", .{ .follow_symlinks = false });
}

fn openDirectory(_: std.Io, parent: std.Io.Dir, name: []const u8) !std.Io.Dir {
    const handle = try std.posix.openat(parent.handle, name, .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
        .DIRECTORY = true,
        .NONBLOCK = true,
        .NOFOLLOW = true,
    }, 0);
    return .{ .handle = handle };
}

fn snapshot(stat: std.Io.File.Stat) Snapshot {
    return .{
        .identity = .{ .device = 0, .inode = stat.inode },
        .token = .{
            .size = stat.size,
            .mode = stat.permissions.toMode(),
            .mtime_ns = stat.mtime.nanoseconds,
            .ctime_ns = stat.ctime.nanoseconds,
        },
        .nlink = stat.nlink,
        .regular = stat.kind == .file,
    };
}

fn validateTarget(value: Snapshot) Error!void {
    if (!value.regular) return error.NotRegular;
    if (value.nlink != 1) return error.LinkCount;
}

fn validateOwner(file: std.Io.File) Error!void {
    var value: c.struct_stat = undefined;
    if (c.fstat(file.handle, &value) != 0) return error.IoFailure;
    if (value.st_uid != c.geteuid()) return error.WrongOwner;
}

fn mapOpen(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.NameTooLong => error.PathTooLong,
        error.SymLinkLoop => error.Symlink,
        error.IsDir => error.NotRegular,
        error.AccessDenied, error.PermissionDenied => error.Permission,
        error.NotDir => error.Symlink,
        else => error.IoFailure,
    };
}

fn mapStat(err: anyerror) Error {
    return switch (err) {
        error.NameTooLong => error.PathTooLong,
        error.SymLinkLoop => error.Symlink,
        error.AccessDenied, error.PermissionDenied => error.Permission,
        else => error.IdentityChanged,
    };
}

fn absolutePath(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, name: []const u8) ![]u8 {
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(base);
    return std.fs.path.join(allocator, &.{ base, name });
}

test "POSIX capability creates owner-only regular file and holds an exclusive lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try absolutePath(std.testing.allocator, &tmp, "transcript.txt");
    defer std.testing.allocator.free(path);
    var implementation: Posix = .{};
    const opened = try implementation.capability().open(std.testing.allocator, std.testing.io, path);
    defer opened.close(std.testing.allocator, std.testing.io);
    try std.testing.expect(try opened.tryLock(std.testing.io));
    const stat = try opened.statOpened(std.testing.io);
    try std.testing.expect(stat.regular);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.token.mode & 0o777);

    const competitor = try std.Io.Dir.openFile(.cwd(), std.testing.io, path, .{ .mode = .read_write });
    defer competitor.close(std.testing.io);
    try std.testing.expect(!try competitor.tryLock(std.testing.io, .exclusive));
}

test "POSIX capability rejects symlinks, nonregular targets, and hard links" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "real", .default_dir);
    try tmp.dir.symLink(std.testing.io, "real", "parent-link", .{ .is_directory = true });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "target", .data = "x" });
    try tmp.dir.symLink(std.testing.io, "target", "final-link", .{});
    try tmp.dir.createDir(std.testing.io, "directory", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "hard-target", .data = "x" });
    const hard_target = try absolutePath(std.testing.allocator, &tmp, "hard-target");
    defer std.testing.allocator.free(hard_target);
    const hard_link = try absolutePath(std.testing.allocator, &tmp, "hard-link");
    defer std.testing.allocator.free(hard_link);
    const hard_target_z = try std.testing.allocator.dupeZ(u8, hard_target);
    defer std.testing.allocator.free(hard_target_z);
    const hard_link_z = try std.testing.allocator.dupeZ(u8, hard_link);
    defer std.testing.allocator.free(hard_link_z);
    try std.testing.expectEqual(@as(c_int, 0), c.link(hard_target_z.ptr, hard_link_z.ptr));

    var implementation: Posix = .{};
    inline for (.{ "parent-link/file", "final-link", "directory" }) |name| {
        const path = try absolutePath(std.testing.allocator, &tmp, name);
        defer std.testing.allocator.free(path);
        try std.testing.expectError(switch (name[0]) {
            'd' => error.NotRegular,
            else => error.Symlink,
        }, implementation.capability().open(std.testing.allocator, std.testing.io, path));
    }
    try std.testing.expectError(
        error.LinkCount,
        implementation.capability().open(std.testing.allocator, std.testing.io, hard_link),
    );
}
