const std = @import("std");
const ModelMeta = @import("ModelMeta.zig");
const Provider = @import("Provider.zig");

pub const maximum_models: usize = 4_096;
pub const maximum_id_bytes: usize = 1_024;
pub const maximum_description_bytes: usize = 16 * 1024;
pub const maximum_failure_bytes: usize = 16 * 1024;

pub const Error = error{ OutOfMemory, Cancelled, InvalidRequest };

pub const Model = struct {
    id: []const u8,
    description: ?[]const u8 = null,
    metadata: ModelMeta.Metadata = .{},
};

/// Heap-stable bulk owner for one listing result. Values returned by its
/// methods remain valid until the containing outcome or list is deinitialized.
pub const Owner = struct {
    backing_allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!*Owner {
        const owner = try allocator.create(Owner);
        owner.* = .{
            .backing_allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
        return owner;
    }

    pub fn destroy(self: *Owner) void {
        const allocator = self.backing_allocator;
        self.arena.deinit();
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn arenaAllocator(self: *Owner) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn ownId(self: *Owner, id: []const u8) error{ OutOfMemory, InvalidRequest }![]const u8 {
        if (id.len == 0 or id.len > maximum_id_bytes) return error.InvalidRequest;
        return self.arena.allocator().dupe(u8, id);
    }

    pub fn ownDescription(
        self: *Owner,
        description: []const u8,
    ) error{ OutOfMemory, InvalidRequest }![]const u8 {
        if (description.len == 0 or description.len > maximum_description_bytes) {
            return error.InvalidRequest;
        }
        return self.arena.allocator().dupe(u8, description);
    }

    pub fn finish(self: *Owner, models: []const Model) error{ OutOfMemory, InvalidRequest }!OwnedList {
        if (models.len > maximum_models) return error.InvalidRequest;
        const owned = try self.arena.allocator().alloc(Model, models.len);
        for (models, owned) |model, *destination| {
            destination.* = .{
                .id = try self.ownId(model.id),
                .description = if (model.description) |description|
                    try self.ownDescription(description)
                else
                    null,
                .metadata = model.metadata,
            };
        }
        return .{ .owner = self, .models = owned };
    }

    fn finishFailure(self: *Owner, message: []const u8) Error!Outcome {
        if (message.len == 0 or message.len > maximum_failure_bytes) return error.InvalidRequest;
        const owned = try self.arena.allocator().dupe(u8, message);
        return .{ .failure = .{ .owner = self, .message = owned } };
    }
};

/// Move-only handle. Copying it would make both copies own the same arena.
pub const OwnedList = struct {
    owner: *Owner,
    models: []const Model,

    pub fn deinit(self: *OwnedList) void {
        self.owner.destroy();
        self.* = undefined;
    }
};

pub const OwnedFailure = struct {
    owner: *Owner,
    message: []const u8,

    pub fn deinit(self: *OwnedFailure) void {
        self.owner.destroy();
        self.* = undefined;
    }
};

pub const Outcome = union(enum) {
    unsupported,
    failure: OwnedFailure,
    models: OwnedList,

    pub fn deinit(self: *Outcome) void {
        switch (self.*) {
            .unsupported => {},
            .failure => |*owned| owned.deinit(),
            .models => |*models| models.deinit(),
        }
        self.* = undefined;
    }
};

pub fn failure(allocator: std.mem.Allocator, message: []const u8) Error!Outcome {
    const owner = try Owner.init(allocator);
    errdefer owner.destroy();
    return owner.finishFailure(message);
}

/// Erased synchronous model-list source. Callback arguments put the allocator
/// first so implementations cannot hide result ownership in their context.
pub const Source = struct {
    context: *anyopaque,
    list_fn: *const fn (
        std.mem.Allocator,
        std.Io,
        *anyopaque,
        ?Provider.Tick,
    ) Error!Outcome,

    pub fn from(pointer: anytype) Source {
        const Pointer = @TypeOf(pointer);
        const info = @typeInfo(Pointer);
        if (info != .pointer or info.pointer.size != .one or info.pointer.is_const) {
            @compileError("ModelListing.Source requires a mutable single-item pointer");
        }
        const Child = info.pointer.child;
        return .{
            .context = @ptrCast(pointer),
            .list_fn = struct {
                fn call(
                    allocator: std.mem.Allocator,
                    io: std.Io,
                    context: *anyopaque,
                    tick: ?Provider.Tick,
                ) Error!Outcome {
                    const self: Pointer = @ptrCast(@alignCast(context));
                    return Child.listModels(self, allocator, io, tick);
                }
            }.call,
        };
    }

    pub fn listModels(
        self: Source,
        allocator: std.mem.Allocator,
        io: std.Io,
        tick: ?Provider.Tick,
    ) Error!Outcome {
        return self.list_fn(allocator, io, self.context, tick);
    }
};

fn exerciseOwner(allocator: std.mem.Allocator) !void {
    const owner = try Owner.init(allocator);
    errdefer owner.destroy();
    const id = try owner.ownId("model");
    const description = try owner.ownDescription("description");
    var list = try owner.finish(&.{.{ .id = id, .description = description }});
    list.deinit();
}

test "owner keeps models stable and releases all allocations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseOwner, .{});
}

test "owner enforces common listing bounds" {
    const owner = try Owner.init(std.testing.allocator);
    defer owner.destroy();
    try std.testing.expectError(error.InvalidRequest, owner.ownId(""));
    try std.testing.expectError(
        error.InvalidRequest,
        owner.ownDescription("x" ** (maximum_description_bytes + 1)),
    );
}

test "owned failure has one bounded lifetime" {
    var outcome = try failure(std.testing.allocator, "catalog unavailable");
    try std.testing.expectEqualStrings("catalog unavailable", outcome.failure.message);
    outcome.deinit();
}

test "source preserves callback errors" {
    const TestSource = struct {
        const Self = @This();

        fn listModels(
            _: *Self,
            _: std.mem.Allocator,
            _: std.Io,
            _: ?Provider.Tick,
        ) Error!Outcome {
            return error.Cancelled;
        }
    };
    var implementation: TestSource = .{};
    const source = Source.from(&implementation);
    try std.testing.expectError(
        error.Cancelled,
        source.listModels(std.testing.allocator, std.testing.io, null),
    );
}
