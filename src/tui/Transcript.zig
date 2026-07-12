const std = @import("std");
const agent_mod = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const runtime = @import("../runtime/root.zig");
const blocks = @import("blocks.zig");
const layout = @import("layout.zig");
const screen = @import("screen.zig");
const theme = @import("theme.zig");

pub const append_chunk_bytes_max: usize = 8 * 1024;
pub const per_item_text_bytes_max: usize = 256 * 1024;
pub const transcript_items_max: usize = 2000;
pub const transcript_bytes_max: usize = 8 * 1024 * 1024;
pub const relayout_items_per_prepare: usize = 128;
pub const relayout_source_bytes_per_prepare: usize = 256 * 1024;
const output_truncated_text = "[output truncated]";
const transcript_padding_x: usize = 1;
const user_padding_y: usize = 1;
const custom_padding_y: usize = 1;
const item_margin_bottom: usize = 1;
const padding_spaces = " " ** 16;

pub const Transcript = @This();

gpa: std.mem.Allocator,
items: std.ArrayList(*Item) = .empty,
live_tools: std.StringArrayHashMapUnmanaged(*Item) = .empty,
streaming_item: ?*Item = null,
total_bytes: usize = 0,
next_seq: u64 = 0,
evicted_seqs: u64 = 0,
run_active: bool = false,
tool_resolver: ToolResolver = .{},
derived: DerivedLayout = .{},

pub const ToolArgs = union(enum) {
    value: std.json.Value,
    json_prefix: []const u8,
};

pub const ToolBodyUpdate = union(enum) {
    unchanged,
    clear,
    replace: struct {
        body: []const u8,
        footer: []const u8 = "",
    },
};

pub const ToolUi = struct {
    title: ?[]const u8 = null,
    compact_title: ?[]const u8 = null,
    display: blocks.ToolDisplay = blocks.default_tool_display,
    body_update: ToolBodyUpdate = .unchanged,
};

pub const ToolResultUi = struct {
    body: ?[]const u8 = null,
    footer: ?[]const u8 = null,
};

pub const ToolResolver = struct {
    context: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, std.mem.Allocator, []const u8, ToolArgs) anyerror!ToolUi = defaultToolResolver,
    result_fn: *const fn (?*anyopaque, std.mem.Allocator, []const u8, bool, []const ai.ToolResultContent, ?std.json.Value) anyerror!ToolResultUi = defaultToolResultResolver,

    fn resolve(self: ToolResolver, allocator: std.mem.Allocator, name: []const u8, args: ToolArgs) !ToolUi {
        return self.call_fn(self.context, allocator, name, args);
    }

    fn resolveResult(self: ToolResolver, allocator: std.mem.Allocator, name: []const u8, is_error: bool, content: []const ai.ToolResultContent, details: ?std.json.Value) !ToolResultUi {
        return self.result_fn(self.context, allocator, name, is_error, content, details);
    }
};

const PartTag = enum { text, thinking };

const Part = union(PartTag) {
    text: std.ArrayList(u8),
    thinking: std.ArrayList(u8),

    fn list(self: *Part) *std.ArrayList(u8) {
        return switch (self.*) {
            .text => |*value| value,
            .thinking => |*value| value,
        };
    }

    fn bytes(self: *const Part) []const u8 {
        return switch (self.*) {
            .text => |value| value.items,
            .thinking => |value| value.items,
        };
    }

    fn tag(self: Part) PartTag {
        return switch (self) {
            .text => .text,
            .thinking => .thinking,
        };
    }
};

const PendingUtf8 = struct {
    // Four bytes of storage lets the next delta complete a scalar in place;
    // len is never retained above three between deltas.
    bytes: [4]u8 = undefined,
    len: u8 = 0,
};

const Stop = enum { ok, aborted, errored };
pub const NoticeLevel = enum { info, warn, err };

const LayoutKey = struct {
    width: u16,
    expanded: bool,
    hide_thinking: bool,

    fn from(state: theme.LayoutState) LayoutKey {
        return .{
            .width = state.width,
            .expanded = state.expanded,
            .hide_thinking = state.hide_thinking,
        };
    }
};

const LayoutInvalidation = enum {
    clean,
    source_appended,
    rebuild,
};

pub const LayoutWork = struct {
    items_laid_out: usize = 0,
    source_bytes: usize = 0,
    index_entries_repaired: usize = 0,
    lines_materialized: usize = 0,

    fn reset(self: *LayoutWork) void {
        self.* = .{};
    }
};

const RowRole = enum {
    content,
    semantic_blank,
    panel_padding,
    item_margin,
};

const CachedLayout = struct {
    arena: std.heap.ArenaAllocator,
    key: ?LayoutKey = null,
    content_generation: u64 = 0,
    lines: []layout.Line = &.{},
    roles: []RowRole = &.{},
    incremental_lines: std.ArrayList(layout.Line) = .empty,
    incremental_roles: std.ArrayList(RowRole) = .empty,
    incremental_part_index: ?usize = null,
    incremental_source_len: usize = 0,
    wrap: layout.WrapState = .{},
};

const ItemLayout = struct {
    invalidation: LayoutInvalidation = .rebuild,
    active: CachedLayout,
    pending: ?*CachedLayout = null,
};

pub const Position = struct {
    item_seq: u64,
    line_in_item: u32,
};

pub const ResolvedPosition = struct {
    position: Position,
    absolute: usize,
};

pub const PrepareResult = enum {
    ready,
    published,
    pending,
};

const RelayoutJob = struct {
    key: LayoutKey,
    next_item: usize = 0,
};

const DerivedLayout = struct {
    key: ?LayoutKey = null,
    first_invalid_item: ?usize = null,
    line_prefix: [transcript_items_max + 1]usize = undefined,
    item_count: usize = 0,
    work: LayoutWork = .{},
    relayout: ?RelayoutJob = null,
};

const Item = struct {
    arena: std.heap.ArenaAllocator,
    seq: u64,
    index: usize = std.math.maxInt(usize),
    content_generation: u64 = 0,
    layout_cache: ItemLayout,
    kind: Kind,

    pub const Kind = union(enum) {
        user: struct { text: std.ArrayList(u8), truncated: bool = false },
        assistant: struct {
            parts: std.ArrayList(Part),
            pending_utf8: std.ArrayList(PendingUtf8) = .empty,
            streaming: bool,
            stop: Stop = .ok,
            error_text: ?[]const u8 = null,
            truncated: bool = false,
        },
        tool: struct {
            call_id: []const u8,
            name: []const u8,
            title: []const u8,
            compact_title: []const u8,
            display: blocks.ToolDisplay,
            args_preview: std.ArrayList(u8),
            args_truncated: bool = false,
            status: blocks.Status,
            started_ns: ?u64 = null,
            elapsed_ms: ?u64 = null,
            duration_ms: ?u64 = null,
            tail: blocks.TailBuffer = .{},
            body: std.ArrayList(u8),
            body_truncated: bool = false,
            details_present: bool = false,
            footer: []const u8,
        },
        notice: struct { level: NoticeLevel, text: []const u8 },
        compaction: struct {
            summary: std.ArrayList(u8),
            truncated: bool = false,
            tokens_before: u64,
        },
        custom: struct { title: []const u8, text: []const u8 },
    };

    fn allocator(self: *Item) std.mem.Allocator {
        return self.arena.allocator();
    }
};

pub fn init(gpa: std.mem.Allocator) Transcript {
    return .{ .gpa = gpa };
}

pub fn initWithToolResolver(gpa: std.mem.Allocator, tool_resolver: ToolResolver) Transcript {
    return .{ .gpa = gpa, .tool_resolver = tool_resolver };
}

pub fn deinit(self: *Transcript) void {
    for (self.items.items) |item| self.destroyItem(item);
    self.items.deinit(self.gpa);
    self.live_tools.deinit(self.gpa);
    self.* = undefined;
}

pub fn clear(self: *Transcript) void {
    for (self.items.items) |item| self.destroyItem(item);
    self.items.clearRetainingCapacity();
    self.live_tools.clearRetainingCapacity();
    self.streaming_item = null;
    self.total_bytes = 0;
    self.next_seq = 0;
    self.evicted_seqs = 0;
    self.run_active = false;
    self.derived = .{};
}

pub fn applyListener(io: std.Io, context: ?*anyopaque, event: agent_mod.AgentEvent, _: runtime.CancelToken) anyerror!void {
    const self: *Transcript = @ptrCast(@alignCast(context.?));
    try self.apply(io, event);
}

pub fn apply(self: *Transcript, io: std.Io, event: agent_mod.AgentEvent) !void {
    switch (event) {
        .agent_start => self.run_active = true,
        .agent_end => {
            self.run_active = false;
            self.live_tools.clearRetainingCapacity();
        },
        .turn_start, .turn_end => {},
        .message_start => |payload| try self.applyMessageStart(payload.message),
        .message_update => |payload| try self.applyMessageUpdate(payload.assistant_message_event),
        .message_end => |payload| try self.applyMessageEnd(io, payload.message),
        .tool_execution_start => |payload| try self.applyToolStart(io, payload),
        .tool_execution_update => |payload| try self.applyToolUpdate(payload),
        .tool_execution_end => |payload| try self.applyToolEnd(io, payload),
    }
    try self.enforceCaps();
}

pub fn appendNotice(self: *Transcript, level: NoticeLevel, text: []const u8) !void {
    const item = try self.createItem(.{ .notice = .{
        .level = level,
        .text = undefined,
    } });
    item.kind.notice.text = try item.allocator().dupe(u8, text);
    self.total_bytes += item.kind.notice.text.len;
    try self.appendItem(item);
    try self.enforceCaps();
}

pub fn appendCompaction(self: *Transcript, summary: []const u8, tokens_before: u64) !void {
    const item = try self.createItem(.{ .compaction = .{
        .summary = .empty,
        .tokens_before = tokens_before,
    } });
    var item_owned = true;
    errdefer if (item_owned) self.destroyItem(item);
    try self.appendListBounded(
        item,
        &item.kind.compaction.summary,
        summary,
        per_item_text_bytes_max,
        &item.kind.compaction.truncated,
        true,
    );
    try self.appendItem(item);
    item_owned = false;
    try self.enforceCaps();
}

pub fn markRunningToolsDirty(self: *Transcript, now_ns: u64) bool {
    var changed = false;
    for (self.live_tools.values()) |item| {
        if (item.kind != .tool or item.kind.tool.status != .running or !item.kind.tool.display.shows_duration) continue;
        const started = item.kind.tool.started_ns orelse continue;
        const elapsed_ms = (now_ns -| started) / std.time.ns_per_ms;
        const previous_ms = item.kind.tool.elapsed_ms orelse 0;
        item.kind.tool.elapsed_ms = elapsed_ms;
        if (elapsed_ms / blocks.duration_tick_ms == previous_ms / blocks.duration_tick_ms) continue;
        self.invalidateItem(item, .rebuild);
        changed = true;
    }
    return changed;
}

pub fn prepareLayout(self: *Transcript, state: theme.LayoutState) !PrepareResult {
    self.derived.work.reset();
    const requested_key = LayoutKey.from(state);
    if (self.derived.key) |active_key| {
        if (std.meta.eql(active_key, requested_key)) {
            self.cancelRelayout();
            try self.repairActiveLayout(active_key);
            return .ready;
        }
        try self.repairActiveLayout(active_key);
    }

    if (self.derived.relayout == null or !std.meta.eql(self.derived.relayout.?.key, requested_key)) {
        self.startRelayout(requested_key);
    }
    if (try self.advanceRelayout()) return .published;
    return .pending;
}

pub fn hasPendingRelayout(self: *const Transcript) bool {
    return self.derived.relayout != null;
}

fn repairActiveLayout(self: *Transcript, key: LayoutKey) !void {
    const item_count = self.items.items.len;
    const dirty_from = if (self.derived.first_invalid_item) |index|
        @min(index, item_count)
    else if (item_count != self.derived.item_count)
        @min(item_count, self.derived.item_count)
    else
        return;

    var total = if (dirty_from == 0) @as(usize, 0) else self.derived.line_prefix[dirty_from];
    self.derived.line_prefix[0] = 0;
    for (self.items.items[dirty_from..], dirty_from..) |item, index| {
        const lines = try self.layoutActiveItem(item, key);
        total += lines.len;
        self.derived.line_prefix[index + 1] = total;
        self.derived.work.index_entries_repaired += 1;
    }
    self.derived.item_count = item_count;
    self.derived.first_invalid_item = null;
}

fn startRelayout(self: *Transcript, key: LayoutKey) void {
    self.discardPendingLayouts();
    self.derived.relayout = .{ .key = key };
}

fn cancelRelayout(self: *Transcript) void {
    if (self.derived.relayout == null) return;
    self.discardPendingLayouts();
    self.derived.relayout = null;
}

