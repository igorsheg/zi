//! Event registry — event kind → ordered list of handlers.
//!
//! Owned by `ExtensionRunner`. Unlike `tool_registry`, this is NOT
//! first-registered-wins: every subscription is appended, and dispatch
//! walks the full chain in registration order. The chain semantics
//! depend on the event kind:
//!
//!   - **observer**: every handler runs, return values ignored.
//!     (most lifecycle events: agent_start, message_end, ...)
//!   - **cancellable**: handlers run in order; the first that returns
//!     `block = true` stops the chain. Mutations from earlier handlers
//!     are visible to later ones.
//!   - **transformable** / **middleware** / **aggregate** variants are reserved
//!     for v2 event classes whose concrete dispatch points land incrementally.
//!     The registry stores their handlers now so API shape stays stable.
//!
//! D2 only stores the handlers — actual dispatch lives in D4. The
//! semantics tag is recorded on the EventKind so the dispatcher can
//! pick the right loop without a per-event switch.

const std = @import("std");
const resource_types = @import("../../resources/types.zig");

/// Every extension event the runner knows about. v1 covers lifecycle,
/// tool, session_start/shutdown, and model_select. v2 events get added
/// here as their dispatch points come online — the registry's storage
/// shape is generic over EventKind, so growth is mechanical.
///
/// Order in this enum is NOT semantic; treat it as a tag set.
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
    job_exit,
    job_json,

    model_select,
    ui,

    /// Dispatch semantics for this kind. Used by D4's dispatcher to
    /// pick a chain implementation. Hard-coded here so the registry
    /// is the single source of truth — extensions cannot override
    /// the semantics of an existing event.
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

/// One subscription. The handler reference is opaque to the registry —
/// concrete dispatch (D4) interprets it. For Lua handlers it's a
/// `c_int` from `luaL_ref` against the runner's Lua state. For
/// internal zig hooks it's a function-pointer index; we'll grow the
/// union shape when D4 needs it.
pub const EventHandler = struct {
    /// Lua registry ref produced by `luaL_ref`. The runner closes it
    /// during deinit so the Lua GC can collect the closure.
    lua_ref: c_int,
    /// Provenance — extension file path or builtin name. Borrowed.
    source_id: []const u8,
    provenance: ?resource_types.ExtensionProvenance = null,
};

/// Map from EventKind to its handler chain.
///
/// Storage is a fixed-size array indexed by enum tag. Faster than a
/// hash map and lets us preallocate the slot array on init. The cost
/// is that adding a new EventKind requires growing the array — which
/// the compiler enforces via `@typeInfo(EventKind).@"enum".fields.len`.
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

    /// Append a handler to the chain for `kind`. Always succeeds
    /// (modulo allocator OOM) — there is no first-wins semantic for
    /// events; observers are additive by design.
    pub fn subscribe(self: *EventRegistry, kind: EventKind, handler: EventHandler) !void {
        try self.chains[@intFromEnum(kind)].append(self.allocator, handler);
    }

    /// Read-only view of the handler chain for `kind`. The slice is
    /// stable until the next `subscribe` call for the same kind (the
    /// underlying ArrayList may reallocate). Dispatch (D4) is
    /// expected to walk the chain synchronously without intervening
    /// mutations.
    pub fn handlers(self: *const EventRegistry, kind: EventKind) []const EventHandler {
        return self.chains[@intFromEnum(kind)].items;
    }

    /// Total subscriptions across every chain. Diagnostic only.
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

test "EventKind reserves the v3 event surface" {
    try testing.expectEqual(@as(usize, 34), @typeInfo(EventKind).@"enum".fields.len);
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
