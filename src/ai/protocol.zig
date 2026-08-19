const std = @import("std");
const auth = @import("auth.zig");
const message = @import("message.zig");
const model = @import("model.zig");
const settings = @import("settings.zig");
const transport = @import("transport.zig");

pub const Invocation = struct {
    transport: transport.Transport,
    base_url: []const u8,
    headers: []const transport.Header = &.{},
    auth: auth.ModelAuth = .{},
};

pub const ProfileHints = struct {
    reasoning: bool = false,
    reasoning_efforts: std.EnumSet(settings.ReasoningEffort) = .initEmpty(),
};

pub const Protocol = struct {
    context: *const anyopaque,
    vtable: *const VTable,
    id: []const u8,

    pub const VTable = struct {
        profile: *const fn (*const anyopaque, ProfileHints) settings.ModelProfile,
        invoke: *const fn (
            context: *const anyopaque,
            result_allocator: std.mem.Allocator,
            scratch_allocator: std.mem.Allocator,
            io: std.Io,
            invocation: Invocation,
            identity: message.ModelIdentity,
            request: model.ModelRequest,
            delivery: model.Delivery,
        ) model.ModelError!message.ResponseMessage,
    };

    pub fn from(implementation: anytype, id: []const u8) Protocol {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        comptime {
            if (pointer_info != .pointer or pointer_info.pointer.size != .one or !pointer_info.pointer.is_const) {
                @compileError("Protocol.from expects a const single-item pointer");
            }
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn profileImpl(context: *const anyopaque, hints: ProfileHints) settings.ModelProfile {
                const self: *const Implementation = @ptrCast(@alignCast(context));
                return self.profile(hints);
            }

            // Context leads because this adapter implements the erased protocol ABI.
            // ziglint-ignore: Z023
            fn invokeImpl(
                context: *const anyopaque,
                result_allocator: std.mem.Allocator, // ziglint-ignore: Z023
                scratch_allocator: std.mem.Allocator, // ziglint-ignore: Z023
                io: std.Io, // ziglint-ignore: Z023
                invocation: Invocation,
                identity: message.ModelIdentity,
                request: model.ModelRequest,
                delivery: model.Delivery,
            ) model.ModelError!message.ResponseMessage {
                const self: *const Implementation = @ptrCast(@alignCast(context));
                return self.invoke(
                    result_allocator,
                    scratch_allocator,
                    io,
                    invocation,
                    identity,
                    request,
                    delivery,
                );
            }

            const vtable: VTable = .{ .profile = profileImpl, .invoke = invokeImpl };
        };
        return .{ .context = implementation, .vtable = &Adapter.vtable, .id = id };
    }

    pub fn profile(self: Protocol, hints: ProfileHints) settings.ModelProfile {
        return self.vtable.profile(self.context, hints);
    }

    pub fn invoke(
        self: Protocol,
        result_allocator: std.mem.Allocator,
        scratch_allocator: std.mem.Allocator,
        io: std.Io,
        invocation: Invocation,
        identity: message.ModelIdentity,
        request: model.ModelRequest,
        delivery: model.Delivery,
    ) model.ModelError!message.ResponseMessage {
        return self.vtable.invoke(
            self.context,
            result_allocator,
            scratch_allocator,
            io,
            invocation,
            identity,
            request,
            delivery,
        );
    }
};

pub const Registry = struct {
    protocols: []const Protocol,

    pub fn init(protocols: []const Protocol) error{ InvalidProtocol, DuplicateProtocol }!Registry {
        for (protocols, 0..) |entry, index| {
            if (entry.id.len == 0) return error.InvalidProtocol;
            for (protocols[0..index]) |previous| {
                if (std.mem.eql(u8, previous.id, entry.id)) return error.DuplicateProtocol;
            }
        }
        return .{ .protocols = protocols };
    }

    pub fn find(self: Registry, id: []const u8) ?Protocol {
        for (self.protocols) |entry| {
            if (std.mem.eql(u8, entry.id, id)) return entry;
        }
        return null;
    }
};

test "protocol registry resolves implementations without provider dispatch" {
    const Stub = struct {
        const Self = @This();

        fn profile(_: *const Self, _: ProfileHints) settings.ModelProfile {
            return .{};
        }

        fn invoke(
            _: *const Self,
            allocator: std.mem.Allocator,
            _: std.mem.Allocator,
            _: std.Io,
            _: Invocation,
            identity: message.ModelIdentity,
            _: model.ModelRequest,
            _: model.Delivery,
        ) model.ModelError!message.ResponseMessage {
            return .{
                .identity = identity,
                .parts = allocator.alloc(message.ResponsePart, 0) catch return error.OutOfMemory,
            };
        }
    };
    const stub: Stub = .{};
    const protocols = [_]Protocol{Protocol.from(&stub, "test-protocol")};
    const registry = try Registry.init(&protocols);
    try std.testing.expect(registry.find("test-protocol") != null);
    try std.testing.expect(registry.find("missing") == null);
}
