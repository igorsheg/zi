# zi TUI Architecture Spec

## Decision Record

**Rendering technique**: cell-buffer differential (opentui's approach), NOT string-based differential (pi-mono's approach).

**Product experience**: pi-mono parity. same streaming UX, same component types, same interactive patterns.

**Rationale**: pi-mono's `render(width) → string[]` forces complex ANSI string manipulation for diffing, overlays, and width calculation. opentui's cell-buffer approach eliminates this — cells are structured data, diffing is struct comparison, overlays are coordinate writes. zig's memory model (arenas, no GC) makes double-buffered cell grids natural.

---

## Product Surface Inventory

Every interactive surface pi-mono exposes. zi must implement all of these.

| Surface | pi-mono source | Description |
|---------|---------------|-------------|
| **Header** | `header.ts` | Session name, model info, branch indicator |
| **Chat transcript** | `interactive-mode.ts` | Messages (user, assistant), tool executions, branch summaries, compaction summaries |
| **Pending queue area** | `interactive-mode.ts` | Queued steering/follow-up messages shown below transcript |
| **Status area** | `interactive-mode.ts` | Retry indicator, compaction progress, error display |
| **Editor** | `editor.ts` | Multi-line input with history, slash command autocomplete |
| **Footer** | `footer.ts` | Model name, key hints, context usage bar |
| **Model selector** | `model-selector.ts` | Overlay — fuzzy-filterable model list |
| **Session selector** | `session-selector.ts` | Overlay — session list with metadata |
| **Tree viewer** | `tree.ts` | Overlay — session branch tree |
| **Settings overlay** | `settings.ts` | Overlay — toggle settings |
| **Login flow** | `login.ts` | Overlay — auth flow |
| **Extension UI surfaces** | `extension-api.ts` | Widgets, custom editors, dialogs — **deferred, but the component interface must support it** (extensions register Component implementations via vtable; the overlay system renders them) |

### Slash Commands (complete pi-mono built-in set)

| Command | Action |
|---------|--------|
| `/help` | Show available commands |
| `/model` | Open model selector overlay |
| `/scoped-models` | Show/edit per-tool model overrides |
| `/settings` | Open settings overlay |
| `/session` | Open session selector overlay |
| `/tree` | Show session branch tree |
| `/new` | New session |
| `/fork` | Fork current session branch |
| `/name` | Rename current session |
| `/compact` | Trigger compaction |
| `/resume` | Resume interrupted session |
| `/reload` | Reload extensions and config |
| `/export` | Export session to file |
| `/import` | Import session from file |
| `/share` | Share session (generate link) |
| `/copy` | Copy last response to clipboard |
| `/login` | Authenticate |
| `/logout` | Clear auth |
| `/clear` | Clear screen |
| `/hotkeys` | Show keybinding reference |
| `/changelog` | Show changelog |
| `/quit` | Exit zi |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ INTERACTIVE MODE (src/tui/interactive.zig)                      │
│   Agent events → component tree mutations → dirty flag → render │
│   Slash commands, overlays, streaming UX                        │
├─────────────────────────────────────────────────────────────────┤
│ COMPONENTS (src/tui/components/)                                │
│   Markdown, Editor, Text, Container, Box, Loader, SelectList    │
│   Components write to Buffer via render(buf, region)            │
├─────────────────────────────────────────────────────────────────┤
│ RENDERER (src/tui/renderer.zig)                                 │
│   Double-buffered Cell grid. Diffs current vs next per cell.    │
│   Emits minimal ANSI for changed runs. Synchronized output.     │
│   Optional render thread for stdout flush.                      │
├─────────────────────────────────────────────────────────────────┤
│ TERMINAL (src/tui/terminal.zig)                                 │
│   Raw mode, resize, kitty keyboard + xterm fallback,            │
│   cursor management, capability detection                       │
├─────────────────────────────────────────────────────────────────┤
│ PRIMITIVES (src/tui/cell.zig, buffer.zig, grapheme.zig)         │
│   Cell struct, Buffer grid, Unicode width, grapheme clusters    │
└─────────────────────────────────────────────────────────────────┘
```

---

## Layer 1: Primitives

### Cell

The atomic rendering unit. Every screen position is a Cell.

```zig
pub const Color = struct {
    r: u8, g: u8, b: u8,
    pub const default_fg = Color{ .r = 255, .g = 255, .b = 255 };
    pub const default_bg = Color{ .r = 0, .g = 0, .b = 0 };
    pub const transparent = Color{ .r = 0, .g = 0, .b = 0 }; // sentinel
};

