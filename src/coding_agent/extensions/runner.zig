const std = @import("std");
const registries = @import("registries/root.zig");
const lua_runtime = @import("lua_runtime.zig");
const abort_signal = @import("../../abort_signal.zig");
const agent_protocol = @import("../../agent3/types.zig");
const session_mod = @import("../session/root.zig");

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
        session: *anyopaque,
        ui: ?*anyopaque = null,
        command_actions: ?*anyopaque = null,

        /// Context action seams used by tool/event `ctx.*` helpers.
        /// Stored as function pointers here so extension modules can call
        /// through them without importing `coding_agent.zig` and creating
        /// a cycle.
        get_model: *const fn (session: *anyopaque) agent_protocol.Model,
        is_idle: *const fn (session: *anyopaque) bool,
        abort: *const fn (session: *anyopaque) void,
        has_pending_messages: *const fn (session: *anyopaque) bool,
        shutdown: ?*const fn (session: *anyopaque) void = null,
        get_context_usage: *const fn (session: *anyopaque) ?session_mod.context_usage.ContextUsage,
        get_system_prompt: *const fn (session: *anyopaque) []const u8,
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

pub const SpawnRequest = struct {
    task: []const u8,
    model: ?[]const u8 = null,
    tools: ?[]const u8 = null,
    append_system_prompt: ?[]const u8 = null,
    cwd: []const u8,
    callbacks_ref: c_int = lua_runtime.c.LUA_NOREF,
    source_L: *lua_runtime.c.lua_State,
    continuation_ctx: lua_runtime.c.lua_KContext = 0,

    pub fn deinit(self: *SpawnRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.task);
        if (self.model) |v| allocator.free(v);
        if (self.tools) |v| allocator.free(v);
        if (self.append_system_prompt) |v| allocator.free(v);
        allocator.free(self.cwd);
        self.* = undefined;
    }
};

pub const SpawnOutcome = struct {
    result: agent_protocol.AgentToolResult,
};

pub const ExtensionLoadSource = struct {
    kind: []const u8,
    id: []const u8,
    path: []const u8,
};

pub const LoadContext = struct {
    source: ExtensionLoadSource,
};