fn advanceRelayout(self: *Transcript) !bool {
    const job = if (self.derived.relayout) |*pending| pending else return false;
    const bytes_before = self.derived.work.source_bytes;
    var processed: usize = 0;
    while (job.next_item < self.items.items.len) {
        if (processed >= relayout_items_per_prepare) break;
        if (processed > 0 and
            self.derived.work.source_bytes -| bytes_before >= relayout_source_bytes_per_prepare)
        {
            break;
        }
        const item = self.items.items[job.next_item];
        try self.preparePendingItem(item, job.key);
        job.next_item += 1;
        processed += 1;
    }
    if (job.next_item < self.items.items.len) return false;

    for (self.items.items) |item| {
        const pending = item.layout_cache.pending orelse return false;
        if (pending.content_generation != item.content_generation or !std.meta.eql(pending.key.?, job.key)) {
            job.next_item = @min(job.next_item, item.index);
            return false;
        }
    }
    self.publishPendingLayouts(job.key);
    return true;
}

fn preparePendingItem(self: *Transcript, item: *Item, key: LayoutKey) !void {
    if (item.layout_cache.pending) |pending| {
        if (pending.content_generation == item.content_generation and
            pending.key != null and
            std.meta.eql(pending.key.?, key))
        {
            return;
        }
        self.deinitCachedLayout(pending);
        self.gpa.destroy(pending);
        item.layout_cache.pending = null;
    }

    const pending = try self.gpa.create(CachedLayout);
    errdefer self.gpa.destroy(pending);
    pending.* = .{ .arena = std.heap.ArenaAllocator.init(self.gpa) };
    errdefer self.deinitCachedLayout(pending);
    if (item.kind == .assistant) {
        if (assistantIncrementalSource(&item.kind.assistant, key.hide_thinking)) |source| {
            self.derived.work.items_laid_out += 1;
            try self.layoutIncrementalAssistant(item, pending, source, key, false);
        } else {
            try self.layoutItemFull(item, pending, key);
        }
    } else {
        try self.layoutItemFull(item, pending, key);
    }
    pending.content_generation = item.content_generation;
    item.layout_cache.pending = pending;
}

fn publishPendingLayouts(self: *Transcript, key: LayoutKey) void {
    var total: usize = 0;
    self.derived.line_prefix[0] = 0;
    for (self.items.items, 0..) |item, index| {
        const pending = item.layout_cache.pending.?;
        self.deinitCachedLayout(&item.layout_cache.active);
        item.layout_cache.active = pending.*;
        self.gpa.destroy(pending);
        item.layout_cache.pending = null;
        item.layout_cache.invalidation = .clean;
        total += item.layout_cache.active.lines.len;
        self.derived.line_prefix[index + 1] = total;
        self.derived.work.index_entries_repaired += 1;
    }
    self.derived.item_count = self.items.items.len;
    self.derived.first_invalid_item = null;
    self.derived.key = key;
    self.derived.relayout = null;
}

fn discardPendingLayouts(self: *Transcript) void {
    for (self.items.items) |item| {
        const pending = item.layout_cache.pending orelse continue;
        self.deinitCachedLayout(pending);
        self.gpa.destroy(pending);
        item.layout_cache.pending = null;
    }
}

pub fn totalLines(self: *const Transcript) usize {
    return if (self.derived.item_count == 0) 0 else self.derived.line_prefix[self.derived.item_count];
}

pub fn collectVisible(self: *Transcript, start: usize, out: []layout.Line) []const layout.Line {
    if (out.len == 0) return &.{};
    var ref = self.lineRefAt(start) orelse return &.{};
    var count: usize = 0;
    while (count < out.len and ref.item_index < self.derived.item_count) {
        const lines = self.items.items[ref.item_index].layout_cache.active.lines;
        if (ref.line_in_item < lines.len) {
            out[count] = lines[ref.line_in_item];
            count += 1;
            ref.line_in_item += 1;
        }
        if (ref.line_in_item >= lines.len) {
            ref.item_index += 1;
            ref.line_in_item = 0;
        }
    }
    self.derived.work.lines_materialized += count;
    return out[0..count];
}

pub fn lineAt(self: *const Transcript, absolute: usize) ?layout.Line {
    const ref = self.lineRefAt(absolute) orelse return null;
    return self.items.items[ref.item_index].layout_cache.active.lines[ref.line_in_item];
}

pub fn isItemMarginAt(self: *const Transcript, absolute: usize) bool {
    return self.rowRoleAt(absolute) == .item_margin;
}

fn rowRoleAt(self: *const Transcript, absolute: usize) ?RowRole {
    const ref = self.lineRefAt(absolute) orelse return null;
    return self.items.items[ref.item_index].layout_cache.active.roles[ref.line_in_item];
}

pub fn positionAtLine(self: *const Transcript, absolute: usize) ?ResolvedPosition {
    const ref = self.lineRefAt(absolute) orelse return null;
    return .{
        .position = .{
            .item_seq = self.items.items[ref.item_index].seq,
            .line_in_item = @intCast(ref.line_in_item),
        },
        .absolute = absolute,
    };
}

pub fn resolvePosition(self: *const Transcript, position: Position) ?ResolvedPosition {
    const item_index = self.itemIndexForSeq(position.item_seq) orelse return null;
    const line_count = self.itemLineCount(item_index);
    if (line_count == 0) return .{
        .position = .{ .item_seq = position.item_seq, .line_in_item = 0 },
        .absolute = self.derived.line_prefix[item_index],
    };
    var line_index = @min(@as(usize, position.line_in_item), line_count - 1);
    const roles = self.items.items[item_index].layout_cache.active.roles;
    while (line_index > 0 and roles[line_index] == .item_margin) line_index -= 1;
    return .{
        .position = .{ .item_seq = position.item_seq, .line_in_item = @intCast(line_index) },
        .absolute = self.derived.line_prefix[item_index] + line_index,
    };
}

pub fn oldestPosition(self: *const Transcript) ?ResolvedPosition {
    if (self.derived.item_count == 0 or self.totalLines() == 0) return null;
    return .{
        .position = .{ .item_seq = self.items.items[0].seq, .line_in_item = 0 },
        .absolute = 0,
    };
}

pub fn lastLayoutWork(self: *const Transcript) LayoutWork {
    return self.derived.work;
}

const LineRef = struct {
    item_index: usize,
    line_in_item: usize,
};

fn lineRefAt(self: *const Transcript, absolute: usize) ?LineRef {
    if (absolute >= self.totalLines()) return null;
    var low: usize = 0;
    var high = self.derived.item_count;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (absolute < self.derived.line_prefix[mid + 1]) {
            high = mid;
        } else {
            low = mid + 1;
        }
    }
    if (low == self.derived.item_count) return null;
    return .{ .item_index = low, .line_in_item = absolute - self.derived.line_prefix[low] };
}

fn itemLineCount(self: *const Transcript, item_index: usize) usize {
    return self.derived.line_prefix[item_index + 1] - self.derived.line_prefix[item_index];
}

fn itemIndexForSeq(self: *const Transcript, seq: u64) ?usize {
    var low: usize = 0;
    var high = self.derived.item_count;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const item_seq = self.items.items[mid].seq;
        if (item_seq < seq) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    if (low == self.derived.item_count or self.items.items[low].seq != seq) return null;
    return low;
}

fn layoutActiveItem(self: *Transcript, item: *Item, key: LayoutKey) ![]const layout.Line {
    const cache = &item.layout_cache.active;
    if (item.layout_cache.invalidation == .clean and
        cache.key != null and
        std.meta.eql(cache.key.?, key))
    {
        return cache.lines;
    }
    if (item.kind == .assistant) {
        if (assistantIncrementalSource(&item.kind.assistant, key.hide_thinking)) |source| {
            self.derived.work.items_laid_out += 1;
            const can_append = item.layout_cache.invalidation == .source_appended and
                cache.key != null and
                std.meta.eql(cache.key.?, key) and
                cache.incremental_part_index == source.part_index and
                cache.incremental_source_len <= source.text.len;
            try self.layoutIncrementalAssistant(item, cache, source, key, can_append);
            item.layout_cache.invalidation = .clean;
            return cache.lines;
        }
    }
    try self.layoutItemFull(item, cache, key);
    item.layout_cache.invalidation = .clean;
    return cache.lines;
}

fn layoutItemFull(self: *Transcript, item: *Item, cache: *CachedLayout, key: LayoutKey) !void {
    self.derived.work.items_laid_out += 1;
    self.derived.work.source_bytes += itemBytes(item);
    cache.incremental_lines.clearRetainingCapacity();
    cache.incremental_roles.clearRetainingCapacity();
    cache.incremental_part_index = null;
    cache.incremental_source_len = 0;
    cache.wrap = .{};
    _ = cache.arena.reset(.retain_capacity);
    cache.lines = &.{};
    cache.roles = &.{};
    const allocator = cache.arena.allocator();
    const content_lines = switch (item.kind) {
        .user => |*user| blk: {
            const lines = try layout.wrapProse(
                allocator,
                trimTrailingNewlines(user.text.items),
                transcriptInnerWidth(key.width),
                screen.text.user_message,
            );
            for (lines) |*line| line.row_style = screen.surface.user_message;
            break :blk lines;
        },
        .assistant => |*assistant| try layoutAssistant(
            allocator,
            assistant,
            transcriptInnerWidth(key.width),
            key.hide_thinking,
        ),
        .tool => |*tool| try blocks.layoutTool(
            allocator,
            tool,
            transcriptInnerWidth(key.width),
            key.expanded,
        ),
        .notice => |notice| try layout.wrapProse(
            allocator,
            trimTrailingNewlines(notice.text),
            transcriptInnerWidth(key.width),
            noticeStyle(notice.level),
        ),
        .compaction => |*compaction| try layoutCompaction(
            allocator,
            compaction,
            transcriptInnerWidth(key.width),
            key.expanded,
        ),
        .custom => |custom| try layoutCustom(allocator, custom, transcriptInnerWidth(key.width)),
    };
    const rhythmed = try applyItemRhythm(allocator, item.kind, content_lines);
    cache.lines = rhythmed.lines;
    cache.roles = rhythmed.roles;
    std.debug.assert(cache.lines.len == cache.roles.len);
    cache.key = key;
    cache.content_generation = item.content_generation;
}

const AssistantIncrementalSource = struct {
    part_index: usize,
    text: []const u8,
    prefix: []const u8 = "",
    prefix_style: screen.Style = screen.text.normal,
};

fn assistantIncrementalSource(assistant: anytype, hide_thinking: bool) ?AssistantIncrementalSource {
    if (!assistant.streaming or assistant.stop != .ok) return null;
    if (assistant.parts.items.len == 1) return switch (assistant.parts.items[0]) {
        .text => |text| if (text.items.len == 0) null else .{ .part_index = 0, .text = text.items },
        .thinking => null,
    };
    if (hide_thinking and assistant.parts.items.len == 2) {
        const thinking = switch (assistant.parts.items[0]) {
            .thinking => |thinking| thinking.items,
            .text => return null,
        };
        const text = switch (assistant.parts.items[1]) {
            .text => |text| text.items,
            .thinking => return null,
        };
        if (thinking.len > 0 and text.len > 0) return .{
            .part_index = 1,
            .text = text,
            .prefix = "Thinking...\n\n",
            .prefix_style = thinkingStyle(),
        };
    }
    return null;
}

fn layoutIncrementalAssistant(
    self: *Transcript,
    item: *Item,
    cache: *CachedLayout,
    source: AssistantIncrementalSource,
    key: LayoutKey,
    can_append: bool,
) !void {
    const inner_width = transcriptInnerWidth(key.width);
    std.debug.assert(std.unicode.utf8ValidateSlice(source.text));

    var new_line_start: usize = undefined;
    if (can_append) {
        self.derived.work.source_bytes += source.text.len -| cache.wrap.committed_bytes;
        cache.incremental_lines.items.len = cache.wrap.committed_lines;
        cache.incremental_roles.items.len = cache.wrap.committed_lines;
        new_line_start = cache.incremental_lines.items.len;
    } else {
        self.derived.work.source_bytes += source.prefix.len + source.text.len;
        _ = cache.arena.reset(.retain_capacity);
        cache.incremental_lines.clearRetainingCapacity();
        cache.incremental_roles.clearRetainingCapacity();
        cache.wrap = .{};
        new_line_start = 0;
        if (source.prefix.len > 0) {
            try layout.appendMarkdown(
                self.gpa,
                &cache.incremental_lines,
                source.prefix,
                inner_width,
                source.prefix_style,
                &cache.wrap,
            );
            cache.incremental_lines.items.len = cache.wrap.committed_lines;
            for (cache.incremental_lines.items) |line| {
                try cache.incremental_roles.append(self.gpa, contentRowRole(line));
            }
            cache.wrap.committed_bytes = 0;
        }
    }

    try layout.appendMarkdown(
        self.gpa,
        &cache.incremental_lines,
        source.text,
        inner_width,
        screen.text.normal,
        &cache.wrap,
    );
    for (cache.incremental_lines.items[cache.incremental_roles.items.len..]) |line| {
        try cache.incremental_roles.append(self.gpa, contentRowRole(line));
    }
    for (cache.incremental_lines.items[new_line_start..]) |*line| {
        if (line.spans().len > 0) try insetTranscriptLine(line, lineInsetStyle(item.kind, line.*));
    }
    for (0..item_margin_bottom) |_| {
        try cache.incremental_lines.append(self.gpa, .{});
        try cache.incremental_roles.append(self.gpa, .item_margin);
    }

    cache.lines = cache.incremental_lines.items;
    cache.roles = cache.incremental_roles.items;
    std.debug.assert(cache.lines.len == cache.roles.len);
    cache.incremental_part_index = source.part_index;
    cache.incremental_source_len = source.text.len;
    cache.key = key;
    cache.content_generation = item.content_generation;
}

