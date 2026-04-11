const std = @import("std");
const posix = std.posix;
const cell_mod = @import("cell.zig");
const buffer_mod = @import("buffer.zig");
const renderer_mod = @import("renderer.zig");
const terminal_mod = @import("terminal.zig");
const keys_mod = @import("keys.zig");
const component_mod = @import("component.zig");
const text_mod = @import("components/text.zig");
const greeter_mod = @import("components/greeter.zig");
const footer_mod = @import("components/footer.zig");
const editor_mod = @import("components/editor.zig");
const loader_mod = @import("components/loader.zig");
const ui_event_mod = @import("ui_event.zig");
const transcript_mod = @import("transcript.zig");
const container_mod = @import("container.zig");
const overlay_mod = @import("overlay.zig");
const tool_display_mod = @import("tool_display.zig");
const theme_mod = @import("theme.zig");
const tui_mod = @import("tui.zig");
const editor_iface_mod = @import("editor_iface.zig");
const input_buffer_mod = @import("input_buffer.zig");
const status_data_mod = @import("status_data.zig");

const autocomplete_mod = @import("autocomplete.zig");
const slash_commands_mod = @import("../slash_commands.zig");
const AutocompleteProvider = autocomplete_mod.AutocompleteProvider;
const SlashCommandProvider = autocomplete_mod.SlashCommandProvider;
const CommandRegistry = slash_commands_mod.CommandRegistry;
const list_picker_mod = @import("components/list_picker.zig");
const select_list_mod = @import("components/select_list.zig");
const ListPicker = list_picker_mod.ListPicker;
const SelectItem = select_list_mod.SelectItem;
const session_store_mod = @import("../session/store.zig");
const SessionStore = session_store_mod.SessionStore;
const storage = @import("../storage.zig");

const agent_mod = @import("../agent/root.zig");
const coding_agent_mod = @import("../coding_agent.zig");
const session_controller_mod = @import("../session_controller.zig");
const AgentEvent = agent_mod.protocol.AgentEvent;
const AgentToolResult = agent_mod.protocol.AgentToolResult;
const AgentRequest = agent_mod.AgentRequest;
const RequestQueue = agent_mod.RequestQueue;
const ResumedAssistantBlock = ui_event_mod.ResumedAssistantBlock;
const ResumedEntry = ui_event_mod.ResumedEntry;
const agent_protocol = agent_mod.protocol;
const SessionController = session_controller_mod.SessionController;
const RetryPolicy = session_controller_mod.RetryPolicy;
const CompactionPolicy = session_controller_mod.CompactionPolicy;
const CompactionExecutor = session_controller_mod.CompactionExecutor;
const SessionEvent = session_controller_mod.SessionEvent;

/// Discriminates what a spawned agent worker thread is doing.
/// `prompt` is the classic path (subscribe + ca.run); `drain_only`
/// is zi-wub.15's spawn-on-idle for request-queue work when no
/// prompt is in flight. Both paths drain AgentRequests at the top.
/// See oracle review on zi-wub.15 for why this is one thread fn
/// with a work discriminator rather than two entry points.
const AgentWork = union(enum) {
    prompt: []const u8,
    drain_only: void,
};
const AgentSession = coding_agent_mod.AgentSession;
const json_util = @import("../ai/json_util.zig");
const auth_storage_mod = @import("../auth/storage.zig");
const oauth_mod = @import("../auth/oauth.zig");
const settings_manager_mod = @import("../settings/manager.zig");
const ai_protocol = @import("../ai/protocol.zig");
const ai_resolve = @import("../ai/resolve.zig");
const memory_debug = @import("../debug/tracked_allocator.zig");

const Color = cell_mod.Color;
const Region = buffer_mod.Region;
const Terminal = terminal_mod.Terminal;
const Renderer = renderer_mod.Renderer;
const Key = keys_mod.Key;
const Component = component_mod.Component;
const CursorState = component_mod.CursorState;
const UiEvent = ui_event_mod.UiEvent;
const Transcript = transcript_mod.Transcript;
const ToolRendererResolver = tool_display_mod.ToolRendererResolver;
const Loader = loader_mod.Loader;
const TUI = tui_mod.TUI;
const EditorInterface = editor_iface_mod.EditorInterface;
const StatusData = status_data_mod.StatusData;

/// Thread-safe queue: agent thread pushes, main thread drains.
fn EventQueue(comptime T: type) type {
    return struct {
        items: std.ArrayListUnmanaged(T) = .empty,
        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.items.deinit(self.allocator);
        }

        pub fn push(self: *Self, item: T) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.items.append(self.allocator, item) catch {
                var mutable = item;
                if (@hasDecl(T, "deinit")) {
                    mutable.deinit(self.allocator);
                }
                return;
            };
            self.cond.signal();
        }

        pub fn drainInto(self: *Self, out: []T) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            const count = @min(self.items.items.len, out.len);
            if (count == 0) return 0;
            @memcpy(out[0..count], self.items.items[0..count]);
            if (count < self.items.items.len) {
                const remaining = self.items.items.len - count;
                std.mem.copyForwards(T, self.items.items[0..remaining], self.items.items[count .. count + remaining]);
            }
            self.items.items.len -= count;
            return count;
        }
    };
}