pub const Attributes = packed struct {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    inverse: bool = false,
    hidden: bool = false,
    strikethrough: bool = false,
};

/// Grapheme holds either a single codepoint inline (common case, fits in 4 bytes)
/// or an index into a GraphemePool for multi-codepoint clusters (emoji ZWJ sequences, etc.).
/// Matches opentui's GraphemePool approach.
pub const Grapheme = union(enum) {
    codepoint: u21,       // single codepoint (covers >99% of cells)
    pooled: u32,          // index into GraphemePool for multi-codepoint clusters
};

pub const Cell = struct {
    grapheme: Grapheme = .{ .codepoint = ' ' },
    fg: Color = Color.default_fg,
    bg: Color = Color.default_bg,
    attrs: Attributes = .{},
    width: u2 = 1,            // display width: 0 (continuation), 1 (normal), 2 (wide char left half)
    link_id: u16 = 0,         // non-zero = hyperlink (index into link table per-frame)

    pub fn eql(a: Cell, b: Cell) bool {
        return std.meta.eql(a.grapheme, b.grapheme) and
            std.meta.eql(a.fg, b.fg) and
            std.meta.eql(a.bg, b.bg) and
            std.meta.eql(a.attrs, b.attrs) and
            a.width == b.width and
            a.link_id == b.link_id;
    }
};
```

**Hyperlink support**: `link_id` indexes into a per-frame link table (`ArrayList([]const u8)`) stored on the Buffer. The renderer emits OSC 8 escape sequences for cells with non-zero `link_id`. Link table is rebuilt each frame.

**Image support**: images occupy rectangular cell regions. Stored as a separate overlay layer on the Buffer (list of `ImageRegion` structs with position, size, and image data reference). The renderer emits the appropriate protocol (kitty graphics protocol or sixel) after cell diffing. Cell grid is not used for image content — images composite on top.

### Buffer

2D grid of Cells. Components render into Buffers.

```zig
pub const Buffer = struct {
    cells: []Cell,
    width: u32,
    height: u32,
    allocator: std.mem.Allocator,
    grapheme_pool: GraphemePool,     // shared pool for multi-codepoint graphemes
    link_table: std.ArrayList([]const u8),  // hyperlink URLs indexed by link_id

    pub fn init(allocator, width, height) !Buffer
    pub fn deinit(self) void
    pub fn resize(self, width, height) !void
    pub fn clear(self) void
    pub fn get(self, x, y) Cell
    pub fn set(self, x, y, cell) void

    // String writing helpers
    pub fn writeStr(self, x, y, text, fg, bg, attrs) u32  // returns columns written
    pub fn writeStrWrapped(self, x, y, width, text, fg, bg, attrs) u32 // returns rows used

    // Region operations
    pub fn fill(self, x, y, w, h, cell) void
    pub fn copyFrom(self, src, src_x, src_y, dst_x, dst_y, w, h) void

    // Links
    pub fn addLink(self, url: []const u8) u16  // returns link_id
};
```

### Region

Clipped sub-area of a Buffer that components render into. Prevents components from writing outside their bounds.

```zig
pub const Region = struct {
    buf: *Buffer,
    x: u32,
    y: u32,
    width: u32,
    height: u32,

    pub fn set(self, x, y, cell) void       // clips to region bounds
    pub fn writeStr(self, x, y, text, ...) u32
    pub fn fill(self, x, y, w, h, cell) void
    pub fn sub(self, x, y, w, h) Region     // nested sub-region
};
```

### Grapheme / Width

Unicode-aware character width. Hot path — called per character during text rendering.

```zig
pub fn charWidth(codepoint: u21) u2       // 0, 1, or 2
pub fn strWidth(text: []const u8) usize   // total display columns
pub fn sliceToWidth(text: []const u8, max_cols: usize) []const u8
```

pi-mono does this with `visibleWidth()` which must parse ANSI escapes. With cell buffers, width calculation happens BEFORE cell writing — no ANSI to parse.

---

## Layer 2: Terminal

Abstraction over the actual terminal. Handles raw mode, input, resize.

```zig
pub const Terminal = struct {
    fd_in: std.posix.fd_t,    // stdin
    fd_out: std.posix.fd_t,   // stdout
    original_termios: std.posix.termios,
    width: u32,
    height: u32,
    kitty_active: bool,

    pub fn init() Terminal
    pub fn deinit(self) void

    // Mode management
    pub fn enterRawMode(self) void
    pub fn exitRawMode(self) void

    // Output
    pub fn write(self, data: []const u8) void
    pub fn flush(self) void

    // Dimensions
    pub fn getSize(self) struct { width: u32, height: u32 }
    pub fn onResize(self, callback) void  // SIGWINCH handler

    // Input
    pub fn readInput(self, buf) !usize  // non-blocking read

    // Keyboard protocol
    pub fn enableKittyProtocol(self) void
    pub fn disableKittyProtocol(self) void

    // Cursor
    pub fn hideCursor(self) void
    pub fn showCursor(self) void
    pub fn setCursorPos(self, col, row) void
};
```

### Key parsing

Parse raw terminal input into structured key events. Matches pi-mono's `keys.ts`.

```zig
pub const Key = struct {
    code: KeyCode,        // .char, .enter, .escape, .tab, .backspace, .up, .down, etc.
    char: ?u21 = null,    // for printable characters
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
};

