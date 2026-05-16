const std = @import("std");
const resource_types = @import("../../resources/types.zig");

pub const EventKind = enum {
    session_directory,
    resources_discover,

    agent_start,
    agent_end,
    before_agent_start,
    input,
    context,
    before_provider_request,
    turn_start,
    turn_end,
    message_start,
    message_update,
    message_end,
    message,

    tool_execution_start,
    tool_execution_update,
    tool_execution_end,
    tool_call,
    tool_result,
    user_bash,

    session_start,
    session_shutdown,
    session_before_switch,
    session_before_fork,
    session_before_compact,
    session_compact,
    session_before_tree,
    session_tree,

    job_stdout,
    job_stderr,
    job_output_dropped,
    job_exit,
    job_ready,
    job_json,

    model_select,
    ui,

    pub fn semantics(self: EventKind) Semantics {
        return switch (self) {
            .session_directory,
            .resources_discover,
            .before_agent_start,
            => .aggregate,

            .input,
            .tool_call,
            => .middleware_cancellable,

            .context,
            .before_provider_request,
            .tool_result,
            => .middleware,

            .user_bash,
            .session_before_fork,
            .session_before_compact,
            .session_before_tree,
            => .cancellable_aggregate,

            .session_before_switch => .cancellable,

            else => .observer,
        };
    }
};

pub const Semantics = enum {
    observer,
    cancellable,
    transformable,
    aggregate,
    middleware,
    middleware_cancellable,
    cancellable_aggregate,
};

pub const EventHandler = struct {
    lua_ref: c_int,

    source_id: []const u8,
    provenance: ?resource_types.ExtensionProvenance = null,
};

pub const EventRegistry = struct {
    allocator: std.mem.Allocator,
    chains: [event_count]std.ArrayListUnmanaged(EventHandler) = @splat(.empty),

    const event_count = @typeInfo(EventKind).@"enum".fields.len;

    pub fn init(allocator: std.mem.Allocator) EventRegistry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *EventRegistry) void {
        for (&self.chains) |*chain| {
            chain.deinit(self.allocator);
        }
    }

    pub fn subscribe(self: *EventRegistry, kind: EventKind, handler: EventHandler) !void {
        try self.chains[@intFromEnum(kind)].append(self.allocator, handler);
    }

    pub fn handlers(self: *const EventRegistry, kind: EventKind) []const EventHandler {
        return self.chains[@intFromEnum(kind)].items;
    }

    pub fn count(self: *const EventRegistry) usize {
        var total: usize = 0;
        for (&self.chains) |chain| total += chain.items.len;
        return total;
    }
};

const testing = std.testing;

test "EventRegistry subscribes in order and dispatches correct chain" {
    var reg = EventRegistry.init(testing.allocator);
    defer reg.deinit();

    try reg.subscribe(.tool_call, .{ .lua_ref = 10, .source_id = "ext-a" });
    try reg.subscribe(.tool_call, .{ .lua_ref = 11, .source_id = "ext-b" });
    try reg.subscribe(.message_end, .{ .lua_ref = 20, .source_id = "ext-c" });

    try testing.expectEqual(@as(usize, 3), reg.count());

    const tc = reg.handlers(.tool_call);
    try testing.expectEqual(@as(usize, 2), tc.len);
    try testing.expectEqual(@as(c_int, 10), tc[0].lua_ref);
    try testing.expectEqual(@as(c_int, 11), tc[1].lua_ref);

    const me = reg.handlers(.message_end);
    try testing.expectEqual(@as(usize, 1), me.len);
    try testing.expectEqualStrings("ext-c", me[0].source_id);
}

test "EventKind.semantics matches spec" {
    try testing.expectEqual(Semantics.aggregate, EventKind.resources_discover.semantics());
    try testing.expectEqual(Semantics.middleware_cancellable, EventKind.tool_call.semantics());
    try testing.expectEqual(Semantics.middleware, EventKind.tool_result.semantics());
    try testing.expectEqual(Semantics.middleware, EventKind.before_provider_request.semantics());
    try testing.expectEqual(Semantics.observer, EventKind.message_end.semantics());
    try testing.expectEqual(Semantics.cancellable, EventKind.session_before_switch.semantics());
    try testing.expectEqual(Semantics.cancellable_aggregate, EventKind.session_before_fork.semantics());
    try testing.expectEqual(Semantics.cancellable_aggregate, EventKind.session_before_compact.semantics());
    try testing.expectEqual(Semantics.observer, EventKind.session_compact.semantics());
    try testing.expectEqual(Semantics.observer, EventKind.session_start.semantics());
}
