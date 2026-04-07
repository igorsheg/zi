const std = @import("std");
const component_mod = @import("component.zig");
const buffer_mod = @import("buffer.zig");
const cell_mod = @import("cell.zig");
const grapheme = @import("grapheme.zig");
const markdown_mod = @import("components/markdown.zig");
const tool_display_mod = @import("tool_display.zig");
const agent_protocol = @import("../agent/root.zig").protocol;
const AgentToolResult = agent_protocol.AgentToolResult;
const json_util = @import("../ai/json_util.zig");
const theme_mod = @import("theme.zig");
const word_wrap_mod = @import("word_wrap.zig");
const lua_renderer_mod = @import("../extensions/lua_renderer.zig");
const runner_mod = @import("../extensions/runner.zig");

const Component = component_mod.Component;
const Measurement = component_mod.Measurement;
const Region = buffer_mod.Region;
const Color = cell_mod.Color;

// ── Transcript Item ───────────────────────────────────────────────

/// Behavior tag for items that need special rendering treatment.
/// Most items are .generic (just render the component). Built-in types
/// use tags for: bg fill (tool), spacer (user_message), scroll merge (assistant).
pub const ItemKind = enum {
    generic,
    assistant_text,
    user_message,
    tool_execution,
};

/// Cleanup function type for owned items.
pub const DeinitFn = *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) void;

/// A single item in the transcript — generic component with optional metadata.
///
/// Replaces the previous closed TranscriptRow union. Every item is a Component
/// that can be rendered/measured via the vtable. Built-in types (assistant,
/// tool, user) are convenience constructors that set `kind` + metadata.
/// Extensions inject arbitrary components with kind=.generic.
pub const TranscriptItem = struct {
    component: Component,
    kind: ItemKind = .generic,
    /// For tool_execution: route updates by ID via pending_tools HashMap.
    tool_call_id: ?[]const u8 = null,
    /// Owned cleanup context. Called on item removal/transcript clear.
    deinit_ctx: ?*anyopaque = null,
    deinit_fn: ?DeinitFn = null,
    /// Extra height added outside the component (e.g., spacer before user message).
    extra_height: u32 = 0,

    pub fn deinit(self: *TranscriptItem, allocator: std.mem.Allocator) void {
        if (self.deinit_fn) |f| f(self.deinit_ctx.?, allocator);
    }
};

// ── Tool Execution ────────────────────────────────────────────────

