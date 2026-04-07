const std = @import("std");
const registries = @import("registries/root.zig");
const lua_runtime = @import("lua_runtime.zig");

/// Monotonic generation counter. Each reload creates a new generation.
/// 
/// Why: Extensions may cache pointers or references into the runner (e.g., tool
/// registries, handler lists). When a reload occurs, the old runner is destroyed
/// and a new one created with a higher generation number. Consumers that cache
/// such pointers MUST check the generation to detect invalidation — this avoids
/// use-after-free without requiring every consumer to subscribe to a lifecycle
/// event. The generation is u64 to ensure monotonicity even across very long
/// sessions (practically infinite).
pub const Generation = u64;

/// Two-phase runtime lifecycle: stub → bound.
/// 
/// Extensions register during the "load" phase, where action methods like
/// send_message would fail. The runtime starts as `.stub` and transitions to
/// `.bound` only after AgentSession is fully constructed and can provide the
/// concrete implementations. This prevents extensions from calling into
/// session-dependent APIs during registration, when session state is incomplete.
/// 
/// The `.bound` variant carries opaque pointers (`*anyopaque`) to avoid circular
/// imports in D1. Real types (AgentSession, ExtensionUIContext, etc.) get wired
/// in later phases once the module dependency graph stabilizes.
/// 
/// ExtensionCommandContext seam exists from day one (per the spec's v2
/// preparation), but v1 leaves `command_actions` null. This preserves the
/// bind-time contract without requiring D2 refactors.
pub const ExtensionRuntime = union(enum) {
    stub: void,
    bound: Bound,

    pub const Bound = struct {
        /// Opaque pointer to AgentSession — avoids circular import in D1.
        /// Phase B+ casts this to *AgentSession when invoking session-control
        /// actions from command handlers.
        session: *anyopaque,

        /// Optional UI context pointer — null in print/json modes, non-null in
        /// interactive mode. Cast to *ExtensionUIContext in later phases.
        ui: ?*anyopaque = null,

        /// Command-context actions — null in v1, populated in v2 when commands
        /// are registered. Provides session control methods (new_session,
        /// fork, navigate_tree, etc.) that are only safe in user-initiated
        /// slash commands, not during autonomous tool execution.
        command_actions: ?*anyopaque = null,
    };
};

/// ExtensionRunner — owned by AgentSession. One per generation.
///
/// The runner encapsulates all extension state for a single "generation" of the
/// extension system. Each /reload creates a fresh runner (new generation),
/// re-discovers extensions from disk, and re-loads them into a fresh Lua state.
/// The old runner is destroyed only after the new one is bound and active,
/// ensuring atomic swap semantics.
///
/// D1 scaffold only. Registries, Lua state, and event dispatch come in later
/// phases. The struct shape is intentionally minimal to let D1 land
/// independently while preserving the generation and runtime-bind contracts.
/// Forward-declared runner cell — the "`ref: { current?: ExtensionRunner }`"
/// pattern from pi-mono (sdk.ts:294). Exists to break a chicken-and-egg
/// problem:
///
///   1. The `Agent` is constructed with `stream_fn`, `transform_context`,
///      and `on_payload` closures that need to CALL INTO the runner.
///   2. The runner, in turn, needs a live `AgentSession` (which owns
///      the `Agent`) to flush its provider queue, bind ctx.ui, and
///      emit `session_start`.
///
/// Without this cell, neither can be constructed first. With it,
/// `sdk.createAgentSession` allocates an empty `ExtensionRunnerRef`
/// up front, wires Agent closures against it, builds the session,
/// builds the runner, and finally writes `ref.current = runner`.
/// Closures that fire before that last step see `.current == null`
/// and no-op gracefully (there are no extensions registered yet —
/// the runner's own construction phase must not depend on itself).
///
/// Reload uses the same cell: the slot is re-assigned to the new
/// generation atomically. Closures never re-capture a pointer — they
/// dereference `ref.current` on every call. This is what makes a
/// tool ctx wrapper from generation N safe to drop the moment the
/// active slice swaps to generation N+1.
pub const ExtensionRunnerRef = struct {
    current: ?*ExtensionRunner = null,
};