/// Interactive mode — wires AgentSession (blocking on its thread)
/// to the TUI (main thread) via a thread-safe event queue.
///
/// Uses UiEvent (deep-copied) instead of raw AgentEvent to ensure
/// no borrowed pointers cross the thread boundary.
///
/// Composes TUI (reusable rendering/focus/overlay infrastructure)
/// with domain-specific state (editor, transcript, agent, containers).
pub const Interactive = struct {
    allocator: std.mem.Allocator,
    /// Thread-safe GPA-backed allocator for cross-thread message
    /// payloads and queue backing storage (zi-wub.8). Used by phase 3
    /// migrations (.9 EventQueue backing, .10 convertAgentEvent
    /// clones, .14 AgentRequest queue, .17 login callbacks). NOT the
    /// same as `allocator` (which is the shared arena) — this one
    /// wraps the root GPA directly so cross-thread free paths work.
    /// See .zi/design-notes/threading-doctrine.md R2/R3.
    msg_allocator: std.mem.Allocator,
    tui: TUI,
    theme: *const theme_mod.Theme = &theme_mod.Theme.dark,

    // ── Owned components ──────────────────────────────────────────
    editor: editor_mod.Editor,
    /// Active editor interface — routes paste/newline/ctrl+d/clear.
    /// Defaults to the built-in editor. Extensions can swap via setEditor().
    /// Initialized in init() after self.editor is set up.
    active_editor: EditorInterface = undefined,
    status_text: text_mod.Text,
    greeter: greeter_mod.Greeter,
    footer: footer_mod.Footer,
    transcript: Transcript,
    resolver: ToolRendererResolver,
    status_data: StatusData,
    loader: Loader = .{},
    loader_active: bool = false,
    retry_active: bool = false,
    retry_waiting: bool = false,
    retry_attempt: u32 = 0,
    retry_max_attempts: u32 = 0,

    // ── Container slots (pi-mono parity) ──────────────────────────
    header_container: container_mod.Container,
    pending_container: container_mod.Container,
    status_container: container_mod.Container,
    widget_above_container: container_mod.Container,
    editor_container: container_mod.Container,
    widget_below_container: container_mod.Container,

    // ── Slash commands ──────────────────────────────────────────
    command_registry: CommandRegistry,
    slash_provider: SlashCommandProvider = undefined,

    // ── Session picker (for /resume) ────────────────────────────
    session_picker: ListPicker = undefined,
    session_picker_items: [64]SelectItem = undefined,
    session_picker_paths: [64][]const u8 = undefined,
    session_picker_count: usize = 0,
    session_picker_handle: ?tui_mod.OverlayHandle = null,

    // ── Model picker (for /model) ───────────────────────────────
    auth_storage: *auth_storage_mod.AuthStorage,
    settings_manager: *settings_manager_mod.SettingsManager,
    /// Borrowed slice of the session's ModelRegistry. Bound at init
    /// from `ca.model_registry.getAll()`. Lifetime: AgentSession
    /// outlives Interactive, and the registry is immutable for the
    /// session lifetime, so the slice is stable.
    model_catalog: []const ai_protocol.Model = &.{},
    model_picker: ListPicker = undefined,
    model_picker_items: [512]SelectItem = undefined,
    model_picker_search_texts: [512][]const u8 = undefined,
    model_picker_models: [512]ai_protocol.Model = undefined,
    model_picker_count: usize = 0,
    model_picker_handle: ?tui_mod.OverlayHandle = null,

    // ── Login state (/login) ────────────────────────────────────────
    login_picker: ListPicker = undefined,
    login_picker_items: [8]SelectItem = undefined,
    login_picker_count: usize = 0,
    login_picker_handle: ?tui_mod.OverlayHandle = null,
    login_thread: ?std.Thread = null,
    login_cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    event_queue: EventQueue(UiEvent),
    /// TUI → agent mutation channel (zi-wub.14). TUI thread enqueues
    /// AgentRequest values, the agent thread drains at turn boundary.
    /// See `src/agent/request.zig` and the threading doctrine.
    /// Consumers land in zi-wub.15 (/resume) and .16 (/model); .14
    /// only introduces the channel, so the queue is wired but no one
    /// pushes to it yet. Backed by `msg_allocator` per doctrine R3.
    request_queue: RequestQueue,
    ca: *AgentSession,
    memory_diagnostics: *const memory_debug.Diagnostics,
    session_controller: SessionController,
    session_event_token: ?SessionController.SubscriptionToken = null,
    agent_thread: ?std.Thread = null,
    running: bool = true,
    is_streaming: bool = false,
    last_ctrl_c_ns: i128 = 0,
    tool_output_expanded: bool = false,
    hide_thinking_block: bool = false,
    greeter_dismissed: bool = false,
    /// Input sequence buffer — handles split escape sequences, paste, kitty negotiation.
    input: input_buffer_mod.InputBuffer,
    /// Kitty protocol negotiation: deadline (ns timestamp) for query response.
    /// null = negotiation complete.
    kitty_deadline_ns: ?i128 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        msg_allocator: std.mem.Allocator,
        ca: *AgentSession,
        memory_diagnostics: *const memory_debug.Diagnostics,
        resolver: ToolRendererResolver,
        cwd: []const u8,
        auth_storage: *auth_storage_mod.AuthStorage,
        settings_manager: *settings_manager_mod.SettingsManager,
        retry_policy: RetryPolicy,
        compaction_policy: CompactionPolicy,
        compaction_executor: ?CompactionExecutor,
    ) !Interactive {
        _ = allocator;
        const theme = &theme_mod.Theme.dark;
        const state_allocator = memory_diagnostics.tui.allocator();

        var self: Interactive = .{
            .allocator = state_allocator,
            .msg_allocator = msg_allocator,
            .tui = try TUI.init(state_allocator),
            .theme = theme,
            .editor = editor_mod.Editor.init(state_allocator),
            .status_text = text_mod.Text.init(state_allocator),
            .greeter = .{ .theme = theme, .version = "0.1.0" },
            .footer = .{ .theme = theme },
            .transcript = Transcript.init(state_allocator),
            .resolver = resolver,
            .status_data = StatusData.init(state_allocator),
            .header_container = container_mod.Container.init(state_allocator),
            .pending_container = container_mod.Container.init(state_allocator),
            .status_container = container_mod.Container.init(state_allocator),
            .widget_above_container = container_mod.Container.init(state_allocator),
            .editor_container = container_mod.Container.init(state_allocator),
            .widget_below_container = container_mod.Container.init(state_allocator),
            .command_registry = CommandRegistry.init(state_allocator),
            .input = input_buffer_mod.InputBuffer.init(state_allocator),
            .event_queue = EventQueue(UiEvent).init(msg_allocator),
            .request_queue = RequestQueue.init(msg_allocator),
            .ca = ca,
            .memory_diagnostics = memory_diagnostics,
            .session_controller = SessionController.init(state_allocator, ca, .{
                .retry_policy = retry_policy,
                .compaction_policy = compaction_policy,
                .compaction_executor = compaction_executor,
            }),
            .auth_storage = auth_storage,
            .settings_manager = settings_manager,
            .model_catalog = if (ca.model_registry) |mr| mr.getAll() else &.{},
        };
        // Wire the extension runner into the transcript so
        // tool_execution_end can dispatch Lua render_result hooks
        // for tools that registered one. Null in tests or
        // extensionless modes; the transcript no-ops gracefully.
        self.transcript.lua_runner = ca.extensionRunner();

        self.editor.prompt_fg = theme.fg(.muted);
        self.editor.border_color = theme.fg(.border_muted);
        self.loader.spinner_fg = theme.fg(.accent);
        self.loader.message_fg = theme.fg(.muted);
        self.status_data.model_id = ca.agent.state.model.id;
        self.status_data.thinking_level = agentThinkingLabel(ca.agent.state.thinking_level);
        self.editor.cwd = cwd;
        self.hide_thinking_block = settings_manager.getHideThinkingBlock();
        self.transcript.setHideThinkingBlock(self.hide_thinking_block);
        // NOTE: status_data pointer and active_editor are bound in run() where
        // self is at its final address. Binding here would capture a pointer to
        // the local `self` that becomes dangling after the by-value return.
        self.transcript.theme = theme;
        return self;
    }

    pub fn deinit(self: *Interactive) void {
        // Cancel and join login thread if active
        if (self.login_thread != null) {
            self.login_cancelled.store(true, .release);
            if (self.login_thread) |t| t.join();
            self.login_thread = null;
        }
        // zi-wub.28: if a prompt is mid-flight, abort + join it
        // before doing anything else. The next steps spawn a fresh
        // drain_only worker that rebinds the lua owner; the runner
        // contract requires the previous thread to be fully joined.
        if (self.agent_thread) |t| {
            if (self.is_streaming) self.ca.agent.abort();
            t.join();
            self.agent_thread = null;
            self.is_streaming = false;
        }

        // zi-wub.28: shutdown the extension runner + lua_State on
        // the agent thread. We:
        //   1. drain + free any stale pending requests (a queued
        //      /resume or /model whose result event will never be
        //      consumed — quit semantics > best-effort delivery)
        //   2. null transcript.lua_runner so any late refresh path
        //      can't dereference a freed runner
        //   3. push .shutdown, spawn one final drain_only worker,
        //      join it. The worker binds owner, drains, calls
        //      ca.shutdownExtensionsOnAgentThread() which nulls the
        //      ext fields so the upcoming ca.deinit() skips them.
        //
        // Skipped entirely if there's no extension runner (tests,
        // extensionless mode) — nothing to tear down on the agent
        // thread, plain ca.deinit() handles it.
        if (self.ca.extensionRunner() != null) {
            var stale: [16]AgentRequest = undefined;
            while (true) {
                const n = self.request_queue.drainInto(&stale);
                if (n == 0) break;
                for (stale[0..n]) |*req| req.deinit(self.msg_allocator);
            }
            self.transcript.lua_runner = null;
            self.request_queue.push(.{ .shutdown = {} });
            const t = std.Thread.spawn(.{}, agentThreadFn, .{ self, AgentWork{ .drain_only = {} } }) catch null;
            if (t) |handle| handle.join();
        }

        if (self.session_event_token) |token| {
            self.session_controller.unsubscribe(token);
            self.session_event_token = null;
        }
        self.session_controller.deinit();

        // drain and free any remaining events
        var drain_buf: [64]UiEvent = undefined;
        while (true) {
            const count = self.event_queue.drainInto(&drain_buf);
            if (count == 0) break;
            for (drain_buf[0..count]) |*ev| ev.deinit(self.msg_allocator);
        }
        self.freeModelPickerSearchTexts();
        self.command_registry.deinit();
        self.status_data.deinit();
        self.input.deinit();
        self.event_queue.deinit();
        // Drain any leftover requests (no consumers in .14, but be
        // defensive once .15+ start pushing). Agent thread is joined
        // above, so this runs without contention.
        self.request_queue.deinit();
        self.widget_below_container.deinit();
        self.editor_container.deinit();
        self.widget_above_container.deinit();
        self.status_container.deinit();
        self.pending_container.deinit();
        self.header_container.deinit();
        self.transcript.deinit();
        self.status_text.deinit();
        self.editor.deinit();
        self.tui.deinit();
    }

    /// Main loop — runs on the main thread.
    pub fn run(self: *Interactive) !void {
        try self.tui.terminal.enterRawMode();
        self.tui.terminal.installSignalHandlers();
        self.tui.terminal.hideCursor();
        self.tui.terminal.enableBracketedPaste();
        self.tui.terminal.queryKittyProtocol();
        self.tui.terminal.enableMouseTracking();
        self.kitty_deadline_ns = std.time.nanoTimestamp() + 150_000_000; // 150ms

        self.detectGitBranch();

        self.editor.on_submit = &onEditorSubmit;
        self.editor.on_submit_ctx = @ptrCast(self);
        self.session_controller.wire();
        self.session_event_token = self.session_controller.subscribe(&sessionEventCallback, @ptrCast(self));

        // Bind pointers now that self is at its stable address (not a stack copy).
        self.editor.status_data = &self.status_data;
        self.editor.theme = self.theme;

        // Wire autocomplete: registry → provider → editor
        self.slash_provider = SlashCommandProvider.init(&self.command_registry);
        self.editor.setAutocompleteProvider(self.slash_provider.provider());

        self.active_editor = EditorInterface.init(editor_mod.Editor, &self.editor);

        // Populate container slots with their initial children.
        self.refreshGreeterVisibility();
        self.status_container.addChild(self.status_text.component());
        self.editor_container.addChild(self.active_editor.component());
        self.editor_container.focused_child_index = 0; // for cursor y-offset translation

        // Set initial focus via TUI (source of truth for input routing)
        self.tui.setFocus(self.active_editor.component());

        // Build root tree matching pi-mono slot structure:
        // headerContainer → chat(flex) → pending → status → widget_above → editor(focused) → widget_below → footer
        self.tui.root.addChild(self.header_container.component()); // [0] headerContainer
        self.tui.root.addChild(self.transcript.component()); // [1] chat (flex)
        self.tui.root.addChild(self.pending_container.component()); // [2] pendingContainer
        self.tui.root.addChild(self.status_container.component()); // [3] statusContainer
        self.tui.root.addChild(self.widget_above_container.component()); // [4] widgetAboveContainer
        self.tui.root.addChild(self.editor_container.component()); // [5] editorContainer
        self.tui.root.addChild(self.widget_below_container.component()); // [6] widgetBelowContainer
        self.tui.root.flex_child_index = 1; // transcript is flex
        self.tui.root.focused_child_index = 5; // editorContainer for cursor y-offset

        self.tui.dirty = true;

        while (self.running) {
            // 1. Drain UI events (owned, thread-safe)
            var event_buf: [64]UiEvent = undefined;
            const count = self.event_queue.drainInto(&event_buf);
            for (event_buf[0..count]) |*ev| {
                self.handleUiEvent(ev);
                ev.deinit(self.msg_allocator);
            }

            // 2. Poll terminal input (non-blocking: MIN=0, TIME=0)
            var input_raw: [4096]u8 = undefined;
            const n = self.tui.terminal.readInput(&input_raw) catch 0;
            if (n > 0) {
                // During kitty negotiation, buffer input and check for response
                if (self.kitty_deadline_ns != null) {
                    self.input.buf.appendSlice(self.allocator, input_raw[0..n]) catch {};
                    if (self.input.consumeKittyResponse()) {
                        self.tui.terminal.enableKittyProtocol();
                        self.kitty_deadline_ns = null;
                        // Drain buffered input now that kitty is active
                        self.input.drain(&onInputSequence, &onInputPaste, @ptrCast(self));
                    }
                    // Still negotiating — hold bytes for timeout
                    continue;
                }
                // Feed through InputBuffer — emits complete sequences via callbacks
                self.input.feed(input_raw[0..n], &onInputSequence, &onInputPaste, @ptrCast(self));
            }

            // 2b. Check InputBuffer timeout (lone ESC, incomplete sequences)
            self.input.checkTimeout(&onInputSequence, @ptrCast(self));

            // 2c. Kitty negotiation timeout → fall back to modifyOtherKeys
            if (self.kitty_deadline_ns) |deadline| {
                if (std.time.nanoTimestamp() >= deadline) {
                    self.tui.terminal.enableModifyOtherKeys();
                    self.kitty_deadline_ns = null;
                    // Drain any buffered input from negotiation period
                    if (self.input.buf.items.len > 0) {
                        self.input.drain(&onInputSequence, &onInputPaste, @ptrCast(self));
                    }
                }
            }

            // 3. Check for terminal resize
            _ = self.tui.checkResize();

            // 3b. Tick loader animation
            if (self.loader_active) {
                if (self.loader.tick()) {
                    self.tui.dirty = true;
                }
            }
            // 4. Render if dirty
            if (self.tui.dirty) {
                self.renderFrame();
                self.tui.dirty = false;
            }

            // 5. Brief sleep to avoid busy-wait (1ms)
            std.Thread.sleep(1_000_000);
        }
    }

    // ── InputBuffer callbacks ───────────────────────────────────────

    /// Called by InputBuffer for each complete input sequence.
    fn onInputSequence(seq: []const u8, raw_ctx: *anyopaque) void {
        const self: *Interactive = @ptrCast(@alignCast(raw_ctx));

        // Bare \n = newline insertion (some terminals send this for shift+enter)
        if (seq.len == 1 and seq[0] == '\n') {
            self.active_editor.insertText("\n");
            self.refreshGreeterVisibility();
            self.tui.dirty = true;
            return;
        }

        const result = keys_mod.parseInput(seq, self.tui.terminal.kitty_active) orelse return;
        switch (result) {
            .key => |k| self.handleKey(k.key),
            .mouse => |m| self.handleMouse(m.event),
        }
    }

    /// Called by InputBuffer when paste content is complete.
    fn onInputPaste(content: []const u8, raw_ctx: *anyopaque) void {
        const self: *Interactive = @ptrCast(@alignCast(raw_ctx));
        self.active_editor.insertText(content);
        self.refreshGreeterVisibility();
        self.tui.dirty = true;
    }

    fn handleKey(self: *Interactive, key: Key) void {
        // When an overlay has focus, route input there FIRST.
        // Overlays own Esc/Ctrl+C for dismiss — app-level handlers are fallbacks.
        if (self.tui.hasOverlay()) {
            if (self.tui.handleInput(key)) {
                self.tui.dirty = true;
                return;
            }
            // Overlay didn't consume it — Esc dismisses the topmost overlay
            if (key.code == .escape) {
                self.tui.hideOverlay();
                return;
            }
            // Ctrl+C also dismisses overlay instead of exiting
            if (key.code == .char and key.char != null and key.char.? == 'c' and key.ctrl) {
                self.tui.hideOverlay();
                return;
            }
            return;
        }

        // App-level keybindings — no overlay active
        if (key.code == .escape) {
            if (self.retry_waiting) {
                self.session_controller.abortRetry();
                return;
            }
            if (self.is_streaming) {
                self.ca.agent.abort();
                self.status_text.setContent("aborted");
                self.status_text.fg = self.theme.fg(.@"error");
                self.tui.dirty = true;
            }
            return;
        }

        // Ctrl+C: double-tap guard (pi-mono parity)
        // First press: clear editor. Second press within 500ms: exit.
        if (key.code == .char and key.char != null and key.char.? == 'c' and key.ctrl) {
            if (self.login_thread != null) {
                self.login_cancelled.store(true, .release);
                return;
            }
            if (self.retry_waiting) {
                self.session_controller.abortRetry();
                return;
            }
            if (self.is_streaming) {
                self.ca.agent.abort();
                self.status_text.setContent("aborted");
                self.status_text.fg = self.theme.fg(.@"error");
                self.tui.dirty = true;
                return;
            }
            const now = std.time.nanoTimestamp();
            const double_tap_ns: i128 = 500 * std.time.ns_per_ms;
            if (now - self.last_ctrl_c_ns < double_tap_ns) {
                self.running = false;
                return;
            }
            self.active_editor.clear();
            self.refreshGreeterVisibility();
            self.last_ctrl_c_ns = now;
            self.tui.dirty = true;
            return;
        }

        // Ctrl+D: exit only when editor is empty (pi-mono parity)
        if (key.code == .char and key.char != null and key.char.? == 'd' and key.ctrl) {
            if (self.active_editor.getText().len == 0) {
                self.running = false;
                return;
            }
        }

        // ctrl+o — toggle tool output expansion
        if (key.code == .char and key.char != null and key.char.? == 'o' and key.ctrl) {
            self.tool_output_expanded = !self.tool_output_expanded;
            self.transcript.setToolOutputExpanded(self.tool_output_expanded);
            self.tui.dirty = true;
            return;
        }

        // ctrl+t — toggle thinking block visibility
        if (key.code == .char and key.char != null and key.char.? == 't' and key.ctrl) {
            self.hide_thinking_block = !self.hide_thinking_block;
            self.settings_manager.setHideThinkingBlock(self.hide_thinking_block);
            self.transcript.setHideThinkingBlock(self.hide_thinking_block);
            self.tui.dirty = true;
            return;
        }

        // scroll: page up/down, shift+up/down
        if (self.handleScroll(key)) return;

        // Route to focused component via TUI
        if (self.tui.handleInput(key)) {
            self.refreshGreeterVisibility();
            self.tui.dirty = true;
        }
    }

    fn handleScroll(self: *Interactive, key: Key) bool {
        const output_h = self.outputHeight();
        if (output_h == 0) return false;

        const page_size = @max(1, output_h -| 2);

        const delta: ?i64 = switch (key.code) {
            .page_up => -@as(i64, @intCast(page_size)),
            .page_down => @as(i64, @intCast(page_size)),
            .up => if (key.shift) @as(i64, -3) else null,
            .down => if (key.shift) @as(i64, 3) else null,
            else => null,
        };

        if (delta) |d| {
            const w = self.tui.width();
            self.transcript.scrollBy(w, output_h, d);
            self.tui.dirty = true;
            return true;
        }
        return false;
    }

    fn handleMouse(self: *Interactive, event: keys_mod.MouseEvent) void {
        switch (event.button) {
            .scroll_up => {
                const w = self.tui.width();
                const output_h = self.outputHeight();
                self.transcript.scrollBy(w, output_h, -3);
                self.tui.dirty = true;
            },
            .scroll_down => {
                const w = self.tui.width();
                const output_h = self.outputHeight();
                self.transcript.scrollBy(w, output_h, 3);
                self.tui.dirty = true;
            },
            else => {},
        }
    }

    fn handleUiEvent(self: *Interactive, ev: *UiEvent) void {
        switch (ev.*) {
            .assistant_text_delta => |d| {
                self.transcript.appendText(d.content_index, d.delta);
                self.tui.dirty = true;
            },
            .assistant_thinking_delta => |d| {
                self.transcript.appendThinking(d.content_index, d.delta);
                self.tui.dirty = true;
            },
            .error_message => |e| {
                self.status_text.setContent(e.message);
                self.status_text.fg = self.theme.fg(.@"error");
                self.tui.dirty = true;
            },
            .message_start_assistant => {
                self.transcript.beginAssistantMessage();
                self.tui.dirty = true;
            },
            .message_start_user => {},
            .tool_call_streaming => |t| {
                const renderer = self.resolver.resolve(t.tool_name);
                self.transcript.addToolExecution(t.tool_call_id, t.tool_name, renderer);
                self.transcript.toolSetArgs(t.tool_call_id, t.args);
                if (t.is_complete) self.transcript.toolSetArgsComplete(t.tool_call_id);
                self.tui.dirty = true;
            },
            .message_end_assistant => |m| {
                if (m.is_aborted) {
                    self.status_text.setContent(m.error_message orelse "aborted");
                    self.status_text.fg = self.theme.fg(.@"error");
                    self.tui.dirty = true;
                } else if (m.error_message) |msg| {
                    self.status_text.setContent(userFacingFailureMessage(m.failure_kind, msg));
                    self.status_text.fg = self.theme.fg(.@"error");
                    self.tui.dirty = true;
                }
            },
            .tool_start => |t| {
                const renderer = self.resolver.resolve(t.tool_name);
                self.transcript.addToolExecution(t.tool_call_id, t.tool_name, renderer);
                self.transcript.toolSetArgs(t.tool_call_id, t.args);
                self.transcript.toolMarkExecutionStarted(t.tool_call_id);
                self.status_text.setContent(t.tool_name);
                self.status_text.fg = self.theme.fg(.accent);
                self.tui.dirty = true;
            },
            .tool_update => |t| {
                self.transcript.toolSetPartialResult(t.tool_call_id, t.result, t.is_error);
                self.tui.dirty = true;
            },
            .tool_end => |t| {
                self.transcript.toolSetFinalResult(t.tool_call_id, t.result, t.is_error);
                self.tui.dirty = true;
            },
            .login_progress => |l| {
                self.status_text.setContent(l.message);
                self.status_text.fg = switch (l.kind) {
                    .auth_url => self.theme.fg(.accent),
                    .info => self.theme.fg(.muted),
                };
                self.tui.dirty = true;
            },
            .login_complete => |l| {
                if (self.login_thread) |t| t.join();
                self.login_thread = null;

                if (l.success) {
                    self.status_text.setContent(l.message);
                    self.status_text.fg = self.theme.fg(.success);
                    self.status_data.model_id = self.ca.agent.state.model.id;
                    self.status_data.thinking_level = agentThinkingLabel(self.ca.agent.state.thinking_level);
                } else {
                    self.status_text.setContent(l.message);
                    self.status_text.fg = self.theme.fg(.@"error");
                }
                self.tui.dirty = true;
            },
            .retry_start => |r| {
                self.retry_active = true;
                self.retry_waiting = true;
                self.retry_attempt = r.attempt;
                self.retry_max_attempts = r.max_attempts;
                self.showRetryLoader(r.attempt, r.max_attempts, r.delay_ms, true);
                self.tui.dirty = true;
            },
            .retry_wait_finished => {
                self.retry_waiting = false;
                if (self.retry_active) {
                    self.showRetryLoader(self.retry_attempt, self.retry_max_attempts, 0, false);
                }
                self.tui.dirty = true;
            },
            .retry_end => |r| {
                self.retry_active = false;
                self.retry_waiting = false;
                self.retry_attempt = 0;
                self.retry_max_attempts = 0;
                self.hideLoader();
                if (!r.success) {
                    var buf: [160]u8 = undefined;
                    const msg = std.fmt.bufPrint(
                        &buf,
                        "retry failed after {d} attempt{s}: {s}",
                        .{ r.attempt, if (r.attempt == 1) "" else "s", r.final_error orelse "unknown error" },
                    ) catch (r.final_error orelse "retry failed");
                    self.status_text.setContent(msg);
                    self.status_text.fg = self.theme.fg(.@"error");
                }
                self.tui.dirty = true;
            },
            .prompt_worker_finished => |p| {
                self.is_streaming = false;
                if (self.agent_thread) |t| t.join();
                self.agent_thread = null;
                self.hideLoader();
                self.tui.setFocus(self.active_editor.component());
                switch (p.outcome) {
                    .success => self.status_text.setContent(""),
                    .assistant_error, .aborted => {},
                }
                if (p.internal_error) |msg| {
                    self.status_text.setContent(msg);
                    self.status_text.fg = self.theme.fg(.@"error");
                }
                self.tui.dirty = true;
            },
            .request_worker_finished => {
                // zi-wub.15: drain-only worker completed. Just join
                // and hide the loader — do NOT touch status_text or
                // focus here, the individual request handlers
                // (.session_resumed / .session_resume_failed) owned
                // that UI state already. See oracle note on why this
                // is separate from prompt cleanup.
                if (self.agent_thread) |t| t.join();
                self.agent_thread = null;
                self.hideLoader();
                self.tui.dirty = true;
            },
            .session_resumed => |r| {
                self.transcript.clearAll();
                for (r.entries) |entry| {
                    switch (entry) {
                        .user_text => |t| self.transcript.addUserMessage(t),
                        .assistant_message => |blocks| {
                            self.transcript.beginAssistantMessage();
                            for (blocks, 0..) |block, idx| {
                                switch (block) {
                                    .text => |t| self.transcript.appendText(idx, t),
                                    .thinking => |t| self.transcript.appendThinking(idx, t),
                                }
                            }
                        },
                    }
                }
                self.transcript.scrollToBottom(self.tui.width(), self.outputHeight());
                // Prefer the restore warning over the generic
                // "session resumed" banner when a fallback happened
                // — users need to see why their saved model isn't
                // the one they're about to talk to. Otherwise default
                // to the success banner.
                if (r.restore_warning) |w| {
                    self.status_text.setContent(w);
                    self.status_text.fg = self.theme.fg(.warning);
                } else {
                    self.status_text.setContent("session resumed");
                    self.status_text.fg = self.theme.fg(.success);
                }
                self.tui.dirty = true;
            },
            .session_resume_failed => |f| {
                self.status_text.setContent(f.message);
                self.status_text.fg = self.theme.fg(.@"error");
                self.tui.dirty = true;
            },
            .model_switch_failed => |m| {
                self.status_text.setContent(m.message);
                self.status_text.fg = self.theme.fg(.@"error");
                self.tui.dirty = true;
            },
            .model_switched => |m| {
                // status_data.model_id is a borrow into the live
                // model in agent state — agent thread already
                // updated ca.agent.state.model, so reading it here
                // is safe (the catalog slice is static, no race).
                self.status_data.model_id = self.ca.agent.state.model.id;
                self.status_data.thinking_level = agentThinkingLabel(self.ca.agent.state.thinking_level);
                self.settings_manager.setDefaultModelAndProvider(m.provider, m.id);
                var buf: [80]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Model: {s}", .{m.id}) catch "model switched";
                self.status_text.setContent(msg);
                self.status_text.fg = self.theme.fg(.success);
                self.tui.dirty = true;
            },
        }
    }

    fn outputHeight(self: *Interactive) u32 {
        const h = self.tui.height();
        const w = self.tui.width();
        const max_h = @max(3, h * 30 / 100);
        self.editor.max_visible_lines = max_h;

        // Sum all non-flex children's measured heights
        var fixed_total: u32 = 0;
        for (self.tui.root.children.items, 0..) |child, i| {
            if (self.tui.root.flex_child_index != null and i == self.tui.root.flex_child_index.?) continue;
            var c = child;
            fixed_total += c.measure(w).preferred_height;
        }
        return if (h > fixed_total) h - fixed_total else 0;
    }

    fn refreshGreeterVisibility(self: *Interactive) void {
        if (!self.greeter_dismissed and self.active_editor.getText().len > 0) {
            self.greeter_dismissed = true;
        }
        self.widget_above_container.clear();
        if (!self.greeter_dismissed) {
            self.widget_above_container.addChild(self.greeter.component());
        }
    }

    fn showLoader(self: *Interactive, message: []const u8) void {
        self.loader.spinner_fg = self.theme.fg(.accent);
        self.loader.message_fg = self.theme.fg(.muted);
        self.loader.setMessage(message);
        self.loader.start();
        self.loader_active = true;
        self.status_container.clear();
        self.status_container.addChild(self.loader.component());
    }

    fn showRetryLoader(self: *Interactive, attempt: u32, max_attempts: u32, delay_ms: u64, cancellable: bool) void {
        var buf: [128]u8 = undefined;
        const delay_seconds = @divTrunc(delay_ms + 500, 1000);
        const message = if (cancellable)
            std.fmt.bufPrint(
                &buf,
                "Retrying ({d}/{d}) in {d}s... (Esc to cancel)",
                .{ attempt, max_attempts, delay_seconds },
            ) catch "Retrying..."
        else
            std.fmt.bufPrint(&buf, "Retrying ({d}/{d})...", .{ attempt, max_attempts }) catch "Retrying...";
        self.loader.spinner_fg = self.theme.fg(.warning);
        self.loader.message_fg = self.theme.fg(.muted);
        self.loader.setMessage(message);
        self.loader.start();
        self.loader_active = true;
        self.status_container.clear();
        self.status_container.addChild(self.loader.component());
    }

    fn hideLoader(self: *Interactive) void {
        if (!self.loader_active) return;
        self.loader.stop();
        self.loader_active = false;
        self.status_container.clear();
        self.status_container.addChild(self.status_text.component());
        // Don't blank status_text — preserve any error/abort message
        // that was set while the loader was active.
    }

    fn detectGitBranch(self: *Interactive) void {
        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "git", "rev-parse", "--abbrev-ref", "HEAD" },
            .max_output_bytes = 256,
        }) catch return;
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term.Exited == 0) {
            const branch = std.mem.trimRight(u8, result.stdout, " \t\n\r");
            if (branch.len > 0) {
                self.editor.setGitBranch(branch);
            }
        }
    }
    fn renderFrame(self: *Interactive) void {
        const w = self.tui.width();
        const h = self.tui.height();

        if (h < 3 or w < 10) {
            const region = self.tui.renderer.begin();
            _ = region.writeStr(0, 0, "terminal too small", self.theme.fg(.@"error"), Color.default, .{});
            self.tui.renderer.end() catch {};
            return;
        }

        // Update editor max height before layout measures it
        const max_h = @max(3, h * 30 / 100);
        self.editor.max_visible_lines = max_h;

        // Render via TUI (root tree + overlays) and get cursor state
        if (self.tui.render()) |cs| {
            self.tui.terminal.showCursor();
            self.tui.terminal.setCursorPos(cs.x, cs.y);
        } else {
            self.tui.terminal.hideCursor();
        }
    }

    // --- Editor submit callback ---

    fn onEditorSubmit(text: []const u8, ctx: ?*anyopaque) void {
        const self: *Interactive = @ptrCast(@alignCast(ctx));
        if (text.len == 0) return;

        // Slash command dispatch
        if (text[0] == '/') {
            if (self.dispatchSlashCommand(text)) return;
        }

        const prompt_copy = self.msg_allocator.dupe(u8, text) catch return;

        self.active_editor.clear();
        self.refreshGreeterVisibility();
        self.is_streaming = true;
        self.tui.setFocus(null); // defocus editor during streaming
        self.showLoader("Working...");
        self.tui.dirty = true;

        self.agent_thread = std.Thread.spawn(.{}, agentThreadFn, .{ self, AgentWork{ .prompt = prompt_copy } }) catch {
            self.is_streaming = false;
            self.tui.setFocus(self.active_editor.component());
            self.status_text.setContent("failed to start agent");
            self.status_text.fg = self.theme.fg(.@"error");
            self.msg_allocator.free(prompt_copy);
            return;
        };

        // Add user message after successful spawn (prompt_copy is safe to read here —
        // the agent thread doesn't free it until run() completes)
        self.transcript.addUserMessage(prompt_copy);
        self.transcript.scrollToBottom(self.tui.width(), self.outputHeight());
    }

    /// Dispatch a slash command. Returns true if handled (caller should not send to agent).
    fn dispatchSlashCommand(self: *Interactive, text: []const u8) bool {
        // Parse "/command args" → name="command", args="args"
        const after_slash = text[1..];
        const space_idx = std.mem.indexOfScalar(u8, after_slash, ' ');
        const name = if (space_idx) |si| after_slash[0..si] else after_slash;
        const args = if (space_idx) |si| std.mem.trimLeft(u8, after_slash[si + 1 ..], " ") else "";

        if (name.len == 0) return false;

        const cmd = self.command_registry.findCommand(name) orelse return false;

        self.active_editor.clear();
        self.refreshGreeterVisibility();
        self.tui.dirty = true;

        // Built-in commands with Interactive access
        if (cmd.source == .builtin) {
            if (std.mem.eql(u8, name, "quit")) {
                self.running = false;
                return true;
            }
            if (std.mem.eql(u8, name, "clear") or std.mem.eql(u8, name, "new")) {
                self.transcript.clearAll();
                self.status_text.setContent("");
                self.tui.dirty = true;
                return true;
            }
            if (std.mem.eql(u8, name, "resume")) {
                self.showSessionPicker();
                return true;
            }
            if (std.mem.eql(u8, name, "model")) {
                if (args.len > 0) {
                    self.switchModelDirect(args);
                } else {
                    self.showModelPicker();
                }
                return true;
            }
            if (std.mem.eql(u8, name, "login")) {
                if (args.len > 0) {
                    self.startLogin(args);
                } else {
                    self.showLoginPicker();
                }
                return true;
            }
            if (std.mem.eql(u8, name, "mem")) {
                self.writeMemoryDiagnostic();
                return true;
            }
        }

        switch (cmd.action) {
            .builtin => |handler| {
                var cmd_ctx = slash_commands_mod.CommandContext{ ._reserved = @ptrCast(self) };
                handler(args, &cmd_ctx) catch {
                    self.status_text.setContent("command failed");
                    self.status_text.fg = self.theme.fg(.@"error");
                };
            },
            .extension => |ext| {
                var cmd_ctx = slash_commands_mod.CommandContext{ ._reserved = @ptrCast(self) };
                ext.handler(args, &cmd_ctx, ext.user_ctx) catch {
                    self.status_text.setContent("extension command failed");
                    self.status_text.fg = self.theme.fg(.@"error");
                };
            },
            .prompt_template, .skill => {
                self.status_text.setContent("not yet implemented");
                self.status_text.fg = self.theme.fg(.warning);
            },
        }

        return true;
    }

    // ── App-level overlay presets ──────────────────────────────
    // These know about the Interactive layout (footer height, etc).
    // Generic presets live in overlay.zig (OverlayPresets).

    fn writeMemoryDiagnostic(self: *Interactive) void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const scratch = arena.allocator();

        const path = self.memory_diagnostics.writeSnapshotFile(scratch, self.editor.cwd, null) catch {
            self.status_text.setContent("failed to write memory diagnostics");
            self.status_text.fg = self.theme.fg(.@"error");
            return;
        };

        const agent_dir = storage.getAgentDir(scratch, null) catch null;
        const relative_path = if (agent_dir) |dir|
            if (std.mem.startsWith(u8, path, dir) and path.len > dir.len)
                std.mem.trimLeft(u8, path[dir.len..], std.fs.path.sep_str)
            else
                null
        else
            null;

        var status_buf: [256]u8 = undefined;
        const msg = if (relative_path) |rel|
            std.fmt.bufPrint(&status_buf, "wrote memory diagnostics: ~/.zi/agent/{s}", .{rel}) catch path
        else
            std.fmt.bufPrint(&status_buf, "wrote memory diagnostics: {s}", .{path}) catch path;
        self.status_text.setContent(msg);
        self.status_text.fg = self.theme.fg(.success);
    }

    fn bottomPanelOptions(self: *Interactive) overlay_mod.OverlayOptions {
        const width = self.tui.width();
        const header_h = self.header_container.measure(width).preferred_height;
        return .{
            .anchor = .bottom_left,
            .width_percent = 100,
            .max_height_percent = 40,
            .margin_bottom = 0,
            .margin_top = header_h,
        };
    }

    // ── Session picker (/resume) ────────────────────────────────

    fn showSessionPicker(self: *Interactive) void {
        // zi-wub.26: cwd lives on the TUI side (Interactive was
        // constructed with it; editor.cwd is the canonical copy).
        // Reading from ca.session_store.writer.cwd would reach into
        // agent-owned state from the TUI thread, violating the
        // doctrine. The session store path tracks the *current*
        // session's cwd which in zi is always the process cwd
        // (we don't support per-session cwd switching), so this is
        // strictly equivalent.
        const sessions = session_store_mod.listSessions(self.allocator, self.editor.cwd) catch {
            self.status_text.setContent("failed to list sessions");
            self.status_text.fg = self.theme.fg(.@"error");
            return;
        };

        if (sessions.len == 0) {
            self.status_text.setContent("no sessions found");
            self.status_text.fg = self.theme.fg(.muted);
            return;
        }

        // Build picker items: "first message preview" + "N msgs · relative time"
        const count = @min(sessions.len, self.session_picker_items.len);
        for (0..count) |i| {
            // Format description: "N msgs · time ago"
            var desc_buf: [64]u8 = undefined;
            const desc = std.fmt.bufPrint(&desc_buf, "{d} msgs \xC2\xB7 {s}", .{
                sessions[i].message_count,
                formatRelativeTime(sessions[i].timestamp),
            }) catch sessions[i].timestamp;

            self.session_picker_items[i] = .{
                .value = sessions[i].session_id,
                .label = sessions[i].first_message,
                .description = self.allocator.dupe(u8, desc) catch sessions[i].timestamp,
            };
            self.session_picker_paths[i] = sessions[i].path;
        }
        self.session_picker_count = count;

        // Set up picker with fuzzy search
        self.session_picker = ListPicker.init(self.theme);
        self.session_picker.title = "Resume session";
        self.session_picker.list.max_visible = 10;
        self.session_picker.setSearchableItems(self.session_picker_items[0..count], null);
        self.session_picker.on_select = &onSessionSelected;
        self.session_picker.on_cancel = &onSessionPickerCancel;
        self.session_picker.callback_ctx = @ptrCast(self);

        // Show as bottom panel overlay (ivy-style, preserves footer)
        self.session_picker_handle = self.tui.showOverlay(
            self.session_picker.component(),
            self.bottomPanelOptions(),
        );
    }

    fn onSessionSelected(item: *const SelectItem, ctx: ?*anyopaque) void {
        const self: *Interactive = @ptrCast(@alignCast(ctx));

        // Find the path for this selection
        var selected_path: ?[]const u8 = null;
        for (0..self.session_picker_count) |i| {
            if (std.mem.eql(u8, self.session_picker_items[i].value, item.value)) {
                selected_path = self.session_picker_paths[i];
                break;
            }
        }

        // Dismiss picker
        if (self.session_picker_handle) |h| {
            h.hide();
            self.session_picker_handle = null;
        }

        const path = selected_path orelse {
            self.status_text.setContent("session not found");
            self.status_text.fg = self.theme.fg(.@"error");
            return;
        };

        // zi-wub.15: block /resume during streaming. Rebuilding the
        // transcript while a stream is still emitting events is
        // chaos, and our single pre-run drain point would delay the
        // request until the *next* prompt otherwise.
        if (self.is_streaming or self.agent_thread != null) {
            self.status_text.setContent("cannot resume while agent is running");
            self.status_text.fg = self.theme.fg(.@"error");
            self.tui.dirty = true;
            return;
        }

        // Clone path into msg_allocator (doctrine R3: cross-thread
        // payload slices must be thread-safe allocated).
        const path_copy = self.msg_allocator.dupe(u8, path) catch {
            self.status_text.setContent("out of memory");
            self.status_text.fg = self.theme.fg(.@"error");
            return;
        };

        self.request_queue.push(.{ .resume_session = .{ .path = path_copy } });

        // Spawn a drain-only worker to process it. Agent thread is
        // idle (checked above), so this starts a fresh thread whose
        // only job is to bind lua ownership, drain the request
        // queue, and exit.
        self.showLoader("Loading session...");
        self.tui.dirty = true;

        self.agent_thread = std.Thread.spawn(.{}, agentThreadFn, .{ self, AgentWork{ .drain_only = {} } }) catch {
            self.hideLoader();
            self.status_text.setContent("failed to spawn resume worker");
            self.status_text.fg = self.theme.fg(.@"error");
            // Request is still in the queue — drain it ourselves to
            // avoid leaking the path copy. Safe because no thread is
            // concurrently touching it.
            var drain_buf: [4]AgentRequest = undefined;
            const n = self.request_queue.drainInto(&drain_buf);
            for (drain_buf[0..n]) |*r| r.deinit(self.msg_allocator);
            return;
        };
    }

    fn onSessionPickerCancel(ctx: ?*anyopaque) void {
        const self: *Interactive = @ptrCast(@alignCast(ctx));
        if (self.session_picker_handle) |h| {
            h.hide();
            self.session_picker_handle = null;
        }
    }

    // ── Model picker (/model) ───────────────────────────────────

    fn switchModelDirect(self: *Interactive, pattern: []const u8) void {
        // `/model <pattern>` goes through the same resolver as the
        // CLI flag so users get identical semantics: canonical
        // provider/id, inferred-provider-from-slash, alias-vs-dated
        // preference, and fuzzy id/name matching. pi-mono parity.
        const registry = self.ca.model_registry orelse {
            self.status_text.setContent("model registry unavailable");
            self.status_text.fg = self.theme.fg(.@"error");
            return;
        };

        // Scratch arena for resolver output — resolver owns warning/
        // err strings and we display them inline, then drop them.
        var scratch = std.heap.ArenaAllocator.init(self.msg_allocator);
        defer scratch.deinit();
        const result = ai_resolve.resolveCliModel(.{
            .cli_model = pattern,
            .registry = registry,
            .allocator = scratch.allocator(),
        });
        if (result.err) |e| {
            self.status_text.setContent(e);
            self.status_text.fg = self.theme.fg(.@"error");
            return;
        }
        const m = result.model orelse {
            self.status_text.setContent("model not found");
            self.status_text.fg = self.theme.fg(.@"error");
            return;
        };
        self.applyModelSwitch(m);
    }

    fn freeModelPickerSearchTexts(self: *Interactive) void {
        for (0..self.model_picker_count) |i| {
            // Only free if it was heap-allocated (not a static fallback from m.id)
            const txt = self.model_picker_search_texts[i];
            if (txt.len > 0 and txt.ptr != self.model_picker_items[i].label.ptr) {
                self.allocator.free(txt);
            }
        }
        self.model_picker_count = 0;
    }

    fn showModelPicker(self: *Interactive) void {
        self.freeModelPickerSearchTexts();
        const all = self.model_catalog;
        var count: usize = 0;

        for (all) |m| {
            if (count >= self.model_picker_items.len) break;
            const provider_str = json_util.providerToString(m.provider);
            if (!self.auth_storage.hasAuth(provider_str)) continue;

            self.model_picker_models[count] = m;
            self.model_picker_items[count] = .{
                .value = m.id,
                .label = m.id,
                .description = provider_str,
            };
            var search_buf: [128]u8 = undefined;
            const search_text = std.fmt.bufPrint(&search_buf, "{s} {s}", .{ provider_str, m.id }) catch m.id;
            self.model_picker_search_texts[count] = self.allocator.dupe(u8, search_text) catch m.id;
            count += 1;
        }
        self.model_picker_count = count;

        if (count == 0) {
            self.status_text.setContent("no models available");
            self.status_text.fg = self.theme.fg(.muted);
            return;
        }
        self.model_picker = ListPicker.init(self.theme);
        self.model_picker.title = "Select model";
        self.model_picker.list.max_visible = 12;
        self.model_picker.setSearchableItems(
            self.model_picker_items[0..count],
            self.model_picker_search_texts[0..count],
        );
        self.model_picker.on_select = &onModelSelected;
        self.model_picker.on_cancel = &onModelPickerCancel;
        self.model_picker.callback_ctx = @ptrCast(self);

        self.model_picker_handle = self.tui.showOverlay(
            self.model_picker.component(),
            self.bottomPanelOptions(),
        );
    }

    fn onModelSelected(item: *const SelectItem, ctx: ?*anyopaque) void {
        const self: *Interactive = @ptrCast(@alignCast(ctx));

        var selected_model: ?ai_protocol.Model = null;
        for (0..self.model_picker_count) |i| {
            if (std.mem.eql(u8, self.model_picker_items[i].value, item.value) and
                std.mem.eql(u8, self.model_picker_items[i].description.?, item.description.?))
            {
                selected_model = self.model_picker_models[i];
                break;
            }
        }

        if (self.model_picker_handle) |h| {
            h.hide();
            self.model_picker_handle = null;
        }
        self.freeModelPickerSearchTexts();

        const m = selected_model orelse {
            self.status_text.setContent("model not found");
            self.status_text.fg = self.theme.fg(.@"error");
            return;
        };

        self.applyModelSwitch(m);
    }

    fn onModelPickerCancel(ctx: ?*anyopaque) void {
        const self: *Interactive = @ptrCast(@alignCast(ctx));
        if (self.model_picker_handle) |h| {
            h.hide();
            self.model_picker_handle = null;
        }
        self.freeModelPickerSearchTexts();
    }

    /// Enqueue a /model switch through the AgentRequest queue
    /// (zi-wub.16). The actual mutation runs on the agent thread
    /// inside `handleSetModel`. Same shape as the .15 /resume path:
    /// block during streaming, push request, spawn drain_only worker
    /// when idle. Status update happens when `.model_switched`
    /// drains back through the event queue.
    ///
    /// Model is a static catalog value (its slices live forever in
    /// `ai_models`), so we pass it by value into the request without
    /// cloning the inner strings.
    fn applyModelSwitch(self: *Interactive, m: ai_protocol.Model) void {
        if (self.is_streaming or self.agent_thread != null) {
            self.status_text.setContent("cannot switch model while agent is running");
            self.status_text.fg = self.theme.fg(.@"error");
            self.tui.dirty = true;
            return;
        }

        self.request_queue.push(.{ .set_model = .{ .model = m } });

        self.showLoader("Switching model...");
        self.tui.dirty = true;

        self.agent_thread = std.Thread.spawn(.{}, agentThreadFn, .{ self, AgentWork{ .drain_only = {} } }) catch {
            self.hideLoader();
            self.status_text.setContent("failed to spawn model-switch worker");
            self.status_text.fg = self.theme.fg(.@"error");
            // Drain leaked request to free its payload (set_model
            // currently has no allocations, but stay symmetric with
            // the .15 path).
            var drain_buf: [4]AgentRequest = undefined;
            const n = self.request_queue.drainInto(&drain_buf);
            for (drain_buf[0..n]) |*r| r.deinit(self.msg_allocator);
            return;
        };
    }

    // ── Login picker (/login) ───────────────────────────────────

    fn showLoginPicker(self: *Interactive) void {
        var count: usize = 0;
        for (&oauth_mod.PROVIDERS) |*p| {
            if (count >= self.login_picker_items.len) break;
            self.login_picker_items[count] = .{
                .value = p.id,
                .label = p.name,
                .description = null,
            };
            count += 1;
        }
        self.login_picker_count = count;

        if (count == 0) {
            self.status_text.setContent("no OAuth providers available");
            self.status_text.fg = self.theme.fg(.muted);
            return;
        }

        self.login_picker = ListPicker.init(self.theme);
        self.login_picker.title = "Login";
        self.login_picker.list.max_visible = 8;
        self.login_picker.list.setItems(self.login_picker_items[0..count]);
        self.login_picker.on_select = &onLoginProviderSelected;
        self.login_picker.on_cancel = &onLoginPickerCancel;
        self.login_picker.callback_ctx = @ptrCast(self);

        self.login_picker_handle = self.tui.showOverlay(
            self.login_picker.component(),
            self.bottomPanelOptions(),
        );
    }

    fn onLoginProviderSelected(item: *const SelectItem, ctx: ?*anyopaque) void {
        const self: *Interactive = @ptrCast(@alignCast(ctx));
        if (self.login_picker_handle) |h| {
            h.hide();
            self.login_picker_handle = null;
        }
        self.startLogin(item.value);
    }

    fn onLoginPickerCancel(ctx: ?*anyopaque) void {
        const self: *Interactive = @ptrCast(@alignCast(ctx));
        if (self.login_picker_handle) |h| {
            h.hide();
            self.login_picker_handle = null;
        }
    }

    fn startLogin(self: *Interactive, provider_id: []const u8) void {
        if (self.login_thread != null) {
            self.status_text.setContent("login already in progress");
            self.status_text.fg = self.theme.fg(.warning);
            return;
        }

        const provider = oauth_mod.findProvider(provider_id) orelse {
            self.status_text.setContent("unknown OAuth provider");
            self.status_text.fg = self.theme.fg(.@"error");
            return;
        };

        self.login_cancelled.store(false, .release);

        self.status_text.setContent("starting login...");
        self.status_text.fg = self.theme.fg(.muted);
        self.tui.dirty = true;

        const login_ctx = self.msg_allocator.create(LoginContext) catch {
            self.status_text.setContent("failed to start login");
            self.status_text.fg = self.theme.fg(.@"error");
            return;
        };
        login_ctx.* = .{
            .interactive = self,
            .provider = provider,
        };

        self.login_thread = std.Thread.spawn(.{}, loginThreadFn, .{login_ctx}) catch {
            self.msg_allocator.destroy(login_ctx);
            self.status_text.setContent("failed to spawn login thread");
            self.status_text.fg = self.theme.fg(.@"error");
            return;
        };
    }

    const LoginContext = struct {
        interactive: *Interactive,
        provider: oauth_mod.OAuthProvider,
    };

    fn loginThreadFn(ctx: *LoginContext) void {
        const self = ctx.interactive;
        const provider = ctx.provider;
        self.msg_allocator.destroy(ctx);

        const result = oauth_mod.login(
            self.msg_allocator,
            provider,
            .{
                .on_auth = &onLoginAuth,
                .on_progress = &onLoginProgress,
                .ctx = @ptrCast(self),
            },
            &self.login_cancelled,
        );

        const provider_id = self.msg_allocator.dupe(u8, provider.id) catch return;
        switch (result) {
            .success => |cred| {
                self.auth_storage.set(provider.id, .{ .oauth = cred });
                // auth_storage.set() dupes the credential; free the originals
                self.msg_allocator.free(cred.refresh);
                self.msg_allocator.free(cred.access);
                var extras = cred.extras;
                var eit = extras.iterator();
                while (eit.next()) |e| {
                    self.msg_allocator.free(e.key_ptr.*);
                    json_util.freeJsonValue(self.msg_allocator, e.value_ptr.*);
                }
                extras.deinit();
                self.event_queue.push(.{ .login_complete = .{
                    .provider_id = provider_id,
                    .success = true,
                    .message = self.msg_allocator.dupe(u8, "logged in") catch return,
                } });
            },
            .cancelled => {
                self.event_queue.push(.{ .login_complete = .{
                    .provider_id = provider_id,
                    .success = false,
                    .message = self.msg_allocator.dupe(u8, "login cancelled") catch return,
                } });
            },
            .err => |msg| {
                self.event_queue.push(.{ .login_complete = .{
                    .provider_id = provider_id,
                    .success = false,
                    .message = self.msg_allocator.dupe(u8, msg) catch return,
                } });
            },
        }
    }

    // zi-wub.17: login-thread callbacks. These run on the login
    // thread, so they MUST NOT touch TUI-owned state (status_text,
    // tui.dirty, etc). Instead they publish a `login_progress` event
    // on `event_queue` with an msg_allocator-owned payload; the TUI
    // thread consumes it from the normal drain loop. Single-owner
    // invariant for status_text is restored — only the TUI thread
    // writes it.
    fn onLoginAuth(url: []const u8, ctx: ?*anyopaque) void {
        const self: *Interactive = @ptrCast(@alignCast(ctx));

        _ = std.process.Child.run(.{
            .allocator = self.msg_allocator,
            .argv = if (@import("builtin").os.tag == .macos)
                &.{ "open", url }
            else
                &.{ "xdg-open", url },
        }) catch {};

        const msg = self.msg_allocator.dupe(u8, "login: check your browser") catch return;
        self.event_queue.push(.{ .login_progress = .{ .message = msg, .kind = .auth_url } });
    }

    fn onLoginProgress(msg: []const u8, ctx: ?*anyopaque) void {
        const self: *Interactive = @ptrCast(@alignCast(ctx));
        const owned = self.msg_allocator.dupe(u8, msg) catch return;
        self.event_queue.push(.{ .login_progress = .{ .message = owned, .kind = .info } });
    }

    /// Format an ISO 8601 timestamp as relative time: "now", "2m", "1h", "3d", "2w", "1mo", "1y"
    fn formatRelativeTime(iso_ts: []const u8) []const u8 {
        // Parse "YYYY-MM-DDThh:mm:ss" → epoch seconds
        if (iso_ts.len < 19) return iso_ts;
        const year = std.fmt.parseInt(i64, iso_ts[0..4], 10) catch return iso_ts;
        const month = std.fmt.parseInt(u8, iso_ts[5..7], 10) catch return iso_ts;
        const day = std.fmt.parseInt(u8, iso_ts[8..10], 10) catch return iso_ts;
        const hour = std.fmt.parseInt(u8, iso_ts[11..13], 10) catch return iso_ts;
        const min = std.fmt.parseInt(u8, iso_ts[14..16], 10) catch return iso_ts;
        const sec = std.fmt.parseInt(u8, iso_ts[17..19], 10) catch return iso_ts;

        // Rough epoch calculation (no leap second precision needed for "time ago")
        const days_in_month = [_]u16{ 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 };
        if (month < 1 or month > 12) return iso_ts;
        const year_days = (year - 1970) * 365 + @divTrunc(year - 1969, 4);
        const month_days: i64 = days_in_month[month - 1];
        const ts_epoch = (year_days + month_days + day - 1) * 86400 + @as(i64, hour) * 3600 + @as(i64, min) * 60 + sec;

        const now = std.time.timestamp();
        const diff = now - ts_epoch;
        if (diff < 0) return "now";

        const diff_u: u64 = @intCast(diff);
        if (diff_u < 60) return "now";
        if (diff_u < 3600) {
            const mins = diff_u / 60;
            return switch (mins) {
                1 => "1m",
                2 => "2m",
                3 => "3m",
                5 => "5m",
                10 => "10m",
                15 => "15m",
                30 => "30m",
                else => if (mins < 5) "few min" else if (mins < 30) "<30m" else "<1h",
            };
        }
        if (diff_u < 86400) {
            const hours = diff_u / 3600;
            return switch (hours) {
                1 => "1h",
                2 => "2h",
                3 => "3h",
                else => if (hours < 12) "<12h" else "<1d",
            };
        }
        const days = diff_u / 86400;
        if (days == 1) return "yesterday";
        if (days < 7) return if (days == 2) "2d" else if (days < 4) "few days" else "<1w";
        if (days < 30) return if (days < 14) "1w" else if (days < 21) "2w" else "3w";
        if (days < 365) {
            const months = days / 30;
            return if (months <= 1) "1mo" else if (months <= 2) "2mo" else if (months <= 6) "<6mo" else "<1y";
        }
        return ">1y";
    }

    /// Agent worker thread entry point. Handles both streaming
    /// prompts and drain-only request work (zi-wub.15). This is the
    /// ONLY path that runs on the agent thread — any future work
    /// that needs agent-thread ownership should extend `AgentWork`
    /// rather than adding a second thread fn.
    ///
    /// Completion events are mode-aware:
    ///   - prompt     → `.prompt_worker_finished` (cleanup after the
    ///                  controller finishes the full prompt lifecycle)
    ///   - drain_only → `.request_worker_finished` (join only; the
    ///                  individual request handlers publish their
    ///                  own success/failure events, so the TUI
    ///                  state unwinds without wiping a good status)
    fn agentThreadFn(self: *Interactive, work: AgentWork) void {
        defer switch (work) {
            .prompt => |p| self.msg_allocator.free(p),
            .drain_only => {},
        };

        // zi-wub.28: bind lua owner on the drain_only path too. The
        // .15/.16 handlers don't touch lua, but `.shutdown` calls
        // `lua_close` and we want this thread to be the bound owner
        // when zi-wub.7 flips wrong-thread access to fatal. Safe
        // because the previous agent_thread (if any) was joined
        // before we were spawned (caller invariant — see deinit
        // and the dispatch sites in handleSlashResume / setModel).
        if (work == .drain_only) {
            if (self.ca.extensionRunner()) |runner| {
                runner.bindLuaOwnerThread(std.Thread.getCurrentId());
            }
        }

        switch (work) {
            .prompt => |p| {
                // zi-wub.14: drain pending TUI→agent requests at the turn
                // boundary, before issuing the stream. This is the "safe
                // point" the doctrine specifies — we are on the agent thread,
                // owner of lua_state and ca.agent.state, and not yet inside
                // a stream. Mid-stream draining is explicitly out of scope
                // (R5: no event loop in this epic).
                self.processAgentRequests();

                const outcome = self.session_controller.runPrompt(p) catch |err| {
                    const err_msg = self.msg_allocator.dupe(u8, @errorName(err)) catch null;
                    self.event_queue.push(.{ .prompt_worker_finished = .{
                        .outcome = .assistant_error,
                        .internal_error = err_msg,
                    } });
                    return;
                };
                self.event_queue.push(.{ .prompt_worker_finished = .{ .outcome = outcome } });
            },
            .drain_only => {
                self.session_controller.beginRequestDrain();
                self.processAgentRequests();
                self.session_controller.finishRequestDrain();
                self.event_queue.push(.{ .request_worker_finished = {} });
            },
        }
    }

    /// Drain the AgentRequest queue and dispatch each request on the
    /// agent thread. Runs inside `agentThreadFn` at a turn boundary.
    ///
    /// Drain → dispatch is split so handlers can publish UiEvents
    /// back via EventQueue (and in future may take longer than the
    /// drain critical section allows).
    fn processAgentRequests(self: *Interactive) void {
        var buf: [16]AgentRequest = undefined;
        while (true) {
            const n = self.request_queue.drainInto(&buf);
            if (n == 0) return;
            for (buf[0..n]) |*req| {
                switch (req.*) {
                    .resume_session => |r| self.handleResumeSession(r.path),
                    .set_model => |s| self.handleSetModel(s.model),
                    // zi-wub.28: terminal request. Tears down the
                    // runner + lua_State on the agent thread (the
                    // owner). After this returns, ca's extension
                    // fields are nulled and `AgentSession.deinit`
                    // (which still runs on the TUI thread for non-
                    // extension teardown) will skip the lua blocks.
                    .shutdown => self.ca.shutdownExtensionsOnAgentThread(),
                }
                req.deinit(self.msg_allocator);
            }
        }
    }

    /// Agent-thread handler for `AgentRequest.resume_session`.
    /// Loads the session via `openSession` (agent_arena allocated),
    /// projects messages into `ResumedEntry` display values cloned
    /// into `msg_allocator` (doctrine R3), and publishes either
    /// `.session_resumed` or `.session_resume_failed` back to the TUI.
    ///
    /// Transcript rebuild stays on the TUI thread — this handler
    /// does NOT touch `self.transcript`. That's .15's whole point.
    fn handleResumeSession(self: *Interactive, path: []const u8) void {
        const loaded = coding_agent_mod.openSession(self.allocator, path) catch {
            const msg = self.msg_allocator.dupe(u8, "failed to load session") catch return;
            self.event_queue.push(.{ .session_resume_failed = .{ .message = msg } });
            return;
        };

        // Agent-thread state mutations (doctrine: session_store +
        // ca.agent.state are agent-owned). Safe here — we're on the
        // agent thread and no stream is in flight.
        self.ca.session_store = loaded.store;
        self.ca.agent.loadMessages(loaded.messages);

        // pi-mono parity: if the session recorded a last model,
        // route it through `restoreModelFromSession`. Falls back to
        // the current model / first authed model when the saved one
        // disappeared or lost auth. `restore_warning`, when set,
        // rides along with `.session_resumed` so it survives the
        // transcript-rebuild status update on the TUI side.
        //
        // pi-mono source: model-resolver.ts:559-628
        var restore_warning: ?[]u8 = null;
        if (loaded.model) |saved| {
            if (self.ca.model_registry) |registry| {
                const restore = ai_resolve.restoreModelFromSession(.{
                    .saved_provider = saved.provider,
                    .saved_model_id = saved.model_id,
                    .current_model = self.ca.agent.state.model,
                    .registry = registry,
                    .allocator = self.msg_allocator,
                }) catch ai_resolve.RestoreResult{ .model = null, .fallback_message = null };
                if (restore.model) |m| {
                    self.ca.agent.state.model = m;
                }
                if (restore.fallback_message) |msg| {
                    // `restoreModelFromSession` allocates via
                    // msg_allocator above; take ownership directly.
                    // `UiEvent.deinit` frees with the same allocator.
                    restore_warning = msg;
                }
            }
        }

        // Project messages into a display list, cloned into
        // msg_allocator so the TUI can free them independently of
        // agent_arena. Preserve assistant text + thinking block order
        // so resume rebuild matches live TUI semantics.
        var entries = std.ArrayListUnmanaged(ResumedEntry).empty;
        defer entries.deinit(self.msg_allocator);

        for (loaded.messages) |msg| {
            switch (msg) {
                .user => |u| switch (u.content) {
                    .text => |t| {
                        const cloned = self.msg_allocator.dupe(u8, t) catch continue;
                        entries.append(self.msg_allocator, .{ .user_text = cloned }) catch {
                            self.msg_allocator.free(cloned);
                        };
                    },
                    else => {},
                },
                .assistant => |a| {
                    var blocks = std.ArrayListUnmanaged(ResumedAssistantBlock).empty;
                    defer blocks.deinit(self.msg_allocator);
                    for (a.content) |block| {
                        switch (block) {
                            .text => |tc| {
                                const cloned = self.msg_allocator.dupe(u8, tc.text) catch continue;
                                blocks.append(self.msg_allocator, .{ .text = cloned }) catch {
                                    self.msg_allocator.free(cloned);
                                };
                            },
                            .thinking => |th| {
                                const cloned = self.msg_allocator.dupe(u8, th.thinking) catch continue;
                                blocks.append(self.msg_allocator, .{ .thinking = cloned }) catch {
                                    self.msg_allocator.free(cloned);
                                };
                            },
                            else => {},
                        }
                    }
                    if (blocks.items.len > 0) {
                        const owned_blocks = blocks.toOwnedSlice(self.msg_allocator) catch {
                            for (blocks.items) |*block| block.deinit(self.msg_allocator);
                            continue;
                        };
                        entries.append(self.msg_allocator, .{ .assistant_message = owned_blocks }) catch {
                            for (owned_blocks) |*block| block.deinit(self.msg_allocator);
                            self.msg_allocator.free(owned_blocks);
                        };
                    }
                },
                else => {},
            }
        }

        const owned_entries = entries.toOwnedSlice(self.msg_allocator) catch {
            // toOwnedSlice failed — free what we gathered and report.
            for (entries.items) |*e| e.deinit(self.msg_allocator);
            const msg = self.msg_allocator.dupe(u8, "out of memory building resume view") catch return;
            self.event_queue.push(.{ .session_resume_failed = .{ .message = msg } });
            return;
        };
        self.event_queue.push(.{ .session_resumed = .{
            .entries = owned_entries,
            .restore_warning = restore_warning,
        } });
    }

    /// Agent-thread handler for `AgentRequest.set_model` (zi-wub.16).
    /// Delegates the canonical validation + mutation path to
    /// `AgentSession.trySetModel`, then translates the typed outcome
    /// into a TUI-owned event payload.
    fn handleSetModel(self: *Interactive, m: ai_protocol.Model) void {
        switch (self.ca.trySetModel(m)) {
            .success => |switched| {
                const provider_str = json_util.providerToString(switched.model.provider);
                const provider_copy = self.msg_allocator.dupe(u8, provider_str) catch return;
                const id_copy = self.msg_allocator.dupe(u8, switched.model.id) catch {
                    self.msg_allocator.free(provider_copy);
                    return;
                };
                self.event_queue.push(.{ .model_switched = .{ .provider = provider_copy, .id = id_copy } });
            },
            .no_auth => |blocked| {
                const provider_str = json_util.providerToString(blocked.provider);
                const msg = std.fmt.allocPrint(
                    self.msg_allocator,
                    "No API key for {s}/{s}",
                    .{ provider_str, blocked.id },
                ) catch return;
                self.event_queue.push(.{ .model_switch_failed = .{ .message = msg } });
            },
            .registry_unavailable => {
                const msg = self.msg_allocator.dupe(u8, "model registry unavailable") catch return;
                self.event_queue.push(.{ .model_switch_failed = .{ .message = msg } });
            },
        }
    }

    /// Session event callback — runs on the AGENT THREAD.
    fn sessionEventCallback(event: SessionEvent, ctx: ?*anyopaque) void {
        const self: *Interactive = @ptrCast(@alignCast(ctx));
        switch (event) {
            .agent_event => |agent_event| {
                const ui_event = convertAgentEvent(agent_event, self.msg_allocator) orelse return;
                self.event_queue.push(ui_event);
            },
            .phase_changed => |pc| {
                if (pc.from == .waiting_to_retry and pc.to == .running_continue) {
                    self.event_queue.push(.retry_wait_finished);
                }
            },
            .retry_start => |r| {
                const err_msg = self.msg_allocator.dupe(u8, r.error_message) catch return;
                self.event_queue.push(.{ .retry_start = .{
                    .attempt = r.attempt,
                    .max_attempts = r.max_attempts,
                    .delay_ms = r.delay_ms,
                    .error_message = err_msg,
                } });
            },
            .retry_end => |r| {
                const final_error = if (r.final_error) |msg|
                    (self.msg_allocator.dupe(u8, msg) catch null)
                else
                    null;
                self.event_queue.push(.{ .retry_end = .{
                    .success = r.success,
                    .attempt = r.attempt,
                    .final_error = final_error,
                } });
            },
            .compaction_start, .compaction_end => {},
        }
    }
};

