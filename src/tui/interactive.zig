const std = @import("std");
const posix = std.posix;
const cell_mod = @import("cell.zig");
const buffer_mod = @import("primitives/surface.zig");
const renderer_mod = @import("renderer.zig");
const terminal_mod = @import("terminal/mod.zig");
const keys_mod = @import("terminal/keys.zig");
const component_mod = @import("primitives/view.zig");
const text_mod = @import("components/text.zig");
const status_line_mod = @import("components/status_line.zig");
const greeter_mod = @import("components/greeter.zig");
const footer_mod = @import("components/footer.zig");
const editor_mod = @import("components/editor.zig");
const hotkeys_overlay_mod = @import("components/hotkeys_overlay.zig");
const ui_event_mod = @import("ui_event.zig");
const ai_complete_worker_mod = @import("../coding_agent/extensions/ai_complete_worker.zig");
const system_worker_mod = @import("../coding_agent/extensions/system_worker.zig");
const extension_runner_mod = @import("../coding_agent/extensions/runner.zig");
const system_command_mod = @import("../coding_agent/extensions/system_command.zig");
const transcript_mod = @import("conversation/transcript.zig");
const conversation_projection_mod = @import("conversation/projection.zig");
const overlay_mod = @import("primitives/overlay.zig");
const tool_display_mod = @import("conversation/tool_display.zig");
const theme_mod = @import("theme.zig");
const themes_builtin = @import("../themes/builtin.zig");
const app_meta = @import("../runtime/app.zig");
const tui_mod = @import("tui.zig");
const editor_iface_mod = @import("editor/interface.zig");
const input_buffer_mod = @import("terminal/input_buffer.zig");
const queues_mod = @import("interactive/runtime/queues.zig");
const mailbox_mod = @import("../zio/root.zig").mailbox;
const model_picker_flow_mod = @import("interactive/model_picker_flow.zig");
const model_flow = @import("interactive/model_flow.zig");
const resume_picker_flow_mod = @import("interactive/resume_picker_flow.zig");
const thinking_mod = @import("interactive/thinking.zig");
const slash_command_mod = @import("interactive/slash_command.zig");
const ui_event_handler_mod = @import("interactive/ui_event_handler.zig");
const session_requests_mod = @import("interactive/session_requests.zig");
const model_requests_mod = @import("interactive/model_requests.zig");
const session_events_mod = @import("interactive/session_events.zig");
const runtime_process = @import("../zio/root.zig").process;
const session_flow = @import("interactive/session_flow.zig");
const conversation_publish = @import("interactive/conversation_publish.zig");
const key_flow_mod = @import("interactive/key_flow.zig");
const transcript_mouse = @import("interactive/transcript_mouse.zig");
const login_flow = @import("interactive/login_flow.zig");
const composer_flow = @import("interactive/composer_flow.zig");
const settings_flow_mod = @import("interactive/settings_flow.zig");
const status_snapshot_mod = @import("interactive/status_snapshot.zig");
const status_flow = @import("interactive/status_flow.zig");
const memory_telemetry = @import("interactive/runtime/memory_telemetry.zig");
const overlay_flow = @import("interactive/overlay_flow.zig");
const simple_picker_flow_mod = @import("interactive/simple_picker_flow.zig");
const idle_request = @import("interactive/runtime/idle_request.zig");
const runtime_loop = @import("interactive/runtime/loop.zig");
const job_manager_mod = @import("interactive/runtime/job_manager.zig");
const theme_flow = @import("interactive/theme_flow.zig");
const terminal_input_flow = @import("interactive/terminal_input.zig");
const external_editor_flow = @import("interactive/external_editor.zig");
const event_flow = @import("interactive/runtime/events.zig");
const run_setup = @import("interactive/run_setup.zig");
const startup_flow = @import("interactive/startup_flow.zig");
const extension_ui_state_mod = @import("interactive/extension_ui_state.zig");
const extension_ui_flow = @import("interactive/extension_ui.zig");
const status_data_mod = @import("status_data.zig");
const clipboard_mod = @import("terminal/clipboard.zig");
const agent_ui_event_mod = @import("interactive/agent_ui_event.zig");
const clipboard_images_mod = @import("interactive/clipboard_images.zig");
const scroll_text_overlay_mod = @import("components/scroll_text_overlay.zig");
const logging = @import("../logging.zig");

const autocomplete_mod = @import("autocomplete/provider.zig");
const keybindings = @import("keybindings.zig");
const slash_commands_mod = @import("../coding_agent/slash_commands.zig");
const request_mod = @import("../coding_agent/request.zig");
const extension_ui = @import("../coding_agent/extensions/ui.zig");
const CombinedAutocompleteProvider = autocomplete_mod.CombinedAutocompleteProvider;
const CommandRegistry = slash_commands_mod.CommandRegistry;
const list_picker_mod = @import("components/list_picker.zig");
const select_list_mod = @import("components/select_list.zig");
const PickerSelection = list_picker_mod.Selection;
const SelectItem = select_list_mod.SelectItem;
const SimplePickerFlow = simple_picker_flow_mod.SimplePickerFlow;
const ScrollTextOverlay = scroll_text_overlay_mod.ScrollTextOverlay;

pub const TerminalSystemRequest = struct {
    id: extension_runner_mod.AsyncOpId,
    system: extension_runner_mod.SystemRequest,

    pub fn deinit(self: *TerminalSystemRequest, allocator: std.mem.Allocator) void {
        self.system.deinit(allocator);
        self.* = undefined;
    }
};
const TerminalSystemQueue = mailbox_mod.Mailbox(TerminalSystemRequest, .{ .cleanup = .deinit, .policy = .{ .bounded = .{ .capacity = 8, .on_full = .reject } }, .wakeup = .pipe });
const UiSnapshotQueue = queues_mod.UiSnapshotQueue;
const UiLifecycleQueue = queues_mod.UiLifecycleQueue;
const PublishedStatusSnapshot = status_snapshot_mod.PublishedStatusSnapshot;
const convertAgentUiEvent = agent_ui_event_mod.convertAgentUiEvent;
const userFacingFailureMessage = agent_ui_event_mod.userFacingFailureMessage;
const PendingImageAttachment = clipboard_images_mod.PendingImageAttachment;
const ModelPickerFlow = model_picker_flow_mod.ModelPickerFlow;
const ResumePickerFlow = resume_picker_flow_mod.ResumePickerFlow;
const ExtensionUiState = extension_ui_state_mod.ExtensionUiState;
const session_store_mod = @import("../coding_agent/session/store.zig");
const session_index_worker_mod = @import("interactive/session_index_worker.zig");
const SessionStore = session_store_mod.SessionStore;