/// State for a single tool execution within the transcript.
/// Owns all data (deep-cloned from events). Handles its own rendering
/// with bg fill, call summary, and result display.
///
/// Rendering uses optional ToolRenderer functions for per-tool formatting.
/// Falls back to: bold(tool_name) for call, truncated text for result.
pub const ToolExecution = struct {
    tool_call_id: []u8,
    tool_name: []u8,
    args: std.json.Value = .null,
    result: ?AgentToolResult = null,
    is_partial: bool = true,
    is_error: bool = false,
    execution_started: bool = false,
    args_complete: bool = false,
    expanded: bool = false,
    renderer: tool_display_mod.ToolRenderer = .{},
    renderer_state: ?*anyopaque = null,
    allocator: std.mem.Allocator,
    theme: *const theme_mod.Theme = &theme_mod.Theme.dark,

    /// Optional pre-computed span tree from a Lua render_result hook.
    /// When present, `renderResult` paints from these spans instead
    /// of the zig-native vtable or the text fallback. Computed by
    /// `Transcript.lua_renderer_ctx` dispatch at
    /// `setFinalResult`/`setPartialResult`/`setArgs` time.
    lua_render_state: ?*lua_renderer_mod.LuaRenderState = null,

    pub fn deinit(self: *ToolExecution) void {
        if (self.renderer.deinit_state) |deinit_fn| {
            if (self.renderer_state) |state| deinit_fn(state, self.allocator);
        }
        if (self.lua_render_state) |s| s.deinit(self.allocator);
        if (self.result) |r| r.free(self.allocator);
        json_util.freeJsonValue(self.allocator, self.args);
        self.allocator.free(self.tool_name);
        self.allocator.free(self.tool_call_id);
        self.allocator.destroy(self);
    }

    /// Clear the cached lua render state. Called from any mutator
    /// that invalidates what the hook would have produced.
    fn invalidateLuaRender(self: *ToolExecution) void {
        if (self.lua_render_state) |s| {
            s.deinit(self.allocator);
            self.lua_render_state = null;
        }
    }

    fn deinitItem(ctx: *anyopaque, _: std.mem.Allocator) void {
        const self: *ToolExecution = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    /// Set args (from tool_call_streaming or tool_start). Deep-clones the value.
    pub fn setArgs(self: *ToolExecution, args: std.json.Value) void {
        json_util.freeJsonValue(self.allocator, self.args);
        self.args = json_util.cloneJsonValue(self.allocator, args) catch .null;
        self.invalidateLuaRender();
    }

    /// Mark that execution has started (tool_start received).
    pub fn markExecutionStarted(self: *ToolExecution) void {
        self.execution_started = true;
    }

    /// Mark that args are complete (tool_call_streaming finished).
    pub fn setArgsComplete(self: *ToolExecution) void {
        self.args_complete = true;
    }

    /// Set partial result (from tool_update). Deep-clones.
    pub fn setPartialResult(self: *ToolExecution, result: ?AgentToolResult, is_error: bool) void {
        if (self.result) |old| old.free(self.allocator);
        self.result = if (result) |r| (r.clone(self.allocator) catch null) else null;
        self.is_error = is_error;
        self.is_partial = true;
        self.invalidateLuaRender();
    }

    /// Set final result (from tool_end). Deep-clones.
    pub fn setFinalResult(self: *ToolExecution, result: ?AgentToolResult, is_error: bool) void {
        if (self.result) |old| old.free(self.allocator);
        self.result = if (result) |r| (r.clone(self.allocator) catch null) else null;
        self.is_error = is_error;
        self.is_partial = false;
        self.invalidateLuaRender();
    }

    // ── Rendering ─────────────────────────────────────────────────

    fn bgColor(self: *ToolExecution) Color {
        if (self.is_partial)
            return self.theme.bg(.tool_pending_bg);
        if (self.is_error)
            return self.theme.bg(.tool_error_bg);
        return self.theme.bg(.tool_success_bg);
    }

    // Vertical padding inside the bg box (pi-mono: Box(paddingX=1, paddingY=1))
    const padding_y: u32 = 1;

    pub fn measure(self: *ToolExecution, width: u32) Measurement {
        if (width == 0) return .{ .min_height = 0, .preferred_height = 0 };
        const content_w = if (width > 2) width - 2 else 1;
        var h: u32 = padding_y; // top padding
        h += 1; // call line
        h += self.measureResult(content_w);
        h += padding_y; // bottom padding
        return .{ .min_height = 1, .preferred_height = @max(1, h) };
    }

    pub fn render(self: *ToolExecution, region: Region) void {
        const w = region.width;
        const h = region.height;
        if (w == 0 or h == 0) return;

        const bg = self.bgColor();
        if (!bg.eql(Color.default)) {
            region.fill(0, 0, w, h, .{
                .grapheme = .{ .codepoint = ' ' },
                .bg = bg,
            });
        }

        const content_w = if (w > 2) w - 2 else 1;
        var row: u32 = padding_y; // skip top padding

        if (row < h) {
            const call_region = region.sub(1, row, content_w, 1);
            self.renderCall(call_region);
            row += 1;
        }

        if (row < h -| padding_y) {
            const result_h = h -| row -| padding_y; // leave room for bottom padding
            if (result_h > 0) {
                const result_region = region.sub(1, row, content_w, result_h);
                self.renderResult(result_region);
            }
        }
    }

    fn renderCall(self: *ToolExecution, region: Region) void {
        // When a Lua render hook owns this tool, `lines[0]` of the
        // precomputed spans is the title line (e.g. "Task <desc>").
        // Paint it here instead of the default bold-toolname
        // fallback so we don't double up.
        if (self.lua_render_state) |s| {
            const lines = if (self.expanded) s.expanded else s.collapsed;
            if (lines.len > 0) {
                self.renderSpanLine(region, 0, lines[0]);
                return;
            }
        }
        if (self.renderer.render_call) |render_fn| {
            var ctx = self.makeRenderContext(region);
            render_fn(&ctx);
        } else {
            self.renderCallFallback(region);
        }
    }

    fn renderCallFallback(self: *ToolExecution, region: Region) void {
        _ = region.writeStr(0, 0, self.tool_name, self.theme.fg(.tool_title), Color.default, .{ .bold = true });
    }

    fn renderResult(self: *ToolExecution, region: Region) void {
        if (self.lua_render_state) |s| {
            // lines[0] was painted in renderCall; the rest goes
            // here. When there are no extra lines (tool with
            // only a title), the result region stays blank.
            const lines = if (self.expanded) s.expanded else s.collapsed;
            if (lines.len > 1) {
                self.renderSpanLines(region, lines[1..]);
            }
            return;
        }
        if (self.renderer.render_result) |render_fn| {
            var ctx = self.makeRenderContext(region);
            render_fn(&ctx);
        } else {
            self.renderResultFallback(region);
        }
    }

    /// Paint a single span-line at `row` inside `region`. Used for
    /// both the call row (1 line) and individual result rows.
    fn renderSpanLine(self: *ToolExecution, region: Region, row: u32, line: lua_renderer_mod.Line) void {
        if (row >= region.height) return;
        var col: u32 = 0;
        for (line) |span| {
            if (col >= region.width) break;
            const fg = if (span.fg) |role| self.theme.fg(role) else Color.default;
            const bg = if (span.bg) |role| self.theme.bg(role) else Color.default;
            const attrs = cell_mod.Attributes{
                .bold = span.bold,
                .dim = span.dim,
                .italic = span.italic,
                .underline = span.underline,
            };
            const written = region.writeStr(col, row, span.text, fg, bg, attrs);
            col += written;
        }
    }

    /// Paint pre-computed styled lines into the region. Used by
    /// Lua renderers; strings and roles are arena-owned by
    /// `lua_render_state`. Each span resolves its theme role to
    /// concrete colors at paint time so theme swaps work without
    /// re-dispatching the Lua hook.
    fn renderSpanLines(self: *ToolExecution, region: Region, lines: []const lua_renderer_mod.Line) void {
        const max_h = region.height;
        var row: u32 = 0;
        for (lines) |line| {
            if (row >= max_h) break;
            self.renderSpanLine(region, row, line);
            row += 1;
        }
    }

    fn renderResultFallback(self: *ToolExecution, region: Region) void {
        const result_text = self.getResultText() orelse return;
        defer self.allocator.free(result_text);

        const fg = if (self.is_error) self.theme.fg(.@"error") else self.theme.fg(.tool_output);
        const w: usize = @intCast(region.width);
        const lines = word_wrap_mod.wordWrap(result_text, w, self.allocator) catch return;
        defer self.allocator.free(lines);

        const max_preview: u32 = if (self.expanded) @intCast(lines.len) else 5;
        var row: u32 = 0;
        var line_idx: u32 = 0;
        while (line_idx < @min(@as(u32, @intCast(lines.len)), max_preview) and row < region.height) {
            const line = lines[line_idx];
            _ = region.writeStr(0, row, line.text(result_text), fg, Color.default, .{});
            row += 1;
            line_idx += 1;
        }

        if (!self.expanded and lines.len > max_preview and row < region.height) {
            const remaining = lines.len - max_preview;
            var hint_buf: [64]u8 = undefined;
            const hint = std.fmt.bufPrint(&hint_buf, "... ({d} more lines)", .{remaining}) catch "...";
            _ = region.writeStr(0, row, hint, self.theme.fg(.dim), Color.default, .{});
        }
    }

    fn measureResult(self: *ToolExecution, width: u32) u32 {
        if (self.lua_render_state) |s| {
            // lines[0] is painted in the call row; the rest is
            // the result region's height.
            const lines = if (self.expanded) s.expanded else s.collapsed;
            return if (lines.len > 0) @intCast(lines.len - 1) else 0;
        }
        if (self.renderer.measure_result) |measure_fn| {
            var ctx = self.makeMeasureContext(width);
            return measure_fn(&ctx);
        }
        return self.measureResultFallback(width);
    }

    fn measureResultFallback(self: *ToolExecution, width: u32) u32 {
        const result_text = self.getResultText() orelse return 0;
        defer self.allocator.free(result_text);

        const w: usize = @intCast(width);
        const lines = word_wrap_mod.wordWrap(result_text, w, self.allocator) catch return 1;
        defer self.allocator.free(lines);

        if (self.expanded) return @intCast(lines.len);
        const max_preview: u32 = 5;
        if (lines.len > max_preview) return max_preview + 1;
        return @intCast(lines.len);
    }

    /// Extract joined text from result content blocks.
    fn getResultText(self: *ToolExecution) ?[]u8 {
        const result = self.result orelse return null;
        var total_len: usize = 0;
        for (result.content) |block| {
            switch (block) {
                .text => |t| total_len += t.text.len + 1,
                .image => {},
            }
        }
        if (total_len == 0) return null;

        const buf = self.allocator.alloc(u8, total_len) catch return null;
        var pos: usize = 0;
        for (result.content) |block| {
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
            return self.allocator.realloc(buf, pos) catch buf[0..pos];
        }
        return buf;
    }

    fn makeMeasureContext(self: *ToolExecution, width: u32) tool_display_mod.ToolRenderContext {
        return .{
            .tool_name = self.tool_name,
            .tool_call_id = self.tool_call_id,
            .args = self.args,
            .result = self.result,
            .is_partial = self.is_partial,
            .is_error = self.is_error,
            .expanded = self.expanded,
            .execution_started = self.execution_started,
            .args_complete = self.args_complete,
            .theme = self.theme,
            .allocator = self.allocator,
            .state = self.renderer_state,
            .region = undefined,
            .width = width,
        };
    }

    fn makeRenderContext(self: *ToolExecution, region: Region) tool_display_mod.ToolRenderContext {
        return .{
            .tool_name = self.tool_name,
            .tool_call_id = self.tool_call_id,
            .args = self.args,
            .result = self.result,
            .is_partial = self.is_partial,
            .is_error = self.is_error,
            .expanded = self.expanded,
            .execution_started = self.execution_started,
            .args_complete = self.args_complete,
            .theme = self.theme,
            .allocator = self.allocator,
            .state = self.renderer_state,
            .region = region,
            .width = region.width,
        };
    }

    pub fn component(self: *ToolExecution) Component {
        return Component.init(ToolExecution, self);
    }
};

// ── Markdown wrapper deinit ───────────────────────────────────────

fn deinitMarkdown(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const md: *markdown_mod.Markdown = @ptrCast(@alignCast(ctx));
    md.deinit();
    allocator.destroy(md);
}

// ── Transcript ────────────────────────────────────────────────────

/// Scrollable conversation transcript with generic item storage.
///
/// Items are Components with optional metadata (kind, tool_call_id).
/// The transcript handles:
/// - Appending items in event order
/// - Streaming text merge (current_text_idx for assistant text deltas)
/// - Tool update routing by tool_call_id (O(1) HashMap lookup)
/// - Measuring total height for scroll calculations
/// - Rendering visible items into a Region given a scroll offset
///
/// Built-in types (assistant, tool, user) are convenience methods.
/// Extensions add arbitrary Components via addComponent().
pub const Transcript = struct {
    items: std.ArrayListUnmanaged(TranscriptItem) = .empty,
    /// Fast lookup: tool_call_id → item index for routing updates.
    pending_tools: std.StringHashMapUnmanaged(usize) = .{},
    /// Current assistant text item being appended to (index into items).
    current_text_idx: ?usize = null,

    allocator: std.mem.Allocator,
    theme: *const theme_mod.Theme = &theme_mod.Theme.dark,
    scroll_offset: u32 = 0,
    /// Cached from last render() call, used by clampScroll().
    last_render_width: u32 = 80,

    /// Optional runner pointer used to dispatch Lua `render_result`
    /// hooks at tool_execution_end time. When null (tests, headless
    /// modes, no-extensions build), Lua renderers are never invoked
    /// and the transcript falls back to its default formatting.
    lua_runner: ?*runner_mod.ExtensionRunner = null,

    pub fn init(allocator: std.mem.Allocator) Transcript {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Transcript) void {
        for (self.items.items) |*item| item.deinit(self.allocator);
        self.items.deinit(self.allocator);
        self.pending_tools.deinit(self.allocator);
    }

    // ── Generic mutation API ──────────────────────────────────────

    /// Append an arbitrary component to the transcript.
    pub fn addComponent(self: *Transcript, comp: Component) void {
        self.current_text_idx = null;
        self.items.append(self.allocator, .{ .component = comp }) catch return;
    }

    /// Remove a specific component by identity. Used by extensions to retract items.
    /// Matches pi-mono's Container.removeChild() identity-based removal.
    pub fn removeComponent(self: *Transcript, comp: Component) void {
        var i: usize = 0;
        while (i < self.items.items.len) {
            if (Component.eql(self.items.items[i].component, comp)) {
                var item = self.items.items[i];
                // Clean up tool index if this was a tool execution
                if (item.tool_call_id) |id| {
                    _ = self.pending_tools.remove(id);
                }
                item.deinit(self.allocator);
                _ = self.items.orderedRemove(i);
                // Fix up pending_tools indices for items after the removed one
                var iter = self.pending_tools.iterator();
                while (iter.next()) |entry| {
                    if (entry.value_ptr.* > i) {
                        entry.value_ptr.* -= 1;
                    }
                }
                // Fix up current_text_idx
                if (self.current_text_idx) |idx| {
                    if (idx == i) {
                        self.current_text_idx = null;
                    } else if (idx > i) {
                        self.current_text_idx = idx - 1;
                    }
                }
                // Clamp scroll_offset so content doesn't render blank
                self.clampScroll();
                return; // remove first match only
            }
            i += 1;
        }
    }

    /// Remove all items and reset state. Used on session reset / /clear.
    pub fn clearAll(self: *Transcript) void {
        for (self.items.items) |*item| item.deinit(self.allocator);
        self.items.items.len = 0;
        self.pending_tools.clearRetainingCapacity();
        self.current_text_idx = null;
        self.scroll_offset = 0;
    }

    // ── Built-in convenience methods ──────────────────────────────

    /// Start a new assistant message.
    pub fn beginAssistantMessage(self: *Transcript) void {
        self.current_text_idx = null;
    }

    /// Append streaming text content to the current assistant message.
    pub fn appendText(self: *Transcript, delta: []const u8) void {
        if (self.current_text_idx) |idx| {
            // Reach into the markdown component to append
            const item = &self.items.items[idx];
            const md: *markdown_mod.Markdown = @ptrCast(@alignCast(item.component.ptr));
            md.appendContent(delta);
        } else {
            const md = self.allocator.create(markdown_mod.Markdown) catch return;
            md.* = markdown_mod.Markdown.init(self.allocator);
            md.padding_x = 1;
            md.appendContent(delta);
            self.items.append(self.allocator, .{
                .component = md.component(),
                .kind = .assistant_text,
                .extra_height = 1, // spacer before assistant text (pi-mono: Spacer(1))
                .deinit_ctx = @ptrCast(md),
                .deinit_fn = deinitMarkdown,
            }) catch {
                md.deinit();
                self.allocator.destroy(md);
                return;
            };
            self.current_text_idx = self.items.items.len - 1;
        }
    }

    /// Register a new tool execution.
    pub fn addToolExecution(
        self: *Transcript,
        tool_call_id: []const u8,
        tool_name: []const u8,
        renderer: tool_display_mod.ToolRenderer,
    ) void {
        if (self.pending_tools.contains(tool_call_id)) return;

        self.current_text_idx = null;

        const id = self.allocator.dupe(u8, tool_call_id) catch return;
        const name = self.allocator.dupe(u8, tool_name) catch {
            self.allocator.free(id);
            return;
        };
        const te = self.allocator.create(ToolExecution) catch {
            self.allocator.free(name);
            self.allocator.free(id);
            return;
        };
        te.* = .{
            .tool_call_id = id,
            .tool_name = name,
            .allocator = self.allocator,
            .theme = self.theme,
            .renderer = renderer,
        };
        if (renderer.init_state) |init_fn| {
            te.renderer_state = init_fn(self.allocator);
        }

        const item_idx = self.items.items.len;
        self.items.append(self.allocator, .{
            .component = te.component(),
            .kind = .tool_execution,
            .tool_call_id = te.tool_call_id,
            .extra_height = 1, // spacer before tool (pi-mono: Spacer(1))
            .deinit_ctx = @ptrCast(te),
            .deinit_fn = ToolExecution.deinitItem,
        }) catch {
            te.deinit();
            return;
        };
        self.pending_tools.put(self.allocator, te.tool_call_id, item_idx) catch {};
    }

    /// Get the ToolExecution for a pending tool by ID.
    fn getToolExecution(self: *Transcript, tool_call_id: []const u8) ?*ToolExecution {
        const idx = self.pending_tools.get(tool_call_id) orelse return null;
        if (idx >= self.items.items.len) return null;
        const item = &self.items.items[idx];
        if (item.kind != .tool_execution) return null;
        return @ptrCast(@alignCast(item.deinit_ctx.?));
    }

    /// Set args on a tool execution (from tool_call_streaming or tool_start).
    pub fn toolSetArgs(self: *Transcript, tool_call_id: []const u8, args: std.json.Value) void {
        const te = self.getToolExecution(tool_call_id) orelse return;
        te.setArgs(args);
    }

    /// Mark a tool execution as started.
    pub fn toolMarkExecutionStarted(self: *Transcript, tool_call_id: []const u8) void {
        const te = self.getToolExecution(tool_call_id) orelse return;
        te.markExecutionStarted();
    }

    /// Mark args as complete on a tool execution.
    pub fn toolSetArgsComplete(self: *Transcript, tool_call_id: []const u8) void {
        const te = self.getToolExecution(tool_call_id) orelse return;
        te.setArgsComplete();
    }

    /// Set partial result on a tool execution.
    pub fn toolSetPartialResult(self: *Transcript, tool_call_id: []const u8, result: ?AgentToolResult, is_error: bool) void {
        const te = self.getToolExecution(tool_call_id) orelse return;
        te.setPartialResult(result, is_error);
        // Re-dispatch the render hook so the tree view reflects
        // the new partial state. Tools without a render hook
        // no-op gracefully.
        self.refreshLuaRender(te);
    }

    /// Set final result on a tool execution and remove from pending.
    pub fn toolSetFinalResult(self: *Transcript, tool_call_id: []const u8, result: ?AgentToolResult, is_error: bool) void {
        const te = self.getToolExecution(tool_call_id) orelse return;
        te.setFinalResult(result, is_error);
        _ = self.pending_tools.remove(tool_call_id);
        // Kick off the Lua render_result hook (if any) now that we
        // have a final result in hand. `refreshLuaRender` is a
        // no-op for tools without a registered render hook.
        self.refreshLuaRender(te);
    }

    /// Pick up any precomputed render that the agent thread
    /// stashed for this tool call and assign it to the
    /// ToolExecution. Pure data move — does not touch the Lua
    /// state, so this is safe to call from the TUI thread without
    /// blocking on the runner's lua mutex.
    ///
    /// The render itself is computed on the agent thread inside
    /// `lua_tool.precomputeRender`, which fires once on each
    /// `ctx.update(...)` call and once on tool completion. See
    /// `runner.zig` `pending_renders` for the cross-thread inbox
    /// rationale.
    fn refreshLuaRender(self: *Transcript, te: *ToolExecution) void {
        const runner = self.lua_runner orelse return;
        const pending = runner.takePendingRender(te.tool_call_id) orelse return;
        te.invalidateLuaRender();
        te.lua_render_state = @ptrCast(@alignCast(pending.state));
    }

    /// Toggle expansion state on all tool executions.
    pub fn setToolOutputExpanded(self: *Transcript, expanded: bool) void {
        for (self.items.items) |*item| {
            if (item.kind == .tool_execution) {
                const te: *ToolExecution = @ptrCast(@alignCast(item.deinit_ctx.?));
                te.expanded = expanded;
            }
        }
    }

    /// Add a user message bubble.
    pub fn addUserMessage(self: *Transcript, text: []const u8) void {
        self.current_text_idx = null;

        const md = self.allocator.create(markdown_mod.Markdown) catch return;
        md.* = markdown_mod.Markdown.init(self.allocator);
        md.padding_x = 1;
        md.padding_y = 1;
        md.bg = self.theme.bg(.user_message_bg);
        md.fg = self.theme.fg(.user_message_text);
        md.setContent(text);

        self.items.append(self.allocator, .{
            .component = md.component(),
            .kind = .user_message,
            .extra_height = 1, // spacer before user message
            .deinit_ctx = @ptrCast(md),
            .deinit_fn = deinitMarkdown,
        }) catch {
            md.deinit();
            self.allocator.destroy(md);
            return;
        };
    }

    // ── Layout / scroll ───────────────────────────────────────────

    /// Total height of all items at the given width.
    pub fn totalHeight(self: *Transcript, width: u32) u32 {
        if (width == 0) return 0;
        var h: u32 = 0;
        for (self.items.items) |*item| {
            h += self.itemHeight(item, width);
        }
        return h;
    }

    /// Scroll to bottom so last content is visible.
    pub fn scrollToBottom(self: *Transcript, width: u32, visible_height: u32) void {
        const total = self.totalHeight(width);
        if (total > visible_height) {
            self.scroll_offset = total - visible_height;
        } else {
            self.scroll_offset = 0;
        }
    }

    /// Clamp scroll_offset so it doesn't exceed content height.
    /// Uses last_render_width for measurement. Called after mutations
    /// that shrink content (removeComponent).
    fn clampScroll(self: *Transcript) void {
        const total = self.totalHeight(self.last_render_width);
        if (self.scroll_offset > total) {
            self.scroll_offset = total;
        }
    }

    pub fn measure(self: *Transcript, width: u32) Measurement {
        const total = self.totalHeight(width);
        return .{ .min_height = 1, .preferred_height = total };
    }

    pub fn component(self: *Transcript) component_mod.Component {
        return component_mod.Component.init(Transcript, self);
    }

    /// Render visible items into the region, respecting scroll_offset.
    pub fn render(self: *Transcript, region: Region) void {
        const w = region.width;
        const h = region.height;
        if (w == 0 or h == 0) return;
        self.last_render_width = w;

        var virtual_y: u32 = 0;
        var screen_y: u32 = 0;

        for (self.items.items) |*item| {
            const item_h = self.itemHeight(item, w);
            const item_end = virtual_y + item_h;

            if (item_end <= self.scroll_offset) {
                virtual_y = item_end;
                continue;
            }
            if (screen_y >= h) break;

            const skipped = if (virtual_y < self.scroll_offset) self.scroll_offset - virtual_y else 0;
            const remaining = item_h - skipped;
            const visible_h = @min(remaining, h - screen_y);
            const row_region = region.sub(0, screen_y, w, visible_h);

            self.renderItem(item, row_region, skipped, visible_h, w);

            screen_y += visible_h;
            virtual_y = item_end;
        }
    }

    fn renderItem(_: *Transcript, item: *TranscriptItem, row_region: Region, skipped: u32, visible_h: u32, w: u32) void {
        switch (item.kind) {
            .tool_execution => {
                // Tool execution: extra_height=1 spacer before the bg box
                const row_skip = skipped;
                if (item.extra_height > 0 and row_skip < item.extra_height) {
                    // Spacer still visible — render tool into remaining space
                    const spacer_visible = item.extra_height - row_skip;
                    if (visible_h > spacer_visible) {
                        const tool_region = row_region.sub(0, spacer_visible, w, visible_h - spacer_visible);
                        item.component.render(tool_region);
                    }
                } else {
                    // Spacer scrolled past — render tool directly
                    item.component.render(row_region);
                }
            },
            .user_message => {
                // User message: extra_height=1 spacer before the markdown bubble
                const row_skip = skipped;
                if (row_skip == 0) {
                    // Spacer visible — render md into remaining space
                    if (visible_h > 1) {
                        const md_region = row_region.sub(0, 1, w, visible_h - 1);
                        // Temporarily set scroll offset on the markdown for partial visibility
                        const md: *markdown_mod.Markdown = @ptrCast(@alignCast(item.deinit_ctx.?));
                        const saved = md.scroll_offset;
                        md.scroll_offset = 0;
                        md.render(md_region);
                        md.scroll_offset = saved;
                    }
                } else {
                    // Spacer scrolled past — render md with adjusted scroll
                    const md: *markdown_mod.Markdown = @ptrCast(@alignCast(item.deinit_ctx.?));
                    const saved = md.scroll_offset;
                    md.scroll_offset = row_skip - 1; // -1 for spacer
                    md.render(row_region);
                    md.scroll_offset = saved;
                }
            },
            .assistant_text => {
                // Assistant text: extra_height=1 spacer before content
                const md: *markdown_mod.Markdown = @ptrCast(@alignCast(item.deinit_ctx.?));
                const saved = md.scroll_offset;
                const row_skip = skipped;
                if (item.extra_height > 0 and row_skip < item.extra_height) {
                    // Spacer still visible
                    const spacer_visible = item.extra_height - row_skip;
                    if (visible_h > spacer_visible) {
                        const md_region = row_region.sub(0, spacer_visible, w, visible_h - spacer_visible);
                        md.scroll_offset = 0;
                        md.render(md_region);
                    }
                } else {
                    // Spacer scrolled past
                    md.scroll_offset = row_skip -| item.extra_height;
                    md.render(row_region);
                }
                md.scroll_offset = saved;
            },
            .generic => {
                // Generic: just render the component
                item.component.render(row_region);
            },
        }
    }

    fn itemHeight(self: *Transcript, item: *TranscriptItem, width: u32) u32 {
        _ = self;
        return @max(1, item.component.measure(width).preferred_height) + item.extra_height;
    }
};

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;
const Buffer = buffer_mod.Buffer;

test "Transcript renders assistant text and tool execution in order" {
    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    transcript.beginAssistantMessage();
    transcript.appendText("hello from assistant");

    transcript.addToolExecution("tool-1", "bash", .{});
    transcript.toolSetArgs("tool-1", .null);
    transcript.toolSetArgsComplete("tool-1");
    transcript.toolMarkExecutionStarted("tool-1");

    var content = [_]AgentToolResult.ContentBlock{
        .{ .text = .{ .text = "hi" } },
    };
    transcript.toolSetFinalResult("tool-1", .{ .content = &content, .is_error = false }, false);

    try testing.expectEqual(@as(usize, 2), transcript.items.items.len);

    var buf = try Buffer.init(testing.allocator, 30, 10);
    defer buf.deinit();
    transcript.render(buf.region());

    try testing.expectEqual(@as(u21, 'h'), buf.get(1, 0).grapheme.codepoint);
}

test "Transcript removeComponent removes item by identity and fixes indices" {
    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    // Use a simple component wrapper for identity testing
    const Wrapper = struct {
        val: u8 = 0,
        pub fn render(_: *@This(), _: Region) void {}
        pub fn measure(_: *@This(), _: u32) component_mod.Measurement {
            return .{ .min_height = 1, .preferred_height = 1 };
        }
        pub fn component(self: *@This()) Component {
            return Component.init(@This(), self);
        }
    };

    var w1 = Wrapper{ .val = 1 };
    var w2 = Wrapper{ .val = 2 };
    var w3 = Wrapper{ .val = 3 };

    transcript.addComponent(w1.component());
    transcript.addComponent(w2.component());
    transcript.addComponent(w3.component());

    try testing.expectEqual(@as(usize, 3), transcript.items.items.len);

    // Remove middle item
    transcript.removeComponent(w2.component());
    try testing.expectEqual(@as(usize, 2), transcript.items.items.len);

    // Remaining items should be w1 and w3
    try testing.expect(Component.eql(transcript.items.items[0].component, w1.component()));
    try testing.expect(Component.eql(transcript.items.items[1].component, w3.component()));

    // Remove non-existent — no-op
    transcript.removeComponent(w2.component());
    try testing.expectEqual(@as(usize, 2), transcript.items.items.len);

    // Scroll clamp: set scroll past total, remove item, verify clamped
    transcript.scroll_offset = 100;
    transcript.removeComponent(w3.component());
    // total height is now 1 (just w1), so scroll_offset should be clamped to ≤ 1
    try testing.expect(transcript.scroll_offset <= 1);
}

test "Transcript clearAll removes all items and resets state" {
    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    transcript.beginAssistantMessage();
    transcript.appendText("hello");
    transcript.addUserMessage("user msg");

    try testing.expectEqual(@as(usize, 2), transcript.items.items.len);

    transcript.clearAll();

    try testing.expectEqual(@as(usize, 0), transcript.items.items.len);
    try testing.expectEqual(@as(?usize, null), transcript.current_text_idx);
    try testing.expectEqual(@as(u32, 0), transcript.scroll_offset);
}
