const std = @import("std");
const component_mod = @import("component.zig");
const buffer_mod = @import("buffer.zig");
const cell_mod = @import("cell.zig");
const grapheme = @import("grapheme.zig");
const markdown_mod = @import("components/markdown.zig");
const assistant_message_mod = @import("components/assistant_message.zig");
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
    assistant_message,
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

const FirstVisible = struct {
    index: usize,
    skip_rows: u32,
};

const LayoutItemState = struct {
    cached_width: u32 = 0,
    cached_height: u32 = 0,
    dirty: bool = true,
};

const FenwickTree = struct {
    tree: std.ArrayListUnmanaged(u32) = .empty,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) FenwickTree {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *FenwickTree) void {
        self.tree.deinit(self.allocator);
    }

    fn resize(self: *FenwickTree, count: usize) !void {
        const new_len = count + 1;
        const old_len = self.tree.items.len;
        try self.tree.resize(self.allocator, new_len);
        if (new_len > old_len) {
            @memset(self.tree.items[old_len..new_len], 0);
        }
    }

    fn rebuild(self: *FenwickTree, heights: []const LayoutItemState) !void {
        try self.resize(heights.len);
        @memset(self.tree.items, 0);
        for (heights, 0..) |state, idx| {
            self.add(idx, state.cached_height);
        }
    }

    fn add(self: *FenwickTree, index: usize, delta: u32) void {
        var i = index + 1;
        while (i < self.tree.items.len) : (i += i & (~i + 1)) {
            self.tree.items[i] +%= delta;
        }
    }

    fn sub(self: *FenwickTree, index: usize, delta: u32) void {
        var i = index + 1;
        while (i < self.tree.items.len) : (i += i & (~i + 1)) {
            self.tree.items[i] -|= delta;
        }
    }

    fn set(self: *FenwickTree, index: usize, old_value: u32, new_value: u32) void {
        if (new_value > old_value) {
            self.add(index, new_value - old_value);
        } else if (old_value > new_value) {
            self.sub(index, old_value - new_value);
        }
    }

    fn prefixSumExclusive(self: *const FenwickTree, end: usize) u32 {
        var sum: u32 = 0;
        var i = end;
        while (i > 0) : (i -= i & (~i + 1)) {
            sum +%= self.tree.items[i];
        }
        return sum;
    }

    fn total(self: *const FenwickTree) u32 {
        if (self.tree.items.len == 0) return 0;
        return self.prefixSumExclusive(self.tree.items.len - 1);
    }

    fn lowerBound(self: *const FenwickTree, target: u32) usize {
        const count = if (self.tree.items.len == 0) 0 else self.tree.items.len - 1;
        if (count == 0) return 0;

        var bit: usize = 1;
        while ((bit << 1) <= count) : (bit <<= 1) {}

        var idx: usize = 0;
        var accumulated: u32 = 0;
        var step = bit;
        while (step > 0) : (step >>= 1) {
            const next = idx + step;
            if (next <= count and accumulated + self.tree.items[next] <= target) {
                idx = next;
                accumulated +%= self.tree.items[next];
            }
        }
        return @min(idx, count);
    }
};

