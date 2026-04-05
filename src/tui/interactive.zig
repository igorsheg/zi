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
const ui_event_mod = @import("ui_event.zig");
const transcript_mod = @import("transcript.zig");
const container_mod = @import("container.zig");
const overlay_mod = @import("overlay.zig");
const tool_display_mod = @import("tool_display.zig");
const theme_mod = @import("theme.zig");
const tui_mod = @import("tui.zig");

const agent_mod = @import("../agent/root.zig");
const coding_agent_mod = @import("../coding_agent.zig");
const AgentEvent = agent_mod.protocol.AgentEvent;
const AgentToolResult = agent_mod.protocol.AgentToolResult;
const CodingAgent = coding_agent_mod.CodingAgent;
const json_util = @import("../ai/json_util.zig");

const Color = cell_mod.Color;
const Region = buffer_mod.Region;
const Terminal = terminal_mod.Terminal;
const Renderer = renderer_mod.Renderer;
const Key = keys_mod.Key;
const Component = component_mod.Component;
const CursorState = component_mod.CursorState;
const UiEvent = ui_event_mod.UiEvent;
const Transcript = transcript_mod.Transcript;
const ToolDisplayRegistry = tool_display_mod.ToolDisplayRegistry;
const ToolDisplay = tool_display_mod.ToolDisplay;
const TUI = tui_mod.TUI;

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
    status_text: text_mod.Text,
    header: header_mod.Header,
    footer: footer_mod.Footer,
    transcript: Transcript,
    registry: ToolDisplayRegistry,

    // ── Container slots (pi-mono parity) ──────────────────────────
    header_container: container_mod.Container,
    pending_container: container_mod.Container,
    status_container: container_mod.Container,
    widget_above_container: container_mod.Container,
    editor_container: container_mod.Container,
    widget_below_container: container_mod.Container,

    event_queue: EventQueue(UiEvent),
    ca: *CodingAgent,
    agent_thread: ?std.Thread = null,
    running: bool = true,
    is_streaming: bool = false,
    in_paste: bool = false,
    paste_buf: std.ArrayListUnmanaged(u8) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        ca: *CodingAgent,
        registry: ToolDisplayRegistry,
        cwd: []const u8,
    ) !Interactive {
        const theme = &theme_mod.Theme.dark;

        var self: Interactive = .{
            .allocator = allocator,
            .tui = try TUI.init(allocator),
            .theme = theme,
            .editor = editor_mod.Editor.init(allocator),
            .status_text = text_mod.Text.init(allocator),
            .header = .{ .theme = theme, .version = "0.1.0" },
            .footer = .{ .theme = theme, .cwd = cwd, .model_name = ca.agent.state.model.id },
            .transcript = Transcript.init(allocator),
            .registry = registry,
            .header_container = container_mod.Container.init(allocator),
            .pending_container = container_mod.Container.init(allocator),
            .status_container = container_mod.Container.init(allocator),
            .widget_above_container = container_mod.Container.init(allocator),
            .editor_container = container_mod.Container.init(allocator),
            .widget_below_container = container_mod.Container.init(allocator),
            .event_queue = EventQueue(UiEvent).init(allocator),
            .ca = ca,
        };
        self.editor.prompt_fg = theme.fg(.muted);
        self.editor.border_color = theme.fg(.border_muted);
        self.transcript.theme = theme;
        return self;
    }

    pub fn deinit(self: *Interactive) void {
        if (self.agent_thread) |t| t.join();
        // drain and free any remaining events
        var drain_buf: [64]UiEvent = undefined;
        while (true) {
            const count = self.event_queue.drainInto(&drain_buf);
            if (count == 0) break;
            for (drain_buf[0..count]) |*ev| ev.deinit(self.allocator);
        }
        self.paste_buf.deinit(self.allocator);
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

        self.editor.on_submit = &onEditorSubmit;
        self.editor.on_submit_ctx = @ptrCast(self);

        // Populate container slots with their initial children.
        self.header_container.addChild(self.header.component());
        self.status_container.addChild(self.status_text.component());
        self.editor_container.addChild(self.editor.component());
        self.editor_container.focused_child_index = 0; // for cursor y-offset translation

        // Set initial focus via TUI (source of truth for input routing)
        self.tui.setFocus(self.editor.component());

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
            var input_buf: [4096]u8 = undefined;
            const n = self.tui.terminal.readInput(&input_buf) catch 0;
            if (n > 0) {
                self.handleRawInput(input_buf[0..n]);
            }

            // 3. Check for terminal resize
            _ = self.tui.checkResize();

            // 4. Render if dirty
            if (self.tui.dirty) {
                self.renderFrame();
                self.tui.dirty = false;
            }

            // 5. Brief sleep to avoid busy-wait (1ms)
            std.Thread.sleep(1_000_000);
        }
    }

    fn handleRawInput(self: *Interactive, data: []const u8) void {
        var offset: usize = 0;
        while (offset < data.len) {
            // Bracketed paste: buffer until end marker
            if (self.in_paste) {
                if (std.mem.indexOfPos(u8, data, offset, "\x1b[201~")) |end_pos| {
                    self.paste_buf.appendSlice(self.allocator, data[offset..end_pos]) catch {};
                    self.editor.insertText(self.paste_buf.items);
                    self.paste_buf.items.len = 0;
                    self.in_paste = false;
                    self.tui.dirty = true;
                    offset = end_pos + 6;
                    continue;
                } else {
                    self.paste_buf.appendSlice(self.allocator, data[offset..]) catch {};
                    return;
                }
            }

            // Detect paste start marker
            if (offset + 5 < data.len and std.mem.eql(u8, data[offset .. offset + 6], "\x1b[200~")) {
                self.in_paste = true;
                self.paste_buf.items.len = 0;
                offset += 6;
                continue;
            }

            // Also treat bare \n as newline insertion (some terminals send this for shift+enter)
            if (data[offset] == '\n') {
                self.editor.insertText("\n");
                self.tui.dirty = true;
                offset += 1;
                continue;
            }

            const result = keys_mod.parseKey(data[offset..], self.tui.terminal.kitty_active) orelse {
                offset += 1;
                continue;
            };
            self.handleKey(result.key);
            offset += result.len;
        }
    }

    fn handleKey(self: *Interactive, key: Key) void {
        // App-level keybindings — handled before focus routing
        if (key.code == .escape) {
            if (self.is_streaming) {
                self.ca.agent.abort();
                self.status_text.setContent("aborted");
                self.status_text.fg = self.theme.fg(.@"error");
                self.tui.dirty = true;
            }
            return;
        }

        if (key.code == .char and key.char != null and key.char.? == 'c' and key.ctrl) {
            self.running = false;
            return;
        }

        if (key.code == .char and key.char != null and key.char.? == 'd' and key.ctrl) {
            if (self.editor.getText().len == 0) {
                self.running = false;
                return;
            }
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
                self.status_text.setContent("thinking...");
                self.status_text.fg = self.theme.fg(.muted);
                self.tui.dirty = true;
            },
            .message_start_user => {},
            .tool_call_streaming => |t| {
                const display = self.registry.create(self.allocator, t.tool_name);
                self.transcript.addToolExecution(t.tool_call_id, display);
                self.transcript.updateTool(t.tool_call_id, .{ .start = .{
                    .tool_name = t.tool_name,
                    .args_json = t.args_json,
                } });
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
                const display = self.registry.create(self.allocator, t.tool_name);
                self.transcript.addToolExecution(t.tool_call_id, display);
                self.transcript.updateTool(t.tool_call_id, .{ .start = .{
                    .tool_name = t.tool_name,
                    .args_json = t.args_json,
                } });
                self.status_text.setContent(t.tool_name);
                self.status_text.fg = self.theme.fg(.accent);
                self.transcript.scrollToBottom(self.tui.width(), self.outputHeight());
                self.tui.dirty = true;
            },
            .tool_update => |t| {
                self.transcript.updateTool(t.tool_call_id, .{ .update = .{
                    .result_text = t.result_text,
                    .is_error = t.is_error,
                } });
                self.transcript.scrollToBottom(self.tui.width(), self.outputHeight());
                self.tui.dirty = true;
            },
            .tool_end => |t| {
                self.transcript.updateTool(t.tool_call_id, .{ .end = .{
                    .result_text = t.result_text,
                    .is_error = t.is_error,
                } });
                self.transcript.scrollToBottom(self.tui.width(), self.outputHeight());
                self.tui.dirty = true;
            },
            .agent_finished => {
                self.is_streaming = false;
                if (self.agent_thread) |t| t.join();
                self.agent_thread = null;
                self.status_text.setContent("");
                self.tui.setFocus(self.editor.component());
                self.tui.dirty = true;
            },
            .agent_error => {
                self.is_streaming = false;
                if (self.agent_thread) |t| t.join();
                self.agent_thread = null;
                self.status_text.setContent("error occurred");
                self.status_text.fg = self.theme.fg(.@"error");
                self.tui.setFocus(self.editor.component());
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

        const prompt_copy = self.allocator.dupe(u8, text) catch return;

        self.editor.clear();
        self.is_streaming = true;
        self.tui.setFocus(null); // defocus editor during streaming
        self.status_text.setContent("sending...");
        self.status_text.fg = self.theme.fg(.muted);
        self.tui.dirty = true;

        self.agent_thread = std.Thread.spawn(.{}, agentThreadFn, .{ self, prompt_copy }) catch {
            self.is_streaming = false;
            self.tui.setFocus(self.editor.component());
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
                    const args_json = serializeJson(tc.tool_call.arguments, allocator) catch return null;
                    return .{ .tool_call_streaming = .{
                        .tool_call_id = id,
                        .tool_name = name,
                        .args_json = args_json,
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
            const args_json = serializeJson(te.args, allocator) catch return null;
            return .{ .tool_start = .{
                .tool_call_id = id,
                .tool_name = name,
                .args_json = args_json,
            } };
        },
        .tool_execution_update => |te| {
            const id = allocator.dupe(u8, te.tool_call_id) catch return null;
            errdefer allocator.free(id);
            const text = extractResultText(te.partial_result, allocator);
            return .{ .tool_update = .{
                .tool_call_id = id,
                .result_text = text,
                .is_error = if (te.partial_result) |r| r.is_error else false,
            } };
        },
        .tool_execution_end => |te| {
            const id = allocator.dupe(u8, te.tool_call_id) catch return null;
            errdefer allocator.free(id);
            const text = extractResultText(te.result, allocator);
            return .{ .tool_end = .{
                .tool_call_id = id,
                .result_text = text,
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

/// Serialize a json.Value to an owned string.
fn serializeJson(value: std.json.Value, allocator: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    errdefer buf.deinit(allocator);
    var out = std.io.Writer.Allocating.fromArrayList(allocator, &buf);
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    jw.write(value) catch return error.OutOfMemory;
    return buf.toOwnedSlice(allocator);
}

/// Extract text output from a tool result into an owned string.
/// Accepts both optional and non-optional AgentToolResult.
fn extractResultText(result: anytype, allocator: std.mem.Allocator) ?[]u8 {
    const T = @TypeOf(result);
    const r = if (@typeInfo(T) == .optional) (result orelse return null) else result;
    var total_len: usize = 0;
    for (r.content) |block| {
        switch (block) {
            .text => |t| total_len += t.text.len + 1,
            .image => {},
        }
    }
    if (total_len == 0) return null;

    const buf = allocator.alloc(u8, total_len) catch return null;
    var pos: usize = 0;
    for (r.content) |block| {
        switch (block) {
            .text => |t| {
                if (pos > 0) {
                    buf[pos] = '\n';
                    pos += 1;
                }
                @memcpy(buf[pos..][0..t.text.len], t.text);
                pos += t.text.len;
            },
            .image => {},
        }
    }
    if (pos < buf.len) {
        return allocator.realloc(buf, pos) catch buf;
    }
    return buf;
}