fn layoutAssistant(
    allocator: std.mem.Allocator,
    assistant: anytype,
    width: u16,
    hide_thinking: bool,
) ![]layout.Line {
    var out = std.ArrayList(layout.Line).empty;
    errdefer out.deinit(allocator);
    var hidden_thinking_shown = false;
    var previous_visible_part_was_thinking = false;

    for (assistant.parts.items) |part| {
        switch (part) {
            .text => |value| {
                const visible = trimTrailingNewlines(value.items);
                std.debug.assert(std.unicode.utf8ValidateSlice(visible));
                if (visible.len == 0) continue;
                if (previous_visible_part_was_thinking) try out.append(allocator, .{});
                try appendMarkdownBlock(allocator, &out, visible, width, screen.text.normal);
                previous_visible_part_was_thinking = false;
            },
            .thinking => |value| {
                const visible = trimTrailingNewlines(value.items);
                std.debug.assert(std.unicode.utf8ValidateSlice(visible));
                if (visible.len == 0) continue;
                if (hide_thinking) {
                    if (hidden_thinking_shown) continue;
                    if (previous_visible_part_was_thinking) try out.append(allocator, .{});
                    try appendMarkdownBlock(allocator, &out, "Thinking...", width, thinkingStyle());
                    hidden_thinking_shown = true;
                } else {
                    if (previous_visible_part_was_thinking) try out.append(allocator, .{});
                    try appendMarkdownBlock(allocator, &out, visible, width, thinkingStyle());
                }
                previous_visible_part_was_thinking = true;
            },
        }
    }

    if (assistant.stop != .ok) {
        if (out.items.len > 0) try out.append(allocator, .{});
        const status_text = switch (assistant.stop) {
            .ok => unreachable,
            .aborted => "aborted",
            .errored => if (assistant.error_text) |err|
                try std.fmt.allocPrint(allocator, "error: {s}", .{err})
            else
                "error",
        };
        const status_lines = try layout.wrapPlain(allocator, status_text, width, screen.text.error_);
        try out.appendSlice(allocator, status_lines);
    }

    return out.toOwnedSlice(allocator);
}

fn appendMarkdownBlock(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(layout.Line),
    text: []const u8,
    width: u16,
    style: screen.Style,
) !void {
    var wrap_state: layout.WrapState = .{};
    const lines = try layout.wrapMarkdown(allocator, text, width, style, &wrap_state);
    try out.appendSlice(allocator, lines);
}

fn thinkingStyle() screen.Style {
    var style = screen.text.thinking;
    style.italic = true;
    return style;
}

fn noticeStyle(level: NoticeLevel) screen.Style {
    return switch (level) {
        .info => screen.text.muted,
        .warn => screen.text.warning,
        .err => screen.text.error_,
    };
}

fn applyMessageStart(self: *Transcript, message: agent_mod.AgentMessage) !void {
    switch (message) {
        .user => |user| {
            const item = try self.createUserMessageItem(user);
            try self.appendItem(item);
        },
        .assistant => {
            const item = try self.createAssistantItem(true);
            self.streaming_item = item;
            try self.appendItem(item);
        },
        .custom => |custom| try self.appendCustom(custom),
        .tool_result => {},
    }
}

fn applyMessageUpdate(self: *Transcript, event: ai.AssistantMessageEvent) !void {
    switch (event) {
        .start, .done, .@"error" => {},
        .text_start => |payload| _ = try self.ensurePart(payload.content_index, .text),
        .thinking_start => |payload| _ = try self.ensurePart(payload.content_index, .thinking),
        .text_delta => |payload| {
            const part = try self.ensurePart(payload.content_index, .text);
            try self.appendAssistantPart(payload.content_index, part, payload.delta);
        },
        .thinking_delta => |payload| {
            const part = try self.ensurePart(payload.content_index, .thinking);
            try self.appendAssistantPart(payload.content_index, part, payload.delta);
        },
        .text_end => |payload| {
            const part = try self.ensurePart(payload.content_index, .text);
            try self.replaceAssistantPart(payload.content_index, part, payload.content);
        },
        .thinking_end => |payload| {
            const part = try self.ensurePart(payload.content_index, .thinking);
            try self.replaceAssistantPart(payload.content_index, part, payload.content);
        },
        .toolcall_start => |payload| {
            if (toolCallAt(payload.partial, payload.content_index)) |call| _ = try self.ensureToolItem(call.id, call.name, call.arguments, true);
        },
        .toolcall_delta => |payload| {
            const call = toolCallAt(payload.partial, payload.content_index) orelse return;
            const item = try self.ensureToolItem(call.id, call.name, call.arguments, true);
            try self.appendToolArgs(item, payload.delta);
            try self.applyToolArgsPreview(item, call.arguments);
        },
        .toolcall_end => |payload| {
            const item = try self.ensureToolItem(payload.tool_call.id, payload.tool_call.name, payload.tool_call.arguments, true);
            try self.setToolTitleFromValue(item, payload.tool_call.arguments);
        },
    }
}

fn applyMessageEnd(self: *Transcript, io: std.Io, message: agent_mod.AgentMessage) !void {
    switch (message) {
        .assistant => |assistant| {
            const item = self.streaming_item orelse blk: {
                const created = try self.createAssistantItem(false);
                try self.appendItem(created);
                break :blk created;
            };
            self.streaming_item = null;
            std.debug.assert(item.kind == .assistant);
            item.kind.assistant.streaming = false;
            try self.reconcileAssistant(item, assistant);
            switch (assistant.stop_reason) {
                .aborted => {
                    item.kind.assistant.stop = .aborted;
                    try self.abortLiveTools(io);
                },
                .error_ => {
                    item.kind.assistant.stop = .errored;
                    if (assistant.error_message) |err| {
                        item.kind.assistant.error_text = try item.allocator().dupe(u8, err);
                        self.total_bytes += item.kind.assistant.error_text.?.len;
                    } else {
                        item.kind.assistant.error_text = null;
                    }
                    try self.abortLiveTools(io);
                },
                else => item.kind.assistant.stop = .ok,
            }
            self.invalidateItem(item, .rebuild);
        },
        .user, .tool_result, .custom => {},
    }
}

fn applyToolStart(self: *Transcript, io: std.Io, payload: agent_mod.AgentEvent.ToolExecutionStart) !void {
    const item = try self.ensureToolItem(payload.tool_call_id, payload.tool_name, payload.args, true);
    std.debug.assert(item.kind == .tool);
    item.kind.tool.status = mergeToolStatus(item.kind.tool.status, .running);
    item.kind.tool.started_ns = nowNs(io);
    item.kind.tool.elapsed_ms = 0;
    self.invalidateItem(item, .rebuild);
}

fn applyToolUpdate(self: *Transcript, payload: agent_mod.AgentEvent.ToolExecutionUpdate) !void {
    const item = try self.ensureToolItem(payload.tool_call_id, payload.tool_name, payload.args, false);
    std.debug.assert(item.kind == .tool);
    var changed = false;
    for (payload.partial_result.content) |content| switch (content) {
        .text => |text| if (item.kind.tool.display.live_updates == .show_tail and text.text.len > 0) {
            item.kind.tool.tail.update(text.text);
            changed = true;
        },
        .image => {},
    };
    if (changed) self.invalidateItem(item, .rebuild);
}

fn applyToolEnd(self: *Transcript, io: std.Io, payload: agent_mod.AgentEvent.ToolExecutionEnd) !void {
    const item = try self.ensureToolItem(payload.tool_call_id, payload.tool_name, .null, false);
    std.debug.assert(item.kind == .tool);
    const tool = &item.kind.tool;
    const result_status: blocks.Status = if (payload.is_error) .failed else .done;
    tool.status = mergeToolStatus(tool.status, result_status);
    if (tool.started_ns) |started| tool.duration_ms = (nowNs(io) -| started) / std.time.ns_per_ms;
    tool.elapsed_ms = null;
    tool.details_present = payload.result.details != null;
    const result_ui = try self.tool_resolver.resolveResult(item.allocator(), payload.tool_name, payload.is_error, payload.result.content, payload.result.details);
    if (result_ui.body) |body| try self.replaceToolBody(item, body);
    if (result_ui.footer) |footer| try self.replaceToolFooter(item, footer);
    _ = self.live_tools.orderedRemove(tool.call_id);
    self.invalidateItem(item, .rebuild);
}

fn ensurePart(self: *Transcript, index: usize, tag: PartTag) !*Part {
    const item = self.streaming_item orelse blk: {
        const created = try self.createAssistantItem(true);
        self.streaming_item = created;
        try self.appendItem(created);
        break :blk created;
    };
    std.debug.assert(item.kind == .assistant);
    const assistant = &item.kind.assistant;
    var changed = false;
    if (assistant.parts.items.len <= index) {
        const additional = index + 1 - assistant.parts.items.len;
        try assistant.parts.ensureUnusedCapacity(item.allocator(), additional);
        try assistant.pending_utf8.ensureUnusedCapacity(item.allocator(), additional);
        for (0..additional) |_| {
            assistant.parts.appendAssumeCapacity(.{ .text = .empty });
            assistant.pending_utf8.appendAssumeCapacity(.{});
        }
        changed = true;
    }
    std.debug.assert(assistant.parts.items.len == assistant.pending_utf8.items.len);
    const part = &assistant.parts.items[index];
    if (part.tag() != tag) {
        self.total_bytes -|= part.bytes().len;
        part.* = switch (tag) {
            .text => .{ .text = .empty },
            .thinking => .{ .thinking = .empty },
        };
        assistant.pending_utf8.items[index].len = 0;
        changed = true;
    }
    if (changed) self.invalidateItem(item, .rebuild);
    return part;
}

fn appendAssistantPart(self: *Transcript, index: usize, part: *Part, text: []const u8) !void {
    const item = self.streaming_item.?;
    const assistant = &item.kind.assistant;
    const old_len = part.bytes().len;
    const old_truncated = assistant.truncated;
    try self.appendAssistantUtf8(
        item,
        part.list(),
        &assistant.pending_utf8.items[index],
        text,
        &assistant.truncated,
    );
    if (part.bytes().len != old_len or assistant.truncated != old_truncated) {
        self.invalidateItem(item, .source_appended);
    }
}

fn replaceAssistantPart(self: *Transcript, index: usize, part: *Part, text: []const u8) !void {
    const item = self.streaming_item.?;
    const assistant = &item.kind.assistant;
    const pending = &assistant.pending_utf8.items[index];
    if (pending.len == 0 and std.mem.eql(u8, part.bytes(), text)) return;
    self.total_bytes -|= part.bytes().len;
    part.list().clearRetainingCapacity();
    pending.len = 0;
    try self.appendAssistantUtf8(item, part.list(), pending, text, &assistant.truncated);
    try self.finishAssistantUtf8(item, part.list(), pending, &assistant.truncated);
    self.invalidateItem(item, .rebuild);
}

const replacement_character = "\xef\xbf\xbd";

fn appendAssistantUtf8(
    self: *Transcript,
    item: *Item,
    list: *std.ArrayList(u8),
    pending_utf8: *PendingUtf8,
    text: []const u8,
    truncated: *bool,
) !void {
    var consumed: usize = 0;

    if (pending_utf8.len > 0) {
        const expected = std.unicode.utf8ByteSequenceLength(pending_utf8.bytes[0]) catch unreachable;
        while (pending_utf8.len < expected and consumed < text.len) {
            const byte = text[consumed];
            if (byte & 0xc0 != 0x80) {
                try self.appendAssistantUtf8Run(item, list, replacement_character, truncated);
                pending_utf8.len = 0;
                break;
            }
            pending_utf8.bytes[pending_utf8.len] = byte;
            pending_utf8.len += 1;
            consumed += 1;
        }
        if (pending_utf8.len > 0) {
            if (pending_utf8.len < expected) return;
            const pending = pending_utf8.bytes[0..pending_utf8.len];
            if (std.unicode.utf8Decode(pending)) |_| {
                try self.appendAssistantUtf8Run(item, list, pending, truncated);
            } else |_| {
                try self.appendAssistantUtf8Run(item, list, replacement_character, truncated);
            }
            pending_utf8.len = 0;
        }
    }

    var index = consumed;
    var valid_start = index;
    while (index < text.len) {
        const byte = text[index];
        if (byte < 0x80) {
            index += 1;
            continue;
        }
        const sequence_len = std.unicode.utf8ByteSequenceLength(byte) catch {
            try self.appendAssistantUtf8Run(item, list, text[valid_start..index], truncated);
            try self.appendAssistantUtf8Run(item, list, replacement_character, truncated);
            index += 1;
            valid_start = index;
            continue;
        };
        if (text.len - index < sequence_len) {
            var potential_prefix = true;
            for (text[index + 1 ..]) |continuation| {
                if (continuation & 0xc0 != 0x80) {
                    potential_prefix = false;
                    break;
                }
            }
            if (potential_prefix) {
                try self.appendAssistantUtf8Run(item, list, text[valid_start..index], truncated);
                const suffix = text[index..];
                std.debug.assert(suffix.len < pending_utf8.bytes.len);
                @memcpy(pending_utf8.bytes[0..suffix.len], suffix);
                pending_utf8.len = @intCast(suffix.len);
                return;
            }
        } else if (std.unicode.utf8Decode(text[index .. index + sequence_len])) |_| {
            index += sequence_len;
            continue;
        } else |_| {}

        try self.appendAssistantUtf8Run(item, list, text[valid_start..index], truncated);
        try self.appendAssistantUtf8Run(item, list, replacement_character, truncated);
        index += 1;
        valid_start = index;
    }
    try self.appendAssistantUtf8Run(item, list, text[valid_start..], truncated);
}