const TranscriptLayout = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged(LayoutItemState) = .empty,
    heights: FenwickTree,
    layout_width: u32 = 0,
    dirty_count: usize = 0,
    viewport_offset: u32 = 0,
    follow_bottom: bool = true,

    fn init(allocator: std.mem.Allocator) TranscriptLayout {
        return .{
            .allocator = allocator,
            .heights = FenwickTree.init(allocator),
        };
    }

    fn deinit(self: *TranscriptLayout) void {
        self.items.deinit(self.allocator);
        self.heights.deinit();
    }

    fn clear(self: *TranscriptLayout) void {
        self.items.clearRetainingCapacity();
        self.layout_width = 0;
        self.dirty_count = 0;
        self.viewport_offset = 0;
        self.follow_bottom = true;
        self.heights.tree.clearRetainingCapacity();
    }

    fn appendItem(self: *TranscriptLayout) !void {
        const new_count = self.items.items.len + 1;
        try self.heights.resize(new_count);
        errdefer self.heights.resize(self.items.items.len) catch {};
        try self.items.append(self.allocator, .{});
        self.dirty_count += 1;
    }

    fn removeItem(self: *TranscriptLayout, index: usize) void {
        if (index >= self.items.items.len) return;
        const removed = self.items.orderedRemove(index);
        if (removed.dirty and self.dirty_count > 0) self.dirty_count -= 1;
        self.heights.rebuild(self.items.items) catch return;
    }

    fn invalidate(self: *TranscriptLayout, index: usize) void {
        if (index >= self.items.items.len) return;
        const item = &self.items.items[index];
        if (!item.dirty) {
            item.dirty = true;
            self.dirty_count += 1;
        }
    }

    fn invalidateAll(self: *TranscriptLayout) void {
        for (self.items.items) |*item| {
            if (!item.dirty) {
                item.dirty = true;
                self.dirty_count += 1;
            }
        }
    }

    fn ensureMeasured(self: *TranscriptLayout, ctx: *anyopaque, width: u32, measure_fn: *const fn (ctx: *anyopaque, index: usize, width: u32) u32) void {
        if (self.layout_width != width) {
            self.layout_width = width;
            self.invalidateAll();
        }
        if (self.dirty_count == 0) return;
        self.remeasureAll(ctx, width, measure_fn);
    }

    fn remeasureItem(self: *TranscriptLayout, index: usize, ctx: *anyopaque, width: u32, measure_fn: *const fn (ctx: *anyopaque, index: usize, width: u32) u32) void {
        if (index >= self.items.items.len) return;
        if (self.layout_width != width) {
            self.layout_width = width;
            self.invalidateAll();
        }

        const item = &self.items.items[index];
        const old_height = item.cached_height;
        const new_height = measure_fn(ctx, index, width);
        item.cached_width = width;
        item.cached_height = new_height;
        if (item.dirty) {
            item.dirty = false;
            if (self.dirty_count > 0) self.dirty_count -= 1;
        }
        self.heights.set(index, old_height, new_height);
    }

    fn remeasureAll(self: *TranscriptLayout, ctx: *anyopaque, width: u32, measure_fn: *const fn (ctx: *anyopaque, index: usize, width: u32) u32) void {
        self.layout_width = width;
        var idx: usize = 0;
        while (idx < self.items.items.len) : (idx += 1) {
            self.remeasureItem(idx, ctx, width, measure_fn);
        }
    }

    fn itemHeight(self: *const TranscriptLayout, index: usize) u32 {
        return if (index < self.items.items.len) self.items.items[index].cached_height else 0;
    }

    fn totalHeight(self: *const TranscriptLayout) u32 {
        return self.heights.total();
    }

    fn scrollOffset(self: *const TranscriptLayout) u32 {
        return self.viewport_offset;
    }

    fn maxScrollOffset(self: *const TranscriptLayout, visible_height: u32) u32 {
        const total = self.totalHeight();
        return if (total > visible_height) total - visible_height else 0;
    }

    fn scrollBy(self: *TranscriptLayout, delta: i64, visible_height: u32) void {
        const max_scroll = self.maxScrollOffset(visible_height);
        const current: i64 = @intCast(self.viewport_offset);
        const next = @max(0, @min(current + delta, @as(i64, @intCast(max_scroll))));
        self.viewport_offset = @intCast(next);
        self.follow_bottom = self.viewport_offset == max_scroll;
    }

    fn scrollToBottom(self: *TranscriptLayout, visible_height: u32) void {
        self.viewport_offset = self.maxScrollOffset(visible_height);
        self.follow_bottom = true;
    }

    fn clampScroll(self: *TranscriptLayout, visible_height: u32) void {
        const max_scroll = self.maxScrollOffset(visible_height);
        if (self.follow_bottom) {
            self.viewport_offset = max_scroll;
        } else if (self.viewport_offset > max_scroll) {
            self.viewport_offset = max_scroll;
        }
    }

    fn prefixHeightBefore(self: *const TranscriptLayout, index: usize) u32 {
        return self.heights.prefixSumExclusive(index);
    }

    fn findFirstVisible(self: *const TranscriptLayout) ?FirstVisible {
        const scroll_offset = self.viewport_offset;
        const total = self.totalHeight();
        if (self.items.items.len == 0 or scroll_offset >= total) return null;

        const index = self.heights.lowerBound(scroll_offset);
        if (index >= self.items.items.len) return null;
        const item_start = self.prefixHeightBefore(index);
        return .{
            .index = index,
            .skip_rows = scroll_offset - item_start,
        };
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
    scroll_offset: u32 = 0,

    /// Optional pre-computed span tree from a Lua render_result hook.
    /// When present, `renderResult` paints from these spans instead
    /// of the zig-native vtable or the text fallback. Computed by
    /// `Transcript.lua_renderer_ctx` dispatch at
    /// `setFinalResult`/`setPartialResult`/`setArgs` time.
    lua_render_state: ?*lua_renderer_mod.LuaRenderState = null,
    /// Lua render states are produced on the agent thread using the
    /// runner's allocator, then consumed and eventually retired on the
    /// TUI thread. Keep the typed deinit callback + original allocator
    /// so teardown happens against the allocation owner, not the
    /// transcript's allocator.
    lua_render_deinit: ?*const fn (*anyopaque, std.mem.Allocator) void = null,
    lua_render_allocator: ?std.mem.Allocator = null,

    pub fn deinit(self: *ToolExecution) void {
        if (self.renderer.deinit_state) |deinit_fn| {
            if (self.renderer_state) |state| deinit_fn(state, self.allocator);
        }
        self.invalidateLuaRender();
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
            const deinit_fn = self.lua_render_deinit orelse lua_renderer_mod.LuaRenderState.deinitOpaque;
            const alloc = self.lua_render_allocator orelse self.allocator;
            deinit_fn(@ptrCast(s), alloc);
            self.lua_render_state = null;
            self.lua_render_deinit = null;
            self.lua_render_allocator = null;
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
        const result_h = self.measureResult(content_w);
        const total_h = padding_y + 1 + result_h + padding_y;
        var row: u32 = 0;
        var virtual_row: u32 = self.scroll_offset;

        while (row < h and virtual_row < total_h) {
            if (virtual_row < padding_y) {
                row += 1;
                virtual_row += 1;
                continue;
            }

            if (virtual_row == padding_y) {
                const call_region = region.sub(1, row, content_w, 1);
                self.renderCall(call_region);
                row += 1;
                virtual_row += 1;
                continue;
            }

            const result_start = padding_y + 1;
            if (virtual_row < result_start + result_h) {
                const result_skip = virtual_row - result_start;
                const result_region = region.sub(1, row, content_w, h - row);
                self.renderResultFromOffset(result_region, result_skip, result_h);
                break;
            }

            break;
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
        self.renderResultFromOffset(region, 0, self.measureResult(region.width));
    }

    fn renderResultFromOffset(self: *ToolExecution, region: Region, skip_rows: u32, total_rows: u32) void {
        if (skip_rows >= total_rows) return;

        if (self.lua_render_state) |s| {
            const lines = if (self.expanded) s.expanded else s.collapsed;
            if (lines.len > 1) {
                const first: usize = @intCast(@min(skip_rows + 1, @as(u32, @intCast(lines.len))));
                if (first < lines.len) self.renderSpanLines(region, lines[first..]);
            }
            return;
        }

        if (self.renderer.render_result) |render_fn| {
            if (skip_rows == 0) {
                var ctx = self.makeRenderContext(region);
                render_fn(&ctx);
                return;
            }
            self.renderCustomResultSlice(region, skip_rows, total_rows, render_fn);
            return;
        }

        self.renderResultFallbackFromOffset(region, skip_rows);
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

    fn renderCustomResultSlice(
        self: *ToolExecution,
        region: Region,
        skip_rows: u32,
        total_rows: u32,
        render_fn: *const fn (ctx: *const tool_display_mod.ToolRenderContext) void,
    ) void {
        if (region.width == 0 or region.height == 0 or total_rows == 0 or skip_rows >= total_rows) return;

        var scratch = Buffer.init(self.allocator, region.width, total_rows) catch return;
        defer scratch.deinit();

        var ctx = self.makeRenderContext(scratch.region());
        render_fn(&ctx);

        blitRows(scratch.region(), region, skip_rows);
    }

    fn renderResultFallback(self: *ToolExecution, region: Region) void {
        self.renderResultFallbackFromOffset(region, 0);
    }

    fn renderResultFallbackFromOffset(self: *ToolExecution, region: Region, skip_rows: u32) void {
        const result_text = self.getResultText() orelse return;
        defer self.allocator.free(result_text);

        const fg = if (self.is_error) self.theme.fg(.@"error") else self.theme.fg(.tool_output);
        const w: usize = @intCast(region.width);
        const lines = word_wrap_mod.wordWrap(result_text, w, self.allocator) catch return;
        defer self.allocator.free(lines);

        const max_preview: u32 = if (self.expanded) @intCast(lines.len) else 5;
        const visible_lines = @min(@as(u32, @intCast(lines.len)), max_preview);
        var row: u32 = 0;
        var line_idx: u32 = skip_rows;
        while (line_idx < visible_lines and row < region.height) {
            const line = lines[line_idx];
            _ = region.writeStr(0, row, line.text(result_text), fg, Color.default, .{});
            row += 1;
            line_idx += 1;
        }

        if (!self.expanded and lines.len > max_preview and skip_rows <= max_preview and row < region.height) {
            const remaining = lines.len - max_preview;
            var hint_buf: [64]u8 = undefined;
            const hint = std.fmt.bufPrint(&hint_buf, "... ({d} more lines)", .{remaining}) catch "...";
            if (skip_rows == max_preview) {
                _ = region.writeStr(0, row, hint, self.theme.fg(.dim), Color.default, .{});
            }
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

fn blitRows(src: Region, dst: Region, start_row: u32) void {
    if (start_row >= src.height) return;
    const max_rows = @min(dst.height, src.height - start_row);
    const max_cols = @min(dst.width, src.width);

    var row: u32 = 0;
    while (row < max_rows) : (row += 1) {
        var col: u32 = 0;
        while (col < max_cols) : (col += 1) {
            dst.set(col, row, src.get(col, start_row + row));
        }
    }
}

// ── Markdown wrapper deinit ───────────────────────────────────────

fn deinitMarkdown(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const md: *markdown_mod.Markdown = @ptrCast(@alignCast(ctx));
    md.deinit();
    allocator.destroy(md);
}

fn deinitAssistantMessage(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const am: *assistant_message_mod.AssistantMessage = @ptrCast(@alignCast(ctx));
    am.deinit();
    allocator.destroy(am);
}

// ── Transcript ────────────────────────────────────────────────────

/// Scrollable conversation transcript with generic item storage.
///
/// Items are Components with optional metadata (kind, tool_call_id).
/// The transcript handles:
/// - Appending items in event order
/// - Streaming assistant message merge (current_assistant_idx for content deltas)
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
    /// Current assistant message item being appended to (index into items).
    current_assistant_idx: ?usize = null,
    layout: TranscriptLayout,

    allocator: std.mem.Allocator,
    theme: *const theme_mod.Theme = &theme_mod.Theme.dark,
    hide_thinking_block: bool = false,
    /// Cached viewport height for scroll clamping / sticky-end updates.
    last_visible_height: u32 = 0,
    /// Cached from last render() call, used by clampScroll().
    last_render_width: u32 = 80,

    /// Optional runner pointer used to dispatch Lua `render_result`
    /// hooks at tool_execution_end time. When null (tests, headless
    /// modes, no-extensions build), Lua renderers are never invoked
    /// and the transcript falls back to its default formatting.
    lua_runner: ?*runner_mod.ExtensionRunner = null,

    pub fn init(allocator: std.mem.Allocator) Transcript {
        return .{
            .allocator = allocator,
            .layout = TranscriptLayout.init(allocator),
        };
    }

    pub fn deinit(self: *Transcript) void {
        for (self.items.items) |*item| item.deinit(self.allocator);
        self.items.deinit(self.allocator);
        self.pending_tools.deinit(self.allocator);
        self.layout.deinit();
    }

    fn measureLayoutItem(ctx: *anyopaque, index: usize, width: u32) u32 {
        const self: *Transcript = @ptrCast(@alignCast(ctx));
        return self.itemHeight(&self.items.items[index], width);
    }

    fn ensureLayout(self: *Transcript, width: u32) void {
        self.last_render_width = width;
        self.layout.ensureMeasured(@ptrCast(self), width, measureLayoutItem);
    }

    fn syncScrollAfterLayout(self: *Transcript) void {
        self.layout.clampScroll(self.last_visible_height);
    }

    fn remeasureItem(self: *Transcript, index: usize) void {
        if (index >= self.items.items.len) return;
        self.layout.remeasureItem(index, @ptrCast(self), self.last_render_width, measureLayoutItem);
    }

    fn noteAppendedItem(self: *Transcript) void {
        const idx = self.items.items.len - 1;
        self.remeasureItem(idx);
        self.syncScrollAfterLayout();
    }

    fn appendTranscriptItem(self: *Transcript, item: TranscriptItem) bool {
        self.items.append(self.allocator, item) catch return false;
        errdefer self.items.items.len -= 1;
        self.layout.appendItem() catch return false;
        self.noteAppendedItem();
        return true;
    }

    fn noteItemMutated(self: *Transcript, index: usize) void {
        if (index >= self.items.items.len) return;
        self.layout.invalidate(index);
        self.remeasureItem(index);
        self.syncScrollAfterLayout();
    }

    // ── Generic mutation API ──────────────────────────────────────

    /// Append an arbitrary component to the transcript.
    pub fn addComponent(self: *Transcript, comp: Component) void {
        self.current_assistant_idx = null;
        _ = self.appendTranscriptItem(.{ .component = comp });
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
                self.layout.removeItem(i);
                // Fix up pending_tools indices for items after the removed one
                var iter = self.pending_tools.iterator();
                while (iter.next()) |entry| {
                    if (entry.value_ptr.* > i) {
                        entry.value_ptr.* -= 1;
                    }
                }
                // Fix up current_assistant_idx
                if (self.current_assistant_idx) |idx| {
                    if (idx == i) {
                        self.current_assistant_idx = null;
                    } else if (idx > i) {
                        self.current_assistant_idx = idx - 1;
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
        self.current_assistant_idx = null;
        self.last_visible_height = 0;
        self.layout.clear();
    }

    // ── Built-in convenience methods ──────────────────────────────

    /// Start a new assistant message.
    pub fn beginAssistantMessage(self: *Transcript) void {
        self.current_assistant_idx = null;
    }

    fn createAssistantMessage(self: *Transcript) ?*assistant_message_mod.AssistantMessage {
        const am = self.allocator.create(assistant_message_mod.AssistantMessage) catch return null;
        am.* = assistant_message_mod.AssistantMessage.init(self.allocator);
        am.theme = self.theme;
        am.hide_thinking_block = self.hide_thinking_block;
        if (!self.appendTranscriptItem(.{
            .component = am.component(),
            .kind = .assistant_message,
            .extra_height = 1,
            .deinit_ctx = @ptrCast(am),
            .deinit_fn = deinitAssistantMessage,
        })) {
            am.deinit();
            self.allocator.destroy(am);
            return null;
        }
        self.current_assistant_idx = self.items.items.len - 1;
        return am;
    }

    fn currentAssistant(self: *Transcript) ?*assistant_message_mod.AssistantMessage {
        const idx = self.current_assistant_idx orelse return null;
        if (idx >= self.items.items.len) return null;
        const item = &self.items.items[idx];
        if (item.kind != .assistant_message) return null;
        return @ptrCast(@alignCast(item.deinit_ctx.?));
    }

    /// Append streaming text content to the current assistant message.
    pub fn appendText(self: *Transcript, content_index: usize, delta: []const u8) void {
        var am = self.currentAssistant();
        if (am == null) am = self.createAssistantMessage();
        if (am) |assistant| {
            assistant.appendText(content_index, delta);
            const idx = self.current_assistant_idx orelse return;
            self.noteItemMutated(idx);
        }
    }

    /// Append streaming thinking content to the current assistant message.
    pub fn appendThinking(self: *Transcript, content_index: usize, delta: []const u8) void {
        var am = self.currentAssistant();
        if (am == null) am = self.createAssistantMessage();
        if (am) |assistant| {
            assistant.appendThinking(content_index, delta);
            const idx = self.current_assistant_idx orelse return;
            self.noteItemMutated(idx);
        }
    }

    pub fn setHideThinkingBlock(self: *Transcript, hide: bool) void {
        self.hide_thinking_block = hide;
        for (self.items.items, 0..) |*item, idx| {
            if (item.kind == .assistant_message) {
                const am: *assistant_message_mod.AssistantMessage = @ptrCast(@alignCast(item.deinit_ctx.?));
                am.setHideThinkingBlock(hide);
                self.noteItemMutated(idx);
            }
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

        self.current_assistant_idx = null;

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
        if (!self.appendTranscriptItem(.{
            .component = te.component(),
            .kind = .tool_execution,
            .tool_call_id = te.tool_call_id,
            .extra_height = 1, // spacer before tool (pi-mono: Spacer(1))
            .deinit_ctx = @ptrCast(te),
            .deinit_fn = ToolExecution.deinitItem,
        })) {
            te.deinit();
            return;
        }
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
        const idx = self.pending_tools.get(tool_call_id) orelse return;
        const te = self.getToolExecution(tool_call_id) orelse return;
        te.setArgs(args);
        self.noteItemMutated(idx);
    }

    /// Mark a tool execution as started.
    pub fn toolMarkExecutionStarted(self: *Transcript, tool_call_id: []const u8) void {
        const idx = self.pending_tools.get(tool_call_id) orelse return;
        const te = self.getToolExecution(tool_call_id) orelse return;
        te.markExecutionStarted();
        self.noteItemMutated(idx);
    }

    /// Mark args as complete on a tool execution.
    pub fn toolSetArgsComplete(self: *Transcript, tool_call_id: []const u8) void {
        const idx = self.pending_tools.get(tool_call_id) orelse return;
        const te = self.getToolExecution(tool_call_id) orelse return;
        te.setArgsComplete();
        self.noteItemMutated(idx);
    }

    /// Set partial result on a tool execution.
    pub fn toolSetPartialResult(self: *Transcript, tool_call_id: []const u8, result: ?AgentToolResult, is_error: bool) void {
        const idx = self.pending_tools.get(tool_call_id) orelse return;
        const te = self.getToolExecution(tool_call_id) orelse return;
        te.setPartialResult(result, is_error);
        // Re-dispatch the render hook so the tree view reflects
        // the new partial state. Tools without a render hook
        // no-op gracefully.
        self.refreshLuaRender(te);
        self.noteItemMutated(idx);
    }

    /// Set final result on a tool execution and remove from pending.
    pub fn toolSetFinalResult(self: *Transcript, tool_call_id: []const u8, result: ?AgentToolResult, is_error: bool) void {
        const idx = self.pending_tools.get(tool_call_id) orelse return;
        const te = self.getToolExecution(tool_call_id) orelse return;
        te.setFinalResult(result, is_error);
        _ = self.pending_tools.remove(tool_call_id);
        // Kick off the Lua render_result hook (if any) now that we
        // have a final result in hand. `refreshLuaRender` is a
        // no-op for tools without a registered render hook.
        self.refreshLuaRender(te);
        self.noteItemMutated(idx);
    }

    /// Pick up any precomputed render that the agent thread
    /// stashed for this tool call and assign it to the
    /// ToolExecution. Pure data move — does not touch the Lua
    /// state, so this is safe to call from the TUI thread without
    /// reaching into `lua_state` (which the agent thread owns since
    /// zi-wub.5/.6).
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
        te.lua_render_deinit = pending.deinit;
        te.lua_render_allocator = runner.allocator;
    }

    /// Toggle expansion state on all tool executions.
    pub fn setToolOutputExpanded(self: *Transcript, expanded: bool) void {
        for (self.items.items, 0..) |*item, idx| {
            if (item.kind == .tool_execution) {
                const te: *ToolExecution = @ptrCast(@alignCast(item.deinit_ctx.?));
                te.expanded = expanded;
                self.noteItemMutated(idx);
            }
        }
    }

    /// Add a user message bubble.
    pub fn addUserMessage(self: *Transcript, text: []const u8) void {
        self.current_assistant_idx = null;

        const md = self.allocator.create(markdown_mod.Markdown) catch return;
        md.* = markdown_mod.Markdown.init(self.allocator);
        md.padding_x = 1;
        // User messages render as filled bubbles, so they need a little
        // internal vertical padding to read as intentional chrome rather
        // than a background paint bug.
        md.padding_y = 1;
        md.bg = self.theme.bg(.user_message_bg);
        md.fg = self.theme.fg(.user_message_text);
        md.setContent(text);

        if (!self.appendTranscriptItem(.{
            .component = md.component(),
            .kind = .user_message,
            .extra_height = 1, // spacer before user message
            .deinit_ctx = @ptrCast(md),
            .deinit_fn = deinitMarkdown,
        })) {
            md.deinit();
            self.allocator.destroy(md);
            return;
        }
    }

    // ── Layout / scroll ───────────────────────────────────────────

    /// Total height of all items at the given width.
    pub fn totalHeight(self: *Transcript, width: u32) u32 {
        if (width == 0) return 0;
        self.ensureLayout(width);
        return self.layout.totalHeight();
    }

    /// Scroll to bottom so last content is visible.
    pub fn scrollToBottom(self: *Transcript, width: u32, visible_height: u32) void {
        self.last_visible_height = visible_height;
        _ = self.totalHeight(width);
        self.layout.scrollToBottom(visible_height);
    }

    pub fn scrollBy(self: *Transcript, width: u32, visible_height: u32, delta: i64) void {
        self.last_visible_height = visible_height;
        _ = self.totalHeight(width);
        self.layout.scrollBy(delta, visible_height);
    }

    pub fn scrollOffset(self: *Transcript) u32 {
        return self.layout.scrollOffset();
    }

    /// Clamp scroll offset against content height after shrink/layout changes.
    fn clampScroll(self: *Transcript) void {
        _ = self.totalHeight(self.last_render_width);
        self.layout.clampScroll(self.last_visible_height);
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
        self.ensureLayout(w);
        self.last_visible_height = h;
        self.layout.clampScroll(h);

        var screen_y: u32 = 0;
        const first = self.layout.findFirstVisible() orelse return;
        var idx = first.index;
        var skipped = first.skip_rows;

        while (idx < self.items.items.len and screen_y < h) : (idx += 1) {
            const item = &self.items.items[idx];
            const item_h = self.layout.itemHeight(idx);
            if (item_h == 0) continue;

            const remaining = item_h - skipped;
            const visible_h = @min(remaining, h - screen_y);
            const row_region = region.sub(0, screen_y, w, visible_h);
            self.renderItem(item, row_region, skipped, visible_h, w);

            screen_y += visible_h;
            skipped = 0;
        }
    }

    fn renderItem(self: *Transcript, item: *TranscriptItem, row_region: Region, skipped: u32, visible_h: u32, w: u32) void {
        switch (item.kind) {
            .tool_execution => {
                const te: *ToolExecution = @ptrCast(@alignCast(item.deinit_ctx.?));
                const saved = te.scroll_offset;
                const row_skip = skipped;
                if (item.extra_height > 0 and row_skip < item.extra_height) {
                    const spacer_visible = item.extra_height - row_skip;
                    if (visible_h > spacer_visible) {
                        const tool_region = row_region.sub(0, spacer_visible, w, visible_h - spacer_visible);
                        te.scroll_offset = 0;
                        te.render(tool_region);
                    }
                } else {
                    te.scroll_offset = row_skip -| item.extra_height;
                    te.render(row_region);
                }
                te.scroll_offset = saved;
            },
            .user_message => {
                const row_skip = skipped;
                if (row_skip == 0) {
                    if (visible_h > 1) {
                        const md_region = row_region.sub(0, 1, w, visible_h - 1);
                        const md: *markdown_mod.Markdown = @ptrCast(@alignCast(item.deinit_ctx.?));
                        const saved = md.scroll_offset;
                        md.scroll_offset = 0;
                        md.render(md_region);
                        md.scroll_offset = saved;
                    }
                } else {
                    const md: *markdown_mod.Markdown = @ptrCast(@alignCast(item.deinit_ctx.?));
                    const saved = md.scroll_offset;
                    md.scroll_offset = row_skip - 1;
                    md.render(row_region);
                    md.scroll_offset = saved;
                }
            },
            .assistant_message => {
                const am: *assistant_message_mod.AssistantMessage = @ptrCast(@alignCast(item.deinit_ctx.?));
                const saved = am.scroll_offset;
                const row_skip = skipped;
                if (item.extra_height > 0 and row_skip < item.extra_height) {
                    const spacer_visible = item.extra_height - row_skip;
                    if (visible_h > spacer_visible) {
                        const am_region = row_region.sub(0, spacer_visible, w, visible_h - spacer_visible);
                        am.scroll_offset = 0;
                        am.render(am_region);
                    }
                } else {
                    am.scroll_offset = row_skip -| item.extra_height;
                    am.render(row_region);
                }
                am.scroll_offset = saved;
            },
            .generic => {
                if (skipped == 0) {
                    item.component.render(row_region);
                } else {
                    self.renderGenericSlice(item.component, row_region, skipped);
                }
            },
        }
    }

    fn renderGenericSlice(self: *Transcript, comp: Component, row_region: Region, skipped: u32) void {
        if (row_region.width == 0 or row_region.height == 0) return;

        const total_h = comp.measure(row_region.width).preferred_height;
        if (total_h == 0 or skipped >= total_h) return;

        var scratch = Buffer.init(self.allocator, row_region.width, total_h) catch return;
        defer scratch.deinit();
        comp.render(scratch.region());
        blitRows(scratch.region(), row_region, skipped);
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
    transcript.appendText(0, "hello from assistant");

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

test "Transcript preserves manual scroll when assistant content grows" {
    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    transcript.beginAssistantMessage();
    transcript.appendText(0, "one two three four five six seven eight nine ten");
    transcript.scrollToBottom(12, 3);
    transcript.scrollBy(12, 3, -1);
    const before = transcript.scrollOffset();

    transcript.appendText(0, " eleven twelve thirteen fourteen");

    try testing.expectEqual(before, transcript.scrollOffset());
}

test "Transcript scrolls through tool output without repeating the first rows" {
    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    transcript.addToolExecution("tool-1", "bash", .{});

    var content = [_]AgentToolResult.ContentBlock{
        .{ .text = .{ .text = "line1\nline2\nline3\nline4\nline5\nline6" } },
    };
    transcript.toolSetFinalResult("tool-1", .{ .content = &content, .is_error = false }, false);
    transcript.scrollBy(20, 3, 4);

    var buf = try Buffer.init(testing.allocator, 20, 3);
    defer buf.deinit();
    transcript.render(buf.region());

    try testing.expectEqual(@as(u21, 'l'), buf.get(1, 0).grapheme.codepoint);
    try testing.expectEqual(@as(u21, '2'), buf.get(5, 0).grapheme.codepoint);
    try testing.expectEqual(@as(u21, 'l'), buf.get(1, 1).grapheme.codepoint);
    try testing.expectEqual(@as(u21, '3'), buf.get(5, 1).grapheme.codepoint);
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
    transcript.scrollBy(80, 1, 100);
    transcript.removeComponent(w3.component());
    // total height is now 1 (just w1), so scroll offset should be clamped to ≤ 1
    try testing.expect(transcript.scrollOffset() <= 1);
}

test "Transcript clearAll removes all items and resets state" {
    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    transcript.beginAssistantMessage();
    transcript.appendText(0, "hello");
    transcript.addUserMessage("user msg");

    try testing.expectEqual(@as(usize, 2), transcript.items.items.len);

    transcript.clearAll();

    try testing.expectEqual(@as(usize, 0), transcript.items.items.len);
    try testing.expectEqual(@as(?usize, null), transcript.current_assistant_idx);
    try testing.expectEqual(@as(u32, 0), transcript.scrollOffset());
}