fn userFacingFailureMessage(
    failure_kind: ?ai_protocol.NormalizedFailure.Kind,
    raw_message: []const u8,
) []const u8 {
    return switch (failure_kind orelse return raw_message) {
        .auth => "authentication failed. run /login or refresh your credentials.",
        .context_overflow => "context window exceeded. compact the session or switch to a larger-context model.",
        .invalid_request => if (containsCI(raw_message, "content_filter"))
            "request blocked by the provider safety filter. try rephrasing and try again."
        else
            raw_message,
        else => raw_message,
    };
}

fn containsCI(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// Convert an AgentEvent to a TUI-owned UiEvent with deep-copied data.
/// Runs on the agent thread. Returns null for events the TUI doesn't need.
fn convertAgentEvent(event: AgentEvent, allocator: std.mem.Allocator) ?UiEvent {
    switch (event) {
        .message_start => |ms| {
            return switch (ms.message) {
                .assistant => .message_start_assistant,
                .user => .message_start_user,
                else => null,
            };
        },
        .message_update => |mu| {
            switch (mu.assistant_message_event) {
                .text_delta => |d| {
                    const delta = allocator.dupe(u8, d.delta) catch return null;
                    return .{ .assistant_text_delta = .{
                        .content_index = d.content_index,
                        .delta = delta,
                    } };
                },
                .thinking_delta => |d| {
                    const delta = allocator.dupe(u8, d.delta) catch return null;
                    return .{ .assistant_thinking_delta = .{
                        .content_index = d.content_index,
                        .delta = delta,
                    } };
                },
                .@"error" => |e| {
                    if (e.@"error".error_message) |msg| {
                        const owned = allocator.dupe(u8, msg) catch return null;
                        return .{ .error_message = .{ .message = owned } };
                    }
                    return null;
                },
                .toolcall_delta => |tc| {
                    // Mid-stream tool-call progress. `partial.content`
                    // is refreshed by anthropic.zig before each delta
                    // callback, so the in-progress tool_call is at
                    // `partial.content[content_index]`. Args are the
                    // incrementally parsed partial JSON — the TUI
                    // renders them without marking them complete.
                    if (tc.content_index >= tc.partial.content.len) return null;
                    const block = tc.partial.content[tc.content_index];
                    if (block != .tool_call) return null;
                    const call = block.tool_call;
                    const id = allocator.dupe(u8, call.id) catch return null;
                    errdefer allocator.free(id);
                    const name = allocator.dupe(u8, call.name) catch return null;
                    errdefer allocator.free(name);
                    const args = json_util.cloneJsonValue(allocator, call.arguments) catch return null;
                    return .{ .tool_call_streaming = .{
                        .tool_call_id = id,
                        .tool_name = name,
                        .args = args,
                        .is_complete = false,
                    } };
                },
                .toolcall_end => |tc| {
                    const id = allocator.dupe(u8, tc.tool_call.id) catch return null;
                    errdefer allocator.free(id);
                    const name = allocator.dupe(u8, tc.tool_call.name) catch return null;
                    errdefer allocator.free(name);
                    const args = json_util.cloneJsonValue(allocator, tc.tool_call.arguments) catch return null;
                    return .{ .tool_call_streaming = .{
                        .tool_call_id = id,
                        .tool_name = name,
                        .args = args,
                        .is_complete = true,
                    } };
                },
                else => return null,
            }
        },
        .tool_execution_start => |te| {
            const id = allocator.dupe(u8, te.tool_call_id) catch return null;
            errdefer allocator.free(id);
            const name = allocator.dupe(u8, te.tool_name) catch return null;
            errdefer allocator.free(name);
            const args = json_util.cloneJsonValue(allocator, te.args) catch return null;
            return .{ .tool_start = .{
                .tool_call_id = id,
                .tool_name = name,
                .args = args,
            } };
        },
        .tool_execution_update => |te| {
            const id = allocator.dupe(u8, te.tool_call_id) catch return null;
            errdefer allocator.free(id);
            const result = if (te.partial_result) |r| (r.clone(allocator) catch return null) else null;
            return .{ .tool_update = .{
                .tool_call_id = id,
                .result = result,
                .is_error = if (te.partial_result) |r| r.is_error else false,
            } };
        },
        .tool_execution_end => |te| {
            const id = allocator.dupe(u8, te.tool_call_id) catch return null;
            errdefer allocator.free(id);
            const result = te.result.clone(allocator) catch return null;
            return .{ .tool_end = .{
                .tool_call_id = id,
                .result = result,
                .is_error = te.is_error,
            } };
        },
        .message_end => |me| {
            switch (me.message) {
                .assistant => |am| {
                    if (am.stop_reason == .aborted or am.stop_reason == .@"error") {
                        const err_msg = if (am.error_message) |msg|
                            (allocator.dupe(u8, msg) catch null)
                        else
                            null;
                        return .{ .message_end_assistant = .{
                            .is_aborted = am.stop_reason == .aborted,
                            .error_message = err_msg,
                            .failure_kind = if (am.failure) |failure| failure.kind else null,
                        } };
                    }
                    return null;
                },
                else => return null,
            }
        },
        .agent_end, .agent_start, .turn_start, .turn_end => return null,
    }
}

fn agentThinkingLabel(level: agent_protocol.ThinkingLevel) []const u8 {
    return switch (level) {
        .off => "",
        .minimal => "minimal",
        .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => "xhigh",
    };
}