fn appendAssistantUtf8Run(
    self: *Transcript,
    item: *Item,
    list: *std.ArrayList(u8),
    text: []const u8,
    truncated: *bool,
) !void {
    if (text.len == 0) return;
    try self.appendListBounded(item, list, text, per_item_text_bytes_max, truncated, true);
}

fn finishAssistantUtf8(
    self: *Transcript,
    item: *Item,
    list: *std.ArrayList(u8),
    pending_utf8: *PendingUtf8,
    truncated: *bool,
) !void {
    if (pending_utf8.len == 0) return;
    pending_utf8.len = 0;
    try self.appendAssistantUtf8Run(item, list, replacement_character, truncated);
}

fn appendToolArgs(self: *Transcript, item: *Item, delta: []const u8) !void {
    std.debug.assert(item.kind == .tool);
    const tool = &item.kind.tool;
    const preview_len = tool.args_preview.items.len;
    const was_truncated = tool.args_truncated;
    try self.appendListBounded(item, &tool.args_preview, delta, blocks.args_preview_bytes_max, &tool.args_truncated, false);
    if (tool.args_preview.items.len == preview_len and tool.args_truncated == was_truncated) return;
    const ui = try self.tool_resolver.resolve(item.allocator(), tool.name, .{ .json_prefix = tool.args_preview.items });
    try self.applyToolUi(item, ui);
}

fn applyToolArgsPreview(self: *Transcript, item: *Item, value: std.json.Value) !void {
    if (!hasToolArgsPreview(value)) return;
    try self.setToolTitleFromValue(item, value);
}

fn hasToolArgsPreview(value: std.json.Value) bool {
    if (value != .object) return false;
    return value.object.count() != 0;
}

fn setToolTitleFromValue(self: *Transcript, item: *Item, value: std.json.Value) !void {
    std.debug.assert(item.kind == .tool);
    const tool = &item.kind.tool;
    const ui = try self.tool_resolver.resolve(item.allocator(), tool.name, .{ .value = value });
    try self.applyToolUi(item, ui);
}

fn applyToolUi(self: *Transcript, item: *Item, ui: ToolUi) !void {
    std.debug.assert(item.kind == .tool);
    const tool = &item.kind.tool;
    if (ui.title) |title| tool.title = title;
    if (ui.compact_title) |compact_title| tool.compact_title = compact_title;
    tool.display = ui.display;
    try self.applyToolBodyUpdate(item, ui.body_update);
    self.invalidateItem(item, .rebuild);
}

fn applyToolBodyUpdate(self: *Transcript, item: *Item, update: ToolBodyUpdate) !void {
    switch (update) {
        .unchanged => {},
        .clear => {
            try self.replaceToolBody(item, "");
            try self.replaceToolFooter(item, "");
        },
        .replace => |replace| {
            try self.replaceToolBody(item, replace.body);
            try self.replaceToolFooter(item, replace.footer);
        },
    }
}

fn replaceToolBody(self: *Transcript, item: *Item, body: ?[]const u8) !void {
    std.debug.assert(item.kind == .tool);
    const tool = &item.kind.tool;
    self.total_bytes -|= tool.body.items.len;
    tool.body.clearRetainingCapacity();
    tool.body_truncated = false;
    const text = body orelse {
        self.invalidateItem(item, .rebuild);
        return;
    };
    try self.appendListBounded(item, &tool.body, text, blocks.tool_body_bytes_max, &tool.body_truncated, true);
    self.invalidateItem(item, .rebuild);
}

fn replaceToolFooter(self: *Transcript, item: *Item, footer: ?[]const u8) !void {
    std.debug.assert(item.kind == .tool);
    item.kind.tool.footer = if (footer) |value| value else "";
    self.invalidateItem(item, .rebuild);
}

fn reconcileAssistant(self: *Transcript, item: *Item, assistant_message: ai.AssistantMessage) !void {
    std.debug.assert(item.kind == .assistant);
    for (assistant_message.content, 0..) |content, index| switch (content) {
        .text => |text| {
            const part = try self.ensureFinalPart(item, index, .text);
            try self.replaceFinalPart(item, index, part, text.text);
        },
        .thinking => |thinking| {
            const part = try self.ensureFinalPart(item, index, .thinking);
            try self.replaceFinalPart(item, index, part, thinking.thinking);
        },
        .tool_call => |call| {
            self.clearFinalPart(item, index);
            const tool = try self.ensureToolItem(call.id, call.name, call.arguments, true);
            try self.setToolTitleFromValue(tool, call.arguments);
        },
    };
    self.truncateFinalParts(item, assistant_message.content.len);
}

fn ensureFinalPart(self: *Transcript, item: *Item, index: usize, tag: PartTag) !*Part {
    std.debug.assert(item.kind == .assistant);
    const assistant = &item.kind.assistant;
    if (assistant.parts.items.len <= index) {
        const additional = index + 1 - assistant.parts.items.len;
        try assistant.parts.ensureUnusedCapacity(item.allocator(), additional);
        try assistant.pending_utf8.ensureUnusedCapacity(item.allocator(), additional);
        for (0..additional) |_| {
            assistant.parts.appendAssumeCapacity(.{ .text = .empty });
            assistant.pending_utf8.appendAssumeCapacity(.{});
        }
    }
    std.debug.assert(assistant.parts.items.len == assistant.pending_utf8.items.len);
    const part = &assistant.parts.items[index];
    if (part.tag() != tag) {
        self.total_bytes -|= part.bytes().len;
        part.* = switch (tag) {
            .text => .{ .text = .empty },
            .thinking => .{ .thinking = .empty },
        };
        assistant.pending_utf8.items[index].len = 0;
    }
    return part;
}

fn clearFinalPart(self: *Transcript, item: *Item, index: usize) void {
    std.debug.assert(item.kind == .assistant);
    const assistant = &item.kind.assistant;
    if (index >= assistant.parts.items.len) return;
    const part = &assistant.parts.items[index];
    self.total_bytes -|= part.bytes().len;
    part.list().clearRetainingCapacity();
    part.* = .{ .text = .empty };
    item.kind.assistant.pending_utf8.items[index].len = 0;
    self.invalidateItem(item, .rebuild);
}

fn truncateFinalParts(self: *Transcript, item: *Item, len: usize) void {
    std.debug.assert(item.kind == .assistant);
    const assistant = &item.kind.assistant;
    if (assistant.parts.items.len <= len) return;
    for (assistant.parts.items[len..]) |part| self.total_bytes -|= part.bytes().len;
    assistant.parts.items.len = len;
    assistant.pending_utf8.items.len = len;
    self.invalidateItem(item, .rebuild);
}

fn replaceFinalPart(self: *Transcript, item: *Item, index: usize, part: *Part, text: []const u8) !void {
    const assistant = &item.kind.assistant;
    const pending = &assistant.pending_utf8.items[index];
    if (pending.len == 0 and std.mem.eql(u8, part.bytes(), text)) return;
    self.total_bytes -|= part.bytes().len;
    part.list().clearRetainingCapacity();
    pending.len = 0;
    try self.appendAssistantUtf8(item, part.list(), pending, text, &assistant.truncated);
    try self.finishAssistantUtf8(item, part.list(), pending, &assistant.truncated);
    self.invalidateItem(item, .rebuild);
}

fn findToolItem(self: *Transcript, call_id: []const u8) ?*Item {
    var index = self.items.items.len;
    while (index > 0) {
        index -= 1;
        const item = self.items.items[index];
        if (item.kind != .tool) continue;
        if (std.mem.eql(u8, item.kind.tool.call_id, call_id)) return item;
    }
    return null;
}

fn ensureToolItem(self: *Transcript, call_id: []const u8, name: []const u8, args: std.json.Value, create_new_if_terminal: bool) !*Item {
    if (self.live_tools.get(call_id)) |item| return item;
    if (self.findToolItem(call_id)) |item| {
        if (!create_new_if_terminal or !isTerminalToolStatus(item.kind.tool.status)) return item;
    }
    const item = try self.createToolItem(call_id, name, args);
    try self.appendItem(item);
    try self.live_tools.put(self.gpa, item.kind.tool.call_id, item);
    return item;
}

fn isTerminalToolStatus(status: blocks.Status) bool {
    return switch (status) {
        .done, .failed, .aborted => true,
        .pending, .running => false,
    };
}

fn mergeToolStatus(old: blocks.Status, new: blocks.Status) blocks.Status {
    return switch (old) {
        .aborted => .aborted,
        .done, .failed => if (new == .running or new == .pending) old else new,
        .pending, .running => new,
    };
}

fn appendCustom(self: *Transcript, custom: agent_mod.CustomAgentMessage) !void {
    const item = try self.createCustomItem(custom);
    try self.appendItem(item);
    try self.enforceCaps();
}

fn createUserItem(self: *Transcript, text: []const u8) !*Item {
    const item = try self.createItem(.{ .user = .{ .text = .empty } });
    try self.appendUserText(item, text);
    return item;
}

fn createUserMessageItem(self: *Transcript, user: ai.UserMessage) !*Item {
    const item = try self.createItem(.{ .user = .{ .text = .empty } });
    switch (user.content) {
        .string => |text| try self.appendUserText(item, text),
        .blocks => |blocks_slice| for (blocks_slice) |block| switch (block) {
            .text => |text| try self.appendUserText(item, text.text),
            .image => |image| try self.appendUserImage(item, image.mime_type),
        },
    }
    return item;
}

fn appendUserText(self: *Transcript, item: *Item, text: []const u8) !void {
    const old_len = item.kind.user.text.items.len;
    const old_truncated = item.kind.user.truncated;
    try self.appendListBounded(item, &item.kind.user.text, text, per_item_text_bytes_max, &item.kind.user.truncated, true);
    if (item.kind.user.text.items.len != old_len or item.kind.user.truncated != old_truncated) {
        self.invalidateItem(item, .rebuild);
    }
}

fn appendUserImage(self: *Transcript, item: *Item, mime_type: []const u8) !void {
    if (item.kind.user.text.items.len != 0 and item.kind.user.text.items[item.kind.user.text.items.len - 1] != '\n') {
        try self.appendUserText(item, "\n");
    }
    try self.appendUserText(item, imageFallbackText(mime_type));
}

fn createAssistantItem(self: *Transcript, streaming: bool) !*Item {
    return self.createItem(.{ .assistant = .{ .parts = .empty, .streaming = streaming } });
}

fn createCustomItem(self: *Transcript, custom: agent_mod.CustomAgentMessage) !*Item {
    const item = try self.createItem(.{ .custom = .{ .title = undefined, .text = undefined } });
    const allocator = item.allocator();
    item.kind.custom.title = try allocator.dupe(u8, custom.kind);
    item.kind.custom.text = try jsonValueString(allocator, custom.payload);
    self.total_bytes += item.kind.custom.title.len + item.kind.custom.text.len;
    return item;
}

fn createToolItem(self: *Transcript, call_id: []const u8, name: []const u8, args: std.json.Value) !*Item {
    const item = try self.createItem(.{ .tool = .{
        .call_id = undefined,
        .name = undefined,
        .title = undefined,
        .compact_title = undefined,
        .display = blocks.default_tool_display,
        .args_preview = .empty,
        .body = .empty,
        .status = .pending,
        .footer = "",
    } });
    const allocator = item.allocator();
    item.kind.tool.call_id = try allocator.dupe(u8, call_id);
    item.kind.tool.name = try allocator.dupe(u8, name);
    const ui = try self.tool_resolver.resolve(allocator, name, .{ .value = args });
    item.kind.tool.title = ui.title orelse try allocator.dupe(u8, name);
    item.kind.tool.compact_title = ui.compact_title orelse "";
    item.kind.tool.display = ui.display;
    try self.applyToolBodyUpdate(item, ui.body_update);
    return item;
}

fn createItem(self: *Transcript, kind: Item.Kind) !*Item {
    const item = try self.gpa.create(Item);
    errdefer self.gpa.destroy(item);
    item.* = .{
        .arena = std.heap.ArenaAllocator.init(self.gpa),
        .seq = self.next_seq,
        .layout_cache = .{ .active = .{ .arena = std.heap.ArenaAllocator.init(self.gpa) } },
        .kind = kind,
    };
    self.next_seq +%= 1;
    return item;
}

