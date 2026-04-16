const std = @import("std");
const posix = std.posix;
const mailbox_mod = @import("../runtime/mailbox.zig");
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
const hotkeys_overlay_mod = @import("components/hotkeys_overlay.zig");
const loader_mod = @import("components/loader.zig");
const ui_event_mod = @import("ui_event.zig");
const transcript_mod = @import("transcript.zig");
const conversation_projection_mod = @import("conversation_projection.zig");
const container_mod = @import("container.zig");
const overlay_mod = @import("overlay.zig");
const tool_display_mod = @import("tool_display.zig");
const theme_mod = @import("theme.zig");
const themes_builtin = @import("../themes/builtin.zig");
const app_meta = @import("../app_meta.zig");
const tui_mod = @import("tui.zig");
const editor_iface_mod = @import("editor_iface.zig");
const input_buffer_mod = @import("input_buffer.zig");
const status_data_mod = @import("status_data.zig");
const clipboard_mod = @import("clipboard.zig");
const string_util = @import("../lib/string_util.zig");
const time_util = @import("../lib/time_util.zig");

const autocomplete_mod = @import("autocomplete.zig");
const keybindings = @import("keybindings.zig");
const slash_commands_mod = @import("../slash_commands.zig");
const CombinedAutocompleteProvider = autocomplete_mod.CombinedAutocompleteProvider;
const CommandRegistry = slash_commands_mod.CommandRegistry;
const list_picker_mod = @import("components/list_picker.zig");
const select_list_mod = @import("components/select_list.zig");
const ListPicker = list_picker_mod.ListPicker;
const PickerSelection = list_picker_mod.Selection;
const SelectItem = select_list_mod.SelectItem;
const session_store_mod = @import("../session/store.zig");
const SessionStore = session_store_mod.SessionStore;
const storage = @import("../storage.zig");
const logging = @import("../logging.zig");

const agent_mod = @import("../agent/root.zig");
const coding_agent_mod = @import("../coding_agent.zig");
const session_controller_mod = @import("../session_controller.zig");
const run_control_mod = @import("../runtime/run_control.zig");
const AgentEvent = agent_mod.protocol.AgentEvent;
const AgentToolResult = agent_mod.protocol.AgentToolResult;
const AgentRequest = agent_mod.AgentRequest;
const RequestQueue = agent_mod.RequestQueue;
const agent_protocol = agent_mod.protocol;
const message_memory = agent_mod.message_memory;
const SessionController = session_controller_mod.SessionController;
const RetryPolicy = session_controller_mod.RetryPolicy;
const CompactionPolicy = session_controller_mod.CompactionPolicy;
const CompactionExecutor = session_controller_mod.CompactionExecutor;
const SessionEvent = session_controller_mod.SessionEvent;
const ChildRect = container_mod.ChildRect;

const MouseCapture = union(enum) {
    none,
    transcript_selection: void,
};

const AgentSession = coding_agent_mod.AgentSession;
const json_util = @import("../ai/json_util.zig");
const SettingsAction = enum {
    open_thinking,
    toggle_hide_thinking,
};

const IdleRequestDispatch = struct {
    busy_message: []const u8,
    loader_message: []const u8,
    spawn_failed_message: []const u8,
};
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

const PublishedStatusSnapshot = struct {
    model_provider: []u8,
    model_id: []u8,
    thinking_level: agent_protocol.ThinkingLevel,
    context_tokens: ?u64,
    context_window: u64,

    fn init(
        allocator: std.mem.Allocator,
        snapshot: AgentSession.StatusSnapshot,
    ) !PublishedStatusSnapshot {
        const model_provider = try allocator.dupe(u8, snapshot.model_provider);
        errdefer allocator.free(model_provider);
        const model_id = try allocator.dupe(u8, snapshot.model_id);
        return .{
            .model_provider = model_provider,
            .model_id = model_id,
            .thinking_level = snapshot.thinking_level,
            .context_tokens = snapshot.context_tokens,
            .context_window = snapshot.context_window,
        };
    }

    fn deinit(self: *PublishedStatusSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.model_provider);
        allocator.free(self.model_id);
        self.* = undefined;
    }

    fn eql(self: PublishedStatusSnapshot, snapshot: AgentSession.StatusSnapshot) bool {
        return std.mem.eql(u8, self.model_provider, snapshot.model_provider) and
            std.mem.eql(u8, self.model_id, snapshot.model_id) and
            self.thinking_level == snapshot.thinking_level and
            self.context_tokens == snapshot.context_tokens and
            self.context_window == snapshot.context_window;
    }
};

/// Mailbox-backed agent/helper → TUI event channel.
///
/// The queue shape remains part of zi's runtime doctrine, but wakeup
/// signaling now comes from the shared mailbox primitive rather than a
/// bespoke event pipe implementation.
const UiEventQueue = mailbox_mod.Mailbox(UiEvent, .{
    .cleanup = .deinit,
    .policy = .unbounded,
    .wakeup = .pipe,
});

const QueuedInputKind = enum {
    steering,
    follow_up,
};