pub const KeyCode = enum {
    char, enter, escape, tab, backspace,
    up, down, left, right,
    home, end, page_up, page_down,
    delete, insert,
    f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12,
};

pub fn parseKey(data: []const u8) ?Key
```

---

## Layer 3: Renderer

Diffs two Buffers and emits minimal ANSI to update the terminal. This is the core of the TUI — opentui's technique.

```zig
pub const Renderer = struct {
    current: Buffer,     // what's on screen
    next: Buffer,        // what should be on screen
    output: std.ArrayList(u8),  // ANSI output buffer
    terminal: *Terminal,
    width: u32,
    height: u32,

    pub fn init(allocator, terminal) !Renderer
    pub fn deinit(self) void

    // Get the next buffer for components to render into
    pub fn begin(self) *Buffer
        // clears next buffer, returns it for writing

    // Diff and flush
    pub fn end(self) void
        // 1. compare current vs next cell-by-cell
        // 2. build ANSI output for changed runs
        // 3. wrap in CSI 2026 synchronized output
        // 4. write to terminal
        // 5. swap: current = next

    pub fn resize(self, width, height) !void
    pub fn forceRedraw(self) void   // marks all cells dirty
};
```

### Diff algorithm (from opentui renderer.zig:609-760)

```
for each row y:
    for each col x:
        if current[x,y] == next[x,y]: skip
        else:
            position cursor at (x, y)
            emit fg/bg/attrs ANSI codes (only if changed from prev emit)
            emit character
            track run of consecutive changed cells (avoid redundant cursor moves)
