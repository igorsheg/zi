const std = @import("std");
const message = @import("message.zig");
const model_api = @import("model.zig");
const settings = @import("settings.zig");

pub const ModelDescriptor = struct {
    id: []const u8,
    display_name: ?[]const u8 = null,
    profile: settings.ModelProfile,
};

pub const OwnedModelList = struct {
    arena: std.heap.ArenaAllocator,
    items: []const ModelDescriptor,

    pub fn deinit(self: *OwnedModelList) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const ProviderError = error{OutOfMemory};

pub const Provider = struct {
    context: *anyopaque,
    vtable: *const VTable,
    id: []const u8,

    pub const VTable = struct {
        model: *const fn (*anyopaque, []const u8) ?model_api.Model,
        models: *const fn (*anyopaque, std.mem.Allocator) ProviderError!OwnedModelList,
    };

    pub fn from(implementation: anytype, id: []const u8) Provider {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        comptime {
            if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
                @compileError("Provider.from expects a single-item pointer");
            }
        }
        const Adapter = struct {
            fn modelFn(context: *anyopaque, model_id: []const u8) ?model_api.Model {
                const self: Pointer = @ptrCast(@alignCast(context));
                return self.model(model_id);
            }

            // The context-first order matches the erased provider ABI.
            // ziglint-ignore: Z023
            fn modelsFn(context: *anyopaque, allocator: std.mem.Allocator) ProviderError!OwnedModelList {
                const self: Pointer = @ptrCast(@alignCast(context));
                return self.models(allocator);
            }

            const vtable: VTable = .{ .model = modelFn, .models = modelsFn };
        };
        return .{ .context = implementation, .vtable = &Adapter.vtable, .id = id };
    }

    pub fn model(self: Provider, model_id: []const u8) ?model_api.Model {
        return self.vtable.model(self.context, model_id);
    }

    pub fn models(self: Provider, allocator: std.mem.Allocator) ProviderError!OwnedModelList {
        return self.vtable.models(self.context, allocator);
    }
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    providers: std.ArrayList(Provider) = .empty,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        self.providers.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn register(self: *Registry, provider: Provider) error{ OutOfMemory, DuplicateProvider, InvalidProvider }!void {
        if (provider.id.len == 0) return error.InvalidProvider;
        for (self.providers.items) |registered| {
            if (std.mem.eql(u8, registered.id, provider.id)) return error.DuplicateProvider;
        }
        try self.providers.append(self.allocator, provider);
    }

    pub fn resolve(self: *const Registry, identity: message.ModelIdentity) ?model_api.Model {
        for (self.providers.items) |provider| {
            if (std.mem.eql(u8, provider.id, identity.provider)) return provider.model(identity.model);
        }
        return null;
    }
};

test "registry resolves borrowed provider models without central dispatch" {
    const Stub = struct {
        const Self = @This();
        identity: message.ModelIdentity,

        fn provider(self: *Self) Provider {
            return Provider.from(self, self.identity.provider);
        }

        fn model(self: *Self, model_id: []const u8) ?model_api.Model {
            if (!std.mem.eql(u8, model_id, self.identity.model)) return null;
            return model_api.Model.from(self, self.identity, .{});
        }

        fn models(self: *Self, allocator: std.mem.Allocator) ProviderError!OwnedModelList {
            var arena = std.heap.ArenaAllocator.init(allocator);
            errdefer arena.deinit();
            const items = arena.allocator().alloc(ModelDescriptor, 1) catch return error.OutOfMemory;
            items[0] = .{ .id = self.identity.model, .profile = .{} };
            return .{ .arena = arena, .items = items };
        }

        pub fn invoke(
            self: *Self,
            allocator: std.mem.Allocator,
            _: std.mem.Allocator,
            _: std.Io,
            _: model_api.ModelRequest,
            _: model_api.Delivery,
        ) model_api.ModelError!message.ResponseMessage {
            return .{
                .parts = allocator.alloc(message.ResponsePart, 0) catch return error.OutOfMemory,
                .identity = self.identity,
            };
        }
    };

    var stub: Stub = .{ .identity = .{ .provider = "stub", .model = "one" } };
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.register(stub.provider());
    try std.testing.expect(registry.resolve(stub.identity) != null);
    try std.testing.expect(registry.resolve(.{ .provider = "stub", .model = "missing" }) == null);
    try std.testing.expectError(error.DuplicateProvider, registry.register(stub.provider()));
}