test "UiEventQueue wake pipe signals poll and drains with mailbox semantics" {
    var q = try UiEventQueue.init(std.testing.allocator);
    defer q.deinit();

    q.push(.{ .message_start_user = .{ .text = try std.testing.allocator.dupe(u8, "hello") } });

    var pfd = [1]posix.pollfd{.{
        .fd = q.wakeReadFd().?,
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    const ready = try posix.poll(&pfd, 0);
    try std.testing.expectEqual(@as(usize, 1), ready);

    var out: [2]UiEvent = undefined;
    const count = q.drainInto(&out);
    try std.testing.expectEqual(@as(usize, 1), count);
    switch (out[0]) {
        .message_start_user => {},
        else => return error.UnexpectedResult,
    }
    out[0].deinit(std.testing.allocator);

    pfd[0].revents = 0;
    const after = try posix.poll(&pfd, 0);
    try std.testing.expectEqual(@as(usize, 0), after);
}

/// Owns all transient heap-backed data for one `/resume` overlay.
/// The picker borrows from this flow; teardown is one arena drop.
const ResumePickerFlow = struct {
    arena: std.heap.ArenaAllocator,
    rows: []Row = &.{},
    items: []SelectItem = &.{},
    picker: ListPicker,
    handle: ?tui_mod.OverlayHandle = null,

    const Row = struct {
        item: SelectItem,
        path: []const u8,
    };

    fn init(gpa: std.mem.Allocator, theme: *const theme_mod.Theme, cwd: []const u8) !ResumePickerFlow {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const sessions = try session_store_mod.listSessions(a, cwd);
        const rows = try a.alloc(Row, sessions.len);
        const items = try a.alloc(SelectItem, sessions.len);

        for (sessions, 0..) |session, i| {
            const item: SelectItem = .{
                .value = session.session_id,
                .label = session.first_message,
                .description = try std.fmt.allocPrint(a, "{d} msgs \xC2\xB7 {s}", .{
                    session.message_count,
                    time_util.relativeTimeLabel(session.timestamp),
                }),
            };
            rows[i] = .{ .item = item, .path = session.path };
            items[i] = item;
        }

        var picker = ListPicker.init(theme);
        picker.title = "Resume session";
        picker.list.max_visible = 10;
        picker.setSearchPlaceholder("Filter sessions");
        picker.setEmptyText("No matching sessions");
        picker.setSearchableItems(items, null);

        return .{
            .arena = arena,
            .rows = rows,
            .items = items,
            .picker = picker,
        };
    }

    fn deinit(self: *ResumePickerFlow) void {
        self.arena.deinit();
    }
};

/// Owns all transient heap-backed data for one `/model` overlay.
/// Stable catalog models stay borrowed; derived search rows live here.
const ModelPickerFlow = struct {
    arena: std.heap.ArenaAllocator,
    rows: []Row = &.{},
    items: []SelectItem = &.{},
    search_texts: []const []const u8 = &.{},
    picker: ListPicker,
    handle: ?tui_mod.OverlayHandle = null,

    const Row = struct {
        item: SelectItem,
        model: ai_protocol.Model,
        search_text: []const u8,
    };

    fn init(
        gpa: std.mem.Allocator,
        theme: *const theme_mod.Theme,
        model_catalog: []const ai_protocol.Model,
        auth_storage: *auth_storage_mod.AuthStorage,
    ) !ModelPickerFlow {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();

        var count: usize = 0;
        for (model_catalog) |model| {
            if (auth_storage.hasAuth(json_util.providerToString(model.provider))) count += 1;
        }

        const rows = try a.alloc(Row, count);
        const items = try a.alloc(SelectItem, count);
        const search_texts = try a.alloc([]const u8, count);

        var i: usize = 0;
        for (model_catalog) |model| {
            const provider_str = json_util.providerToString(model.provider);
            if (!auth_storage.hasAuth(provider_str)) continue;

            const item: SelectItem = .{
                .value = model.id,
                .label = model.id,
                .description = provider_str,
            };
            const search_text = try std.fmt.allocPrint(a, "{s} {s}", .{ provider_str, model.id });
            rows[i] = .{ .item = item, .model = model, .search_text = search_text };
            items[i] = item;
            search_texts[i] = search_text;
            i += 1;
        }

        var picker = ListPicker.init(theme);
        picker.title = "Select model";
        picker.list.max_visible = 12;
        picker.setSearchPlaceholder("Search models");
        picker.setEmptyText("No matching models");
        picker.setSearchableItems(items, search_texts);

        return .{
            .arena = arena,
            .rows = rows,
            .items = items,
            .search_texts = search_texts,
            .picker = picker,
        };
    }

    fn deinit(self: *ModelPickerFlow) void {
        self.arena.deinit();
    }
};

const StartupAction = union(enum) {
    none,
    prompt: []const u8,
    resume_session: []const u8,
    resume_picker,
};

/// Interactive mode — wires AgentSession (blocking on its thread)
/// to the TUI (main thread) via a thread-safe event queue.
///
/// Uses UiEvent (deep-copied) instead of raw AgentEvent to ensure
/// no borrowed pointers cross the thread boundary.
///
/// Composes TUI (reusable rendering/focus/overlay infrastructure)
/// with domain-specific state (editor, transcript, agent, containers).
pub const Interactive = struct {
    /// TUI-local tracked allocator for widget/component state and other
    /// heap data that never crosses threads. Use this (or a short-lived
    /// arena backed by it) for local scratch.
    allocator: std.mem.Allocator,
    /// Thread-safe GPA-backed allocator for cross-thread mailbox
    /// payloads and mailbox backing storage. This is NOT the same as
    /// `allocator` (which is TUI-local tracked state storage) — it wraps
    /// the root GPA directly so producer/consumer free paths stay
    /// allocator-correct.
    /// See `docs/runtime.md` doctrine R3.
    msg_allocator: std.mem.Allocator,
    tui: TUI,
    theme: *const theme_mod.Theme = undefined,
    cwd: []const u8 = "",

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
    /// Agent-thread dedupe cache for semantic status publication.
    /// Owned storage lives in `msg_allocator` so teardown can free it on
    /// the TUI thread after all workers are joined.
    last_published_status_snapshot: ?PublishedStatusSnapshot = null,
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
    autocomplete_provider: CombinedAutocompleteProvider = undefined,
    autocomplete_provider_bound: bool = false,
    hotkeys_overlay: hotkeys_overlay_mod.HotkeysOverlay,

    // ── Flow-owned transient pickers ────────────────────────────
    resume_picker_flow: ?ResumePickerFlow = null,

    // ── Model picker (for /model) ───────────────────────────────
    auth_storage: *auth_storage_mod.AuthStorage,
    settings_manager: *settings_manager_mod.SettingsManager,
    /// Borrowed slice of the session's ModelRegistry. Bound at init
    /// from `ca.model_registry.getAll()`. Lifetime: AgentSession
    /// outlives Interactive, and the registry is immutable for the
    /// session lifetime, so the slice is stable.
    model_catalog: []const ai_protocol.Model = &.{},
    model_picker_flow: ?ModelPickerFlow = null,

    // ── Settings pickers (/settings) ───────────────────────────────
    settings_picker: ListPicker = undefined,
    settings_picker_items: [16]SelectItem = undefined,
    settings_picker_actions: [16]SettingsAction = undefined,
    settings_picker_count: usize = 0,
    settings_picker_handle: ?tui_mod.OverlayHandle = null,
    thinking_picker: ListPicker = undefined,
    thinking_picker_items: [8]SelectItem = undefined,
    thinking_picker_levels: [8]agent_protocol.ThinkingLevel = undefined,
    thinking_picker_count: usize = 0,
    thinking_picker_handle: ?tui_mod.OverlayHandle = null,

    // ── Login state (/login) ────────────────────────────────────────
    login_picker: ListPicker = undefined,
    login_picker_items: [8]SelectItem = undefined,
    login_picker_count: usize = 0,
    login_picker_handle: ?tui_mod.OverlayHandle = null,
    login_thread: ?std.Thread = null,
    login_cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    event_queue: UiEventQueue,
    /// TUI → agent owner inbox. The TUI enqueues `AgentRequest`
    /// values; the long-lived agent thread wakes, drains, and dispatches
    /// them on the owner thread.
    request_queue: RequestQueue,
    run_control: run_control_mod.RunControl,
    ca: *AgentSession,
    memory_diagnostics: *const memory_debug.Diagnostics,
    session_controller: SessionController,
    session_event_token: ?SessionController.SubscriptionToken = null,
    agent_thread: ?std.Thread = null,
    running: bool = true,
    is_streaming: bool = false,
    request_in_flight: bool = false,
    startup_action: StartupAction = .none,
    last_ctrl_c_ns: i128 = 0,
    tool_output_expanded: bool = false,
    hide_thinking_block: bool = false,
    greeter_dismissed: bool = false,
    /// Input sequence buffer — handles split escape sequences, paste, kitty negotiation.
    input: input_buffer_mod.InputBuffer,
    /// Kitty protocol negotiation: deadline (ns timestamp) for query response.
    /// null = negotiation complete.
    kitty_deadline_ns: ?i128 = null,
    mouse_capture: MouseCapture = .none,

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
        const theme = themes_builtin.defaultForTerminal();
        const state_allocator = memory_diagnostics.tui.allocator();

        var self: Interactive = .{
            .allocator = state_allocator,
            .msg_allocator = msg_allocator,
            .tui = try TUI.init(state_allocator),
            .theme = theme,
            .cwd = cwd,
            .editor = editor_mod.Editor.init(state_allocator),
            .status_text = text_mod.Text.init(state_allocator),
            .greeter = .{ .theme = theme, .version = app_meta.version },
            .footer = .{ .theme = theme },
            .hotkeys_overlay = .{ .theme = theme },
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
            .event_queue = try UiEventQueue.init(msg_allocator),
            .request_queue = try RequestQueue.init(msg_allocator),
            .run_control = try run_control_mod.RunControl.init(msg_allocator, .{}),
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

        self.editor.setTheme(theme);
        self.loader.shimmer_edge_fg = theme.fg(.muted);
        self.loader.message_fg = theme.fg(.dim);
        self.loader.shimmer_peak_fg = Color.rgb(0xF2, 0xF1, 0xEF);
        self.editor.setCwd(cwd);
        self.hide_thinking_block = settings_manager.getHideThinkingBlock();
        self.transcript.setHideThinkingBlock(self.hide_thinking_block);
        // NOTE: active_editor is bound in run() where self is at its final
        // address. Binding it here would capture a pointer to the local `self`
        // that becomes dangling after the by-value return.
        self.transcript.theme = theme;
        return self;
    }

    pub fn setStartupAction(self: *Interactive, startup_action: StartupAction) void {
        self.startup_action = startup_action;
    }

    pub fn deinit(self: *Interactive) void {
        // Cancel and join login thread if active
        if (self.login_thread != null) {
            self.login_cancelled.store(true, .release);
            if (self.login_thread) |t| t.join();
            self.login_thread = null;
        }
        // Stop the long-lived agent owner thread. Abort first if a
        // prompt is mid-flight so the owner loop can reach its next
        // request boundary, then enqueue an ordered shutdown, close the
        // transport, and join.
        if (self.agent_thread) |t| {
            if (self.is_streaming) self.ca.agent.abort();
            self.transcript.lua_runner = null;
            self.enqueueAgentShutdown();
            self.request_queue.close();
            t.join();
            self.agent_thread = null;
            self.is_streaming = false;
            self.request_in_flight = false;
        } else {
            self.request_queue.close();
        }
        self.ca.agent.unbindRunControl(&self.run_control);

        if (self.session_event_token) |token| {
            self.session_controller.unsubscribe(token);
            self.session_event_token = null;
        }
        self.session_controller.deinit();
        self.event_queue.close();

        // drain and free any remaining events
        var drain_buf: [64]UiEvent = undefined;
        while (true) {
            const count = self.event_queue.drainInto(&drain_buf);
            if (count == 0) break;
            for (drain_buf[0..count]) |*ev| ev.deinit(self.msg_allocator);
        }
        self.closeModelPickerFlow();
        self.closeResumePickerFlow();
        if (self.autocomplete_provider_bound) self.autocomplete_provider.deinit();
        self.command_registry.deinit();
        if (self.last_published_status_snapshot) |*snapshot| {
            snapshot.deinit(self.msg_allocator);
            self.last_published_status_snapshot = null;
        }
        self.status_data.deinit();
        self.input.deinit();
        self.event_queue.deinit();
        self.run_control.deinit();
        // Any unexpectedly undrained requests are mailbox-owned here;
        // deinit cleans them with AgentRequest.deinit.
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

    fn startAgentThread(self: *Interactive) !void {
        if (self.agent_thread != null) return;
        self.agent_thread = try std.Thread.spawn(.{}, agentThreadFn, .{self});
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

        self.active_editor = EditorInterface.init(editor_mod.Editor, &self.editor);
        self.active_editor.setOnSubmit(&onEditorSubmit, @ptrCast(self));
        self.active_editor.setOnChange(&onEditorChange, @ptrCast(self));
        self.active_editor.setTheme(self.theme);
        self.active_editor.setCwd(self.cwd);
        self.active_editor.setPaddingX(@intCast(self.settings_manager.getEditorPaddingX()));
        self.active_editor.setAutocompleteMaxVisible(@intCast(self.settings_manager.getAutocompleteMaxVisible()));
        self.active_editor.setStatusData(&self.status_data);
        self.ca.agent.bindRunControl(&self.run_control);
        self.rebuildConversationFromMessages(self.ca.agent.state.messages);
        self.syncQueueSnapshotFromRunControl();
        self.session_controller.wire();
        self.session_event_token = self.session_controller.subscribe(&sessionEventCallback, @ptrCast(self));

        self.detectGitBranch();
        try self.startAgentThread();

        // Prime the status chips via the agent-owned snapshot path before the
        // first frame. This keeps model/thinking/context reads off the TUI
        // thread even during startup.
        self.bootstrapStatusSnapshot();

        // Wire autocomplete: combined slash + file path completion.
        self.autocomplete_provider = CombinedAutocompleteProvider.init(self.allocator, &self.command_registry, self.cwd);
        self.autocomplete_provider_bound = true;
        self.active_editor.setAutocompleteProvider(self.autocomplete_provider.provider());

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
        self.performStartupAction();

        while (self.running) {
            // 1. Drain UI events (owned, thread-safe)
            var event_buf: [64]UiEvent = undefined;
            while (true) {
                const count = self.event_queue.drainInto(&event_buf);
                if (count == 0) break;
                for (event_buf[0..count]) |*ev| {
                    self.handleUiEvent(ev);
                    ev.deinit(self.msg_allocator);
                }
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
            if (self.tui.checkResize()) {
                self.cancelTranscriptSelection();
            }

            // 3b. Tick any animated components that reached their deadline.
            const now_ns = std.time.nanoTimestamp();
            if (self.tui.tickAnimations(now_ns)) {
                self.tui.dirty = true;
            }

            // 4. Render if dirty
            if (self.tui.dirty) {
                self.renderFrame();
                self.tui.dirty = false;
            }

            // 5. Sleep until the next input/animation deadline, capped so
            // timer-driven UI work still wakes promptly alongside mailbox events.
            self.sleepUntilNextLoopDeadline();
        }
    }

    fn performStartupAction(self: *Interactive) void {
        switch (self.startup_action) {
            .none => {},
            .prompt => |text| self.submitPrompt(text),
            .resume_session => |path| {
                const path_copy = self.msg_allocator.dupe(u8, path) catch {
                    self.status_text.setContent("out of memory");
                    self.status_text.fg = self.theme.fg(.@"error");
                    self.tui.dirty = true;
                    self.startup_action = .none;
                    return;
                };
                _ = self.dispatchIdleRequest(.{ .resume_session = .{ .path = path_copy } }, .{
                    .busy_message = "cannot resume while agent is running",
                    .loader_message = "Loading session...",
                    .spawn_failed_message = "failed to queue resume",
                });
            },
            .resume_picker => self.showSessionPicker(),
        }
        self.startup_action = .none;
    }

    fn bootstrapStatusSnapshot(self: *Interactive) void {
        switch (self.request_queue.trySend(.{ .refresh_status_snapshot = {} })) {
            .ok => {},
            .dropped => unreachable,
            .closed, .full, .oom => return,
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
        self.active_editor.handlePaste(content);
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
            if (keybindings.matches(.select_cancel, key)) {
                self.tui.hideOverlay();
                return;
            }
            return;
        }

        // App-level keybindings — no overlay active
        if (keybindings.matches(.app_interrupt, key)) {
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
        if (keybindings.matches(.app_clear, key)) {
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
        if (keybindings.matches(.app_exit, key)) {
            if (self.active_editor.getText().len == 0) {
                self.running = false;
                return;
            }
        }

        if (keybindings.matches(.app_toggle_tools, key)) {
            self.tool_output_expanded = !self.tool_output_expanded;
            self.transcript.setToolOutputExpanded(self.tool_output_expanded);
            self.tui.dirty = true;
            return;
        }

        if (keybindings.matches(.app_toggle_thinking, key)) {
            self.hide_thinking_block = !self.hide_thinking_block;
            self.settings_manager.setHideThinkingBlock(self.hide_thinking_block);
            self.transcript.setHideThinkingBlock(self.hide_thinking_block);
            self.tui.dirty = true;
            return;
        }

        if (keybindings.matches(.app_queue_follow_up, key)) {
            self.handleFollowUpShortcut();
            return;
        }

        if (keybindings.matches(.app_restore_queued, key)) {
            self.restoreQueuedInputsToEditor();
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

        const delta: ?i64 = if (keybindings.matches(.app_scroll_page_up, key))
            -@as(i64, @intCast(page_size))
        else if (keybindings.matches(.app_scroll_page_down, key))
            @as(i64, @intCast(page_size))
        else if (keybindings.matches(.app_scroll_line_up, key))
            -3
        else if (keybindings.matches(.app_scroll_line_down, key))
            3
        else
            null;

        if (delta) |d| {
            const w = self.tui.width();
            self.transcript.scrollBy(w, output_h, d);
            self.tui.dirty = true;
            return true;
        }
        return false;
    }

    fn handleMouse(self: *Interactive, event: keys_mod.MouseEvent) void {
        if (self.tui.hasOverlay()) {
            self.cancelTranscriptSelection();
            return;
        }

        if (event.kind == .scroll) {
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
            return;
        }

        switch (self.mouse_capture) {
            .none => {
                if (event.kind != .down or event.button != .left) return;
                const zone = self.transcriptMouseZone(event, false) orelse return;
                if (zone.zone != .inside) return;
                if (self.transcript.beginSelection(zone.width, zone.height, zone.local_x, zone.local_y)) {
                    self.mouse_capture = .{ .transcript_selection = {} };
                    self.tui.dirty = true;
                }
            },
            .transcript_selection => {
                const zone = self.transcriptMouseZone(event, true) orelse return;
                const now_ns = std.time.nanoTimestamp();
                switch (event.kind) {
                    .drag, .move => {
                        if (self.transcript.updateSelection(zone.width, zone.height, zone.local_x, zone.local_y, zone.zone, now_ns)) {
                            self.tui.dirty = true;
                        }
                    },
                    .up => {
                        _ = self.transcript.endSelection(zone.width, zone.height, zone.local_x, zone.local_y, zone.zone, now_ns);
                        self.mouse_capture = .none;
                        self.copyTranscriptSelection(zone.width);
                        self.cancelTranscriptSelection();
                        self.tui.dirty = true;
                    },
                    else => {},
                }
            },
        }
    }

    fn handleUiEvent(self: *Interactive, ev: *UiEvent) void {
        switch (ev.*) {
            .assistant_text_delta, .assistant_thinking_delta => {
                _ = self.applyConversationLiveEvent(ev.*);
                self.tui.dirty = true;
            },
            .error_message => |e| {
                self.status_text.setContent(e.message);
                self.status_text.fg = self.theme.fg(.@"error");
                self.tui.dirty = true;
            },
            .message_start_assistant => {
                _ = self.applyConversationLiveEvent(ev.*);
                self.tui.dirty = true;
            },
            .message_start_user => {
                _ = self.applyConversationLiveEvent(ev.*);
                self.transcript.scrollToBottom(self.tui.width(), self.outputHeight());
                self.tui.dirty = true;
            },
            .tool_call_streaming => {
                _ = self.applyConversationLiveEvent(ev.*);
                self.tui.dirty = true;
            },
            .message_end_assistant => |m| {
                _ = self.applyConversationLiveEvent(ev.*);
                self.tui.dirty = true;
                if (m.is_aborted) {
                    self.status_text.setContent(m.error_message orelse "aborted");
                    self.status_text.fg = self.theme.fg(.@"error");
                } else if (m.error_message) |msg| {
                    self.status_text.setContent(userFacingFailureMessage(m.failure_kind, msg));
                    self.status_text.fg = self.theme.fg(.@"error");
                }
            },
            .tool_start => |t| {
                _ = self.applyConversationLiveEvent(ev.*);
                self.status_text.setContent(t.tool_name);
                self.status_text.fg = self.theme.fg(.accent);
                self.tui.dirty = true;
            },
            .tool_update => {
                _ = self.applyConversationLiveEvent(ev.*);
                self.tui.dirty = true;
            },
            .tool_end => {
                _ = self.applyConversationLiveEvent(ev.*);
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
            .queue_snapshot => |q| {
                self.applyQueueSnapshot(q);
                self.tui.dirty = true;
            },
            .request_worker_finished => {
                // Long-lived agent owner loop finished an idle request drain.
                // Hide the loader only when the TUI actually has a pending
                // request banner to unwind; individual success/failure events
                // still own status_text and focus.
                if (self.request_in_flight) {
                    self.request_in_flight = false;
                    self.hideLoader();
                }
                self.tui.dirty = true;
            },
            .session_resumed => |r| {
                self.rebuildConversationFromMessages(r.messages);
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
            .session_new_started => {
                self.rebuildConversationFromMessages(&.{});
                self.status_text.setContent("new session started");
                self.status_text.fg = self.theme.fg(.success);
                self.tui.dirty = true;
            },
            .session_new_failed => |f| {
                self.status_text.setContent(f.message);
                self.status_text.fg = self.theme.fg(.@"error");
                self.tui.dirty = true;
            },
            .status_snapshot => |s| {
                self.applyStatusSnapshot(s);
                self.tui.dirty = true;
            },
            .model_switch_failed => |m| {
                self.status_text.setContent(m.message);
                self.status_text.fg = self.theme.fg(.@"error");
                self.tui.dirty = true;
            },
            .model_switched => {
                var buf: [80]u8 = undefined;
                const label = if (self.status_data.model_id.len > 0) self.status_data.model_id else "model switched";
                const msg = std.fmt.bufPrint(&buf, "Model: {s}", .{label}) catch "model switched";
                self.status_text.setContent(msg);
                self.status_text.fg = self.theme.fg(.success);
                self.tui.dirty = true;
            },
            .thinking_level_changed => {
                var buf: [96]u8 = undefined;
                const level = if (self.status_data.thinking_level.len > 0) self.status_data.thinking_level else "off";
                const msg = std.fmt.bufPrint(&buf, "Thinking: {s}", .{level}) catch "thinking level updated";
                self.status_text.setContent(msg);
                self.status_text.fg = self.theme.fg(.success);
                self.tui.dirty = true;
            },
            .thinking_level_change_failed => |t| {
                self.status_text.setContent(t.message);
                self.status_text.fg = self.theme.fg(.@"error");
                self.tui.dirty = true;
            },
        }
    }

    fn applyStatusSnapshot(self: *Interactive, snapshot: @FieldType(UiEvent, "status_snapshot")) void {
        self.status_data.setModelProvider(snapshot.model_provider);
        self.status_data.setModelId(snapshot.model_id);
        self.status_data.setThinkingLevel(snapshot.thinking_level);
        self.status_data.context_tokens = snapshot.context_tokens;
        self.status_data.context_window = snapshot.context_window;
    }

    fn applyQueueSnapshot(self: *Interactive, snapshot: agent_mod.QueuedMessageSnapshot) void {
        self.transcript.syncQueuedUserMessages(snapshot.steering, snapshot.follow_up);
    }

    fn syncQueueSnapshotFromRunControl(self: *Interactive) void {
        var snapshot = self.run_control.snapshot(self.allocator);
        defer snapshot.deinit(self.allocator);
        self.applyQueueSnapshot(snapshot);
    }

    fn rebuildConversationFromMessages(self: *Interactive, messages: []const agent_protocol.AgentMessage) void {
        conversation_projection_mod.rebuildFromMessages(
            &self.transcript,
            self.active_editor,
            self.resolver,
            messages,
            .{
                .theme = self.theme,
                .retry_attempt = self.retry_attempt,
            },
        );
    }

    fn applyConversationLiveEvent(self: *Interactive, ev: UiEvent) bool {
        return conversation_projection_mod.applyLiveEvent(&self.transcript, self.resolver, ev);
    }

    const TranscriptMouseZone = struct {
        zone: transcript_mod.DragZone,
        local_x: u32,
        local_y: u32,
        width: u32,
        height: u32,
    };

    fn transcriptRect(self: *Interactive) ?ChildRect {
        return self.tui.root.childRect(1);
    }

    fn transcriptMouseZone(self: *Interactive, event: keys_mod.MouseEvent, allow_outside: bool) ?TranscriptMouseZone {
        const rect = self.transcriptRect() orelse return null;
        if (rect.width == 0 or rect.height == 0) return null;

        const ex: i32 = event.x;
        const ey: i32 = event.y;
        const left: i32 = @intCast(rect.x);
        const top: i32 = @intCast(rect.y);
        const right: i32 = left + @as(i32, @intCast(rect.width));
        const bottom: i32 = top + @as(i32, @intCast(rect.height));

        if (!allow_outside and (ex < left or ex >= right or ey < top or ey >= bottom)) return null;

        const clamped_x: u32 = if (ex < left)
            0
        else if (ex >= right)
            rect.width - 1
        else
            @intCast(ex - left);

        const zone: transcript_mod.DragZone = if (ey < top)
            .above
        else if (ey >= bottom)
            .below
        else
            .inside;
        if (!allow_outside and zone != .inside) return null;

        const local_y: u32 = switch (zone) {
            .inside => @intCast(ey - top),
            .above => 0,
            .below => rect.height - 1,
        };

        return .{
            .zone = zone,
            .local_x = clamped_x,
            .local_y = local_y,
            .width = rect.width,
            .height = rect.height,
        };
    }

    fn cancelTranscriptSelection(self: *Interactive) void {
        self.transcript.cancelSelection();
        self.mouse_capture = .none;
    }

    fn copyTranscriptSelection(self: *Interactive, width: u32) void {
        const selected = self.transcript.selectedText(self.allocator, width) catch return;
        const text = selected orelse return;
        defer self.allocator.free(text);

        clipboard_mod.copyText(text);
        self.status_text.setContent("copied selection");
        self.status_text.fg = self.theme.fg(.success);
    }

    fn outputHeight(self: *Interactive) u32 {
        const h = self.tui.height();
        const w = self.tui.width();
        const max_h = @max(3, h * 30 / 100);
        self.active_editor.setMaxVisibleLines(max_h);

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
        self.loader.shimmer_edge_fg = self.theme.fg(.muted);
        self.loader.message_fg = self.theme.fg(.dim);
        self.loader.shimmer_peak_fg = Color.rgb(0xF2, 0xF1, 0xEF);
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
                "Retrying ({d}/{d}) in {d}s… (Esc to cancel)",
                .{ attempt, max_attempts, delay_seconds },
            ) catch "Retrying…"
        else
            std.fmt.bufPrint(&buf, "Retrying ({d}/{d})…", .{ attempt, max_attempts }) catch "Retrying…";
        self.loader.shimmer_edge_fg = self.theme.fg(.warning);
        self.loader.message_fg = self.theme.fg(.dim);
        self.loader.shimmer_peak_fg = Color.rgb(0xF2, 0xF1, 0xEF);
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
                self.active_editor.setGitBranch(branch);
            }
        }
    }

    fn nextLoopDeadlineNs(self: *Interactive, now_ns: i128) ?i128 {
        var next_deadline: ?i128 = null;

        if (self.input.flush_deadline_ns) |deadline| {
            next_deadline = deadline;
        }
        if (self.kitty_deadline_ns) |deadline| {
            next_deadline = if (next_deadline) |cur| @min(cur, deadline) else deadline;
        }
        if (self.tui.nextAnimationDeadline(now_ns)) |deadline| {
            next_deadline = if (next_deadline) |cur| @min(cur, deadline) else deadline;
        }

        return next_deadline;
    }

    fn sleepUntilNextLoopDeadline(self: *Interactive) void {
        const now_ns = std.time.nanoTimestamp();
        const max_idle_sleep_ns: i128 = 8_333_334; // ≈120 FPS cap while still honoring timer deadlines even with mailbox wakeups
        const timeout_ns: i128 = if (self.nextLoopDeadlineNs(now_ns)) |deadline|
            if (deadline <= now_ns) 0 else @min(deadline - now_ns, max_idle_sleep_ns)
        else
            max_idle_sleep_ns;
        const timeout_ms: i32 = @intCast(@divFloor(timeout_ns + 999_999, 1_000_000));

        var pfds = [2]posix.pollfd{
            .{
                .fd = self.tui.terminal.fd_in,
                .events = posix.POLL.IN,
                .revents = 0,
            },
            .{
                .fd = self.event_queue.wakeReadFd().?,
                .events = posix.POLL.IN,
                .revents = 0,
            },
        };

        const ready = posix.poll(&pfds, timeout_ms) catch return;
        if (ready <= 0) return;
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
        self.active_editor.setMaxVisibleLines(max_h);

        // Render via TUI (root tree + overlays) and get cursor state
        if (self.tui.render()) |cs| {
            self.tui.terminal.showCursor();
            self.tui.terminal.setCursorPos(cs.x, cs.y);
        } else {
            self.tui.terminal.hideCursor();
        }
    }

    // --- Editor callbacks ---

    fn onEditorChange(_: []const u8, ctx: ?*anyopaque) void {
        const self: *Interactive = @ptrCast(@alignCast(ctx));
        self.refreshGreeterVisibility();
        self.tui.dirty = true;
    }

    fn queueMessageWhileStreaming(self: *Interactive, kind: QueuedInputKind, text: []const u8) void {
        const msg: agent_protocol.AgentMessage = .{ .user = .{
            .content = .{ .text = text },
            .timestamp = std.time.milliTimestamp(),
        } };
        const result = self.run_control.enqueue(switch (kind) {
            .steering => .steering,
            .follow_up => .follow_up,
        }, msg);
        switch (result) {
            .ok => {},
            .closed, .oom => {
                self.status_text.setContent("agent unavailable");
                self.status_text.fg = self.theme.fg(.@"error");
                self.tui.dirty = true;
                return;
            },
        }
        self.syncQueueSnapshotFromRunControl();
        self.active_editor.clear();
        self.refreshGreeterVisibility();
        self.tui.dirty = true;
    }

    fn restoreQueuedInputsToEditor(self: *Interactive) void {
        var snapshot = self.run_control.clearAndSnapshot(self.allocator);
        defer snapshot.deinit(self.allocator);

        const count = snapshot.steering.len + snapshot.follow_up.len;
        if (count == 0) {
            self.status_text.setContent("no queued messages");
            self.status_text.fg = self.theme.fg(.muted);
            self.tui.dirty = true;
            return;
        }

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);

        for (snapshot.steering) |entry| {
            if (buf.items.len > 0) buf.appendSlice(self.allocator, "\n\n") catch return;
            buf.appendSlice(self.allocator, entry.text) catch return;
        }
        for (snapshot.follow_up) |entry| {
            if (buf.items.len > 0) buf.appendSlice(self.allocator, "\n\n") catch return;
            buf.appendSlice(self.allocator, entry.text) catch return;
        }

        const current_text = self.active_editor.getText();
        if (current_text.len > 0) {
            if (buf.items.len > 0) buf.appendSlice(self.allocator, "\n\n") catch return;
            buf.appendSlice(self.allocator, current_text) catch return;
        }

        self.active_editor.setText(buf.items);
        self.syncQueueSnapshotFromRunControl();
        self.refreshGreeterVisibility();
        self.status_text.setContent(if (count == 1) "restored 1 queued message" else "restored queued messages");
        self.status_text.fg = self.theme.fg(.success);
        self.tui.dirty = true;
    }

    fn submitPrompt(self: *Interactive, text: []const u8) void {
        if (self.request_in_flight) {
            self.status_text.setContent("agent is busy");
            self.status_text.fg = self.theme.fg(.@"error");
            self.tui.dirty = true;
            return;
        }

        const prompt_copy = self.msg_allocator.dupe(u8, text) catch return;

        switch (self.request_queue.trySend(.{ .prompt = .{ .text = prompt_copy } })) {
            .ok => {},
            .dropped => unreachable,
            .closed, .full, .oom => |rejected| {
                var failed_req = rejected;
                failed_req.deinit(self.msg_allocator);
                self.tui.setFocus(self.active_editor.component());
                self.status_text.setContent("agent unavailable");
                self.status_text.fg = self.theme.fg(.@"error");
                self.tui.dirty = true;
                return;
            },
        }

        self.active_editor.clear();
        self.refreshGreeterVisibility();
        self.is_streaming = true;
        self.showLoader("Working…");
        self.tui.dirty = true;
    }

    fn handleSubmittedText(self: *Interactive, text: []const u8, queued_kind: ?QueuedInputKind) void {
        if (text.len == 0) return;

        self.active_editor.addToHistory(text);

        if (text[0] == '/' and self.dispatchSlashCommand(text)) return;

        if (queued_kind) |kind| {
            self.queueMessageWhileStreaming(kind, text);
            return;
        }

        self.submitPrompt(text);
    }

    fn handleFollowUpShortcut(self: *Interactive) void {
        const expanded = self.active_editor.getExpandedText();
        const text = std.mem.trim(u8, expanded, " \t\r\n");
        if (text.len == 0) return;

        if (self.is_streaming) {
            self.handleSubmittedText(text, .follow_up);
            return;
        }

        self.handleSubmittedText(text, null);
    }

    fn onEditorSubmit(text: []const u8, ctx: ?*anyopaque) void {
        const self: *Interactive = @ptrCast(@alignCast(ctx));
        self.handleSubmittedText(text, if (self.is_streaming) .steering else null);
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
            if (std.mem.eql(u8, name, "clear")) {
                self.transcript.clearAll();
                self.status_text.setContent("");
                self.tui.dirty = true;
                return true;
            }
            if (std.mem.eql(u8, name, "new")) {
                _ = self.dispatchIdleRequest(.{ .new_session = {} }, .{
                    .busy_message = "cannot start a new session while agent is running",
                    .loader_message = "Starting new session...",
                    .spawn_failed_message = "failed to queue new session",
                });
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
            if (std.mem.eql(u8, name, "settings")) {
                self.showSettingsPicker();
                return true;
            }
            if (std.mem.eql(u8, name, "hotkeys")) {
                self.showHotkeysOverlay();
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
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const scratch = arena.allocator();

        const path = self.memory_diagnostics.writeSnapshotFile(scratch, self.cwd, null) catch {
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
            .surface = .{ .fill = Color.default },
        };
    }

    fn centerDialogOptions(self: *Interactive) overlay_mod.OverlayOptions {
        var options = overlay_mod.OverlayPresets.centerDialog();
        const width = self.tui.width();
        const header_h = self.header_container.measure(width).preferred_height;
        options.margin_top = header_h;
        options.margin_bottom = 1;
        options.surface = .{ .fill = self.theme.bg(.tool_pending_bg) };
        return options;
    }

    fn showHotkeysOverlay(self: *Interactive) void {
        self.cancelTranscriptSelection();
        _ = self.tui.showOverlay(self.hotkeys_overlay.component(), self.centerDialogOptions());
    }

    fn configureSimplePicker(
        self: *Interactive,
        picker: *ListPicker,
        title: []const u8,
        max_visible: u32,
        items: []const SelectItem,
        on_select: ?*const fn (selection: PickerSelection, ctx: ?*anyopaque) void,
        on_cancel: ?*const fn (ctx: ?*anyopaque) void,
    ) void {
        picker.* = ListPicker.init(self.theme);
        picker.title = title;
        picker.list.max_visible = max_visible;
        picker.setItems(items);
        picker.on_select = on_select;
        picker.on_cancel = on_cancel;
        picker.callback_ctx = @ptrCast(self);
    }

    fn showSimplePickerOverlay(
        self: *Interactive,
        handle: *?tui_mod.OverlayHandle,
        picker: *ListPicker,
    ) void {
        self.cancelTranscriptSelection();
        self.hideSimplePickerOverlay(handle);
        handle.* = self.tui.showOverlay(picker.component(), self.bottomPanelOptions());
    }

    fn hideSimplePickerOverlay(self: *Interactive, handle: *?tui_mod.OverlayHandle) void {
        _ = self;
        if (handle.*) |h| {
            handle.* = null;
            h.hide();
        }
    }

    fn dispatchIdleRequest(self: *Interactive, req: AgentRequest, options: IdleRequestDispatch) bool {
        if (self.is_streaming or self.request_in_flight) {
            var rejected = req;
            rejected.deinit(self.msg_allocator);
            self.status_text.setContent(options.busy_message);
            self.status_text.fg = self.theme.fg(.@"error");
            self.tui.dirty = true;
            return false;
        }

        switch (self.request_queue.trySend(req)) {
            .ok => {},
            .dropped => unreachable,
            .closed, .full, .oom => |rejected| {
                var failed_req = rejected;
                failed_req.deinit(self.msg_allocator);
                self.status_text.setContent(options.spawn_failed_message);
                self.status_text.fg = self.theme.fg(.@"error");
                self.tui.dirty = true;
                return false;
            },
        }
        self.request_in_flight = true;
        self.showLoader(options.loader_message);
        self.tui.dirty = true;
        return true;
    }

    // ── Session picker (/resume) ────────────────────────────────

    fn closeResumePickerFlow(self: *Interactive) void {
        if (self.resume_picker_flow) |*flow| {
            if (flow.handle) |h| {
                flow.handle = null;
                h.hide();
            }
            flow.deinit();
        }
        self.resume_picker_flow = null;
    }

    fn showSessionPicker(self: *Interactive) void {
        // zi-wub.26: cwd lives on the TUI side (Interactive was
        // constructed with it; editor.cwd is the canonical copy).
        // Reading from ca.session_store.writer.cwd would reach into
        // agent-owned state from the TUI thread, violating the
        // doctrine. The session store path tracks the *current*
        // session's cwd which in zi is always the process cwd
        // (we don't support per-session cwd switching), so this is
        // strictly equivalent.
        self.closeResumePickerFlow();
        var flow = ResumePickerFlow.init(self.allocator, self.theme, self.cwd) catch {
            self.status_text.setContent("failed to list sessions");
            self.status_text.fg = self.theme.fg(.@"error");
            return;
        };
        errdefer flow.deinit();

        if (flow.rows.len == 0) {
            self.status_text.setContent("no sessions found");
            self.status_text.fg = self.theme.fg(.muted);
            return;
        }

        flow.picker.on_select = &onSessionSelected;
        flow.picker.on_cancel = &onSessionPickerCancel;
        flow.picker.callback_ctx = @ptrCast(self);
        self.cancelTranscriptSelection();
        self.resume_picker_flow = flow;
        self.resume_picker_flow.?.handle = self.tui.showOverlay(
            self.resume_picker_flow.?.picker.component(),
            self.bottomPanelOptions(),
        );
    }

    fn onSessionSelected(selection: PickerSelection, ctx: ?*anyopaque) void {
        const self: *Interactive = @ptrCast(@alignCast(ctx));
        const path = if (self.resume_picker_flow) |*flow|
            if (selection.source_index < flow.rows.len) flow.rows[selection.source_index].path else null
        else
            null;

        const selected_path = path orelse {
            self.closeResumePickerFlow();
            self.status_text.setContent("session not found");
            self.status_text.fg = self.theme.fg(.@"error");
            return;
        };

        // Clone path into msg_allocator (doctrine R3: cross-thread
        // payload slices must be thread-safe allocated).
        const path_copy = self.msg_allocator.dupe(u8, selected_path) catch {
            self.closeResumePickerFlow();
            self.status_text.setContent("out of memory");
            self.status_text.fg = self.theme.fg(.@"error");
            return;
        };
        self.closeResumePickerFlow();
        _ = self.dispatchIdleRequest(.{ .resume_session = .{ .path = path_copy } }, .{
            .busy_message = "cannot resume while agent is running",
            .loader_message = "Loading session...",
            .spawn_failed_message = "failed to queue resume",
        });
    }

    fn onSessionPickerCancel(ctx: ?*anyopaque) void {
        const self: *Interactive = @ptrCast(@alignCast(ctx));
        self.closeResumePickerFlow();
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
        // err strings and we display them inline, then drop them. This
        // never crosses threads, so keep it on the TUI-local allocator.
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
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

    fn closeModelPickerFlow(self: *Interactive) void {
        if (self.model_picker_flow) |*flow| {
            if (flow.handle) |h| {
                flow.handle = null;
                h.hide();
            }
            flow.deinit();
        }
        self.model_picker_flow = null;
    }

    fn showModelPicker(self: *Interactive) void {
        self.closeModelPickerFlow();
        var flow = ModelPickerFlow.init(self.allocator, self.theme, self.model_catalog, self.auth_storage) catch {
            self.status_text.setContent("failed to build model picker");
            self.status_text.fg = self.theme.fg(.@"error");
            return;
        };
        errdefer flow.deinit();

        if (flow.rows.len == 0) {
            self.status_text.setContent("no models available");
            self.status_text.fg = self.theme.fg(.muted);
            return;
        }

        flow.picker.on_select = &onModelSelected;
        flow.picker.on_cancel = &onModelPickerCancel;
        flow.picker.callback_ctx = @ptrCast(self);
        for (flow.rows, 0..) |row, i| {
            if (std.mem.eql(u8, json_util.providerToString(row.model.provider), self.status_data.model_provider) and
                std.mem.eql(u8, row.model.id, self.status_data.model_id))
            {
                flow.picker.setInitialSelectionIndex(i);
                break;
            }
        }
        self.cancelTranscriptSelection();
        self.model_picker_flow = flow;
        self.model_picker_flow.?.handle = self.tui.showOverlay(
            self.model_picker_flow.?.picker.component(),
            self.bottomPanelOptions(),
        );
    }

    fn onModelSelected(selection: PickerSelection, ctx: ?*anyopaque) void {
        const self: *Interactive = @ptrCast(@alignCast(ctx));
        const selected_model = if (self.model_picker_flow) |*flow|
            if (selection.source_index < flow.rows.len) flow.rows[selection.source_index].model else null
        else
            null;

        self.closeModelPickerFlow();

        const m = selected_model orelse {
            self.status_text.setContent("model not found");
            self.status_text.fg = self.theme.fg(.@"error");
            return;
        };

        self.applyModelSwitch(m);
    }

    fn onModelPickerCancel(ctx: ?*anyopaque) void {
        const self: *Interactive = @ptrCast(@alignCast(ctx));
        self.closeModelPickerFlow();
    }

    /// Enqueue a /model switch through the AgentRequest queue
    /// (zi-wub.16). The actual mutation runs on the agent thread
    /// inside `handleSetModel`. Semantic state flows back via
    /// `status_snapshot`; `.model_switched` / `.model_switch_failed`
    /// are banner outcomes.
    ///
    /// Model is a static catalog value (its slices live forever in
    /// `ai_models`), so we pass it by value into the request without
    /// cloning the inner strings.
    fn applyModelSwitch(self: *Interactive, m: ai_protocol.Model) void {
        _ = self.dispatchIdleRequest(.{ .set_model = .{ .model = m } }, .{
            .busy_message = "cannot switch model while agent is running",
            .loader_message = "Switching model...",
            .spawn_failed_message = "failed to queue model switch",
        });
    }

    // ── Settings picker (/settings) ─────────────────────────────

    fn showSettingsPicker(self: *Interactive) void {
        var count: usize = 0;

        self.settings_picker_items[count] = .{
            .value = "thinking",
            .label = "Thinking level",
            .description = currentThinkingSettingsDescription(self),
        };
        self.settings_picker_actions[count] = .open_thinking;
        count += 1;

        self.settings_picker_items[count] = .{
            .value = "hide-thinking",
            .label = "Hide thinking",
            .description = if (self.hide_thinking_block) "On" else "Off",
        };
        self.settings_picker_actions[count] = .toggle_hide_thinking;
        count += 1;

        self.settings_picker_count = count;
        self.configureSimplePicker(
            &self.settings_picker,
            "Settings",
            10,
            self.settings_picker_items[0..count],
            &onSettingsSelected,
            &onSettingsPickerCancel,
        );
        self.showSimplePickerOverlay(&self.settings_picker_handle, &self.settings_picker);
    }

    fn onSettingsSelected(selection: PickerSelection, ctx: ?*anyopaque) void {
        const self: *Interactive = @ptrCast(@alignCast(ctx));
        self.hideSimplePickerOverlay(&self.settings_picker_handle);
        if (selection.source_index >= self.settings_picker_count) return;

        switch (self.settings_picker_actions[selection.source_index]) {
            .open_thinking => self.showThinkingLevelPicker(),
            .toggle_hide_thinking => {
                self.hide_thinking_block = !self.hide_thinking_block;
                self.settings_manager.setHideThinkingBlock(self.hide_thinking_block);
                self.transcript.setHideThinkingBlock(self.hide_thinking_block);
                self.status_text.setContent(if (self.hide_thinking_block) "thinking hidden" else "thinking shown");
                self.status_text.fg = self.theme.fg(.success);
                self.tui.dirty = true;
            },
        }
    }

    fn onSettingsPickerCancel(ctx: ?*anyopaque) void {
        const self: *Interactive = @ptrCast(@alignCast(ctx));
        self.hideSimplePickerOverlay(&self.settings_picker_handle);
    }

    fn showThinkingLevelPicker(self: *Interactive) void {
        const model = currentStatusModel(self) orelse {
            self.status_text.setContent("current model unavailable");
            self.status_text.fg = self.theme.fg(.@"error");
            self.tui.dirty = true;
            return;
        };
        const available = coding_agent_mod.AgentSession.getAvailableThinkingLevelsForModel(model);
        const count = @min(available.len, self.thinking_picker_items.len);
        for (0..count) |i| {
            const level = available[i];
            self.thinking_picker_levels[i] = level;
            self.thinking_picker_items[i] = .{
                .value = agentThinkingValue(level),
                .label = agentThinkingValue(level),
                .description = thinkingDescription(level),
            };
        }
        self.thinking_picker_count = count;
        self.configureSimplePicker(
            &self.thinking_picker,
            "Thinking level",
            8,
            self.thinking_picker_items[0..count],
            &onThinkingLevelSelected,
            &onThinkingLevelPickerCancel,
        );
        self.thinking_picker.setInitialSelectionByValue(if (self.status_data.thinking_level.len > 0) self.status_data.thinking_level else "off");
        self.showSimplePickerOverlay(&self.thinking_picker_handle, &self.thinking_picker);
    }

    fn onThinkingLevelSelected(selection: PickerSelection, ctx: ?*anyopaque) void {
        const self: *Interactive = @ptrCast(@alignCast(ctx));
        self.hideSimplePickerOverlay(&self.thinking_picker_handle);

        if (selection.source_index < self.thinking_picker_count) {
            self.applyThinkingLevelChange(self.thinking_picker_levels[selection.source_index]);
        }
    }

    fn onThinkingLevelPickerCancel(ctx: ?*anyopaque) void {
        const self: *Interactive = @ptrCast(@alignCast(ctx));
        self.hideSimplePickerOverlay(&self.thinking_picker_handle);
    }

    fn applyThinkingLevelChange(self: *Interactive, level: agent_protocol.ThinkingLevel) void {
        _ = self.dispatchIdleRequest(.{ .set_thinking_level = .{ .level = level } }, .{
            .busy_message = "cannot change thinking level while agent is running",
            .loader_message = "Updating thinking level...",
            .spawn_failed_message = "failed to queue thinking-level change",
        });
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

        self.configureSimplePicker(
            &self.login_picker,
            "Login",
            8,
            self.login_picker_items[0..count],
            &onLoginProviderSelected,
            &onLoginPickerCancel,
        );
        self.showSimplePickerOverlay(&self.login_picker_handle, &self.login_picker);
    }

    fn onLoginProviderSelected(selection: PickerSelection, ctx: ?*anyopaque) void {
        const self: *Interactive = @ptrCast(@alignCast(ctx));
        self.hideSimplePickerOverlay(&self.login_picker_handle);
        self.startLogin(selection.item.value);
    }

    fn onLoginPickerCancel(ctx: ?*anyopaque) void {
        const self: *Interactive = @ptrCast(@alignCast(ctx));
        self.hideSimplePickerOverlay(&self.login_picker_handle);
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
        logging.setThreadLabel(.login);

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

    fn publishQueueSnapshot(self: *Interactive) void {
        const snapshot = self.run_control.snapshot(self.msg_allocator);
        self.event_queue.push(.{ .queue_snapshot = snapshot });
    }

    /// Long-lived agent owner thread entry point. This is the only
    /// path that runs agent-owned mutations: it binds lua ownership,
    /// blocks on the request inbox wake fd, drains queued work, and
    /// tears down extensions on exit after an ordered shutdown request
    /// or after the inbox has been transport-closed and fully drained.
    ///
    /// Completion events stay semantic rather than thread-shaped:
    ///   - prompt requests publish `.prompt_worker_finished`
    ///   - non-prompt request drains publish `.request_worker_finished`
    fn agentThreadFn(self: *Interactive) void {
        logging.setThreadLabel(.agent);

        if (self.ca.extensionRunner()) |runner| {
            runner.bindLuaOwnerThread(std.Thread.getCurrentId());
        }

        while (true) {
            _ = self.request_queue.waitReadable(-1) catch break;
            if (self.request_queue.isDrained()) break;
            if (!self.processAgentRequests()) break;
            if (self.request_queue.isDrained()) break;
        }

        self.ca.shutdownExtensionsOnAgentThread();
    }

    fn enqueueAgentShutdown(self: *Interactive) void {
        switch (self.request_queue.trySend(.{ .shutdown = {} })) {
            .ok, .dropped => {},
            .closed, .full, .oom => {},
        }
    }

    fn discardAgentRequests(self: *Interactive, requests: []AgentRequest) void {
        for (requests) |*req| req.deinit(self.msg_allocator);
    }

    fn discardQueuedAgentRequests(self: *Interactive) void {
        var buf: [16]AgentRequest = undefined;
        while (true) {
            const n = self.request_queue.drainInto(&buf);
            if (n == 0) return;
            self.discardAgentRequests(buf[0..n]);
        }
    }

    /// Drain the AgentRequest inbox and dispatch each request on the
    /// long-lived agent owner thread. Returns `false` when an in-band
    /// shutdown request terminates the owner loop after all earlier work.
    fn processAgentRequests(self: *Interactive) bool {
        var buf: [16]AgentRequest = undefined;
        while (true) {
            const n = self.request_queue.drainInto(&buf);
            if (n == 0) return true;

            var idle_processed = false;
            var prompt_processed = false;
            var request_drain_active = false;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                var req = &buf[i];
                switch (req.*) {
                    .prompt => |p| {
                        prompt_processed = true;
                        const outcome = self.session_controller.runPrompt(p.text) catch |err| {
                            const err_msg = self.msg_allocator.dupe(u8, @errorName(err)) catch null;
                            self.event_queue.push(.{ .prompt_worker_finished = .{
                                .outcome = .assistant_error,
                                .internal_error = err_msg,
                            } });
                            req.deinit(self.msg_allocator);
                            continue;
                        };
                        self.event_queue.push(.{ .prompt_worker_finished = .{ .outcome = outcome } });
                    },
                    .resume_session => |r| {
                        if (!request_drain_active) {
                            self.session_controller.beginRequestDrain();
                            request_drain_active = true;
                        }
                        idle_processed = true;
                        self.handleResumeSession(r.path);
                    },
                    .new_session => {
                        if (!request_drain_active) {
                            self.session_controller.beginRequestDrain();
                            request_drain_active = true;
                        }
                        idle_processed = true;
                        self.handleNewSession();
                    },
                    .set_model => |s| {
                        if (!request_drain_active) {
                            self.session_controller.beginRequestDrain();
                            request_drain_active = true;
                        }
                        idle_processed = true;
                        self.handleSetModel(s.model);
                    },
                    .set_thinking_level => |s| {
                        if (!request_drain_active) {
                            self.session_controller.beginRequestDrain();
                            request_drain_active = true;
                        }
                        idle_processed = true;
                        self.handleSetThinkingLevel(s.level);
                    },
                    .refresh_status_snapshot => {
                        if (!request_drain_active) {
                            self.session_controller.beginRequestDrain();
                            request_drain_active = true;
                        }
                        idle_processed = true;
                        self.publishStatusSnapshot();
                    },
                    .shutdown => {
                        req.deinit(self.msg_allocator);
                        self.discardAgentRequests(buf[i + 1 .. n]);
                        self.discardQueuedAgentRequests();
                        if (request_drain_active) self.session_controller.finishRequestDrain();
                        return false;
                    },
                }
                req.deinit(self.msg_allocator);
            }

            if (request_drain_active) self.session_controller.finishRequestDrain();
            if (idle_processed and !prompt_processed) {
                self.event_queue.push(.{ .request_worker_finished = {} });
            }
        }
    }

    fn handleNewSession(self: *Interactive) void {
        self.ca.startNewSession() catch |err| {
            const msg = std.fmt.allocPrint(self.msg_allocator, "failed to start new session: {s}", .{@errorName(err)}) catch return;
            self.event_queue.push(.{ .session_new_failed = .{ .message = msg } });
            return;
        };
        self.publishQueueSnapshot();
        self.publishStatusSnapshot();
        self.event_queue.push(.{ .session_new_started = {} });
    }

    /// Agent-thread handler for `AgentRequest.resume_session`.
    /// Loads the session via `openSession` (agent_arena allocated),
    /// deep-clones the resolved AgentMessage snapshot into
    /// `msg_allocator` (doctrine R3), and publishes either
    /// `.session_resumed` or `.session_resume_failed` back to the TUI.
    ///
    /// Transcript rebuild stays on the TUI thread — this handler
    /// does NOT touch `self.transcript`. That's .15's whole point.
    fn handleResumeSession(self: *Interactive, path: []const u8) void {
        var loaded = coding_agent_mod.openSession(self.ca.allocator, path) catch {
            const msg = self.msg_allocator.dupe(u8, "failed to load session") catch return;
            self.event_queue.push(.{ .session_resume_failed = .{ .message = msg } });
            return;
        };
        defer loaded.deinit();

        // Agent-thread state mutations (doctrine: session_store +
        // ca.agent.state are agent-owned). Safe here — we're on the
        // agent thread and no stream is in flight.
        var new_store = loaded.takeStore();
        errdefer new_store.deinit();
        self.ca.replaceSessionStore(new_store) catch {
            const msg = self.msg_allocator.dupe(u8, "failed to bind resumed session") catch return;
            self.event_queue.push(.{ .session_resume_failed = .{ .message = msg } });
            return;
        };
        self.ca.agent.loadMessages(loaded.messages);
        self.ca.agent.state.thinking_level = parseAgentThinkingLevel(loaded.thinking_level);

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

        // Clone the resolved AgentMessage snapshot into msg_allocator
        // so the TUI can reconstruct transcript state without any
        // borrowed pointers crossing the queue boundary.
        const owned_messages = message_memory.cloneMessages(self.msg_allocator, loaded.messages) catch {
            if (restore_warning) |warning| self.msg_allocator.free(warning);
            const msg = self.msg_allocator.dupe(u8, "out of memory building resume snapshot") catch return;
            self.event_queue.push(.{ .session_resume_failed = .{ .message = msg } });
            return;
        };
        self.publishQueueSnapshot();
        self.publishStatusSnapshot();
        self.event_queue.push(.{ .session_resumed = message_memory.SessionResumeSnapshot.initOwned(
            owned_messages,
            restore_warning,
        ) });
    }

    /// Agent-thread handler for `AgentRequest.set_model` (zi-wub.16).
    /// Delegates the canonical validation + mutation path to
    /// `AgentSession.trySetModel`, then translates the typed outcome
    /// into a TUI-owned event payload.
    fn handleSetModel(self: *Interactive, m: ai_protocol.Model) void {
        switch (self.ca.trySetModel(m)) {
            .success => |_| {
                self.publishStatusSnapshot();
                self.event_queue.push(.{ .model_switched = {} });
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

    fn publishStatusSnapshot(self: *Interactive) void {
        const snapshot = self.ca.statusSnapshot();
        if (self.shouldSkipStatusSnapshotPublish(snapshot)) return;

        const provider_copy = self.msg_allocator.dupe(u8, snapshot.model_provider) catch return;
        errdefer self.msg_allocator.free(provider_copy);
        const model_id_copy = self.msg_allocator.dupe(u8, snapshot.model_id) catch return;
        errdefer self.msg_allocator.free(model_id_copy);
        const thinking_copy = self.msg_allocator.dupe(u8, agentThinkingLabel(snapshot.thinking_level)) catch return;
        errdefer self.msg_allocator.free(thinking_copy);

        self.rememberPublishedStatusSnapshot(snapshot);
        self.event_queue.push(.{ .status_snapshot = .{
            .model_provider = provider_copy,
            .model_id = model_id_copy,
            .thinking_level = thinking_copy,
            .context_tokens = snapshot.context_tokens,
            .context_window = snapshot.context_window,
        } });
    }

    fn shouldSkipStatusSnapshotPublish(
        self: *const Interactive,
        snapshot: AgentSession.StatusSnapshot,
    ) bool {
        const last = self.last_published_status_snapshot orelse return false;
        return last.eql(snapshot);
    }

    fn rememberPublishedStatusSnapshot(
        self: *Interactive,
        snapshot: AgentSession.StatusSnapshot,
    ) void {
        const replacement = PublishedStatusSnapshot.init(self.msg_allocator, snapshot) catch return;
        if (self.last_published_status_snapshot) |*last| {
            last.deinit(self.msg_allocator);
        }
        self.last_published_status_snapshot = replacement;
    }

    fn publishStatusSnapshotForAgentEvent(self: *Interactive, event: AgentEvent) void {
        switch (event) {
            // Status chips reflect current semantic state, so publish at
            // message commit boundaries instead of waiting for turn_end.
            .message_end => self.publishStatusSnapshot(),
            else => {},
        }
    }

    fn publishQueueSnapshotForAgentEvent(self: *Interactive, event: AgentEvent) void {
        switch (event) {
            .message_start => |ms| switch (ms.message) {
                .user => self.publishQueueSnapshot(),
                else => {},
            },
            else => {},
        }
    }

    fn handleSetThinkingLevel(self: *Interactive, level: agent_protocol.ThinkingLevel) void {
        _ = self.ca.trySetThinkingLevel(level);
        self.publishStatusSnapshot();
        self.event_queue.push(.{ .thinking_level_changed = {} });
    }

    /// Session event callback — runs on the AGENT THREAD.
    fn sessionEventCallback(event: SessionEvent, ctx: ?*anyopaque) void {
        const self: *Interactive = @ptrCast(@alignCast(ctx));
        switch (event) {
            .agent_event => |agent_event| {
                self.publishQueueSnapshotForAgentEvent(agent_event);
                if (convertAgentEvent(agent_event, self.msg_allocator)) |ui_event| {
                    self.event_queue.push(ui_event);
                }
                self.publishStatusSnapshotForAgentEvent(agent_event);
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
            .compaction_start => {},
            .compaction_end => {
                self.publishStatusSnapshot();
            },
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
        .invalid_request => if (string_util.containsCI(raw_message, "content_filter"))
            "request blocked by the provider safety filter. try rephrasing and try again."
        else
            raw_message,
        else => raw_message,
    };
}

fn cloneUserDisplayText(allocator: std.mem.Allocator, user: ai_protocol.UserMessage) ?[]u8 {
    return switch (user.content) {
        .text => |text| if (text.len == 0) null else allocator.dupe(u8, text) catch null,
        .blocks => |blocks| blk: {
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(allocator);
            for (blocks) |block| {
                switch (block) {
                    .text => |text| out.appendSlice(allocator, text.text) catch return null,
                    .image => {},
                }
            }
            if (out.items.len == 0) break :blk null;
            break :blk out.toOwnedSlice(allocator) catch null;
        },
    };
}

/// Convert an AgentEvent to a TUI-owned UiEvent with deep-copied data.
/// Runs on the agent thread. Returns null for events the TUI doesn't need.
fn convertAgentEvent(event: AgentEvent, allocator: std.mem.Allocator) ?UiEvent {
    switch (event) {
        .message_start => |ms| {
            return switch (ms.message) {
                .assistant => .message_start_assistant,
                .user => |user| blk: {
                    const text = cloneUserDisplayText(allocator, user) orelse break :blk null;
                    break :blk .{ .message_start_user = .{ .text = text } };
                },
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

fn agentThinkingValue(level: agent_protocol.ThinkingLevel) []const u8 {
    return switch (level) {
        .off => "off",
        .minimal => "minimal",
        .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => "xhigh",
    };
}

fn parseAgentThinkingLevel(value: []const u8) agent_protocol.ThinkingLevel {
    if (std.mem.eql(u8, value, "minimal")) return .minimal;
    if (std.mem.eql(u8, value, "low")) return .low;
    if (std.mem.eql(u8, value, "medium")) return .medium;
    if (std.mem.eql(u8, value, "high")) return .high;
    if (std.mem.eql(u8, value, "xhigh")) return .xhigh;
    return .off;
}

fn currentThinkingSettingsDescription(self: *const Interactive) []const u8 {
    const model = currentStatusModel(self) orelse return "Current model unavailable";
    if (!model.reasoning) return "Current model does not support thinking";
    return if (self.status_data.thinking_level.len > 0) self.status_data.thinking_level else "off";
}

fn currentStatusModel(self: *const Interactive) ?ai_protocol.Model {
    for (self.model_catalog) |model| {
        if (std.mem.eql(u8, json_util.providerToString(model.provider), self.status_data.model_provider) and
            std.mem.eql(u8, model.id, self.status_data.model_id))
        {
            return model;
        }
    }
    return null;
}

fn thinkingDescription(level: agent_protocol.ThinkingLevel) []const u8 {
    return switch (level) {
        .off => "No reasoning",
        .minimal => "Very brief reasoning (~1k tokens)",
        .low => "Light reasoning (~2k tokens)",
        .medium => "Moderate reasoning (~8k tokens)",
        .high => "Deep reasoning (~16k tokens)",
        .xhigh => "Maximum reasoning (~32k tokens)",
    };
}
