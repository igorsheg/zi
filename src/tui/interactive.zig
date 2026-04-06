const std = @import("std");
const posix = std.posix;
const cell_mod = @import("cell.zig");
const buffer_mod = @import("buffer.zig");
const renderer_mod = @import("renderer.zig");
const terminal_mod = @import("terminal.zig");
const keys_mod = @import("keys.zig");
const component_mod = @import("component.zig");
const text_mod = @import("components/text.zig");
const header_mod = @import("components/header.zig");
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

const agent_mod = @import("../agent/root.zig");
const coding_agent_mod = @import("../coding_agent.zig");
const AgentEvent = agent_mod.protocol.AgentEvent;
const AgentToolResult = agent_mod.protocol.AgentToolResult;
const CodingAgent = coding_agent_mod.CodingAgent;
const json_util = @import("../ai/json_util.zig");
const auth_storage_mod = @import("../auth/storage.zig");
const oauth_mod = @import("../auth/oauth.zig");
const ai_models = @import("../ai/models.zig");
const ai_protocol = @import("../ai/protocol.zig");

const Color = cell_mod.Color;
const Region = buffer_mod.Region;
const Terminal = terminal_mod.Terminal;
const Renderer = renderer_mod.Renderer;
const Key = keys_mod.Key;
const Component = component_mod.Component;
const CursorState = component_mod.CursorState;
const UiEvent = ui_event_mod.UiEvent;
const Transcript = transcript_mod.Transcript;
const ToolRendererRegistry = tool_display_mod.ToolRendererRegistry;
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
                std.mem.copyForwards(T, self.items.items[0..], self.items.items[count..]);
            }
            self.items.items.len -= count;
            return count;
        }
    };
}