const agent_mod = @import("../agent/root.zig");
const coding_agent_mod = @import("../coding_agent/root.zig");
const AgentEvent = agent_mod.protocol.AgentEvent;
const AgentRequest = coding_agent_mod.AgentRequest;
const RequestQueue = coding_agent_mod.RequestQueue;
const agent_protocol = agent_mod.protocol;
const RetryPolicy = coding_agent_mod.runtime_host.RetryPolicy;
const CompactionPolicy = coding_agent_mod.runtime_host.CompactionPolicy;
const CompactionExecutor = coding_agent_mod.runtime_host.CompactionExecutor;
const log = std.log.scoped(.tui_interactive);

fn deinitTranscriptText(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const text: *text_mod.Text = @ptrCast(@alignCast(ctx));
    text.deinit();
    allocator.destroy(text);
}

const MouseCapture = transcript_mouse.MouseCapture;
const AgentSession = coding_agent_mod.AgentSession;
const SessionEvent = coding_agent_mod.session_event.SessionEvent;
const RuntimeHost = coding_agent_mod.RuntimeHost;
const SettingsAction = enum {
    open_thinking,
    toggle_hide_thinking,
};

const IdleRequestDispatch = idle_request.Options;
const auth_storage_mod = @import("../coding_agent/auth/storage.zig");
const oauth_mod = @import("../coding_agent/auth/oauth.zig");
const settings_manager_mod = @import("../coding_agent/settings/manager.zig");
const ai_protocol = @import("../ai/protocol.zig");
const ai_resolve = @import("../coding_agent/resolve.zig");

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

const ClipboardImageReader = *const fn (allocator: std.mem.Allocator) ?[]u8;

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

