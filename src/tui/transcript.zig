const std = @import("std");
const component_mod = @import("component.zig");
const buffer_mod = @import("buffer.zig");
const cell_mod = @import("cell.zig");
const grapheme = @import("grapheme.zig");
const markdown_mod = @import("components/markdown.zig");
const assistant_message_mod = @import("components/assistant_message.zig");
const user_message_mod = @import("components/user_message.zig");
const tool_display_mod = @import("tool_display.zig");
const agent_mod = @import("../agent3/root.zig");
const agent_protocol = agent_mod.protocol;
const AgentToolResult = agent_protocol.AgentToolResult;
const json_util = @import("../ai/json_util.zig");
const theme_mod = @import("theme.zig");
const themes_builtin = @import("../themes/builtin.zig");
const display_wrap_mod = @import("display_wrap.zig");

const Measurement = component_mod.Measurement;
const Region = buffer_mod.Region;
const Color = cell_mod.Color;

// ── Transcript Item ───────────────────────────────────────────────

/// Type-erased transcript row interface.
///
/// Unlike the general TUI `Component` protocol, transcript rows MUST support
/// native slice rendering. The transcript is a viewport compositor and never
/// allocates full offscreen scratch surfaces just to crop visible rows.
pub const TranscriptRenderable = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        render_slice: *const fn (ptr: *anyopaque, region: Region, first_row: u32) void,
        measure: *const fn (ptr: *anyopaque, width: u32) Measurement,
        next_animation_deadline: *const fn (ptr: *anyopaque, now_ns: i128) ?i128,
        tick_animation: *const fn (ptr: *anyopaque, now_ns: i128) bool,
    };

    pub fn init(comptime T: type, ptr: *T) TranscriptRenderable {
        comptime {
            if (!@hasDecl(T, "renderSlice")) {
                @compileError(@typeName(T) ++ " must implement renderSlice(region, first_row) to live in the transcript");
            }
            if (!@hasDecl(T, "measure")) {
                @compileError(@typeName(T) ++ " must implement measure(width) to live in the transcript");
            }
        }

        const gen = struct {
            fn renderSlice(erased: *anyopaque, region: Region, first_row: u32) void {
                const self: *T = @ptrCast(@alignCast(erased));
                self.renderSlice(region, first_row);
            }
            fn measure(erased: *anyopaque, width: u32) Measurement {
                const self: *T = @ptrCast(@alignCast(erased));
                return self.measure(width);
            }
            fn nextAnimationDeadline(erased: *anyopaque, now_ns: i128) ?i128 {
                const self: *T = @ptrCast(@alignCast(erased));
                if (@hasDecl(T, "nextAnimationDeadline")) {
                    return self.nextAnimationDeadline(now_ns);
                }
                return null;
            }
            fn tickAnimation(erased: *anyopaque, now_ns: i128) bool {
                const self: *T = @ptrCast(@alignCast(erased));
                if (@hasDecl(T, "tickAnimation")) {
                    return self.tickAnimation(now_ns);
                }
                return false;
            }
        };

        return .{
            .ptr = @ptrCast(ptr),
            .vtable = &.{
                .render_slice = gen.renderSlice,
                .measure = gen.measure,
                .next_animation_deadline = gen.nextAnimationDeadline,
                .tick_animation = gen.tickAnimation,
            },
        };
    }

    pub fn eql(a: TranscriptRenderable, b: TranscriptRenderable) bool {
        return a.ptr == b.ptr and a.vtable == b.vtable;
    }

    pub fn renderSlice(self: TranscriptRenderable, region: Region, first_row: u32) void {
        self.vtable.render_slice(self.ptr, region, first_row);
    }

    pub fn measure(self: TranscriptRenderable, width: u32) Measurement {
        return self.vtable.measure(self.ptr, width);
    }

    pub fn nextAnimationDeadline(self: TranscriptRenderable, now_ns: i128) ?i128 {
        return self.vtable.next_animation_deadline(self.ptr, now_ns);
    }

    pub fn tickAnimation(self: TranscriptRenderable, now_ns: i128) bool {
        return self.vtable.tick_animation(self.ptr, now_ns);
    }
};

/// Behavior tag for transcript-owned items.
/// Renderables remain tagged for routing updates and typed retained-row access.
pub const ItemId = enum(u64) { _ };
pub const SemanticVersion = u64;

pub const ItemKind = enum {
    generic,
    assistant_message,
    user_message,
    queued_user_message,
    tool_execution,
};

/// Cleanup function type for owned items.
pub const DeinitFn = *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) void;

