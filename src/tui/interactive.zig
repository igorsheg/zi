const std = @import("std");
const posix = std.posix;
const cell_mod = @import("cell.zig");
const buffer_mod = @import("buffer.zig");
const renderer_mod = @import("renderer.zig");
const terminal_mod = @import("terminal.zig");
const keys_mod = @import("keys.zig");
const component_mod = @import("component.zig");
const text_mod = @import("components/text.zig");
const editor_mod = @import("components/editor.zig");
const ui_event_mod = @import("ui_event.zig");
const transcript_mod = @import("transcript.zig");
const tool_display_mod = @import("tool_display.zig");

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
const CursorState = component_mod.CursorState;
const UiEvent = ui_event_mod.UiEvent;
const Transcript = transcript_mod.Transcript;
const ToolDisplayRegistry = tool_display_mod.ToolDisplayRegistry;
const ToolDisplay = tool_display_mod.ToolDisplay;

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
            self.items.append(self.allocator, item) catch return;
            self.cond.signal();
        }

        /// Drain all queued items into caller's buffer. Non-blocking.
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
pub const Interactive = struct {
    allocator: std.mem.Allocator,
    terminal: Terminal,
    renderer: Renderer,
    editor: editor_mod.Editor,
    status_text: text_mod.Text,
    transcript: Transcript,
    registry: ToolDisplayRegistry,

    event_queue: EventQueue(UiEvent),
    ca: *CodingAgent,
    agent_thread: ?std.Thread = null,
    dirty: bool = true,
    running: bool = true,
    is_streaming: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        ca: *CodingAgent,
        registry: ToolDisplayRegistry,
    ) !Interactive {
        var term = Terminal.init();
        term.updateSize();

        const rend = try Renderer.init(allocator, term.fd_out, term.width, term.height);

        return .{
            .allocator = allocator,
            .terminal = term,
            .renderer = rend,
            .editor = editor_mod.Editor.init(allocator),
            .status_text = text_mod.Text.init(allocator),
            .transcript = Transcript.init(allocator),
            .registry = registry,
            .event_queue = EventQueue(UiEvent).init(allocator),
            .ca = ca,
        };
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
        self.event_queue.deinit();
        self.transcript.deinit();
        self.status_text.deinit();
        self.editor.deinit();
        self.renderer.deinit();
        self.terminal.deinit();
    }

    /// Main loop — runs on the main thread.
    pub fn run(self: *Interactive) !void {
        try self.terminal.enterRawMode();
        self.terminal.installSignalHandlers();
        self.terminal.hideCursor();
        self.terminal.enableBracketedPaste();
        self.terminal.queryKittyProtocol();

        self.editor.on_submit = &onEditorSubmit;
        self.editor.on_submit_ctx = @ptrCast(self);

        self.dirty = true;

        while (self.running) {
            // 1. Drain UI events (owned, thread-safe)
            var event_buf: [64]UiEvent = undefined;
            const count = self.event_queue.drainInto(&event_buf);
            for (event_buf[0..count]) |*ev| {
                self.handleUiEvent(ev);
                ev.deinit(self.allocator);
            }

            // 2. Poll terminal input (non-blocking: MIN=0, TIME=0)
            var input_buf: [256]u8 = undefined;
            const n = self.terminal.readInput(&input_buf) catch 0;
            if (n > 0) {
                self.handleRawInput(input_buf[0..n]);
            }

            // 3. Check for terminal resize
            self.terminal.updateSize();
            if (self.terminal.width != self.renderer.width or self.terminal.height != self.renderer.height) {
                self.renderer.resize(self.terminal.width, self.terminal.height) catch {};
                self.dirty = true;
            }

            // 4. Render if dirty
            if (self.dirty) {
                self.renderFrame();
                self.dirty = false;
            }

            // 5. Brief sleep to avoid busy-wait (1ms)
            std.Thread.sleep(1_000_000);
        }
    }

    fn handleRawInput(self: *Interactive, data: []const u8) void {
        var offset: usize = 0;
        while (offset < data.len) {
            const result = keys_mod.parseKey(data[offset..], self.terminal.kitty_active) orelse {
                offset += 1;
                continue;
            };
            self.handleKey(result.key);
            offset += result.len;
        }
    }

    fn handleKey(self: *Interactive, key: Key) void {
        if (key.code == .escape) {
            if (self.is_streaming) {
                self.ca.agent.abort();
                self.status_text.setContent("aborted");
                self.status_text.fg = Color.rgb(255, 80, 80);
                self.dirty = true;
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

        if (self.editor.handleInput(key)) {
            self.dirty = true;
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
            const w = self.renderer.width;
            const total = self.transcript.totalHeight(w);
            const max_scroll: u32 = if (total > output_h) total - output_h else 0;
            const current: i64 = @intCast(self.transcript.scroll_offset);
            const new_val = @max(0, @min(current + d, @as(i64, @intCast(max_scroll))));
            self.transcript.scroll_offset = @intCast(new_val);
            self.dirty = true;
            return true;
        }
        return false;
    }

    fn handleUiEvent(self: *Interactive, ev: *UiEvent) void {
        switch (ev.*) {
            .text_delta => |d| {
                self.transcript.appendText(d.delta);
                self.transcript.scrollToBottom(self.renderer.width, self.outputHeight());
                self.dirty = true;
            },
            .error_message => |e| {
                self.status_text.setContent(e.message);
                self.status_text.fg = Color.rgb(255, 80, 80);
                self.dirty = true;
            },
            .message_start_assistant => {
                self.transcript.beginAssistantMessage();
                self.status_text.setContent("thinking...");
                self.status_text.fg = Color.rgb(150, 150, 150);
                self.dirty = true;
            },
            .message_start_user => {},
            .tool_start => |t| {
                const display = self.registry.create(self.allocator, t.tool_name);
                self.transcript.addToolExecution(t.tool_call_id, display);
                self.transcript.updateTool(t.tool_call_id, .{ .start = .{
                    .tool_name = t.tool_name,
                    .args_json = t.args_json,
                } });
                self.status_text.setContent(t.tool_name);
                self.status_text.fg = Color.rgb(100, 200, 255);
                self.transcript.scrollToBottom(self.renderer.width, self.outputHeight());
                self.dirty = true;
            },
            .tool_update => |t| {
                self.transcript.updateTool(t.tool_call_id, .{ .update = .{
                    .result_text = t.result_text,
                    .is_error = t.is_error,
                } });
                self.transcript.scrollToBottom(self.renderer.width, self.outputHeight());
                self.dirty = true;
            },
            .tool_end => |t| {
                self.transcript.updateTool(t.tool_call_id, .{ .end = .{
                    .result_text = t.result_text,
                    .is_error = t.is_error,
                } });
                self.transcript.scrollToBottom(self.renderer.width, self.outputHeight());
                self.dirty = true;
            },
            .agent_finished => {
                self.is_streaming = false;
                self.agent_thread = null;
                self.status_text.setContent("");
                self.editor.focused = true;
                self.dirty = true;
            },
            .agent_error => {
                self.is_streaming = false;
                self.agent_thread = null;
                self.status_text.setContent("error occurred");
                self.status_text.fg = Color.rgb(255, 80, 80);
                self.editor.focused = true;
                self.dirty = true;
            },
        }
    }

    fn outputHeight(self: *Interactive) u32 {
        const h = self.renderer.height;
        const editor_height: u32 = 1;
        const status_height: u32 = 1;
        return if (h > editor_height + status_height) h - editor_height - status_height else 0;
    }

    fn renderFrame(self: *Interactive) void {
        const region = self.renderer.begin();
        const w = region.width;
        const h = region.height;

        if (h < 3 or w < 10) {
            _ = region.writeStr(0, 0, "terminal too small", Color.rgb(255, 80, 80), Color.default, .{});
            self.renderer.end() catch {};
            return;
        }

        const editor_height: u32 = 1;
        const status_height: u32 = 1;
        const output_height = self.outputHeight();

        if (output_height > 0) {
            const output_region = region.sub(0, 0, w, output_height);
            self.transcript.render(output_region);
        }

        if (h > editor_height) {
            const status_region = region.sub(0, output_height, w, status_height);
            self.status_text.render(status_region);
        }

        const editor_region = region.sub(0, h - editor_height, w, editor_height);
        self.editor.render(editor_region);

        self.renderer.end() catch {};

        if (self.editor.cursorState()) |cs| {
            self.terminal.showCursor();
            self.terminal.setCursorPos(cs.x, h - editor_height + cs.y);
        } else {
            self.terminal.hideCursor();
        }
    }

    // --- Editor submit callback ---

    fn onEditorSubmit(text: []const u8, ctx: ?*anyopaque) void {
        const self: *Interactive = @ptrCast(@alignCast(ctx));
        if (text.len == 0) return;

        const prompt_copy = self.allocator.dupe(u8, text) catch return;

        self.editor.clear();
        self.is_streaming = true;
        self.editor.focused = false;
        self.status_text.setContent("sending...");
        self.status_text.fg = Color.rgb(150, 150, 150);
        self.dirty = true;

        self.agent_thread = std.Thread.spawn(.{}, agentThreadFn, .{ self, prompt_copy }) catch {
            self.is_streaming = false;
            self.editor.focused = true;
            self.status_text.setContent("failed to start agent");
            self.status_text.fg = Color.rgb(255, 80, 80);
            self.allocator.free(prompt_copy);
            return;
        };
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
        .agent_end, .agent_start, .turn_start, .turn_end, .message_end => return null,
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
