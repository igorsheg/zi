const std = @import("std");

/// Injected secure regular-file opener. Implementations must open `name`
/// relative to `directory`, reject a final symlink, set close-on-exec, and use
/// nonblocking mode so special files cannot stall discovery. The returned file
/// transfers to the caller.
pub const Capability = struct {
    context: *anyopaque,
    open_fn: *const fn (*anyopaque, std.Io, std.Io.Dir, []const u8) anyerror!std.Io.File,

    pub fn openFile(
        self: Capability,
        io: std.Io,
        directory: std.Io.Dir,
        name: []const u8,
    ) anyerror!std.Io.File {
        return self.open_fn(self.context, io, directory, name);
    }

    pub fn from(implementation: anytype) Capability {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("SecureOpen.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn openFile(
                context: *anyopaque,
                io: std.Io,
                directory: std.Io.Dir,
                name: []const u8,
            ) anyerror!std.Io.File {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.openFile(io, directory, name);
            }
        };
        return .{ .context = implementation, .open_fn = Adapter.openFile };
    }
};
