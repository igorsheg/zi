const std = @import("std");
const ai = @import("../ai/root.zig");

pub const CallbackError = error{
    OutOfMemory,
    Failed,
};

/// Synchronous source for image-input capability. The implementation and its
/// context must outlive every copied handle. A resolved value is used only by
/// the provider request or tool dispatch that immediately follows the call.
pub const ImageInputSource = struct {
    context: *anyopaque,
    resolve_fn: *const fn (
        std.mem.Allocator,
        std.Io,
        *anyopaque,
    ) CallbackError!ai.Provider.ImageInput,

    pub fn resolve(
        self: ImageInputSource,
        allocator: std.mem.Allocator,
        io: std.Io,
    ) CallbackError!ai.Provider.ImageInput {
        return self.resolve_fn(allocator, io, self.context);
    }

    pub fn from(implementation: anytype) ImageInputSource {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("ImageInputSource.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn resolve(
                allocator: std.mem.Allocator,
                io: std.Io,
                context: *anyopaque,
            ) CallbackError!ai.Provider.ImageInput {
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
        ) CallbackError!ai.Provider.ImageInput {
            return .supported;
        }
    };
    var implementation: Source = .{};
    const source = ImageInputSource.from(&implementation);
    try std.testing.expectEqual(ai.Provider.ImageInput.supported, try source.resolve(
        std.testing.allocator,
        std.testing.io,
    ));
}

test "source forwards allocator failures without ambient allocation" {
    const Source = struct {
        const Self = @This();

        fn resolve(
            allocator: std.mem.Allocator,
            _: std.Io,
            _: *Self,
        ) CallbackError!ai.Provider.ImageInput {
            const scratch = try allocator.alloc(u8, 1);
            defer allocator.free(scratch);
            return .supported;
        }
    };
    var implementation: Source = .{};
    const source = ImageInputSource.from(&implementation);
    try std.testing.expectError(
        error.OutOfMemory,
        source.resolve(std.testing.failing_allocator, std.testing.io),
    );
}