pub const ExtensionRunner = struct {
    allocator: std.mem.Allocator,

    /// Monotonic generation identifier. Never reused across reloads.
    generation: Generation,

    /// Runtime state — starts as stub, transitions to bound once.
    runtime: ExtensionRuntime,

    /// Tool registry — maps tool name → ExtensionTool. First-
    /// registered-wins; populated during load, consumed by
    /// AgentSession to build the active tool list. Owns every
    /// entry's strings and JSON schema for the runner generation.
    tool_registry: registries.ToolRegistry,

    /// Event registry — maps EventKind → ordered handler chain.
    /// D2 stores subscriptions; D4 implements dispatch on top.
    /// Handler `lua_ref` values are released when the Lua state is
    /// closed during runner deinit, not per-entry here.
    event_registry: registries.EventRegistry,

    /// Command registry — slash commands. v1 leaves this empty
    /// (commands are v2) but the slot exists so the bind seam
    /// (`ExtensionRuntime.Bound.command_actions`) has a target.
    command_registry: registries.CommandRegistry,

    /// Provider queue — pending custom-provider registrations that
    /// arrived during the pre-bind load phase. Drained by
    /// `bindRuntime` (D7) into the AI provider registry. v1 leaves
    /// this empty; v2 wires `zi.register_provider`.
    provider_queue: registries.ProviderQueue,

    /// Lua state for this generation. Borrowed (NOT owned) — the
    /// state is constructed and owned by the SDK factory or the
    /// test scaffold, and passed in via `attachLuaState`. The runner
    /// uses it to dispatch Lua handlers from the agent's event
    /// stream and to host the `zi.*` API table.
    ///
    /// Why borrowed instead of owned: the state's lifetime is tied
    /// to the SDK bootstrap order — it must outlive any in-flight
    /// agent stream that may be holding a coroutine reference. The
    /// SDK owns it; the runner just dispatches against it.
    ///
    /// Null until `attachLuaState` is called. The dispatch helpers
    /// in `event_bridge.zig` no-op when the state is missing, so
    /// pre-bind registrations don't crash and runner-without-state
    /// instances stay valid (they just can't dispatch).
    lua_state: ?*lua_runtime.LuaState = null,

    // Future fields documented as comments so the runner shape is
    // visible without compiling unused state:
    //
    //   flag_values: std.StringHashMap(FlagValue) = .empty,  — v2

    pub fn init(allocator: std.mem.Allocator, generation: Generation) ExtensionRunner {
        return .{
            .allocator = allocator,
            .generation = generation,
            .runtime = .{ .stub = {} },
            .tool_registry = registries.ToolRegistry.init(allocator),
            .event_registry = registries.EventRegistry.init(allocator),
            .command_registry = registries.CommandRegistry.init(allocator),
            .provider_queue = registries.ProviderQueue.init(allocator),
        };
    }

    /// Attach a borrowed Lua state. Called by the SDK factory once
    /// it has constructed the LuaState and installed the `zi.*` API
    /// table; the runner uses the state for handler dispatch but
    /// does NOT own its lifetime. Caller must keep the state alive
    /// for the runner's full lifetime.
    pub fn attachLuaState(self: *ExtensionRunner, state: *lua_runtime.LuaState) void {
        self.lua_state = state;
    }

    pub fn deinit(self: *ExtensionRunner) void {
        // Tear down in REVERSE construction order. The provider
        // queue holds Lua registry refs that the lua_state (when
        // we add it) will collect on close — destroying registries
        // first then closing the state is correct because the refs
        // are integers, not pointers, so order doesn't matter for
        // memory safety. Order matters only when v2 adds tool ctx
        // wrappers that hold zig pointers into runner state; D9
        // will revisit this.
        self.provider_queue.deinit();
        self.command_registry.deinit();
        self.event_registry.deinit();
        self.tool_registry.deinit();
    }

    /// Swap the runtime from stub to bound. Idempotent guard: errors if
    /// already bound to prevent accidental double-binding.
    ///
    /// Called by AgentSession after construction, once all dependencies
    /// (session store, agent core, optional UI) are available. The bound
    /// pointers are opaque to avoid circular module dependencies; later
    /// phases cast them to concrete types at use sites.
    pub fn bindRuntime(self: *ExtensionRunner, bound: ExtensionRuntime.Bound) !void {
        if (self.runtime != .stub) return error.AlreadyBound;
        self.runtime = .{ .bound = bound };
    }

    pub fn isBound(self: *const ExtensionRunner) bool {
        return self.runtime == .bound;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "ExtensionRunner starts in stub state" {
    const allocator = std.testing.allocator;
    var runner = ExtensionRunner.init(allocator, 0);
    defer runner.deinit();

    try std.testing.expect(!runner.isBound());
    try std.testing.expect(runner.generation == 0);
}

test "bindRuntime rejects double-bind" {
    const allocator = std.testing.allocator;
    var runner = ExtensionRunner.init(allocator, 1);
    defer runner.deinit();

    // First bind should succeed
    var dummy: u8 = 0;
    const ptr: *anyopaque = @ptrCast(&dummy);
    const bound = ExtensionRuntime.Bound{
        .session = ptr,
        .ui = null,
        .command_actions = null,
    };

    try runner.bindRuntime(bound);
    try std.testing.expect(runner.isBound());

    // Second bind should fail
    var dummy2: u8 = 0;
    const ptr2: *anyopaque = @ptrCast(&dummy2);
    const bound2 = ExtensionRuntime.Bound{
        .session = ptr2,
        .ui = null,
        .command_actions = null,
    };

    const result = runner.bindRuntime(bound2);
    try std.testing.expectError(error.AlreadyBound, result);
}

test "ExtensionRunner owns four empty registries on init" {
    const allocator = std.testing.allocator;
    var runner = ExtensionRunner.init(allocator, 2);
    defer runner.deinit();

    try std.testing.expectEqual(@as(usize, 0), runner.tool_registry.count());
    try std.testing.expectEqual(@as(usize, 0), runner.event_registry.count());
    try std.testing.expectEqual(@as(usize, 0), runner.command_registry.count());
    try std.testing.expectEqual(@as(usize, 0), runner.provider_queue.count());
}

test "ExtensionRunner registries survive populated deinit" {
    const allocator = std.testing.allocator;
    var runner = ExtensionRunner.init(allocator, 3);
    defer runner.deinit();

    // Tool: ownership transferred to registry on accept.
    const params = std.json.Value{ .object = std.json.ObjectMap.init(allocator) };
    const accepted = try runner.tool_registry.register(.{
        .name = try allocator.dupe(u8, "task"),
        .label = try allocator.dupe(u8, "Task"),
        .description = try allocator.dupe(u8, "spawn a sub-agent"),
        .parameters = params,
        .impl = .{ .lua = 7 },
        .source = .{ .kind = "user", .id = "task.lua" },
    });
    try std.testing.expect(accepted);

    // Event: pure append.
    try runner.event_registry.subscribe(.tool_call, .{ .lua_ref = 8, .source_id = "task.lua" });

    // Provider queue: pre-bind enqueue, never drained in this test.
    try runner.provider_queue.enqueue(.{
        .api = try allocator.dupe(u8, "anthropic-messages"),
        .config_ref = 9,
        .source = .{ .kind = "user", .id = "task.lua" },
    });

    try std.testing.expectEqual(@as(usize, 1), runner.tool_registry.count());
    try std.testing.expectEqual(@as(usize, 1), runner.event_registry.count());
    try std.testing.expectEqual(@as(usize, 1), runner.provider_queue.count());
    // deinit (via defer) frees everything; testing.allocator catches leaks.
}