```

Key optimizations:
- **Run coalescing**: consecutive changed cells share cursor position (no per-cell `\e[row;colH`)
- **Attribute caching**: track current fg/bg/attrs, only emit escape when they change
- **Synchronized output**: `\e[?2026h` ... `\e[?2026l` prevents tearing
- **Preallocated output buffer**: no per-frame allocation for ANSI output

---

## Layer 4: Component Interface

Components render into a Buffer Region. This is the fundamental departure from pi-mono's `render(width) → string[]`.

```zig
pub const Component = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Write cells into the given region. MUST NOT call renderer.end() or trigger renders.
        render: *const fn (ptr: *anyopaque, region: Region) void,

        /// Handle a key event. Returns true if consumed.
        handle_input: ?*const fn (ptr: *anyopaque, key: Key) bool = null,

        /// Mark component as needing re-render (sets dirty flag on component state).
        invalidate: ?*const fn (ptr: *anyopaque) void = null,

        /// Return min and preferred height for layout. Used by Container to allocate space.
        measure: ?*const fn (ptr: *anyopaque, width: u32) struct { min_height: u32, preferred_height: u32 } = null,

        /// Return cursor position and style if this component wants a visible cursor.
        /// Used by the main loop to position the terminal cursor after rendering.
        cursor_position: ?*const fn (ptr: *anyopaque) ?struct { x: u32, y: u32, style: CursorStyle } = null,

        /// Called when focus moves to/from this component.
        focus_changed: ?*const fn (ptr: *anyopaque, focused: bool) void = null,

        /// If true, component receives all input including keys normally consumed by the container
        /// (e.g., Escape, Tab). Used by overlays and the editor in multi-line mode.
        wants_raw_input: ?*const fn (ptr: *anyopaque) bool = null,
    };

    pub fn render(self, region: Region) void
    pub fn handleInput(self, key: Key) bool  // returns true if consumed
    pub fn invalidate(self) void
    pub fn measure(self, width: u32) struct { min_height: u32, preferred_height: u32 }
    pub fn cursorPosition(self) ?struct { x: u32, y: u32, style: CursorStyle }
};

pub const CursorStyle = enum { block, underline, bar };
```

### Container

Vertical stack of components. pi-mono equivalent: `Container`.

```zig
pub const Container = struct {
    children: std.ArrayList(Component),

    pub fn render(self, region: Region) void {
        var y: u32 = 0;
        for (self.children.items) |child| {
            const m = child.measure(region.width);
            const h = m.preferred_height;
            if (y + h > region.height) break;
            child.render(region.sub(0, y, region.width, h));
            y += h;
        }
    }
};
```

### ScrollView

Wraps a component taller than its region. Tracks scroll offset.

```zig
pub const ScrollView = struct {
    child: Component,
    scroll_y: u32,
    // renders child into oversized buffer, then copies visible window to region
};
```

---

## Layer 5: Core Components

### Text

Styled text. Wraps to width.

```zig
pub const Text = struct {
    content: []const u8,
    fg: Color,
    bg: Color,
    attrs: Attributes,
};
```

### Markdown

Renders markdown to cells. pi-mono equivalent: `Markdown` component (825 lines).

Approach: parse markdown → walk AST → write styled cells to buffer.

```zig
pub const Markdown = struct {
    content: []const u8,    // raw markdown text
    theme: MarkdownTheme,   // colors for headings, code, etc.
    cached_lines: ?[]Line,  // parsed cache, invalidated on content change

    pub fn setContent(self, text: []const u8) void
    pub fn render(self, region: Region) void
    pub fn measure(self, width: u32) struct { min_height: u32, preferred_height: u32 }
};
```

Markdown features (matching pi-mono):
- Headings (# through ######)
- Bold, italic, strikethrough
- Code spans (inline `code`)
- Code blocks (``` with language hint)
- Links (display text, not URLs)
- Blockquotes
- Lists (bulleted, numbered)
- Horizontal rules
- Word wrapping within paragraphs

Syntax highlighting in code blocks: defer to phase 4. Initially render code blocks with a single "code" color.

### Editor

Multi-line text input. pi-mono equivalent: `EditorComponent` (2231 lines).

```zig
pub const Editor = struct {
    lines: std.ArrayList(std.ArrayList(u8)),  // text content
    cursor_row: u32,
    cursor_col: u32,
    scroll_y: u32,
    focused: bool,
    // ... undo stack, kill ring, selection

    pub fn render(self, region: Region) void
    pub fn handleInput(self, key: Key) bool
    pub fn getText(self) []const u8
    pub fn clear(self) void
    pub fn cursorPosition(self) ?struct { x: u32, y: u32, style: CursorStyle }
};
```

Editor features (matching pi-mono, ordered by priority):
1. **P1**: Insert/delete characters, cursor movement (arrows, home/end), enter for newline
2. **P1**: Submit on Enter (single-line mode) or Ctrl+Enter (multi-line mode)
3. **P2**: Word-level movement (Ctrl+Left/Right), word-level delete
4. **P2**: Line history (up/down recalls previous inputs)
5. **P3**: Selection (Shift+arrows), cut/copy/paste
6. **P3**: Undo/redo
7. **P4**: Autocomplete for slash commands
8. **P4**: Bracketed paste detection

### Loader

Animated spinner. Shows during LLM streaming.

```zig
pub const Loader = struct {
    frames: []const []const u8,  // ["⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏"]
    current_frame: usize,
    label: []const u8,
};
```

### SelectList

Scrollable list with optional fuzzy filtering. Used for model selector, session selector.

```zig
pub const SelectList = struct {
    items: []const Item,
    selected: usize,
    scroll_offset: usize,
    filter: ?[]const u8,

    pub const Item = struct {
        label: []const u8,
        description: ?[]const u8 = null,
    };
};
```

### Box

Bordered container. Used for overlays, code blocks.

```zig
pub const Box = struct {
    child: Component,
    border_fg: Color,
    title: ?[]const u8,
    // renders border characters around child's region
};
```