fn appendItem(self: *Transcript, item: *Item) !void {
    item.index = self.items.items.len;
    try self.items.append(self.gpa, item);
    self.noteInvalidItem(item.index);
}

fn invalidateItem(self: *Transcript, item: *Item, invalidation: LayoutInvalidation) void {
    item.content_generation +%= 1;
    item.layout_cache.invalidation = switch (item.layout_cache.invalidation) {
        .rebuild => .rebuild,
        .source_appended => if (invalidation == .rebuild) .rebuild else .source_appended,
        .clean => invalidation,
    };
    if (item.layout_cache.pending) |pending| {
        self.deinitCachedLayout(pending);
        self.gpa.destroy(pending);
        item.layout_cache.pending = null;
        if (self.derived.relayout) |*job| job.next_item = @min(job.next_item, item.index);
    }
    if (item.index < self.items.items.len and self.items.items[item.index] == item) {
        self.noteInvalidItem(item.index);
    }
}

fn noteInvalidItem(self: *Transcript, index: usize) void {
    self.derived.first_invalid_item = if (self.derived.first_invalid_item) |current| @min(current, index) else index;
}

fn appendListBounded(
    self: *Transcript,
    item: *Item,
    list: *std.ArrayList(u8),
    text: []const u8,
    max_bytes: usize,
    truncated: *bool,
    count_total: bool,
) !void {
    var remaining = text;
    while (remaining.len > 0) {
        if (list.items.len >= max_bytes) {
            try self.appendTruncationMarker(item, list, max_bytes, truncated, count_total);
            return;
        }
        const room = max_bytes - list.items.len;
        const chunk_len = @min(room, append_chunk_bytes_max, remaining.len);
        const chunk = agent_mod.utf8Prefix(remaining, chunk_len);
        if (chunk.len == 0) {
            try self.appendTruncationMarker(item, list, max_bytes, truncated, count_total);
            return;
        }
        try list.appendSlice(item.allocator(), chunk);
        if (count_total) self.total_bytes += chunk.len;
        remaining = remaining[chunk.len..];
        if (remaining.len == 0) return;
        if (chunk_len == room) {
            try self.appendTruncationMarker(item, list, max_bytes, truncated, count_total);
            return;
        }
    }
}

fn appendTruncationMarker(self: *Transcript, item: *Item, list: *std.ArrayList(u8), max_bytes: usize, truncated: *bool, count_total: bool) !void {
    if (truncated.*) return;
    truncated.* = true;
    const room = max_bytes -| list.items.len;
    if (list.items.len != 0 and list.items[list.items.len - 1] != '\n' and room > 0) {
        try list.append(item.allocator(), '\n');
        if (count_total) self.total_bytes += 1;
    }
    const remaining_room = max_bytes -| list.items.len;
    const chunk = agent_mod.utf8Prefix(blocks.output_truncated_text, remaining_room);
    try list.appendSlice(item.allocator(), chunk);
    if (count_total) self.total_bytes += chunk.len;
}

fn abortLiveTools(self: *Transcript, io: std.Io) !void {
    for (self.live_tools.values()) |item| {
        if (item.kind != .tool) continue;
        switch (item.kind.tool.status) {
            .pending, .running => {
                const tool = &item.kind.tool;
                if (tool.started_ns) |started| tool.duration_ms = (nowNs(io) -| started) / std.time.ns_per_ms;
                tool.elapsed_ms = null;
                tool.status = .aborted;
                self.invalidateItem(item, .rebuild);
            },
            else => {},
        }
    }
}

fn enforceCaps(self: *Transcript) !void {
    while (self.items.items.len > transcript_items_max or self.total_bytes > transcript_bytes_max) {
        if (self.items.items.len == 0) break;
        const item = self.items.orderedRemove(0);
        if (item.kind == .tool) _ = self.live_tools.orderedRemove(item.kind.tool.call_id);
        if (self.streaming_item == item) self.streaming_item = null;
        self.total_bytes -|= itemBytes(item);
        self.evicted_seqs += 1;
        self.destroyItem(item);
        for (self.items.items, 0..) |remaining, index| remaining.index = index;
        self.derived.first_invalid_item = 0;
        if (self.derived.relayout) |*job| job.next_item = 0;
    }
}

fn deinitCachedLayout(self: *Transcript, cache: *CachedLayout) void {
    cache.incremental_lines.deinit(self.gpa);
    cache.incremental_roles.deinit(self.gpa);
    cache.arena.deinit();
    cache.* = undefined;
}

fn destroyItem(self: *Transcript, item: *Item) void {
    if (item.layout_cache.pending) |pending| {
        self.deinitCachedLayout(pending);
        self.gpa.destroy(pending);
    }
    self.deinitCachedLayout(&item.layout_cache.active);
    item.arena.deinit();
    self.gpa.destroy(item);
}

fn itemBytes(item: *const Item) usize {
    return switch (item.kind) {
        .user => |user| user.text.items.len,
        .assistant => |assistant| blk: {
            var total: usize = 0;
            for (assistant.parts.items) |part| total += part.bytes().len;
            if (assistant.error_text) |err| total += err.len;
            break :blk total;
        },
        .tool => |tool| tool.body.items.len,
        .notice => |notice| notice.text.len,
        .compaction => |compaction| compaction.summary.items.len,
        .custom => |custom| custom.title.len + custom.text.len,
    };
}

fn imageFallbackText(mime_type: []const u8) []const u8 {
    if (mime_type.len == 0) return "[Image]";
    if (std.mem.eql(u8, mime_type, "image/png")) return "[Image: image/png]";
    if (std.mem.eql(u8, mime_type, "image/jpeg")) return "[Image: image/jpeg]";
    if (std.mem.eql(u8, mime_type, "image/gif")) return "[Image: image/gif]";
    if (std.mem.eql(u8, mime_type, "image/webp")) return "[Image: image/webp]";
    return "[Image]";
}

fn userText(user: ai.UserMessage) []const u8 {
    return switch (user.content) {
        .string => |text| text,
        .blocks => |blocks_slice| blk: {
            for (blocks_slice) |block| if (block == .text) break :blk block.text.text;
            break :blk "";
        },
    };
}

test "transcript user block has panel padding and item margin" {
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();

    try transcript.apply(std.testing.io, .{ .message_start = .{ .message = .{ .user = .{ .content = .{ .string = "hello" }, .timestamp = 0 } } } });
    const state: theme.LayoutState = .{ .width = 40, .height = 10 };
    const prepared = try transcript.prepareLayout(state);
    try std.testing.expectEqual(PrepareResult.published, prepared);
    const lines = transcript.items.items[0].layout_cache.active.lines;

    var buffer: [64]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), lines.len);
    try std.testing.expectEqualStrings("", lines[0].copyText(&buffer));
    try std.testing.expect(std.meta.eql(lines[0].row_style.bg, screen.surface.user_message.bg));
    try std.testing.expectEqualStrings(" hello", lines[1].copyText(&buffer));
    try std.testing.expect(std.meta.eql(lines[1].row_style.bg, screen.surface.user_message.bg));
    try std.testing.expectEqualStrings("", lines[2].copyText(&buffer));
    try std.testing.expect(std.meta.eql(lines[2].row_style.bg, screen.surface.user_message.bg));
    try std.testing.expectEqualStrings("", lines[3].copyText(&buffer));
    try std.testing.expect(screen.Style.eql(lines[3].row_style, screen.surface.transparent));
}

test "transcript user block renders image placeholders" {
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();

    const content = [_]ai.UserContent{
        .{ .text = .{ .text = "look" } },
        .{ .image = .{ .data = "abc", .mime_type = "image/png" } },
    };
    try transcript.apply(std.testing.io, .{ .message_start = .{ .message = .{ .user = .{ .content = .{ .blocks = &content }, .timestamp = 0 } } } });
    const state: theme.LayoutState = .{ .width = 40, .height = 10 };
    _ = try transcript.prepareLayout(state);
    const lines = transcript.items.items[0].layout_cache.active.lines;

    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings(" look", lines[1].copyText(&buffer));
    try std.testing.expectEqualStrings(" [Image: image/png]", lines[2].copyText(&buffer));
}

test "transcript visible thinking trims trailing blank rows" {
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();

    const content = [_]ai.AssistantContent{.{ .thinking = .{ .thinking = "**plan** first\n\n" } }};
    const assistant = emptyAssistantMessage(&content, .stop);
    try transcript.apply(std.testing.io, .{ .message_start = .{ .message = .{ .assistant = assistant } } });
    try transcript.apply(std.testing.io, .{ .message_end = .{ .message = .{ .assistant = assistant } } });
    const state: theme.LayoutState = .{ .width = 60, .height = 10, .hide_thinking = false };
    _ = try transcript.prepareLayout(state);
    const lines = transcript.items.items[0].layout_cache.active.lines;

    var buffer: [64]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings(" plan first", lines[0].copyText(&buffer));
    try std.testing.expect(lines[0].spans()[1].style.italic);
    try std.testing.expectEqualStrings("", lines[1].copyText(&buffer));
}

test "transcript custom message renders padded title body and margin" {
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();

    try transcript.apply(std.testing.io, .{ .message_start = .{ .message = .{ .custom = .{ .kind = "Session Info", .payload = .{ .string = "ok" }, .timestamp = 0 } } } });
    const state: theme.LayoutState = .{ .width = 40, .height = 10 };
    _ = try transcript.prepareLayout(state);
    const lines = transcript.items.items[0].layout_cache.active.lines;

    var buffer: [64]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 6), lines.len);
    try std.testing.expectEqualStrings("", lines[0].copyText(&buffer));
    try std.testing.expectEqualStrings(" Session Info", lines[1].copyText(&buffer));
    try std.testing.expectEqualStrings("", lines[2].copyText(&buffer));
    try std.testing.expectEqualStrings(" \"ok\"", lines[3].copyText(&buffer));
    try std.testing.expectEqualStrings("", lines[4].copyText(&buffer));
    try std.testing.expect(std.meta.eql(lines[4].row_style.bg, screen.surface.custom_message.bg));
    try std.testing.expectEqualStrings("", lines[5].copyText(&buffer));
    try std.testing.expect(screen.Style.eql(lines[5].row_style, screen.surface.transparent));
}

test "transcript streams visible thinking without a synthetic label" {
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();

    try transcript.apply(std.testing.io, .{ .message_start = .{
        .message = .{ .assistant = emptyAssistantMessage(&.{}, .stop) },
    } });
    try transcript.apply(std.testing.io, .{ .message_update = .{ .assistant_message_event = .{ .thinking_delta = .{
        .content_index = 0,
        .delta = "plan",
        .partial = emptyAssistantMessage(&.{}, .stop),
    } } } });

    const state: theme.LayoutState = .{ .width = 40, .height = 10, .hide_thinking = false };
    _ = try transcript.prepareLayout(state);
    const lines = transcript.items.items[0].layout_cache.active.lines;

    var buffer: [64]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings(" plan", lines[0].copyText(&buffer));
    try std.testing.expect(lines[0].spans()[1].style.italic);
    try std.testing.expectEqualStrings("", lines[1].copyText(&buffer));
}

test "transcript separates and styles visible thinking before answer" {
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();

    const content = [_]ai.AssistantContent{
        .{ .thinking = .{ .thinking = "plan" } },
        .{ .text = .{ .text = "answer" } },
    };
    const assistant = emptyAssistantMessage(&content, .stop);
    try transcript.apply(std.testing.io, .{ .message_start = .{ .message = .{ .assistant = assistant } } });
    try transcript.apply(std.testing.io, .{ .message_end = .{ .message = .{ .assistant = assistant } } });
    const state: theme.LayoutState = .{ .width = 40, .height = 10, .hide_thinking = false };
    _ = try transcript.prepareLayout(state);
    const lines = transcript.items.items[0].layout_cache.active.lines;

    var buffer: [64]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), lines.len);
    try std.testing.expectEqualStrings(" plan", lines[0].copyText(&buffer));
    try std.testing.expect(lines[0].spans()[1].style.italic);
    try std.testing.expectEqualStrings("", lines[1].copyText(&buffer));
    try std.testing.expectEqualStrings(" answer", lines[2].copyText(&buffer));
    try std.testing.expect(!lines[2].spans()[1].style.italic);
    try std.testing.expectEqualStrings("", lines[3].copyText(&buffer));
}

