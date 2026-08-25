const std = @import("std");
const ai = @import("../ai/root.zig");

pub const CallbackError = error{
    OutOfMemory,
    Failed,
};

/// Synchronous source for a live model metadata snapshot. The implementation
/// and its context must outlive every copied handle. Metadata is returned by
/// value and remains allocation-free after the callback returns.
pub const ModelMetadataSource = struct {
    context: *anyopaque,
    resolve_fn: *const fn (
        std.mem.Allocator,
        std.Io,
        *anyopaque,
    ) CallbackError!ai.ModelMeta.Metadata,

    pub fn resolve(
        self: ModelMetadataSource,
        allocator: std.mem.Allocator,
        io: std.Io,
    ) CallbackError!ai.ModelMeta.Metadata {
        return self.resolve_fn(allocator, io, self.context);
    }

    pub fn from(implementation: anytype) ModelMetadataSource {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("ModelMetadataSource.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn resolve(
                allocator: std.mem.Allocator,
                io: std.Io,
                context: *anyopaque,
            ) CallbackError!ai.ModelMeta.Metadata {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return Implementation.resolve(allocator, io, self);
            }
        };
        return .{ .context = implementation, .resolve_fn = Adapter.resolve };
    }
};

test "source is implementable through the erased seam" {
    const Source = struct {
        const Self = @This();

        fn resolve(
            _: std.mem.Allocator,
            _: std.Io,
            _: *Self,
        ) CallbackError!ai.ModelMeta.Metadata {
            return .{ .context_window = 32_000 };
        }
    };
    var implementation: Source = .{};
    const source = ModelMetadataSource.from(&implementation);
    const metadata = try source.resolve(std.testing.allocator, std.testing.io);
    try std.testing.expectEqual(@as(u64, 32_000), metadata.context_window);
}

test "source forwards allocator failures" {
    const Source = struct {
        const Self = @This();

        fn resolve(
            allocator: std.mem.Allocator,
            _: std.Io,
            _: *Self,
        ) CallbackError!ai.ModelMeta.Metadata {
            const scratch = try allocator.alloc(u8, 1);
            defer allocator.free(scratch);
            return .{};
        }
    };
    var implementation: Source = .{};
    const source = ModelMetadataSource.from(&implementation);
    try std.testing.expectError(
        error.OutOfMemory,
        source.resolve(std.testing.failing_allocator, std.testing.io),
    );
}