---

## Layer 6: Interactive Mode

Wires CodingAgent events to the component tree. This is the equivalent of pi-mono's `interactive-mode.ts`.

### Component Tree

```
Container (root)
├── Header                           ← session name, model, branch
├── ScrollView (chat history)
│   └── Container (messages)
│       ├── UserMessageComponent     ← user prompt text
│       ├── AssistantMessageComponent ← streaming markdown + tool calls
│       │   ├── Markdown             ← text content blocks
│       │   └── ToolCallComponent[]  ← inline tool call argument streaming
│       ├── ToolExecutionComponent   ← tool name + incremental output + result
│       ├── BranchSummaryComponent   ← branch point indicator
│       ├── CompactionSummaryComponent ← compaction boundary marker
│       ├── UserMessageComponent     ← next user prompt
│       ├── AssistantMessageComponent
│       │   └── Markdown
│       └── ...
├── PendingQueueArea                 ← queued steering/follow-up messages
├── StatusArea                       ← retry indicator, compaction progress, errors
├── Loader                           ← shown during streaming
├── Editor                           ← user input
└── Footer                           ← model, session info, key hints, context usage
```

### Event → Component Mapping

Full mapping of agent events to component mutations. Event callbacks mutate component state and set a dirty flag. They NEVER call `renderer.end()` — rendering is driven solely by the main loop.

```zig
fn onAgentEvent(self: *InteractiveState, event: AgentEvent) void {
    switch (event) {
        // --- Message lifecycle ---
        .message_start => |e| {
            switch (e.message) {
                .user => self.addUserMessageComponent(e.message.user),
                .assistant => {
                    self.startAssistantComponent();
                    self.loader.show();
                },
                .tool_result => {},  // tool results rendered by ToolExecutionComponent
            }
        },

        .message_update => |e| {
            // e.assistant_message_event is one of 12 AssistantMessageEvent variants
            switch (e.assistant_message_event) {
                // Text content streaming
                .text_delta => |d| self.currentAssistant().appendText(d.delta),
                .text_done => |d| self.currentAssistant().finalizeText(d.text),

                // Thinking/reasoning content
                .thinking_delta => |d| self.currentAssistant().appendThinking(d.delta),
                .thinking_done => {},

                // Tool call argument streaming (shows args building up in real-time)
                .toolcall_start => |d| self.currentAssistant().startToolCall(d.tool_call_id, d.tool_name),
                .toolcall_delta => |d| self.currentAssistant().appendToolCallArgs(d.tool_call_id, d.args_delta),
                .toolcall_end => |d| self.currentAssistant().finalizeToolCall(d.tool_call_id),

                // Usage/stop
                .usage => |d| self.footer.updateUsage(d.usage),
                .stop_reason => |d| self.footer.updateStopReason(d.reason),
                .message_complete => |d| self.currentAssistant().setComplete(d.message),
            }
        },

        .message_end => |e| {
            switch (e.message) {
                .assistant => {
                    self.finalizeAssistantComponent();
                    self.loader.hide();
                },
                else => {},
            }
        },

        // --- Tool execution lifecycle ---
        .tool_execution_start => |e| {
            self.addToolExecutionComponent(e.tool_call_id, e.tool_name, e.args);
        },
        .tool_execution_update => |e| {
            // Incremental tool output (e.g., command stdout streaming)
            self.updateToolExecution(e.tool_call_id, e.output);
        },
        .tool_execution_end => |e| {
            self.completeToolExecution(e.tool_call_id, e.result);
        },

        // --- Agent lifecycle ---
        .agent_start => {},
        .agent_end => {
            self.loader.hide();
            self.editor.focus();
        },

        // --- Status events ---
        .retry => |e| {
            self.status.showRetry(e.attempt, e.max_attempts, e.reason);
        },
        .compaction_start => {
            self.status.showCompactionProgress();
        },
        .compaction_end => |e| {
            self.status.clearCompactionProgress();
            self.addCompactionSummary(e.summary);
        },

        // --- Queue events ---
        .steering_queued => |e| {
            self.pending_queue.addSteering(e.message);
        },
        .followup_queued => |e| {
            self.pending_queue.addFollowUp(e.message);
        },
        .queue_drained => |e| {
            self.pending_queue.remove(e.message_id);
        },
    }

    self.dirty = true;  // mark for re-render, NEVER call renderer.end() here
}
```