/// Interactive mode — wires CodingAgent (blocking on its thread)
/// to the TUI (main thread) via a thread-safe event queue.
///
/// Uses UiEvent (deep-copied) instead of raw AgentEvent to ensure
/// no borrowed pointers cross the thread boundary.
///
/// Composes TUI (reusable rendering/focus/overlay infrastructure)
/// with domain-specific state (editor, transcript, agent, containers).
pub const Interactive = struct {
    allocator: std.mem.Allocator,
    tui: TUI,
    theme: *const theme_mod.Theme = &theme_mod.Theme.dark,

    // ── Owned components ──────────────────────────────────────────
    editor: editor_mod.Editor,
    /// Active editor interface — routes paste/newline/ctrl+d/clear.
    /// Defaults to the built-in editor. Extensions can swap via setEditor().
    /// Initialized in init() after self.editor is set up.
    active_editor: EditorInterface = undefined,
    status_text: text_mod.Text,
    header: header_mod.Header,
    footer: footer_mod.Footer,
    transcript: Transcript,
    registry: ToolRendererRegistry,
    status_data: StatusData,
    loader: Loader = .{},
    loader_active: bool = false,

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
    model_picker: ListPicker = undefined,
    model_picker_items: [256]SelectItem = undefined,
    model_picker_search_texts: [256][]const u8 = undefined,
    model_picker_models: [256]ai_protocol.Model = undefined,
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
    ca: *CodingAgent,
    agent_thread: ?std.Thread = null,
    running: bool = true,
    is_streaming: bool = false,
    last_ctrl_c_ns: i128 = 0,
    tool_output_expanded: bool = false,
    /// Input sequence buffer — handles split escape sequences, paste, kitty negotiation.
    input: input_buffer_mod.InputBuffer,
    /// Kitty protocol negotiation: deadline (ns timestamp) for query response.
    /// null = negotiation complete.
    kitty_deadline_ns: ?i128 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        ca: *CodingAgent,
        registry: ToolRendererRegistry,
        cwd: []const u8,
        auth_storage: *auth_storage_mod.AuthStorage,
    ) !Interactive {
        const theme = &theme_mod.Theme.dark;

        var self: Interactive = .{
            .allocator = allocator,
            .tui = try TUI.init(allocator),
            .theme = theme,
            .editor = editor_mod.Editor.init(allocator),
            .status_text = text_mod.Text.init(allocator),
            .header = .{ .theme = theme, .version = "0.1.0" },
            .footer = .{ .theme = theme },
            .transcript = Transcript.init(allocator),
            .registry = registry,
            .status_data = StatusData.init(allocator),
            .header_container = container_mod.Container.init(allocator),
            .pending_container = container_mod.Container.init(allocator),
            .status_container = container_mod.Container.init(allocator),
            .widget_above_container = container_mod.Container.init(allocator),
            .editor_container = container_mod.Container.init(allocator),
            .widget_below_container = container_mod.Container.init(allocator),
            .command_registry = CommandRegistry.init(allocator),
            .input = input_buffer_mod.InputBuffer.init(allocator),
            .event_queue = EventQueue(UiEvent).init(allocator),
            .ca = ca,
            .auth_storage = auth_storage,
        };
        self.editor.prompt_fg = theme.fg(.muted);
        self.editor.border_color = theme.fg(.border_muted);
        self.loader.spinner_fg = theme.fg(.accent);
        self.loader.message_fg = theme.fg(.muted);
        self.status_data.model_id = ca.agent.state.model.id;
        self.editor.cwd = cwd;
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
        if (self.agent_thread) |t| t.join();
        // drain and free any remaining events
        var drain_buf: [64]UiEvent = undefined;
        while (true) {
            const count = self.event_queue.drainInto(&drain_buf);
            if (count == 0) break;
            for (drain_buf[0..count]) |*ev| ev.deinit(self.allocator);
        }
        self.freeModelPickerSearchTexts();
        self.command_registry.deinit();
        self.status_data.deinit();
        self.input.deinit();
        self.event_queue.deinit();
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

        // Bind pointers now that self is at its stable address (not a stack copy).
        self.editor.status_data = &self.status_data;
        self.editor.theme = self.theme;

        // Wire autocomplete: registry → provider → editor
        self.slash_provider = SlashCommandProvider.init(&self.command_registry);
        self.editor.setAutocompleteProvider(self.slash_provider.provider());

        self.active_editor = EditorInterface.init(editor_mod.Editor, &self.editor);

        // Populate container slots with their initial children.
        self.header_container.addChild(self.header.component());
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
        self.tui.root.addChild(self.footer.component()); // [7] footer (direct, no wrapper)
        self.tui.root.flex_child_index = 1; // transcript is flex
        self.tui.root.focused_child_index = 5; // editorContainer for cursor y-offset

        self.tui.dirty = true;

        while (self.running) {
            // 1. Drain UI events (owned, thread-safe)
            var event_buf: [64]UiEvent = undefined;
            const count = self.event_queue.drainInto(&event_buf);
            for (event_buf[0..count]) |*ev| {
                self.handleUiEvent(ev);
                ev.deinit(self.allocator);
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

        // scroll: page up/down, shift+up/down
        if (self.handleScroll(key)) return;

        // Route to focused component via TUI
        if (self.tui.handleInput(key)) {
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
            const total = self.transcript.totalHeight(w);
            const max_scroll: u32 = if (total > output_h) total - output_h else 0;
            const current: i64 = @intCast(self.transcript.scroll_offset);
            const new_val = @max(0, @min(current + d, @as(i64, @intCast(max_scroll))));
            self.transcript.scroll_offset = @intCast(new_val);
            self.tui.dirty = true;
            return true;
        }
        return false;
    }

    fn handleMouse(self: *Interactive, event: keys_mod.MouseEvent) void {
        switch (event.button) {
            .scroll_up => {
                const w = self.tui.width();
                const total = self.transcript.totalHeight(w);
                const output_h = self.outputHeight();
                _ = total;
                _ = output_h;
                if (self.transcript.scroll_offset >= 3) {
                    self.transcript.scroll_offset -= 3;
                } else {
                    self.transcript.scroll_offset = 0;
                }
                self.tui.dirty = true;
            },
            .scroll_down => {
                const w = self.tui.width();
                const total = self.transcript.totalHeight(w);
                const output_h = self.outputHeight();
                const max_scroll: u32 = if (total > output_h) total - output_h else 0;
                self.transcript.scroll_offset = @min(self.transcript.scroll_offset + 3, max_scroll);
                self.tui.dirty = true;
            },
            else => {},
        }
    }


    fn handleUiEvent(self: *Interactive, ev: *UiEvent) void {
        switch (ev.*) {
            .text_delta => |d| {
                self.transcript.appendText(d.delta);
                self.transcript.scrollToBottom(self.tui.width(), self.outputHeight());
                self.tui.dirty = true;
            },
            .error_message => |e| {
                self.status_text.setContent(e.message);
                self.status_text.fg = self.theme.fg(.@"error");
                self.tui.dirty = true;
            },
            .message_start_assistant => {
                self.transcript.beginAssistantMessage();
                self.showLoader("thinking...");
                self.tui.dirty = true;
            },
            .message_start_user => {},
            .tool_call_streaming => |t| {
                const renderer = self.registry.get(t.tool_name);
                self.transcript.addToolExecution(t.tool_call_id, t.tool_name, renderer);
                self.transcript.toolSetArgs(t.tool_call_id, t.args);
                self.transcript.toolSetArgsComplete(t.tool_call_id);
                self.transcript.scrollToBottom(self.tui.width(), self.outputHeight());
                self.tui.dirty = true;
            },
            .message_end_assistant => |m| {
                if (m.is_aborted) {
                    self.status_text.setContent(m.error_message orelse "aborted");
                    self.status_text.fg = self.theme.fg(.@"error");
                    self.tui.dirty = true;
                } else if (m.error_message) |msg| {
                    self.status_text.setContent(msg);
                    self.status_text.fg = self.theme.fg(.@"error");
                    self.tui.dirty = true;
                }
            },
            .tool_start => |t| {
                const renderer = self.registry.get(t.tool_name);
                self.transcript.addToolExecution(t.tool_call_id, t.tool_name, renderer);
                self.transcript.toolSetArgs(t.tool_call_id, t.args);
                self.transcript.toolMarkExecutionStarted(t.tool_call_id);
                self.status_text.setContent(t.tool_name);
                if (self.loader_active) self.loader.setMessage(t.tool_name);
                self.status_text.fg = self.theme.fg(.accent);
                self.transcript.scrollToBottom(self.tui.width(), self.outputHeight());
                self.tui.dirty = true;
            },
            .tool_update => |t| {
                self.transcript.toolSetPartialResult(t.tool_call_id, t.result, t.is_error);
                self.transcript.scrollToBottom(self.tui.width(), self.outputHeight());
                self.tui.dirty = true;
            },
            .tool_end => |t| {
                self.transcript.toolSetFinalResult(t.tool_call_id, t.result, t.is_error);
                self.transcript.scrollToBottom(self.tui.width(), self.outputHeight());
                self.tui.dirty = true;
            },
            .login_complete => |l| {
                if (self.login_thread) |t| t.join();
                self.login_thread = null;

                if (l.success) {
                    self.status_text.setContent(l.message);
                    self.status_text.fg = self.theme.fg(.success);
                    self.status_data.model_id = self.ca.agent.state.model.id;
                } else {
                    self.status_text.setContent(l.message);
                    self.status_text.fg = self.theme.fg(.@"error");
                }
                self.tui.dirty = true;
            },
            .agent_finished => {
                self.is_streaming = false;
                if (self.agent_thread) |t| t.join();
                self.agent_thread = null;
                self.hideLoader();
                self.status_text.setContent("");
                self.tui.setFocus(self.active_editor.component());
                self.tui.dirty = true;
            },
            .agent_error => {
                self.is_streaming = false;
                if (self.agent_thread) |t| t.join();
                self.agent_thread = null;
                self.hideLoader();
                self.status_text.setContent("error occurred");
                self.status_text.fg = self.theme.fg(.@"error");
                self.tui.setFocus(self.active_editor.component());
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


    fn showLoader(self: *Interactive, message: []const u8) void {
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
        self.status_text.setContent("");
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

        const prompt_copy = self.allocator.dupe(u8, text) catch return;

        self.active_editor.clear();
        self.is_streaming = true;
        self.tui.setFocus(null); // defocus editor during streaming
        self.status_text.setContent("sending...");
        self.status_text.fg = self.theme.fg(.muted);
        self.tui.dirty = true;

        self.agent_thread = std.Thread.spawn(.{}, agentThreadFn, .{ self, prompt_copy }) catch {
            self.is_streaming = false;
            self.tui.setFocus(self.active_editor.component());
            self.status_text.setContent("failed to start agent");
            self.status_text.fg = self.theme.fg(.@"error");
            self.allocator.free(prompt_copy);
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

    fn bottomPanelOptions(self: *Interactive) overlay_mod.OverlayOptions {
        // Reserve space for footer (1 row) + header (1 row)
        const header_h: u32 = 1;
        const footer_h = self.footer.measure(self.tui.width()).preferred_height;
        return .{
            .anchor = .bottom_left,
            .width_percent = 100,
            .max_height_percent = 40,
            .margin_bottom = footer_h,
            .margin_top = header_h,
        };
    }

    // ── Session picker (/resume) ────────────────────────────────

    fn showSessionPicker(self: *Interactive) void {
        // List sessions for current cwd
        const cwd = self.ca.session_store.writer.cwd;
        const effective_cwd = if (cwd.len > 0) cwd else self.editor.cwd;
        const sessions = session_store_mod.listSessions(self.allocator, effective_cwd) catch {
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

        // Load the selected session
        const loaded = coding_agent_mod.openSession(self.allocator, path) catch {
            self.status_text.setContent("failed to load session");
            self.status_text.fg = self.theme.fg(.@"error");
            return;
        };

        // Rewire: replace session store, reload agent messages
        self.ca.session_store = loaded.store;
        self.ca.agent.state.messages = loaded.messages;

        // Rebuild transcript from loaded messages
        self.transcript.clearAll();
        for (loaded.messages) |msg| {
            switch (msg) {
                .user => |u| {
                    switch (u.content) {
                        .text => |t| self.transcript.addUserMessage(t),
                        else => {},
                    }
                },
                .assistant => |a| {
                    self.transcript.beginAssistantMessage();
                    for (a.content) |block| {
                        switch (block) {
                            .text => |tc| self.transcript.appendText(tc.text),
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }

        self.status_text.setContent("session resumed");
        self.status_text.fg = self.theme.fg(.success);
        self.tui.dirty = true;
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
        const m = ai_models.getModelById(pattern) orelse ai_models.findModel(pattern) orelse {
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
        const all = ai_models.getAllModels();
        var count: usize = 0;

        for (all) |m| {
            if (count >= self.model_picker_items.len) break;
            if (m.api != .anthropic_messages) continue;
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

    fn applyModelSwitch(self: *Interactive, m: ai_protocol.Model) void {
        self.ca.agent.state.model = m;
        self.status_data.model_id = m.id;

        const provider_str = json_util.providerToString(m.provider);
        self.ca.session_store.appendModelChange(provider_str, m.id);

        var buf: [80]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Model: {s}", .{m.id}) catch "model switched";
        self.status_text.setContent(msg);
        self.status_text.fg = self.theme.fg(.success);
        self.tui.dirty = true;
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

        const login_ctx = self.allocator.create(LoginContext) catch {
            self.status_text.setContent("failed to start login");
            self.status_text.fg = self.theme.fg(.@"error");
            return;
        };
        login_ctx.* = .{
            .interactive = self,
            .provider = provider,
        };

        self.login_thread = std.Thread.spawn(.{}, loginThreadFn, .{login_ctx}) catch {
            self.allocator.destroy(login_ctx);
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
        self.allocator.destroy(ctx);

        const result = oauth_mod.login(
            self.allocator,
            provider,
            .{
                .on_auth = &onLoginAuth,
                .on_progress = &onLoginProgress,
                .ctx = @ptrCast(self),
            },
            &self.login_cancelled,
        );

        const provider_id = self.allocator.dupe(u8, provider.id) catch return;
        switch (result) {
            .success => |cred| {
                self.auth_storage.set(provider.id, .{ .oauth = cred });
                // auth_storage.set() dupes the credential; free the originals
                self.allocator.free(cred.refresh);
                self.allocator.free(cred.access);
                var extras = cred.extras;
                extras.deinit();

                self.event_queue.push(.{ .login_complete = .{
                    .provider_id = provider_id,
                    .success = true,
                    .message = self.allocator.dupe(u8, "logged in") catch return,
                }});
            },
            .cancelled => {
                self.event_queue.push(.{ .login_complete = .{
                    .provider_id = provider_id,
                    .success = false,
                    .message = self.allocator.dupe(u8, "login cancelled") catch return,
                }});
            },
            .err => |msg| {
                self.event_queue.push(.{ .login_complete = .{
                    .provider_id = provider_id,
                    .success = false,
                    .message = self.allocator.dupe(u8, msg) catch return,
                }});
            },
        }
    }

    fn onLoginAuth(url: []const u8, ctx: ?*anyopaque) void {
        const self: *Interactive = @ptrCast(@alignCast(ctx));

        _ = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = if (@import("builtin").os.tag == .macos)
                &.{ "open", url }
            else
                &.{ "xdg-open", url },
        }) catch {};

        self.status_text.setContent("login: check your browser");
        self.status_text.fg = self.theme.fg(.accent);
        self.tui.dirty = true;
    }

    fn onLoginProgress(msg: []const u8, ctx: ?*anyopaque) void {
        const self: *Interactive = @ptrCast(@alignCast(ctx));
        self.status_text.setContent(msg);
        self.status_text.fg = self.theme.fg(.muted);
        self.tui.dirty = true;
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

    fn agentThreadFn(self: *Interactive, prompt_copy: []const u8) void {
        defer self.allocator.free(prompt_copy);

        const token = self.ca.agent.subscribe(&agentEventCallback, @ptrCast(self));
        defer self.ca.agent.unsubscribe(token);

        self.ca.run(prompt_copy);

        self.event_queue.push(.{ .agent_finished = {} });
    }

    /// Agent event callback — runs on the AGENT THREAD.
    /// Deep-copies event data into a UiEvent before pushing to the queue.
    fn agentEventCallback(event: AgentEvent, ctx: ?*anyopaque) void {
        const self: *Interactive = @ptrCast(@alignCast(ctx));
        const ui_event = convertAgentEvent(event, self.allocator) orelse return;
        self.event_queue.push(ui_event);
    }
};

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
                    return .{ .text_delta = .{ .delta = delta } };
                },
                .@"error" => |e| {
                    if (e.@"error".error_message) |msg| {
                        const owned = allocator.dupe(u8, msg) catch return null;
                        return .{ .error_message = .{ .message = owned } };
                    }
                    return null;
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
