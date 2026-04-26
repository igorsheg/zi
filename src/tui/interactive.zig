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
const status_line_mod = @import("components/status_line.zig");
const greeter_mod = @import("components/greeter.zig");
const footer_mod = @import("components/footer.zig");
const editor_mod = @import("components/editor.zig");
const hotkeys_overlay_mod = @import("components/hotkeys_overlay.zig");
const ui_event_mod = @import("ui_event.zig");
const transcript_mod = @import("transcript.zig");
const conversation_projection_mod = @import("conversation_projection.zig");
const container_mod = @import("container.zig");
const overlay_mod = @import("overlay.zig");
const tool_display_mod = @import("tool_display.zig");
const theme_mod = @import("theme.zig");
const app_meta = @import("../app_meta.zig");
const tui_mod = @import("tui.zig");
const editor_iface_mod = @import("editor_iface.zig");
const input_buffer_mod = @import("input_buffer.zig");
const status_data_mod = @import("status_data.zig");
const clipboard_mod = @import("clipboard.zig");
const image_mod = @import("../image/root.zig");
const profile_mod = @import("../debug/profile.zig");
const string_util = @import("../lib/string_util.zig");
const time_util = @import("../lib/time_util.zig");

const autocomplete_mod = @import("autocomplete.zig");
const keybindings = @import("keybindings.zig");
const slash_commands_mod = @import("../coding_agent/slash_commands.zig");
const request_mod = @import("../coding_agent/request.zig");
const extension_ui = @import("../coding_agent/extensions/ui.zig");
const CombinedAutocompleteProvider = autocomplete_mod.CombinedAutocompleteProvider;
const CommandRegistry = slash_commands_mod.CommandRegistry;
const list_picker_mod = @import("components/list_picker.zig");
const select_list_mod = @import("components/select_list.zig");
const ListPicker = list_picker_mod.ListPicker;
const PickerSelection = list_picker_mod.Selection;
const SelectItem = select_list_mod.SelectItem;
const session_store_mod = @import("../coding_agent/session/store.zig");
const session_index_worker_mod = @import("session_index_worker.zig");
const SessionStore = session_store_mod.SessionStore;
const storage = @import("../storage.zig");
const logging = @import("../logging.zig");

const agent_mod = @import("../agent3/root.zig");
const message_memory = @import("../agent3/message_memory.zig");
const coding_agent_mod = @import("../coding_agent/root.zig");
const AgentEvent = agent_mod.protocol.AgentEvent;
const AgentRequest = coding_agent_mod.AgentRequest;
const RequestQueue = coding_agent_mod.RequestQueue;
const agent_protocol = agent_mod.protocol;
const RetryPolicy = coding_agent_mod.runtime_host.RetryPolicy;
const CompactionPolicy = coding_agent_mod.runtime_host.CompactionPolicy;
const CompactionExecutor = coding_agent_mod.runtime_host.CompactionExecutor;
const ChildRect = container_mod.ChildRect;
const log = std.log.scoped(.tui_interactive);

const MouseCapture = union(enum) {
    none,
    transcript_selection: void,
};

const AgentSession = coding_agent_mod.AgentSession;
const SessionEvent = coding_agent_mod.session_event.SessionEvent;
const RuntimeHost = coding_agent_mod.RuntimeHost;
const ConversationSnapshotPublisher = coding_agent_mod.ConversationSnapshotPublisher;
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
const auth_storage_mod = @import("../coding_agent/auth/storage.zig");
const auth_types = @import("../coding_agent/auth/types.zig");
const oauth_mod = @import("../coding_agent/auth/oauth.zig");
const settings_manager_mod = @import("../coding_agent/settings/manager.zig");
const ai_protocol = @import("../ai/protocol.zig");
const ai_resolve = @import("../coding_agent/resolve.zig");
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
const StatusLine = status_line_mod.StatusLine;
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

const ui_snapshot_queue_capacity: usize = 64;
const ui_lifecycle_queue_capacity: usize = 64;

/// Mailbox-backed agent/helper → TUI snapshot channel.
///
/// Snapshot/progress traffic is bounded and lossy: the latest semantic
/// state will be republished, so intermediate snapshots may be dropped.
const UiSnapshotQueue = mailbox_mod.Mailbox(UiEvent, .{
    .cleanup = .deinit,
    .policy = .{ .bounded = .{ .capacity = ui_snapshot_queue_capacity, .on_full = .drop_newest } },
    .wakeup = .pipe,
});

/// Mailbox-backed agent/helper → TUI lifecycle channel.
///
/// Terminal lifecycle outcomes must not disappear silently, so this
/// channel rejects on overload instead of dropping.
const UiLifecycleQueue = mailbox_mod.Mailbox(UiEvent, .{
    .cleanup = .deinit,
    .policy = .{ .bounded = .{ .capacity = ui_lifecycle_queue_capacity, .on_full = .reject } },
    .wakeup = .pipe,
});

const QueuedInputKind = enum {
    steering,
    follow_up,
};

const ClipboardImageReader = *const fn (allocator: std.mem.Allocator) ?[]u8;

const PendingImageAttachment = struct {
    image: ai_protocol.ImageContent,
    dimensions: ?image_mod.Dimensions = null,

    fn deinit(self: *PendingImageAttachment, allocator: std.mem.Allocator) void {
        allocator.free(self.image.data);
        allocator.free(self.image.mime_type);
        self.* = undefined;
    }
};

const PreparedClipboardImageResult = union(enum) {
    attach: PendingImageAttachment,
    rejected: []u8,

    fn deinit(self: *PreparedClipboardImageResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .attach => |*attachment| attachment.deinit(allocator),
            .rejected => |message| allocator.free(message),
        }
    }
};

const BuiltSubmitContent = struct {
    content: ai_protocol.UserMessage.UserMessageContent,

    fn deinit(self: *BuiltSubmitContent, allocator: std.mem.Allocator) void {
        switch (self.content) {
            .text => {},
            .blocks => |blocks| allocator.free(blocks),
        }
    }
};

test "UiSnapshotQueue drops newest snapshot traffic when bounded" {
    const themes_builtin = @import("../themes/builtin.zig");
    var q = try UiSnapshotQueue.init(std.testing.allocator);
    defer q.deinit();

    var sent: usize = 0;
    while (sent < ui_snapshot_queue_capacity) : (sent += 1) {
        try std.testing.expectEqual(.ok, q.trySend(.{ .theme_changed = themes_builtin.dark().* }));
    }
    try std.testing.expectEqual(.dropped, q.trySend(.{ .theme_changed = themes_builtin.light().* }));

    const stats = q.stats();
    try std.testing.expectEqual(@as(usize, ui_snapshot_queue_capacity), stats.pending_depth);
    try std.testing.expectEqual(@as(usize, 1), stats.dropped_count);
    try std.testing.expectEqual(@as(usize, ui_snapshot_queue_capacity), stats.send_count);
}

