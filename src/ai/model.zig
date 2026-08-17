const std = @import("std");
const failure = @import("failure.zig");
const message = @import("message.zig");
const settings = @import("settings.zig");
const stream_api = @import("stream.zig");

pub const ModelError = failure.ModelError;
pub const ModelIdentity = message.ModelIdentity;
pub const ModelProfile = settings.ModelProfile;
pub const ModelRequest = struct {
    messages: []const message.Message,
    instructions: []const []const u8 = &.{},
    tools: []const message.ToolDefinition = &.{},
    settings: settings.ModelSettings = .{},
    handoff: HandoffPolicy = .drop_foreign_state,
    deadline: ?std.Io.Clock.Timestamp = null,
    cancellation: ?*const CancellationToken = null,
    failure_sink: ?failure.FailureSink = null,

    pub fn validateHandoff(
        self: ModelRequest,
        provider_id: []const u8,
        protocol_id: ?[]const u8,
    ) ModelError!void {
        if (self.handoff == .drop_foreign_state) return;
        for (self.messages) |entry| switch (entry) {
            .request => {},
            .response => |response| for (response.parts) |part| {
                const state = switch (part) {
                    .text => |text| text.provider_state,
                    .thinking => |thinking| thinking.provider_state,
                    .tool_call => |tool_call| tool_call.provider_state,
                } orelse continue;
                if (!std.mem.eql(u8, state.provider, provider_id)) return error.HandoffRejected;
                const accepted = protocol_id orelse return error.HandoffRejected;
                if (!std.mem.eql(u8, state.protocol, accepted)) return error.HandoffRejected;
            },
        };
    }
};

pub const HandoffPolicy = enum {
    reject_foreign_state,
    drop_foreign_state,
};

pub const CancellationToken = struct {
    value: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn cancel(self: *CancellationToken) void {
        self.value.store(true, .release);
    }

    pub fn isCancelled(self: *const CancellationToken) bool {
        return self.value.load(.acquire);
    }
};

pub const Delivery = union(enum) {
    buffered,
    streaming: stream_api.StreamSink,
};

pub const OwnedResponse = struct {
    arena: std.heap.ArenaAllocator,
    value: message.ResponseMessage,

    pub fn deinit(self: *OwnedResponse) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Model = struct {
    context: *anyopaque,
    vtable: *const VTable,
    identity: ModelIdentity,
    profile: ModelProfile,

    pub const VTable = struct {
        invoke: *const fn (
            context: *anyopaque,
            result_allocator: std.mem.Allocator,
            scratch_allocator: std.mem.Allocator,
            io: std.Io,
            request: ModelRequest,
            delivery: Delivery,
        ) ModelError!message.ResponseMessage,
    };

    pub fn from(implementation: anytype, identity: ModelIdentity, profile: ModelProfile) Model {
        const Implementation = @TypeOf(implementation.*);
        const VTableImpl = struct {
            // Context leads because this adapter implements the erased model ABI.
            // ziglint-ignore: Z023
            fn invokeImpl(
                context: *anyopaque,
                result_allocator: std.mem.Allocator, // ziglint-ignore: Z023
                scratch_allocator: std.mem.Allocator, // ziglint-ignore: Z023
                io: std.Io, // ziglint-ignore: Z023
                request: ModelRequest,
                delivery: Delivery,
            ) ModelError!message.ResponseMessage {
                const instance: *Implementation = @ptrCast(@alignCast(context));
                return instance.invoke(result_allocator, scratch_allocator, io, request, delivery);
            }
            const vtable: VTable = .{ .invoke = invokeImpl };
        };
        return .{
            .context = implementation,
            .vtable = &VTableImpl.vtable,
            .identity = identity,
            .profile = profile,
        };
    }

    pub fn complete(
        self: Model,
        allocator: std.mem.Allocator,
        io: std.Io,
        request: ModelRequest,
    ) ModelError!OwnedResponse {
        return self.invoke(allocator, io, request, .buffered);
    }

    pub fn stream(
        self: Model,
        allocator: std.mem.Allocator,
        io: std.Io,
        request: ModelRequest,
        sink: stream_api.StreamSink,
    ) ModelError!OwnedResponse {
        return self.invoke(allocator, io, request, .{ .streaming = sink });
    }

    fn invoke(
        self: Model,
        allocator: std.mem.Allocator,
        io: std.Io,
        request: ModelRequest,
        delivery: Delivery,
    ) ModelError!OwnedResponse {
        if (self.identity.provider.len == 0 or self.identity.model.len == 0) return error.InvalidRequest;
        try request.settings.validate(self.profile);
        if (request.tools.len > 0 and !self.profile.supports(.tools)) return error.UnsupportedCapability;
        if (request.cancellation) |token| if (token.isCancelled()) return error.Cancelled;
        if (request.deadline) |deadline| {
            const now = std.Io.Clock.Timestamp.now(io, deadline.clock);
            if (now.durationTo(deadline).raw.nanoseconds <= 0) return error.TimedOut;
        }
        if (delivery == .streaming and !self.profile.supports(.streaming)) return error.UnsupportedCapability;

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        var value = try self.vtable.invoke(
            self.context,
            arena.allocator(),
            allocator,
            io,
            request,
            delivery,
        );
        value.identity = .{
            .provider = try arena.allocator().dupe(u8, self.identity.provider),
            .model = try arena.allocator().dupe(u8, self.identity.model),
        };
        return .{ .arena = arena, .value = value };
    }
};
