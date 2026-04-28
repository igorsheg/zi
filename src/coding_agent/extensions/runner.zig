const std = @import("std");
const registries = @import("registries/root.zig");
const lua_runtime = @import("lua_runtime.zig");
const abort_signal = @import("../../abort_signal.zig");
const agent_protocol = @import("../../agent3/types.zig");
const session_core = @import("../../session/root.zig");
const ai = @import("../../ai/root.zig");
const resource_types = @import("../resources/types.zig");
const tool_def = @import("../tools/definition.zig");
const context_mod = @import("context.zig");
const oauth_mod = @import("../auth/oauth.zig");
const auth_types = @import("../auth/types.zig");
const request_mod = @import("../request.zig");
const extension_ui = @import("ui.zig");

const log = std.log.scoped(.zi_runner);

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
pub const AsyncOpId = u64;

pub const AsyncKind = enum {
    @"test",
    ai_complete,
};

pub const AiCompleteRequest = struct {
    prompt: []const u8,
    system_prompt: ?[]const u8 = null,
    max_tokens: ?u64 = null,
    model: ?[]const u8 = null,
    reasoning: ?agent_protocol.ThinkingLevel = null,

    pub fn deinit(self: *AiCompleteRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.prompt);
        if (self.system_prompt) |value| allocator.free(value);
        if (self.model) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const AiCompleteResult = union(enum) {
    completed: struct { text: []const u8 },
    err: []const u8,
    cancelled,

    pub fn clone(self: AiCompleteResult, allocator: std.mem.Allocator) !AiCompleteResult {
        return switch (self) {
            .completed => |completed| .{ .completed = .{ .text = try allocator.dupe(u8, completed.text) } },
            .err => |msg| .{ .err = try allocator.dupe(u8, msg) },
            .cancelled => .cancelled,
        };
    }

    pub fn deinit(self: *AiCompleteResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .completed => |completed| allocator.free(completed.text),
            .err => |msg| allocator.free(msg),
            .cancelled => {},
        }
        self.* = undefined;
    }
};

