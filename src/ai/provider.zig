const std = @import("std");
const auth_api = @import("auth.zig");
const fake_transport = @import("transport/fake.zig");
const message = @import("message.zig");
const model_catalog = @import("model_catalog.zig");
const model_api = @import("model.zig");
const protocol_api = @import("protocol.zig");
const settings = @import("settings.zig");
const transport_api = @import("transport.zig");

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

pub fn modelsFromCatalog(
    allocator: std.mem.Allocator,
    catalog: model_catalog.Catalog,
    provider_id: []const u8,
) ProviderError!OwnedModelList {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var count: usize = 0;
    for (catalog.entries) |entry| {
        if (std.mem.eql(u8, entry.identity.provider, provider_id)) count += 1;
    }
    const items = arena.allocator().alloc(ModelDescriptor, count) catch return error.OutOfMemory;
    var index: usize = 0;
    for (catalog.entries) |entry| {
        if (!std.mem.eql(u8, entry.identity.provider, provider_id)) continue;
        items[index] = .{
            .id = arena.allocator().dupe(u8, entry.identity.model) catch return error.OutOfMemory,
            .profile = entry.profile,
        };
        index += 1;
    }
    return .{ .arena = arena, .items = items };
}

fn createCatalogModelList(allocator: std.mem.Allocator) !void {
    const entries = [_]model_catalog.Entry{
        .{
            .identity = .{ .provider = "provider", .model = "one" },
            .protocol_id = "test-protocol",
            .profile = .{},
        },
        .{
            .identity = .{ .provider = "provider", .model = "two" },
            .protocol_id = "test-protocol",
            .profile = .{},
        },
    };
    var list = try modelsFromCatalog(allocator, .{ .entries = &entries }, "provider");
    list.deinit();
}

test "catalog model lists clean up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, createCatalogModelList, .{});
}

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

pub const Definition = struct {
    id: []const u8,
    name: []const u8,
    base_url: []const u8,
    headers: []const transport_api.Header = &.{},
    auth: auth_api.ProviderAuth,
};

pub const Configured = struct {
    transport: transport_api.Transport,
    protocols: protocol_api.Registry,
    catalog: model_catalog.Catalog,
    definition: Definition,
    auth_inputs: auth_api.Inputs,

    pub fn provider(self: *Configured) Provider {
        return Provider.from(self, self.definition.id);
    }

    pub fn model(self: *Configured, model_id: []const u8) ?model_api.Model {
        const resolved = self.catalog.resolve(.{
            .provider = self.definition.id,
            .model = model_id,
        }) orelse return null;
        _ = self.protocols.find(resolved.entry.protocol_id) orelse return null;
        return model_api.Model.from(self, resolved.entry.identity, resolved.entry.profile);
    }

    pub fn models(self: *Configured, allocator: std.mem.Allocator) ProviderError!OwnedModelList {
        return modelsFromCatalog(allocator, self.catalog, self.definition.id);
    }

    pub fn invoke(
        self: *Configured,
        result_allocator: std.mem.Allocator,
        scratch_allocator: std.mem.Allocator,
        io: std.Io,
        identity: message.ModelIdentity,
        request: model_api.ModelRequest,
        delivery: model_api.Delivery,
    ) model_api.ModelError!message.ResponseMessage {
        const entry = self.catalog.resolve(identity) orelse return error.InvalidRequest;
        const protocol = self.protocols.find(entry.entry.protocol_id) orelse return error.InvalidRequest;
        const resolved_auth = auth_api.resolve(
            self.definition.auth,
            self.definition.id,
            self.auth_inputs,
        ) catch return error.InvalidRequest;
        return protocol.invoke(result_allocator, scratch_allocator, io, .{
            .transport = self.transport,
            .base_url = resolved_auth.base_url orelse self.definition.base_url,
            .headers = self.definition.headers,
            .auth = resolved_auth,
        }, identity, request, delivery);
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
            _: message.ModelIdentity,
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

test "configured provider binds a non-OpenAI model through its protocol" {
    const StubProtocol = struct {
        const Self = @This();

        pub fn profile(_: *const Self, _: protocol_api.ProfileHints) settings.ModelProfile {
            return .{};
        }

        pub fn invoke(
            _: *const Self,
            result_allocator: std.mem.Allocator,
            _: std.mem.Allocator,
            _: std.Io,
            _: protocol_api.Invocation,
            identity: message.ModelIdentity,
            _: model_api.ModelRequest,
            _: model_api.Delivery,
        ) model_api.ModelError!message.ResponseMessage {
            return .{
                .identity = identity,
                .parts = result_allocator.alloc(message.ResponsePart, 0) catch return error.OutOfMemory,
            };
        }
    };
    const entries = [_]model_catalog.Entry{.{
        .identity = .{ .provider = "acme", .model = "reasoner" },
        .protocol_id = "acme-wire",
        .profile = .{},
    }};
    const implementation: StubProtocol = .{};
    const protocols = [_]protocol_api.Protocol{protocol_api.Protocol.from(&implementation, "acme-wire")};
    var fake = fake_transport.FakeTransport.init(&.{});
    var configured: Configured = .{
        .transport = fake.transport(),
        .protocols = try protocol_api.Registry.init(&protocols),
        .catalog = .{ .entries = &entries },
        .definition = .{
            .id = "acme",
            .name = "Acme",
            .base_url = "https://example.test",
            .auth = .{ .allow_unauthenticated = true },
        },
        .auth_inputs = .{},
    };

    var response = try configured.model("reasoner").?.complete(
        std.testing.allocator,
        std.testing.io,
        .{ .messages = &.{} },
    );
    defer response.deinit();
    try std.testing.expectEqualStrings("acme", response.value.identity.provider);
    try std.testing.expectEqualStrings("reasoner", response.value.identity.model);
}