/// Composition root: main-thread TUI + agent-thread runtime queues.
pub const Interactive = struct {
    /// TUI-thread allocator; do not free mailbox payloads with it.
    allocator: std.mem.Allocator,
    /// Cross-thread mailbox allocator; producer/consumer frees must match.
    msg_allocator: std.mem.Allocator,
    io: std.Io,
    tui: TUI,
    theme_storage: theme_mod.Theme,
    theme: *const theme_mod.Theme = undefined,
    cwd: []const u8 = "",

    editor: editor_mod.Editor,
    active_editor: EditorInterface = undefined,
    active_editor_bound: bool = false,
    status_line: StatusLine,
    pending_image_banner: text_mod.Text,
    extension_ui_state: ExtensionUiState,
    extension_toast_overlay: ?tui_mod.OverlayHandle = null,
    extension_overlay_handle: ?tui_mod.OverlayHandle = null,
    greeter: greeter_mod.Greeter,
    footer: footer_mod.Footer,
    transcript: Transcript,
    conversation_projection: conversation_projection_mod.ProjectionState,
    resolver: ToolRendererResolver,
    status_data: StatusData,
    /// Agent-written, TUI-freed; allocate with msg_allocator.
    last_published_status_snapshot: ?PublishedStatusSnapshot = null,

    last_conversation_publish_ns: u64 = 0,
    conversation_publish_dirty: bool = false,
    /// Agent-thread dedupe only; TUI path is version-filtered downstream.
    last_published_queued_version: u64 = 0,
    runtime_host: RuntimeHost,
    loader_active: bool = false,
    built_in_working_message: []const u8 = "Working…",
    compaction_loader_active: bool = false,
    compaction_loader_reason: coding_agent_mod.session_event.CompactionReason = .manual,
    retry_active: bool = false,
    retry_waiting: bool = false,
    retry_attempt: u32 = 0,
    retry_max_attempts: u32 = 0,
    retry_delay_ms: u64 = 0,

    pending_images: std.ArrayListUnmanaged(PendingImageAttachment) = .empty,
    clipboard_image_reader: ClipboardImageReader = clipboard_mod.readImage,

    command_registry: CommandRegistry,
    autocomplete_provider: CombinedAutocompleteProvider = undefined,
    autocomplete_provider_bound: bool = false,
    hotkeys_overlay: hotkeys_overlay_mod.HotkeysOverlay,
    logs_overlay: ScrollTextOverlay,
    extension_keybindings: std.ArrayListUnmanaged(ui_event_mod.ExtensionKeybindingEntry) = .empty,
    extension_command_actions: extension_runner_mod.ExtensionCommandActions = undefined,
    extension_deferred_user_prompts: std.ArrayListUnmanaged([]u8) = .empty,

    resume_picker_flow: ?ResumePickerFlow = null,
    resume_picker_generation: u64 = 0,
    session_index_worker: session_index_worker_mod.SessionIndexWorker,
    ai_complete_worker: ?ai_complete_worker_mod.AiCompleteWorker = null,
    system_worker: ?system_worker_mod.SystemWorker = null,
    terminal_system_queue: TerminalSystemQueue,

    auth_storage: *auth_storage_mod.AuthStorage,
    settings_manager: *settings_manager_mod.SettingsManager,
    /// TUI-owned snapshot; never read agent registry from the TUI thread.
    model_catalog: []ai_protocol.Model = &.{},
    model_picker_flow: ?ModelPickerFlow = null,
    settings_picker: SimplePickerFlow = .{},
    settings_picker_items: [16]SelectItem = undefined,
    settings_picker_actions: [16]SettingsAction = undefined,
    settings_picker_count: usize = 0,
    thinking_picker: SimplePickerFlow = .{},
    thinking_picker_items: [8]SelectItem = undefined,
    thinking_picker_levels: [8]agent_protocol.ThinkingLevel = undefined,
    thinking_picker_count: usize = 0,

    login_picker: SimplePickerFlow = .{},
    login_picker_items: [8]SelectItem = undefined,
    login_picker_entries: [8]oauth_mod.ProviderListEntry = undefined,
    login_picker_count: usize = 0,
    login_thread: ?std.Thread = null,
    login_cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    snapshot_event_queue: UiSnapshotQueue,
    lifecycle_event_queue: UiLifecycleQueue,
    /// TUI → agent owner inbox; close before joining agent thread.
    request_queue: RequestQueue,
    job_manager: job_manager_mod.JobManager,
    agent_event_token: ?RuntimeHost.AgentEventSubscriptionToken = null,
    session_event_token: ?RuntimeHost.EventSubscriptionToken = null,
    agent_thread: ?std.Thread = null,
    running: bool = true,
    is_streaming: bool = false,
    request_in_flight: bool = false,
    startup_action: StartupAction = .none,
    last_ctrl_c_ns: i128 = 0,
    memory_log_enabled: bool = false,
    last_memory_log_ns: i128 = 0,
    snapshot_coalesced_dropped: usize = 0,
    tool_output_expanded: bool = false,
    hide_thinking_block: bool = false,
    greeter_dismissed: bool = false,
    /// Buffers split terminal protocols; ESC timeout drives Alt vs Escape.
    input: input_buffer_mod.InputBuffer,
    /// Kitty query deadline; null after negotiation settles.
    kitty_deadline_ns: ?i128 = null,
    mouse_capture: MouseCapture = .none,

    pub fn init(
        allocator: std.mem.Allocator,
        msg_allocator: std.mem.Allocator,
        runtime_host: RuntimeHost,
        resolver: ToolRendererResolver,
        cwd: []const u8,
        io: std.Io,
        auth_storage: *auth_storage_mod.AuthStorage,
        settings_manager: *settings_manager_mod.SettingsManager,
    ) !Interactive {
        const tui = try TUI.init(allocator);
        var self: Interactive = .{
            .allocator = allocator,
            .msg_allocator = msg_allocator,
            .io = io,
            .tui = tui,
            .theme_storage = undefined,
            .theme = undefined,
            .cwd = cwd,
            .editor = editor_mod.Editor.init(allocator, tui.terminal.capabilities.width_method),
            .status_line = StatusLine.init(allocator),
            .pending_image_banner = text_mod.Text.init(allocator, tui.terminal.capabilities.width_method),
            .extension_ui_state = ExtensionUiState.init(allocator),
            .greeter = .{ .version = app_meta.version },
            .footer = .{},
            .hotkeys_overlay = .{},
            .logs_overlay = ScrollTextOverlay.init(allocator, themes_builtin.dark(), tui.terminal.capabilities.width_method),
            .transcript = Transcript.init(allocator),
            .conversation_projection = conversation_projection_mod.ProjectionState.init(msg_allocator),
            .resolver = resolver,
            .status_data = StatusData.init(allocator),
            .runtime_host = runtime_host,
            .command_registry = CommandRegistry.init(allocator),
            .input = input_buffer_mod.InputBuffer.init(allocator),
            .snapshot_event_queue = try UiSnapshotQueue.init(msg_allocator),
            .lifecycle_event_queue = try UiLifecycleQueue.init(msg_allocator),
            .request_queue = try RequestQueue.init(msg_allocator),
            .terminal_system_queue = try TerminalSystemQueue.init(msg_allocator),
            .job_manager = undefined,
            .session_index_worker = try session_index_worker_mod.SessionIndexWorker.init(msg_allocator),
            .auth_storage = auth_storage,
            .settings_manager = settings_manager,
            .model_catalog = &.{},
            .memory_log_enabled = memory_telemetry.enabledFromEnv(),
        };
        self.job_manager = try job_manager_mod.JobManager.init(msg_allocator, io, &self.request_queue, null);
        self.ai_complete_worker = try ai_complete_worker_mod.AiCompleteWorker.init(msg_allocator);
        self.system_worker = try system_worker_mod.SystemWorker.init(msg_allocator, io);
        self.logs_overlay.setTheme(self.theme);
        self.pending_image_banner.setPadding(1, 0);
        self.editor.setCwd(cwd);
        self.hide_thinking_block = settings_manager.getHideThinkingBlock();
        self.applyTranscriptHideThinkingBlock();
        return self;
    }

    pub fn setStartupAction(self: *Interactive, startup_action: StartupAction) void {
        self.startup_action = startup_action;
    }

    pub fn deinit(self: *Interactive) void {
        if (self.login_thread != null) {
            self.login_cancelled.store(true, .release);
            if (self.login_thread) |t| t.join();
            self.login_thread = null;
        }
        self.session_index_worker.stop();
        if (self.ai_complete_worker) |*worker| worker.worker.stop();
        if (self.system_worker) |*worker| worker.worker.stop();
        self.terminal_system_queue.clear();

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
        self.closeModelPickerFlow();
        self.closeResumePickerFlow();
        self.clearLoginPickerEntries();
        self.clearPendingImages();
        self.pending_images.deinit(self.allocator);
        if (self.autocomplete_provider_bound) self.autocomplete_provider.deinit();
        self.clearExtensionKeybindings();
        self.extension_keybindings.deinit(self.allocator);
        for (self.extension_deferred_user_prompts.items) |prompt| self.msg_allocator.free(prompt);
        self.extension_deferred_user_prompts.deinit(self.msg_allocator);
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
        event_flow.logStats("snapshot", self.snapshot_event_queue.stats());
        event_flow.logStats("lifecycle", self.lifecycle_event_queue.stats());
        event_flow.logStats("request", self.request_queue.stats());
        event_flow.logStats("session_index", self.session_index_worker.stats());
        self.session_index_worker.deinit();
        if (self.ai_complete_worker) |*worker| worker.deinit();
        self.ai_complete_worker = null;
        if (self.system_worker) |*worker| worker.deinit();
        self.system_worker = null;
        self.terminal_system_queue.deinit();
        self.job_manager.deinit();
        self.snapshot_event_queue.deinit();
        self.lifecycle_event_queue.deinit();
        self.request_queue.deinit();
        self.conversation_projection.deinit();
        self.transcript.deinit();
        self.extension_ui_state.deinit();
        self.logs_overlay.deinit();
        self.pending_image_banner.deinit();
        self.status_line.deinit();
        self.editor.deinit();
        self.tui.deinit();
    }

    fn startAgentThread(self: *Interactive) !void {
        if (self.agent_thread != null) return;
        self.agent_thread = try std.Thread.spawn(.{}, runtime_loop.agentThread, .{self});
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

    /// Main thread owns terminal state and all rendering.
    pub fn run(self: *Interactive) !void {
        try run_setup.prepareTerminal(self);
        run_setup.bindEditor(self);
        run_setup.bindRuntimeEvents(self);

        self.detectGitBranch();
        try self.startAgentThread();
        try self.startSessionIndexWorker();
        if (self.ai_complete_worker) |*worker| {
            worker.setResultSink(.{ .ptr = @ptrCast(self), .submit = &runtime_loop.submitExtensionAsyncResult, .submit_event = &runtime_loop.submitExtensionAiCompleteEvent });
            try worker.start();
        }
        if (self.system_worker) |*worker| {
            worker.setResultSink(.{ .ptr = @ptrCast(self), .submit = &runtime_loop.submitExtensionAsyncResult });
            try worker.start();
        }

        self.bootstrapStatusSnapshot();

        run_setup.bindAutocomplete(self);
        run_setup.mountInitialTree(self);

        self.job_manager.setFrameSink(.{ .ptr = @ptrCast(self), .submit = &publishJobUiFrame });

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

            if (self.processPendingTerminalSystem()) continue;

            if (input_ready and self.processTerminalInput()) continue;

            self.input.checkTimeout(&terminal_input_flow.onSequence, @ptrCast(self));
            self.finishKittyNegotiationIfDue();
            if (self.tui.checkResize()) {
                self.cancelTranscriptSelection();
            }

            const now_ns = @as(i128, @intCast(std.Io.Timestamp.now(std.Options.debug_io, .awake).toNanoseconds()));
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
        startup_flow.performStartupAction(self);
    }

    fn bootstrapStatusSnapshot(self: *Interactive) void {
        startup_flow.bootstrapStatusSnapshot(self);
    }

    pub fn enqueueTerminalSystem(self: *Interactive, id: extension_runner_mod.AsyncOpId, request: extension_runner_mod.SystemRequest) !void {
        const cloned = try request.clone(self.msg_allocator);
        switch (self.terminal_system_queue.trySend(.{ .id = id, .system = cloned })) {
            .ok => {},
            .full, .closed, .oom => |rejected| {
                var failed = rejected;
                failed.deinit(self.msg_allocator);
                return error.TerminalSystemQueueUnavailable;
            },
            .dropped => unreachable,
        }
    }

    fn processPendingTerminalSystem(self: *Interactive) bool {
        var buf: [1]TerminalSystemRequest = undefined;
        const n = self.terminal_system_queue.drainInto(&buf);
        if (n == 0) return false;
        var request = buf[0];
        defer request.deinit(self.msg_allocator);

        const result = self.runTerminalSystem(request.system);
        if (!runtime_loop.submitExtensionAsyncResult(@ptrCast(self), request.id, .{ .system = result })) {
            var failed = result;
            failed.deinit(self.msg_allocator);
        }
        self.tui.dirty = true;
        return true;
    }

    fn runTerminalSystem(self: *Interactive, request: extension_runner_mod.SystemRequest) extension_runner_mod.SystemResult {
        const env_pairs = self.msg_allocator.alloc(system_command_mod.EnvPair, request.env.len) catch {
            return .{ .err = .{ .message = self.msg_allocator.dupe(u8, "failed to allocate env") catch &.{} } };
        };
        defer self.msg_allocator.free(env_pairs);
        for (request.env, 0..) |pair, i| env_pairs[i] = .{ .key = pair.key, .value = pair.value };

        run_setup.suspendTerminalForExternalProcess(self);
        defer run_setup.resumeTerminalAfterExternalProcess(self) catch {};

        return system_command_mod.run(self.msg_allocator, self.io, .{
            .argv = request.argv,
            .cwd = request.cwd,
            .env = env_pairs,
            .clear_env = request.clear_env,
            .text = request.text,
            .stdio = .terminal,
        });
    }

    pub fn openPromptInExternalEditor(self: *Interactive) void {
        var result = external_editor_flow.editText(self, self.editor.getExpandedText(), .{ .cwd = self.cwd, .suffix = ".md" });
        defer result.deinit(self.msg_allocator);
        switch (result) {
            .submitted => |text| {
                self.editor.setText(text);
                self.refreshHeaderVisibility();
            },
            .cancelled => {},
            .err => |msg| self.status_line.setPrimary(msg, self.theme.fg(.@"error")),
        }
        self.tui.dirty = true;
    }

    fn drainUiEvents(self: *Interactive) void {
        event_flow.drain(self);
        self.maybeLogMemory("drain");
    }

    fn maybeLogMemory(self: *Interactive, label: []const u8) void {
        if (!self.memory_log_enabled) return;
        const now_ns = @as(i128, @intCast(std.Io.Timestamp.now(self.io, .awake).toNanoseconds()));
        if (self.last_memory_log_ns != 0 and now_ns - self.last_memory_log_ns < memory_telemetry.log_interval_ns) return;
        self.last_memory_log_ns = now_ns;
        memory_telemetry.log(self, label);
    }

    fn processTerminalInput(self: *Interactive) bool {
        return terminal_input_flow.process(self);
    }

    fn finishKittyNegotiationIfDue(self: *Interactive) void {
        terminal_input_flow.finishKittyNegotiationIfDue(self);
    }

    pub fn showAgentRequestQueueFull(self: *Interactive) void {
        self.status_line.setPrimary("agent request queue full; try again", self.theme.fg(.@"error"));
        self.tui.dirty = true;
    }

    fn publishUiEvent(self: *Interactive, event: UiEvent) bool {
        return event_flow.publish(self, event);
    }

    pub fn publishSnapshotUiEvent(self: *Interactive, event: UiEvent) bool {
        return event_flow.publishSnapshot(self, event);
    }

    pub fn publishLifecycleUiEvent(self: *Interactive, event: UiEvent) bool {
        return event_flow.publishLifecycle(self, event);
    }

    fn publishJobUiFrame(ptr: *anyopaque, frame: extension_ui.UiFrame) bool {
        const self: *Interactive = @ptrCast(@alignCast(ptr));
        const updates = self.msg_allocator.alloc(extension_ui.UiFrame, 1) catch {
            var failed = frame;
            failed.deinit(self.msg_allocator);
            return false;
        };
        updates[0] = frame;
        return self.publishLifecycleUiEvent(.{ .extension_ui_framed = .{ .updates = updates } });
    }

    pub fn handleKey(self: *Interactive, key: Key) void {
        key_flow_mod.handle(self, key);
    }

    fn handleScroll(self: *Interactive, key: Key) bool {
        return key_flow_mod.handleScroll(self, key);
    }

    pub fn handleMouse(self: *Interactive, event: keys_mod.MouseEvent) void {
        transcript_mouse.handle(self, event);
    }

    pub fn handleUiEvent(self: *Interactive, ev: *UiEvent) void {
        ui_event_handler_mod.handle(self, ev);
    }

    pub fn applyStatusSnapshot(self: *Interactive, snapshot: @FieldType(UiEvent, "status_snapshot")) void {
        self.status_data.setModelProvider(snapshot.model_provider);
        self.status_data.setModelId(snapshot.model_id);
        self.status_data.setThinkingLevel(snapshot.thinking_level);
        self.status_data.context_tokens = snapshot.context_tokens;
        self.status_data.context_window = snapshot.context_window;
    }

    pub fn applyVisibleModelsSnapshot(self: *Interactive, models: []ai_protocol.Model) void {
        self.closeModelPickerFlow();
        coding_agent_mod.model_registry.deinitOwnedModels(self.msg_allocator, self.model_catalog);
        self.model_catalog = models;
    }

    pub fn applyResumeSessionsLoaded(self: *Interactive, generation: u64, sessions: []const session_store_mod.SessionInfo) void {
        session_flow.applyLoaded(self, generation, sessions);
    }

    pub fn applyResumeSessionsFailed(self: *Interactive, generation: u64, message: []const u8) void {
        session_flow.applyFailed(self, generation, message);
    }

    pub fn applyTranscriptHideThinkingBlock(self: *Interactive) void {
        self.transcript.hide_thinking_block = self.hide_thinking_block;
        for (self.transcript.items.items, 0..) |_, idx| {
            const assistant = self.transcript.assistantMessageAt(idx) orelse continue;
            assistant.setHideThinkingBlock(self.hide_thinking_block) catch continue;
            assistant.setHiddenThinkingLabel(self.currentHiddenThinkingLabel()) catch continue;
            self.transcript.itemMutatedAt(idx);
        }
    }

    pub fn currentHiddenThinkingLabel(_: *const Interactive) []const u8 {
        return "Thinking...";
    }

    pub fn cancelTranscriptSelection(self: *Interactive) void {
        transcript_mouse.cancelSelection(self);
    }

    pub fn composerHasPendingInput(self: *Interactive) bool {
        return composer_flow.hasPendingInput(self);
    }

    pub fn clearComposerDraft(self: *Interactive) void {
        composer_flow.clearDraft(self);
    }

    fn clearPendingImages(self: *Interactive) void {
        composer_flow.clearPendingImages(self);
    }

    pub fn refreshPendingImageBanner(self: *Interactive) void {
        composer_flow.refreshPendingImageBanner(self);
    }

    pub fn handlePasteImageShortcut(self: *Interactive) void {
        composer_flow.handlePasteImageShortcut(self);
    }

    pub fn outputHeight(self: *Interactive) u32 {
        const h = self.tui.height();
        const w = self.tui.width();
        const max_h = @max(3, h * 30 / 100);
        self.active_editor.setMaxVisibleLines(max_h);

        var fixed_total: u32 = 0;
        for (self.tui.root.children.items, 0..) |child, i| {
            if (self.tui.root.isFlexChild(child, i)) continue;
            fixed_total += self.tui.root.childDesiredHeight(child, w);
        }
        return if (h > fixed_total) h - fixed_total else 0;
    }

    pub fn refreshHeaderVisibility(self: *Interactive) void {
        if (self.composerHasPendingInput() and !self.greeter_dismissed) {
            self.greeter_dismissed = true;
        }
        self.tui.root.setVisible(self.greeter.component(), !self.greeter_dismissed);
    }

    pub fn showLoader(self: *Interactive, message: []const u8) void {
        status_flow.showLoader(self, message);
    }

    pub fn showCompactionLoader(self: *Interactive, reason: coding_agent_mod.session_event.CompactionReason) void {
        status_flow.showCompactionLoader(self, reason);
    }

    pub fn finishCompactionLoader(self: *Interactive) void {
        status_flow.finishCompactionLoader(self);
    }

    pub fn hideLoader(self: *Interactive) void {
        status_flow.hideLoader(self);
    }

    pub fn refreshBuiltInStatus(self: *Interactive) void {
        status_flow.refreshBuiltInStatus(self);
    }

    fn detectGitBranch(self: *Interactive) void {
        var result = runtime_process.run(self.allocator, self.io, .{
            .argv = &.{ "git", "rev-parse", "--abbrev-ref", "HEAD" },
            .max_stdout_bytes = 256,
            .capture_stderr = false,
        });
        defer result.deinit(self.allocator);

        const completed = switch (result) {
            .completed => |completed| completed,
            .timeout, .err => return,
        };
        switch (completed.term) {
            .exited => |code| if (code != 0) return,
            else => return,
        }

        const branch = std.mem.trimEnd(u8, completed.stdout, " \t\n\r");
        if (branch.len > 0) self.active_editor.setGitBranch(branch);
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
        const now_ns = @as(i128, @intCast(std.Io.Timestamp.now(std.Options.debug_io, .awake).toNanoseconds()));
        const timeout_ms: i32 = if (self.nextLoopDeadlineNs(now_ns)) |deadline|
            if (deadline <= now_ns) 0 else @intCast(@divFloor(deadline - now_ns + 999_999, 1_000_000))
        else
            idle_wait_timeout_ms;

        var pfds = [4]posix.pollfd{
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
            .{
                .fd = self.terminal_system_queue.wakeReadFd().?,
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
        const w = self.tui.width();
        const h = self.tui.height();

        if (h < 3 or w < 10) {
            const region = self.tui.renderer.begin();
            _ = region.writeStr(0, 0, "terminal too small", self.theme.fg(.@"error"), Color.default, .{});
            self.tui.renderer.end() catch {};
            return;
        }

        const max_h = @max(3, h * 30 / 100);
        self.active_editor.setMaxVisibleLines(max_h);

        if (self.tui.render()) |cs| {
            self.tui.terminal.showCursor();
            self.tui.terminal.setCursorPos(cs.x, cs.y);
        } else {
            self.tui.terminal.hideCursor();
        }
    }

    pub fn restoreQueuedInputsToEditor(self: *Interactive) void {
        composer_flow.restoreQueuedInputsToEditor(self);
    }

    pub fn submitUserContent(self: *Interactive, content: ai_protocol.UserMessage.UserMessageContent) bool {
        return composer_flow.submitUserContent(self, content);
    }

    pub fn handleFollowUpShortcut(self: *Interactive) void {
        composer_flow.handleFollowUpShortcut(self);
    }

    pub fn dispatchSlashCommand(self: *Interactive, text: []const u8) bool {
        const parsed = slash_command_mod.parse(text) orelse return false;
        const name = parsed.name;
        const args = parsed.args;

        const cmd = self.command_registry.findCommand(name) orelse return false;

        self.active_editor.clear();
        self.refreshHeaderVisibility();
        self.tui.dirty = true;

        if (cmd.source == .builtin) {
            if (self.dispatchInteractiveBuiltinCommand(name, args)) return true;
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

    fn dispatchInteractiveBuiltinCommand(self: *Interactive, name: []const u8, args: []const u8) bool {
        const builtin = slash_command_mod.builtinInteractiveCommand(name) orelse return false;
        switch (builtin) {
            .quit => {
                self.running = false;
            },
            .clear => {
                self.transcript.clearAll();
                self.conversation_projection.clear();
                self.status_line.clearPrimary();
                self.tui.dirty = true;
            },
            .new => _ = self.dispatchIdleRequest(.{ .new_session = {} }, .{
                .busy_message = "cannot start a new session while agent is running",
                .loader_message = "Starting new session...",
                .spawn_failed_message = "failed to queue new session",
            }),
            .compact => {
                const instructions: ?[]const u8 = if (args.len > 0)
                    self.msg_allocator.dupe(u8, args) catch null
                else
                    null;
                _ = self.dispatchIdleRequest(.{ .compact = .{ .custom_instructions = instructions } }, .{
                    .busy_message = "cannot compact while agent is running",
                    .loader_message = "Compacting session...",
                    .spawn_failed_message = "failed to queue compaction",
                });
            },
            .@"resume" => self.showSessionPicker(true),
            .fork => {
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
            },
            .model => if (args.len > 0) self.switchModelDirect(args) else self.showModelPicker(),
            .login => if (args.len > 0) self.startLogin(args) else self.showLoginPicker(),
            .settings => self.showSettingsPicker(),
            .hotkeys => self.showHotkeysOverlay(),
            .memory => self.showMemoryTelemetry(),
            .logs => self.showLogs(args),
        }
        return true;
    }

    pub fn bottomSheetOptions(self: *Interactive) overlay_mod.OverlayOptions {
        return overlay_flow.bottomSheetOptions(self);
    }

    fn centerDialogOptions(self: *Interactive) overlay_mod.OverlayOptions {
        return overlay_flow.centerDialogOptions(self);
    }

    fn showHotkeysOverlay(self: *Interactive) void {
        overlay_flow.showHotkeys(self);
    }

    fn showLogs(self: *Interactive, args: []const u8) void {
        const trimmed = std.mem.trim(u8, args, " \t\r\n");
        if (std.mem.eql(u8, trimmed, "snapshot")) {
            const path = logging.writeSnapshotFileDefault(self.allocator) catch {
                self.status_line.setPrimary("log snapshot failed", self.theme.fg(.@"error"));
                self.tui.dirty = true;
                return;
            };
            defer self.allocator.free(path);
            self.status_line.setPrimary("log snapshot written", self.theme.fg(.accent));
            self.tui.dirty = true;
            return;
        }

        const snapshot = logging.recentSnapshotAlloc(self.allocator) catch {
            self.status_line.setPrimary("logs unavailable", self.theme.fg(.@"error"));
            self.tui.dirty = true;
            return;
        };
        defer self.allocator.free(snapshot);

        var subtitle_buf: [512]u8 = undefined;
        const subtitle = if (logging.currentLogPath()) |path|
            std.fmt.bufPrint(&subtitle_buf, "file: {s}", .{path}) catch "file: <path too long>"
        else
            "file logging disabled; showing recent in-memory logs";

        self.logs_overlay.setTheme(self.theme);
        self.logs_overlay.setContent("Logs", subtitle, snapshot) catch {
            self.status_line.setPrimary("log overlay allocation failed", self.theme.fg(.@"error"));
            self.tui.dirty = true;
            return;
        };
        _ = self.tui.showOverlay(self.logs_overlay.component(), self.bottomSheetOptions());
    }

    fn showMemoryTelemetry(self: *Interactive) void {
        const content = memory_telemetry.format(self.allocator, self) catch {
            self.status_line.setPrimary("memory telemetry unavailable", self.theme.fg(.@"error"));
            self.tui.dirty = true;
            return;
        };
        defer self.allocator.free(content);

        self.addTextTranscriptItem(content, .accent, "memory telemetry added to transcript");
        memory_telemetry.log(self, "slash");
        self.tui.dirty = true;
    }

    fn addTextTranscriptItem(self: *Interactive, content: []const u8, color: theme_mod.FgColor, success_message: []const u8) void {
        var row = self.allocator.create(text_mod.Text) catch {
            self.status_line.setPrimary("transcript allocation failed", self.theme.fg(.@"error"));
            self.tui.dirty = true;
            return;
        };
        row.* = text_mod.Text.init(self.allocator, self.tui.terminal.capabilities.width_method);
        row.fg = self.theme.fg(color);
        row.setContent(content);

        const item: transcript_mod.TranscriptItem = .{
            .renderable = transcript_mod.TranscriptRenderable.init(text_mod.Text, row),
            .deinit_ctx = @ptrCast(row),
            .deinit_fn = deinitTranscriptText,
        };
        if (!self.transcript.addItem(item)) {
            deinitTranscriptText(@ptrCast(row), self.allocator);
            self.status_line.setPrimary("transcript unavailable", self.theme.fg(.@"error"));
        } else {
            self.status_line.setPrimary(success_message, self.theme.fg(.accent));
        }
        self.tui.dirty = true;
    }

    pub fn configureSimplePicker(
        self: *Interactive,
        picker: *SimplePickerFlow,
        title: []const u8,
        max_visible: u32,
        items: []const SelectItem,
        on_select: ?*const fn (selection: PickerSelection, ctx: ?*anyopaque) void,
        on_cancel: ?*const fn (ctx: ?*anyopaque) void,
    ) void {
        overlay_flow.configureSimplePicker(self, picker, title, max_visible, items, on_select, on_cancel);
    }

    pub fn showSimplePickerOverlay(
        self: *Interactive,
        picker: *SimplePickerFlow,
    ) void {
        overlay_flow.showSimplePickerOverlay(self, picker);
    }

    pub fn hideSimplePickerOverlay(self: *Interactive, picker: *SimplePickerFlow) void {
        _ = self;
        overlay_flow.hideSimplePickerOverlay(picker);
    }

    pub fn dispatchIdleRequest(self: *Interactive, req: AgentRequest, options: IdleRequestDispatch) bool {
        return idle_request.dispatch(self, req, options);
    }

    fn closeResumePickerFlow(self: *Interactive) void {
        session_flow.close(self);
    }

    pub fn showSessionPicker(self: *Interactive, restore_session_model: bool) void {
        session_flow.show(self, restore_session_model);
    }

    fn switchModelDirect(self: *Interactive, pattern: []const u8) void {
        model_flow.switchDirect(self, pattern);
    }

    fn closeModelPickerFlow(self: *Interactive) void {
        model_flow.close(self);
    }

    fn showModelPicker(self: *Interactive) void {
        model_flow.show(self);
    }

    fn showSettingsPicker(self: *Interactive) void {
        settings_flow_mod.showSettings(self, &onSettingsSelected, &onSettingsPickerCancel);
    }

    fn onSettingsSelected(selection: PickerSelection, ctx: ?*anyopaque) void {
        const self: *Interactive = @ptrCast(@alignCast(ctx));
        settings_flow_mod.settingsSelected(self, selection, &onThinkingLevelSelected, &onThinkingLevelPickerCancel);
    }

    fn onSettingsPickerCancel(ctx: ?*anyopaque) void {
        const self: *Interactive = @ptrCast(@alignCast(ctx));
        self.hideSimplePickerOverlay(&self.settings_picker);
    }

    fn showThinkingLevelPicker(self: *Interactive) void {
        settings_flow_mod.showThinkingLevel(self, &onThinkingLevelSelected, &onThinkingLevelPickerCancel);
    }

    fn onThinkingLevelSelected(selection: PickerSelection, ctx: ?*anyopaque) void {
        const self: *Interactive = @ptrCast(@alignCast(ctx));
        settings_flow_mod.thinkingLevelSelected(self, selection);
    }

    fn onThinkingLevelPickerCancel(ctx: ?*anyopaque) void {
        const self: *Interactive = @ptrCast(@alignCast(ctx));
        self.hideSimplePickerOverlay(&self.thinking_picker);
    }

    pub fn applyThinkingLevelChange(self: *Interactive, level: agent_protocol.ThinkingLevel) void {
        _ = self.dispatchIdleRequest(.{ .set_thinking_level = .{ .level = level } }, .{
            .busy_message = "cannot change thinking level while agent is running",
            .loader_message = "Updating thinking level...",
            .spawn_failed_message = "failed to queue thinking-level change",
        });
    }

    fn clearLoginPickerEntries(self: *Interactive) void {
        login_flow.clearEntries(self);
    }

    fn showLoginPicker(self: *Interactive) void {
        login_flow.showPicker(self);
    }

    fn startLogin(self: *Interactive, provider_id: []const u8) void {
        login_flow.start(self, provider_id);
    }

    fn enqueueAgentShutdown(self: *Interactive) void {
        runtime_loop.enqueueShutdown(self);
    }

    pub fn discardAgentRequests(self: *Interactive, requests: []AgentRequest) void {
        runtime_loop.discardRequests(self, requests);
    }

    pub fn discardQueuedAgentRequests(self: *Interactive) void {
        runtime_loop.discardQueuedRequests(self);
    }

    fn processAgentRequests(self: *Interactive) bool {
        return runtime_loop.processRequests(self);
    }

    /// Publish the current extension command list through the UI event
    /// queue so the TUI thread can rebuild its own registry without reading
    /// or mutating agent-owned runner state directly.
    pub fn publishExtensionCommandsUpdate(self: *Interactive) void {
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
        self.publishExtensionKeybindingsSnapshot();
    }

    pub fn publishExtensionKeybindingsSnapshot(self: *Interactive) void {
        const extension_bindings = blk: {
            const runner = self.runtime_host.currentSession().extensionRunner() orelse break :blk self.msg_allocator.alloc(ui_event_mod.ExtensionKeybindingEntry, 0) catch return;
            var count: usize = 0;
            for (runner.keybinding_registry.items()) |entry| count += entry.keys.len;
            var owned = self.msg_allocator.alloc(ui_event_mod.ExtensionKeybindingEntry, count) catch return;
            var built: usize = 0;
            errdefer {
                for (owned[0..built]) |kb| {
                    self.msg_allocator.free(kb.id);
                    self.msg_allocator.free(kb.description);
                    self.msg_allocator.free(kb.display);
                }
                self.msg_allocator.free(owned);
            }
            for (runner.keybinding_registry.items()) |entry| {
                for (entry.keys, 0..) |key, i| {
                    owned[built] = .{
                        .id = self.msg_allocator.dupe(u8, entry.id) catch return,
                        .description = self.msg_allocator.dupe(u8, entry.description) catch {
                            self.msg_allocator.free(owned[built].id);
                            return;
                        },
                        .key = key,
                        .display = self.msg_allocator.dupe(u8, entry.displays[i]) catch {
                            self.msg_allocator.free(owned[built].id);
                            self.msg_allocator.free(owned[built].description);
                            return;
                        },
                    };
                    built += 1;
                }
            }
            break :blk owned;
        };
        _ = self.publishLifecycleUiEvent(.{ .extension_keybindings_updated = .{ .keybindings = extension_bindings } });
    }

    pub fn publishPendingExtensionUi(self: *Interactive) void {
        extension_ui_flow.publishPending(self);
    }

    pub fn applyExtensionEditorActions(self: *Interactive, actions: []const @import("../coding_agent/extensions/ui.zig").EditorAction) void {
        extension_ui_flow.applyEditorActions(self, actions);
    }

    pub fn applyExtensionRenderUpdates(self: *Interactive, updates: []const @import("../coding_agent/extensions/ui.zig").RenderSpec) void {
        extension_ui_flow.applyRenderUpdates(self, updates);
    }

    pub fn applyExtensionFrameUpdates(self: *Interactive, updates: []const @import("../coding_agent/extensions/ui.zig").UiFrame) void {
        extension_ui_flow.applyFrameUpdates(self, updates);
    }

    pub fn applyExtensionCommandsUpdate(self: *Interactive, commands: []const ui_event_mod.ExtensionCommandEntry) void {
        extension_ui_flow.applyCommandsUpdate(self, commands);
    }

    pub fn applyExtensionKeybindingsUpdate(self: *Interactive, entries: []const ui_event_mod.ExtensionKeybindingEntry) void {
        self.clearExtensionKeybindings();
        for (entries) |kb| {
            const id = self.allocator.dupe(u8, kb.id) catch continue;
            const description = self.allocator.dupe(u8, kb.description) catch {
                self.allocator.free(id);
                continue;
            };
            const display = self.allocator.dupe(u8, kb.display) catch {
                self.allocator.free(id);
                self.allocator.free(description);
                continue;
            };
            self.extension_keybindings.append(self.allocator, .{
                .id = id,
                .description = description,
                .key = kb.key,
                .display = display,
            }) catch {
                self.allocator.free(id);
                self.allocator.free(description);
                self.allocator.free(display);
                continue;
            };
        }
    }

    pub fn clearExtensionKeybindings(self: *Interactive) void {
        for (self.extension_keybindings.items) |kb| {
            self.allocator.free(kb.id);
            self.allocator.free(kb.description);
            self.allocator.free(kb.display);
        }
        self.extension_keybindings.clearRetainingCapacity();
    }

    /// Agent-thread handler for `AgentRequest.compact`. The runner emits
    /// `compaction_start`/`compaction_end` events which the TUI consumes
    /// via `sessionEventCallback`; no direct mutation of agent-owned state
    /// happens here. Failures still flow through `compaction_end`.
    pub fn handleManualCompactRequest(self: *Interactive, custom_instructions: ?[]const u8) void {
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

    pub fn handleNewSession(self: *Interactive) void {
        session_requests_mod.handleNewSession(self);
    }

    pub fn handleForkSession(self: *Interactive, entry_id: []const u8) void {
        session_requests_mod.handleForkSession(self, entry_id);
    }

    /// Agent-thread handler for `AgentRequest.resume_session`.
    /// Loads the session via `openSession` (agent_arena allocated),
    /// binds the authoritative session state on the agent thread, and
    /// then publishes semantic snapshots back to the TUI.
    ///
    /// Transcript rebuild stays on the TUI thread — this handler
    /// does NOT touch `self.transcript`. That's .15's whole point.
    pub fn handleResumeSession(self: *Interactive, path: []const u8, restore_session_model: bool) void {
        session_requests_mod.handleResumeSession(self, path, restore_session_model);
    }

    pub fn publishConversationState(self: *Interactive) bool {
        return conversation_publish.publishConversationState(self);
    }

    pub fn publishQueuedSnapshot(self: *Interactive) bool {
        return conversation_publish.publishQueuedSnapshot(self);
    }

    pub fn publishQueuedSnapshotIfChanged(self: *Interactive) void {
        conversation_publish.publishQueuedSnapshotIfChanged(self);
    }

    /// Agent-thread handler for `AgentRequest.set_model` (zi-wub.16).
    /// Delegates the canonical validation + mutation path to
    /// `AgentSession.trySetModel`, then translates the typed outcome
    /// into a TUI-owned event payload.
    pub fn handleSetModel(self: *Interactive, m: ai_protocol.Model) void {
        model_requests_mod.handleSetModel(self, m);
    }

    pub fn handleSetModelPattern(self: *Interactive, pattern: []const u8) void {
        model_requests_mod.handleSetModelPattern(self, pattern);
    }

    pub fn publishThemeSnapshot(self: *Interactive) void {
        theme_flow.publishSnapshot(self);
    }

    pub fn applyTheme(self: *Interactive, theme: theme_mod.Theme) void {
        theme_flow.apply(self, theme);
    }

    pub fn publishVisibleModelsSnapshot(self: *Interactive) void {
        model_requests_mod.publishVisibleModelsSnapshot(self);
    }

    pub fn publishStatusSnapshot(self: *Interactive) void {
        model_requests_mod.publishStatusSnapshot(self);
    }

    pub fn shouldSkipStatusSnapshotPublish(
        self: *const Interactive,
        snapshot: AgentSession.StatusSnapshot,
    ) bool {
        const last = self.last_published_status_snapshot orelse return false;
        return last.eql(snapshot);
    }

    pub fn rememberPublishedStatusSnapshot(
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
        if (!status_snapshot_mod.shouldPublishStatusSnapshotForAgentEvent(event)) return;
        self.publishStatusSnapshot();
    }

    pub fn handleSetThinkingLevel(self: *Interactive, level: agent_protocol.ThinkingLevel) void {
        model_requests_mod.handleSetThinkingLevel(self, level);
    }

    fn publishConversationStateForAgentEvent(self: *Interactive, event: AgentEvent) void {
        conversation_publish.publishForAgentEvent(self, event);
    }

    /// Raw agent event callback — runs on the AGENT THREAD.
    pub fn agentEventCallback(event: AgentEvent, ctx: ?*anyopaque) void {
        const self: *Interactive = @ptrCast(@alignCast(ctx));
        self.publishConversationStateForAgentEvent(event);
        if (convertAgentUiEvent(event, self.msg_allocator)) |ui_event| {
            _ = self.publishUiEvent(ui_event);
        }
        self.publishStatusSnapshotForAgentEvent(event);
        self.publishPendingExtensionUi();
    }

    /// Session event callback — runs on the AGENT THREAD.
    pub fn sessionEventCallback(event: SessionEvent, ctx: ?*anyopaque) void {
        const self: *Interactive = @ptrCast(@alignCast(ctx));
        session_events_mod.handle(self, event);
    }
};