pub const AsyncRequest = union(AsyncKind) {
    @"test": void,
    ai_complete: AiCompleteRequest,

    pub fn deinit(self: *AsyncRequest, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .@"test" => {},
            .ai_complete => |*request| request.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const AsyncStart = struct {
    id: AsyncOpId,
    request: AsyncRequest,

    pub fn kind(self: AsyncStart) AsyncKind {
        return std.meta.activeTag(self.request);
    }

    pub fn deinit(self: *AsyncStart, allocator: std.mem.Allocator) void {
        self.request.deinit(allocator);
        self.* = undefined;
    }
};

pub const AsyncDispatcher = struct {
    ptr: *anyopaque,
    submit: *const fn (ptr: *anyopaque, runner: *ExtensionRunner, start: AsyncStart) anyerror!void,
};

pub const AsyncResult = union(AsyncKind) {
    @"test": []const u8,
    ai_complete: AiCompleteResult,

    pub fn clone(self: AsyncResult, allocator: std.mem.Allocator) !AsyncResult {
        return switch (self) {
            .@"test" => |value| .{ .@"test" = try allocator.dupe(u8, value) },
            .ai_complete => |result| .{ .ai_complete = try result.clone(allocator) },
        };
    }

    pub fn deinit(self: *AsyncResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .@"test" => |value| allocator.free(value),
            .ai_complete => |*result| result.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const PendingAsync = struct {
    id: AsyncOpId,
    kind: AsyncKind,
    co: lua_runtime.Coroutine,
    provenance: ?resource_types.ExtensionProvenance,
    generation: Generation,

    pub fn deinit(self: *PendingAsync) void {
        self.co.deinit();
        self.* = undefined;
    }
};

pub const ExtensionBindingInfo = struct {
    workspace_id: []const u8,
    session_id: []const u8,
    session_file: ?[]const u8 = null,
};

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
        models_get: ?*const fn (session: *anyopaque, allocator: std.mem.Allocator) ?std.json.Value = null,
        models_get_one: ?*const fn (session: *anyopaque, allocator: std.mem.Allocator, model_ref: []const u8) ?std.json.Value = null,
        is_idle: *const fn (session: *anyopaque) bool,
        abort: *const fn (session: *anyopaque) void,
        has_pending_messages: *const fn (session: *anyopaque) bool,
        shutdown: ?*const fn (session: *anyopaque) void = null,
        get_context_usage: *const fn (session: *anyopaque) ?session_core.context_usage.ContextUsage,
        get_system_prompt: *const fn (session: *anyopaque) []const u8,
        get_binding_info: *const fn (session: *anyopaque) ExtensionBindingInfo,
        session_state_get: ?*const fn (session: *anyopaque, allocator: std.mem.Allocator, state_owner_id: []const u8, key: []const u8) ?std.json.Value = null,
        session_state_set: ?*const fn (session: *anyopaque, state_owner_id: []const u8, key: []const u8, value: std.json.Value) anyerror!void = null,
        session_state_delete: ?*const fn (session: *anyopaque, state_owner_id: []const u8, key: []const u8) anyerror!void = null,
        session_info_get: ?*const fn (session: *anyopaque, allocator: std.mem.Allocator) ?std.json.Value = null,
        session_name_get: ?*const fn (session: *anyopaque, allocator: std.mem.Allocator) ?[]const u8 = null,
        session_name_set: ?*const fn (session: *anyopaque, name: ?[]const u8) anyerror!void = null,
        session_tool_results_get: ?*const fn (session: *anyopaque, allocator: std.mem.Allocator, tool_name: []const u8) ?std.json.Value = null,
        session_messages_get: ?*const fn (session: *anyopaque, allocator: std.mem.Allocator, limit: usize, include_tools: bool) ?std.json.Value = null,
        session_note_append: ?*const fn (session: *anyopaque, kind: []const u8, title: ?[]const u8, body: []const u8, source_entry_id: ?[]const u8) anyerror!void = null,
        session_notes_get: ?*const fn (session: *anyopaque, allocator: std.mem.Allocator, kind: ?[]const u8, source_entry_id: ?[]const u8, limit: usize) ?std.json.Value = null,
        session_label_set: ?*const fn (session: *anyopaque, target_entry_id: []const u8, label: ?[]const u8) anyerror!void = null,
        session_labels_get: ?*const fn (session: *anyopaque, allocator: std.mem.Allocator, target_entry_id: ?[]const u8, limit: usize) ?std.json.Value = null,
        show_panel: ?*const fn (session: *anyopaque, panel: extension_ui.Panel) anyerror!void = null,
        publish_prompt: ?*const fn (session: *anyopaque, prompt: extension_ui.PromptRequest) anyerror!void = null,
        resolve_prompt: ?*const fn (session: *anyopaque, prompt: extension_ui.PromptRequest, response: *request_mod.ExtensionPromptResponse) void = null,
        cancel_prompts: ?*const fn (session: *anyopaque) void = null,
        publish_surface: ?*const fn (session: *anyopaque, update: extension_ui.SurfaceUpdate) anyerror!void = null,
        revoke_surfaces: ?*const fn (session: *anyopaque) void = null,
        publish_editor_action: ?*const fn (session: *anyopaque, action: extension_ui.EditorAction) anyerror!void = null,
        clear_editor_actions: ?*const fn (session: *anyopaque) void = null,
        provider_projection_changed: ?*const fn (session: *anyopaque) void = null,
        tool_projection_changed: ?*const fn (session: *anyopaque) void = null,
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

    pub fn swap(self: *ExtensionRunnerRef, next: ?*ExtensionRunner) ?*ExtensionRunner {
        const previous = self.current;
        self.current = next;
        return previous;
    }
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
    provenance: resource_types.ExtensionProvenance,
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

    next_async_id: AsyncOpId = 1,
    current_async_start: ?AsyncStart = null,
    pending_async: std.AutoHashMapUnmanaged(AsyncOpId, PendingAsync) = .empty,
    completed_async: std.AutoHashMapUnmanaged(AsyncOpId, AsyncResult) = .empty,
    async_dispatcher: ?AsyncDispatcher = null,
    enable_test_async: bool = false,

    loaded_extensions: std.ArrayListUnmanaged(resource_types.ExtensionProvenance) = .empty,
    load_context: ?LoadContext = null,
    execution_context: ?LoadContext = null,
    _provider_registry: ?*ai.provider.Registry = null,

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

    /// Per-extension private module root directories, keyed by
    /// `state_owner_id`. Set during extension load so that later
    /// execution (tool, event, render) can prepend the right
    /// private root to `package.path`.
    module_roots: std.StringHashMapUnmanaged([]const u8) = .empty,

    /// Shared `lua/` search paths built from the canonical ordered
    /// root list. Persisted so every execution entry point can
    /// prepend the private root and restore the shared + default
    /// package.path.
    shared_lua_paths: ?[]const u8 = null,

    /// The default `package.path` captured at Lua state creation,
    /// before any extension overrides. Preserves builtin/default
    /// module resolution after shared and private roots.
    base_package_path: ?[]const u8 = null,

    /// Borrowed builtin tool catalog used by the host-private builtin
    /// extension bridge during load. Empty for sessions that provide
    /// custom top-level tools instead of the default builtin set.
    builtin_tool_definitions: []const tool_def.ToolDefinition = &.{},

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
            .loaded_extensions = .empty,
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

    pub fn beginExecutionContext(self: *ExtensionRunner, source: ExtensionLoadSource) void {
        self.execution_context = .{ .source = source };
    }

    pub fn endExecutionContext(self: *ExtensionRunner) void {
        self.execution_context = null;
    }

    pub fn currentLoadSource(self: *const ExtensionRunner) ?ExtensionLoadSource {
        if (self.load_context) |ctx| return ctx.source;
        return if (self.execution_context) |ctx| ctx.source else null;
    }

    pub fn recordLoadedExtension(self: *ExtensionRunner, provenance: resource_types.ExtensionProvenance) !void {
        try self.loaded_extensions.append(self.allocator, provenance);
    }

    pub fn findLoadedExtensionByStateOwner(self: *const ExtensionRunner, state_owner_id: []const u8) ?resource_types.ExtensionProvenance {
        for (self.loaded_extensions.items) |provenance| {
            if (std.mem.eql(u8, provenance.state_owner_id, state_owner_id)) return provenance;
        }
        return null;
    }
    pub fn findLoadedExtensionById(self: *const ExtensionRunner, extension_id: []const u8) ?resource_types.ExtensionProvenance {
        for (self.loaded_extensions.items) |provenance| {
            if (std.mem.eql(u8, provenance.extension_id, extension_id)) return provenance;
        }
        return null;
    }

    pub fn sourceForProvenance(self: *const ExtensionRunner, provenance: resource_types.ExtensionProvenance) ExtensionLoadSource {
        _ = self;
        return .{
            .kind = switch (provenance.root_kind) {
                .builtin => "builtin",
                else => "extension",
            },
            .id = provenance.extension_id,
            .path = provenance.state_owner_id,
            .provenance = provenance,
        };
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
    pub fn isOnLuaThread(self: *const ExtensionRunner) bool {
        const owner = self.lua_owner_thread.load(.acquire);
        return owner != 0 and owner == std.Thread.getCurrentId();
    }

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
        self.clearAsyncState();
        self.provider_queue.deinit();
        self.command_registry.deinit();
        self.event_registry.deinit();
        self.tool_registry.deinit();
        self.loaded_extensions.deinit(self.allocator);
        self.hook_arena.deinit();

        // Free module-context state.
        var it = self.module_roots.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.module_roots.deinit(self.allocator);
        if (self.shared_lua_paths) |p| self.allocator.free(p);
        if (self.base_package_path) |p| self.allocator.free(p);
    }

    /// Swap the runtime from stub to bound. Idempotent guard: errors if
    /// already bound to prevent accidental double-binding.
    ///
    /// Called by AgentSession after construction, once all dependencies
    /// (session store, agent core, optional UI) are available. The bound
    /// pointers are opaque to avoid circular module dependencies; later
    /// phases cast them to concrete types at use sites.
    pub fn bindRuntime(self: *ExtensionRunner, bound: ExtensionRuntime.Bound, provider_registry: *ai.provider.Registry) !void {
        if (self.runtime != .stub) return error.AlreadyBound;
        self.runtime = .{ .bound = bound };
        self._provider_registry = provider_registry;
        errdefer self._provider_registry = null;
        const projection_changed = try self.drainQueuedProviders();
        if (projection_changed) self.notifyProviderProjectionChanged();
    }

    pub fn unbindRuntime(self: *ExtensionRunner) void {
        if (self.runtime == .bound) {
            const bound = self.runtime.bound;
            if (bound.cancel_prompts) |cancel| cancel(bound.session);
            if (bound.revoke_surfaces) |revoke| revoke(bound.session);
            if (bound.clear_editor_actions) |clear| clear(bound.session);
            var projection_changed = false;
            if (self._provider_registry) |registry| {
                const before = registry.activeClaimCount();
                registry.unregisterClaimsByGeneration(self.generation) catch |err| {
                    log.warn("failed to revoke provider claims for generation {d}: {s}", .{ self.generation, @errorName(err) });
                };
                oauth_mod.unregisterProvidersByGeneration(self.generation);
                projection_changed = registry.activeClaimCount() != before;
            }
            if (projection_changed) self.notifyProviderProjectionChanged();
            self._provider_registry = null;
            self.runtime = .{ .stub = {} };
        }
    }

    pub fn registerProviderClaim(self: *ExtensionRunner, claim: ai.provider.ClaimRegistration) !bool {
        if (self._provider_registry) |registry| {
            errdefer {
                var owned = claim;
                owned.deinit(self.allocator);
            }
            const accepted = try registry.registerClaim(claim);
            if (accepted) {
                const active = registry.activeClaimRegistrationByName(claim.name) orelse unreachable;
                try oauth_mod.syncClaimProvider(self.allocator, active);
                self.notifyProviderProjectionChanged();
            }
            return accepted;
        }
        errdefer {
            var owned = claim;
            owned.deinit(self.allocator);
        }
        try self.provider_queue.enqueueRegister(claim);
        return true;
    }

    pub fn unregisterProviderClaim(self: *ExtensionRunner, name: []const u8, owner_id: []const u8) !bool {
        if (self._provider_registry) |registry| {
            defer self.allocator.free(name);
            defer self.allocator.free(owner_id);
            const removed = try registry.unregisterClaim(name, owner_id, self.generation);
            if (removed) {
                _ = oauth_mod.unregisterClaimProvider(name, owner_id, self.generation);
                self.notifyProviderProjectionChanged();
            }
            return removed;
        }
        errdefer {
            self.allocator.free(name);
            self.allocator.free(owner_id);
        }
        try self.provider_queue.enqueueUnregister(.{ .name = name, .owner_id = owner_id });
        return true;
    }

    fn drainQueuedProviders(self: *ExtensionRunner) !bool {
        const registry = self._provider_registry orelse return false;
        const drained = self.provider_queue.drain();
        defer self.allocator.free(drained);

        var projection_changed = false;
        for (drained) |*op| {
            switch (op.*) {
                .register => |claim| {
                    if (try registry.registerClaim(claim)) {
                        const active = registry.activeClaimRegistrationByName(claim.name) orelse unreachable;
                        try oauth_mod.syncClaimProvider(self.allocator, active);
                        projection_changed = true;
                    } else {
                        var rejected = claim;
                        rejected.deinit(self.allocator);
                    }
                },
                .unregister => |claim| {
                    if (try registry.unregisterClaim(claim.name, claim.owner_id, self.generation)) {
                        _ = oauth_mod.unregisterClaimProvider(claim.name, claim.owner_id, self.generation);
                        projection_changed = true;
                    }
                    var owned = claim;
                    owned.deinit(self.allocator);
                },
            }
            op.* = undefined;
        }
        return projection_changed;
    }

    fn notifyProviderProjectionChanged(self: *ExtensionRunner) void {
        const bound = switch (self.runtime) {
            .bound => |runtime| runtime,
            .stub => return,
        };
        const callback = bound.provider_projection_changed orelse return;
        callback(bound.session);
    }

    pub fn notifyToolProjectionChanged(self: *ExtensionRunner) void {
        const bound = switch (self.runtime) {
            .bound => |runtime| runtime,
            .stub => return,
        };
        const callback = bound.tool_projection_changed orelse return;
        callback(bound.session);
    }

    pub fn isBound(self: *const ExtensionRunner) bool {
        return self.runtime == .bound;
    }

    pub fn isReloadIdle(self: *const ExtensionRunner) bool {
        return self.load_context == null and
            self.execution_context == null and
            self.current_signal == null and
            self.current_update_callback == null and
            self.current_spawn_request == null;
    }

    /// Dispatch an extension command by its visible invocation name.
    ///
    /// Thread contract: must run on the Lua-owning (agent) thread.
    /// The handler is invoked in a fresh coroutine with `args` as the
    /// first argument and a command context as the second. If the
    /// handler yields, returns `error.UnexpectedYield` — command
    /// bodies are not yieldable in this slice.
    pub fn dispatchCommand(self: *ExtensionRunner, name: []const u8, args: []const u8) !void {
        self.assertOnLuaThread();

        const state = self.lua_state orelse return error.MissingLuaState;
        const cmd = self.command_registry.getByVisibleName(name) orelse return error.UnknownCommand;

        var co = try lua_runtime.Coroutine.init(state);
        var co_owned = true;
        defer if (co_owned) co.deinit();

        _ = lua_runtime.c.lua_rawgeti(co.L, lua_runtime.c.LUA_REGISTRYINDEX, cmd.lua_ref);
        if (lua_runtime.c.lua_type(co.L, -1) != lua_runtime.c.LUA_TFUNCTION) {
            lua_runtime.c.lua_pop(co.L, 1);
            return error.InvalidHandlerRef;
        }

        // arg 1: args string
        _ = lua_runtime.c.lua_pushlstring(co.L, args.ptr, args.len);

        // arg 2: command context
        context_mod.pushCommandContext(co.L, self, cmd.source.provenance) catch {
            lua_runtime.c.lua_pop(co.L, 2); // args + handler
            return error.ContextPushFailed;
        };

        self.setModuleContext(state, cmd.source.provenance);
        if (cmd.source.provenance) |provenance| {
            self.beginExecutionContext(self.sourceForProvenance(provenance));
            defer self.endExecutionContext();
        }

        const r = try co.resumeWith(2);
        switch (r.status) {
            .yielded => {
                const start = try self.suspendYieldedCommand(&co, cmd.source.provenance);
                co_owned = false;
                try self.submitAsyncStart(start);
                return;
            },
            .ok, .finished => {},
        }

        // Discard any return values.
        const top = lua_runtime.c.lua_gettop(co.L);
        if (r.nresults > 0) {
            lua_runtime.c.lua_settop(co.L, top - r.nresults);
        }
    }

    fn suspendYieldedCommand(self: *ExtensionRunner, co: *lua_runtime.Coroutine, provenance: ?resource_types.ExtensionProvenance) !AsyncStart {
        const start = self.current_async_start orelse return error.UnexpectedYield;
        self.current_async_start = null;
        try self.pending_async.put(self.allocator, start.id, .{
            .id = start.id,
            .kind = start.kind(),
            .co = co.*,
            .provenance = provenance,
            .generation = self.generation,
        });
        return start;
    }

    fn submitAsyncStart(self: *ExtensionRunner, start: AsyncStart) !void {
        if (self.async_dispatcher) |dispatcher| {
            dispatcher.submit(dispatcher.ptr, self, start) catch |err| {
                var failed_start = start;
                failed_start.deinit(self.allocator);
                if (self.pending_async.fetchRemove(start.id)) |kv| {
                    var pending = kv.value;
                    pending.deinit();
                }
                return err;
            };
        } else {
            var unsubmitted = start;
            unsubmitted.deinit(self.allocator);
        }
    }

    pub fn beginTestAsync(self: *ExtensionRunner) AsyncOpId {
        const id = self.next_async_id;
        self.next_async_id += 1;
        self.current_async_start = .{ .id = id, .request = .{ .@"test" = {} } };
        return id;
    }

    pub fn beginAiCompleteAsync(self: *ExtensionRunner, request: AiCompleteRequest) AsyncOpId {
        const id = self.next_async_id;
        self.next_async_id += 1;
        self.current_async_start = .{ .id = id, .request = .{ .ai_complete = request } };
        return id;
    }

    pub fn takeCompletedAsync(self: *ExtensionRunner, id: AsyncOpId) ?AsyncResult {
        const kv = self.completed_async.fetchRemove(id) orelse return null;
        return kv.value;
    }

    pub fn completeTestAsync(self: *ExtensionRunner, id: AsyncOpId, value: []const u8) !void {
        const owned = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned);
        try self.resumeAsync(id, .{ .@"test" = owned });
    }

    pub fn resumeAsync(self: *ExtensionRunner, id: AsyncOpId, result: AsyncResult) !void {
        self.assertOnLuaThread();
        const pending_kv = self.pending_async.fetchRemove(id) orelse {
            var dropped = result;
            dropped.deinit(self.allocator);
            return;
        };
        var pending = pending_kv.value;
        var pending_owned = true;
        defer if (pending_owned) pending.deinit();

        if (pending.generation != self.generation) {
            var dropped = result;
            dropped.deinit(self.allocator);
            return;
        }

        try self.completed_async.put(self.allocator, id, result);
        errdefer if (self.completed_async.fetchRemove(id)) |kv| {
            var dropped = kv.value;
            dropped.deinit(self.allocator);
        };

        const r = try pending.co.resumeWith(0);
        switch (r.status) {
            .yielded => {
                const start = try self.suspendYieldedCommand(&pending.co, pending.provenance);
                pending_owned = false;
                try self.submitAsyncStart(start);
            },
            .ok, .finished => {
                const top = lua_runtime.c.lua_gettop(pending.co.L);
                if (r.nresults > 0) lua_runtime.c.lua_settop(pending.co.L, top - r.nresults);
            },
        }
    }

    fn clearAsyncState(self: *ExtensionRunner) void {
        if (self.current_async_start != null) self.current_async_start = null;
        var pending_it = self.pending_async.iterator();
        while (pending_it.next()) |entry| entry.value_ptr.deinit();
        self.pending_async.deinit(self.allocator);
        var completed_it = self.completed_async.iterator();
        while (completed_it.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.completed_async.deinit(self.allocator);
    }

    pub fn dispatchOAuthLogin(
        self: *ExtensionRunner,
        provider_id: []const u8,
        callbacks: request_mod.ExtensionOAuthLoginCallbacks,
        allocator: std.mem.Allocator,
    ) !request_mod.ExtensionOAuthLoginResponse.Result {
        self.assertOnLuaThread();

        const registry = self._provider_registry orelse return error.MissingProviderRegistry;
        const claim = registry.activeClaimRegistrationByName(provider_id) orelse return error.UnknownProvider;
        const handler_ref = claim.oauth_login_ref orelse return .unsupported;
        const state = self.lua_state orelse return error.MissingLuaState;
        const provenance = self.findLoadedExtensionByStateOwner(claim.owner_id);

        var co = try lua_runtime.Coroutine.init(state);
        defer co.deinit();

        _ = lua_runtime.c.lua_rawgeti(co.L, lua_runtime.c.LUA_REGISTRYINDEX, handler_ref);
        if (lua_runtime.c.lua_type(co.L, -1) != lua_runtime.c.LUA_TFUNCTION) {
            lua_runtime.c.lua_pop(co.L, 1);
            return error.InvalidHandlerRef;
        }

        var invoke_ctx = OAuthLoginInvokeCtx{ .callbacks = callbacks };
        pushOAuthLoginCallbacks(co.L, &invoke_ctx);

        self.setModuleContext(state, provenance);
        if (provenance) |prov| {
            self.beginExecutionContext(self.sourceForProvenance(prov));
            defer self.endExecutionContext();
        }

        const r = try co.resumeWith(1);
        switch (r.status) {
            .yielded => return error.UnexpectedYield,
            .ok, .finished => {},
        }

        if (r.nresults == 0) return .cancelled;
        const top = lua_runtime.c.lua_gettop(co.L);
        defer lua_runtime.c.lua_settop(co.L, top - r.nresults);
        return .{ .success = try parseOAuthCredential(co.L, top - r.nresults + 1, allocator) };
    }

    pub fn dispatchOAuthRefresh(
        self: *ExtensionRunner,
        provider_id: []const u8,
        credential: auth_types.OAuthCredential,
        allocator: std.mem.Allocator,
    ) !oauth_mod.ExchangeResult {
        self.assertOnLuaThread();

        const registry = self._provider_registry orelse return error.MissingProviderRegistry;
        const claim = registry.activeClaimRegistrationByName(provider_id) orelse return error.UnknownProvider;
        const handler_ref = claim.oauth_refresh_token_ref orelse return .{ .err = "extension OAuth refresh is unsupported for this provider" };
        const state = self.lua_state orelse return error.MissingLuaState;
        const provenance = self.findLoadedExtensionByStateOwner(claim.owner_id);

        var co = try lua_runtime.Coroutine.init(state);
        defer co.deinit();

        _ = lua_runtime.c.lua_rawgeti(co.L, lua_runtime.c.LUA_REGISTRYINDEX, handler_ref);
        if (lua_runtime.c.lua_type(co.L, -1) != lua_runtime.c.LUA_TFUNCTION) {
            lua_runtime.c.lua_pop(co.L, 1);
            return error.InvalidHandlerRef;
        }
        pushOAuthCredentialTable(co.L, credential);

        self.setModuleContext(state, provenance);
        if (provenance) |prov| {
            self.beginExecutionContext(self.sourceForProvenance(prov));
            defer self.endExecutionContext();
        }

        const r = try co.resumeWith(1);
        switch (r.status) {
            .yielded => return error.UnexpectedYield,
            .ok, .finished => {},
        }

        if (r.nresults == 0) return .{ .err = "missing OAuth credential" };
        const top = lua_runtime.c.lua_gettop(co.L);
        defer lua_runtime.c.lua_settop(co.L, top - r.nresults);
        return .{ .success = try parseOAuthCredential(co.L, top - r.nresults + 1, allocator) };
    }

    pub fn dispatchOAuthGetApiKey(
        self: *ExtensionRunner,
        provider_id: []const u8,
        credential: auth_types.OAuthCredential,
        allocator: std.mem.Allocator,
    ) !?[]const u8 {
        self.assertOnLuaThread();

        const registry = self._provider_registry orelse return error.MissingProviderRegistry;
        const claim = registry.activeClaimRegistrationByName(provider_id) orelse return error.UnknownProvider;
        const handler_ref = claim.oauth_get_api_key_ref orelse return null;
        const state = self.lua_state orelse return error.MissingLuaState;
        const provenance = self.findLoadedExtensionByStateOwner(claim.owner_id);

        var co = try lua_runtime.Coroutine.init(state);
        defer co.deinit();

        _ = lua_runtime.c.lua_rawgeti(co.L, lua_runtime.c.LUA_REGISTRYINDEX, handler_ref);
        if (lua_runtime.c.lua_type(co.L, -1) != lua_runtime.c.LUA_TFUNCTION) {
            lua_runtime.c.lua_pop(co.L, 1);
            return error.InvalidHandlerRef;
        }
        pushOAuthCredentialTable(co.L, credential);

        self.setModuleContext(state, provenance);
        if (provenance) |prov| {
            self.beginExecutionContext(self.sourceForProvenance(prov));
            defer self.endExecutionContext();
        }

        const r = try co.resumeWith(1);
        switch (r.status) {
            .yielded => return error.UnexpectedYield,
            .ok, .finished => {},
        }

        if (r.nresults == 0) return null;
        const top = lua_runtime.c.lua_gettop(co.L);
        defer lua_runtime.c.lua_settop(co.L, top - r.nresults);
        return try parseOAuthApiKeyResult(co.L, top - r.nresults + 1, allocator);
    }

    const OAuthLoginInvokeCtx = struct {
        callbacks: request_mod.ExtensionOAuthLoginCallbacks,
    };

    fn pushOAuthLoginCallbacks(L: *lua_runtime.c.lua_State, invoke_ctx: *OAuthLoginInvokeCtx) void {
        const c = lua_runtime.c;
        c.lua_createtable(L, 0, 2);
        c.lua_pushlightuserdata(L, invoke_ctx);
        c.lua_pushcclosure(L, oauthLoginOnAuth, 1);
        c.lua_setfield(L, -2, "onAuth");
        if (invoke_ctx.callbacks.on_progress != null) {
            c.lua_pushlightuserdata(L, invoke_ctx);
            c.lua_pushcclosure(L, oauthLoginOnProgress, 1);
            c.lua_setfield(L, -2, "onProgress");
        }
    }

    fn oauthLoginOnAuth(L_opt: ?*lua_runtime.c.lua_State) callconv(.c) c_int {
        const c = lua_runtime.c;
        const L = L_opt.?;
        const ctx_ptr = c.lua_touserdata(L, c.lua_upvalueindex(1)) orelse return c.luaL_error(L, "oauth.onAuth: missing context");
        const invoke_ctx: *OAuthLoginInvokeCtx = @ptrCast(@alignCast(ctx_ptr));
        if (c.lua_type(L, 1) != c.LUA_TTABLE) return c.luaL_error(L, "oauth.onAuth: expected table");
        _ = c.lua_getfield(L, 1, "url");
        defer c.lua_pop(L, 1);
        if (c.lua_type(L, -1) != c.LUA_TSTRING) return c.luaL_error(L, "oauth.onAuth: expected string field 'url'");
        invoke_ctx.callbacks.on_auth(lstring(L, -1), invoke_ctx.callbacks.ctx);
        return 0;
    }

    fn oauthLoginOnProgress(L_opt: ?*lua_runtime.c.lua_State) callconv(.c) c_int {
        const c = lua_runtime.c;
        const L = L_opt.?;
        const ctx_ptr = c.lua_touserdata(L, c.lua_upvalueindex(1)) orelse return c.luaL_error(L, "oauth.onProgress: missing context");
        const invoke_ctx: *OAuthLoginInvokeCtx = @ptrCast(@alignCast(ctx_ptr));
        const progress = invoke_ctx.callbacks.on_progress orelse return 0;
        if (c.lua_type(L, 1) != c.LUA_TSTRING) return c.luaL_error(L, "oauth.onProgress: expected string");
        progress(lstring(L, 1), invoke_ctx.callbacks.ctx);
        return 0;
    }

    fn pushOAuthCredentialTable(L: *lua_runtime.c.lua_State, credential: auth_types.OAuthCredential) void {
        const c = lua_runtime.c;
        c.lua_createtable(L, 0, 3 + @as(c_int, @intCast(credential.extras.count())));
        _ = c.lua_pushlstring(L, credential.refresh.ptr, credential.refresh.len);
        c.lua_setfield(L, -2, "refresh");
        _ = c.lua_pushlstring(L, credential.access.ptr, credential.access.len);
        c.lua_setfield(L, -2, "access");
        c.lua_pushinteger(L, @intCast(credential.expires));
        c.lua_setfield(L, -2, "expires");

        var it = credential.extras.iterator();
        while (it.next()) |entry| {
            _ = c.lua_pushlstring(L, entry.key_ptr.*.ptr, entry.key_ptr.*.len);
            lua_runtime.pushJsonValue(L, entry.value_ptr.*) catch unreachable;
            c.lua_settable(L, -3);
        }
    }

    fn parseOAuthApiKeyResult(
        L: *lua_runtime.c.lua_State,
        idx: c_int,
        allocator: std.mem.Allocator,
    ) !?[]const u8 {
        const c = lua_runtime.c;
        return switch (c.lua_type(L, idx)) {
            c.LUA_TNIL => null,
            c.LUA_TSTRING => try allocator.dupe(u8, lstring(L, idx)),
            else => error.InvalidOAuthApiKey,
        };
    }

    fn parseOAuthCredential(
        L: *lua_runtime.c.lua_State,
        idx: c_int,
        allocator: std.mem.Allocator,
    ) !auth_types.OAuthCredential {
        const c = lua_runtime.c;
        if (c.lua_type(L, idx) != c.LUA_TTABLE) return error.InvalidOAuthCredential;
        const abs_idx = c.lua_absindex(L, idx);

        _ = c.lua_getfield(L, abs_idx, "refresh");
        defer c.lua_pop(L, 1);
        if (c.lua_type(L, -1) != c.LUA_TSTRING) return error.InvalidOAuthCredential;
        const refresh = try allocator.dupe(u8, lstring(L, -1));
        errdefer allocator.free(refresh);

        _ = c.lua_getfield(L, abs_idx, "access");
        defer c.lua_pop(L, 1);
        if (c.lua_type(L, -1) != c.LUA_TSTRING) return error.InvalidOAuthCredential;
        const access = try allocator.dupe(u8, lstring(L, -1));
        errdefer allocator.free(access);

        _ = c.lua_getfield(L, abs_idx, "expires");
        defer c.lua_pop(L, 1);
        const expires: i64 = switch (c.lua_type(L, -1)) {
            c.LUA_TNUMBER => if (c.lua_isinteger(L, -1) != 0)
                @intCast(c.lua_tointegerx(L, -1, null))
            else
                @intFromFloat(c.lua_tonumberx(L, -1, null)),
            else => return error.InvalidOAuthCredential,
        };

        var extras = std.json.ObjectMap.init(allocator);
        errdefer {
            var eit = extras.iterator();
            while (eit.next()) |e| {
                allocator.free(e.key_ptr.*);
                ai.json_util.freeJsonValue(allocator, e.value_ptr.*);
            }
            extras.deinit();
        }

        c.lua_pushnil(L);
        while (c.lua_next(L, abs_idx) != 0) {
            defer c.lua_pop(L, 1);
            if (c.lua_type(L, -2) != c.LUA_TSTRING) continue;
            const key = lstring(L, -2);
            if (std.mem.eql(u8, key, "refresh") or std.mem.eql(u8, key, "access") or std.mem.eql(u8, key, "expires")) continue;
            const duped_key = try allocator.dupe(u8, key);
            errdefer allocator.free(duped_key);
            const value = try lua_runtime.luaValueToJson(L, -1, allocator);
            try extras.put(duped_key, value);
        }

        return .{
            .refresh = refresh,
            .access = access,
            .expires = expires,
            .extras = extras,
        };
    }

    fn lstring(L: *lua_runtime.c.lua_State, idx: c_int) []const u8 {
        var len: usize = 0;
        const ptr = lua_runtime.c.lua_tolstring(L, idx, &len) orelse return &.{};
        return ptr[0..len];
    }

    /// Record the private module root for an extension so that later
    /// execution entry points can resolve `require("helper")` relative
    /// to the extension's directory.
    pub fn recordModuleRoot(self: *ExtensionRunner, state_owner_id: []const u8, path: []const u8) !void {
        const root = try moduleRootFromExtensionPath(self.allocator, path);
        errdefer self.allocator.free(root);
        const key = try self.allocator.dupe(u8, state_owner_id);
        errdefer self.allocator.free(key);
        try self.module_roots.put(self.allocator, key, root);
    }

    /// Set Lua `package.path` for the execution context belonging to
    /// `provenance`. Prepends the extension's private root (if any),
    /// then the shared `lua/` roots, then the default builtin paths.
    /// Single-threaded: every entry point overwrites the path for
    /// its own context, so nested callbacks naturally inherit the
    /// current tool's module context.
    pub fn setModuleContext(self: *ExtensionRunner, state: *lua_runtime.LuaState, provenance: ?resource_types.ExtensionProvenance) void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);

        // Private root first.
        if (provenance) |prov| {
            if (self.module_roots.get(prov.state_owner_id)) |private_root| {
                buf.writer(self.allocator).print("{s}/?.lua;{s}/?/init.lua", .{ private_root, private_root }) catch {};
            }
        }

        // Shared lua/ anchors from canonical roots.
        if (self.shared_lua_paths) |shared| {
            if (buf.items.len > 0) buf.append(self.allocator, ';') catch {};
            buf.appendSlice(self.allocator, shared) catch {};
        }

        // Default Lua search paths (builtin libraries).
        if (self.base_package_path) |base| {
            if (buf.items.len > 0) buf.append(self.allocator, ';') catch {};
            buf.appendSlice(self.allocator, base) catch {};
        }

        if (buf.items.len > 0) {
            state.setPackagePathRaw(buf.items);
        }
    }
};

fn moduleRootFromExtensionPath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const basename = std.fs.path.basename(path);
    if (std.mem.eql(u8, basename, "init.lua")) {
        const dir = std.fs.path.dirname(path) orelse path;
        return try allocator.dupe(u8, dir);
    }
    if (std.mem.endsWith(u8, path, ".lua")) {
        return try allocator.dupe(u8, path[0 .. path.len - 4]);
    }
    const dir = std.fs.path.dirname(path) orelse path;
    return try allocator.dupe(u8, dir);
}