test "transcript hidden thinking label persists after answer completes" {
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();

    try transcript.apply(std.testing.io, .{ .message_start = .{
        .message = .{ .assistant = emptyAssistantMessage(&.{}, .stop) },
    } });
    try transcript.apply(std.testing.io, .{ .message_update = .{ .assistant_message_event = .{ .thinking_delta = .{
        .content_index = 0,
        .delta = "plan",
        .partial = emptyAssistantMessage(&.{}, .stop),
    } } } });
    try transcript.apply(std.testing.io, .{ .message_update = .{ .assistant_message_event = .{ .text_delta = .{
        .content_index = 1,
        .delta = "answer",
        .partial = emptyAssistantMessage(&.{}, .stop),
    } } } });

    const state: theme.LayoutState = .{ .width = 40, .height = 10, .hide_thinking = true };
    _ = try transcript.prepareLayout(state);
    var lines = transcript.items.items[0].layout_cache.active.lines;
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings(" Thinking...", lines[0].copyText(&buffer));

    const content = [_]ai.AssistantContent{
        .{ .thinking = .{ .thinking = "plan" } },
        .{ .text = .{ .text = "answer" } },
    };
    try transcript.apply(std.testing.io, .{ .message_end = .{
        .message = .{ .assistant = emptyAssistantMessage(&content, .stop) },
    } });
    _ = try transcript.prepareLayout(state);
    lines = transcript.items.items[0].layout_cache.active.lines;

    try std.testing.expectEqual(@as(usize, 4), lines.len);
    try std.testing.expectEqualStrings(" Thinking...", lines[0].copyText(&buffer));
    try std.testing.expect(lines[0].spans()[1].style.italic);
    try std.testing.expectEqualStrings("", lines[1].copyText(&buffer));
    try std.testing.expectEqualStrings(" answer", lines[2].copyText(&buffer));
    try std.testing.expect(!lines[2].spans()[1].style.italic);
}

test "transcript assistant error is a distinct row without leading blank" {
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();

    var assistant = emptyAssistantMessage(&.{}, .error_);
    assistant.error_message = "boom";
    try transcript.apply(std.testing.io, .{ .message_start = .{ .message = .{ .assistant = assistant } } });
    try transcript.apply(std.testing.io, .{ .message_end = .{ .message = .{ .assistant = assistant } } });
    const state: theme.LayoutState = .{ .width = 40, .height = 10 };
    _ = try transcript.prepareLayout(state);
    const lines = transcript.items.items[0].layout_cache.active.lines;

    var buffer: [64]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings(" error: boom", lines[0].copyText(&buffer));
    try std.testing.expect(std.meta.eql(lines[0].spans()[1].style.fg, screen.text.error_.fg));
    try std.testing.expectEqualStrings("", lines[1].copyText(&buffer));
}

test "transcript compaction is a padded collapsed and expanded summary block" {
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();

    try transcript.appendCompaction("first\n\nsecond", 1234);
    const collapsed_state: theme.LayoutState = .{ .width = 60, .height = 10 };
    _ = try transcript.prepareLayout(collapsed_state);
    var lines = transcript.items.items[0].layout_cache.active.lines;

    var buffer: [96]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 6), lines.len);
    try std.testing.expectEqualStrings("", lines[0].copyText(&buffer));
    try std.testing.expectEqualStrings(" [compaction]", lines[1].copyText(&buffer));
    try std.testing.expectEqualStrings("", lines[2].copyText(&buffer));
    try std.testing.expectEqualStrings(" Compacted from 1234 tokens (ctrl+o to expand)", lines[3].copyText(&buffer));
    try std.testing.expectEqualStrings("", lines[4].copyText(&buffer));
    try std.testing.expect(std.meta.eql(lines[4].row_style.bg, screen.surface.custom_message.bg));
    try std.testing.expectEqualStrings("", lines[5].copyText(&buffer));

    const expanded_state: theme.LayoutState = .{ .width = 60, .height = 10, .expanded = true };
    _ = try transcript.prepareLayout(expanded_state);
    lines = transcript.items.items[0].layout_cache.active.lines;
    try std.testing.expectEqual(@as(usize, 10), lines.len);
    try std.testing.expectEqualStrings(" Compacted from 1234 tokens", lines[3].copyText(&buffer));
    try std.testing.expectEqualStrings("", lines[4].copyText(&buffer));
    try std.testing.expectEqualStrings(" first", lines[5].copyText(&buffer));
    try std.testing.expectEqualStrings("", lines[6].copyText(&buffer));
    try std.testing.expectEqualStrings(" second", lines[7].copyText(&buffer));
    try std.testing.expectEqualStrings("", lines[8].copyText(&buffer));
    try std.testing.expect(std.meta.eql(lines[8].row_style.bg, screen.surface.custom_message.bg));
    try std.testing.expectEqualStrings("", lines[9].copyText(&buffer));
}

test "transcript markdown reserves a span for outer inset" {
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();

    const text = "a **b** c **d** e **f** g **h** i **j** k **l** m **n** o **p** q";
    const content = [_]ai.AssistantContent{.{ .text = .{ .text = text } }};
    const assistant = emptyAssistantMessage(&content, .stop);
    try transcript.apply(std.testing.io, .{ .message_start = .{ .message = .{ .assistant = assistant } } });
    try transcript.apply(std.testing.io, .{ .message_end = .{ .message = .{ .assistant = assistant } } });
    const state: theme.LayoutState = .{ .width = 100, .height = 10 };
    _ = try transcript.prepareLayout(state);
    const line = transcript.items.items[0].layout_cache.active.lines[0];

    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings(" a b c d e f g h i j k l m n o **p** q", line.copyText(&buffer));
    try std.testing.expectEqual(@as(usize, screen.span_capacity), line.spans().len);
}

test "transcript settled assistant trims trailing blank rows" {
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();

    const content = [_]ai.AssistantContent{.{ .text = .{ .text = "answer\n\n" } }};
    const assistant = emptyAssistantMessage(&content, .stop);
    try transcript.apply(std.testing.io, .{ .message_start = .{ .message = .{ .assistant = assistant } } });
    try transcript.apply(std.testing.io, .{ .message_end = .{ .message = .{ .assistant = assistant } } });
    const state: theme.LayoutState = .{ .width = 40, .height = 10 };
    _ = try transcript.prepareLayout(state);
    const lines = transcript.items.items[0].layout_cache.active.lines;

    var buffer: [64]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings(" answer", lines[0].copyText(&buffer));
    try std.testing.expectEqualStrings("", lines[1].copyText(&buffer));
}

fn toolCallAt(message: ai.AssistantMessage, index: usize) ?ai.ToolCall {
    if (index >= message.content.len) return null;
    return switch (message.content[index]) {
        .tool_call => |call| call,
        else => null,
    };
}

fn transcriptInnerWidth(width: u16) u16 {
    const padding = transcript_padding_x * 2;
    return if (width <= padding) 0 else @intCast(@as(usize, width) - padding);
}

const RhythmedLayout = struct {
    lines: []layout.Line,
    roles: []RowRole,
};

fn applyItemRhythm(allocator: std.mem.Allocator, kind: Item.Kind, content: []layout.Line) !RhythmedLayout {
    if (content.len == 0) return .{ .lines = &.{}, .roles = &.{} };
    var lines = std.ArrayList(layout.Line).empty;
    errdefer lines.deinit(allocator);
    var roles = std.ArrayList(RowRole).empty;
    errdefer roles.deinit(allocator);
    const style = itemStyle(kind);
    const padding_y = itemPaddingY(kind);
    const total = content.len + padding_y * 2 + item_margin_bottom;
    try lines.ensureTotalCapacity(allocator, total);
    try roles.ensureTotalCapacity(allocator, total);

    for (0..padding_y) |_| {
        try lines.append(allocator, .{ .row_style = style });
        try roles.append(allocator, .panel_padding);
    }
    for (content) |source| {
        const role = contentRowRole(source);
        var line = source;
        if (screen.Style.eql(line.row_style, screen.surface.transparent) and !screen.Style.eql(style, screen.surface.transparent)) line.row_style = style;
        if (line.spans().len > 0) try insetTranscriptLine(&line, lineInsetStyle(kind, line));
        try lines.append(allocator, line);
        try roles.append(allocator, role);
    }
    for (0..padding_y) |_| {
        try lines.append(allocator, .{ .row_style = style });
        try roles.append(allocator, .panel_padding);
    }
    for (0..item_margin_bottom) |_| {
        try lines.append(allocator, .{});
        try roles.append(allocator, .item_margin);
    }
    const owned_lines = try lines.toOwnedSlice(allocator);
    errdefer allocator.free(owned_lines);
    const owned_roles = try roles.toOwnedSlice(allocator);
    return .{ .lines = owned_lines, .roles = owned_roles };
}

fn contentRowRole(line: layout.Line) RowRole {
    return if (line.spans().len == 0) .semantic_blank else .content;
}

fn itemPaddingY(kind: Item.Kind) usize {
    return switch (kind) {
        .user => user_padding_y,
        .compaction, .custom => custom_padding_y,
        else => 0,
    };
}

fn itemStyle(kind: Item.Kind) screen.Style {
    return switch (kind) {
        .user => screen.surface.user_message,
        .compaction, .custom => screen.surface.custom_message,
        else => screen.surface.transparent,
    };
}

fn lineInsetStyle(kind: Item.Kind, line: layout.Line) screen.Style {
    if (line.spans().len > 0) return line.spans()[0].style;
    return itemStyle(kind);
}

fn insetTranscriptLine(line: *layout.Line, style: screen.Style) error{LineFull}!void {
    if (transcript_padding_x == 0) return;
    try line.prepend(.{ .text = padding_spaces[0..transcript_padding_x], .style = style });
}

fn layoutCompaction(
    allocator: std.mem.Allocator,
    compaction: anytype,
    width: u16,
    expanded: bool,
) ![]layout.Line {
    var out = std.ArrayList(layout.Line).empty;
    errdefer out.deinit(allocator);
    try layout.appendPlainLine(
        allocator,
        &out,
        "[compaction]",
        width,
        screen.withBold(screen.text.custom_message_label),
    );
    try out.append(allocator, .{});

    const token_text = try std.fmt.allocPrint(
        allocator,
        "Compacted from {d} tokens",
        .{compaction.tokens_before},
    );
    if (!expanded) {
        const summary = try std.fmt.allocPrint(
            allocator,
            "{s} (ctrl+o to expand)",
            .{token_text},
        );
        try layout.appendProseLine(
            allocator,
            &out,
            summary,
            width,
            screen.text.custom_message,
        );
        return out.toOwnedSlice(allocator);
    }

    try layout.appendProseLine(
        allocator,
        &out,
        token_text,
        width,
        screen.withBold(screen.text.custom_message),
    );
    const summary = trimTrailingNewlines(compaction.summary.items);
    if (summary.len > 0) {
        try out.append(allocator, .{});
        try appendMarkdownBlock(
            allocator,
            &out,
            summary,
            width,
            screen.text.custom_message,
        );
    }
    return out.toOwnedSlice(allocator);
}

fn layoutCustom(allocator: std.mem.Allocator, custom: anytype, width: u16) ![]layout.Line {
    var out = std.ArrayList(layout.Line).empty;
    errdefer out.deinit(allocator);
    if (custom.title.len > 0) {
        try layout.appendPlainLine(allocator, &out, custom.title, width, screen.text.custom_message_label);
        try out.append(allocator, .{});
    }
    var state: layout.WrapState = .{};
    const body = try layout.wrapMarkdown(
        allocator,
        trimTrailingNewlines(custom.text),
        width,
        screen.text.custom_message,
        &state,
    );
    try out.appendSlice(allocator, body);
    return out.toOwnedSlice(allocator);
}

fn trimTrailingNewlines(text: []const u8) []const u8 {
    var end = text.len;
    while (end > 0 and (text[end - 1] == '\n' or text[end - 1] == '\r')) : (end -= 1) {}
    return text[0..end];
}

fn jsonValueString(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var stringify: std.json.Stringify = .{ .writer = &writer.writer };
    try stringify.write(value);
    return writer.toOwnedSlice();
}

fn nowNs(io: std.Io) u64 {
    const raw = std.Io.Timestamp.now(io, .awake).toNanoseconds();
    return if (raw <= 0) 0 else @intCast(raw);
}

fn defaultToolResolver(_: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8, _: ToolArgs) anyerror!ToolUi {
    return .{ .title = try allocator.dupe(u8, name), .display = blocks.default_tool_display };
}

fn defaultToolResultResolver(_: ?*anyopaque, allocator: std.mem.Allocator, _: []const u8, _: bool, content: []const ai.ToolResultContent, _: ?std.json.Value) anyerror!ToolResultUi {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var truncated = false;
    try blocks.appendTextContent(&writer, content, blocks.tool_body_bytes_max, &truncated);
    return .{ .body = try writer.toOwnedSlice() };
}

fn emptyAssistantMessage(content: []const ai.AssistantContent, stop_reason: ai.StopReason) ai.AssistantMessage {
    return .{
        .content = content,
        .api = ai.KnownApi.faux,
        .provider = ai.KnownProvider.faux,
        .model = "faux",
        .usage = ai.protocol.emptyUsage(),
        .stop_reason = stop_reason,
        .timestamp = 0,
    };
}

const RhythmFixtureKind = enum {
    user,
    assistant,
    tool,
    notice,
    compaction,
    custom,
};

