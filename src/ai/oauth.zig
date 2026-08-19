const std = @import("std");
const credential = @import("credential.zig");
const transport_api = @import("transport.zig");

pub const Error = error{
    OutOfMemory,
    Cancelled,
    TimedOut,
    InvalidUrl,
    ConnectionFailed,
    InvalidResponse,
    ResponseTooLarge,
    ConsumerStopped,
    Rejected,
};

pub const Request = struct {
    credential: credential.Credential.OAuth,
    now_ms: u64,
};

pub const Refreshed = struct {
    arena: std.heap.ArenaAllocator,
    credential: credential.Credential.OAuth,

    pub fn deinit(self: *Refreshed) void {
        std.crypto.secureZero(u8, @constCast(self.credential.access));
        std.crypto.secureZero(u8, @constCast(self.credential.refresh));
        if (self.credential.account_id) |account_id| {
            std.crypto.secureZero(u8, @constCast(account_id));
        }
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Refresher = struct {
    context: *const anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        refresh: *const fn (
            context: *const anyopaque,
            result_allocator: std.mem.Allocator,
            scratch_allocator: std.mem.Allocator,
            io: std.Io,
            transport: transport_api.Transport,
            request: Request,
        ) Error!Refreshed,
    };

    pub fn from(implementation: anytype) Refresher {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        comptime {
            if (pointer_info != .pointer or pointer_info.pointer.size != .one or
                !pointer_info.pointer.is_const)
            {
                @compileError("OAuth Refresher.from expects a const single-item pointer");
            }
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            // Context leads because this adapter implements the erased refresher ABI.
            // ziglint-ignore: Z023
            fn refreshImpl(
                context: *const anyopaque,
                result_allocator: std.mem.Allocator, // ziglint-ignore: Z023
                scratch_allocator: std.mem.Allocator, // ziglint-ignore: Z023
                io: std.Io, // ziglint-ignore: Z023
                transport: transport_api.Transport,
                request: Request,
            ) Error!Refreshed {
                const self: *const Implementation = @ptrCast(@alignCast(context));
                return self.refresh(
                    result_allocator,
                    scratch_allocator,
                    io,
                    transport,
                    request,
                );
            }

            const vtable: VTable = .{ .refresh = refreshImpl };
        };
        return .{ .context = implementation, .vtable = &Adapter.vtable };
    }

    pub fn refresh(
        self: Refresher,
        result_allocator: std.mem.Allocator,
        scratch_allocator: std.mem.Allocator,
        io: std.Io,
        transport: transport_api.Transport,
        request: Request,
    ) Error!Refreshed {
        return self.vtable.refresh(
            self.context,
            result_allocator,
            scratch_allocator,
            io,
            transport,
            request,
        );
    }
};