// =============================================================================
// Tests
// =============================================================================

test "ExtensionRunner unbinds back to stub state" {
    const allocator = std.testing.allocator;
    var runner = ExtensionRunner.init(allocator, 7);
    defer runner.deinit();
    var provider_registry = ai.provider.Registry.init(allocator);
    defer provider_registry.deinit();

    try runner.bindRuntime(.{
        .session = undefined,
        .ui = null,
        .command_actions = null,
        .get_model = &testGetModel,
        .is_idle = &testIsIdle,
        .abort = &testAbort,
        .has_pending_messages = &testHasPendingMessages,
        .shutdown = null,
        .get_context_usage = &testGetContextUsage,
        .get_system_prompt = &testGetSystemPrompt,
        .get_binding_info = &testGetBindingInfo,
    }, &provider_registry);
    try std.testing.expect(runner.isBound());

    runner.unbindRuntime();
    try std.testing.expect(!runner.isBound());
    try std.testing.expect(runner.runtime == .stub);
}

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

fn testGetContextUsage(_: *anyopaque) ?session_core.context_usage.ContextUsage {
    return .{ .tokens = 64, .context_window = 1024, .percent = 6.25 };
}

fn testGetSystemPrompt(_: *anyopaque) []const u8 {
    return "system";
}

fn testGetBindingInfo(_: *anyopaque) ExtensionBindingInfo {
    return .{
        .workspace_id = "/workspace",
        .session_id = "session-123",
        .session_file = "/workspace/.zi/sessions/session-123.jsonl",
    };
}