fn appendRhythmFixture(transcript: *Transcript, kind: RhythmFixtureKind) !void {
    switch (kind) {
        .user => try transcript.apply(std.testing.io, .{ .message_start = .{ .message = .{ .user = .{
            .content = .{ .string = "user words" },
            .timestamp = 0,
        } } } }),
        .assistant => {
            const content = [_]ai.AssistantContent{.{ .text = .{ .text = "assistant words" } }};
            const assistant = emptyAssistantMessage(&content, .stop);
            try transcript.apply(std.testing.io, .{ .message_start = .{ .message = .{ .assistant = assistant } } });
            try transcript.apply(std.testing.io, .{ .message_end = .{ .message = .{ .assistant = assistant } } });
        },
        .tool => {
            var id_buffer: [32]u8 = undefined;
            const call_id = try std.fmt.bufPrint(&id_buffer, "fixture-tool-{d}", .{transcript.next_seq});
            try transcript.apply(std.testing.io, .{ .tool_execution_start = .{
                .tool_call_id = call_id,
                .tool_name = "fixture",
                .args = .null,
            } });
        },
        .notice => try transcript.appendNotice(.info, "notice words"),
        .compaction => try transcript.appendCompaction("summary words", 100),
        .custom => try transcript.apply(std.testing.io, .{ .message_start = .{ .message = .{ .custom = .{
            .kind = "Fixture",
            .payload = .{ .string = "custom words" },
            .timestamp = 0,
        } } } }),
    }
}

test "transcript applies streamed assistant text by delta" {
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();

    try transcript.apply(std.testing.io, .agent_start);
    try transcript.apply(std.testing.io, .{ .message_start = .{ .message = .{ .assistant = emptyAssistantMessage(&.{}, .stop) } } });
    try transcript.apply(std.testing.io, .{ .message_update = .{ .assistant_message_event = .{ .text_delta = .{
        .content_index = 0,
        .delta = "hello",
        .partial = emptyAssistantMessage(&.{}, .stop),
    } } } });
    const content = [_]ai.AssistantContent{.{ .text = .{ .text = "hello" } }};
    try transcript.apply(std.testing.io, .{ .message_end = .{ .message = .{ .assistant = emptyAssistantMessage(&content, .stop) } } });
    try transcript.apply(std.testing.io, .agent_end);

    try std.testing.expectEqual(@as(usize, 1), transcript.items.items.len);
    try std.testing.expect(!transcript.run_active);
    const item = transcript.items.items[0];
    try std.testing.expectEqualStrings("hello", item.kind.assistant.parts.items[0].text.items);
    try std.testing.expect(!item.kind.assistant.streaming);
}

test "transcript keeps streamed assistant text valid across UTF-8 delta boundaries" {
    const source = "Aé中😀Z";

    for (1..source.len) |split| {
        var transcript = Transcript.init(std.testing.allocator);
        defer transcript.deinit();

        try transcript.apply(std.testing.io, .{ .message_start = .{
            .message = .{ .assistant = emptyAssistantMessage(&.{}, .stop) },
        } });
        try transcript.apply(std.testing.io, .{ .message_update = .{ .assistant_message_event = .{ .text_delta = .{
            .content_index = 0,
            .delta = source[0..split],
            .partial = emptyAssistantMessage(&.{}, .stop),
        } } } });

        const item = transcript.items.items[0];
        const first = item.kind.assistant.parts.items[0].text.items;
        try std.testing.expect(std.unicode.utf8ValidateSlice(first));
        _ = try transcript.prepareLayout(.{ .width = 20, .height = 10 });
        for (item.layout_cache.active.lines) |line| {
            for (line.spans()) |span| try std.testing.expect(std.unicode.utf8ValidateSlice(span.text));
        }

        try transcript.apply(std.testing.io, .{ .message_update = .{ .assistant_message_event = .{ .text_delta = .{
            .content_index = 0,
            .delta = source[split..],
            .partial = emptyAssistantMessage(&.{}, .stop),
        } } } });
        try std.testing.expectEqualStrings(source, item.kind.assistant.parts.items[0].text.items);
        try std.testing.expectEqual(@as(u8, 0), item.kind.assistant.pending_utf8.items[0].len);
        _ = try transcript.prepareLayout(.{ .width = 20, .height = 10 });
        for (item.layout_cache.active.lines) |line| {
            for (line.spans()) |span| try std.testing.expect(std.unicode.utf8ValidateSlice(span.text));
        }
    }
}

test "transcript replaces malformed streamed assistant UTF-8" {
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();

    try transcript.apply(std.testing.io, .{ .message_start = .{
        .message = .{ .assistant = emptyAssistantMessage(&.{}, .stop) },
    } });
    try transcript.apply(std.testing.io, .{ .message_update = .{ .assistant_message_event = .{ .text_delta = .{
        .content_index = 0,
        .delta = "ok\xffdone",
        .partial = emptyAssistantMessage(&.{}, .stop),
    } } } });

    const text = transcript.items.items[0].kind.assistant.parts.items[0].text.items;
    try std.testing.expectEqualStrings("ok�done", text);
    try std.testing.expect(std.unicode.utf8ValidateSlice(text));
}

test "transcript incrementally relayouts only the unstable streamed suffix" {
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();

    try transcript.apply(std.testing.io, .{ .message_start = .{
        .message = .{ .assistant = emptyAssistantMessage(&.{}, .stop) },
    } });
    try transcript.apply(std.testing.io, .{ .message_update = .{ .assistant_message_event = .{ .text_delta = .{
        .content_index = 0,
        .delta = "one\nabcdefghij",
        .partial = emptyAssistantMessage(&.{}, .stop),
    } } } });
    const item = transcript.items.items[0];
    const state: theme.LayoutState = .{ .width = 6, .height = 10 };
    _ = try transcript.prepareLayout(state);
    var lines = item.layout_cache.active.lines;

    try std.testing.expectEqual(
        @as(usize, "one\nabcdefgh".len),
        item.layout_cache.active.wrap.committed_bytes,
    );
    try std.testing.expectEqual(@as(usize, 3), item.layout_cache.active.wrap.committed_lines);
    const stable_text_ptr = lines[0].spans()[1].text.ptr;

    try transcript.apply(std.testing.io, .{ .message_update = .{ .assistant_message_event = .{ .text_delta = .{
        .content_index = 0,
        .delta = "kl",
        .partial = emptyAssistantMessage(&.{}, .stop),
    } } } });
    try std.testing.expectEqual(LayoutInvalidation.source_appended, item.layout_cache.invalidation);

    _ = try transcript.prepareLayout(state);
    lines = item.layout_cache.active.lines;
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings(" one", lines[0].copyText(&buffer));
    try std.testing.expectEqualStrings(" ijkl", lines[3].copyText(&buffer));
    try std.testing.expectEqual(stable_text_ptr, lines[0].spans()[1].text.ptr);
}

test "transcript tracks the first item needing line index repair" {
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();

    try transcript.apply(std.testing.io, .{ .message_start = .{
        .message = .{ .user = .{ .content = .{ .string = "prompt" }, .timestamp = 0 } },
    } });
    try transcript.apply(std.testing.io, .{ .message_start = .{
        .message = .{ .assistant = emptyAssistantMessage(&.{}, .stop) },
    } });
    try transcript.apply(std.testing.io, .{ .message_update = .{ .assistant_message_event = .{ .text_delta = .{
        .content_index = 0,
        .delta = "first",
        .partial = emptyAssistantMessage(&.{}, .stop),
    } } } });
    const state: theme.LayoutState = .{ .width = 40, .height = 10 };
    _ = try transcript.prepareLayout(state);

    try transcript.apply(std.testing.io, .{ .message_update = .{ .assistant_message_event = .{ .text_delta = .{
        .content_index = 0,
        .delta = " second",
        .partial = emptyAssistantMessage(&.{}, .stop),
    } } } });
    _ = try transcript.prepareLayout(state);
    const work = transcript.lastLayoutWork();
    try std.testing.expectEqual(@as(usize, 1), work.items_laid_out);
    try std.testing.expectEqual(@as(usize, 1), work.index_entries_repaired);
}

test "transcript final assistant message removes stale streamed parts" {
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();

    try transcript.apply(std.testing.io, .{ .message_start = .{ .message = .{ .assistant = emptyAssistantMessage(&.{}, .stop) } } });
    try transcript.apply(std.testing.io, .{ .message_update = .{ .assistant_message_event = .{ .text_delta = .{
        .content_index = 0,
        .delta = "hello",
        .partial = emptyAssistantMessage(&.{}, .stop),
    } } } });
    try transcript.apply(std.testing.io, .{ .message_update = .{ .assistant_message_event = .{ .text_delta = .{
        .content_index = 1,
        .delta = "stale",
        .partial = emptyAssistantMessage(&.{}, .stop),
    } } } });
    const content = [_]ai.AssistantContent{.{ .text = .{ .text = "hello" } }};
    try transcript.apply(std.testing.io, .{ .message_end = .{ .message = .{ .assistant = emptyAssistantMessage(&content, .stop) } } });

    const assistant = &transcript.items.items[0].kind.assistant;
    try std.testing.expectEqual(@as(usize, 1), assistant.parts.items.len);
    try std.testing.expectEqualStrings("hello", assistant.parts.items[0].text.items);
}

test "transcript bounds streamed tool args preview once" {
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();

    try transcript.apply(std.testing.io, .{ .tool_execution_start = .{ .tool_call_id = "args-1", .tool_name = "bash", .args = .null } });
    const item = transcript.items.items[0];
    const delta = try std.testing.allocator.alloc(u8, blocks.args_preview_bytes_max + 100);
    defer std.testing.allocator.free(delta);
    @memset(delta, 'a');

    try transcript.appendToolArgs(item, delta);
    try std.testing.expect(item.kind.tool.args_truncated);
    try std.testing.expect(item.kind.tool.args_preview.items.len <= blocks.args_preview_bytes_max);
    const len_after_truncation = item.kind.tool.args_preview.items.len;
    try transcript.appendToolArgs(item, "extra");
    try std.testing.expectEqual(len_after_truncation, item.kind.tool.args_preview.items.len);
}

test "transcript bounded append continues across UTF-8 chunk boundary" {
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();

    const text = try std.testing.allocator.alloc(u8, append_chunk_bytes_max + 2);
    defer std.testing.allocator.free(text);
    @memset(text[0 .. append_chunk_bytes_max - 1], 'a');
    text[append_chunk_bytes_max - 1] = 0xc3;
    text[append_chunk_bytes_max] = 0xa9;
    text[append_chunk_bytes_max + 1] = 'b';

    try transcript.apply(std.testing.io, .{ .message_start = .{ .message = .{ .user = .{ .content = .{ .string = text }, .timestamp = 0 } } } });

    const user = transcript.items.items[0].kind.user;
    try std.testing.expect(!user.truncated);
    try std.testing.expectEqualStrings(text, user.text.items);
    try std.testing.expect(std.mem.indexOf(u8, user.text.items, output_truncated_text) == null);
}

test "transcript creates tool before execution and records output" {
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();

    var args_object: std.json.ObjectMap = .empty;
    defer args_object.deinit(std.testing.allocator);
    try args_object.put(std.testing.allocator, "path", .{ .string = "src/main.zig" });
    const call = ai.ToolCall{ .id = "call-1", .name = "read", .arguments = .{ .object = args_object } };
    const content = [_]ai.AssistantContent{.{ .tool_call = call }};
    const partial = emptyAssistantMessage(&content, .tool_use);
    try transcript.apply(std.testing.io, .{ .message_start = .{ .message = .{ .assistant = emptyAssistantMessage(&.{}, .tool_use) } } });
    try transcript.apply(std.testing.io, .{ .message_update = .{ .assistant_message_event = .{ .toolcall_start = .{
        .content_index = 0,
        .partial = partial,
    } } } });
    try std.testing.expectEqual(@as(usize, 2), transcript.items.items.len);
    const tool = transcript.items.items[1];
    try std.testing.expectEqualStrings("read", tool.kind.tool.title);

    try transcript.apply(std.testing.io, .{ .tool_execution_start = .{ .tool_call_id = "call-1", .tool_name = "read", .args = .null } });
    const result_content = [_]ai.ToolResultContent{.{ .text = .{ .text = "file body" } }};
    try transcript.apply(std.testing.io, .{ .tool_execution_update = .{ .tool_call_id = "call-1", .tool_name = "read", .args = .null, .partial_result = .{ .content = &result_content } } });
    try transcript.apply(std.testing.io, .{ .tool_execution_end = .{ .tool_call_id = "call-1", .tool_name = "read", .result = .{ .content = &result_content }, .is_error = false } });

    try std.testing.expectEqual(blocks.Status.done, tool.kind.tool.status);
    try std.testing.expectEqualStrings("file body", tool.kind.tool.body.items);
    try std.testing.expect(transcript.live_tools.get("call-1") == null);
}

test "transcript suppresses invisible live tool updates without relayout" {
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();

    try transcript.apply(std.testing.io, .{ .tool_execution_start = .{
        .tool_call_id = "call-1",
        .tool_name = "read",
        .args = .null,
    } });
    const item = transcript.items.items[0];
    const state: theme.LayoutState = .{ .width = 40, .height = 10 };
    _ = try transcript.prepareLayout(state);

    const content = [_]ai.ToolResultContent{.{ .text = .{ .text = "hidden progress" } }};
    try transcript.apply(std.testing.io, .{ .tool_execution_update = .{
        .tool_call_id = "call-1",
        .tool_name = "read",
        .args = .null,
        .partial_result = .{ .content = &content },
    } });
    try std.testing.expectEqual(LayoutInvalidation.clean, item.layout_cache.invalidation);
    _ = try transcript.prepareLayout(state);
    try std.testing.expectEqual(@as(usize, 0), transcript.lastLayoutWork().items_laid_out);
}