### Main Loop and Threading Model

The agent loop runs in a **separate thread**. The main thread owns terminal I/O and rendering. This is required because `ca.run()` blocks — without a separate thread, input cannot be processed during streaming (no Escape to abort, no follow-up queueing).

```
┌──────────────────────────┐     ┌──────────────────────────┐
│ Main thread              │     │ Agent thread              │
│                          │     │                           │
│ poll terminal input      │     │ ca.run(prompt)            │
│ poll event queue  ◄──────┼─────┤  events → queue           │
│ dispatch to components   │     │  blocks until done        │
│ if dirty: render         │     │                           │
│                          │     │ ca.continueSession()      │
│ submit → signal agent ───┼────►│  events → queue           │
└──────────────────────────┘     └──────────────────────────┘
```

**Communication**: thread-safe event queue between agent thread and main thread. Uses `std.Thread.Mutex` + `std.Thread.Condition` or a lock-free ring buffer. The main thread wakes on either terminal input OR a new event in the queue (via a self-pipe or eventfd for unified polling).

```zig
pub fn run(terminal: *Terminal) !void {
    var renderer = try Renderer.init(allocator, terminal);
    var state = InteractiveState.init(allocator);
    var event_queue = ThreadSafeQueue(AgentEvent).init(allocator);

    // Agent thread posts events to the queue
    var agent_thread: ?std.Thread = null;

    while (true) {
        // 1. Drain event queue (non-blocking)
        while (event_queue.tryPop()) |event| {
            state.onAgentEvent(event);
        }

        // 2. Poll input (non-blocking)
        if (terminal.readInput(&input_buf)) |n| {
            const key = parseKey(input_buf[0..n]);
            if (key) |k| {
                if (handleGlobalKey(k, &state, &agent_thread)) continue;
                if (state.focused_component.handleInput(k)) {
                    state.dirty = true;
                }
            }
        }

        // 3. Handle submit
        if (state.submit_requested) {
            const text = state.editor.getText();
            state.editor.clear();
            state.submit_requested = false;

            // Spawn or signal agent thread
            if (agent_thread == null) {
                agent_thread = try std.Thread.spawn(.{}, agentThreadFn, .{
                    ca, text, &event_queue,
                });
            } else {
                // Queue as follow-up or steering
                ca.queueFollowUp(text);
            }
        }

        // 4. Handle abort (Escape during streaming)
        if (state.abort_requested) {
            ca.abort();
            state.abort_requested = false;
        }

        // 5. Render if dirty
        if (state.dirty) {
            const buf = renderer.begin();
            state.root.render(Region.from(buf));

            // Position cursor if focused component wants one
            if (state.focused_component.cursorPosition()) |pos| {
                terminal.showCursor();
                terminal.setCursorPos(pos.x, pos.y);
            } else {
                terminal.hideCursor();
            }

            renderer.end();
            state.dirty = false;
        }

        // 6. Sleep briefly to avoid busy-wait (or use poll/select on fd + event pipe)
        std.time.sleep(1_000_000); // 1ms — replaced with proper fd polling in production
    }
}

fn agentThreadFn(ca: *CodingAgent, prompt: []const u8, queue: *ThreadSafeQueue(AgentEvent)) void {
    ca.agent.subscribe(struct {
        fn callback(ctx: *ThreadSafeQueue(AgentEvent), event: AgentEvent) void {
            ctx.push(event);
        }
    }.callback, queue);
    ca.run(prompt) catch |err| {
        queue.push(.{ .agent_error = err });
    };
    // Agent thread exits; main thread detects via agent_end event
}
```

**Key properties of this model**:
- Main thread is always responsive to input (Escape aborts, Ctrl+C exits, follow-ups queue)
- Rendering is driven by the main loop, exactly once per iteration when dirty
- Event callbacks in the agent thread do NOT render — they push to the queue
- No `renderer.end()` from callbacks, ever
- Timer-driven animations (loader spinner) update via the main loop's periodic tick

### Overlays

Modal components rendered on top of the main content. Uses the same Buffer — overlay components write to specific coordinates, overwriting the base content in the next buffer.

```zig
pub const Overlay = struct {
    component: Component,
    x: u32, y: u32,
    width: u32, height: u32,
    on_dismiss: ?*const fn () void,
};
```

