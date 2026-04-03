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

const agent_mod = @import("../agent/root.zig");
const coding_agent_mod = @import("../coding_agent.zig");
const AgentEvent = agent_mod.protocol.AgentEvent;
const AssistantMessageEvent = agent_mod.protocol.AssistantMessageEvent;
const CodingAgent = coding_agent_mod.CodingAgent;

const Color = cell_mod.Color;
const Region = buffer_mod.Region;
const Terminal = terminal_mod.Terminal;
const Renderer = renderer_mod.Renderer;
const Key = keys_mod.Key;
const CursorState = component_mod.CursorState;

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

/// Wrapper: either an agent event or a control signal from the agent thread.
const QueuedEvent = union(enum) {
    agent_event: AgentEvent,
    agent_finished: void,
    agent_error: void,
};

/// Interactive mode — wires CodingAgent (blocking on its thread)
/// to the TUI (main thread) via a thread-safe event queue.
pub const Interactive = struct {
    allocator: std.mem.Allocator,
    terminal: Terminal,
    renderer: Renderer,
    editor: editor_mod.Editor,
    status_text: text_mod.Text,
    output_text: text_mod.Text,

    event_queue: EventQueue(QueuedEvent),
    ca: *CodingAgent,
    agent_thread: ?std.Thread = null,
    dirty: bool = true,
    running: bool = true,
    is_streaming: bool = false,

    /// Accumulated assistant response text (append text_deltas here).
    response_buf: std.ArrayListUnmanaged(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, ca: *CodingAgent) !Interactive {
        var term = Terminal.init();
        term.updateSize();

        const rend = try Renderer.init(allocator, term.fd_out, term.width, term.height);

        return .{
            .allocator = allocator,
            .terminal = term,
            .renderer = rend,
            .editor = editor_mod.Editor.init(allocator),
            .status_text = .{},
            .output_text = .{},
            .event_queue = EventQueue(QueuedEvent).init(allocator),
            .ca = ca,
        };
    }

    pub fn deinit(self: *Interactive) void {
        if (self.agent_thread) |t| t.join();
        self.response_buf.deinit(self.allocator);
        self.event_queue.deinit();
        self.editor.deinit();
        self.renderer.deinit();
        self.terminal.deinit();
    }

    /// Main loop — runs on the main thread.
    pub fn run(self: *Interactive) !void {
        try self.terminal.enterRawMode();
        self.terminal.hideCursor();
        self.terminal.enableBracketedPaste();
        self.terminal.queryKittyProtocol();

        self.editor.on_submit = &onEditorSubmit;
        self.editor.on_submit_ctx = @ptrCast(self);

        self.dirty = true;

        while (self.running) {
            // 1. Drain agent events
            var event_buf: [64]QueuedEvent = undefined;
            const count = self.event_queue.drainInto(&event_buf);
            for (event_buf[0..count]) |ev| {
                self.handleQueuedEvent(ev);
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

        if (self.editor.handleInput(key)) {
            self.dirty = true;
        }
    }

    fn handleQueuedEvent(self: *Interactive, ev: QueuedEvent) void {
        switch (ev) {
            .agent_event => |ae| self.handleAgentEvent(ae),
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

    fn handleAgentEvent(self: *Interactive, event: AgentEvent) void {
        switch (event) {
            .message_update => |mu| {
                switch (mu.assistant_message_event) {
                    .text_delta => |d| {
                        self.response_buf.appendSlice(self.allocator, d.delta) catch {};
                        self.output_text.setContent(self.response_buf.items);
                        self.dirty = true;
                    },
                    .@"error" => |e| {
                        if (e.@"error".error_message) |msg| {
                            self.status_text.setContent(msg);
                            self.status_text.fg = Color.rgb(255, 80, 80);
                            self.dirty = true;
                        }
                    },
                    else => {},
                }
            },
            .message_start => |ms| {
                switch (ms.message) {
                    .user => {},
                    .assistant => {
                        self.response_buf.items.len = 0;
                        self.status_text.setContent("thinking...");
                        self.status_text.fg = Color.rgb(150, 150, 150);
                        self.dirty = true;
                    },
                    .tool_result => {},
                    .compaction_summary, .branch_summary, .custom => {},
                }
            },
            .tool_execution_start => |te| {
                self.status_text.setContent(te.tool_name);
                self.status_text.fg = Color.rgb(100, 200, 255);
                self.dirty = true;
            },
            .agent_end, .agent_start, .turn_start, .turn_end,
            .message_end, .tool_execution_update, .tool_execution_end,
            => {},
        }
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
        const output_height: u32 = if (h > editor_height + status_height) h - editor_height - status_height else 0;

        if (output_height > 0) {
            const output_region = region.sub(0, 0, w, output_height);
            self.output_text.render(output_region);
        }

        if (h > editor_height) {
            const status_region = region.sub(0, output_height, w, status_height);
            self.status_text.render(status_region);
        }

        const editor_region = region.sub(0, h - editor_height, w, editor_height);
        self.editor.render(editor_region);

        if (self.editor.cursorState()) |cs| {
            self.terminal.showCursor();
            self.terminal.setCursorPos(cs.x, h - editor_height + cs.y);
        } else {
            self.terminal.hideCursor();
        }

        self.renderer.end() catch {};
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

    fn agentEventCallback(event: AgentEvent, ctx: ?*anyopaque) void {
        const self: *Interactive = @ptrCast(@alignCast(ctx));
        self.event_queue.push(.{ .agent_event = event });
    }
};