test "transcript relayouts running duration only when its visible tick changes" {
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();

    try transcript.apply(std.testing.io, .{ .tool_execution_start = .{
        .tool_call_id = "call-1",
        .tool_name = "bash",
        .args = .null,
    } });
    const item = transcript.items.items[0];
    item.kind.tool.display.shows_duration = true;
    item.kind.tool.started_ns = 0;
    item.kind.tool.elapsed_ms = 0;
    const state: theme.LayoutState = .{ .width = 40, .height = 10 };
    _ = try transcript.prepareLayout(state);

    try std.testing.expect(!transcript.markRunningToolsDirty(99 * std.time.ns_per_ms));
    try std.testing.expectEqual(LayoutInvalidation.clean, item.layout_cache.invalidation);
    try std.testing.expect(transcript.markRunningToolsDirty(100 * std.time.ns_per_ms));
    try std.testing.expectEqual(LayoutInvalidation.rebuild, item.layout_cache.invalidation);
}

test "transcript invalidation has one dominance order" {
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();

    const item = try transcript.createAssistantItem(true);
    try transcript.appendItem(item);
    transcript.invalidateItem(item, .source_appended);
    try std.testing.expectEqual(LayoutInvalidation.rebuild, item.layout_cache.invalidation);

    item.layout_cache.invalidation = .clean;
    transcript.invalidateItem(item, .source_appended);
    try std.testing.expectEqual(LayoutInvalidation.source_appended, item.layout_cache.invalidation);
    transcript.invalidateItem(item, .rebuild);
    try std.testing.expectEqual(LayoutInvalidation.rebuild, item.layout_cache.invalidation);
}

test "transcript distinguishes semantic blanks panel padding and item margins" {
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();

    try transcript.apply(std.testing.io, .{ .message_start = .{ .message = .{ .user = .{
        .content = .{ .string = "alpha\n\nbeta" },
        .timestamp = 0,
    } } } });
    const state: theme.LayoutState = .{ .width = 40, .height = 10 };
    _ = try transcript.prepareLayout(state);
    const cache = transcript.items.items[0].layout_cache.active;

    try std.testing.expectEqual(cache.lines.len, cache.roles.len);
    try std.testing.expectEqualSlices(RowRole, &.{
        .panel_padding,
        .content,
        .semantic_blank,
        .content,
        .panel_padding,
        .item_margin,
    }, cache.roles);
    const semantic = transcript.resolvePosition(.{ .item_seq = 0, .line_in_item = 2 }).?;
    try std.testing.expectEqual(@as(u32, 2), semantic.position.line_in_item);
    const margin = transcript.resolvePosition(.{ .item_seq = 0, .line_in_item = 5 }).?;
    try std.testing.expectEqual(@as(u32, 4), margin.position.line_in_item);
}

test "transcript golden rhythm covers every item adjacency" {
    const kinds = std.enums.values(RhythmFixtureKind);
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();

    for (kinds) |first| for (kinds) |second| {
        transcript.clear();
        try appendRhythmFixture(&transcript, first);
        try appendRhythmFixture(&transcript, second);
        const state: theme.LayoutState = .{ .width = 40, .height = 20 };
        _ = try transcript.prepareLayout(state);

        try std.testing.expectEqual(@as(usize, 2), transcript.items.items.len);
        const first_cache = transcript.items.items[0].layout_cache.active;
        const second_cache = transcript.items.items[1].layout_cache.active;
        try std.testing.expect(first_cache.roles.len > 0);
        try std.testing.expect(second_cache.roles.len > 0);
        try std.testing.expectEqual(RowRole.item_margin, first_cache.roles[first_cache.roles.len - 1]);
        try std.testing.expect(second_cache.roles[0] != .item_margin);
        try std.testing.expectEqual(RowRole.item_margin, second_cache.roles[second_cache.roles.len - 1]);

        var margins: usize = 0;
        for (0..transcript.totalLines()) |absolute| {
            if (transcript.rowRoleAt(absolute) == .item_margin) margins += 1;
        }
        try std.testing.expectEqual(@as(usize, 2), margins);
    };
}

test "transcript golden rhythm remains valid at pathological widths" {
    const widths = [_]u16{ 0, 1, 2, 3, 4, 8, 40 };
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();
    for (std.enums.values(RhythmFixtureKind)) |kind| try appendRhythmFixture(&transcript, kind);

    for (widths) |width| {
        const state: theme.LayoutState = .{ .width = width, .height = 20 };
        while (try transcript.prepareLayout(state) == .pending) {}
        try std.testing.expect(transcript.totalLines() > 0);
        for (transcript.items.items) |item| {
            const cache = item.layout_cache.active;
            try std.testing.expectEqual(cache.lines.len, cache.roles.len);
            try std.testing.expect(cache.roles.len > 0);
            try std.testing.expectEqual(RowRole.item_margin, cache.roles[cache.roles.len - 1]);
        }
    }
}

test "transcript owns line positions and visible collection" {
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();

    try transcript.appendNotice(.info, "alpha");
    try transcript.appendNotice(.info, "beta");
    const state: theme.LayoutState = .{ .width = 40, .height = 10 };
    const prepared = try transcript.prepareLayout(state);
    try std.testing.expectEqual(PrepareResult.published, prepared);
    try std.testing.expectEqual(@as(usize, 4), transcript.totalLines());

    const second = transcript.positionAtLine(2).?;
    try std.testing.expectEqual(transcript.items.items[1].seq, second.position.item_seq);
    try std.testing.expectEqual(@as(u32, 0), second.position.line_in_item);
    const resolved = transcript.resolvePosition(.{
        .item_seq = second.position.item_seq,
        .line_in_item = std.math.maxInt(u32),
    }).?;
    try std.testing.expectEqual(@as(usize, 2), resolved.absolute);

    var visible: [2]layout.Line = undefined;
    const lines = transcript.collectVisible(2, &visible);
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings(" beta", lines[0].copyText(&buffer));
    try std.testing.expectEqualStrings("", lines[1].copyText(&buffer));
    try std.testing.expectEqual(@as(usize, 2), transcript.lastLayoutWork().lines_materialized);
}

test "transcript complete relayout is bounded and published atomically" {
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();

    for (0..relayout_items_per_prepare + 1) |index| {
        var buffer: [32]u8 = undefined;
        try transcript.appendNotice(.info, try std.fmt.bufPrint(&buffer, "item {d}", .{index}));
    }
    const state: theme.LayoutState = .{ .width = 40, .height = 10 };
    const first = try transcript.prepareLayout(state);
    try std.testing.expectEqual(PrepareResult.pending, first);
    try std.testing.expectEqual(relayout_items_per_prepare, transcript.lastLayoutWork().items_laid_out);
    try std.testing.expectEqual(@as(usize, 0), transcript.totalLines());

    const second = try transcript.prepareLayout(state);
    try std.testing.expectEqual(PrepareResult.published, second);
    try std.testing.expectEqual(@as(usize, 1), transcript.lastLayoutWork().items_laid_out);
    try std.testing.expectEqual((relayout_items_per_prepare + 1) * 2, transcript.totalLines());
}

test "transcript cancels stale relayout when layout key returns to active" {
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();

    for (0..relayout_items_per_prepare + 1) |index| {
        var buffer: [32]u8 = undefined;
        try transcript.appendNotice(.info, try std.fmt.bufPrint(&buffer, "item {d}", .{index}));
    }
    const narrow: theme.LayoutState = .{ .width = 40, .height = 10 };
    while ((try transcript.prepareLayout(narrow)) == .pending) {}
    const old_total = transcript.totalLines();

    const wide: theme.LayoutState = .{ .width = 80, .height = 10 };
    const pending = try transcript.prepareLayout(wide);
    try std.testing.expectEqual(PrepareResult.pending, pending);
    try std.testing.expectEqual(old_total, transcript.totalLines());

    const reverted = try transcript.prepareLayout(narrow);
    try std.testing.expectEqual(PrepareResult.ready, reverted);
    try std.testing.expectEqual(old_total, transcript.totalLines());
}

test "transcript relayout incorporates mutations without restarting unrelated work" {
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();

    try transcript.apply(std.testing.io, .{ .message_start = .{
        .message = .{ .assistant = emptyAssistantMessage(&.{}, .stop) },
    } });
    try transcript.apply(std.testing.io, .{ .message_update = .{ .assistant_message_event = .{ .text_delta = .{
        .content_index = 0,
        .delta = "hello",
        .partial = emptyAssistantMessage(&.{}, .stop),
    } } } });
    for (0..relayout_items_per_prepare) |index| {
        var buffer: [32]u8 = undefined;
        try transcript.appendNotice(.info, try std.fmt.bufPrint(&buffer, "item {d}", .{index}));
    }
    const narrow: theme.LayoutState = .{ .width = 40, .height = 10 };
    while ((try transcript.prepareLayout(narrow)) == .pending) {}

    const wide: theme.LayoutState = .{ .width = 80, .height = 10 };
    try std.testing.expectEqual(PrepareResult.pending, try transcript.prepareLayout(wide));
    try transcript.apply(std.testing.io, .{ .message_update = .{ .assistant_message_event = .{ .text_delta = .{
        .content_index = 0,
        .delta = " world",
        .partial = emptyAssistantMessage(&.{}, .stop),
    } } } });
    while ((try transcript.prepareLayout(wide)) == .pending) {}

    const first = transcript.lineAt(0).?;
    var text: [32]u8 = undefined;
    try std.testing.expectEqualStrings(" hello world", first.copyText(&text));
}

test "transcript layout key ignores height and rebuilds on width" {
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();

    try transcript.appendNotice(.info, "alpha");
    try transcript.appendNotice(.info, "beta");
    const first: theme.LayoutState = .{ .width = 40, .height = 10 };
    const prepared = try transcript.prepareLayout(first);
    try std.testing.expectEqual(PrepareResult.published, prepared);
    try std.testing.expectEqual(@as(usize, 2), transcript.lastLayoutWork().items_laid_out);

    const height_only: theme.LayoutState = .{ .width = 40, .height = 20 };
    const same_key = try transcript.prepareLayout(height_only);
    try std.testing.expectEqual(PrepareResult.ready, same_key);
    try std.testing.expectEqual(@as(usize, 0), transcript.lastLayoutWork().items_laid_out);

    const wider: theme.LayoutState = .{ .width = 60, .height = 20 };
    const rebuilt = try transcript.prepareLayout(wider);
    try std.testing.expectEqual(PrepareResult.published, rebuilt);
    try std.testing.expectEqual(@as(usize, 2), transcript.lastLayoutWork().items_laid_out);
}

test "transcript aborts running tools on aborted assistant end" {
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();

    try transcript.apply(std.testing.io, .{ .tool_execution_start = .{ .tool_call_id = "call-1", .tool_name = "bash", .args = .null } });
    try transcript.apply(std.testing.io, .{ .message_start = .{ .message = .{ .assistant = emptyAssistantMessage(&.{}, .aborted) } } });
    try transcript.apply(std.testing.io, .{ .message_end = .{ .message = .{ .assistant = emptyAssistantMessage(&.{}, .aborted) } } });

    const tool = transcript.items.items[0].kind.tool;
    try std.testing.expectEqual(blocks.Status.aborted, tool.status);
    try std.testing.expectEqual(@as(?u64, null), tool.elapsed_ms);
    try std.testing.expect(tool.duration_ms != null);
}

test "transcript reused terminal tool id starts a new live item" {
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();

    try transcript.apply(std.testing.io, .{ .tool_execution_start = .{ .tool_call_id = "call-1", .tool_name = "bash", .args = .null } });
    const result_content = [_]ai.ToolResultContent{.{ .text = .{ .text = "done" } }};
    try transcript.apply(std.testing.io, .{ .tool_execution_end = .{ .tool_call_id = "call-1", .tool_name = "bash", .result = .{ .content = &result_content }, .is_error = false } });
    try transcript.apply(std.testing.io, .{ .tool_execution_start = .{ .tool_call_id = "call-1", .tool_name = "bash", .args = .null } });

    try std.testing.expectEqual(@as(usize, 2), transcript.items.items.len);
    try std.testing.expectEqual(blocks.Status.done, transcript.items.items[0].kind.tool.status);
    try std.testing.expectEqual(blocks.Status.running, transcript.items.items[1].kind.tool.status);
    try std.testing.expect(transcript.live_tools.get("call-1").? == transcript.items.items[1]);
}

test "transcript evicts oldest items past item cap" {
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();

    for (0..transcript_items_max + 1) |index| {
        var buffer: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "msg-{d}", .{index});
        try transcript.apply(std.testing.io, .{ .message_start = .{ .message = .{ .user = .{ .content = .{ .string = text }, .timestamp = 0 } } } });
    }

    try std.testing.expectEqual(@as(usize, transcript_items_max), transcript.items.items.len);
    try std.testing.expectEqual(@as(u64, 1), transcript.evicted_seqs);
    try std.testing.expectEqualStrings("msg-1", transcript.items.items[0].kind.user.text.items);
}

test {
    std.testing.refAllDecls(@This());
}
