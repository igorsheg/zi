const std = @import("std");

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
pub const ExtensionRunner = struct {
    allocator: std.mem.Allocator,

    /// Monotonic generation identifier. Never reused across reloads.
    generation: Generation,

    /// Runtime state — starts as stub, transitions to bound once.
    runtime: ExtensionRuntime,

    // Placeholder fields for later phases — kept as comments to document
    // the eventual shape without blocking D1 compilation:
    //
    // /// Lua 5.4 state owned by this runner. All extensions for this generation
    // /// share this state. Closed on deinit.
    // lua_state: ?*anyopaque = null,  // D2/Phase B
    //
    // /// Tool registry — maps tool name → ExtensionTool (builtin or lua).
    // /// First-registered-wins semantics. Populated during load, consumed
    // /// by AgentSession to build the active tool list.
    // tool_registry: ToolRegistry = .empty,  // D2
    //
    // /// Event registry — maps event type → list of handler references.
    // /// Used by dispatch() to fan out events to subscribed extensions.
    // event_registry: EventRegistry = .empty,  // D2
    //
    // /// Command registry — slash commands registered by extensions.
    // /// v2 feature, but the registry slot exists for bind-time wiring.
    // command_registry: CommandRegistry = .empty,  // D2
    //
    // /// Provider queue — registrations that arrived pre-bind are queued
    // /// and flushed into ModelRegistry during bindRuntime().
    // provider_queue: std.ArrayList(ProviderRegistration) = .empty,  // D2
    //
    // /// Flag values storage — populated by setFlagValue(), queried by
    // /// extensions via zi.get_flag(). Persists for the generation lifetime.
    // flag_values: std.StringHashMap(FlagValue) = .empty,  // D2+

    pub fn init(allocator: std.mem.Allocator, generation: Generation) ExtensionRunner {
        return .{
            .allocator = allocator,
            .generation = generation,
            .runtime = .{ .stub = {} },
        };
    }

    pub fn deinit(self: *ExtensionRunner) void {
        // D1: nothing to free yet. Later phases add:
        //   - close lua_state (lua_close)
        //   - free all registry entries (tool, event, command)
        //   - free handler refs (luaL_unref)
        //   - free schema JSON values (std.json.Value deep copies)
        //   - free tool ctx wrappers (owned by runner, referenced by AgentTool)
        _ = self;
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