test "bindRuntime rejects double-bind" {
    const allocator = std.testing.allocator;
    var runner = ExtensionRunner.init(allocator, 1);
    defer runner.deinit();
    var provider_registry = ai.provider.Registry.init(allocator);
    defer provider_registry.deinit();

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
        .get_binding_info = &testGetBindingInfo,
    };

    try runner.bindRuntime(bound, &provider_registry);
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
        .get_binding_info = &testGetBindingInfo,
    };

    const result = runner.bindRuntime(bound2, &provider_registry);
    try std.testing.expectError(error.AlreadyBound, result);
}

test "dispatchOAuthGetApiKey executes the claim callback on the lua-owning thread" {
    const allocator = std.testing.allocator;

    var state = try lua_runtime.LuaState.init(allocator);
    defer state.deinit();

    var runner = ExtensionRunner.init(allocator, 11);
    defer runner.deinit();
    runner.attachLuaState(&state);
    runner.bindLuaOwnerThread(std.Thread.getCurrentId());

    try state.doString(
        \\function oauth_get_api_key(credentials)
        \\  return credentials.access .. "-api"
        \\end
    , "oauth_get_api_key_test");
    _ = lua_runtime.c.lua_getglobal(state.L, "oauth_get_api_key");
    const handler_ref = lua_runtime.c.luaL_ref(state.L, lua_runtime.c.LUA_REGISTRYINDEX);

    var baseline = ai.faux.FauxProvider.init(allocator);
    defer baseline.deinit();

    var provider_registry = ai.provider.Registry.init(allocator);
    defer provider_registry.deinit();
    try provider_registry.register("anthropic-messages", baseline.provider(), null);
    try std.testing.expect(try provider_registry.registerClaim(.{
        .name = try allocator.dupe(u8, "proxy-get-key"),
        .api = try allocator.dupe(u8, "anthropic-messages"),
        .base_url = try allocator.dupe(u8, "https://proxy.example"),
        .oauth_enabled = true,
        .oauth_get_api_key_ref = handler_ref,
        .owner_id = try allocator.dupe(u8, "state-123"),
        .generation = runner.generation,
    }));

    try runner.bindRuntime(.{
        .session = undefined,
        .ui = null,
        .command_actions = null,
        .get_model = &testGetModel,
        .is_idle = &testIsIdle,
        .abort = &testAbort,
        .has_pending_messages = &testHasPendingMessages,
        .shutdown = null,
        .get_context_usage = &testGetContextUsage,
        .get_system_prompt = &testGetSystemPrompt,
        .get_binding_info = &testGetBindingInfo,
    }, &provider_registry);

    var credential = auth_types.OAuthCredential{
        .refresh = try allocator.dupe(u8, "refresh-token"),
        .access = try allocator.dupe(u8, "access-token"),
        .expires = 1234,
        .extras = std.json.ObjectMap.init(allocator),
    };
    defer auth_types.deinitOAuthCredential(allocator, &credential);

    const api_key = try runner.dispatchOAuthGetApiKey("proxy-get-key", credential, allocator);
    defer if (api_key) |key| allocator.free(key);
    try std.testing.expect(api_key != null);
    try std.testing.expectEqualStrings("access-token-api", api_key.?);
}

