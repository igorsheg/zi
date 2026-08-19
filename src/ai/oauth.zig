const std = @import("std");
const credential = @import("credential.zig");
const model = @import("model.zig");
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
    cancellation: ?*const model.CancellationToken = null,
};

pub const LoginMethod = enum {
    browser,
    device_code,
};

pub const Event = union(enum) {
    auth_url: struct {
        url: []const u8,
        instructions: []const u8,
    },
    device_code: struct {
        user_code: []const u8,
        verification_uri: []const u8,
        interval_seconds: u64,
        expires_in_seconds: u64,
    },
};

pub const Prompt = struct {
    message: []const u8,
    placeholder: ?[]const u8 = null,
};

pub const Interaction = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        notify: *const fn (*anyopaque, Event) anyerror!void,
        prompt: *const fn (*anyopaque, std.mem.Allocator, Prompt) anyerror![]u8,
    };

    pub fn notify(self: Interaction, event: Event) !void {
        return self.vtable.notify(self.context, event);
    }

    pub fn prompt(self: Interaction, allocator: std.mem.Allocator, request: Prompt) ![]u8 {
        return self.vtable.prompt(self.context, allocator, request);
    }
};

pub const LoginRequest = struct {
    method: LoginMethod,
    interaction: Interaction,
    now_ms: u64,
    cancellation: ?*const model.CancellationToken = null,
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

pub const Authenticator = struct {
    context: *const anyopaque,
    login_fn: *const fn (
        *const anyopaque,
        std.mem.Allocator,
        std.mem.Allocator,
        std.Io,
        transport_api.Transport,
        LoginRequest,
    ) Error!Refreshed,

    pub fn from(implementation: anytype) Authenticator {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        comptime {
            if (pointer_info != .pointer or pointer_info.pointer.size != .one or
                !pointer_info.pointer.is_const)
            {
                @compileError("OAuth Authenticator.from expects a const single-item pointer");
            }
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            // Context leads because this adapter implements the erased authenticator ABI.
            // ziglint-ignore: Z023
            fn login(
                context: *const anyopaque,
                result_allocator: std.mem.Allocator, // ziglint-ignore: Z023
                scratch_allocator: std.mem.Allocator, // ziglint-ignore: Z023
                io: std.Io, // ziglint-ignore: Z023
                transport: transport_api.Transport,
                request: LoginRequest,
            ) Error!Refreshed {
                const self: *const Implementation = @ptrCast(@alignCast(context));
                return self.login(result_allocator, scratch_allocator, io, transport, request);
            }
        };
        return .{ .context = implementation, .login_fn = Adapter.login };
    }

    pub fn login(
        self: Authenticator,
        result_allocator: std.mem.Allocator,
        scratch_allocator: std.mem.Allocator,
        io: std.Io,
        transport: transport_api.Transport,
        request: LoginRequest,
    ) Error!Refreshed {
        return self.login_fn(
            self.context,
            result_allocator,
            scratch_allocator,
            io,
            transport,
            request,
        );
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
