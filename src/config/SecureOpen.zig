const std = @import("std");

/// Errors retain the distinctions used by config diagnostics while keeping
/// allocator exhaustion fatal. All other operating-system failures are
/// represented without exposing a platform error set.
pub const Error = error{
    OutOfMemory,
    FileNotFound,
    Unreadable,
    InvalidPath,
    Failed,
};

/// Injected access to absolute config paths. Implementations must reject
/// relative paths. `statFile` must not follow the final symlink. `openFile`
/// must reject the final symlink, use nonblocking and close-on-exec modes, and
/// transfer the returned file to the caller.
pub const Capability = struct {
    context: *anyopaque,
    stat_fn: *const fn (std.Io, *anyopaque, []const u8) Error!std.Io.File.Stat,
    open_fn: *const fn (std.Io, *anyopaque, []const u8) Error!std.Io.File,

    pub fn statFile(self: Capability, io: std.Io, absolute_path: []const u8) Error!std.Io.File.Stat {
        return self.stat_fn(io, self.context, absolute_path);
    }

    pub fn openFile(self: Capability, io: std.Io, absolute_path: []const u8) Error!std.Io.File {
        return self.open_fn(io, self.context, absolute_path);
    }

    pub fn from(implementation: anytype) Capability {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one or pointer_info.pointer.is_const) {
            @compileError("SecureOpen.from expects a mutable single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn statFile(io: std.Io, context: *anyopaque, path: []const u8) Error!std.Io.File.Stat {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.statAbsolute(io, path);
            }

            fn openFile(io: std.Io, context: *anyopaque, path: []const u8) Error!std.Io.File {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.openAbsolute(io, path);
            }
        };
        return .{ .context = implementation, .stat_fn = Adapter.statFile, .open_fn = Adapter.openFile };
    }
};