test "bindRuntime replays queued providers, registers oauth claims, and unbindRuntime revokes the generation" {
    const allocator = std.testing.allocator;
    oauth_mod.resetDynamicProvidersForTest();
    defer oauth_mod.resetDynamicProvidersForTest();

    var runner = ExtensionRunner.init(allocator, 9);
    defer runner.deinit();

    var baseline = ai.faux.FauxProvider.init(allocator);
    defer baseline.deinit();

    var provider_registry = ai.provider.Registry.init(allocator);
    defer provider_registry.deinit();
    try provider_registry.register("anthropic-messages", baseline.provider(), null);

    try runner.provider_queue.enqueueRegister(.{
        .name = try allocator.dupe(u8, "proxy"),
        .api = try allocator.dupe(u8, "anthropic-messages"),
        .base_url = try allocator.dupe(u8, "https://proxy.example"),
        .oauth_enabled = true,
        .oauth_name = try allocator.dupe(u8, "Proxy Login"),
        .owner_id = try allocator.dupe(u8, "state-123"),
        .generation = runner.generation,
    });

    try runner.bindRuntime(.{
        .session = undefined,
        .ui = null,
        .command_actions = null,
        .get_model = &testGetModel,
        .is_idle = &testIsIdle,
        .abort = &testAbort,
        .has_pending_messages = &testHasPendingMessages,
        .shutdown = null,
        .get_context_usage = &testGetContextUsage,
        .get_system_prompt = &testGetSystemPrompt,
        .get_binding_info = &testGetBindingInfo,
    }, &provider_registry);

    try std.testing.expectEqual(@as(usize, 0), runner.provider_queue.count());
    try std.testing.expectEqualStrings("proxy", provider_registry.get("anthropic-messages").?.getName());
    try std.testing.expect(oauth_mod.findProvider("proxy") != null);
    try std.testing.expect(oauth_mod.findProvider("anthropic-messages") == null);

    runner.unbindRuntime();
    try std.testing.expectEqualStrings("faux", provider_registry.get("anthropic-messages").?.getName());
    try std.testing.expect(oauth_mod.findProvider("proxy") == null);
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
        .owned = true,
    });
    try std.testing.expect(accepted);

    // Event: pure append.
    try runner.event_registry.subscribe(.tool_call, .{ .lua_ref = 8, .source_id = "task.lua" });

    // Provider queue: pre-bind enqueue, never drained in this test.
    try runner.provider_queue.enqueueRegister(.{
        .name = try allocator.dupe(u8, "proxy"),
        .api = try allocator.dupe(u8, "anthropic-messages"),
        .base_url = try allocator.dupe(u8, "https://proxy.example"),
        .owner_id = try allocator.dupe(u8, "task.lua"),
        .generation = runner.generation,
    });

    try std.testing.expectEqual(@as(usize, 1), runner.tool_registry.count());
    try std.testing.expectEqual(@as(usize, 1), runner.event_registry.count());
    try std.testing.expectEqual(@as(usize, 1), runner.provider_queue.count());
    // deinit (via defer) frees everything; testing.allocator catches leaks.
}
