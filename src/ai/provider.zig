const std = @import("std");
const protocol = @import("protocol.zig");

pub const StreamEventSink = struct {
    /// Synchronous borrowed-event sink. Providers may call this only during stream execution.
    /// Receivers must copy data they retain after emit returns.
    func: *const fn (event: protocol.AssistantMessageEvent, ctx: ?*anyopaque) void,
    ctx: ?*anyopaque = null,

    pub fn emit(self: StreamEventSink, event: protocol.AssistantMessageEvent) void {
        self.func(event, self.ctx);
    }
};

pub const Provider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        stream: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            model: protocol.Model,
            context: protocol.Context,
            options: protocol.StreamOptions,
            sink: StreamEventSink,
        ) void,

        stream_simple: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            model: protocol.Model,
            context: protocol.Context,
            options: protocol.SimpleStreamOptions,
            sink: StreamEventSink,
        ) void,

        get_name: *const fn (ptr: *anyopaque) []const u8,

        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn stream(
        self: Provider,
        allocator: std.mem.Allocator,
        model: protocol.Model,
        context: protocol.Context,
        options: protocol.StreamOptions,
        sink: StreamEventSink,
    ) void {
        self.vtable.stream(self.ptr, allocator, model, context, options, sink);
    }

    pub fn streamSimple(
        self: Provider,
        allocator: std.mem.Allocator,
        model: protocol.Model,
        context: protocol.Context,
        options: protocol.SimpleStreamOptions,
        sink: StreamEventSink,
    ) void {
        self.vtable.stream_simple(self.ptr, allocator, model, context, options, sink);
    }

    pub fn getName(self: Provider) []const u8 {
        return self.vtable.get_name(self.ptr);
    }

    pub fn deinit(self: Provider) void {
        self.vtable.deinit(self.ptr);
    }
};

pub const registry = @import("provider_registry.zig");
pub const ClaimModelRegistration = registry.ClaimModelRegistration;
pub const ClaimRegistration = registry.ClaimRegistration;
pub const Registry = registry.Registry;