pub const ExtensionRunner = struct {
    allocator: std.mem.Allocator,

    /// Monotonic generation identifier. Never reused across reloads.
    generation: Generation,

    /// Runtime state — starts as stub, transitions to bound once.
    runtime: ExtensionRuntime,

    /// Tool registry — maps tool name → ToolDefinition. First-
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

    /// Abort signal for the currently executing Lua tool. Set by
    /// `lua_tool.execute` before invoking the user's handler and
    /// cleared on return. Read by host functions like `zi.spawn`
    /// that need to forward the parent's abort into a child
    /// subprocess.
    ///
    /// Single-threaded contract: the Lua state runs one coroutine
    /// at a time, so a single mutable slot is safe without locking.
    /// If concurrent tools ever land, this becomes per-coroutine
    /// state.
    ///
    /// Null when no Lua tool is running. `zi.spawn` callers from
    /// non-tool contexts (e.g. an event handler that wants to
    /// fan out a sub-agent) will see no abort forwarding — the
    /// child runs uninterruptible from the parent's POV.
    current_signal: ?abort_signal.AbortSignal = null,

    /// Update callback + ctx for the currently executing Lua tool.
    /// Set by `lua_tool.execute` before invoking the user's
    /// handler so the Lua-callable `ctx.update(partial)` host
    /// function can forward partial results back through the
    /// agent loop's update bridge.
    ///
    /// Lifetime + thread contract is identical to `current_signal`:
    /// single-threaded slot, valid for the duration of one tool
    /// execution, cleared on return.
    current_update_callback: ?agent_protocol.AgentToolUpdateCallback = null,
    current_update_ctx: ?*anyopaque = null,

    /// Working directory of the parent agent. Surfaced to Lua tools
    /// via `ctx.cwd` so they can spawn child processes in the
    /// right directory and resolve relative paths. Set once at
    /// session bootstrap; static for the runner generation.
    cwd: []const u8 = ".",

    /// Minimal scheduler state for one in-flight yieldable host call.
    ///
    /// Phase zi-0br / smallest zi-5w4 slice: only Lua tool execution may
    /// suspend, and only via `zi.spawn`. Event handlers and spawn `on={...}`
    /// callbacks still run non-yieldably. Because the agent thread is the sole
    /// owner of `lua_state` and drives exactly one coroutine at a time, runner-
    /// scoped state is enough for now. Later scheduler work (`zi-ilc`) can grow
    /// this into a richer per-coroutine task table without changing the tool
    /// execution contract landed here.
    current_spawn_request: ?SpawnRequest = null,
    current_spawn_result: ?SpawnOutcome = null,

    load_context: ?LoadContext = null,

    /// Identity of the thread that owns the `lua_state`.
    ///
    /// ## Threading contract
    ///
    /// `lua_State *` is non-reentrant: only one thread may make
    /// any Lua C API call at a time, and Lua's GC bookkeeping
    /// corrupts horribly when this is violated (the symptom is a
    /// SIGSEGV inside `_sweeplist` or similar mark/sweep
    /// internals — see git history if curious).
    ///
    /// zi enforces this contract via convention, not via locking:
    ///
    ///   - exactly one thread (the agent thread in interactive
    ///     mode, or the test thread in unit tests) ever calls
    ///     into Lua. That thread "owns" the lua_State for the
    ///     entire runner generation.
    ///
    ///   - the TUI thread NEVER calls Lua.
    ///
    ///   - every Lua entry point (lua_tool.execute, event_bridge
    ///     dispatch, before/afterToolCall hooks, render hook
    ///     precompute) calls `assertOnLuaThread()` at entry.
    ///     The first call claims ownership; subsequent calls
    ///     verify the same thread is calling. Mismatched threads
    ///     `@panic` with a clear message instead of corrupting
    ///     the GC.
    ///
    /// `lua_owner_thread` is `0` when no thread has claimed
    /// ownership yet (between `init` and the first Lua entry).
    ///
    /// Why no mutex: a mutex would let multiple threads call Lua
    /// in turn, but it doesn't help us — Lua entry points can be
    /// long-running (a Task tool holds the lock for the whole
    /// child subprocess lifetime, multiple seconds). Any other
    /// thread that tried to enter Lua during that time would
    /// block, freezing the UI. The right architecture is "one
    /// thread, no contention", which we get for free by having
    /// the agent thread own everything and the TUI thread read
    /// pre-computed data.
    lua_owner_thread: std.atomic.Value(std.Thread.Id) = .{ .raw = 0 },

    /// Scratch arena for hook return values that the agent loop must
    /// hold across a tool-call iteration. The agent's hook signatures
    /// take no allocator, so the bridge needs a place to put owned
    /// JSON values, content-block strings, and reason strings that
    /// outlive the dispatch call but don't need to outlive the runner
    /// generation.
    ///
    /// Lifetime: arena lives for the entire runner generation
    /// (one session in v1 — reload destroys the runner). Allocations
    /// pile up; for typical sessions (~thousands of tool calls,
    /// hook results sized in hundreds of bytes) the working set is
    /// well under a MiB. v2 will revisit if compaction-heavy or
    /// long-running sessions stress this.
    ///
    /// Why not use the agent's loop arena: hooks fire from inside
    /// the loop body but pi-mono's hook ABI doesn't pass the loop
    /// allocator through, and bolting one on would mean changing
    /// every embedder's hook signature. The runner-owned scratch is
    /// the smallest seam.
    hook_arena: std.heap.ArenaAllocator,

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
            .hook_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    /// Allocator backed by the hook scratch arena. Bridge code calls
    /// this when it needs to produce memory that survives until the
    /// runner is destroyed.
    pub fn hookAllocator(self: *ExtensionRunner) std.mem.Allocator {
        return self.hook_arena.allocator();
    }

    /// Attach a borrowed Lua state. Called by the SDK factory once
    /// it has constructed the LuaState and installed the `zi.*` API
    /// table; the runner uses the state for handler dispatch but
    /// does NOT own its lifetime. Caller must keep the state alive
    /// for the runner's full lifetime.
    pub fn attachLuaState(self: *ExtensionRunner, state: *lua_runtime.LuaState) void {
        self.lua_state = state;
    }

    /// Explicitly declare which thread owns `lua_state` from this
    /// point forward (zi-wub.5/.6). MUST be called from the new
    /// owning thread, before that thread makes any other lua call.
    /// Overrides any prior owner pinned by the first-touch claim in
    /// `assertOnLuaThread` (the first-touch claim is the phase 1
    /// fallback; explicit bind is the phase 2 truth).
    ///
    /// Idempotent for the same tid. Calling from a different tid is
    /// a hard rebind — used by flows that transfer ownership before
    /// the new thread starts issuing lua calls. Interactive mode now
    /// binds once on its long-lived agent owner thread at startup.
    ///
    pub fn bindLuaOwnerThread(self: *ExtensionRunner, tid: std.Thread.Id) void {
        self.lua_owner_thread.store(tid, .release);
    }

    pub fn beginLoadContext(self: *ExtensionRunner, source: ExtensionLoadSource) void {
        self.load_context = .{ .source = source };
    }

    pub fn endLoadContext(self: *ExtensionRunner) void {
        self.load_context = null;
    }

    pub fn currentLoadSource(self: *const ExtensionRunner) ?ExtensionLoadSource {
        return if (self.load_context) |ctx| ctx.source else null;
    }

    /// Assert that the current thread is allowed to call into
    /// `lua_state`. Must be invoked at every Lua entry point
    /// (lua_tool.execute, event_bridge dispatch, render hook
    /// precompute, etc.) before any Lua C API call.
    ///
    /// Behavior (phase 1 — soft tracing, zi-wub.3):
    ///   - First call ever: claims the current thread as the
    ///     owner via an atomic compare-and-swap.
    ///   - Subsequent calls from the same thread: no-op.
    ///   - Subsequent calls from a different thread: log a warning
    ///     once per unique offending tid (capped at 16) and CONTINUE.
    ///     We deliberately do NOT panic yet because the first-touch
    ///     claim may have pinned the wrong owner — phase 2
    ///     (`bindLuaOwnerThread`, zi-wub.5/.6/.7) replaces the claim
    ///     with an explicit bind from the agent thread, and only
    ///     then is it safe to flip this to fatal.
    ///
    /// Why an assertion instead of a mutex: see the doc comment
    /// on `lua_owner_thread`. The short version: locking would
    /// freeze the UI behind long-running tools; "single owner
    /// thread + cross-thread inboxes" gives us correctness AND
    /// responsiveness for free.
    pub fn assertOnLuaThread(self: *ExtensionRunner) void {
        const tid = std.Thread.getCurrentId();
        // Try to claim ownership if it's still vacant. cmpxchgStrong
        // is race-free: if two threads try to claim simultaneously,
        // exactly one wins and the loser sees the winner's id.
        const prev = self.lua_owner_thread.cmpxchgStrong(
            0,
            tid,
            .acq_rel,
            .acquire,
        );
        const owner = prev orelse tid;
        if (owner != tid) {
            // zi-wub.7: hard fatal in all build modes. Phase 2's
            // explicit bind (.5/.6) + phase 4's request-queue routing
            // (.14-.17) + shutdown variant (.28) close every known
            // cross-thread touch. Surviving wrong-thread access is a
            // GC-corrupting bug, not a warning. The check itself is
            // a single cmpxchg on the happy path; cost is negligible.
            std.debug.panic(
                "[zi-wub.7] lua_state touched from wrong thread: this={d} owner={d}",
                .{ tid, owner },
            );
        }
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
        self.hook_arena.deinit();
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

fn testGetModel(_: *anyopaque) agent_protocol.Model {
    return .{
        .id = "test-model",
        .name = "Test Model",
        .api = .{ .custom = "test-api" },
        .provider = .{ .custom = "test-provider" },
        .base_url = "",
        .reasoning = false,
        .input = &.{.text},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 1024,
        .max_tokens = 1024,
    };
}

fn testIsIdle(_: *anyopaque) bool {
    return true;
}

fn testAbort(_: *anyopaque) void {}

fn testHasPendingMessages(_: *anyopaque) bool {
    return false;
}

fn testGetContextUsage(_: *anyopaque) ?session_mod.context_usage.ContextUsage {
    return .{ .tokens = 64, .context_window = 1024, .percent = 6.25 };
}

fn testGetSystemPrompt(_: *anyopaque) []const u8 {
    return "system";
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
        .get_model = &testGetModel,
        .is_idle = &testIsIdle,
        .abort = &testAbort,
        .has_pending_messages = &testHasPendingMessages,
        .shutdown = null,
        .get_context_usage = &testGetContextUsage,
        .get_system_prompt = &testGetSystemPrompt,
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
        .get_model = &testGetModel,
        .is_idle = &testIsIdle,
        .abort = &testAbort,
        .has_pending_messages = &testHasPendingMessages,
        .shutdown = null,
        .get_context_usage = &testGetContextUsage,
        .get_system_prompt = &testGetSystemPrompt,
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