/// A single item in the transcript — slice-native renderable plus metadata.
///
/// Replaces the previous closed TranscriptRow union. Built-in types
/// (assistant, tool, user) are convenience constructors that set `kind` +
/// metadata. Extensions may inject arbitrary transcript renderables with
/// kind=.generic.
pub const TranscriptItem = struct {
    renderable: TranscriptRenderable,
    kind: ItemKind = .generic,
    retained_item_id: ?ItemId = null,
    retained_semantic_version: ?SemanticVersion = null,
    /// For tool_execution: route updates by ID via pending_tools HashMap.
    tool_call_id: ?[]const u8 = null,
    /// Owned cleanup context. Called on item removal/transcript clear.
    deinit_ctx: ?*anyopaque = null,
    deinit_fn: ?DeinitFn = null,
    /// Extra height added outside the renderable (e.g., spacer before user message).
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

const SelectionPoint = struct {
    row: u32,
    col: u32,
};

const NormalizedSelection = struct {
    start: SelectionPoint,
    end: SelectionPoint,
};

const AutoScrollDirection = enum {
    none,
    up,
    down,
};

pub const DragZone = enum {
    inside,
    above,
    below,
};

const ActiveSelection = struct {
    anchor: SelectionPoint,
    focus: SelectionPoint,
    dragging: bool = true,
    auto_scroll: AutoScrollDirection = .none,
    next_tick_ns: ?i128 = null,
};

const SelectionState = union(enum) {
    inactive,
    active: ActiveSelection,
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
        try self.items.append(self.allocator, .{});
        errdefer self.items.items.len -= 1;
        try self.heights.rebuild(self.items.items);
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

    fn captureAnchor(self: *const TranscriptLayout) ?FirstVisible {
        if (self.follow_bottom) return null;
        return self.findFirstVisible();
    }

    fn restoreAnchor(self: *TranscriptLayout, anchor: ?FirstVisible) void {
        const first = anchor orelse return;
        if (first.index >= self.items.items.len) return;
        const item_h = self.itemHeight(first.index);
        const max_skip = if (item_h > 0) item_h - 1 else 0;
        self.viewport_offset = self.prefixHeightBefore(first.index) + @min(first.skip_rows, max_skip);
    }

    fn remeasureItemNoAnchor(self: *TranscriptLayout, index: usize, ctx: *anyopaque, width: u32, measure_fn: *const fn (ctx: *anyopaque, index: usize, width: u32) u32) void {
        if (index >= self.items.items.len) return;

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

    fn remeasureItem(self: *TranscriptLayout, index: usize, ctx: *anyopaque, width: u32, measure_fn: *const fn (ctx: *anyopaque, index: usize, width: u32) u32) void {
        if (index >= self.items.items.len) return;
        if (self.layout_width != width) {
            self.layout_width = width;
            self.invalidateAll();
        }

        const anchor = self.captureAnchor();
        self.remeasureItemNoAnchor(index, ctx, width, measure_fn);
        self.restoreAnchor(anchor);
    }

    fn remeasureAll(self: *TranscriptLayout, ctx: *anyopaque, width: u32, measure_fn: *const fn (ctx: *anyopaque, index: usize, width: u32) u32) void {
        const anchor = self.captureAnchor();
        self.layout_width = width;
        var idx: usize = 0;
        while (idx < self.items.items.len) : (idx += 1) {
            self.remeasureItemNoAnchor(idx, ctx, width, measure_fn);
        }
        self.restoreAnchor(anchor);
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
        if (visible_height == 0) return 0;
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

pub const ToolExecutionRowModel = struct {
    tool_call_id: ?[]u8 = null,
    tool_name: ?[]u8 = null,
    args: std.json.Value = .null,
    args_json_source: ?[]u8 = null,
    result: ?AgentToolResult = null,
    is_partial: bool = true,
    is_error: bool = false,
    execution_started: bool = false,
    args_complete: bool = false,

    pub fn clone(self: ToolExecutionRowModel, allocator: std.mem.Allocator) !ToolExecutionRowModel {
        const tool_call_id = if (self.tool_call_id) |tool_call_id|
            try allocator.dupe(u8, tool_call_id)
        else
            null;
        errdefer if (tool_call_id) |owned| allocator.free(owned);

        const tool_name = if (self.tool_name) |tool_name|
            try allocator.dupe(u8, tool_name)
        else
            null;
        errdefer if (tool_name) |owned| allocator.free(owned);

        const args = try json_util.cloneJsonValue(allocator, self.args);
        errdefer json_util.freeJsonValue(allocator, args);

        const args_json_source = if (self.args_json_source) |source|
            try allocator.dupe(u8, source)
        else
            null;
        errdefer if (args_json_source) |source| allocator.free(source);

        const result = if (self.result) |result|
            try result.clone(allocator)
        else
            null;
        errdefer if (result) |owned| owned.free(allocator);

        return .{
            .tool_call_id = tool_call_id,
            .tool_name = tool_name,
            .args = args,
            .args_json_source = args_json_source,
            .result = result,
            .is_partial = self.is_partial,
            .is_error = self.is_error,
            .execution_started = self.execution_started,
            .args_complete = self.args_complete,
        };
    }

    pub fn deinit(self: *ToolExecutionRowModel, allocator: std.mem.Allocator) void {
        if (self.result) |result| result.free(allocator);
        json_util.freeJsonValue(allocator, self.args);
        if (self.args_json_source) |source| allocator.free(source);
        if (self.tool_name) |tool_name| allocator.free(tool_name);
        if (self.tool_call_id) |tool_call_id| allocator.free(tool_call_id);
        self.* = .{};
    }
};

/// State for a single tool execution within the transcript.
/// Owns a stable row model plus presentation-local state (expansion,
/// renderer caches, and retained renderer state).
///
/// Rendering uses optional ToolRenderer functions for per-tool formatting.
/// Falls back to: bold(tool_name) for call, truncated text for result.
pub const ToolExecution = struct {
    model: ToolExecutionRowModel = .{},
    expanded: bool = false,
    renderer: tool_display_mod.ToolRenderer = .{},
    renderer_state: ?*anyopaque = null,
    allocator: std.mem.Allocator,
    theme: *const theme_mod.Theme = undefined,
    measured_content_width: u32 = 0,
    measured_result_height: u32 = 0,

    pub fn deinit(self: *ToolExecution) void {
        if (self.renderer.deinit_state) |deinit_fn| {
            if (self.renderer_state) |state| deinit_fn(state, self.allocator);
        }
        self.model.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn deinitItem(ctx: *anyopaque, _: std.mem.Allocator) void {
        const self: *ToolExecution = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    pub fn setOwnedModel(self: *ToolExecution, model: *ToolExecutionRowModel) !void {
        const incoming_tool_call_id = model.tool_call_id orelse return error.InvalidToolExecutionRowModel;
        const incoming_tool_name = model.tool_name orelse return error.InvalidToolExecutionRowModel;
        if (self.model.tool_call_id) |current| {
            if (!std.mem.eql(u8, current, incoming_tool_call_id)) {
                return error.ToolExecutionIdentityMismatch;
            }
        }
        if (self.model.tool_name) |current| {
            if (!std.mem.eql(u8, current, incoming_tool_name)) {
                return error.ToolExecutionIdentityMismatch;
            }
        }

        var owned_model = model.*;
        model.* = .{};
        const had_result = self.model.result != null;

        if (self.model.tool_call_id) |current| {
            self.allocator.free(owned_model.tool_call_id.?);
            owned_model.tool_call_id = current;
            self.model.tool_call_id = null;
        }
        if (self.model.tool_name) |current| {
            self.allocator.free(owned_model.tool_name.?);
            owned_model.tool_name = current;
            self.model.tool_name = null;
        }

        self.model.deinit(self.allocator);
        self.model = owned_model;
        self.measured_content_width = 0;
        self.measured_result_height = 0;
        self.notifyArgsChanged();
        if (had_result or self.model.result != null) self.notifyResultChanged();
    }

    pub fn setExpanded(self: *ToolExecution, expanded: bool) void {
        if (self.expanded == expanded) return;
        self.expanded = expanded;
        self.measured_content_width = 0;
        self.measured_result_height = 0;
        if (self.renderer.expanded_changed) |changed_fn| {
            var ctx = self.makeStateContext();
            changed_fn(&ctx);
        }
    }

    fn notifyArgsChanged(self: *ToolExecution) void {
        if (self.renderer.args_changed) |changed_fn| {
            var ctx = self.makeStateContext();
            changed_fn(&ctx);
        }
    }

    fn notifyResultChanged(self: *ToolExecution) void {
        if (self.renderer.result_changed) |changed_fn| {
            var ctx = self.makeStateContext();
            changed_fn(&ctx);
        }
    }

    // ── Rendering ─────────────────────────────────────────────────

    fn bgColor(self: *ToolExecution) Color {
        _ = self;
        return Color.default;
    }

    // Vertical padding inside the bg box (pi-mono: Box(paddingX=1, paddingY=1))
    const padding_y: u32 = 1;

    pub fn measure(self: *ToolExecution, width: u32) Measurement {
        if (width == 0) return .{ .min_height = 0, .preferred_height = 0 };
        const content_w = if (width > 2) width - 2 else 1;
        const result_h = self.measureResult(content_w);
        self.measured_content_width = content_w;
        self.measured_result_height = result_h;
        var h: u32 = padding_y; // top padding
        h += 1; // call line
        h += result_h;
        h += padding_y; // bottom padding
        return .{ .min_height = 1, .preferred_height = @max(1, h) };
    }

    pub fn render(self: *ToolExecution, region: Region) void {
        self.renderSlice(region, 0);
    }

    pub fn renderSlice(self: *ToolExecution, region: Region, first_row: u32) void {
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
        const result_h = self.ensureMeasuredResultHeight(content_w);
        const total_h = padding_y + 1 + result_h + padding_y;
        var row: u32 = 0;
        var virtual_row: u32 = first_row;

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
                self.renderResultFromOffset(result_region, result_skip);
                break;
            }

            break;
        }
    }

    fn ensureMeasuredResultHeight(self: *ToolExecution, width: u32) u32 {
        if (self.measured_content_width != width) {
            self.measured_content_width = width;
            self.measured_result_height = self.measureResult(width);
        }
        return self.measured_result_height;
    }

    fn renderCall(self: *ToolExecution, region: Region) void {
        if (self.renderer.render_call) |render_fn| {
            var ctx = self.makeRenderContext(region);
            render_fn(&ctx);
        } else {
            self.renderCallDefault(region);
        }
    }

    fn renderCallDefault(self: *ToolExecution, region: Region) void {
        _ = region.writeStr(0, 0, self.model.tool_name orelse "", self.theme.fg(.tool_title), Color.default, .{ .bold = true });
    }

    fn renderResultFromOffset(self: *ToolExecution, region: Region, skip_rows: u32) void {
        const total_rows = self.ensureMeasuredResultHeight(region.width);
        if (skip_rows >= total_rows) return;

        // pi-mono only invokes result renderers once a tool has
        // actually produced a result. Keep the same contract here so
        // pending tools do not render placeholder/malformed result
        // states before projected args/results are complete.
        if (self.model.result == null) return;

        if (self.renderer.render_result_slice) |render_fn| {
            var ctx = self.makeRenderContext(region);
            render_fn(&ctx, skip_rows);
            return;
        }

        self.renderResultPlainTextFromOffset(region, skip_rows);
    }

    fn renderResultPlainTextFromOffset(self: *ToolExecution, region: Region, skip_rows: u32) void {
        const result_text = self.getResultText() orelse return;
        defer self.allocator.free(result_text);

        const fg = if (self.model.is_error) self.theme.fg(.@"error") else self.theme.fg(.tool_output);
        const w: usize = @intCast(region.width);
        const lines = display_wrap_mod.wordWrap(result_text, w, self.allocator) catch return;
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
            _ = region.writeStr(0, row, hint, self.theme.fg(.dim), Color.default, .{});
        }
    }

    fn measureResult(self: *ToolExecution, width: u32) u32 {
        if (self.model.result == null) return 0;
        if (self.renderer.measure_result) |measure_fn| {
            var ctx = self.makeMeasureContext(width);
            return measure_fn(&ctx);
        }
        return self.measureResultPlainText(width);
    }

    fn measureResultPlainText(self: *ToolExecution, width: u32) u32 {
        const result_text = self.getResultText() orelse return 0;
        defer self.allocator.free(result_text);

        const w: usize = @intCast(width);
        const lines = display_wrap_mod.wordWrap(result_text, w, self.allocator) catch return 1;
        defer self.allocator.free(lines);

        if (self.expanded) return @intCast(lines.len);
        const max_preview: u32 = 5;
        if (lines.len > max_preview) return max_preview + 1;
        return @intCast(lines.len);
    }

    /// Extract joined text from result content blocks.
    fn getResultText(self: *ToolExecution) ?[]u8 {
        const result = self.model.result orelse return null;
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

    fn makeStateContext(self: *ToolExecution) tool_display_mod.ToolStateContext {
        return .{
            .tool_name = self.model.tool_name orelse "",
            .tool_call_id = self.model.tool_call_id orelse "",
            .args = self.model.args,
            .result = self.model.result,
            .is_partial = self.model.is_partial,
            .is_error = self.model.is_error,
            .expanded = self.expanded,
            .execution_started = self.model.execution_started,
            .args_complete = self.model.args_complete,
            .allocator = self.allocator,
            .state = self.renderer_state,
        };
    }

    fn makeMeasureContext(self: *ToolExecution, width: u32) tool_display_mod.ToolMeasureContext {
        return .{
            .tool_name = self.model.tool_name orelse "",
            .tool_call_id = self.model.tool_call_id orelse "",
            .args = self.model.args,
            .result = self.model.result,
            .is_partial = self.model.is_partial,
            .is_error = self.model.is_error,
            .expanded = self.expanded,
            .execution_started = self.model.execution_started,
            .args_complete = self.model.args_complete,
            .allocator = self.allocator,
            .state = self.renderer_state,
            .width = width,
        };
    }

    fn makeRenderContext(self: *ToolExecution, region: Region) tool_display_mod.ToolRenderContext {
        return .{
            .tool_name = self.model.tool_name orelse "",
            .tool_call_id = self.model.tool_call_id orelse "",
            .args = self.model.args,
            .result = self.model.result,
            .is_partial = self.model.is_partial,
            .is_error = self.model.is_error,
            .expanded = self.expanded,
            .execution_started = self.model.execution_started,
            .args_complete = self.model.args_complete,
            .theme = self.theme,
            .allocator = self.allocator,
            .state = self.renderer_state,
            .region = region,
            .width = region.width,
        };
    }
};

test "tool execution renderSlice starts inside a wrapped tool result" {
    var buffer = try buffer_mod.Buffer.init(testing.allocator, 6, 3);
    defer buffer.deinit();

    const content = try testing.allocator.alloc(AgentToolResult.ContentBlock, 1);
    content[0] = .{ .text = .{ .text = try testing.allocator.dupe(u8, "abcdef\nXYZ\n") } };
    var tool = ToolExecution{
        .allocator = testing.allocator,
        .theme = themes_builtin.dark(),
        .expanded = true,
        .model = .{
            .tool_call_id = try testing.allocator.dupe(u8, "call-1"),
            .tool_name = try testing.allocator.dupe(u8, "bash"),
            .result = .{ .content = content },
            .is_partial = false,
            .execution_started = true,
            .args_complete = true,
        },
    };
    defer tool.model.deinit(testing.allocator);

    tool.renderSlice(buffer.region(), 3);

    try testing.expectEqual(@as(u21, 'e'), buffer.get(1, 0).grapheme.codepoint);
    try testing.expectEqual(@as(u21, 'f'), buffer.get(2, 0).grapheme.codepoint);
    try testing.expectEqual(@as(u21, 'X'), buffer.get(1, 1).grapheme.codepoint);
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

fn deinitUserMessage(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const um: *user_message_mod.UserMessage = @ptrCast(@alignCast(ctx));
    um.deinit();
    allocator.destroy(um);
}

// ── Transcript ────────────────────────────────────────────────────

/// Scrollable retained transcript container with slice-native item storage.
///
/// Items are owned transcript renderables plus optional metadata used for
/// retained reconciliation (`retained_item_id`) and keyed tool-row lookup
/// (`tool_call_id`). The transcript owns retained item order, layout, scroll,
/// selection, and viewport rendering. Conversation semantics are projected into
/// retained rows before they reach this container.
pub const Transcript = struct {
    items: std.ArrayListUnmanaged(TranscriptItem) = .empty,
    /// Fast lookup: tool_call_id → item index for retained tool-row updates.
    pending_tools: std.StringHashMapUnmanaged(usize) = .{},
    /// Fast lookup: retained item_id → item index for retained reconciliation.
    retained_items: std.AutoHashMapUnmanaged(ItemId, usize) = .empty,
    layout: TranscriptLayout,

    allocator: std.mem.Allocator,
    theme: *const theme_mod.Theme = undefined,
    hide_thinking_block: bool = false,
    /// Cached viewport height for scroll clamping / sticky-end updates.
    last_visible_height: u32 = 0,
    /// Cached from last render() call, used by clampScroll().
    last_render_width: u32 = 80,

    selection: SelectionState = .inactive,

    pub fn init(allocator: std.mem.Allocator) Transcript {
        return .{
            .allocator = allocator,
            .theme = themes_builtin.dark(),
            .layout = TranscriptLayout.init(allocator),
        };
    }

    pub fn deinit(self: *Transcript) void {
        self.cancelSelection();
        for (self.items.items) |*item| item.deinit(self.allocator);
        self.items.deinit(self.allocator);
        self.pending_tools.deinit(self.allocator);
        self.retained_items.deinit(self.allocator);
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
        const idx = self.items.items.len - 1;
        if (item.retained_item_id) |item_id| {
            self.retained_items.put(self.allocator, item_id, idx) catch {
                _ = self.items.pop();
                self.layout.removeItem(idx);
                return false;
            };
        }
        if (item.tool_call_id) |tool_call_id| {
            self.pending_tools.put(self.allocator, tool_call_id, idx) catch {
                if (item.retained_item_id) |item_id| _ = self.retained_items.remove(item_id);
                _ = self.items.pop();
                self.layout.removeItem(idx);
                return false;
            };
        }
        self.noteAppendedItem();
        return true;
    }

    fn noteItemMutated(self: *Transcript, index: usize) void {
        if (index >= self.items.items.len) return;
        self.layout.invalidate(index);
        self.remeasureItem(index);
        self.syncScrollAfterLayout();
    }

    pub fn itemMutatedAt(self: *Transcript, index: usize) void {
        self.noteItemMutated(index);
    }

    // ── External renderable API ───────────────────────────────────

    /// Append an arbitrary transcript item.
    pub fn addItem(self: *Transcript, item: TranscriptItem) bool {
        return self.appendTranscriptItem(item);
    }

    /// Append an arbitrary transcript renderable.
    pub fn addRenderable(self: *Transcript, renderable: TranscriptRenderable) void {
        _ = self.addItem(.{ .renderable = renderable });
    }

    /// Remove a specific transcript renderable by identity.
    pub fn removeRenderable(self: *Transcript, renderable: TranscriptRenderable) void {
        var i: usize = 0;
        while (i < self.items.items.len) {
            if (TranscriptRenderable.eql(self.items.items[i].renderable, renderable)) {
                self.removeItemAt(i);
                return; // remove first match only
            }
            i += 1;
        }
    }

    pub fn removeItemAt(self: *Transcript, index: usize) void {
        if (index >= self.items.items.len) return;
        var item = self.items.items[index];
        if (item.tool_call_id) |id| {
            _ = self.pending_tools.remove(id);
        }
        if (item.retained_item_id) |item_id| {
            _ = self.retained_items.remove(item_id);
        }
        item.deinit(self.allocator);
        _ = self.items.orderedRemove(index);
        self.layout.removeItem(index);
        self.reindexMaps(index);
        self.clampScroll();
    }

    pub fn truncateFrom(self: *Transcript, start_index: usize) void {
        if (start_index >= self.items.items.len) return;
        while (self.items.items.len > start_index) {
            self.removeItemAt(start_index);
        }
    }

    /// Remove all items and reset state. Used on session reset / /clear.
    pub fn clearAll(self: *Transcript) void {
        self.cancelSelection();
        for (self.items.items) |*item| item.deinit(self.allocator);
        self.items.items.len = 0;
        self.pending_tools.clearRetainingCapacity();
        self.retained_items.clearRetainingCapacity();
        self.last_visible_height = 0;
        self.layout.clear();
    }

    // ── Built-in retained row mutators ────────────────────────────

    pub fn assistantMessageAt(self: *Transcript, index: usize) ?*assistant_message_mod.AssistantMessage {
        if (index >= self.items.items.len) return null;
        const item = &self.items.items[index];
        if (item.kind != .assistant_message) return null;
        return @ptrCast(@alignCast(item.deinit_ctx.?));
    }

    pub fn toolExecutionAt(self: *Transcript, index: usize) ?*ToolExecution {
        if (index >= self.items.items.len) return null;
        const item = &self.items.items[index];
        if (item.kind != .tool_execution) return null;
        return @ptrCast(@alignCast(item.deinit_ctx.?));
    }

    pub fn clearToolRoutingAt(self: *Transcript, index: usize) void {
        if (index >= self.items.items.len) return;
        const item = &self.items.items[index];
        if (item.tool_call_id) |tool_call_id| {
            _ = self.pending_tools.remove(tool_call_id);
            item.tool_call_id = null;
        }
    }

    fn reindexMaps(self: *Transcript, start_index: usize) void {
        var tool_iter = self.pending_tools.iterator();
        while (tool_iter.next()) |entry| {
            if (entry.value_ptr.* >= start_index) {
                const tool_index = self.findToolExecutionIndex(entry.key_ptr.*) orelse continue;
                entry.value_ptr.* = tool_index;
            }
        }
        var retained_iter = self.retained_items.iterator();
        while (retained_iter.next()) |entry| {
            if (entry.value_ptr.* >= start_index) {
                const retained_index = self.findRetainedItemIndex(entry.key_ptr.*) orelse continue;
                entry.value_ptr.* = retained_index;
            }
        }
    }

    pub fn findToolExecutionIndex(self: *Transcript, tool_call_id: []const u8) ?usize {
        for (self.items.items, 0..) |item, idx| {
            if (item.tool_call_id) |candidate| {
                if (std.mem.eql(u8, candidate, tool_call_id)) return idx;
            }
        }
        return null;
    }

    pub fn findRetainedItemIndex(self: *Transcript, item_id: ItemId) ?usize {
        const idx = self.retained_items.get(item_id) orelse return null;
        if (idx >= self.items.items.len) return null;
        const item = self.items.items[idx];
        if (item.retained_item_id != null and item.retained_item_id.? == item_id) return idx;
        for (self.items.items, 0..) |candidate, search_idx| {
            if (candidate.retained_item_id != null and candidate.retained_item_id.? == item_id) return search_idx;
        }
        return null;
    }

    pub fn insertItemAt(self: *Transcript, index: usize, item: TranscriptItem) bool {
        const insert_index = @min(index, self.items.items.len);
        self.items.insert(self.allocator, insert_index, item) catch return false;
        errdefer _ = self.items.orderedRemove(insert_index);
        self.layout.items.insert(self.layout.allocator, insert_index, .{}) catch {
            _ = self.items.orderedRemove(insert_index);
            return false;
        };
        self.layout.heights.rebuild(self.layout.items.items) catch {
            _ = self.layout.items.orderedRemove(insert_index);
            _ = self.items.orderedRemove(insert_index);
            return false;
        };
        self.layout.dirty_count += 1;
        if (item.retained_item_id) |item_id| {
            self.retained_items.put(self.allocator, item_id, insert_index) catch {
                _ = self.layout.items.orderedRemove(insert_index);
                self.layout.heights.rebuild(self.layout.items.items) catch {};
                if (self.layout.dirty_count > 0) self.layout.dirty_count -= 1;
                _ = self.items.orderedRemove(insert_index);
                return false;
            };
        }
        self.reindexMaps(insert_index);
        if (item.tool_call_id) |tool_call_id| {
            self.pending_tools.put(self.allocator, tool_call_id, insert_index) catch {};
        }
        self.remeasureItem(insert_index);
        self.syncScrollAfterLayout();
        return true;
    }

    pub fn replaceItemAt(self: *Transcript, index: usize, item: TranscriptItem) bool {
        if (index >= self.items.items.len) return false;
        var old_item = self.items.items[index];
        if (old_item.tool_call_id) |id| _ = self.pending_tools.remove(id);
        if (old_item.retained_item_id) |item_id| _ = self.retained_items.remove(item_id);
        self.items.items[index] = item;
        if (item.retained_item_id) |item_id| {
            self.retained_items.put(self.allocator, item_id, index) catch {
                self.items.items[index] = old_item;
                if (old_item.tool_call_id) |id| self.pending_tools.put(self.allocator, id, index) catch {};
                if (old_item.retained_item_id) |old_item_id| self.retained_items.put(self.allocator, old_item_id, index) catch {};
                return false;
            };
        }
        if (item.tool_call_id) |tool_call_id| self.pending_tools.put(self.allocator, tool_call_id, index) catch {};
        old_item.deinit(self.allocator);
        self.noteItemMutated(index);
        return true;
    }

    pub fn moveItem(self: *Transcript, from_index: usize, to_index: usize) void {
        if (from_index >= self.items.items.len or to_index >= self.items.items.len or from_index == to_index) return;
        const item = self.items.orderedRemove(from_index);
        self.items.insert(self.allocator, to_index, item) catch {
            self.items.insert(self.allocator, from_index, item) catch unreachable;
            return;
        };
        const layout_item = self.layout.items.orderedRemove(from_index);
        self.layout.items.insert(self.layout.allocator, to_index, layout_item) catch {
            _ = self.layout.items.orderedRemove(to_index);
            self.layout.items.insert(self.layout.allocator, from_index, layout_item) catch unreachable;
            return;
        };
        self.layout.heights.rebuild(self.layout.items.items) catch return;
        self.reindexMaps(@min(from_index, to_index));
        self.clampScroll();
    }

    pub fn retainedItemSemanticVersionAt(self: *Transcript, index: usize) ?SemanticVersion {
        if (index >= self.items.items.len) return null;
        return self.items.items[index].retained_semantic_version;
    }

    /// O(1) check for the P2 retain short-circuit: is there already a
    /// retained row for this item_id with exactly this semantic_version?
    /// If true, callers may emit a metadata-only DesiredItem (row=null)
    /// and skip the full row-build cost.
    pub fn hasRetainedMatch(self: *Transcript, item_id: ItemId, version: SemanticVersion) bool {
        const idx = self.retained_items.get(item_id) orelse return false;
        if (idx >= self.items.items.len) return false;
        const item = self.items.items[idx];
        if (item.retained_item_id == null or item.retained_item_id.? != item_id) return false;
        return item.retained_semantic_version == version;
    }

    pub fn isFollowingBottom(self: *Transcript) bool {
        return self.layout.follow_bottom;
    }

    /// Clear any pending tool-result routing state.
    pub fn clearPendingToolRouting(self: *Transcript) void {
        self.pending_tools.clearRetainingCapacity();
    }

    /// Toggle expansion state on all tool executions.
    pub fn setToolOutputExpanded(self: *Transcript, expanded: bool) void {
        for (self.items.items, 0..) |*item, idx| {
            if (item.kind == .tool_execution) {
                const te: *ToolExecution = @ptrCast(@alignCast(item.deinit_ctx.?));
                te.setExpanded(expanded);
                self.noteItemMutated(idx);
            }
        }
    }

    // ── Selection ────────────────────────────────────────────────

    pub fn beginSelection(self: *Transcript, width: u32, visible_height: u32, local_x: u32, local_y: u32) bool {
        if (visible_height == 0 or width == 0) return false;
        const point = self.selectionPointForLocal(width, visible_height, local_x, local_y) orelse return false;
        self.last_visible_height = visible_height;
        self.layout.follow_bottom = false;
        self.selection = .{ .active = .{
            .anchor = point,
            .focus = point,
        } };
        return true;
    }

    pub fn updateSelection(self: *Transcript, width: u32, visible_height: u32, local_x: u32, local_y: u32, zone: DragZone, now_ns: i128) bool {
        const active = switch (self.selection) {
            .inactive => return false,
            .active => |*active| active,
        };

        self.last_visible_height = visible_height;
        const total = self.totalHeight(width);
        if (total == 0 or visible_height == 0) return false;

        const clamped_x = if (width == 0) 0 else @min(local_x, width - 1);
        active.focus.col = clamped_x;
        switch (zone) {
            .inside => {
                const point = self.selectionPointForLocal(width, visible_height, clamped_x, local_y) orelse return false;
                active.focus = point;
                self.disarmAutoScroll(active);
            },
            .above => {
                active.focus.row = self.layout.scrollOffset();
                self.armAutoScroll(active, .up, now_ns);
            },
            .below => {
                const last_visible_row = self.layout.scrollOffset() + @min(visible_height - 1, total - 1);
                active.focus.row = @min(last_visible_row, total - 1);
                self.armAutoScroll(active, .down, now_ns);
            },
        }
        return true;
    }

    pub fn endSelection(self: *Transcript, width: u32, visible_height: u32, local_x: u32, local_y: u32, zone: DragZone, now_ns: i128) bool {
        const updated = self.updateSelection(width, visible_height, local_x, local_y, zone, now_ns);
        const active = switch (self.selection) {
            .inactive => return updated,
            .active => |*active| active,
        };
        active.dragging = false;
        self.disarmAutoScroll(active);
        return updated;
    }

    pub fn cancelSelection(self: *Transcript) void {
        self.selection = .inactive;
    }

    pub fn hasSelection(self: *Transcript, width: u32) bool {
        return self.normalizedSelection(width) != null;
    }

    pub fn selectedText(self: *Transcript, allocator: std.mem.Allocator, width: u32) !?[]u8 {
        const selection = self.normalizedSelection(width) orelse return null;
        if (width == 0) return null;

        var scratch = try Buffer.init(allocator, width, 1);
        defer scratch.deinit();

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);

        var row = selection.start.row;
        while (row <= selection.end.row) : (row += 1) {
            scratch.clear();
            self.renderAbsoluteRow(scratch.region(), width, row);
            const used_cols = rowUsedColumns(scratch.region(), 0);
            const start_col = if (row == selection.start.row) @min(selection.start.col, used_cols) else 0;
            const end_col = if (row == selection.end.row) @min(selection.end.col, used_cols) else used_cols;
            if (row != selection.start.row) try out.append(allocator, '\n');
            try appendRowColumns(&out, allocator, scratch.region(), 0, start_col, end_col);
        }

        const owned = try out.toOwnedSlice(allocator);
        if (owned.len == 0) {
            allocator.free(owned);
            return null;
        }
        return owned;
    }

    fn selectionPointForLocal(self: *Transcript, width: u32, visible_height: u32, local_x: u32, local_y: u32) ?SelectionPoint {
        const total = self.totalHeight(width);
        if (total == 0 or visible_height == 0) return null;
        const clamped_y = @min(local_y, visible_height - 1);
        const row = @min(self.layout.scrollOffset() + clamped_y, total - 1);
        const col = if (width == 0) 0 else @min(local_x, width - 1);
        return .{ .row = row, .col = col };
    }

    fn normalizedSelection(self: *Transcript, width: u32) ?NormalizedSelection {
        const active = switch (self.selection) {
            .inactive => return null,
            .active => |active| active,
        };
        const total = self.totalHeight(width);
        if (total == 0) return null;

        var anchor = active.anchor;
        var focus = active.focus;
        const max_row = total - 1;
        anchor.row = @min(anchor.row, max_row);
        focus.row = @min(focus.row, max_row);

        if (anchor.row == focus.row and anchor.col == focus.col) return null;
        const anchor_before_focus = anchor.row < focus.row or (anchor.row == focus.row and anchor.col < focus.col);
        return if (anchor_before_focus)
            .{ .start = anchor, .end = focus }
        else
            .{ .start = focus, .end = anchor };
    }

    fn armAutoScroll(self: *Transcript, active: *ActiveSelection, dir: AutoScrollDirection, now_ns: i128) void {
        _ = self;
        active.auto_scroll = dir;
        active.next_tick_ns = now_ns + 50 * std.time.ns_per_ms;
    }

    fn disarmAutoScroll(self: *Transcript, active: *ActiveSelection) void {
        _ = self;
        active.auto_scroll = .none;
        active.next_tick_ns = null;
    }

    fn tickSelectionAutoScroll(self: *Transcript, now_ns: i128) bool {
        const active = switch (self.selection) {
            .inactive => return false,
            .active => |*active| active,
        };
        const dir = active.auto_scroll;
        const due = active.next_tick_ns orelse return false;
        if (dir == .none or now_ns < due or self.last_visible_height == 0) return false;

        const total = self.totalHeight(self.last_render_width);
        if (total == 0) {
            self.disarmAutoScroll(active);
            return false;
        }

        switch (dir) {
            .up => {
                if (self.layout.scrollOffset() == 0) {
                    self.disarmAutoScroll(active);
                    return false;
                }
                self.layout.scrollBy(-1, self.last_visible_height);
                if (active.focus.row > 0) active.focus.row -= 1;
            },
            .down => {
                const max_scroll = self.layout.maxScrollOffset(self.last_visible_height);
                if (self.layout.scrollOffset() >= max_scroll) {
                    self.disarmAutoScroll(active);
                    return false;
                }
                self.layout.scrollBy(1, self.last_visible_height);
                active.focus.row = @min(active.focus.row + 1, total - 1);
            },
            .none => return false,
        }
        active.next_tick_ns = now_ns + 50 * std.time.ns_per_ms;
        return true;
    }

    fn renderAbsoluteRow(self: *Transcript, region: Region, width: u32, absolute_row: u32) void {
        self.ensureLayout(width);
        const total = self.layout.totalHeight();
        if (absolute_row >= total) return;

        const idx = self.layout.heights.lowerBound(absolute_row);
        if (idx >= self.items.items.len) return;
        const item_start = self.layout.prefixHeightBefore(idx);
        const item = &self.items.items[idx];
        self.renderItem(item, region, absolute_row - item_start, region.height, width);
    }

    fn rowSelectedColumnRange(self: *Transcript, absolute_row: u32, max_cols: u32) ?struct { start_col: u32, end_col: u32 } {
        const selection = self.normalizedSelection(self.last_render_width) orelse return null;
        if (absolute_row < selection.start.row or absolute_row > selection.end.row) return null;

        var start_col: u32 = 0;
        var end_col: u32 = max_cols;
        if (absolute_row == selection.start.row) start_col = @min(selection.start.col, max_cols);
        if (absolute_row == selection.end.row) end_col = @min(selection.end.col, max_cols);
        if (start_col >= end_col) return null;
        return .{ .start_col = start_col, .end_col = end_col };
    }

    fn renderSelectionOverlay(self: *Transcript, region: Region) void {
        const selection = self.normalizedSelection(self.last_render_width) orelse return;
        if (region.height == 0 or region.width == 0) return;

        var screen_row: u32 = 0;
        while (screen_row < region.height) : (screen_row += 1) {
            const absolute_row = self.layout.scrollOffset() + screen_row;
            if (absolute_row < selection.start.row or absolute_row > selection.end.row) continue;
            const used_cols = rowUsedColumns(region, screen_row);
            const range = self.rowSelectedColumnRange(absolute_row, used_cols) orelse continue;
            var col = range.start_col;
            while (col < range.end_col and col < region.width) : (col += 1) {
                var cell = region.get(col, screen_row);
                cell.bg = self.theme.bg(.selected_bg);
                region.set(col, screen_row, cell);
            }
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

    pub fn nextAnimationDeadline(self: *Transcript, now_ns: i128) ?i128 {
        var next_deadline: ?i128 = switch (self.selection) {
            .inactive => null,
            .active => |active| active.next_tick_ns,
        };
        for (self.items.items) |item| {
            if (item.renderable.nextAnimationDeadline(now_ns)) |deadline| {
                next_deadline = if (next_deadline) |cur| @min(cur, deadline) else deadline;
            }
        }
        return next_deadline;
    }

    pub fn tickAnimation(self: *Transcript, now_ns: i128) bool {
        var changed = self.tickSelectionAutoScroll(now_ns);
        for (self.items.items) |item| {
            changed = item.renderable.tickAnimation(now_ns) or changed;
        }
        return changed;
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
        self.renderSelectionOverlay(region);
    }

    fn renderItem(self: *Transcript, item: *TranscriptItem, row_region: Region, skipped: u32, _: u32, w: u32) void {
        const row_skip = skipped;
        if (item.extra_height > 0 and row_skip < item.extra_height) {
            const spacer_visible = item.extra_height - row_skip;
            if (row_region.height > spacer_visible) {
                const sub = row_region.sub(0, spacer_visible, w, row_region.height - spacer_visible);
                self.renderRenderableRows(item.renderable, sub, 0);
            }
            return;
        }
        self.renderRenderableRows(item.renderable, row_region, row_skip -| item.extra_height);
    }

    fn renderRenderableRows(self: *Transcript, renderable: TranscriptRenderable, row_region: Region, skipped: u32) void {
        _ = self;
        if (row_region.width == 0 or row_region.height == 0) return;
        renderable.renderSlice(row_region, skipped);
    }

    fn itemHeight(self: *Transcript, item: *TranscriptItem, width: u32) u32 {
        _ = self;
        return @max(1, item.renderable.measure(width).preferred_height) + item.extra_height;
    }
};

fn rowUsedColumns(region: Region, row: u32) u32 {
    if (row >= region.height) return 0;
    var last_used: u32 = 0;
    var col: u32 = 0;
    while (col < region.width) : (col += 1) {
        const cell = region.get(col, row);
        if (cell.width == 0) continue;
        if (!cellIsBlank(region.buf, cell)) {
            last_used = @min(region.width, col + @as(u32, cell.width));
        }
    }
    return last_used;
}

fn cellIsBlank(buf: *const Buffer, cell: cell_mod.Cell) bool {
    return switch (cell.grapheme) {
        .codepoint => |cp| cp == ' ',
        .pooled => |id| blk: {
            for (buf.grapheme_pool.get(id)) |b| {
                if (b != ' ') break :blk false;
            }
            break :blk true;
        },
    };
}

fn appendRowColumns(out: *std.ArrayList(u8), allocator: std.mem.Allocator, region: Region, row: u32, start_col: u32, end_col: u32) !void {
    if (row >= region.height or start_col >= end_col) return;
    var col = start_col;
    while (col < end_col and col < region.width) : (col += 1) {
        const cell = region.get(col, row);
        if (cell.width == 0) continue;
        switch (cell.grapheme) {
            .codepoint => |cp| {
                var utf8_buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cp, &utf8_buf) catch continue;
                try out.appendSlice(allocator, utf8_buf[0..len]);
            },
            .pooled => |id| try out.appendSlice(allocator, region.buf.grapheme_pool.get(id)),
        }
    }
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;
const Buffer = buffer_mod.Buffer;

fn appendTestAssistantRow(transcript: *Transcript) !usize {
    const assistant = try transcript.allocator.create(assistant_message_mod.AssistantMessage);
    errdefer transcript.allocator.destroy(assistant);
    assistant.* = assistant_message_mod.AssistantMessage.init(transcript.allocator);
    errdefer assistant.deinit();
    assistant.theme = transcript.theme;
    assistant.hide_thinking_block = transcript.hide_thinking_block;

    const item: TranscriptItem = .{
        .renderable = TranscriptRenderable.init(assistant_message_mod.AssistantMessage, assistant),
        .kind = .assistant_message,
        .extra_height = 1,
        .deinit_ctx = @ptrCast(assistant),
        .deinit_fn = deinitAssistantMessage,
    };
    if (!transcript.addItem(item)) return error.AppendFailed;
    return transcript.items.items.len - 1;
}

fn setTestAssistantModel(
    transcript: *Transcript,
    assistant: *assistant_message_mod.AssistantMessage,
    blocks: []const assistant_message_mod.AssistantRowModel.Block,
) !void {
    var model: assistant_message_mod.AssistantRowModel = .{};
    defer model.deinit(transcript.allocator);

    for (blocks) |block| {
        switch (block) {
            .text => |text| try model.blocks.append(transcript.allocator, .{ .text = try transcript.allocator.dupe(u8, text) }),
            .thinking => |thinking| try model.blocks.append(transcript.allocator, .{ .thinking = try transcript.allocator.dupe(u8, thinking) }),
        }
    }

    try assistant.setOwnedModel(&model);
}

fn appendTestAssistantText(transcript: *Transcript, text: []const u8) !usize {
    const idx = try appendTestAssistantRow(transcript);
    const assistant = transcript.assistantMessageAt(idx) orelse return error.MissingAssistantRow;
    try setTestAssistantModel(transcript, assistant, &.{.{ .text = @constCast(text) }});
    transcript.itemMutatedAt(idx);
    return idx;
}

fn appendTestAssistantThinking(transcript: *Transcript, text: []const u8) !usize {
    const idx = try appendTestAssistantRow(transcript);
    const assistant = transcript.assistantMessageAt(idx) orelse return error.MissingAssistantRow;
    try setTestAssistantModel(transcript, assistant, &.{.{ .thinking = @constCast(text) }});
    transcript.itemMutatedAt(idx);
    return idx;
}

fn buildTestToolExecutionModel(
    allocator: std.mem.Allocator,
    tool_call_id: []const u8,
    tool_name: []const u8,
) !ToolExecutionRowModel {
    return .{
        .tool_call_id = try allocator.dupe(u8, tool_call_id),
        .tool_name = try allocator.dupe(u8, tool_name),
    };
}

fn setTestToolExecutionState(
    transcript: *Transcript,
    tool: *ToolExecution,
    args_complete: bool,
    execution_started: bool,
    result: ?AgentToolResult,
    is_partial: bool,
    is_error: bool,
) !void {
    var model = try tool.model.clone(transcript.allocator);
    defer model.deinit(transcript.allocator);

    if (model.result) |owned| owned.free(transcript.allocator);
    model.result = if (result) |value| try value.clone(transcript.allocator) else null;
    if (model.result) |*owned| owned.is_error = is_error;
    model.args_complete = args_complete;
    if (args_complete and model.args_json_source != null) {
        transcript.allocator.free(model.args_json_source.?);
        model.args_json_source = null;
    }
    model.execution_started = execution_started;
    model.is_partial = is_partial;
    model.is_error = is_error;
    try tool.setOwnedModel(&model);
}

fn appendTestToolExecutionRow(
    transcript: *Transcript,
    tool_call_id: []const u8,
    tool_name: []const u8,
    renderer: tool_display_mod.ToolRenderer,
) !usize {
    const tool = try transcript.allocator.create(ToolExecution);
    errdefer transcript.allocator.destroy(tool);
    tool.* = .{
        .allocator = transcript.allocator,
        .theme = transcript.theme,
        .renderer = renderer,
    };
    errdefer tool.deinit();
    if (renderer.init_state) |init_fn| {
        tool.renderer_state = init_fn(transcript.allocator);
    }

    var model = try buildTestToolExecutionModel(transcript.allocator, tool_call_id, tool_name);
    defer model.deinit(transcript.allocator);
    try tool.setOwnedModel(&model);

    const item: TranscriptItem = .{
        .renderable = TranscriptRenderable.init(ToolExecution, tool),
        .kind = .tool_execution,
        .tool_call_id = tool.model.tool_call_id.?,
        .extra_height = 1,
        .deinit_ctx = @ptrCast(tool),
        .deinit_fn = ToolExecution.deinitItem,
    };
    if (!transcript.addItem(item)) return error.AppendFailed;
    return transcript.items.items.len - 1;
}

fn buildTestUserModel(
    allocator: std.mem.Allocator,
    text: []const u8,
    footer: user_message_mod.Footer,
    status: user_message_mod.Status,
) !user_message_mod.UserRowModel {
    return .{
        .text = try allocator.dupe(u8, text),
        .footer = try footer.clone(allocator),
        .status = status,
    };
}

fn appendTestUserRow(
    transcript: *Transcript,
    text: []const u8,
    footer: user_message_mod.Footer,
    kind: ItemKind,
) !usize {
    const msg = try transcript.allocator.create(user_message_mod.UserMessage);
    errdefer transcript.allocator.destroy(msg);
    msg.* = user_message_mod.UserMessage.init(transcript.allocator);
    errdefer msg.deinit();
    msg.setTheme(transcript.theme);

    var model = try buildTestUserModel(
        transcript.allocator,
        text,
        footer,
        if (kind == .queued_user_message) .pending else .in_chat,
    );
    defer model.deinit(transcript.allocator);
    msg.setOwnedModel(&model);

    const item: TranscriptItem = .{
        .renderable = TranscriptRenderable.init(user_message_mod.UserMessage, msg),
        .kind = kind,
        .extra_height = 1,
        .deinit_ctx = @ptrCast(msg),
        .deinit_fn = deinitUserMessage,
    };
    if (!transcript.addItem(item)) return error.AppendFailed;
    return transcript.items.items.len - 1;
}

test "Transcript retained items install transcript renderables" {
    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    _ = try appendTestAssistantText(&transcript, "hello from assistant");
    _ = try appendTestUserRow(&transcript, "user msg", .none, .user_message);
    _ = try appendTestToolExecutionRow(&transcript, "tool-1", "bash", .{});

    try testing.expectEqual(@as(usize, 3), transcript.items.items.len);
    try testing.expectEqual(ItemKind.assistant_message, transcript.items.items[0].kind);
    try testing.expectEqual(ItemKind.user_message, transcript.items.items[1].kind);
    try testing.expectEqual(ItemKind.tool_execution, transcript.items.items[2].kind);
}

test "tool execution keeps transcript background transparent" {
    const theme = themes_builtin.dark();
    var model = try buildTestToolExecutionModel(testing.allocator, "tool-1", "bash");
    defer model.deinit(testing.allocator);

    var tool = ToolExecution{
        .model = model,
        .allocator = testing.allocator,
        .theme = theme,
    };
    model = .{};
    defer tool.model.deinit(testing.allocator);

    try testing.expect(tool.bgColor().eql(Color.default));
    tool.model.is_partial = false;
    try testing.expect(tool.bgColor().eql(Color.default));
    tool.model.is_error = true;
    try testing.expect(tool.bgColor().eql(Color.default));
}

test "Transcript renders assistant text and tool execution in order" {
    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    _ = try appendTestAssistantText(&transcript, "hello from assistant");

    const tool_idx = try appendTestToolExecutionRow(&transcript, "tool-1", "bash", .{});
    const tool = transcript.toolExecutionAt(tool_idx).?;

    var content = [_]AgentToolResult.ContentBlock{
        .{ .text = .{ .text = "hi" } },
    };
    try setTestToolExecutionState(&transcript, tool, true, true, .{ .content = &content, .is_error = false }, false, false);
    transcript.clearToolRoutingAt(tool_idx);
    transcript.itemMutatedAt(tool_idx);

    try testing.expectEqual(@as(usize, 2), transcript.items.items.len);

    var buf = try Buffer.init(testing.allocator, 30, 10);
    defer buf.deinit();
    transcript.render(buf.region());

    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(testing.allocator);
    for (0..buf.height) |row| {
        if (row > 0) try text.append(testing.allocator, '\n');
        for (0..buf.width) |col| {
            const cp = buf.get(@intCast(col), @intCast(row)).grapheme.codepoint;
            if (cp == 0) continue;
            try text.append(testing.allocator, @intCast(cp));
        }
    }
    const flat = text.items;
    const assistant_idx = std.mem.indexOf(u8, flat, "hello from assistant") orelse return error.TestUnexpectedResult;
    const tool_idx_text = std.mem.indexOf(u8, flat, "bash") orelse return error.TestUnexpectedResult;
    try testing.expect(assistant_idx < tool_idx_text);
}

test "tool execution model replacement preserves pending routing by tool_call_id" {
    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    const tool_idx = try appendTestToolExecutionRow(&transcript, "tool-1", "bash", .{});
    const tool = transcript.toolExecutionAt(tool_idx).?;
    try testing.expectEqual(tool_idx, transcript.findToolExecutionIndex("tool-1").?);

    var partial_content = [_]AgentToolResult.ContentBlock{
        .{ .text = .{ .text = "running" } },
    };
    try setTestToolExecutionState(&transcript, tool, false, true, .{ .content = &partial_content, .is_error = false }, true, false);

    try testing.expectEqual(tool_idx, transcript.findToolExecutionIndex("tool-1").?);
}

test "Transcript preserves manual scroll when assistant content grows" {
    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    const assistant_idx = try appendTestAssistantText(&transcript, "one two three four five six seven eight nine ten");
    transcript.scrollToBottom(12, 3);
    transcript.scrollBy(12, 3, -1);
    const before = transcript.scrollOffset();

    const assistant = transcript.assistantMessageAt(assistant_idx).?;
    try setTestAssistantModel(&transcript, assistant, &.{.{ .text = @constCast("one two three four five six seven eight nine ten eleven twelve thirteen fourteen") }});
    transcript.itemMutatedAt(assistant_idx);

    try testing.expectEqual(before, transcript.scrollOffset());
}

test "ToolExecution does not invoke result renderers before any result exists" {
    const S = struct {
        var measure_result_calls: usize = 0;
        var render_result_calls: usize = 0;

        fn renderCall(ctx: *const tool_display_mod.ToolRenderContext) void {
            _ = ctx.region.writeStr(0, 0, "Edit /tmp/file.txt", ctx.theme.fg(.tool_title), Color.default, .{ .bold = true });
        }

        fn renderResult(_: *const tool_display_mod.ToolRenderContext, _: u32) void {
            render_result_calls += 1;
        }

        fn measureResult(_: *const tool_display_mod.ToolMeasureContext) u32 {
            measure_result_calls += 1;
            return 7;
        }
    };

    S.measure_result_calls = 0;
    S.render_result_calls = 0;

    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    const tool_idx = try appendTestToolExecutionRow(&transcript, "tool-1", "edit", .{
        .render_call = &S.renderCall,
        .render_result_slice = &S.renderResult,
        .measure_result = &S.measureResult,
    });
    const tool = transcript.toolExecutionAt(tool_idx).?;
    try setTestToolExecutionState(&transcript, tool, false, true, null, true, false);
    transcript.itemMutatedAt(tool_idx);

    var buf = try Buffer.init(testing.allocator, 30, 6);
    defer buf.deinit();
    transcript.render(buf.region());

    try testing.expectEqual(@as(usize, 0), S.measure_result_calls);
    try testing.expectEqual(@as(usize, 0), S.render_result_calls);
}

test "ToolExecution keeps transcript surface transparent across pending partial and final states" {
    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    const tool_idx = try appendTestToolExecutionRow(&transcript, "tool-1", "bash", .{});
    const tool = transcript.toolExecutionAt(tool_idx).?;

    var pending = try Buffer.init(testing.allocator, 20, 6);
    defer pending.deinit();
    transcript.render(pending.region());
    try testing.expect(pending.get(1, 1).bg.eql(Color.default));

    var partial_content = [_]AgentToolResult.ContentBlock{
        .{ .text = .{ .text = "running" } },
    };
    try setTestToolExecutionState(&transcript, tool, false, false, .{ .content = &partial_content, .is_error = false }, true, false);
    transcript.itemMutatedAt(tool_idx);

    var partial = try Buffer.init(testing.allocator, 20, 6);
    defer partial.deinit();
    transcript.render(partial.region());
    try testing.expect(partial.get(1, 1).bg.eql(Color.default));
    try testing.expect(partial.get(1, 2).bg.eql(Color.default));

    var error_content = [_]AgentToolResult.ContentBlock{
        .{ .text = .{ .text = "boom" } },
    };
    try setTestToolExecutionState(&transcript, tool, false, false, .{ .content = &error_content, .is_error = true }, false, true);
    transcript.clearToolRoutingAt(tool_idx);
    transcript.itemMutatedAt(tool_idx);

    var final = try Buffer.init(testing.allocator, 20, 6);
    defer final.deinit();
    transcript.render(final.region());
    try testing.expect(final.get(1, 1).bg.eql(Color.default));
    try testing.expect(final.get(1, 2).bg.eql(Color.default));
}

test "Transcript scrolls through tool output without repeating the first rows" {
    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    const tool_idx = try appendTestToolExecutionRow(&transcript, "tool-1", "bash", .{});
    const tool = transcript.toolExecutionAt(tool_idx).?;

    var content = [_]AgentToolResult.ContentBlock{
        .{ .text = .{ .text = "line1\nline2\nline3\nline4\nline5\nline6" } },
    };
    try setTestToolExecutionState(&transcript, tool, false, false, .{ .content = &content, .is_error = false }, false, false);
    transcript.clearToolRoutingAt(tool_idx);
    transcript.itemMutatedAt(tool_idx);
    transcript.scrollToBottom(20, 3);
    transcript.scrollBy(20, 3, -3);

    var buf = try Buffer.init(testing.allocator, 20, 3);
    defer buf.deinit();
    transcript.render(buf.region());

    try testing.expectEqual(@as(u21, 'l'), buf.get(1, 0).grapheme.codepoint);
    try testing.expectEqual(@as(u21, '2'), buf.get(5, 0).grapheme.codepoint);
    try testing.expectEqual(@as(u21, 'l'), buf.get(1, 1).grapheme.codepoint);
    try testing.expectEqual(@as(u21, '3'), buf.get(5, 1).grapheme.codepoint);
}

test "Transcript preserves visible anchor when earlier items grow" {
    const Box = struct {
        height: u32,
        ch: u21,

        pub fn renderSlice(self: *@This(), region: Region, first_row: u32) void {
            if (first_row >= self.height) return;
            const rows = @min(region.height, self.height - first_row);
            var row: u32 = 0;
            while (row < rows) : (row += 1) {
                region.set(0, row, .{ .grapheme = .{ .codepoint = self.ch } });
            }
        }

        pub fn measure(self: *@This(), _: u32) component_mod.Measurement {
            return .{ .min_height = if (self.height > 0) 1 else 0, .preferred_height = self.height };
        }

        pub fn renderable(self: *@This()) TranscriptRenderable {
            return TranscriptRenderable.init(@This(), self);
        }
    };

    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    var first = Box{ .height = 3, .ch = 'A' };
    var second = Box{ .height = 3, .ch = 'B' };
    transcript.addRenderable(first.renderable());
    transcript.addRenderable(second.renderable());
    transcript.scrollBy(10, 2, 3);

    var before = try Buffer.init(testing.allocator, 10, 2);
    defer before.deinit();
    transcript.render(before.region());
    try testing.expectEqual(@as(u21, 'B'), before.get(0, 0).grapheme.codepoint);

    first.height = 5;
    transcript.noteItemMutated(0);

    var after = try Buffer.init(testing.allocator, 10, 2);
    defer after.deinit();
    transcript.render(after.region());
    try testing.expectEqual(@as(u21, 'B'), after.get(0, 0).grapheme.codepoint);
}

test "ToolExecution collapsed plain text renderer shows overflow hint row" {
    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    const tool_idx = try appendTestToolExecutionRow(&transcript, "tool-1", "unknown", .{});
    const tool = transcript.toolExecutionAt(tool_idx).?;

    var content = [_]AgentToolResult.ContentBlock{
        .{ .text = .{ .text = "line1\nline2\nline3\nline4\nline5\nline6" } },
    };
    try setTestToolExecutionState(&transcript, tool, false, false, .{ .content = &content, .is_error = false }, false, false);
    transcript.clearToolRoutingAt(tool_idx);
    transcript.itemMutatedAt(tool_idx);

    var buf = try Buffer.init(testing.allocator, 20, 10);
    defer buf.deinit();
    transcript.render(buf.region());

    try testing.expectEqual(@as(u21, '.'), buf.get(1, 8).grapheme.codepoint);
}

test "Transcript removeRenderable removes item by identity and fixes indices" {
    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    // Use a simple renderable wrapper for identity testing
    const Wrapper = struct {
        val: u8 = 0,
        pub fn renderSlice(_: *@This(), _: Region, _: u32) void {}
        pub fn measure(_: *@This(), _: u32) component_mod.Measurement {
            return .{ .min_height = 1, .preferred_height = 1 };
        }
        pub fn renderable(self: *@This()) TranscriptRenderable {
            return TranscriptRenderable.init(@This(), self);
        }
    };

    var w1 = Wrapper{ .val = 1 };
    var w2 = Wrapper{ .val = 2 };
    var w3 = Wrapper{ .val = 3 };

    transcript.addRenderable(w1.renderable());
    transcript.addRenderable(w2.renderable());
    transcript.addRenderable(w3.renderable());

    try testing.expectEqual(@as(usize, 3), transcript.items.items.len);

    // Remove middle item
    transcript.removeRenderable(w2.renderable());
    try testing.expectEqual(@as(usize, 2), transcript.items.items.len);

    // Remaining items should be w1 and w3
    try testing.expect(TranscriptRenderable.eql(transcript.items.items[0].renderable, w1.renderable()));
    try testing.expect(TranscriptRenderable.eql(transcript.items.items[1].renderable, w3.renderable()));

    // Remove non-existent — no-op
    transcript.removeRenderable(w2.renderable());
    try testing.expectEqual(@as(usize, 2), transcript.items.items.len);

    // Scroll clamp: set scroll past total, remove item, verify clamped
    transcript.scrollBy(80, 1, 100);
    transcript.removeRenderable(w3.renderable());
    // total height is now 1 (just w1), so scroll offset should be clamped to ≤ 1
    try testing.expect(transcript.scrollOffset() <= 1);
}

test "Transcript animation hooks stay static for assistant thinking blocks" {
    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    _ = try appendTestAssistantThinking(&transcript, "ponder");

    try testing.expectEqual(@as(?i128, null), transcript.nextAnimationDeadline(0));
    try testing.expect(!transcript.tickAnimation(0));
    try testing.expectEqual(@as(?i128, null), transcript.nextAnimationDeadline(0));
}

test "Transcript selection copies across visual rows" {
    const FixedLines = struct {
        lines: []const []const u8,

        pub fn renderSlice(self: *@This(), region: Region, first_row: u32) void {
            var row: u32 = 0;
            var line_idx: usize = @intCast(first_row);
            while (row < region.height and line_idx < self.lines.len) : ({
                row += 1;
                line_idx += 1;
            }) {
                _ = region.writeStr(0, row, self.lines[line_idx], Color.default, Color.default, .{});
            }
        }

        pub fn measure(self: *@This(), _: u32) component_mod.Measurement {
            const h: u32 = @intCast(self.lines.len);
            return .{ .min_height = if (h > 0) 1 else 0, .preferred_height = h };
        }

        pub fn renderable(self: *@This()) TranscriptRenderable {
            return TranscriptRenderable.init(@This(), self);
        }
    };

    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    var lines = FixedLines{ .lines = &.{ "alpha", "bravo" } };
    transcript.addRenderable(lines.renderable());

    try testing.expect(transcript.beginSelection(10, 2, 1, 0));
    try testing.expect(transcript.updateSelection(10, 2, 4, 1, .inside, 0));

    const selected = (try transcript.selectedText(testing.allocator, 10)).?;
    defer testing.allocator.free(selected);
    try testing.expectEqualStrings("lpha\nbrav", selected);
}

test "Transcript selection autoscroll advances viewport while dragging below" {
    const FixedLines = struct {
        lines: []const []const u8,

        pub fn renderSlice(self: *@This(), region: Region, first_row: u32) void {
            var row: u32 = 0;
            var line_idx: usize = @intCast(first_row);
            while (row < region.height and line_idx < self.lines.len) : ({
                row += 1;
                line_idx += 1;
            }) {
                _ = region.writeStr(0, row, self.lines[line_idx], Color.default, Color.default, .{});
            }
        }

        pub fn measure(self: *@This(), _: u32) component_mod.Measurement {
            const h: u32 = @intCast(self.lines.len);
            return .{ .min_height = if (h > 0) 1 else 0, .preferred_height = h };
        }

        pub fn renderable(self: *@This()) TranscriptRenderable {
            return TranscriptRenderable.init(@This(), self);
        }
    };

    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    var lines = FixedLines{ .lines = &.{ "row0", "row1", "row2", "row3" } };
    transcript.addRenderable(lines.renderable());

    try testing.expect(transcript.beginSelection(10, 2, 0, 1));
    try testing.expect(transcript.updateSelection(10, 2, 3, 1, .below, 0));
    try testing.expectEqual(@as(?i128, 50 * std.time.ns_per_ms), transcript.nextAnimationDeadline(0));
    try testing.expect(!transcript.tickAnimation(49 * std.time.ns_per_ms));
    try testing.expect(transcript.tickAnimation(50 * std.time.ns_per_ms));
    try testing.expectEqual(@as(u32, 1), transcript.scrollOffset());

    var buf = try Buffer.init(testing.allocator, 10, 2);
    defer buf.deinit();
    transcript.render(buf.region());
    try testing.expectEqual(@as(u21, 'r'), buf.get(0, 0).grapheme.codepoint);
    try testing.expectEqual(@as(u21, '1'), buf.get(3, 0).grapheme.codepoint);
}

test "Transcript clearAll removes all items and resets state" {
    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    _ = try appendTestAssistantText(&transcript, "hello");
    _ = try appendTestUserRow(&transcript, "user msg", .none, .user_message);

    try testing.expectEqual(@as(usize, 2), transcript.items.items.len);

    transcript.clearAll();

    try testing.expectEqual(@as(usize, 0), transcript.items.items.len);
    try testing.expectEqual(@as(u32, 0), transcript.scrollOffset());
}