test "UiLifecycleQueue rejects overload and keeps wake semantics" {
    var q = try UiLifecycleQueue.init(std.testing.allocator);
    defer q.deinit();

    var sent: usize = 0;
    while (sent < ui_lifecycle_queue_capacity) : (sent += 1) {
        try std.testing.expectEqual(.ok, q.trySend(.{ .request_worker_finished = {} }));
    }
    switch (q.trySend(.{ .request_worker_finished = {} })) {
        .full => |rejected| {
            var failed = rejected;
            failed.deinit(std.testing.allocator);
        },
        else => return error.UnexpectedResult,
    }

    var pfd = [1]posix.pollfd{.{
        .fd = q.wakeReadFd().?,
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    const ready = try posix.poll(&pfd, 0);
    try std.testing.expectEqual(@as(usize, 1), ready);

    var out: [ui_lifecycle_queue_capacity]UiEvent = undefined;
    const count = q.drainInto(&out);
    try std.testing.expectEqual(ui_lifecycle_queue_capacity, count);
    for (out[0..count]) |*ev| ev.deinit(std.testing.allocator);

    const stats = q.stats();
    try std.testing.expectEqual(@as(usize, 1), stats.rejected_count);
    try std.testing.expectEqual(ui_lifecycle_queue_capacity, stats.high_water_depth);
}

/// Owns all transient heap-backed data for one `/resume` overlay.
/// The picker borrows from this flow; teardown is one arena drop.
const ResumePickerFlow = struct {
    arena: std.heap.ArenaAllocator,
    rows: []Row = &.{},
    items: []SelectItem = &.{},
    picker: ListPicker,
    handle: ?tui_mod.OverlayHandle = null,
    restore_session_model: bool = true,
    generation: u64 = 0,

    const Row = struct {
        item: SelectItem,
        path: []const u8,
    };

    fn initLoading(
        gpa: std.mem.Allocator,
        theme: *const theme_mod.Theme,
        restore_session_model: bool,
        generation: u64,
    ) !ResumePickerFlow {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();

        var picker = ListPicker.init(theme);
        picker.title = "Resume session";
        picker.list.max_visible = 10;
        picker.setSearchPlaceholder("Filter sessions");
        picker.setEmptyText("Loading sessions...");
        picker.setSearchableItems(&.{}, null);

        return .{
            .arena = arena,
            .picker = picker,
            .restore_session_model = restore_session_model,
            .generation = generation,
        };
    }

    fn populate(self: *ResumePickerFlow, summaries: []const session_store_mod.SessionInfo) !void {
        const a = self.arena.allocator();
        const rows = try a.alloc(Row, summaries.len);
        const items = try a.alloc(SelectItem, summaries.len);

        for (summaries, 0..) |session, i| {
            const item: SelectItem = .{
                .value = try a.dupe(u8, session.session_id),
                .label = try a.dupe(u8, session.first_message),
                .description = try std.fmt.allocPrint(a, "{d} msgs \xC2\xB7 {s}", .{
                    session.message_count,
                    time_util.relativeTimeLabel(session.timestamp),
                }),
            };
            rows[i] = .{ .item = item, .path = try a.dupe(u8, session.path) };
            items[i] = item;
        }

        self.rows = rows;
        self.items = items;
        self.picker.setEmptyText("No matching sessions");
        self.picker.setSearchableItems(items, null);
    }

    fn deinit(self: *ResumePickerFlow) void {
        self.arena.deinit();
    }
};

const ExtensionPromptFlow = struct {
    arena: std.heap.ArenaAllocator,
    prompt: extension_ui.PromptRequest,
    response: *request_mod.ExtensionPromptResponse,
    items: []SelectItem = &.{},
    picker: ?ListPicker = null,
    editor: ?editor_mod.Editor = null,
    handle: ?tui_mod.OverlayHandle = null,

    fn init(gpa: std.mem.Allocator, theme: *const theme_mod.Theme, prompt: extension_ui.PromptRequest, response: *request_mod.ExtensionPromptResponse) !ExtensionPromptFlow {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const owned_prompt = try extension_ui.PromptRequest.clone(a, prompt);

        switch (prompt.kind) {
            .confirm, .select => {
                const items = switch (prompt.kind) {
                    .confirm => blk: {
                        const confirm_items = try a.alloc(SelectItem, 2);
                        confirm_items[0] = .{ .value = "yes", .label = "Yes" };
                        confirm_items[1] = .{ .value = "no", .label = "No" };
                        break :blk confirm_items;
                    },
                    .select => blk: {
                        const select_items = try a.alloc(SelectItem, prompt.options.len);
                        for (prompt.options, 0..) |option, i| {
                            select_items[i] = .{ .value = option.id, .label = option.label };
                        }
                        break :blk select_items;
                    },
                    .input, .editor => unreachable,
                };
                var picker = ListPicker.init(theme);
                picker.title = owned_prompt.title;
                picker.list.max_visible = 8;
                picker.setItems(items);
                return .{ .arena = arena, .prompt = owned_prompt, .response = response, .items = items, .picker = picker };
            },
            .input, .editor => {
                var editor = editor_mod.Editor.init(a);
                editor.setTheme(theme);
                editor.setCwd(owned_prompt.title);
                editor.setAutocompleteMaxVisible(0);
                editor.setMaxVisibleLines(if (prompt.kind == .input) 1 else 8);
                if (prompt.kind == .editor) editor.setText(owned_prompt.prefill orelse "");
                return .{ .arena = arena, .prompt = owned_prompt, .response = response, .editor = editor };
            },
        }
    }

    fn deinit(self: *ExtensionPromptFlow) void {
        if (self.editor) |*editor| editor.deinit();
        self.arena.deinit();
    }
};

/// Owns all transient heap-backed data for one `/model` overlay.
/// Catalog models are borrowed from Interactive's TUI-owned snapshot;
/// derived search rows live here.
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
    prompt: ai_protocol.UserMessage.UserMessageContent,
    resume_session: struct {
        path: []const u8,
        restore_session_model: bool = true,
    },
    resume_picker: struct {
        restore_session_model: bool = true,
    },
};

/// Interactive mode — wires AgentSession (blocking on its thread)
/// to the TUI (main thread) via thread-safe snapshot and lifecycle queues.
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
    theme_storage: theme_mod.Theme,
    theme: *const theme_mod.Theme = undefined,
    cwd: []const u8 = "",

    // ── Owned components ──────────────────────────────────────────
    editor: editor_mod.Editor,
    /// Active editor interface — routes paste/newline/ctrl+d/clear.
    /// Defaults to the built-in editor. Extensions can swap via setEditor().
    /// Initialized in run() after self.editor is set up.
    active_editor: EditorInterface = undefined,
    active_editor_bound: bool = false,
    status_line: StatusLine,
    pending_image_banner: text_mod.Text,
    extension_panel_text: text_mod.Text,
    extension_header_text: text_mod.Text,
    extension_footer_text: text_mod.Text,
    extension_widget_above_text: text_mod.Text,
    extension_widget_below_text: text_mod.Text,
    extension_header_active: bool = false,
    extension_header_lifetime: @import("../coding_agent/extensions/ui.zig").SurfaceLifetime = .session,
    greeter: greeter_mod.Greeter,
    footer: footer_mod.Footer,
    transcript: Transcript,
    conversation_projection: conversation_projection_mod.ProjectionState,
    resolver: ToolRendererResolver,
    status_data: StatusData,
    /// Agent-thread dedupe cache for semantic status publication.
    /// Owned storage lives in `msg_allocator` so teardown can free it on
    /// the TUI thread after all workers are joined.
    last_published_status_snapshot: ?PublishedStatusSnapshot = null,

    // ── Conversation-publish coalescer (agent thread only) ────────
    // P1: soft events (token deltas, tool_execution_update) mark-dirty
    // and only publish if the cadence has elapsed. Hard events flush
    // immediately. See flushPendingConversationPublish /
    // maybePublishSoftConversation below.
    last_conversation_publish_ns: u64 = 0,
    conversation_publish_dirty: bool = false,
    /// Last queued-snapshot version we've published from the agent thread.
    /// Used by `publishQueuedSnapshotIfChanged` to skip redundant publishes
    /// when the run-control queue hasn't mutated since our last send. The
    /// TUI-thread direct publish path does **not** update this field; stale
    /// deliveries from race conditions are handled downstream by
    /// `ProjectionState.replaceQueuedSnapshot` version filtering.
    last_published_queued_version: u64 = 0,
    runtime_host: RuntimeHost,
    loader_active: bool = false,
    retry_active: bool = false,
    retry_waiting: bool = false,
    retry_attempt: u32 = 0,
    retry_max_attempts: u32 = 0,

    pending_images: std.ArrayListUnmanaged(PendingImageAttachment) = .empty,
    clipboard_image_reader: ClipboardImageReader = clipboard_mod.readImage,

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
    resume_picker_generation: u64 = 0,
    session_index_worker: session_index_worker_mod.SessionIndexWorker,

    // ── Model picker (for /model) ───────────────────────────────
    auth_storage: *auth_storage_mod.AuthStorage,
    settings_manager: *settings_manager_mod.SettingsManager,
    /// TUI-owned visible-model snapshot published from the agent
    /// thread. `/model` UI reads only this slice, never the session
    /// registry directly. Allocated with `msg_allocator`.
    model_catalog: []ai_protocol.Model = &.{},
    model_picker_flow: ?ModelPickerFlow = null,
    extension_prompt_flow: ?ExtensionPromptFlow = null,

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
    login_picker_entries: [8]oauth_mod.ProviderListEntry = undefined,
    login_picker_count: usize = 0,
    login_picker_handle: ?tui_mod.OverlayHandle = null,
    login_thread: ?std.Thread = null,
    login_cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    snapshot_event_queue: UiSnapshotQueue,
    lifecycle_event_queue: UiLifecycleQueue,
    /// TUI → agent owner inbox. The TUI enqueues `AgentRequest`
    /// values; the long-lived agent thread wakes, drains, and dispatches
    /// them on the owner thread.
    request_queue: RequestQueue,
    memory_diagnostics: *const memory_debug.Diagnostics,
    agent_event_token: ?RuntimeHost.AgentEventSubscriptionToken = null,
    session_event_token: ?RuntimeHost.EventSubscriptionToken = null,
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
        runtime_host: RuntimeHost,
        memory_diagnostics: *const memory_debug.Diagnostics,
        resolver: ToolRendererResolver,
        cwd: []const u8,
        auth_storage: *auth_storage_mod.AuthStorage,
        settings_manager: *settings_manager_mod.SettingsManager,
    ) !Interactive {
        _ = allocator;
        const state_allocator = memory_diagnostics.tui.allocator();

        var self: Interactive = .{
            .allocator = state_allocator,
            .msg_allocator = msg_allocator,
            .tui = try TUI.init(state_allocator),
            .theme_storage = undefined,
            .theme = undefined,
            .cwd = cwd,
            .editor = editor_mod.Editor.init(state_allocator),
            .status_line = StatusLine.init(state_allocator),
            .pending_image_banner = text_mod.Text.init(state_allocator),
            .extension_panel_text = text_mod.Text.init(state_allocator),
            .extension_header_text = text_mod.Text.init(state_allocator),
            .extension_footer_text = text_mod.Text.init(state_allocator),
            .extension_widget_above_text = text_mod.Text.init(state_allocator),
            .extension_widget_below_text = text_mod.Text.init(state_allocator),
            .greeter = .{ .version = app_meta.version },
            .footer = .{},
            .hotkeys_overlay = .{},
            .transcript = Transcript.init(state_allocator),
            .conversation_projection = conversation_projection_mod.ProjectionState.init(msg_allocator),
            .resolver = resolver,
            .status_data = StatusData.init(state_allocator),
            .runtime_host = runtime_host,
            .header_container = container_mod.Container.init(state_allocator),
            .pending_container = container_mod.Container.init(state_allocator),
            .status_container = container_mod.Container.init(state_allocator),
            .widget_above_container = container_mod.Container.init(state_allocator),
            .editor_container = container_mod.Container.init(state_allocator),
            .widget_below_container = container_mod.Container.init(state_allocator),
            .command_registry = CommandRegistry.init(state_allocator),
            .input = input_buffer_mod.InputBuffer.init(state_allocator),
            .snapshot_event_queue = try UiSnapshotQueue.init(msg_allocator),
            .lifecycle_event_queue = try UiLifecycleQueue.init(msg_allocator),
            .request_queue = try RequestQueue.init(msg_allocator),
            .session_index_worker = try session_index_worker_mod.SessionIndexWorker.init(msg_allocator),
            .memory_diagnostics = memory_diagnostics,
            .auth_storage = auth_storage,
            .settings_manager = settings_manager,
            .model_catalog = &.{},
        };
        self.pending_image_banner.setPadding(1, 0);
        self.editor.setCwd(cwd);
        self.hide_thinking_block = settings_manager.getHideThinkingBlock();
        self.applyTranscriptHideThinkingBlock();
        // NOTE: active_editor is bound in run() where self is at its final
        // address. Binding it here would capture a pointer to the local `self`
        // that becomes dangling after the by-value return.
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
        self.session_index_worker.stop();

        // Stop the long-lived agent owner thread. Abort first if a
        // prompt is mid-flight so the owner loop can reach its next
        // request boundary, then enqueue an ordered shutdown, close the
        // transport, and join.
        if (self.agent_thread) |t| {
            if (self.is_streaming) self.runtime_host.abortCurrentRun();
            self.enqueueAgentShutdown();
            self.request_queue.close();
            t.join();
            self.agent_thread = null;
            self.is_streaming = false;
            self.request_in_flight = false;
        } else {
            self.request_queue.close();
        }

        self.runtime_host.setExtensionOAuthRefreshDispatcher(null);
        if (self.agent_event_token) |token| {
            self.runtime_host.unsubscribeAgentEvents(token);
            self.agent_event_token = null;
        }
        if (self.session_event_token) |token| {
            self.runtime_host.unsubscribeEvents(token);
            self.session_event_token = null;
        }
        self.snapshot_event_queue.close();
        self.lifecycle_event_queue.close();

        self.drainUiEvents();
        self.closeExtensionPromptFlow(false);
        self.closeModelPickerFlow();
        self.closeResumePickerFlow();
        self.clearLoginPickerEntries();
        self.clearPendingImages();
        self.pending_images.deinit(self.allocator);
        if (self.autocomplete_provider_bound) self.autocomplete_provider.deinit();
        self.command_registry.deinit();
        self.runtime_host.deinit();
        if (self.last_published_status_snapshot) |*snapshot| {
            snapshot.deinit(self.msg_allocator);
            self.last_published_status_snapshot = null;
        }
        coding_agent_mod.model_registry.deinitOwnedModels(self.msg_allocator, self.model_catalog);
        self.model_catalog = &.{};
        self.status_data.deinit();
        self.input.deinit();
        logMailboxStats("snapshot", self.snapshot_event_queue.stats());
        logMailboxStats("lifecycle", self.lifecycle_event_queue.stats());
        logMailboxStats("request", self.request_queue.stats());
        logMailboxStats("session_index", self.session_index_worker.stats());
        self.session_index_worker.deinit();
        self.snapshot_event_queue.deinit();
        self.lifecycle_event_queue.deinit();
        // Any unexpectedly undrained requests are mailbox-owned here;
        // deinit cleans them with AgentRequest.deinit.
        self.request_queue.deinit();
        self.widget_below_container.deinit();
        self.editor_container.deinit();
        self.widget_above_container.deinit();
        self.status_container.deinit();
        self.pending_container.deinit();
        self.header_container.deinit();
        self.conversation_projection.deinit();
        self.transcript.deinit();
        self.extension_widget_below_text.deinit();
        self.extension_widget_above_text.deinit();
        self.extension_footer_text.deinit();
        self.extension_header_text.deinit();
        self.extension_panel_text.deinit();
        self.pending_image_banner.deinit();
        self.status_line.deinit();
        self.editor.deinit();
        self.tui.deinit();
    }

    fn startAgentThread(self: *Interactive) !void {
        if (self.agent_thread != null) return;
        self.agent_thread = try std.Thread.spawn(.{}, agentThreadFn, .{self});
    }

    fn startSessionIndexWorker(self: *Interactive) !void {
        self.session_index_worker.setPublisher(&publishSessionIndexUiEvent, @ptrCast(self));
        try self.session_index_worker.start();
        self.session_index_worker.warmResumeSessions(self.cwd) catch {};
    }

    fn publishSessionIndexUiEvent(ctx: ?*anyopaque, event: UiEvent) bool {
        const self: *Interactive = @ptrCast(@alignCast(ctx.?));
        return self.publishLifecycleUiEvent(event);
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
        self.active_editor_bound = true;
        self.active_editor.setOnSubmit(&onEditorSubmit, @ptrCast(self));
        self.active_editor.setOnChange(&onEditorChange, @ptrCast(self));
        self.active_editor.setTheme(self.theme);
        self.active_editor.setCwd(self.cwd);
        self.active_editor.setPaddingX(@intCast(self.settings_manager.getEditorPaddingX()));
        self.active_editor.setAutocompleteMaxVisible(@intCast(self.settings_manager.getAutocompleteMaxVisible()));
        self.active_editor.setStatusData(&self.status_data);
        self.agent_event_token = self.runtime_host.subscribeAgentEvents(&agentEventCallback, @ptrCast(self));
        self.session_event_token = self.runtime_host.subscribeEvents(&sessionEventCallback, @ptrCast(self));
        self.runtime_host.setExtensionOAuthRefreshDispatcher(.{
            .func = &dispatchExtensionOAuthRefreshViaRequestQueue,
            .ctx = @ptrCast(self),
        });

        self.detectGitBranch();
        try self.startAgentThread();
        try self.startSessionIndexWorker();

        // Prime the status chips via the agent-owned snapshot path before the
        // first frame. This keeps model/thinking/context reads off the TUI
        // thread even during startup.
        self.bootstrapStatusSnapshot();

        // Wire autocomplete: combined slash + file path completion.
        self.autocomplete_provider = CombinedAutocompleteProvider.init(self.allocator, &self.command_registry, self.cwd);
        self.autocomplete_provider_bound = true;
        self.active_editor.setAutocompleteProvider(self.autocomplete_provider.provider());

        // Populate container slots with their initial children.
        self.refreshHeaderVisibility();
        self.refreshPendingImageBanner();
        self.status_line.setStatusData(&self.status_data);
        self.status_line.setTheme(self.theme);
        self.status_container.addChild(self.status_line.component());
        self.widget_above_container.addChild(self.extension_widget_above_text.component());
        self.editor_container.addChild(self.active_editor.component());
        self.editor_container.focused_child_index = 0; // for cursor y-offset translation
        self.widget_below_container.addChild(self.extension_widget_below_text.component());
        self.widget_below_container.addChild(self.extension_panel_text.component());
        self.widget_below_container.addChild(self.extension_footer_text.component());

        // Set initial focus via TUI (source of truth for input routing)
        self.tui.setFocus(self.active_editor.component());

        // Build root tree matching pi-mono slot structure, adapted for a
        // full-screen TUI: transcript remains the flex region while the header
        // is a composer/onboarding surface near the editor, not top chrome.
        // chat(flex) → pending → status → header → widget_above → editor(focused) → widget_below
        self.tui.root.addChild(self.transcript.component()); // [0] chat (flex)
        self.tui.root.addChild(self.pending_container.component()); // [1] pendingContainer
        self.tui.root.addChild(self.status_container.component()); // [2] statusContainer
        self.tui.root.addChild(self.header_container.component()); // [3] composer header/onboarding
        self.tui.root.addChild(self.widget_above_container.component()); // [4] widgetAboveContainer
        self.tui.root.addChild(self.editor_container.component()); // [5] editorContainer
        self.tui.root.addChild(self.widget_below_container.component()); // [6] widgetBelowContainer
        self.tui.root.flex_child_index = 0; // transcript is flex
        self.tui.root.focused_child_index = 5; // editorContainer for cursor y-offset

        // RuntimeHost emits extension `session_start` before the TUI tree exists.
        // Drain the semantic UI publications once after slots are materialized so
        // lifecycle-time retained surfaces (widgets/status/header/footer/etc.)
        // are visible without waiting for an extension command.
        self.publishPendingExtensionUi();

        self.tui.dirty = true;
        self.performStartupAction();

        var should_wait = false;
        var input_ready = true;
        while (self.running) {
            if (should_wait) {
                const readiness = self.waitForLoopReadiness();
                input_ready = readiness.input_ready;
                if (readiness.snapshot_ready) self.snapshot_event_queue.wait();
                if (readiness.lifecycle_ready) self.lifecycle_event_queue.wait();
            } else {
                should_wait = true;
                input_ready = true;
            }

            self.drainUiEvents();
            if (!self.running) break;

            if (input_ready and self.processTerminalInput()) continue;

            self.input.checkTimeout(&onInputSequence, @ptrCast(self));
            self.finishKittyNegotiationIfDue();

            if (self.tui.checkResize()) {
                self.cancelTranscriptSelection();
            }

            const now_ns = std.time.nanoTimestamp();
            if (self.tui.tickAnimations(now_ns)) {
                self.tui.dirty = true;
            }

            if (self.tui.dirty) {
                self.renderFrame();
                self.tui.dirty = false;
            }
        }
    }

    fn performStartupAction(self: *Interactive) void {
        switch (self.startup_action) {
            .none => {},
            .prompt => |content| {
                _ = self.submitUserContent(content);
            },
            .resume_session => |session_resume| {
                const path_copy = self.msg_allocator.dupe(u8, session_resume.path) catch {
                    self.status_line.setPrimary("out of memory", self.theme.fg(.@"error"));
                    self.tui.dirty = true;
                    self.startup_action = .none;
                    return;
                };
                _ = self.dispatchIdleRequest(.{ .resume_session = .{
                    .path = path_copy,
                    .restore_session_model = session_resume.restore_session_model,
                } }, .{
                    .busy_message = "cannot resume while agent is running",
                    .loader_message = "Loading session...",
                    .spawn_failed_message = "failed to queue resume",
                });
            },
            .resume_picker => |picker| self.showSessionPicker(picker.restore_session_model),
        }
        self.startup_action = .none;
    }

    fn bootstrapStatusSnapshot(self: *Interactive) void {
        switch (self.request_queue.trySend(.{ .refresh_status_snapshot = {} })) {
            .ok => {},
            .dropped => unreachable,
            .full => |rejected| {
                var failed_req = rejected;
                failed_req.deinit(self.msg_allocator);
                self.showAgentRequestQueueFull();
            },
            .closed, .oom => |rejected| {
                var failed_req = rejected;
                failed_req.deinit(self.msg_allocator);
            },
        }
    }

    fn drainUiEvents(self: *Interactive) void {
        self.drainUiEventQueue(&self.snapshot_event_queue);
        self.drainUiEventQueue(&self.lifecycle_event_queue);
    }

    fn drainUiEventQueue(self: *Interactive, queue: anytype) void {
        var event_buf: [64]UiEvent = undefined;
        while (true) {
            const count = queue.drainInto(&event_buf);
            if (count == 0) break;
            for (event_buf[0..count]) |*ev| {
                self.handleUiEvent(ev);
                ev.deinit(self.msg_allocator);
            }
        }
    }

    fn processTerminalInput(self: *Interactive) bool {
        var input_raw: [4096]u8 = undefined;
        const n = self.tui.terminal.readInput(&input_raw) catch 0;
        if (n == 0) return false;

        if (self.kitty_deadline_ns != null) {
            self.input.buf.appendSlice(self.allocator, input_raw[0..n]) catch {};
            if (self.input.consumeKittyResponse()) {
                self.tui.terminal.enableKittyProtocol();
                self.kitty_deadline_ns = null;
                self.input.drain(&onInputSequence, &onInputPaste, @ptrCast(self));
                return false;
            }
            return true;
        }

        self.input.feed(input_raw[0..n], &onInputSequence, &onInputPaste, @ptrCast(self));
        return false;
    }

    fn finishKittyNegotiationIfDue(self: *Interactive) void {
        if (self.kitty_deadline_ns) |deadline| {
            if (std.time.nanoTimestamp() >= deadline) {
                self.tui.terminal.enableModifyOtherKeys();
                self.kitty_deadline_ns = null;
                if (self.input.buf.items.len > 0) {
                    self.input.drain(&onInputSequence, &onInputPaste, @ptrCast(self));
                }
            }
        }
    }

    fn showAgentRequestQueueFull(self: *Interactive) void {
        self.status_line.setPrimary("agent request queue full; try again", self.theme.fg(.@"error"));
        self.tui.dirty = true;
    }

    fn publishUiEvent(self: *Interactive, event: UiEvent) bool {
        return if (event.isSnapshotEvent())
            self.publishSnapshotUiEvent(event)
        else
            self.publishLifecycleUiEvent(event);
    }

    fn publishSnapshotUiEvent(self: *Interactive, event: UiEvent) bool {
        switch (self.snapshot_event_queue.trySend(event)) {
            .ok => return true,
            .dropped => return false,
            .closed, .full, .oom => |rejected| {
                var failed = rejected;
                failed.deinit(self.msg_allocator);
                return false;
            },
        }
    }

    fn publishLifecycleUiEvent(self: *Interactive, event: UiEvent) bool {
        switch (self.lifecycle_event_queue.trySend(event)) {
            .ok => return true,
            .dropped => unreachable,
            .closed, .full, .oom => |rejected| {
                var failed = rejected;
                defer failed.deinit(self.msg_allocator);
                log.warn("lifecycle queue rejected ui event", .{});
                return false;
            },
        }
    }

    fn logMailboxStats(comptime label: []const u8, stats: anytype) void {
        log.info(
            "{s} queue stats pending={d} high_water={d} sends={d} wakes={d} rejected={d} dropped={d} state={s}",
            .{
                label,
                stats.pending_depth,
                stats.high_water_depth,
                stats.send_count,
                stats.wake_count,
                stats.rejected_count,
                stats.dropped_count,
                @tagName(stats.state),
            },
        );
    }

    // ── InputBuffer callbacks ───────────────────────────────────────

    /// Called by InputBuffer for each complete input sequence.
    fn onInputSequence(seq: []const u8, raw_ctx: *anyopaque) void {
        const self: *Interactive = @ptrCast(@alignCast(raw_ctx));

        // Bare \n = newline insertion (some terminals send this for shift+enter)
        if (seq.len == 1 and seq[0] == '\n') {
            self.active_editor.insertText("\n");
            self.refreshHeaderVisibility();
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
        self.refreshHeaderVisibility();
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
                if (self.extension_prompt_flow != null) {
                    self.closeExtensionPromptFlow(true);
                } else {
                    self.tui.hideOverlay();
                }
                return;
            }
            return;
        }

        // App-level keybindings — no overlay active
        if (keybindings.matches(.app_interrupt, key)) {
            if (self.retry_waiting) {
                self.runtime_host.abortRetry();
                return;
            }
            if (self.is_streaming) {
                self.runtime_host.abortCurrentRun();
                self.status_line.setPrimary("aborted", self.theme.fg(.@"error"));
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
                self.runtime_host.abortRetry();
                return;
            }
            if (self.is_streaming) {
                self.runtime_host.abortCurrentRun();
                self.status_line.setPrimary("aborted", self.theme.fg(.@"error"));
                self.tui.dirty = true;
                return;
            }
            const now = std.time.nanoTimestamp();
            const double_tap_ns: i128 = 500 * std.time.ns_per_ms;
            if (!self.composerHasPendingInput() and now - self.last_ctrl_c_ns < double_tap_ns) {
                self.running = false;
                return;
            }
            self.clearComposerDraft();
            self.last_ctrl_c_ns = now;
            self.tui.dirty = true;
            return;
        }

        // Ctrl+D: exit only when the composer is empty (pi-mono parity)
        if (keybindings.matches(.app_exit, key)) {
            if (!self.composerHasPendingInput()) {
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
            self.applyTranscriptHideThinkingBlock();
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

        if (keybindings.matches(.app_paste_image, key)) {
            self.handlePasteImageShortcut();
            return;
        }

        // scroll: page up/down, shift+up/down
        if (self.handleScroll(key)) return;

        // Route to focused component via TUI
        if (self.tui.handleInput(key)) {
            self.refreshHeaderVisibility();
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
        if (ev.takeConversationSnapshot()) |snapshot| {
            var owned = snapshot;
            const was_following_bottom = self.transcript.isFollowingBottom();
            self.conversation_projection.replaceViewSnapshot(
                &self.transcript,
                self.active_editor,
                self.resolver,
                &owned,
                .{
                    .theme = self.theme,
                    .retry_attempt = self.retry_attempt,
                },
            );
            if (was_following_bottom) {
                self.transcript.scrollToBottom(self.tui.width(), self.outputHeight());
            }
            self.tui.dirty = true;
            return;
        }

        if (ev.takeQueuedSnapshot()) |snapshot| {
            var owned = snapshot;
            const was_following_bottom = self.transcript.isFollowingBottom();
            self.conversation_projection.replaceQueuedSnapshot(
                &self.transcript,
                self.active_editor,
                self.resolver,
                &owned,
                .{
                    .theme = self.theme,
                    .retry_attempt = self.retry_attempt,
                },
            );
            if (was_following_bottom) {
                self.transcript.scrollToBottom(self.tui.width(), self.outputHeight());
            }
            self.tui.dirty = true;
            return;
        }

        if (ev.takeVisibleModelsSnapshot()) |models| {
            self.applyVisibleModelsSnapshot(models);
            self.tui.dirty = true;
            return;
        }

        switch (ev.*) {
            .consumed => {},
            .conversation_snapshot => unreachable,
            .queued_snapshot => unreachable,
            .visible_models_snapshot => unreachable,
            .error_message => |e| {
                self.status_line.setPrimary(e.message, self.theme.fg(.@"error"));
                self.tui.dirty = true;
            },
            .theme_changed => |theme| {
                self.applyTheme(theme);
                self.tui.dirty = true;
            },
            .assistant_run_finished => |m| {
                self.tui.dirty = true;
                if (m.is_aborted) {
                    self.status_line.setPrimary(m.error_message orelse "aborted", self.theme.fg(.@"error"));
                } else if (m.error_message) |msg| {
                    self.status_line.setPrimary(userFacingFailureMessage(m.failure_kind, msg), self.theme.fg(.@"error"));
                }
            },
            .tool_running => |t| {
                self.status_line.setPrimary(t.tool_name, self.theme.fg(.accent));
                self.tui.dirty = true;
            },
            .login_progress => |l| {
                self.status_line.setPrimary(l.message, switch (l.kind) {
                    .auth_url => self.theme.fg(.accent),
                    .info => self.theme.fg(.muted),
                });
                self.tui.dirty = true;
            },
            .login_complete => |l| {
                if (self.login_thread) |t| t.join();
                self.login_thread = null;

                if (l.success) {
                    self.status_line.setPrimary(l.message, self.theme.fg(.success));
                } else {
                    self.status_line.setPrimary(l.message, self.theme.fg(.@"error"));
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
                    const final_error = r.final_error orelse "unknown error";
                    const msg = std.fmt.bufPrint(
                        &buf,
                        "retry failed after {d} attempt{s}: {s}",
                        .{ r.attempt, if (r.attempt == 1) "" else "s", userFacingFailureMessage(r.failure_kind, final_error) },
                    ) catch userFacingFailureMessage(r.failure_kind, final_error);
                    self.status_line.setPrimary(msg, self.theme.fg(.@"error"));
                }
                self.tui.dirty = true;
            },
            .prompt_worker_finished => |p| {
                self.is_streaming = false;
                self.hideLoader();
                self.tui.setFocus(self.active_editor.component());
                switch (p.outcome) {
                    .success => self.status_line.clearPrimary(),
                    .assistant_error, .aborted => {},
                }
                if (p.internal_error) |msg| {
                    self.status_line.setPrimary(msg, self.theme.fg(.@"error"));
                }
                self.tui.dirty = true;
            },
            .request_worker_finished => {
                // Long-lived agent owner loop finished an idle request drain.
                // Hide the loader only when the TUI actually has a pending
                // request banner to unwind; individual success/failure events
                // still own primary status and focus.
                if (self.request_in_flight) {
                    self.request_in_flight = false;
                    self.hideLoader();
                }
                self.tui.dirty = true;
            },
            .session_resumed => |r| {
                self.transcript.scrollToBottom(self.tui.width(), self.outputHeight());
                // Prefer the restore warning over the generic
                // "session resumed" banner when a fallback happened
                // — users need to see why their saved model isn't
                // the one they're about to talk to. Otherwise default
                // to the success banner.
                if (r.restore_warning) |w| {
                    self.status_line.setPrimary(w, self.theme.fg(.warning));
                } else {
                    self.status_line.setPrimary("session resumed", self.theme.fg(.success));
                }
                self.tui.dirty = true;
            },
            .session_resume_failed => |f| {
                self.status_line.setPrimary(f.message, self.theme.fg(.@"error"));
                self.tui.dirty = true;
            },
            .resume_sessions_loaded => |r| {
                self.applyResumeSessionsLoaded(r.generation, r.sessions);
            },
            .resume_sessions_failed => |f| {
                self.applyResumeSessionsFailed(f.generation, f.message);
            },
            .extension_commands_updated => |u| {
                self.applyExtensionCommandsUpdate(u.commands);
            },
            .extension_panel_shown => |u| {
                self.applyExtensionPanel(u.panel);
            },
            .extension_surfaces_updated => |u| {
                self.applyExtensionSurfaces(u.updates);
            },
            .extension_editor_actions => |u| {
                self.applyExtensionEditorActions(u.actions);
            },
            .extension_prompt_requested => |u| {
                self.showExtensionPrompt(u.prompt, u.response);
            },
            .session_new_started => {
                self.transcript.scrollToBottom(self.tui.width(), self.outputHeight());
                self.status_line.setPrimary("new session started", self.theme.fg(.success));
                self.tui.dirty = true;
            },
            .session_fork_started => {
                self.transcript.scrollToBottom(self.tui.width(), self.outputHeight());
                self.status_line.setPrimary("session forked", self.theme.fg(.success));
                self.tui.dirty = true;
            },
            .session_new_failed => |f| {
                self.status_line.setPrimary(f.message, self.theme.fg(.@"error"));
                self.tui.dirty = true;
            },
            .session_compacted => {
                self.status_line.setPrimary("session compacted; ctx updates after next response", self.theme.fg(.success));
                self.tui.dirty = true;
            },
            .session_compaction_failed => |f| {
                self.status_line.setPrimary(f.message, self.theme.fg(.@"error"));
                self.tui.dirty = true;
            },
            .status_snapshot => |s| {
                self.applyStatusSnapshot(s);
                self.tui.dirty = true;
            },
            .model_switch_failed => |m| {
                self.status_line.setPrimary(m.message, self.theme.fg(.@"error"));
                self.tui.dirty = true;
            },
            .model_switched => |m| {
                var buf: [80]u8 = undefined;
                const label = if (m.model_id.len > 0) m.model_id else "model switched";
                const msg = std.fmt.bufPrint(&buf, "Model: {s}", .{label}) catch "model switched";
                self.status_line.setPrimary(msg, self.theme.fg(.success));
                self.tui.dirty = true;
            },
            .thinking_level_changed => |t| {
                var buf: [96]u8 = undefined;
                const level = if (t.level.len > 0) t.level else "off";
                const msg = std.fmt.bufPrint(&buf, "Thinking: {s}", .{level}) catch "thinking level updated";
                self.status_line.setPrimary(msg, self.theme.fg(.success));
                self.tui.dirty = true;
            },
            .thinking_level_change_failed => |t| {
                self.status_line.setPrimary(t.message, self.theme.fg(.@"error"));
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

    fn applyVisibleModelsSnapshot(self: *Interactive, models: []ai_protocol.Model) void {
        self.closeModelPickerFlow();
        coding_agent_mod.model_registry.deinitOwnedModels(self.msg_allocator, self.model_catalog);
        self.model_catalog = models;
    }

    fn applyResumeSessionsLoaded(self: *Interactive, generation: u64, sessions: []const session_store_mod.SessionInfo) void {
        if (generation != self.resume_picker_generation) return;
        const flow = if (self.resume_picker_flow) |*flow| flow else return;
        if (flow.generation != generation) return;

        if (sessions.len == 0) {
            flow.picker.setEmptyText("No sessions found");
            flow.picker.setSearchableItems(&.{}, null);
            self.status_line.setPrimary("no sessions found", self.theme.fg(.muted));
            self.tui.dirty = true;
            return;
        }

        flow.populate(sessions) catch {
            self.closeResumePickerFlow();
            self.status_line.setPrimary("failed to render sessions", self.theme.fg(.@"error"));
            self.tui.dirty = true;
            return;
        };
        self.tui.dirty = true;
    }

    fn applyResumeSessionsFailed(self: *Interactive, generation: u64, message: []const u8) void {
        if (generation != self.resume_picker_generation) return;
        if (self.resume_picker_flow) |*flow| {
            if (flow.generation != generation) return;
            flow.picker.setEmptyText(message);
            flow.picker.setSearchableItems(&.{}, null);
        }
        self.status_line.setPrimary(message, self.theme.fg(.@"error"));
        self.tui.dirty = true;
    }

    fn applyTranscriptHideThinkingBlock(self: *Interactive) void {
        self.transcript.hide_thinking_block = self.hide_thinking_block;
        for (self.transcript.items.items, 0..) |_, idx| {
            const assistant = self.transcript.assistantMessageAt(idx) orelse continue;
            assistant.setHideThinkingBlock(self.hide_thinking_block) catch continue;
            self.transcript.itemMutatedAt(idx);
        }
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
        self.status_line.setPrimary("copied selection", self.theme.fg(.success));
    }

    fn composerHasPendingInput(self: *Interactive) bool {
        return self.active_editor.getText().len > 0 or self.pending_images.items.len > 0;
    }

    fn clearComposerDraft(self: *Interactive) void {
        self.active_editor.clear();
        self.clearPendingImages();
        self.refreshHeaderVisibility();
    }

    fn clearPendingImages(self: *Interactive) void {
        for (self.pending_images.items) |*attachment| attachment.deinit(self.allocator);
        self.pending_images.clearRetainingCapacity();
        self.refreshPendingImageBanner();
    }

    fn refreshPendingImageBanner(self: *Interactive) void {
        self.pending_container.clear();
        if (self.pending_images.items.len == 0) return;

        const banner = pendingImageBannerText(self.allocator, self.pending_images.items) catch return;
        defer self.allocator.free(banner);
        self.pending_image_banner.setContent(banner);
        self.pending_container.addChild(self.pending_image_banner.component());
    }

    fn handlePasteImageShortcut(self: *Interactive) void {
        if (self.is_streaming or self.request_in_flight) {
            self.status_line.setPrimary("cannot paste image while agent is running", self.theme.fg(.@"error"));
            self.tui.dirty = true;
            return;
        }

        const raw = self.clipboard_image_reader(self.allocator) orelse {
            self.status_line.setPrimary("clipboard has no image", self.theme.fg(.muted));
            self.tui.dirty = true;
            return;
        };
        defer self.allocator.free(raw);

        const prepared = prepareClipboardImageAttachment(self.allocator, raw, .{
            .auto_resize = self.settings_manager.getImageAutoResize(),
        }) catch {
            self.status_line.setPrimary("out of memory", self.theme.fg(.@"error"));
            self.tui.dirty = true;
            return;
        };

        switch (prepared) {
            .rejected => |message| {
                defer self.allocator.free(message);
                self.status_line.setPrimary(message, self.theme.fg(.warning));
            },
            .attach => |attachment| {
                self.pending_images.append(self.allocator, attachment) catch {
                    var failed_attachment = attachment;
                    failed_attachment.deinit(self.allocator);
                    self.status_line.setPrimary("out of memory", self.theme.fg(.@"error"));
                    self.tui.dirty = true;
                    return;
                };
                self.refreshPendingImageBanner();
                self.refreshHeaderVisibility();

                var status_buf: [96]u8 = undefined;
                const pending_count = self.pending_images.items.len;
                const status = if (pending_count == 1)
                    "attached clipboard image"
                else
                    std.fmt.bufPrint(&status_buf, "attached clipboard image ({d} pending)", .{pending_count}) catch "attached clipboard image";
                self.status_line.setPrimary(status, self.theme.fg(.success));
            },
        }
        self.tui.dirty = true;
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

    fn refreshHeaderVisibility(self: *Interactive) void {
        if (self.composerHasPendingInput()) {
            if (self.extension_header_active and self.extension_header_lifetime == .until_input) {
                self.extension_header_active = false;
                self.extension_header_text.setContent("");
            }
            if (!self.extension_header_active and !self.greeter_dismissed) {
                self.greeter_dismissed = true;
            }
        }
        self.header_container.clear();
        if (self.extension_header_active) {
            self.header_container.addChild(self.extension_header_text.component());
        } else if (!self.greeter_dismissed) {
            self.header_container.addChild(self.greeter.component());
        }
    }

    fn showLoader(self: *Interactive, message: []const u8) void {
        self.status_line.setWorking(message);
        self.loader_active = true;
        self.tui.dirty = true;
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
        self.status_line.setWorking(message);
        self.loader_active = true;
        self.tui.dirty = true;
    }

    fn hideLoader(self: *Interactive) void {
        if (!self.loader_active) return;
        self.status_line.clearWorking();
        self.loader_active = false;
        self.tui.dirty = true;
        // Don't blank primary status — preserve any error/abort message
        // that was set while working was active.
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

    const LoopReadiness = struct {
        input_ready: bool = false,
        snapshot_ready: bool = false,
        lifecycle_ready: bool = false,
    };

    fn waitForLoopReadiness(self: *Interactive) LoopReadiness {
        const idle_wait_timeout_ms: i32 = 50;
        const now_ns = std.time.nanoTimestamp();
        const timeout_ms: i32 = if (self.nextLoopDeadlineNs(now_ns)) |deadline|
            if (deadline <= now_ns) 0 else @intCast(@divFloor(deadline - now_ns + 999_999, 1_000_000))
        else
            idle_wait_timeout_ms;

        var pfds = [3]posix.pollfd{
            .{
                .fd = self.tui.terminal.fd_in,
                .events = posix.POLL.IN,
                .revents = 0,
            },
            .{
                .fd = self.snapshot_event_queue.wakeReadFd().?,
                .events = posix.POLL.IN,
                .revents = 0,
            },
            .{
                .fd = self.lifecycle_event_queue.wakeReadFd().?,
                .events = posix.POLL.IN,
                .revents = 0,
            },
        };

        const ready = posix.poll(&pfds, timeout_ms) catch return .{};
        if (ready <= 0) return .{};
        return .{
            .input_ready = pfds[0].revents & posix.POLL.IN != 0,
            .snapshot_ready = pfds[1].revents & posix.POLL.IN != 0,
            .lifecycle_ready = pfds[2].revents & posix.POLL.IN != 0,
        };
    }

    fn renderFrame(self: *Interactive) void {
        var frame_timer = profile_mod.ScopedTimer.begin(.tui_render_frame);
        defer frame_timer.end();
        defer profile_mod.maybeEmitPeriodic(120);

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
        self.refreshHeaderVisibility();
        self.tui.dirty = true;
    }

    fn queueMessageWhileStreaming(self: *Interactive, kind: QueuedInputKind, text: []const u8) void {
        // Run-control is the dedicated cross-thread queued-message boundary
        // (see docs/runtime.md). Enqueue directly from the TUI thread so
        // steering submits appear immediately in the transcript instead of
        // waiting for `runUserContent` to return on the agent owner loop.
        const queue_kind: coding_agent_mod.runtime_host.QueueKind = switch (kind) {
            .steering => .steering,
            .follow_up => .follow_up,
        };
        switch (self.runtime_host.enqueueQueuedText(queue_kind, text)) {
            .ok => {},
            .closed, .oom => {
                self.status_line.setPrimary("agent unavailable", self.theme.fg(.@"error"));
                self.tui.dirty = true;
                return;
            },
        }

        // Publish the queued snapshot so the transcript projection picks up
        // the new row without waiting for the agent thread to surface.
        _ = self.publishQueuedSnapshot();

        self.active_editor.clear();
        self.refreshHeaderVisibility();
        self.tui.dirty = true;
    }

    fn restoreQueuedInputsToEditor(self: *Interactive) void {
        // Atomic take-and-clear on the TUI thread (safe — run-control's
        // mailbox serializes it against the agent thread's drain).
        var snapshot = self.runtime_host.takeQueuedMessagesAndClear(self.msg_allocator) catch {
            self.status_line.setPrimary("failed to restore queued messages", self.theme.fg(.@"error"));
            self.tui.dirty = true;
            return;
        };
        defer snapshot.deinit(self.msg_allocator);

        self.applyRestoredQueuedInputs(&snapshot);
        _ = self.publishQueuedSnapshot();
    }

    fn applyRestoredQueuedInputs(self: *Interactive, snapshot: *const coding_agent_mod.runtime_host.QueuedMessageSnapshot) void {
        const count = snapshot.steering.len + snapshot.follow_up.len;
        if (count == 0) {
            self.status_line.setPrimary("no queued messages", self.theme.fg(.muted));
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
        self.refreshHeaderVisibility();
        self.status_line.setPrimary(if (count == 1) "restored 1 queued message" else "restored queued messages", self.theme.fg(.success));
        self.tui.dirty = true;
    }

    fn submitUserContent(self: *Interactive, content: ai_protocol.UserMessage.UserMessageContent) bool {
        if (self.request_in_flight) {
            self.status_line.setPrimary("agent is busy", self.theme.fg(.@"error"));
            self.tui.dirty = true;
            return false;
        }

        const content_copy = message_memory.cloneUserContent(self.msg_allocator, content) catch return false;

        switch (self.request_queue.trySend(.{ .prompt = .{ .content = content_copy } })) {
            .ok => {},
            .dropped => unreachable,
            .full => |rejected| {
                var failed_req = rejected;
                failed_req.deinit(self.msg_allocator);
                self.tui.setFocus(self.active_editor.component());
                self.showAgentRequestQueueFull();
                return false;
            },
            .closed, .oom => |rejected| {
                var failed_req = rejected;
                failed_req.deinit(self.msg_allocator);
                self.tui.setFocus(self.active_editor.component());
                self.status_line.setPrimary("agent unavailable", self.theme.fg(.@"error"));
                self.tui.dirty = true;
                return false;
            },
        }

        self.clearComposerDraft();
        self.is_streaming = true;
        self.showLoader("Working…");
        self.tui.dirty = true;
        return true;
    }

    fn handleSubmittedText(self: *Interactive, text: []const u8, queued_kind: ?QueuedInputKind) void {
        if (text.len == 0 and self.pending_images.items.len == 0) return;

        self.active_editor.addToHistory(text);

        if (text.len > 0 and text[0] == '/' and self.dispatchSlashCommand(text)) return;

        if (queued_kind) |kind| {
            if (self.pending_images.items.len > 0) {
                self.status_line.setPrimary("cannot queue images while agent is streaming", self.theme.fg(.@"error"));
                self.tui.dirty = true;
                return;
            }
            self.queueMessageWhileStreaming(kind, text);
            return;
        }

        var built = buildSubmittedUserContent(self.allocator, text, self.pending_images.items) catch {
            self.status_line.setPrimary("out of memory", self.theme.fg(.@"error"));
            self.tui.dirty = true;
            return;
        };
        defer built.deinit(self.allocator);

        _ = self.submitUserContent(built.content);
    }

    fn handleFollowUpShortcut(self: *Interactive) void {
        const expanded = self.active_editor.getExpandedText();
        const text = std.mem.trim(u8, expanded, " \t\r\n");
        if (text.len == 0 and self.pending_images.items.len == 0) return;

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
        self.refreshHeaderVisibility();
        self.tui.dirty = true;

        // Built-in commands with Interactive access
        if (cmd.source == .builtin) {
            if (std.mem.eql(u8, name, "quit")) {
                self.running = false;
                return true;
            }
            if (std.mem.eql(u8, name, "clear")) {
                self.transcript.clearAll();
                // Drop the projection snapshot/cache too — otherwise the
                // next replaceViewSnapshot with the same committed ptr
                // would take the cache-hit path and hand reconcile
                // metadata-only items against a wiped transcript.
                self.conversation_projection.clear();
                self.status_line.clearPrimary();
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
            if (std.mem.eql(u8, name, "compact")) {
                const instructions: ?[]const u8 = if (args.len > 0)
                    self.msg_allocator.dupe(u8, args) catch null
                else
                    null;
                _ = self.dispatchIdleRequest(.{ .compact = .{ .custom_instructions = instructions } }, .{
                    .busy_message = "cannot compact while agent is running",
                    .loader_message = "Compacting session...",
                    .spawn_failed_message = "failed to queue compaction",
                });
                return true;
            }
            if (std.mem.eql(u8, name, "resume")) {
                self.showSessionPicker(true);
                return true;
            }
            if (std.mem.eql(u8, name, "fork")) {
                if (args.len == 0) {
                    self.status_line.setPrimary("usage: /fork <entry-id>", self.theme.fg(.@"error"));
                    self.tui.dirty = true;
                    return true;
                }
                const entry_id = self.msg_allocator.dupe(u8, args) catch return true;
                _ = self.dispatchIdleRequest(.{ .fork_session = .{ .entry_id = entry_id } }, .{
                    .busy_message = "cannot fork while agent is running",
                    .loader_message = "Forking session...",
                    .spawn_failed_message = "failed to queue fork",
                });
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
                    self.status_line.setPrimary("command failed", self.theme.fg(.@"error"));
                };
            },
            .extension => {
                const name_copy = self.msg_allocator.dupe(u8, name) catch {
                    self.status_line.setPrimary("out of memory", self.theme.fg(.@"error"));
                    self.tui.dirty = true;
                    return true;
                };
                const args_copy = self.msg_allocator.dupe(u8, args) catch {
                    self.msg_allocator.free(name_copy);
                    self.status_line.setPrimary("out of memory", self.theme.fg(.@"error"));
                    self.tui.dirty = true;
                    return true;
                };
                _ = self.dispatchIdleRequest(.{ .extension_command = .{ .name = name_copy, .args = args_copy } }, .{
                    .busy_message = "cannot run command while agent is running",
                    .loader_message = "Running command...",
                    .spawn_failed_message = "failed to queue extension command",
                });
            },
            .prompt_template, .skill => {
                self.status_line.setPrimary("not yet implemented", self.theme.fg(.warning));
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
            self.status_line.setPrimary("failed to write memory diagnostics", self.theme.fg(.@"error"));
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
        self.status_line.setPrimary(msg, self.theme.fg(.success));
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
            self.status_line.setPrimary(options.busy_message, self.theme.fg(.@"error"));
            self.tui.dirty = true;
            return false;
        }

        switch (self.request_queue.trySend(req)) {
            .ok => {},
            .dropped => unreachable,
            .full => |rejected| {
                var failed_req = rejected;
                failed_req.deinit(self.msg_allocator);
                self.showAgentRequestQueueFull();
                return false;
            },
            .closed, .oom => |rejected| {
                var failed_req = rejected;
                failed_req.deinit(self.msg_allocator);
                self.status_line.setPrimary(options.spawn_failed_message, self.theme.fg(.@"error"));
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

    fn showSessionPicker(self: *Interactive, restore_session_model: bool) void {
        self.closeResumePickerFlow();
        self.resume_picker_generation +%= 1;
        const generation = self.resume_picker_generation;

        var flow = ResumePickerFlow.initLoading(
            self.allocator,
            self.theme,
            restore_session_model,
            generation,
        ) catch {
            self.status_line.setPrimary("failed to open resume picker", self.theme.fg(.@"error"));
            self.tui.dirty = true;
            return;
        };
        errdefer flow.deinit();

        flow.picker.on_select = &onSessionSelected;
        flow.picker.on_cancel = &onSessionPickerCancel;
        flow.picker.callback_ctx = @ptrCast(self);
        self.cancelTranscriptSelection();
        self.resume_picker_flow = flow;
        self.resume_picker_flow.?.handle = self.tui.showOverlay(
            self.resume_picker_flow.?.picker.component(),
            self.bottomPanelOptions(),
        );
        self.tui.dirty = true;

        self.session_index_worker.listResumeSessions(generation, self.cwd) catch {
            self.closeResumePickerFlow();
            self.status_line.setPrimary("failed to queue session listing", self.theme.fg(.@"error"));
            self.tui.dirty = true;
        };
    }

    fn onSessionSelected(selection: PickerSelection, ctx: ?*anyopaque) void {
        const self: *Interactive = @ptrCast(@alignCast(ctx));
        const path = if (self.resume_picker_flow) |*flow|
            if (selection.source_index < flow.rows.len) flow.rows[selection.source_index].path else null
        else
            null;

        const selected_path = path orelse {
            self.closeResumePickerFlow();
            self.status_line.setPrimary("session not found", self.theme.fg(.@"error"));
            return;
        };

        // Clone path into msg_allocator (doctrine R3: cross-thread
        // payload slices must be thread-safe allocated).
        const path_copy = self.msg_allocator.dupe(u8, selected_path) catch {
            self.closeResumePickerFlow();
            self.status_line.setPrimary("out of memory", self.theme.fg(.@"error"));
            return;
        };
        const restore_session_model = self.resume_picker_flow.?.restore_session_model;
        self.closeResumePickerFlow();
        _ = self.dispatchIdleRequest(.{ .resume_session = .{
            .path = path_copy,
            .restore_session_model = restore_session_model,
        } }, .{
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
        self.queueModelPatternSwitch(pattern);
    }

    fn closeExtensionPromptFlow(self: *Interactive, resolve_default: bool) void {
        if (self.extension_prompt_flow) |*flow| {
            if (resolve_default) flow.response.finish(request_mod.ExtensionPromptResponse.defaultFor(flow.prompt.kind));
            if (flow.handle) |h| {
                flow.handle = null;
                h.hide();
            }
            flow.deinit();
        }
        self.extension_prompt_flow = null;
    }

    fn showExtensionPrompt(self: *Interactive, prompt: extension_ui.PromptRequest, response: *request_mod.ExtensionPromptResponse) void {
        self.closeExtensionPromptFlow(true);
        var flow = ExtensionPromptFlow.init(self.allocator, self.theme, prompt, response) catch {
            response.finish(request_mod.ExtensionPromptResponse.defaultFor(prompt.kind));
            return;
        };
        errdefer flow.deinit();
        if (flow.picker) |*picker| {
            picker.on_select = &onExtensionPromptSelected;
            picker.on_cancel = &onExtensionPromptCancelled;
            picker.callback_ctx = @ptrCast(self);
        }
        if (flow.editor) |*editor| {
            editor.setOnSubmit(&onExtensionPromptSubmitted, @ptrCast(self));
        }
        self.cancelTranscriptSelection();
        self.extension_prompt_flow = flow;
        const component = switch (self.extension_prompt_flow.?.prompt.kind) {
            .confirm, .select => self.extension_prompt_flow.?.picker.?.component(),
            .input, .editor => self.extension_prompt_flow.?.editor.?.component(),
        };
        self.extension_prompt_flow.?.handle = self.tui.showOverlay(
            component,
            self.bottomPanelOptions(),
        );
    }

    fn onExtensionPromptSelected(selection: PickerSelection, ctx: ?*anyopaque) void {
        const self: *Interactive = @ptrCast(@alignCast(ctx));
        if (self.extension_prompt_flow) |*flow| {
            switch (flow.prompt.kind) {
                .confirm => flow.response.finish(.{ .confirm = std.mem.eql(u8, selection.item.value, "yes") }),
                .select => {
                    const value = self.msg_allocator.dupe(u8, selection.item.value) catch null;
                    flow.response.finish(.{ .value = if (value) |text| .{ .text = text, .allocator = self.msg_allocator } else null });
                },
                .input, .editor => flow.response.finish(request_mod.ExtensionPromptResponse.defaultFor(flow.prompt.kind)),
            }
        }
        self.closeExtensionPromptFlow(false);
    }

    fn onExtensionPromptSubmitted(text: []const u8, ctx: ?*anyopaque) void {
        const self: *Interactive = @ptrCast(@alignCast(ctx));
        if (self.extension_prompt_flow) |*flow| {
            const value = self.msg_allocator.dupe(u8, text) catch null;
            flow.response.finish(.{ .value = if (value) |owned| .{ .text = owned, .allocator = self.msg_allocator } else null });
        }
        self.closeExtensionPromptFlow(false);
    }

    fn onExtensionPromptCancelled(ctx: ?*anyopaque) void {
        const self: *Interactive = @ptrCast(@alignCast(ctx));
        self.closeExtensionPromptFlow(true);
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
            self.status_line.setPrimary("failed to build model picker", self.theme.fg(.@"error"));
            return;
        };
        errdefer flow.deinit();

        if (flow.rows.len == 0) {
            self.status_line.setPrimary("no models available", self.theme.fg(.muted));
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
            self.status_line.setPrimary("model not found", self.theme.fg(.@"error"));
            return;
        };

        const reference = std.fmt.allocPrint(self.msg_allocator, "{s}/{s}", .{ json_util.providerToString(m.provider), m.id }) catch {
            self.status_line.setPrimary("out of memory", self.theme.fg(.@"error"));
            self.tui.dirty = true;
            return;
        };
        defer self.msg_allocator.free(reference);
        self.queueModelPatternSwitch(reference);
    }

    fn onModelPickerCancel(ctx: ?*anyopaque) void {
        const self: *Interactive = @ptrCast(@alignCast(ctx));
        self.closeModelPickerFlow();
    }

    fn queueModelPatternSwitch(self: *Interactive, pattern: []const u8) void {
        const pattern_copy = self.msg_allocator.dupe(u8, pattern) catch {
            self.status_line.setPrimary("out of memory", self.theme.fg(.@"error"));
            self.tui.dirty = true;
            return;
        };
        _ = self.dispatchIdleRequest(.{ .set_model_by_pattern = .{ .pattern = pattern_copy } }, .{
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
                self.applyTranscriptHideThinkingBlock();
                self.status_line.setPrimary(if (self.hide_thinking_block) "thinking hidden" else "thinking shown", self.theme.fg(.success));
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
            self.status_line.setPrimary("current model unavailable", self.theme.fg(.@"error"));
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

    fn clearLoginPickerEntries(self: *Interactive) void {
        var i: usize = 0;
        while (i < self.login_picker_count) : (i += 1) {
            self.login_picker_entries[i].deinit(self.msg_allocator);
        }
        self.login_picker_count = 0;
    }

    fn showLoginPicker(self: *Interactive) void {
        self.clearLoginPickerEntries();

        const providers = oauth_mod.listProviders(self.msg_allocator) catch {
            self.status_line.setPrimary("failed to load OAuth providers", self.theme.fg(.@"error"));
            return;
        };
        defer self.msg_allocator.free(providers);

        var count: usize = 0;
        for (providers) |provider| {
            if (count >= self.login_picker_items.len) {
                var dropped = provider;
                dropped.deinit(self.msg_allocator);
                continue;
            }
            self.login_picker_entries[count] = provider;
            self.login_picker_items[count] = .{
                .value = provider.id,
                .label = provider.name,
                .description = null,
            };
            count += 1;
        }
        self.login_picker_count = count;

        if (count == 0) {
            self.status_line.setPrimary("no OAuth providers available", self.theme.fg(.muted));
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
            self.status_line.setPrimary("login already in progress", self.theme.fg(.warning));
            return;
        }

        const provider = oauth_mod.findProvider(provider_id) orelse {
            self.status_line.setPrimary("unknown OAuth provider", self.theme.fg(.@"error"));
            return;
        };

        self.login_cancelled.store(false, .release);

        self.status_line.setPrimary("starting login...", self.theme.fg(.muted));
        self.tui.dirty = true;

        const login_ctx = self.msg_allocator.create(LoginContext) catch {
            self.status_line.setPrimary("failed to start login", self.theme.fg(.@"error"));
            return;
        };
        login_ctx.* = .{
            .interactive = self,
            .provider = provider,
        };

        self.login_thread = std.Thread.spawn(.{}, loginThreadFn, .{login_ctx}) catch {
            self.msg_allocator.destroy(login_ctx);
            self.status_line.setPrimary("failed to spawn login thread", self.theme.fg(.@"error"));
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

        const result: oauth_mod.LoginResult = if (!provider.kind.usesExtensionLogin())
            oauth_mod.login(
                self.msg_allocator,
                provider,
                .{
                    .on_auth = &onLoginAuth,
                    .on_progress = &onLoginProgress,
                    .ctx = @ptrCast(self),
                },
                &self.login_cancelled,
            )
        else blk: {
            var response: request_mod.ExtensionOAuthLoginResponse = .{};
            const provider_copy = self.msg_allocator.dupe(u8, provider.id) catch break :blk .{ .err = "out of memory" };
            switch (self.request_queue.trySend(.{ .extension_oauth_login = .{
                .provider_id = provider_copy,
                .callbacks = .{
                    .on_auth = &onLoginAuth,
                    .on_progress = &onLoginProgress,
                    .ctx = @ptrCast(self),
                },
                .response = &response,
            } })) {
                .ok => {},
                .full => |rejected| {
                    var req = rejected;
                    req.deinit(self.msg_allocator);
                    break :blk .{ .err = "login request queue is full" };
                },
                .closed => |rejected| {
                    var req = rejected;
                    req.deinit(self.msg_allocator);
                    break :blk .{ .err = "login request queue is closed" };
                },
                .oom => break :blk .{ .err = "out of memory" },
                .dropped => unreachable,
            }
            const result_from_agent: oauth_mod.LoginResult = switch (response.wait()) {
                .success => |cred| .{ .success = cred },
                .cancelled => .cancelled,
                .err => |msg| .{ .err = msg },
                .unsupported => .{ .err = "extension OAuth login is unsupported for this provider" },
            };
            break :blk result_from_agent;
        };

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
                _ = self.publishLifecycleUiEvent(.{ .login_complete = .{
                    .provider_id = provider_id,
                    .success = true,
                    .message = self.msg_allocator.dupe(u8, "logged in") catch return,
                } });
            },
            .cancelled => {
                _ = self.publishLifecycleUiEvent(.{ .login_complete = .{
                    .provider_id = provider_id,
                    .success = false,
                    .message = self.msg_allocator.dupe(u8, "login cancelled") catch return,
                } });
            },
            .err => |msg| {
                _ = self.publishLifecycleUiEvent(.{ .login_complete = .{
                    .provider_id = provider_id,
                    .success = false,
                    .message = self.msg_allocator.dupe(u8, msg) catch return,
                } });
            },
        }
    }

    // zi-wub.17: login-thread callbacks. These run on the login
    // thread, so they MUST NOT touch TUI-owned state (status_line,
    // tui.dirty, etc). Instead they publish a `login_progress` event
    // on the snapshot queue with an msg_allocator-owned payload; the TUI
    // thread consumes it from the normal drain loop. Single-owner
    // invariant for status_line is restored — only the TUI thread
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
        _ = self.publishSnapshotUiEvent(.{ .login_progress = .{ .message = msg, .kind = .auth_url } });
    }

    fn onLoginProgress(msg: []const u8, ctx: ?*anyopaque) void {
        const self: *Interactive = @ptrCast(@alignCast(ctx));
        const owned = self.msg_allocator.dupe(u8, msg) catch return;
        _ = self.publishSnapshotUiEvent(.{ .login_progress = .{ .message = owned, .kind = .info } });
    }

    fn dispatchExtensionOAuthRefreshViaRequestQueue(
        provider_id: []const u8,
        credential: auth_types.OAuthCredential,
        result_allocator: std.mem.Allocator,
        ctx: ?*anyopaque,
    ) oauth_mod.ExchangeResult {
        const self: *Interactive = @ptrCast(@alignCast(ctx.?));
        var response: request_mod.ExtensionOAuthRefreshResponse = .{};
        const provider_copy = self.msg_allocator.dupe(u8, provider_id) catch return .{ .err = "out of memory" };
        const credential_copy = auth_types.cloneOAuthCredential(self.msg_allocator, credential) catch {
            self.msg_allocator.free(provider_copy);
            return .{ .err = "out of memory" };
        };
        switch (self.request_queue.trySend(.{ .extension_oauth_refresh = .{
            .provider_id = provider_copy,
            .credential = credential_copy,
            .result_allocator = result_allocator,
            .response = &response,
        } })) {
            .ok => {},
            .full => |rejected| {
                var req = rejected;
                req.deinit(self.msg_allocator);
                return .{ .err = "refresh request queue is full" };
            },
            .closed => |rejected| {
                var req = rejected;
                req.deinit(self.msg_allocator);
                return .{ .err = "refresh request queue is closed" };
            },
            .oom => return .{ .err = "out of memory" },
            .dropped => unreachable,
        }
        return switch (response.wait()) {
            .success => |cred| .{ .success = cred },
            .err => |msg| .{ .err = msg },
            .unsupported => .{ .err = "extension OAuth refresh is unsupported for this provider" },
        };
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

        if (self.runtime_host.currentSession().extensionRunner()) |runner| {
            runner.bindLuaOwnerThread(std.Thread.getCurrentId());
            self.publishExtensionCommandsUpdate();
        }
        self.publishVisibleModelsSnapshot();
        _ = self.publishConversationState();
        self.publishQueuedSnapshotIfChanged();

        while (true) {
            _ = self.request_queue.waitReadable(-1) catch break;
            if (self.request_queue.isDrained()) break;
            if (!self.processAgentRequests()) break;
            if (self.request_queue.isDrained()) break;
        }

        self.runtime_host.shutdownCurrentSessionOnAgentThread();
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
            var i: usize = 0;
            while (i < n) : (i += 1) {
                var req = &buf[i];
                switch (req.*) {
                    .prompt => |p| {
                        prompt_processed = true;
                        const outcome = self.runtime_host.runUserContent(p.content) catch |err| {
                            const err_msg = self.msg_allocator.dupe(u8, @errorName(err)) catch null;
                            _ = self.publishLifecycleUiEvent(.{ .prompt_worker_finished = .{
                                .outcome = .assistant_error,
                                .internal_error = err_msg,
                            } });
                            req.deinit(self.msg_allocator);
                            continue;
                        };
                        _ = self.publishLifecycleUiEvent(.{ .prompt_worker_finished = .{ .outcome = outcome } });
                    },
                    .resume_session => |r| {
                        idle_processed = true;
                        self.handleResumeSession(r.path, r.restore_session_model);
                    },
                    .fork_session => |f| {
                        idle_processed = true;
                        self.handleForkSession(f.entry_id);
                    },
                    .new_session => {
                        idle_processed = true;
                        self.handleNewSession();
                    },
                    .set_model => |s| {
                        idle_processed = true;
                        self.handleSetModel(s.model);
                    },
                    .set_model_by_pattern => |s| {
                        idle_processed = true;
                        self.handleSetModelPattern(s.pattern);
                    },
                    .set_thinking_level => |s| {
                        idle_processed = true;
                        self.handleSetThinkingLevel(s.level);
                    },
                    .refresh_status_snapshot => {
                        idle_processed = true;
                        self.publishStatusSnapshot();
                    },
                    .compact => |c| {
                        idle_processed = true;
                        self.handleManualCompactRequest(c.custom_instructions);
                    },
                    .extension_command => |ec| {
                        idle_processed = true;
                        self.runtime_host.dispatchExtensionCommand(ec.name, ec.args) catch |err| {
                            const msg = self.msg_allocator.dupe(u8, @errorName(err)) catch {
                                // OOM: skip publishing error message, keep draining.
                                continue;
                            };
                            _ = self.publishLifecycleUiEvent(.{ .error_message = .{ .message = msg } });
                        };
                        self.publishPendingExtensionUi();
                    },
                    .extension_oauth_login => |oauth| {
                        idle_processed = true;
                        const result: request_mod.ExtensionOAuthLoginResponse.Result = self.runtime_host.dispatchExtensionOAuthLogin(oauth.provider_id, oauth.callbacks) catch |err| blk: {
                            const msg = self.msg_allocator.dupe(u8, @errorName(err)) catch break :blk .unsupported;
                            break :blk .{ .err = msg };
                        };
                        oauth.response.finish(result);
                    },
                    .extension_oauth_refresh => |oauth| {
                        idle_processed = true;
                        const exchange: oauth_mod.ExchangeResult = self.runtime_host.dispatchExtensionOAuthRefresh(oauth.provider_id, oauth.credential, oauth.result_allocator) catch |err| .{ .err = @errorName(err) };
                        const result: request_mod.ExtensionOAuthRefreshResponse.Result = switch (exchange) {
                            .success => |cred| .{ .success = cred },
                            .err => |msg| .{ .err = msg },
                        };
                        oauth.response.finish(result);
                    },
                    .shutdown => {
                        req.deinit(self.msg_allocator);
                        self.discardAgentRequests(buf[i + 1 .. n]);
                        self.discardQueuedAgentRequests();
                        return false;
                    },
                }
                req.deinit(self.msg_allocator);
            }

            if (idle_processed) {
                // Session replacement, model events, oauth callbacks, and future
                // observer paths may run extension code outside command dispatch.
                // Publish any semantic UI records those callbacks produced before
                // telling the TUI thread the idle batch is finished.
                self.publishPendingExtensionUi();
            }
            if (idle_processed and !prompt_processed) {
                _ = self.publishLifecycleUiEvent(.{ .request_worker_finished = {} });
            }
        }
    }

    /// Publish the current extension command surface through the UI event
    /// queue so the TUI thread can rebuild its own registry without reading
    /// or mutating agent-owned runner state directly.
    fn publishExtensionCommandsUpdate(self: *Interactive) void {
        const commands = blk: {
            const runner = self.runtime_host.currentSession().extensionRunner() orelse break :blk self.msg_allocator.alloc(ui_event_mod.ExtensionCommandEntry, 0) catch return;
            const items = runner.command_registry.items();
            var owned = self.msg_allocator.alloc(ui_event_mod.ExtensionCommandEntry, items.len) catch return;
            var built: usize = 0;
            errdefer {
                for (owned[0..built]) |cmd| {
                    self.msg_allocator.free(cmd.name);
                    self.msg_allocator.free(cmd.description);
                }
                self.msg_allocator.free(owned);
            }
            for (items) |entry| {
                owned[built] = .{
                    .name = self.msg_allocator.dupe(u8, entry.visible_name) catch return,
                    .description = self.msg_allocator.dupe(u8, entry.description) catch {
                        self.msg_allocator.free(owned[built].name);
                        return;
                    },
                };
                built += 1;
            }
            break :blk owned;
        };
        _ = self.publishLifecycleUiEvent(.{ .extension_commands_updated = .{ .commands = commands } });
    }

    /// Publish agent-owned extension UI publications across the TUI boundary.
    ///
    /// This is intentionally a semantic publication drain, not TUI access to an
    /// extension UI store. The TUI consumes owned publication records and
    /// materializes them locally; the agent/runtime remains the retained-object
    /// owner. Call this after any agent-thread extension execution boundary that
    /// may have mutated UI state (startup lifecycle, commands, future observers).
    fn publishPendingExtensionUi(self: *Interactive) void {
        if (self.runtime_host.takePendingExtensionPanel(self.msg_allocator)) |panel| {
            _ = self.publishLifecycleUiEvent(.{ .extension_panel_shown = .{ .panel = panel } });
        }
        const updates = self.runtime_host.takePendingExtensionSurfaces(self.msg_allocator);
        if (updates.len > 0) {
            _ = self.publishLifecycleUiEvent(.{ .extension_surfaces_updated = .{ .updates = updates } });
        } else {
            self.msg_allocator.free(updates);
        }
        const actions = self.runtime_host.takePendingExtensionEditorActions(self.msg_allocator);
        if (actions.len > 0) {
            _ = self.publishLifecycleUiEvent(.{ .extension_editor_actions = .{ .actions = actions } });
        } else {
            self.msg_allocator.free(actions);
        }
    }

    fn applyExtensionPanel(self: *Interactive, panel: @import("../coding_agent/extensions/ui.zig").Panel) void {
        const text = panel.flattenText(self.allocator) catch return;
        defer self.allocator.free(text);
        self.extension_panel_text.setContent(text);
        self.tui.dirty = true;
    }

    fn applyExtensionEditorActions(self: *Interactive, actions: []const @import("../coding_agent/extensions/ui.zig").EditorAction) void {
        for (actions) |action| {
            switch (action.kind) {
                .set_text => if (action.text) |text| self.active_editor.setText(text),
                .paste_text => if (action.text) |text| self.active_editor.handlePaste(text),
                .clear_text => self.active_editor.clear(),
                .get_text => {},
            }
        }
        self.tui.dirty = true;
    }

    fn applyExtensionSurfaces(self: *Interactive, updates: []const @import("../coding_agent/extensions/ui.zig").SurfaceUpdate) void {
        for (updates) |update| {
            switch (update.kind) {
                .status => {
                    self.status_data.setStatus(update.id, update.text);
                },
                .header => {
                    self.applySurfaceText(&self.extension_header_text, update);
                    self.extension_header_active = surfaceHasContent(update);
                    self.extension_header_lifetime = update.lifetime;
                    self.refreshHeaderVisibility();
                },
                .footer => self.applySurfaceText(&self.extension_footer_text, update),
                .widget => if (update.placement != null and std.mem.eql(u8, update.placement.?, "belowEditor"))
                    self.applySurfaceText(&self.extension_widget_below_text, update)
                else
                    self.applySurfaceText(&self.extension_widget_above_text, update),
                .working, .overlay => self.applySurfaceText(&self.extension_panel_text, update),
                .title, .thinking_label => {},
            }
        }
        self.tui.dirty = true;
    }

    fn applySurfaceText(self: *Interactive, text_component: *text_mod.Text, update: @import("../coding_agent/extensions/ui.zig").SurfaceUpdate) void {
        const text = update.flattenText(self.allocator) catch return;
        defer self.allocator.free(text);
        text_component.setContent(text);
    }

    fn surfaceHasContent(update: @import("../coding_agent/extensions/ui.zig").SurfaceUpdate) bool {
        if (update.text) |text| if (text.len > 0) return true;
        return update.lines.len > 0;
    }

    /// TUI-thread application of the latest extension command surface.
    fn applyExtensionCommandsUpdate(self: *Interactive, commands: []const ui_event_mod.ExtensionCommandEntry) void {
        for (self.command_registry.dynamic.items) |*cmd| {
            self.allocator.free(cmd.name);
            if (cmd.description) |d| self.allocator.free(d);
        }
        self.command_registry.dynamic.clearRetainingCapacity();

        for (commands) |entry| {
            const name = self.allocator.dupe(u8, entry.name) catch continue;
            const desc = self.allocator.dupe(u8, entry.description) catch {
                self.allocator.free(name);
                continue;
            };
            self.command_registry.register(.{
                .name = name,
                .description = desc,
                .source = .extension,
                .action = .extension,
            });
        }
        self.tui.dirty = true;
    }

    /// Agent-thread handler for `AgentRequest.compact`. The runner emits
    /// `compaction_start`/`compaction_end` events which the TUI consumes
    /// via `sessionEventCallback`; no direct mutation of agent-owned state
    /// happens here. Failures still flow through `compaction_end`.
    fn handleManualCompactRequest(self: *Interactive, custom_instructions: ?[]const u8) void {
        _ = self.runtime_host.runCompaction(.manual, false, .{
            .custom_instructions = custom_instructions,
        }) catch {
            self.publishStatusSnapshot();
            return;
        };
        self.publishStatusSnapshot();
        if (!self.publishConversationState()) {
            log.warn("snapshot queue dropped post-compaction conversation state", .{});
        }
    }

    fn handleNewSession(self: *Interactive) void {
        self.runtime_host.newSession() catch |err| {
            const msg = switch (err) {
                error.SessionBeforeSwitchBlocked => self.msg_allocator.dupe(u8, "session switch blocked by extension") catch return,
                else => std.fmt.allocPrint(self.msg_allocator, "failed to start new session: {s}", .{@errorName(err)}) catch return,
            };
            _ = self.publishLifecycleUiEvent(.{ .session_new_failed = .{ .message = msg } });
            return;
        };
        self.publishExtensionCommandsUpdate();
        self.publishThemeSnapshot();
        self.publishVisibleModelsSnapshot();
        self.publishStatusSnapshot();
        if (!self.publishConversationState()) {
            log.warn("snapshot queue dropped new-session conversation state", .{});
        }
        self.publishQueuedSnapshotIfChanged();
        _ = self.publishLifecycleUiEvent(.{ .session_new_started = {} });
    }

    fn handleForkSession(self: *Interactive, entry_id: []const u8) void {
        self.runtime_host.forkSession(entry_id) catch |err| {
            const msg = switch (err) {
                error.SessionBeforeForkBlocked => self.msg_allocator.dupe(u8, "session fork blocked by extension") catch return,
                else => std.fmt.allocPrint(self.msg_allocator, "failed to fork session: {s}", .{@errorName(err)}) catch return,
            };
            _ = self.publishLifecycleUiEvent(.{ .session_new_failed = .{ .message = msg } });
            return;
        };
        self.publishExtensionCommandsUpdate();
        self.publishThemeSnapshot();
        self.publishVisibleModelsSnapshot();
        self.publishStatusSnapshot();
        if (!self.publishConversationState()) {
            log.warn("snapshot queue dropped forked conversation state", .{});
        }
        self.publishQueuedSnapshotIfChanged();
        _ = self.publishLifecycleUiEvent(.{ .session_fork_started = {} });
    }

    /// Agent-thread handler for `AgentRequest.resume_session`.
    /// Loads the session via `openSession` (agent_arena allocated),
    /// binds the authoritative session state on the agent thread, and
    /// then publishes semantic snapshots back to the TUI.
    ///
    /// Transcript rebuild stays on the TUI thread — this handler
    /// does NOT touch `self.transcript`. That's .15's whole point.
    fn handleResumeSession(self: *Interactive, path: []const u8, restore_session_model: bool) void {
        const result = self.runtime_host.resumeSession(path, restore_session_model) catch |err| {
            const message = switch (err) {
                error.SessionAlreadyActive => "session is already active",
                error.SessionBeforeSwitchBlocked => "session switch blocked by extension",
                else => "failed to load session",
            };
            const msg = self.msg_allocator.dupe(u8, message) catch return;
            _ = self.publishLifecycleUiEvent(.{ .session_resume_failed = .{ .message = msg } });
            return;
        };

        const restore_warning = result.restore_warning;

        self.publishExtensionCommandsUpdate();
        self.publishThemeSnapshot();
        self.publishVisibleModelsSnapshot();
        self.publishStatusSnapshot();
        if (!self.publishConversationState()) {
            log.warn("snapshot queue dropped resumed conversation state", .{});
        }
        self.publishQueuedSnapshotIfChanged();
        _ = self.publishLifecycleUiEvent(.{ .session_resumed = .{
            .restore_warning = restore_warning,
        } });
    }

    fn publishConversationState(self: *Interactive) bool {
        return self.runtime_host.publishConversationState(self.conversationSnapshotPublisher());
    }

    fn publishQueuedSnapshot(self: *Interactive) bool {
        return self.runtime_host.publishQueuedSnapshot(self.queuedSnapshotPublisher());
    }

    /// Agent-thread entry point for queued-snapshot publication. Skips
    /// the publish when the run-control version hasn't moved since we
    /// last pushed. This is how pending rows disappear after the agent
    /// loop drains steering/follow-up during a run — the drain bumps
    /// the version, and this call picks that up on the next event flush.
    fn publishQueuedSnapshotIfChanged(self: *Interactive) void {
        const current_version = self.runtime_host.currentQueuedVersion();
        if (current_version == self.last_published_queued_version) return;
        if (self.publishQueuedSnapshot()) {
            self.last_published_queued_version = current_version;
        }
    }

    /// Soft conversation-publish cadence (ns between forced publishes
    /// while streaming). 30 Hz feels "live" in a terminal and lets us
    /// collapse token-rate event floods (1000+/turn) down to ~30/sec.
    const soft_conversation_publish_cadence_ns: u64 = 33 * std.time.ns_per_ms;

    fn monotonicNowNs() u64 {
        return @intCast(std.time.nanoTimestamp());
    }

    /// Flush the latest conversation snapshot unconditionally.
    fn flushPendingConversationPublish(self: *Interactive, event: AgentEvent) void {
        _ = event;
        const published = self.publishConversationState();
        self.publishQueuedSnapshotIfChanged();
        if (published) {
            self.last_conversation_publish_ns = monotonicNowNs();
            self.conversation_publish_dirty = false;
        }
    }

    /// Soft path: mark dirty and publish only if cadence has elapsed
    /// since the last publish. Otherwise drop — the next event will
    /// re-check, or a hard boundary will flush. Accepted edge: a mid-
    /// stream pause longer than the cadence leaves one pending snapshot
    /// deferred until the next event; acceptable for P1.
    fn maybePublishSoftConversation(self: *Interactive, event: AgentEvent) void {
        _ = event;
        self.conversation_publish_dirty = true;
        const now = monotonicNowNs();
        const elapsed = now -% self.last_conversation_publish_ns;
        if (elapsed < soft_conversation_publish_cadence_ns) return;
        const published = self.publishConversationState();
        if (!published) return;
        self.last_conversation_publish_ns = now;
        self.conversation_publish_dirty = false;
    }

    fn conversationSnapshotPublisher(self: *Interactive) ConversationSnapshotPublisher {
        return .{
            .func = &publishConversationSnapshotToUi,
            .ctx = @ptrCast(self),
        };
    }

    fn queuedSnapshotPublisher(self: *Interactive) coding_agent_mod.runtime_host.QueuedSnapshotPublisher {
        return .{
            .func = &publishQueuedSnapshotToUi,
            .ctx = @ptrCast(self),
        };
    }

    fn publishConversationSnapshotToUi(envelope: agent_mod.conversation_state.ConversationSnapshotEnvelope, ctx: ?*anyopaque) bool {
        const self: *Interactive = @ptrCast(@alignCast(ctx));
        return self.publishSnapshotUiEvent(.{ .conversation_snapshot = envelope });
    }

    fn publishQueuedSnapshotToUi(snapshot: coding_agent_mod.runtime_host.QueuedMessageSnapshot, ctx: ?*anyopaque) bool {
        const self: *Interactive = @ptrCast(@alignCast(ctx));
        return self.publishSnapshotUiEvent(.{ .queued_snapshot = snapshot });
    }

    /// Agent-thread handler for `AgentRequest.set_model` (zi-wub.16).
    /// Delegates the canonical validation + mutation path to
    /// `AgentSession.trySetModel`, then translates the typed outcome
    /// into a TUI-owned event payload.
    fn handleSetModel(self: *Interactive, m: ai_protocol.Model) void {
        switch (self.runtime_host.currentSession().trySetModel(m)) {
            .success => |_| {
                self.publishStatusSnapshot();
                const model_id = self.msg_allocator.dupe(u8, m.id) catch return;
                _ = self.publishLifecycleUiEvent(.{ .model_switched = .{ .model_id = model_id } });
            },
            .no_auth => |blocked| {
                const provider_str = json_util.providerToString(blocked.provider);
                const msg = std.fmt.allocPrint(
                    self.msg_allocator,
                    "No API key for {s}/{s}",
                    .{ provider_str, blocked.id },
                ) catch return;
                _ = self.publishLifecycleUiEvent(.{ .model_switch_failed = .{ .message = msg } });
            },
            .registry_unavailable => {
                const msg = self.msg_allocator.dupe(u8, "model registry unavailable") catch return;
                _ = self.publishLifecycleUiEvent(.{ .model_switch_failed = .{ .message = msg } });
            },
        }
    }

    fn handleSetModelPattern(self: *Interactive, pattern: []const u8) void {
        const registry = self.runtime_host.currentSession().model_registry orelse {
            const msg = self.msg_allocator.dupe(u8, "model registry unavailable") catch return;
            _ = self.publishLifecycleUiEvent(.{ .model_switch_failed = .{ .message = msg } });
            return;
        };

        var scratch = std.heap.ArenaAllocator.init(self.msg_allocator);
        defer scratch.deinit();
        const result = ai_resolve.resolveCliModel(.{
            .cli_model = pattern,
            .registry = registry,
            .allocator = scratch.allocator(),
        });
        if (result.err) |err_msg| {
            const msg = self.msg_allocator.dupe(u8, err_msg) catch return;
            _ = self.publishLifecycleUiEvent(.{ .model_switch_failed = .{ .message = msg } });
            return;
        }
        const model = result.model orelse {
            const msg = self.msg_allocator.dupe(u8, "model not found") catch return;
            _ = self.publishLifecycleUiEvent(.{ .model_switch_failed = .{ .message = msg } });
            return;
        };
        self.handleSetModel(model);
    }

    fn publishThemeSnapshot(self: *Interactive) void {
        _ = self.publishSnapshotUiEvent(.{ .theme_changed = self.runtime_host.selectedTheme() });
    }

    pub fn applyTheme(self: *Interactive, theme: theme_mod.Theme) void {
        self.theme_storage = theme;
        self.theme = &self.theme_storage;
        self.greeter.theme = self.theme;
        self.footer.theme = self.theme;
        self.hotkeys_overlay.theme = self.theme;
        if (self.active_editor_bound) {
            self.active_editor.setTheme(self.theme);
        } else {
            self.editor.setTheme(self.theme);
        }
        self.transcript.theme = self.theme;
        self.status_line.setTheme(self.theme);
        self.pending_image_banner.fg = self.theme.fg(.accent);
        self.pending_image_banner.bg = self.theme.bg(.tool_pending_bg);
    }

    fn publishVisibleModelsSnapshot(self: *Interactive) void {
        const registry = self.runtime_host.currentSession().model_registry orelse {
            _ = self.publishLifecycleUiEvent(.{ .visible_models_snapshot = .{ .models = &.{} } });
            return;
        };
        const models = coding_agent_mod.model_registry.cloneOwnedModels(self.msg_allocator, registry.getAll()) catch return;
        _ = self.publishLifecycleUiEvent(.{ .visible_models_snapshot = .{ .models = models } });
    }

    fn publishStatusSnapshot(self: *Interactive) void {
        const snapshot = self.runtime_host.currentSession().statusSnapshot();
        if (self.shouldSkipStatusSnapshotPublish(snapshot)) return;

        const provider_copy = self.msg_allocator.dupe(u8, snapshot.model_provider) catch return;
        errdefer self.msg_allocator.free(provider_copy);
        const model_id_copy = self.msg_allocator.dupe(u8, snapshot.model_id) catch return;
        errdefer self.msg_allocator.free(model_id_copy);
        const thinking_copy = self.msg_allocator.dupe(u8, agentThinkingLabel(snapshot.thinking_level)) catch return;
        errdefer self.msg_allocator.free(thinking_copy);

        if (self.publishSnapshotUiEvent(.{ .status_snapshot = .{
            .model_provider = provider_copy,
            .model_id = model_id_copy,
            .thinking_level = thinking_copy,
            .context_tokens = snapshot.context_tokens,
            .context_window = snapshot.context_window,
        } })) {
            self.rememberPublishedStatusSnapshot(snapshot);
        }
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
        if (!shouldPublishStatusSnapshotForAgentEvent(event)) return;
        self.publishStatusSnapshot();
    }

    fn shouldPublishStatusSnapshotForAgentEvent(event: AgentEvent) bool {
        return switch (event) {
            .message_end => true,
            .turn_end => |payload| switch (payload.message) {
                .assistant => true,
                else => false,
            },
            else => false,
        };
    }

    fn handleSetThinkingLevel(self: *Interactive, level: agent_protocol.ThinkingLevel) void {
        _ = self.runtime_host.currentSession().trySetThinkingLevel(level);
        self.publishStatusSnapshot();
        const level_label = self.msg_allocator.dupe(u8, agentThinkingLabel(level)) catch return;
        _ = self.publishLifecycleUiEvent(.{ .thinking_level_changed = .{ .level = level_label } });
    }

    fn publishConversationStateForAgentEvent(self: *Interactive, event: AgentEvent) void {
        switch (event) {
            .message_start => |payload| switch (payload.message) {
                .assistant => self.flushPendingConversationPublish(event),
                else => {},
            },
            // Soft deltas: coalesce at the configured cadence.
            .message_update, .tool_execution_update => {
                self.maybePublishSoftConversation(event);
            },
            // Hard semantic boundaries: flush now so the UI never stalls
            // behind a dropped soft event.
            .message_end, .tool_execution_start, .tool_execution_end, .agent_end => {
                self.flushPendingConversationPublish(event);
            },
            .turn_end => |payload| {
                if (payload.message != .assistant) return;
                self.flushPendingConversationPublish(event);
            },
            .agent_start, .turn_start => {},
        }
    }

    /// Raw agent event callback — runs on the AGENT THREAD.
    fn agentEventCallback(event: AgentEvent, ctx: ?*anyopaque) void {
        const self: *Interactive = @ptrCast(@alignCast(ctx));
        self.publishConversationStateForAgentEvent(event);
        if (convertAgentUiEvent(event, self.msg_allocator)) |ui_event| {
            _ = self.publishUiEvent(ui_event);
        }
        self.publishStatusSnapshotForAgentEvent(event);
        self.publishPendingExtensionUi();
    }

    /// Session event callback — runs on the AGENT THREAD.
    fn sessionEventCallback(event: SessionEvent, ctx: ?*anyopaque) void {
        const self: *Interactive = @ptrCast(@alignCast(ctx));
        switch (event) {
            .auto_retry_start => |retry| {
                const err_msg = self.msg_allocator.dupe(u8, retry.error_message) catch return;
                _ = self.publishLifecycleUiEvent(.{ .retry_start = .{
                    .attempt = retry.attempt,
                    .max_attempts = retry.max_attempts,
                    .delay_ms = retry.delay_ms,
                    .error_message = err_msg,
                } });
            },
            .auto_retry_wait_finished => {
                _ = self.publishLifecycleUiEvent(.retry_wait_finished);
            },
            .auto_retry_end => |retry| {
                const final_error = if (retry.final_error) |msg|
                    (self.msg_allocator.dupe(u8, msg) catch null)
                else
                    null;
                _ = self.publishLifecycleUiEvent(.{ .retry_end = .{
                    .success = retry.success,
                    .attempt = retry.attempt,
                    .final_error = final_error,
                    .failure_kind = retry.failure_kind,
                } });
            },
            .compaction_start => {
                self.publishStatusSnapshot();
            },
            .compaction_end => |compaction| {
                self.publishManualCompactionLifecycle(compaction);
                self.publishStatusSnapshot();
                _ = self.publishConversationState();
            },
            .visible_models_changed => {
                self.publishVisibleModelsSnapshot();
                self.publishStatusSnapshot();
            },
            .extension_prompt_request => |request| {
                const prompt = extension_ui.PromptRequest.clone(self.msg_allocator, request.prompt) catch {
                    request.response.finish(request_mod.ExtensionPromptResponse.defaultFor(request.prompt.kind));
                    return;
                };
                _ = self.publishLifecycleUiEvent(.{ .extension_prompt_requested = .{ .prompt = prompt, .response = request.response } });
            },
        }
    }

    fn publishManualCompactionLifecycle(
        self: *Interactive,
        compaction: coding_agent_mod.session_event.CompactionEnd,
    ) void {
        if (compaction.reason != .manual) return;

        if (compaction.success) {
            _ = self.publishLifecycleUiEvent(.{ .session_compacted = {} });
            return;
        }

        const msg = if (compaction.aborted)
            self.msg_allocator.dupe(u8, "compaction cancelled") catch return
        else if (compaction.error_message) |err|
            self.msg_allocator.dupe(u8, err) catch return
        else
            self.msg_allocator.dupe(u8, "compaction failed") catch return;
        _ = self.publishLifecycleUiEvent(.{ .session_compaction_failed = .{ .message = msg } });
    }
};

fn buildSubmittedUserContent(
    allocator: std.mem.Allocator,
    text: []const u8,
    pending_images: []const PendingImageAttachment,
) !BuiltSubmitContent {
    if (pending_images.len == 0) return .{ .content = .{ .text = text } };

    const text_block_count: usize = if (text.len > 0) 1 else 0;
    const blocks = try allocator.alloc(ai_protocol.UserMessage.UserMessageContent.Block, pending_images.len + text_block_count);

    var next_index: usize = 0;
    if (text.len > 0) {
        blocks[next_index] = .{ .text = .{ .text = text } };
        next_index += 1;
    }
    for (pending_images) |attachment| {
        blocks[next_index] = .{ .image = attachment.image };
        next_index += 1;
    }

    return .{ .content = .{ .blocks = blocks } };
}

fn prepareClipboardImageAttachment(
    allocator: std.mem.Allocator,
    raw: []const u8,
    policy: image_mod.InlinePolicy,
) !PreparedClipboardImageResult {
    const mime = image_mod.sniffMime(raw) orelse {
        return .{ .rejected = try allocator.dupe(u8, "clipboard image format unsupported") };
    };
    const dimensions = image_mod.sniffDimensions(raw, mime);
    switch (image_mod.evaluateInlineImage(raw.len, dimensions, policy)) {
        .needs_resize => return .{ .rejected = try std.fmt.allocPrint(
            allocator,
            "clipboard image not attached: {s}",
            .{image_mod.omittedInlineNote()},
        ) },
        .attach_original => {
            const encoded = try encodeBase64Owned(allocator, raw);
            errdefer allocator.free(encoded);
            const mime_owned = try allocator.dupe(u8, image_mod.mimeString(mime));
            return .{ .attach = .{
                .image = .{
                    .data = encoded,
                    .mime_type = mime_owned,
                },
                .dimensions = dimensions,
            } };
        },
    }
}

fn pendingImageBannerText(
    allocator: std.mem.Allocator,
    pending_images: []const PendingImageAttachment,
) ![]u8 {
    var clear_binding_buf: [32]u8 = undefined;
    const clear_binding = keybindings.formatBindings(.app_clear, " / ", &clear_binding_buf);
    const last = pending_images[pending_images.len - 1];

    if (pending_images.len == 1) {
        if (last.dimensions) |dimensions| {
            return std.fmt.allocPrint(
                allocator,
                "1 clipboard image pending ({s}, {d}x{d}) · {s} to clear",
                .{ last.image.mime_type, dimensions.width, dimensions.height, clear_binding },
            );
        }
        return std.fmt.allocPrint(
            allocator,
            "1 clipboard image pending ({s}) · {s} to clear",
            .{ last.image.mime_type, clear_binding },
        );
    }

    if (last.dimensions) |dimensions| {
        return std.fmt.allocPrint(
            allocator,
            "{d} clipboard images pending (latest {s}, {d}x{d}) · {s} to clear",
            .{ pending_images.len, last.image.mime_type, dimensions.width, dimensions.height, clear_binding },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "{d} clipboard images pending (latest {s}) · {s} to clear",
        .{ pending_images.len, last.image.mime_type, clear_binding },
    );
}

fn encodeBase64Owned(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(raw.len));
    _ = std.base64.standard.Encoder.encode(encoded, raw);
    return encoded;
}

fn userFacingFailureMessage(
    failure_kind: ?ai_protocol.NormalizedFailure.Kind,
    raw_message: []const u8,
) []const u8 {
    return switch (failure_kind orelse return raw_message) {
        .auth => "authentication failed. run /login or refresh your credentials.",
        .context_overflow => "context window exceeded. compact the session or switch to a larger-context model.",
        .rate_limited => "provider rate limit reached. wait and try again, or switch providers.",
        .transient => "provider or network failure. try again shortly.",
        .invalid_request => if (string_util.containsCI(raw_message, "content_filter"))
            "request blocked by the provider safety filter. try rephrasing and try again."
        else
            raw_message,
        else => raw_message,
    };
}

/// Convert an AgentEvent to a small TUI side-effect event.
/// Conversation semantics cross separately as `conversation_state`.
fn convertAgentUiEvent(event: AgentEvent, allocator: std.mem.Allocator) ?UiEvent {
    switch (event) {
        .message_update => |mu| switch (mu.assistant_message_event) {
            .@"error" => |e| {
                const assistant = e.@"error";
                if (assistant.error_message) |msg| {
                    const display = userFacingFailureMessage(if (assistant.failure) |failure| failure.kind else null, msg);
                    const owned = allocator.dupe(u8, display) catch return null;
                    return .{ .error_message = .{ .message = owned } };
                }
                return null;
            },
            else => return null,
        },
        .tool_execution_start => |te| {
            const tool_name = allocator.dupe(u8, te.tool_name) catch return null;
            return .{ .tool_running = .{ .tool_name = tool_name } };
        },
        .message_end => |me| switch (me.message) {
            .assistant => |assistant| {
                if (assistant.stop_reason != .aborted and assistant.stop_reason != .@"error") return null;
                const err_msg = if (assistant.error_message) |msg|
                    (allocator.dupe(u8, msg) catch null)
                else
                    null;
                return .{ .assistant_run_finished = .{
                    .is_aborted = assistant.stop_reason == .aborted,
                    .error_message = err_msg,
                    .failure_kind = if (assistant.failure) |failure| failure.kind else null,
                } };
            },
            else => return null,
        },
        .agent_start, .agent_end, .turn_start, .turn_end, .message_start, .tool_execution_update, .tool_execution_end => return null,
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

const testing = std.testing;

fn pngHeader(width: u32, height: u32) [24]u8 {
    return .{
        0x89,                                    0x50,                                    0x4E,                                   0x47,                            0x0D,                                     0x0A,                                     0x1A,                                    0x0A,
        0x00,                                    0x00,                                    0x00,                                   0x0D,                            0x49,                                     0x48,                                     0x44,                                    0x52,
        @as(u8, @intCast((width >> 24) & 0xFF)), @as(u8, @intCast((width >> 16) & 0xFF)), @as(u8, @intCast((width >> 8) & 0xFF)), @as(u8, @intCast(width & 0xFF)), @as(u8, @intCast((height >> 24) & 0xFF)), @as(u8, @intCast((height >> 16) & 0xFF)), @as(u8, @intCast((height >> 8) & 0xFF)), @as(u8, @intCast(height & 0xFF)),
    };
}

test "prepareClipboardImageAttachment accepts clipboard png within inline policy" {
    const png = pngHeader(64, 32);
    var prepared = try prepareClipboardImageAttachment(testing.allocator, &png, .{});
    defer prepared.deinit(testing.allocator);

    switch (prepared) {
        .attach => |attachment| {
            try testing.expectEqualStrings("image/png", attachment.image.mime_type);
            try testing.expectEqual(image_mod.Dimensions{ .width = 64, .height = 32 }, attachment.dimensions.?);
        },
        .rejected => return error.ExpectedClipboardAttachment,
    }
}

test "prepareClipboardImageAttachment rejects oversized clipboard image when auto resize is enabled" {
    const png = pngHeader(640, 480);
    var prepared = try prepareClipboardImageAttachment(testing.allocator, &png, .{
        .auto_resize = true,
        .max_width = 100,
        .max_height = 100,
        .max_base64_bytes = 1024,
    });
    defer prepared.deinit(testing.allocator);

    switch (prepared) {
        .rejected => |message| try testing.expect(std.mem.indexOf(u8, message, image_mod.omittedInlineNote()) != null),
        .attach => return error.ExpectedClipboardRejection,
    }
}

test "buildSubmittedUserContent places text before pending images" {
    const data = try testing.allocator.dupe(u8, "ZGF0YQ==");
    defer testing.allocator.free(data);
    const mime_type = try testing.allocator.dupe(u8, "image/png");
    defer testing.allocator.free(mime_type);

    const pending = [_]PendingImageAttachment{.{
        .image = .{ .data = data, .mime_type = mime_type },
        .dimensions = .{ .width = 10, .height = 20 },
    }};

    var built = try buildSubmittedUserContent(testing.allocator, "describe this", &pending);
    defer built.deinit(testing.allocator);

    switch (built.content) {
        .blocks => |blocks| {
            try testing.expectEqual(@as(usize, 2), blocks.len);
            try testing.expectEqualStrings("describe this", blocks[0].text.text);
            try testing.expectEqualStrings("image/png", blocks[1].image.mime_type);
        },
        .text => return error.ExpectedBlockContent,
    }
}

test "pendingImageBannerText includes latest image details and clear shortcut" {
    const data1 = try testing.allocator.dupe(u8, "aaa");
    defer testing.allocator.free(data1);
    const mime1 = try testing.allocator.dupe(u8, "image/png");
    defer testing.allocator.free(mime1);
    const data2 = try testing.allocator.dupe(u8, "bbb");
    defer testing.allocator.free(data2);
    const mime2 = try testing.allocator.dupe(u8, "image/jpeg");
    defer testing.allocator.free(mime2);

    const pending = [_]PendingImageAttachment{
        .{ .image = .{ .data = data1, .mime_type = mime1 }, .dimensions = .{ .width = 10, .height = 20 } },
        .{ .image = .{ .data = data2, .mime_type = mime2 }, .dimensions = .{ .width = 30, .height = 40 } },
    };

    const banner = try pendingImageBannerText(testing.allocator, &pending);
    defer testing.allocator.free(banner);

    try testing.expect(std.mem.indexOf(u8, banner, "2 clipboard images pending") != null);
    try testing.expect(std.mem.indexOf(u8, banner, "image/jpeg") != null);
    try testing.expect(std.mem.indexOf(u8, banner, "30x40") != null);
    try testing.expect(std.mem.indexOf(u8, banner, "ctrl+c") != null);
}

test "status snapshot publication follows message-end source mutations" {
    const user = agent_protocol.AgentMessage{ .user = .{
        .content = .{ .text = "hello" },
        .timestamp = 1,
    } };
    const assistant = agent_protocol.AgentMessage{ .assistant = .{
        .content = &.{},
        .api = .openai_responses,
        .provider = .openai,
        .model = "gpt-test",
        .usage = .{
            .input = 0,
            .output = 0,
            .cache_read = 0,
            .cache_write = 0,
            .total_tokens = 0,
            .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 },
        },
        .stop_reason = .stop,
        .timestamp = 2,
    } };
    const tool_result = agent_protocol.AgentMessage{ .tool_result = .{
        .tool_call_id = "tool-1",
        .tool_name = "read",
        .content = &.{},
        .is_error = false,
        .timestamp = 3,
    } };

    try testing.expect(Interactive.shouldPublishStatusSnapshotForAgentEvent(.{ .message_end = .{ .message = user } }));
    try testing.expect(Interactive.shouldPublishStatusSnapshotForAgentEvent(.{ .message_end = .{ .message = assistant } }));
    try testing.expect(Interactive.shouldPublishStatusSnapshotForAgentEvent(.{ .message_end = .{ .message = tool_result } }));
    try testing.expect(Interactive.shouldPublishStatusSnapshotForAgentEvent(.{ .turn_end = .{ .message = assistant, .tool_results = &.{} } }));
}