The renderer composites overlays after the main tree renders but before diffing.

---

## Build Phases

### Phase 1: Terminal + Renderer (testable without components)

Files: `src/tui/cell.zig`, `src/tui/buffer.zig`, `src/tui/grapheme.zig`, `src/tui/terminal.zig`, `src/tui/renderer.zig`, `src/tui/keys.zig`

Tests:
- Buffer: set/get cells, clear, writeStr, region clipping, grapheme pool for multi-codepoint clusters
- Renderer: diff produces correct ANSI for single cell change, row change, full redraw
- Keys: parse xterm escape sequences, kitty protocol

Milestone: can clear screen and render colored text via Renderer.

### Phase 2: Core Components (testable against Buffer snapshots)

Files: `src/tui/component.zig`, `src/tui/components/text.zig`, `src/tui/components/container.zig`, `src/tui/components/scroll_view.zig`, `src/tui/components/markdown.zig`, `src/tui/components/editor.zig`

Tests:
- Text: renders at correct position with correct colors
- Container: stacks children vertically, respects measure()
- Markdown: headings, code blocks, bold render to correct cells
- Editor: cursor movement, insert/delete characters, cursorPosition() returns correct coords

Milestone: can render a markdown document and accept text input.

### Phase 3: Interactive Mode + Overlays (e2e with faux provider)

Files: `src/tui/interactive.zig`, `src/tui/event_queue.zig`, `src/tui/components/header.zig`, `src/tui/components/user_message.zig`, `src/tui/components/assistant_message.zig`, `src/tui/components/tool_execution.zig`, `src/tui/components/footer.zig`, `src/tui/components/loader.zig`, `src/tui/components/status_area.zig`, `src/tui/components/pending_queue.zig`, `src/tui/components/select_list.zig`, `src/tui/components/box.zig`, `src/tui/components/overlay.zig`

Tests:
- Streaming: faux sends text_delta events → Markdown component updates → Buffer contains expected cells
- Multi-turn: prompt → response → prompt → response → verify component tree
- Tool execution: tool_call → execution display → result display
- Threading: agent events arrive via queue, input remains responsive during streaming
- Overlays: render on top of base content, capture input, dismiss correctly
- SelectList: arrow keys navigate, fuzzy filter works
- Model/session selectors open and close correctly

Milestone: `zi` without flags launches interactive mode. Full conversation loop works. Overlays (model selector, session selector, tree viewer) are functional.

### Phase 4: Polish

Files: syntax highlighting, image rendering, extension UI system, advanced editor features

Deliverables:
- Syntax highlighting in code blocks (tree-sitter or regex-based)
- Image rendering (kitty graphics protocol)
- Extension UI contract (extensions register Component vtable implementations)
- Autocomplete for slash commands
- Kill ring / advanced clipboard
- Hyperlink rendering (OSC 8)

Milestone: pi-mono product parity for all interactive workflows including polish features.

---

## File Structure

```
src/tui/
├── cell.zig          # Cell, Color, Attributes, Grapheme
├── buffer.zig        # Buffer, Region, GraphemePool, link table
├── grapheme.zig      # Unicode width, grapheme clusters
├── terminal.zig      # Raw mode, resize, I/O
├── keys.zig          # Key parsing (xterm + kitty)
├── renderer.zig      # Double-buffer diff, ANSI output
├── component.zig     # Component interface (vtable), CursorStyle
├── interactive.zig   # Main loop, event→component wiring, threading
├── event_queue.zig   # Thread-safe event queue (agent→main thread)
├── theme.zig         # Color scheme definitions
├── root.zig          # Public exports
├── components/
│   ├── container.zig
│   ├── scroll_view.zig
│   ├── text.zig
│   ├── markdown.zig
│   ├── editor.zig
│   ├── loader.zig
│   ├── select_list.zig
│   ├── box.zig
│   ├── overlay.zig
│   ├── header.zig
│   ├── user_message.zig
│   ├── assistant_message.zig
│   ├── tool_execution.zig
│   ├── branch_summary.zig
│   ├── compaction_summary.zig
│   ├── status_area.zig
│   ├── pending_queue.zig
│   └── footer.zig
└── tests/
    ├── buffer_test.zig
    ├── renderer_test.zig
    ├── keys_test.zig
    ├── markdown_test.zig
    ├── editor_test.zig
    └── event_queue_test.zig
```
